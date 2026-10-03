# Canvas screen decomposition

## Goal

Keep `CanvasScreen` as the route-level lifecycle and composition point while
moving cohesive policy and state transitions into independent libraries with
explicit input and ownership boundaries. Do not reduce line count by moving
private methods into more `part` files.

Rust remains the document authority. Flutter owns input translation, gesture
arbitration, transient presentation state, and canvas composition. Preserve
pointer packet ordering, stroke cancellation and recovery, autosave holds,
preview-to-CPU fallback, tile acknowledgement, page binding, and document
replacement barriers throughout the decomposition.

## Current boundaries

The following responsibilities already have independent owners and explicit
hosts or values:

- Document workflows, including native close/quit unsaved-change decisions:
  `CanvasDocumentActions` depends on the narrow
  `CanvasDocumentActionSession` contract rather than importing the screen;
  the screen implements the session contract and retains only native
  method-channel registration and reply/error adapters.
- Rust-backed layer commands and panel persistence: `CanvasLayerActions`.
- Undo, redo, and history navigation ordering plus projection refresh:
  `CanvasHistoryActions`, with explicit engine, stroke-queue, autosave, and
  projection callbacks. The screen retains lifecycle and panel composition.
- Layer summary projection and thumbnail cache: `CanvasLayerProjectionService`;
  projected layer presentation, transient selection/solo state, and generation-
  bound panel-state restoration: `CanvasLayerPresentationState`.
- Layer list and vector inspector composition:
  `CanvasLayerPanelContent`, using existing Rust-backed action owners.
- Native preview lifecycle and CPU tile publication: `CanvasPreviewSynchronization`
  owns native surfaces, preview picture retirement, and CPU handoff state;
  `CanvasTileSynchronization` owns its periodic
  fallback poll, pending CPU/live acknowledgement queues, and commit-batch
  sequence; it cancels the poll and clears its queues when the route releases
  the owner. The route supplies refresh-time layer visibility, packet timing,
  and queue-depth values through immutable `CanvasTileSynchronizationSnapshot`
  instances instead of independent mutable getters. `CanvasCompositeTileSnapshotReader` owns bounded multi-part reads
  and rejects snapshots assembled across different Rust revisions.
  `CanvasCpuAcknowledgementBatch` owns the policy for deduplicating dirty tiles,
  preserving acknowledgement atomicity, and allowing progress for one oversized
  commit. Input and history paths continue to request immediate refreshes.
- Flutter and native pointer delivery: `FlutterPointerStrokeCoordinator`,
  `NativePencilStrokeCoordinator`, and `NativePencilInputCoordinator`. Native
  queue drain failures are logged and recovered inside the input coordinator;
  the route supplies the existing serialized stroke operation and cancellation
  owner.
- Confirmed stroke-preview input ordering:
  `CanvasLiveStrokePreviewInput` owns preview begin/append routing plus the
  diagnostic and GPU pending signals around pointer samples. It delegates point
  assembly and sequence mapping to `CanvasStrokePreviewActions`; the screen
  supplies current surface/active state and callbacks.
- Stroke autosave hold lifecycle: `CanvasStrokeAutosaveHold` owns idempotent
  continuous-edit begin/finish transitions and records the queue-depth
  diagnostics supplied by the screen. The screen still chooses the finish
  reason at each stroke, replacement, cancellation, and disposal boundary.
- Brush-stroke start ordering: `CanvasStrokeStartCoordinator` persists pending
  quick-size changes, waits for an in-flight brush edit, validates the selected
  visible raster target, and begins the Rust stroke through explicit callbacks.
  The screen owns the snackbar presentation and supplies the active session.
- Dangling stroke finalization before brush edits:
  `CanvasDanglingStrokeFinalizer` drains already accepted pointer work, asks
  Rust to finish a still-active stroke, then resets the local gesture and
  publishes dirty/tile/thumbnail updates. It tolerates a stale Flutter active
  flag because the subsequent Rust brush-draft operation remains authoritative.
- Flutter/native stroke terminal ordering:
  `CanvasStrokeCompletionCoordinator` owns the shared reset, preview-retirement,
  autosave-release, and refresh sequence while retaining source-specific
  contact reset and cancellation diagnostics through explicit callbacks.
- Stroke cancellation recovery: `CanvasStrokeCancellationCoordinator` owns
  Rust cancellation failure policy and the common local reset/preview/autosave
  cleanup. `CanvasTouchStrokeCancellationCoordinator` owns the touch marker,
  serialized ownership check, and touch cancellation diagnostics, then delegates
  common cleanup only after Rust cancellation succeeds.
- Stylus draw-and-hold timing: `CanvasDrawAndHoldCoordinator` owns the quiet
  interval timer and rechecks stroke, constraint, latest stylus position, and
  native queue state before dispatch. The screen supplies one immutable state
  snapshot and owns the timer's route lifetime.
- Flutter pointer filtering and routing across tools, touch, sampling, and
  drawing: `CanvasPointerEventRouter`. It owns active pointer-ID tracking and
  can retire stale contacts during Pencil takeover or document replacement;
  touch gesture recognition and serialized stroke cancellation remain with
  their dedicated owners.
- Transient input retirement before document replacement:
  `CanvasInputReplacementCoordinator` sequences screen-supplied gesture,
  navigation, pointer, and native-contact cleanup before the existing
  `DocumentReplacementBarrier` drains, cancels, flushes, and replaces.
- Flutter pressure normalization: `CanvasPointerPressurePolicy` owns mouse,
  stylus-range, and touch-contact fallbacks as an independently tested input
  boundary; native Pencil pressure remains normalized by its native adapter.
- Native pointer, readiness, Pencil command, and canvas-diagnostic stream
  subscriptions: `CanvasNativeInputSubscriptions` owns forwarding, readiness
  state, channel-error reporting, and cancellation. The screen selects streams
  for the current platform and disposes the subscription owner with the route.
- Touch contact timing, touch chord recognition handoff, and configured
  gesture-to-command mapping: `CanvasGestureCoordinator` and
  `TouchGestureTracker`. `CanvasTouchStrokeCancellationCoordinator` owns the
  serialized touch-stroke cancellation transition.
- Comic panel projection and clipping: `CanvasComicPanelActions`.
- Comic workspace notifications: `CanvasComicWorkspaceNotifications` owns
  listener registration and frame-coalesced updates. The screen supplies page
  selection cleanup, widget rebuild, and follow-document workspace effects.
- Workspace layout and dock editing: `CanvasWorkspaceLayoutActions`,
  `CanvasDockActions`, and `CanvasWorkspaceEditorActions`. Desktop dock width
  bounds, collapse/expand state transitions, and their persistence are owned by
  `CanvasDockActions`; `CanvasScreen` supplies explicit state adapters.
- Device-local dock state and preference hydration:
  `CanvasWorkspaceDockState` owns widths, collapse flags, tabs, groups, and
  handedness. It resolves initial preferences, preference changes, workspace
  selections, and edited layouts; the screen only publishes its transitions.
- Desktop dock rendering and palette drag targets: `CanvasDesktopDock`;
  per-side placement and resize hit-target geometry:
  `CanvasDesktopDockRegion`; desktop status-bar placement and collapsed-dock
  affordances: `CanvasDesktopWorkspaceChrome`. `CanvasDesktopWorkspace` now
  composes both sides and their chrome from immutable dock snapshots and an
  explicit action port. The screen persists widths and dock-group state.
- Workspace selection and follow-document preference transitions:
  `CanvasWorkspaceLayoutActions` resolves the dock snapshot and persists
  workspace/follow preferences together; the screen only applies the returned
  selection to view state.
- Per-frame workspace presentation policy: `resolveCanvasWorkspaceFrame` from
  `workspace_dock_layout.dart` derives dock visibility and effective widths,
  tablet presentation modes, and native macOS menu eligibility from explicit
  platform, viewport, preference, and dock snapshots. `shouldUseWideDesktopLayout`
  owns pure platform/width thresholds; the screen reads inherited media and
  workspace mode, then composes the immutable projection.
- Compact/tablet and desktop palette routing: pure
  `selectCanvasWorkspacePanel` plus `CanvasWorkspacePanelActions`, which owns
  sheet/dock/floating-panel branching through a snapshot and explicit effect
  callbacks. The screen creates the snapshot and adapts effects to `setState`,
  preference persistence, and sheet presenters.
- Quick Access, History, and focus quick-control sheet composition:
  `showCanvasQuickAccessSheet`, `showCanvasHistorySheet`, and
  `showCanvasFocusQuickControlsSheet` in `canvas_workspace_panel_sheets.dart`.
  The screen supplies preference, engine, and brush snapshots plus action
  callbacks; command dispatch, history navigation, and preference persistence
  remain with their owners.
- Reused tool, brush, and comic palette composition:
  `CanvasToolPaletteContent`, `CanvasBrushPaletteContent`, and
  `CanvasComicPaletteContent` in `canvas_palette_content.dart`. These widgets
  adapt explicit values, action owners, and callbacks to existing palette
  widgets; the screen retains panel routing and active session ownership.
- Dock palette routing and properties, color, materials, Quick Access, and
  History composition: `CanvasWorkspacePalette` receives a palette snapshot
  and action port, and lazily invokes the existing tool/brush/comic/layer
  builders for their tabs.
- Non-brush tool and selection-command dispatch:
  `CanvasToolEventCoordinator`, which also owns transient tool-start,
  target-layer, sampled-point, and ruler state. Vector stroke mutations are
  delegated through `CanvasVectorToolOperations` to `CanvasVectorActions`, the
  owner of vector projection and Rust vector editing. The screen reads
  preview/ruler snapshots for painting and coordinate snapping and resets
  pointer-path state on tool or engine changes.
- Shared editor-command precedence and fallback routing:
  `CanvasEditorActionRouter` delegates to document, history, tool, brush-color,
  viewport, and panel owners in a tested order. The screen supplies concrete
  handlers for its lifecycle and local UI effects.
- Native macOS menu construction and shared document-action availability:
  `canvas_macos_application_menu.dart` and `isEditorActionDisabled` in
  `app/editor_action.dart`.
- Flutter keyboard shortcut mapping:
  `buildCanvasEditorShortcutBindings`; the screen retains command dispatch.
- Command search dialog result flow: `showCanvasCommandSearch` presents the
  independent dialog, checks route validity after the await, and dispatches the
  selected action through an injected callback.
- Clipboard palette flow: `showCanvasClipboardPalette` owns sheet selection and
  clipboard reads/writes, then delegates pasted-color application to the brush
  color action owner.
- Gesture/navigation and large-control settings plus their asynchronous dialog
  result lifecycle: `CanvasInputSettingsController`. The dialogs keep temporary
  form state; handedness remains in dock state and preference persistence stays
  with workspace actions.
- Canvas render stack and gesture hit testing from an immutable paint snapshot:
  `CanvasViewportSurface`.
- Focus controls, tablet/desktop tool rails, selection launcher, and quick-menu
  overlay composition: `CanvasEditorAuxiliaryOverlays` receives a presentation
  snapshot and action port; the screen retains command and lifecycle effects.
- Current visible tile selection: `projectVisibleTileEntries` prefers current
  composite tiles, falls back to visible raster layers or the primary raster,
  and orders tiles deterministically from explicit snapshots.
- Floating panel placement and presentation semantics:
  `CanvasWorkspaceOverlays`. `CanvasFloatingWorkspacePanels` owns canvas panel
  metadata and maps close actions to immutable visibility updates; the screen
  owns visibility state and composes the tool, brush, layer, and comic content.
- Floating-panel visibility transitions for compact/tablet workspaces:
  `CanvasFloatingPanelVisibility`, an immutable presentation-state value.
- Transient workspace presentation state: `CanvasWorkspacePresentationController`
  owns focus mode, quick-menu visibility, current floating panels, and the
  per-tablet-mode last-palette memory. The screen remains the widget lifecycle
  owner and calls `setState` around controller transitions; preference
  persistence, panel content, and focus-node ownership stay there.
- Flutter/native live preview assembly, sequence mapping, chunk compaction,
  page-edge clipping, and CPU-covered retirement:
  `CanvasStrokePreviewActions`.
- Post-frame live-preview diagnostics: `CanvasLivePreviewFrameDiagnostics`
  coalesces samples to one callback per frame, records an immutable preview and
  queue snapshot, and updates optional input-to-visible traces. The screen
  supplies current pipeline values and disposes the diagnostic owner with the
  route.
- Brush summary projection and local preference restore:
  `CanvasBrushProjection`.
- Durable layer-panel state validation and stale-selection repair:
  `CanvasLayerSelectionReconciliation` resolves stored disclosure and
  selection state against the current immutable layer snapshot;
  `CanvasLayerPresentationState` applies that result and owns the associated
  layer, selection, solo, and generation state. The screen publishes changes
  and queues persistence when stored state needs repair.
- Active brush color mutation and dirty marking:
  `CanvasBrushActions.updateActiveBrushColor`. `CanvasBrushColorActions` owns
  picker result handling, UI color command sequencing, and recent-color policy
  through explicit host callbacks. Callers pass `BuildContext` for each picker
  invocation; the screen owns visible color projections.
- Sampled-color transaction: `CanvasColorSamplingCoordinator` maps a pointer
  location through the current viewport, samples the current tile projection,
  applies the color through `CanvasBrushActions`, and publishes the UI color
  only after the Rust-backed update succeeds and the route remains mounted.
  Pixel decoding stays pure in `CanvasColorSampler`; the screen supplies the
  current document, cache, coordinate transform, and lifecycle callbacks.

`CanvasScreen` is currently about 2,665 lines, down from more than 11,000. It
still owns route lifecycle, inherited-media reads, tool-panel selection,
editor action dispatch, dock state wiring, and root widget composition. The
workspace layout policies now handle wide-desktop thresholds, dock visibility
and sizing, tablet mode selection, and native-menu eligibility from explicit
inputs. Continue
splitting the remaining widget tree only where a component can own a stable
region through a compact value/callback contract. Keep lifecycle callbacks and
narrow adapters here when they are the true owner; do not create a service whose
only purpose is to mirror screen fields.

## Next decomposition sequence

1. **Sheet presenters (implemented):** Quick Access, History, and focus
   quick-control sheets live in `canvas_workspace_panel_sheets.dart`. Inputs
   are snapshots and callbacks; dispatch, persistence, and history navigation
   keep their existing owners.
2. **Dock palette content:** desktop dock assembly is implemented in
   `CanvasDesktopWorkspace`, and tool/brush/comic palette adapters are shared
   by docked and floating layouts. Panel-selection transitions now live in
   `CanvasWorkspacePanelActions`, and dock state/preference hydration now live
   in `CanvasWorkspaceDockState`; layer-panel durable-state validation and
   stale-selection repair are split between the pure
   `CanvasLayerSelectionReconciliation` resolver and
   `CanvasLayerPresentationState`; and `CanvasWorkspacePalette`
   owns dock palette routing plus properties, color, materials, Quick Access,
   and History composition. Continue reviewing its snapshot/action surface and
   the remaining root editor-region composition. Keep active-engine and
   screen-state adaptation in `CanvasScreen`.
3. **Root editor regions:** split the remaining `build` composition into stable
   chrome/viewport regions with immutable presentation values. Keep focus,
   route lifecycle, shared controllers, and cross-region coordination in the
   screen state.
4. **Boundary cleanup:** replace remaining callback bundles that expose screen
   internals with explicit host interfaces only when a service owns a real
   transition or lifecycle. Avoid moving code into a new library solely to
   lower the line count.
5. **Acceptance:** run the focused owner tests after each extraction, then the
   full Flutter suite and representative tablet, desktop, and accessibility
   goldens. Review intentional image changes rather than regenerating them to
   silence failures.

## Remaining work, in order

### 1. Narrow the tile synchronization host

`CanvasTileSynchronizationHost` no longer exposes tile caches or render
revision. `CanvasTileSynchronization` owns those values, clears CPU bytes and
revision on engine replacement, and replaces the decoded-image cache so an
in-flight decode against the old engine cannot repopulate the new session. Tile
polling, commit-batch state, acknowledgement queues, multipart snapshot reading,
and bounded acknowledgement planning also have dedicated owners. Preview
lifecycle and the narrow preview-acknowledgement action port are constructor
dependencies, not host properties. The host receives visible raster IDs and
visible-layer IDs, packet timing, and queue depths through immutable
`CanvasTileSynchronizationSnapshot` values rather than layer models or queue
objects. Each value is captured at the existing read point to preserve async
sampling semantics. Canvas publication and performance reporting live in a
separate `CanvasTileSynchronizationEffects`
port, so the state host remains read-only. Diagnostics are injected separately;
the host captures engine identity and generation in one
`CanvasTileSynchronizationSession`, then validates that token after async
boundaries. `CanvasScreen` implements the state host; only lifecycle checks,
engine-session validation, and the live stroke-active predicate remain as
direct reads. Preserve the single atomic `drainTileUpdates` boundary and
revision checks around every await.

Acceptance: the screen no longer exposes cache or render-revision state just to
satisfy tile synchronization; CPU and live acknowledgements still advance
together only after coherent tile publication. Snapshot copies visible layer
IDs so refresh work never retains mutable route collections. Remaining host
access is limited to lifecycle/session checks and the current stroke predicate;
keep those live because their values can change across awaits.

### 2. Extract remaining input coordination from the route

`CanvasLiveStrokePreviewInput` owns the preview start/sample transition and its
ordering relative to GPU pending notifications. `NativePencilInputCoordinator`
now also owns serialized packet failure logging and stroke recovery, so a
failed packet does not escape the owner that drains native input. Review the
remaining tool dispatch and touch selection handlers. Move a flow only when
the extracted owner can hold its ordering or failure policy with explicit
dependencies; preserve packet sequencing, cancellation, and autosave release
semantics.

### 3. Review remaining route-owned policy and composition

`CanvasScreen` remains the intended route lifecycle and widget composition
point. Continue moving a workflow only when it owns a real transition, async
ordering rule, or disposal boundary and can accept compact explicit inputs.
Review the remaining service-construction wiring and editor `build` tree for
stable region boundaries; do not create a forwarding layer or split widgets
solely to reduce line count. Preserve focus, document replacement, engine
rebinding, pointer ordering, and current accessibility behavior.

Acceptance: new owners have focused tests; screen state remains the single
presentation/lifecycle authority; no `part` files or private cross-library
state sharing are reintroduced.

### 4. Refactor acceptance

After the remaining boundaries change, run `flutter analyze`, the full Flutter
suite, and representative tablet, desktop, and accessibility goldens. For any
change affecting pointer timing, live preview, or native rendering, also run the
iOS/macOS build gates and the relevant physical iPad checks. Rust changes require
the workspace formatting, tests, and Clippy gates in `AGENTS.md`. Report device,
platform, and build-only evidence separately.

## Working rules

- Extract one ownership boundary per change; preserve observable behavior and
  public import paths.
- Prefer immutable snapshots and callbacks over exposing `State` or private
  fields. If an extraction needs a broad bag of getters/setters, split the
  boundary again or leave the orchestration in `CanvasScreen`.
- Each async owner checks its session/generation after awaits and has a clear
  disposal path. Never allow work queued for an old engine or page to target a
  replacement.
- Add focused tests for the new owner and run the existing behavior tests
  before widening the change. Do not refresh goldens unless the visual change
  is intentional and reviewed.
- Preserve the Rust/Dart contract, wire formats, native host interfaces, and
  performance baselines. For input/rendering changes, report build-only,
  simulator, and physical-device evidence separately.
- Keep `AGENTS.md` and `app/README.md` ownership summaries synchronized with
  completed extractions.
