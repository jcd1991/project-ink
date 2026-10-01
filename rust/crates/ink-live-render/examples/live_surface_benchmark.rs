//! Compares append-only dab batches with a forced full-overlay rebuild.
//!
//! This does not measure native texture presentation, Flutter frame scheduling,
//! or display scan-out. Use the desktop/app trace after platform texture
//! registration is available for end-to-end latency claims.

use ink_live_render::{DabPhase, GpuLiveSurface, LiveDab, LiveSurfaceConfig};
use std::time::Instant;

const FRAMES: usize = 600;

fn main() {
    let append_surface = match GpuLiveSurface::new(LiveSurfaceConfig {
        physical_width: 1024,
        physical_height: 768,
        scale_milli: 1000,
    }) {
        Ok(surface) => surface,
        Err(error) => {
            eprintln!("GPU live surface unavailable: {error:?}");
            return;
        }
    };
    let rebuild_surface = match GpuLiveSurface::new(LiveSurfaceConfig {
        physical_width: 1024,
        physical_height: 768,
        scale_milli: 1000,
    }) {
        Ok(surface) => surface,
        Err(error) => {
            eprintln!("GPU rebuild comparison surface unavailable: {error:?}");
            return;
        }
    };

    let adapter_name = format!("{:?}", append_surface.adapter_name());
    let mut append_micros = Vec::with_capacity(FRAMES);
    let mut rebuild_micros = Vec::with_capacity(FRAMES);
    for sequence in 0..FRAMES {
        let dab = LiveDab {
            stroke_id: 1,
            sequence: u32::try_from(sequence).expect("benchmark sequence is bounded"),
            dab_index: 0,
            x: f32::from(u16::try_from(sequence % 1024).expect("x coordinate is bounded")),
            y: f32::from(u16::try_from(sequence % 768).expect("y coordinate is bounded")),
            radius: 6.0,
            opacity: 1.0,
            rotation: 0.0,
            color: [0, 0, 0, 255],
            phase: DabPhase::Confirmed,
        };
        let append_started = Instant::now();
        append_surface
            .render(&[dab])
            .expect("bounded append-only benchmark dab must render");
        append_micros.push(append_started.elapsed().as_micros());

        rebuild_surface
            .render(&[dab])
            .expect("bounded comparison dab must render");
        let rebuild_started = Instant::now();
        rebuild_surface
            .set_viewport(
                [1.0, 0.0, 0.0, 1.0, 0.0, 0.0],
                u64::try_from(sequence + 1).expect("benchmark generation is bounded"),
            )
            .expect("bounded full-overlay rebuild must render");
        rebuild_micros.push(rebuild_started.elapsed().as_micros());
    }

    let append_p95_micros = percentile_95(&append_micros);
    let rebuild_p95_micros = percentile_95(&rebuild_micros);
    let append_max_micros = append_micros.iter().copied().max().unwrap_or_default();
    let rebuild_max_micros = rebuild_micros.iter().copied().max().unwrap_or_default();
    println!(
        "{{\"frames\":{FRAMES},\"surface_width\":1024,\"surface_height\":768,\"gpu_adapter\":{adapter_name},\"append_p95_cpu_prepare_and_submit_us\":{append_p95_micros},\"append_max_cpu_prepare_and_submit_us\":{append_max_micros},\"forced_rebuild_p95_cpu_prepare_and_submit_us\":{rebuild_p95_micros},\"forced_rebuild_max_cpu_prepare_and_submit_us\":{rebuild_max_micros},\"measures_gpu_completion\":false,\"measures_frame_presentation\":false}}"
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
