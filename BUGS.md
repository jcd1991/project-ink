# Project Ink bug and UX list

This is a living list for development review. Items marked fixed have an
automated regression test or were reproduced in the running macOS shell.
Physical-device and hosted-platform findings remain Phase 5 work.

Project Ink live-test rule: before launching, inspect both the app/window
inventory and exact Project Ink plus Flutter/device-runner processes; the app
inventory can report the window closed while an old executable PID remains.
Close only identified prior test instances, discard only disposable QA state,
and verify both inventory and process list are clear after cleanup.

- [x] **Transient macOS build failure resolved in current tree
  (2026-09-30).** An initial clean `flutter run -d macos --debug` attempt
  failed before launch with unresolved `PointerSample` at
  `ink-engine/src/lib.rs:6196` and `:6201`. A subsequent source read showed
  both helper signatures now qualified as `ink_input::PointerSample` (no fix
  made in this chat); `cargo check -p ink-engine` and
  `cargo check -p ink-engine --target aarch64-apple-darwin` pass, and a fresh
  `flutter build macos --debug` succeeds. This indicates the initial error was
  transient while the parallel refactor was changing. Resume isolated live
  QA, keeping `canvas_screen.dart` with its owner.

- [x] **Stroke-preview chunk integration built in an earlier snapshot
  (2026-09-30); its prior P0 compile report was fixed at that point.** The earlier attempt
  referenced missing `_StrokePreview` chunk fields/builder and failed before
  launch. The current source now includes `_strokePreviewChunkSize`, preview
  chunks, `chunkedThrough`, and `_buildStrokePreviewChunk`; a fresh build then
  succeeded. A later edit in the concurrent canvas refactor introduced a new
  compile failure recorded below. Do not edit `canvas_screen.dart` here. Live
  long-stroke QA remains necessary because compile success alone does not
  cover preview/commit parity.

- [x] **Concurrent canvas-refactor compile regression cleared in current
  snapshot (2026-09-30).** A prior test run found nullable `snapshotRevision`
  passed to `math.max` in `canvas_screen.dart:5386`; no edit was made here
  because that file belongs to the user's other chat. The current macOS app
  launches successfully, and a fresh focused batch passes
  `project_ink_app_test.dart`, `canvas_pointer_failure_test.dart`,
  `layer_panel_model_test.dart`, `layer_panel_gesture_test.dart`, and
  `brush_library_test.dart` (58 tests total). This only clears the compile
  blocker for the tested snapshot; keep the canvas-refactor source ownership
  boundary and rerun after further edits.

- [ ] **Engine suite retains one pre-existing raster-hash failure
  (rechecked 2026-09-30).** `cargo test -p ink-engine` ran 80 tests: 79 passed;
  `recorded_stroke_has_cross_architecture_golden_tile_hash` failed with actual
  `1395959408535220756` vs expected `12475419944979558790`. The strengthened
  long-stroke exact-pixel Undo/Redo/save/reopen test passes within that suite.
  The golden hashes three legacy CPU samples, and no independent pre-change
  baseline has been established; do not replace the expected value without
  reconstructing intended raster semantics and obtaining a trusted reference.

- [ ] **P1 long-stroke Redo restores a corrupted visual (live macOS QA,
  2026-09-30; refactor-sensitive).** In the fresh debug QA app, Brush Library
  highlighted `Dry Gouache`; the toolbar continued to report `Pen`. A long
  mouse drag from approximately (250,760) to (1400,760) first rendered as a
  continuous dark line. Undo removed that line while preserving the earlier
  test stroke. Redo restored the same region as a dense, noisy band of repeated
  marks rather than the prior continuous line. A fresh app process reopened the
  QA recovery state and showed the same band; one Undo removed it, and Redo
  restored the noisy strip again. A second screenshot after Redo settled showed
  the artifact still present, so this is not just an immediate-transition
  frame. `ink-engine`'s
  `long_confirmed_stroke_crosses_tiles_and_round_trips_as_one_undo_unit` now
  compares full output rows byte-for-byte at commit, after Redo, and after
  save/reopen for two brush families; it passes. This localizes the observed
  discrepancy to the desktop presentation/preview/cache path rather than the
  Rust history raster. Next: capture pointer diagnostics and compare fresh
  committed tile pixels against the live surface after Redo, including after a
  viewport refresh. The toolbar still reported `Pen` while `Dry Gouache` was
  highlighted, so confirm brush identity reporting separately. The user's
  other chat owns the canvas refactor; do not modify its canvas screen here.

- [ ] **P0 Closing a dirty document offers no Save/Discard/Cancel choice
  (live macOS reproduction, 2026-09-30).** In a fresh debug app, created a
  blank Untitled document, drew one disposable mouse stroke, then clicked the
  native red window-close control. No confirmation appeared; the editor window
  disappeared immediately while the app process remained alive. The live
  `AppDelegate.applicationShouldTerminateAfterLastWindowClosed` returns `true`,
  but the exact QA process persisted until the test runner was quit and its
  exact executable PID was terminated. No named project was written. The app
  does have a two-second local recovery checkpoint coordinator, so this does
  **not** prove the stroke was lost; it proves the user received no close-time
  choice, and recovery-vs-close behavior still needs a no-loss test. Source
  audit found an important lifecycle constraint: `AutosaveCoordinator._dirty`
  means “checkpoint pending,” not “changed since explicit Save”; `_saveNow`
  clears it before writing and leaves it false after a successful two-second
  checkpoint. `ProjectInkApp` also binds autosave to the active named project
  after Save/Open, so a checkpoint may already have overwritten that package
  before the user chooses Discard. A close prompt must therefore not key off
  `AutosaveState.dirty`, and Discard cannot honestly promise to restore a named
  document unless the pre-edit revision is preserved or autosave is redirected
  to a separate recoverable session copy. Suggested handoff: add a native-
  window close request path through `AppDelegate.swift` /
  `MainFlutterWindow.swift` to the Flutter document session; track pending
  checkpoint, in-flight write, and changed-since-explicit-save as distinct
  states. Define the no-loss/Discard contract before wiring Save / Discard /
  Cancel. Save errors abort close; Cancel keeps the editor open; clean close is
  immediate. Add tests for untitled and named docs, waiting beyond the
  two-second debounce, failed Save, in-flight checkpoint, Cancel, explicit
  Discard, and reopen/recovery outcomes. Relevant touchpoints:
  `app/macos/Runner/{AppDelegate.swift,MainFlutterWindow.swift}`,
  `app/lib/app/project_ink_app.dart`,
  `app/lib/documents/autosave_coordinator.dart`, and native-window lifecycle
  tests. Project Ink macOS app is closed. A concurrent iPad Flutter runner
  appeared during the pass and was preserved as other-chat work.

## Open findings from the 2026-09-29 Phase 3.85.be acceptance

- [x] **Edited custom-brush native asset round-trip (2026-09-30).** Added
  `edited_brush_export_import_changes_stroke_and_survives_reopen` in
  `ink-engine`: edit a duplicate Opaque Round to 72 px, export `.inkbrush`,
  import it into another Rust-owned document, compare rendered output with the
  original brush, save/reopen `.inkproj`, confirm the custom diameter and
  pixels, then draw again with the reopened brush. The focused test passes;
  `cargo fmt --all -- --check` passes. Full `cargo test -p ink-engine` runs 79
  tests: 78 pass and the pre-existing
  `recorded_stroke_has_cross_architecture_golden_tile_hash` fails with actual
  `1395959408535220756` vs expected `12475419944979558790`. Do not update that
  unrelated golden. Flutter picker/confirm/export/import interaction and live
  macOS `.inkbrush` extension behavior remain unverified; the current canvas
  refactor is being handled in the user's other chat.

- [x] **Live macOS edited-brush export (2026-09-30).** In a single isolated
  macOS QA app, the selected custom brush `Opaque Round Copy Copy` exported
  through the native save panel as
  `/private/tmp/Opaque Round Copy Copy.inkbrush`; the panel proposed exactly
  one `.inkbrush` suffix and the resulting 1,571-byte file is a ZIP archive.
  A later fresh macOS run imported this exact file; the compatibility report
  identified `InkBrush`, `Lossless`, and `project-ink-import-v1`, and the
  `Opaque Round Copy Copy` preset appeared in the library. With that entry
  selected, a new wide mouse stroke rendered visibly. This closes the exact
  desktop export → import/install → brush-selection → draw path, but not its
  save/reopen path in the live app, pressure/tilt, or physical-stylus fidelity.
  The active document contained only disposable QA/recovery marks and was not
  saved. The app and Flutter runner were closed; app inventory and process
  search were clear afterward.

- [ ] **P1 Brush Studio source editing and preview fidelity gap (current-tree
  audit, 2026-09-30).** `BrushLibraryPanel` exposes scalar controls for size,
  opacity, stabilization, pressure response/curve, hardness, spacing, texture
  scale, scatter, rotation jitter, smudge, and wetness. Tip/grain resources are
  shown only as hash summaries (`_ResourceInspector`); there is no visible
  import/create/edit source control or create-from-scratch action in the
  library command row (Import, Export, Duplicate, Rename, Save, Cancel). The
  scratch pad uses a local Flutter `CustomPainter` approximation; the source
  explicitly says it stays outside Rust, and it draws synthetic effect marks
  from scalar settings rather than evaluating the selected `BrushPresetV2`.
  This can make preview disagree with canvas output and is a product fidelity
  issue, not merely missing tests. Rust already models `StampTip.resource_hash`
  and `GrainBehavior`; pack import/export exists, while current engine
  `BrushDraftSettings` is scalar-only. Suggested handoff: first wire scratch
  preview to the same bounded Rust brush evaluator using a disposable preview
  surface that cannot dirty the project; add pixel-level parity regressions for
  preset preview vs one canvas dab/stroke. In a separate slice, add typed
  resource assignment/import/edit draft commands that preserve SHA-256 resource
  identity and remain cancelable/undoable/saveable. Relevant files:
  `app/lib/tools/brush_library_panel.dart`, `brush_library.dart`,
  `app/lib/bridge/engine_api.dart`, bridge `api.rs`, `rust/crates/ink-engine/src/lib.rs`
  (`BrushDraftSettings`), `rust/crates/ink-brush/src/v2.rs`, `pack.rs`, and
  brush library/engine tests. Comparator references and exact product gaps are
  recorded in the Phase 3.85.be brush section; no source code was changed for
  this audit.

- [ ] **P1 General layer lock is missing (current-tree audit, 2026-09-30).**
  The Rust `Layer` model and Flutter `LayerView` expose `alpha_lock`, but no
  independent whole-layer `locked` property or lock/unlock command is present
  in the model, panel, bridge, or engine API. Alpha lock only constrains paint
  to existing opaque pixels; it does not protect a finished layer from paint,
  erase, transform, merge, or delete. Procreate and Krita document a separate
  layer lock, with a visible padlock; Procreate describes it as protecting the
  layer from edits. Suggested handoff: add a serde-defaulted `locked` field to
  Rust and Flutter projections, a validated/journaled update command and bridge
  path, and an accessible lock indicator/action. Define policy before coding:
  block content edits and destructive merge/delete/transform on locked targets;
  allow visibility/reorder/rename/unlock; decide explicitly whether locking a
  group recursively blocks descendants. Add engine tests that prove rejected
  edits leave pixels and history unchanged, undo/redo and save/reopen preserve
  lock state, and Flutter tests for the control and clear locked-target
  feedback. Touchpoints: `rust/crates/ink-model/src/lib.rs` (`Layer`),
  `rust/crates/ink-engine/src/lib.rs` (layer-property validation/commands),
  `rust/crates/ink-bridge/src/api.rs`, generated bridge only if API changes,
  `app/lib/layers/{layer_panel.dart,layer_panel_model.dart}`,
  `app/lib/bridge/engine_api.dart`, layer/compositor/storage tests. This is
  distinct from the already implemented alpha-lock and does not imply general
  selection or mask-lock parity. References: [Procreate layer lock](https://help.procreate.com/procreate/handbook/5.3/layers/layers-mask),
  [Krita layer lock](https://docs.krita.org/en/reference_manual/dockers/layers.html).

- [ ] **P1 Active paint-layer target is ambiguous and can silently fall back
  (reproduced in isolated macOS app, 2026-09-30).** The layer panel
  permits multi-selection through long-press/right-swipe, but
  `LayerSelectionModel` stores only selected IDs; the UI gives selected rows
  the same state and does not identify a primary drawing layer.
  `CanvasScreen._beginActiveBrushStroke` filters the current layer snapshot to
  selected Raster/Mask entries and chooses the first; if none qualify (for
  example, only a Group, Vector, Tone, or Adjustment is selected), it falls
  back to `documentInfo.primaryRasterLayer`. That can route a stroke to a
  different layer than the artist believes is active. Procreate explicitly
  distinguishes one Primary layer from Secondary selections, with painting on
  the Primary. Suggested handoff: define an explicit `primaryId`; single-tap
  makes that layer primary, multi-select either retains it or deliberately
  changes it, and removing primary chooses a deterministic paintable survivor.
  Render primary and secondary selection distinctly. If primary is not
  paintable, prompt/select explicitly or reject with visible feedback—never
  silently redirect. In live QA, added a temporary Group above `Ink`, left the
  Group selected, and drew a disposable stroke. Hiding the Group left that
  stroke visible; hiding `Ink` removed it. This confirms the stroke went to
  `Ink` despite the visible active selection being the Group. The QA app was
  closed without an explicit project save; all marks were disposable recovery
  test state. A second blank-document pass selected `Layer 2` first, added
  `Ink` with right-swipe, drew with both selected, then hid `Ink`; the stroke
  disappeared. Thus reverse-order multi-select also paints into `Ink`, not the
  first-selected `Layer 2`. This matches the source's stable Rust layer
  projection iteration, not an explicit active-primary contract. Test primary
  removal and other non-paintable-only selection at the
  Flutter callback/bridge boundary, then prove non-target raster pixels remain
  unchanged. Touchpoints: `app/lib/layers/layer_panel_model.dart`
  (`LayerSelectionModel`), `app/lib/layers/layer_panel.dart` (selection
  affordance), `app/lib/canvas/canvas_screen.dart`
  (`_beginActiveBrushStroke`; coordinate with the other-chat refactor owner),
  and layer/canvas interaction tests. The Group-only fallback is now live-
  reproduced, including the reverse-order two-raster case; primary/secondary
  indication and other non-paintable types still need separate acceptance.
  Reference: [Procreate layer
  organization](https://help.procreate.com/procreate/handbook/5.0/layers/layers-organize).
  Current `flutter test test/layer_panel_model_test.dart
  test/layer_panel_gesture_test.dart` passes 24/24, but covers additive set
  membership/right-swipe—not primary-target routing—so it does not close this
  defect. The test app was closed; fresh CUA inventory and process search show
  no Project Ink window or executable/Flutter runner.

- [~] **P0 shutdown recovery flush raced engine closure (2026-09-29).** The
  app's `dispose()` previously launched `AutosaveCoordinator.dispose()` and
  `EngineApi.close()` independently. A delayed-save regression reproduced the
  race: event order was `save-started`, `engine-closed`, while the final save
  was still pending. Shutdown now awaits the coordinator's final flush before
  closing the active Rust engine, then closes retiring engines; a checkpoint
  error is logged but does not prevent cleanup. The new focused regression
  `final recovery save completes before the engine closes` passes (1 test).
  After the concurrent canvas refactor stabilized, all 9 tests in
  `test/project_ink_app_test.dart` passed. `flutter analyze` then reported two
  diagnostics in `canvas_screen.dart` (a redundant non-null assertion and
  interpolation style). A macOS build attempt against a later in-progress
  snapshot failed because `_pendingPreviewIndex` had been removed while a few
  references remained; that file continued changing in the user's other chat,
  so no canvas edits were made after the user identified the refactor. The
  app did not launch. Re-run analysis/build against the refactor's settled
  state before claiming integration acceptance.
  This ordering fix does not by itself prove the OS waits for async disposal
  before terminating the process, nor does it add a dirty close prompt; native
  window-close/relaunch recovery acceptance remains open.

- [x] **Graceful-quit recovery checkpoint survives fresh app relaunch
  (2026-09-30).** In the isolated macOS QA session, one earlier visible QA
  stroke was present at startup; a second wide stroke was then drawn with the
  exact imported custom brush. After quitting via Flutter's `q` command, a
  second fresh `flutter run -d macos --debug` logged that it opened the
  recovery project and visibly restored both strokes. This confirms the final
  checkpoint survives normal app shutdown/relaunch for this test document.
  It does not test force-quit/crash recovery, dirty-close prompting, named
  document/recovery-path separation, or prove the first stroke's provenance.
  The session was not saved as a named project; only disposable QA marks were
  involved. CUA inventory and exact Project Ink/Flutter process checks were
  clear after cleanup.

- [x] **Debounced recovery checkpoint survives abrupt app-process termination
  (2026-09-30).** Starting from the same disposable recovery session, drew a
  third visible stroke, waited four seconds (twice the configured two-second
  autosave debounce), and terminated only the exact Project Ink executable
  PID. A fresh debug process logged that it opened the recovery project and
  visibly restored all three marks, including the new stroke. This confirms a
  completed periodic recovery checkpoint survives app-process termination;
  it does not test killing during an in-flight write, OS power loss, or native
  window-close prompting. The app and runner were closed after verification.
  Final CUA inventory and exact process search were clear.

- [x] **Comic page reorder preserves the active-page selection (2026-09-29).**
  `ComicWorkspaceController.reorderPage` previously updated the Rust page
  order and persisted the project but left `_lastKnownPageIndex` unchanged.
  Removing a page afterwards could therefore preserve/activate a different
  page than the one the user had selected. The controller now adjusts the
  active index across moves and when the active page itself moves.
  `comic_workspace_search_test.dart` covers forward/backward moves across the
  active page, moving the active page, and an unaffected active page. The
  focused comic workspace suite passes all 22 tests, `flutter analyze`
  reports no issues, and `flutter build macos --debug` succeeds. The native
  macOS UI round-trip was not completed in this run; physical-device input
  remains untested.

- [x] **Rejected comic Open preserves the current route (Flutter interaction
  regression, 2026-09-29).** `canvas_document_actions_test.dart` now selects a
  path with `comic.json`, makes the studio controller reject it, and verifies
  that the standalone document callback and studio-success callback are not
  invoked, the current active path stays `/tmp/current.inkproj`, and the
  drawing canvas remains available with an error message. The full focused
  document-action suite passes (21 tests) and `flutter analyze` is clean. This
  was first a widget-level failure-path check, then exercised in a fresh
  sandbox macOS build with a copied comic package whose `comic.json` was
  malformed. After selecting the package and granting `/private/tmp` as its
  parent, the app returned to the original `Untitled • Pen` canvas with the
  same three visible QA marks; the selected source package's `comic.json`
  hash remained unchanged. The transient rejection message was not captured,
  so this verifies non-replacement, not error-copy quality. The saved source
  fixture and all existing user fixtures were preserved.

- [x] **New after Save As clears the prior document session path** (app-shell
  regression, 2026-09-29). The new test saves through the app's Save As flow,
  verifies `Phase385Title.inkproj` becomes the active path, then creates a new
  document and verifies the title returns to `Untitled`, the active document
  path is null, and the fresh recovery autosave state has no saved checkpoint.
  `flutter test test/project_ink_app_test.dart` passes all 8 tests. This covers
  Save As → New; Save As → Open another valid-file transition is verified
  below.

- [x] **Save As rebinds future autosaves to the selected project** (app-shell
  regression, 2026-09-29). The test starts with a separate recovery checkpoint
  path, performs Save As to `/tmp/Phase385Title.inkproj`, draws a stroke, and
  advances the autosave debounce. A recording in-memory engine confirms the
  initial explicit save and the later checkpoint both target the selected
  project path, never the recovery path; the status becomes clean/checkpointed
  and displays “Saved.” `flutter test test/project_ink_app_test.dart` passes
  all 8 tests and `flutter analyze` is clean. This proves app-shell path
  selection and status behavior, not disk serialization or reopen durability.

- [x] **Open another valid standalone project replaces the active session**
  (2026-09-29). Added an injectable open-engine factory to `ProjectInkApp` so
  the app-shell lifecycle can be tested without filesystem/UI coupling. The
  widget regression verifies the selected project path reaches the opener,
  the replacement engine becomes the canvas engine, and the title/path update
  together. `flutter test test/project_ink_app_test.dart` passes all 8 tests;
  `flutter analyze` is clean. Fresh macOS live acceptance opened
  `/private/tmp/phase385-layer-visibility.ZYdICT/visibility-roundtrip.inkproj`
  from an Untitled session. After the asynchronous open settled, the toolbar
  showed `visibility-roundtrip • Pen`; Layers showed `QA Group` containing
  `Layer 3` above `Ink`; selecting the group showed 100% opacity and
  Pass-through, while selecting `Layer 3` showed 55%. No layer edits or save
  were performed. The test app was closed and the final app inventory showed
  no running Project Ink instance. Comic picker cancellation is now separately
  verified below. Recovery relaunch and dirty-state behavior across explicit
  Save/Open remain open.

- [x] **Layer-group hierarchy, opacity, and visibility save/reopen verified
  (2026-09-29).** A fresh macOS QA run created a Group, added a raster child,
  renamed the group to `QA Group`, changed an opacity control to 55%, and saved
  `/Users/carito/Desktop/phase385layerqa.inkproj`. Read-only inspection of its
  SQLite document database confirms the group record and child `Layer 3` parent
  ID, but records the group at 100% (65535/65535) and the child at about 55%
  (36044/65535). The child may have remained selected after creation, so this
  was not evidence of an opacity-targeting defect. Source review confirms the
  inspector callback carries the selected layer ID, and a Flutter regression
  verifies a selected group with a child dispatches the group's ID. On a fresh
  macOS app run, opening this exact package displayed `QA Group` as a group with
  nested `Layer 3` and `Ink`; selecting `QA Group` showed 100% opacity, while
  selecting `Layer 3` showed 55%. This confirms hierarchy and each saved
  opacity value survive reopen and the inspector follows selection. No package
  mutation was made during the check. A copy of the fixture was then used to
  draw a disposable mark on `Layer 3`; hiding `QA Group` removed that mark while
  standalone `Ink` marks stayed visible. Save As to a new sibling package
  succeeded, and a fresh app process reopened it with the group still hidden,
  the child mark data present, and the mark absent from the rendered canvas.
  This verifies group visibility composition and persistence. Group blend and
  pass-through/isolation are implemented locally; see the status entry below
  for focused tests and the remaining live group-mode reopen/export, nested
  group, clipping, editable mask, adjustment, and export acceptance gates. The
  original package was not changed.

- [~] **Group blend/pass-through implementation: focused verification passes;
  full parity remains open (2026-09-29).** Added a persisted `group_mode`
  (Isolated/Pass-through), command-journal support and undo/redo, bridge/UI
  inspector control, and group-boundary compositing. Non-Normal blend math
  now preserves source-only colors over transparency. Verified: bridge
  inspector/undo test (1), compositor tests (5), storage tests (18), focused
  engine group blend/isolation and visibility/opacity tests (2), Flutter
  layer/canvas tests (52), and `flutter analyze`. The latest workspace rerun
  has 75/76 engine tests passing and one failure in
  `recorded_stroke_has_cross_architecture_golden_tile_hash`
  (actual 1395959408535220756, expected 12475419944979558790); it hashes a raw
  stroke tile and no pre-change baseline is available, so do not update the
  golden or attribute the failure to group compositing yet. A saved QA package
  at `/private/tmp/untitled-6.inkproj` has SQLite rows proving Group mode
  Pass-through and blend Multiply persisted. However, a fresh-process UI
  attempt did not confirm that package: after selecting its folder, the app
  showed `Untitled • Pen` and only an `Ink` layer. This could be a wrong-open
  selection or load/title/tree restoration failure; it is not yet a confirmed
  package-reopen defect. Next: reliably open that exact package; assert its
  title, group hierarchy, Multiply, and Pass-through in the live UI, then add
  remaining nested-group combinations, group clipping/mask, adjustment,
  export-parity, and legacy-schema tests. Keep the test package as a disposable
  fixture; no product art was changed.

- [x] **Pass-through groups no longer composite translucent content twice**
  (2026-09-29). A focused engine regression compared a normal 100% pass-through
  group against the same two raster layers at the same stack position over a
  partially transparent backdrop. Before the fix, the grouped result was
  BGRA `[0, 96, 128, 224]` instead of `[0, 64, 128, 192]`: the group buffer
  already contained the backdrop, then the compositor blended that buffer back
  over the backdrop. The engine now publishes that accumulated buffer directly
  for identity pass-through groups (100% opacity, Normal blend, not clipped).
  The regression now uses nested pass-through groups; it and the existing
  isolated/pass-through, group visibility/opacity,
  group-adjustment, group-duplication, and panel-mask tests pass; all five
  `ink-compositor` tests and `cargo fmt --all -- --check` pass. Non-identity
  pass-through group presentation (reduced opacity, non-Normal group blend, or
  group clipping), other nested-group combinations, and export rendering
  remain unverified. An updated macOS debug build launched successfully and
  displayed the editor, but the native picker interaction could not reliably
  select the saved Group fixture; live rendering of this fix remains
  unverified. The app and runner were closed and process checks are clear.

- [x] **Pass-through Groups cannot be newly clipped to the layer below**
  (2026-09-29). CSP documents that a folder in Through mode cannot be clipped
  to the layer below. Project Ink previously exposed Group mode and Group
  clipping as independent controls. The Rust command path now rejects either
  entering Pass-through while clipping is enabled or enabling clipping while
  Pass-through is active. The inspector disables the conflicting clipping
  control and offers a hint; row/swipe actions do not offer Enable clipping.
  Existing projects already containing the combination remain loadable and
  can resolve it by disabling clipping or switching to Isolated. The focused
  engine regression verifies both rejected transitions preserve state and the
  recovery path works. The Flutter regression plus all 21 tests in
  `layer_panel_gesture_test.dart` pass, and `flutter analyze` is clean. Fresh
  macOS live QA created a Group, switched it to Pass-through, and verified its
  row omitted Enable clipping; clicking the inspector Clipping control left
  the state unchanged. Switching to Isolated restored an actionable Clipping
  control; enabling it changed the row action to Disable clipping, and the
  mode menu did not switch the clipped Group back to Pass-through. Disabling
  clipping allowed Pass-through again. The unsaved QA document was discarded,
  and both app inventory and process checks confirmed Project Ink closed.
  This constraint follows documented CSP behavior; Krita also documents
  restrictions on pass-through and masks. Group-mask semantics remain a
  separate open acceptance item.

- [x] **Existing-package Save and fresh-process reopen verified (2026-09-29).** In a fresh sandboxed macOS app, Open a
  saved `.inkproj`, change group visibility, then Cmd+S originally reported
  `Operation not permitted (os error 1)`. The Rust package writer atomically
  writes temporary and backup siblings beside the package, so selecting only
  the `.inkproj` directory did not grant the required parent-folder write
  access. Save As to a new sibling package succeeded because its picker
  explicitly selects the parent. Added
  `reopened_document_can_save_again_to_its_existing_package` in
  `rust/crates/ink-bridge/src/api.rs`; create → save → reopen → same-path save →
  reopen passes under `cargo test -p ink_bridge
  reopened_document_can_save_again_to_its_existing_package`. The bridge now
  returns the underlying Rust error string for save diagnostics. The macOS
  picker asks for the containing folder from its parent directory (avoiding a
  still-selected project child), normalizes native trailing-slash paths, and
  normalizes enumerated `.inkproj` choices. Unit tests cover direct package
  selection and multiple packages in a real temporary directory. In a fresh
  macOS app, the copied package
  `/private/tmp/phase385-layer-visibility.ZYdICT/visibility-roundtrip.inkproj`
  opened with title `visibility-roundtrip • Pen`; revealing `QA Group` and
  Cmd+S completed without the prior permission error. `document.sqlite` mtime
  advanced to 17:52 and stored `QA Group.visible = 1`, confirming persistence.
  In a separate fresh `flutter run --no-pub -d macos` process, the native
  multi-project chooser reopened that same copy; after the asynchronous open
  settled, the toolbar showed `visibility-roundtrip • Pen` and the Layers panel
  listed `QA Group`, `Layer 3`, and `Ink`, with the group visible. The earlier
  `Untitled` observation was captured before that open settled and was not a
  product defect. No Desktop fixture was changed; all writes were confined to
  the disposable copy.

- [~] **Brush edit output is covered; physical pressure/tilt acceptance remains
  open.** Added
  `committed_brush_draft_changes_the_rendered_stroke`: duplicate Opaque Round,
  render a baseline dab, commit a Rust-owned diameter edit, then render the same
  dab and assert the tile pixels differ. `cargo test -p ink-engine
  committed_brush_draft_changes_the_rendered_stroke` passes. Existing tests
  cover draft cancel without document mutation, resource import/export, and
  imported-brush rendering after reopen. Added
  `edited_custom_brush_and_stroke_survive_document_reopen`, which commits a
  duplicated preset's 72 px setting, saves/reopens the project, and asserts the
  custom setting and exact painted tile bytes survive; this focused engine test,
  the cancel transaction test, the edited-output test, and `cargo fmt --check`
  pass. Fresh macOS live QA opened a disposable copy of the edited-brush package,
  selected `Technical Pen Copy`,
  confirmed its 15.5 px displayed size, and drew a visible mouse stroke;
  runner diagnostics recorded 373 compiled dabs over five tile updates. The
  saved source fixture's database timestamp remained unchanged. Still needed
  for full parity: Apple Pencil/stylus pressure and tilt acceptance on physical
  hardware. A second live attempt created a disposable package at
  `/Users/carito/Desktop/untitled.inkproj` after the name dialog retained its
  default; read-only inspection found `Technical Pen Copy` revision 2 and two
  painted tiles. In a fresh process, the native Open picker successfully
  selected that package folder, but its title remained `Untitled • Pen` and
  the Brush Library exposed only built-ins in the visible list. Because the
  UI did not provide a reliable visible confirmation of which project had
  loaded (and search did not filter the brush list), this attempt is
  inconclusive for live custom-brush/artwork reopen—not a confirmed restore
  defect. The saved package is preserved; unsaved test state was discarded.
  Both CUA app inventory and exact process inspection were clean after close.

- [x] **Native directory path with trailing separator displayed as Untitled
  (2026-09-29).** The macOS file picker exposes `.inkproj` directory URLs with
  a trailing slash. `_documentDisplayName` previously split the raw path and
  treated its final empty segment as `Untitled`. It now strips trailing path
  separators before selecting the basename; a widget regression covers
  `/tmp/Comic Draft.inkproj/`. `flutter test test/canvas_touch_gesture_test.dart`
  (32 tests), `flutter test test/project_ink_app_test.dart` (6 tests), and
  `flutter analyze` pass. The app-shell Save As title test also passes. Fresh
  macOS live QA opened `/Users/carito/Desktop/phase385editedbrush.inkproj` from
  the parent directory; the toolbar displayed `phase385editedbrush • Pen` and
  the saved horizontal marks were visible. This verifies the exact saved
  package title and artwork after Open, including the native directory-path
  case. The fixture was not changed.

- [x] **Edited brush appears and renders after project reopen (macOS,
  2026-09-29).** The saved package's
  `brushes.json.zst` decodes to user brush ID 13, `Technical Pen Copy`,
  revision 2, diameter 15.454981 px, confirming the committed edit is written
  into the package. A fresh app opened a temporary copy of the fixture; the
  custom preset was available below the built-ins, selected successfully, and
  rendered a visible stroke at the saved size. The live stroke was deliberately
  left unsaved and discarded when the app closed. The original Desktop package
  was not modified.

- [x] **P1: native stylus recovery regression no longer assumes a fixed packet
  total.** `app/test/canvas_pointer_failure_test.dart`, test “native stylus
  packets stop at the page edge and the next stroke works”, previously
  expected five packets where valid coalescing delivered four. Replaced the
  brittle exact totals for the follow-up strokes with assertions that each
  stroke sends samples and closes (begin/end counts remain exact); the initial
  clipped-stroke packet count remains exact. The test passes alone and all 15
  tests in `canvas_pointer_failure_test.dart` pass. This was a test
  expectation mismatch, not a reproduced artwork-loss defect.
- [x] **Long confirmed stroke crosses tile boundaries and round-trips.** The
  Rust regression `long_confirmed_stroke_crosses_tiles_and_round_trips_as_one_undo_unit`
  passes, covering four 256-pixel tiles, one-step Undo/Redo, and save/reopen.
  A fresh macOS app run also created a default transparent 2048×2048 document,
  drew a continuous full-page-width mouse stroke in Fit Canvas and another
  across the viewport at View → Actual Pixels, and visibly removed/restored the
  second stroke with one Undo/Redo. Save As produced
  `/Users/carito/Desktop/phase385longqa.inkproj`; after quitting and launching a
  fresh app process, Open Project reopened it with both strokes visible and the
  expected title. The package is retained as a saved QA fixture. Zoomed
  Flutter-preview handoff and live stylus/touch acceptance remain separate
  validation gaps.

- [x] **P0: oversized undo history no longer blocks artwork open or makes new
  saves unreopenable.** Opening the saved eight-page QA package
  `/private/tmp/project-ink-comic-first-qa.g9AHSH/LongStrokeQA.inkproj`
  failed before the page workspace loaded. A temporary local diagnostic test
  identified a decoded-history limit error. Page 1's compressed history is
  about 203 KiB but expands to 391,958,254 bytes, above the reader's 128 MiB
  `MAX_DECOMPRESSED_HISTORY_BYTES`. Storage now writes only the newest undo/redo
  snapshots that fit this reader bound; when opening older packages whose
  history sidecar already exceeds the bound, it skips that optional sidecar,
  keeps the artwork/layers, and marks the history projection as trimmed. The
  History palette discloses that older undo history was omitted. Tests cover
  bounded save, legacy oversized-history open, artwork preservation, and
  retained-tail alignment. Focused Rust suites pass (`ink-storage` 17,
  `ink-command` 6, `ink-engine` 72, `ink_bridge` 30); the focused Flutter
  gesture/history suite passes 32 tests and `flutter analyze` is clean. A fresh
  macOS build opened the original fixture successfully; its title became
  `LongStrokeQA`, and the canvas visibly showed all three saved long strokes.
  The source fixture was not modified. The History palette's disclosure is
  verified in the live app's History overlay with the exact disclosure visible
  over the reopened artwork. History-sidecar discard is explicit data loss limited to undo/redo
  history; current artwork is preserved. Do not raise the decode cap blindly,
  because all pages could otherwise require gigabytes of memory.

- [x] **Legacy comic workspace controls are reachable in the live app
  (2026-09-29).** Reopened the disposable eight-page `LongStrokeQA` v2 package
  after the history fix and opened Window → Comics. The workspace exposed the
  four linked-mask panel records, gutter sliders, polygon/split controls, and
  panel-bound editor. Opening the bounds editor and cancelling returned to the
  panel list without committing. Text/Balloon exposed four per-panel entries
  and dialogue, tail, and style editors; opening the first dialogue editor and
  cancelling also returned without committing. That early pass verified
  control reachability and cancel navigation only; the later bounded checks
  below close the geometry-edit and panel-clip gaps for the tested path.
  A second pass on a disposable copy confirmed the bounds editor prepopulates
  the persisted rectangle values and `Draw inside panel` can be activated; a
  cross-boundary mouse drag was visible, but exact screen-to-document panel
  alignment and active-mask state were not independently observable. A further
  fresh-build pass on a disposable copy calibrated the canvas: Page 1 is
  2400×1800 and Panel 1 spans x=120..620, y=180..1580. Green active-panel
  feedback was visible after choosing `Draw inside panel`. Engine diagnostics
  placed the inside drag at x=189..548 and the boundary-crossing drag at
  x=466..744. Read-only comparison of the saved copy's Page 1 SQLite layer
  index against the original shows the panel Ink child gained three tiles
  (`0x223344556677a899`); decoded alpha bounds place the inside stroke at
  x=183..554, y=790..802, consistent with the calibrated input and brush width.
  The initial cross-boundary attempt was miscalibrated: its later diagnostic
  coordinates were x=925..1075, entirely outside Panel 1, so its preview-only
  appearance was expected clipping rather than evidence of a lost stroke.
  Rechecked in a fresh macOS build on a new disposable copy, with Fit Canvas
  and release inside the viewport. The diagnostic mapped the actual crossing
  drag to x≈303..792, y≈959; Page 1 Panel 1 spans x=120..620. After Save, the
  selected Panel 1 Ink child had tiles (1,3) and (2,3), whose decoded alpha
  bounds were x=297..619, y=953..965. This confirms the inside segment commits
  and the outside segment is clipped. One Undo removed those child tile rows;
  Redo restored them and the state was saved. A fresh process reopened the
  disposable package with the saved stroke visible; one Undo and Redo after
  reopening also removed/restored that stroke, confirming persisted history
  behavior for this gesture. No production code change was needed. The Rust bridge regression
  `selected_layer_stroke_respects_panel_polygon_selection` independently
  verifies inside/outside dab clipping. Only a disposable copy was written;
  the original fixture was untouched. The app and Flutter runner were closed
  after the test.
- [x] **Legacy comic panel geometry survives edit, save, and fresh-process
  reopen (2026-09-29).** Copied the saved eight-page v2 `LongStrokeQA` fixture
  to `/private/tmp/phase385-legacy-edit.2CnHNy/LegacyPanelQA.inkproj`; opened
  that disposable copy in the rebuilt macOS app; edited Page 1 / Panel 1 width
  from 500 to 510 through Comics → Panel → Edit panel bounds; and used the
  explicit Save project command. The copy's `comic.json` records width 510.0
  with the existing panel ID 8192. A normalized JSON comparison against the
  source package, applying only that width change, has identical SHA-256
  (`9ff3b54edec82081c6e1086642874b0f4eac511ff31331cc1da0eec8e4bc1bc7`), so
  the test found no other comic-structure or ID changes. After closing the
  first app and verifying it was no longer running, a fresh macOS process
  reopened the saved copy; the app showed `LegacyPanelQA`, eight pages and four
  panels on Page 1, and the bounds editor again displayed width 510.0. The
  original fixture was only read, not modified. The reopened canvas retained
  its saved ink. This verifies legacy geometry edit/save/reopen and structure
  preservation. Polygon geometry and mask-edit semantics remain unverified.
  Regression checks pass:
  `cargo test -p ink_bridge selected_layer_stroke_respects_panel_polygon_selection`
  (1 selected test), `cd app && flutter test
  test/comic_workspace_search_test.dart test/engine_api_test.dart` (25 tests),
  `cd app && flutter test test/project_ink_app_test.dart
  test/canvas_document_actions_test.dart` (29 tests), and `cd app && flutter
  analyze` (no issues).

- [x] **P2: rich comic SVG visual acceptance (2026-09-29).** Fresh runtime
  export of the eight-page onboarding comic produced
  8 PNG + 8 SVG files in `/private/tmp/project-ink-phase385-rich-export.XOpJ2X`.
  Structural checks confirm 2400×1800 PNGs and parseable SVG with embedded
  page artwork, four panels, twenty comic-ink polylines, four balloon shapes,
  tails, and wrapped dialogue. Native macOS Quick Look rendered page 1; all
  four panels, stick-figure ink, balloon tails, and two-line dialogue were
  visibly present, with lettering fitting inside each oval balloon. Quick Look
  is zoomed beyond the full-page viewport, so inspection used scroll/pan to
  review the two panel columns and upper/lower artwork. No visual defect was
  found in this fixture. This does not verify other SVG viewers, font
  substitution, or print rendering.

- [x] **P0: named standalone Save As → fresh-process Open preserves artwork
  (2026-09-29).** Opened `/private/tmp/phase385be-qa-saveflow.inkproj` in a
  fresh Project Ink process through the native Open Project picker. The window
  title became `phase385be-qa-saveflow`; the canvas visibly restored its two
  saved horizontal ink strokes, and the Layers panel showed the persisted Ink
  raster layer. This closes the previously open standalone package reopen
  check for this fixture. It does not establish the broader unsaved-dirty,
  failed/cancelled-open, or relaunch-recovery matrix. A second blank Untitled
  Project Ink window was discovered and closed during cleanup; the saved package
  was not modified.

- [x] **Fresh-document → Save As → draw → save → fresh-process Open (2026-09-29).**
  Created a new transparent sRGB document with the default 2048×2048 px and
  300 dpi settings, then saved it as
  `/private/tmp/phase385be-lifecycle-qa.inkproj`. Drew a long diagonal stroke,
  saved, closed Project Ink, and relaunched a single fresh app process. Opening
  the package restored the exact `phase385be-lifecycle-qa` title and visible
  stroke. The package manifest reports 2048×2048, 300 dpi, transparent sRGB;
  SQLite lists three populated tile coordinates for the stroke. In the reopened
  document, one toolbar Undo removed the complete stroke and Redo restored it;
  the restored state was saved. This is positive live evidence for document
  creation, named Save As, save, fresh-process Open, and one-stroke undo/redo.
  It does not close dirty-title indication, failed/cancelled-open preservation,
  Save As replacement/corruption handling, recovery/relaunch after unsaved
  edits, layer/brush matrices, or long-stroke performance at multiple zooms.
  The named package is disposable QA data; Project Ink was confirmed closed.

- [x] **Disk-backed Save As → long stroke → save → fresh-process Open (2026-09-29).**
  In one isolated macOS QA run, saved a copy as
  `/private/tmp/phase385-live-save-open-20260929/Phase385DiskRoundtrip.inkproj`,
  drew a long horizontal mouse stroke, waited for autosave, and invoked Save.
  After quitting and starting a fresh process, Open Project loaded that exact
  package. The first view showed only the newer stroke because the prior mark
  was outside the current pan/zoom; View → Fit canvas displayed both marks, so
  this was a view-framing false alarm, not missing artwork. One Undo removed
  the new stroke and Redo restored it. The package contained four populated
  tile coordinates and checkpoint revision 13 at close. The pre-existing
  recovery package manifest stayed unchanged (mtime `02:51:15`, 347 bytes),
  and Project Ink was confirmed closed. This strengthens disk-backed selected-
  path save/open and single-stroke undo/redo evidence; it does not verify dirty
  close/recovery relaunch, cancellation/failure preservation, stylus input,
  multi-brush live preview, or performance. The named package is disposable QA
  data and was retained for inspection.

## Fixed in the current review

- [x] **Predicted-to-confirmed preview handoff does not leave a ghost dab
  (GPU regression, 2026-09-29).** Added a live-render regression that draws a
  predicted dab, replaces it with a confirmed dab of the same stroke/sequence/
  dab identity at a corrected coordinate, then reads back the GPU surface and
  asserts the predicted pixel is cleared while the confirmed pixel is present.
  `cargo test -p ink-live-render confirmed_sample_replaces_its_predicted_preview_without_a_ghost`
  passes; the full `cargo test -p ink-live-render` suite passes all 12 tests.
  This closes the stale-preview replacement seam at the GPU surface level,
  not exact app/device preview-to-committed-tile pixel equivalence.

- [x] **Long-stroke deterministic acceptance coverage (2026-09-29).**
  `cargo test -p ink-engine
  long_confirmed_stroke_crosses_tiles_and_round_trips_as_one_undo_unit` passes:
  two starter brushes span four tiles, each whole stroke is one Undo/Redo unit,
  and both persist after document reopen. `cd app && flutter test
  test/canvas_pointer_failure_test.dart` passes all 15 tests, including the
  repeated long-stroke UI exercise for all 12 starter brushes. Earlier fresh
  macOS QA separately verified page-width and zoomed viewport-crossing mouse
  strokes with Undo/Redo and fresh-process reopen. Physical stylus/pressure,
  measured performance at multiple zoom levels, and app/device pixel-exact
  preview handoff remain open; mouse evidence is not stylus parity.

- [x] **Drawing ignored the selected layer (2026-09-29).** Both native-stylus
  and Flutter pointer paths began brush strokes through a bridge call that
  always targeted `primary_raster_layer()`, even when the Layers panel selected
  another raster or mask (including a comic panel's Ink child). Added a
  selected-layer stroke-start API through Rust, generated FRB, and `EngineApi`;
  the canvas now routes to the first selected paintable layer and retains the
  primary-raster fallback when selection is absent/non-paintable. A Rust bridge
  regression verifies the selected layer receives the dab while the primary
  layer remains untouched. A Flutter interaction test selects a second raster
  and asserts its ID is sent. In a fresh macOS build, drawing on Layer 2 and
  hiding it made the stroke disappear from the otherwise blank canvas, directly
  confirming it was not written to the base layer. `cargo test -p ink_bridge`
  (31), `flutter test test/canvas_pointer_failure_test.dart` (15),
  `flutter analyze`, `cargo fmt --check`, and `flutter build macos --debug`
  pass. The test also exposed a debug assertion for `ExpansionTile` inside
  decorated inspector surfaces; a transparent local Material now owns its ink
  effects, and the same interaction test runs without framework exceptions.

- [x] Legacy v2 comic panel bindings can contain 128-bit child-layer IDs that
  Flutter `int` cannot represent; the prior bridge rejected the primary layer,
  layer summaries, and tile invalidations. `LayerIdProjection` now assigns
  stable safe UI aliases while retaining Rust IDs in package metadata, and
  maps layer commands, reads, summaries, and tile updates back through the
  adapter. Comic canvas binding paths use the projection rather than narrowing
  persisted IDs. `flutter test test/engine_api_test.dart` (8),
  `flutter test test/comic_workspace_search_test.dart` (17),
  `flutter test test/canvas_document_actions_test.dart` (20),
  `flutter analyze`, `cargo fmt --check`, and all 30 `ink_bridge` tests pass.
  The Rust regression opens, edits, saves, and reopens a high-namespace
  project, confirming the original `comic.json` bytes and layer IDs remain
  unchanged. Live app opening/drawing with an actual previous-generator v2
  fixture is not yet verified.

- [x] **Comic export collision feedback (2026-09-29):** The Rust no-clobber
  behavior correctly rejected a second export, but Flutter displayed only
  `Instance of 'EngineErrorImpl'`. Export failures now show
  “Export failed. Choose a different, writable folder and try again.” Other
  opaque bridge errors are rendered as a generic comic-operation message
  rather than a generated class name. `flutter test
  test/comic_workspace_search_test.dart` passes all 18 tests and
  `flutter analyze` is clean. A fresh macOS build repeated export to the same
  folder; the actionable retry message appeared and hashes of all four
  existing PNG/SVG outputs remained identical. QA artifacts are under
  `/private/tmp/project-ink-phase385-export.d3d9hW`.

- [x] Generic Open sent saved multi-page comic packages to the standalone
  document loader, which rejected `comic.json` packages. `CanvasScreen` now
  identifies native studio packages and opens them through
  `ComicWorkspaceController.openProjectFromPath` → `openStudioProject`; the
  active standalone autosave is flushed before the engine capability rebind,
  and the old coordinator is retired without saving into its former path after
  a successful open. Failed studio opens keep the current controller handle
  and canvas projection. `canvas_document_actions_test.dart` covers routing
  and callback order; `cargo test -p ink_bridge` now has 29 passing tests and
  `flutter analyze` is clean. A fresh sandbox-signed macOS build saved and
  reopened a two-page comic with a panel, linked Panel/Panel Mask/Effects
  layers, and visible page artwork. Standalone document lifecycle, named path
  accuracy, cancel/corrupt studio-project behavior, and old v2 panel-ID
  compatibility remain separate acceptance items.

- [x] Entering Comic workspace on a fresh document showed a generic Rust error
  instead of its eight-page onboarding comic. The sample assembled panel
  records directly but omitted the corresponding `PanelLayerBinding` records
  required when the unified studio handle materialized its page layer trees.
  The fixture now adds the canonical binding for each generated panel.
  `studio_first_run_example_materializes_as_a_complete_project` verifies all
  eight pages, 32 panels, and materialized panel/mask layers. The test first
  reproduced `InvalidCommand("studio panel binding is missing")`, then passed
  after the fixture change; `phase3_eight_page_stick_figure_acceptance_flow`
  and all 15 `ink-comic` tests pass. A fresh sandbox-signed macOS build now
  loads “A tiny stick-figure comic” with 8 pages, 4 panels and 4 balloons per
  page, without the prior error. Initial materialization took about 15 seconds
  on this machine; startup latency is recorded but not yet optimized.

- [x] Fresh Flutter-created comic panels were rejected as having invalid layer
  tree IDs. `ComicWorkspaceController` sends layer IDs through Dart `int`, but
  `PanelLayerBinding` generated child IDs in high 128-bit namespaces; after the
  `u128 → Dart int` boundary, distinct child IDs collapsed and the local
  `EngineApi` uniqueness check rejected the tree. The role namespaces now use
  distinct positive signed-64-bit values while retaining the stable `u128`
  storage type. `epoch_microsecond_flutter_ids_materialize_repeated_panel_trees`
  creates three panels using the same timestamp-sized sequential IDs as the UI,
  verifies all 21 layer IDs fit the Dart range, and checks their page tree.
  `cargo test -p ink-comic` (15 tests), `cargo test -p ink_bridge` (29 tests),
  `flutter test test/comic_workspace_search_test.dart` (16 tests),
  `flutter analyze`, and `flutter build macos --debug` pass. In a fresh isolated
  macOS app, two panels were created with no error and a long stroke was drawn
  after activating Draw inside panel. This verifies new-project panel IDs;
  reopening projects already saved with the previous 128-bit child namespaces
  still needs an explicit compatibility/migration test before claiming legacy
  panel-layer usability.

- [x] Unified comic projects initially exported only structural SVG and
  omitted each Rust-owned page document's raster/vector artwork. “Export pages”
  now writes paired `page-####.png` artwork and a self-contained SVG embedding
  that PNG with comic structure and dialogue. The bridge regression checks
  painted-vs-blank pages, dimensions, pair publication/no-clobber cleanup,
  wrapped/escaped dialogue markup, and deterministic output after save/reopen.
  Fresh isolated macOS QA exported a two-page comic with two panels, one
  balloon/dialogue and a long stroke; both PNGs were 2400×1800, page 1 visibly
  contains the stroke, and both SVGs parse as XML with embedded PNG data and
  panel/balloon/tspan markup. SVG rendering itself was not visually checked
  because the available browser blocks local `file:` URLs. PDF, ICC/CMYK, font
  shaping and print preflight remain open; collision safety is covered by the
  bridge regression but not a second live export attempt.

- [x] Brush size editing was effectively linear across `.25–4096 px`, leaving
  practical values such as 10 px cramped near the slider start. The editor now
  maps the bounded range logarithmically and displays the actual pixel size.
  `flutter test test/brush_library_test.dart` passes all seven tests,
  `flutter analyze` is clean, and `flutter build macos --debug` succeeds. In a
  fresh isolated sandbox-signed app, a duplicated G-Pen was resized from 10 px
  to about 28 px and its canvas stroke was visibly thicker than the original.
  This verifies the size control and edit-to-draw path only.
- [x] The custom G-Pen asset completed a live `.inkbrush` export/import
  acceptance in the isolated brush QA app. Export proposed exactly
  `G-Pen Copy.inkbrush`; the resulting archive existed at the chosen path and
  the importer reported `InkBrush` / `Lossless`. Install added a second
  same-name preset, and selecting it left the editor showing the 28.3 px size.
  Save/reopen of the resulting `.inkproj` preserved the visible canvas marks;
  `brushes.json.zst` contains both custom records (IDs 13 and 14, each 28.34456
  px). The CUA pointer failed with `windowNotFoundAtPosition` when attempting
  a post-import stroke, so imported-brush drawing after reinstall/reopen is
  not live-verified. Project-name entry in this run resolved to
  `untitled.inkproj`; because CUA text entry also corrupted the brush-search
  field, treat project-name editing as a harness-limited follow-up, not a
  confirmed product defect.
- [x] Reorder controls stayed actionable at the top and bottom of a sibling
  stack, where the engine-side index clamp made the operation a no-op. The
  layer rows now derive boundary availability from the same compositor-ordered
  projection they render; top-up and bottom-down are disabled while available
  directions remain usable. A widget regression covers both endpoints and a
  middle row. The focused layer gesture/model suite passes (21 tests),
  `flutter analyze` is clean, and the rebuilt macOS app visually shows the top
  boundary disabled and its downward action enabled; live reorder was exercised
  in the isolated app.
- [x] Pinch-to-merge used the raw engine projection to pick the target row even
  though the UI displayed the compositor-ordered projection. After reordering,
  merging a visible row could target a different layer (including itself).
  Merge preview now uses the same ordered layer list as the rendered rows. A
  widget regression supplies IDs in an order that disagrees with stack order
  and verifies source 2 merges into its visible neighbor 3. Focused layer
  gesture/model tests pass (21 tests), `flutter analyze` is clean, and the
  macOS debug build succeeds. The fresh rebuilt bundle reaches the editor and
  displays the layer panel. The CUA interface cannot synthesize the two-pointer
  pinch, so the preview/confirm gesture remains automated-test-only.
- [x] Pinch-to-merge offered confirmation even when the engine would reject the
  pair (for example, a raster layer next to a group or either layer marked for
  clipping). The preview now explains the constraint and disables Merge for
  non-raster, different-parent, child-bearing, clipped, or identical pairs.
  Widget tests verify unsupported non-raster and clipped pairs cannot dispatch
  the merge callback; supported raster pairs still expose confirmation and
  report stable source/target IDs. The focused 21-test layer gesture/model
  suite passes, the Rust engine's atomic/undo/replay merge test passes,
  `flutter analyze` is clean, and the macOS debug build succeeds.
  Live UI inspection confirms the rebuilt layer panel is present, but the
  two-pointer gesture itself could not be driven through CUA.
- [x] The desktop status bar always showed “Autosave,” even when the current
  document had never been checkpointed, had pending edits, was saving, or had
  failed. It now reflects the Rust-backed session coordinator states (“Not
  saved,” “Unsaved changes,” “Saving…,” pending changes, “Saved,” and “Save
  failed”); opening an existing project starts as checkpointed, while a new
  document starts unsaved. The app-shell regression draws a real test pointer
  stroke, observes dirty state and “Unsaved changes,” advances the autosave
  debounce, then asserts a clean checkpoint, “Saved,” and no error. The widget
  test targets macOS explicitly so it exercises the desktop status strip.
  In a fresh sandbox-signed macOS build, the same Not saved → Unsaved changes →
  Saved transition was observed after a stroke and automatic checkpoint. The
  app shell also ignores late
  autosave notifications during disposal, preventing a teardown `setState`
  assertion. The status strip is desktop-workspace-only; compact canvas-first
  layouts do not show it.
- [x] The toolbar always said “Project Ink • Pen,” so after Save As or Open
  the active project was not identifiable. It now derives the title from the
  active `.inkproj` path (and shows “Untitled” before a named save) in desktop
  and compact layouts. Widget coverage verifies both states; an isolated fresh
  macOS build created a new canvas, saved a drawn canvas as `ComicDraft.inkproj`,
  reopened it, and displayed `ComicDraft • Pen` while preserving the visible
  stroke. Creating another new canvas reset the toolbar to `Untitled • Pen` and
  showed a blank canvas; the saved package remained on disk.
- [x] macOS mouse clicks and drags could be invisible because Flutter reports
  zero pressure for a conventional mouse. Mouse packets now use firm pressure
  while native stylus pressure remains unchanged. Regression coverage is in
  `app/test/canvas_pointer_failure_test.dart`.
- [x] Desktop tools and layers were hidden behind toolbar buttons and were
  easy to miss. The production desktop shell now reserves a right Workspace
  dock with labeled Tools, Brushes, Layers, and Comics tabs.
- [x] The layer panel projected engine layers in stable ID order rather than
  compositor order, so a newly added higher layer appeared below the base and
  the visible “Move layer up” control could be a no-op at the row shown. The
  UI now orders siblings by descending explicit stack order and keeps nested
  descendants contiguous below their group. Model and widget regressions cover
  top-to-bottom ordering. A fresh sandbox-signed macOS build showed Group
  above Ink, moved Ink above Group with the row action, and restored/reapplied
  the order with Undo/Redo.
- [x] The canvas is inset beside the desktop dock so the sidebar does not steal
  drawing input. The compact floating panels remain available to touch-sized
  layouts and deterministic widget tests.
- [x] Closing the comic dialogue editor could leave a Flutter red-screen
  assertion because temporary text controllers were disposed before the modal
  route finished its reverse animation. Dialogue, polygon, tail, and style
  editors now own and dispose their controllers with the dialog route.
- [x] Replacing a decoded canvas tile could dispose its `ui.Image` while the
  raster thread was still painting the previous frame. Tile images are now
  exposed to each painter through cloned handles; cache eviction can therefore
  retire its own handle without invalidating a live raster frame. A separate
  non-persisted pointer preview also bridges tile-decode latency without
  flashing the canvas.
- [x] Comic structural edits had no visible history controls. The Comics dock
  now exposes bounded undo/redo backed by validated JSON checkpoints; the
  live xkcd fixture was edited and restored in both directions.
- [x] The desktop canvas had no fast brush controls and settings were split
  across icon-only actions. A desktop-only quick-control strip now exposes
  the active brush, size, opacity, eraser, color, zoom, fit, and gesture
  settings without hiding the canvas; narrow-window icon targets remain stable.
- [x] The Workspace dock could not be temporarily dismissed on wide desktop
  windows. Its header now has collapse/expand controls and preserves the
  selected tool tab while the canvas is maximized.
- [x] The comic toolbar exposed speech and narration only even though the
  model supported thought and burst balloons. A labeled balloon-type menu now
  exposes all four shapes without adding more permanent toolbar clutter.
- [x] The desktop quick strip showed the active brush but not the active layer.
  It now keeps the current layer name visible beside the brush context.
- [x] Panel division required a numeric slider without showing the resulting
  composition. The divide dialog now includes a draggable visual divider and
  keeps the bounded ratio control for precise edits.
- [x] Local materials were display-only after creation. The material summary
  now exposes license/attribution and a Rust-backed remove action.
- [x] Page order depended on drag-and-drop alone. Page cards now expose
  labeled move-up/move-down actions as an accessible alternative and preserve
  the selected page after reordering.
- [x] Screentone creation exposed only three fixed presets despite supporting
  frequency, angle, density, and shape. The workspace now opens a bounded
  screentone editor before dispatching the nondestructive layer.
- [x] Effect-line creation exposed only fixed speed/focus/radial choices even
  though the engine accepted width and opacity. The workspace now opens a
  bounded editor for line type, width, and opacity before dispatch.
- [x] Page bleed, trim, safety, and DPI were visible but not editable. The
  page inspector now provides a validated settings editor backed by an atomic
  Rust layout command.
- [x] Rectangular panels had no direct geometry editor and the polygon action
  could only convert a rectangle. Rectangles now expose bounded X/Y/width/
  height editing; polygon vertices remain explicit and are never discarded.
- [x] Panel geometry validation checked finiteness but allowed off-canvas
  rectangles or polygon vertices. Rust now bounds panel geometry to the page
  canvas and rejects invalid edits atomically.
- [x] Thought and burst balloons were labeled correctly but previewed as plain
  ovals, and the canvas preview omitted tails. Preview/export now uses bubble
  clusters and burst polygons, while the Flutter canvas draws the stored tail.
- [x] Adding a local material silently inserted a hard-coded placeholder and
  license. The workspace now asks for bounded name/type/license metadata and
  persists the author-supplied attribution and source locally.
- [x] Drawing could flash the entire layer when a new revision promoted the
  image cache before dirty tiles finished decoding. The canvas now keeps the
  last complete frame visible, promotes unchanged tiles using the previous
  revision, and retires old images only after the replacement frame is
  published.
- [x] Screentones and effect lines could be created but not edited or removed
  from the page inspector. Existing items now show their parameters with
  Rust-backed edit and remove actions; the original geometry remains intact
  while style settings change.
- [x] A long mouse drag could show the committed raster stroke and its
  latency preview at the same time, producing a parallel line until save
  settled. Pointer-up now clears the ephemeral preview immediately after the
  authoritative stroke commit; the preview now hands off sample-by-sample to
  confirmed tiles instead of drawing over them. Painter image handles remain
  alive for a bounded desktop-renderer
  safety window, preventing the transient black-box/draw-image failure.
- [x] Mouse/stylus preview updates were serialized behind awaited Rust bridge
  packets, making the cursor trail behind a fast drag. Preview samples now
  update synchronously and the painter renders only the unconfirmed suffix;
  packet submission remains ordered and authoritative.
- [x] Closing a comic without a host file callback discarded the in-session
  recovery checkpoint. Close now keeps the last validated bytes available to
  the recovery action.
- [x] Canvas image handles were disposed synchronously when the canvas state
  shut down, allowing a desktop compositor to repaint an old display list
  against a disposed image. Shutdown now uses the bounded deferred retirement
  queue used for normal tile revisions.
- [x] A pointer release could land while a composite tile was decoding and
     have its follow-up refresh dropped, so the responsive live preview vanished
     without the committed tile being published. Refresh requests are now
     coalesced and retried after the active decode; a fresh macOS build was
     verified with short and long mouse strokes remaining visible after release.
- [x] A fresh session kept released strokes only in memory until the user
     completed a named Save dialog. Production startup now creates an app-owned
     recovery project, autosaves released strokes there, and reopens that
     checkpoint on the next launch without modifying a failed source file.
- [x] Mouse drags could accidentally arm the stylus draw-and-hold straighten
     gesture and show a SnackBar during the drawing hot path. Mouse input no
     longer arms that timer, mode activation is silent, and pointer-up cancels
     any pending hold without a frame/layout spike.
- [x] Color selection was limited to RGB sliders and the eyedropper sampled a
     stale layer tile. The brush color dialog now has an HSV wheel, alpha/value
     controls, RGB precision sliders, C/I shortcuts, and composite-tile sampling.
- [x] Undoing the only stroke produced an empty full-redraw batch, but the
     tile pump treated it as incomplete and never repainted the cleared canvas.
     Full redraws now retire the previous frame and force a repaint even when
     the valid replacement is an empty document.
- [x] Standalone macOS startup could race two FrbEngineApi constructors and
     call RustLib.init twice. Bridge initialization is now single-flight and
     retryable after a failed dynamic-library load.
- [x] If a desktop window stopped delivering pointer-up after a stroke left
     the app, the next mouse/stylus press could remain attached to the stale
     engine transaction. A new pointer-down now cancels any abandoned stroke
     before starting a fresh one on both generic Flutter and native input paths.
     Regression coverage simulates a missed release and confirms later drawing
     remains available.
- [x] Long captured drags after a stroke crossed the artwork edge kept sending
     pointer packets even though Rust had already clipped the crossing segment
     and ignored re-entry. Both Flutter mouse input and native stylus input now
     stop forwarding those outside moves and close the transaction on
     release/cancel. 100-move regressions confirm bounded packet submission
     and that the next stroke still works. Native coalesced batches are also
     truncated at the first confirmed edge-crossing sample, preserving the
     segment Rust needs to clip while discarding the captured packet tail.
- [x] At 1:1 zoom, the visible canvas viewport can end before the document
     edge. A captured mouse drag could leave the visible canvas while still
     mapping to valid document coordinates, continuing to queue hidden-page
     samples and making the editor appear stuck. Generic pointer input now
     stops at the viewport boundary while preserving the document-edge sample
     needed for precise Rust clipping; release still closes the stroke. A
     regression verifies the next stroke remains usable.

## Open UI polish

- [ ] **Remaining comic Open lifecycle acceptance:** Type-aware routing is
  implemented and live Save → Open now succeeds. A fresh sandbox-signed macOS
  build reopened `/private/tmp/project-ink-comic-open-qa.Qfp3uP/untitled.inkproj`
  with two pages, one panel, the linked Panel/Panel Mask/Effects layer tree,
  and visible raster marks intact. In a fresh debug app, opening a deliberately
  malformed comic package kept the previously opened project title, Ink layer,
  and visible marks intact. That live failure first exposed a raw
  `EngineErrorImpl` in the snackbar; `CanvasScreen` now shows a plain-language
  message explaining the comic may be damaged/unsupported and that the current
  project remains open. The rejection widget test asserts the exact copy and
  absence of the implementation type. `flutter test
  test/canvas_document_actions_test.dart` passes all 21 tests; `flutter analyze`
  is clean. Fresh macOS QA reopened the saved comic package, opened the native
  Open picker, and canceled; the `untitled • Pen` title, active Ink layer, and
  both visible saved marks were unchanged. The test app was closed and both
  app/process inventories were clear. Still open: page selection/content
  through another reopen, legacy panel IDs remaining editable, named
  path/dirty state, and relaunch recovery. Do not route comics through the
  standalone decoder or flatten their page structure.

- [x] **Layer rename route lifecycle regression (2026-09-29):** Reproduced
  during fresh isolated macOS QA after adding a second raster layer: opening
  Layer options → Rename, entering a new name, and submitting produced the
  Flutter red-screen assertion `_dependents.isEmpty` (`framework.dart:6281`).
  The rename dialog previously disposed its text controller in the
  `showDialog(...).then(...)` callback, before the reverse route transition
  finished. Controller ownership now lives inside a stateful dialog route;
  focused Flutter tests cover both commit and cancel and
  `flutter analyze` is clean. A rebuilt sandbox-signed macOS app then
  successfully added and renamed a raster layer, with the new name visible in
  the live layer tree; the red-screen assertion did not recur.

- [x] Fresh macOS bundle QA initially inspected an older process sharing the
  same bundle ID, which made the Adjustment and direct Delete controls appear
  absent. A rebuilt bundle isolated under a temporary QA bundle ID exposes
  both controls in its live accessibility tree. Live QA verified Add
  Adjustment, brightness/contrast inspector and Reset presence, Delete
  confirmation/cancel, confirmed deletion, and Undo restoring the layer.
- [x] **Nested Adjustment accessibility-tree crash (2026-09-29):** Reproduced
  on multiple isolated macOS 27.0 builds while adding an Adjustment beneath a
  selected Group. The latest pre-fix report,
  `project_ink-2026-09-29-054803.ips`, identifies `EXC_BAD_ACCESS` at `0x48`
  in `flutter::FlutterPlatformNodeDelegate::ChildAtIndex(int)` during
  `-[AXPlatformNodeCocoa AXChildrenInternal]`. The Flutter layer list and
  selected inspector previously reused unkeyed elements while insertion
  changed both row children and the inspector subtree. Layer rows now have
  stable layer-ID keys; the inspector is keyed by selected layer ID and kind.
  A semantics widget regression exercises group → nested Adjustment selection
  and the inspector switch. In a fresh sandbox-signed build, live Group →
  Adjustment creation now exposes the adjustment sliders; Brightness edit,
  Reset, Undo, and Redo all completed with accessibility updates and without a
  crash. This closes the reproduced app path, but keep monitoring other
  dynamic layer-tree mutations; do not suppress accessibility semantics.
- [x] Add an explicit desktop collapse/expand control for the Workspace dock.
- [x] Add a compact brush-size/opacity strip near the canvas; the desktop
  quick-control strip also includes eraser, color, zoom, fit, and settings.
- [ ] Replace the icon-only document actions that can require horizontal
  scrolling in narrow desktop windows with a labeled overflow menu.
- [x] macOS brush Export previously suggested `<brush>.inkbrush.inkbrush`.
  Reproduced in the live app (`G-Pen Copy.inkbrush.inkbrush`) because NSSavePanel
  appends the accepted extension. `PlatformDocumentPicker.saveBrush` now passes
  an extensionless suggestion and normalizes the returned path; the picker test
  asserts both. Focused tests and `flutter analyze` pass, and a macOS debug build
  succeeds. Fresh `flutter run -d macos --debug` QA verified the native panel
  suggests exactly one `.inkbrush` extension and exported a usable 2,079-byte
  archive to `/private/tmp/phase385be-GPen.inkbrush`; the native importer
  reported `InkBrush` / `Lossless`. The suffix/export defect is closed.
- [ ] **Unconfirmed/intermittent:** One macOS AX snapshot omitted the Brush
  library subtree after scrolling to parameters while the screenshot showed the
  sliders. A subsequent `getAXStateAndScreenshot` refreshed the tree and exposed
  slider semantics (Curve response, Tip hardness, Spacing, Texture scale,
  Scatter, Rotation jitter, Smudge, Wetness). Layers remained exposed and no
  crash occurred. Repeat with VoiceOver or a semantics harness before filing a
  product accessibility defect; current evidence may be a stale snapshot, not
  an app regression. **Follow-up (2026-09-29):** On the standard macOS app,
  Brush library buttons/presets were initially exposed; after duplicating a
  preset and scrolling, two fresh full AX snapshots omitted the panel's
  descendants while screenshots showed the brush list/sliders. A coordinate
  click attempt returned `AXError.failure`; the window remained renderable.
  A new Flutter regression,
  `visible brush controls stay in Flutter semantics after scroll`, proves that
  visible Texture scale, Tip hardness, and Wetness labels remain in Flutter's
  semantics tree. Thus the native snapshot discrepancy is below that Flutter
  test seam or specific to CUA/macOS AX; it is not evidence that the widgets
  omit semantics. Repeat with VoiceOver/native AX before assigning ownership;
  do not infer brush-edit failure from the AX action failure alone. All six
  `brush_library_test.dart` tests pass.
- [x] **Imported custom brush after project reopen, fresh-process QA
  (2026-09-29):** The earlier stable-app CUA run could not draw even with the
  built-in brush and was inconclusive. A clean `flutter run -d macos --debug`
  process was subsequently used: G-Pen Copy exported to a temporary `.inkbrush`
  archive (2,079 bytes), and the import review reported `InkBrush` / `Lossless`
  before installation. The imported entry rendered a visible stroke. The
  project was saved as `/private/tmp/untitled-2.inkproj`, terminated, and
  explicitly reopened in a new process. Its original stroke remained visible;
  filtering by `ink` exposed both persisted G-Pen Copy records, and drawing with
  the imported entry rendered a second stroke. Undo removed only the second
  stroke and Redo restored it. `brushes.json.zst` contains the two expected
  custom records. This closes mouse-input and undo/redo acceptance for this
  imported brush after reopen; stylus/pressure/tilt remain untested. This QA
  process was quit and `cua.getState()` confirmed Project Ink was no longer
  running. Temporary test artifacts are under `/private/tmp`.
- [x] **Rust-owned brush rename (2026-09-29):** Added custom brush rename
  through engine, bridge and library UI. Rust trims and validates 1–256 UTF-8
  bytes, rejects built-ins/empty names/active strokes, increments the preset
  revision, and routes rename through brush Undo/Redo and document persistence.
  The engine regression verifies settings remain unchanged and save/reopen
  retains the new name; Flutter tests cover availability, dialog submission,
  and controller lifecycle. Live macOS QA exposed an early controller-lifetime
  failure; moving controller ownership into a stateful dialog fixed it, and a
  fresh single-instance run opened/cancelled the dialog without exceptions.
  Distinct source/duplicate row identity is still a usability follow-up; same-
  name rows remain visually indistinguishable until one is renamed.
- [ ] **macOS accessibility diagnostics during brush QA:** while opening,
  scrolling, and dismissing Brush Library and native file sheets, the debug
  console repeatedly logged Flutter `accessibility_bridge.cc` AXTree update
  errors (`id ... will not be in the tree and is not the new root` / pending
  nodes). The app remained interactive, rendered both strokes, and completed
  Undo/Redo; CUA AX snapshots also intermittently omitted visible panel
  descendants. A fresh 2026-09-29 brush-reopen session reproduced the errors
  during scroll/dismiss; despite this, custom-brush selection and drawing
  succeeded (diagnostic: 373 dabs, five tile updates) and the app quit cleanly.
  Current evidence cannot distinguish transient snapshot churn from an app
  semantics lifecycle defect. Recheck with VoiceOver/native AX and avoid
  suppressing semantics based on this observation alone.
- [x] New Document can now be started from File, command search, command bar,
  or Cmd/Ctrl+N. The dialog validates dimensions and DPI and currently offers
  transparent sRGB only. The current project is checkpointed before switching.
- [x] Native Save As uses the project package's parent-directory contract and
  a project-name prompt instead of a file Save panel. macOS Debug and Release
  sandbox profiles include user-selected read/write access; the folder picker
  returns a parent in which Rust can atomically publish the `.inkproj`
  directory. In a fresh app, a long mouse stroke was saved, Open Project
  reopened the package, the stroke and `Ink raster` layer were visible, and
  Cmd+Z/Cmd+Shift+Z removed/restored the stroke after reopen. The live reopen
  also exposed Flutter's `_dependents.isEmpty` red screen; the project-name
  dialog now owns its `TextEditingController` in a stateful route, avoiding
  disposal before the reverse transition completes. Focused picker/document
  tests and `flutter analyze` pass, and a fresh macOS build/live round trip
  shows no red screen. Native cancel, corrupt-file, dirty-state/path semantics,
  and autosave recovery still need acceptance. The CUA text-entry run did not
  reliably replace the default name, so filename editing should be verified
  with physical keyboard input.
- [x] Open project no longer requires dismissing a PSD-only picker before the
  project-directory picker. PSD import is now a separate File action with its
  own filtered file picker. A fresh macOS build displayed one `Open project`
  folder sheet for Cmd+O; command search exposed `Import PSD`, whose sheet is
  independently filtered and labeled `Import PSD`. Focused platform-picker
  tests confirm opening a project does not invoke the PSD file selector and
  the explicit import action does.
- [x] Opening another project now waits for an in-flight autosave even when
  the coordinator's dirty flag has cleared. Autosave clears that flag when a
  write begins, so checking only `isDirty` could close the engine while its
  checkpoint was still running. `_openDocument` now always flushes the
  existing coordinator before constructing/replacing the active document;
  `autosave_coordinator_test.dart` holds a save open and verifies `flush()`
  does not complete until the write does. Native corrupt-input and dirty/path
  UI acceptance remain open.
- [x] A corrupt `.inkproj` open now reports a useful safe explanation instead
  of the opaque `Instance of 'EngineErrorImpl'`. `FrbEngineApi.open` logs the
  bridge failure for diagnostics and converts it to a user-facing
  `DocumentOpenException`; the document action surfaces that message. A fresh
  uniquely sandbox-signed macOS app was given a visible stroke, then opened a
  disposable project directory with invalid JSON in `manifest.json`. The app
  rejected it, retained the stroke, and displayed “Could not open the selected
  document. It may be damaged, unsupported, or inaccessible.” The focused
  widget regression and all 15 `canvas_document_actions_test.dart` tests pass;
  native picker cancellation, active-path semantics, and recovery acceptance
  remain open.
- [x] Added a deterministic Rust long-stroke regression that crosses four
  256-pixel tiles with two starter brush presets, verifies the whole line is
  removed/restored by a single Undo/Redo per stroke, and confirms both strokes
  survive `.inkproj` save/reopen. `cargo test -p ink-engine` passes (70 tests).
  This does not replace visual seam checks at zoom levels or live stylus/input
  acceptance.
- [x] Add a visible active-layer/active-brush status line and canvas zoom
  percentage to the desktop quick controls.
- [ ] Add a first-run hint explaining that mouse drawing is supported and that
  two-finger/stylus gestures are platform-dependent.
- [x] Keep the live stroke preview from being composited over confirmed tiles
  during long mouse drags; retain desktop tile image handles long enough for
  the native compositor to finish using prior frames.

## Deferred validation

- **Current verification refresh (2026-09-29):** `cargo test --workspace`
  compiles and runs the workspace; all suites completed except one unchanged
  `ink-engine` golden failure (75/76 engine tests pass, actual tile hash
  `1395959408535220756`, expected `12475419944979558790`). The test hashes
  legacy CPU dabs, so group compositing is not implicated by the exercised
  path; the expected baseline still cannot be safely replaced without an
  independent reference. Workspace rerun also exposed a brush binding test
  that appended its case to the starter's existing pressure binding; clearing
  the starter dynamics made the test correctly isolate its named behavior,
  and that test now passes. A fresh `flutter run --no-pub -d macos --debug`
  launched the editor/recovery document successfully. Native-picker navigation
  to `/private/tmp/untitled-6.inkproj` did not select/open the fixture, so no
  new layer/group runtime acceptance is claimed. The app and its exact Dart
  development-service process were terminated and final app/process inventories
  are clear; all saved QA fixtures remain untouched.

- **Cross-page comic script editor (implemented; macOS accessibility gate open,
  2026-09-29):** Dialogue search hits now display inline editable script rows,
  navigate to their current owning page, and save through the existing
  `studio_set_dialogue` Rust command. Stable balloon IDs are resolved against
  the current project snapshot; result order updates when pages reorder, and
  deleted hits cannot write through stale indices. `comic_workspace_search_test.dart`
  passes all 21 tests, including inline mutation dispatch and reorder mapping;
  `cross_page_script_dialogue_edit_is_searchable_undoable_and_persistent` in
  `ink_bridge` passes search/edit/undo/redo/save/reopen with stable IDs, and
  `flutter analyze` is clean. In a fresh macOS run, disposable comic page and
  balloon creation worked, but CUA text entry did not reliably replace/enter
  the search or dialogue text. The run printed Flutter AXTree stale-node and
  unknown-semantics-node assertions during shutdown while the automation was
  changing text-field semantics. Treat live script editing/keyboard/screen-reader
  acceptance as inconclusive; reproduce with normal keyboard/physical input
  before classifying the assertion as app-owned. Unsaved test comic state was
  discarded, no package was saved, and both CUA inventory and process checks
  confirm Project Ink is closed.

- [ ] Verify Apple Pencil Pro/Apple Pencil 2, S Pen, and external tablets on
  physical hardware in Phase 5.
- [ ] Verify final Windows/Linux hosted builds and signed release artifacts in
  Phase 5.

- [x] **Duplicate-layer macOS runtime verification (2026-09-29):**
  The standard running app and older `org.projectink.studio.qa385be` window
  omit “Duplicate layer”; both predate the current menu wiring. A fresh Flutter
  build initially bundled an `ink_bridge.framework` timestamped before the API
  change. A targeted `xcodebuild -project macos/Pods/Pods.xcodeproj -scheme
  ink_bridge -configuration Debug -sdk macosx -derivedDataPath
  build/macos/Build clean build` rebuilt the framework, which was copied into
  the QA app product before relaunch. Launching the isolated copied app through
  LaunchServices still produced a spinner-only window. A debug-run launch
  (`flutter run -d macos --debug`) did initialize successfully and logged
  `RustLib.init complete`, engine health passed, document opened, and initial
  revision loaded. The current debug-run window exposed Duplicate layer. On a
  disposable copy of `visibility-roundtrip.inkproj`, the action created `Ink
  Copy`; Undo removed it and Redo restored it. Save updated only the copy; a
  fresh process reopened it with `Ink Copy` in the layer stack, and SQLite
  independently showed the persisted layer record. Focused regressions pass:
  `cargo test -p ink-engine
  duplicate_leaf_layer_copies_pixels_preserves_order_and_survives_undo_reopen`,
  `cargo test -p ink_bridge
  duplicating_a_leaf_layer_is_available_through_bridge_and_undoable`, and
  `cd app && flutter test test/layer_panel_gesture_test.dart` (20 tests), plus
  `flutter analyze`. Final inventory showed Project Ink closed. This closes
  ordinary leaf duplication runtime/reopen only. Follow-up acceptance in the
  same session also duplicated an ordinary group subtree on a disposable copy:
  `QA Group Copy` appeared with its `Layer 3` child, Undo removed the whole
  copied subtree atomically, Redo restored it, and save/fresh-process reopen
  preserved the copied parent/child relationship (confirmed in both the layer
  panel and SQLite). `cargo test -p ink-engine
  duplicate_group_copies_complete_hierarchy_and_undoes_atomically`,
  `cargo test -p ink_bridge
  duplicating_a_group_subtree_is_projected_and_comic_owned_descendants_are_rejected`,
  `cd app && flutter test test/layer_panel_gesture_test.dart` (20 tests), and
  `flutter analyze` pass. Final inventory confirmed Project Ink closed. This
  closes ordinary leaf and ordinary group-subtree duplicate runtime/reopen
  only; comic-owned layer constraints, other layer operations, and the wider
  matrix remain separate acceptance.
- [ ] **Historical fresh-bundle spinner observation (2026-09-29; superseded below):**
  Rebuilt `app/build/macos/Build/Products/Debug/project_ink.app`, copied it to
  `/tmp/ProjectInk-QA385be6.app`, assigned bundle ID
  `org.projectink.studio.qa385be6`, ad-hoc signed it, and launched it. CUA
  targeted that unique bundle ID and showed only the centered loading spinner;
  no layer UI was reachable. The normal bundle lookup still binds an older
  same-ID window. This adds evidence that the issue is not merely CUA selecting
  one of the old QA copies, but does not isolate whether startup context,
  recovery/bootstrap, or framework loading is responsible. Preserve existing
  app windows and documents; do not claim macOS layer-menu acceptance.
- [ ] **Historical rebuilt-bundle spinner observation (2026-09-29; superseded below):**
  After adding the comic page-removal API and regenerating FRB, `flutter build
  macos --debug` succeeded. The product was copied to
  `/tmp/ProjectInk-QA385be7.app`, assigned unique bundle ID
  `org.projectink.studio.qa385be7`, ad-hoc signed, and launched. CUA bound by
  that exact ID; screenshot and accessibility tree showed a blank dark canvas
  with only the centered Flutter loading spinner and no editor controls. This
  blocks live acceptance of both recent layer and comic changes. It is not
  evidence that the individual features fail after startup. Existing user
  windows/documents were not closed or modified.
- [x] **Open/Save/Save As picker cancellation regression:**
  `flutter test test/canvas_document_actions_test.dart` verifies cancelled
  open/save/save-as picks do not call document replacement, engine save, or
  saved-path notification. A new injected save failure case verifies failed
  Save As does not adopt the selected destination or emit a saved-path event;
  the document-action suite passes all 16 cases. In a fresh sandbox-signed
  macOS app, a visible stroke and `Untitled` title survived Cmd+O → Cancel and
  Cmd+Shift+S → enter name → cancel destination selection. This directly
  verifies those cancel paths in the UI; the name-prompt cancel case, named
  document path/dirty invariants, and relaunch recovery remain unverified.
- [ ] **Full Flutter suite visual baseline:** latest `flutter test` completed
  280 tests with 232 passing and 48 failures, all reported from
  `editor_layout_visual_test.dart` golden comparisons (pixel diffs varied by
  layout, scale and theme). Functional widget tests including the new duplicate
  menu test passed. Do not refresh goldens automatically; inspect the diff
  images and establish whether these are current intended layout changes or
  existing environment/baseline drift.

- [x] **Fresh macOS startup and editor smoke / QA signing context (2026-09-29):**
  Added debug-only startup stage logs around path-provider resolution, engine
  creation, Rust initialization, project open, and first revision. A newly
  rebuilt debug app launched directly and logged all stages through
  `initial revision loaded`; its Flutter menu exposed the editor's New/Open/
  Save/Save As/Export actions. The earlier unique QA copies were signed with
  `codesign --deep --sign -` without the app's sandbox entitlements; macOS
  displayed a Documents-access permission dialog for an older temporary QA
  app. This makes the spinner evidence potentially a test-harness/TCC artifact,
  but does not prove that is the only cause. Leave permission prompts
  untouched; do not grant Documents access for QA. A fresh bundle signed with
  `app/macos/Runner/DebugProfile.entitlements` and a unique ID launched in its
  own sandbox container. Logs reached default document creation and initial
  revision load. A later isolated sandbox-signed build visibly rendered a
  mouse stroke; Undo cleared it and Redo restored it. The same fresh process
  passed live layer add/rename, duplicate/undo, visibility toggle, and Group →
  nested Adjustment → brightness edit/reset/undo/redo with accessibility
  updates. Apple Account/iCloud and Documents prompts seen in other sessions
  were never interacted with. Named-project dirty/path invariants, recovery,
  custom-brush, comic, and hardware acceptance remain open. No
  original recovery file was modified; the earlier temporary recovery copy
  was byte-identical when checked.
- [x] **Brush-family UI selection coverage expanded:**
  `test/canvas_pointer_failure_test.dart` now selects all 12 built-in presets
  and routes one pointer stroke per preset through `CanvasScreen` into its
  recording test engine, including Watercolor Blender, Ink Spatter, Ribbon
  Chain, and Acrylic Rake. `flutter test test/canvas_pointer_failure_test.dart`
  passes all 13 cases. The engine regression
  `imported_tip_resource_renders_exports_and_reopens` now also draws with the
  resource brush after project reopen; its focused Cargo test passes. These
  automated paths do not replace live stylus/manual brush QA.
- [x] **Document replacement retired the old live surface too late (2026-09-29):**
  A fresh macOS debug session initially reproduced `document engine is closed`
  during tile refresh and `invalid_surface: Only one live surface may be
  registered per window` while opening/replacing a document. `CanvasScreen`
  now serializes old live-surface disposal before registering its replacement,
  ignores stale tile refresh errors after engine generation changes, and
  notifies `ProjectInkApp` when canvas cleanup is complete. The app retires
  replaced engines only after that disposal future resolves. Added a deferred-
  disposal widget regression. Live QA then reopened `/private/tmp/untitled-3.inkproj`
  and created a new document over it in the same app instance; neither runtime
  error recurred. `canvas_document_actions_test.dart` passes all 19 tests,
  `project_ink_app_test.dart` all 5, and `flutter analyze` reports no issues.
  The original fixture remains intact. Project Ink was closed after the run.
- [x] **Save As name/path verified in a fresh macOS run (2026-09-29):**
  `setValue` alone did not update the Flutter controller; that earlier attempt
  created `untitled-4.inkproj` and was an automation limitation, not a confirmed
  product defect. In a fresh instance, triple-clicking the editable name field
  selected the full default name and normal keyboard text input replaced it.
  The title changed to `phase385be-qa-saveflow`, and the exact package exists at
  `/private/tmp/phase385be-qa-saveflow.inkproj` with manifest, document
  database, history, vectors, and brush data. This agrees with
  `desktop Save As forwards the entered project name` in
  `canvas_document_actions_test.dart`, which checks that the dialog value
  reaches the picker, engine save, and saved-path callback. The current
  `flutter test test/canvas_document_actions_test.dart` passes all 20 tests and
  `flutter analyze` reports no issues. Standalone
  open/reopen of this package is still unverified in this run; native picker
  automation selected a different temporary folder, so no result is attributed
  to Open.

- [x] **New → named Save As → Open live round-trip (2026-09-29, disposable QA
  package):** A fresh `flutter run -d macos --debug` instance showed the New
  Document dialog defaults (2048×2048, 300 DPI, transparent sRGB) and created a
  blank canvas with one `Ink` raster layer. The dialog says the current project
  is checkpointed before switching; this pass did not inspect recovery storage,
  so it is not proof that a dirty document can be restored. The package was
  saved to `/private/tmp/phase385-dirty-flow.X0Nljq/phase385docroundtrip.inkproj`.
  Accessibility `setValue` did not replace the name; clicking the field and
  entering the replacement with keyboard input did. The title updated to
  `phase385docroundtrip • Pen`, and the package contains manifest, SQLite,
  history, vectors, and brush data. In the same process, the native Open picker
  selected that exact package folder; the title and `Ink` layer returned. The
  first picker attempt accidentally chose its parent folder and is excluded
  from product evidence. The fixture is disposable and retained. Final CUA
  inventory and process search confirmed both Project Ink and Flutter runners
  closed. Dirty-state prompting, recovery checkpoint restoration, Save
  cancellation, corrupt-open preservation, and relaunch recovery remain open.

- **Brush Studio explicit commit boundary (2026-09-29):** Removed the 350 ms
  idle auto-commit for Rust-backed brush drafts. The Brush Library now exposes
  a disabled-until-dirty `Save brush changes` action beside `Cancel edit`,
  wired in both docked and floating panels. Successful commit marks the
  document dirty. Added a widget regression for the commit/cancel affordances.
  `flutter test test/brush_library_test.dart test/canvas_touch_gesture_test.dart`
  passes all 41 cases, and focused analysis is clean. The brush-selection test
  fixture now uses the same 1440×900 desktop-dock setup as the passing desktop
  palette coverage and targets the brush’s semantic label.
  Fresh-process macOS QA verified cancel (4.0 px → 164.6 px, wait 900 ms →
  Cancel → Rust projection returned to 4.0 px) and explicit commit (same size
  edit; after 900 ms Save was enabled, then after Save the value remained
  164.6 px and Save was disabled). Save As wrote
  `/private/tmp/untitled-5.inkproj`; the requested QA name was not adopted,
  matching the separately tracked name-flow issue. Reopening that exact package
  in a second fresh process showed Technical Pen at 164.6 px. Read-only package
  inspection confirmed `brushes.json.zst` contains `tip.Stamp.diameter_px` of
  164.56343 and manifest revision 5. Project Ink was closed after the pass;
  the QA package is retained in `/private/tmp`.

- **Brush scatter commit retest is inconclusive (2026-09-29):** In a fresh
  macOS QA app, duplicated Technical Pen to `Technical Pen Copy` (custom brush
  ID 13). Changing scatter to 51% and choosing Cancel returned the visible
  value to 0%, confirming draft rollback. A subsequent attempted 51% edit and
  Save brush changes did not persist: after File → Save project,
  `brushes.json.zst` still reports `tip.Stamp.editor_scatter: 0.0` (revision 2).
  However, the UI became unreliable during this sequence and the saved value
  matches the prior Cancel, so this does not yet prove a product defect. Retest
  with one controlled parameter change, verify the Save action enables and
  disables around commit, then reopen the exact package and inspect the
  projection/rendered brush. Disposable QA copy:
  `/private/tmp/phase385-brush-edit-uTqmeI/untitledPhase385BrushLoop.inkproj`;
  saved recovery artwork was not modified. `flutter test
  test/brush_library_test.dart test/project_ink_app_test.dart` passes all 18
  tests and `flutter analyze` is clean. Final process search found no Project
  Ink/Flutter runner process.

- **Fresh isolated macOS smoke pass after the canvas-refactor handoff
  (2026-09-30).** Reused the already-running single QA runner rather than
  starting another Project Ink instance. The current macOS build opened
  successfully. On a transparent 2048×2048, 300-DPI Untitled canvas, a
  continuous ~1,150-screen-pixel mouse Pen stroke rendered end-to-end; one
  Undo removed it and Redo restored the same clean continuous line. This is a
  narrow mouse/Pen pass only; it does not contradict the previously reproduced
  noisy Redo band for Dry Gouache or establish multi-zoom, multi-brush, or
  stylus equivalence. The New Document dialog exposed the expected defaults
  and created a fresh blank canvas with one `Ink` raster layer. The layer panel
  exposed creation choices for Raster, Vector, Group, Mask, Tone, Panel group,
  and Adjustment, plus opacity and a 16-entry blend-mode menu. Brush Library
  visibly exposed Import, Export, Duplicate, Rename, Save brush changes, Cancel
  edit, All brushes, search, and the starter preset list; this pass did not
  exercise every brush or edit custom tip/grain resources. A disposable package
  was saved at `/private/tmp/untitledqa_phase385_20260930.inkproj`; it contains
  `manifest.json`, `document.sqlite`, `history.json.zst`, vectors/brush metadata,
  and tiles. Loading this exact package was attempted through the native folder
  picker but not completed; this run supplies Save/package evidence, not a new
  Open/reopen pass. Accessibility `setValue` changed the visible Save-name
  value but the resulting project title/path retained the prior text, so this
  remains a CUA input/controller verification limitation consistent with
  prior naming probes; do not classify it as a product defect without
  physical-keyboard reproduction. Flutter emitted repeated `AXTree` stale-node
  and pending-node diagnostics during automation while panels/dialogs changed;
  classify as a possible semantics-update issue requiring reproduction without
  automation before filing a product bug. The canvas refactor file was not
  edited. Runner quit cleanly, but its exact app PID remained; only that
  identified QA PID was terminated. Final app inventory and exact Project
  Ink/Flutter process search were clear. The disposable package is
  intentionally retained as test evidence.
