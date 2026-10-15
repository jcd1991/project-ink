# Fresco-informed workflow baseline

Audit date: 2026-10-11. This records source and host-test evidence before the
workflow improvement batch. It is not installed-device acceptance.

Platform scope: the inspected checkout contains the Flutter native app and
desktop workspace, but no `app/web` target or web build entry. Browser viewing
is therefore a proposed future export, not an existing web editor. If the
comparison is meant to include a separate web product, its repository still
needs an audit.

| Workflow | Current evidence | Status |
|---|---|---|
| Recovery and save status | `AutosaveCoordinator` tracks dirty, saving, checkpoint, and error state. `CanvasScreen` currently compresses these into “Saved”, “Unsaved changes”, and “Save failed”; recovery checkpoints and named project saves are not distinguished in the visible label. Explicit save already includes provider write-back and revision validation. | Core behavior and focused host tests verified; status wording/retry affordance incomplete |
| Brush pressure and smoothing | Brush library already has Stroke and Pressure sections, pressure curves, stabilization, and pulled-string controls. `CanvasQuickControls` exposes size, opacity, brush library, and eraser, but no direct route to the Stroke/Pressure sections. | Existing control behavior verified in source; quick route incomplete |
| Layers and paint target | Layer panel supports target selection, groups, multiselect, masks, clipping, reference state, layer actions, and group opacity. Selected layer is displayed in quick controls; mask owner is identified in row labels. | Existing panel behavior has host tests; compact selected-target context remains incomplete |
| Mask drawing | Rust `BeginStroke` accepts raster and mask layers and renders mask dabs. `CanvasStrokeStartCoordinator` currently rejects every selected target except raster, so Flutter cannot reach the Rust mask path. | Incomplete at Flutter stroke-start boundary; mask end-to-end behavior unverified |
| Bucket fill | Fill dialog already exposes RGB, tolerance, gap closing, and gradient. It starts from a fixed orange color and invalid values/failures have limited user-facing feedback. | Existing fill engine path verified by source; color initialization and feedback incomplete |
| Project navigation | Platform picker opens/saves projects and app recovery is separate. No local recent-project index was found in the inspected app preferences or document-action owners. | Recent-project navigation incomplete |

## Baseline checks

- `flutter test test/autosave_coordinator_test.dart test/canvas/canvas_stroke_start_coordinator_test.dart test/layer_panel_gesture_test.dart test/canvas_tool_event_coordinator_test.dart` from `app/`: 77 tests passed.
- `flutter analyze` from `app/`: passed with no issues.
- An initial test invocation used the wrong stroke-start test path and failed to load that file; the corrected command above passed.
- Physical Android/S Pen, iPad/Pencil, and other installed-device workflows were not run as part of this audit.

## Post-batch evidence

The T1–T6 implementation is recorded in
[`fresco-workflow-action-plan.md`](fresco-workflow-action-plan.md). The latest
complete Flutter suite passed all 730 tests; 15 Rust mask regression tests and
`flutter analyze` also passed. The relevant editor-layout snapshots were
updated and visually reviewed. The Galaxy S23 Ultra S Pen mask, touch-history,
and save/reopen checks now have a bounded physical result; see
[`physical-device-acceptance.md`](physical-device-acceptance.md) for its exact
scope and remaining gates. The iPad simulator suite was not run because current
host free space is below its 18 GiB floor, and no physical iPad/Pencil is
connected. Installed macOS and browser acceptance remain open; the checkout
contains no web editor target. Preserve the unrelated in-progress changes and
generated/build outputs while assigning the remaining work.
