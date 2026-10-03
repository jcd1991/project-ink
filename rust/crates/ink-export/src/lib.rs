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
use std::fs::File;
use std::io::{Cursor, Write};
use std::path::Path;
use zip::{CompressionMethod, ZipWriter, write::SimpleFileOptions};

/// Maximum projected memory for importing one flattened PSD. The projection
/// includes the encoded source, decoded RGBA pixels, and the initial raster
/// layer tiles that are built from those pixels.
pub const MAX_PSD_IMPORT_WORKING_SET_BYTES: u64 = 768 * 1024 * 1024;
const MAX_PSD_PIXELS: u64 = 64 * 1024 * 1024;

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
            Self::UnsafePath => f.write_str("PNG destination must not be a symlink"),
            Self::InvalidPsd(message) => write!(f, "invalid PSD: {message}"),
            Self::UnsupportedPsd(message) => write!(f, "unsupported PSD: {message}"),
        }
    }
}

/// Decode the conservative flattened PSD subset emitted by [`encode_psd`].
/// Only version 1, RGB, 8-bit, uncompressed composite images with three or
/// four channels are accepted. Layer records and compressed/RLE data are
/// rejected rather than guessed, keeping imports deterministic and bounded.
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
    if compression != 0 {
        return Err(ExportError::UnsupportedPsd(
            "RLE/compressed images are not imported",
        ));
    }
    let pixel_count = usize::try_from(width)
        .ok()
        .and_then(|w| usize::try_from(height).ok().and_then(|h| w.checked_mul(h)))
        .ok_or(ExportError::InvalidPixelLength)?;
    let channel_bytes = pixel_count
        .checked_mul(usize::from(channels))
        .ok_or(ExportError::InvalidPixelLength)?;
    let end = cursor
        .checked_add(channel_bytes)
        .ok_or(ExportError::InvalidPsd("pixel length overflow"))?;
    let planar = bytes
        .get(cursor..end)
        .ok_or(ExportError::InvalidPsd("truncated pixel data"))?;
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
    Ok((width, height, rgba))
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
/// illustration applications. Layer structure remains intentionally limited.
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
        bytes.extend(pixels.iter().map(|pixel| pixel[channel]));
    }
    debug_assert_eq!(bytes.len(), 40 + pixel_count * 4);
    Ok(bytes)
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

    #[test]
    fn encodes_png_signature_and_rejects_wrong_size() {
        let pixels = [255, 0, 0, 255];
        let png = encode_png(1, 1, &pixels).expect("png");
        assert_eq!(&png[..8], b"\x89PNG\r\n\x1a\n");
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
