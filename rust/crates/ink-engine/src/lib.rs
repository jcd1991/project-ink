//! Public orchestration API. Flutter/FRB will call this crate only.
#![allow(missing_docs)]
#![allow(
    clippy::missing_errors_doc,
    clippy::missing_panics_doc,
    clippy::must_use_candidate
)]
#![allow(
    clippy::cast_possible_truncation,
    clippy::cast_possible_wrap,
    clippy::cast_sign_loss,
    clippy::cast_precision_loss
)]

use ink_brush::{
    BrushDab, BrushPaint, BrushPreset, BrushPresetV2, CombineOp, CompiledBrush, CompiledBrushState,
    CurvePoint, Dab, GrainStamp, PaintBehavior, ParameterBinding, ParameterId, PostEffect,
    ResponseCurve, SensorId, TipBehavior, ToolBehavior, WatercolorEdgeStyle, builtin_library,
    resample_from,
};
use ink_command::{EditorCommand, History, Transaction, decode_journal, encode_command};
use ink_export::ExportError;
use ink_input::{PacketQueue, PointerPacket, QueueOutcome, decode, flags};
use ink_model::{
    BrushId, ColorSpace, DocumentId, DocumentSpec, Layer, LayerId, LayerKind, ModelError, Rgba8,
    StrokeId,
};
use ink_raster::{TILE_SIZE, Tile, TileCoord, TileStore};
use ink_storage::{
    HistorySnapshot, LayerPanelState, ProjectSnapshot, ResourceRecord, StorageError, StoredState,
    TileRecord, VectorRecord,
};
use ink_tools::{
    SelectionMask, TimeLapseRecording, TimeLapseSample, TimeLapseStroke, VectorPoint, VectorStroke,
};
use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::fmt;
use std::io::Write;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::thread::{self, JoinHandle};

const MAX_STROKE_INPUT_SEGMENT_SAMPLES: usize = TimeLapseRecording::MAX_SAMPLES;
// Hold a burst of expanded, confirmed dabs until the asynchronous GPU pump
// drains them. The queue grows on demand, so ordinary documents pay no cost
// for this upper bound.
const LIVE_DAB_QUEUE_CAPACITY: usize = 16_384;
const MAX_LAYERS: usize = 4096;
const MAX_COMMAND_JOURNAL_ENTRIES: usize = 262_144;
const MAX_EXPORT_BYTES: usize = 512 * 1024 * 1024;
const MAX_DOCUMENT_RESOURCE_BYTES: usize = 256 * 1024 * 1024;
const MAX_FILL_PIXELS: usize = 32 * 1024 * 1024;
const MAX_PANEL_MASK_PIXELS: usize = 32 * 1024 * 1024;
/// Undo/redo snapshots are full layer maps in v1. Keep their aggregate
/// payload bounded so a long session cannot turn history into an unbounded
/// memory sink. The newest snapshot is retained even when one document state
/// alone exceeds this budget, preserving the most recent undo operation.
const MAX_HISTORY_SNAPSHOT_BYTES: usize = 256 * 1024 * 1024;
/// A post-effect pass may only materialize a bounded dirty region. This is
/// large enough for a full 4096x4096 illustration while preventing a hostile
/// preset from turning a short stroke into an unbounded allocation.
const MAX_POST_EFFECT_PIXELS: usize = 32 * 1024 * 1024;

/// Stable bridge projection for one editable brush preset.
///
/// This deliberately contains only bounded scalar controls and resource
/// hashes. It is not executable brush state; the full preset remains Rust
/// owned and is validated before use. Keeping the controls in the projection
/// means reopening a document cannot silently reset the Flutter inspector to
/// UI defaults.
#[derive(Clone, Debug, PartialEq)]
pub struct BrushSummaryProjection {
    pub id: BrushId,
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

/// One normalized input point used by the disposable brush-editor preview.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct BrushPreviewPoint {
    pub x: f32,
    pub y: f32,
    pub pressure: f32,
}

/// Stable projection of one editable vector stroke for the UI. The bounds are
/// document-space and intentionally contain no mutable engine state.
pub type VectorStrokeSummaryTuple = (ink_model::StrokeId, u32, [f32; 4], Vec<f32>);

/// Read-only UI projection of one Rust-owned transaction history entry.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HistoryEntryView {
    pub sequence: u64,
    pub kind: String,
    pub detail: Option<String>,
    pub applied: bool,
}

/// Bounded history projection. `cursor` is the number of applied entries in
/// the full retained history; entry sequence numbers are zero-based.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HistoryProjection {
    pub revision: u64,
    pub cursor: u32,
    pub entries: Vec<HistoryEntryView>,
    pub was_trimmed: bool,
}

fn lock_recover<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// A dirty tile notification.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TileDescriptor {
    pub layer: LayerId,
    pub coordinate: TileCoord,
}

/// Inclusive tile-coordinate bounds for a committed stroke acknowledgement.
/// Bounds are deliberately tile-space rather than pixel-space so the bridge
/// can invalidate a bounded set of cached composite tiles without carrying a
/// large pixel rectangle through the control plane.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TileBounds {
    pub min_x: i32,
    pub min_y: i32,
    pub max_x: i32,
    pub max_y: i32,
}

/// A compact acknowledgement that confirmed input has reached CPU document
/// state. The bridge serializes this as a fixed-width binary packet rather
/// than JSON so high-frequency stroke feedback stays bounded.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct StrokeRenderMetrics {
    pub confirmed_sample_count: u64,
    pub path_length: f64,
    pub direct_length: f64,
    pub legacy_dabs: u64,
    pub compiled_dabs: u64,
    pub cpu_tiles_written: u64,
    pub compiled_cpu_tile_updates: u64,
    pub work_segments: u64,
    pub work_limit_reached: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct StrokeAcknowledgement {
    pub stroke: StrokeId,
    pub highest_committed_sequence: u32,
    pub revision: u64,
    pub dirty_bounds: Option<TileBounds>,
    pub dirty_tiles: Vec<TileCoord>,
    pub metrics: StrokeRenderMetrics,
}

impl TileBounds {
    fn from_coordinates(coordinates: &[TileCoord]) -> Option<Self> {
        let first = *coordinates.first()?;
        let mut bounds = Self {
            min_x: first.x,
            min_y: first.y,
            max_x: first.x,
            max_y: first.y,
        };
        for coordinate in coordinates.iter().copied().skip(1) {
            bounds.min_x = bounds.min_x.min(coordinate.x);
            bounds.min_y = bounds.min_y.min(coordinate.y);
            bounds.max_x = bounds.max_x.max(coordinate.x);
            bounds.max_y = bounds.max_y.max(coordinate.y);
        }
        Some(bounds)
    }
}

/// Events consumed by the UI event stream.
#[derive(Clone, Debug, PartialEq)]
pub enum EngineEvent {
    DocumentChanged {
        revision: u64,
    },
    TilesDirty {
        revision: u64,
        tiles: Vec<TileDescriptor>,
    },
    /// Committed pixels changed; consumers should invalidate the authoritative
    /// composite at these coordinates independently of individual layers.
    CompositeTilesDirty {
        revision: u64,
        tiles: Vec<TileCoord>,
    },
    /// Highest confirmed pointer sequence represented by the published CPU
    /// state for one active stroke.
    StrokeAcknowledged {
        stroke: StrokeId,
        highest_committed_sequence: u32,
        revision: u64,
        dirty_bounds: Option<TileBounds>,
        dirty_tiles: Vec<TileCoord>,
        metrics: StrokeRenderMetrics,
    },
    LayersChanged {
        revision: u64,
    },
    HistoryChanged {
        revision: u64,
        cursor: u32,
    },
}

/// Result of replaying the persisted command journal against a fresh state.
///
/// Replay validates command and layer/history semantics. Raster pixels remain
/// checkpoint data in v1 because high-frequency pointer packets are not part
/// of the journal.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct JournalReplayReport {
    pub command_count: usize,
    pub command_revision: u64,
    pub layer_count: usize,
    pub active_stroke: bool,
}

/// Structured engine error.
#[derive(Debug)]
pub enum EngineError {
    Model(ModelError),
    InvalidLayer,
    InvalidCommand(String),
    Packet(ink_input::PacketError),
    Storage(StorageError),
    Export(ExportError),
    WorkerUnavailable(String),
}

impl fmt::Display for EngineError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Model(error) => error.fmt(f),
            Self::InvalidLayer => f.write_str("layer does not exist"),
            Self::InvalidCommand(message) => f.write_str(message),
            Self::Packet(error) => error.fmt(f),
            Self::Storage(error) => error.fmt(f),
            Self::Export(error) => error.fmt(f),
            Self::WorkerUnavailable(message) => write!(f, "render worker unavailable: {message}"),
        }
    }
}
impl std::error::Error for EngineError {}
impl From<ModelError> for EngineError {
    fn from(error: ModelError) -> Self {
        Self::Model(error)
    }
}
impl From<ink_input::PacketError> for EngineError {
    fn from(error: ink_input::PacketError) -> Self {
        Self::Packet(error)
    }
}
impl From<StorageError> for EngineError {
    fn from(error: StorageError) -> Self {
        Self::Storage(error)
    }
}
impl From<ExportError> for EngineError {
    fn from(error: ExportError) -> Self {
        Self::Export(error)
    }
}

mod state;
use state::{
    ActiveStroke, BrushDraftSettings, BrushEditUndo, BrushResource, EngineState, LayerState,
    ResourceLru, StrokeInputMetrics,
};

mod persistence;
use persistence::{map_to_stored_state, stored_to_map};

fn validate_vector_stroke(stroke: &VectorStroke, spec: DocumentSpec) -> Result<(), EngineError> {
    if stroke.points.is_empty() || stroke.points.len() > 8_192 {
        return Err(EngineError::InvalidCommand(
            "vector stroke point count is outside limits".into(),
        ));
    }
    for point in &stroke.points {
        if [point.x, point.y, point.pressure, point.tilt]
            .into_iter()
            .any(|value| !value.is_finite())
            || point.pressure < 0.0
            || point.pressure > 1.0
            || point.x < 0.0
            || point.y < 0.0
            || point.x > spec.width_px as f32
            || point.y > spec.height_px as f32
        {
            return Err(EngineError::InvalidCommand(
                "vector stroke point is outside document bounds".into(),
            ));
        }
    }
    Ok(())
}

fn validate_layer_tree(layers: &BTreeMap<LayerId, LayerState>) -> Result<(), EngineError> {
    for state in layers.values() {
        match (state.layer.kind, state.layer.mask_owner) {
            (LayerKind::Mask, Some(owner_id)) => {
                let owner = layers.get(&owner_id).ok_or_else(|| {
                    EngineError::InvalidCommand("mask references a missing owner layer".into())
                })?;
                let valid_owner = match owner.layer.kind {
                    LayerKind::Raster | LayerKind::VectorInk => {
                        state.layer.parent == owner.layer.parent
                    }
                    LayerKind::Group | LayerKind::PanelGroup => {
                        state.layer.parent == Some(owner_id)
                    }
                    _ => false,
                };
                if !valid_owner {
                    return Err(EngineError::InvalidCommand(
                        "mask owner must be a paint sibling or its parent group".into(),
                    ));
                }
            }
            (_, Some(_)) => {
                return Err(EngineError::InvalidCommand(
                    "only mask layers can have a mask owner".into(),
                ));
            }
            (LayerKind::Mask | _, None) => {}
        }
        match (state.layer.kind, state.layer.adjustment) {
            (LayerKind::Adjustment, Some(adjustment)) => {
                adjustment
                    .validate()
                    .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
                if let Some(parent) = state.layer.parent {
                    let parent = layers.get(&parent).ok_or(EngineError::InvalidLayer)?;
                    if parent.layer.kind != LayerKind::Group {
                        return Err(EngineError::InvalidCommand(
                            "nested adjustment layers require a group parent".into(),
                        ));
                    }
                }
            }
            (LayerKind::Adjustment, None) => {
                return Err(EngineError::InvalidCommand(
                    "adjustment layer is missing filter settings".into(),
                ));
            }
            (_, Some(_)) => {
                return Err(EngineError::InvalidCommand(
                    "filter settings are only valid on adjustment layers".into(),
                ));
            }
            (_, None) => {}
        }
        let mut visited = HashSet::new();
        let mut current = Some(state.layer.id);
        while let Some(layer_id) = current {
            if !visited.insert(layer_id) {
                return Err(EngineError::InvalidCommand(
                    "layer tree contains a parent cycle".into(),
                ));
            }
            let layer = layers.get(&layer_id).ok_or_else(|| {
                EngineError::InvalidCommand("layer tree contains a dangling parent".into())
            })?;
            current = layer.layer.parent;
        }
    }
    Ok(())
}

/// Return the layer tree in deterministic bottom-to-top preorder. Sibling
/// order is authoritative; the ID is only a stable tie-breaker for malformed
/// or legacy states that contain duplicate order values.
fn ordered_layer_ids(layers: &BTreeMap<LayerId, LayerState>) -> Vec<LayerId> {
    fn visit(
        layers: &BTreeMap<LayerId, LayerState>,
        parent: Option<LayerId>,
        output: &mut Vec<LayerId>,
    ) {
        let mut siblings = layers
            .values()
            .filter(|state| state.layer.parent == parent)
            .map(|state| (state.layer.order, state.layer.id))
            .collect::<Vec<_>>();
        siblings.sort_unstable();
        for (_, id) in siblings {
            output.push(id);
            visit(layers, Some(id), output);
        }
    }

    let mut output = Vec::with_capacity(layers.len());
    visit(layers, None, &mut output);
    // A validated tree should include every node. Keep the read path total if
    // a future migration encounters malformed data by appending any omitted
    // IDs in deterministic order; validation still rejects such data before
    // it can be saved.
    if output.len() != layers.len() {
        let seen = output.iter().copied().collect::<HashSet<_>>();
        output.extend(layers.keys().copied().filter(|id| !seen.contains(id)));
    }
    output
}

fn layer_subtree_ids(
    layers: &BTreeMap<LayerId, LayerState>,
    root: LayerId,
) -> Result<Vec<LayerId>, EngineError> {
    fn visit(layers: &BTreeMap<LayerId, LayerState>, parent: LayerId, output: &mut Vec<LayerId>) {
        let mut children = layers
            .values()
            .filter(|layer| layer.layer.parent == Some(parent))
            .map(|layer| (layer.layer.order, layer.layer.id))
            .collect::<Vec<_>>();
        children.sort_unstable();
        for (_, child) in children {
            output.push(child);
            visit(layers, child, output);
        }
    }

    if !layers.contains_key(&root) {
        return Err(EngineError::InvalidLayer);
    }
    let mut output = vec![root];
    visit(layers, root, &mut output);
    Ok(output)
}

fn ordered_layer_states(layers: &BTreeMap<LayerId, LayerState>) -> Vec<&LayerState> {
    ordered_layer_ids(layers)
        .into_iter()
        .filter_map(|id| layers.get(&id))
        .collect()
}

fn normalize_sibling_orders(layers: &mut BTreeMap<LayerId, LayerState>, parent: Option<LayerId>) {
    let mut siblings = layers
        .values()
        .filter(|state| state.layer.parent == parent)
        .map(|state| (state.layer.order, state.layer.id))
        .collect::<Vec<_>>();
    siblings.sort_unstable();
    for (order, (_, id)) in siblings.into_iter().enumerate() {
        if let Some(state) = layers.get_mut(&id) {
            state.layer.order = u32::try_from(order).unwrap_or(u32::MAX);
        }
    }
}

fn next_layer_id(layers: &BTreeMap<LayerId, LayerState>) -> Result<LayerId, EngineError> {
    let mut candidate = layers.keys().next_back().map_or(0, |id| id.0);
    loop {
        candidate = candidate
            .checked_add(1)
            .ok_or_else(|| EngineError::InvalidCommand("layer ID space exhausted".into()))?;
        let id = LayerId::from_u128(candidate);
        if !layers.contains_key(&id) {
            return Ok(id);
        }
    }
}

fn normalize_duplicate_roots(
    layers: &BTreeMap<LayerId, LayerState>,
    selected: Vec<LayerId>,
) -> Result<Vec<LayerId>, EngineError> {
    if !(2..=4_096).contains(&selected.len()) {
        return Err(EngineError::InvalidCommand(
            "duplicate selected requires between two and 4096 layers".into(),
        ));
    }
    let mut normalized = HashSet::new();
    for id in selected {
        let layer = layers.get(&id).ok_or(EngineError::InvalidLayer)?;
        normalized.insert(layer.layer.mask_owner.unwrap_or(id));
    }
    let mut roots = normalized
        .iter()
        .copied()
        .filter(|candidate| {
            let mut parent = layers.get(candidate).and_then(|item| item.layer.parent);
            let mut visited = HashSet::new();
            while let Some(id) = parent {
                if normalized.contains(&id) {
                    return false;
                }
                if !visited.insert(id) {
                    break;
                }
                parent = layers.get(&id).and_then(|item| item.layer.parent);
            }
            true
        })
        .collect::<Vec<_>>();
    if roots.len() < 2 {
        return Err(EngineError::InvalidCommand(
            "duplicate selected requires at least two structural roots".into(),
        ));
    }
    let parent = layers[&roots[0]].layer.parent;
    if roots.iter().any(|id| layers[id].layer.parent != parent) {
        return Err(EngineError::InvalidCommand(
            "bulk duplicate requires sibling roots".into(),
        ));
    }
    roots.sort_by_key(|id| (layers[id].layer.order, *id));
    Ok(roots)
}

fn duplicate_source_mapping(
    layers: &BTreeMap<LayerId, LayerState>,
    roots: &[LayerId],
) -> Result<Vec<(LayerId, LayerId)>, EngineError> {
    let mut sources = Vec::new();
    for root in roots {
        let layer = &layers[root].layer;
        if layer.kind == LayerKind::Group {
            sources.extend(layer_subtree_ids(layers, *root)?);
        } else if layer.kind != LayerKind::Mask {
            sources.push(*root);
        }
        if layer.kind != LayerKind::Mask {
            let mut masks = layers
                .values()
                .filter(|candidate| {
                    candidate.layer.kind == LayerKind::Mask
                        && candidate.layer.mask_owner == Some(*root)
                })
                .map(|candidate| (candidate.layer.order, candidate.layer.id))
                .collect::<Vec<_>>();
            masks.sort_unstable();
            sources.extend(masks.into_iter().map(|(_, id)| id));
        }
    }
    if sources.len() > 4_096 {
        return Err(EngineError::InvalidCommand(
            "bulk duplicate exceeds the layer command limit".into(),
        ));
    }
    let mut next = next_layer_id(layers)?.0;
    sources
        .into_iter()
        .map(|source| {
            let duplicate = LayerId::from_u128(next);
            next = next
                .checked_add(1)
                .ok_or_else(|| EngineError::InvalidCommand("layer ID space exhausted".into()))?;
            Ok((source, duplicate))
        })
        .collect()
}

fn bounded_selection_coordinate(value: f32, extent: u32) -> i32 {
    let limit = i32::try_from(extent).unwrap_or(i32::MAX);
    value.round().clamp(
        -(limit.saturating_mul(2) as f32),
        limit.saturating_mul(2) as f32,
    ) as i32
}

fn resource_total_bytes(resources: &BTreeMap<[u8; 32], BrushResource>) -> usize {
    resources
        .values()
        .map(|resource| resource.rgba8.len())
        .sum()
}

fn layer_map_bytes(layers: &BTreeMap<LayerId, LayerState>) -> usize {
    layers.values().fold(0usize, |total, layer| {
        let tiles = layer.tiles.tiles();
        total
            .saturating_add(std::mem::size_of::<LayerState>())
            .saturating_add(
                layer
                    .vectors
                    .iter()
                    .map(|(_, vector)| {
                        std::mem::size_of::<ink_model::StrokeId>()
                            .saturating_add(std::mem::size_of::<VectorStroke>())
                            .saturating_add(
                                vector
                                    .points
                                    .len()
                                    .saturating_mul(std::mem::size_of::<VectorPoint>()),
                            )
                    })
                    .fold(0usize, usize::saturating_add),
            )
            .saturating_add(tiles.iter().fold(0usize, |tile_total, (_, bytes)| {
                tile_total
                    .saturating_add(std::mem::size_of::<TileCoord>())
                    .saturating_add(std::mem::size_of::<Vec<u8>>())
                    .saturating_add(bytes.len())
            }))
    })
}

mod history;
#[cfg(test)]
use history::time_lapse_has_capacity_at;
use history::{time_lapse_has_capacity, trim_history_snapshots};

fn compositor_blend_mode(mode: ink_model::LayerBlendMode) -> ink_compositor::BlendMode {
    match mode {
        ink_model::LayerBlendMode::Normal => ink_compositor::BlendMode::Normal,
        ink_model::LayerBlendMode::Multiply => ink_compositor::BlendMode::Multiply,
        ink_model::LayerBlendMode::Screen => ink_compositor::BlendMode::Screen,
        ink_model::LayerBlendMode::Overlay => ink_compositor::BlendMode::Overlay,
        ink_model::LayerBlendMode::Darken => ink_compositor::BlendMode::Darken,
        ink_model::LayerBlendMode::Lighten => ink_compositor::BlendMode::Lighten,
        ink_model::LayerBlendMode::Add => ink_compositor::BlendMode::Add,
        ink_model::LayerBlendMode::Subtract => ink_compositor::BlendMode::Subtract,
        ink_model::LayerBlendMode::ColorBurn => ink_compositor::BlendMode::ColorBurn,
        ink_model::LayerBlendMode::LinearBurn => ink_compositor::BlendMode::LinearBurn,
        ink_model::LayerBlendMode::ColorDodge => ink_compositor::BlendMode::ColorDodge,
        ink_model::LayerBlendMode::SoftLight => ink_compositor::BlendMode::SoftLight,
        ink_model::LayerBlendMode::HardLight => ink_compositor::BlendMode::HardLight,
        ink_model::LayerBlendMode::Difference => ink_compositor::BlendMode::Difference,
        ink_model::LayerBlendMode::Exclusion => ink_compositor::BlendMode::Exclusion,
        ink_model::LayerBlendMode::Divide => ink_compositor::BlendMode::Divide,
    }
}

/// Immutable inputs validated before applying a raster merge.
struct PreparedRasterMerge {
    source_parent: Option<LayerId>,
    source_opacity: u16,
    source_tiles: HashMap<TileCoord, Tile>,
    target_tiles: HashMap<TileCoord, Tile>,
    coordinates: HashSet<TileCoord>,
}

fn validate_raster_merge_structure(
    state: &EngineState,
    target: LayerId,
    source: LayerId,
) -> Result<(Option<LayerId>, u16), EngineError> {
    if target == source {
        return Err(EngineError::InvalidCommand(
            "a layer cannot be merged into itself".into(),
        ));
    }
    let target_state = state.layers.get(&target).ok_or(EngineError::InvalidLayer)?;
    let source_state = state.layers.get(&source).ok_or(EngineError::InvalidLayer)?;
    let source_parent = source_state.layer.parent;
    if target_state.layer.kind != LayerKind::Raster || source_state.layer.kind != LayerKind::Raster
    {
        return Err(EngineError::InvalidCommand(
            "layer merge currently requires two raster layers".into(),
        ));
    }
    if target_state.layer.parent != source_state.layer.parent {
        return Err(EngineError::InvalidCommand(
            "layer merge requires layers in the same group".into(),
        ));
    }
    if !target_state.layer.visible || !source_state.layer.visible {
        return Err(EngineError::InvalidCommand(
            "show both layers before merging them".into(),
        ));
    }
    if target_state.layer.blend_mode != ink_model::LayerBlendMode::Normal
        || source_state.layer.blend_mode != ink_model::LayerBlendMode::Normal
    {
        return Err(EngineError::InvalidCommand(
            "safe merge currently requires Normal blending on both layers".into(),
        ));
    }
    let siblings = {
        let mut ordered = state
            .layers
            .values()
            .filter(|candidate| candidate.layer.parent == source_parent)
            .map(|candidate| (candidate.layer.order, candidate.layer.id))
            .collect::<Vec<_>>();
        ordered.sort_unstable();
        ordered
    };
    let source_index = siblings
        .iter()
        .position(|(_, id)| *id == source)
        .ok_or(EngineError::InvalidLayer)?;
    if source_index == 0 || siblings[source_index - 1].1 != target {
        return Err(EngineError::InvalidCommand(
            "merge requires contiguous siblings with the target directly below the source".into(),
        ));
    }
    if state.layers.values().any(|candidate| {
        candidate.layer.parent == Some(target) || candidate.layer.parent == Some(source)
    }) {
        return Err(EngineError::InvalidCommand(
            "layer merge requires standalone layers without children".into(),
        ));
    }
    if target_state.layer.clipping || source_state.layer.clipping {
        return Err(EngineError::InvalidCommand(
            "disable clipping before merging layers".into(),
        ));
    }
    let has_sibling_mask = state.layers.values().any(|candidate| {
        candidate.layer.parent == source_parent && candidate.layer.kind == LayerKind::Mask
    });
    if has_sibling_mask
        || ancestor_has_mask_node(&state.layers, target_state)
        || ancestor_has_mask_node(&state.layers, source_state)
    {
        return Err(EngineError::InvalidCommand(
            "remove or apply attached masks before merging layers".into(),
        ));
    }

    if target_state.layer.opacity != u16::MAX {
        return Err(EngineError::InvalidCommand(
            "exact merge requires the lower target at 100% opacity".into(),
        ));
    }
    Ok((source_parent, source_state.layer.opacity))
}

fn prepare_merge_raster_layers(
    state: &EngineState,
    target: LayerId,
    source: LayerId,
) -> Result<PreparedRasterMerge, EngineError> {
    let (source_parent, source_opacity) = validate_raster_merge_structure(state, target, source)?;
    let target_state = state.layers.get(&target).ok_or(EngineError::InvalidLayer)?;
    let source_state = state.layers.get(&source).ok_or(EngineError::InvalidLayer)?;
    let source_tiles = source_state
        .tiles
        .tiles()
        .into_iter()
        .map(|(coordinate, bytes)| {
            Tile::from_bytes(bytes)
                .map(|tile| (coordinate, tile))
                .map_err(|error| {
                    EngineError::InvalidCommand(format!("source tile is invalid: {error:?}"))
                })
        })
        .collect::<Result<HashMap<_, _>, _>>()?;
    let target_tiles = target_state
        .tiles
        .tiles()
        .into_iter()
        .map(|(coordinate, bytes)| {
            Tile::from_bytes(bytes)
                .map(|tile| (coordinate, tile))
                .map_err(|error| {
                    EngineError::InvalidCommand(format!("target tile is invalid: {error:?}"))
                })
        })
        .collect::<Result<HashMap<_, _>, _>>()?;
    let coordinates = target_tiles
        .keys()
        .chain(source_tiles.keys())
        .copied()
        .collect::<HashSet<_>>();

    // Flattening translucent layers onto a transparent target changes the
    // group alpha semantics for unknown backdrops. Require fully covered
    // target pixels beneath every source mark, so the merged layer remains
    // pixel-identical for any content behind it.
    for (coordinate, source_tile) in &source_tiles {
        let target_tile = target_tiles.get(coordinate);
        for local_y in 0..TILE_SIZE {
            let document_y = i64::from(coordinate.y)
                .saturating_mul(i64::from(TILE_SIZE))
                .saturating_add(i64::from(local_y));
            if document_y < 0 || document_y >= i64::from(state.height_px) {
                continue;
            }
            for local_x in 0..TILE_SIZE {
                let document_x = i64::from(coordinate.x)
                    .saturating_mul(i64::from(TILE_SIZE))
                    .saturating_add(i64::from(local_x));
                if document_x < 0 || document_x >= i64::from(state.width_px) {
                    continue;
                }
                let source_pixel = source_tile.pixel_rgba(local_x, local_y);
                let target_pixel =
                    target_tile.map_or(Rgba8::default(), |tile| tile.pixel_rgba(local_x, local_y));
                if source_pixel.a != 0 && target_pixel.a != u8::MAX {
                    return Err(EngineError::InvalidCommand(
                        "exact merge requires opaque lower-layer coverage beneath source marks"
                            .into(),
                    ));
                }
            }
        }
    }

    Ok(PreparedRasterMerge {
        source_parent,
        source_opacity,
        source_tiles,
        target_tiles,
        coordinates,
    })
}

/// Merge one standalone raster layer into another using the same deterministic
/// compositor used for export. The source layer is removed only after every
/// source tile has been validated and applied. This keeps the operation
/// atomic from the caller's perspective: validation failures cannot partially
/// mutate the document, while the normal layer-map snapshot makes the command
/// fully undoable and journal-replayable.
#[allow(clippy::too_many_lines)]
fn merge_raster_layers(
    state: &mut EngineState,
    target: LayerId,
    source: LayerId,
) -> Result<Vec<TileCoord>, EngineError> {
    let PreparedRasterMerge {
        source_parent,
        source_opacity,
        source_tiles,
        target_tiles,
        coordinates,
    } = prepare_merge_raster_layers(state, target, source)?;
    let mut dirty = HashSet::new();
    let target_state = state
        .layers
        .get_mut(&target)
        .ok_or(EngineError::InvalidLayer)?;
    for coordinate in coordinates {
        let target_tile = target_tiles.get(&coordinate);
        let source_tile = source_tiles.get(&coordinate);
        for local_y in 0..TILE_SIZE {
            let document_y = i64::from(coordinate.y)
                .saturating_mul(i64::from(TILE_SIZE))
                .saturating_add(i64::from(local_y));
            if document_y < 0 || document_y >= i64::from(state.height_px) {
                continue;
            }
            for local_x in 0..TILE_SIZE {
                let document_x = i64::from(coordinate.x)
                    .saturating_mul(i64::from(TILE_SIZE))
                    .saturating_add(i64::from(local_x));
                if document_x < 0 || document_x >= i64::from(state.width_px) {
                    continue;
                }
                let target_pixel =
                    target_tile.map_or(Rgba8::default(), |tile| tile.pixel_rgba(local_x, local_y));
                let source_pixel =
                    source_tile.map_or(Rgba8::default(), |tile| tile.pixel_rgba(local_x, local_y));
                let merged = if source_pixel.a == 0 {
                    [
                        target_pixel.r,
                        target_pixel.g,
                        target_pixel.b,
                        target_pixel.a,
                    ]
                } else {
                    ink_compositor::blend_rgba8(
                        [
                            target_pixel.r,
                            target_pixel.g,
                            target_pixel.b,
                            target_pixel.a,
                        ],
                        [
                            source_pixel.r,
                            source_pixel.g,
                            source_pixel.b,
                            source_pixel.a,
                        ],
                        source_opacity,
                        ink_compositor::BlendMode::Normal,
                    )
                };
                let x = u32::try_from(document_x).map_err(|_| {
                    EngineError::InvalidCommand("target tile coordinate overflow".into())
                })?;
                let y = u32::try_from(document_y).map_err(|_| {
                    EngineError::InvalidCommand("target tile coordinate overflow".into())
                })?;
                target_state.tiles.set_pixel(
                    x,
                    y,
                    Rgba8 {
                        r: merged[0],
                        g: merged[1],
                        b: merged[2],
                        a: merged[3],
                    },
                );
            }
        }
        dirty.insert(coordinate);
    }
    target_state.layer.opacity = u16::MAX;
    target_state.layer.blend_mode = ink_model::LayerBlendMode::Normal;
    state.layers.remove(&source);
    normalize_sibling_orders(&mut state.layers, source_parent);
    let mut dirty = dirty.into_iter().collect::<Vec<_>>();
    dirty.sort_unstable_by_key(|coordinate| (coordinate.y, coordinate.x));
    Ok(dirty)
}

/// Conservatively reject exact merges anywhere under a group that owns a mask
/// node, including disabled/empty masks. A merge must not change which content
/// an attached group mask affects.
fn ancestor_has_mask_node(layers: &BTreeMap<LayerId, LayerState>, layer: &LayerState) -> bool {
    let mut current = layer.layer.parent;
    let mut visited = HashSet::new();
    while let Some(parent_id) = current {
        if !visited.insert(parent_id) {
            return true;
        }
        let Some(parent) = layers.get(&parent_id) else {
            return true;
        };
        if matches!(parent.layer.kind, LayerKind::Group | LayerKind::PanelGroup)
            && layers.values().any(|candidate| {
                candidate.layer.mask_owner == Some(parent_id)
                    && candidate.layer.kind == LayerKind::Mask
            })
        {
            return true;
        }
        current = parent.layer.parent;
    }
    false
}

/// Return the visible mask explicitly attached to a paint layer.
fn mask_sibling<'a>(
    layers: &'a BTreeMap<LayerId, LayerState>,
    layer: &LayerState,
) -> Option<&'a LayerState> {
    if !matches!(layer.layer.kind, LayerKind::Raster | LayerKind::VectorInk) {
        return None;
    }
    layers.values().find(|candidate| {
        candidate.layer.kind == LayerKind::Mask
            && candidate.layer.mask_owner == Some(layer.layer.id)
            && candidate.layer.visible
            && candidate.layer.mask_enabled
    })
}

fn point_inside_polygon(x: f32, y: f32, points: &[(f32, f32)]) -> bool {
    let mut inside = false;
    let mut previous = points[points.len() - 1];
    for &current in points {
        if ((current.1 > y) != (previous.1 > y))
            && x < (previous.0 - current.0) * (y - current.1)
                / (previous.1 - current.1).max(f32::MIN_POSITIVE)
                + current.0
        {
            inside = !inside;
        }
        previous = current;
    }
    inside
}

/// Return a visible mask owned by the nearest structural group ancestor.
/// Panel masks use this path so one geometry stencil clips every paint child,
/// rather than only the last sibling in the group.
fn ancestor_group_mask<'a>(
    layers: &'a BTreeMap<LayerId, LayerState>,
    layer: &LayerState,
) -> Option<&'a LayerState> {
    let mut current = layer.layer.parent;
    let mut visited = HashSet::new();
    while let Some(parent_id) = current {
        if !visited.insert(parent_id) {
            return None;
        }
        let parent = layers.get(&parent_id)?;
        if matches!(parent.layer.kind, LayerKind::Group | LayerKind::PanelGroup) {
            let mask_id = layers
                .values()
                .find(|candidate| {
                    candidate.layer.mask_owner == Some(parent_id)
                        && candidate.layer.kind == LayerKind::Mask
                        && candidate.layer.visible
                        && candidate.layer.mask_enabled
                        && candidate.tiles.allocated_tiles() > 0
                })
                .map(|candidate| candidate.layer.id);
            if let Some(mask_id) = mask_id {
                return layers.get(&mask_id);
            }
        }
        current = parent.layer.parent;
    }
    None
}

/// Convert stored mask alpha into effective reveal coverage. Ordinary masks
/// store hidden coverage, so absent sparse pixels reveal by default. Legacy
/// geometry masks store reveal coverage directly.
fn mask_coverage(alpha: u8, stencil: bool, inverted: bool) -> u32 {
    let coverage = if stencil { alpha } else { u8::MAX - alpha };
    u32::from(if inverted {
        u8::MAX - coverage
    } else {
        coverage
    })
}

fn sample_layer_thumbnail_pixel(
    layer: &LayerState,
    is_mask: bool,
    source_size: (u64, u64),
    content_size: (usize, usize),
    cell: (usize, usize),
) -> Rgba8 {
    let (source_width, source_height) = source_size;
    let (content_width, content_height) = content_size;
    let (x, y) = cell;
    let cell_start = |position: usize, source: u64, content: usize| {
        u64::try_from(position).unwrap_or(0) * source / u64::try_from(content).unwrap_or(1)
    };
    let row_start = cell_start(y, source_height, content_height);
    let row_end = cell_start(y + 1, source_height, content_height).max(row_start + 1);
    let row_span = row_end.saturating_sub(row_start);
    let column_start = cell_start(x, source_width, content_width);
    let column_end = cell_start(x + 1, source_width, content_width).max(column_start + 1);
    let column_span = column_end.saturating_sub(column_start);
    let sample_rows = row_span.min(12);
    let sample_columns = column_span.min(12);
    let mut strongest = Rgba8::default();
    let mut mask_coverage_total = 0_u32;
    for sample_y in 0..sample_rows {
        let source_y =
            row_start + (sample_y * row_span / sample_rows) + (row_span / sample_rows / 2);
        for sample_x in 0..sample_columns {
            let source_x = column_start
                + (sample_x * column_span / sample_columns)
                + (column_span / sample_columns / 2);
            let candidate = layer.tiles.sample_pixel(
                source_x.min(source_width.saturating_sub(1)) as u32,
                source_y.min(source_height.saturating_sub(1)) as u32,
            );
            if is_mask {
                mask_coverage_total += mask_coverage(
                    candidate.a,
                    layer.layer.mask_stencil,
                    layer.layer.mask_inverted,
                );
            } else if candidate.a > strongest.a {
                strongest = candidate;
            }
        }
    }
    if is_mask {
        let count = u32::try_from(sample_rows * sample_columns).unwrap_or(u32::MAX);
        let coverage = u8::try_from(mask_coverage_total / count).unwrap_or(u8::MAX);
        Rgba8 {
            r: coverage,
            g: coverage,
            b: coverage,
            a: u8::MAX,
        }
    } else {
        strongest
    }
}

/// Resolve ancestor visibility and opacity for a paint layer. Groups are
/// structural nodes, but their presentation state still affects every child;
/// keeping this calculation in Rust ensures layer-panel changes and exports
/// use the same authoritative result. The validated layer tree bounds the
/// walk, while the visited set protects the read path from malformed state.
fn effective_layer_presentation(
    layers: &BTreeMap<LayerId, LayerState>,
    layer_id: LayerId,
) -> (bool, u16) {
    let mut current = Some(layer_id);
    let mut visible = true;
    let mut opacity = u32::from(u16::MAX);
    let mut visited = HashSet::new();
    while let Some(id) = current {
        if !visited.insert(id) {
            return (false, 0);
        }
        let Some(layer) = layers.get(&id) else {
            return (false, 0);
        };
        visible &= layer.layer.visible;
        opacity = (opacity * u32::from(layer.layer.opacity) + 32_767) / 65_535;
        current = layer.layer.parent;
    }
    (visible, u16::try_from(opacity).unwrap_or(u16::MAX))
}

fn apply_solo_visibility(
    layers: &mut BTreeMap<LayerId, LayerState>,
    selected: LayerId,
) -> Result<(), EngineError> {
    let selected_layer = layers.get(&selected).ok_or(EngineError::InvalidLayer)?;
    let owner = if selected_layer.layer.kind == LayerKind::Mask {
        selected_layer
            .layer
            .mask_owner
            .ok_or_else(|| EngineError::InvalidCommand("solo requires an attached mask".into()))?
    } else {
        selected
    };
    let root = layers.get(&owner).ok_or(EngineError::InvalidLayer)?;
    if !matches!(
        root.layer.kind,
        LayerKind::Raster | LayerKind::VectorInk | LayerKind::Group
    ) {
        return Err(EngineError::InvalidCommand(
            "solo is supported for paint layers and ordinary groups".into(),
        ));
    }

    let mut included = HashSet::from([owner, selected]);
    if root.layer.kind == LayerKind::Group {
        for candidate in layers.values() {
            let mut parent = candidate.layer.parent;
            let mut visited = HashSet::new();
            while let Some(parent_id) = parent {
                if !visited.insert(parent_id) {
                    break;
                }
                if parent_id == owner {
                    included.insert(candidate.layer.id);
                    break;
                }
                parent = layers.get(&parent_id).and_then(|item| item.layer.parent);
            }
        }
    }
    let included_owners = included.clone();
    for candidate in layers.values() {
        if candidate
            .layer
            .mask_owner
            .is_some_and(|mask_owner| included_owners.contains(&mask_owner))
        {
            included.insert(candidate.layer.id);
        }
    }

    // The isolated layer and its ancestor groups must render even if their
    // saved visibility flags are off. Descendant visibility inside a soloed
    // group remains governed by the saved flags and is never rewritten.
    let mut forced_visible = HashSet::from([selected, owner]);
    let mut current = layers.get(&owner).and_then(|item| item.layer.parent);
    let mut visited = HashSet::new();
    while let Some(id) = current {
        if !visited.insert(id) {
            break;
        }
        forced_visible.insert(id);
        current = layers.get(&id).and_then(|item| item.layer.parent);
    }
    for (id, layer) in layers {
        layer.layer.visible =
            included.contains(id) && (forced_visible.contains(id) || layer.layer.visible);
    }
    Ok(())
}

fn validate_layer_panel_state<'a>(
    panel_state: &LayerPanelState,
    layers: impl IntoIterator<Item = &'a Layer>,
) -> Result<(), EngineError> {
    let mut layer_kinds = HashMap::new();
    for layer in layers {
        layer_kinds.insert(layer.id, layer.kind);
    }
    if panel_state
        .primary_layer
        .is_some_and(|primary| !layer_kinds.contains_key(&primary))
    {
        return Err(EngineError::InvalidCommand(
            "layer-panel primary target does not exist".into(),
        ));
    }
    let mut collapsed_groups = HashSet::with_capacity(panel_state.collapsed_groups.len());
    if panel_state.collapsed_groups.iter().any(|group| {
        layer_kinds.get(group) != Some(&LayerKind::Group) || !collapsed_groups.insert(*group)
    }) {
        return Err(EngineError::InvalidCommand(
            "collapsed layer-panel entries must be unique ordinary groups".into(),
        ));
    }
    Ok(())
}

mod worker;
use worker::RenderWorker;
#[cfg(test)]
use worker::WorkerControl;

/// Rust-authoritative drag source and group destination availability.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LayerDragCapability {
    pub layer_id: LayerId,
    pub can_drag: bool,
    pub drag_reason: Option<String>,
    pub can_receive_layers: bool,
    pub receive_reason: Option<String>,
}

/// Rust-authoritative availability for common single-layer actions.
// Each independent action needs a direct availability bit and a reason for UI
// rendering; keeping both in this projection avoids re-deriving Rust rules.
#[allow(clippy::struct_excessive_bools)]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LayerActionCapability {
    pub layer_id: LayerId,
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

fn comic_owned_layer_ids(comic_json: Option<&[u8]>) -> Result<HashSet<LayerId>, EngineError> {
    let Some(bytes) = comic_json else {
        return Ok(HashSet::new());
    };
    let project = ink_comic::ComicProject::from_json(bytes).map_err(|error| {
        EngineError::InvalidCommand(format!("cannot validate comic layer ownership: {error}"))
    })?;
    Ok(project
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
        .map(LayerId::from_u128)
        .collect())
}

fn layer_is_comic_owned(
    state: &EngineState,
    comic_owned_ids: &HashSet<LayerId>,
    layer_id: LayerId,
) -> bool {
    let mut cursor = Some(layer_id);
    let mut visited = HashSet::new();
    while let Some(current) = cursor {
        if !visited.insert(current) {
            return true;
        }
        let Some(layer) = state.layers.get(&current) else {
            return false;
        };
        if layer.layer.kind == LayerKind::PanelGroup || comic_owned_ids.contains(&current) {
            return true;
        }
        cursor = layer.layer.parent;
    }
    false
}

fn layer_lock_owner(state: &EngineState, layer_id: LayerId) -> Option<LayerId> {
    let mut cursor = Some(layer_id);
    let mut visited = HashSet::new();
    while let Some(current) = cursor {
        if !visited.insert(current) {
            return None;
        }
        let layer = state.layers.get(&current)?;
        if layer.layer.locked {
            return Some(current);
        }
        cursor = layer.layer.parent;
    }
    None
}

fn locked_layer_action_reason(state: &EngineState, owner: LayerId, action: &str) -> String {
    let name = state
        .layers
        .get(&owner)
        .map_or("a locked layer", |entry| entry.layer.name.as_str());
    format!("Locked by {name}; unlock it before {action}.")
}

fn duplicate_capacity_reason(existing_layers: usize, copied_layers: usize) -> Option<String> {
    (existing_layers.saturating_add(copied_layers) > MAX_LAYERS)
        .then(|| "Document layer limit reached; remove layers before duplicating.".into())
}

fn layer_merge_down_reason(
    state: &EngineState,
    comic_owned_ids: &HashSet<LayerId>,
    source: &Layer,
) -> Option<String> {
    if layer_is_comic_owned(state, comic_owned_ids, source.id) {
        return Some("Comic-owned layers must be merged in Comics.".into());
    }
    if source.kind != LayerKind::Raster {
        return Some("Merge is available only between raster layers.".into());
    }
    let mut siblings = state
        .layers
        .values()
        .filter(|candidate| candidate.layer.parent == source.parent)
        .map(|candidate| (candidate.layer.order, candidate.layer.id))
        .collect::<Vec<_>>();
    siblings.sort_unstable();
    let source_index = siblings.iter().position(|(_, id)| *id == source.id)?;
    if source_index == 0 {
        return Some("Choose a layer with a sibling directly below it.".into());
    }
    let target_id = siblings[source_index - 1].1;
    let target = state.layers.get(&target_id)?;
    if layer_is_comic_owned(state, comic_owned_ids, target_id) {
        return Some("Comic-owned layers must be merged in Comics.".into());
    }
    if let Some(owner) = layer_lock_owner(state, source.id) {
        return Some(locked_layer_action_reason(state, owner, "merging layers"));
    }
    if let Some(owner) = layer_lock_owner(state, target_id) {
        return Some(locked_layer_action_reason(state, owner, "merging layers"));
    }
    if target.layer.kind != LayerKind::Raster {
        return Some("Merge is available only between raster layers.".into());
    }
    if !source.visible || !target.layer.visible {
        return Some("Show both layers before merging them.".into());
    }
    if source.blend_mode != ink_model::LayerBlendMode::Normal
        || target.layer.blend_mode != ink_model::LayerBlendMode::Normal
    {
        return Some("Safe merge currently requires Normal blending on both layers.".into());
    }
    if state.layers.values().any(|candidate| {
        candidate.layer.parent == Some(source.id) || candidate.layer.parent == Some(target_id)
    }) {
        return Some("Layer merge requires standalone layers without children.".into());
    }
    if source.clipping || target.layer.clipping {
        return Some("Disable clipping before merging layers.".into());
    }
    if state.layers.values().any(|candidate| {
        candidate.layer.parent == source.parent && candidate.layer.kind == LayerKind::Mask
    }) || ancestor_has_mask_node(&state.layers, target)
        || state
            .layers
            .get(&source.id)
            .is_some_and(|layer| ancestor_has_mask_node(&state.layers, layer))
    {
        return Some("Remove or apply attached masks before merging layers.".into());
    }
    if target.layer.opacity != u16::MAX {
        return Some("Exact merge requires the lower target at 100% opacity.".into());
    }
    None
}

fn layer_drag_capability(
    state: &EngineState,
    comic_owned_ids: &HashSet<LayerId>,
    layer: &Layer,
) -> LayerDragCapability {
    let comic_owned = layer_is_comic_owned(state, comic_owned_ids, layer.id);
    let locked_by = layer_lock_owner(state, layer.id);
    let lock_reason = locked_by.map(|owner| {
        let owner_name = state
            .layers
            .get(&owner)
            .map_or("a locked layer", |item| item.layer.name.as_str());
        owner_name.to_owned()
    });
    let drag_reason = if comic_owned {
        Some("Comic-owned layers can only be rearranged in Comics.".into())
    } else if let Some(owner_name) = &lock_reason {
        Some(format!("Locked by {owner_name}; unlock it before moving."))
    } else if layer.kind == LayerKind::Mask && layer.mask_owner.is_some() {
        Some("Move the mask owner to keep its attached mask together.".into())
    } else {
        None
    };
    let receive_reason = if layer.kind != LayerKind::Group {
        Some("Only ordinary groups can contain layers.".into())
    } else if comic_owned {
        Some("Comic-owned groups can only be rearranged in Comics.".into())
    } else {
        lock_reason.map(|owner_name| {
            format!("Locked by {owner_name}; unlock it before moving layers inside.")
        })
    };
    LayerDragCapability {
        layer_id: layer.id,
        can_drag: drag_reason.is_none(),
        drag_reason,
        can_receive_layers: receive_reason.is_none(),
        receive_reason,
    }
}

fn layer_action_subtree_ids(state: &EngineState, root: LayerId) -> HashSet<LayerId> {
    let mut subtree = HashSet::from([root]);
    let mut pending = vec![root];
    let mut cursor = 0;
    while let Some(parent) = pending.get(cursor).copied() {
        cursor += 1;
        for child in state.layers.values().filter(|candidate| {
            candidate.layer.parent == Some(parent) || candidate.layer.mask_owner == Some(parent)
        }) {
            if subtree.insert(child.layer.id) {
                pending.push(child.layer.id);
            }
        }
    }
    subtree
}

fn group_layers_reason(
    state: &EngineState,
    comic_owned_ids: &HashSet<LayerId>,
    members: &[LayerId],
) -> Option<String> {
    if members.len() < 2 {
        return Some("Select at least two layers to create a group.".into());
    }
    if members.len() > 4_096 {
        return Some("Group selection exceeds the layer safety limit.".into());
    }
    if state.layers.len() >= MAX_LAYERS {
        return Some("Document layer safety limit reached.".into());
    }
    if state.revision == u64::MAX || next_layer_id(&state.layers).is_err() {
        return Some("No more layer IDs are available for a new group.".into());
    }
    if members.iter().copied().collect::<HashSet<_>>().len() != members.len() {
        return Some("A layer can only appear once in a group selection.".into());
    }

    let Some(first) = state.layers.get(&members[0]) else {
        return Some("One or more selected layers no longer exist.".into());
    };
    let parent = first.layer.parent;
    for member in members {
        let Some(layer) = state.layers.get(member) else {
            return Some("One or more selected layers no longer exist.".into());
        };
        if layer.layer.parent != parent {
            return Some("Group selected layers from the same parent.".into());
        }
        let subtree = layer_action_subtree_ids(state, *member);
        if layer.layer.kind == LayerKind::PanelGroup
            || subtree
                .iter()
                .any(|id| layer_is_comic_owned(state, comic_owned_ids, *id))
        {
            return Some("Comic-owned layers must be grouped through the comic workspace.".into());
        }
        if let Some(owner) = subtree.iter().find_map(|id| layer_lock_owner(state, *id)) {
            return Some(locked_layer_action_reason(state, owner, "grouping layers"));
        }
    }

    let mut siblings = state
        .layers
        .values()
        .filter(|candidate| candidate.layer.parent == parent)
        .map(|candidate| (candidate.layer.order, candidate.layer.id))
        .collect::<Vec<_>>();
    siblings.sort_unstable();
    let selected_positions = members
        .iter()
        .map(|member| siblings.iter().position(|(_, id)| id == member))
        .collect::<Option<Vec<_>>>();
    let Some(selected_positions) = selected_positions else {
        return Some("One or more selected layers no longer exist.".into());
    };
    let first_selected = *selected_positions.iter().min().unwrap_or(&0);
    let last_selected = *selected_positions.iter().max().unwrap_or(&0);
    let selected_members = members.iter().copied().collect::<HashSet<_>>();
    let attached_masks = state
        .layers
        .values()
        .filter(|candidate| {
            candidate.layer.kind == LayerKind::Mask
                && candidate.layer.parent == parent
                && candidate
                    .layer
                    .mask_owner
                    .is_some_and(|owner| selected_members.contains(&owner))
        })
        .map(|candidate| candidate.layer.id)
        .collect::<HashSet<_>>();
    let selected_range = &siblings[first_selected..=last_selected];
    if selected_range.iter().any(|(_, id)| {
        let layer = &state.layers[id].layer;
        layer.kind == LayerKind::Mask && !attached_masks.contains(id)
    }) {
        return Some("Grouping this range could move a mask away from its owner.".into());
    }
    if selected_range
        .iter()
        .any(|(_, id)| state.layers[id].layer.clipping)
    {
        return Some("Grouping this range could change clipping behavior.".into());
    }
    None
}

fn layer_action_capability(
    state: &EngineState,
    comic_owned_ids: &HashSet<LayerId>,
    layer: &Layer,
) -> LayerActionCapability {
    let subtree = layer_action_subtree_ids(state, layer.id);
    let mut ordered_subtree = subtree.iter().copied().collect::<Vec<_>>();
    ordered_subtree.sort_unstable();
    let lock_owner = ordered_subtree
        .iter()
        .find_map(|id| layer_lock_owner(state, *id));
    let lock_reason =
        lock_owner.map(|owner| locked_layer_action_reason(state, owner, "this action"));
    let comic_owned = ordered_subtree
        .iter()
        .any(|id| layer_is_comic_owned(state, comic_owned_ids, *id));

    let edit_properties_reason = layer_lock_owner(state, layer.id)
        .map(|owner| locked_layer_action_reason(state, owner, "changing properties"));
    let duplicate_reason = if comic_owned {
        Some("Comic-owned structures must be duplicated in Comics.".into())
    } else {
        lock_reason
            .clone()
            .or_else(|| duplicate_capacity_reason(state.layers.len(), subtree.len()))
    };
    let delete_reason = if comic_owned {
        Some("Comic-owned structures must be removed in Comics.".into())
    } else if let Some(reason) = &lock_reason {
        Some(reason.clone())
    } else if subtree.len() >= state.layers.len() {
        Some("A document must keep at least one layer.".into())
    } else {
        None
    };

    let ungroup_reason = if layer.kind != LayerKind::Group {
        Some("Only ordinary groups can be ungrouped here.".into())
    } else if comic_owned {
        Some("Comic-owned groups must be ungrouped in Comics.".into())
    } else if let Some(reason) = &lock_reason {
        Some(reason.clone())
    } else if layer.group_mode != ink_model::LayerGroupMode::PassThrough
        || layer.blend_mode != ink_model::LayerBlendMode::Normal
        || layer.opacity != u16::MAX
        || layer.clipping
        || layer.reference
    {
        Some("Ungroup requires a pass-through, Normal, 100% group without clipping or reference state.".into())
    } else if !state
        .layers
        .values()
        .any(|candidate| candidate.layer.parent == Some(layer.id))
    {
        Some("Empty groups have nothing to ungroup.".into())
    } else {
        let parent = layer.parent;
        let affects_relationship = state.layers.values().any(|candidate| {
            ((subtree.contains(&candidate.layer.id) || candidate.layer.parent == parent)
                && candidate.layer.id != layer.id)
                && (candidate.layer.kind == LayerKind::Mask || candidate.layer.clipping)
        });
        affects_relationship.then(|| "Ungroup could change mask or clipping relationships.".into())
    };

    let apply_mask_reason = if layer.kind != LayerKind::Mask {
        Some("Apply Mask is available only for mask layers.".into())
    } else if comic_owned {
        Some("Comic-owned masks must be applied in Comics.".into())
    } else if let Some(reason) = &lock_reason {
        Some(reason.clone())
    } else {
        match layer.mask_owner.and_then(|owner| state.layers.get(&owner)) {
            None => Some("Attach this mask to a layer before applying it.".into()),
            Some(owner) if owner.layer.kind != LayerKind::Raster => {
                Some("Apply Mask is supported for raster owners only.".into())
            }
            Some(owner) => layer_lock_owner(state, owner.layer.id)
                .map(|locked| locked_layer_action_reason(state, locked, "applying this mask")),
        }
    };
    let merge_down_reason = layer_merge_down_reason(state, comic_owned_ids, layer);

    LayerActionCapability {
        layer_id: layer.id,
        can_edit_properties: edit_properties_reason.is_none(),
        edit_properties_reason,
        can_duplicate: duplicate_reason.is_none(),
        duplicate_reason,
        can_delete: delete_reason.is_none(),
        delete_reason,
        can_ungroup: ungroup_reason.is_none(),
        ungroup_reason,
        can_apply_mask: apply_mask_reason.is_none(),
        apply_mask_reason,
        merge_down_reason,
    }
}

/// A document handle with revisioned state and event history.
#[derive(Debug)]
pub struct Document {
    pub id: DocumentId,
    pub spec: DocumentSpec,
    state: Arc<Mutex<EngineState>>,
    live_dabs: Arc<Mutex<ink_live_render::LiveDabQueue>>,
    live_dab_overflow_count: Arc<AtomicU64>,
    worker: RenderWorker,
}

/// Owned inputs for a composite tile read. The layer metadata and only the
/// requested raster tile bytes are captured under the document lock; callers
/// can then compose pixels after releasing both the engine and bridge locks.
pub struct CompositeTileReadSnapshot {
    revision: u64,
    width_px: u32,
    height_px: u32,
    background: Rgba8,
    layers: BTreeMap<LayerId, LayerState>,
}

impl CompositeTileReadSnapshot {
    /// Revision captured with this immutable set of layer tile bytes.
    #[must_use]
    pub fn revision(&self) -> u64 {
        self.revision
    }

    /// Composite the requested tiles from the captured revision.
    pub fn read_tiles(&self, coordinates: &[TileCoord]) -> Result<Vec<Vec<u8>>, EngineError> {
        coordinates
            .iter()
            .copied()
            .map(|coordinate| {
                Document::composite_tile_from_layers(
                    self.width_px,
                    self.height_px,
                    self.background,
                    &self.layers,
                    coordinate,
                )
            })
            .collect()
    }
}

impl Document {
    /// Replace the ephemeral selection with a bounded rectangle.
    pub fn select_rectangle(
        &mut self,
        x0: f32,
        y0: f32,
        x1: f32,
        y1: f32,
    ) -> Result<u64, EngineError> {
        let bounds = [x0, y0, x1, y1];
        if bounds.iter().any(|value| !value.is_finite()) {
            return Err(EngineError::InvalidCommand(
                "selection coordinates must be finite".into(),
            ));
        }
        let mask = SelectionMask::rectangle(
            self.spec.width_px,
            self.spec.height_px,
            bounded_selection_coordinate(x0, self.spec.width_px),
            bounded_selection_coordinate(y0, self.spec.height_px),
            bounded_selection_coordinate(x1, self.spec.width_px),
            bounded_selection_coordinate(y1, self.spec.height_px),
        )
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
        self.replace_selection(mask)
    }

    /// Replace the ephemeral selection with a bounded ellipse.
    pub fn select_ellipse(
        &mut self,
        center_x: f32,
        center_y: f32,
        radius_x: f32,
        radius_y: f32,
    ) -> Result<u64, EngineError> {
        let values = [center_x, center_y, radius_x, radius_y];
        if values.iter().any(|value| !value.is_finite()) || radius_x <= 0.0 || radius_y <= 0.0 {
            return Err(EngineError::InvalidCommand(
                "ellipse selection geometry is invalid".into(),
            ));
        }
        let mask = SelectionMask::ellipse(
            self.spec.width_px,
            self.spec.height_px,
            center_x,
            center_y,
            radius_x,
            radius_y,
        )
        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
        self.replace_selection(mask)
    }

    /// Replace the ephemeral selection with a bounded closed lasso polygon.
    pub fn select_lasso(&mut self, points: &[f32]) -> Result<u64, EngineError> {
        if points.len() < 6 || points.len() > 2_048 || !points.len().is_multiple_of(2) {
            return Err(EngineError::InvalidCommand(
                "lasso selection requires 3 to 1024 points".into(),
            ));
        }
        if points.iter().any(|value| !value.is_finite()) {
            return Err(EngineError::InvalidCommand(
                "lasso selection coordinates must be finite".into(),
            ));
        }
        let (pairs, remainder) = points.as_chunks::<2>();
        debug_assert!(remainder.is_empty());
        let polygon = pairs
            .iter()
            .map(|pair| (pair[0], pair[1]))
            .collect::<Vec<_>>();
        let mask = SelectionMask::lasso(self.spec.width_px, self.spec.height_px, &polygon)
            .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
        self.replace_selection(mask)
    }

    /// Select pixels on a layer whose alpha meets the supplied threshold.
    pub fn select_layer_opacity(
        &mut self,
        layer_id: LayerId,
        minimum_alpha: u8,
    ) -> Result<u64, EngineError> {
        let mask = self.mask_from_layer(layer_id, |pixel| pixel.a >= minimum_alpha)?;
        self.replace_selection(mask)
    }

    /// Select pixels on a layer within a bounded RGBA tolerance.
    pub fn select_color_range(
        &mut self,
        layer_id: LayerId,
        target: ink_model::Rgba8,
        tolerance: u16,
    ) -> Result<u64, EngineError> {
        let limit = u32::from(tolerance) * u32::from(tolerance);
        let mask = self.mask_from_layer(layer_id, |pixel| {
            [
                pixel.r.abs_diff(target.r),
                pixel.g.abs_diff(target.g),
                pixel.b.abs_diff(target.b),
                pixel.a.abs_diff(target.a),
            ]
            .into_iter()
            .map(u32::from)
            .map(|value| value * value)
            .sum::<u32>()
                <= limit
        })?;
        self.replace_selection(mask)
    }

    /// Clear the ephemeral selection without altering raster history.
    pub fn clear_selection(&mut self) -> Result<u64, EngineError> {
        self.flush_input()?;
        let mut state = lock_recover(&self.state);
        state.selection = None;
        let revision = advance_revision(&mut state)?;
        state.events.push(EngineEvent::DocumentChanged { revision });
        Ok(revision)
    }

    /// Invert the ephemeral selection coverage without changing document
    /// pixels or creating an undoable document edit.
    pub fn invert_selection(&mut self) -> Result<u64, EngineError> {
        self.update_selection(|selection| {
            selection.invert();
            Ok(())
        })
    }

    /// Grow the ephemeral selection by one to 256 pixels.
    pub fn grow_selection(&mut self, radius: u32) -> Result<u64, EngineError> {
        self.update_selection(|selection| {
            selection
                .grow(radius)
                .map_err(|error| EngineError::InvalidCommand(error.to_string()))
        })
    }

    /// Shrink the ephemeral selection by one to 256 pixels.
    pub fn shrink_selection(&mut self, radius: u32) -> Result<u64, EngineError> {
        self.update_selection(|selection| {
            selection
                .shrink(radius)
                .map_err(|error| EngineError::InvalidCommand(error.to_string()))
        })
    }

    fn update_selection(
        &mut self,
        update: impl FnOnce(&mut SelectionMask) -> Result<(), EngineError>,
    ) -> Result<u64, EngineError> {
        self.flush_input()?;
        let mut state = lock_recover(&self.state);
        let selection = state
            .selection
            .as_mut()
            .ok_or_else(|| EngineError::InvalidCommand("no active selection to modify".into()))?;
        update(selection)?;
        advance_revision(&mut state)?;
        let revision = state.revision;
        state.events.push(EngineEvent::DocumentChanged { revision });
        Ok(revision)
    }

    /// Fill a contiguous raster region with bounded tolerance and gap
    /// closing. The operation is a normal editor command, so the existing
    /// layer snapshot machinery makes it undoable and recoverable.
    pub fn fill_region(
        &mut self,
        layer_id: LayerId,
        x: u32,
        y: u32,
        color: ink_model::Rgba8,
        tolerance: u16,
        gap: u32,
    ) -> Result<u64, EngineError> {
        self.dispatch(EditorCommand::FillRegion {
            layer: layer_id,
            x,
            y,
            color,
            tolerance,
            gap,
        })
    }

    /// Apply a deterministic gradient using flood-fill, Paint Inside, and
    /// optional transparent-only masking. All parameters are journaled as one
    /// undoable command.
    #[allow(clippy::too_many_arguments)]
    pub fn gradient_fill(
        &mut self,
        layer_id: LayerId,
        x: u32,
        y: u32,
        start: (f32, f32),
        end: (f32, f32),
        from: ink_model::Rgba8,
        to: ink_model::Rgba8,
        tolerance: u16,
        gap: u32,
        expansion: u32,
        paint_inside: bool,
        paint_unfilled: bool,
    ) -> Result<u64, EngineError> {
        self.dispatch(EditorCommand::GradientFill {
            layer: layer_id,
            x,
            y,
            start_x: start.0,
            start_y: start.1,
            end_x: end.0,
            end_y: end.1,
            from,
            to,
            tolerance,
            gap,
            expansion,
            paint_inside,
            paint_unfilled,
        })
    }

    /// Apply an undoable perspective transform to a raster layer.
    pub fn perspective_layer(
        &mut self,
        layer_id: LayerId,
        target: [(f32, f32); 4],
    ) -> Result<u64, EngineError> {
        self.dispatch(EditorCommand::PerspectiveLayer {
            layer: layer_id,
            target,
        })
    }

    /// Apply an undoable regular mesh transform to a raster layer.
    pub fn mesh_layer(
        &mut self,
        layer_id: LayerId,
        columns: u16,
        rows: u16,
        points: Vec<(f32, f32)>,
    ) -> Result<u64, EngineError> {
        self.dispatch(EditorCommand::MeshLayer {
            layer: layer_id,
            columns,
            rows,
            points,
        })
    }

    /// Apply an undoable local liquify deformation to a raster layer.
    #[allow(clippy::too_many_arguments)]
    pub fn liquify_layer(
        &mut self,
        layer_id: LayerId,
        center_x: f32,
        center_y: f32,
        radius: f32,
        strength: f32,
        mode: u8,
        direction_x: f32,
        direction_y: f32,
    ) -> Result<u64, EngineError> {
        self.dispatch(EditorCommand::LiquifyLayer {
            layer: layer_id,
            center_x,
            center_y,
            radius,
            strength,
            mode,
            direction_x,
            direction_y,
        })
    }

    /// Add an editable vector centerline stroke to a vector-ink layer.
    pub fn add_vector_stroke(
        &mut self,
        layer_id: LayerId,
        stroke_id: ink_model::StrokeId,
        points: Vec<(f32, f32, f32, f32)>,
        closed: bool,
    ) -> Result<u64, EngineError> {
        self.dispatch(EditorCommand::AddVectorStroke {
            layer: layer_id,
            stroke: stroke_id,
            points,
            closed,
        })
    }

    /// Add a layer and return its stable ID for UI selection.
    pub fn add_layer(&mut self, kind: LayerKind) -> Result<LayerId, EngineError> {
        self.add_layer_with_parent(kind, None)
    }

    /// Add a layer under an existing group or panel parent.
    pub fn add_layer_with_parent(
        &mut self,
        kind: LayerKind,
        parent: Option<LayerId>,
    ) -> Result<LayerId, EngineError> {
        self.flush_input()?;
        let id = {
            let state = lock_recover(&self.state);
            next_layer_id(&state.layers)?
        };
        self.dispatch(EditorCommand::AddLayer { parent, kind })?;
        Ok(id)
    }

    /// Temporarily isolate one paint layer, its attached mask, or an ordinary
    /// group for inspection. Passing `None` restores saved visibility. Solo
    /// state is session-only and does not create history or alter layer flags.
    pub fn set_layer_solo(&mut self, layer: Option<LayerId>) -> Result<u64, EngineError> {
        self.flush_input()?;
        let mut state = lock_recover(&self.state);
        if state.solo_layer == layer {
            return Ok(state.revision);
        }
        if let Some(layer_id) = layer {
            let target = state
                .layers
                .get(&layer_id)
                .ok_or(EngineError::InvalidLayer)?;
            let owner = if target.layer.kind == LayerKind::Mask {
                target.layer.mask_owner.ok_or_else(|| {
                    EngineError::InvalidCommand("solo requires an attached mask".into())
                })?
            } else {
                layer_id
            };
            let owner = state.layers.get(&owner).ok_or(EngineError::InvalidLayer)?;
            if !matches!(
                owner.layer.kind,
                LayerKind::Raster | LayerKind::VectorInk | LayerKind::Group
            ) {
                return Err(EngineError::InvalidCommand(
                    "solo is supported for paint layers and ordinary groups".into(),
                ));
            }
        }
        state.solo_layer = layer;
        let revision = advance_revision(&mut state)?;
        state.events.push(EngineEvent::LayersChanged { revision });
        Ok(revision)
    }

    /// Delete one leaf layer as an undoable command. The engine rejects
    /// deletion of the final layer and groups that still contain children.
    pub fn delete_layer(&mut self, layer: LayerId) -> Result<u64, EngineError> {
        self.dispatch(EditorCommand::DeleteLayer { layer })
    }

    /// Delete selected layer roots and their descendants in one undoable
    /// command. Descendants of a selected group are normalized away so the
    /// same subtree is removed only once.
    pub fn delete_layers(&mut self, layers: Vec<LayerId>) -> Result<u64, EngineError> {
        self.dispatch(EditorCommand::DeleteLayers { layers })
    }

    /// Validate selected-layer deletion without changing content, revision,
    /// or history. The undoable delete command repeats the same plan at commit.
    pub fn preflight_delete_layers(
        &self,
        layers: &[LayerId],
    ) -> Result<Option<String>, EngineError> {
        self.flush_input()?;
        let state = lock_recover(&self.state);
        match commands::preflight_delete_layer_roots(&state, layers) {
            Ok(()) => Ok(None),
            Err(EngineError::InvalidCommand(reason)) => Ok(Some(reason)),
            Err(EngineError::InvalidLayer) => {
                Ok(Some("One or more selected layers no longer exist.".into()))
            }
            Err(error) => Err(error),
        }
    }

    /// Duplicate a layer with new stable IDs and insert it above the source.
    /// Ordinary groups include their complete ordered descendant hierarchy;
    /// comic-owned panel trees remain managed by the comic workspace.
    pub fn duplicate_layer(&mut self, source: LayerId) -> Result<LayerId, EngineError> {
        self.flush_input()?;
        let (kind, duplicates) = {
            let state = lock_recover(&self.state);
            let kind = state
                .layers
                .get(&source)
                .ok_or(EngineError::InvalidLayer)?
                .layer
                .kind;
            if kind == LayerKind::Group {
                let subtree = layer_subtree_ids(&state.layers, source)?;
                let mut next = next_layer_id(&state.layers)?.0;
                let mut mapping = Vec::with_capacity(subtree.len());
                for layer in subtree {
                    mapping.push((layer, LayerId::from_u128(next)));
                    next = next.checked_add(1).ok_or_else(|| {
                        EngineError::InvalidCommand("layer ID space exhausted".into())
                    })?;
                }
                (kind, mapping)
            } else {
                if kind == LayerKind::Mask
                    && state
                        .layers
                        .get(&source)
                        .is_some_and(|layer| layer.layer.mask_owner.is_some())
                {
                    return Err(EngineError::InvalidCommand(
                        "duplicate the mask owner to keep its attached mask relationship".into(),
                    ));
                }
                let mut next = next_layer_id(&state.layers)?.0;
                let mut mapping = vec![(source, LayerId::from_u128(next))];
                next = next.checked_add(1).ok_or_else(|| {
                    EngineError::InvalidCommand("layer ID space exhausted".into())
                })?;
                let mut masks = state
                    .layers
                    .values()
                    .filter(|layer| {
                        layer.layer.kind == LayerKind::Mask
                            && layer.layer.mask_owner == Some(source)
                    })
                    .map(|layer| (layer.layer.order, layer.layer.id))
                    .collect::<Vec<_>>();
                masks.sort_unstable();
                for (_, mask) in masks {
                    mapping.push((mask, LayerId::from_u128(next)));
                    next = next.checked_add(1).ok_or_else(|| {
                        EngineError::InvalidCommand("layer ID space exhausted".into())
                    })?;
                }
                (kind, mapping)
            }
        };
        if kind == LayerKind::Group {
            let duplicate = duplicates[0].1;
            self.dispatch(EditorCommand::DuplicateLayerSubtree { source, duplicates })?;
            Ok(duplicate)
        } else {
            let duplicate = duplicates[0].1;
            if duplicates.len() == 1 {
                self.dispatch(EditorCommand::DuplicateLayer { source, duplicate })?;
            } else {
                self.dispatch(EditorCommand::DuplicateLayerWithMasks {
                    source,
                    duplicate,
                    masks: duplicates.iter().skip(1).copied().collect(),
                })?;
            }
            Ok(duplicate)
        }
    }

    /// Duplicate selected sibling roots and their masks or group descendants
    /// as one undoable transaction. Descendants of selected groups are folded
    /// into their selected ancestor, and selecting an attached mask targets
    /// its owner so the relationship remains stable.
    pub fn duplicate_layers(
        &mut self,
        selected: Vec<LayerId>,
    ) -> Result<Vec<LayerId>, EngineError> {
        self.flush_input()?;
        let (sources, duplicates) = {
            let state = lock_recover(&self.state);
            let sources = normalize_duplicate_roots(&state.layers, selected)?;
            let duplicates = duplicate_source_mapping(&state.layers, &sources)?;
            (sources, duplicates)
        };
        let result = sources
            .iter()
            .map(|source| {
                duplicates
                    .iter()
                    .find(|(old, _)| old == source)
                    .map(|(_, new)| *new)
                    .ok_or(EngineError::InvalidLayer)
            })
            .collect::<Result<Vec<_>, _>>()?;
        self.dispatch(EditorCommand::DuplicateLayers {
            sources,
            duplicates,
        })?;
        Ok(result)
    }

    /// Group sibling layers into one pass-through group in a single undoable
    /// transaction. The layer IDs are stable identities; their input order is
    /// ignored in favor of the document's existing sibling order.
    pub fn group_layers(&mut self, members: Vec<LayerId>) -> Result<LayerId, EngineError> {
        self.flush_input()?;
        let group = {
            let state = lock_recover(&self.state);
            next_layer_id(&state.layers)?
        };
        self.dispatch(EditorCommand::GroupLayers { group, members })?;
        Ok(group)
    }

    /// Validate a selected sibling group without changing content, revision,
    /// or history. The group command repeats its checks when committed.
    pub fn preflight_group_layers(
        &self,
        members: &[LayerId],
    ) -> Result<Option<String>, EngineError> {
        self.flush_input()?;
        let state = lock_recover(&self.state);
        let comic_owned_ids = comic_owned_layer_ids(state.comic_json.as_deref())?;
        Ok(group_layers_reason(&state, &comic_owned_ids, members))
    }

    /// Ungroup an ordinary pass-through group when doing so preserves its
    /// current compositing. The operation is atomic and undoable.
    pub fn ungroup_layer(&mut self, group: LayerId) -> Result<u64, EngineError> {
        self.flush_input()?;
        self.dispatch(EditorCommand::UngroupLayer { group })
    }

    /// Materialize the stable layer tree owned by one comic panel. The
    /// operation is atomic and idempotent so v1-to-v2 migration can safely
    /// retry it after an interrupted checkpoint.
    #[allow(clippy::too_many_arguments)]
    pub fn create_panel_layer_tree(
        &mut self,
        panel: LayerId,
        panel_group: LayerId,
        mask: LayerId,
        sketch: LayerId,
        ink: LayerId,
        color: LayerId,
        tone: LayerId,
        effects: LayerId,
    ) -> Result<u64, EngineError> {
        self.dispatch(EditorCommand::CreatePanelLayerTree {
            panel,
            panel_group,
            mask,
            sketch,
            ink,
            color,
            tone,
            effects,
        })
    }

    /// Replace a generated panel mask with bounded document-space polygon
    /// geometry. The mask is persisted as ordinary raster pixels, so undo,
    /// save, export, and replay all observe the same CPU-authored stencil.
    pub fn set_panel_mask_geometry(
        &mut self,
        mask: LayerId,
        points: Vec<(f32, f32)>,
    ) -> Result<u64, EngineError> {
        self.dispatch(EditorCommand::SetPanelMaskGeometry { mask, points })
    }

    /// Replace one raster layer with the applied panel frame outlines.
    pub fn set_panel_frames(
        &mut self,
        layer: LayerId,
        frames: Vec<Vec<(f32, f32)>>,
        border_px: f32,
    ) -> Result<u64, EngineError> {
        self.dispatch(EditorCommand::SetPanelFrames {
            layer,
            frames,
            border_px,
        })
    }

    /// Clear raster or vector paint from one layer as one undoable command.
    pub fn clear_layer_content(&mut self, layer: LayerId) -> Result<u64, EngineError> {
        self.dispatch(EditorCommand::ClearLayer { layer })
    }

    /// Merge a standalone raster source into a raster target as one undoable
    /// command. The explicit IDs are stable across UI reorder operations.
    pub fn merge_layers(&mut self, target: LayerId, source: LayerId) -> Result<u64, EngineError> {
        self.dispatch(EditorCommand::MergeLayers { target, source })
    }

    /// Validate an exact raster merge without changing document content,
    /// history, or revision. The merge command repeats this validation when
    /// committed so a stale preview cannot bypass engine invariants.
    pub fn preflight_merge_layers(
        &self,
        target: LayerId,
        source: LayerId,
    ) -> Result<(), EngineError> {
        self.flush_input()?;
        let state = lock_recover(&self.state);
        prepare_merge_raster_layers(&state, target, source).map(|_| ())
    }

    /// Merge contiguous selected sibling rasters into the lowest layer in one
    /// undoable edit, retaining that layer's stable ID and name.
    pub fn merge_layers_bulk(&mut self, layers: Vec<LayerId>) -> Result<LayerId, EngineError> {
        self.flush_input()?;
        if !(2..=4_096).contains(&layers.len())
            || layers.iter().copied().collect::<HashSet<_>>().len() != layers.len()
        {
            return Err(EngineError::InvalidCommand(
                "bulk merge requires at least two distinct layers".into(),
            ));
        }
        let state = lock_recover(&self.state);
        let mut ordered = layers;
        ordered.sort_by_key(|id| {
            state
                .layers
                .get(id)
                .map_or((u32::MAX, *id), |layer| (layer.layer.order, *id))
        });
        let parent = state
            .layers
            .get(&ordered[0])
            .ok_or(EngineError::InvalidLayer)?
            .layer
            .parent;
        if ordered.iter().any(|id| {
            state
                .layers
                .get(id)
                .is_none_or(|layer| layer.layer.parent != parent)
        }) {
            return Err(EngineError::InvalidCommand(
                "bulk merge requires sibling layers".into(),
            ));
        }
        let target = ordered[0];
        drop(state);
        self.dispatch(EditorCommand::MergeLayersBulk { layers: ordered })?;
        Ok(target)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn transform_vector_stroke(
        &mut self,
        layer: LayerId,
        stroke: ink_model::StrokeId,
        a: f32,
        b: f32,
        c: f32,
        d: f32,
        tx: f32,
        ty: f32,
    ) -> Result<u64, EngineError> {
        self.dispatch(EditorCommand::TransformVectorStroke {
            layer,
            stroke,
            a,
            b,
            c,
            d,
            tx,
            ty,
        })
    }

    pub fn simplify_vector_stroke(
        &mut self,
        layer: LayerId,
        stroke: ink_model::StrokeId,
        tolerance: f32,
    ) -> Result<u64, EngineError> {
        self.dispatch(EditorCommand::SimplifyVectorStroke {
            layer,
            stroke,
            tolerance,
        })
    }

    pub fn connect_vector_strokes(
        &mut self,
        layer: LayerId,
        first: ink_model::StrokeId,
        second: ink_model::StrokeId,
        tolerance: f32,
    ) -> Result<u64, EngineError> {
        self.dispatch(EditorCommand::ConnectVectorStrokes {
            layer,
            first,
            second,
            tolerance,
        })
    }

    pub fn erase_vector_segment(
        &mut self,
        layer: LayerId,
        stroke: ink_model::StrokeId,
        center_x: f32,
        center_y: f32,
        radius: f32,
    ) -> Result<u64, EngineError> {
        self.dispatch(EditorCommand::EraseVectorSegment {
            layer,
            stroke,
            center_x,
            center_y,
            radius,
        })
    }

    /// Move one pressure-aware vector centerline control point. The mutation
    /// is journaled and participates in the ordinary undo/redo snapshots.
    #[allow(clippy::too_many_arguments)]
    pub fn set_vector_point(
        &mut self,
        layer: LayerId,
        stroke: ink_model::StrokeId,
        index: u32,
        x: f32,
        y: f32,
        pressure: f32,
        tilt: f32,
    ) -> Result<u64, EngineError> {
        self.dispatch(EditorCommand::SetVectorPoint {
            layer,
            stroke,
            index,
            x,
            y,
            pressure,
            tilt,
        })
    }

    fn replace_selection(&mut self, mask: SelectionMask) -> Result<u64, EngineError> {
        self.flush_input()?;
        let mut state = lock_recover(&self.state);
        if state.active_stroke.is_some() {
            return Err(EngineError::InvalidCommand(
                "finish or cancel the active stroke before changing selection".into(),
            ));
        }
        state.selection = Some(mask);
        let revision = advance_revision(&mut state)?;
        state.events.push(EngineEvent::DocumentChanged { revision });
        Ok(revision)
    }

    fn mask_from_layer(
        &self,
        layer_id: LayerId,
        predicate: impl Fn(ink_model::Rgba8) -> bool,
    ) -> Result<SelectionMask, EngineError> {
        let state = lock_recover(&self.state);
        let layer = state
            .layers
            .get(&layer_id)
            .ok_or(EngineError::InvalidLayer)?;
        let mut mask = SelectionMask::new(self.spec.width_px, self.spec.height_px)
            .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
        for (coordinate, bytes) in layer.tiles.tiles() {
            let tile = Tile::from_bytes(bytes)
                .map_err(|_| EngineError::InvalidCommand("invalid layer tile".into()))?;
            for local_y in 0..TILE_SIZE {
                let y = i64::from(coordinate.y) * i64::from(TILE_SIZE) + i64::from(local_y);
                if y < 0 || y >= i64::from(self.spec.height_px) {
                    continue;
                }
                for local_x in 0..TILE_SIZE {
                    let x = i64::from(coordinate.x) * i64::from(TILE_SIZE) + i64::from(local_x);
                    if x < 0 || x >= i64::from(self.spec.width_px) {
                        continue;
                    }
                    if predicate(tile.pixel_rgba(local_x, local_y)) {
                        mask.set(x as u32, y as u32, u8::MAX);
                    }
                }
            }
        }
        Ok(mask)
    }

    /// Create a new document with one raster layer.
    pub fn new(id: DocumentId, spec: DocumentSpec) -> Result<Self, EngineError> {
        let spec = spec.validate()?;
        let layer_id = LayerId::from_u128(1);
        let layer = Layer::new(layer_id, LayerKind::Raster, "Ink");
        let mut layers = BTreeMap::new();
        layers.insert(
            layer_id,
            LayerState {
                layer,
                tiles: TileStore::default(),
                vectors: Vec::new(),
            },
        );
        Self::from_parts(
            id,
            spec,
            EngineState {
                width_px: spec.width_px,
                height_px: spec.height_px,
                revision: 0,
                layers,
                history: History::new(128),
                undo_states: Vec::new(),
                redo_states: Vec::new(),
                history_was_trimmed: false,
                journal: Vec::new(),
                active_stroke: None,
                time_lapse: TimeLapseRecording::new(),
                brush_overrides: BTreeMap::new(),
                active_brush_color: None,
                brush_undo: None,
                brush_redo: None,
                resources: BTreeMap::new(),
                resource_cache: ResourceLru::new(),
                selection: None,
                solo_layer: None,
                layer_panel_state: LayerPanelState::default(),
                brush_drafts: BTreeMap::new(),
                next_brush_draft: 1,
                opacity_edit: None,
                next_opacity_edit: 1,
                live_dabs: Arc::new(Mutex::new(
                    ink_live_render::LiveDabQueue::new(LIVE_DAB_QUEUE_CAPACITY).map_err(|_| {
                        EngineError::WorkerUnavailable("live dab queue unavailable".into())
                    })?,
                )),
                live_dab_overflow_count: Arc::new(AtomicU64::new(0)),
                events: Vec::new(),
                worker_error: None,
                comic_json: None,
            },
        )
    }

    /// Construct a document from a bounded flattened RGBA image import.
    /// Imported pixels become the initial raster layer and no external path is
    /// retained in the document.
    pub fn from_flattened_rgba(
        id: DocumentId,
        width: u32,
        height: u32,
        pixels: &[u8],
    ) -> Result<Self, EngineError> {
        let expected = usize::try_from(width)
            .ok()
            .and_then(|w| usize::try_from(height).ok().and_then(|h| w.checked_mul(h)))
            .and_then(|count| count.checked_mul(4))
            .ok_or_else(|| EngineError::InvalidCommand("PSD pixel dimensions overflow".into()))?;
        if pixels.len() != expected {
            return Err(EngineError::InvalidCommand(
                "PSD pixel payload length does not match dimensions".into(),
            ));
        }
        let spec = DocumentSpec {
            width_px: width,
            height_px: height,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let document = Self::new(id, spec)?;
        {
            let mut state = lock_recover(&document.state);
            let layer = state
                .layers
                .values_mut()
                .next()
                .ok_or(EngineError::InvalidLayer)?;
            for (index, pixel) in pixels.as_chunks::<4>().0.iter().enumerate() {
                let x = u32::try_from(index % usize::try_from(width).unwrap_or(1)).unwrap_or(0);
                let y = u32::try_from(index / usize::try_from(width).unwrap_or(1)).unwrap_or(0);
                layer.tiles.set_pixel(
                    x,
                    y,
                    Rgba8 {
                        r: pixel[0],
                        g: pixel[1],
                        b: pixel[2],
                        a: pixel[3],
                    },
                );
            }
        }
        Ok(document)
    }

    /// Reconstruct a document from a validated native snapshot.
    #[allow(clippy::too_many_lines)]
    pub fn from_snapshot(snapshot: ProjectSnapshot) -> Result<Self, EngineError> {
        let ProjectSnapshot {
            id,
            spec,
            revision,
            layers,
            tiles,
            vectors,
            journal,
            history,
            brushes,
            resources,
            layer_panel_state,
            comic,
        } = snapshot;
        let history_sidecar_truncated = history.truncated_on_load;
        let journal_commands = decode_journal(&journal).map_err(|error| {
            EngineError::InvalidCommand(format!("invalid command history: {error}"))
        })?;
        let mut command_history = History::new(128);
        for command in journal_commands {
            match command {
                EditorCommand::Undo => {
                    command_history.undo();
                }
                EditorCommand::Redo => {
                    command_history.redo();
                }
                EditorCommand::CancelStroke { .. } => {
                    command_history.discard_last();
                }
                EditorCommand::EndStroke { .. } => command_history.clear_redo(),
                command @ EditorCommand::BeginStroke { .. } => {
                    command_history.push_preserving_redo(Transaction {
                        label: history_label(&command),
                        command,
                    });
                }
                command => command_history.push(Transaction {
                    label: history_label(&command),
                    command,
                }),
            }
        }
        let spec = spec.validate()?;
        if let Some(bytes) = &comic {
            ink_comic::ComicProject::from_json(bytes).map_err(|error| {
                EngineError::InvalidCommand(format!("invalid persisted comic structure: {error}"))
            })?;
        }
        validate_layer_panel_state(&layer_panel_state, &layers)?;
        let layers = stored_to_map(
            StoredState {
                layers,
                tiles,
                vectors,
            },
            spec,
        )?;
        let mut undo_states = history
            .undo
            .into_iter()
            .map(|state| stored_to_map(state, spec))
            .collect::<Result<Vec<_>, _>>()?;
        let mut redo_states = history
            .redo
            .into_iter()
            .map(|state| stored_to_map(state, spec))
            .collect::<Result<Vec<_>, _>>()?;
        trim_history_snapshots(&mut undo_states);
        trim_history_snapshots(&mut redo_states);
        let history_was_trimmed = history_sidecar_truncated
            || command_history.undo_transactions().len() != undo_states.len()
            || command_history.redo_transactions().count() != redo_states.len();
        command_history.retain_snapshot_window(undo_states.len(), redo_states.len());
        let mut brush_overrides = BTreeMap::new();
        for payload in brushes {
            let preset: BrushPresetV2 = serde_json::from_slice(&payload).map_err(|error| {
                EngineError::InvalidCommand(format!("invalid persisted brush preset: {error}"))
            })?;
            preset
                .validate()
                .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
            if brush_overrides.insert(preset.id, preset).is_some() {
                return Err(EngineError::InvalidCommand(
                    "persisted brush library contains a duplicate ID".into(),
                ));
            }
        }
        let mut resource_map = BTreeMap::new();
        for resource in resources {
            if resource.bytes.len() > MAX_DOCUMENT_RESOURCE_BYTES
                || resource_total_bytes(&resource_map).saturating_add(resource.bytes.len())
                    > MAX_DOCUMENT_RESOURCE_BYTES
            {
                return Err(EngineError::InvalidCommand(
                    "persisted brush resources exceed the document memory limit".into(),
                ));
            }
            if resource_map
                .insert(
                    resource.hash,
                    BrushResource {
                        kind: resource.kind,
                        width: resource.width,
                        height: resource.height,
                        rgba8: resource.bytes,
                    },
                )
                .is_some()
            {
                return Err(EngineError::InvalidCommand(
                    "persisted brush resources contain a duplicate hash".into(),
                ));
            }
        }
        Self::from_parts(
            id,
            spec,
            EngineState {
                width_px: spec.width_px,
                height_px: spec.height_px,
                revision,
                layers,
                history: command_history,
                undo_states,
                redo_states,
                history_was_trimmed,
                journal,
                active_stroke: None,
                time_lapse: TimeLapseRecording::new(),
                brush_overrides,
                active_brush_color: None,
                brush_undo: None,
                brush_redo: None,
                resources: resource_map,
                resource_cache: ResourceLru::new(),
                selection: None,
                solo_layer: None,
                layer_panel_state,
                brush_drafts: BTreeMap::new(),
                next_brush_draft: 1,
                opacity_edit: None,
                next_opacity_edit: 1,
                live_dabs: Arc::new(Mutex::new(
                    ink_live_render::LiveDabQueue::new(LIVE_DAB_QUEUE_CAPACITY).map_err(|_| {
                        EngineError::WorkerUnavailable("live dab queue unavailable".into())
                    })?,
                )),
                live_dab_overflow_count: Arc::new(AtomicU64::new(0)),
                events: Vec::new(),
                worker_error: None,
                comic_json: comic,
            },
        )
    }

    fn from_parts(
        id: DocumentId,
        spec: DocumentSpec,
        state: EngineState,
    ) -> Result<Self, EngineError> {
        let live_dabs = Arc::clone(&state.live_dabs);
        let live_dab_overflow_count = Arc::clone(&state.live_dab_overflow_count);
        let state = Arc::new(Mutex::new(state));
        let worker = RenderWorker::new(Arc::clone(&state))?;
        Ok(Self {
            id,
            spec,
            state,
            live_dabs,
            live_dab_overflow_count,
            worker,
        })
    }

    /// Dispatch a command and return the new document revision.
    pub fn dispatch(&mut self, command: EditorCommand) -> Result<u64, EngineError> {
        let input_error = self.flush_input().err();
        if let Some(error) = input_error
            && !matches!(command, EditorCommand::CancelStroke { .. })
        {
            return Err(error);
        }
        let mut state = lock_recover(&self.state);
        if state.opacity_edit.is_some() {
            commands::commit_pending_opacity_edit(&mut state, None)?;
        }
        let revision = dispatch_state(&mut state, command)?;
        let valid_layers = state.layers.keys().copied().collect::<HashSet<_>>();
        let valid_groups = state
            .layers
            .values()
            .filter(|layer| layer.layer.kind == LayerKind::Group)
            .map(|layer| layer.layer.id)
            .collect::<HashSet<_>>();
        if state
            .layer_panel_state
            .primary_layer
            .is_some_and(|layer_id| !valid_layers.contains(&layer_id))
        {
            state.layer_panel_state.primary_layer = None;
        }
        state
            .layer_panel_state
            .collapsed_groups
            .retain(|group| valid_groups.contains(group));
        if state
            .solo_layer
            .is_some_and(|layer_id| !state.layers.contains_key(&layer_id))
        {
            // Structural edits can remove a solo target (or turn a group into
            // ordinary children). Clear the session override with the same
            // command revision so the next composite and panel projection
            // both return to the saved visibility state.
            state.solo_layer = None;
        }
        Ok(revision)
    }
}

fn flush_deferred_dual_dabs(
    state: &mut EngineState,
    stroke: StrokeId,
) -> Result<Vec<TileCoord>, EngineError> {
    let (layer_id, sequence, preset, pending) = {
        let active = state
            .active_stroke
            .as_mut()
            .ok_or_else(|| EngineError::InvalidCommand("stroke is not active".into()))?;
        if active.stroke != stroke {
            return Err(EngineError::InvalidCommand("stroke is not active".into()));
        }
        let Some(compiled) = active.compiled_brush.as_ref() else {
            return Ok(Vec::new());
        };
        let pending = match compiled.finish_incremental(&mut active.compiled_brush_state) {
            Ok(pending) => pending,
            Err(ink_brush::BrushValidationError::WorkLimitExceeded) => {
                active.work_limit_reached = true;
                return Ok(Vec::new());
            }
            Err(error) => return Err(EngineError::InvalidCommand(error.to_string())),
        };
        (
            active.layer,
            active
                .last_confirmed_sample
                .map_or(0, |sample| sample.sequence),
            active.brush,
            pending,
        )
    };
    if pending.is_empty() {
        return Ok(Vec::new());
    }

    let all_dabs = pending.iter().map(|(dab, _)| *dab).collect::<Vec<_>>();
    let resources = state
        .resource_cache
        .resolve_for_dabs(&all_dabs, &state.resources);
    let selection = state.selection.clone();
    let width_px = state.width_px;
    let height_px = state.height_px;
    let mut dirty = Vec::new();
    {
        let layer_state = state
            .layers
            .get_mut(&layer_id)
            .ok_or(EngineError::InvalidLayer)?;
        let alpha_lock = layer_state.layer.alpha_lock;
        let is_mask = layer_state.layer.kind == LayerKind::Mask;
        let mut start = 0;
        while start < pending.len() {
            let eraser = pending[start].1;
            let mut end = start + 1;
            while end < pending.len() && pending[end].1 == eraser {
                end += 1;
            }
            let dabs = pending[start..end]
                .iter()
                .map(|(dab, _)| *dab)
                .collect::<Vec<_>>();
            if is_mask {
                dirty.extend(render_mask_dabs(
                    &mut layer_state.tiles,
                    MaskDabInput {
                        preset,
                        compiled_dabs: Some(&dabs),
                        legacy_dabs: &[],
                        resources: &resources,
                        selection: selection.as_ref(),
                        eraser,
                        width_px,
                        height_px,
                    },
                ));
            } else {
                dirty.extend(render_brush_dabs(
                    &mut layer_state.tiles,
                    &dabs,
                    &resources,
                    selection.as_ref(),
                    eraser,
                    false,
                    alpha_lock,
                    width_px,
                    height_px,
                ));
            }
            start = end;
        }
    }
    dirty.sort_unstable_by_key(|coordinate| (coordinate.y, coordinate.x));
    dirty.dedup();
    publish_deferred_dual_dabs(state, stroke, sequence, &all_dabs, dirty.len());
    Ok(dirty)
}

fn publish_deferred_dual_dabs(
    state: &mut EngineState,
    stroke: StrokeId,
    sequence: u32,
    dabs: &[BrushDab],
    dirty_tile_count: usize,
) {
    for (dab_index, dab) in dabs.iter().copied().enumerate() {
        queue_live_dab(
            state,
            ink_live_render::LiveDab {
                stroke_id: stroke.0,
                sequence,
                dab_index: u32::try_from(dab_index).unwrap_or(u32::MAX),
                x: dab.x,
                y: dab.y,
                radius: f32::midpoint(dab.radius_x.abs(), dab.radius_y.abs()),
                opacity: (dab.opacity * dab.flow).clamp(0.0, 1.0),
                rotation: dab.angle,
                color: [dab.color.r, dab.color.g, dab.color.b, dab.color.a],
                phase: ink_live_render::DabPhase::Confirmed,
            },
        );
    }
    if let Some(active) = state.active_stroke.as_mut() {
        for dab in dabs {
            if let Some((previous_x, previous_y)) = active.compiled_dab_last_position {
                let step = (dab.x - previous_x).hypot(dab.y - previous_y);
                active.compiled_dab_path_length += f64::from(step);
                active.compiled_dab_max_step = active.compiled_dab_max_step.max(step);
            }
            active.compiled_dab_last_position = Some((dab.x, dab.y));
        }
        active.compiled_rendered_dabs = active.compiled_rendered_dabs.saturating_add(dabs.len());
        active.compiled_cpu_tile_updates = active
            .compiled_cpu_tile_updates
            .saturating_add(dirty_tile_count);
        active.cpu_tile_updates = active.cpu_tile_updates.saturating_add(dirty_tile_count);
    }
}

mod commands;
use commands::dispatch_state;

fn advance_revision(state: &mut EngineState) -> Result<u64, EngineError> {
    state.revision = state
        .revision
        .checked_add(1)
        .ok_or_else(|| EngineError::InvalidCommand("document revision is exhausted".into()))?;
    Ok(state.revision)
}

fn history_kind(command: &EditorCommand) -> &'static str {
    match command {
        EditorCommand::BeginStroke { .. }
        | EditorCommand::AddVectorStroke { .. }
        | EditorCommand::EndStroke { .. }
        | EditorCommand::CancelStroke { .. } => "stroke",
        EditorCommand::AddLayer { .. }
        | EditorCommand::DeleteLayer { .. }
        | EditorCommand::DeleteLayers { .. }
        | EditorCommand::DuplicateLayer { .. }
        | EditorCommand::DuplicateLayerWithMasks { .. }
        | EditorCommand::DuplicateLayerSubtree { .. }
        | EditorCommand::DuplicateLayers { .. }
        | EditorCommand::GroupLayers { .. }
        | EditorCommand::UngroupLayer { .. }
        | EditorCommand::CreatePanelLayerTree { .. }
        | EditorCommand::ClearLayer { .. } => "layer",
        EditorCommand::MergeLayers { .. } | EditorCommand::MergeLayersBulk { .. } => "merge",
        EditorCommand::MoveLayer { .. } | EditorCommand::ReorderLayers { .. } => "reorder",
        EditorCommand::SetLayerName { .. } => "rename",
        EditorCommand::SetLayerAdjustment { .. } => "adjustment",
        EditorCommand::SetLayerVisibility { .. } | EditorCommand::SetLayersVisibility { .. } => {
            "visibility"
        }
        EditorCommand::SetMaskEnabled { .. }
        | EditorCommand::SetMaskInverted { .. }
        | EditorCommand::ApplyLayerMask { .. } => "mask",
        EditorCommand::SetLayerOpacity { .. } => "opacity",
        EditorCommand::SetLayerBlendMode { .. } => "blend_mode",
        EditorCommand::SetLayerGroupMode { .. } => "group_mode",
        EditorCommand::SetLayersLocked { .. }
        | EditorCommand::SetLayersLabel { .. }
        | EditorCommand::SetLayerAlphaLock { .. }
        | EditorCommand::SetLayerLocked { .. }
        | EditorCommand::SetLayerClipping { .. }
        | EditorCommand::SetLayerReference { .. }
        | EditorCommand::SetLayerLabel { .. } => "layer_property",
        EditorCommand::SetPanelMaskGeometry { .. } | EditorCommand::SetPanelFrames { .. } => {
            "panel"
        }
        EditorCommand::FillRegion { .. } | EditorCommand::GradientFill { .. } => "fill",
        EditorCommand::TransformLayer { .. }
        | EditorCommand::PerspectiveLayer { .. }
        | EditorCommand::MeshLayer { .. }
        | EditorCommand::LiquifyLayer { .. }
        | EditorCommand::TransformVectorStroke { .. }
        | EditorCommand::SimplifyVectorStroke { .. }
        | EditorCommand::ConnectVectorStrokes { .. }
        | EditorCommand::EraseVectorSegment { .. }
        | EditorCommand::SetVectorPoint { .. } => "transform",
        EditorCommand::Undo | EditorCommand::Redo => "history",
    }
}

fn history_label(command: &EditorCommand) -> String {
    match command {
        EditorCommand::BeginStroke { .. } => "Brush stroke".into(),
        EditorCommand::AddLayer { kind, .. } => format!("Add {kind:?} layer"),
        EditorCommand::DeleteLayer { .. } => "Delete layer".into(),
        EditorCommand::DeleteLayers { .. } => "Delete selected layers".into(),
        EditorCommand::SetLayersVisibility { .. } => "Change selected visibility".into(),
        EditorCommand::SetMaskEnabled { .. } => "Toggle mask".into(),
        EditorCommand::SetMaskInverted { .. } => "Invert mask".into(),
        EditorCommand::ApplyLayerMask { .. } => "Apply mask".into(),
        EditorCommand::SetLayersLocked { .. } => "Change selected layer locks".into(),
        EditorCommand::SetLayersLabel { .. } => "Label selected layers".into(),
        EditorCommand::DuplicateLayer { .. } => "Duplicate layer".into(),
        EditorCommand::DuplicateLayerWithMasks { .. } => "Duplicate layer and masks".into(),
        EditorCommand::DuplicateLayerSubtree { .. } => "Duplicate group".into(),
        EditorCommand::DuplicateLayers { .. } => "Duplicate selected layers".into(),
        EditorCommand::GroupLayers { .. } => "Group layers".into(),
        EditorCommand::UngroupLayer { .. } => "Ungroup layers".into(),
        EditorCommand::MergeLayers { .. } => "Merge layers".into(),
        EditorCommand::MergeLayersBulk { .. } => "Merge selected layers".into(),
        EditorCommand::MoveLayer { .. } => "Reorder layer".into(),
        EditorCommand::ReorderLayers { .. } => "Reorder selected layers".into(),
        EditorCommand::CreatePanelLayerTree { .. } => "Create panel layers".into(),
        EditorCommand::SetPanelMaskGeometry { .. } => "Edit panel geometry".into(),
        EditorCommand::SetPanelFrames { .. } => "Apply panel frames".into(),
        EditorCommand::ClearLayer { .. } => "Clear layer".into(),
        EditorCommand::SetLayerOpacity { .. } => "Change layer opacity".into(),
        EditorCommand::SetLayerVisibility { .. } => "Change layer visibility".into(),
        EditorCommand::SetLayerBlendMode { .. } => "Change blend mode".into(),
        EditorCommand::SetLayerGroupMode { .. } => "Change group compositing".into(),
        EditorCommand::SetLayerAlphaLock { .. } => "Change alpha lock".into(),
        EditorCommand::SetLayerLocked { .. } => "Change layer lock".into(),
        EditorCommand::SetLayerClipping { .. } => "Change clipping".into(),
        EditorCommand::SetLayerReference { .. } => "Change reference layer".into(),
        EditorCommand::SetLayerLabel { .. } => "Change layer label".into(),
        EditorCommand::SetLayerName { .. } => "Rename layer".into(),
        EditorCommand::SetLayerAdjustment { .. } => "Adjust colors".into(),
        EditorCommand::FillRegion { .. } => "Bucket fill".into(),
        EditorCommand::GradientFill { .. } => "Gradient fill".into(),
        EditorCommand::TransformLayer { .. } => "Transform layer".into(),
        EditorCommand::PerspectiveLayer { .. } => "Perspective transform".into(),
        EditorCommand::MeshLayer { .. } => "Mesh transform".into(),
        EditorCommand::LiquifyLayer { .. } => "Liquify".into(),
        EditorCommand::AddVectorStroke { .. } => "Vector stroke".into(),
        EditorCommand::TransformVectorStroke { .. } => "Transform vector stroke".into(),
        EditorCommand::SimplifyVectorStroke { .. } => "Simplify vector stroke".into(),
        EditorCommand::ConnectVectorStrokes { .. } => "Connect vector strokes".into(),
        EditorCommand::EraseVectorSegment { .. } => "Erase vector segment".into(),
        EditorCommand::SetVectorPoint { .. } => "Edit vector point".into(),
        EditorCommand::EndStroke { .. } => "Finish stroke".into(),
        EditorCommand::CancelStroke { .. } => "Cancel stroke".into(),
        EditorCommand::Undo => "Undo".into(),
        EditorCommand::Redo => "Redo".into(),
    }
}

/// Decode the bounded, normalized curve representation sent by the editor.
/// An empty vector preserves the legacy midpoint-only editor behavior; a
/// non-empty vector must contain two to sixteen ordered `(x, y)` pairs.
fn decode_editor_curve(
    values: &[f32],
    fallback_midpoint: f32,
) -> Result<Vec<CurvePoint>, EngineError> {
    if values.is_empty() {
        return Ok(vec![
            CurvePoint { x: 0.0, y: 0.0 },
            CurvePoint {
                x: 0.5,
                y: fallback_midpoint,
            },
            CurvePoint { x: 1.0, y: 1.0 },
        ]);
    }
    if !values.len().is_multiple_of(2) || !(4..=32).contains(&values.len()) {
        return Err(EngineError::InvalidCommand(
            "pressure curve must contain two to sixteen point pairs".into(),
        ));
    }
    let mut points = Vec::with_capacity(values.len() / 2);
    let mut previous_x = -1.0_f32;
    for pair in values.as_chunks::<2>().0 {
        let x = pair[0];
        let y = pair[1];
        if !x.is_finite()
            || !y.is_finite()
            || !(0.0..=1.0).contains(&x)
            || !(0.0..=1.0).contains(&y)
        {
            return Err(EngineError::InvalidCommand(
                "pressure curve points must be finite and normalized".into(),
            ));
        }
        if x <= previous_x {
            return Err(EngineError::InvalidCommand(
                "pressure curve x coordinates must be strictly increasing".into(),
            ));
        }
        previous_x = x;
        points.push(CurvePoint { x, y });
    }
    Ok(points)
}

fn validate_brush_draft_settings(settings: &BrushDraftSettings) -> Result<(), EngineError> {
    let values = [
        settings.diameter_px,
        settings.opacity,
        settings.spacing,
        settings.smoothing,
        settings.pressure_size,
        settings.pressure_opacity,
        settings.pressure_curve,
        settings.hardness,
        settings.texture_scale,
        settings.scatter,
        settings.rotation_jitter,
        settings.smudge,
        settings.wetness,
    ];
    if values.iter().any(|value| !value.is_finite())
        || !(0.25..=4096.0).contains(&settings.diameter_px)
        || !(0.0..=1.0).contains(&settings.opacity)
        || !(0.001..=1.0).contains(&settings.spacing)
        || !(0.0..=1.0).contains(&settings.smoothing)
        || !(0.0..=1.0).contains(&settings.pressure_size)
        || !(0.0..=1.0).contains(&settings.pressure_opacity)
        || !(0.0..=1.0).contains(&settings.pressure_curve)
        || !(0.0..=1.0).contains(&settings.hardness)
        || !(0.01..=64.0).contains(&settings.texture_scale)
        || !(0.0..=1.0).contains(&settings.scatter)
        || !(0.0..=1.0).contains(&settings.rotation_jitter)
        || !(0.0..=1.0).contains(&settings.smudge)
        || !(0.0..=1.0).contains(&settings.wetness)
    {
        return Err(EngineError::InvalidCommand(
            "brush settings are outside the supported finite ranges".into(),
        ));
    }
    let _ = decode_editor_curve(&settings.pressure_curve_points, settings.pressure_curve)?;
    Ok(())
}

fn brush_summary_projection(preset: &BrushPresetV2) -> BrushSummaryProjection {
    let pressure_curve_binding = preset
        .dynamics
        .iter()
        .find(|binding| {
            binding.sensor == SensorId::Pressure && binding.target == ParameterId::Diameter
        })
        .or_else(|| {
            preset
                .dynamics
                .iter()
                .find(|binding| binding.sensor == SensorId::Pressure)
        });
    let curve = pressure_curve_binding.map_or_else(
        || vec![0.0, 0.0, 1.0, 1.0],
        |binding| {
            binding
                .curve
                .points
                .iter()
                .flat_map(|point| [point.x, point.y])
                .collect::<Vec<_>>()
        },
    );
    let (diameter_px, hardness, scatter, rotation_jitter) = match &preset.tip {
        TipBehavior::Stamp(tip) => (
            tip.diameter_px,
            tip.hardness,
            // New presets retain the exact editor value. Older v2 presets
            // fall back to the density-derived approximation.
            if tip.editor_scatter > 0.0 {
                tip.editor_scatter
            } else {
                ((1.0 - tip.density) * 2.0).clamp(0.0, 1.0)
            },
            (tip.angle_degrees / 180.0).abs().clamp(0.0, 1.0),
        ),
        TipBehavior::Spray(tip) => (tip.diameter_px, tip.hardness, tip.scatter, 0.0),
        TipBehavior::Ribbon(tip) => (tip.width_px, 1.0, 0.0, 0.0),
        TipBehavior::Bristle(tip) => (tip.diameter_px, tip.stiffness, tip.spread, 0.0),
    };
    let (opacity, color_rgba) = match &preset.paint {
        PaintBehavior::Solid(value) => (value.opacity, pack_rgba(value.color)),
        PaintBehavior::Glaze(value) => (value.opacity, pack_rgba(value.color)),
        PaintBehavior::Marker(value) => (value.opacity, pack_rgba(value.color)),
        PaintBehavior::ColorPickup(value) => (value.opacity, pack_rgba(value.color)),
        PaintBehavior::DigitalWatercolor(value) => (value.wash, pack_rgba(value.color)),
    };
    let (smudge, wetness) = match &preset.paint {
        PaintBehavior::ColorPickup(value) => (value.pickup, value.dilution),
        PaintBehavior::DigitalWatercolor(value) => (value.pickup, value.dilution),
        _ => (0.0, 0.0),
    };
    let pressure_size = preset
        .dynamics
        .iter()
        .find(|binding| {
            binding.sensor == SensorId::Pressure && binding.target == ParameterId::Diameter
        })
        .map_or(0.0, |binding| binding.amount.clamp(0.0, 1.0));
    let pressure_opacity = preset
        .dynamics
        .iter()
        .find(|binding| {
            binding.sensor == SensorId::Pressure && binding.target == ParameterId::Opacity
        })
        .map_or(0.0, |binding| binding.amount.clamp(0.0, 1.0));
    let texture_scale = preset
        .grain
        .as_ref()
        .map_or(1.0, |grain| grain.scale.clamp(0.01, 64.0));
    let tip_hash = match &preset.tip {
        TipBehavior::Stamp(tip) => tip.resource_hash.map(|hash| hash.to_vec()),
        _ => None,
    };
    let grain_hash = preset
        .grain
        .as_ref()
        .map(|grain| grain.resource_hash.to_vec());
    BrushSummaryProjection {
        id: preset.id,
        is_builtin: builtin_library().iter().any(|item| item.id == preset.id),
        name: preset.metadata.name.clone(),
        tags: preset.metadata.tags.clone(),
        diameter_px,
        opacity,
        spacing: preset.stroke.spacing,
        smoothing: preset.stroke.smoothing,
        pressure_size,
        pressure_opacity,
        hardness,
        texture_scale,
        scatter,
        rotation_jitter,
        smudge,
        wetness,
        color_rgba,
        pressure_curve_points: curve,
        tip_resource_hash: tip_hash,
        grain_resource_hash: grain_hash,
    }
}

fn pack_rgba(color: Rgba8) -> u32 {
    (u32::from(color.r) << 24)
        | (u32::from(color.g) << 16)
        | (u32::from(color.b) << 8)
        | u32::from(color.a)
}

fn next_available_brush_id(state: &EngineState) -> Result<BrushId, EngineError> {
    let max_builtin = builtin_library()
        .into_iter()
        .map(|preset| preset.id.0)
        .max()
        .unwrap_or(0);
    let max_override = state
        .brush_overrides
        .keys()
        .map(|brush_id| brush_id.0)
        .max()
        .unwrap_or(0);
    let id = max_builtin
        .max(max_override)
        .checked_add(1)
        .ok_or_else(|| EngineError::InvalidCommand("brush ID space is exhausted".into()))?;
    Ok(BrushId::from_u128(id))
}

fn resource_hashes_for_preset(preset: &BrushPresetV2) -> Vec<[u8; 32]> {
    let mut hashes = Vec::new();
    if let TipBehavior::Stamp(tip) = &preset.tip
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

fn hex_hash(hash: &[u8; 32]) -> String {
    use std::fmt::Write;
    let mut value = String::with_capacity(hash.len() * 2);
    for byte in hash {
        write!(&mut value, "{byte:02x}").expect("writing to String cannot fail");
    }
    value
}

mod brushes;

mod rendering;
use rendering::{
    apply_post_effects, legacy_dab_opacity, legacy_dab_radius, mask_preview_to_alpha,
    rasterize_vector_stroke, rebuild_vector_layer, render_brush_dabs, render_dabs,
};

fn restore_brush_override(
    state: &mut EngineState,
    brush_id: &BrushId,
    preset: Option<BrushPresetV2>,
) {
    match preset {
        Some(preset) => {
            state.brush_overrides.insert(*brush_id, preset);
        }
        None => {
            state.brush_overrides.remove(brush_id);
        }
    }
}

fn queue_live_dab(state: &mut EngineState, dab: ink_live_render::LiveDab) {
    if lock_recover(&state.live_dabs).push(dab).is_err()
        && dab.phase != ink_live_render::DabPhase::Predicted
    {
        // The CPU path has already accepted the source pointer samples. A
        // saturated preview queue must therefore degrade to committed-tile
        // rendering instead of aborting the worker or canceling a stroke.
        state
            .live_dab_overflow_count
            .fetch_add(1, Ordering::Relaxed);
    }
}

mod strokes;
use strokes::consume_packet;
use strokes::{MaskDabInput, render_mask_dabs};
#[cfg(test)]
use strokes::{
    compact_stationary_samples, consume_packet_with_sample_limit, render_compiled_confirmed_bounded,
};

impl Document {
    /// Return events since the previous poll.
    pub fn drain_events(&mut self) -> Result<Vec<EngineEvent>, EngineError> {
        self.flush_input()?;
        Ok(self.drain_events_available()?.0)
    }

    /// Return events that the render worker has produced so far without
    /// waiting for its queued input to finish. Canvas polling uses this path
    /// so a long stroke cannot turn a tile refresh into a full-queue barrier.
    /// The returned revision is captured under the same state lock as the
    /// event batch, keeping the batch internally coherent.
    pub fn drain_events_available(&self) -> Result<(Vec<EngineEvent>, u64), EngineError> {
        let mut state = lock_recover(&self.state);
        if let Some(error) = state.worker_error.take() {
            return Err(EngineError::InvalidCommand(error));
        }
        let revision = state.revision;
        let events = std::mem::take(&mut state.events);
        Ok((events, revision))
    }

    /// Drain completed events without waiting for an in-progress CPU render.
    /// The live canvas polls this on the UI bridge while a long stroke may be
    /// holding the document state lock. Returning `None` lets the caller retry
    /// on its next frame without blocking other calls on the document handle.
    pub fn try_drain_events_available(
        &self,
    ) -> Result<Option<(Vec<EngineEvent>, u64)>, EngineError> {
        let mut state = match self.state.try_lock() {
            Ok(state) => state,
            Err(std::sync::TryLockError::WouldBlock) => return Ok(None),
            Err(std::sync::TryLockError::Poisoned(error)) => error.into_inner(),
        };
        if let Some(error) = state.worker_error.take() {
            return Err(EngineError::InvalidCommand(error));
        }
        let revision = state.revision;
        let events = std::mem::take(&mut state.events);
        Ok(Some((events, revision)))
    }

    /// Drain only stroke acknowledgements, leaving tile and layer events for
    /// the normal tile-update boundary. This allows the UI to observe input
    /// progress without stealing invalidation records from the painter.
    pub fn drain_stroke_acknowledgements(
        &mut self,
    ) -> Result<Vec<StrokeAcknowledgement>, EngineError> {
        self.flush_input()?;
        let mut state = lock_recover(&self.state);
        let mut acknowledgements = Vec::new();
        state.events.retain(|event| {
            if let EngineEvent::StrokeAcknowledged {
                stroke,
                highest_committed_sequence,
                revision,
                dirty_bounds,
                dirty_tiles,
                metrics,
            } = event
            {
                acknowledgements.push(StrokeAcknowledgement {
                    stroke: *stroke,
                    highest_committed_sequence: *highest_committed_sequence,
                    revision: *revision,
                    dirty_bounds: *dirty_bounds,
                    dirty_tiles: dirty_tiles.clone(),
                    metrics: *metrics,
                });
                false
            } else {
                true
            }
        });
        Ok(acknowledgements)
    }
    /// Read a copied tile for Flutter's immutable cache.
    pub fn read_tile(&self, layer: LayerId, coordinate: TileCoord) -> Result<Vec<u8>, EngineError> {
        self.flush_input()?;
        let state = lock_recover(&self.state);
        let layer_state = state.layers.get(&layer).ok_or(EngineError::InvalidLayer)?;
        let mut bytes = layer_state.tiles.read(coordinate).bytes().to_vec();
        if let Some(mask) = mask_sibling(&state.layers, layer_state)
            .or_else(|| ancestor_group_mask(&state.layers, layer_state))
            && mask.layer.mask_enabled
        {
            let mask_tile = mask.tiles.read(coordinate);
            let mask_bytes = mask_tile.bytes();
            for offset in (0..bytes.len()).step_by(4) {
                let alpha = mask_coverage(
                    mask_bytes[offset + 3],
                    mask.layer.mask_stencil,
                    mask.layer.mask_inverted,
                );
                for channel in 0..4 {
                    bytes[offset + channel] =
                        (u32::from(bytes[offset + channel]) * alpha / 255) as u8;
                }
            }
        }
        let is_clipping = state
            .layers
            .get(&layer)
            .is_some_and(|candidate| candidate.layer.clipping);
        if is_clipping {
            // Clip to the nearest preceding visible non-clipping paint layer
            // in stable layer order. The tile remains premultiplied BGRA, so
            // multiplying all channels by the mask alpha is sufficient.
            let ordered = ordered_layer_states(&state.layers);
            let position = ordered
                .iter()
                .position(|candidate| candidate.layer.id == layer)
                .unwrap_or(ordered.len());
            let base = ordered.into_iter().take(position).rev().find(|candidate| {
                candidate.layer.visible
                    && !candidate.layer.clipping
                    && matches!(
                        candidate.layer.kind,
                        LayerKind::Raster | LayerKind::VectorInk
                    )
            });
            if let Some(base) = base {
                let mask = base.tiles.read(coordinate);
                for offset in (0..bytes.len()).step_by(4) {
                    let alpha = u32::from(mask.bytes()[offset + 3]);
                    for channel in 0..4 {
                        bytes[offset + channel] =
                            (u32::from(bytes[offset + channel]) * alpha / 255) as u8;
                    }
                }
            }
        }
        if let Some(active) = state
            .active_stroke
            .as_ref()
            .filter(|active| active.layer == layer)
        {
            let preview = active.preview_tiles.read(coordinate);
            if active.preview_eraser {
                for offset in (0..bytes.len()).step_by(4) {
                    if preview.bytes()[offset + 3] != 0 {
                        bytes[offset..offset + 4].fill(0);
                    }
                }
            } else {
                blend_preview_over(&mut bytes, preview.bytes());
            }
        }
        Ok(bytes)
    }

    /// Report whether a layer owns any sparse raster tiles. This is a bounded
    /// load/migration probe used to avoid replaying identical generated masks
    /// every time a unified project is opened.
    pub fn layer_has_allocated_tiles(&self, layer: LayerId) -> Result<bool, EngineError> {
        self.flush_input()?;
        let state = lock_recover(&self.state);
        let layer = state.layers.get(&layer).ok_or(EngineError::InvalidLayer)?;
        Ok(layer.tiles.allocated_tiles() > 0)
    }

    /// Read one authoritative committed composite tile in premultiplied BGRA
    /// order. This is intentionally separate from layer tiles so Flutter does
    /// not approximate blend modes with its own renderer. The calculation is
    /// bounded to one 256x256 tile and never allocates a canvas-sized buffer.
    pub fn read_composite_tile(&self, coordinate: TileCoord) -> Result<Vec<u8>, EngineError> {
        self.flush_input()?;
        let snapshot = self.capture_composite_tile_snapshot(&[coordinate]);
        snapshot
            .read_tiles(&[coordinate])?
            .into_iter()
            .next()
            .ok_or_else(|| EngineError::InvalidCommand("composite tile is unavailable".into()))
    }

    /// Capture several composite tiles and the document revision under one
    /// state lock. The returned pixels are immutable and all correspond to
    /// the same revision, so callers can publish tile images and stroke
    /// coverage together without racing the render worker between tile reads.
    /// This deliberately does not flush queued input: canvas handoff snapshots
    /// must not wait for unrelated later packets in the render queue.
    pub fn read_composite_tiles_snapshot(
        &self,
        coordinates: &[TileCoord],
    ) -> Result<(u64, Vec<Vec<u8>>), EngineError> {
        let snapshot = self.capture_composite_tile_snapshot(coordinates);
        Ok((snapshot.revision(), snapshot.read_tiles(coordinates)?))
    }

    /// Capture just the requested tile data and presentation metadata under
    /// the document lock. Call `read_tiles` after releasing any outer bridge
    /// handle lock so CPU compositing cannot delay pointer packet submission.
    pub fn capture_composite_tile_snapshot(
        &self,
        coordinates: &[TileCoord],
    ) -> CompositeTileReadSnapshot {
        let state = lock_recover(&self.state);
        let mut layers = state
            .layers
            .iter()
            .map(|(id, layer)| {
                (
                    *id,
                    LayerState {
                        layer: layer.layer.clone(),
                        tiles: layer.tiles.snapshot_tiles(coordinates),
                        // Composite snapshots use rasterized vector tiles;
                        // authored vector geometry is not read here.
                        vectors: Vec::new(),
                    },
                )
            })
            .collect::<BTreeMap<_, _>>();
        if let Some(solo_layer) = state.solo_layer {
            let _ = apply_solo_visibility(&mut layers, solo_layer);
        }
        CompositeTileReadSnapshot {
            revision: state.revision,
            width_px: state.width_px,
            height_px: state.height_px,
            background: self.spec.background,
            layers,
        }
    }

    #[allow(clippy::too_many_lines)]
    fn composite_tile_from_layers(
        width_px: u32,
        height_px: u32,
        background: Rgba8,
        layers: &BTreeMap<LayerId, LayerState>,
        coordinate: TileCoord,
    ) -> Result<Vec<u8>, EngineError> {
        let mut output = Tile::default();
        let ordered_layers = ordered_layer_states(layers);
        // Each nested adjustment scopes itself to the accumulated content of
        // its parent group. Store one alpha plane per group that owns an
        // adjustment, rather than allocating planes for every group.
        let adjustment_scopes = ordered_layers
            .iter()
            .filter_map(|layer| {
                (layer.layer.kind == LayerKind::Adjustment)
                    .then_some(layer.layer.parent)
                    .flatten()
            })
            .collect::<HashSet<_>>()
            .into_iter()
            .enumerate()
            .map(|(index, group)| (group, index))
            .collect::<HashMap<_, _>>();
        let mut scope_coverage = vec![0_u8; adjustment_scopes.len()];
        // Generation tags avoid clearing every group coverage value for each
        // pixel in the tile. Pixel indices are bounded by TILE_SIZE squared.
        let mut scope_generation = vec![0_u32; adjustment_scopes.len()];
        let layer_tiles = ordered_layers
            .into_iter()
            .filter_map(|candidate| {
                let (visible, _) = effective_layer_presentation(layers, candidate.layer.id);
                let is_paint = matches!(
                    candidate.layer.kind,
                    LayerKind::Raster | LayerKind::VectorInk
                );
                let is_adjustment = candidate.layer.kind == LayerKind::Adjustment;
                let is_group = matches!(
                    candidate.layer.kind,
                    LayerKind::Group | LayerKind::PanelGroup
                );
                if !visible || (!is_paint && !is_adjustment && !is_group) {
                    return None;
                }
                let adjustment_scope = candidate
                    .layer
                    .parent
                    .and_then(|parent| adjustment_scopes.get(&parent).copied());
                let mut paint_scopes = Vec::new();
                if is_paint {
                    let mut parent = candidate.layer.parent;
                    let mut visited = HashSet::new();
                    while let Some(group) = parent {
                        if !visited.insert(group) {
                            break;
                        }
                        if let Some(scope) = adjustment_scopes.get(&group) {
                            paint_scopes.push(*scope);
                        }
                        parent = layers.get(&group).and_then(|layer| layer.layer.parent);
                    }
                }
                let mut ancestor_groups = HashSet::new();
                let mut parent = candidate.layer.parent;
                let mut visited = HashSet::new();
                while let Some(id) = parent {
                    if !visited.insert(id) {
                        break;
                    }
                    if layers.get(&id).is_some_and(|layer| {
                        matches!(layer.layer.kind, LayerKind::Group | LayerKind::PanelGroup)
                    }) {
                        ancestor_groups.insert(id);
                    }
                    parent = layers.get(&id).and_then(|layer| layer.layer.parent);
                }
                Some((
                    candidate,
                    candidate.tiles.read(coordinate),
                    if is_paint {
                        mask_sibling(layers, candidate)
                            .or_else(|| ancestor_group_mask(layers, candidate))
                            .map(|mask| {
                                (
                                    mask.tiles.read(coordinate),
                                    mask.layer.mask_stencil,
                                    mask.layer.mask_inverted,
                                )
                            })
                    } else {
                        None
                    },
                    candidate.layer.opacity,
                    adjustment_scope,
                    paint_scopes,
                    ancestor_groups,
                ))
            })
            .collect::<Vec<_>>();
        // Composite pixel buffers are scratch space for the inner pixel loop.
        // Reuse their allocations across the tile instead of allocating three
        // vectors for every one of its 65,536 pixels. Snapshotting many dirty
        // tiles during a long stroke made those tiny per-pixel allocations a
        // substantial part of the CPU handoff latency.
        let mut composites = Vec::with_capacity(layer_tiles.len().saturating_add(1));
        let mut clip_bases = Vec::with_capacity(layer_tiles.len().saturating_add(1));
        let mut group_stack = Vec::<(
            LayerId,
            usize,
            u16,
            ink_model::LayerBlendMode,
            ink_model::LayerGroupMode,
            bool,
        )>::with_capacity(layer_tiles.len());
        for local_y in 0..TILE_SIZE {
            let document_y = i64::from(coordinate.y)
                .saturating_mul(i64::from(TILE_SIZE))
                .saturating_add(i64::from(local_y));
            if document_y < 0 || document_y >= i64::from(height_px) {
                continue;
            }
            for local_x in 0..TILE_SIZE {
                let document_x = i64::from(coordinate.x)
                    .saturating_mul(i64::from(TILE_SIZE))
                    .saturating_add(i64::from(local_x));
                if document_x < 0 || document_x >= i64::from(width_px) {
                    continue;
                }
                let index = (local_y * TILE_SIZE + local_x) as usize;
                let generation = u32::try_from(index + 1).unwrap_or(u32::MAX);
                composites.clear();
                composites.push([background.r, background.g, background.b, background.a]);
                clip_bases.clear();
                clip_bases.push(0);
                group_stack.clear();
                for (
                    layer_state,
                    layer_tile,
                    mask_tile,
                    inherited_opacity,
                    adjustment_scope,
                    paint_scopes,
                    ancestor_groups,
                ) in &layer_tiles
                {
                    while group_stack
                        .last()
                        .is_some_and(|(id, _, _, _, _, _)| !ancestor_groups.contains(id))
                    {
                        let (id, parent_target, opacity, blend_mode, group_mode, clipping) =
                            group_stack.pop().expect("checked group stack");
                        let group_composite = composites.pop().expect("group composite");
                        let group_clip_base = clip_bases.pop().expect("group clip base");
                        let _ = id;
                        if group_mode == ink_model::LayerGroupMode::PassThrough
                            && opacity == u16::MAX
                            && blend_mode == ink_model::LayerBlendMode::Normal
                            && !clipping
                        {
                            // This buffer already began with the parent
                            // backdrop, so blending it back over that same
                            // backdrop would apply translucent child pixels a
                            // second time. For the identity group presentation,
                            // publish the accumulated pass-through buffer.
                            composites[parent_target] = group_composite;
                            clip_bases[parent_target] = group_clip_base;
                        } else {
                            let parent = composites[parent_target];
                            let mut source = group_composite;
                            if clipping {
                                source[3] = ((u16::from(source[3])
                                    * u16::from(clip_bases[parent_target])
                                    + 127)
                                    / 255) as u8;
                            }
                            composites[parent_target] = ink_compositor::blend_rgba8(
                                parent,
                                source,
                                opacity,
                                compositor_blend_mode(blend_mode),
                            );
                            if !clipping {
                                clip_bases[parent_target] = composites[parent_target][3];
                            }
                        }
                    }
                    if matches!(
                        layer_state.layer.kind,
                        LayerKind::Group | LayerKind::PanelGroup
                    ) {
                        let parent_target = composites.len() - 1;
                        let isolated =
                            layer_state.layer.group_mode == ink_model::LayerGroupMode::Isolated;
                        composites.push(if isolated {
                            [0, 0, 0, 0]
                        } else {
                            composites[parent_target]
                        });
                        clip_bases.push(if isolated {
                            0
                        } else {
                            clip_bases[parent_target]
                        });
                        group_stack.push((
                            layer_state.layer.id,
                            parent_target,
                            layer_state.layer.opacity,
                            layer_state.layer.blend_mode,
                            layer_state.layer.group_mode,
                            layer_state.layer.clipping,
                        ));
                        continue;
                    }
                    let target = composites.len() - 1;
                    if layer_state.layer.kind == LayerKind::Adjustment {
                        let Some(ink_model::LayerAdjustment::BrightnessContrast {
                            brightness,
                            contrast,
                        }) = layer_state.layer.adjustment
                        else {
                            continue;
                        };
                        if composites[target][3] == 0 {
                            continue;
                        }
                        let adjustment_opacity = if let Some(scope) = adjustment_scope {
                            if scope_generation[*scope] != generation {
                                continue;
                            }
                            ((u32::from(layer_state.layer.opacity)
                                * u32::from(scope_coverage[*scope])
                                + 127)
                                / 255) as u16
                        } else {
                            *inherited_opacity
                        };
                        if adjustment_opacity == 0 {
                            continue;
                        }
                        let original = composites[target];
                        let adjusted = ink_compositor::BrightnessContrast {
                            brightness,
                            contrast,
                        }
                        .apply(original)
                        .map_err(|error| EngineError::InvalidCommand(format!("{error:?}")))?;
                        composites[target] = ink_compositor::blend_rgba8(
                            original,
                            adjusted,
                            adjustment_opacity,
                            compositor_blend_mode(layer_state.layer.blend_mode),
                        );
                        // An adjustment changes color, not the accumulated
                        // silhouette; preserve the pre-adjustment alpha.
                        composites[target][3] = original[3];
                        continue;
                    }
                    let offset = index * 4;
                    let mut alpha = layer_tile.bytes()[offset + 3];
                    if let Some((mask, stencil, inverted)) = mask_tile {
                        let coverage = mask_coverage(mask.bytes()[offset + 3], *stencil, *inverted);
                        alpha = ((u32::from(alpha) * coverage + 127) / 255) as u8;
                    }
                    let mut effective_alpha = ((u32::from(alpha) * u32::from(*inherited_opacity)
                        + 32_767)
                        / 65_535) as u8;
                    if layer_state.layer.clipping {
                        effective_alpha =
                            ((u32::from(effective_alpha) * u32::from(clip_bases[target]) + 127)
                                / 255) as u8;
                    }
                    if effective_alpha == 0 {
                        if !layer_state.layer.clipping {
                            clip_bases[target] = 0;
                        }
                        continue;
                    }
                    let unpremultiply = |value: u8| {
                        if alpha == 0 {
                            0
                        } else {
                            (u32::from(value) * 255 / u32::from(alpha)).min(255) as u8
                        }
                    };
                    let source = [
                        unpremultiply(layer_tile.bytes()[offset + 2]),
                        unpremultiply(layer_tile.bytes()[offset + 1]),
                        unpremultiply(layer_tile.bytes()[offset]),
                        effective_alpha,
                    ];
                    composites[target] = ink_compositor::blend_rgba8(
                        composites[target],
                        source,
                        u16::MAX,
                        compositor_blend_mode(layer_state.layer.blend_mode),
                    );
                    if !layer_state.layer.clipping {
                        clip_bases[target] = effective_alpha;
                    }
                    for scope in paint_scopes {
                        let previous = if scope_generation[*scope] == generation {
                            scope_coverage[*scope]
                        } else {
                            0
                        };
                        scope_coverage[*scope] = previous.saturating_add(
                            ((u16::from(effective_alpha) * u16::from(255 - previous) + 127) / 255)
                                as u8,
                        );
                        scope_generation[*scope] = generation;
                    }
                }
                while let Some((_, parent_target, opacity, blend_mode, group_mode, clipping)) =
                    group_stack.pop()
                {
                    let group_composite = composites.pop().expect("group composite");
                    let group_clip_base = clip_bases.pop().expect("group clip base");
                    if group_mode == ink_model::LayerGroupMode::PassThrough
                        && opacity == u16::MAX
                        && blend_mode == ink_model::LayerBlendMode::Normal
                        && !clipping
                    {
                        composites[parent_target] = group_composite;
                        clip_bases[parent_target] = group_clip_base;
                    } else {
                        let parent = composites[parent_target];
                        let mut source = group_composite;
                        if clipping {
                            source[3] = ((u16::from(source[3])
                                * u16::from(clip_bases[parent_target])
                                + 127)
                                / 255) as u8;
                        }
                        composites[parent_target] = ink_compositor::blend_rgba8(
                            parent,
                            source,
                            opacity,
                            compositor_blend_mode(blend_mode),
                        );
                        if !clipping {
                            clip_bases[parent_target] = composites[parent_target][3];
                        }
                    }
                }
                let composite = composites[0];
                let alpha = composite[3];
                output.blend_pixel(
                    local_x,
                    local_y,
                    Rgba8 {
                        r: composite[0],
                        g: composite[1],
                        b: composite[2],
                        a: alpha,
                    },
                    u16::MAX,
                );
            }
        }
        Ok(output.bytes().to_vec())
    }

    /// Read a bounded RGBA thumbnail for a layer without materializing a full
    /// canvas-sized bitmap. Thumbnails are a presentation projection only and
    /// are never persisted as document authority.
    pub fn read_layer_thumbnail(
        &self,
        layer_id: LayerId,
        size: u16,
    ) -> Result<Vec<u8>, EngineError> {
        if !(16..=128).contains(&size) {
            return Err(EngineError::InvalidCommand(
                "layer thumbnail size is outside limits".into(),
            ));
        }
        self.flush_input()?;
        let state = lock_recover(&self.state);
        let layer = state
            .layers
            .get(&layer_id)
            .ok_or(EngineError::InvalidLayer)?;
        let is_mask = layer.layer.kind == LayerKind::Mask;
        let thumb_side = usize::from(size);
        let mut output = vec![0_u8; thumb_side.saturating_mul(thumb_side).saturating_mul(4)];
        let source_width = u64::from(state.width_px);
        let source_height = u64::from(state.height_px);
        let size_u64 = u64::from(size);
        let (content_width, content_height) = if source_width >= source_height {
            (
                thumb_side,
                usize::try_from(
                    ((source_height * size_u64 + source_width / 2) / source_width)
                        .clamp(1, size_u64),
                )
                .unwrap_or(thumb_side),
            )
        } else {
            (
                usize::try_from(
                    ((source_width * size_u64 + source_height / 2) / source_height)
                        .clamp(1, size_u64),
                )
                .unwrap_or(thumb_side),
                thumb_side,
            )
        };
        let offset_x = (thumb_side - content_width) / 2;
        let offset_y = (thumb_side - content_height) / 2;
        for y in 0..content_height {
            for x in 0..content_width {
                // Sparse marks can be much thinner than one thumbnail pixel.
                // Sample a bounded grid within each source cell and retain the
                // strongest covered pixel so artwork does not disappear from
                // the layer list at common canvas-to-thumbnail ratios.
                let pixel = sample_layer_thumbnail_pixel(
                    layer,
                    is_mask,
                    (source_width, source_height),
                    (content_width, content_height),
                    (x, y),
                );
                let offset = ((y + offset_y) * thumb_side + x + offset_x) * 4;
                output[offset..offset + 4].copy_from_slice(&[pixel.r, pixel.g, pixel.b, pixel.a]);
            }
        }
        Ok(output)
    }

    /// Take a lossless storage snapshot of the current document.
    #[must_use]
    pub fn snapshot(&self) -> ProjectSnapshot {
        let _ = self.flush_input();
        self.snapshot_unflushed()
    }

    /// Flush accepted input and take a lossless snapshot for persistence.
    ///
    /// Callers that coordinate document access with a broader lock can release
    /// that lock after this method returns and perform storage I/O from the
    /// owned snapshot without blocking document commands for the duration of
    /// the write.
    pub fn snapshot_for_save(&self) -> Result<ProjectSnapshot, EngineError> {
        self.flush_input()?;
        Ok(self.snapshot_unflushed())
    }

    /// Return the bounded Rust-authoritative history projection.
    pub fn history_snapshot(&mut self, limit: u16) -> Result<HistoryProjection, EngineError> {
        self.flush_input()?;
        let state = lock_recover(&self.state);
        let undo = state.history.undo_transactions();
        let cursor = u32::try_from(undo.len()).unwrap_or(u32::MAX);
        let mut transactions = undo.iter().collect::<Vec<_>>();
        transactions.extend(state.history.redo_transactions());
        let total = transactions.len();
        let limit = usize::from(limit.clamp(1, 100));
        let start = total.saturating_sub(limit);
        let entries = transactions
            .into_iter()
            .enumerate()
            .skip(start)
            .map(|(index, transaction)| HistoryEntryView {
                sequence: u64::try_from(index).unwrap_or(u64::MAX),
                kind: history_kind(&transaction.command).to_owned(),
                detail: Some(transaction.label.clone()),
                applied: index < usize::try_from(cursor).unwrap_or(usize::MAX),
            })
            .collect();
        Ok(HistoryProjection {
            revision: state.revision,
            cursor,
            entries,
            was_trimmed: state.history_was_trimmed,
        })
    }

    /// Move the authoritative undo/redo cursor to a zero-based transaction
    /// boundary. The requested sequence is accepted only within the retained
    /// history and is applied through the ordinary undo/redo command path.
    pub fn navigate_history(&mut self, sequence: u64) -> Result<u64, EngineError> {
        self.flush_input()?;
        let (mut cursor, total, undo_snapshots, redo_snapshots) = {
            let state = lock_recover(&self.state);
            (
                state.history.undo_transactions().len(),
                state.history.undo_transactions().len() + state.history.redo_transactions().count(),
                state.undo_states.len(),
                state.redo_states.len(),
            )
        };
        if undo_snapshots != cursor || redo_snapshots != total.saturating_sub(cursor) {
            return Err(EngineError::InvalidCommand(
                "history cursor is not synchronized with document snapshots".into(),
            ));
        }
        let target = usize::try_from(sequence)
            .map_err(|_| EngineError::InvalidCommand("history sequence is invalid".into()))?;
        if target > total {
            return Err(EngineError::InvalidCommand(
                "history sequence is outside the retained history".into(),
            ));
        }
        while cursor > target {
            self.dispatch(EditorCommand::Undo)?;
            cursor -= 1;
        }
        while cursor < target {
            self.dispatch(EditorCommand::Redo)?;
            cursor += 1;
        }
        Ok(self.revision())
    }

    /// Attach or replace validated Phase 3 comic structure for this document.
    /// The structure is stored as canonical JSON and included in the next
    /// recovery-safe `.inkproj` checkpoint.
    pub fn set_comic_json(&mut self, bytes: Vec<u8>) -> Result<u64, EngineError> {
        ink_comic::ComicProject::from_json(&bytes).map_err(|error| {
            EngineError::InvalidCommand(format!("invalid comic structure: {error}"))
        })?;
        self.flush_input()?;
        let mut state = lock_recover(&self.state);
        state.comic_json = Some(bytes);
        state.revision = state.revision.saturating_add(1);
        let revision = state.revision;
        state.events.push(EngineEvent::DocumentChanged { revision });
        Ok(revision)
    }

    /// Read the attached comic structure without exposing mutable document
    /// state to Dart.
    #[must_use]
    pub fn comic_json(&self) -> Option<Vec<u8>> {
        lock_recover(&self.state).comic_json.clone()
    }

    fn snapshot_unflushed(&self) -> ProjectSnapshot {
        let mut state = lock_recover(&self.state);
        if state.opacity_edit.is_some()
            && commands::commit_pending_opacity_edit(&mut state, None).is_err()
        {
            let _ = commands::cancel_pending_opacity_edit(&mut state, None);
        }
        let current = map_to_stored_state(&state.layers);
        ProjectSnapshot {
            id: self.id,
            spec: self.spec,
            revision: state.revision,
            layers: current.layers,
            tiles: current.tiles,
            vectors: current.vectors,
            journal: state.journal.clone(),
            history: HistorySnapshot {
                undo: state.undo_states.iter().map(map_to_stored_state).collect(),
                redo: state.redo_states.iter().map(map_to_stored_state).collect(),
                truncated_on_load: state.history_was_trimmed,
            },
            brushes: state
                .brush_overrides
                .values()
                .map(|preset| {
                    serde_json::to_vec(preset).expect("validated brush preset must serialize")
                })
                .collect(),
            resources: state
                .resources
                .iter()
                .map(|(hash, resource)| ResourceRecord {
                    hash: *hash,
                    kind: resource.kind.clone(),
                    width: resource.width,
                    height: resource.height,
                    bytes: resource.rgba8.clone(),
                })
                .collect(),
            layer_panel_state: state.layer_panel_state.clone(),
            comic: state.comic_json.clone(),
        }
    }

    /// Atomically save the current document as a native `.inkproj` directory.
    pub fn save_as(&self, destination: &std::path::Path) -> Result<(), EngineError> {
        ink_storage::save_project(destination, &self.snapshot_for_save()?)
            .map_err(EngineError::from)
    }

    /// Return the bounded in-session stroke recording used for time-lapse
    /// export. It contains no document pixels or external paths.
    #[must_use]
    pub fn time_lapse(&self) -> TimeLapseRecording {
        let _ = self.flush_input();
        lock_recover(&self.state).time_lapse.clone()
    }

    /// Export the current session's stroke history as deterministic JSON.
    pub fn export_time_lapse(&self, destination: &std::path::Path) -> Result<(), EngineError> {
        let bytes = self.time_lapse().to_json().map_err(|error| {
            EngineError::InvalidCommand(format!("time-lapse encoding failed: {error}"))
        })?;
        if let Ok(metadata) = std::fs::symlink_metadata(destination)
            && (metadata.file_type().is_symlink() || !metadata.is_file())
        {
            return Err(EngineError::InvalidCommand(
                "time-lapse destination is unsafe".into(),
            ));
        }
        let mut file = std::fs::File::create(destination).map_err(|error| {
            EngineError::InvalidCommand(format!("time-lapse export failed: {error}"))
        })?;
        file.write_all(&bytes)
            .and_then(|()| file.sync_all())
            .map_err(|error| {
                EngineError::InvalidCommand(format!("time-lapse export failed: {error}"))
            })
    }

    /// Open a native `.inkproj` directory without modifying its source.
    pub fn open(source: &std::path::Path) -> Result<Self, EngineError> {
        Self::from_snapshot(ink_storage::load_project(source)?)
    }

    /// Export the visible raster composite as a deterministic RGBA PNG.
    pub fn export_png(&self, destination: &std::path::Path) -> Result<(), EngineError> {
        self.export(destination, ink_export::ExportFormat::Png)
    }

    /// Export the visible raster composite through a Phase 2 format encoder.
    pub fn export(
        &self,
        destination: &std::path::Path,
        format: ink_export::ExportFormat,
    ) -> Result<(), EngineError> {
        self.flush_input()?;
        let width = self.spec.width_px;
        let height = self.spec.height_px;
        let pixel_count = usize::try_from(width)
            .ok()
            .and_then(|w| usize::try_from(height).ok().and_then(|h| w.checked_mul(h)))
            .ok_or_else(|| EngineError::InvalidCommand("image dimensions overflow".into()))?;
        let pixel_bytes = pixel_count
            .checked_mul(4)
            .ok_or_else(|| EngineError::InvalidCommand("image dimensions overflow".into()))?;
        if pixel_bytes > MAX_EXPORT_BYTES {
            return Err(EngineError::InvalidCommand(
                "PNG export exceeds the memory safety limit".into(),
            ));
        }
        let mut pixels = vec![0_u8; pixel_bytes];
        let tile_columns = width.div_ceil(TILE_SIZE);
        let tile_rows = height.div_ceil(TILE_SIZE);
        for tile_y in 0..tile_rows {
            for tile_x in 0..tile_columns {
                let composite = self.read_composite_tile(TileCoord {
                    x: i32::try_from(tile_x).unwrap_or(i32::MAX),
                    y: i32::try_from(tile_y).unwrap_or(i32::MAX),
                })?;
                for local_y in 0..TILE_SIZE {
                    let y = tile_y * TILE_SIZE + local_y;
                    if y >= height {
                        break;
                    }
                    for local_x in 0..TILE_SIZE {
                        let x = tile_x * TILE_SIZE + local_x;
                        if x >= width {
                            break;
                        }
                        let source = ((local_y * TILE_SIZE + local_x) * 4) as usize;
                        let destination = ((y * width + x) * 4) as usize;
                        let alpha = u32::from(composite[source + 3]).max(1);
                        pixels[destination] =
                            (u32::from(composite[source + 2]) * 255 / alpha).min(255) as u8;
                        pixels[destination + 1] =
                            (u32::from(composite[source + 1]) * 255 / alpha).min(255) as u8;
                        pixels[destination + 2] =
                            (u32::from(composite[source]) * 255 / alpha).min(255) as u8;
                        pixels[destination + 3] = composite[source + 3];
                    }
                }
            }
        }
        ink_export::write_export(destination, format, width, height, &pixels)
            .map_err(EngineError::from)
    }
    /// Current revision.
    #[must_use]
    pub fn revision(&self) -> u64 {
        lock_recover(&self.state).revision
    }
    /// Layer summaries in stable order.
    #[must_use]
    pub fn layers(&self) -> Vec<Layer> {
        let _ = self.flush_input();
        // Keep the historical ID-stable projection for existing callers and
        // fixtures. Compositing and persistence use `ordered_layer_states`;
        // bridge layer summaries expose each sibling's explicit `order` so a
        // UI can render a hierarchical list without treating indexes as IDs.
        lock_recover(&self.state)
            .layers
            .values()
            .map(|state| state.layer.clone())
            .collect()
    }

    /// Return drag-source and group-destination rules from the authoritative
    /// layer tree. Pair-specific cycle checks remain the caller's job.
    pub fn layer_drag_capabilities(&self) -> Result<Vec<LayerDragCapability>, EngineError> {
        self.flush_input()?;
        let state = lock_recover(&self.state);
        let comic_owned_ids = comic_owned_layer_ids(state.comic_json.as_deref())?;
        Ok(state
            .layers
            .values()
            .map(|layer| layer_drag_capability(&state, &comic_owned_ids, &layer.layer))
            .collect())
    }

    /// Return Rust-validated availability and explanations for common
    /// single-layer actions in the authoritative layer tree.
    pub fn layer_action_capabilities(&self) -> Result<Vec<LayerActionCapability>, EngineError> {
        self.flush_input()?;
        let state = lock_recover(&self.state);
        let comic_owned_ids = comic_owned_layer_ids(state.comic_json.as_deref())?;
        let capabilities = state
            .layers
            .values()
            .map(|layer| layer_action_capability(&state, &comic_owned_ids, &layer.layer))
            .collect();
        Ok(capabilities)
    }

    /// Read the durable layer-panel state for this document/page.
    #[must_use]
    pub fn layer_panel_state(&self) -> LayerPanelState {
        lock_recover(&self.state).layer_panel_state.clone()
    }

    /// Persist the primary layer target and collapsed ordinary groups without
    /// adding a content-history entry. Unknown IDs and non-group disclosures
    /// are rejected as one atomic update.
    pub fn set_layer_panel_state(
        &mut self,
        primary_layer: Option<LayerId>,
        mut collapsed_groups: Vec<LayerId>,
    ) -> Result<u64, EngineError> {
        self.flush_input()?;
        collapsed_groups.sort_unstable();
        let candidate = LayerPanelState {
            primary_layer,
            collapsed_groups,
        };
        let mut state = lock_recover(&self.state);
        validate_layer_panel_state(&candidate, state.layers.values().map(|layer| &layer.layer))?;
        if state.layer_panel_state == candidate {
            return Ok(state.revision);
        }
        advance_revision(&mut state)?;
        let revision = state.revision;
        state.layer_panel_state = candidate;
        state.events.push(EngineEvent::DocumentChanged { revision });
        Ok(revision)
    }

    /// First visible raster layer suitable for the Phase 1 canvas, falling
    /// back to the first raster layer when all raster layers are hidden.
    #[must_use]
    pub fn primary_raster_layer(&self) -> Option<LayerId> {
        let _ = self.flush_input();
        let state = lock_recover(&self.state);
        state
            .layers
            .values()
            .find(|state| state.layer.kind == LayerKind::Raster && state.layer.visible)
            .or_else(|| {
                state
                    .layers
                    .values()
                    .find(|state| state.layer.kind == LayerKind::Raster)
            })
            .map(|state| state.layer.id)
    }

    /// Allocated tile coordinates used to seed a UI cache without materializing
    /// every transparent tile in a sparse document.
    #[must_use]
    pub fn tile_descriptors(&self) -> Vec<TileDescriptor> {
        let _ = self.flush_input();
        let state = lock_recover(&self.state);
        let mut tiles = Vec::new();
        for layer in ordered_layer_states(&state.layers) {
            tiles.extend(
                layer
                    .tiles
                    .allocated_coordinates()
                    .into_iter()
                    .map(|coordinate| TileDescriptor {
                        layer: layer.layer.id,
                        coordinate,
                    }),
            );
        }
        tiles.sort_unstable_by_key(|tile| (tile.layer, tile.coordinate.y, tile.coordinate.x));
        tiles
    }

    /// Stop the render worker deterministically before releasing a bridge
    /// handle. Calling this more than once is harmless.
    pub fn close(&mut self) {
        self.worker.shutdown();
    }

    /// Estimate memory owned by the document state and reversible snapshots.
    ///
    /// This intentionally excludes allocator/process overhead and the Flutter
    /// image cache; it is a stable engine-side measurement for benchmark
    /// comparisons, not a substitute for a platform RSS trace.
    #[must_use]
    pub fn estimated_working_memory_bytes(&self) -> usize {
        let _ = self.flush_input();
        let state = lock_recover(&self.state);
        let snapshot_bytes = state
            .undo_states
            .iter()
            .chain(state.redo_states.iter())
            .map(layer_map_bytes)
            .sum::<usize>();
        let preview_bytes = state
            .active_stroke
            .as_ref()
            .map(|active| {
                active
                    .preview_tiles
                    .tiles()
                    .iter()
                    .map(|(_, bytes)| {
                        std::mem::size_of::<TileCoord>()
                            + std::mem::size_of::<Vec<u8>>()
                            + bytes.len()
                    })
                    .sum::<usize>()
            })
            .unwrap_or_default();
        std::mem::size_of::<EngineState>()
            .saturating_add(layer_map_bytes(&state.layers))
            .saturating_add(snapshot_bytes)
            .saturating_add(preview_bytes)
            .saturating_add(resource_total_bytes(&state.resources))
            .saturating_add(state.resource_cache.bytes())
            .saturating_add(
                state
                    .journal
                    .iter()
                    .map(|payload| std::mem::size_of::<Vec<u8>>() + payload.len())
                    .sum(),
            )
    }

    /// Replay the persisted command journal against a fresh document state.
    ///
    /// This is a compatibility and audit check for command/layer/history
    /// semantics. Pixel content is restored from checkpoint tiles because
    /// pointer packets are intentionally not journaled in the v1 format.
    pub fn replay_journal(&self) -> Result<JournalReplayReport, EngineError> {
        self.flush_input()?;
        let journal = lock_recover(&self.state).journal.clone();
        let commands = decode_journal(&journal).map_err(|error| {
            EngineError::InvalidCommand(format!("invalid command journal: {error}"))
        })?;
        let command_count = commands.len();
        let mut replay = Self::new(self.id, self.spec)?;
        for command in commands {
            replay.dispatch(command)?;
        }
        let state = lock_recover(&replay.state);
        Ok(JournalReplayReport {
            command_count,
            command_revision: state.revision,
            layer_count: state.layers.len(),
            active_stroke: state.active_stroke.is_some(),
        })
    }
    /// Tile size exposed to the UI.
    #[must_use]
    pub const fn tile_size(&self) -> u32 {
        TILE_SIZE
    }
}

fn blend_preview_over(destination: &mut [u8], preview: &[u8]) {
    for offset in (0..destination.len()).step_by(4) {
        let source = &preview[offset..offset + 4];
        let destination = &mut destination[offset..offset + 4];
        let source_alpha = u32::from(source[3]);
        let inverse = 255 - source_alpha;
        for channel in 0..3 {
            destination[channel] = (u32::from(source[channel])
                + (u32::from(destination[channel]) * inverse + 127) / 255)
                .min(255) as u8;
        }
        destination[3] =
            (source_alpha + (u32::from(destination[3]) * inverse + 127) / 255).min(255) as u8;
    }
}

#[cfg(test)]
mod tests;
