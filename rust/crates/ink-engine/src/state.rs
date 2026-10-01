use super::{
    Arc, AtomicU64, BTreeMap, BrushDab, BrushId, BrushPreset, BrushPresetV2, CompiledBrush,
    CompiledBrushState, Dab, EngineEvent, History, Layer, LayerId, Mutex, SelectionMask, TileStore,
    TimeLapseRecording, VecDeque, VectorStroke,
};

#[derive(Clone, Debug)]
pub(super) struct LayerState {
    pub(super) layer: Layer,
    pub(super) tiles: TileStore,
    pub(super) vectors: Vec<(ink_model::StrokeId, VectorStroke)>,
}

#[derive(Clone, Debug)]
pub(super) struct BrushResource {
    pub(super) kind: String,
    pub(super) width: u32,
    pub(super) height: u32,
    pub(super) rgba8: Vec<u8>,
}

/// Bounded decoded-resource cache. The project resource map remains the
/// durable source of truth; this LRU limits hot decoded copies used by brush
/// rendering and can be discarded without changing document semantics.
#[derive(Debug)]
pub(super) struct ResourceLru {
    pub(super) entries: BTreeMap<[u8; 32], BrushResource>,
    pub(super) order: VecDeque<[u8; 32]>,
    pub(super) bytes: usize,
    pub(super) max_bytes: usize,
}

impl ResourceLru {
    pub(super) const DEFAULT_MAX_BYTES: usize = 64 * 1024 * 1024;

    pub(super) fn new() -> Self {
        Self {
            entries: BTreeMap::new(),
            order: VecDeque::new(),
            bytes: 0,
            max_bytes: Self::DEFAULT_MAX_BYTES,
        }
    }

    pub(super) fn touch(&mut self, hash: [u8; 32]) {
        if let Some(position) = self.order.iter().position(|candidate| *candidate == hash) {
            self.order.remove(position);
        }
        self.order.push_back(hash);
    }

    pub(super) fn resolve(
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

    pub(super) fn resolve_for_dabs(
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

    pub(super) fn bytes(&self) -> usize {
        self.bytes
    }
}

#[derive(Clone, Debug)]
pub(super) struct BrushDraftSettings {
    pub(super) diameter_px: f32,
    pub(super) opacity: f32,
    pub(super) spacing: f32,
    pub(super) smoothing: f32,
    pub(super) pressure_size: f32,
    pub(super) pressure_opacity: f32,
    pub(super) pressure_curve: f32,
    pub(super) hardness: f32,
    pub(super) texture_scale: f32,
    pub(super) scatter: f32,
    pub(super) rotation_jitter: f32,
    pub(super) smudge: f32,
    pub(super) wetness: f32,
    pub(super) pressure_curve_points: Vec<f32>,
}

#[derive(Clone, Debug)]
pub(super) struct BrushEditUndo {
    pub(super) brush_id: BrushId,
    pub(super) previous_override: Option<BrushPresetV2>,
    pub(super) current_override: Option<BrushPresetV2>,
}

#[derive(Debug)]
// These flags are independent transaction facts; they cannot be represented
// by one mutually exclusive state without losing valid combinations.
#[allow(clippy::struct_excessive_bools)]
pub(super) struct ActiveStroke {
    pub(super) stroke: ink_model::StrokeId,
    pub(super) layer: LayerId,
    pub(super) brush: BrushPreset,
    pub(super) compiled_brush: Option<CompiledBrush>,
    pub(super) compiled_brush_state: CompiledBrushState,
    /// Retained input for optional end-of-stroke effects. This is a rolling
    /// per-segment buffer; the full stroke is summarized incrementally below.
    pub(super) samples: Vec<ink_input::PointerSample>,
    pub(super) last_confirmed_sample: Option<ink_input::PointerSample>,
    pub(super) input_metrics: StrokeInputMetrics,
    pub(super) sample_history_complete: bool,
    /// Last raw pointer sample, including samples outside the document. Keeping
    /// this separately lets us clip the incoming segment instead of pinning
    /// every off-canvas point to the nearest edge.
    pub(super) last_input_sample: Option<ink_input::PointerSample>,
    /// Once a stroke exits after entering the page, ignore further captured
    /// motion until pointer-up. This prevents accidentally connecting the exit
    /// and re-entry points through the page while keeping the transaction live.
    pub(super) stopped_at_page_edge: bool,
    /// Last spacing anchor for incremental legacy-brush resampling.
    pub(super) legacy_resample_anchor: Option<Dab>,
    pub(super) legacy_rendered_dabs: usize,
    pub(super) legacy_segment_dabs: usize,
    pub(super) work_segments: u64,
    pub(super) compiled_rendered_dabs: usize,
    pub(super) compiled_cpu_tile_updates: usize,
    pub(super) cpu_tile_updates: usize,
    pub(super) compiled_dab_last_position: Option<(f32, f32)>,
    pub(super) compiled_dab_path_length: f64,
    pub(super) compiled_dab_max_step: f32,
    pub(super) preview_tiles: TileStore,
    pub(super) preview_eraser: bool,
    /// Set when a bounded work ceiling is reached. Existing rasterized pixels
    /// remain valid; a later input batch or `EndStroke` reports the bounded
    /// evaluator failure so callers can cancel the incomplete transaction.
    /// This avoids turning a safety guard into loss of the entire stroke.
    pub(super) work_limit_reached: bool,
}

#[derive(Debug, Default)]
pub(super) struct StrokeInputMetrics {
    pub(super) sample_count: usize,
    pub(super) path_start: Option<ink_input::PointerSample>,
    pub(super) path_end: Option<ink_input::PointerSample>,
    pub(super) bounds: Option<(f32, f32, f32, f32)>,
    pub(super) pressure_range: Option<(f32, f32)>,
    pub(super) path_length: f64,
}

#[derive(Debug)]
pub(super) struct EngineState {
    pub(super) width_px: u32,
    pub(super) height_px: u32,
    pub(super) revision: u64,
    pub(super) layers: BTreeMap<LayerId, LayerState>,
    pub(super) history: History,
    pub(super) undo_states: Vec<BTreeMap<LayerId, LayerState>>,
    pub(super) redo_states: Vec<BTreeMap<LayerId, LayerState>>,
    pub(super) history_was_trimmed: bool,
    pub(super) journal: Vec<Vec<u8>>,
    pub(super) active_stroke: Option<ActiveStroke>,
    pub(super) time_lapse: TimeLapseRecording,
    /// User edits to presets are kept in the Rust engine. Built-ins remain
    /// immutable until an explicit override is created by the editor.
    pub(super) brush_overrides: BTreeMap<ink_model::BrushId, BrushPresetV2>,
    /// The most recent brush-library edit participates in the same Undo/Redo
    /// command path as canvas edits. It is intentionally session-scoped; the
    /// durable brush override itself is persisted with the document.
    pub(super) brush_undo: Option<BrushEditUndo>,
    pub(super) brush_redo: Option<BrushEditUndo>,
    pub(super) resources: BTreeMap<[u8; 32], BrushResource>,
    pub(super) resource_cache: ResourceLru,
    /// Ephemeral selection mask. It is intentionally not persisted in v1
    /// projects; it constrains rasterization until the user clears it.
    pub(super) selection: Option<SelectionMask>,
    pub(super) brush_drafts: BTreeMap<u64, (BrushId, BrushDraftSettings)>,
    pub(super) next_brush_draft: u64,
    /// Rust-generated ephemeral dabs shared with an optional GPU preview.
    /// If the optional preview queue is saturated, the CPU document continues
    /// without interruption and this counter records that the preview should
    /// fall back to the normal tile path. The queue is never part of document
    /// persistence or undo state.
    pub(super) live_dabs: Arc<Mutex<ink_live_render::LiveDabQueue>>,
    pub(super) live_dab_overflow_count: Arc<AtomicU64>,
    pub(super) events: Vec<EngineEvent>,
    pub(super) worker_error: Option<String>,
    /// Optional validated Phase 3 comic structure persisted with the native
    /// document. Pixels and comic metadata remain separate authorities.
    pub(super) comic_json: Option<Vec<u8>>,
}
