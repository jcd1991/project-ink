# Fresco-informed workflow action plan

Audit and implementation batch date: 2026-10-11. Use this document as the
handoff record for small, sequential model assignments. The first batch is
implemented in the current checkout; its evidence and outstanding device gates
are recorded below. The next unassigned work is design-only and is described in
[`fresco-follow-up-design-queue.md`](fresco-follow-up-design-queue.md).

## Product comparison and evidence

The comparison is about drawing workflows, not feature-count parity. The videos
show artists returning to recent work, adjusting pressure and stabilization
between sketch and ink, painting on masks, using references to guide color and
shading, and keeping layer targeting clear while working on touch devices.
Project Ink already has substantial engine capabilities—brush pressure curves,
stabilization, masks, clipping, groups, reference flags, fill tolerance and gap
closing, recovery checkpoints, and editable imports/exports. The highest-value
near-term work was to make existing capabilities easier to reach and safer to
understand, then close the Flutter path to an existing Rust mask feature.

Sources reviewed:

- [Ten Hundred video](https://www.youtube.com/watch?v=XRtNFJKXIgw)
- [Chris Piascik video](https://www.youtube.com/watch?v=IZ_tZcPuBog)
- [Adobe Fresco on iPhone](https://helpx.adobe.com/fresco/desktop/introduction/fresco-on-iphone.html)
- [Adobe Fresco layers](https://helpx.adobe.com/fresco/desktop/draw-paint-animate-and-share/layers.html)

The video notes cover the full videos, including sections outside the supplied
timestamps; they are workflow evidence, not a frame-by-frame visual audit.

| Area | Adobe Fresco evidence | Project Ink evidence and direction |
|---|---|---|
| Start and resume | The iPhone guide documents a Creative Cloud `Your files` library, sync status, create/import/open, and export across devices. The videos also demonstrate returning to recent work and choosing canvas sizes. | Project Ink remains local-first. The new device-local recent list improves return-to-work without adding accounts or cloud state. Keep canvas presets and a gallery as separate follow-up design work. |
| Phone workspace | Fresco documents a mobile toolbar, per-tool options, hideable layer stack, full-screen mode, touch shortcut, brush size/smoothing/settings, quick export, and time-lapse video export. | Project Ink has responsive phone controls plus tablet/desktop docks. This batch adds a direct brush settings route and target context. Verify actual pen/touch feel on devices before claiming parity. |
| Layers and paint safety | Fresco documents frequent taskbar actions plus contextual layer actions, groups, multi-selection, masks, and adjustment layers. | Project Ink already has Rust-backed groups, masks, clipping, adjustments, and preflight reasons. This batch clarifies the active target and connects the UI stroke path to Rust mask painting. |
| Product boundary | Fresco documents cloud documents and cross-device access. Its mobile guide includes built-in tutorial/community entry points. | Project Ink is offline/local-first and has no account or telemetry requirement. Preserve that distinction; focus on file safety, comics, and local control instead of copying cloud dependencies. No web editor was found in this checkout. |

The iPhone help page says it was last updated September 30, 2026; the layers
page says August 18, 2026. Product-specific claims above are grounded in those
official pages, while the artist workflow observations come from the full-video
notes.

**Platform scope:** this checkout contains the Flutter native app and desktop
workspace. No `app/web` target or web build entry was found, so the implementation
below covers phone, tablet, and desktop. The browser viewer remains a proposed
read-only export, not evidence that a web editor exists. If “our web app” means
a separate product, audit that repository before making web-specific claims.

## Shared instructions for a coding-model handoff

> Work only on the assigned task. Read `AGENTS.md`, inspect the current branch
> and working-tree diff, and preserve all existing changes. Locate the named
> owner before editing and reuse existing services and action routing. Rust
> remains authoritative for project state, pixels, layers, brushes, history,
> persistence, and export; Flutter owns presentation and temporary UI state.
> Preserve serialized formats, packet contracts, public APIs, generated bridge
> interfaces, local-first operation, and recovery guarantees.
>
> First report the relevant existing behavior and a short edit list. Make the
> smallest coherent change, add focused behavioral tests, and update the nearest
> documentation. Do not refactor unrelated code, introduce dependencies,
> regenerate unrelated outputs, commit, push, or delete files. If the task needs
> a new format, engine API, or architecture, stop with the evidence and a
> proposed contract rather than improvising.
>
> Report changed files, actual test results, baseline failures, and physical
> device checks still required. A host test or build is not installed-device
> acceptance.

Run one task at a time. Use cheaper coding models for bounded Dart presentation
and navigation changes. Use stronger review for save ordering, input routing,
mask behavior, persistence, and any Rust work.

## First batch: completed implementation tasks

### T0 — Record the baseline

**Owners:** save projection, brush controls, phone layout, layer actions, fill,
and mask stroke targeting.

**Done:** [`fresco-workflow-baseline.md`](fresco-workflow-baseline.md) records
the pre-change behavior and its focused test evidence. It distinguishes existing
capabilities from missing routes and does not label untested device behavior as
verified.

### T1 — Clarify saving and recovery status

**Owners:** `AutosaveCoordinator`, document actions, and status presentation.

Presentation now distinguishes pending edits, recovery save progress/success,
named project save success, and recovery failure. Recovery completion does not
claim that a named project was saved. Retry is exposed for recovery failure;
project-save errors identify the operation and stay retryable. Provider
write-back and revision checks remain in the existing save path.

**Acceptance:** status projection tests cover pending edits, recovery, explicit
save, and errors; document-action tests cover failed provider write-back and
failed Save As. Device layout acceptance remains required for phone and desktop.

### T2 — Route directly to brush stroke and pressure settings

**Owners:** phone/compact controls and the existing brush editor.

Brush controls expose direct Stroke and Pressure routes, selected-brush context,
smoothing percentage, and pulled-string state. Edits continue through the
existing brush-editor draft/apply/cancel lifecycle; no global override was
added. Short phone sheets scroll rather than overflow.

**Acceptance:** phone-control tests cover the route and narrow sheet; canvas
integration tests exercise compact controls. Test both phone orientations,
tablet presentation, and enlarged text on installed devices. On the Galaxy,
the phone sheet showed Technical Pen context and Stroke/Pressure routes.
Selecting Pressure for the built-in brush returned to its library; source
behavior requires duplicating factory brushes before editing their pressure
curves. No brush was duplicated or changed, so the custom-brush edit path still
needs a device check.

### T3 — Clarify the selected layer target

**Owners:** layer-panel presentation and existing `CanvasLayerActions`.

The layer panel now identifies the selected layer, kind, target state, mask
owner, clipping base, or containing group. Existing labeled layer menus remain
the action surface for raster, mask, group, and multi-selection operations;
availability and Rust preflight reasons stay authoritative.

**Acceptance:** widget tests cover mask owner and clipping base; layer-panel and
screen tests cover existing actions and target updates. Review panel fit and
200% text scaling on installed devices.

### T4 — Connect mask painting to the shared stroke path

**Owners:** `CanvasStrokeStartCoordinator`, preview policy, and Rust mask
rendering.

The shared stroke-start gate admits visible, unlocked masks as well as raster
layers. Selected-mask context says “Black hides; white reveals.” Colored/GPU
stroke previews are suppressed for mask targets so the Rust CPU composite stays
the visible truth. Existing Rust mask semantics and packet/API contracts are
unchanged.

**Acceptance:** Dart tests cover mask acceptance and invalid/hidden/locked
targets. Existing Rust engine tests cover black hide, white reveal, composite
coverage, undo, and persistence behavior. Before release, verify native and
Flutter input, cancellation, document replacement, undo/redo, unchanged owner
artwork, and save/reopen on Android/S Pen and iPad/Pencil. These physical checks
are not claimed complete by this implementation batch.

### T5 — Improve bucket fill

**Owner:** `CanvasToolActions` plus the existing brush-color picker and fill
commands.

Fill now starts from the active brush color, offers a color swatch and existing
picker, keeps numeric RGB/tolerance/gap controls and gradient fill, explains the
controls, validates ranges inline, and reports command failure through the
existing message callback. Failed commands do not mark the document dirty.

**Acceptance:** focused tests cover active-color initialization, picker result,
invalid values, cancellation, and failure feedback. The canvas integration test
confirms fill still targets the selected primary raster layer. Verify reference
layer behavior and undo on device.

### T6 — Add device-local recent projects

**Owners:** document-action completion and `RecentProjectsStore`.

The app stores up to 20 local project directories with display name and
last-used time. It deduplicates and orders entries, retains unavailable paths
for removal/reconnection, and excludes provider URIs, temporary paths, and
staged provider projects. Opening a recent item uses the ordinary replacement
confirmation and barrier; removal edits only preference metadata.

**Acceptance:** service tests cover MRU order/cap, persistence across store
instances, missing paths, and excluded URIs/temp paths. Document-action tests
cover opening/removing recents and replacement handling. Provider-backed
documents remain available from the normal Open picker.

## Batch validation and limits

The initial pre-change baseline passed 77 focused tests and `flutter analyze`.
After implementation, the focused owner set passed, the canvas screen
integration set passed all 36 tests, and the project app plus fill-action set
passed all 21 tests. `flutter analyze` reported no issues. The final full Flutter
suite passed all 730 tests on 2026-10-11 (`flutter test --no-pub` from
`app/`); this supersedes an earlier 830-test count in the draft. The
editor-layout suite passed all 119 cases after its snapshots were updated for
the direct brush-settings control and selected target header. Representative
desktop, tablet Simple/Studio, high-contrast, and 150%/200% text layouts were
reviewed. The original editor-layout goldens were copied before refresh to
`/tmp/project-ink-fresco-goldens-before-update-20261011/editor_layout`.

The Rust engine mask regression filter passed all 15 tests, including black
hide/white reveal, mask undo, and mask save/reopen coverage. The mask-paint test
now also checks owner pixels remain byte-identical when the mask is disabled.
At the end of the original 2026-10-11 implementation batch, the two
screen-level routes (Android Flutter stylus and native iOS packets) and
stroke-start tests passed all 30 tests, including rejection beneath a locked
parent group; the wider owner batch passed 198 tests before that small lock-gate
addition. At that time, the full workspace format check reported ordering
differences in the generated FRB file and strict Clippy found two
`manual_is_multiple_of` warnings in `ink-brush/src/v2.rs`. Those issues were
resolved in the later source snapshot; the current snapshot checks are recorded
below.

## Later source snapshot validation

On 2026-10-15, the committed source snapshot passed
`cargo fmt --all -- --check`, the locked full workspace Rust test suite with
all targets and features, strict workspace Clippy with `-D warnings`,
`flutter analyze`, and the full Flutter suite (730 tests). These are host checks for that source
snapshot. Platform builds and installed-device acceptance were not rerun against
it, so the earlier Android result is historical evidence and does not
establish release readiness for these commits.

On 2026-10-11, Android was verified on a Galaxy S23 Ultra (SM-S918U1, Android
16) with an arm64 profile APK installed under the parallel
`org.projectink.studio.debug` package. The user made a physical S Pen stroke;
two-finger Undo, three-finger Redo, and touch-stroke cancellation were reported
working. A physical black stroke on an attached mask hid part of the line;
disabling the mask showed the unchanged base line, and a white stroke revealed
the segment again. The named project was saved and reopened from Recents, with
the mask composite intact. The user then performed the ordered Undo → canceled
touch stroke → Redo check. The final screenshot showed the line restored and no
stray touch mark, so the prior Redo branch survived cancellation; the named
project was saved afterward. The latest short trace reported 2,060 confirmed
samples, no sequence gaps or rejected packets, and 17.179 ms worst recorded p95
against the 40 ms S23 target. The trace evaluator passed latency and
confirmed-delivery checks. `dumpsys meminfo` after this small project reported
252,172 kB PSS and 317,480 kB RSS; these are not measurements of the documented
4096×4096/20-layer scenario. Studio mode was opened in portrait and reported
that compact controls were in use at this phone width; the mask target label
remained legible. Tablet Studio and landscape layouts remain open, as do the
one-hour drawing run, S Pen pressure/long-stroke checks, and scenario-matched
authoritative RSS evidence.

No files were removed during the 2026-10-11 Android preparation. At that
check, the host had 2.8 GiB free, below the documented 18 GiB iOS simulator-run
floor; the simulator suite was not run and no physical iPad/Pencil was
connected. Installed macOS interaction and browser acceptance also remained
outstanding. The checkout contains no web editor target, so browser-viewer work
remains a design task, not web-app acceptance. Run
`app/tool/run_ios_acceptance.sh --simulator` only when its 18 GiB floor is met.
Host tests and the earlier Android checks do not substitute for the
iPad/Pencil, macOS, or browser gates.
Chrome device discovery alone does not establish a configured browser build.
See
[`physical-device-acceptance.md`](physical-device-acceptance.md) and
[`device-test-matrix.md`](device-test-matrix.md) for the device gates.

## Follow-up handoffs

Assign the six design-only tasks in
[`fresco-follow-up-design-queue.md`](fresco-follow-up-design-queue.md) one at a
time: reference/palette surface; project gallery; comic PDF; faithful playable
time-lapse; read-only browser viewer; and timeline animation. Defer vector
intersection trimming, multicolor brush sampling, arbitrary off-canvas artwork,
and richer wet-paint simulation until each has its own engine contract and
performance budget.
