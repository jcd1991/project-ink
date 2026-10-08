# Project Ink release readiness

This checklist defines the gates for a supported public release. For the
immediate experimental GitHub prerelease, use
[alpha-release-checklist.md](alpha-release-checklist.md). Its bounded launch
scope allows verified artifacts independently, without claiming full support.
A debug build or a passing unit suite is evidence for only the checks it
directly exercises.
Keep all six platforms currently named in the README visible in the matrix:
iPadOS, iOS, Android, macOS, Windows, and Linux. The first supported-release
candidates are macOS and iPadOS; they are candidates, not support claims. Do
not describe a platform as supported until its install, document, input,
offline, and recovery gates below pass. At present, none is
release-supported.

## Current working-tree verification (2026-10-07)

- `flutter analyze` and all 659 Flutter tests pass. The tests include refreshed
  layout goldens for the Simple/Studio control changes.
- `cargo test --workspace --all-targets --all-features`,
  `cargo clippy --workspace --all-targets --all-features -- -D warnings`, and
  `cargo fmt --all -- --check` pass.
- The current Android arm64 profile build produced
  `app/build/app/outputs/flutter-apk/app-profile.apk` (68.4 MB). Gradle reports
  that the app selects NDK 27.1 while several plugins request NDK 28.2; this
  build succeeded with that warning.
- Current macOS and iOS builds were not run: only 1.7 GiB was free, below the
  macOS alpha runner's 6 GiB build preflight. The earlier macOS debug build
  recorded in `focused-workspace-ui.md` is prior-build evidence, not a fresh
  build of this worktree.
- The 2026-10-07 Samsung phone session reported a visible sketch missing,
  History showing “No edits yet,” and restart failing to restore the sketch.
  No save was issued and the document state is unresolved. Do not close the
  document-recovery alpha gate based on that session.

## Gate 1: protect documents

- [x] Implement macOS window close and app quit dispatch through the shared
  Save, Discard, and Cancel flow. Cancel tells AppKit to keep the same window
  and document open; widget/channel coverage exercises each choice.
- [x] Verify the close button and Cmd-Q interactively in a fresh macOS app
  session, including the actual AppKit callbacks and a dirty named document.
  The 2026-10-03 real-app workflow also saved two distinct brush-family marks,
  reopened them in a fresh process, verified Undo/Redo, saved after Redo, and
  reopened both marks again. A subsequent malformed-package Open was rejected
  while the active canvas remained visible; the active package hash still
  matched its post-save reopen snapshot, and the damaged fixture hash was
  unchanged by the attempt. External manual records and hashes are under
  `ProjectInkAlphaValidation/manual-20261003/records/`.
- [ ] New, standalone Open, comic Open, and import replacement use the same
  decision. A cancelled picker does not prompt or change the current document.
- [x] Track edits since an explicit save separately from a pending recovery
  checkpoint. Clear explicit-save state only when the saved engine revision is
  still current.
- [x] Keep automatic checkpoints at the app recovery path, separate from the
  user's named project. Remove a recovery checkpoint only after an explicit
  save, a valid replacement, or a confirmed Discard; wait for an in-flight
  recovery write before removal.
- [x] Confirm Discard through a disposable profile: remove the recovery copy,
  leave the named project byte-identical, and launch the app to a clean state.
  Debug runs can isolate documents and diagnostic logs with
  `--dart-define=PROJECT_INK_TEST_DOCUMENTS_PATH=/absolute/test/path`; release
  builds ignore this override. The 2026-10-03 manual record now covers the
  real AppKit red-close and Cmd-Q branches, named-package hash, recovery
  removal, and a fresh-process reopen after Cmd-Q Discard.
- [x] Rust storage tests cover malformed metadata, corrupt journals, oversized
  tile payloads, injected failures after manifest/tiles/SQLite/history writes,
  and abrupt subprocess exit across writer and backup/publish boundaries.
  Recovery reads the last backup into a new destination while preserving the
  corrupt source.
- [x] Flutter autosave and document-action tests cover failed checkpoint retry,
  draining an in-flight recovery write, failed Save As preserving the active
  destination, and cancelled pickers. The canceled Open/Save As regression
  begins with a dirty named document and checks that the path and unsaved state
  survive unchanged. These use test engines/pickers rather than disk-backed
  provider fixtures.
- [ ] Exercise failed explicit saves, recovery writes, migrations, and provider
  write-back through the production Rust bridge using disk-backed fixtures.
  Storage subprocess tests do not simulate power loss or prove provider
  behavior.
- [x] Verify failed Save As, failed recovery writes, corrupt Open, and damaged
  brush import through the production Rust bridge with disk-backed fixtures.
  The tests preserve the active engine/recovery bytes, dirty state, source
  bytes, and destination blockers; provider write-back and migration failures
  remain open.
- [ ] Repeat failed/cancelled Save As, Open, comic Open, and import flows with
  disk-backed fixtures and compare source hashes before and after.
  One failed standalone Open was checked manually in the real macOS app on
  2026-10-03 using a malformed `.inkproj` fixture. It does not close the
  remaining Save As, cancelled Open, comic Open, or import cases.

## Gate 2: release hardening

- [x] Add and run storage-layer failure injection around manifest, SQLite,
  tiles, and history writes, plus subprocess abrupt-exit coverage at writer and
  atomic-publication boundaries.
- [x] Inject deterministic failures during repair-copy publication; verify the
  corrupt source is byte-identical, no partial destination is published, and
  temporary output is removed.
- [x] Verify legacy v2/v3 reads apply migration semantics in memory without
  rewriting package files, and unsupported future formats are rejected without
  changing any source bytes.
- [ ] Extend deterministic failure injection through app recovery checkpoints
  and provider write-back. Verify the original remains usable until a
  replacement is confirmed.
Existing code has component-level limits: `.inkproj` bounds manifest, SQLite,
compressed and decoded tile, history, layer, vector, resource, and comic-sidecar
sizes; brush archives cap compressed/expanded bytes, entries, compression ratio,
resource bytes, and image dimensions; comic metadata caps page and per-page
object counts; PSD input caps file bytes and each dimension. These checks are
spread across Rust crates and do not yet form one release import budget.

The PSD route now also enforces an aggregate projection before loading the full
file: encoded source bytes plus decoded RGBA bytes plus the initial raster-layer
copy must fit within 768 MiB. The limit is checked from the fixed-size PSD header
and repeated by the decoder before it allocates RGBA. This closes that route's
known 512 MiB source + 256 MiB decode + 256 MiB layer peak. Other route limits
remain component caps until the cross-route peak-memory audit below is complete.

| Import route | Current bounds | Remaining hardening |
| --- | --- | --- |
| `.inkproj` and studio pages | Manifest 256 KiB; SQLite 64 MiB; decoded tiles 768 MiB; decompressed history 128 MiB; vector/resource libraries 256 MiB each; brush library 64 MiB; comic sidecar 64 MiB. A shared conservative ledger caps accounted document data at 768 MiB and reserves decompression/parse working space below 900 MiB. Studio pages share the same ledger. Saves trim older undo/redo history only when that optional data prevents the project from fitting, and disclose the trim on reopen. | Validate the accounting against a generated maximum-valid fixture and measure peak memory on minimum-spec hardware. The 28 storage tests, including adaptive history-limit boundaries and a studio round-trip, pass. |
| Comic JSON | 64 MiB input; 512 pages; 128 me total page pixels; per-page caps include 256 panels, 512 balloons, 4,096 materials, 2,048 effect lines, 4,096 ink lines, and 256 tone layers; text fields are capped at 16 KiB. | Measure deserialization/render cost at maximum inputs and audit combined transient allocations. |
| Brush imports | Native `.inkbrush`/`.inkbrushpack`, Krita bundles, and external brush packages cap source at 256 MiB, expanded ZIP data at 512 MiB, entries at 256, and compression ratio at 100:1. Presets cap at 1 MiB, individual decoded resources at 96 MiB, and the unique resource library at 256 MiB. Multi-brush report copies now also cap at 256 MiB total. SUT reads a 256 MiB SQLite source and imports at most two decoded image assets. | Measure decompression/preview latency and aggregate parser buffers on the lowest supported device. |
| Image brush tip | 64 MiB source; checked dimensions before decode and enforced again by decoder width/height limits; at most 96 MiB decoded RGBA and decoder allocation limit. | The decoder allocation limit is best-effort for some codecs; measure parser and preview peaks on the lowest supported device. |
| MyPaint metadata | 1 MiB JSON source, bounded read and source hash; iterative metadata traversal stops beyond depth 64 or 100,000 visited nodes. | Measure parse latency at the limit. |
| PSD | 512 MiB source; 64 me pixels; 768 MiB source + decoded RGBA + initial layer projection. | Measure peak memory on minimum-spec hardware, including parser/export working buffers. |

None of these import APIs currently exposes cooperative cancellation or a
wall-clock deadline. The size and object caps bound work, but do not prove a
responsive import time on minimum-spec hardware. Keep the time/cancellation gate
open until representative device measurements and an interruptible workflow
exist.

- [ ] Define cancellation/time budgets for expensive imports and validate
  aggregate peak memory across all routes on minimum-spec hardware. The static
  source audit below records current byte and structure bounds; it does not
  establish an end-to-end memory or responsiveness budget.
- [x] Limit comic page specs to 128 me total pixels across the project. The
  import and page-add tests verify just-over-limit rejection before page
  snapshots load and without partially adding a page.
- [x] Reject PSD imports above 64 me pixels before allocating decoded RGBA
  output and cap projected source + decode + initial-layer memory at 768 MiB;
  header validation runs before the full file read.
- [x] Enforce MyPaint JSON and image-tip byte limits during reads and source
  hashing, not only through metadata preflight. Bounded read/hash regressions
  and the full 38-test `ink-brush` suite pass. Image decoding also receives
  the validated dimensions and 96 MiB allocation limit; that decoder limit is
  best-effort for some codecs.
- [x] Review static file-size, dimension, object-count, archive-entry,
  decompressed-byte, and decoded-resource bounds for native projects, studio
  pages, comic JSON, PSD, external brush packages, images, and MyPaint files;
  the route caps and remaining measurements are recorded in the table above.
- [ ] Add cooperative cancellation and processing-time limits to expensive
  imports; the current import APIs do not accept cancellation or deadlines.
- [ ] Review accessibility labels, keyboard navigation, contrast, text scale,
  touch target sizes, and localized layout in every release surface.
- [x] Record the current locale scope: Project Ink's app-specific interface
  copy is English only; no translated catalogs are shipped. This is a scope
  statement, not a claim of localization completeness.
- [x] Set English as the app's only supported locale and verify an unsupported
  Spanish system locale falls back to English in
  `project_ink_app_test.dart`.
- [ ] Review native file-picker and operating-system text under non-English
  system locales before adding translated app interface copy.
- [ ] Produce reproducible signed packages from tagged source for each supported
  platform. Record toolchain, signing identity, artifact hashes, and source
  revision; keep secrets out of logs.
- [ ] Verify install, drawing, save, reopen, export, and update paths with the
  network disabled. Platform-specific account, signing, and file-provider
  setup must be documented where required.

## Gate 3: supported platform acceptance

CI debug builds are compile evidence only. Keep a per-platform record with the
release artifact hash, OS/device version, install method, input device, storage
provider, test date, and failures.

| Platform | First release candidate? | Required acceptance before claiming support |
| --- | --- | --- |
| iPadOS | Yes | Signed install; Pencil pressure/tilt/eraser; touch gestures; long strokes; memory; Files open/save; recovery and offline use. |
| iOS | No | Signed install; touch and supported stylus behavior; Files open/save; recovery, export, and offline use. |
| Android | No | Signed install; S Pen/touch behavior; SAF open/save; recovery, export, and offline use across a supported tablet and phone. |
| macOS | Yes | Signed install; mouse and tablet input; close/quit prompt; file-provider flow; recovery, export, and offline use. |
| Windows | No | Signed install; mouse and tablet input; provider/file flows; recovery, export, and offline use on a hosted or physical Windows system. |
| Linux | No | Reproducible package; mouse and tablet input; file flows; recovery, export, and offline use on a documented distribution. |

The current phase checklist also calls for Wacom, Huion, and XP-Pen desktop
coverage; hosted Windows/Linux installation; and a comic project round trip
across platforms. Track each device and OS result separately from simulator,
emulator, CI, and macOS-only results.

## Gate 4: core workflow evidence

- [x] Define the macOS/iPadOS candidate scope, required user journeys, and
  parity non-goals in `first-release-scope.md`. The document is an acceptance
  contract, not evidence that these journeys or platforms have passed.

Use disposable, checked-in fixtures and record exact artifact hashes and
resulting project revisions.

- [x] New canvas → draw with at least two brush families → save → close → fresh
  process reopen → undo → redo → save and reopen again.
- [ ] Edit, reorder, hide, group, mask, and delete layers; exercise primary
  targeting, locks, rollback, undo/redo, persistence, and reopen.
  - [x] Basic raster path: create/select, rename, reorder, hide/show, opacity,
    selected-layer drawing, delete/undo, save, and reopen (macOS integration
    evidence dated 2026-10-08 below).
  - [x] Engine lifecycle regression covers group lock inheritance, alpha lock,
    attached masks, clipping, undo/redo, and save/reopen (2026-10-08).
  - [ ] Physical macOS/Android combined layer acceptance and rollback-failure
    handling remain open.
- [ ] Edit a custom brush, preview it, cancel and commit drafts, export/import
  it, select it, and prove the committed settings change rendered output.
  - [x] Custom-brush draft edit, preview, discard, save, rendered-output change,
    and persisted settings (macOS integration evidence dated 2026-10-08 below).
  - [ ] Custom-brush package export/import round-trip remains open.
- [ ] Verify adjustment visibility, order, parameters, undo/redo, save/reopen,
  and deterministic export for the supported adjustment set.
- [x] Create and edit a multi-page comic with panels and dialogue, save/reopen,
  then produce and inspect one useful export with references intact.
  - [x] Mac Flutter/Rust integration `app/integration_test/comic_artist_journey_test.dart`
    created an original two-page, four-panel-per-page comic with panel-linked
    dialogue and editable stick-figure ink, saved `.inkproj`, closed and
    reopened it, then exported both pages. Reopen retained all eight panels,
    eight dialogue balloons, panel links, text, and page artwork. The
    self-contained SVGs were checked for embedded PNG artwork, panel and
    balloon IDs, and dialogue; the 2400×1800 PNG artwork exports were opened
    and visually checked. The story is an original sparse stick-figure comic,
    not a copy of a published strip.
  - [x] `flutter test test/comic_workspace_search_test.dart` covers the visible
    2/3/4-panel presets and adding a speech balloon to its selected panel.
    Those UI controls are widget-tested; the full journey drives the Rust-backed
    controller and document APIs and does not simulate canvas pointer input.
  - [x] Preserved local fixture: `artifacts/comic-artist-journey/`. Both
    2400×1800 page documents are revision 11. SHA-256: page-0001.png
    `5208c12d50d7bce32312a402d31845292ef499b606d2d3fe154f9229963d81d7`,
    page-0001.svg
    `a6eeef670d90fb1a8b985a8e1643f6556c86e81ac4c42c21fbac788131d2f9c1`,
    page-0002.png
    `5208c12d50d7bce32312a402d31845292ef499b606d2d3fe154f9229963d81d7`,
    page-0002.svg
    `fe94da920f2688bfeb555d212ff84d0840d9fed1d9d4766a9dc6c008de2c2832`.
    The fixture is ignored local output; it is not part of the source commit.
- [ ] Verify live preview-to-committed tile equivalence, long-stroke undo
  grouping, and memory/performance limits on physical pen devices.
- [x] Rust engine regression preserves an available Redo when a touch stroke
  begins and is canceled; save/reopen and the three-finger gesture route are
  covered by automated tests (2026-10-08).
- [x] Retest three-finger Redo on the installed Galaxy S23 profile build; the
  user confirmed that the mark returned after the three-finger gesture. The
  app-private recovery checkpoint was then reopened after a force-stop and the
  marks were visible again (2026-10-08). This verifies recovery reopen, not a
  named-project save or Redo after reopen; both remain open.
- [ ] Verify active-layer targeting and long-stroke behavior with real S Pen
  input on the Galaxy S23. The installed app is staged on a blank layer marked
  Active; physical input confirmation is pending (2026-10-08).

Automated engine tests, Flutter tests, desktop mouse checks, and stylus/print
acceptance are separate evidence classes. Do not substitute one for another.

## Gate 5: public release path

The local iOS acceptance scheme and runner are documented in
specifications/ios-acceptance.md. It supports simulator and connected-device
Flutter/Rust integration tests, native packet tests, process relaunch, native
project-picker entry, and a guided local Pencil session. The acceptance app
uses a separate bundle and data container. The runner has been added but has
completed both Flutter/Rust integration targets on an iPad simulator for the
recorded working-tree fingerprint, but the native XCUITest stage did not
complete and the run did not pass as a whole. That fingerprint differs from
the current working tree, so rerun the suite after active canvas changes
stabilize. Physical-device automation and Pencil, latency, and process-memory
evidence remain separate hardware gates.

- [ ] Confirm the recommended channel for each first-release candidate before
  configuring signing: signed and notarized macOS direct download, plus an
  iPadOS TestFlight beta followed by an App Store release if the beta passes.
  This is the current recommendation, not a configured or approved channel.
- [ ] Choose and tag a version from source; update the application version,
  changelog, release notes, and compatibility statement together.
- [x] Add a fail-closed preflight at `scripts/release_preflight.sh` requiring
  a matching `vMAJOR.MINOR.PATCH` tag, Flutter app version, changelog heading,
  tagged `HEAD`, and clean checkout. `.github/workflows/release-preflight.yml`
  invokes it on version-tag pushes; no tagged release run has been verified.
- [x] Add `scripts/release_checksums.sh` to create and verify a SHA-256 manifest
  for staged artifacts. Keep signed-package and downloaded-release validation
  open until actual release artifacts exist.
- [ ] Publish platform-specific signed packages with SHA-256 checksums and a
  source revision link. A release job must not run for untagged commits.
- [ ] Write install, update, uninstall, offline, recovery, and known-limitations
  instructions for each supported platform.
- [x] Add contributor setup, code review, test, and pull-request guidance in
  `CONTRIBUTING.md`.
- [ ] Add a private security-reporting route and a response policy.
- [x] Include the full MPL-2.0 text in the repository and make source/license
  access clear in the repository documentation. Executable distributions still
  need a source link and bundled license access.
- [ ] Run the release workflow from a clean checkout and verify every published
  checksum against the downloaded artifact.

## Current evidence snapshot

- **macOS illustration alpha workflow (2026-10-08).**
  `flutter test --no-pub integration_test/illustration_alpha_workflow_test.dart
  -d macos` passed 1/1 with the production Rust bridge and the desktop-dock
  canvas. The run set `PROJECT_INK_TEST_DOCUMENTS_PATH` to
  `Library/Containers/org.projectink.studio/Data/Documents/ProjectInkAlphaValidation/manual-20261008-02`
  and `PROJECT_INK_PRESERVE_ALPHA_FIXTURES=true`. The scenario created and
  selected raster layers, renamed and reordered the
  target, hid/showed it, changed opacity, drew only on that selected layer,
  deleted a spare layer and restored it with Undo, then saved and reopened the
  project in a new Rust engine in the same test process. Two built-in brush
  families drew marks after UI size changes; the RGB picker UI set red and blue
  colors, and pixel digests confirmed each brush changed the target layer only.
  A duplicated custom brush was previewed, edited and discarded (size and preview
  unchanged), then edited and saved (size and rendered preview changed); its
  settings matched after reopen. PNG export from the reopened project decoded to
  512×512, had alpha 0 at the untouched page corner, and contained 2,797 red and
  2,935 blue pixels. This is an automated macOS integration run with synthetic
  Flutter pointer input, not a signed-install or physical mouse/tablet session,
  and reopen was not a fresh app-process launch. The preserved disposable
  artifact is under
  `Library/Containers/org.projectink.studio/Data/Documents/ProjectInkAlphaValidation/manual-20261008-02/project-ink-illustration-alpha-Tm0p5S/`;
  its manifest revision is 218. SHA-256 records:

  Flutter printed `Failed to foreground app; open returned 1` during startup;
  the integration case itself completed successfully. This run is not manual
  installed-app signoff.

  | Artifact | SHA-256 |
  | --- | --- |
  | `illustration.inkproj/manifest.json` | `5cf00d60f05eb6d21354a8a2c3ac75425c8704e84ba97879032ad6a3aabf06eb` |
  | `illustration.inkproj/document.sqlite` | `3b15990713c7aa15f2d9af9c3cb56fc90c18ef1b50e73b218b1f65c0fa910243` |
  | `illustration.inkproj/history.json.zst` | `2ba40f31cafcdcaaa8005d6fbe6a597088892fa0953aeab3d522ec74c95dbd94` |
  | `illustration.inkproj/vectors.json.zst` | `0402abf9f915f3ae8fb67f6a26454e8fb08de085cf8f2d7988330f0e812fa66c` |
  | `illustration.inkproj/brushes.json.zst` | `5f9d36951ebb751ee2f681689c01e5d2b3c339df88902701c4e086e6a086f703` |
  | `illustration.inkproj/tiles/.../0_0.tile.zst` | `986ef971bcfa7da5e0918250b8758684a54e760bf8f0a7eed5527a4b93aa87ac` |
  | `illustration.inkproj/tiles/.../0_1.tile.zst` | `16508139c6d82f0de00c1d342fba76e2c6e231788b2471e9ab1d1d1775353f95` |
  | `illustration.inkproj/tiles/.../1_0.tile.zst` | `c9b42762ad400ec0b75c1e25170c9986afad47a43429fff05f754b817abbc8ca` |
  | `illustration.inkproj/tiles/.../1_1.tile.zst` | `31442c6b584eaefa8ba2f142ef547fd4dd926ace6d478c0d48fe49a43688efb1` |
  | `illustration.png` | `d58a0c0ed6f2a0757e9b26d46205b7c7663eb3816f85fa38122a2ada319ada2c` |
- **macOS acceptance refresh (2026-10-03, 17:00–17:25 EDT).** A fresh run of
  `app/tool/run_macos_alpha_checks.sh --workflows-only` passed Flutter analysis,
  all 597 Flutter tests, seven Rust-backed disk journeys (layer round-trip,
  custom-brush edit/import and damaged-import preservation, comic save/reopen/
  export, draw/save/reopen/undo/redo, corrupt Open, failed Save, and failed
  recovery write), and the macOS app build. The run summary and per-journey
  logs are in `app/build/macos-alpha-checks/`; its isolated document root is
  `ProjectInkAlphaValidation/20261003-170129-98148`.
- The real-app manual record
  `ProjectInkAlphaValidation/manual-xctest-20261003/records/macos-manual-safety.txt`
  verifies red-close and Cmd-Q Save, Discard, and Cancel, package hashes,
  recovery behavior, and save/reopen/undo/redo. The focused XCUITest still
  fails its app-window automation gate (`mainWindow.isEnabled == false`), so
  automated AppKit acceptance remains open.
- The native live-texture integration test now proves Rust surface creation,
  Metal texture registration, dab rendering, frame notification, and Rust
  acknowledgment, and records two raster pixel-buffer copies. Native Dispose
  now returns after requesting asynchronous unregistration while retaining the
  pixel buffer until Flutter's raster callback, so a missing callback cannot
  block canvas cleanup. The focused test still fails after ten raster frames:
  the texture remains in `retiring` state and the callback was not received.
  Creation stays bounded and the controller falls back to CPU preview. The
  stage log is in
  `app/build/macos-alpha-checks/macos_native_live_texture.log`; native texture
  retirement is not accepted.
- The connected iPad Pro 11-inch (3rd generation) preflight reports 11.2 GiB
  free against the runner's 18 GiB device-run threshold. No current-revision
  build or install was started; Apple Pencil, recovery, offline, and physical
  document acceptance remain open.

- This validation pass fixed `.inkproj` layer-label persistence. New saves use
  the storage reader's canonical four-channel array, while the reader also
  accepts older object-shaped labels so projects saved before the fix remain
  openable. The focused storage compatibility and engine layer-presentation
  save/reopen tests pass.
- The Flutter analysis reports no issues and the complete unit/widget suite
  passes all 592 tests. Isolated macOS Rust-bridge journeys pass for layer
  presentation with undo/redo, custom brush edit/export/import, damaged brush
  source preservation, multi-page comic save/reopen/export, and pixel
  draw/save/reopen/undo/redo with corrupt Open and recovery preservation. App
  shell checks also pass for failed Save As/corrupt Open and a failed recovery
  write keeping the dirty Rust document. These are same-process debug
  integration runs; fresh-process, provider, and device acceptance remain
  open.
- `app/tool/run_macos_alpha_checks.sh` now offers preflight, unit-only, full
  workflow, and separate native-live-texture modes. Preflight found 1,302 MiB
  free, below the runner's 6 GiB rebuild threshold, so full mode correctly
  stopped before starting a rebuild. The native texture integration test now
  follows the Rust/Metal/Flutter device-handle handoff, but surface creation
  did not return in this integration-test session and the run was stopped. Do
  not count native texture acceptance as passed.
- The attached iPad Pro 11-inch (3rd generation, iOS 27.0) is visible to
  Flutter, but this pass did not deploy or run the updated app on it. Direct
  Apple Pencil pressure, tilt, hover, latency, long-stroke recovery, and
  physical document workflows remain open.
- `specifications/macos-alpha-acceptance.md` now records the isolated-profile
  manual matrix for real AppKit red-close and Cmd-Q Save/Discard/Cancel, source
  hashes, damaged Open/Save/import, and recovery outcomes. Those AppKit actions
  were not exercised in this pass.

- `CARGO_PROFILE_DEV_DEBUG=0 CARGO_INCREMENTAL=0 flutter run -d macos --debug
  --dart-define=PROJECT_INK_TEST_DOCUMENTS_PATH=<sandbox-temp-path>` built and
  launched the current macOS debug app under a temporary acceptance bundle ID.
  Startup logs confirmed that recovery and diagnostics used the isolated
  app-container path. The repository bundle ID was restored afterward. An
  initial `/tmp` override was rejected by the macOS sandbox and was not used
  for document edits.

- Latest macOS validation attempt (2026-10-03): Flutter analysis passed and all
  596 unit/widget tests passed. Six Rust-backed on-disk workflows passed:
  layer save/reopen and undo/redo, custom brush edit/export/import, damaged
  brush source preservation, multi-page comic save/reopen/export, pixel
  save/reopen/undo/redo with corrupt Open recovery, and failed recovery-write
  preservation. The app-shell failed Save As/corrupt Open integration initially
  hit an unregistered test text-input channel; after removing the unnecessary
  `hide()` call, that focused integration passed. The normal macOS debug app
  rebuilt successfully. The new Xcode UI-test bundle compiled, but macOS timed
  out while enabling UI automation before executing any of its six close/quit
  cases. Its retained result bundle is
  `app/build/macos-alpha-checks/NativeDocumentSafety-20261003-142002-8978.xcresult`.
  Therefore the overall runner exits nonzero and the automated UI suite has no
  case results. The separate visible-app results are recorded below. Check
  Gate 1 again after UI automation is available, then repeat the visual manual
  matrix in `macos-alpha-acceptance.md`. Fresh-process save/reopen and
  undo/redo have since been observed for one brush family; the full two-brush
  workflow, provider flows, offline acceptance, and physical iPad/Pencil
  evidence remain open.
- A separate visible-app pass used the isolated profile recorded in
  `Library/Containers/org.projectink.studio/Data/Documents/ProjectInkAlphaValidation/manual-20261003/records/partial-native-close-quit.txt`.
  Red-close Cancel, Discard, and Save behaved as expected for the visible
  document, saved-package hashes, and recovery copy. Cmd-Q Cancel kept the
  dirty project open. Cmd-Q Save initially persisted the mark and removed
  recovery but left the window visible. The native callback was fixed to reply
  synchronously when already on the main thread; a visible rerun then saved,
  removed recovery, and quit the app. A separate run against the current
  Flutter-built app confirmed Cmd-Q Discard exits, preserves the named package
  byte-for-byte, removes recovery, and permits a fresh-process open of the
  unchanged project. An older Xcode acceptance-derived app was mistakenly
  opened during an intervening attempt; that run is excluded in the evidence
  record. In the latest red-close Save and Discard reruns, the app process
  stopped after its window closed.
- Focused autosave, document-action, and app-session tests cover separate
  explicit-save state, the recovery path, in-flight recovery-write draining,
  and Cancel/Discard for New/Open.
- The document-replacement prompt now states that Discard removes the recovery
  copy and edits since the last explicit save while leaving the last saved
  project unchanged. The focused Open/Discard widget test passes; this does not
  close the interactive close/quit or disk-backed replacement gates.
- A disk-backed app-session widget fixture now writes a recovery sentinel,
  simulates a corrupt Open, and verifies the existing engine and recovery bytes
  survive. Another regression makes recovery cleanup fail after a valid
  replacement has been opened; it verifies the active engine and checkpoint
  bytes remain, and the unused candidate engine is closed. The focused
  `project_ink_app_test.dart` suite passes all 13 tests, including the
  English-only locale fallback regression. Openers and cleanup failures are
  injected, so these are not production Rust bridge or provider evidence.
- A UI interaction regression starts with a dirty recovery checkpoint, chooses
  Discard for Open, rejects a corrupt replacement, then verifies the same
  engine and checkpoint bytes remain and the error says the current project is
  still open. This proves the combined Flutter replacement path with a disk
  sentinel; it does not exercise production bridge deserialization.
- Recovery-directory deletion now uses `RecoveryCheckpointStore`. Its real
  filesystem tests confirm the recovery directory is removed while a sibling
  named-project file remains byte-identical, and missing/empty paths are
  harmless. These exercise the deletion helper; interactive Discard and app
  provider persistence remain open.
- A regression injects recovery-checkpoint deletion failure after Discard. It
  verifies native close is canceled, a fresh autosave coordinator is restored,
  and another recovery save succeeds. The focused app-session suite passes;
  this remains widget/channel evidence, not a live AppKit close test.
- A focused widget test now injects provider write-back failure after the local
  save and confirms the UI does not report success or adopt the staged path.
  The document-action suite now passes all 30 tests. Regressions cover revision
  changes during Save keeping native close canceled and PSD replacement Cancel
  preserving the current document while Discard proceeds. This exercises the
  Flutter failure boundary, not provider storage itself.
- `ink-storage` tests passed for injected checkpoint failures, abrupt process
  exits at save boundaries, recovery from a corrupt source while preserving
  that source, and corrupt command-journal rejection. These are storage-layer
  results; app/bridge failures, actual power loss, and provider write-back are
  still open.
- `cargo test -p ink-engine --lib` passed all 118 tests, including save/reopen,
  undo/redo, long cross-tile strokes, brush edit/export/import/reuse, layer
  rollback, mask ownership, and compositing cases. This is engine evidence;
  fresh-process UI workflows and physical input acceptance remain open.
- `cargo test -p ink-comic --lib` passed all 16 tests, including the new
  aggregate page-pixel rejection, page-add rollback, eight-page fixture
  round-trip, SVG export, and print-preview coverage. Cross-platform comic
  production acceptance remains open.
- `cargo test -p ink-export --lib psd_` passed the PSD pixel-boundary and
  aggregate working-set tests. The bridge sparse-file header test now also
  passes, rejecting an oversized projected working set before reading the
  remaining payload. Both are targeted host tests, not minimum-device memory
  measurements.
- `CARGO_PROFILE_TEST_DEBUG=0 CARGO_INCREMENTAL=0 cargo test -p ink-storage
  --lib` passed all 28 tests, including aggregate project-memory boundaries,
  studio round-trip, migrations, tile limits, corrupt-manifest handling, and
  subprocess interruption. `autosave_coordinator_test.dart` passed 7 tests,
  `canvas_document_actions_test.dart` passed 30 tests, and
  `project_ink_app_test.dart` passed 13 tests. They cover Save/Discard/Cancel,
  failed saves, canceled pickers, recovery-write draining, failed recovery
  deletion, autosave restoration, and canceling Cmd-Q when the requested Save
  fails. These are host/widget/channel tests;
  they do not exercise AppKit's real quit callback. Production-provider
  persistence is not covered by those widget fakes.
- `CARGO_PROFILE_TEST_DEBUG=0 CARGO_INCREMENTAL=0 cargo test -p ink_bridge
  --lib` passed all 54 bridge tests, including attached-mask ownership,
  undoable layer mutations, comic export/reopen workflows, PSD header rejection,
  and the unified studio project round-trip. This validates the Rust/FRB
  boundary on the host, not app file-provider behavior or tablet input.
- Brush-tip image decoding now applies expected image dimensions and a 96 MiB
  allocation limit before decode. The `ink-brush` suite passes all 38 tests,
  including a regression where decoder dimensions exceed the validated import
  dimensions; targeted Clippy passes with warnings denied. Decoder allocation
  limits are best-effort for some codecs, so device peak-memory acceptance
  remains open.
- Storage repair-copy failpoint coverage now exercises failures after manifest,
  tiles, SQLite, and history writes; all failures preserve the corrupt source
  bytes, publish no recovered destination, and remove temporary output.
- Legacy v2/v3 migration reads now compare every package file before and after
  loading; unsupported-version rejection receives the same byte-preservation
  check. This matches the reader-only migration design and does not simulate a
  write-side migration because readers do not rewrite source projects.
- The static import audit records component-level caps for storage, studio
  projects, comic metadata, PSD, native/external brush packages, and image tips.
  PSD rejects over 64 me pixels before RGBA allocation; comic projects reject
  more than 128 me total page pixels. Cross-route peak-memory measurements and
  cooperative cancellation/time budgets remain open.
- `cargo fmt --all -- --check`,
  `CARGO_PROFILE_DEV_DEBUG=0 CARGO_INCREMENTAL=0 cargo clippy -p ink-storage
  --all-targets -- -D warnings`, and `flutter analyze --no-pub` pass.
- The first full Flutter run in this slice reported 269 passing and 128 failing
  tests before it stalled in a touch-input test. Investigation found layer
  loading sequenced behind brush preference restoration and widget fixtures
  without isolated preference/native-channel setup. Layer projection now
  starts independently at canvas startup; an unavailable preference store
  cannot prevent its authoritative snapshot from loading. Tests now isolate
  those platform services. The full Flutter widget suite passes all 423 tests
  with file concurrency set to one, including 118 editor-layout scenarios and
  the two recovery-store filesystem tests; the focused
  document, touch, pointer, and focus suites pass as well.
- A macOS debug integration test now drives a touch stroke through the real
  canvas and Rust bridge, saves an `.inkproj`, closes and reopens the engine,
  verifies committed pixels, checks Undo/Redo against the empty and drawn
  states, then saves and reopens again. It also writes a separate recovery
  project, rejects a corrupt `manifest.json` through `FrbEngineApi.open`, and
  verifies the old engine, recovery pixels, and corrupt source bytes remain
  intact. A second app-shell integration case uses the production Rust engine
  and `ProjectInkApp` recovery coordinator: it checkpoints a Rust layer edit,
  rejects a corrupt replacement, then confirms that the same engine and
  autosave coordinator remain active and the recovery file reopens with that
  layer. Both tests pass with
  `CARGO_PROFILE_DEV_DEBUG=0 CARGO_INCREMENTAL=0 flutter test
  integration_test/release_document_round_trip_test.dart -d macos --no-pub`.
  These are same-process Rust bridge/debug integration tests. The app-shell
  case uses a platform override and does not exercise AppKit, native file
  pickers, a fresh app-process reopen, signed install, provider write-back, or
  offline acceptance.
- The reviewed desktop, 200% high-contrast tablet, and populated Simple/Studio
  Layers images now match their updated golden snapshots. These visual tests
  prove widget composition only; they are not screenshots of an installed Mac
  app or physical tablet.
- The layer reorder handle now exposes a named semantics target and drag hint;
  `layer_panel_gesture_test.dart` passes all 58 tests, including the new
  semantics assertion. This is one control-level fix, not a complete
  accessibility or screen-reader review of the editor.
- `ProjectInkApp` has no app-specific localization delegates or translated
  catalogs. The first-candidate UI scope is currently English only; platform
  locale fallback and complete copy review remain open.
- `CARGO_PROFILE_DEV_DEBUG=0 CARGO_INCREMENTAL=0 flutter build macos --debug`
  completed successfully on the local Apple Silicon Mac. Xcode emitted an
  upstream `file_selector_macos` warning that `allowedFileTypes` is deprecated
  on macOS 12 and newer; it did not fail the build.
- The built `org.projectink.studio` app launched and exposed the Layers panel
  with a group, paint layers, a mask, reorder handles, and lock/visibility
  controls. This was an unisolated recovery-backed debug session with no useful
  artwork in the canvas; the screenshot is a UI smoke check, not a populated
  layer acceptance screenshot. One layer name was visibly ellipsized. Do not
  count this run as layer parity or isolated-profile verification.
- Cmd-Q reached the real AppKit termination callback and displayed the dirty
  recovery prompt. Cancel returned to the same recovered document; the app
  process and recovery state remain open to avoid discarding it. This verifies
  the interactive cancel branch only. Save and Discard through AppKit, window
  close, and the separate isolated-profile run remain open.
- The screen and process inventory resolved the app as `org.projectink.studio`.
  Earlier reports of a conflicting bundle identifier are superseded by this
  observation. The prior user-authorized 2.0 GiB intermediates removal left
  3.0 GiB free immediately before this build; no cleanup was needed for it.
- `app/pubspec.yaml` remains `0.1.0+1`; `.github/workflows/` contains regular
  CI and a tagged metadata preflight, but no signed packaging/release workflow.
  `git remote -v` returns no destination. Reproducible signed artifacts,
  checksums, release publication, and their clean-checkout rehearsal therefore
  remain open. Do not infer a publication target from package metadata.
- `scripts/release_preflight.sh` now validates the tag syntax, tag-to-HEAD
  identity, app version, changelog heading, and clean checkout before release.
  `bash -n` passes; an isolated tagged fixture passes, and malformed-tag,
  dirty-checkout, and tag-to-HEAD mismatch fixtures are rejected. The
  version-tag preflight workflow is configured but has not been run on a real
  release tag. Signed packaging remains gated on distribution channels and
  signing setup.
- `scripts/release_checksums.sh` passes a local Bash 3.2 fixture with
  space-containing macOS/iPadOS artifact names. Verification accepts the
  original bytes and rejects a modified artifact. No real signed packages have
  been generated or published.
- `CONTRIBUTING.md` now documents the maintainer sequence for app version,
  changelog entry, clean tagged preflight, and staged package checksums. It
  explicitly says there is no signed package publisher yet; platform install
  and update instructions remain open until actual channels and packages exist.
- `first-release-scope.md` now states the intended candidate platforms, core
  release journeys, and non-goals. Its claims stay conditional on the open
  acceptance gates.
- macOS window close and `applicationShouldTerminate` are wired to the same
  Flutter Save/Discard/Cancel flow. Cmd-Q routes through the native termination
  path. If the Flutter close channel is unavailable, AppKit keeps the window
  open and clears its pending-close latch so a later request can retry. The
  focused Flutter document-action suite passes all 30 tests, including native
  close/quit Save, Discard, and Cancel decisions; these tests mock the native
  channel. The live Cmd-Q Cancel branch now confirms the AppKit callback and
  prompt are connected. Save/Discard outcomes, window close, disk-backed named
  document behavior, and isolated-profile acceptance remain open; Gate 1
  remains open.
- The current CI workflow is not the tagged, signed release workflow required
  by Gate 5. Physical-device, hosted Windows/Linux, print/export, and
  cross-platform acceptance remain open.
- Contributor guidance, an initial changelog, and the complete MPL-2.0 text are
  now present. The security document is a placeholder policy until maintainers
  configure and verify a private report route; it does not claim one is live.
- On 2026-10-02, the physical iPad Pro 11-inch (3rd generation, iPadOS 27.0)
  brush-gallery integration run passed. It transferred and imported one SUT and
  one Procreate brush as guided recreations; simulated touch-pressure strokes
  for both imported brushes changed committed Rust tiles. The captured gallery
  is in the local run artifact at
  `app/build/brush-device-gallery/run-20261003T032130Z-82956/brush-device-gallery.png`.
  This does not establish Apple Pencil pressure/tilt behavior, full document
  acceptance, or a release install. The runner reported `Failed to stop app`
  after passing, so its cleanup is not claimed complete.
- The static import audit found that `.inkbrushpack` import cloned referenced
  resource bytes into each brush report without bounding the aggregate cloned
  payload. Import now rejects report resources above 256 MiB before cloning
  them. The focused boundary test and all 38 `ink-brush` unit tests pass;
  targeted Clippy passes with warnings denied. Device peak-memory and
  import-duration budgets remain open.
- The focused `project_ink_app_test.dart` English-fallback case passes. The app now
  declares English as its only supported locale and resolves an unsupported
  Spanish system locale to English; native picker localization and broader
  accessibility/layout review remain open.
- Current manual macOS reruns used the Flutter-built app, with its executable
  path checked before interaction. All six dirty-document choices now have
  visible real-AppKit evidence across the recorded sessions. The current
  red-close Save and Discard runs both stopped the process; Save changed the
  named package and removed recovery, while Discard preserved its exact package
  hash and removed recovery. Cmd-Q Discard also preserved the package, exited,
  and allowed a fresh-process reopen without the discarded mark. The exact
  package hash records and binary identity note are in the manual acceptance
  record. The full real-app workflow is also complete: after saving the initial
  Pen/Technical Pen Ink stroke, selected HB Sketch Pencil from the Sketch
  family, drew and saved a visibly thinner stroke, then closed and reopened in
  a fresh process. Undo removed only the Sketch stroke; Redo restored it. A
  save after Redo survived another close and fresh-process reopen, with the
  package hash unchanged across that final reopen. The detailed hash records
  are listed in the manual record. XCUITest still timed out before executing
  cases.
- Real macOS layer presentation workflow: created a second paint layer in the
  app, renamed it `Highlights`, drew on it, hid it, and saved the named project.
  After opening that project in a fresh app session, the Layers panel showed
  `Highlights` hidden and `Ink` visible. All six package file hashes matched
  the post-save snapshot after reopen. The manual record is
  `macos-layer-fresh-reopen.txt`. A focused widget regression test also
  confirms that layer rename reloads the Rust-backed layer projection; this
  fixed both layer and comic callbacks that had been wired to brush projection
  loading. This run does not establish comic UI acceptance.
- Shutdown preservation check: the Flutter-built macOS app restored an
  unnamed blank-document recovery checkpoint on launch. Cmd-Q displayed the
  unsaved prompt; choosing Save, naming the project, and confirming the native
  project folder saved the document and exited the app. Package hashes are in
  `alpha-shutdown-preserved.sha256`; no Discard action was used.
- Added `app/tool/run_macos_alpha_checks.sh --workflows-only` to rerun analysis,
  Flutter tests, disk-backed Rust bridge journeys, and the macOS app build
  without entering the OS UI automation stage. It reports explicitly that the
  native AppKit UI suite was not run; `--full` remains the full automated gate.
- Re-ran `app/tool/run_macos_alpha_checks.sh --workflows-only` on commit
  `881638448c398fd53b571a4d3336d41fd481391a`: Flutter analysis passed, all
  596 unit/widget tests passed, all seven disk-backed layer/brush/comic/drawing
  and failure-preservation journeys passed, and the macOS debug app built.
  The runner exited successfully and records each result in
  `app/build/macos-alpha-checks/summary.txt`. As designed, this run skipped
  XCUITest; it does not replace the separate visible AppKit evidence.
- Current working-tree macOS unit gate: `app/tool/run_macos_alpha_checks.sh
  --unit-only` passed Flutter analysis and all 597 unit/widget tests. Native
  AppKit snapshot collection now throws on package enumeration or file-read
  errors, so a missing snapshot cannot satisfy the Save-changed assertion.
  Added `--appkit-only` to rerun the AppKit exit matrix without repeating the
  Rust-backed journeys. Shell syntax and Swift parsing passed. The native test
  target was not built or run: disk availability during this gate was 2.7 GiB,
  below the runner's 6 GiB build threshold. The runner's full preflight must
  pass before attempting it.
- After the user freed space, `app/tool/run_macos_alpha_checks.sh
  --appkit-only` passed its disk preflight (17,880 MiB) and built/launched the
  native test target. All six XCUITests then stopped at the shared startup
  assertion because `drawing-canvas` was absent from the accessibility tree;
  the captured hierarchy showed a disabled `project_ink` window and no Flutter
  controls. No Save/Discard/Cancel behavior was exercised. Result bundle:
  `app/build/macos-alpha-checks/NativeDocumentSafety-20261003-162729-69510.xcresult`.
  The harness now activates the app and checks the native window's enabled
  state before waiting for canvas semantics. A focused rerun failed that new
  check (`mainWindow.isEnabled == false`), confirming the XCUITest host still
  cannot interact with the target. Result bundle:
  `app/build/macos-alpha-checks/NativeDocumentSafetyForeground-20261003.xcresult`.
  The new script entry point
  `app/tool/run_macos_alpha_checks.sh --appkit-test
  testRedCloseCancelKeepsDirtyNamedProjectOpen` reproduced the same diagnosed
  permission failure in five seconds and retained
  `NativeDocumentSafety-testRedCloseCancelKeepsDirtyNamedProjectOpen-20261003-165216-91732.xcresult`.
  A manual app launch exposes the canvas to desktop accessibility. After
  enabling Accessibility for both Xcode.app and Xcode Helper.app from the
  active Xcode 27 installation, then restarting Xcode, the focused test still
  failed. Running it from Xcode's GUI produced the same result: XCTest reports
  the Project Ink application/window as disabled and sees only native window
  chrome, with no Flutter canvas node. The app itself is visible in the test
  recording. This points to a Flutter macOS accessibility-tree problem rather
  than an ungranted Xcode permission; a similar childless FlutterView group is
  reported in upstream issue
  https://github.com/flutter/flutter/issues/189683, though that report used a
  different Flutter/macOS combination and does not prove the same root cause.
  The manual matrix covers all six Save/Discard/Cancel outcomes. Keep the
  automated XCUITest matrix marked unverified until Flutter exposes the target
  semantics to XCTest or a reliable native test-driver workaround is in place.
- Real-app macOS manual safety follow-up on the built debug app: the native
  accessibility tree exposed `Drawing canvas`, and a saved stroke changed the
  package including tile files. Cmd-Q Cancel and red-close Cancel kept the
  window open, left the explicitly saved package byte-for-byte unchanged, and
  retained recovery. Red-close Discard and Cmd-Q Discard left the saved package
  hashes unchanged and removed recovery; fresh launches showed no recovery
  prompt. Red-close Save and Cmd-Q Save both exited after changing package
  state, including canvas tiles. Reopening the Cmd-Q-saved project displayed
  its stroke; Undo removed it and Redo restored it. Detailed hashes and steps
  are in the local record
  `manual-xctest-20261003/records/macos-manual-safety.txt` under the app's
  `ProjectInkAlphaValidation` documents folder. These are desktop pointer
  checks, not physical Apple Pencil evidence. The XCUITest matrix remains
  unverified until its disabled-window automation issue is resolved.
- The paired physical iPad Pro (11-inch, 3rd generation; iPadOS 27.0) is
  currently visible to Flutter and `devicectl`. The acceptance preflight
  reported 19.9 GiB free before the macOS workflow rerun. That rerun used disk;
  current free space is 13.1 GiB, below the 18 GiB device threshold and
  28 GiB full-run threshold. Approved inactive simulator and macOS Xcode build
  products were removed to recover space; per-run simulator checksum
  manifests were refreshed, and logs/Xcode result bundles remain preserved.
  No iPad build or install has started because automatic signing may register
  the iPad UDID with the configured developer team; authorization is pending.
  Physical Pencil, save, recovery, offline, latency, and memory acceptance
  remain open.
- Fresh macOS revalidation on 2026-10-03: `app/tool/run_macos_alpha_checks.sh
  --workflows-only` passed Flutter analysis, all 597 Flutter tests, all seven
  disk-backed document/layer/brush/comic and failure-preservation journeys,
  and the macOS debug build. The run summary and per-step logs are retained in
  `app/build/macos-alpha-checks/`. The AppKit runner now rebuilds the regular
  app target before either focused or full native UI testing, repairing the
  stale temporary `listener.dart` configuration found during the prior run.
  A focused red-close Cancel test passed the app build but Xcode timed out while
  enabling macOS UI automation before launching the test app; its result bundle
  is `app/build/macos-alpha-checks/NativeDocumentSafety-testRedCloseCancelKeepsDirtyNamedProjectOpen-20261003-182239-67480.xcresult`.
  The six-choice AppKit automation remains unverified. The recorded manual
  real-app matrix remains passed. Current free space is 10.3 GiB, below the
  physical-device run's 18 GiB minimum; no iPad build or install was started.
  A read-only signing check found one valid code-signing identity but no
  installed provisioning profile containing the connected iPad's UDID. A
  signed install may require Xcode to register the device; no registration was
  attempted.
- Recheck after the acceptance commits on 2026-10-03: the iPad remains connected
  and the macOS runner preflight passes with no Project Ink process. Free disk
  is 10.5 GiB, still below the physical-device run's 18 GiB minimum. The
  focused red-close Cancel runner rebuilt the app successfully, then Xcode
  timed out after 67.5 seconds while enabling UI automation; it launched no
  test case. Result bundle:
  `app/build/macos-alpha-checks/NativeDocumentSafety-testRedCloseCancelKeepsDirtyNamedProjectOpen-20261003-183555-81676.xcresult`.
  The interactive six-choice matrix remains covered by the real-app record
  `manual-xctest-20261003/records/macos-manual-safety.txt`. iPad signing and
  Xcode UI-automation authorization have not been granted; no device install
  or system privacy change was made.
- Native live-texture recheck on 2026-10-03: the macOS integration test built
  and rendered a confirmed dab; Flutter copied two pixel buffers and frame
  acknowledgement succeeded. Native texture disposal returned promptly, but
  Flutter did not deliver `onTextureUnregistered` within a two-second
  wall-clock polling window. The texture remained in `retiring`; the acceptance
  test correctly fails rather than releasing the backing buffer early. The
  registry retains one surface at most and the Dart controller falls back to
  CPU preview. Result log:
  `app/build/macos-alpha-checks/macos_native_live_texture.log`.
- iPad preflight recheck on 2026-10-03: the physical iPad Pro 11-inch (3rd
  generation, iPadOS 27.0) is connected and visible to both Flutter and
  `devicectl`; the Acceptance scheme resolves with Flutter 3.47.5 and Xcode
  27.0. The previously approved inactive macOS build products were removed
  after confirming no process held them. The runner now reports 9.5 GiB free,
  still below its 18 GiB device-run threshold, so no iPad build or install was
  started. The existing signing preflight found no provisioning profile for
  this iPad's UDID; if signing requires device registration, obtain explicit
  approval before allowing Xcode to register it. Pencil, latency, memory,
  recovery, offline, and physical document acceptance remain open.
- iPad Acceptance build-only probe on 2026-10-03: bypassed the acceptance
  runner's free-space gate and ran the trace-enabled, no-code-signing Debug
  flavor directly. Xcode completed its compile in 59.3 seconds. The Runner.app
  bundle is 183 MiB under `app/build/ios/Debug-Acceptance-iphoneos/`; the new
  Xcode build directory is 503 MiB. The existing acceptance output directory
  is 751 MiB. Flutter then reported that its expected
  `ios/iphoneos/Runner.app` path was missing, although the flavor-specific app
  exists under `ios/Debug-Acceptance-iphoneos/`. Free disk changed from 9.5 to
  9.8 GiB. This was compile and storage evidence only; there was no signing,
  install, device registration, Flutter integration run, or native UI test.
  The 18 GiB threshold has not been calibrated against the full device run.
