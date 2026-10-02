# Project Ink development guide for agents

Use this guide for new work and maintenance in this repository. Treat it as
the project-specific layer over the upstream language and framework guidance
linked at the end. Existing behavior, checked-in format specifications, and
the source code take precedence over assumptions based on a generic pattern.

## Before changing code

- Work from the repository root. Read the relevant package README and
  `specifications/` documents before changing a public API, serialized format,
  input protocol, persistence behavior, or performance-sensitive path.
- Inspect `git status` and the current branch before editing. Preserve all
  pre-existing user changes, untracked files, artwork, generated outputs, and
  diagnostics. Stage only files belonging to the task. Never use `git reset`,
  `git clean`, broad checkout/revert commands, or cache cleanup to get a clean
  test run.
- Make the smallest coherent change at the owning module boundary. Separate
  behavior changes from structural cleanup where practical. Do not reformat or
  regenerate unrelated files.
- State the behavior and compatibility invariants first. Add or update tests
  for changed behavior and report exactly which checks ran and which did not.

## Product and architecture invariants

- Project Ink is local-first and works without accounts, advertising, or a
  required network service. Do not introduce remote state or telemetry without
  an explicit product decision.
- Rust is authoritative for document/project state, pixels, layers, brushes,
  history, persistence, and export. Dart may hold UI state and temporary
  projections, but must not become a second mutable document authority.
- Flutter owns responsive controls, accessibility, gesture arbitration,
  viewport transforms, and visible tile composition. Keep widgets focused on
  presentation and orchestration; move reusable domain decisions into their
  owning Rust or Dart service.
- Preserve existing Rust public APIs, FRB-exported names/types/paths, Dart
  import paths, native channel names, packet encodings, and native-host
  interfaces unless the task explicitly changes a versioned contract. A
  compatibility change must update its specification, generators/adapters,
  migration path, and tests together.
- `.inkproj` is versioned and recovery-safe. Never overwrite an unsupported or
  invalid source document as a side effect of opening it. Keep atomic save,
  backup/recovery, and provider write-back guarantees intact.

## Ownership map

- `rust/crates/ink-engine/src/lib.rs` is the public engine façade. Private
  modules own engine state, commands, worker/queueing, strokes, brushes,
  rendering, persistence conversion, history, and tests. Keep cross-module
  visibility narrow (`pub(super)` or private); do not widen the public façade
  solely to simplify a refactor.
- `rust/crates/ink-bridge/src/api.rs` keeps FRB-exported Rust functions at
  their established `crate::api` paths. Generated transport belongs in
  `frb_generated.rs`; handwritten native interop stays isolated and documented
  at its platform boundary.
- `app/lib/bridge/engine_api/` owns the Dart bridge contract, production FRB
  adapter, in-memory test adapter, packet utilities, and projections.
  `app/lib/bridge/engine_api.dart` is a compatibility/export façade.
- `ComicWorkspaceController` owns its Rust project capability and must release
  it when the workspace session ends. Comic widgets and painters display Rust
  view types; they do not own or mutate project state.
- `CanvasScreen` remains the canvas composition and lifecycle point.
  `CanvasDocumentActions`, `CanvasPreviewSynchronization`,
  `CanvasTileSynchronization`, and `StrokeOperationQueue` own their existing
  document, live-preview, tile-publication, and ordered-bridge seams.
- Keep platform input translation in the native adapters and wire-format
  decoding at the bridge/input boundary. Avoid platform-specific branching in
  the engine when an adapter can normalize input without changing semantics.

## State, ordering, and lifecycle rules

- Preserve the single Rust document authority and the active page/document
  binding. On page/project switches, stop or drain work at the existing
  boundary before rebinding; never allow queued packets or saves to target a
  newly selected document accidentally.
- Pointer packet v1 is a fixed-width little-endian contract. Keep confirmed
  sample ordering and delivery fail-closed: malformed packets, queue rejection,
  or bridge failures must not silently commit a partial stroke. Predicted
  samples remain ephemeral and must never enter saved pixels or undo history.
- Keep stroke bridge work serialized through `StrokeOperationQueue`. Preserve
  cancellation/recovery behavior so one failed operation cannot poison later
  strokes.
- Keep preview dabs until Rust/CPU acknowledgement or cancellation. Native live
  rendering is optional; bounded-queue backpressure must fall back to the CPU
  preview without interrupting input or losing confirmed samples. Do not wait
  for GPU work in the pointer callback or Flutter paint callback.
- Preserve command transaction boundaries, undo/redo grouping, page rebinding,
  dirty-tile revision checks, and save-before-close ordering. UI selection,
  autosave checkpoints, and document commits are distinct state transitions.
- `AutosaveCoordinator` defers checkpoints during active edits, coalesces
  mutations, and flushes without overlapping Rust saves. A failed checkpoint
  remains dirty and retryable. Finish its final checkpoint before closing the
  document engine; retire live surfaces tied to an old engine generation before
  registering replacements.
- Every controller, stream subscription, listener, timer, surface, and native
  handle needs one clear owner and a corresponding disposal path. Async
  completions must not update disposed widgets/controllers or a replaced
  document session.

## Rust practices

- Follow the Rust API Guidelines when designing public APIs: choose predictable
  names and argument order, use types that prevent invalid states, document
  public items and invariants, and consider interoperability and future
  evolution before making a new item public.
- Prefer borrowing when ownership need not move; avoid redundant clones and
  allocations, especially in render and input paths. Use iterators and
  straightforward control flow where they improve clarity; do not contort code
  for style points.
- Return typed, actionable errors from library and bridge code. Do not use
  `unwrap`, `expect`, or panics to handle malformed input, I/O, or expected
  runtime failures. A panic/assert is appropriate only for a true internal
  invariant that cannot be caused by user data or the environment.
- Fix Clippy warnings rather than suppressing them. Put any unavoidable lint
  allowance on the narrowest item and explain why it is safe or necessary.
- Workspace Rust code forbids unsafe by default. Keep unsafe interop confined
  to the existing Apple Metal boundary, with a local safety argument covering
  pointer validity, lifetime, ownership, and platform assumptions. Do not
  broaden an unsafe allowance or claim that generated FFI is handwritten.
- Keep dependencies conservative. Before adding a crate, establish why the
  standard library or an existing dependency is insufficient and consider
  compile time, maintenance, target support, and licensing.
- Keep tests deterministic and bounded. Exercise success, invalid input,
  failures, cancellation, recovery, persistence/reopen, and concurrency or
  queue boundaries where relevant. Benchmark changes on the actual hot path;
  do not infer rendering performance from engine-only timings.

## Dart and Flutter practices

- Follow Effective Dart and the repository's `app/analysis_options.yaml`.
  Prefer sound null safety, clear names, small public surfaces, `final` for
  stable state, immutable value objects for snapshots, and typed errors.
  Prefer `async`/`await`; catch only errors that the current boundary can
  meaningfully handle, and do not discard failures silently.
- Keep package imports canonical in tests (`package:project_ink/...`); within
  `lib/`, use the import style already established by the package. Never
  import through another package's private `src/` implementation.
- Put state at the narrowest owner. Prefer constructor injection for services
  and platform seams; keep test fakes behind the same contract as production.
  Do not add a state-management or utility dependency without an architectural
  need and a concrete maintenance benefit.
- Give each `State`, controller, notifier, stream subscription, and native
  resource an explicit lifecycle. Dispose only resources the object owns;
  remove listeners and close native capabilities in the established order.
- Keep `build`, `paint`, pointer callbacks, and frame callbacks cheap. Avoid
  file I/O, JSON parsing, image decoding, synchronous bridge work, large
  collection transforms, and avoidable allocations there. Move expensive CPU
  work off the UI isolate when profiling shows it blocks frames, while
  respecting ordering and data ownership.
- Reduce rebuild and repaint scope: use `const` where valid, stable keys,
  narrow listeners, and `CustomPainter.shouldRepaint` comparisons based on
  actual inputs. Avoid unnecessary opacity, clipping, `saveLayer`, and repeated
  shader/resource creation in frequently painted canvas content. Measure
  before and after any performance optimization.
- Preserve accessibility labels/semantics, keyboard and touch behavior,
  high-contrast themes, text scaling, and responsive layouts when changing
  controls. Update goldens only when the visual change is intentional and
  review the images; never refresh goldens merely to silence a failure.

## Bridge generation and wire formats

- Pin the Rust FRB runtime, Dart FRB runtime, and code generator to
  `2.13.0`. Edit exported Rust source, not generated files. From `app/`, run
  `../scripts/generate_frb.sh` with the pinned generator installed as described
  in `app/README.md`.
- Review generated Rust and Dart diffs together. Check adapter calls, error
  conversion, ownership/lifetime behavior, and native host interfaces. Run the
  bridge and engine tests after generation; generated code compiling alone is
  not proof of behavioral compatibility.
- Treat pointer packet v1, live-dab packets, `.inkproj`, command journals,
  comic sidecars, and export structures as versioned formats. Update the
  relevant specification, validation/compatibility behavior, fixtures, and
  round-trip or rejection tests for a format change.
- Diagnostic traces are device-local and never uploaded automatically. The
  canvas troubleshooting log is a rolling JSONL log capped at two 32 MiB
  segments. It may contain packet bytes, paths, errors, and artwork tile data;
  keep captured logs private, redact sensitive material before sharing, and do
  not add automatic upload or UI export without explicit product approval.
  Phase 1 latency traces are separately opt-in using
  `--dart-define=PROJECT_INK_TRACE=true` and the physical-device runbook.

## Validation workflow

Run focused tests first, then the broad checks appropriate to the change. Do
not claim a platform or physical-device gate passed from a host test or a
successful compile alone.

From the repository root:

```sh
cargo fmt --all -- --check
cargo test --workspace --all-targets --all-features
cargo clippy --workspace --all-targets --all-features -- -D warnings
```

From `app/`:

```sh
flutter analyze
flutter test
```

For the Apple build gates, use the pinned Flutter version and preserve existing
build caches. When disk is constrained, disable Rust debug symbols and
incremental compilation for the build rather than deleting caches:

```sh
CARGO_PROFILE_DEV_DEBUG=0 CARGO_INCREMENTAL=0 flutter build ios --debug --no-codesign
CARGO_PROFILE_DEV_DEBUG=0 CARGO_INCREMENTAL=0 flutter build macos --debug
```

These are compile gates; they do not replace a signed install or tablet
interaction run. Changes to platform input, live rendering, persistence, or
UI behavior require the relevant physical-device checks from
`specifications/physical-device-acceptance.md` and
`specifications/device-test-matrix.md`. Keep iOS/iPadOS and macOS results
separate from Android/Windows/Linux claims.

Retain the existing Rust performance guardrails: packet-to-dirty p95 no more
than 8 ms, four dirty fixture tiles, and less than 900 MB estimated
engine-owned memory. Use `specifications/phase1-benchmark.md`,
`specifications/live-render.md`, and the physical-device runbook for the
separate input-to-visible thresholds and measurement definitions. A passing
benchmark is meaningful only when its workload and environment match the
documented harness.

When reporting validation, distinguish: tests run and passed; checks not run;
host/device/platform; build-only versus installed interactive checks; and
known baseline failures. Include representative failure behavior when a change
touches error paths. Do not describe a partial or unavailable gate as passing.

## Git and delivery

- Keep commits focused and stage only task files. Preserve unrelated work in
  the checkout. Do not commit build output, local traces, device logs, or
  user-created project documents unless explicitly requested.
- Do not merge, push, publish, or change remotes unless the user explicitly
  requests it. When asked to push, verify the configured destination before
  sending local changes; never guess a remote from package metadata.
- Update the closest README, specification, or runbook when ownership,
  generation, diagnostics, validation, or developer workflow changes.

## Upstream references

- [Rust API Guidelines](https://rust-lang.github.io/api-guidelines/)
- [Apollo Rust best practices](https://github.com/apollographql/rust-best-practices)
- [rust-analyzer style guide](https://rust-analyzer.github.io/book/contributing/style.html)
- [Effective Dart](https://dart.dev/effective-dart)
- [Flutter performance best practices](https://docs.flutter.dev/perf/best-practices)
