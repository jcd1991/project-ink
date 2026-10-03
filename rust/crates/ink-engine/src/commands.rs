use super::{
    ActiveStroke, BrushPreset, CompiledBrush, CompiledBrushState, DocumentSpec, EditorCommand,
    EngineError, EngineEvent, EngineState, HashMap, HashSet, Layer, LayerId, LayerKind, LayerState,
    MAX_COMMAND_JOURNAL_ENTRIES, MAX_FILL_PIXELS, MAX_LAYERS, MAX_PANEL_MASK_PIXELS, Rgba8,
    SelectionMask, StrokeInputMetrics, Tile, TileDescriptor, TileStore, TimeLapseSample,
    TimeLapseStroke, Transaction, VectorPoint, VectorStroke, advance_revision,
    ancestor_has_mask_node, apply_post_effects, builtin_library, compositor_blend_mode,
    encode_command, flush_deferred_dual_dabs, history_label, layer_subtree_ids, lock_recover,
    merge_raster_layers, next_layer_id, normalize_sibling_orders, point_inside_polygon,
    rasterize_vector_stroke, rebuild_vector_layer, restore_brush_override, time_lapse_has_capacity,
    trim_history_snapshots, validate_layer_tree, validate_vector_stroke,
};

/// Commit a pending opacity preview as one ordinary, undoable command.
pub(super) fn commit_pending_opacity_edit(
    state: &mut EngineState,
    expected_id: Option<u64>,
) -> Result<u64, EngineError> {
    let Some(edit) = state.opacity_edit else {
        return if expected_id.is_some() {
            Err(EngineError::InvalidCommand(
                "layer opacity edit is no longer active".into(),
            ))
        } else {
            Ok(state.revision)
        };
    };
    if expected_id.is_some_and(|expected| expected != edit.id) {
        return Err(EngineError::InvalidCommand(
            "layer opacity edit ID does not match".into(),
        ));
    }
    let current = state
        .layers
        .get(&edit.layer)
        .ok_or(EngineError::InvalidLayer)?
        .layer
        .opacity;
    if current == edit.original {
        state.opacity_edit = None;
        return Ok(state.revision);
    }
    ensure_unlocked(state, edit.layer)?;
    state.opacity_edit = None;
    state
        .layers
        .get_mut(&edit.layer)
        .ok_or(EngineError::InvalidLayer)?
        .layer
        .opacity = edit.original;
    dispatch_state(
        state,
        EditorCommand::SetLayerOpacity {
            layer: edit.layer,
            opacity: current,
        },
    )
}

pub(super) fn cancel_pending_opacity_edit(
    state: &mut EngineState,
    expected_id: Option<u64>,
) -> Result<u64, EngineError> {
    let Some(edit) = state.opacity_edit else {
        return if expected_id.is_some() {
            Err(EngineError::InvalidCommand(
                "layer opacity edit is no longer active".into(),
            ))
        } else {
            Ok(state.revision)
        };
    };
    if expected_id.is_some_and(|expected| expected != edit.id) {
        return Err(EngineError::InvalidCommand(
            "layer opacity edit ID does not match".into(),
        ));
    }
    state.opacity_edit = None;
    let layer_state = state
        .layers
        .get_mut(&edit.layer)
        .ok_or(EngineError::InvalidLayer)?;
    if layer_state.layer.opacity == edit.original {
        return Ok(state.revision);
    }
    layer_state.layer.opacity = edit.original;
    advance_revision(state)?;
    let revision = state.revision;
    state.events.push(EngineEvent::LayersChanged { revision });
    Ok(revision)
}

impl super::Document {
    /// Start a temporary opacity preview for one stable layer identity.
    pub fn begin_layer_opacity_edit(&mut self, layer: LayerId) -> Result<u64, EngineError> {
        self.flush_input()?;
        {
            let mut state = lock_recover(&self.state);
            if let Some(edit) = state.opacity_edit {
                if edit.layer == layer {
                    return Ok(edit.id);
                }
                commit_pending_opacity_edit(&mut state, Some(edit.id))?;
            }
            ensure_unlocked(&state, layer)?;
            let opacity = state
                .layers
                .get(&layer)
                .ok_or(EngineError::InvalidLayer)?
                .layer
                .opacity;
            let id = state.next_opacity_edit;
            state.next_opacity_edit = id.checked_add(1).ok_or_else(|| {
                EngineError::InvalidCommand("opacity edit ID space is exhausted".into())
            })?;
            state.opacity_edit = Some(super::state::LayerOpacityEdit {
                id,
                layer,
                original: opacity,
            });
            Ok(id)
        }
    }

    /// Preview opacity without adding history entries while the slider moves.
    pub fn update_layer_opacity_edit(
        &mut self,
        edit_id: u64,
        opacity: u16,
    ) -> Result<u64, EngineError> {
        self.flush_input()?;
        let mut state = lock_recover(&self.state);
        let edit = state.opacity_edit.ok_or_else(|| {
            EngineError::InvalidCommand("layer opacity edit is no longer active".into())
        })?;
        if edit.id != edit_id {
            return Err(EngineError::InvalidCommand(
                "layer opacity edit ID does not match".into(),
            ));
        }
        ensure_unlocked(&state, edit.layer)?;
        let layer_state = state
            .layers
            .get_mut(&edit.layer)
            .ok_or(EngineError::InvalidLayer)?;
        if layer_state.layer.opacity == opacity {
            return Ok(state.revision);
        }
        layer_state.layer.opacity = opacity;
        advance_revision(&mut state)?;
        let revision = state.revision;
        state.events.push(EngineEvent::LayersChanged { revision });
        Ok(revision)
    }

    /// Commit a slider preview as exactly one undoable opacity command.
    pub fn commit_layer_opacity_edit(&mut self, edit_id: u64) -> Result<u64, EngineError> {
        self.flush_input()?;
        commit_pending_opacity_edit(&mut lock_recover(&self.state), Some(edit_id))
    }

    /// Restore the gesture-start opacity without recording an undo command.
    pub fn cancel_layer_opacity_edit(&mut self, edit_id: u64) -> Result<u64, EngineError> {
        self.flush_input()?;
        cancel_pending_opacity_edit(&mut lock_recover(&self.state), Some(edit_id))
    }
}

/// Validate every requested subtree before removing any layer, then commit
/// the complete deletion with one revision and one layer-change event.
fn delete_layer_roots(state: &mut EngineState, requested: &[LayerId]) -> Result<(), EngineError> {
    let (removed, surviving_parents) = delete_layer_plan(state, requested)?;

    for id in removed {
        state.layers.remove(&id);
    }
    for parent in surviving_parents {
        normalize_sibling_orders(&mut state.layers, parent);
    }
    advance_revision(state)?;
    state.events.push(EngineEvent::LayersChanged {
        revision: state.revision,
    });
    Ok(())
}

/// Return the same structural deletion plan used by the committing command.
/// The caller may inspect the plan without changing document state.
fn delete_layer_plan(
    state: &EngineState,
    requested: &[LayerId],
) -> Result<(HashSet<LayerId>, HashSet<Option<LayerId>>), EngineError> {
    if requested.len() > 4_096 {
        return Err(EngineError::InvalidCommand(
            "delete request exceeds the 4096-layer safety limit".into(),
        ));
    }
    if requested.is_empty()
        || requested.iter().copied().collect::<HashSet<_>>().len() != requested.len()
    {
        return Err(EngineError::InvalidCommand(
            "delete requires unique layer IDs".into(),
        ));
    }

    let selected = requested.iter().copied().collect::<HashSet<_>>();
    let mut roots = Vec::new();
    for id in requested {
        let layer = state.layers.get(id).ok_or(EngineError::InvalidLayer)?;
        let mut parent = layer.layer.parent;
        let mut has_selected_ancestor = false;
        let mut visited = HashSet::new();
        while let Some(parent_id) = parent {
            if !visited.insert(parent_id) {
                return Err(EngineError::InvalidCommand(
                    "layer hierarchy contains a cycle".into(),
                ));
            }
            if selected.contains(&parent_id) {
                has_selected_ancestor = true;
                break;
            }
            parent = state
                .layers
                .get(&parent_id)
                .ok_or(EngineError::InvalidLayer)?
                .layer
                .parent;
        }
        if !has_selected_ancestor {
            roots.push(*id);
        }
    }

    let mut removed = HashSet::new();
    let mut surviving_parents = HashSet::new();
    for root_id in roots {
        let root = state
            .layers
            .get(&root_id)
            .ok_or(EngineError::InvalidLayer)?;
        if root.layer.kind == LayerKind::PanelGroup {
            return Err(EngineError::InvalidCommand(
                "comic panel groups must be removed through the comic workspace".into(),
            ));
        }
        surviving_parents.insert(root.layer.parent);
        let mut subtree = vec![root_id];
        let mut cursor = 0;
        while cursor < subtree.len() {
            let parent = subtree[cursor];
            let children = state
                .layers
                .values()
                .filter(|candidate| {
                    candidate.layer.parent == Some(parent)
                        || (candidate.layer.kind == LayerKind::Mask
                            && candidate.layer.mask_owner == Some(parent))
                })
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
        removed.extend(subtree);
    }

    if state.layers.len().saturating_sub(removed.len()) == 0 {
        return Err(EngineError::InvalidCommand(
            "a document must keep at least one layer".into(),
        ));
    }
    reject_comic_owned_layers(state, &removed, "removed")?;

    Ok((removed, surviving_parents))
}

/// Check the exact structural and lock rules used by selected-layer deletion
/// without changing content, revision, or history.
pub(super) fn preflight_delete_layer_roots(
    state: &EngineState,
    requested: &[LayerId],
) -> Result<(), EngineError> {
    for id in requested {
        ensure_subtree_unlocked(state, *id)?;
    }
    delete_layer_plan(state, requested).map(|_| ())
}

fn reject_comic_owned_layers(
    state: &EngineState,
    layers: &HashSet<LayerId>,
    action: &str,
) -> Result<(), EngineError> {
    let Some(comic_bytes) = &state.comic_json else {
        return Ok(());
    };
    let project = ink_comic::ComicProject::from_json(comic_bytes).map_err(|error| {
        EngineError::InvalidCommand(format!("cannot validate comic layer ownership: {error}"))
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
    if layers.iter().any(|id| bound_layers.contains(id)) {
        return Err(EngineError::InvalidCommand(format!(
            "comic-owned layers must be {action} through the comic workspace"
        )));
    }
    Ok(())
}

#[allow(clippy::too_many_lines)]
fn effective_lock_owner(
    state: &EngineState,
    layer: LayerId,
) -> Result<Option<LayerId>, EngineError> {
    let mut cursor = Some(layer);
    let mut visited = HashSet::new();
    while let Some(id) = cursor {
        if !visited.insert(id) {
            return Err(EngineError::InvalidCommand(
                "layer hierarchy contains a cycle".into(),
            ));
        }
        let current = state.layers.get(&id).ok_or(EngineError::InvalidLayer)?;
        if current.layer.locked {
            return Ok(Some(id));
        }
        cursor = current.layer.parent;
    }
    Ok(None)
}

fn ensure_unlocked(state: &EngineState, layer: LayerId) -> Result<(), EngineError> {
    if let Some(owner) = effective_lock_owner(state, layer)? {
        return Err(EngineError::InvalidCommand(format!(
            "layer {layer} is locked by layer {owner}; unlock the owning layer or group first"
        )));
    }
    Ok(())
}

fn ensure_lock_owner_editable(state: &EngineState, layer: LayerId) -> Result<(), EngineError> {
    if effective_lock_owner(state, layer)?.is_some_and(|owner| owner != layer) {
        return ensure_unlocked(state, layer);
    }
    Ok(())
}

fn ensure_subtree_unlocked(state: &EngineState, root: LayerId) -> Result<(), EngineError> {
    ensure_unlocked(state, root)?;
    let mut pending = vec![root];
    let mut cursor = 0;
    while cursor < pending.len() {
        let parent = pending[cursor];
        for child in state.layers.values().filter(|candidate| {
            candidate.layer.parent == Some(parent) || candidate.layer.mask_owner == Some(parent)
        }) {
            ensure_unlocked(state, child.layer.id)?;
            if !pending.contains(&child.layer.id) {
                pending.push(child.layer.id);
            }
        }
        cursor += 1;
    }
    Ok(())
}

fn validate_distinct_unlocked_layers(
    state: &EngineState,
    layers: &[ink_model::LayerId],
    operation: &str,
) -> Result<(), EngineError> {
    if layers.is_empty()
        || layers
            .iter()
            .copied()
            .collect::<std::collections::HashSet<_>>()
            .len()
            != layers.len()
    {
        return Err(EngineError::InvalidCommand(format!(
            "{operation} requires distinct layer IDs"
        )));
    }
    for layer in layers {
        ensure_unlocked(state, *layer)?;
    }
    Ok(())
}

fn validate_lock_access(state: &EngineState, command: &EditorCommand) -> Result<(), EngineError> {
    match command {
        EditorCommand::AddLayer {
            parent: Some(parent),
            ..
        } => ensure_unlocked(state, *parent),
        EditorCommand::DeleteLayer { layer }
        | EditorCommand::UngroupLayer { group: layer }
        | EditorCommand::DuplicateLayer { source: layer, .. }
        | EditorCommand::DuplicateLayerWithMasks { source: layer, .. }
        | EditorCommand::DuplicateLayerSubtree { source: layer, .. } => {
            ensure_subtree_unlocked(state, *layer)
        }
        EditorCommand::DuplicateLayers {
            sources: layers, ..
        }
        | EditorCommand::DeleteLayers { layers }
        | EditorCommand::MergeLayersBulk { layers } => {
            for layer in layers {
                ensure_subtree_unlocked(state, *layer)?;
            }
            Ok(())
        }
        EditorCommand::GroupLayers { members, .. } => {
            for layer in members {
                ensure_subtree_unlocked(state, *layer)?;
            }
            Ok(())
        }
        EditorCommand::MergeLayers { target, source } => {
            ensure_unlocked(state, *target)?;
            ensure_subtree_unlocked(state, *source)
        }
        EditorCommand::MoveLayer { layer, parent, .. } => {
            ensure_subtree_unlocked(state, *layer)?;
            if let Some(parent) = parent {
                ensure_unlocked(state, *parent)?;
            }
            Ok(())
        }
        EditorCommand::ReorderLayers { layers, .. } => validate_reorder_locks(state, layers),
        EditorCommand::SetLayerVisibility { .. }
        | EditorCommand::SetLayersVisibility { .. }
        | EditorCommand::SetLayerLocked { .. }
        | EditorCommand::Undo
        | EditorCommand::Redo
        | EditorCommand::EndStroke { .. }
        | EditorCommand::CancelStroke { .. }
        | EditorCommand::AddLayer { parent: None, .. }
        | EditorCommand::CreatePanelLayerTree { .. } => Ok(()),
        EditorCommand::SetLayersLocked { layers, .. } => {
            for layer in layers {
                ensure_lock_owner_editable(state, *layer)?;
            }
            Ok(())
        }
        EditorCommand::SetLayersLabel { layers, .. } => {
            validate_distinct_unlocked_layers(state, layers, "bulk label")
        }
        EditorCommand::SetPanelMaskGeometry { mask, .. }
        | EditorCommand::SetMaskEnabled { mask, .. }
        | EditorCommand::SetMaskInverted { mask, .. } => ensure_unlocked(state, *mask),
        EditorCommand::ApplyLayerMask { mask } => validate_mask_apply_target(state, *mask),
        EditorCommand::SetLayerOpacity { layer, .. }
        | EditorCommand::SetLayerBlendMode { layer, .. }
        | EditorCommand::SetLayerGroupMode { layer, .. }
        | EditorCommand::SetLayerAlphaLock { layer, .. }
        | EditorCommand::SetLayerClipping { layer, .. }
        | EditorCommand::SetLayerReference { layer, .. }
        | EditorCommand::SetLayerLabel { layer, .. }
        | EditorCommand::SetLayerName { layer, .. }
        | EditorCommand::SetLayerAdjustment { layer, .. }
        | EditorCommand::TransformLayer { layer, .. }
        | EditorCommand::FillRegion { layer, .. }
        | EditorCommand::GradientFill { layer, .. }
        | EditorCommand::PerspectiveLayer { layer, .. }
        | EditorCommand::MeshLayer { layer, .. }
        | EditorCommand::LiquifyLayer { layer, .. }
        | EditorCommand::AddVectorStroke { layer, .. }
        | EditorCommand::TransformVectorStroke { layer, .. }
        | EditorCommand::SimplifyVectorStroke { layer, .. }
        | EditorCommand::ConnectVectorStrokes { layer, .. }
        | EditorCommand::EraseVectorSegment { layer, .. }
        | EditorCommand::SetVectorPoint { layer, .. }
        | EditorCommand::BeginStroke { layer, .. } => ensure_unlocked(state, *layer),
    }
}

fn validate_mask_apply_target(state: &EngineState, mask: LayerId) -> Result<(), EngineError> {
    ensure_unlocked(state, mask)?;
    let mask_layer = state
        .layers
        .get(&mask)
        .filter(|layer| layer.layer.kind == LayerKind::Mask)
        .ok_or_else(|| EngineError::InvalidCommand("apply requires a mask layer".into()))?;
    let owner_id = mask_layer
        .layer
        .mask_owner
        .ok_or_else(|| EngineError::InvalidCommand("mask must be attached to apply it".into()))?;
    let owner = state
        .layers
        .get(&owner_id)
        .ok_or(EngineError::InvalidLayer)?;
    if owner.layer.kind != LayerKind::Raster {
        return Err(EngineError::InvalidCommand(
            "Apply Mask is supported for raster owners only".into(),
        ));
    }
    ensure_unlocked(state, owner_id)
}

fn apply_layer_mask(state: &mut EngineState, mask: LayerId) -> Result<u64, EngineError> {
    validate_mask_apply_target(state, mask)?;
    let mask_state = state.layers.get(&mask).ok_or(EngineError::InvalidLayer)?;
    let owner_id = mask_state
        .layer
        .mask_owner
        .ok_or(EngineError::InvalidLayer)?;
    let mask_layer = mask_state.layer.clone();
    let mask_tiles = mask_state.tiles.clone();
    let owner_coordinates = state
        .layers
        .get(&owner_id)
        .ok_or(EngineError::InvalidLayer)?
        .tiles
        .allocated_coordinates();
    for coordinate in &owner_coordinates {
        let mask_tile = mask_tiles.read(*coordinate);
        let owner = state
            .layers
            .get_mut(&owner_id)
            .ok_or(EngineError::InvalidLayer)?;
        let owner_tile = owner.tiles.read(*coordinate);
        for y in 0..ink_raster::TILE_SIZE {
            let document_y = i64::from(coordinate.y)
                .saturating_mul(i64::from(ink_raster::TILE_SIZE))
                .saturating_add(i64::from(y));
            if document_y < 0 || document_y >= i64::from(state.height_px) {
                continue;
            }
            for x in 0..ink_raster::TILE_SIZE {
                let document_x = i64::from(coordinate.x)
                    .saturating_mul(i64::from(ink_raster::TILE_SIZE))
                    .saturating_add(i64::from(x));
                if document_x < 0 || document_x >= i64::from(state.width_px) {
                    continue;
                }
                let mask_alpha = mask_tile.pixel_rgba(x, y).a;
                let coverage = if mask_layer.mask_enabled {
                    super::mask_coverage(
                        mask_alpha,
                        mask_layer.mask_stencil,
                        mask_layer.mask_inverted,
                    )
                } else {
                    u32::from(u8::MAX)
                };
                if coverage == u32::from(u8::MAX) {
                    continue;
                }
                let pixel = owner_tile.pixel_rgba(x, y);
                let scale = |channel: u8| ((u32::from(channel) * coverage + 127) / 255) as u8;
                owner.tiles.set_pixel(
                    u32::try_from(document_x).unwrap_or(u32::MAX),
                    u32::try_from(document_y).unwrap_or(u32::MAX),
                    Rgba8 {
                        r: scale(pixel.r),
                        g: scale(pixel.g),
                        b: scale(pixel.b),
                        a: scale(pixel.a),
                    },
                );
            }
        }
    }
    state.layers.remove(&mask);
    let revision = advance_revision(state)?;
    state.events.push(EngineEvent::TilesDirty {
        revision,
        tiles: owner_coordinates
            .into_iter()
            .map(|coordinate| TileDescriptor {
                layer: owner_id,
                coordinate,
            })
            .collect(),
    });
    state.events.push(EngineEvent::LayersChanged { revision });
    Ok(revision)
}

fn validate_reorder_locks(state: &EngineState, layers: &[LayerId]) -> Result<(), EngineError> {
    if layers.is_empty()
        || layers
            .iter()
            .copied()
            .collect::<std::collections::HashSet<_>>()
            .len()
            != layers.len()
    {
        return Err(EngineError::InvalidCommand(
            "multi-layer reorder requires distinct layer IDs".into(),
        ));
    }
    for layer in layers {
        ensure_subtree_unlocked(state, *layer)?;
    }
    Ok(())
}

// Keep the established command dispatcher together: splitting it now would
// widen the mutation refactor beyond the lock-validation change.
#[allow(clippy::too_many_lines)]
pub(super) fn dispatch_state(
    state: &mut EngineState,
    command: EditorCommand,
) -> Result<u64, EngineError> {
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
    validate_lock_access(state, &command)?;
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
            mask_state.layer.mask_stencil = true;
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
                if id == *mask {
                    layer.mask_owner = Some(*panel_group);
                    layer.mask_stencil = true;
                }
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
            if *kind == LayerKind::Mask {
                layer.mask_owner = if parent.is_some_and(|parent_id| {
                    state.layers.get(&parent_id).is_some_and(|candidate| {
                        matches!(
                            candidate.layer.kind,
                            LayerKind::Group | LayerKind::PanelGroup
                        )
                    })
                }) {
                    *parent
                } else {
                    state
                        .layers
                        .values()
                        .filter(|candidate| {
                            candidate.layer.parent == *parent
                                && matches!(
                                    candidate.layer.kind,
                                    LayerKind::Raster | LayerKind::VectorInk
                                )
                        })
                        .max_by_key(|candidate| candidate.layer.order)
                        .map(|candidate| candidate.layer.id)
                };
            }
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
        EditorCommand::GroupLayers { group, members } => {
            if members.len() < 2
                || members.len() > 4_096
                || state.layers.len() >= MAX_LAYERS
                || state.revision == u64::MAX
                || next_layer_id(&state.layers)? != *group
            {
                return Err(EngineError::InvalidCommand(
                    "group selection is invalid or exceeds the layer safety limit".into(),
                ));
            }
            let unique_members = members.iter().copied().collect::<HashSet<_>>();
            if unique_members.len() != members.len() {
                return Err(EngineError::InvalidCommand(
                    "a layer can only appear once in a group selection".into(),
                ));
            }
            let first = state
                .layers
                .get(&members[0])
                .ok_or(EngineError::InvalidLayer)?;
            let parent = first.layer.parent;
            if members.iter().any(|member| {
                state
                    .layers
                    .get(member)
                    .is_none_or(|candidate| candidate.layer.parent != parent)
            }) {
                return Err(EngineError::InvalidCommand(
                    "group selected layers from the same parent".into(),
                ));
            }
            if members
                .iter()
                .any(|member| state.layers[member].layer.kind == LayerKind::PanelGroup)
            {
                return Err(EngineError::InvalidCommand(
                    "comic panel groups must be grouped through the comic workspace".into(),
                ));
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
                for member in members {
                    if layer_subtree_ids(&state.layers, *member)?
                        .iter()
                        .any(|id| bound_layers.contains(id))
                    {
                        return Err(EngineError::InvalidCommand(
                            "comic-owned layers must be grouped through the comic workspace".into(),
                        ));
                    }
                }
            }
            let mut siblings = state
                .layers
                .values()
                .filter(|candidate| candidate.layer.parent == parent)
                .map(|candidate| (candidate.layer.order, candidate.layer.id))
                .collect::<Vec<_>>();
            siblings.sort_unstable();
            let selected_positions = siblings
                .iter()
                .enumerate()
                .filter_map(|(position, (_, id))| unique_members.contains(id).then_some(position))
                .collect::<Vec<_>>();
            if selected_positions.len() != members.len() {
                return Err(EngineError::InvalidLayer);
            }
            let first_selected = selected_positions[0];
            let last_selected = *selected_positions.last().ok_or_else(|| {
                EngineError::InvalidCommand("group requires at least two layers".into())
            })?;
            // Attached masks are structural companions of their selected
            // owners. Carry them into the new group with those owners so the
            // visible hierarchy matches the explicit mask_owner relationship.
            let attached_mask_ids = state
                .layers
                .values()
                .filter(|candidate| {
                    candidate.layer.kind == LayerKind::Mask
                        && candidate.layer.parent == parent
                        && candidate
                            .layer
                            .mask_owner
                            .is_some_and(|owner| unique_members.contains(&owner))
                })
                .map(|candidate| candidate.layer.id)
                .collect::<HashSet<_>>();
            // Grouping non-contiguous selections changes their relationship to
            // unselected layers. Reject masks and clipping in that span because
            // their legacy adjacency-dependent behavior cannot be preserved.
            // Explicitly attached masks move with selected owners and are safe.
            let selected_range = &siblings[first_selected..=last_selected];
            if selected_range.iter().any(|(_, id)| {
                let layer = &state.layers[id].layer;
                layer.kind == LayerKind::Mask && !attached_mask_ids.contains(id)
            }) {
                return Err(EngineError::InvalidCommand(
                    "grouping this range could move a mask away from its owner".into(),
                ));
            }
            if selected_range
                .iter()
                .any(|(_, id)| state.layers[id].layer.clipping)
            {
                return Err(EngineError::InvalidCommand(
                    "grouping this range could change clipping behavior".into(),
                ));
            }
            let group_children = siblings
                .iter()
                .filter_map(|(_, id)| {
                    (unique_members.contains(id) || attached_mask_ids.contains(id)).then_some(*id)
                })
                .collect::<Vec<_>>();
            let mut new_siblings = Vec::with_capacity(siblings.len() - group_children.len() + 1);
            for (position, (_, id)) in siblings.iter().enumerate() {
                if position == last_selected {
                    new_siblings.push(*group);
                }
                if !unique_members.contains(id) && !attached_mask_ids.contains(id) {
                    new_siblings.push(*id);
                }
            }
            let mut group_layer = Layer::new(*group, LayerKind::Group, "Group");
            group_layer.parent = parent;
            group_layer.group_mode = ink_model::LayerGroupMode::PassThrough;
            group_layer.order = u32::try_from(last_selected).unwrap_or(u32::MAX);
            for (order, member) in group_children.iter().enumerate() {
                let child = state
                    .layers
                    .get_mut(member)
                    .ok_or(EngineError::InvalidLayer)?;
                child.layer.parent = Some(*group);
                child.layer.order = u32::try_from(order).unwrap_or(u32::MAX);
            }
            state.layers.insert(
                *group,
                LayerState {
                    layer: group_layer,
                    tiles: TileStore::default(),
                    vectors: Vec::new(),
                },
            );
            for (order, sibling_id) in new_siblings.into_iter().enumerate() {
                if let Some(sibling) = state.layers.get_mut(&sibling_id) {
                    sibling.layer.order = u32::try_from(order).unwrap_or(u32::MAX);
                }
            }
            advance_revision(state)?;
            state.events.push(EngineEvent::LayersChanged {
                revision: state.revision,
            });
        }
        EditorCommand::UngroupLayer { group } => {
            let group_state = state.layers.get(group).ok_or(EngineError::InvalidLayer)?;
            let group_layer = &group_state.layer;
            if group_layer.kind != LayerKind::Group {
                return Err(EngineError::InvalidCommand(
                    "only ordinary groups can be ungrouped here".into(),
                ));
            }
            if group_layer.group_mode != ink_model::LayerGroupMode::PassThrough
                || group_layer.blend_mode != ink_model::LayerBlendMode::Normal
                || group_layer.opacity != u16::MAX
                || group_layer.clipping
                || group_layer.reference
            {
                return Err(EngineError::InvalidCommand("ungroup requires a pass-through, Normal, 100% group without clipping or reference state".into()));
            }
            let subtree = layer_subtree_ids(&state.layers, *group)?;
            reject_comic_owned_layers(state, &subtree.iter().copied().collect(), "ungrouped")?;
            let parent = group_layer.parent;
            let mut siblings = state
                .layers
                .values()
                .filter(|candidate| candidate.layer.parent == parent)
                .map(|candidate| (candidate.layer.order, candidate.layer.id))
                .collect::<Vec<_>>();
            siblings.sort_unstable();
            let Some(group_index) = siblings.iter().position(|(_, id)| id == group) else {
                return Err(EngineError::InvalidLayer);
            };
            let mut children = state
                .layers
                .values()
                .filter(|candidate| candidate.layer.parent == Some(*group))
                .map(|candidate| (candidate.layer.order, candidate.layer.id))
                .collect::<Vec<_>>();
            if children.is_empty() {
                return Err(EngineError::InvalidCommand(
                    "empty groups have nothing to ungroup".into(),
                ));
            }
            children.sort_unstable();
            let unsafe_nodes = state.layers.values().any(|candidate| {
                ((subtree.contains(&candidate.layer.id) || candidate.layer.parent == parent)
                    && candidate.layer.id != *group)
                    && (candidate.layer.kind == LayerKind::Mask || candidate.layer.clipping)
            });
            if unsafe_nodes {
                return Err(EngineError::InvalidCommand(
                    "ungroup could change mask or clipping relationships".into(),
                ));
            }
            let mut replacement = Vec::with_capacity(siblings.len() - 1 + children.len());
            for (index, (_, sibling)) in siblings.iter().enumerate() {
                if index == group_index {
                    replacement.extend(children.iter().map(|(_, id)| *id));
                } else {
                    replacement.push(*sibling);
                }
            }
            for (order, id) in replacement.into_iter().enumerate() {
                if let Some(child) = state.layers.get_mut(&id) {
                    if child.layer.parent == Some(*group) {
                        child.layer.parent = parent;
                    }
                    child.layer.order = u32::try_from(order).unwrap_or(u32::MAX);
                }
            }
            state.layers.remove(group);
            advance_revision(state)?;
            state.events.push(EngineEvent::LayersChanged {
                revision: state.revision,
            });
        }
        EditorCommand::DeleteLayer { layer } => delete_layer_roots(state, &[*layer])?,
        EditorCommand::DeleteLayers { layers } => delete_layer_roots(state, layers)?,
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
        EditorCommand::DuplicateLayerWithMasks {
            source,
            duplicate,
            masks,
        } => {
            let source_state = state.layers.get(source).ok_or(EngineError::InvalidLayer)?;
            if source_state.layer.kind == LayerKind::PanelGroup
                || source_state.layer.kind == LayerKind::Mask
                || state
                    .layers
                    .values()
                    .any(|candidate| candidate.layer.parent == Some(*source))
            {
                return Err(EngineError::InvalidCommand(
                    "only paint leaf layers with attached masks can be duplicated this way".into(),
                ));
            }
            let mut attached_masks = state
                .layers
                .values()
                .filter(|candidate| {
                    candidate.layer.kind == LayerKind::Mask
                        && candidate.layer.mask_owner == Some(*source)
                })
                .map(|candidate| (candidate.layer.order, candidate.layer.id))
                .collect::<Vec<_>>();
            attached_masks.sort_unstable();
            if attached_masks.is_empty()
                || masks.len() != attached_masks.len()
                || masks
                    .iter()
                    .zip(&attached_masks)
                    .any(|((old, _), (_, expected))| old != expected)
            {
                return Err(EngineError::InvalidCommand(
                    "duplicate mask mapping does not match the owner's attached masks".into(),
                ));
            }
            if state.layers.len().saturating_add(1 + masks.len()) > MAX_LAYERS {
                return Err(EngineError::InvalidCommand(
                    "document layer safety limit reached".into(),
                ));
            }
            let parent = source_state.layer.parent;
            let mut expected_id = next_layer_id(&state.layers)?.0;
            let requested_ids =
                std::iter::once(*duplicate).chain(masks.iter().map(|(_, copied)| *copied));
            for requested in requested_ids {
                if state.layers.contains_key(&requested) || requested.0 != expected_id {
                    return Err(EngineError::InvalidCommand(
                        "duplicate layer ID is not the next available ID".into(),
                    ));
                }
                expected_id = expected_id.checked_add(1).ok_or_else(|| {
                    EngineError::InvalidCommand("layer ID space exhausted".into())
                })?;
            }
            if let Some(comic_bytes) = &state.comic_json {
                let project = ink_comic::ComicProject::from_json(comic_bytes).map_err(|error| {
                    EngineError::InvalidCommand(format!(
                        "cannot validate comic layer ownership: {error}"
                    ))
                })?;
                let owned = project.panel_layers.iter().any(|binding| {
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
                });
                if owned {
                    return Err(EngineError::InvalidCommand(
                        "comic-owned layers must be duplicated through the comic workspace".into(),
                    ));
                }
            }
            let mut owner_copy = source_state.clone();
            owner_copy.layer.id = *duplicate;
            owner_copy.layer.name = format!("{} Copy", source_state.layer.name);
            let mut copies = vec![(*duplicate, owner_copy)];
            for ((source_mask, duplicate_mask), _) in masks.iter().zip(&attached_masks) {
                let mut mask_copy = state
                    .layers
                    .get(source_mask)
                    .ok_or(EngineError::InvalidLayer)?
                    .clone();
                mask_copy.layer.id = *duplicate_mask;
                mask_copy.layer.mask_owner = Some(*duplicate);
                copies.push((*duplicate_mask, mask_copy));
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
            let mut siblings = state
                .layers
                .values()
                .filter(|candidate| {
                    candidate.layer.parent == parent
                        && candidate.layer.id != *duplicate
                        && !masks
                            .iter()
                            .any(|(_, copied)| candidate.layer.id == *copied)
                })
                .map(|candidate| (candidate.layer.order, candidate.layer.id))
                .collect::<Vec<_>>();
            siblings.sort_unstable();
            let mut ordered = Vec::with_capacity(siblings.len() + masks.len() + 1);
            for (_, id) in siblings {
                ordered.push(id);
                if id == *source {
                    ordered.push(*duplicate);
                    ordered.extend(masks.iter().map(|(_, copied)| *copied));
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
                copy.layer.mask_owner = copy
                    .layer
                    .mask_owner
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
        EditorCommand::DuplicateLayers {
            sources,
            duplicates,
        } => {
            if !(2..=4_096).contains(&sources.len())
                || duplicates.is_empty()
                || duplicates.len() > 4_096
                || sources.iter().copied().collect::<HashSet<_>>().len() != sources.len()
                || state.layers.len().saturating_add(duplicates.len()) > MAX_LAYERS
            {
                return Err(EngineError::InvalidCommand(
                    "bulk duplicate requires distinct layer roots within the layer limit".into(),
                ));
            }
            let parent = state
                .layers
                .get(&sources[0])
                .ok_or(EngineError::InvalidLayer)?
                .layer
                .parent;
            let mut expected_sources = Vec::new();
            for source in sources {
                let source_state = state.layers.get(source).ok_or(EngineError::InvalidLayer)?;
                if source_state.layer.parent != parent
                    || source_state.layer.kind == LayerKind::Mask
                    || source_state.layer.kind == LayerKind::PanelGroup
                {
                    return Err(EngineError::InvalidCommand(
                        "bulk duplicate requires sibling roots and cannot target masks or comic layers".into(),
                    ));
                }
                let has_children = state
                    .layers
                    .values()
                    .any(|candidate| candidate.layer.parent == Some(*source));
                let mut tree = if source_state.layer.kind == LayerKind::Group {
                    layer_subtree_ids(&state.layers, *source)?
                } else if has_children {
                    return Err(EngineError::InvalidCommand(
                        "only ordinary groups can duplicate layer subtrees".into(),
                    ));
                } else {
                    vec![*source]
                };
                let mut masks = state
                    .layers
                    .values()
                    .filter(|candidate| {
                        candidate.layer.kind == LayerKind::Mask
                            && candidate.layer.mask_owner == Some(*source)
                    })
                    .map(|candidate| (candidate.layer.order, candidate.layer.id))
                    .collect::<Vec<_>>();
                masks.sort_unstable();
                tree.extend(masks.into_iter().map(|(_, id)| id));
                expected_sources.extend(tree);
            }
            if expected_sources.len() != duplicates.len()
                || expected_sources
                    .iter()
                    .zip(duplicates)
                    .any(|(expected, (actual, _))| expected != actual)
            {
                return Err(EngineError::InvalidCommand(
                    "bulk duplicate mapping does not match the selected layer hierarchy".into(),
                ));
            }
            let mut expected_id = next_layer_id(&state.layers)?.0;
            let mut remap = HashMap::with_capacity(duplicates.len());
            for (old, new) in duplicates {
                if state.layers.contains_key(new)
                    || new.0 != expected_id
                    || remap.insert(*old, *new).is_some()
                {
                    return Err(EngineError::InvalidCommand(
                        "bulk duplicate IDs are not the next available IDs".into(),
                    ));
                }
                expected_id = expected_id.checked_add(1).ok_or_else(|| {
                    EngineError::InvalidCommand("layer ID space exhausted".into())
                })?;
            }
            if sources
                .iter()
                .any(|id| state.layers[id].layer.kind == LayerKind::PanelGroup)
            {
                return Err(EngineError::InvalidCommand(
                    "comic panel structures must be duplicated through the comic workspace".into(),
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
                if expected_sources.iter().any(|id| bound.contains(id)) {
                    return Err(EngineError::InvalidCommand(
                        "comic-owned layers must be duplicated through the comic workspace".into(),
                    ));
                }
            }
            let mut copies = Vec::with_capacity(duplicates.len());
            for (old, new) in duplicates {
                let mut copy = state.layers[old].clone();
                copy.layer.id = *new;
                copy.layer.parent = copy
                    .layer
                    .parent
                    .map(|id| remap.get(&id).copied().unwrap_or(id));
                copy.layer.mask_owner = copy
                    .layer
                    .mask_owner
                    .map(|id| remap.get(&id).copied().unwrap_or(id));
                if sources.contains(old) {
                    copy.layer.name = format!("{} Copy", copy.layer.name);
                }
                copies.push((*old, *new, copy));
            }
            let dirty = copies
                .iter()
                .flat_map(|(_, id, layer)| {
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
            for (_, id, copy) in &copies {
                state.layers.insert(*id, copy.clone());
            }
            let copied_ids = remap.values().copied().collect::<HashSet<_>>();
            let mut siblings = state
                .layers
                .values()
                .filter(|candidate| {
                    candidate.layer.parent == parent && !copied_ids.contains(&candidate.layer.id)
                })
                .map(|candidate| (candidate.layer.order, candidate.layer.id))
                .collect::<Vec<_>>();
            siblings.sort_unstable();
            let mut ordered = Vec::with_capacity(siblings.len() + sources.len());
            for (_, sibling) in siblings {
                ordered.push(sibling);
                if sources.contains(&sibling) {
                    let source = sibling;
                    ordered.extend(copies.iter().filter_map(|(old, new, copy)| {
                        (copy.layer.parent == parent
                            && (*old == source || copy.layer.mask_owner == Some(source)))
                        .then_some(*new)
                    }));
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
        EditorCommand::MergeLayersBulk { layers } => {
            if !(2..=4_096).contains(&layers.len())
                || layers.iter().copied().collect::<HashSet<_>>().len() != layers.len()
            {
                return Err(EngineError::InvalidCommand(
                    "bulk merge requires at least two distinct layers".into(),
                ));
            }
            let parent = state
                .layers
                .get(&layers[0])
                .ok_or(EngineError::InvalidLayer)?
                .layer
                .parent;
            let mut siblings = state
                .layers
                .values()
                .filter(|candidate| candidate.layer.parent == parent)
                .map(|candidate| (candidate.layer.order, candidate.layer.id))
                .collect::<Vec<_>>();
            siblings.sort_unstable();
            let positions = layers
                .iter()
                .map(|id| {
                    siblings
                        .iter()
                        .position(|(_, sibling)| sibling == id)
                        .ok_or(EngineError::InvalidLayer)
                })
                .collect::<Result<Vec<_>, _>>()?;
            let mut sorted_positions = positions.clone();
            sorted_positions.sort_unstable();
            if sorted_positions
                .windows(2)
                .any(|pair| pair[1] != pair[0] + 1)
            {
                return Err(EngineError::InvalidCommand(
                    "bulk merge requires contiguous sibling layers".into(),
                ));
            }
            let ordered = sorted_positions
                .iter()
                .map(|position| siblings[*position].1)
                .collect::<Vec<_>>();
            let target = *ordered.first().ok_or(EngineError::InvalidLayer)?;
            if ordered.iter().any(|id| {
                let layer = &state.layers[id].layer;
                layer.kind != LayerKind::Raster
                    || !layer.visible
                    || layer.blend_mode != ink_model::LayerBlendMode::Normal
                    || layer.clipping
                    || state
                        .layers
                        .values()
                        .any(|child| child.layer.parent == Some(*id))
                    || ancestor_has_mask_node(&state.layers, &state.layers[id])
            }) || ordered
                .iter()
                .any(|id| state.layers[id].layer.kind == LayerKind::Mask)
                || state.layers.values().any(|layer| {
                    layer.layer.parent == parent && layer.layer.kind == LayerKind::Mask
                })
            {
                return Err(EngineError::InvalidCommand(
                    "safe bulk merge requires visible, unlocked standalone raster siblings without masks, clipping, or effects".into(),
                ));
            }
            if state.layers[&target].layer.opacity != u16::MAX {
                return Err(EngineError::InvalidCommand(
                    "exact merge requires the lowest target at 100% opacity".into(),
                ));
            }
            for id in &ordered {
                for (_, bytes) in state.layers[id].tiles.tiles() {
                    Tile::from_bytes(bytes).map_err(|error| {
                        EngineError::InvalidCommand(format!("merge tile is invalid: {error:?}"))
                    })?;
                }
            }
            let before = state.layers.clone();
            let mut dirty = HashSet::new();
            for source in ordered.iter().skip(1) {
                match merge_raster_layers(state, target, *source) {
                    Ok(tiles) => dirty.extend(tiles),
                    Err(error) => {
                        state.layers = before;
                        return Err(error);
                    }
                }
            }
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
                            layer: target,
                            coordinate,
                        })
                        .collect(),
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
        EditorCommand::SetMaskEnabled { mask, enabled } => {
            let layer_state = state
                .layers
                .get_mut(mask)
                .ok_or(EngineError::InvalidLayer)?;
            if layer_state.layer.kind != LayerKind::Mask {
                return Err(EngineError::InvalidCommand(
                    "mask operation requires a mask layer".into(),
                ));
            }
            layer_state.layer.mask_enabled = *enabled;
            advance_revision(state)?;
            state.events.push(EngineEvent::LayersChanged {
                revision: state.revision,
            });
        }
        EditorCommand::SetMaskInverted { mask, inverted } => {
            let layer_state = state
                .layers
                .get_mut(mask)
                .ok_or(EngineError::InvalidLayer)?;
            if layer_state.layer.kind != LayerKind::Mask {
                return Err(EngineError::InvalidCommand(
                    "mask operation requires a mask layer".into(),
                ));
            }
            layer_state.layer.mask_inverted = *inverted;
            advance_revision(state)?;
            state.events.push(EngineEvent::LayersChanged {
                revision: state.revision,
            });
        }
        EditorCommand::ApplyLayerMask { mask } => {
            apply_layer_mask(state, *mask)?;
        }
        EditorCommand::SetLayersVisibility { layers, visible } => {
            let unique: std::collections::HashSet<_> = layers.iter().copied().collect();
            if layers.is_empty() || unique.len() != layers.len() {
                return Err(EngineError::InvalidCommand(
                    "bulk visibility requires distinct layer IDs".into(),
                ));
            }
            if layers.iter().any(|layer| !state.layers.contains_key(layer)) {
                return Err(EngineError::InvalidLayer);
            }
            for layer in layers {
                if let Some(layer_state) = state.layers.get_mut(layer) {
                    layer_state.layer.visible = *visible;
                }
            }
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
        EditorCommand::SetLayerLocked { layer, locked } => {
            let layer_state = state
                .layers
                .get_mut(layer)
                .ok_or(EngineError::InvalidLayer)?;
            layer_state.layer.locked = *locked;
            advance_revision(state)?;
            state.events.push(EngineEvent::LayersChanged {
                revision: state.revision,
            });
        }
        EditorCommand::SetLayersLocked { layers, locked } => {
            let unique: std::collections::HashSet<_> = layers.iter().copied().collect();
            if layers.is_empty() || unique.len() != layers.len() {
                return Err(EngineError::InvalidCommand(
                    "bulk lock requires distinct layer IDs".into(),
                ));
            }
            if layers.iter().any(|layer| !state.layers.contains_key(layer)) {
                return Err(EngineError::InvalidLayer);
            }
            for layer in layers {
                if let Some(layer_state) = state.layers.get_mut(layer) {
                    layer_state.layer.locked = *locked;
                }
            }
            advance_revision(state)?;
            state.events.push(EngineEvent::LayersChanged {
                revision: state.revision,
            });
        }
        EditorCommand::SetLayersLabel { layers, label } => {
            let unique: std::collections::HashSet<_> = layers.iter().copied().collect();
            if layers.is_empty() || unique.len() != layers.len() {
                return Err(EngineError::InvalidCommand(
                    "bulk label requires distinct layer IDs".into(),
                ));
            }
            if layers.iter().any(|layer| !state.layers.contains_key(layer)) {
                return Err(EngineError::InvalidLayer);
            }
            for layer in layers {
                if let Some(layer_state) = state.layers.get_mut(layer) {
                    layer_state.layer.label = *label;
                }
            }
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
            let mut preset = BrushPreset::starters()
                .into_iter()
                .find(|candidate| candidate.id == *brush)
                .unwrap_or_else(|| BrushPreset::starters()[0]);
            if let Some(color) = state.active_brush_color {
                preset.color = color;
            }
            let compiled_brush = if let Some(override_preset) = state.brush_overrides.get(brush) {
                let mut brush_copy = override_preset.clone();
                if let Some(color) = state.active_brush_color {
                    crate::brushes::set_brush_paint_color(&mut brush_copy.paint, color);
                }
                Some(
                    brush_copy
                        .compile()
                        .map_err(|error| EngineError::InvalidCommand(error.to_string()))?,
                )
            } else if brush.0 > 5 {
                let mut brush_copy = builtin_library()
                    .into_iter()
                    .find(|candidate| candidate.id == *brush)
                    .ok_or_else(|| EngineError::InvalidCommand("unknown Phase 2 brush".into()))?;
                if let Some(color) = state.active_brush_color {
                    crate::brushes::set_brush_paint_color(&mut brush_copy.paint, color);
                }
                Some(
                    brush_copy
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
            let time_lapse_stroke = if active.sample_history_complete
                && time_lapse_has_capacity(&state.time_lapse, post_effect_samples.len())
            {
                Some(TimeLapseStroke {
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
                })
            } else {
                None
            };
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
                if !state.layers.get(parent).is_some_and(|candidate| {
                    matches!(
                        candidate.layer.kind,
                        LayerKind::Group | LayerKind::PanelGroup
                    )
                }) {
                    return Err(EngineError::InvalidCommand(
                        "layers can only be moved into a group".into(),
                    ));
                }
            }
            let old_parent = state
                .layers
                .get(layer)
                .ok_or(EngineError::InvalidLayer)?
                .layer
                .parent;
            let moving_layer = state.layers.get(layer).ok_or(EngineError::InvalidLayer)?;
            if moving_layer.layer.kind == LayerKind::Mask
                && moving_layer.layer.mask_owner.is_some()
                && old_parent != *parent
            {
                return Err(EngineError::InvalidCommand(
                    "move the mask owner to keep its attached mask together".into(),
                ));
            }
            let mut attached_masks = state
                .layers
                .values()
                .filter(|candidate| {
                    candidate.layer.kind == LayerKind::Mask
                        && candidate.layer.mask_owner == Some(*layer)
                })
                .map(|candidate| (candidate.layer.order, candidate.layer.id))
                .collect::<Vec<_>>();
            attached_masks.sort_unstable();
            let attached_mask_ids = attached_masks
                .iter()
                .map(|(_, id)| *id)
                .collect::<HashSet<_>>();
            // Preserve the relative order of all unaffected siblings, then
            // insert the moved node and its masks at the requested index.
            let mut target_siblings = state
                .layers
                .values()
                .filter(|candidate| {
                    candidate.layer.parent == *parent
                        && candidate.layer.id != *layer
                        && !attached_mask_ids.contains(&candidate.layer.id)
                })
                .map(|candidate| (candidate.layer.order, candidate.layer.id))
                .collect::<Vec<_>>();
            target_siblings.sort_unstable();
            let insertion = usize::try_from(*index)
                .unwrap_or(usize::MAX)
                .min(target_siblings.len());
            target_siblings.insert(insertion, (u32::MAX, *layer));
            for (offset, (_, mask_id)) in attached_masks.iter().enumerate() {
                target_siblings.insert(insertion + offset + 1, (u32::MAX, *mask_id));
            }
            if let Some(layer_state) = state.layers.get_mut(layer) {
                layer_state.layer.parent = *parent;
            }
            for (_, mask_id) in &attached_masks {
                if let Some(mask_state) = state.layers.get_mut(mask_id) {
                    mask_state.layer.parent = *parent;
                }
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
        EditorCommand::ReorderLayers { layers, index } => {
            let mut roots = Vec::new();
            for id in layers {
                let item = state.layers.get(id).ok_or(EngineError::InvalidLayer)?;
                if item.layer.kind == LayerKind::PanelGroup {
                    return Err(EngineError::InvalidCommand(
                        "comic-owned layers must be reordered in the Comics workspace".into(),
                    ));
                }
                let normalized = item.layer.mask_owner.unwrap_or(*id);
                let mut parent = state
                    .layers
                    .get(&normalized)
                    .ok_or(EngineError::InvalidLayer)?
                    .layer
                    .parent;
                let mut nested = false;
                let mut visited = HashSet::new();
                while let Some(parent_id) = parent {
                    if !visited.insert(parent_id) {
                        return Err(EngineError::InvalidCommand(
                            "layer hierarchy contains a cycle".into(),
                        ));
                    }
                    if roots.contains(&parent_id) {
                        nested = true;
                        break;
                    }
                    let ancestor = state
                        .layers
                        .get(&parent_id)
                        .ok_or(EngineError::InvalidLayer)?;
                    if ancestor.layer.kind == LayerKind::PanelGroup {
                        return Err(EngineError::InvalidCommand(
                            "comic-owned layers must be reordered in the Comics workspace".into(),
                        ));
                    }
                    parent = ancestor.layer.parent;
                }
                if !nested && !roots.contains(&normalized) {
                    roots.push(normalized);
                }
            }
            if roots.is_empty() {
                return Err(EngineError::InvalidCommand(
                    "multi-layer reorder has no structural roots".into(),
                ));
            }
            let parent = state
                .layers
                .get(&roots[0])
                .ok_or(EngineError::InvalidLayer)?
                .layer
                .parent;
            if roots.iter().any(|id| {
                state
                    .layers
                    .get(id)
                    .is_none_or(|item| item.layer.parent != parent)
            }) {
                return Err(EngineError::InvalidCommand(
                    "selected layers must share one sibling stack to reorder together".into(),
                ));
            }
            let root_set: HashSet<_> = roots.iter().copied().collect();
            let mut moving = state
                .layers
                .values()
                .filter(|item| {
                    root_set.contains(&item.layer.id)
                        || (item.layer.kind == LayerKind::Mask
                            && item
                                .layer
                                .mask_owner
                                .is_some_and(|owner| root_set.contains(&owner)))
                })
                .map(|item| (item.layer.order, item.layer.id))
                .collect::<Vec<_>>();
            moving.sort_unstable();
            let moving_ids: HashSet<_> = moving.iter().map(|(_, id)| *id).collect();
            let mut siblings = state
                .layers
                .values()
                .filter(|item| item.layer.parent == parent && !moving_ids.contains(&item.layer.id))
                .map(|item| (item.layer.order, item.layer.id))
                .collect::<Vec<_>>();
            siblings.sort_unstable();
            let insertion = usize::try_from(*index)
                .unwrap_or(usize::MAX)
                .min(siblings.len());
            siblings.splice(insertion..insertion, moving);
            for (order, (_, id)) in siblings.into_iter().enumerate() {
                if let Some(item) = state.layers.get_mut(&id) {
                    item.layer.order = u32::try_from(order).unwrap_or(u32::MAX);
                }
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
