//! Repeatable Phase 1 CPU benchmark for packet-to-dirty-tile work.
//!
//! This measures the Rust engine boundary only. It does not include platform
//! stylus delivery, Flutter scheduling, GPU composition, or display latency.

use ink_brush::BrushPreset;
use ink_command::EditorCommand;
use ink_engine::{Document, EngineEvent};
use ink_model::{ColorSpace, DocumentId, DocumentSpec, LayerKind, Rgba8};
use ink_test_support::one_sample;
use std::collections::HashSet;
use std::time::Instant;

const LATENCY_ITERATIONS: usize = 128;

fn measure_packet_to_dirty_latency(spec: DocumentSpec) -> (u128, usize) {
    let latency_samples = [
        (16.0, 16.0, 0.5),
        (300.0, 16.0, 0.6),
        (550.0, 16.0, 0.8),
        (800.0, 16.0, 1.0),
    ];
    let mut latency_document = Document::new(DocumentId::from_u128(0xBEEF), spec)
        .expect("latency benchmark document must be valid");
    let latency_layer = latency_document.layers()[0].id;
    let mut elapsed_micros = Vec::with_capacity(LATENCY_ITERATIONS);
    let mut maximum_dirty_tiles = 0usize;
    for iteration in 0..LATENCY_ITERATIONS {
        let stroke = ink_model::StrokeId::from_u128(
            0x2000_u128 + u128::try_from(iteration).expect("bounded iteration"),
        );
        latency_document
            .dispatch(EditorCommand::BeginStroke {
                stroke,
                layer: latency_layer,
                brush: BrushPreset::starters()[0].id,
            })
            .expect("begin latency stroke");
        let started = Instant::now();
        for (x, y, pressure) in latency_samples {
            latency_document
                .push_pointer_packet(&one_sample(x, y, pressure))
                .expect("push latency sample");
        }
        let events = latency_document.drain_events().expect("latency events");
        elapsed_micros.push(started.elapsed().as_micros());
        // The real Flutter consumer drains confirmed dabs as frames are
        // presented. Keep the synthetic consumer moving between iterations;
        // otherwise this benchmark eventually measures a permanently full
        // preview queue rather than packet-to-dirty latency.
        latency_document
            .drain_live_dabs_available(65_536)
            .expect("drain benchmark preview dabs");
        let dirty_tiles = events
            .iter()
            .filter_map(|event| match event {
                EngineEvent::TilesDirty { tiles, .. } => Some(
                    tiles
                        .iter()
                        .map(|tile| (tile.layer, tile.coordinate))
                        .collect::<HashSet<_>>(),
                ),
                _ => None,
            })
            .fold(HashSet::new(), |mut all, current| {
                all.extend(current);
                all
            })
            .len();
        maximum_dirty_tiles = maximum_dirty_tiles.max(dirty_tiles);
        latency_document
            .dispatch(EditorCommand::EndStroke { stroke })
            .expect("end latency stroke");
        latency_document
            .dispatch(EditorCommand::Undo)
            .expect("reset latency stroke");
    }
    elapsed_micros.sort_unstable();
    let p95_index = ((elapsed_micros.len() * 95).saturating_sub(1) / 100)
        .min(elapsed_micros.len().saturating_sub(1));
    let p95 = elapsed_micros.get(p95_index).copied().unwrap_or_default();
    (p95, maximum_dirty_tiles)
}

fn main() {
    let spec = DocumentSpec {
        width_px: 4096,
        height_px: 4096,
        dpi: 300.0,
        color_space: ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let (p95, maximum_dirty_tiles) = measure_packet_to_dirty_latency(spec);

    let mut memory_document = Document::new(DocumentId::from_u128(0xCAFE), spec)
        .expect("memory benchmark document must be valid");
    for _ in 0..19 {
        memory_document
            .dispatch(EditorCommand::AddLayer {
                parent: None,
                kind: LayerKind::Raster,
            })
            .expect("add benchmark layer");
    }
    let layers = memory_document.layers();
    for (layer_index, layer) in layers.iter().enumerate() {
        let stroke = ink_model::StrokeId::from_u128(0x1000 + layer_index as u128);
        memory_document
            .dispatch(EditorCommand::BeginStroke {
                stroke,
                layer: layer.id,
                brush: BrushPreset::starters()[0].id,
            })
            .expect("begin memory benchmark stroke");
        memory_document
            .push_pointer_packet(&one_sample(32.0, 32.0, 1.0))
            .expect("push memory benchmark sample");
        memory_document.drain_events().expect("memory events");
        memory_document
            .dispatch(EditorCommand::EndStroke { stroke })
            .expect("end memory benchmark stroke");
    }
    println!(
        "{{\"latency_iterations\":{},\"p95_packet_to_dirty_us\":{},\"max_dirty_tiles\":{},\"memory_layers\":{},\"estimated_engine_bytes\":{}}}",
        LATENCY_ITERATIONS,
        p95,
        maximum_dirty_tiles,
        layers.len(),
        memory_document.estimated_working_memory_bytes(),
    );
}
