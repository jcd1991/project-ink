//! Deterministic layer and paint compositing helpers.
#![allow(missing_docs)]
#![allow(
    clippy::missing_errors_doc,
    clippy::missing_panics_doc,
    clippy::must_use_candidate
)]

/// Common illustration blend modes supported by the CPU compositor.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BlendMode {
    Normal,
    Multiply,
    Screen,
    Overlay,
    Darken,
    Lighten,
    Add,
    Subtract,
    ColorDodge,
    ColorBurn,
    LinearBurn,
    SoftLight,
    HardLight,
    Difference,
    Exclusion,
    Divide,
}

/// Bounded non-destructive color correction parameters for the first
/// adjustment-stack filter. Values are percentages in `-100..=100`; keeping
/// the parameter type in the compositor lets the document/bridge layers share
/// one validation contract without duplicating pixel math.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct BrightnessContrast {
    pub brightness: i16,
    pub contrast: i16,
}

impl BrightnessContrast {
    /// Validate UI- or file-provided adjustment values before evaluation.
    pub fn validate(self) -> Result<Self, AdjustmentError> {
        if !(-100..=100).contains(&self.brightness) {
            return Err(AdjustmentError::BrightnessOutOfRange);
        }
        if !(-100..=100).contains(&self.contrast) {
            return Err(AdjustmentError::ContrastOutOfRange);
        }
        Ok(self)
    }

    /// Apply this correction to straight RGBA8 sRGB, preserving alpha.
    /// Integer fixed-point math makes evaluation deterministic across targets.
    pub fn apply(self, pixel: [u8; 4]) -> Result<[u8; 4], AdjustmentError> {
        let adjustment = self.validate()?;
        let contrast_permille = 1000 + i32::from(adjustment.contrast) * 10;
        let brightness_delta = i32::from(adjustment.brightness) * 255 / 100;
        let mut output = pixel;
        for channel in &mut output[..3] {
            let centered = i32::from(*channel) - 128;
            let scaled = centered * contrast_permille;
            let rounded = if scaled < 0 {
                (scaled - 500) / 1000
            } else {
                (scaled + 500) / 1000
            };
            let adjusted = rounded + 128 + brightness_delta;
            *channel = u8::try_from(adjusted.clamp(0, 255)).unwrap_or_default();
        }
        Ok(output)
    }
}

/// Invalid adjustment parameters are rejected before any document mutation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AdjustmentError {
    BrightnessOutOfRange,
    ContrastOutOfRange,
}

/// Composite straight RGBA8 pixels with deterministic integer arithmetic.
///
/// The public raster tile representation remains premultiplied BGRA; this
/// helper deliberately takes straight RGBA so importers, previews, and layer
/// operations can share one tested blend contract.
#[must_use]
pub fn blend_rgba8(
    destination: [u8; 4],
    source: [u8; 4],
    opacity: u16,
    mode: BlendMode,
) -> [u8; 4] {
    let source_alpha = (u32::from(source[3]) * u32::from(opacity) + 32_767) / 65_535;
    if source_alpha == 0 {
        return destination;
    }
    let destination_alpha = u32::from(destination[3]);
    let out_alpha = source_alpha + ((destination_alpha * (255 - source_alpha) + 127) / 255);
    let mut result = destination;
    for channel in 0..3 {
        let base = u32::from(destination[channel]);
        let blend = channel_blend(base, u32::from(source[channel]), mode);
        // Source-over with a blend function has three regions: source-only,
        // source/backdrop overlap (where the blend function applies), and
        // backdrop-only. Omitting source-only makes non-Normal modes turn
        // black over transparent pixels (for example red Multiply on an
        // empty isolated group).
        let source_and_overlap =
            (u32::from(source[channel]) * source_alpha * (255 - destination_alpha)
                + blend * source_alpha * destination_alpha)
                / 255;
        let destination_only = base * destination_alpha * (255 - source_alpha) / 255;
        result[channel] = ((source_and_overlap + destination_only + out_alpha / 2)
            / out_alpha.max(1))
        .min(255) as u8;
    }
    result[3] = out_alpha.min(255) as u8;
    result
}

fn channel_blend(destination: u32, source: u32, mode: BlendMode) -> u32 {
    match mode {
        BlendMode::Normal => source,
        BlendMode::Multiply => destination * source / 255,
        BlendMode::Screen => 255 - (255 - destination) * (255 - source) / 255,
        BlendMode::Overlay => {
            if destination < 128 {
                2 * destination * source / 255
            } else {
                255 - 2 * (255 - destination) * (255 - source) / 255
            }
        }
        BlendMode::Darken => destination.min(source),
        BlendMode::Lighten => destination.max(source),
        BlendMode::Add => destination.saturating_add(source).min(255),
        BlendMode::Subtract => destination.saturating_sub(source),
        BlendMode::ColorDodge => {
            if source == 255 {
                255
            } else {
                (destination * 255 / (255 - source)).min(255)
            }
        }
        BlendMode::ColorBurn => 255 - ((255 - destination) * 255 / source.max(1)).min(255),
        BlendMode::LinearBurn => destination.saturating_add(source).saturating_sub(255),
        BlendMode::SoftLight => {
            let factor = (2 * source).min(255);
            ((destination * (255 - factor) + ((2 * destination * source) / 255) * factor) / 255)
                .min(255)
        }
        BlendMode::HardLight => {
            if source < 128 {
                2 * destination * source / 255
            } else {
                255 - 2 * (255 - destination) * (255 - source) / 255
            }
        }
        BlendMode::Difference => destination.abs_diff(source),
        BlendMode::Exclusion => destination
            .saturating_add(source)
            .saturating_sub((2 * destination * source) / 255),
        BlendMode::Divide => destination
            .saturating_mul(255)
            .checked_div(source)
            .unwrap_or(255)
            .min(255),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blend_modes_are_bounded_and_deterministic() {
        for mode in [
            BlendMode::Normal,
            BlendMode::Multiply,
            BlendMode::Screen,
            BlendMode::Overlay,
            BlendMode::Darken,
            BlendMode::Lighten,
            BlendMode::Add,
            BlendMode::Subtract,
            BlendMode::ColorDodge,
            BlendMode::ColorBurn,
            BlendMode::LinearBurn,
            BlendMode::SoftLight,
            BlendMode::HardLight,
            BlendMode::Difference,
            BlendMode::Exclusion,
            BlendMode::Divide,
        ] {
            let first = blend_rgba8([20, 100, 220, 255], [220, 80, 40, 200], u16::MAX, mode);
            let second = blend_rgba8([20, 100, 220, 255], [220, 80, 40, 200], u16::MAX, mode);
            assert_eq!(first, second);
            assert!(first[3] > 0);
        }
    }

    #[test]
    fn non_normal_blend_preserves_source_color_over_transparency() {
        assert_eq!(
            blend_rgba8(
                [0, 0, 0, 0],
                [255, 0, 0, 255],
                u16::MAX,
                BlendMode::Multiply,
            ),
            [255, 0, 0, 255]
        );
        assert_eq!(
            blend_rgba8(
                [0, 255, 0, 255],
                [255, 0, 0, 255],
                u16::MAX,
                BlendMode::Multiply,
            ),
            [0, 0, 0, 255]
        );
    }

    #[test]
    fn transparent_source_is_a_no_op() {
        assert_eq!(
            blend_rgba8(
                [1, 2, 3, 4],
                [200, 200, 200, 0],
                u16::MAX,
                BlendMode::Screen
            ),
            [1, 2, 3, 4]
        );
    }

    #[test]
    fn brightness_contrast_is_identity_at_neutral_and_preserves_alpha() {
        let pixel = [24, 128, 240, 93];
        assert_eq!(
            BrightnessContrast::default()
                .apply(pixel)
                .expect("neutral adjustment"),
            pixel
        );
        assert_eq!(
            BrightnessContrast {
                brightness: 20,
                contrast: 0,
            }
            .apply(pixel)
            .expect("brightness"),
            [75, 179, 255, 93]
        );
    }

    #[test]
    fn brightness_contrast_is_deterministic_bounded_and_validated() {
        let adjustment = BrightnessContrast {
            brightness: -35,
            contrast: 70,
        };
        let first = adjustment
            .apply([0, 127, 255, 255])
            .expect("valid adjustment");
        let second = adjustment
            .apply([0, 127, 255, 255])
            .expect("valid adjustment");
        assert_eq!(first, second);
        assert_eq!(first[3], 255);
        assert_eq!(first[0], 0);
        assert_eq!(first[2], 255);
        assert_eq!(
            BrightnessContrast {
                brightness: 101,
                contrast: 0,
            }
            .apply([1, 2, 3, 4]),
            Err(AdjustmentError::BrightnessOutOfRange)
        );
        assert_eq!(
            BrightnessContrast {
                brightness: 0,
                contrast: -101,
            }
            .validate(),
            Err(AdjustmentError::ContrastOutOfRange)
        );
    }
}
