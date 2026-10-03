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
- Recursive recovery deletion is allowed only for `last-session.inkproj` under
  the trusted app recovery directory. A custom `autosavePath` is not a trusted
  deletion root; hosts that own such a path must provide an explicit deletion
  callback with their own safety checks.

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
  `CanvasDocumentActions` is an independent controller with an explicit
  `CanvasDocumentActionHost` and routes file/document action IDs to its own
  workflows, including native close/quit unsaved-change decisions. It depends
  on the narrow `CanvasDocumentActionSession` contract rather than importing
  the screen. The screen retains method-channel registration and reply/error
  adapters.
  `CanvasLayerActions` owns Rust-backed layer
  commands, selection updates, opacity transactions, solo state, and serialized
  layer-panel persistence through `CanvasLayerActionHost`; keep screen state
  access behind that host. `CanvasLayerProjectionService` converts Rust layer
  summaries into immutable presentation snapshots and owns bounded thumbnail
  caching. `CanvasLayerPresentationState` owns the projected layers, transient
  selection/solo state, generation-bound panel restoration, and selection
  reconciliation; the screen publishes updates and queues persistence.
  `CanvasWorkspaceLayoutActions` owns device-local
  workspace preference updates, built-in/custom layout resolution, dock-width
  persistence, workspace selection/follow preference transitions, and palette
  mappings through `CanvasWorkspaceLayoutHost`; it returns immutable
  `WorkspaceDockSelection` values but does not own active dock presentation
  state. `CanvasWorkspaceDockState` owns
  device-local dock widths, groups, tabs, collapse flags, handedness, and
  preference hydration/rebinds; the screen publishes controller transitions.
  `CanvasToolActions` owns
  raster selection/fill/transform workflows through explicit engine, selection,
  layer, and UI callbacks. `canvas_workspace_panel_sheets.dart` owns the
  Quick Access, History, and focus quick-control sheet composition and accepts
  explicit preference/engine/brush snapshots and action callbacks; the screen
  retains command dispatch, history navigation, and preference persistence.
  `CanvasDesktopWorkspace` composes desktop docks, status chrome, and collapse
  affordances from immutable snapshots and a callback action port; the screen
  and workspace action owners retain dock state and preference persistence.
  `CanvasToolPaletteContent`, `CanvasBrushPaletteContent`, and
  `CanvasComicPaletteContent` adapt shared screen-owned actions to reusable
  tool, brush, and comic palette widgets for both docked and floating layouts.
  `CanvasWorkspacePanelActions` owns the sheet/dock/floating-panel routing
  transitions from an immutable selection snapshot; its host keeps Flutter
  state publication, preference writes, and route presentation explicit.
  `CanvasEditorActionRouter` owns shared command precedence across document,
  history, tool, color, viewport, and workspace owners; keep its dispatch order
  covered by tests and leave screen lifecycle effects behind host callbacks.
  `CanvasPreviewSynchronization`
  independently
  owns native preview lifecycle, viewport sync, ephemeral preview picture
  retirement, and CPU handoff acknowledgement state through explicit engine
  and viewport inputs. `CanvasTilePainter`
  and `CanvasOverlayPainter` consume explicit immutable paint inputs,
  `CanvasColorWheel` and `CanvasColorSquare` own their color-picker gestures,
  `CanvasQuickControls`/`CanvasColorSwatch` own callback-driven toolbar
  presentation; `EditorActionMenu`, `DesktopToolRail`, and
  `TabletStudioToolRail` are independent controls; and `NewDocumentDialog`/
  `ProjectNameDialog` own their form state. The
  `CanvasQuickAccessPanel` owns only its local selected-set projection and
  sends changed sets and actions to its host callbacks. The
  `CanvasColorPalettePanel` receives color projections and action callbacks.
  `CanvasHistoryPanel` owns its asynchronous history projection through an
  explicit engine, revision token, and navigation callback;
  `CanvasHistoryActions` owns undo/redo queue ordering, history navigation,
  autosave marking, and projection refresh sequencing through an explicit host.
  Status-bar and
  selection-toolbar widgets are callback/value driven. The
  `CanvasTileSynchronization` owns CPU byte and decoded-image caches, render
  revision, tile publication, pending preview acknowledgements, commit-batch
  sequencing, and its periodic fallback poll. Engine replacement resets its
  revision and byte cache and retires the decoded-image cache so an in-flight
  decode cannot publish into the next engine generation. Its host contract
  supplies visible raster IDs and queue depths, not layer models or queue
  objects. Preview lifecycle and the narrow acknowledgement/retirement action
  port and UI effects are constructor-injected separately from the read-only
  state host. The effects port publishes canvas state and reports visible
  updates; it does not expose the full trace object. Cache and render-revision
  state remain internal. `CanvasTileSynchronizationHost.captureSnapshot()`
  returns an immutable `CanvasTileSynchronizationSnapshot` for visible raster
  IDs, packet timing, and queue depths at the point each refresh decision needs
  them; do not expose layer models or queue owners. The host captures engine
  identity and generation as `CanvasTileSynchronizationSession` and validates
  that token after asynchronous boundaries. Diagnostics are
  constructor-injected outside the state host. Input and history paths still
  request immediate refreshes.
  `CanvasCompositeTileSnapshotReader`
  owns bounded multi-part tile reads and revision-coherence validation.
  `CanvasCpuAcknowledgementBatch` owns the pure dirty-tile deduplication and
  acknowledgement-atomic batch-selection policy;
  `projectVisibleTileEntries` selects current composite or visible raster images
  and orders them deterministically from explicit tile and layer snapshots;
  the screen adapts its engine/session state and rendering callbacks.
  `TouchGestureTracker` owns transient touch pointer bookkeeping, long-press
  timing, and gesture classification; `CanvasScreen` maps emitted gestures to
  editor actions, while `CanvasTouchStrokeCancellationCoordinator` owns the
  queued drawing-stroke cancellation guard.
  `NativePointerPacketQueue` owns buffered native packet ordering and move-only
  compaction. `NativePencilInputCoordinator` owns drain scheduling, serial
  packet failure logging, and stroke recovery; the screen supplies the ordered
  stroke queue and the native stroke operation.
  `NativePencilStrokeCoordinator` owns native Pencil packet-to-Rust stroke
  ordering, pressure/edge diagnostics, and commit/cancel decisions through an
  explicit host. The screen adapts shared preview, autosave, and lifecycle
  state; Rust remains responsible for clipping committed pixels.
  `NativePencilInputCoordinator` owns contact filtering, native packet
  adaptation, confirmed-preview scheduling, the bounded packet queue, and
  failure recovery for serialized native packets. The screen provides position
  transforms, preview presentation, and its stroke-cancellation operation
  explicitly.
  `FlutterPointerStrokeCoordinator` owns ordered Flutter pointer-to-Rust
  delivery and terminal decisions behind its own explicit host. Preview
  construction and presentation remain screen-owned.
  `CanvasComicPanelActions` maps Rust comic panel projections to the active
  canvas document, materializes panel layer trees, and applies/removes panel
  clipping; it receives workspace, layer, and selection operations explicitly.
  `CanvasComicWorkspaceNotifications` owns the workspace listener and
  frame-coalesced change handling; the screen supplies page-selection cleanup,
  rebuild, and follow-document workspace effects.
  `CanvasDockActions` owns dock width changes, collapse/expand transitions,
  tab movement, group resizing, and persistence through explicit state and
  preference callbacks. `CanvasScreen` supplies the dock-state adapter and
  wraps state mutations for widget publication.
  `CanvasWorkspaceLayoutActions` owns workspace-selection and follow-document
  preference transitions and returns immutable dock-selection values; the
  screen applies them to view state.
  `resolveCanvasWorkspaceFrame` in `workspace_dock_layout.dart` projects
  explicit platform, viewport, preference, and dock snapshots into per-frame
  dock visibility, effective widths, tablet modes, and native-menu eligibility.
  `shouldUseWideDesktopLayout` owns the pure platform/logical/physical width
  thresholds; the screen resolves inherited media and workspace mode, then
  composes the resulting frame. These projections own no mutable state.
  `CanvasLayerPanelContent` composes layer and vector presentation from the
  existing action services; it does not own Rust document state.
  `CanvasBrushActions.updateActiveBrushColor` is the single owner for active
  brush color writes and successful autosave dirty marking; color UI state and
  recent-color sequencing is owned by `CanvasBrushColorActions` through an
  explicit host. It owns picker result handling and receives `BuildContext` at
  the call site; the screen owns visible color projections.
  `CanvasToolEventCoordinator` owns pointer sampling and Rust command dispatch
  for selection, transform, fill, and ruler tools, plus selection mutation
  commands. It delegates vector stroke mutations to `CanvasVectorActions` via
  `CanvasVectorToolOperations`. It owns transient tool-start, target-layer,
  sampled-point, and ruler state; the screen reads preview/ruler snapshots for
  painting and coordinate snapping and resets pointer-path state when the tool
  or engine changes. Shared selection geometry and dialogs remain explicit
  host/action-service inputs.
  `CanvasStrokePreviewActions` owns ephemeral Flutter/native preview point
  assembly, sequence-to-preview mapping, chunk compaction, page-edge clipping,
  and CPU-covered retirement; the screen supplies brush/document snapshots and
  coordinate policy, while Rust remains authoritative for committed pixels.
  `CanvasLiveStrokePreviewInput` sequences start/sample signaling around that
  owner and the optional live GPU surface; keep pointer callbacks free of waits.
  `CanvasPointerEventRouter` owns Flutter pointer filtering and dispatch order
  across sampling, tools, touch navigation, and serialized stroke work through
  an explicit host, plus active pointer-ID tracking and reset operations during
  Pencil takeover and document replacement. `CanvasLiveStrokePreviewInput`
  owns the diagnostic, GPU
  pending signal, and preview begin/append order for confirmed input. Keep
  transforms and native adapter policy at the screen/platform boundaries.
  `CanvasViewportSurface` owns the canvas render stack and gesture surface from
  an immutable paint snapshot. `CanvasViewportController` owns transform math,
  the active scale-gesture baseline, and state-independent viewport command
  routing; the screen obtains bounds, binds the document, and schedules
  rebuilds. `CanvasInputCoordinatePolicy` owns
  explicit screen-to-document ruler projection and safe/bounded input rules.
  `CanvasStrokeConstraintController` owns per-stroke straighten/constrain state
  and projects sampled positions without depending on widget state.
  `CanvasGestureCoordinator` owns touch-tracker timing and gesture-to-command
  mapping; `CanvasTouchStrokeCancellationCoordinator` owns queued touch-stroke
  cancellation, and the screen supplies command effects.
  `showCanvasClipboardPalette` owns the sheet/clipboard async flow and dispatches
  pasted colors through the injected brush-color action; the palette owns its
  typed commands and RGB text encoding.
  `CanvasColorSampler` owns document-bounds checks and BGRA tile sampling;
  `CanvasColorSamplingCoordinator` maps the sample, applies it through the
  brush action service, then publishes its UI projection after success.
  `CanvasBrushColorActions` owns apply/swap/reset sequencing, swap/reset command
  routing, and recent-color policy while preserving the pointer-up drain and
  bridge write order.
  `CanvasWorkspaceOverlays` owns generic panel placement and semantics;
  `CanvasFloatingWorkspacePanels` owns canvas panel metadata and translates
  close actions into immutable visibility updates. The route owns the visibility
  controller and composes child content. `CanvasWorkspacePresentationController` owns
  the route's transient focus mode, quick-menu visibility, floating-panel
  snapshot, and per-tablet-mode palette memory; the screen publishes changes
  with `setState` and retains preference persistence, panel content, and route
  lifecycle. `CanvasFloatingPanelVisibility` owns the
  immutable panel visibility value and compact-versus-exclusive transition
  rules.
  `canvasWorkspacePanelForAction` maps panel commands to workspace panel IDs;
  `selectCanvasWorkspacePanel` resolves dock routing and mobile sheet intent
  from layout snapshots. `CanvasScreen` performs UI and persistence effects.
  `CanvasBrushProjection` owns async Rust brush-summary mapping, local brush
  preference restoration, stale-request rejection, and active-brush projection.
  `CanvasWorkspaceEditorActions` owns workspace editing dialogs and preference
  changes through explicit preference, dock snapshot, and screen-update inputs;
  active dock presentation remains with `CanvasScreen`.
  `buildCanvasMacOSApplicationMenus` builds the native macOS menu from shared
  `EditorActionId` values and shortcuts; `isEditorActionDisabled` is the common
  UI availability rule used by both the menu and top bar.
  `buildCanvasEditorShortcutBindings` owns the Flutter shortcut map and sends
  selected actions through the screen's existing command registry.
  `CanvasInputSettingsController` owns gesture/navigation and large-control
  settings plus the async dialog/result lifecycle. The settings dialogs own
  temporary form state; the screen supplies the mounted/rebuild boundary, while
  handedness remains with dock state and is persisted by workspace actions.
  `CanvasTopBar` receives document/workspace projections and action callbacks
  without reaching into the canvas state. `CanvasCommandSearchDialog` owns its
  query and returns a selected editor action; `showCanvasCommandSearch` owns
  the dialog result lifecycle and dispatches through an injected action handler.
  `CanvasDesktopDock` owns dock rendering and palette drag targets;
  `CanvasDesktopDockRegion` owns left/right placement and resize hit targets,
  while the screen persists the resulting width and layout changes.
  `CanvasDesktopWorkspaceChrome` places the status bar and collapsed-dock
  affordances from the immutable workspace frame and explicit collapse state.
  `CanvasBrushActions`
  owns brush edit drafts, serialized settings writes, preview thumbnail
  caching, and quick-size persistence through an explicit
  `CanvasBrushActionHost`; the screen retains active selection, color
  projections, and stroke state. `CanvasBrushColorDialog` owns temporary HSV,
  RGB, and alpha selection and returns the chosen color;
  `CanvasBrushColorActions` owns picker result handling, flush/publish/bridge
  sequencing, and recent-color policy through an explicit host. The picker
  context is passed per call instead of being retained by the action host.
  `CanvasCommandBarEditorDialog` owns its
  temporary command selection and returns the edited value on Save.
  `CanvasSimpleEdgeControls`, `CanvasFocusQuickControls`, and
  `CanvasQuickMenu` receive brush/color snapshots and callbacks; panel
  decoration is isolated in `CanvasToolPanel`.
  `CanvasWorkspacePalette` owns dock tab routing and properties, color,
  materials, Quick Access, and History composition through a snapshot/action
  port; screen-backed tool, brush, comic, and layer builders are lazy inputs.
  `StrokeOperationQueue` owns ordered bridge work.
- `CanvasStrokeAutosaveHold` owns the idempotent continuous-edit hold used by
  Flutter and native stroke paths. The screen supplies autosave effects and
  queue observations and ends the hold at stroke, replacement, and disposal
  boundaries.
- `CanvasStrokeStartCoordinator` owns brush-edit wait ordering and raster
  target validation before Rust stroke creation. Keep the active engine,
  selection, autosave hold, and user-facing error presentation behind its
  explicit host callbacks.
- `CanvasDanglingStrokeFinalizer` drains accepted input and finalizes a
  dangling Rust stroke before brush edits, then resets local state and
  publishes autosave and projection updates.
- `CanvasStrokeCompletionCoordinator` owns common Flutter/native terminal
  reset and preview/autosave refresh ordering while preserving source-specific
  diagnostics and native-contact cleanup.
- `CanvasStrokeCancellationCoordinator` owns failure recovery and shared local
  cancellation cleanup. `CanvasTouchStrokeCancellationCoordinator` owns the
  touch marker and serialized active-touch ownership check before requesting
  shared cleanup, so a queued touch cancel cannot cancel a later Pencil stroke.
- `CanvasDrawAndHoldCoordinator` owns stylus quiet-interval timing and rechecks
  the stroke, constraint, latest position, and native queue snapshot before
  dispatching the configured gesture. The screen supplies snapshots and owns
  disposal with the route.
- `CanvasLivePreviewFrameDiagnostics` coalesces post-frame preview metrics and
  optional input-to-visible samples. It consumes an immutable snapshot and is
  disposed with the route; keep trace meanings distinct from GPU completion or
  display scan-out.
- `CanvasEditorAuxiliaryOverlays` owns presentation for focus controls,
  tablet/desktop tool rails, selection actions, and the quick menu from an
  immutable snapshot and explicit callbacks. Keep editor command dispatch and
  lifecycle effects with `CanvasScreen` and the relevant action owners.
- Document replacement runs through `DocumentReplacementBarrier`: block new
  Flutter and native input, drain accepted bridge work, cancel any unfinished
  stroke, flush recovery, then replace the engine. If preparation fails, do not
  replace the current document.
- Keep platform input translation in the native adapters and wire-format
  decoding at the bridge/input boundary. Avoid platform-specific branching in
  the engine when an adapter can normalize input without changing semantics.
- Keep Flutter pressure normalization in `CanvasPointerPressurePolicy` and
  native Pencil normalization in its adapter; test platform fallbacks at the
  input boundary before changing the pointer packet contract.
- `CanvasNativeInputSubscriptions` owns native stream listeners and readiness
  state. `CanvasScreen` selects the platform channels, forwards events to the
  pointer coordinator, and disposes the subscription owner with the route.
- `CanvasInputReplacementCoordinator` retires transient Flutter/native input
  state before `DocumentReplacementBarrier` drains accepted input and replaces
  a document. The screen supplies those concrete effects; keep preparation,
  barrier, and replacement ordering covered by the coordinator tests.

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
