# Engine design guardrails

The engine owns document state and committed pixels. Flutter owns presentation;
live GPU dabs are ephemeral. These checks preserve the existing FRB API,
packet encodings, brush semantics, and `.inkproj` versions.

## Dependency ownership

From the repository root:

```sh
python3 scripts/check_architecture.py
python3 -m unittest discover -s scripts -p test_check_architecture.py
```

The standard-library-only checker reads locked Cargo metadata, including
renamed, build, optional, and target-specific dependencies. Every workspace
crate needs an explicit entry. Production workspace edges use an allowlist;
test-support is dev-only, the vendored PSD parser stays standalone, UI/FRB
stays at `ink_bridge`, and graphics handles stay in `ink-live-render`.
Dev dependencies may reach other engine modules to exercise integration seams,
but cannot import UI into foundations or couple the standalone parser to Ink.
CI runs both the checker and negative fixtures. A deliberate ownership change
must update the table and its negative fixtures together; never add an edge
solely to silence a failure.

## CPU reference and GPU preview

```sh
INK_REQUIRE_GPU_PARITY=1 cargo test -p ink-engine gpu_live_preview_ -- --nocapture
cargo test -p ink-live-render --lib -- --nocapture
```

The engine comparisons use actual committed CPU tiles and offscreen GPU
readback. Technical Pen taps cover full/low pressure, fractional centers, and
canvas-edge clipping. Long spirals cover the first three basic starter brushes
and compare geometric support in both directions within one pixel.
Tap bounds tolerate one pixel; fully covered centers agree exactly. A tiny,
low-pressure fractional dab allows 16/255 per premultiplied center channel:
the CPU coverage kernel and GPU smoothstep do not have identical subpixel AA.
This allowance is specific to that small-dab case, not an export tolerance.
Outside pixels remain transparent. Existing live-render tests independently
exercise acknowledgement, cancellation, transforms, and append/rebuild parity.

Unavailable adapters print `GPU_PARITY_SKIPPED` under normal test execution.
`INK_REQUIRE_GPU_PARITY` makes unavailability fail, and macOS CI requires this
mode. `GPU_PARITY_EXECUTED` reports adapter initialization; the subsequent test
result proves the comparison completed. Always retain both pieces of evidence.
These checks do not claim a complete GPU layer compositor, textured/effect
brush pixel equivalence, or physical input-to-display acceptance. Any future
GPU document compositor must be compared with CPU composition for its entire
advertised layer/mask/group/adjustment/blend subset before being enabled.

## Cache identity and invalidation

Committed CPU tile bytes are document-space, premultiplied BGRA8. Their key is
`(revision, layer, tile x, tile y)` inside a document-session-owned cache. A
monotonic whole-document revision conservatively includes every relevant layer,
mask, order, opacity, and adjustment change. Zoom, pan, display scale, and
viewport dimensions do not affect these CPU bytes; viewport transforms belong
to presentation and live GPU surfaces, whose own generation/transform contract
is documented in `live-render.md`. A future color-space, tile-format, or
rendering-option variant must be included in cache identity or retire the
cache before publication.

Dirty-only revisions promote unchanged tiles after replacement images decode.
Full redraws rebuild the byte set and retire old decoded revisions only after
the replacement frame is ready. Engine replacement clears byte/revision state,
retires the image cache, clears both CPU and live acknowledgement state, and
checks the captured engine/generation after drains, snapshot reads, fallback
tile reads, and image decodes. Old asynchronous work cannot clear or publish
into the new session, even when its numeric revision equals the new one.

```sh
cd app
flutter test test/tile_cache_test.dart test/canvas_tile_synchronization_lifecycle_test.dart test/canvas_composite_tile_snapshot_reader_test.dart
```

The delayed-snapshot regression replaces the session during a pending snapshot
and checks that the new session's populated cache survives. Engine lifecycle
fixtures below verify mask/reorder/undo revision and pixel behavior separately.

## Sparse history costs

```sh
cargo bench -p ink-raster --bench tile_store_history
cargo run -p ink-engine --release --example history_session_benchmark
```

The tile-store benchmark emits JSONL for 64/256/1024 populated tiles spread
across sparse extents. Each workload performs 256 edits with 128 retained undo
snapshots. It measures snapshot clone, first-write detachment (including index
and dirty-map detachment), and store-level undo p95 in nanoseconds. Unique
retained pixel buffers are counted once across current/history stores and
asserted against the expected baseline plus one detached buffer per retained
edit. `retained_pixel_bytes` excludes indices, allocator overhead, and RSS;
it does not replace conservative engine admission or history budgets.

The engine example separately measures actual command commit, Undo, and Redo
latency after 256 strokes across a 16384-square sparse canvas. Only commands
that advance revision enter the latency samples; exhausted-history no-ops are
excluded, and the JSON reports actual undo/redo counts. It validates
that undo removes the last painted tile and redo restores its exact pixels.
Neither benchmark is a stylus/display latency measurement. Timing is reported,
not enforced as a machine-independent threshold. Existing Phase 1 and Phase 2
performance gates remain required and unchanged.

## Deterministic headless lifecycle

```sh
cargo test -p ink-engine headless_contract
```

The scenario starts with synthetic known red/blue pixels and an attached mask,
then uses engine commands for mask toggles, layer reordering, undo/redo, and an
invalid cyclic move. Every expected composite pixel is independently generated;
a captured immutable snapshot must retain its old revision and pixels after
mutation. Save, close, and reopen must preserve the expected composition, and
two independent runs must agree. It runs on both replay-determinism CI hosts.
A second scenario paints mask coverage through the real pointer/stroke path,
checks the new composite and revision, preserves the old snapshot, and undoes
the paint. No Flutter window, account, network service, or GPU is needed.
