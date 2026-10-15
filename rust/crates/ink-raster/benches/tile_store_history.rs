//! Release-mode microbenchmark for history snapshot cloning of sparse stores.

use ink_model::Rgba8;
use ink_raster::{TILE_SIZE, TileStore};
use std::hint::black_box;
use std::time::Instant;

const TILE_COUNT: u32 = 64;
const CLONE_ITERATIONS: usize = 10_000;

fn main() {
    let mut store = TileStore::default();
    for tile_x in 0..TILE_COUNT {
        store.set_pixel(
            tile_x * TILE_SIZE,
            0,
            Rgba8 {
                r: 20,
                g: 40,
                b: 60,
                a: 255,
            },
        );
    }

    let started = Instant::now();
    let mut allocated_tiles = 0usize;
    for _ in 0..CLONE_ITERATIONS {
        let snapshot = black_box(store.clone());
        allocated_tiles = allocated_tiles.saturating_add(snapshot.allocated_tiles());
        black_box(snapshot);
    }
    let elapsed = started.elapsed();
    let average_ns = elapsed.as_nanos() / CLONE_ITERATIONS as u128;

    println!(
        "{{\"tiles\":{TILE_COUNT},\"clones\":{CLONE_ITERATIONS},\"elapsed_ns\":{},\"average_clone_ns\":{average_ns},\"allocated_tile_observations\":{allocated_tiles}}}",
        elapsed.as_nanos(),
    );
}
