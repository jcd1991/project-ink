//! Recovery-safe `.inkproj` persistence.
//!
//! The archive is a directory during editing so individual tiles can be
//! checkpointed without rebuilding a monolithic image. A caller can zip the
//! directory for transport later without changing its internal schema.

#![allow(missing_docs)]
#![allow(
    clippy::missing_errors_doc,
    clippy::missing_panics_doc,
    clippy::must_use_candidate,
    clippy::too_many_lines
)]

use ink_command::decode_command;
use ink_model::{
    ColorSpace, DocumentId, DocumentSpec, Layer, LayerBlendMode, LayerId, LayerKind, Rgba8,
};
use ink_raster::{TILE_SIZE, TileCoord};
use rusqlite::{Connection, OpenFlags, params};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::ffi::OsString;
use std::fmt;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Component, Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// Native extension for Project Ink documents.
pub const EXTENSION: &str = "inkproj";
const FORMAT_VERSION: u32 = 2;
const MIN_READER_VERSION: &str = "0.1.0";
const TILE_BYTES: usize = (TILE_SIZE * TILE_SIZE * 4) as usize;
const MAX_MANIFEST_BYTES: u64 = 64 * 1024;
const MAX_SQLITE_BYTES: u64 = 64 * 1024 * 1024;
const MAX_COMPRESSED_TILE_BYTES: u64 = 1024 * 1024;
const MAX_PROJECT_TILE_BYTES: usize = 768 * 1024 * 1024;
const MAX_COMPRESSED_HISTORY_BYTES: u64 = 64 * 1024 * 1024;
const MAX_DECOMPRESSED_HISTORY_BYTES: usize = 128 * 1024 * 1024;
const MAX_LAYERS: usize = 4096;
const MAX_LAYER_NAME_BYTES: usize = 1024;
const MAX_JOURNAL_ENTRIES: usize = 262_144;
// Vector-stroke commands carry bounded point data; the SQLite file remains
// capped at 64 MiB and the journal entry count is independently bounded.
const MAX_JOURNAL_PAYLOAD_BYTES: usize = 256 * 1_024;
const MAX_HISTORY_STATES: usize = 128;
const MAX_BRUSHES: usize = 1_024;
const MAX_BRUSH_BYTES: usize = 1_024 * 1_024;
const MAX_BRUSH_LIBRARY_BYTES: u64 = 64 * 1_024 * 1_024;
const MAX_RESOURCES: usize = 1_024;
const MAX_RESOURCE_BYTES: usize = 96 * 1_024 * 1_024;
const MAX_RESOURCE_LIBRARY_BYTES: u64 = 256 * 1_024 * 1_024;
const MAX_VECTORS: usize = 100_000;
const MAX_VECTOR_BYTES: usize = 1_024 * 1_024;
const MAX_VECTOR_LIBRARY_BYTES: u64 = 256 * 1_024 * 1_024;
const MAX_COMIC_BYTES: u64 = 64 * 1_024 * 1_024;

/// A complete, immutable document payload suitable for saving or testing.
#[derive(Clone, Debug, PartialEq)]
pub struct ProjectSnapshot {
    pub id: DocumentId,
    pub spec: DocumentSpec,
    pub revision: u64,
    pub layers: Vec<Layer>,
    pub tiles: Vec<TileRecord>,
    pub vectors: Vec<VectorRecord>,
    pub journal: Vec<Vec<u8>>,
    pub history: HistorySnapshot,
    pub brushes: Vec<Vec<u8>>,
    pub resources: Vec<ResourceRecord>,
    /// Optional validated Phase 3 comic structure stored beside the raster
    /// project. The bytes are canonical JSON from `ink-comic`.
    pub comic: Option<Vec<u8>>,
}

/// One page document inside a v2 studio project. The page payload uses the
/// same recovery-safe document schema as a standalone `.inkproj`, but is
/// stored at the validated relative path recorded by the comic metadata.
#[derive(Clone, Debug, PartialEq)]
pub struct StudioPageSnapshot {
    pub page_id: u128,
    pub relative_path: String,
    pub snapshot: ProjectSnapshot,
}

/// Complete portable multi-page project state. The outer project owns comic
/// structure and every page document; callers never need to coordinate
/// independent persistence authorities.
#[derive(Clone, Debug, PartialEq)]
pub struct StudioProjectSnapshot {
    pub comic: Vec<u8>,
    pub pages: Vec<StudioPageSnapshot>,
}

/// A bounded decoded RGBA8 brush resource stored by content hash.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResourceRecord {
    pub hash: [u8; 32],
    pub kind: String,
    pub width: u32,
    pub height: u32,
    pub bytes: Vec<u8>,
}

/// One sparse tile in a layer.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TileRecord {
    pub layer: LayerId,
    pub coordinate: TileCoord,
    pub bytes: Vec<u8>,
}

/// One bounded serialized editable vector stroke. The payload is canonical
/// JSON for `ink_tools::VectorStroke`; storage does not execute it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct VectorRecord {
    pub layer: LayerId,
    pub stroke: u128,
    pub bytes: Vec<u8>,
}

/// Persisted reversible states needed for undo/redo after reopening.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct HistorySnapshot {
    pub undo: Vec<StoredState>,
    pub redo: Vec<StoredState>,
    /// True only when a bounded reader omitted an oversized optional sidecar.
    #[serde(skip)]
    pub truncated_on_load: bool,
}

#[derive(Serialize)]
struct HistorySnapshotView<'a> {
    undo: &'a [StoredState],
    redo: &'a [StoredState],
}

#[derive(Default)]
struct ByteCounter(usize);

impl Write for ByteCounter {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.0 = self.0.saturating_add(bytes.len());
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

#[derive(Debug, PartialEq, Eq)]
struct HistoryWindow {
    undo_start: usize,
    redo_start: usize,
}

/// Keep the newest undo/redo states that fit the reader's decoded JSON bound.
/// Older undo states are discarded first; if undo is empty, oldest redo states
/// are discarded while preserving the next redo operation at the vector tail.
fn bounded_history_window(
    history: &HistorySnapshot,
    max_bytes: usize,
) -> Result<HistoryWindow, StorageError> {
    fn json_len<T: Serialize>(value: &T) -> Result<usize, StorageError> {
        let mut counter = ByteCounter::default();
        serde_json::to_writer(&mut counter, value)?;
        Ok(counter.0)
    }

    let undo_sizes = history
        .undo
        .iter()
        .map(json_len)
        .collect::<Result<Vec<_>, _>>()?;
    let redo_sizes = history
        .redo
        .iter()
        .map(json_len)
        .collect::<Result<Vec<_>, _>>()?;
    let empty_size = json_len(&HistorySnapshot::default())?;
    let mut total = empty_size.saturating_sub(4)
        + undo_sizes.iter().sum::<usize>()
        + redo_sizes.iter().sum::<usize>()
        + history.undo.len().saturating_sub(1)
        + history.redo.len().saturating_sub(1);
    let mut window = HistoryWindow {
        undo_start: 0,
        redo_start: 0,
    };
    while total > max_bytes && window.undo_start < undo_sizes.len() {
        let remaining = undo_sizes.len() - window.undo_start;
        total = total.saturating_sub(undo_sizes[window.undo_start] + usize::from(remaining > 1));
        window.undo_start += 1;
    }
    while total > max_bytes && window.redo_start < redo_sizes.len() {
        let remaining = redo_sizes.len() - window.redo_start;
        total = total.saturating_sub(redo_sizes[window.redo_start] + usize::from(remaining > 1));
        window.redo_start += 1;
    }
    if total > max_bytes {
        return Err(StorageError::LimitExceeded("decoded history size"));
    }
    Ok(window)
}

/// A layer/tile state stored in the history sidecar.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct StoredState {
    pub layers: Vec<Layer>,
    pub tiles: Vec<TileRecord>,
    #[serde(default)]
    pub vectors: Vec<VectorRecord>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct Manifest {
    format_version: u32,
    document_id: String,
    width_px: u32,
    height_px: u32,
    dpi: f32,
    color_space: String,
    background: [u8; 4],
    created_unix_seconds: u64,
    modified_unix_seconds: u64,
    minimum_reader_version: String,
    revision: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct StudioManifest {
    format_version: u32,
    project_id: String,
    page_count: u32,
    minimum_reader_version: String,
    created_unix_seconds: u64,
    modified_unix_seconds: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct ResourceDescriptor {
    hash: String,
    kind: String,
    width: u32,
    height: u32,
}

/// Storage validation and I/O errors.
#[derive(Debug)]
pub enum StorageError {
    WrongExtension,
    MissingManifest,
    RecoveryUnavailable,
    UnsupportedFormat(u32),
    InvalidManifest(String),
    UnsafePath(String),
    LimitExceeded(&'static str),
    Io(std::io::Error),
    Json(serde_json::Error),
    Sqlite(rusqlite::Error),
    Compression(std::io::Error),
}

impl fmt::Display for StorageError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::WrongExtension => {
                f.write_str("Project Ink documents must use the .inkproj extension")
            }
            Self::MissingManifest => f.write_str("document manifest.json is missing"),
            Self::RecoveryUnavailable => f.write_str("no valid recovery sibling was found"),
            Self::UnsupportedFormat(version) => {
                write!(f, "unsupported Project Ink format version {version}")
            }
            Self::InvalidManifest(message) => write!(f, "invalid document manifest: {message}"),
            Self::UnsafePath(message) => write!(f, "unsafe document path: {message}"),
            Self::LimitExceeded(resource) => {
                write!(f, "document exceeds the {resource} safety limit")
            }
            Self::Io(error) | Self::Compression(error) => error.fmt(f),
            Self::Json(error) => error.fmt(f),
            Self::Sqlite(error) => error.fmt(f),
        }
    }
}

impl std::error::Error for StorageError {}
impl From<std::io::Error> for StorageError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}
impl From<serde_json::Error> for StorageError {
    fn from(error: serde_json::Error) -> Self {
        Self::Json(error)
    }
}
impl From<rusqlite::Error> for StorageError {
    fn from(error: rusqlite::Error) -> Self {
        Self::Sqlite(error)
    }
}

/// Validate a destination without modifying it.
pub fn validate_destination(path: &Path) -> Result<(), StorageError> {
    if !path
        .extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| extension.eq_ignore_ascii_case(EXTENSION))
    {
        return Err(StorageError::WrongExtension);
    }
    Ok(())
}

/// Save a complete snapshot to a temporary sibling and atomically publish it.
/// An existing destination is moved to `<name>.inkproj.bak` before replacement;
/// if publication fails, the original is restored.
pub fn save_project(destination: &Path, snapshot: &ProjectSnapshot) -> Result<(), StorageError> {
    save_project_inner(destination, snapshot, None)
}

/// Save a complete v2 multi-page studio project as one atomic directory.
/// Every page is written below `pages/<page_id>` using the ordinary document
/// schema before the outer destination is published.
pub fn save_studio_project(
    destination: &Path,
    snapshot: &StudioProjectSnapshot,
) -> Result<(), StorageError> {
    let project = validate_studio_snapshot(snapshot)?;
    validate_destination(destination)?;
    let parent = destination.parent().unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent)?;
    if destination.exists() {
        let metadata = fs::symlink_metadata(destination)?;
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            return Err(StorageError::UnsafePath(
                "studio save destination must be a real directory".into(),
            ));
        }
    }
    let temp = sibling_path(destination, ".tmp");
    if temp.exists() {
        remove_project_directory(&temp)?;
    }
    fs::create_dir_all(temp.join("pages"))?;
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let manifest = StudioManifest {
        format_version: FORMAT_VERSION,
        project_id: project.id.to_string(),
        page_count: u32::try_from(snapshot.pages.len()).unwrap_or(u32::MAX),
        minimum_reader_version: MIN_READER_VERSION.into(),
        created_unix_seconds: now,
        modified_unix_seconds: now,
    };
    let manifest_bytes = serde_json::to_vec_pretty(&manifest)?;
    if manifest_bytes.len() > usize::try_from(MAX_MANIFEST_BYTES).unwrap_or(usize::MAX) {
        return Err(StorageError::LimitExceeded("studio manifest size"));
    }
    let mut manifest_file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(temp.join("manifest.json"))?;
    manifest_file.write_all(&manifest_bytes)?;
    manifest_file.sync_all()?;
    let comic_bytes = project.to_json().map_err(|error| {
        StorageError::InvalidManifest(format!("invalid comic structure: {error}"))
    })?;
    let mut comic_file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(temp.join("comic.json"))?;
    comic_file.write_all(&comic_bytes)?;
    comic_file.sync_all()?;
    for page in &snapshot.pages {
        let page_path = temp.join(&page.relative_path);
        fs::create_dir_all(&page_path)?;
        write_snapshot(
            &page_path,
            &page.snapshot,
            None,
            MAX_DECOMPRESSED_HISTORY_BYTES,
        )?;
    }
    sync_directory(&temp.join("pages"))?;
    sync_directory(&temp)?;

    let backup = sibling_path(destination, ".bak");
    if backup.exists() {
        remove_project_directory(&backup)?;
    }
    let had_original = destination.exists();
    if had_original {
        fs::rename(destination, &backup)?;
        sync_directory(parent)?;
    }
    match fs::rename(&temp, destination) {
        Ok(()) => {
            sync_directory(parent)?;
            Ok(())
        }
        Err(error) => {
            if had_original {
                let _ = fs::rename(&backup, destination);
                let _ = sync_directory(parent);
            }
            let _ = remove_project_directory(&temp);
            Err(StorageError::Io(error))
        }
    }
}

fn validate_studio_snapshot(
    snapshot: &StudioProjectSnapshot,
) -> Result<ink_comic::ComicProject, StorageError> {
    if snapshot.comic.len() > usize::try_from(MAX_COMIC_BYTES).unwrap_or(usize::MAX) {
        return Err(StorageError::LimitExceeded("studio comic structure size"));
    }
    let project = ink_comic::ComicProject::from_json(&snapshot.comic).map_err(|error| {
        StorageError::InvalidManifest(format!("invalid studio comic structure: {error}"))
    })?;
    if snapshot.pages.len() != project.page_documents.len()
        || snapshot.pages.len() != project.pages.len()
    {
        return Err(StorageError::InvalidManifest(
            "studio page count does not match comic metadata".into(),
        ));
    }
    let mut page_ids = HashSet::with_capacity(snapshot.pages.len());
    for (page, page_ref) in snapshot.pages.iter().zip(&project.page_documents) {
        if page.page_id != page_ref.page_id
            || page.snapshot.id.0 != page_ref.document_id
            || !page_ids.insert(page.page_id)
        {
            return Err(StorageError::InvalidManifest(
                "studio page identity does not match comic metadata".into(),
            ));
        }
        let expected_path = format!("pages/{:032x}", page.page_id);
        if page.relative_path != page_ref.relative_path || page.relative_path != expected_path {
            return Err(StorageError::UnsafePath(
                "studio page path is not canonical".into(),
            ));
        }
        validate_nested_relative_path(&page.relative_path)?;
        let comic_page = project
            .pages
            .iter()
            .find(|candidate| candidate.id == page.page_id)
            .ok_or_else(|| StorageError::InvalidManifest("studio page is missing".into()))?;
        if page.snapshot.spec.width_px != comic_page.spec.width_px
            || page.snapshot.spec.height_px != comic_page.spec.height_px
            || (page.snapshot.spec.dpi - comic_page.spec.dpi).abs() > f32::EPSILON
        {
            return Err(StorageError::InvalidManifest(
                "page document dimensions do not match comic metadata".into(),
            ));
        }
        validate_snapshot(&page.snapshot)?;
    }
    Ok(project)
}

fn validate_nested_relative_path(path: &str) -> Result<(), StorageError> {
    let components = Path::new(path).components().collect::<Vec<_>>();
    if components.len() != 2
        || components[0] != Component::Normal("pages".as_ref())
        || !matches!(components[1], Component::Normal(_))
    {
        return Err(StorageError::UnsafePath(
            "studio page path must remain below pages/".into(),
        ));
    }
    Ok(())
}

/// Open a v2 studio project without modifying its source. Every page is
/// validated before the returned snapshot becomes available.
pub fn load_studio_project(source: &Path) -> Result<StudioProjectSnapshot, StorageError> {
    validate_source(source)?;
    let manifest_bytes = read_project_file_bounded(
        source,
        Path::new("manifest.json"),
        MAX_MANIFEST_BYTES,
        "studio manifest size",
    )?;
    let manifest: StudioManifest = serde_json::from_slice(&manifest_bytes)?;
    if manifest.format_version != FORMAT_VERSION {
        return Err(StorageError::UnsupportedFormat(manifest.format_version));
    }
    validate_minimum_reader_version(&manifest.minimum_reader_version)?;
    let comic = read_project_file_bounded(
        source,
        Path::new("comic.json"),
        MAX_COMIC_BYTES,
        "studio comic structure size",
    )?;
    let project = ink_comic::ComicProject::from_json(&comic).map_err(|error| {
        StorageError::InvalidManifest(format!("invalid studio comic structure: {error}"))
    })?;
    if manifest.project_id != project.id.to_string()
        || usize::try_from(manifest.page_count).unwrap_or(usize::MAX) != project.pages.len()
    {
        return Err(StorageError::InvalidManifest(
            "studio manifest does not match comic metadata".into(),
        ));
    }
    let mut pages = Vec::with_capacity(project.page_documents.len());
    for page_ref in &project.page_documents {
        validate_nested_relative_path(&page_ref.relative_path)?;
        let page_path = source.join(&page_ref.relative_path);
        let page_snapshot = load_nested_project(&page_path)?;
        if page_snapshot.id.0 != page_ref.document_id {
            return Err(StorageError::InvalidManifest(
                "page document ID does not match comic metadata".into(),
            ));
        }
        pages.push(StudioPageSnapshot {
            page_id: page_ref.page_id,
            relative_path: page_ref.relative_path.clone(),
            snapshot: page_snapshot,
        });
    }
    let snapshot = StudioProjectSnapshot { comic, pages };
    validate_studio_snapshot(&snapshot)?;
    Ok(snapshot)
}

fn save_project_inner(
    destination: &Path,
    snapshot: &ProjectSnapshot,
    fail_after: Option<SaveStage>,
) -> Result<(), StorageError> {
    save_project_inner_with_history_limit(
        destination,
        snapshot,
        fail_after,
        MAX_DECOMPRESSED_HISTORY_BYTES,
    )
}

fn save_project_inner_with_history_limit(
    destination: &Path,
    snapshot: &ProjectSnapshot,
    fail_after: Option<SaveStage>,
    history_limit: usize,
) -> Result<(), StorageError> {
    validate_destination(destination)?;
    validate_snapshot(snapshot)?;
    let parent = destination.parent().unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent)?;
    if destination.exists() {
        let metadata = fs::symlink_metadata(destination)?;
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            return Err(StorageError::UnsafePath(
                "save destination must be a real directory".into(),
            ));
        }
    }
    let temp = sibling_path(destination, ".tmp");
    if temp.exists() {
        remove_project_directory(&temp)?;
    }
    if let Err(error) = write_snapshot(&temp, snapshot, fail_after, history_limit) {
        let _ = fs::remove_dir_all(&temp);
        return Err(error);
    }

    let backup = sibling_path(destination, ".bak");
    if backup.exists() {
        remove_project_directory(&backup)?;
    }
    let had_original = destination.exists();
    if had_original {
        fs::rename(destination, &backup)?;
        sync_directory(parent)?;
    }
    #[cfg(test)]
    maybe_crash(CrashPoint::AfterBackupRename);
    match fs::rename(&temp, destination) {
        Ok(()) => {
            sync_directory(parent)?;
            #[cfg(test)]
            maybe_crash(CrashPoint::AfterPublishRename);
            Ok(())
        }
        Err(error) => {
            if had_original {
                let _ = fs::rename(&backup, destination);
                let _ = sync_directory(parent);
            }
            let _ = remove_project_directory(&temp);
            Err(StorageError::Io(error))
        }
    }
}

/// Open a project without modifying it. Corrupt data returns an error and the
/// source remains untouched so the caller can create a recovered copy.
pub fn load_project(source: &Path) -> Result<ProjectSnapshot, StorageError> {
    validate_source(source)?;
    load_project_contents(source)
}

/// Open a page document stored below a v2 studio project. Nested page
/// directories intentionally have no `.inkproj` suffix; they still use the
/// exact same manifest, SQLite, tile, and recovery validation as a root
/// document.
pub fn load_nested_project(source: &Path) -> Result<ProjectSnapshot, StorageError> {
    validate_nested_source(source)?;
    load_project_contents(source)
}

fn load_project_contents(source: &Path) -> Result<ProjectSnapshot, StorageError> {
    load_project_contents_with_history_limit(source, MAX_DECOMPRESSED_HISTORY_BYTES)
}

fn load_project_contents_with_history_limit(
    source: &Path,
    history_limit: usize,
) -> Result<ProjectSnapshot, StorageError> {
    let manifest_relative = Path::new("manifest.json");
    if !source.join(manifest_relative).is_file() {
        return Err(StorageError::MissingManifest);
    }
    let manifest_bytes = read_project_file_bounded(
        source,
        manifest_relative,
        MAX_MANIFEST_BYTES,
        "manifest size",
    )?;
    let manifest: Manifest = serde_json::from_slice(&manifest_bytes)?;
    if manifest.format_version == 0 || manifest.format_version > FORMAT_VERSION {
        return Err(StorageError::UnsupportedFormat(manifest.format_version));
    }
    if manifest.color_space != "sRGB" {
        return Err(StorageError::InvalidManifest(
            "v1 documents must use the sRGB color space".into(),
        ));
    }
    validate_minimum_reader_version(&manifest.minimum_reader_version)?;
    if manifest.created_unix_seconds > manifest.modified_unix_seconds {
        return Err(StorageError::InvalidManifest(
            "created timestamp is later than modified timestamp".into(),
        ));
    }
    let id = DocumentId::from_u128(parse_id(&manifest.document_id)?);
    let background = Rgba8 {
        r: manifest.background[0],
        g: manifest.background[1],
        b: manifest.background[2],
        a: manifest.background[3],
    };
    let spec = DocumentSpec {
        width_px: manifest.width_px,
        height_px: manifest.height_px,
        dpi: manifest.dpi,
        color_space: ColorSpace::Srgb,
        background,
    }
    .validate()
    .map_err(|error| StorageError::InvalidManifest(error.to_string()))?;
    let sqlite_relative = Path::new("document.sqlite");
    validate_project_file(
        source,
        sqlite_relative,
        MAX_SQLITE_BYTES,
        "SQLite metadata size",
    )?;
    let connection = Connection::open_with_flags(
        source.join(sqlite_relative),
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    connection.pragma_update(None, "query_only", true)?;
    let checkpoint_count: i64 =
        connection.query_row("SELECT COUNT(*) FROM checkpoints", [], |row| row.get(0))?;
    if checkpoint_count != 1 {
        return Err(StorageError::InvalidManifest(
            "document must contain exactly one checkpoint".into(),
        ));
    }
    let checkpoint_revision: i64 =
        connection.query_row("SELECT revision FROM checkpoints", [], |row| row.get(0))?;
    let checkpoint_revision = u64::try_from(checkpoint_revision)
        .map_err(|_| StorageError::InvalidManifest("checkpoint revision is out of range".into()))?;
    if checkpoint_revision != manifest.revision {
        return Err(StorageError::InvalidManifest(
            "checkpoint revision does not match the manifest".into(),
        ));
    }
    let mut layer_columns = HashSet::new();
    let mut column_statement = connection.prepare("PRAGMA table_info(layers)")?;
    let column_rows = column_statement.query_map([], |row| row.get::<_, String>(1))?;
    for column in column_rows {
        layer_columns.insert(column?);
    }
    let phase_two_layers = layer_columns.contains("blend_mode")
        && layer_columns.contains("alpha_lock")
        && layer_columns.contains("clipping")
        && layer_columns.contains("reference")
        && layer_columns.contains("label");
    let has_adjustment_column = layer_columns.contains("adjustment");
    let has_group_mode_column = layer_columns.contains("group_mode");
    let mut layers = Vec::new();
    let query = if phase_two_layers && has_adjustment_column && has_group_mode_column {
        "SELECT id, parent, kind, name, opacity, visible, blend_mode, alpha_lock, clipping, reference, label, group_mode, adjustment FROM layers ORDER BY rowid"
    } else if phase_two_layers && has_adjustment_column {
        "SELECT id, parent, kind, name, opacity, visible, blend_mode, alpha_lock, clipping, reference, label, 1, adjustment FROM layers ORDER BY rowid"
    } else if phase_two_layers && has_group_mode_column {
        "SELECT id, parent, kind, name, opacity, visible, blend_mode, alpha_lock, clipping, reference, label, group_mode, NULL FROM layers ORDER BY rowid"
    } else if phase_two_layers {
        "SELECT id, parent, kind, name, opacity, visible, blend_mode, alpha_lock, clipping, reference, label, 1, NULL FROM layers ORDER BY rowid"
    } else {
        "SELECT id, parent, kind, name, opacity, visible, 0, 0, 0, 0, NULL, 1, NULL FROM layers ORDER BY rowid"
    };
    let mut statement = connection.prepare(query)?;
    let rows = statement.query_map([], |row| {
        let id: String = row.get(0)?;
        let parent: Option<String> = row.get(1)?;
        let kind: i64 = row.get(2)?;
        let name: String = row.get(3)?;
        let opacity: i64 = row.get(4)?;
        let visible: i64 = row.get(5)?;
        let blend_mode: i64 = row.get(6)?;
        let alpha_lock: i64 = row.get(7)?;
        let clipping: i64 = row.get(8)?;
        let reference: i64 = row.get(9)?;
        let label: Option<String> = row.get(10)?;
        let group_mode: i64 = row.get(11)?;
        let adjustment: Option<String> = row.get(12)?;
        Ok((
            id, parent, kind, name, opacity, visible, blend_mode, alpha_lock, clipping, reference,
            label, group_mode, adjustment,
        ))
    })?;
    for row in rows {
        if layers.len() >= MAX_LAYERS {
            return Err(StorageError::LimitExceeded("layer count"));
        }
        let (
            id,
            parent,
            kind,
            name,
            opacity,
            visible,
            blend_mode,
            alpha_lock,
            clipping,
            reference,
            label,
            group_mode,
            adjustment,
        ) = row?;
        if name.len() > MAX_LAYER_NAME_BYTES {
            return Err(StorageError::LimitExceeded("layer name length"));
        }
        if !matches!(visible, 0 | 1) {
            return Err(StorageError::InvalidManifest(
                "layer visibility must be zero or one".into(),
            ));
        }
        if !matches!(alpha_lock, 0 | 1) || !matches!(clipping, 0 | 1) || !matches!(reference, 0 | 1)
        {
            return Err(StorageError::InvalidManifest(
                "layer flags must be zero or one".into(),
            ));
        }
        if !matches!(group_mode, 0 | 1) {
            return Err(StorageError::InvalidManifest(
                "layer group mode must be zero or one".into(),
            ));
        }
        layers.push(Layer {
            id: LayerId::from_u128(parse_id(&id)?),
            parent: parent
                .map(|value| parse_id(&value).map(LayerId::from_u128))
                .transpose()?,
            // Legacy SQLite rows are read in their persisted row order. The
            // engine canonicalizes sibling ranks after loading, so this
            // placeholder is intentionally overwritten there.
            order: 0,
            kind: decode_layer_kind(kind)?,
            name,
            opacity: u16::try_from(opacity).map_err(|_| {
                StorageError::InvalidManifest("layer opacity is out of range".into())
            })?,
            visible: visible != 0,
            blend_mode: decode_layer_blend_mode(blend_mode)?,
            group_mode: decode_layer_group_mode(group_mode)?,
            alpha_lock: alpha_lock != 0,
            clipping: clipping != 0,
            reference: reference != 0,
            label: label
                .filter(|value| value != "null")
                .map(|value| serde_json::from_str::<[u8; 4]>(&value))
                .transpose()?
                .map(|value| Rgba8 {
                    r: value[0],
                    g: value[1],
                    b: value[2],
                    a: value[3],
                }),
            adjustment: adjustment
                .filter(|value| value != "null")
                .map(|value| {
                    serde_json::from_str::<Option<ink_model::LayerAdjustment>>(&value).map_err(
                        |error| {
                            StorageError::InvalidManifest(format!(
                                "layer adjustment is invalid: {error}"
                            ))
                        },
                    )
                })
                .transpose()?
                .flatten()
                .map(|adjustment| {
                    adjustment
                        .validate()
                        .map_err(|error| StorageError::InvalidManifest(error.to_string()))
                })
                .transpose()?,
        });
    }
    if layers.is_empty() {
        return Err(StorageError::InvalidManifest(
            "document has no layers".into(),
        ));
    }
    let layer_ids: HashSet<_> = layers.iter().map(|layer| layer.id).collect();
    if layer_ids.len() != layers.len() {
        return Err(StorageError::InvalidManifest(
            "layer IDs are not unique".into(),
        ));
    }
    let mut tiles = Vec::new();
    let mut tile_keys = HashSet::new();
    let mut total_tile_bytes = 0usize;
    let mut tile_statement =
        connection.prepare("SELECT layer_id, x, y, path FROM tiles ORDER BY layer_id, y, x")?;
    let tile_rows = tile_statement.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, i64>(1)?,
            row.get::<_, i64>(2)?,
            row.get::<_, String>(3)?,
        ))
    })?;
    for row in tile_rows {
        let (layer_id, x, y, relative_path) = row?;
        let layer = LayerId::from_u128(parse_id(&layer_id)?);
        if !layer_ids.contains(&layer) {
            return Err(StorageError::InvalidManifest(
                "tile references an unknown layer".into(),
            ));
        }
        let x = i32::try_from(x)
            .map_err(|_| StorageError::InvalidManifest("tile x is out of range".into()))?;
        let y = i32::try_from(y)
            .map_err(|_| StorageError::InvalidManifest("tile y is out of range".into()))?;
        validate_tile_coordinate(spec, TileCoord { x, y })?;
        if !tile_keys.insert((layer, x, y)) {
            return Err(StorageError::InvalidManifest(
                "document contains duplicate tile coordinates".into(),
            ));
        }
        total_tile_bytes = total_tile_bytes
            .checked_add(TILE_BYTES)
            .ok_or(StorageError::LimitExceeded("decoded tile bytes"))?;
        if total_tile_bytes > MAX_PROJECT_TILE_BYTES {
            return Err(StorageError::LimitExceeded("decoded tile bytes"));
        }
        let expected_path = format!("tiles/{layer}/{x}_{y}.tile.zst");
        if relative_path != expected_path {
            return Err(StorageError::UnsafePath(
                "tile path does not match its layer and coordinates".into(),
            ));
        }
        let encoded = read_project_file_bounded(
            source,
            Path::new(&expected_path),
            MAX_COMPRESSED_TILE_BYTES,
            "compressed tile size",
        )?;
        let bytes = decode_zstd_bounded(&encoded, TILE_BYTES, "decoded tile size")?;
        if bytes.len() != TILE_BYTES {
            return Err(StorageError::InvalidManifest(
                "tile byte length is not 256x256 BGRA8".into(),
            ));
        }
        tiles.push(TileRecord {
            layer,
            coordinate: TileCoord { x, y },
            bytes,
        });
    }
    let vectors_relative = Path::new("vectors.json.zst");
    let vectors = if source.join(vectors_relative).is_file() {
        let encoded = read_project_file_bounded(
            source,
            vectors_relative,
            MAX_COMPRESSED_HISTORY_BYTES,
            "compressed vector library size",
        )?;
        let decoded = decode_zstd_bounded(
            &encoded,
            usize::try_from(MAX_VECTOR_LIBRARY_BYTES).unwrap_or(usize::MAX),
            "decoded vector library size",
        )?;
        let vectors: Vec<VectorRecord> = serde_json::from_slice(&decoded)?;
        validate_vectors(&vectors, &layer_ids)?;
        vectors
    } else {
        Vec::new()
    };
    let mut journal = Vec::new();
    let mut journal_statement =
        connection.prepare("SELECT sequence, payload FROM command_journal ORDER BY sequence")?;
    let journal_rows = journal_statement.query_map([], |row| {
        Ok((row.get::<_, i64>(0)?, row.get::<_, Vec<u8>>(1)?))
    })?;
    for row in journal_rows {
        if journal.len() >= MAX_JOURNAL_ENTRIES {
            return Err(StorageError::LimitExceeded("command journal length"));
        }
        let (sequence, payload) = row?;
        if sequence != i64::try_from(journal.len()).unwrap_or(i64::MAX) {
            return Err(StorageError::InvalidManifest(
                "command journal sequence is not contiguous".into(),
            ));
        }
        if payload.len() > MAX_JOURNAL_PAYLOAD_BYTES {
            return Err(StorageError::LimitExceeded("command journal payload size"));
        }
        decode_command(&payload).map_err(|error| {
            StorageError::InvalidManifest(format!("invalid command journal: {error}"))
        })?;
        journal.push(payload);
    }
    let history_relative = Path::new("history.json.zst");
    let history = if source.join(history_relative).is_file() {
        let encoded = read_project_file_bounded(
            source,
            history_relative,
            MAX_COMPRESSED_HISTORY_BYTES,
            "compressed history size",
        )?;
        match decode_zstd_bounded(&encoded, history_limit, "decoded history size") {
            Ok(decoded) => {
                let history: HistorySnapshot = serde_json::from_slice(&decoded)?;
                validate_history(&history, spec)?;
                history
            }
            // The editable artwork checkpoint is independent of reversible
            // snapshots. Older writers could create a history sidecar larger
            // than the reader's memory budget, so retain the document and
            // discard only that optional undo/redo sidecar.
            Err(StorageError::LimitExceeded("decoded history size")) => HistorySnapshot {
                truncated_on_load: true,
                ..HistorySnapshot::default()
            },
            Err(error) => return Err(error),
        }
    } else {
        HistorySnapshot::default()
    };
    let brushes_relative = Path::new("brushes.json.zst");
    let brushes = if source.join(brushes_relative).is_file() {
        let encoded = read_project_file_bounded(
            source,
            brushes_relative,
            MAX_COMPRESSED_HISTORY_BYTES,
            "compressed brush library size",
        )?;
        let decoded = decode_zstd_bounded(
            &encoded,
            usize::try_from(MAX_BRUSH_LIBRARY_BYTES).unwrap_or(usize::MAX),
            "decoded brush library size",
        )?;
        let brushes: Vec<Vec<u8>> = serde_json::from_slice(&decoded)?;
        if brushes.len() > MAX_BRUSHES || brushes.iter().any(|brush| brush.len() > MAX_BRUSH_BYTES)
        {
            return Err(StorageError::LimitExceeded("brush library"));
        }
        brushes
    } else {
        Vec::new()
    };
    let resources_relative = Path::new("resources.json.zst");
    let resources = if source.join(resources_relative).is_file() {
        let encoded = read_project_file_bounded(
            source,
            resources_relative,
            MAX_COMPRESSED_HISTORY_BYTES,
            "compressed resource metadata size",
        )?;
        let decoded = decode_zstd_bounded(
            &encoded,
            usize::try_from(MAX_RESOURCE_LIBRARY_BYTES).unwrap_or(usize::MAX),
            "decoded resource metadata size",
        )?;
        let descriptors: Vec<ResourceDescriptor> = serde_json::from_slice(&decoded)?;
        if descriptors.len() > MAX_RESOURCES {
            return Err(StorageError::LimitExceeded("resource count"));
        }
        let mut resources = Vec::with_capacity(descriptors.len());
        let mut hashes = HashSet::with_capacity(descriptors.len());
        for descriptor in descriptors {
            let hash = parse_hash_hex(&descriptor.hash)?;
            if !hashes.insert(hash) {
                return Err(StorageError::InvalidManifest(
                    "resource hashes are not unique".into(),
                ));
            }
            let expected = rgba8_bytes(descriptor.width, descriptor.height)?;
            if expected > MAX_RESOURCE_BYTES {
                return Err(StorageError::LimitExceeded("resource size"));
            }
            let relative = PathBuf::from(format!("resources/{}.rgba", descriptor.hash));
            let bytes = read_project_file_bounded(
                source,
                &relative,
                u64::try_from(MAX_RESOURCE_BYTES).unwrap_or(u64::MAX),
                "resource payload size",
            )?;
            if bytes.len() != expected || sha256_bytes(&bytes) != hash {
                return Err(StorageError::InvalidManifest(
                    "resource payload does not match its descriptor".into(),
                ));
            }
            resources.push(ResourceRecord {
                hash,
                kind: descriptor.kind,
                width: descriptor.width,
                height: descriptor.height,
                bytes,
            });
        }
        resources
    } else {
        Vec::new()
    };
    let comic = if source.join("comic.json").is_file() {
        let bytes = read_project_file_bounded(
            source,
            Path::new("comic.json"),
            MAX_COMIC_BYTES,
            "comic structure size",
        )?;
        ink_comic::ComicProject::from_json(&bytes).map_err(|error| {
            StorageError::InvalidManifest(format!("invalid comic structure: {error}"))
        })?;
        Some(bytes)
    } else {
        None
    };
    Ok(ProjectSnapshot {
        id,
        spec,
        revision: manifest.revision,
        layers,
        tiles,
        vectors,
        journal,
        history,
        brushes,
        resources,
        comic,
    })
}

/// Recover a corrupted source from the last atomic backup into a new sibling.
/// The original source is never modified.
pub fn recover_project(source: &Path, recovered_destination: &Path) -> Result<(), StorageError> {
    validate_destination(source)?;
    validate_destination(recovered_destination)?;
    let backup = sibling_path(source, ".bak");
    if !backup.exists() {
        return Err(StorageError::RecoveryUnavailable);
    }
    let snapshot = load_project(&backup).map_err(|_| StorageError::RecoveryUnavailable)?;
    save_project(recovered_destination, &snapshot)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum SaveStage {
    Manifest,
    Sqlite,
    Tiles,
    History,
}

#[cfg(test)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum CrashPoint {
    Manifest,
    Sqlite,
    Tiles,
    History,
    AfterBackupRename,
    AfterPublishRename,
}

#[cfg(test)]
impl CrashPoint {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Manifest => "manifest",
            Self::Sqlite => "sqlite",
            Self::Tiles => "tiles",
            Self::History => "history",
            Self::AfterBackupRename => "after-backup-rename",
            Self::AfterPublishRename => "after-publish-rename",
        }
    }
}

fn write_snapshot(
    destination: &Path,
    snapshot: &ProjectSnapshot,
    fail_after: Option<SaveStage>,
    history_limit: usize,
) -> Result<(), StorageError> {
    fs::create_dir_all(destination.join("tiles"))?;
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let manifest = Manifest {
        format_version: FORMAT_VERSION,
        document_id: snapshot.id.to_string(),
        width_px: snapshot.spec.width_px,
        height_px: snapshot.spec.height_px,
        dpi: snapshot.spec.dpi,
        color_space: "sRGB".into(),
        background: [
            snapshot.spec.background.r,
            snapshot.spec.background.g,
            snapshot.spec.background.b,
            snapshot.spec.background.a,
        ],
        created_unix_seconds: now,
        modified_unix_seconds: now,
        minimum_reader_version: MIN_READER_VERSION.into(),
        revision: snapshot.revision,
    };
    let manifest_bytes = serde_json::to_vec_pretty(&manifest)?;
    if manifest_bytes.len() > usize::try_from(MAX_MANIFEST_BYTES).unwrap_or(usize::MAX) {
        return Err(StorageError::LimitExceeded("manifest size"));
    }
    let mut manifest_file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(destination.join("manifest.json"))?;
    manifest_file.write_all(&manifest_bytes)?;
    manifest_file.sync_all()?;
    if let Some(comic) = &snapshot.comic {
        if u64::try_from(comic.len()).unwrap_or(u64::MAX) > MAX_COMIC_BYTES {
            return Err(StorageError::LimitExceeded("comic structure size"));
        }
        let canonical_comic = ink_comic::ComicProject::from_json(comic)
            .and_then(|project| project.to_json())
            .map_err(|error| {
                StorageError::InvalidManifest(format!("invalid comic structure: {error}"))
            })?;
        let mut comic_file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(destination.join("comic.json"))?;
        comic_file.write_all(&canonical_comic)?;
        comic_file.sync_all()?;
    }
    maybe_fail(fail_after, SaveStage::Manifest)?;
    #[cfg(test)]
    maybe_crash(CrashPoint::Manifest);

    let connection = Connection::open(destination.join("document.sqlite"))?;
    connection.pragma_update(None, "journal_mode", "WAL")?;
    connection.execute_batch("BEGIN IMMEDIATE; CREATE TABLE layers(id TEXT PRIMARY KEY, parent TEXT, kind INTEGER NOT NULL, name TEXT NOT NULL, opacity INTEGER NOT NULL, visible INTEGER NOT NULL, blend_mode INTEGER NOT NULL DEFAULT 0, group_mode INTEGER NOT NULL DEFAULT 0, alpha_lock INTEGER NOT NULL DEFAULT 0, clipping INTEGER NOT NULL DEFAULT 0, reference INTEGER NOT NULL DEFAULT 0, label TEXT, adjustment TEXT); CREATE TABLE tiles(layer_id TEXT NOT NULL, x INTEGER NOT NULL, y INTEGER NOT NULL, path TEXT NOT NULL, PRIMARY KEY(layer_id, x, y)); CREATE TABLE checkpoints(revision INTEGER NOT NULL); CREATE TABLE command_journal(sequence INTEGER PRIMARY KEY, payload BLOB NOT NULL); COMMIT;")?;
    let transaction = connection.unchecked_transaction()?;
    for layer in &snapshot.layers {
        let label = serde_json::to_string(&layer.label)?;
        let adjustment = serde_json::to_string(&layer.adjustment)?;
        transaction.execute("INSERT INTO layers(id, parent, kind, name, opacity, visible, blend_mode, group_mode, alpha_lock, clipping, reference, label, adjustment) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)", params![layer.id.to_string(), layer.parent.map(|id| id.to_string()), encode_layer_kind(layer.kind), layer.name, i64::from(layer.opacity), i64::from(u8::from(layer.visible)), encode_layer_blend_mode(layer.blend_mode), encode_layer_group_mode(layer.group_mode), i64::from(u8::from(layer.alpha_lock)), i64::from(u8::from(layer.clipping)), i64::from(u8::from(layer.reference)), label, adjustment])?;
    }
    transaction.execute(
        "INSERT INTO checkpoints(revision) VALUES(?1)",
        params![snapshot.revision],
    )?;
    for (sequence, payload) in snapshot.journal.iter().enumerate() {
        transaction.execute(
            "INSERT INTO command_journal(sequence, payload) VALUES(?1, ?2)",
            params![
                i64::try_from(sequence)
                    .map_err(|_| StorageError::InvalidManifest("journal is too large".into()))?,
                payload
            ],
        )?;
    }
    for tile in &snapshot.tiles {
        if tile.bytes.len() != TILE_BYTES {
            return Err(StorageError::InvalidManifest(
                "tile byte length is not 256x256 BGRA8".into(),
            ));
        }
        let relative_path = format!(
            "tiles/{}/{}_{}.tile.zst",
            tile.layer, tile.coordinate.x, tile.coordinate.y
        );
        let absolute_path = destination.join(&relative_path);
        if let Some(parent) = absolute_path.parent() {
            fs::create_dir_all(parent)?;
        }
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&absolute_path)?;
        let encoded = zstd::stream::encode_all(tile.bytes.as_slice(), 3)
            .map_err(StorageError::Compression)?;
        file.write_all(&encoded)?;
        file.sync_all()?;
        transaction.execute(
            "INSERT INTO tiles(layer_id, x, y, path) VALUES(?1, ?2, ?3, ?4)",
            params![
                tile.layer.to_string(),
                tile.coordinate.x,
                tile.coordinate.y,
                relative_path
            ],
        )?;
    }
    for layer in &snapshot.layers {
        let layer_tiles = destination.join("tiles").join(layer.id.to_string());
        if layer_tiles.is_dir() {
            sync_directory(&layer_tiles)?;
        }
    }
    sync_directory(&destination.join("tiles"))?;
    maybe_fail(fail_after, SaveStage::Tiles)?;
    #[cfg(test)]
    maybe_crash(CrashPoint::Tiles);
    transaction.commit()?;
    connection.execute_batch("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;")?;
    drop(connection);
    let sqlite_file = File::open(destination.join("document.sqlite"))?;
    sqlite_file.sync_all()?;
    maybe_fail(fail_after, SaveStage::Sqlite)?;
    #[cfg(test)]
    maybe_crash(CrashPoint::Sqlite);
    let history_window = bounded_history_window(&snapshot.history, history_limit)?;
    let history_json = serde_json::to_vec(&HistorySnapshotView {
        undo: &snapshot.history.undo[history_window.undo_start..],
        redo: &snapshot.history.redo[history_window.redo_start..],
    })?;
    let history_zstd =
        zstd::stream::encode_all(history_json.as_slice(), 3).map_err(StorageError::Compression)?;
    if history_zstd.len() > usize::try_from(MAX_COMPRESSED_HISTORY_BYTES).unwrap_or(usize::MAX) {
        return Err(StorageError::LimitExceeded("compressed history size"));
    }
    let mut history_file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(destination.join("history.json.zst"))?;
    history_file.write_all(&history_zstd)?;
    history_file.sync_all()?;
    maybe_fail(fail_after, SaveStage::History)?;
    #[cfg(test)]
    maybe_crash(CrashPoint::History);
    let vector_json = serde_json::to_vec(&snapshot.vectors)?;
    if u64::try_from(vector_json.len()).unwrap_or(u64::MAX) > MAX_VECTOR_LIBRARY_BYTES {
        return Err(StorageError::LimitExceeded("vector library"));
    }
    let vector_zstd =
        zstd::stream::encode_all(vector_json.as_slice(), 3).map_err(StorageError::Compression)?;
    if vector_zstd.len() > usize::try_from(MAX_COMPRESSED_HISTORY_BYTES).unwrap_or(usize::MAX) {
        return Err(StorageError::LimitExceeded(
            "compressed vector library size",
        ));
    }
    let mut vector_file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(destination.join("vectors.json.zst"))?;
    vector_file.write_all(&vector_zstd)?;
    vector_file.sync_all()?;
    if snapshot.brushes.len() > MAX_BRUSHES
        || snapshot
            .brushes
            .iter()
            .any(|brush| brush.len() > MAX_BRUSH_BYTES)
    {
        return Err(StorageError::LimitExceeded("brush library"));
    }
    let brush_json = serde_json::to_vec(&snapshot.brushes)?;
    if u64::try_from(brush_json.len()).unwrap_or(u64::MAX) > MAX_BRUSH_LIBRARY_BYTES {
        return Err(StorageError::LimitExceeded("brush library"));
    }
    let brush_zstd =
        zstd::stream::encode_all(brush_json.as_slice(), 3).map_err(StorageError::Compression)?;
    if brush_zstd.len() > usize::try_from(MAX_COMPRESSED_HISTORY_BYTES).unwrap_or(usize::MAX) {
        return Err(StorageError::LimitExceeded("compressed brush library size"));
    }
    let mut brush_file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(destination.join("brushes.json.zst"))?;
    brush_file.write_all(&brush_zstd)?;
    brush_file.sync_all()?;
    if !snapshot.resources.is_empty() {
        fs::create_dir_all(destination.join("resources"))?;
        let mut descriptors = Vec::with_capacity(snapshot.resources.len());
        for resource in &snapshot.resources {
            validate_resource_record(resource)?;
            let hash = hex_hash(&resource.hash);
            let relative_path = format!("resources/{hash}.rgba");
            let mut file = OpenOptions::new()
                .create_new(true)
                .write(true)
                .open(destination.join(&relative_path))?;
            file.write_all(&resource.bytes)?;
            file.sync_all()?;
            descriptors.push(ResourceDescriptor {
                hash,
                kind: resource.kind.clone(),
                width: resource.width,
                height: resource.height,
            });
        }
        descriptors.sort_by(|left, right| left.hash.cmp(&right.hash));
        let resource_json = serde_json::to_vec(&descriptors)?;
        if u64::try_from(resource_json.len()).unwrap_or(u64::MAX) > MAX_RESOURCE_LIBRARY_BYTES {
            return Err(StorageError::LimitExceeded("resource metadata"));
        }
        let resource_zstd = zstd::stream::encode_all(resource_json.as_slice(), 3)
            .map_err(StorageError::Compression)?;
        if resource_zstd.len() > usize::try_from(MAX_COMPRESSED_HISTORY_BYTES).unwrap_or(usize::MAX)
        {
            return Err(StorageError::LimitExceeded(
                "compressed resource metadata size",
            ));
        }
        let mut resource_file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(destination.join("resources.json.zst"))?;
        resource_file.write_all(&resource_zstd)?;
        resource_file.sync_all()?;
        sync_directory(&destination.join("resources"))?;
    }
    sync_directory(destination)?;
    Ok(())
}

fn maybe_fail(fail_after: Option<SaveStage>, stage: SaveStage) -> Result<(), StorageError> {
    if fail_after == Some(stage) {
        return Err(StorageError::Io(std::io::Error::other(format!(
            "injected save failure after {stage:?}"
        ))));
    }
    Ok(())
}

fn validate_snapshot(snapshot: &ProjectSnapshot) -> Result<(), StorageError> {
    snapshot
        .spec
        .validate()
        .map_err(|error| StorageError::InvalidManifest(error.to_string()))?;
    validate_stored_state(
        &StoredState {
            layers: snapshot.layers.clone(),
            tiles: snapshot.tiles.clone(),
            vectors: snapshot.vectors.clone(),
        },
        snapshot.spec,
    )?;
    if let Some(comic) = &snapshot.comic {
        if u64::try_from(comic.len()).unwrap_or(u64::MAX) > MAX_COMIC_BYTES {
            return Err(StorageError::LimitExceeded("comic structure size"));
        }
        ink_comic::ComicProject::from_json(comic).map_err(|error| {
            StorageError::InvalidManifest(format!("invalid comic structure: {error}"))
        })?;
    }
    if snapshot.journal.len() > MAX_JOURNAL_ENTRIES {
        return Err(StorageError::LimitExceeded("command journal length"));
    }
    for payload in &snapshot.journal {
        if payload.len() > MAX_JOURNAL_PAYLOAD_BYTES {
            return Err(StorageError::LimitExceeded("command journal payload size"));
        }
        decode_command(payload).map_err(|error| {
            StorageError::InvalidManifest(format!("invalid command journal: {error}"))
        })?;
    }
    if snapshot.brushes.len() > MAX_BRUSHES
        || snapshot
            .brushes
            .iter()
            .any(|brush| brush.len() > MAX_BRUSH_BYTES)
    {
        return Err(StorageError::LimitExceeded("brush library"));
    }
    let brush_json = serde_json::to_vec(&snapshot.brushes)?;
    if u64::try_from(brush_json.len()).unwrap_or(u64::MAX) > MAX_BRUSH_LIBRARY_BYTES {
        return Err(StorageError::LimitExceeded("brush library"));
    }
    if snapshot.resources.len() > MAX_RESOURCES {
        return Err(StorageError::LimitExceeded("resource count"));
    }
    let mut resource_bytes = 0_u64;
    let mut resource_hashes = HashSet::with_capacity(snapshot.resources.len());
    for resource in &snapshot.resources {
        validate_resource_record(resource)?;
        if !resource_hashes.insert(resource.hash) {
            return Err(StorageError::InvalidManifest(
                "resource hashes are not unique".into(),
            ));
        }
        resource_bytes = resource_bytes
            .checked_add(u64::try_from(resource.bytes.len()).unwrap_or(u64::MAX))
            .ok_or(StorageError::LimitExceeded("resource library"))?;
        if resource_bytes > MAX_RESOURCE_LIBRARY_BYTES {
            return Err(StorageError::LimitExceeded("resource library"));
        }
    }
    validate_history(&snapshot.history, snapshot.spec)
}

fn validate_resource_record(resource: &ResourceRecord) -> Result<(), StorageError> {
    let expected = rgba8_bytes(resource.width, resource.height)?;
    if expected > MAX_RESOURCE_BYTES || resource.bytes.len() != expected {
        return Err(StorageError::LimitExceeded("resource payload"));
    }
    if resource.kind.is_empty() || resource.kind.len() > 64 {
        return Err(StorageError::InvalidManifest(
            "resource kind is outside limits".into(),
        ));
    }
    if sha256_bytes(&resource.bytes) != resource.hash {
        return Err(StorageError::InvalidManifest(
            "resource hash does not match payload".into(),
        ));
    }
    Ok(())
}

fn rgba8_bytes(width: u32, height: u32) -> Result<usize, StorageError> {
    let bytes = u64::from(width)
        .checked_mul(u64::from(height))
        .and_then(|value| value.checked_mul(4))
        .ok_or(StorageError::LimitExceeded("resource payload"))?;
    usize::try_from(bytes).map_err(|_| StorageError::LimitExceeded("resource payload"))
}

fn sha256_bytes(bytes: &[u8]) -> [u8; 32] {
    use sha2::{Digest, Sha256};
    Sha256::digest(bytes).into()
}

fn hex_hash(hash: &[u8; 32]) -> String {
    use std::fmt::Write;
    let mut value = String::with_capacity(hash.len() * 2);
    for byte in hash {
        write!(&mut value, "{byte:02x}").expect("writing to String cannot fail");
    }
    value
}

fn parse_hash_hex(value: &str) -> Result<[u8; 32], StorageError> {
    if value.len() != 64 {
        return Err(StorageError::InvalidManifest(
            "resource hash must contain 64 hexadecimal characters".into(),
        ));
    }
    let mut hash = [0_u8; 32];
    let (pairs, remainder) = value.as_bytes().as_chunks::<2>();
    debug_assert!(remainder.is_empty());
    for (index, pair) in pairs.iter().enumerate() {
        let high = hex_nibble(pair[0]).ok_or_else(|| {
            StorageError::InvalidManifest("resource hash is not hexadecimal".into())
        })?;
        let low = hex_nibble(pair[1]).ok_or_else(|| {
            StorageError::InvalidManifest("resource hash is not hexadecimal".into())
        })?;
        hash[index] = (high << 4) | low;
    }
    Ok(hash)
}

fn hex_nibble(value: u8) -> Option<u8> {
    match value {
        b'0'..=b'9' => Some(value - b'0'),
        b'a'..=b'f' => Some(value - b'a' + 10),
        b'A'..=b'F' => Some(value - b'A' + 10),
        _ => None,
    }
}

fn validate_history(history: &HistorySnapshot, spec: DocumentSpec) -> Result<(), StorageError> {
    if history.undo.len() > MAX_HISTORY_STATES || history.redo.len() > MAX_HISTORY_STATES {
        return Err(StorageError::LimitExceeded("undo or redo history length"));
    }
    let mut history_tile_bytes = 0usize;
    for state in history.undo.iter().chain(&history.redo) {
        validate_stored_state(state, spec)?;
        history_tile_bytes = history_tile_bytes
            .checked_add(state.tiles.len().saturating_mul(TILE_BYTES))
            .ok_or(StorageError::LimitExceeded("undo history tile bytes"))?;
        if history_tile_bytes > MAX_PROJECT_TILE_BYTES {
            return Err(StorageError::LimitExceeded("undo history tile bytes"));
        }
    }
    Ok(())
}

fn validate_vectors(
    vectors: &[VectorRecord],
    layer_ids: &HashSet<LayerId>,
) -> Result<(), StorageError> {
    if vectors.len() > MAX_VECTORS {
        return Err(StorageError::LimitExceeded("vector stroke count"));
    }
    let mut total = 0_u64;
    let mut strokes = HashSet::with_capacity(vectors.len());
    for vector in vectors {
        if !layer_ids.contains(&vector.layer) {
            return Err(StorageError::InvalidManifest(
                "vector stroke references an unknown layer".into(),
            ));
        }
        if vector.stroke == 0 || !strokes.insert((vector.layer, vector.stroke)) {
            return Err(StorageError::InvalidManifest(
                "vector stroke IDs are not unique per layer".into(),
            ));
        }
        if vector.bytes.is_empty() || vector.bytes.len() > MAX_VECTOR_BYTES {
            return Err(StorageError::LimitExceeded("vector stroke payload"));
        }
        serde_json::from_slice::<serde_json::Value>(&vector.bytes).map_err(|_| {
            StorageError::InvalidManifest("vector stroke payload is not valid JSON".into())
        })?;
        total = total
            .checked_add(u64::try_from(vector.bytes.len()).unwrap_or(u64::MAX))
            .ok_or(StorageError::LimitExceeded("vector library"))?;
        if total > MAX_VECTOR_LIBRARY_BYTES {
            return Err(StorageError::LimitExceeded("vector library"));
        }
    }
    Ok(())
}

fn validate_stored_state(state: &StoredState, spec: DocumentSpec) -> Result<(), StorageError> {
    if state.layers.is_empty() {
        return Err(StorageError::InvalidManifest(
            "document state has no layers".into(),
        ));
    }
    if state.layers.len() > MAX_LAYERS {
        return Err(StorageError::LimitExceeded("layer count"));
    }
    let mut layers = HashMap::with_capacity(state.layers.len());
    for layer in &state.layers {
        if layer.name.len() > MAX_LAYER_NAME_BYTES {
            return Err(StorageError::LimitExceeded("layer name length"));
        }
        if layers.insert(layer.id, layer).is_some() {
            return Err(StorageError::InvalidManifest(
                "layer IDs are not unique".into(),
            ));
        }
    }
    let layer_ids: HashSet<_> = state.layers.iter().map(|layer| layer.id).collect();
    validate_vectors(&state.vectors, &layer_ids)?;
    for layer in &state.layers {
        let mut visited = HashSet::new();
        let mut current = Some(layer.id);
        while let Some(id) = current {
            if !visited.insert(id) {
                return Err(StorageError::InvalidManifest(
                    "layer tree contains a parent cycle".into(),
                ));
            }
            let entry = layers.get(&id).ok_or_else(|| {
                StorageError::InvalidManifest("layer tree contains a dangling parent".into())
            })?;
            current = entry.parent;
        }
    }
    let mut tile_keys = HashSet::new();
    let mut tile_bytes = 0usize;
    for tile in &state.tiles {
        if !layers.contains_key(&tile.layer) {
            return Err(StorageError::InvalidManifest(
                "tile references an unknown layer".into(),
            ));
        }
        validate_tile_coordinate(spec, tile.coordinate)?;
        if tile.bytes.len() != TILE_BYTES {
            return Err(StorageError::InvalidManifest(
                "tile byte length is not 256x256 BGRA8".into(),
            ));
        }
        if !tile_keys.insert((tile.layer, tile.coordinate.x, tile.coordinate.y)) {
            return Err(StorageError::InvalidManifest(
                "document contains duplicate tile coordinates".into(),
            ));
        }
        tile_bytes = tile_bytes
            .checked_add(TILE_BYTES)
            .ok_or(StorageError::LimitExceeded("decoded tile bytes"))?;
        if tile_bytes > MAX_PROJECT_TILE_BYTES {
            return Err(StorageError::LimitExceeded("decoded tile bytes"));
        }
    }
    Ok(())
}

fn validate_tile_coordinate(spec: DocumentSpec, coordinate: TileCoord) -> Result<(), StorageError> {
    let width_in_tiles = spec.width_px.div_ceil(TILE_SIZE);
    let height_in_tiles = spec.height_px.div_ceil(TILE_SIZE);
    let x = u32::try_from(coordinate.x)
        .map_err(|_| StorageError::InvalidManifest("tile x is outside the canvas".into()))?;
    let y = u32::try_from(coordinate.y)
        .map_err(|_| StorageError::InvalidManifest("tile y is outside the canvas".into()))?;
    if x >= width_in_tiles || y >= height_in_tiles {
        return Err(StorageError::InvalidManifest(
            "tile coordinate is outside the canvas".into(),
        ));
    }
    Ok(())
}

fn read_project_file_bounded(
    root: &Path,
    relative: &Path,
    max_bytes: u64,
    limit_name: &'static str,
) -> Result<Vec<u8>, StorageError> {
    validate_project_file(root, relative, max_bytes, limit_name)?;
    let file = File::open(root.join(relative))?;
    let mut bytes = Vec::new();
    file.take(max_bytes.saturating_add(1))
        .read_to_end(&mut bytes)?;
    if u64::try_from(bytes.len()).unwrap_or(u64::MAX) > max_bytes {
        return Err(StorageError::LimitExceeded(limit_name));
    }
    Ok(bytes)
}

fn validate_project_file(
    root: &Path,
    relative: &Path,
    max_bytes: u64,
    limit_name: &'static str,
) -> Result<(), StorageError> {
    if relative.is_absolute()
        || relative
            .components()
            .any(|component| !matches!(component, Component::Normal(_)))
    {
        return Err(StorageError::UnsafePath(
            "project members must use normalized relative paths".into(),
        ));
    }
    let path = root.join(relative);
    let metadata = fs::symlink_metadata(&path)?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(StorageError::UnsafePath(
            "project members must be regular files".into(),
        ));
    }
    if metadata.len() > max_bytes {
        return Err(StorageError::LimitExceeded(limit_name));
    }
    let canonical_root = fs::canonicalize(root)?;
    let canonical_path = fs::canonicalize(&path)?;
    if !canonical_path.starts_with(&canonical_root) {
        return Err(StorageError::UnsafePath(
            "project member resolves outside the project root".into(),
        ));
    }
    Ok(())
}

fn decode_zstd_bounded(
    encoded: &[u8],
    max_bytes: usize,
    limit_name: &'static str,
) -> Result<Vec<u8>, StorageError> {
    let mut zstd_decoder =
        zstd::stream::read::Decoder::new(encoded).map_err(StorageError::Compression)?;
    // The encoder may select one window size above the exact payload length;
    // allow that bounded headroom while still rejecting untrusted multi-
    // gigabyte windows before zstd allocates them.
    let window_bytes = max_bytes.max(2 * 1024 * 1024);
    let window_log = if window_bytes <= 1 {
        0
    } else {
        usize::BITS - (window_bytes - 1).leading_zeros()
    };
    zstd_decoder
        .window_log_max(window_log)
        .map_err(StorageError::Compression)?;
    let mut decoded = Vec::new();
    zstd_decoder
        .take(
            u64::try_from(max_bytes)
                .unwrap_or(u64::MAX)
                .saturating_add(1),
        )
        .read_to_end(&mut decoded)
        .map_err(StorageError::Compression)?;
    if decoded.len() > max_bytes {
        return Err(StorageError::LimitExceeded(limit_name));
    }
    Ok(decoded)
}

fn validate_minimum_reader_version(value: &str) -> Result<(), StorageError> {
    fn parse(value: &str) -> Option<(u32, u32, u32)> {
        let mut components = value.split('.');
        let version = (
            components.next()?.parse().ok()?,
            components.next()?.parse().ok()?,
            components.next()?.parse().ok()?,
        );
        components.next().is_none().then_some(version)
    }
    let minimum = parse(value)
        .ok_or_else(|| StorageError::InvalidManifest("minimum reader version is invalid".into()))?;
    let current = (0, 1, 0);
    if minimum > current {
        return Err(StorageError::InvalidManifest(
            "document requires a newer Project Ink reader".into(),
        ));
    }
    Ok(())
}

fn remove_project_directory(path: &Path) -> Result<(), StorageError> {
    let metadata = fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(StorageError::UnsafePath(
            "temporary and backup paths must be real directories".into(),
        ));
    }
    fs::remove_dir_all(path)?;
    Ok(())
}

#[cfg(unix)]
fn sync_directory(path: &Path) -> Result<(), StorageError> {
    File::open(path)?.sync_all()?;
    Ok(())
}

#[cfg(not(unix))]
fn sync_directory(_path: &Path) -> Result<(), StorageError> {
    Ok(())
}

fn sibling_path(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path
        .file_name()
        .map_or_else(OsString::new, std::ffi::OsStr::to_os_string);
    name.push(suffix);
    path.with_file_name(name)
}

fn validate_source(path: &Path) -> Result<(), StorageError> {
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or_default();
    if path
        .extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| extension.eq_ignore_ascii_case(EXTENSION))
        || name.ends_with(".inkproj.bak")
    {
        let metadata = fs::symlink_metadata(path)?;
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            return Err(StorageError::UnsafePath(
                "project root must be a real directory".into(),
            ));
        }
        Ok(())
    } else {
        Err(StorageError::WrongExtension)
    }
}

fn validate_nested_source(path: &Path) -> Result<(), StorageError> {
    let metadata = fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(StorageError::UnsafePath(
            "nested page document must be a real directory".into(),
        ));
    }
    Ok(())
}

#[cfg(test)]
fn maybe_crash(point: CrashPoint) {
    if std::env::var("PROJECT_INK_TEST_KILL_STAGE").ok().as_deref() == Some(point.as_str()) {
        // Deliberately bypass destructors so the parent observes the exact
        // filesystem state left by an interrupted save.
        std::process::exit(137);
    }
}
fn parse_id(value: &str) -> Result<u128, StorageError> {
    if value.len() != 32 || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(StorageError::InvalidManifest(
            "object IDs must be exactly 32 hexadecimal characters".into(),
        ));
    }
    u128::from_str_radix(value, 16)
        .map_err(|_| StorageError::InvalidManifest("object ID is invalid".into()))
}
fn encode_layer_kind(kind: LayerKind) -> i64 {
    match kind {
        LayerKind::Raster => 0,
        LayerKind::VectorInk => 1,
        LayerKind::Group => 2,
        LayerKind::Mask => 3,
        LayerKind::Tone => 4,
        LayerKind::PanelGroup => 5,
        LayerKind::Adjustment => 6,
    }
}

fn encode_layer_blend_mode(mode: LayerBlendMode) -> i64 {
    match mode {
        LayerBlendMode::Normal => 0,
        LayerBlendMode::Multiply => 1,
        LayerBlendMode::Screen => 2,
        LayerBlendMode::Overlay => 3,
        LayerBlendMode::Darken => 4,
        LayerBlendMode::Lighten => 5,
        LayerBlendMode::Add => 6,
        LayerBlendMode::Subtract => 7,
        LayerBlendMode::ColorBurn => 8,
        LayerBlendMode::LinearBurn => 9,
        LayerBlendMode::ColorDodge => 10,
        LayerBlendMode::SoftLight => 11,
        LayerBlendMode::HardLight => 12,
        LayerBlendMode::Difference => 13,
        LayerBlendMode::Exclusion => 14,
        LayerBlendMode::Divide => 15,
    }
}

fn encode_layer_group_mode(mode: ink_model::LayerGroupMode) -> i64 {
    match mode {
        ink_model::LayerGroupMode::Isolated => 0,
        ink_model::LayerGroupMode::PassThrough => 1,
    }
}

fn decode_layer_group_mode(value: i64) -> Result<ink_model::LayerGroupMode, StorageError> {
    match value {
        0 => Ok(ink_model::LayerGroupMode::Isolated),
        1 => Ok(ink_model::LayerGroupMode::PassThrough),
        _ => Err(StorageError::InvalidManifest(
            "layer group mode is invalid".into(),
        )),
    }
}

fn decode_layer_blend_mode(value: i64) -> Result<LayerBlendMode, StorageError> {
    match value {
        0 => Ok(LayerBlendMode::Normal),
        1 => Ok(LayerBlendMode::Multiply),
        2 => Ok(LayerBlendMode::Screen),
        3 => Ok(LayerBlendMode::Overlay),
        4 => Ok(LayerBlendMode::Darken),
        5 => Ok(LayerBlendMode::Lighten),
        6 => Ok(LayerBlendMode::Add),
        7 => Ok(LayerBlendMode::Subtract),
        8 => Ok(LayerBlendMode::ColorBurn),
        9 => Ok(LayerBlendMode::LinearBurn),
        10 => Ok(LayerBlendMode::ColorDodge),
        11 => Ok(LayerBlendMode::SoftLight),
        12 => Ok(LayerBlendMode::HardLight),
        13 => Ok(LayerBlendMode::Difference),
        14 => Ok(LayerBlendMode::Exclusion),
        15 => Ok(LayerBlendMode::Divide),
        _ => Err(StorageError::InvalidManifest(format!(
            "unknown layer blend mode {value}"
        ))),
    }
}
fn decode_layer_kind(value: i64) -> Result<LayerKind, StorageError> {
    match value {
        0 => Ok(LayerKind::Raster),
        1 => Ok(LayerKind::VectorInk),
        2 => Ok(LayerKind::Group),
        3 => Ok(LayerKind::Mask),
        4 => Ok(LayerKind::Tone),
        5 => Ok(LayerKind::PanelGroup),
        6 => Ok(LayerKind::Adjustment),
        _ => Err(StorageError::InvalidManifest(format!(
            "unknown layer kind {value}"
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ink_command::{EditorCommand, encode_command};
    use ink_model::ColorSpace;
    use std::process::Command;

    fn save_with_failpoint(
        destination: &Path,
        snapshot: &ProjectSnapshot,
        stage: SaveStage,
    ) -> Result<(), StorageError> {
        save_project_inner(destination, snapshot, Some(stage))
    }

    fn snapshot() -> ProjectSnapshot {
        let id = DocumentId::from_u128(0xabc);
        let layer = Layer::new(LayerId::from_u128(1), LayerKind::Raster, "Ink");
        ProjectSnapshot {
            id,
            spec: DocumentSpec {
                width_px: 256,
                height_px: 256,
                dpi: 144.0,
                color_space: ColorSpace::Srgb,
                background: Rgba8::default(),
            },
            revision: 7,
            layers: vec![layer.clone()],
            tiles: vec![TileRecord {
                layer: layer.id,
                coordinate: TileCoord { x: 0, y: 0 },
                bytes: vec![42; (TILE_SIZE * TILE_SIZE * 4) as usize],
            }],
            vectors: Vec::new(),
            journal: vec![
                encode_command(&EditorCommand::BeginStroke {
                    stroke: ink_model::StrokeId::from_u128(2),
                    layer: layer.id,
                    brush: ink_model::BrushId::from_u128(1),
                }),
                encode_command(&EditorCommand::EndStroke {
                    stroke: ink_model::StrokeId::from_u128(2),
                }),
            ],
            history: HistorySnapshot::default(),
            brushes: Vec::new(),
            resources: Vec::new(),
            comic: None,
        }
    }

    fn history_with_named_states(names: &[&str]) -> HistorySnapshot {
        let layer_id = LayerId::from_u128(1);
        HistorySnapshot {
            undo: names
                .iter()
                .map(|name| StoredState {
                    layers: vec![Layer::new(
                        layer_id,
                        LayerKind::Raster,
                        format!("{name}-{}", "x".repeat(450)),
                    )],
                    tiles: Vec::new(),
                    vectors: Vec::new(),
                })
                .collect(),
            redo: Vec::new(),
            truncated_on_load: false,
        }
    }

    #[test]
    fn oversized_undo_history_is_trimmed_before_save_and_artwork_round_trips() {
        let root =
            std::env::temp_dir().join(format!("project-ink-history-bound-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).expect("temp root");
        let destination = root.join("bounded.inkproj");
        let mut expected = snapshot();
        expected.history = history_with_named_states(&["oldest", "middle", "newest"]);
        let original_artwork = expected.tiles.clone();

        save_project_inner_with_history_limit(&destination, &expected, None, 1_100)
            .expect("save should trim only persisted undo history");
        let actual = load_project(&destination).expect("saved project remains reopenable");

        assert_eq!(actual.tiles, original_artwork);
        assert_eq!(actual.layers, expected.layers);
        assert_eq!(actual.history.undo.len(), 1);
        assert!(actual.history.undo[0].layers[0].name.starts_with("newest-"));
        let encoded_history = fs::read(destination.join("history.json.zst"))
            .expect("history sidecar")
            .as_slice()
            .to_vec();
        let decoded_history = decode_zstd_bounded(&encoded_history, 1_100, "decoded history size")
            .expect("saved history respects the configured read bound");
        assert!(decoded_history.len() <= 1_100);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn oversized_legacy_history_is_discarded_without_losing_document_artwork() {
        let root =
            std::env::temp_dir().join(format!("project-ink-legacy-history-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).expect("temp root");
        let destination = root.join("legacy.inkproj");
        let mut expected = snapshot();
        expected.history = history_with_named_states(&["undo-one", "undo-two"]);
        let original_artwork = expected.tiles.clone();

        write_snapshot(&destination, &expected, None, 10_000).expect("write legacy-style sidecar");
        let loaded = load_project_contents_with_history_limit(&destination, 1_000)
            .expect("oversized optional history must not block artwork open");

        assert_eq!(loaded.tiles, original_artwork);
        assert_eq!(loaded.layers, expected.layers);
        assert!(loaded.history.undo.is_empty());
        assert!(loaded.history.truncated_on_load);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn round_trip_is_lossless_and_uses_atomic_publish() {
        let root = std::env::temp_dir().join(format!("project-ink-storage-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).expect("temp root");
        let destination = root.join("sample.inkproj");
        let expected = snapshot();
        save_project(&destination, &expected).expect("save");
        let actual = load_project(&destination).expect("load");
        assert_eq!(actual, expected);
        assert!(destination.join("document.sqlite").is_file());
        assert!(destination.join("tiles").is_dir());
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn adjustment_layers_and_typed_settings_round_trip() {
        let root = std::env::temp_dir().join(format!(
            "project-ink-adjustment-storage-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).expect("temp root");
        let destination = root.join("adjustment.inkproj");
        let mut expected = snapshot();
        expected.layers[0].kind = LayerKind::Adjustment;
        expected.layers[0].adjustment = Some(ink_model::LayerAdjustment::BrightnessContrast {
            brightness: -35,
            contrast: 80,
        });
        save_project(&destination, &expected).expect("save adjustment layer");
        let actual = load_project(&destination).expect("load adjustment layer");
        assert_eq!(actual, expected);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn group_compositing_mode_round_trips() {
        let root = std::env::temp_dir().join(format!(
            "project-ink-group-mode-storage-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).expect("temp root");
        let destination = root.join("group-mode.inkproj");
        let mut expected = snapshot();
        expected.layers[0].kind = LayerKind::Group;
        expected.layers[0].group_mode = ink_model::LayerGroupMode::PassThrough;
        save_project(&destination, &expected).expect("save group mode");
        let actual = load_project(&destination).expect("load group mode");
        assert_eq!(actual, expected);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn studio_project_round_trip_keeps_page_documents_inside_one_container() {
        let root =
            std::env::temp_dir().join(format!("project-ink-studio-storage-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).expect("temp root");
        let destination = root.join("comic.inkproj");
        let project = ink_comic::xkcd_stick_figure_comic();
        let comic = project.to_json().expect("comic json");
        let pages = project
            .page_documents
            .iter()
            .map(|page_ref| {
                let page = project
                    .pages
                    .iter()
                    .find(|page| page.id == page_ref.page_id)
                    .expect("page");
                let mut page_snapshot = snapshot();
                page_snapshot.id = DocumentId::from_u128(page_ref.document_id);
                page_snapshot.spec.width_px = page.spec.width_px;
                page_snapshot.spec.height_px = page.spec.height_px;
                page_snapshot.spec.dpi = page.spec.dpi;
                StudioPageSnapshot {
                    page_id: page_ref.page_id,
                    relative_path: page_ref.relative_path.clone(),
                    snapshot: page_snapshot,
                }
            })
            .collect();
        let expected = StudioProjectSnapshot { comic, pages };
        save_studio_project(&destination, &expected).expect("studio save");
        let actual = load_studio_project(&destination).expect("studio load");
        assert_eq!(actual.comic, expected.comic);
        assert_eq!(actual.pages.len(), 8);
        assert!(destination.join("comic.json").is_file());
        assert!(destination.join("pages").is_dir());
        assert!(
            destination
                .join("pages")
                .join(format!("{:032x}", expected.pages[0].page_id))
                .join("document.sqlite")
                .is_file()
        );
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn vector_sidecar_round_trip_is_bounded_and_lossless() {
        let root = std::env::temp_dir().join(format!(
            "project-ink-storage-vectors-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).expect("temp root");
        let destination = root.join("vectors.inkproj");
        let mut expected = snapshot();
        let vector_layer = Layer::new(LayerId::from_u128(2), LayerKind::VectorInk, "Vectors");
        expected.layers.push(vector_layer.clone());
        expected.vectors.push(VectorRecord {
            layer: vector_layer.id,
            stroke: 3,
            bytes: br#"{"points":[{"x":1.0,"y":2.0,"pressure":1.0,"tilt":0.0}],"closed":false}"#
                .to_vec(),
        });
        save_project(&destination, &expected).expect("save");
        let actual = load_project(&destination).expect("load");
        assert_eq!(actual.vectors, expected.vectors);
        assert!(destination.join("vectors.json.zst").is_file());
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn rejects_non_native_extension_without_writing() {
        let root =
            std::env::temp_dir().join(format!("project-ink-extension-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).expect("temp root");
        let result = save_project(&root.join("wrong.png"), &snapshot());
        assert!(matches!(result, Err(StorageError::WrongExtension)));
        assert_eq!(fs::read_dir(&root).expect("read root").count(), 0);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn opening_incomplete_project_does_not_create_missing_sqlite() {
        let root = std::env::temp_dir().join(format!(
            "project-ink-storage-missing-sqlite-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("clock")
                .as_nanos()
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).expect("temp root");
        let source = root.join("missing.inkproj");
        save_project(&source, &snapshot()).expect("save");
        fs::remove_file(source.join("document.sqlite")).expect("remove sqlite");

        assert!(load_project(&source).is_err());
        assert!(!source.join("document.sqlite").exists());
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn rejects_tile_path_traversal_from_metadata() {
        let root = std::env::temp_dir().join(format!(
            "project-ink-storage-traversal-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).expect("temp root");
        let source = root.join("traversal.inkproj");
        save_project(&source, &snapshot()).expect("save");
        let connection = Connection::open(source.join("document.sqlite")).expect("sqlite");
        connection
            .execute("UPDATE tiles SET path = '../outside.tile.zst'", [])
            .expect("tamper path");
        drop(connection);

        assert!(matches!(
            load_project(&source),
            Err(StorageError::UnsafePath(_))
        ));
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[cfg(unix)]
    #[test]
    fn rejects_symlinked_project_members() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "project-ink-storage-symlink-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).expect("temp root");
        let source = root.join("symlink.inkproj");
        save_project(&source, &snapshot()).expect("save");
        let outside = root.join("outside.tile.zst");
        fs::write(&outside, b"not a tile").expect("outside file");
        let tile_path = source
            .join("tiles")
            .join(LayerId::from_u128(1).to_string())
            .join("0_0.tile.zst");
        fs::remove_file(&tile_path).expect("remove tile");
        symlink(&outside, &tile_path).expect("symlink tile");

        assert!(matches!(
            load_project(&source),
            Err(StorageError::UnsafePath(_))
        ));
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn rejects_zstd_payload_that_expands_past_tile_limit() {
        let root = std::env::temp_dir().join(format!(
            "project-ink-storage-zstd-limit-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).expect("temp root");
        let source = root.join("bomb.inkproj");
        save_project(&source, &snapshot()).expect("save");
        let oversized = vec![0u8; TILE_BYTES + 1];
        let encoded = zstd::stream::encode_all(oversized.as_slice(), 1).expect("encode");
        let tile_path = source
            .join("tiles")
            .join(LayerId::from_u128(1).to_string())
            .join("0_0.tile.zst");
        fs::write(tile_path, encoded).expect("replace tile");

        assert!(matches!(
            load_project(&source),
            Err(StorageError::LimitExceeded("decoded tile size"))
        ));
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn rejects_manifest_revision_that_disagrees_with_checkpoint() {
        let root = std::env::temp_dir().join(format!(
            "project-ink-storage-revision-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).expect("temp root");
        let source = root.join("revision.inkproj");
        save_project(&source, &snapshot()).expect("save");
        let manifest_path = source.join("manifest.json");
        let manifest = fs::read_to_string(&manifest_path).expect("manifest");
        fs::write(
            &manifest_path,
            manifest.replace("\"revision\": 7", "\"revision\": 8"),
        )
        .expect("tamper manifest");

        assert!(matches!(
            load_project(&source),
            Err(StorageError::InvalidManifest(message)) if message.contains("checkpoint revision")
        ));
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn recovery_reads_backup_and_preserves_corrupt_source() {
        let root =
            std::env::temp_dir().join(format!("project-ink-recovery-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).expect("temp root");
        let source = root.join("drawing.inkproj");
        let recovered = root.join("drawing-recovered.inkproj");
        let expected = snapshot();
        save_project(&source, &expected).expect("first save");
        let replacement = ProjectSnapshot {
            revision: 8,
            ..expected.clone()
        };
        save_project(&source, &replacement).expect("second save");
        fs::write(source.join("manifest.json"), b"not-json").expect("corrupt source");
        recover_project(&source, &recovered).expect("recover");
        assert_eq!(
            load_project(&recovered).expect("recovered").revision,
            expected.revision
        );
        assert_eq!(
            fs::read(source.join("manifest.json"))
                .expect("source")
                .as_slice(),
            b"not-json"
        );
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn rejects_corrupt_command_journal_without_mutating_source() {
        let root = std::env::temp_dir().join(format!(
            "project-ink-journal-corruption-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).expect("temp root");
        let source = root.join("drawing.inkproj");
        save_project(&source, &snapshot()).expect("save");

        let connection = Connection::open(source.join("document.sqlite")).expect("open sqlite");
        connection
            .execute(
                "UPDATE command_journal SET payload = ?1 WHERE sequence = 0",
                params![vec![0xff_u8]],
            )
            .expect("corrupt journal");
        drop(connection);

        let result = load_project(&source);
        assert!(matches!(
            result,
            Err(StorageError::InvalidManifest(message))
                if message.contains("invalid command journal")
        ));
        assert!(source.join("manifest.json").is_file());
        assert!(source.join("document.sqlite").is_file());
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn refuses_to_publish_an_invalid_command_journal() {
        let root = std::env::temp_dir().join(format!(
            "project-ink-journal-save-validation-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).expect("temp root");
        let destination = root.join("drawing.inkproj");
        let invalid = ProjectSnapshot {
            journal: vec![vec![0xff_u8]],
            ..snapshot()
        };
        let result = save_project(&destination, &invalid);
        assert!(matches!(
            result,
            Err(StorageError::InvalidManifest(message))
                if message.contains("invalid command journal")
        ));
        assert!(!destination.exists());
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn injected_checkpoint_failures_preserve_last_published_project() {
        let root = std::env::temp_dir().join(format!(
            "project-ink-save-failpoints-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).expect("temp root");
        let destination = root.join("drawing.inkproj");
        let original = snapshot();
        save_project(&destination, &original).expect("initial save");

        let replacement = ProjectSnapshot {
            revision: original.revision + 1,
            ..original.clone()
        };
        for stage in [
            SaveStage::Manifest,
            SaveStage::Tiles,
            SaveStage::Sqlite,
            SaveStage::History,
        ] {
            let result = save_with_failpoint(&destination, &replacement, stage);
            assert!(matches!(result, Err(StorageError::Io(_))));
            assert_eq!(
                load_project(&destination)
                    .expect("last valid save")
                    .revision,
                original.revision
            );
            assert!(!sibling_path(&destination, ".tmp").exists());
        }
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn process_kill_during_save_preserves_last_valid_project() {
        if let (Ok(stage), Ok(destination)) = (
            std::env::var("PROJECT_INK_TEST_KILL_STAGE"),
            std::env::var("PROJECT_INK_TEST_KILL_DESTINATION"),
        ) {
            let original = snapshot();
            let replacement = ProjectSnapshot {
                revision: original.revision + 1,
                ..original
            };
            assert!(!stage.is_empty(), "child stage must be set");
            let _ = save_project_inner(Path::new(&destination), &replacement, None);
            panic!("save child should terminate at the requested crash point");
        }

        let stages = [
            CrashPoint::Manifest,
            CrashPoint::Sqlite,
            CrashPoint::Tiles,
            CrashPoint::History,
            CrashPoint::AfterBackupRename,
            CrashPoint::AfterPublishRename,
        ];
        for (index, stage) in stages.into_iter().enumerate() {
            let root = std::env::temp_dir().join(format!(
                "project-ink-storage-process-kill-{}-{index}",
                std::process::id()
            ));
            let _ = fs::remove_dir_all(&root);
            fs::create_dir_all(&root).expect("temp root");
            let destination = root.join("drawing.inkproj");
            let original = snapshot();
            save_project(&destination, &original).expect("initial save");

            let status = Command::new(std::env::current_exe().expect("test executable"))
                .args([
                    "--exact",
                    "tests::process_kill_during_save_preserves_last_valid_project",
                ])
                .env("PROJECT_INK_TEST_KILL_STAGE", stage.as_str())
                .env("PROJECT_INK_TEST_KILL_DESTINATION", &destination)
                .status()
                .expect("spawn save child");
            assert!(!status.success(), "child must terminate at {stage:?}");

            match stage {
                CrashPoint::AfterBackupRename => {
                    let recovered = root.join("recovered.inkproj");
                    recover_project(&destination, &recovered).expect("recover backup");
                    assert_eq!(
                        load_project(&recovered)
                            .expect("recovered project")
                            .revision,
                        original.revision
                    );
                }
                CrashPoint::AfterPublishRename => {
                    assert_eq!(
                        load_project(&destination)
                            .expect("published replacement")
                            .revision,
                        original.revision + 1
                    );
                }
                CrashPoint::Manifest
                | CrashPoint::Sqlite
                | CrashPoint::Tiles
                | CrashPoint::History => {
                    assert_eq!(
                        load_project(&destination)
                            .expect("last valid project")
                            .revision,
                        original.revision
                    );
                }
            }
            fs::remove_dir_all(root).expect("cleanup");
        }
    }
}
