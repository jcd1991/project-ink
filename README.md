# Project Ink

Project Ink is a free, offline-first drawing and comic studio for iPadOS,
iOS, Android, macOS, Windows, and Linux. It is designed around pen input,
fast touch gestures, reliable local documents, and a custom Rust drawing core.

The project is licensed under the Mozilla Public License 2.0 (MPL-2.0): files
can be reused in proprietary applications, while modified Project Ink files
must remain available under MPL-2.0.

## Status

The Phase 3.5 illustration/workspace foundation and all locally executable
verification are in place. Native texture-registry hookup, physical-device,
hosted Windows/Linux, and final release validation remain gated work. Physical
and external-platform acceptance is intentionally deferred to Phase 5 so
development can remain within the available memory budget.
The canvas now uses authoritative Rust composite tiles for committed artwork,
supports sixteen deterministic layer blend modes, and keeps an ephemeral live
stroke preview visible until the corresponding CPU tile is published;
the optional native surface supplies GPU composition when available, and the
CPU painter is the current Flutter fallback.
The workspace has explicit light/dark/high-contrast tokens, adaptive desktop
and tablet layout seams, a visible layer-properties inspector, and bounded
device-local workspace preferences. Comic metadata is v2 with source-preserving
v1 migration, stable page-document/panel-layer ownership metadata, and atomic
nested page-document storage behind one Rust-owned StudioProjectHandle. The
Flutter comic controller now uses that handle for metadata, page activation,
and project-manager structural undo/redo. Canvas drawing, layer commands,
tile reads, and complete-project saves now use an Arc-backed capability for the
active page document, so the project remains the document authority. Rust now
generates bounded live-dab packets and has an optional fixed-shader wgpu
surface; native Flutter texture-registry registration and physical latency
acceptance remain Phase 5.
GPU dabs are retained until CPU acknowledgement or cancellation, and preview
backpressure falls back to the CPU painter without interrupting a stroke.
Group visibility/opacity is resolved in Rust composite reads. The comic
inspector provides a Draw-inside-panel action that applies a scaled Rust
selection mask; panel guides align to the active canvas and never cover paint.
Entering Draw-inside-panel now atomically materializes and selects the panel's
Rust-owned PanelGroup and Ink child (with Sketch, Color, Tone, Effects, and
Mask siblings), persists the scaled polygon into the authoritative mask, and
keeps a transient selection clip for the active gesture. The unified Rust
StudioProjectHandle also materializes those trees during project open and
project-boundary panel add. Compatibility-controller resize, polygon, add,
and split edits still synchronize the active canvas mask through a bounded
transitional callback; the callback is now a compatibility seam for panel
geometry only, while drawing and persistence share the project page handle.
Phase 3 now has a Rust-owned comic model and FRB-backed workspace foundation:
bounded pages, panels/gutters, balloons/dialogue search, screentones, effect
lines, page reordering, webtoon segmentation, and an eight-page stick-figure
acceptance fixture. `.inkproj` checkpoint integration is complete; physical
cross-device comic acceptance is a Phase 5 gate. Comic structure is now preserved in a
validated `comic.json` sidecar inside native checkpoints. The comic workspace
also renders page/panel-mask thumbnails, exposes print-preview/moiré checks,
renders bounded trim/bleed/safety guides, and can export self-contained SVG
pages plus bounded structural manifests. The selected-page inspector now edits
dialogue and gutters through Rust-backed commands and shows polygon panel
geometry without mirroring document state in Dart.
The workspace also exposes a deterministic portable render digest so a
transferred project can be compared across devices without a server.
The bundled eight-page xkcd-style acceptance comic contains deterministic
vector stick figures in every panel, so exported pages and raster previews show
actual comic artwork rather than layout metadata alone.
Creation controls include panel splitting, circle/line/noise tones,
speed/focus/radial effect lines, and categorized local materials; webtoon
exports automatically use cropped SVG segments for long canvases.
The print-preview inspector also requests a bounded deterministic Rust PNG for
the selected page, including trim/safety guides, panel geometry, tones, effect
lines, balloon outlines, and offline text-length stubs; final typography and
color-managed export remain a separate production-export concern.
The Rust core has a working document model,
deterministic tiled raster engine, a versioned Phase 2 brush evaluator with
sketch/ink/paint/watercolor/effect presets, pointer packet decoding,
undo/redo commands, multi-layer blend compositing, and PNG/JPEG/WebP/
OpenRaster/SVG/flattened-PSD export. Pointer packets are consumed by a
dedicated Rust render worker;
native `.inkproj` persistence includes SQLite WAL metadata,
Zstandard tiles, atomic backups/recovery, and reversible history snapshots.
Predicted stylus samples render through an ephemeral tile overlay and are
discarded on confirmation or stroke completion, so prediction pixels never
enter saved documents or undo history.
Command-journal payloads are version-decoded and validated before publish and
during reopen, so malformed journals cannot silently load from disk.
Flutter 3.47.5 runners, FRB 2.13.0 bindings, Cargokit packaging, native
packet encoders, the Rust-backed Dart adapter, and revision-aware dirty-tile
composition are in place. Native iOS Pencil, Android S Pen, and macOS AppKit
tablet EventChannel transport is now wired. Apple Pencil double-tap/squeeze
commands, desktop/S Pen side-button eraser toggles, quick-pinch fit-canvas, and
undoable eraser packets are also wired; physical-device latency validation is
deferred to Phase 5. Startup now calls the generated FRB engine-health marker
before document creation, and the canvas exposes a bounded local performance
snapshot hook for those hardware runs.
When a local trace path is enabled, Apple platforms add a native resident-size
sample and Android adds a diagnostic PSS estimate; acceptance still requires
the platform memory tools in the physical-device runbook.
The same trace counts confirmed and predicted samples, detects native sequence
gaps, and records rejected confirmed packets; the evaluator fails confirmed
sample delivery when any of those signals indicate loss.
Pointer delivery is fail-closed: a malformed packet or bridge error cancels
the active stroke through the Rust engine rather than leaving a partial stroke
committed.
The Dart control plane also exposes native `.inkproj` open, atomic save-as, and
deterministic PNG export. The picker contract is path-based because the native
project is directory-backed; the current default is an offline app-owned
Documents fallback, with native desktop dialogs and Android directory
selection enabled when they return a local path. Android SAF and iOS Files
project-open selections are staged locally before Rust sees them; provider
project saves can be transactionally written back when the provider grants a
writable parent, and completed PNG exports can be promoted beside that project
with the same capability check. Rust never receives an
unresolved URI.
The canvas now has injected Open, Save, and Export PNG toolbar actions with
gesture isolation. The default offline picker stores projects in each
platform's app Documents container when a native selector cannot provide a
local path.

Phase 5 physical Pencil/S Pen acceptance uses the checked-in
[`specifications/physical-device-acceptance.md`](specifications/physical-device-acceptance.md)
runbook and the local trace evaluator under `tools/`.
Phase 5 transfer acceptance for the Phase 3 comic workflow uses
[`specifications/phase3-device-acceptance.md`](specifications/phase3-device-acceptance.md);
the portable digest is a comparison aid, not a substitute for testing the
listed physical devices.
For Android testing, the current debug artifacts are available as the normal
[`project_ink-debug.apk`](outputs/project_ink-debug.apk) and the opt-in
[`project_ink-phase1-trace-debug.apk`](outputs/project_ink-phase1-trace-debug.apk).

## Build the Rust core

```sh
cargo test --workspace --all-targets --all-features
cargo clippy --workspace --all-targets --all-features -- -D warnings
```

The Flutter toolchain is intentionally kept separate from the Rust workspace.
Run `flutter pub get`, `flutter analyze`, and `flutter test` in `app/`.

### Project Ink app QA rule

Before starting any UI test, inspect the running-app list and close every
Project Ink instance left by earlier tests. Treat only known test-session,
unsaved changes as disposable; do not discard a named user project or another
app's work. Run one Project Ink instance at a time, then quit it after the test
and verify both its window and process are closed before handing the computer
back.

## Design constraints

- No account, advertising, subscription, or required network service.
- Rust is the source of truth for documents, pixels, layers, brushes, history,
  persistence, and exports.
- Flutter owns responsive controls, viewport transforms, gesture arbitration,
  accessibility, and visible tile composition.
- The `.inkproj` format is versioned and recovery-safe; unknown future versions
  open read-only or fail without modifying the source document.

See `specifications/` for the stable wire formats and `IMPLEMENTATION.md` for
the phased handoff checklist.

For a reproducible local CPU baseline, run
`cargo run -p ink-engine --release --example phase1_benchmark`. The output is
JSON and intentionally separates engine timing/memory evidence from the
Phase 5 physical-device latency gates that still require iPad, Android, and
desktop tablet runs.
The trace evaluator's deterministic pass/fail smoke fixtures live under
`fixtures/phase1_trace/` and are exercised in CI.
The Rust CI lane fails regressions above 8 ms packet-to-dirty p95, four dirty
fixture tiles, or 900 MB of estimated engine-owned memory.

## Code ownership boundaries

- `ink-engine/src/lib.rs` remains the public `Document` façade. Private modules
  own command dispatch, engine state, the bounded render worker, confirmed
  stroke processing, brush operations, rendering, persistence conversion,
  history limits, and engine tests. Cross-module state visibility stays
  `pub(super)`; Rust public methods and serialized project formats remain at
  the existing façade.
- `ink-bridge/src/api.rs` keeps the FRB-exported Rust functions at their current
  `crate::api` paths. Its tests live under `api/tests.rs`. Generated transport
  is isolated in `frb_generated`; the handwritten Apple Metal texture handoff
  is the only unsafe call in `api.rs` and has a local safety explanation.
- The Flutter bridge contract and production/in-memory adapters live under
  `app/lib/bridge/engine_api/`; the original `engine_api.dart` import path
  remains an export façade. `ComicWorkspaceController` owns the Rust comic
  project capability, and comic projections/painters live in
  `comic_presentation.dart`.
- `CanvasScreen` remains the Flutter composition/lifecycle point. Input queue,
  live stroke preview, tile cache, autosave, native surface, and independent
  workspace components retain their existing collaborators. Preserve the
  serialized confirmed-packet queue, page rebinding, save-before-close order,
  undo/history transaction boundaries, and CPU fallback when editing these
  seams.

See [`app/README.md`](app/README.md) for controller disposal order and the
pinned flutter_rust_bridge 2.13.0 generation command.
