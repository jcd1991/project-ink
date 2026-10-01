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
    clippy::cast_precision_loss,
    clippy::too_many_lines
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
    HistorySnapshot, ProjectSnapshot, ResourceRecord, StorageError, StoredState, TileRecord,
    VectorRecord,
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

#[derive(Clone, Debug)]
struct LayerState {
    layer: Layer,
    tiles: TileStore,
    vectors: Vec<(ink_model::StrokeId, VectorStroke)>,
}

#[derive(Clone, Debug)]
struct BrushResource {
    kind: String,
    width: u32,
    height: u32,
    rgba8: Vec<u8>,
}

/// Bounded decoded-resource cache. The project resource map remains the
/// durable source of truth; this LRU limits hot decoded copies used by brush
/// rendering and can be discarded without changing document semantics.
#[derive(Debug)]
struct ResourceLru {
    entries: BTreeMap<[u8; 32], BrushResource>,
    order: VecDeque<[u8; 32]>,
    bytes: usize,
    max_bytes: usize,
}

impl ResourceLru {
    const DEFAULT_MAX_BYTES: usize = 64 * 1024 * 1024;

    fn new() -> Self {
        Self {
            entries: BTreeMap::new(),
            order: VecDeque::new(),
            bytes: 0,
            max_bytes: Self::DEFAULT_MAX_BYTES,
        }
    }

    fn touch(&mut self, hash: [u8; 32]) {
        if let Some(position) = self.order.iter().position(|candidate| *candidate == hash) {
            self.order.remove(position);
        }
        self.order.push_back(hash);
    }

    fn resolve(
        &mut self,
        hash: [u8; 32],
        resources: &BTreeMap<[u8; 32], BrushResource>,
    ) -> Option<BrushResource> {
        if let Some(resource) = self.entries.get(&hash).cloned() {
            self.touch(hash);
            return Some(resource);
        }
        let resource = resources.get(&hash)?.clone();
        if resource.rgba8.len() > self.max_bytes {
            return Some(resource);
        }
        while self.bytes.saturating_add(resource.rgba8.len()) > self.max_bytes {
            let Some(evicted) = self.order.pop_front() else {
                break;
            };
            if let Some(previous) = self.entries.remove(&evicted) {
                self.bytes = self.bytes.saturating_sub(previous.rgba8.len());
            }
        }
        self.bytes = self.bytes.saturating_add(resource.rgba8.len());
        self.entries.insert(hash, resource.clone());
        self.order.push_back(hash);
        Some(resource)
    }

    fn resolve_for_dabs(
        &mut self,
        dabs: &[BrushDab],
        resources: &BTreeMap<[u8; 32], BrushResource>,
    ) -> BTreeMap<[u8; 32], BrushResource> {
        let mut resolved = BTreeMap::new();
        for dab in dabs {
            if let Some(hash) = dab.tip_resource_hash
                && let Some(resource) = self.resolve(hash, resources)
            {
                resolved.entry(hash).or_insert(resource);
            }
        }
        resolved
    }

    fn bytes(&self) -> usize {
        self.bytes
    }
}

#[derive(Clone, Debug)]
struct BrushDraftSettings {
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
}

#[derive(Clone, Debug)]
struct BrushEditUndo {
    brush_id: BrushId,
    previous_override: Option<BrushPresetV2>,
    current_override: Option<BrushPresetV2>,
}

fn map_to_stored_state(layers: &BTreeMap<LayerId, LayerState>) -> StoredState {
    let mut stored_layers = Vec::with_capacity(layers.len());
    let mut tiles = Vec::new();
    let mut vectors = Vec::new();
    for state in ordered_layer_states(layers) {
        stored_layers.push(state.layer.clone());
        tiles.extend(
            state
                .tiles
                .tiles()
                .into_iter()
                .map(|(coordinate, bytes)| TileRecord {
                    layer: state.layer.id,
                    coordinate,
                    bytes,
                }),
        );
        vectors.extend(state.vectors.iter().map(|(stroke, vector)| {
            let bytes = serde_json::to_vec(vector).expect("validated vector stroke must serialize");
            VectorRecord {
                layer: state.layer.id,
                stroke: stroke.0,
                bytes,
            }
        }));
    }
    StoredState {
        layers: stored_layers,
        tiles,
        vectors,
    }
}

fn stored_to_map(
    state: StoredState,
    spec: DocumentSpec,
) -> Result<BTreeMap<LayerId, LayerState>, EngineError> {
    let mut layers = BTreeMap::new();
    // The SQLite v1 schema had no explicit order column. The serialized
    // layer sequence is therefore the compatibility source of truth; assign
    // canonical sibling ranks while loading so older projects preserve their
    // visible stacking order and newer projects remain deterministic.
    let mut sibling_next: BTreeMap<Option<LayerId>, u32> = BTreeMap::new();
    for mut layer in state.layers {
        let next = sibling_next.entry(layer.parent).or_default();
        layer.order = *next;
        *next = next.saturating_add(1);
        let id = layer.id;
        let previous = layers.insert(
            id,
            LayerState {
                layer,
                tiles: TileStore::default(),
                vectors: Vec::new(),
            },
        );
        if previous.is_some() {
            return Err(EngineError::InvalidCommand(
                "layer tree contains a duplicate layer ID".into(),
            ));
        }
    }
    if layers.is_empty() {
        return Err(EngineError::InvalidCommand(
            "document state must contain at least one layer".into(),
        ));
    }
    validate_layer_tree(&layers)?;
    for tile in state.tiles {
        let layer = layers
            .get_mut(&tile.layer)
            .ok_or(EngineError::InvalidLayer)?;
        let decoded = Tile::from_bytes(tile.bytes)
            .map_err(|_| EngineError::InvalidCommand("invalid tile payload".into()))?;
        let x = u32::try_from(tile.coordinate.x)
            .map_err(|_| EngineError::InvalidCommand("tile is outside the canvas".into()))?;
        let y = u32::try_from(tile.coordinate.y)
            .map_err(|_| EngineError::InvalidCommand("tile is outside the canvas".into()))?;
        if x >= spec.width_px.div_ceil(TILE_SIZE) || y >= spec.height_px.div_ceil(TILE_SIZE) {
            return Err(EngineError::InvalidCommand(
                "tile is outside the canvas".into(),
            ));
        }
        layer.tiles.restore([(tile.coordinate, decoded)]);
    }
    for vector in state.vectors {
        let layer = layers
            .get_mut(&vector.layer)
            .ok_or(EngineError::InvalidLayer)?;
        if layer.layer.kind != LayerKind::VectorInk {
            return Err(EngineError::InvalidCommand(
                "vector stroke references a non-vector layer".into(),
            ));
        }
        let decoded: VectorStroke = serde_json::from_slice(&vector.bytes).map_err(|error| {
            EngineError::InvalidCommand(format!("invalid vector stroke payload: {error}"))
        })?;
        validate_vector_stroke(&decoded, spec)?;
        layer
            .vectors
            .push((ink_model::StrokeId::from_u128(vector.stroke), decoded));
    }
    Ok(layers)
}

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

fn trim_history_snapshots(snapshots: &mut Vec<BTreeMap<LayerId, LayerState>>) {
    while snapshots.len() > 128
        || (snapshots.len() > 1
            && snapshots
                .iter()
                .map(layer_map_bytes)
                .fold(0usize, usize::saturating_add)
                > MAX_HISTORY_SNAPSHOT_BYTES)
    {
        snapshots.remove(0);
    }
}

fn time_lapse_has_capacity(recording: &TimeLapseRecording, additional_samples: usize) -> bool {
    let recorded_samples = recording
        .strokes
        .iter()
        .map(|stroke| stroke.samples.len())
        .fold(0usize, usize::saturating_add);
    time_lapse_has_capacity_at(
        recording.strokes.len(),
        recorded_samples,
        additional_samples,
    )
}

fn time_lapse_has_capacity_at(
    recorded_strokes: usize,
    recorded_samples: usize,
    additional_samples: usize,
) -> bool {
    recorded_strokes < TimeLapseRecording::MAX_STROKES
        && recorded_samples.saturating_add(additional_samples) <= TimeLapseRecording::MAX_SAMPLES
}

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

/// Merge one standalone raster layer into another using the same deterministic
/// compositor used for export. The source layer is removed only after every
/// source tile has been validated and applied. This keeps the operation
/// atomic from the caller's perspective: validation failures cannot partially
/// mutate the document, while the normal layer-map snapshot makes the command
/// fully undoable and journal-replayable.
fn merge_raster_layers(
    state: &mut EngineState,
    target: LayerId,
    source: LayerId,
) -> Result<Vec<TileCoord>, EngineError> {
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

    // Clone only the bounded source payload before borrowing the target
    // mutably. TileStore::tiles() returns stable, owned bytes and therefore
    // avoids aliasing the mutable document state during the merge.
    let source_opacity = source_state.layer.opacity;
    let source_mode = compositor_blend_mode(source_state.layer.blend_mode);
    let source_visible = source_state.layer.visible;
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
        .collect::<Result<Vec<_>, _>>()?;
    let mut dirty = HashSet::new();
    if source_visible && source_opacity > 0 {
        let target_state = state
            .layers
            .get_mut(&target)
            .ok_or(EngineError::InvalidLayer)?;
        for (coordinate, tile) in source_tiles {
            for local_y in 0..TILE_SIZE {
                for local_x in 0..TILE_SIZE {
                    let source_pixel = tile.pixel_rgba(local_x, local_y);
                    if source_pixel.a == 0 {
                        continue;
                    }
                    let document_x = i64::from(coordinate.x)
                        .saturating_mul(i64::from(TILE_SIZE))
                        .saturating_add(i64::from(local_x));
                    let document_y = i64::from(coordinate.y)
                        .saturating_mul(i64::from(TILE_SIZE))
                        .saturating_add(i64::from(local_y));
                    if document_x < 0
                        || document_y < 0
                        || document_x >= i64::from(state.width_px)
                        || document_y >= i64::from(state.height_px)
                    {
                        continue;
                    }
                    let x = u32::try_from(document_x).map_err(|_| {
                        EngineError::InvalidCommand("source tile coordinate overflow".into())
                    })?;
                    let y = u32::try_from(document_y).map_err(|_| {
                        EngineError::InvalidCommand("source tile coordinate overflow".into())
                    })?;
                    let destination = target_state.tiles.sample_pixel(x, y);
                    let blended = ink_compositor::blend_rgba8(
                        [destination.r, destination.g, destination.b, destination.a],
                        [
                            source_pixel.r,
                            source_pixel.g,
                            source_pixel.b,
                            source_pixel.a,
                        ],
                        source_opacity,
                        source_mode,
                    );
                    target_state.tiles.set_pixel(
                        x,
                        y,
                        Rgba8 {
                            r: blended[0],
                            g: blended[1],
                            b: blended[2],
                            a: blended[3],
                        },
                    );
                    dirty.insert(TileCoord {
                        x: i32::try_from(x / TILE_SIZE).map_err(|_| {
                            EngineError::InvalidCommand("target tile coordinate overflow".into())
                        })?,
                        y: i32::try_from(y / TILE_SIZE).map_err(|_| {
                            EngineError::InvalidCommand("target tile coordinate overflow".into())
                        })?,
                    });
                }
            }
        }
    }
    state.layers.remove(&source);
    normalize_sibling_orders(&mut state.layers, source_parent);
    let mut dirty = dirty.into_iter().collect::<Vec<_>>();
    dirty.sort_unstable_by_key(|coordinate| (coordinate.y, coordinate.x));
    Ok(dirty)
}

/// Return the first visible mask sibling after a paint layer. Mask layers are
/// intentionally simple in v1: their alpha acts as a nondestructive stencil
/// for the preceding raster/vector sibling in the same parent group.
fn mask_sibling<'a>(
    layers: &'a BTreeMap<LayerId, LayerState>,
    layer: &LayerState,
) -> Option<&'a LayerState> {
    if !matches!(layer.layer.kind, LayerKind::Raster | LayerKind::VectorInk) {
        return None;
    }
    let ordered = ordered_layer_ids(layers);
    let position = ordered.iter().position(|id| *id == layer.layer.id)?;
    for candidate_id in ordered.into_iter().skip(position.saturating_add(1)) {
        let candidate = layers.get(&candidate_id)?;
        if candidate.layer.parent != layer.layer.parent {
            continue;
        }
        if candidate.layer.kind == LayerKind::Mask {
            return candidate.layer.visible.then_some(candidate);
        }
        if matches!(
            candidate.layer.kind,
            LayerKind::Raster | LayerKind::VectorInk
        ) {
            return None;
        }
    }
    None
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
            let mask_id = ordered_layer_ids(layers).into_iter().find(|id| {
                layers.get(id).is_some_and(|candidate| {
                    candidate.layer.parent == Some(parent_id)
                        && candidate.layer.kind == LayerKind::Mask
                        && candidate.layer.visible
                        && candidate.tiles.allocated_tiles() > 0
                })
            });
            if let Some(mask_id) = mask_id {
                return layers.get(&mask_id);
            }
        }
        current = parent.layer.parent;
    }
    None
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

#[derive(Debug)]
struct ActiveStroke {
    stroke: ink_model::StrokeId,
    layer: LayerId,
    brush: BrushPreset,
    compiled_brush: Option<CompiledBrush>,
    compiled_brush_state: CompiledBrushState,
    /// Retained input for optional end-of-stroke effects. This is a rolling
    /// per-segment buffer; the full stroke is summarized incrementally below.
    samples: Vec<ink_input::PointerSample>,
    last_confirmed_sample: Option<ink_input::PointerSample>,
    input_metrics: StrokeInputMetrics,
    sample_history_complete: bool,
    /// Last raw pointer sample, including samples outside the document. Keeping
    /// this separately lets us clip the incoming segment instead of pinning
    /// every off-canvas point to the nearest edge.
    last_input_sample: Option<ink_input::PointerSample>,
    /// Once a stroke exits after entering the page, ignore further captured
    /// motion until pointer-up. This prevents accidentally connecting the exit
    /// and re-entry points through the page while keeping the transaction live.
    stopped_at_page_edge: bool,
    /// Last spacing anchor for incremental legacy-brush resampling.
    legacy_resample_anchor: Option<Dab>,
    legacy_rendered_dabs: usize,
    legacy_segment_dabs: usize,
    work_segments: u64,
    compiled_rendered_dabs: usize,
    compiled_cpu_tile_updates: usize,
    cpu_tile_updates: usize,
    compiled_dab_last_position: Option<(f32, f32)>,
    compiled_dab_path_length: f64,
    compiled_dab_max_step: f32,
    preview_tiles: TileStore,
    preview_eraser: bool,
    /// Set when a bounded work ceiling is reached. Existing rasterized pixels
    /// remain valid; a later input batch or `EndStroke` reports the bounded
    /// evaluator failure so callers can cancel the incomplete transaction.
    /// This avoids turning a safety guard into loss of the entire stroke.
    work_limit_reached: bool,
}

#[derive(Debug, Default)]
struct StrokeInputMetrics {
    sample_count: usize,
    path_start: Option<ink_input::PointerSample>,
    path_end: Option<ink_input::PointerSample>,
    bounds: Option<(f32, f32, f32, f32)>,
    pressure_range: Option<(f32, f32)>,
    path_length: f64,
}

#[derive(Debug)]
struct EngineState {
    width_px: u32,
    height_px: u32,
    revision: u64,
    layers: BTreeMap<LayerId, LayerState>,
    history: History,
    undo_states: Vec<BTreeMap<LayerId, LayerState>>,
    redo_states: Vec<BTreeMap<LayerId, LayerState>>,
    history_was_trimmed: bool,
    journal: Vec<Vec<u8>>,
    active_stroke: Option<ActiveStroke>,
    time_lapse: TimeLapseRecording,
    /// User edits to presets are kept in the Rust engine. Built-ins remain
    /// immutable until an explicit override is created by the editor.
    brush_overrides: BTreeMap<ink_model::BrushId, BrushPresetV2>,
    /// The most recent brush-library edit participates in the same Undo/Redo
    /// command path as canvas edits. It is intentionally session-scoped; the
    /// durable brush override itself is persisted with the document.
    brush_undo: Option<BrushEditUndo>,
    brush_redo: Option<BrushEditUndo>,
    resources: BTreeMap<[u8; 32], BrushResource>,
    resource_cache: ResourceLru,
    /// Ephemeral selection mask. It is intentionally not persisted in v1
    /// projects; it constrains rasterization until the user clears it.
    selection: Option<SelectionMask>,
    brush_drafts: BTreeMap<u64, (BrushId, BrushDraftSettings)>,
    next_brush_draft: u64,
    /// Rust-generated ephemeral dabs shared with an optional GPU preview.
    /// If the optional preview queue is saturated, the CPU document continues
    /// without interruption and this counter records that the preview should
    /// fall back to the normal tile path. The queue is never part of document
    /// persistence or undo state.
    live_dabs: Arc<Mutex<ink_live_render::LiveDabQueue>>,
    live_dab_overflow_count: Arc<AtomicU64>,
    events: Vec<EngineEvent>,
    worker_error: Option<String>,
    /// Optional validated Phase 3 comic structure persisted with the native
    /// document. Pixels and comic metadata remain separate authorities.
    comic_json: Option<Vec<u8>>,
}

#[derive(Debug)]
struct WorkerControl {
    queue: PacketQueue,
    shutdown: bool,
    busy: bool,
}

#[derive(Debug)]
struct RenderWorker {
    control: Arc<(Mutex<WorkerControl>, Condvar)>,
    state: Arc<Mutex<EngineState>>,
    join: Option<JoinHandle<()>>,
}

impl RenderWorker {
    fn new(state: Arc<Mutex<EngineState>>) -> Result<Self, EngineError> {
        let control = Arc::new((
            Mutex::new(WorkerControl {
                queue: PacketQueue::new(1024),
                shutdown: false,
                busy: false,
            }),
            Condvar::new(),
        ));
        let worker_control = Arc::clone(&control);
        let worker_state = Arc::clone(&state);
        let join = thread::Builder::new()
            .name("project-ink-render".into())
            .spawn(move || render_worker_loop(worker_control, worker_state))
            .map_err(|error| EngineError::WorkerUnavailable(error.to_string()))?;
        Ok(Self {
            control,
            state,
            join: Some(join),
        })
    }

    fn enqueue(&self, bytes: Vec<u8>) -> Result<QueueOutcome, EngineError> {
        Self::enqueue_pointer_packet(&self.control, bytes)
    }

    fn enqueue_pointer_packet(
        control: &Arc<(Mutex<WorkerControl>, Condvar)>,
        bytes: Vec<u8>,
    ) -> Result<QueueOutcome, EngineError> {
        let (lock, wake) = &**control;
        let mut control = lock_recover(lock);
        let mut pending_packet = bytes;
        loop {
            if control.shutdown {
                return Err(EngineError::WorkerUnavailable(
                    "render worker is closed".into(),
                ));
            }
            match control.queue.push_preserving_on_error(pending_packet) {
                Ok(outcome) => {
                    if outcome == QueueOutcome::Enqueued {
                        wake.notify_one();
                    }
                    return Ok(outcome);
                }
                Err((ink_input::PacketError::QueueFull, packet)) => {
                    // Confirmed input is document data, not a disposable live
                    // preview. Keep the packet bounded at the queue boundary
                    // and wait for the CPU renderer to free a slot instead of
                    // rejecting the UI call and canceling the active stroke.
                    pending_packet = packet;
                    control = wake.wait(control).unwrap_or_else(PoisonError::into_inner);
                }
                Err((error, _packet)) => return Err(EngineError::Packet(error)),
            }
        }
    }

    fn flush(&self) {
        let (lock, wake) = &*self.control;
        let mut control = lock_recover(lock);
        while !control.queue.is_empty() || control.busy {
            control = wake.wait(control).unwrap_or_else(PoisonError::into_inner);
        }
    }

    fn take_error(&self) -> Option<String> {
        lock_recover(&self.state).worker_error.take()
    }

    fn shutdown(&mut self) {
        let (lock, wake) = &*self.control;
        {
            let mut control = lock_recover(lock);
            control.shutdown = true;
            wake.notify_all();
        }
        if let Some(join) = self.join.take() {
            let _ = join.join();
        }
    }
}

impl Drop for RenderWorker {
    fn drop(&mut self) {
        self.shutdown();
    }
}

#[allow(clippy::needless_pass_by_value)]
fn render_worker_loop(
    control: Arc<(Mutex<WorkerControl>, Condvar)>,
    state: Arc<Mutex<EngineState>>,
) {
    loop {
        let bytes = {
            let (lock, wake) = &*control;
            let mut control = lock_recover(lock);
            while control.queue.is_empty() && !control.shutdown {
                control = wake.wait(control).unwrap_or_else(PoisonError::into_inner);
            }
            if control.queue.is_empty() && control.shutdown {
                break;
            }
            control.busy = true;
            control.queue.pop()
        };

        if let Some(bytes) = bytes {
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                decode(&bytes)
                    .map_err(|error| error.to_string())
                    .and_then(|packet| {
                        consume_packet(&mut lock_recover(&state), packet)
                            .map_err(|error| error.to_string())
                    })
            }));
            let error = match result {
                Ok(Ok(())) => None,
                Ok(Err(error)) => Some(error),
                Err(_) => Some("render worker rejected a panicking packet".to_string()),
            };
            if let Some(error) = error {
                eprintln!("Project Ink render worker error: {error}");
                lock_recover(&state).worker_error = Some(error);
            }
        }

        let (lock, wake) = &*control;
        let mut control = lock_recover(lock);
        control.busy = false;
        wake.notify_all();
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

    /// Delete one leaf layer as an undoable command. The engine rejects
    /// deletion of the final layer and groups that still contain children.
    pub fn delete_layer(&mut self, layer: LayerId) -> Result<u64, EngineError> {
        self.dispatch(EditorCommand::DeleteLayer { layer })
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
                let duplicate = next_layer_id(&state.layers)?;
                (kind, vec![(source, duplicate)])
            }
        };
        if kind == LayerKind::Group {
            let duplicate = duplicates[0].1;
            self.dispatch(EditorCommand::DuplicateLayerSubtree { source, duplicates })?;
            Ok(duplicate)
        } else {
            let duplicate = duplicates[0].1;
            self.dispatch(EditorCommand::DuplicateLayer { source, duplicate })?;
            Ok(duplicate)
        }
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

    /// Merge a standalone raster source into a raster target as one undoable
    /// command. The explicit IDs are stable across UI reorder operations.
    pub fn merge_layers(&mut self, target: LayerId, source: LayerId) -> Result<u64, EngineError> {
        self.dispatch(EditorCommand::MergeLayers { target, source })
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
                brush_undo: None,
                brush_redo: None,
                resources: BTreeMap::new(),
                resource_cache: ResourceLru::new(),
                selection: None,
                brush_drafts: BTreeMap::new(),
                next_brush_draft: 1,
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
                EditorCommand::EndStroke { .. } => {}
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
                brush_undo: None,
                brush_redo: None,
                resources: resource_map,
                resource_cache: ResourceLru::new(),
                selection: None,
                brush_drafts: BTreeMap::new(),
                next_brush_draft: 1,
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
        dispatch_state(&mut state, command)
    }
}

fn flush_deferred_dual_dabs(
    state: &mut EngineState,
    stroke: StrokeId,
) -> Result<Vec<TileCoord>, EngineError> {
    let (layer_id, sequence, pending) = {
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
            start = end;
        }
    }
    for (dab_index, dab) in all_dabs.into_iter().enumerate() {
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
    dirty.sort_unstable_by_key(|coordinate| (coordinate.y, coordinate.x));
    dirty.dedup();
    Ok(dirty)
}

fn dispatch_state(state: &mut EngineState, command: EditorCommand) -> Result<u64, EngineError> {
    if state.active_stroke.is_some()
        && !matches!(
            command,
            EditorCommand::EndStroke { .. } | EditorCommand::CancelStroke { .. }
        )
    {
        return Err(EngineError::InvalidCommand(
            "finish or cancel the active stroke before another command".into(),
        ));
    }
    if state.journal.len() >= MAX_COMMAND_JOURNAL_ENTRIES {
        return Err(EngineError::InvalidCommand(
            "command journal safety limit reached; save and reopen the document".into(),
        ));
    }
    // A canvas command establishes a new top-level history branch. Brush
    // library edits use a small session-scoped slot because they are not part
    // of the raster layer snapshot schema; clear that slot once another
    // command starts so Undo always follows the most recent mutation domain.
    if !matches!(command, EditorCommand::Undo | EditorCommand::Redo) {
        state.brush_undo = None;
        state.brush_redo = None;
    }
    let before_layers = if matches!(
        command,
        EditorCommand::Undo
            | EditorCommand::Redo
            | EditorCommand::EndStroke { .. }
            | EditorCommand::CancelStroke { .. }
    ) {
        None
    } else {
        Some(state.layers.clone())
    };
    match &command {
        EditorCommand::SetPanelMaskGeometry { mask, points } => {
            if !(3..=64).contains(&points.len()) {
                return Err(EngineError::InvalidCommand(
                    "panel mask requires 3 to 64 vertices".into(),
                ));
            }
            if points.iter().any(|(x, y)| {
                !x.is_finite()
                    || !y.is_finite()
                    || *x < 0.0
                    || *y < 0.0
                    || *x > state.width_px as f32
                    || *y > state.height_px as f32
            }) {
                return Err(EngineError::InvalidCommand(
                    "panel mask vertices must be finite and inside the document".into(),
                ));
            }
            let min_x = points
                .iter()
                .map(|(x, _)| x.floor() as u32)
                .min()
                .unwrap_or(0);
            let min_y = points
                .iter()
                .map(|(_, y)| y.floor() as u32)
                .min()
                .unwrap_or(0);
            let max_x = points
                .iter()
                .map(|(x, _)| x.ceil() as u32)
                .max()
                .unwrap_or(0)
                .min(state.width_px.saturating_sub(1));
            let max_y = points
                .iter()
                .map(|(_, y)| y.ceil() as u32)
                .max()
                .unwrap_or(0)
                .min(state.height_px.saturating_sub(1));
            let area = usize::try_from(max_x.saturating_sub(min_x).saturating_add(1))
                .ok()
                .and_then(|width| {
                    usize::try_from(max_y.saturating_sub(min_y).saturating_add(1))
                        .ok()
                        .and_then(|height| width.checked_mul(height))
                })
                .ok_or_else(|| EngineError::InvalidCommand("panel mask bounds overflow".into()))?;
            if area > MAX_PANEL_MASK_PIXELS {
                return Err(EngineError::InvalidCommand(
                    "panel mask rasterization exceeds the safety limit".into(),
                ));
            }
            let mask_state = state
                .layers
                .get_mut(mask)
                .ok_or(EngineError::InvalidLayer)?;
            if mask_state.layer.kind != LayerKind::Mask {
                return Err(EngineError::InvalidCommand(
                    "panel mask geometry requires a mask layer".into(),
                ));
            }
            let mut dirty = mask_state.tiles.allocated_coordinates();
            mask_state.tiles.clear();
            for y in min_y..=max_y {
                for x in min_x..=max_x {
                    if point_inside_polygon(x as f32 + 0.5, y as f32 + 0.5, points) {
                        dirty.push(mask_state.tiles.set_pixel(
                            x,
                            y,
                            Rgba8 {
                                r: 255,
                                g: 255,
                                b: 255,
                                a: 255,
                            },
                        ));
                    }
                }
            }
            dirty.sort_unstable_by_key(|coordinate| (coordinate.y, coordinate.x));
            dirty.dedup();
            advance_revision(state)?;
            state.events.push(EngineEvent::TilesDirty {
                revision: state.revision,
                tiles: dirty
                    .iter()
                    .copied()
                    .map(|coordinate| TileDescriptor {
                        layer: *mask,
                        coordinate,
                    })
                    .collect(),
            });
            state.events.push(EngineEvent::CompositeTilesDirty {
                revision: state.revision,
                tiles: dirty,
            });
        }
        EditorCommand::CreatePanelLayerTree {
            panel,
            panel_group,
            mask,
            sketch,
            ink,
            color,
            tone,
            effects,
        } => {
            let ids = [*panel_group, *mask, *sketch, *ink, *color, *tone, *effects];
            if panel.0 == 0
                || ids.iter().any(|id| id.0 == 0)
                || ids.contains(panel)
                || (0..ids.len()).any(|index| ids[index + 1..].contains(&ids[index]))
            {
                return Err(EngineError::InvalidCommand(
                    "panel layer tree IDs must be non-zero and unique".into(),
                ));
            }
            let present = ids
                .iter()
                .filter(|id| state.layers.contains_key(id))
                .count();
            if present == ids.len() {
                // Replaying a migration or reopening an already materialized
                // panel is intentionally idempotent. Do not append a second
                // layer tree or a redundant history entry.
                let group = state
                    .layers
                    .get(panel_group)
                    .ok_or(EngineError::InvalidLayer)?;
                let expected = [
                    (*sketch, LayerKind::Raster),
                    (*ink, LayerKind::Raster),
                    (*color, LayerKind::Raster),
                    (*tone, LayerKind::Tone),
                    (*effects, LayerKind::Raster),
                    (*mask, LayerKind::Mask),
                ];
                if group.layer.kind != LayerKind::PanelGroup
                    || group.layer.parent.is_some()
                    || expected.iter().enumerate().any(|(index, (id, kind))| {
                        state.layers.get(id).is_none_or(|child| {
                            child.layer.parent != Some(*panel_group)
                                || child.layer.kind != *kind
                                || child.layer.order != u32::try_from(index).unwrap_or(u32::MAX)
                        })
                    })
                {
                    return Err(EngineError::InvalidCommand(
                        "panel layer IDs already belong to an incompatible layer tree".into(),
                    ));
                }
                return Ok(state.revision);
            }
            if present != 0 {
                return Err(EngineError::InvalidCommand(
                    "panel layer tree IDs partially exist; refusing a non-atomic repair".into(),
                ));
            }
            if state.layers.len().saturating_add(ids.len()) > MAX_LAYERS {
                return Err(EngineError::InvalidCommand(
                    "document layer safety limit reached".into(),
                ));
            }
            let root_order = state
                .layers
                .values()
                .filter(|candidate| candidate.layer.parent.is_none())
                .count();
            let mut new_layers = Vec::with_capacity(ids.len());
            let definitions = [
                (*panel_group, None, 0, LayerKind::PanelGroup, "Panel"),
                (*sketch, Some(*panel_group), 0, LayerKind::Raster, "Sketch"),
                (*ink, Some(*panel_group), 1, LayerKind::Raster, "Ink"),
                (*color, Some(*panel_group), 2, LayerKind::Raster, "Color"),
                (*tone, Some(*panel_group), 3, LayerKind::Tone, "Tone"),
                (
                    *effects,
                    Some(*panel_group),
                    4,
                    LayerKind::Raster,
                    "Effects",
                ),
                (*mask, Some(*panel_group), 5, LayerKind::Mask, "Panel Mask"),
            ];
            for (id, parent, child_order, kind, name) in definitions {
                let mut layer = Layer::new(id, kind, name);
                layer.parent = parent;
                layer.order = if parent.is_none() {
                    u32::try_from(root_order).unwrap_or(u32::MAX)
                } else {
                    child_order
                };
                new_layers.push(LayerState {
                    layer,
                    tiles: TileStore::default(),
                    vectors: Vec::new(),
                });
            }
            for layer in new_layers {
                state.layers.insert(layer.layer.id, layer);
            }
            validate_layer_tree(&state.layers)?;
            advance_revision(state)?;
            state.events.push(EngineEvent::LayersChanged {
                revision: state.revision,
            });
        }
        EditorCommand::AddLayer { parent, kind } => {
            if state.layers.len() >= MAX_LAYERS {
                return Err(EngineError::InvalidCommand(
                    "document layer safety limit reached".into(),
                ));
            }
            if let Some(parent) = parent
                && !state.layers.contains_key(parent)
            {
                return Err(EngineError::InvalidLayer);
            }
            if *kind == LayerKind::Adjustment
                && parent.is_some_and(|parent| {
                    !state
                        .layers
                        .get(&parent)
                        .is_some_and(|layer| layer.layer.kind == LayerKind::Group)
                })
            {
                return Err(EngineError::InvalidCommand(
                    "nested adjustment layers require a group parent".into(),
                ));
            }
            let id = next_layer_id(&state.layers)?;
            let mut layer = Layer::new(id, *kind, format!("Layer {}", id.0));
            if *kind == LayerKind::Adjustment {
                layer.adjustment = Some(ink_model::LayerAdjustment::BrightnessContrast {
                    brightness: 0,
                    contrast: 0,
                });
            }
            layer.parent = *parent;
            layer.order = u32::try_from(
                state
                    .layers
                    .values()
                    .filter(|candidate| candidate.layer.parent == *parent)
                    .count(),
            )
            .unwrap_or(u32::MAX);
            state.layers.insert(
                id,
                LayerState {
                    layer,
                    tiles: TileStore::default(),
                    vectors: Vec::new(),
                },
            );
            advance_revision(state)?;
            state.events.push(EngineEvent::LayersChanged {
                revision: state.revision,
            });
        }
        EditorCommand::DeleteLayer { layer } => {
            if state.layers.len() <= 1 {
                return Err(EngineError::InvalidCommand(
                    "a document must keep at least one layer".into(),
                ));
            }
            let root = state.layers.get(layer).ok_or(EngineError::InvalidLayer)?;
            if root.layer.kind == LayerKind::PanelGroup {
                return Err(EngineError::InvalidCommand(
                    "comic panel groups must be removed through the comic workspace".into(),
                ));
            }
            let removed_parent = root.layer.parent;
            let mut subtree = vec![*layer];
            let mut cursor = 0;
            while cursor < subtree.len() {
                let parent = subtree[cursor];
                let children = state
                    .layers
                    .values()
                    .filter(|candidate| candidate.layer.parent == Some(parent))
                    .map(|candidate| candidate.layer.id)
                    .collect::<Vec<_>>();
                if !children.is_empty() && state.layers[&parent].layer.kind != LayerKind::Group {
                    return Err(EngineError::InvalidCommand(
                        "only ordinary groups can be deleted with their children".into(),
                    ));
                }
                for child in children {
                    if !subtree.contains(&child) {
                        subtree.push(child);
                    }
                }
                cursor += 1;
            }
            if let Some(comic_bytes) = &state.comic_json {
                let project = ink_comic::ComicProject::from_json(comic_bytes).map_err(|error| {
                    EngineError::InvalidCommand(format!(
                        "cannot validate comic layer ownership: {error}"
                    ))
                })?;
                let bound_layers = project
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
                    .collect::<HashSet<_>>();
                if subtree.iter().any(|id| bound_layers.contains(id)) {
                    return Err(EngineError::InvalidCommand(
                        "comic-owned layers must be removed through the comic workspace".into(),
                    ));
                }
            }
            for removed in subtree {
                state.layers.remove(&removed);
            }
            // Removing a subtree leaves compact sibling ordering at the
            // surviving parent, preserving deterministic composition/reopen.
            normalize_sibling_orders(&mut state.layers, removed_parent);
            advance_revision(state)?;
            state.events.push(EngineEvent::LayersChanged {
                revision: state.revision,
            });
        }
        EditorCommand::DuplicateLayer { source, duplicate } => {
            if state.layers.len() >= MAX_LAYERS {
                return Err(EngineError::InvalidCommand(
                    "document layer safety limit reached".into(),
                ));
            }
            if state.layers.contains_key(duplicate) || next_layer_id(&state.layers)? != *duplicate {
                return Err(EngineError::InvalidCommand(
                    "duplicate layer ID is not the next available ID".into(),
                ));
            }
            let source_state = state.layers.get(source).ok_or(EngineError::InvalidLayer)?;
            if source_state.layer.kind == LayerKind::PanelGroup {
                return Err(EngineError::InvalidCommand(
                    "comic panel groups must be duplicated through the comic workspace".into(),
                ));
            }
            if state
                .layers
                .values()
                .any(|candidate| candidate.layer.parent == Some(*source))
            {
                return Err(EngineError::InvalidCommand(
                    "only leaf layers can be duplicated".into(),
                ));
            }
            if let Some(comic_bytes) = &state.comic_json {
                let project = ink_comic::ComicProject::from_json(comic_bytes).map_err(|error| {
                    EngineError::InvalidCommand(format!(
                        "cannot validate comic layer ownership: {error}"
                    ))
                })?;
                if project.panel_layers.iter().any(|binding| {
                    [
                        binding.panel_group_id,
                        binding.mask_layer_id,
                        binding.sketch_layer_id,
                        binding.ink_layer_id,
                        binding.color_layer_id,
                        binding.tone_layer_id,
                        binding.effects_layer_id,
                    ]
                    .contains(&source.0)
                }) {
                    return Err(EngineError::InvalidCommand(
                        "comic-owned layers must be duplicated through the comic workspace".into(),
                    ));
                }
            }
            let parent = source_state.layer.parent;
            let mut duplicate_state = source_state.clone();
            duplicate_state.layer.id = *duplicate;
            duplicate_state.layer.name = format!("{} Copy", source_state.layer.name);
            let dirty_tiles = duplicate_state
                .tiles
                .tiles()
                .into_iter()
                .map(|(coordinate, _)| coordinate)
                .collect::<Vec<_>>();
            state.layers.insert(*duplicate, duplicate_state);
            let mut siblings = state
                .layers
                .values()
                .filter(|candidate| {
                    candidate.layer.parent == parent && candidate.layer.id != *duplicate
                })
                .map(|candidate| (candidate.layer.order, candidate.layer.id))
                .collect::<Vec<_>>();
            siblings.sort_unstable();
            let mut ordered = Vec::with_capacity(siblings.len());
            for (_, id) in siblings {
                ordered.push(id);
                if id == *source {
                    ordered.push(*duplicate);
                }
            }
            for (order, id) in ordered.into_iter().enumerate() {
                if let Some(layer) = state.layers.get_mut(&id) {
                    layer.layer.order = u32::try_from(order).unwrap_or(u32::MAX);
                }
            }
            advance_revision(state)?;
            state.events.push(EngineEvent::LayersChanged {
                revision: state.revision,
            });
            if !dirty_tiles.is_empty() {
                state.events.push(EngineEvent::TilesDirty {
                    revision: state.revision,
                    tiles: dirty_tiles
                        .into_iter()
                        .map(|coordinate| TileDescriptor {
                            layer: *duplicate,
                            coordinate,
                        })
                        .collect(),
                });
            }
        }
        EditorCommand::DuplicateLayerSubtree { source, duplicates } => {
            if duplicates.is_empty()
                || state.layers.len().saturating_add(duplicates.len()) > MAX_LAYERS
            {
                return Err(EngineError::InvalidCommand(
                    "document layer safety limit reached".into(),
                ));
            }
            let source_ids = layer_subtree_ids(&state.layers, *source)?;
            let source_state = state.layers.get(source).ok_or(EngineError::InvalidLayer)?;
            if source_state.layer.kind != LayerKind::Group {
                return Err(EngineError::InvalidCommand(
                    "only ordinary groups can be duplicated as a subtree".into(),
                ));
            }
            if source_ids.len() != duplicates.len()
                || source_ids
                    .iter()
                    .zip(duplicates)
                    .any(|(expected, (actual, _))| expected != actual)
            {
                return Err(EngineError::InvalidCommand(
                    "duplicate subtree mapping does not match source hierarchy".into(),
                ));
            }
            let mut remap = HashMap::with_capacity(duplicates.len());
            let mut expected_id = next_layer_id(&state.layers)?.0;
            for (old, new) in duplicates {
                if state.layers.contains_key(new)
                    || expected_id != new.0
                    || remap.insert(*old, *new).is_some()
                {
                    return Err(EngineError::InvalidCommand(
                        "duplicate layer ID is not the next available ID".into(),
                    ));
                }
                expected_id = expected_id.checked_add(1).ok_or_else(|| {
                    EngineError::InvalidCommand("layer ID space exhausted".into())
                })?;
            }
            if source_ids
                .iter()
                .any(|id| state.layers[id].layer.kind == LayerKind::PanelGroup)
            {
                return Err(EngineError::InvalidCommand(
                    "comic panel groups must be duplicated through the comic workspace".into(),
                ));
            }
            if let Some(comic_bytes) = &state.comic_json {
                let project = ink_comic::ComicProject::from_json(comic_bytes).map_err(|error| {
                    EngineError::InvalidCommand(format!(
                        "cannot validate comic layer ownership: {error}"
                    ))
                })?;
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
                    .map(LayerId::from_u128)
                    .collect::<HashSet<_>>();
                if source_ids.iter().any(|id| bound.contains(id)) {
                    return Err(EngineError::InvalidCommand(
                        "comic-owned layers must be duplicated through the comic workspace".into(),
                    ));
                }
            }
            let parent = source_state.layer.parent;
            let mut copies = Vec::with_capacity(duplicates.len());
            for (index, (old, new)) in duplicates.iter().enumerate() {
                let mut copy = state.layers[old].clone();
                copy.layer.id = *new;
                copy.layer.parent = copy
                    .layer
                    .parent
                    .map(|id| remap.get(&id).copied().unwrap_or(id));
                if index == 0 {
                    copy.layer.name = format!("{} Copy", copy.layer.name);
                }
                copies.push((*new, copy));
            }
            let dirty = copies
                .iter()
                .flat_map(|(id, layer)| {
                    layer
                        .tiles
                        .tiles()
                        .into_iter()
                        .map(move |(coordinate, _)| TileDescriptor {
                            layer: *id,
                            coordinate,
                        })
                })
                .collect::<Vec<_>>();
            for (id, layer) in copies {
                state.layers.insert(id, layer);
            }
            let duplicate_root = duplicates[0].1;
            let mut siblings = state
                .layers
                .values()
                .filter(|candidate| {
                    candidate.layer.parent == parent && candidate.layer.id != duplicate_root
                })
                .map(|candidate| (candidate.layer.order, candidate.layer.id))
                .collect::<Vec<_>>();
            siblings.sort_unstable();
            let mut ordered = Vec::with_capacity(siblings.len() + 1);
            for (_, id) in siblings {
                ordered.push(id);
                if id == *source {
                    ordered.push(duplicate_root);
                }
            }
            for (order, id) in ordered.into_iter().enumerate() {
                if let Some(layer) = state.layers.get_mut(&id) {
                    layer.layer.order = u32::try_from(order).unwrap_or(u32::MAX);
                }
            }
            advance_revision(state)?;
            state.events.push(EngineEvent::LayersChanged {
                revision: state.revision,
            });
            if !dirty.is_empty() {
                state.events.push(EngineEvent::TilesDirty {
                    revision: state.revision,
                    tiles: dirty,
                });
            }
        }
        EditorCommand::MergeLayers { target, source } => {
            let dirty = merge_raster_layers(state, *target, *source)?;
            advance_revision(state)?;
            state.events.push(EngineEvent::LayersChanged {
                revision: state.revision,
            });
            if !dirty.is_empty() {
                state.events.push(EngineEvent::TilesDirty {
                    revision: state.revision,
                    tiles: dirty
                        .into_iter()
                        .map(|coordinate| TileDescriptor {
                            layer: *target,
                            coordinate,
                        })
                        .collect(),
                });
            }
        }
        EditorCommand::SetLayerOpacity { layer, opacity } => {
            let layer_state = state
                .layers
                .get_mut(layer)
                .ok_or(EngineError::InvalidLayer)?;
            layer_state.layer.opacity = *opacity;
            advance_revision(state)?;
            state.events.push(EngineEvent::LayersChanged {
                revision: state.revision,
            });
        }
        EditorCommand::SetLayerVisibility { layer, visible } => {
            let layer_state = state
                .layers
                .get_mut(layer)
                .ok_or(EngineError::InvalidLayer)?;
            layer_state.layer.visible = *visible;
            advance_revision(state)?;
            state.events.push(EngineEvent::LayersChanged {
                revision: state.revision,
            });
        }
        EditorCommand::SetLayerBlendMode { layer, mode } => {
            let layer_state = state
                .layers
                .get_mut(layer)
                .ok_or(EngineError::InvalidLayer)?;
            layer_state.layer.blend_mode = *mode;
            advance_revision(state)?;
            state.events.push(EngineEvent::LayersChanged {
                revision: state.revision,
            });
        }
        EditorCommand::SetLayerGroupMode { layer, mode } => {
            let layer_state = state
                .layers
                .get_mut(layer)
                .ok_or(EngineError::InvalidLayer)?;
            if !matches!(
                layer_state.layer.kind,
                LayerKind::Group | LayerKind::PanelGroup
            ) {
                return Err(EngineError::InvalidCommand(
                    "group compositing mode requires a group layer".into(),
                ));
            }
            if *mode == ink_model::LayerGroupMode::PassThrough && layer_state.layer.clipping {
                return Err(EngineError::InvalidCommand(
                    "pass-through groups cannot be clipped to the layer below".into(),
                ));
            }
            layer_state.layer.group_mode = *mode;
            advance_revision(state)?;
            state.events.push(EngineEvent::LayersChanged {
                revision: state.revision,
            });
        }
        EditorCommand::SetLayerAlphaLock { layer, enabled } => {
            let layer_state = state
                .layers
                .get_mut(layer)
                .ok_or(EngineError::InvalidLayer)?;
            layer_state.layer.alpha_lock = *enabled;
            advance_revision(state)?;
            state.events.push(EngineEvent::LayersChanged {
                revision: state.revision,
            });
        }
        EditorCommand::SetLayerClipping { layer, enabled } => {
            let layer_state = state
                .layers
                .get_mut(layer)
                .ok_or(EngineError::InvalidLayer)?;
            if *enabled
                && matches!(
                    layer_state.layer.kind,
                    LayerKind::Group | LayerKind::PanelGroup
                )
                && layer_state.layer.group_mode == ink_model::LayerGroupMode::PassThrough
            {
                return Err(EngineError::InvalidCommand(
                    "pass-through groups cannot be clipped to the layer below".into(),
                ));
            }
            layer_state.layer.clipping = *enabled;
            advance_revision(state)?;
            state.events.push(EngineEvent::LayersChanged {
                revision: state.revision,
            });
        }
        EditorCommand::SetLayerReference { layer, enabled } => {
            let layer_state = state
                .layers
                .get_mut(layer)
                .ok_or(EngineError::InvalidLayer)?;
            layer_state.layer.reference = *enabled;
            advance_revision(state)?;
            state.events.push(EngineEvent::LayersChanged {
                revision: state.revision,
            });
        }
        EditorCommand::SetLayerLabel { layer, label } => {
            let layer_state = state
                .layers
                .get_mut(layer)
                .ok_or(EngineError::InvalidLayer)?;
            layer_state.layer.label = *label;
            advance_revision(state)?;
            state.events.push(EngineEvent::LayersChanged {
                revision: state.revision,
            });
        }
        EditorCommand::SetLayerName { layer, name } => {
            if name.len() > 1024 {
                return Err(EngineError::InvalidCommand(
                    "layer name exceeds the safety limit".into(),
                ));
            }
            let layer_state = state
                .layers
                .get_mut(layer)
                .ok_or(EngineError::InvalidLayer)?;
            layer_state.layer.name.clone_from(name);
            advance_revision(state)?;
            state.events.push(EngineEvent::LayersChanged {
                revision: state.revision,
            });
        }
        EditorCommand::SetLayerAdjustment { layer, adjustment } => {
            let adjustment = adjustment
                .validate()
                .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
            let layer_state = state
                .layers
                .get_mut(layer)
                .ok_or(EngineError::InvalidLayer)?;
            if layer_state.layer.kind != LayerKind::Adjustment {
                return Err(EngineError::InvalidCommand(
                    "adjustment settings require an adjustment layer".into(),
                ));
            }
            layer_state.layer.adjustment = Some(adjustment);
            advance_revision(state)?;
            state.events.push(EngineEvent::LayersChanged {
                revision: state.revision,
            });
        }
        EditorCommand::TransformLayer {
            layer,
            a,
            b,
            c,
            d,
            tx,
            ty,
        } => {
            let width_px = state.width_px;
            let height_px = state.height_px;
            let layer_state = state
                .layers
                .get_mut(layer)
                .ok_or(EngineError::InvalidLayer)?;
            if layer_state.layer.kind != LayerKind::Raster {
                return Err(EngineError::InvalidCommand(
                    "affine transforms currently require a raster layer".into(),
                ));
            }
            let dirty = layer_state
                .tiles
                .transform_affine(width_px, height_px, *a, *b, *c, *d, *tx, *ty)
                .map_err(|error| {
                    EngineError::InvalidCommand(format!("invalid transform: {error:?}"))
                })?;
            advance_revision(state)?;
            if !dirty.is_empty() {
                state.events.push(EngineEvent::TilesDirty {
                    revision: state.revision,
                    tiles: dirty
                        .into_iter()
                        .map(|coordinate| TileDescriptor {
                            layer: *layer,
                            coordinate,
                        })
                        .collect(),
                });
            }
        }
        EditorCommand::FillRegion {
            layer,
            x,
            y,
            color,
            tolerance,
            gap,
        } => {
            let pixel_count = usize::try_from(state.width_px)
                .ok()
                .and_then(|width| {
                    usize::try_from(state.height_px)
                        .ok()
                        .and_then(|height| width.checked_mul(height))
                })
                .ok_or_else(|| EngineError::InvalidCommand("fill dimensions overflow".into()))?;
            if pixel_count > MAX_FILL_PIXELS {
                return Err(EngineError::InvalidCommand(
                    "bucket fill is disabled for documents above the memory safety limit".into(),
                ));
            }
            if *x >= state.width_px || *y >= state.height_px {
                return Err(EngineError::InvalidCommand(
                    "bucket fill origin is outside the canvas".into(),
                ));
            }
            let target_layer = state.layers.get(layer).ok_or(EngineError::InvalidLayer)?;
            if target_layer.layer.kind != LayerKind::Raster {
                return Err(EngineError::InvalidCommand(
                    "bucket fill currently requires a raster layer".into(),
                ));
            }
            let width = state.width_px;
            let height = state.height_px;
            // A marked reference layer supplies the flood-fill sample image,
            // while the target layer remains the only layer that is mutated.
            // This mirrors illustration-app reference-fill behavior without
            // duplicating document pixels in Dart. If no reference layer is
            // marked, preserve the traditional current-layer behavior.
            let sample_layers = state
                .layers
                .values()
                .filter(|candidate| {
                    candidate.layer.visible
                        && candidate.layer.reference
                        && matches!(
                            candidate.layer.kind,
                            LayerKind::Raster | LayerKind::VectorInk
                        )
                })
                .map(|candidate| candidate.layer.id)
                .collect::<Vec<_>>();
            let sample_layers = if sample_layers.is_empty() {
                vec![*layer]
            } else {
                sample_layers
            };
            let mut pixels = Vec::with_capacity(pixel_count);
            for py in 0..height {
                for px in 0..width {
                    let mut composite = ink_model::Rgba8::default();
                    for sample_layer in &sample_layers {
                        let candidate = state
                            .layers
                            .get(sample_layer)
                            .ok_or(EngineError::InvalidLayer)?;
                        let pixel = candidate.tiles.sample_pixel(px, py);
                        let source = [pixel.r, pixel.g, pixel.b, pixel.a];
                        let mode = compositor_blend_mode(candidate.layer.blend_mode);
                        let blended = ink_compositor::blend_rgba8(
                            [composite.r, composite.g, composite.b, composite.a],
                            source,
                            candidate.layer.opacity,
                            mode,
                        );
                        composite = ink_model::Rgba8 {
                            r: blended[0],
                            g: blended[1],
                            b: blended[2],
                            a: blended[3],
                        };
                    }
                    pixels.push(composite);
                }
            }
            let mut mask = SelectionMask::flood_fill(
                &pixels,
                width,
                height,
                *x,
                *y,
                *tolerance,
                (*gap).min(4),
            )
            .map_err(|error| EngineError::InvalidCommand(format!("fill mask failed: {error}")))?;
            if let Some(selection) = &state.selection {
                for (value, selected) in mask.values.iter_mut().zip(&selection.values) {
                    *value = (*value).min(*selected);
                }
            }
            let layer_state = state
                .layers
                .get_mut(layer)
                .ok_or(EngineError::InvalidLayer)?;
            let mut dirty = HashSet::new();
            for py in 0..height {
                for px in 0..width {
                    if mask.get(px, py) != 0 {
                        dirty.insert(layer_state.tiles.set_pixel(px, py, *color));
                    }
                }
            }
            advance_revision(state)?;
            let mut dirty = dirty.into_iter().collect::<Vec<_>>();
            dirty.sort_unstable_by_key(|coordinate| (coordinate.y, coordinate.x));
            if !dirty.is_empty() {
                state.events.push(EngineEvent::TilesDirty {
                    revision: state.revision,
                    tiles: dirty
                        .into_iter()
                        .map(|coordinate| TileDescriptor {
                            layer: *layer,
                            coordinate,
                        })
                        .collect(),
                });
            }
        }
        EditorCommand::GradientFill {
            layer,
            x,
            y,
            start_x,
            start_y,
            end_x,
            end_y,
            from,
            to,
            tolerance,
            gap,
            expansion,
            paint_inside,
            paint_unfilled,
        } => {
            let pixel_count = usize::try_from(state.width_px)
                .ok()
                .and_then(|width| {
                    usize::try_from(state.height_px)
                        .ok()
                        .and_then(|height| width.checked_mul(height))
                })
                .ok_or_else(|| EngineError::InvalidCommand("fill dimensions overflow".into()))?;
            if pixel_count > MAX_FILL_PIXELS {
                return Err(EngineError::InvalidCommand(
                    "gradient fill is disabled for documents above the memory safety limit".into(),
                ));
            }
            if *x >= state.width_px || *y >= state.height_px {
                return Err(EngineError::InvalidCommand(
                    "gradient fill origin is outside the canvas".into(),
                ));
            }
            if [*start_x, *start_y, *end_x, *end_y]
                .iter()
                .any(|value| !value.is_finite())
            {
                return Err(EngineError::InvalidCommand(
                    "gradient endpoints must be finite".into(),
                ));
            }
            let target = state.layers.get(layer).ok_or(EngineError::InvalidLayer)?;
            if target.layer.kind != LayerKind::Raster {
                return Err(EngineError::InvalidCommand(
                    "gradient fill currently requires a raster layer".into(),
                ));
            }
            let width = state.width_px;
            let height = state.height_px;
            let sample_layers = state
                .layers
                .values()
                .filter(|candidate| {
                    candidate.layer.visible
                        && candidate.layer.reference
                        && matches!(
                            candidate.layer.kind,
                            LayerKind::Raster | LayerKind::VectorInk
                        )
                })
                .map(|candidate| candidate.layer.id)
                .collect::<Vec<_>>();
            let sample_layers = if sample_layers.is_empty() {
                vec![*layer]
            } else {
                sample_layers
            };
            let mut sample_pixels = Vec::with_capacity(pixel_count);
            for py in 0..height {
                for px in 0..width {
                    let mut composite = ink_model::Rgba8::default();
                    for sample_layer in &sample_layers {
                        let candidate = state
                            .layers
                            .get(sample_layer)
                            .ok_or(EngineError::InvalidLayer)?;
                        let pixel = candidate.tiles.sample_pixel(px, py);
                        let blended = ink_compositor::blend_rgba8(
                            [composite.r, composite.g, composite.b, composite.a],
                            [pixel.r, pixel.g, pixel.b, pixel.a],
                            candidate.layer.opacity,
                            compositor_blend_mode(candidate.layer.blend_mode),
                        );
                        composite = ink_model::Rgba8 {
                            r: blended[0],
                            g: blended[1],
                            b: blended[2],
                            a: blended[3],
                        };
                    }
                    sample_pixels.push(composite);
                }
            }
            let base_pixels = (0..height)
                .flat_map(|py| (0..width).map(move |px| (px, py)))
                .map(|(px, py)| target.tiles.sample_pixel(px, py))
                .collect::<Vec<_>>();
            let mut mask = if *paint_inside {
                SelectionMask::from_opacity(&base_pixels, width, height, 1)
            } else {
                SelectionMask::flood_fill(
                    &sample_pixels,
                    width,
                    height,
                    *x,
                    *y,
                    *tolerance,
                    (*gap).min(4),
                )
            }
            .map_err(|error| {
                EngineError::InvalidCommand(format!("gradient mask failed: {error}"))
            })?;
            if *paint_unfilled {
                for (value, pixel) in mask.values.iter_mut().zip(&base_pixels) {
                    if pixel.a != 0 {
                        *value = 0;
                    }
                }
            }
            mask.expand((*expansion).min(16));
            if let Some(selection) = &state.selection {
                for (value, selected) in mask.values.iter_mut().zip(&selection.values) {
                    *value = ((u16::from(*value) * u16::from(*selected)) / 255) as u8;
                }
            }
            let gradient = mask
                .gradient_fill(
                    &base_pixels,
                    (*start_x, *start_y),
                    (*end_x, *end_y),
                    *from,
                    *to,
                )
                .map_err(|error| {
                    EngineError::InvalidCommand(format!("gradient fill failed: {error}"))
                })?;
            let layer_state = state
                .layers
                .get_mut(layer)
                .ok_or(EngineError::InvalidLayer)?;
            let mut dirty = HashSet::new();
            for py in 0..height {
                for px in 0..width {
                    if mask.get(px, py) != 0 {
                        dirty.insert(layer_state.tiles.set_pixel(
                            px,
                            py,
                            gradient[usize::try_from(py * width + px).unwrap_or(0)],
                        ));
                    }
                }
            }
            advance_revision(state)?;
            let mut dirty = dirty.into_iter().collect::<Vec<_>>();
            dirty.sort_unstable_by_key(|coordinate| (coordinate.y, coordinate.x));
            if !dirty.is_empty() {
                state.events.push(EngineEvent::TilesDirty {
                    revision: state.revision,
                    tiles: dirty
                        .into_iter()
                        .map(|coordinate| TileDescriptor {
                            layer: *layer,
                            coordinate,
                        })
                        .collect(),
                });
            }
        }
        EditorCommand::PerspectiveLayer { layer, target } => {
            let width_px = state.width_px;
            let height_px = state.height_px;
            let layer_state = state
                .layers
                .get_mut(layer)
                .ok_or(EngineError::InvalidLayer)?;
            if layer_state.layer.kind != LayerKind::Raster {
                return Err(EngineError::InvalidCommand(
                    "perspective transforms currently require a raster layer".into(),
                ));
            }
            let dirty = layer_state
                .tiles
                .transform_perspective(width_px, height_px, *target)
                .map_err(|error| {
                    EngineError::InvalidCommand(format!("invalid perspective transform: {error:?}"))
                })?;
            advance_revision(state)?;
            if !dirty.is_empty() {
                state.events.push(EngineEvent::TilesDirty {
                    revision: state.revision,
                    tiles: dirty
                        .into_iter()
                        .map(|coordinate| TileDescriptor {
                            layer: *layer,
                            coordinate,
                        })
                        .collect(),
                });
            }
        }
        EditorCommand::MeshLayer {
            layer,
            columns,
            rows,
            points,
        } => {
            let width_px = state.width_px;
            let height_px = state.height_px;
            let layer_state = state
                .layers
                .get_mut(layer)
                .ok_or(EngineError::InvalidLayer)?;
            if layer_state.layer.kind != LayerKind::Raster {
                return Err(EngineError::InvalidCommand(
                    "mesh transforms currently require a raster layer".into(),
                ));
            }
            let dirty = layer_state
                .tiles
                .transform_mesh(width_px, height_px, *columns, *rows, points)
                .map_err(|error| {
                    EngineError::InvalidCommand(format!("invalid mesh transform: {error:?}"))
                })?;
            advance_revision(state)?;
            if !dirty.is_empty() {
                state.events.push(EngineEvent::TilesDirty {
                    revision: state.revision,
                    tiles: dirty
                        .into_iter()
                        .map(|coordinate| TileDescriptor {
                            layer: *layer,
                            coordinate,
                        })
                        .collect(),
                });
            }
        }
        EditorCommand::LiquifyLayer {
            layer,
            center_x,
            center_y,
            radius,
            strength,
            mode,
            direction_x,
            direction_y,
        } => {
            let width_px = state.width_px;
            let height_px = state.height_px;
            let layer_state = state
                .layers
                .get_mut(layer)
                .ok_or(EngineError::InvalidLayer)?;
            if layer_state.layer.kind != LayerKind::Raster {
                return Err(EngineError::InvalidCommand(
                    "liquify transforms currently require a raster layer".into(),
                ));
            }
            let dirty = layer_state
                .tiles
                .transform_liquify(
                    width_px,
                    height_px,
                    *center_x,
                    *center_y,
                    *radius,
                    *strength,
                    *mode,
                    *direction_x,
                    *direction_y,
                )
                .map_err(|error| {
                    EngineError::InvalidCommand(format!("invalid liquify transform: {error:?}"))
                })?;
            advance_revision(state)?;
            if !dirty.is_empty() {
                state.events.push(EngineEvent::TilesDirty {
                    revision: state.revision,
                    tiles: dirty
                        .into_iter()
                        .map(|coordinate| TileDescriptor {
                            layer: *layer,
                            coordinate,
                        })
                        .collect(),
                });
            }
        }
        EditorCommand::AddVectorStroke {
            layer,
            stroke,
            points,
            closed,
        } => {
            if state.active_stroke.is_some() {
                return Err(EngineError::InvalidCommand(
                    "finish or cancel the active stroke before adding vector ink".into(),
                ));
            }
            let width_px = state.width_px;
            let height_px = state.height_px;
            let layer_state = state
                .layers
                .get_mut(layer)
                .ok_or(EngineError::InvalidLayer)?;
            if layer_state.layer.kind != LayerKind::VectorInk {
                return Err(EngineError::InvalidCommand(
                    "vector strokes require a vector-ink layer".into(),
                ));
            }
            if layer_state.vectors.iter().any(|(id, _)| id == stroke) {
                return Err(EngineError::InvalidCommand(
                    "vector stroke ID already exists on this layer".into(),
                ));
            }
            let vector = VectorStroke {
                points: points
                    .iter()
                    .map(|(x, y, pressure, tilt)| VectorPoint {
                        x: *x,
                        y: *y,
                        pressure: *pressure,
                        tilt: *tilt,
                    })
                    .collect(),
                closed: *closed,
            };
            validate_vector_stroke(
                &vector,
                DocumentSpec {
                    width_px: state.width_px,
                    height_px: state.height_px,
                    dpi: 1.0,
                    color_space: ink_model::ColorSpace::Srgb,
                    background: ink_model::Rgba8::default(),
                },
            )?;
            let dirty =
                rasterize_vector_stroke(&mut layer_state.tiles, &vector, width_px, height_px);
            layer_state.vectors.push((*stroke, vector));
            advance_revision(state)?;
            state.events.push(EngineEvent::LayersChanged {
                revision: state.revision,
            });
            if !dirty.is_empty() {
                state.events.push(EngineEvent::TilesDirty {
                    revision: state.revision,
                    tiles: dirty
                        .into_iter()
                        .map(|coordinate| TileDescriptor {
                            layer: *layer,
                            coordinate,
                        })
                        .collect(),
                });
            }
        }
        EditorCommand::TransformVectorStroke {
            layer,
            stroke,
            a,
            b,
            c,
            d,
            tx,
            ty,
        } => {
            if [*a, *b, *c, *d, *tx, *ty]
                .iter()
                .any(|value| !value.is_finite())
                || (*a * *d - *b * *c).abs() < 0.000_001
            {
                return Err(EngineError::InvalidCommand(
                    "vector transform must be finite and invertible".into(),
                ));
            }
            let width_px = state.width_px;
            let height_px = state.height_px;
            let layer_state = state
                .layers
                .get_mut(layer)
                .ok_or(EngineError::InvalidLayer)?;
            if layer_state.layer.kind != LayerKind::VectorInk {
                return Err(EngineError::InvalidCommand(
                    "vector transform requires a vector-ink layer".into(),
                ));
            }
            let vector = layer_state
                .vectors
                .iter_mut()
                .find(|(id, _)| id == stroke)
                .map(|(_, vector)| vector)
                .ok_or_else(|| {
                    EngineError::InvalidCommand("vector stroke does not exist".into())
                })?;
            vector.transform(ink_tools::Affine2D {
                a: *a,
                b: *b,
                c: *c,
                d: *d,
                tx: *tx,
                ty: *ty,
            });
            validate_vector_stroke(
                vector,
                DocumentSpec {
                    width_px,
                    height_px,
                    dpi: 1.0,
                    color_space: ink_model::ColorSpace::Srgb,
                    background: ink_model::Rgba8::default(),
                },
            )?;
            let dirty = rebuild_vector_layer(layer_state, width_px, height_px);
            advance_revision(state)?;
            state.events.push(EngineEvent::TilesDirty {
                revision: state.revision,
                tiles: dirty
                    .into_iter()
                    .map(|coordinate| TileDescriptor {
                        layer: *layer,
                        coordinate,
                    })
                    .collect(),
            });
        }
        EditorCommand::SimplifyVectorStroke {
            layer,
            stroke,
            tolerance,
        } => {
            if !tolerance.is_finite() || *tolerance <= 0.0 || *tolerance > 256.0 {
                return Err(EngineError::InvalidCommand(
                    "vector simplify tolerance is outside limits".into(),
                ));
            }
            let width_px = state.width_px;
            let height_px = state.height_px;
            let layer_state = state
                .layers
                .get_mut(layer)
                .ok_or(EngineError::InvalidLayer)?;
            let vector = layer_state
                .vectors
                .iter_mut()
                .find(|(id, _)| id == stroke)
                .map(|(_, vector)| vector)
                .ok_or_else(|| {
                    EngineError::InvalidCommand("vector stroke does not exist".into())
                })?;
            *vector = vector.simplify(*tolerance);
            validate_vector_stroke(
                vector,
                DocumentSpec {
                    width_px,
                    height_px,
                    dpi: 1.0,
                    color_space: ink_model::ColorSpace::Srgb,
                    background: ink_model::Rgba8::default(),
                },
            )?;
            let dirty = rebuild_vector_layer(layer_state, width_px, height_px);
            advance_revision(state)?;
            state.events.push(EngineEvent::TilesDirty {
                revision: state.revision,
                tiles: dirty
                    .into_iter()
                    .map(|coordinate| TileDescriptor {
                        layer: *layer,
                        coordinate,
                    })
                    .collect(),
            });
        }
        EditorCommand::ConnectVectorStrokes {
            layer,
            first,
            second,
            tolerance,
        } => {
            if !tolerance.is_finite() || *tolerance < 0.0 || *tolerance > 256.0 || first == second {
                return Err(EngineError::InvalidCommand(
                    "vector connection is invalid".into(),
                ));
            }
            let width_px = state.width_px;
            let height_px = state.height_px;
            let layer_state = state
                .layers
                .get_mut(layer)
                .ok_or(EngineError::InvalidLayer)?;
            let first_index = layer_state
                .vectors
                .iter()
                .position(|(id, _)| id == first)
                .ok_or_else(|| {
                    EngineError::InvalidCommand("first vector stroke does not exist".into())
                })?;
            let second_index = layer_state
                .vectors
                .iter()
                .position(|(id, _)| id == second)
                .ok_or_else(|| {
                    EngineError::InvalidCommand("second vector stroke does not exist".into())
                })?;
            let joined = layer_state.vectors[first_index]
                .1
                .connect(&layer_state.vectors[second_index].1, *tolerance)
                .ok_or_else(|| {
                    EngineError::InvalidCommand(
                        "vector endpoints exceed connection tolerance".into(),
                    )
                })?;
            layer_state.vectors[first_index].1 = joined;
            layer_state.vectors.remove(second_index);
            let dirty = rebuild_vector_layer(layer_state, width_px, height_px);
            advance_revision(state)?;
            state.events.push(EngineEvent::TilesDirty {
                revision: state.revision,
                tiles: dirty
                    .into_iter()
                    .map(|coordinate| TileDescriptor {
                        layer: *layer,
                        coordinate,
                    })
                    .collect(),
            });
        }
        EditorCommand::EraseVectorSegment {
            layer,
            stroke,
            center_x,
            center_y,
            radius,
        } => {
            if [*center_x, *center_y, *radius]
                .iter()
                .any(|value| !value.is_finite())
                || *radius <= 0.0
                || *radius > 4096.0
            {
                return Err(EngineError::InvalidCommand(
                    "vector erase radius is outside limits".into(),
                ));
            }
            let width_px = state.width_px;
            let height_px = state.height_px;
            let layer_state = state
                .layers
                .get_mut(layer)
                .ok_or(EngineError::InvalidLayer)?;
            let index = layer_state
                .vectors
                .iter()
                .position(|(id, _)| id == stroke)
                .ok_or_else(|| {
                    EngineError::InvalidCommand("vector stroke does not exist".into())
                })?;
            let (_, original) = layer_state.vectors[index].clone();
            let pieces = original.erase_segment((*center_x, *center_y), *radius);
            layer_state.vectors.remove(index);
            let mut next_id = layer_state
                .vectors
                .iter()
                .map(|(id, _)| id.0)
                .max()
                .unwrap_or(0)
                .saturating_add(1);
            for (piece_index, piece) in pieces.into_iter().enumerate() {
                let id = if piece_index == 0 {
                    *stroke
                } else {
                    let value = next_id;
                    next_id = next_id.saturating_add(1);
                    ink_model::StrokeId::from_u128(value)
                };
                layer_state.vectors.push((id, piece));
            }
            let dirty = rebuild_vector_layer(layer_state, width_px, height_px);
            advance_revision(state)?;
            state.events.push(EngineEvent::TilesDirty {
                revision: state.revision,
                tiles: dirty
                    .into_iter()
                    .map(|coordinate| TileDescriptor {
                        layer: *layer,
                        coordinate,
                    })
                    .collect(),
            });
        }
        EditorCommand::SetVectorPoint {
            layer,
            stroke,
            index,
            x,
            y,
            pressure,
            tilt,
        } => {
            if [*x, *y, *pressure, *tilt]
                .iter()
                .any(|value| !value.is_finite())
                || *x < 0.0
                || *y < 0.0
                || *x > state.width_px as f32
                || *y > state.height_px as f32
                || !(0.0..=1.0).contains(pressure)
            {
                return Err(EngineError::InvalidCommand(
                    "vector control point is outside limits".into(),
                ));
            }
            let width_px = state.width_px;
            let height_px = state.height_px;
            let layer_state = state
                .layers
                .get_mut(layer)
                .ok_or(EngineError::InvalidLayer)?;
            if layer_state.layer.kind != LayerKind::VectorInk {
                return Err(EngineError::InvalidCommand(
                    "vector control points require a vector-ink layer".into(),
                ));
            }
            let vector = layer_state
                .vectors
                .iter_mut()
                .find(|(id, _)| id == stroke)
                .map(|(_, vector)| vector)
                .ok_or_else(|| {
                    EngineError::InvalidCommand("vector stroke does not exist".into())
                })?;
            let point_index = usize::try_from(*index).unwrap_or(usize::MAX);
            let previous = *vector.points.get(point_index).ok_or_else(|| {
                EngineError::InvalidCommand("vector control point does not exist".into())
            })?;
            vector.points[point_index] = VectorPoint {
                x: *x,
                y: *y,
                pressure: *pressure,
                tilt: *tilt,
            };
            if let Err(error) = validate_vector_stroke(
                vector,
                DocumentSpec {
                    width_px,
                    height_px,
                    dpi: 1.0,
                    color_space: ink_model::ColorSpace::Srgb,
                    background: ink_model::Rgba8::default(),
                },
            ) {
                vector.points[point_index] = previous;
                return Err(error);
            }
            let dirty = rebuild_vector_layer(layer_state, width_px, height_px);
            advance_revision(state)?;
            state.events.push(EngineEvent::TilesDirty {
                revision: state.revision,
                tiles: dirty
                    .into_iter()
                    .map(|coordinate| TileDescriptor {
                        layer: *layer,
                        coordinate,
                    })
                    .collect(),
            });
        }
        EditorCommand::BeginStroke {
            stroke,
            layer,
            brush,
        } => {
            let layer_state = state.layers.get(layer).ok_or(EngineError::InvalidLayer)?;
            if !matches!(layer_state.layer.kind, LayerKind::Raster | LayerKind::Mask) {
                return Err(EngineError::InvalidCommand(
                    "strokes require a raster or mask layer".into(),
                ));
            }
            let preset = BrushPreset::starters()
                .into_iter()
                .find(|candidate| candidate.id == *brush)
                .unwrap_or_else(|| BrushPreset::starters()[0]);
            let compiled_brush = if let Some(override_preset) = state.brush_overrides.get(brush) {
                Some(
                    override_preset
                        .compile()
                        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?,
                )
            } else if brush.0 > 5 {
                Some(
                    builtin_library()
                        .into_iter()
                        .find(|candidate| candidate.id == *brush)
                        .ok_or_else(|| EngineError::InvalidCommand("unknown Phase 2 brush".into()))?
                        .compile()
                        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?,
                )
            } else {
                None
            };
            state.active_stroke = Some(ActiveStroke {
                stroke: *stroke,
                layer: layer_state.layer.id,
                brush: preset,
                compiled_brush,
                compiled_brush_state: CompiledBrushState::default(),
                samples: Vec::new(),
                last_confirmed_sample: None,
                input_metrics: StrokeInputMetrics::default(),
                sample_history_complete: true,
                last_input_sample: None,
                stopped_at_page_edge: false,
                legacy_resample_anchor: None,
                legacy_rendered_dabs: 0,
                legacy_segment_dabs: 0,
                work_segments: 0,
                compiled_rendered_dabs: 0,
                compiled_cpu_tile_updates: 0,
                cpu_tile_updates: 0,
                compiled_dab_last_position: None,
                compiled_dab_path_length: 0.0,
                compiled_dab_max_step: 0.0,
                preview_tiles: TileStore::default(),
                preview_eraser: false,
                work_limit_reached: false,
            });
            advance_revision(state)?;
        }
        EditorCommand::EndStroke { stroke } => {
            if state.active_stroke.as_ref().map(|active| active.stroke) != Some(*stroke) {
                return Err(EngineError::InvalidCommand("stroke is not active".into()));
            }
            if state
                .active_stroke
                .as_ref()
                .is_some_and(|active| active.work_limit_reached)
            {
                return Err(EngineError::InvalidCommand(format!(
                    "stroke_work_limit_reached: confirmed input could not be continued safely (stroke={})",
                    stroke.0,
                )));
            }
            let deferred_dual_dirty = if state
                .active_stroke
                .as_ref()
                .is_some_and(|active| active.work_limit_reached)
            {
                Vec::new()
            } else {
                flush_deferred_dual_dabs(state, *stroke)?
            };
            let Some(active) = state.active_stroke.as_ref() else {
                return Err(EngineError::InvalidCommand("stroke is not active".into()));
            };
            let metrics = &active.input_metrics;
            let path_start = metrics.path_start;
            let path_end = metrics.path_end;
            let (min_x, min_y, max_x, max_y) = metrics.bounds.unwrap_or((
                f32::INFINITY,
                f32::INFINITY,
                f32::NEG_INFINITY,
                f32::NEG_INFINITY,
            ));
            let (min_pressure, max_pressure) = metrics
                .pressure_range
                .unwrap_or((f32::INFINITY, f32::NEG_INFINITY));
            let direct_length = path_start.zip(path_end).map_or(0.0, |(start, end)| {
                f64::from(end.canvas_x - start.canvas_x)
                    .hypot(f64::from(end.canvas_y - start.canvas_y))
            });
            eprintln!(
                "Project Ink Pencil diagnostic: Rust end samples={} pathStart=({:.1},{:.1}) pathEnd=({:.1},{:.1}) bounds=({:.1},{:.1})-({:.1},{:.1}) pathLength={:.1} directLength={:.1} pressure={:.3}..{:.3} compiledDabs={} dabTravel={:.1} dabMaxStep={:.2} cpuTilesWritten={} compiledCpuTileUpdates={} legacyDabs={} workSegments={} workLimit={} rustPageEdge={}",
                metrics.sample_count,
                path_start.map_or(0.0, |sample| sample.canvas_x),
                path_start.map_or(0.0, |sample| sample.canvas_y),
                path_end.map_or(0.0, |sample| sample.canvas_x),
                path_end.map_or(0.0, |sample| sample.canvas_y),
                min_x,
                min_y,
                max_x,
                max_y,
                metrics.path_length,
                direct_length,
                min_pressure,
                max_pressure,
                active.compiled_rendered_dabs,
                active.compiled_dab_path_length,
                active.compiled_dab_max_step,
                active.cpu_tile_updates,
                active.compiled_cpu_tile_updates,
                active.legacy_rendered_dabs,
                active.work_segments,
                active.work_limit_reached,
                active.stopped_at_page_edge,
            );
            if !active.sample_history_complete {
                eprintln!(
                    "Project Ink stroke optional history segmented: stroke={} retainedSamples={} totalSamples={} postEffects=unavailable timeLapse=omitted",
                    active.stroke.0,
                    active.samples.len(),
                    active.input_metrics.sample_count,
                );
            }
            let preview_dirty = (active.layer, active.preview_tiles.allocated_coordinates());
            let post_effects = active
                .compiled_brush
                .as_ref()
                .map(|brush| brush.post_effects.to_vec())
                .unwrap_or_default();
            let post_effect_padding = active
                .compiled_brush
                .as_ref()
                .map_or(1, CompiledBrush::post_effect_padding_px);
            let post_effect_samples = if active.sample_history_complete {
                active.samples.clone()
            } else {
                Vec::new()
            };
            // Time-lapse is an optional, bounded side recording. Reaching its
            // limit must never reject EndStroke: pixels are already committed
            // incrementally, and leaving the active transaction open here
            // makes later brush changes appear to lose artwork.
            let time_lapse_stroke = active
                .sample_history_complete
                .then(|| time_lapse_has_capacity(&state.time_lapse, post_effect_samples.len()))
                .unwrap_or(false)
                .then(|| TimeLapseStroke {
                    revision: state.revision.saturating_add(1),
                    layer: active.layer.0,
                    brush: active
                        .compiled_brush
                        .as_ref()
                        .map_or(active.brush.id.0, |brush| brush.source_id.0),
                    samples: active
                        .samples
                        .iter()
                        .map(|sample| TimeLapseSample {
                            x: sample.canvas_x,
                            y: sample.canvas_y,
                            pressure: sample.pressure,
                            tilt: (sample.tilt_x, sample.tilt_y),
                            azimuth: sample.azimuth,
                            twist: sample.twist,
                            timestamp_ns: sample.timestamp_ns,
                        })
                        .collect(),
                });
            let mut post_dirty = Vec::new();
            if !post_effects.is_empty() && !post_effect_samples.is_empty() {
                let selection = state.selection.clone();
                let width_px = state.width_px;
                let height_px = state.height_px;
                let layer = state
                    .layers
                    .get_mut(&preview_dirty.0)
                    .ok_or(EngineError::InvalidLayer)?;
                post_dirty = apply_post_effects(
                    &mut layer.tiles,
                    &post_effects,
                    &post_effect_samples,
                    post_effect_padding,
                    selection.as_ref(),
                    width_px,
                    height_px,
                )?;
            }
            if let Some(time_lapse_stroke) = time_lapse_stroke {
                // Capacity is checked above; if the recording validator ever
                // becomes stricter, preserve the document edit and omit only
                // the optional recording entry.
                let _ = state.time_lapse.push(time_lapse_stroke);
            }
            state.active_stroke = None;
            advance_revision(state)?;
            if !post_dirty.is_empty() {
                state.events.push(EngineEvent::TilesDirty {
                    revision: state.revision,
                    tiles: post_dirty
                        .into_iter()
                        .map(|coordinate| TileDescriptor {
                            layer: preview_dirty.0,
                            coordinate,
                        })
                        .collect(),
                });
            }
            let mut stroke_dirty = preview_dirty.1;
            stroke_dirty.extend(deferred_dual_dirty);
            stroke_dirty.sort_unstable_by_key(|coordinate| (coordinate.y, coordinate.x));
            stroke_dirty.dedup();
            if !stroke_dirty.is_empty() {
                state.events.push(EngineEvent::TilesDirty {
                    revision: state.revision,
                    tiles: stroke_dirty
                        .into_iter()
                        .map(|coordinate| TileDescriptor {
                            layer: preview_dirty.0,
                            coordinate,
                        })
                        .collect(),
                });
            }
        }
        EditorCommand::CancelStroke { stroke } => {
            if state.active_stroke.as_ref().map(|active| active.stroke) != Some(*stroke) {
                return Err(EngineError::InvalidCommand("stroke is not active".into()));
            }
            lock_recover(&state.live_dabs).remove_stroke(stroke.0);
            state.active_stroke = None;
            if let Some(previous) = state.undo_states.pop() {
                state.layers = previous;
                state.history.discard_last();
                state.redo_states.clear();
            }
            advance_revision(state)?;
            state.events.push(EngineEvent::LayersChanged {
                revision: state.revision,
            });
        }
        EditorCommand::Undo => {
            if let Some(edit) = state.brush_undo.take() {
                restore_brush_override(state, &edit.brush_id, edit.previous_override.clone());
                state.brush_redo = Some(edit);
                advance_revision(state)?;
                state.events.push(EngineEvent::DocumentChanged {
                    revision: state.revision,
                });
            } else if let Some(previous) = state.undo_states.pop() {
                let current = std::mem::replace(&mut state.layers, previous);
                state.redo_states.push(current);
                trim_history_snapshots(&mut state.redo_states);
                state.history.undo();
                advance_revision(state)?;
                state.events.push(EngineEvent::LayersChanged {
                    revision: state.revision,
                });
            } else {
                return Ok(state.revision);
            }
        }
        EditorCommand::Redo => {
            if let Some(edit) = state.brush_redo.take() {
                restore_brush_override(state, &edit.brush_id, edit.current_override.clone());
                state.brush_undo = Some(edit);
                advance_revision(state)?;
                state.events.push(EngineEvent::DocumentChanged {
                    revision: state.revision,
                });
            } else if let Some(next) = state.redo_states.pop() {
                let current = std::mem::replace(&mut state.layers, next);
                state.undo_states.push(current);
                trim_history_snapshots(&mut state.undo_states);
                state.history.redo();
                advance_revision(state)?;
                state.events.push(EngineEvent::LayersChanged {
                    revision: state.revision,
                });
            } else {
                return Ok(state.revision);
            }
        }
        EditorCommand::MoveLayer {
            layer,
            parent,
            index,
        } => {
            if !state.layers.contains_key(layer) {
                return Err(EngineError::InvalidLayer);
            }
            if let Some(parent) = parent {
                if !state.layers.contains_key(parent) {
                    return Err(EngineError::InvalidLayer);
                }
                if parent == layer {
                    return Err(EngineError::InvalidCommand(
                        "a layer cannot be its own parent".into(),
                    ));
                }
                let mut current = Some(*parent);
                while let Some(current_id) = current {
                    if current_id == *layer {
                        return Err(EngineError::InvalidCommand(
                            "cannot move a layer below one of its descendants".into(),
                        ));
                    }
                    current = state
                        .layers
                        .get(&current_id)
                        .and_then(|candidate| candidate.layer.parent);
                }
            }
            let old_parent = state
                .layers
                .get(layer)
                .ok_or(EngineError::InvalidLayer)?
                .layer
                .parent;
            // Preserve the relative order of all unaffected siblings, then
            // insert the moved node at the requested bounded index.
            let mut target_siblings = state
                .layers
                .values()
                .filter(|candidate| {
                    candidate.layer.parent == *parent && candidate.layer.id != *layer
                })
                .map(|candidate| (candidate.layer.order, candidate.layer.id))
                .collect::<Vec<_>>();
            target_siblings.sort_unstable();
            let insertion = usize::try_from(*index)
                .unwrap_or(usize::MAX)
                .min(target_siblings.len());
            target_siblings.insert(insertion, (u32::MAX, *layer));
            if let Some(layer_state) = state.layers.get_mut(layer) {
                layer_state.layer.parent = *parent;
            }
            for (order, (_, sibling_id)) in target_siblings.into_iter().enumerate() {
                if let Some(sibling) = state.layers.get_mut(&sibling_id) {
                    sibling.layer.order = u32::try_from(order).unwrap_or(u32::MAX);
                }
            }
            if old_parent != *parent {
                normalize_sibling_orders(&mut state.layers, old_parent);
            }
            advance_revision(state)?;
            state.events.push(EngineEvent::LayersChanged {
                revision: state.revision,
            });
        }
    }
    if let Some(before_layers) = before_layers {
        state.undo_states.push(before_layers);
        trim_history_snapshots(&mut state.undo_states);
        state.redo_states.clear();
    }
    state.journal.push(encode_command(&command));
    if !matches!(
        command,
        EditorCommand::Undo
            | EditorCommand::Redo
            | EditorCommand::EndStroke { .. }
            | EditorCommand::CancelStroke { .. }
    ) {
        state.history.push(Transaction {
            label: history_label(&command),
            command,
        });
    }
    state.events.push(EngineEvent::DocumentChanged {
        revision: state.revision,
    });
    state.events.push(EngineEvent::HistoryChanged {
        revision: state.revision,
        cursor: u32::try_from(state.history.undo_transactions().len()).unwrap_or(u32::MAX),
    });
    Ok(state.revision)
}

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
        | EditorCommand::DuplicateLayer { .. }
        | EditorCommand::DuplicateLayerSubtree { .. }
        | EditorCommand::CreatePanelLayerTree { .. } => "layer",
        EditorCommand::MergeLayers { .. } => "merge",
        EditorCommand::MoveLayer { .. } => "reorder",
        EditorCommand::SetLayerName { .. } => "rename",
        EditorCommand::SetLayerAdjustment { .. } => "adjustment",
        EditorCommand::SetLayerVisibility { .. } => "visibility",
        EditorCommand::SetLayerOpacity { .. } => "opacity",
        EditorCommand::SetLayerBlendMode { .. } => "blend_mode",
        EditorCommand::SetLayerGroupMode { .. } => "group_mode",
        EditorCommand::SetLayerAlphaLock { .. }
        | EditorCommand::SetLayerClipping { .. }
        | EditorCommand::SetLayerReference { .. }
        | EditorCommand::SetLayerLabel { .. } => "layer_property",
        EditorCommand::SetPanelMaskGeometry { .. } => "panel",
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
        EditorCommand::DuplicateLayer { .. } => "Duplicate layer".into(),
        EditorCommand::DuplicateLayerSubtree { .. } => "Duplicate group".into(),
        EditorCommand::MergeLayers { .. } => "Merge layers".into(),
        EditorCommand::MoveLayer { .. } => "Reorder layer".into(),
        EditorCommand::CreatePanelLayerTree { .. } => "Create panel layers".into(),
        EditorCommand::SetPanelMaskGeometry { .. } => "Edit panel geometry".into(),
        EditorCommand::SetLayerOpacity { .. } => "Change layer opacity".into(),
        EditorCommand::SetLayerVisibility { .. } => "Change layer visibility".into(),
        EditorCommand::SetLayerBlendMode { .. } => "Change blend mode".into(),
        EditorCommand::SetLayerGroupMode { .. } => "Change group compositing".into(),
        EditorCommand::SetLayerAlphaLock { .. } => "Change alpha lock".into(),
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
    let curve = preset
        .dynamics
        .iter()
        .find(|binding| {
            binding.sensor == SensorId::Pressure && binding.target == ParameterId::Diameter
        })
        .map_or_else(
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

impl Document {
    /// Start a temporary, Rust-owned brush edit transaction. Drafts are not
    /// visible to stroke capture until committed and are discarded on close.
    pub fn begin_brush_draft(&mut self, brush_id: BrushId) -> Result<u64, EngineError> {
        self.flush_input()?;
        let mut state = lock_recover(&self.state);
        if state.active_stroke.is_some() {
            return Err(EngineError::InvalidCommand(
                "finish or cancel the active stroke before editing a brush".into(),
            ));
        }
        let exists = state.brush_overrides.contains_key(&brush_id)
            || builtin_library().iter().any(|preset| preset.id == brush_id);
        if !exists {
            return Err(EngineError::InvalidCommand("unknown Phase 2 brush".into()));
        }
        let id = state.next_brush_draft;
        state.next_brush_draft = id.checked_add(1).ok_or_else(|| {
            EngineError::InvalidCommand("brush draft ID space is exhausted".into())
        })?;
        state.brush_drafts.insert(
            id,
            (
                brush_id,
                BrushDraftSettings {
                    diameter_px: 0.0,
                    opacity: 0.0,
                    spacing: 0.0,
                    smoothing: 0.0,
                    pressure_size: 0.0,
                    pressure_opacity: 0.0,
                    pressure_curve: 0.5,
                    hardness: 0.0,
                    texture_scale: 0.0,
                    scatter: 0.0,
                    rotation_jitter: 0.0,
                    smudge: 0.0,
                    wetness: 0.0,
                    pressure_curve_points: Vec::new(),
                },
            ),
        );
        Ok(id)
    }

    /// Replace the pending settings for a brush draft without touching the
    /// installed library. The complete settings vector is required so a
    /// commit cannot accidentally inherit stale UI state.
    #[allow(clippy::too_many_arguments)]
    pub fn update_brush_draft(
        &mut self,
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
        pressure_curve_points: &[f32],
    ) -> Result<(), EngineError> {
        let settings = BrushDraftSettings {
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
            pressure_curve_points: pressure_curve_points.to_vec(),
        };
        validate_brush_draft_settings(&settings)?;
        self.flush_input()?;
        let mut state = lock_recover(&self.state);
        let Some((_, draft)) = state.brush_drafts.get_mut(&draft_id) else {
            return Err(EngineError::InvalidCommand(
                "brush draft is not active".into(),
            ));
        };
        *draft = settings;
        Ok(())
    }

    /// Commit a complete brush draft as one library mutation.
    #[allow(clippy::too_many_lines)]
    pub fn commit_brush_draft(&mut self, draft_id: u64) -> Result<u64, EngineError> {
        let (brush_id, settings) = {
            let mut state = lock_recover(&self.state);
            let (brush_id, settings) = state
                .brush_drafts
                .remove(&draft_id)
                .ok_or_else(|| EngineError::InvalidCommand("brush draft is not active".into()))?;
            (brush_id, settings)
        };
        if let Err(error) = validate_brush_draft_settings(&settings) {
            let mut state = lock_recover(&self.state);
            state.brush_drafts.insert(draft_id, (brush_id, settings));
            return Err(error);
        }
        let result = self.update_brush_settings(
            brush_id,
            settings.diameter_px,
            settings.opacity,
            settings.spacing,
            settings.smoothing,
            settings.pressure_size,
            settings.pressure_opacity,
            0.5,
            settings.hardness,
            settings.texture_scale,
            settings.scatter,
            settings.rotation_jitter,
            settings.smudge,
            settings.wetness,
            &settings.pressure_curve_points,
        );
        match result {
            Ok(revision) => Ok(revision),
            Err(error) => {
                let mut state = lock_recover(&self.state);
                state.brush_drafts.insert(draft_id, (brush_id, settings));
                Err(error)
            }
        }
    }

    /// Discard a draft without changing document revision or brush state.
    pub fn cancel_brush_draft(&mut self, draft_id: u64) -> Result<(), EngineError> {
        self.flush_input()?;
        let mut state = lock_recover(&self.state);
        if state.brush_drafts.remove(&draft_id).is_none() {
            return Err(EngineError::InvalidCommand(
                "brush draft is not active".into(),
            ));
        }
        Ok(())
    }

    /// Update the bounded, pixel-affecting controls for a user brush copy.
    ///
    /// The edit is validated and stored in Rust before the next stroke can
    /// capture it. Active strokes retain their immutable compiled preset.
    #[allow(clippy::too_many_arguments)]
    pub fn update_brush_settings(
        &mut self,
        brush_id: BrushId,
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
        pressure_curve_points: &[f32],
    ) -> Result<u64, EngineError> {
        self.flush_input()?;
        if !diameter_px.is_finite()
            || !opacity.is_finite()
            || !spacing.is_finite()
            || !smoothing.is_finite()
            || !pressure_size.is_finite()
            || !pressure_opacity.is_finite()
            || !pressure_curve.is_finite()
            || !hardness.is_finite()
            || !texture_scale.is_finite()
            || !scatter.is_finite()
            || !rotation_jitter.is_finite()
            || !smudge.is_finite()
            || !wetness.is_finite()
            || !(0.25..=4096.0).contains(&diameter_px)
            || !(0.0..=1.0).contains(&opacity)
            || !(0.001..=1.0).contains(&spacing)
            || !(0.0..=1.0).contains(&smoothing)
            || !(0.0..=1.0).contains(&pressure_size)
            || !(0.0..=1.0).contains(&pressure_opacity)
            || !(0.0..=1.0).contains(&pressure_curve)
            || !(0.0..=1.0).contains(&hardness)
            || !(0.01..=64.0).contains(&texture_scale)
            || !(0.0..=1.0).contains(&scatter)
            || !(0.0..=1.0).contains(&rotation_jitter)
            || !(0.0..=1.0).contains(&smudge)
            || !(0.0..=1.0).contains(&wetness)
        {
            return Err(EngineError::InvalidCommand(
                "brush settings are outside the supported finite ranges".into(),
            ));
        }
        let mut state = lock_recover(&self.state);
        if state.active_stroke.is_some() {
            return Err(EngineError::InvalidCommand(
                "finish or cancel the active stroke before editing a brush".into(),
            ));
        }
        let previous_override = state.brush_overrides.get(&brush_id).cloned();
        let mut preset = previous_override
            .clone()
            .or_else(|| {
                builtin_library()
                    .into_iter()
                    .find(|candidate| candidate.id == brush_id)
            })
            .ok_or_else(|| EngineError::InvalidCommand("unknown Phase 2 brush".into()))?;
        preset.stroke.spacing = spacing;
        preset.stroke.smoothing = smoothing;
        let pressure_curve = ResponseCurve {
            points: decode_editor_curve(pressure_curve_points, pressure_curve)?,
        };
        for binding in &mut preset.dynamics {
            if binding.sensor == SensorId::Pressure && binding.target == ParameterId::Diameter {
                binding.amount = pressure_size;
            }
            if binding.sensor == SensorId::Pressure && binding.target == ParameterId::Opacity {
                binding.amount = pressure_opacity;
            }
            if binding.sensor == SensorId::Pressure {
                binding.curve = pressure_curve.clone();
            }
        }
        if !preset.dynamics.iter().any(|binding| {
            binding.sensor == SensorId::Pressure && binding.target == ParameterId::Diameter
        }) {
            preset.dynamics.push(ParameterBinding {
                target: ParameterId::Diameter,
                base: 1.0,
                sensor: SensorId::Pressure,
                curve: pressure_curve.clone(),
                amount: pressure_size,
                combine: CombineOp::Multiply,
            });
        }
        if !preset.dynamics.iter().any(|binding| {
            binding.sensor == SensorId::Pressure && binding.target == ParameterId::Opacity
        }) {
            preset.dynamics.push(ParameterBinding {
                target: ParameterId::Opacity,
                base: 1.0,
                sensor: SensorId::Pressure,
                curve: pressure_curve.clone(),
                amount: pressure_opacity,
                combine: CombineOp::Multiply,
            });
        }
        match &mut preset.tip {
            TipBehavior::Stamp(tip) => {
                tip.diameter_px = diameter_px;
                tip.editor_scatter = scatter;
                tip.density = (tip.density * (1.0 - scatter * 0.5)).clamp(0.01, 1.0);
                tip.angle_degrees = rotation_jitter * 180.0;
            }
            TipBehavior::Spray(tip) => {
                tip.diameter_px = diameter_px;
                tip.scatter = scatter;
            }
            TipBehavior::Ribbon(tip) => tip.width_px = diameter_px,
            TipBehavior::Bristle(tip) => {
                tip.diameter_px = diameter_px;
                tip.spread = (tip.spread + scatter * 0.25).clamp(0.0, 1.0);
                tip.lag = (tip.lag + smoothing * 0.25).clamp(0.0, 1.0);
            }
        }
        match &mut preset.tip {
            TipBehavior::Stamp(tip) => tip.hardness = hardness,
            TipBehavior::Spray(tip) => tip.hardness = hardness,
            TipBehavior::Ribbon(_) => {}
            TipBehavior::Bristle(tip) => tip.stiffness = hardness,
        }
        match &mut preset.paint {
            PaintBehavior::Solid(paint) => {
                paint.opacity = opacity;
                paint.flow = (1.0 - wetness * 0.5).clamp(0.01, 1.0);
            }
            PaintBehavior::Glaze(paint) => {
                paint.opacity = opacity;
                paint.flow = (1.0 - wetness * 0.5).clamp(0.01, 1.0);
            }
            PaintBehavior::Marker(paint) => {
                paint.opacity = opacity;
                paint.flow = (1.0 - wetness * 0.5).clamp(0.01, 1.0);
            }
            PaintBehavior::ColorPickup(paint) => {
                paint.opacity = opacity;
                paint.pickup = smudge;
                paint.blur = (smudge * 0.5).clamp(0.0, 1.0);
            }
            PaintBehavior::DigitalWatercolor(paint) => {
                paint.wash = opacity;
                paint.dilution = wetness;
                paint.pickup = smudge;
                paint.granulation = ((texture_scale - 0.01) / 63.99).clamp(0.0, 1.0);
            }
        }
        if let Some(grain) = &mut preset.grain {
            grain.scale = texture_scale;
            grain.depth = scatter;
        }
        preset
            .validate()
            .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
        state.brush_overrides.insert(brush_id, preset);
        let current_override = state.brush_overrides.get(&brush_id).cloned();
        state.brush_undo = Some(BrushEditUndo {
            brush_id,
            previous_override,
            current_override,
        });
        state.brush_redo = None;
        let revision = advance_revision(&mut state)?;
        state.events.push(EngineEvent::DocumentChanged { revision });
        Ok(revision)
    }

    /// Update the active color of a Rust-owned brush copy.
    ///
    /// Color changes are document-library mutations, so they are rejected
    /// during an active stroke and advance the same revision/event stream as
    /// other brush edits. The color remains part of the saved brush override.
    pub fn update_brush_color(
        &mut self,
        brush_id: BrushId,
        color: Rgba8,
    ) -> Result<u64, EngineError> {
        self.flush_input()?;
        let mut state = lock_recover(&self.state);
        if state.active_stroke.is_some() {
            return Err(EngineError::InvalidCommand(
                "finish or cancel the active stroke before editing a brush".into(),
            ));
        }
        let previous_override = state.brush_overrides.get(&brush_id).cloned();
        let mut preset = previous_override
            .clone()
            .or_else(|| {
                builtin_library()
                    .into_iter()
                    .find(|candidate| candidate.id == brush_id)
            })
            .ok_or_else(|| EngineError::InvalidCommand("unknown Phase 2 brush".into()))?;
        set_brush_paint_color(&mut preset.paint, color);
        preset
            .validate()
            .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
        state.brush_overrides.insert(brush_id, preset);
        let current_override = state.brush_overrides.get(&brush_id).cloned();
        state.brush_undo = Some(BrushEditUndo {
            brush_id,
            previous_override,
            current_override,
        });
        state.brush_redo = None;
        let revision = advance_revision(&mut state)?;
        state.events.push(EngineEvent::DocumentChanged { revision });
        Ok(revision)
    }

    /// Rename a user-owned brush copy without changing its rendering data.
    pub fn rename_brush(&mut self, brush_id: BrushId, name: &str) -> Result<u64, EngineError> {
        self.flush_input()?;
        let name = name.trim();
        if name.is_empty() || name.len() > 256 {
            return Err(EngineError::InvalidCommand(
                "brush name must contain 1 to 256 UTF-8 bytes".into(),
            ));
        }
        let mut state = lock_recover(&self.state);
        if state.active_stroke.is_some() {
            return Err(EngineError::InvalidCommand(
                "finish or cancel the active stroke before editing a brush".into(),
            ));
        }
        let previous_override = state.brush_overrides.get(&brush_id).cloned();
        let mut preset = previous_override.clone().ok_or_else(|| {
            EngineError::InvalidCommand("only duplicated or imported brushes can be renamed".into())
        })?;
        preset.metadata.name = name.to_owned();
        preset.revision = preset
            .revision
            .checked_add(1)
            .ok_or_else(|| EngineError::InvalidCommand("brush revision is exhausted".into()))?;
        preset
            .validate()
            .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
        state.brush_overrides.insert(brush_id, preset.clone());
        state.brush_undo = Some(BrushEditUndo {
            brush_id,
            previous_override,
            current_override: Some(preset),
        });
        state.brush_redo = None;
        let revision = advance_revision(&mut state)?;
        state.events.push(EngineEvent::DocumentChanged { revision });
        Ok(revision)
    }

    /// Export a Rust-owned brush preset without exposing its mutable state.
    pub fn export_brush(
        &mut self,
        brush_id: BrushId,
        destination: &std::path::Path,
    ) -> Result<(), EngineError> {
        self.flush_input()?;
        let state = lock_recover(&self.state);
        let preset = state
            .brush_overrides
            .get(&brush_id)
            .cloned()
            .or_else(|| {
                builtin_library()
                    .into_iter()
                    .find(|candidate| candidate.id == brush_id)
            })
            .ok_or_else(|| EngineError::InvalidCommand("unknown Phase 2 brush".into()))?;
        let resources = resource_hashes_for_preset(&preset)
            .into_iter()
            .map(|hash| {
                let resource = state.resources.get(&hash).ok_or_else(|| {
                    EngineError::InvalidCommand(
                        "brush references a resource that is not available".into(),
                    )
                })?;
                Ok(ink_brush::ImportedResource {
                    name: format!("{}.rgba", hex_hash(&hash)),
                    kind: resource.kind.clone(),
                    sha256: hash,
                    bytes: u64::try_from(resource.rgba8.len()).unwrap_or(u64::MAX),
                    data: resource.rgba8.clone(),
                    width: resource.width,
                    height: resource.height,
                })
            })
            .collect::<Result<Vec<_>, EngineError>>()?;
        ink_brush::export_inkbrush_with_resources(destination, &preset, &resources)
            .map_err(|error| EngineError::InvalidCommand(format!("brush export failed: {error}")))
    }

    /// Duplicate a built-in or imported preset into a new Rust-owned brush.
    /// The duplicate receives a fresh stable ID and participates in the same
    /// single-edit undo/redo boundary as other brush-library mutations.
    pub fn duplicate_brush(&mut self, brush_id: BrushId) -> Result<BrushId, EngineError> {
        self.flush_input()?;
        let mut state = lock_recover(&self.state);
        if state.active_stroke.is_some() {
            return Err(EngineError::InvalidCommand(
                "finish or cancel the active stroke before duplicating a brush".into(),
            ));
        }
        let mut preset = state
            .brush_overrides
            .get(&brush_id)
            .cloned()
            .or_else(|| {
                builtin_library()
                    .into_iter()
                    .find(|candidate| candidate.id == brush_id)
            })
            .ok_or_else(|| EngineError::InvalidCommand("unknown Phase 2 brush".into()))?;
        let duplicate_id = next_available_brush_id(&state)?;
        let suffix = " Copy";
        let mut name = String::new();
        for character in preset.metadata.name.chars() {
            if name
                .len()
                .saturating_add(character.len_utf8())
                .saturating_add(suffix.len())
                > 256
            {
                break;
            }
            name.push(character);
        }
        name.push_str(suffix);
        preset.id = duplicate_id;
        preset.revision = preset
            .revision
            .checked_add(1)
            .ok_or_else(|| EngineError::InvalidCommand("brush revision is exhausted".into()))?;
        preset.metadata.name = name;
        preset
            .validate()
            .map_err(|error| EngineError::InvalidCommand(error.to_string()))?;
        state.brush_overrides.insert(duplicate_id, preset.clone());
        state.brush_undo = Some(BrushEditUndo {
            brush_id: duplicate_id,
            previous_override: None,
            current_override: Some(preset),
        });
        state.brush_redo = None;
        let revision = advance_revision(&mut state)?;
        state.events.push(EngineEvent::DocumentChanged { revision });
        Ok(duplicate_id)
    }

    /// Convert and install a supported external brush into the Rust-owned
    /// document library. Guided reports without a decoded preset are rejected.
    pub fn import_brush(&mut self, source: &std::path::Path) -> Result<BrushId, EngineError> {
        self.import_brush_verified(source, None)
    }

    /// Convert and install a brush only if its content still matches the hash
    /// presented during the import report step. This closes path-based TOCTOU
    /// races without exposing source bytes to Flutter.
    pub fn import_brush_verified(
        &mut self,
        source: &std::path::Path,
        expected_sha256: Option<[u8; 32]>,
    ) -> Result<BrushId, EngineError> {
        self.flush_input()?;
        let report = ink_brush::import_external(source).map_err(|error| {
            EngineError::InvalidCommand(format!("brush import failed: {error}"))
        })?;
        if expected_sha256.is_some_and(|expected| expected != report.source_sha256) {
            return Err(EngineError::InvalidCommand(
                "brush source changed after compatibility inspection".into(),
            ));
        }
        let mut preset = report.preset.ok_or_else(|| {
            EngineError::InvalidCommand(
                "this source requires guided brush recreation and cannot be installed automatically"
                    .into(),
            )
        })?;
        let resources = report.resources;
        if resources.iter().any(|resource| resource.data.is_empty()) {
            return Err(EngineError::InvalidCommand(
                "imported brush resource has no decoded payload".into(),
            ));
        }
        preset.validate().map_err(|error| {
            EngineError::InvalidCommand(format!("imported brush validation failed: {error}"))
        })?;
        let mut state = lock_recover(&self.state);
        if state.active_stroke.is_some() {
            return Err(EngineError::InvalidCommand(
                "finish or cancel the active stroke before importing a brush".into(),
            ));
        }
        let next_id = state
            .brush_overrides
            .keys()
            .map(|id| id.0)
            .chain(1_u128..=12)
            .max()
            .and_then(|id| id.checked_add(1))
            .ok_or_else(|| EngineError::InvalidCommand("brush ID space is exhausted".into()))?;
        preset.id = BrushId::from_u128(next_id);
        let id = preset.id;
        if state.revision == u64::MAX {
            return Err(EngineError::InvalidCommand(
                "document revision is exhausted".into(),
            ));
        }
        let incoming_bytes = resources
            .iter()
            .filter(|resource| !state.resources.contains_key(&resource.sha256))
            .map(|resource| resource.data.len())
            .sum::<usize>();
        if resource_total_bytes(&state.resources).saturating_add(incoming_bytes)
            > MAX_DOCUMENT_RESOURCE_BYTES
        {
            return Err(EngineError::InvalidCommand(
                "brush resources exceed the document memory limit".into(),
            ));
        }
        for resource in resources {
            state
                .resources
                .entry(resource.sha256)
                .or_insert_with(|| BrushResource {
                    kind: resource.kind,
                    width: resource.width,
                    height: resource.height,
                    rgba8: resource.data,
                });
        }
        state.brush_overrides.insert(id, preset);
        let revision = advance_revision(&mut state)?;
        state.events.push(EngineEvent::DocumentChanged { revision });
        Ok(id)
    }

    /// Convert and install every member of a native brush pack as one
    /// transaction. A changed source or a single invalid member aborts the
    /// whole operation before the library is mutated.
    pub fn import_brush_pack_verified(
        &mut self,
        source: &std::path::Path,
        expected_sha256: Option<[u8; 32]>,
    ) -> Result<Vec<BrushId>, EngineError> {
        self.flush_input()?;
        let reports = ink_brush::import_inkbrushpack(source).map_err(|error| {
            EngineError::InvalidCommand(format!("brush pack import failed: {error}"))
        })?;
        self.install_imported_brush_reports(reports, expected_sha256, "brush pack")
    }

    /// Convert and install every `.kpp` member of a Krita bundle as one
    /// transaction. A changed source or a single invalid member aborts the
    /// whole operation before the library is mutated.
    pub fn import_krita_bundle_verified(
        &mut self,
        source: &std::path::Path,
        expected_sha256: Option<[u8; 32]>,
    ) -> Result<Vec<BrushId>, EngineError> {
        self.flush_input()?;
        let reports = ink_brush::import_krita_bundle(source).map_err(|error| {
            EngineError::InvalidCommand(format!("Krita bundle import failed: {error}"))
        })?;
        self.install_imported_brush_reports(reports, expected_sha256, "Krita bundle")
    }

    fn install_imported_brush_reports(
        &mut self,
        reports: Vec<ink_brush::BrushImportReport>,
        expected_sha256: Option<[u8; 32]>,
        source_label: &str,
    ) -> Result<Vec<BrushId>, EngineError> {
        if let Some(expected) = expected_sha256 {
            let actual = reports
                .first()
                .map(|report| report.source_sha256)
                .ok_or_else(|| EngineError::InvalidCommand(format!("{source_label} is empty")))?;
            if actual != expected {
                return Err(EngineError::InvalidCommand(format!(
                    "{source_label} source changed after compatibility inspection"
                )));
            }
        }
        let mut prepared = Vec::with_capacity(reports.len());
        for report in reports {
            let preset = report.preset.ok_or_else(|| {
                EngineError::InvalidCommand(format!("{source_label} member has no decoded preset"))
            })?;
            let resources = report.resources;
            if resources.iter().any(|resource| resource.data.is_empty()) {
                return Err(EngineError::InvalidCommand(format!(
                    "{source_label} resource has no decoded payload"
                )));
            }
            preset.validate().map_err(|error| {
                EngineError::InvalidCommand(format!("imported brush validation failed: {error}"))
            })?;
            prepared.push((preset, resources));
        }
        let mut state = lock_recover(&self.state);
        if state.active_stroke.is_some() {
            return Err(EngineError::InvalidCommand(
                "finish or cancel the active stroke before importing brushes".into(),
            ));
        }
        let next_id = state
            .brush_overrides
            .keys()
            .map(|id| id.0)
            .chain(1_u128..=12)
            .max()
            .and_then(|id| id.checked_add(1))
            .ok_or_else(|| EngineError::InvalidCommand("brush ID space is exhausted".into()))?;
        if state.revision == u64::MAX {
            return Err(EngineError::InvalidCommand(
                "document revision is exhausted".into(),
            ));
        }
        if next_id.checked_add(prepared.len() as u128).is_none() {
            return Err(EngineError::InvalidCommand(
                "brush ID space is exhausted".into(),
            ));
        }
        // A multi-member pack/bundle may legitimately share one decoded tip
        // or grain resource. Count each content hash once for the document
        // budget; installation below is already content-addressed and
        // deduplicates the same resource in the state map.
        let mut incoming_hashes = HashSet::new();
        let incoming_bytes = prepared
            .iter()
            .flat_map(|(_, resources)| resources.iter())
            .filter(|resource| !state.resources.contains_key(&resource.sha256))
            .filter(|resource| incoming_hashes.insert(resource.sha256))
            .map(|resource| resource.data.len())
            .sum::<usize>();
        if resource_total_bytes(&state.resources).saturating_add(incoming_bytes)
            > MAX_DOCUMENT_RESOURCE_BYTES
        {
            return Err(EngineError::InvalidCommand(format!(
                "{source_label} resources exceed the document memory limit"
            )));
        }
        let mut installed = Vec::with_capacity(prepared.len());
        for (index, (mut preset, resources)) in prepared.into_iter().enumerate() {
            for resource in resources {
                state
                    .resources
                    .entry(resource.sha256)
                    .or_insert_with(|| BrushResource {
                        kind: resource.kind,
                        width: resource.width,
                        height: resource.height,
                        rgba8: resource.data,
                    });
            }
            preset.id = BrushId::from_u128(next_id + index as u128);
            let id = preset.id;
            state.brush_overrides.insert(id, preset);
            installed.push(id);
        }
        let revision = advance_revision(&mut state)?;
        state.events.push(EngineEvent::DocumentChanged { revision });
        Ok(installed)
    }

    /// Return built-in and imported brush metadata in stable ID order.
    #[must_use]
    pub fn brush_summaries(&self) -> Vec<BrushSummaryProjection> {
        let _ = self.flush_input();
        let state = lock_recover(&self.state);
        let mut presets = builtin_library()
            .into_iter()
            .map(|preset| (preset.id, preset))
            .collect::<BTreeMap<_, _>>();
        for (id, preset) in &state.brush_overrides {
            presets.insert(*id, preset.clone());
        }
        presets
            .into_values()
            .map(|preset| brush_summary_projection(&preset))
            .collect()
    }

    /// Return bounded vector-stroke metadata for one vector layer.
    pub fn vector_stroke_summaries(
        &self,
        layer_id: LayerId,
    ) -> Result<Vec<VectorStrokeSummaryTuple>, EngineError> {
        let _ = self.flush_input();
        let state = lock_recover(&self.state);
        let layer = state
            .layers
            .get(&layer_id)
            .ok_or(EngineError::InvalidLayer)?;
        if layer.layer.kind != LayerKind::VectorInk {
            return Err(EngineError::InvalidCommand(
                "vector stroke summaries require a vector layer".into(),
            ));
        }
        Ok(layer
            .vectors
            .iter()
            .map(|(id, stroke)| {
                let mut bounds = [
                    f32::INFINITY,
                    f32::INFINITY,
                    f32::NEG_INFINITY,
                    f32::NEG_INFINITY,
                ];
                for point in &stroke.points {
                    bounds[0] = bounds[0].min(point.x);
                    bounds[1] = bounds[1].min(point.y);
                    bounds[2] = bounds[2].max(point.x);
                    bounds[3] = bounds[3].max(point.y);
                }
                (
                    *id,
                    u32::try_from(stroke.points.len()).unwrap_or(u32::MAX),
                    bounds,
                    stroke
                        .points
                        .iter()
                        .flat_map(|point| [point.x, point.y, point.pressure, point.tilt])
                        .collect(),
                )
            })
            .collect())
    }

    /// Consume a high-frequency packet and rasterize confirmed samples.
    pub fn push_pointer_packet(&mut self, bytes: &[u8]) -> Result<(), EngineError> {
        if bytes.len() > ink_input::MAX_PACKET_BYTES {
            return Err(EngineError::Packet(ink_input::PacketError::TrailingBytes));
        }
        self.worker.enqueue(bytes.to_vec())?;
        Ok(())
    }

    /// Drain Rust-generated ephemeral dabs for a live preview surface. The
    /// queue is not persisted and draining it cannot change document truth.
    pub fn drain_live_dabs(
        &mut self,
        limit: usize,
    ) -> Result<Vec<ink_live_render::LiveDab>, EngineError> {
        self.flush_input()?;
        self.drain_live_dabs_available(limit)
    }

    /// Drain dabs produced so far without waiting for CPU tile rasterization.
    /// The queue has its own lock so GPU presentation never contends with the
    /// document-state lock held by the authoritative renderer.
    pub fn drain_live_dabs_available(
        &self,
        limit: usize,
    ) -> Result<Vec<ink_live_render::LiveDab>, EngineError> {
        if limit > 65_536 {
            return Err(EngineError::InvalidCommand(
                "live dab drain exceeds the safety limit".into(),
            ));
        }
        Ok(lock_recover(&self.live_dabs).drain(limit))
    }

    /// Return and clear the number of confirmed live-preview dabs that could
    /// not be queued since the previous poll. This is a preview-health signal;
    /// it never indicates document loss because CPU rasterization has already
    /// committed the corresponding samples.
    pub fn take_live_dab_overflow_count(&mut self) -> Result<u64, EngineError> {
        self.flush_input()?;
        Ok(self.take_live_dab_overflow_count_available())
    }

    /// Read a best-effort preview health signal without waiting for the CPU
    /// renderer or acquiring the document-state lock.
    pub fn take_live_dab_overflow_count_available(&self) -> u64 {
        self.live_dab_overflow_count.swap(0, Ordering::AcqRel)
    }

    fn flush_input(&self) -> Result<(), EngineError> {
        self.worker.flush();
        if let Some(error) = self.worker.take_error() {
            return Err(EngineError::InvalidCommand(error));
        }
        Ok(())
    }
}

#[allow(clippy::too_many_arguments)]
fn render_dabs(
    tiles: &mut TileStore,
    dabs: &[Dab],
    preset: BrushPreset,
    selection: Option<&SelectionMask>,
    eraser: bool,
    preview_mask: bool,
    alpha_lock: bool,
    width_px: u32,
    height_px: u32,
) -> Vec<TileCoord> {
    let mut dirty = Vec::new();
    for dab in dabs.iter().copied() {
        let pressure = dab.pressure.clamp(0.0, 1.0);
        let radius = legacy_dab_radius(preset, pressure);
        let opacity_pressure = legacy_dab_opacity(preset, pressure);
        let min_x = ((dab.x - radius - 0.5).floor() as i64).max(0);
        let min_y = ((dab.y - radius - 0.5).floor() as i64).max(0);
        let max_x =
            ((dab.x + radius + 0.5).ceil() as i64).min(i64::from(width_px).saturating_sub(1));
        let max_y =
            ((dab.y + radius + 0.5).ceil() as i64).min(i64::from(height_px).saturating_sub(1));
        if min_x > max_x || min_y > max_y {
            continue;
        }
        for y in min_y..=max_y {
            for x in min_x..=max_x {
                let distance = (x as f32 - dab.x).hypot(y as f32 - dab.y);
                let coverage = (radius + 0.5 - distance).clamp(0.0, 1.0);
                if coverage > 0.0
                    && selection.is_none_or(|mask| mask.get(x as u32, y as u32) > 0)
                    && (!alpha_lock || tiles.sample_pixel(x as u32, y as u32).a != 0)
                {
                    let opacity =
                        (coverage * opacity_pressure * preset.opacity * f32::from(u16::MAX))
                            .clamp(0.0, f32::from(u16::MAX)) as u16;
                    let coord = if eraser && !preview_mask {
                        tiles.erase_pixel(x as u32, y as u32)
                    } else {
                        let color = if eraser {
                            ink_model::Rgba8 {
                                r: 255,
                                g: 255,
                                b: 255,
                                a: 255,
                            }
                        } else {
                            preset.color
                        };
                        tiles.blend_pixel(x as u32, y as u32, color, opacity)
                    };
                    if !dirty.contains(&coord) {
                        dirty.push(coord);
                    }
                }
            }
        }
    }
    dirty
}

fn legacy_dab_radius(preset: BrushPreset, pressure: f32) -> f32 {
    let pressure = pressure.clamp(0.0, 1.0);
    let diameter_scale = if preset.kind == ink_brush::BrushKind::TechnicalPen {
        // A narrow low-pressure start and a strong curved rise make changes
        // visible across the Pencil's working range, not only at maximum force.
        0.2 + 2.8 * pressure.powf(1.5)
    } else {
        1.0
    };
    (preset.diameter_px * diameter_scale * 0.5).max(0.5)
}

fn legacy_dab_opacity(preset: BrushPreset, pressure: f32) -> f32 {
    let pressure = pressure.clamp(0.0, 1.0);
    let pressure_opacity = if preset.kind == ink_brush::BrushKind::TechnicalPen {
        // Technical pens vary width with pressure, but remain opaque. Using
        // Pencil force for opacity made light Pencil strokes translucent and
        // visually strand-like compared with finger input.
        1.0
    } else {
        pressure
    };
    (pressure_opacity * preset.opacity).clamp(0.0, 1.0)
}

#[allow(clippy::too_many_arguments)]
fn render_brush_dabs(
    tiles: &mut TileStore,
    dabs: &[BrushDab],
    resources: &BTreeMap<[u8; 32], BrushResource>,
    selection: Option<&SelectionMask>,
    eraser: bool,
    preview_mask: bool,
    alpha_lock: bool,
    width_px: u32,
    height_px: u32,
) -> Vec<TileCoord> {
    let mut dirty = Vec::new();
    for dab in dabs.iter().copied() {
        let radius_x = dab.radius_x.max(0.25);
        let radius_y = dab.radius_y.max(0.25);
        let cx = dab.x.round() as i64;
        let cy = dab.y.round() as i64;
        let min_x = (cx - radius_x.ceil() as i64).max(0);
        let min_y = (cy - radius_y.ceil() as i64).max(0);
        let max_x = (cx + radius_x.ceil() as i64).min(i64::from(width_px).saturating_sub(1));
        let max_y = (cy + radius_y.ceil() as i64).min(i64::from(height_px).saturating_sub(1));
        if min_x > max_x || min_y > max_y {
            continue;
        }
        let normalized_angle = dab.angle;
        let (sin, cos) = normalized_angle.sin_cos();
        let center_sample = tiles.sample_pixel(cx.max(0) as u32, cy.max(0) as u32);
        let sampled = match dab.paint {
            BrushPaint::ColorPickup {
                pickup,
                deposit,
                dilution,
                blur,
            } => {
                let source = if blur > 0.01 {
                    average_samples(tiles, cx.max(0) as u32, cy.max(0) as u32)
                } else {
                    center_sample
                };
                let picked = mix_color(dab.color, source, (pickup * dilution).clamp(0.0, 1.0));
                let deposit = deposit.clamp(0.0, 1.0);
                mix_color(source, picked, deposit)
            }
            BrushPaint::DigitalWatercolor {
                dilution, pickup, ..
            } => mix_color(
                dab.color,
                center_sample,
                (dilution * pickup).clamp(0.0, 1.0),
            ),
            _ if matches!(dab.tool, ToolBehavior::Smudge | ToolBehavior::Blur) => {
                if dab.tool == ToolBehavior::Blur {
                    average_samples(tiles, cx.max(0) as u32, cy.max(0) as u32)
                } else {
                    center_sample
                }
            }
            _ => dab.color,
        };
        for y in min_y..=max_y {
            for x in min_x..=max_x {
                let raw_x = (x as f32 - dab.x) / radius_x;
                let raw_y = (y as f32 - dab.y) / radius_y;
                let normalized_x = raw_x * cos + raw_y * sin;
                let normalized_y = -raw_x * sin + raw_y * cos;
                let distance = normalized_x * normalized_x + normalized_y * normalized_y;
                if distance > 1.0 {
                    continue;
                }
                if selection.is_some_and(|mask| mask.get(x as u32, y as u32) == 0) {
                    continue;
                }
                if alpha_lock && tiles.sample_pixel(x as u32, y as u32).a == 0 {
                    continue;
                }
                let edge = (1.0 - distance).clamp(0.0, 1.0);
                let grain = dab
                    .grain
                    .map_or(1.0, |value| grain_multiplier(value, x as f32, y as f32));
                let tip = dab
                    .tip_resource_hash
                    .and_then(|hash| resources.get(&hash))
                    .map_or(1.0, |resource| {
                        sample_resource_alpha(resource, normalized_x, normalized_y)
                    });
                let paint_factor = match dab.paint {
                    BrushPaint::Glaze => 0.82,
                    BrushPaint::Marker => 0.92,
                    BrushPaint::DigitalWatercolor {
                        edge_pooling,
                        paper_resist,
                        granulation,
                        ..
                    } => {
                        let pooling = 1.0 + (1.0 - edge) * edge_pooling.clamp(0.0, 1.0);
                        let resist = 1.0 - paper_resist.clamp(0.0, 1.0) * 0.2;
                        pooling * resist * (0.85 + granulation.clamp(0.0, 1.0) * 0.15)
                    }
                    BrushPaint::ColorPickup { .. } => 0.9,
                    BrushPaint::Solid => 1.0,
                };
                let opacity = (dab.opacity
                    * dab.flow
                    * edge
                    * grain
                    * tip
                    * paint_factor
                    * f32::from(u16::MAX))
                .clamp(0.0, f32::from(u16::MAX)) as u16;
                let coord = if (eraser || dab.tool == ToolBehavior::Erase) && !preview_mask {
                    tiles.erase_pixel(x as u32, y as u32)
                } else {
                    tiles.blend_pixel(x as u32, y as u32, sampled, opacity)
                };
                if !dirty.contains(&coord) {
                    dirty.push(coord);
                }
            }
        }
    }
    dirty
}

/// Restrict predicted alpha-locked dabs to pixels that already contain
/// content on the committed layer. Preview tiles are separate from the
/// document, so this pass keeps them visually consistent without journaling
/// or mutating the committed raster.
fn mask_preview_to_alpha(
    preview: &mut TileStore,
    source: &TileStore,
    width_px: u32,
    height_px: u32,
) {
    let coordinates = preview.allocated_coordinates();
    for coordinate in coordinates {
        for local_y in 0..TILE_SIZE {
            let y = coordinate
                .y
                .saturating_mul(TILE_SIZE as i32)
                .saturating_add(local_y as i32);
            if y < 0 || y >= height_px as i32 {
                continue;
            }
            for local_x in 0..TILE_SIZE {
                let x = coordinate
                    .x
                    .saturating_mul(TILE_SIZE as i32)
                    .saturating_add(local_x as i32);
                if x < 0 || x >= width_px as i32 {
                    continue;
                }
                if preview.sample_pixel(x as u32, y as u32).a != 0
                    && source.sample_pixel(x as u32, y as u32).a == 0
                {
                    preview.erase_pixel(x as u32, y as u32);
                }
            }
        }
    }
}

fn mix_color(left: ink_model::Rgba8, right: ink_model::Rgba8, amount: f32) -> ink_model::Rgba8 {
    let amount = amount.clamp(0.0, 1.0);
    let mix = |a: u8, b: u8| {
        (f32::from(a) + (f32::from(b) - f32::from(a)) * amount)
            .round()
            .clamp(0.0, 255.0) as u8
    };
    ink_model::Rgba8 {
        r: mix(left.r, right.r),
        g: mix(left.g, right.g),
        b: mix(left.b, right.b),
        a: mix(left.a, right.a),
    }
}

#[derive(Clone, Copy)]
struct PostEffectBounds {
    min_x: u32,
    min_y: u32,
    max_x: u32,
    max_y: u32,
}

impl PostEffectBounds {
    fn width(self) -> usize {
        self.max_x.saturating_sub(self.min_x) as usize + 1
    }

    fn height(self) -> usize {
        self.max_y.saturating_sub(self.min_y) as usize + 1
    }

    fn contains(self, x: i64, y: i64) -> bool {
        x >= i64::from(self.min_x)
            && x <= i64::from(self.max_x)
            && y >= i64::from(self.min_y)
            && y <= i64::from(self.max_y)
    }

    fn index(self, x: u32, y: u32) -> usize {
        (y.saturating_sub(self.min_y) as usize)
            .saturating_mul(self.width())
            .saturating_add(x.saturating_sub(self.min_x) as usize)
    }
}

fn post_effect_bounds(
    samples: &[ink_input::PointerSample],
    padding: u32,
    halo: u32,
    width_px: u32,
    height_px: u32,
) -> Option<PostEffectBounds> {
    let first = samples.first()?;
    let (mut min_x, mut max_x) = (first.canvas_x, first.canvas_x);
    let (mut min_y, mut max_y) = (first.canvas_y, first.canvas_y);
    for sample in samples.iter().skip(1) {
        min_x = min_x.min(sample.canvas_x);
        max_x = max_x.max(sample.canvas_x);
        min_y = min_y.min(sample.canvas_y);
        max_y = max_y.max(sample.canvas_y);
    }
    let pad = padding.saturating_add(halo) as f32;
    let min_x = (min_x.floor().max(0.0) - pad).max(0.0) as u32;
    let min_y = (min_y.floor().max(0.0) - pad).max(0.0) as u32;
    let max_x = (max_x.ceil() + pad)
        .min(width_px.saturating_sub(1) as f32)
        .max(0.0) as u32;
    let max_y = (max_y.ceil() + pad)
        .min(height_px.saturating_sub(1) as f32)
        .max(0.0) as u32;
    (min_x <= max_x && min_y <= max_y).then_some(PostEffectBounds {
        min_x,
        min_y,
        max_x,
        max_y,
    })
}

fn post_region_sample(
    current: &[Rgba8],
    bounds: PostEffectBounds,
    tiles: &TileStore,
    x: i64,
    y: i64,
) -> Rgba8 {
    if bounds.contains(x, y) {
        return current[bounds.index(x as u32, y as u32)];
    }
    if x < 0 || y < 0 {
        Rgba8::default()
    } else {
        tiles.sample_pixel(x as u32, y as u32)
    }
}

fn post_average_neighbors(
    current: &[Rgba8],
    bounds: PostEffectBounds,
    tiles: &TileStore,
    x: u32,
    y: u32,
    radius: u32,
) -> Rgba8 {
    let radius = i64::from(radius.max(1));
    let x = i64::from(x);
    let y = i64::from(y);
    let samples = [
        post_region_sample(current, bounds, tiles, x - radius, y),
        post_region_sample(current, bounds, tiles, x + radius, y),
        post_region_sample(current, bounds, tiles, x, y - radius),
        post_region_sample(current, bounds, tiles, x, y + radius),
    ];
    let mut sums = [0_u32; 4];
    for sample in samples {
        sums[0] += u32::from(sample.r);
        sums[1] += u32::from(sample.g);
        sums[2] += u32::from(sample.b);
        sums[3] += u32::from(sample.a);
    }
    Rgba8 {
        r: (sums[0] / 4) as u8,
        g: (sums[1] / 4) as u8,
        b: (sums[2] / 4) as u8,
        a: (sums[3] / 4) as u8,
    }
}

fn post_scale_color(color: Rgba8, factor: f32) -> Rgba8 {
    let scale = |value: u8| (f32::from(value) * factor).round().clamp(0.0, 255.0) as u8;
    Rgba8 {
        r: scale(color.r),
        g: scale(color.g),
        b: scale(color.b),
        a: color.a,
    }
}

fn post_saturate(color: Rgba8, amount: f32) -> Rgba8 {
    let amount = (1.0 + amount).clamp(0.0, 2.0);
    let gray = 0.299 * f32::from(color.r) + 0.587 * f32::from(color.g) + 0.114 * f32::from(color.b);
    let channel = |value: u8| {
        (gray + (f32::from(value) - gray) * amount)
            .round()
            .clamp(0.0, 255.0) as u8
    };
    Rgba8 {
        r: channel(color.r),
        g: channel(color.g),
        b: channel(color.b),
        a: color.a,
    }
}

fn post_hue_shift(color: Rgba8, amount: f32) -> Rgba8 {
    let amount = amount.clamp(-1.0, 1.0);
    if amount.abs() <= f32::EPSILON {
        return color;
    }
    let rotate = |a: u8, b: u8, t: f32| {
        (f32::from(a) + (f32::from(b) - f32::from(a)) * t)
            .round()
            .clamp(0.0, 255.0) as u8
    };
    if amount > 0.0 {
        Rgba8 {
            r: rotate(color.r, color.g, amount),
            g: rotate(color.g, color.b, amount),
            b: rotate(color.b, color.r, amount),
            a: color.a,
        }
    } else {
        let amount = -amount;
        Rgba8 {
            r: rotate(color.r, color.b, amount),
            g: rotate(color.g, color.r, amount),
            b: rotate(color.b, color.g, amount),
            a: color.a,
        }
    }
}

fn post_noise(hash: &[u8; 32], x: u32, y: u32, scale: f32) -> f32 {
    let qx = (x as f32 * scale.clamp(0.01, 64.0)).floor() as u64;
    let qy = (y as f32 * scale.clamp(0.01, 64.0)).floor() as u64;
    let mut state = u64::from_le_bytes(hash[..8].try_into().unwrap_or([0; 8]));
    state ^= qx.wrapping_mul(0x9e37_79b9_7f4a_7c15);
    state ^= qy.wrapping_mul(0xbf58_476d_1ce4_e5b9);
    state ^= state >> 30;
    state = state.wrapping_mul(0xbf58_476d_1ce4_e5b9);
    state ^= state >> 27;
    (state as f32 / u64::MAX as f32).clamp(0.0, 1.0)
}

/// Apply declarative post effects to the current stroke's bounded dirty
/// region. Every stage reads from an immutable region snapshot, making output
/// independent of tile iteration order and keeping the operation undoable as
/// one stroke transaction.
fn apply_post_effects(
    tiles: &mut TileStore,
    effects: &[PostEffect],
    samples: &[ink_input::PointerSample],
    padding: u32,
    selection: Option<&SelectionMask>,
    width_px: u32,
    height_px: u32,
) -> Result<Vec<TileCoord>, EngineError> {
    let halo = effects.iter().map(PostEffect::halo_px).max().unwrap_or(0);
    let Some(bounds) = post_effect_bounds(samples, padding, halo, width_px, height_px) else {
        return Ok(Vec::new());
    };
    let area = bounds.width().saturating_mul(bounds.height());
    if area > MAX_POST_EFFECT_PIXELS {
        return Err(EngineError::InvalidCommand(
            "post-effect dirty region exceeds the safety limit".into(),
        ));
    }
    let mut current = Vec::with_capacity(area);
    for y in bounds.min_y..=bounds.max_y {
        for x in bounds.min_x..=bounds.max_x {
            current.push(tiles.sample_pixel(x, y));
        }
    }
    let original = current.clone();
    let (start, end) =
        samples
            .first()
            .zip(samples.last())
            .map_or(((0.0, 0.0), (1.0, 0.0)), |(first, last)| {
                (
                    (first.canvas_x, first.canvas_y),
                    (last.canvas_x, last.canvas_y),
                )
            });
    let direction = (end.0 - start.0, end.1 - start.1);
    let direction_length = direction.0.hypot(direction.1).max(1.0);
    for effect in effects {
        let mut next = current.clone();
        for y in bounds.min_y..=bounds.max_y {
            for x in bounds.min_x..=bounds.max_x {
                if selection.is_some_and(|mask| mask.get(x, y) == 0) {
                    continue;
                }
                let index = bounds.index(x, y);
                let center = current[index];
                let updated = match effect {
                    PostEffect::DigitalWatercolorEdge {
                        radius_px,
                        strength,
                        darkness,
                        blur,
                        saturation,
                        hue_shift,
                        style,
                        ..
                    } => {
                        let neighbor =
                            post_average_neighbors(&current, bounds, tiles, x, y, *radius_px);
                        let edge = (f32::from(center.a) - f32::from(neighbor.a)).abs() / 255.0;
                        let vivid =
                            f32::from(u8::from(matches!(style, WatercolorEdgeStyle::Vivid)));
                        let factor = (edge * *strength * (1.0 + vivid * 0.25)).clamp(0.0, 1.0);
                        let softened = mix_color(center, neighbor, factor * *blur);
                        let darkened = post_scale_color(softened, 1.0 - *darkness * factor);
                        post_hue_shift(
                            post_saturate(darkened, *saturation * factor),
                            *hue_shift * factor,
                        )
                    }
                    PostEffect::EdgeSoftness { radius_px, amount } => {
                        let neighbor =
                            post_average_neighbors(&current, bounds, tiles, x, y, *radius_px);
                        if *amount >= 0.0 {
                            mix_color(center, neighbor, *amount)
                        } else {
                            let sharpen = -*amount;
                            let channel = |value: u8, average: u8| {
                                (f32::from(value)
                                    + (f32::from(value) - f32::from(average)) * sharpen)
                                    .round()
                                    .clamp(0.0, 255.0) as u8
                            };
                            Rgba8 {
                                r: channel(center.r, neighbor.r),
                                g: channel(center.g, neighbor.g),
                                b: channel(center.b, neighbor.b),
                                a: center.a,
                            }
                        }
                    }
                    PostEffect::StampOutline {
                        radius_px,
                        opacity,
                        color,
                    } => {
                        let neighbor =
                            post_average_neighbors(&current, bounds, tiles, x, y, *radius_px);
                        if center.a > 0 && neighbor.a == 0 {
                            mix_color(center, *color, *opacity)
                        } else {
                            center
                        }
                    }
                    PostEffect::TrailingFade {
                        distance_px,
                        amount,
                    } => {
                        let projection = ((x as f32 - start.0) * direction.0
                            + (y as f32 - start.1) * direction.1)
                            / direction_length;
                        let endpoint =
                            (direction_length - projection).clamp(0.0, *distance_px as f32);
                        let fade = (*amount * (1.0 - endpoint / (*distance_px as f32).max(1.0)))
                            .clamp(0.0, 1.0);
                        Rgba8 {
                            r: center.r,
                            g: center.g,
                            b: center.b,
                            a: (f32::from(center.a) * (1.0 - fade)).round() as u8,
                        }
                    }
                    PostEffect::TexturePass {
                        resource_hash,
                        scale,
                        depth,
                    } => {
                        let noise = post_noise(resource_hash, x, y, *scale);
                        post_scale_color(center, 1.0 + (noise - 0.5) * 2.0 * *depth)
                    }
                };
                next[index] = updated;
            }
        }
        current = next;
    }
    let mut dirty = Vec::new();
    for y in bounds.min_y..=bounds.max_y {
        for x in bounds.min_x..=bounds.max_x {
            let index = bounds.index(x, y);
            if current[index] != original[index] {
                let coordinate = tiles.set_pixel(x, y, current[index]);
                if !dirty.contains(&coordinate) {
                    dirty.push(coordinate);
                }
            }
        }
    }
    dirty.sort_unstable_by_key(|coordinate| (coordinate.y, coordinate.x));
    Ok(dirty)
}

fn set_brush_paint_color(paint: &mut PaintBehavior, color: ink_model::Rgba8) {
    match paint {
        PaintBehavior::Solid(value) => value.color = color,
        PaintBehavior::Glaze(value) => value.color = color,
        PaintBehavior::Marker(value) => value.color = color,
        PaintBehavior::ColorPickup(value) => value.color = color,
        PaintBehavior::DigitalWatercolor(value) => value.color = color,
    }
}

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

fn average_samples(tiles: &TileStore, x: u32, y: u32) -> ink_model::Rgba8 {
    let mut sums = [0_u32; 4];
    let mut count = 0_u32;
    for (dx, dy) in [(0_i32, 0_i32), (-1, 0), (1, 0), (0, -1), (0, 1)] {
        let px = i64::from(x) + i64::from(dx);
        let py = i64::from(y) + i64::from(dy);
        if px < 0 || py < 0 {
            continue;
        }
        let sample = tiles.sample_pixel(px as u32, py as u32);
        sums[0] = sums[0].saturating_add(u32::from(sample.r));
        sums[1] = sums[1].saturating_add(u32::from(sample.g));
        sums[2] = sums[2].saturating_add(u32::from(sample.b));
        sums[3] = sums[3].saturating_add(u32::from(sample.a));
        count = count.saturating_add(1);
    }
    let divisor = count.max(1);
    ink_model::Rgba8 {
        r: (sums[0] / divisor) as u8,
        g: (sums[1] / divisor) as u8,
        b: (sums[2] / divisor) as u8,
        a: (sums[3] / divisor) as u8,
    }
}

/// Rasterize editable centerline ink into the same sparse tile store used by
/// the canvas. The vector record remains authoritative; this deterministic
/// cache makes vector layers visible in Flutter and all export formats.
fn rasterize_vector_stroke(
    tiles: &mut TileStore,
    stroke: &VectorStroke,
    width_px: u32,
    height_px: u32,
) -> Vec<TileCoord> {
    let mut dirty = Vec::new();
    let mut paint_point = |x: f32, y: f32, pressure: f32| {
        if x < 0.0 || y < 0.0 || x >= width_px as f32 || y >= height_px as f32 {
            return;
        }
        let radius = (0.75 + pressure.clamp(0.0, 1.0) * 2.75).max(0.5);
        let cx = x.round() as i64;
        let cy = y.round() as i64;
        let min_x = (cx - radius.ceil() as i64).max(0);
        let min_y = (cy - radius.ceil() as i64).max(0);
        let max_x = (cx + radius.ceil() as i64).min(i64::from(width_px) - 1);
        let max_y = (cy + radius.ceil() as i64).min(i64::from(height_px) - 1);
        for py in min_y..=max_y {
            for px in min_x..=max_x {
                let distance = ((px as f32 - x).powi(2) + (py as f32 - y).powi(2)).sqrt();
                if distance > radius {
                    continue;
                }
                let opacity = ((1.0 - distance / radius).clamp(0.0, 1.0)
                    * (0.45 + pressure.clamp(0.0, 1.0) * 0.55)
                    * f32::from(u16::MAX)) as u16;
                let coordinate = tiles.blend_pixel(
                    px as u32,
                    py as u32,
                    ink_model::Rgba8 {
                        r: 24,
                        g: 24,
                        b: 28,
                        a: 255,
                    },
                    opacity,
                );
                if !dirty.contains(&coordinate) {
                    dirty.push(coordinate);
                }
            }
        }
    };
    for pair in stroke.points.windows(2) {
        let from = pair[0];
        let to = pair[1];
        let distance = (to.x - from.x).hypot(to.y - from.y);
        let steps = distance.ceil().max(1.0) as usize;
        for step in 0..=steps {
            let amount = step as f32 / steps as f32;
            let x = from.x + (to.x - from.x) * amount;
            let y = from.y + (to.y - from.y) * amount;
            let pressure = from.pressure + (to.pressure - from.pressure) * amount;
            paint_point(x, y, pressure);
        }
    }
    if stroke.points.len() == 1 {
        let point = stroke.points[0];
        paint_point(point.x, point.y, point.pressure);
    }
    dirty
}

fn rebuild_vector_layer(layer: &mut LayerState, width_px: u32, height_px: u32) -> Vec<TileCoord> {
    layer.tiles.clear();
    let mut dirty = Vec::new();
    for (_, stroke) in &layer.vectors {
        dirty.extend(rasterize_vector_stroke(
            &mut layer.tiles,
            stroke,
            width_px,
            height_px,
        ));
    }
    dirty.sort_unstable_by_key(|coordinate| (coordinate.y, coordinate.x));
    dirty.dedup();
    dirty
}

fn sample_resource_alpha(resource: &BrushResource, x: f32, y: f32) -> f32 {
    if resource.width == 0 || resource.height == 0 || resource.rgba8.len() < 4 {
        return 1.0;
    }
    let u = f32::midpoint(x, 1.0).clamp(0.0, 1.0);
    let v = f32::midpoint(y, 1.0).clamp(0.0, 1.0);
    let px = (u * (resource.width.saturating_sub(1)) as f32).round() as usize;
    let py = (v * (resource.height.saturating_sub(1)) as f32).round() as usize;
    let offset = py
        .saturating_mul(resource.width as usize)
        .saturating_add(px)
        .saturating_mul(4);
    resource
        .rgba8
        .get(offset + 3)
        .map_or(1.0, |alpha| f32::from(*alpha) / 255.0)
}

/// Deterministic bounded grain modulation. The native v2 resource pipeline
/// supplies content hashes; until decoded image resources are installed, the
/// hash still gives every preset a stable, seam-free procedural texture.
fn grain_multiplier(grain: GrainStamp, x: f32, y: f32) -> f32 {
    let scale = grain.scale.clamp(0.01, 64.0);
    let qx = (x * scale).floor() as i64;
    let qy = (y * scale).floor() as i64;
    let mut state = u64::from_le_bytes(grain.resource_hash[..8].try_into().unwrap_or([0; 8]));
    state ^= (qx as u64).wrapping_mul(0x9e37_79b9_7f4a_7c15);
    state ^= (qy as u64).wrapping_mul(0xbf58_476d_1ce4_e5b9);
    state ^= state >> 30;
    state = state.wrapping_mul(0xbf58_476d_1ce4_e5b9);
    state ^= state >> 27;
    let noise = (state as f32 / u64::MAX as f32).clamp(0.0, 1.0);
    let contrast = (1.0 + (noise - 0.5) * 2.0 * grain.contrast.clamp(-1.0, 1.0)).clamp(0.0, 2.0);
    (1.0 - grain.depth.clamp(0.0, 1.0) + grain.depth.clamp(0.0, 1.0) * contrast).clamp(0.0, 2.0)
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

fn same_brush_sample(a: ink_input::PointerSample, b: ink_input::PointerSample) -> bool {
    a.pointer_id == b.pointer_id
        && a.flags == b.flags
        && a.device_kind == b.device_kind
        && a.canvas_x.to_bits() == b.canvas_x.to_bits()
        && a.canvas_y.to_bits() == b.canvas_y.to_bits()
        && a.pressure == b.pressure
        && a.tilt_x.to_bits() == b.tilt_x.to_bits()
        && a.tilt_y.to_bits() == b.tilt_y.to_bits()
        && a.azimuth.to_bits() == b.azimuth.to_bits()
        && a.twist.to_bits() == b.twist.to_bits()
}

fn interpolate_pointer_sample(
    start: ink_input::PointerSample,
    end: ink_input::PointerSample,
    t: f32,
) -> ink_input::PointerSample {
    let lerp = |a: f32, b: f32| a + (b - a) * t;
    let timestamp_delta = end.timestamp_ns.saturating_sub(start.timestamp_ns);
    ink_input::PointerSample {
        pointer_id: end.pointer_id,
        flags: end.flags,
        device_kind: end.device_kind,
        phase: end.phase,
        canvas_x: lerp(start.canvas_x, end.canvas_x),
        canvas_y: lerp(start.canvas_y, end.canvas_y),
        pressure: lerp(f32::from(start.pressure), f32::from(end.pressure)).round() as u16,
        tilt_x: lerp(start.tilt_x, end.tilt_x),
        tilt_y: lerp(start.tilt_y, end.tilt_y),
        azimuth: lerp(start.azimuth, end.azimuth),
        twist: lerp(start.twist, end.twist),
        timestamp_ns: start
            .timestamp_ns
            .saturating_add((timestamp_delta as f64 * f64::from(t)) as u64),
        sequence: end.sequence,
    }
}

/// Clip one raw pointer segment to the document rectangle. Off-canvas motion
/// must not be converted into a stroke along the document border.
fn clip_pointer_segment(
    start: Option<ink_input::PointerSample>,
    end: ink_input::PointerSample,
    max_x: f32,
    max_y: f32,
) -> Vec<ink_input::PointerSample> {
    let Some(start) = start else {
        return (end.canvas_x >= 0.0
            && end.canvas_x <= max_x
            && end.canvas_y >= 0.0
            && end.canvas_y <= max_y)
            .then_some(end)
            .into_iter()
            .collect();
    };
    let dx = end.canvas_x - start.canvas_x;
    let dy = end.canvas_y - start.canvas_y;
    let mut t0 = 0.0_f32;
    let mut t1 = 1.0_f32;
    for (p, q) in [
        (-dx, start.canvas_x),
        (dx, max_x - start.canvas_x),
        (-dy, start.canvas_y),
        (dy, max_y - start.canvas_y),
    ] {
        if p == 0.0 {
            if q < 0.0 {
                return Vec::new();
            }
            continue;
        }
        let ratio = q / p;
        if p < 0.0 {
            t0 = t0.max(ratio);
        } else {
            t1 = t1.min(ratio);
        }
        if t0 > t1 {
            return Vec::new();
        }
    }
    let clipped_start = interpolate_pointer_sample(start, end, t0);
    let clipped_end = if t1 >= 1.0 {
        end
    } else {
        interpolate_pointer_sample(start, end, t1)
    };
    // The previous in-canvas endpoint has already been accepted by the
    // preceding sample/packet. Returning it again for every ordinary segment
    // doubled confirmed sample work; source flags can differ between actual
    // and coalesced samples, so the later stationary-sample compactor cannot
    // reliably remove these duplicates. Only synthesize a new start point
    // when this segment enters the document from outside.
    if t0 <= f32::EPSILON {
        return vec![clipped_end];
    }
    if (clipped_end.canvas_x - clipped_start.canvas_x).abs() < f32::EPSILON
        && (clipped_end.canvas_y - clipped_start.canvas_y).abs() < f32::EPSILON
    {
        vec![clipped_end]
    } else {
        vec![clipped_start, clipped_end]
    }
}

fn sample_inside_document(sample: ink_input::PointerSample, max_x: f32, max_y: f32) -> bool {
    sample.canvas_x >= 0.0
        && sample.canvas_x <= max_x
        && sample.canvas_y >= 0.0
        && sample.canvas_y <= max_y
}

fn compact_stationary_samples(
    previous: Option<ink_input::PointerSample>,
    incoming: Vec<ink_input::PointerSample>,
    stationary_rate_hz: f32,
) -> Vec<ink_input::PointerSample> {
    let mut compacted = Vec::with_capacity(incoming.len());
    let mut last = previous;
    for sample in incoming {
        let stationary_dab_due = stationary_rate_hz > 0.0
            && last.is_some_and(|previous| {
                let interval_ns = (1_000_000_000.0 / stationary_rate_hz).ceil() as u64;
                sample.timestamp_ns.saturating_sub(previous.timestamp_ns) >= interval_ns
            });
        if last.is_some_and(|previous| same_brush_sample(previous, sample)) && !stationary_dab_due {
            continue;
        }
        compacted.push(sample);
        last = Some(sample);
    }
    compacted
}

fn consume_packet(state: &mut EngineState, packet: PointerPacket) -> Result<(), EngineError> {
    consume_packet_with_sample_limit(state, packet, MAX_STROKE_INPUT_SEGMENT_SAMPLES)
}

fn record_confirmed_stroke_samples(
    active: &mut ActiveStroke,
    samples: &[ink_input::PointerSample],
    segment_limit: usize,
) {
    let segment_limit = segment_limit.max(1);
    for sample in samples.iter().copied() {
        if active.samples.len() >= segment_limit {
            active.samples.clear();
            active.sample_history_complete = false;
            active.work_segments = active.work_segments.saturating_add(1);
            eprintln!(
                "Project Ink stroke input segment rollover: stroke={} segment={} reason=confirmed_sample_limit",
                active.stroke.0, active.work_segments,
            );
        }
        let pressure = f32::from(sample.pressure) / f32::from(u16::MAX);
        let metrics = &mut active.input_metrics;
        if let Some(previous) = metrics.path_end {
            let dx = f64::from(sample.canvas_x - previous.canvas_x);
            let dy = f64::from(sample.canvas_y - previous.canvas_y);
            metrics.path_length += dx.hypot(dy);
        } else {
            metrics.path_start = Some(sample);
        }
        metrics.path_end = Some(sample);
        metrics.sample_count = metrics.sample_count.saturating_add(1);
        metrics.bounds = Some(match metrics.bounds {
            Some((min_x, min_y, max_x, max_y)) => (
                min_x.min(sample.canvas_x),
                min_y.min(sample.canvas_y),
                max_x.max(sample.canvas_x),
                max_y.max(sample.canvas_y),
            ),
            None => (
                sample.canvas_x,
                sample.canvas_y,
                sample.canvas_x,
                sample.canvas_y,
            ),
        });
        metrics.pressure_range = Some(match metrics.pressure_range {
            Some((minimum, maximum)) => (minimum.min(pressure), maximum.max(pressure)),
            None => (pressure, pressure),
        });
        active.samples.push(sample);
        active.last_confirmed_sample = Some(sample);
    }
}

fn stroke_render_metrics(active: &ActiveStroke) -> StrokeRenderMetrics {
    let direct_length = active
        .input_metrics
        .path_start
        .zip(active.input_metrics.path_end)
        .map_or(0.0, |(start, end)| {
            f64::from(end.canvas_x - start.canvas_x).hypot(f64::from(end.canvas_y - start.canvas_y))
        });
    StrokeRenderMetrics {
        confirmed_sample_count: u64::try_from(active.input_metrics.sample_count)
            .unwrap_or(u64::MAX),
        path_length: active.input_metrics.path_length,
        direct_length,
        legacy_dabs: u64::try_from(active.legacy_rendered_dabs).unwrap_or(u64::MAX),
        compiled_dabs: u64::try_from(active.compiled_rendered_dabs).unwrap_or(u64::MAX),
        cpu_tiles_written: u64::try_from(active.cpu_tile_updates).unwrap_or(u64::MAX),
        compiled_cpu_tile_updates: u64::try_from(active.compiled_cpu_tile_updates)
            .unwrap_or(u64::MAX),
        work_segments: active.work_segments,
        work_limit_reached: active.work_limit_reached,
    }
}

/// Evaluate a confirmed batch transactionally in bounded segments. If a
/// packet is too expensive for one brush work segment, subdivide it while
/// preserving the evaluator's spacing and smoothing state. The returned
/// sample count is the confirmed prefix actually accepted; the caller must
/// commit that prefix and report a work-limit failure for any remainder.
fn render_compiled_confirmed_bounded(
    brush: &ink_brush::CompiledBrush,
    samples: &[ink_input::PointerSample],
    state: &mut ink_brush::CompiledBrushState,
) -> Result<(Vec<ink_brush::BrushDab>, usize, bool), ink_brush::BrushValidationError> {
    fn render_slice(
        brush: &ink_brush::CompiledBrush,
        samples: &[ink_input::PointerSample],
        state: &mut ink_brush::CompiledBrushState,
    ) -> Result<(Vec<ink_brush::BrushDab>, usize, bool), ink_brush::BrushValidationError> {
        match brush.render_incremental(samples, state) {
            Ok(dabs) => return Ok((dabs, samples.len(), false)),
            Err(ink_brush::BrushValidationError::WorkLimitExceeded) => {}
            Err(error) => return Err(error),
        }

        if state.begin_work_segment() {
            match brush.render_incremental(samples, state) {
                Ok(dabs) => return Ok((dabs, samples.len(), false)),
                Err(ink_brush::BrushValidationError::WorkLimitExceeded) => {}
                Err(error) => return Err(error),
            }
        }

        if samples.len() <= 1 {
            return Ok((Vec::new(), 0, true));
        }

        let split = samples.len() / 2;
        let (mut first_dabs, first_count, first_limited) =
            render_slice(brush, &samples[..split], state)?;
        if first_limited {
            return Ok((first_dabs, first_count, true));
        }
        let (second_dabs, second_count, second_limited) =
            render_slice(brush, &samples[split..], state)?;
        first_dabs.extend(second_dabs);
        Ok((first_dabs, first_count + second_count, second_limited))
    }

    render_slice(brush, samples, state)
}

fn resample_legacy_confirmed_bounded(
    samples: &[ink_input::PointerSample],
    preset: BrushPreset,
    anchor: Option<ink_brush::Dab>,
) -> Result<(Vec<ink_brush::Dab>, Option<ink_brush::Dab>, usize, bool), ink_brush::BrushError> {
    match ink_brush::resample_from(samples, preset, anchor) {
        Ok((dabs, next_anchor)) => return Ok((dabs, next_anchor, samples.len(), false)),
        Err(ink_brush::BrushError::TooManyDabs) => {}
    }

    if samples.len() <= 1 {
        return Ok((Vec::new(), anchor, 0, true));
    }

    let split = samples.len() / 2;
    let (mut first_dabs, first_anchor, first_count, first_limited) =
        resample_legacy_confirmed_bounded(&samples[..split], preset, anchor)?;
    if first_limited {
        return Ok((first_dabs, first_anchor, first_count, true));
    }
    let (second_dabs, second_anchor, second_count, second_limited) =
        resample_legacy_confirmed_bounded(&samples[split..], preset, first_anchor)?;
    first_dabs.extend(second_dabs);
    Ok((
        first_dabs,
        second_anchor,
        first_count + second_count,
        second_limited,
    ))
}

fn consume_packet_with_sample_limit(
    state: &mut EngineState,
    packet: PointerPacket,
    sample_limit: usize,
) -> Result<(), EngineError> {
    if state.active_stroke.is_none() {
        return Ok(());
    }
    if state
        .active_stroke
        .as_ref()
        .is_some_and(|active| active.work_limit_reached)
    {
        return Err(EngineError::InvalidCommand(
            "stroke_work_limit_reached: confirmed input could not be continued safely".into(),
        ));
    }
    let stroke_id = state
        .active_stroke
        .as_ref()
        .map(|active| active.stroke)
        .ok_or_else(|| EngineError::InvalidCommand("stroke is not active".into()))?;
    let mut confirmed = Vec::new();
    let mut predicted = Vec::new();
    let max_x = state.width_px.saturating_sub(1) as f32;
    let max_y = state.height_px.saturating_sub(1) as f32;
    let mut raw_previous = state
        .active_stroke
        .as_ref()
        .and_then(|active| active.last_input_sample);
    for sample in packet.samples {
        if sample.flags & (flags::HOVER | flags::PALM_REJECTED) != 0 {
            continue;
        }
        if sample.flags & flags::PREDICTED != 0 {
            // Predictions are disposable and are replaced by confirmed
            // samples; keep them bounded for the ephemeral preview path.
            let stopped_at_page_edge = state
                .active_stroke
                .as_ref()
                .is_some_and(|active| active.stopped_at_page_edge);
            if !stopped_at_page_edge {
                let mut bounded = sample;
                bounded.canvas_x = bounded.canvas_x.clamp(0.0, max_x);
                bounded.canvas_y = bounded.canvas_y.clamp(0.0, max_y);
                predicted.push(bounded);
            }
        } else {
            let stopped_at_page_edge = state
                .active_stroke
                .as_ref()
                .is_some_and(|active| active.stopped_at_page_edge);
            if !stopped_at_page_edge {
                confirmed.extend(clip_pointer_segment(raw_previous, sample, max_x, max_y));
                if raw_previous.is_some_and(|previous| {
                    sample_inside_document(previous, max_x, max_y)
                        && !sample_inside_document(sample, max_x, max_y)
                }) {
                    if let Some(active) = state.active_stroke.as_mut() {
                        active.stopped_at_page_edge = true;
                    }
                    predicted.clear();
                }
            }
            raw_previous = Some(sample);
        }
    }
    if let Some(active) = state.active_stroke.as_mut() {
        active.last_input_sample = raw_previous;
    }

    // Pointer capture remains active after leaving the artwork. Every sample
    // is clamped to the document edge above; a stationary cursor beyond that
    // edge can therefore produce thousands of identical points. Rebuilding
    // the full smoothed path for each duplicate makes a long drag quadratic
    // work and can stall the whole editor. Preserve sensor changes and the
    // configured stationary-brush cadence, but do not retain redundant input.
    let (previous_sample, stationary_rate_hz) =
        state.active_stroke.as_ref().map_or((None, 0.0), |active| {
            (
                active.last_confirmed_sample,
                active
                    .compiled_brush
                    .as_ref()
                    .map_or(0.0, |brush| brush.stroke.stationary_rate_hz),
            )
        });
    confirmed = compact_stationary_samples(previous_sample, confirmed, stationary_rate_hz);
    predicted = compact_stationary_samples(previous_sample, predicted, stationary_rate_hz);

    let mut committed_dirty = Vec::new();

    let committed = if confirmed.is_empty() {
        None
    } else {
        let active = state
            .active_stroke
            .as_mut()
            .ok_or_else(|| EngineError::InvalidCommand("stroke is not active".into()))?;
        let eraser = confirmed
            .iter()
            .any(|sample| sample.flags & flags::ERASER != 0);
        let (dabs, phase_two_dabs) = if let Some(compiled) = active.compiled_brush.as_ref() {
            let (phase_two_dabs, accepted_count, hit_work_limit) =
                match render_compiled_confirmed_bounded(
                    compiled,
                    &confirmed,
                    &mut active.compiled_brush_state,
                ) {
                    Ok(result) => result,
                    Err(ink_brush::BrushValidationError::WorkLimitExceeded) => {
                        active.work_limit_reached = true;
                        eprintln!(
                            "Project Ink stroke work limit reached: compiled_sample_work_limit stroke={}",
                            stroke_id.0,
                        );
                        (Vec::new(), 0, true)
                    }
                    Err(error) => return Err(EngineError::InvalidCommand(error.to_string())),
                };
            if accepted_count < confirmed.len() {
                confirmed.truncate(accepted_count);
            }
            if hit_work_limit {
                active.work_limit_reached = true;
                active.work_segments = active.work_segments.saturating_add(1);
                eprintln!(
                    "Project Ink stroke work limit reached: compiled_sample_work_limit stroke={} acceptedPacketSamples={}",
                    stroke_id.0, accepted_count,
                );
            }
            if active
                .compiled_brush_state
                .segment_work_near_limit(compiled.limits.max_dabs)
                && active.compiled_brush_state.begin_work_segment()
            {
                active.work_segments = active.work_segments.saturating_add(1);
                eprintln!(
                    "Project Ink stroke work segment rollover: stroke={} segment={} reason=safety_threshold",
                    stroke_id.0, active.work_segments,
                );
            }
            (Vec::new(), Some(phase_two_dabs))
        } else {
            let (dabs, anchor, accepted_count, hit_work_limit) =
                match resample_legacy_confirmed_bounded(
                    &confirmed,
                    active.brush,
                    active.legacy_resample_anchor,
                ) {
                    Ok(result) => result,
                    Err(error) => return Err(EngineError::InvalidCommand(error.to_string())),
                };
            if accepted_count < confirmed.len() {
                confirmed.truncate(accepted_count);
            }
            if hit_work_limit {
                active.work_limit_reached = true;
                eprintln!(
                    "Project Ink stroke work limit reached: legacy_sample_work_limit stroke={} acceptedPacketSamples={}",
                    stroke_id.0, accepted_count,
                );
            }
            if active.legacy_segment_dabs.saturating_add(dabs.len()) > ink_brush::MAX_RESAMPLED_DABS
            {
                // resample_from returns a continuation anchor; resetting this
                // segment counter preserves spacing across the same logical
                // stroke and leaves undo/history as one transaction.
                active.legacy_segment_dabs = 0;
                active.work_segments = active.work_segments.saturating_add(1);
                eprintln!(
                    "Project Ink stroke work segment rollover: stroke={} segment={} reason=legacy_dab_limit",
                    stroke_id.0, active.work_segments,
                );
            }
            active.legacy_segment_dabs = active.legacy_segment_dabs.saturating_add(dabs.len());
            active.legacy_rendered_dabs = active.legacy_rendered_dabs.saturating_add(dabs.len());
            active.legacy_resample_anchor = anchor;
            (dabs, None)
        };
        if let Some(brush_dabs) = phase_two_dabs.as_ref() {
            for dab in brush_dabs {
                if let Some((previous_x, previous_y)) = active.compiled_dab_last_position {
                    let step = (dab.x - previous_x).hypot(dab.y - previous_y);
                    active.compiled_dab_path_length += f64::from(step);
                    active.compiled_dab_max_step = active.compiled_dab_max_step.max(step);
                }
                active.compiled_dab_last_position = Some((dab.x, dab.y));
            }
            active.compiled_rendered_dabs = active
                .compiled_rendered_dabs
                .saturating_add(brush_dabs.len());
        }
        record_confirmed_stroke_samples(active, &confirmed, sample_limit);
        Some((
            active.layer,
            active.brush,
            active.compiled_brush.clone(),
            dabs,
            phase_two_dabs,
            eraser,
        ))
    };
    if let Some((layer_id, preset, compiled_brush, dabs, phase_two_dabs, eraser)) =
        committed.as_ref()
    {
        let sequence = confirmed
            .iter()
            .map(|sample| sample.sequence)
            .max()
            .unwrap_or(0);
        if let Some(brush_dabs) = phase_two_dabs.as_deref() {
            for (dab_index, dab) in brush_dabs.iter().enumerate() {
                queue_live_dab(
                    state,
                    ink_live_render::LiveDab {
                        stroke_id: stroke_id.0,
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
        } else {
            for (dab_index, dab) in dabs.iter().enumerate() {
                queue_live_dab(
                    state,
                    ink_live_render::LiveDab {
                        stroke_id: stroke_id.0,
                        sequence,
                        dab_index: u32::try_from(dab_index).unwrap_or(u32::MAX),
                        x: dab.x,
                        y: dab.y,
                        radius: legacy_dab_radius(*preset, dab.pressure),
                        opacity: legacy_dab_opacity(*preset, dab.pressure),
                        rotation: 0.0,
                        color: [
                            preset.color.r,
                            preset.color.g,
                            preset.color.b,
                            preset.color.a,
                        ],
                        phase: ink_live_render::DabPhase::Confirmed,
                    },
                );
            }
        }
        let resolved_resources =
            phase_two_dabs
                .as_deref()
                .map_or_else(BTreeMap::new, |brush_dabs| {
                    state
                        .resource_cache
                        .resolve_for_dabs(brush_dabs, &state.resources)
                });
        let layer_state = state
            .layers
            .get_mut(layer_id)
            .ok_or(EngineError::InvalidLayer)?;
        let alpha_lock = layer_state.layer.alpha_lock;
        let mut compiled_tile_updates = 0;
        if compiled_brush.is_some() {
            let tiles = render_brush_dabs(
                &mut layer_state.tiles,
                phase_two_dabs.as_deref().unwrap_or_default(),
                &resolved_resources,
                state.selection.as_ref(),
                *eraser,
                false,
                alpha_lock,
                state.width_px,
                state.height_px,
            );
            compiled_tile_updates = tiles.len();
            committed_dirty.extend(tiles.iter().copied());
        } else {
            let tiles = render_dabs(
                &mut layer_state.tiles,
                dabs,
                *preset,
                state.selection.as_ref(),
                *eraser,
                false,
                alpha_lock,
                state.width_px,
                state.height_px,
            );
            committed_dirty.extend(tiles.iter().copied());
        }
        if compiled_brush.is_some()
            && let Some(active) = state.active_stroke.as_mut()
        {
            active.compiled_cpu_tile_updates = active
                .compiled_cpu_tile_updates
                .saturating_add(compiled_tile_updates);
        }
    }

    // The accepted prefix, if any, has now been rasterized. Do not evaluate
    // predicted samples past a confirmed-work ceiling; they are disposable and
    // must not re-trigger the same bounded evaluator failure.
    let work_limit_reached = state
        .active_stroke
        .as_ref()
        .is_some_and(|active| active.work_limit_reached);

    if !confirmed.is_empty() {
        let active = state
            .active_stroke
            .as_mut()
            .ok_or_else(|| EngineError::InvalidCommand("stroke is not active".into()))?;
        active.preview_tiles.clear();
        active.preview_eraser = false;
    }
    if !predicted.is_empty() && !work_limit_reached {
        let (dabs, preview_eraser, brush_dabs) = {
            let active = state
                .active_stroke
                .as_mut()
                .ok_or_else(|| EngineError::InvalidCommand("stroke is not active".into()))?;
            let dabs = if active.compiled_brush.is_none() {
                // Confirmed dabs already live in the authoritative raster.
                // Rebuilding the full confirmed path for every prediction
                // made long strokes quadratic; only sample forward from the
                // last confirmed spacing anchor for this replaceable preview.
                resample_from(&predicted, active.brush, active.legacy_resample_anchor)
                    .map_err(|error| EngineError::InvalidCommand(error.to_string()))?
                    .0
            } else {
                Vec::new()
            };
            active.preview_eraser = predicted
                .iter()
                .any(|sample| sample.flags & flags::ERASER != 0);
            let preview_eraser = active.preview_eraser;
            let brush_dabs = if let Some(compiled) = active.compiled_brush.as_ref() {
                let mut preview_state = active.compiled_brush_state.clone_for_prediction();
                Some(
                    compiled
                        .render_incremental(&predicted, &mut preview_state)
                        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?,
                )
            } else {
                None
            };
            (dabs, preview_eraser, brush_dabs)
        };
        let resolved_resources = brush_dabs.as_deref().map_or_else(BTreeMap::new, |dabs| {
            state
                .resource_cache
                .resolve_for_dabs(dabs, &state.resources)
        });
        let sequence = predicted
            .iter()
            .map(|sample| sample.sequence)
            .max()
            .unwrap_or(0);
        if let Some(brush_dabs) = brush_dabs.as_deref() {
            for (dab_index, dab) in brush_dabs.iter().enumerate() {
                queue_live_dab(
                    state,
                    ink_live_render::LiveDab {
                        stroke_id: stroke_id.0,
                        sequence,
                        dab_index: u32::try_from(dab_index).unwrap_or(u32::MAX),
                        x: dab.x,
                        y: dab.y,
                        radius: f32::midpoint(dab.radius_x.abs(), dab.radius_y.abs()),
                        opacity: (dab.opacity * dab.flow).clamp(0.0, 1.0),
                        rotation: dab.angle,
                        color: [dab.color.r, dab.color.g, dab.color.b, dab.color.a],
                        phase: ink_live_render::DabPhase::Predicted,
                    },
                );
            }
        } else {
            let brush = state
                .active_stroke
                .as_ref()
                .map_or(BrushPreset::starters()[0], |active| active.brush);
            for (dab_index, dab) in dabs.iter().enumerate() {
                queue_live_dab(
                    state,
                    ink_live_render::LiveDab {
                        stroke_id: stroke_id.0,
                        sequence,
                        dab_index: u32::try_from(dab_index).unwrap_or(u32::MAX),
                        x: dab.x,
                        y: dab.y,
                        radius: legacy_dab_radius(brush, dab.pressure),
                        opacity: legacy_dab_opacity(brush, dab.pressure),
                        rotation: 0.0,
                        color: [0, 0, 0, 255],
                        phase: ink_live_render::DabPhase::Predicted,
                    },
                );
            }
        }
        let preview_layer_id = state.active_stroke.as_ref().map(|active| active.layer);
        let preview_alpha_source = preview_layer_id
            .filter(|layer_id| {
                state
                    .layers
                    .get(layer_id)
                    .is_some_and(|layer| layer.layer.alpha_lock)
            })
            .and_then(|layer_id| state.layers.get(&layer_id).map(|layer| layer.tiles.clone()));
        let active = state
            .active_stroke
            .as_mut()
            .ok_or_else(|| EngineError::InvalidCommand("stroke is not active".into()))?;
        active.preview_tiles.clear();
        if let Some(brush_dabs) = brush_dabs.as_deref() {
            render_brush_dabs(
                &mut active.preview_tiles,
                brush_dabs,
                &resolved_resources,
                state.selection.as_ref(),
                preview_eraser,
                true,
                false,
                state.width_px,
                state.height_px,
            );
        } else {
            render_dabs(
                &mut active.preview_tiles,
                &dabs,
                active.brush,
                state.selection.as_ref(),
                preview_eraser,
                true,
                false,
                state.width_px,
                state.height_px,
            );
        }
        if let Some(source) = preview_alpha_source.as_ref() {
            mask_preview_to_alpha(
                &mut active.preview_tiles,
                source,
                state.width_px,
                state.height_px,
            );
        }
    }

    committed_dirty.sort_unstable_by_key(|coordinate| (coordinate.y, coordinate.x));
    committed_dirty.dedup();
    let dirty_bounds = TileBounds::from_coordinates(&committed_dirty);
    let committed_tiles = committed_dirty.clone();
    let highest_committed_sequence = confirmed.iter().map(|sample| sample.sequence).max();
    if !committed_dirty.is_empty() {
        let cpu_tile_count = committed_dirty.len();
        if let Some(active) = state.active_stroke.as_mut() {
            active.cpu_tile_updates = active.cpu_tile_updates.saturating_add(cpu_tile_count);
        }
        let layer_id = state
            .active_stroke
            .as_ref()
            .map(|active| active.layer)
            .or_else(|| committed.as_ref().map(|(layer, _, _, _, _, _)| *layer))
            .ok_or(EngineError::InvalidLayer)?;
        advance_revision(state)?;
        state.events.push(EngineEvent::TilesDirty {
            revision: state.revision,
            tiles: committed_tiles
                .iter()
                .copied()
                .into_iter()
                .map(|coordinate| TileDescriptor {
                    layer: layer_id,
                    coordinate,
                })
                .collect(),
        });
        state.events.push(EngineEvent::CompositeTilesDirty {
            revision: state.revision,
            tiles: committed_tiles.clone(),
        });
    }
    if let Some(highest_committed_sequence) = highest_committed_sequence {
        let metrics = state
            .active_stroke
            .as_ref()
            .map(stroke_render_metrics)
            .ok_or_else(|| EngineError::InvalidCommand("stroke is not active".into()))?;
        state.events.push(EngineEvent::StrokeAcknowledged {
            stroke: stroke_id,
            highest_committed_sequence,
            revision: state.revision,
            dirty_bounds,
            dirty_tiles: committed_tiles,
            metrics,
        });
    }
    Ok(())
}

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
        {
            let mask_tile = mask.tiles.read(coordinate);
            let mask_bytes = mask_tile.bytes();
            for offset in (0..bytes.len()).step_by(4) {
                let alpha = u32::from(mask_bytes[offset + 3]);
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
        let state = lock_recover(&self.state);
        self.composite_tile_locked(&state, coordinate)
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
        let layers = state
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
        CompositeTileReadSnapshot {
            revision: state.revision,
            width_px: state.width_px,
            height_px: state.height_px,
            background: self.spec.background,
            layers,
        }
    }

    fn composite_tile_locked(
        &self,
        state: &EngineState,
        coordinate: TileCoord,
    ) -> Result<Vec<u8>, EngineError> {
        Self::composite_tile_from_layers(
            self.spec.width_px,
            self.spec.height_px,
            self.spec.background,
            &state.layers,
            coordinate,
        )
    }

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
                            .map(|mask| mask.tiles.read(coordinate))
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
                    if let Some(mask) = mask_tile {
                        alpha = ((u32::from(alpha) * u32::from(mask.bytes()[offset + 3]) + 127)
                            / 255) as u8;
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
        let thumb_side = usize::from(size);
        let mut output = vec![0_u8; thumb_side.saturating_mul(thumb_side).saturating_mul(4)];
        for y in 0..thumb_side {
            let source_y = (u64::try_from(y).unwrap_or(0) * u64::from(state.height_px)
                / u64::from(size)) as u32;
            for x in 0..thumb_side {
                let source_x = (u64::try_from(x).unwrap_or(0) * u64::from(state.width_px)
                    / u64::from(size)) as u32;
                let pixel = layer.tiles.sample_pixel(source_x, source_y);
                let offset = (y * thumb_side + x) * 4;
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
        let state = lock_recover(&self.state);
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
            comic: state.comic_json.clone(),
        }
    }

    /// Atomically save the current document as a native `.inkproj` directory.
    pub fn save_as(&self, destination: &std::path::Path) -> Result<(), EngineError> {
        self.flush_input()?;
        ink_storage::save_project(destination, &self.snapshot_unflushed())
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
                        let alpha = u32::from(composite[source + 3]);
                        pixels[destination] = if alpha == 0 {
                            0
                        } else {
                            (u32::from(composite[source + 2]) * 255 / alpha).min(255) as u8
                        };
                        pixels[destination + 1] = if alpha == 0 {
                            0
                        } else {
                            (u32::from(composite[source + 1]) * 255 / alpha).min(255) as u8
                        };
                        pixels[destination + 2] = if alpha == 0 {
                            0
                        } else {
                            (u32::from(composite[source]) * 255 / alpha).min(255) as u8
                        };
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
mod tests {
    use super::*;
    use ink_input::{DeviceKind, Phase, PointerSample};
    use ink_live_render::{GpuLiveSurface, LiveSurfaceConfig};
    use ink_model::{ColorSpace, DocumentSpec, Rgba8};

    #[test]
    fn available_tile_event_poll_skips_a_busy_document_state_lock() {
        let spec = DocumentSpec {
            width_px: 64,
            height_px: 64,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let document = Document::new(DocumentId::from_u128(0x5449_4c45), spec).expect("document");
        let state_guard = lock_recover(&document.state);
        assert!(
            document
                .try_drain_events_available()
                .expect("nonblocking tile poll")
                .is_none()
        );
        drop(state_guard);
        assert!(
            document
                .try_drain_events_available()
                .expect("available tile poll")
                .is_some()
        );
    }

    #[test]
    fn technical_pen_stays_visible_at_light_pressure_and_gets_wider() {
        let preset = BrushPreset::starters()[0];
        assert!(legacy_dab_radius(preset, 0.1) < legacy_dab_radius(preset, 0.5));
        assert!(legacy_dab_radius(preset, 0.5) < legacy_dab_radius(preset, 1.0));
        let mut light = TileStore::default();
        render_dabs(
            &mut light,
            &[Dab {
                x: 20.0,
                y: 20.0,
                pressure: 0.05,
            }],
            preset,
            None,
            false,
            false,
            false,
            64,
            64,
        );
        let mut firm = TileStore::default();
        render_dabs(
            &mut firm,
            &[Dab {
                x: 20.0,
                y: 20.0,
                pressure: 1.0,
            }],
            preset,
            None,
            false,
            false,
            false,
            64,
            64,
        );

        assert!(light.sample_pixel(20, 20).a > 0);
        assert!(light.sample_pixel(20, 20).a > 0);
        assert_eq!(light.sample_pixel(21, 20).a, 0);
        assert!(firm.sample_pixel(23, 20).a > 0);
        assert!(firm.sample_pixel(26, 20).a > 0);
        assert!(firm.sample_pixel(26, 20).a < firm.sample_pixel(25, 20).a);
    }

    #[test]
    fn sample_segment_rollover_keeps_curved_stroke_and_next_brush_draws() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc =
            Document::new(DocumentId::from_u128(0x5354_524f_4b45), spec).expect("valid document");
        let layer = doc.layers()[0].id;
        let first_stroke = ink_model::StrokeId::from_u128(0x0053_5452_4f4b_4501);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke: first_stroke,
            layer,
            brush: BrushPreset::starters()[0].id,
        })
        .expect("begin first brush");
        let samples = (0..256)
            .map(|sequence| {
                let progress = sequence as f32 / 255.0;
                let angle = progress * std::f32::consts::TAU * 8.0;
                let radius = 3.0 + progress * 100.0;
                PointerSample {
                    pointer_id: 1,
                    flags: flags::ACTUAL,
                    device_kind: DeviceKind::Stylus,
                    phase: if sequence == 0 {
                        Phase::Down
                    } else {
                        Phase::Move
                    },
                    canvas_x: 128.0 + radius * angle.cos(),
                    canvas_y: 128.0 + radius * angle.sin(),
                    pressure: u16::MAX,
                    tilt_x: 0.0,
                    tilt_y: 0.0,
                    azimuth: 0.0,
                    twist: 0.0,
                    timestamp_ns: u64::from(sequence) * 1_000_000,
                    sequence,
                }
            })
            .collect::<Vec<_>>();
        let packet = ink_test_support::pointer_packet(&samples);
        consume_packet_with_sample_limit(
            &mut lock_recover(&doc.state),
            decode(&packet).expect("decode long spiral"),
            180,
        )
        .expect("reaching the test limit must not poison the worker");
        {
            let state = lock_recover(&doc.state);
            let active = state
                .active_stroke
                .as_ref()
                .expect("logical stroke stays active");
            assert_eq!(active.input_metrics.sample_count, 256);
            assert_eq!(active.samples.len(), 76);
            assert!(!active.sample_history_complete);
            assert!(!active.work_limit_reached);
            let direct_length = active
                .input_metrics
                .path_start
                .zip(active.input_metrics.path_end)
                .map_or(0.0, |(start, end)| {
                    f64::from(end.canvas_x - start.canvas_x)
                        .hypot(f64::from(end.canvas_y - start.canvas_y))
                });
            assert!(active.input_metrics.path_length > direct_length * 10.0);
        }
        doc.dispatch(EditorCommand::EndStroke {
            stroke: first_stroke,
        })
        .expect("commit the complete logical stroke");

        let second_stroke = ink_model::StrokeId::from_u128(0x0053_5452_4f4b_4502);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke: second_stroke,
            layer,
            brush: BrushId::from_u128(6),
        })
        .expect("switch brushes and begin another stroke");
        doc.push_pointer_packet(&ink_test_support::one_sample(10.0, 10.0, 1.0))
            .expect("queue second-brush sample");
        doc.dispatch(EditorCommand::EndStroke {
            stroke: second_stroke,
        })
        .expect("commit second-brush stroke");

        let pixels = doc
            .read_composite_tile(TileCoord { x: 0, y: 0 })
            .expect("read committed composite");
        for (x, y) in [(131_usize, 128_usize), (230, 128), (10, 10)] {
            let alpha = pixels[(y * 256 + x) * 4 + 3];
            assert!(alpha > 0, "stroke at ({x}, {y}) should remain on canvas");
        }
        doc.dispatch(EditorCommand::Undo)
            .expect("undo the second logical stroke");
        let after_undo = doc
            .read_composite_tile(TileCoord { x: 0, y: 0 })
            .expect("read undo result");
        assert!(after_undo[(128 * 256 + 230) * 4 + 3] > 0);
        assert_eq!(after_undo[(10 * 256 + 10) * 4 + 3], 0);
        doc.dispatch(EditorCommand::Undo)
            .expect("the segmented spiral remains one undo transaction");
        let after_spiral_undo = doc
            .read_composite_tile(TileCoord { x: 0, y: 0 })
            .expect("read segmented stroke undo");
        assert_eq!(after_spiral_undo[(128 * 256 + 230) * 4 + 3], 0);
        doc.dispatch(EditorCommand::Redo)
            .expect("redo the complete segmented spiral");
        let after_redo = doc
            .read_composite_tile(TileCoord { x: 0, y: 0 })
            .expect("read segmented stroke redo");
        assert!(after_redo[(128 * 256 + 230) * 4 + 3] > 0);
        assert!(
            lock_recover(&doc.state).active_stroke.is_none(),
            "limit handling must always close the stroke transaction"
        );
    }

    #[test]
    fn compiled_dab_limit_reports_incomplete_stroke_and_allows_brush_switch() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(0x4441_425f_4c49_4d49), spec)
            .expect("valid document");
        let layer = doc.layers()[0].id;
        let brush_id = BrushId::from_u128(6);
        let mut preset = ink_brush::builtin_library()
            .into_iter()
            .find(|preset| preset.id == brush_id)
            .expect("compiled starter brush");
        // A small valid test budget reaches the same production guard without
        // allocating hundreds of thousands of dabs in a unit test.
        preset.limits.max_dabs = 32;
        lock_recover(&doc.state)
            .brush_overrides
            .insert(brush_id, preset);

        let first_stroke = ink_model::StrokeId::from_u128(0x0044_4142_5f4c_494d_4901);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke: first_stroke,
            layer,
            brush: brush_id,
        })
        .expect("begin bounded compiled stroke");
        let first = decode(&ink_test_support::one_sample(40.0, 40.0, 1.0))
            .expect("decode first sample")
            .samples[0];
        doc.push_pointer_packet(&ink_test_support::pointer_packet(&[first]))
            .expect("queue first sample");
        let mut second = first;
        second.phase = Phase::Move;
        second.canvas_x = 180.0;
        second.canvas_y = 40.0;
        second.timestamp_ns += 1_000_000;
        second.sequence += 1;
        doc.push_pointer_packet(&ink_test_support::pointer_packet(&[second]))
            .expect("queue the long segment that crosses the dab ceiling");
        let error = doc
            .dispatch(EditorCommand::EndStroke {
                stroke: first_stroke,
            })
            .expect_err("an incomplete stroke must report the dab ceiling");
        assert!(error.to_string().contains("stroke_work_limit_reached"));
        doc.dispatch(EditorCommand::CancelStroke {
            stroke: first_stroke,
        })
        .expect("cancel incomplete bounded stroke");

        let second_stroke = ink_model::StrokeId::from_u128(0x0044_4142_5f4c_494d_4902);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke: second_stroke,
            layer,
            brush: BrushId::from_u128(11),
        })
        .expect("switch to another brush");
        doc.push_pointer_packet(&ink_test_support::one_sample(200.0, 200.0, 1.0))
            .expect("queue next-brush sample");
        doc.dispatch(EditorCommand::EndStroke {
            stroke: second_stroke,
        })
        .expect("finish next-brush stroke");

        let pixels = doc
            .read_composite_tile(TileCoord { x: 0, y: 0 })
            .expect("read committed pixels");
        assert_eq!(pixels[(40_usize * 256 + 40) * 4 + 3], 0);
        assert!(pixels[(200_usize * 256 + 200) * 4 + 3] > 0);
    }

    #[test]
    fn compiled_long_packet_rolls_over_bounded_segments_without_losing_curvature() {
        let mut preset = ink_brush::builtin_library()
            .into_iter()
            .find(|preset| preset.id == BrushId::from_u128(6))
            .expect("compiled starter brush");
        preset.limits.max_dabs = 64;
        let brush = preset.compile().expect("valid bounded brush");
        let samples = (0..256)
            .map(|index| {
                let progress = index as f32 / 255.0;
                let angle = progress * std::f32::consts::TAU * 7.0;
                let radius = 4.0 + progress * 42.0;
                ink_input::PointerSample {
                    pointer_id: 1,
                    flags: flags::ACTUAL,
                    device_kind: DeviceKind::Stylus,
                    phase: if index == 0 { Phase::Down } else { Phase::Move },
                    canvas_x: 128.0 + radius * angle.cos(),
                    canvas_y: 128.0 + radius * angle.sin(),
                    pressure: u16::MAX,
                    tilt_x: 0.0,
                    tilt_y: 0.0,
                    azimuth: 0.0,
                    twist: 0.0,
                    timestamp_ns: index as u64 * 1_000_000,
                    sequence: index,
                }
            })
            .collect::<Vec<_>>();
        let mut state = ink_brush::CompiledBrushState::default();

        let (dabs, accepted, limited) =
            render_compiled_confirmed_bounded(&brush, &samples, &mut state)
                .expect("bounded evaluation should not fail the worker");

        assert_eq!(accepted, samples.len());
        assert!(
            !limited,
            "the segment rollover should accept the full packet"
        );
        assert!(!dabs.is_empty());
        assert!(state.segment_work_near_limit(brush.limits.max_dabs));
    }

    #[test]
    fn confirmed_input_waits_for_worker_capacity_instead_of_dropping_stroke() {
        let control = Arc::new((
            Mutex::new(WorkerControl {
                queue: PacketQueue::new(1),
                shutdown: false,
                busy: false,
            }),
            Condvar::new(),
        ));
        let queued_packet = ink_test_support::one_sample(10.0, 10.0, 1.0);
        let waiting_packet = ink_test_support::one_sample(20.0, 20.0, 1.0);
        {
            let (lock, _) = &*control;
            lock_recover(lock)
                .queue
                .push(queued_packet)
                .expect("first confirmed packet fits");
        }

        let (started_tx, started_rx) = std::sync::mpsc::channel();
        let producer_control = Arc::clone(&control);
        let producer = thread::spawn(move || {
            started_tx.send(()).expect("test receiver remains open");
            RenderWorker::enqueue_pointer_packet(&producer_control, waiting_packet)
        });
        started_rx.recv().expect("producer started");

        // The producer must wait while the bounded queue is full, then append
        // the same confirmed packet after the consumer signals available room.
        thread::sleep(std::time::Duration::from_millis(5));
        let (lock, wake) = &*control;
        let mut worker = lock_recover(lock);
        assert_eq!(worker.queue.len(), 1);
        worker.queue.pop().expect("consume the first packet");
        wake.notify_all();
        drop(worker);

        assert_eq!(
            producer
                .join()
                .expect("producer thread completes")
                .expect("enqueue succeeds"),
            QueueOutcome::Enqueued
        );
        let mut worker = lock_recover(lock);
        assert_eq!(worker.queue.len(), 1);
        assert_eq!(
            worker.queue.pop(),
            Some(ink_test_support::one_sample(20.0, 20.0, 1.0))
        );
    }

    #[test]
    fn redundant_edge_samples_are_compacted_but_sensor_and_stationary_changes_remain() {
        let sample = |x, pressure, timestamp_ns, sequence| PointerSample {
            pointer_id: 7,
            flags: flags::ACTUAL,
            device_kind: DeviceKind::Mouse,
            phase: Phase::Move,
            canvas_x: x,
            canvas_y: 255.0,
            pressure,
            tilt_x: 0.0,
            tilt_y: 0.0,
            azimuth: 0.0,
            twist: 0.0,
            timestamp_ns,
            sequence,
        };

        let edge = sample(255.0, 32_768, 1, 0);
        let repeated = std::iter::once(edge)
            .chain(
                (1..4096).map(|sequence| sample(255.0, 32_768, u64::from(sequence + 1), sequence)),
            )
            .collect();
        assert_eq!(compact_stationary_samples(None, repeated, 0.0), vec![edge]);

        let changed_pressure = sample(255.0, 50_000, 2, 1);
        assert_eq!(
            compact_stationary_samples(Some(edge), vec![changed_pressure], 0.0),
            vec![changed_pressure]
        );

        let stationary_tick = sample(255.0, 32_768, 100_000_001, 2);
        assert_eq!(
            compact_stationary_samples(Some(edge), vec![stationary_tick], 10.0),
            vec![stationary_tick]
        );
    }
    #[test]
    fn document_revisions_and_tiles_change_on_stroke() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(9), spec).expect("valid doc");
        let layer = doc.layers()[0].id;
        let stroke = ink_model::StrokeId::from_u128(2);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke,
            layer,
            brush: BrushPreset::starters()[0].id,
        })
        .expect("begin");
        let mut bytes = vec![1, 0, 1, 0];
        bytes.extend([0u8; ink_input::SAMPLE_BYTES]);
        bytes[12..16].copy_from_slice(&10.0f32.to_le_bytes());
        bytes[16..20].copy_from_slice(&10.0f32.to_le_bytes());
        bytes[20..24].copy_from_slice(&1.0f32.to_le_bytes());
        doc.push_pointer_packet(&bytes).expect("packet");
        let events = doc.drain_events().expect("events");
        assert!(
            events
                .iter()
                .any(|event| matches!(event, EngineEvent::TilesDirty { .. }))
        );
        assert!(
            events
                .iter()
                .any(|event| matches!(event, EngineEvent::CompositeTilesDirty { .. }))
        );
        assert!(events.iter().any(|event| matches!(
            event,
            EngineEvent::StrokeAcknowledged {
                stroke: acknowledged,
                highest_committed_sequence: 0,
                dirty_tiles,
                ..
            } if *acknowledged == stroke && !dirty_tiles.is_empty()
        )));
        let cpu_tile_updates = lock_recover(&doc.state)
            .active_stroke
            .as_ref()
            .expect("stroke remains active until pointer-up")
            .cpu_tile_updates;
        assert!(cpu_tile_updates > 0, "legacy strokes must write CPU tiles");
    }

    #[test]
    fn committed_composite_tile_matches_visible_layer_and_background() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8 {
                r: 240,
                g: 240,
                b: 240,
                a: 255,
            },
        };
        let mut doc = Document::new(DocumentId::from_u128(901), spec).expect("valid doc");
        let layer = doc.layers()[0].id;
        let stroke = ink_model::StrokeId::from_u128(902);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke,
            layer,
            brush: BrushPreset::starters()[0].id,
        })
        .expect("begin");
        doc.push_pointer_packet(&ink_test_support::one_sample(32.0, 32.0, 1.0))
            .expect("sample");
        doc.dispatch(EditorCommand::EndStroke { stroke })
            .expect("end");
        let layer_tile = doc
            .read_tile(layer, TileCoord { x: 0, y: 0 })
            .expect("layer tile");
        let composite = doc
            .read_composite_tile(TileCoord { x: 0, y: 0 })
            .expect("composite tile");
        let painted_offset = ((32 * 256 + 32) * 4) as usize;
        assert_eq!(
            &composite[painted_offset..painted_offset + 4],
            &layer_tile[painted_offset..painted_offset + 4]
        );
        let untouched_offset = ((220 * 256 + 220) * 4) as usize;
        assert_eq!(
            &composite[untouched_offset..untouched_offset + 4],
            &[240, 240, 240, 255]
        );
    }

    #[test]
    fn adjustment_layer_changes_composite_without_mutating_raster_source() {
        let spec = DocumentSpec {
            width_px: 64,
            height_px: 64,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(90_101), spec).expect("valid doc");
        let raster = doc.layers()[0].id;
        {
            let mut state = lock_recover(&doc.state);
            state
                .layers
                .get_mut(&raster)
                .expect("base raster")
                .tiles
                .set_pixel(
                    12,
                    18,
                    Rgba8 {
                        r: 40,
                        g: 128,
                        b: 220,
                        a: 255,
                    },
                );
        }
        let adjustment = doc.add_layer(LayerKind::Adjustment).expect("adjustment");
        doc.dispatch(EditorCommand::SetLayerAdjustment {
            layer: adjustment,
            adjustment: ink_model::LayerAdjustment::BrightnessContrast {
                brightness: 20,
                contrast: 0,
            },
        })
        .expect("set adjustment");

        let source = doc
            .read_tile(raster, TileCoord { x: 0, y: 0 })
            .expect("source raster tile");
        let composite = doc
            .read_composite_tile(TileCoord { x: 0, y: 0 })
            .expect("adjusted composite");
        let offset = ((18 * 256 + 12) * 4) as usize;
        assert_eq!(&source[offset..offset + 4], &[220, 128, 40, 255]);
        assert_eq!(&composite[offset..offset + 4], &[255, 179, 91, 255]);

        doc.dispatch(EditorCommand::Undo).expect("undo adjustment");
        let restored = doc
            .read_composite_tile(TileCoord { x: 0, y: 0 })
            .expect("restored composite");
        assert_eq!(&restored[offset..offset + 4], &[220, 128, 40, 255]);
        let source_after_undo = doc
            .read_tile(raster, TileCoord { x: 0, y: 0 })
            .expect("unchanged source raster");
        assert_eq!(&source_after_undo[offset..offset + 4], &[220, 128, 40, 255]);
        doc.dispatch(EditorCommand::Redo).expect("redo adjustment");
        let redone = doc
            .read_composite_tile(TileCoord { x: 0, y: 0 })
            .expect("redone composite");
        assert_eq!(&redone[offset..offset + 4], &[255, 179, 91, 255]);

        let root = std::env::temp_dir().join(format!(
            "project-ink-adjustment-engine-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).expect("temp root");
        let project_path = root.join("adjustment.inkproj");
        doc.save_as(&project_path).expect("save adjustment project");
        let mut reopened = Document::open(&project_path).expect("reopen adjustment project");
        let reopened_tile = reopened
            .read_composite_tile(TileCoord { x: 0, y: 0 })
            .expect("reopened composite");
        assert_eq!(&reopened_tile[offset..offset + 4], &[255, 179, 91, 255]);

        let psd_path = root.join("adjustment.psd");
        reopened
            .export(&psd_path, ink_export::ExportFormat::Psd)
            .expect("export adjusted image");
        let psd = std::fs::read(&psd_path).expect("PSD bytes");
        let (width, height, exported_pixels) =
            ink_export::decode_psd(&psd).expect("decode exported PSD");
        assert_eq!((width, height), (64, 64));
        let rgba_offset = ((18 * width + 12) * 4) as usize;
        assert_eq!(
            &exported_pixels[rgba_offset..rgba_offset + 4],
            &[91, 179, 255, 255]
        );
        reopened.close();
        std::fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn group_adjustment_only_affects_accumulated_group_content() {
        let spec = DocumentSpec {
            width_px: 64,
            height_px: 64,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(90_102), spec).expect("valid doc");
        let base = doc.layers()[0].id;
        let group = doc.add_layer(LayerKind::Group).expect("group");
        let group_paint = doc
            .add_layer_with_parent(LayerKind::Raster, Some(group))
            .expect("group paint");
        assert!(
            doc.add_layer_with_parent(LayerKind::Adjustment, Some(group_paint))
                .is_err()
        );
        let group_mask = doc
            .add_layer_with_parent(LayerKind::Mask, Some(group))
            .expect("group mask");
        {
            let mut state = lock_recover(&doc.state);
            let base_tiles = &mut state.layers.get_mut(&base).expect("base").tiles;
            for (x, y) in [(10, 10), (20, 20), (30, 30)] {
                base_tiles.set_pixel(
                    x,
                    y,
                    Rgba8 {
                        r: 30,
                        g: 60,
                        b: 90,
                        a: 255,
                    },
                );
            }
            state
                .layers
                .get_mut(&group_paint)
                .expect("group paint")
                .tiles
                .set_pixel(
                    10,
                    10,
                    Rgba8 {
                        r: 220,
                        g: 10,
                        b: 20,
                        a: 255,
                    },
                );
            state
                .layers
                .get_mut(&group_paint)
                .expect("group paint")
                .tiles
                .set_pixel(
                    20,
                    20,
                    Rgba8 {
                        r: 220,
                        g: 10,
                        b: 20,
                        a: 255,
                    },
                );
            state
                .layers
                .get_mut(&group_mask)
                .expect("group mask")
                .tiles
                .set_pixel(
                    10,
                    10,
                    Rgba8 {
                        r: 255,
                        g: 255,
                        b: 255,
                        a: 255,
                    },
                );
        }
        let adjustment = doc
            .add_layer_with_parent(LayerKind::Adjustment, Some(group))
            .expect("group adjustment");
        doc.dispatch(EditorCommand::SetLayerAdjustment {
            layer: adjustment,
            adjustment: ink_model::LayerAdjustment::BrightnessContrast {
                brightness: 20,
                contrast: 0,
            },
        })
        .expect("adjust group");

        let composite = doc
            .read_composite_tile(TileCoord { x: 0, y: 0 })
            .expect("scoped composite");
        let group_pixel = ((10 * 256 + 10) * 4) as usize;
        let unrelated_pixel = ((30 * 256 + 30) * 4) as usize;
        let masked_pixel = ((20 * 256 + 20) * 4) as usize;
        assert_eq!(
            &composite[group_pixel..group_pixel + 4],
            &[71, 61, 255, 255],
            "group adjustment must affect pixels covered by lower group content"
        );
        assert_eq!(
            &composite[unrelated_pixel..unrelated_pixel + 4],
            &[90, 60, 30, 255],
            "pixels outside the group must not be adjusted"
        );
        assert_eq!(
            &composite[masked_pixel..masked_pixel + 4],
            &[90, 60, 30, 255],
            "group mask must exclude pixels from adjustment coverage"
        );

        let path = std::env::temp_dir().join(format!(
            "project-ink-group-adjustment-{}.inkproj",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&path);
        doc.save_as(&path).expect("save scoped adjustment");
        let mut reopened = Document::open(&path).expect("reopen scoped adjustment");
        let reopened_composite = reopened
            .read_composite_tile(TileCoord { x: 0, y: 0 })
            .expect("reopened scoped composite");
        assert_eq!(
            &reopened_composite[group_pixel..group_pixel + 4],
            &[71, 61, 255, 255]
        );
        assert_eq!(
            &reopened_composite[unrelated_pixel..unrelated_pixel + 4],
            &[90, 60, 30, 255]
        );
        let export_path = path.with_extension("psd");
        reopened
            .export(&export_path, ink_export::ExportFormat::Psd)
            .expect("export group adjustment");
        let psd = std::fs::read(&export_path).expect("group PSD bytes");
        let (width, height, exported_pixels) =
            ink_export::decode_psd(&psd).expect("decode group PSD");
        assert_eq!((width, height), (64, 64));
        let exported_group_pixel = ((10 * width + 10) * 4) as usize;
        let exported_unrelated_pixel = ((30 * width + 30) * 4) as usize;
        assert_eq!(
            &exported_pixels[exported_group_pixel..exported_group_pixel + 4],
            &[255, 61, 71, 255]
        );
        assert_eq!(
            &exported_pixels[exported_unrelated_pixel..exported_unrelated_pixel + 4],
            &[30, 60, 90, 255]
        );

        doc.dispatch(EditorCommand::SetLayerOpacity {
            layer: group,
            opacity: 0,
        })
        .expect("hide group by opacity");
        let opacity_hidden = doc
            .read_composite_tile(TileCoord { x: 0, y: 0 })
            .expect("opacity-hidden composite");
        assert_eq!(
            &opacity_hidden[group_pixel..group_pixel + 4],
            &[90, 60, 30, 255]
        );
        doc.dispatch(EditorCommand::Undo)
            .expect("undo group opacity");
        doc.dispatch(EditorCommand::SetLayerVisibility {
            layer: group,
            visible: false,
        })
        .expect("hide group");
        let visibility_hidden = doc
            .read_composite_tile(TileCoord { x: 0, y: 0 })
            .expect("visibility-hidden composite");
        assert_eq!(
            &visibility_hidden[group_pixel..group_pixel + 4],
            &[90, 60, 30, 255]
        );
        doc.dispatch(EditorCommand::Undo)
            .expect("undo group visibility");

        doc.dispatch(EditorCommand::Undo).expect("undo adjustment");
        let undone = doc
            .read_composite_tile(TileCoord { x: 0, y: 0 })
            .expect("undo composite");
        assert_eq!(&undone[group_pixel..group_pixel + 4], &[20, 10, 220, 255]);
        reopened.close();
        std::fs::remove_dir_all(path).expect("cleanup");
    }

    #[test]
    fn gpu_live_preview_tracks_committed_cpu_technical_pen_geometry() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(905), spec).expect("valid doc");
        let layer = doc.layers()[0].id;
        let stroke = ink_model::StrokeId::from_u128(906);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke,
            layer,
            brush: BrushPreset::starters()[0].id,
        })
        .expect("begin");
        doc.push_pointer_packet(&ink_test_support::one_sample(32.0, 32.0, 1.0))
            .expect("sample");
        let dabs = doc.drain_live_dabs(64).expect("drain live dabs");
        assert_eq!(dabs.len(), 1);
        let cpu = doc
            .read_tile(layer, TileCoord { x: 0, y: 0 })
            .expect("authoritative CPU tile");

        let Ok(gpu) = GpuLiveSurface::new(LiveSurfaceConfig {
            physical_width: 256,
            physical_height: 256,
            scale_milli: 1000,
        }) else {
            // Headless CI without a graphics adapter still validates all
            // protocol and CPU-authority tests; desktop graphics CI exercises
            // this pixel comparison.
            return;
        };
        gpu.render(&dabs).expect("render GPU preview");
        let preview = gpu.readback().expect("offscreen GPU comparison");

        let bounds = |pixels: &[u8]| {
            let mut left = 256_i32;
            let mut top = 256_i32;
            let mut right = -1_i32;
            let mut bottom = -1_i32;
            for y in 0..256_i32 {
                for x in 0..256_i32 {
                    let alpha = pixels[((y * 256 + x) * 4 + 3) as usize];
                    if alpha > 0 {
                        left = left.min(x);
                        top = top.min(y);
                        right = right.max(x);
                        bottom = bottom.max(y);
                    }
                }
            }
            (left, top, right, bottom)
        };
        let cpu_bounds = bounds(&cpu);
        let gpu_bounds = bounds(&preview);
        for (cpu_edge, gpu_edge) in [
            (cpu_bounds.0, gpu_bounds.0),
            (cpu_bounds.1, gpu_bounds.1),
            (cpu_bounds.2, gpu_bounds.2),
            (cpu_bounds.3, gpu_bounds.3),
        ] {
            assert!(
                (cpu_edge - gpu_edge).abs() <= 1,
                "basic-brush bounds differ by more than one pixel: CPU {cpu_bounds:?}, GPU {gpu_bounds:?}"
            );
        }

        let center_offset = ((32 * 256 + 32) * 4) as usize;
        assert_eq!(
            &preview[center_offset..center_offset + 4],
            &cpu[center_offset..center_offset + 4],
            "opaque center color/alpha must agree with the committed CPU tile"
        );
        let outside_offset = ((48 * 256 + 48) * 4) as usize;
        assert_eq!(preview[outside_offset + 3], 0);
        assert_eq!(cpu[outside_offset + 3], 0);
    }

    #[test]
    fn gpu_live_preview_stays_spatially_aligned_on_long_basic_brush_spirals() {
        use std::f32::consts::TAU;

        let Ok(gpu) = GpuLiveSurface::new(LiveSurfaceConfig {
            physical_width: 256,
            physical_height: 256,
            scale_milli: 1000,
        }) else {
            // Headless CI without a graphics adapter still runs the protocol
            // and CPU-authority tests; desktop graphics CI exercises this
            // live-to-committed replacement comparison.
            return;
        };

        let presets = ink_brush::BrushPreset::starters();
        for (index, brush) in presets.into_iter().take(3).enumerate() {
            let spec = DocumentSpec {
                width_px: 256,
                height_px: 256,
                dpi: 144.0,
                color_space: ColorSpace::Srgb,
                background: Rgba8::default(),
            };
            let mut doc = Document::new(DocumentId::from_u128(9_100 + index as u128), spec)
                .expect("valid document");
            let layer = doc.layers()[0].id;
            let stroke = ink_model::StrokeId::from_u128(9_200 + index as u128);
            doc.dispatch(EditorCommand::BeginStroke {
                stroke,
                layer,
                brush: brush.id,
            })
            .expect("begin spiral stroke");

            // A three-turn spiral is deliberately dense enough to exercise
            // resampling, packetized brush evaluation, and an actual tile
            // replacement rather than only an isolated dab.
            let samples = (0..900)
                .map(|sequence| {
                    let progress = sequence as f32 / 899.0;
                    let angle = progress * TAU * 3.0;
                    let radius = 4.0 + progress * 90.0;
                    PointerSample {
                        pointer_id: 1,
                        flags: ink_input::flags::ACTUAL,
                        device_kind: DeviceKind::Stylus,
                        phase: if sequence == 0 {
                            Phase::Down
                        } else {
                            Phase::Move
                        },
                        canvas_x: 128.0 + radius * angle.cos(),
                        canvas_y: 128.0 + radius * angle.sin(),
                        pressure: u16::MAX,
                        tilt_x: 0.0,
                        tilt_y: 0.0,
                        azimuth: 0.0,
                        twist: 0.0,
                        timestamp_ns: u64::from(sequence) * 1_000_000,
                        sequence,
                    }
                })
                .collect::<Vec<_>>();
            let mut total_dabs = 0usize;
            for packet_samples in samples.chunks(ink_input::MAX_SAMPLES) {
                doc.push_pointer_packet(&ink_test_support::pointer_packet(packet_samples))
                    .expect("feed spiral samples");
                let dabs = doc.drain_live_dabs(65_536).expect("drain live dabs");
                total_dabs += dabs.len();
                gpu.render(&dabs).expect("append live spiral packet");
            }
            assert!(total_dabs > 100, "spiral should produce a dense dab stream");
            assert_eq!(
                doc.take_live_dab_overflow_count()
                    .expect("read preview overflow"),
                0,
                "confirmed spiral dabs must not overflow the live queue",
            );
            if index > 0 {
                gpu.cancel_stroke(9_199 + index as u128)
                    .expect("clear previous live preview");
            }
            let live = gpu.readback().expect("read back live GPU preview");

            doc.dispatch(EditorCommand::EndStroke { stroke })
                .expect("commit spiral stroke");
            let committed = doc
                .read_tile(layer, TileCoord { x: 0, y: 0 })
                .expect("read committed CPU tile");

            let alpha_bounds = |pixels: &[u8]| {
                let mut bounds = [256_i32, 256_i32, -1_i32, -1_i32];
                for y in 0..256_i32 {
                    for x in 0..256_i32 {
                        let alpha = pixels[((y * 256 + x) * 4 + 3) as usize];
                        if alpha > 0 {
                            bounds[0] = bounds[0].min(x);
                            bounds[1] = bounds[1].min(y);
                            bounds[2] = bounds[2].max(x);
                            bounds[3] = bounds[3].max(y);
                        }
                    }
                }
                bounds
            };
            let live_bounds = alpha_bounds(&live);
            let committed_bounds = alpha_bounds(&committed);
            for edge in 0..4 {
                assert!(
                    (live_bounds[edge] - committed_bounds[edge]).abs() <= 1,
                    "brush {:?} long-spiral bounds differ by more than one pixel: live {live_bounds:?}, committed {committed_bounds:?}",
                    brush.kind,
                );
            }

            // Compare geometric support with a one-pixel tolerance. The CPU
            // raster and shader use different antialiasing kernels, so exact
            // coverage equality would conflate edge softness with spatial
            // replacement movement.
            let covered = |pixels: &[u8], x: i32, y: i32| {
                (0..256).contains(&x)
                    && (0..256).contains(&y)
                    && pixels[((y * 256 + x) * 4 + 3) as usize] > 16
            };
            for y in 0..256_i32 {
                for x in 0..256_i32 {
                    let live_covered = covered(&live, x, y);
                    let committed_covered = covered(&committed, x, y);
                    if live_covered {
                        assert!(
                            (-1..=1).any(|dy| {
                                (-1..=1).any(|dx| covered(&committed, x + dx, y + dy))
                            }),
                            "brush {:?} live coverage at ({x},{y}) has no committed coverage within one pixel",
                            brush.kind,
                        );
                    }
                    if committed_covered {
                        assert!(
                            (-1..=1)
                                .any(|dy| { (-1..=1).any(|dx| covered(&live, x + dx, y + dy)) }),
                            "brush {:?} committed coverage at ({x},{y}) has no live coverage within one pixel",
                            brush.kind,
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn committed_composite_tile_preserves_paint_over_transparent_background() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(902), spec).expect("valid doc");
        let layer = doc.layers()[0].id;
        let stroke = ink_model::StrokeId::from_u128(903);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke,
            layer,
            brush: BrushPreset::starters()[0].id,
        })
        .expect("begin");
        doc.push_pointer_packet(&ink_test_support::one_sample(32.0, 32.0, 1.0))
            .expect("sample");
        doc.dispatch(EditorCommand::EndStroke { stroke })
            .expect("end");
        let composite = doc
            .read_composite_tile(TileCoord { x: 0, y: 0 })
            .expect("composite tile");
        let painted_offset = ((32 * 256 + 32) * 4) as usize;
        assert!(
            composite[painted_offset + 3] > 0,
            "paint over a transparent document background must remain visible"
        );
    }

    #[test]
    fn committed_composite_tile_preserves_paint_in_far_tile() {
        let spec = DocumentSpec {
            width_px: 2048,
            height_px: 2048,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(904), spec).expect("valid doc");
        let layer = doc.layers()[0].id;
        let stroke = ink_model::StrokeId::from_u128(905);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke,
            layer,
            brush: BrushPreset::starters()[0].id,
        })
        .expect("begin");
        doc.push_pointer_packet(&ink_test_support::one_sample(1053.0, 1048.0, 1.0))
            .expect("sample");
        doc.dispatch(EditorCommand::EndStroke { stroke })
            .expect("end");
        let composite = doc
            .read_composite_tile(TileCoord { x: 4, y: 4 })
            .expect("composite tile");
        let local_offset = (((1048 - 4 * 256) * 256 + (1053 - 4 * 256)) * 4) as usize;
        assert!(
            composite[local_offset + 3] > 0,
            "far tile paint must survive authoritative compositing"
        );
    }

    #[test]
    fn composite_applies_group_visibility_and_opacity_to_children() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(903), spec).expect("valid doc");
        let base = doc.layers()[0].id;
        let group = doc.add_layer(LayerKind::Group).expect("group layer");
        let child = doc
            .add_layer_with_parent(LayerKind::Raster, Some(group))
            .expect("child layer");
        let stroke = ink_model::StrokeId::from_u128(904);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke,
            layer: child,
            brush: BrushPreset::starters()[0].id,
        })
        .expect("begin");
        doc.push_pointer_packet(&ink_test_support::one_sample(32.0, 32.0, 1.0))
            .expect("sample");
        doc.dispatch(EditorCommand::EndStroke { stroke })
            .expect("end");
        let painted_offset = ((32 * 256 + 32) * 4) as usize;
        let visible = doc
            .read_composite_tile(TileCoord { x: 0, y: 0 })
            .expect("visible composite");
        assert_ne!(&visible[painted_offset..painted_offset + 4], &[0, 0, 0, 0]);

        doc.dispatch(EditorCommand::SetLayerOpacity {
            layer: group,
            opacity: 0,
        })
        .expect("group opacity");
        let hidden_by_opacity = doc
            .read_composite_tile(TileCoord { x: 0, y: 0 })
            .expect("opaque group composite");
        assert_eq!(
            &hidden_by_opacity[painted_offset..painted_offset + 4],
            &[0, 0, 0, 0]
        );

        doc.dispatch(EditorCommand::SetLayerVisibility {
            layer: group,
            visible: false,
        })
        .expect("group visibility");
        let hidden = doc
            .read_composite_tile(TileCoord { x: 0, y: 0 })
            .expect("hidden group composite");
        assert_eq!(&hidden[painted_offset..painted_offset + 4], &[0, 0, 0, 0]);
        assert_ne!(base, child);
    }

    #[test]
    fn pass_through_groups_reject_clipping_but_allow_the_conflict_to_be_cleared() {
        let spec = DocumentSpec {
            width_px: 32,
            height_px: 32,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(90_305), spec).expect("valid doc");
        let group = doc.add_layer(LayerKind::Group).expect("group");

        doc.dispatch(EditorCommand::SetLayerClipping {
            layer: group,
            enabled: true,
        })
        .expect("isolated groups may be clipped");
        assert!(
            doc.dispatch(EditorCommand::SetLayerGroupMode {
                layer: group,
                mode: ink_model::LayerGroupMode::PassThrough,
            })
            .is_err()
        );
        assert_eq!(
            doc.layers()
                .into_iter()
                .find(|layer| layer.id == group)
                .expect("group")
                .group_mode,
            ink_model::LayerGroupMode::Isolated,
            "a rejected mode change must preserve the previous group mode"
        );

        doc.dispatch(EditorCommand::SetLayerClipping {
            layer: group,
            enabled: false,
        })
        .expect("clear clipping before enabling pass-through");
        doc.dispatch(EditorCommand::SetLayerGroupMode {
            layer: group,
            mode: ink_model::LayerGroupMode::PassThrough,
        })
        .expect("enable pass-through after clearing clipping");
        assert!(
            doc.dispatch(EditorCommand::SetLayerClipping {
                layer: group,
                enabled: true,
            })
            .is_err()
        );
        let group = doc
            .layers()
            .into_iter()
            .find(|layer| layer.id == group)
            .expect("group");
        assert_eq!(group.group_mode, ink_model::LayerGroupMode::PassThrough);
        assert!(!group.clipping);
    }

    #[test]
    fn nested_pass_through_groups_do_not_blend_partial_alpha_backdrop_twice() {
        let spec = DocumentSpec {
            width_px: 32,
            height_px: 32,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut flat =
            Document::new(DocumentId::from_u128(90_306), spec).expect("flat reference document");
        let base = flat.layers()[0].id;
        let foreground = flat.add_layer(LayerKind::Raster).expect("foreground");
        flat.fill_region(
            base,
            0,
            0,
            Rgba8 {
                r: 0,
                g: 255,
                b: 0,
                a: 128,
            },
            0,
            0,
        )
        .expect("semi-transparent backdrop");
        flat.fill_region(
            foreground,
            0,
            0,
            Rgba8 {
                r: 255,
                g: 0,
                b: 0,
                a: 128,
            },
            0,
            0,
        )
        .expect("semi-transparent foreground");
        let expected = flat
            .read_composite_tile(TileCoord { x: 0, y: 0 })
            .expect("flat composite");

        let mut grouped =
            Document::new(DocumentId::from_u128(90_307), spec).expect("grouped reference document");
        let base = grouped.layers()[0].id;
        let group = grouped.add_layer(LayerKind::Group).expect("group");
        let nested_group = grouped
            .add_layer_with_parent(LayerKind::Group, Some(group))
            .expect("nested group");
        let foreground = grouped
            .add_layer_with_parent(LayerKind::Raster, Some(nested_group))
            .expect("nested group foreground");
        grouped
            .fill_region(
                base,
                0,
                0,
                Rgba8 {
                    r: 0,
                    g: 255,
                    b: 0,
                    a: 128,
                },
                0,
                0,
            )
            .expect("semi-transparent grouped backdrop");
        grouped
            .fill_region(
                foreground,
                0,
                0,
                Rgba8 {
                    r: 255,
                    g: 0,
                    b: 0,
                    a: 128,
                },
                0,
                0,
            )
            .expect("semi-transparent grouped foreground");
        grouped
            .dispatch(EditorCommand::SetLayerGroupMode {
                layer: group,
                mode: ink_model::LayerGroupMode::PassThrough,
            })
            .expect("pass-through mode");
        grouped
            .dispatch(EditorCommand::SetLayerGroupMode {
                layer: nested_group,
                mode: ink_model::LayerGroupMode::PassThrough,
            })
            .expect("nested pass-through mode");
        let actual = grouped
            .read_composite_tile(TileCoord { x: 0, y: 0 })
            .expect("pass-through composite");
        let pixel = ((8 * 32 + 8) * 4) as usize;
        assert_eq!(
            &actual[pixel..pixel + 4],
            &expected[pixel..pixel + 4],
            "a normal 100% pass-through group must behave like its children at the same stack position"
        );
    }

    #[test]
    fn isolated_and_pass_through_groups_composite_child_blends_differently() {
        let spec = DocumentSpec {
            width_px: 32,
            height_px: 32,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(90_304), spec).expect("valid doc");
        let base = doc.layers()[0].id;
        let group = doc.add_layer(LayerKind::Group).expect("group");
        let child = doc
            .add_layer_with_parent(LayerKind::Raster, Some(group))
            .expect("group child");
        doc.fill_region(
            base,
            0,
            0,
            Rgba8 {
                r: 0,
                g: 255,
                b: 0,
                a: 255,
            },
            0,
            0,
        )
        .expect("green backdrop");
        doc.fill_region(
            child,
            0,
            0,
            Rgba8 {
                r: 255,
                g: 0,
                b: 0,
                a: 255,
            },
            0,
            0,
        )
        .expect("red group child");
        doc.dispatch(EditorCommand::SetLayerBlendMode {
            layer: child,
            mode: ink_model::LayerBlendMode::Multiply,
        })
        .expect("child multiply");

        let isolated = doc
            .read_composite_tile(TileCoord { x: 0, y: 0 })
            .expect("isolated composite");
        let offset = ((8 * 32 + 8) * 4) as usize;
        assert_eq!(
            &isolated[offset..offset + 4],
            &[0, 0, 255, 255],
            "isolated child blends against transparency before the group is applied"
        );

        doc.dispatch(EditorCommand::SetLayerGroupMode {
            layer: group,
            mode: ink_model::LayerGroupMode::PassThrough,
        })
        .expect("pass-through group");
        let pass_through = doc
            .read_composite_tile(TileCoord { x: 0, y: 0 })
            .expect("pass-through composite");
        assert_eq!(
            &pass_through[offset..offset + 4],
            &[0, 0, 0, 255],
            "pass-through child blend sees the green backdrop beneath its group"
        );
        doc.dispatch(EditorCommand::Undo)
            .expect("undo pass-through mode");
        let undone = doc
            .read_composite_tile(TileCoord { x: 0, y: 0 })
            .expect("undo composite");
        assert_eq!(&undone[offset..offset + 4], &[0, 0, 255, 255]);
        doc.dispatch(EditorCommand::Redo)
            .expect("redo pass-through mode");

        doc.dispatch(EditorCommand::SetLayerBlendMode {
            layer: child,
            mode: ink_model::LayerBlendMode::Normal,
        })
        .expect("restore child normal");
        doc.dispatch(EditorCommand::SetLayerBlendMode {
            layer: group,
            mode: ink_model::LayerBlendMode::Multiply,
        })
        .expect("group multiply");
        let group_blend = doc
            .read_composite_tile(TileCoord { x: 0, y: 0 })
            .expect("group blend composite");
        assert_eq!(&group_blend[offset..offset + 4], &[0, 0, 0, 255]);

        let path = std::env::temp_dir().join(format!(
            "project-ink-group-composite-{}.inkproj",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&path);
        doc.save_as(&path).expect("save group compositing mode");
        doc.close();
        let mut reopened = Document::open(&path).expect("reopen group compositing mode");
        let reopened_group = reopened
            .layers()
            .into_iter()
            .find(|layer| layer.id == group)
            .expect("reopened group");
        assert_eq!(
            reopened_group.group_mode,
            ink_model::LayerGroupMode::PassThrough
        );
        assert_eq!(
            reopened_group.blend_mode,
            ink_model::LayerBlendMode::Multiply
        );
        assert_eq!(
            &reopened
                .read_composite_tile(TileCoord { x: 0, y: 0 })
                .expect("reopened group blend")[offset..offset + 4],
            &[0, 0, 0, 255]
        );
        reopened.close();
        std::fs::remove_dir_all(path).expect("remove group compositing fixture");
    }

    #[test]
    fn predicted_samples_are_visible_but_never_persisted() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(10), spec).expect("valid doc");
        let layer = doc.layers()[0].id;
        let blank = doc
            .read_tile(layer, TileCoord { x: 0, y: 0 })
            .expect("blank");
        let stroke = ink_model::StrokeId::from_u128(11);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke,
            layer,
            brush: BrushPreset::starters()[0].id,
        })
        .expect("begin");

        let mut predicted = ink_test_support::one_sample(10.0, 10.0, 1.0);
        predicted[8..10].copy_from_slice(&flags::PREDICTED.to_le_bytes());
        doc.push_pointer_packet(&predicted)
            .expect("predicted sample");
        assert_ne!(
            doc.read_tile(layer, TileCoord { x: 0, y: 0 })
                .expect("preview tile"),
            blank
        );
        assert!(doc.snapshot().tiles.is_empty());

        let root = std::env::temp_dir().join(format!(
            "project-ink-predicted-preview-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).expect("temp root");
        let path = root.join("preview.inkproj");
        doc.save_as(&path).expect("save without preview");
        let reopened = Document::open(&path).expect("reopen without preview");
        assert_eq!(
            reopened
                .read_tile(layer, TileCoord { x: 0, y: 0 })
                .expect("reopened tile"),
            blank
        );
        std::fs::remove_dir_all(root).expect("cleanup");

        let mut confirmed = ink_test_support::one_sample(10.0, 10.0, 1.0);
        confirmed[8..10].copy_from_slice(&flags::ACTUAL.to_le_bytes());
        doc.push_pointer_packet(&confirmed)
            .expect("confirmed sample");
        assert_ne!(
            doc.read_tile(layer, TileCoord { x: 0, y: 0 })
                .expect("confirmed tile"),
            blank
        );
        doc.dispatch(EditorCommand::CancelStroke { stroke })
            .expect("cancel");
        assert_eq!(
            doc.read_tile(layer, TileCoord { x: 0, y: 0 })
                .expect("canceled tile"),
            blank
        );
    }

    #[test]
    fn legacy_prediction_cost_stays_local_after_a_long_confirmed_stroke() {
        let spec = DocumentSpec {
            width_px: 2048,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc =
            Document::new(DocumentId::from_u128(0x5052_4544), spec).expect("valid document");
        let layer = doc.layers()[0].id;
        let stroke = ink_model::StrokeId::from_u128(0x5052_4545);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke,
            layer,
            brush: BrushPreset::starters()[0].id,
        })
        .expect("begin stroke");

        for index in 0..512 {
            let x = 32.0 + index as f32 * 2.0;
            doc.push_pointer_packet(&ink_test_support::one_sample(x, 64.0, 0.6))
                .expect("confirmed input");
        }
        let confirmed_dabs = doc.drain_live_dabs(65_536).expect("flush confirmed path");
        assert!(confirmed_dabs.len() > 1_000);

        let mut predicted = ink_test_support::one_sample(1058.0, 64.0, 0.6);
        predicted[8..10].copy_from_slice(&flags::PREDICTED.to_le_bytes());
        doc.push_pointer_packet(&predicted)
            .expect("predicted endpoint");
        let prediction_dabs = doc.drain_live_dabs(65_536).expect("flush prediction");
        assert!(
            prediction_dabs.len() <= 32,
            "prediction rerendered confirmed history: {} dabs",
            prediction_dabs.len()
        );
        assert!(
            prediction_dabs
                .iter()
                .all(|dab| dab.phase == ink_live_render::DabPhase::Predicted)
        );
    }

    #[test]
    fn rust_generates_bounded_live_dabs_without_persisting_them() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(12), spec).expect("valid doc");
        let layer = doc.layers()[0].id;
        let stroke = ink_model::StrokeId::from_u128(13);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke,
            layer,
            brush: BrushPreset::starters()[0].id,
        })
        .expect("begin");
        doc.push_pointer_packet(&ink_test_support::one_sample(18.0, 18.0, 1.0))
            .expect("sample");
        let dabs = doc.drain_live_dabs(32).expect("live dabs");
        assert!(!dabs.is_empty());
        assert!(dabs.iter().all(|dab| dab.stroke_id == stroke.0));
        assert!(
            dabs.iter()
                .all(|dab| dab.phase == ink_live_render::DabPhase::Confirmed)
        );
        assert!(
            doc.snapshot()
                .tiles
                .iter()
                .any(|tile| !tile.bytes.is_empty())
        );
        assert!(doc.drain_live_dabs(32).expect("drained queue").is_empty());
    }

    #[test]
    fn cancelling_a_stroke_removes_queued_gpu_preview_dabs() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(16), spec).expect("valid doc");
        let layer = doc.layers()[0].id;
        let stroke = ink_model::StrokeId::from_u128(17);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke,
            layer,
            brush: BrushPreset::starters()[0].id,
        })
        .expect("begin");
        doc.push_pointer_packet(&ink_test_support::one_sample(18.0, 18.0, 1.0))
            .expect("sample");
        doc.flush_input().expect("sample reaches CPU renderer");
        assert!(!lock_recover(&doc.live_dabs).is_empty());

        doc.dispatch(EditorCommand::CancelStroke { stroke })
            .expect("cancel");

        assert!(
            doc.drain_live_dabs(32)
                .expect("drain canceled preview")
                .is_empty()
        );
        assert!(lock_recover(&doc.live_dabs).is_empty());
    }

    #[test]
    fn live_preview_queue_overflow_never_aborts_cpu_stroke() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(14), spec).expect("valid doc");
        let layer = doc.layers()[0].id;
        let stroke = ink_model::StrokeId::from_u128(15);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke,
            layer,
            brush: BrushPreset::starters()[0].id,
        })
        .expect("begin");

        {
            let mut live_dabs = lock_recover(&doc.live_dabs);
            for sequence in 0..16_384 {
                live_dabs
                    .push(ink_live_render::LiveDab {
                        stroke_id: stroke.0,
                        sequence,
                        dab_index: 0,
                        x: 8.0,
                        y: 8.0,
                        radius: 2.0,
                        opacity: 1.0,
                        rotation: 0.0,
                        color: [0, 0, 0, 255],
                        phase: ink_live_render::DabPhase::Confirmed,
                    })
                    .expect("fill preview queue");
            }
        }

        doc.push_pointer_packet(&ink_test_support::one_sample(24.0, 24.0, 1.0))
            .expect("CPU stroke remains healthy");
        assert!(doc.take_live_dab_overflow_count().expect("overflow signal") > 0);
        assert!(
            doc.snapshot()
                .tiles
                .iter()
                .any(|tile| !tile.bytes.is_empty()),
            "CPU raster output must survive preview backpressure"
        );
    }

    #[test]
    fn ending_without_confirmation_discards_preview_and_notifies_dirty_tile() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(12), spec).expect("valid doc");
        let layer = doc.layers()[0].id;
        let stroke = ink_model::StrokeId::from_u128(13);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke,
            layer,
            brush: BrushPreset::starters()[0].id,
        })
        .expect("begin");
        let mut predicted = ink_test_support::one_sample(10.0, 10.0, 1.0);
        predicted[8..10].copy_from_slice(&flags::PREDICTED.to_le_bytes());
        doc.push_pointer_packet(&predicted)
            .expect("predicted sample");
        doc.dispatch(EditorCommand::EndStroke { stroke })
            .expect("end");
        let events = doc.drain_events().expect("events");
        assert!(events.iter().any(|event| {
            matches!(
                event,
                EngineEvent::TilesDirty { tiles, .. }
                    if tiles.iter().any(|tile| tile.layer == layer)
            )
        }));
        let tile = doc
            .read_tile(layer, TileCoord { x: 0, y: 0 })
            .expect("discarded preview");
        assert!(tile.iter().all(|byte| *byte == 0));
    }

    #[test]
    fn command_journal_replays_layer_semantics() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(39), spec).expect("valid doc");
        doc.dispatch(EditorCommand::AddLayer {
            parent: None,
            kind: LayerKind::Group,
        })
        .expect("add layer");

        let report = doc.replay_journal().expect("replay journal");
        assert_eq!(report.command_count, 1);
        assert_eq!(report.command_revision, 1);
        assert_eq!(report.layer_count, 2);
        assert!(!report.active_stroke);
    }

    #[test]
    fn layer_parenting_preserves_stable_ids_and_rejects_invalid_delete() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(40), spec).expect("valid doc");
        let original = doc.layers()[0].id;
        doc.dispatch(EditorCommand::AddLayer {
            parent: None,
            kind: LayerKind::Group,
        })
        .expect("group");
        let group = doc.layers()[1].id;
        doc.dispatch(EditorCommand::AddLayer {
            parent: Some(group),
            kind: LayerKind::Raster,
        })
        .expect("child");
        let child = doc.layers()[2].clone();
        assert_eq!(child.id, LayerId::from_u128(3));
        assert_eq!(child.parent, Some(group));

        assert!(matches!(
            doc.dispatch(EditorCommand::AddLayer {
                parent: Some(LayerId::from_u128(999)),
                kind: LayerKind::Raster,
            }),
            Err(EngineError::InvalidLayer)
        ));
        doc.dispatch(EditorCommand::DeleteLayer { layer: group })
            .expect("delete group and descendants");
        assert!(
            doc.layers()
                .iter()
                .all(|layer| layer.id != group && layer.id != child.id)
        );
        assert!(matches!(
            doc.dispatch(EditorCommand::DeleteLayer { layer: original }),
            Err(EngineError::InvalidCommand(message))
                if message.contains("at least one layer")
        ));
        doc.dispatch(EditorCommand::Undo)
            .expect("undo subtree delete");
        assert!(doc.layers().iter().any(|layer| layer.id == child.id));
        doc.dispatch(EditorCommand::Redo)
            .expect("redo subtree delete");
        assert!(
            doc.layers()
                .iter()
                .all(|layer| layer.id != group && layer.id != child.id)
        );
        let path = std::env::temp_dir().join(format!(
            "project-ink-group-delete-{}.inkproj",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&path);
        doc.save_as(&path).expect("save deleted subtree");
        let mut reopened = Document::open(&path).expect("reopen deleted subtree");
        assert!(
            reopened
                .layers()
                .iter()
                .all(|layer| layer.id != group && layer.id != child.id)
        );
        reopened
            .dispatch(EditorCommand::Undo)
            .expect("undo deletion after reopen");
        assert!(reopened.layers().iter().any(|layer| layer.id == child.id));
        let _ = std::fs::remove_dir_all(path);
        doc.dispatch(EditorCommand::AddLayer {
            parent: None,
            kind: LayerKind::Raster,
        })
        .expect("allocate replacement");
        assert_eq!(
            doc.layers().last().expect("replacement").id,
            LayerId::from_u128(2)
        );
        assert!(doc.layers().iter().all(|layer| layer.id != child.id));
    }

    #[test]
    fn panel_layer_tree_is_atomic_idempotent_and_undoable() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(401), spec).expect("valid doc");
        let command = EditorCommand::CreatePanelLayerTree {
            panel: LayerId::from_u128(90),
            panel_group: LayerId::from_u128(100),
            mask: LayerId::from_u128(101),
            sketch: LayerId::from_u128(102),
            ink: LayerId::from_u128(103),
            color: LayerId::from_u128(104),
            tone: LayerId::from_u128(105),
            effects: LayerId::from_u128(106),
        };
        doc.dispatch(command.clone()).expect("panel tree");
        let layers = doc.layers();
        assert_eq!(layers.len(), 8);
        let group = layers
            .iter()
            .find(|layer| layer.id.0 == 100)
            .expect("group");
        assert_eq!(group.kind, LayerKind::PanelGroup);
        assert!(group.parent.is_none());
        for (id, kind, order) in [
            (102, LayerKind::Raster, 0),
            (103, LayerKind::Raster, 1),
            (104, LayerKind::Raster, 2),
            (105, LayerKind::Tone, 3),
            (106, LayerKind::Raster, 4),
            (101, LayerKind::Mask, 5),
        ] {
            let layer = layers.iter().find(|layer| layer.id.0 == id).expect("child");
            assert_eq!(layer.parent, Some(LayerId::from_u128(100)));
            assert_eq!(layer.kind, kind);
            assert_eq!(layer.order, order);
        }
        let revision = doc.snapshot().revision;
        assert_eq!(
            doc.dispatch(command.clone()).expect("idempotent retry"),
            revision
        );
        assert_eq!(doc.layers().len(), 8);
        doc.dispatch(EditorCommand::Undo).expect("undo panel tree");
        assert_eq!(doc.layers().len(), 1);
        doc.dispatch(EditorCommand::Redo).expect("redo panel tree");
        assert_eq!(doc.layers().len(), 8);
        assert!(doc.replay_journal().is_ok());
    }

    #[test]
    fn panel_mask_geometry_clips_all_group_children_and_is_undoable() {
        let spec = DocumentSpec {
            width_px: 64,
            height_px: 64,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(402), spec).expect("valid doc");
        doc.create_panel_layer_tree(
            LayerId::from_u128(90),
            LayerId::from_u128(100),
            LayerId::from_u128(101),
            LayerId::from_u128(102),
            LayerId::from_u128(103),
            LayerId::from_u128(104),
            LayerId::from_u128(105),
            LayerId::from_u128(106),
        )
        .expect("panel tree");
        {
            let mut state = lock_recover(&doc.state);
            let ink = state.layers.get_mut(&LayerId::from_u128(103)).expect("ink");
            ink.tiles.set_pixel(
                16,
                16,
                Rgba8 {
                    r: 20,
                    g: 40,
                    b: 220,
                    a: 255,
                },
            );
            ink.tiles.set_pixel(
                48,
                48,
                Rgba8 {
                    r: 220,
                    g: 40,
                    b: 20,
                    a: 255,
                },
            );
        }
        doc.set_panel_mask_geometry(
            LayerId::from_u128(101),
            vec![(0.0, 0.0), (32.0, 0.0), (32.0, 32.0), (0.0, 32.0)],
        )
        .expect("mask geometry");
        let composite = doc
            .read_composite_tile(TileCoord { x: 0, y: 0 })
            .expect("composite");
        let inside = ((16 * TILE_SIZE + 16) * 4) as usize;
        let outside = ((48 * TILE_SIZE + 48) * 4) as usize;
        assert!(
            composite[inside + 3] > 0,
            "inside panel should remain visible"
        );
        assert_eq!(composite[outside + 3], 0, "outside panel must be clipped");

        doc.dispatch(EditorCommand::Undo).expect("undo mask");
        let unmasked = doc
            .read_composite_tile(TileCoord { x: 0, y: 0 })
            .expect("unmasked composite");
        assert!(
            unmasked[outside + 3] > 0,
            "undo should restore prior mask state"
        );
        doc.dispatch(EditorCommand::Redo).expect("redo mask");
        let remasked = doc
            .read_composite_tile(TileCoord { x: 0, y: 0 })
            .expect("remasked composite");
        assert_eq!(remasked[outside + 3], 0);
    }

    #[test]
    fn duplicate_leaf_layer_copies_pixels_preserves_order_and_survives_undo_reopen() {
        let spec = DocumentSpec {
            width_px: 64,
            height_px: 64,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(0x4455), spec).expect("document");
        let source = doc.layers()[0].id;
        let color = Rgba8 {
            r: 210,
            g: 60,
            b: 30,
            a: 255,
        };
        lock_recover(&doc.state)
            .layers
            .get_mut(&source)
            .expect("source layer")
            .tiles
            .set_pixel(12, 18, color);

        let duplicate = doc.duplicate_layer(source).expect("duplicate");
        let layers = doc.layers();
        let source_view = layers
            .iter()
            .find(|layer| layer.id == source)
            .expect("source");
        let duplicate_view = layers
            .iter()
            .find(|layer| layer.id == duplicate)
            .expect("duplicate layer");
        assert_eq!(duplicate_view.name, "Ink Copy");
        assert_eq!(duplicate_view.parent, source_view.parent);
        assert_eq!(
            duplicate_view.order,
            source_view.order + 1,
            "source/duplicate: {source_view:?} / {duplicate_view:?}; layers: {layers:?}"
        );
        assert_eq!(
            doc.read_tile(duplicate, TileCoord { x: 0, y: 0 })
                .expect("copied tile"),
            doc.read_tile(source, TileCoord { x: 0, y: 0 })
                .expect("source tile")
        );

        doc.dispatch(EditorCommand::Undo).expect("undo duplicate");
        assert!(!doc.layers().iter().any(|layer| layer.id == duplicate));
        doc.dispatch(EditorCommand::Redo).expect("redo duplicate");
        assert!(doc.layers().iter().any(|layer| layer.id == duplicate));
        doc.replay_journal().expect("replay duplicate command");

        let path = std::env::temp_dir().join(format!(
            "project-ink-duplicate-layer-{}.inkproj",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&path);
        doc.save_as(&path).expect("save duplicate layer");
        doc.close();
        let mut reopened = Document::open(&path).expect("reopen duplicate layer");
        assert!(reopened.layers().iter().any(|layer| layer.id == duplicate));
        assert_eq!(
            reopened
                .read_tile(duplicate, TileCoord { x: 0, y: 0 })
                .expect("reopened copied tile"),
            reopened
                .read_tile(source, TileCoord { x: 0, y: 0 })
                .expect("reopened source tile")
        );
        reopened.close();
        std::fs::remove_dir_all(path).expect("remove test project");
    }

    #[test]
    fn duplicate_group_copies_complete_hierarchy_and_undoes_atomically() {
        let spec = DocumentSpec {
            width_px: 64,
            height_px: 64,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(0x4456), spec).expect("document");
        let root = doc
            .add_layer_with_parent(LayerKind::Group, None)
            .expect("group");
        let paint = doc
            .add_layer_with_parent(LayerKind::Raster, Some(root))
            .expect("paint child");
        let nested = doc
            .add_layer_with_parent(LayerKind::Group, Some(root))
            .expect("nested group");
        let nested_paint = doc
            .add_layer_with_parent(LayerKind::Raster, Some(nested))
            .expect("nested paint");
        let pixel = Rgba8 {
            r: 40,
            g: 120,
            b: 220,
            a: 255,
        };
        lock_recover(&doc.state)
            .layers
            .get_mut(&nested_paint)
            .expect("paint")
            .tiles
            .set_pixel(9, 11, pixel);

        let duplicate = doc.duplicate_layer(root).expect("duplicate group");
        let layers = doc.layers();
        let copied = layers
            .iter()
            .find(|layer| layer.id == duplicate)
            .expect("copied root");
        assert!(copied.name.ends_with(" Copy"));
        assert_eq!(
            copied.parent,
            layers
                .iter()
                .find(|layer| layer.id == root)
                .expect("root")
                .parent
        );
        let copied_children = layers
            .iter()
            .filter(|layer| layer.parent == Some(duplicate))
            .collect::<Vec<_>>();
        assert_eq!(copied_children.len(), 2);
        let copied_paint = copied_children
            .iter()
            .find(|layer| layer.kind == LayerKind::Raster)
            .expect("paint child");
        let copied_nested = copied_children
            .iter()
            .find(|layer| layer.kind == LayerKind::Group)
            .expect("nested group");
        let copied_nested_paint = layers
            .iter()
            .find(|layer| layer.parent == Some(copied_nested.id))
            .expect("nested paint");
        assert_ne!(copied_paint.id, paint);
        assert_ne!(copied_nested_paint.id, nested_paint);
        let copied_tile = doc
            .read_tile(copied_nested_paint.id, TileCoord { x: 0, y: 0 })
            .expect("copied tile");
        let pixel_offset = (11 * TILE_SIZE as usize + 9) * 4;
        let source_tile = doc
            .read_tile(nested_paint, TileCoord { x: 0, y: 0 })
            .expect("source tile");
        assert_eq!(
            &copied_tile[pixel_offset..pixel_offset + 4],
            &source_tile[pixel_offset..pixel_offset + 4]
        );

        doc.dispatch(EditorCommand::Undo).expect("undo subtree");
        assert!(!doc.layers().iter().any(|layer| layer.id == duplicate));
        doc.dispatch(EditorCommand::Redo).expect("redo subtree");
        assert!(doc.layers().iter().any(|layer| layer.id == duplicate));
        doc.replay_journal().expect("replay subtree journal");
        assert!(doc.layers().iter().any(|layer| layer.id == duplicate));

        let path = std::env::temp_dir().join(format!(
            "project-ink-duplicate-group-{}.inkproj",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&path);
        doc.save_as(&path).expect("save duplicated group");
        doc.close();
        let mut reopened = Document::open(&path).expect("reopen duplicated group");
        let reopened_layers = reopened.layers();
        assert!(reopened_layers.iter().any(|layer| layer.id == duplicate));
        let reopened_nested_paint = reopened_layers
            .iter()
            .find(|layer| {
                layer.parent
                    == Some(
                        reopened_layers
                            .iter()
                            .find(|layer| {
                                layer.parent == Some(duplicate) && layer.kind == LayerKind::Group
                            })
                            .expect("reopened nested group")
                            .id,
                    )
            })
            .expect("reopened nested paint");
        assert_eq!(
            reopened
                .read_tile(reopened_nested_paint.id, TileCoord { x: 0, y: 0 })
                .expect("reopened copied tile"),
            reopened
                .read_tile(nested_paint, TileCoord { x: 0, y: 0 })
                .expect("reopened source tile")
        );
        reopened.close();
        std::fs::remove_dir_all(path).expect("remove group test project");
    }

    #[test]
    fn raster_layer_merge_is_atomic_undoable_and_replayable() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(61), spec).expect("valid doc");
        let target = doc.layers()[0].id;
        let source = doc.add_layer(LayerKind::Raster).expect("source layer");
        {
            let mut state = lock_recover(&doc.state);
            state
                .layers
                .get_mut(&target)
                .expect("target state")
                .tiles
                .set_pixel(
                    24,
                    24,
                    Rgba8 {
                        r: 20,
                        g: 40,
                        b: 180,
                        a: 255,
                    },
                );
            state
                .layers
                .get_mut(&source)
                .expect("source state")
                .tiles
                .set_pixel(
                    24,
                    24,
                    Rgba8 {
                        r: 220,
                        g: 60,
                        b: 30,
                        a: 220,
                    },
                );
        }
        let target_before = doc
            .read_tile(target, TileCoord { x: 0, y: 0 })
            .expect("target tile before merge");
        let source_before = doc
            .read_tile(source, TileCoord { x: 0, y: 0 })
            .expect("source tile before merge");
        assert_ne!(source_before, vec![0; 256 * 256 * 4]);

        doc.merge_layers(target, source).expect("merge layers");
        assert_eq!(doc.layers().len(), 1);
        assert_eq!(doc.layers()[0].id, target);
        let merged = doc
            .read_tile(target, TileCoord { x: 0, y: 0 })
            .expect("merged target tile");
        assert_ne!(merged, target_before);
        assert!(matches!(
            doc.read_tile(source, TileCoord { x: 0, y: 0 }),
            Err(EngineError::InvalidLayer)
        ));

        doc.dispatch(EditorCommand::Undo).expect("undo merge");
        assert_eq!(doc.layers().len(), 2);
        assert_eq!(
            doc.read_tile(source, TileCoord { x: 0, y: 0 })
                .expect("restored source tile"),
            source_before
        );
        doc.dispatch(EditorCommand::Redo).expect("redo merge");
        assert_eq!(doc.layers().len(), 1);
        assert_eq!(doc.replay_journal().expect("journal replay").layer_count, 1);
    }

    #[test]
    fn moving_layers_updates_parent_and_rejects_cycles() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(41), spec).expect("valid doc");
        doc.dispatch(EditorCommand::AddLayer {
            parent: None,
            kind: LayerKind::Group,
        })
        .expect("first group");
        doc.dispatch(EditorCommand::AddLayer {
            parent: None,
            kind: LayerKind::Group,
        })
        .expect("second group");
        let first = LayerId::from_u128(2);
        let second = LayerId::from_u128(3);
        doc.dispatch(EditorCommand::AddLayer {
            parent: Some(first),
            kind: LayerKind::Raster,
        })
        .expect("child");
        let child = LayerId::from_u128(4);

        doc.dispatch(EditorCommand::MoveLayer {
            layer: child,
            parent: Some(second),
            index: 0,
        })
        .expect("move child");
        assert_eq!(
            doc.layers()
                .iter()
                .find(|layer| layer.id == child)
                .unwrap()
                .order,
            0
        );
        assert_eq!(doc.layers()[3].parent, Some(second));
        doc.dispatch(EditorCommand::Undo).expect("undo move");
        assert_eq!(doc.layers()[3].parent, Some(first));
        doc.dispatch(EditorCommand::Redo).expect("redo move");
        assert_eq!(doc.layers()[3].parent, Some(second));
        assert!(matches!(
            doc.dispatch(EditorCommand::MoveLayer {
                layer: second,
                parent: Some(child),
                index: 0,
            }),
            Err(EngineError::InvalidCommand(message))
                if message.contains("descendants")
        ));
        doc.dispatch(EditorCommand::MoveLayer {
            layer: child,
            parent: None,
            index: 0,
        })
        .expect("move child to root");
        assert_eq!(
            doc.layers()
                .iter()
                .find(|layer| layer.id == child)
                .unwrap()
                .order,
            0
        );
        assert_eq!(doc.layers()[3].parent, None);
    }

    #[test]
    fn reopening_rejects_a_cyclic_layer_tree() {
        let layer_a = Layer {
            id: LayerId::from_u128(1),
            parent: Some(LayerId::from_u128(2)),
            kind: LayerKind::Group,
            name: "A".into(),
            opacity: u16::MAX,
            visible: true,
            ..Layer::new(LayerId::from_u128(1), LayerKind::Group, "A")
        };
        let layer_b = Layer {
            id: LayerId::from_u128(2),
            parent: Some(LayerId::from_u128(1)),
            kind: LayerKind::Group,
            name: "B".into(),
            opacity: u16::MAX,
            visible: true,
            ..Layer::new(LayerId::from_u128(2), LayerKind::Group, "B")
        };
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let result = Document::from_snapshot(ProjectSnapshot {
            id: DocumentId::from_u128(42),
            spec,
            revision: 0,
            layers: vec![layer_a, layer_b],
            tiles: Vec::new(),
            vectors: Vec::new(),
            journal: Vec::new(),
            history: HistorySnapshot::default(),
            brushes: Vec::new(),
            resources: Vec::new(),
            comic: None,
        });
        assert!(matches!(
            result,
            Err(EngineError::InvalidCommand(message))
                if message.contains("parent cycle")
        ));
    }

    #[test]
    fn reopening_rejects_a_dangling_layer_parent() {
        let layer = Layer {
            id: LayerId::from_u128(1),
            parent: Some(LayerId::from_u128(999)),
            kind: LayerKind::Raster,
            name: "Orphan".into(),
            opacity: u16::MAX,
            visible: true,
            ..Layer::new(LayerId::from_u128(1), LayerKind::Raster, "Orphan")
        };
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let result = Document::from_snapshot(ProjectSnapshot {
            id: DocumentId::from_u128(43),
            spec,
            revision: 0,
            layers: vec![layer],
            tiles: Vec::new(),
            vectors: Vec::new(),
            journal: Vec::new(),
            history: HistorySnapshot::default(),
            brushes: Vec::new(),
            resources: Vec::new(),
            comic: None,
        });
        assert!(matches!(
            result,
            Err(EngineError::InvalidCommand(message))
                if message.contains("dangling parent")
        ));
    }

    #[test]
    fn reopening_rejects_duplicate_layer_ids() {
        let layer = Layer::new(LayerId::from_u128(1), LayerKind::Raster, "Duplicate");
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let result = Document::from_snapshot(ProjectSnapshot {
            id: DocumentId::from_u128(44),
            spec,
            revision: 0,
            layers: vec![layer.clone(), layer],
            tiles: Vec::new(),
            vectors: Vec::new(),
            journal: Vec::new(),
            history: HistorySnapshot::default(),
            brushes: Vec::new(),
            resources: Vec::new(),
            comic: None,
        });
        assert!(matches!(
            result,
            Err(EngineError::InvalidCommand(message))
                if message.contains("duplicate layer ID")
        ));
    }

    #[test]
    fn recorded_stroke_has_cross_architecture_golden_tile_hash() {
        let spec = DocumentSpec {
            width_px: 4096,
            height_px: 4096,
            dpi: 300.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(49), spec).expect("valid doc");
        let layer = doc.layers()[0].id;
        let stroke = ink_model::StrokeId::from_u128(50);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke,
            layer,
            brush: BrushPreset::starters()[0].id,
        })
        .expect("begin");
        for (x, y, pressure) in [(32.25, 40.5, 0.25), (48.75, 52.0, 0.5), (80.0, 96.25, 1.0)] {
            doc.push_pointer_packet(&ink_test_support::one_sample(x, y, pressure))
                .expect("sample");
        }
        doc.dispatch(EditorCommand::EndStroke { stroke })
            .expect("end");
        let tile = doc
            .read_tile(layer, TileCoord { x: 0, y: 0 })
            .expect("tile");
        assert_eq!(
            Tile::from_bytes(tile).expect("complete tile").stable_hash(),
            12_475_419_944_979_558_790
        );
    }

    #[test]
    fn vector_ink_has_cross_architecture_golden_tile_hash() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(0xBEE1), spec).expect("valid doc");
        doc.dispatch(EditorCommand::AddLayer {
            parent: None,
            kind: LayerKind::VectorInk,
        })
        .expect("vector layer");
        let layer = doc.layers()[1].id;
        doc.add_vector_stroke(
            layer,
            ink_model::StrokeId::from_u128(0xBEE2),
            vec![
                (20.0, 20.0, 0.2, 0.1),
                (80.0, 48.0, 1.0, 0.5),
                (120.0, 96.0, 0.5, -0.25),
            ],
            false,
        )
        .expect("vector stroke");
        let tile = doc
            .read_tile(layer, TileCoord { x: 0, y: 0 })
            .expect("vector tile");
        assert_eq!(
            Tile::from_bytes(tile).expect("complete tile").stable_hash(),
            4_780_892_121_892_926_211
        );
    }

    #[test]
    fn phase_two_brush_dabs_render_and_undo() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(491), spec).expect("valid doc");
        let layer = doc.layers()[0].id;
        let blank = doc
            .read_tile(layer, TileCoord { x: 0, y: 0 })
            .expect("blank");
        let brush = builtin_library()
            .into_iter()
            .find(|preset| preset.metadata.name == "Digital Watercolor Wash")
            .expect("phase two brush");
        let stroke = ink_model::StrokeId::from_u128(492);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke,
            layer,
            brush: brush.id,
        })
        .expect("begin");
        for (x, y, pressure) in [(48.0, 48.0, 0.35), (76.0, 64.0, 0.7), (112.0, 96.0, 1.0)] {
            doc.push_pointer_packet(&ink_test_support::one_sample(x, y, pressure))
                .expect("sample");
        }
        doc.dispatch(EditorCommand::EndStroke { stroke })
            .expect("end");
        let painted = doc
            .read_tile(layer, TileCoord { x: 0, y: 0 })
            .expect("painted");
        assert_ne!(painted, blank);
        doc.dispatch(EditorCommand::Undo).expect("undo");
        assert_eq!(
            doc.read_tile(layer, TileCoord { x: 0, y: 0 })
                .expect("undo tile"),
            blank
        );
        doc.dispatch(EditorCommand::Redo).expect("redo");
        assert_eq!(
            doc.read_tile(layer, TileCoord { x: 0, y: 0 })
                .expect("redo tile"),
            painted
        );
    }

    #[test]
    fn long_legacy_spiral_and_following_compiled_stroke_survive_brush_switch() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(93), spec).expect("valid doc");
        let layer = doc.layers()[0].id;
        let path = (0..2_048)
            .map(|index| {
                let progress = index as f32 / 2_047.0;
                let angle = progress * 18.0 * std::f32::consts::PI;
                let radius = 4.0 + progress * 104.0;
                (128.0 + radius * angle.cos(), 128.0 + radius * angle.sin())
            })
            .collect::<Vec<_>>();

        for (stroke_id, brush_id) in [(94, 1), (95, 6), (96, 11)] {
            let stroke = ink_model::StrokeId::from_u128(stroke_id);
            doc.dispatch(EditorCommand::BeginStroke {
                stroke,
                layer,
                brush: BrushId::from_u128(brush_id),
            })
            .expect("begin spiral");
            for (x, y) in &path {
                doc.push_pointer_packet(&ink_test_support::one_sample(*x, *y, 1.0))
                    .expect("enqueue spiral sample");
            }
            doc.dispatch(EditorCommand::EndStroke { stroke })
                .expect("finish spiral");
            let pixels = doc
                .read_composite_tile(TileCoord { x: 0, y: 0 })
                .expect("read committed spiral");
            assert!(pixels.as_chunks::<4>().0.iter().any(|pixel| pixel[3] != 0));
        }

        doc.dispatch(EditorCommand::Undo)
            .expect("undo most recent brush stroke");
        let after_undo = doc
            .read_composite_tile(TileCoord { x: 0, y: 0 })
            .expect("read prior spiral");
        assert!(
            after_undo
                .as_chunks::<4>()
                .0
                .iter()
                .any(|pixel| pixel[3] != 0)
        );
        doc.dispatch(EditorCommand::Undo)
            .expect("undo compiled brush stroke");
        let after_compiled_undo = doc
            .read_composite_tile(TileCoord { x: 0, y: 0 })
            .expect("read first spiral");
        assert!(
            after_compiled_undo
                .as_chunks::<4>()
                .0
                .iter()
                .any(|pixel| pixel[3] != 0)
        );
        doc.dispatch(EditorCommand::Undo)
            .expect("undo first brush stroke");
        let cleared = doc
            .read_composite_tile(TileCoord { x: 0, y: 0 })
            .expect("read cleared tile");
        assert!(cleared.as_chunks::<4>().0.iter().all(|pixel| pixel[3] == 0));
    }

    #[test]
    fn repeated_long_spirals_with_brush_changes_never_drop_committed_strokes() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(103), spec).expect("valid doc");
        let layer = doc.layers()[0].id;
        let brushes = [1_u128, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];

        // Exercise repeated worker flushes and brush compilation changes, not
        // just one long stroke followed by one short stroke. Each spiral owns
        // a separate center pixel so a later draw cannot hide an earlier loss.
        for stroke_index in 0..44_u128 {
            let cell = stroke_index % 16;
            let center_x = 32.0 + (cell % 4) as f32 * 64.0;
            let center_y = 32.0 + (cell / 4) as f32 * 64.0;
            let brush_id = brushes[(stroke_index as usize) % brushes.len()];
            let stroke = StrokeId::from_u128(104 + stroke_index);
            doc.dispatch(EditorCommand::BeginStroke {
                stroke,
                layer,
                brush: BrushId::from_u128(brush_id),
            })
            .expect("begin spiral");

            let samples = (0..2_048_u32)
                .map(|index| {
                    let progress = index as f32 / 2_047.0;
                    let angle = progress * 14.0 * std::f32::consts::PI;
                    let radius = 1.0 + progress * 20.0;
                    PointerSample {
                        pointer_id: 1,
                        flags: flags::ACTUAL,
                        device_kind: DeviceKind::Stylus,
                        phase: Phase::Move,
                        canvas_x: center_x + radius * angle.cos(),
                        canvas_y: center_y + radius * angle.sin(),
                        pressure: u16::MAX,
                        tilt_x: 0.0,
                        tilt_y: 0.0,
                        azimuth: 0.0,
                        twist: 0.0,
                        timestamp_ns: u64::from(index) * 1_000_000,
                        sequence: index,
                    }
                })
                .collect::<Vec<_>>();
            for packet in samples.chunks(ink_input::MAX_SAMPLES) {
                doc.push_pointer_packet(&ink_test_support::pointer_packet(packet))
                    .expect("enqueue spiral samples");
            }
            doc.dispatch(EditorCommand::EndStroke { stroke })
                .expect("finish spiral");

            let composite = doc
                .read_composite_tile(TileCoord { x: 0, y: 0 })
                .expect("read committed canvas");
            let center_offset = ((center_y as usize * 256 + center_x as usize) * 4) + 3;
            assert_ne!(
                composite[center_offset], 0,
                "stroke {stroke_index} with brush {brush_id} must remain visible after commit"
            );
        }

        // Every cell has received at least two strokes after all brush
        // switches, so the final composite must still contain all of them.
        let composite = doc
            .read_composite_tile(TileCoord { x: 0, y: 0 })
            .expect("read final canvas");
        for cell in 0..16_usize {
            let x = 32 + (cell % 4) * 64;
            let y = 32 + (cell / 4) * 64;
            assert_ne!(composite[(y * 256 + x) * 4 + 3], 0, "cell {cell} was lost");
        }
    }

    #[test]
    fn long_confirmed_stroke_crosses_tiles_and_round_trips_as_one_undo_unit() {
        let spec = DocumentSpec {
            width_px: 1_024,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc =
            Document::new(DocumentId::from_u128(10_320), spec).expect("valid four-tile document");
        let layer = doc.layers()[0].id;
        let draw_line = |document: &mut Document, stroke: u128, brush: BrushId, y: f32| {
            document
                .dispatch(EditorCommand::BeginStroke {
                    stroke: StrokeId::from_u128(stroke),
                    layer,
                    brush,
                })
                .expect("begin cross-tile stroke");
            let samples = (0..=1_008_u32)
                .map(|sequence| PointerSample {
                    pointer_id: 1,
                    flags: flags::ACTUAL,
                    device_kind: DeviceKind::Stylus,
                    phase: if sequence == 0 {
                        Phase::Down
                    } else {
                        Phase::Move
                    },
                    canvas_x: 8.0 + sequence as f32,
                    canvas_y: y,
                    pressure: u16::MAX,
                    tilt_x: 0.0,
                    tilt_y: 0.0,
                    azimuth: 0.0,
                    twist: 0.0,
                    timestamp_ns: u64::from(sequence) * 1_000_000,
                    sequence,
                })
                .collect::<Vec<_>>();
            for packet in samples.chunks(ink_input::MAX_SAMPLES) {
                document
                    .push_pointer_packet(&ink_test_support::pointer_packet(packet))
                    .expect("enqueue confirmed tile-crossing samples");
            }
            document
                .dispatch(EditorCommand::EndStroke {
                    stroke: StrokeId::from_u128(stroke),
                })
                .expect("commit one cross-tile stroke");
        };
        let tile_has_ink = |document: &Document, tile_x: i32, y: usize| {
            let pixels = document
                .read_composite_tile(TileCoord { x: tile_x, y: 0 })
                .expect("read committed tile");
            // Sample at the center of each tile, away from both tile seams.
            pixels[((y * 256 + 128) * 4 + 3) as usize] != 0
        };
        let read_line_tiles = |document: &Document, y: usize| {
            (0..4)
                .map(|tile_x| {
                    document
                        .read_composite_tile(TileCoord { x: tile_x, y: 0 })
                        .expect("read full cross-tile output")[y * 256 * 4..(y + 1) * 256 * 4]
                        .to_vec()
                })
                .collect::<Vec<_>>()
        };

        let brushes = BrushPreset::starters();
        draw_line(&mut doc, 10_321, brushes[0].id, 128.0);
        let first_brush_output = read_line_tiles(&doc, 128);
        for tile_x in 0..4 {
            assert!(
                tile_has_ink(&doc, tile_x, 128),
                "tile {tile_x} lost first-brush stroke ink"
            );
        }

        doc.dispatch(EditorCommand::Undo)
            .expect("one undo removes the complete stroke");
        for tile_x in 0..4 {
            assert!(
                !tile_has_ink(&doc, tile_x, 128),
                "tile {tile_x} survived undo"
            );
        }
        doc.dispatch(EditorCommand::Redo)
            .expect("one redo restores the complete stroke");
        for tile_x in 0..4 {
            assert!(
                tile_has_ink(&doc, tile_x, 128),
                "tile {tile_x} lost redo ink"
            );
        }
        assert_eq!(
            read_line_tiles(&doc, 128),
            first_brush_output,
            "redo must restore byte-identical pixels for the first long stroke"
        );

        draw_line(&mut doc, 10_322, brushes[1].id, 64.0);
        let second_brush_output = read_line_tiles(&doc, 64);
        for tile_x in 0..4 {
            assert!(
                tile_has_ink(&doc, tile_x, 64),
                "tile {tile_x} lost second-brush stroke ink"
            );
        }
        doc.dispatch(EditorCommand::Undo)
            .expect("one undo removes the second complete stroke");
        for tile_x in 0..4 {
            assert!(
                !tile_has_ink(&doc, tile_x, 64),
                "tile {tile_x} retained second-brush ink after undo"
            );
            assert!(tile_has_ink(&doc, tile_x, 128));
        }
        doc.dispatch(EditorCommand::Redo)
            .expect("one redo restores the second complete stroke");
        assert_eq!(
            read_line_tiles(&doc, 64),
            second_brush_output,
            "redo must restore byte-identical pixels for the second long stroke"
        );

        let root = std::env::temp_dir().join(format!(
            "project-ink-multitile-stroke-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).expect("create isolated fixture root");
        let path = root.join("drawing.inkproj");
        doc.save_as(&path).expect("save multi-tile stroke");
        let reopened = Document::open(&path).expect("reopen multi-tile stroke");
        assert_eq!(
            read_line_tiles(&reopened, 128),
            first_brush_output,
            "save/reopen must preserve byte-identical first-brush pixels"
        );
        assert_eq!(
            read_line_tiles(&reopened, 64),
            second_brush_output,
            "save/reopen must preserve byte-identical second-brush pixels"
        );
        for tile_x in 0..4 {
            assert!(
                tile_has_ink(&reopened, tile_x, 128),
                "tile {tile_x} lost persisted stroke ink"
            );
            assert!(tile_has_ink(&reopened, tile_x, 64));
        }
        std::fs::remove_dir_all(root).expect("clean isolated fixture");
    }

    #[test]
    fn compiled_brush_accepts_and_commits_more_than_legacy_sample_limit() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(97), spec).expect("valid doc");
        let layer = doc.layers()[0].id;
        let stroke = ink_model::StrokeId::from_u128(98);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke,
            layer,
            brush: BrushId::from_u128(6),
        })
        .expect("begin compiled stroke");

        // Cross the previous 65,536-sample ceiling without turning this into
        // an impractically large time-lapse allocation test.
        let sample_count = 65_537;
        let samples = (0..sample_count)
            .map(|index| {
                let progress = index as f32 / (sample_count - 1) as f32;
                let angle = progress * 18.0 * std::f32::consts::PI;
                let radius = 4.0 + progress * 104.0;
                PointerSample {
                    pointer_id: 4,
                    flags: flags::ACTUAL,
                    device_kind: DeviceKind::Stylus,
                    phase: Phase::Move,
                    canvas_x: 128.0 + radius * angle.cos(),
                    canvas_y: 128.0 + radius * angle.sin(),
                    pressure: u16::MAX,
                    tilt_x: 0.0,
                    tilt_y: 0.0,
                    azimuth: 0.0,
                    twist: 0.0,
                    timestamp_ns: index as u64 * 1_000_000,
                    sequence: index as u32,
                }
            })
            .collect::<Vec<_>>();
        for packet in samples.chunks(ink_input::MAX_SAMPLES) {
            doc.push_pointer_packet(&ink_test_support::pointer_packet(packet))
                .expect("enqueue bounded input packet");
        }
        doc.dispatch(EditorCommand::EndStroke { stroke })
            .expect("finish long compiled stroke");

        let pixels = doc
            .read_composite_tile(TileCoord { x: 0, y: 0 })
            .expect("read committed long spiral");
        assert!(pixels.as_chunks::<4>().0.iter().any(|pixel| pixel[3] != 0));
    }

    #[test]
    fn affine_layer_transform_is_journaled_and_undoable() {
        let spec = DocumentSpec {
            width_px: 128,
            height_px: 128,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(493), spec).expect("valid doc");
        let layer = doc.layers()[0].id;
        let stroke = ink_model::StrokeId::from_u128(494);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke,
            layer,
            brush: BrushPreset::starters()[0].id,
        })
        .expect("begin");
        doc.push_pointer_packet(&ink_test_support::one_sample(12.0, 14.0, 1.0))
            .expect("sample");
        doc.dispatch(EditorCommand::EndStroke { stroke })
            .expect("end");
        let before = doc
            .read_tile(layer, TileCoord { x: 0, y: 0 })
            .expect("before");
        doc.dispatch(EditorCommand::TransformLayer {
            layer,
            a: 1.0,
            b: 0.0,
            c: 0.0,
            d: 1.0,
            tx: 20.0,
            ty: 0.0,
        })
        .expect("transform");
        let moved = doc
            .read_tile(layer, TileCoord { x: 0, y: 0 })
            .expect("moved");
        assert_ne!(moved, before);
        doc.dispatch(EditorCommand::Undo).expect("undo transform");
        assert_eq!(
            doc.read_tile(layer, TileCoord { x: 0, y: 0 })
                .expect("restored"),
            before
        );
        doc.dispatch(EditorCommand::Redo).expect("redo transform");
        assert_eq!(
            doc.read_tile(layer, TileCoord { x: 0, y: 0 })
                .expect("redone"),
            moved
        );
    }

    #[test]
    fn bucket_fill_is_bounded_selection_aware_and_undoable() {
        let spec = DocumentSpec {
            width_px: 16,
            height_px: 16,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(495), spec).expect("valid doc");
        let layer = doc.layers()[0].id;
        doc.select_rectangle(0.0, 0.0, 8.0, 16.0)
            .expect("selection");
        doc.fill_region(
            layer,
            2,
            2,
            Rgba8 {
                r: 12,
                g: 34,
                b: 56,
                a: 255,
            },
            0,
            0,
        )
        .expect("fill");
        let tile = Tile::from_bytes(
            doc.read_tile(layer, TileCoord { x: 0, y: 0 })
                .expect("tile"),
        )
        .expect("valid tile");
        assert_eq!(tile.pixel_rgba(2, 2).r, 12);
        assert_eq!(tile.pixel_rgba(12, 2).a, 0);
        doc.dispatch(EditorCommand::Undo).expect("undo fill");
        let restored = Tile::from_bytes(
            doc.read_tile(layer, TileCoord { x: 0, y: 0 })
                .expect("restored"),
        )
        .expect("valid tile");
        assert_eq!(restored.pixel_rgba(2, 2).a, 0);
    }

    #[test]
    fn gradient_fill_supports_paint_inside_and_transparent_only_modes() {
        let spec = DocumentSpec {
            width_px: 8,
            height_px: 4,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(496), spec).expect("valid doc");
        let layer = doc.layers()[0].id;
        doc.fill_region(
            layer,
            0,
            0,
            Rgba8 {
                r: 20,
                g: 20,
                b: 20,
                a: 255,
            },
            0,
            0,
        )
        .expect("base fill");
        doc.gradient_fill(
            layer,
            0,
            0,
            (0.0, 0.0),
            (7.0, 0.0),
            Rgba8 {
                r: 0,
                g: 0,
                b: 0,
                a: 255,
            },
            Rgba8 {
                r: 255,
                g: 0,
                b: 0,
                a: 255,
            },
            0,
            0,
            0,
            true,
            false,
        )
        .expect("paint inside gradient");
        let before = Tile::from_bytes(
            doc.read_tile(layer, TileCoord { x: 0, y: 0 })
                .expect("gradient tile"),
        )
        .expect("valid gradient tile");
        assert_eq!(before.pixel_rgba(0, 0).r, 0);
        assert!(before.pixel_rgba(7, 0).r > before.pixel_rgba(0, 0).r);
        doc.dispatch(EditorCommand::Undo).expect("undo gradient");
        let restored = Tile::from_bytes(
            doc.read_tile(layer, TileCoord { x: 0, y: 0 })
                .expect("restored tile"),
        )
        .expect("valid restored tile");
        assert_eq!(restored.pixel_rgba(0, 0).r, 20);
    }

    #[test]
    fn bucket_fill_uses_visible_reference_layer_without_mutating_it() {
        let spec = DocumentSpec {
            width_px: 32,
            height_px: 32,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(496), spec).expect("valid doc");
        let target = doc.layers()[0].id;
        let reference = doc.add_layer(LayerKind::Raster).expect("reference layer");
        doc.dispatch(EditorCommand::SetLayerReference {
            layer: reference,
            enabled: true,
        })
        .expect("mark reference");

        let stroke = ink_model::StrokeId::from_u128(497);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke,
            layer: reference,
            brush: BrushPreset::starters()[0].id,
        })
        .expect("begin reference stroke");
        doc.push_pointer_packet(&ink_test_support::one_sample(2.0, 2.0, 1.0))
            .expect("reference sample");
        doc.dispatch(EditorCommand::EndStroke { stroke })
            .expect("end reference stroke");

        doc.fill_region(
            target,
            2,
            2,
            Rgba8 {
                r: 12,
                g: 34,
                b: 56,
                a: 255,
            },
            0,
            0,
        )
        .expect("reference fill");
        let target_tile = Tile::from_bytes(
            doc.read_tile(target, TileCoord { x: 0, y: 0 })
                .expect("target tile"),
        )
        .expect("valid target tile");
        assert_eq!(target_tile.pixel_rgba(2, 2).r, 12);
        assert_eq!(target_tile.pixel_rgba(31, 31).a, 0);

        let reference_tile = Tile::from_bytes(
            doc.read_tile(reference, TileCoord { x: 0, y: 0 })
                .expect("reference tile"),
        )
        .expect("valid reference tile");
        assert_ne!(reference_tile.pixel_rgba(2, 2).a, 0);
    }

    #[test]
    fn alpha_locked_raster_strokes_cannot_create_new_pixels() {
        let spec = DocumentSpec {
            width_px: 64,
            height_px: 64,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(498), spec).expect("valid doc");
        let layer = doc.layers()[0].id;
        let brush = BrushPreset::starters()[0].id;
        let first = ink_model::StrokeId::from_u128(499);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke: first,
            layer,
            brush,
        })
        .expect("begin first stroke");
        doc.push_pointer_packet(&ink_test_support::one_sample(8.0, 8.0, 1.0))
            .expect("first sample");
        doc.dispatch(EditorCommand::EndStroke { stroke: first })
            .expect("end first stroke");
        doc.dispatch(EditorCommand::SetLayerAlphaLock {
            layer,
            enabled: true,
        })
        .expect("lock alpha");

        let second = ink_model::StrokeId::from_u128(500);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke: second,
            layer,
            brush,
        })
        .expect("begin locked stroke");
        doc.push_pointer_packet(&ink_test_support::one_sample(48.0, 48.0, 1.0))
            .expect("locked sample");
        doc.dispatch(EditorCommand::EndStroke { stroke: second })
            .expect("end locked stroke");
        let tile = Tile::from_bytes(
            doc.read_tile(layer, TileCoord { x: 0, y: 0 })
                .expect("tile"),
        )
        .expect("valid tile");
        assert_ne!(tile.pixel_rgba(8, 8).a, 0);
        assert_eq!(tile.pixel_rgba(48, 48).a, 0);
    }

    #[test]
    fn clipping_layer_tile_reads_are_masked_by_preceding_paint_layer() {
        let spec = DocumentSpec {
            width_px: 64,
            height_px: 64,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(501), spec).expect("valid doc");
        let base = doc.layers()[0].id;
        let clipped = doc.add_layer(LayerKind::Raster).expect("clipped layer");
        let brush = BrushPreset::starters()[0].id;
        let base_stroke = ink_model::StrokeId::from_u128(502);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke: base_stroke,
            layer: base,
            brush,
        })
        .expect("begin base");
        doc.push_pointer_packet(&ink_test_support::one_sample(8.0, 8.0, 1.0))
            .expect("base sample");
        doc.dispatch(EditorCommand::EndStroke {
            stroke: base_stroke,
        })
        .expect("end base");
        for (stroke_id, x) in [(503_u128, 8.0_f32), (504_u128, 48.0_f32)] {
            let stroke = ink_model::StrokeId::from_u128(stroke_id);
            doc.dispatch(EditorCommand::BeginStroke {
                stroke,
                layer: clipped,
                brush,
            })
            .expect("begin clipped");
            doc.push_pointer_packet(&ink_test_support::one_sample(x, 8.0, 1.0))
                .expect("clipped sample");
            doc.dispatch(EditorCommand::EndStroke { stroke })
                .expect("end clipped");
        }
        doc.dispatch(EditorCommand::SetLayerClipping {
            layer: clipped,
            enabled: true,
        })
        .expect("enable clipping");
        let tile = Tile::from_bytes(
            doc.read_tile(clipped, TileCoord { x: 0, y: 0 })
                .expect("clipped tile"),
        )
        .expect("valid clipped tile");
        assert_ne!(tile.pixel_rgba(8, 8).a, 0);
        assert_eq!(tile.pixel_rgba(48, 8).a, 0);
    }

    #[test]
    fn mask_layer_alpha_stencils_preceding_paint_layer() {
        let spec = DocumentSpec {
            width_px: 64,
            height_px: 64,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(503), spec).expect("valid doc");
        let base = doc.layers()[0].id;
        doc.fill_region(
            base,
            0,
            0,
            Rgba8 {
                r: 24,
                g: 48,
                b: 72,
                a: 255,
            },
            0,
            0,
        )
        .expect("fill base");
        let mask = doc.add_layer(LayerKind::Mask).expect("mask layer");
        let stroke = ink_model::StrokeId::from_u128(504);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke,
            layer: mask,
            brush: BrushPreset::starters()[0].id,
        })
        .expect("begin mask stroke");
        doc.push_pointer_packet(&ink_test_support::one_sample(8.0, 8.0, 1.0))
            .expect("mask sample");
        doc.dispatch(EditorCommand::EndStroke { stroke })
            .expect("end mask stroke");
        let tile = Tile::from_bytes(
            doc.read_tile(base, TileCoord { x: 0, y: 0 })
                .expect("masked base tile"),
        )
        .expect("valid masked base tile");
        assert_ne!(tile.pixel_rgba(8, 8).a, 0);
        assert_eq!(tile.pixel_rgba(48, 48).a, 0);
        let mask_tile = Tile::from_bytes(
            doc.read_tile(mask, TileCoord { x: 0, y: 0 })
                .expect("mask tile"),
        )
        .expect("valid mask tile");
        assert_ne!(mask_tile.pixel_rgba(8, 8).a, 0);
    }

    #[test]
    fn ephemeral_selection_constrains_confirmed_and_predicted_dabs() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(498), spec).expect("valid doc");
        let layer = doc.layers()[0].id;
        doc.select_rectangle(0.0, 0.0, 64.0, 64.0)
            .expect("rectangle selection");
        let outside = ink_model::StrokeId::from_u128(499);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke: outside,
            layer,
            brush: BrushPreset::starters()[0].id,
        })
        .expect("begin outside");
        let mut predicted = ink_test_support::one_sample(200.0, 200.0, 1.0);
        predicted[8..10].copy_from_slice(&flags::PREDICTED.to_le_bytes());
        doc.push_pointer_packet(&predicted)
            .expect("outside preview");
        doc.dispatch(EditorCommand::EndStroke { stroke: outside })
            .expect("end outside");
        let outside_tile = doc
            .read_tile(layer, TileCoord { x: 0, y: 0 })
            .expect("outside tile");
        assert!(outside_tile.iter().all(|byte| *byte == 0));

        let inside = ink_model::StrokeId::from_u128(500);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke: inside,
            layer,
            brush: BrushPreset::starters()[0].id,
        })
        .expect("begin inside");
        doc.push_pointer_packet(&ink_test_support::one_sample(32.0, 32.0, 1.0))
            .expect("inside sample");
        doc.dispatch(EditorCommand::EndStroke { stroke: inside })
            .expect("end inside");
        let inside_tile = doc
            .read_tile(layer, TileCoord { x: 0, y: 0 })
            .expect("inside tile");
        assert!(inside_tile.iter().any(|byte| *byte != 0));

        doc.clear_selection().expect("clear selection");
    }

    #[test]
    fn layer_opacity_selection_reuses_allocated_pixels_only() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(501), spec).expect("valid doc");
        let layer = doc.layers()[0].id;
        let stroke = ink_model::StrokeId::from_u128(502);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke,
            layer,
            brush: BrushPreset::starters()[0].id,
        })
        .expect("begin paint");
        doc.push_pointer_packet(&ink_test_support::one_sample(24.0, 24.0, 1.0))
            .expect("paint sample");
        doc.dispatch(EditorCommand::EndStroke { stroke })
            .expect("end paint");
        doc.select_layer_opacity(layer, 1)
            .expect("select painted opacity");
        let outside = ink_model::StrokeId::from_u128(503);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke: outside,
            layer,
            brush: BrushPreset::starters()[0].id,
        })
        .expect("begin outside");
        doc.push_pointer_packet(&ink_test_support::one_sample(220.0, 220.0, 1.0))
            .expect("outside sample");
        doc.dispatch(EditorCommand::EndStroke { stroke: outside })
            .expect("end outside");
        let tile = doc
            .read_tile(layer, TileCoord { x: 0, y: 0 })
            .expect("tile");
        let outside_offset = ((220 * 256 + 220) * 4) as usize;
        assert_eq!(&tile[outside_offset..outside_offset + 4], &[0, 0, 0, 0]);
    }

    #[test]
    fn brush_editor_settings_are_rust_owned_and_captured_per_stroke() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(493), spec).expect("valid doc");
        let brush = BrushId::from_u128(6);
        let revision = doc
            .update_brush_settings(
                brush,
                42.0,
                0.7,
                0.08,
                0.2,
                0.55,
                0.2,
                0.5,
                0.75,
                1.0,
                0.35,
                0.1,
                0.0,
                0.0,
                &[],
            )
            .expect("valid editor settings");
        assert_eq!(revision, 1);
        doc.update_brush_settings(
            brush,
            42.0,
            0.7,
            0.08,
            0.2,
            0.55,
            0.2,
            0.5,
            0.75,
            1.0,
            0.35,
            0.1,
            0.0,
            0.0,
            &[0.0, 0.0, 0.25, 0.1, 0.6, 0.8, 1.0, 1.0],
        )
        .expect("valid multi-point curve");
        let stored_brush: BrushPresetV2 =
            serde_json::from_slice(&doc.snapshot().brushes[0]).expect("stored brush");
        assert_eq!(
            stored_brush
                .dynamics
                .iter()
                .find(|binding| binding.target == ParameterId::Diameter)
                .expect("pressure size binding")
                .curve
                .points
                .len(),
            4
        );
        let before_invalid_curve = doc.snapshot().brushes.clone();
        assert!(
            doc.update_brush_settings(
                brush,
                42.0,
                0.7,
                0.08,
                0.2,
                0.55,
                0.2,
                0.5,
                0.75,
                1.0,
                0.35,
                0.1,
                0.0,
                0.0,
                &[0.0, 0.0, 0.8, 0.2, 0.7, 0.9, 1.0, 1.0],
            )
            .is_err()
        );
        assert_eq!(doc.snapshot().brushes, before_invalid_curve);
        let layer = doc.layers()[0].id;
        let stroke = ink_model::StrokeId::from_u128(494);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke,
            layer,
            brush,
        })
        .expect("begin edited brush");
        doc.push_pointer_packet(&ink_test_support::one_sample(48.0, 48.0, 1.0))
            .expect("sample");
        doc.dispatch(EditorCommand::EndStroke { stroke })
            .expect("end edited brush");
        assert!(doc.time_lapse().strokes.iter().any(|item| item.brush == 6));
        let projected = doc
            .brush_summaries()
            .into_iter()
            .find(|summary| summary.id == brush)
            .expect("edited brush projection");
        for (actual, expected) in [
            (projected.diameter_px, 42.0),
            (projected.opacity, 0.7),
            (projected.spacing, 0.08),
            (projected.smoothing, 0.2),
            (projected.pressure_size, 0.55),
            (projected.pressure_opacity, 0.2),
            (projected.hardness, 0.75),
            (projected.scatter, 0.35),
            (projected.rotation_jitter, 0.1),
        ] {
            assert!((actual - expected).abs() < 1e-6);
        }
        assert_eq!(
            projected.pressure_curve_points,
            vec![0.0, 0.0, 0.25, 0.1, 0.6, 0.8, 1.0, 1.0]
        );
        let root =
            std::env::temp_dir().join(format!("project-ink-brush-save-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).expect("temp root");
        let path = root.join("brushes.inkproj");
        doc.save_as(&path).expect("save brush override");
        let reopened = Document::open(&path).expect("reopen brush override");
        assert_eq!(reopened.snapshot().brushes.len(), 1);
        let reopened_projection = reopened
            .brush_summaries()
            .into_iter()
            .find(|summary| summary.id == brush)
            .expect("reopened brush projection");
        assert_eq!(reopened_projection, projected);
        let exported_path = root.join("brushes.inkbrush");
        let mut reopened_for_export = reopened;
        reopened_for_export
            .export_brush(brush, &exported_path)
            .expect("export edited brush");
        let exported = ink_brush::import_inkbrush(&exported_path)
            .expect("import exported edited brush")
            .preset
            .expect("exported preset");
        let exported_projection = brush_summary_projection(&exported);
        assert_eq!(exported_projection, projected);
        std::fs::remove_dir_all(root).expect("cleanup");
        assert!(
            doc.update_brush_settings(
                brush,
                f32::NAN,
                0.7,
                0.08,
                0.2,
                0.55,
                0.2,
                0.5,
                0.75,
                1.0,
                0.35,
                0.1,
                0.0,
                0.0,
                &[],
            )
            .is_err()
        );
    }

    #[test]
    fn duplicated_brush_is_persisted_and_undoable() {
        let spec = DocumentSpec {
            width_px: 128,
            height_px: 128,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(498), spec).expect("valid doc");
        assert!(doc.rename_brush(BrushId::from_u128(1), "Nope").is_err());
        let duplicate = doc
            .duplicate_brush(BrushId::from_u128(1))
            .expect("duplicate built-in brush");
        assert!(duplicate.0 > 12);
        let projected = doc
            .brush_summaries()
            .into_iter()
            .find(|summary| summary.id == duplicate)
            .expect("duplicated projection");
        assert!(projected.name.ends_with(" Copy"));
        assert_eq!(doc.snapshot().brushes.len(), 1);

        doc.dispatch(EditorCommand::Undo).expect("undo duplicate");
        assert!(
            doc.brush_summaries()
                .into_iter()
                .all(|summary| summary.id != duplicate)
        );
        doc.dispatch(EditorCommand::Redo).expect("redo duplicate");
        let before_rename = doc
            .brush_summaries()
            .into_iter()
            .find(|summary| summary.id == duplicate)
            .expect("duplicated brush before rename");
        doc.rename_brush(duplicate, "  Story Ink  ")
            .expect("rename duplicated brush");
        let renamed = doc
            .brush_summaries()
            .into_iter()
            .find(|summary| summary.id == duplicate)
            .expect("renamed brush projection");
        assert_eq!(renamed.name, "Story Ink");
        assert_eq!(renamed.diameter_px, before_rename.diameter_px);
        assert_eq!(renamed.opacity, before_rename.opacity);
        assert!(doc.rename_brush(duplicate, " \n ").is_err());
        doc.dispatch(EditorCommand::Undo)
            .expect("undo brush rename");
        assert_eq!(
            doc.brush_summaries()
                .into_iter()
                .find(|summary| summary.id == duplicate)
                .expect("brush after undo rename")
                .name,
            before_rename.name
        );
        doc.dispatch(EditorCommand::Redo)
            .expect("redo brush rename");
        assert!(
            doc.brush_summaries()
                .into_iter()
                .any(|summary| summary.id == duplicate)
        );

        let root = std::env::temp_dir().join(format!(
            "project-ink-duplicate-brush-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).expect("duplicate temp root");
        let path = root.join("duplicate.inkproj");
        doc.save_as(&path).expect("save duplicate");
        let reopened = Document::open(&path).expect("reopen duplicate");
        assert_eq!(
            reopened
                .brush_summaries()
                .into_iter()
                .find(|summary| summary.id == duplicate)
                .expect("reopened renamed brush")
                .name,
            "Story Ink"
        );
        std::fs::remove_dir_all(root).expect("cleanup duplicate temp root");
    }

    #[test]
    fn imported_tip_resource_renders_exports_and_reopens() {
        let root =
            std::env::temp_dir().join(format!("project-ink-resource-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).expect("temp root");
        let pack_path = root.join("tip.inkbrush");
        let resource_data = vec![255; 16];
        let resource_hash: [u8; 32] = <sha2::Sha256 as sha2::Digest>::digest(&resource_data).into();
        let mut preset = builtin_library()
            .into_iter()
            .find(|preset| preset.metadata.name == "Opaque Round")
            .expect("opaque brush");
        if let TipBehavior::Stamp(tip) = &mut preset.tip {
            tip.resource_hash = Some(resource_hash);
        }
        let resource = ink_brush::ImportedResource {
            name: "tip.rgba".into(),
            kind: "tip".into(),
            sha256: resource_hash,
            bytes: u64::try_from(resource_data.len()).expect("resource length"),
            data: resource_data,
            width: 2,
            height: 2,
        };
        ink_brush::export_inkbrush_with_resources(&pack_path, &preset, &[resource])
            .expect("resource pack export");

        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(495), spec).expect("valid doc");
        let source_hash = ink_brush::inspect_brush_import(&pack_path)
            .expect("inspect resource pack")
            .source_sha256;
        let brush_id = doc
            .import_brush_verified(&pack_path, Some(source_hash))
            .expect("install resource brush");
        let layer = doc.layers()[0].id;
        let stroke = ink_model::StrokeId::from_u128(496);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke,
            layer,
            brush: brush_id,
        })
        .expect("begin resource stroke");
        doc.push_pointer_packet(&ink_test_support::one_sample(64.0, 64.0, 1.0))
            .expect("resource sample");
        doc.dispatch(EditorCommand::EndStroke { stroke })
            .expect("end resource stroke");
        let painted = doc
            .read_tile(layer, TileCoord { x: 0, y: 0 })
            .expect("resource tile");
        assert!(painted.iter().any(|byte| *byte != 0));

        let document_path = root.join("resource.inkproj");
        doc.save_as(&document_path).expect("save resource document");
        let mut reopened = Document::open(&document_path).expect("reopen resource document");
        assert_eq!(reopened.snapshot().resources.len(), 1);
        let reopened_layer = reopened.layers()[0].id;
        let before_reopened_stroke = reopened
            .read_tile(reopened_layer, TileCoord { x: 0, y: 0 })
            .expect("reopened resource tile before stroke");
        let reopened_stroke = ink_model::StrokeId::from_u128(497);
        reopened
            .dispatch(EditorCommand::BeginStroke {
                stroke: reopened_stroke,
                layer: reopened_layer,
                brush: brush_id,
            })
            .expect("begin stroke with reopened resource brush");
        reopened
            .push_pointer_packet(&ink_test_support::one_sample(160.0, 160.0, 1.0))
            .expect("reopened resource sample");
        reopened
            .dispatch(EditorCommand::EndStroke {
                stroke: reopened_stroke,
            })
            .expect("end stroke with reopened resource brush");
        let after_reopened_stroke = reopened
            .read_tile(reopened_layer, TileCoord { x: 0, y: 0 })
            .expect("reopened resource tile after stroke");
        assert_ne!(after_reopened_stroke, before_reopened_stroke);

        let exported_path = root.join("exported.inkbrush");
        reopened
            .export_brush(brush_id, &exported_path)
            .expect("export resource brush");
        let exported = ink_brush::import_inkbrush(&exported_path).expect("reopen resource pack");
        assert_eq!(exported.resources.len(), 1);
        std::fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn brush_drafts_are_transactional_and_cancel_without_installing() {
        let spec = DocumentSpec {
            width_px: 128,
            height_px: 128,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(497), spec).expect("valid doc");
        let brush = BrushId::from_u128(6);
        let before_cancel = doc.snapshot();
        let draft = doc.begin_brush_draft(brush).expect("begin draft");
        doc.update_brush_draft(
            draft,
            24.0,
            0.8,
            0.1,
            0.25,
            0.6,
            0.2,
            0.55,
            0.75,
            1.0,
            0.2,
            0.1,
            0.15,
            0.3,
            &[0.0, 0.0, 0.4, 0.3, 1.0, 1.0],
        )
        .expect("update draft");
        assert_eq!(doc.snapshot().revision, before_cancel.revision);
        assert!(doc.snapshot().brushes.is_empty());
        doc.cancel_brush_draft(draft).expect("cancel draft");
        assert_eq!(
            doc.snapshot(),
            before_cancel,
            "cancelling a preview must leave the complete persisted document unchanged"
        );

        let committed = doc.begin_brush_draft(brush).expect("begin committed draft");
        doc.update_brush_draft(
            committed,
            24.0,
            0.8,
            0.1,
            0.25,
            0.6,
            0.2,
            0.55,
            0.75,
            1.0,
            0.2,
            0.1,
            0.15,
            0.3,
            &[0.0, 0.0, 0.4, 0.3, 1.0, 1.0],
        )
        .expect("update committed draft");
        let revision = doc
            .commit_brush_draft(committed)
            .expect("commit brush draft");
        assert_eq!(revision, 1);
        assert_eq!(doc.snapshot().brushes.len(), 1);
        assert!(doc.cancel_brush_draft(committed).is_err());
    }

    #[test]
    fn committed_brush_draft_changes_the_rendered_stroke() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(498), spec).expect("valid doc");
        let layer = doc.layers()[0].id;
        let blank = doc
            .read_tile(layer, TileCoord { x: 0, y: 0 })
            .expect("blank tile");
        let source = BrushId::from_u128(3); // Opaque Round.
        let custom = doc.duplicate_brush(source).expect("duplicate brush");

        let draw = |doc: &mut Document, stroke_id: u128| {
            doc.dispatch(EditorCommand::BeginStroke {
                stroke: ink_model::StrokeId::from_u128(stroke_id),
                layer,
                brush: custom,
            })
            .expect("begin stroke");
            doc.push_pointer_packet(&ink_test_support::one_sample(128.0, 128.0, 1.0))
                .expect("dab sample");
            doc.dispatch(EditorCommand::EndStroke {
                stroke: ink_model::StrokeId::from_u128(stroke_id),
            })
            .expect("end stroke");
            doc.read_tile(layer, TileCoord { x: 0, y: 0 })
                .expect("rendered tile")
        };

        let original_render = draw(&mut doc, 499);
        doc.dispatch(EditorCommand::Undo)
            .expect("undo source stroke");
        let after_undo = doc
            .read_tile(layer, TileCoord { x: 0, y: 0 })
            .expect("blank after undo");
        assert_eq!(after_undo, blank);

        let settings = doc
            .brush_summaries()
            .into_iter()
            .find(|summary| summary.id == custom)
            .expect("custom brush summary");
        let draft = doc.begin_brush_draft(custom).expect("begin edit");
        doc.update_brush_draft(
            draft,
            72.0,
            settings.opacity,
            settings.spacing,
            settings.smoothing,
            settings.pressure_size,
            settings.pressure_opacity,
            0.5,
            settings.hardness,
            settings.texture_scale,
            settings.scatter,
            settings.rotation_jitter,
            settings.smudge,
            settings.wetness,
            &settings.pressure_curve_points,
        )
        .expect("update diameter draft");
        doc.commit_brush_draft(draft).expect("commit edit");

        let edited_render = draw(&mut doc, 500);
        assert_ne!(
            original_render, edited_render,
            "committing a brush edit must affect the pixels produced by that brush"
        );
        assert_eq!(doc.snapshot().brushes.len(), 1);
    }

    #[test]
    fn edited_custom_brush_and_stroke_survive_document_reopen() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(50_103), spec).expect("valid document");
        let layer = doc.layers()[0].id;
        let custom = doc
            .duplicate_brush(BrushId::from_u128(3))
            .expect("duplicate Opaque Round");
        let settings = doc
            .brush_summaries()
            .into_iter()
            .find(|summary| summary.id == custom)
            .expect("custom brush summary");
        let draft = doc.begin_brush_draft(custom).expect("begin brush edit");
        doc.update_brush_draft(
            draft,
            72.0,
            settings.opacity,
            settings.spacing,
            settings.smoothing,
            settings.pressure_size,
            settings.pressure_opacity,
            0.5,
            settings.hardness,
            settings.texture_scale,
            settings.scatter,
            settings.rotation_jitter,
            settings.smudge,
            settings.wetness,
            &settings.pressure_curve_points,
        )
        .expect("update draft size");
        doc.commit_brush_draft(draft).expect("commit brush edit");

        let stroke = StrokeId::from_u128(50_104);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke,
            layer,
            brush: custom,
        })
        .expect("begin custom-brush stroke");
        doc.push_pointer_packet(&ink_test_support::one_sample(128.0, 128.0, 1.0))
            .expect("draw custom-brush dab");
        doc.dispatch(EditorCommand::EndStroke { stroke })
            .expect("commit custom-brush stroke");
        let painted = doc
            .read_tile(layer, TileCoord { x: 0, y: 0 })
            .expect("read custom-brush tile");

        let root = std::env::temp_dir().join(format!(
            "project-ink-edited-brush-reopen-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).expect("create isolated package root");
        let path = root.join("edited-brush.inkproj");
        doc.save_as(&path).expect("save custom-brush document");
        let reopened = Document::open(&path).expect("reopen custom-brush document");
        let reopened_summary = reopened
            .brush_summaries()
            .into_iter()
            .find(|summary| summary.id == custom)
            .expect("reopened custom brush");
        assert!((reopened_summary.diameter_px - 72.0).abs() < 0.01);
        assert_eq!(
            reopened
                .read_tile(layer, TileCoord { x: 0, y: 0 })
                .expect("reopened custom-brush tile"),
            painted,
            "the saved stroke pixels must remain unchanged"
        );
        std::fs::remove_dir_all(root).expect("clean isolated package root");
    }

    #[test]
    fn edited_brush_export_import_changes_stroke_and_survives_reopen() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut source =
            Document::new(DocumentId::from_u128(50_201), spec).expect("source document");
        let custom = source
            .duplicate_brush(BrushId::from_u128(3))
            .expect("duplicate Opaque Round");
        let settings = source
            .brush_summaries()
            .into_iter()
            .find(|summary| summary.id == custom)
            .expect("custom brush summary");
        let draft = source.begin_brush_draft(custom).expect("begin brush edit");
        source
            .update_brush_draft(
                draft,
                72.0,
                settings.opacity,
                settings.spacing,
                settings.smoothing,
                settings.pressure_size,
                settings.pressure_opacity,
                0.5,
                settings.hardness,
                settings.texture_scale,
                settings.scatter,
                settings.rotation_jitter,
                settings.smudge,
                settings.wetness,
                &settings.pressure_curve_points,
            )
            .expect("update custom brush diameter");
        source.commit_brush_draft(draft).expect("commit brush edit");

        let root = std::env::temp_dir().join(format!(
            "project-ink-brush-asset-roundtrip-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).expect("create isolated package root");
        let brush_path = root.join("edited.inkbrush");
        source
            .export_brush(custom, &brush_path)
            .expect("export edited brush");

        let mut target =
            Document::new(DocumentId::from_u128(50_202), spec).expect("target document");
        let layer = target.layers()[0].id;
        let imported = target.import_brush(&brush_path).expect("import brush");
        let imported_summary = target
            .brush_summaries()
            .into_iter()
            .find(|summary| summary.id == imported)
            .expect("imported brush summary");
        assert!((imported_summary.diameter_px - 72.0).abs() < 0.01);

        let draw = |doc: &mut Document, brush: BrushId, stroke_id: u128, x: f32, y: f32| {
            doc.dispatch(EditorCommand::BeginStroke {
                stroke: StrokeId::from_u128(stroke_id),
                layer,
                brush,
            })
            .expect("begin brush stroke");
            doc.push_pointer_packet(&ink_test_support::one_sample(x, y, 1.0))
                .expect("push brush dab");
            doc.dispatch(EditorCommand::EndStroke {
                stroke: StrokeId::from_u128(stroke_id),
            })
            .expect("finish brush stroke");
            doc.read_tile(layer, TileCoord { x: 0, y: 0 })
                .expect("read rendered tile")
        };

        let baseline = draw(&mut target, BrushId::from_u128(3), 50_203, 128.0, 128.0);
        target
            .dispatch(EditorCommand::Undo)
            .expect("undo baseline stroke");
        let imported_pixels = draw(&mut target, imported, 50_204, 128.0, 128.0);
        assert_ne!(
            baseline, imported_pixels,
            "the imported edit must change the raster output"
        );

        let project_path = root.join("imported-brush.inkproj");
        target
            .save_as(&project_path)
            .expect("save imported brush project");
        let mut reopened = Document::open(&project_path).expect("reopen project");
        let reopened_summary = reopened
            .brush_summaries()
            .into_iter()
            .find(|summary| summary.id == imported)
            .expect("reopened imported brush");
        assert!((reopened_summary.diameter_px - 72.0).abs() < 0.01);
        assert_eq!(
            reopened
                .read_tile(layer, TileCoord { x: 0, y: 0 })
                .expect("reopened imported stroke"),
            imported_pixels,
            "saved imported-brush pixels must remain unchanged"
        );
        let after_reopen = draw(&mut reopened, imported, 50_205, 64.0, 64.0);
        assert_ne!(
            imported_pixels, after_reopen,
            "the imported brush remains usable after document reopen"
        );
        std::fs::remove_dir_all(root).expect("clean isolated package root");
    }

    #[test]
    fn committed_strokes_are_available_for_time_lapse_export() {
        let spec = DocumentSpec {
            width_px: 128,
            height_px: 128,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(493), spec).expect("document");
        let layer = doc.layers()[0].id;
        let stroke = ink_model::StrokeId::from_u128(494);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke,
            layer,
            brush: ink_model::BrushId::from_u128(8),
        })
        .expect("begin");
        doc.push_pointer_packet(&ink_test_support::one_sample(12.0, 12.0, 1.0))
            .expect("sample");
        doc.dispatch(EditorCommand::EndStroke { stroke })
            .expect("end");
        assert_eq!(doc.time_lapse().strokes.len(), 1);
        let path =
            std::env::temp_dir().join(format!("project-ink-timelapse-{}.json", std::process::id()));
        doc.export_time_lapse(&path).expect("export");
        let bytes = std::fs::read(&path).expect("bytes");
        assert!(bytes.windows(7).any(|window| window == b"strokes"));
        std::fs::remove_file(path).expect("cleanup");
    }

    #[test]
    fn full_time_lapse_recording_never_rejects_a_committed_drawing_stroke() {
        assert!(time_lapse_has_capacity_at(
            TimeLapseRecording::MAX_STROKES - 1,
            TimeLapseRecording::MAX_SAMPLES - 1,
            1,
        ));
        assert!(!time_lapse_has_capacity_at(
            0,
            TimeLapseRecording::MAX_SAMPLES,
            1,
        ));

        let spec = DocumentSpec {
            width_px: 128,
            height_px: 128,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(495), spec).expect("document");
        let layer = doc.layers()[0].id;
        {
            let mut state = lock_recover(&doc.state);
            state.time_lapse.strokes = (0..TimeLapseRecording::MAX_STROKES)
                .map(|_| TimeLapseStroke {
                    revision: 0,
                    layer: 0,
                    brush: 0,
                    samples: Vec::new(),
                })
                .collect();
        }

        let brushes = [
            BrushPreset::starters()[0].id,
            BrushId::from_u128(8),
            BrushPreset::starters()[1].id,
        ];
        for (stroke_index, brush) in brushes.into_iter().enumerate() {
            let center_x = 24.0 + stroke_index as f32 * 40.0;
            let stroke = StrokeId::from_u128(496 + stroke_index as u128);
            doc.dispatch(EditorCommand::BeginStroke {
                stroke,
                layer,
                brush,
            })
            .expect("begin stroke when optional time-lapse is full");
            let samples = (0..900)
                .map(|sequence| {
                    let progress = sequence as f32 / 899.0;
                    let angle = progress * std::f32::consts::TAU * 3.0;
                    let radius = 2.0 + progress * 12.0;
                    ink_input::PointerSample {
                        pointer_id: 1,
                        flags: flags::ACTUAL,
                        device_kind: ink_input::DeviceKind::Stylus,
                        phase: if sequence == 0 {
                            ink_input::Phase::Down
                        } else {
                            ink_input::Phase::Move
                        },
                        canvas_x: center_x + radius * angle.cos(),
                        canvas_y: 64.0 + radius * angle.sin(),
                        pressure: u16::MAX,
                        tilt_x: 0.0,
                        tilt_y: 0.0,
                        azimuth: 0.0,
                        twist: 0.0,
                        timestamp_ns: u64::from(sequence) * 1_000_000,
                        sequence,
                    }
                })
                .collect::<Vec<_>>();
            for packet in samples.chunks(ink_input::MAX_SAMPLES) {
                doc.push_pointer_packet(&ink_test_support::pointer_packet(packet))
                    .expect("queue repeated long spiral");
            }
            doc.dispatch(EditorCommand::EndStroke { stroke })
                .expect("time-lapse capacity must not reject drawing");
            let pixels = doc
                .read_composite_tile(TileCoord { x: 0, y: 0 })
                .expect("read committed canvas pixels");
            let x = center_x as usize;
            let center_alpha = pixels[(64 * 256 + x) * 4 + 3];
            assert!(
                center_alpha > 0,
                "brush {brush:?} spiral {stroke_index} must remain committed"
            );
        }
        let state = lock_recover(&doc.state);
        assert!(
            state.active_stroke.is_none(),
            "the stroke transaction must close"
        );
        assert_eq!(
            state.time_lapse.strokes.len(),
            TimeLapseRecording::MAX_STROKES
        );
    }

    #[test]
    fn phase_two_sketch_ink_color_vector_and_export_workflow() {
        let spec = DocumentSpec {
            width_px: 128,
            height_px: 128,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc =
            Document::new(DocumentId::from_u128(0x5048_4153_4532), spec).expect("document");
        let raster = doc.layers()[0].id;
        let brush_id = |name: &str| {
            builtin_library()
                .into_iter()
                .find(|preset| preset.metadata.name == name)
                .map(|preset| preset.id)
                .expect("built-in brush")
        };

        for (stroke, brush, points) in [
            (
                1_u128,
                brush_id("HB Sketch Pencil"),
                vec![(18.0, 20.0, 0.35), (32.0, 28.0, 0.7)],
            ),
            (
                2_u128,
                brush_id("Technical Pen"),
                vec![(32.0, 28.0, 0.5), (76.0, 64.0, 1.0)],
            ),
        ] {
            let stroke = ink_model::StrokeId::from_u128(stroke);
            doc.dispatch(EditorCommand::BeginStroke {
                stroke,
                layer: raster,
                brush,
            })
            .expect("begin stroke");
            for (x, y, pressure) in points {
                doc.push_pointer_packet(&ink_test_support::one_sample(x, y, pressure))
                    .expect("sample");
            }
            doc.dispatch(EditorCommand::EndStroke { stroke })
                .expect("end stroke");
        }

        let paint_brush = brush_id("Opaque Round");
        doc.update_brush_color(
            paint_brush,
            Rgba8 {
                r: 230,
                g: 80,
                b: 40,
                a: 255,
            },
        )
        .expect("set paint color");
        let color_stroke = ink_model::StrokeId::from_u128(3);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke: color_stroke,
            layer: raster,
            brush: paint_brush,
        })
        .expect("begin color stroke");
        doc.push_pointer_packet(&ink_test_support::one_sample(80.0, 80.0, 1.0))
            .expect("color sample");
        doc.dispatch(EditorCommand::EndStroke {
            stroke: color_stroke,
        })
        .expect("end color stroke");

        let vector = doc.add_layer(LayerKind::VectorInk).expect("vector layer");
        doc.add_vector_stroke(
            vector,
            ink_model::StrokeId::from_u128(4),
            vec![(10.0, 100.0, 0.4, 0.0), (100.0, 100.0, 1.0, 0.0)],
            false,
        )
        .expect("vector stroke");
        assert!(
            !doc.vector_stroke_summaries(vector)
                .expect("vector summary")
                .is_empty()
        );

        let root = std::env::temp_dir().join(format!(
            "project-ink-phase2-workflow-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).expect("temporary root");
        let exports = [
            ("drawing.png", ink_export::ExportFormat::Png),
            ("drawing.jpg", ink_export::ExportFormat::Jpeg),
            ("drawing.webp", ink_export::ExportFormat::Webp),
            ("drawing.ora", ink_export::ExportFormat::OpenRaster),
            ("drawing.svg", ink_export::ExportFormat::Svg),
            ("drawing.psd", ink_export::ExportFormat::Psd),
        ];
        for (name, format) in exports {
            let path = root.join(name);
            doc.export(&path, format).expect("export");
            assert!(std::fs::metadata(path).expect("export metadata").len() > 0);
        }
        assert!(doc.time_lapse().strokes.len() >= 3);

        let painted = doc
            .read_tile(raster, TileCoord { x: 0, y: 0 })
            .expect("painted tile");
        doc.dispatch(EditorCommand::Undo).expect("undo vector");
        doc.dispatch(EditorCommand::Redo).expect("redo vector");
        assert_eq!(
            doc.read_tile(raster, TileCoord { x: 0, y: 0 })
                .expect("raster after vector undo/redo"),
            painted
        );
        std::fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn save_and_reopen_preserves_revision_layers_and_pixels() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(19), spec).expect("valid doc");
        let layer = doc.layers()[0].id;
        let stroke = ink_model::StrokeId::from_u128(20);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke,
            layer,
            brush: BrushPreset::starters()[0].id,
        })
        .expect("begin");
        doc.push_pointer_packet(&ink_test_support::one_sample(10.0, 10.0, 1.0))
            .expect("sample");
        let root = std::env::temp_dir().join(format!("project-ink-engine-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).expect("temp root");
        let path = root.join("drawing.inkproj");
        doc.save_as(&path).expect("save");
        let mut reopened = Document::open(&path).expect("reopen");
        assert_eq!(reopened.revision(), doc.revision());
        assert_eq!(reopened.layers(), doc.layers());
        let saved_tile = doc
            .read_tile(layer, TileCoord { x: 0, y: 0 })
            .expect("tile");
        assert_eq!(
            reopened
                .read_tile(layer, TileCoord { x: 0, y: 0 })
                .expect("tile"),
            saved_tile
        );
        let replay = reopened.replay_journal().expect("replay persisted journal");
        assert_eq!(replay.command_count, 1);
        assert_eq!(replay.command_revision, 1);
        assert_eq!(replay.layer_count, 1);
        assert!(replay.active_stroke);
        reopened
            .dispatch(EditorCommand::Undo)
            .expect("recovered undo");
        assert_ne!(
            reopened
                .read_tile(layer, TileCoord { x: 0, y: 0 })
                .expect("undo tile"),
            saved_tile
        );
        reopened
            .dispatch(EditorCommand::Redo)
            .expect("recovered redo");
        assert_eq!(
            reopened
                .read_tile(layer, TileCoord { x: 0, y: 0 })
                .expect("redo tile"),
            saved_tile
        );
        let png_path = root.join("drawing.png");
        doc.export_png(&png_path).expect("png export");
        let png = std::fs::read(&png_path).expect("png bytes");
        assert_eq!(&png[..8], b"\x89PNG\r\n\x1a\n");
        let webp_path = root.join("drawing.webp");
        doc.export(&webp_path, ink_export::ExportFormat::Webp)
            .expect("webp export");
        let webp = std::fs::read(&webp_path).expect("webp bytes");
        assert_eq!(&webp[..4], b"RIFF");
        assert_eq!(&webp[8..12], b"WEBP");
        std::fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn stroke_undo_and_redo_restore_pixels() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(29), spec).expect("valid doc");
        let layer = doc.layers()[0].id;
        let blank = doc
            .read_tile(layer, TileCoord { x: 0, y: 0 })
            .expect("blank");
        let stroke = ink_model::StrokeId::from_u128(30);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke,
            layer,
            brush: BrushPreset::starters()[0].id,
        })
        .expect("begin");
        doc.push_pointer_packet(&ink_test_support::one_sample(10.0, 10.0, 1.0))
            .expect("sample");
        doc.dispatch(EditorCommand::EndStroke { stroke })
            .expect("end");
        let inked = doc
            .read_tile(layer, TileCoord { x: 0, y: 0 })
            .expect("inked");
        assert_ne!(inked, blank);
        doc.dispatch(EditorCommand::Undo).expect("undo");
        assert_eq!(
            doc.read_tile(layer, TileCoord { x: 0, y: 0 })
                .expect("undo tile"),
            blank
        );
        doc.dispatch(EditorCommand::Redo).expect("redo");
        assert_eq!(
            doc.read_tile(layer, TileCoord { x: 0, y: 0 })
                .expect("redo tile"),
            inked
        );
    }

    #[test]
    fn eraser_flag_removes_raster_pixels() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(69), spec).expect("valid doc");
        let layer = doc.layers()[0].id;
        let blank = doc
            .read_tile(layer, TileCoord { x: 0, y: 0 })
            .expect("blank");
        let first_stroke = ink_model::StrokeId::from_u128(70);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke: first_stroke,
            layer,
            brush: BrushPreset::starters()[0].id,
        })
        .expect("begin ink");
        doc.push_pointer_packet(&ink_test_support::one_sample(10.0, 10.0, 1.0))
            .expect("ink sample");
        doc.dispatch(EditorCommand::EndStroke {
            stroke: first_stroke,
        })
        .expect("end ink");
        let inked = doc
            .read_tile(layer, TileCoord { x: 0, y: 0 })
            .expect("inked");
        assert_ne!(inked, blank);

        let erase_stroke = ink_model::StrokeId::from_u128(71);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke: erase_stroke,
            layer,
            brush: BrushPreset::starters()[0].id,
        })
        .expect("begin eraser");
        let mut eraser_packet = ink_test_support::one_sample(10.0, 10.0, 1.0);
        eraser_packet[8] = (flags::ACTUAL | flags::ERASER) as u8;
        eraser_packet[9] = 0;
        doc.push_pointer_packet(&eraser_packet)
            .expect("erase sample");
        doc.dispatch(EditorCommand::EndStroke {
            stroke: erase_stroke,
        })
        .expect("end eraser");
        assert_eq!(
            doc.read_tile(layer, TileCoord { x: 0, y: 0 })
                .expect("erased"),
            blank
        );
    }

    #[test]
    fn unrecoverable_stroke_work_limit_is_reported_and_cancelable() {
        let spec = DocumentSpec {
            width_px: 64,
            height_px: 64,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(0x574f_524b_4c49_4d49), spec)
            .expect("valid document");
        let stroke = ink_model::StrokeId::from_u128(0x574f_524b_4c49_4d49);
        let layer = doc.layers()[0].id;
        doc.dispatch(EditorCommand::BeginStroke {
            stroke,
            layer,
            brush: BrushPreset::starters()[0].id,
        })
        .expect("begin stroke");
        lock_recover(&doc.state)
            .active_stroke
            .as_mut()
            .expect("active stroke")
            .work_limit_reached = true;

        let error = doc
            .dispatch(EditorCommand::EndStroke { stroke })
            .expect_err("an incomplete bounded stroke must be reported");
        assert!(error.to_string().contains("stroke_work_limit_reached"));
        doc.dispatch(EditorCommand::CancelStroke { stroke })
            .expect("the caller can cancel the incomplete transaction");
    }

    #[test]
    fn canceled_stroke_restores_pixels_and_history() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(39), spec).expect("valid doc");
        let layer = doc.layers()[0].id;
        let blank = doc
            .read_tile(layer, TileCoord { x: 0, y: 0 })
            .expect("blank");
        let stroke = ink_model::StrokeId::from_u128(40);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke,
            layer,
            brush: BrushPreset::starters()[0].id,
        })
        .expect("begin");
        doc.push_pointer_packet(&ink_test_support::one_sample(10.0, 10.0, 1.0))
            .expect("sample");
        assert_ne!(
            doc.read_tile(layer, TileCoord { x: 0, y: 0 })
                .expect("inked"),
            blank
        );
        doc.dispatch(EditorCommand::CancelStroke { stroke })
            .expect("cancel");
        assert_eq!(
            doc.read_tile(layer, TileCoord { x: 0, y: 0 })
                .expect("canceled tile"),
            blank
        );
        doc.dispatch(EditorCommand::Undo)
            .expect("undo prior command");
        assert_eq!(doc.layers().len(), 1);
    }

    #[test]
    fn oversized_png_export_fails_before_allocating_a_full_frame() {
        let spec = DocumentSpec {
            width_px: 32_768,
            height_px: 32_768,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let doc = Document::new(DocumentId::from_u128(70), spec).expect("valid doc");
        let path = std::env::temp_dir().join(format!(
            "project-ink-export-limit-{}.png",
            std::process::id()
        ));
        assert!(matches!(
            doc.export_png(&path),
            Err(EngineError::InvalidCommand(message)) if message.contains("memory safety limit")
        ));
        assert!(!path.exists());
    }

    #[test]
    fn closed_worker_rejects_new_pointer_packets_without_blocking() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(71), spec).expect("valid doc");
        doc.close();
        let result = doc.push_pointer_packet(&ink_test_support::one_sample(1.0, 1.0, 1.0));
        assert!(matches!(
            result,
            Err(EngineError::WorkerUnavailable(message)) if message.contains("closed")
        ));
        doc.close();
    }

    #[test]
    fn oversized_pointer_packet_is_rejected_before_queue_copy() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(72), spec).expect("valid doc");
        let packet = vec![0u8; ink_input::MAX_PACKET_BYTES + 1];
        assert!(matches!(
            doc.push_pointer_packet(&packet),
            Err(EngineError::Packet(ink_input::PacketError::TrailingBytes))
        ));
    }

    #[test]
    fn pointer_samples_outside_canvas_are_clipped_at_the_page_boundary() {
        let spec = DocumentSpec {
            width_px: 64,
            height_px: 64,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(73), spec).expect("valid doc");
        let layer = doc.layers()[0].id;
        let stroke = StrokeId::from_u128(74);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke,
            layer,
            brush: BrushPreset::starters()[0].id,
        })
        .expect("begin");
        doc.push_pointer_packet(&ink_test_support::one_sample(32.0, 32.0, 1.0))
            .expect("inside sample");
        doc.push_pointer_packet(&ink_test_support::one_sample(65_536.0, -65_536.0, 1.0))
            .expect("outside sample");
        doc.push_pointer_packet(&ink_test_support::one_sample(65_536.0, -32.0, 1.0))
            .expect("captured motion remains outside");
        doc.push_pointer_packet(&ink_test_support::one_sample(32.0, 8.0, 1.0))
            .expect("re-entry sample is ignored until pointer-up");
        doc.flush_input().expect("bounded samples are rendered");
        {
            let state = lock_recover(&doc.state);
            let samples = &state.active_stroke.as_ref().expect("active stroke").samples;
            assert_eq!(samples.len(), 2);
            assert_eq!(samples[1].canvas_x.to_bits(), 63.0_f32.to_bits());
            assert!((samples[1].canvas_y - 0.9697).abs() < 0.001);
            assert_eq!(
                samples.len(),
                2,
                "captured outside motion cannot draw a border or re-entry chord"
            );
        }
        doc.dispatch(EditorCommand::EndStroke { stroke })
            .expect("finish stroke");
        assert!(doc.layer_has_allocated_tiles(layer).expect("layer state"));
    }

    #[test]
    fn consecutive_in_canvas_samples_are_not_duplicated_at_segment_starts() {
        let spec = DocumentSpec {
            width_px: 64,
            height_px: 64,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(78), spec).expect("valid doc");
        let layer = doc.layers()[0].id;
        let stroke = StrokeId::from_u128(79);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke,
            layer,
            brush: BrushPreset::starters()[0].id,
        })
        .expect("begin stroke");
        for x in [8.0, 16.0, 24.0] {
            doc.push_pointer_packet(&ink_test_support::one_sample(x, 16.0, 1.0))
                .expect("queue in-canvas sample");
        }
        doc.flush_input().expect("render queued samples");
        let state = lock_recover(&doc.state);
        let active = state.active_stroke.as_ref().expect("active stroke");
        assert_eq!(active.input_metrics.sample_count, 3);
        assert_eq!(active.samples.len(), 3);
    }

    #[test]
    fn repeated_off_canvas_input_does_not_poison_the_next_stroke() {
        let spec = DocumentSpec {
            width_px: 64,
            height_px: 64,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(75), spec).expect("valid doc");
        let layer = doc.layers()[0].id;
        let stroke = StrokeId::from_u128(76);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke,
            layer,
            brush: BrushPreset::starters()[0].id,
        })
        .expect("begin edge stroke");
        for _ in 0..128 {
            doc.push_pointer_packet(&ink_test_support::one_sample(65_536.0, -65_536.0, 1.0))
                .expect("queue repeated edge sample");
            doc.flush_input().expect("edge sample is handled");
        }
        {
            let state = lock_recover(&doc.state);
            assert_eq!(
                state
                    .active_stroke
                    .as_ref()
                    .expect("edge stroke remains active")
                    .samples
                    .len(),
                0,
                "a stroke that remains outside the page should not create edge dabs"
            );
        }
        doc.dispatch(EditorCommand::EndStroke { stroke })
            .expect("finish edge stroke");

        let next_stroke = StrokeId::from_u128(77);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke: next_stroke,
            layer,
            brush: BrushPreset::starters()[0].id,
        })
        .expect("begin next stroke");
        doc.push_pointer_packet(&ink_test_support::one_sample(32.0, 32.0, 1.0))
            .expect("draw next stroke");
        doc.dispatch(EditorCommand::EndStroke {
            stroke: next_stroke,
        })
        .expect("finish next stroke");
        assert!(doc.layer_has_allocated_tiles(layer).expect("layer state"));
    }

    #[test]
    fn vector_strokes_are_bounded_undoable_and_persisted() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(73), spec).expect("valid doc");
        doc.dispatch(EditorCommand::AddLayer {
            parent: None,
            kind: LayerKind::VectorInk,
        })
        .expect("vector layer");
        let vector_layer = doc.layers()[1].id;
        doc.add_vector_stroke(
            vector_layer,
            ink_model::StrokeId::from_u128(74),
            vec![(1.0, 2.0, 0.25, 0.0), (8.0, 9.0, 1.0, 0.5)],
            false,
        )
        .expect("vector stroke");
        let snapshot = doc.snapshot();
        assert_eq!(snapshot.vectors.len(), 1);
        doc.dispatch(EditorCommand::Undo).expect("undo vector");
        assert!(doc.snapshot().vectors.is_empty());
        doc.dispatch(EditorCommand::Redo).expect("redo vector");
        assert_eq!(doc.snapshot().vectors.len(), 1);
    }

    #[test]
    fn vector_edits_rebuild_pixels_and_undo() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(75), spec).expect("valid doc");
        doc.dispatch(EditorCommand::AddLayer {
            parent: None,
            kind: LayerKind::VectorInk,
        })
        .expect("vector layer");
        let layer = doc.layers()[1].id;
        let first = ink_model::StrokeId::from_u128(76);
        let second = ink_model::StrokeId::from_u128(77);
        doc.add_vector_stroke(
            layer,
            first,
            vec![(10.0, 10.0, 1.0, 0.0), (20.0, 10.0, 1.0, 0.0)],
            false,
        )
        .expect("first stroke");
        let before = doc
            .read_tile(layer, TileCoord { x: 0, y: 0 })
            .expect("vector tile");
        assert!(before.iter().any(|byte| *byte != 0));
        doc.add_vector_stroke(
            layer,
            second,
            vec![(20.0, 10.0, 1.0, 0.0), (30.0, 10.0, 1.0, 0.0)],
            false,
        )
        .expect("second stroke");
        doc.transform_vector_stroke(layer, first, 1.0, 0.0, 0.0, 1.0, 5.0, 0.0)
            .expect("transform vector");
        assert!(
            (doc.vector_stroke_summaries(layer).expect("summary")[0].2[0] - 15.0).abs() < 0.001
        );
        doc.set_vector_point(layer, first, 0, 18.0, 12.0, 0.5, -0.25)
            .expect("set vector point");
        let summary = doc.vector_stroke_summaries(layer).expect("point summary");
        assert!((summary[0].3[0] - 18.0).abs() < 0.001);
        assert!((summary[0].3[2] - 0.5).abs() < 0.001);
        doc.dispatch(EditorCommand::Undo).expect("undo point edit");
        let restored = doc
            .vector_stroke_summaries(layer)
            .expect("restored summary");
        assert!((restored[0].3[0] - 15.0).abs() < 0.001);
        doc.connect_vector_strokes(layer, first, second, 8.0)
            .expect("connect vector");
        assert_eq!(doc.snapshot().vectors.len(), 1);
        doc.erase_vector_segment(layer, first, 25.0, 10.0, 2.0)
            .expect("erase vector");
        doc.dispatch(EditorCommand::Undo).expect("undo erase");
        assert_eq!(doc.snapshot().vectors.len(), 1);
        doc.dispatch(EditorCommand::Undo).expect("undo connect");
        assert_eq!(doc.snapshot().vectors.len(), 2);
    }

    #[test]
    fn vector_intersection_erase_is_undoable_at_engine_boundary() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(80), spec).expect("valid doc");
        doc.dispatch(EditorCommand::AddLayer {
            parent: None,
            kind: LayerKind::VectorInk,
        })
        .expect("vector layer");
        let layer = doc.layers()[1].id;
        let stroke = ink_model::StrokeId::from_u128(81);
        doc.add_vector_stroke(
            layer,
            stroke,
            vec![(10.0, 20.0, 0.0, 0.0), (40.0, 20.0, 1.0, 1.0)],
            false,
        )
        .expect("vector stroke");

        doc.erase_vector_segment(layer, stroke, 25.0, 20.0, 5.0)
            .expect("intersection erase");
        let erased = doc
            .vector_stroke_summaries(layer)
            .expect("erased summaries");
        assert_eq!(erased.len(), 2);
        assert!((erased[0].3[4] - 20.0).abs() < 0.001);
        assert!((erased[1].3[0] - 30.0).abs() < 0.001);
        assert!((erased[0].3[6] - (1.0 / 3.0)).abs() < 0.001);
        assert!((erased[1].3[2] - (2.0 / 3.0)).abs() < 0.001);

        doc.dispatch(EditorCommand::Undo)
            .expect("undo intersection erase");
        let restored = doc
            .vector_stroke_summaries(layer)
            .expect("restored summary");
        assert_eq!(restored.len(), 1);
        assert!((restored[0].3[0] - 10.0).abs() < 0.001);
        assert!((restored[0].3[4] - 40.0).abs() < 0.001);

        doc.dispatch(EditorCommand::Redo)
            .expect("redo intersection erase");
        assert_eq!(
            doc.vector_stroke_summaries(layer)
                .expect("redo summaries")
                .len(),
            2
        );
    }

    #[test]
    fn single_point_vector_stroke_rasterizes_and_resource_cache_evicts_lru() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(78), spec).expect("valid doc");
        doc.dispatch(EditorCommand::AddLayer {
            parent: None,
            kind: LayerKind::VectorInk,
        })
        .expect("vector layer");
        let layer = doc.layers()[1].id;
        doc.add_vector_stroke(
            layer,
            ink_model::StrokeId::from_u128(79),
            vec![(16.0, 16.0, 1.0, 0.0)],
            false,
        )
        .expect("point stroke");
        assert!(
            doc.read_tile(layer, TileCoord { x: 0, y: 0 })
                .expect("point tile")
                .iter()
                .any(|byte| *byte != 0)
        );

        let mut cache = ResourceLru {
            entries: BTreeMap::new(),
            order: VecDeque::new(),
            bytes: 0,
            max_bytes: 4,
        };
        let mut resources = BTreeMap::new();
        resources.insert(
            [1; 32],
            BrushResource {
                kind: "tip".into(),
                width: 1,
                height: 1,
                rgba8: vec![1, 2, 3],
            },
        );
        resources.insert(
            [2; 32],
            BrushResource {
                kind: "tip".into(),
                width: 1,
                height: 1,
                rgba8: vec![4, 5, 6],
            },
        );
        assert!(cache.resolve([1; 32], &resources).is_some());
        assert!(cache.resolve([2; 32], &resources).is_some());
        assert!(!cache.entries.contains_key(&[1; 32]));
        assert_eq!(cache.bytes(), 3);
    }

    #[test]
    fn layer_thumbnail_is_bounded_and_matches_rgba_shape() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(80), spec).expect("valid doc");
        let layer = doc.layers()[0].id;
        let stroke = ink_model::StrokeId::from_u128(81);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke,
            layer,
            brush: BrushPreset::starters()[0].id,
        })
        .expect("begin");
        doc.push_pointer_packet(&ink_test_support::one_sample(32.0, 32.0, 1.0))
            .expect("sample");
        doc.dispatch(EditorCommand::EndStroke { stroke })
            .expect("end");
        assert_eq!(
            doc.read_layer_thumbnail(layer, 32)
                .expect("thumbnail")
                .len(),
            32 * 32 * 4
        );
        assert!(doc.read_layer_thumbnail(layer, 8).is_err());
    }

    #[test]
    fn brush_color_update_is_rust_owned_and_persisted() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(82), spec).expect("valid doc");
        let brush = BrushId::from_u128(1);
        let revision = doc
            .update_brush_color(
                brush,
                Rgba8 {
                    r: 12,
                    g: 96,
                    b: 220,
                    a: 255,
                },
            )
            .expect("color update");
        assert_eq!(revision, 1);
        let stored: BrushPresetV2 =
            serde_json::from_slice(&doc.snapshot().brushes[0]).expect("stored brush");
        let color = match stored.paint {
            PaintBehavior::Solid(value) => value.color,
            PaintBehavior::Glaze(value) => value.color,
            PaintBehavior::Marker(value) => value.color,
            PaintBehavior::ColorPickup(value) => value.color,
            PaintBehavior::DigitalWatercolor(value) => value.color,
        };
        assert_eq!(
            color,
            Rgba8 {
                r: 12,
                g: 96,
                b: 220,
                a: 255,
            }
        );
        let root =
            std::env::temp_dir().join(format!("project-ink-color-save-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).expect("color temp root");
        let path = root.join("color.inkproj");
        doc.save_as(&path).expect("save brush color");
        let reopened = Document::open(&path).expect("reopen brush color");
        let reopened_brush: BrushPresetV2 =
            serde_json::from_slice(&reopened.snapshot().brushes[0]).expect("reopened brush");
        let reopened_color = match reopened_brush.paint {
            PaintBehavior::Solid(value) => value.color,
            PaintBehavior::Glaze(value) => value.color,
            PaintBehavior::Marker(value) => value.color,
            PaintBehavior::ColorPickup(value) => value.color,
            PaintBehavior::DigitalWatercolor(value) => value.color,
        };
        assert_eq!(reopened_color, color);
        std::fs::remove_dir_all(root).expect("cleanup color temp root");
        assert!(doc.update_brush_color(brush, Rgba8::default()).is_ok());
        let layer = doc.layers()[0].id;
        let stroke = ink_model::StrokeId::from_u128(83);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke,
            layer,
            brush,
        })
        .expect("begin color stroke");
        doc.push_pointer_packet(&ink_test_support::one_sample(32.0, 32.0, 1.0))
            .expect("color sample");
        doc.dispatch(EditorCommand::EndStroke { stroke })
            .expect("end color stroke");
        assert!(doc.time_lapse().strokes.iter().any(|item| item.brush == 1));
    }

    #[test]
    fn brush_library_edit_uses_shared_undo_redo_commands() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(84), spec).expect("valid doc");
        let brush = BrushId::from_u128(1);
        doc.update_brush_color(
            brush,
            Rgba8 {
                r: 240,
                g: 80,
                b: 32,
                a: 255,
            },
        )
        .expect("color update");
        assert_eq!(doc.snapshot().brushes.len(), 1);

        doc.dispatch(EditorCommand::Undo).expect("undo brush edit");
        assert!(doc.snapshot().brushes.is_empty());
        doc.dispatch(EditorCommand::Redo).expect("redo brush edit");
        assert_eq!(doc.snapshot().brushes.len(), 1);
        let restored: BrushPresetV2 =
            serde_json::from_slice(&doc.snapshot().brushes[0]).expect("restored brush");
        let restored_color = match restored.paint {
            PaintBehavior::Solid(value) => value.color,
            PaintBehavior::Glaze(value) => value.color,
            PaintBehavior::Marker(value) => value.color,
            PaintBehavior::ColorPickup(value) => value.color,
            PaintBehavior::DigitalWatercolor(value) => value.color,
        };
        assert_eq!(
            restored_color,
            Rgba8 {
                r: 240,
                g: 80,
                b: 32,
                a: 255
            }
        );
    }

    #[test]
    fn comic_structure_survives_native_checkpoint_and_reopen() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(85), spec).expect("valid doc");
        let comic = ink_comic::xkcd_stick_figure_comic()
            .to_json()
            .expect("comic JSON");
        let expected_digest = ink_comic::ComicProject::from_json(&comic)
            .expect("comic decode")
            .portable_render_digest()
            .expect("comic digest");
        doc.set_comic_json(comic.clone()).expect("attach comic");
        assert_eq!(doc.comic_json(), Some(comic.clone()));
        let root =
            std::env::temp_dir().join(format!("project-ink-comic-save-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).expect("comic temp root");
        let path = root.join("comic.inkproj");
        doc.save_as(&path).expect("save comic");
        let reopened = Document::open(&path).expect("reopen comic");
        assert_eq!(reopened.comic_json(), Some(comic));
        let reopened_digest =
            ink_comic::ComicProject::from_json(&reopened.comic_json().expect("reopened comic"))
                .expect("reopened decode")
                .portable_render_digest()
                .expect("reopened digest");
        assert_eq!(reopened_digest, expected_digest);
        std::fs::remove_dir_all(root).expect("cleanup comic temp root");
    }

    #[test]
    fn history_projection_navigates_rust_owned_snapshots() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(86), spec).expect("valid doc");
        doc.add_layer(LayerKind::Raster).expect("add raster");
        doc.add_layer(LayerKind::VectorInk).expect("add vector");

        let events = doc.drain_events().expect("history events");
        assert!(events.contains(&EngineEvent::HistoryChanged {
            revision: doc.revision(),
            cursor: 2,
        }));

        let history = doc.history_snapshot(100).expect("history projection");
        assert_eq!(history.cursor, 2);
        assert_eq!(history.entries.len(), 2);
        assert!(history.entries.iter().all(|entry| entry.applied));
        assert_eq!(
            history.entries[0].detail.as_deref(),
            Some("Add Raster layer")
        );

        doc.navigate_history(0).expect("navigate to beginning");
        assert_eq!(doc.layers().len(), 1);
        assert_eq!(doc.history_snapshot(100).expect("history").cursor, 0);

        doc.navigate_history(1).expect("redo one transaction");
        assert_eq!(doc.layers().len(), 2);
        let history = doc.history_snapshot(100).expect("history after navigation");
        assert_eq!(history.cursor, 1);
        assert!(history.entries[0].applied);
        assert!(!history.entries[1].applied);
        assert!(doc.navigate_history(3).is_err());
    }

    #[test]
    fn history_projection_reports_when_storage_dropped_oversized_undo_sidecar() {
        let spec = DocumentSpec {
            width_px: 256,
            height_px: 256,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc = Document::new(DocumentId::from_u128(87), spec).expect("valid doc");
        doc.add_layer(LayerKind::Raster).expect("first edit");
        doc.add_layer(LayerKind::VectorInk).expect("second edit");
        let mut snapshot = doc.snapshot();
        snapshot.history.undo.remove(0);
        snapshot.history.truncated_on_load = true;
        let mut reopened = Document::from_snapshot(snapshot).expect("reopen artwork");

        let projection = reopened.history_snapshot(100).expect("history projection");
        assert!(projection.was_trimmed);
        assert_eq!(projection.entries.len(), 1);
        assert_eq!(projection.cursor, 1);
        assert_eq!(
            projection.entries[0].detail.as_deref(),
            Some("Add VectorInk layer")
        );
        reopened
            .navigate_history(0)
            .expect("undo retained latest state");
        assert_eq!(reopened.layers().len(), 2);
    }
}
