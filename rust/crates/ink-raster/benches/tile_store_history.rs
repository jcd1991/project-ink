//! Sparse large-canvas history costs; JSONL reports payload bytes, never RSS.

use ink_model::Rgba8;
use ink_raster::{TILE_SIZE, TileStore};
use std::hint::black_box;
use std::time::Instant;

const EDITS: usize = 256;
const HISTORY_LIMIT: usize = 128;

fn p95(samples: &mut [u128]) -> u128 {
    samples.sort_unstable();
    samples[(samples.len() * 95).div_ceil(100) - 1]
}

fn measure(tile_count: u32) {
    let mut store = TileStore::default();
    let color = Rgba8 {
        r: 20,
        g: 40,
        b: 60,
        a: 255,
    };
    // One populated tile per 4x4 tile cell: large extent, sparse allocation.
    for index in 0..tile_count {
        store.set_pixel(
            (index % 32) * TILE_SIZE * 4,
            (index / 32) * TILE_SIZE * 4,
            color,
        );
    }
    store.take_dirty();
    let mut history = Vec::new();
    let mut clones = Vec::new();
    let mut writes = Vec::new();
    for edit in 0..EDITS {
        let started = Instant::now();
        history.push(black_box(store.clone()));
        clones.push(started.elapsed().as_nanos());
        let index = u32::try_from(edit).expect("bounded edits") % tile_count;
        let started = Instant::now();
        store.set_pixel(
            (index % 32) * TILE_SIZE * 4,
            (index / 32) * TILE_SIZE * 4,
            Rgba8 {
                r: u8::try_from(edit % 256).expect("bounded color"),
                ..color
            },
        );
        writes.push(started.elapsed().as_nanos());
        store.take_dirty();
        if history.len() > HISTORY_LIMIT {
            history.remove(0);
        }
    }
    let history_len = history.len();
    history.push(store.clone());
    let retained = TileStore::retained_pixel_bytes(&history);
    let baseline = usize::try_from(tile_count).expect("bounded tiles") * 256 * 256 * 4;
    assert_eq!(retained, baseline + history_len * 256 * 256 * 4);
    history.pop();
    let mut undos = Vec::new();
    while let Some(previous) = history.pop() {
        let started = Instant::now();
        store = black_box(previous);
        undos.push(started.elapsed().as_nanos());
    }
    assert_eq!(store.allocated_tiles(), tile_count as usize);
    println!(
        "{{\"tiles\":{tile_count},\"edits\":{EDITS},\"history_limit\":{HISTORY_LIMIT},\"clone_p95_ns\":{},\"first_write_p95_ns\":{},\"undo_p95_ns\":{},\"retained_pixel_bytes\":{retained},\"baseline_pixel_bytes\":{baseline}}}",
        p95(&mut clones),
        p95(&mut writes),
        p95(&mut undos)
    );
}

fn main() {
    for tiles in [64, 256, 1024] {
        measure(tiles);
    }
}
