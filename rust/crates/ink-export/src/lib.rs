//! Deterministic image export policy and PNG encoder.

#![allow(missing_docs)]
#![allow(
    clippy::missing_errors_doc,
    clippy::missing_panics_doc,
    clippy::must_use_candidate
)]

use base64::Engine;
use jpeg_encoder::{ColorType, Encoder as JpegEncoder};
use std::fmt;
use std::fs::{File, OpenOptions};
use std::io::{Cursor, Write};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use zip::{CompressionMethod, ZipWriter, write::SimpleFileOptions};

/// Maximum projected memory for importing one flattened PSD. The projection
/// includes the encoded source, decoded RGBA pixels, and the initial raster
/// layer tiles that are built from those pixels.
pub const MAX_PSD_IMPORT_WORKING_SET_BYTES: u64 = 768 * 1024 * 1024;
const MAX_PSD_PIXELS: u64 = 64 * 1024 * 1024;
const MAX_PSD_SOURCE_BYTES: usize = 512 * 1024 * 1024;
const MAX_PSD_PARSER_WORKING_SET_BYTES: u64 = MAX_PSD_IMPORT_WORKING_SET_BYTES;
const PSD_PARSER_METADATA_RESERVE_BYTES: u64 = 64 * 1024 * 1024;
const PSD_TILE_SIZE: u64 = 256;
/// Peak in-memory estimate accepted while building one editable PSD.
pub const MAX_PSD_EXPORT_WORKING_SET_BYTES: u64 = 768 * 1024 * 1024;
const MAX_PSD_EXPORT_LAYERS: usize = 1_024;
const MAX_PSD_EXPORT_DEPTH: usize = 32;
static PSD_EXPORT_TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(1);

/// One bounded layer projection from a PSD compatibility inspection.
#[derive(Clone, Debug, Eq, PartialEq)]
#[allow(clippy::struct_excessive_bools)] // Independent PSD layer flags are required in the inspection report.
pub struct PsdLayerInspection {
    /// Source layer name, truncated to 256 Unicode scalar values.
    pub name: String,
    /// Nesting depth in the source's group hierarchy.
    pub depth: u16,
    /// `true` for a PSD folder record.
    pub is_group: bool,
    /// Layer rectangle's left edge in document pixels.
    pub left: i32,
    /// Layer rectangle's top edge in document pixels.
    pub top: i32,
    /// Layer rectangle width in pixels.
    pub width: u32,
    /// Layer rectangle height in pixels.
    pub height: u32,
    /// Source visibility flag.
    pub visible: bool,
    /// Source opacity from 0 through 255.
    pub opacity: u8,
    /// Source blend mode key.
    pub blend_mode: String,
    /// Whether a raster user mask exists.
    pub has_raster_mask: bool,
    /// Whether the layer clips to the preceding base layer.
    pub clipping: bool,
    /// Whether the source marks transparency protected.
    pub alpha_locked: bool,
    /// Whether the source sets Photoshop's composite protection bit.
    pub whole_layer_locked: bool,
}

/// Read-only compatibility report for a Photoshop PSD import candidate.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PsdImportInspection {
    /// Image width in pixels.
    pub width: u32,
    /// Image height in pixels.
    pub height: u32,
    /// PSD channel bit depth.
    pub depth: u16,
    /// Number of merged-image channels.
    pub channels: u16,
    /// Source color mode name.
    pub color_mode: String,
    /// File-order layer projections, including group folder records.
    pub layers: Vec<PsdLayerInspection>,
    /// Number of user-visible layer and group nodes, excluding group divider records.
    pub logical_layer_count: usize,
    /// Features accepted by the current editable subset.
    pub supported_features: Vec<String>,
    /// Features that prevent the complete editable import subset.
    pub incompatibilities: Vec<String>,
    /// Reasons the explicitly selected flattened import is unavailable.
    pub flattened_import_issues: Vec<String>,
    /// Conservative editable-import peak projection in bytes.
    pub estimated_editable_working_set_bytes: u64,
    /// Conservative flattened-import peak projection in bytes.
    pub estimated_flattened_working_set_bytes: u64,
    /// Whether all live layer structures fit the documented editable subset.
    pub editable_import_available: bool,
    /// Whether the merged composite can be explicitly imported as one raster.
    pub flattened_import_available: bool,
}

/// One decoded PSD layer for candidate construction. Pixel and mask samples
/// are straight, row-major RGBA8 and grayscale bytes respectively; the engine
/// converts color to premultiplied BGRA exactly once when binding tiles.
#[derive(Clone, Debug, Eq, PartialEq)]
#[allow(clippy::struct_excessive_bools)] // These are independent PSD layer flags carried losslessly to candidate construction.
pub struct PsdEditableLayer {
    /// Position in the decoded editable-layer list, assigned from the PSD
    /// layer tree rather than its special-record-inclusive raw layer array.
    pub source_index: usize,
    /// Parent group position in the decoded editable-layer list.
    pub parent_index: Option<usize>,
    /// Source name.
    pub name: String,
    /// Nesting depth in the source group tree.
    pub depth: u16,
    /// `true` for a group folder record.
    pub is_group: bool,
    /// Layer origin in document pixels.
    pub left: i32,
    /// Layer origin in document pixels.
    pub top: i32,
    /// Decoded source-layer width in pixels, excluding document margins.
    pub width: u32,
    /// Decoded source-layer height in pixels, excluding document margins.
    pub height: u32,
    /// Layer visibility.
    pub visible: bool,
    /// Opacity from 0 through 255.
    pub opacity: u8,
    /// Supported Ink blend mode name.
    pub blend_mode: String,
    /// Alpha lock flag.
    pub alpha_locked: bool,
    /// Whole-layer lock flag.
    pub whole_layer_locked: bool,
    /// Whether the layer clips to the preceding base layer.
    pub clipping: bool,
    /// Layer pixels in straight RGBA8; empty for groups.
    pub rgba: Vec<u8>,
    /// Optional mask bounds and grayscale samples.
    pub mask: Option<PsdEditableMask>,
}

/// Decoded simple grayscale PSD layer mask.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PsdEditableMask {
    /// Whether the PSD mask is enabled for compositing.
    pub enabled: bool,
    /// Mask origin in document pixels.
    pub left: i32,
    /// Mask origin in document pixels.
    pub top: i32,
    /// Mask width.
    pub width: u32,
    /// Mask height.
    pub height: u32,
    /// Mask samples in row-major order.
    pub samples: Vec<u8>,
    /// Value outside the mask bounds.
    pub default_value: u8,
}

/// Supported editable PSD records decoded for engine candidate construction.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PsdEditableImport {
    /// Document width.
    pub width: u32,
    /// Document height.
    pub height: u32,
    /// Layers in PSD file order, including group records.
    pub layers: Vec<PsdEditableLayer>,
}

fn parse_solid_color_fill_rgb(block: &photocraft_psd::TaggedBlock) -> Option<[u8; 3]> {
    use photocraft_psd::descriptor::{Value, VersionedDescriptor};

    fn component(descriptor: &photocraft_psd::Descriptor, key: &str) -> Option<u8> {
        let value = match descriptor.get(key)? {
            Value::Double(value) => *value,
            Value::Integer(value) => f64::from(*value),
            _ => return None,
        };
        if !value.is_finite() || !(0.0..=255.0).contains(&value) {
            return None;
        }
        Some(rgb_channel_from_bounded_float(value))
    }

    let versioned = VersionedDescriptor::from_bytes(&block.data).ok()?;
    let Some(Value::Descriptor(color)) = versioned.descriptor.get("Clr ") else {
        return None;
    };
    if !color.class_id.is("RGBC") {
        return None;
    }
    Some([
        component(color, "Rd  ")?,
        component(color, "Grn ")?,
        component(color, "Bl  ")?,
    ])
}

#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
fn rgb_channel_from_bounded_float(value: f64) -> u8 {
    // Callers validate the finite value is in [0, 255], so rounding and
    // converting to u8 cannot truncate out of range or produce a negative.
    value.round() as u8
}

/// Blend modes supported by editable PSD export.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PsdExportBlendMode {
    /// Normal compositing.
    Normal,
    /// Multiply compositing.
    Multiply,
    /// Screen compositing.
    Screen,
    /// Photoshop pass-through group compositing.
    PassThrough,
}

/// A raster layer or group in a bounded editable PSD export request.
#[derive(Clone, Debug, Eq, PartialEq)]
#[allow(clippy::struct_excessive_bools)]
pub struct PsdExportLayer {
    /// Stable nonzero identity within this export request.
    pub id: u128,
    /// Parent group identity, or `None` for a document-level layer.
    pub parent: Option<u128>,
    /// Sibling ordering from bottom to top.
    pub order: u32,
    /// Layer or group name.
    pub name: String,
    /// Left offset in document pixels; ignored for groups.
    pub left: i32,
    /// Top offset in document pixels; ignored for groups.
    pub top: i32,
    /// Raster pixel width; ignored for groups.
    pub width: u32,
    /// Raster pixel height; ignored for groups.
    pub height: u32,
    /// `true` for a group; groups have no pixel or mask data.
    pub is_group: bool,
    /// Group uses pass-through compositing when true.
    pub pass_through: bool,
    /// Straight-alpha RGBA8 full-canvas pixels; empty for groups.
    pub rgba: Vec<u8>,
    /// Layer visibility.
    pub visible: bool,
    /// Layer opacity on the `0..=65535` Ink scale.
    pub opacity: u16,
    /// Supported layer/group blend mode.
    pub blend_mode: PsdExportBlendMode,
    /// Alpha lock state.
    pub alpha_locked: bool,
    /// Whole-layer lock state.
    pub whole_layer_locked: bool,
    /// Clipping-to-layer-below state; groups may not be clipped.
    pub clipping: bool,
    /// Optional raster mask; groups do not support masks in this subset.
    pub mask: Option<PsdEditableMask>,
}

/// Coherent editable PSD export request.
#[derive(Clone, Debug, PartialEq)]
pub struct PsdExportDocument {
    /// Canvas width in pixels.
    pub width: u32,
    /// Canvas height in pixels.
    pub height: u32,
    /// Resolution in dots per inch.
    pub dpi: f32,
    /// Layer tree in parent-first order.
    pub layers: Vec<PsdExportLayer>,
    /// Authoritative merged straight-alpha RGBA8 composite.
    pub composite_rgba: Vec<u8>,
}

/// Reject PSD dimensions whose source and initial raster copy exceed the
/// import working-set budget. The caller may use this after reading only the
/// PSD header so an oversized source is rejected before loading the file.
pub fn validate_psd_import_budget(
    encoded_bytes: u64,
    width: u32,
    height: u32,
) -> Result<(), ExportError> {
    if width == 0 || height == 0 || width > 32_768 || height > 32_768 {
        return Err(ExportError::InvalidPsd("dimensions outside safety limits"));
    }
    let pixels = u64::from(width) * u64::from(height);
    if pixels > MAX_PSD_PIXELS {
        return Err(ExportError::InvalidPsd(
            "pixel count exceeds the 64 megapixel safety limit",
        ));
    }
    let projected_bytes = pixels
        .checked_mul(8)
        .and_then(|decoded_and_layer_bytes| encoded_bytes.checked_add(decoded_and_layer_bytes))
        .ok_or(ExportError::InvalidPsd("projected import size overflows"))?;
    if projected_bytes > MAX_PSD_IMPORT_WORKING_SET_BYTES {
        return Err(ExportError::InvalidPsd(
            "projected import memory exceeds the 768 MiB safety limit",
        ));
    }
    Ok(())
}

/// Inspect a PSD's layer tree and report whether the current editable subset
/// or an explicitly selected flattened import is available. The parser is
/// bounded before parsing, and merged pixels are decoded only when their
/// projected working set fits the shared import budget.
#[allow(clippy::too_many_lines)] // Keep ordered parsing, feature classification, and budgeting together.
pub fn inspect_psd(bytes: &[u8]) -> Result<PsdImportInspection, ExportError> {
    if bytes.len() > MAX_PSD_SOURCE_BYTES {
        return Err(ExportError::InvalidPsd("source exceeds the 512 MiB limit"));
    }
    if bytes.len() < 26 || &bytes[..4] != b"8BPS" {
        return Err(ExportError::InvalidPsd("missing signature or header"));
    }
    let width = u32::from_be_bytes([bytes[18], bytes[19], bytes[20], bytes[21]]);
    let height = u32::from_be_bytes([bytes[14], bytes[15], bytes[16], bytes[17]]);
    validate_psd_import_budget(
        u64::try_from(bytes.len()).unwrap_or(u64::MAX),
        width,
        height,
    )?;
    let parser_projection = u64::try_from(bytes.len())
        .unwrap_or(u64::MAX)
        .checked_mul(2)
        .and_then(|value| value.checked_add(PSD_PARSER_METADATA_RESERVE_BYTES))
        .ok_or(ExportError::InvalidPsd(
            "parser working-set estimate overflows",
        ))?;
    if parser_projection > MAX_PSD_PARSER_WORKING_SET_BYTES {
        return Err(ExportError::UnsupportedPsd(
            "source and bounded parser model exceed the 768 MiB working-set limit",
        ));
    }

    let source = photocraft_psd::PsdFile::from_bytes(bytes)
        .map_err(|_| ExportError::InvalidPsd("PhotoCraft PSD parser rejected the file"))?;
    let header = &source.header;
    let pixel_count = u64::from(header.width)
        .checked_mul(u64::from(header.height))
        .ok_or(ExportError::InvalidPixelLength)?;
    let mut incompatibilities = Vec::new();
    let mut flattened_import_issues = Vec::new();
    let mut supported_features = vec![
        "PSD version 1 structure".into(),
        "RGB, 8-bit pixels".into(),
        "raster layer names, order, offsets, visibility and opacity".into(),
        "Normal, Multiply and Screen blend modes".into(),
        "whole-layer and alpha locks".into(),
    ];
    if header.version != photocraft_psd::Version::Psd {
        incompatibilities.push("PSB version 2 is outside the editable PSD subset.".into());
    }
    if header.color_mode != photocraft_psd::ColorMode::Rgb {
        incompatibilities.push("Only RGB color mode is supported for editable import.".into());
    }
    if header.depth != 8 {
        incompatibilities.push("Only 8-bit channels are supported for editable import.".into());
    }
    if source.icc_profile().is_some() {
        incompatibilities
            .push("An embedded ICC profile is present; color conversion is not available.".into());
    }
    let layers = source.layers();
    let tree = source.layer_tree();
    let logical_layer_count = tree.iter().map(photocraft_psd::LayerNode::count).sum();
    if logical_layer_count > 1_024 {
        incompatibilities.push("The document exceeds the 1,024-layer import limit.".into());
    }
    let mut depths = vec![0_u16; layers.len()];
    for node in &tree {
        collect_psd_layer_depths(node, 0, &mut depths);
    }
    let mut layer_projections = Vec::with_capacity(layers.len());
    let mut decoded_channel_bytes = 0_u64;
    let mut decoded_rgba_bytes = 0_u64;
    let mut decoded_mask_bytes = 0_u64;
    let mut candidate_tile_bytes = 0_u64;
    let mut solid_color_fill_count = 0_usize;
    for (index, layer) in layers.iter().enumerate() {
        let group = matches!(
            layer.section_type(),
            photocraft_psd::tagged::SectionType::BoundingDivider
                | photocraft_psd::tagged::SectionType::OpenFolder
                | photocraft_psd::tagged::SectionType::ClosedFolder
        );
        let rect = layer.rect;
        let (layer_width, layer_height) = rect
            .size()
            .map_err(|_| ExportError::InvalidPsd("layer bounds are invalid"))?;
        let width = u32::try_from(layer_width)
            .map_err(|_| ExportError::InvalidPsd("layer width overflows"))?;
        let height = u32::try_from(layer_height)
            .map_err(|_| ExportError::InvalidPsd("layer height overflows"))?;
        if !group && (layer_width > 32_768 || layer_height > 32_768) {
            incompatibilities.push(format!(
                "Layer {} exceeds the 32,768-pixel dimension limit.",
                index + 1
            ));
        }
        if !matches!(
            layer.blend_mode,
            photocraft_psd::BlendMode::Normal
                | photocraft_psd::BlendMode::Multiply
                | photocraft_psd::BlendMode::Screen
                | photocraft_psd::BlendMode::PassThrough
        ) {
            incompatibilities.push(format!(
                "Layer {} uses unsupported blend mode {}.",
                index + 1,
                String::from_utf8_lossy(&layer.blend_mode.key())
            ));
        }
        if !group && layer.blend_mode == photocraft_psd::BlendMode::PassThrough {
            incompatibilities.push(format!(
                "Raster layer {} uses the group-only Pass Through mode.",
                index + 1
            ));
        }
        if layer.clipping > 1 {
            incompatibilities.push(format!(
                "Layer {} has an invalid clipping-chain value.",
                index + 1
            ));
        }
        let has_non_default_blending_ranges = layer
            .blending_ranges
            .data
            .as_chunks::<8>()
            .0
            .iter()
            .any(|range| *range != [0, 0, 255, 255, 0, 0, 255, 255]);
        if has_non_default_blending_ranges {
            incompatibilities.push(format!(
                "Layer {} uses Photoshop Blend If ranges.",
                index + 1
            ));
        }
        let (has_raster_mask, has_unsupported_mask) = match &layer.mask {
            photocraft_psd::MaskData::None => (false, false),
            photocraft_psd::MaskData::Mask(mask) => {
                (true, mask.real.is_some() || mask.parameters.is_some())
            }
            photocraft_psd::MaskData::Raw(_) => (false, true),
        };
        if has_unsupported_mask || (group && has_raster_mask) {
            incompatibilities.push(format!(
                "Layer {} has a complex, malformed, or group mask outside the supported subset.",
                index + 1
            ));
        }
        let mut alpha_locked = layer.flags.transparency_protected();
        let mut whole_layer_locked = false;
        let mut solid_color_fill_blocks = 0_usize;
        let mut solid_color_fill_rgb = None;
        for block in &layer.blocks {
            match &block.key {
                b"lspf" => match block.parsed() {
                    Some(Ok(photocraft_psd::tagged::BlockData::Protection(flags))) => {
                        alpha_locked |= flags & 1 != 0;
                        whole_layer_locked |= flags & 2 != 0;
                        if flags & 4 != 0 {
                            incompatibilities.push(format!(
                                "Layer {} has a position lock without an Ink equivalent.",
                                index + 1
                            ));
                        }
                    }
                    _ => incompatibilities.push(format!(
                        "Layer {} has a malformed Photoshop lock record.",
                        index + 1
                    )),
                },
                b"TySh" => incompatibilities.push(format!(
                    "Layer {} contains editable Photoshop text.",
                    index + 1
                )),
                b"SoLd" | b"SoLE" | b"PlLd" => {
                    incompatibilities.push(format!("Layer {} contains a smart object.", index + 1));
                }
                b"vmsk" | b"vsms" => {
                    incompatibilities.push(format!("Layer {} contains a vector mask.", index + 1));
                }
                b"lrFX" | b"lfx2" | b"lmfx" => incompatibilities.push(format!(
                    "Layer {} contains Photoshop layer effects.",
                    index + 1
                )),
                b"SoCo" => {
                    solid_color_fill_blocks += 1;
                    solid_color_fill_rgb = parse_solid_color_fill_rgb(block);
                }
                b"brit" | b"levl" | b"curv" | b"hue2" | b"hue " | b"nvrt" | b"GdFl" | b"PtFl" => {
                    incompatibilities.push(format!(
                        "Layer {} is a Photoshop adjustment or fill layer.",
                        index + 1
                    ));
                }
                _ => {}
            }
        }
        if solid_color_fill_blocks > 0 {
            if !group && solid_color_fill_blocks == 1 && solid_color_fill_rgb.is_some() {
                solid_color_fill_count += 1;
            } else {
                incompatibilities.push(format!(
                    "Layer {} has a malformed or unsupported solid-color fill; only one RGB solid fill on a raster layer is supported.",
                    index + 1
                ));
            }
        }
        if !group {
            let layer_pixels = u64::from(width)
                .checked_mul(u64::from(height))
                .ok_or(ExportError::InvalidPixelLength)?;
            let tile_count_x = u64::from(width).div_ceil(PSD_TILE_SIZE);
            let tile_count_y = u64::from(height).div_ceil(PSD_TILE_SIZE);
            let layer_tiles = tile_count_x
                .checked_mul(tile_count_y)
                .and_then(|count| count.checked_mul(PSD_TILE_SIZE * PSD_TILE_SIZE * 4))
                .ok_or(ExportError::InvalidPixelLength)?;
            candidate_tile_bytes = candidate_tile_bytes
                .checked_add(layer_tiles)
                .ok_or(ExportError::InvalidPixelLength)?;
            for channel in &layer.channels {
                if channel.compression.is_none() {
                    continue;
                }
                let channel_rect = layer.channel_rect(channel.id);
                let (channel_width, channel_height) = channel_rect
                    .size()
                    .map_err(|_| ExportError::InvalidPsd("layer channel bounds are invalid"))?;
                decoded_channel_bytes = decoded_channel_bytes
                    .checked_add(psd_plane_bytes(
                        channel_width,
                        channel_height,
                        header.depth,
                    )?)
                    .ok_or(ExportError::InvalidPixelLength)?;
            }
            decoded_rgba_bytes = decoded_rgba_bytes
                .checked_add(
                    layer_pixels
                        .checked_mul(4)
                        .ok_or(ExportError::InvalidPixelLength)?,
                )
                .ok_or(ExportError::InvalidPixelLength)?;
            if has_raster_mask {
                let mask_channel = layer
                    .channels
                    .iter()
                    .find(|channel| matches!(channel.id, -2 | -3));
                if let Some(channel) = mask_channel {
                    let channel_rect = layer.channel_rect(channel.id);
                    let (mask_width, mask_height) = channel_rect
                        .size()
                        .map_err(|_| ExportError::InvalidPsd("layer mask bounds are invalid"))?;
                    decoded_mask_bytes = decoded_mask_bytes
                        .checked_add(
                            u64::try_from(mask_width)
                                .ok()
                                .and_then(|mask_width| {
                                    u64::try_from(mask_height)
                                        .ok()
                                        .and_then(|mask_height| mask_width.checked_mul(mask_height))
                                })
                                .ok_or(ExportError::InvalidPixelLength)?,
                        )
                        .ok_or(ExportError::InvalidPixelLength)?;
                }
            }
        }
        layer_projections.push(PsdLayerInspection {
            name: layer.name().chars().take(256).collect(),
            depth: depths.get(index).copied().unwrap_or(0),
            is_group: group,
            left: rect.left,
            top: rect.top,
            width,
            height,
            visible: layer.is_visible(),
            opacity: layer.opacity,
            blend_mode: String::from_utf8_lossy(&layer.blend_mode.key()).into_owned(),
            has_raster_mask,
            // Photoshop stores the clipping byte on folder records too, but
            // group records are not clipping layers. Treating that flag as a
            // group-level clip changes Photoshop's rendered result.
            clipping: !group && layer.clipping == 1,
            alpha_locked,
            whole_layer_locked,
        });
    }

    if solid_color_fill_count > 0 {
        supported_features.push(
            "Conversion: Solid-color fill layers are imported as paint layers. Their fill color is baked into pixels and cannot be edited as a fill after import.".into(),
        );
    }

    if layer_projections.iter().any(|layer| layer.clipping) {
        supported_features.push("layer clipping-chain records".into());
    }
    if source
        .layers()
        .iter()
        .any(|layer| matches!(layer.mask, photocraft_psd::MaskData::Mask(_)))
    {
        supported_features.push("simple raster layer masks".into());
    }
    let composite_bytes = psd_plane_bytes(
        usize::try_from(header.width).map_err(|_| ExportError::InvalidPixelLength)?,
        usize::try_from(header.height).map_err(|_| ExportError::InvalidPixelLength)?,
        header.depth,
    )?
    .checked_mul(u64::from(header.channels))
    .ok_or(ExportError::InvalidPixelLength)?;
    let common_bytes = parser_projection
        .checked_add(composite_bytes)
        .ok_or(ExportError::InvalidPixelLength)?;
    let editable_estimate = common_bytes
        .checked_add(decoded_channel_bytes)
        .and_then(|bytes| bytes.checked_add(decoded_rgba_bytes))
        .and_then(|bytes| bytes.checked_add(decoded_mask_bytes))
        .and_then(|bytes| bytes.checked_add(candidate_tile_bytes))
        .ok_or(ExportError::InvalidPixelLength)?;
    let flattened_estimate = common_bytes
        .checked_add(
            pixel_count
                .checked_mul(8)
                .ok_or(ExportError::InvalidPixelLength)?,
        )
        .ok_or(ExportError::InvalidPixelLength)?;
    if editable_estimate > MAX_PSD_IMPORT_WORKING_SET_BYTES {
        incompatibilities.push(
            "Editable layers exceed the 768 MiB parser, channel, and tile working-set limit."
                .into(),
        );
    }
    if source.has_real_merged_data() == Some(false) {
        flattened_import_issues.push("The PSD has no real merged composite.".into());
    }
    let merged_valid = if flattened_estimate <= MAX_PSD_IMPORT_WORKING_SET_BYTES
        && source.has_real_merged_data() != Some(false)
    {
        source.decode_merged().is_ok()
    } else {
        false
    };
    let base_rgb8 = header.version == photocraft_psd::Version::Psd
        && header.color_mode == photocraft_psd::ColorMode::Rgb
        && header.depth == 8;
    let flattened_import_available =
        base_rgb8 && merged_valid && flattened_estimate <= MAX_PSD_IMPORT_WORKING_SET_BYTES;
    if !merged_valid && flattened_import_issues.is_empty() {
        flattened_import_issues
            .push("The merged composite is invalid or exceeds the flattened-import budget.".into());
    }
    if flattened_estimate > MAX_PSD_IMPORT_WORKING_SET_BYTES {
        flattened_import_issues
            .push("Flattened import exceeds the 768 MiB working-set limit.".into());
    }
    if !base_rgb8 {
        flattened_import_issues
            .push("Flattened import currently requires PSD v1, RGB, 8-bit pixels.".into());
    }
    let editable_import_available =
        incompatibilities.is_empty() && editable_estimate <= MAX_PSD_IMPORT_WORKING_SET_BYTES;
    Ok(PsdImportInspection {
        width: header.width,
        height: header.height,
        depth: header.depth,
        channels: header.channels,
        color_mode: format!("{:?}", header.color_mode),
        layers: layer_projections,
        logical_layer_count,
        supported_features,
        incompatibilities,
        flattened_import_issues,
        estimated_editable_working_set_bytes: editable_estimate,
        estimated_flattened_working_set_bytes: flattened_estimate,
        editable_import_available,
        flattened_import_available,
    })
}

/// Decode a fully compatible PSD subset for construction of a candidate Ink
/// document. The current document is not touched; callers must still apply
/// the existing document replacement barrier and publish the candidate only
/// after it has been completely constructed.
pub fn decode_psd_editable(bytes: &[u8]) -> Result<PsdEditableImport, ExportError> {
    let inspection = inspect_psd(bytes)?;
    if !inspection.editable_import_available {
        return Err(ExportError::UnsupportedPsd(
            "PSD contains structures outside the editable import subset",
        ));
    }
    let source = photocraft_psd::PsdFile::from_bytes(bytes)
        .map_err(|_| ExportError::InvalidPsd("PhotoCraft PSD parser rejected the file"))?;
    let mut layers = Vec::with_capacity(source.layers().len());
    for node in source.layer_tree() {
        decode_psd_tree_node(&source, &inspection, &node, None, &mut layers)?;
    }
    Ok(PsdEditableImport {
        width: inspection.width,
        height: inspection.height,
        layers,
    })
}

fn decode_psd_tree_node(
    source: &photocraft_psd::PsdFile,
    inspection: &PsdImportInspection,
    node: &photocraft_psd::LayerNode,
    parent_index: Option<usize>,
    output: &mut Vec<PsdEditableLayer>,
) -> Result<(), ExportError> {
    let raw_index = node.index();
    let layer = source
        .layer(raw_index)
        .ok_or(ExportError::InvalidPsd("layer tree index is invalid"))?;
    let projected = inspection
        .layers
        .get(raw_index)
        .ok_or(ExportError::InvalidPsd("layer projection is incomplete"))?;
    let is_group = node.is_group();
    let (rgba, mask) = if is_group {
        (Vec::new(), None)
    } else {
        let image = layer
            .rgba8()
            .map_err(|_| ExportError::InvalidPsd("layer channel decoding failed"))?;
        let mut rgba = image.data;
        if let Some(color) = layer
            .record
            .blocks
            .iter()
            .find(|block| block.key == *b"SoCo")
            .and_then(parse_solid_color_fill_rgb)
        {
            let fill_opacity = layer.record.fill_opacity();
            for pixel in rgba.as_chunks_mut::<4>().0 {
                pixel[..3].copy_from_slice(&color);
                pixel[3] =
                    u8::try_from((u16::from(pixel[3]) * u16::from(fill_opacity) + 127) / 255)
                        .map_err(|_| {
                            ExportError::InvalidPsd("solid fill opacity overflows alpha")
                        })?;
            }
        }
        let mask = layer
            .user_mask()
            .map(|decoded| -> Result<PsdEditableMask, ExportError> {
                let image = decoded
                    .map_err(|_| ExportError::InvalidPsd("layer mask channel decoding failed"))?;
                Ok(PsdEditableMask {
                    enabled: !layer
                        .record
                        .layer_mask()
                        .is_some_and(photocraft_psd::LayerMask::disabled),
                    left: image.left,
                    top: image.top,
                    width: image.width,
                    height: image.height,
                    samples: image.data,
                    default_value: image.default_value,
                })
            })
            .transpose()?;
        (rgba, mask)
    };
    let source_index = output.len();
    output.push(PsdEditableLayer {
        source_index,
        parent_index,
        name: projected.name.clone(),
        depth: projected.depth,
        is_group,
        left: projected.left,
        top: projected.top,
        width: projected.width,
        height: projected.height,
        visible: projected.visible,
        opacity: projected.opacity,
        blend_mode: projected.blend_mode.clone(),
        alpha_locked: projected.alpha_locked,
        whole_layer_locked: projected.whole_layer_locked,
        clipping: projected.clipping,
        rgba,
        mask,
    });
    for child in node.children() {
        decode_psd_tree_node(source, inspection, child, Some(source_index), output)?;
    }
    Ok(())
}

fn collect_psd_layer_depths(node: &photocraft_psd::LayerNode, depth: u16, output: &mut [u16]) {
    if let Some(layer_depth) = output.get_mut(node.index()) {
        *layer_depth = depth;
    }
    if node.is_group() {
        for child in node.children() {
            collect_psd_layer_depths(child, depth.saturating_add(1), output);
        }
    }
}

fn psd_plane_bytes(width: usize, height: usize, depth: u16) -> Result<u64, ExportError> {
    let row_bits = u64::try_from(width)
        .map_err(|_| ExportError::InvalidPixelLength)?
        .checked_mul(u64::from(depth))
        .ok_or(ExportError::InvalidPixelLength)?;
    let row_bytes = row_bits.div_ceil(8);
    row_bytes
        .checked_mul(u64::try_from(height).map_err(|_| ExportError::InvalidPixelLength)?)
        .ok_or(ExportError::InvalidPixelLength)
}

/// Formats promised by the public plan.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ExportFormat {
    Png,
    Jpeg,
    Webp,
    OpenRaster,
    Svg,
    Psd,
}

/// Whether an export is available in the current phase.
#[must_use]
pub const fn supported_in_phase_one(format: ExportFormat) -> bool {
    matches!(format, ExportFormat::Png)
}

/// Formats implemented by the Phase 2 export boundary.
#[must_use]
pub const fn supported_in_phase_two(format: ExportFormat) -> bool {
    matches!(
        format,
        ExportFormat::Png
            | ExportFormat::Jpeg
            | ExportFormat::Webp
            | ExportFormat::OpenRaster
            | ExportFormat::Svg
            | ExportFormat::Psd
    )
}

/// PNG export failures.
#[derive(Debug)]
pub enum ExportError {
    Io(std::io::Error),
    Png(png::EncodingError),
    Jpeg(jpeg_encoder::EncodingError),
    Webp,
    Zip(zip::result::ZipError),
    InvalidPixelLength,
    InvalidPng(String),
    UnsafePath,
    InvalidPsd(&'static str),
    UnsupportedPsd(&'static str),
}

impl fmt::Display for ExportError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => error.fmt(f),
            Self::Png(error) => error.fmt(f),
            Self::Jpeg(error) => error.fmt(f),
            Self::Webp => f.write_str("WebP encoder rejected the image"),
            Self::Zip(error) => error.fmt(f),
            Self::InvalidPixelLength => {
                f.write_str("RGBA pixel buffer does not match image dimensions")
            }
            Self::InvalidPng(message) => write!(f, "invalid PNG: {message}"),
            Self::UnsafePath => f.write_str("PNG destination must not be a symlink"),
            Self::InvalidPsd(message) => write!(f, "invalid PSD: {message}"),
            Self::UnsupportedPsd(message) => write!(f, "unsupported PSD: {message}"),
        }
    }
}

/// Decode a flattened version-1, RGB, 8-bit PSD composite with three or four
/// channels into straight-alpha RGBA. Photoshop stores transparent RGB
/// composites matted against white, which is removed on read. Raw and
/// `PackBits` row-compressed composites are supported; ZIP compression and
/// higher depths remain unsupported. Layer records are ignored only because
/// this API explicitly returns the merged composite.
pub fn decode_psd(bytes: &[u8]) -> Result<(u32, u32, Vec<u8>), ExportError> {
    const HEADER: usize = 26;
    if bytes.len() < HEADER || &bytes[..4] != b"8BPS" {
        return Err(ExportError::InvalidPsd("missing signature"));
    }
    if u16::from_be_bytes([bytes[4], bytes[5]]) != 1 {
        return Err(ExportError::UnsupportedPsd("only version 1 is supported"));
    }
    let channels = u16::from_be_bytes([bytes[12], bytes[13]]);
    if !(channels == 3 || channels == 4) {
        return Err(ExportError::UnsupportedPsd(
            "RGB with three or four channels only",
        ));
    }
    let height = u32::from_be_bytes([bytes[14], bytes[15], bytes[16], bytes[17]]);
    let width = u32::from_be_bytes([bytes[18], bytes[19], bytes[20], bytes[21]]);
    validate_psd_import_budget(
        u64::try_from(bytes.len()).unwrap_or(u64::MAX),
        width,
        height,
    )?;
    if u16::from_be_bytes([bytes[22], bytes[23]]) != 8
        || u16::from_be_bytes([bytes[24], bytes[25]]) != 3
    {
        return Err(ExportError::UnsupportedPsd("8-bit RGB only"));
    }
    let mut cursor = HEADER;
    let read_u32 = |bytes: &[u8], cursor: &mut usize| -> Result<u32, ExportError> {
        let end = cursor
            .checked_add(4)
            .ok_or(ExportError::InvalidPsd("length overflow"))?;
        let value = bytes
            .get(*cursor..end)
            .ok_or(ExportError::InvalidPsd("truncated section length"))?;
        *cursor = end;
        Ok(u32::from_be_bytes([value[0], value[1], value[2], value[3]]))
    };
    for section in 0..3 {
        let length = usize::try_from(read_u32(bytes, &mut cursor)?)
            .map_err(|_| ExportError::InvalidPsd("section length overflow"))?;
        let end = cursor
            .checked_add(length)
            .ok_or(ExportError::InvalidPsd("section length overflow"))?;
        if end > bytes.len() {
            return Err(ExportError::InvalidPsd("truncated section"));
        }
        cursor = end;
        if section == 2 {
            break;
        }
    }
    let compression_bytes = bytes
        .get(cursor..cursor + 2)
        .ok_or(ExportError::InvalidPsd("missing image compression"))?;
    let compression = u16::from_be_bytes([compression_bytes[0], compression_bytes[1]]);
    cursor += 2;
    let pixel_count = usize::try_from(width)
        .ok()
        .and_then(|w| usize::try_from(height).ok().and_then(|h| w.checked_mul(h)))
        .ok_or(ExportError::InvalidPixelLength)?;
    if compression == 1 {
        let mut rgba = decode_psd_rle_rgba(bytes, cursor, width, height, channels, pixel_count)?;
        if channels == 4 {
            unmatte_psd_rgb(&mut rgba);
        }
        return Ok((width, height, rgba));
    }
    let planar = decode_psd_planar(bytes, cursor, width, height, channels, compression)?;
    let mut rgba = vec![
        0_u8;
        pixel_count
            .checked_mul(4)
            .ok_or(ExportError::InvalidPixelLength)?
    ];
    for index in 0..pixel_count {
        rgba[index * 4] = planar[index];
        rgba[index * 4 + 1] = planar[pixel_count + index];
        rgba[index * 4 + 2] = planar[pixel_count * 2 + index];
        rgba[index * 4 + 3] = if channels == 4 {
            planar[pixel_count * 3 + index]
        } else {
            u8::MAX
        };
    }
    if channels == 4 {
        unmatte_psd_rgb(&mut rgba);
    }
    Ok((width, height, rgba))
}

/// Convert Photoshop's white-matted RGB composite samples back to straight alpha.
fn unmatte_psd_rgb(rgba: &mut [u8]) {
    for pixel in rgba.as_chunks_mut::<4>().0 {
        let alpha = u32::from(pixel[3]);
        if alpha == 0 {
            continue;
        }
        for channel in pixel.iter_mut().take(3) {
            let value = u32::from(*channel);
            let straight = ((value + alpha).saturating_sub(255) * 255 + alpha / 2) / alpha;
            *channel = straight.min(255) as u8;
        }
    }
}

fn decode_psd_planar(
    bytes: &[u8],
    cursor: usize,
    width: u32,
    height: u32,
    channels: u16,
    compression: u16,
) -> Result<&[u8], ExportError> {
    if compression != 0 {
        return Err(ExportError::UnsupportedPsd(
            "ZIP-compressed composite images are not imported",
        ));
    }
    let channel_bytes = usize::try_from(width)
        .ok()
        .and_then(|w| usize::try_from(height).ok().and_then(|h| w.checked_mul(h)))
        .and_then(|pixels| pixels.checked_mul(usize::from(channels)))
        .ok_or(ExportError::InvalidPixelLength)?;
    let end = cursor
        .checked_add(channel_bytes)
        .ok_or(ExportError::InvalidPsd("pixel length overflow"))?;
    bytes
        .get(cursor..end)
        .ok_or(ExportError::InvalidPsd("truncated pixel data"))
}

fn decode_psd_rle_rgba(
    bytes: &[u8],
    cursor: usize,
    width: u32,
    height: u32,
    channels: u16,
    pixel_count: usize,
) -> Result<Vec<u8>, ExportError> {
    let row_width =
        usize::try_from(width).map_err(|_| ExportError::InvalidPsd("row width overflows"))?;
    let row_height =
        usize::try_from(height).map_err(|_| ExportError::InvalidPsd("row height overflows"))?;
    let row_count = row_height
        .checked_mul(usize::from(channels))
        .ok_or(ExportError::InvalidPsd("row count overflows"))?;
    let table_bytes = row_count
        .checked_mul(2)
        .ok_or(ExportError::InvalidPsd("row table length overflows"))?;
    let table_end = cursor
        .checked_add(table_bytes)
        .ok_or(ExportError::InvalidPsd("row table length overflows"))?;
    let row_table = bytes
        .get(cursor..table_end)
        .ok_or(ExportError::InvalidPsd("truncated RLE row table"))?;
    let rgba_len = pixel_count
        .checked_mul(4)
        .ok_or(ExportError::InvalidPixelLength)?;
    let mut rgba = Vec::new();
    rgba.try_reserve_exact(rgba_len)
        .map_err(|_| ExportError::InvalidPsd("unable to allocate decoded pixels"))?;
    rgba.resize(rgba_len, 0);
    if channels == 3 {
        for pixel in rgba.as_chunks_mut::<4>().0 {
            pixel[3] = u8::MAX;
        }
    }
    let mut decoded_row = Vec::new();
    decoded_row
        .try_reserve_exact(row_width)
        .map_err(|_| ExportError::InvalidPsd("unable to allocate decoded row"))?;
    decoded_row.resize(row_width, 0);
    let mut compressed_cursor = table_end;
    for row_index in 0..row_count {
        let table_offset = row_index
            .checked_mul(2)
            .ok_or(ExportError::InvalidPsd("row table offset overflows"))?;
        let compressed_length = usize::from(u16::from_be_bytes([
            row_table[table_offset],
            row_table[table_offset + 1],
        ]));
        let row_end = compressed_cursor
            .checked_add(compressed_length)
            .ok_or(ExportError::InvalidPsd("RLE row length overflows"))?;
        let encoded_row = bytes
            .get(compressed_cursor..row_end)
            .ok_or(ExportError::InvalidPsd("truncated RLE row"))?;
        decode_packbits_row(encoded_row, &mut decoded_row)?;
        let channel = row_index / row_height;
        let y = row_index % row_height;
        let row_pixel_start = y
            .checked_mul(row_width)
            .and_then(|index| index.checked_mul(4))
            .ok_or(ExportError::InvalidPsd("decoded row offset overflows"))?;
        for (x, value) in decoded_row.iter().copied().enumerate() {
            let output = row_pixel_start
                .checked_add(x.checked_mul(4).ok_or(ExportError::InvalidPixelLength)?)
                .and_then(|index| index.checked_add(channel))
                .ok_or(ExportError::InvalidPixelLength)?;
            let destination = rgba
                .get_mut(output)
                .ok_or(ExportError::InvalidPixelLength)?;
            *destination = value;
        }
        compressed_cursor = row_end;
    }
    Ok(rgba)
}

fn decode_packbits_row(encoded: &[u8], decoded: &mut [u8]) -> Result<(), ExportError> {
    let mut source = 0_usize;
    let mut destination = 0_usize;
    while source < encoded.len() {
        let header = i8::from_ne_bytes([encoded[source]]);
        source += 1;
        match header {
            0..=127 => {
                let count = usize::from(header.unsigned_abs()) + 1;
                let source_end = source
                    .checked_add(count)
                    .ok_or(ExportError::InvalidPsd("PackBits literal length overflows"))?;
                let destination_end = destination
                    .checked_add(count)
                    .ok_or(ExportError::InvalidPsd("PackBits output length overflows"))?;
                let literal = encoded
                    .get(source..source_end)
                    .ok_or(ExportError::InvalidPsd("truncated PackBits literal"))?;
                let output = decoded
                    .get_mut(destination..destination_end)
                    .ok_or(ExportError::InvalidPsd("PackBits row exceeds its width"))?;
                output.copy_from_slice(literal);
                source = source_end;
                destination = destination_end;
            }
            -127..=-1 => {
                let count = usize::from(header.unsigned_abs()) + 1;
                let value = *encoded
                    .get(source)
                    .ok_or(ExportError::InvalidPsd("truncated PackBits repeat"))?;
                let destination_end = destination
                    .checked_add(count)
                    .ok_or(ExportError::InvalidPsd("PackBits output length overflows"))?;
                let output = decoded
                    .get_mut(destination..destination_end)
                    .ok_or(ExportError::InvalidPsd("PackBits row exceeds its width"))?;
                output.fill(value);
                source += 1;
                destination = destination_end;
            }
            -128 => {}
        }
    }
    if destination != decoded.len() {
        return Err(ExportError::InvalidPsd(
            "PackBits row does not match its declared width",
        ));
    }
    Ok(())
}
impl std::error::Error for ExportError {}
impl From<std::io::Error> for ExportError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}
impl From<png::EncodingError> for ExportError {
    fn from(error: png::EncodingError) -> Self {
        Self::Png(error)
    }
}
impl From<jpeg_encoder::EncodingError> for ExportError {
    fn from(error: jpeg_encoder::EncodingError) -> Self {
        Self::Jpeg(error)
    }
}
impl From<zip::result::ZipError> for ExportError {
    fn from(error: zip::result::ZipError) -> Self {
        Self::Zip(error)
    }
}

/// Encode an RGBA8 image into deterministic PNG bytes.
pub fn encode_png(width: u32, height: u32, pixels_rgba: &[u8]) -> Result<Vec<u8>, ExportError> {
    let expected = usize::try_from(width)
        .ok()
        .and_then(|w| usize::try_from(height).ok().and_then(|h| w.checked_mul(h)))
        .and_then(|pixels| pixels.checked_mul(4))
        .ok_or(ExportError::InvalidPixelLength)?;
    if pixels_rgba.len() != expected {
        return Err(ExportError::InvalidPixelLength);
    }
    let mut bytes = Vec::new();
    {
        let cursor = Cursor::new(&mut bytes);
        let mut encoder = png::Encoder::new(cursor, width, height);
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);
        encoder.set_compression(png::Compression::Fast);
        let mut writer = encoder.write_header()?;
        writer.write_image_data(pixels_rgba)?;
    }
    Ok(bytes)
}

/// Decodes an RGBA8 PNG after checking its dimensions before allocating the
/// frame buffer. Other PNG pixel formats are rejected rather than converted
/// implicitly at the export boundary.
pub fn decode_png_rgba8(bytes: &[u8]) -> Result<(u32, u32, Vec<u8>), ExportError> {
    // The PNG reader may return a decoded frame even if the file is missing
    // the terminal IEND chunk. Export composition must reject incomplete
    // artifacts rather than treating a truncated file as a valid source.
    const IEND: &[u8; 12] = b"\0\0\0\0IEND\xaeB`\x82";
    if !bytes.ends_with(IEND) {
        return Err(ExportError::InvalidPng(
            "missing or truncated terminal IEND chunk".to_owned(),
        ));
    }
    let decoder = png::Decoder::new(Cursor::new(bytes));
    let mut reader = decoder
        .read_info()
        .map_err(|error| ExportError::InvalidPng(error.to_string()))?;
    let info = reader.info();
    if info.width == 0
        || info.height == 0
        || info.width > 32_768
        || info.height > 32_768
        || u64::from(info.width) * u64::from(info.height) > MAX_PSD_PIXELS
        || info.color_type != png::ColorType::Rgba
        || info.bit_depth != png::BitDepth::Eight
    {
        return Err(ExportError::InvalidPixelLength);
    }
    let size = reader.output_buffer_size();
    let expected = usize::try_from(info.width)
        .ok()
        .and_then(|width| {
            usize::try_from(info.height)
                .ok()
                .and_then(|height| width.checked_mul(height))
        })
        .and_then(|pixels| pixels.checked_mul(4))
        .ok_or(ExportError::InvalidPixelLength)?;
    if size != expected {
        return Err(ExportError::InvalidPixelLength);
    }
    let mut pixels = vec![0; size];
    let frame = reader
        .next_frame(&mut pixels)
        .map_err(|error| ExportError::InvalidPng(error.to_string()))?;
    if frame.buffer_size() != expected {
        return Err(ExportError::InvalidPixelLength);
    }
    Ok((frame.width, frame.height, pixels))
}

/// Write an RGBA8 image atomically enough for a caller-provided temporary path.
pub fn write_png(
    path: &Path,
    width: u32,
    height: u32,
    pixels_rgba: &[u8],
) -> Result<(), ExportError> {
    let bytes = encode_png(width, height, pixels_rgba)?;
    if let Ok(metadata) = std::fs::symlink_metadata(path)
        && (metadata.file_type().is_symlink() || !metadata.is_file())
    {
        return Err(ExportError::UnsafePath);
    }
    let mut file = File::create(path)?;
    file.write_all(&bytes)?;
    file.sync_all()?;
    Ok(())
}

/// Encode an RGB JPEG with deterministic quality settings.
pub fn encode_jpeg(width: u32, height: u32, pixels_rgba: &[u8]) -> Result<Vec<u8>, ExportError> {
    let expected = expected_len(width, height)?;
    if pixels_rgba.len() != expected {
        return Err(ExportError::InvalidPixelLength);
    }
    let rgb: Vec<u8> = pixels_rgba
        .as_chunks::<4>()
        .0
        .iter()
        .flat_map(|pixel| [pixel[0], pixel[1], pixel[2]])
        .collect();
    let width = u16::try_from(width).map_err(|_| ExportError::InvalidPixelLength)?;
    let height = u16::try_from(height).map_err(|_| ExportError::InvalidPixelLength)?;
    let mut bytes = Vec::new();
    JpegEncoder::new(&mut bytes, 92).encode(&rgb, width, height, ColorType::Rgb)?;
    Ok(bytes)
}

/// Encode a WebP image using the platform-independent `libwebp` wrapper.
pub fn encode_webp(width: u32, height: u32, pixels_rgba: &[u8]) -> Result<Vec<u8>, ExportError> {
    if pixels_rgba.len() != expected_len(width, height)? {
        return Err(ExportError::InvalidPixelLength);
    }
    let encoded = webp::Encoder::from_rgba(pixels_rgba, width, height).encode(90.0);
    if encoded.is_empty() {
        Err(ExportError::Webp)
    } else {
        Ok(encoded.to_vec())
    }
}

/// Encode a flattened `OpenRaster` document with a valid stack and merged image.
pub fn encode_open_raster(
    width: u32,
    height: u32,
    pixels_rgba: &[u8],
) -> Result<Vec<u8>, ExportError> {
    let png = encode_png(width, height, pixels_rgba)?;
    let mut bytes = Cursor::new(Vec::new());
    let mut writer = ZipWriter::new(&mut bytes);
    let stored = SimpleFileOptions::default().compression_method(CompressionMethod::Stored);
    writer.start_file("mimetype", stored)?;
    writer.write_all(b"image/openraster")?;
    let compressed = SimpleFileOptions::default().compression_method(CompressionMethod::Deflated);
    writer.start_file("stack.xml", compressed)?;
    writer.write_all(format!("<?xml version=\"1.0\" encoding=\"UTF-8\"?><image version=\"0.0.1\" w=\"{width}\" h=\"{height}\"><stack name=\"Project Ink\"><layer name=\"Merged\" src=\"data/mergedimage.png\"/></stack></image>").as_bytes())?;
    writer.start_file("data/mergedimage.png", compressed)?;
    writer.write_all(&png)?;
    writer.finish()?;
    Ok(bytes.into_inner())
}

/// Encode a portable SVG wrapper containing the exact raster composite.
pub fn encode_svg(width: u32, height: u32, pixels_rgba: &[u8]) -> Result<Vec<u8>, ExportError> {
    let png = encode_png(width, height, pixels_rgba)?;
    let encoded = base64::engine::general_purpose::STANDARD.encode(png);
    Ok(format!("<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" width=\"{width}\" height=\"{height}\" viewBox=\"0 0 {width} {height}\"><image width=\"{width}\" height=\"{height}\" href=\"data:image/png;base64,{encoded}\"/></svg>").into_bytes())
}

/// Encode a flattened, uncompressed RGB+alpha PSD compatible with common
/// illustration applications. Transparent RGB is matted against white in the
/// merged composite, as required by Photoshop's composite convention. Layer
/// structure remains intentionally limited.
pub fn encode_psd(width: u32, height: u32, pixels_rgba: &[u8]) -> Result<Vec<u8>, ExportError> {
    if pixels_rgba.len() != expected_len(width, height)? {
        return Err(ExportError::InvalidPixelLength);
    }
    let mut bytes = Vec::new();
    bytes.extend_from_slice(b"8BPS");
    bytes.extend_from_slice(&1_u16.to_be_bytes());
    bytes.extend_from_slice(&[0; 6]);
    bytes.extend_from_slice(&4_u16.to_be_bytes());
    bytes.extend_from_slice(&height.to_be_bytes());
    bytes.extend_from_slice(&width.to_be_bytes());
    bytes.extend_from_slice(&8_u16.to_be_bytes());
    bytes.extend_from_slice(&3_u16.to_be_bytes());
    bytes.extend_from_slice(&0_u32.to_be_bytes());
    bytes.extend_from_slice(&0_u32.to_be_bytes());
    bytes.extend_from_slice(&0_u32.to_be_bytes());
    bytes.extend_from_slice(&0_u16.to_be_bytes());
    let pixel_count = usize::try_from(width)
        .ok()
        .and_then(|w| usize::try_from(height).ok().and_then(|h| w.checked_mul(h)))
        .ok_or(ExportError::InvalidPixelLength)?;
    let pixels = pixels_rgba.as_chunks::<4>().0;
    for channel in 0..4 {
        bytes.extend(pixels.iter().map(|pixel| {
            if channel < 3 {
                matte_psd_rgb(pixel[channel], pixel[3])
            } else {
                pixel[channel]
            }
        }));
    }
    debug_assert_eq!(bytes.len(), 40 + pixel_count * 4);
    Ok(bytes)
}

/// Store the flattened PSD RGB composite against white while keeping its alpha plane.
fn matte_psd_rgb(color: u8, alpha: u8) -> u8 {
    if alpha == 0 {
        color
    } else {
        let color = u32::from(color);
        let alpha = u32::from(alpha);
        u8::try_from((color * alpha + 127) / 255 + 255 - alpha).unwrap_or(u8::MAX)
    }
}

/// Encode a supported editable layer tree and its actual merged composite.
///
/// The request is validated before `PsdBuilder` allocates channel planes. Each
/// raster buffer is a bounded straight-alpha RGBA8 image with a document
/// offset; masks may use their own bounded sub-rectangle. All nodes and the merged composite must correspond
/// to the same document revision, which the caller is responsible for
/// capturing atomically.
pub fn encode_editable_psd(document: &PsdExportDocument) -> Result<Vec<u8>, ExportError> {
    validate_psd_export(document)?;
    let mut builder = photocraft_psd::PsdBuilder::new(document.width, document.height)
        .resolution(f64::from(document.dpi));
    emit_psd_export_children(&mut builder, document, None, 0)?;
    builder.composite(photocraft_psd::PixelData::Rgba8(
        document.composite_rgba.clone(),
    ));
    builder
        .to_bytes()
        .map_err(|_| ExportError::InvalidPsd("editable PSD encoding failed"))
}

/// Write an editable PSD through a synced temporary sibling and atomic rename.
pub fn write_editable_psd(path: &Path, document: &PsdExportDocument) -> Result<(), ExportError> {
    if let Ok(metadata) = std::fs::symlink_metadata(path)
        && (metadata.file_type().is_symlink() || !metadata.is_file())
    {
        return Err(ExportError::UnsafePath);
    }
    let bytes = encode_editable_psd(document)?;
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    let name = path
        .file_name()
        .ok_or(ExportError::InvalidPsd("destination has no file name"))?;
    let mut temporary = None;
    for _ in 0..16 {
        let sequence = PSD_EXPORT_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let mut temp_name = name.to_os_string();
        temp_name.push(format!(
            ".project-ink-{}-{sequence}.tmp",
            std::process::id()
        ));
        let candidate = parent.join(temp_name);
        match OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&candidate)
        {
            Ok(mut file) => {
                if let Err(error) = file.write_all(&bytes).and_then(|()| file.sync_all()) {
                    let _ = std::fs::remove_file(&candidate);
                    return Err(ExportError::Io(error));
                }
                drop(file);
                temporary = Some(candidate);
                break;
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(ExportError::Io(error)),
        }
    }
    let temporary = temporary.ok_or(ExportError::InvalidPsd(
        "unable to create a unique temporary export file",
    ))?;
    if let Err(error) = std::fs::rename(&temporary, path) {
        let _ = std::fs::remove_file(&temporary);
        return Err(ExportError::Io(error));
    }
    if let Ok(directory) = File::open(parent) {
        directory.sync_all()?;
    }
    Ok(())
}

fn validate_psd_export(document: &PsdExportDocument) -> Result<(), ExportError> {
    if document.width == 0
        || document.height == 0
        || document.width > 30_000
        || document.height > 30_000
        || !document.dpi.is_finite()
        || document.dpi <= 0.0
        || document.layers.is_empty()
        || document.layers.len() > MAX_PSD_EXPORT_LAYERS
    {
        return Err(ExportError::InvalidPsd(
            "invalid editable PSD dimensions or layer count",
        ));
    }
    let canvas_bytes = expected_len(document.width, document.height)?;
    if document.composite_rgba.len() != canvas_bytes {
        return Err(ExportError::InvalidPixelLength);
    }
    let mut working_set = u64::try_from(canvas_bytes)
        .map_err(|_| ExportError::InvalidPixelLength)?
        .checked_mul(2)
        .ok_or(ExportError::InvalidPixelLength)?;
    for node in &document.layers {
        validate_psd_export_node(document, node, &mut working_set)?;
    }
    validate_psd_export_ids(document)?;
    if document.layers.iter().all(|node| node.parent.is_some()) {
        return Err(ExportError::InvalidPsd("editable PSD has no root layers"));
    }
    // Include temporary per-channel planes and the final encoded copy.
    let peak = working_set
        .checked_mul(3)
        .ok_or(ExportError::InvalidPixelLength)?;
    if peak > MAX_PSD_EXPORT_WORKING_SET_BYTES {
        return Err(ExportError::UnsupportedPsd(
            "editable export exceeds the 768 MiB working-set budget",
        ));
    }
    Ok(())
}

fn validate_psd_export_node(
    document: &PsdExportDocument,
    node: &PsdExportLayer,
    working_set: &mut u64,
) -> Result<(), ExportError> {
    if node.id == 0 {
        return Err(ExportError::InvalidPsd("zero export layer identity"));
    }
    if let Some(parent_id) = node.parent
        && !document
            .layers
            .iter()
            .any(|candidate| candidate.id == parent_id && candidate.is_group)
    {
        return Err(ExportError::InvalidPsd("export parent must be a group"));
    }
    if node.is_group {
        if !node.rgba.is_empty() || node.mask.is_some() || node.clipping {
            return Err(ExportError::UnsupportedPsd(
                "groups with pixels, masks, or clipping are unsupported",
            ));
        }
        if node.pass_through && node.blend_mode != PsdExportBlendMode::Normal {
            return Err(ExportError::InvalidPsd(
                "pass-through groups must use normal blend mode",
            ));
        }
    } else {
        if node.pass_through {
            return Err(ExportError::InvalidPsd("raster layers cannot pass through"));
        }
        let layer_bytes = expected_len(node.width, node.height)?;
        if node.width == 0
            || node.height == 0
            || i64::from(node.left) < -i64::from(document.width)
            || i64::from(node.top) < -i64::from(document.height)
            || i64::from(node.left) + i64::from(node.width) > i64::from(document.width) * 2
            || i64::from(node.top) + i64::from(node.height) > i64::from(document.height) * 2
            || node.rgba.len() != layer_bytes
        {
            return Err(ExportError::InvalidPixelLength);
        }
        *working_set = working_set
            .checked_add(u64::try_from(layer_bytes).map_err(|_| ExportError::InvalidPixelLength)?)
            .ok_or(ExportError::InvalidPixelLength)?;
        if let Some(mask) = &node.mask {
            let mask_len = usize::try_from(mask.width)
                .ok()
                .and_then(|width| {
                    usize::try_from(mask.height)
                        .ok()
                        .and_then(|height| width.checked_mul(height))
                })
                .ok_or(ExportError::InvalidPixelLength)?;
            if mask.width == 0
                || mask.height == 0
                || mask.samples.len() != mask_len
                || i64::from(mask.left) < -i64::from(document.width)
                || i64::from(mask.top) < -i64::from(document.height)
                || i64::from(mask.left) + i64::from(mask.width) > i64::from(document.width) * 2
                || i64::from(mask.top) + i64::from(mask.height) > i64::from(document.height) * 2
            {
                return Err(ExportError::InvalidPsd(
                    "invalid raster mask bounds or samples",
                ));
            }
            *working_set = working_set
                .checked_add(u64::try_from(mask_len).map_err(|_| ExportError::InvalidPixelLength)?)
                .ok_or(ExportError::InvalidPixelLength)?;
        }
    }
    validate_psd_export_depth(document, node)
}

fn validate_psd_export_depth(
    document: &PsdExportDocument,
    node: &PsdExportLayer,
) -> Result<(), ExportError> {
    let mut depth = 0usize;
    let mut parent = node.parent;
    while let Some(parent_id) = parent {
        depth = depth.saturating_add(1);
        if depth > MAX_PSD_EXPORT_DEPTH || parent_id == node.id {
            return Err(ExportError::InvalidPsd(
                "cyclic or deeply nested layer tree",
            ));
        }
        parent = document
            .layers
            .iter()
            .find(|candidate| candidate.id == parent_id)
            .ok_or(ExportError::InvalidPsd("dangling export parent"))?
            .parent;
    }
    Ok(())
}

fn validate_psd_export_ids(document: &PsdExportDocument) -> Result<(), ExportError> {
    let mut ids = std::collections::HashSet::with_capacity(document.layers.len());
    if document.layers.iter().any(|node| !ids.insert(node.id)) {
        return Err(ExportError::InvalidPsd("duplicate export layer identity"));
    }
    Ok(())
}

fn emit_psd_export_children(
    builder: &mut photocraft_psd::PsdBuilder,
    document: &PsdExportDocument,
    parent: Option<u128>,
    depth: usize,
) -> Result<(), ExportError> {
    if depth > MAX_PSD_EXPORT_DEPTH {
        return Err(ExportError::InvalidPsd(
            "layer tree exceeds the depth limit",
        ));
    }
    let mut children = document
        .layers
        .iter()
        .filter(|node| node.parent == parent)
        .collect::<Vec<_>>();
    children.sort_by_key(|node| (node.order, node.id));
    for node in children {
        let blend_mode = psd_export_blend_mode(node.blend_mode);
        let opacity = u8::try_from((u32::from(node.opacity) * 255 + 32_767) / 65_535)
            .map_err(|_| ExportError::InvalidPsd("layer opacity is outside the supported range"))?;
        if node.is_group {
            let group = photocraft_psd::GroupSpec {
                name: node.name.clone(),
                blend_mode: if node.pass_through {
                    photocraft_psd::BlendMode::PassThrough
                } else {
                    blend_mode
                },
                opacity,
                visible: node.visible,
                open: true,
                alpha_locked: node.alpha_locked,
                whole_layer_locked: node.whole_layer_locked,
            };
            builder.begin_group(group);
            emit_psd_export_children(builder, document, Some(node.id), depth + 1)?;
            builder
                .end_group()
                .map_err(|_| ExportError::InvalidPsd("unable to close PSD group"))?;
        } else {
            let mut spec = photocraft_psd::LayerSpec::new(
                node.name.clone(),
                node.left,
                node.top,
                node.width,
                node.height,
                photocraft_psd::PixelData::Rgba8(node.rgba.clone()),
            );
            spec.blend_mode = blend_mode;
            spec.opacity = opacity;
            spec.visible = node.visible;
            spec.clipping = node.clipping;
            let protection =
                u32::from(node.alpha_locked) | (u32::from(node.whole_layer_locked) << 1);
            if protection != 0 {
                spec.extra_blocks
                    .push(photocraft_psd::TaggedBlock::protection(protection));
            }
            if let Some(mask) = &node.mask {
                spec.mask = Some(photocraft_psd::MaskSpec {
                    rect: photocraft_psd::Rect::from_xywh(
                        mask.left,
                        mask.top,
                        mask.width,
                        mask.height,
                    ),
                    data: mask.samples.clone(),
                    default_color: mask.default_value,
                    disabled: !mask.enabled,
                });
            }
            builder.push_layer(spec);
        }
    }
    Ok(())
}

fn psd_export_blend_mode(mode: PsdExportBlendMode) -> photocraft_psd::BlendMode {
    match mode {
        PsdExportBlendMode::Normal => photocraft_psd::BlendMode::Normal,
        PsdExportBlendMode::Multiply => photocraft_psd::BlendMode::Multiply,
        PsdExportBlendMode::Screen => photocraft_psd::BlendMode::Screen,
        PsdExportBlendMode::PassThrough => photocraft_psd::BlendMode::PassThrough,
    }
}

/// Write any Phase 2 format after validating the destination path.
pub fn write_export(
    path: &Path,
    format: ExportFormat,
    width: u32,
    height: u32,
    pixels_rgba: &[u8],
) -> Result<(), ExportError> {
    if let Ok(metadata) = std::fs::symlink_metadata(path)
        && (metadata.file_type().is_symlink() || !metadata.is_file())
    {
        return Err(ExportError::UnsafePath);
    }
    let bytes = match format {
        ExportFormat::Png => encode_png(width, height, pixels_rgba)?,
        ExportFormat::Jpeg => encode_jpeg(width, height, pixels_rgba)?,
        ExportFormat::Webp => encode_webp(width, height, pixels_rgba)?,
        ExportFormat::OpenRaster => encode_open_raster(width, height, pixels_rgba)?,
        ExportFormat::Svg => encode_svg(width, height, pixels_rgba)?,
        ExportFormat::Psd => encode_psd(width, height, pixels_rgba)?,
    };
    let mut file = File::create(path)?;
    file.write_all(&bytes)?;
    file.sync_all()?;
    Ok(())
}

fn expected_len(width: u32, height: u32) -> Result<usize, ExportError> {
    usize::try_from(width)
        .ok()
        .and_then(|w| usize::try_from(height).ok().and_then(|h| w.checked_mul(h)))
        .and_then(|pixels| pixels.checked_mul(4))
        .ok_or(ExportError::InvalidPixelLength)
}

#[cfg(test)]
mod tests {
    use super::*;
    use photocraft_psd::descriptor::{Descriptor, Value, VersionedDescriptor};
    use photocraft_psd::{GroupSpec, LayerSpec, PixelData, PsdBuilder, TaggedBlock};

    fn solid_color_fill_block(rgb: [f64; 3]) -> TaggedBlock {
        let color = Descriptor::new("RGBC")
            .with("Rd  ", Value::Double(rgb[0]))
            .with("Grn ", Value::Double(rgb[1]))
            .with("Bl  ", Value::Double(rgb[2]));
        let descriptor = Descriptor::new("null").with("Clr ", Value::Descriptor(color));
        TaggedBlock::new(*b"SoCo", VersionedDescriptor::new(descriptor).to_bytes())
    }

    fn layered_psd() -> Vec<u8> {
        let rgba = vec![255, 0, 0, 255, 0, 255, 0, 128];
        let mut builder = PsdBuilder::new(2, 1);
        builder.push_layer(LayerSpec::new(
            "Ink",
            -1,
            0,
            2,
            1,
            PixelData::Rgba8(rgba.clone()),
        ));
        builder.composite(PixelData::Rgba8(rgba));
        builder.to_bytes().expect("PSD fixture")
    }

    #[test]
    fn inspects_supported_layered_psd_without_losing_structure() {
        let bytes = layered_psd();
        let inspection = inspect_psd(&bytes).expect("inspection");
        assert_eq!((inspection.width, inspection.height), (2, 1));
        assert_eq!(inspection.layers.len(), 1);
        assert_eq!(inspection.layers[0].name, "Ink");
        assert_eq!(inspection.layers[0].left, -1);
        assert_eq!(
            (inspection.layers[0].width, inspection.layers[0].height),
            (2, 1)
        );
        assert!(
            inspection.editable_import_available,
            "incompatibilities: {:?}",
            inspection.incompatibilities
        );
        assert!(inspection.flattened_import_available);
        assert!(inspection.incompatibilities.is_empty());
        let editable = decode_psd_editable(&bytes).expect("editable layer decode");
        assert_eq!((editable.width, editable.height), (2, 1));
        assert_eq!(editable.layers[0].rgba, [255, 0, 0, 255, 0, 255, 0, 128]);
        assert_eq!(editable.layers[0].left, -1);
        assert_eq!(
            (editable.layers[0].width, editable.layers[0].height),
            (2, 1)
        );
    }

    #[test]
    fn editable_psd_export_writes_layers_masks_locks_and_real_composite() {
        let pixels = vec![255, 0, 0, 255, 0, 255, 0, 128];
        let document = PsdExportDocument {
            width: 2,
            height: 1,
            dpi: 144.0,
            layers: vec![
                PsdExportLayer {
                    id: 1,
                    parent: None,
                    order: 0,
                    name: "Inks".into(),
                    left: 0,
                    top: 0,
                    width: 0,
                    height: 0,
                    is_group: true,
                    pass_through: true,
                    rgba: Vec::new(),
                    visible: true,
                    opacity: u16::MAX,
                    blend_mode: PsdExportBlendMode::Normal,
                    alpha_locked: false,
                    whole_layer_locked: true,
                    clipping: false,
                    mask: None,
                },
                PsdExportLayer {
                    id: 2,
                    parent: Some(1),
                    order: 0,
                    name: "Red and green".into(),
                    left: 0,
                    top: 0,
                    width: 2,
                    height: 1,
                    is_group: false,
                    pass_through: false,
                    rgba: pixels.clone(),
                    visible: true,
                    opacity: u16::MAX,
                    blend_mode: PsdExportBlendMode::Multiply,
                    alpha_locked: true,
                    whole_layer_locked: false,
                    clipping: true,
                    mask: Some(PsdEditableMask {
                        enabled: true,
                        left: 0,
                        top: 0,
                        width: 2,
                        height: 1,
                        samples: vec![255, 128],
                        default_value: 0,
                    }),
                },
            ],
            composite_rgba: pixels.clone(),
        };

        let bytes = encode_editable_psd(&document).expect("editable PSD");
        let inspection = inspect_psd(&bytes).expect("inspect emitted PSD");
        assert!(inspection.editable_import_available);
        let editable = decode_psd_editable(&bytes).expect("decode emitted layers");
        assert_eq!(editable.layers.len(), 2);
        assert!(editable.layers[0].is_group);
        assert!(editable.layers[0].whole_layer_locked);
        assert_eq!(editable.layers[1].blend_mode, "mul ");
        assert!(editable.layers[1].alpha_locked);
        assert!(editable.layers[1].clipping);
        assert_eq!(
            editable.layers[1].mask.as_ref().unwrap().samples,
            vec![255, 128]
        );
        assert_eq!(decode_psd(&bytes).expect("real merged composite").2, pixels);
    }

    #[test]
    fn editable_psd_round_trips_mask_defaults_disabled_state_and_clipping() {
        let document = PsdExportDocument {
            width: 1,
            height: 1,
            dpi: 144.0,
            layers: vec![
                PsdExportLayer {
                    id: 1,
                    parent: None,
                    order: 0,
                    name: "Base".into(),
                    left: 0,
                    top: 0,
                    width: 1,
                    height: 1,
                    is_group: false,
                    pass_through: false,
                    rgba: vec![24, 48, 96, 255],
                    visible: true,
                    opacity: u16::MAX,
                    blend_mode: PsdExportBlendMode::Normal,
                    alpha_locked: false,
                    whole_layer_locked: false,
                    clipping: false,
                    mask: Some(PsdEditableMask {
                        enabled: true,
                        left: 0,
                        top: 0,
                        width: 1,
                        height: 1,
                        samples: vec![0],
                        default_value: 255,
                    }),
                },
                PsdExportLayer {
                    id: 2,
                    parent: None,
                    order: 1,
                    name: "Clipped ink".into(),
                    left: 0,
                    top: 0,
                    width: 1,
                    height: 1,
                    is_group: false,
                    pass_through: false,
                    rgba: vec![200, 100, 50, 255],
                    visible: true,
                    opacity: u16::MAX,
                    blend_mode: PsdExportBlendMode::Normal,
                    alpha_locked: false,
                    whole_layer_locked: false,
                    clipping: true,
                    mask: Some(PsdEditableMask {
                        enabled: false,
                        left: 0,
                        top: 0,
                        width: 1,
                        height: 1,
                        samples: vec![64],
                        default_value: 0,
                    }),
                },
            ],
            composite_rgba: vec![24, 48, 96, 255],
        };

        let bytes = encode_editable_psd(&document).expect("editable PSD");
        let inspection = inspect_psd(&bytes).expect("inspect emitted PSD");
        assert!(inspection.editable_import_available);
        assert!(inspection.layers[1].clipping);

        let decoded = decode_psd_editable(&bytes).expect("decode editable layers");
        assert_eq!(decoded.layers.len(), 2);
        assert_eq!(
            decoded.layers[0]
                .mask
                .as_ref()
                .map(|mask| mask.default_value),
            Some(255)
        );
        assert_eq!(
            decoded.layers[1].mask.as_ref().map(|mask| (
                mask.enabled,
                mask.default_value,
                mask.samples.as_slice()
            )),
            Some((false, 0, &[64][..]))
        );
        assert!(decoded.layers[1].clipping);
    }

    #[test]
    fn editable_psd_export_preserves_bounded_layer_offsets_and_rejects_bad_bounds() {
        let layer = PsdExportLayer {
            id: 1,
            parent: None,
            order: 0,
            name: "Offset ink".into(),
            left: 1,
            top: 1,
            width: 2,
            height: 1,
            is_group: false,
            pass_through: false,
            rgba: vec![255, 0, 0, 255, 0, 0, 255, 128],
            visible: true,
            opacity: u16::MAX,
            blend_mode: PsdExportBlendMode::Normal,
            alpha_locked: false,
            whole_layer_locked: false,
            clipping: false,
            mask: None,
        };
        let document = PsdExportDocument {
            width: 4,
            height: 3,
            dpi: 144.0,
            layers: vec![layer.clone()],
            composite_rgba: vec![0; 4 * 3 * 4],
        };

        let bytes = encode_editable_psd(&document).expect("bounded editable PSD");
        let decoded = decode_psd_editable(&bytes).expect("decode bounded layer");
        assert_eq!(decoded.layers[0].left, 1);
        assert_eq!(decoded.layers[0].top, 1);
        assert_eq!((decoded.layers[0].width, decoded.layers[0].height), (2, 1));
        assert_eq!(decoded.layers[0].rgba, layer.rgba);

        let mut invalid = document;
        invalid.layers[0].width = 3;
        assert!(matches!(
            encode_editable_psd(&invalid),
            Err(ExportError::InvalidPixelLength)
        ));
        invalid.layers[0].width = 2;
        invalid.layers[0].left = 8;
        assert!(matches!(
            encode_editable_psd(&invalid),
            Err(ExportError::InvalidPixelLength)
        ));
    }

    #[test]
    fn inspection_reports_incompatible_profiles_but_allows_explicit_flattening() {
        let rgba = vec![12, 34, 56, 255];
        let mut builder = PsdBuilder::new(1, 1).icc_profile(vec![1, 2, 3, 4]);
        builder.push_layer(LayerSpec::new(
            "Profiled",
            0,
            0,
            1,
            1,
            PixelData::Rgba8(rgba.clone()),
        ));
        builder.composite(PixelData::Rgba8(rgba));
        let inspection =
            inspect_psd(&builder.to_bytes().expect("PSD fixture")).expect("inspection");
        assert!(!inspection.editable_import_available);
        assert!(inspection.flattened_import_available);
        assert!(
            inspection
                .incompatibilities
                .iter()
                .any(|reason| reason.contains("ICC profile"))
        );
    }

    #[test]
    fn inspection_keeps_editable_import_available_without_a_merged_composite() {
        let mut builder = PsdBuilder::new(1, 1);
        builder.push_layer(LayerSpec::new(
            "Ink",
            0,
            0,
            1,
            1,
            PixelData::Rgba8(vec![1, 2, 3, 255]),
        ));
        let inspection =
            inspect_psd(&builder.to_bytes().expect("PSD fixture")).expect("inspection");
        assert!(inspection.editable_import_available);
        assert!(!inspection.flattened_import_available);
        assert!(inspection.incompatibilities.is_empty());
        assert!(
            inspection
                .flattened_import_issues
                .iter()
                .any(|reason| reason.contains("no real merged composite"))
        );
        let editable = decode_psd_editable(&builder.to_bytes().expect("PSD fixture"))
            .expect("editable layer decode");
        assert_eq!(editable.layers[0].rgba, [1, 2, 3, 255]);
    }

    #[test]
    fn editable_decode_reconstructs_groups_without_importing_divider_records() {
        let mut builder = PsdBuilder::new(1, 1);
        builder.begin_group(GroupSpec::new("Folder"));
        builder.push_layer(LayerSpec::new(
            "Ink",
            0,
            0,
            1,
            1,
            PixelData::Rgba8(vec![10, 20, 30, 255]),
        ));
        builder.end_group().expect("close folder");
        let bytes = builder.to_bytes().expect("PSD fixture");
        let inspection = inspect_psd(&bytes).expect("inspection");
        assert!(
            inspection.editable_import_available,
            "{:?}",
            inspection.incompatibilities
        );
        let editable = decode_psd_editable(&bytes).expect("editable hierarchy");
        assert_eq!(editable.layers.len(), 2);
        assert!(editable.layers[0].is_group);
        assert_eq!(editable.layers[0].name, "Folder");
        assert_eq!(editable.layers[1].name, "Ink");
        assert_eq!(editable.layers[1].parent_index, Some(0));
    }

    #[test]
    fn solid_color_fill_is_rasterized_and_fill_opacity_becomes_pixel_alpha() {
        let mut fill = LayerSpec::new(
            "Solid fill",
            0,
            0,
            2,
            1,
            PixelData::Rgba8(vec![1, 2, 3, 255, 4, 5, 6, 128]),
        );
        fill.fill_opacity = Some(128);
        fill.extra_blocks
            .push(solid_color_fill_block([32.0, 96.0, 224.0]));
        let mut builder = PsdBuilder::new(2, 1);
        builder.push_layer(fill);
        builder.composite(PixelData::Rgba8(vec![32, 96, 224, 255, 32, 96, 224, 128]));
        let bytes = builder.to_bytes().expect("PSD fixture");

        let inspection = inspect_psd(&bytes).expect("inspection");
        assert!(
            inspection.editable_import_available,
            "{:?}",
            inspection.incompatibilities
        );
        assert_eq!(inspection.logical_layer_count, 1);
        assert!(
            inspection
                .supported_features
                .iter()
                .any(|feature| { feature.contains("fill color is baked into pixels") })
        );

        let editable = decode_psd_editable(&bytes).expect("solid fill decode");
        assert_eq!(editable.layers[0].name, "Solid fill");
        assert_eq!(editable.layers[0].rgba, [32, 96, 224, 128, 32, 96, 224, 64]);
    }

    #[test]
    fn logical_layer_count_excludes_group_divider_records() {
        let mut builder = PsdBuilder::new(1, 1);
        builder.begin_group(GroupSpec::new("Folder"));
        builder.push_layer(LayerSpec::new(
            "Ink",
            0,
            0,
            1,
            1,
            PixelData::Rgba8(vec![10, 20, 30, 255]),
        ));
        builder.end_group().expect("close folder");

        let bytes = builder.to_bytes().expect("PSD fixture");
        let inspection = inspect_psd(&bytes).expect("inspection");
        assert_eq!(inspection.layers.len(), 3, "raw records include a divider");
        assert_eq!(
            inspection.logical_layer_count, 2,
            "folder and child are visible nodes"
        );
        assert!(inspection.editable_import_available);
    }

    #[test]
    fn gradient_pattern_and_malformed_solid_fills_remain_unsupported() {
        for (key, data) in [
            (*b"GdFl", vec![1]),
            (*b"PtFl", vec![1]),
            (*b"SoCo", vec![1]),
        ] {
            let mut layer = LayerSpec::new(
                "Unsupported fill",
                0,
                0,
                1,
                1,
                PixelData::Rgba8(vec![0, 0, 0, 255]),
            );
            layer.extra_blocks.push(TaggedBlock::new(key, data));
            let mut builder = PsdBuilder::new(1, 1);
            builder.push_layer(layer);
            let inspection =
                inspect_psd(&builder.to_bytes().expect("PSD fixture")).expect("inspection");
            assert!(!inspection.editable_import_available);
        }
    }

    #[test]
    fn encodes_png_signature_and_rejects_wrong_size() {
        let pixels = [255, 0, 0, 255];
        let png = encode_png(1, 1, &pixels).expect("png");
        assert_eq!(&png[..8], b"\x89PNG\r\n\x1a\n");
        assert_eq!(decode_png_rgba8(&png).expect("decode").2, pixels);
        assert!(matches!(
            decode_png_rgba8(&png[..png.len() - 2]),
            Err(ExportError::InvalidPng(_))
        ));
        assert!(matches!(
            encode_png(2, 1, &pixels),
            Err(ExportError::InvalidPixelLength)
        ));
    }

    #[test]
    fn phase_two_formats_have_valid_signatures_and_containers() {
        let pixels = [255, 32, 16, 255, 0, 64, 128, 255];
        let jpeg = encode_jpeg(2, 1, &pixels).expect("jpeg");
        assert_eq!(&jpeg[..2], b"\xff\xd8");
        let webp = encode_webp(2, 1, &pixels).expect("webp");
        assert_eq!(&webp[..4], b"RIFF");
        assert_eq!(&webp[8..12], b"WEBP");
        let ora = encode_open_raster(2, 1, &pixels).expect("ora");
        let mut archive = zip::ZipArchive::new(Cursor::new(ora)).expect("ora zip");
        assert_eq!(archive.by_name("mimetype").expect("mimetype").size(), 16);
        assert!(archive.by_name("stack.xml").is_ok());
        assert!(archive.by_name("data/mergedimage.png").is_ok());
        let svg = encode_svg(2, 1, &pixels).expect("svg");
        assert!(
            std::str::from_utf8(&svg)
                .expect("svg utf8")
                .starts_with("<svg ")
        );
        let psd = encode_psd(2, 1, &pixels).expect("psd");
        assert_eq!(&psd[..4], b"8BPS");
        assert_eq!(psd.len(), 48);
        let (width, height, decoded) = decode_psd(&psd).expect("decode psd");
        assert_eq!((width, height), (2, 1));
        assert_eq!(decoded, pixels);
        assert!(matches!(
            decode_psd(&psd[..psd.len() - 1]),
            Err(ExportError::InvalidPsd(_))
        ));
    }

    #[test]
    fn decodes_packbits_psd_composites_and_rejects_bad_rows() {
        let pixels = [255, 32, 16, 255, 0, 64, 128, 255];
        let raw = encode_psd(2, 1, &pixels).expect("raw PSD");
        let mut rle = raw[..38].to_vec();
        rle.extend_from_slice(&1_u16.to_be_bytes());
        for _ in 0..4 {
            rle.extend_from_slice(&3_u16.to_be_bytes());
        }
        for channel in 0..4 {
            rle.push(1); // two literal bytes follow
            rle.extend_from_slice(&raw[40 + channel * 2..42 + channel * 2]);
        }
        let (width, height, decoded) = decode_psd(&rle).expect("decode PackBits PSD");
        assert_eq!((width, height), (2, 1));
        assert_eq!(decoded, pixels);

        let mut truncated = rle.clone();
        truncated.pop();
        assert!(matches!(
            decode_psd(&truncated),
            Err(ExportError::InvalidPsd("truncated RLE row"))
        ));

        let mut row_overrun = rle;
        row_overrun[40..42].copy_from_slice(&4_u16.to_be_bytes());
        row_overrun.insert(51, 0);
        row_overrun[48] = 2; // four literal bytes cannot fit in a two-pixel row
        assert!(matches!(
            decode_psd(&row_overrun),
            Err(ExportError::InvalidPsd("PackBits row exceeds its width"))
        ));
    }

    #[test]
    fn decodes_packbits_repeat_and_noop_packets() {
        let pixels = [10, 20, 30, 40, 10, 20, 30, 40];
        let raw = encode_psd(2, 1, &pixels).expect("raw PSD");
        let mut rle = raw[..38].to_vec();
        rle.extend_from_slice(&1_u16.to_be_bytes());
        for _ in 0..4 {
            rle.extend_from_slice(&3_u16.to_be_bytes());
        }
        for channel in 0..4 {
            rle.extend_from_slice(&[0xff, raw[40 + channel * 2], 0x80]);
        }
        let (_, _, decoded) = decode_psd(&rle).expect("decode PackBits repeat PSD");
        for (actual, expected) in decoded
            .as_chunks::<4>()
            .0
            .iter()
            .zip(pixels.as_chunks::<4>().0)
        {
            for channel in 0..3 {
                assert_eq!(
                    matte_psd_rgb(actual[channel], actual[3]),
                    matte_psd_rgb(expected[channel], expected[3]),
                    "white-matted composite differs"
                );
            }
            assert_eq!(actual[3], expected[3]);
        }
    }

    #[test]
    fn rejects_oversized_psd_pixel_count_before_allocating_rgba() {
        let mut header = [0_u8; 26];
        header[..4].copy_from_slice(b"8BPS");
        header[4..6].copy_from_slice(&1_u16.to_be_bytes());
        header[12..14].copy_from_slice(&3_u16.to_be_bytes());
        header[14..18].copy_from_slice(&8_193_u32.to_be_bytes());
        header[18..22].copy_from_slice(&8_193_u32.to_be_bytes());
        header[22..24].copy_from_slice(&8_u16.to_be_bytes());
        header[24..26].copy_from_slice(&3_u16.to_be_bytes());

        assert!(matches!(
            decode_psd(&header),
            Err(ExportError::InvalidPsd(
                "pixel count exceeds the 64 megapixel safety limit"
            ))
        ));

        header[14..18].copy_from_slice(&8_192_u32.to_be_bytes());
        header[18..22].copy_from_slice(&8_192_u32.to_be_bytes());
        assert!(matches!(
            decode_psd(&header),
            Err(ExportError::InvalidPsd("truncated section length"))
        ));
    }

    #[test]
    fn psd_working_set_budget_accounts_for_source_pixels_and_initial_layer() {
        let max_pixels = 8_192_u32 * 8_192;
        let decoded_and_layer_bytes = u64::from(max_pixels) * 8;
        let source_bytes_at_budget = MAX_PSD_IMPORT_WORKING_SET_BYTES - decoded_and_layer_bytes;
        assert!(validate_psd_import_budget(source_bytes_at_budget, 8_192, 8_192).is_ok());
        assert!(matches!(
            validate_psd_import_budget(source_bytes_at_budget + 1, 8_192, 8_192),
            Err(ExportError::InvalidPsd(
                "projected import memory exceeds the 768 MiB safety limit"
            ))
        ));
    }

    #[cfg(unix)]
    #[test]
    fn refuses_to_follow_a_symlink_destination() {
        use std::os::unix::fs::symlink;

        let root =
            std::env::temp_dir().join(format!("project-ink-export-symlink-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).expect("temp root");
        let target = root.join("target.png");
        std::fs::write(&target, b"keep").expect("target");
        let destination = root.join("output.png");
        symlink(&target, &destination).expect("symlink");
        assert!(matches!(
            write_png(&destination, 1, 1, &[255, 0, 0, 255]),
            Err(ExportError::UnsafePath)
        ));
        assert_eq!(std::fs::read(&target).expect("target bytes"), b"keep");
        std::fs::remove_dir_all(root).expect("cleanup");
    }
}
