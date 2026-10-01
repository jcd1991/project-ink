use super::{
    ActiveStroke, BrushPreset, CompiledBrush, CompiledBrushState, DocumentSpec, EditorCommand,
    EngineError, EngineEvent, EngineState, HashMap, HashSet, Layer, LayerId, LayerKind, LayerState,
    MAX_COMMAND_JOURNAL_ENTRIES, MAX_FILL_PIXELS, MAX_LAYERS, MAX_PANEL_MASK_PIXELS, Rgba8,
    SelectionMask, StrokeInputMetrics, TileDescriptor, TileStore, TimeLapseSample, TimeLapseStroke,
    Transaction, VectorPoint, VectorStroke, advance_revision, apply_post_effects, builtin_library,
    compositor_blend_mode, encode_command, flush_deferred_dual_dabs, history_label,
    layer_subtree_ids, lock_recover, merge_raster_layers, next_layer_id, normalize_sibling_orders,
    point_inside_polygon, rasterize_vector_stroke, rebuild_vector_layer, restore_brush_override,
    time_lapse_has_capacity, trim_history_snapshots, validate_layer_tree, validate_vector_stroke,
};

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
