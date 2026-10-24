# Engine guardrails validation — 2026-10-24

Scope: dependency ownership, CPU/GPU preview reference checks, cache/session
invalidation, sparse history measurement, and deterministic headless scenarios.
Implementation/run commands are in `engine-design-guardrails.md`.

## Host results

- Architecture metadata check passed against the current workspace. Seven
  negative fixtures passed (upward/build/target edges, renamed UI/FRB,
  test-support production use, platform handles, unknown crates, standalone PSD).
- `cargo test --workspace --all-targets --all-features`: 629 tests passed across
  23 test targets; no failures. Run with `CARGO_PROFILE_DEV_DEBUG=0` and
  `CARGO_INCREMENTAL=0` to preserve disk headroom.
- Strict workspace/all-target/all-feature Clippy passed with the same profile
  overrides. Cargo reports an existing future-compatibility warning for
  dependency `block 0.1.6`.
- Required-adapter GPU engine comparisons executed on this Mac's offscreen
  adapter, including low-pressure/subpixel/edge taps and three-brush spirals.
  These are GPU preview comparisons, not whole-document GPU composition.
- `flutter analyze --no-pub`: no issues.
- `flutter test --no-pub`: all 731 unit/widget tests passed, including the new
  replacement-during-snapshot regression. It tests equal/reused tile locations
  while a new engine generation owns the cache.
- `cargo fmt --all -- --check` and `git diff --check`: passed.
- `flutter build macos --debug`: passed. Existing plugin Swift Package Manager
  and deprecated macOS file-selector API warnings remain.

The Flutter dependency `objective_c 9.6.0` build hook initially picked up
AppleDouble `._*.m` and `._*.c` metadata from the shared external-volume cache.
Validation used an isolated temporary PUB_CACHE: other package directories
were linked to the existing cache and only objective_c was copied, excluding
`._*`. The shared cache, dependencies, lockfile, and SDK were not edited or
cleaned. Reproduce that isolation when those metadata files are present;
do not count the initial hook failure as a product-test failure or pass.

## Release history measurements

Local Mac results; timings vary with load and are not portable performance SLOs.
Each sparse-store workload performed 256 edits and retained 128 history stores.

| Populated tiles | Clone p95 | First-write p95 | Store undo p95 | Unique retained pixel bytes |
| --- | --- | --- | --- | --- |
| 64 | 83 ns | 71,875 ns | 750 ns | 50,331,648 |
| 256 | 42 ns | 53,667 ns | 1,208 ns | 100,663,296 |
| 1,024 | 42 ns | 55,458 ns | 4,292 ns | 301,989,888 |

The public-engine 256-stroke sparse session performed 128 actual Undo and 128
actual Redo transitions (each advanced the revision). Commit p95 was 211,500
ns; Undo p95 4,042 ns; Redo p95 4,334 ns. Undo cleared the last painted tile and
Redo restored its exact pixels. Exhausted-history no-ops are excluded from
latency samples. Pixel payload counts omit indices, allocator overhead and
RSS; existing conservative admission/history budgets are unchanged.

## Acceptance limits

No Android/iPadOS/Windows/Linux installed interaction or physical stylus/display
latency claim follows from these host tests. No signed release, publication,
push, or full macOS native close/quit acceptance was performed. Native macOS
integration evidence is recorded below separately from the successful build.

## Native macOS integration

`flutter test integration_test/release_document_round_trip_test.dart -d macos`
with a unique `PROJECT_INK_TEST_DOCUMENTS_PATH` passed all seven cases through
the production Rust bridge on this Mac:

- Layer presentation/visibility save, reopen, undo/redo, and second reopen.
- Edited/re-imported custom brush settings persisted on disk.
- Failed brush import preserved source and active document.
- Multi-page comic save, reopen, and export.
- Pixel/recovery round trip with corrupt-open rejection.
- ProjectInkApp preserved active engine and recovery after corrupt Open.
- Failed recovery write retained a dirty, retryable document.

Expected error-path diagnostics were logged by the failure fixtures; the
runner completed with `All tests passed`. Documents/recovery were isolated
under a unique sandbox validation directory. The normal application build
is restored after integration testing because the Flutter runner temporarily
changes its generated Dart target to a listener.

## Existing performance gates

Both unchanged CI guardrails passed in release mode:

- Phase 1: packet-to-dirty p95 4,084 µs (limit 8,000), four dirty tiles
  (limit four), estimated engine bytes 55,287,785 (limit 900,000,000).
- Phase 2: 3,600 strokes across 15 brushes; stroke p95 584 µs (limit 50,000),
  first/final-window p95 600/579 µs (final limit twice the first), maximum
  estimated engine bytes 316,064,272 (limit 900,000,000). Initial/final estimates
  were 3,920/268,883,648 bytes. These are engine estimates, not process RSS.

The final normal macOS debug rebuild completed after native integration,
restoring the regular application target. No source or build caches were
removed to obtain these results.
