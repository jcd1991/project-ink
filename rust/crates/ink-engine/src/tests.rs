use super::*;
use ink_input::{DeviceKind, Phase, PointerSample};
use ink_live_render::{GpuLiveSurface, LiveSurfaceConfig};
use ink_model::{ColorSpace, DocumentSpec, Rgba8};

#[test]
fn applied_panel_frames_are_separate_layer_content_and_clear_undoably() {
    let spec = DocumentSpec {
        width_px: 64,
        height_px: 64,
        dpi: 144.0,
        color_space: ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let mut document =
        Document::new(DocumentId::from_u128(0x5041_4e45_4c46_5241), spec).expect("document");
    let layer = document.add_layer(LayerKind::Raster).expect("frame layer");

    document
        .set_panel_frames(
            layer,
            vec![vec![(8.0, 8.0), (40.0, 8.0), (40.0, 40.0), (8.0, 40.0)]],
            2.0,
        )
        .expect("apply frames");
    assert!(
        document
            .layer_has_allocated_tiles(layer)
            .expect("frame tiles")
    );
    let tile = document
        .read_tile(layer, TileCoord { x: 0, y: 0 })
        .expect("frame tile");
    let pixel = |x: usize, y: usize| tile[(y * 256 + x) * 4 + 3];
    assert!(pixel(8, 20) > 0, "frame border is stored as layer pixels");
    assert_eq!(pixel(20, 20), 0, "panel interior remains transparent");

    document
        .clear_layer_content(layer)
        .expect("clear frame layer");
    assert!(!document.layer_has_allocated_tiles(layer).expect("cleared"));
    document.dispatch(EditorCommand::Undo).expect("undo clear");
    assert!(document.layer_has_allocated_tiles(layer).expect("restored"));
}

#[test]
fn brush_projection_marks_factory_origin_without_relying_on_numeric_cutoffs() {
    let spec = DocumentSpec {
        width_px: 64,
        height_px: 64,
        dpi: 144.0,
        color_space: ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let mut document =
        Document::new(DocumentId::from_u128(0x0042_5255_5348), spec).expect("valid document");
    let custom_id = document
        .duplicate_brush(BrushId::from_u128(1))
        .expect("duplicate factory brush");
    let summaries = document.brush_summaries();
    assert!(
        summaries
            .iter()
            .find(|brush| brush.id.0 == 1)
            .expect("factory projection")
            .is_builtin
    );
    assert!(
        !summaries
            .iter()
            .find(|brush| brush.id == custom_id)
            .expect("custom projection")
            .is_builtin
    );
}

#[test]
fn brush_editor_preview_uses_rust_renderer_without_document_mutation() {
    let spec = DocumentSpec {
        width_px: 64,
        height_px: 64,
        dpi: 144.0,
        color_space: ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let document =
        Document::new(DocumentId::from_u128(0x0050_5245_5649_4557), spec).expect("document");
    let brush_id = document.brush_summaries()[0].id;
    let revision = document.revision();
    let points = [
        BrushPreviewPoint {
            x: 8.0,
            y: 24.0,
            pressure: 0.2,
        },
        BrushPreviewPoint {
            x: 28.0,
            y: 32.0,
            pressure: 0.6,
        },
        BrushPreviewPoint {
            x: 54.0,
            y: 24.0,
            pressure: 1.0,
        },
    ];

    let preview = document
        .render_brush_preview_rgba8(brush_id, 64, 64, &points)
        .expect("rendered preview");

    let samples = points
        .iter()
        .enumerate()
        .map(|(index, point)| PointerSample {
            pointer_id: 1,
            flags: flags::ACTUAL,
            device_kind: DeviceKind::Stylus,
            phase: if index == 0 {
                Phase::Down
            } else if index + 1 == points.len() {
                Phase::Up
            } else {
                Phase::Move
            },
            canvas_x: point.x,
            canvas_y: point.y,
            pressure: (point.pressure * f32::from(u16::MAX)).round() as u16,
            tilt_x: 0.0,
            tilt_y: 0.0,
            azimuth: 0.0,
            twist: 0.0,
            timestamp_ns: index as u64 * 1_000_000,
            sequence: index as u32,
        })
        .collect::<Vec<_>>();
    let preset = builtin_library()
        .into_iter()
        .find(|preset| preset.id == brush_id)
        .expect("built-in brush");
    let dabs = preset
        .compile()
        .expect("compile brush")
        .render(&samples)
        .expect("render dabs");
    let mut committed_raster = TileStore::default();
    render_brush_dabs(
        &mut committed_raster,
        &dabs,
        &BTreeMap::new(),
        None,
        false,
        false,
        false,
        64,
        64,
    );
    let committed_pixels = (0..64)
        .flat_map(|y| (0..64).map(move |x| (x, y)))
        .flat_map(|(x, y)| {
            let pixel = committed_raster.sample_pixel(x, y);
            [pixel.r, pixel.g, pixel.b, pixel.a]
        })
        .collect::<Vec<_>>();

    assert_eq!(preview.len(), 64 * 64 * 4);
    assert_eq!(preview, committed_pixels);
    assert!(preview.as_chunks::<4>().0.iter().any(|pixel| pixel[3] != 0));
    assert!(
        preview
            .as_chunks::<4>()
            .0
            .iter()
            .any(|pixel| (1..u8::MAX).contains(&pixel[3]))
    );
    assert_eq!(document.revision(), revision);
}

#[test]
fn brush_editor_draft_preview_changes_and_cancel_restores_original() {
    let spec = DocumentSpec {
        width_px: 64,
        height_px: 64,
        dpi: 144.0,
        color_space: ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let mut document =
        Document::new(DocumentId::from_u128(0x0044_5241_4654), spec).expect("document");
    let brush_id = document.brush_summaries()[0].id;
    let revision = document.revision();
    let points = [
        BrushPreviewPoint {
            x: 8.0,
            y: 24.0,
            pressure: 0.2,
        },
        BrushPreviewPoint {
            x: 28.0,
            y: 32.0,
            pressure: 0.6,
        },
        BrushPreviewPoint {
            x: 54.0,
            y: 24.0,
            pressure: 1.0,
        },
    ];
    let preview = document
        .render_brush_preview_rgba8(brush_id, 64, 64, &points)
        .expect("render preview");
    let draft_id = document.begin_brush_draft(brush_id).expect("begin draft");
    document
        .update_brush_draft(
            draft_id,
            28.0,
            0.65,
            0.2,
            0.0,
            1.0,
            0.0,
            0.5,
            0.9,
            1.0,
            0.0,
            0.0,
            0.0,
            0.0,
            &[0.0, 0.0, 1.0, 1.0],
        )
        .expect("update draft");
    let edited_preview = document
        .render_brush_preview_rgba8(brush_id, 64, 64, &points)
        .expect("render updated draft");
    assert_ne!(edited_preview, preview);
    document
        .cancel_brush_draft(draft_id)
        .expect("discard draft");
    assert_eq!(
        document
            .render_brush_preview_rgba8(brush_id, 64, 64, &points)
            .expect("render restored preview"),
        preview,
    );
    assert_eq!(document.revision(), revision);
    assert!(
        document
            .render_brush_preview_rgba8(
                brush_id,
                64,
                64,
                &[BrushPreviewPoint {
                    x: f32::NAN,
                    y: 1.0,
                    pressure: 0.5,
                }],
            )
            .is_err()
    );
}

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
fn legacy_pressure_opacity_is_not_multiplied_by_preset_opacity_twice() {
    let pencil = BrushPreset::starters()[1];
    let mut tiles = TileStore::default();
    render_dabs(
        &mut tiles,
        &[Dab {
            x: 20.0,
            y: 20.0,
            pressure: 1.0,
        }],
        pencil,
        None,
        false,
        false,
        false,
        64,
        64,
    );

    let alpha = tiles.sample_pixel(20, 20).a;
    assert!(
        (135..=145).contains(&alpha),
        "the HB preset's 0.55 opacity should be applied once, got alpha {alpha}"
    );
}

#[test]
fn original_builtin_ids_use_their_v2_pressure_profiles() {
    for brush_id in 1..=5_u128 {
        let spec = DocumentSpec {
            width_px: 64,
            height_px: 64,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        };
        let mut doc =
            Document::new(DocumentId::from_u128(brush_id + 100), spec).expect("valid document");
        let layer = doc.layers()[0].id;
        let stroke = StrokeId::from_u128(brush_id + 200);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke,
            layer,
            brush: BrushId::from_u128(brush_id),
        })
        .expect("begin built-in stroke");

        let state = lock_recover(&doc.state);
        assert!(
            state
                .active_stroke
                .as_ref()
                .expect("active stroke")
                .compiled_brush
                .is_some(),
            "built-in brush ID {brush_id} should use its V2 preset"
        );
    }
}

#[test]
fn opacity_only_builtin_brushes_project_their_pressure_curve_for_preview() {
    let spec = DocumentSpec {
        width_px: 64,
        height_px: 64,
        dpi: 144.0,
        color_space: ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let doc = Document::new(DocumentId::from_u128(106), spec).expect("valid document");
    let airbrush = doc
        .brush_summaries()
        .into_iter()
        .find(|summary| summary.id == BrushId::from_u128(4))
        .expect("Soft Airbrush summary");

    assert!(airbrush.pressure_size.abs() < f32::EPSILON);
    assert!((airbrush.pressure_opacity - 0.85).abs() < f32::EPSILON);
    assert_eq!(airbrush.pressure_curve_points.get(2), Some(&0.003));
    assert_eq!(airbrush.pressure_curve_points.get(3), Some(&0.005));
}

#[test]
#[allow(clippy::too_many_lines)]
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
    let samples = (0_u32..256)
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
    let mut doc =
        Document::new(DocumentId::from_u128(0x4441_425f_4c49_4d49), spec).expect("valid document");
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
                timestamp_ns: u64::from(index) * 1_000_000,
                sequence: index,
            }
        })
        .collect::<Vec<_>>();
    let mut state = ink_brush::CompiledBrushState::default();

    let (dabs, accepted, limited) = render_compiled_confirmed_bounded(&brush, &samples, &mut state)
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
        .chain((1..4096).map(|sequence| sample(255.0, 32_768, u64::from(sequence + 1), sequence)))
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

    let mut up = sample(255.0, 32_768, 2, 3);
    up.phase = Phase::Up;
    assert_eq!(
        compact_stationary_samples(Some(edge), vec![up], 0.0),
        vec![up]
    );
    let mut cancel = up;
    cancel.phase = Phase::Cancel;
    assert_eq!(
        compact_stationary_samples(Some(edge), vec![cancel], 0.0),
        vec![cancel]
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
    let mut up = bytes.clone();
    up[11] = Phase::Up as u8;
    doc.push_pointer_packet(&up).expect("stationary tap ends");
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
#[allow(clippy::too_many_lines)]
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
        state
            .layers
            .get_mut(&group_mask)
            .expect("group mask")
            .layer
            .mask_stencil = true;
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
    let (width, height, exported_pixels) = ink_export::decode_psd(&psd).expect("decode group PSD");
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
    let mut up = ink_test_support::one_sample(32.0, 32.0, 1.0);
    up[11] = Phase::Up as u8;
    doc.push_pointer_packet(&up).expect("stationary tap ends");
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
#[allow(clippy::too_many_lines)]
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
                        (-1..=1)
                            .any(|dy| { (-1..=1).any(|dx| covered(&committed, x + dx, y + dy)) }),
                        "brush {:?} live coverage at ({x},{y}) has no committed coverage within one pixel",
                        brush.kind,
                    );
                }
                if committed_covered {
                    assert!(
                        (-1..=1).any(|dy| { (-1..=1).any(|dx| covered(&live, x + dx, y + dy)) }),
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
fn bulk_visibility_is_atomic_and_undoable_as_one_operation() {
    let spec = DocumentSpec {
        width_px: 64,
        height_px: 64,
        dpi: 144.0,
        color_space: ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let mut doc = Document::new(DocumentId::from_u128(9_903), spec).expect("valid doc");
    let base = doc.layers()[0].id;
    let group = doc.add_layer(LayerKind::Group).expect("group");
    doc.dispatch(EditorCommand::SetLayersVisibility {
        layers: vec![base, group],
        visible: false,
    })
    .expect("hide selection");
    let hidden = doc.layers();
    assert!(
        !hidden
            .iter()
            .find(|layer| layer.id == base)
            .expect("base layer")
            .visible
    );
    assert!(
        !hidden
            .iter()
            .find(|layer| layer.id == group)
            .expect("group layer")
            .visible
    );
    doc.dispatch(EditorCommand::Undo)
        .expect("undo bulk visibility");
    let restored = doc.layers();
    assert!(
        restored
            .iter()
            .find(|layer| layer.id == base)
            .expect("base layer")
            .visible
    );
    assert!(
        restored
            .iter()
            .find(|layer| layer.id == group)
            .expect("group layer")
            .visible
    );
    doc.dispatch(EditorCommand::Redo)
        .expect("redo bulk visibility");
    let hidden_again = doc.layers();
    assert!(
        !hidden_again
            .iter()
            .find(|layer| layer.id == base)
            .expect("base layer")
            .visible
    );
    assert!(
        !hidden_again
            .iter()
            .find(|layer| layer.id == group)
            .expect("group layer")
            .visible
    );
}

#[test]
fn solo_visibility_is_temporary_and_does_not_change_history_or_saved_flags() {
    let spec = DocumentSpec {
        width_px: 64,
        height_px: 64,
        dpi: 144.0,
        color_space: ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let mut doc = Document::new(DocumentId::from_u128(9_904), spec).expect("valid doc");
    let base = doc.layers()[0].id;
    let upper = doc.add_layer(LayerKind::Raster).expect("upper paint layer");
    {
        let mut state = lock_recover(&doc.state);
        state.layers.get_mut(&base).expect("base").tiles.set_pixel(
            8,
            8,
            Rgba8 {
                r: 255,
                g: 0,
                b: 0,
                a: 255,
            },
        );
        state
            .layers
            .get_mut(&upper)
            .expect("upper")
            .tiles
            .set_pixel(
                24,
                24,
                Rgba8 {
                    r: 0,
                    g: 0,
                    b: 255,
                    a: 255,
                },
            );
    }
    let before = doc
        .read_composite_tile(TileCoord { x: 0, y: 0 })
        .expect("baseline composite");
    let history_before = doc.history_snapshot(32).expect("history before solo");
    let saved_visibility = doc
        .layers()
        .into_iter()
        .map(|layer| (layer.id, layer.visible))
        .collect::<Vec<_>>();

    doc.set_layer_solo(Some(upper)).expect("enter solo");
    let isolated = doc
        .read_composite_tile(TileCoord { x: 0, y: 0 })
        .expect("solo composite");
    assert_eq!(isolated[((8 * 256 + 8) * 4 + 3) as usize], 0);
    assert_eq!(isolated[((24 * 256 + 24) * 4 + 3) as usize], 255);
    assert_eq!(
        doc.layers()
            .into_iter()
            .map(|layer| (layer.id, layer.visible))
            .collect::<Vec<_>>(),
        saved_visibility,
        "Solo must not rewrite saved layer visibility"
    );

    doc.set_layer_solo(None).expect("exit solo");
    let restored = doc
        .read_composite_tile(TileCoord { x: 0, y: 0 })
        .expect("restored composite");
    assert_eq!(restored, before);
    let history_after = doc.history_snapshot(32).expect("history after solo");
    assert_eq!(history_after.cursor, history_before.cursor);
    assert_eq!(history_after.entries, history_before.entries);
}

#[test]
fn deleting_the_solo_target_clears_the_temporary_visibility_override() {
    let spec = DocumentSpec {
        width_px: 64,
        height_px: 64,
        dpi: 144.0,
        color_space: ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let mut doc = Document::new(DocumentId::from_u128(9_905), spec).expect("valid doc");
    let solo_target = doc.add_layer(LayerKind::Raster).expect("solo target");
    let before = doc
        .read_composite_tile(TileCoord { x: 0, y: 0 })
        .expect("baseline composite");
    doc.set_layer_solo(Some(solo_target))
        .expect("solo target layer");
    doc.delete_layer(solo_target).expect("delete solo target");
    assert_eq!(lock_recover(&doc.state).solo_layer, None);

    let composite = doc
        .read_composite_tile(TileCoord { x: 0, y: 0 })
        .expect("composite after deleting solo target");
    assert_eq!(composite, before);
}

#[test]
fn bulk_lock_is_atomic_and_undoable_as_one_operation() {
    let spec = DocumentSpec {
        width_px: 64,
        height_px: 64,
        dpi: 144.0,
        color_space: ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let mut doc = Document::new(DocumentId::from_u128(9_904), spec).expect("valid doc");
    let base = doc.layers()[0].id;
    let extra = doc.add_layer(LayerKind::Raster).expect("extra layer");
    doc.dispatch(EditorCommand::SetLayersLocked {
        layers: vec![base, extra],
        locked: true,
    })
    .expect("lock selection");
    assert!(
        doc.layers()
            .iter()
            .filter(|layer| [base, extra].contains(&layer.id))
            .all(|layer| layer.locked)
    );
    let revision = doc.revision();
    assert!(
        doc.dispatch(EditorCommand::SetLayersLocked {
            layers: vec![base, ink_model::LayerId::from_u128(0xDEAD)],
            locked: false,
        })
        .is_err()
    );
    assert_eq!(
        doc.revision(),
        revision,
        "failed bulk lock must not partially commit"
    );
    doc.dispatch(EditorCommand::Undo).expect("undo bulk lock");
    assert!(
        doc.layers()
            .iter()
            .filter(|layer| [base, extra].contains(&layer.id))
            .all(|layer| !layer.locked)
    );
}

#[test]
fn bulk_duplicate_preserves_sibling_order_and_commits_one_undo_step() {
    let spec = DocumentSpec {
        width_px: 64,
        height_px: 64,
        dpi: 144.0,
        color_space: ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let mut doc = Document::new(DocumentId::from_u128(9_906), spec).expect("valid doc");
    let bottom = doc.layers()[0].id;
    let middle = doc.add_layer(LayerKind::Raster).expect("middle layer");
    let top = doc.add_layer(LayerKind::Raster).expect("top layer");
    let mut before_layers = doc.layers();
    before_layers.sort_by_key(|layer| layer.order);
    let before = before_layers
        .into_iter()
        .map(|layer| layer.id)
        .collect::<Vec<_>>();
    let duplicates = doc
        .duplicate_layers(vec![bottom, top])
        .expect("duplicate two sibling roots");
    assert_eq!(duplicates.len(), 2);
    let mut after_layers = doc.layers();
    after_layers.sort_by_key(|layer| layer.order);
    let after = after_layers
        .into_iter()
        .map(|layer| layer.id)
        .collect::<Vec<_>>();
    assert_eq!(
        after,
        vec![bottom, duplicates[0], middle, top, duplicates[1]]
    );
    doc.dispatch(EditorCommand::Undo)
        .expect("undo bulk duplicate");
    assert_eq!(
        {
            let mut layers = doc.layers();
            layers.sort_by_key(|layer| layer.order);
            layers.into_iter().map(|layer| layer.id).collect::<Vec<_>>()
        },
        before
    );
    doc.dispatch(EditorCommand::Redo)
        .expect("redo bulk duplicate");
    assert_eq!(
        {
            let mut layers = doc.layers();
            layers.sort_by_key(|layer| layer.order);
            layers.into_iter().map(|layer| layer.id).collect::<Vec<_>>()
        },
        after
    );
}

#[test]
fn bulk_duplicate_remaps_attached_mask_ownership() {
    let spec = DocumentSpec {
        width_px: 64,
        height_px: 64,
        dpi: 144.0,
        color_space: ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let mut doc = Document::new(DocumentId::from_u128(9_907), spec).expect("valid doc");
    let first = doc.layers()[0].id;
    let second = doc.add_layer(LayerKind::Raster).expect("second layer");
    let mask = doc.add_layer(LayerKind::Mask).expect("mask layer");
    lock_recover(&doc.state)
        .layers
        .get_mut(&mask)
        .expect("mask state")
        .layer
        .mask_owner = Some(first);

    let copies = doc
        .duplicate_layers(vec![first, second])
        .expect("duplicate owner and sibling");
    let layers = doc.layers();
    let copied_mask = layers
        .iter()
        .find(|layer| layer.kind == LayerKind::Mask && layer.mask_owner == Some(copies[0]))
        .expect("mask points to copied owner");
    assert_ne!(copied_mask.id, mask);
    assert!(layers.iter().any(|layer| layer.mask_owner == Some(first)));
    doc.dispatch(EditorCommand::Undo)
        .expect("undo owner and mask duplication");
    let restored = doc.layers();
    assert!(
        copies
            .iter()
            .all(|id| restored.iter().all(|layer| layer.id != *id))
    );
    assert!(
        restored
            .iter()
            .any(|layer| layer.id == mask && layer.mask_owner == Some(first))
    );
}

#[test]
fn bulk_merge_is_atomic_and_one_undoable_operation() {
    let spec = DocumentSpec {
        width_px: 64,
        height_px: 64,
        dpi: 144.0,
        color_space: ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let mut doc = Document::new(DocumentId::from_u128(9_908), spec).expect("valid doc");
    let bottom = doc.layers()[0].id;
    let middle = doc.add_layer(LayerKind::Raster).expect("middle layer");
    let top = doc.add_layer(LayerKind::Raster).expect("top layer");
    let target = doc
        .merge_layers_bulk(vec![top, bottom, middle])
        .expect("merge contiguous selected rasters");
    assert_eq!(target, bottom);
    assert_eq!(doc.layers().len(), 1);
    doc.dispatch(EditorCommand::Undo).expect("undo bulk merge");
    assert_eq!(doc.layers().len(), 3);

    let revision = doc.revision();
    assert!(doc.merge_layers_bulk(vec![bottom, top]).is_err());
    assert_eq!(doc.revision(), revision);
    assert_eq!(doc.layers().len(), 3);
}

#[test]
fn selected_sibling_reorder_preserves_block_order_and_undoes_atomically() {
    let spec = DocumentSpec {
        width_px: 64,
        height_px: 64,
        dpi: 144.0,
        color_space: ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let mut doc = Document::new(DocumentId::from_u128(9_905), spec).expect("valid doc");
    let bottom = doc.layers()[0].id;
    let middle = doc.add_layer(LayerKind::Raster).expect("middle layer");
    let top = doc.add_layer(LayerKind::Raster).expect("top layer");

    doc.dispatch(EditorCommand::ReorderLayers {
        layers: vec![bottom, top],
        index: 1,
    })
    .expect("move selected siblings together");
    let mut reordered = doc.layers();
    reordered.sort_by_key(|layer| layer.order);
    assert_eq!(
        reordered.iter().map(|layer| layer.id).collect::<Vec<_>>(),
        [middle, bottom, top]
    );
    let revision = doc.revision();
    assert!(
        doc.dispatch(EditorCommand::ReorderLayers {
            layers: vec![bottom, ink_model::LayerId::from_u128(0xBAD)],
            index: 0,
        })
        .is_err()
    );
    assert_eq!(
        doc.revision(),
        revision,
        "invalid bulk reorder must not commit"
    );

    doc.dispatch(EditorCommand::Undo)
        .expect("undo selected reorder");
    let mut restored = doc.layers();
    restored.sort_by_key(|layer| layer.order);
    assert_eq!(
        restored.iter().map(|layer| layer.id).collect::<Vec<_>>(),
        [bottom, middle, top]
    );
}

#[test]
fn selected_layer_labels_change_atomically_and_undo_together() {
    let spec = DocumentSpec {
        width_px: 64,
        height_px: 64,
        dpi: 144.0,
        color_space: ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let mut doc = Document::new(DocumentId::from_u128(9_906), spec).expect("valid doc");
    let first = doc.layers()[0].id;
    let second = doc.add_layer(LayerKind::Raster).expect("second layer");
    let label = Rgba8 {
        r: 220,
        g: 40,
        b: 50,
        a: 255,
    };
    doc.dispatch(EditorCommand::SetLayersLabel {
        layers: vec![first, second],
        label: Some(label),
    })
    .expect("label both layers");
    assert!(
        doc.layers()
            .iter()
            .filter(|layer| [first, second].contains(&layer.id))
            .all(|layer| layer.label == Some(label))
    );

    let revision = doc.revision();
    assert!(
        doc.dispatch(EditorCommand::SetLayersLabel {
            layers: vec![first, ink_model::LayerId::from_u128(0xBAD)],
            label: None,
        })
        .is_err()
    );
    assert_eq!(
        doc.revision(),
        revision,
        "invalid bulk label must not partially commit"
    );

    doc.dispatch(EditorCommand::Undo).expect("undo bulk label");
    assert!(
        doc.layers()
            .iter()
            .filter(|layer| [first, second].contains(&layer.id))
            .all(|layer| layer.label.is_none())
    );
}

#[test]
fn layer_presentation_round_trips_through_project_storage() {
    let spec = DocumentSpec {
        width_px: 64,
        height_px: 64,
        dpi: 144.0,
        color_space: ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let mut doc =
        Document::new(DocumentId::from_u128(0x4c41_5945_525f_5254), spec).expect("valid doc");
    let layer = doc.add_layer(LayerKind::Raster).expect("add layer");
    let label = Rgba8 {
        r: 255,
        g: 51,
        b: 102,
        a: 255,
    };
    doc.dispatch(EditorCommand::SetLayerName {
        layer,
        name: "Alpha Ink Layer".into(),
    })
    .expect("rename layer");
    doc.dispatch(EditorCommand::SetLayerLabel {
        layer,
        label: Some(label),
    })
    .expect("label layer");
    doc.dispatch(EditorCommand::SetLayerVisibility {
        layer,
        visible: false,
    })
    .expect("hide layer");

    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("clock after epoch")
        .as_nanos();
    let path = std::env::temp_dir().join(format!(
        "project-ink-layer-presentation-{}-{nonce}.inkproj",
        std::process::id()
    ));
    doc.save_as(&path).expect("save layer presentation");
    let reopened = Document::open(&path).expect("reopen layer presentation");
    let persisted = reopened
        .layers()
        .into_iter()
        .find(|candidate| candidate.id == layer)
        .expect("persisted layer");
    assert_eq!(persisted.name, "Alpha Ink Layer");
    assert_eq!(persisted.label, Some(label));
    assert!(!persisted.visible);
    std::fs::remove_dir_all(path).expect("cleanup project");
}

#[test]
fn full_group_lock_blocks_descendant_edits_but_allows_visibility_and_unlock() {
    let spec = DocumentSpec {
        width_px: 64,
        height_px: 64,
        dpi: 144.0,
        color_space: ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let mut doc = Document::new(DocumentId::from_u128(9_904), spec).expect("valid doc");
    let group = doc.add_layer(LayerKind::Group).expect("group");
    let child = doc
        .add_layer_with_parent(LayerKind::Raster, Some(group))
        .expect("child");
    doc.dispatch(EditorCommand::SetLayerLocked {
        layer: group,
        locked: true,
    })
    .expect("lock group");
    let error = doc
        .dispatch(EditorCommand::SetLayerOpacity {
            layer: child,
            opacity: 12,
        })
        .expect_err("locked descendant cannot change properties");
    assert!(error.to_string().contains(&group.to_string()));
    doc.dispatch(EditorCommand::SetLayerVisibility {
        layer: child,
        visible: false,
    })
    .expect("visibility remains available on locked layer");
    doc.dispatch(EditorCommand::SetLayerLocked {
        layer: group,
        locked: false,
    })
    .expect("unlock group");
    doc.dispatch(EditorCommand::SetLayerOpacity {
        layer: child,
        opacity: 12,
    })
    .expect("unlocked descendant can be edited");
}

#[test]
fn layer_drag_capabilities_explain_inherited_locks_and_group_targets() {
    let spec = DocumentSpec {
        width_px: 64,
        height_px: 64,
        dpi: 144.0,
        color_space: ink_model::ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let mut doc = Document::new(DocumentId::from_u128(90_306), spec).expect("valid doc");
    let group = doc.add_layer(LayerKind::Group).expect("group");
    let child = doc
        .add_layer_with_parent(LayerKind::Raster, Some(group))
        .expect("child");

    let initial = doc.layer_drag_capabilities().expect("capabilities");
    let group_capability = initial
        .iter()
        .find(|capability| capability.layer_id == group)
        .expect("group capability");
    assert!(group_capability.can_drag);
    assert!(group_capability.can_receive_layers);
    let raster = initial
        .iter()
        .find(|capability| capability.layer_id == child)
        .expect("child capability");
    assert!(!raster.can_receive_layers);
    assert_eq!(
        raster.receive_reason.as_deref(),
        Some("Only ordinary groups can contain layers.")
    );

    doc.dispatch(EditorCommand::SetLayerLocked {
        layer: group,
        locked: true,
    })
    .expect("lock group");
    let locked = doc.layer_drag_capabilities().expect("locked capabilities");
    let child_capability = locked
        .iter()
        .find(|capability| capability.layer_id == child)
        .expect("locked child capability");
    assert!(!child_capability.can_drag);
    assert_eq!(
        child_capability.drag_reason.as_deref(),
        Some("Locked by Layer 2; unlock it before moving.")
    );
    let group_capability = locked
        .iter()
        .find(|capability| capability.layer_id == group)
        .expect("locked group capability");
    assert!(!group_capability.can_receive_layers);
    assert!(
        group_capability
            .receive_reason
            .as_deref()
            .is_some_and(|reason| { reason.contains("unlock it before moving layers inside") })
    );
}

#[test]
fn layer_action_capabilities_explain_lock_delete_ungroup_and_mask_rules() {
    let spec = DocumentSpec {
        width_px: 64,
        height_px: 64,
        dpi: 144.0,
        color_space: ink_model::ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let mut doc = Document::new(DocumentId::from_u128(90_307), spec).expect("valid doc");
    let base = doc.layers()[0].id;
    let other = doc.add_layer(LayerKind::Raster).expect("second layer");
    let group = doc.group_layers(vec![base, other]).expect("group siblings");

    let actions = doc
        .layer_action_capabilities()
        .expect("action capabilities");
    let group_actions = actions
        .iter()
        .find(|capability| capability.layer_id == group)
        .expect("group actions");
    assert!(group_actions.can_ungroup);
    assert!(group_actions.can_duplicate);
    assert_eq!(
        group_actions.merge_down_reason.as_deref(),
        Some("Merge is available only between raster layers.")
    );
    assert!(!group_actions.can_delete);
    assert_eq!(
        group_actions.delete_reason.as_deref(),
        Some("A document must keep at least one layer.")
    );

    let mask = doc.add_layer(LayerKind::Mask).expect("unattached mask");
    let mask_actions = doc
        .layer_action_capabilities()
        .expect("mask action capabilities")
        .into_iter()
        .find(|capability| capability.layer_id == mask)
        .expect("mask actions");
    assert!(!mask_actions.can_apply_mask);
    assert_eq!(
        mask_actions.apply_mask_reason.as_deref(),
        Some("Attach this mask to a layer before applying it.")
    );

    doc.dispatch(EditorCommand::SetLayerOpacity {
        layer: group,
        opacity: 32_768,
    })
    .expect("set group opacity");
    let modified = doc.layer_action_capabilities().expect("updated actions");
    let group_actions = modified
        .iter()
        .find(|capability| capability.layer_id == group)
        .expect("updated group actions");
    assert!(!group_actions.can_ungroup);
    assert!(
        group_actions
            .ungroup_reason
            .as_deref()
            .is_some_and(|reason| reason.contains("pass-through, Normal, 100%"))
    );

    doc.dispatch(EditorCommand::SetLayerLocked {
        layer: group,
        locked: true,
    })
    .expect("lock group");
    let locked = doc.layer_action_capabilities().expect("locked actions");
    let group_actions = locked
        .iter()
        .find(|capability| capability.layer_id == group)
        .expect("locked group actions");
    assert!(!group_actions.can_edit_properties);
    assert!(!group_actions.can_duplicate);
    assert!(!group_actions.can_delete);
    assert!(
        group_actions
            .edit_properties_reason
            .as_deref()
            .is_some_and(|reason| reason.contains("unlock it before changing properties"))
    );
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
#[allow(clippy::too_many_lines)]
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
#[allow(clippy::too_many_lines)]
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
    let mut up = confirmed.clone();
    up[11] = Phase::Up as u8;
    doc.push_pointer_packet(&up).expect("stationary tap ends");
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
    let mut doc = Document::new(DocumentId::from_u128(0x5052_4544), spec).expect("valid document");
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
    doc.flush_input()
        .expect("stationary contact reaches renderer");
    assert!(lock_recover(&doc.live_dabs).is_empty());
    doc.push_pointer_packet(&ink_test_support::one_sample(22.0, 18.0, 1.0))
        .expect("first movement confirms stroke");
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
    doc.push_pointer_packet(&ink_test_support::one_sample(22.0, 18.0, 1.0))
        .expect("first movement confirms stroke");
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
        .expect("CPU stroke begins");
    doc.push_pointer_packet(&ink_test_support::one_sample(25.0, 24.0, 1.0))
        .expect("CPU stroke remains healthy after movement");
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
    let source_mask = doc.add_layer(LayerKind::Mask).expect("attached mask");

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
    let duplicate_mask = layers
        .iter()
        .find(|layer| layer.mask_owner == Some(duplicate))
        .expect("copied mask attached to duplicate")
        .id;
    assert!(
        layers
            .iter()
            .any(|layer| { layer.id == source_mask && layer.mask_owner == Some(source) })
    );
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
    assert!(
        !doc.layers()
            .iter()
            .any(|layer| layer.id == duplicate || layer.id == duplicate_mask)
    );
    doc.dispatch(EditorCommand::Redo).expect("redo duplicate");
    assert!(
        doc.layers()
            .iter()
            .any(|layer| layer.id == duplicate && layer.kind == LayerKind::Raster)
    );
    assert!(
        doc.layers()
            .iter()
            .any(|layer| layer.id == duplicate_mask && layer.mask_owner == Some(duplicate))
    );
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
    assert!(
        reopened
            .layers()
            .iter()
            .any(|layer| layer.id == duplicate_mask && layer.mask_owner == Some(duplicate))
    );
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
#[allow(clippy::too_many_lines)]
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
fn safe_raster_merge_bakes_source_opacity_without_changing_composite_pixels() {
    let spec = DocumentSpec {
        width_px: 256,
        height_px: 256,
        dpi: 144.0,
        color_space: ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let mut doc = Document::new(DocumentId::from_u128(7_301), spec).expect("valid doc");
    let target = doc.layers()[0].id;
    let source = doc.add_layer(LayerKind::Raster).expect("source layer");
    {
        let mut state = lock_recover(&doc.state);
        state
            .layers
            .get_mut(&target)
            .expect("target")
            .tiles
            .set_pixel(
                30,
                40,
                Rgba8 {
                    r: 230,
                    g: 30,
                    b: 50,
                    a: 255,
                },
            );
        state
            .layers
            .get_mut(&source)
            .expect("source")
            .tiles
            .set_pixel(
                30,
                40,
                Rgba8 {
                    r: 20,
                    g: 100,
                    b: 240,
                    a: 190,
                },
            );
    }
    doc.dispatch(EditorCommand::SetLayerOpacity {
        layer: target,
        opacity: u16::MAX,
    })
    .expect("target opacity");
    doc.dispatch(EditorCommand::SetLayerOpacity {
        layer: source,
        opacity: 42_000,
    })
    .expect("source opacity");
    let before = doc
        .read_composite_tile(TileCoord { x: 0, y: 0 })
        .expect("composite before merge");
    let revision_before_preflight = doc.revision();
    let history_before_preflight = doc.history_snapshot(32).expect("history before preflight");
    doc.preflight_merge_layers(target, source)
        .expect("safe merge preflight");
    assert_eq!(doc.revision(), revision_before_preflight);
    let history_after_preflight = doc.history_snapshot(32).expect("history after preflight");
    assert_eq!(
        history_after_preflight.cursor,
        history_before_preflight.cursor
    );
    assert_eq!(
        history_after_preflight.entries,
        history_before_preflight.entries
    );

    doc.merge_layers(target, source).expect("safe merge");

    let after = doc
        .read_composite_tile(TileCoord { x: 0, y: 0 })
        .expect("composite after merge");
    let pixel_offset = (40 * 256 + 30) * 4;
    assert_eq!(
        &after[pixel_offset..pixel_offset + 4],
        &before[pixel_offset..pixel_offset + 4],
    );
    let merged = doc.layers().into_iter().next().expect("merged layer");
    assert_eq!(merged.id, target);
    assert_eq!(merged.opacity, u16::MAX);
}

#[test]
fn unsafe_coverage_merge_is_rejected_without_mutation() {
    let spec = DocumentSpec {
        width_px: 256,
        height_px: 256,
        dpi: 144.0,
        color_space: ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let mut doc = Document::new(DocumentId::from_u128(7_302), spec).expect("valid doc");
    let target = doc.layers()[0].id;
    let source = doc.add_layer(LayerKind::Raster).expect("source layer");
    {
        let mut state = lock_recover(&doc.state);
        state
            .layers
            .get_mut(&source)
            .expect("source")
            .tiles
            .set_pixel(
                30,
                40,
                Rgba8 {
                    r: 20,
                    g: 100,
                    b: 240,
                    a: 190,
                },
            );
    }
    let target_before = doc
        .read_tile(target, TileCoord { x: 0, y: 0 })
        .expect("target before merge");
    let source_before = doc
        .read_tile(source, TileCoord { x: 0, y: 0 })
        .expect("source before merge");
    let revision_before = doc.revision();

    assert!(matches!(
        doc.preflight_merge_layers(target, source),
        Err(EngineError::InvalidCommand(message))
            if message.contains("opaque lower-layer coverage")
    ));
    assert_eq!(doc.revision(), revision_before);
    assert!(matches!(
        doc.merge_layers(target, source),
        Err(EngineError::InvalidCommand(message))
            if message.contains("opaque lower-layer coverage")
    ));
    assert_eq!(doc.revision(), revision_before);
    assert_eq!(doc.layers().len(), 2);
    assert_eq!(
        doc.read_tile(target, TileCoord { x: 0, y: 0 })
            .expect("target unchanged"),
        target_before
    );
    assert_eq!(
        doc.read_tile(source, TileCoord { x: 0, y: 0 })
            .expect("source unchanged"),
        source_before
    );
}

#[test]
fn hidden_mask_sibling_still_blocks_merge_and_cannot_be_retargeted() {
    let spec = DocumentSpec {
        width_px: 256,
        height_px: 256,
        dpi: 144.0,
        color_space: ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let mut doc = Document::new(DocumentId::from_u128(7_303), spec).expect("valid doc");
    let target = doc.layers()[0].id;
    let source = doc.add_layer(LayerKind::Raster).expect("source layer");
    let mask = doc.add_layer(LayerKind::Mask).expect("mask layer");
    doc.dispatch(EditorCommand::SetLayerVisibility {
        layer: mask,
        visible: false,
    })
    .expect("hide mask");
    let layers_before = doc.layers();
    let revision_before = doc.revision();

    assert!(matches!(
        doc.merge_layers(target, source),
        Err(EngineError::InvalidCommand(message)) if message.contains("masks")
    ));
    assert_eq!(doc.revision(), revision_before);
    assert_eq!(doc.layers(), layers_before);
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
    let non_group = doc.layers()[0].id;
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
    assert!(matches!(
        doc.dispatch(EditorCommand::MoveLayer {
            layer: first,
            parent: Some(child),
            index: 0,
        }),
        Err(EngineError::InvalidCommand(message)) if message.contains("group")
    ));
    assert!(matches!(
        doc.dispatch(EditorCommand::MoveLayer {
            layer: child,
            parent: Some(non_group),
            index: 0,
        }),
        Err(EngineError::InvalidCommand(message)) if message.contains("group")
    ));
    assert_eq!(
        doc.layers()
            .iter()
            .find(|layer| layer.id == child)
            .map(|layer| layer.parent),
        Some(Some(second))
    );
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
fn grouping_sibling_layers_is_atomic_ordered_pass_through_and_undoable() {
    let spec = DocumentSpec {
        width_px: 64,
        height_px: 64,
        dpi: 144.0,
        color_space: ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let mut doc = Document::new(DocumentId::from_u128(42), spec).expect("valid doc");
    let bottom = doc.add_layer(LayerKind::Raster).expect("bottom layer");
    let middle = doc.add_layer(LayerKind::Raster).expect("middle layer");
    let top = doc.add_layer(LayerKind::Raster).expect("top layer");
    let before = doc.layers();

    let group = doc
        .group_layers(vec![top, bottom])
        .expect("group non-contiguous siblings");
    let layers = doc.layers();
    let group_layer = layers
        .iter()
        .find(|layer| layer.id == group)
        .expect("group projection");
    assert_eq!(group_layer.parent, None);
    assert_eq!(group_layer.kind, LayerKind::Group);
    assert_eq!(
        group_layer.group_mode,
        ink_model::LayerGroupMode::PassThrough
    );
    assert_eq!(
        layers
            .iter()
            .filter(|layer| layer.parent == Some(group))
            .map(|layer| layer.id)
            .collect::<Vec<_>>(),
        vec![bottom, top]
    );
    assert_eq!(
        layers
            .iter()
            .find(|layer| layer.id == middle)
            .map(|layer| layer.order),
        Some(1)
    );
    let grouped_state = doc.layers();
    let grouped_revision = doc.revision();
    assert!(matches!(
        doc.group_layers(vec![middle, bottom]),
        Err(EngineError::InvalidCommand(message)) if message.contains("same parent")
    ));
    assert_eq!(doc.layers(), grouped_state);
    assert_eq!(doc.revision(), grouped_revision);
    doc.dispatch(EditorCommand::Undo)
        .expect("undo grouped layers");
    assert_eq!(doc.layers(), before);
    doc.dispatch(EditorCommand::Redo)
        .expect("redo grouped layers");
    assert!(doc.layers().iter().any(|layer| layer.id == group));
}

#[test]
fn group_preflight_reports_selection_reasons_without_mutating_document() {
    let spec = DocumentSpec {
        width_px: 64,
        height_px: 64,
        dpi: 144.0,
        color_space: ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let mut doc = Document::new(DocumentId::from_u128(421), spec).expect("valid doc");
    let unrelated_owner = doc.layers()[0].id;
    let lower = doc.add_layer(LayerKind::Raster).expect("lower layer");
    let mask = doc.add_layer(LayerKind::Mask).expect("mask layer");
    let upper = doc.add_layer(LayerKind::Raster).expect("upper layer");
    {
        let mut state = lock_recover(&doc.state);
        state
            .layers
            .get_mut(&mask)
            .expect("mask state")
            .layer
            .mask_owner = Some(unrelated_owner);
    }
    let original_layers = doc.layers();
    let original_revision = doc.revision();

    assert_eq!(
        doc.preflight_group_layers(&[lower])
            .expect("single-layer preflight"),
        Some("Select at least two layers to create a group.".into())
    );
    assert_eq!(
        doc.preflight_group_layers(&[lower, upper])
            .expect("range preflight"),
        Some("Grouping this range could move a mask away from its owner.".into())
    );
    assert_eq!(
        doc.preflight_group_layers(&[lower, lower])
            .expect("duplicate-layer preflight"),
        Some("A layer can only appear once in a group selection.".into())
    );
    assert_eq!(
        doc.preflight_group_layers(&[lower, mask])
            .expect("mask-range preflight"),
        Some("Grouping this range could move a mask away from its owner.".into())
    );
    assert_eq!(doc.layers(), original_layers);
    assert_eq!(doc.revision(), original_revision);

    assert_eq!(
        doc.preflight_group_layers(&[lower, upper])
            .expect("repeat range preflight"),
        Some("Grouping this range could move a mask away from its owner.".into())
    );

    let mut valid_doc = Document::new(
        DocumentId::from_u128(422),
        DocumentSpec {
            width_px: 64,
            height_px: 64,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        },
    )
    .expect("valid document");
    let first = valid_doc.add_layer(LayerKind::Raster).expect("first layer");
    let second = valid_doc
        .add_layer(LayerKind::Raster)
        .expect("second layer");
    let before_preflight = valid_doc.layers();
    let revision_before_preflight = valid_doc.revision();
    assert_eq!(
        valid_doc
            .preflight_group_layers(&[first, second])
            .expect("valid group preflight"),
        None
    );
    assert_eq!(valid_doc.layers(), before_preflight);
    assert_eq!(valid_doc.revision(), revision_before_preflight);
    valid_doc
        .group_layers(vec![first, second])
        .expect("preflighted group commits");
}

#[test]
fn group_preflight_explains_clipping_boundary_without_mutation() {
    let mut doc = Document::new(
        DocumentId::from_u128(424),
        DocumentSpec {
            width_px: 64,
            height_px: 64,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        },
    )
    .expect("valid document");
    let first = doc.layers()[0].id;
    let second = doc.add_layer(LayerKind::Raster).expect("second layer");
    {
        let mut state = lock_recover(&doc.state);
        state
            .layers
            .get_mut(&second)
            .expect("second layer state")
            .layer
            .clipping = true;
    }
    let before = doc.layers();
    let revision = doc.revision();

    assert_eq!(
        doc.preflight_group_layers(&[first, second])
            .expect("clipping preflight"),
        Some("Grouping this range could change clipping behavior.".into())
    );
    assert_eq!(doc.layers(), before);
    assert_eq!(doc.revision(), revision);
}

#[test]
fn grouping_an_owner_carries_its_attached_mask_into_the_group() {
    let mut doc = Document::new(
        DocumentId::from_u128(423),
        DocumentSpec {
            width_px: 64,
            height_px: 64,
            dpi: 144.0,
            color_space: ColorSpace::Srgb,
            background: Rgba8::default(),
        },
    )
    .expect("valid document");
    let owner = doc.layers()[0].id;
    let mask = doc.add_layer(LayerKind::Mask).expect("attached mask");
    let other = doc.add_layer(LayerKind::Raster).expect("sibling layer");
    assert_eq!(
        doc.preflight_group_layers(&[owner, other])
            .expect("attached-mask preflight"),
        None
    );
    let before = doc.layers();

    let group = doc
        .group_layers(vec![owner, other])
        .expect("group carries its attached mask");
    let layers = doc.layers();
    assert_eq!(
        layers
            .iter()
            .find(|layer| layer.id == owner)
            .and_then(|layer| layer.parent),
        Some(group)
    );
    let mask_layer = layers
        .iter()
        .find(|layer| layer.id == mask)
        .expect("mask remains in the layer tree");
    assert_eq!(mask_layer.mask_owner, Some(owner));
    assert_eq!(mask_layer.parent, Some(group));

    doc.dispatch(EditorCommand::Undo).expect("undo grouping");
    assert_eq!(doc.layers(), before);
    doc.dispatch(EditorCommand::Redo).expect("redo grouping");
    assert_eq!(
        doc.layers()
            .iter()
            .find(|layer| layer.id == mask)
            .and_then(|layer| layer.parent),
        Some(group)
    );
}

#[test]
fn ungroup_preserves_sibling_position_and_is_one_undoable_edit() {
    let spec = DocumentSpec {
        width_px: 64,
        height_px: 64,
        dpi: 144.0,
        color_space: ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let mut doc = Document::new(DocumentId::from_u128(420), spec).expect("valid doc");
    let lower = doc.add_layer(LayerKind::Raster).expect("lower");
    let first = doc.add_layer(LayerKind::Raster).expect("first");
    let second = doc.add_layer(LayerKind::Raster).expect("second");
    let upper = doc.add_layer(LayerKind::Raster).expect("upper");
    let group = doc.group_layers(vec![first, second]).expect("group");
    let before_ungroup = doc.layers();
    doc.ungroup_layer(group).expect("safe ungroup");
    let layers = doc.layers();
    assert!(!layers.iter().any(|layer| layer.id == group));
    assert_eq!(
        layers
            .iter()
            .filter(|layer| layer.parent.is_none())
            .map(|layer| layer.id)
            .collect::<Vec<_>>(),
        vec![LayerId::from_u128(1), lower, first, second, upper]
    );
    doc.dispatch(EditorCommand::Undo).expect("undo");
    assert_eq!(doc.layers(), before_ungroup);
    doc.dispatch(EditorCommand::Redo).expect("redo");
    assert!(!doc.layers().iter().any(|layer| layer.id == group));
    let path = std::env::temp_dir().join(format!(
        "project-ink-ungroup-{}.inkproj",
        std::process::id()
    ));
    doc.save_as(&path).expect("persist ungroup");
    let mut reopened = Document::open(&path).expect("reopen persisted project");
    reopened
        .dispatch(EditorCommand::Undo)
        .expect("undo after reopen");
    assert!(reopened.layers().iter().any(|layer| layer.id == group));
    assert!(
        reopened
            .layers()
            .iter()
            .filter(|layer| layer.id == first || layer.id == second)
            .all(|layer| layer.parent == Some(group))
    );
    std::fs::remove_dir_all(path).expect("remove test project");
}

#[test]
fn ungroup_rejects_group_properties_and_masks_without_partial_changes() {
    let spec = DocumentSpec {
        width_px: 64,
        height_px: 64,
        dpi: 144.0,
        color_space: ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let mut doc = Document::new(DocumentId::from_u128(421), spec).expect("valid doc");
    let first = doc.add_layer(LayerKind::Raster).expect("first");
    let second = doc.add_layer(LayerKind::Raster).expect("second");
    let group = doc.group_layers(vec![first, second]).expect("group");
    doc.dispatch(EditorCommand::SetLayerOpacity {
        layer: group,
        opacity: u16::MAX - 1,
    })
    .expect("set non-default opacity");
    let state = doc.layers();
    let revision = doc.revision();
    assert!(
        matches!(doc.ungroup_layer(group), Err(EngineError::InvalidCommand(message)) if message.contains("100%"))
    );
    assert_eq!(doc.layers(), state);
    assert_eq!(doc.revision(), revision);

    doc.dispatch(EditorCommand::SetLayerOpacity {
        layer: group,
        opacity: u16::MAX,
    })
    .expect("restore opacity");
    let mask = doc
        .add_layer_with_parent(LayerKind::Mask, Some(group))
        .expect("child mask");
    let state = doc.layers();
    let revision = doc.revision();
    assert!(
        matches!(doc.ungroup_layer(group), Err(EngineError::InvalidCommand(message)) if message.contains("mask or clipping"))
    );
    assert!(state.iter().any(|layer| layer.id == mask));
    assert_eq!(doc.layers(), state);
    assert_eq!(doc.revision(), revision);
}

#[test]
fn deleting_selected_roots_is_atomic_normalized_and_undoable() {
    let spec = DocumentSpec {
        width_px: 64,
        height_px: 64,
        dpi: 144.0,
        color_space: ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let mut doc = Document::new(DocumentId::from_u128(43), spec).expect("valid doc");
    let preserved = doc.layers()[0].id;
    let group = doc.add_layer(LayerKind::Group).expect("ordinary group");
    let child = doc
        .add_layer_with_parent(LayerKind::Raster, Some(group))
        .expect("group child");
    let leaf = doc
        .add_layer(LayerKind::Raster)
        .expect("another selected layer");
    let before = doc.layers();

    doc.delete_layers(vec![group, child, leaf])
        .expect("delete structural roots once");
    let deleted = doc.layers();
    assert_eq!(deleted.len(), 1);
    assert_eq!(deleted[0].id, preserved);

    let revision = doc.revision();
    assert!(
        doc.delete_layers(vec![group, LayerId::from_u128(u128::MAX)])
            .is_err()
    );
    assert_eq!(doc.layers(), deleted);
    assert_eq!(doc.revision(), revision);

    doc.dispatch(EditorCommand::Undo)
        .expect("undo bulk deletion");
    assert_eq!(doc.layers(), before);
    doc.dispatch(EditorCommand::Redo)
        .expect("redo bulk deletion");
    assert_eq!(doc.layers(), deleted);
}

#[test]
fn delete_preflight_is_read_only_and_matches_lock_and_last_layer_guards() {
    let spec = DocumentSpec {
        width_px: 64,
        height_px: 64,
        dpi: 144.0,
        color_space: ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let mut doc = Document::new(DocumentId::from_u128(44), spec).expect("valid doc");
    let only = doc.layers()[0].id;
    let initial_revision = doc.revision();
    assert_eq!(
        doc.preflight_delete_layers(&[only])
            .expect("last-layer preflight"),
        Some("a document must keep at least one layer".into())
    );
    assert_eq!(doc.revision(), initial_revision);
    assert_eq!(doc.layers().len(), 1);

    let group = doc.add_layer(LayerKind::Group).expect("ordinary group");
    let child = doc
        .add_layer_with_parent(LayerKind::Raster, Some(group))
        .expect("group child");
    doc.dispatch(EditorCommand::SetLayerLocked {
        layer: group,
        locked: true,
    })
    .expect("lock group");
    let locked_revision = doc.revision();
    let locked_layers = doc.layers();
    assert_eq!(
        doc.preflight_delete_layers(&[group])
            .expect("locked preflight"),
        Some(format!(
            "layer {group} is locked by layer {group}; unlock the owning layer or group first"
        ))
    );
    assert_eq!(doc.revision(), locked_revision);
    assert_eq!(doc.layers(), locked_layers);

    doc.dispatch(EditorCommand::SetLayerLocked {
        layer: group,
        locked: false,
    })
    .expect("unlock group");
    let unlocked_revision = doc.revision();
    assert_eq!(
        doc.preflight_delete_layers(&[group, child])
            .expect("valid group subtree preflight"),
        None
    );
    assert_eq!(doc.revision(), unlocked_revision);
    assert!(doc.layers().iter().any(|layer| layer.id == group));
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
        layer_panel_state: ink_storage::LayerPanelState::default(),
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
        layer_panel_state: ink_storage::LayerPanelState::default(),
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
        layer_panel_state: ink_storage::LayerPanelState::default(),
        comic: None,
    });
    assert!(matches!(
        result,
        Err(EngineError::InvalidCommand(message))
            if message.contains("duplicate layer ID")
    ));
}

#[test]
fn recorded_stroke_renders_deterministically_on_host() {
    let render = || {
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
        let tile = Tile::from_bytes(tile).expect("complete tile");
        assert!(tile.bytes().iter().any(|byte| *byte != 0));
        tile.stable_hash()
    };

    // Factory ID 1 now renders through V2, so the old per-architecture legacy
    // raster hashes no longer describe this recorded stroke. Keep a replay
    // determinism check while pressure geometry has dedicated engine tests.
    assert_eq!(render(), render());
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
#[allow(clippy::too_many_lines)]
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
        pixels[(y * 256 + 128) * 4 + 3] != 0
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
                timestamp_ns: u64::try_from(index).expect("sample index fits u64") * 1_000_000,
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
    assert_eq!(tile.pixel_rgba(8, 8).a, 255);
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
fn mask_owner_survives_sibling_reorder_and_owner_reparenting() {
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
    let unrelated = doc.add_layer(LayerKind::Raster).expect("unrelated layer");
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
    assert_eq!(
        doc.layers()
            .iter()
            .find(|layer| layer.id == mask)
            .and_then(|layer| layer.mask_owner),
        Some(base)
    );
    doc.dispatch(EditorCommand::MoveLayer {
        layer: mask,
        parent: None,
        index: 2,
    })
    .expect("reorder attached mask");
    let group = doc.add_layer(LayerKind::Group).expect("group");
    assert!(
        doc.dispatch(EditorCommand::MoveLayer {
            layer: mask,
            parent: Some(group),
            index: 0,
        })
        .is_err()
    );
    doc.dispatch(EditorCommand::MoveLayer {
        layer: base,
        parent: Some(group),
        index: 0,
    })
    .expect("move masked owner and mask into group");
    let layers = doc.layers();
    assert_eq!(
        layers
            .iter()
            .find(|layer| layer.id == mask)
            .and_then(|layer| layer.mask_owner),
        Some(base)
    );
    assert_eq!(
        layers
            .iter()
            .find(|layer| layer.id == mask)
            .and_then(|layer| layer.parent),
        Some(group)
    );
    assert!(layers.iter().any(|layer| layer.id == unrelated));
    let tile = Tile::from_bytes(
        doc.read_tile(base, TileCoord { x: 0, y: 0 })
            .expect("masked base tile"),
    )
    .expect("valid masked base tile");
    assert!(
        tile.pixel_rgba(8, 8).a < 255,
        "black mask paint should reduce owner coverage"
    );
    assert_ne!(
        tile.pixel_rgba(48, 48).a,
        0,
        "untouched sparse mask pixels should reveal by default"
    );
    let mask_tile = Tile::from_bytes(
        doc.read_tile(mask, TileCoord { x: 0, y: 0 })
            .expect("mask tile"),
    )
    .expect("valid mask tile");
    assert_ne!(mask_tile.pixel_rgba(8, 8).a, 0);
}

#[test]
fn new_sparse_mask_reveals_by_default_and_inverts_coverage_without_tile_expansion() {
    let spec = DocumentSpec {
        width_px: 64,
        height_px: 64,
        dpi: 144.0,
        color_space: ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let mut doc = Document::new(DocumentId::from_u128(0x5a51), spec).expect("document");
    let owner = doc.layers()[0].id;
    let color = Rgba8 {
        r: 70,
        g: 80,
        b: 90,
        a: 255,
    };
    doc.fill_region(owner, 0, 0, color, 0, 0)
        .expect("fill owner");
    let mask = doc.add_layer(LayerKind::Mask).expect("new attached mask");
    let default_reveal = doc
        .read_tile(owner, TileCoord { x: 0, y: 0 })
        .expect("default reveal");
    assert_eq!(default_reveal[(5 * 256 + 4) * 4 + 3], 255);

    {
        let mut state = lock_recover(&doc.state);
        state
            .layers
            .get_mut(&mask)
            .expect("mask state")
            .tiles
            .set_pixel(
                4,
                5,
                Rgba8 {
                    r: 0,
                    g: 0,
                    b: 0,
                    a: 255,
                },
            );
    }
    let masked = doc
        .read_tile(owner, TileCoord { x: 0, y: 0 })
        .expect("hidden pixel");
    assert_eq!(&masked[((5 * 256 + 4) * 4) as usize..][..4], &[0, 0, 0, 0]);
    assert_eq!(
        masked,
        doc.read_composite_tile(TileCoord { x: 0, y: 0 })
            .expect("masked export composite")
    );
    assert_ne!(
        &masked[..4],
        &[0, 0, 0, 0],
        "sparse default remains revealed"
    );

    doc.dispatch(EditorCommand::SetMaskInverted {
        mask,
        inverted: true,
    })
    .expect("invert mask");
    let inverted = doc
        .read_tile(owner, TileCoord { x: 0, y: 0 })
        .expect("inverted mask");
    assert_ne!(
        &inverted[((5 * 256 + 4) * 4) as usize..][..4],
        &[0, 0, 0, 0]
    );
    assert_eq!(&inverted[..4], &[0, 0, 0, 0]);
    assert_eq!(
        inverted,
        doc.read_composite_tile(TileCoord { x: 0, y: 0 })
            .expect("inverted export composite")
    );

    doc.dispatch(EditorCommand::Undo).expect("undo inversion");
    let restored = doc
        .read_tile(owner, TileCoord { x: 0, y: 0 })
        .expect("undo inversion tile");
    assert_ne!(&restored[..4], &[0, 0, 0, 0]);
    assert_eq!(
        &restored[((5 * 256 + 4) * 4) as usize..][..4],
        &[0, 0, 0, 0]
    );
    doc.dispatch(EditorCommand::SetMaskEnabled {
        mask,
        enabled: false,
    })
    .expect("disable mask");
    assert_ne!(
        &doc.read_tile(owner, TileCoord { x: 0, y: 0 })
            .expect("disabled mask tile")[..4],
        &[0, 0, 0, 0]
    );
}

#[test]
fn white_mask_brush_reveals_pixels_hidden_by_black_brush() {
    let spec = DocumentSpec {
        width_px: 64,
        height_px: 64,
        dpi: 144.0,
        color_space: ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let mut doc = Document::new(DocumentId::from_u128(0x5a52), spec).expect("document");
    let owner = doc.layers()[0].id;
    doc.fill_region(
        owner,
        0,
        0,
        Rgba8 {
            r: 70,
            g: 80,
            b: 90,
            a: 255,
        },
        0,
        0,
    )
    .expect("fill owner");
    let mask = doc.add_layer(LayerKind::Mask).expect("new mask");
    let brush = BrushPreset::starters()[0].id;
    doc.update_brush_color(
        brush,
        Rgba8 {
            r: 0,
            g: 0,
            b: 0,
            a: 255,
        },
    )
    .expect("choose black mask color");
    let paint = |doc: &mut Document, stroke_id: u128| {
        let stroke = ink_model::StrokeId::from_u128(stroke_id);
        doc.dispatch(EditorCommand::BeginStroke {
            stroke,
            layer: mask,
            brush,
        })
        .expect("begin mask stroke");
        doc.push_pointer_packet(&ink_test_support::one_sample(16.0, 16.0, 1.0))
            .expect("mask dab");
        doc.dispatch(EditorCommand::EndStroke { stroke })
            .expect("commit mask stroke");
    };
    paint(&mut doc, 0x5a53);
    let hidden = Tile::from_bytes(
        doc.read_tile(owner, TileCoord { x: 0, y: 0 })
            .expect("black mask composite"),
    )
    .expect("valid hidden tile")
    .pixel_rgba(16, 16)
    .a;
    assert!(
        hidden < 255,
        "black mask brush should hide part of the owner"
    );

    doc.update_brush_color(
        brush,
        Rgba8 {
            r: 255,
            g: 255,
            b: 255,
            a: 255,
        },
    )
    .expect("choose white mask color");
    paint(&mut doc, 0x5a54);
    let revealed = Tile::from_bytes(
        doc.read_tile(owner, TileCoord { x: 0, y: 0 })
            .expect("white mask composite"),
    )
    .expect("valid revealed tile")
    .pixel_rgba(16, 16)
    .a;
    assert!(
        revealed > hidden,
        "white mask brush should reveal prior coverage"
    );
}

#[test]
fn applying_raster_mask_bakes_coverage_and_undo_restores_attachment() {
    let spec = DocumentSpec {
        width_px: 64,
        height_px: 64,
        dpi: 144.0,
        color_space: ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let mut doc = Document::new(DocumentId::from_u128(0x5a55), spec).expect("document");
    let owner = doc.layers()[0].id;
    doc.fill_region(
        owner,
        0,
        0,
        Rgba8 {
            r: 70,
            g: 80,
            b: 90,
            a: 255,
        },
        0,
        0,
    )
    .expect("fill owner");
    let mask = doc.add_layer(LayerKind::Mask).expect("new mask");
    lock_recover(&doc.state)
        .layers
        .get_mut(&mask)
        .expect("mask state")
        .tiles
        .set_pixel(
            4,
            5,
            Rgba8 {
                r: 0,
                g: 0,
                b: 0,
                a: 255,
            },
        );
    let before_apply = doc
        .read_tile(owner, TileCoord { x: 0, y: 0 })
        .expect("masked owner");
    let history_before = doc.history_snapshot(50).expect("history").cursor;
    doc.dispatch(EditorCommand::ApplyLayerMask { mask })
        .expect("apply mask");
    assert_eq!(
        doc.history_snapshot(50).expect("applied history").cursor,
        history_before + 1
    );
    assert!(!doc.layers().iter().any(|layer| layer.id == mask));
    assert_eq!(
        doc.read_tile(owner, TileCoord { x: 0, y: 0 })
            .expect("baked owner"),
        before_apply,
        "apply preserves the rendered pixels"
    );
    doc.dispatch(EditorCommand::Undo).expect("undo apply");
    assert!(doc.layers().iter().any(|layer| layer.id == mask));
    assert_eq!(
        doc.read_tile(owner, TileCoord { x: 0, y: 0 })
            .expect("restored source"),
        before_apply,
        "undo restores the attached mask and its visual effect"
    );
}

#[test]
fn applying_disabled_mask_removes_it_without_changing_owner_pixels() {
    let spec = DocumentSpec {
        width_px: 64,
        height_px: 64,
        dpi: 144.0,
        color_space: ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let mut doc = Document::new(DocumentId::from_u128(0x5a56), spec).expect("document");
    let owner = doc.layers()[0].id;
    doc.fill_region(
        owner,
        0,
        0,
        Rgba8 {
            r: 70,
            g: 80,
            b: 90,
            a: 255,
        },
        0,
        0,
    )
    .expect("fill owner");
    let original_owner = doc
        .read_tile(owner, TileCoord { x: 0, y: 0 })
        .expect("unmasked owner");
    let mask = doc.add_layer(LayerKind::Mask).expect("new mask");
    lock_recover(&doc.state)
        .layers
        .get_mut(&mask)
        .expect("mask state")
        .tiles
        .set_pixel(
            4,
            5,
            Rgba8 {
                r: 0,
                g: 0,
                b: 0,
                a: 255,
            },
        );
    doc.dispatch(EditorCommand::SetMaskEnabled {
        mask,
        enabled: false,
    })
    .expect("disable mask");
    doc.dispatch(EditorCommand::ApplyLayerMask { mask })
        .expect("apply disabled mask");
    assert_eq!(
        doc.read_tile(owner, TileCoord { x: 0, y: 0 })
            .expect("owner after applying disabled mask"),
        original_owner
    );
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
fn layer_opacity_preview_commits_once_and_cancel_restores_pixels_state() {
    let spec = DocumentSpec {
        width_px: 64,
        height_px: 64,
        dpi: 144.0,
        color_space: ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let mut doc = Document::new(DocumentId::from_u128(0x5a57), spec).expect("document");
    let layer = doc.layers()[0].id;
    let original = doc.layers()[0].opacity;
    let cursor_before = doc.history_snapshot(50).expect("history before").cursor;
    let edit = doc
        .begin_layer_opacity_edit(layer)
        .expect("begin opacity edit");
    doc.update_layer_opacity_edit(edit, u16::MAX / 2)
        .expect("preview opacity");
    doc.update_layer_opacity_edit(edit, u16::MAX / 3)
        .expect("update opacity preview");
    assert_eq!(doc.layers()[0].opacity, u16::MAX / 3);
    assert_eq!(
        doc.history_snapshot(50).expect("preview history").cursor,
        cursor_before,
        "preview frames do not create undo entries"
    );

    doc.commit_layer_opacity_edit(edit)
        .expect("commit opacity edit");
    assert_eq!(
        doc.history_snapshot(50).expect("committed history").cursor,
        cursor_before + 1
    );
    doc.dispatch(EditorCommand::Undo)
        .expect("undo opacity edit");
    assert_eq!(doc.layers()[0].opacity, original);
    doc.dispatch(EditorCommand::Redo)
        .expect("redo opacity edit");
    assert_eq!(doc.layers()[0].opacity, u16::MAX / 3);

    let cursor_before_cancel = doc.history_snapshot(50).expect("history").cursor;
    let canceled = doc
        .begin_layer_opacity_edit(layer)
        .expect("begin second opacity edit");
    doc.update_layer_opacity_edit(canceled, 0)
        .expect("preview zero opacity");
    doc.cancel_layer_opacity_edit(canceled)
        .expect("cancel opacity edit");
    assert_eq!(doc.layers()[0].opacity, u16::MAX / 3);
    assert_eq!(
        doc.history_snapshot(50).expect("canceled history").cursor,
        cursor_before_cancel,
        "canceled preview does not alter history"
    );

    let cursor_before_save = doc.history_snapshot(50).expect("history").cursor;
    let save_edit = doc
        .begin_layer_opacity_edit(layer)
        .expect("begin saved opacity edit");
    doc.update_layer_opacity_edit(save_edit, u16::MAX / 4)
        .expect("preview saved opacity");
    let snapshot = doc.snapshot();
    assert_eq!(
        snapshot
            .layers
            .iter()
            .find(|candidate| candidate.id == layer)
            .expect("saved layer")
            .opacity,
        u16::MAX / 4,
        "snapshot closes the temporary edit with its final value"
    );
    assert_eq!(
        doc.history_snapshot(50).expect("saved history").cursor,
        cursor_before_save + 1,
        "saving during an active preview commits one undo step"
    );
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
#[allow(clippy::too_many_lines)]
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
    let root = std::env::temp_dir().join(format!("project-ink-brush-save-{}", std::process::id()));
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
    assert_eq!(
        renamed.diameter_px.to_bits(),
        before_rename.diameter_px.to_bits()
    );
    assert_eq!(renamed.opacity.to_bits(), before_rename.opacity.to_bits());
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
#[allow(clippy::too_many_lines)]
fn edited_brush_export_import_changes_stroke_and_survives_reopen() {
    let spec = DocumentSpec {
        width_px: 256,
        height_px: 256,
        dpi: 144.0,
        color_space: ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let mut source = Document::new(DocumentId::from_u128(50_201), spec).expect("source document");
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

    let mut target = Document::new(DocumentId::from_u128(50_202), spec).expect("target document");
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
#[allow(clippy::too_many_lines)]
fn phase_two_sketch_ink_color_vector_and_export_workflow() {
    let spec = DocumentSpec {
        width_px: 128,
        height_px: 128,
        dpi: 144.0,
        color_space: ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let mut doc = Document::new(DocumentId::from_u128(0x5048_4153_4532), spec).expect("document");
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
    let mut up = ink_test_support::one_sample(10.0, 10.0, 1.0);
    up[11] = Phase::Up as u8;
    doc.push_pointer_packet(&up).expect("stationary tap ends");
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
fn layer_panel_state_is_validated_not_undoable_and_persisted_per_page() {
    let spec = DocumentSpec {
        width_px: 64,
        height_px: 64,
        dpi: 144.0,
        color_space: ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let mut doc = Document::new(DocumentId::from_u128(9_906), spec).expect("valid doc");
    let paint = doc.layers()[0].id;
    let group = doc.add_layer(LayerKind::Group).expect("group");
    let history_before = doc
        .history_snapshot(32)
        .expect("history before panel state");
    let revision_before = doc.revision();

    assert!(
        doc.set_layer_panel_state(Some(LayerId::from_u128(999)), vec![])
            .is_err()
    );
    assert!(doc.set_layer_panel_state(Some(paint), vec![paint]).is_err());
    assert_eq!(doc.revision(), revision_before);
    assert_eq!(doc.layer_panel_state(), LayerPanelState::default());

    doc.set_layer_panel_state(Some(paint), vec![group])
        .expect("persist valid panel state");
    let expected = LayerPanelState {
        primary_layer: Some(paint),
        collapsed_groups: vec![group],
    };
    assert_eq!(doc.layer_panel_state(), expected);
    let history_after = doc.history_snapshot(32).expect("history after panel state");
    assert_eq!(history_after.cursor, history_before.cursor);
    assert_eq!(history_after.entries, history_before.entries);

    let path = std::env::temp_dir().join(format!(
        "project-ink-layer-panel-state-{}.inkproj",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&path);
    doc.save_as(&path).expect("save panel state");
    let reopened = Document::open(&path).expect("reopen panel state");
    assert_eq!(reopened.layer_panel_state(), expected);
    std::fs::remove_dir_all(path).expect("cleanup");
}

#[test]
fn grouped_layer_locks_masks_and_clipping_survive_undo_save_and_reopen() {
    let spec = DocumentSpec {
        width_px: 64,
        height_px: 64,
        dpi: 144.0,
        color_space: ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let mut doc = Document::new(DocumentId::from_u128(9_907), spec).expect("valid doc");
    let group = doc.add_layer(LayerKind::Group).expect("group");
    let paint = doc
        .add_layer_with_parent(LayerKind::Raster, Some(group))
        .expect("paint child");
    let clipped = doc
        .add_layer_with_parent(LayerKind::Raster, Some(group))
        .expect("clipped child");
    let mask = doc
        .add_layer_with_parent(LayerKind::Mask, Some(group))
        .expect("group mask");
    let find_layer = |layers: &[ink_model::Layer], id| {
        layers
            .iter()
            .find(|layer| layer.id == id)
            .cloned()
            .expect("expected layer")
    };

    assert_eq!(find_layer(&doc.layers(), mask).mask_owner, Some(group));
    doc.dispatch(EditorCommand::Undo)
        .expect("undo mask creation");
    assert!(!doc.layers().iter().any(|layer| layer.id == mask));
    doc.dispatch(EditorCommand::Redo)
        .expect("redo mask creation");
    assert_eq!(find_layer(&doc.layers(), mask).mask_owner, Some(group));

    doc.dispatch(EditorCommand::SetLayerClipping {
        layer: clipped,
        enabled: true,
    })
    .expect("enable clipping");
    doc.dispatch(EditorCommand::SetLayerAlphaLock {
        layer: paint,
        enabled: true,
    })
    .expect("enable alpha lock");
    doc.dispatch(EditorCommand::SetLayerLocked {
        layer: group,
        locked: true,
    })
    .expect("lock group");
    doc.dispatch(EditorCommand::Undo).expect("undo group lock");
    assert!(!find_layer(&doc.layers(), group).locked);
    doc.dispatch(EditorCommand::Redo).expect("redo group lock");
    assert!(find_layer(&doc.layers(), group).locked);

    let root = std::env::temp_dir().join(format!(
        "project-ink-trust-layer-loop-{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).expect("temporary root");
    let path = root.join("layers.inkproj");
    doc.save_as(&path).expect("save layers");
    let mut reopened = Document::open(&path).expect("reopen layers");
    let reopened_layers = reopened.layers();
    assert!(find_layer(&reopened_layers, group).locked);
    assert!(find_layer(&reopened_layers, paint).alpha_lock);
    assert!(find_layer(&reopened_layers, clipped).clipping);
    assert_eq!(find_layer(&reopened_layers, mask).mask_owner, Some(group));
    assert!(
        reopened
            .dispatch(EditorCommand::SetLayerOpacity {
                layer: paint,
                opacity: 50_000,
            })
            .is_err(),
        "a reopened group lock must still reject descendant edits"
    );
    reopened
        .dispatch(EditorCommand::Undo)
        .expect("undo reopened lock");
    assert!(!find_layer(&reopened.layers(), group).locked);
    reopened
        .dispatch(EditorCommand::Redo)
        .expect("redo reopened lock");
    assert!(find_layer(&reopened.layers(), group).locked);
    std::fs::remove_dir_all(root).expect("cleanup project");
}

#[test]
fn raster_merge_down_capability_reports_engine_structural_restrictions() {
    let spec = DocumentSpec {
        width_px: 64,
        height_px: 64,
        dpi: 144.0,
        color_space: ink_model::ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let mut doc = Document::new(DocumentId::from_u128(90_310), spec).expect("valid doc");
    let target = doc.layers()[0].id;
    let source = doc.add_layer(LayerKind::Raster).expect("source raster");
    let capability_for_source = |doc: &Document| {
        doc.layer_action_capabilities()
            .expect("action capabilities")
            .into_iter()
            .find(|capability| capability.layer_id == source)
            .expect("source actions")
    };
    assert_eq!(capability_for_source(&doc).merge_down_reason, None);

    doc.dispatch(EditorCommand::SetLayerOpacity {
        layer: target,
        opacity: u16::MAX / 2,
    })
    .expect("set target opacity");
    assert_eq!(
        capability_for_source(&doc).merge_down_reason.as_deref(),
        Some("Exact merge requires the lower target at 100% opacity.")
    );
    doc.dispatch(EditorCommand::SetLayerOpacity {
        layer: target,
        opacity: u16::MAX,
    })
    .expect("restore target opacity");

    doc.add_layer(LayerKind::Mask).expect("attached mask");
    assert_eq!(
        capability_for_source(&doc).merge_down_reason.as_deref(),
        Some("Remove or apply attached masks before merging layers.")
    );
}

#[test]
fn layer_duplicate_capacity_reason_matches_engine_limit() {
    assert_eq!(
        duplicate_capacity_reason(MAX_LAYERS - 1, 1),
        None,
        "a duplicate that reaches the limit is allowed"
    );
    assert_eq!(
        duplicate_capacity_reason(MAX_LAYERS - 1, 2).as_deref(),
        Some("Document layer limit reached; remove layers before duplicating.")
    );
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
    let mut doc =
        Document::new(DocumentId::from_u128(0x574f_524b_4c49_4d49), spec).expect("valid document");
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
    doc.push_pointer_packet(&ink_test_support::one_sample(20.0, 10.0, 1.0))
        .expect("movement commits ink before cancellation");
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
fn canceled_touch_stroke_preserves_redo_through_save_and_reopen() {
    let spec = DocumentSpec {
        width_px: 128,
        height_px: 128,
        dpi: 144.0,
        color_space: ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let mut doc = Document::new(DocumentId::from_u128(41), spec).expect("valid doc");
    let layer = doc.layers()[0].id;
    let original_stroke = StrokeId::from_u128(42);
    doc.dispatch(EditorCommand::BeginStroke {
        stroke: original_stroke,
        layer,
        brush: BrushPreset::starters()[0].id,
    })
    .expect("begin original stroke");
    doc.push_pointer_packet(&ink_test_support::one_sample(32.0, 32.0, 1.0))
        .expect("queue original stroke sample");
    doc.dispatch(EditorCommand::EndStroke {
        stroke: original_stroke,
    })
    .expect("commit original stroke");
    let original_tile = doc
        .read_tile(layer, TileCoord { x: 0, y: 0 })
        .expect("read original ink");
    assert!(original_tile.iter().any(|channel| *channel != 0));

    doc.dispatch(EditorCommand::Undo)
        .expect("undo original stroke");
    let blank_tile = doc
        .read_tile(layer, TileCoord { x: 0, y: 0 })
        .expect("read undone tile");
    assert!(blank_tile.iter().all(|channel| *channel == 0));

    // A three-finger Redo chord starts as a one-finger touch stroke, then the
    // editor cancels that provisional stroke when the second finger arrives.
    let canceled_stroke = StrokeId::from_u128(43);
    doc.dispatch(EditorCommand::BeginStroke {
        stroke: canceled_stroke,
        layer,
        brush: BrushPreset::starters()[0].id,
    })
    .expect("begin provisional touch stroke");
    doc.push_pointer_packet(&ink_test_support::one_sample(80.0, 80.0, 1.0))
        .expect("queue provisional touch sample");
    doc.dispatch(EditorCommand::CancelStroke {
        stroke: canceled_stroke,
    })
    .expect("cancel provisional touch stroke");

    assert_eq!(
        doc.read_tile(layer, TileCoord { x: 0, y: 0 })
            .expect("read canceled tile"),
        blank_tile,
    );
    let history_before_save = doc.history_snapshot(100).expect("read history");
    assert_eq!(history_before_save.cursor, 0);
    assert_eq!(history_before_save.entries.len(), 1);
    assert!(!history_before_save.entries[0].applied);

    let root = std::env::temp_dir().join(format!(
        "project-ink-canceled-touch-redo-{}",
        std::process::id()
    ));
    std::fs::create_dir(&root).expect("create isolated fixture root");
    let path = root.join("drawing.inkproj");
    doc.save_as(&path).expect("save canceled touch stroke");
    let mut reopened = Document::open(&path).expect("reopen canceled touch stroke");
    let history_after_reopen = reopened
        .history_snapshot(100)
        .expect("read reopened history");
    assert_eq!(history_after_reopen.cursor, 0);
    assert_eq!(history_after_reopen.entries.len(), 1);
    assert!(!history_after_reopen.entries[0].applied);

    reopened
        .dispatch(EditorCommand::Redo)
        .expect("redo original stroke after reopen");
    assert_eq!(
        reopened
            .read_tile(layer, TileCoord { x: 0, y: 0 })
            .expect("read redone tile"),
        original_tile,
    );
    std::fs::remove_dir_all(root).expect("remove isolated fixture root");
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
fn pointer_samples_resume_as_a_new_path_after_reentering_the_canvas() {
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
    let sample = |canvas_x, canvas_y, sequence| ink_input::PointerSample {
        pointer_id: 0,
        flags: 0,
        device_kind: ink_input::DeviceKind::Unknown,
        phase: ink_input::Phase::Move,
        canvas_x,
        canvas_y,
        pressure: u16::MAX,
        tilt_x: 0.0,
        tilt_y: 0.0,
        azimuth: 0.0,
        twist: 0.0,
        timestamp_ns: u64::from(sequence),
        sequence,
    };
    doc.push_pointer_packet(&ink_test_support::pointer_packet(&[
        sample(65_536.0, -65_536.0, 2),
        sample(65_536.0, -32.0, 3),
        sample(32.0, 8.0, 4),
    ]))
    .expect("off-page gap and re-entry packet");
    doc.flush_input().expect("bounded samples are rendered");
    {
        let state = lock_recover(&doc.state);
        let samples = &state.active_stroke.as_ref().expect("active stroke").samples;
        assert_eq!(samples.len(), 4);
        assert_eq!(samples[1].canvas_x.to_bits(), 63.0_f32.to_bits());
        assert!((samples[1].canvas_y - 0.9697).abs() < 0.001);
        assert!((samples[2].canvas_x - 63.0).abs() < 0.001);
        assert!(
            (samples[2].canvas_y - 7.981).abs() < 0.01,
            "re-entry boundary sample: {:?}",
            samples[2]
        );
        assert!((samples[3].canvas_x - 32.0).abs() < f32::EPSILON);
        assert!((samples[3].canvas_y - 8.0).abs() < f32::EPSILON);
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
    assert!((doc.vector_stroke_summaries(layer).expect("summary")[0].2[0] - 15.0).abs() < 0.001);
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
        height_px: 128,
        dpi: 144.0,
        color_space: ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let mut doc = Document::new(DocumentId::from_u128(80), spec).expect("valid doc");
    let layer = doc.layers()[0].id;
    {
        let mut state = lock_recover(&doc.state);
        state
            .layers
            .get_mut(&layer)
            .expect("thumbnail layer")
            .tiles
            .set_pixel(
                128,
                64,
                Rgba8 {
                    r: 12,
                    g: 34,
                    b: 56,
                    a: 255,
                },
            );
        state
            .layers
            .get_mut(&layer)
            .expect("thumbnail layer")
            .tiles
            .set_pixel(
                167,
                65,
                Rgba8 {
                    r: 240,
                    g: 10,
                    b: 20,
                    a: 255,
                },
            );
    }
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
    let thumbnail = doc.read_layer_thumbnail(layer, 32).expect("thumbnail");
    assert_eq!(thumbnail.len(), 32 * 32 * 4);
    let sampled_center = (16 * 32 + 16) * 4;
    assert_eq!(
        &thumbnail[sampled_center..sampled_center + 4],
        &[12, 34, 56, 255]
    );
    let sparse_mark = (16 * 32 + 20) * 4;
    assert_eq!(
        &thumbnail[sparse_mark..sparse_mark + 4],
        &[240, 10, 20, 255],
        "a sparse mark between thumbnail pixel centers remains visible"
    );
    let padded_top_center = (2 * 32 + 16) * 4;
    assert_eq!(
        &thumbnail[padded_top_center..padded_top_center + 4],
        &[0; 4]
    );
    assert!(doc.read_layer_thumbnail(layer, 8).is_err());
}

#[test]
fn sparse_mask_thumbnail_shows_effective_coverage_and_reveal_all_default() {
    let spec = DocumentSpec {
        width_px: 256,
        height_px: 128,
        dpi: 144.0,
        color_space: ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let mut doc = Document::new(DocumentId::from_u128(81), spec).expect("document");
    let owner = doc.layers()[0].id;
    let mask = doc.add_layer(LayerKind::Mask).expect("mask layer");
    {
        let mut state = lock_recover(&doc.state);
        let mask_state = state.layers.get_mut(&mask).expect("mask");
        mask_state.layer.mask_owner = Some(owner);
        mask_state.layer.mask_stencil = false;
    }

    let thumbnail = doc.read_layer_thumbnail(mask, 32).expect("default preview");
    let center = (16 * 32 + 16) * 4;
    assert_eq!(&thumbnail[center..center + 4], &[255; 4]);

    {
        let mut state = lock_recover(&doc.state);
        state.layers.get_mut(&mask).expect("mask").tiles.set_pixel(
            128,
            64,
            Rgba8 {
                r: 0,
                g: 0,
                b: 0,
                a: 255,
            },
        );
    }
    let thumbnail = doc.read_layer_thumbnail(mask, 32).expect("edited preview");
    let edited = &thumbnail[center..center + 4];
    assert!(
        edited[0] < 255,
        "hidden coverage should darken the mask preview"
    );
    assert_eq!(&edited[..3], &[edited[0]; 3]);
    assert_eq!(edited[3], 255);
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
    let root = std::env::temp_dir().join(format!("project-ink-color-save-{}", std::process::id()));
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
fn active_brush_color_is_session_state_and_does_not_edit_presets() {
    let spec = DocumentSpec {
        width_px: 64,
        height_px: 64,
        dpi: 144.0,
        color_space: ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let mut doc = Document::new(DocumentId::from_u128(83), spec).expect("valid doc");
    let color = Rgba8 {
        r: 18,
        g: 171,
        b: 52,
        a: 255,
    };
    doc.set_active_brush_color(color);

    assert_eq!(
        doc.revision(),
        0,
        "a foreground color is not a document edit"
    );
    assert!(
        doc.snapshot().brushes.is_empty(),
        "built-in brushes remain unmodified"
    );
    let layer = doc.layers()[0].id;
    let stroke = ink_model::StrokeId::from_u128(84);
    doc.dispatch(EditorCommand::BeginStroke {
        stroke,
        layer,
        brush: BrushId::from_u128(1),
    })
    .expect("begin stroke with shared color");
    assert_eq!(
        lock_recover(&doc.state)
            .active_stroke
            .as_ref()
            .expect("active legacy stroke")
            .brush
            .color,
        color
    );
    doc.dispatch(EditorCommand::EndStroke { stroke })
        .expect("end legacy stroke");

    let compiled_stroke = ink_model::StrokeId::from_u128(85);
    doc.dispatch(EditorCommand::BeginStroke {
        stroke: compiled_stroke,
        layer,
        brush: BrushId::from_u128(6),
    })
    .expect("begin compiled stroke with shared color");
    let state = lock_recover(&doc.state);
    let compiled = state
        .active_stroke
        .as_ref()
        .expect("active compiled stroke")
        .compiled_brush
        .as_ref()
        .expect("compiled brush");
    let compiled_color = match &compiled.paint {
        PaintBehavior::Solid(value) => value.color,
        PaintBehavior::Glaze(value) => value.color,
        PaintBehavior::Marker(value) => value.color,
        PaintBehavior::ColorPickup(value) => value.color,
        PaintBehavior::DigitalWatercolor(value) => value.color,
    };
    assert_eq!(compiled_color, color);
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
    let root = std::env::temp_dir().join(format!("project-ink-comic-save-{}", std::process::id()));
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
