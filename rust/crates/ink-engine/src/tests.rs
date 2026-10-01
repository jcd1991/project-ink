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
fn recorded_stroke_matches_host_raster_golden_tile_hash() {
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
    let expected_hash = match std::env::consts::ARCH {
        // The original shared value came from the x86_64 CI runner. This
        // fixture's legacy CPU raster has a separate captured output on arm64.
        "aarch64" => 1_395_959_408_535_220_756,
        "x86_64" => 12_475_419_944_979_558_790,
        architecture => panic!("no raster golden is recorded for {architecture}"),
    };
    assert_eq!(
        Tile::from_bytes(tile).expect("complete tile").stable_hash(),
        expected_hash
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
