# VectorCraft reuse implementation audit

Audit date: 2026-10-09. Scope: implementation requirements in the
VectorCraft reuse specification supplied for Project Ink. This is a current
state audit, not an acceptance sign-off. The checkout contains extensive
pre-existing PhotoCraft changes; those files and their staging state were
preserved.

## Phase status

| Phase | Current evidence | Status |
|---|---|---|
| V0 mixed model, format 8, history and rendering | `ink-model` defines legacy and Bézier records; `ink-vector` rasterizes closed Bézier fills. Storage reads formats 2–8 and writes format 8 with `vector_semantics: 1`; tag 52 applies validated ordered edits. The engine publishes candidate geometry, rebuilt tiles and one history snapshot together. A document-level test covers legacy pixels, path/archive render, failed-patch atomicity, undo/redo, backup recovery and format-8 reopen. | Core compatibility acceptance is tested; memory/worker/public bridge requirements remain incomplete |
| V1 selection, recognition and editing | The pinned recognizer and fitter run through revision-checked preview/apply bridge calls. Paged summaries include IDs, kind, bounds and counts only; selected-object detail includes geometry plus subpath starts and closed flags. Rust hit-testing chooses the topmost visible/unlocked object within supplied document-space tolerance; Kurbo nearest-point and winding queries avoid fixed-chord misses, and vector-transform converts 8 logical screen pixels by viewport scale. Summary bounds include Bézier control handles and visible stroke expansion. The inspector supports explicit ID selection, candidate apply/cancel, Restore Original Ink, 0.25–8 px Fit Curve tolerance, anchor/handle edits, splitting/deletion and uniform transforms. Canvas hit-testing is asynchronous; stale results are rejected; Shift-click changes selection; path/legacy drags preview and apply once. Rectangle and ellipse candidates support Square/Circle constraints. Tests verify one-sample taps and unsupported hexagons return NoMatch without mutation, line/open versus closed-shape topology, four-anchor ellipse output, and three-anchor triangle classification. | Host acceptance is partial; installed canvas interaction remains open |
| V2 comic PDF | No comic PDF writer or project PDF export interface found. PhotoCraft-owned render-plan integration is not present in the inspected source. | Not started; dependency gate absent |
| V3 booleans, offsets and outlines | No Linesweeper dependency or path operation APIs found. | Not started |
| V4 raster tracing | A bounded RGBA-to-contours geometry helper exists, with tests for holes, diagonal separation, transparent pixels, alpha compositing, strict thresholds and component explosion. Component labels, direction grids, contour points, component output, fitted point buffers and anchor output use fallible reservation. Boundary walking and contour fitting have explicit edge/evaluation ceilings; fitted anchor growth stops at the shared 2,048-anchor limit. It does not snapshot a selected engine layer, preserve document-space region offsets, create a vector layer, preview/cancel, or atomically publish history. Fitting currently emits straight-segment contours. | Incomplete geometry prototype |
| V5 vector-pen hold | No vector-only preference, quiet timer, sample revision token or shared pen commit workflow found. | Not started |

## Shared-contract audit

- **Source pin and license:** partial. The new crate records VectorCraft commit
  `11fceda13e2423c28cd2c60d8d80689c760a54f8`, the three adapted source paths,
  Kurbo 0.13, local changes, and includes the upstream MIT license.
- **Dependency direction:** `ink-vector` depends on `ink-model` and Kurbo only;
  it does not depend on engine, storage, comic or Flutter.
- **Model:** legacy point/stroke types are defined in `ink-model` and re-exported
  from `ink-tools`. Bézier path, style, archive and validation types exist.
  A bounded mixed-object bridge projection exposes lightweight paged summaries
  and retrieves full detail for one selected object at a time. A shared model
  `VectorObjectView` type and broad compatibility tests remain absent.
- **Persistence and journal:** format 8 writes a tagged mixed-object payload
  using the existing vector sidecar and keeps per-layer object order. Formats
  2–7 load as `LegacyInk`; opening remains read-only and an explicit save
  migrates to format 8. Tag 52 now has `vector_semantics: 1` and a bounded
  little-endian encoding for legacy samples, path style/anchors and optional
  source archives; the prior nested JSON payload and `ink-command`'s unused
  `serde_json` dependency were removed. The encoder checks complete payload
  size and structure before document mutation, and the decoder rejects unknown
  semantics/object/style tags and malformed bounds. Tags 22–27 remain
  unchanged. Verify storage compatibility and old journal fixtures before
  treating the format gate as closed.
- **Transactions and rendering:** the engine keeps legacy strokes on their
  existing rasterizer path and renders Bézier fills via `ink-vector`. Tag-52
  edits build a candidate layer and its tiles before publication, then add one
  history entry and invalidate old/new allocated tile coordinates. This is a
  synchronous command path, not the planned off-lock capture/worker/preview/
  revision-checked transaction. Candidate construction starts with an empty
  tile store instead of cloning the old sparse tile map; old tile coordinates
  are captured separately for invalidation. `TileStore` history clones now
  share sparse tile maps and dirty sets through copy-on-write, while pixel
  buffers independently detach only when touched. The release clone benchmark
  improved from 309 ns to 11 ns per clone for its 64-tile fixture. However,
  `dispatch_state` still clones the complete layer map and vector geometry into
  `before_layers`; a write also detaches the sparse map of each touched layer.
  Peak-memory accounting for those snapshots and candidate geometry, candidate
  rasterization and retained history, plus document-level candidate retirement, remain incomplete. The
  candidate geometry, candidate rasterization and retained history, plus
  document-level candidate retirement, remain incomplete. Kurbo stroke-outline
  generation still needs internal work/allocation bounds; post-generation
  checks alone are not sufficient for the plan's resource contract.
- **Flutter and bridge:** FRB remains pinned to 2.13.0 and was regenerated from
  handwritten exports. Rust exposes paged mixed-object summaries, shape/fit
  preview, path-edit preview, apply/cancel, and original-ink restoration.
  Flutter has explicit list and canvas hit-test selection, Shift-click
  add/remove, inspector preview/apply/restore/edit controls, and transient
  candidate rendering in the viewport. Candidate request generations reject
  and cancel recognition/path-edit results that arrive after a newer preview
  or selection. Bézier anchors and handles can now be dragged on-canvas through
  candidate previews; detail projections preserve subpath boundaries. Square
  and Circle constraints update the active recognition candidate in Rust while
  retaining its token and source archive. Fit Curve exposes the documented
  0.25–8 pixel tolerance range with a 1 pixel default.
- **PhotoCraft exclusions:** no new text shaping, lettering, comic PNG/SVG,
  PSD, ABR, adjustment layer or stabilization capability was implemented as
  part of this vector work.

## Additional VectorCraft-derived improvements

These are follow-on additions beyond the V0–V5 reuse plan. They are intentionally
small and preserve Ink's existing Rust document authority and UI boundaries.

| Improvement | Implementation evidence | Boundary / remaining limit |
|---|---|---|
| Copy-on-write sparse tile snapshots | `TileStore` clones share tile and dirty-index maps through `Arc`; writes detach the changed map while untouched pixel buffers remain shared. Engine memory accounting reads payload sizes without copying tiles. A 64-tile release microbenchmark is in `ink-raster/benches/tile_store_history.rs`. | This reduces snapshot clone cost, but engine history still clones layer/vector geometry. The microbenchmark is not an end-to-end history or rendering benchmark. |
| Object-aware Smart Guides | Vector transform previews snap bounds, centers and fetched anchors to nearby vector objects, using an 8-logical-pixel tolerance converted by viewport scale. Temporary alignment lines are painted during preview; Rust geometry helpers and Flutter action/painter tests cover deterministic snapping and visibility. | Guide targets are the currently loaded object-summary page plus at most eight nearby detailed projections. It does not yet provide a document-wide spatial index or spacing guides. |
| Materialized vector repeat | Radial, grid and mirror operations create ordinary Bézier paths in one revision-checked `ApplyVectorPatch`; the UI exposes the operation from the selected path inspector. Rust tests verify transformed handles, limits, ordering and one-step undo/redo. | Repeats are editable copies, not live parametric groups. The operation is limited to 64 new objects and 4,096 combined anchors. |
| Property-based persistence/history checks | `ink-command`, `ink-storage` and `ink-engine` use generated valid Bézier records and patches to check tag-52 codec round trips, format-8 ordering/manifest data, replay, undo and redo. | Generated tests supplement fixed edge cases; they do not replace malformed-input fuzzing or full compatibility tests for every historical format. |

The current upstream README also highlights exact path operations, SVG/PDF
interchange, appearance stacks, live corners, width profiles and Shape Builder.
For Ink, the next useful product candidates are **live corner editing** and
**pressure-preserving editable vector widths**: they directly improve drawn
artwork without bringing in VectorCraft's text, application or renderer
subsystems. Interactive Shape Builder is a later option after Ink's bounded
boolean operations and selection UX are established. SVG interchange and rich
appearance stacks have larger persistence/export consequences and should stay
separate from this reuse batch. These are product recommendations, not copied
implementation claims; inspect the pinned source before adapting any code.

## Verification performed

- `cargo test -p ink-vector`: passed 20 tests after adding isolated/diagonal
  component and alpha-threshold cases. Those tests initially exposed a bug in
  closed-contour simplification that collapsed a one-pixel square below three
  anchors; the simplifier now falls back to the original contour in that case.
- `cargo test -p ink-vector fit_curve`: passed cubic-handle recovery from
  sampled curve data, endpoint preservation and sharp-corner preservation.
- The same suite verifies fit conversion retains sampled pressure/tilt exactly
  and uses the specified uniform-width and rounded-alpha formulas.
- `cargo test -p ink-vector path_transform_is_uniform_and_scales_stroke_width`:
  passed translation/rotation/uniform-scale coverage and rejects reflections.
- `cargo test -p ink-engine vector_ -- --nocapture`: passed 6 legacy vector
  regression tests, including the existing cross-architecture golden tile
  hash, undo and persistence; rerun after mixed-path rendering changes passed.
- `cargo test -p ink-command`: passed 7 tests, including tag-52 round-trip and
  malformed-edit rejection. `cargo clippy -p ink-command --all-targets -- -D
  warnings` passed. `cargo test -p ink-engine --no-run` compiled with the
  explicit unsupported-operation branch in place.
- `cargo test -p ink-model`: passed 4 tests, including the large-document
  coordinate-bound regression.
- `cargo test -p ink-vector`: passed 22 tests, including recognition, fitting,
  source archives, path transforms, tracing, and fixed-grid Bézier rasterization.
- `cargo test -p ink-engine bezier_patch_renders_undoes_and_survives_format8_reopen`:
  passed; verifies a filled path's pixels, failed-patch atomicity, unsupported
  legacy editing, undo/redo, format-8 reopen and recovery from a vector-sidecar
  corruption without changing the corrupt source file.
- `cargo test -p ink-storage vector_sidecar_round_trip_is_bounded_and_lossless`:
  passed; verifies format-7 read-only loading and explicit format-8 migration.
- `CARGO_PROFILE_DEV_DEBUG=0 CARGO_INCREMENTAL=0 cargo test -p ink_bridge vector_candidate_preview_apply_cancel_and_stale_revision_are_safe -- --nocapture`:
  passed after adding mixed-object paging and source restoration coverage. It
  verifies the restored samples match the original projection and undo returns
  through the converted path to the original state.
- `CARGO_PROFILE_DEV_DEBUG=0 CARGO_INCREMENTAL=0 cargo test -p ink_bridge`:
  passed all 64 bridge tests after adding lightweight summaries, selected-object
  detail retrieval, and topmost canvas hit-testing coverage.
- `CARGO_PROFILE_DEV_DEBUG=0 CARGO_INCREMENTAL=0 cargo test -p ink-vector`:
  passed all 25 geometry tests. The hit-test suite includes high-curvature
  nearest-point accuracy, transparent fills, fill-edge tolerance, and legacy
  sampled-stroke selection.
- `CARGO_PROFILE_DEV_DEBUG=0 CARGO_INCREMENTAL=0 cargo clippy -p ink-vector --all-targets -- -D warnings`:
  passed. The conversion/history bridge test also verifies that projected
  bounds contain every selected Bézier anchor and handle.
- `CARGO_PROFILE_DEV_DEBUG=0 CARGO_INCREMENTAL=0 cargo clippy -p ink-engine -p ink_bridge --lib --all-features -- -D warnings`:
  passed after the new hit-testing and selected-detail APIs. The broader
  `--all-targets` run still reports a too-many-lines lint in the existing
  PhotoCraft engine persistence test; that unrelated test was left untouched.
- `CARGO_PROFILE_DEV_DEBUG=0 CARGO_INCREMENTAL=0 cargo test --workspace --all-targets --all-features --quiet`:
  passed. This supersedes an earlier audit note that recorded a PhotoCraft SVG
  export failure; the current workspace result is green, including all 64
  bridge tests and 156 PSD-vendor tests.
- `flutter test test/canvas_tool_event_coordinator_test.dart`: passed 2 tests
  after wiring the canvas selection tolerance and vector hit-test action.
- `flutter test test/canvas_tool_event_coordinator_test.dart`: passed after
  vector hit-testing moved off pointer-down and Shift-click selection was wired.
- `dart analyze lib/canvas/canvas_vector_actions.dart lib/canvas/canvas_tool_event_coordinator.dart test/canvas_tool_event_coordinator_test.dart`:
  passed with no issues.
- `flutter test test/canvas_vector_candidate_painter_test.dart`: passed; records
  a candidate path through the canvas overlay painter without GPU readback.
- `flutter test test/canvas_vector_actions_test.dart`: passed; completes two
  overlapping preview requests out of order and verifies the stale candidate is
  cancelled while the latest one remains selected.
- `flutter test test/canvas_tool_event_coordinator_test.dart`: passed after
  verifying that Bézier movement previews during drag and commits on release.
- `flutter test test/canvas_vector_actions_test.dart test/canvas_tool_event_coordinator_test.dart test/canvas_vector_candidate_painter_test.dart`:
  passed 10 tests after adding subpath-aware handle targeting and a single
  preview/apply pointer-drag flow.
- `flutter test test/canvas_vector_actions_test.dart test/canvas_tool_event_coordinator_test.dart test/canvas_vector_candidate_painter_test.dart`:
  passed 11 tests with Square preview candidate replacement and custom fit
  tolerance coverage (`0.25` pixel reaches the Rust adapter).
- `cargo check -p ink-engine -p ink_bridge --all-features`: passed after
  extending vector detail projections with subpath starts and closure flags.
- `CARGO_PROFILE_DEV_DEBUG=0 CARGO_INCREMENTAL=0 cargo test -p ink-engine bezier_patch_renders_undoes_and_survives_format8_reopen --all-features`:
  passed with a two-subpath fixture and detail projection assertions.
- `CARGO_PROFILE_DEV_DEBUG=0 CARGO_INCREMENTAL=0 cargo test -p ink_bridge --all-features`:
  passed all 65 bridge tests, including candidate transactions and topmost
  hit-testing.
- `CARGO_PROFILE_DEV_DEBUG=0 CARGO_INCREMENTAL=0 cargo test -p ink_bridge --all-features`:
  passed all 67 bridge tests, including source-archive retention and candidate
  token stability through a shape constraint.
- `CARGO_PROFILE_DEV_DEBUG=0 CARGO_INCREMENTAL=0 cargo test -p ink-vector`:
  passed all 27 geometry tests after adding component-explosion rejection,
  fallible contour/fitting output construction, and rotated Circle/Square
  constraints.
- `CARGO_PROFILE_DEV_DEBUG=0 CARGO_INCREMENTAL=0 cargo clippy -p ink-vector --all-targets -- -D warnings`:
  passed after extracting per-component fitting and enforcing the in-loop
  boundary and fitting-work budgets.
- `cargo fmt --all -- --check` and `git diff --check`: passed.
- `CARGO_PROFILE_DEV_DEBUG=0 CARGO_INCREMENTAL=0 cargo clippy -p ink-vector --all-targets -- -D warnings`:
  passed after the geometry and trace-budget changes; `cargo check -p ink_bridge --all-features` also passed with regenerated shape-constraint bindings.
- `flutter test`: passed all 688 tests; `flutter analyze`: passed with no issues.
- `flutter test`: passed all 690 tests after adding the shape-constraint
  candidate flow; `flutter analyze`: passed with no issues.
- `flutter test`: passed all 691 tests after adding the Fit Curve tolerance
  dialog; `flutter analyze` and the focused 11-test vector UI suite passed.
- `CARGO_PROFILE_DEV_DEBUG=0 CARGO_INCREMENTAL=0 cargo test -p ink-engine --all-features`:
  133 of 134 tests passed. The unrelated in-progress pulled-string brush test
  fails its undo assertion (`pulled_string` remains true); its stabilization
  behavior was left outside this vector change.
- `CARGO_PROFILE_DEV_DEBUG=0 CARGO_INCREMENTAL=0 cargo clippy -p ink-engine -p ink_bridge --lib --all-features -- -D warnings`:
  blocked by two existing `too_many_lines` warnings in brush projection/draft
  functions. No Clippy suppression or brush refactor was added.
- `flutter analyze`: passed after updating outstanding in-progress brush-field
  call sites and removing unnecessary null assertions.
- `flutter test test/canvas_vector_actions_test.dart`: passed; verifies the
  transform applies the already-visible candidate once and marks dirty once.
- `flutter test`: passed all 686 tests after the asynchronous selection,
  additive-selection, viewport candidate-overlay and Bézier drag-preview changes.
- `flutter test`: passed all 680 Flutter tests after adding the required host
  tolerance and selection-method fakes.
- `flutter analyze`: reports two pre-existing informational curly-brace lints
  in `app/lib/layers/layer_adjustment_editor.dart`; no errors were reported in
  the vector files. A first Flutter test attempt failed because the disk filled
  during simultaneous Rust/Flutter builds; the serial retry passed.
- `flutter analyze`: passed after adding the paged projection adapter and
  restoration control. `flutter test test/workspace_panels_test.dart` and the
  full `flutter test` suite (680 tests): passed after the inspector path-edit
  dialog was added.
- `cargo test -p ink_bridge --all-features`: passed all 69 tests after adding
  legacy-vector translation preview/apply coverage, including exact preservation
  of pressure and tilt, no preview mutation, one apply, undo restoration, and
  retirement of a prior candidate after a failed replacement preview.
- `flutter test test/canvas_vector_actions_test.dart`: passed all 6 tests,
  including legacy translation preview samples and exactly one apply/dirty mark;
  `flutter analyze` passed.
- `flutter test`: passed all 692 tests with the legacy candidate path included.
- At this checkpoint `cargo fmt --all -- --check` reported differences in the
  engine test file. The added regression test was formatted narrowly; the
  latest full-workspace format check now passes (see the current revalidation
  below).
- `cargo test -p ink-command`: passed all 10 tests after replacing tag-52 JSON
  objects with versioned binary records; tests cover legacy and Bézier round
  trips, exact encoded-size accounting, 256 KiB rejection, unknown semantics,
  and unknown object tags. `cargo fmt -p ink-command -- --check` and strict
  command-crate Clippy passed.
- `cargo test -p ink-engine --lib oversized_vector_patch_is_rejected_before_document_mutation`:
  passed; an oversized two-object patch leaves revision, snapshot and history
  unchanged. A later engine Clippy attempt could not finish because the data
  volume had only 301 MiB free and incremental compilation returned ENOSPC;
  no build outputs or caches were deleted.
- `cargo clippy -p ink-engine -p ink_bridge --all-targets --all-features -- -D warnings`:
  passed after resolving the mixed-vector storage match lints and adding narrow
  explanations for the long projection and end-to-end persistence test.
- `cargo clippy -p ink-model -p ink-tools --all-targets -- -D warnings`:
  passed.
- `cargo clippy -p ink-vector --all-targets -- -D warnings`: passed after
  adding narrow, justified lint allowances around the pinned upstream
  algorithms and deterministic fixture tests.
- `cargo clippy -p ink-vector -p ink-command --all-targets -- -D warnings`:
  passed after tag-52 and rasterizer changes. A full-workspace Clippy run was
  not performed at that checkpoint; the current full-workspace result is
  recorded below.
- Current revalidation on 2026-10-09: `cargo test -p ink-command` passed 10
  tests; the latest `cargo test -p ink-vector` passed 30; `cargo test -p ink-storage`
  passed 28; `cargo test -p ink-engine --lib` passed 137; and
  `cargo test -p ink_bridge --all-features` passed 69. The engine suite
  includes `rejected_vector_patch_preserves_pending_brush_undo`, which checks
  that a failed patch does not consume a prior brush-library undo. The complete
  `cargo test --workspace --all-targets --all-features --quiet` run passed,
  including the pinned PSD parser's 156 tests, after adding tap NoMatch,
  recognized-path-topology, and source-archive save/recovery coverage. A later
  test-only hexagon fixture was covered by the 30-test `ink-vector` run and
  strict workspace Clippy; the full workspace test suite was not rerun after
  that fixture. Strict
  `cargo clippy -p ink-engine --lib --all-features -- -D warnings`,
  `cargo clippy -p ink-engine -p ink_bridge --all-targets --all-features -- -D warnings`,
  and `cargo clippy --workspace --all-targets --all-features -- -D warnings`
  passed. `cargo fmt --all -- --check` and `git diff --check` passed. Earlier
  storage and command attempts made while free space was critically low failed
  before exercising their cases; those failures were environmental and are
  superseded by these fresh passing runs.
- Source review found that successful-command history handling previously
  cleared a pending brush undo before vector-patch validation. The clear now
  occurs only after the command branch succeeds. The focused regression test
  and full engine/workspace suites pass with this ordering.
- The latest full Flutter verification used Flutter 3.47.5:
  `flutter analyze` reported no issues and `flutter test` passed all 693 tests.
- The initial full-workspace Rust format check found formatting only in the
  new regression test; that test was formatted without reformatting the other
  in-progress engine tests, and the repeated `cargo fmt --all -- --check`
  passed. `git diff --check` passed after the audit update as well.
- Fresh focused verification on the current checkout: `cargo test -p ink-vector
  --lib` passed all 36 tests; `cargo test -p ink-raster --lib` passed all 12;
  `cargo test -p ink-engine --lib` passed all 140; `cargo test -p ink-command
  --lib` passed all 11; `cargo test -p ink-storage --lib` passed all 29; and
  `cargo test -p ink_bridge --lib` passed all 70. These cover the generated
  format-8/tag-52 cases and materialized repeat's one-step undo. Flutter 3.47.5
  `flutter analyze` reported no issues; the four focused Smart Guides/vector
  action/inspector/painter files passed all 14 tests. `cargo fmt --all --
  --check` and `git diff --check` passed. An all-features bridge retry ran out of
  disk while recompiling; the default-feature bridge suite then passed. The
  full Flutter suite of 693 tests predates these additions and was not rerun.
- Installed-device acceptance was not run. The macOS `project_ink` process was
  already running, so it was left untouched; the connected Galaxy S23 Ultra
  has `org.projectink.studio` installed but Android Settings was foreground,
  and the iPad was not discoverable (CoreDevice error -27). No physical input,
  stylus, latency, or on-device save/reopen result is claimed.

## Acceptance gaps

| Plan acceptance gate | Evidence from current tests/source | Unverified or missing |
|---|---|---|
| V0 legacy pixels unchanged; new paths survive undo, recovery and reopen | Full-workspace tests include the legacy vector golden hash. The current engine round-trip test verifies a mixed Bézier path with an archived legacy stroke, undo/redo, recovery, and format-8 reopen. Tag-52 codec tests cover exact size and malformed records. | Full snapshot/candidate memory estimates, bounded in-loop stroke outlining, worker cancellation, allocation-failure atomicity, and document-level candidate retirement. |
| V1 shape conversion and Bézier editing | `ink-vector` covers recognition orientation/noise, open-line versus closed shapes, four-anchor ellipses, triangle conversion, tap and unsupported-hexagon NoMatch, fit tolerance/corners, pressure-derived uniform style, handle invariants, and transforms. Bridge tests cover preview/apply/cancel, archive restore, stale revision, hit testing, and legacy pressure/tilt preservation; Flutter tests cover candidate overlay, selection, drag flows, visible pressure-conversion disclosure, and visible NoMatch feedback. | No installed canvas acceptance. The host tests do not establish pen pressure/tilt behavior or the complete edit-preview workflow on macOS/Android/iPadOS. |
| V2 multipage comic PDF | PhotoCraft Phase 1 source currently has comic render-plan code. | No Krilla dependency, `ink-export` PDF writer, coherent project-page capture, export workflow, PDF rendering comparison, cancellation, or destination-failure fixture. |
| V3 booleans, offsets, outlines | No V3 operation tests exist. | Linesweeper and all operations are absent; topology, area, degeneracy, resource ceilings, and atomic history remain untested. |
| V4 black-and-white tracing | `ink-vector` tests alpha-over-white luminance thresholding, transparent pixels, four-connectivity, holes, oversized bounds, and component explosion. | No selected-layer snapshot, document-coordinate region offset, Bézier fitting, worker cancellation, preview, new vector layer, atomic combined journal patch, or engine-level source-preservation test. |
| V5 vector-pen hold | No V5 implementation or test found. | Preference, quiet timer, contact/sample revisions, native/Flutter ordering, one-terminal-commit behavior, cancellation, and installed macOS/Android pen checks are absent. |

V0's core compatibility gate now has document-level render, undo/redo, recovery
and reopen evidence, but the full V0 architecture gate remains open until
resource accounting, bounded stroke outlining and document-level candidate
retirement are implemented and verified. V1–V5 remain incomplete. Host tests
now cover Rust topmost hit-testing, nonblocking Flutter transform dispatch,
subpath-aware Bézier handle hit-testing, one-step handle-drag preview/apply,
and one-step legacy translation preview/apply;
they do not establish the complete installed canvas edit/preview workflow.
Other open gates include bounded cancellation inside expensive algorithms,
allocation-failure atomicity, PDF visual fidelity, boolean topology, trace-mask
coverage through an engine transaction, and installed-device pen behavior. Do
not treat the helpers or the partial V0 path as complete product features.
