//! Native `.inkbrush` import/export and bounded external-format inspection.

use super::{
    BrushPresetV2, BrushValidationError, CPU_BRUSH_V2, CombineOp, EngineSemantics,
    ParameterBinding, ParameterId, PathStabilizer, PostEffect, ResponseCurve, SensorId,
    TipBehavior,
};
use ciborium::{de::from_reader, ser::into_writer};
use ink_model::BrushId;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::fmt;
use std::fmt::Write as _;
use std::fs::File;
use std::io::{Cursor, Read, Seek, Write};
use std::path::Path;
use zip::{CompressionMethod, ZipArchive, ZipWriter, result::ZipError, write::SimpleFileOptions};

const MAX_ARCHIVE_BYTES: u64 = 256 * 1024 * 1024;
const MAX_EXPANDED_BYTES: u64 = 512 * 1024 * 1024;
const MAX_MANIFEST_BYTES: usize = 1024 * 1024;
const MAX_PRESET_BYTES: usize = 1024 * 1024;
const MAX_ENTRIES: usize = 256;
const MAX_INSPECTION_BYTES: usize = 64 * 1024;
const MAX_COMPRESSION_RATIO: u64 = 100;
const MAX_RESOURCE_BYTES: usize = 96 * 1024 * 1024;
const MAX_RESOURCE_LIBRARY_BYTES: u64 = 256 * 1024 * 1024;
// Multi-brush reports own copies of referenced resources. Keep their total
// below one library's bound so shared images cannot amplify memory per brush.
const MAX_PACK_REPORT_RESOURCE_BYTES: u64 = 256 * 1024 * 1024;
const MAX_RESOURCE_DIMENSION: u32 = 16_384;
const MAX_ABR_IMPORT_PRESETS: usize = 256;
const MAX_ABR_REPORT_OMISSIONS: usize = 128;

/// External brush formats known to the inspector.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum ExternalBrushFormat {
    InkBrush,
    InkBrushPack,
    KritaKpp,
    KritaBundle,
    MyPaintMyb,
    PhotoshopAbr,
    SutArchive,
    TosArchive,
    BrushArchive,
    BrushSetArchive,
    BrushLibraryArchive,
    Image,
    Unknown,
}

/// Honest conversion fidelity shown to the user before installation.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum FidelityTier {
    Lossless,
    High,
    Approximate,
    GuidedRecreation,
    Rejected,
}

/// Version of the clean-room importer used for compatibility reports.
pub const BRUSH_IMPORTER_VERSION: &str = "project-ink-import-v1";

/// Bounded display-only value used in import difference reports.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum DisplayValue {
    Number(f32),
    Text(String),
    Bool(bool),
    None,
}

/// One source-to-Project-Ink setting mapping.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SettingMapping {
    pub source_path: String,
    pub source_value: DisplayValue,
    pub target_path: String,
    pub target_value: DisplayValue,
    pub quality: MappingQuality,
    pub note: Option<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum MappingQuality {
    Exact,
    Normalized,
    Approximated,
    Defaulted,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct OmittedSetting {
    pub source_path: String,
    pub reason: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ImportedResource {
    pub name: String,
    pub kind: String,
    pub sha256: [u8; 32],
    pub bytes: u64,
    /// Decoded straight-alpha RGBA8 payload staged for the engine. This is
    /// deliberately not exposed through the bridge report DTO.
    #[serde(skip)]
    pub data: Vec<u8>,
    pub width: u32,
    pub height: u32,
}

/// Optional bounded preview returned by an importer before installation.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct BrushPreview {
    pub width: u16,
    pub height: u16,
    pub rgba8: Vec<u8>,
}

/// Human-readable warning attached to an import report.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ImportWarning {
    pub code: String,
    pub message: String,
}

/// A bounded import result. A report with no preset is never installable.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct BrushImportReport {
    pub source_format: ExternalBrushFormat,
    pub source_sha256: [u8; 32],
    pub importer_version: String,
    pub fidelity: FidelityTier,
    pub preset: Option<BrushPresetV2>,
    #[serde(default)]
    pub mappings: Vec<SettingMapping>,
    #[serde(default)]
    pub omitted: Vec<OmittedSetting>,
    #[serde(default)]
    pub resources: Vec<ImportedResource>,
    #[serde(default)]
    pub preview: Option<BrushPreview>,
    pub warnings: Vec<ImportWarning>,
}

/// Read-only inspection data shown before a conversion is committed.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct BrushImportInspection {
    pub source_format: ExternalBrushFormat,
    pub source_sha256: [u8; 32],
    pub bytes: u64,
    pub fidelity_hint: FidelityTier,
    pub importer_version: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct NativeManifest {
    format_version: u32,
    brush_id: u128,
    name: String,
    preset_sha256: String,
    #[serde(default)]
    resources: Vec<NativeResourceManifest>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct NativeResourceManifest {
    hash: String,
    kind: String,
    width: u32,
    height: u32,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct NativePackManifest {
    format_version: u32,
    brushes: Vec<NativePackBrushManifest>,
    #[serde(default)]
    resources: Vec<NativeResourceManifest>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct NativePackBrushManifest {
    index: u32,
    brush_id: u128,
    name: String,
    preset_sha256: String,
}

/// Errors returned by the native pack boundary.
#[derive(Debug)]
pub enum BrushPackError {
    Io(std::io::Error),
    Zip(ZipError),
    Json(serde_json::Error),
    Cbor(ciborium::de::Error<std::io::Error>),
    CborEncode(ciborium::ser::Error<std::io::Error>),
    Sqlite(rusqlite::Error),
    Validation(BrushValidationError),
    UnsafeArchive(&'static str),
    InvalidManifest(String),
    HashMismatch,
}

impl fmt::Display for BrushPackError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => error.fmt(f),
            Self::Zip(error) => error.fmt(f),
            Self::Json(error) => error.fmt(f),
            Self::Cbor(error) => error.fmt(f),
            Self::CborEncode(error) => error.fmt(f),
            Self::Sqlite(error) => error.fmt(f),
            Self::Validation(error) => error.fmt(f),
            Self::UnsafeArchive(message) => write!(f, "unsafe brush archive: {message}"),
            Self::InvalidManifest(message) => write!(f, "invalid brush manifest: {message}"),
            Self::HashMismatch => f.write_str("brush preset hash does not match its manifest"),
        }
    }
}

impl std::error::Error for BrushPackError {}
impl From<std::io::Error> for BrushPackError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}
impl From<ZipError> for BrushPackError {
    fn from(error: ZipError) -> Self {
        Self::Zip(error)
    }
}
impl From<serde_json::Error> for BrushPackError {
    fn from(error: serde_json::Error) -> Self {
        Self::Json(error)
    }
}
impl From<rusqlite::Error> for BrushPackError {
    fn from(error: rusqlite::Error) -> Self {
        Self::Sqlite(error)
    }
}
impl From<BrushValidationError> for BrushPackError {
    fn from(error: BrushValidationError) -> Self {
        Self::Validation(error)
    }
}

/// Export one native preset as a bounded ZIP archive.
pub fn export_inkbrush(path: &Path, preset: &BrushPresetV2) -> Result<(), BrushPackError> {
    export_inkbrush_with_resources(path, preset, &[])
}

/// Export a native preset and its referenced decoded RGBA resources.
pub fn export_inkbrush_with_resources(
    path: &Path,
    preset: &BrushPresetV2,
    resources: &[ImportedResource],
) -> Result<(), BrushPackError> {
    preset.validate()?;
    if let Ok(metadata) = std::fs::symlink_metadata(path)
        && (metadata.file_type().is_symlink() || !metadata.is_file())
    {
        return Err(BrushPackError::UnsafeArchive(
            "destination is not a regular file",
        ));
    }
    let mut preset_bytes = Vec::new();
    into_writer(preset, &mut preset_bytes).map_err(BrushPackError::CborEncode)?;
    if preset_bytes.len() > MAX_PRESET_BYTES {
        return Err(BrushPackError::UnsafeArchive("preset is too large"));
    }
    let preview = preview_for(preset)?;
    let preview_webp = webp::Encoder::from_rgba(
        &preview.rgba8,
        u32::from(preview.width),
        u32::from(preview.height),
    )
    .encode(90.0);
    if preview_webp.len() > MAX_PRESET_BYTES {
        return Err(BrushPackError::UnsafeArchive("preview is too large"));
    }
    let hash = Sha256::digest(&preset_bytes);
    let mut resource_manifest = Vec::new();
    for resource in resources {
        validate_resource(resource)?;
        if !preset_references_resource(preset, resource.sha256) {
            return Err(BrushPackError::InvalidManifest(
                "native pack contains an unreferenced resource".into(),
            ));
        }
        resource_manifest.push(NativeResourceManifest {
            hash: hex(&resource.sha256),
            kind: resource.kind.clone(),
            width: resource.width,
            height: resource.height,
        });
    }
    resource_manifest.sort_by(|left, right| left.hash.cmp(&right.hash));
    let manifest = NativeManifest {
        format_version: 1,
        brush_id: preset.id.0,
        name: preset.metadata.name.clone(),
        preset_sha256: hex(&hash),
        resources: resource_manifest,
    };
    let file = File::create(path)?;
    let mut writer = ZipWriter::new(file);
    let options = SimpleFileOptions::default().compression_method(CompressionMethod::Deflated);
    writer.start_file("manifest.json", options)?;
    writer.write_all(&serde_json::to_vec_pretty(&manifest)?)?;
    writer.start_file("preset.cbor", options)?;
    writer.write_all(&preset_bytes)?;
    writer.start_file("preview.webp", options)?;
    writer.write_all(&preview_webp)?;
    for resource in resources {
        let path = format!("resources/{}.rgba", hex(&resource.sha256));
        writer.start_file(path, options)?;
        writer.write_all(&resource.data)?;
    }
    writer.finish()?.sync_all()?;
    Ok(())
}

/// Export a bounded multi-brush native pack. Resources are content-addressed
/// once at pack scope and may be shared by any member preset.
pub fn export_inkbrushpack(
    path: &Path,
    presets: &[BrushPresetV2],
    resources: &[ImportedResource],
) -> Result<(), BrushPackError> {
    if presets.is_empty() || presets.len() > MAX_ENTRIES {
        return Err(BrushPackError::UnsafeArchive(
            "brush pack member count is outside limits",
        ));
    }
    if let Ok(metadata) = std::fs::symlink_metadata(path)
        && (metadata.file_type().is_symlink() || !metadata.is_file())
    {
        return Err(BrushPackError::UnsafeArchive(
            "destination is not a regular file",
        ));
    }
    let mut members = Vec::with_capacity(presets.len());
    let mut serialized = Vec::with_capacity(presets.len());
    for (index, preset) in presets.iter().enumerate() {
        preset.validate()?;
        let mut bytes = Vec::new();
        into_writer(preset, &mut bytes).map_err(BrushPackError::CborEncode)?;
        if bytes.len() > MAX_PRESET_BYTES {
            return Err(BrushPackError::UnsafeArchive("preset is too large"));
        }
        members.push(NativePackBrushManifest {
            index: u32::try_from(index).unwrap_or(u32::MAX),
            brush_id: preset.id.0,
            name: preset.metadata.name.clone(),
            preset_sha256: hex(&Sha256::digest(&bytes)),
        });
        serialized.push(bytes);
    }
    let mut resource_manifest = Vec::new();
    let mut seen_resources = HashSet::with_capacity(resources.len());
    for resource in resources {
        validate_resource(resource)?;
        if !presets
            .iter()
            .any(|preset| preset_references_resource(preset, resource.sha256))
        {
            return Err(BrushPackError::InvalidManifest(
                "native pack contains an unreferenced resource".into(),
            ));
        }
        if !seen_resources.insert(resource.sha256) {
            return Err(BrushPackError::InvalidManifest(
                "native pack contains duplicate resources".into(),
            ));
        }
        resource_manifest.push(NativeResourceManifest {
            hash: hex(&resource.sha256),
            kind: resource.kind.clone(),
            width: resource.width,
            height: resource.height,
        });
    }
    resource_manifest.sort_by(|left, right| left.hash.cmp(&right.hash));
    let manifest = NativePackManifest {
        format_version: 1,
        brushes: members,
        resources: resource_manifest,
    };
    let file = File::create(path)?;
    let mut writer = ZipWriter::new(file);
    let options = SimpleFileOptions::default().compression_method(CompressionMethod::Deflated);
    writer.start_file("manifest.json", options)?;
    writer.write_all(&serde_json::to_vec_pretty(&manifest)?)?;
    for (index, (preset, bytes)) in presets.iter().zip(serialized).enumerate() {
        writer.start_file(format!("brushes/{index}.cbor"), options)?;
        writer.write_all(&bytes)?;
        let preview = preview_for(preset)?;
        let preview_webp = webp::Encoder::from_rgba(
            &preview.rgba8,
            u32::from(preview.width),
            u32::from(preview.height),
        )
        .encode(90.0);
        writer.start_file(format!("brushes/{index}.preview.webp"), options)?;
        writer.write_all(&preview_webp)?;
    }
    for resource in resources {
        writer.start_file(format!("resources/{}.rgba", hex(&resource.sha256)), options)?;
        writer.write_all(&resource.data)?;
    }
    writer.finish()?.sync_all()?;
    Ok(())
}

/// Import every member of a native `.inkbrushpack` transactionally.
#[allow(clippy::too_many_lines)]
pub fn import_inkbrushpack(path: &Path) -> Result<Vec<BrushImportReport>, BrushPackError> {
    let archive_bytes = read_bounded_file(path, MAX_ARCHIVE_BYTES)?;
    let source_sha256 = sha256(&archive_bytes);
    let archive_size = archive_bytes.len() as u64;
    let mut archive = ZipArchive::new(Cursor::new(archive_bytes))?;
    if archive.is_empty() || archive.len() > MAX_ENTRIES {
        return Err(BrushPackError::UnsafeArchive(
            "entry count is outside limits",
        ));
    }
    validate_archive_entries(&mut archive, archive_size)?;
    let manifest_bytes = read_entry(&mut archive, "manifest.json", MAX_MANIFEST_BYTES)?;
    let manifest: NativePackManifest = serde_json::from_slice(&manifest_bytes)?;
    if manifest.format_version != 1
        || manifest.brushes.is_empty()
        || manifest.brushes.len() > MAX_ENTRIES
    {
        return Err(BrushPackError::InvalidManifest(
            "native brush pack manifest is outside limits".into(),
        ));
    }
    let mut resources = HashMap::with_capacity(manifest.resources.len());
    let mut resource_bytes = 0_u64;
    for descriptor in &manifest.resources {
        let hash = parse_hash(&descriptor.hash)?;
        let entry_name = format!("resources/{}.rgba", descriptor.hash.to_ascii_lowercase());
        let data = read_entry(&mut archive, &entry_name, MAX_RESOURCE_BYTES)?;
        if sha256(&data) != hash {
            return Err(BrushPackError::HashMismatch);
        }
        let resource = ImportedResource {
            name: entry_name,
            kind: descriptor.kind.clone(),
            sha256: hash,
            bytes: u64::try_from(data.len()).unwrap_or(u64::MAX),
            data,
            width: descriptor.width,
            height: descriptor.height,
        };
        validate_resource(&resource)?;
        resource_bytes =
            resource_bytes
                .checked_add(resource.bytes)
                .ok_or(BrushPackError::UnsafeArchive(
                    "brush resource library size overflows",
                ))?;
        if resource_bytes > MAX_RESOURCE_LIBRARY_BYTES {
            return Err(BrushPackError::UnsafeArchive(
                "brush resource library exceeds limits",
            ));
        }
        if resources.insert(hash, resource).is_some() {
            return Err(BrushPackError::InvalidManifest(
                "native brush pack has duplicate resource hashes".into(),
            ));
        }
    }
    let mut reports = Vec::with_capacity(manifest.brushes.len());
    let mut indexes = HashSet::with_capacity(manifest.brushes.len());
    let mut report_resource_bytes = 0_u64;
    for member in &manifest.brushes {
        if !indexes.insert(member.index) {
            return Err(BrushPackError::InvalidManifest(
                "native brush pack has duplicate member indexes".into(),
            ));
        }
        let entry_name = format!("brushes/{}.cbor", member.index);
        let preset_bytes = read_entry(&mut archive, &entry_name, MAX_PRESET_BYTES)?;
        if hex(&Sha256::digest(&preset_bytes)) != member.preset_sha256 {
            return Err(BrushPackError::HashMismatch);
        }
        let preset: BrushPresetV2 =
            from_reader(Cursor::new(preset_bytes)).map_err(BrushPackError::Cbor)?;
        preset.validate()?;
        if preset.id.0 != member.brush_id || preset.metadata.name != member.name {
            return Err(BrushPackError::InvalidManifest(
                "pack member identity differs from its manifest".into(),
            ));
        }
        let member_resource_refs = resource_hashes_for_preset(&preset)
            .into_iter()
            .filter_map(|hash| resources.get(&hash))
            .collect::<Vec<_>>();
        let member_resource_bytes = member_resource_refs
            .iter()
            .try_fold(0_u64, |total, resource| total.checked_add(resource.bytes))
            .ok_or(BrushPackError::UnsafeArchive(
                "multi-brush member resource size overflows",
            ))?;
        report_resource_bytes =
            add_pack_report_resource_bytes(report_resource_bytes, member_resource_bytes)?;
        let member_resources = member_resource_refs
            .into_iter()
            .cloned()
            .collect::<Vec<_>>();
        if let Some(hash) = tip_resource_hash(&preset)
            && !resources.contains_key(&hash)
        {
            return Err(BrushPackError::InvalidManifest(
                "pack member references a missing image tip resource".into(),
            ));
        }
        let preview_entry = format!("brushes/{}.preview.webp", member.index);
        let preview_bytes = read_entry(&mut archive, &preview_entry, MAX_PRESET_BYTES)?;
        if preview_bytes.len() < 12
            || &preview_bytes[..4] != b"RIFF"
            || &preview_bytes[8..12] != b"WEBP"
        {
            return Err(BrushPackError::UnsafeArchive(
                "native brush pack preview is not a bounded WebP",
            ));
        }
        let preview = preview_for(&preset)?;
        reports.push(BrushImportReport {
            source_format: ExternalBrushFormat::InkBrushPack,
            source_sha256,
            importer_version: BRUSH_IMPORTER_VERSION.into(),
            fidelity: FidelityTier::Lossless,
            preset: Some(preset),
            mappings: Vec::new(),
            omitted: Vec::new(),
            resources: member_resources,
            preview: Some(preview),
            warnings: Vec::new(),
        });
    }
    Ok(reports)
}

fn validate_archive_entries<R: Read + Seek>(
    archive: &mut ZipArchive<R>,
    archive_bytes: u64,
) -> Result<(), BrushPackError> {
    let mut expanded = 0_u64;
    let mut names = HashSet::with_capacity(archive.len());
    let mut folded_names = HashSet::with_capacity(archive.len());
    for index in 0..archive.len() {
        let entry = archive.by_index(index)?;
        let name = entry.name().to_owned();
        if entry.enclosed_name().is_none()
            || name.starts_with('/')
            || name.contains('\\')
            || name.contains("..")
            || entry.is_dir()
            || !names.insert(name.clone())
            || !folded_names.insert(name.to_ascii_lowercase())
        {
            return Err(BrushPackError::UnsafeArchive(
                "archive path is not normalized or unique",
            ));
        }
        if entry.compressed_size() > 0
            && entry.size()
                > entry
                    .compressed_size()
                    .saturating_mul(MAX_COMPRESSION_RATIO)
        {
            return Err(BrushPackError::UnsafeArchive(
                "archive entry compression ratio exceeds the safety limit",
            ));
        }
        expanded = expanded.saturating_add(entry.size());
        if expanded > MAX_EXPANDED_BYTES {
            return Err(BrushPackError::UnsafeArchive(
                "expanded archive is too large",
            ));
        }
    }
    if expanded > archive_bytes.saturating_mul(MAX_COMPRESSION_RATIO) {
        return Err(BrushPackError::UnsafeArchive(
            "archive compression ratio exceeds the safety limit",
        ));
    }
    Ok(())
}

/// Import a native preset without modifying the source archive.
#[allow(clippy::too_many_lines)]
pub fn import_inkbrush(path: &Path) -> Result<BrushImportReport, BrushPackError> {
    let archive_bytes = read_bounded_file(path, MAX_ARCHIVE_BYTES)?;
    let source_sha256 = sha256(&archive_bytes);
    let archive_size = archive_bytes.len() as u64;
    let mut archive = ZipArchive::new(Cursor::new(archive_bytes))?;
    if archive.is_empty() || archive.len() > MAX_ENTRIES {
        return Err(BrushPackError::UnsafeArchive(
            "entry count is outside limits",
        ));
    }
    let mut expanded = 0_u64;
    let mut names = HashSet::with_capacity(archive.len());
    let mut folded_names = HashSet::with_capacity(archive.len());
    for index in 0..archive.len() {
        let entry = archive.by_index(index)?;
        let name = entry.name().to_owned();
        if entry.enclosed_name().is_none()
            || name.starts_with('/')
            || name.contains('\\')
            || name.contains("..")
            || entry.is_dir()
            || !names.insert(name.clone())
            || !folded_names.insert(name.to_ascii_lowercase())
        {
            return Err(BrushPackError::UnsafeArchive(
                "archive path is not normalized or unique",
            ));
        }
        if entry.compressed_size() > 0
            && entry.size()
                > entry
                    .compressed_size()
                    .saturating_mul(MAX_COMPRESSION_RATIO)
        {
            return Err(BrushPackError::UnsafeArchive(
                "archive entry compression ratio exceeds the safety limit",
            ));
        }
        expanded = expanded.saturating_add(entry.size());
        if expanded > MAX_EXPANDED_BYTES {
            return Err(BrushPackError::UnsafeArchive(
                "expanded archive is too large",
            ));
        }
    }
    if expanded > archive_size.saturating_mul(MAX_COMPRESSION_RATIO) {
        return Err(BrushPackError::UnsafeArchive(
            "archive compression ratio exceeds the safety limit",
        ));
    }
    let manifest_bytes = read_entry(&mut archive, "manifest.json", MAX_MANIFEST_BYTES)?;
    let manifest: NativeManifest = serde_json::from_slice(&manifest_bytes)?;
    if manifest.format_version != 1 {
        return Err(BrushPackError::InvalidManifest(
            "unsupported format version".into(),
        ));
    }
    let preset_bytes = read_entry(&mut archive, "preset.cbor", MAX_PRESET_BYTES)?;
    let hash = Sha256::digest(&preset_bytes);
    if hex(&hash) != manifest.preset_sha256 {
        return Err(BrushPackError::HashMismatch);
    }
    let preset: BrushPresetV2 =
        from_reader(Cursor::new(preset_bytes)).map_err(BrushPackError::Cbor)?;
    preset.validate()?;
    if preset.id.0 != manifest.brush_id || preset.metadata.name != manifest.name {
        return Err(BrushPackError::InvalidManifest(
            "manifest and preset identity differ".into(),
        ));
    }
    let preview = read_entry(&mut archive, "preview.webp", MAX_PRESET_BYTES)?;
    if preview.len() < 12 || &preview[..4] != b"RIFF" || &preview[8..12] != b"WEBP" {
        return Err(BrushPackError::UnsafeArchive(
            "native brush preview is not a bounded WebP",
        ));
    }
    let preview = preview_for(&preset)?;
    let mut resources = Vec::with_capacity(manifest.resources.len());
    let mut resource_bytes = 0_u64;
    let mut resource_hashes = HashSet::with_capacity(manifest.resources.len());
    for descriptor in &manifest.resources {
        let hash = parse_hash(&descriptor.hash)?;
        if !resource_hashes.insert(hash) {
            return Err(BrushPackError::InvalidManifest(
                "native pack contains duplicate resource hashes".into(),
            ));
        }
        if !preset_references_resource(&preset, hash) {
            return Err(BrushPackError::InvalidManifest(
                "native pack contains an unreferenced resource".into(),
            ));
        }
        let entry_name = format!("resources/{}.rgba", descriptor.hash.to_ascii_lowercase());
        let data = read_entry(&mut archive, &entry_name, MAX_RESOURCE_BYTES)?;
        if sha256(&data) != hash {
            return Err(BrushPackError::HashMismatch);
        }
        let resource = ImportedResource {
            name: entry_name,
            kind: descriptor.kind.clone(),
            sha256: hash,
            bytes: u64::try_from(data.len()).unwrap_or(u64::MAX),
            data,
            width: descriptor.width,
            height: descriptor.height,
        };
        validate_resource(&resource)?;
        resource_bytes =
            resource_bytes
                .checked_add(resource.bytes)
                .ok_or(BrushPackError::UnsafeArchive(
                    "brush resource library size overflows",
                ))?;
        if resource_bytes > MAX_RESOURCE_LIBRARY_BYTES {
            return Err(BrushPackError::UnsafeArchive(
                "brush resource library exceeds limits",
            ));
        }
        resources.push(resource);
    }
    Ok(BrushImportReport {
        source_format: ExternalBrushFormat::InkBrush,
        source_sha256,
        importer_version: BRUSH_IMPORTER_VERSION.into(),
        fidelity: FidelityTier::Lossless,
        preset: Some(preset),
        mappings: Vec::new(),
        omitted: Vec::new(),
        resources,
        preview: Some(preview),
        warnings: Vec::new(),
    })
}

/// Return the extension hint for a known external format.
///
/// This is intentionally only a hint. Callers that are about to inspect or
/// import a file use [`detect_external_format`], which validates magic bytes
/// and the native archive manifest before selecting a parser.
#[must_use]
pub fn inspect_external_format(path: &Path) -> ExternalBrushFormat {
    match path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase()
        .as_str()
    {
        "inkbrush" => ExternalBrushFormat::InkBrush,
        "inkbrushpack" => ExternalBrushFormat::InkBrushPack,
        "kpp" => ExternalBrushFormat::KritaKpp,
        "bundle" => ExternalBrushFormat::KritaBundle,
        "myb" => ExternalBrushFormat::MyPaintMyb,
        "abr" => ExternalBrushFormat::PhotoshopAbr,
        "sut" => ExternalBrushFormat::SutArchive,
        "tos" => ExternalBrushFormat::TosArchive,
        "brush" => ExternalBrushFormat::BrushArchive,
        "brushset" => ExternalBrushFormat::BrushSetArchive,
        "brushlibrary" => ExternalBrushFormat::BrushLibraryArchive,
        "png" | "jpg" | "jpeg" | "webp" => ExternalBrushFormat::Image,
        _ => ExternalBrushFormat::Unknown,
    }
}

/// Detect a source format from bounded structure and magic bytes.
///
/// Proprietary guided-recreation formats do not have a stable public magic
/// contract, so their extension is retained only as a non-executable UI hint.
/// Native Project Ink archives, images, Krita PNG presets, `MyPaint` JSON, and
/// Photoshop ABR files are never trusted from an extension alone.
fn detect_external_format(path: &Path) -> Result<ExternalBrushFormat, BrushPackError> {
    if std::fs::symlink_metadata(path)?.file_type().is_symlink() {
        return Err(BrushPackError::UnsafeArchive(
            "brush source must not be a symlink",
        ));
    }
    let metadata = std::fs::metadata(path)?;
    if metadata.len() > MAX_ARCHIVE_BYTES {
        return Err(BrushPackError::UnsafeArchive(
            "source exceeds import size limit",
        ));
    }
    let hint = inspect_external_format(path);
    let raw = read_file_prefix(path, MAX_INSPECTION_BYTES as u64)?;
    if raw.starts_with(b"PK") {
        if let Ok(format) = classify_native_archive(path) {
            return Ok(format);
        }
        if hint == ExternalBrushFormat::KritaBundle {
            validate_zip_file(path)?;
            return Ok(ExternalBrushFormat::KritaBundle);
        }
        if matches!(
            hint,
            ExternalBrushFormat::BrushArchive
                | ExternalBrushFormat::BrushSetArchive
                | ExternalBrushFormat::BrushLibraryArchive
        ) {
            validate_zip_file(path)?;
            return Ok(hint);
        }
        return Err(BrushPackError::UnsafeArchive(
            "ZIP brush source has no recognized native manifest",
        ));
    }
    if raw.starts_with(b"\x89PNG\r\n\x1a\n") {
        let _ = image_dimensions(&raw)?;
        return Ok(if hint == ExternalBrushFormat::KritaKpp {
            ExternalBrushFormat::KritaKpp
        } else {
            ExternalBrushFormat::Image
        });
    }
    if raw.starts_with(b"RIFF") && raw.len() >= 12 && &raw[8..12] == b"WEBP" {
        let _ = image_dimensions(&raw)?;
        return Ok(ExternalBrushFormat::Image);
    }
    if raw.starts_with(&[0xff, 0xd8]) {
        let _ = image_dimensions(&raw)?;
        return Ok(ExternalBrushFormat::Image);
    }
    if raw.starts_with(b"8BPS") {
        return Ok(ExternalBrushFormat::Unknown);
    }
    if hint == ExternalBrushFormat::PhotoshopAbr
        && raw.len() >= 2
        && matches!(u16::from_be_bytes([raw[0], raw[1]]), 1 | 2 | 6..=10)
    {
        return Ok(ExternalBrushFormat::PhotoshopAbr);
    }
    if hint == ExternalBrushFormat::MyPaintMyb {
        let bytes = read_bounded_file(path, MAX_PRESET_BYTES as u64)?;
        let value: serde_json::Value = serde_json::from_slice(&bytes)?;
        if !value.is_object() {
            return Err(BrushPackError::UnsafeArchive(
                "MyPaint brush metadata must be a JSON object",
            ));
        }
        return Ok(ExternalBrushFormat::MyPaintMyb);
    }
    if matches!(
        hint,
        ExternalBrushFormat::SutArchive
            | ExternalBrushFormat::TosArchive
            | ExternalBrushFormat::BrushArchive
            | ExternalBrushFormat::BrushSetArchive
            | ExternalBrushFormat::BrushLibraryArchive
    ) {
        if raw.is_empty() {
            return Err(BrushPackError::UnsafeArchive(
                "guided brush source is empty",
            ));
        }
        return Ok(hint);
    }
    Ok(ExternalBrushFormat::Unknown)
}

fn validate_zip_file(path: &Path) -> Result<(), BrushPackError> {
    let metadata = std::fs::metadata(path)?;
    let file = File::open(path)?;
    let mut archive = ZipArchive::new(file)?;
    if archive.is_empty() || archive.len() > MAX_ENTRIES {
        return Err(BrushPackError::UnsafeArchive(
            "entry count is outside limits",
        ));
    }
    validate_archive_entries(&mut archive, metadata.len())
}

fn classify_native_archive(path: &Path) -> Result<ExternalBrushFormat, BrushPackError> {
    let metadata = std::fs::metadata(path)?;
    let file = File::open(path)?;
    let mut archive = ZipArchive::new(file)?;
    if archive.is_empty() || archive.len() > MAX_ENTRIES {
        return Err(BrushPackError::UnsafeArchive(
            "entry count is outside limits",
        ));
    }
    validate_archive_entries(&mut archive, metadata.len())?;
    let manifest = read_entry(&mut archive, "manifest.json", MAX_MANIFEST_BYTES)?;
    let value: serde_json::Value = serde_json::from_slice(&manifest)?;
    if value
        .get("brush_id")
        .is_some_and(serde_json::Value::is_number)
        && value
            .get("preset_sha256")
            .is_some_and(serde_json::Value::is_string)
    {
        return Ok(ExternalBrushFormat::InkBrush);
    }
    if value
        .get("brushes")
        .is_some_and(serde_json::Value::is_array)
    {
        return Ok(ExternalBrushFormat::InkBrushPack);
    }
    Err(BrushPackError::UnsafeArchive(
        "native manifest shape is not recognized",
    ))
}

/// Return a safe guided-recreation report for formats without a stable parser.
pub fn guided_recreation_report(path: &Path) -> Result<BrushImportReport, BrushPackError> {
    if std::fs::symlink_metadata(path)?.file_type().is_symlink() {
        return Err(BrushPackError::UnsafeArchive(
            "brush source must not be a symlink",
        ));
    }
    let format = detect_external_format(path)?;
    let source_sha256 = hash_file(path)?;
    let (fidelity, message) = match format {
        ExternalBrushFormat::KritaKpp
        | ExternalBrushFormat::KritaBundle
        | ExternalBrushFormat::MyPaintMyb => (
            FidelityTier::Approximate,
            "format recognized; conversion requires a versioned parser fixture",
        ),
        ExternalBrushFormat::PhotoshopAbr => (
            FidelityTier::Approximate,
            "tip extraction is experimental; exact Photoshop rendering is not promised",
        ),
        ExternalBrushFormat::SutArchive
        | ExternalBrushFormat::TosArchive
        | ExternalBrushFormat::BrushArchive
        | ExternalBrushFormat::BrushSetArchive
        | ExternalBrushFormat::BrushLibraryArchive => (
            FidelityTier::GuidedRecreation,
            "create a Project Ink brush from user-supplied tips, grain, and reference strokes",
        ),
        _ => (
            FidelityTier::Rejected,
            "no safe external brush converter is registered",
        ),
    };
    Ok(BrushImportReport {
        source_format: format,
        source_sha256,
        importer_version: BRUSH_IMPORTER_VERSION.into(),
        fidelity,
        preset: None,
        mappings: Vec::new(),
        omitted: Vec::new(),
        resources: Vec::new(),
        preview: None,
        warnings: vec![ImportWarning {
            code: "guided-recreation".into(),
            message: message.into(),
        }],
    })
}

/// Stage ordinary PNG shape and grain assets from a user-provided brush archive.
/// Archive settings remain intentionally uninterpreted.
fn import_brush_archive_assets(path: &Path) -> Result<BrushImportReport, BrushPackError> {
    let metadata = std::fs::metadata(path)?;
    if metadata.len() > MAX_ARCHIVE_BYTES {
        return Err(BrushPackError::UnsafeArchive(
            "source exceeds import size limit",
        ));
    }
    let source_sha256 = hash_file(path)?;
    let file = File::open(path)?;
    let mut archive = ZipArchive::new(file)?;
    if archive.is_empty() || archive.len() > MAX_ENTRIES {
        return Err(BrushPackError::UnsafeArchive(
            "entry count is outside limits",
        ));
    }
    validate_archive_entries(&mut archive, metadata.len())?;
    let mut resources = Vec::new();
    for (name, kind) in [("Shape.png", "tip"), ("Grain.png", "grain")] {
        let candidate = [name.to_owned(), format!("Reset/{name}")]
            .into_iter()
            .find(|candidate| archive.file_names().any(|entry| entry == candidate));
        let Some(candidate) = candidate else { continue };
        let bytes = read_entry(&mut archive, &candidate, MAX_RESOURCE_BYTES)?;
        let (width, height) = image_dimensions(&bytes)?;
        let mut rgba = decode_image_rgba8(&bytes, width, height)?;
        if kind == "tip" {
            normalize_monochrome_tip_alpha(&mut rgba);
        }
        resources.push(ImportedResource {
            name: candidate,
            kind: kind.into(),
            sha256: sha256(&rgba),
            bytes: u64::try_from(rgba.len()).unwrap_or(u64::MAX),
            data: rgba,
            width,
            height,
        });
    }
    if resources.is_empty() {
        return guided_recreation_report(path);
    }
    guided_report_from_assets(
        path,
        source_sha256,
        ExternalBrushFormat::BrushArchive,
        resources,
    )
}

/// Extract only ordinary PNG thumbnails from a legacy SQLite/TAR brush archive.
/// The encrypted C2F material payload is never decoded or decrypted.
fn import_sut_archive_assets(path: &Path) -> Result<BrushImportReport, BrushPackError> {
    use rusqlite::OpenFlags;
    let metadata = std::fs::metadata(path)?;
    if metadata.len() > MAX_ARCHIVE_BYTES {
        return Err(BrushPackError::UnsafeArchive(
            "source exceeds import size limit",
        ));
    }
    let source_sha256 = hash_file(path)?;
    let connection = rusqlite::Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    let references = sut_image_references(&connection)?;
    let mut statement =
        connection.prepare("SELECT OriginalPath, FileData FROM MaterialFile LIMIT 64")?;
    let materials = statement.query_map([], |row| {
        Ok((
            row.get::<_, Option<String>>(0)?,
            row.get::<_, Option<Vec<u8>>>(1)?,
        ))
    })?;
    let mut resources = Vec::new();
    for material in materials {
        let (Some(original_path), Some(tar)) = material? else {
            continue;
        };
        if tar.len() > MAX_RESOURCE_BYTES {
            continue;
        }
        let role = sut_material_role(&references, &original_path);
        let Some(role) = role else { continue };
        let Some(png) = tar_thumbnail(&tar)? else {
            continue;
        };
        let Ok((width, height)) = image_dimensions(&png) else {
            continue;
        };
        let Ok(mut rgba) = decode_image_rgba8(&png, width, height) else {
            continue;
        };
        if role == "tip" {
            normalize_monochrome_tip_alpha(&mut rgba);
        }
        if role == "grain" && !image_has_texture(&rgba) {
            continue;
        }
        resources.push(ImportedResource {
            name: format!("external brush {role} thumbnail.png"),
            kind: role.into(),
            sha256: sha256(&rgba),
            bytes: u64::try_from(rgba.len()).unwrap_or(u64::MAX),
            data: rgba,
            width,
            height,
        });
        if resources.len() == 2 {
            break;
        }
    }
    if resources.is_empty() {
        return guided_recreation_report(path);
    }
    guided_report_from_assets(
        path,
        source_sha256,
        ExternalBrushFormat::SutArchive,
        resources,
    )
}

struct SutImageReferences {
    texture: Option<Vec<u8>>,
    pattern: Option<Vec<u8>>,
}

fn sut_image_references(
    connection: &rusqlite::Connection,
) -> Result<SutImageReferences, BrushPackError> {
    use rusqlite::OptionalExtension;
    let (texture, pattern) = connection
        .query_row(
            "SELECT TextureImage, BrushPatternImageArray FROM Variant LIMIT 1",
            [],
            |row| {
                Ok((
                    row.get::<_, Option<Vec<u8>>>(0)?,
                    row.get::<_, Option<Vec<u8>>>(1)?,
                ))
            },
        )
        .optional()?
        .unwrap_or((None, None));
    Ok(SutImageReferences { texture, pattern })
}

fn sut_material_role(references: &SutImageReferences, original_path: &str) -> Option<&'static str> {
    let path_utf16: Vec<u8> = original_path
        .encode_utf16()
        .flat_map(u16::to_le_bytes)
        .collect();
    let matches_reference = |bytes: &[u8]| contains_bytes(bytes, &path_utf16);
    if references.pattern.as_deref().is_some_and(matches_reference) {
        Some("tip")
    } else if references.texture.as_deref().is_some_and(matches_reference) {
        Some("grain")
    } else {
        None
    }
}

fn guided_report_from_assets(
    path: &Path,
    source_sha256: [u8; 32],
    source_format: ExternalBrushFormat,
    resources: Vec<ImportedResource>,
) -> Result<BrushImportReport, BrushPackError> {
    let mut preset = crate::builtin_library()
        .into_iter()
        .find(|brush| brush.metadata.name == "Opaque Round")
        .ok_or_else(|| {
            BrushPackError::InvalidManifest("built-in conversion base is missing".into())
        })?;
    preset.id = BrushId::from_u128(u128::from_le_bytes(
        source_sha256[..16].try_into().expect("hash slice"),
    ));
    preset.metadata.name = format!(
        "Recreated — {}",
        path.file_stem().and_then(|n| n.to_str()).unwrap_or("brush")
    );
    preset.metadata.author = None;
    preset.metadata.license = Some("source license unknown; user-provided assets only".into());
    preset.metadata.source_format = Some(format!("{source_format:?}"));
    preset.metadata.tags = vec!["recreated".into(), "imported-assets".into()];
    let mut mappings = Vec::new();
    if let Some(tip) = resources.iter().find(|resource| resource.kind == "tip") {
        if let crate::TipBehavior::Stamp(value) = &mut preset.tip {
            value.resource_hash = Some(tip.sha256);
            value.diameter_px = 32.0;
        }
        mappings.push(SettingMapping {
            source_path: "source.tip-image".into(),
            source_value: DisplayValue::Text(tip.name.clone()),
            target_path: "tip.resource_hash".into(),
            target_value: DisplayValue::Text(hex(&tip.sha256)),
            quality: MappingQuality::Approximated,
            note: Some(
                "source image reused; brush behavior and filtering were not converted".into(),
            ),
        });
    }
    if let Some(grain) = resources.iter().find(|resource| resource.kind == "grain") {
        preset.grain = Some(crate::GrainBehavior {
            resource_hash: grain.sha256,
            scale: 1.0,
            depth: 0.35,
            contrast: 0.35,
            canvas_space: true,
        });
        mappings.push(SettingMapping {
            source_path: "source.grain-image".into(),
            source_value: DisplayValue::Text(grain.name.clone()),
            target_path: "grain.resource_hash".into(),
            target_value: DisplayValue::Text(hex(&grain.sha256)),
            quality: MappingQuality::Approximated,
            note: Some("source grain image reused with Project Ink default grain settings".into()),
        });
    }
    preset.validate()?;
    let preview = preview_for(&preset)?;
    let names = resources
        .iter()
        .map(|resource| resource.kind.as_str())
        .collect::<Vec<_>>()
        .join(" and ");
    Ok(BrushImportReport {
        source_format,
        source_sha256,
        importer_version: BRUSH_IMPORTER_VERSION.into(),
        fidelity: FidelityTier::GuidedRecreation,
        preset: Some(preset),
        mappings,
        omitted: vec![OmittedSetting {
            source_path: "source.brush-settings".into(),
            reason: "source renderer settings, dynamics, and effects are not converted".into(),
        }],
        resources,
        preview: Some(preview),
        warnings: vec![ImportWarning {
            code: "guided-assets-staged".into(),
            message: format!(
                "{names} image assets were staged for a new recreated brush; nothing was installed automatically"
            ),
        }],
    })
}

fn normalize_monochrome_tip_alpha(rgba: &mut [u8]) {
    for pixel in rgba.as_chunks_mut::<4>().0 {
        let luminance =
            ((u16::from(pixel[0]) * 54 + u16::from(pixel[1]) * 183 + u16::from(pixel[2]) * 19)
                / 256) as u8;
        pixel[3] =
            u8::try_from(u16::from(pixel[3]) * u16::from(255 - luminance) / 255).unwrap_or(0);
        pixel[..3].fill(255);
    }
}

fn contains_bytes(haystack: &[u8], needle: &[u8]) -> bool {
    !needle.is_empty()
        && haystack
            .windows(needle.len())
            .any(|window| window == needle)
}

fn tar_thumbnail(tar: &[u8]) -> Result<Option<Vec<u8>>, BrushPackError> {
    let mut offset = 0usize;
    while offset.checked_add(512).is_some_and(|end| end <= tar.len()) {
        let header = &tar[offset..offset + 512];
        if header.iter().all(|byte| *byte == 0) {
            break;
        }
        let name_end = header[..100]
            .iter()
            .position(|byte| *byte == 0)
            .unwrap_or(100);
        let name = std::str::from_utf8(&header[..name_end]).unwrap_or("");
        let size_end = header[124..136]
            .iter()
            .position(|byte| *byte == 0)
            .unwrap_or(12);
        let size_text = std::str::from_utf8(&header[124..124 + size_end])
            .unwrap_or("")
            .trim();
        let size = usize::from_str_radix(size_text.trim_start_matches('0'), 8).unwrap_or(0);
        let start = offset + 512;
        let Some(end) = start.checked_add(size) else {
            break;
        };
        if end > tar.len() {
            return Err(BrushPackError::UnsafeArchive(
                "truncated material thumbnail archive",
            ));
        }
        if name == "thumbnail/thumbnail.png" && size <= MAX_RESOURCE_BYTES {
            return Ok(Some(tar[start..end].to_vec()));
        }
        let padded = size.checked_add(511).map(|value| value / 512 * 512);
        let Some(next) = padded.and_then(|value| start.checked_add(value)) else {
            break;
        };
        if next <= offset || next > tar.len() {
            break;
        }
        offset = next;
    }
    Ok(None)
}

fn image_has_texture(rgba: &[u8]) -> bool {
    let mut min = 255u8;
    let mut max = 0u8;
    for pixel in rgba.as_chunks::<4>().0 {
        let luminance =
            ((u16::from(pixel[0]) * 54 + u16::from(pixel[1]) * 183 + u16::from(pixel[2]) * 19)
                / 256) as u8;
        min = min.min(luminance);
        max = max.max(luminance);
        if max.saturating_sub(min) >= 8 {
            return true;
        }
    }
    false
}

/// Validate a source enough to display an import choice without installing it.
pub fn inspect_brush_import(path: &Path) -> Result<BrushImportInspection, BrushPackError> {
    if std::fs::symlink_metadata(path)?.file_type().is_symlink() {
        return Err(BrushPackError::UnsafeArchive(
            "brush source must not be a symlink",
        ));
    }
    let bytes = std::fs::metadata(path)?.len();
    if bytes > MAX_ARCHIVE_BYTES {
        return Err(BrushPackError::UnsafeArchive(
            "source exceeds import size limit",
        ));
    }
    let format = detect_external_format(path)?;
    let raw = if format == ExternalBrushFormat::Image {
        read_bounded_file(path, MAX_ARCHIVE_BYTES)?
    } else {
        read_file_prefix(path, MAX_INSPECTION_BYTES as u64)?
    };
    match format {
        ExternalBrushFormat::InkBrush | ExternalBrushFormat::InkBrushPack
            if raw.len() < 2 || !raw.starts_with(b"PK") =>
        {
            return Err(BrushPackError::UnsafeArchive(
                "native brush is not a ZIP archive",
            ));
        }
        ExternalBrushFormat::KritaKpp if !raw.starts_with(b"\x89PNG\r\n\x1a\n") => {
            return Err(BrushPackError::UnsafeArchive("Krita preset is not a PNG"));
        }
        ExternalBrushFormat::Image => {
            let _ = image_dimensions(&raw)?;
        }
        _ => {}
    }
    let fidelity_hint = match format {
        ExternalBrushFormat::InkBrush | ExternalBrushFormat::InkBrushPack => FidelityTier::Lossless,
        ExternalBrushFormat::KritaKpp | ExternalBrushFormat::MyPaintMyb => {
            FidelityTier::Approximate
        }
        ExternalBrushFormat::Image => FidelityTier::Approximate,
        ExternalBrushFormat::SutArchive
        | ExternalBrushFormat::TosArchive
        | ExternalBrushFormat::BrushArchive
        | ExternalBrushFormat::BrushSetArchive
        | ExternalBrushFormat::BrushLibraryArchive => FidelityTier::GuidedRecreation,
        _ => FidelityTier::Rejected,
    };
    Ok(BrushImportInspection {
        source_format: format,
        source_sha256: hash_file(path)?,
        bytes,
        fidelity_hint,
        importer_version: BRUSH_IMPORTER_VERSION.into(),
    })
}

/// Convert the safe, scalar subset of a Krita `.kpp` PNG preset.
///
/// Krita stores brush-engine metadata in bounded PNG annotations. This parser
/// intentionally ignores unknown binary chunks and never treats XML as code.
pub fn import_krita_kpp(path: &Path) -> Result<BrushImportReport, BrushPackError> {
    let bytes = read_bounded_file(path, MAX_ARCHIVE_BYTES)?;
    let source_sha256 = sha256(&bytes);
    import_krita_kpp_bytes(&bytes, source_sha256, ExternalBrushFormat::KritaKpp)
}

fn import_krita_kpp_bytes(
    bytes: &[u8],
    source_sha256: [u8; 32],
    source_format: ExternalBrushFormat,
) -> Result<BrushImportReport, BrushPackError> {
    if !bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        return Err(BrushPackError::UnsafeArchive(
            "Krita preset is not a bounded PNG",
        ));
    }
    let annotation = png_text_payload(bytes)?;
    let annotation_lower = annotation.to_ascii_lowercase();
    let spray = annotation_lower.contains("spray");
    let mut preset = crate::builtin_library()
        .into_iter()
        .find(|brush| {
            if spray {
                brush.metadata.name == "Ink Spatter"
            } else {
                brush.metadata.name == "Opaque Round"
            }
        })
        .ok_or_else(|| {
            BrushPackError::InvalidManifest("built-in conversion base is missing".into())
        })?;
    preset.id = BrushId::from_u128(u128::from_le_bytes(
        source_sha256[..16].try_into().expect("hash slice"),
    ));
    preset.metadata.name = format!("Krita conversion — {}", preset.metadata.name);
    preset.metadata.author = None;
    preset.metadata.license = Some("source license unknown; local use only".into());
    preset.metadata.source_format = Some("krita-kpp".into());
    preset.metadata.tags.push("converted".into());
    let mut mappings = Vec::new();
    if let Some(size) = find_number(&annotation, &["diameter", "size", "radius"])
        && let crate::TipBehavior::Stamp(tip) = &mut preset.tip
    {
        tip.diameter_px = size.clamp(0.25, 4096.0);
        mappings.push(SettingMapping {
            source_path: "diameter".into(),
            source_value: DisplayValue::Number(size),
            target_path: "tip.diameter_px".into(),
            target_value: DisplayValue::Number(tip.diameter_px),
            quality: MappingQuality::Normalized,
            note: Some("clamped to Project Ink brush limits".into()),
        });
    }
    if let Some(opacity) = find_number(&annotation, &["opacity"]) {
        let opacity = if opacity > 1.0 {
            opacity / 100.0
        } else {
            opacity
        };
        match &mut preset.paint {
            crate::PaintBehavior::Solid(value) => value.opacity = opacity.clamp(0.0, 1.0),
            crate::PaintBehavior::Glaze(value) => value.opacity = opacity.clamp(0.0, 1.0),
            crate::PaintBehavior::Marker(value) => value.opacity = opacity.clamp(0.0, 1.0),
            crate::PaintBehavior::ColorPickup(value) => value.opacity = opacity.clamp(0.0, 1.0),
            crate::PaintBehavior::DigitalWatercolor(value) => value.wash = opacity.clamp(0.0, 1.0),
        }
        mappings.push(SettingMapping {
            source_path: "opacity".into(),
            source_value: DisplayValue::Number(opacity),
            target_path: "paint.opacity".into(),
            target_value: DisplayValue::Number(opacity.clamp(0.0, 1.0)),
            quality: MappingQuality::Normalized,
            note: Some("percent values are normalized to 0..1".into()),
        });
    }
    preset.validate()?;
    let preview = preview_for(&preset)?;
    let tier = if annotation_lower.contains("pixel") && !annotation_lower.contains("unknown") {
        FidelityTier::High
    } else {
        FidelityTier::Approximate
    };
    Ok(BrushImportReport {
        source_format,
        source_sha256,
        importer_version: BRUSH_IMPORTER_VERSION.into(),
        fidelity: tier,
        preset: Some(preset),
        mappings,
        omitted: vec![OmittedSetting {
            source_path: "renderer-specific".into(),
            reason: "No direct equivalent in the deterministic CPU renderer".into(),
        }],
        resources: Vec::new(),
        preview: Some(preview),
        warnings: vec![ImportWarning {
            code: "resource-approximation".into(),
            message: "tip, grain, and renderer-specific settings were not copied; inspect the preview before saving".into(),
        }],
    })
}

/// Convert every bounded `.kpp` member in a Krita resource bundle.
///
/// Bundles are treated as untrusted ZIP archives. Only PNG-backed `.kpp`
/// members are decoded; resources, scripts, and unrelated files remain inert
/// and are never extracted to the filesystem.
pub fn import_krita_bundle(path: &Path) -> Result<Vec<BrushImportReport>, BrushPackError> {
    let archive_bytes = read_bounded_file(path, MAX_ARCHIVE_BYTES)?;
    let source_sha256 = sha256(&archive_bytes);
    let archive_size = u64::try_from(archive_bytes.len()).unwrap_or(u64::MAX);
    let mut archive = ZipArchive::new(Cursor::new(archive_bytes))?;
    if archive.is_empty() || archive.len() > MAX_ENTRIES {
        return Err(BrushPackError::UnsafeArchive(
            "Krita bundle entry count is outside limits",
        ));
    }
    validate_archive_entries(&mut archive, archive_size)?;
    let mut members = Vec::new();
    for index in 0..archive.len() {
        let entry = archive.by_index(index)?;
        let name = entry.name().to_owned();
        if name
            .rsplit('/')
            .next()
            .is_some_and(|value| value.to_ascii_lowercase().ends_with(".kpp"))
        {
            members.push(name);
        }
    }
    members.sort();
    if members.is_empty() {
        return Err(BrushPackError::InvalidManifest(
            "Krita bundle contains no .kpp presets".into(),
        ));
    }

    let mut reports = Vec::with_capacity(members.len());
    for member in members {
        let bytes = read_entry(
            &mut archive,
            &member,
            usize::try_from(MAX_ARCHIVE_BYTES).expect("archive limit fits usize"),
        )?;
        let member_hash = sha256(&bytes);
        let mut report =
            import_krita_kpp_bytes(&bytes, member_hash, ExternalBrushFormat::KritaBundle)?;
        report.source_sha256 = source_sha256;
        report.warnings.push(ImportWarning {
            code: "bundle-member".into(),
            message: format!("converted bounded Krita bundle member {member}"),
        });
        reports.push(report);
    }
    Ok(reports)
}

/// Convert the documented scalar subset of a `MyPaint` `.myb` JSON brush.
pub fn import_mypaint_myb(path: &Path) -> Result<BrushImportReport, BrushPackError> {
    if std::fs::symlink_metadata(path)?.file_type().is_symlink() {
        return Err(BrushPackError::UnsafeArchive(
            "MyPaint source must not be a symlink",
        ));
    }
    if std::fs::metadata(path)?.len() > MAX_PRESET_BYTES as u64 {
        return Err(BrushPackError::UnsafeArchive("MyPaint preset is too large"));
    }
    let bytes = read_bounded_file_with_message(
        path,
        MAX_PRESET_BYTES as u64,
        "MyPaint preset is too large",
    )?;
    let value: serde_json::Value = serde_json::from_slice(&bytes)?;
    let source_sha256 = sha256(&bytes);
    let mut preset = crate::builtin_library()
        .into_iter()
        .find(|brush| brush.metadata.name == "HB Sketch Pencil")
        .ok_or_else(|| {
            BrushPackError::InvalidManifest("built-in conversion base is missing".into())
        })?;
    preset.id = BrushId::from_u128(u128::from_le_bytes(
        source_sha256[..16].try_into().expect("hash slice"),
    ));
    preset.metadata.name = "MyPaint conversion".into();
    preset.metadata.author = None;
    preset.metadata.license = Some("source license unknown; local use only".into());
    preset.metadata.source_format = Some("mypaint-myb".into());
    preset.metadata.tags.push("converted".into());
    let mut mappings = Vec::new();
    if let Some(radius) = find_json_number(&value, &["radius", "radius_logarithmic"])
        && let crate::TipBehavior::Stamp(tip) = &mut preset.tip
    {
        tip.diameter_px = if radius < 1.0 {
            radius.exp() * 2.0
        } else {
            radius
        }
        .clamp(0.25, 4096.0);
        mappings.push(SettingMapping {
            source_path: "radius".into(),
            source_value: DisplayValue::Number(radius),
            target_path: "tip.diameter_px".into(),
            target_value: DisplayValue::Number(tip.diameter_px),
            quality: MappingQuality::Normalized,
            note: Some("MyPaint logarithmic radius converted to diameter".into()),
        });
    }
    if let Some(opacity) = find_json_number(&value, &["opacity", "opaque"])
        && let crate::PaintBehavior::Glaze(paint) = &mut preset.paint
    {
        paint.opacity = opacity.clamp(0.0, 1.0);
        mappings.push(SettingMapping {
            source_path: "opacity".into(),
            source_value: DisplayValue::Number(opacity),
            target_path: "paint.opacity".into(),
            target_value: DisplayValue::Number(paint.opacity),
            quality: MappingQuality::Normalized,
            note: None,
        });
    }
    preset.validate()?;
    let preview = preview_for(&preset)?;
    Ok(BrushImportReport {
        source_format: ExternalBrushFormat::MyPaintMyb,
        source_sha256,
        importer_version: BRUSH_IMPORTER_VERSION.into(),
        fidelity: FidelityTier::Approximate,
        preset: Some(preset),
        mappings,
        omitted: Vec::new(),
        resources: Vec::new(),
        preview: Some(preview),
        warnings: vec![ImportWarning {
            code: "renderer-substitution".into(),
            message: "Project Ink uses its deterministic CPU renderer instead of libmypaint; compare the preview".into(),
        }],
    })
}

/// Inspect or convert a supported external file through one safe entry point.
pub fn import_external(path: &Path) -> Result<BrushImportReport, BrushPackError> {
    if std::fs::symlink_metadata(path)?.file_type().is_symlink() {
        return Err(BrushPackError::UnsafeArchive(
            "brush source must not be a symlink",
        ));
    }
    match detect_external_format(path)? {
        ExternalBrushFormat::InkBrush => import_inkbrush(path),
        ExternalBrushFormat::InkBrushPack => {
            let reports = import_inkbrushpack(path)?;
            if reports.len() == 1 {
                return Ok(reports.into_iter().next().expect("one report"));
            }
            let source_sha256 = hash_file(path)?;
            let resource_count: usize = reports.iter().map(|report| report.resources.len()).sum();
            Ok(BrushImportReport {
                source_format: ExternalBrushFormat::InkBrushPack,
                source_sha256,
                importer_version: BRUSH_IMPORTER_VERSION.into(),
                fidelity: FidelityTier::Lossless,
                preset: None,
                mappings: Vec::new(),
                omitted: Vec::new(),
                resources: Vec::new(),
                preview: None,
                warnings: vec![ImportWarning {
                    code: "multi-brush-pack".into(),
                    message: format!(
                        "pack contains {} lossless brushes and {} referenced resources; use the pack install operation",
                        reports.len(),
                        resource_count
                    ),
                }],
            })
        }
        ExternalBrushFormat::KritaKpp => import_krita_kpp(path),
        ExternalBrushFormat::KritaBundle => {
            let reports = import_krita_bundle(path)?;
            if reports.len() == 1 {
                return Ok(reports.into_iter().next().expect("one bundle member"));
            }
            let source_sha256 = hash_file(path)?;
            Ok(BrushImportReport {
                source_format: ExternalBrushFormat::KritaBundle,
                source_sha256,
                importer_version: BRUSH_IMPORTER_VERSION.into(),
                fidelity: FidelityTier::Approximate,
                preset: None,
                mappings: Vec::new(),
                omitted: Vec::new(),
                resources: Vec::new(),
                preview: None,
                warnings: vec![ImportWarning {
                    code: "multi-brush-bundle".into(),
                    message: format!(
                        "bundle contains {} converted presets; use the bundle install operation",
                        reports.len()
                    ),
                }],
            })
        }
        ExternalBrushFormat::MyPaintMyb => import_mypaint_myb(path),
        ExternalBrushFormat::PhotoshopAbr => import_photoshop_abr(path).and_then(|mut reports| {
            reports
                .drain(..)
                .next()
                .ok_or(BrushPackError::UnsafeArchive(
                    "ABR contains no supported brushes",
                ))
        }),
        ExternalBrushFormat::BrushArchive => import_brush_archive_assets(path),
        ExternalBrushFormat::SutArchive => import_sut_archive_assets(path),
        ExternalBrushFormat::Image => import_image_as_brush(path),
        _ => guided_recreation_report(path),
    }
}

/// Convert supported ABR computed and sampled presets into bounded Ink brush
/// reports. Every converted preset is marked Approximate (tier C); skipped
/// or unsupported records are summarized in each returned report's warnings.
pub fn import_photoshop_abr(path: &Path) -> Result<Vec<BrushImportReport>, BrushPackError> {
    if std::fs::symlink_metadata(path)?.file_type().is_symlink() {
        return Err(BrushPackError::UnsafeArchive(
            "brush source must not be a symlink",
        ));
    }
    let bytes = read_bounded_file_with_message(
        path,
        MAX_ARCHIVE_BYTES,
        "ABR source exceeds the 256 MiB import limit",
    )?;
    let name = path
        .file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or("Imported brush");
    convert_photoshop_abr_bytes(&bytes, name)
}

fn convert_photoshop_abr_bytes(
    bytes: &[u8],
    source_name: &str,
) -> Result<Vec<BrushImportReport>, BrushPackError> {
    let abr = photocraft_psd::abr::parse(bytes)
        .map_err(|error| BrushPackError::InvalidManifest(format!("ABR parse failed: {error}")))?;
    let source_sha256 = sha256(bytes);
    let (mut converted, mut omitted_records) = if abr.legacy.is_empty() {
        convert_sectioned_abr(&abr, source_name, source_sha256)
    } else {
        convert_legacy_abr(&abr.legacy, source_name, source_sha256)
    };
    omitted_records.extend(abr.warnings);
    if omitted_records.len() > MAX_ABR_REPORT_OMISSIONS {
        return Err(BrushPackError::UnsafeArchive(
            "ABR has too many unsupported or malformed records for a complete bounded report; no brushes were imported",
        ));
    }
    if converted.is_empty() {
        return Err(BrushPackError::UnsafeArchive(
            "ABR has no supported, bounded brush tips",
        ));
    }
    let omitted_text = omitted_records
        .iter()
        .map(|record| bounded_text(record, 256))
        .collect::<Vec<_>>();
    for report in &mut converted {
        if report.omitted.len().saturating_add(omitted_text.len()) > MAX_ABR_REPORT_OMISSIONS {
            return Err(BrushPackError::UnsafeArchive(
                "ABR omissions exceed the complete per-brush report bound; no brushes were imported",
            ));
        }
        report.source_sha256 = source_sha256;
        report
            .omitted
            .extend(omitted_text.iter().map(|record| OmittedSetting {
                source_path: "abr.member".into(),
                reason: record.clone(),
            }));
        if !omitted_records.is_empty() {
            report.warnings.push(ImportWarning {
                code: "abr-members-skipped".into(),
                message: format!(
                    "{} unsupported or malformed ABR record(s) were skipped; see Not carried over",
                    omitted_records.len()
                ),
            });
        }
    }
    Ok(converted)
}

fn convert_legacy_abr(
    legacy: &[photocraft_psd::abr::LegacyBrush],
    source_name: &str,
    source_sha256: [u8; 32],
) -> (Vec<BrushImportReport>, Vec<String>) {
    let mut converted = Vec::new();
    let mut omitted = Vec::new();
    let mut remaining_resource_bytes = MAX_PACK_REPORT_RESOURCE_BYTES;
    for (index, brush) in legacy.iter().take(MAX_ABR_IMPORT_PRESETS).enumerate() {
        if let photocraft_psd::abr::LegacyTip::Sampled(sample) = &brush.tip {
            match abr_sample_rgba_bytes(sample) {
                Ok(required) if required <= remaining_resource_bytes => {
                    remaining_resource_bytes -= required;
                }
                Ok(_) => {
                    omitted.push(format!(
                        "{}: cumulative imported tip resources exceed the 256 MiB limit",
                        abr_brush_label(&brush.name, index)
                    ));
                    continue;
                }
                Err(reason) => {
                    omitted.push(format!("{}: {reason}", abr_brush_label(&brush.name, index)));
                    continue;
                }
            }
        }
        match convert_legacy_abr_brush(brush, source_name, index, source_sha256) {
            Ok(report) => converted.push(report),
            Err(reason) => {
                omitted.push(format!("{}: {reason}", abr_brush_label(&brush.name, index)));
            }
        }
    }
    if legacy.len() > MAX_ABR_IMPORT_PRESETS {
        omitted.push(format!(
            "{} additional ABR brushes exceeded the {MAX_ABR_IMPORT_PRESETS}-preset import limit",
            legacy.len() - MAX_ABR_IMPORT_PRESETS
        ));
    }
    (converted, omitted)
}

fn convert_sectioned_abr(
    abr: &photocraft_psd::abr::AbrFile,
    source_name: &str,
    source_sha256: [u8; 32],
) -> (Vec<BrushImportReport>, Vec<String>) {
    let mut converted = Vec::new();
    let mut omitted = Vec::new();
    let mut matched_sample_ids = HashSet::new();
    let mut remaining_resource_bytes = MAX_PACK_REPORT_RESOURCE_BYTES;
    for (index, descriptor) in abr.presets.iter().take(MAX_ABR_IMPORT_PRESETS).enumerate() {
        if let Some(sample) = sectioned_abr_sample(descriptor, &abr.samples) {
            match abr_sample_rgba_bytes(sample) {
                Ok(required) if required <= remaining_resource_bytes => {}
                Ok(_) => {
                    omitted.push(format!(
                        "{}: cumulative imported tip resources exceed the 256 MiB limit",
                        abr_descriptor_name(descriptor)
                            .unwrap_or_else(|| format!("Brush {}", index + 1))
                    ));
                    continue;
                }
                Err(reason) => {
                    omitted.push(format!(
                        "{}: {reason}",
                        abr_descriptor_name(descriptor)
                            .unwrap_or_else(|| format!("Brush {}", index + 1))
                    ));
                    continue;
                }
            }
        }
        match convert_sectioned_abr_preset(
            descriptor,
            &abr.samples,
            source_name,
            index,
            source_sha256,
        ) {
            Ok((report, sample_id)) => {
                if let Some(sample_id) = sample_id {
                    matched_sample_ids.insert(sample_id);
                }
                remaining_resource_bytes = remaining_resource_bytes
                    .saturating_sub(report.resources.iter().map(|resource| resource.bytes).sum());
                converted.push(report);
            }
            Err(reason) => omitted.push(format!(
                "{}: {reason}",
                abr_descriptor_name(descriptor).unwrap_or_else(|| format!("Brush {}", index + 1))
            )),
        }
    }
    push_abr_limit_omission(&mut omitted, abr.presets.len(), "ABR presets");
    if abr.presets.is_empty() {
        for (index, sample) in abr.samples.iter().take(MAX_ABR_IMPORT_PRESETS).enumerate() {
            let required = match abr_sample_rgba_bytes(sample) {
                Ok(required) if required <= remaining_resource_bytes => required,
                Ok(_) => {
                    omitted.push(format!(
                        "Sample {}: cumulative imported tip resources exceed the 256 MiB limit",
                        index + 1
                    ));
                    continue;
                }
                Err(reason) => {
                    omitted.push(format!("Sample {}: {reason}", index + 1));
                    continue;
                }
            };
            match converted_sample_report(
                sample,
                source_name,
                &format!("{} tip {}", source_name, index + 1),
                index,
                25,
                32.0,
                100.0,
                100.0,
                0.0,
                source_sha256,
            ) {
                Ok(report) => {
                    remaining_resource_bytes = remaining_resource_bytes.saturating_sub(required);
                    converted.push(report);
                }
                Err(reason) => omitted.push(format!("Sample {}: {reason}", index + 1)),
            }
        }
        push_abr_limit_omission(&mut omitted, abr.samples.len(), "standalone ABR tips");
    } else {
        for sample in &abr.samples {
            if !matched_sample_ids.contains(&sample.id) {
                omitted.push(format!(
                    "Sample {} was not referenced by a supported preset",
                    bounded_text(&sample.id, 128)
                ));
            }
        }
    }
    (converted, omitted)
}

fn push_abr_limit_omission(omitted: &mut Vec<String>, actual_count: usize, subject: &str) {
    if actual_count > MAX_ABR_IMPORT_PRESETS {
        omitted.push(format!(
            "{} additional {subject} exceeded the {MAX_ABR_IMPORT_PRESETS}-preset import limit",
            actual_count - MAX_ABR_IMPORT_PRESETS
        ));
    }
}

fn convert_legacy_abr_brush(
    brush: &photocraft_psd::abr::LegacyBrush,
    source_name: &str,
    index: usize,
    source_sha256: [u8; 32],
) -> Result<BrushImportReport, String> {
    match &brush.tip {
        photocraft_psd::abr::LegacyTip::Computed {
            diameter,
            hardness,
            angle,
            roundness,
        } => computed_abr_report(
            source_name,
            &abr_brush_label(&brush.name, index),
            index,
            brush.spacing,
            f32::from(*diameter),
            f32::from(*hardness),
            f32::from(*roundness),
            f32::from(*angle),
            source_sha256,
            vec![SettingMapping {
                source_path: "abr.tip.kind".into(),
                source_value: DisplayValue::Text("computed".into()),
                target_path: "tip.shape".into(),
                target_value: DisplayValue::Text("procedural stamp".into()),
                quality: MappingQuality::Approximated,
                note: Some("Photoshop rasterization and edge coverage are not reproduced".into()),
            }],
            Vec::new(),
        ),
        photocraft_psd::abr::LegacyTip::Sampled(sample) => converted_sample_report(
            sample,
            source_name,
            &abr_brush_label(&brush.name, index),
            index,
            brush.spacing,
            32.0,
            100.0,
            100.0,
            0.0,
            source_sha256,
        ),
    }
}

fn sectioned_abr_sample<'a>(
    preset: &photocraft_psd::descriptor::Descriptor,
    samples: &'a [photocraft_psd::abr::AbrSample],
) -> Option<&'a photocraft_psd::abr::AbrSample> {
    use photocraft_psd::descriptor::Value;
    let Some(Value::Descriptor(brush_descriptor)) = preset.get("Brsh") else {
        return None;
    };
    let Some(Value::Text(sample_id)) = brush_descriptor.get("sampledData") else {
        return None;
    };
    let sample_id = sample_id.to_string_lossy();
    samples.iter().find(|sample| sample.id == sample_id)
}

fn abr_sample_rgba_bytes(sample: &photocraft_psd::abr::AbrSample) -> Result<u64, String> {
    let byte_count = u64::from(sample.width)
        .checked_mul(u64::from(sample.height))
        .and_then(|pixels| pixels.checked_mul(4))
        .ok_or_else(|| "decoded tip size overflows".to_string())?;
    if sample.width > MAX_RESOURCE_DIMENSION
        || sample.height > MAX_RESOURCE_DIMENSION
        || byte_count > u64::try_from(MAX_RESOURCE_BYTES).unwrap_or(u64::MAX)
    {
        return Err("decoded sampled tip exceeds Ink's dimension or 96 MiB resource limit".into());
    }
    Ok(byte_count)
}

fn convert_sectioned_abr_preset(
    preset: &photocraft_psd::descriptor::Descriptor,
    samples: &[photocraft_psd::abr::AbrSample],
    source_name: &str,
    index: usize,
    source_sha256: [u8; 32],
) -> Result<(BrushImportReport, Option<String>), String> {
    use photocraft_psd::descriptor::Value;

    let name =
        abr_descriptor_name(preset).unwrap_or_else(|| format!("{source_name} {}", index + 1));
    let Some(Value::Descriptor(brush_descriptor)) = preset.get("Brsh") else {
        return Err("preset has no supported brush descriptor".into());
    };
    if let Some(Value::Text(sample_id)) = brush_descriptor.get("sampledData") {
        let sample_id = sample_id.to_string_lossy();
        let sample = samples
            .iter()
            .find(|sample| sample.id == sample_id)
            .ok_or_else(|| "sampled tip reference is missing".to_string())?;
        let settings =
            sectioned_abr_settings(brush_descriptor, f64::from(sample.width.max(sample.height)));
        let mut report = converted_sample_report(
            sample,
            source_name,
            &name,
            index,
            settings.spacing,
            settings.diameter,
            settings.hardness,
            settings.roundness,
            settings.angle,
            source_sha256,
        )?;
        let dynamics = sectioned_abr_dynamics(brush_descriptor);
        apply_sectioned_abr_dynamics(&mut report, dynamics)?;
        report
            .omitted
            .extend(abr_unsupported_settings(preset, brush_descriptor)?);
        return Ok((report, Some(sample_id)));
    }
    if brush_descriptor.class_id.is("computedBrush") {
        let settings = sectioned_abr_settings(brush_descriptor, 32.0);
        let mut report = computed_abr_report(
            source_name,
            &name,
            index,
            settings.spacing,
            settings.diameter,
            settings.hardness,
            settings.roundness,
            settings.angle,
            source_sha256,
            Vec::new(),
            abr_unsupported_settings(preset, brush_descriptor)?,
        )?;
        let dynamics = sectioned_abr_dynamics(brush_descriptor);
        apply_sectioned_abr_dynamics(&mut report, dynamics)?;
        return Ok((report, None));
    }
    Err("preset uses an unsupported computed or sampled tip descriptor".into())
}

struct SectionedAbrSettings {
    spacing: u16,
    diameter: f32,
    hardness: f32,
    roundness: f32,
    angle: f32,
}

fn sectioned_abr_settings(
    descriptor: &photocraft_psd::descriptor::Descriptor,
    default_diameter: f64,
) -> SectionedAbrSettings {
    SectionedAbrSettings {
        spacing: descriptor_spacing(descriptor_number(descriptor, &["Spcn", "spacing"]), 25),
        diameter: bounded_descriptor_f32(
            descriptor_number(descriptor, &["Dmtr", "diameter"]),
            default_diameter,
            0.25,
            2_000.0,
        ),
        hardness: bounded_descriptor_f32(
            descriptor_number(descriptor, &["Hrdn", "hardness"]),
            100.0,
            0.0,
            100.0,
        ),
        roundness: bounded_descriptor_f32(
            descriptor_number(descriptor, &["Rndn", "roundness"]),
            100.0,
            1.0,
            100.0,
        ),
        angle: bounded_descriptor_f32(
            descriptor_number(descriptor, &["Angl", "angle"]),
            0.0,
            -180.0,
            180.0,
        ),
    }
}

struct SectionedAbrDynamics {
    bindings: Vec<ParameterBinding>,
    mappings: Vec<SettingMapping>,
    omitted: Vec<OmittedSetting>,
}

/// Map the pressure-controlled, zero-jitter subset whose output has a direct
/// equivalent in Ink's normalized sensor evaluator. Other ABR dynamics stay
/// explicit omissions; parsing a descriptor alone never implies fidelity.
fn sectioned_abr_dynamics(brush: &photocraft_psd::descriptor::Descriptor) -> SectionedAbrDynamics {
    use photocraft_psd::descriptor::Value;

    let mut result = SectionedAbrDynamics {
        bindings: Vec::new(),
        mappings: Vec::new(),
        omitted: Vec::new(),
    };
    for (enabled_key, dynamics_key, target, label) in [
        ("useTipDynamics", "szVr", ParameterId::Diameter, "size"),
        ("usePaintDynamics", "opVr", ParameterId::Opacity, "opacity"),
    ] {
        if !matches!(brush.get(enabled_key), Some(Value::Boolean(true))) {
            continue;
        }
        let Some(Value::Descriptor(dynamics)) = brush.get(dynamics_key) else {
            result.omitted.push(abr_dynamics_omission(
                dynamics_key,
                "enabled Photoshop control has no readable dynamics descriptor",
            ));
            continue;
        };
        let control = descriptor_number(dynamics, &["bVTy"]);
        let jitter = descriptor_percent(dynamics, "jitter");
        if control != Some(2.0) || jitter != Some(0.0) {
            result.omitted.push(abr_dynamics_omission(
                dynamics_key,
                "only zero-jitter pen-pressure dynamics can be mapped",
            ));
            continue;
        }
        let outer_minimum = if target == ParameterId::Diameter {
            descriptor_percent(brush, "minimumDiameter")
        } else {
            None
        };
        let minimum = outer_minimum
            .or_else(|| descriptor_percent(dynamics, "Mnm "))
            .unwrap_or(100.0);
        if !minimum.is_finite() || !(0.0..=100.0).contains(&minimum) {
            result.omitted.push(abr_dynamics_omission(
                dynamics_key,
                "minimum value is outside the supported 0–100 percent range",
            ));
            continue;
        }
        let minimum = percent_to_unit_f32(minimum);
        result.bindings.push(ParameterBinding {
            target,
            base: minimum,
            sensor: SensorId::Pressure,
            curve: ResponseCurve::identity(),
            amount: 1.0 - minimum,
            combine: CombineOp::Add,
        });
        result.mappings.push(SettingMapping {
            source_path: format!("abr.brush.{dynamics_key}"),
            source_value: DisplayValue::Text(format!(
                "pen pressure, minimum {:.0}%",
                minimum * 100.0
            )),
            target_path: format!("dynamics.pressure.{label}"),
            target_value: DisplayValue::Text(format!(
                "linear {:.0}% to 100%",
                minimum * 100.0
            )),
            quality: MappingQuality::Approximated,
            note: Some(
                "maps to Ink's normalized pressure response; Photoshop's stroke renderer is not reproduced".into(),
            ),
        });
    }
    result
}

fn abr_dynamics_omission(key: &str, reason: &str) -> OmittedSetting {
    OmittedSetting {
        source_path: format!("abr.brush.{key}"),
        reason: reason.into(),
    }
}

fn descriptor_percent(
    descriptor: &photocraft_psd::descriptor::Descriptor,
    key: &str,
) -> Option<f64> {
    match descriptor.get(key)? {
        photocraft_psd::descriptor::Value::UnitFloat { unit, value }
            if unit == b"#Prc" && value.is_finite() =>
        {
            Some(*value)
        }
        _ => None,
    }
}

#[allow(clippy::cast_possible_truncation)]
fn percent_to_unit_f32(percent: f64) -> f32 {
    // Callers validate this descriptor value is finite and in 0..=100 first.
    (percent / 100.0) as f32
}

fn apply_sectioned_abr_dynamics(
    report: &mut BrushImportReport,
    dynamics: SectionedAbrDynamics,
) -> Result<(), String> {
    let preset = report
        .preset
        .as_mut()
        .ok_or_else(|| "converted ABR preset is missing".to_string())?;
    preset.dynamics.extend(dynamics.bindings);
    preset.validate().map_err(|error| error.to_string())?;
    report.mappings.extend(dynamics.mappings);
    report.omitted.extend(dynamics.omitted);
    report.preview = Some(preview_for(preset).map_err(|error| error.to_string())?);
    Ok(())
}

fn abr_unsupported_settings(
    preset: &photocraft_psd::descriptor::Descriptor,
    brush: &photocraft_psd::descriptor::Descriptor,
) -> Result<Vec<OmittedSetting>, String> {
    let known_preset = ["Nm  ", "Brsh"];
    let known_brush = [
        "sampledData",
        "Spcn",
        "Dmtr",
        "Hrdn",
        "Rndn",
        "Angl",
        "useTipDynamics",
        "szVr",
        "minimumDiameter",
        "usePaintDynamics",
        "opVr",
    ];
    let mut omitted = Vec::new();
    for (key, _) in &preset.items {
        if !known_preset.iter().any(|known| key.is(known)) {
            if omitted.len() == MAX_ABR_REPORT_OMISSIONS {
                return Err(format!(
                    "preset has more than {MAX_ABR_REPORT_OMISSIONS} unsupported settings; the complete bounded report cannot fit"
                ));
            }
            omitted.push(OmittedSetting {
                source_path: format!("abr.preset.{}", String::from_utf8_lossy(key.as_bytes())),
                reason: "preset setting has no supported Project Ink mapping".into(),
            });
        }
    }
    for (key, _) in &brush.items {
        if !known_brush.iter().any(|known| key.is(known)) {
            if omitted.len() == MAX_ABR_REPORT_OMISSIONS {
                return Err(format!(
                    "preset has more than {MAX_ABR_REPORT_OMISSIONS} unsupported settings; the complete bounded report cannot fit"
                ));
            }
            omitted.push(OmittedSetting {
                source_path: format!("abr.brush.{}", String::from_utf8_lossy(key.as_bytes())),
                reason: "brush setting has no supported Project Ink mapping".into(),
            });
        }
    }
    Ok(omitted)
}

fn descriptor_number(
    descriptor: &photocraft_psd::descriptor::Descriptor,
    keys: &[&str],
) -> Option<f64> {
    use photocraft_psd::descriptor::Value;
    keys.iter().find_map(|key| match descriptor.get(key)? {
        Value::Double(value) | Value::UnitFloat { value, .. } => Some(*value),
        Value::Integer(value) => Some(f64::from(*value)),
        _ => None,
    })
}

#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
fn descriptor_spacing(value: Option<f64>, default: u16) -> u16 {
    let value = value
        .filter(|number| number.is_finite())
        .unwrap_or(f64::from(default));
    value.round().clamp(1.0, 100.0) as u16
}

#[allow(clippy::cast_possible_truncation)]
fn bounded_descriptor_f32(value: Option<f64>, default: f64, min: f64, max: f64) -> f32 {
    let value = value.filter(|number| number.is_finite()).unwrap_or(default);
    value.clamp(min, max) as f32
}

fn abr_descriptor_name(descriptor: &photocraft_psd::descriptor::Descriptor) -> Option<String> {
    use photocraft_psd::descriptor::Value;
    match descriptor.get("Nm  ") {
        Some(Value::Text(name)) => {
            let value = bounded_text(&name.to_string_lossy(), 128);
            (!value.trim().is_empty()).then_some(value)
        }
        _ => None,
    }
}

fn abr_brush_label(name: &str, index: usize) -> String {
    if name.trim().is_empty() {
        format!("Imported brush {}", index + 1)
    } else {
        bounded_text(name, 128)
    }
}

fn bounded_text(value: &str, max_bytes: usize) -> String {
    value
        .char_indices()
        .take_while(|(offset, character)| offset.saturating_add(character.len_utf8()) <= max_bytes)
        .map(|(_, character)| character)
        .collect()
}

#[allow(clippy::too_many_arguments)]
fn computed_abr_report(
    source_name: &str,
    name: &str,
    index: usize,
    spacing_percent: u16,
    diameter: f32,
    hardness_percent: f32,
    roundness_percent: f32,
    angle_degrees: f32,
    source_sha256: [u8; 32],
    mut mappings: Vec<SettingMapping>,
    omitted: Vec<OmittedSetting>,
) -> Result<BrushImportReport, String> {
    let mut preset = abr_base_preset(source_name, name, index, source_sha256)?;
    let computed_mappings = abr_scalar_mappings(
        spacing_percent,
        diameter,
        hardness_percent,
        roundness_percent,
        angle_degrees,
    );
    mappings.extend(computed_mappings);
    if let TipBehavior::Stamp(tip) = &mut preset.tip {
        tip.diameter_px = diameter;
        tip.hardness = (hardness_percent / 100.0).clamp(0.0, 1.0);
        tip.roundness = (roundness_percent / 100.0).clamp(0.01, 1.0);
        tip.angle_degrees = angle_degrees;
    }
    set_abr_spacing(&mut preset, spacing_percent);
    preset.validate().map_err(|error| error.to_string())?;
    let preview = preview_for(&preset).map_err(|error| error.to_string())?;
    Ok(BrushImportReport {
        source_format: ExternalBrushFormat::PhotoshopAbr,
        source_sha256,
        importer_version: BRUSH_IMPORTER_VERSION.into(),
        fidelity: FidelityTier::Approximate,
        preset: Some(preset),
        mappings,
        omitted,
        resources: Vec::new(),
        preview: Some(preview),
        warnings: vec![ImportWarning {
            code: "abr-approximate-renderer".into(),
            message: "Imported as an Approximate tier C brush; Project Ink does not reproduce Photoshop rendering.".into(),
        }],
    })
}

#[allow(clippy::too_many_arguments)]
fn converted_sample_report(
    sample: &photocraft_psd::abr::AbrSample,
    source_name: &str,
    name: &str,
    index: usize,
    spacing_percent: u16,
    diameter: f32,
    hardness_percent: f32,
    roundness_percent: f32,
    angle_degrees: f32,
    source_sha256: [u8; 32],
) -> Result<BrushImportReport, String> {
    let byte_count = abr_sample_rgba_bytes(sample)?;
    let rgba = abr_sample_to_rgba(sample)?;
    let resource_sha256 = sha256(&rgba);
    let mut preset = abr_base_preset(source_name, name, index, source_sha256)?;
    if let TipBehavior::Stamp(tip) = &mut preset.tip {
        tip.resource_hash = Some(resource_sha256);
        tip.diameter_px = diameter;
        tip.hardness = (hardness_percent / 100.0).clamp(0.0, 1.0);
        tip.roundness = (roundness_percent / 100.0).clamp(0.01, 1.0);
        tip.angle_degrees = angle_degrees;
    }
    set_abr_spacing(&mut preset, spacing_percent);
    preset.validate().map_err(|error| error.to_string())?;
    let preview = preview_for(&preset).map_err(|error| error.to_string())?;
    let mut mappings = abr_scalar_mappings(
        spacing_percent,
        diameter,
        hardness_percent,
        roundness_percent,
        angle_degrees,
    );
    mappings.push(SettingMapping {
        source_path: "sampledData".into(),
        source_value: DisplayValue::Text(format!(
            "{} ({}x{}x{})",
            sample.id, sample.width, sample.height, sample.depth
        )),
        target_path: "tip.resource_hash".into(),
        target_value: DisplayValue::Text(hex(&resource_sha256)),
        quality: MappingQuality::Approximated,
        note: Some(
            "ABR tip identity is retained in this report; sampled coverage is saved as a content-addressed local monochrome tip".into(),
        ),
    });
    Ok(BrushImportReport {
        source_format: ExternalBrushFormat::PhotoshopAbr,
        source_sha256,
        importer_version: BRUSH_IMPORTER_VERSION.into(),
        fidelity: FidelityTier::Approximate,
        preset: Some(preset),
        mappings,
        omitted: vec![OmittedSetting {
            source_path: "abr.renderer".into(),
            reason: "Photoshop tip rasterization, dual brushes, texture, and other renderer-specific behavior are not carried over".into(),
        }],
        resources: vec![ImportedResource {
            name: bounded_text(name, 128),
            kind: "tip".into(),
            sha256: resource_sha256,
            bytes: byte_count,
            data: rgba,
            width: sample.width,
            height: sample.height,
        }],
        preview: Some(preview),
        warnings: vec![ImportWarning {
            code: "abr-approximate-renderer".into(),
            message: "Imported as an Approximate tier C brush; Project Ink does not reproduce Photoshop rendering.".into(),
        }],
    })
}

fn abr_sample_to_rgba(sample: &photocraft_psd::abr::AbrSample) -> Result<Vec<u8>, String> {
    let pixels = usize::try_from(sample.width)
        .ok()
        .and_then(|width| {
            usize::try_from(sample.height)
                .ok()
                .and_then(|height| width.checked_mul(height))
        })
        .ok_or_else(|| "sample dimensions overflow".to_string())?;
    let mut rgba = Vec::with_capacity(pixels.checked_mul(4).ok_or("sample size overflow")?);
    match sample.depth {
        8 if sample.data.len() == pixels => {
            for coverage in &sample.data {
                rgba.extend_from_slice(&[255, 255, 255, *coverage]);
            }
        }
        16 if sample.data.len() == pixels.saturating_mul(2) => {
            for pair in sample.data.as_chunks::<2>().0 {
                let value = u16::from_be_bytes(*pair);
                let coverage = u8::try_from((u32::from(value) + 128) / 257)
                    .map_err(|_| "16-bit sample conversion failed".to_string())?;
                rgba.extend_from_slice(&[255, 255, 255, coverage]);
            }
        }
        _ => return Err("sample byte length does not match its dimensions and depth".into()),
    }
    Ok(rgba)
}

fn abr_base_preset(
    source_name: &str,
    name: &str,
    index: usize,
    source_sha256: [u8; 32],
) -> Result<BrushPresetV2, String> {
    let mut preset = crate::builtin_library()
        .into_iter()
        .find(|brush| brush.metadata.name == "Opaque Round")
        .ok_or_else(|| "built-in conversion base is missing".to_string())?;
    let mut id_bytes = [0; 16];
    id_bytes.copy_from_slice(&source_sha256[..16]);
    preset.id = BrushId::from_u128(u128::from_le_bytes(id_bytes).wrapping_add(index as u128));
    preset.format_version = 2;
    preset.engine_semantics = EngineSemantics(CPU_BRUSH_V2);
    // External presets must not inherit defaults from the local Opaque Round
    // preset; only dynamics explicitly present in the source file are mapped.
    preset.dynamics.clear();
    preset.stroke.stabilizer = PathStabilizer::Legacy;
    preset.metadata.name = bounded_text(name, 128);
    preset.metadata.author = None;
    preset.metadata.license = Some("unknown; verify source rights before redistribution".into());
    preset.metadata.source_format = Some("photoshop-abr".into());
    preset.metadata.tags = vec!["converted".into(), "photoshop-abr".into()];
    let source_label = source_name
        .chars()
        .filter(|character| !character.is_control())
        .collect::<String>();
    let source_label = bounded_text(source_label.trim(), 116);
    if !source_label.is_empty() {
        preset
            .metadata
            .tags
            .push(format!("source-file:{source_label}"));
    }
    Ok(preset)
}

fn set_abr_spacing(preset: &mut BrushPresetV2, spacing_percent: u16) {
    preset.stroke.spacing = f32::from(spacing_percent.clamp(1, 100)) / 100.0;
}

fn abr_scalar_mappings(
    spacing_percent: u16,
    diameter: f32,
    hardness: f32,
    roundness: f32,
    angle: f32,
) -> Vec<SettingMapping> {
    [
        (
            "spacing",
            "stroke.spacing",
            f32::from(spacing_percent) / 100.0,
        ),
        ("diameter", "tip.diameter_px", diameter),
        ("hardness", "tip.hardness", hardness / 100.0),
        ("roundness", "tip.roundness", roundness / 100.0),
        ("angle", "tip.angle_degrees", angle),
    ]
    .into_iter()
    .map(|(source, target, value)| SettingMapping {
        source_path: format!("abr.{source}"),
        source_value: DisplayValue::Number(value),
        target_path: target.into(),
        target_value: DisplayValue::Number(value),
        quality: MappingQuality::Approximated,
        note: None,
    })
    .collect()
}

/// Explicitly import a user-selected PNG/JPEG/WebP image as a brush tip.
///
/// The source is decoded into a bounded straight-alpha RGBA8 resource. The
/// preset records the decoded content hash and never follows a path at render
/// time.
pub fn import_image_as_brush(path: &Path) -> Result<BrushImportReport, BrushPackError> {
    if std::fs::symlink_metadata(path)?.file_type().is_symlink() {
        return Err(BrushPackError::UnsafeArchive(
            "image source must not be a symlink",
        ));
    }
    let metadata = std::fs::metadata(path)?;
    if metadata.len() > 64 * 1024 * 1024 {
        return Err(BrushPackError::UnsafeArchive(
            "image exceeds the tip import limit",
        ));
    }
    let bytes = read_bounded_file_with_message(
        path,
        64 * 1024 * 1024,
        "image exceeds the tip import limit",
    )?;
    let (width, height) = image_dimensions(&bytes)?;
    let mut decoded = decode_image_rgba8(&bytes, width, height)?;
    normalize_monochrome_tip_alpha(&mut decoded);
    let source_sha256 = sha256(&bytes);
    let resource_sha256 = sha256(&decoded);
    let mut preset = crate::builtin_library()
        .into_iter()
        .find(|brush| brush.metadata.name == "Opaque Round")
        .ok_or_else(|| {
            BrushPackError::InvalidManifest("built-in conversion base is missing".into())
        })?;
    preset.id = BrushId::from_u128(u128::from_le_bytes(
        source_sha256[..16].try_into().expect("hash slice"),
    ));
    preset.metadata.name = format!(
        "Image tip — {}",
        path.file_stem()
            .and_then(|name| name.to_str())
            .unwrap_or("imported")
    );
    preset.metadata.author = None;
    preset.metadata.license = Some("user-supplied resource; verify source rights".into());
    preset.metadata.source_format = Some("image-tip".into());
    preset.metadata.tags = vec!["converted".into(), "image-tip".into()];
    if let crate::TipBehavior::Stamp(tip) = &mut preset.tip {
        tip.resource_hash = Some(resource_sha256);
        tip.diameter_px = 32.0;
    }
    preset.validate()?;
    let preview = preview_for(&preset)?;
    Ok(BrushImportReport {
        source_format: ExternalBrushFormat::Image,
        source_sha256,
        importer_version: BRUSH_IMPORTER_VERSION.into(),
        fidelity: FidelityTier::Approximate,
        preset: Some(preset),
        mappings: vec![SettingMapping {
            source_path: "image.dimensions".into(),
            source_value: DisplayValue::Text(format!("{width}x{height}")),
            target_path: "tip.resource_hash".into(),
            target_value: DisplayValue::Text(hex(&resource_sha256)),
            quality: MappingQuality::Approximated,
            note: Some(
                "the source image is used as a tip resource by the library staging layer".into(),
            ),
        }],
        omitted: vec![OmittedSetting {
            source_path: "source-renderer".into(),
            reason: "image filtering and source-app brush semantics are not imported".into(),
        }],
        resources: vec![ImportedResource {
            name: path
                .file_name()
                .and_then(|name| name.to_str())
                .unwrap_or("tip")
                .to_owned(),
            kind: "tip".into(),
            sha256: resource_sha256,
            bytes: u64::try_from(decoded.len()).unwrap_or(u64::MAX),
            data: decoded,
            width,
            height,
        }],
        preview: Some(preview),
        warnings: vec![ImportWarning {
            code: "image-tip-staged".into(),
            message: "confirm the staged resource before saving the brush".into(),
        }],
    })
}

fn preview_for(preset: &BrushPresetV2) -> Result<BrushPreview, BrushPackError> {
    let width = 160_u16;
    let height = 64_u16;
    let rgba8 = preset.preview_rgba8(width, height)?;
    let expected = usize::from(width)
        .saturating_mul(usize::from(height))
        .saturating_mul(4);
    if rgba8.len() != expected {
        return Err(BrushPackError::UnsafeArchive(
            "generated preview has invalid size",
        ));
    }
    Ok(BrushPreview {
        width,
        height,
        rgba8,
    })
}

fn preset_references_resource(preset: &BrushPresetV2, hash: [u8; 32]) -> bool {
    let tip_matches = match &preset.tip {
        crate::TipBehavior::Stamp(tip) => tip.resource_hash == Some(hash),
        _ => false,
    };
    let grain_matches = preset
        .grain
        .as_ref()
        .is_some_and(|grain| grain.resource_hash == hash);
    let post_effect_matches = preset.post_effects.iter().any(|effect| {
        matches!(
            effect,
            PostEffect::TexturePass {
                resource_hash,
                ..
            } if *resource_hash == hash
        )
    });
    tip_matches
        || grain_matches
        || post_effect_matches
        || preset
            .dual
            .as_ref()
            .is_some_and(|dual| preset_references_resource(&dual.secondary, hash))
}

fn resource_hashes_for_preset(preset: &BrushPresetV2) -> Vec<[u8; 32]> {
    let mut hashes = Vec::new();
    if let crate::TipBehavior::Stamp(tip) = &preset.tip
        && let Some(hash) = tip.resource_hash
    {
        hashes.push(hash);
    }
    if let Some(grain) = &preset.grain {
        hashes.push(grain.resource_hash);
    }
    for effect in &preset.post_effects {
        if let PostEffect::TexturePass { resource_hash, .. } = effect {
            hashes.push(*resource_hash);
        }
    }
    if let Some(dual) = &preset.dual {
        hashes.extend(resource_hashes_for_preset(&dual.secondary));
    }
    hashes.sort_unstable();
    hashes.dedup();
    hashes
}

fn add_pack_report_resource_bytes(current: u64, additional: u64) -> Result<u64, BrushPackError> {
    let total = current
        .checked_add(additional)
        .ok_or(BrushPackError::UnsafeArchive(
            "multi-brush report resource size overflows",
        ))?;
    if total > MAX_PACK_REPORT_RESOURCE_BYTES {
        return Err(BrushPackError::UnsafeArchive(
            "multi-brush report resources exceed limits",
        ));
    }
    Ok(total)
}

fn tip_resource_hash(preset: &BrushPresetV2) -> Option<[u8; 32]> {
    match &preset.tip {
        crate::TipBehavior::Stamp(tip) => tip.resource_hash,
        _ => None,
    }
}

fn validate_resource(resource: &ImportedResource) -> Result<(), BrushPackError> {
    if resource.width == 0
        || resource.height == 0
        || resource.width > MAX_RESOURCE_DIMENSION
        || resource.height > MAX_RESOURCE_DIMENSION
    {
        return Err(BrushPackError::UnsafeArchive(
            "brush resource dimensions exceed limits",
        ));
    }
    let expected = u64::from(resource.width)
        .checked_mul(u64::from(resource.height))
        .and_then(|value| value.checked_mul(4))
        .ok_or(BrushPackError::UnsafeArchive(
            "brush resource size overflows",
        ))?;
    if expected > MAX_RESOURCE_BYTES as u64
        || expected != u64::try_from(resource.data.len()).unwrap_or(u64::MAX)
    {
        return Err(BrushPackError::UnsafeArchive(
            "brush resource payload is not bounded RGBA8",
        ));
    }
    Ok(())
}

fn parse_hash(value: &str) -> Result<[u8; 32], BrushPackError> {
    if value.len() != 64 {
        return Err(BrushPackError::InvalidManifest(
            "resource hash must be 64 hexadecimal characters".into(),
        ));
    }
    let mut output = [0_u8; 32];
    let (pairs, remainder) = value.as_bytes().as_chunks::<2>();
    debug_assert!(remainder.is_empty());
    for (index, chunk) in pairs.iter().enumerate() {
        let high = hex_nibble(chunk[0]).ok_or_else(|| {
            BrushPackError::InvalidManifest("resource hash is not hexadecimal".into())
        })?;
        let low = hex_nibble(chunk[1]).ok_or_else(|| {
            BrushPackError::InvalidManifest("resource hash is not hexadecimal".into())
        })?;
        output[index] = (high << 4) | low;
    }
    Ok(output)
}

fn hex_nibble(value: u8) -> Option<u8> {
    match value {
        b'0'..=b'9' => Some(value - b'0'),
        b'a'..=b'f' => Some(value - b'a' + 10),
        b'A'..=b'F' => Some(value - b'A' + 10),
        _ => None,
    }
}

fn decode_image_rgba8(
    bytes: &[u8],
    expected_width: u32,
    expected_height: u32,
) -> Result<Vec<u8>, BrushPackError> {
    let expected = u64::from(expected_width)
        .checked_mul(u64::from(expected_height))
        .and_then(|value| value.checked_mul(4))
        .ok_or(BrushPackError::UnsafeArchive(
            "decoded image size overflows",
        ))?;
    if expected > MAX_RESOURCE_BYTES as u64 {
        return Err(BrushPackError::UnsafeArchive(
            "decoded image exceeds the resource cache limit",
        ));
    }
    let mut limits = image::Limits::default();
    limits.max_image_width = Some(expected_width);
    limits.max_image_height = Some(expected_height);
    limits.max_alloc = Some(MAX_RESOURCE_BYTES as u64);
    let mut reader = image::ImageReader::new(Cursor::new(bytes))
        .with_guessed_format()
        .map_err(|_| BrushPackError::UnsafeArchive("image format cannot be identified"))?;
    reader.limits(limits);
    let image = reader
        .decode()
        .map_err(|_| BrushPackError::UnsafeArchive("image resource cannot be decoded"))?;
    if image.width() != expected_width || image.height() != expected_height {
        return Err(BrushPackError::UnsafeArchive(
            "decoded image dimensions do not match its header",
        ));
    }
    let data = image.into_rgba8().into_raw();
    if data.len() != usize::try_from(expected).unwrap_or(usize::MAX) {
        return Err(BrushPackError::UnsafeArchive(
            "decoded image has an invalid RGBA8 length",
        ));
    }
    Ok(data)
}

fn image_dimensions(bytes: &[u8]) -> Result<(u32, u32), BrushPackError> {
    let dimensions = if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        if bytes.len() < 24 || &bytes[12..16] != b"IHDR" {
            return Err(BrushPackError::UnsafeArchive("PNG tip is missing IHDR"));
        }
        (
            u32::from_be_bytes(bytes[16..20].try_into().expect("PNG width")),
            u32::from_be_bytes(bytes[20..24].try_into().expect("PNG height")),
        )
    } else if bytes.starts_with(b"RIFF") && bytes.len() >= 20 && &bytes[8..12] == b"WEBP" {
        webp_dimensions(bytes)?
    } else if bytes.starts_with(&[0xff, 0xd8]) {
        jpeg_dimensions(bytes).ok_or(BrushPackError::UnsafeArchive(
            "JPEG tip dimensions are unavailable",
        ))?
    } else {
        return Err(BrushPackError::UnsafeArchive(
            "unsupported image tip encoding",
        ));
    };
    let (width, height) = dimensions;
    let pixels = u64::from(width).saturating_mul(u64::from(height));
    if width == 0 || height == 0 || width > 16_384 || height > 16_384 || pixels > 128 * 1024 * 1024
    {
        return Err(BrushPackError::UnsafeArchive(
            "image tip dimensions exceed limits",
        ));
    }
    Ok(dimensions)
}

fn webp_dimensions(bytes: &[u8]) -> Result<(u32, u32), BrushPackError> {
    let chunk = &bytes[12..16];
    let chunk_size = usize::try_from(u32::from_le_bytes(
        bytes[16..20].try_into().expect("WebP chunk size header"),
    ))
    .map_err(|_| BrushPackError::UnsafeArchive("WebP chunk size is not representable"))?;
    match chunk {
        b"VP8X" if chunk_size >= 10 && bytes.len() >= 30 => {
            let data = &bytes[20..30];
            let width =
                1 + u32::from(data[4]) + (u32::from(data[5]) << 8) + (u32::from(data[6]) << 16);
            let height =
                1 + u32::from(data[7]) + (u32::from(data[8]) << 8) + (u32::from(data[9]) << 16);
            Ok((width, height))
        }
        b"VP8 " if chunk_size >= 10 && bytes.len() >= 30 && bytes[23..26] == [0x9d, 0x01, 0x2a] => {
            let data = &bytes[20..30];
            let width = u32::from(u16::from_le_bytes([data[6], data[7]]) & 0x3fff);
            let height = u32::from(u16::from_le_bytes([data[8], data[9]]) & 0x3fff);
            Ok((width, height))
        }
        b"VP8L" if chunk_size >= 5 && bytes.len() >= 25 && bytes[20] == 0x2f => {
            let data = &bytes[20..25];
            let width = 1 + (u32::from(data[1]) | ((u32::from(data[2]) & 0x3f) << 8));
            let height = 1
                + ((u32::from(data[2]) >> 6)
                    | (u32::from(data[3]) << 2)
                    | ((u32::from(data[4]) & 0x0f) << 10));
            Ok((width, height))
        }
        b"VP8X" | b"VP8 " | b"VP8L" => Err(BrushPackError::UnsafeArchive(
            "WebP image header is malformed",
        )),
        _ => Err(BrushPackError::UnsafeArchive(
            "unsupported WebP image encoding",
        )),
    }
}

fn jpeg_dimensions(bytes: &[u8]) -> Option<(u32, u32)> {
    let mut cursor = 2usize;
    while cursor + 4 <= bytes.len() {
        if bytes[cursor] != 0xff {
            cursor += 1;
            continue;
        }
        while cursor < bytes.len() && bytes[cursor] == 0xff {
            cursor += 1;
        }
        let marker = *bytes.get(cursor)?;
        cursor += 1;
        if marker == 0xd8 || marker == 0xd9 || (0xd0..=0xd7).contains(&marker) {
            continue;
        }
        let length = usize::from(u16::from_be_bytes([
            *bytes.get(cursor)?,
            *bytes.get(cursor + 1)?,
        ]));
        if length < 2 || cursor.checked_add(length)? > bytes.len() {
            return None;
        }
        if length >= 8
            && ((0xc0..=0xc3).contains(&marker)
                || (0xc5..=0xc7).contains(&marker)
                || (0xc9..=0xcb).contains(&marker)
                || (0xcd..=0xcf).contains(&marker))
        {
            let height = u32::from(u16::from_be_bytes([bytes[cursor + 3], bytes[cursor + 4]]));
            let width = u32::from(u16::from_be_bytes([bytes[cursor + 5], bytes[cursor + 6]]));
            return Some((width, height));
        }
        cursor += length;
    }
    None
}

fn png_text_payload(bytes: &[u8]) -> Result<String, BrushPackError> {
    let mut cursor = 8usize;
    let mut output = String::new();
    while cursor + 12 <= bytes.len() {
        let length = u32::from_be_bytes(bytes[cursor..cursor + 4].try_into().expect("chunk length"))
            as usize;
        cursor = cursor.saturating_add(4);
        if cursor.checked_add(4).is_none_or(|end| end > bytes.len()) {
            return Err(BrushPackError::UnsafeArchive("truncated PNG chunk type"));
        }
        let kind = &bytes[cursor..cursor + 4];
        cursor = cursor.saturating_add(4);
        let end = cursor
            .checked_add(length)
            .ok_or(BrushPackError::UnsafeArchive("PNG chunk overflow"))?;
        let crc_end = end
            .checked_add(4)
            .ok_or(BrushPackError::UnsafeArchive("PNG chunk overflow"))?;
        if crc_end > bytes.len() || length > MAX_MANIFEST_BYTES {
            return Err(BrushPackError::UnsafeArchive(
                "PNG annotation exceeds limit",
            ));
        }
        if (kind == b"tEXt" || kind == b"iTXt" || kind == b"zTXt")
            && let Ok(value) = std::str::from_utf8(&bytes[cursor..end])
        {
            output.push_str(value);
            output.push('\n');
            if output.len() > MAX_MANIFEST_BYTES {
                return Err(BrushPackError::UnsafeArchive(
                    "PNG annotations exceed limit",
                ));
            }
        }
        cursor = crc_end;
        if kind == b"IEND" {
            break;
        }
    }
    Ok(output)
}

fn find_number(text: &str, keys: &[&str]) -> Option<f32> {
    for key in keys {
        let mut start = 0usize;
        while let Some(offset) = text[start..].find(key) {
            let index = start + offset + key.len();
            let tail = text.get(index..).unwrap_or_default();
            let digits =
                tail.trim_start_matches(|ch: char| !ch.is_ascii_digit() && ch != '.' && ch != '-');
            let end = digits.find(|ch: char| {
                !ch.is_ascii_digit()
                    && ch != '.'
                    && ch != '-'
                    && ch != 'e'
                    && ch != 'E'
                    && ch != '+'
            });
            let candidate = end.map_or(digits, |end| &digits[..end]);
            if let Ok(value) = candidate.parse() {
                return Some(value);
            }
            start = index;
        }
    }
    None
}

#[allow(clippy::cast_possible_truncation)]
fn find_json_number(value: &serde_json::Value, keys: &[&str]) -> Option<f32> {
    // Walk iteratively with explicit depth/node limits. A hostile `.myb`
    // document must not be able to turn metadata lookup into unbounded
    // recursion or stack exhaustion.
    let mut pending = vec![(value, 0_u8)];
    let mut visited = 0_usize;
    while let Some((current, depth)) = pending.pop() {
        visited = visited.saturating_add(1);
        if visited > 100_000 || depth > 64 {
            continue;
        }
        match current {
            serde_json::Value::Object(map) => {
                for key in keys {
                    if let Some(value) = map.get(*key).and_then(serde_json::Value::as_f64) {
                        return Some(value as f32);
                    }
                }
                if depth < 64 {
                    pending.extend(map.values().map(|value| (value, depth + 1)));
                }
            }
            serde_json::Value::Array(values) if depth < 64 => {
                pending.extend(values.iter().map(|value| (value, depth + 1)));
            }
            _ => {}
        }
    }
    None
}

fn read_entry<R: Read + Seek>(
    archive: &mut ZipArchive<R>,
    name: &str,
    limit: usize,
) -> Result<Vec<u8>, BrushPackError> {
    let entry = archive.by_name(name)?;
    if entry.size() > limit as u64 {
        return Err(BrushPackError::UnsafeArchive("archive member is too large"));
    }
    let capacity = usize::try_from(entry.size())
        .map_err(|_| BrushPackError::UnsafeArchive("archive member size is not representable"))?;
    let mut bytes = Vec::with_capacity(capacity);
    entry
        .take((limit as u64).saturating_add(1))
        .read_to_end(&mut bytes)?;
    if bytes.len() > limit {
        return Err(BrushPackError::UnsafeArchive("archive member is too large"));
    }
    Ok(bytes)
}

fn hash_file(path: &Path) -> Result<[u8; 32], BrushPackError> {
    hash_file_with_limit(path, MAX_ARCHIVE_BYTES)
}

fn hash_file_with_limit(path: &Path, limit: u64) -> Result<[u8; 32], BrushPackError> {
    if std::fs::symlink_metadata(path)?.file_type().is_symlink() {
        return Err(BrushPackError::UnsafeArchive(
            "brush source must not be a symlink",
        ));
    }
    let file = File::open(path)?;
    let mut reader = file.take(limit.saturating_add(1));
    let mut hasher = Sha256::new();
    let mut buffer = vec![0_u8; 64 * 1024];
    let mut total = 0_u64;
    loop {
        let read = reader.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        total = total.saturating_add(u64::try_from(read).unwrap_or(u64::MAX));
        hasher.update(&buffer[..read]);
    }
    if total > limit {
        return Err(BrushPackError::UnsafeArchive(
            "source exceeds import size limit",
        ));
    }
    Ok(hasher.finalize().into())
}

fn read_bounded_file(path: &Path, limit: u64) -> Result<Vec<u8>, BrushPackError> {
    read_bounded_file_with_message(path, limit, "source exceeds import size limit")
}

fn read_bounded_file_with_message(
    path: &Path,
    limit: u64,
    limit_message: &'static str,
) -> Result<Vec<u8>, BrushPackError> {
    if std::fs::symlink_metadata(path)?.file_type().is_symlink() {
        return Err(BrushPackError::UnsafeArchive(
            "brush source must not be a symlink",
        ));
    }
    let file = File::open(path)?;
    let mut bytes = Vec::new();
    file.take(limit.saturating_add(1)).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > limit {
        return Err(BrushPackError::UnsafeArchive(limit_message));
    }
    Ok(bytes)
}

fn read_file_prefix(path: &Path, limit: u64) -> Result<Vec<u8>, BrushPackError> {
    if std::fs::symlink_metadata(path)?.file_type().is_symlink() {
        return Err(BrushPackError::UnsafeArchive(
            "brush source must not be a symlink",
        ));
    }
    let mut bytes = Vec::new();
    File::open(path)?.take(limit).read_to_end(&mut bytes)?;
    Ok(bytes)
}

fn sha256(bytes: &[u8]) -> [u8; 32] {
    Sha256::digest(bytes).into()
}

fn hex(bytes: &[u8]) -> String {
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        let _ = write!(output, "{byte:02x}");
    }
    output
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::builtin_library;

    fn write_bundle(path: &Path, entries: &[(&str, &[u8])]) {
        let file = File::create(path).expect("bundle file");
        let mut writer = ZipWriter::new(file);
        let options = SimpleFileOptions::default().compression_method(CompressionMethod::Deflated);
        for (name, bytes) in entries {
            writer.start_file(*name, options).expect("bundle member");
            writer.write_all(bytes).expect("bundle member bytes");
        }
        writer.finish().expect("bundle finish");
    }

    #[test]
    fn bounded_import_reader_rejects_bytes_past_its_limit() {
        let path = std::env::temp_dir().join(format!(
            "project-ink-bounded-import-{}.bin",
            std::process::id()
        ));
        std::fs::write(&path, b"0123456789").expect("write test source");

        let result = read_bounded_file_with_message(&path, 4, "test import limit");

        assert!(matches!(
            result,
            Err(BrushPackError::UnsafeArchive("test import limit"))
        ));
        std::fs::remove_file(path).expect("cleanup");
    }

    #[test]
    fn bounded_import_hash_rejects_bytes_past_its_limit() {
        let path = std::env::temp_dir().join(format!(
            "project-ink-bounded-hash-{}.bin",
            std::process::id()
        ));
        let source = b"0123456789";
        std::fs::write(&path, source).expect("write test source");

        let bounded = hash_file_with_limit(&path, 4);
        assert!(matches!(
            bounded,
            Err(BrushPackError::UnsafeArchive(
                "source exceeds import size limit"
            ))
        ));
        assert_eq!(
            hash_file_with_limit(&path, source.len() as u64).expect("bounded hash"),
            sha256(source)
        );
        std::fs::remove_file(path).expect("cleanup");
    }

    #[test]
    fn multi_brush_report_resource_budget_rejects_clone_amplification() {
        assert_eq!(
            add_pack_report_resource_bytes(MAX_PACK_REPORT_RESOURCE_BYTES - 1, 1)
                .expect("exact budget boundary"),
            MAX_PACK_REPORT_RESOURCE_BYTES
        );
        assert!(matches!(
            add_pack_report_resource_bytes(MAX_PACK_REPORT_RESOURCE_BYTES, 1),
            Err(BrushPackError::UnsafeArchive(
                "multi-brush report resources exceed limits"
            ))
        ));
        assert!(matches!(
            add_pack_report_resource_bytes(u64::MAX, 1),
            Err(BrushPackError::UnsafeArchive(
                "multi-brush report resource size overflows"
            ))
        ));
    }

    #[test]
    fn native_pack_round_trip_is_lossless() {
        let path =
            std::env::temp_dir().join(format!("project-ink-brush-{}.inkbrush", std::process::id()));
        let preset = builtin_library().remove(0);
        export_inkbrush(&path, &preset).expect("export");
        let mut archive =
            ZipArchive::new(File::open(&path).expect("archive")).expect("valid native archive");
        let preview = archive.by_name("preview.webp").expect("preview entry");
        assert!(preview.size() > 0);
        let report = import_inkbrush(&path).expect("import");
        assert_eq!(report.fidelity, FidelityTier::Lossless);
        assert_eq!(report.preset, Some(preset));
        std::fs::remove_file(path).expect("cleanup");
    }

    #[test]
    fn post_effect_texture_resources_round_trip_and_are_not_dropped() {
        let path = std::env::temp_dir().join(format!(
            "project-ink-post-effect-resource-{}.inkbrush",
            std::process::id()
        ));
        let mut preset = builtin_library().remove(0);
        let data = vec![255, 255, 255, 255];
        let hash = sha256(&data);
        preset.post_effects.push(PostEffect::TexturePass {
            resource_hash: hash,
            scale: 1.0,
            depth: 0.25,
        });
        let resource = ImportedResource {
            name: "post-effect.rgba".into(),
            kind: "texture".into(),
            sha256: hash,
            bytes: 4,
            data,
            width: 1,
            height: 1,
        };
        export_inkbrush_with_resources(&path, &preset, &[resource]).expect("export");
        let report = import_inkbrush(&path).expect("import");
        assert_eq!(report.preset, Some(preset));
        assert_eq!(report.resources.len(), 1);
        assert_eq!(report.resources[0].sha256, hash);
        std::fs::remove_file(path).expect("cleanup");
    }

    #[test]
    fn native_brush_pack_round_trip_preserves_all_members() {
        let path = std::env::temp_dir().join(format!(
            "project-ink-brush-pack-{}.inkbrushpack",
            std::process::id()
        ));
        let library = builtin_library();
        export_inkbrushpack(&path, &library[..2], &[]).expect("pack export");
        let reports = import_inkbrushpack(&path).expect("pack import");
        assert_eq!(reports.len(), 2);
        assert!(reports.iter().all(|report| {
            report.source_format == ExternalBrushFormat::InkBrushPack
                && report.fidelity == FidelityTier::Lossless
                && report.preset.is_some()
        }));
        std::fs::remove_file(path).expect("cleanup");
    }

    #[test]
    fn external_formats_are_never_mislabeled_as_lossless() {
        let path = std::env::temp_dir().join("source.sut");
        std::fs::write(&path, vec![b'x'; MAX_INSPECTION_BYTES + 1]).expect("fixture");
        let inspection = inspect_brush_import(&path).expect("inspection");
        assert_eq!(inspection.source_format, ExternalBrushFormat::SutArchive);
        assert_eq!(inspection.fidelity_hint, FidelityTier::GuidedRecreation);
        let report = guided_recreation_report(&path).expect("report");
        assert_eq!(report.fidelity, FidelityTier::GuidedRecreation);
        assert!(report.preset.is_none());
        std::fs::remove_file(path).expect("cleanup");
    }

    #[test]
    fn external_brush_archive_is_reported_as_guided_recreation() {
        let path = std::env::temp_dir().join(format!(
            "project-ink-external-brush-{}.brush",
            std::process::id()
        ));
        let file = File::create(&path).expect("fixture file");
        let mut archive = ZipWriter::new(file);
        let options = SimpleFileOptions::default().compression_method(CompressionMethod::Stored);
        archive.start_file("Brush.archive", options).expect("entry");
        let source_data: Vec<u8> = (0..=MAX_INSPECTION_BYTES)
            .map(|index| u8::try_from(index % 251).unwrap_or_default())
            .collect();
        archive.write_all(&source_data).expect("brush data");
        let png = tiny_test_png();
        archive.start_file("Shape.png", options).expect("entry");
        archive.write_all(&png).expect("shape data");
        archive.start_file("Grain.png", options).expect("entry");
        archive.write_all(&png).expect("grain data");
        archive.finish().expect("finish fixture");

        let inspection = inspect_brush_import(&path).expect("inspection");
        assert_eq!(inspection.source_format, ExternalBrushFormat::BrushArchive);
        assert_eq!(inspection.fidelity_hint, FidelityTier::GuidedRecreation);
        let report = import_external(&path).expect("guided report");
        assert_eq!(report.source_format, ExternalBrushFormat::BrushArchive);
        assert_eq!(report.fidelity, FidelityTier::GuidedRecreation);
        assert!(report.preset.is_some());
        assert_eq!(report.resources.len(), 2);
        assert!(
            report
                .resources
                .iter()
                .any(|resource| resource.kind == "tip")
        );
        assert!(
            report
                .resources
                .iter()
                .any(|resource| resource.kind == "grain")
        );
        std::fs::remove_file(path).expect("cleanup");
    }

    fn tiny_test_png() -> Vec<u8> {
        use image::ImageEncoder;
        let mut bytes = Vec::new();
        image::codecs::png::PngEncoder::new(&mut bytes)
            .write_image(
                &[0, 0, 0, 255, 255, 255, 255, 255],
                2,
                1,
                image::ExtendedColorType::Rgba8,
            )
            .expect("encode fixture PNG");
        bytes
    }

    #[test]
    fn malformed_png_chunks_are_rejected_without_panicking() {
        let mut png = b"\x89PNG\r\n\x1a\n".to_vec();
        png.extend_from_slice(&[0, 0, 0, 4, b't', b'E', 0, 0, 0, 0, 0, 0]);
        assert!(matches!(
            png_text_payload(&png),
            Err(BrushPackError::UnsafeArchive(_))
        ));
    }

    #[test]
    fn krita_kpp_scalar_conversion_is_bounded_and_reported() {
        let path = std::env::temp_dir().join(format!(
            "project-ink-krita-conversion-{}.kpp",
            std::process::id()
        ));
        let annotation = b"engine=pixel size=18 opacity=65";
        let mut png = b"\x89PNG\r\n\x1a\n".to_vec();
        png.extend_from_slice(
            &u32::try_from(annotation.len())
                .expect("bounded test annotation length")
                .to_be_bytes(),
        );
        png.extend_from_slice(b"tEXt");
        png.extend_from_slice(annotation);
        // The importer only needs bounded chunk framing; CRC validation is
        // intentionally delegated to the image decoder used for resources.
        png.extend_from_slice(&[0, 0, 0, 0]);
        png.extend_from_slice(&[0, 0, 0, 0, b'I', b'E', b'N', b'D', 0, 0, 0, 0]);
        std::fs::write(&path, png).expect("fixture");

        let report = import_krita_kpp(&path).expect("Krita conversion");
        assert_eq!(report.source_format, ExternalBrushFormat::KritaKpp);
        assert!(matches!(
            report.fidelity,
            FidelityTier::High | FidelityTier::Approximate
        ));
        let preset = report.preset.expect("converted preset");
        assert_eq!(preset.metadata.source_format.as_deref(), Some("krita-kpp"));
        assert!(
            report
                .mappings
                .iter()
                .any(|mapping| mapping.source_path == "diameter")
        );
        assert!(
            report
                .warnings
                .iter()
                .any(|warning| warning.code == "resource-approximation")
        );
        std::fs::remove_file(path).expect("cleanup");
    }

    #[test]
    fn krita_bundle_converts_kpp_members_transactionally() {
        let path = std::env::temp_dir().join(format!(
            "project-ink-krita-bundle-{}.bundle",
            std::process::id()
        ));
        let annotation = b"engine=pixel size=12 opacity=80";
        let mut png = b"\x89PNG\r\n\x1a\n".to_vec();
        png.extend_from_slice(
            &u32::try_from(annotation.len())
                .expect("bounded test annotation length")
                .to_be_bytes(),
        );
        png.extend_from_slice(b"tEXt");
        png.extend_from_slice(annotation);
        png.extend_from_slice(&[0, 0, 0, 0]);
        png.extend_from_slice(&[0, 0, 0, 0, b'I', b'E', b'N', b'D', 0, 0, 0, 0]);

        let file = File::create(&path).expect("bundle");
        let mut writer = ZipWriter::new(file);
        writer
            .start_file(
                "brushes/demo.kpp",
                SimpleFileOptions::default().compression_method(CompressionMethod::Deflated),
            )
            .expect("member");
        writer.write_all(&png).expect("member bytes");
        writer
            .finish()
            .expect("bundle finish")
            .sync_all()
            .expect("sync");

        let bundle_bytes = std::fs::read(&path).expect("bundle bytes");
        let reports = import_krita_bundle(&path).expect("bundle conversion");
        assert_eq!(reports.len(), 1);
        assert_eq!(reports[0].source_format, ExternalBrushFormat::KritaBundle);
        assert_eq!(reports[0].source_sha256, sha256(&bundle_bytes));
        assert!(reports[0].preset.is_some());
        assert!(
            reports[0]
                .warnings
                .iter()
                .any(|warning| warning.code == "bundle-member")
        );
        std::fs::remove_file(path).expect("cleanup");
    }

    #[test]
    fn krita_bundle_rejects_traversal_and_case_collisions() {
        let traversal = std::env::temp_dir().join(format!(
            "project-ink-krita-bundle-traversal-{}.bundle",
            std::process::id()
        ));
        write_bundle(&traversal, &[("../escape.kpp", b"not-a-preset")]);
        assert!(matches!(
            import_krita_bundle(&traversal),
            Err(BrushPackError::UnsafeArchive(_))
        ));
        std::fs::remove_file(&traversal).expect("cleanup traversal");

        let collision = std::env::temp_dir().join(format!(
            "project-ink-krita-bundle-collision-{}.bundle",
            std::process::id()
        ));
        write_bundle(
            &collision,
            &[
                ("brushes/demo.kpp", b"first"),
                ("BRUSHES/DEMO.KPP", b"second"),
            ],
        );
        assert!(matches!(
            import_krita_bundle(&collision),
            Err(BrushPackError::UnsafeArchive(_))
        ));
        std::fs::remove_file(collision).expect("cleanup collision");
    }

    #[test]
    fn krita_bundle_requires_a_kpp_member_and_rejects_ratio_bombs() {
        let missing = std::env::temp_dir().join(format!(
            "project-ink-krita-bundle-missing-{}.bundle",
            std::process::id()
        ));
        write_bundle(&missing, &[("brushes/texture.png", b"inert")]);
        assert!(matches!(
            import_krita_bundle(&missing),
            Err(BrushPackError::InvalidManifest(_))
        ));
        std::fs::remove_file(&missing).expect("cleanup missing");

        let ratio_bomb = std::env::temp_dir().join(format!(
            "project-ink-krita-bundle-ratio-{}.bundle",
            std::process::id()
        ));
        let payload = vec![0_u8; 1024 * 1024];
        write_bundle(&ratio_bomb, &[("brushes/large.kpp", &payload)]);
        assert!(matches!(
            import_krita_bundle(&ratio_bomb),
            Err(BrushPackError::UnsafeArchive(_))
        ));
        std::fs::remove_file(ratio_bomb).expect("cleanup ratio bomb");

        let too_many = std::env::temp_dir().join(format!(
            "project-ink-krita-bundle-entry-limit-{}.bundle",
            std::process::id()
        ));
        let file = File::create(&too_many).expect("entry-limit bundle file");
        let mut writer = ZipWriter::new(file);
        let options = SimpleFileOptions::default().compression_method(CompressionMethod::Stored);
        for index in 0..=MAX_ENTRIES {
            writer
                .start_file(format!("members/{index}.bin"), options)
                .expect("entry-limit member");
            writer.write_all(b"x").expect("entry-limit bytes");
        }
        writer.finish().expect("entry-limit finish");
        assert!(matches!(
            import_krita_bundle(&too_many),
            Err(BrushPackError::UnsafeArchive(_))
        ));
        std::fs::remove_file(too_many).expect("cleanup entry limit");
    }

    #[test]
    fn mypaint_json_conversion_maps_scalar_values_without_renderer_claims() {
        let path = std::env::temp_dir().join(format!(
            "project-ink-mypaint-conversion-{}.myb",
            std::process::id()
        ));
        std::fs::write(
            &path,
            br#"{"radius_logarithmic":1.25,"opaque":0.72,"smudge":0.3}"#,
        )
        .expect("fixture");

        let report = import_mypaint_myb(&path).expect("MyPaint conversion");
        assert_eq!(report.source_format, ExternalBrushFormat::MyPaintMyb);
        assert_eq!(report.fidelity, FidelityTier::Approximate);
        let preset = report.preset.expect("converted preset");
        assert_eq!(
            preset.metadata.source_format.as_deref(),
            Some("mypaint-myb")
        );
        assert!(
            report
                .mappings
                .iter()
                .any(|mapping| mapping.source_path == "radius")
        );
        assert!(
            report
                .warnings
                .iter()
                .any(|warning| warning.code == "renderer-substitution")
        );
        std::fs::remove_file(path).expect("cleanup");
    }

    #[test]
    fn duplicate_native_archive_entries_are_rejected_before_decode() {
        let path = std::env::temp_dir().join(format!(
            "project-ink-duplicate-{}.inkbrush",
            std::process::id()
        ));
        let file = File::create(&path).expect("archive file");
        let mut writer = ZipWriter::new(file);
        let options = SimpleFileOptions::default().compression_method(CompressionMethod::Deflated);
        writer.start_file("manifest.json", options).expect("first");
        writer.write_all(b"{}").expect("first bytes");
        writer
            .start_file("MANIFEST.JSON", options)
            .expect("case collision");
        writer.write_all(b"{}").expect("duplicate bytes");
        writer.finish().expect("finish");
        assert!(matches!(
            import_inkbrush(&path),
            Err(BrushPackError::UnsafeArchive(_))
        ));
        std::fs::remove_file(path).expect("cleanup");
    }

    #[test]
    fn explicit_image_tip_import_returns_a_report_and_resource_hash() {
        let path = std::env::temp_dir().join(format!("project-ink-tip-{}.png", std::process::id()));
        let mut encoded = Cursor::new(Vec::new());
        image::DynamicImage::ImageRgba8(image::RgbaImage::from_pixel(
            2,
            3,
            image::Rgba([255, 255, 255, 255]),
        ))
        .write_to(&mut encoded, image::ImageFormat::Png)
        .expect("encode fixture");
        let png = encoded.into_inner();
        std::fs::write(&path, png).expect("fixture");
        let report = import_image_as_brush(&path).expect("image import");
        assert_eq!(report.source_format, ExternalBrushFormat::Image);
        assert_eq!(report.fidelity, FidelityTier::Approximate);
        assert!(report.preset.is_some());
        assert_eq!(report.resources.len(), 1);
        assert_eq!(report.resources[0].data.len(), 2 * 3 * 4);
        assert!(!report.mappings.is_empty());
        std::fs::remove_file(path).expect("cleanup");

        let webp_path =
            std::env::temp_dir().join(format!("project-ink-tip-{}.webp", std::process::id()));
        let webp = webp::Encoder::from_rgba(&[255, 255, 255, 255], 1, 1).encode(90.0);
        std::fs::write(&webp_path, &*webp).expect("webp fixture");
        let webp_report = import_image_as_brush(&webp_path).expect("WebP image import");
        assert_eq!(webp_report.source_format, ExternalBrushFormat::Image);
        assert_eq!(webp_report.resources[0].data.len(), 4);
        std::fs::remove_file(webp_path).expect("cleanup");
    }

    #[test]
    fn image_tip_decoder_enforces_declared_dimensions_before_decode() {
        let mut encoded = Cursor::new(Vec::new());
        image::DynamicImage::ImageRgba8(image::RgbaImage::from_pixel(
            2,
            2,
            image::Rgba([255, 255, 255, 255]),
        ))
        .write_to(&mut encoded, image::ImageFormat::Png)
        .expect("encode fixture");

        let error = decode_image_rgba8(&encoded.into_inner(), 1, 1)
            .expect_err("mismatched dimensions should be stopped by decoder limits");
        assert!(matches!(
            error,
            BrushPackError::UnsafeArchive("image resource cannot be decoded")
        ));
    }

    #[test]
    fn bounded_image_inspection_reads_png_dimensions_and_full_hashes_source() {
        let path = std::env::temp_dir().join(format!(
            "project-ink-inspect-tip-{}.bin",
            std::process::id()
        ));
        let mut png = b"\x89PNG\r\n\x1a\n".to_vec();
        png.extend_from_slice(b"\x00\x00\x00\x0dIHDR");
        png.extend_from_slice(&4_u32.to_be_bytes());
        png.extend_from_slice(&5_u32.to_be_bytes());
        png.extend_from_slice(&[8, 6, 0, 0, 0]);
        png.extend(std::iter::repeat_n(0x5a, 128));
        std::fs::write(&path, &png).expect("fixture");
        let inspection = inspect_brush_import(&path).expect("inspection");
        assert_eq!(inspection.source_format, ExternalBrushFormat::Image);
        assert_eq!(inspection.bytes, png.len() as u64);
        assert_eq!(inspection.source_sha256, sha256(&png));
        std::fs::remove_file(path).expect("cleanup");
    }

    #[test]
    fn native_detection_uses_manifest_structure_not_extension() {
        let path = std::env::temp_dir().join(format!(
            "project-ink-detect-native-{}.kpp",
            std::process::id()
        ));
        let preset = builtin_library().remove(0);
        export_inkbrush(&path, &preset).expect("export");
        let inspection = inspect_brush_import(&path).expect("inspection");
        assert_eq!(inspection.source_format, ExternalBrushFormat::InkBrush);
        assert_eq!(inspection.fidelity_hint, FidelityTier::Lossless);
        std::fs::remove_file(path).expect("cleanup");
    }

    #[test]
    fn malformed_native_magic_is_rejected_before_parser_selection() {
        let path = std::env::temp_dir().join(format!(
            "project-ink-detect-malformed-{}.inkbrush",
            std::process::id()
        ));
        std::fs::write(&path, b"PK\x03\x04not-a-zip").expect("fixture");
        assert!(matches!(
            inspect_brush_import(&path),
            Err(BrushPackError::UnsafeArchive(_) | BrushPackError::Zip(_))
        ));
        std::fs::remove_file(path).expect("cleanup");
    }

    #[test]
    fn webp_dimension_parser_supports_all_bounded_variants() {
        let riff = |kind: &[u8; 4], data: &[u8]| {
            let mut bytes = b"RIFF".to_vec();
            bytes.extend_from_slice(
                &u32::try_from(4 + 8 + data.len())
                    .expect("bounded WebP size")
                    .to_le_bytes(),
            );
            bytes.extend_from_slice(b"WEBP");
            bytes.extend_from_slice(kind);
            bytes.extend_from_slice(
                &u32::try_from(data.len())
                    .expect("bounded chunk size")
                    .to_le_bytes(),
            );
            bytes.extend_from_slice(data);
            bytes
        };

        let mut extended = vec![0; 10];
        extended[4..7].copy_from_slice(&[16, 0, 0]);
        extended[7..10].copy_from_slice(&[8, 0, 0]);
        assert_eq!(
            image_dimensions(&riff(b"VP8X", &extended)).expect("VP8X"),
            (17, 9)
        );

        let mut lossy = vec![0; 10];
        lossy[3..6].copy_from_slice(&[0x9d, 0x01, 0x2a]);
        lossy[6..8].copy_from_slice(&17_u16.to_le_bytes());
        lossy[8..10].copy_from_slice(&9_u16.to_le_bytes());
        assert_eq!(
            image_dimensions(&riff(b"VP8 ", &lossy)).expect("VP8"),
            (17, 9)
        );

        let lossless = [0x2f, 16, 0, 2, 0];
        assert_eq!(
            image_dimensions(&riff(b"VP8L", &lossless)).expect("VP8L"),
            (17, 9)
        );
        assert!(image_dimensions(&riff(b"VP8L", &[0x2f, 0])).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn native_export_refuses_symlink_destinations() {
        use std::os::unix::fs::symlink;
        let root =
            std::env::temp_dir().join(format!("project-ink-brush-symlink-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).expect("root");
        let target = root.join("target.inkbrush");
        std::fs::write(&target, b"keep").expect("target");
        let destination = root.join("output.inkbrush");
        symlink(&target, &destination).expect("symlink");
        let preset = builtin_library().remove(0);
        assert!(matches!(
            export_inkbrush(&destination, &preset),
            Err(BrushPackError::UnsafeArchive(_))
        ));
        assert_eq!(std::fs::read(&target).expect("target bytes"), b"keep");
        std::fs::remove_dir_all(root).expect("cleanup");
    }

    #[cfg(unix)]
    #[test]
    fn external_import_refuses_symlink_sources_before_format_decode() {
        use std::os::unix::fs::symlink;
        let root = std::env::temp_dir().join(format!(
            "project-ink-brush-import-link-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).expect("root");
        let target = root.join("source.kpp");
        std::fs::write(&target, b"not a preset").expect("target");
        let link = root.join("linked.kpp");
        symlink(&target, &link).expect("symlink");
        assert!(matches!(
            import_external(&link),
            Err(BrushPackError::UnsafeArchive(_))
        ));
        std::fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn abr_v1_v2_computed_and_sampled_tips_become_tier_c_reports() {
        use photocraft_psd::abr::{LegacyBrush, LegacyTip};

        let brushes = vec![
            LegacyBrush {
                name: String::new(),
                spacing: 35,
                anti_alias: true,
                tip: LegacyTip::Computed {
                    diameter: 18,
                    hardness: 72,
                    angle: -15,
                    roundness: 60,
                },
            },
            LegacyBrush {
                name: "Sampled Leaf".into(),
                spacing: 28,
                anti_alias: true,
                tip: LegacyTip::Sampled(photocraft_psd::abr::AbrSample {
                    id: String::new(),
                    width: 2,
                    height: 1,
                    depth: 8,
                    data: vec![0, 255],
                }),
            },
        ];
        let bytes = photocraft_psd::abr::write_v12(2, &brushes, true).expect("ABR fixture");
        let reports = convert_photoshop_abr_bytes(&bytes, "source").expect("conversion");
        assert_eq!(reports.len(), 2);
        assert!(
            reports
                .iter()
                .all(|report| report.fidelity == FidelityTier::Approximate)
        );
        let computed = reports[0].preset.as_ref().expect("computed preset");
        assert!(matches!(computed.tip, TipBehavior::Stamp(_)));
        assert!(reports[0].mappings.iter().any(|mapping| {
            mapping.source_path == "abr.spacing" && mapping.target_path == "stroke.spacing"
        }));
        let sampled = &reports[1];
        assert_eq!(sampled.resources.len(), 1);
        assert_eq!(
            sampled.resources[0].data,
            [255, 255, 255, 0, 255, 255, 255, 255]
        );
        assert_eq!(
            sampled
                .preset
                .as_ref()
                .expect("sampled preset")
                .metadata
                .name,
            "Sampled Leaf"
        );
    }

    #[test]
    fn abr_v6_sampled_data_and_settings_map_to_a_local_tip() {
        use photocraft_psd::abr::AbrSample;
        use photocraft_psd::descriptor::{Descriptor, UnicodeString, Value};

        let sample = AbrSample {
            id: "$tip".into(),
            width: 2,
            height: 1,
            depth: 8,
            data: vec![0, 255],
        };
        let sampled_brush = Descriptor::new("sampledBrush")
            .with("sampledData", Value::Text(UnicodeString::new_nul("$tip")))
            .with("Spcn", Value::Double(42.0))
            .with("Dmtr", Value::Double(21.0));
        let preset = Descriptor::new("brushPreset")
            .with("Nm  ", Value::Text(UnicodeString::new_nul("ABR v6 sample")))
            .with("Brsh", Value::Descriptor(sampled_brush));
        let bytes = photocraft_psd::abr::write_v6(1, &[sample], &[], &[preset], true)
            .expect("ABR v6 fixture");
        let reports = convert_photoshop_abr_bytes(&bytes, "source").expect("conversion");
        assert_eq!(reports.len(), 1);
        let report = &reports[0];
        assert_eq!(report.fidelity, FidelityTier::Approximate);
        assert_eq!(
            report.preset.as_ref().expect("preset").metadata.name,
            "ABR v6 sample"
        );
        assert_eq!(report.resources[0].width, 2);
        assert!(report.mappings.iter().any(|mapping| {
            mapping.source_path == "abr.diameter" && mapping.target_path == "tip.diameter_px"
        }));
        let sample_mapping = report
            .mappings
            .iter()
            .find(|mapping| mapping.source_path == "sampledData")
            .expect("sample identity mapping");
        assert!(matches!(
            &sample_mapping.source_value,
            DisplayValue::Text(value) if value.contains("$tip")
        ));
        let sampled_preset = report.preset.as_ref().expect("sampled preset metadata");
        assert!(
            sampled_preset
                .metadata
                .tags
                .iter()
                .any(|tag| tag == "source-file:source")
        );
    }

    #[test]
    fn abr_v6_computed_descriptor_maps_scalars_and_preserves_source_attribution() {
        use photocraft_psd::descriptor::{Descriptor, UnicodeString, Value};

        let computed = Descriptor::new("computedBrush")
            .with("Spcn", Value::Double(42.0))
            .with("Dmtr", Value::Double(21.5))
            .with("Hrdn", Value::Double(70.0))
            .with("Rndn", Value::Double(60.0))
            .with("Angl", Value::Double(-12.0))
            .with("usePressure", Value::Boolean(true));
        let preset = Descriptor::new("brushPreset")
            .with("Nm  ", Value::Text(UnicodeString::new_nul("ABR computed")))
            .with("Brsh", Value::Descriptor(computed))
            .with("customPresetValue", Value::Boolean(true));

        for version in [6_u16, 7, 9, 10] {
            for subversion in [1, 2] {
                let mut bytes = photocraft_psd::abr::write_v6(
                    subversion,
                    &[],
                    &[],
                    std::slice::from_ref(&preset),
                    true,
                )
                .expect("sectioned computed ABR fixture");
                bytes[..2].copy_from_slice(&version.to_be_bytes());
                let reports = convert_photoshop_abr_bytes(&bytes, "Ink test pack")
                    .expect("convert sectioned computed brush");
                assert_eq!(reports.len(), 1, "ABR {version} subversion {subversion}");
                let report = &reports[0];
                assert_eq!(report.fidelity, FidelityTier::Approximate);
                assert_eq!(report.source_format, ExternalBrushFormat::PhotoshopAbr);
                let brush = report.preset.as_ref().expect("computed preset");
                assert_eq!(brush.metadata.name, "ABR computed");
                assert!(
                    brush
                        .metadata
                        .tags
                        .iter()
                        .any(|tag| tag == "source-file:Ink test pack")
                );
                assert!((brush.stroke.spacing - 0.42).abs() < 0.0001);
                let TipBehavior::Stamp(tip) = &brush.tip else {
                    panic!("computed ABR tip must map to a stamp");
                };
                assert!((tip.diameter_px - 21.5).abs() < 0.0001);
                assert!((tip.hardness - 0.7).abs() < 0.0001);
                assert!((tip.roundness - 0.6).abs() < 0.0001);
                assert!((tip.angle_degrees + 12.0).abs() < 0.0001);
                for setting in ["abr.brush.usePressure", "abr.preset.customPresetValue"] {
                    assert!(
                        report
                            .omitted
                            .iter()
                            .any(|omitted| omitted.source_path == setting),
                        "ABR {version} unmapped setting {setting} must be reported"
                    );
                }
            }
        }
    }

    fn assert_imported_pressure_changes_rendered_output(preset: &BrushPresetV2) {
        let compiled = preset.compile().expect("compile imported dynamics");
        let sample = |pressure, x, sequence| ink_input::PointerSample {
            pointer_id: 1,
            flags: ink_input::flags::ACTUAL,
            device_kind: ink_input::DeviceKind::Stylus,
            phase: if sequence == 0 {
                ink_input::Phase::Down
            } else {
                ink_input::Phase::Move
            },
            canvas_x: x,
            canvas_y: 32.0,
            pressure,
            tilt_x: 0.0,
            tilt_y: 0.0,
            azimuth: 0.0,
            twist: 0.0,
            timestamp_ns: u64::from(sequence) * 1_000_000,
            sequence,
        };
        let light = compiled
            .render(&[sample(0, 32.0, 0), sample(64, 48.0, 1)])
            .expect("render light-pressure imported brush");
        let firm = compiled
            .render(&[sample(u16::MAX, 32.0, 0), sample(u16::MAX, 48.0, 1)])
            .expect("render firm-pressure imported brush");
        assert!(light[0].radius_x < firm[0].radius_x);
        assert!(
            light.last().expect("light dabs").opacity < firm.last().expect("firm dabs").opacity
        );
    }

    #[test]
    fn abr_v6_maps_supported_zero_jitter_pressure_size_and_opacity_dynamics() {
        use photocraft_psd::descriptor::{Descriptor, UnicodeString, Value};

        let percent = |value| Value::UnitFloat {
            unit: *b"#Prc",
            value,
        };
        let size_dynamics = Descriptor::new("sizeDynamics")
            .with("bVTy", Value::Integer(2))
            .with("fStp", Value::Integer(0))
            .with("jitter", percent(0.0))
            .with("Mnm ", percent(30.0));
        let opacity_dynamics = Descriptor::new("opacityDynamics")
            .with("bVTy", Value::Integer(2))
            .with("fStp", Value::Integer(0))
            .with("jitter", percent(0.0))
            .with("Mnm ", percent(15.0));
        let brush = Descriptor::new("computedBrush")
            .with("Spcn", Value::Double(25.0))
            .with("Dmtr", Value::Double(18.0))
            .with("Hrdn", Value::Double(90.0))
            .with("Rndn", Value::Double(100.0))
            .with("Angl", Value::Double(0.0))
            .with("useTipDynamics", Value::Boolean(true))
            .with("minimumDiameter", percent(25.0))
            .with("szVr", Value::Descriptor(size_dynamics))
            .with("usePaintDynamics", Value::Boolean(true))
            .with("opVr", Value::Descriptor(opacity_dynamics));
        let preset = Descriptor::new("brushPreset")
            .with("Nm  ", Value::Text(UnicodeString::new_nul("Pressure Ink")))
            .with("Brsh", Value::Descriptor(brush));
        let bytes = photocraft_psd::abr::write_v6(1, &[], &[], &[preset], true)
            .expect("sectioned pressure dynamics fixture");

        let reports = convert_photoshop_abr_bytes(&bytes, "pressure-pack")
            .expect("convert pressure dynamics");
        let report = &reports[0];
        let converted = report.preset.as_ref().expect("converted preset");
        let size = converted
            .dynamics
            .iter()
            .find(|binding| binding.target == ParameterId::Diameter)
            .expect("pressure size binding");
        assert_eq!(size.sensor, SensorId::Pressure);
        assert!((size.base - 0.25).abs() < f32::EPSILON);
        assert!((size.amount - 0.75).abs() < f32::EPSILON);
        assert_eq!(size.combine, CombineOp::Add);
        let opacity = converted
            .dynamics
            .iter()
            .find(|binding| binding.target == ParameterId::Opacity)
            .expect("pressure opacity binding");
        assert_eq!(opacity.sensor, SensorId::Pressure);
        assert!((opacity.base - 0.15).abs() < f32::EPSILON);
        assert!((opacity.amount - 0.85).abs() < f32::EPSILON);
        assert!(report.mappings.iter().any(|mapping| {
            mapping.source_path == "abr.brush.szVr"
                && mapping.target_path == "dynamics.pressure.size"
        }));
        assert!(report.mappings.iter().any(|mapping| {
            mapping.source_path == "abr.brush.opVr"
                && mapping.target_path == "dynamics.pressure.opacity"
        }));
        assert!(
            !report
                .omitted
                .iter()
                .any(|omitted| omitted.source_path == "abr.brush.szVr")
        );
        assert!(
            !report
                .omitted
                .iter()
                .any(|omitted| omitted.source_path == "abr.brush.opVr")
        );

        assert_imported_pressure_changes_rendered_output(converted);
    }

    #[test]
    fn abr_v6_reports_non_pressure_and_jittered_dynamics_without_mapping_them() {
        use photocraft_psd::descriptor::{Descriptor, UnicodeString, Value};

        let percent = |value| Value::UnitFloat {
            unit: *b"#Prc",
            value,
        };
        let size_dynamics = Descriptor::new("sizeDynamics")
            .with("bVTy", Value::Integer(2))
            .with("fStp", Value::Integer(0))
            .with("jitter", percent(10.0))
            .with("Mnm ", percent(20.0));
        let opacity_dynamics = Descriptor::new("opacityDynamics")
            .with("bVTy", Value::Integer(3))
            .with("fStp", Value::Integer(0))
            .with("jitter", percent(0.0))
            .with("Mnm ", percent(20.0));
        let brush = Descriptor::new("computedBrush")
            .with("Spcn", Value::Double(25.0))
            .with("Dmtr", Value::Double(18.0))
            .with("useTipDynamics", Value::Boolean(true))
            .with("szVr", Value::Descriptor(size_dynamics))
            .with("usePaintDynamics", Value::Boolean(true))
            .with("opVr", Value::Descriptor(opacity_dynamics));
        let preset = Descriptor::new("brushPreset")
            .with(
                "Nm  ",
                Value::Text(UnicodeString::new_nul("Unsupported Dynamics")),
            )
            .with("Brsh", Value::Descriptor(brush));
        let bytes = photocraft_psd::abr::write_v6(1, &[], &[], &[preset], true)
            .expect("sectioned unsupported dynamics fixture");

        let reports = convert_photoshop_abr_bytes(&bytes, "pressure-pack")
            .expect("convert supported base tip and report dynamics");
        let report = &reports[0];
        assert!(report.preset.as_ref().expect("preset").dynamics.is_empty());
        for key in ["szVr", "opVr"] {
            assert!(report.omitted.iter().any(|omitted| {
                omitted.source_path == format!("abr.brush.{key}")
                    && omitted.reason.contains("only zero-jitter pen-pressure")
            }));
        }
    }

    #[test]
    fn abr_sectioned_preset_limit_is_reported() {
        use photocraft_psd::descriptor::{Descriptor, UnicodeString, Value};

        let presets = (0..=MAX_ABR_IMPORT_PRESETS)
            .map(|index| {
                Descriptor::new("brushPreset")
                    .with(
                        "Nm  ",
                        Value::Text(UnicodeString::new_nul(&format!("Preset {index}"))),
                    )
                    .with(
                        "Brsh",
                        Value::Descriptor(
                            Descriptor::new("computedBrush")
                                .with("Dmtr", Value::Double(16.0))
                                .with("Hrdn", Value::Double(75.0)),
                        ),
                    )
            })
            .collect::<Vec<_>>();
        let bytes = photocraft_psd::abr::write_v6(1, &[], &[], &presets, true)
            .expect("over-limit preset fixture");
        let reports =
            convert_photoshop_abr_bytes(&bytes, "preset-limit").expect("bounded preset import");
        assert_eq!(reports.len(), MAX_ABR_IMPORT_PRESETS);
        assert!(reports[0].omitted.iter().any(|omitted| {
            omitted.reason.contains("1 additional ABR presets")
                && omitted.reason.contains("256-preset import limit")
        }));
    }

    #[test]
    fn abr_sectioned_standalone_tip_limit_is_reported() {
        use photocraft_psd::abr::AbrSample;

        let samples = (0..=MAX_ABR_IMPORT_PRESETS)
            .map(|index| AbrSample {
                id: format!("sample-{index}"),
                width: 1,
                height: 1,
                depth: 8,
                data: vec![255],
            })
            .collect::<Vec<_>>();
        let bytes = photocraft_psd::abr::write_v6(1, &samples, &[], &[], true)
            .expect("over-limit standalone tip fixture");
        let reports = convert_photoshop_abr_bytes(&bytes, "sample-limit")
            .expect("bounded standalone tip import");
        assert_eq!(reports.len(), MAX_ABR_IMPORT_PRESETS);
        assert!(reports[0].omitted.iter().any(|omitted| {
            omitted.reason.contains("1 additional standalone ABR tips")
                && omitted.reason.contains("256-preset import limit")
        }));
    }

    #[test]
    fn abr_unsupported_settings_are_complete_or_the_preset_is_omitted() {
        use photocraft_psd::descriptor::{Descriptor, Id, UnicodeString, Value};

        let mut oversized_settings = Descriptor::new("computedBrush");
        for index in 0..=MAX_ABR_REPORT_OMISSIONS {
            oversized_settings
                .items
                .push((Id::new(&format!("x{index:03}")), Value::Boolean(true)));
        }
        let oversized_preset = Descriptor::new("brushPreset")
            .with("Nm  ", Value::Text(UnicodeString::new_nul("Many settings")))
            .with("Brsh", Value::Descriptor(oversized_settings));
        let valid = Descriptor::new("brushPreset")
            .with("Nm  ", Value::Text(UnicodeString::new_nul("Valid")))
            .with(
                "Brsh",
                Value::Descriptor(
                    Descriptor::new("computedBrush")
                        .with("Dmtr", Value::Double(16.0))
                        .with("Hrdn", Value::Double(75.0)),
                ),
            );
        let bytes = photocraft_psd::abr::write_v6(1, &[], &[], &[valid, oversized_preset], true)
            .expect("oversized settings fixture");
        let reports = convert_photoshop_abr_bytes(&bytes, "settings-limit")
            .expect("valid preset remains explicitly importable");
        assert_eq!(reports.len(), 1);
        assert!(reports[0].omitted.iter().any(|omitted| {
            omitted.reason.contains("Many settings")
                && omitted
                    .reason
                    .contains("more than 128 unsupported settings")
        }));
    }

    #[test]
    fn abr_rejects_import_when_malformed_records_exceed_report_bound() {
        use photocraft_psd::descriptor::{Descriptor, UnicodeString, Value};

        let malformed_presets = (0..=MAX_ABR_REPORT_OMISSIONS)
            .map(|index| {
                Descriptor::new("brushPreset").with(
                    "Nm  ",
                    Value::Text(UnicodeString::new_nul(&format!("Malformed {index}"))),
                )
            })
            .collect::<Vec<_>>();
        let bytes = photocraft_psd::abr::write_v6(1, &[], &[], &malformed_presets, true)
            .expect("too-many-malformed-preset fixture");
        let error = convert_photoshop_abr_bytes(&bytes, "malformed-limit")
            .expect_err("unreportable partial import must be rejected");
        assert!(matches!(
            error,
            BrushPackError::UnsafeArchive(message)
                if message.contains("complete bounded report")
        ));
    }

    #[test]
    fn abr_rejects_combined_unsupported_and_malformed_report_overflow() {
        use photocraft_psd::descriptor::{Descriptor, Id, UnicodeString, Value};

        let mut max_settings = Descriptor::new("computedBrush");
        for index in 0..MAX_ABR_REPORT_OMISSIONS {
            max_settings
                .items
                .push((Id::new(&format!("m{index:03}")), Value::Boolean(true)));
        }
        let supported = Descriptor::new("brushPreset")
            .with("Nm  ", Value::Text(UnicodeString::new_nul("128 settings")))
            .with("Brsh", Value::Descriptor(max_settings));
        let malformed = Descriptor::new("brushPreset").with(
            "Nm  ",
            Value::Text(UnicodeString::new_nul("One omitted preset")),
        );
        let bytes = photocraft_psd::abr::write_v6(1, &[], &[], &[supported, malformed], true)
            .expect("combined omission bound fixture");
        let error = convert_photoshop_abr_bytes(&bytes, "combined-limit")
            .expect_err("combined details beyond report limit must be rejected");
        assert!(matches!(
            error,
            BrushPackError::UnsafeArchive(message)
                if message.contains("complete per-brush report bound")
        ));
    }

    #[test]
    fn abr_detection_requires_a_supported_header_version_and_abr_extension() {
        let root =
            std::env::temp_dir().join(format!("project-ink-abr-detect-{}", std::process::id()));
        std::fs::create_dir_all(&root).expect("root");
        let abr_path = root.join("sample.abr");
        let abr_bytes = photocraft_psd::abr::write_v12(1, &[], false).expect("ABR header");
        std::fs::write(&abr_path, abr_bytes).expect("ABR file");
        assert_eq!(
            detect_external_format(&abr_path).expect("ABR detection"),
            ExternalBrushFormat::PhotoshopAbr
        );
        let psd_named_abr = root.join("not-abr.abr");
        std::fs::write(&psd_named_abr, b"8BPS\0\x01").expect("PSD-looking bytes");
        assert_eq!(
            detect_external_format(&psd_named_abr).expect("unknown detection"),
            ExternalBrushFormat::Unknown
        );
        std::fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn abr_truncated_records_are_rejected_before_conversion() {
        use photocraft_psd::abr::{LegacyBrush, LegacyTip};

        let brush = LegacyBrush {
            name: "Truncated fixture".into(),
            spacing: 25,
            anti_alias: true,
            tip: LegacyTip::Computed {
                diameter: 20,
                hardness: 70,
                angle: 0,
                roundness: 100,
            },
        };
        let bytes = photocraft_psd::abr::write_v12(2, &[brush], true).expect("ABR fixture");
        for length in [0, 1, 8, bytes.len() / 2, bytes.len() - 1] {
            assert!(
                convert_photoshop_abr_bytes(&bytes[..length], "truncated").is_err(),
                "truncation at byte {length} must be rejected"
            );
        }
    }
}
