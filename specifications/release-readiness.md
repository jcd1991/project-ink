# Project Ink release readiness

This checklist defines the gates for a public release. A debug build or a
passing unit suite is evidence for only the checks it directly exercises.
Keep all six platforms currently named in the README visible in the matrix:
iPadOS, iOS, Android, macOS, Windows, and Linux. The first public release
candidates are macOS and iPadOS; they are candidates, not support claims. Do
not describe a platform as supported until its install, document, input,
offline, and recovery gates below pass. At present, none is
release-supported.

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
| `.inkproj` and studio pages | Manifest 256 KiB; SQLite 64 MiB; decoded tiles 768 MiB; decompressed history 128 MiB; vector/resource libraries 256 MiB each; brush library 64 MiB; comic sidecar 64 MiB. A shared conservative ledger caps accounted document data at 768 MiB and reserves decompression/parse working space below 900 MiB. Studio pages share the same ledger. | Validate the accounting against a generated maximum-valid fixture and measure peak memory on minimum-spec hardware. The 24 storage tests, including aggregate-budget boundaries and a studio round-trip, pass. |
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
- [ ] Edit a custom brush, preview it, cancel and commit drafts, export/import
  it, select it, and prove the committed settings change rendered output.
- [ ] Verify adjustment visibility, order, parameters, undo/redo, save/reopen,
  and deterministic export for the supported adjustment set.
- [ ] Create and edit a multi-page comic with panels and dialogue, save/reopen,
  then produce and inspect one useful export with references intact.
- [ ] Verify live preview-to-committed tile equivalence, long-stroke undo
  grouping, and memory/performance limits on physical pen devices.

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
  --lib` passed all 24 tests, including aggregate project-memory boundaries,
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
- The paired physical iPad Pro (11-inch, 3rd generation; iPadOS 27.0) is
  currently visible to Flutter and `devicectl`. The acceptance preflight
  reported 19.9 GiB free before the macOS workflow rerun. That rerun used disk;
  current free space is about 12 GiB, below the 18 GiB device threshold and
  28 GiB full-run threshold. Approved inactive simulator and macOS Xcode build
  products were removed to recover space; per-run simulator checksum
  manifests were refreshed, and logs/Xcode result bundles remain preserved.
  No iPad build or install has started because automatic signing may register
  the iPad UDID with the configured developer team; authorization is pending.
  Physical Pencil, save, recovery, offline, latency, and memory acceptance
  remain open.
