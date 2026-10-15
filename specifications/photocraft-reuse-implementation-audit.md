# PhotoCraft reuse implementation audit

Audit date: 2026-10-09. This records repository evidence for the PhotoCraft
reuse plan. “Implemented” means source and focused host tests exist; it does not
mean the feature has passed installed macOS, Android, or iOS acceptance.

## Phase status

| Phase | Evidence in this checkout | Status |
|---|---|---|
| 1: comic lettering and complete exports | `ink-text` owns Rust shaping/layout, comic render plans feed PNG/SVG, the canvas displays Rust overlay previews, export warnings are confirmed in Flutter, and a Japanese vertical dialogue round-trip/export test exists. A pinned Noto font bundle and provenance are present. A two-page Latin comic was saved, quit, reopened, and exported as PNG/SVG on macOS. | Rust/core, bridge, canvas integration, warning UI, and Latin macOS journey have evidence; Japanese vertical installed acceptance and Android/iOS comic journeys remain open |
| 2A: layered PSD | Flattened raw/PackBits decoding remains supported. The pinned parser is vendored with MIT notice and structural caps. `ink-export::inspect_psd` reports compatibility and memory; the bridge exposes bounded inspection and constructs a detached editable candidate; Flutter offers explicit editable or flattened import and publishes only after the replacement barrier. Editable export snapshots supported raster/group/mask/lock/clipping state with the actual Rust composite, crops raster and mask data to their own bounds, and writes through a synced temporary sibling. Round-trip fixtures cover clipping, disabled masks, and default values 0 and 255. Three Photoshop 2026 corpus fixtures and independent group/clipping and raster-mask fixtures provide external image oracles. Basic editable import/save/reopen/export, Photoshop grouped/clipped and masked imports, exported offsets, and merged composites are checked against those oracles. | Host evidence covers the tested subset and offset-preserving export; malformed/truncated data, broader feature-combination coverage, cancellation during decoding, and installed persistence/import acceptance remain open |
| 2B: ABR import | The pinned MIT parser is used from `ink-brush`; the bounded converter maps legacy v1/v2 computed/sampled tips and v6+ sampled descriptors into Tier C reports. It maps zero-jitter Pen Pressure size/opacity descriptors to normalized Ink pressure curves and reports jittered/other controls. `ink-engine` installs the full report through the existing verified library transaction, the picker accepts `.abr`, and Flutter routes confirmation to the multi-brush API. Tests cover parser conversion, cumulative decoded-byte rejection before decompression, truncated-record rejection, source-hash rejection without mutation, multi-brush registration, UI confirmation, and a sampled tip that paints and survives `.inkproj` save/reopen. A compiled imported preset renders visibly different light/firm pressure dabs in a host test, and pressure bindings survive project save/reopen. | New pressure mapping, unsupported-control fixtures, save/reopen, ABR-focused tests, and strict package Clippy pass; broader real-world ABR version/descriptor fixtures and installed library acceptance remain open |
| 3: adjustment layers | `LayerAdjustment` contains Levels, Curves, and Hue/Saturation; compositor LUT/evaluation code and engine fixtures exist. Bridge APIs now expose a Rust-owned begin/update/commit/cancel transaction. Flutter previews through Rust, offers Levels, Curves, Hue/Saturation and legacy Brightness/Contrast, and commits one undoable edit or restores on cancel. Recovery from a corrupt current manifest through the backup verifies adjustment settings and identical composite. Conflicting editor actions and native window close are blocked during an active draft, and route disposal queues cancellation. An engine export matrix now checks every output pixel in PNG and flattened PSD against the authoritative composite for Curves, non-identity Levels, and Hue/Saturation, including partial-alpha preservation. | Core, transaction-lock, recovery, and cross-format host evidence present; installed platform workflows remain open |
| 4: pulled-string stabilization | Brush format 3 and semantics 2001 evaluator are exposed through Rust brush drafts, summaries, FRB, Dart projections, and the custom brush Stroke editor. Draft commit applies settings as one brush-library edit; cancel remains draft-local. Rust verifies v3 persistence/reopen, replay, chunk equivalence, pressure preservation, cancel, and in-session undo/redo. Time-lapse JSON v2 now captures brush revision, semantics, and stabilizer settings while reading v1 defaults. Technical Pen revision 5 and matching live-preview diameter semantics are installed in the Android `.debug` profile package; the signed alpha package remains unchanged. | The user confirmed pressure direction on revision 4: the firm 12 px Technical Pen stroke was wider than a comparable light stroke. Revision 5 is installed and launched; its S Pen pressure, toolbar/layer taps, and stabilization replay checks await device confirmation. |

## Implementation specifications

The expert-reviewed, implementation-ready contracts are split by ownership and
acceptance scope:

- [`photocraft-integration-contract.md`](photocraft-integration-contract.md)
  defines Rust/Flutter ownership, provenance, format coordination, resource
  limits, failure atomicity, async generations, and delivery rules.
- [`photocraft-phase-1-comic-lettering.md`](photocraft-phase-1-comic-lettering.md)
  specifies bundled-font shaping, vertical Japanese text, shared render plans,
  warning confirmation, and PNG/SVG composition.
- [`photocraft-phase-2a-psd.md`](photocraft-phase-2a-psd.md) and
  [`photocraft-phase-2b-abr.md`](photocraft-phase-2b-abr.md) specify explicit
  interchange subsets, parser budgets, detached/transactional import, and
  independent fixtures.
- [`photocraft-phase-3-adjustments.md`](photocraft-phase-3-adjustments.md)
  and [`photocraft-phase-4-pulled-string.md`](photocraft-phase-4-pulled-string.md)
  specify serialized semantics, Rust evaluation, edit transactions, and
  compatibility with existing strokes; pulled-string time-lapse metadata is
  versioned separately in [`time-lapse-format.md`](time-lapse-format.md).

These documents preserve the current root format 8/vector work and comic
format 3/brush format 3 domains. They describe requirements; a specification's
existence is not evidence that its installed acceptance gate has passed.

## PSD inspection contract currently implemented

`ink-export::inspect_psd` rejects an oversized source before parsing, applies
the fixed-header dimensions and 768 MiB flattened budget, then parses the
bounded layer model. The vendored parser stops before growing vectors beyond
1,024 layers, 4,096 resources, and 32 tagged blocks in a section. The report
distinguishes incompatibilities with editable import from reasons that prevent
flattening; an editable source need not contain a merged composite. Flattened
decoding remains a separate, explicit capability in the report.

The inspector does not decompress all layer channels or build an Ink document.
Editable decoding produces a detached candidate; the engine validates
parent-first hierarchy, layer pixel lengths, mask defaults and dimensions,
clips negative and out-of-canvas offsets, and converts straight RGBA into
premultiplied BGRA once. Fresh layer and mask IDs are assigned. The bridge
adds the active document's estimated working set to the PSD projection and
rejects the candidate above a 900 MiB combined estimate. UI publication still
uses the document replacement barrier. The synchronous decoder currently has
no mid-decode cancellation hook.
ICC profiles are currently reported as incompatible for editable import when
present; profile conversion and proof that an embedded profile is sRGB are not
implemented.

## Format-version coordination

The supplied reuse plan proposed root `.inkproj` format 7, but this checkout
already contains in-progress vector persistence that writes format 8 with
`vector_semantics: 1` and reads formats 2–8. Do not downgrade or overwrite that
work. Adjustment persistence, if it is not already covered by the format-8
payload contract, must be coordinated as a later version bump or as a
backward-compatible extension with explicit unknown-value rejection. Comic
format 3 and brush format 3 remain separate version domains.

## Verification performed in this audit

- `cargo test -p ink-export`: 10 tests passed, including layer structure and
  decoded samples, profile incompatibility, editable decoding without a merged
  composite, raw/PackBits flattened decoding, malformed PackBits rows, and
  header working-set rejection.
- `cargo clippy -p ink-export --all-targets -- -D warnings`: passed after
  scoping allowances to the pinned upstream parser and two necessary
  inspection-report lint cases.
- `cargo test -p ink-export -p photocraft-psd --lib`: all 166 combined tests
  passed, including the vendored parser's 156 unit tests after its parser-cap
  edits.
- `cargo test -p ink-brush --lib`: 56 tests passed, including ABR detection,
  v1/v2 computed/sampled conversion, v6 descriptor mapping, and coverage
  polarity.
- `cargo test -p ink-engine imported_abr_tip_renders_and_survives_project_reopen --lib` and the analogous `ink_bridge` transaction test both passed.
- `flutter test test/canvas_document_actions_test.dart --plain-name 'ABR import confirms Tier C report before transactional install'` passed.
- `cargo test -p ink_bridge --lib`: all 63 tests passed at the prior audit point, including PSD
  inspection, explicit flattened-choice data, source symlink rejection, and
  pre-allocation memory rejection.
- `flutter test test/canvas_document_actions_test.dart`: all 33 tests passed,
  including flattened PSD confirmation/cancel flows and ABR report/install.
- `flutter analyze`: passed after the new import flow was formatted.
- FRB generation completed with `flutter_rust_bridge_codegen 2.13.0`;
  `cargo check -p ink-engine --lib` and the then-current 61-test bridge suite
  passed. One additional ABR bridge test was added and passed afterward.
- `cargo test --workspace --all-targets --all-features`: passed across the
  workspace, including the vendored parser.
- `cargo fmt --all -- --check` and
  `cargo clippy --workspace --all-targets --all-features -- -D warnings`:
  passed. Vendored upstream test fixtures use a test-only lint allowance;
  production parser code remains strict. One exact-value serialization test
  compares float bit patterns to avoid a misleading approximate comparison.
- `flutter test`: all 680 tests passed; `flutter analyze`: passed.
- After adjustment UI wiring, `cargo test -p ink-engine adjustment_preview_cancel_restores_committed_state_without_history --lib`, `cargo test -p ink-engine committed_adjustment_is_one_history_item_and_reopens --lib`, and `cargo test -p ink_bridge adjustment --lib` passed. `flutter test test/layer_panel_gesture_test.dart` passed all 61 tests, including preview, apply, and cancel wiring.
- `cargo test -p ink-brush abr_truncated_records_are_rejected_before_conversion --lib` and `cargo clippy -p ink-brush --all-targets -- -D warnings` passed for the added ABR truncation fixture.
- The vendored ABR parser already charged cumulative decoded sample bytes before decompression; the audit's missing-fixture note was stale. Added a bounded v6 fixture that accepts two 4-byte samples at an 8-byte budget and rejects the second at 7 bytes. `cargo test -p photocraft-psd abr::tests::v6_rejects_cumulative_sample_bytes_before_decoding_over_budget_tip --lib` and `cargo fmt --all -- --check` passed.
- For editable PSD candidate construction, `cargo test -p ink-engine editable_psd -- --nocapture` passed two tests for clipped offsets, one-time alpha conversion, lock/group/mask preservation, save-snapshot reopen, and invalid hierarchy rejection. `cargo test -p ink-bridge editable_psd_open_builds_a_separate_layered_candidate -- --nocapture` passed the file-to-bridge candidate path. `flutter test test/canvas_document_actions_test.dart` passed all 35 tests, including explicit editable routing and flattened-choice cancellation/replacement. FRB bindings were regenerated with 2.13.0.
- For pulled-string editor wiring, `cargo test -p ink-engine pulled_string_brush_draft_persists_reopens_and_undoes_as_one_edit --lib` passed. It verifies draft commit, in-session undo/redo, serialized format 3 / semantics 2001, and save/reopen of distance and catch-up settings. `flutter test test/brush_library_test.dart test/canvas_brush_actions_test.dart test/workspace_focus_test.dart` passed all 24 tests, including the new editor control test; `flutter analyze` reported no issues. FRB bindings were regenerated with 2.13.0. Saved snapshots persist the brush settings; the brush-library undo record remains session-local, matching the existing brush editing architecture.
- Editable PSD export now has a Rust engine path and a separate `Editable PSD` menu choice alongside `Flattened PSD`. `cargo test -p ink-export --lib` passed 12 tests; `cargo test -p ink-engine --lib editable_psd_export_round_trips_raster_and_merged_pixels` passed the engine-to-file-to-decoded-composite check; `cargo test -p ink_bridge --lib` passed all 69 tests; and `flutter test test/canvas_document_actions_test.dart` passed all 36 tests including separate editable-export routing. FRB 2.13.0 bindings were regenerated. The fixture is an Ink-generated stroke, so external Photoshop composite equivalence and actual desktop/mobile export acceptance remain unverified.
- Current host gates: `cargo test --workspace --all-targets --all-features` passed; strict Clippy passed for `ink-export`, `ink-engine`, and `ink_bridge`; `cargo fmt --all -- --check`, `git diff --check`, `flutter analyze`, and the full `canvas_document_actions_test.dart` passed. The attempted full `flutter test` run did not produce a final summary and is not counted as a pass.
- `flutter build macos --debug` stopped during the native Rust build because the data volume had only about 150 MiB free (`No space left on device` while writing `libink_text`); a later check showed about 225 MiB free. No caches or build outputs were removed. `flutter devices` found only macOS and Chrome; the iPad scan failed with device error -27, and `adb devices -l` found no Android device. Installed acceptance remains open.
- The prior vector-file compile blocker has been repaired, and `ink-vector` tests and strict Clippy passed. The focused Clippy run for editable PSD export and its callers now passes.
- An earlier checkpoint reported all 680 Flutter tests passing. The latest full-suite attempt did not provide a completion summary, so it must be rerun when disk headroom permits.
- `dart analyze` on the adjustment editor and its integration files and a later full `flutter analyze` both passed. An earlier full analysis attempt saw transient errors in the in-progress vector coordinator test; the current checkout no longer reports them.
- Installed device acceptance remains open. Earlier macOS builds stopped at
  the native Rust bridge because the data volume ran out of space; later
  builds and installed journeys are recorded in the dated updates below.

## Remaining release work

The dated updates below supersede the earlier checklist where they add newer
evidence. Current remaining gates are:

1. **Android input acceptance:** the revision-4 S23 test passed the
   pressure-direction check at 12 px: the user reports that the firm stroke is
   wider than the light stroke. Revision 5 is now installed on the phone; confirm
   S Pen toolbar taps, layer targeting, and the pressure comparison on this
   build. The extra final redraw was reported gone; the broader input-to-visible
   latency gate remains open because the trace's worst p95 was 87.7 ms against
   the 40 ms target.
2. **Installed feature journeys:** repeat the comic save/reopen/PNG/SVG,
   editable PSD import/export, ABR registration, adjustment preview/apply/
   cancel, and pulled-string replay journeys on current installed macOS and
   Android builds. MacOS host evidence includes a completed Latin comic export
   journey from an earlier build and a later partial current-source smoke
   check; Japanese vertical lettering currently has Rust fixture coverage but
   no installed UI journey. Android's revision-5 profile APK was installed with
   `adb install -r`, preserving its package data; its feature journeys remain
   open. iOS remains compile-only until a device is available.
3. **Interchange scope:** external Photoshop-authored fixtures now cover
   editable layers, nested groups/clipping, raster masks, save/reopen, and
   editable export against independent rendered composites for the supported
   subset. Expand real-world ABR descriptor fixtures and installed brush
   library acceptance. Do not claim general Photoshop compatibility beyond the
   documented editable subset.
4. **Current host verification:** the complete Flutter suite now passes 713
   tests and `flutter analyze` is clean. Rust brush tests pass after the
   Technical Pen revision-5 default-size update. Re-run broader Rust and
   platform build gates after that change when disk headroom permits.
5. **Release checks:** retain platform-specific evidence separately. The
   current iOS compile is not physical acceptance, and host tests/builds do not
   close the S23 pressure, latency, or installed feature gates.

## 2026-10-09 verification update

- The full current Rust workspace test gate passed: `cargo test --workspace
  --all-targets --all-features`. It includes the Japanese vertical comic
  save/export test, PSD import/export and composite tests, ABR parsing and
  report-budget tests, adjustment alpha/identity/history tests, and pulled-
  string chunk/cancel/prediction tests.
- The strict workspace Clippy gate passed:
  `cargo clippy --workspace --all-targets --all-features -- -D warnings`.
  The only output was Cargo's future-incompatibility notice for the existing
  `block 0.1.6` dependency.
- `flutter analyze` passed and the full `flutter test` suite passed all 693
  tests.
- A current-tree Android arm64 release APK was built, signed with the existing
  alpha certificate, and verified for 16 KiB alignment. Its signing
  certificate SHA-256 matched the installed app. `adb install -r` succeeded,
  preserving app data. The phone subsequently showed its lock screen, so no
  real S Pen interaction is claimed for this APK yet.
- `CARGO_PROFILE_DEV_DEBUG=0 CARGO_INCREMENTAL=0 flutter build ios --debug
  --no-codesign` passed and produced `app/build/ios/iphoneos/Runner.app`.
  This is a compile-only result; no iOS device was attached.
- A macOS debug build with reduced Rust debug symbols and incremental output
  passed. On the installed app, a fresh mark was drawn, saved as
  `/private/tmp/untitled.inkproj`, exported as a 2048×2048 transparent PNG,
  undone, redone, and the project was reopened with the mark visible. The PNG
  was visually checked over white; the transparent background matches the
  project policy. This is a basic canvas journey, not comic-lettering or PSD
  external-fixture acceptance.
- A separate two-page print comic was saved as
  `/private/tmp/comic-photo-plan-macos.inkproj`, the macOS app was quit and
  relaunched, and the saved comic was reopened. The Comics workspace restored
  both 2400×1800 pages, two panels per page, and one dialogue balloon per page.
  PNG and SVG export after reopening produced both page pairs in
  `/private/tmp/comic-cold-export`. Both PNGs are 2400×1800 RGBA. Each SVG has
  one embedded artwork image and outlined dialogue with source text metadata;
  the two source strings are “Hi, artist!” and “And that's a wrap!”. The
  exported PNG was visually inspected and contains the balloon, dialogue, and
  panel borders. This validates the Latin lettering journey on macOS; Japanese
  vertical lettering remains covered by Rust fixtures, not an installed UI
  journey.
- `cargo test -p ink-engine
  pulled_string_stroke_reopens_and_replays_with_captured_brush_semantics
  --lib` passed. This added lifecycle fixture verifies pulled-string settings
  and committed pixels survive save/reopen, then undo/redo after reopen.
- Android real S Pen long strokes were reported intact. Private on-device
  terminal summaries show a broad low-to-firm normalized pressure span, while
  the user still rates the visible pressure response as weak. The exact brush
  for that comparison is not yet confirmed, so Android pressure acceptance is
  open. Gesture and save/reopen/export acceptance must be tracked separately.
  Physical iOS
  interaction and all device-specific comic/PSD/ABR/adjustment/stabilizer
  flows remain unverified.

## 2026-10-09 specification review

- Added the shared integration contract and one specification for each of
  Phases 1, 2A, 2B, 3, and 4. The contract resolves the draft's root-format-7
  proposal against the current format-8 vector baseline and keeps comic and
  brush versions independent.
- The phase specifications include allocation-before-decode requirements,
  detached import and publish-after-validation, coherent revision snapshots,
  premultiplied-alpha rules, one-step adjustment transactions, and stroke
  semantics capture. They identify mandatory independent PSD expectations and
  distinguish unit, build, install, and physical-device evidence.
- Added `editable_psd_round_trips_mask_defaults_disabled_state_and_clipping`
  and `editable_psd_candidate_preserves_disabled_mask_and_reveal_default_after_reopen`.
  The `ink-export` library suite passed (13 tests), the candidate save/reopen
  fixture passed, and strict Clippy passed for both `ink-export` and
  `ink-engine`. These verify Ink's writer/parser and candidate mapping;
  independent Photoshop-authored fixtures and composites remain necessary.
- The connected Galaxy S23 sent real S Pen strokes through the native adapter;
  terminal packet summaries showed broad pressure variation and no edge exits.
  The user reported weak visible pressure while long strokes remained intact.
  This confirms sensor variation reaches the app but does not pass brush
  response; verify the selected pressure-sensitive brush before changing
  versioned brush behavior.
- Time-lapse format 2 now includes brush revision, evaluator semantics, and
  pulled-string settings. Version-1 JSON reads with legacy defaults; appending
  to a v1 recording is rejected. `ink-tools` validates the metadata, and the
  pulled-string lifecycle test verifies that the emitted stroke record retains
  revision 1, semantics 2001, the 24 px setting, and catch-up.
- After the Galaxy test identified Technical Pen specifically, its built-in
  response was moved to revision 2 with a wider measured light-to-firm range.
  A host fixture requires at least a 35% size increase across the observed
  S Pen pressure values. The new preset has not yet been installed or retested
  on the phone.
- No implementation source was changed for this documentation review. Existing
  Rust/Flutter verification listed above remains the latest code evidence;
  installed Android S Pen behavior still awaits confirmation from the connected
  device test.

## 2026-10-09 follow-up verification

- Added three Photoshop 2026 PSDs from PhotoCraft Corpus commit
  `b2e1dcba8954efa9ad0e7944c258cc0e9a5efc1e`, with upstream licenses, hashes,
  and independently extracted embedded-composite RGBA oracles. The new
  `photocraft_psd_oracles` tests verify flattened composite bytes and explicit
  incompatibility reporting for clipped/masked adjustment content. A bridge
  test verifies Photoshop-authored flattened import maps to the same expected
  pixels. These fixtures do not yet prove supported editable Photoshop layer
  mapping or editable-export equivalence.
- Added adjustment recovery coverage: recovery from a corrupt current manifest
  restores Levels parameters and an identical composite from the backup while
  leaving the corrupt source untouched. Added action-router coverage and draft
  lifecycle guards so Apply/Cancel are required before undo/save or native
  window close; disposing the editor route queues cancellation. The focused
  recovery test and full Flutter suite (703 tests) passed.
- Added a merged-export matrix for Curves, non-identity Levels, and
  Hue/Saturation. It checks every pixel of PNG and flattened PSD against the
  same authoritative composite and verifies partial alpha preservation.
  `cargo test -p ink-engine adjustment_exports_match_composite --lib` passed
  all three focused cases; `cargo clippy -p ink-engine --all-targets -- -D
  warnings` passed.
- `cargo fmt --all -- --check`, full strict workspace Clippy, and staged and
  unstaged `git diff --check` passed. Full workspace Rust tests had passed
  earlier in this update; the new adjustment recovery and external-PSD oracle
  tests also passed individually.
- A fresh current-tree Android arm64 release APK built, passed apksigner and
  16 KiB alignment checks, and was installed with `adb install -r` under the
  existing alpha certificate. The app was launched. The user is retesting
  light versus firm S Pen strokes with Technical Pen revision 2; no pressure
  acceptance result is recorded yet.
- Fresh `flutter build macos --debug` passed and produced
  `app/build/macos/Build/Products/Debug/project_ink.app`. Fresh
  `flutter build ios --debug --no-codesign` passed and produced
  `app/build/ios/iphoneos/Runner.app`. The iOS result is compile-only; no iOS
  device is attached. macOS was not relaunched during this compile check.

- The Galaxy reported that S Pen taps did not activate toolbar or layer
  controls. The cause was Android `MainActivity.dispatchTouchEvent` returning
  `true` after publishing any stylus packet, which consumed the event before
  Flutter could hit-test controls. Android now leaves MotionEvents to Flutter
  and uses the generic Flutter stylus path for canvas strokes; native Android
  button commands remain. A regression test exercises S Pen taps on Undo and a
  layer row, then draws on the selected layer. `flutter analyze` and the
  relevant canvas, native-input, top-bar, and layer-panel suites passed (90
  tests); the full Flutter suite then passed all 704 tests.
- The corrected Android arm64 release APK was rebuilt, signed with the existing
  alpha certificate, verified for 16 KiB alignment, and installed in place.
  Its release-mode generated plugin registrant excludes `integration_test`,
  and `apkanalyzer` found no `integration_test` package in the APK. The device
  app was launched; physical S Pen retest of controls, layer targeting, and
  Technical Pen pressure is still pending.

## 2026-10-09 Android freehand regression

- The user reported that S Pen marks had become straight, slanted lines after
  the Android input-path change. The cause was a stale draw-and-hold quiet
  interval: its snapshot read the native input clock, but Android stylus input
  now arrived through Flutter, so the default Straighten gesture fired while
  the pen was still moving.
- `CanvasDrawAndHoldCoordinator` now owns one monotonic arrival clock shared by
  Flutter and native stylus paths. Each stylus arrival restarts the quiet
  interval and cancels any armed gesture; the timer checks the interval again
  before dispatch. The pointer router reports arrivals before routing the
  event. This preserves the existing straightening gesture after a genuine
  quiet hold while allowing ordinary Android freehand strokes.
- The focused draw-and-hold, pointer-router, native-input, and Android
  pointer-failure tests passed (32 tests); `flutter analyze` passed; then the
  full Flutter suite passed all 707 tests. Rust tests were not rerun for this
  Dart-only input fix.
- A fresh arm64 release APK built successfully, was signed with the existing
  alpha certificate, passed signature and 16 KiB alignment checks, and was
  installed over the existing app with `adb install -r`. The app launched;
  package inspection confirms version 0.1.0 and no `integration_test` artifact.
  APK: `artifacts/alpha-0.1.0/android-s-pen-freehand-fix-20261009/`
  (`5c98c5cedfd7761cbd0cc7eaf17db593a4fee14648009e2042d54f59e99b4bac`).
- The user must still confirm freehand curves and short handwriting on the
  installed Galaxy S23. The build and automated tests do not establish physical
  S Pen acceptance.

## 2026-10-09 Android stroke handoff latency

- The user then reported a noticeable final stroke redraw on Android. The
  Android `InkLiveTextureRegistry.redraw` path cleared the SurfaceProducer
  canvas and replayed every retained dab for every incoming packet. As a stroke
  grew, the render thread repeated an increasingly large set of `drawCircle`
  calls; the per-update work was linear in the stroke's accumulated dabs and
  the complete stroke's replay cost was quadratic.
- Android now records dabs in hardware `RenderNode` groups keyed by stroke,
  eight input sequences, and 64 dab indices. New and corrected packets rebuild
  only affected groups. Acknowledgement/eviction rebuilds the affected groups,
  viewport changes rebuild retained groups, and each SurfaceProducer frame
  composites the cached nodes. This retains the transient preview and CPU-tile
  authority while avoiding a full-screen bitmap allocation.
- `flutter test test/android_live_surface_controller_test.dart` passed all 6
  tests; `./gradlew :app:compileReleaseKotlin` passed. The arm64 release APK
  built after running config-only and verifying the generated release
  registrant excludes `integration_test`; the signed APK passed apksigner and
  16 KiB alignment checks. `adb install -r` updated the connected Galaxy S23
  without uninstalling app data, and the app launched.
- The physical S Pen comparison remains open. The release build and host tests
  do not establish that the final handoff now feels immediate or that the
  cached RenderNode preview matches committed brush output. Record a real
  long-stroke and short-stroke comparison on the S23 before closing this gate.

## 2026-10-09 current-state audit

- The implementation gaps described in the latest continuation prompt do not
  match the current checkout: editable PSD import/export is implemented in
  `ink-export`, `ink-engine`, `ink-bridge`, and Flutter document actions; ABR
  import is implemented through the verified brush-library transaction;
  adjustment preview/apply/cancel and pulled-string controls are bridged and
  exposed in Flutter; comic dialogue is rendered by Rust into the main canvas
  overlay, and warning confirmation is checked again before export. These are
  source-path findings, not device-acceptance claims.
- Current focused verification passed: `cargo test -p ink-comic --lib` (22
  tests), `flutter test test/workspace_panels_test.dart` (4 tests), and the
  comic warning-confirmation widget test (1 test). The ABR parser suite passed
  all 157 tests and the four ABR conversion tests passed after aligning the
  parser's cumulative decoded-sample cap with Ink's 256 MiB import budget.
- The editable PSD gap remains real: the existing Photoshop-authored fixtures
  verify flattened composite oracles and incompatibility reports, not supported
  editable-layer mapping or external equivalence for Ink-exported layered
  files. A local Photoshop automation attempt stalled before creating a
  fixture, so it contributes no acceptance evidence.
- The Galaxy S23 is currently connected with Project Ink 0.1.0 installed.
  Physical confirmation of freehand shape, S Pen toolbar/layer taps, pressure,
  and short/long-stroke handoff remains pending. The current app install and
  native compile are not a substitute for that interaction.
- Disk headroom fell to approximately 806 MiB during focused Rust/Flutter test
  compilation. Do not start fresh macOS, iOS, or Android builds until there is
  safe build headroom; preserve existing build outputs and caches.

## 2026-10-09 implementation continuation

- Added separate Curves, Levels, and Hue/Saturation export tests. Each compares
  every PNG and flattened-PSD output pixel against the Rust composite and checks
  partial-alpha preservation. `cargo test -p ink-engine
  adjustment_exports_match_composite --lib` passed all three tests, and
  `cargo clippy -p ink-engine --all-targets -- -D warnings` passed.
- Regenerated FRB with the pinned `flutter_rust_bridge_codegen 2.13.0`. The
  Dart outputs and C header remained byte-identical; the generated Rust file
  updated to include current vector-candidate and adjustment-transaction
  exports. `cargo test -p ink_bridge --lib` passed all 71 tests.
- Android live-surface redraws are now coalesced to display-frame cadence.
  Android Kotlin compilation and all six focused Flutter live-surface tests
  passed. The Galaxy was not attached during this continuation, so the long
  S Pen stroke has not yet been retested against this change. Android signing
  variables are not configured in the current shell.
- At this continuation the device is absent from `adb devices`, and free build
  headroom is about 10 GiB. The earlier 806 MiB reading above is historical;
  current build feasibility must be checked before another full platform build.

## 2026-10-09 cross-platform verification update

- The full Rust workspace gate passed after the adjustment export matrix and
  current FRB regeneration: `cargo test --workspace --all-targets
  --all-features`. Strict workspace Clippy, workspace rustfmt check, and
  `git diff --check` also passed.
- The complete Flutter suite passed all 707 tests and `flutter analyze` passed.
- Reduced-symbol macOS debug build passed. The iOS device-target debug build
  passed with code signing disabled; this is compile-only and no iOS device was
  attached.
- The Galaxy S23 Ultra reappeared on USB, but no updated Android package has
  been installed. The current shell lacks the alpha keystore/signing variables;
  the installed app is still the prior 0.1.0 build. The Android redraw change
  therefore remains physically unverified.
- After the macOS/iOS builds, free disk headroom is about 2.2 GiB. Preserve
  existing caches and check headroom before another full platform build.
- Added a separate four-layer PSD authored against the public format
  specification, with provenance and hashes in
  `rust/testdata/pine-and-birch-psd/README.md`. Its editable layer names and
  merged composite now pass against pixels independently rendered by
  `psd-tools` 1.11.0. This covers basic editable parsing, not Photoshop's
  grouped/mask/clipping cases or Ink's external editable-export equivalence.

## 2026-10-09 external editable PSD lifecycle verification

- Added a bridge-level test that imports the independently authored four-layer
  PSD as an editable candidate, verifies layer order and names, saves the
  resulting `.inkproj`, reopens it, and compares all 640×480 composite pixels
  against the independent `psd-tools` PNG oracle. It then exports editable PSD,
  verifies the four layers remain editable, and compares the exported merged
  composite byte-for-byte with that same independent oracle.
- `cargo test -p ink_bridge
  independently_authored_editable_psd_survives_candidate_save_and_reopen
  --lib` passed. `cargo fmt --all -- --check`,
  `cargo clippy -p ink_bridge --all-targets -- -D warnings`, and
  `git diff --check` passed.
- This closes the basic external editable-import/save/reopen/export host
  journey. It does not cover Photoshop-authored groups, masks, clipping,
  complex layer semantics, or installed app acceptance.
- A Galaxy S23 long stroke was performed, but the installed package is not
  debuggable and its Dart trace flag was not enabled. `adb run-as` therefore
  cannot retrieve a trace for that stroke; the latest local Android trace is
  from an earlier run. The RenderNode redraw change still needs a fresh
  trace-enabled signed install and physical long-stroke comparison.

## 2026-10-09 ABR report completeness

- Fixed the sectioned ABR importer so presets and standalone sampled tips
  beyond the 256-item conversion cap are reported by count. Unsupported
  settings are listed up to the 128-entry per-brush report bound, including
  file-level omissions; presets exceeding that bound are explicitly omitted
  with a reason. If malformed or skipped records exceed the global
  complete-report bound, conversion rejects the file before any brush-library
  transaction can begin.
- Added fixtures for 257 presets, 257 standalone sampled tips, a preset with
  129 unsupported settings, 129 malformed presets, and combined per-brush
  report overflow. The tests verify explicit cap reports and rejection of
  unreportable partial imports.
- `cargo test -p ink-brush --lib` passed all 63 tests;
  `cargo clippy -p ink-brush --all-targets -- -D warnings`,
  `cargo fmt --all -- --check`, and `git diff --check` passed.

## 2026-10-09 comic warning visibility

- The Rust renderer can return a bounded list of up to 4,096 lettering
  warnings, while the Flutter confirmation previously rendered only the first
  12. Replaced that preview with a virtualized scroll list that presents the
  full returned report before the artist chooses whether to export.
- Expanded the widget test to include missing-glyph and overflow warnings plus
  13 more entries. It scrolls to a page-14 warning beyond the old cutoff,
  verifies cancellation prevents export, then changes the warning list while
  the dialog is open and verifies that export is canceled until the artist
  reviews and confirms the fresh report.
- `flutter test test/canvas_document_actions_test.dart --plain-name 'comic
  export requires explicit confirmation for render warnings'` and focused
  `flutter analyze` passed. The UI still rechecks the warning list after user
  confirmation and cancels if it changed.
- The current Flutter tree built successfully for macOS with
  `CARGO_PROFILE_DEV_DEBUG=0 CARGO_INCREMENTAL=0 flutter build macos --debug`.
  This is a compile result, not an installed macOS interaction run. The build
  left about 849 MiB free; iOS and Android were not rebuilt in this pass.
- The Galaxy S23 remains connected, but this shell exposes no Android signing
  variables, the installed app is non-debuggable, and the latest long-stroke
  trace was not captured. Do not count the RenderNode change as device-verified.

## 2026-10-09 Android long-stroke batch handoff

- Source review found that `NativeLiveSurfaceController` awaited one platform
  call for each 2,048-dab packet, while Android completed each call only after
  its next Choreographer frame. A long-stroke drain could therefore wait up to
  four display frames even after native `RenderNode` caching removed repeated
  circle recording.
- Android now accepts one bounded group of up to four packets, applies the
  decoded dabs and re-records affected nodes once, then publishes one surface
  frame. The platform-neutral desktop adapter preserves packet order and its
  existing per-packet channel contract. The confirmed CPU preview remains the
  fallback until native presentation completes.
- `flutter test test/android_live_surface_controller_test.dart
  test/desktop_live_texture_adapter_test.dart` passed all 11 tests;
  focused `flutter analyze` passed. `./gradlew :app:compileReleaseKotlin`
  passed. The device has not yet been rebuilt or tested with this batching
  change, and the private trace from the preceding stroke is unavailable from
  the non-debuggable installed alpha.

## 2026-10-09 Photoshop group, clipping, and mask conformance

- Added externally sourced Photoshop PSD fixtures from the pinned psd-tools
  corpus. The nested group/clipping fixture verifies layer ancestry, offsets,
  clipping semantics, and the complete Rust composite against the independent
  Photoshop/psd-tools PNG. It also exposed and fixed a parser projection bug:
  a clipping byte on a Photoshop folder record is ignored for group semantics.
- Added a Photoshop raster-mask fixture, with provenance and regeneration
  instructions. Its bridge test imports the file as an editable candidate,
  confirms the mask owner, saves and reopens `.inkproj`, then compares the full
  page against the independent rendered image (up to 2 RGB levels and 1 alpha
  level for premultiplied-channel rounding).
- That full-pixel comparison exposed and fixed a compositor bug: mask coverage
  had replaced source alpha before unpremultiplying stored colors, whitening
  partially masked pixels. Source alpha now remains the divisor; masked alpha
  is used only for compositing coverage.
- `cargo test -p ink_bridge --lib photoshop` passed 3 tests, including the
  grouped/clipped, raster-mask save/reopen, and existing flattened oracle
  journeys. `cargo test -p ink-export --test psd_tools_conformance` passed 2
  fixture mapping tests.
- This closes those host-side PSD structure and render cases. It does not
  establish installed PSD import acceptance or Photoshop round-trip fidelity
  beyond the tested subset. The S23 long-stroke trace remains unavailable:
  `adb run-as org.projectink.studio` reports that the installed package is not
  debuggable.

## 2026-10-09 PSD offset-preserving export

- The external group/clipping and mask checks were extended through editable
  PSD export. The exported Photoshop group retains the blue child's `(175,80)`
  offset, parent group, and clipping flag; exported composite pixels match the
  external oracle. The reopened raster mask retains its own `(23,10,71,57)`
  bounds and its exported merged pixels match the independent oracle.
- Editable PSD export now crops raster layer payloads to their nontransparent
  bounds and records document-space offsets. Masks are independently cropped
  to their nondefault coverage bounds; an all-default mask uses a 1×1 sample.
  Validation rejects mismatched payload dimensions and out-of-range bounds.
- `cargo test -p ink-export` passed 14 unit tests and 6 external-fixture
  tests, including bounded-offset validation. `cargo test -p ink-engine
  editable_psd` passed all 4 candidate/export tests. The complete
  `cargo test -p ink_bridge --lib` suite passed all 74 tests, including the
  Photoshop group/clipping and mask import/export comparisons.
- `cargo fmt --all -- --check` and `git diff --check` passed.
- Set `PROJECT_INK_PSD_ORACLE_DIR=/tmp/project-ink-psd-export-oracles` while
  running the three Photoshop bridge tests, then independently rendered both
  emitted files with `tools/verify_external_psd_composite.py` and psd-tools
  1.11.0. Both third-party renders matched their independent PNG oracles with
  zero per-channel difference. The external parser also confirmed the exact
  group and blue-layer bounds/clipping, and the raster mask bounds
  `(23,10,94,67)`.
- Rust format check, Clippy, and workspace-wide checks have not been rerun for
  this change. Only about 536 MiB was free during the focused checks, so no
  broad build was started. Installed macOS/Android import/export acceptance
  remains open.

## 2026-10-09 ABR pressure dynamics mapping

- The sectioned ABR converter now maps zero-jitter Pen Pressure size and
  opacity controls to linear pressure bindings using the configured minimum.
  Jittered and non-pressure controls remain explicit per-setting omissions.
  The conversion stays Approximate, Tier C.
- Added fixtures for supported pressure size/opacity and unsupported jitter/
  tilt controls. `cargo test -p ink-brush --lib abr_` passed all 12 ABR-focused
  tests, `cargo clippy -p ink-brush --all-targets -- -D warnings` passed,
  `cargo fmt --all -- --check` passed, and `git diff --check` passed. These are
  host checks; broader ABR descriptors and installed library acceptance remain
  open.
- Added an engine save/reopen test for the imported pressure bindings. It
  passed on retry with `CARGO_PROFILE_DEV_DEBUG=0 CARGO_INCREMENTAL=0 cargo
  test -p ink-engine --lib
  imported_abr_pressure_bindings_survive_project_reopen`.
- A trace-enabled Android debug APK with the parallel
  `org.projectink.studio.debug` identity built and installed beside the signed
  alpha. Startup confirms the rolling diagnostic log and Phase 1 trace path;
  the long-stroke interaction and trace analysis are still pending.

## 2026-10-09 Android long-stroke trace follow-up

- The initial attempt did not record pointer packets; that capture was
  inconclusive. A subsequent S23 interaction produced 975 confirmed samples
  across four strokes, including one approximately 4,003-document-pixel stroke
  with 956 points and 9,538 compiled dabs. There were no rejected packets or
  sequence gaps.
- The opt-in trace report failed its 40 ms Android input-to-visible target:
  worst recorded p95 was 321.363 ms. The worst commit-stage sample spent
  162.688 ms reading/compositing a three-tile immutable snapshot, 23.435 ms
  decoding tile images, and 254.626 ms from refresh start to state
  publication. The corresponding frame arrived 271.575 ms after refresh began.
  For the long stroke's final commit, the trace records about 170.6 ms from
  pen-up to preview retirement and about 184.3 ms to the next frame. Initial
  pointer-to-preview p95 was 2.434 ms, so the observed delay is concentrated
  in committed CPU tile handoff, not first live-preview appearance.
- This was an installed debug build with Rust development optimization off;
  it identifies the debug-path bottleneck but does not establish release APK
  latency or physical alpha acceptance. Keep the trace local because
  diagnostics may include artwork tile data.
- The measured composite read is consistent with repeated per-tile setup in
  `CompositeTileReadSnapshot::read_tiles`: each tile rebuilds ordered layer
  state, adjustment LUTs, masks, group ancestry, and scratch buffers before
  pixel composition. This is a source-level optimization candidate, not yet
  a verified root cause for the measured time. A release-profile trace is
  needed before changing or accepting the Android performance gate.

## 2026-10-09 current-worktree verification

- `CARGO_PROFILE_DEV_DEBUG=0 CARGO_INCREMENTAL=0 cargo test --workspace
  --all-targets --all-features` passed across the current Rust workspace.
  Strict workspace Clippy passed after replacing the PSD mask sample scans
  with `contains`, using `map_or` for the PSD tile-record fallback, and
  extracting the sampled-ABR fixture writer from its long test. The bridge
  Photoshop group/clipping oracle test and both ABR engine persistence tests
  passed again after those refactors.
- `flutter analyze` passed and `flutter test` passed all 711 tests. This
  includes the current comic export-warning confirmation and adjustment-editor
  transaction flows.
- FRB code generation completed with the pinned 2.13.0 script. The generated
  Dart API exposes comic warnings/previews, adjustment transactions, verified
  ABR import, editable PSD export, and stabilization fields; `cargo check -p
  ink_bridge --lib` passed. `git diff --check` passed. Workspace `cargo fmt
  --all -- --check` reports only import ordering in the generated Rust FRB
  file; handwritten Rust files pass direct `rustfmt --check`. Do not hand-edit
  generated bindings to silence that formatter difference.
- A macOS debug compile passed into a separate build directory while the
  existing app process remained open. The temporary build output was moved to
  Trash after disk pressure; the compile result remains valid, but that debug
  bundle is no longer available for installation. An unsigned iOS debug device
  build also passed (`Runner.app`); this is compile-only evidence.
- A current-source Android debug rebuild was attempted but stopped while
  linking `libink_bridge.a` with `No space left on device`. The already
  installed trace-enabled debug package and signed alpha package were not
  replaced or uninstalled. The installed trace-enabled debug app then captured
  the S Pen interaction summarized above. No release-profile Android latency
  pass is claimed.

## 2026-10-09 batched composite setup reuse

- `CompositeTileReadSnapshot::read_tiles` now prepares ordered layer
  presentation, adjustment LUTs, mask references, adjustment scopes, and group
  ancestry once for the requested batch, then reuses that immutable plan for
  each tile. Per-tile pixels and scratch buffers remain independent; document
  snapshots and format versions are unchanged.
- A new two-tile regression test compares each batched output byte-for-byte
  with its single-tile read. All 145 `ink-engine` library tests passed after
  the change, including the compositor and adjustment cases. Strict
  `ink-engine` Clippy passed.
- This removes repeated metadata preparation by construction, but no timing
  improvement is claimed yet. The S23 measurements came from a debug APK, and
  a release-profile latency trace on the current source is still required.

## 2026-10-09 optimized Android profile capture

- Android profile builds initially shared the signed alpha package ID while
  carrying the debug signing certificate. Installing that APK would have
  required replacing the signed alpha, so it was not installed. The Android
  profile build type now shares the existing `.debug` test package suffix;
  profile tracing remains debuggable for local `run-as` retrieval.
- The trace-enabled arm64 profile APK built successfully with release Rust
  optimization and installed via `adb install -r` as
  `org.projectink.studio.debug`. The signed alpha package remains installed
  and untouched. Startup confirmed the trace-enabled app is foregrounded.
- The user completed a 251-sample S Pen stroke on the profile build, with no
  rejected confirmed samples or sequence gaps. The captured stroke compiled
  886 dabs and produced 227 CPU tile updates. Its final composite snapshot read
  took 4.128 ms, tile image decode took 1.328 ms, and refresh-to-frame took
  9.616 ms; the live preview was retired 1.134 ms after pen-up. The user still
  reported a perceptible delay, so these stage timings do not close the report.
- The complete trace report still fails: worst recorded p95 is 6,936.074 ms
  and the final p95/p99 are 10.824/5,654.402 ms against a 40 ms target. The
  trace records an early high tail but does not tie that outlier to a specific
  stroke in its summarized output. No Android acceptance pass is claimed; the
  reported perception and tail-latency evidence remain open for investigation.

## 2026-10-09 Android post-stroke redraw investigation

- The user confirmed the visible delay is the final committed render after
  lifting the S Pen. A fresh trace from the optimized Android profile package
  contained three completed stylus strokes and no rejected packets or sequence
  gaps. Pen-up to the matching committed CPU frame measured 15.674 ms,
  26.945 ms, and 16.901 ms. These are app-side post-frame measurements and do
  not include display scan-out.
- The final stroke's CPU commit contained seven monotonic packet acknowledgments
  for the same retained GPU stroke. `CanvasTileSynchronization` dispatched
  each independently; Android's texture adapter rebuilt the retained render
  batches for every call, even though the highest sequence subsumed the earlier
  acknowledgments. This is a concrete source of repeated post-commit redraws.
- `NativeLiveSurfaceController` now coalesces pending acknowledgments per stroke
  to the highest committed sequence and performs one native texture rebuild
  for the burst. Once the corresponding CPU frame is published, it hides the
  Flutter texture immediately when all retained dabs are CPU-covered; native
  cleanup no longer delays the committed canvas. Focused controller tests
  prove three concurrent packet acknowledgments issue one native call at
  sequence 3 and that the empty texture hides before delayed native cleanup.
- The trace-enabled profile APK rebuilt successfully and was installed as
  `org.projectink.studio.debug`; the signed alpha package remains installed.
  The focused Android live-surface tests, full Flutter suite (712 tests), and
  `flutter analyze` passed. The user retested a long S Pen stroke and confirmed
  the extra final redraw is gone. The fresh profile trace records preview
  retirement 11.7 ms after pen-up and a CPU frame 20.6 ms after pen-up; these
  app-side timings do not include display scan-out.
  The latest trace snapshot's cumulative p95 is 11.3 ms with no rejected or
  missing confirmed samples. The run's worst recorded p95 is still 87.7 ms,
  above the 40 ms S23 gate, so the broader latency gate remains open. S23
acceptance for stabilization and the other feature workflows also remains
open.

## 2026-10-09 FRB regeneration and iOS recheck

- `scripts/generate_frb.sh` completed with `flutter_rust_bridge_codegen 2.13.0`.
  Review confirmed the regenerated Rust/Dart endpoints include current comic
  overlay/warning rendering, PSD inspection/import/export, verified ABR install,
  adjustment transactions, stabilizer settings, and vector-candidate APIs.
  `cargo check -p ink_bridge --lib` passed, as did `flutter analyze` and the
  full Flutter suite (712 tests) against the regenerated files.
- `cargo fmt --all -- --check` reports only import ordering in the generated
  Rust file. Per the repository rule, generated bindings were not hand-edited
  to silence that difference.
- The first iOS build attempt reached Xcode linking but failed with `No space
  left on device`; after the failed process released temporary space, a retry
  succeeded: `CARGO_PROFILE_DEV_DEBUG=0 CARGO_INCREMENTAL=0 flutter build ios
  --debug --no-codesign` produced `app/build/ios/iphoneos/Runner.app`.
  `flutter devices` found no iPad, so this is compile-only evidence. The running
  macOS editor and its build output remain preserved.
- A current-source macOS debug build also succeeded in the isolated
  `.ink-macos-build` directory while the existing editor remained open. The
  temporary Flutter build-directory setting was cleared afterward; the
  isolated app bundle is retained as local build output.

## 2026-10-09 Android post-stroke redraw retest

- After installing the updated profile build, the user repeated a long S Pen
  stroke, lifted, and confirmed the final committed redraw is no longer visible
  as a second delayed line. This closes the specific post-stroke redraw
  symptom for that S23 run; it does not close the separate p95 latency gate or
  other feature acceptance journeys.
- The controlled light-versus-firm Technical Pen pressure comparison remains
  open. The earlier S23 trace contains mixed interaction samples and is not a
  calibrated pressure test.

## 2026-10-09 focused ABR confirmation

- Re-ran `cargo test -p ink-brush
  abr_v6_computed_descriptor_maps_scalars_and_preserves_source_attribution
  --lib`; the sectioned ABR v6 computed-tip conversion test passed.
- That fresh Cargo test build left about 314 MiB free on the data volume. No
  cleanup was performed; further builds are deferred until disk headroom is
  available.

## 2026-10-09 Technical Pen pressure revision 3

- The captured S23 trace's normalized pressure p10/p90 values were about
  0.106/0.435, while the earlier host fixture compared a much wider range.
  Technical Pen revision 3 now allocates more diameter change across the
  observed S23 span and retains the Apple Pencil low-force ramp. Its host test
  requires at least 35% greater dab radius between the observed p10 and p90.
- `cargo test -p ink-brush --lib technical_pen_` passed all 9 matching tests;
  `starter_pressure_curve_expands_the_observed_low_force_range` and
  `built_in_pressure_curves_keep_ramping_through_firm_pressure` also passed.
  A first candidate failed the existing Apple Pencil test and was revised
  before this passing run.
- At that checkpoint this was host evidence only and Android pressure
  acceptance remained open; the build and install were completed later as
  recorded below.
- After the full `ink-brush` suite passed (66 tests), the current source built
  as an Android arm64 profile APK with
  `CARGO_PROFILE_RELEASE_DEBUG=0 CARGO_INCREMENTAL=0 flutter build apk
  --profile --target-platform=android-arm64`. `adb install -r` succeeded for
  the existing `.debug` package, preserving app data; the updated app was
  launched. The build emitted the existing NDK 27.1 versus plugin 28.2
  compatibility warning. Physical pressure confirmation is still pending.
- The user tested that revision-3 profile APK with light and firm S Pen strokes
  and still found the pressure response weak. Revision 4 now maps pressure
  directly to Technical Pen's base diameter, with a 12% minimum, instead of
  multiplying an already-full-width mark. All 9 `technical_pen_` tests pass
  for the revision-4 evaluator, including the measured S23 p10/p90 range.
- That stronger evaluator also exposed a live-preview mismatch: Flutter assumed
  multiplicative pressure while Rust used direct diameter mapping. The Rust
  brush projection, FRB DTO, Dart brush projection, and preview painter now
  carry the replace-versus-multiply mode, with a paired Rust projection test
  and Flutter width test. FRB regeneration succeeded. The Rust engine test
  attempt then failed during dependency compilation with `No space left on
  device`, before reaching the test; Flutter preview tests have not run.
- Revision 4 and preview-parity changes are source-only: the installed S23
  package still contains revision 3. Only 119 MiB remained after the failed
  host build. The obsolete isolated `.ink-macos-build` bundle was moved
  recoverably to `~/.Trash/.ink-macos-build`; it did not free APFS space because
  Trash has not been emptied. The running macOS app at `app/build/macos` and
  the Android profile build cache were preserved.

## 2026-10-09 Approved disk recovery and revision 4 verification

- The user explicitly approved permanently deleting the exact isolated
  `~/.Trash/.ink-macos-build` item. That item was removed; no other build
  outputs or caches were cleaned. The running macOS app and Android build
  cache were preserved. The immediate recovery raised free space to about
  2.2 GiB.
- Revision 4 verification passed the full 66-test `ink-brush` suite, the
  focused `ink-engine` brush-summary projection test, the Flutter live stroke
  preview tests, `flutter analyze`, targeted Rust formatting, Dart formatting,
  and `git diff --check`. Flutter analysis found one redundant nested `const`
  in the in-memory adapter; it was removed and analysis then passed.
- A new Android arm64 profile APK built successfully and was installed with
  `adb install -r` over `org.projectink.studio.debug`, preserving app data. The
  updated app launched on the connected Galaxy S23 Ultra. The build still
  reports the existing NDK 27.1 versus plugin 28.2 warning. The user has been
  asked to repeat the controlled light-versus-firm Technical Pen test on this
  revision 4 build. The user reported the stroke starts smaller and the firm
  stroke also appears smaller; this does not pass pressure acceptance. A
  follow-up requests a controlled comparison at 12 px to separate the
  expected start taper from pressure response.
- Current free space after the Rust and Android builds is about 1.2 GiB.
- The complete `flutter test` run finished with 64 visual golden mismatches;
  `flutter analyze` and the focused live-preview tests pass. Failure artifacts
  were retained and goldens were not regenerated. This broad UI suite is not a
  passing gate for the current checkout. Inspecting one failure pair shows the
  checked-in master image displays a 12 px brush while the current test render
  displays 4 px; this is a meaningful state mismatch rather than a tiny
  rendering-noise difference. The golden changes are pre-existing staged work
  and were not altered as part of this pressure fix.

## 2026-10-09 feature-suite and current-source iOS verification

- The focused Flutter suites for comic workspace, PSD/ABR document actions,
  adjustment/layer actions, brush library, and comic panel actions passed all
  143 tests.
- Reused the freshly compiled current-source Rust test executables to run 17
  focused engine tests: editable PSD construction/export, ABR paint and reopen,
  adjustment preview/apply/recovery/export, pulled-string persistence/replay,
  and comic checkpoint/reopen. The `ink-comic` test executable separately
  passed Japanese vertical dialogue save/reopen/export-once and warning
  identification for fallback fonts, missing glyphs, and overflow.
- A current-source iOS device-target compile was attempted with debug symbols
  and incremental compilation disabled. Xcode reached Rust bridge compilation,
  then failed writing Rust metadata and the result bundle with `No space left
  on device`. Only about 117 MiB remains. The running macOS app is still
  present at `app/build/macos` (PID 68816).
- The failed build left about 603 MiB under the exact iOS Rust intermediate
  directory in Xcode DerivedData; `lsof` found no process holding that path.
  After the user approved deletion of that exact directory, it was removed;
  no other DerivedData or build outputs were changed. Free space is now about
  731 MiB at that checkpoint, so the full iOS build was deferred until further
  authorized space recovery. The later successful retry is recorded below.

## 2026-10-09 current-source Apple build retry

- The user approved deleting the exact unused 1.6 GiB `app/build/ink_bridge`
  directory. Inspection showed it contained Android arm64 profile Rust output;
  the installed Android APK and running macOS bundle were separate and remain
  intact. The Android bridge cache will be rebuilt if another Android package
  build is needed.
- Restored Flutter's missing `.dart_tool/package_config.json` with
  `flutter pub get --offline`; `app/pubspec.lock` remained unchanged.
- Current-source iOS device-target debug compile then passed:
  `CARGO_PROFILE_DEV_DEBUG=0 CARGO_INCREMENTAL=0 flutter build ios --debug
  --no-codesign`. It is compile-only; no iOS device is attached.
- Current-source macOS debug compile also passed in the isolated
  `app/.ink-macos-build` output directory while the previously running app
  remained open and untouched. Flutter's temporary `build-dir` setting was
  restored to its original unset state. This is compile-only; the new bundle
  has not been opened for interactive acceptance.
- The current app still has revision 4 installed on Android. The controlled
  12 px light-versus-firm pressure comparison has not yet been reported.
  Remaining disk space after both Apple builds is about 472 MiB.

## 2026-10-09 current-source macOS interactive spot check

- Launched the isolated current-source macOS build at
  `app/.ink-macos-build/macos/Build/Products/Debug/project_ink.app` after
  gracefully closing the prior instance. The new-canvas dialog showed the
  screen-size default and created a canvas.
- In the Comics workspace, created a print comic, added two panels to page 1,
  added page 2, and created horizontal and vertical dialogue entries. The
  workspace projection reported 2 pages, 2 panels, and 2 balloons. This is a
  partial interactive smoke check only; dialogue replacement, visible canvas
  lettering, explicit project save/reopen, and PNG/SVG export were not
  confirmed in this run.
- A generic “Comic operation failed” message appeared when first opening the
  Comics workspace with no comic project. Starting a new print comic then
  succeeded and the error cleared. Follow up whether opening the workspace
  without a project should display an empty state without an error.
- Full Flutter tests remain red with 64 visual golden mismatches; the goldens
  were not regenerated. Current-source iOS and macOS build results are
  compile-only. No iOS device is attached. Android pressure acceptance remains
  pending the controlled 12 px light-versus-firm S Pen comparison.
- After exiting the interactive macOS build, the host reports about 850 MiB
  free. No build caches were removed beyond the exact approved paths recorded
  above.

## 2026-10-09 FRB regeneration and audit reconciliation

- After the user approved deletion of the exact isolated
  `app/.ink-macos-build` output, it was permanently removed. The existing
  `app/build/macos/Build/Products/Debug/project_ink.app` bundle remained
  present. Disk space rose to about 2.2 GiB immediately after deletion.
- Re-ran `CARGO_PROFILE_DEV_DEBUG=0 CARGO_INCREMENTAL=0
  CARGO_BUILD_JOBS=1 ../scripts/generate_frb.sh` from `app/`; generation
  completed with the pinned `flutter_rust_bridge_codegen 2.13.0`. The output
  includes the current Rust/Dart bridge interfaces.
- `CARGO_PROFILE_DEV_DEBUG=0 CARGO_INCREMENTAL=0 CARGO_BUILD_JOBS=1 cargo
  check -p ink_bridge --lib` passed after rebuilding the Rust dependencies.
  `flutter analyze` passed with no issues, and staged/unstaged `git diff
  --check` passed.
- `cargo fmt --all -- --check` still reports only import ordering in the
  generated Rust FRB file. The generator output was not hand-edited. No full
  tests or new platform builds were run in this continuation; the prior 64
  visual golden mismatches and device gates above remain open. Free disk space
  after verification is about 1.6 GiB.
- The earlier “Remaining release work” list was reconciled against later
  entries: independent PSD group/clipping/mask import/export oracles now cover
  the documented subset, while installed acceptance, Android pressure,
  latency, expanded ABR fixtures, the current Flutter golden failures, and
  physical iOS interaction remain open as detailed above.

## 2026-10-09 Technical Pen pressure acceptance on revision 4

- The user repeated the S23 comparison with Technical Pen at 12 px and
  reported that the firm stroke's middle section was wider than the light
  stroke's. This supersedes the earlier revision-4 report that both marks
  appeared smaller and closes the pressure-direction gate for that controlled
  comparison.
- Private local device diagnostics contain two similarly sized stylus paths
  with clearly separated normalized pressure distributions: medians 0.064 and
  0.732, with p10/p90 ranges 0.021–0.122 and 0.514–0.866. Only aggregate
  sensor statistics were inspected; packet bytes and artwork remain private.
- This result verifies pressure direction at one brush size on the S23. It
  does not close S Pen toolbar/layer hit testing, the separate 40 ms latency
  gate, stabilization interaction, or other Android feature journeys.

## 2026-10-09 Technical Pen revision 5 and Flutter suite

- The staged editor screenshots consistently show an initial 12 px Technical
  Pen, while a representative current render showed 4 px. The Rust built-in
  and in-memory bridge adapter both supplied 4 px, so the screenshots and
  runtime state disagreed. Updated the V2 built-in Technical Pen to 12 px and
  bumped its preset revision from 4 to 5; the legacy evaluator's starter
  preset remains unchanged. Saved brush overrides continue to retain their
  captured data.
- Added a revision-5 assertion for the 12 px default and retained explicit
  4 px fixtures for tests whose expected values concern taper or dynamic
  binding math. All 66 `ink-brush` tests passed.
- The previously failing representative desktop golden now passes without
  changing the staged snapshots. `flutter analyze` passed and the complete
  Flutter suite passed all 713 tests. This resolves the earlier 64-golden
  failure cluster.
- The Android package currently installed on the Galaxy is still revision 4;
  revision 5 has not yet been built or installed. No Android or iOS build was
  rerun after this preset change. Stylus toolbar/layer tap confirmation remains
  pending; the latest pressure-direction comparison at 12 px passed as recorded
  above.

## 2026-10-09 revision-5 engine and macOS verification

- `CARGO_PROFILE_DEV_DEBUG=0 CARGO_INCREMENTAL=0 CARGO_BUILD_JOBS=1 cargo
  test -p ink-engine --lib` passed all 146 tests after updating the long-stroke
  prediction-cost fixture to use a longer, in-bounds path with the new 12 px
  base diameter. `cargo check -p ink-engine --tests` also passed.
- `cargo test -p ink-brush --lib` passed all 66 tests, including the Technical
  Pen revision-5 size/pressure contract and the ABR parser cases.
- The full Flutter suite passed all 713 tests and `flutter analyze` found no
  issues against the revision-5 in-memory projection. The staged 12 px
  screenshots were left unchanged.
- `CARGO_PROFILE_DEV_DEBUG=0 CARGO_INCREMENTAL=0 CARGO_BUILD_JOBS=1 flutter
  build macos --debug` passed and produced the current-source
  `app/build/macos/Build/Products/Debug/project_ink.app`. This bundle was
  opened for a non-editing startup spot check. The S23 still has the revision-4
  profile package, and the iOS compile was not repeated after the size-only
  preset update.
- The engine test exposed one fixed-count assumption: the larger 12 px brush
  spaces dabs farther apart, so the test's previous 512-sample path no longer
  exceeded 1,000 dabs. The fixture now uses 1,024 in-bounds samples at 1.5 px
  intervals; the prediction bound remains unchanged and the regression test
  passes.

## 2026-10-09 revision-5 Android profile build

- `CARGO_PROFILE_RELEASE_DEBUG=0 CARGO_INCREMENTAL=0 CARGO_BUILD_JOBS=1
  flutter build apk --profile --target-platform=android-arm64` passed in 459.4
  seconds and produced `app/build/app/outputs/flutter-apk/app-profile.apk`
  (102.9 MB). `apksigner verify --print-certs` passed; this profile build uses
  the Android debug certificate (SHA-256
  `c9df52b0ea4dc8c3a99a48bd0f561391699f2cc8bd55148e2387e19b63484dc9`). The
  APK SHA-256 is `3ee19875015710224aace9a445721706b9b7c091e429d25d8e131a0b53610b3b`.
- The S23 was updated with `adb install -r`; package metadata reports version
  `0.1.0` and last update time 16:37 UTC. The app was launched and confirmed as
  the resumed activity. This is an install/startup check, not interactive
  feature acceptance. The build logged the existing NDK 27.1 versus plugin
  NDK 28.2 mismatch warning, but completed successfully.

## 2026-10-09 revision-5 bridge revalidation

- `CARGO_PROFILE_DEV_DEBUG=0 CARGO_INCREMENTAL=0 CARGO_BUILD_JOBS=1 cargo
  test -p ink_bridge --lib` passed all 74 bridge tests on the current tree.
  This includes editable PSD candidate construction and independent Photoshop
  composite oracles, ABR report installation, comic export warnings, the
  pulled-string draft bridge, and adjustment/layer transaction coverage.
- The S23 remains on the installed revision-5 profile package and its main
  activity is resumed. The user-visible S Pen toolbar/layer tap and revision-5
  pressure checks are still awaiting response; no physical acceptance is
  inferred from the passing bridge tests.
- `CARGO_PROFILE_DEV_DEBUG=0 CARGO_INCREMENTAL=0 CARGO_BUILD_JOBS=1 flutter
  build ios --debug --no-codesign` passed against the current source and
  produced `app/build/ios/iphoneos/Runner.app` (252 MiB). This is device-target
  compilation only; no iOS device is attached for interactive acceptance.

## 2026-10-09 pressure response across built-in brushes

- All 20 built-in brush presets now have a pressure binding that changes a
  visible dab property. This includes Opaque Round, Marker, Ink Spatter, Ribbon
  Chain, both blenders, and both erasers. Changed preset revisions identify
  the new behavior; user-created and imported brushes continue to use their
  saved dynamics.
- The ABR conversion base now clears local preset dynamics before mapping
  source settings. Otherwise an imported ABR brush could inherit Ink's Opaque
  Round pressure behavior and report settings that were absent from the file.
- `CARGO_PROFILE_DEV_DEBUG=0 CARGO_INCREMENTAL=0 CARGO_BUILD_JOBS=1 cargo
  test -p ink-brush --lib` passed all 67 tests, including rendered-dab
  comparisons for all 20 built-ins and ABR pressure mapping. The focused
  Flutter brush library suite passed all 19 tests, including every in-memory
  built-in pressure projection. `cargo fmt -p ink-brush -- --check`, Dart
  formatting for the changed adapter, scoped whitespace checks, and
  `cargo clippy -p ink-brush --all-targets -- -D warnings` passed.
- A fresh Android arm64 profile APK built in 462.3 seconds, passed
  `apksigner verify --print-certs`, and was installed with `adb install -r` on
  the Galaxy S23 Ultra. Package `org.projectink.studio.debug` is resumed. APK
  SHA-256: `c6a40e7f0b76a1b93cb88e5cfb38f715d6e6ec27d02bc5bb62750b35e846b6b3`;
  the profile package uses the Android debug certificate, so it is a test
  build rather than the alpha-signed release artifact.
- The user already confirmed that S Pen toolbar taps work and Technical Pen
  light/firm pressure is visible on the prior revision-5 build. The newly
  installed build still needs an interactive comparison on the changed brush
  families; engine tests do not replace that device check.

## 2026-10-09 Ink Spatter and Ribbon Chain feedback

- The user reported Ink Spatter marks were too light and Ribbon Chain looked
  like other brushes. Ink Spatter revision 3 now uses 12 particles per dab
  instead of 18, 4 px particles instead of 3 px, 0.9 base opacity instead of
  0.65, and an 0.8 pressure-opacity amount instead of 0.45.
- Ribbon Chain revision 3 emits alternating slanted links at its configured
  repeat spacing and no longer adds a continuous Technical Pen companion. The
  old continuous-ribbon path remains for revision-2 saved presets.
- The Android arm64 profile APK rebuilt successfully in 69.5 seconds, passed
  signature verification, and was installed with `adb install -r` on the S23.
  Package `org.projectink.studio.debug` is resumed. APK SHA-256:
  `81cd1f59547c1d88a3af28ab2041438fcbc47a8d2ffe488d377c06f9c3343455`.
  This remains a debug-signed test build. Physical checks of the revised
  Ink Spatter darkness and Ribbon Chain appearance are still pending.
