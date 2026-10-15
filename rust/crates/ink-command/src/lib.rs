//! Shared editor commands and bounded undo/redo history.
#![allow(missing_docs)]
#![allow(
    clippy::missing_errors_doc,
    clippy::missing_panics_doc,
    clippy::must_use_candidate
)]

use ink_model::{
    BrushId, Id, LayerAdjustment, LayerBlendMode, LayerGroupMode, LayerId, LayerKind, Rgba8,
    StrokeId, VectorObject,
};

const MAX_VECTOR_PATCH_BYTES: usize = 256 * 1_024;
const MAX_VECTOR_PATCH_EDITS: usize = 4_096;

/// One ordered, resolved-geometry edit in an atomic vector patch.
#[derive(Clone, Debug, PartialEq)]
pub enum VectorPatchEdit {
    /// Insert an object at an explicit layer order position.
    Insert {
        object_id: Id,
        position: u32,
        object: VectorObject,
    },
    /// Replace geometry/style for an existing ID without changing its order.
    Replace { object_id: Id, object: VectorObject },
    /// Remove one object by stable ID.
    Remove { object_id: Id },
}

/// User-visible command IDs are represented by this stable enum.
#[derive(Clone, Debug, PartialEq)]
pub enum EditorCommand {
    AddLayer {
        parent: Option<LayerId>,
        kind: LayerKind,
    },
    DeleteLayer {
        layer: LayerId,
    },
    /// Delete several structural roots and their descendants atomically.
    DeleteLayers {
        layers: Vec<LayerId>,
    },
    /// Duplicate one leaf layer into a new stable ID, preserving its content
    /// and presentation while inserting the copy immediately above its source.
    DuplicateLayer {
        source: LayerId,
        duplicate: LayerId,
    },
    /// Duplicate one leaf together with every mask attached to it. The mask
    /// pairs are encoded in sibling order and receive fresh stable IDs.
    DuplicateLayerWithMasks {
        source: LayerId,
        duplicate: LayerId,
        masks: Vec<(LayerId, LayerId)>,
    },
    /// Duplicate an ordinary group and every descendant with stable ID remaps.
    /// Pairs are encoded in deterministic source preorder, with the root first.
    DuplicateLayerSubtree {
        source: LayerId,
        duplicates: Vec<(LayerId, LayerId)>,
    },
    /// Atomically duplicate selected sibling roots and their owned subtrees.
    /// `duplicates` is concatenated source-preorder mappings in `sources` order.
    DuplicateLayers {
        sources: Vec<LayerId>,
        duplicates: Vec<(LayerId, LayerId)>,
    },
    /// Group selected sibling layers into one pass-through group.
    GroupLayers {
        group: LayerId,
        members: Vec<LayerId>,
    },
    /// Remove an ordinary group while keeping its children at the group's
    /// sibling position. The engine validates that this preserves compositing.
    UngroupLayer {
        group: LayerId,
    },
    /// Merge the standalone raster [source] into [target] and remove source.
    /// The command is intentionally explicit about both IDs so replay and
    /// undo cannot depend on mutable layer-list indexes.
    MergeLayers {
        target: LayerId,
        source: LayerId,
    },
    /// Merge a contiguous selected sibling stack into its lowest layer.
    MergeLayersBulk {
        layers: Vec<LayerId>,
    },
    MoveLayer {
        layer: LayerId,
        parent: Option<LayerId>,
        index: u32,
    },
    /// Reorder selected sibling roots together while preserving their order.
    ReorderLayers {
        layers: Vec<LayerId>,
        index: u32,
    },
    /// Atomically create the deterministic layer tree owned by a comic panel.
    /// All IDs are supplied by the comic model so panel metadata and document
    /// layers remain joinable across save/reopen and page migration.
    CreatePanelLayerTree {
        panel: Id,
        panel_group: LayerId,
        mask: LayerId,
        sketch: LayerId,
        ink: LayerId,
        color: LayerId,
        tone: LayerId,
        effects: LayerId,
    },
    /// Replace the geometry of a generated panel/group mask. Coordinates are
    /// document-space and the engine rasterizes them into the mask layer.
    SetPanelMaskGeometry {
        mask: LayerId,
        points: Vec<(f32, f32)>,
    },
    /// Replace the contents of a raster layer with rendered panel borders.
    SetPanelFrames {
        layer: LayerId,
        frames: Vec<Vec<(f32, f32)>>,
        border_px: f32,
    },
    /// Remove all paint/vector contents from one paint layer.
    ClearLayer {
        layer: LayerId,
    },
    SetLayerOpacity {
        layer: LayerId,
        opacity: u16,
    },
    SetLayerVisibility {
        layer: LayerId,
        visible: bool,
    },
    /// Enable or disable an attached mask without changing its stored tiles.
    SetMaskEnabled {
        mask: LayerId,
        enabled: bool,
    },
    /// Invert an attached mask without rewriting its stored tiles.
    SetMaskInverted {
        mask: LayerId,
        inverted: bool,
    },
    /// Apply an attached mask to its raster owner and remove the mask atomically.
    ApplyLayerMask {
        mask: LayerId,
    },
    /// Change visibility for a set of distinct layers in one history entry.
    SetLayersVisibility {
        layers: Vec<LayerId>,
        visible: bool,
    },
    /// Change the color label for distinct selected layers atomically.
    SetLayersLabel {
        layers: Vec<LayerId>,
        label: Option<Rgba8>,
    },
    SetLayerBlendMode {
        layer: LayerId,
        mode: LayerBlendMode,
    },
    SetLayerGroupMode {
        layer: LayerId,
        mode: LayerGroupMode,
    },
    SetLayerAlphaLock {
        layer: LayerId,
        enabled: bool,
    },
    /// Set or clear the full content and property lock on one layer.
    SetLayerLocked {
        layer: LayerId,
        locked: bool,
    },
    /// Change full lock state on distinct selected layers in one history entry.
    SetLayersLocked {
        layers: Vec<LayerId>,
        locked: bool,
    },
    SetLayerClipping {
        layer: LayerId,
        enabled: bool,
    },
    SetLayerReference {
        layer: LayerId,
        enabled: bool,
    },
    SetLayerLabel {
        layer: LayerId,
        label: Option<Rgba8>,
    },
    SetLayerName {
        layer: LayerId,
        name: String,
    },
    SetLayerAdjustment {
        layer: LayerId,
        adjustment: LayerAdjustment,
    },
    /// Apply a bounded affine transform to the raster pixels in one layer.
    /// The matrix maps document-space `(x, y)` to `(a*x + c*y + tx,
    /// b*x + d*y + ty)` and is persisted in the command journal.
    TransformLayer {
        layer: LayerId,
        a: f32,
        b: f32,
        c: f32,
        d: f32,
        tx: f32,
        ty: f32,
    },
    /// Fill a contiguous region on a raster layer using a bounded color
    /// tolerance and gap-closing radius.
    FillRegion {
        layer: LayerId,
        x: u32,
        y: u32,
        color: Rgba8,
        tolerance: u16,
        gap: u32,
    },
    /// Apply a deterministic linear gradient through a flood/paint-inside
    /// mask. `expansion` grows the computed mask by a bounded radius;
    /// `paint_unfilled` restricts the result to currently transparent pixels.
    GradientFill {
        layer: LayerId,
        x: u32,
        y: u32,
        start_x: f32,
        start_y: f32,
        end_x: f32,
        end_y: f32,
        from: Rgba8,
        to: Rgba8,
        tolerance: u16,
        gap: u32,
        expansion: u32,
        paint_inside: bool,
        paint_unfilled: bool,
    },
    /// Map the full raster canvas into a bounded target quadrilateral.
    PerspectiveLayer {
        layer: LayerId,
        target: [(f32, f32); 4],
    },
    /// Apply a bounded regular bilinear mesh transform to a raster layer.
    MeshLayer {
        layer: LayerId,
        columns: u16,
        rows: u16,
        points: Vec<(f32, f32)>,
    },
    /// Apply a bounded local liquify deformation to a raster layer.
    LiquifyLayer {
        layer: LayerId,
        center_x: f32,
        center_y: f32,
        radius: f32,
        strength: f32,
        mode: u8,
        direction_x: f32,
        direction_y: f32,
    },
    /// Add one bounded editable centerline stroke to a vector-ink layer.
    AddVectorStroke {
        layer: LayerId,
        stroke: StrokeId,
        points: Vec<(f32, f32, f32, f32)>,
        closed: bool,
    },
    TransformVectorStroke {
        layer: LayerId,
        stroke: StrokeId,
        a: f32,
        b: f32,
        c: f32,
        d: f32,
        tx: f32,
        ty: f32,
    },
    SimplifyVectorStroke {
        layer: LayerId,
        stroke: StrokeId,
        tolerance: f32,
    },
    ConnectVectorStrokes {
        layer: LayerId,
        first: StrokeId,
        second: StrokeId,
        tolerance: f32,
    },
    EraseVectorSegment {
        layer: LayerId,
        stroke: StrokeId,
        center_x: f32,
        center_y: f32,
        radius: f32,
    },
    SetVectorPoint {
        layer: LayerId,
        stroke: StrokeId,
        index: u32,
        x: f32,
        y: f32,
        pressure: f32,
        tilt: f32,
    },
    /// Apply resolved geometry edits atomically to one vector layer.
    ApplyVectorPatch {
        layer: LayerId,
        edits: Vec<VectorPatchEdit>,
    },
    BeginStroke {
        stroke: StrokeId,
        layer: LayerId,
        brush: BrushId,
    },
    EndStroke {
        stroke: StrokeId,
    },
    CancelStroke {
        stroke: StrokeId,
    },
    Undo,
    Redo,
}

fn append_id(bytes: &mut Vec<u8>, value: ink_model::Id) {
    bytes.extend_from_slice(&value.0.to_le_bytes());
}

/// Encode a command for the append-only journal. Invalid vector patches
/// produce an empty payload; engine code should use [`try_encode_command`] to
/// receive a typed error before changing document state.
#[allow(clippy::too_many_lines)]
#[must_use]
pub fn encode_command(command: &EditorCommand) -> Vec<u8> {
    try_encode_command(command).unwrap_or_default()
}

/// Fallibly encode one command, enforcing the vector-patch size and geometry
/// bounds before allocating its journal payload.
pub fn try_encode_command(command: &EditorCommand) -> Result<Vec<u8>, CommandEncodeError> {
    let capacity = if let EditorCommand::ApplyVectorPatch { edits, .. } = command {
        vector_patch_encoded_size(edits)?
    } else {
        0
    };
    let mut bytes = Vec::new();
    bytes
        .try_reserve_exact(capacity)
        .map_err(|_| CommandEncodeError::VectorPatchTooLarge)?;
    Ok(encode_command_unchecked(command, bytes))
}

#[allow(clippy::too_many_lines)]
fn encode_command_unchecked(command: &EditorCommand, mut bytes: Vec<u8>) -> Vec<u8> {
    match command {
        EditorCommand::AddLayer { parent, kind } => {
            bytes.push(1);
            bytes.push(u8::from(parent.is_some()));
            if let Some(parent) = parent {
                append_id(&mut bytes, *parent);
            }
            bytes.push(*kind as u8);
        }
        EditorCommand::DeleteLayer { layer } => {
            bytes.push(2);
            append_id(&mut bytes, *layer);
        }
        EditorCommand::DeleteLayers { layers } => {
            bytes.push(37);
            let count = u16::try_from(layers.len()).unwrap_or(u16::MAX);
            bytes.extend_from_slice(&count.to_le_bytes());
            for layer in layers.iter().take(usize::from(count)) {
                append_id(&mut bytes, *layer);
            }
        }
        EditorCommand::SetLayersVisibility { layers, visible } => {
            bytes.push(40);
            bytes.push(u8::from(*visible));
            let count = u16::try_from(layers.len()).unwrap_or(u16::MAX);
            bytes.extend_from_slice(&count.to_le_bytes());
            for layer in layers.iter().take(usize::from(count)) {
                append_id(&mut bytes, *layer);
            }
        }
        EditorCommand::DuplicateLayer { source, duplicate } => {
            bytes.push(33);
            append_id(&mut bytes, *source);
            append_id(&mut bytes, *duplicate);
        }
        EditorCommand::DuplicateLayerWithMasks {
            source,
            duplicate,
            masks,
        } => {
            bytes.push(39);
            append_id(&mut bytes, *source);
            append_id(&mut bytes, *duplicate);
            let count = u16::try_from(masks.len()).unwrap_or(u16::MAX);
            bytes.extend_from_slice(&count.to_le_bytes());
            for (source_mask, duplicate_mask) in masks.iter().take(usize::from(count)) {
                append_id(&mut bytes, *source_mask);
                append_id(&mut bytes, *duplicate_mask);
            }
        }
        EditorCommand::DuplicateLayerSubtree { source, duplicates } => {
            bytes.push(34);
            append_id(&mut bytes, *source);
            let count = u16::try_from(duplicates.len()).unwrap_or(u16::MAX);
            bytes.extend_from_slice(&count.to_le_bytes());
            for (source_id, duplicate_id) in duplicates.iter().take(usize::from(count)) {
                append_id(&mut bytes, *source_id);
                append_id(&mut bytes, *duplicate_id);
            }
        }
        EditorCommand::DuplicateLayers {
            sources,
            duplicates,
        } => {
            bytes.push(45);
            let source_count = u16::try_from(sources.len()).unwrap_or(u16::MAX);
            bytes.extend_from_slice(&source_count.to_le_bytes());
            for source in sources.iter().take(usize::from(source_count)) {
                append_id(&mut bytes, *source);
            }
            let duplicate_count = u16::try_from(duplicates.len()).unwrap_or(u16::MAX);
            bytes.extend_from_slice(&duplicate_count.to_le_bytes());
            for (source, duplicate) in duplicates.iter().take(usize::from(duplicate_count)) {
                append_id(&mut bytes, *source);
                append_id(&mut bytes, *duplicate);
            }
        }
        EditorCommand::GroupLayers { group, members } => {
            bytes.push(36);
            append_id(&mut bytes, *group);
            let count = u16::try_from(members.len()).unwrap_or(u16::MAX);
            bytes.extend_from_slice(&count.to_le_bytes());
            for member in members.iter().take(usize::from(count)) {
                append_id(&mut bytes, *member);
            }
        }
        EditorCommand::UngroupLayer { group } => {
            bytes.push(38);
            append_id(&mut bytes, *group);
        }
        EditorCommand::MergeLayers { target, source } => {
            bytes.push(29);
            append_id(&mut bytes, *target);
            append_id(&mut bytes, *source);
        }
        EditorCommand::MergeLayersBulk { layers } => {
            bytes.push(46);
            let count = u16::try_from(layers.len()).unwrap_or(u16::MAX);
            bytes.extend_from_slice(&count.to_le_bytes());
            for layer in layers.iter().take(usize::from(count)) {
                append_id(&mut bytes, *layer);
            }
        }
        EditorCommand::MoveLayer {
            layer,
            parent,
            index,
        } => {
            bytes.push(3);
            append_id(&mut bytes, *layer);
            bytes.push(u8::from(parent.is_some()));
            if let Some(parent) = parent {
                append_id(&mut bytes, *parent);
            }
            bytes.extend_from_slice(&index.to_le_bytes());
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
            bytes.push(30);
            for id in [panel, panel_group, mask, sketch, ink, color, tone, effects] {
                append_id(&mut bytes, *id);
            }
        }
        EditorCommand::SetPanelMaskGeometry { mask, points } => {
            bytes.push(31);
            append_id(&mut bytes, *mask);
            let count = u16::try_from(points.len()).unwrap_or(u16::MAX);
            bytes.extend_from_slice(&count.to_le_bytes());
            for (x, y) in points.iter().take(usize::from(count)) {
                bytes.extend_from_slice(&x.to_le_bytes());
                bytes.extend_from_slice(&y.to_le_bytes());
            }
        }
        EditorCommand::SetPanelFrames {
            layer,
            frames,
            border_px,
        } => {
            bytes.push(50);
            append_id(&mut bytes, *layer);
            bytes.extend_from_slice(&border_px.to_le_bytes());
            let count = u16::try_from(frames.len()).unwrap_or(u16::MAX);
            bytes.extend_from_slice(&count.to_le_bytes());
            for frame in frames.iter().take(usize::from(count)) {
                bytes.push(u8::try_from(frame.len()).unwrap_or(u8::MAX));
                for (x, y) in frame {
                    bytes.extend_from_slice(&x.to_le_bytes());
                    bytes.extend_from_slice(&y.to_le_bytes());
                }
            }
        }
        EditorCommand::ClearLayer { layer } => {
            bytes.push(51);
            append_id(&mut bytes, *layer);
        }
        EditorCommand::SetLayerOpacity { layer, opacity } => {
            bytes.push(4);
            append_id(&mut bytes, *layer);
            bytes.extend_from_slice(&opacity.to_le_bytes());
        }
        EditorCommand::SetLayerVisibility { layer, visible } => {
            bytes.push(5);
            append_id(&mut bytes, *layer);
            bytes.push(u8::from(*visible));
        }
        EditorCommand::SetMaskEnabled { mask, enabled } => {
            bytes.push(47);
            append_id(&mut bytes, *mask);
            bytes.push(u8::from(*enabled));
        }
        EditorCommand::SetMaskInverted { mask, inverted } => {
            bytes.push(48);
            append_id(&mut bytes, *mask);
            bytes.push(u8::from(*inverted));
        }
        EditorCommand::ApplyLayerMask { mask } => {
            bytes.push(49);
            append_id(&mut bytes, *mask);
        }
        EditorCommand::SetLayerBlendMode { layer, mode } => {
            bytes.push(11);
            append_id(&mut bytes, *layer);
            bytes.push(encode_layer_blend_mode(*mode));
        }
        EditorCommand::SetLayerGroupMode { layer, mode } => {
            bytes.push(35);
            append_id(&mut bytes, *layer);
            bytes.push(match mode {
                LayerGroupMode::Isolated => 0,
                LayerGroupMode::PassThrough => 1,
            });
        }
        EditorCommand::SetLayerAlphaLock { layer, enabled } => {
            bytes.push(12);
            append_id(&mut bytes, *layer);
            bytes.push(u8::from(*enabled));
        }
        EditorCommand::SetLayerLocked { layer, locked } => {
            bytes.push(41);
            append_id(&mut bytes, *layer);
            bytes.push(u8::from(*locked));
        }
        EditorCommand::SetLayersLocked { layers, locked } => {
            bytes.push(42);
            bytes.push(u8::from(*locked));
            let count = u16::try_from(layers.len()).unwrap_or(u16::MAX);
            bytes.extend_from_slice(&count.to_le_bytes());
            for layer in layers.iter().take(usize::from(count)) {
                append_id(&mut bytes, *layer);
            }
        }
        EditorCommand::SetLayersLabel { layers, label } => {
            bytes.push(44);
            bytes.push(u8::from(label.is_some()));
            if let Some(label) = label {
                bytes.extend([label.r, label.g, label.b, label.a]);
            }
            let count = u16::try_from(layers.len()).unwrap_or(u16::MAX);
            bytes.extend_from_slice(&count.to_le_bytes());
            for layer in layers.iter().take(usize::from(count)) {
                append_id(&mut bytes, *layer);
            }
        }
        EditorCommand::ReorderLayers { layers, index } => {
            bytes.push(43);
            bytes.extend_from_slice(&index.to_le_bytes());
            let count = u16::try_from(layers.len()).unwrap_or(u16::MAX);
            bytes.extend_from_slice(&count.to_le_bytes());
            for layer in layers.iter().take(usize::from(count)) {
                append_id(&mut bytes, *layer);
            }
        }
        EditorCommand::SetLayerClipping { layer, enabled } => {
            bytes.push(13);
            append_id(&mut bytes, *layer);
            bytes.push(u8::from(*enabled));
        }
        EditorCommand::SetLayerReference { layer, enabled } => {
            bytes.push(14);
            append_id(&mut bytes, *layer);
            bytes.push(u8::from(*enabled));
        }
        EditorCommand::SetLayerLabel { layer, label } => {
            bytes.push(15);
            append_id(&mut bytes, *layer);
            bytes.push(u8::from(label.is_some()));
            if let Some(label) = label {
                bytes.extend([label.r, label.g, label.b, label.a]);
            }
        }
        EditorCommand::SetLayerName { layer, name } => {
            bytes.push(16);
            append_id(&mut bytes, *layer);
            let name_bytes = name.as_bytes();
            let length = u16::try_from(name_bytes.len()).unwrap_or(u16::MAX);
            bytes.extend(length.to_le_bytes());
            bytes.extend(&name_bytes[..usize::from(length).min(name_bytes.len())]);
        }
        EditorCommand::SetLayerAdjustment { layer, adjustment } => {
            bytes.push(32);
            append_id(&mut bytes, *layer);
            match adjustment {
                LayerAdjustment::BrightnessContrast {
                    brightness,
                    contrast,
                } => {
                    bytes.push(0);
                    bytes.extend_from_slice(&brightness.to_le_bytes());
                    bytes.extend_from_slice(&contrast.to_le_bytes());
                }
                LayerAdjustment::Levels {
                    input_black,
                    input_white,
                    gamma_hundredths,
                    output_black,
                    output_white,
                } => {
                    bytes.push(1);
                    bytes.extend([input_black, input_white]);
                    bytes.extend_from_slice(&gamma_hundredths.to_le_bytes());
                    bytes.extend([output_black, output_white]);
                }
                LayerAdjustment::Curves {
                    master,
                    red,
                    green,
                    blue,
                } => {
                    bytes.push(2);
                    for curve in [master, red, green, blue] {
                        bytes.push(curve.len);
                        for point in curve.points {
                            bytes.extend([point.x, point.y]);
                        }
                    }
                }
                LayerAdjustment::HueSaturation {
                    hue_degrees,
                    saturation,
                    lightness,
                } => {
                    bytes.push(3);
                    bytes.extend_from_slice(&hue_degrees.to_le_bytes());
                    bytes.extend_from_slice(&saturation.to_le_bytes());
                    bytes.extend_from_slice(&lightness.to_le_bytes());
                }
            }
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
            bytes.push(17);
            append_id(&mut bytes, *layer);
            for value in [a, b, c, d, tx, ty] {
                bytes.extend_from_slice(&value.to_le_bytes());
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
            bytes.push(18);
            append_id(&mut bytes, *layer);
            bytes.extend_from_slice(&x.to_le_bytes());
            bytes.extend_from_slice(&y.to_le_bytes());
            bytes.extend([color.r, color.g, color.b, color.a]);
            bytes.extend_from_slice(&tolerance.to_le_bytes());
            bytes.extend_from_slice(&gap.to_le_bytes());
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
            bytes.push(28);
            append_id(&mut bytes, *layer);
            bytes.extend_from_slice(&x.to_le_bytes());
            bytes.extend_from_slice(&y.to_le_bytes());
            for value in [start_x, start_y, end_x, end_y] {
                bytes.extend_from_slice(&value.to_le_bytes());
            }
            bytes.extend([from.r, from.g, from.b, from.a]);
            bytes.extend([to.r, to.g, to.b, to.a]);
            bytes.extend_from_slice(&tolerance.to_le_bytes());
            bytes.extend_from_slice(&gap.to_le_bytes());
            bytes.extend_from_slice(&expansion.to_le_bytes());
            bytes.push(u8::from(*paint_inside));
            bytes.push(u8::from(*paint_unfilled));
        }
        EditorCommand::PerspectiveLayer { layer, target } => {
            bytes.push(19);
            append_id(&mut bytes, *layer);
            for (x, y) in target {
                bytes.extend_from_slice(&x.to_le_bytes());
                bytes.extend_from_slice(&y.to_le_bytes());
            }
        }
        EditorCommand::MeshLayer {
            layer,
            columns,
            rows,
            points,
        } => {
            bytes.push(20);
            append_id(&mut bytes, *layer);
            bytes.extend_from_slice(&columns.to_le_bytes());
            bytes.extend_from_slice(&rows.to_le_bytes());
            let count = u16::try_from(points.len()).unwrap_or(u16::MAX);
            bytes.extend_from_slice(&count.to_le_bytes());
            for (x, y) in points.iter().take(usize::from(count)) {
                bytes.extend_from_slice(&x.to_le_bytes());
                bytes.extend_from_slice(&y.to_le_bytes());
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
            bytes.push(21);
            append_id(&mut bytes, *layer);
            for value in [
                center_x,
                center_y,
                radius,
                strength,
                direction_x,
                direction_y,
            ] {
                bytes.extend_from_slice(&value.to_le_bytes());
            }
            bytes.push(*mode);
        }
        EditorCommand::AddVectorStroke {
            layer,
            stroke,
            points,
            closed,
        } => {
            bytes.push(22);
            append_id(&mut bytes, *layer);
            append_id(&mut bytes, *stroke);
            bytes.push(u8::from(*closed));
            let count = u16::try_from(points.len()).unwrap_or(u16::MAX);
            bytes.extend_from_slice(&count.to_le_bytes());
            for (x, y, pressure, tilt) in points.iter().take(usize::from(count)) {
                for value in [x, y, pressure, tilt] {
                    bytes.extend_from_slice(&value.to_le_bytes());
                }
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
            bytes.push(23);
            append_id(&mut bytes, *layer);
            append_id(&mut bytes, *stroke);
            for value in [a, b, c, d, tx, ty] {
                bytes.extend_from_slice(&value.to_le_bytes());
            }
        }
        EditorCommand::SimplifyVectorStroke {
            layer,
            stroke,
            tolerance,
        } => {
            bytes.push(24);
            append_id(&mut bytes, *layer);
            append_id(&mut bytes, *stroke);
            bytes.extend_from_slice(&tolerance.to_le_bytes());
        }
        EditorCommand::ConnectVectorStrokes {
            layer,
            first,
            second,
            tolerance,
        } => {
            bytes.push(25);
            append_id(&mut bytes, *layer);
            append_id(&mut bytes, *first);
            append_id(&mut bytes, *second);
            bytes.extend_from_slice(&tolerance.to_le_bytes());
        }
        EditorCommand::EraseVectorSegment {
            layer,
            stroke,
            center_x,
            center_y,
            radius,
        } => {
            bytes.push(26);
            append_id(&mut bytes, *layer);
            append_id(&mut bytes, *stroke);
            for value in [center_x, center_y, radius] {
                bytes.extend_from_slice(&value.to_le_bytes());
            }
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
            bytes.push(27);
            append_id(&mut bytes, *layer);
            append_id(&mut bytes, *stroke);
            bytes.extend_from_slice(&index.to_le_bytes());
            for value in [x, y, pressure, tilt] {
                bytes.extend_from_slice(&value.to_le_bytes());
            }
        }
        EditorCommand::ApplyVectorPatch { layer, edits } => {
            bytes.push(52);
            append_id(&mut bytes, *layer);
            bytes.push(1); // vector_semantics
            let count = u16::try_from(edits.len()).unwrap_or(u16::MAX);
            bytes.extend_from_slice(&count.to_le_bytes());
            for edit in edits.iter().take(usize::from(count)) {
                match edit {
                    VectorPatchEdit::Insert {
                        object_id,
                        position,
                        object,
                    } => {
                        bytes.push(0);
                        append_id(&mut bytes, *object_id);
                        bytes.extend_from_slice(&position.to_le_bytes());
                        append_vector_object(&mut bytes, object);
                    }
                    VectorPatchEdit::Replace { object_id, object } => {
                        bytes.push(1);
                        append_id(&mut bytes, *object_id);
                        append_vector_object(&mut bytes, object);
                    }
                    VectorPatchEdit::Remove { object_id } => {
                        bytes.push(2);
                        append_id(&mut bytes, *object_id);
                    }
                }
            }
        }
        EditorCommand::BeginStroke {
            stroke,
            layer,
            brush,
        } => {
            bytes.push(6);
            append_id(&mut bytes, *stroke);
            append_id(&mut bytes, *layer);
            append_id(&mut bytes, *brush);
        }
        EditorCommand::EndStroke { stroke } => {
            bytes.push(7);
            append_id(&mut bytes, *stroke);
        }
        EditorCommand::CancelStroke { stroke } => {
            bytes.push(8);
            append_id(&mut bytes, *stroke);
        }
        EditorCommand::Undo => bytes.push(9),
        EditorCommand::Redo => bytes.push(10),
    }
    bytes
}

fn append_vector_object(bytes: &mut Vec<u8>, object: &VectorObject) {
    match object {
        VectorObject::LegacyInk { stroke } => {
            bytes.push(0);
            append_vector_stroke(bytes, stroke);
        }
        VectorObject::BezierPath { path, source } => {
            bytes.push(1);
            append_optional_color(bytes, path.style.fill);
            append_optional_color(bytes, path.style.stroke);
            bytes.extend_from_slice(&path.style.stroke_width.to_le_bytes());
            bytes.push(match path.style.cap {
                ink_model::StrokeCap::Butt => 0,
                ink_model::StrokeCap::Square => 1,
                ink_model::StrokeCap::Round => 2,
            });
            bytes.push(match path.style.join {
                ink_model::StrokeJoin::Miter => 0,
                ink_model::StrokeJoin::Bevel => 1,
                ink_model::StrokeJoin::Round => 2,
            });
            bytes.extend_from_slice(&path.style.miter_limit.to_le_bytes());
            bytes.push(match path.style.fill_rule {
                ink_model::FillRule::NonZero => 0,
                ink_model::FillRule::EvenOdd => 1,
            });
            bytes.extend_from_slice(
                &u16::try_from(path.subpaths.len())
                    .unwrap_or(u16::MAX)
                    .to_le_bytes(),
            );
            for subpath in &path.subpaths {
                bytes.push(u8::from(subpath.closed));
                bytes.extend_from_slice(
                    &u16::try_from(subpath.anchors.len())
                        .unwrap_or(u16::MAX)
                        .to_le_bytes(),
                );
                for anchor in &subpath.anchors {
                    for value in [
                        anchor.x,
                        anchor.y,
                        anchor.incoming[0],
                        anchor.incoming[1],
                        anchor.outgoing[0],
                        anchor.outgoing[1],
                    ] {
                        bytes.extend_from_slice(&value.to_le_bytes());
                    }
                    bytes.push(match anchor.kind {
                        ink_model::AnchorKind::Corner => 0,
                        ink_model::AnchorKind::Smooth => 1,
                    });
                }
            }
            match source {
                None => bytes.push(0),
                Some(source) => {
                    bytes.push(1);
                    append_vector_stroke(bytes, &source.legacy);
                }
            }
        }
    }
}

fn append_vector_stroke(bytes: &mut Vec<u8>, stroke: &ink_model::VectorStroke) {
    bytes.push(u8::from(stroke.closed));
    bytes.extend_from_slice(
        &u16::try_from(stroke.points.len())
            .unwrap_or(u16::MAX)
            .to_le_bytes(),
    );
    for point in &stroke.points {
        for value in [point.x, point.y, point.pressure, point.tilt] {
            bytes.extend_from_slice(&value.to_le_bytes());
        }
    }
}

fn append_optional_color(bytes: &mut Vec<u8>, color: Option<Rgba8>) {
    match color {
        None => bytes.push(0),
        Some(color) => {
            bytes.push(1);
            bytes.extend_from_slice(&[color.r, color.g, color.b, color.a]);
        }
    }
}

fn vector_patch_encoded_size(edits: &[VectorPatchEdit]) -> Result<usize, CommandEncodeError> {
    if edits.is_empty() || edits.len() > MAX_VECTOR_PATCH_EDITS {
        return Err(CommandEncodeError::InvalidVectorPatch);
    }
    let mut size = 1_usize + 16 + 1 + 2; // tag, layer ID, semantics, edit count
    for edit in edits {
        size = size
            .checked_add(match edit {
                VectorPatchEdit::Insert { object, .. } => {
                    1 + 16 + 4 + vector_object_encoded_size(object)?
                }
                VectorPatchEdit::Replace { object, .. } => {
                    1 + 16 + vector_object_encoded_size(object)?
                }
                VectorPatchEdit::Remove { .. } => 1 + 16,
            })
            .ok_or(CommandEncodeError::VectorPatchTooLarge)?;
        if size > MAX_VECTOR_PATCH_BYTES {
            return Err(CommandEncodeError::VectorPatchTooLarge);
        }
    }
    Ok(size)
}

fn vector_object_encoded_size(object: &VectorObject) -> Result<usize, CommandEncodeError> {
    match object {
        VectorObject::LegacyInk { stroke } => 1_usize
            .checked_add(vector_stroke_encoded_size(stroke)?)
            .ok_or(CommandEncodeError::VectorPatchTooLarge),
        VectorObject::BezierPath { path, source } => {
            if path.subpaths.is_empty()
                || path.subpaths.len() > 128
                || !path.style.stroke_width.is_finite()
                || !(0.0..=4096.0).contains(&path.style.stroke_width)
                || !path.style.miter_limit.is_finite()
                || !(1.0..=64.0).contains(&path.style.miter_limit)
                || (path.style.fill.is_none() && path.style.stroke.is_none())
            {
                return Err(CommandEncodeError::InvalidVectorPatch);
            }
            let mut total_anchors = 0_usize;
            let mut size: usize = 1
                + 1
                + path.style.fill.map_or(0, |_| 4)
                + 1
                + path.style.stroke.map_or(0, |_| 4)
                + 8
                + 1
                + 1
                + 8
                + 1
                + 2
                + 1;
            for subpath in &path.subpaths {
                let minimum = if subpath.closed { 3 } else { 2 };
                if subpath.anchors.len() < minimum {
                    return Err(CommandEncodeError::InvalidVectorPatch);
                }
                total_anchors = total_anchors
                    .checked_add(subpath.anchors.len())
                    .ok_or(CommandEncodeError::VectorPatchTooLarge)?;
                if total_anchors > 1_024
                    || subpath.anchors.iter().any(|anchor| {
                        [
                            anchor.x,
                            anchor.y,
                            anchor.incoming[0],
                            anchor.incoming[1],
                            anchor.outgoing[0],
                            anchor.outgoing[1],
                        ]
                        .iter()
                        .any(|value| !value.is_finite())
                    })
                {
                    return Err(CommandEncodeError::InvalidVectorPatch);
                }
                size = size
                    .checked_add(1 + 2 + subpath.anchors.len() * (6 * 8 + 1))
                    .ok_or(CommandEncodeError::VectorPatchTooLarge)?;
            }
            if let Some(source) = source {
                size = size
                    .checked_add(1 + vector_stroke_encoded_size(&source.legacy)?)
                    .ok_or(CommandEncodeError::VectorPatchTooLarge)?;
            }
            Ok(size)
        }
    }
}

fn vector_stroke_encoded_size(
    stroke: &ink_model::VectorStroke,
) -> Result<usize, CommandEncodeError> {
    if stroke.points.is_empty()
        || stroke.points.len() > 8_192
        || stroke.points.iter().any(|point| {
            !point.x.is_finite()
                || !point.y.is_finite()
                || !point.pressure.is_finite()
                || !point.tilt.is_finite()
                || !(0.0..=1.0).contains(&point.pressure)
        })
    {
        return Err(CommandEncodeError::InvalidVectorPatch);
    }
    1_usize
        .checked_add(2)
        .and_then(|header| header.checked_add(stroke.points.len().checked_mul(16)?))
        .ok_or(CommandEncodeError::VectorPatchTooLarge)
}

/// Errors returned while decoding a v1 command-journal payload.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum CommandDecodeError {
    Truncated,
    UnknownTag(u8),
    InvalidFlag(u8),
    InvalidLayerKind(u8),
    InvalidLayerBlendMode(u8),
    InvalidGroupMode(u8),
    InvalidAdjustment(u8),
    InvalidUtf8,
    StringTooLong,
    InvalidVectorPatch,
    InvalidVectorObject(u8),
    InvalidVectorStyle(u8),
    VectorPatchTooLarge,
    InvalidFloat,
    TrailingBytes,
}

impl std::fmt::Display for CommandDecodeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Truncated => f.write_str("command journal payload is truncated"),
            Self::UnknownTag(tag) => write!(f, "unknown command journal tag {tag}"),
            Self::InvalidFlag(flag) => write!(f, "invalid command journal flag {flag}"),
            Self::InvalidLayerKind(kind) => write!(f, "invalid command layer kind {kind}"),
            Self::InvalidLayerBlendMode(mode) => {
                write!(f, "invalid command layer blend mode {mode}")
            }
            Self::InvalidGroupMode(mode) => write!(f, "invalid command group mode {mode}"),
            Self::InvalidAdjustment(kind) => write!(f, "invalid adjustment kind {kind}"),
            Self::InvalidUtf8 => f.write_str("command string is not valid UTF-8"),
            Self::StringTooLong => f.write_str("command string exceeds the safety limit"),
            Self::InvalidVectorPatch => f.write_str("vector patch is malformed"),
            Self::InvalidVectorObject(kind) => {
                write!(f, "unknown vector object kind {kind}")
            }
            Self::InvalidVectorStyle(value) => {
                write!(f, "unknown vector style value {value}")
            }
            Self::VectorPatchTooLarge => f.write_str("vector patch exceeds the safety limit"),
            Self::InvalidFloat => f.write_str("command contains a non-finite float"),
            Self::TrailingBytes => f.write_str("command journal payload has trailing bytes"),
        }
    }
}

impl std::error::Error for CommandDecodeError {}

/// Errors returned when a command cannot be encoded within the journal contract.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum CommandEncodeError {
    InvalidVectorPatch,
    VectorPatchTooLarge,
}

impl std::fmt::Display for CommandEncodeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidVectorPatch => f.write_str("vector patch is malformed"),
            Self::VectorPatchTooLarge => f.write_str("vector patch exceeds the safety limit"),
        }
    }
}

impl std::error::Error for CommandEncodeError {}

/// Decode one v1 journal payload and reject malformed or future data.
#[allow(clippy::too_many_lines)]
pub fn decode_command(bytes: &[u8]) -> Result<EditorCommand, CommandDecodeError> {
    let mut cursor = 0;
    let tag = read_u8(bytes, &mut cursor)?;
    let command = match tag {
        1 => {
            let parent = read_optional_id(bytes, &mut cursor)?.map(Id::from_u128);
            let kind = decode_layer_kind(read_u8(bytes, &mut cursor)?)?;
            EditorCommand::AddLayer { parent, kind }
        }
        2 => EditorCommand::DeleteLayer {
            layer: Id::from_u128(read_id(bytes, &mut cursor)?),
        },
        37 => {
            let count = usize::from(read_u16(bytes, &mut cursor)?);
            if count == 0 || count > 4_096 {
                return Err(CommandDecodeError::TrailingBytes);
            }
            let mut layers = Vec::with_capacity(count);
            for _ in 0..count {
                layers.push(Id::from_u128(read_id(bytes, &mut cursor)?));
            }
            EditorCommand::DeleteLayers { layers }
        }
        40 => {
            let visible = match read_u8(bytes, &mut cursor)? {
                0 => false,
                1 => true,
                _ => return Err(CommandDecodeError::TrailingBytes),
            };
            let count = usize::from(read_u16(bytes, &mut cursor)?);
            if count == 0 || count > 4_096 {
                return Err(CommandDecodeError::TrailingBytes);
            }
            let mut layers = Vec::with_capacity(count);
            for _ in 0..count {
                layers.push(Id::from_u128(read_id(bytes, &mut cursor)?));
            }
            EditorCommand::SetLayersVisibility { layers, visible }
        }
        33 => EditorCommand::DuplicateLayer {
            source: Id::from_u128(read_id(bytes, &mut cursor)?),
            duplicate: Id::from_u128(read_id(bytes, &mut cursor)?),
        },
        39 => {
            let source = Id::from_u128(read_id(bytes, &mut cursor)?);
            let duplicate = Id::from_u128(read_id(bytes, &mut cursor)?);
            let count = usize::from(read_u16(bytes, &mut cursor)?);
            if count == 0 || count > 4_096 {
                return Err(CommandDecodeError::TrailingBytes);
            }
            let mut masks = Vec::with_capacity(count);
            for _ in 0..count {
                masks.push((
                    Id::from_u128(read_id(bytes, &mut cursor)?),
                    Id::from_u128(read_id(bytes, &mut cursor)?),
                ));
            }
            EditorCommand::DuplicateLayerWithMasks {
                source,
                duplicate,
                masks,
            }
        }
        34 => {
            let source = Id::from_u128(read_id(bytes, &mut cursor)?);
            let count = usize::from(read_u16(bytes, &mut cursor)?);
            if count == 0 || count > 4_096 {
                return Err(CommandDecodeError::TrailingBytes);
            }
            let mut duplicates = Vec::with_capacity(count);
            for _ in 0..count {
                duplicates.push((
                    Id::from_u128(read_id(bytes, &mut cursor)?),
                    Id::from_u128(read_id(bytes, &mut cursor)?),
                ));
            }
            EditorCommand::DuplicateLayerSubtree { source, duplicates }
        }
        45 => {
            let source_count = usize::from(read_u16(bytes, &mut cursor)?);
            if !(2..=4_096).contains(&source_count) {
                return Err(CommandDecodeError::TrailingBytes);
            }
            let mut sources = Vec::with_capacity(source_count);
            for _ in 0..source_count {
                sources.push(Id::from_u128(read_id(bytes, &mut cursor)?));
            }
            let duplicate_count = usize::from(read_u16(bytes, &mut cursor)?);
            if duplicate_count < source_count || duplicate_count > 4_096 {
                return Err(CommandDecodeError::TrailingBytes);
            }
            let mut duplicates = Vec::with_capacity(duplicate_count);
            for _ in 0..duplicate_count {
                duplicates.push((
                    Id::from_u128(read_id(bytes, &mut cursor)?),
                    Id::from_u128(read_id(bytes, &mut cursor)?),
                ));
            }
            EditorCommand::DuplicateLayers {
                sources,
                duplicates,
            }
        }
        46 => {
            let count = usize::from(read_u16(bytes, &mut cursor)?);
            if !(2..=4_096).contains(&count) {
                return Err(CommandDecodeError::TrailingBytes);
            }
            let mut layers = Vec::with_capacity(count);
            for _ in 0..count {
                layers.push(Id::from_u128(read_id(bytes, &mut cursor)?));
            }
            EditorCommand::MergeLayersBulk { layers }
        }
        36 => {
            let group = Id::from_u128(read_id(bytes, &mut cursor)?);
            let count = usize::from(read_u16(bytes, &mut cursor)?);
            if !(2..=4_096).contains(&count) {
                return Err(CommandDecodeError::TrailingBytes);
            }
            let mut members = Vec::with_capacity(count);
            for _ in 0..count {
                members.push(Id::from_u128(read_id(bytes, &mut cursor)?));
            }
            EditorCommand::GroupLayers { group, members }
        }
        38 => EditorCommand::UngroupLayer {
            group: Id::from_u128(read_id(bytes, &mut cursor)?),
        },
        29 => EditorCommand::MergeLayers {
            target: Id::from_u128(read_id(bytes, &mut cursor)?),
            source: Id::from_u128(read_id(bytes, &mut cursor)?),
        },
        3 => {
            let layer = Id::from_u128(read_id(bytes, &mut cursor)?);
            let parent = read_optional_id(bytes, &mut cursor)?.map(Id::from_u128);
            let index = read_u32(bytes, &mut cursor)?;
            EditorCommand::MoveLayer {
                layer,
                parent,
                index,
            }
        }
        30 => EditorCommand::CreatePanelLayerTree {
            panel: Id::from_u128(read_id(bytes, &mut cursor)?),
            panel_group: Id::from_u128(read_id(bytes, &mut cursor)?),
            mask: Id::from_u128(read_id(bytes, &mut cursor)?),
            sketch: Id::from_u128(read_id(bytes, &mut cursor)?),
            ink: Id::from_u128(read_id(bytes, &mut cursor)?),
            color: Id::from_u128(read_id(bytes, &mut cursor)?),
            tone: Id::from_u128(read_id(bytes, &mut cursor)?),
            effects: Id::from_u128(read_id(bytes, &mut cursor)?),
        },
        31 => {
            let mask = Id::from_u128(read_id(bytes, &mut cursor)?);
            let count = usize::from(read_u16(bytes, &mut cursor)?);
            if !(3..=64).contains(&count) {
                return Err(CommandDecodeError::TrailingBytes);
            }
            let mut points = Vec::with_capacity(count);
            for _ in 0..count {
                points.push((read_f32(bytes, &mut cursor)?, read_f32(bytes, &mut cursor)?));
            }
            EditorCommand::SetPanelMaskGeometry { mask, points }
        }
        50 => {
            let layer = Id::from_u128(read_id(bytes, &mut cursor)?);
            let border_px = read_f32(bytes, &mut cursor)?;
            let count = usize::from(read_u16(bytes, &mut cursor)?);
            if count > 256 || !(0.0..=128.0).contains(&border_px) {
                return Err(CommandDecodeError::TrailingBytes);
            }
            let mut frames = Vec::with_capacity(count);
            for _ in 0..count {
                let point_count = usize::from(read_u8(bytes, &mut cursor)?);
                if !(3..=64).contains(&point_count) {
                    return Err(CommandDecodeError::TrailingBytes);
                }
                let mut points = Vec::with_capacity(point_count);
                for _ in 0..point_count {
                    points.push((read_f32(bytes, &mut cursor)?, read_f32(bytes, &mut cursor)?));
                }
                frames.push(points);
            }
            EditorCommand::SetPanelFrames {
                layer,
                frames,
                border_px,
            }
        }
        51 => EditorCommand::ClearLayer {
            layer: Id::from_u128(read_id(bytes, &mut cursor)?),
        },
        4 => EditorCommand::SetLayerOpacity {
            layer: Id::from_u128(read_id(bytes, &mut cursor)?),
            opacity: read_u16(bytes, &mut cursor)?,
        },
        5 => EditorCommand::SetLayerVisibility {
            layer: Id::from_u128(read_id(bytes, &mut cursor)?),
            visible: read_bool(bytes, &mut cursor)?,
        },
        47 => EditorCommand::SetMaskEnabled {
            mask: Id::from_u128(read_id(bytes, &mut cursor)?),
            enabled: read_bool(bytes, &mut cursor)?,
        },
        48 => EditorCommand::SetMaskInverted {
            mask: Id::from_u128(read_id(bytes, &mut cursor)?),
            inverted: read_bool(bytes, &mut cursor)?,
        },
        49 => EditorCommand::ApplyLayerMask {
            mask: Id::from_u128(read_id(bytes, &mut cursor)?),
        },
        11 => EditorCommand::SetLayerBlendMode {
            layer: Id::from_u128(read_id(bytes, &mut cursor)?),
            mode: decode_layer_blend_mode(read_u8(bytes, &mut cursor)?)?,
        },
        35 => {
            let layer = Id::from_u128(read_id(bytes, &mut cursor)?);
            let mode = match read_u8(bytes, &mut cursor)? {
                0 => LayerGroupMode::Isolated,
                1 => LayerGroupMode::PassThrough,
                invalid => return Err(CommandDecodeError::InvalidGroupMode(invalid)),
            };
            EditorCommand::SetLayerGroupMode { layer, mode }
        }
        12 => EditorCommand::SetLayerAlphaLock {
            layer: Id::from_u128(read_id(bytes, &mut cursor)?),
            enabled: read_bool(bytes, &mut cursor)?,
        },
        41 => EditorCommand::SetLayerLocked {
            layer: Id::from_u128(read_id(bytes, &mut cursor)?),
            locked: read_bool(bytes, &mut cursor)?,
        },
        42 => {
            let locked = read_bool(bytes, &mut cursor)?;
            let count = usize::from(read_u16(bytes, &mut cursor)?);
            if count == 0 || count > 4_096 {
                return Err(CommandDecodeError::TrailingBytes);
            }
            let mut layers = Vec::with_capacity(count);
            for _ in 0..count {
                layers.push(Id::from_u128(read_id(bytes, &mut cursor)?));
            }
            EditorCommand::SetLayersLocked { layers, locked }
        }
        43 => {
            let index = read_u32(bytes, &mut cursor)?;
            let count = usize::from(read_u16(bytes, &mut cursor)?);
            if count == 0 || count > 4_096 {
                return Err(CommandDecodeError::TrailingBytes);
            }
            let mut layers = Vec::with_capacity(count);
            for _ in 0..count {
                layers.push(Id::from_u128(read_id(bytes, &mut cursor)?));
            }
            EditorCommand::ReorderLayers { layers, index }
        }
        44 => {
            let label = if read_optional_flag(bytes, &mut cursor)? {
                Some(Rgba8 {
                    r: read_u8(bytes, &mut cursor)?,
                    g: read_u8(bytes, &mut cursor)?,
                    b: read_u8(bytes, &mut cursor)?,
                    a: read_u8(bytes, &mut cursor)?,
                })
            } else {
                None
            };
            let count = usize::from(read_u16(bytes, &mut cursor)?);
            if count == 0 || count > 4_096 {
                return Err(CommandDecodeError::TrailingBytes);
            }
            let mut layers = Vec::with_capacity(count);
            for _ in 0..count {
                layers.push(Id::from_u128(read_id(bytes, &mut cursor)?));
            }
            EditorCommand::SetLayersLabel { layers, label }
        }
        13 => EditorCommand::SetLayerClipping {
            layer: Id::from_u128(read_id(bytes, &mut cursor)?),
            enabled: read_bool(bytes, &mut cursor)?,
        },
        14 => EditorCommand::SetLayerReference {
            layer: Id::from_u128(read_id(bytes, &mut cursor)?),
            enabled: read_bool(bytes, &mut cursor)?,
        },
        15 => {
            let layer = Id::from_u128(read_id(bytes, &mut cursor)?);
            let label = if read_optional_flag(bytes, &mut cursor)? {
                Some(Rgba8 {
                    r: read_u8(bytes, &mut cursor)?,
                    g: read_u8(bytes, &mut cursor)?,
                    b: read_u8(bytes, &mut cursor)?,
                    a: read_u8(bytes, &mut cursor)?,
                })
            } else {
                None
            };
            EditorCommand::SetLayerLabel { layer, label }
        }
        16 => EditorCommand::SetLayerName {
            layer: Id::from_u128(read_id(bytes, &mut cursor)?),
            name: read_string(bytes, &mut cursor)?,
        },
        32 => {
            let layer = Id::from_u128(read_id(bytes, &mut cursor)?);
            let kind = read_u8(bytes, &mut cursor)?;
            let adjustment = match kind {
                0 => LayerAdjustment::BrightnessContrast {
                    brightness: i16::from_le_bytes(read_u16(bytes, &mut cursor)?.to_le_bytes()),
                    contrast: i16::from_le_bytes(read_u16(bytes, &mut cursor)?.to_le_bytes()),
                },
                1 => LayerAdjustment::Levels {
                    input_black: read_u8(bytes, &mut cursor)?,
                    input_white: read_u8(bytes, &mut cursor)?,
                    gamma_hundredths: read_u16(bytes, &mut cursor)?,
                    output_black: read_u8(bytes, &mut cursor)?,
                    output_white: read_u8(bytes, &mut cursor)?,
                },
                2 => {
                    let mut read_curve =
                        || -> Result<ink_model::AdjustmentCurve, CommandDecodeError> {
                            let len = read_u8(bytes, &mut cursor)?;
                            let mut points = [ink_model::AdjustmentCurvePoint::default(); 16];
                            for point in &mut points {
                                point.x = read_u8(bytes, &mut cursor)?;
                                point.y = read_u8(bytes, &mut cursor)?;
                            }
                            Ok(ink_model::AdjustmentCurve { points, len })
                        };
                    LayerAdjustment::Curves {
                        master: read_curve()?,
                        red: read_curve()?,
                        green: read_curve()?,
                        blue: read_curve()?,
                    }
                }
                3 => LayerAdjustment::HueSaturation {
                    hue_degrees: i16::from_le_bytes(read_u16(bytes, &mut cursor)?.to_le_bytes()),
                    saturation: i16::from_le_bytes(read_u16(bytes, &mut cursor)?.to_le_bytes()),
                    lightness: i16::from_le_bytes(read_u16(bytes, &mut cursor)?.to_le_bytes()),
                },
                invalid => return Err(CommandDecodeError::InvalidAdjustment(invalid)),
            }
            .validate()
            .map_err(|_| CommandDecodeError::InvalidAdjustment(kind))?;
            EditorCommand::SetLayerAdjustment { layer, adjustment }
        }
        17 => EditorCommand::TransformLayer {
            layer: Id::from_u128(read_id(bytes, &mut cursor)?),
            a: read_f32(bytes, &mut cursor)?,
            b: read_f32(bytes, &mut cursor)?,
            c: read_f32(bytes, &mut cursor)?,
            d: read_f32(bytes, &mut cursor)?,
            tx: read_f32(bytes, &mut cursor)?,
            ty: read_f32(bytes, &mut cursor)?,
        },
        18 => EditorCommand::FillRegion {
            layer: Id::from_u128(read_id(bytes, &mut cursor)?),
            x: read_u32(bytes, &mut cursor)?,
            y: read_u32(bytes, &mut cursor)?,
            color: Rgba8 {
                r: read_u8(bytes, &mut cursor)?,
                g: read_u8(bytes, &mut cursor)?,
                b: read_u8(bytes, &mut cursor)?,
                a: read_u8(bytes, &mut cursor)?,
            },
            tolerance: read_u16(bytes, &mut cursor)?,
            gap: read_u32(bytes, &mut cursor)?,
        },
        28 => EditorCommand::GradientFill {
            layer: Id::from_u128(read_id(bytes, &mut cursor)?),
            x: read_u32(bytes, &mut cursor)?,
            y: read_u32(bytes, &mut cursor)?,
            start_x: read_f32(bytes, &mut cursor)?,
            start_y: read_f32(bytes, &mut cursor)?,
            end_x: read_f32(bytes, &mut cursor)?,
            end_y: read_f32(bytes, &mut cursor)?,
            from: Rgba8 {
                r: read_u8(bytes, &mut cursor)?,
                g: read_u8(bytes, &mut cursor)?,
                b: read_u8(bytes, &mut cursor)?,
                a: read_u8(bytes, &mut cursor)?,
            },
            to: Rgba8 {
                r: read_u8(bytes, &mut cursor)?,
                g: read_u8(bytes, &mut cursor)?,
                b: read_u8(bytes, &mut cursor)?,
                a: read_u8(bytes, &mut cursor)?,
            },
            tolerance: read_u16(bytes, &mut cursor)?,
            gap: read_u32(bytes, &mut cursor)?,
            expansion: read_u32(bytes, &mut cursor)?,
            paint_inside: read_bool(bytes, &mut cursor)?,
            paint_unfilled: read_bool(bytes, &mut cursor)?,
        },
        19 => {
            let layer = Id::from_u128(read_id(bytes, &mut cursor)?);
            let mut target = [(0.0, 0.0); 4];
            for point in &mut target {
                point.0 = read_f32(bytes, &mut cursor)?;
                point.1 = read_f32(bytes, &mut cursor)?;
            }
            EditorCommand::PerspectiveLayer { layer, target }
        }
        20 => {
            let layer = Id::from_u128(read_id(bytes, &mut cursor)?);
            let columns = read_u16(bytes, &mut cursor)?;
            let rows = read_u16(bytes, &mut cursor)?;
            let count = usize::from(read_u16(bytes, &mut cursor)?);
            if count > 1_024 {
                return Err(CommandDecodeError::TrailingBytes);
            }
            let mut points = Vec::with_capacity(count);
            for _ in 0..count {
                points.push((read_f32(bytes, &mut cursor)?, read_f32(bytes, &mut cursor)?));
            }
            EditorCommand::MeshLayer {
                layer,
                columns,
                rows,
                points,
            }
        }
        21 => EditorCommand::LiquifyLayer {
            layer: Id::from_u128(read_id(bytes, &mut cursor)?),
            center_x: read_f32(bytes, &mut cursor)?,
            center_y: read_f32(bytes, &mut cursor)?,
            radius: read_f32(bytes, &mut cursor)?,
            strength: read_f32(bytes, &mut cursor)?,
            direction_x: read_f32(bytes, &mut cursor)?,
            direction_y: read_f32(bytes, &mut cursor)?,
            mode: read_u8(bytes, &mut cursor)?,
        },
        22 => {
            let layer = Id::from_u128(read_id(bytes, &mut cursor)?);
            let stroke = Id::from_u128(read_id(bytes, &mut cursor)?);
            let closed = read_bool(bytes, &mut cursor)?;
            let count = usize::from(read_u16(bytes, &mut cursor)?);
            if count > 8_192 {
                return Err(CommandDecodeError::TrailingBytes);
            }
            let mut points = Vec::with_capacity(count);
            for _ in 0..count {
                points.push((
                    read_f32(bytes, &mut cursor)?,
                    read_f32(bytes, &mut cursor)?,
                    read_f32(bytes, &mut cursor)?,
                    read_f32(bytes, &mut cursor)?,
                ));
            }
            EditorCommand::AddVectorStroke {
                layer,
                stroke,
                points,
                closed,
            }
        }
        23 => EditorCommand::TransformVectorStroke {
            layer: Id::from_u128(read_id(bytes, &mut cursor)?),
            stroke: Id::from_u128(read_id(bytes, &mut cursor)?),
            a: read_f32(bytes, &mut cursor)?,
            b: read_f32(bytes, &mut cursor)?,
            c: read_f32(bytes, &mut cursor)?,
            d: read_f32(bytes, &mut cursor)?,
            tx: read_f32(bytes, &mut cursor)?,
            ty: read_f32(bytes, &mut cursor)?,
        },
        24 => EditorCommand::SimplifyVectorStroke {
            layer: Id::from_u128(read_id(bytes, &mut cursor)?),
            stroke: Id::from_u128(read_id(bytes, &mut cursor)?),
            tolerance: read_f32(bytes, &mut cursor)?,
        },
        25 => EditorCommand::ConnectVectorStrokes {
            layer: Id::from_u128(read_id(bytes, &mut cursor)?),
            first: Id::from_u128(read_id(bytes, &mut cursor)?),
            second: Id::from_u128(read_id(bytes, &mut cursor)?),
            tolerance: read_f32(bytes, &mut cursor)?,
        },
        26 => EditorCommand::EraseVectorSegment {
            layer: Id::from_u128(read_id(bytes, &mut cursor)?),
            stroke: Id::from_u128(read_id(bytes, &mut cursor)?),
            center_x: read_f32(bytes, &mut cursor)?,
            center_y: read_f32(bytes, &mut cursor)?,
            radius: read_f32(bytes, &mut cursor)?,
        },
        27 => EditorCommand::SetVectorPoint {
            layer: Id::from_u128(read_id(bytes, &mut cursor)?),
            stroke: Id::from_u128(read_id(bytes, &mut cursor)?),
            index: read_u32(bytes, &mut cursor)?,
            x: read_f32(bytes, &mut cursor)?,
            y: read_f32(bytes, &mut cursor)?,
            pressure: read_f32(bytes, &mut cursor)?,
            tilt: read_f32(bytes, &mut cursor)?,
        },
        52 => {
            if bytes.len() > MAX_VECTOR_PATCH_BYTES {
                return Err(CommandDecodeError::VectorPatchTooLarge);
            }
            let layer = Id::from_u128(read_id(bytes, &mut cursor)?);
            let semantics = read_u8(bytes, &mut cursor)?;
            if semantics != 1 {
                return Err(CommandDecodeError::InvalidVectorPatch);
            }
            let count = usize::from(read_u16(bytes, &mut cursor)?);
            if count == 0 || count > MAX_VECTOR_PATCH_EDITS {
                return Err(CommandDecodeError::InvalidVectorPatch);
            }
            let mut edits = Vec::new();
            edits
                .try_reserve(count)
                .map_err(|_| CommandDecodeError::VectorPatchTooLarge)?;
            for _ in 0..count {
                let kind = read_u8(bytes, &mut cursor)?;
                let object_id = Id::from_u128(read_id(bytes, &mut cursor)?);
                let edit = match kind {
                    0 => VectorPatchEdit::Insert {
                        object_id,
                        position: read_u32(bytes, &mut cursor)?,
                        object: read_vector_object(bytes, &mut cursor)?,
                    },
                    1 => VectorPatchEdit::Replace {
                        object_id,
                        object: read_vector_object(bytes, &mut cursor)?,
                    },
                    2 => VectorPatchEdit::Remove { object_id },
                    _ => return Err(CommandDecodeError::InvalidVectorPatch),
                };
                edits.push(edit);
            }
            EditorCommand::ApplyVectorPatch { layer, edits }
        }
        6 => EditorCommand::BeginStroke {
            stroke: Id::from_u128(read_id(bytes, &mut cursor)?),
            layer: Id::from_u128(read_id(bytes, &mut cursor)?),
            brush: Id::from_u128(read_id(bytes, &mut cursor)?),
        },
        7 => EditorCommand::EndStroke {
            stroke: Id::from_u128(read_id(bytes, &mut cursor)?),
        },
        8 => EditorCommand::CancelStroke {
            stroke: Id::from_u128(read_id(bytes, &mut cursor)?),
        },
        9 => EditorCommand::Undo,
        10 => EditorCommand::Redo,
        unknown => return Err(CommandDecodeError::UnknownTag(unknown)),
    };
    if cursor == bytes.len() {
        Ok(command)
    } else {
        Err(CommandDecodeError::TrailingBytes)
    }
}

/// Decode an ordered v1 command journal without mutating document state.
pub fn decode_journal(payloads: &[Vec<u8>]) -> Result<Vec<EditorCommand>, CommandDecodeError> {
    payloads
        .iter()
        .map(|payload| decode_command(payload))
        .collect()
}

fn read_u8(bytes: &[u8], cursor: &mut usize) -> Result<u8, CommandDecodeError> {
    let value = *bytes.get(*cursor).ok_or(CommandDecodeError::Truncated)?;
    *cursor += 1;
    Ok(value)
}

fn read_optional_flag(bytes: &[u8], cursor: &mut usize) -> Result<bool, CommandDecodeError> {
    match read_u8(bytes, cursor)? {
        0 => Ok(false),
        1 => Ok(true),
        flag => Err(CommandDecodeError::InvalidFlag(flag)),
    }
}

fn read_string(bytes: &[u8], cursor: &mut usize) -> Result<String, CommandDecodeError> {
    let length = usize::from(read_u16(bytes, cursor)?);
    if length > 1024 {
        return Err(CommandDecodeError::StringTooLong);
    }
    let end = cursor
        .checked_add(length)
        .ok_or(CommandDecodeError::Truncated)?;
    let value = bytes
        .get(*cursor..end)
        .ok_or(CommandDecodeError::Truncated)?;
    *cursor = end;
    String::from_utf8(value.to_vec()).map_err(|_| CommandDecodeError::InvalidUtf8)
}

fn read_u16(bytes: &[u8], cursor: &mut usize) -> Result<u16, CommandDecodeError> {
    let end = cursor.checked_add(2).ok_or(CommandDecodeError::Truncated)?;
    let value = bytes
        .get(*cursor..end)
        .ok_or(CommandDecodeError::Truncated)?;
    *cursor = end;
    Ok(u16::from_le_bytes([value[0], value[1]]))
}

fn read_u32(bytes: &[u8], cursor: &mut usize) -> Result<u32, CommandDecodeError> {
    let end = cursor.checked_add(4).ok_or(CommandDecodeError::Truncated)?;
    let value = bytes
        .get(*cursor..end)
        .ok_or(CommandDecodeError::Truncated)?;
    *cursor = end;
    Ok(u32::from_le_bytes(
        value.try_into().expect("slice length checked"),
    ))
}

fn read_f32(bytes: &[u8], cursor: &mut usize) -> Result<f32, CommandDecodeError> {
    let end = cursor.checked_add(4).ok_or(CommandDecodeError::Truncated)?;
    let value = bytes
        .get(*cursor..end)
        .ok_or(CommandDecodeError::Truncated)?;
    *cursor = end;
    let value = f32::from_le_bytes(value.try_into().expect("slice length checked"));
    if value.is_finite() {
        Ok(value)
    } else {
        Err(CommandDecodeError::InvalidFloat)
    }
}

fn read_f64(bytes: &[u8], cursor: &mut usize) -> Result<f64, CommandDecodeError> {
    let end = cursor.checked_add(8).ok_or(CommandDecodeError::Truncated)?;
    let value = bytes
        .get(*cursor..end)
        .ok_or(CommandDecodeError::Truncated)?;
    *cursor = end;
    let value = f64::from_le_bytes(value.try_into().expect("slice length checked"));
    if value.is_finite() {
        Ok(value)
    } else {
        Err(CommandDecodeError::InvalidFloat)
    }
}

fn read_id(bytes: &[u8], cursor: &mut usize) -> Result<u128, CommandDecodeError> {
    let end = cursor
        .checked_add(16)
        .ok_or(CommandDecodeError::Truncated)?;
    let value = bytes
        .get(*cursor..end)
        .ok_or(CommandDecodeError::Truncated)?;
    *cursor = end;
    Ok(u128::from_le_bytes(
        value.try_into().expect("slice length checked"),
    ))
}

fn read_vector_object(
    bytes: &[u8],
    cursor: &mut usize,
) -> Result<VectorObject, CommandDecodeError> {
    match read_u8(bytes, cursor)? {
        0 => Ok(VectorObject::LegacyInk {
            stroke: read_vector_stroke(bytes, cursor)?,
        }),
        1 => {
            let fill = read_optional_color(bytes, cursor)?;
            let stroke = read_optional_color(bytes, cursor)?;
            let stroke_width = read_f64(bytes, cursor)?;
            let cap = match read_u8(bytes, cursor)? {
                0 => ink_model::StrokeCap::Butt,
                1 => ink_model::StrokeCap::Square,
                2 => ink_model::StrokeCap::Round,
                value => return Err(CommandDecodeError::InvalidVectorStyle(value)),
            };
            let join = match read_u8(bytes, cursor)? {
                0 => ink_model::StrokeJoin::Miter,
                1 => ink_model::StrokeJoin::Bevel,
                2 => ink_model::StrokeJoin::Round,
                value => return Err(CommandDecodeError::InvalidVectorStyle(value)),
            };
            let miter_limit = read_f64(bytes, cursor)?;
            let fill_rule = match read_u8(bytes, cursor)? {
                0 => ink_model::FillRule::NonZero,
                1 => ink_model::FillRule::EvenOdd,
                value => return Err(CommandDecodeError::InvalidVectorStyle(value)),
            };
            let subpath_count = usize::from(read_u16(bytes, cursor)?);
            if subpath_count == 0 || subpath_count > 128 {
                return Err(CommandDecodeError::InvalidVectorPatch);
            }
            let mut subpaths = Vec::new();
            subpaths
                .try_reserve_exact(subpath_count)
                .map_err(|_| CommandDecodeError::VectorPatchTooLarge)?;
            let mut total_anchors = 0_usize;
            for _ in 0..subpath_count {
                let closed = read_bool(bytes, cursor)?;
                let anchor_count = usize::from(read_u16(bytes, cursor)?);
                let minimum = if closed { 3 } else { 2 };
                total_anchors = total_anchors
                    .checked_add(anchor_count)
                    .ok_or(CommandDecodeError::VectorPatchTooLarge)?;
                if anchor_count < minimum || total_anchors > 1_024 {
                    return Err(CommandDecodeError::InvalidVectorPatch);
                }
                let mut anchors = Vec::new();
                anchors
                    .try_reserve_exact(anchor_count)
                    .map_err(|_| CommandDecodeError::VectorPatchTooLarge)?;
                for _ in 0..anchor_count {
                    let x = read_f64(bytes, cursor)?;
                    let y = read_f64(bytes, cursor)?;
                    let incoming = [read_f64(bytes, cursor)?, read_f64(bytes, cursor)?];
                    let outgoing = [read_f64(bytes, cursor)?, read_f64(bytes, cursor)?];
                    let kind = match read_u8(bytes, cursor)? {
                        0 => ink_model::AnchorKind::Corner,
                        1 => ink_model::AnchorKind::Smooth,
                        value => return Err(CommandDecodeError::InvalidVectorStyle(value)),
                    };
                    anchors.push(ink_model::BezierAnchor {
                        x,
                        y,
                        incoming,
                        outgoing,
                        kind,
                    });
                }
                subpaths.push(ink_model::BezierSubpath { anchors, closed });
            }
            let source = match read_u8(bytes, cursor)? {
                0 => None,
                1 => Some(ink_model::VectorSourceArchive {
                    legacy: read_vector_stroke(bytes, cursor)?,
                }),
                value => return Err(CommandDecodeError::InvalidFlag(value)),
            };
            if (fill.is_none() && stroke.is_none())
                || !(0.0..=4096.0).contains(&stroke_width)
                || !(1.0..=64.0).contains(&miter_limit)
            {
                return Err(CommandDecodeError::InvalidVectorPatch);
            }
            Ok(VectorObject::BezierPath {
                path: ink_model::BezierPath {
                    subpaths,
                    style: ink_model::VectorStyle {
                        fill,
                        stroke,
                        stroke_width,
                        cap,
                        join,
                        miter_limit,
                        fill_rule,
                    },
                },
                source,
            })
        }
        value => Err(CommandDecodeError::InvalidVectorObject(value)),
    }
}

fn read_vector_stroke(
    bytes: &[u8],
    cursor: &mut usize,
) -> Result<ink_model::VectorStroke, CommandDecodeError> {
    let closed = read_bool(bytes, cursor)?;
    let point_count = usize::from(read_u16(bytes, cursor)?);
    if point_count == 0 || point_count > 8_192 {
        return Err(CommandDecodeError::InvalidVectorPatch);
    }
    let mut points = Vec::new();
    points
        .try_reserve_exact(point_count)
        .map_err(|_| CommandDecodeError::VectorPatchTooLarge)?;
    for _ in 0..point_count {
        let point = ink_model::VectorPoint {
            x: read_f32(bytes, cursor)?,
            y: read_f32(bytes, cursor)?,
            pressure: read_f32(bytes, cursor)?,
            tilt: read_f32(bytes, cursor)?,
        };
        if !(0.0..=1.0).contains(&point.pressure) {
            return Err(CommandDecodeError::InvalidVectorPatch);
        }
        points.push(point);
    }
    Ok(ink_model::VectorStroke { points, closed })
}

fn read_optional_color(
    bytes: &[u8],
    cursor: &mut usize,
) -> Result<Option<Rgba8>, CommandDecodeError> {
    match read_u8(bytes, cursor)? {
        0 => Ok(None),
        1 => {
            let end = cursor.checked_add(4).ok_or(CommandDecodeError::Truncated)?;
            let value = bytes
                .get(*cursor..end)
                .ok_or(CommandDecodeError::Truncated)?;
            *cursor = end;
            Ok(Some(Rgba8 {
                r: value[0],
                g: value[1],
                b: value[2],
                a: value[3],
            }))
        }
        value => Err(CommandDecodeError::InvalidFlag(value)),
    }
}

fn read_optional_id(bytes: &[u8], cursor: &mut usize) -> Result<Option<u128>, CommandDecodeError> {
    match read_u8(bytes, cursor)? {
        0 => Ok(None),
        1 => Ok(Some(read_id(bytes, cursor)?)),
        flag => Err(CommandDecodeError::InvalidFlag(flag)),
    }
}

fn read_bool(bytes: &[u8], cursor: &mut usize) -> Result<bool, CommandDecodeError> {
    match read_u8(bytes, cursor)? {
        0 => Ok(false),
        1 => Ok(true),
        flag => Err(CommandDecodeError::InvalidFlag(flag)),
    }
}

fn decode_layer_kind(value: u8) -> Result<LayerKind, CommandDecodeError> {
    match value {
        0 => Ok(LayerKind::Raster),
        1 => Ok(LayerKind::VectorInk),
        2 => Ok(LayerKind::Group),
        3 => Ok(LayerKind::Mask),
        4 => Ok(LayerKind::Tone),
        5 => Ok(LayerKind::PanelGroup),
        6 => Ok(LayerKind::Adjustment),
        value => Err(CommandDecodeError::InvalidLayerKind(value)),
    }
}

fn encode_layer_blend_mode(mode: LayerBlendMode) -> u8 {
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

fn decode_layer_blend_mode(value: u8) -> Result<LayerBlendMode, CommandDecodeError> {
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
        mode => Err(CommandDecodeError::InvalidLayerBlendMode(mode)),
    }
}

/// A reversible pair of state transitions. The engine owns the snapshots.
#[derive(Clone, Debug, PartialEq)]
pub struct Transaction {
    pub command: EditorCommand,
    pub label: String,
}

/// Linear undo/redo stack with a bounded history.
#[derive(Clone, Debug)]
pub struct History {
    undo: Vec<Transaction>,
    redo: Vec<Transaction>,
    capacity: usize,
}

impl History {
    /// Construct a history with a positive capacity.
    #[must_use]
    pub fn new(capacity: usize) -> Self {
        Self {
            undo: Vec::new(),
            redo: Vec::new(),
            capacity: capacity.max(1),
        }
    }
    /// Commit a new transaction and discard redo states.
    pub fn push(&mut self, transaction: Transaction) {
        self.push_undo(transaction);
        self.redo.clear();
    }

    /// Append a provisional transaction while preserving the redo branch.
    ///
    /// A stroke is provisional until `EndStroke`; a canceled stroke removes
    /// this entry with [`History::discard_last`] and must leave redo available.
    pub fn push_preserving_redo(&mut self, transaction: Transaction) {
        self.push_undo(transaction);
    }

    /// Discard the redo branch after a provisional transaction commits.
    pub fn clear_redo(&mut self) {
        self.redo.clear();
    }

    fn push_undo(&mut self, transaction: Transaction) {
        self.undo.push(transaction);
        if self.undo.len() > self.capacity {
            self.undo.remove(0);
        }
    }
    /// Move one command from undo to redo.
    pub fn undo(&mut self) -> Option<Transaction> {
        let item = self.undo.pop()?;
        self.redo.push(item.clone());
        Some(item)
    }
    /// Move one command from redo to undo.
    pub fn redo(&mut self) -> Option<Transaction> {
        let item = self.redo.pop()?;
        self.undo.push(item.clone());
        Some(item)
    }

    /// Read the currently applied transactions in chronological order.
    #[must_use]
    pub fn undo_transactions(&self) -> &[Transaction] {
        &self.undo
    }

    /// Read pending redo transactions in the order they will be reapplied.
    #[must_use]
    pub fn redo_transactions(&self) -> impl DoubleEndedIterator<Item = &Transaction> {
        self.redo.iter().rev()
    }

    /// Remove a provisional command that never committed, such as a canceled
    /// stroke, without moving it onto the redo stack.
    pub fn discard_last(&mut self) -> Option<Transaction> {
        self.undo.pop()
    }

    /// Align persisted command history with the available layer snapshots.
    /// Oldest entries are removed because stored snapshots are retained as a
    /// tail window; the redo tail is also the next operation to be reapplied.
    pub fn retain_snapshot_window(&mut self, undo_count: usize, redo_count: usize) {
        if self.undo.len() > undo_count {
            self.undo.drain(..self.undo.len() - undo_count);
        }
        if self.redo.len() > redo_count {
            self.redo.drain(..self.redo.len() - redo_count);
        }
    }
    #[must_use]
    pub fn can_undo(&self) -> bool {
        !self.undo.is_empty()
    }
    #[must_use]
    pub fn can_redo(&self) -> bool {
        !self.redo.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;
    #[test]
    fn redo_is_cleared_after_new_command() {
        let layer = LayerId::from_u128(1);
        let command = EditorCommand::SetLayerVisibility {
            layer,
            visible: false,
        };
        let mut history = History::new(2);
        history.push(Transaction {
            command: command.clone(),
            label: "hide".into(),
        });
        assert!(history.undo().is_some());
        history.push(Transaction {
            command,
            label: "hide again".into(),
        });
        assert!(!history.can_redo());
    }

    #[test]
    fn canceled_provisional_transaction_keeps_redo_available() {
        let command = EditorCommand::SetLayerVisibility {
            layer: LayerId::from_u128(1),
            visible: false,
        };
        let mut history = History::new(4);
        history.push(Transaction {
            command: command.clone(),
            label: "hide".into(),
        });
        assert!(history.undo().is_some());

        history.push_preserving_redo(Transaction {
            command: command.clone(),
            label: "provisional stroke".into(),
        });
        assert!(history.can_redo());
        assert!(history.discard_last().is_some());

        assert!(history.can_redo());
        assert_eq!(history.redo().map(|entry| entry.label), Some("hide".into()));
        assert!(!history.can_redo());
    }

    #[test]
    fn persisted_history_can_be_aligned_to_retained_snapshot_tail() {
        let layer = LayerId::from_u128(1);
        let mut history = History::new(8);
        for visible in [false, true, false, true] {
            history.push(Transaction {
                command: EditorCommand::SetLayerVisibility { layer, visible },
                label: format!("visible={visible}"),
            });
        }
        history.retain_snapshot_window(2, 0);
        assert_eq!(history.undo_transactions().len(), 2);
        assert_eq!(history.undo_transactions()[0].label, "visible=false");
        assert_eq!(history.undo_transactions()[1].label, "visible=true");
    }

    #[test]
    fn journal_encoding_is_stable() {
        let command = EditorCommand::SetLayerOpacity {
            layer: LayerId::from_u128(7),
            opacity: 1234,
        };
        assert_eq!(
            encode_command(&command),
            [4, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 210, 4]
        );
    }

    #[test]
    #[allow(clippy::too_many_lines)]
    fn journal_commands_round_trip() {
        let commands = [
            EditorCommand::AddLayer {
                parent: Some(LayerId::from_u128(2)),
                kind: LayerKind::VectorInk,
            },
            EditorCommand::DeleteLayer {
                layer: LayerId::from_u128(3),
            },
            EditorCommand::DeleteLayers {
                layers: vec![LayerId::from_u128(3), LayerId::from_u128(4)],
            },
            EditorCommand::SetLayersVisibility {
                layers: vec![LayerId::from_u128(3), LayerId::from_u128(4)],
                visible: false,
            },
            EditorCommand::SetMaskEnabled {
                mask: LayerId::from_u128(5),
                enabled: false,
            },
            EditorCommand::SetMaskInverted {
                mask: LayerId::from_u128(5),
                inverted: true,
            },
            EditorCommand::ApplyLayerMask {
                mask: LayerId::from_u128(5),
            },
            EditorCommand::SetLayerLocked {
                layer: LayerId::from_u128(8),
                locked: true,
            },
            EditorCommand::SetLayersLocked {
                layers: vec![LayerId::from_u128(8), LayerId::from_u128(9)],
                locked: false,
            },
            EditorCommand::DuplicateLayer {
                source: LayerId::from_u128(2),
                duplicate: LayerId::from_u128(3),
            },
            EditorCommand::DuplicateLayerWithMasks {
                source: LayerId::from_u128(2),
                duplicate: LayerId::from_u128(4),
                masks: vec![(LayerId::from_u128(3), LayerId::from_u128(5))],
            },
            EditorCommand::DuplicateLayerSubtree {
                source: LayerId::from_u128(2),
                duplicates: vec![
                    (LayerId::from_u128(2), LayerId::from_u128(5)),
                    (LayerId::from_u128(3), LayerId::from_u128(6)),
                ],
            },
            EditorCommand::DuplicateLayers {
                sources: vec![LayerId::from_u128(2), LayerId::from_u128(4)],
                duplicates: vec![
                    (LayerId::from_u128(2), LayerId::from_u128(10)),
                    (LayerId::from_u128(4), LayerId::from_u128(11)),
                ],
            },
            EditorCommand::GroupLayers {
                group: LayerId::from_u128(9),
                members: vec![LayerId::from_u128(2), LayerId::from_u128(3)],
            },
            EditorCommand::UngroupLayer {
                group: LayerId::from_u128(9),
            },
            EditorCommand::MergeLayers {
                target: LayerId::from_u128(2),
                source: LayerId::from_u128(3),
            },
            EditorCommand::MergeLayersBulk {
                layers: vec![LayerId::from_u128(2), LayerId::from_u128(3)],
            },
            EditorCommand::MoveLayer {
                layer: LayerId::from_u128(4),
                parent: None,
                index: 7,
            },
            EditorCommand::ReorderLayers {
                layers: vec![LayerId::from_u128(2), LayerId::from_u128(4)],
                index: 1,
            },
            EditorCommand::SetLayersLabel {
                layers: vec![LayerId::from_u128(2), LayerId::from_u128(4)],
                label: Some(Rgba8 {
                    r: 10,
                    g: 20,
                    b: 30,
                    a: 255,
                }),
            },
            EditorCommand::CreatePanelLayerTree {
                panel: LayerId::from_u128(20),
                panel_group: LayerId::from_u128(21),
                mask: LayerId::from_u128(22),
                sketch: LayerId::from_u128(23),
                ink: LayerId::from_u128(24),
                color: LayerId::from_u128(25),
                tone: LayerId::from_u128(26),
                effects: LayerId::from_u128(27),
            },
            EditorCommand::SetPanelMaskGeometry {
                mask: LayerId::from_u128(22),
                points: vec![(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)],
            },
            EditorCommand::SetPanelFrames {
                layer: LayerId::from_u128(6),
                frames: vec![vec![(0.0, 0.0), (20.0, 0.0), (20.0, 10.0), (0.0, 10.0)]],
                border_px: 2.0,
            },
            EditorCommand::ClearLayer {
                layer: LayerId::from_u128(6),
            },
            EditorCommand::SetLayerOpacity {
                layer: LayerId::from_u128(5),
                opacity: 321,
            },
            EditorCommand::SetLayerVisibility {
                layer: LayerId::from_u128(6),
                visible: false,
            },
            EditorCommand::SetLayerBlendMode {
                layer: LayerId::from_u128(6),
                mode: LayerBlendMode::Multiply,
            },
            EditorCommand::SetLayerGroupMode {
                layer: LayerId::from_u128(7),
                mode: LayerGroupMode::PassThrough,
            },
            EditorCommand::SetLayerAlphaLock {
                layer: LayerId::from_u128(6),
                enabled: true,
            },
            EditorCommand::SetLayerClipping {
                layer: LayerId::from_u128(6),
                enabled: true,
            },
            EditorCommand::SetLayerReference {
                layer: LayerId::from_u128(6),
                enabled: false,
            },
            EditorCommand::SetLayerLabel {
                layer: LayerId::from_u128(6),
                label: Some(Rgba8 {
                    r: 1,
                    g: 2,
                    b: 3,
                    a: 4,
                }),
            },
            EditorCommand::SetLayerName {
                layer: LayerId::from_u128(6),
                name: "Ink".into(),
            },
            EditorCommand::SetLayerAdjustment {
                layer: LayerId::from_u128(6),
                adjustment: LayerAdjustment::BrightnessContrast {
                    brightness: -42,
                    contrast: 73,
                },
            },
            EditorCommand::SetLayerAdjustment {
                layer: LayerId::from_u128(6),
                adjustment: LayerAdjustment::Levels {
                    input_black: 4,
                    input_white: 247,
                    gamma_hundredths: 125,
                    output_black: 3,
                    output_white: 250,
                },
            },
            EditorCommand::SetLayerAdjustment {
                layer: LayerId::from_u128(6),
                adjustment: LayerAdjustment::Curves {
                    master: ink_model::AdjustmentCurve::identity(),
                    red: ink_model::AdjustmentCurve::identity(),
                    green: ink_model::AdjustmentCurve::identity(),
                    blue: ink_model::AdjustmentCurve::identity(),
                },
            },
            EditorCommand::SetLayerAdjustment {
                layer: LayerId::from_u128(6),
                adjustment: LayerAdjustment::HueSaturation {
                    hue_degrees: -45,
                    saturation: 22,
                    lightness: -12,
                },
            },
            EditorCommand::TransformLayer {
                layer: LayerId::from_u128(6),
                a: 1.0,
                b: 0.25,
                c: -0.5,
                d: 0.75,
                tx: 12.0,
                ty: -4.0,
            },
            EditorCommand::FillRegion {
                layer: LayerId::from_u128(6),
                x: 20,
                y: 30,
                color: Rgba8 {
                    r: 10,
                    g: 20,
                    b: 30,
                    a: 255,
                },
                tolerance: 12,
                gap: 2,
            },
            EditorCommand::GradientFill {
                layer: LayerId::from_u128(6),
                x: 2,
                y: 3,
                start_x: 0.0,
                start_y: 0.0,
                end_x: 10.0,
                end_y: 12.0,
                from: Rgba8 {
                    r: 10,
                    g: 20,
                    b: 30,
                    a: 255,
                },
                to: Rgba8 {
                    r: 200,
                    g: 210,
                    b: 220,
                    a: 128,
                },
                tolerance: 16,
                gap: 1,
                expansion: 2,
                paint_inside: true,
                paint_unfilled: false,
            },
            EditorCommand::PerspectiveLayer {
                layer: LayerId::from_u128(6),
                target: [(0.0, 0.0), (10.0, 1.0), (9.0, 10.0), (1.0, 9.0)],
            },
            EditorCommand::MeshLayer {
                layer: LayerId::from_u128(6),
                columns: 2,
                rows: 2,
                points: vec![(0.0, 0.0), (10.0, 0.0), (0.0, 10.0), (10.0, 10.0)],
            },
            EditorCommand::LiquifyLayer {
                layer: LayerId::from_u128(6),
                center_x: 5.0,
                center_y: 5.0,
                radius: 10.0,
                strength: 0.5,
                mode: 0,
                direction_x: 1.0,
                direction_y: 0.0,
            },
            EditorCommand::AddVectorStroke {
                layer: LayerId::from_u128(6),
                stroke: StrokeId::from_u128(12),
                points: vec![(1.0, 2.0, 0.5, 0.0), (3.0, 4.0, 1.0, 0.25)],
                closed: false,
            },
            EditorCommand::TransformVectorStroke {
                layer: LayerId::from_u128(6),
                stroke: StrokeId::from_u128(12),
                a: 1.0,
                b: 0.0,
                c: 0.0,
                d: 1.0,
                tx: 2.0,
                ty: 3.0,
            },
            EditorCommand::SimplifyVectorStroke {
                layer: LayerId::from_u128(6),
                stroke: StrokeId::from_u128(12),
                tolerance: 0.25,
            },
            EditorCommand::ConnectVectorStrokes {
                layer: LayerId::from_u128(6),
                first: StrokeId::from_u128(12),
                second: StrokeId::from_u128(13),
                tolerance: 2.0,
            },
            EditorCommand::EraseVectorSegment {
                layer: LayerId::from_u128(6),
                stroke: StrokeId::from_u128(12),
                center_x: 4.0,
                center_y: 5.0,
                radius: 3.0,
            },
            EditorCommand::SetVectorPoint {
                layer: LayerId::from_u128(6),
                stroke: StrokeId::from_u128(12),
                index: 1,
                x: 7.0,
                y: 8.0,
                pressure: 0.75,
                tilt: -0.25,
            },
            EditorCommand::ApplyVectorPatch {
                layer: LayerId::from_u128(77),
                edits: vec![
                    VectorPatchEdit::Insert {
                        object_id: Id::from_u128(78),
                        position: 2,
                        object: VectorObject::LegacyInk {
                            stroke: ink_model::VectorStroke {
                                points: vec![ink_model::VectorPoint {
                                    x: 1.0,
                                    y: 2.0,
                                    pressure: 0.5,
                                    tilt: 0.0,
                                }],
                                closed: false,
                            },
                        },
                    },
                    VectorPatchEdit::Replace {
                        object_id: Id::from_u128(79),
                        object: VectorObject::BezierPath {
                            path: ink_model::BezierPath {
                                subpaths: vec![ink_model::BezierSubpath {
                                    anchors: vec![
                                        ink_model::BezierAnchor {
                                            x: 0.0,
                                            y: 0.0,
                                            incoming: [0.0, 0.0],
                                            outgoing: [0.0, 0.0],
                                            kind: ink_model::AnchorKind::Corner,
                                        },
                                        ink_model::BezierAnchor {
                                            x: 10.0,
                                            y: 0.0,
                                            incoming: [10.0, 0.0],
                                            outgoing: [10.0, 0.0],
                                            kind: ink_model::AnchorKind::Corner,
                                        },
                                        ink_model::BezierAnchor {
                                            x: 5.0,
                                            y: 10.0,
                                            incoming: [5.0, 10.0],
                                            outgoing: [5.0, 10.0],
                                            kind: ink_model::AnchorKind::Corner,
                                        },
                                    ],
                                    closed: true,
                                }],
                                style: ink_model::VectorStyle {
                                    fill: Some(Rgba8 {
                                        r: 10,
                                        g: 20,
                                        b: 30,
                                        a: 255,
                                    }),
                                    stroke: None,
                                    stroke_width: 0.0,
                                    cap: ink_model::StrokeCap::Round,
                                    join: ink_model::StrokeJoin::Round,
                                    miter_limit: 4.0,
                                    fill_rule: ink_model::FillRule::NonZero,
                                },
                            },
                            source: None,
                        },
                    },
                    VectorPatchEdit::Remove {
                        object_id: Id::from_u128(80),
                    },
                ],
            },
            EditorCommand::BeginStroke {
                stroke: StrokeId::from_u128(7),
                layer: LayerId::from_u128(8),
                brush: BrushId::from_u128(9),
            },
            EditorCommand::EndStroke {
                stroke: StrokeId::from_u128(10),
            },
            EditorCommand::CancelStroke {
                stroke: StrokeId::from_u128(11),
            },
            EditorCommand::Undo,
            EditorCommand::Redo,
        ];
        for command in commands {
            assert_eq!(decode_command(&encode_command(&command)), Ok(command));
        }
    }

    #[test]
    fn vector_patch_uses_versioned_little_endian_payload_and_rejects_oversize() {
        let layer = LayerId::from_u128(77);
        let make_stroke = || VectorObject::LegacyInk {
            stroke: ink_model::VectorStroke {
                points: (0..8_192)
                    .map(|_| ink_model::VectorPoint {
                        x: 0.0,
                        y: 2.0,
                        pressure: 0.5,
                        tilt: 0.0,
                    })
                    .collect(),
                closed: false,
            },
        };
        let single = EditorCommand::ApplyVectorPatch {
            layer,
            edits: vec![VectorPatchEdit::Insert {
                object_id: Id::from_u128(78),
                position: 0,
                object: make_stroke(),
            }],
        };
        let encoded = try_encode_command(&single).expect("bounded vector patch");
        let EditorCommand::ApplyVectorPatch { edits, .. } = &single else {
            unreachable!("fixture is a vector patch");
        };
        assert_eq!(vector_patch_encoded_size(edits), Ok(encoded.len()));
        assert_eq!(encoded[0], 52);
        assert_eq!(encoded[17], 1, "vector semantics version");
        assert_eq!(decode_command(&encoded), Ok(single));

        let oversized = EditorCommand::ApplyVectorPatch {
            layer,
            edits: vec![
                VectorPatchEdit::Insert {
                    object_id: Id::from_u128(79),
                    position: 0,
                    object: make_stroke(),
                },
                VectorPatchEdit::Insert {
                    object_id: Id::from_u128(80),
                    position: 1,
                    object: make_stroke(),
                },
            ],
        };
        assert_eq!(
            try_encode_command(&oversized),
            Err(CommandEncodeError::VectorPatchTooLarge)
        );
        assert!(encode_command(&oversized).is_empty());
    }

    fn generated_path(x: i16, y: i16, width: u8, alpha: u8) -> VectorObject {
        let legacy_x = f32::from(x);
        let legacy_y = f32::from(y);
        let x = f64::from(x);
        let y = f64::from(y);
        VectorObject::BezierPath {
            path: ink_model::BezierPath {
                subpaths: vec![ink_model::BezierSubpath {
                    anchors: vec![
                        ink_model::BezierAnchor {
                            x,
                            y,
                            incoming: [x, y],
                            outgoing: [x, y],
                            kind: ink_model::AnchorKind::Corner,
                        },
                        ink_model::BezierAnchor {
                            x: x + 20.0,
                            y,
                            incoming: [x + 20.0, y],
                            outgoing: [x + 20.0, y],
                            kind: ink_model::AnchorKind::Smooth,
                        },
                        ink_model::BezierAnchor {
                            x: x + 10.0,
                            y: y + 20.0,
                            incoming: [x + 10.0, y + 20.0],
                            outgoing: [x + 10.0, y + 20.0],
                            kind: ink_model::AnchorKind::Corner,
                        },
                    ],
                    closed: true,
                }],
                style: ink_model::VectorStyle {
                    fill: Some(ink_model::Rgba8 {
                        r: 17,
                        g: 63,
                        b: 201,
                        a: alpha,
                    }),
                    stroke: None,
                    stroke_width: f64::from(width),
                    cap: ink_model::StrokeCap::Round,
                    join: ink_model::StrokeJoin::Bevel,
                    miter_limit: 4.0,
                    fill_rule: ink_model::FillRule::EvenOdd,
                },
            },
            source: Some(ink_model::VectorSourceArchive {
                legacy: ink_model::VectorStroke {
                    points: vec![
                        ink_model::VectorPoint {
                            x: legacy_x,
                            y: legacy_y,
                            pressure: 0.25,
                            tilt: -0.5,
                        },
                        ink_model::VectorPoint {
                            x: legacy_x + 20.0,
                            y: legacy_y + 20.0,
                            pressure: 1.0,
                            tilt: 0.5,
                        },
                    ],
                    closed: false,
                },
            }),
        }
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(48))]

        #[test]
        fn generated_bezier_patch_round_trips_through_tag_52(
            x in -500_i16..500,
            y in -500_i16..500,
            width in 0_u8..32,
            alpha in any::<u8>(),
            insertion_position in 0_u32..128,
        ) {
            let command = EditorCommand::ApplyVectorPatch {
                layer: LayerId::from_u128(77),
                edits: vec![
                    VectorPatchEdit::Insert {
                        object_id: Id::from_u128(78),
                        position: insertion_position,
                        object: generated_path(x, y, width, alpha),
                    },
                    VectorPatchEdit::Remove {
                        object_id: Id::from_u128(79),
                    },
                ],
            };
            let encoded = try_encode_command(&command).expect("generated patch fits codec limits");
            prop_assert_eq!(encoded.first(), Some(&52));
            prop_assert_eq!(decode_command(&encoded), Ok(command));
        }
    }

    #[test]
    fn vector_patch_decoder_rejects_unknown_semantics_before_reading_edits() {
        let mut encoded = encode_command(&EditorCommand::ApplyVectorPatch {
            layer: LayerId::from_u128(77),
            edits: vec![VectorPatchEdit::Remove {
                object_id: Id::from_u128(78),
            }],
        });
        encoded[17] = 2;
        assert_eq!(
            decode_command(&encoded),
            Err(CommandDecodeError::InvalidVectorPatch)
        );
    }

    #[test]
    fn vector_patch_decoder_rejects_unknown_object_tag() {
        let mut encoded = encode_command(&EditorCommand::ApplyVectorPatch {
            layer: LayerId::from_u128(77),
            edits: vec![VectorPatchEdit::Replace {
                object_id: Id::from_u128(78),
                object: VectorObject::LegacyInk {
                    stroke: ink_model::VectorStroke {
                        points: vec![ink_model::VectorPoint {
                            x: 1.0,
                            y: 2.0,
                            pressure: 0.5,
                            tilt: 0.0,
                        }],
                        closed: false,
                    },
                },
            }],
        });
        encoded[37] = 255;
        assert_eq!(
            decode_command(&encoded),
            Err(CommandDecodeError::InvalidVectorObject(255))
        );
    }

    #[test]
    fn journal_decoder_rejects_trailing_and_invalid_data() {
        let mut encoded = encode_command(&EditorCommand::Undo);
        encoded.push(0);
        assert_eq!(
            decode_command(&encoded),
            Err(CommandDecodeError::TrailingBytes)
        );
        assert_eq!(
            decode_command(&[99]),
            Err(CommandDecodeError::UnknownTag(99))
        );
        let mut invalid_flag = vec![12];
        invalid_flag.extend_from_slice(&[0; 16]);
        invalid_flag.push(2);
        assert_eq!(
            decode_command(&invalid_flag),
            Err(CommandDecodeError::InvalidFlag(2))
        );
        let mut invalid_mode = vec![11];
        invalid_mode.extend_from_slice(&[0; 16]);
        invalid_mode.push(99);
        assert_eq!(
            decode_command(&invalid_mode),
            Err(CommandDecodeError::InvalidLayerBlendMode(99))
        );
        let mut invalid_utf8 = vec![16];
        invalid_utf8.extend_from_slice(&[0; 16]);
        invalid_utf8.extend_from_slice(&[1, 0, 0xff]);
        assert_eq!(
            decode_command(&invalid_utf8),
            Err(CommandDecodeError::InvalidUtf8)
        );

        let mut invalid_vector_edit = vec![52];
        invalid_vector_edit.extend_from_slice(&[0; 16]);
        invalid_vector_edit.push(1); // vector_semantics
        invalid_vector_edit.extend_from_slice(&1_u16.to_le_bytes());
        invalid_vector_edit.push(9);
        invalid_vector_edit.extend_from_slice(&[0; 16]);
        assert_eq!(
            decode_command(&invalid_vector_edit),
            Err(CommandDecodeError::InvalidVectorPatch)
        );
    }

    #[test]
    fn journal_decoder_preserves_order() {
        let commands = vec![EditorCommand::Undo, EditorCommand::Redo];
        let payloads = commands.iter().map(encode_command).collect::<Vec<_>>();
        assert_eq!(decode_journal(&payloads).expect("decode journal"), commands);
    }
}
