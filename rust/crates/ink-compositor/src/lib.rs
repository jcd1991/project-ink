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
    InvalidParameters,
}

/// Three channel lookup tables compiled once before raster tile evaluation.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RgbAdjustmentLut {
    red: [u8; 256],
    green: [u8; 256],
    blue: [u8; 256],
}

impl RgbAdjustmentLut {
    /// Compile piecewise-linear master and per-channel integer curves.
    pub fn from_curves(
        master: &[(u8, u8)],
        red: &[(u8, u8)],
        green: &[(u8, u8)],
        blue: &[(u8, u8)],
    ) -> Result<Self, AdjustmentError> {
        let master_lut = curve_lut(master)?;
        let apply_channel = |channel: &[(u8, u8)]| -> Result<[u8; 256], AdjustmentError> {
            let channel_lut = curve_lut(channel)?;
            let mut result = [0; 256];
            for value in 0..=255 {
                result[value] = channel_lut[usize::from(master_lut[value])];
            }
            Ok(result)
        };
        Ok(Self {
            red: apply_channel(red)?,
            green: apply_channel(green)?,
            blue: apply_channel(blue)?,
        })
    }

    /// Compile a Levels transform to a bounded 256-entry RGB table.
    pub fn from_levels(
        input_black: u8,
        input_white: u8,
        gamma_hundredths: u16,
        output_black: u8,
        output_white: u8,
    ) -> Result<Self, AdjustmentError> {
        if input_black >= input_white
            || !(10..=1000).contains(&gamma_hundredths)
            || output_black > output_white
        {
            return Err(AdjustmentError::InvalidParameters);
        }
        let mut table = [0; 256];
        let gamma = f64::from(gamma_hundredths) / 100.0;
        for input in 0_u8..=u8::MAX {
            let normalized = ((f64::from(input) - f64::from(input_black))
                / f64::from(input_white - input_black))
            .clamp(0.0, 1.0);
            let corrected = normalized.powf(1.0 / gamma);
            let mapped =
                f64::from(output_black) + corrected * f64::from(output_white - output_black);
            table[usize::from(input)] = rounded_f64_to_u8(mapped);
        }
        Ok(Self {
            red: table,
            green: table,
            blue: table,
        })
    }

    /// Apply to straight RGBA8, preserving the exact alpha byte.
    #[must_use]
    pub fn apply(&self, pixel: [u8; 4]) -> [u8; 4] {
        [
            self.red[usize::from(pixel[0])],
            self.green[usize::from(pixel[1])],
            self.blue[usize::from(pixel[2])],
            pixel[3],
        ]
    }
}

fn curve_lut(points: &[(u8, u8)]) -> Result<[u8; 256], AdjustmentError> {
    if !(2..=16).contains(&points.len())
        || points[0].0 != 0
        || points[points.len() - 1].0 != 255
        || points.windows(2).any(|pair| pair[0].0 >= pair[1].0)
    {
        return Err(AdjustmentError::InvalidParameters);
    }
    let mut table = [0; 256];
    let mut segment = 0;
    for value in 0_u8..=u8::MAX {
        while segment + 1 < points.len() - 1 && value > points[segment + 1].0 {
            segment += 1;
        }
        let (x0, y0) = points[segment];
        let (x1, y1) = points[segment + 1];
        let t = f32::from(value - x0) / f32::from(x1 - x0);
        table[usize::from(value)] =
            rounded_f32_to_u8(f32::from(y0) + (f32::from(y1) - f32::from(y0)) * t);
    }
    Ok(table)
}

// Inputs are clamped to the full 8-bit output range before conversion.
#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
fn rounded_f64_to_u8(value: f64) -> u8 {
    value.round().clamp(0.0, 255.0) as u8
}

// Inputs are clamped to the full 8-bit output range before conversion.
#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
fn rounded_f32_to_u8(value: f32) -> u8 {
    value.round().clamp(0.0, 255.0) as u8
}

/// Apply bounded HSL hue/saturation/lightness controls to straight RGBA8.
/// Identity settings return the input bytes exactly and alpha is unchanged.
#[allow(
    clippy::float_cmp,
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss
)]
pub fn hue_saturation(
    pixel: [u8; 4],
    hue_degrees: i16,
    saturation: i16,
    lightness: i16,
) -> Result<[u8; 4], AdjustmentError> {
    if !(-180..=180).contains(&hue_degrees)
        || !(-100..=100).contains(&saturation)
        || !(-100..=100).contains(&lightness)
    {
        return Err(AdjustmentError::InvalidParameters);
    }
    if hue_degrees == 0 && saturation == 0 && lightness == 0 {
        return Ok(pixel);
    }
    let red_value = f32::from(pixel[0]) / 255.0;
    let green_value = f32::from(pixel[1]) / 255.0;
    let blue_value = f32::from(pixel[2]) / 255.0;
    let max = red_value.max(green_value).max(blue_value);
    let min = red_value.min(green_value).min(blue_value);
    let delta = max - min;
    let mut hue = if delta == 0.0 {
        0.0
    // `max` is selected directly from these exact channel values.
    } else if max == red_value {
        60.0 * ((green_value - blue_value) / delta).rem_euclid(6.0)
    } else if max == green_value {
        60.0 * ((blue_value - red_value) / delta + 2.0)
    } else {
        60.0 * ((red_value - green_value) / delta + 4.0)
    };
    let mut sat = if delta == 0.0 {
        0.0
    } else {
        delta / (1.0 - (2.0 * f32::midpoint(max, min) - 1.0).abs())
    };
    let mut light = f32::midpoint(max, min);
    hue = (hue + f32::from(hue_degrees)).rem_euclid(360.0);
    sat = (sat * (1.0 + f32::from(saturation) / 100.0)).clamp(0.0, 1.0);
    light = (light + f32::from(lightness) / 100.0).clamp(0.0, 1.0);
    let chroma = (1.0 - (2.0 * light - 1.0).abs()) * sat;
    let intermediate = chroma * (1.0 - ((hue / 60.0).rem_euclid(2.0) - 1.0).abs());
    let (r1, g1, b1) = match hue {
        hue if hue < 60.0 => (chroma, intermediate, 0.0),
        hue if hue < 120.0 => (intermediate, chroma, 0.0),
        hue if hue < 180.0 => (0.0, chroma, intermediate),
        hue if hue < 240.0 => (0.0, intermediate, chroma),
        hue if hue < 300.0 => (intermediate, 0.0, chroma),
        _ => (chroma, 0.0, intermediate),
    };
    let offset = light - chroma * 0.5;
    Ok([
        rounded_f32_to_u8((r1 + offset) * 255.0),
        rounded_f32_to_u8((g1 + offset) * 255.0),
        rounded_f32_to_u8((b1 + offset) * 255.0),
        pixel[3],
    ])
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

    #[test]
    fn levels_and_curves_luts_preserve_identity_bytes_and_alpha() {
        let levels = RgbAdjustmentLut::from_levels(0, 255, 100, 0, 255).expect("identity levels");
        let identity = [(0, 0), (255, 255)];
        let curves = RgbAdjustmentLut::from_curves(&identity, &identity, &identity, &identity)
            .expect("identity curves");
        let pixel = [37, 129, 244, 91];
        assert_eq!(levels.apply(pixel), pixel);
        assert_eq!(curves.apply(pixel), pixel);

        let inverted = [(0, 255), (255, 0)];
        let curve = RgbAdjustmentLut::from_curves(&identity, &inverted, &identity, &identity)
            .expect("channel curve");
        assert_eq!(curve.apply(pixel), [218, 129, 244, 91]);
    }

    #[test]
    fn hue_saturation_identity_and_invalid_settings_are_exact() {
        let pixel = [40, 130, 220, 73];
        assert_eq!(hue_saturation(pixel, 0, 0, 0).expect("identity"), pixel);
        assert_eq!(hue_saturation(pixel, 30, 25, -10).unwrap()[3], pixel[3]);
        assert_eq!(
            hue_saturation(pixel, 181, 0, 0),
            Err(AdjustmentError::InvalidParameters)
        );
    }
}
