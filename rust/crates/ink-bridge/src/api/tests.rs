use super::*;
use ink_model::{ColorSpace, LayerKind, Rgba8};

#[test]
#[allow(clippy::too_many_lines)]
#[allow(clippy::float_cmp)]
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
    let acknowledgement_count = u32::from_le_bytes(updates[8..12].try_into().expect("ack count"));
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

    let captured = capture_composite_tiles_snapshot(&handle, &[0, 0, 0, 0])
        .expect("capture coherent snapshot");
    let snapshot = compose_composite_tiles_snapshot(&captured).expect("compose coherent snapshot");
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
    assert!(
        first_tile
            .as_chunks::<4>()
            .0
            .iter()
            .any(|pixel| pixel[3] != 0)
    );

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
    assert_eq!(&packet[0..2], &TILE_UPDATE_PACKET_VERSION.to_le_bytes());
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
    let mut handle = create_default_document(0xD311, 256, 256, 144.0).expect("default document");
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
    let mut handle = create_default_document(0xD312, 256, 256, 144.0).expect("default document");
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
    let mut handle = create_default_document(0xD313, 256, 256, 144.0).expect("default document");
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

    let protected = add_layer_to_parent(&mut handle, 5, group).expect("comic panel group fixture");
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
    let mut handle = create_default_document(0xAD11, 256, 256, 144.0).expect("default document");
    let group = add_layer(&mut handle, 2).expect("group layer");
    let adjustment_layer =
        add_layer_to_parent(&mut handle, 6, group).expect("group adjustment layer");
    set_layer_brightness_contrast(&mut handle, adjustment_layer, 32, -18).expect("set adjustment");
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
    let mut handle = create_default_document(0x1A9E, 256, 256, 144.0).expect("default document");
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
    let reopened = open_studio_project(root.to_string_lossy().into_owned()).expect("studio reopen");
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
    let view =
        add_project_panel(&mut handle, 0, 0x7110, 16.0, 16.0, 160.0, 160.0, 8.0).expect("panel");
    let panel = &view.pages[0].panels[0];
    let mask_id = panel.mask_layer_id.expect("mask");
    let changed = set_project_panel_bounds(&mut handle, 0, panel.id, 64.0, 64.0, 200.0, 120.0)
        .expect("resize panel");
    assert!((changed.pages[0].panels[0].x - 64.0).abs() < f32::EPSILON);
    let mask_tile = read_tile(&handle.pages[&0x7101], mask_id, 0, 0).expect("mask tile");
    let inside = (80usize * 256 + 80) * 4;
    let outside = (32usize * 256 + 32) * 4;
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
    let added =
        add_project_panel(&mut handle, 0, 0x7210, 32.0, 32.0, 180.0, 180.0, 12.0).expect("panel");
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
    let mut reopened =
        open_studio_project(root.to_string_lossy().into_owned()).expect("reopen script project");
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
#[allow(clippy::too_many_lines)]
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
    let project = create_studio_project(0x7310, 1, "Stroke page".into(), 0x7311, 2048, 2048, 144.0)
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
#[allow(clippy::too_many_lines)]
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
    let composite_svg = std::fs::read(first_export.join("page-0001.svg")).expect("composited SVG");
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
        studio_batch_export_pages(&project, first_export.to_string_lossy().into_owned()).is_err()
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
        studio_batch_export_pages(&project, blocked_export.to_string_lossy().into_owned()).is_err()
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
    let edited = comic_set_dialogue(&mut handle, 2, balloon_id, "A quiet panel follows.".into())
        .expect("dialogue edit");
    assert_eq!(edited.page_count, 8);
    let hits = comic_search_dialogue(&handle, "NEXT".into()).expect("dialogue search");
    assert_eq!(hits.len(), 31);
    let segments = comic_webtoon_segments(&handle, 0, 1024).expect("webtoon segments");
    assert_eq!(segments.len(), 2);
    let path = std::env::temp_dir().join(format!("project-ink-comic-{}.json", std::process::id()));
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
    let styled = comic_set_balloon_style(&mut handle, 3, 0x9300, "monospace".into(), 40.0, 3.0, 0)
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
    let installed = commit_staged_brush_import(&mut handle, staged.operation_id).expect("commit");
    assert!(installed > 12);

    let staged_again =
        stage_brush_import(&mut handle, path.to_string_lossy().into_owned()).expect("stage again");
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
