//! Versioned, deterministic Phase 2 brush model and CPU evaluator.
//!
//! The evaluator intentionally works on small value types and bounded
//! collections.  It is suitable for previews and for the engine's tile
//! worker; file formats and resource decoding remain outside this module.

#![allow(
    clippy::cast_possible_truncation,
    clippy::cast_precision_loss,
    clippy::cast_sign_loss,
    clippy::semicolon_if_nothing_returned,
    clippy::too_many_lines
)]

use ink_input::PointerSample;
use ink_model::{BrushId, Rgba8};
use serde::{Deserialize, Serialize};
use std::fmt;

/// Pixel-affecting semantics version for the Phase 2 CPU renderer.
pub const CPU_BRUSH_V2: u32 = 2_000;
/// Maximum number of dynamic bindings on one preset.
pub const MAX_BINDINGS: usize = 64;
/// Maximum number of curve points on one response curve.
pub const MAX_CURVE_POINTS: usize = 16;
/// Maximum number of source tips on one preset.
pub const MAX_TIPS: usize = 32;
/// Maximum number of dabs emitted by one evaluated stroke.
pub const MAX_RENDERED_DABS: usize = 1_048_576;
/// Maximum number of post-effect stages on one preset.
pub const MAX_POST_EFFECTS: usize = 8;
const MAX_METADATA_NAME_BYTES: usize = 256;
const MAX_METADATA_AUTHOR_BYTES: usize = 512;
const MAX_METADATA_LICENSE_BYTES: usize = 1024;
const MAX_METADATA_TAGS: usize = 64;
const MAX_METADATA_TAG_BYTES: usize = 128;
/// Reserved built-in ID range; stays clear of IDs assigned by earlier app versions.
const STARTER_BRUSH_ID_BASE: u128 = 4_000_000_000_000_000;

/// Stable rendering semantics identifier.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash, Serialize, Deserialize)]
pub struct EngineSemantics(pub u32);

impl Default for EngineSemantics {
    fn default() -> Self {
        Self(CPU_BRUSH_V2)
    }
}

/// Brush attribution and library metadata.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct BrushMetadata {
    pub name: String,
    pub author: Option<String>,
    pub license: Option<String>,
    pub source_format: Option<String>,
    pub tags: Vec<String>,
}

impl BrushMetadata {
    /// Construct metadata for an original built-in preset.
    #[must_use]
    pub fn builtin(name: impl Into<String>, tags: &[&str]) -> Self {
        Self {
            name: name.into(),
            author: Some("Project Ink contributors".into()),
            license: Some("MPL-2.0-compatible original asset".into()),
            source_format: None,
            tags: tags.iter().map(|tag| (*tag).into()).collect(),
        }
    }
}

/// The operation performed by a brush on its target layer.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash, Serialize, Deserialize)]
pub enum ToolBehavior {
    Deposit,
    Erase,
    Smudge,
    Blur,
    Clone,
}

/// Stroke-path controls shared by all brush engines.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct StrokeBehavior {
    pub spacing: f32,
    pub minimum_spacing_px: f32,
    pub smoothing: f32,
    pub streamline: f32,
    pub taper_start: f32,
    pub taper_end: f32,
    pub stationary_rate_hz: f32,
    pub corner_preservation: f32,
}

impl Default for StrokeBehavior {
    fn default() -> Self {
        Self {
            spacing: 0.10,
            minimum_spacing_px: 0.25,
            smoothing: 0.0,
            streamline: 0.0,
            taper_start: 0.0,
            taper_end: 0.0,
            stationary_rate_hz: 0.0,
            corner_preservation: 0.0,
        }
    }
}

/// A procedural or image-backed stamp tip.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct StampTip {
    /// Optional content hash for a user-supplied monochrome tip resource.
    pub resource_hash: Option<[u8; 32]>,
    pub diameter_px: f32,
    pub hardness: f32,
    pub roundness: f32,
    pub angle_degrees: f32,
    pub follow_stroke: f32,
    pub impressions: u8,
    pub density: f32,
    /// Exact editor value retained separately from density for lossless UI
    /// projection. Older v2 presets deserialize this as zero.
    #[serde(default)]
    pub editor_scatter: f32,
}

impl Default for StampTip {
    fn default() -> Self {
        Self {
            resource_hash: None,
            diameter_px: 8.0,
            hardness: 1.0,
            roundness: 1.0,
            angle_degrees: 0.0,
            follow_stroke: 1.0,
            impressions: 1,
            density: 1.0,
            editor_scatter: 0.0,
        }
    }
}

/// A bounded procedural spray tip.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SprayTip {
    pub diameter_px: f32,
    pub particle_count: u32,
    pub particle_size_px: f32,
    pub scatter: f32,
    pub hardness: f32,
}

/// A path-following decorative ribbon.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct RibbonTip {
    pub width_px: f32,
    pub repeat_spacing_px: f32,
    pub follow_direction: bool,
}

/// A deterministic bundle of virtual bristles.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct BristleTip {
    pub diameter_px: f32,
    pub bristle_count: u16,
    pub spread: f32,
    pub stiffness: f32,
    pub lag: f32,
}

/// The supported tip evaluator.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum TipBehavior {
    Stamp(StampTip),
    Spray(SprayTip),
    Ribbon(RibbonTip),
    Bristle(BristleTip),
}

/// Optional canvas-space grain modulation.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct GrainBehavior {
    pub resource_hash: [u8; 32],
    pub scale: f32,
    pub depth: f32,
    pub contrast: f32,
    pub canvas_space: bool,
}

/// Color accumulation semantics.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash, Serialize, Deserialize)]
pub enum AccumulationMode {
    BuildUp,
    UniformStroke,
    Glaze,
    Marker,
    DarkenTips,
    Erase,
}

/// Opaque paint deposit.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SolidPaint {
    pub color: Rgba8,
    pub opacity: f32,
    pub flow: f32,
    pub accumulation: AccumulationMode,
}

/// Low-flow translucent paint.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct GlazePaint {
    pub color: Rgba8,
    pub opacity: f32,
    pub flow: f32,
    pub accumulation: AccumulationMode,
}

/// Marker paint with controlled overlap.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct MarkerPaint {
    pub color: Rgba8,
    pub opacity: f32,
    pub flow: f32,
}

/// RGB pickup/smudge paint.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ColorPickupPaint {
    pub color: Rgba8,
    pub opacity: f32,
    pub flow: f32,
    pub pickup: f32,
    pub deposit: f32,
    pub dilution: f32,
    pub blur: f32,
}

/// Digital watercolor, deliberately bounded and non-physical.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct DigitalWatercolorPaint {
    pub color: Rgba8,
    pub wash: f32,
    pub flow: f32,
    pub dilution: f32,
    pub pickup: f32,
    pub granulation: f32,
    pub edge_pooling: f32,
    pub paper_resist: f32,
}

/// Paint stage selected by a preset.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum PaintBehavior {
    Solid(SolidPaint),
    Glaze(GlazePaint),
    Marker(MarkerPaint),
    ColorPickup(ColorPickupPaint),
    DigitalWatercolor(DigitalWatercolorPaint),
}

/// Direct and derived input channels.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash, Serialize, Deserialize)]
pub enum SensorId {
    Pressure,
    Tilt,
    Rotation,
    Speed,
    Direction,
    Distance,
    Progress,
    RandomPerDab,
}

/// Parameters that can be controlled by a sensor.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash, Serialize, Deserialize)]
pub enum ParameterId {
    Diameter,
    Opacity,
    Flow,
    Density,
    Spacing,
    Rotation,
    Scatter,
    GrainDepth,
    Pickup,
    ColorShift,
}

/// A fixed-point curve point serialized as normalized values.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct CurvePoint {
    pub x: f32,
    pub y: f32,
}

/// Piecewise-linear response curve. The evaluator is intentionally bounded.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ResponseCurve {
    pub points: Vec<CurvePoint>,
}

impl ResponseCurve {
    /// Identity curve.
    #[must_use]
    pub fn identity() -> Self {
        Self {
            points: vec![CurvePoint { x: 0.0, y: 0.0 }, CurvePoint { x: 1.0, y: 1.0 }],
        }
    }

    /// Evaluate a validated curve with deterministic linear interpolation.
    #[must_use]
    pub fn evaluate(&self, value: f32) -> f32 {
        let value = value.clamp(0.0, 1.0);
        let Some(first) = self.points.first() else {
            return value;
        };
        if value <= first.x {
            return first.y;
        }
        for pair in self.points.windows(2) {
            let [left, right] = [pair[0], pair[1]];
            if value <= right.x {
                let span = (right.x - left.x).max(f32::EPSILON);
                let t = ((value - left.x) / span).clamp(0.0, 1.0);
                return left.y + (right.y - left.y) * t;
            }
        }
        self.points.last().map_or(value, |point| point.y)
    }
}

/// How one modulation combines with the current value.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash, Serialize, Deserialize)]
pub enum CombineOp {
    Add,
    Multiply,
    Replace,
    Minimum,
    Maximum,
}

/// A bounded sensor-to-parameter mapping.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ParameterBinding {
    pub target: ParameterId,
    pub base: f32,
    pub sensor: SensorId,
    pub curve: ResponseCurve,
    pub amount: f32,
    pub combine: CombineOp,
}

/// Resource and work limits compiled into a brush.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct BrushLimits {
    pub max_dabs: usize,
    pub max_particles: usize,
    pub max_halo_px: u32,
}

impl Default for BrushLimits {
    fn default() -> Self {
        Self {
            max_dabs: MAX_RENDERED_DABS,
            max_particles: MAX_RENDERED_DABS,
            max_halo_px: 128,
        }
    }
}

/// A non-recursive dual brush.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct DualBrush {
    pub secondary: Box<BrushPresetV2>,
    pub multiply_coverage: bool,
}

/// Whether an effect is evaluated while dabs arrive or once the stroke ends.
///
/// The CPU tile renderer evaluates the live watercolor contribution on each
/// dab and also runs the bounded committed-region pass at stroke end so the
/// final pixels are deterministic across platforms. The stroke-end variant is
/// used for neighborhood effects that need the completed dirty region. Keeping
/// this in the serialized model means imported presets retain their intended
/// timing when an incremental preview is available.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash, Serialize, Deserialize)]
pub enum PostEffectTiming {
    Live,
    StrokeEnd,
}

/// Watercolor edge rendering style.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash, Serialize, Deserialize)]
pub enum WatercolorEdgeStyle {
    Standard,
    Vivid,
}

/// Bounded, declarative effects applied only to the active stroke's dirty
/// region.  Effects contain no executable code or paths and therefore remain
/// safe to import from untrusted brush packs.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum PostEffect {
    DigitalWatercolorEdge {
        radius_px: u32,
        strength: f32,
        darkness: f32,
        blur: f32,
        saturation: f32,
        hue_shift: f32,
        style: WatercolorEdgeStyle,
        timing: PostEffectTiming,
    },
    EdgeSoftness {
        radius_px: u32,
        amount: f32,
    },
    StampOutline {
        radius_px: u32,
        opacity: f32,
        color: Rgba8,
    },
    TrailingFade {
        distance_px: u32,
        amount: f32,
    },
    TexturePass {
        resource_hash: [u8; 32],
        scale: f32,
        depth: f32,
    },
}

impl PostEffect {
    /// Return the maximum neighborhood halo required by this effect.
    #[must_use]
    pub fn halo_px(&self) -> u32 {
        match self {
            Self::DigitalWatercolorEdge { radius_px, .. }
            | Self::EdgeSoftness { radius_px, .. }
            | Self::StampOutline { radius_px, .. } => *radius_px,
            Self::TrailingFade { distance_px, .. } => *distance_px,
            Self::TexturePass { .. } => 0,
        }
    }
}

/// A complete declarative Phase 2 preset.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct BrushPresetV2 {
    pub format_version: u32,
    pub engine_semantics: EngineSemantics,
    pub id: BrushId,
    pub revision: u32,
    pub metadata: BrushMetadata,
    pub tool: ToolBehavior,
    pub stroke: StrokeBehavior,
    pub tip: TipBehavior,
    pub grain: Option<GrainBehavior>,
    pub paint: PaintBehavior,
    pub dynamics: Vec<ParameterBinding>,
    pub dual: Option<DualBrush>,
    #[serde(default)]
    pub post_effects: Vec<PostEffect>,
    pub limits: BrushLimits,
}

/// A compiled preset ready for deterministic evaluation.
#[derive(Clone, Debug)]
pub struct CompiledBrush {
    pub source_id: BrushId,
    pub semantics: EngineSemantics,
    pub tool: ToolBehavior,
    pub stroke: StrokeBehavior,
    pub tip: TipBehavior,
    pub paint: PaintBehavior,
    pub grain: Option<GrainBehavior>,
    pub dynamics: Vec<ParameterBinding>,
    pub dual: Option<(Box<CompiledBrush>, bool)>,
    pub post_effects: Box<[PostEffect]>,
    pub limits: BrushLimits,
}

/// Bounded incremental path state for one active compiled-brush stroke.
///
/// Keep one instance per stroke and pass only newly confirmed samples to
/// [`CompiledBrush::render_incremental`]. The brush's persistent sample,
/// smoothing, and spacing anchors make streamed output match a one-shot render.
#[derive(Clone, Debug, Default)]
pub struct CompiledBrushState {
    conditioned_anchor: Option<PointerSample>,
    path_anchor: Option<PathPoint>,
    path_points_emitted: usize,
    segment_path_points_emitted: usize,
    dabs_emitted: usize,
    segment_dabs_emitted: usize,
    dual_state: Option<Box<Self>>,
    deferred_dual_dabs: Vec<(BrushDab, bool)>,
}

impl CompiledBrushState {
    /// Clone path/dynamics cursors for ephemeral prediction without copying
    /// deferred confirmed companion dabs from the active stroke.
    #[must_use]
    pub fn clone_for_prediction(&self) -> Self {
        Self {
            conditioned_anchor: self.conditioned_anchor,
            path_anchor: self.path_anchor,
            path_points_emitted: self.path_points_emitted,
            segment_path_points_emitted: self.segment_path_points_emitted,
            dabs_emitted: self.dabs_emitted,
            segment_dabs_emitted: self.segment_dabs_emitted,
            dual_state: self
                .dual_state
                .as_deref()
                .map(|state| Box::new(state.clone_for_prediction())),
            deferred_dual_dabs: Vec::new(),
        }
    }

    /// Reset per-segment safety counters while preserving smoothing, spacing,
    /// dynamics, and seed state for one continuous logical stroke.
    /// Returns false when deferred companion-brush work still needs flushing.
    pub fn begin_work_segment(&mut self) -> bool {
        if !self.deferred_dual_dabs.is_empty() {
            return false;
        }
        if let Some(secondary) = self.dual_state.as_deref_mut()
            && !secondary.begin_work_segment()
        {
            return false;
        }
        self.segment_path_points_emitted = 0;
        self.segment_dabs_emitted = 0;
        true
    }

    #[must_use]
    pub fn segment_work_near_limit(&self, limit: usize) -> bool {
        let threshold = limit.saturating_mul(3) / 4;
        self.segment_path_points_emitted >= threshold
            || self.segment_dabs_emitted >= threshold
            || self
                .dual_state
                .as_deref()
                .is_some_and(|state| state.segment_work_near_limit(limit))
    }
}

/// A generated paint mark consumed by a raster tile renderer.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct BrushDab {
    pub x: f32,
    pub y: f32,
    pub radius_x: f32,
    pub radius_y: f32,
    pub angle: f32,
    pub opacity: f32,
    /// Per-dab deposition multiplier, distinct from stroke opacity.
    pub flow: f32,
    /// Optional deterministic grain modulation metadata.
    pub grain: Option<GrainStamp>,
    /// Optional decoded image-tip lookup key. The renderer resolves this
    /// against the Rust-owned bounded resource cache.
    pub tip_resource_hash: Option<[u8; 32]>,
    pub color: Rgba8,
    pub tool: ToolBehavior,
    pub paint: BrushPaint,
}

/// Per-dab paint behavior carried into the tile renderer. Keeping these
/// bounded scalar values on the dab avoids exposing mutable preset state to
/// the render worker while still distinguishing glaze, smudge, and watercolor
/// deposition.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum BrushPaint {
    Solid,
    Glaze,
    Marker,
    ColorPickup {
        pickup: f32,
        deposit: f32,
        dilution: f32,
        blur: f32,
    },
    DigitalWatercolor {
        dilution: f32,
        pickup: f32,
        granulation: f32,
        edge_pooling: f32,
        paper_resist: f32,
    },
}

/// Compact grain parameters copied into each emitted dab. No file paths or
/// unbounded resource data enter the hot path.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GrainStamp {
    pub resource_hash: [u8; 32],
    pub scale: f32,
    pub depth: f32,
    pub contrast: f32,
    pub canvas_space: bool,
}

/// Errors returned while validating or compiling a preset.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum BrushValidationError {
    UnsupportedFormat(u32),
    InvalidNumber(&'static str),
    InvalidRange(&'static str),
    TooManyBindings,
    TooManyCurvePoints,
    TooManyTips,
    TooManyPostEffects,
    RecursiveDual,
    WorkLimitExceeded,
    CloneNotImplemented,
}

impl fmt::Display for BrushValidationError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnsupportedFormat(value) => write!(f, "unsupported brush format {value}"),
            Self::InvalidNumber(field) => write!(f, "brush field {field} is not finite"),
            Self::InvalidRange(field) => write!(f, "brush field {field} is outside its range"),
            Self::TooManyBindings => f.write_str("brush has too many parameter bindings"),
            Self::TooManyCurvePoints => f.write_str("brush response curve has too many points"),
            Self::TooManyTips => f.write_str("brush has too many source tips"),
            Self::TooManyPostEffects => f.write_str("brush has too many post effects"),
            Self::RecursiveDual => f.write_str("dual brushes may not contain another dual brush"),
            Self::WorkLimitExceeded => f.write_str("brush work limits are unsafe"),
            Self::CloneNotImplemented => {
                f.write_str("clone brushes are reserved for a later engine gate")
            }
        }
    }
}

impl std::error::Error for BrushValidationError {}

impl BrushPresetV2 {
    /// Validate untrusted or editor-created preset data before compilation.
    pub fn validate(&self) -> Result<(), BrushValidationError> {
        if self.format_version != 2 {
            return Err(BrushValidationError::UnsupportedFormat(self.format_version));
        }
        if self.metadata.name.is_empty()
            || self.metadata.name.len() > MAX_METADATA_NAME_BYTES
            || self
                .metadata
                .author
                .as_ref()
                .is_some_and(|value| value.len() > MAX_METADATA_AUTHOR_BYTES)
            || self
                .metadata
                .license
                .as_ref()
                .is_some_and(|value| value.len() > MAX_METADATA_LICENSE_BYTES)
            || self.metadata.tags.len() > MAX_METADATA_TAGS
            || self
                .metadata
                .tags
                .iter()
                .any(|tag| tag.is_empty() || tag.len() > MAX_METADATA_TAG_BYTES)
        {
            return Err(BrushValidationError::InvalidRange("metadata bounds"));
        }
        finite_range("stroke.spacing", self.stroke.spacing, 0.001, 1.0)?;
        finite_range(
            "stroke.minimum_spacing_px",
            self.stroke.minimum_spacing_px,
            0.01,
            64.0,
        )?;
        finite_range("stroke.smoothing", self.stroke.smoothing, 0.0, 1.0)?;
        finite_range("stroke.streamline", self.stroke.streamline, 0.0, 1.0)?;
        finite_range("stroke.taper_start", self.stroke.taper_start, 0.0, 1.0)?;
        finite_range("stroke.taper_end", self.stroke.taper_end, 0.0, 1.0)?;
        finite_range(
            "stroke.stationary_rate_hz",
            self.stroke.stationary_rate_hz,
            0.0,
            120.0,
        )?;
        finite_range(
            "stroke.corner_preservation",
            self.stroke.corner_preservation,
            0.0,
            1.0,
        )?;
        if self.dynamics.len() > MAX_BINDINGS {
            return Err(BrushValidationError::TooManyBindings);
        }
        for binding in &self.dynamics {
            finite_range("binding.base", binding.base, 0.0, 1.0)?;
            finite_range("binding.amount", binding.amount, -1.0, 1.0)?;
            if binding.curve.points.len() < 2 {
                return Err(BrushValidationError::InvalidRange("curve point count"));
            }
            if binding.curve.points.len() > MAX_CURVE_POINTS {
                return Err(BrushValidationError::TooManyCurvePoints);
            }
            let mut previous_x = -1.0;
            for point in &binding.curve.points {
                finite_range("curve.x", point.x, 0.0, 1.0)?;
                finite_range("curve.y", point.y, 0.0, 1.0)?;
                if point.x <= previous_x {
                    return Err(BrushValidationError::InvalidRange("curve.x ordering"));
                }
                previous_x = point.x;
            }
        }
        if self.limits.max_dabs == 0
            || self.limits.max_particles == 0
            || self.limits.max_dabs > MAX_RENDERED_DABS
            || self.limits.max_particles > MAX_RENDERED_DABS
            || self.limits.max_halo_px > 128
        {
            return Err(BrushValidationError::WorkLimitExceeded);
        }
        if self.post_effects.len() > MAX_POST_EFFECTS {
            return Err(BrushValidationError::TooManyPostEffects);
        }
        for effect in &self.post_effects {
            validate_post_effect(effect, self.limits.max_halo_px)?;
        }
        validate_tip(&self.tip)?;
        if let Some(grain) = &self.grain {
            validate_grain(grain)?;
        }
        validate_paint(&self.paint)?;
        if let Some(dual) = &self.dual {
            if dual.secondary.dual.is_some() {
                return Err(BrushValidationError::RecursiveDual);
            }
            dual.secondary.validate()?
        }
        if self.tool == ToolBehavior::Clone {
            return Err(BrushValidationError::CloneNotImplemented);
        }
        Ok(())
    }

    /// Compile and normalize a preset for the render worker.
    pub fn compile(&self) -> Result<CompiledBrush, BrushValidationError> {
        self.validate()?;
        Ok(CompiledBrush {
            source_id: self.id,
            semantics: self.engine_semantics,
            tool: self.tool,
            stroke: self.stroke.clone(),
            tip: self.tip.clone(),
            paint: self.paint.clone(),
            grain: self.grain.clone(),
            dynamics: self.dynamics.clone(),
            dual: self
                .dual
                .as_ref()
                .map(|dual| Ok((Box::new(dual.secondary.compile()?), dual.multiply_coverage)))
                .transpose()?,
            post_effects: self.post_effects.clone().into_boxed_slice(),
            limits: self.limits.clone(),
        })
    }

    /// Render a small deterministic scratch-pad preview without touching a
    /// document tile store. The preview intentionally uses the same compiled
    /// dab evaluator as committed strokes.
    pub fn preview_rgba8(&self, width: u16, height: u16) -> Result<Vec<u8>, BrushValidationError> {
        let samples = (0..16)
            .map(|index| {
                let index = index as u64;
                let fraction = index as f32 / 15.0;
                PointerSample {
                    pointer_id: 1,
                    flags: ink_input::flags::ACTUAL,
                    device_kind: ink_input::DeviceKind::Stylus,
                    phase: ink_input::Phase::Move,
                    canvas_x: 8.0 + fraction * (f32::from(width) - 16.0).max(0.0),
                    canvas_y: f32::from(height) * (0.35 + fraction * 0.3),
                    pressure: (fraction * f32::from(u16::MAX)) as u16,
                    tilt_x: 0.0,
                    tilt_y: 0.0,
                    azimuth: 0.0,
                    twist: 0.0,
                    timestamp_ns: index * 1_000_000,
                    sequence: index as u32,
                }
            })
            .collect::<Vec<_>>();
        self.preview_samples_rgba8(width, height, &samples)
    }

    /// Render a bounded, editor-provided stroke using the compiled brush.
    /// This path has no access to a document tile store or history.
    pub fn preview_samples_rgba8(
        &self,
        width: u16,
        height: u16,
        samples: &[PointerSample],
    ) -> Result<Vec<u8>, BrushValidationError> {
        let width_usize = usize::from(width);
        let height_usize = usize::from(height);
        if width == 0
            || height == 0
            || width_usize.saturating_mul(height_usize) > 256 * 256
            || samples.is_empty()
            || samples.len() > 1024
        {
            return Err(BrushValidationError::WorkLimitExceeded);
        }
        let compiled = self.compile()?;
        let dabs = compiled.render(samples)?;
        let mut pixels = vec![0_u8; width_usize * height_usize * 4];
        for dab in dabs {
            let left = (dab.x - dab.radius_x).floor().max(0.0) as u32;
            let right = (dab.x + dab.radius_x).ceil().min(f32::from(width)).max(0.0) as u32;
            let top = (dab.y - dab.radius_y).floor().max(0.0) as u32;
            let bottom = (dab.y + dab.radius_y)
                .ceil()
                .min(f32::from(height))
                .max(0.0) as u32;
            let (sin, cos) = dab.angle.sin_cos();
            for y in top..bottom {
                for x in left..right {
                    let raw_x = (x as f32 - dab.x) / dab.radius_x.max(0.25);
                    let raw_y = (y as f32 - dab.y) / dab.radius_y.max(0.25);
                    let nx = raw_x * cos + raw_y * sin;
                    let ny = -raw_x * sin + raw_y * cos;
                    if nx * nx + ny * ny > 1.0 {
                        continue;
                    }
                    let offset = (usize::try_from(y).unwrap_or(0) * width_usize
                        + usize::try_from(x).unwrap_or(0))
                        * 4;
                    let grain = dab.grain.map_or(1.0, |value| {
                        preview_grain_multiplier(value, x as f32, y as f32)
                    });
                    let alpha = (dab.opacity
                        * dab.flow
                        * grain
                        * (f32::from(dab.color.a) / 255.0)
                        * (1.0 - (nx * nx + ny * ny)).clamp(0.0, 1.0)
                        * 255.0)
                        .clamp(0.0, 255.0) as u16;
                    let inverse = 255_u16.saturating_sub(alpha);
                    pixels[offset] = ((u16::from(pixels[offset]) * inverse
                        + u16::from(dab.color.r) * alpha)
                        / 255) as u8;
                    pixels[offset + 1] = ((u16::from(pixels[offset + 1]) * inverse
                        + u16::from(dab.color.g) * alpha)
                        / 255) as u8;
                    pixels[offset + 2] = ((u16::from(pixels[offset + 2]) * inverse
                        + u16::from(dab.color.b) * alpha)
                        / 255) as u8;
                    pixels[offset + 3] = (alpha
                        + (u16::from(pixels[offset + 3]) * inverse + 127) / 255)
                        .min(255) as u8;
                }
            }
        }
        let (rgba_pixels, remainder) = pixels.as_chunks_mut::<4>();
        debug_assert!(remainder.is_empty());
        for pixel in rgba_pixels {
            let alpha = u16::from(pixel[3]);
            if alpha == 0 {
                continue;
            }
            for channel in &mut pixel[..3] {
                *channel = ((u16::from(*channel) * 255 + alpha / 2) / alpha).min(255) as u8;
            }
        }
        Ok(pixels)
    }
}

fn finite_range(
    field: &'static str,
    value: f32,
    min: f32,
    max: f32,
) -> Result<(), BrushValidationError> {
    if !value.is_finite() {
        return Err(BrushValidationError::InvalidNumber(field));
    }
    if !(min..=max).contains(&value) {
        return Err(BrushValidationError::InvalidRange(field));
    }
    Ok(())
}

fn validate_tip(tip: &TipBehavior) -> Result<(), BrushValidationError> {
    match tip {
        TipBehavior::Stamp(value) => {
            finite_range("tip.diameter_px", value.diameter_px, 0.25, 4096.0)?;
            finite_range("tip.hardness", value.hardness, 0.0, 1.0)?;
            finite_range("tip.roundness", value.roundness, 0.05, 1.0)?;
            finite_range("tip.follow_stroke", value.follow_stroke, 0.0, 1.0)?;
            finite_range("tip.density", value.density, 0.0, 1.0)?;
            finite_range("tip.editor_scatter", value.editor_scatter, 0.0, 1.0)?;
            if value.impressions == 0 || usize::from(value.impressions) > MAX_TIPS {
                return Err(BrushValidationError::TooManyTips);
            }
        }
        TipBehavior::Spray(value) => {
            finite_range("spray.diameter_px", value.diameter_px, 0.25, 4096.0)?;
            finite_range("spray.particle_size_px", value.particle_size_px, 0.1, 512.0)?;
            finite_range("spray.scatter", value.scatter, 0.0, 1.0)?;
            finite_range("spray.hardness", value.hardness, 0.0, 1.0)?;
            if value.particle_count == 0 || value.particle_count as usize > MAX_RENDERED_DABS {
                return Err(BrushValidationError::WorkLimitExceeded);
            }
        }
        TipBehavior::Ribbon(value) => {
            finite_range("ribbon.width_px", value.width_px, 0.25, 4096.0)?;
            finite_range(
                "ribbon.repeat_spacing_px",
                value.repeat_spacing_px,
                0.25,
                4096.0,
            )?;
        }
        TipBehavior::Bristle(value) => {
            finite_range("bristle.diameter_px", value.diameter_px, 0.25, 4096.0)?;
            finite_range("bristle.spread", value.spread, 0.0, 1.0)?;
            finite_range("bristle.stiffness", value.stiffness, 0.0, 1.0)?;
            finite_range("bristle.lag", value.lag, 0.0, 1.0)?;
            if value.bristle_count == 0 || value.bristle_count > 128 {
                return Err(BrushValidationError::WorkLimitExceeded);
            }
        }
    }
    Ok(())
}

fn validate_paint(paint: &PaintBehavior) -> Result<(), BrushValidationError> {
    let (opacity, flow) = match paint {
        PaintBehavior::Solid(value) => (value.opacity, value.flow),
        PaintBehavior::Glaze(value) => (value.opacity, value.flow),
        PaintBehavior::Marker(value) => (value.opacity, value.flow),
        PaintBehavior::ColorPickup(value) => (value.opacity, value.flow),
        PaintBehavior::DigitalWatercolor(value) => (value.wash, value.flow),
    };
    finite_range("paint.opacity", opacity, 0.0, 1.0)?;
    finite_range("paint.flow", flow, 0.0, 1.0)?;
    Ok(())
}

fn validate_grain(grain: &GrainBehavior) -> Result<(), BrushValidationError> {
    finite_range("grain.scale", grain.scale, 0.01, 64.0)?;
    finite_range("grain.depth", grain.depth, 0.0, 1.0)?;
    finite_range("grain.contrast", grain.contrast, -1.0, 1.0)
}

fn validate_post_effect(effect: &PostEffect, max_halo_px: u32) -> Result<(), BrushValidationError> {
    if effect.halo_px() > max_halo_px || effect.halo_px() > 128 {
        return Err(BrushValidationError::WorkLimitExceeded);
    }
    match effect {
        PostEffect::DigitalWatercolorEdge {
            radius_px,
            strength,
            darkness,
            blur,
            saturation,
            hue_shift,
            ..
        } => {
            if *radius_px == 0 {
                return Err(BrushValidationError::InvalidRange("post_effect.radius_px"));
            }
            finite_range("post_effect.strength", *strength, 0.0, 1.0)?;
            finite_range("post_effect.darkness", *darkness, 0.0, 1.0)?;
            finite_range("post_effect.blur", *blur, 0.0, 1.0)?;
            finite_range("post_effect.saturation", *saturation, -1.0, 1.0)?;
            finite_range("post_effect.hue_shift", *hue_shift, -1.0, 1.0)?;
        }
        PostEffect::EdgeSoftness { radius_px, amount } => {
            if *radius_px == 0 {
                return Err(BrushValidationError::InvalidRange("post_effect.radius_px"));
            }
            finite_range("post_effect.amount", *amount, -1.0, 1.0)?;
        }
        PostEffect::StampOutline {
            radius_px, opacity, ..
        } => {
            if *radius_px == 0 {
                return Err(BrushValidationError::InvalidRange("post_effect.radius_px"));
            }
            finite_range("post_effect.opacity", *opacity, 0.0, 1.0)?;
        }
        PostEffect::TrailingFade {
            distance_px,
            amount,
        } => {
            if *distance_px == 0 {
                return Err(BrushValidationError::InvalidRange(
                    "post_effect.distance_px",
                ));
            }
            finite_range("post_effect.amount", *amount, 0.0, 1.0)?;
        }
        PostEffect::TexturePass { scale, depth, .. } => {
            finite_range("post_effect.scale", *scale, 0.01, 64.0)?;
            finite_range("post_effect.depth", *depth, 0.0, 1.0)?;
        }
    }
    Ok(())
}

impl CompiledBrush {
    /// Radius needed to include the largest dab when applying a bounded
    /// stroke-finalization effect.
    #[must_use]
    pub fn post_effect_padding_px(&self) -> u32 {
        (self.diameter() * 0.5).ceil().clamp(1.0, 4096.0) as u32
    }

    /// Emit bounded dabs for a recorded pointer path.
    pub fn render(&self, samples: &[PointerSample]) -> Result<Vec<BrushDab>, BrushValidationError> {
        if samples.is_empty() {
            return Ok(Vec::new());
        }
        let mut state = CompiledBrushState::default();
        let mut dabs = self.render_incremental(samples, &mut state)?;
        dabs.extend(
            self.finish_incremental(&mut state)?
                .into_iter()
                .map(|(dab, _eraser)| dab),
        );
        Ok(dabs)
    }

    /// Emit only the dabs attributable to newly confirmed samples.
    ///
    /// State updates are transactional: a rejected batch leaves the caller's
    /// previous state untouched. This lets the engine safely report bounded
    /// work-limit failures without corrupting a later retry.
    pub fn render_incremental(
        &self,
        samples: &[PointerSample],
        state: &mut CompiledBrushState,
    ) -> Result<Vec<BrushDab>, BrushValidationError> {
        // Keep the potentially large deferred dual-brush buffer out of the
        // per-packet state clone. New companion dabs are staged separately
        // and appended only after the current batch succeeds.
        let mut previous_dual_dabs = std::mem::take(&mut state.deferred_dual_dabs);
        let mut next_state = state.clone();
        let result = match self.render_incremental_inner(samples, &mut next_state) {
            Ok(result) => result,
            Err(error) => {
                state.deferred_dual_dabs = previous_dual_dabs;
                return Err(error);
            }
        };
        previous_dual_dabs.append(&mut next_state.deferred_dual_dabs);
        next_state.deferred_dual_dabs = previous_dual_dabs;
        *state = next_state;
        Ok(result)
    }

    /// Return dual-brush companion dabs in the same primary-then-secondary
    /// order as [`CompiledBrush::render`]. Companion dab count is bounded by
    /// the same preset work limit and is retained only for this active stroke.
    pub fn finish_incremental(
        &self,
        state: &mut CompiledBrushState,
    ) -> Result<Vec<(BrushDab, bool)>, BrushValidationError> {
        let mut next_state = state.clone();
        let pending = std::mem::take(&mut next_state.deferred_dual_dabs);
        if let Some((secondary, _)) = &self.dual
            && let Some(secondary_state) = next_state.dual_state.as_deref_mut()
        {
            let nested = secondary.finish_incremental(secondary_state)?;
            if !nested.is_empty() {
                return Err(BrushValidationError::RecursiveDual);
            }
        }
        *state = next_state;
        Ok(pending)
    }

    fn render_incremental_inner(
        &self,
        samples: &[PointerSample],
        state: &mut CompiledBrushState,
    ) -> Result<Vec<BrushDab>, BrushValidationError> {
        if samples.is_empty() {
            return Ok(Vec::new());
        }
        let diameter = self.diameter();
        let spacing = (diameter * self.stroke.spacing).max(self.stroke.minimum_spacing_px);
        let first_path_index = state.path_points_emitted;
        let path = state.append_path(
            samples,
            (self.stroke.smoothing.max(self.stroke.streamline) * 0.92).clamp(0.0, 0.95),
            spacing,
            self.limits.max_dabs,
        )?;
        if path.is_empty() {
            return Ok(Vec::new());
        }
        let mut result = Vec::new();
        let mut secondary_dab_count = 0;
        for (local_index, point) in path.iter().enumerate() {
            let index = first_path_index + local_index;
            let progress = if index == 0 {
                0.0
            } else {
                index as f32 / (index as f32 + 1.0)
            };
            let dynamic = self.dynamic_for_point(ParameterId::Diameter, point, progress);
            let mut radius = (diameter * dynamic.max(0.02)) * 0.5;
            let mut opacity =
                self.opacity() * self.dynamic_for_point(ParameterId::Opacity, point, progress);
            opacity *= taper(progress, self.stroke.taper_start, self.stroke.taper_end);
            if !opacity.is_finite() || !radius.is_finite() {
                return Err(BrushValidationError::InvalidNumber("evaluated dab"));
            }
            match &self.tip {
                TipBehavior::Stamp(tip) => {
                    let rotation = point.twist * std::f32::consts::TAU
                        + self.dynamic_for_point(ParameterId::Rotation, point, progress)
                        - 1.0;
                    let impressions = usize::from(tip.impressions);
                    for impression in 0..impressions {
                        let jitter = ((point.seed.wrapping_add(impression as u64 * 17) % 997)
                            as f32
                            / 997.0
                            - 0.5)
                            * (1.0 - tip.hardness)
                            * radius;
                        result.push(BrushDab {
                            x: point.x + jitter,
                            y: point.y - jitter,
                            radius_x: radius,
                            radius_y: radius * tip.roundness,
                            angle: tip.angle_degrees.to_radians() + rotation,
                            opacity: (opacity * tip.density / impressions as f32).clamp(0.0, 1.0),
                            flow: self.flow(),
                            grain: self.grain_stamp(),
                            tip_resource_hash: self.tip_resource_hash(),
                            color: self.color(),
                            tool: self.tool,
                            paint: self.paint_dab(),
                        });
                    }
                }
                TipBehavior::Spray(tip) => {
                    let rotation = point.twist * std::f32::consts::TAU
                        + self.dynamic_for_point(ParameterId::Rotation, point, progress)
                        - 1.0;
                    let count = tip.particle_count.min(self.limits.max_particles as u32) as usize;
                    for particle in 0..count {
                        let (unit_x, unit_y) = random_unit(point.seed, particle as u64);
                        let distance = tip.scatter * radius * (0.25 + unit_x.abs() * 0.75);
                        result.push(BrushDab {
                            x: point.x + unit_x * distance,
                            y: point.y + unit_y * distance,
                            radius_x: (tip.particle_size_px * 0.5).max(0.1),
                            radius_y: (tip.particle_size_px * 0.5).max(0.1),
                            angle: rotation,
                            opacity: (opacity / count.max(1) as f32).clamp(0.0, 1.0),
                            flow: self.flow(),
                            grain: self.grain_stamp(),
                            tip_resource_hash: self.tip_resource_hash(),
                            color: self.color(),
                            tool: self.tool,
                            paint: self.paint_dab(),
                        });
                    }
                }
                TipBehavior::Ribbon(tip) => {
                    let rotation = point.twist * std::f32::consts::TAU
                        + self.dynamic_for_point(ParameterId::Rotation, point, progress)
                        - 1.0;
                    radius = tip.width_px * 0.5 * dynamic.max(0.02);
                    result.push(BrushDab {
                        x: point.x,
                        y: point.y,
                        radius_x: radius,
                        radius_y: radius,
                        angle: if tip.follow_direction {
                            point.azimuth
                        } else {
                            rotation
                        },
                        opacity,
                        flow: self.flow(),
                        grain: self.grain_stamp(),
                        tip_resource_hash: self.tip_resource_hash(),
                        color: self.color(),
                        tool: self.tool,
                        paint: self.paint_dab(),
                    });
                }
                TipBehavior::Bristle(tip) => {
                    let rotation = point.twist * std::f32::consts::TAU
                        + self.dynamic_for_point(ParameterId::Rotation, point, progress)
                        - 1.0;
                    let count = usize::from(tip.bristle_count);
                    for bristle in 0..count {
                        let centered = bristle as f32 / count.max(1) as f32 - 0.5;
                        result.push(BrushDab {
                            x: point.x + centered * radius * 2.0 * tip.spread,
                            y: point.y,
                            radius_x: (radius / count.max(1) as f32).max(0.25),
                            radius_y: radius,
                            angle: point.azimuth + rotation,
                            opacity: (opacity / count.max(1) as f32).clamp(0.0, 1.0),
                            flow: self.flow(),
                            grain: self.grain_stamp(),
                            tip_resource_hash: self.tip_resource_hash(),
                            color: self.color(),
                            tool: self.tool,
                            paint: self.paint_dab(),
                        });
                    }
                }
            }
            if result.len() > self.limits.max_dabs {
                return Err(BrushValidationError::WorkLimitExceeded);
            }
        }
        if let Some((secondary, multiply_coverage)) = &self.dual {
            let child_state = state.dual_state.get_or_insert_default();
            let mut secondary_dabs = secondary.render_incremental_inner(samples, child_state)?;
            if *multiply_coverage {
                for dab in &mut secondary_dabs {
                    dab.opacity *= 0.75;
                }
            }
            if state
                .segment_dabs_emitted
                .saturating_add(result.len())
                .saturating_add(secondary_dabs.len())
                > self.limits.max_dabs
            {
                return Err(BrushValidationError::WorkLimitExceeded);
            }
            secondary_dab_count = secondary_dabs.len();
            let eraser = samples
                .iter()
                .any(|sample| sample.flags & ink_input::flags::ERASER != 0);
            state
                .deferred_dual_dabs
                .extend(secondary_dabs.drain(..).map(|dab| (dab, eraser)));
        }
        state.dabs_emitted = state
            .dabs_emitted
            .checked_add(result.len().saturating_add(secondary_dab_count))
            .ok_or(BrushValidationError::WorkLimitExceeded)?;
        state.segment_dabs_emitted = state
            .segment_dabs_emitted
            .checked_add(result.len().saturating_add(secondary_dab_count))
            .ok_or(BrushValidationError::WorkLimitExceeded)?;
        if state.segment_dabs_emitted > self.limits.max_dabs {
            return Err(BrushValidationError::WorkLimitExceeded);
        }
        Ok(result)
    }

    fn diameter(&self) -> f32 {
        match &self.tip {
            TipBehavior::Stamp(value) => value.diameter_px,
            TipBehavior::Spray(value) => value.diameter_px,
            TipBehavior::Ribbon(value) => value.width_px,
            TipBehavior::Bristle(value) => value.diameter_px,
        }
    }

    fn opacity(&self) -> f32 {
        match &self.paint {
            PaintBehavior::Solid(value) => value.opacity,
            PaintBehavior::Glaze(value) => value.opacity,
            PaintBehavior::Marker(value) => value.opacity,
            PaintBehavior::ColorPickup(value) => value.opacity,
            PaintBehavior::DigitalWatercolor(value) => value.wash,
        }
    }

    fn flow(&self) -> f32 {
        match &self.paint {
            PaintBehavior::Solid(value) => value.flow,
            PaintBehavior::Glaze(value) => value.flow,
            PaintBehavior::Marker(value) => value.flow,
            PaintBehavior::ColorPickup(value) => value.flow,
            PaintBehavior::DigitalWatercolor(value) => value.flow,
        }
    }

    fn grain_stamp(&self) -> Option<GrainStamp> {
        self.grain.as_ref().map(|grain| GrainStamp {
            resource_hash: grain.resource_hash,
            scale: grain.scale,
            depth: grain.depth,
            contrast: grain.contrast,
            canvas_space: grain.canvas_space,
        })
    }

    fn tip_resource_hash(&self) -> Option<[u8; 32]> {
        match &self.tip {
            TipBehavior::Stamp(tip) => tip.resource_hash,
            _ => None,
        }
    }

    fn paint_dab(&self) -> BrushPaint {
        match &self.paint {
            PaintBehavior::Solid(_) => BrushPaint::Solid,
            PaintBehavior::Glaze(_) => BrushPaint::Glaze,
            PaintBehavior::Marker(_) => BrushPaint::Marker,
            PaintBehavior::ColorPickup(value) => BrushPaint::ColorPickup {
                pickup: value.pickup,
                deposit: value.deposit,
                dilution: value.dilution,
                blur: value.blur,
            },
            PaintBehavior::DigitalWatercolor(value) => BrushPaint::DigitalWatercolor {
                dilution: value.dilution,
                pickup: value.pickup,
                granulation: value.granulation,
                edge_pooling: value.edge_pooling,
                paper_resist: value.paper_resist,
            },
        }
    }

    fn color(&self) -> Rgba8 {
        match &self.paint {
            PaintBehavior::Solid(value) => value.color,
            PaintBehavior::Glaze(value) => value.color,
            PaintBehavior::Marker(value) => value.color,
            PaintBehavior::ColorPickup(value) => value.color,
            PaintBehavior::DigitalWatercolor(value) => value.color,
        }
    }

    fn dynamic_for_point(&self, target: ParameterId, point: &PathPoint, progress: f32) -> f32 {
        let mut current = None;
        for binding in self
            .dynamics
            .iter()
            .filter(|binding| binding.target == target)
        {
            // `base` is the target's normalized starting value.  It must be
            // applied once, while additional bindings compose with the
            // already-modulated value.  This also keeps imported presets with
            // a non-default base from silently rendering at 1.0.
            let value = current.get_or_insert(binding.base);
            let sensor = normalized_sensor(binding.sensor, point, progress);
            let mapped = binding.curve.evaluate(sensor);
            *value = match binding.combine {
                CombineOp::Add => *value + mapped * binding.amount,
                CombineOp::Multiply => *value * (1.0 + mapped * binding.amount),
                CombineOp::Replace => mapped * binding.amount,
                CombineOp::Minimum => (*value).min(mapped * binding.amount),
                CombineOp::Maximum => (*value).max(mapped * binding.amount),
            };
        }
        current.unwrap_or(1.0).clamp(0.0, 2.0)
    }
}

/// Convert a wire/path sensor to the normalized domain required by a response
/// curve.  Only azimuth is angular in the packet; all other values are already
/// normalized by the platform adapter or derived from normalized samples.
fn normalized_sensor(sensor: SensorId, point: &PathPoint, progress: f32) -> f32 {
    match sensor {
        SensorId::Pressure => point.pressure.clamp(0.0, 1.0),
        SensorId::Tilt
        | SensorId::Rotation
        | SensorId::Speed
        | SensorId::Distance
        | SensorId::Progress
        | SensorId::RandomPerDab => {
            let value = match sensor {
                SensorId::Tilt => point.tilt,
                SensorId::Rotation => point.twist,
                SensorId::Speed => point.speed,
                SensorId::Distance | SensorId::Progress => progress,
                SensorId::RandomPerDab => (point.seed % 10_000) as f32 / 10_000.0,
                SensorId::Pressure | SensorId::Direction => unreachable!(),
            };
            value.clamp(0.0, 1.0)
        }
        SensorId::Direction => (point.azimuth / std::f32::consts::TAU).rem_euclid(1.0),
    }
}

#[derive(Clone, Copy, Debug)]
struct PathPoint {
    x: f32,
    y: f32,
    pressure: f32,
    tilt: f32,
    azimuth: f32,
    twist: f32,
    speed: f32,
    timestamp_ns: u64,
    seed: u64,
}

impl CompiledBrushState {
    fn append_path(
        &mut self,
        samples: &[PointerSample],
        smoothing_amount: f32,
        spacing: f32,
        limit: usize,
    ) -> Result<Vec<PathPoint>, BrushValidationError> {
        let mut result = Vec::new();
        for sample in samples {
            let conditioned = if let Some(previous) = self.conditioned_anchor {
                let keep = 1.0 - smoothing_amount;
                let mut filtered = *sample;
                filtered.canvas_x =
                    previous.canvas_x + (sample.canvas_x - previous.canvas_x) * keep;
                filtered.canvas_y =
                    previous.canvas_y + (sample.canvas_y - previous.canvas_y) * keep;
                filtered.tilt_x = previous.tilt_x + (sample.tilt_x - previous.tilt_x) * keep;
                filtered.tilt_y = previous.tilt_y + (sample.tilt_y - previous.tilt_y) * keep;
                filtered.azimuth = previous.azimuth + (sample.azimuth - previous.azimuth) * keep;
                filtered.twist = previous.twist + (sample.twist - previous.twist) * keep;
                filtered
            } else {
                *sample
            };
            self.conditioned_anchor = Some(conditioned);

            let Some(mut anchor) = self.path_anchor else {
                let point = PathPoint {
                    x: conditioned.canvas_x,
                    y: conditioned.canvas_y,
                    pressure: f32::from(conditioned.pressure) / f32::from(u16::MAX),
                    tilt: conditioned.tilt_x.hypot(conditioned.tilt_y).clamp(0.0, 1.0),
                    azimuth: conditioned.azimuth,
                    twist: conditioned.twist,
                    speed: 0.0,
                    timestamp_ns: conditioned.timestamp_ns,
                    seed: u64::from(conditioned.sequence),
                };
                self.path_anchor = Some(point);
                result.push(point);
                continue;
            };

            let dx = conditioned.canvas_x - anchor.x;
            let dy = conditioned.canvas_y - anchor.y;
            let distance = dx.hypot(dy);
            if distance < spacing {
                continue;
            }
            let steps = (distance / spacing).floor() as usize;
            if self
                .segment_path_points_emitted
                .saturating_add(result.len())
                .saturating_add(steps)
                > limit
            {
                return Err(BrushValidationError::WorkLimitExceeded);
            }
            for step in 1..=steps {
                let fraction = (step as f32 * spacing / distance).min(1.0);
                result.push(PathPoint {
                    x: anchor.x + dx * fraction,
                    y: anchor.y + dy * fraction,
                    pressure: anchor.pressure
                        + (f32::from(conditioned.pressure) / f32::from(u16::MAX) - anchor.pressure)
                            * fraction,
                    tilt: anchor.tilt
                        + (conditioned.tilt_x.hypot(conditioned.tilt_y).clamp(0.0, 1.0)
                            - anchor.tilt)
                            * fraction,
                    azimuth: anchor.azimuth + (conditioned.azimuth - anchor.azimuth) * fraction,
                    twist: anchor.twist + (conditioned.twist - anchor.twist) * fraction,
                    speed: anchor.speed + sample_speed(anchor, &conditioned) * fraction,
                    timestamp_ns: conditioned.timestamp_ns,
                    seed: u64::from(conditioned.sequence).wrapping_add(step as u64),
                });
            }
            anchor = PathPoint {
                x: conditioned.canvas_x,
                y: conditioned.canvas_y,
                pressure: f32::from(conditioned.pressure) / f32::from(u16::MAX),
                tilt: conditioned.tilt_x.hypot(conditioned.tilt_y).clamp(0.0, 1.0),
                azimuth: conditioned.azimuth,
                twist: conditioned.twist,
                speed: sample_speed(anchor, &conditioned),
                timestamp_ns: conditioned.timestamp_ns,
                seed: u64::from(conditioned.sequence),
            };
            self.path_anchor = Some(anchor);
        }
        self.path_points_emitted = self
            .path_points_emitted
            .checked_add(result.len())
            .ok_or(BrushValidationError::WorkLimitExceeded)?;
        self.segment_path_points_emitted = self
            .segment_path_points_emitted
            .checked_add(result.len())
            .ok_or(BrushValidationError::WorkLimitExceeded)?;
        Ok(result)
    }
}

fn sample_speed(anchor: PathPoint, sample: &PointerSample) -> f32 {
    let distance = (sample.canvas_x - anchor.x).hypot(sample.canvas_y - anchor.y);
    let elapsed = sample
        .timestamp_ns
        .saturating_sub(anchor.timestamp_ns)
        .max(1);
    (distance / elapsed as f32 * 1_000_000_000.0 / 2048.0).clamp(0.0, 1.0)
}

fn taper(progress: f32, start: f32, end: f32) -> f32 {
    let start_factor = if start == 0.0 {
        1.0
    } else {
        (progress / start).clamp(0.0, 1.0)
    };
    let end_factor = if end == 0.0 {
        1.0
    } else {
        ((1.0 - progress) / end).clamp(0.0, 1.0)
    };
    start_factor.min(end_factor)
}

fn random_unit(seed: u64, index: u64) -> (f32, f32) {
    let mut value = seed
        .wrapping_add(index.wrapping_mul(0x9e37_79b9_7f4a_7c15))
        .wrapping_add(0xa5a5_a5a5_a5a5_a5a5);
    value ^= value >> 30;
    value = value.wrapping_mul(0xbf58_476d_1ce4_e5b9);
    value ^= value >> 27;
    value = value.wrapping_mul(0x94d0_49bb_1331_11eb);
    value ^= value >> 31;
    let angle = (value as f64 / u64::MAX as f64 * std::f64::consts::TAU) as f32;
    let radius = ((value.rotate_left(17) as f64 / u64::MAX as f64) as f32).sqrt();
    (angle.cos() * radius, angle.sin() * radius)
}

fn preview_grain_multiplier(grain: GrainStamp, x: f32, y: f32) -> f32 {
    let scale = grain.scale.clamp(0.01, 64.0);
    let qx = (x * scale).floor() as i64;
    let qy = (y * scale).floor() as i64;
    let mut state = u64::from_le_bytes(grain.resource_hash[..8].try_into().unwrap_or([0; 8]));
    state ^= (qx as u64).wrapping_mul(0x9e37_79b9_7f4a_7c15);
    state ^= (qy as u64).wrapping_mul(0xbf58_476d_1ce4_e5b9);
    state ^= state >> 30;
    state = state.wrapping_mul(0xbf58_476d_1ce4_e5b9);
    state ^= state >> 27;
    let noise = (state as f32 / u64::MAX as f32).clamp(0.0, 1.0);
    let contrast = (1.0 + (noise - 0.5) * 2.0 * grain.contrast.clamp(-1.0, 1.0)).clamp(0.0, 2.0);
    let depth = grain.depth.clamp(0.0, 1.0);
    (1.0 - depth + depth * contrast).clamp(0.0, 2.0)
}

fn base_preset(
    id: u128,
    name: &str,
    tags: &[&str],
    tip: TipBehavior,
    paint: PaintBehavior,
) -> BrushPresetV2 {
    BrushPresetV2 {
        format_version: 2,
        engine_semantics: EngineSemantics::default(),
        id: BrushId::from_u128(id),
        revision: 1,
        metadata: BrushMetadata::builtin(name, tags),
        tool: ToolBehavior::Deposit,
        stroke: StrokeBehavior::default(),
        tip,
        grain: None,
        paint,
        dynamics: Vec::new(),
        dual: None,
        post_effects: Vec::new(),
        limits: BrushLimits::default(),
    }
}

fn pressure_binding(target: ParameterId, amount: f32) -> ParameterBinding {
    ParameterBinding {
        target,
        base: 1.0,
        sensor: SensorId::Pressure,
        // Stylus force commonly occupies only a small part of the platform's
        // normalized range during ordinary drawing. Give that low-force range
        // useful resolution while preserving the firm-pressure endpoint; each
        // brush's amount still controls how strongly pressure changes its
        // parameter.
        curve: ResponseCurve {
            points: vec![
                CurvePoint { x: 0.0, y: 0.0 },
                CurvePoint { x: 0.02, y: 0.18 },
                CurvePoint { x: 0.05, y: 0.38 },
                CurvePoint { x: 0.1, y: 0.56 },
                CurvePoint { x: 0.3, y: 0.78 },
                CurvePoint { x: 0.6, y: 0.92 },
                CurvePoint { x: 1.0, y: 1.0 },
            ],
        },
        amount,
        combine: CombineOp::Multiply,
    }
}

/// High-quality original starter library for Phase 2.
#[must_use]
pub fn builtin_library() -> Vec<BrushPresetV2> {
    let dark = Rgba8 {
        r: 24,
        g: 24,
        b: 28,
        a: 255,
    };
    let mut presets = vec![
        base_preset(
            1,
            "Technical Pen",
            &["ink", "technical"],
            TipBehavior::Stamp(StampTip {
                diameter_px: 4.0,
                ..StampTip::default()
            }),
            PaintBehavior::Solid(SolidPaint {
                color: dark,
                opacity: 1.0,
                flow: 1.0,
                accumulation: AccumulationMode::UniformStroke,
            }),
        ),
        base_preset(
            2,
            "HB Sketch Pencil",
            &["sketch", "pencil"],
            TipBehavior::Stamp(StampTip {
                diameter_px: 6.0,
                hardness: 0.55,
                density: 0.72,
                ..StampTip::default()
            }),
            PaintBehavior::Glaze(GlazePaint {
                color: dark,
                opacity: 0.55,
                flow: 0.65,
                accumulation: AccumulationMode::Glaze,
            }),
        ),
        base_preset(
            3,
            "Opaque Round",
            &["paint", "opaque"],
            TipBehavior::Stamp(StampTip {
                diameter_px: 24.0,
                ..StampTip::default()
            }),
            PaintBehavior::Solid(SolidPaint {
                color: dark,
                opacity: 1.0,
                flow: 1.0,
                accumulation: AccumulationMode::BuildUp,
            }),
        ),
        base_preset(
            4,
            "Soft Airbrush",
            &["paint", "airbrush"],
            TipBehavior::Stamp(StampTip {
                diameter_px: 80.0,
                hardness: 0.05,
                density: 0.55,
                ..StampTip::default()
            }),
            PaintBehavior::Glaze(GlazePaint {
                color: dark,
                opacity: 0.18,
                flow: 0.3,
                accumulation: AccumulationMode::Glaze,
            }),
        ),
        base_preset(
            5,
            "Marker",
            &["ink", "marker"],
            TipBehavior::Stamp(StampTip {
                diameter_px: 14.0,
                hardness: 0.7,
                ..StampTip::default()
            }),
            PaintBehavior::Marker(MarkerPaint {
                color: dark,
                opacity: 0.8,
                flow: 0.8,
            }),
        ),
        base_preset(
            6,
            "G-Pen",
            &["ink", "pressure"],
            TipBehavior::Stamp(StampTip {
                diameter_px: 10.0,
                hardness: 0.9,
                ..StampTip::default()
            }),
            PaintBehavior::Solid(SolidPaint {
                color: dark,
                opacity: 1.0,
                flow: 1.0,
                accumulation: AccumulationMode::BuildUp,
            }),
        ),
        base_preset(
            7,
            "Dry Gouache",
            &["paint", "gouache"],
            TipBehavior::Bristle(BristleTip {
                diameter_px: 28.0,
                bristle_count: 24,
                spread: 0.6,
                stiffness: 0.75,
                lag: 0.12,
            }),
            PaintBehavior::Solid(SolidPaint {
                color: dark,
                opacity: 0.85,
                flow: 0.8,
                accumulation: AccumulationMode::BuildUp,
            }),
        ),
        base_preset(
            8,
            "Digital Watercolor Wash",
            &["paint", "watercolor"],
            TipBehavior::Stamp(StampTip {
                diameter_px: 42.0,
                hardness: 0.35,
                density: 0.7,
                ..StampTip::default()
            }),
            PaintBehavior::DigitalWatercolor(DigitalWatercolorPaint {
                color: dark,
                wash: 0.42,
                flow: 0.45,
                dilution: 0.55,
                pickup: 0.3,
                granulation: 0.4,
                edge_pooling: 0.6,
                paper_resist: 0.35,
            }),
        ),
        base_preset(
            9,
            "Watercolor Blender",
            &["blend", "watercolor"],
            TipBehavior::Stamp(StampTip {
                diameter_px: 38.0,
                hardness: 0.2,
                density: 0.65,
                ..StampTip::default()
            }),
            PaintBehavior::ColorPickup(ColorPickupPaint {
                color: dark,
                opacity: 0.45,
                flow: 0.35,
                pickup: 0.8,
                deposit: 0.2,
                dilution: 0.6,
                blur: 0.35,
            }),
        ),
        base_preset(
            10,
            "Ink Spatter",
            &["effect", "spatter"],
            TipBehavior::Spray(SprayTip {
                diameter_px: 30.0,
                particle_count: 18,
                particle_size_px: 3.0,
                scatter: 1.0,
                hardness: 0.8,
            }),
            PaintBehavior::Solid(SolidPaint {
                color: dark,
                opacity: 0.65,
                flow: 0.8,
                accumulation: AccumulationMode::BuildUp,
            }),
        ),
        base_preset(
            11,
            "Ribbon Chain",
            &["effect", "ribbon"],
            TipBehavior::Ribbon(RibbonTip {
                width_px: 16.0,
                repeat_spacing_px: 14.0,
                follow_direction: true,
            }),
            PaintBehavior::Solid(SolidPaint {
                color: dark,
                opacity: 0.9,
                flow: 0.9,
                accumulation: AccumulationMode::BuildUp,
            }),
        ),
        base_preset(
            12,
            "Acrylic Rake",
            &["paint", "bristle"],
            TipBehavior::Bristle(BristleTip {
                diameter_px: 30.0,
                bristle_count: 32,
                spread: 0.85,
                stiffness: 0.8,
                lag: 0.08,
            }),
            PaintBehavior::Solid(SolidPaint {
                color: dark,
                opacity: 0.9,
                flow: 0.85,
                accumulation: AccumulationMode::BuildUp,
            }),
        ),
    ];
    presets.extend([
        base_preset(
            STARTER_BRUSH_ID_BASE + 1,
            "Soft Graphite",
            &["sketch", "pencil", "soft"],
            TipBehavior::Stamp(StampTip {
                diameter_px: 8.0,
                hardness: 0.28,
                density: 0.62,
                ..StampTip::default()
            }),
            PaintBehavior::Glaze(GlazePaint {
                color: dark,
                opacity: 0.72,
                flow: 0.6,
                accumulation: AccumulationMode::Glaze,
            }),
        ),
        base_preset(
            STARTER_BRUSH_ID_BASE + 2,
            "Charcoal",
            &["sketch", "charcoal", "texture"],
            TipBehavior::Stamp(StampTip {
                diameter_px: 18.0,
                hardness: 0.18,
                density: 0.52,
                ..StampTip::default()
            }),
            PaintBehavior::Glaze(GlazePaint {
                color: dark,
                opacity: 0.78,
                flow: 0.68,
                accumulation: AccumulationMode::BuildUp,
            }),
        ),
        base_preset(
            STARTER_BRUSH_ID_BASE + 3,
            "Brush Pen",
            &["ink", "pressure", "taper"],
            TipBehavior::Bristle(BristleTip {
                diameter_px: 18.0,
                bristle_count: 12,
                spread: 0.32,
                stiffness: 0.82,
                lag: 0.04,
            }),
            PaintBehavior::Solid(SolidPaint {
                color: dark,
                opacity: 1.0,
                flow: 1.0,
                accumulation: AccumulationMode::UniformStroke,
            }),
        ),
        base_preset(
            STARTER_BRUSH_ID_BASE + 4,
            "Dry Ink",
            &["ink", "texture", "dry"],
            TipBehavior::Stamp(StampTip {
                diameter_px: 7.0,
                hardness: 0.7,
                density: 0.78,
                ..StampTip::default()
            }),
            PaintBehavior::Glaze(GlazePaint {
                color: dark,
                opacity: 0.88,
                flow: 0.74,
                accumulation: AccumulationMode::BuildUp,
            }),
        ),
        base_preset(
            STARTER_BRUSH_ID_BASE + 5,
            "Flat Paint",
            &["paint", "opaque", "flat"],
            TipBehavior::Stamp(StampTip {
                diameter_px: 32.0,
                hardness: 0.82,
                roundness: 0.58,
                ..StampTip::default()
            }),
            PaintBehavior::Solid(SolidPaint {
                color: dark,
                opacity: 0.96,
                flow: 0.9,
                accumulation: AccumulationMode::BuildUp,
            }),
        ),
        base_preset(
            STARTER_BRUSH_ID_BASE + 6,
            "Soft Blender",
            &["blend", "smudge", "soft"],
            TipBehavior::Stamp(StampTip {
                diameter_px: 36.0,
                hardness: 0.08,
                density: 0.64,
                ..StampTip::default()
            }),
            PaintBehavior::ColorPickup(ColorPickupPaint {
                color: dark,
                opacity: 0.82,
                flow: 0.45,
                pickup: 0.62,
                deposit: 0.1,
                dilution: 0.28,
                blur: 0.18,
            }),
        ),
        base_preset(
            STARTER_BRUSH_ID_BASE + 7,
            "Hard Eraser",
            &["eraser", "hard", "clean"],
            TipBehavior::Stamp(StampTip {
                diameter_px: 24.0,
                hardness: 0.98,
                ..StampTip::default()
            }),
            PaintBehavior::Solid(SolidPaint {
                color: dark,
                opacity: 1.0,
                flow: 1.0,
                accumulation: AccumulationMode::Erase,
            }),
        ),
        base_preset(
            STARTER_BRUSH_ID_BASE + 8,
            "Soft Eraser",
            &["eraser", "soft"],
            TipBehavior::Stamp(StampTip {
                diameter_px: 36.0,
                hardness: 0.18,
                ..StampTip::default()
            }),
            PaintBehavior::Solid(SolidPaint {
                color: dark,
                opacity: 0.46,
                flow: 0.58,
                accumulation: AccumulationMode::Erase,
            }),
        ),
    ]);
    // The default ink pen should visibly respond to Apple Pencil pressure;
    // with no dynamics configured, its incoming pressure samples were ignored.
    presets[0]
        .dynamics
        .push(pressure_binding(ParameterId::Diameter, 0.55));
    presets[1]
        .dynamics
        .push(pressure_binding(ParameterId::Diameter, 0.55));
    presets[5]
        .dynamics
        .push(pressure_binding(ParameterId::Diameter, 0.85));
    for index in [12, 13, 14, 15] {
        presets[index]
            .dynamics
            .push(pressure_binding(ParameterId::Diameter, 0.62));
    }
    presets[14].stroke.taper_start = 0.08;
    presets[14].stroke.taper_end = 0.18;
    presets[14].stroke.smoothing = 0.12;
    presets[15].stroke.taper_end = 0.08;
    presets[15].grain = Some(GrainBehavior {
        resource_hash: [0x55; 32],
        scale: 1.0,
        depth: 0.2,
        contrast: 0.35,
        canvas_space: true,
    });
    presets[6]
        .dynamics
        .push(pressure_binding(ParameterId::Opacity, 0.35));
    presets[8].tool = ToolBehavior::Smudge;
    presets[1].grain = Some(GrainBehavior {
        resource_hash: [0x11; 32],
        scale: 1.8,
        depth: 0.32,
        contrast: 0.55,
        canvas_space: true,
    });
    presets[6].grain = Some(GrainBehavior {
        resource_hash: [0x22; 32],
        scale: 1.25,
        depth: 0.28,
        contrast: 0.4,
        canvas_space: true,
    });
    presets[7].grain = Some(GrainBehavior {
        resource_hash: [0x33; 32],
        scale: 0.85,
        depth: 0.24,
        contrast: 0.35,
        canvas_space: true,
    });
    presets[8].grain = Some(GrainBehavior {
        resource_hash: [0x44; 32],
        scale: 0.75,
        depth: 0.18,
        contrast: 0.3,
        canvas_space: true,
    });
    presets[10].dynamics.push(ParameterBinding {
        target: ParameterId::Rotation,
        base: 1.0,
        sensor: SensorId::Rotation,
        curve: ResponseCurve::identity(),
        amount: 0.5,
        combine: CombineOp::Add,
    });
    let dual_component = presets[0].clone();
    presets[10].dual = Some(DualBrush {
        secondary: Box::new(dual_component),
        multiply_coverage: true,
    });
    presets[7]
        .post_effects
        .push(PostEffect::DigitalWatercolorEdge {
            radius_px: 6,
            strength: 0.55,
            darkness: 0.3,
            blur: 0.25,
            saturation: 0.12,
            hue_shift: 0.0,
            style: WatercolorEdgeStyle::Standard,
            timing: PostEffectTiming::StrokeEnd,
        });
    presets
}

#[cfg(test)]
mod tests {
    use super::*;
    use ink_input::{DeviceKind, Phase};

    fn sample(x: f32, pressure: u16, sequence: u32) -> PointerSample {
        PointerSample {
            pointer_id: 1,
            flags: 1,
            device_kind: DeviceKind::Stylus,
            phase: Phase::Move,
            canvas_x: x,
            canvas_y: 10.0,
            pressure,
            tilt_x: 0.0,
            tilt_y: 0.0,
            azimuth: 0.0,
            twist: 0.0,
            timestamp_ns: u64::from(sequence),
            sequence,
        }
    }

    #[test]
    fn builtin_library_contains_deterministic_phase_two_brushes() {
        let library = builtin_library();
        assert_eq!(library.len(), 20);
        let ids = library
            .iter()
            .map(|brush| brush.id)
            .collect::<std::collections::HashSet<_>>();
        let names = library
            .iter()
            .map(|brush| brush.metadata.name.as_str())
            .collect::<std::collections::HashSet<_>>();
        assert_eq!(ids.len(), library.len(), "built-in IDs must be unique");
        assert_eq!(names.len(), library.len(), "built-in names must be unique");
        assert!(library.iter().all(|brush| brush.validate().is_ok()));
        assert_eq!(library[0].id, BrushId::from_u128(1));
        assert_eq!(
            library[12].id,
            BrushId::from_u128(STARTER_BRUSH_ID_BASE + 1),
        );
        assert!(library.iter().any(|brush| brush.grain.is_some()));
    }

    #[test]
    fn technical_pen_diameter_responds_to_pressure() {
        let compiled = builtin_library()
            .remove(0)
            .compile()
            .expect("valid technical pen");
        let light = compiled
            .render(&[sample(0.0, 0, 1), sample(20.0, 0, 2)])
            .expect("light-pressure stroke");
        let firm = compiled
            .render(&[sample(0.0, u16::MAX, 1), sample(20.0, u16::MAX, 2)])
            .expect("firm-pressure stroke");

        assert!(
            light[0].radius_x < firm[0].radius_x,
            "firm pressure should produce a wider technical-pen mark"
        );
    }

    #[test]
    fn g_pen_responds_across_light_apple_pencil_pressure() {
        let compiled = builtin_library()
            .into_iter()
            .find(|preset| preset.metadata.name == "G-Pen")
            .expect("built-in G-Pen")
            .compile()
            .expect("valid G-Pen");
        let light = compiled
            .render(&[sample(0.0, 1_311, 1)])
            .expect("light-pressure dab");
        let firm = compiled
            .render(&[sample(0.0, 3_932, 1)])
            .expect("firm-pressure dab");

        assert_eq!(light.len(), 1);
        assert_eq!(firm.len(), 1);
        assert!(
            firm[0].radius_x > light[0].radius_x * 1.15,
            "G-Pen should visibly widen from 0.02 to 0.06 normalized Pencil pressure"
        );
    }

    #[test]
    fn starter_pen_pressure_profile_responds_earlier_than_linear() {
        let preset = builtin_library().remove(0);
        let binding = preset
            .dynamics
            .iter()
            .find(|binding| {
                binding.sensor == SensorId::Pressure && binding.target == ParameterId::Diameter
            })
            .expect("starter pen pressure binding");

        assert!(binding.curve.evaluate(0.2) > 0.2);
        assert!((binding.curve.evaluate(1.0) - 1.0).abs() < f32::EPSILON);
    }

    #[test]
    fn pressure_and_spray_evaluation_is_bounded_and_repeatable() {
        for brush in builtin_library() {
            let compiled = brush.compile().expect("valid built-in");
            let samples = [sample(0.0, u16::MAX / 2, 1), sample(40.0, u16::MAX, 2)];
            let first = compiled.render(&samples).expect("render");
            let second = compiled.render(&samples).expect("render");
            assert_eq!(first, second);
            assert!(first.len() <= brush.limits.max_dabs);
            assert!(
                first
                    .iter()
                    .all(|dab| dab.opacity.is_finite() && dab.flow.is_finite())
            );
        }
    }

    #[test]
    fn incremental_evaluation_matches_full_strokes_for_every_builtin_brush() {
        let samples = (0..257)
            .map(|index| {
                let mut point = sample(
                    index as f32 * 0.7,
                    (index as u16).wrapping_mul(251),
                    index as u32,
                );
                point.canvas_y = 10.0 + (index as f32 * 0.11).sin() * 12.0;
                point.tilt_x = (index as f32 / 257.0).clamp(0.0, 1.0);
                point.azimuth = index as f32 * 0.015;
                point.twist = (index as f32 * 0.031).fract();
                point
            })
            .collect::<Vec<_>>();

        for preset in builtin_library() {
            let compiled = preset.compile().expect("valid built-in");
            let expected = compiled.render(&samples).expect("full path renders");
            let mut state = CompiledBrushState::default();
            let mut streamed = Vec::new();
            for packet in samples.chunks(7) {
                streamed.extend(
                    compiled
                        .render_incremental(packet, &mut state)
                        .expect("sample batch renders"),
                );
            }
            streamed.extend(
                compiled
                    .finish_incremental(&mut state)
                    .expect("companion brush finalizes")
                    .into_iter()
                    .map(|(dab, _eraser)| dab),
            );
            assert_eq!(
                streamed, expected,
                "incremental mismatch: {}",
                preset.metadata.name
            );
        }
    }

    #[test]
    fn work_segments_preserve_one_continuous_compiled_stroke() {
        let mut segmented_preset = builtin_library().remove(0);
        segmented_preset.limits.max_dabs = 24;
        let segmented = segmented_preset.compile().expect("segmented brush");
        let mut reference_preset = segmented_preset;
        reference_preset.limits.max_dabs = 512;
        let reference = reference_preset.compile().expect("reference brush");
        let samples = (0..100)
            .map(|index| sample(index as f32 * 2.0, u16::MAX, index))
            .collect::<Vec<_>>();

        let expected = reference.render(&samples).expect("reference render");
        let mut state = CompiledBrushState::default();
        let mut actual = Vec::new();
        let mut segments = 0;
        for packet in samples.chunks(1) {
            let mut rendered = segmented.render_incremental(packet, &mut state);
            if matches!(rendered, Err(BrushValidationError::WorkLimitExceeded)) {
                assert!(state.begin_work_segment(), "no companion work pending");
                segments += 1;
                rendered = segmented.render_incremental(packet, &mut state);
            }
            actual.extend(rendered.expect("segment retry renders"));
            if state.segment_work_near_limit(segmented.limits.max_dabs)
                && state.begin_work_segment()
            {
                segments += 1;
            }
        }
        actual.extend(
            segmented
                .finish_incremental(&mut state)
                .expect("finish")
                .into_iter()
                .map(|(dab, _)| dab),
        );
        assert!(segments > 1, "the sample path should cross work segments");
        assert_eq!(actual, expected);
    }

    #[test]
    fn validation_rejects_non_monotone_curves_and_recursive_duals() {
        let mut brush = builtin_library().remove(0);
        brush.dynamics.push(ParameterBinding {
            target: ParameterId::Opacity,
            base: 1.0,
            sensor: SensorId::Pressure,
            curve: ResponseCurve {
                points: vec![CurvePoint { x: 0.5, y: 0.2 }, CurvePoint { x: 0.4, y: 0.7 }],
            },
            amount: 1.0,
            combine: CombineOp::Multiply,
        });
        assert_eq!(
            brush.validate(),
            Err(BrushValidationError::InvalidRange("curve.x ordering"))
        );
        let mut recursive = builtin_library().remove(0);
        let child = recursive.clone();
        recursive.dual = Some(DualBrush {
            secondary: Box::new(BrushPresetV2 {
                dual: Some(DualBrush {
                    secondary: Box::new(child.clone()),
                    multiply_coverage: false,
                }),
                ..child
            }),
            multiply_coverage: false,
        });
        assert_eq!(
            recursive.validate(),
            Err(BrushValidationError::RecursiveDual)
        );
    }

    #[test]
    fn rotation_sensor_reaches_oriented_dabs() {
        let mut preset = builtin_library().remove(0);
        preset.dynamics.push(ParameterBinding {
            target: ParameterId::Rotation,
            base: 1.0,
            sensor: SensorId::Rotation,
            curve: ResponseCurve::identity(),
            amount: 0.75,
            combine: CombineOp::Add,
        });
        let compiled = preset.compile().expect("preset");
        let mut first = sample(0.0, u16::MAX, 1);
        first.twist = 0.0;
        let mut second = sample(16.0, u16::MAX, 2);
        second.twist = 0.75;
        second.tilt_x = 0.6;
        second.azimuth = 0.5;
        let dabs = compiled.render(&[first, second]).expect("dabs");
        assert!(dabs.iter().any(|dab| dab.angle.abs() > 0.1));
    }

    #[test]
    fn pressure_curve_reaches_its_endpoint_without_wrapping() {
        let mut preset = builtin_library().remove(0);
        preset.dynamics.push(ParameterBinding {
            target: ParameterId::Diameter,
            base: 0.1,
            sensor: SensorId::Pressure,
            curve: ResponseCurve {
                points: vec![CurvePoint { x: 0.0, y: 0.0 }, CurvePoint { x: 1.0, y: 1.0 }],
            },
            amount: 1.0,
            combine: CombineOp::Replace,
        });
        let compiled = preset.compile().expect("preset");
        let low = compiled.render(&[sample(0.0, 0, 1)]).expect("low pressure");
        let high = compiled
            .render(&[sample(0.0, u16::MAX, 2)])
            .expect("high pressure");
        assert!(low[0].radius_x < 0.1);
        assert!((high[0].radius_x - 2.0).abs() < f32::EPSILON);
    }

    #[test]
    fn binding_base_is_used_as_the_initial_value() {
        let mut preset = builtin_library().remove(0);
        // Keep this regression focused on the binding under test. Starter
        // presets already define a pressure-to-diameter binding, whose base
        // correctly becomes the initial value when it appears first.
        preset.dynamics.clear();
        preset.dynamics.push(ParameterBinding {
            target: ParameterId::Diameter,
            base: 0.25,
            sensor: SensorId::Pressure,
            curve: ResponseCurve::identity(),
            amount: 0.0,
            combine: CombineOp::Add,
        });
        let compiled = preset.compile().expect("preset");
        let dabs = compiled
            .render(&[sample(0.0, u16::MAX / 2, 1)])
            .expect("render");
        assert!((dabs[0].radius_x - 0.5).abs() < f32::EPSILON);
    }

    #[test]
    fn preview_is_bounded_and_deterministic() {
        let preset = builtin_library().into_iter().nth(6).expect("preset");
        let first = preset.preview_rgba8(160, 64).expect("preview");
        let second = preset.preview_rgba8(160, 64).expect("preview");
        assert_eq!(first, second);
        assert_eq!(first.len(), 160 * 64 * 4);
        assert!(first.as_chunks::<4>().0.iter().any(|pixel| pixel[3] > 0));
    }

    #[test]
    fn post_effects_are_compiled_bounded_and_backward_compatible() {
        let watercolor = builtin_library()
            .into_iter()
            .find(|preset| preset.metadata.name == "Digital Watercolor Wash")
            .expect("watercolor preset");
        assert_eq!(watercolor.post_effects.len(), 1);
        let compiled = watercolor.compile().expect("compiled watercolor");
        assert_eq!(compiled.post_effects.len(), 1);
        assert!(compiled.post_effect_padding_px() >= 1);

        let legacy_json = serde_json::to_value(BrushPresetV2 {
            post_effects: Vec::new(),
            ..watercolor.clone()
        })
        .expect("serialize");
        let object = legacy_json.as_object().expect("object");
        let mut without_field = object.clone();
        without_field.remove("post_effects");
        let restored: BrushPresetV2 =
            serde_json::from_value(without_field.into()).expect("old v2 preset remains readable");
        assert!(restored.post_effects.is_empty());
    }

    #[test]
    fn post_effect_limits_reject_untrusted_values() {
        let mut preset = builtin_library().remove(0);
        preset.post_effects = vec![PostEffect::EdgeSoftness {
            radius_px: 129,
            amount: 0.5,
        }];
        assert_eq!(
            preset.validate(),
            Err(BrushValidationError::WorkLimitExceeded)
        );
        preset.post_effects = vec![PostEffect::EdgeSoftness {
            radius_px: 4,
            amount: f32::NAN,
        }];
        assert_eq!(
            preset.validate(),
            Err(BrushValidationError::InvalidNumber("post_effect.amount"))
        );
        preset.post_effects = (0..=MAX_POST_EFFECTS)
            .map(|_| PostEffect::TexturePass {
                resource_hash: [0x55; 32],
                scale: 1.0,
                depth: 0.2,
            })
            .collect();
        assert_eq!(
            preset.validate(),
            Err(BrushValidationError::TooManyPostEffects)
        );
    }
}
