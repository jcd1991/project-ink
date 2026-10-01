//! Public control-plane functions exposed to Flutter through FRB.

#![allow(clippy::needless_pass_by_value)]

use ink_comic::{
    Balloon, BalloonShape, ComicProject, EffectLine, MaterialAsset, Panel, PanelShape,
    ProjectTemplate, Rect, TextOrientation, TextStyle, ToneLayer,
};
pub use ink_command::EditorCommand;
use ink_engine::Document;
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
                        .chunks_exact(2)
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
    let mask_points = vec![
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
                        .chunks_exact(2)
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
        .chunks_exact(2)
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
    if tail.len() % 2 != 0 {
        return Err(EngineError::InvalidCommand(
            "balloon tail requires coordinate pairs".into(),
        ));
    }
    let tail = tail
        .chunks_exact(2)
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
    if points.len() < 4 || points.len() % 2 != 0 {
        return Err(EngineError::InvalidCommand(
            "effect line requires at least two coordinate pairs".into(),
        ));
    }
    let points = points
        .chunks_exact(2)
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
    if points.len() < 4 || points.len() % 2 != 0 {
        return Err(EngineError::InvalidCommand(
            "effect line requires at least two coordinate pairs".into(),
        ));
    }
    let points = points
        .chunks_exact(2)
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
    if points.len() % 2 != 0 {
        return Err(EngineError::InvalidCommand(
            "balloon tail requires coordinate pairs".into(),
        ));
    }
    let tail = points
        .chunks_exact(2)
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
    if tail.len() % 2 != 0 {
        return Err(EngineError::InvalidCommand(
            "balloon tail requires coordinate pairs".into(),
        ));
    }
    let tail = tail
        .chunks_exact(2)
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
    if points.len() < 6 || points.len() % 2 != 0 {
        return Err(EngineError::InvalidCommand(
            "panel polygon requires at least three coordinate pairs".into(),
        ));
    }
    let polygon = points
        .chunks_exact(2)
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
    if points.len() < 4 || points.len() % 2 != 0 {
        return Err(EngineError::InvalidCommand(
            "effect line requires at least two coordinate pairs".into(),
        ));
    }
    let points = points
        .chunks_exact(2)
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
    if points.len() < 4 || points.len() % 2 != 0 {
        return Err(EngineError::InvalidCommand(
            "effect line requires at least two coordinate pairs".into(),
        ));
    }
    let points = points
        .chunks_exact(2)
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
    if points.len() % 2 != 0 {
        return Err(EngineError::InvalidCommand(
            "balloon tail requires coordinate pairs".into(),
        ));
    }
    let tail = points
        .chunks_exact(2)
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
    pub order: u32,
    pub kind: String,
    pub name: String,
    pub opacity: u16,
    pub visible: bool,
    pub blend_mode: String,
    pub group_mode: String,
    pub alpha_lock: bool,
    pub clipping: bool,
    pub reference: bool,
    pub label_rgba: Option<u32>,
    pub adjustment_brightness: i16,
    pub adjustment_contrast: i16,
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

/// Duplicate a leaf layer within the active page document.
pub fn duplicate_layer(handle: &mut DocumentHandle, source: u128) -> Result<u128, EngineError> {
    document_mut(handle)?
        .duplicate_layer(ink_model::LayerId::from_u128(source))
        .map(|id| id.0)
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

/// Read a bounded group of authoritative composite tiles from one immutable
/// document revision. `coordinates` is a flat x,y list; each packet record
/// contains its coordinates followed by one fixed-size BGRA tile.
#[flutter_rust_bridge::frb]
pub fn read_composite_tiles_snapshot(
    handle: &DocumentHandle,
    coordinates: &[i32],
) -> Result<Vec<u8>, EngineError> {
    if coordinates.len() % 2 != 0 {
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
        .chunks_exact(2)
        .map(|pair| TileCoord {
            x: pair[0],
            y: pair[1],
        })
        .collect::<Vec<_>>();
    // Capture an immutable set of only the requested layer tiles while the
    // handle/state locks are held, then release the bridge handle lock before
    // the much more expensive per-pixel composite pass. Pointer packets and
    // renderer polls must remain serviceable while these pixels are built.
    let snapshot = {
        let document = document(handle)?;
        document.capture_composite_tile_snapshot(&tile_coordinates)
    };
    let revision = snapshot.revision();
    let tiles = snapshot.read_tiles(&tile_coordinates)?;
    let mut packet = Vec::with_capacity(
        COMPOSITE_SNAPSHOT_HEADER_BYTES
            + tile_count.saturating_mul(COMPOSITE_SNAPSHOT_RECORD_BYTES),
    );
    packet.extend(COMPOSITE_SNAPSHOT_PACKET_VERSION.to_le_bytes());
    packet.extend(0_u16.to_le_bytes());
    packet.extend(revision.to_le_bytes());
    packet.extend(u32::try_from(tile_count).unwrap_or(u32::MAX).to_le_bytes());
    for (coordinate, pixels) in tile_coordinates.iter().zip(tiles) {
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
/// event snapshot. Header: `u16 version`, `u16 flags`, `u32 tile_count`,
/// `u32 acknowledgement_count`. Tile records are `u64 revision`, `u128
/// `layer_id`, `i32 tile_x`, and `i32 tile_y`; acknowledgement records retain
/// the fixed-width prefix documented by `drain_stroke_acknowledgements`, then
/// append exact dirty composite-tile coordinates and bounded stroke metrics.
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

/// Return immutable layer projections without leaking the engine's layer map.
pub fn layer_summaries(handle: &DocumentHandle) -> Result<Vec<LayerSummary>, EngineError> {
    Ok(document(handle)?
        .layers()
        .into_iter()
        .map(|layer| LayerSummary {
            id: layer.id.0,
            parent: layer.parent.map(|id| id.0),
            order: layer.order,
            kind: layer_kind_name(layer.kind).to_owned(),
            name: layer.name,
            opacity: layer.opacity,
            visible: layer.visible,
            blend_mode: blend_mode_name(layer.blend_mode).to_owned(),
            group_mode: group_mode_name(layer.group_mode).to_owned(),
            alpha_lock: layer.alpha_lock,
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
        })
        .collect())
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
mod tests {
    use super::*;
    use ink_model::{ColorSpace, LayerKind, Rgba8};

    #[test]
    fn tile_drain_keeps_stroke_acknowledgements_with_their_tiles() {
        let mut handle = create_document(
            0x3386,
            DocumentSpec {
                width_px: 64,
                height_px: 64,
                dpi: 144.0,
                color_space: ColorSpace::Srgb,
                background: Rgba8::default(),
            },
        )
        .expect("valid document");
        let primary = document_info(&handle)
            .expect("document info")
            .primary_raster_layer;
        begin_brush_stroke_on_layer(&mut handle, 1, primary).expect("begin stroke");
        let mut packet = vec![1, 0, 1, 0];
        packet.extend([0_u8; 48]);
        packet[8..10].copy_from_slice(&1_u16.to_le_bytes()); // actual sample
        packet[10] = 1; // stylus
        packet[11] = 0; // down
        packet[12..16].copy_from_slice(&24.0_f32.to_le_bytes());
        packet[16..20].copy_from_slice(&24.0_f32.to_le_bytes());
        packet[20..24].copy_from_slice(&1.0_f32.to_le_bytes());
        push_pointer_packet(&mut handle, &packet).expect("pointer packet");

        let updates = loop {
            let updates = drain_tile_updates(&mut handle).expect("atomic canvas drain");
            let acknowledgement_count =
                u32::from_le_bytes(updates[8..12].try_into().expect("ack count"));
            if acknowledgement_count > 0 {
                break updates;
            }
            std::thread::yield_now();
        };
        assert_eq!(u16::from_le_bytes([updates[0], updates[1]]), 4);
        let tile_count = u32::from_le_bytes(updates[4..8].try_into().expect("tile count"));
        let acknowledgement_count =
            u32::from_le_bytes(updates[8..12].try_into().expect("ack count"));
        assert!(tile_count > 0, "CPU tile invalidation must be present");
        assert_eq!(acknowledgement_count, 1);
        let acknowledgement_offset = 12 + tile_count as usize * TILE_UPDATE_RECORD_BYTES;
        let acknowledged_revision = u64::from_le_bytes(
            updates[acknowledgement_offset + 16..acknowledgement_offset + 24]
                .try_into()
                .expect("ack revision"),
        );
        let has_matching_composite = (0..tile_count as usize).any(|index| {
            let offset = 12 + index * TILE_UPDATE_RECORD_BYTES;
            let revision = u64::from_le_bytes(
                updates[offset..offset + 8]
                    .try_into()
                    .expect("tile revision"),
            );
            let layer = u128::from_le_bytes(
                updates[offset + 8..offset + 24]
                    .try_into()
                    .expect("tile layer"),
            );
            revision == acknowledged_revision && layer == COMPOSITE_TILE_LAYER
        });
        assert!(
            has_matching_composite,
            "the matching CPU composite invalidation must share the ack batch"
        );
        let committed_tile_count = u32::from_le_bytes(
            updates[acknowledgement_offset + 44..acknowledgement_offset + 48]
                .try_into()
                .expect("committed tile count"),
        );
        assert!(committed_tile_count > 0);
        let committed_tile_x = i32::from_le_bytes(
            updates[acknowledgement_offset + 48..acknowledgement_offset + 52]
                .try_into()
                .expect("committed tile x"),
        );
        let committed_tile_y = i32::from_le_bytes(
            updates[acknowledgement_offset + 52..acknowledgement_offset + 56]
                .try_into()
                .expect("committed tile y"),
        );
        let has_exact_composite = (0..tile_count as usize).any(|index| {
            let offset = 12 + index * TILE_UPDATE_RECORD_BYTES;
            let layer = u128::from_le_bytes(
                updates[offset + 8..offset + 24]
                    .try_into()
                    .expect("composite layer"),
            );
            let x = i32::from_le_bytes(
                updates[offset + 24..offset + 28]
                    .try_into()
                    .expect("composite x"),
            );
            let y = i32::from_le_bytes(
                updates[offset + 28..offset + 32]
                    .try_into()
                    .expect("composite y"),
            );
            layer == COMPOSITE_TILE_LAYER && x == committed_tile_x && y == committed_tile_y
        });
        assert!(
            has_exact_composite,
            "ack must name a published composite tile"
        );
        let metrics_offset = acknowledgement_offset + 48 + committed_tile_count as usize * 8;
        assert_eq!(
            u64::from_le_bytes(
                updates[metrics_offset..metrics_offset + 8]
                    .try_into()
                    .expect("confirmed sample count"),
            ),
            1,
        );
        assert_eq!(
            f64::from_le_bytes(
                updates[metrics_offset + 8..metrics_offset + 16]
                    .try_into()
                    .expect("path length"),
            ),
            0.0,
        );
        assert_eq!(
            u64::from_le_bytes(
                updates[metrics_offset + 56..metrics_offset + 64]
                    .try_into()
                    .expect("work segment count"),
            ),
            0,
        );
        assert_eq!(updates[metrics_offset + 64], 0);
        end_stroke(&mut handle).expect("close stroke");
        close_document(&mut handle).expect("close document");
    }

    #[test]
    fn composite_tile_snapshot_has_one_revision_for_all_pixels() {
        let mut handle = create_document(
            0x3387,
            DocumentSpec {
                width_px: 128,
                height_px: 128,
                dpi: 144.0,
                color_space: ColorSpace::Srgb,
                background: Rgba8::default(),
            },
        )
        .expect("valid document");
        let layer = document_info(&handle)
            .expect("document info")
            .primary_raster_layer;
        begin_brush_stroke_on_layer(&mut handle, 1, layer).expect("begin stroke");
        let mut packet = vec![1, 0, 1, 0];
        packet.extend([0_u8; 48]);
        packet[8..10].copy_from_slice(&1_u16.to_le_bytes());
        packet[10] = 1;
        packet[11] = 0;
        packet[12..16].copy_from_slice(&48.0_f32.to_le_bytes());
        packet[16..20].copy_from_slice(&48.0_f32.to_le_bytes());
        packet[20..24].copy_from_slice(&1.0_f32.to_le_bytes());
        push_pointer_packet(&mut handle, &packet).expect("queue stroke sample");

        let snapshot =
            read_composite_tiles_snapshot(&handle, &[0, 0, 0, 0]).expect("read coherent snapshot");
        assert_eq!(u16::from_le_bytes([snapshot[0], snapshot[1]]), 1);
        assert_eq!(u16::from_le_bytes([snapshot[2], snapshot[3]]), 0);
        let snapshot_revision =
            u64::from_le_bytes(snapshot[4..12].try_into().expect("snapshot revision"));
        assert_eq!(u32::from_le_bytes(snapshot[12..16].try_into().unwrap()), 2);
        assert_eq!(i32::from_le_bytes(snapshot[16..20].try_into().unwrap()), 0);
        assert_eq!(i32::from_le_bytes(snapshot[20..24].try_into().unwrap()), 0);
        let first_tile = &snapshot[24..24 + COMPOSITE_SNAPSHOT_TILE_BYTES];
        let second_record = COMPOSITE_SNAPSHOT_HEADER_BYTES + COMPOSITE_SNAPSHOT_RECORD_BYTES;
        assert_eq!(
            i32::from_le_bytes(
                snapshot[second_record..second_record + 4]
                    .try_into()
                    .unwrap()
            ),
            0
        );
        assert_eq!(
            i32::from_le_bytes(
                snapshot[second_record + 4..second_record + 8]
                    .try_into()
                    .unwrap()
            ),
            0
        );
        assert_eq!(
            snapshot_revision,
            document(&handle).expect("document").revision()
        );
        assert!(first_tile.chunks_exact(4).any(|pixel| pixel[3] != 0));

        end_stroke(&mut handle).expect("close stroke");
        close_document(&mut handle).expect("close document");
    }

    #[test]
    fn selected_layer_stroke_respects_panel_polygon_selection() {
        let mut handle = create_document(
            0x3387,
            DocumentSpec {
                width_px: 64,
                height_px: 64,
                dpi: 144.0,
                color_space: ColorSpace::Srgb,
                background: Rgba8::default(),
            },
        )
        .expect("valid document");
        let primary = document_info(&handle)
            .expect("document info")
            .primary_raster_layer;
        let selected = add_layer(&mut handle, 0).expect("additional raster layer");
        select_lasso(
            &mut handle,
            vec![0.0, 0.0, 32.0, 0.0, 32.0, 32.0, 0.0, 32.0],
        )
        .expect("panel polygon selection");

        begin_brush_stroke_on_layer(&mut handle, 1, selected).expect("begin on selected layer");
        for (x, y) in [(16.0_f32, 16.0_f32), (48.0_f32, 16.0_f32)] {
            let mut packet = vec![1, 0, 1, 0];
            packet.extend([0_u8; 48]);
            packet[12..16].copy_from_slice(&x.to_le_bytes());
            packet[16..20].copy_from_slice(&y.to_le_bytes());
            packet[20..24].copy_from_slice(&1.0_f32.to_le_bytes());
            push_pointer_packet(&mut handle, &packet).expect("pointer sample");
        }
        end_stroke(&mut handle).expect("end selected-layer stroke");

        let selected_tile = read_tile(&handle, selected, 0, 0).expect("selected tile");
        let primary_tile = read_tile(&handle, primary, 0, 0).expect("primary tile");
        let inside = ((16 * 256 + 16) * 4) as usize;
        let crossing_inside = ((16 * 256 + 24) * 4) as usize;
        let outside = ((16 * 256 + 40) * 4) as usize;
        assert!(
            selected_tile[inside + 3] > 0,
            "inside dab should be retained"
        );
        assert!(
            selected_tile[crossing_inside + 3] > 0,
            "inside segment of a boundary-crossing stroke should be retained"
        );
        assert_eq!(
            selected_tile[outside + 3],
            0,
            "outside segment of a boundary-crossing stroke must be clipped"
        );
        assert_eq!(
            primary_tile[inside + 3],
            0,
            "primary layer must stay untouched"
        );
        close_document(&mut handle).expect("close document");
    }

    #[test]
    fn custom_brush_rename_is_projected_and_undoable_through_bridge() {
        let mut handle = create_document(
            0x3388,
            DocumentSpec {
                width_px: 64,
                height_px: 64,
                dpi: 144.0,
                color_space: ColorSpace::Srgb,
                background: Rgba8::default(),
            },
        )
        .expect("valid document");
        let duplicate = duplicate_brush(&mut handle, 6).expect("duplicate G-Pen");
        rename_brush(&mut handle, duplicate, " Ink Manga Pen ".into()).expect("rename duplicate");
        assert_eq!(
            brushes(&handle)
                .expect("brush projection")
                .into_iter()
                .find(|brush| brush.id == duplicate)
                .expect("renamed brush")
                .name,
            "Ink Manga Pen"
        );
        undo(&mut handle).expect("undo rename");
        assert!(
            brushes(&handle)
                .expect("brush projection after undo")
                .into_iter()
                .any(|brush| brush.id == duplicate && brush.name == "G-Pen Copy")
        );
        redo(&mut handle).expect("redo rename");
        assert!(
            brushes(&handle)
                .expect("brush projection after redo")
                .into_iter()
                .any(|brush| brush.id == duplicate && brush.name == "Ink Manga Pen")
        );
    }

    #[test]
    fn tile_update_packet_marks_layer_changes_as_full_redraw() {
        let mut handle = create_document(
            99,
            DocumentSpec {
                width_px: 256,
                height_px: 256,
                dpi: 144.0,
                color_space: ColorSpace::Srgb,
                background: Rgba8::default(),
            },
        )
        .expect("valid document");
        dispatch(
            &mut handle,
            EditorCommand::AddLayer {
                parent: None,
                kind: LayerKind::Raster,
            },
        )
        .expect("layer command");

        let packet = drain_tile_updates(&mut handle).expect("tile update packet");
        assert_eq!(&packet[0..2], &3u16.to_le_bytes());
        assert_eq!(&packet[2..4], &1u16.to_le_bytes());
        assert_eq!(&packet[4..8], &0u32.to_le_bytes());
        assert_eq!(&packet[8..12], &0u32.to_le_bytes());
        assert_eq!(packet.len(), 12);
    }

    #[test]
    fn engine_health_marker_is_stable() {
        assert_eq!(engine_health(), "project-ink-engine-v1");
    }

    #[test]
    fn deleting_a_leaf_layer_uses_undoable_bridge_command() {
        let mut handle =
            create_default_document(0xD311, 256, 256, 144.0).expect("default document");
        let added = add_layer(&mut handle, 0).expect("added raster layer");
        let before = layer_summaries(&handle).expect("layer projection");
        assert!(before.iter().any(|layer| layer.id == added));

        delete_layer(&mut handle, added).expect("delete through bridge");
        let after = layer_summaries(&handle).expect("updated projection");
        assert!(!after.iter().any(|layer| layer.id == added));
        undo(&mut handle).expect("undo deletion");
        assert!(
            layer_summaries(&handle)
                .expect("restored projection")
                .iter()
                .any(|layer| layer.id == added)
        );
        redo(&mut handle).expect("redo deletion");
        assert!(
            !layer_summaries(&handle)
                .expect("redone projection")
                .iter()
                .any(|layer| layer.id == added)
        );
        assert!(delete_layer(&mut handle, 1).is_err());
        close_document(&mut handle).expect("close document");
    }

    #[test]
    fn duplicating_a_leaf_layer_is_available_through_bridge_and_undoable() {
        let mut handle =
            create_default_document(0xD312, 256, 256, 144.0).expect("default document");
        let source = add_layer(&mut handle, 0).expect("added raster layer");
        let duplicate = duplicate_layer(&mut handle, source).expect("duplicate through bridge");
        let layers = layer_summaries(&handle).expect("layer projection");
        assert!(layers.iter().any(|layer| layer.id == source));
        assert!(layers.iter().any(|layer| layer.id == duplicate));
        undo(&mut handle).expect("undo duplication");
        assert!(
            !layer_summaries(&handle)
                .expect("projection after undo")
                .iter()
                .any(|layer| layer.id == duplicate)
        );
        redo(&mut handle).expect("redo duplication");
        assert!(
            layer_summaries(&handle)
                .expect("projection after redo")
                .iter()
                .any(|layer| layer.id == duplicate)
        );
        close_document(&mut handle).expect("close document");
    }

    #[test]
    fn duplicating_a_group_subtree_is_projected_and_comic_owned_descendants_are_rejected() {
        let mut handle =
            create_default_document(0xD313, 256, 256, 144.0).expect("default document");
        let group = add_layer(&mut handle, 2).expect("ordinary group");
        let child = add_layer_to_parent(&mut handle, 0, group).expect("paint child");
        let nested = add_layer_to_parent(&mut handle, 2, group).expect("nested group");
        let nested_child = add_layer_to_parent(&mut handle, 0, nested).expect("nested paint");

        let duplicate = duplicate_layer(&mut handle, group).expect("duplicate group subtree");
        let summaries = layer_summaries(&handle).expect("layer projection");
        let copied_nested = summaries
            .iter()
            .find(|layer| layer.parent == Some(duplicate) && layer.kind == "Group")
            .expect("copied nested group");
        assert!(
            summaries
                .iter()
                .any(|layer| layer.parent == Some(duplicate))
        );
        let copied_nested_child = summaries
            .iter()
            .find(|layer| layer.parent == Some(copied_nested.id) && layer.kind == "Raster")
            .expect("copied nested paint");
        assert_ne!(copied_nested_child.id, nested_child);
        assert!(summaries.iter().any(|layer| layer.id == child));

        undo(&mut handle).expect("undo subtree duplication");
        assert!(
            !layer_summaries(&handle)
                .expect("projection after undo")
                .iter()
                .any(|layer| layer.id == duplicate)
        );
        redo(&mut handle).expect("redo subtree duplication");

        let protected =
            add_layer_to_parent(&mut handle, 5, group).expect("comic panel group fixture");
        assert!(duplicate_layer(&mut handle, group).is_err());
        assert!(
            layer_summaries(&handle)
                .expect("projection after rejected duplication")
                .iter()
                .any(|layer| layer.id == protected)
        );
        close_document(&mut handle).expect("close document");
    }

    #[test]
    fn duplicating_a_group_routes_through_unified_project_active_page() {
        let mut project = create_studio_project(
            0xD314,
            1,
            "Duplicate group test".into(),
            0xD315,
            256,
            256,
            144.0,
        )
        .expect("studio project");
        let page = project.pages.get_mut(&0xD315).expect("active page");
        let group = add_layer(page, 2).expect("ordinary group");
        let child = add_layer_to_parent(page, 0, group).expect("paint child");
        let duplicate =
            duplicate_project_layer(&mut project, group).expect("duplicate active project group");
        let summaries = layer_summaries(project.pages.get(&0xD315).expect("active page"))
            .expect("unified project projection");
        assert!(summaries.iter().any(|layer| layer.id == duplicate));
        assert!(
            summaries
                .iter()
                .any(|layer| layer.parent == Some(duplicate) && layer.id != child)
        );
        close_studio_project(&mut project);
    }

    #[test]
    fn adjustment_settings_are_projected_validated_and_undoable() {
        let mut handle =
            create_default_document(0xAD11, 256, 256, 144.0).expect("default document");
        let group = add_layer(&mut handle, 2).expect("group layer");
        let adjustment_layer =
            add_layer_to_parent(&mut handle, 6, group).expect("group adjustment layer");
        set_layer_brightness_contrast(&mut handle, adjustment_layer, 32, -18)
            .expect("set adjustment");
        let summary = layer_summaries(&handle)
            .expect("layer summaries")
            .into_iter()
            .find(|layer| layer.id == adjustment_layer)
            .expect("adjustment projection");
        assert_eq!(summary.kind, "Adjustment");
        assert_eq!(summary.parent, Some(group));
        assert_eq!(summary.adjustment_brightness, 32);
        assert_eq!(summary.adjustment_contrast, -18);
        assert!(set_layer_brightness_contrast(&mut handle, adjustment_layer, 101, 0).is_err());
        undo(&mut handle).expect("undo adjustment edit");
        let summary = layer_summaries(&handle)
            .expect("undo projection")
            .into_iter()
            .find(|layer| layer.id == adjustment_layer)
            .expect("adjustment layer remains");
        assert_eq!(summary.adjustment_brightness, 0);
        assert_eq!(summary.adjustment_contrast, 0);
        redo(&mut handle).expect("redo adjustment edit");
        let summary = layer_summaries(&handle)
            .expect("redo projection")
            .into_iter()
            .find(|layer| layer.id == adjustment_layer)
            .expect("adjustment layer remains");
        assert_eq!(summary.adjustment_brightness, 32);
        assert_eq!(summary.adjustment_contrast, -18);
        close_document(&mut handle).expect("close document");
    }

    #[test]
    fn delete_bridge_rejects_comic_owned_panel_layers() {
        let mut project = create_studio_project(
            0xD312,
            1,
            "Panel delete guard".into(),
            0xD313,
            512,
            512,
            144.0,
        )
        .expect("studio project");
        add_project_panel(&mut project, 0, 0xD314, 32.0, 32.0, 180.0, 180.0, 12.0)
            .expect("panel with owned layer tree");
        let binding = project
            .project
            .as_ref()
            .expect("comic graph")
            .panel_layers
            .first()
            .expect("panel layer binding")
            .clone();
        assert!(delete_project_layer(&mut project, binding.panel_group_id).is_err());
        assert!(delete_project_layer(&mut project, binding.mask_layer_id).is_err());
        let page = project_active_document(&project).expect("active page");
        assert!(
            layer_summaries(&page)
                .expect("layer projection")
                .iter()
                .any(|layer| layer.id == binding.mask_layer_id)
        );
        close_studio_project(&mut project);
    }

    #[test]
    fn one_layer_inspector_edit_creates_one_undo_step() {
        let mut handle =
            create_default_document(0x1A9E, 256, 256, 144.0).expect("default document");
        let layer = layers(&handle)
            .expect("layers")
            .into_iter()
            .next()
            .expect("default layer");
        let before = revision(&handle).expect("initial revision");

        let changed = update_layer_properties(
            &mut handle,
            layer.id.0,
            false,
            layer.opacity,
            layer.alpha_lock,
            layer.clipping,
            layer.reference,
        )
        .expect("change visibility");
        assert_eq!(changed, before + 1);
        undo(&mut handle).expect("undo visibility");
        assert!(
            layers(&handle)
                .expect("restored layers")
                .iter()
                .find(|candidate| candidate.id == layer.id)
                .expect("restored layer")
                .visible
        );

        let before_presentation = revision(&handle).expect("revision after undo");
        update_layer_presentation(&mut handle, layer.id.0, layer.name, 1, 0, None)
            .expect("change blend mode");
        assert_eq!(
            revision(&handle).expect("blend revision"),
            before_presentation + 1
        );
        undo(&mut handle).expect("undo blend mode");
        assert_eq!(
            layers(&handle)
                .expect("layers after blend undo")
                .into_iter()
                .find(|candidate| candidate.id == layer.id)
                .expect("layer after blend undo")
                .blend_mode,
            LayerBlendMode::Normal
        );

        let group_id = add_layer(&mut handle, 2).expect("group");
        let group_name = layers(&handle)
            .expect("layers with group")
            .into_iter()
            .find(|candidate| candidate.id.0 == group_id)
            .expect("group layer")
            .name;
        let before_group_mode = revision(&handle).expect("group revision");
        update_layer_presentation(&mut handle, group_id, group_name, 0, 1, None)
            .expect("set pass-through mode");
        assert_eq!(
            revision(&handle).expect("group mode revision"),
            before_group_mode + 1
        );
        assert_eq!(
            layer_summaries(&handle)
                .expect("group projection")
                .into_iter()
                .find(|candidate| candidate.id == group_id)
                .expect("group summary")
                .group_mode,
            "Pass-through"
        );
        undo(&mut handle).expect("undo group mode");
        assert_eq!(
            layer_summaries(&handle)
                .expect("restored group projection")
                .into_iter()
                .find(|candidate| candidate.id == group_id)
                .expect("restored group")
                .group_mode,
            "Isolated"
        );
        close_document(&mut handle).expect("close document");
    }

    #[test]
    fn live_dab_packet_v3_round_trips_fixed_width_records() {
        let dab = ink_live_render::LiveDab {
            stroke_id: 0x1234,
            sequence: 17,
            dab_index: 4,
            x: 12.5,
            y: 34.25,
            radius: 4.0,
            opacity: 0.75,
            rotation: 0.25,
            color: [12, 34, 56, 255],
            phase: ink_live_render::DabPhase::Confirmed,
        };
        let packet = encode_live_dab_packet(&[dab]);

        assert_eq!(packet.len(), 8 + LIVE_DAB_RECORD_BYTES);
        assert_eq!(u16::from_le_bytes([packet[0], packet[1]]), 3);
        assert_eq!(u32::from_le_bytes(packet[4..8].try_into().unwrap()), 1);
        assert_eq!(
            decode_live_dab_packet(&packet).expect("valid packet"),
            [dab]
        );
        assert_eq!(
            u32::from_le_bytes(packet[8 + 20..8 + 24].try_into().unwrap()),
            dab.dab_index
        );
        assert_eq!(&packet[8 + 45..8 + 49], &dab.color);
        assert!(packet[8 + 49..].iter().all(|byte| *byte == 0));
    }

    #[test]
    fn live_dab_packet_v3_rejects_nonzero_reserved_bytes() {
        let dab = ink_live_render::LiveDab {
            stroke_id: 1,
            sequence: 1,
            dab_index: 0,
            x: 1.0,
            y: 1.0,
            radius: 1.0,
            opacity: 1.0,
            rotation: 0.0,
            color: [255, 0, 0, 255],
            phase: ink_live_render::DabPhase::Predicted,
        };
        let mut packet = encode_live_dab_packet(&[dab]);
        *packet.last_mut().expect("record padding") = 1;
        assert!(decode_live_dab_packet(&packet).is_err());
    }

    #[test]
    fn unified_studio_project_owns_pages_and_round_trips_storage() {
        let mut handle = create_studio_project(
            0x7000,
            1,
            "Unified test comic".into(),
            0x7001,
            512,
            512,
            144.0,
        )
        .expect("studio project");
        let first = project_snapshot(&handle).expect("project snapshot");
        assert_eq!(first.page_count, 1);
        let with_panel = add_project_panel(&mut handle, 0, 0x7010, 32.0, 32.0, 180.0, 180.0, 12.0)
            .expect("panel in unified project");
        assert_eq!(with_panel.pages[0].panel_count, 1);
        assert!(with_panel.pages[0].panels[0].ink_layer_id.is_some());
        let second = add_project_page(&mut handle, 0x7002, 512, 512, 144.0).expect("second page");
        assert_eq!(second.page_count, 2);
        activate_page(&mut handle, 0x7002).expect("activate second page");
        let tile = read_project_composite_tile(&handle, 0, 0).expect("composite tile");
        assert_eq!(tile.len(), 256 * 256 * 4);

        let root = std::env::temp_dir().join(format!(
            "project-ink-unified-studio-{}.inkproj",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        save_project_as(&handle, root.to_string_lossy().into_owned()).expect("studio save");
        assert!(root.join("comic.json").is_file());
        let reopened =
            open_studio_project(root.to_string_lossy().into_owned()).expect("studio reopen");
        assert_eq!(
            project_snapshot(&reopened)
                .expect("reopened snapshot")
                .page_count,
            2
        );
        let mask_id = with_panel.pages[0].panels[0]
            .mask_layer_id
            .expect("panel mask binding");
        let first_page = reopened.pages.get(&0x7001).expect("reopened first page");
        assert!(
            document(first_page)
                .expect("reopened document")
                .layer_has_allocated_tiles(ink_model::LayerId::from_u128(mask_id))
                .expect("reopened mask probe")
        );
        let checkpoint = checkpoint_project(&reopened).expect("checkpoint");
        assert!(!checkpoint.is_empty());
        let mut reopened = reopened;
        close_studio_project(&mut reopened);
        close_studio_project(&mut handle);
        std::fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn unified_panel_geometry_updates_authoritative_masks_and_split_layers() {
        let mut handle =
            create_studio_project(0x7100, 1, "Geometry test".into(), 0x7101, 512, 512, 144.0)
                .expect("studio project");
        let view = add_project_panel(&mut handle, 0, 0x7110, 16.0, 16.0, 160.0, 160.0, 8.0)
            .expect("panel");
        let panel = &view.pages[0].panels[0];
        let mask_id = panel.mask_layer_id.expect("mask");
        let changed = set_project_panel_bounds(&mut handle, 0, panel.id, 64.0, 64.0, 200.0, 120.0)
            .expect("resize panel");
        assert!((changed.pages[0].panels[0].x - 64.0).abs() < f32::EPSILON);
        let mask_tile = read_tile(&handle.pages[&0x7101], mask_id, 0, 0).expect("mask tile");
        let inside = ((80usize * 256 + 80) * 4) as usize;
        let outside = ((32usize * 256 + 32) * 4) as usize;
        assert_eq!(mask_tile[inside + 3], 255);
        assert_eq!(mask_tile[outside + 3], 0);

        let polygon = set_project_panel_polygon(
            &mut handle,
            0,
            panel.id,
            vec![64.0, 64.0, 264.0, 64.0, 180.0, 184.0],
        )
        .expect("polygon panel");
        assert_eq!(polygon.pages[0].panels[0].shape, 1);
        let split = split_project_panel(&mut handle, 0, panel.id, 0x7120, 0x7121, 0, 0.5);
        assert!(split.is_err(), "polygon panels cannot be split");

        let mut rectangular =
            create_studio_project(0x7130, 1, "Split test".into(), 0x7131, 512, 512, 144.0)
                .expect("split project");
        let initial = add_project_panel(&mut rectangular, 0, 0x7140, 16.0, 16.0, 320.0, 160.0, 8.0)
            .expect("rectangular panel");
        let split = split_project_panel(
            &mut rectangular,
            0,
            initial.pages[0].panels[0].id,
            0x7150,
            0x7151,
            0,
            0.5,
        )
        .expect("split panel");
        assert_eq!(split.pages[0].panel_count, 2);
        assert!(split.pages[0].panels[0].ink_layer_id.is_some());
        assert!(split.pages[0].panels[1].mask_layer_id.is_some());
    }

    #[test]
    fn unified_project_history_undoes_structure_without_json_rebuild() {
        let mut handle =
            create_studio_project(0x7200, 1, "History test".into(), 0x7201, 512, 512, 144.0)
                .expect("studio project");
        let initial_revision =
            revision(studio_active_document(&handle).expect("active page")).expect("revision");
        let added = add_project_panel(&mut handle, 0, 0x7210, 32.0, 32.0, 180.0, 180.0, 12.0)
            .expect("panel");
        assert_eq!(added.pages[0].panel_count, 1);
        assert!(project_can_undo(&handle));

        let undone = undo_project(&mut handle).expect("undo panel");
        assert_eq!(undone.pages[0].panel_count, 0);
        assert!(project_can_redo(&handle));
        assert_eq!(
            revision(studio_active_document(&handle).expect("active page")).expect("revision"),
            initial_revision
        );

        let redone = redo_project(&mut handle).expect("redo panel");
        assert_eq!(redone.pages[0].panel_count, 1);
        assert!(project_can_undo(&handle));
        assert!(!project_can_redo(&handle));
        close_studio_project(&mut handle);
    }

    #[test]
    fn cross_page_script_dialogue_edit_is_searchable_undoable_and_persistent() {
        let mut handle = create_studio_project(
            0x7300,
            1,
            "Script editor test".into(),
            0x7301,
            512,
            512,
            144.0,
        )
        .expect("studio project");
        add_project_page(&mut handle, 0x7302, 512, 512, 144.0).expect("second page");
        let with_balloon = studio_add_styled_balloon(
            &mut handle,
            1,
            0x7310,
            None,
            0,
            vec![300.0, 320.0, 280.0, 380.0],
            0,
            "sans-serif".into(),
            32.0,
            0.0,
            100.0,
            100.0,
            220.0,
            120.0,
            "Draft line".into(),
        )
        .expect("add second-page balloon");
        assert_eq!(with_balloon.pages[1].balloons[0].text, "Draft line");

        let edited = studio_set_dialogue(&mut handle, 1, 0x7310, "Final line".into())
            .expect("edit through script route");
        assert_eq!(edited.pages[1].balloons[0].text, "Final line");
        let hits = studio_search_dialogue(&handle, "final".into()).expect("edited search");
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].page_index, 1);
        assert_eq!(hits[0].balloon_id, 0x7310);

        let undone = undo_project(&mut handle).expect("undo dialogue edit");
        assert_eq!(undone.pages[1].balloons[0].text, "Draft line");
        let redone = redo_project(&mut handle).expect("redo dialogue edit");
        assert_eq!(redone.pages[1].balloons[0].text, "Final line");

        let root = std::env::temp_dir().join(format!(
            "project-ink-script-roundtrip-{}.inkproj",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        save_project_as(&handle, root.to_string_lossy().into_owned()).expect("save script project");
        close_studio_project(&mut handle);
        let mut reopened = open_studio_project(root.to_string_lossy().into_owned())
            .expect("reopen script project");
        let snapshot = project_snapshot(&reopened).expect("reopened script snapshot");
        assert_eq!(snapshot.pages[1].balloons[0].id, 0x7310);
        assert_eq!(snapshot.pages[1].balloons[0].text, "Final line");
        close_studio_project(&mut reopened);
        std::fs::remove_dir_all(root).expect("remove temporary script project");
    }

    #[test]
    fn epoch_microsecond_flutter_ids_materialize_repeated_panel_trees() {
        // ComicWorkspaceController starts its local ID sequence from
        // DateTime.now().microsecondsSinceEpoch, then allocates project, page,
        // and panel IDs consecutively. Keep this in the bridge regression so
        // the live Flutter ID shape is covered (not only small fixture IDs).
        let seed = 1_790_000_000_000_000_u128;
        let mut handle = create_studio_project(
            seed,
            1,
            "Flutter ID range".into(),
            seed + 1,
            2400,
            1800,
            300.0,
        )
        .expect("studio project with Flutter-shaped IDs");

        for panel_id in [seed + 2, seed + 3, seed + 4] {
            let snapshot =
                add_project_panel(&mut handle, 0, panel_id, 100.0, 100.0, 420.0, 420.0, 24.0)
                    .expect("panel layer IDs must be valid for sequential epoch IDs");
            assert_eq!(
                snapshot.pages[0].panel_count as usize,
                (panel_id - seed - 1) as usize
            );
        }

        let layers = layer_summaries(studio_active_document(&handle).expect("active page"))
            .expect("page layers");
        assert_eq!(layers.len(), 1 + 3 * 7);
        let project = handle.project.as_ref().expect("project");
        assert_eq!(project.validate(), Ok(()));
        assert!(
            project
                .panel_layers
                .iter()
                .flat_map(|binding| [
                    binding.panel_group_id,
                    binding.mask_layer_id,
                    binding.sketch_layer_id,
                    binding.ink_layer_id,
                    binding.color_layer_id,
                    binding.tone_layer_id,
                    binding.effects_layer_id,
                ])
                .all(|id| id <= i64::MAX as u128)
        );
        close_studio_project(&mut handle);
    }

    #[test]
    fn high_namespace_panel_layer_ids_round_trip_without_rewriting_metadata() {
        let project_id = 0xD38F;
        let page_id = 0xD390;
        let panel_id = 0xD391;
        let high = 1_u128 << 100;
        let mut comic = ink_comic::ComicProject::new(
            project_id,
            ink_comic::ProjectTemplate::PrintComic,
            "Legacy high layer IDs",
        );
        comic
            .add_page(ink_comic::print_page(512, 512, 144.0, 1, page_id))
            .expect("page");
        comic
            .add_panel(
                0,
                ink_comic::Panel {
                    id: panel_id,
                    shape: ink_comic::PanelShape::Rectangle,
                    bounds: ink_comic::Rect {
                        x: 24.0,
                        y: 24.0,
                        width: 464.0,
                        height: 464.0,
                    },
                    polygon: Vec::new(),
                    gutter_px: 12.0,
                    mask_layer_id: None,
                },
            )
            .expect("panel");
        let binding = comic
            .panel_layers
            .iter_mut()
            .find(|binding| binding.panel_id == panel_id)
            .expect("panel binding");
        binding.panel_group_id = high + 1;
        binding.mask_layer_id = high + 2;
        binding.sketch_layer_id = high + 3;
        binding.ink_layer_id = high + 4;
        binding.color_layer_id = high + 5;
        binding.tone_layer_id = high + 6;
        binding.effects_layer_id = high + 7;
        let source_comic = comic.to_json().expect("comic metadata");
        let mut project = create_studio_project_from_json(source_comic.clone())
            .expect("materialize high-namespace panel tree");
        let expected_ids = [
            high + 1,
            high + 2,
            high + 3,
            high + 4,
            high + 5,
            high + 6,
            high + 7,
        ];
        let layers = layer_summaries(studio_active_document(&project).expect("active page"))
            .expect("layer projection");
        assert!(
            expected_ids
                .iter()
                .all(|id| layers.iter().any(|layer| layer.id == *id))
        );

        set_panel_mask_geometry(
            studio_active_document_mut(&mut project).expect("mutable active page"),
            high + 2,
            vec![24.0, 24.0, 488.0, 24.0, 488.0, 488.0, 24.0, 488.0],
        )
        .expect("edit legacy mask layer");
        update_layer_presentation(
            studio_active_document_mut(&mut project).expect("mutable active page"),
            high + 4,
            "Legacy Ink".into(),
            0,
            0,
            None,
        )
        .expect("rename legacy ink layer");

        let nonce = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("clock")
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "project-ink-legacy-u128-{}-{nonce}.inkproj",
            std::process::id()
        ));
        save_project_as(&project, path.to_string_lossy().into_owned()).expect("save package");
        close_studio_project(&mut project);

        let comic_path = path.join("comic.json");
        let saved_comic = std::fs::read(&comic_path).expect("saved comic metadata");
        assert_eq!(saved_comic, source_comic);
        let mut reopened = open_studio_project(path.to_string_lossy().into_owned())
            .expect("reopen high-namespace project");
        assert_eq!(
            std::fs::read(&comic_path).expect("comic metadata after open"),
            saved_comic
        );
        let reopened_project = studio_project(&reopened).expect("reopened comic graph");
        let reopened_binding = reopened_project
            .panel_layers
            .iter()
            .find(|binding| binding.panel_id == panel_id)
            .expect("reopened panel binding");
        assert_eq!(reopened_binding.mask_layer_id, high + 2);
        assert_eq!(reopened_binding.ink_layer_id, high + 4);
        let layers = layer_summaries(studio_active_document(&reopened).expect("active page"))
            .expect("reopened layer projection");
        assert!(
            expected_ids
                .iter()
                .all(|id| layers.iter().any(|layer| layer.id == *id))
        );
        assert_eq!(
            layers
                .iter()
                .find(|layer| layer.id == high + 4)
                .expect("renamed high-ID layer")
                .name,
            "Legacy Ink"
        );
        close_studio_project(&mut reopened);
        std::fs::remove_dir_all(path).expect("remove temporary package");
    }

    #[test]
    fn removing_active_project_page_repairs_selection_and_is_undoable() {
        let first_page = 0xD320;
        let second_page = 0xD321;
        let third_page = 0xD322;
        let mut handle = create_studio_project(
            0xD31F,
            1,
            "Remove page test".into(),
            first_page,
            512,
            512,
            144.0,
        )
        .expect("studio project");
        add_project_page(&mut handle, second_page, 512, 512, 144.0).expect("second page");
        add_project_page(&mut handle, third_page, 512, 512, 144.0).expect("third page");
        activate_page(&mut handle, second_page).expect("activate second page");

        let removed_other = studio_remove_page(&mut handle, 2).expect("remove other page");
        assert_eq!(removed_other.page_count, 2);
        assert_eq!(handle.active_page, Some(second_page));
        undo_project(&mut handle).expect("undo other-page removal");
        assert_eq!(handle.active_page, Some(second_page));
        redo_project(&mut handle).expect("redo other-page removal");

        let removed = studio_remove_page(&mut handle, 1).expect("remove active page");
        assert_eq!(removed.page_count, 1);
        assert_eq!(handle.active_page, Some(first_page));
        assert!(handle.pages.contains_key(&first_page));
        assert!(!handle.pages.contains_key(&second_page));
        assert!(studio_active_document(&handle).is_ok());

        let undone = undo_project(&mut handle).expect("undo page removal");
        assert_eq!(undone.page_count, 2);
        assert_eq!(handle.active_page, Some(second_page));
        assert!(handle.pages.contains_key(&second_page));
        let redone = redo_project(&mut handle).expect("redo page removal");
        assert_eq!(redone.page_count, 1);
        assert_eq!(handle.active_page, Some(first_page));

        let before = studio_project(&handle).expect("project").clone();
        assert!(studio_remove_page(&mut handle, 0).is_err());
        assert_eq!(studio_project(&handle).expect("unchanged project"), &before);

        let path = std::env::temp_dir().join(format!(
            "project-ink-remove-page-{}.inkproj",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&path);
        save_project_as(&handle, path.to_string_lossy().into_owned())
            .expect("save project after removal");
        close_studio_project(&mut handle);
        let mut reopened = open_studio_project(path.to_string_lossy().into_owned())
            .expect("reopen project after removal");
        let snapshot = project_snapshot(&reopened).expect("reopened project snapshot");
        assert_eq!(snapshot.page_count, 1);
        assert_eq!(snapshot.pages[0].id, first_page);
        assert_eq!(
            reopened.pages.keys().copied().collect::<Vec<_>>(),
            vec![first_page]
        );
        close_studio_project(&mut reopened);
        std::fs::remove_dir_all(path).expect("remove project fixture");
    }

    #[test]
    fn active_page_capability_shares_document_state_with_project() {
        let mut project =
            create_studio_project(0x7300, 1, "Shared page".into(), 0x7301, 512, 512, 144.0)
                .expect("studio project");
        let mut page = project_active_document(&project).expect("active page capability");
        let added_layer = add_layer(&mut page, 0).expect("page layer");
        let summaries = layer_summaries(&project.pages[&0x7301]).expect("project layer view");
        assert!(summaries.iter().any(|layer| layer.id == added_layer));
        let snapshot = page_document_snapshot(&project, 0x7301).expect("shared snapshot");
        assert!(
            snapshot
                .layers
                .iter()
                .any(|layer| layer.id.0 == added_layer)
        );
        let root = std::env::temp_dir().join(format!(
            "project-ink-shared-page-{}.inkproj",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        save_project_as(&project, root.to_string_lossy().into_owned()).expect("shared save");
        let reopened = open_studio_project(root.to_string_lossy().into_owned()).expect("reopen");
        let reopened_layers = layer_summaries(&reopened.pages[&0x7301]).expect("reopened layers");
        assert!(reopened_layers.iter().any(|layer| layer.id == added_layer));
        let mut reopened = reopened;
        close_studio_project(&mut reopened);
        std::fs::remove_dir_all(root).expect("cleanup");
        close_studio_project(&mut project);
    }

    #[test]
    fn active_page_capability_composite_shows_stroke_over_transparent_background() {
        let project =
            create_studio_project(0x7310, 1, "Stroke page".into(), 0x7311, 2048, 2048, 144.0)
                .expect("project");
        let mut page = project_active_document(&project).expect("active page capability");
        begin_brush_stroke(&mut page, 1).expect("begin");
        let mut packet = vec![1, 0, 1, 0];
        packet.extend([0_u8; 48]);
        packet[12..16].copy_from_slice(&1053.0_f32.to_le_bytes());
        packet[16..20].copy_from_slice(&1048.0_f32.to_le_bytes());
        packet[20..24].copy_from_slice(&1.0_f32.to_le_bytes());
        push_pointer_packet(&mut page, &packet).expect("sample");
        end_stroke(&mut page).expect("end");
        let layer = read_tile(&page, 1, 4, 4).expect("layer tile");
        let composite = read_composite_tile(&page, 4, 4).expect("composite tile");
        let offset = (((1048 - 4 * 256) * 256 + (1053 - 4 * 256)) * 4) as usize;
        assert!(
            layer[offset + 3] > 0,
            "layer tile should contain the stroke"
        );
        assert!(
            composite[offset + 3] > 0,
            "composite tile should contain the stroke"
        );
        let mut project = project;
        close_studio_project(&mut project);
    }

    #[test]
    fn studio_batch_page_export_contains_painted_art_and_survives_reopen() {
        let test_id = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("clock")
            .as_nanos();
        let root = std::env::temp_dir().join(format!("project-ink-comic-png-{test_id}"));
        let first_export = root.join("first");
        let second_export = root.join("second");
        let project_path = root.join("comic.inkproj");
        let mut project =
            create_studio_project(0x7410, 1, "Painted comic".into(), 0x7411, 512, 512, 144.0)
                .expect("project");
        add_project_page(&mut project, 0x7412, 512, 512, 144.0).expect("second page");
        studio_add_styled_balloon(
            &mut project,
            0,
            0x7413,
            None,
            0,
            Vec::new(),
            0,
            "Arial".into(),
            32.0,
            2.0,
            64.0,
            64.0,
            256.0,
            128.0,
            "Hello & goodbye from Project Ink".into(),
        )
        .expect("lettered balloon");

        let mut page = project_active_document(&project).expect("first page");
        begin_brush_stroke(&mut page, 1).expect("begin stroke");
        let mut packet = vec![1, 0, 1, 0];
        packet.extend([0_u8; 48]);
        packet[12..16].copy_from_slice(&128.0_f32.to_le_bytes());
        packet[16..20].copy_from_slice(&128.0_f32.to_le_bytes());
        packet[20..24].copy_from_slice(&1.0_f32.to_le_bytes());
        push_pointer_packet(&mut page, &packet).expect("stroke sample");
        end_stroke(&mut page).expect("end stroke");

        assert_eq!(
            studio_batch_export_pages(&project, first_export.to_string_lossy().into_owned())
                .expect("PNG export"),
            2
        );
        let painted = std::fs::read(first_export.join("page-0001.png")).expect("painted PNG");
        let blank = std::fs::read(first_export.join("page-0002.png")).expect("blank PNG");
        let composite_svg =
            std::fs::read(first_export.join("page-0001.svg")).expect("composited SVG");
        assert!(painted.starts_with(b"\x89PNG\r\n\x1a\n"));
        assert_eq!(&painted[16..24], &[0, 0, 2, 0, 0, 0, 2, 0]);
        assert_ne!(painted, blank, "page export must include page tile content");
        let composite_svg = String::from_utf8(composite_svg).expect("SVG UTF-8");
        assert!(composite_svg.contains("data-page-artwork=\"true\""));
        assert!(composite_svg.contains("data:image/png;base64,"));
        assert!(composite_svg.contains("Hello &amp;"));
        assert!(composite_svg.contains("goodbye"));
        assert!(composite_svg.contains("<tspan x="));
        assert!(composite_svg.contains("data-balloon-shape=\"oval\""));
        assert!(
            studio_batch_export_pages(&project, first_export.to_string_lossy().into_owned())
                .is_err()
        );
        assert_eq!(
            painted,
            std::fs::read(first_export.join("page-0001.png")).expect("existing export")
        );

        let blocked_export = root.join("blocked");
        std::fs::create_dir_all(&blocked_export).expect("blocked output directory");
        let protected = blocked_export.join("page-0002.png");
        std::fs::write(&protected, b"keep-existing-output").expect("existing page output");
        assert!(
            studio_batch_export_pages(&project, blocked_export.to_string_lossy().into_owned())
                .is_err()
        );
        assert!(!blocked_export.join("page-0001.png").exists());
        assert_eq!(
            std::fs::read(protected).expect("preserved output"),
            b"keep-existing-output"
        );

        save_project_as(&project, project_path.to_string_lossy().into_owned())
            .expect("save comic project");
        let mut reopened = open_studio_project(project_path.to_string_lossy().into_owned())
            .expect("reopen comic project");
        assert_eq!(
            studio_batch_export_pages(&reopened, second_export.to_string_lossy().into_owned())
                .expect("reopened PNG export"),
            2
        );
        assert_eq!(
            painted,
            std::fs::read(second_export.join("page-0001.png")).expect("reopened painted PNG"),
            "save/reopen export should be deterministic"
        );
        assert_eq!(
            composite_svg,
            std::fs::read_to_string(second_export.join("page-0001.svg"))
                .expect("reopened composited SVG"),
            "save/reopen composite should be deterministic"
        );
        assert_eq!(
            blank,
            std::fs::read(second_export.join("page-0002.png")).expect("reopened blank PNG")
        );

        close_studio_project(&mut reopened);
        close_studio_project(&mut project);
        std::fs::remove_dir_all(root).expect("test cleanup");
    }

    #[test]
    fn comic_bridge_round_trip_supports_dialogue_and_webtoon_queries() {
        let mut handle = create_xkcd_stick_figure_comic();
        let snapshot = comic_project_snapshot(&handle).expect("comic snapshot");
        assert_eq!(snapshot.page_count, 8);
        assert_eq!(snapshot.pages[0].panel_count, 4);
        assert_eq!(snapshot.pages[0].panels.len(), 4);
        assert_eq!(snapshot.pages[0].balloons.len(), 4);
        let with_material = comic_add_material(
            &mut handle,
            0x9000,
            "Example balloon style".into(),
            "balloon-style".into(),
            "CC0-1.0".into(),
            Some("Project Ink example".into()),
            Some("local://project-ink/example".into()),
        )
        .expect("material");
        assert_eq!(with_material.materials.len(), 1);
        let without_material = comic_remove_material(&mut handle, 0x9000).expect("remove");
        assert!(without_material.materials.is_empty());
        let balloon_id = 0x4000 + 2 * 16 + 1;
        let edited =
            comic_set_dialogue(&mut handle, 2, balloon_id, "A quiet panel follows.".into())
                .expect("dialogue edit");
        assert_eq!(edited.page_count, 8);
        let hits = comic_search_dialogue(&handle, "NEXT".into()).expect("dialogue search");
        assert_eq!(hits.len(), 31);
        let segments = comic_webtoon_segments(&handle, 0, 1024).expect("webtoon segments");
        assert_eq!(segments.len(), 2);
        let path =
            std::env::temp_dir().join(format!("project-ink-comic-{}.json", std::process::id()));
        comic_project_export_manifest(&handle, path.to_string_lossy().into_owned())
            .expect("comic manifest export");
        assert!(std::fs::metadata(&path).expect("manifest metadata").len() > 0);
        let bytes = comic_project_to_json(&handle).expect("comic encode");
        let digest = comic_project_portable_digest(&handle).expect("portable digest");
        assert_eq!(digest.len(), 64);
        assert!(
            digest
                .chars()
                .all(|character| character.is_ascii_hexdigit())
        );
        close_comic_project(&mut handle);
        assert!(comic_project_snapshot(&handle).is_err());
        let restored = comic_project_from_json(bytes).expect("comic decode");
        assert_eq!(
            comic_project_snapshot(&restored)
                .expect("restored snapshot")
                .page_count,
            8
        );
        assert_eq!(
            comic_project_portable_digest(&restored).expect("restored digest"),
            digest,
            "portable transfer must preserve structural/rendering identity"
        );
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn comic_bridge_reorder_is_page_numbered_and_safe() {
        let mut handle = create_xkcd_stick_figure_comic();
        let view = comic_reorder_page(&mut handle, 0, 7).expect("reorder");
        assert_eq!(view.pages[0].page_number, 1);
        assert_eq!(view.pages[7].page_number, 8);
        assert!(comic_reorder_page(&mut handle, 99, 0).is_err());
    }

    #[test]
    fn comic_bridge_exports_pages_and_reports_print_warnings() {
        let handle = create_xkcd_stick_figure_comic();
        let report = comic_print_preview_report(&handle).expect("print preview");
        assert_eq!(report.page_count, 8);
        assert!(report.bleed_safe);
        assert!(report.safety_safe);
        assert!(report.moire_warnings.is_empty());
        let preview = comic_render_page_preview(&handle, 0, 512).expect("PNG preview");
        assert!(preview.starts_with(b"\x89PNG\r\n\x1a\n"));
        let directory = std::env::temp_dir().join(format!(
            "project-ink-bridge-comic-pages-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&directory);
        let count =
            comic_batch_export_page_manifests(&handle, directory.to_string_lossy().into_owned())
                .expect("batch export");
        assert_eq!(count, 8);
        assert!(directory.join("page-0008.json").is_file());
        let svg_count = comic_batch_export_pages(&handle, directory.to_string_lossy().into_owned())
            .expect("SVG export");
        assert_eq!(svg_count, 8);
        assert!(directory.join("page-0008.svg").is_file());
        std::fs::remove_dir_all(directory).expect("cleanup");
    }

    #[test]
    fn webtoon_template_creates_a_long_canvas_and_segments_it() {
        let mut handle = create_comic_project(0x9400, 2, "webtoon".into()).expect("template");
        comic_add_page(&mut handle, 0x9401, 1080, 5000, 144.0).expect("long page");
        let segments = comic_webtoon_segments(&handle, 0, 2048).expect("segments");
        assert_eq!(segments.len(), 3);
        assert_eq!(segments[2].height_px, 904);
    }

    #[test]
    fn studio_first_run_example_materializes_as_a_complete_project() {
        let mut handle = create_studio_xkcd_stick_figure_project().expect("studio example");
        let snapshot = project_snapshot(&handle).expect("studio snapshot");
        assert_eq!(snapshot.page_count, 8);
        assert_eq!(
            snapshot
                .pages
                .iter()
                .map(|page| page.panel_count)
                .sum::<u32>(),
            32
        );
        let active = project_active_document(&handle).expect("first page document");
        let layers = layer_summaries(&active).expect("first page layer tree");
        assert!(layers.iter().any(|layer| layer.name == "Panel Mask"));
        assert!(layers.iter().any(|layer| layer.name == "Panel"));
        close_studio_project(&mut handle);
    }

    #[test]
    #[allow(clippy::too_many_lines)]
    fn phase3_eight_page_stick_figure_acceptance_flow() {
        let mut handle = create_xkcd_stick_figure_comic();
        let initial = comic_project_snapshot(&handle).expect("created fixture");
        assert_eq!(initial.page_count, 8);
        let panel_id = initial.pages[0].panels[0].id;
        let layout = comic_set_page_layout(
            &mut handle,
            0,
            350.0,
            96.0,
            96.0,
            96.0,
            96.0,
            96.0,
            96.0,
            2208.0,
            1608.0,
            120.0,
            120.0,
            120.0,
            120.0,
        )
        .expect("page layout");
        assert!((layout.pages[0].dpi - 350.0).abs() < f32::EPSILON);
        assert_eq!(layout.pages[0].panel_count, 4);
        comic_resize_gutter(&mut handle, 0, panel_id, 48.0).expect("resize gutter");
        let rectangle_panel_id = initial.pages[0].panels[1].id;
        let bounds = comic_set_panel_bounds(
            &mut handle,
            0,
            rectangle_panel_id,
            700.0,
            200.0,
            460.0,
            1360.0,
        )
        .expect("panel bounds");
        assert!((bounds.pages[0].panels[1].width - 460.0).abs() < f32::EPSILON);
        comic_set_panel_polygon(
            &mut handle,
            0,
            panel_id,
            vec![120.0, 180.0, 600.0, 180.0, 580.0, 1500.0, 120.0, 1500.0],
        )
        .expect("polygon panel");
        let edited_view = comic_project_snapshot(&handle).expect("edited snapshot");
        assert_eq!(edited_view.pages[0].panels[0].polygon.len(), 8);
        assert_eq!(edited_view.pages[0].panels[0].shape, 1);
        let view = comic_add_tone(
            &mut handle,
            0,
            0x9100,
            60.0,
            45.0,
            0.35,
            "circle".into(),
            120.0,
            180.0,
            480.0,
            1320.0,
        )
        .expect("tone");
        assert_eq!(view.pages[0].tone_count, 1);
        let first_panel_id = view.pages[0].panels[1].id;
        let split = comic_split_panel(&mut handle, 0, first_panel_id, 0x9150, 0x9151, 0, 0.5)
            .expect("drawn panel division");
        assert_eq!(split.pages[0].panel_count, 5);
        let view = comic_add_effect_line(
            &mut handle,
            0,
            0x9200,
            "speed".into(),
            vec![40.0, 40.0, 2000.0, 1600.0],
            8.0,
            0.75,
        )
        .expect("effect line");
        assert_eq!(view.pages[0].effect_line_count, 1);
        let balloon_id = initial.pages[3].balloons[0].id;
        comic_set_dialogue(&mut handle, 3, balloon_id, "A different line.".into())
            .expect("edit dialogue");
        let edited_view = comic_project_snapshot(&handle).expect("dialogue snapshot");
        assert_eq!(edited_view.pages[3].balloons[0].text, "A different line.");
        let styled = comic_add_styled_balloon(
            &mut handle,
            3,
            0x9300,
            None,
            2,
            vec![400.0, 700.0, 360.0, 760.0],
            1,
            "serif".into(),
            36.0,
            2.0,
            240.0,
            520.0,
            420.0,
            240.0,
            "Vertical narration".into(),
        )
        .expect("styled balloon");
        assert_eq!(styled.pages[3].balloon_count, 5);
        comic_set_balloon_tail(
            &mut handle,
            3,
            0x9300,
            vec![400.0, 700.0, 320.0, 820.0, 280.0, 860.0],
        )
        .expect("edit balloon tail");
        let styled =
            comic_set_balloon_style(&mut handle, 3, 0x9300, "monospace".into(), 40.0, 3.0, 0)
                .expect("edit balloon style");
        assert_eq!(styled.pages[3].balloons[4].font_family, "monospace");
        assert_eq!(styled.pages[3].balloons[4].orientation, 0);
        comic_reorder_page(&mut handle, 0, 7).expect("reorder page");
        let hits = comic_search_dialogue(&handle, "different".into()).expect("search");
        assert_eq!(hits.len(), 1);

        let directory = std::env::temp_dir().join(format!(
            "project-ink-phase3-acceptance-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&directory);
        assert_eq!(
            comic_batch_export_page_manifests(&handle, directory.to_string_lossy().into_owned())
                .expect("manifest export"),
            8
        );
        assert_eq!(
            comic_batch_export_pages(&handle, directory.to_string_lossy().into_owned())
                .expect("SVG export"),
            8
        );
        let bytes = comic_project_to_json(&handle).expect("checkpoint bytes");
        close_comic_project(&mut handle);
        let recovered = comic_project_from_json(bytes).expect("recovered fixture");
        assert_eq!(
            comic_project_snapshot(&recovered)
                .expect("recovered snapshot")
                .page_count,
            8
        );
        std::fs::remove_dir_all(directory).expect("cleanup");
    }

    #[test]
    fn comic_structure_attaches_to_native_document_checkpoint() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut handle = create_document(901, spec).expect("document");
        let bytes = ink_comic::xkcd_stick_figure_comic()
            .to_json()
            .expect("comic JSON");
        attach_comic_project(&mut handle, bytes.clone()).expect("attach comic");
        assert_eq!(read_comic_project(&handle), Some(bytes.clone()));
        let root =
            std::env::temp_dir().join(format!("project-ink-bridge-comic-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).expect("temp root");
        let path = root.join("comic.inkproj");
        save_document(&handle, path.to_string_lossy().into_owned()).expect("save");
        let reopened = open_document(path.to_string_lossy().into_owned()).expect("reopen");
        assert_eq!(read_comic_project(&reopened), Some(bytes));
        std::fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn reopened_document_can_save_again_to_its_existing_package() {
        let root =
            std::env::temp_dir().join(format!("project-ink-bridge-resave-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).expect("temp root");
        let path = root.join("resave.inkproj");
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };

        let created = create_document(902, spec).expect("document");
        save_document(&created, path.to_string_lossy().into_owned()).expect("initial save");
        drop(created);

        let reopened = open_document(path.to_string_lossy().into_owned()).expect("reopen");
        save_document(&reopened, path.to_string_lossy().into_owned()).expect("save reopened");
        drop(reopened);

        open_document(path.to_string_lossy().into_owned()).expect("second reopen");
        std::fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn staged_brush_import_revalidates_and_can_be_discarded() {
        let path = std::env::temp_dir().join(format!(
            "project-ink-bridge-stage-{}.inkbrush",
            std::process::id()
        ));
        ink_brush::export_inkbrush(&path, &ink_brush::builtin_library()[0]).expect("brush export");
        let mut handle = create_document(
            100,
            DocumentSpec {
                width_px: 256,
                height_px: 256,
                dpi: 144.0,
                color_space: ColorSpace::Srgb,
                background: Rgba8::default(),
            },
        )
        .expect("valid document");
        let staged =
            stage_brush_import(&mut handle, path.to_string_lossy().into_owned()).expect("stage");
        assert_eq!(staged.operation_id, 1);
        let report = convert_staged_brush_import(&mut handle, staged.operation_id).expect("report");
        assert_eq!(report.source_format, "InkBrush");
        let installed =
            commit_staged_brush_import(&mut handle, staged.operation_id).expect("commit");
        assert!(installed > 12);

        let staged_again = stage_brush_import(&mut handle, path.to_string_lossy().into_owned())
            .expect("stage again");
        discard_staged_brush_import(&mut handle, staged_again.operation_id);
        assert!(convert_staged_brush_import(&mut handle, staged_again.operation_id).is_err());
        let _ = std::fs::remove_file(path);
    }

    #[cfg(unix)]
    #[test]
    fn psd_open_rejects_symlink_sources_before_reading() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "project-ink-bridge-psd-symlink-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).expect("temp root");
        let target = root.join("source.psd");
        let alias = root.join("alias.psd");
        std::fs::write(&target, b"8BPS").expect("source");
        symlink(&target, &alias).expect("symlink");

        assert!(open_document(alias.to_string_lossy().into_owned()).is_err());
        std::fs::remove_dir_all(root).expect("cleanup");
    }
}
