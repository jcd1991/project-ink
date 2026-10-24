# Phase 1 benchmark contract

Run from the repository root:

```sh
cargo run -p ink-engine --release --example phase1_benchmark
```

The example emits one JSON object with:

- `p95_packet_to_dirty_us`: release-mode Rust time from enqueueing the four
  recorded samples through worker completion and dirty-event drain. The
  harness drains the corresponding preview dabs between iterations to model
  the Flutter frame consumer and avoid measuring a permanently saturated
  preview queue.
- `max_dirty_tiles`: unique `(layer, tile)` coordinates touched by that
  four-tile fixture.
- `memory_layers`: ordinary raster-layer count in the memory scenario.
- `estimated_engine_bytes`: document state, tile payloads, journal payloads,
  and reversible snapshots owned by Rust. It excludes allocator/process RSS,
  worker queue capacity, Flutter image cache, and operating-system overhead.

The raster crate also has a focused release microbenchmark for the copy-on-write
history snapshot path:

```sh
cargo bench -p ink-raster --bench tile_store_history
```

It clones a prepared 64-tile sparse store 10,000 times and reports elapsed and
average clone time. This isolates snapshot-container cost; it is not a stroke,
save, or full-document benchmark. On the local arm64 development host during
the copy-on-write change, the same harness measured 309 ns/clone before and
11 ns/clone after. These are comparative local observations, not CI thresholds
or portable latency claims.

The benchmark is a regression signal, not a physical latency claim. Phase 1
stylus-to-visible-update targets still require timestamped traces on the M1/M4
iPads and Galaxy S23 Ultra. The legacy CPU recorded-stroke fixture uses
architecture-specific tile hashes: `1395959408535220756` on arm64 and
`12475419944979558790` on x86_64. This detects regressions within each target;
it does not claim bit-identical legacy raster pixels across architectures.
The vector-ink golden test asserts tile hash `4780892121892926211`; run the
golden checks on arm64 and x86_64 CI lanes.

The Rust CI lane treats this as a regression guard, not a device acceptance
claim: packet-to-dirty p95 must remain at or below 8 ms, the fixture must touch
no more than four unique tiles, and the engine-owned memory estimate must stay
below 900 MB. Flutter composition, display scheduling, and process RSS remain
outside these guardrails.

The Flutter canvas exposes an optional `onPerformanceSnapshot` hook for those
device runs. It reports a bounded nearest-rank p95 from normalized packet
receipt to a post-frame callback, plus dirty-tile count and tile decode time.
The hook is local-only and emits no network telemetry. `ProjectInkApp` also
accepts an optional `performanceTracePath`, which appends each snapshot as a
newline-delimited JSON record asynchronously. Treat its result as an app-side
trace: hardware scan-out and display scheduling remain outside the measurement.
On iOS/iPadOS and macOS, records include an optional `rss_bytes` sample from
the native task resident-size API. Android records use the closest app-level
PSS estimate available to the process; Windows/Linux currently leave the field
null. These samples are diagnostic context only and do not replace the
platform-native memory evidence below.

Use the repository report utility after copying the trace off the device:

```sh
dart tools/phase1_trace_report.dart phase1.jsonl ipad-m4
dart tools/phase1_trace_report.dart phase1.jsonl ipad-m1
dart tools/phase1_trace_report.dart phase1.jsonl android-s23
```

The report uses the worst complete recorded p95 and exits non-zero when the
device target is missed. Capture RSS separately at the same document size:

- Android: `adb shell dumpsys meminfo org.projectink.studio`.
- iOS/iPadOS: Instruments Allocations/Memory Graph or an Xcode device report.
- macOS/Windows/Linux: the platform process monitor while replaying the same
  recorded stroke fixture.

External platform tooling remains authoritative for RSS; the optional trace
field is intentionally not inferred from the Dart trace or the Rust estimate.

For the Phase 2 long-session gate, run the accelerated mixed-brush harness:

```sh
cargo run -p ink-engine --release --example phase2_session_benchmark
```

It replays 3,600 short strokes across the Phase 2 built-in brushes using the
same public command and pointer paths as the app. The JSON output reports
checkpoint memory, overall p95 stroke time, and the first/final 600-stroke p95
windows. The harness drains preview dabs between iterations to model the
Flutter frame consumer and avoid measuring a permanently saturated queue. It
is a repeatable engine regression signal; it does not claim physical
stylus-to-display latency or process RSS. A run passes the engine memory gate
when `max_memory_bytes` remains below the 900 MiB document ceiling and the
final-window timing does not regress against the first window.

For sparse copy-on-write detachment, retained pixel payload, and public-command
undo/redo measurements, see [engine design guardrails](engine-design-guardrails.md#sparse-history-costs).
