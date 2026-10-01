use super::{
    BTreeMap, DocumentSpec, EngineError, LayerId, LayerKind, LayerState, StoredState, TILE_SIZE,
    Tile, TileRecord, TileStore, VectorRecord, VectorStroke, ordered_layer_states,
    validate_layer_tree, validate_vector_stroke,
};

pub(super) fn map_to_stored_state(layers: &BTreeMap<LayerId, LayerState>) -> StoredState {
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

pub(super) fn stored_to_map(
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
