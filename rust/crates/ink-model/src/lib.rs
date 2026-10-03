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
    BrightnessContrast { brightness: i16, contrast: i16 },
}

impl LayerAdjustment {
    /// Reject untrusted settings outside the UI's bounded percentage range.
    pub fn validate(self) -> Result<Self, ModelError> {
        match self {
            Self::BrightnessContrast {
                brightness,
                contrast,
            } if (-100..=100).contains(&brightness) && (-100..=100).contains(&contrast) => Ok(self),
            Self::BrightnessContrast { .. } => Err(ModelError::InvalidAdjustment),
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
}

impl fmt::Display for ModelError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let message = match self {
            Self::InvalidDimensions => "document dimensions must be non-zero",
            Self::DimensionsTooLarge => "document dimensions exceed the v1 limit",
            Self::InvalidDpi => "dpi must be finite and positive",
            Self::InvalidAdjustment => "adjustment parameters are outside limits",
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
}
