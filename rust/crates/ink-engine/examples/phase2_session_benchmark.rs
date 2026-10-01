//! Accelerated one-hour Phase 2 mixed-brush session.
//!
//! This is an engine regression signal, not a wall-clock simulation. It
//! replays 3,600 short strokes (one per second for an hour) across the Phase 2
//! built-in library and reports memory checkpoints plus per-stroke timing. It
//! intentionally uses the same public command and pointer paths as the app.

use ink_brush::builtin_library;
use ink_command::EditorCommand;
use ink_engine::Document;
use ink_model::{ColorSpace, DocumentId, DocumentSpec, Rgba8};
use ink_test_support::one_sample;
use std::time::Instant;

const STROKES: usize = 3_600;
const CHECKPOINT_INTERVAL: usize = 600;

fn main() {
    let spec = DocumentSpec {
        width_px: 4096,
        height_px: 4096,
        dpi: 300.0,
        color_space: ColorSpace::Srgb,
        background: Rgba8::default(),
    };
    let mut document = Document::new(DocumentId::from_u128(0x0053_4553_5349_4F4E), spec)
        .expect("session document must be valid");
    let layer = document.layers()[0].id;
    let brushes = builtin_library();
    let phase_two_brushes: Vec<_> = brushes.iter().filter(|brush| brush.id.0 > 5).collect();
    assert!(
        !phase_two_brushes.is_empty(),
        "Phase 2 library must not be empty"
    );
    let initial_memory_bytes = document.estimated_working_memory_bytes();

    let mut elapsed_micros = Vec::with_capacity(STROKES);
    let mut checkpoints = Vec::with_capacity(STROKES / CHECKPOINT_INTERVAL);
    for index in 0..STROKES {
        let stroke = ink_model::StrokeId::from_u128(0x7000 + index as u128);
        let brush = phase_two_brushes[index % phase_two_brushes.len()].id;
        let x_offset = u16::try_from((index * 37) % 4000).expect("bounded x offset");
        let y_offset = u16::try_from((index * 61) % 4000).expect("bounded y offset");
        let pressure_step = u16::try_from(index % 4).expect("bounded pressure step");
        let x = 32.0 + f32::from(x_offset);
        let y = 32.0 + f32::from(y_offset);
        let pressure = 0.25 + f32::from(pressure_step) * 0.2;

        let started = Instant::now();
        document
            .dispatch(EditorCommand::BeginStroke {
                stroke,
                layer,
                brush,
            })
            .expect("begin session stroke");
        for (dx, dy) in [(0.0, 0.0), (8.0, 4.0), (16.0, 8.0)] {
            document
                .push_pointer_packet(&one_sample(x + dx, y + dy, pressure))
                .expect("push session sample");
        }
        document
            .dispatch(EditorCommand::EndStroke { stroke })
            .expect("end session stroke");
        document.drain_events().expect("drain session events");
        elapsed_micros.push(started.elapsed().as_micros());
        // Model Flutter consuming the confirmed preview stream each frame.
        // Without a consumer, the bounded queue fills during this accelerated
        // session and later strokes measure overflow scans rather than engine
        // work under normal presentation.
        document
            .drain_live_dabs_available(65_536)
            .expect("drain session preview dabs");

        if (index + 1) % CHECKPOINT_INTERVAL == 0 {
            checkpoints.push((index + 1, document.estimated_working_memory_bytes()));
        }
    }

    let p95 = percentile_95(&elapsed_micros);
    let first_window = &elapsed_micros[..CHECKPOINT_INTERVAL.min(elapsed_micros.len())];
    let last_start = elapsed_micros.len().saturating_sub(CHECKPOINT_INTERVAL);
    let last_window = &elapsed_micros[last_start..];
    let first_p95 = percentile_95(first_window);
    let last_p95 = percentile_95(last_window);
    let max_memory = checkpoints
        .iter()
        .map(|(_, bytes)| *bytes)
        .max()
        .unwrap_or_default();
    let final_memory_bytes = document.estimated_working_memory_bytes();
    let checkpoints_json = checkpoints
        .iter()
        .map(|(strokes, bytes)| format!("{{\"strokes\":{strokes},\"bytes\":{bytes}}}"))
        .collect::<Vec<_>>()
        .join(",");
    println!(
        "{{\"strokes\":{STROKES},\"phase_two_brushes\":{},\"p95_stroke_us\":{p95},\"first_window_p95_us\":{first_p95},\"last_window_p95_us\":{last_p95},\"initial_memory_bytes\":{initial_memory_bytes},\"final_memory_bytes\":{final_memory_bytes},\"max_memory_bytes\":{max_memory},\"checkpoints\":[{checkpoints_json}]}}",
        phase_two_brushes.len()
    );
}

fn percentile_95(samples: &[u128]) -> u128 {
    if samples.is_empty() {
        return 0;
    }
    let mut sorted = samples.to_vec();
    sorted.sort_unstable();
    let index = ((sorted.len() * 95).saturating_sub(1) / 100).min(sorted.len() - 1);
    sorted[index]
}
