//! Public control-plane functions exposed to Flutter through FRB.

#![allow(clippy::needless_pass_by_value)]

use ink_comic::{
    Balloon, BalloonShape, ComicProject, EffectLine, MaterialAsset, Panel, PanelShape,
    ProjectTemplate, Rect, TextOrientation, TextStyle, ToneLayer,
};
pub use ink_command::EditorCommand;
use ink_engine::BrushPreviewPoint as EngineBrushPreviewPoint;
use ink_engine::{CompositeTileReadSnapshot, Document};
pub use ink_engine::{EngineError, EngineEvent};
use ink_model::{BrushId, DocumentId, StrokeId};
use ink_model::{ColorSpace, LayerAdjustment, LayerBlendMode, LayerGroupMode, LayerKind, Rgba8};
pub use ink_model::{DocumentSpec, Layer};
use ink_raster::TileCoord;
use std::collections::{BTreeMap, HashSet};
use std::fmt::Write as _;
use std::io::{Read, Write};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

/// Immutable and bounded history projection returned to editor palettes.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HistorySnapshotView {
    pub revision: u64,
    pub cursor: u32,
    pub entries: Vec<HistoryEntryView>,
    pub was_trimmed: bool,
}

/// One stable, display-only entry in a Rust-authoritative history snapshot.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HistoryEntryView {
    pub sequence: u64,
    pub kind: String,
    pub detail: Option<String>,
    pub applied: bool,
}

/// Persisted layer-panel selection and group disclosure for one document page.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct LayerPanelStateView {
    pub primary_layer_id: Option<u128>,
    pub collapsed_group_ids: Vec<String>,
}

/// Normalized scratchpad sample sent to the bounded Rust preview renderer.
#[derive(Clone, Copy, Debug)]
pub struct BrushPreviewPoint {
    pub x: f32,
    pub y: f32,
    pub pressure: f32,
}

/// Immutable pixels and revision captured for a bounded composite-tile read.
/// The opaque handle is separate from `DocumentHandle` so CPU compositing does
/// not hold the document's Flutter Rust Bridge lock while pointer input arrives.
#[flutter_rust_bridge::frb(opaque)]
pub struct CompositeTilesSnapshotHandle {
    snapshot: Mutex<Option<CompositeTileReadSnapshot>>,
    coordinates: Mutex<Vec<TileCoord>>,
}

/// Phase 2 export formats accepted by the bridge.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[allow(dead_code)]
pub enum ExportKind {
    Png,
    Jpeg,
    Webp,
    OpenRaster,
    Svg,
    Psd,
}

/// Inspect an external brush before conversion or installation.
#[allow(dead_code)]
pub fn inspect_brush_import(path: String) -> Result<BrushImportInspectionView, EngineError> {
    let path = std::path::PathBuf::from(path);
    ink_brush::inspect_brush_import(&path)
        .map(|value| inspection_view(&value))
        .map_err(|error| EngineError::InvalidCommand(format!("brush inspection failed: {error}")))
}

/// Convert a supported brush source without modifying the source file.
#[allow(dead_code)]
pub fn convert_brush_import(path: String) -> Result<BrushImportReportView, EngineError> {
    let path = std::path::PathBuf::from(path);
    ink_brush::import_external(&path)
        .map(|value| {
            let brush_count = if value.source_format == ink_brush::ExternalBrushFormat::InkBrushPack
            {
                ink_brush::import_inkbrushpack(&path).map_or(0, |reports| {
                    u32::try_from(reports.len()).unwrap_or(u32::MAX)
                })
            } else {
                1
            };
            report_view(&value, brush_count)
        })
        .map_err(|error| EngineError::InvalidCommand(format!("brush conversion failed: {error}")))
}

fn purge_expired_brush_imports(handle: &mut DocumentHandle) {
    let now = Instant::now();
    let Ok(mut state) = document_state(handle) else {
        return;
    };
    state
        .staged_brush_imports
        .retain(|_, operation| operation.expires_at > now);
}

/// Inspect and stage an external brush under a bounded, expiring operation ID.
/// The path and source hash are held only in the opaque document handle.
pub fn stage_brush_import(
    handle: &mut DocumentHandle,
    path: String,
) -> Result<BrushImportStageView, EngineError> {
    purge_expired_brush_imports(handle);
    if document_state(handle)?.staged_brush_imports.len() >= MAX_STAGED_BRUSH_IMPORTS {
        return Err(EngineError::InvalidCommand(
            "too many staged brush imports; commit or discard one first".into(),
        ));
    }
    let path = PathBuf::from(path);
    let inspected = ink_brush::inspect_brush_import(&path).map_err(|error| {
        EngineError::InvalidCommand(format!("brush inspection failed: {error}"))
    })?;
    let mut state = document_state(handle)?;
    let operation_id = state.next_brush_import;
    let next_operation_id = operation_id
        .checked_add(1)
        .ok_or_else(|| EngineError::InvalidCommand("brush operation ID space exhausted".into()))?;
    state.next_brush_import = next_operation_id;
    state.staged_brush_imports.insert(
        operation_id,
        StagedBrushImport {
            path,
            source_sha256: inspected.source_sha256,
            expires_at: Instant::now() + BRUSH_IMPORT_TTL,
        },
    );
    Ok(BrushImportStageView {
        operation_id,
        inspection: inspection_view(&inspected),
        expires_in_seconds: u32::try_from(BRUSH_IMPORT_TTL.as_secs()).unwrap_or(u32::MAX),
    })
}

#[derive(Clone)]
struct StagedBrushImport {
    path: PathBuf,
    source_sha256: [u8; 32],
    expires_at: Instant,
}

fn staged_brush_import(
    handle: &mut DocumentHandle,
    operation_id: u64,
) -> Result<StagedBrushImport, EngineError> {
    purge_expired_brush_imports(handle);
    document_state(handle)?
        .staged_brush_imports
        .get(&operation_id)
        .cloned()
        .ok_or_else(|| {
            EngineError::InvalidCommand("brush import operation expired or unknown".into())
        })
}

/// Re-read a staged source and return its compatibility report without
/// changing the document. A changed source invalidates the operation.
pub fn convert_staged_brush_import(
    handle: &mut DocumentHandle,
    operation_id: u64,
) -> Result<BrushImportReportView, EngineError> {
    let operation = staged_brush_import(handle, operation_id)?;
    let report = ink_brush::import_external(&operation.path).map_err(|error| {
        EngineError::InvalidCommand(format!("brush conversion failed: {error}"))
    })?;
    if report.source_sha256 != operation.source_sha256 {
        return Err(EngineError::InvalidCommand(
            "brush source changed after staging".into(),
        ));
    }
    let brush_count = if report.source_format == ink_brush::ExternalBrushFormat::InkBrushPack {
        ink_brush::import_inkbrushpack(&operation.path).map_or(0, |reports| {
            u32::try_from(reports.len()).unwrap_or(u32::MAX)
        })
    } else {
        1
    };
    Ok(report_view(&report, brush_count))
}

/// Commit a staged brush only after its source hash is revalidated.
pub fn commit_staged_brush_import(
    handle: &mut DocumentHandle,
    operation_id: u64,
) -> Result<u128, EngineError> {
    let (path, expected) = {
        let operation = staged_brush_import(handle, operation_id)?;
        (operation.path.clone(), operation.source_sha256)
    };
    let id = document_mut(handle)?
        .import_brush_verified(&path, Some(expected))?
        .0;
    document_state(handle)?
        .staged_brush_imports
        .remove(&operation_id);
    Ok(id)
}

/// Discard a staged import. Unknown IDs are intentionally idempotent so a
/// cancelled mobile picker cannot strand state in the native handle.
pub fn discard_staged_brush_import(handle: &mut DocumentHandle, operation_id: u64) {
    if let Ok(mut state) = document_state(handle) {
        state.staged_brush_imports.remove(&operation_id);
    }
}

/// Explicitly stage an image as a user-selected brush tip.
#[allow(dead_code)]
pub fn import_image_brush(path: String) -> Result<BrushImportReportView, EngineError> {
    let path = std::path::PathBuf::from(path);
    ink_brush::import_image_as_brush(&path)
        .map(|value| report_view(&value, 1))
        .map_err(|error| EngineError::InvalidCommand(format!("image brush import failed: {error}")))
}

const TILE_UPDATE_PACKET_VERSION: u16 = 4;
const TILE_UPDATE_PACKET_FULL_REDRAW: u16 = 1 << 0;
const TILE_UPDATE_PACKET_RENDER_BUSY: u16 = 1 << 1;
const TILE_UPDATE_RECORD_BYTES: usize = 32;
const MAX_TILE_UPDATE_RECORDS: usize = 262_144;
// The all-ones u128 is reserved for a composite-tile invalidation record.
// Real layer IDs are bounded to the signed 64-bit range at the Dart boundary.
const COMPOSITE_TILE_LAYER: u128 = u128::MAX;
const STROKE_ACK_PACKET_VERSION: u16 = 1;
const STROKE_ACK_RECORD_BYTES: usize = 44;
const STROKE_COMMIT_ACK_BASE_BYTES: usize = 48 + STROKE_RENDER_METRICS_BYTES;
const STROKE_RENDER_METRICS_BYTES: usize = 65;
const MAX_STROKE_ACK_RECORDS: usize = 65_536;
const MAX_TILE_UPDATE_PACKET_BYTES: usize = 16 * 1024 * 1024;
const COMPOSITE_SNAPSHOT_PACKET_VERSION: u16 = 1;
const COMPOSITE_SNAPSHOT_HEADER_BYTES: usize = 16;
const COMPOSITE_SNAPSHOT_TILE_BYTES: usize = 256 * 256 * 4;
const COMPOSITE_SNAPSHOT_RECORD_BYTES: usize = 8 + COMPOSITE_SNAPSHOT_TILE_BYTES;
const MAX_COMPOSITE_SNAPSHOT_TILES: usize = (MAX_TILE_UPDATE_PACKET_BYTES
    - COMPOSITE_SNAPSHOT_HEADER_BYTES)
    / COMPOSITE_SNAPSHOT_RECORD_BYTES;
const LIVE_DAB_PACKET_VERSION: u16 = 3;
const LIVE_DAB_RECORD_BYTES: usize = 56;
const MAX_LIVE_DABS_PER_PACKET: usize = 65_536;

fn encode_live_dab_packet(dabs: &[ink_live_render::LiveDab]) -> Vec<u8> {
    let count = u32::try_from(dabs.len()).unwrap_or(u32::MAX);
    let mut packet =
        Vec::with_capacity(8usize.saturating_add(dabs.len().saturating_mul(LIVE_DAB_RECORD_BYTES)));
    packet.extend(LIVE_DAB_PACKET_VERSION.to_le_bytes());
    packet.extend(0_u16.to_le_bytes());
    packet.extend(count.to_le_bytes());
    for dab in dabs {
        packet.extend(dab.stroke_id.to_le_bytes());
        packet.extend(dab.sequence.to_le_bytes());
        packet.extend(dab.dab_index.to_le_bytes());
        packet.extend(dab.x.to_le_bytes());
        packet.extend(dab.y.to_le_bytes());
        packet.extend(dab.radius.to_le_bytes());
        packet.extend(dab.opacity.to_le_bytes());
        packet.extend(dab.rotation.to_le_bytes());
        packet.push(match dab.phase {
            ink_live_render::DabPhase::Predicted => 0,
            ink_live_render::DabPhase::Coalesced => 1,
            ink_live_render::DabPhase::Confirmed => 2,
        });
        packet.extend(dab.color);
        // Seven zero bytes keep each v3 record fixed-width and reserved for
        // compatible future extensions.
        packet.extend([0_u8; 7]);
    }
    packet
}

fn decode_live_dab_packet(packet: &[u8]) -> Result<Vec<ink_live_render::LiveDab>, EngineError> {
    if packet.len() < 8 {
        return Err(EngineError::InvalidCommand(
            "live dab packet header is truncated".into(),
        ));
    }
    let version = u16::from_le_bytes([packet[0], packet[1]]);
    let flags = u16::from_le_bytes([packet[2], packet[3]]);
    let count = u32::from_le_bytes([packet[4], packet[5], packet[6], packet[7]]) as usize;
    if version != LIVE_DAB_PACKET_VERSION || flags != 0 || count > MAX_LIVE_DABS_PER_PACKET {
        return Err(EngineError::InvalidCommand(
            "live dab packet header is invalid".into(),
        ));
    }
    let expected = 8usize.saturating_add(count.saturating_mul(LIVE_DAB_RECORD_BYTES));
    if packet.len() != expected {
        return Err(EngineError::InvalidCommand(
            "live dab packet length is invalid".into(),
        ));
    }
    let mut dabs = Vec::with_capacity(count);
    for index in 0..count {
        let offset = 8 + index * LIVE_DAB_RECORD_BYTES;
        let mut stroke_bytes = [0_u8; 16];
        stroke_bytes.copy_from_slice(&packet[offset..offset + 16]);
        let read_f32 = |start: usize| {
            f32::from_le_bytes([
                packet[start],
                packet[start + 1],
                packet[start + 2],
                packet[start + 3],
            ])
        };
        let phase = match packet[offset + 44] {
            0 => ink_live_render::DabPhase::Predicted,
            1 => ink_live_render::DabPhase::Coalesced,
            2 => ink_live_render::DabPhase::Confirmed,
            _ => {
                return Err(EngineError::InvalidCommand(
                    "live dab packet phase is invalid".into(),
                ));
            }
        };
        if packet[offset + 49..offset + LIVE_DAB_RECORD_BYTES]
            .iter()
            .any(|byte| *byte != 0)
        {
            return Err(EngineError::InvalidCommand(
                "live dab packet reserved bytes are nonzero".into(),
            ));
        }
        dabs.push(
            ink_live_render::LiveDab {
                stroke_id: u128::from_le_bytes(stroke_bytes),
                sequence: u32::from_le_bytes(packet[offset + 16..offset + 20].try_into().map_err(
                    |_| EngineError::InvalidCommand("live dab sequence is truncated".into()),
                )?),
                dab_index: u32::from_le_bytes(
                    packet[offset + 20..offset + 24].try_into().map_err(|_| {
                        EngineError::InvalidCommand("live dab index is truncated".into())
                    })?,
                ),
                x: read_f32(offset + 24),
                y: read_f32(offset + 28),
                radius: read_f32(offset + 32),
                opacity: read_f32(offset + 36),
                rotation: read_f32(offset + 40),
                color: [
                    packet[offset + 45],
                    packet[offset + 46],
                    packet[offset + 47],
                    packet[offset + 48],
                ],
                phase,
            }
            .validate()
            .map_err(|error| EngineError::InvalidCommand(format!("invalid live dab: {error:?}")))?,
        );
    }
    Ok(dabs)
}

/// Return a stable bridge/engine health marker before opening a document.
pub fn engine_health() -> String {
    "project-ink-engine-v1".to_owned()
}

/// Opaque document handle used by the generated bridge.
#[flutter_rust_bridge::frb(opaque)]
#[derive(Clone)]
pub struct DocumentHandle {
    state: Arc<Mutex<DocumentHandleState>>,
}

struct DocumentHandleState {
    inner: Option<Document>,
    active_stroke: Option<StrokeId>,
    tile_snapshot_sent: bool,
    staged_brush_imports: BTreeMap<u64, StagedBrushImport>,
    next_brush_import: u64,
}

struct DocumentRef<'a> {
    state: MutexGuard<'a, DocumentHandleState>,
}

impl std::ops::Deref for DocumentRef<'_> {
    type Target = Document;

    fn deref(&self) -> &Self::Target {
        self.state
            .inner
            .as_ref()
            .expect("DocumentRef is only created for an open document")
    }
}

struct DocumentMutRef<'a> {
    state: MutexGuard<'a, DocumentHandleState>,
}

impl std::ops::Deref for DocumentMutRef<'_> {
    type Target = Document;

    fn deref(&self) -> &Self::Target {
        self.state
            .inner
            .as_ref()
            .expect("DocumentMutRef is only created for an open document")
    }
}

impl std::ops::DerefMut for DocumentMutRef<'_> {
    fn deref_mut(&mut self) -> &mut Self::Target {
        self.state
            .inner
            .as_mut()
            .expect("DocumentMutRef is only created for an open document")
    }
}

/// Opaque Phase 3 comic project handle. Comic structure remains Rust-owned;
/// Flutter receives bounded immutable projections and never mirrors page state.
#[flutter_rust_bridge::frb(opaque)]
pub struct ComicProjectHandle {
    inner: Option<ComicProject>,
}

/// Unified Phase 3.5 project boundary. Comic metadata and every page's
/// document handle are owned together; callers cannot accidentally save a
/// page through a separate authority or activate a page that is not in the
/// validated project graph.
#[flutter_rust_bridge::frb(opaque)]
pub struct StudioProjectHandle {
    project: Option<ComicProject>,
    pages: BTreeMap<u128, DocumentHandle>,
    active_page: Option<u128>,
    project_undo: Vec<StudioProjectHistoryState>,
    project_redo: Vec<StudioProjectHistoryState>,
}

/// A project-manager checkpoint contains the comic graph and every page
/// document snapshot. Page drawing history remains inside each Document, but
/// structural edits (panel geometry, pages, dialogue, etc.) must be undoable
/// without rebuilding blank page documents from JSON.
#[derive(Clone)]
struct StudioProjectHistoryState {
    project: ComicProject,
    pages: BTreeMap<u128, ink_storage::ProjectSnapshot>,
    active_page: Option<u128>,
}

impl StudioProjectHistoryState {
    fn payload_bytes(&self) -> usize {
        self.pages.values().map(studio_snapshot_payload_bytes).sum()
    }
}

const MAX_STUDIO_PROJECT_HISTORY: usize = 16;
const MAX_STUDIO_HISTORY_STATE_BYTES: usize = 256 * 1024 * 1024;
const MAX_STUDIO_HISTORY_BYTES: usize = 512 * 1024 * 1024;

/// Opaque GPU live-surface handle. The native texture registry remains a
/// platform concern; this handle owns only the bounded wgpu target and never
/// becomes document authority.
#[flutter_rust_bridge::frb(opaque)]
pub struct LiveSurfaceHandle {
    inner: Option<ink_live_render::GpuLiveSurface>,
    config: ink_live_render::LiveSurfaceConfig,
    attached_document: Option<u128>,
    viewport_generation: u64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ComicPageView {
    pub id: u128,
    pub page_number: u32,
    pub width_px: u32,
    pub height_px: u32,
    pub dpi: f32,
    pub panel_count: u32,
    pub balloon_count: u32,
    pub tone_count: u32,
    pub effect_line_count: u32,
    pub panels: Vec<ComicPanelPreviewView>,
    pub balloons: Vec<ComicBalloonPreviewView>,
    pub tones: Vec<ComicTonePreviewView>,
    pub effect_lines: Vec<ComicEffectLinePreviewView>,
    pub bleed_left: f32,
    pub bleed_top: f32,
    pub bleed_right: f32,
    pub bleed_bottom: f32,
    pub trim_x: f32,
    pub trim_y: f32,
    pub trim_width: f32,
    pub trim_height: f32,
    pub safety_left: f32,
    pub safety_top: f32,
    pub safety_right: f32,
    pub safety_bottom: f32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ComicPanelPreviewView {
    pub id: u128,
    pub shape: u8,
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    pub gutter_px: f32,
    pub mask_layer_id: Option<u128>,
    /// Stable page-document layer ownership IDs. `None` is retained for
    /// legacy v1 comic metadata that has not yet materialized its binding.
    pub panel_group_id: Option<u128>,
    pub sketch_layer_id: Option<u128>,
    pub ink_layer_id: Option<u128>,
    pub color_layer_id: Option<u128>,
    pub tone_layer_id: Option<u128>,
    pub effects_layer_id: Option<u128>,
    /// Polygon vertices flattened as x0,y0,x1,y1,... for touch-safe editing.
    pub polygon: Vec<f32>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ComicBalloonPreviewView {
    pub id: u128,
    pub shape: u8,
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    pub panel_id: Option<u128>,
    pub text: String,
    pub font_family: String,
    pub font_size_px: f32,
    pub outline_px: f32,
    pub orientation: u8,
    /// Tail points flattened as x0,y0,x1,y1,... for touch-safe editing.
    pub tail: Vec<f32>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ComicTonePreviewView {
    pub id: u128,
    pub frequency_lpi: f32,
    pub angle_degrees: f32,
    pub density: f32,
    pub shape: String,
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ComicEffectLinePreviewView {
    pub id: u128,
    pub kind: String,
    pub points: Vec<f32>,
    pub width_px: f32,
    pub opacity: f32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ComicProjectView {
    pub id: u128,
    pub template: u8,
    pub title: String,
    pub page_count: u32,
    pub pages: Vec<ComicPageView>,
    pub materials: Vec<ComicMaterialView>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ComicMaterialView {
    pub id: u128,
    pub name: String,
    pub kind: String,
    pub license: String,
    pub attribution: Option<String>,
    pub source: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ComicDialogueHitView {
    pub page_index: u32,
    pub balloon_id: u128,
    pub match_start: u32,
    pub match_end: u32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ComicWebtoonSegmentView {
    pub page_index: u32,
    pub segment_index: u32,
    pub source_y: u32,
    pub height_px: u32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ComicPrintPreviewView {
    pub page_count: u32,
    pub bleed_safe: bool,
    pub safety_safe: bool,
    pub moire_warnings: Vec<String>,
}

fn comic_template(value: u8) -> Result<ProjectTemplate, EngineError> {
    match value {
        0 => Ok(ProjectTemplate::Illustration),
        1 => Ok(ProjectTemplate::PrintComic),
        2 => Ok(ProjectTemplate::Webtoon),
        _ => Err(EngineError::InvalidCommand(
            "comic template must be 0 (illustration), 1 (print comic), or 2 (webtoon)".into(),
        )),
    }
}

fn comic_project(handle: &ComicProjectHandle) -> Result<&ComicProject, EngineError> {
    handle
        .inner
        .as_ref()
        .ok_or_else(|| EngineError::InvalidCommand("comic project is closed".into()))
}

fn comic_project_mut(handle: &mut ComicProjectHandle) -> Result<&mut ComicProject, EngineError> {
    handle
        .inner
        .as_mut()
        .ok_or_else(|| EngineError::InvalidCommand("comic project is closed".into()))
}

fn studio_project(handle: &StudioProjectHandle) -> Result<&ComicProject, EngineError> {
    handle
        .project
        .as_ref()
        .ok_or_else(|| EngineError::InvalidCommand("studio project is closed".into()))
}

fn studio_project_mut(handle: &mut StudioProjectHandle) -> Result<&mut ComicProject, EngineError> {
    handle
        .project
        .as_mut()
        .ok_or_else(|| EngineError::InvalidCommand("studio project is closed".into()))
}

fn studio_mutate<F>(
    handle: &mut StudioProjectHandle,
    operation: F,
) -> Result<ComicProjectView, EngineError>
where
    F: FnOnce(&mut ComicProject) -> Result<(), ink_comic::ComicError>,
{
    let before = studio_capture_state(handle)?;
    let view = {
        let project = studio_project_mut(handle)?;
        operation(project).map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
        comic_view(project)
    };
    studio_push_history(handle, before);
    Ok(view)
}

fn studio_active_document(handle: &StudioProjectHandle) -> Result<&DocumentHandle, EngineError> {
    let page_id = handle
        .active_page
        .ok_or_else(|| EngineError::InvalidCommand("studio project has no active page".into()))?;
    handle.pages.get(&page_id).ok_or_else(|| {
        EngineError::InvalidCommand("active studio page document is unavailable".into())
    })
}

fn studio_active_document_mut(
    handle: &mut StudioProjectHandle,
) -> Result<&mut DocumentHandle, EngineError> {
    let page_id = handle
        .active_page
        .ok_or_else(|| EngineError::InvalidCommand("studio project has no active page".into()))?;
    handle.pages.get_mut(&page_id).ok_or_else(|| {
        EngineError::InvalidCommand("active studio page document is unavailable".into())
    })
}

fn make_page_document(page: &ink_comic::Page) -> Result<DocumentHandle, EngineError> {
    create_document(
        page.id,
        DocumentSpec {
            width_px: page.spec.width_px,
            height_px: page.spec.height_px,
            dpi: page.spec.dpi,
            color_space: ColorSpace::Srgb,
            background: Rgba8 {
                r: 255,
                g: 255,
                b: 255,
                a: 255,
            },
        },
    )
}

fn make_page_document_from_snapshot(
    snapshot: ink_storage::ProjectSnapshot,
) -> Result<DocumentHandle, EngineError> {
    Ok(new_document_handle(Document::from_snapshot(snapshot)?))
}

/// Ensure every validated comic panel has its deterministic layer tree in the
/// corresponding page document. This runs only at the unified project
/// boundary, so compatibility `ComicProjectHandle` documents are not mutated
/// behind their caller's back.
fn materialize_studio_panel_layers(
    project: &ComicProject,
    pages: &mut BTreeMap<u128, DocumentHandle>,
) -> Result<(), EngineError> {
    for page in &project.pages {
        let Some(document) = pages.get_mut(&page.id) else {
            return Err(EngineError::InvalidCommand(
                "studio panel references an unavailable page document".into(),
            ));
        };
        for panel in &page.panels {
            let binding = project
                .panel_layers
                .iter()
                .find(|binding| binding.panel_id == panel.id)
                .ok_or_else(|| {
                    EngineError::InvalidCommand("studio panel binding is missing".into())
                })?;
            let mask_points = if panel.polygon.len() >= 3 {
                panel
                    .polygon
                    .iter()
                    .flat_map(|(x, y)| [*x, *y])
                    .collect::<Vec<_>>()
            } else {
                vec![
                    panel.bounds.x,
                    panel.bounds.y,
                    panel.bounds.x + panel.bounds.width,
                    panel.bounds.y,
                    panel.bounds.x + panel.bounds.width,
                    panel.bounds.y + panel.bounds.height,
                    panel.bounds.x,
                    panel.bounds.y + panel.bounds.height,
                ]
            };
            let mut document = document_mut(document)?;
            document.create_panel_layer_tree(
                ink_model::LayerId::from_u128(binding.panel_id),
                ink_model::LayerId::from_u128(binding.panel_group_id),
                ink_model::LayerId::from_u128(binding.mask_layer_id),
                ink_model::LayerId::from_u128(binding.sketch_layer_id),
                ink_model::LayerId::from_u128(binding.ink_layer_id),
                ink_model::LayerId::from_u128(binding.color_layer_id),
                ink_model::LayerId::from_u128(binding.tone_layer_id),
                ink_model::LayerId::from_u128(binding.effects_layer_id),
            )?;
            let mask_has_pixels = document
                .layer_has_allocated_tiles(ink_model::LayerId::from_u128(binding.mask_layer_id))?;
            if !mask_has_pixels {
                document.set_panel_mask_geometry(
                    ink_model::LayerId::from_u128(binding.mask_layer_id),
                    mask_points
                        .as_chunks::<2>()
                        .0
                        .iter()
                        .map(|pair| (pair[0], pair[1]))
                        .collect(),
                )?;
            }
        }
    }
    Ok(())
}

#[allow(dead_code)]
fn panel_mask_points(panel: &Panel) -> Vec<(f32, f32)> {
    if panel.polygon.len() >= 3 {
        panel.polygon.clone()
    } else {
        vec![
            (panel.bounds.x, panel.bounds.y),
            (panel.bounds.x + panel.bounds.width, panel.bounds.y),
            (
                panel.bounds.x + panel.bounds.width,
                panel.bounds.y + panel.bounds.height,
            ),
            (panel.bounds.x, panel.bounds.y + panel.bounds.height),
        ]
    }
}

#[allow(dead_code)]
fn studio_panel_binding(
    handle: &StudioProjectHandle,
    page_index: usize,
    panel_id: u128,
) -> Result<(u128, ink_comic::PanelLayerBinding, Panel), EngineError> {
    let project = studio_project(handle)?;
    let page = project
        .pages
        .get(page_index)
        .ok_or_else(|| EngineError::InvalidCommand("page index is outside limits".into()))?;
    let panel = page
        .panels
        .iter()
        .find(|panel| panel.id == panel_id)
        .cloned()
        .ok_or_else(|| EngineError::InvalidCommand("panel is unavailable".into()))?;
    let binding = project
        .panel_layers
        .iter()
        .find(|binding| binding.panel_id == panel_id)
        .cloned()
        .ok_or_else(|| EngineError::InvalidCommand("panel binding is unavailable".into()))?;
    Ok((page.id, binding, panel))
}

#[allow(dead_code)]
fn materialize_and_set_panel_mask(
    document: &mut DocumentHandle,
    binding: &ink_comic::PanelLayerBinding,
    points: Vec<(f32, f32)>,
) -> Result<(), EngineError> {
    let mut document = document_mut(document)?;
    document
        .create_panel_layer_tree(
            ink_model::LayerId::from_u128(binding.panel_id),
            ink_model::LayerId::from_u128(binding.panel_group_id),
            ink_model::LayerId::from_u128(binding.mask_layer_id),
            ink_model::LayerId::from_u128(binding.sketch_layer_id),
            ink_model::LayerId::from_u128(binding.ink_layer_id),
            ink_model::LayerId::from_u128(binding.color_layer_id),
            ink_model::LayerId::from_u128(binding.tone_layer_id),
            ink_model::LayerId::from_u128(binding.effects_layer_id),
        )
        .and_then(|_| {
            document.set_panel_mask_geometry(
                ink_model::LayerId::from_u128(binding.mask_layer_id),
                points,
            )
        })
        .map(|_| ())
}

fn page_document_snapshot(
    handle: &StudioProjectHandle,
    page_id: u128,
) -> Result<ink_storage::ProjectSnapshot, EngineError> {
    let page = handle
        .pages
        .get(&page_id)
        .ok_or_else(|| EngineError::InvalidCommand("page document is unavailable".into()))?;
    Ok(document(page)?.snapshot())
}

fn studio_snapshot_payload_bytes(snapshot: &ink_storage::ProjectSnapshot) -> usize {
    let tile_bytes = snapshot
        .tiles
        .iter()
        .map(|tile| tile.bytes.len())
        .sum::<usize>();
    let vector_bytes = snapshot
        .vectors
        .iter()
        .map(|vector| vector.bytes.len())
        .sum::<usize>();
    let brush_bytes = snapshot.brushes.iter().map(Vec::len).sum::<usize>();
    let resource_bytes = snapshot
        .resources
        .iter()
        .map(|resource| resource.bytes.len())
        .sum::<usize>();
    let history_bytes = snapshot
        .history
        .undo
        .iter()
        .chain(snapshot.history.redo.iter())
        .map(|state| {
            state
                .tiles
                .iter()
                .map(|tile| tile.bytes.len())
                .sum::<usize>()
                + state
                    .vectors
                    .iter()
                    .map(|vector| vector.bytes.len())
                    .sum::<usize>()
        })
        .sum::<usize>();
    tile_bytes
        .saturating_add(vector_bytes)
        .saturating_add(brush_bytes)
        .saturating_add(resource_bytes)
        .saturating_add(history_bytes)
}

fn studio_capture_state(
    handle: &StudioProjectHandle,
) -> Result<StudioProjectHistoryState, EngineError> {
    let mut pages = BTreeMap::new();
    for page_id in handle.pages.keys().copied() {
        pages.insert(page_id, page_document_snapshot(handle, page_id)?);
    }
    let payload_bytes = pages
        .values()
        .map(studio_snapshot_payload_bytes)
        .sum::<usize>();
    if payload_bytes > MAX_STUDIO_HISTORY_STATE_BYTES {
        return Err(EngineError::InvalidCommand(
            "project history checkpoint exceeds the memory limit".into(),
        ));
    }
    Ok(StudioProjectHistoryState {
        project: studio_project(handle)?.clone(),
        pages,
        active_page: handle.active_page,
    })
}

fn studio_push_history(handle: &mut StudioProjectHandle, state: StudioProjectHistoryState) {
    if handle.project_undo.len() >= MAX_STUDIO_PROJECT_HISTORY {
        handle.project_undo.remove(0);
    }
    handle.project_undo.push(state);
    handle.project_redo.clear();
    bound_studio_history_stack(&mut handle.project_undo);
}

fn bound_studio_history_stack(stack: &mut Vec<StudioProjectHistoryState>) {
    let mut total = stack
        .iter()
        .map(StudioProjectHistoryState::payload_bytes)
        .sum::<usize>();
    while (stack.len() > MAX_STUDIO_PROJECT_HISTORY || total > MAX_STUDIO_HISTORY_BYTES)
        && stack.len() > 1
    {
        total = total.saturating_sub(stack.remove(0).payload_bytes());
    }
}

fn studio_restore_state(
    handle: &mut StudioProjectHandle,
    state: StudioProjectHistoryState,
) -> Result<(), EngineError> {
    state
        .project
        .validate()
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    let mut pages = BTreeMap::new();
    for (page_id, snapshot) in state.pages {
        pages.insert(page_id, make_page_document_from_snapshot(snapshot)?);
    }
    for page in &state.project.pages {
        if !pages.contains_key(&page.id) {
            return Err(EngineError::InvalidCommand(
                "project history is missing a page document".into(),
            ));
        }
    }
    handle.project = Some(state.project);
    handle.pages = pages;
    handle.active_page = state.active_page;
    Ok(())
}

fn restore_page_document(
    handle: &mut StudioProjectHandle,
    page_id: u128,
    snapshot: ink_storage::ProjectSnapshot,
) -> Result<(), EngineError> {
    let restored = make_page_document_from_snapshot(snapshot)?;
    handle.pages.insert(page_id, restored);
    Ok(())
}

#[allow(clippy::too_many_lines)]
fn comic_view(project: &ComicProject) -> ComicProjectView {
    ComicProjectView {
        id: project.id,
        template: match project.template {
            ProjectTemplate::Illustration => 0,
            ProjectTemplate::PrintComic => 1,
            ProjectTemplate::Webtoon => 2,
        },
        title: project.title.clone(),
        page_count: u32::try_from(project.pages.len()).unwrap_or(u32::MAX),
        pages: project
            .pages
            .iter()
            .map(|page| ComicPageView {
                id: page.id,
                page_number: page.spec.page_number,
                width_px: page.spec.width_px,
                height_px: page.spec.height_px,
                dpi: page.spec.dpi,
                panel_count: u32::try_from(page.panels.len()).unwrap_or(u32::MAX),
                balloon_count: u32::try_from(page.balloons.len()).unwrap_or(u32::MAX),
                tone_count: u32::try_from(page.tones.len()).unwrap_or(u32::MAX),
                effect_line_count: u32::try_from(page.effect_lines.len()).unwrap_or(u32::MAX),
                panels: page
                    .panels
                    .iter()
                    .map(|panel| {
                        let binding = project
                            .panel_layers
                            .iter()
                            .find(|binding| binding.panel_id == panel.id);
                        ComicPanelPreviewView {
                            id: panel.id,
                            shape: match panel.shape {
                                PanelShape::Rectangle => 0,
                                PanelShape::Polygon => 1,
                            },
                            x: panel.bounds.x,
                            y: panel.bounds.y,
                            width: panel.bounds.width,
                            height: panel.bounds.height,
                            gutter_px: panel.gutter_px,
                            mask_layer_id: binding
                                .map(|value| value.mask_layer_id)
                                .or(panel.mask_layer_id),
                            panel_group_id: binding.map(|value| value.panel_group_id),
                            sketch_layer_id: binding.map(|value| value.sketch_layer_id),
                            ink_layer_id: binding.map(|value| value.ink_layer_id),
                            color_layer_id: binding.map(|value| value.color_layer_id),
                            tone_layer_id: binding.map(|value| value.tone_layer_id),
                            effects_layer_id: binding.map(|value| value.effects_layer_id),
                            polygon: panel.polygon.iter().flat_map(|(x, y)| [*x, *y]).collect(),
                        }
                    })
                    .collect(),
                balloons: page
                    .balloons
                    .iter()
                    .map(|balloon| ComicBalloonPreviewView {
                        id: balloon.id,
                        shape: match balloon.shape {
                            BalloonShape::Oval => 0,
                            BalloonShape::Thought => 1,
                            BalloonShape::Narration => 2,
                            BalloonShape::Burst => 3,
                        },
                        x: balloon.bounds.x,
                        y: balloon.bounds.y,
                        width: balloon.bounds.width,
                        height: balloon.bounds.height,
                        panel_id: balloon.panel_id,
                        text: balloon.text.clone(),
                        font_family: balloon.style.font_family.clone(),
                        font_size_px: balloon.style.font_size_px,
                        outline_px: balloon.style.outline_px,
                        orientation: match balloon.style.orientation {
                            ink_comic::TextOrientation::Horizontal => 0,
                            ink_comic::TextOrientation::Vertical => 1,
                        },
                        tail: balloon.tail.iter().flat_map(|(x, y)| [*x, *y]).collect(),
                    })
                    .collect(),
                tones: page
                    .tones
                    .iter()
                    .map(|tone| ComicTonePreviewView {
                        id: tone.id,
                        frequency_lpi: tone.frequency_lpi,
                        angle_degrees: tone.angle_degrees,
                        density: tone.density,
                        shape: tone.shape.clone(),
                        x: tone.bounds.x,
                        y: tone.bounds.y,
                        width: tone.bounds.width,
                        height: tone.bounds.height,
                    })
                    .collect(),
                effect_lines: page
                    .effect_lines
                    .iter()
                    .map(|line| ComicEffectLinePreviewView {
                        id: line.id,
                        kind: line.kind.clone(),
                        points: line.points.iter().flat_map(|(x, y)| [*x, *y]).collect(),
                        width_px: line.width_px,
                        opacity: line.opacity,
                    })
                    .collect(),
                bleed_left: page.spec.bleed_px.left,
                bleed_top: page.spec.bleed_px.top,
                bleed_right: page.spec.bleed_px.right,
                bleed_bottom: page.spec.bleed_px.bottom,
                trim_x: page.spec.trim.x,
                trim_y: page.spec.trim.y,
                trim_width: page.spec.trim.width,
                trim_height: page.spec.trim.height,
                safety_left: page.spec.safety.left,
                safety_top: page.spec.safety.top,
                safety_right: page.spec.safety.right,
                safety_bottom: page.spec.safety.bottom,
            })
            .collect(),
        materials: project
            .materials
            .iter()
            .map(|material| ComicMaterialView {
                id: material.id,
                name: material.name.clone(),
                kind: material.kind.clone(),
                license: material.license.clone(),
                attribution: material.attribution.clone(),
                source: material.source.clone(),
            })
            .collect(),
    }
}

/// Create an empty comic project with a validated template and title.
pub fn create_comic_project(
    id: u128,
    template: u8,
    title: String,
) -> Result<ComicProjectHandle, EngineError> {
    let template = comic_template(template)?;
    let project = ComicProject::new(id, template, title);
    project
        .validate()
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    Ok(ComicProjectHandle {
        inner: Some(project),
    })
}

/// Return a deterministic eight-page stick-figure example for acceptance and
/// first-run onboarding.
pub fn create_xkcd_stick_figure_comic() -> ComicProjectHandle {
    ComicProjectHandle {
        inner: Some(ink_comic::xkcd_stick_figure_comic()),
    }
}

/// Create a unified project with one active, Rust-owned page document.
pub fn create_studio_project(
    project_id: u128,
    template: u8,
    title: String,
    page_id: u128,
    width_px: u32,
    height_px: u32,
    dpi: f32,
) -> Result<StudioProjectHandle, EngineError> {
    let template = comic_template(template)?;
    let mut project = ComicProject::new(project_id, template, title);
    let page = ink_comic::print_page(width_px, height_px, dpi, 1, page_id);
    let document = make_page_document(&page)?;
    project
        .add_page(page)
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    Ok(StudioProjectHandle {
        project: Some(project),
        pages: BTreeMap::from([(page_id, document)]),
        active_page: Some(page_id),
        project_undo: Vec::new(),
        project_redo: Vec::new(),
    })
}

fn studio_from_project(project: ComicProject) -> Result<StudioProjectHandle, EngineError> {
    project
        .validate()
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    let mut pages = BTreeMap::new();
    for page in &project.pages {
        pages.insert(page.id, make_page_document(page)?);
    }
    materialize_studio_panel_layers(&project, &mut pages)?;
    let active_page = project.pages.first().map(|page| page.id);
    Ok(StudioProjectHandle {
        project: Some(project),
        pages,
        active_page,
        project_undo: Vec::new(),
        project_redo: Vec::new(),
    })
}

/// Create a unified project from canonical comic metadata. Page documents are
/// created and panel trees/masks are materialized before the handle is exposed.
pub fn create_studio_project_from_json(bytes: Vec<u8>) -> Result<StudioProjectHandle, EngineError> {
    let project = ComicProject::from_json(&bytes)
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    studio_from_project(project)
}

/// Return the deterministic comic fixture behind one unified project handle.
pub fn create_studio_xkcd_stick_figure_project() -> Result<StudioProjectHandle, EngineError> {
    studio_from_project(ink_comic::xkcd_stick_figure_comic())
}

/// Open a v2 multi-page project and materialize its page documents under one
/// opaque handle. Source files remain untouched during this operation.
pub fn open_studio_project(path: String) -> Result<StudioProjectHandle, EngineError> {
    let snapshot = ink_storage::load_studio_project(std::path::Path::new(&path))
        .map_err(|error| EngineError::InvalidCommand(format!("studio open failed: {error}")))?;
    let project = ComicProject::from_json(&snapshot.comic)
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    let mut pages = BTreeMap::new();
    for page in snapshot.pages {
        pages.insert(
            page.page_id,
            make_page_document_from_snapshot(page.snapshot)?,
        );
    }
    materialize_studio_panel_layers(&project, &mut pages)?;
    let active_page = project.pages.first().map(|page| page.id);
    Ok(StudioProjectHandle {
        project: Some(project),
        pages,
        active_page,
        project_undo: Vec::new(),
        project_redo: Vec::new(),
    })
}

/// Return the immutable comic projection for a unified project.
pub fn project_snapshot(handle: &StudioProjectHandle) -> Result<ComicProjectView, EngineError> {
    Ok(comic_view(studio_project(handle)?))
}

/// Undo the latest project-manager structural edit while preserving each
/// page's raster/vector document snapshot. Drawing commands continue to use
/// the active page document's own undo timeline.
pub fn undo_project(handle: &mut StudioProjectHandle) -> Result<ComicProjectView, EngineError> {
    let Some(target) = handle.project_undo.pop() else {
        return Err(EngineError::InvalidCommand(
            "project undo stack is empty".into(),
        ));
    };
    let current = studio_capture_state(handle)?;
    if let Err(error) = studio_restore_state(handle, target.clone()) {
        handle.project_undo.push(target);
        return Err(error);
    }
    if handle.project_redo.len() >= MAX_STUDIO_PROJECT_HISTORY {
        handle.project_redo.remove(0);
    }
    handle.project_redo.push(current);
    bound_studio_history_stack(&mut handle.project_redo);
    Ok(comic_view(studio_project(handle)?))
}

/// Redo a project-manager structural edit.
pub fn redo_project(handle: &mut StudioProjectHandle) -> Result<ComicProjectView, EngineError> {
    let Some(target) = handle.project_redo.pop() else {
        return Err(EngineError::InvalidCommand(
            "project redo stack is empty".into(),
        ));
    };
    let current = studio_capture_state(handle)?;
    if let Err(error) = studio_restore_state(handle, target.clone()) {
        handle.project_redo.push(target);
        return Err(error);
    }
    if handle.project_undo.len() >= MAX_STUDIO_PROJECT_HISTORY {
        handle.project_undo.remove(0);
    }
    handle.project_undo.push(current);
    bound_studio_history_stack(&mut handle.project_undo);
    Ok(comic_view(studio_project(handle)?))
}

pub fn project_can_undo(handle: &StudioProjectHandle) -> bool {
    !handle.project_undo.is_empty()
}

pub fn project_can_redo(handle: &StudioProjectHandle) -> bool {
    !handle.project_redo.is_empty()
}

/// Activate a page without creating an undo entry. The page must already have
/// a validated document owned by this project handle.
pub fn activate_page(handle: &mut StudioProjectHandle, page_id: u128) -> Result<u64, EngineError> {
    studio_project(handle)?
        .pages
        .iter()
        .find(|page| page.id == page_id)
        .ok_or_else(|| EngineError::InvalidCommand("unknown studio page".into()))?;
    if !handle.pages.contains_key(&page_id) {
        return Err(EngineError::InvalidCommand(
            "studio page document is unavailable".into(),
        ));
    }
    handle.active_page = Some(page_id);
    revision(studio_active_document(handle)?)
}

/// Return a shared handle for the active page document. The returned handle
/// is a cheap capability view into the same Rust-owned document; mutations
/// through it are immediately visible to project snapshots, saves, and page
/// activation. It does not create a second document authority.
pub fn project_active_document(
    handle: &StudioProjectHandle,
) -> Result<DocumentHandle, EngineError> {
    Ok(studio_active_document(handle)?.clone())
}

/// Add a blank page and its document atomically to the project boundary.
pub fn add_project_page(
    handle: &mut StudioProjectHandle,
    page_id: u128,
    width_px: u32,
    height_px: u32,
    dpi: f32,
) -> Result<ComicProjectView, EngineError> {
    if handle.pages.contains_key(&page_id) {
        return Err(EngineError::InvalidCommand(
            "duplicate studio page ID".into(),
        ));
    }
    let before = studio_capture_state(handle)?;
    let page_number =
        u32::try_from(studio_project(handle)?.pages.len().saturating_add(1)).unwrap_or(u32::MAX);
    let page = ink_comic::print_page(width_px, height_px, dpi, page_number, page_id);
    let document = make_page_document(&page)?;
    studio_project_mut(handle)?
        .add_page(page)
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    handle.pages.insert(page_id, document);
    studio_push_history(handle, before);
    Ok(comic_view(studio_project(handle)?))
}

/// Add a panel and its conventional layer tree through the unified project
/// boundary. Metadata and page-document layers are rolled back together if
/// materialization fails.
#[allow(clippy::too_many_arguments)]
pub fn add_project_panel(
    handle: &mut StudioProjectHandle,
    page_index: u32,
    panel_id: u128,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    gutter_px: f32,
) -> Result<ComicProjectView, EngineError> {
    let page_index = usize::try_from(page_index)
        .map_err(|_| EngineError::InvalidCommand("page index is outside limits".into()))?;
    let page_id = studio_project(handle)?
        .pages
        .get(page_index)
        .ok_or_else(|| EngineError::InvalidCommand("page index is outside limits".into()))?
        .id;
    let before = studio_capture_state(handle)?;
    let prior_document = page_document_snapshot(handle, page_id)?;
    let old_project = studio_project(handle)?.clone();
    studio_project_mut(handle)?
        .add_panel(
            page_index,
            Panel {
                id: panel_id,
                shape: PanelShape::Rectangle,
                bounds: Rect {
                    x,
                    y,
                    width,
                    height,
                },
                polygon: Vec::new(),
                gutter_px,
                mask_layer_id: None,
            },
        )
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    let page_id = studio_project(handle)?.pages[page_index].id;
    let binding = studio_project(handle)?
        .panel_layers
        .iter()
        .find(|binding| binding.panel_id == panel_id)
        .ok_or_else(|| EngineError::InvalidCommand("panel binding was not created".into()))?
        .clone();
    let panel = studio_project(handle)?.pages[page_index]
        .panels
        .iter()
        .find(|panel| panel.id == panel_id)
        .ok_or_else(|| EngineError::InvalidCommand("panel was not created".into()))?;
    let mask_points = [
        panel.bounds.x,
        panel.bounds.y,
        panel.bounds.x + panel.bounds.width,
        panel.bounds.y,
        panel.bounds.x + panel.bounds.width,
        panel.bounds.y + panel.bounds.height,
        panel.bounds.x,
        panel.bounds.y + panel.bounds.height,
    ];
    let result = {
        let page_document = handle
            .pages
            .get_mut(&page_id)
            .ok_or_else(|| EngineError::InvalidCommand("page document is unavailable".into()))?;
        let mut document = document_mut(page_document)?;
        document
            .create_panel_layer_tree(
                ink_model::LayerId::from_u128(binding.panel_id),
                ink_model::LayerId::from_u128(binding.panel_group_id),
                ink_model::LayerId::from_u128(binding.mask_layer_id),
                ink_model::LayerId::from_u128(binding.sketch_layer_id),
                ink_model::LayerId::from_u128(binding.ink_layer_id),
                ink_model::LayerId::from_u128(binding.color_layer_id),
                ink_model::LayerId::from_u128(binding.tone_layer_id),
                ink_model::LayerId::from_u128(binding.effects_layer_id),
            )
            .and_then(|_| {
                document.set_panel_mask_geometry(
                    ink_model::LayerId::from_u128(binding.mask_layer_id),
                    mask_points
                        .as_chunks::<2>()
                        .0
                        .iter()
                        .map(|pair| (pair[0], pair[1]))
                        .collect(),
                )
            })
    };
    if let Err(error) = result {
        *studio_project_mut(handle)? = old_project;
        restore_page_document(handle, page_id, prior_document)?;
        return Err(error);
    }
    studio_push_history(handle, before);
    Ok(comic_view(studio_project(handle)?))
}

/// Resize a rectangular panel and update the authoritative page-document mask
/// in the same project boundary. Existing pixels remain in their layer tree;
/// only the generated stencil geometry changes.
#[allow(dead_code)]
pub fn set_project_panel_bounds(
    handle: &mut StudioProjectHandle,
    page_index: u32,
    panel_id: u128,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
) -> Result<ComicProjectView, EngineError> {
    let page_index = usize::try_from(page_index)
        .map_err(|_| EngineError::InvalidCommand("page index is outside limits".into()))?;
    let page_id = studio_project(handle)?
        .pages
        .get(page_index)
        .ok_or_else(|| EngineError::InvalidCommand("page index is outside limits".into()))?
        .id;
    let before = studio_capture_state(handle)?;
    let prior_document = page_document_snapshot(handle, page_id)?;
    let old_project = studio_project(handle)?.clone();
    studio_project_mut(handle)?
        .set_panel_bounds(
            page_index,
            panel_id,
            Rect {
                x,
                y,
                width,
                height,
            },
        )
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    let (_, binding, panel) = match studio_panel_binding(handle, page_index, panel_id) {
        Ok(value) => value,
        Err(error) => {
            *studio_project_mut(handle)? = old_project;
            restore_page_document(handle, page_id, prior_document)?;
            return Err(error);
        }
    };
    let result = handle
        .pages
        .get_mut(&page_id)
        .ok_or_else(|| EngineError::InvalidCommand("page document is unavailable".into()))
        .and_then(|document| {
            materialize_and_set_panel_mask(document, &binding, panel_mask_points(&panel))
        });
    if let Err(error) = result {
        *studio_project_mut(handle)? = old_project;
        restore_page_document(handle, page_id, prior_document)?;
        return Err(error);
    }
    studio_push_history(handle, before);
    Ok(comic_view(studio_project(handle)?))
}

/// Replace a panel polygon and its generated page-document mask atomically.
#[allow(dead_code)]
pub fn set_project_panel_polygon(
    handle: &mut StudioProjectHandle,
    page_index: u32,
    panel_id: u128,
    points: Vec<f32>,
) -> Result<ComicProjectView, EngineError> {
    if points.len() < 6 || points.len() > 128 || !points.len().is_multiple_of(2) {
        return Err(EngineError::InvalidCommand(
            "panel polygon must contain 3 to 64 points".into(),
        ));
    }
    if points.iter().any(|value| !value.is_finite()) {
        return Err(EngineError::InvalidCommand(
            "panel polygon contains a non-finite coordinate".into(),
        ));
    }
    let polygon = points
        .as_chunks::<2>()
        .0
        .iter()
        .map(|pair| (pair[0], pair[1]))
        .collect::<Vec<_>>();
    let page_index = usize::try_from(page_index)
        .map_err(|_| EngineError::InvalidCommand("page index is outside limits".into()))?;
    let page_id = studio_project(handle)?
        .pages
        .get(page_index)
        .ok_or_else(|| EngineError::InvalidCommand("page index is outside limits".into()))?
        .id;
    let before = studio_capture_state(handle)?;
    let prior_document = page_document_snapshot(handle, page_id)?;
    let old_project = studio_project(handle)?.clone();
    studio_project_mut(handle)?
        .set_panel_polygon(page_index, panel_id, polygon)
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    let (_, binding, panel) = match studio_panel_binding(handle, page_index, panel_id) {
        Ok(value) => value,
        Err(error) => {
            *studio_project_mut(handle)? = old_project;
            restore_page_document(handle, page_id, prior_document)?;
            return Err(error);
        }
    };
    let result = handle
        .pages
        .get_mut(&page_id)
        .ok_or_else(|| EngineError::InvalidCommand("page document is unavailable".into()))
        .and_then(|document| {
            materialize_and_set_panel_mask(document, &binding, panel_mask_points(&panel))
        });
    if let Err(error) = result {
        *studio_project_mut(handle)? = old_project;
        restore_page_document(handle, page_id, prior_document)?;
        return Err(error);
    }
    studio_push_history(handle, before);
    Ok(comic_view(studio_project(handle)?))
}

/// Split a rectangular panel and materialize the new child mask while
/// preserving the original document-layer binding for the first child.
#[allow(dead_code)]
pub fn split_project_panel(
    handle: &mut StudioProjectHandle,
    page_index: u32,
    panel_id: u128,
    first_id: u128,
    second_id: u128,
    axis: u8,
    ratio: f32,
) -> Result<ComicProjectView, EngineError> {
    let page_index = usize::try_from(page_index)
        .map_err(|_| EngineError::InvalidCommand("page index is outside limits".into()))?;
    let page_id = studio_project(handle)?
        .pages
        .get(page_index)
        .ok_or_else(|| EngineError::InvalidCommand("page index is outside limits".into()))?
        .id;
    let before = studio_capture_state(handle)?;
    let prior_document = page_document_snapshot(handle, page_id)?;
    let old_project = studio_project(handle)?.clone();
    studio_project_mut(handle)?
        .split_panel(page_index, panel_id, first_id, second_id, axis, ratio)
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    let Some(page) = studio_project(handle)?.pages.get(page_index) else {
        *studio_project_mut(handle)? = old_project;
        restore_page_document(handle, page_id, prior_document)?;
        return Err(EngineError::InvalidCommand(
            "page index is outside limits".into(),
        ));
    };
    let Some(first) = page
        .panels
        .iter()
        .find(|panel| panel.id == first_id)
        .cloned()
    else {
        *studio_project_mut(handle)? = old_project;
        restore_page_document(handle, page_id, prior_document)?;
        return Err(EngineError::InvalidCommand(
            "first split panel is unavailable".into(),
        ));
    };
    let Some(second) = page
        .panels
        .iter()
        .find(|panel| panel.id == second_id)
        .cloned()
    else {
        *studio_project_mut(handle)? = old_project;
        restore_page_document(handle, page_id, prior_document)?;
        return Err(EngineError::InvalidCommand(
            "second split panel is unavailable".into(),
        ));
    };
    let Some(first_binding) = studio_project(handle)?
        .panel_layers
        .iter()
        .find(|binding| binding.panel_id == first_id)
        .cloned()
    else {
        *studio_project_mut(handle)? = old_project;
        restore_page_document(handle, page_id, prior_document)?;
        return Err(EngineError::InvalidCommand(
            "first split binding is unavailable".into(),
        ));
    };
    let Some(second_binding) = studio_project(handle)?
        .panel_layers
        .iter()
        .find(|binding| binding.panel_id == second_id)
        .cloned()
    else {
        *studio_project_mut(handle)? = old_project;
        restore_page_document(handle, page_id, prior_document)?;
        return Err(EngineError::InvalidCommand(
            "second split binding is unavailable".into(),
        ));
    };
    let result = handle
        .pages
        .get_mut(&page_id)
        .ok_or_else(|| EngineError::InvalidCommand("page document is unavailable".into()))
        .and_then(|document| {
            materialize_and_set_panel_mask(document, &first_binding, panel_mask_points(&first))?;
            materialize_and_set_panel_mask(document, &second_binding, panel_mask_points(&second))
        });
    if let Err(error) = result {
        *studio_project_mut(handle)? = old_project;
        restore_page_document(handle, page_id, prior_document)?;
        return Err(error);
    }
    studio_push_history(handle, before);
    Ok(comic_view(studio_project(handle)?))
}

pub fn studio_reorder_page(
    handle: &mut StudioProjectHandle,
    from: u32,
    to: u32,
) -> Result<ComicProjectView, EngineError> {
    studio_mutate(handle, |project| {
        project.reorder_page(from as usize, to as usize)
    })
}

/// Remove a page and its document as one undoable project mutation. The
/// project always retains one page; removing the active page activates the
/// nearest remaining page, while removing another page preserves selection.
pub fn studio_remove_page(
    handle: &mut StudioProjectHandle,
    page_index: u32,
) -> Result<ComicProjectView, EngineError> {
    let index = usize::try_from(page_index)
        .map_err(|_| EngineError::InvalidCommand("page index is outside limits".into()))?;
    let removed_id = studio_project(handle)?
        .pages
        .get(index)
        .map(|page| page.id)
        .ok_or_else(|| EngineError::InvalidCommand("page index is outside limits".into()))?;
    let before = studio_capture_state(handle)?;
    studio_project_mut(handle)?
        .remove_page(index)
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    handle.pages.remove(&removed_id);
    if handle.active_page == Some(removed_id) {
        let project = studio_project(handle)?;
        let next_index = index.min(project.pages.len() - 1);
        handle.active_page = Some(project.pages[next_index].id);
    }
    studio_push_history(handle, before);
    Ok(comic_view(studio_project(handle)?))
}

#[allow(clippy::too_many_arguments)]
pub fn studio_set_page_layout(
    handle: &mut StudioProjectHandle,
    page_index: u32,
    dpi: f32,
    bleed_left: f32,
    bleed_top: f32,
    bleed_right: f32,
    bleed_bottom: f32,
    trim_x: f32,
    trim_y: f32,
    trim_width: f32,
    trim_height: f32,
    safety_left: f32,
    safety_top: f32,
    safety_right: f32,
    safety_bottom: f32,
) -> Result<ComicProjectView, EngineError> {
    studio_mutate(handle, |project| {
        project.set_page_layout(
            page_index as usize,
            dpi,
            ink_comic::Insets {
                left: bleed_left,
                top: bleed_top,
                right: bleed_right,
                bottom: bleed_bottom,
            },
            ink_comic::Rect {
                x: trim_x,
                y: trim_y,
                width: trim_width,
                height: trim_height,
            },
            ink_comic::Insets {
                left: safety_left,
                top: safety_top,
                right: safety_right,
                bottom: safety_bottom,
            },
        )
    })
}

pub fn studio_resize_gutter(
    handle: &mut StudioProjectHandle,
    page_index: u32,
    panel_id: u128,
    gutter_px: f32,
) -> Result<ComicProjectView, EngineError> {
    studio_mutate(handle, |project| {
        project.resize_gutter(page_index as usize, panel_id, gutter_px)
    })
}

#[allow(clippy::too_many_arguments)]
#[allow(clippy::needless_pass_by_value)]
pub fn studio_add_styled_balloon(
    handle: &mut StudioProjectHandle,
    page_index: u32,
    balloon_id: u128,
    panel_id: Option<u128>,
    shape: u8,
    tail: Vec<f32>,
    orientation: u8,
    font_family: String,
    font_size_px: f32,
    outline_px: f32,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    text: String,
) -> Result<ComicProjectView, EngineError> {
    let shape = match shape {
        0 => BalloonShape::Oval,
        1 => BalloonShape::Thought,
        2 => BalloonShape::Narration,
        3 => BalloonShape::Burst,
        _ => return Err(EngineError::InvalidCommand("unknown balloon shape".into())),
    };
    let orientation = match orientation {
        0 => TextOrientation::Horizontal,
        1 => TextOrientation::Vertical,
        _ => {
            return Err(EngineError::InvalidCommand(
                "unknown text orientation".into(),
            ));
        }
    };
    if !tail.len().is_multiple_of(2) {
        return Err(EngineError::InvalidCommand(
            "balloon tail requires coordinate pairs".into(),
        ));
    }
    let tail = tail
        .as_chunks::<2>()
        .0
        .iter()
        .map(|pair| (pair[0], pair[1]))
        .collect::<Vec<_>>();
    studio_mutate(handle, |project| {
        project.add_balloon(
            page_index as usize,
            Balloon {
                id: balloon_id,
                shape,
                bounds: Rect {
                    x,
                    y,
                    width,
                    height,
                },
                tail,
                text,
                style: TextStyle {
                    font_family,
                    font_size_px,
                    outline_px,
                    orientation,
                    ..TextStyle::default()
                },
                panel_id,
            },
        )
    })
}

pub fn studio_add_material(
    handle: &mut StudioProjectHandle,
    material_id: u128,
    name: String,
    kind: String,
    license: String,
    attribution: Option<String>,
    source: Option<String>,
) -> Result<ComicProjectView, EngineError> {
    studio_mutate(handle, |project| {
        project.add_material(MaterialAsset {
            id: material_id,
            name,
            kind,
            license,
            attribution,
            source,
        })
    })
}

pub fn studio_remove_material(
    handle: &mut StudioProjectHandle,
    material_id: u128,
) -> Result<ComicProjectView, EngineError> {
    studio_mutate(handle, |project| project.remove_material(material_id))
}

#[allow(clippy::too_many_arguments)]
pub fn studio_add_tone(
    handle: &mut StudioProjectHandle,
    page_index: u32,
    tone_id: u128,
    frequency_lpi: f32,
    angle_degrees: f32,
    density: f32,
    shape: String,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
) -> Result<ComicProjectView, EngineError> {
    studio_mutate(handle, |project| {
        project.add_tone(
            page_index as usize,
            ToneLayer {
                id: tone_id,
                frequency_lpi,
                angle_degrees,
                density,
                shape,
                bounds: Rect {
                    x,
                    y,
                    width,
                    height,
                },
            },
        )
    })
}

#[allow(clippy::too_many_arguments)]
pub fn studio_set_tone(
    handle: &mut StudioProjectHandle,
    page_index: u32,
    tone_id: u128,
    frequency_lpi: f32,
    angle_degrees: f32,
    density: f32,
    shape: String,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
) -> Result<ComicProjectView, EngineError> {
    studio_mutate(handle, |project| {
        project.set_tone(
            page_index as usize,
            tone_id,
            ToneLayer {
                id: tone_id,
                frequency_lpi,
                angle_degrees,
                density,
                shape,
                bounds: Rect {
                    x,
                    y,
                    width,
                    height,
                },
            },
        )
    })
}

pub fn studio_remove_tone(
    handle: &mut StudioProjectHandle,
    page_index: u32,
    tone_id: u128,
) -> Result<ComicProjectView, EngineError> {
    studio_mutate(handle, |project| {
        project.remove_tone(page_index as usize, tone_id)
    })
}

#[allow(clippy::too_many_arguments)]
#[allow(clippy::needless_pass_by_value)]
pub fn studio_add_effect_line(
    handle: &mut StudioProjectHandle,
    page_index: u32,
    effect_id: u128,
    kind: String,
    points: Vec<f32>,
    width_px: f32,
    opacity: f32,
) -> Result<ComicProjectView, EngineError> {
    if points.len() < 4 || !points.len().is_multiple_of(2) {
        return Err(EngineError::InvalidCommand(
            "effect line requires at least two coordinate pairs".into(),
        ));
    }
    let points = points
        .as_chunks::<2>()
        .0
        .iter()
        .map(|pair| (pair[0], pair[1]))
        .collect::<Vec<_>>();
    studio_mutate(handle, |project| {
        project.add_effect_line(
            page_index as usize,
            EffectLine {
                id: effect_id,
                kind,
                points,
                width_px,
                opacity,
            },
        )
    })
}

#[allow(clippy::too_many_arguments)]
#[allow(clippy::needless_pass_by_value)]
pub fn studio_set_effect_line(
    handle: &mut StudioProjectHandle,
    page_index: u32,
    effect_id: u128,
    kind: String,
    points: Vec<f32>,
    width_px: f32,
    opacity: f32,
) -> Result<ComicProjectView, EngineError> {
    if points.len() < 4 || !points.len().is_multiple_of(2) {
        return Err(EngineError::InvalidCommand(
            "effect line requires at least two coordinate pairs".into(),
        ));
    }
    let points = points
        .as_chunks::<2>()
        .0
        .iter()
        .map(|pair| (pair[0], pair[1]))
        .collect::<Vec<_>>();
    studio_mutate(handle, |project| {
        project.set_effect_line(
            page_index as usize,
            effect_id,
            EffectLine {
                id: effect_id,
                kind,
                points,
                width_px,
                opacity,
            },
        )
    })
}

pub fn studio_remove_effect_line(
    handle: &mut StudioProjectHandle,
    page_index: u32,
    effect_id: u128,
) -> Result<ComicProjectView, EngineError> {
    studio_mutate(handle, |project| {
        project.remove_effect_line(page_index as usize, effect_id)
    })
}

pub fn studio_set_dialogue(
    handle: &mut StudioProjectHandle,
    page_index: u32,
    balloon_id: u128,
    text: String,
) -> Result<ComicProjectView, EngineError> {
    studio_mutate(handle, |project| {
        project.set_dialogue(page_index as usize, balloon_id, text)
    })
}

pub fn studio_set_balloon_tail(
    handle: &mut StudioProjectHandle,
    page_index: u32,
    balloon_id: u128,
    points: Vec<f32>,
) -> Result<ComicProjectView, EngineError> {
    if !points.len().is_multiple_of(2) {
        return Err(EngineError::InvalidCommand(
            "balloon tail requires coordinate pairs".into(),
        ));
    }
    let tail = points
        .as_chunks::<2>()
        .0
        .iter()
        .map(|pair| (pair[0], pair[1]))
        .collect::<Vec<_>>();
    studio_mutate(handle, |project| {
        project.set_balloon_tail(page_index as usize, balloon_id, tail)
    })
}

#[allow(clippy::too_many_arguments)]
#[allow(clippy::needless_pass_by_value)]
pub fn studio_set_balloon_style(
    handle: &mut StudioProjectHandle,
    page_index: u32,
    balloon_id: u128,
    font_family: String,
    font_size_px: f32,
    outline_px: f32,
    orientation: u8,
) -> Result<ComicProjectView, EngineError> {
    let orientation = match orientation {
        0 => TextOrientation::Horizontal,
        1 => TextOrientation::Vertical,
        _ => {
            return Err(EngineError::InvalidCommand(
                "unknown text orientation".into(),
            ));
        }
    };
    studio_mutate(handle, |project| {
        let existing = project
            .pages
            .get(page_index as usize)
            .and_then(|page| {
                page.balloons
                    .iter()
                    .find(|balloon| balloon.id == balloon_id)
            })
            .ok_or(ink_comic::ComicError::DanglingReference)?;
        project.set_balloon_style(
            page_index as usize,
            balloon_id,
            TextStyle {
                font_family,
                font_size_px,
                outline_px,
                orientation,
                fill_rgba: existing.style.fill_rgba,
                outline_rgba: existing.style.outline_rgba,
            },
        )
    })
}

pub fn studio_search_dialogue(
    handle: &StudioProjectHandle,
    query: String,
) -> Result<Vec<ComicDialogueHitView>, EngineError> {
    Ok(studio_project(handle)?
        .search_dialogue(&query)
        .into_iter()
        .map(|hit| ComicDialogueHitView {
            page_index: u32::try_from(hit.page_index).unwrap_or(u32::MAX),
            balloon_id: hit.balloon_id,
            match_start: u32::try_from(hit.match_start).unwrap_or(u32::MAX),
            match_end: u32::try_from(hit.match_end).unwrap_or(u32::MAX),
        })
        .collect())
}

pub fn studio_webtoon_segments(
    handle: &StudioProjectHandle,
    page_index: u32,
    max_height_px: u32,
) -> Result<Vec<ComicWebtoonSegmentView>, EngineError> {
    Ok(studio_project(handle)?
        .webtoon_segments(page_index as usize, max_height_px)
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?
        .into_iter()
        .map(|segment| ComicWebtoonSegmentView {
            page_index: u32::try_from(segment.page_index).unwrap_or(u32::MAX),
            segment_index: u32::try_from(segment.segment_index).unwrap_or(u32::MAX),
            source_y: segment.source_y,
            height_px: segment.height_px,
        })
        .collect())
}

pub fn studio_print_preview_report(
    handle: &StudioProjectHandle,
) -> Result<ComicPrintPreviewView, EngineError> {
    let report = studio_project(handle)?
        .print_preview_report()
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    Ok(ComicPrintPreviewView {
        page_count: u32::try_from(report.page_count).unwrap_or(u32::MAX),
        bleed_safe: report.bleed_safe,
        safety_safe: report.safety_safe,
        moire_warnings: report.moire_warnings,
    })
}

pub fn studio_render_page_preview(
    handle: &StudioProjectHandle,
    page_index: u32,
    max_dimension: u32,
) -> Result<Vec<u8>, EngineError> {
    let preview = studio_project(handle)?
        .render_page_preview(page_index as usize, max_dimension)
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    ink_export::encode_png(preview.width, preview.height, &preview.pixels_rgba)
        .map_err(|error| EngineError::InvalidCommand(format!("preview PNG failed: {error}")))
}

pub fn studio_project_to_json(handle: &StudioProjectHandle) -> Result<Vec<u8>, EngineError> {
    studio_project(handle)?
        .to_json()
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))
}

pub fn studio_project_portable_digest(handle: &StudioProjectHandle) -> Result<String, EngineError> {
    let digest = studio_project(handle)?
        .portable_render_digest()
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    let mut output = String::with_capacity(digest.len() * 2);
    for byte in digest {
        write!(&mut output, "{byte:02x}")
            .map_err(|_| EngineError::InvalidCommand("digest formatting failed".into()))?;
    }
    Ok(output)
}

pub fn studio_batch_export_page_manifests(
    handle: &StudioProjectHandle,
    directory: String,
) -> Result<u32, EngineError> {
    let count = studio_project(handle)?
        .batch_export_page_manifests(std::path::Path::new(&directory))
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    Ok(u32::try_from(count).unwrap_or(u32::MAX))
}

#[allow(clippy::too_many_lines)]
pub fn studio_batch_export_pages(
    handle: &StudioProjectHandle,
    directory: String,
) -> Result<u32, EngineError> {
    // A unified project owns both comic structure and its page documents.
    // Export page artwork as PNG plus a self-contained composited SVG with
    // vector comic structure/lettering above the actual raster page.
    let directory = PathBuf::from(directory);
    if directory.as_os_str().is_empty() {
        return Err(EngineError::InvalidCommand(
            "comic export directory is empty".into(),
        ));
    }
    if let Ok(metadata) = std::fs::symlink_metadata(&directory)
        && (metadata.file_type().is_symlink() || !metadata.is_dir())
    {
        return Err(EngineError::InvalidCommand(
            "comic export destination must be a real directory".into(),
        ));
    }
    std::fs::create_dir_all(&directory)
        .map_err(|error| EngineError::InvalidCommand(format!("comic export failed: {error}")))?;
    let directory_metadata = std::fs::symlink_metadata(&directory)
        .map_err(|error| EngineError::InvalidCommand(format!("comic export failed: {error}")))?;
    if directory_metadata.file_type().is_symlink() || !directory_metadata.is_dir() {
        return Err(EngineError::InvalidCommand(
            "comic export destination must be a real directory".into(),
        ));
    }

    let project = studio_project(handle)?;
    let export_nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |duration| duration.as_nanos());
    let mut staged = Vec::with_capacity(project.pages.len());
    for (index, _) in project.pages.iter().enumerate() {
        let png_name = format!("page-{:04}.png", index + 1);
        let svg_name = format!("page-{:04}.svg", index + 1);
        let png_destination = directory.join(&png_name);
        let svg_destination = directory.join(&svg_name);
        for destination in [&png_destination, &svg_destination] {
            match std::fs::symlink_metadata(destination) {
                Ok(_) => {
                    return Err(EngineError::InvalidCommand(format!(
                        "comic export will not overwrite existing output {}",
                        destination.display()
                    )));
                }
                Err(error) if error.kind() != std::io::ErrorKind::NotFound => {
                    return Err(EngineError::InvalidCommand(format!(
                        "comic export destination cannot be checked: {error}"
                    )));
                }
                Err(_) => {}
            }
        }
        let png_temporary = directory.join(format!(
            ".{png_name}.{}.{}.tmp",
            std::process::id(),
            export_nonce
        ));
        let svg_temporary = directory.join(format!(
            ".{svg_name}.{}.{}.tmp",
            std::process::id(),
            export_nonce
        ));
        staged.push((
            png_destination,
            png_temporary,
            svg_destination,
            svg_temporary,
        ));
    }

    for (page_index, ((_, png_temporary, _, svg_temporary), page)) in
        staged.iter().zip(&project.pages).enumerate()
    {
        let Some(document_handle) = handle.pages.get(&page.id) else {
            for (_, png_staged, _, svg_staged) in &staged {
                let _ = std::fs::remove_file(png_staged);
                let _ = std::fs::remove_file(svg_staged);
            }
            return Err(EngineError::InvalidCommand(
                "comic page document is unavailable".into(),
            ));
        };
        let export_result = document(document_handle)
            .and_then(|page_document| page_document.export_png(png_temporary.as_path()));
        if let Err(error) = export_result {
            for (_, png_staged, _, svg_staged) in &staged {
                let _ = std::fs::remove_file(png_staged);
                let _ = std::fs::remove_file(svg_staged);
            }
            return Err(error);
        }
        let png_bytes = match std::fs::read(png_temporary) {
            Ok(bytes) => bytes,
            Err(error) => {
                for (_, png_staged, _, svg_staged) in &staged {
                    let _ = std::fs::remove_file(png_staged);
                    let _ = std::fs::remove_file(svg_staged);
                }
                return Err(EngineError::InvalidCommand(format!(
                    "comic SVG artwork could not be read: {error}"
                )));
            }
        };
        let svg_bytes = match project.page_svg_with_raster_artwork(page_index, &png_bytes) {
            Ok(bytes) => bytes,
            Err(error) => {
                for (_, png_staged, _, svg_staged) in &staged {
                    let _ = std::fs::remove_file(png_staged);
                    let _ = std::fs::remove_file(svg_staged);
                }
                return Err(EngineError::InvalidCommand(error.to_string()));
            }
        };
        let write_svg = (|| -> std::io::Result<()> {
            let mut file = std::fs::File::create(svg_temporary)?;
            file.write_all(&svg_bytes)?;
            file.sync_all()
        })();
        if let Err(error) = write_svg {
            for (_, png_staged, _, svg_staged) in &staged {
                let _ = std::fs::remove_file(png_staged);
                let _ = std::fs::remove_file(svg_staged);
            }
            return Err(EngineError::InvalidCommand(format!(
                "comic SVG staging failed: {error}"
            )));
        }
    }

    let mut published = Vec::with_capacity(staged.len() * 2);
    for (png_destination, png_temporary, svg_destination, svg_temporary) in &staged {
        for (destination, temporary) in [
            (png_destination, png_temporary),
            (svg_destination, svg_temporary),
        ] {
            if let Err(error) = std::fs::hard_link(temporary, destination) {
                // Final paths were preflighted as absent; remove any newly
                // published siblings so an I/O failure does not report a partial
                // batch as success.
                for published_destination in published {
                    let _ = std::fs::remove_file(published_destination);
                }
                for (_, png_staged, _, svg_staged) in &staged {
                    let _ = std::fs::remove_file(png_staged);
                    let _ = std::fs::remove_file(svg_staged);
                }
                return Err(EngineError::InvalidCommand(format!(
                    "comic export could not publish all page files: {error}"
                )));
            }
            published.push(destination);
            if let Err(error) = std::fs::remove_file(temporary) {
                for published_destination in published {
                    let _ = std::fs::remove_file(published_destination);
                }
                for (_, png_staged, _, svg_staged) in &staged {
                    let _ = std::fs::remove_file(png_staged);
                    let _ = std::fs::remove_file(svg_staged);
                }
                return Err(EngineError::InvalidCommand(format!(
                    "comic export could not finalize staged page files: {error}"
                )));
            }
        }
    }
    Ok(u32::try_from(staged.len()).unwrap_or(u32::MAX))
}

pub fn studio_batch_export_webtoon_segments(
    handle: &StudioProjectHandle,
    directory: String,
    max_height_px: u32,
) -> Result<u32, EngineError> {
    let count = studio_project(handle)?
        .batch_export_webtoon_segments(std::path::Path::new(&directory), max_height_px)
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    Ok(u32::try_from(count).unwrap_or(u32::MAX))
}

/// Dispatch an editor command against the active page document. Page
/// activation itself is navigation, while drawing and layer commands remain
/// undoable in that page's Rust timeline.
pub fn dispatch_project_command(
    handle: &mut StudioProjectHandle,
    command: EditorCommand,
) -> Result<u64, EngineError> {
    dispatch(studio_active_document_mut(handle)?, command)
}

/// Append a high-frequency pointer packet to the active page document.
pub fn push_project_pointer_packet(
    handle: &mut StudioProjectHandle,
    packet: &[u8],
) -> Result<(), EngineError> {
    document_mut(studio_active_document_mut(handle)?)?.push_pointer_packet(packet)
}

/// Read the active page's authoritative composite tile.
pub fn read_project_composite_tile(
    handle: &StudioProjectHandle,
    x: i32,
    y: i32,
) -> Result<Vec<u8>, EngineError> {
    document(studio_active_document(handle)?)?.read_composite_tile(TileCoord { x, y })
}

/// Return canonical comic metadata for checkpoint coordinators.
pub fn checkpoint_project(handle: &StudioProjectHandle) -> Result<Vec<u8>, EngineError> {
    studio_project(handle)?
        .to_json()
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))
}

/// Save all page snapshots and comic metadata through the atomic v2 storage
/// boundary. No source is replaced until every page validates and is written.
pub fn save_project_as(handle: &StudioProjectHandle, path: String) -> Result<(), String> {
    let project = studio_project(handle).map_err(|error| error.to_string())?;
    let comic = project.to_json().map_err(|error| error.to_string())?;
    let mut pages = Vec::with_capacity(project.pages.len());
    for page_ref in &project.page_documents {
        let page = handle
            .pages
            .get(&page_ref.page_id)
            .ok_or_else(|| "studio page document is unavailable".to_owned())?;
        let mut snapshot = document(page)
            .map_err(|error| error.to_string())?
            .snapshot();
        snapshot.comic = None;
        pages.push(ink_storage::StudioPageSnapshot {
            page_id: page_ref.page_id,
            relative_path: page_ref.relative_path.clone(),
            snapshot,
        });
    }
    ink_storage::save_studio_project(
        std::path::Path::new(&path),
        &ink_storage::StudioProjectSnapshot { comic, pages },
    )
    .map_err(|error| format!("studio save failed: {error}"))
}

/// Close a unified project and release all page workers.
pub fn close_studio_project(handle: &mut StudioProjectHandle) {
    handle.pages.clear();
    handle.active_page = None;
    handle.project_undo.clear();
    handle.project_redo.clear();
    handle.project = None;
}

/// Create the bounded native GPU surface. Adapter, allocation, or shader
/// failure is returned to Flutter so the CPU live painter can remain active.
pub fn create_live_surface(
    physical_width: u32,
    physical_height: u32,
    scale_milli: u32,
) -> Result<LiveSurfaceHandle, EngineError> {
    let config = ink_live_render::LiveSurfaceConfig {
        physical_width,
        physical_height,
        scale_milli,
    };
    let inner = ink_live_render::GpuLiveSurface::new(config).map_err(|error| {
        EngineError::InvalidCommand(format!("live GPU surface unavailable: {error:?}"))
    })?;
    Ok(LiveSurfaceHandle {
        inner: Some(inner),
        config,
        attached_document: None,
        viewport_generation: 0,
    })
}

/// Return the native graphics-device handle for a paired platform surface
/// adapter. The handle is process-local and must never be persisted.
pub fn live_surface_native_device_handle(surface: &LiveSurfaceHandle) -> Result<u64, EngineError> {
    surface
        .inner
        .as_ref()
        .ok_or_else(|| {
            EngineError::InvalidCommand("live GPU surface is unavailable; use CPU fallback".into())
        })?
        .native_metal_device_handle()
        .map_err(|error| {
            EngineError::InvalidCommand(format!("native live device unavailable: {error:?}"))
        })
}

/// Attach a retained native texture created by the trusted platform adapter.
/// This process-local pointer is only accepted by the paired Apple Metal
/// adapter; unsupported targets keep using the Flutter CPU preview.
#[allow(unsafe_code)]
pub fn attach_live_surface_native_texture(
    surface: &LiveSurfaceHandle,
    texture_handle: u64,
) -> Result<(), EngineError> {
    let gpu = surface.inner.as_ref().ok_or_else(|| {
        EngineError::InvalidCommand("live GPU surface is unavailable; use CPU fallback".into())
    })?;
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    {
        // SAFETY: this bridge method is only called with the retained pointer
        // returned by the paired Apple Flutter texture adapter. The renderer
        // validates the target's dimensions, format, type, sample count, and
        // usage before taking ownership.
        unsafe { gpu.attach_metal_texture(texture_handle) }.map_err(|error| {
            EngineError::InvalidCommand(format!("native live texture rejected: {error:?}"))
        })
    }
    #[cfg(not(any(target_os = "macos", target_os = "ios")))]
    {
        let _ = (gpu, texture_handle);
        Err(EngineError::InvalidCommand(
            "native live texture attachment is unsupported on this target".into(),
        ))
    }
}

/// Associate a surface with a document for lifecycle tracking. Pixel and
/// brush state remain in the document handle; this does not copy document
/// data into the GPU surface.
pub fn attach_live_surface(
    document_handle: &DocumentHandle,
    surface: &mut LiveSurfaceHandle,
) -> Result<(), EngineError> {
    let document = document(document_handle)?;
    surface.attached_document = Some(document.id.0);
    Ok(())
}

/// Update the bounded physical target. The old surface remains untouched if
/// allocation or shader setup for the replacement fails.
pub fn resize_live_surface(
    surface: &mut LiveSurfaceHandle,
    physical_width: u32,
    physical_height: u32,
    scale_milli: u32,
) -> Result<(), EngineError> {
    let config = ink_live_render::LiveSurfaceConfig {
        physical_width,
        physical_height,
        scale_milli,
    };
    let replacement = ink_live_render::GpuLiveSurface::new(config).map_err(|error| {
        EngineError::InvalidCommand(format!("live GPU resize unavailable: {error:?}"))
    })?;
    surface.inner = Some(replacement);
    surface.config = config;
    Ok(())
}

/// Record a viewport generation on the surface. The matrix is validated at
/// the FFI boundary; the platform compositor applies it when presenting the
/// surface so stale generations cannot replace a newer canvas transform.
pub fn set_live_viewport(
    surface: &mut LiveSurfaceHandle,
    matrix: Vec<f32>,
    generation: u64,
) -> Result<(), EngineError> {
    if matrix.len() != 6 || matrix.iter().any(|value| !value.is_finite()) {
        return Err(EngineError::InvalidCommand(
            "live viewport matrix must contain six finite values".into(),
        ));
    }
    if generation < surface.viewport_generation {
        return Err(EngineError::InvalidCommand(
            "live viewport generation is stale".into(),
        ));
    }
    let matrix: [f32; 6] = matrix
        .try_into()
        .map_err(|_| EngineError::InvalidCommand("invalid live viewport matrix".into()))?;
    let gpu = surface.inner.as_ref().ok_or_else(|| {
        EngineError::InvalidCommand("live GPU surface is unavailable; use CPU fallback".into())
    })?;
    gpu.set_viewport(matrix, generation)
        .map_err(|error| EngineError::InvalidCommand(format!("live viewport failed: {error:?}")))?;
    surface.viewport_generation = generation;
    Ok(())
}

/// Detach a surface without destroying the document or its CPU state.
pub fn detach_live_surface(
    document_handle: &DocumentHandle,
    surface: &mut LiveSurfaceHandle,
) -> Result<(), EngineError> {
    let document = document(document_handle)?;
    if surface.attached_document == Some(document.id.0) {
        surface.attached_document = None;
    }
    Ok(())
}

/// Dispose the native target. Calling it more than once is safe.
pub fn dispose_live_surface(surface: &mut LiveSurfaceHandle) {
    surface.inner = None;
    surface.attached_document = None;
}

/// Drain the Rust-generated live dab batch as fixed-width little-endian data.
/// Layout: `u16 version`, `u16 flags`, `u32 count`; each v3 record contains a
/// u128 stroke ID, u32 sample sequence, u32 dab index, five f32 values (x, y,
/// radius, opacity, rotation), a phase byte, straight RGBA8 color, and seven
/// reserved zero bytes.
pub fn drain_live_dabs(handle: &mut DocumentHandle, limit: u32) -> Result<Vec<u8>, EngineError> {
    let limit = usize::try_from(limit).map_err(|_| {
        EngineError::InvalidCommand("live dab limit is outside the host range".into())
    })?;
    if limit > MAX_LIVE_DABS_PER_PACKET {
        return Err(EngineError::InvalidCommand(
            "live dab packet exceeds the safety limit".into(),
        ));
    }
    let dabs = document(handle)?.drain_live_dabs_available(limit)?;
    Ok(encode_live_dab_packet(&dabs))
}

/// Return the number of confirmed preview dabs that were back-pressured since
/// the previous poll. A non-zero value is a request to keep the CPU painter
/// visible; it is never a document-loss signal.
pub fn drain_live_dab_overflow_count(handle: &mut DocumentHandle) -> Result<u64, EngineError> {
    Ok(document(handle)?.take_live_dab_overflow_count_available())
}

/// Consume one fixed-width dab packet on the optional native GPU surface.
/// Malformed packets are rejected before any GPU call; a missing surface is a
/// recoverable fallback condition for the Flutter CPU painter.
pub fn render_live_dab_packet(
    surface: &mut LiveSurfaceHandle,
    packet: Vec<u8>,
) -> Result<(), EngineError> {
    let dabs = decode_live_dab_packet(&packet)?;
    let gpu = surface.inner.as_ref().ok_or_else(|| {
        EngineError::InvalidCommand("live GPU surface is unavailable; use CPU fallback".into())
    })?;
    gpu.render(&dabs)
        .map_err(|error| EngineError::InvalidCommand(format!("live GPU render failed: {error:?}")))
}

/// Retire acknowledged dabs from the ephemeral GPU surface. CPU tiles remain
/// authoritative; this only controls the overlay's lifetime.
pub fn acknowledge_live_surface(
    surface: &mut LiveSurfaceHandle,
    stroke_id: u128,
    highest_committed_sequence: u32,
) -> Result<(), EngineError> {
    let gpu = surface.inner.as_ref().ok_or_else(|| {
        EngineError::InvalidCommand("live GPU surface is unavailable; use CPU fallback".into())
    })?;
    gpu.acknowledge(stroke_id, highest_committed_sequence)
        .map_err(|error| {
            EngineError::InvalidCommand(format!("live acknowledgement failed: {error:?}"))
        })
}

/// Cancel one stroke's ephemeral overlay without modifying CPU document data.
pub fn cancel_live_surface_stroke(
    surface: &mut LiveSurfaceHandle,
    stroke_id: u128,
) -> Result<(), EngineError> {
    let gpu = surface.inner.as_ref().ok_or_else(|| {
        EngineError::InvalidCommand("live GPU surface is unavailable; use CPU fallback".into())
    })?;
    gpu.cancel_stroke(stroke_id).map_err(|error| {
        EngineError::InvalidCommand(format!("live stroke cancellation failed: {error:?}"))
    })
}

pub fn comic_project_snapshot(
    handle: &ComicProjectHandle,
) -> Result<ComicProjectView, EngineError> {
    Ok(comic_view(comic_project(handle)?))
}

pub fn comic_add_print_page(
    handle: &mut ComicProjectHandle,
    page_id: u128,
    width_px: u32,
    height_px: u32,
    dpi: f32,
) -> Result<ComicProjectView, EngineError> {
    comic_add_page(handle, page_id, width_px, height_px, dpi)
}

pub fn comic_add_page(
    handle: &mut ComicProjectHandle,
    page_id: u128,
    width_px: u32,
    height_px: u32,
    dpi: f32,
) -> Result<ComicProjectView, EngineError> {
    let project = comic_project_mut(handle)?;
    project
        .add_page(ink_comic::print_page(width_px, height_px, dpi, 0, page_id))
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    Ok(comic_view(project))
}

pub fn comic_reorder_page(
    handle: &mut ComicProjectHandle,
    from: u32,
    to: u32,
) -> Result<ComicProjectView, EngineError> {
    let project = comic_project_mut(handle)?;
    project
        .reorder_page(from as usize, to as usize)
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    Ok(comic_view(project))
}

#[allow(clippy::too_many_arguments)]
pub fn comic_set_page_layout(
    handle: &mut ComicProjectHandle,
    page_index: u32,
    dpi: f32,
    bleed_left: f32,
    bleed_top: f32,
    bleed_right: f32,
    bleed_bottom: f32,
    trim_x: f32,
    trim_y: f32,
    trim_width: f32,
    trim_height: f32,
    safety_left: f32,
    safety_top: f32,
    safety_right: f32,
    safety_bottom: f32,
) -> Result<ComicProjectView, EngineError> {
    let project = comic_project_mut(handle)?;
    project
        .set_page_layout(
            page_index as usize,
            dpi,
            ink_comic::Insets {
                left: bleed_left,
                top: bleed_top,
                right: bleed_right,
                bottom: bleed_bottom,
            },
            ink_comic::Rect {
                x: trim_x,
                y: trim_y,
                width: trim_width,
                height: trim_height,
            },
            ink_comic::Insets {
                left: safety_left,
                top: safety_top,
                right: safety_right,
                bottom: safety_bottom,
            },
        )
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    Ok(comic_view(project))
}

pub fn comic_resize_gutter(
    handle: &mut ComicProjectHandle,
    page_index: u32,
    panel_id: u128,
    gutter_px: f32,
) -> Result<ComicProjectView, EngineError> {
    let project = comic_project_mut(handle)?;
    project
        .resize_gutter(page_index as usize, panel_id, gutter_px)
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    Ok(comic_view(project))
}

#[allow(clippy::too_many_arguments)]
pub fn comic_add_panel(
    handle: &mut ComicProjectHandle,
    page_index: u32,
    panel_id: u128,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    gutter_px: f32,
    mask_layer_id: Option<u128>,
) -> Result<ComicProjectView, EngineError> {
    let project = comic_project_mut(handle)?;
    project
        .add_panel(
            page_index as usize,
            Panel {
                id: panel_id,
                shape: PanelShape::Rectangle,
                bounds: Rect {
                    x,
                    y,
                    width,
                    height,
                },
                polygon: Vec::new(),
                gutter_px,
                mask_layer_id,
            },
        )
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    Ok(comic_view(project))
}

pub fn comic_set_panel_bounds(
    handle: &mut ComicProjectHandle,
    page_index: u32,
    panel_id: u128,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
) -> Result<ComicProjectView, EngineError> {
    let project = comic_project_mut(handle)?;
    project
        .set_panel_bounds(
            page_index as usize,
            panel_id,
            ink_comic::Rect {
                x,
                y,
                width,
                height,
            },
        )
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    Ok(comic_view(project))
}

#[allow(clippy::too_many_arguments)]
pub fn comic_add_balloon(
    handle: &mut ComicProjectHandle,
    page_index: u32,
    balloon_id: u128,
    panel_id: Option<u128>,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    text: String,
) -> Result<ComicProjectView, EngineError> {
    let project = comic_project_mut(handle)?;
    project
        .add_balloon(
            page_index as usize,
            Balloon {
                id: balloon_id,
                shape: BalloonShape::Oval,
                bounds: Rect {
                    x,
                    y,
                    width,
                    height,
                },
                tail: Vec::new(),
                text,
                style: TextStyle::default(),
                panel_id,
            },
        )
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    Ok(comic_view(project))
}

#[allow(clippy::too_many_arguments)]
#[allow(clippy::needless_pass_by_value)]
pub fn comic_add_styled_balloon(
    handle: &mut ComicProjectHandle,
    page_index: u32,
    balloon_id: u128,
    panel_id: Option<u128>,
    shape: u8,
    tail: Vec<f32>,
    orientation: u8,
    font_family: String,
    font_size_px: f32,
    outline_px: f32,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    text: String,
) -> Result<ComicProjectView, EngineError> {
    let shape = match shape {
        0 => BalloonShape::Oval,
        1 => BalloonShape::Thought,
        2 => BalloonShape::Narration,
        3 => BalloonShape::Burst,
        _ => return Err(EngineError::InvalidCommand("unknown balloon shape".into())),
    };
    let orientation = match orientation {
        0 => TextOrientation::Horizontal,
        1 => TextOrientation::Vertical,
        _ => {
            return Err(EngineError::InvalidCommand(
                "unknown text orientation".into(),
            ));
        }
    };
    if !tail.len().is_multiple_of(2) {
        return Err(EngineError::InvalidCommand(
            "balloon tail requires coordinate pairs".into(),
        ));
    }
    let tail = tail
        .as_chunks::<2>()
        .0
        .iter()
        .map(|pair| (pair[0], pair[1]))
        .collect();
    let project = comic_project_mut(handle)?;
    project
        .add_balloon(
            page_index as usize,
            Balloon {
                id: balloon_id,
                shape,
                bounds: Rect {
                    x,
                    y,
                    width,
                    height,
                },
                tail,
                text,
                style: TextStyle {
                    font_family,
                    font_size_px,
                    outline_px,
                    orientation,
                    ..TextStyle::default()
                },
                panel_id,
            },
        )
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    Ok(comic_view(project))
}

pub fn comic_add_material(
    handle: &mut ComicProjectHandle,
    material_id: u128,
    name: String,
    kind: String,
    license: String,
    attribution: Option<String>,
    source: Option<String>,
) -> Result<ComicProjectView, EngineError> {
    let project = comic_project_mut(handle)?;
    project
        .add_material(MaterialAsset {
            id: material_id,
            name,
            kind,
            license,
            attribution,
            source,
        })
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    Ok(comic_view(project))
}

pub fn comic_remove_material(
    handle: &mut ComicProjectHandle,
    material_id: u128,
) -> Result<ComicProjectView, EngineError> {
    let project = comic_project_mut(handle)?;
    project
        .remove_material(material_id)
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    Ok(comic_view(project))
}

pub fn comic_set_panel_polygon(
    handle: &mut ComicProjectHandle,
    page_index: u32,
    panel_id: u128,
    points: Vec<f32>,
) -> Result<ComicProjectView, EngineError> {
    if points.len() < 6 || !points.len().is_multiple_of(2) {
        return Err(EngineError::InvalidCommand(
            "panel polygon requires at least three coordinate pairs".into(),
        ));
    }
    let polygon = points
        .as_chunks::<2>()
        .0
        .iter()
        .map(|pair| (pair[0], pair[1]))
        .collect();
    let project = comic_project_mut(handle)?;
    project
        .set_panel_polygon(page_index as usize, panel_id, polygon)
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    Ok(comic_view(project))
}

pub fn comic_split_panel(
    handle: &mut ComicProjectHandle,
    page_index: u32,
    panel_id: u128,
    first_id: u128,
    second_id: u128,
    axis: u8,
    ratio: f32,
) -> Result<ComicProjectView, EngineError> {
    let project = comic_project_mut(handle)?;
    project
        .split_panel(
            page_index as usize,
            panel_id,
            first_id,
            second_id,
            axis,
            ratio,
        )
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    Ok(comic_view(project))
}

#[allow(clippy::too_many_arguments)]
pub fn comic_add_tone(
    handle: &mut ComicProjectHandle,
    page_index: u32,
    tone_id: u128,
    frequency_lpi: f32,
    angle_degrees: f32,
    density: f32,
    shape: String,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
) -> Result<ComicProjectView, EngineError> {
    let project = comic_project_mut(handle)?;
    project
        .add_tone(
            page_index as usize,
            ToneLayer {
                id: tone_id,
                frequency_lpi,
                angle_degrees,
                density,
                shape,
                bounds: Rect {
                    x,
                    y,
                    width,
                    height,
                },
            },
        )
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    Ok(comic_view(project))
}

#[allow(clippy::too_many_arguments)]
#[allow(clippy::needless_pass_by_value)]
pub fn comic_set_tone(
    handle: &mut ComicProjectHandle,
    page_index: u32,
    tone_id: u128,
    frequency_lpi: f32,
    angle_degrees: f32,
    density: f32,
    shape: String,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
) -> Result<ComicProjectView, EngineError> {
    let project = comic_project_mut(handle)?;
    project
        .set_tone(
            page_index as usize,
            tone_id,
            ToneLayer {
                id: tone_id,
                frequency_lpi,
                angle_degrees,
                density,
                shape,
                bounds: Rect {
                    x,
                    y,
                    width,
                    height,
                },
            },
        )
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    Ok(comic_view(project))
}

pub fn comic_remove_tone(
    handle: &mut ComicProjectHandle,
    page_index: u32,
    tone_id: u128,
) -> Result<ComicProjectView, EngineError> {
    let project = comic_project_mut(handle)?;
    project
        .remove_tone(page_index as usize, tone_id)
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    Ok(comic_view(project))
}

#[allow(clippy::too_many_arguments)]
#[allow(clippy::needless_pass_by_value)]
pub fn comic_add_effect_line(
    handle: &mut ComicProjectHandle,
    page_index: u32,
    effect_id: u128,
    kind: String,
    points: Vec<f32>,
    width_px: f32,
    opacity: f32,
) -> Result<ComicProjectView, EngineError> {
    if points.len() < 4 || !points.len().is_multiple_of(2) {
        return Err(EngineError::InvalidCommand(
            "effect line requires at least two coordinate pairs".into(),
        ));
    }
    let points = points
        .as_chunks::<2>()
        .0
        .iter()
        .map(|pair| (pair[0], pair[1]))
        .collect();
    let project = comic_project_mut(handle)?;
    project
        .add_effect_line(
            page_index as usize,
            EffectLine {
                id: effect_id,
                kind,
                points,
                width_px,
                opacity,
            },
        )
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    Ok(comic_view(project))
}

#[allow(clippy::too_many_arguments)]
#[allow(clippy::needless_pass_by_value)]
pub fn comic_set_effect_line(
    handle: &mut ComicProjectHandle,
    page_index: u32,
    effect_id: u128,
    kind: String,
    points: Vec<f32>,
    width_px: f32,
    opacity: f32,
) -> Result<ComicProjectView, EngineError> {
    if points.len() < 4 || !points.len().is_multiple_of(2) {
        return Err(EngineError::InvalidCommand(
            "effect line requires at least two coordinate pairs".into(),
        ));
    }
    let points = points
        .as_chunks::<2>()
        .0
        .iter()
        .map(|pair| (pair[0], pair[1]))
        .collect();
    let project = comic_project_mut(handle)?;
    project
        .set_effect_line(
            page_index as usize,
            effect_id,
            EffectLine {
                id: effect_id,
                kind,
                points,
                width_px,
                opacity,
            },
        )
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    Ok(comic_view(project))
}

pub fn comic_remove_effect_line(
    handle: &mut ComicProjectHandle,
    page_index: u32,
    effect_id: u128,
) -> Result<ComicProjectView, EngineError> {
    let project = comic_project_mut(handle)?;
    project
        .remove_effect_line(page_index as usize, effect_id)
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    Ok(comic_view(project))
}

pub fn comic_set_dialogue(
    handle: &mut ComicProjectHandle,
    page_index: u32,
    balloon_id: u128,
    text: String,
) -> Result<ComicProjectView, EngineError> {
    let project = comic_project_mut(handle)?;
    project
        .set_dialogue(page_index as usize, balloon_id, text)
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    Ok(comic_view(project))
}

pub fn comic_set_balloon_tail(
    handle: &mut ComicProjectHandle,
    page_index: u32,
    balloon_id: u128,
    points: Vec<f32>,
) -> Result<ComicProjectView, EngineError> {
    if !points.len().is_multiple_of(2) {
        return Err(EngineError::InvalidCommand(
            "balloon tail requires coordinate pairs".into(),
        ));
    }
    let tail = points
        .as_chunks::<2>()
        .0
        .iter()
        .map(|pair| (pair[0], pair[1]))
        .collect();
    let project = comic_project_mut(handle)?;
    project
        .set_balloon_tail(page_index as usize, balloon_id, tail)
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    Ok(comic_view(project))
}

#[allow(clippy::too_many_arguments)]
#[allow(clippy::needless_pass_by_value)]
pub fn comic_set_balloon_style(
    handle: &mut ComicProjectHandle,
    page_index: u32,
    balloon_id: u128,
    font_family: String,
    font_size_px: f32,
    outline_px: f32,
    orientation: u8,
) -> Result<ComicProjectView, EngineError> {
    let orientation = match orientation {
        0 => TextOrientation::Horizontal,
        1 => TextOrientation::Vertical,
        _ => {
            return Err(EngineError::InvalidCommand(
                "unknown text orientation".into(),
            ));
        }
    };
    let project = comic_project_mut(handle)?;
    let existing = project
        .pages
        .get(page_index as usize)
        .and_then(|page| {
            page.balloons
                .iter()
                .find(|balloon| balloon.id == balloon_id)
        })
        .ok_or_else(|| EngineError::InvalidCommand("dangling balloon reference".into()))?;
    let style = TextStyle {
        font_family,
        font_size_px,
        outline_px,
        orientation,
        fill_rgba: existing.style.fill_rgba,
        outline_rgba: existing.style.outline_rgba,
    };
    project
        .set_balloon_style(page_index as usize, balloon_id, style)
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    Ok(comic_view(project))
}

pub fn comic_search_dialogue(
    handle: &ComicProjectHandle,
    query: String,
) -> Result<Vec<ComicDialogueHitView>, EngineError> {
    Ok(comic_project(handle)?
        .search_dialogue(&query)
        .into_iter()
        .map(|hit| ComicDialogueHitView {
            page_index: u32::try_from(hit.page_index).unwrap_or(u32::MAX),
            balloon_id: hit.balloon_id,
            match_start: u32::try_from(hit.match_start).unwrap_or(u32::MAX),
            match_end: u32::try_from(hit.match_end).unwrap_or(u32::MAX),
        })
        .collect())
}

pub fn comic_webtoon_segments(
    handle: &ComicProjectHandle,
    page_index: u32,
    max_height_px: u32,
) -> Result<Vec<ComicWebtoonSegmentView>, EngineError> {
    Ok(comic_project(handle)?
        .webtoon_segments(page_index as usize, max_height_px)
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?
        .into_iter()
        .map(|segment| ComicWebtoonSegmentView {
            page_index: u32::try_from(segment.page_index).unwrap_or(u32::MAX),
            segment_index: u32::try_from(segment.segment_index).unwrap_or(u32::MAX),
            source_y: segment.source_y,
            height_px: segment.height_px,
        })
        .collect())
}

/// Export one bounded JSON manifest per page into a caller-selected local
/// directory. The Rust model validates the complete project before writing.
pub fn comic_batch_export_page_manifests(
    handle: &ComicProjectHandle,
    directory: String,
) -> Result<u32, EngineError> {
    let count = comic_project(handle)?
        .batch_export_page_manifests(std::path::Path::new(&directory))
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    Ok(u32::try_from(count).unwrap_or(u32::MAX))
}

/// Export all comic pages as self-contained SVGs with panels, balloons, text,
/// tones, and effect-line structure preserved.
pub fn comic_batch_export_pages(
    handle: &ComicProjectHandle,
    directory: String,
) -> Result<u32, EngineError> {
    let count = comic_project(handle)?
        .batch_export_page_svgs(std::path::Path::new(&directory))
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    Ok(u32::try_from(count).unwrap_or(u32::MAX))
}

/// Export long-canvas webtoon pages as cropped, deterministic SVG segments.
pub fn comic_batch_export_webtoon_segments(
    handle: &ComicProjectHandle,
    directory: String,
    max_height_px: u32,
) -> Result<u32, EngineError> {
    let count = comic_project(handle)?
        .batch_export_webtoon_segments(std::path::Path::new(&directory), max_height_px)
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    Ok(u32::try_from(count).unwrap_or(u32::MAX))
}

/// Validate print trim/safety geometry and return non-destructive moiré
/// warnings for the print-preview UI.
pub fn comic_print_preview_report(
    handle: &ComicProjectHandle,
) -> Result<ComicPrintPreviewView, EngineError> {
    let report = comic_project(handle)?
        .print_preview_report()
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    Ok(ComicPrintPreviewView {
        page_count: u32::try_from(report.page_count).unwrap_or(u32::MAX),
        bleed_safe: report.bleed_safe,
        safety_safe: report.safety_safe,
        moire_warnings: report.moire_warnings,
    })
}

/// Render one bounded comic page preview as deterministic PNG bytes for the
/// Flutter print-preview surface.
pub fn comic_render_page_preview(
    handle: &ComicProjectHandle,
    page_index: u32,
    max_dimension: u32,
) -> Result<Vec<u8>, EngineError> {
    let preview = comic_project(handle)?
        .render_page_preview(page_index as usize, max_dimension)
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    ink_export::encode_png(preview.width, preview.height, &preview.pixels_rgba)
        .map_err(|error| EngineError::InvalidCommand(format!("preview PNG failed: {error}")))
}

pub fn comic_project_to_json(handle: &ComicProjectHandle) -> Result<Vec<u8>, EngineError> {
    comic_project(handle)?
        .to_json()
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))
}

/// Return a deterministic structural/rendering digest for cross-device
/// transfer verification. It is computed entirely from Rust-owned bytes.
pub fn comic_project_portable_digest(handle: &ComicProjectHandle) -> Result<String, EngineError> {
    let digest = comic_project(handle)?
        .portable_render_digest()
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    let mut output = String::with_capacity(digest.len() * 2);
    for byte in digest {
        write!(&mut output, "{byte:02x}")
            .map_err(|_| EngineError::InvalidCommand("digest formatting failed".into()))?;
    }
    Ok(output)
}

pub fn comic_project_export_manifest(
    handle: &ComicProjectHandle,
    path: String,
) -> Result<(), EngineError> {
    comic_project(handle)?
        .export_manifest(std::path::Path::new(&path))
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))
}

pub fn comic_project_from_json(bytes: Vec<u8>) -> Result<ComicProjectHandle, EngineError> {
    let project = ComicProject::from_json(&bytes)
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    Ok(ComicProjectHandle {
        inner: Some(project),
    })
}

pub fn close_comic_project(handle: &mut ComicProjectHandle) {
    handle.inner = None;
}

const BRUSH_IMPORT_TTL: Duration = Duration::from_mins(10);
const MAX_STAGED_BRUSH_IMPORTS: usize = 16;

/// Immutable Phase 1 canvas metadata cached by Flutter.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DocumentInfo {
    pub width_px: u32,
    pub height_px: u32,
    pub dpi: f32,
    pub primary_raster_layer: u128,
}

/// Small immutable brush projection for the Flutter library UI.
#[derive(Clone, Debug, PartialEq)]
#[allow(dead_code)]
pub struct BrushSummary {
    pub id: u128,
    pub is_builtin: bool,
    pub name: String,
    pub tags: Vec<String>,
    pub diameter_px: f32,
    pub opacity: f32,
    pub spacing: f32,
    pub smoothing: f32,
    pub pressure_size: f32,
    pub pressure_opacity: f32,
    pub hardness: f32,
    pub texture_scale: f32,
    pub scatter: f32,
    pub rotation_jitter: f32,
    pub smudge: f32,
    pub wetness: f32,
    pub color_rgba: u32,
    pub pressure_curve_points: Vec<f32>,
    pub tip_resource_hash: Option<Vec<u8>>,
    pub grain_resource_hash: Option<Vec<u8>>,
}

/// Bounded, display-only inspection data for the Flutter import confirmation.
#[derive(Clone, Debug, PartialEq)]
pub struct BrushImportInspectionView {
    pub source_format: String,
    pub source_sha256: Vec<u8>,
    pub bytes: u64,
    pub fidelity: String,
    pub importer_version: String,
}

/// A document-scoped import operation. The source remains outside Rust's
/// project state until the caller explicitly commits it.
#[derive(Clone, Debug, PartialEq)]
pub struct BrushImportStageView {
    pub operation_id: u64,
    pub inspection: BrushImportInspectionView,
    pub expires_in_seconds: u32,
}

/// Bounded compatibility report shown before an external brush is installed.
/// It intentionally contains no executable source metadata or raw archives.
#[derive(Clone, Debug, PartialEq)]
pub struct BrushImportReportView {
    pub source_format: String,
    pub source_sha256: Vec<u8>,
    pub importer_version: String,
    pub fidelity: String,
    pub mappings: Vec<String>,
    pub omitted: Vec<String>,
    pub warnings: Vec<String>,
    pub resource_count: u32,
    pub preview_width: u16,
    pub preview_height: u16,
    pub brush_count: u32,
}

fn bounded_text(value: &str, limit: usize) -> String {
    value.chars().take(limit).collect()
}

fn inspection_view(value: &ink_brush::BrushImportInspection) -> BrushImportInspectionView {
    BrushImportInspectionView {
        source_format: format!("{:?}", value.source_format),
        source_sha256: value.source_sha256.to_vec(),
        bytes: value.bytes,
        fidelity: format!("{:?}", value.fidelity_hint),
        importer_version: bounded_text(&value.importer_version, 128),
    }
}

fn report_view(value: &ink_brush::BrushImportReport, brush_count: u32) -> BrushImportReportView {
    let preview_width = value.preview.as_ref().map_or(0, |preview| preview.width);
    let preview_height = value.preview.as_ref().map_or(0, |preview| preview.height);
    BrushImportReportView {
        source_format: format!("{:?}", value.source_format),
        source_sha256: value.source_sha256.to_vec(),
        importer_version: bounded_text(&value.importer_version, 128),
        fidelity: format!("{:?}", value.fidelity),
        mappings: value
            .mappings
            .iter()
            .take(128)
            .map(|mapping| {
                format!(
                    "{} -> {} ({:?})",
                    bounded_text(&mapping.source_path, 128),
                    bounded_text(&mapping.target_path, 128),
                    mapping.quality
                )
            })
            .collect(),
        omitted: value
            .omitted
            .iter()
            .take(128)
            .map(|item| {
                format!(
                    "{}: {}",
                    bounded_text(&item.source_path, 128),
                    bounded_text(&item.reason, 256)
                )
            })
            .collect(),
        warnings: value
            .warnings
            .iter()
            .take(128)
            .map(|warning| {
                format!(
                    "{}: {}",
                    bounded_text(&warning.code, 128),
                    bounded_text(&warning.message, 256)
                )
            })
            .collect(),
        resource_count: u32::try_from(value.resources.len()).unwrap_or(u32::MAX),
        preview_width,
        preview_height,
        brush_count,
    }
}

/// Immutable layer projection for responsive Flutter panels.  Keeping this
/// DTO flat avoids exposing the internal layer tree or mutable document state
/// across the FFI boundary.
#[derive(Clone, Debug, PartialEq)]
#[allow(clippy::struct_excessive_bools)]
pub struct LayerSummary {
    pub id: u128,
    pub parent: Option<u128>,
    pub mask_owner: Option<u128>,
    pub mask_enabled: bool,
    pub mask_inverted: bool,
    pub order: u32,
    pub kind: String,
    pub name: String,
    pub opacity: u16,
    pub visible: bool,
    pub blend_mode: String,
    pub group_mode: String,
    pub alpha_lock: bool,
    pub locked: bool,
    pub clipping: bool,
    pub reference: bool,
    pub label_rgba: Option<u32>,
    pub adjustment_brightness: i16,
    pub adjustment_contrast: i16,
    pub can_drag: bool,
    pub drag_reason: Option<String>,
    pub can_receive_layers: bool,
    pub receive_reason: Option<String>,
    pub can_edit_properties: bool,
    pub edit_properties_reason: Option<String>,
    pub can_duplicate: bool,
    pub duplicate_reason: Option<String>,
    pub can_delete: bool,
    pub delete_reason: Option<String>,
    pub can_ungroup: bool,
    pub ungroup_reason: Option<String>,
    pub can_apply_mask: bool,
    pub apply_mask_reason: Option<String>,
    pub merge_down_reason: Option<String>,
}

/// Bounded editable vector-stroke projection used by the vector inspector.
#[derive(Clone, Debug, PartialEq)]
pub struct VectorStrokeSummary {
    pub id: u128,
    pub point_count: u32,
    pub points: Vec<f32>,
    pub min_x: f32,
    pub min_y: f32,
    pub max_x: f32,
    pub max_y: f32,
}

fn layer_kind_name(kind: LayerKind) -> &'static str {
    match kind {
        LayerKind::Raster => "Raster",
        LayerKind::VectorInk => "VectorInk",
        LayerKind::Group => "Group",
        LayerKind::Mask => "Mask",
        LayerKind::Tone => "Tone",
        LayerKind::PanelGroup => "PanelGroup",
        LayerKind::Adjustment => "Adjustment",
    }
}

fn blend_mode_name(mode: LayerBlendMode) -> &'static str {
    match mode {
        LayerBlendMode::Normal => "Normal",
        LayerBlendMode::Multiply => "Multiply",
        LayerBlendMode::Screen => "Screen",
        LayerBlendMode::Overlay => "Overlay",
        LayerBlendMode::Darken => "Darken",
        LayerBlendMode::Lighten => "Lighten",
        LayerBlendMode::Add => "Add",
        LayerBlendMode::Subtract => "Subtract",
        LayerBlendMode::ColorBurn => "Color Burn",
        LayerBlendMode::LinearBurn => "Linear Burn",
        LayerBlendMode::ColorDodge => "Color Dodge",
        LayerBlendMode::SoftLight => "Soft Light",
        LayerBlendMode::HardLight => "Hard Light",
        LayerBlendMode::Difference => "Difference",
        LayerBlendMode::Exclusion => "Exclusion",
        LayerBlendMode::Divide => "Divide",
    }
}

fn group_mode_name(mode: LayerGroupMode) -> &'static str {
    match mode {
        LayerGroupMode::Isolated => "Isolated",
        LayerGroupMode::PassThrough => "Pass-through",
    }
}

fn document(handle: &DocumentHandle) -> Result<DocumentRef<'_>, EngineError> {
    let state = handle
        .state
        .lock()
        .map_err(|_| EngineError::InvalidCommand("document handle lock is poisoned".into()))?;
    if state.inner.is_none() {
        return Err(EngineError::InvalidCommand(
            "document handle is closed".into(),
        ));
    }
    Ok(DocumentRef { state })
}

fn document_mut(handle: &mut DocumentHandle) -> Result<DocumentMutRef<'_>, EngineError> {
    let state = handle
        .state
        .lock()
        .map_err(|_| EngineError::InvalidCommand("document handle lock is poisoned".into()))?;
    if state.inner.is_none() {
        return Err(EngineError::InvalidCommand(
            "document handle is closed".into(),
        ));
    }
    Ok(DocumentMutRef { state })
}

fn document_state(
    handle: &DocumentHandle,
) -> Result<MutexGuard<'_, DocumentHandleState>, EngineError> {
    handle
        .state
        .lock()
        .map_err(|_| EngineError::InvalidCommand("document handle lock is poisoned".into()))
}

fn new_document_handle(document: Document) -> DocumentHandle {
    DocumentHandle {
        state: Arc::new(Mutex::new(DocumentHandleState {
            inner: Some(document),
            active_stroke: None,
            tile_snapshot_sent: false,
            staged_brush_imports: BTreeMap::new(),
            next_brush_import: 1,
        })),
    }
}

/// Create a new transparent sRGB document using the stable v1 defaults.
pub fn create_default_document(
    id: u128,
    width_px: u32,
    height_px: u32,
    dpi: f32,
) -> Result<DocumentHandle, EngineError> {
    create_document(
        id,
        DocumentSpec {
            width_px,
            height_px,
            dpi,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        },
    )
}

/// Create a document handle.
pub fn create_document(id: u128, spec: DocumentSpec) -> Result<DocumentHandle, EngineError> {
    Ok(new_document_handle(Document::new(
        DocumentId::from_u128(id),
        spec,
    )?))
}

/// Open an existing native project without mutating its source.
pub fn open_document(path: String) -> Result<DocumentHandle, EngineError> {
    let path = std::path::PathBuf::from(path);
    if path
        .extension()
        .and_then(std::ffi::OsStr::to_str)
        .is_some_and(|extension| extension.eq_ignore_ascii_case("psd"))
    {
        const MAX_PSD_BYTES: u64 = 512 * 1024 * 1024;
        let link_metadata = std::fs::symlink_metadata(&path).map_err(|error| {
            EngineError::InvalidCommand(format!("PSD metadata failed: {error}"))
        })?;
        if link_metadata.file_type().is_symlink() || !link_metadata.is_file() {
            return Err(EngineError::InvalidCommand(
                "PSD source must be a regular file".into(),
            ));
        }
        let metadata = std::fs::metadata(&path).map_err(|error| {
            EngineError::InvalidCommand(format!("PSD metadata failed: {error}"))
        })?;
        if metadata.len() > MAX_PSD_BYTES {
            return Err(EngineError::InvalidCommand(
                "PSD exceeds the 512 MiB import limit".into(),
            ));
        }
        // Check the aggregate source + decoded image + initial raster-layer
        // footprint from the fixed-size header before allocating the source
        // buffer. The decoder repeats this validation before allocating RGBA.
        let mut header = [0_u8; 26];
        std::fs::File::open(&path)
            .and_then(|mut file| file.read_exact(&mut header))
            .map_err(|error| EngineError::InvalidCommand(format!("PSD read failed: {error}")))?;
        if &header[..4] == b"8BPS" {
            let width = u32::from_be_bytes([header[18], header[19], header[20], header[21]]);
            let height = u32::from_be_bytes([header[14], header[15], header[16], header[17]]);
            ink_export::validate_psd_import_budget(metadata.len(), width, height).map_err(
                |error| EngineError::InvalidCommand(format!("PSD import failed: {error}")),
            )?;
        }
        let file = std::fs::File::open(&path)
            .map_err(|error| EngineError::InvalidCommand(format!("PSD read failed: {error}")))?;
        let mut bytes = Vec::new();
        file.take(MAX_PSD_BYTES.saturating_add(1))
            .read_to_end(&mut bytes)
            .map_err(|error| EngineError::InvalidCommand(format!("PSD read failed: {error}")))?;
        if u64::try_from(bytes.len()).unwrap_or(u64::MAX) > MAX_PSD_BYTES {
            return Err(EngineError::InvalidCommand(
                "PSD exceeds the 512 MiB import limit".into(),
            ));
        }
        let (width, height, pixels) = ink_export::decode_psd(&bytes)
            .map_err(|error| EngineError::InvalidCommand(format!("PSD import failed: {error}")))?;
        return Ok(new_document_handle(Document::from_flattened_rgba(
            DocumentId::from_u128(2),
            width,
            height,
            &pixels,
        )?));
    }
    Ok(new_document_handle(Document::open(&path)?))
}

/// Close a document and join its render worker. The operation is idempotent.
#[allow(clippy::unnecessary_wraps)]
pub fn close_document(handle: &mut DocumentHandle) -> Result<(), EngineError> {
    let mut state = document_state(handle)?;
    if let Some(mut document) = state.inner.take() {
        document.close();
    }
    state.active_stroke = None;
    state.staged_brush_imports.clear();
    Ok(())
}

/// Dispatch one shared command.
pub fn dispatch(handle: &mut DocumentHandle, command: EditorCommand) -> Result<u64, EngineError> {
    let active_stroke_before = document_state(handle)?.active_stroke;
    let active_stroke = match &command {
        EditorCommand::BeginStroke { stroke, .. } => Some(Some(*stroke)),
        EditorCommand::EndStroke { stroke } | EditorCommand::CancelStroke { stroke }
            if active_stroke_before == Some(*stroke) =>
        {
            Some(None)
        }
        _ => None,
    };
    let revision = document_mut(handle)?.dispatch(command)?;
    if let Some(active_stroke) = active_stroke {
        document_state(handle)?.active_stroke = active_stroke;
    }
    Ok(revision)
}

/// Undo the most recent committed command.
pub fn undo(handle: &mut DocumentHandle) -> Result<u64, EngineError> {
    dispatch(handle, EditorCommand::Undo)
}

/// Redo the most recently undone command.
pub fn redo(handle: &mut DocumentHandle) -> Result<u64, EngineError> {
    dispatch(handle, EditorCommand::Redo)
}

/// Return the bounded Rust-owned command history for a document.
pub fn history_snapshot(
    handle: &mut DocumentHandle,
    limit: u16,
) -> Result<HistorySnapshotView, EngineError> {
    let projection = document_mut(handle)?.history_snapshot(limit)?;
    Ok(HistorySnapshotView {
        revision: projection.revision,
        cursor: projection.cursor,
        was_trimmed: projection.was_trimmed,
        entries: projection
            .entries
            .into_iter()
            .map(|entry| HistoryEntryView {
                sequence: entry.sequence,
                kind: entry.kind,
                detail: entry.detail,
                applied: entry.applied,
            })
            .collect(),
    })
}

/// Move the document's undo/redo cursor to a sequence boundary from a recent
/// history snapshot. Sequence zero means before the first retained command.
pub fn navigate_history(handle: &mut DocumentHandle, sequence: u64) -> Result<u64, EngineError> {
    document_mut(handle)?.navigate_history(sequence)
}

/// Add a top-level layer. Kind uses the stable document enum values:
/// 0 raster, 1 vector ink, 2 group, 3 mask, 4 tone, 5 panel group, 6 adjustment.
pub fn add_layer(handle: &mut DocumentHandle, kind: u8) -> Result<u128, EngineError> {
    let kind = match kind {
        0 => LayerKind::Raster,
        1 => LayerKind::VectorInk,
        2 => LayerKind::Group,
        3 => LayerKind::Mask,
        4 => LayerKind::Tone,
        5 => LayerKind::PanelGroup,
        6 => LayerKind::Adjustment,
        _ => return Err(EngineError::InvalidCommand("unknown layer kind".into())),
    };
    document_mut(handle)?.add_layer(kind).map(|id| id.0)
}

/// Add a layer under an existing group or panel-group parent.
pub fn add_layer_to_parent(
    handle: &mut DocumentHandle,
    kind: u8,
    parent: u128,
) -> Result<u128, EngineError> {
    let kind = match kind {
        0 => LayerKind::Raster,
        1 => LayerKind::VectorInk,
        2 => LayerKind::Group,
        3 => LayerKind::Mask,
        4 => LayerKind::Tone,
        5 => LayerKind::PanelGroup,
        6 => LayerKind::Adjustment,
        _ => return Err(EngineError::InvalidCommand("unknown layer kind".into())),
    };
    document_mut(handle)?
        .add_layer_with_parent(kind, Some(ink_model::LayerId::from_u128(parent)))
        .map(|id| id.0)
}

/// Delete one leaf layer through the shared undoable command path.
pub fn delete_layer(handle: &mut DocumentHandle, layer: u128) -> Result<u64, EngineError> {
    document_mut(handle)?.delete_layer(ink_model::LayerId::from_u128(layer))
}

/// Delete several selected layer roots and descendants as one undoable edit.
pub fn delete_layers(handle: &mut DocumentHandle, layers: Vec<u128>) -> Result<u64, EngineError> {
    document_mut(handle)?.delete_layers(
        layers
            .into_iter()
            .map(ink_model::LayerId::from_u128)
            .collect(),
    )
}

/// Return an engine-authored reason when selected page layers cannot be
/// deleted. The query does not change revision, content, or history.
pub fn preflight_delete_layers(
    handle: &DocumentHandle,
    layers: Vec<u128>,
) -> Result<Option<String>, EngineError> {
    document(handle)?.preflight_delete_layers(
        &layers
            .into_iter()
            .map(ink_model::LayerId::from_u128)
            .collect::<Vec<_>>(),
    )
}

/// Preflight page deletion while preserving project-owned comic layers.
pub fn preflight_delete_project_layers(
    handle: &StudioProjectHandle,
    layer_ids: Vec<u128>,
) -> Result<Option<String>, EngineError> {
    let project = studio_project(handle)?;
    let bound = project
        .panel_layers
        .iter()
        .flat_map(|binding| {
            [
                binding.panel_group_id,
                binding.mask_layer_id,
                binding.sketch_layer_id,
                binding.ink_layer_id,
                binding.color_layer_id,
                binding.tone_layer_id,
                binding.effects_layer_id,
            ]
        })
        .collect::<HashSet<_>>();
    let active_document = studio_active_document(handle)?;
    let layer_views = layers(active_document)?;
    let mut removed = HashSet::new();
    for id in &layer_ids {
        let root = ink_model::LayerId::from_u128(*id);
        let mut subtree = vec![root];
        let mut cursor = 0;
        while cursor < subtree.len() {
            let parent = subtree[cursor];
            for child in layer_views.iter().filter(|candidate| {
                candidate.parent == Some(parent) || candidate.mask_owner == Some(parent)
            }) {
                if !subtree.contains(&child.id) {
                    subtree.push(child.id);
                }
            }
            cursor += 1;
        }
        removed.extend(subtree.into_iter().map(|layer| layer.0));
    }
    if removed.iter().any(|id| bound.contains(id)) {
        return Ok(Some(
            "Comic-owned layers must be removed through the Comics workspace.".into(),
        ));
    }
    document(active_document)?.preflight_delete_layers(
        &layer_ids
            .into_iter()
            .map(ink_model::LayerId::from_u128)
            .collect::<Vec<_>>(),
    )
}

/// Set visibility on distinct layers as one undoable operation.
pub fn set_layers_visibility(
    handle: &mut DocumentHandle,
    layers: Vec<u128>,
    visible: bool,
) -> Result<u64, EngineError> {
    dispatch(
        handle,
        EditorCommand::SetLayersVisibility {
            layers: layers
                .into_iter()
                .map(ink_model::LayerId::from_u128)
                .collect(),
            visible,
        },
    )
}

/// Set or clear the session-only Solo presentation override for one layer.
pub fn set_layer_solo(
    handle: &mut DocumentHandle,
    layer: Option<u128>,
) -> Result<u64, EngineError> {
    document_mut(handle)?.set_layer_solo(layer.map(ink_model::LayerId::from_u128))
}

/// Set or clear a layer's full content and property lock.
pub fn set_layer_locked(
    handle: &mut DocumentHandle,
    layer: u128,
    locked: bool,
) -> Result<u64, EngineError> {
    let layer_id = ink_model::LayerId::from_u128(layer);
    if document(handle)?
        .layers()
        .into_iter()
        .find(|candidate| candidate.id == layer_id)
        .ok_or(EngineError::InvalidLayer)?
        .locked
        == locked
    {
        return revision(handle);
    }
    dispatch(
        handle,
        EditorCommand::SetLayerLocked {
            layer: layer_id,
            locked,
        },
    )
}

/// Enable or disable an attached mask with one undoable property change.
pub fn set_mask_enabled(
    handle: &mut DocumentHandle,
    mask: u128,
    enabled: bool,
) -> Result<u64, EngineError> {
    let mask_id = ink_model::LayerId::from_u128(mask);
    let current = document(handle)?
        .layers()
        .into_iter()
        .find(|candidate| candidate.id == mask_id)
        .ok_or(EngineError::InvalidLayer)?;
    if current.kind != LayerKind::Mask {
        return Err(EngineError::InvalidCommand(
            "mask operation requires a mask layer".into(),
        ));
    }
    if current.mask_enabled == enabled {
        return revision(handle);
    }
    dispatch(
        handle,
        EditorCommand::SetMaskEnabled {
            mask: mask_id,
            enabled,
        },
    )
}

/// Invert an attached mask without rewriting pixels.
pub fn set_mask_inverted(
    handle: &mut DocumentHandle,
    mask: u128,
    inverted: bool,
) -> Result<u64, EngineError> {
    let mask_id = ink_model::LayerId::from_u128(mask);
    let current = document(handle)?
        .layers()
        .into_iter()
        .find(|candidate| candidate.id == mask_id)
        .ok_or(EngineError::InvalidLayer)?;
    if current.kind != LayerKind::Mask {
        return Err(EngineError::InvalidCommand(
            "mask operation requires a mask layer".into(),
        ));
    }
    if current.mask_inverted == inverted {
        return revision(handle);
    }
    dispatch(
        handle,
        EditorCommand::SetMaskInverted {
            mask: mask_id,
            inverted,
        },
    )
}

/// Bake an attached mask into its raster owner and remove the mask in one edit.
pub fn apply_layer_mask(handle: &mut DocumentHandle, mask: u128) -> Result<u64, EngineError> {
    dispatch(
        handle,
        EditorCommand::ApplyLayerMask {
            mask: ink_model::LayerId::from_u128(mask),
        },
    )
}

/// Set or clear full locks on distinct selected layers in one undoable edit.
pub fn set_layers_locked(
    handle: &mut DocumentHandle,
    layers: Vec<u128>,
    locked: bool,
) -> Result<u64, EngineError> {
    let layers: Vec<_> = layers
        .into_iter()
        .map(ink_model::LayerId::from_u128)
        .collect();
    if layers.is_empty()
        || layers
            .iter()
            .copied()
            .collect::<std::collections::HashSet<_>>()
            .len()
            != layers.len()
    {
        return Err(EngineError::InvalidCommand(
            "bulk lock requires distinct layer IDs".into(),
        ));
    }
    let current = document(handle)?.layers();
    if layers.iter().all(|id| {
        current
            .iter()
            .any(|layer| layer.id == *id && layer.locked == locked)
    }) {
        return revision(handle);
    }
    dispatch(handle, EditorCommand::SetLayersLocked { layers, locked })
}

/// Set or clear color labels on distinct selected layers in one undoable edit.
/// `label_rgba` is packed as `0xRRGGBBAA`; `None` clears the labels.
pub fn set_layers_label(
    handle: &mut DocumentHandle,
    layers: Vec<u128>,
    label_rgba: Option<u32>,
) -> Result<u64, EngineError> {
    let layers: Vec<_> = layers
        .into_iter()
        .map(ink_model::LayerId::from_u128)
        .collect();
    if layers.is_empty() || layers.iter().copied().collect::<HashSet<_>>().len() != layers.len() {
        return Err(EngineError::InvalidCommand(
            "bulk label requires distinct layer IDs".into(),
        ));
    }
    let label = label_rgba.map(|packed| Rgba8 {
        r: (packed >> 24) as u8,
        g: (packed >> 16) as u8,
        b: (packed >> 8) as u8,
        a: packed as u8,
    });
    dispatch(handle, EditorCommand::SetLayersLabel { layers, label })
}

/// Reorder selected sibling roots as one undoable stack operation.
pub fn reorder_layers(
    handle: &mut DocumentHandle,
    layers: Vec<u128>,
    index: u32,
) -> Result<u64, EngineError> {
    dispatch(
        handle,
        EditorCommand::ReorderLayers {
            layers: layers
                .into_iter()
                .map(ink_model::LayerId::from_u128)
                .collect(),
            index,
        },
    )
}

/// Duplicate a leaf layer within the active page document.
pub fn duplicate_layer(handle: &mut DocumentHandle, source: u128) -> Result<u128, EngineError> {
    document_mut(handle)?
        .duplicate_layer(ink_model::LayerId::from_u128(source))
        .map(|id| id.0)
}

/// Duplicate multiple sibling layer roots and their owned hierarchy atomically.
pub fn duplicate_layers(
    handle: &mut DocumentHandle,
    sources: Vec<u128>,
) -> Result<Vec<u128>, EngineError> {
    document_mut(handle)?
        .duplicate_layers(
            sources
                .into_iter()
                .map(ink_model::LayerId::from_u128)
                .collect(),
        )
        .map(|ids| ids.into_iter().map(|id| id.0).collect())
}

/// Group selected sibling layers in a single undoable pass-through group.
pub fn group_layers(handle: &mut DocumentHandle, members: Vec<u128>) -> Result<u128, EngineError> {
    document_mut(handle)?
        .group_layers(
            members
                .into_iter()
                .map(ink_model::LayerId::from_u128)
                .collect(),
        )
        .map(|id| id.0)
}

/// Return an actionable reason when selected layers cannot be grouped.
pub fn preflight_group_layers(
    handle: &DocumentHandle,
    members: Vec<u128>,
) -> Result<Option<String>, EngineError> {
    document(handle)?.preflight_group_layers(
        &members
            .into_iter()
            .map(ink_model::LayerId::from_u128)
            .collect::<Vec<_>>(),
    )
}

/// Ungroup a compositing-safe ordinary layer group as one undoable edit.
pub fn ungroup_layer(handle: &mut DocumentHandle, group: u128) -> Result<u64, EngineError> {
    document_mut(handle)?.ungroup_layer(ink_model::LayerId::from_u128(group))
}

/// Duplicate a page layer through the active studio project document handle.
pub fn duplicate_project_layer(
    handle: &mut StudioProjectHandle,
    source: u128,
) -> Result<u128, EngineError> {
    document_mut(studio_active_document_mut(handle)?)?
        .duplicate_layer(ink_model::LayerId::from_u128(source))
        .map(|id| id.0)
}

/// Duplicate multiple sibling roots in the active unified-project page.
pub fn duplicate_project_layers(
    handle: &mut StudioProjectHandle,
    sources: Vec<u128>,
) -> Result<Vec<u128>, EngineError> {
    document_mut(studio_active_document_mut(handle)?)?
        .duplicate_layers(
            sources
                .into_iter()
                .map(ink_model::LayerId::from_u128)
                .collect(),
        )
        .map(|ids| ids.into_iter().map(|id| id.0).collect())
}

/// Delete a page layer while preserving the unified comic project's panel
/// ownership graph. Ordinary groups may delete their subtree, but a subtree
/// containing any panel-bound layer must be removed through Comics.
pub fn delete_project_layer(
    handle: &mut StudioProjectHandle,
    layer: u128,
) -> Result<u64, EngineError> {
    let bound = studio_project(handle)?
        .panel_layers
        .iter()
        .flat_map(|binding| {
            [
                binding.panel_group_id,
                binding.mask_layer_id,
                binding.sketch_layer_id,
                binding.ink_layer_id,
                binding.color_layer_id,
                binding.tone_layer_id,
                binding.effects_layer_id,
            ]
        })
        .collect::<HashSet<_>>();
    let layers = layers(studio_active_document(handle)?)?;
    let mut subtree = vec![layer];
    let mut cursor = 0;
    while cursor < subtree.len() {
        let parent = subtree[cursor];
        for child in layers
            .iter()
            .filter(|candidate| candidate.parent == Some(ink_model::LayerId::from_u128(parent)))
        {
            if !subtree.contains(&child.id.0) {
                subtree.push(child.id.0);
            }
        }
        cursor += 1;
    }
    if subtree.iter().any(|id| bound.contains(id)) {
        return Err(EngineError::InvalidCommand(
            "comic-owned layers must be removed through the comic workspace".into(),
        ));
    }
    document_mut(studio_active_document_mut(handle)?)?
        .delete_layer(ink_model::LayerId::from_u128(layer))
}

/// Atomically delete selected page layers while preserving comic ownership.
pub fn delete_project_layers(
    handle: &mut StudioProjectHandle,
    layer_ids: Vec<u128>,
) -> Result<u64, EngineError> {
    let bound = studio_project(handle)?
        .panel_layers
        .iter()
        .flat_map(|binding| {
            [
                binding.panel_group_id,
                binding.mask_layer_id,
                binding.sketch_layer_id,
                binding.ink_layer_id,
                binding.color_layer_id,
                binding.tone_layer_id,
                binding.effects_layer_id,
            ]
        })
        .collect::<HashSet<_>>();
    let layer_views = layers(studio_active_document(handle)?)?;
    let mut removed = HashSet::new();
    for id in &layer_ids {
        let mut subtree = vec![*id];
        let mut cursor = 0;
        while cursor < subtree.len() {
            let parent = ink_model::LayerId::from_u128(subtree[cursor]);
            for child in layer_views
                .iter()
                .filter(|candidate| candidate.parent == Some(parent))
            {
                if !subtree.contains(&child.id.0) {
                    subtree.push(child.id.0);
                }
            }
            cursor += 1;
        }
        removed.extend(subtree);
    }
    if removed.iter().any(|id| bound.contains(id)) {
        return Err(EngineError::InvalidCommand(
            "comic-owned layers must be removed through the comic workspace".into(),
        ));
    }
    document_mut(studio_active_document_mut(handle)?)?.delete_layers(
        layer_ids
            .into_iter()
            .map(ink_model::LayerId::from_u128)
            .collect(),
    )
}

/// Move a layer within the validated sibling list. The index is a position
/// among the destination parent's children, not an object identity; Rust
/// persists and applies the resulting order for composition and reopen.
pub fn move_layer(
    handle: &mut DocumentHandle,
    layer: u128,
    parent: Option<u128>,
    index: u32,
) -> Result<u64, EngineError> {
    dispatch(
        handle,
        EditorCommand::MoveLayer {
            layer: ink_model::LayerId::from_u128(layer),
            parent: parent.map(ink_model::LayerId::from_u128),
            index,
        },
    )
}

/// Materialize one panel's conventional group, mask, and child paint layers
/// in the page document. The Rust command validates all IDs and commits the
/// seven-layer tree atomically; retrying an already completed migration is a
/// safe no-op.
#[allow(clippy::too_many_arguments)]
pub fn create_panel_layer_tree(
    handle: &mut DocumentHandle,
    panel: u128,
    panel_group: u128,
    mask: u128,
    sketch: u128,
    ink: u128,
    color: u128,
    tone: u128,
    effects: u128,
) -> Result<u64, EngineError> {
    document_mut(handle)?.create_panel_layer_tree(
        ink_model::LayerId::from_u128(panel),
        ink_model::LayerId::from_u128(panel_group),
        ink_model::LayerId::from_u128(mask),
        ink_model::LayerId::from_u128(sketch),
        ink_model::LayerId::from_u128(ink),
        ink_model::LayerId::from_u128(color),
        ink_model::LayerId::from_u128(tone),
        ink_model::LayerId::from_u128(effects),
    )
}

/// Persist bounded panel geometry into the generated mask layer. The bridge
/// accepts a flat coordinate list to keep the Dart API allocation-free at the
/// FFI boundary; Rust validates the vertex count, finiteness, and bounds.
pub fn set_panel_mask_geometry(
    handle: &mut DocumentHandle,
    mask: u128,
    points: Vec<f32>,
) -> Result<u64, EngineError> {
    if points.len() < 6 || points.len() > 128 || !points.len().is_multiple_of(2) {
        return Err(EngineError::InvalidCommand(
            "panel mask geometry requires 3 to 64 points".into(),
        ));
    }
    if points.iter().any(|value| !value.is_finite()) {
        return Err(EngineError::InvalidCommand(
            "panel mask geometry contains a non-finite coordinate".into(),
        ));
    }
    let (pairs, remainder) = points.as_chunks::<2>();
    debug_assert!(remainder.is_empty());
    document_mut(handle)?.set_panel_mask_geometry(
        ink_model::LayerId::from_u128(mask),
        pairs.iter().map(|pair| (pair[0], pair[1])).collect(),
    )
}

/// Merge two standalone raster layers. The source is removed only after the
/// Rust engine has composited it into the target; the command remains
/// undoable through the shared layer-history path.
pub fn merge_layers(
    handle: &mut DocumentHandle,
    target_layer: u128,
    source_layer: u128,
) -> Result<u64, EngineError> {
    document_mut(handle)?.merge_layers(
        ink_model::LayerId::from_u128(target_layer),
        ink_model::LayerId::from_u128(source_layer),
    )
}

/// Validate a two-layer merge without mutating the active document.
pub fn preflight_merge_layers(
    handle: &DocumentHandle,
    target_layer: u128,
    source_layer: u128,
) -> String {
    match document(handle).and_then(|document| {
        document.preflight_merge_layers(
            ink_model::LayerId::from_u128(target_layer),
            ink_model::LayerId::from_u128(source_layer),
        )
    }) {
        Ok(()) => String::new(),
        Err(error) => error.to_string(),
    }
}

/// Merge contiguous selected sibling rasters in the active document.
pub fn merge_layers_bulk(
    handle: &mut DocumentHandle,
    layers: Vec<u128>,
) -> Result<u128, EngineError> {
    document_mut(handle)?
        .merge_layers_bulk(
            layers
                .into_iter()
                .map(ink_model::LayerId::from_u128)
                .collect(),
        )
        .map(|id| id.0)
}

/// Merge contiguous selected sibling rasters on the active unified-project page.
pub fn merge_project_layers_bulk(
    handle: &mut StudioProjectHandle,
    layers: Vec<u128>,
) -> Result<u128, EngineError> {
    document_mut(studio_active_document_mut(handle)?)?
        .merge_layers_bulk(
            layers
                .into_iter()
                .map(ink_model::LayerId::from_u128)
                .collect(),
        )
        .map(|id| id.0)
}

/// Begin the built-in technical-pen stroke on the active raster layer.
pub fn begin_default_stroke(handle: &mut DocumentHandle) -> Result<u64, EngineError> {
    let (revision, layer) = {
        let document = document(handle)?;
        let layer = document.primary_raster_layer().ok_or_else(|| {
            EngineError::InvalidCommand("document has no raster layer available".into())
        })?;
        (document.revision(), layer)
    };
    let stroke_value = u128::from(revision)
        .checked_add(1)
        .ok_or_else(|| EngineError::InvalidCommand("stroke ID space is exhausted".into()))?;
    let stroke = StrokeId::from_u128(stroke_value);
    dispatch(
        handle,
        EditorCommand::BeginStroke {
            stroke,
            layer,
            brush: BrushId::from_u128(1),
        },
    )
}

/// Begin a stroke using a built-in Phase 2 brush.
#[allow(dead_code)]
pub fn begin_brush_stroke(handle: &mut DocumentHandle, brush_id: u128) -> Result<u64, EngineError> {
    let (revision, layer) = {
        let document = document(handle)?;
        let layer = document.primary_raster_layer().ok_or_else(|| {
            EngineError::InvalidCommand("document has no raster layer available".into())
        })?;
        (document.revision(), layer)
    };
    let stroke = StrokeId::from_u128(
        revision
            .checked_add(1)
            .ok_or_else(|| EngineError::InvalidCommand("stroke ID space is exhausted".into()))?
            .into(),
    );
    dispatch(
        handle,
        EditorCommand::BeginStroke {
            stroke,
            layer,
            brush: BrushId::from_u128(brush_id),
        },
    )
}

/// Begin a brush stroke on a caller-selected raster or mask layer.
pub fn begin_brush_stroke_on_layer(
    handle: &mut DocumentHandle,
    brush_id: u128,
    layer_id: u128,
) -> Result<u64, EngineError> {
    let revision = document(handle)?.revision();
    let stroke = StrokeId::from_u128(
        revision
            .checked_add(1)
            .ok_or_else(|| EngineError::InvalidCommand("stroke ID space is exhausted".into()))?
            .into(),
    );
    let result = dispatch(
        handle,
        EditorCommand::BeginStroke {
            stroke,
            layer: ink_model::LayerId::from_u128(layer_id),
            brush: BrushId::from_u128(brush_id),
        },
    );
    if let Err(error) = &result {
        eprintln!("Project Ink begin brush stroke failed: {error}");
    }
    result
}

/// Apply bounded editor settings to a Rust-owned brush copy.
#[allow(clippy::too_many_arguments)]
// FRB owns this generated-call boundary and requires an owned Vec for the
// Dart transfer; the engine receives it as a borrowed slice immediately.
#[allow(clippy::needless_pass_by_value)]
pub fn update_brush_settings(
    handle: &mut DocumentHandle,
    brush_id: u128,
    diameter_px: f32,
    opacity: f32,
    spacing: f32,
    smoothing: f32,
    pressure_size: f32,
    pressure_opacity: f32,
    pressure_curve: f32,
    hardness: f32,
    texture_scale: f32,
    scatter: f32,
    rotation_jitter: f32,
    smudge: f32,
    wetness: f32,
    pressure_curve_points: Vec<f32>,
) -> Result<u64, EngineError> {
    document_mut(handle)?.update_brush_settings(
        BrushId::from_u128(brush_id),
        diameter_px,
        opacity,
        spacing,
        smoothing,
        pressure_size,
        pressure_opacity,
        pressure_curve,
        hardness,
        texture_scale,
        scatter,
        rotation_jitter,
        smudge,
        wetness,
        &pressure_curve_points,
    )
}

/// Update the bounded RGBA color of a Rust-owned brush copy.
pub fn update_brush_color(
    handle: &mut DocumentHandle,
    brush_id: u128,
    red: u8,
    green: u8,
    blue: u8,
    alpha: u8,
) -> Result<u64, EngineError> {
    document_mut(handle)?.update_brush_color(
        BrushId::from_u128(brush_id),
        Rgba8 {
            r: red,
            g: green,
            b: blue,
            a: alpha,
        },
    )
}

/// Set the shared foreground color for strokes in the current document session.
pub fn set_active_brush_color(
    handle: &mut DocumentHandle,
    red: u8,
    green: u8,
    blue: u8,
    alpha: u8,
) -> Result<(), EngineError> {
    document_mut(handle)?.set_active_brush_color(Rgba8 {
        r: red,
        g: green,
        b: blue,
        a: alpha,
    });
    Ok(())
}

/// Begin a temporary brush editor transaction owned by Rust.
pub fn begin_brush_draft(handle: &mut DocumentHandle, brush_id: u128) -> Result<u64, EngineError> {
    document_mut(handle)?.begin_brush_draft(BrushId::from_u128(brush_id))
}

/// Update a pending brush editor transaction without installing it.
#[allow(clippy::too_many_arguments)]
#[allow(clippy::needless_pass_by_value)]
pub fn update_brush_draft(
    handle: &mut DocumentHandle,
    draft_id: u64,
    diameter_px: f32,
    opacity: f32,
    spacing: f32,
    smoothing: f32,
    pressure_size: f32,
    pressure_opacity: f32,
    pressure_curve: f32,
    hardness: f32,
    texture_scale: f32,
    scatter: f32,
    rotation_jitter: f32,
    smudge: f32,
    wetness: f32,
    pressure_curve_points: Vec<f32>,
) -> Result<(), EngineError> {
    document_mut(handle)?.update_brush_draft(
        draft_id,
        diameter_px,
        opacity,
        spacing,
        smoothing,
        pressure_size,
        pressure_opacity,
        pressure_curve,
        hardness,
        texture_scale,
        scatter,
        rotation_jitter,
        smudge,
        wetness,
        &pressure_curve_points,
    )
}

/// Commit one complete brush editor transaction.
pub fn commit_brush_draft(handle: &mut DocumentHandle, draft_id: u64) -> Result<u64, EngineError> {
    document_mut(handle)?.commit_brush_draft(draft_id)
}

/// Discard one brush editor transaction.
pub fn cancel_brush_draft(handle: &mut DocumentHandle, draft_id: u64) -> Result<(), EngineError> {
    document_mut(handle)?.cancel_brush_draft(draft_id)
}

/// Render a bounded brush-editor scratch stroke as a transparent PNG.
pub fn render_brush_preview_png(
    handle: &mut DocumentHandle,
    brush_id: u128,
    width: u16,
    height: u16,
    points: Vec<BrushPreviewPoint>,
) -> Result<Vec<u8>, EngineError> {
    let engine_points = points
        .into_iter()
        .map(|point| EngineBrushPreviewPoint {
            x: point.x,
            y: point.y,
            pressure: point.pressure,
        })
        .collect::<Vec<_>>();
    let pixels = document_mut(handle)?.render_brush_preview_rgba8(
        BrushId::from_u128(brush_id),
        width,
        height,
        &engine_points,
    )?;
    ink_export::encode_png(u32::from(width), u32::from(height), &pixels)
        .map_err(|error| EngineError::InvalidCommand(format!("brush preview PNG failed: {error}")))
}

/// Apply the common editable layer flags through shared command IDs.
#[allow(clippy::too_many_arguments)]
#[allow(clippy::fn_params_excessive_bools)]
pub fn update_layer_properties(
    handle: &mut DocumentHandle,
    layer_id: u128,
    visible: bool,
    opacity: u16,
    alpha_lock: bool,
    clipping: bool,
    reference: bool,
) -> Result<u64, EngineError> {
    let layer = ink_model::LayerId::from_u128(layer_id);
    let existing = document(handle)?
        .layers()
        .into_iter()
        .find(|candidate| candidate.id == layer)
        .ok_or(EngineError::InvalidLayer)?;
    let mut latest_revision = revision(handle)?;
    if existing.visible != visible {
        latest_revision = dispatch(handle, EditorCommand::SetLayerVisibility { layer, visible })?;
    }
    if existing.opacity != opacity {
        latest_revision = dispatch(handle, EditorCommand::SetLayerOpacity { layer, opacity })?;
    }
    if existing.alpha_lock != alpha_lock {
        latest_revision = dispatch(
            handle,
            EditorCommand::SetLayerAlphaLock {
                layer,
                enabled: alpha_lock,
            },
        )?;
    }
    if existing.clipping != clipping {
        latest_revision = dispatch(
            handle,
            EditorCommand::SetLayerClipping {
                layer,
                enabled: clipping,
            },
        )?;
    }
    if existing.reference != reference {
        latest_revision = dispatch(
            handle,
            EditorCommand::SetLayerReference {
                layer,
                enabled: reference,
            },
        )?;
    }
    Ok(latest_revision)
}

/// Begin an opacity-slider preview for one stable layer ID.
pub fn begin_layer_opacity_edit(
    handle: &mut DocumentHandle,
    layer_id: u128,
) -> Result<u64, EngineError> {
    document_mut(handle)?.begin_layer_opacity_edit(ink_model::LayerId::from_u128(layer_id))
}

/// Update the temporary opacity preview without creating history entries.
pub fn update_layer_opacity_edit(
    handle: &mut DocumentHandle,
    edit_id: u64,
    opacity: u16,
) -> Result<u64, EngineError> {
    document_mut(handle)?.update_layer_opacity_edit(edit_id, opacity)
}

/// Commit a slider preview as one undoable command.
pub fn commit_layer_opacity_edit(
    handle: &mut DocumentHandle,
    edit_id: u64,
) -> Result<u64, EngineError> {
    document_mut(handle)?.commit_layer_opacity_edit(edit_id)
}

/// Cancel a slider preview and restore its gesture-start opacity.
pub fn cancel_layer_opacity_edit(
    handle: &mut DocumentHandle,
    edit_id: u64,
) -> Result<u64, EngineError> {
    document_mut(handle)?.cancel_layer_opacity_edit(edit_id)
}

/// Apply the non-destructive layer presentation fields through journaled
/// command IDs. `blend_mode` uses the stable sixteen-value enum order and
/// `label_rgba` is packed as `0xRRGGBBAA`.
pub fn update_layer_presentation(
    handle: &mut DocumentHandle,
    layer_id: u128,
    name: String,
    blend_mode: u8,
    group_mode: u8,
    label_rgba: Option<u32>,
) -> Result<u64, EngineError> {
    if name.chars().count() > 128 {
        return Err(EngineError::InvalidCommand(
            "layer name exceeds the UI safety limit".into(),
        ));
    }
    let mode = match blend_mode {
        0 => LayerBlendMode::Normal,
        1 => LayerBlendMode::Multiply,
        2 => LayerBlendMode::Screen,
        3 => LayerBlendMode::Overlay,
        4 => LayerBlendMode::Darken,
        5 => LayerBlendMode::Lighten,
        6 => LayerBlendMode::Add,
        7 => LayerBlendMode::Subtract,
        8 => LayerBlendMode::ColorBurn,
        9 => LayerBlendMode::LinearBurn,
        10 => LayerBlendMode::ColorDodge,
        11 => LayerBlendMode::SoftLight,
        12 => LayerBlendMode::HardLight,
        13 => LayerBlendMode::Difference,
        14 => LayerBlendMode::Exclusion,
        15 => LayerBlendMode::Divide,
        _ => return Err(EngineError::InvalidCommand("unknown blend mode".into())),
    };
    let group_mode = match group_mode {
        0 => LayerGroupMode::Isolated,
        1 => LayerGroupMode::PassThrough,
        _ => return Err(EngineError::InvalidCommand("unknown group mode".into())),
    };
    let label = label_rgba.map(|packed| Rgba8 {
        r: (packed >> 24) as u8,
        g: (packed >> 16) as u8,
        b: (packed >> 8) as u8,
        a: packed as u8,
    });
    let layer = ink_model::LayerId::from_u128(layer_id);
    let existing = document(handle)?
        .layers()
        .into_iter()
        .find(|candidate| candidate.id == layer)
        .ok_or(EngineError::InvalidLayer)?;
    let mut latest_revision = revision(handle)?;
    if existing.name != name {
        latest_revision = dispatch(handle, EditorCommand::SetLayerName { layer, name })?;
    }
    if existing.blend_mode != mode {
        latest_revision = dispatch(handle, EditorCommand::SetLayerBlendMode { layer, mode })?;
    }
    if matches!(existing.kind, LayerKind::Group | LayerKind::PanelGroup)
        && existing.group_mode != group_mode
    {
        latest_revision = dispatch(
            handle,
            EditorCommand::SetLayerGroupMode {
                layer,
                mode: group_mode,
            },
        )?;
    }
    if existing.label != label {
        latest_revision = dispatch(handle, EditorCommand::SetLayerLabel { layer, label })?;
    }
    Ok(latest_revision)
}

/// Update a brightness/contrast adjustment layer through the undoable
/// document command path. Values are bounded percentages in -100..=100.
pub fn set_layer_brightness_contrast(
    handle: &mut DocumentHandle,
    layer_id: u128,
    brightness: i16,
    contrast: i16,
) -> Result<u64, EngineError> {
    let adjustment = LayerAdjustment::BrightnessContrast {
        brightness,
        contrast,
    }
    .validate()
    .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
    dispatch(
        handle,
        EditorCommand::SetLayerAdjustment {
            layer: ink_model::LayerId::from_u128(layer_id),
            adjustment,
        },
    )
}

/// Replace the ephemeral raster selection with a rectangle in canvas pixels.
pub fn select_rectangle(
    handle: &mut DocumentHandle,
    left: f32,
    top: f32,
    right: f32,
    bottom: f32,
) -> Result<u64, EngineError> {
    document_mut(handle)?.select_rectangle(left, top, right, bottom)
}

/// Replace the ephemeral raster selection with an ellipse in canvas pixels.
pub fn select_ellipse(
    handle: &mut DocumentHandle,
    center_x: f32,
    center_y: f32,
    radius_x: f32,
    radius_y: f32,
) -> Result<u64, EngineError> {
    document_mut(handle)?.select_ellipse(center_x, center_y, radius_x, radius_y)
}

/// Replace the ephemeral raster selection with a bounded lasso polygon.
#[allow(clippy::needless_pass_by_value)]
pub fn select_lasso(handle: &mut DocumentHandle, points: Vec<f32>) -> Result<u64, EngineError> {
    document_mut(handle)?.select_lasso(&points)
}

/// Select non-transparent pixels from one raster layer.
pub fn select_layer_opacity(
    handle: &mut DocumentHandle,
    layer_id: u128,
    minimum_alpha: u8,
) -> Result<u64, EngineError> {
    document_mut(handle)?
        .select_layer_opacity(ink_model::LayerId::from_u128(layer_id), minimum_alpha)
}

/// Select a bounded RGBA color range from one raster layer.
pub fn select_color_range(
    handle: &mut DocumentHandle,
    layer_id: u128,
    red: u8,
    green: u8,
    blue: u8,
    alpha: u8,
    tolerance: u16,
) -> Result<u64, EngineError> {
    document_mut(handle)?.select_color_range(
        ink_model::LayerId::from_u128(layer_id),
        Rgba8 {
            r: red,
            g: green,
            b: blue,
            a: alpha,
        },
        tolerance,
    )
}

/// Clear the ephemeral raster selection.
pub fn clear_selection(handle: &mut DocumentHandle) -> Result<u64, EngineError> {
    document_mut(handle)?.clear_selection()
}

/// Invert the active ephemeral selection.
pub fn invert_selection(handle: &mut DocumentHandle) -> Result<u64, EngineError> {
    document_mut(handle)?.invert_selection()
}

/// Grow the active selection by one to 256 pixels.
pub fn grow_selection(handle: &mut DocumentHandle, radius: u32) -> Result<u64, EngineError> {
    document_mut(handle)?.grow_selection(radius)
}

/// Shrink the active selection by one to 256 pixels.
pub fn shrink_selection(handle: &mut DocumentHandle, radius: u32) -> Result<u64, EngineError> {
    document_mut(handle)?.shrink_selection(radius)
}

/// Fill a contiguous raster region with bounded tolerance and gap closing.
#[allow(clippy::too_many_arguments)]
pub fn fill_region(
    handle: &mut DocumentHandle,
    layer_id: u128,
    x: u32,
    y: u32,
    red: u8,
    green: u8,
    blue: u8,
    alpha: u8,
    tolerance: u16,
    gap: u32,
) -> Result<u64, EngineError> {
    document_mut(handle)?.fill_region(
        ink_model::LayerId::from_u128(layer_id),
        x,
        y,
        Rgba8 {
            r: red,
            g: green,
            b: blue,
            a: alpha,
        },
        tolerance,
        gap,
    )
}

/// Apply a bounded linear gradient through a flood or Paint Inside mask.
#[allow(clippy::too_many_arguments)]
pub fn gradient_fill(
    handle: &mut DocumentHandle,
    layer_id: u128,
    x: u32,
    y: u32,
    start_x: f32,
    start_y: f32,
    end_x: f32,
    end_y: f32,
    from_red: u8,
    from_green: u8,
    from_blue: u8,
    from_alpha: u8,
    to_red: u8,
    to_green: u8,
    to_blue: u8,
    to_alpha: u8,
    tolerance: u16,
    gap: u32,
    expansion: u32,
    paint_inside: bool,
    paint_unfilled: bool,
) -> Result<u64, EngineError> {
    if [start_x, start_y, end_x, end_y]
        .iter()
        .any(|value| !value.is_finite())
    {
        return Err(EngineError::InvalidCommand(
            "gradient endpoints must be finite".into(),
        ));
    }
    document_mut(handle)?.gradient_fill(
        ink_model::LayerId::from_u128(layer_id),
        x,
        y,
        (start_x, start_y),
        (end_x, end_y),
        Rgba8 {
            r: from_red,
            g: from_green,
            b: from_blue,
            a: from_alpha,
        },
        Rgba8 {
            r: to_red,
            g: to_green,
            b: to_blue,
            a: to_alpha,
        },
        tolerance,
        gap.min(4),
        expansion.min(16),
        paint_inside,
        paint_unfilled,
    )
}

/// Apply an undoable perspective transform to a raster layer. The target
/// points are ordered top-left, top-right, bottom-right, bottom-left.
#[allow(clippy::needless_pass_by_value)]
pub fn perspective_layer(
    handle: &mut DocumentHandle,
    layer_id: u128,
    target: Vec<f32>,
) -> Result<u64, EngineError> {
    if target.len() != 8 || target.iter().any(|value| !value.is_finite()) {
        return Err(EngineError::InvalidCommand(
            "perspective target requires four finite points".into(),
        ));
    }
    let (pairs, remainder) = target.as_chunks::<2>();
    debug_assert!(remainder.is_empty());
    let target = [
        (pairs[0][0], pairs[0][1]),
        (pairs[1][0], pairs[1][1]),
        (pairs[2][0], pairs[2][1]),
        (pairs[3][0], pairs[3][1]),
    ];
    document_mut(handle)?.perspective_layer(ink_model::LayerId::from_u128(layer_id), target)
}

/// Apply an undoable regular mesh transform. Points are flattened row-major
/// `(x,y)` pairs and are bounded to a 32x32 control grid.
#[allow(clippy::needless_pass_by_value)]
pub fn mesh_layer(
    handle: &mut DocumentHandle,
    layer_id: u128,
    columns: u16,
    rows: u16,
    points: Vec<f32>,
) -> Result<u64, EngineError> {
    if !(2..=32).contains(&columns)
        || !(2..=32).contains(&rows)
        || points.len() != usize::from(columns) * usize::from(rows) * 2
        || points.iter().any(|value| !value.is_finite())
    {
        return Err(EngineError::InvalidCommand(
            "mesh transform points do not match a bounded grid".into(),
        ));
    }
    let (pairs, remainder) = points.as_chunks::<2>();
    debug_assert!(remainder.is_empty());
    let points = pairs.iter().map(|pair| (pair[0], pair[1])).collect();
    document_mut(handle)?.mesh_layer(
        ink_model::LayerId::from_u128(layer_id),
        columns,
        rows,
        points,
    )
}

/// Apply an undoable local liquify deformation to a raster layer.
#[allow(clippy::too_many_arguments)]
pub fn liquify_layer(
    handle: &mut DocumentHandle,
    layer_id: u128,
    center_x: f32,
    center_y: f32,
    radius: f32,
    strength: f32,
    mode: u8,
    direction_x: f32,
    direction_y: f32,
) -> Result<u64, EngineError> {
    document_mut(handle)?.liquify_layer(
        ink_model::LayerId::from_u128(layer_id),
        center_x,
        center_y,
        radius,
        strength,
        mode,
        direction_x,
        direction_y,
    )
}

/// Add an editable vector-ink stroke. Points are flattened `(x, y, pressure,
/// tilt)` tuples and are bounded before crossing into the engine.
#[allow(clippy::needless_pass_by_value)]
pub fn add_vector_stroke(
    handle: &mut DocumentHandle,
    layer_id: u128,
    points: Vec<f32>,
    closed: bool,
) -> Result<u64, EngineError> {
    if points.is_empty() || points.len() > 8_192 * 4 || !points.len().is_multiple_of(4) {
        return Err(EngineError::InvalidCommand(
            "vector stroke requires 1..8192 points".into(),
        ));
    }
    if points.iter().any(|value| !value.is_finite()) {
        return Err(EngineError::InvalidCommand(
            "vector stroke contains a non-finite point".into(),
        ));
    }
    let (tuples, remainder) = points.as_chunks::<4>();
    debug_assert!(remainder.is_empty());
    let points = tuples
        .iter()
        .map(|point| (point[0], point[1], point[2], point[3]))
        .collect();
    let stroke = {
        let revision = document(handle)?.revision();
        StrokeId::from_u128(
            revision
                .checked_add(1)
                .ok_or_else(|| EngineError::InvalidCommand("stroke ID space is exhausted".into()))?
                .into(),
        )
    };
    document_mut(handle)?.add_vector_stroke(
        ink_model::LayerId::from_u128(layer_id),
        stroke,
        points,
        closed,
    )
}

/// Apply an undoable affine transform to an editable vector stroke.
#[allow(clippy::too_many_arguments)]
pub fn transform_vector_stroke(
    handle: &mut DocumentHandle,
    layer_id: u128,
    stroke_id: u128,
    a: f32,
    b: f32,
    c: f32,
    d: f32,
    translate_x: f32,
    translate_y: f32,
) -> Result<u64, EngineError> {
    let values = [a, b, c, d, translate_x, translate_y];
    if values.iter().any(|value| !value.is_finite()) || (a * d - b * c).abs() < 0.000_001 {
        return Err(EngineError::InvalidCommand(
            "vector transform must be finite and invertible".into(),
        ));
    }
    document_mut(handle)?.transform_vector_stroke(
        ink_model::LayerId::from_u128(layer_id),
        ink_model::StrokeId::from_u128(stroke_id),
        a,
        b,
        c,
        d,
        translate_x,
        translate_y,
    )
}

/// Simplify one editable vector centerline with a bounded tolerance.
pub fn simplify_vector_stroke(
    handle: &mut DocumentHandle,
    layer_id: u128,
    stroke_id: u128,
    tolerance: f32,
) -> Result<u64, EngineError> {
    if !tolerance.is_finite() || !(0.0..=256.0).contains(&tolerance) || tolerance == 0.0 {
        return Err(EngineError::InvalidCommand(
            "vector simplification tolerance is outside limits".into(),
        ));
    }
    document_mut(handle)?.simplify_vector_stroke(
        ink_model::LayerId::from_u128(layer_id),
        ink_model::StrokeId::from_u128(stroke_id),
        tolerance,
    )
}

/// Join two compatible vector centerlines as one undoable operation.
pub fn connect_vector_strokes(
    handle: &mut DocumentHandle,
    layer_id: u128,
    first_id: u128,
    second_id: u128,
    tolerance: f32,
) -> Result<u64, EngineError> {
    if !tolerance.is_finite() || !(0.0..=256.0).contains(&tolerance) || tolerance == 0.0 {
        return Err(EngineError::InvalidCommand(
            "vector connection tolerance is outside limits".into(),
        ));
    }
    document_mut(handle)?.connect_vector_strokes(
        ink_model::LayerId::from_u128(layer_id),
        ink_model::StrokeId::from_u128(first_id),
        ink_model::StrokeId::from_u128(second_id),
        tolerance,
    )
}

/// Erase a circular segment from an editable vector stroke.
pub fn erase_vector_segment(
    handle: &mut DocumentHandle,
    layer_id: u128,
    stroke_id: u128,
    center_x: f32,
    center_y: f32,
    radius: f32,
) -> Result<u64, EngineError> {
    if [center_x, center_y, radius]
        .iter()
        .any(|value| !value.is_finite())
        || !(0.0..=4096.0).contains(&radius)
        || radius == 0.0
    {
        return Err(EngineError::InvalidCommand(
            "vector eraser radius is outside limits".into(),
        ));
    }
    document_mut(handle)?.erase_vector_segment(
        ink_model::LayerId::from_u128(layer_id),
        ink_model::StrokeId::from_u128(stroke_id),
        center_x,
        center_y,
        radius,
    )
}

/// Move one bounded editable vector centerline control point.
#[allow(clippy::too_many_arguments)]
pub fn set_vector_point(
    handle: &mut DocumentHandle,
    layer_id: u128,
    stroke_id: u128,
    index: u32,
    x: f32,
    y: f32,
    pressure: f32,
    tilt: f32,
) -> Result<u64, EngineError> {
    if [x, y, pressure, tilt]
        .iter()
        .any(|value| !value.is_finite())
        || !(0.0..=1.0).contains(&pressure)
    {
        return Err(EngineError::InvalidCommand(
            "vector control point contains an invalid value".into(),
        ));
    }
    document_mut(handle)?.set_vector_point(
        ink_model::LayerId::from_u128(layer_id),
        ink_model::StrokeId::from_u128(stroke_id),
        index,
        x,
        y,
        pressure,
        tilt,
    )
}

/// Apply an undoable affine transform to a raster layer. Coordinates are
/// document pixels; the matrix maps `(x, y)` to `(a*x + c*y + tx, b*x + d*y + ty)`.
#[allow(clippy::too_many_arguments)]
pub fn transform_layer(
    handle: &mut DocumentHandle,
    layer_id: u128,
    a: f32,
    b: f32,
    c: f32,
    d: f32,
    translate_x: f32,
    translate_y: f32,
) -> Result<u64, EngineError> {
    dispatch(
        handle,
        EditorCommand::TransformLayer {
            layer: ink_model::LayerId::from_u128(layer_id),
            a,
            b,
            c,
            d,
            tx: translate_x,
            ty: translate_y,
        },
    )
}

/// Export a selected Rust-owned brush preset as a native `.inkbrush` file.
#[allow(clippy::needless_pass_by_value)]
pub fn export_brush(
    handle: &mut DocumentHandle,
    brush_id: u128,
    path: String,
) -> Result<(), EngineError> {
    document_mut(handle)?.export_brush(BrushId::from_u128(brush_id), std::path::Path::new(&path))
}

/// Duplicate a built-in or imported brush into a new Rust-owned preset.
pub fn duplicate_brush(handle: &mut DocumentHandle, brush_id: u128) -> Result<u128, EngineError> {
    document_mut(handle)?
        .duplicate_brush(BrushId::from_u128(brush_id))
        .map(|id| id.0)
}

/// Rename a duplicated or imported user-owned brush.
pub fn rename_brush(
    handle: &mut DocumentHandle,
    brush_id: u128,
    name: String,
) -> Result<u64, EngineError> {
    document_mut(handle)?.rename_brush(BrushId::from_u128(brush_id), &name)
}

/// Import and install a decoded external brush; guided-only sources are
/// rejected until the user supplies the recreation inputs.
#[allow(clippy::needless_pass_by_value)]
pub fn import_brush(handle: &mut DocumentHandle, path: String) -> Result<u128, EngineError> {
    document_mut(handle)?
        .import_brush(std::path::Path::new(&path))
        .map(|id| id.0)
}

/// Import and install only when the source still matches the report hash.
#[allow(clippy::needless_pass_by_value)]
pub fn import_brush_verified(
    handle: &mut DocumentHandle,
    path: String,
    source_sha256: Vec<u8>,
) -> Result<u128, EngineError> {
    let hash: [u8; 32] = source_sha256.try_into().map_err(|_| {
        EngineError::InvalidCommand("brush report hash must contain 32 bytes".into())
    })?;
    document_mut(handle)?
        .import_brush_verified(std::path::Path::new(&path), Some(hash))
        .map(|id| id.0)
}

/// Import every member of a native brush pack when its report hash matches.
#[allow(clippy::needless_pass_by_value)]
pub fn import_brush_pack_verified(
    handle: &mut DocumentHandle,
    path: String,
    source_sha256: Vec<u8>,
) -> Result<Vec<u128>, EngineError> {
    let hash: [u8; 32] = source_sha256.try_into().map_err(|_| {
        EngineError::InvalidCommand("brush pack report hash must contain 32 bytes".into())
    })?;
    document_mut(handle)?
        .import_brush_pack_verified(std::path::Path::new(&path), Some(hash))
        .map(|ids| ids.into_iter().map(|id| id.0).collect())
}

/// Import every converted `.kpp` member of a Krita bundle transactionally.
#[allow(clippy::needless_pass_by_value)]
pub fn import_krita_bundle_verified(
    handle: &mut DocumentHandle,
    path: String,
    source_sha256: Vec<u8>,
) -> Result<Vec<u128>, EngineError> {
    let hash: [u8; 32] = source_sha256.try_into().map_err(|_| {
        EngineError::InvalidCommand("Krita bundle report hash must contain 32 bytes".into())
    })?;
    document_mut(handle)?
        .import_krita_bundle_verified(std::path::Path::new(&path), Some(hash))
        .map(|ids| ids.into_iter().map(|id| id.0).collect())
}

/// Return the original built-in Phase 2 brush library.
#[allow(dead_code)]
pub fn builtin_brushes() -> Vec<BrushSummary> {
    ink_brush::builtin_library()
        .into_iter()
        .map(|brush| BrushSummary {
            id: brush.id.0,
            is_builtin: true,
            name: brush.metadata.name,
            tags: brush.metadata.tags,
            diameter_px: 12.0,
            opacity: 1.0,
            spacing: 0.1,
            smoothing: 0.0,
            pressure_size: 0.0,
            pressure_opacity: 0.0,
            hardness: 0.75,
            texture_scale: 1.0,
            scatter: 0.0,
            rotation_jitter: 0.0,
            smudge: 0.0,
            wetness: 0.0,
            color_rgba: 0x1818_1cff,
            pressure_curve_points: Vec::new(),
            tip_resource_hash: None,
            grain_resource_hash: None,
        })
        .collect()
}

/// Return built-in and user-imported brushes for one document library.
pub fn brushes(handle: &DocumentHandle) -> Result<Vec<BrushSummary>, EngineError> {
    Ok(document(handle)?
        .brush_summaries()
        .into_iter()
        .map(|summary| BrushSummary {
            id: summary.id.0,
            is_builtin: summary.is_builtin,
            name: summary.name,
            tags: summary.tags,
            diameter_px: summary.diameter_px,
            opacity: summary.opacity,
            spacing: summary.spacing,
            smoothing: summary.smoothing,
            pressure_size: summary.pressure_size,
            pressure_opacity: summary.pressure_opacity,
            hardness: summary.hardness,
            texture_scale: summary.texture_scale,
            scatter: summary.scatter,
            rotation_jitter: summary.rotation_jitter,
            smudge: summary.smudge,
            wetness: summary.wetness,
            color_rgba: summary.color_rgba,
            pressure_curve_points: summary.pressure_curve_points,
            tip_resource_hash: summary.tip_resource_hash,
            grain_resource_hash: summary.grain_resource_hash,
        })
        .collect())
}

/// Finish the active built-in stroke as one undoable action.
pub fn end_stroke(handle: &mut DocumentHandle) -> Result<u64, EngineError> {
    let stroke = document_state(handle)?
        .active_stroke
        .ok_or_else(|| EngineError::InvalidCommand("stroke is not active".into()))?;
    dispatch(handle, EditorCommand::EndStroke { stroke })
}

/// Cancel the active stroke and roll back its in-progress pixels.
pub fn cancel_stroke(handle: &mut DocumentHandle) -> Result<u64, EngineError> {
    let stroke = document_state(handle)?
        .active_stroke
        .ok_or_else(|| EngineError::InvalidCommand("stroke is not active".into()))?;
    dispatch(handle, EditorCommand::CancelStroke { stroke })
}

/// Append a packed pointer packet to the engine.
pub fn push_pointer_packet(handle: &mut DocumentHandle, packet: &[u8]) -> Result<(), EngineError> {
    document_mut(handle)?.push_pointer_packet(packet)
}

/// Atomically save a native project.
pub fn save_document(handle: &DocumentHandle, path: String) -> Result<(), String> {
    let path = std::path::PathBuf::from(path);
    document(handle)
        .map_err(|error| error.to_string())?
        .save_as(&path)
        .map_err(|error| error.to_string())
}

/// Attach validated comic structure to the native document before checkpoint.
pub fn attach_comic_project(
    handle: &mut DocumentHandle,
    bytes: Vec<u8>,
) -> Result<u64, EngineError> {
    document_mut(handle)?.set_comic_json(bytes)
}

/// Read the Rust-owned comic structure attached to a native document.
pub fn read_comic_project(handle: &DocumentHandle) -> Option<Vec<u8>> {
    document(handle)
        .ok()
        .and_then(|document| document.comic_json())
}

/// Export the current visible raster layer as PNG.
pub fn export_png(handle: &DocumentHandle, path: String) -> Result<(), EngineError> {
    let path = std::path::PathBuf::from(path);
    document(handle)?.export_png(&path)
}

/// Export the current visible composite in a Phase 2 format.
#[allow(dead_code)]
#[allow(clippy::needless_pass_by_value)]
pub fn export_document(
    handle: &DocumentHandle,
    path: String,
    format: ExportKind,
) -> Result<(), EngineError> {
    let format = match format {
        ExportKind::Png => ink_export::ExportFormat::Png,
        ExportKind::Jpeg => ink_export::ExportFormat::Jpeg,
        ExportKind::Webp => ink_export::ExportFormat::Webp,
        ExportKind::OpenRaster => ink_export::ExportFormat::OpenRaster,
        ExportKind::Svg => ink_export::ExportFormat::Svg,
        ExportKind::Psd => ink_export::ExportFormat::Psd,
    };
    document(handle)?.export(std::path::Path::new(&path), format)
}

/// Export the committed in-session stroke history for a local time-lapse tool.
#[allow(dead_code)]
#[allow(clippy::needless_pass_by_value)]
pub fn export_time_lapse(handle: &DocumentHandle, path: String) -> Result<(), EngineError> {
    document(handle)?.export_time_lapse(std::path::Path::new(&path))
}

/// Read one immutable BGRA tile for the Flutter cache.
pub fn read_tile(
    handle: &DocumentHandle,
    layer: u128,
    x: i32,
    y: i32,
) -> Result<Vec<u8>, EngineError> {
    document(handle)?.read_tile(ink_model::LayerId::from_u128(layer), TileCoord { x, y })
}

/// Read one authoritative committed composite tile. The payload remains
/// fixed-size BGRA bytes and is kept off the JSON/control plane.
#[flutter_rust_bridge::frb]
pub fn read_composite_tile(
    handle: &DocumentHandle,
    x: i32,
    y: i32,
) -> Result<Vec<u8>, EngineError> {
    document(handle)?.read_composite_tile(TileCoord { x, y })
}

/// Capture the requested tile bytes and revision without doing pixel
/// composition while holding the document handle. `coordinates` is a flat
/// x,y list. The returned opaque snapshot has its own bridge lock, so pointer
/// packets can continue while the caller composites its immutable pixels.
#[flutter_rust_bridge::frb]
pub fn capture_composite_tiles_snapshot(
    handle: &DocumentHandle,
    coordinates: &[i32],
) -> Result<CompositeTilesSnapshotHandle, EngineError> {
    if !coordinates.len().is_multiple_of(2) {
        return Err(EngineError::InvalidCommand(
            "composite tile snapshot coordinates must be x,y pairs".into(),
        ));
    }
    let tile_count = coordinates.len() / 2;
    if tile_count > MAX_COMPOSITE_SNAPSHOT_TILES {
        return Err(EngineError::InvalidCommand(format!(
            "composite tile snapshot exceeds the {MAX_COMPOSITE_SNAPSHOT_TILES}-tile bridge limit"
        )));
    }
    let tile_coordinates = coordinates
        .as_chunks::<2>()
        .0
        .iter()
        .map(|pair| TileCoord {
            x: pair[0],
            y: pair[1],
        })
        .collect::<Vec<_>>();
    let snapshot = {
        let document = document(handle)?;
        document.capture_composite_tile_snapshot(&tile_coordinates)
    };
    Ok(CompositeTilesSnapshotHandle {
        snapshot: Mutex::new(Some(snapshot)),
        coordinates: Mutex::new(tile_coordinates),
    })
}

/// Composite an immutable tile snapshot captured by
/// [`capture_composite_tiles_snapshot`]. This call uses the snapshot's own
/// opaque handle, leaving the document handle free for incoming pointer work.
#[flutter_rust_bridge::frb]
pub fn compose_composite_tiles_snapshot(
    snapshot_handle: &CompositeTilesSnapshotHandle,
) -> Result<Vec<u8>, EngineError> {
    let snapshot = snapshot_handle
        .snapshot
        .lock()
        .map_err(|_| EngineError::InvalidCommand("composite snapshot lock is poisoned".into()))?
        .take()
        .ok_or_else(|| {
            EngineError::InvalidCommand("composite tile snapshot was already consumed".into())
        })?;
    let coordinates = {
        let mut coordinates = snapshot_handle.coordinates.lock().map_err(|_| {
            EngineError::InvalidCommand("composite coordinates lock is poisoned".into())
        })?;
        std::mem::take(&mut *coordinates)
    };
    let tile_count = coordinates.len();
    let revision = snapshot.revision();
    let tiles = snapshot.read_tiles(&coordinates)?;
    let mut packet = Vec::with_capacity(
        COMPOSITE_SNAPSHOT_HEADER_BYTES
            + tile_count.saturating_mul(COMPOSITE_SNAPSHOT_RECORD_BYTES),
    );
    packet.extend(COMPOSITE_SNAPSHOT_PACKET_VERSION.to_le_bytes());
    packet.extend(0_u16.to_le_bytes());
    packet.extend(revision.to_le_bytes());
    packet.extend(u32::try_from(tile_count).unwrap_or(u32::MAX).to_le_bytes());
    for (coordinate, pixels) in coordinates.iter().zip(tiles) {
        if pixels.len() != COMPOSITE_SNAPSHOT_TILE_BYTES {
            return Err(EngineError::InvalidCommand(
                "composite tile snapshot returned an invalid tile size".into(),
            ));
        }
        packet.extend(coordinate.x.to_le_bytes());
        packet.extend(coordinate.y.to_le_bytes());
        packet.extend(pixels);
    }
    if packet.len() > MAX_TILE_UPDATE_PACKET_BYTES {
        return Err(EngineError::InvalidCommand(
            "composite tile snapshot exceeded its 16 MiB bridge limit".into(),
        ));
    }
    Ok(packet)
}

/// Read a bounded RGBA layer thumbnail for the responsive layer panel.
pub fn read_layer_thumbnail(
    handle: &DocumentHandle,
    layer: u128,
    size: u16,
) -> Result<Vec<u8>, EngineError> {
    document(handle)?.read_layer_thumbnail(ink_model::LayerId::from_u128(layer), size)
}

/// Return the current document revision.
pub fn revision(handle: &DocumentHandle) -> Result<u64, EngineError> {
    Ok(document(handle)?.revision())
}

/// Return immutable canvas metadata for viewport and tile-cache setup.
pub fn document_info(handle: &DocumentHandle) -> Result<DocumentInfo, EngineError> {
    let document = document(handle)?;
    let primary_raster_layer = document.primary_raster_layer().ok_or_else(|| {
        EngineError::InvalidCommand("document has no raster layer available".into())
    })?;
    Ok(DocumentInfo {
        width_px: document.spec.width_px,
        height_px: document.spec.height_px,
        dpi: document.spec.dpi,
        primary_raster_layer: primary_raster_layer.0,
    })
}

/// Drain engine events for the Dart stream adapter.
pub fn drain_events(handle: &mut DocumentHandle) -> Result<Vec<EngineEvent>, EngineError> {
    document_mut(handle)?.drain_events()
}

/// Drain dirty-tile notifications as a compact binary packet.
///
/// The packet is intentionally not JSON: it crosses the high-frequency
/// control/data boundary with fixed-width little-endian fields. Version 3
/// drains tile invalidations and exact stroke-tile coverage from the same
/// event snapshot. Version 4 header: `u16 version`, `u16 flags`, `u32 tile_count`,
/// `u32 acknowledgement_count`. Tile records contain a `u64 revision`,
/// `u128 layer_id`, `i32 tile_x`, and `i32 tile_y`; acknowledgements retain
/// the fixed-width prefix documented by `drain_stroke_acknowledgements`, then
/// append exact dirty composite-tile coordinates and bounded stroke metrics.
#[allow(clippy::too_many_lines)]
pub fn drain_tile_updates(handle: &mut DocumentHandle) -> Result<Vec<u8>, EngineError> {
    let initial_snapshot = !document_state(handle)?.tile_snapshot_sent;
    // The initial tile snapshot is required to display an opened document.
    // During drawing, however, waiting for the render worker's EngineState
    // lock here would hold DocumentHandleState and block pointer/GPU bridge
    // calls on the same document. Skip this poll when the worker is busy; the
    // next 16 ms canvas poll will retry while the GPU remains responsive.
    let event_snapshot = if initial_snapshot {
        Some(document(handle)?.drain_events_available()?)
    } else {
        document(handle)?.try_drain_events_available()?
    };
    let Some((events, captured_revision)) = event_snapshot else {
        let mut packet = Vec::with_capacity(12);
        packet.extend(TILE_UPDATE_PACKET_VERSION.to_le_bytes());
        packet.extend(TILE_UPDATE_PACKET_RENDER_BUSY.to_le_bytes());
        packet.extend(0u32.to_le_bytes());
        packet.extend(0u32.to_le_bytes());
        return Ok(packet);
    };
    let mut full_redraw = initial_snapshot;
    let mut revision = captured_revision;
    let mut records = Vec::new();
    let mut acknowledgements = Vec::new();
    for event in events {
        match event {
            EngineEvent::TilesDirty {
                revision: event_revision,
                tiles,
            } => {
                revision = revision.max(event_revision);
                records.extend(tiles.into_iter().map(|tile| {
                    (
                        event_revision,
                        tile.layer.0,
                        tile.coordinate.x,
                        tile.coordinate.y,
                    )
                }));
            }
            EngineEvent::CompositeTilesDirty {
                revision: event_revision,
                tiles,
            } => {
                revision = revision.max(event_revision);
                records.extend(tiles.into_iter().map(|coordinate| {
                    (
                        event_revision,
                        COMPOSITE_TILE_LAYER,
                        coordinate.x,
                        coordinate.y,
                    )
                }));
            }
            EngineEvent::LayersChanged {
                revision: event_revision,
            } => {
                revision = revision.max(event_revision);
                full_redraw = true;
            }
            EngineEvent::StrokeAcknowledged {
                stroke,
                highest_committed_sequence,
                revision: event_revision,
                dirty_bounds,
                dirty_tiles,
                metrics,
            } => {
                revision = revision.max(event_revision);
                acknowledgements.push(ink_engine::StrokeAcknowledgement {
                    stroke,
                    highest_committed_sequence,
                    revision: event_revision,
                    dirty_bounds,
                    dirty_tiles,
                    metrics,
                });
            }
            EngineEvent::HistoryChanged {
                revision: event_revision,
                ..
            }
            | EngineEvent::DocumentChanged {
                revision: event_revision,
            } => {
                revision = revision.max(event_revision);
            }
        }
    }
    records.sort_unstable();
    records.dedup();
    if full_redraw {
        records.extend(
            document(handle)?
                .tile_descriptors()
                .into_iter()
                .map(|tile| (revision, tile.layer.0, tile.coordinate.x, tile.coordinate.y)),
        );
        records.sort_unstable();
        records.dedup();
    }
    if records.len() > MAX_TILE_UPDATE_RECORDS {
        return Err(EngineError::InvalidCommand(
            "tile update batch exceeds the bridge safety limit".into(),
        ));
    }
    if acknowledgements.len() > MAX_STROKE_ACK_RECORDS {
        return Err(EngineError::InvalidCommand(
            "stroke acknowledgement batch exceeds the bridge safety limit".into(),
        ));
    }
    document_state(handle)?.tile_snapshot_sent = true;

    let record_count = u32::try_from(records.len()).unwrap_or(u32::MAX);
    let acknowledgement_count = u32::try_from(acknowledgements.len()).unwrap_or(u32::MAX);
    let acknowledgement_bytes = acknowledgements
        .iter()
        .fold(0usize, |total, acknowledgement| {
            total.saturating_add(
                STROKE_COMMIT_ACK_BASE_BYTES
                    .saturating_add(acknowledgement.dirty_tiles.len().saturating_mul(8)),
            )
        });
    let packet_capacity = 12usize
        .saturating_add(record_count as usize * TILE_UPDATE_RECORD_BYTES)
        .saturating_add(acknowledgement_bytes);
    if packet_capacity > MAX_TILE_UPDATE_PACKET_BYTES {
        return Err(EngineError::InvalidCommand(
            "canvas commit batch exceeds the 16 MiB bridge safety limit".into(),
        ));
    }
    let mut packet = Vec::with_capacity(packet_capacity);
    packet.extend(TILE_UPDATE_PACKET_VERSION.to_le_bytes());
    packet.extend(
        if full_redraw {
            TILE_UPDATE_PACKET_FULL_REDRAW
        } else {
            0
        }
        .to_le_bytes(),
    );
    packet.extend(record_count.to_le_bytes());
    packet.extend(acknowledgement_count.to_le_bytes());
    for (event_revision, layer, x, y) in records.into_iter().take(record_count as usize) {
        packet.extend(event_revision.to_le_bytes());
        packet.extend(layer.to_le_bytes());
        packet.extend(x.to_le_bytes());
        packet.extend(y.to_le_bytes());
    }
    for acknowledgement in acknowledgements {
        packet.extend(acknowledgement.stroke.0.to_le_bytes());
        packet.extend(acknowledgement.revision.to_le_bytes());
        packet.extend(acknowledgement.highest_committed_sequence.to_le_bytes());
        let bounds = acknowledgement
            .dirty_bounds
            .unwrap_or(ink_engine::TileBounds {
                min_x: 1,
                min_y: 1,
                max_x: 0,
                max_y: 0,
            });
        packet.extend(bounds.min_x.to_le_bytes());
        packet.extend(bounds.min_y.to_le_bytes());
        packet.extend(bounds.max_x.to_le_bytes());
        packet.extend(bounds.max_y.to_le_bytes());
        let dirty_tile_count = u32::try_from(acknowledgement.dirty_tiles.len()).unwrap_or(u32::MAX);
        packet.extend(dirty_tile_count.to_le_bytes());
        for coordinate in acknowledgement.dirty_tiles {
            packet.extend(coordinate.x.to_le_bytes());
            packet.extend(coordinate.y.to_le_bytes());
        }
        packet.extend(acknowledgement.metrics.confirmed_sample_count.to_le_bytes());
        packet.extend(acknowledgement.metrics.path_length.to_le_bytes());
        packet.extend(acknowledgement.metrics.direct_length.to_le_bytes());
        packet.extend(acknowledgement.metrics.legacy_dabs.to_le_bytes());
        packet.extend(acknowledgement.metrics.compiled_dabs.to_le_bytes());
        packet.extend(acknowledgement.metrics.cpu_tiles_written.to_le_bytes());
        packet.extend(
            acknowledgement
                .metrics
                .compiled_cpu_tile_updates
                .to_le_bytes(),
        );
        packet.extend(acknowledgement.metrics.work_segments.to_le_bytes());
        packet.push(u8::from(acknowledgement.metrics.work_limit_reached));
    }
    Ok(packet)
}

/// Drain fixed-width acknowledgements for confirmed stroke sequences. The
/// packet is intentionally separate from tile invalidations so a UI can track
/// pointer progress without consuming paint refresh events.
///
/// Header: `u16 version`, `u16 flags`, `u32 record_count`. Each record is
/// `u128 stroke_id`, `u64 revision`, `u32 highest_sequence`, followed by four
/// little-endian `i32` tile bounds. An empty bounds rectangle (`min > max`) is
/// used when the confirmed sample produced no visible dirty tile.
pub fn drain_stroke_acknowledgements(handle: &mut DocumentHandle) -> Result<Vec<u8>, EngineError> {
    let acknowledgements = document_mut(handle)?.drain_stroke_acknowledgements()?;
    if acknowledgements.len() > MAX_STROKE_ACK_RECORDS {
        return Err(EngineError::InvalidCommand(
            "stroke acknowledgement batch exceeds the bridge safety limit".into(),
        ));
    }
    let count = u32::try_from(acknowledgements.len()).unwrap_or(u32::MAX);
    let mut packet = Vec::with_capacity(
        8usize.saturating_add(
            usize::try_from(count)
                .unwrap_or(0)
                .saturating_mul(STROKE_ACK_RECORD_BYTES),
        ),
    );
    packet.extend(STROKE_ACK_PACKET_VERSION.to_le_bytes());
    packet.extend(0_u16.to_le_bytes());
    packet.extend(count.to_le_bytes());
    for acknowledgement in acknowledgements {
        packet.extend(acknowledgement.stroke.0.to_le_bytes());
        packet.extend(acknowledgement.revision.to_le_bytes());
        packet.extend(acknowledgement.highest_committed_sequence.to_le_bytes());
        let bounds = acknowledgement
            .dirty_bounds
            .unwrap_or(ink_engine::TileBounds {
                min_x: 1,
                min_y: 1,
                max_x: 0,
                max_y: 0,
            });
        packet.extend(bounds.min_x.to_le_bytes());
        packet.extend(bounds.min_y.to_le_bytes());
        packet.extend(bounds.max_x.to_le_bytes());
        packet.extend(bounds.max_y.to_le_bytes());
    }
    Ok(packet)
}

/// Return an immutable layer projection.
pub fn layers(handle: &DocumentHandle) -> Result<Vec<Layer>, EngineError> {
    Ok(document(handle)?.layers())
}

/// Read the durable layer-panel state for the active document/page.
pub fn layer_panel_state(handle: &DocumentHandle) -> Result<LayerPanelStateView, EngineError> {
    let state = document(handle)?.layer_panel_state();
    Ok(LayerPanelStateView {
        primary_layer_id: state.primary_layer.map(|layer| layer.0),
        collapsed_group_ids: state
            .collapsed_groups
            .into_iter()
            .map(|group| group.0.to_string())
            .collect(),
    })
}

/// Persist the primary target and collapsed groups without creating a content
/// history entry. Validation and project revision ownership stay in Rust.
pub fn set_layer_panel_state(
    handle: &mut DocumentHandle,
    primary_layer_id: Option<u128>,
    collapsed_group_ids: Vec<u128>,
) -> Result<u64, EngineError> {
    document_mut(handle)?.set_layer_panel_state(
        primary_layer_id.map(ink_model::LayerId::from_u128),
        collapsed_group_ids
            .into_iter()
            .map(ink_model::LayerId::from_u128)
            .collect(),
    )
}

/// Return immutable layer projections without leaking the engine's layer map.
pub fn layer_summaries(handle: &DocumentHandle) -> Result<Vec<LayerSummary>, EngineError> {
    let document = document(handle)?;
    let capabilities = document
        .layer_drag_capabilities()?
        .into_iter()
        .map(|capability| (capability.layer_id, capability))
        .collect::<std::collections::HashMap<_, _>>();
    let action_capabilities = document
        .layer_action_capabilities()?
        .into_iter()
        .map(|capability| (capability.layer_id, capability))
        .collect::<std::collections::HashMap<_, _>>();
    document
        .layers()
        .into_iter()
        .map(|layer| {
            let capability = capabilities
                .get(&layer.id)
                .ok_or(EngineError::InvalidLayer)?;
            let actions = action_capabilities
                .get(&layer.id)
                .ok_or(EngineError::InvalidLayer)?;
            Ok(LayerSummary {
                id: layer.id.0,
                parent: layer.parent.map(|id| id.0),
                mask_owner: layer.mask_owner.map(|id| id.0),
                mask_enabled: layer.mask_enabled,
                mask_inverted: layer.mask_inverted,
                order: layer.order,
                kind: layer_kind_name(layer.kind).to_owned(),
                name: layer.name,
                opacity: layer.opacity,
                visible: layer.visible,
                blend_mode: blend_mode_name(layer.blend_mode).to_owned(),
                group_mode: group_mode_name(layer.group_mode).to_owned(),
                alpha_lock: layer.alpha_lock,
                locked: layer.locked,
                clipping: layer.clipping,
                reference: layer.reference,
                label_rgba: layer.label.map(|value| {
                    (u32::from(value.r) << 24)
                        | (u32::from(value.g) << 16)
                        | (u32::from(value.b) << 8)
                        | u32::from(value.a)
                }),
                adjustment_brightness: match layer.adjustment {
                    Some(LayerAdjustment::BrightnessContrast { brightness, .. }) => brightness,
                    None => 0,
                },
                adjustment_contrast: match layer.adjustment {
                    Some(LayerAdjustment::BrightnessContrast { contrast, .. }) => contrast,
                    None => 0,
                },
                can_drag: capability.can_drag,
                drag_reason: capability.drag_reason.clone(),
                can_receive_layers: capability.can_receive_layers,
                receive_reason: capability.receive_reason.clone(),
                can_edit_properties: actions.can_edit_properties,
                edit_properties_reason: actions.edit_properties_reason.clone(),
                can_duplicate: actions.can_duplicate,
                duplicate_reason: actions.duplicate_reason.clone(),
                can_delete: actions.can_delete,
                delete_reason: actions.delete_reason.clone(),
                can_ungroup: actions.can_ungroup,
                ungroup_reason: actions.ungroup_reason.clone(),
                can_apply_mask: actions.can_apply_mask,
                apply_mask_reason: actions.apply_mask_reason.clone(),
                merge_down_reason: actions.merge_down_reason.clone(),
            })
        })
        .collect()
}

/// Return editable vector-stroke metadata for one vector layer.
pub fn vector_stroke_summaries(
    handle: &DocumentHandle,
    layer_id: u128,
) -> Result<Vec<VectorStrokeSummary>, EngineError> {
    document(handle)?
        .vector_stroke_summaries(ink_model::LayerId::from_u128(layer_id))
        .map(|strokes| {
            strokes
                .into_iter()
                .map(|(id, point_count, bounds, points)| VectorStrokeSummary {
                    id: id.0,
                    point_count,
                    points,
                    min_x: bounds[0],
                    min_y: bounds[1],
                    max_x: bounds[2],
                    max_y: bounds[3],
                })
                .collect()
        })
}

#[cfg(test)]
mod tests;
