//! Stable document and layer types shared by the Project Ink engine.
#![allow(missing_docs)]
#![allow(
    clippy::missing_errors_doc,
    clippy::missing_panics_doc,
    clippy::must_use_candidate
)]

use serde::{Deserialize, Serialize};
use std::fmt;

/// A stable object identifier. UUID generation is kept at the engine boundary
/// so this core remains deterministic in tests and does not need unsafe code.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
pub struct Id(pub u128);

impl Id {
    /// Construct an ID from a deterministic integer (useful for fixtures).
    #[must_use]
    pub const fn from_u128(value: u128) -> Self {
        Self(value)
    }
}

impl fmt::Display for Id {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:032x}", self.0)
    }
}

/// Semantic aliases make APIs self-documenting while retaining compact IDs.
pub type DocumentId = Id;
pub type LayerId = Id;
pub type StrokeId = Id;
pub type BrushId = Id;

/// A pressure-aware vector stroke, retained as sampled input for compatibility.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct VectorStroke {
    pub points: Vec<VectorPoint>,
    pub closed: bool,
}

/// One normalized sample in a legacy vector stroke.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct VectorPoint {
    pub x: f32,
    pub y: f32,
    pub pressure: f32,
    pub tilt: f32,
}

/// Affine point-transform contract implemented by the tools crate's legacy
/// transform type to preserve the existing vector-stroke API without a model
/// dependency on the tool layer.
pub trait VectorAffineTransform: Copy {
    fn apply_vector_point(self, point: (f32, f32)) -> (f32, f32);
}

impl VectorStroke {
    #[must_use]
    pub fn simplify(&self, tolerance: f32) -> Self {
        if self.points.len() < 3 || !tolerance.is_finite() || tolerance <= 0.0 {
            return self.clone();
        }
        let mut keep = vec![false; self.points.len()];
        keep[0] = true;
        let last = self.points.len() - 1;
        keep[last] = true;
        let mut stack = vec![(0usize, last)];
        while let Some((from, to)) = stack.pop() {
            let a = self.points[from];
            let b = self.points[to];
            let dx = b.x - a.x;
            let dy = b.y - a.y;
            let length2 = dx * dx + dy * dy;
            let mut best = (from, 0.0f32);
            for (index, point) in self.points.iter().enumerate().take(to).skip(from + 1) {
                let t = if length2 <= f32::EPSILON {
                    0.0
                } else {
                    (((point.x - a.x) * dx + (point.y - a.y) * dy) / length2).clamp(0.0, 1.0)
                };
                let d = (point.x - (a.x + t * dx)).powi(2) + (point.y - (a.y + t * dy)).powi(2);
                if d > best.1 {
                    best = (index, d);
                }
            }
            if best.1 > tolerance * tolerance {
                keep[best.0] = true;
                if best.0 > from + 1 {
                    stack.push((from, best.0));
                }
                if to > best.0 + 1 {
                    stack.push((best.0, to));
                }
            }
        }
        Self {
            points: self
                .points
                .iter()
                .zip(keep)
                .filter_map(|(p, k)| k.then_some(*p))
                .collect(),
            closed: self.closed,
        }
    }

    #[must_use]
    pub fn width_at(&self, index: usize, min_width: f32, max_width: f32) -> f32 {
        let pressure = self
            .points
            .get(index)
            .map_or(0.0, |point| point.pressure.clamp(0.0, 1.0));
        min_width + (max_width - min_width) * pressure
    }

    pub fn transform<T: VectorAffineTransform>(&mut self, transform: T) {
        for point in &mut self.points {
            (point.x, point.y) = transform.apply_vector_point((point.x, point.y));
        }
    }

    #[must_use]
    pub fn connect(&self, other: &Self, tolerance: f32) -> Option<Self> {
        let first = self.points.last()?;
        let last = other.points.first()?;
        if (first.x - last.x).hypot(first.y - last.y) > tolerance.max(0.0) {
            return None;
        }
        let mut points = self.points.clone();
        points.extend_from_slice(&other.points[1..]);
        Some(Self {
            points,
            closed: self.closed || other.closed,
        })
    }

    /// Erase a circular segment, interpolating pressure and tilt at cut points.
    #[must_use]
    pub fn erase_segment(&self, center: (f32, f32), radius: f32) -> Vec<Self> {
        if !center.0.is_finite()
            || !center.1.is_finite()
            || !radius.is_finite()
            || self
                .points
                .iter()
                .any(|p| !p.x.is_finite() || !p.y.is_finite())
        {
            return vec![self.clone()];
        }
        if self.points.len() < 2 {
            return if self
                .points
                .first()
                .is_some_and(|p| (p.x - center.0).hypot(p.y - center.1) > radius.max(0.0))
            {
                vec![self.clone()]
            } else {
                Vec::new()
            };
        }
        let radius = radius.max(0.0);
        let mut pieces = Vec::new();
        let mut current = Vec::new();
        let mut erased = false;
        let count = if self.closed {
            self.points.len()
        } else {
            self.points.len() - 1
        };
        for i in 0..count {
            let a = self.points[i];
            let b = self.points[(i + 1) % self.points.len()];
            let cuts = segment_circle_cuts(a, b, center, radius);
            for cut in cuts.windows(2) {
                let mid = f32::midpoint(cut[0], cut[1]);
                let p = interpolate_vector_point(a, b, mid);
                if (p.x - center.0).hypot(p.y - center.1) <= radius {
                    if current.len() >= 2 {
                        pieces.push(Self {
                            points: std::mem::take(&mut current),
                            closed: false,
                        });
                    }
                    current.clear();
                    erased = true;
                    continue;
                }
                for t in cut {
                    let p = interpolate_vector_point(a, b, *t);
                    if current.last() != Some(&p) {
                        current.push(p);
                    }
                }
            }
        }
        if current.len() >= 2 {
            pieces.push(Self {
                points: current,
                closed: false,
            });
        }
        if erased { pieces } else { vec![self.clone()] }
    }
}

fn interpolate_vector_point(a: VectorPoint, b: VectorPoint, t: f32) -> VectorPoint {
    VectorPoint {
        x: a.x + (b.x - a.x) * t,
        y: a.y + (b.y - a.y) * t,
        pressure: a.pressure + (b.pressure - a.pressure) * t,
        tilt: a.tilt + (b.tilt - a.tilt) * t,
    }
}
fn segment_circle_cuts(
    start: VectorPoint,
    end: VectorPoint,
    center: (f32, f32),
    radius: f32,
) -> Vec<f32> {
    let (dx, dy, fx, fy) = (
        f64::from(end.x - start.x),
        f64::from(end.y - start.y),
        f64::from(start.x - center.0),
        f64::from(start.y - center.1),
    );
    let quadratic = dx * dx + dy * dy;
    let linear = 2.0 * (fx * dx + fy * dy);
    let constant = fx * fx + fy * fy - f64::from(radius) * f64::from(radius);
    let discriminant = linear * linear - 4.0 * quadratic * constant;
    let mut cuts = vec![0.0, 1.0];
    if quadratic > f64::EPSILON && discriminant > 0.0 {
        let root = discriminant.sqrt();
        for parameter in [
            (-linear - root) / (2.0 * quadratic),
            (-linear + root) / (2.0 * quadratic),
        ] {
            if parameter > 0.0 && parameter < 1.0 {
                // The quadratic root is strictly inside [0, 1], and the
                // destination representation is the same f32 parameter used
                // by the source stroke coordinates.
                #[allow(clippy::cast_possible_truncation)]
                let parameter = parameter as f32;
                cuts.push(parameter);
            }
        }
    }
    cuts.sort_by(f32::total_cmp);
    cuts.dedup_by(|a, b| (*a - *b).abs() <= f32::EPSILON);
    cuts
}

/// How an editable Bézier anchor joins adjacent segments.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum AnchorKind {
    Corner,
    Smooth,
}

/// Editable Bézier anchor with absolute incoming and outgoing handles.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct BezierAnchor {
    pub x: f64,
    pub y: f64,
    pub incoming: [f64; 2],
    pub outgoing: [f64; 2],
    pub kind: AnchorKind,
}

/// One path contour; closed contours participate in fill operations.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct BezierSubpath {
    pub anchors: Vec<BezierAnchor>,
    pub closed: bool,
}

/// Fill rule used when rasterizing compound paths.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum FillRule {
    NonZero,
    EvenOdd,
}

/// Solid stroke cap style.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum StrokeCap {
    Butt,
    Square,
    Round,
}

/// Solid stroke join style.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum StrokeJoin {
    Miter,
    Bevel,
    Round,
}

/// A bounded solid-color style for editable vector paths.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct VectorStyle {
    /// Straight-alpha RGBA8 fill; `None` means no fill.
    pub fill: Option<Rgba8>,
    /// Straight-alpha RGBA8 stroke; `None` means no stroke.
    pub stroke: Option<Rgba8>,
    pub stroke_width: f64,
    pub cap: StrokeCap,
    pub join: StrokeJoin,
    pub miter_limit: f64,
    pub fill_rule: FillRule,
}

/// Editable compound Bézier geometry in document-pixel coordinates.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct BezierPath {
    pub subpaths: Vec<BezierSubpath>,
    pub style: VectorStyle,
}

/// Original sampled stroke retained when converting it to an editable path.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct VectorSourceArchive {
    pub legacy: VectorStroke,
}

/// Tagged vector content stored on a vector layer.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum VectorObject {
    LegacyInk {
        stroke: VectorStroke,
    },
    BezierPath {
        path: BezierPath,
        source: Option<VectorSourceArchive>,
    },
}

/// Maximum supported anchors in one path.
pub const MAX_BEZIER_ANCHORS: usize = 1_024;
/// Maximum supported subpaths in one path.
pub const MAX_BEZIER_SUBPATHS: usize = 128;

/// Validate Bézier path structure and finite bounded geometry before storage.
pub fn validate_bezier_path(path: &BezierPath, document: DocumentSpec) -> Result<(), ModelError> {
    if path.subpaths.is_empty() || path.subpaths.len() > MAX_BEZIER_SUBPATHS {
        return Err(ModelError::InvalidVectorGeometry);
    }
    let max = f64::from(document.width_px.max(document.height_px)) * 4.0;
    let mut total = 0usize;
    for subpath in &path.subpaths {
        let min_anchors = if subpath.closed { 3 } else { 2 };
        if subpath.anchors.len() < min_anchors {
            return Err(ModelError::InvalidVectorGeometry);
        }
        total = total
            .checked_add(subpath.anchors.len())
            .ok_or(ModelError::InvalidVectorGeometry)?;
        for anchor in &subpath.anchors {
            let values = [
                anchor.x,
                anchor.y,
                anchor.incoming[0],
                anchor.incoming[1],
                anchor.outgoing[0],
                anchor.outgoing[1],
            ];
            if values.iter().any(|v| !v.is_finite() || v.abs() > max) {
                return Err(ModelError::InvalidVectorGeometry);
            }
        }
    }
    if total > MAX_BEZIER_ANCHORS
        || !path.style.stroke_width.is_finite()
        || !(0.0..=4096.0).contains(&path.style.stroke_width)
        || !path.style.miter_limit.is_finite()
        || !(1.0..=64.0).contains(&path.style.miter_limit)
        || (path.style.fill.is_none() && path.style.stroke.is_none())
    {
        return Err(ModelError::InvalidVectorGeometry);
    }
    Ok(())
}

/// Validate mixed vector objects before persistence or engine publication.
pub fn validate_vector_object(
    object: &VectorObject,
    document: DocumentSpec,
) -> Result<(), ModelError> {
    match object {
        VectorObject::LegacyInk { stroke } => validate_legacy_stroke(stroke, document),
        VectorObject::BezierPath { path, source } => {
            validate_bezier_path(path, document)?;
            if let Some(source) = source {
                validate_legacy_stroke(&source.legacy, document)?;
            }
            Ok(())
        }
    }
}

fn validate_legacy_stroke(stroke: &VectorStroke, document: DocumentSpec) -> Result<(), ModelError> {
    if stroke.points.is_empty() || stroke.points.len() > 8_192 {
        return Err(ModelError::InvalidVectorGeometry);
    }
    let max = f64::from(document.width_px.max(document.height_px)) * 4.0;
    if stroke.points.iter().any(|point| {
        !point.x.is_finite()
            || !point.y.is_finite()
            || !point.pressure.is_finite()
            || !point.tilt.is_finite()
            || f64::from(point.x).abs() > max
            || f64::from(point.y).abs() > max
            || !(0.0..=1.0).contains(&point.pressure)
    }) {
        return Err(ModelError::InvalidVectorGeometry);
    }
    Ok(())
}

/// v1 only supports 8-bit sRGB documents.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum ColorSpace {
    Srgb,
}

/// Premultiplied or straight RGBA color depending on the API boundary.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct Rgba8 {
    pub r: u8,
    pub g: u8,
    pub b: u8,
    pub a: u8,
}

impl Default for Rgba8 {
    fn default() -> Self {
        Self {
            r: 255,
            g: 255,
            b: 255,
            a: 0,
        }
    }
}

/// Immutable document creation parameters.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct DocumentSpec {
    pub width_px: u32,
    pub height_px: u32,
    pub dpi: f32,
    pub color_space: ColorSpace,
    pub background: Rgba8,
}

impl DocumentSpec {
    /// Validate dimensions and metadata before allocating any tiles.
    pub fn validate(self) -> Result<Self, ModelError> {
        if self.width_px == 0 || self.height_px == 0 {
            return Err(ModelError::InvalidDimensions);
        }
        if self.width_px > 32_768 || self.height_px > 32_768 {
            return Err(ModelError::DimensionsTooLarge);
        }
        if !self.dpi.is_finite() || self.dpi <= 0.0 {
            return Err(ModelError::InvalidDpi);
        }
        Ok(self)
    }
}

/// Layer content kind. Comic-only kinds are reserved for later phases.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum LayerKind {
    Raster,
    VectorInk,
    Group,
    Mask,
    Tone,
    PanelGroup,
    Adjustment,
}

/// Typed settings for a non-destructive layer adjustment. Each adjustment
/// node owns one filter; stacking is represented by ordinary layer order.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum LayerAdjustment {
    BrightnessContrast {
        brightness: i16,
        contrast: i16,
    },
    Levels {
        input_black: u8,
        input_white: u8,
        gamma_hundredths: u16,
        output_black: u8,
        output_white: u8,
    },
    Curves {
        master: AdjustmentCurve,
        red: AdjustmentCurve,
        green: AdjustmentCurve,
        blue: AdjustmentCurve,
    },
    HueSaturation {
        hue_degrees: i16,
        saturation: i16,
        lightness: i16,
    },
}

/// Integer point used by a serialized adjustment curve.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct AdjustmentCurvePoint {
    pub x: u8,
    pub y: u8,
}

/// Fixed-capacity curve storage; unused entries must remain zeroed.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct AdjustmentCurve {
    pub points: [AdjustmentCurvePoint; 16],
    pub len: u8,
}

impl AdjustmentCurve {
    /// Identity curve with canonical zeroed unused slots.
    pub const fn identity() -> Self {
        let mut points = [AdjustmentCurvePoint { x: 0, y: 0 }; 16];
        points[1] = AdjustmentCurvePoint { x: 255, y: 255 };
        Self { points, len: 2 }
    }

    /// Check point count, endpoints, ordering, and unused-slot canonical form.
    pub fn validate(self) -> Result<Self, ModelError> {
        let len = usize::from(self.len);
        if !(2..=16).contains(&len)
            || self.points[0].x != 0
            || self.points[len - 1].x != 255
            || self.points[..len]
                .windows(2)
                .any(|pair| pair[0].x >= pair[1].x)
            || self.points[len..]
                .iter()
                .any(|point| *point != AdjustmentCurvePoint::default())
        {
            return Err(ModelError::InvalidAdjustment);
        }
        Ok(self)
    }
}

impl LayerAdjustment {
    /// Reject untrusted settings outside the UI's bounded percentage range.
    pub fn validate(self) -> Result<Self, ModelError> {
        match self {
            Self::BrightnessContrast {
                brightness,
                contrast,
            } if (-100..=100).contains(&brightness) && (-100..=100).contains(&contrast) => Ok(self),
            Self::Levels {
                input_black,
                input_white,
                gamma_hundredths,
                output_black,
                output_white,
            } if input_black < input_white
                && (10..=1000).contains(&gamma_hundredths)
                && output_black <= output_white =>
            {
                Ok(self)
            }
            Self::Curves {
                master,
                red,
                green,
                blue,
            } => {
                master.validate()?;
                red.validate()?;
                green.validate()?;
                blue.validate()?;
                Ok(self)
            }
            Self::HueSaturation {
                hue_degrees,
                saturation,
                lightness,
            } if (-180..=180).contains(&hue_degrees)
                && (-100..=100).contains(&saturation)
                && (-100..=100).contains(&lightness) =>
            {
                Ok(self)
            }
            _ => Err(ModelError::InvalidAdjustment),
        }
    }
}

/// Layer compositing modes shared by the raster compositor and persistence.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub enum LayerBlendMode {
    #[default]
    Normal,
    Multiply,
    Screen,
    Overlay,
    Darken,
    Lighten,
    Add,
    Subtract,
    ColorBurn,
    LinearBurn,
    ColorDodge,
    SoftLight,
    HardLight,
    Difference,
    Exclusion,
    Divide,
}

/// Controls whether a group composites its children as one surface or lets
/// them interact directly with the layers beneath the group.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub enum LayerGroupMode {
    /// Composite children into a transparent intermediate before applying
    /// the group's opacity and blend mode.
    #[default]
    Isolated,
    /// Composite children directly against the backdrop beneath the group.
    PassThrough,
}

/// A minimal persistent layer node.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[allow(clippy::struct_excessive_bools)]
pub struct Layer {
    pub id: LayerId,
    pub parent: Option<LayerId>,
    /// Stable sibling order. Lower values are composited first (behind later
    /// siblings) and are never used as object identity. Older documents omit
    /// this field; storage reconstructs their order from the persisted row
    /// sequence before exposing the layer tree.
    #[serde(default)]
    pub order: u32,
    pub kind: LayerKind,
    /// Stable owner identity for an attached mask. `None` means the mask is
    /// unattached; unlike legacy mask adjacency this link survives reordering.
    #[serde(default)]
    pub mask_owner: Option<LayerId>,
    /// Whether an attached mask currently affects its owner.
    #[serde(default = "default_mask_enabled")]
    pub mask_enabled: bool,
    /// Normal masks store hidden coverage sparsely (zero means reveal). Legacy
    /// geometry masks store reveal coverage directly and set this flag.
    #[serde(default)]
    pub mask_stencil: bool,
    /// Invert the effective coverage without rewriting mask pixels.
    #[serde(default)]
    pub mask_inverted: bool,
    pub name: String,
    pub opacity: u16,
    pub visible: bool,
    #[serde(default)]
    pub blend_mode: LayerBlendMode,
    /// Group compositing behavior. Legacy packages load as pass-through to
    /// preserve their historical flattened appearance.
    #[serde(default = "legacy_group_mode")]
    pub group_mode: LayerGroupMode,
    #[serde(default)]
    pub alpha_lock: bool,
    /// Full layer lock. Group locks are inherited by their descendants.
    #[serde(default)]
    pub locked: bool,
    #[serde(default)]
    pub clipping: bool,
    #[serde(default)]
    pub reference: bool,
    #[serde(default)]
    pub label: Option<Rgba8>,
    /// Optional typed non-destructive filter settings. Older projects omit
    /// this field and load as an unconfigured/neutral layer.
    #[serde(default)]
    pub adjustment: Option<LayerAdjustment>,
}

impl Layer {
    #[must_use]
    pub fn new(id: LayerId, kind: LayerKind, name: impl Into<String>) -> Self {
        Self {
            id,
            parent: None,
            order: 0,
            kind,
            mask_owner: None,
            mask_enabled: true,
            mask_stencil: false,
            mask_inverted: false,
            name: name.into(),
            opacity: u16::MAX,
            visible: true,
            blend_mode: LayerBlendMode::Normal,
            group_mode: if matches!(kind, LayerKind::Group | LayerKind::PanelGroup) {
                LayerGroupMode::Isolated
            } else {
                LayerGroupMode::PassThrough
            },
            alpha_lock: false,
            locked: false,
            clipping: false,
            reference: false,
            label: None,
            adjustment: None,
        }
    }
}

fn default_mask_enabled() -> bool {
    true
}

fn legacy_group_mode() -> LayerGroupMode {
    LayerGroupMode::PassThrough
}

/// Errors that can be returned while constructing the model.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ModelError {
    InvalidDimensions,
    DimensionsTooLarge,
    InvalidDpi,
    InvalidAdjustment,
    InvalidVectorGeometry,
}

impl fmt::Display for ModelError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let message = match self {
            Self::InvalidDimensions => "document dimensions must be non-zero",
            Self::DimensionsTooLarge => "document dimensions exceed the v1 limit",
            Self::InvalidDpi => "dpi must be finite and positive",
            Self::InvalidAdjustment => "adjustment parameters are outside limits",
            Self::InvalidVectorGeometry => "vector geometry is outside supported limits",
        };
        f.write_str(message)
    }
}

impl std::error::Error for ModelError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_document_spec() {
        let spec = DocumentSpec {
            width_px: 4096,
            height_px: 4096,
            dpi: 300.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        assert!(spec.validate().is_ok());
        assert!(
            DocumentSpec {
                width_px: 0,
                ..spec
            }
            .validate()
            .is_err()
        );
    }

    #[test]
    fn bezier_validation_rejects_non_finite_and_over_budget_geometry() {
        let document = DocumentSpec {
            width_px: 100,
            height_px: 100,
            dpi: 300.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let anchor = BezierAnchor {
            x: 1.0,
            y: 2.0,
            incoming: [1.0, 2.0],
            outgoing: [3.0, 4.0],
            kind: AnchorKind::Smooth,
        };
        let path = BezierPath {
            subpaths: vec![BezierSubpath {
                anchors: vec![anchor, anchor],
                closed: false,
            }],
            style: VectorStyle {
                fill: None,
                stroke: Some(Rgba8 {
                    r: 0,
                    g: 0,
                    b: 0,
                    a: 255,
                }),
                stroke_width: 1.0,
                cap: StrokeCap::Round,
                join: StrokeJoin::Round,
                miter_limit: 4.0,
                fill_rule: FillRule::NonZero,
            },
        };
        assert!(validate_bezier_path(&path, document).is_ok());
        let mut invalid = path.clone();
        invalid.subpaths[0].anchors[0].outgoing[0] = f64::NAN;
        assert_eq!(
            validate_bezier_path(&invalid, document),
            Err(ModelError::InvalidVectorGeometry)
        );
    }

    #[test]
    fn legacy_coordinate_bounds_do_not_overflow_for_large_documents() {
        let document = DocumentSpec {
            width_px: 100_000,
            height_px: 100_000,
            dpi: 300.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let object = VectorObject::LegacyInk {
            stroke: VectorStroke {
                points: vec![VectorPoint {
                    x: 1_000_000_000.0,
                    y: 0.0,
                    pressure: 0.5,
                    tilt: 0.0,
                }],
                closed: false,
            },
        };
        assert_eq!(
            validate_vector_object(&object, document),
            Err(ModelError::InvalidVectorGeometry)
        );
    }

    #[test]
    fn adjustment_values_are_bounded_and_curve_storage_is_canonical() {
        let identity = AdjustmentCurve::identity();
        assert!(identity.validate().is_ok());
        assert!(
            LayerAdjustment::Levels {
                input_black: 0,
                input_white: 255,
                gamma_hundredths: 100,
                output_black: 0,
                output_white: 255,
            }
            .validate()
            .is_ok()
        );
        assert!(
            LayerAdjustment::HueSaturation {
                hue_degrees: -180,
                saturation: 100,
                lightness: -100,
            }
            .validate()
            .is_ok()
        );
        assert!(
            LayerAdjustment::Levels {
                input_black: 50,
                input_white: 50,
                gamma_hundredths: 100,
                output_black: 0,
                output_white: 255,
            }
            .validate()
            .is_err()
        );

        let mut malformed = identity;
        malformed.points[15].x = 1;
        assert!(malformed.validate().is_err());
    }
}
