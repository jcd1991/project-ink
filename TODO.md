# Project Ink implementation queue

## 1 — foundation (in progress)

- [x] Rust workspace and toolchain pin.
- [x] Stable model, command, pointer packet, brush, tile, and engine seams.
- [x] Deterministic unit tests and clippy-clean workspace.
- [x] Bounded pointer queue preserving confirmed samples over predicted input.
- [x] Dedicated Rust render worker drains the bounded queue and synchronizes
  tile/event state before commands, reads, and saves observe it.
- [x] Reversible tile/layer undo and redo, including persisted history snapshots.
- [x] Canceling an active stroke restores the pre-stroke snapshot and removes
  its provisional history entry.
- [x] Flutter tile-cache contract that rejects stale revisions.
- [x] Deterministic PNG encoding and engine export for the visible raster layer.
- [x] iOS/macOS/Android pointer-packet v1 encoders with little-endian layout.
- [x] Flutter responsive canvas shell and default gestures.
- [x] Install Flutter 3.47.5; generate the five runner projects and commit
  `app/pubspec.lock`.
- [x] Pin Flutter 3.47.5 in `app/pubspec.yaml` and configure native-host CI
  build lanes for macOS/iOS, Android arm64, Windows, and Linux.
- [x] Generate and commit `flutter_rust_bridge` v2.13.0 bindings from
  `ink_bridge`.
- [x] Add the FRB-backed Dart engine adapter and Cargokit native plugin.
- [x] Bridge dirty-tile revisions as fixed-width packets and compose Rust BGRA
  tiles in Flutter without painting on the UI thread.
- [x] Implement SQLite/WAL metadata, compressed tiles, atomic `.inkproj` saves,
  backup recovery, and source-preserving corruption handling.
- [x] Decode and validate every persisted command-journal payload on reopen;
  malformed journals fail without modifying the source document.
- [x] Add checkpoint-stage fault injection proving failed saves preserve the last
  published project.
- [x] Exercise actual subprocess termination at each save/publish stage and
  verify the last project or atomic backup remains recoverable.
- [x] Decode and replay v1 command-journal commands for layer/history
  compatibility; raster pixels remain checkpoint data.
- [x] Add a release-mode Phase 1 benchmark and recorded-stroke golden tile hash;
  physical stylus/display latency and RSS traces remain required.
- [x] Add a bounded Flutter packet-to-post-frame trace hook for physical-device
  latency runs, including p95 and dirty-tile reporting without telemetry.
- [x] Add optional native process-memory samples to local traces on Apple
  platforms and Android; keep platform memory tools authoritative.
- [x] Add an opt-in `PROJECT_INK_TRACE=true` entry-point path for collecting
  timestamped device traces without changing normal builds.
- [x] Record confirmed/predicted sample counts, native sequence gaps, and
  rejected confirmed packets in the physical-device trace evaluator.
- [x] Keep packet-accounting and latency trace work off the normal production
  path unless an acceptance hook or trace file is explicitly enabled.
- [x] Enforce the v1 256-sample packet bound in the Dart/native transport seam
  before coordinate transforms or trace accounting.
- [x] Enforce the same bound in the iOS, macOS, and Android native encoders,
  preferring confirmed samples over coalesced and predicted samples.
- [x] Run the Android native packet unit test in the hosted Android build lane.
- [x] Make Android CI install and verify both the locked NDK 27.1 toolchain and
  the plugin-required NDK 28.2 compatibility toolchain.
- [x] Cancel an active stroke when native or generic packet delivery fails, so
  bridge errors cannot leave a partially committed stroke in the document.
- [x] Add a Flutter regression test proving a generic pointer bridge failure
  invokes Rust cancellation and cannot leave the stroke active.
- [x] Make the hosted desktop CI lanes explicitly enable and report their
  Flutter targets before building.
- [x] Add CI guardrails for the Phase 1 CPU benchmark's latency, dirty-tile,
  and engine-memory regression signals.
- [x] Prevent production startup from silently substituting the Dart in-memory
  engine when Rust initialization fails.
- [x] Reject trailing bytes and unknown lifecycle phases in pointer packets;
  malformed native input cannot be reinterpreted as cancellation.
- [x] Preserve stable layer IDs and validate parent relationships during layer
  commands and native-project reopen.
- [x] Render predicted pointer samples as ephemeral previews; never persist
  them in `.inkproj` snapshots or undo history.
- [x] Add and call a generated FRB engine-health marker before document creation.
- [x] Expose native `.inkproj` open, atomic save-as, and PNG export through the
  shared Dart engine contract.
- [x] Add a debounced autosave coordinator that retries failed checkpoints and
  is driven by stroke and undo/redo mutations.
- [x] Implement quick-pinch fit-canvas behavior with conservative gesture
  arbitration thresholds and Flutter tests.
- [x] Route Apple Pencil double-tap/squeeze commands through a dedicated
  EventChannel, add Android/macOS tablet-button toggles, and make eraser
  packets clear pixels through the Rust engine.
- [x] Add the injected document-picker seam and wire open/save/export toolbar
  actions while keeping the Rust path contract platform-neutral.
- [x] Implement the default offline picker adapter using app-owned Documents
  storage on all targets, plus iOS Files exposure.
- [x] Add native directory selection on Android plus native directory/save
  dialogs on desktop, with local-path validation and offline fallback.
- [x] Add Android SAF and iOS/iPadOS Files project-open staging with bounded
  copies, preserving a local filesystem path before Rust opens the document.
- [x] Add transactional provider write-back for staged project saves when a
  writable parent is granted; keep root-folder imports local-only on fallback.
- [x] Add provider write-back for PNG exports and mobile project-name prompts
  without changing the Rust path contract.
- [x] Phase 2 export encoders for JPEG, WebP, OpenRaster, SVG, and bounded
  flattened PSD, with signature/container regression tests.
- [x] Connect iOS/iPadOS, Android, and macOS native pointer adapters to the
  shared binary EventChannel and Rust engine path; physical-device validation remains.
- [x] Make each hosted platform build lane verify and upload its debug output
  with checksums, so Windows/Linux runs produce auditable Phase 1 evidence.
- [x] Run the iOS native packet regression in the hosted macOS/iOS CI lane.
- [x] Keep generic stylus input enabled until each native packet EventChannel
  reports readiness, preventing startup races from swallowing first input.
- [x] Re-run the Android native unit test after the readiness-channel change.
- [x] Add an iOS native regression for the pointer-channel readiness event.
- [x] Add macOS native packet/readiness regressions and run them in the Apple
  CI lane.
- [x] Add checked-in Phase 1 trace pass/fail fixtures and CI evaluator smoke
  checks.
- [x] Add widget regressions for the implemented two-, three-, and four-finger
  touch commands.
## 2 — illustration alpha

- [x] Rust layer flags for groups, masks, clipping, alpha lock, reference
  layers, labels, names, and sixteen deterministic blend modes, persisted in
  native projects and included in composite export. Masks are drawable alpha
  stencils for the preceding paint sibling; group visibility/opacity propagate
  through parent chains in the Flutter compositor.
- [x] Persist sibling layer order through the native layer sequence and route
  visible move-up/move-down controls through the undoable `MoveLayer` command.
- [x] Expose undoable leaf-layer deletion through the Rust/FRB/Flutter path,
  require explicit confirmation, repair selection after deletion, support
  undoable ordinary-group subtree deletion, and protect comic-owned layers.
- [x] Add parent-aware layer creation so selected groups and panel groups can
  receive child layers through the same undoable AddLayer command.
- [x] Deterministic Phase 2 brush model with twelve built-ins spanning sketch,
  ink, paint, watercolor, smudge, texture, spray, ribbon, and bristle tools;
  pressure curves, taper, grain, scatter, rotation, dual brushes, validation,
  native `.inkbrush` packs, and honest guided external-import reports.
- [x] Implement bounded declarative post effects (watercolor edge,
  soften/sharpen, stamp outline, trailing fade, and texture pass) with
  deterministic stroke-finalization, selection awareness, undo integration,
  legacy-preset defaults, and hostile-value validation.
- [x] Rust illustration-tool foundations for rectangle/ellipse/lasso/color
  range/flood selections, bounded gap closing, affine transforms, vector ink
  simplification, pressure width, and straight/parallel/symmetry/radial/
  perspective ruler snapping.
- [x] Rust-owned rectangle, ellipse, lasso, layer-opacity, and color-range
  selection masks now constrain committed and predicted raster dabs; Flutter
  exposes them through an illustration-tools palette, overlays, and a bounded
  RGB/tolerance dialog for color-range selection.
- [x] Ruler overlays snap generic and native transformed pointer samples before
  they enter the Rust brush engine.
- [x] Rust-backed brush/layer projections, responsive brush-library and layer
  panels, selected Phase 2 brush routing, and generated FRB bindings for the
  brush/import/export/layer APIs.
- [x] Rust-owned brush editor settings, per-stroke preset capture, brush
  import/install/export bridge paths, and undoable layer flag editing.
- [x] Bounded `.inkproj` brush-library persistence with save/reopen coverage;
  edited and imported presets survive recovery-safe checkpointing.
- [x] Full multi-point pressure-curve editor and bounded textured-resource
  inspection metadata; decoded RGBA8 image-tip resources are hash-addressed,
  bounded, persisted in `.inkproj`, sampled by the renderer, and rejected
  before staging when malformed.
- [x] Brush-library import/export actions through the optional platform picker,
  including guarded PNG/JPEG/WebP tip import and a full-source-hash inspection
  regression.
- [x] Show bounded compatibility reports before installing external brushes;
  native `.inkbrush` and multi-member `.inkbrushpack` archives include
  deterministic previews, full-source hash verification, and reject
  duplicate/case-colliding entries, missing resources, and decompression-ratio
  bombs; pack installation is all-or-nothing.
- [x] Convert bounded Krita `.bundle` archives by scanning only `.kpp` members;
  preserve the bundle hash, keep unrelated members inert, and install all
  converted presets transactionally through the shared Rust command boundary.
- [x] Add Flutter regression coverage proving multi-member Krita bundles use
  the transactional bundle install operation after the compatibility report.
- [x] Add Krita-bundle hostile-archive fixtures for traversal, case-collision,
  missing presets, and compression-ratio bombs.
- [x] Select external brush parsers from validated magic bytes and native
  manifest structure rather than trusting filename extensions alone.
- [x] Accept bounded PNG, JPEG, and all common WebP header variants (VP8X,
  VP8, and VP8L) for image-tip imports, rejecting malformed dimensions.
- [x] Rust-owned begin/update/commit/cancel brush drafts keep uncommitted
  editor settings out of stroke capture and persistence.
- [x] Generic Flutter export choices for PNG, JPEG, WebP, OpenRaster, SVG,
  and flattened PSD preserve the direct PNG toolbar contract.
- [x] Keyboard command shortcuts share the existing undo/redo, brush, eraser,
  and transient-panel command paths.
- [x] Add an accessible gesture-settings surface with single-finger
  navigation opt-in and undo/redo remapping for two- and three-finger taps;
  keep stylus-first arbitration and the four-finger interface toggle intact.
- [x] Add a layer-pinch merge preview and undoable merge commit. The layer
  preview confirms source/target IDs, then dispatches a journaled Rust raster
  merge; the two-finger layer hold still selects opaque contents and the
  two-finger layer swipe toggles alpha lock through the shared mutation path.
- [x] Add explicit canvas screen-reader semantics plus accessible settings for
  larger toolbar controls and left-handed toolbar placement.
- [x] Add a Rust-owned brush-color command and bounded canvas RGB picker so
  users can complete a sketch, ink, color, and export workflow in-app.
- [x] Add an end-to-end Rust acceptance workflow covering sketch, ink, colored
  paint, vector ink, time-lapse, undo/redo, and every Phase 2 export format.
- [x] Bound imported brush metadata and sanitize exported brush filenames at
  the platform boundary to prevent hostile packs from causing path traversal
  or unbounded UI text.
- [x] Windows Ink/WM_POINTER with runtime WinTab fallback, plus GTK
  Wayland/X11 tablet adapters, normalize pressure, tilt, eraser, barrel, and
  lifecycle samples into packet v1.
- [x] Subscribe Flutter to the Windows/Linux native packet and readiness
  channels, consume a desktop pen message only after a packet is published, and
  disconnect the Linux GTK event signal before adapter teardown to prevent
  duplicate strokes, startup swallowing, and use-after-free callbacks.
- [x] Route brush-library edits through a debounced Rust draft
  begin/update/commit path; cancel active drafts during canvas teardown.
- [x] Add an explicit brush-editor cancel action that refreshes the Rust-owned
  projection after cancellation.
- [x] Add a disposable brush scratch pad to the brush editor; it never dirties
  or persists the document.
- [x] Surface color-range controls and basic raster move/scale/rotate
  transforms in the responsive Flutter UI.
- [x] Add a bounded, selection-aware reference/bucket fill command with
  tolerance and gap-closing controls; filling is journaled and undoable.
- [x] Make gap closing traverse only a bounded number of consecutive
  out-of-tolerance barrier pixels instead of expanding the final fill mask,
  preventing unrelated-pixel bleed; add a regression for the barrier budget.
- [x] Make v2 brush bindings honor their serialized base value, clamp normalized
  sensors without pressure-endpoint wrapping, require 2–16 response points,
  and normalize Apple Pencil/macOS barrel rotation at the native packet edge.
- [x] Add journaled linear gradient fills with reference sampling, Paint
  Inside, transparent-only painting, bounded mask expansion, and a Flutter
  Gradient action sharing the bucket-fill dialog.
- [x] Add strict flattened PSD import for version-1 RGB 8-bit uncompressed
  composites, with malformed/truncated/compressed input rejection tests.
- [x] Add a bounded, undoable perspective raster transform command and a
  responsive rectangle-driven perspective-transform tool.
- [x] Add a bounded regular mesh raster transform command and a responsive
  rectangle-driven 2x2 mesh-transform tool.
- [x] Add a bounded, undoable liquify raster transform command and a responsive
  drag-driven push-liquify tool.
- [x] Surface arbitrary-control-point mesh editing, advanced liquify controls,
  and editable vector-ink workflows in the responsive Flutter UI. Mesh editing
  accepts bounded 2–32 row-major control grids; liquify exposes push, expand,
  contract, and twirl modes; vector layers expose pen, transform, eraser,
  simplify, connect, and control-point commands. Every mutation routes through
  journal tags 23–27 and remains undoable.
- [x] Add a decoded-resource LRU cache and a documented memory benchmark for
  large brush packs and long mixed-brush sessions. The 64 MiB engine cache is
  measured by `estimated_working_memory_bytes`; durable resources remain
  content-addressed and bounded separately. The accelerated 3,600-stroke
  `phase2_session_benchmark` now also enforces the 256 MiB aggregate history
  snapshot budget and reports first/final-window timing.
- [x] Add CI guardrails for the Phase 2 mixed-brush benchmark: required stroke
  count and brush coverage, a conservative p95 latency ceiling, start/end and
  peak memory fields under the 900 MiB document ceiling, and a
  first-versus-final-window stability bound.
- [x] Add staged import operation IDs with expiry/cancel semantics for
  external brush reports while retaining source-hash verification. Each
  document handle retains at most sixteen ten-minute operations, and commit
  rechecks the source hash before installing.
- [x] Keep brush-editor commits transactional and undoable through the shared
  command path; reject symlinked external sources before format decoding.
- [x] Add widget coverage proving desktop keyboard undo/redo shortcuts share
  the same engine command path as touch gestures.
- [x] Keep brush selection side-effect-free; only explicit setting changes may
  create a Rust-owned brush edit draft.
- [x] Refresh layer projections after accepted or rejected layer mutations so
  Flutter cannot retain a stale optimistic state.
- [x] Clean up rejected brush drafts and refresh the Rust-owned brush library
  projection after draft failures.
- [x] Preserve the active brush selection across Rust projection refreshes.
- [x] Refresh all pixel-affecting brush controls from Rust while preserving
  only UI-owned favorites across projection updates.
- [x] Project the complete persisted brush editor state (including color and
  exact stamp scatter) through FRB so save/reopen cannot reset controls to UI
  defaults.
- [x] Duplicate built-in and imported brushes through a Rust-owned stable-ID
  operation with persistence and undo/redo coverage; expose it in the brush
  library panel.
- [x] Keep brush-library search and tag filters reactive to Rust projection
  refreshes and reachable in compact touch layouts.

## 3 — comics beta

- [x] Rust comic model and FRB handle cover bounded multi-page projects,
  panel/gutter geometry, balloons/dialogue, screentones, and effect lines.
- [x] Flutter comic workspace exposes page navigation/reordering, dialogue
  search, and deterministic webtoon segmentation for the eight-page fixture.
- [x] Persist comic structure inside `.inkproj` checkpoints through the
  validated `comic.json` sidecar and FRB attach/read APIs.
- [x] Add rendered page thumbnails and linked panel-mask previews to the comic
  workspace page navigator (full cross-document gallery integration remains a
  release-hardening follow-up).
- [x] Add self-contained SVG page export alongside structural JSON manifests;
  preserve panels, balloons, dialogue, screentones, effect lines, and linked
  mask metadata without external resources.
- [x] Add a Rust-owned local materials list with license/attribution/source
  metadata and a compact Flutter materials summary.
- [x] Expose polygon panel editing, screentone insertion, and effect-line
  insertion through validated FRB operations and touch-friendly controls.
- [x] Add validated drawn panel division that preserves gutters, keeps the
  first linked mask, retargets linked balloons, and remains structurally safe.
- [x] Offer circle/line/noise screentone presets, speed/focus/radial effect
  line choices, and local brush/texture/template/balloon material choices.
- [x] Expose explicit illustration, print-comic, and webtoon template
  creation plus styled balloon/tail and vertical-text controls.
- [x] Give new webtoon templates a long-canvas page default and deterministic
  segmented export path.
- [x] Export webtoon pages as cropped SVG segments with deterministic viewBoxes
  and source offsets instead of only reporting segment metadata.
- [x] Connect multi-page SVG export to platform-safe local directory pickers,
  with an app-owned fallback where native directory selection is unavailable.
- [x] Add bounded print-preview geometry checks and moiré warnings to the
  Rust/FRB/UI path.
- [x] Render the bounded trim, bleed, and safety guides in the Flutter print
  preview so the geometry report is visible while composing a page.
- [x] Add a selected-page inspector with Rust-backed gutter sliders, dialogue
  editing, page-specific webtoon segmentation, and polygon-aware thumbnails.
- [x] Add a compact selected-page canvas preview with trim/safety guides,
  panel geometry, balloon shapes, and bounded dialogue text rendering.
- [x] Include immutable polygon/text/style projections in the FRB snapshot so
  Flutter can edit and preview comic objects without duplicating document state.
- [x] Add Rust/FRB/UI editing for balloon tails and text style (font fallback,
  size, outline, and horizontal/vertical orientation), with bounded dialogs.
- [x] Verify the comic workspace opens from the main canvas toolbar and remains
  scrollable in the compact touch panel without layout overflow.
- [x] Clamp selected-page state after template changes and project recovery so
  creation actions never dispatch against a stale page index.
- [x] Add a touch-friendly panel polygon editor that pre-fills vertices and
  dispatches bounded Rust geometry updates without repainting panel contents.
- [x] Make template creation immediately provision its first page with the
  correct print or long-webtoon dimensions before creation tools become active.
- [x] Clear project-specific dialogue hits, webtoon segments, and print
  warnings when the Rust project identity changes after template replacement
  or recovery.
- [x] Add a deterministic portable render digest and a Flutter transfer-check
  surface for comparing a project after device-to-device transfer; the digest
  covers canonical JSON, SVG, and the bounded 1024-pixel raster preview.
- [x] Add a bounded deterministic Rust raster preview PNG for print inspection;
  it draws trim/safety guides, panels, tones, effect lines, balloon geometry,
  and offline text stubs without loading fonts, files, or network resources.
- [x] Make the eight-page xkcd-style fixture visibly drawable by adding bounded
  vector stick-figure lines to every panel and including them in SVG/PNG output.
- [x] Give newly created panels stable linked-mask identities so panel
  ownership survives page edits, export, and portable transfer.
- [x] Preserve linked-mask ownership when splitting a panel; both resulting
  panels receive deterministic mask identities without changing panel content.
- [x] Load the bounded Rust raster preview for the selected comic page so the
  inspector shows the actual xkcd-style ink, balloons, tones, and effect lines
  instead of only a structural geometry placeholder; invalidate it after edits.
- [x] Keep the desktop drawing shell discoverable with a labeled Workspace dock
  for Tools, Brushes, Layers, and Comics; verify the Layers surface and a
  visible mouse stroke in the running macOS build.
- [x] Make project-wide dialogue search actionable: bounded result rows expose
  the matched page and text preview, and tapping a result selects that page.
- [x] Add a widget regression for cross-page dialogue search and page selection.
- [x] Show inspectable webtoon segment offsets/heights before export, bounded to
  the first 16 rows while retaining the complete export set.
- [x] Keep drawing visually continuous with a non-persisted pointer preview,
  avoid unnecessary normal-layer offscreen compositing, and retire GPU tile
  images only after several completed frames.
- [x] Clear the pointer preview at confirmed tile/pointer-up boundaries so a
  long mouse drag cannot be composited twice; extend the bounded image-handle
  retirement window for desktop compositor safety.
- [x] Keep brush feedback on the synchronous pointer path while Rust consumes
  an ordered packet queue; draw only unconfirmed preview samples.
- [x] Publish tile revisions atomically: keep the previous complete frame
  visible while dirty/full-redraw tiles decode, then retire stale images only
  after the replacement revision is ready.
- [x] Make existing screentones and effect lines first-class inspector items:
  show their parameters, edit them without changing geometry, and remove them
  through undoable Rust commands.
- [x] Add bounded comic edit undo/redo history across persisted structural
  changes, with visible controls in the Comics workspace and a widget
  regression for dispatching both commands.
- [x] Make comic panel division authorable instead of fixed: choose horizontal
  or vertical direction and a bounded first-panel ratio before dispatch.
- [x] Defer Comics controller notifications that arrive during dock mounting
  so the live desktop shell never calls setState during build.
- [x] Standardize desktop canvas controls with a compact quick-control strip
  for brush, size, opacity, eraser, color, zoom, fit, and gesture settings;
  preserve icon hit targets for narrow-window document and accessibility tests.
- [x] Add a reversible collapse/expand control for the wide-desktop Workspace
  dock so the canvas can be maximized without changing the selected tab.
- [x] Expose all Phase 3 balloon shapes from the authoring surface (speech,
  thought, narration, and burst) and cover the type menu with a widget test.
- [x] Show the active layer in the desktop quick controls so the compact
  canvas workflow keeps brush and layer context visible together.
- [x] Make panel division directly draggable in the authoring dialog, with a
  visual divider preview while retaining bounded horizontal/vertical ratios.
- [x] Make local comic materials manageable from the workspace: show license
  metadata and provide a safe remove action backed by Rust persistence.
- [x] Add accessible page move-up/move-down actions alongside drag reordering,
  keeping page selection aligned after a move.
- [x] Replace fixed screentone presets with a bounded editor for pattern,
  frequency, angle, and density before creating a nondestructive tone layer.
- [x] Replace fixed effect-line presets with a bounded editor for speed,
  focus, or radial lines plus width and opacity before dispatch.
- [x] Make print layout metadata authorable from the page inspector: DPI,
  bleed, trim, and safety fields validate before the Rust snapshot changes.
- [x] Make rectangular panel geometry authorable with bounded X/Y/width/height
  fields while keeping polygon panels on the explicit vertex editor path.
- [x] Render thought balloons as bubble clusters and burst balloons as star
  polygons in both the deterministic Rust preview/export and Flutter canvas;
  preserve editable tails in the visible preview.
- [x] Make local material creation authorable: capture a material name, type,
  license, attribution, and source in a bounded dialog before Rust persistence.
- [x] Reject panel rectangles and polygon vertices outside the page canvas at
  the Rust boundary, preserving the prior geometry on invalid edits.
- [x] Preserve the last validated comic checkpoint when closing a session so
  recovery remains available without a host file callback.
- [x] Defer native tile-image disposal during canvas shutdown, preventing a
  retained desktop display list from drawing through a disposed handle.

## 3.5 — professional workspace and authoritative compositing

- [x] Add explicit light, dark, and high-contrast `ThemeExtension` tokens plus
  reusable dock, inspector, slider, tool, and status components.
- [x] Add adaptive workspace-mode resolution and a versioned, bounded local
  workspace-preferences store for dock width, panel visibility, theme, and
  layout overrides.
- [x] Make the desktop dock expose Tool Properties and Materials alongside
  Tools, Brushes, Layers, and Comics with bounded tab hit regions; keep canvas
  navigation gesture-first instead of adding a standalone Navigator view.
- [x] Make pinch, trackpad, and touch navigation use one focal-point-anchored
  viewport transform on every platform; remove ambiguous quick-pinch fit resets.
- [x] Clip transformed canvas painting to its viewport so rotated/zoomed tile
  geometry cannot bleed over the toolbar or Workspace dock as black/white bars.
- [x] Centralize common undo/redo, panel, eraser, fit-canvas, and interface
  actions behind `EditorActionId` so shortcuts and gesture surfaces share IDs.
- [x] Make Fit Canvas compute a centered, margin-aware scale from the visible
  canvas viewport and document size; verify the command changes zoom in a
  widget test and supports the largest document dimensions.
- [x] Preserve a 400-point drawing area in narrow desktop windows by reducing
  effective dock widths without overwriting the artist's saved dock sizes;
  refresh the compact desktop illustration/comic golden baselines.
- [x] Add all sixteen deterministic layer blend modes while preserving the
  serialized values `0–7`; expose opacity, blend, alpha-lock, clipping, and
  reference properties in the visible Layers inspector.
- [x] Add Rust-authoritative committed composite-tile reads and route the
  Flutter canvas through those tiles instead of approximating blend modes with
  Flutter compositing; keep a safe per-layer fallback for compatibility.
- [x] Add bounded live-dab fanout/overflow contracts, Rust-generated dab
  packets, optional fixed-shader wgpu rendering, and separate pointer-to-
  preview telemetry; keep the Flutter GPU-composited live preview visible
  until the corresponding CPU tile is actually published.
- [x] Retain GPU dabs until CPU acknowledgement or stroke cancellation and
  expose preview-overflow health without aborting the authoritative CPU path.
- [x] Lock the live-dab binary v1 record to 48 bytes at both bridge boundaries;
  fix missing reserved padding that made every nonempty GPU dab batch invalid,
  and add round-trip plus malformed-padding tests.
- [x] Replace the opaque comic page preview overlay with transform-aligned,
  guides-only panel borders so drawing cannot appear behind a rendered page.
- [x] Add a visible Draw-inside-panel action that scales panel geometry into
  the active canvas and applies Rust's bounded selection mask; repeat to
  release the clip.
- [x] Version comic structure as v2 with generated per-page document refs,
  panel child-layer ownership metadata, source-preserving v1 JSON migration,
  atomic nested page-document storage, and one Rust-owned StudioProjectHandle.
- [x] Add an atomic, idempotent Rust/FRB command that materializes each panel
  binding as a real PanelGroup with generated Mask and Sketch/Ink/Color/Tone/
  Effects child layers; Draw-inside-panel creates/selects the Ink child before
  applying the bounded selection clip.
- [x] Create those trees automatically in the unified StudioProjectHandle when
  opening a migrated project or adding a project-boundary panel.
- [x] Add bounded Rust/FRB project-boundary operations for panel resize,
  polygon edits, and split. The first split child retains the original layer
  binding and painted content; the new child receives a materialized tree and
  authoritative mask.
- [x] Synchronize compatibility-controller panel geometry edits into the active
  canvas document so resize, polygon edits, add, and split cannot leave a stale
  mask behind the guide.
- [x] Migrate the Flutter comic controller metadata path to the unified
  StudioProjectHandle, including validated page activation and project-manager
  structural undo/redo that preserves page-document snapshots.
- [x] Replace the transitional canvas-host callback with a shared Arc-backed
  active-page DocumentHandle capability. Canvas strokes, layer commands, tile
  reads, undo, and complete-project saves now observe the same page document;
  physical texture registration and device acceptance remain Phase 5.

## 3.5 — live drawing reliability and color workflow

- [x] Replace the numeric-only brush color dialog with an HSV color wheel,
  retain RGB precision sliders, and add C color-picker plus I/Alt-I canvas
  sampler shortcuts.
- [x] Prevent mouse drags from arming stylus draw-and-hold straighten mode;
  remove pointer-hot-path SnackBars that caused a lag spike and random popup.
- [x] Treat an empty full-redraw batch as a valid empty document, retire the
  previous frame, and force a repaint so undoing the only stroke clears it.
- [x] Make FRB initialization single-flight so concurrent engine construction
  cannot initialize the native bridge twice.

## 3.75 — professional UI parity

- [x] Make command-bar customization persist per built-in workspace and
  per saved custom workspace; keep action IDs allowlisted and the list bounded.
- [x] Add resizable vertical palette-group dividers and persist built-in group
  proportions in bounded `WorkspacePreferencesV2` overrides.
- [x] Add a confirmed built-in workspace reset that clears layout/command-bar
  overrides without touching artwork or active document state.
- [x] Keep document actions and brush/color commands testable through their
  accessible command labels after toolbar icons and shortcut tooltips change.
- [x] Migrate the primary Layers tree row to reusable `InkLayerRow` styling
  with a minimum 48px target, selected-state treatment, bounded text, and
  preservation of the existing layer gesture and action controls.
- [x] Extract the repeated toolbar/selection icon pattern to the shared
  `InkCommandButton`, including explicit accessibility semantics and 48px
  targets in tablet Simple mode.
- [x] Replace the brush browser's raw preset/tag chips with a shared
  `InkSelectableChip` using theme tokens, selected-state semantics, and a
  48px minimum target for brush selection.
- [x] Replace narrow-desktop horizontal scrolling for document actions with a
  labeled More commands menu; keep Undo/Redo, command search, Brushes, Layers,
  and Color directly reachable in compact windows.
- [x] Migrate the brush browser's primary size, opacity, stabilization, and
  pressure controls to the shared labeled inspector slider; expose each
  control's value to screen readers and retain long pixel values visibly.
- [x] Use the shared labeled, accessible slider for the remaining advanced
  brush parameters and multi-point pressure-curve controls as well.
- [x] Rebuild the Comics dock header around the shared palette header, keep
  long project names bounded, group project/template commands into one menu,
  and show compact Page/Panel/Text tabs with an overflow menu for narrow docks.
  Move dialogue search into the Text/Balloon section.
- [x] Migrate layer-type creation controls to the shared themed selectable-chip
  component with touch-sized targets and wrapping for narrow docks.
- [x] Stop captured generic pointer streams at the visible canvas viewport even
  when zoomed document coordinates remain in bounds; preserve the exact
  document-edge sample when Rust needs it to clip the final segment.
- [x] Give expanded-touch Studio mode its own 48px tool rail and command bar,
  open Layers by default, keep one touch palette active at a time, and render
  the palette as a flat dock rather than a floating card. Cover portrait and
  landscape tablet sizes across dark, light, and high-contrast themes.
- [x] Enable drag-to-reorder palette tabs and drag palettes between dock
  groups; persist a cross-dock move as one workspace-preference update.
- [x] Verify workspace orientation/state retention on phone, tablet, and
  desktop using responsive Flutter widget transitions.
- [x] Replace the in-window macOS menu row with native application menus while
  keeping the shared action registry for Windows/Linux menus and shortcuts.
- [x] Index every implemented command by its label, category, aliases, shortcut,
  associated palette, and associated tool; test alias-based dispatch in the UI.
- [x] Migrate illustration tool groups, selection clear, and transform presets
  onto the shared inspector and command components; preserve tool selection
  and accessible labels.
- [x] Migrate comic page-manager rows to the shared inspector row with selected
  state, thumbnails, and accessible move controls while retaining drag reorder.
- [x] Adapt shared dock/layer rows and property sliders for 200% text, keeping
  brush-size and opacity values visible and giving long titles a second line.
- [x] Review golden screenshots for every built-in desktop workspace at
  1440×900 and 2048×1280, iPad portrait/landscape modes, Android tablet
  1280×800, and phone across dark/light/high-contrast themes. Capture 150% and
  200% text-scale variants for desktop, tablet Simple/Studio, and phone.
- [x] Exercise history navigation, selection launcher, color roles, layer
  visibility/opacity/blend/state controls, Comics tabs and materials through
  visible controls and semantics; keep deferred actions out of those flows.
- [x] Remove per-dab linear searches and synchronous device-waiting from the
  retained GPU preview path; add a release benchmark that reports adapter and
  CPU prepare/submit p95 without claiming GPU completion or display latency.
- [x] Render unique append-only dab batches directly into the retained live
  target; rebuild only when a dab is replaced/evicted, the viewport changes, or
  acknowledgement/cancellation removes pixels. Verify incremental pixels match
  a full rebuild and retain the no-readback pointer path.
- [x] Preserve multiple brush dabs emitted by one input sample as distinct live
  preview points. Packet v3 adds a stable dab index while acknowledgements stay
  sample-sequence-based; a 900-sample repeated-brush spiral regression confirms
  GPU/CPU spatial agreement within one pixel for three basic brushes. This
  local correctness test does not complete the end-to-end presentation gate.
- [x] Align Android's transport size bound with the v3 56-byte dab record so a
  full 2,048-record batch is not rejected and does not disable the native
  preview. The exact maximum packet and the first over-limit packet are tested.
- [x] Finish migrating the remaining ad-hoc Comics inspector and modal surfaces
  to shared components; audit their control states and accessibility. Inspector
  rows, material summaries, print previews, sliders, dialog actions, and
  vertical-text toggle now use the shared system; Flutter regression tests
  cover page, panel, tone, effect, material, and dialog workflows; raw
  ListTile/Card/ExpansionTile/CheckboxListTile/Slider and button widgets no
  longer remain in `comic_workspace.dart`.
- [x] Connect the existing macOS Flutter texture registry and bounded Rust
  live-dab API to the canvas lifecycle, viewport transform, confirmed-stroke
  fanout, CPU-tile acknowledgement, cancellation, and CPU fallback. Flutter
  texture ID zero, viewport mapping, dab delivery, acknowledgement, disposal,
  and malformed-packet fallback have automated coverage.
- [x] Add the iOS Flutter texture-registry adapter using a bounded
  IOSurface-backed pixel buffer and the same validated Metal texture handoff as
  macOS. Wire the channel into the implicit iOS engine and enable the live
  surface only for Apple targets with a live-render engine. Swift simulator
  type-check and macOS-host Rust/Flutter tests pass; full iOS target build is
  pending.
- [x] Extract the bounded dab-packet validation, viewport lifecycle,
  acknowledgement, cancellation, retention, and CPU-fallback behavior into a
  platform-neutral native texture controller interface. Android keeps its
  existing triple-buffer memory ceiling; Windows/Linux source registration is
  now implemented, with native build/runtime verification tracked below.
- [x] Record pointer-to-native-texture-submission separately from immediate
  Flutter preview, committed-tile visibility, and tile decode. Keep the field
  explicitly labeled as a frame-request/submission measure, not GPU completion
  or display scan-out; controller and p95 serialization tests cover it.
- [x] Add Android `SurfaceProducer` texture registration and hardware-canvas
  presentation for bounded live-dab packets, with Flutter CPU-preview fallback;
  `flutter build apk --debug --no-pub` compiles all configured Android ABIs.
- [x] Keep completed drawing strokes commit-safe when the optional, bounded
  time-lapse recording reaches its sample/stroke limit; stop extending the
  time-lapse instead of rejecting `EndStroke` and leaving the drawing
  transaction open. Rust stress coverage checks 44 long spirals across 11
  brushes, and a Flutter canvas regression selects eight brushes in the UI and
  draws a long mouse spiral with each.
- [x] Keep the serialized Flutter pointer queue recoverable after an unexpected
  asynchronous handler error. Recover the unfinished stroke once, log the
  failure, and continue processing future pointer events; a one-time bridge
  failure followed by a successful new stroke is covered by a widget test.
- [x] Add native Windows/Linux external pixel-texture registration and wire
  both platform runners to the bounded v3 live-dab channel; keep Flutter's CPU
  preview fallback available. The shared native raster core has a standalone
  warning-clean test, and CI includes the Linux runner build.
- [x] Add a desktop integration smoke test against the real Windows/Linux
  runner channel: register and display a texture, update its viewport, submit a
  confirmed dab frame, acknowledge it, dispose the texture, and reject a stale
  texture ID. Windows and Linux CI now run this test on their native hosts.
- [ ] Build and runtime-verify the Windows/Linux runners on their native CI
  hosts, including texture creation, frame delivery, acknowledgement, and
  disposal. The integration test is wired but awaits successful hosted runs;
  the current macOS host cannot establish those platform gates.
- [ ] Measure end-to-end GPU live-preview presentation and basic-brush spatial
  replacement on desktop after platform texture presentation is integrated;
  verify replacement against committed CPU tiles and retain deterministic CPU
  truth.

The rebuilt macOS debug bundle and automated desktop widget tests are local
development evidence only. Physical iPad/Android/stylus acceptance remains in
Phase 5; do not close Phase 3.75 until its remaining checklist and screenshot
review are complete.

Platform-native Flutter texture-registry registration is a Phase 3.75
implementation requirement. Physical iPad/Android/stylus latency, spatial
replacement, and cross-device validation gates remain in Phase 5. The bounded
wgpu surface, live-dab packet path, and Flutter compositor fallback are
testable locally without a downloaded shader.

## 4 — release hardening

- [ ] Fault injection, repair copies, import limits, accessibility, locales,
  reproducible signed builds and offline release validation.

## 5 — final external acceptance and deferred enhancements

All final external validation is intentionally deferred until the implementation
is memory-stable enough for dedicated test runs. Phases 1–4 use automated Rust/
Flutter tests, deterministic fixtures, local static checks, and simulator or
emulator startup checks only; none of those checks claim physical hardware,
hosted-platform, or store-release acceptance.

- [ ] Run the physical input/memory matrix on iPad Pro M1/M4 with Apple Pencil
  2/Pro, Galaxy S23 Ultra with S Pen, and the Samsung tablet; record latency,
  confirmed-sample delivery, RSS/PSS, gestures, hover, eraser, and recovery.
- [ ] Run the desktop tablet matrix with Wacom, Huion, and XP-Pen hardware on
  macOS, Windows, and Linux; verify pressure, eraser, buttons, no duplicate
  strokes, and long-session memory behavior.
- [ ] Complete hosted Windows/Linux builds and retain CI logs and checksums;
  install and exercise the corresponding artifacts on real desktop systems.
- [ ] Execute the Phase 3 cross-device comic round trip across iPadOS,
  Android, macOS, Windows, and Linux using the transfer fingerprint, SVG
  hashes, edited dialogue, polygon panels, gutters, recovery, and batch export.
- [ ] Perform final print/export review with production fonts, font fallback,
  color-managed output, moiré checks, and eight-page xkcd-style plus long-
  webtoon deliverables.
- [ ] Verify signed/store/direct-release installation, offline operation,
  provider file flows, and network-disabled drawing/saving/export on every
  supported platform. Record Sidecar only as a macOS smoke test, not as
  iPadOS Pencil acceptance.

3D, animation, wet pigment, 16-bit/HDR/P3/CMYK, GPU compute, collaboration,
cloud conveniences, plugins, ML tools, web editor, ARM Windows/Linux, and full
PSD compatibility remain intentionally out of scope until Phases 1–4 are met.
