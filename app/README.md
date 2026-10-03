# Flutter shell

The shell is intentionally thin: it owns responsive controls, viewport
transforms, gesture arbitration, accessibility, and visible tile composition.
The generated `flutter_rust_bridge` v2 bindings and Cargokit plugin provide the
production Rust adapter in `lib/bridge/engine_api.dart`; the in-memory adapter
is retained for isolated widget tests and shell seams. The production
`ProjectInkApp` never substitutes it: a Rust startup failure is shown to the
user instead of silently changing document authority.
Dirty tiles arrive through a fixed-width binary FRB packet, are decoded off the
paint path, and are composed into the transformed document canvas with
revision-aware caching.
On iOS/iPadOS, Android, and macOS, stylus-only native adapters publish packet v1
over `org.projectink.studio/pointer_packets_v1`; Dart transforms those
coordinates and routes them through the same Rust engine API.
The iOS, macOS, and Android adapter seams encode pointer packet v1 in
little-endian binary form. Keep the Rust engine as the only document/pixel
authority.

The Dart engine contract exposes native `.inkproj` open through
`FrbEngineApi.open(path)`, atomic save-as through `saveAs(path)`, and PNG
export through `exportPng(path)`. File-picker UI is intentionally kept outside
the engine adapter so each platform can select a directory-backed project
without duplicating document state.

`AutosaveCoordinator` is the local checkpoint seam for an open path. It
coalesces pointer/command mutations and defers checkpoints while a continuous
edit such as a stroke is active, avoiding a Rust bridge save during incoming
pointer packets. It resumes checkpoint scheduling when the last edit ends;
an explicit flush waits for active edits and never overlaps Rust saves. A save
error keeps the revision dirty so a later explicit flush can retry. The
production entry point always provides an app-owned recovery path under
`Project Ink/Recovery/` and reopens
that checkpoint on the next launch; an explicit Save still writes the named
portable project selected by the user. Embedders can pass a different
`autosavePath` to `ProjectInkApp` when they own the document session. Only the
production entry point supplies `recoveryDirectory`, which authorizes recursive
cleanup of its exact `last-session.inkproj` child. Custom paths are never deleted
implicitly; an embedder that wants cleanup must supply an explicit deletion
callback and enforce its own ownership boundary.

`DocumentPicker` is the platform seam for directory-backed project selection.
When supplied to `ProjectInkApp`, it enables Open, Save, and Export PNG toolbar
actions; the picker implementation owns platform storage and dialog behavior.
`PlatformDocumentPicker` is native-first: desktop uses native directory/save
dialogs, Android uses the native directory provider when it can return a local
path, and Android SAF/iOS Files project-open selections are staged into
app-owned storage before Rust opens them. Project saves use a transactional
provider replacement when a writable parent was granted, and completed PNG
exports use a bounded, collision-safe provider promotion under the same
capability. Changing picker UI will not change the Rust path contract.
On Android and iOS, new saves ask for a project name before the
directory-backed path is created; imported provider projects bypass that
prompt and retain their source name.

For local physical-device acceptance runs, pass a callback to
`ProjectInkApp.onPerformanceSnapshot`. It receives a bounded p95 trace from
normalized packet receipt to the post-frame callback, along with dirty-tile and
tile-update timings. To persist those snapshots for later review, also pass a
local `ProjectInkApp.performanceTracePath`; the app writes newline-delimited
JSON asynchronously and performs no network reporting.

The production entry point has an opt-in convenience path for device runs:
`flutter run -d DEVICE_ID --dart-define=PROJECT_INK_TRACE=true`. It stores a
timestamped JSONL file under the app Documents `phase1-traces/` directory.
Normal builds keep this disabled and do not create trace files.

For repeatable local iOS acceptance, use
specifications/ios-acceptance.md. The Acceptance Xcode scheme uses its own
bundle identifier and app container. Runner logs, traces, and XCTest results
use a local per-run folder; Flutter iOS build products use app/build/ios.
From the repository root, run app/tool/run_ios_acceptance.sh with
--preflight, --simulator, --device DEVICE_UDID, --pencil DEVICE_UDID, or
--full DEVICE_UDID. The full run pauses for human Apple Pencil steps and keeps
traces and artwork on the Mac. Simulated or injected stylus packets verify the
adapter/rendering path; only physical Pencil input completes the hardware
acceptance checks.

For a repeatable physical-iPad brush rendering check, pass the Procreate and
Clip Studio brush fixtures to `tool/run_brush_device_gallery.sh` from `app/`:

```sh
./tool/run_brush_device_gallery.sh DEVICE_UDID /path/to/sample.brush /path/to/sample.sut
```

The helper copies the supplied files into a dedicated app Documents folder,
imports them into a disposable Rust document, draws a touch stroke for each,
checks that authoritative Rust pixels changed, captures a gallery screenshot
under `build/brush-device-gallery/`, and restores a launchable iOS Profile app
snapshot captured before the test build can replace Flutter's shared Profile
output. It does not edit the user's current artwork. Touch pressure is
synthetic; use Apple Pencil manually for pressure, tilt, hover, and feel.

Run from this directory:

```sh
flutter pub get
flutter analyze
flutter test
flutter run -d macos
```

Run the first-release validation suite on macOS from any directory:

```sh
./app/tool/run_macos_alpha_checks.sh
```

The script requires Flutter 3.47.5 and runs analysis, the Flutter test suite,
and Rust-bridge disk-backed drawing/layer/brush/comic round trips. Logs and a
pass/fail summary go under
`app/build/macos-alpha-checks/` by default; override the location with
`PROJECT_INK_MACOS_ALPHA_RESULTS_DIR`. Use `--unit-only` to run analysis and
all Flutter unit/widget tests without rebuilding the desktop app,
`--native-live-texture` to run the separate Rust/Metal/Flutter texture smoke
test, or `--preflight-only` to inspect the toolchain, free disk space, and live
app processes. Full mode requires 6 GiB free by default and stops if a Project
Ink macOS process is running; it does not remove build outputs, caches, or app
data. Test project files go under a unique directory in the app's sandbox
container. The separate native texture test requires an available Metal
adapter; run it on a foreground macOS session. Override the free-space
threshold only when the machine has been reviewed for the planned build.

The integration suite includes pixel and layer save/reopen/undo/redo, edited
brush import, multi-page comic export, corrupt Open, and disk-backed failed
Save, recovery-write, and brush-import cases. It does not automate the AppKit
red window button or Cmd-Q with a dirty named project. Follow
[`specifications/macos-alpha-acceptance.md`](../specifications/macos-alpha-acceptance.md)
in a disposable app session and record Save, Discard, and Cancel outcomes.

## Code ownership and lifecycle

- `EngineApi` is the Dart-side contract. `FrbEngineApi` adapts the generated
  Rust API for production; `InMemoryEngineApi` supports isolated tests.
- `ComicWorkspaceController` owns its Rust project handle. Dispose the
  controller when the workspace session ends so it closes that capability.
  Widgets that listen to the controller remove their listener and dispose
  their own text and animation controllers in `dispose`.
- `CanvasScreen` is the composition and lifecycle point. The independent
  `CanvasDocumentActions` owns file/document workflows through its explicit
  `CanvasDocumentActionHost`; it depends on the narrow
  `CanvasDocumentActionSession` contract rather than importing the screen.
  Native close/quit unsaved-change decisions stay there, while the screen owns
  method-channel registration and supplies reply/error callbacks.
  `CanvasLayerActions` owns Rust-backed
  layer commands, selection transitions, solo state, opacity transactions, and
  ordered panel-state persistence through `CanvasLayerActionHost`.
  `CanvasLayerProjectionService` converts Rust layer summaries into immutable
  presentation snapshots and owns the bounded thumbnail cache.
  `CanvasLayerPresentationState` owns projected layers, transient selection and
  solo state, generation-bound panel restoration, and applies the pure
  `CanvasLayerSelectionReconciliation` result; the screen publishes changes
  and queues repairs.
  `CanvasStrokeAutosaveHold` pairs continuous-edit begin/finish transitions
  across Flutter and native stroke paths; the screen supplies autosave and
  queue observations and selects the finish reason at each lifecycle edge.
  `CanvasStrokeStartCoordinator` orders pending brush edits, validates the
  active raster layer, and begins strokes through an explicit host.
  `CanvasDanglingStrokeFinalizer` drains accepted input and finishes a
  dangling stroke before brush edits, then publishes its local reset and
  projections.
  `CanvasStrokeCompletionCoordinator` shares terminal reset, preview,
  autosave, and refresh ordering between Flutter and native pointer paths.
  `CanvasStrokeCancellationCoordinator` owns Rust cancellation failures and
  shared preview/autosave cleanup. `CanvasTouchStrokeCancellationCoordinator`
  owns the queued touch ownership guard so touch cannot cancel a later Pencil
  stroke before delegating common cleanup.
  `CanvasDrawAndHoldCoordinator` owns the stylus quiet timer and only dispatches
  after rechecking a screen-provided stroke and native-queue snapshot.
  `CanvasLivePreviewFrameDiagnostics` coalesces immutable preview snapshots at
  frame boundaries and owns the optional input-to-visible trace update.
  `CanvasEditorAuxiliaryOverlays` composes focus, tablet/desktop rail,
  selection, and quick-menu controls from a presentation snapshot and callbacks.
  `CanvasWorkspacePalette` routes dock tabs and composes properties, color,
  materials, Quick Access, and History from an immutable snapshot and action
  port; existing session-backed palette builders remain lazily supplied by the
  screen.
  `CanvasNativeInputSubscriptions` owns native stream forwarding, readiness,
  channel errors, and cancellation; the screen chooses platform streams and
  ties the owner to route disposal.
  `CanvasInputReplacementCoordinator` resets transient Flutter/native input
  state before the document barrier drains accepted work, cancels an active
  stroke, flushes recovery, and permits replacement.
  `canvas_workspace_panel_sheets.dart` composes Quick Access, History, and
  focus quick-control sheets from explicit preference/engine/brush snapshots
  and callbacks; the screen retains command dispatch, history navigation, and
  preference writes.
  `CanvasToolPaletteContent`, `CanvasBrushPaletteContent`, and
  `CanvasComicPaletteContent` provide shared docked/floating presentation while
  delegating brush mutations and document actions to their existing owners.
  `CanvasWorkspacePanelActions` resolves panel selection and coordinates sheet,
  dock, and floating-panel transitions through an explicit state/effect host.
  `CanvasEditorActionRouter` preserves shared command precedence across the
  document, history, tool, brush-color, viewport, and workspace owners.
  `CanvasLayerPanelContent` composes the layer panel and vector inspector from
  the Rust-backed layer/vector action services and immutable screen snapshots.
  `TouchGestureTracker` owns transient touch pointer bookkeeping, long-press
  timing, and gesture classification; `CanvasScreen` maps emitted gestures to
  editor actions, while `CanvasTouchStrokeCancellationCoordinator` owns the
  queued drawing-stroke cancellation guard.
  `NativePointerPacketQueue` owns buffered packet order and safe move
  compaction. `NativePencilInputCoordinator` owns drain scheduling and
  serialized packet failure recovery while receiving the screen's ordered
  stroke queue, stroke operation, and cancellation operation explicitly.
  `NativePencilStrokeCoordinator` owns native Pencil packet-to-Rust stroke
  ordering and commit/cancel decisions through a host; the screen adapts shared
  preview and autosave state, and Rust clips committed pixels.
  `NativePencilInputCoordinator` owns native contact filtering, packet
  adaptation, confirmed-preview scheduling, bounded queue dispatch, and
  serialized native-packet failure recovery.
  `FlutterPointerStrokeCoordinator` owns Flutter pointer-to-Rust delivery and
  terminal decisions through a separate host; preview construction is owned by
  `CanvasStrokePreviewActions`, while viewport presentation has its own surface.
  `CanvasComicPanelActions` owns panel geometry translation and clipping
  against the active canvas document through an explicit session host.
  `CanvasComicWorkspaceNotifications` owns comic workspace listener lifetime
  and coalesced frame updates, while the screen supplies page and workspace
  selection effects.
  `CanvasDockActions` owns desktop dock width, collapse/expand, tab movement,
  group resizing, and persistence using workspace preference and state-update
  seams supplied by the screen.
  `CanvasWorkspaceDockState` owns local dock values and preference hydration,
  including initialization, workspace rebinds, and layout application.
  `CanvasDesktopDock` owns dock presentation and palette drag targets;
  `CanvasDesktopDockRegion` owns left/right placement and resize hit-target
  geometry; `CanvasDesktopWorkspaceChrome` places the desktop status bar and
  collapsed-dock controls. `CanvasDesktopWorkspace` composes both dock sides
  from immutable snapshots and a callback action port. The screen persists
  widths and dock-state changes.
  `CanvasWorkspaceLayoutActions` owns workspace selection and follow-document
  preference transitions, returning immutable `WorkspaceDockSelection` values;
  the screen applies them to its view state.
  `resolveCanvasWorkspaceFrame` in `canvas/workspace_dock_layout.dart` projects
  explicit platform, viewport, preference, and dock snapshots into dock
  visibility and widths, tablet modes, and native-menu eligibility.
  `shouldUseWideDesktopLayout` owns pure platform/width thresholds; the screen
  reads inherited media and workspace mode, then composes the immutable frame.
  `canvasWorkspacePanelForAction` maps shared editor IDs to panel names, and
  `selectCanvasWorkspacePanel` owns pure compact, Studio, and desktop dock
  selection policy; the screen owns sheet presentation and preference writes.
  `CanvasToolEventCoordinator` owns pointer sampling and command dispatch for
  non-brush selection, transform, fill, and ruler tools, plus selection
  mutation commands, along with transient tool-start, target-layer, sampled
  point, and ruler state. It delegates vector stroke mutations to
  `CanvasVectorActions` through `CanvasVectorToolOperations`. The screen reads
  preview/ruler snapshots and resets pointer-path state at tool and engine
  changes; selection geometry remains screen presentation state.
  `CanvasHistoryActions` owns the serialized undo/redo boundary and history
  navigation refresh ordering through explicit engine, queue, autosave, and
  projection callbacks.
  `CanvasStrokePreviewActions` owns transient Flutter/native preview assembly,
  confirmed sequence mapping, bounded chunk compaction, page-edge clipping,
  and CPU-covered retirement. `CanvasLiveStrokePreviewInput` owns confirmed
  input ordering for diagnostic capture, GPU pending signals, and preview
  begin/append routing. The screen supplies document/brush snapshots and
  coordinate callbacks; saved pixels and history remain Rust-owned.
  `CanvasPointerEventRouter` owns Flutter event filtering and dispatch order
  behind an explicit host, plus pointer-ID tracking and reset for Pencil
  takeover or document replacement; coordinate transforms, native adaptation,
  and the ordered bridge queue keep their existing owners.
  `CanvasBrushProjection` owns asynchronous brush summary mapping, local
  preference restoration, and stale engine/request rejection.
  `CanvasViewportSurface` owns canvas painting and gesture hit testing from an
  immutable paint snapshot. `projectVisibleTileEntries` owns current-revision
  composite preference, visible-raster fallback, and deterministic tile
  ordering from explicit cache and layer inputs. `CanvasViewportController` owns
  transform math, scale-gesture baselines, and state-independent viewport
  command routing; the screen supplies bounds and rebuild scheduling.
  `CanvasInputCoordinatePolicy` owns safe input bounds and explicit ruler
  projection from active-tool and ruler snapshots.
  `CanvasStrokeConstraintController` owns the temporary straighten/constrain
  mode and stroke-local projection state.
  `CanvasGestureCoordinator` owns touch-contact tracking and maps configured
  gestures to shared editor commands through an explicit host.
  `showCanvasClipboardPalette` owns the async sheet/clipboard flow and delegates
  pasted colors through the injected brush-color action;
  `CanvasClipboardPalette` owns typed commands and RGB text conversion.
  `CanvasColorSampler` reads composited BGRA tiles with a primary-raster
  fallback. `CanvasColorSamplingCoordinator` maps and applies the sample
  through `CanvasBrushActions` before publishing the mounted UI projection.
  `CanvasWorkspaceOverlays` owns generic floating-panel placement and
  semantics; `CanvasFloatingWorkspacePanels` owns the canvas panel metadata and
  maps close actions to visibility snapshots. The route owns that snapshot and
  composes the panel contents. `CanvasWorkspacePresentationController`
  owns transient focus-mode, quick-menu, floating-panel state, and per-tablet-
  mode palette memory; the screen publishes updates and retains preference,
  route, and child lifecycles.
  `CanvasFloatingPanelVisibility` is the immutable value owner for compact and
  tablet floating-panel visibility transitions.
  `CanvasWorkspaceEditorActions` owns workspace rename, deletion, save-as,
  reset, and command-bar editing workflows through an explicit host; dock
  presentation state remains screen-owned.
  `CanvasBrushActions` owns the session-wide foreground color sent to Rust for
  subsequent strokes; changing it does not edit a brush preset or dirty the
  document. Brush preset colors remain available as their saved base values.
  `CanvasBrushColorActions` sequences selection, clipboard paste, swap, reset,
  and recent-color policy through explicit callbacks and routes swap/reset
  editor commands, and owns picker result handling with `BuildContext` supplied
  at each call; the screen retains color projections.
  The native macOS menu is built from shared action IDs in
  `canvas_macos_application_menu.dart`, while document-action availability is
  shared between it and the top bar.
  `buildCanvasEditorShortcutBindings` keeps keyboard bindings in a focused
  action-routing module while dispatch and screen lifecycle remain screen-owned.
  `CanvasInputSettingsController` owns gesture/navigation and large-control
  state with its async dialog lifecycle. The dialogs own temporary form state;
  dock state retains handedness and workspace actions persist it.
  The remaining `CanvasScreen` boundaries and their extraction order are tracked
  in `specifications/canvas-screen-decomposition.md` at the repository root.
  `CanvasPreviewSynchronization` is an
  independent lifecycle service for native
  surfaces, preview commit handoff state, and ephemeral preview picture
  retirement, supplied with engine and viewport snapshots by the screen.
  `CanvasTileSynchronization` owns CPU tile
  caches, render revision, pending preview acknowledgements, commit-batch
  sequencing, and its periodic fallback poll behind an explicit
  `CanvasTileSynchronizationHost`. It retires decoded images when the engine
  changes so pending decodes cannot publish into the replacement session;
  its host returns immutable `CanvasTileSynchronizationSnapshot` values with
  visible raster IDs, packet timing, and queue depths rather than exposing full
  layer models or queue objects. Preview lifecycle and the narrow preview-acknowledge
  action port plus canvas publication/performance effects are injected
  separately from the read-only state host. The effects port does not expose
  the full trace object. A
  `CanvasTileSynchronizationSession`
  captures engine identity/generation, which the host validates after awaits.
  Diagnostics are injected separately from the state host. Input and history
  paths still request immediate refreshes.
  `CanvasCompositeTileSnapshotReader` owns bounded
  multipart reads and revision-coherence validation.
  `CanvasCpuAcknowledgementBatch` owns acknowledgement-atomic snapshot
  selection and dirty-tile deduplication.
  `NativePointerPacketAdapter` owns native
  packet validation, coordinate translation, sequence insertion, and confirmed
  sample extraction while receiving the canvas transform and sequence source
  explicitly. `CanvasTilePainter` and `CanvasOverlayPainter` are independent presentation
  libraries with explicit inputs; quick controls, color-picker controls,
  tool rails, history projection, color palette, status/selection widgets,
  quick access, top bar, command search, and document form dialogs are also
  independent widgets. `showCanvasCommandSearch` owns selected-action dispatch
  with explicit mounted and dispatch inputs. Desktop dock rendering and drag/drop are in their own
  callback-driven component library, as are compact canvas controls and tool
  panel decoration. `CanvasBrushActions` owns brush edit drafts, serialized
  settings writes, preview thumbnail caching, and quick-size persistence
  through an explicit `CanvasBrushActionHost`; the screen retains active
  selection, color projections, and stroke state. `CanvasBrushColorDialog`
  owns temporary HSV, RGB, and alpha selection and returns the chosen color;
  `CanvasBrushColorActions` presents the picker, drains active input, updates
  the color projection, applies recent-color policy, then delegates the Rust
  mutation. Callers supply `BuildContext` per invocation.
  `CanvasCommandBarEditorDialog`
  owns its temporary command selection and returns the edited value on Save.
  `StrokeOperationQueue` owns ordered
  bridge work and error recovery. Keep page
  rebinding, undo/history, autosave, and preview-to-CPU fallback semantics at
  their existing seams.
- `DocumentReplacementBarrier` blocks new input, drains accepted packets,
  cancels an unfinished stroke, and flushes recovery before replacement.
  Preparation failure releases the input gate and preserves the current
  document.
- `AutosaveCoordinator.dispose()` must finish its final checkpoint before the
  Rust document engine is closed. Retire a live surface before registering a
  replacement surface; its native handle is tied to the old engine generation.
- Comic presentation painters and summaries are stateless projections of Rust
  view types. They do not own project state or mutate the document.

## Flutter Rust Bridge generation

The Rust runtime and Dart runtime are pinned to flutter_rust_bridge 2.13.0.
Generated files are checked in under `rust/crates/ink-bridge/src/` and
`app/lib/bridge/generated/`; edit `api.rs`, never generated files. Install the
matching generator with `cargo install flutter_rust_bridge_codegen --version
2.13.0 --locked`, then run `../scripts/generate_frb.sh` from this directory.
Review the complete generated diff after changing exported Rust signatures,
and keep the generated Rust/Dart API, `api.dart` adapter calls, and platform
native-host interfaces in sync. Do not upgrade only one runtime package or
regenerate with an unpinned global generator.
