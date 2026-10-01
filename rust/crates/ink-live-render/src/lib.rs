//! Bounded live-stroke protocol shared by the CPU renderer and a platform GPU
//! surface. The crate deliberately contains no unsafe graphics handles: a
//! platform adapter may consume the dab stream, while the document engine
//! remains the deterministic source of truth.
#![allow(missing_docs)]
#![allow(
    clippy::cast_precision_loss,
    clippy::missing_errors_doc,
    clippy::must_use_candidate
)]

use std::collections::VecDeque;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DabPhase {
    Predicted,
    Coalesced,
    Confirmed,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LiveDab {
    pub stroke_id: u128,
    /// Highest input sample represented by this dab; acknowledgement follows
    /// this value so all dabs from a packet retire together.
    pub sequence: u32,
    /// Stable zero-based identity among dabs emitted for `sequence`.
    pub dab_index: u32,
    pub x: f32,
    pub y: f32,
    pub radius: f32,
    pub opacity: f32,
    pub rotation: f32,
    /// Straight-alpha sRGB color shared with the CPU brush dab.
    pub color: [u8; 4],
    pub phase: DabPhase,
}

impl LiveDab {
    pub fn validate(self) -> Result<Self, LiveRenderError> {
        if [self.x, self.y, self.radius, self.opacity, self.rotation]
            .iter()
            .any(|value| !value.is_finite())
            || !(0.0..=131_072.0).contains(&self.radius)
            || !(0.0..=1.0).contains(&self.opacity)
        {
            return Err(LiveRenderError::InvalidDab);
        }
        Ok(self)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct LiveSurfaceConfig {
    pub physical_width: u32,
    pub physical_height: u32,
    pub scale_milli: u32,
}

impl LiveSurfaceConfig {
    pub fn validate(self) -> Result<Self, LiveRenderError> {
        if self.physical_width == 0
            || self.physical_height == 0
            || self.physical_width > 8192
            || self.physical_height > 8192
            || self.scale_milli == 0
        {
            return Err(LiveRenderError::InvalidSurface);
        }
        let bytes = u64::from(self.physical_width)
            .saturating_mul(u64::from(self.physical_height))
            .saturating_mul(4);
        if bytes > 256 * 1024 * 1024 {
            return Err(LiveRenderError::GpuMemoryLimit);
        }
        Ok(self)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LiveRenderError {
    InvalidDab,
    InvalidSurface,
    GpuMemoryLimit,
    ConfirmedQueueFull,
    GpuUnavailable,
    DabBatchTooLarge,
    GpuReadbackFailed,
    InvalidViewport,
    StaleViewportGeneration,
    InvalidNativeTexture,
}

#[derive(Debug)]
pub struct LiveDabQueue {
    capacity: usize,
    dabs: VecDeque<LiveDab>,
}

#[cfg(feature = "gpu")]
mod gpu {
    use super::{LiveDab, LiveRenderError, LiveSurfaceConfig};
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    use metal::foreign_types::ForeignType;
    use std::borrow::Cow;
    use std::collections::HashMap;
    use std::sync::Mutex;
    use wgpu::util::DeviceExt;

    struct LiveRenderTarget {
        texture: wgpu::Texture,
        view: wgpu::TextureView,
        copy_source: bool,
        /// Flutter samples Apple `IOSurface` targets on a different GPU queue.
        /// Those targets must be complete before frameAvailable is signalled.
        external: bool,
        initialized: bool,
    }

    fn poll_mode_for_target(_external: bool) -> wgpu::Maintain {
        // Flutter samples the IOSurface independently of the wgpu queue. A
        // blocking Wait after every dab batch turns a long stroke into a
        // serial CPU/GPU pipeline and can pause input for hundreds of ms when
        // the device is catching up. Submission order is preserved by the
        // shared texture; polling keeps the queue moving and lets the next
        // frame observe the most recent completed work.
        wgpu::Maintain::Poll
    }

    #[derive(Clone, Default)]
    struct LiveDabStore {
        dabs: Vec<LiveDab>,
        indices: HashMap<(u128, u32, u32), usize>,
    }

    #[derive(Clone, Copy)]
    struct LiveViewport {
        matrix: [f32; 6],
        generation: u64,
    }

    impl Default for LiveViewport {
        fn default() -> Self {
            Self {
                matrix: [1.0, 0.0, 0.0, 1.0, 0.0, 0.0],
                generation: 0,
            }
        }
    }

    impl LiveDabStore {
        fn rebuild_indices(&mut self) {
            self.indices.clear();
            self.indices.reserve(self.dabs.len());
            for (index, dab) in self.dabs.iter().enumerate() {
                self.indices
                    .insert((dab.stroke_id, dab.sequence, dab.dab_index), index);
            }
        }
    }

    /// Fixed shader source bundled with the application. It expands each dab
    /// into a circular, antialiased quad; no source is accepted from documents
    /// or users at runtime.
    const LIVE_DAB_SHADER: &str = r"
struct Vertex {
  @location(0) position: vec2<f32>,
  @location(1) local_position: vec2<f32>,
  @location(2) color: vec4<f32>,
  @location(3) opacity: f32,
}

struct VertexOutput {
  @builtin(position) position: vec4<f32>,
  @location(0) local_position: vec2<f32>,
  @location(1) color: vec4<f32>,
  @location(2) opacity: f32,
}

@vertex
fn vs_main(vertex: Vertex) -> VertexOutput {
  var output: VertexOutput;
  output.position = vec4<f32>(vertex.position, 0.0, 1.0);
  output.local_position = vertex.local_position;
  output.color = vertex.color;
  output.opacity = vertex.opacity;
  return output;
}

@fragment
fn fs_main(input: VertexOutput) -> @location(0) vec4<f32> {
  let distance = length(input.local_position);
  let feather = max(fwidth(distance), 0.0001);
  let coverage = 1.0 - smoothstep(1.0 - feather, 1.0, distance);
  return vec4<f32>(input.color.rgb, input.opacity * input.color.a * coverage);
}
";

    fn create_pipeline(device: &wgpu::Device) -> wgpu::RenderPipeline {
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("project-ink-live-dab-shader"),
            source: wgpu::ShaderSource::Wgsl(Cow::Borrowed(LIVE_DAB_SHADER)),
        });
        let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("project-ink-live-pipeline-layout"),
            bind_group_layouts: &[],
            push_constant_ranges: &[],
        });
        device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("project-ink-live-pipeline"),
            layout: Some(&pipeline_layout),
            vertex: wgpu::VertexState {
                module: &shader,
                entry_point: "vs_main",
                compilation_options: wgpu::PipelineCompilationOptions::default(),
                buffers: &[wgpu::VertexBufferLayout {
                    array_stride: 36,
                    step_mode: wgpu::VertexStepMode::Vertex,
                    attributes: &[
                        wgpu::VertexAttribute {
                            format: wgpu::VertexFormat::Float32x2,
                            offset: 0,
                            shader_location: 0,
                        },
                        wgpu::VertexAttribute {
                            format: wgpu::VertexFormat::Float32x2,
                            offset: 8,
                            shader_location: 1,
                        },
                        wgpu::VertexAttribute {
                            format: wgpu::VertexFormat::Float32x4,
                            offset: 16,
                            shader_location: 2,
                        },
                        wgpu::VertexAttribute {
                            format: wgpu::VertexFormat::Float32,
                            offset: 32,
                            shader_location: 3,
                        },
                    ],
                }],
            },
            fragment: Some(wgpu::FragmentState {
                module: &shader,
                entry_point: "fs_main",
                compilation_options: wgpu::PipelineCompilationOptions::default(),
                targets: &[Some(wgpu::ColorTargetState {
                    format: wgpu::TextureFormat::Bgra8Unorm,
                    blend: Some(wgpu::BlendState::ALPHA_BLENDING),
                    write_mask: wgpu::ColorWrites::ALL,
                })],
            }),
            primitive: wgpu::PrimitiveState::default(),
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview: None,
        })
    }

    /// A bounded wgpu render target for the ephemeral live surface. The
    /// texture is intentionally not part of document state; Apple adapters
    /// may attach an IOSurface-backed Flutter texture while CPU tiles remain
    /// the fallback and source of truth.
    pub struct GpuLiveSurface {
        config: LiveSurfaceConfig,
        adapter_name: String,
        device: wgpu::Device,
        queue: wgpu::Queue,
        target: Mutex<LiveRenderTarget>,
        pipeline: wgpu::RenderPipeline,
        live_dabs: Mutex<LiveDabStore>,
        viewport: Mutex<LiveViewport>,
    }

    impl GpuLiveSurface {
        /// Create a surface using an adapter with no user-provided shader or
        /// resource input. Adapter failure is converted to the ordinary live
        /// renderer error so callers can use the CPU fallback.
        pub fn new(config: LiveSurfaceConfig) -> Result<Self, LiveRenderError> {
            let config = config.validate()?;
            let instance = wgpu::Instance::default();
            let adapter =
                pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
                    power_preference: wgpu::PowerPreference::LowPower,
                    compatible_surface: None,
                    force_fallback_adapter: false,
                }))
                .ok_or(LiveRenderError::GpuUnavailable)?;
            let adapter_name = adapter.get_info().name;
            // Keep conservative downlevel requirements for every other
            // resource, but request this adapter's actual 2D texture limit.
            // Flutter reports physical pixels, so even an 11-inch iPad can
            // exceed the 2048px downlevel default in portrait orientation.
            let mut required_limits = wgpu::Limits::downlevel_defaults();
            required_limits.max_texture_dimension_2d = adapter.limits().max_texture_dimension_2d;
            let (device, queue) = pollster::block_on(adapter.request_device(
                &wgpu::DeviceDescriptor {
                    label: Some("project-ink-live-surface"),
                    required_features: wgpu::Features::empty(),
                    required_limits,
                },
                None,
            ))
            .map_err(|_| LiveRenderError::GpuUnavailable)?;

            let texture = device.create_texture(&wgpu::TextureDescriptor {
                label: Some("project-ink-live-surface-texture"),
                size: wgpu::Extent3d {
                    width: config.physical_width,
                    height: config.physical_height,
                    depth_or_array_layers: 1,
                },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: wgpu::TextureFormat::Bgra8Unorm,
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT
                    | wgpu::TextureUsages::TEXTURE_BINDING
                    | wgpu::TextureUsages::COPY_SRC,
                view_formats: &[],
            });
            let view = texture.create_view(&wgpu::TextureViewDescriptor::default());
            let pipeline = create_pipeline(&device);
            Ok(Self {
                config,
                adapter_name,
                device,
                queue,
                target: Mutex::new(LiveRenderTarget {
                    texture,
                    view,
                    copy_source: true,
                    external: false,
                    initialized: false,
                }),
                pipeline,
                live_dabs: Mutex::new(LiveDabStore::default()),
                viewport: Mutex::new(LiveViewport::default()),
            })
        }

        /// Set the document-to-surface affine transform. Matrix layout is
        /// `[a, b, c, d, tx, ty]`, mapping `(x, y)` to
        /// `(a*x + c*y + tx, b*x + d*y + ty)` in physical surface pixels.
        /// Older generations are rejected so delayed viewport updates cannot
        /// move a live stroke back to a stale transform.
        pub fn set_viewport(
            &self,
            matrix: [f32; 6],
            generation: u64,
        ) -> Result<(), LiveRenderError> {
            if matrix.iter().any(|value| !value.is_finite()) {
                return Err(LiveRenderError::InvalidViewport);
            }
            let mut viewport = self
                .viewport
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if generation < viewport.generation {
                return Err(LiveRenderError::StaleViewportGeneration);
            }
            viewport.matrix = matrix;
            viewport.generation = generation;
            drop(viewport);
            let live_dabs = self
                .live_dabs
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            self.render_store(&live_dabs)?;
            Ok(())
        }

        /// Render a bounded dab batch. The caller is responsible for sending
        /// the same batch to the CPU engine; this method never mutates CPU
        /// document state.
        pub fn render(&self, dabs: &[LiveDab]) -> Result<(), LiveRenderError> {
            if dabs.len() > 65_536 {
                return Err(LiveRenderError::DabBatchTooLarge);
            }
            // Validate the complete batch before mutating the retained
            // overlay. A malformed later record must not leave a partial
            // render behind the CPU document.
            let validated = dabs
                .iter()
                .copied()
                .map(LiveDab::validate)
                .collect::<Result<Vec<_>, _>>()?;
            let mut live_dabs = self
                .live_dabs
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            // The normal input path appends confirmed records with unique
            // keys. Avoid cloning the entire retained dab vector and index
            // map for every small input batch: on long strokes that made
            // rendering cost grow with the length of the stroke and caused
            // the live preview to fall behind the Pencil.
            let mut batch_keys = HashMap::with_capacity(validated.len());
            let mut appended = Vec::with_capacity(validated.len());
            let mut requires_rebuild = false;
            for dab in &validated {
                let key = (dab.stroke_id, dab.sequence, dab.dab_index);
                if let Some(index) = live_dabs.indices.get(&key).copied() {
                    if live_dabs.dabs[index] != *dab {
                        requires_rebuild = true;
                        break;
                    }
                    continue;
                }
                if let Some(previous) = batch_keys.get(&key) {
                    if previous != dab {
                        requires_rebuild = true;
                        break;
                    }
                    continue;
                }
                batch_keys.insert(key, *dab);
                appended.push(*dab);
            }
            let within_capacity = live_dabs.dabs.len().saturating_add(appended.len()) <= 65_536;
            if !requires_rebuild && within_capacity {
                // Submit the GPU work before committing its retention keys, so
                // a device error still leaves the previous overlay coherent.
                if !appended.is_empty() {
                    self.render_dabs(&appended, false)?;
                    live_dabs.dabs.reserve(appended.len());
                    live_dabs.indices.reserve(appended.len());
                    for dab in appended {
                        let key = (dab.stroke_id, dab.sequence, dab.dab_index);
                        let index = live_dabs.dabs.len();
                        live_dabs.indices.insert(key, index);
                        live_dabs.dabs.push(dab);
                    }
                }
                return Ok(());
            }

            // Work on a copy so a capacity error leaves the previously
            // presented stroke set intact. Confirmed dabs are never silently
            // evicted from the GPU's bounded overlay.
            let mut next = live_dabs.clone();
            let mut append_only = true;
            let mut appended = Vec::with_capacity(dabs.len());
            for dab in validated {
                let key = (dab.stroke_id, dab.sequence, dab.dab_index);
                if let Some(index) = next.indices.get(&key).copied() {
                    if next.dabs[index] != dab {
                        next.dabs[index] = dab;
                        append_only = false;
                    }
                } else {
                    if next.dabs.len() >= 65_536 {
                        if let Some(evicted) = next
                            .dabs
                            .iter()
                            .position(|existing| existing.phase == super::DabPhase::Predicted)
                        {
                            next.dabs.remove(evicted);
                            next.rebuild_indices();
                            append_only = false;
                        } else if dab.phase == super::DabPhase::Predicted {
                            continue;
                        } else {
                            return Err(LiveRenderError::ConfirmedQueueFull);
                        }
                    }
                    let index = next.dabs.len();
                    next.indices.insert(key, index);
                    next.dabs.push(dab);
                    appended.push(dab);
                }
            }
            if append_only {
                if !appended.is_empty() {
                    self.render_dabs(&appended, false)?;
                }
            } else {
                self.render_store(&next)?;
            }
            *live_dabs = next;
            Ok(())
        }

        fn render_store(&self, live_dabs: &LiveDabStore) -> Result<(), LiveRenderError> {
            self.render_dabs(&live_dabs.dabs, true)
        }

        /// Append a unique batch without rebuilding existing pixels. Any
        /// replacement, capacity eviction, viewport change, acknowledgement,
        /// or cancellation takes the full redraw path to remove stale pixels.
        fn render_dabs(&self, dabs: &[LiveDab], clear: bool) -> Result<(), LiveRenderError> {
            let width = self.config.physical_width as f32;
            let height = self.config.physical_height as f32;
            let matrix = self
                .viewport
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .matrix;
            let mut vertex_bytes = Vec::with_capacity(dabs.len().saturating_mul(6 * 36));
            let radius_scale = matrix[0].hypot(matrix[1]);
            for dab in dabs.iter().copied() {
                // The deterministic CPU raster samples document pixel `n` at
                // its integer coordinate, while GPU fragments are evaluated
                // at physical pixel centers (`n + 0.5`). Shift transformed
                // dab centers by half a physical pixel so the live preview
                // overlays the same pixel footprint instead of appearing
                // softer or displaced when committed tiles replace it.
                let surface_x = matrix[0] * dab.x + matrix[2] * dab.y + matrix[4] + 0.5;
                let surface_y = matrix[1] * dab.x + matrix[3] * dab.y + matrix[5] + 0.5;
                let radius_x = dab.radius * radius_scale * 2.0 / width;
                let radius_y = dab.radius * radius_scale * 2.0 / height;
                let center_x = surface_x * 2.0 / width - 1.0;
                let center_y = 1.0 - surface_y * 2.0 / height;
                let color = dab.color.map(|channel| f32::from(channel) / 255.0);
                let vertices = [
                    (center_x - radius_x, center_y - radius_y, -1.0_f32, -1.0_f32),
                    (center_x + radius_x, center_y - radius_y, 1.0_f32, -1.0_f32),
                    (center_x + radius_x, center_y + radius_y, 1.0_f32, 1.0_f32),
                    (center_x - radius_x, center_y - radius_y, -1.0_f32, -1.0_f32),
                    (center_x + radius_x, center_y + radius_y, 1.0_f32, 1.0_f32),
                    (center_x - radius_x, center_y + radius_y, -1.0_f32, 1.0_f32),
                ];
                for (x, y, local_x, local_y) in vertices {
                    vertex_bytes.extend(x.to_le_bytes());
                    vertex_bytes.extend(y.to_le_bytes());
                    vertex_bytes.extend(local_x.to_le_bytes());
                    vertex_bytes.extend(local_y.to_le_bytes());
                    for channel in color {
                        vertex_bytes.extend(channel.to_le_bytes());
                    }
                    vertex_bytes.extend(dab.opacity.to_le_bytes());
                }
            }
            let vertex_count = u32::try_from(dabs.len().saturating_mul(6))
                .map_err(|_| LiveRenderError::DabBatchTooLarge)?;
            let vertex_buffer = (!vertex_bytes.is_empty()).then(|| {
                self.device
                    .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                        label: Some("project-ink-live-dabs"),
                        contents: &vertex_bytes,
                        usage: wgpu::BufferUsages::VERTEX,
                    })
            });
            let mut encoder = self
                .device
                .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                    label: Some("project-ink-live-render-encoder"),
                });
            let mut target = self
                .target
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let synchronize_for_external_consumer = target.external;
            let load = if clear || !target.initialized {
                wgpu::LoadOp::Clear(wgpu::Color::TRANSPARENT)
            } else {
                wgpu::LoadOp::Load
            };
            {
                let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                    label: Some("project-ink-live-render-pass"),
                    color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                        view: &target.view,
                        resolve_target: None,
                        ops: wgpu::Operations {
                            load,
                            store: wgpu::StoreOp::Store,
                        },
                    })],
                    depth_stencil_attachment: None,
                    timestamp_writes: None,
                    occlusion_query_set: None,
                });
                if let Some(vertex_buffer) = &vertex_buffer {
                    pass.set_pipeline(&self.pipeline);
                    pass.set_vertex_buffer(0, vertex_buffer.slice(..));
                    pass.draw(0..vertex_count, 0..1);
                }
            }
            target.initialized = true;
            self.queue.submit(Some(encoder.finish()));
            drop(target);
            // Apple Flutter textures are IOSurface-backed and Flutter samples
            // them from a separate Metal command queue. Merely submitting on
            // wgpu's queue does not order that read after this write; publishing
            // early can expose partially updated alpha/color data, which looks
            // like the artwork beneath the stroke is flashing. Pointer input
            // never waits on this worker, so synchronize only the external
            // presentation target. The private readback/test target stays async.
            let _ = self
                .device
                .poll(poll_mode_for_target(synchronize_for_external_consumer));
            Ok(())
        }

        /// Remove dabs whose confirmed input is present in the CPU tile
        /// revision. Predictions beyond the acknowledgement remain visible.
        pub fn acknowledge(&self, stroke_id: u128, sequence: u32) -> Result<(), LiveRenderError> {
            let mut live_dabs = self
                .live_dabs
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            live_dabs
                .dabs
                .retain(|dab| dab.stroke_id != stroke_id || dab.sequence > sequence);
            live_dabs.rebuild_indices();
            self.render_store(&live_dabs)
        }

        /// Cancel one stroke's ephemeral surface content without touching the
        /// CPU document or its undo history.
        pub fn cancel_stroke(&self, stroke_id: u128) -> Result<(), LiveRenderError> {
            let mut live_dabs = self
                .live_dabs
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            live_dabs.dabs.retain(|dab| dab.stroke_id != stroke_id);
            live_dabs.rebuild_indices();
            self.render_store(&live_dabs)
        }

        /// Expose the bounded texture dimensions for a platform texture shim.
        #[must_use]
        pub const fn dimensions(&self) -> (u32, u32) {
            (self.config.physical_width, self.config.physical_height)
        }

        /// Report the selected adapter so local renderer benchmarks can
        /// distinguish real GPU execution from an unavailable adapter.
        #[must_use]
        pub fn adapter_name(&self) -> &str {
            &self.adapter_name
        }

        /// Return the Metal device used by wgpu so the Apple texture adapter
        /// can create its IOSurface-backed texture on the same device.
        #[cfg(any(target_os = "macos", target_os = "ios"))]
        pub fn native_metal_device_handle(&self) -> Result<u64, LiveRenderError> {
            let handle = unsafe {
                self.device.as_hal::<wgpu_hal::api::Metal, _, _>(|device| {
                    device.map(|device| {
                        let raw_device = device.raw_device().lock();
                        raw_device.as_ptr() as usize as u64
                    })
                })
            }
            .flatten()
            .filter(|handle| *handle != 0)
            .ok_or(LiveRenderError::GpuUnavailable)?;
            Ok(handle)
        }

        /// Return a platform-native device only on Metal targets.
        #[cfg(not(any(target_os = "macos", target_os = "ios")))]
        pub fn native_metal_device_handle(&self) -> Result<u64, LiveRenderError> {
            Err(LiveRenderError::GpuUnavailable)
        }

        /// Replace the offscreen target with a Flutter-owned IOSurface-backed
        /// Metal texture. The wrapper takes ownership of the retained native
        /// texture reference, while Flutter keeps the corresponding
        /// `CVPixelBuffer` alive for the external texture lifetime.
        ///
        /// # Safety
        ///
        /// `texture_handle` must be a live, retained `MTLTexture` created from
        /// the exact Metal device returned by `native_metal_device_handle`,
        /// with the configured dimensions, `BGRA8Unorm` format, 2D type, one
        /// sample, and render-target plus shader-read usage. The pointer is
        /// transferred to this method and must not be released by the caller.
        #[cfg(any(target_os = "macos", target_os = "ios"))]
        pub unsafe fn attach_metal_texture(
            &self,
            texture_handle: u64,
        ) -> Result<(), LiveRenderError> {
            if texture_handle == 0 {
                return Err(LiveRenderError::InvalidNativeTexture);
            }
            let pointer = usize::try_from(texture_handle)
                .map_err(|_| LiveRenderError::InvalidNativeTexture)?;
            // SAFETY: the method contract requires an owned +1 MTLTexture
            // reference from the paired Flutter texture adapter.
            let raw_texture = unsafe { metal::Texture::from_ptr(pointer as *mut _) };
            if raw_texture.width() != u64::from(self.config.physical_width)
                || raw_texture.height() != u64::from(self.config.physical_height)
                || raw_texture.pixel_format() != metal::MTLPixelFormat::BGRA8Unorm
                || raw_texture.texture_type() != metal::MTLTextureType::D2
                || raw_texture.sample_count() != 1
                || !raw_texture.usage().contains(
                    metal::MTLTextureUsage::RenderTarget | metal::MTLTextureUsage::ShaderRead,
                )
            {
                return Err(LiveRenderError::InvalidNativeTexture);
            }
            // SAFETY: the paired adapter creates this MTLTexture on the wgpu
            // device and validates the descriptor before transferring it.
            let hal_texture = unsafe {
                wgpu_hal::metal::Device::texture_from_raw(
                    raw_texture,
                    wgpu::TextureFormat::Bgra8Unorm,
                    metal::MTLTextureType::D2,
                    1,
                    1,
                    wgpu_hal::CopyExtent {
                        width: self.config.physical_width,
                        height: self.config.physical_height,
                        depth: 1,
                    },
                )
            };
            let descriptor = wgpu::TextureDescriptor {
                label: Some("project-ink-flutter-iosurface"),
                size: wgpu::Extent3d {
                    width: self.config.physical_width,
                    height: self.config.physical_height,
                    depth_or_array_layers: 1,
                },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: wgpu::TextureFormat::Bgra8Unorm,
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT
                    | wgpu::TextureUsages::TEXTURE_BINDING,
                view_formats: &[],
            };
            // SAFETY: device identity, format, size, and usage were checked
            // against the texture supplied by the paired native adapter.
            let texture = unsafe {
                self.device
                    .create_texture_from_hal::<wgpu_hal::api::Metal>(hal_texture, &descriptor)
            };
            let view = texture.create_view(&wgpu::TextureViewDescriptor::default());
            let mut target = self
                .target
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            *target = LiveRenderTarget {
                texture,
                view,
                copy_source: false,
                external: true,
                initialized: false,
            };
            Ok(())
        }

        /// Restore the renderer-owned target after the native texture is
        /// unregistered or becomes unavailable.
        pub fn detach_native_texture(&self) -> Result<(), LiveRenderError> {
            let texture = self.device.create_texture(&wgpu::TextureDescriptor {
                label: Some("project-ink-live-surface-fallback"),
                size: wgpu::Extent3d {
                    width: self.config.physical_width,
                    height: self.config.physical_height,
                    depth_or_array_layers: 1,
                },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: wgpu::TextureFormat::Bgra8Unorm,
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT
                    | wgpu::TextureUsages::TEXTURE_BINDING
                    | wgpu::TextureUsages::COPY_SRC,
                view_formats: &[],
            });
            let view = texture.create_view(&wgpu::TextureViewDescriptor::default());
            let mut target = self
                .target
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            *target = LiveRenderTarget {
                texture,
                view,
                copy_source: true,
                external: false,
                initialized: false,
            };
            drop(target);
            self.render_store(
                &self
                    .live_dabs
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner),
            )
        }

        /// Read back the bounded target for deterministic renderer tests and
        /// local spatial comparisons. This is never used on the pointer path.
        pub fn readback(&self) -> Result<Vec<u8>, LiveRenderError> {
            let width = self.config.physical_width;
            let height = self.config.physical_height;
            let target = self
                .target
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if !target.copy_source {
                return Err(LiveRenderError::GpuReadbackFailed);
            }
            let bytes_per_row = width.saturating_mul(4);
            let alignment = wgpu::COPY_BYTES_PER_ROW_ALIGNMENT;
            let padded_bytes_per_row = bytes_per_row.div_ceil(alignment) * alignment;
            let buffer = self.device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("project-ink-live-readback"),
                size: u64::from(padded_bytes_per_row) * u64::from(height),
                usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
                mapped_at_creation: false,
            });
            let mut encoder = self
                .device
                .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                    label: Some("project-ink-live-readback-encoder"),
                });
            encoder.copy_texture_to_buffer(
                target.texture.as_image_copy(),
                wgpu::ImageCopyBuffer {
                    buffer: &buffer,
                    layout: wgpu::ImageDataLayout {
                        offset: 0,
                        bytes_per_row: Some(padded_bytes_per_row),
                        rows_per_image: Some(height),
                    },
                },
                wgpu::Extent3d {
                    width,
                    height,
                    depth_or_array_layers: 1,
                },
            );
            self.queue.submit(Some(encoder.finish()));
            let slice = buffer.slice(..);
            let (sender, receiver) = std::sync::mpsc::channel();
            slice.map_async(wgpu::MapMode::Read, move |result| {
                let _ = sender.send(result);
            });
            self.device.poll(wgpu::Maintain::Wait);
            receiver
                .recv()
                .map_err(|_| LiveRenderError::GpuReadbackFailed)?
                .map_err(|_| LiveRenderError::GpuReadbackFailed)?;
            let mapped = slice.get_mapped_range();
            let mut pixels = Vec::with_capacity((bytes_per_row * height) as usize);
            for row in mapped
                .chunks_exact(padded_bytes_per_row as usize)
                .take(height as usize)
            {
                pixels.extend_from_slice(&row[..bytes_per_row as usize]);
            }
            drop(mapped);
            buffer.unmap();
            Ok(pixels)
        }
    }

    #[cfg(test)]
    mod store_tests {
        use super::*;

        #[test]
        fn external_texture_targets_do_not_block_dab_submission() {
            assert!(matches!(poll_mode_for_target(true), wgpu::Maintain::Poll));
            assert!(matches!(poll_mode_for_target(false), wgpu::Maintain::Poll));
        }
        use crate::DabPhase;

        fn dab(sequence: u32) -> LiveDab {
            LiveDab {
                stroke_id: 7,
                sequence,
                dab_index: 0,
                x: 10.0,
                y: 20.0,
                radius: 4.0,
                opacity: 1.0,
                rotation: 0.0,
                color: [0, 0, 0, 255],
                phase: DabPhase::Confirmed,
            }
        }

        #[test]
        fn rebuilding_after_removal_keeps_dab_identity_indices_current() {
            let first = dab(1);
            let second = dab(2);
            let mut store = LiveDabStore {
                dabs: vec![first, second],
                indices: HashMap::new(),
            };
            store.rebuild_indices();

            store.dabs.remove(0);
            store.rebuild_indices();

            assert_eq!(store.indices.get(&(7, 2, 0)), Some(&0));
            assert!(!store.indices.contains_key(&(7, 1, 0)));
        }

        #[test]
        fn gpu_preview_uses_brush_color_and_circular_coverage() {
            let Ok(surface) = GpuLiveSurface::new(LiveSurfaceConfig {
                physical_width: 64,
                physical_height: 64,
                scale_milli: 1000,
            }) else {
                // Headless CI runners without a graphics adapter still run
                // the protocol and CPU fallback tests.
                return;
            };
            surface
                .render(&[LiveDab {
                    stroke_id: 7,
                    sequence: 1,
                    dab_index: 0,
                    x: 32.0,
                    y: 32.0,
                    radius: 10.0,
                    opacity: 1.0,
                    rotation: 0.0,
                    color: [10, 120, 240, 255],
                    phase: DabPhase::Confirmed,
                }])
                .expect("render one dab");
            let pixels = surface.readback().expect("readback for test");
            let pixel = |x: usize, y: usize| {
                let offset = (y * 64 + x) * 4;
                &pixels[offset..offset + 4]
            };

            assert_eq!(pixel(32, 32), [240, 120, 10, 255]);
            assert_eq!(pixel(41, 41)[3], 0, "square corners must be transparent");
            assert_eq!(pixel(10, 10)[3], 0, "outside the dab must be transparent");
        }

        #[test]
        fn append_only_batches_match_a_full_overlay_rebuild() {
            let Ok(surface) = GpuLiveSurface::new(LiveSurfaceConfig {
                physical_width: 64,
                physical_height: 64,
                scale_milli: 1000,
            }) else {
                return;
            };
            let first = LiveDab {
                stroke_id: 7,
                sequence: 1,
                dab_index: 0,
                x: 24.0,
                y: 32.0,
                radius: 12.0,
                opacity: 0.5,
                rotation: 0.0,
                color: [255, 0, 0, 255],
                phase: DabPhase::Confirmed,
            };
            let second = LiveDab {
                stroke_id: 7,
                sequence: 2,
                dab_index: 0,
                x: 40.0,
                y: 32.0,
                color: [0, 0, 255, 255],
                ..first
            };

            surface.render(&[first]).expect("append first dab");
            surface.render(&[second]).expect("append second dab");
            let incremental = surface.readback().expect("read back appended dabs");

            surface
                .set_viewport([1.0, 0.0, 0.0, 1.0, 0.0, 0.0], 1)
                .expect("force deterministic full rebuild");
            let rebuilt = surface.readback().expect("read back rebuilt overlay");
            assert_eq!(incremental, rebuilt);
        }

        #[test]
        fn multiple_dabs_from_one_input_sample_keep_distinct_preview_pixels() {
            let Ok(surface) = GpuLiveSurface::new(LiveSurfaceConfig {
                physical_width: 64,
                physical_height: 64,
                scale_milli: 1000,
            }) else {
                return;
            };
            let first = LiveDab {
                stroke_id: 71,
                sequence: 12,
                dab_index: 0,
                x: 16.0,
                y: 32.0,
                radius: 5.0,
                opacity: 1.0,
                rotation: 0.0,
                color: [0, 0, 0, 255],
                phase: crate::DabPhase::Confirmed,
            };
            let second = LiveDab {
                dab_index: 1,
                x: 48.0,
                ..first
            };

            surface
                .render(&[first, second])
                .expect("render all dabs from one input sample");
            let pixels = surface.readback().expect("read back both dab centers");
            assert_eq!(pixels[(32 * 64 + 16) * 4 + 3], 255);
            assert_eq!(pixels[(32 * 64 + 48) * 4 + 3], 255);
        }

        #[test]
        fn gpu_preview_applies_the_latest_document_to_surface_transform() {
            let Ok(surface) = GpuLiveSurface::new(LiveSurfaceConfig {
                physical_width: 64,
                physical_height: 64,
                scale_milli: 1000,
            }) else {
                return;
            };
            surface
                .set_viewport([1.0, 0.0, 0.0, 1.0, 16.0, 8.0], 1)
                .expect("set viewport");
            surface
                .render(&[LiveDab {
                    stroke_id: 7,
                    sequence: 1,
                    dab_index: 0,
                    x: 8.0,
                    y: 8.0,
                    radius: 4.0,
                    opacity: 1.0,
                    rotation: 0.0,
                    color: [255, 0, 0, 255],
                    phase: DabPhase::Confirmed,
                }])
                .expect("render transformed dab");

            let pixels = surface.readback().expect("readback for test");
            let alpha_at = |x: usize, y: usize| pixels[(y * 64 + x) * 4 + 3];
            assert_eq!(alpha_at(24, 16), 255);
            assert_eq!(alpha_at(8, 8), 0);
            surface
                .set_viewport([1.0, 0.0, 0.0, 1.0, 24.0, 24.0], 2)
                .expect("update viewport with an active dab");
            let pixels = surface.readback().expect("readback after viewport move");
            let alpha_at = |x: usize, y: usize| pixels[(y * 64 + x) * 4 + 3];
            assert_eq!(alpha_at(32, 32), 255);
            assert_eq!(alpha_at(24, 16), 0);
            assert_eq!(
                surface.set_viewport([1.0, 0.0, 0.0, 1.0, 0.0, 0.0], 0),
                Err(LiveRenderError::StaleViewportGeneration)
            );
        }

        #[test]
        fn acknowledgement_and_cancellation_repaint_the_overlay() {
            let Ok(surface) = GpuLiveSurface::new(LiveSurfaceConfig {
                physical_width: 64,
                physical_height: 64,
                scale_milli: 1000,
            }) else {
                return;
            };
            let dab = LiveDab {
                stroke_id: 7,
                sequence: 1,
                dab_index: 0,
                x: 32.0,
                y: 32.0,
                radius: 8.0,
                opacity: 1.0,
                rotation: 0.0,
                color: [255, 0, 0, 255],
                phase: DabPhase::Confirmed,
            };
            surface.render(&[dab]).expect("render initial dab");
            surface
                .acknowledge(dab.stroke_id, dab.sequence)
                .expect("acknowledge and clear dab");
            let pixels = surface.readback().expect("readback after ack");
            assert_eq!(pixels[(32 * 64 + 32) * 4 + 3], 0);

            surface.render(&[dab]).expect("render dab to cancel");
            surface
                .cancel_stroke(dab.stroke_id)
                .expect("cancel and clear stroke");
            let pixels = surface.readback().expect("readback after cancel");
            assert_eq!(pixels[(32 * 64 + 32) * 4 + 3], 0);
        }

        #[test]
        fn confirmed_sample_replaces_its_predicted_preview_without_a_ghost() {
            let Ok(surface) = GpuLiveSurface::new(LiveSurfaceConfig {
                physical_width: 64,
                physical_height: 64,
                scale_milli: 1000,
            }) else {
                return;
            };
            let predicted = LiveDab {
                stroke_id: 17,
                sequence: 9,
                dab_index: 0,
                x: 16.0,
                y: 16.0,
                radius: 5.0,
                opacity: 1.0,
                rotation: 0.0,
                color: [255, 0, 0, 255],
                phase: DabPhase::Predicted,
            };
            surface
                .render(&[predicted])
                .expect("render predicted preview");
            let confirmed = LiveDab {
                x: 40.0,
                phase: DabPhase::Confirmed,
                ..predicted
            };
            surface
                .render(&[confirmed])
                .expect("replace prediction with confirmed sample");

            let pixels = surface.readback().expect("read back handoff");
            let alpha_at = |x: usize, y: usize| pixels[(y * 64 + x) * 4 + 3];
            assert_eq!(alpha_at(16, 16), 0, "stale prediction left a ghost");
            assert_eq!(alpha_at(40, 16), 255, "confirmed dab is not visible");
        }
    }
}

#[cfg(feature = "gpu")]
pub use gpu::GpuLiveSurface;

impl LiveDabQueue {
    pub fn new(capacity: usize) -> Result<Self, LiveRenderError> {
        if capacity == 0 {
            return Err(LiveRenderError::ConfirmedQueueFull);
        }
        Ok(Self {
            capacity,
            dabs: VecDeque::with_capacity(capacity),
        })
    }

    /// Push one dab. Predicted dabs are discarded first when pressure builds;
    /// confirmed dabs are never silently discarded.
    pub fn push(&mut self, dab: LiveDab) -> Result<(), LiveRenderError> {
        let dab = dab.validate()?;
        if self.dabs.len() >= self.capacity {
            if let Some(index) = self
                .dabs
                .iter()
                .position(|candidate| candidate.phase == DabPhase::Predicted)
            {
                self.dabs.remove(index);
            } else if dab.phase == DabPhase::Predicted {
                return Ok(());
            } else {
                return Err(LiveRenderError::ConfirmedQueueFull);
            }
        }
        self.dabs.push_back(dab);
        Ok(())
    }

    pub fn drain(&mut self, limit: usize) -> Vec<LiveDab> {
        let count = limit.min(self.dabs.len());
        self.dabs.drain(..count).collect()
    }

    /// Drop queued preview records for a document stroke that was cancelled
    /// before Flutter had a chance to drain them. This affects only the
    /// transient GPU-preview stream; the command path separately restores CPU
    /// document tiles and undo state.
    pub fn remove_stroke(&mut self, stroke_id: u128) {
        self.dabs.retain(|dab| dab.stroke_id != stroke_id);
    }

    pub fn len(&self) -> usize {
        self.dabs.len()
    }

    pub fn is_empty(&self) -> bool {
        self.dabs.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dab(sequence: u32, phase: DabPhase) -> LiveDab {
        LiveDab {
            stroke_id: 1,
            sequence,
            dab_index: 0,
            x: 10.0,
            y: 20.0,
            radius: 4.0,
            opacity: 1.0,
            rotation: 0.0,
            color: [0, 0, 0, 255],
            phase,
        }
    }

    #[test]
    fn predicted_samples_are_evicted_before_confirmed_samples() {
        let mut queue = LiveDabQueue::new(2).expect("queue");
        queue.push(dab(1, DabPhase::Predicted)).expect("predicted");
        queue.push(dab(2, DabPhase::Confirmed)).expect("confirmed");
        queue.push(dab(3, DabPhase::Confirmed)).expect("confirmed");
        let output = queue.drain(8);
        assert_eq!(
            output.iter().map(|dab| dab.sequence).collect::<Vec<_>>(),
            [2, 3]
        );
    }

    #[test]
    fn confirmed_overflow_is_explicit() {
        let mut queue = LiveDabQueue::new(1).expect("queue");
        queue.push(dab(1, DabPhase::Confirmed)).expect("confirmed");
        assert_eq!(
            queue.push(dab(2, DabPhase::Confirmed)),
            Err(LiveRenderError::ConfirmedQueueFull)
        );
    }

    #[test]
    fn surface_limits_are_bounded() {
        assert!(
            LiveSurfaceConfig {
                physical_width: 8192,
                physical_height: 8192,
                scale_milli: 1000,
            }
            .validate()
            .is_ok()
        );
        assert_eq!(
            LiveSurfaceConfig {
                physical_width: 8193,
                physical_height: 1,
                scale_milli: 1000,
            }
            .validate(),
            Err(LiveRenderError::InvalidSurface)
        );
    }

    #[test]
    fn cancelled_stroke_records_can_be_removed_before_the_gpu_drain() {
        let mut queue = LiveDabQueue::new(4).expect("queue");
        queue.push(dab(1, DabPhase::Confirmed)).expect("confirmed");
        queue.remove_stroke(1);
        assert!(queue.is_empty());
    }
}
