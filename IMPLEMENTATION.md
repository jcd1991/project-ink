# Implementation handoff

This repository follows the numbered Project Ink plan. Each change should be
one small subsystem with tests before implementation. Phase 5 items remain
deferred.

Final external validation is deliberately a Phase 5 activity. Phases 1–4
record local automated tests, deterministic fixtures, static analysis, and
simulator/emulator startup evidence only; physical hardware, hosted
Windows/Linux execution, store installation, and final print/export review are
not required to advance those implementation phases.

## Current slice

1. Workspace/toolchain pins and MPL-2.0 headers.
2. Rust model, command, input, brush, tiled raster, and engine crates.
3. Deterministic golden-stroke and undo/redo tests.
4. Flutter shell with a responsive canvas contract and gesture defaults.
5. Native `.inkproj` persistence with SQLite WAL metadata, Zstandard tiles,
   atomic replacement, backups, and source-preserving recovery.
6. Bounded pointer backpressure, a dedicated Rust render worker, and persisted
   reversible history snapshots.
7. Flutter 3.47.5 runners for iOS, Android, macOS, Windows, and Linux, with
   FRB 2.13.0 generated bindings and Cargokit native-library packaging.
8. A Rust-backed Dart adapter, deterministic generic pointer encoder, default
   two-/three-/four-finger command gestures, and fixed-width dirty-tile update
   packets.
9. Incremental Flutter BGRA tile decoding/composition with revision promotion
   so unchanged tiles survive partial updates.
10. Native iOS Pencil, Android S Pen, and macOS AppKit tablet interception with
    the shared binary EventChannel, Dart viewport transformation, and Rust packet path.
11. Versioned command-journal decoding and reopen-time corruption validation,
    including a regression test that preserves the unreadable source.
12. Pinned Flutter version metadata in `app/pubspec.yaml` and native build lanes for macOS/iOS,
    Android arm64, Windows, and Linux in GitHub Actions.
13. A cross-architecture recorded-stroke golden tile hash and a release-mode
    Phase 1 benchmark for packet-to-dirty-tile latency and engine-owned memory.
14. A tested quick-pinch fit-canvas gesture with scale/rotation baselines that
    avoid cumulative zoom drift.
15. Apple Pencil command transport for double-tap/squeeze, Android S Pen and
    macOS tablet side-button toggles, a local quick menu, Pencil Pro roll-angle
    normalization, and undoable eraser rasterization driven by the packet
    `ERASER` flag.
16. Bounded Flutter packet-to-post-frame performance traces with p95 reporting,
    dirty-tile counts, and a local `ProjectInkApp.onPerformanceSnapshot` hook
    for physical-device acceptance runs.
17. A generated FRB `engine_health` call that validates the native bridge before
    document creation on every Flutter target.
18. A subprocess crash-injection storage test that terminates during manifest,
    SQLite, tile, history, backup-rename, and publish-rename stages and verifies
    the prior save or backup recovery.
19. A Dart control-plane contract for native `.inkproj` open, atomic save-as,
    and deterministic PNG export, including an FRB-backed open factory that
    validates the engine health marker before reading a document.
20. A debounced Dart autosave coordinator wired to stroke and undo/redo
    mutations, preserving dirty state after a failed Rust checkpoint.
21. An injected `DocumentPicker` seam and canvas toolbar actions for Open,
    Save, and PNG export without copying document state into Dart; the canvas
    gesture arena is isolated from those controls so taps are not swallowed.
22. A document-picker specification defining cancellation, directory-backed
    `.inkproj` paths, mobile provider access, and offline behavior.
23. A default `PlatformDocumentPicker` with an app-owned Documents fallback,
    iOS Files exposure, and no unresolved URI crossing into Rust.
24. Native-first directory selection on Android and native directory/save
    dialogs on desktop through the Flutter file-selector platform seam, with
    deterministic cancellation and local-path fallback tests.
25. Android SAF and iOS/iPadOS Files project-open staging into app-owned
    storage, bounded by entry/byte limits and exposed to Dart only as a local
    path through the provider method channel.
26. Provider-import session capability tracking and transactional project
    write-back after a successful local Rust save; imports selected at the
    provider root remain local-only when a safe parent replacement is absent.
27. Provider PNG export staging and collision-safe native promotion after a
    successful local Rust export; PNGs remain local when no writable provider
    parent is available.
28. Mobile project-name prompt with provider-session bypass, plus an injected
    target-platform seam so naming behavior is deterministic in widget tests.
29. Opt-in newline-delimited JSON performance recorder for physical-device
    acceptance traces, with asynchronous local writes and a regression test.
30. Dependency-free `tools/phase1_trace_report.dart` evaluator for device
    p95 targets; native memory samples are diagnostic and platform tools remain
    authoritative for RSS.
31. Checked-in physical-device acceptance runbook covering installation,
    trace collection, RSS capture, and device-specific pass/fail criteria.
32. Optional native performance-channel memory samples on iOS/iPadOS, macOS,
    and Android, with JSON coverage tests and platform-specific build checks.
33. Opt-in `PROJECT_INK_TRACE=true` entry-point wiring that creates a
    timestamped, app-local Phase 1 trace without enabling network telemetry.
34. CI desktop lanes explicitly enable their Flutter targets and print the
    resolved Flutter toolchain before building Windows, Linux, or macOS.
35. Rust CI enforces bounded Phase 1 CPU benchmark guardrails for packet
    latency, dirty-tile count, and engine-owned memory estimate.
36. Production `ProjectInkApp` no longer silently falls back to an in-memory
   document when Rust initialization fails; widget tests use an explicit
   engine override and users receive a startup error surface.
37. Reopen-time persistence coverage now verifies that both undo and redo
   restore the expected tile pixels after loading a native project.
38. Pointer packet decoding rejects trailing bytes and unknown lifecycle
   phases instead of accepting ambiguous native input.
39. Layer commands preserve stable IDs, record parent relationships, reject
   child deletion and ancestry cycles, and validate the tree when reopening,
   including duplicate-ID rejection.
40. Predicted pointer samples render into ephemeral preview tiles, are excluded
   from snapshots and saves, and are invalidated when confirmed samples or
   stroke completion arrive.
41. Rebuilt the normal and trace-enabled Android arm64 debug artifacts after
   the predicted-preview engine change; both builds completed successfully.
42. Rebuilt the macOS debug app and iOS simulator app with the pinned Flutter
   3.47.5 SDK; installed and launched the iPad Air 11-inch (M4) simulator,
   confirming FRB initialization, engine health, and the initial document.
43. Installed and launched the refreshed trace APK on the local Android API 35
   emulator; logcat confirmed the app-local trace path, Rust bridge health, and
   initial document load before the emulator was shut down.
44. Extended the opt-in trace with confirmed/predicted sample accounting,
   native sequence-gap detection, and rejected-confirmed-packet reporting;
   the evaluator now requires both latency and confirmed-sample delivery.
45. Rebuilt normal and trace Android APKs plus macOS/iOS simulator targets
   after the trace-accounting change; the exact trace APK was installed and
   launched on the Android API 35 emulator with bridge-health logs confirmed.
46. Gated packet-accounting and post-frame performance tracing behind an
   explicit acceptance callback or trace path so normal drawing builds avoid
   the diagnostic decode/allocation work.
47. Rebuilt the normal and trace APKs plus macOS/iOS simulator targets after
   that hot-path optimization; the current iOS simulator launch again passed
   the Rust engine-health marker.
48. Applied the v1 256-sample bound in Dart/native packet validation and added
   a regression test before transforms and trace accounting.
49. Rebuilt the current APKs and Apple simulator targets after the packet-bound
   change; the exact trace APK installed/launched on Android API 35 with the
   trace path and Rust health marker confirmed.
50. Extended every hosted platform build lane to verify its expected output
   and upload a short-lived debug artifact plus checksum for CI evidence.
51. Made native and generic pointer delivery fail-closed: a malformed packet or
   bridge error cancels the active stroke, restores the pre-stroke Rust state,
   records a rejected packet only on opt-in traces, and prevents later samples
   from being applied to a half-committed stroke.
52. Reinstalled the final trace-enabled arm64 APK on the local Android API 35
   emulator after the fail-closed change; the app reached a live Flutter
   process, initialized the Rust bridge, passed the engine-health marker, and
   created the default document before the emulator was shut down.
53. Re-ran the release CPU benchmark after the current workspace changes:
   packet-to-dirty p95 `870` microseconds, four dirty tiles, and
   `55,167,545` estimated engine-owned bytes for the 4096×4096/20-layer gate.
54. Enforced the 256-sample packet bound inside the iOS, macOS, and Android
   native encoders, retaining confirmed samples before coalesced and predicted
   samples while preserving retained wire order; the iOS RunnerTests packet
   regression passed on the iPad Air M4 simulator.
55. Added an Android native unit test for the same bound-preservation rule and
   made the hosted Android lane run `:app:testDebugUnitTest` before uploading
   its APK artifact; the local Gradle test task passed.
56. Made the Android CI lane install and verify the locked NDK 27.1 toolchain
   plus the 28.2 plugin compatibility toolchain before Gradle runs, removing
   host-image availability as an implicit build dependency.
57. Added the iOS native packet-bound regression to the hosted macOS/iOS lane;
   it runs the same XCTest that passed locally on the iPad Air M4 simulator.
58. Rebuilt the cleaned Rust workspace and re-ran format, all workspace tests,
   Clippy with warnings denied, and the release benchmark; the current
   benchmark reported packet-to-dirty p95 `896` microseconds, four dirty tiles,
   and `55,167,545` estimated engine-owned bytes.
59. Re-ran the Android `:app:testDebugUnitTest --no-daemon` task after the
   native readiness-channel change; the build completed successfully.
60. Re-ran Flutter dependency resolution, analyzer, and the full 31-test suite
   after formatting the readiness fallback code; all checks passed.
61. Launched the Rust-backed macOS debug app locally; startup logged Rust
   bridge initialization, the `project-ink-engine-v1` health marker, default
   document creation, and initial revision loading before the debug process
   was stopped cleanly.
62. Added and passed an iOS XCTest proving the native pointer status stream
   emits `ready` after a listener attaches, covering the startup fallback
   arbitration directly on the iPad Air M4 simulator.
63. Added macOS packet-bound and readiness EventChannel XCTest coverage and
   made the hosted Apple lane run the macOS native test suite alongside iOS.
64. Ran the macOS native XCTest locally on the Apple Silicon host; both packet
   bound and readiness tests passed.
65. Added checked-in positive and negative trace JSONL fixtures and a CI smoke
   check that requires the evaluator to accept the good fixture and reject the
   sequence-gap fixture.
66. Added widget-level touch arbitration tests for two-finger undo,
   three-finger redo, and four-finger interface toggle through `CanvasScreen`.
67. Re-ran Flutter analyzer and the full suite after the new widget tests;
   analyzer is clean and all 34 tests pass.
68. Added bounded decoded RGBA8 image-tip resources for PNG/JPEG/WebP brush
   imports, hash-addressed resource persistence in `.inkproj`, image-tip
   alpha sampling during rasterization, and export/reopen regression coverage.
69. Added native `.inkbrushpack` multi-brush export/import with manifest,
   per-member CBOR hashes, deterministic previews, resource validation,
   duplicate/case-collision/path-traversal checks, full-source hash
   verification, and all-or-nothing Rust installation staging.
70. Added generic Flutter document export choices for PNG, JPEG, WebP,
   OpenRaster, SVG, and flattened PSD while preserving the direct PNG toolbar
   action; added keyboard shortcuts for undo/redo, brush, eraser, and Escape.
71. Added Rust-owned brush draft transactions with begin/update/commit/cancel
   semantics; uncommitted editor settings cannot affect stroke capture or
   saved brush state.
72. Re-ran the complete Rust workspace tests, warnings-as-errors Clippy, and
   Flutter analyzer plus the full 42-test suite after the resource, pack,
   transaction, export, and shortcut changes; all passed.
73. Hardened native brush archive reads by hashing and parsing the same bounded
   byte buffer (instead of hashing one path read and parsing a second), added
   a 256 MiB aggregate decoded-resource cap, and kept symlink/path/ratio
   validation before resource staging.
74. Routed Flutter brush-library edits through debounced Rust-owned draft
   begin/update/commit transactions and cancel active drafts during canvas
   teardown; direct slider changes no longer mutate committed brush settings.
75. Added a visible Brush Library “Cancel edit” action that queues draft
   cancellation behind pending updates and refreshes the Rust-owned projection.
76. Rebuilt the macOS debug application after the draft-transaction and
   cancellation UI changes; the desktop artifact completed successfully.
77. Added an ephemeral Rust-owned selection mask bridge for rectangle, ellipse,
   lasso, layer-opacity, and color-range operations. Confirmed and predicted
   brush dabs are clipped by the active mask; Flutter now exposes selection
   tools and overlays, and ruler geometry snaps transformed native/generic
   pointer samples before they reach Rust.
78. Regenerated FRB bindings after the selection API addition and re-ran Rust
   tests, warnings-as-errors Clippy, Flutter analyzer, and the full 42-test
   Flutter suite.
79. Added scalar Krita KPP and MyPaint MYB conversion regressions that retain
   source provenance and explicitly report renderer substitutions.
80. Added bounded Krita `.bundle` conversion: only `.kpp` members are parsed,
   unrelated members remain inert, member identities are deterministic, and
   multi-member installation is transactional with source-hash verification.
81. Added the Rust engine and FRB bundle-install path, regenerated bindings,
   and routed the Flutter compatibility dialog through the dedicated bundle
   operation without changing the native pack contract.
82. Re-ran Rust format, all workspace tests (including 24 brush and 41 engine
   tests), warnings-denied Clippy, Flutter analyzer, and all 53 Flutter tests;
   every check passed.
83. Re-ran iOS simulator and macOS native XCTest suites plus Android
   `:app:testDebugUnitTest --no-daemon` against the regenerated bindings; all
   packet-bound and readiness tests passed.
84. Rebuilt the arm64-targeted Android debug APK after the bundle changes and
   copied it to `outputs/project_ink-debug.apk`; the artifact is 197,898,989
   bytes with SHA-256
   `3c51d841a5f95dd98d4cee939439efe18acd4fc386e8acd80fdec7d498493b13`.
85. Rebuilt the latest Rust-backed macOS debug app and iOS simulator app after
   the shared-resource accounting fix; both Flutter build targets completed
   successfully.
86. Extended the one-hour-equivalent Phase 2 benchmark with explicit initial
   and final memory fields and CI assertions that the peak covers the final
   sample; the current run reports 3,600 strokes, seven brushes, and all
   latency/memory guardrails passing.
87. Hardened bounded PSD opening at the bridge boundary by rejecting symlinks
   and non-regular files and capping the actual read, closing the metadata/read
   replacement window before decode.
88. Re-ran the iOS simulator and macOS native XCTest suites plus Android
   Gradle unit tests after the PSD boundary change; all platform-native tests
   passed, and the refreshed macOS/iOS/Android debug builds completed.
89. Added Krita-bundle adversarial fixtures for traversal, case-collision,
   missing-preset, entry-count/size limits, and compression-ratio-bomb inputs;
   the brush crate now has 29 passing tests covering those archive-specific
   rejection paths.
90. Implemented and validated bounded brush post effects: the release Phase 2
   benchmark now reports p95 `40,554` microseconds (first window `40,881`,
   final window `40,024`) with final memory `268,882,224` bytes and peak
   `323,927,984` bytes; Flutter analyze/tests remain clean and the latest
   iOS/macOS XCTest, Android unit-test, and Android debug APK builds pass.
91. Preserved the verified Android debug APK at
   `outputs/project_ink-debug.apk` (SHA-256
   `1eb8b5dfbd3edef9e53104f8843ee83345061c30453b25590663b239a7902cf0`) and
   removed only the exact generated Project Ink `app/build`, `app/.dart_tool`,
   and Rust `target` caches after all verification completed; the host volume
   recovered to approximately 15 GiB free.
92. Included `TexturePass` post-effect hashes in both brush-pack resource
   reachability and engine export accounting; added a lossless native-pack
   round-trip test proving the referenced resource is retained rather than
   silently dropped.
93. Aligned the Brush Studio size and texture-scale controls with the engine's
   validated import limits (0.25–4096 px and 0.01–64×); added a widget
   regression proving an imported maximum-size/maximum-texture preset renders
   without a Flutter slider assertion.
94. Re-ran Flutter 3.47.5/Dart 3.13.4 analyzer and all 54 Flutter tests,
   Rust workspace tests, format, and warnings-denied Clippy after the Brush
   Studio bounds fix; rebuilt the arm64 debug APK at
   `outputs/project_ink-debug.apk` (116,261,171 bytes, SHA-256
   `ca394ee77bb1be538aa95c938fff7ce13cea172ff49e342aaed6f6cf9021d8d9`).
95. Rebuilt the current Flutter macOS debug app and iOS simulator app after
   the Brush Studio change; both Flutter build outputs completed successfully.
   Android native unit tests and the iOS/macOS native packet/readiness XCTest
   suites also pass. The remaining Phase 2 evidence is limited to external
   Windows/Linux hosted artifacts and physical tablet traces.
96. Preserved the rebuilt APK and removed only the generated `app/build`,
   `app/.dart_tool`, and Rust `target` directories after verification; the
   exact cache paths are absent and the host volume reports approximately
   16 GiB free.
97. Added the pinned Flutter 3.47.5 SDK bin directory to the user's zsh login
   PATH; a fresh login shell now resolves Flutter 3.47.5 and Dart 3.13.4.
98. `flutter doctor -v` now reports no blocking issues for Flutter, Dart,
   Android SDK 36, Xcode 27, CocoaPods, and the available macOS/Chrome targets;
   it reports only a duplicate `adb` installation warning.
99. Hardened Dart packet-flag rewriting to validate packet version, bounds, and
   known mode flags before mutation; the full Flutter suite now passes 55 tests.
   Rebuilt Android arm64, macOS, and iOS-simulator artifacts from this source;
   the preserved APK is 116,261,647 bytes with SHA-256
   `49ab19a3dcc640b3edb16f0a908ed6467701703b5b4458f181e82ecddc90d4ab`.
100. Made vector intersection erase geometry-aware: circular erasing now solves
    deterministic segment/circle intersections, interpolates pressure and tilt
    at cut points, splits surviving centerline pieces, preserves untouched
    closed strokes, and rejects non-finite geometry without destructive writes.
    Added crossing, interpolation, miss, and bounded single-point regressions;
    workspace tests and warnings-denied Clippy pass.
101. Rebuilt Android arm64, macOS, and iOS-simulator debug artifacts with the
     intersection-erase engine; the preserved APK is 116,354,303 bytes with
     SHA-256 `dd0b8b045689fa050c44d585b346966da93df32f9714f42fc235fa1dbfc1a550`.
     Moved the generated Flutter and Rust build caches to Trash after the builds;
     the exact cache paths are absent and the host reports approximately 4.7 GiB
     free after the final Rust verification pass.
102. Added a dedicated regression for vector segment/circle interpolation and
     untouched closed-stroke preservation; the complete Rust workspace test
     suite passes across all targets/features, warnings-denied Clippy passes,
     and the repository remains rustfmt-clean.
103. Re-ran Flutter 3.47.5/Dart 3.13.4 analysis and the complete 55-test
     widget/control-plane suite against the current tree; analysis reports no
     issues and all gesture, picker, brush, layer, accessibility, and native
     packet contract tests pass.
104. Added the pinned Flutter 3.47.5 SDK bin directory to interactive zsh
     sessions as well as login sessions; an interactive shell resolves Flutter
     3.47.5 and Dart 3.13.4 directly.
105. Restored Flutter package metadata for the simulator-only native test and
     ran the iPad Air 11-inch (M4) iOS simulator `RunnerTests`; pointer packet
     bounds and native readiness-channel tests both passed. The physical Apple
     Pencil acceptance gate remains separate and unclaimed.
106. Ran the macOS native `RunnerTests` on the Apple Silicon host; pointer
     packet bounds and readiness-channel tests both passed there as well.
107. Moved only the two Project Ink-generated Xcode DerivedData directories
     created by the simulator/macOS tests to Trash; shared SDK/module caches
     were left untouched.
108. Removed the empty generated `app/build` directory after native-test
     verification; no source or preserved release artifact was touched.
109. Booted the installed Android API 35 arm64 emulator, installed the
     preserved `org.projectink.studio` debug APK, launched `MainActivity`, and
     verified a live Flutter/Rust startup (`RustLib.init`, engine-health marker,
     default document, and initial revision) with no fatal exception. The
     emulator was shut down cleanly; this is emulator smoke evidence, not S Pen
     or Galaxy S23 acceptance.
110. Added an engine-boundary regression for `EraseVectorSegment`: a crossing
     erase splits the real persisted vector stroke, preserves interpolated
     pressure values, and undo/redo restores and reapplies the split. The full
     Rust workspace suite (including 42 `ink-engine` tests) passes, Clippy is
     warnings-clean, and rustfmt remains clean.
111. Fixed the Linux GTK tablet adapter to accept `GDK_SOURCE_ERASER` as well
     as `GDK_SOURCE_PEN`, set the packet-v1 eraser flag for that source, and
     retain barrel-button normalization while continuing to reject mouse,
     touch, and cursor devices. Updated the native transport specification;
     hosted Linux hardware/build evidence remains external.
112. Hardened Android `MotionEvent` serialization with finite-axis and
     ±65,536-coordinate validation before packet encoding, then added JVM tests
     for NaN/infinite/out-of-range rejection. The Android Gradle unit lane
     compiles the adapter and passes successfully; the existing NDK 27.1 versus
     plugin 28.2 warning remains intentional.
113. Hardened the iOS and macOS packet encoders with the same finite-axis and
     coordinate bounds, propagated rejected packets back to Flutter’s generic
     pointer path, and added native regressions for non-finite coordinates.
     Both Apple adapter/packet source pairs pass SDK type-checking for their
     target platforms; full XCTest reruns remain constrained by local build
     cache space.
114. Parsed `.github/workflows/ci.yml` locally after the platform changes;
     the workflow remains syntactically valid and contains Windows/Linux build
     artifact lanes. A read-only GitHub Actions lookup for the declared public
     repository returned 404, so no hosted run or artifact can be claimed from
     the current external state.
115. Clarified the release-status boundary in `README.md`: Phase 2
     illustration-alpha implementation and locally executable verification are
     complete, while physical Apple/Samsung acceptance and hosted Windows/Linux
     evidence remain explicit external gates. This prevents local simulator,
     emulator, and source-level checks from being misreported as hardware or
     hosted-platform acceptance.
116. Added the Phase 3 `ink-comic` crate and `specifications/comic-format.md`.
     The validated model covers print/illustration/webtoon templates, page
     metadata (bleed/trim/safety/DPI), rectangular and polygonal panels with
     linked masks and gutters, editable balloons/dialogue styles, screentones,
     effect lines, licensed material metadata, dialogue search, safe JSON
     round-trips, and bounded webtoon segmentation. The deterministic
     eight-page stick-figure fixture exercises create/reorder/gutter/search/
     recovery-shaped round trips without relying on pixel fixtures.
117. Added FRB `ComicProjectHandle` APIs for creation, snapshots, page
     insertion/reordering, gutter editing, dialogue search, segmentation, JSON
     serialization, and close semantics. Regenerated FRB 2.13.0 bindings and
     added the responsive Flutter comic workspace panel with page reordering,
     search, and segmentation controls. Flutter analysis passes.
118. The bridge test lane now passes all six tests, including eight-page comic
     creation, page-number-safe reorder, case-insensitive dialogue search,
     bounded webtoon segmentation, JSON close/reopen recovery, and existing
     symlink-safety regressions. The initial build hit the host disk ceiling;
     only the exact generated Project Ink target cache was removed before the
     successful serialized `-j1` rerun.
119. Added bounded dialogue editing and explicit file-backed comic manifest
     export to the core and FRB API. The acceptance test now edits a balloon,
     verifies the dialogue-search delta, writes and validates a manifest,
     closes the opaque handle, and restores the eight-page project from JSON.
     The comic crate has five passing tests and the bridge lane remains green.
120. Added safe panel, balloon, and print-page creation APIs plus compact
     workspace actions for Page, Panel, Balloon, and Webtoon segments. The
     top canvas toolbar now scrolls horizontally on narrow desktop/mobile test
     surfaces; the complete Flutter suite passes all 56 tests without layout
     overflow failures.
121. Integrated comic JSON into native `.inkproj` checkpoints as a validated
     `comic.json` sidecar. `Document::set_comic_json` and the FRB attach/read
     APIs preserve comic structure across save/reopen and reject malformed or
     oversized payloads. The Flutter workspace loads existing comic metadata
     when present and persists fixture edits through the Rust document engine;
     engine and bridge checkpoint tests pass.

## Verified build matrix

- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo run -p ink-engine --release --example phase1_benchmark`
- `flutter analyze` and `flutter test` (55 tests)
- `flutter build macos --debug`
- `flutter build ios --debug --simulator --no-codesign`
- `flutter build apk --debug --target-platform android-arm64`
- `flutter build apk --debug --target-platform android-arm64 --dart-define=PROJECT_INK_TRACE=true`
- `xcodebuild test -workspace app/ios/Runner.xcworkspace -scheme Runner` on
  the iPad Air 11-inch (M4) simulator
- `xcodebuild test -workspace app/macos/Runner.xcworkspace -scheme Runner` on
  the Apple Silicon macOS host
- Hosted macOS/iOS lane command for the iPhone 15 iOS Simulator destination
- `./gradlew :app:testDebugUnitTest --no-daemon`
- iPad Air 11-inch (M4) simulator install and launch via `simctl` without code signing
- Generated FRB health binding and native bridge unit test
- `cargo test -p ink-storage process_kill_during_save_preserves_last_valid_project -- --nocapture`
- Flutter control-plane tests for dirty-tile decoding and save/export contracts
- Flutter autosave coalescing, interval, and retry tests
- Flutter canvas document-action wiring through the picker seam
- Flutter native-picker contract tests for desktop, Android, and cancellation
- Flutter provider-channel contract test for staged local paths
- Flutter save-then-provider-commit ordering test
- Flutter provider PNG staging/commit and export-then-write-back ordering tests
- Flutter local performance-recorder JSON test
- Native performance-channel memory sample serialization test
- Opt-in entry-point trace path remains disabled by default
- Explicit `ProjectInkApp.engineOverride` widget-test seam and visible Rust
  startup-error surface
- Reopened `.inkproj` undo/redo test that restores the saved tile after each
  direction
- Pointer packet tests for trailing-byte and invalid-phase rejection
- Layer-tree tests for stable IDs, parent moves, child deletion, and corrupt
  cyclic/dangling/duplicate-tree rejection on reopen, including move
  undo/redo
- Predicted-stroke tests proving visible preview pixels never persist and are
  cleared with a dirty-tile notification when a stroke ends without a sample
- Resource-backed image-tip render/save/reopen/export/reimport test
- Native `.inkbrushpack` multi-member lossless round-trip and archive-safety tests
- Rust brush-draft cancel/commit transaction test
- Flutter generic-format export wiring and direct-PNG compatibility tests
- `cargo clippy --workspace --all-targets -- -D warnings` after the latest
  Phase 2 changes
- `flutter build macos --debug` after the brush draft UI changes
- Flutter 3.47.5 `analyze` (no issues) and 42-test suite (all passed) after
  the latest native runner rebuild
- macOS debug build and iOS simulator debug build with the pinned Flutter SDK
- iPad Air 11-inch (M4) simulator install/launch; log confirmed
  `RustLib.init complete`, `engine health passed (project-ink-engine-v1)`,
  default document creation, and initial revision loading
- Refreshed trace APK installed/launched on the Android API 35 emulator;
  logcat confirmed the local JSONL trace path, `RustLib.init complete`,
  `engine health passed (project-ink-engine-v1)`, default document creation,
  and initial revision loading
- Flutter trace tests for confirmed/predicted counts, sequence gaps, and
  rejected confirmed packets
- Native pointer adapters now publish a readiness event only after Flutter has
  attached the packet stream; the generic stylus bridge stays enabled until
  that event, preventing startup races from swallowing the first stroke.
- Trace-report evaluator positive and negative smoke fixtures, including the
  confirmed-sample delivery gate
- Trace-report evaluator smoke run for the iPad M4 target

The iOS build compiles the Pencil interception/status and packet EventChannels
plus native memory channels, and the Android build compiles the S Pen
`MotionEvent` plus status/packet EventChannels and native memory channels.
Android reports the
intentional NDK 27.1 versus Cargokit/plugin NDK 28.2 compatibility warning;
the arm64 APK still completes successfully. The latest local run completed
`app-debug.apk` after installing the plugin's missing NDK/platform components.

Windows and Linux builds are present in the generated runner projects. Their
native-host CI lanes are configured but still need a hosted run before this
acceptance item can be marked verified.
The iPad simulator launch reached the Rust-backed canvas after FRB
initialization; it does not validate Apple Pencil hardware input or physical
display latency.
The Android API 35 emulator also launched the trace-enabled APK and reported
the app-local JSONL path plus the Rust engine health marker. This is startup
evidence only; it does not validate S Pen delivery or physical-device latency.
The final trace-enabled APK was reinstalled after the fail-closed pointer
delivery change; `ActivityTaskManager` reported the app fully drawn and
logcat recorded `RustLib.init complete`, the engine-health marker, default
document creation, and initial revision loading. The emulator has no stylus,
so this remains startup evidence rather than physical S Pen acceptance.
The iPad Air 11-inch (M4) simulator was rebuilt, installed, and launched after
the mobile naming change; `org.projectink.studio` reported a live UIKit
process. This still does not validate Apple Pencil hardware input or display
latency.
The earlier unfiltered Android APK attempt exhausted the host volume; after
removing only project-generated build caches, the arm64 build completed
successfully. The latest iOS simulator and macOS debug builds also completed
after the provider-staging change. Simulator builds verify compilation only;
Files/SAF selection and copy behavior still require physical-device runs.

The latest local release run reported `p95_packet_to_dirty_us=896`, four unique
dirty tiles for the four-tile fixture, and an estimated 55,167,545 engine-owned
bytes for a 4096×4096 document with 20 raster layers. Timing is expected to
vary by host. This is CPU-engine evidence only; it does not prove Pencil/S Pen
delivery, Flutter scheduling, display latency, allocator overhead, or
physical-device memory acceptance.

The current Android arm64 debug artifact is
`app/build/app/outputs/flutter-apk/app-debug.apk` (116,261,647 bytes; SHA-256
`49ab19a3dcc640b3edb16f0a908ed6467701703b5b4458f181e82ecddc90d4ab`). It is
an unsigned debug build for sideloading. No Android hardware was connected
during this rebuild, so S Pen delivery and device latency remain unverified.

After the latest import-report, archive-hardening, Krita-bundle conversion,
FRB, and Phase 2 stroke-history changes, the local targets were rebuilt again:
`app/build/macos/Build/Products/Debug/project_ink.app`,
`app/build/ios/iphonesimulator/Runner.app`, and
`app/build/app/outputs/flutter-apk/app-debug.apk` (215,901,489 bytes; SHA-256
`1eb8b5dfbd3edef9e53104f8843ee83345061c30453b25590663b239a7902cf0`).
This remains an unsigned/debug artifact; the historical `outputs/` copy is not
assumed to exist after cache cleanup.

Latest merge-command verification: Rust workspace tests (41 engine tests plus
all crate tests), format, and warnings-denied Clippy pass; Flutter analyze and
all 55 widget/control-plane tests pass. The iOS simulator and macOS native
`RunnerTests` pass pointer-packet bound and readiness-channel regressions, and
the Android `testDebugUnitTest` task passes. The current macOS debug app, iOS
simulator debug app, iOS device-architecture app (`--no-codesign`), and
Android debug APK rebuild successfully. The local host cannot build Windows or
Linux (`flutter build windows/linux` are host-restricted); those hosted lanes
and physical tablet traces are explicitly deferred to Phase 5 external
acceptance.

## Phase 2 implementation evidence

- Added a versioned deterministic brush evaluator with twelve built-in
  presets covering sketch, ink, marker, opaque paint, gouache, watercolor,
  blender, spray, ribbon, bristle, and rake behavior. Pressure curves, taper,
  grain, scatter, rotation jitter, dual brushes, smudge/wetness parameters,
  and validation limits are unit-tested.
- Added native `.inkbrush` packs with canonical CBOR payloads, SHA-256
  manifests, bounded ZIP extraction, normalized paths, symlink-safe export,
  and explicit approximate/guided reports for external ABR/SUT/TOS/Procreate
  formats. Krita KPP and MyPaint MYB scalar conversions never claim renderer
  equivalence; bounded parser regressions now verify their conversion reports,
  source provenance, and renderer-substitution warnings. Krita `.bundle`
  archives now convert bounded `.kpp` members transactionally while leaving
  unrelated archive members inert.
- Added persistent layer blend mode, alpha lock, clipping, reference, label,
  and name commands, with journal round trips and multi-layer composite export.
- Added JPEG, WebP, OpenRaster, SVG, and bounded flattened PSD encoders with
  signature/container tests; the existing PNG path uses the same composite.
  Added a strict flattened-PSD decoder for version-1 RGB 8-bit uncompressed
  files, with rejection tests for truncation and compressed/channel variants.
- Added `ink-tools` selection masks and flood fill with bounded gap closing,
  affine transforms, vector-ink simplification/pressure widths, and
  straight/parallel/symmetry/radial/perspective ruler snapping.
- Integrated rectangle/ellipse/lasso/layer-opacity selection masks into the
  Rust raster path, with a verified predicted/confirmed clipping test and a
  responsive Flutter illustration-tools palette. Color-range selection now
  has a bounded RGB/tolerance dialog in the Flutter tool panel.
- Added ruler overlays and canvas-space snapping for both generic and native
  pointer packets; selection masks remain ephemeral until a versioned
  selection-persistence schema is approved.
- Added an undoable, journaled raster affine transform command with finite
  matrix validation, deterministic sparse forward mapping, dirty-region
  notifications, and engine tests proving move/undo/redo behavior. Flutter
  exposes a transform tool with drag-to-move and canvas-centered rotate/scale
  presets; mesh and liquify are now exposed through their bounded dialogs.
- Added a bounded perspective raster transform command with quadrilateral
  validation, deterministic bilinear forward mapping, journal tag 19, FRB
  bindings, and a Flutter rectangle-driven perspective-transform tool.
- Added a bounded regular mesh raster transform command with 2–32 control-grid
  validation, deterministic bilinear mapping, journal tag 20, FRB bindings,
  and a responsive row-major control-point editor. Added a bounded,
  undoable local liquify command with push/expand/contract/twirl modes, journal
  tag 21, FRB bindings, and a mode/strength dialog.
- Added a bounded editable vector-stroke command (journal tag 22), plus
  journaled transform, simplify, connect, segment-erase, and control-point
  commands (tags 23–27). Rust validates finite canvas-clamped points, pressure,
  rebuilds vector raster visibility tiles, persists `vectors.json.zst`, and
  keeps edits undoable. Flutter now creates vector layers, exposes vector
  pen/transform/eraser tools, and provides simplify/connect/control-point
  editing while compositing visible vector tiles with raster layers.
- Added journal tag 28 for deterministic linear gradients. The engine supports
  flood/reference sampling, Paint Inside, transparent-only painting, bounded
  mask expansion, selection intersection, undo/redo, and a Flutter Gradient
  action alongside bucket fill.
- Completed the v1 mask/group semantics: mask layers are drawable alpha
  stencils for the preceding paint sibling, mask layers are excluded from the
  visible paint stack, and group visibility/opacity propagate through nested
  parent chains in the Flutter compositor. Added Rust regression coverage for
  mask alpha stenciling.
- Added a parent-aware layer creation bridge. Selecting a group or panel group
  before adding a layer now persists the new child under that parent, while
  top-level creation remains the default.
- Extended the iOS Files provider staging path to accept `.psd` files as
  read-only imports, with the same bounded copy budget and no provider
  write-back entitlement.
- Reference-aware bucket fill now samples visible marked reference layers while
  mutating only the selected raster layer; alpha-lock blocks new pixels and
  clipping masks a layer to the preceding paint layer in engine reads/exports.
- Added a local time-lapse export action that writes the bounded committed
  stroke recording through the same platform export picker.
- Added document-scoped staged brush-import operation IDs with a ten-minute
  expiry, a sixteen-operation cap, discard semantics, and source-hash
  revalidation immediately before commit.
- Added a 64 MiB decoded-resource LRU for image tips and included its usage in
  `estimated_working_memory_bytes`; durable resources remain separately
  bounded and content-addressed.
- Added an undoable, selection-aware bucket-fill command. It uses the bounded
  Rust flood-fill mask with tolerance and gap closing, rejects oversized
  documents before allocating its working buffer, and exposes a Flutter fill
  tool with bounded color/tolerance/gap controls.
- Corrected gap closing so flood fill may cross only the configured number of
  consecutive out-of-tolerance barrier pixels. It no longer expands the final
  mask after traversal, preventing gap-closing from bleeding into nearby
  unrelated artwork; the barrier budget is regression-tested.
- Corrected v2 brush dynamic evaluation to seed each target from its serialized
  `base`, clamp normalized pressure/tilt/speed/progress/random/rotation values,
  wrap only angular direction, and require the specified 2–16 response-curve
  points. Pressure endpoint and non-default-base regressions now cover these
  semantics. Apple Pencil Pro `rollAngle` and AppKit tablet rotation are
  normalized to turns before entering pointer packet v1, so desktop and iPad
  rotation curves share one domain.
- Added Flutter projection models and tests for brush-library favorites/drafts
  and layer-panel multiselect/range behavior. Wired those projections into the
  canvas shell through the Rust-owned brush and layer summary APIs; selecting a
  built-in Phase 2 brush now changes the stroke command routed to Rust.
- Added layer-pinch merge preview UI with explicit source/target confirmation,
  stable-ID routing, and a Rust `MergeLayers` journal command. The command
  validates standalone raster layers, composites with source opacity and blend
  mode, removes the source atomically, and is covered by undo/redo and journal
  replay tests.
- Regenerated and compiled FRB 2.13.0 bindings with Flutter 3.47.5/Dart 3.13.4.
  `flutter analyze` and the complete Flutter suite pass. The local macOS debug,
  iOS simulator, and Android arm64 debug builds also complete; the Android
  build retains the intentional NDK 27.1 versus plugin-required 28.2 warning.
- Added Rust-owned brush editor updates with finite/range validation, immutable
  active-stroke capture, safe native brush export, decoded external-brush
  installation, and layer-property command routing for visibility, opacity,
  alpha lock, clipping, and reference flags.
- Added compact pressure-size/pressure-opacity controls plus spacing, texture,
  scatter, rotation, smudge, wetness, curve-midpoint, and tip-hardness
  controls; pressure bindings and tip settings are updated and validated in
  Rust before a subsequent stroke captures them.
- Made the Flutter brush library projection reactive with Rust-owned updates,
  composable name/tag filtering, and an immediately reachable brush/action
  layout on compact touch viewports. Added regression coverage for filter
  notifications and selection visibility.
- Persisted imported and edited brush overrides in the bounded
  `brushes.json.zst` sidecar inside `.inkproj`; save/reopen tests verify that
  the Rust-owned brush library survives recovery-safe checkpointing.
- Extended the pressure editor from a midpoint-only control to bounded
  two-to-sixteen-point curves carried through FRB as normalized pairs, with
  Rust ordering/range validation and save/reopen coverage. Brush projections
  now expose tip/grain resource hashes for the textured-resource inspector.
- Wired native brush import/export actions into the responsive brush panel via
  an optional `BrushPicker` seam, so existing document-picker integrations and
  widget fakes remain source-compatible. The Rust bridge installs decoded
  presets and exports only Rust-owned `.inkbrush` packs.
- Added bounded inspection/report DTOs to the FRB surface. External imports now
  show source format, fidelity, mappings, omissions, warnings, and preview
  metadata before the user can install; guided-only formats remain disabled.
- Native `.inkbrush` exports now contain a deterministic `preview.webp` entry;
  imports reject missing/invalid previews, duplicate or case-folding-colliding
  paths, and archive compression ratios above the safety limit.
- Native `.inkbrushpack` exports/imports now preserve multiple presets,
  per-member previews, and referenced decoded resources. Pack installation
  verifies the full source hash and stages every member before mutating the
  Rust library; archive bytes are hashed and parsed from the same bounded
  buffer, with a 256 MiB aggregate decoded-resource cap.
- Hardened external parser selection to validate magic bytes and native
  manifest structure before dispatching a decoder, with regression coverage for
  renamed native archives, malformed ZIP signatures, and extensionless image
  inspection.
- Routed PNG/JPEG/WebP imports through the guarded image-tip converter. Bounded
  header inspection now reads enough bytes for valid PNG/WebP dimensions while
  hashing the complete source; decoded straight-alpha RGBA8 payloads are
  persisted by hash and sampled by the renderer; a regression test covers the
  full round trip.
- Extended bounded WebP inspection to parse VP8X, ordinary lossy VP8, and
  lossless VP8L headers, with malformed/truncated variant coverage.
- Added the generic document-format export chooser and keyboard command
  shortcuts while retaining the direct PNG toolbar path. The Rust brush draft
  transaction API is now used by the Flutter brush-library editor with a
  bounded idle commit and visible cancellation. The brush panel now includes
  a disposable scratch pad for testing the current size/opacity settings.
- Added native desktop tablet adapters: Windows WM_POINTER/Windows Ink packet
  normalization with eraser/barrel flags, a dynamically loaded WinTab
  compatibility fallback for older tablet drivers, and a GTK tablet adapter
  covering Wayland/X11 pressure and tilt axes. All use the existing packet /
  status channels; hosted compilation and physical tablet traces remain
  pending. The optional WinTab DLL is loaded from the Windows system directory
  only, its packet fields are bounded before entering the shared wire format,
  and the fallback disables itself as soon as Windows Ink produces a pen
  packet so drivers cannot duplicate a stroke.
- Closed the desktop native-input routing gap: Flutter now listens to the
  Windows/Linux packet and readiness channels, Windows consumes a pen message
  only after the packet sink accepts it (otherwise generic Flutter input stays
  available), and Linux disconnects its GTK event signal before adapter
  teardown. This prevents duplicate Windows strokes, startup input loss, and
  teardown callbacks into freed Linux adapter state.
- Added an in-app gesture settings surface for touch-first workflows. Users can
  enable single-finger canvas navigation and remap the two- and three-finger
  tap commands between undo and redo; changes use the shared command paths,
  while the four-finger interface toggle remains intact. Stylus-first
  arbitration is unchanged, so a stylus contact still draws when navigation is
  enabled.
- The gesture settings and tap recognizers intentionally do not claim the full
  CSP/Procreate gesture matrix yet. Three-finger swipe-down now opens a local
  clipboard color palette, long-press samples the visible cached canvas color,
  Pencil Pro quick-menu routing is wired, and layer right/left swipes provide
  additive selection and mutation actions. Draw-and-hold now enables a bounded
  next-stroke straightening constraint, a second finger enables 15-degree
  constrain mode, and two-finger layer hold/swipe maps to opaque-content
  selection and alpha-lock mutation. Layer pinch now opens an explicit merge
  preview and commits through the same undoable Rust command path.
- Added a widget regression that opens the gesture settings surface and checks
  the navigation and remapping controls before cancelling without changing
  editor state.
- Added a bounded touch-command classifier with three-finger swipe-down and
  long-press recognition, a clipboard color palette, cached-canvas eyedropper,
  draw-and-hold straightening, second-finger 15-degree constrain mode, and
  classifier regression tests. Layer rows now support raw-pointer right/left
  swipes, two-finger alpha-lock swipes, and two-finger opaque-content holds;
  the layer swipe path has widget coverage.
- Added explicit `Semantics` metadata for the drawing canvas and an
  accessibility settings surface for larger toolbar hit targets/icon sizes and
  left-handed toolbar placement, with widget coverage for both controls.
- Added a Rust-owned brush-color update through the FRB control plane and a
  bounded RGB slider dialog in the canvas toolbar. Color updates are rejected
  during active strokes, persist with brush overrides, and are covered by Rust
  and Flutter tests so sketch/ink/color/export is reachable without another
  application.
- Added a single Rust acceptance workflow covering sketch, ink, colored paint,
  editable vector ink, time-lapse recording, undo/redo, and all six Phase 2
  export formats. It verifies the complete path in one document rather than
  relying only on isolated feature tests.
- Expanded the disposable Flutter brush scratch pad to consume the complete
  projected preset, so spacing, stabilization, pressure, hardness, texture,
  scatter, rotation, smudge, and wetness changes visibly affect the preview
  without mutating the document.
- Added a Rust-owned duplicate-brush operation with bounded name handling,
  fresh stable IDs, persistence, undo/redo, generated FRB bindings, and a
  responsive library action.
- Fixed multi-sample Phase 2 rendering so legacy resampling and compiled-brush
  dab streams maintain independent cursors; a multi-point watercolor stroke now
  completes without a worker panic and remains undoable.
- Added `phase2_session_benchmark`, an accelerated 3,600-stroke mixed-brush
  session. Its current local run completed with a maximum estimated engine
  memory of `323,927,840` bytes; first-window p95 stroke time was `19,098`
  microseconds and the final-window p95 was `14,606` microseconds. The run is
  engine-only evidence and does not replace physical-device traces.
- Capped aggregate undo/redo snapshot payloads at 256 MiB while retaining the
  newest undo state. This prevents long sessions from turning full layer-map
  snapshots into an unbounded memory sink; the cap is enforced on load and on
  every history mutation.
- Made committed brush-library settings and color edits transactional and
  undoable through the shared `EditorCommand::Undo`/`Redo` path; invalid draft
  input no longer leaves a partially mutated preset behind.
- Hardened external MyPaint metadata lookup with an iterative depth/node-bounded
  walk, preventing deeply nested untrusted JSON from exhausting the stack.
- Added a desktop widget regression proving Ctrl/Cmd-Z, Ctrl/Cmd-Shift-Z, and
  Ctrl/Cmd-Y reach the same Rust-owned undo/redo methods as touch gestures.
- Extended the arm64/x64 replay lane with a deterministic vector-ink golden
  tile hash (`4780892121892926211`) alongside the raster golden, covering both
  rendering paths before hosted cross-architecture runs.
- Hardened the CI evidence lanes: Rust CI now runs all targets and features
  with warnings-denied Clippy, and the Windows debug artifact includes a
  persisted SHA-256 checksum alongside the uploaded executable bundle.
- Separated brush selection from brush editing in the Flutter panel. Selecting
  a preset now only changes the active brush; it cannot silently create and
  commit a Rust brush draft with UI defaults. Added a widget regression for
  this command-boundary invariant.
- Changed layer property and presentation edits to refresh from Rust after both
  success and rejection instead of leaving optimistic Flutter-only state. The
  rejection path now has a widget regression proving the layer projection stays
  authoritative.
- Brush draft update, commit, and cancellation failures now clean up any
  remaining Rust draft and reload the Rust-owned brush projection.
- Projection refreshes preserve the active brush ID when it remains available,
  instead of silently switching back to the first preset after layer changes.
- Brush projection upserts now replace every pixel-affecting control from the
  Rust projection while preserving only the UI-owned favorite flag; this keeps
  the Rust document authoritative across refreshes and reopen flows.
- Multi-brush import budget accounting now deduplicates shared resource hashes
  before applying the document resource ceiling, matching the content-addressed
  resource store and avoiding false rejection of valid packs.
- Extended the Rust brush summary projection and generated FRB DTO with the
  complete bounded editor state (size, opacity, spacing, smoothing, pressure,
  hardness, texture, scatter, rotation, smudge, wetness, and color). Reopened
  documents now repopulate Flutter from persisted Rust settings instead of UI
  defaults; exact stamp scatter is retained losslessly, and a regression
  checks the projection before and after save/reopen.
- The latest release-mode mixed-brush benchmark (3,600 strokes across seven
  Phase 2 brushes, including stroke-finalization effects) reports p95 `40,554`
  microseconds, first-window p95 `40,881` microseconds, final-window p95
  `40,024` microseconds, initial memory `2,928` bytes, final memory
  `268,882,224` bytes, and peak estimated engine memory `323,927,984` bytes.
  This is repeatable local CPU evidence,
  not a substitute for the physical-device one-hour trace.

The Rust CI lane now runs this same 3,600-stroke Phase 2 benchmark and fails
on missing brush coverage, p95 above 50 ms, memory above the 900 MiB document
ceiling, or a final-window p95 more than twice the first-window p95.

The latest native verification also passed the iOS `RunnerTests` packet-bound
regression on the iPad Air 11-inch (M4) simulator after the readiness-channel
change. macOS and iOS debug builds and the Android arm64 debug builds compile
the same startup-race and desktop-channel routing changes. The current Android
APK is 116,261,647 bytes with SHA-256
`49ab19a3dcc640b3edb16f0a908ed6467701703b5b4458f181e82ecddc90d4ab`.

The current local release benchmark was repeated three times after the
brush-color and accessibility changes. It reported four dirty tiles and
`55,197,321` estimated engine-owned bytes on every run, with host-side
packet-to-dirty p95 values between `802` and `992` microseconds. This is a
stable CPU-engine regression signal and remains deliberately separate from the
physical-device latency, display scheduling, and RSS evidence still required
by the acceptance matrix.

## Next slices

- Exercise the decoded-resource LRU under a bounded local mixed-brush session and
  collect the documented memory samples. The bounded persistent resource store,
  image-tip rendering, and native pack round trips are implemented and covered
  by tests.
- Exercise the readiness event on each native adapter with a first-stroke
  launch test; keep the generic stylus fallback until the event is observed.

All remaining physical, hosted-platform, store-installation, and final export
review work is listed under the Phase 5 backlog below.

## Phase 5 external validation backlog

- Run the physical Pencil/S Pen and Wacom/Huion/XP-Pen matrix with latency,
  confirmed-sample, memory, gesture, and recovery evidence.
- Run hosted Windows/Linux builds and install the artifacts on real desktop
  systems.
- Execute the Phase 3 cross-device comic transfer and production print/export
  review described in `TODO.md` and the two Phase 5 runbooks.

Do not change the pointer packet, command meaning, or `.inkproj` schema without
updating its specification and compatibility tests in the same change.

- Added the declarative Phase 2 post-effect model to the brush compiler. It
  now validates bounded digital-watercolor edge, edge-softness/sharpen,
  stamp-outline, trailing-fade, and texture-pass stages, preserves the field
  when reading older v2 presets, and compiles effects into the immutable
  per-stroke handle.
- Added deterministic, selection-aware stroke-finalization passes over a
  bounded dirty region. Effects include the brush-diameter padding and a
  maximum 32-million-pixel allocation guard; modified tiles are committed as
  part of the same undoable stroke transaction. Watercolor Wash now exercises
  the edge pass in the built-in library. Brush tests cover limits, backward
  deserialization, and compiled-effect metadata; the Phase 2 watercolor
  workflow covers paint, finalization, undo, and redo.

122. Refined the Phase 3 comic model and export boundary. Project validation
    now rejects negative trim geometry and duplicate IDs across tones and
    effect lines before mutation. Added atomic, self-contained SVG page export
    (panels, linked mask metadata, balloons/text, screentones, and effect
    lines) alongside the bounded JSON page manifests; XML escaping and a
    no-script export regression are covered by `ink-comic` tests.
123. Added FRB DTOs for panel/balloon preview geometry and print-preview
    reports, plus batch SVG export. The Flutter comic workspace now paints
    page thumbnails with linked-mask overlays and displays bleed/safety/moiré
    warnings. Rust comic, bridge, Flutter analyzer, and focused Flutter tests
    pass; physical cross-device round trips remain an external acceptance gate.
124. Added a bounded Rust-owned local materials library with license,
    attribution, and source metadata, exposed through FRB and summarized in
    the Flutter workspace. The Phase 3 acceptance flow now passes create,
    eight-page edit/reorder/gutter/dialogue search, JSON recovery, print
    preview, JSON/SVG batch export, and native `.inkproj` checkpoint tests.
    Full Flutter test suite passes (55 tests); regenerated bindings are
    formatted and warning-denied Clippy is clean. Regenerable Rust build
    output was removed after verification to recover disk space.
125. Extended creation controls beyond rectangular defaults: polygon panel
    editing, configurable screentone insertion, and speed/effect-line insertion
    are now validated in Rust, exposed through FRB, and reachable from the
    touch-friendly comic workspace. Local UI IDs use a monotonic session
    allocator so rapid taps cannot collide and leave a partially-created
    project.
126. Added styled balloon creation (oval, thought, narration, burst, tails,
    horizontal/vertical text, font/outline settings) and a guarded template
    switcher for illustration, print-comic, and webtoon sessions. The current
    Flutter flow keeps template replacement explicit through the new-project
    menu and persists the resulting Rust-owned project.
127. Added a generic page-creation bridge so webtoon templates default to a
    1080×5000 long canvas and segment deterministically into 2,048-pixel export
    slices. The bridge acceptance lane now includes a dedicated webtoon
    template/segmentation test; Flutter analysis remains clean after the
    generated API update.
128. Re-ran the complete Flutter suite after the styled-balloon and template
    controls landed: all 55 tests pass. Rust format and warning-denied Clippy
    remain clean for the comic and bridge crates.
129. Wired batch SVG export to a user-facing local directory picker on desktop,
    Android, and the app-owned iOS fallback. The picker path contract is
    covered by Flutter tests; export remains offline and writes only after the
    destination is selected.
130. Regenerated the FRB bindings after extending comic page DTOs with print
    guide geometry, and added a bounded Flutter overlay for trim, bleed, and
    safety guides in the print-preview summary. Rust bridge tests, formatting,
    warning-denied Clippy, Flutter analysis, and the full 55-test Flutter suite
    pass. Full raster print-safe preview, physical cross-device round trips,
    and hosted Windows/Linux evidence remain external or follow-up gates.
131. Extended comic snapshots with polygon vertices and balloon text/style
     projections, then added a selected-page Flutter inspector: dialogue can
     be edited in place, gutters use bounded sliders and persist through the
     Rust API, selected pages drive webtoon segmentation and print guides, and
     polygon panels render in thumbnails. Added byte-stable portable JSON
     round-trip coverage and bridge assertions for the editable projections.
132. Added a SHA-256 portable render digest over canonical comic JSON and
     deterministic page SVG bytes, exposed through FRB and a Flutter
     "Transfer check" dialog. This gives users a concrete cross-device
     comparison value while keeping font caches, filesystem order, and network
     services out of the document authority.
133. Final verification after the usability and transfer updates: the complete
     Rust workspace/all-target/all-feature suite passed, Flutter analysis and
     all 55 Flutter tests passed, and formatting plus warning-denied Clippy
     passed. The generated `target` directory was removed afterward to recover
     roughly 1.1 GiB safely; no source or user documents were deleted.
134. Added the selected-page canvas preview to the comic inspector. It renders
     bounded panel geometry, polygon panels, balloons, dialogue snippets, and
     trim/safety guides at touch-panel scale; Flutter analysis and all 55 tests
     pass after the preview was added.
135. Added the physical Phase 3 transfer-acceptance runbook for iPadOS,
     Android, and desktop. It requires matching portable fingerprints and SVG
     hashes, and explicitly distinguishes macOS Sidecar smoke tests from direct
     Apple Pencil hardware acceptance.
136. Added validated panel division (including linked-balloon retargeting),
     configurable circle/line/noise tone presets, speed/focus/radial effect
     line choices, and local material categories to the creation controls.
     Webtoon batch export now emits cropped SVG segments with deterministic
     source offsets and viewBoxes; focused comic tests and Flutter analysis
     pass, and warning-denied Clippy remains clean.
137. Re-ran the full Rust workspace/all-target/all-feature suite after the
     panel and segmentation changes (all crate tests passed), plus the full
     Flutter suite (55 tests passed). Regenerable build output was removed
     again after verification; approximately 1.6 GiB remains free.
138. Verified the final configurable-creation pass: full Rust workspace tests,
     11 comic-model tests, 10 bridge tests, Flutter analysis, 55 Flutter tests,
     formatting, and warning-denied Clippy all pass. The generated `target`
     directory was removed after the run.
139. Added a bounded Rust raster print-preview path. `render_page_preview`
     validates the requested dimensions, renders trim/safety guides, panels,
     tones, effect lines, balloon geometry, and deterministic offline text
     stubs into RGBA bytes, and the FRB API encodes those bytes as PNG. The
     Flutter inspector displays the returned image and retains the guide
     fallback. Determinism, dimension limits, non-white output, PNG encoding,
     Rust tests, Flutter tests/analyzer, formatting, and warning-denied
     Clippy all pass. Physical iPadOS/Android/desktop round trips and final
     font/color-managed production export remain acceptance gates.
140. Closed the fixture-fidelity gap in the Phase 3 acceptance comic. Pages now
     carry bounded serialized vector-ink lines with finite points, width, and
     RGBA color; the xkcd-style fixture adds five deterministic stick-figure
     strokes per panel, and both SVG export and raster preview render them.
     Round-trip equality, deterministic digest, SVG marker, focused Rust tests,
     formatting, and warning-denied Clippy pass.
141. Added bounded balloon-tail and text-style mutation APIs through Rust and
     FRB, plus touch-friendly Flutter dialogs for coordinate-pair tail editing
     and font fallback/size/outline/orientation editing. The acceptance bridge
     flow exercises both mutations; Rust focused tests, Flutter analysis, and
     all 55 Flutter tests pass.
142. Strengthened the portable transfer fingerprint to hash canonical JSON,
     deterministic SVG, and each page's bounded 1024-pixel raster preview.
     Cross-device comparison now covers both structure and the rendered page
     projection while remaining offline and bounded; the full Rust workspace
     test suite passes after this change.
143. Added a `ComicWorkspaceController` injection seam and an app-boundary
     Flutter test that opens the comic workspace from the real canvas toolbar.
     The workspace header/actions are now vertically scrollable in the compact
     touch panel, eliminating the overflow discovered by that test. Flutter
     analysis, the focused widget test, and the full suite remain green.
144. Hardened the Flutter comic navigator against stale selection indexes after
     template replacement or recovery. The selected page resets/clamps before
     creation commands are dispatched; analyzer and the app-boundary widget
     regression pass.
145. Added a bounded panel polygon editor to the selected-page inspector. It
     pre-fills rectangle corners or existing vertices, validates 3–32 pairs in
     the dialog, and routes edits through the Rust-owned polygon command; the
     compact UI keeps gutter editing beside the shape editor.
146. Improved template creation ergonomics: Illustration and print-comic
     projects now open with a 2400×1800 @300-DPI page, while webtoon projects
     open with a 1080×5000 @144-DPI page. Page provisioning is transactional;
     failed page creation or snapshot loading closes the new Rust handle so the
     previous project remains intact.
147. Cleared project-specific Flutter projections when the Rust comic identity
     changes. Dialogue hits, webtoon segments, and print-preview warnings now
     disappear during template replacement or recovery instead of remaining
     attached to the previous project.
148. Re-scoped final external testing into Phase 5 at the user's request:
     physical Apple Pencil/S Pen and desktop-tablet traces, hosted Windows/
     Linux artifacts, cross-device comic transfer, store/direct-release
     installation, and production-font/color export review are now deferred
     requirements. Local Rust/Flutter acceptance remains runnable without those
     memory-intensive external sessions; the two device runbooks and matrix
     explicitly identify their Phase 5 status.
149. Reviewed the live macOS shell through manual mouse input. Conventional
     mouse packets now normalize pressure to 1.0 so pressure-sensitive brushes
     render visible dabs, with a widget regression covering the path. Added a
     production-only desktop Workspace dock with labeled Tools, Brushes,
     Layers, and Comics tabs; the canvas and top bar are inset beside it while
     compact test/touch layouts retain floating panels. Full Flutter analysis
     and all 57 Flutter tests pass. Remaining UI polish and physical/hosted
     validation are tracked in `BUGS.md` and Phase 5 requirements.
150. Closed a panel-creation usability gap: panels added from the comic
     workspace now receive a fresh stable linked-mask identity instead of an
     unlinked placeholder. The identity remains metadata-only until raster
     mask binding is connected, but it is preserved by the existing Rust
     validation, SVG export, checkpoint, and transfer-digest paths.
151. Fixed a reproducible Flutter modal lifecycle crash in the comic inspector.
     Dialogue, polygon, balloon-tail, and balloon-style editors now own their
     text controllers inside stateful dialog routes; closing a modal no longer
     rebuilds a TextField with a disposed controller. Flutter analysis and all
     57 tests pass, and the live macOS app was hot-restarted and manually
     verified through open/close of the dialogue editor without a red screen.
152. Improved comic authoring fidelity by automatically loading the bounded
     Rust raster preview for the selected page. The inspector now shows the
     actual xkcd stick-figure ink, balloons, tones, and effect lines; page
     changes request the matching preview and structural edits invalidate stale
     bytes. Flutter analysis and all 57 tests pass, and the live macOS Comics
     dock visibly rendered the stick figures after hot restart.
153. Queued comic preview requests so rapid page selection cannot leave a
     previous page's raster preview attached to the new inspector selection.
     Manual macOS verification switched from page 1 to page 2 and observed the
     page-2 preview and inspector update together.
154. Re-reviewed the running macOS shell through the desktop dock: the labeled
     Layers tab exposes raster/vector/group/mask/tone/panel creation and the
     active layer row, while Tools and Brushes remain one-click siblings.
     A direct mouse click-drag on the canvas produced a visible stroke, with
     the conventional mouse pressure normalization confirmed in the live UI.
155. Hardened `TileImageCache` image lifetimes. Replaced tile images and
     revision promotions are now retired after the frame boundary instead of
     being disposed during a possible paint, preventing Flutter's native
     `drawImage` assertion during live redraws. Analyzer and all 57 Flutter
     tests pass, and a second live mouse stroke produced no new shell error.
156. Closed a comic-structure gap in panel division: the second panel created
     by a horizontal or vertical split now receives a deterministic linked-mask
     identity in a separate metadata namespace. The existing mask remains on
     the first panel, and the Rust comic plus bridge acceptance tests verify
     both links and unchanged gutters/content ownership. Derived mask IDs are
     collision-checked before mutation so hostile imported IDs fail atomically.
157. Made the comic dialogue search useful during page editing: up to twelve
     bounded result rows now show the page, matched text, balloon ID, and match
     range, and tapping a result selects that page so the inspector can edit
     the corresponding dialogue. Flutter analysis and all 59 tests pass,
     including a widget regression that submits a cross-page hit and verifies
     the inspector changes pages.
158. Replaced the webtoon segmentation count-only status with a bounded slice
     summary showing segment numbers, source Y offsets, and heights (first 16
     rows, while export still includes every slice). Widget coverage verifies
     the long-canvas workflow exposes the expected segmentation metadata.
159. Removed a major live-canvas hitch: opaque normal layers now skip the
     full-document `saveLayer` offscreen buffer, and drawing shows an
     ephemeral pointer-frequency stroke preview while Rust tiles are decoded.
     Retired `ui.Image` objects are kept for three completed frames before GPU
     disposal, preventing the macOS `drawImage` assertion and revision flash.
     Flutter analysis is clean, all 59 tests pass, and a hot-restarted macOS
     mouse stroke produced no shell errors.
160. Added a bounded comic-session history: every successful persisted
     structural edit contributes a JSON checkpoint to a 64-entry/16 MiB
     undo stack, with redo invalidated by new edits. Undo/redo restores a
     validated Rust handle, persists the restored project without recursively
     recording history, and refreshes previews safely. The Comics dock now
     exposes labeled undo/redo buttons; Flutter analysis and all 60 tests pass,
     and the live macOS fixture was edited, undone, and redone (balloon count
     4 → 5 → 4 → 5) without a red screen.
161. Standardized the desktop workspace around a compact, labeled quick-control
     strip: active brush, size, opacity, eraser, color, zoom, fit, and gesture
     settings are available above the canvas without opening a panel. The
     existing tool destinations remain icon-first for narrow windows so
     document-action and accessibility hit targets stay stable. Flutter
     analysis and the focused canvas/document/comic UI tests pass.
     Added an explicit collapse/expand affordance for the desktop Workspace
     dock so the canvas can be temporarily maximized without losing the dock
     state.
162. Closed a Phase 3 authoring discoverability gap: thought and burst balloon
     shapes were supported by Rust but not reachable from the Flutter toolbar.
     Added a labeled balloon-type menu for speech, thought, narration, and
     burst balloons, plus a widget regression that verifies a thought-balloon
     selection dispatches shape 1.
     The full Flutter suite now passes with 63 tests; Rust comic/bridge tests
     remain green (11 + 10) with clippy warnings denied.
163. Added the active layer name to the desktop quick-control strip next to the
     brush context and zoom state, closing the remaining status-context gap in
     the compact canvas workflow.
164. Made panel division visually authorable: the divide dialog now renders
     the two resulting panel regions and lets the user drag the divider while
     preserving bounded horizontal/vertical ratio validation. A widget test
     drags the divider to the 90% bound and verifies the dispatched command.
165. Made the local materials library actionable. ComicWorkspaceController now
     removes a selected material through the Rust bridge and persists the
     result; the expanded material summary exposes a labeled remove action and
     the widget suite verifies the material ID dispatched for removal.
     The complete Flutter suite now passes 64 tests.
166. Added accessible page-order controls beside the existing drag handle. Move
     up/down actions use the same Rust reorder command and update the selected
     page index after a move; widget coverage verifies the first page move.
     The complete Flutter suite now passes 65 tests.
167. Replaced fixed screentone presets with a bounded authoring dialog. Users
     can choose circle, line, or noise patterns and tune frequency, angle, and
     density before the Rust tone-layer command is dispatched; widget coverage
     verifies the default settings and all values passed to the controller.
     The complete Flutter suite now passes 66 tests.
168. Replaced fixed effect-line presets with a bounded authoring dialog. Users
     can choose speed, focus, or radial lines and tune width and opacity before
     the Rust effect-line command is dispatched; widget coverage verifies the
     default settings and all values passed to the controller. The nullable
     screentone snapshot path was hardened at the same time. The complete
     Flutter suite now passes 67 tests and `flutter analyze` is clean.
169. Closed the print-layout authoring gap. Added validated Rust/FRB page-layout
     mutation for DPI, bleed, trim, and safety, with atomic rejection that
     preserves all page content. The page inspector now opens a compact,
     scrollable Page settings editor and widget coverage verifies the defaults
     and dispatch values.
170. Added direct rectangular panel bounds editing through Rust/FRB and the
     page inspector. Polygon panels remain on their vertex editor path so
     polygon data cannot be discarded accidentally. Rust coverage verifies both
     successful rectangle edits and rejection of polygon edits; Flutter widget
     coverage verifies the authoring dialog. The focused comic suite now passes
     12 tests; the complete Flutter suite passes 69 tests, the full Rust
     workspace passes, and the rebuilt macOS app starts with the regenerated
     bridge library.
171. Closed the balloon-preview fidelity gap. Deterministic SVG and raster
     previews now render thought balloons as two bubble nodes plus an oval and
     burst balloons as bounded star polygons, while preserving the original
     shape metadata. The Flutter page canvas mirrors those shapes and renders
     stored tails, with structural assertions covering both exported shapes.
     Rust package tests, clippy, Flutter analysis, and all 69 Flutter tests pass;
     the macOS debug app was rebuilt against the current native library.
172. Replaced hard-coded local-material placeholders with an authoring dialog.
     Users can name a brush, texture, template, or balloon style and record
     license, attribution, and source metadata before the Rust-owned project is
     changed. Empty optional fields stay absent, required metadata is bounded,
     and widget coverage verifies the complete dispatch payload. The complete
     Flutter suite now passes 70 tests; the macOS debug app was rebuilt and
     starts cleanly with the new UI.
173. Hardened panel authoring at the Rust boundary. Rectangular bounds and
     polygon vertices must remain inside the page canvas; invalid geometry is
     rejected before mutation, and a regression verifies the previous panel
     remains unchanged. The full Rust workspace, format check, and Clippy pass.
174. Fixed the remaining whole-layer flash during drawing. The tile image cache
     now promotes unchanged images from the previous revision before switching
     the painter to that revision, while full redraws keep the prior frame
     visible until all replacement tiles decode. Stale images are retired only
     after publication. Flutter analysis and all 70 Flutter tests pass; the
     full Rust workspace passes; the follow-up image-lifetime hardening is
     recorded in entry 176.
175. Made Phase 3 tone/effect authoring round-trip complete. Existing
     screentones and speed/focus/radial lines now appear in the page inspector
     with readable parameters and labeled edit/remove actions. Editing keeps
     the stored geometry while Rust validates and persists the new style
     values; widget coverage now exercises both flows. The focused comic suite
     passes 14 tests and Flutter analysis is clean.
176. Hardened canvas image lifetime beyond revision staging. Every painter
     snapshot receives cloned `ui.Image` handles, so replacing or evicting a
     cache entry cannot dispose the handle still referenced by a previous
     CustomPainter. Tile-cache and pointer-failure tests pass, and the rebuilt
     macOS app survives repeated mouse strokes without new draw-image
     assertions.
177. Fixed the long-drag duplicate-line artifact. Confirmed tile updates and
     pointer-up now clear the ephemeral stroke preview immediately after the
     Rust stroke commit, instead of retaining it through the save window.
     Increased the bounded image-retirement window for Metal/Vulkan desktop
     compositor snapshots. Long mouse drags and consecutive strokes were
     reproduced in the running macOS app with one committed line per stroke,
     no black-box flash, and no new draw-image assertions; Flutter analysis and
     focused tile/pointer tests remain green.
178. Removed input-to-preview lag from the generic mouse/stylus path. Flutter
     now records preview points synchronously before enqueueing each Rust
     packet, and each queued packet acknowledges its captured preview index.
     `_StrokePreviewPainter` renders only the unconfirmed suffix, preserving
     natural cursor feedback without compositing confirmed pixels twice. The
     rebuilt macOS app was exercised with consecutive long drags; analysis and
     pointer/touch/tile tests pass.
179. Closed a comic-session recovery gap: closing a project now retains its
     last validated in-memory checkpoint when no host file callback is
     available, so the visible recovery action remains meaningful after a
     close. Hardened `TileImageCache` shutdown so native image handles are
     retired through the same deferred compositor-safe queue as revisions
     instead of being disposed synchronously during hot reload or dock
     transitions. Flutter analysis and focused canvas/comic tests pass.
180. Implemented the Phase 3.5 design foundation: explicit light/dark/high-
    contrast theme extensions, reusable dock/inspector/property components,
    adaptive workspace mode resolution, shared editor action IDs, and bounded
    local workspace preferences.
181. Extended layer presentation to sixteen stable blend modes, added a visible
    opacity/blend/alpha-lock/clipping/reference inspector, and added
    authoritative Rust committed composite-tile reads. Flutter now requests
    one revisioned composite tile per dirty coordinate, with the old layer
    painter retained as a compatibility fallback.
182. Added a bounded live-dab queue contract with explicit predicted-sample
    eviction and confirmed overflow errors. The Flutter live preview now stays
    visible until a decoded CPU tile is published, and local traces separately
    report pointer-to-preview timing.
183. Replaced the opaque comic preview overlay with transform-aligned guides so
    panel borders no longer cover user strokes. Versioned comic metadata as v2,
    added generated page-document references and panel-layer bindings, and
    migrated v1 comic JSON without modifying its source bytes.
184. Added separate composite-tile invalidation events and fixed-width stroke
     acknowledgement packets. Confirmed Rust samples now generate bounded
     live-dab packets for the optional GPU surface while CPU tiles remain the
     document authority; focused engine, bridge, and Flutter decoder tests pass.
185. Added the v2 atomic multi-page storage boundary. Studio projects now write
     and validate `pages/<page_id>/` document containers, and the bridge exposes
     one `StudioProjectHandle` for page activation, page commands, composite
     reads, checkpointing, and save/reopen. Storage and bridge round-trip tests
     cover an eight-page project.
186. Added the optional fixed WGSL/wgpu live surface with bounded dimensions,
     allocation limits, viewport-generation validation, and CPU fallback error
     paths. Platform texture-registry registration and physical-device gates
     remain Phase 5.
187. Made live GPU batches persistent until acknowledgement or cancellation;
     acknowledged confirmed dabs and canceled strokes are retired from the
     ephemeral surface without touching CPU document state. Added a bounded
     preview-overflow signal so backpressure degrades to the CPU painter
     instead of aborting a stroke. Added group visibility/opacity propagation
     to authoritative composite reads with regression coverage.
188. Added an explicit “Draw inside panel” action to the comic inspector. It
     scales page-space polygon/rectangle geometry into the active document and
     installs Rust’s selection mask, so brush input is clipped to the panel;
     toggling the same action releases the mask. Panel guides are now scaled
     to the active canvas and highlight the selected panel.
189. Closed the remaining layer-reordering gap in Phase 3.5. Layers now carry
    a bounded sibling order reconstructed from legacy SQLite row order, save
    in canonical sibling order, and compose/export in that order. The Rust
    `MoveLayer` command now honors its destination index, normalizes old and new
    sibling lists, and remains undoable/replayable. The bridge exposes the
    command and the Layers inspector provides visible move-up/move-down actions
    through the same shared mutation path. Rust workspace tests, warnings-
    denied Clippy, Flutter analysis, and the full Flutter suite remain green.
190. Added the panel layer-tree bridge slice. Journal tag `30` now atomically
    materializes a deterministic PanelGroup with Mask, Sketch, Ink, Color,
    Tone, and Effects children, validates non-zero unique IDs, rejects partial
    trees, and treats complete retries as idempotent. Comic panel projections
    expose the stable binding IDs; Draw-inside-panel creates/selects the Ink
    child before installing the bounded selection clip. Rust command/engine
    tests, bridge compilation, Flutter analysis, and the full Flutter suite
    pass. The unified StudioProjectHandle now materializes panel trees during
    project open and project-boundary panel creation; the remaining tracked
    gap is native texture registration and physical acceptance.
191. Hardened panel binding identity generation. Child roles now use distinct
    namespace constants instead of low-bit offsets that could collide between
    adjacent panel IDs; project validation rejects zero or duplicate binding
    layer IDs before preview/export.
192. Added persistent panel-mask geometry. Journal tag `31` rasterizes bounded
    page polygons into sparse mask tiles, applies group/PanelGroup masks to all
    paint descendants during composite reads and export, and keeps the change
    undoable with layer/composite invalidations. Draw-inside-panel now updates
    the persistent mask as well as its transient input selection; unified
    project open and project-boundary panel creation materialize initial mask
    geometry. The Flutter controller now receives a shared active-page
    capability; the callback remains only for compatibility mask geometry.
193. Added unified project-boundary panel geometry operations for resize,
    polygon edits, and split. Splitting preserves the original binding for the
    first child and materializes the second child's PanelGroup/mask atomically;
    bridge tests verify authoritative mask pixels and reject polygon splits.
    The compatibility Flutter controller still calls a bounded canvas-host
    synchronization callback after panel geometry edits; it is now only a
    mask-geometry compatibility seam because drawing and saves use the shared
    StudioProjectHandle page capability.
194. Migrated the Flutter comic controller's metadata authority to
    `StudioProjectHandle`, added validated page activation, and replaced JSON
    reconstruction undo/redo with bounded Rust project-manager checkpoints that
    preserve page document snapshots. Generated FRB bindings and a bridge test
    cover structural undo/redo. Arc-backed page capabilities now keep canvas
    drawing, layer commands, tile reads, and complete-project saves on the same
    Rust document; native texture registration remains a Phase 5 gate.
195. Converted `DocumentHandle` to a cloneable Arc-backed capability and added
    `project_active_document`. The project map and canvas now share page state,
    allowing layer edits and strokes to appear in project snapshots and survive
    `.inkproj` saves. `FrbEngineApi` rebinds on page activation and routes saves
    through `save_project_as` while a project is bound. Rust workspace tests,
    Clippy, Flutter analysis/tests, and macOS/iOS/Android debug builds pass.
196. Fixed committed composite-tile placement in the Flutter canvas. Composite
    tiles now use the same document-centered transform as layer tiles; previously
    a released stroke could be present in Rust and the live preview but render
    offscreen after confirmation. Added transparent-background and far-tile
    engine regressions plus an active-page bridge regression. A clean macOS mouse
    stroke was verified in the running app and remained visible after release.
197. Completed the adaptive workspace preference path. Mobile targets no longer
    inherit the desktop dock density from the production shell; iPad/Android
    resolve to expanded or compact touch modes while desktop retains the dock.
    Desktop dock width is draggable within 320–480 logical pixels, selected
    panel and handedness changes persist through bounded versioned
    `shared_preferences` keys, and malformed or interrupted preference writes
    fail closed. Added workspace-mode and preference validation tests.
198. Closed a dropped-refresh race in the Flutter canvas tile pump. If a
     pointer release or periodic poll arrives while a prior composite tile is
     decoding, the request is now coalesced and retried after the active decode
     completes. This keeps the CPU-authored committed tile visible after the
     responsive live preview retires instead of leaving the canvas apparently
     blank after release. Flutter analysis/tests and the macOS debug build pass.
199. Added an app-owned recovery checkpoint for every production session. The
     entry point creates `Project Ink/Recovery/last-session.inkproj`, the app
     reopens it when present, and the existing autosave coordinator checkpoints
     released strokes without requiring the user to complete a named Save
     dialog. Storage-provider failures fail open to a normal unsaved document;
     Flutter analysis/tests and the macOS debug build pass.
200. Verified the recovery path in the running macOS UI: a mouse stroke remained
     visible after release, the recovery manifest advanced to revision 4, and a
     Flutter hot restart reopened the same stroke visibly. The named Save
     control also opened the native save flow and was dismissed without writing
     a test file. Flutter analysis and all 79 widget/unit tests pass.
201. Expanded the desktop Workspace dock with bounded Navigator, Tool
     Properties, and Materials panels alongside Tools, Brushes, Layers, and
     Comics. The navigator reuses committed composite tiles, properties edit
     Rust-owned brush drafts and expose the active layer, and materials observe
     the comic controller without duplicating project state. Added dock
     preference validation and component tests; fixed the horizontal-tab
     flex-layout assertion found during live macOS hot reload. Flutter tests,
     analysis, and the macOS debug build pass.
202. Removed the standalone Navigator dock from the primary workspace at the
     user's request. Workspace preferences filter the retired tab and fall back
     to Layers when an older saved preference selected it. Pinch navigation now
     uses a shared focal-point-anchored viewport transform: scale, pan, and
     rotation preserve the content beneath the fingers, clamp invalid values,
     and never infer Fit Canvas from pinch speed. The ambiguous quick-pinch and
     canvas double-tap resets were removed; Fit Canvas remains an explicit
     toolbar/command action. Added pure viewport math tests, updated gesture
     and preference tests, verified the rebuilt macOS UI contains no Navigator
     tab, and passed Flutter analysis, 83 tests, and the macOS debug build.
203. Fixed the intermittent black-bar/triangle canvas artifact. Rotated and
     zoomed `CustomPaint` content could paint beyond its `Positioned` canvas
     bounds because the sibling toolbar and dock did not clip that transformed
     geometry. The canvas gesture/painter subtree is now wrapped in a hard
     `ClipRect`, keeping document tiles and previews inside the canvas viewport.
     Rebuilt and inspected the live macOS Comics view: the toolbar and dock
     remain clean and only the intended saved stroke is visible. Flutter
     analysis and the macOS debug build pass.
204. Fixed three live drawing regressions. The brush color dialog now provides
     an HSV wheel with alpha/value controls, keeps RGB precision sliders, and
     binds C to the picker plus I/Alt-I to a one-shot composite-tile sampler.
     Mouse input no longer arms stylus-only draw-and-hold straighten mode, and
     the mode no longer inserts a SnackBar into the pointer hot path. Full
     redraws with an empty filtered tile batch retain the last complete frame
     and retry rather than blanking the canvas. FRB initialization is also
     single-flight so concurrent engine construction cannot call `RustLib.init`
     twice. Full redraws now repaint valid empty documents, so undoing the
     only stroke clears immediately. Focused Flutter tests, analysis, a clean macOS build, and live
     macOS color-wheel/long-stroke verification pass.
205. Continued Phase 3.75 by adding drag-resizable vertical palette-group
     splits and bounded persisted overrides for built-in workspace layouts.
     Added a confirmed layout reset that clears local dock/command overrides
     without changing document state. Updated stale toolbar tests to locate
     commands by accessible labels.
     Flutter analysis and all 95 Flutter tests pass; all Rust workspace tests
     and warnings-denied Clippy pass; a fresh macOS debug bundle builds. The
     already-open app was not restarted, to preserve the user's canvas state.
206. Fixed a failure when a captured pointer leaves the document page. The
     bridge now preserves finite bounded raw document coordinates; Rust clips
     each segment to the page instead of clamping every outside sample to its
     nearest edge. After a stroke exits the page, later captured motion is
     ignored until release so it cannot draw along the border or connect a
     re-entry chord. The Flutter live preview follows the same cutoff. Added
     regressions for page-edge clipping, ignored outside/re-entry motion,
     bounded Flutter packets, and drawing again after release. All 55
     `ink-engine` tests, warnings-denied Clippy, Flutter analysis, and the
     focused pointer-failure widget suite pass; a fresh macOS debug bundle
     builds. The currently open app was left untouched so its canvas state is
     preserved.
207. Completed desktop palette drag organization for Phase 3.75. Tabs can be
     reordered within a palette group or moved between existing left/right
     groups, with a visible drop target and persisted active palette. Moving a
     palette across docks now saves both columns in one preference update so
     the second write cannot restore the old source layout. Added desktop
     widget coverage for cross-dock movement and tab reordering. All 97 Flutter
     tests and analysis pass; a fresh macOS debug bundle builds. The already-
     open app was not restarted, to preserve the user's canvas state.
208. Completed command-search metadata for Phase 3.75. Search now matches each
     action's label, category, aliases, shortcut, associated palette, and
     associated tool; multi-word searches require every term and results show
     the relevant category/palette/tool/shortcut context. Added exhaustive
     metadata coverage and UI alias-dispatch tests. The UI test caught and
     fixed a command-search dialog overflow and a controller-disposal race by
     moving search state into a route-owned widget with bounded scrollable
     results. Full Flutter test suite passes (101 tests), analysis is clean,
     and the updated macOS debug bundle builds; the existing open app was not
     restarted so its drawing state remains untouched.
209. Fixed a desktop/tablet input recovery gap where leaving the app during a
     pressed stroke could lose the matching pointer-up and leave the engine
     transaction active. The next pointer-down now cancels that abandoned
     transaction before beginning a new stroke, for both generic Flutter and
     native pointer streams. Added a widget regression that simulates the
     missed release and confirms subsequent drawing remains available. The
     focused pointer suite passes; the existing app was not restarted,
     preserving its current drawing state.
210. Began the Phase 3.75 component audit by replacing the Layers tree's raw
     `ListTile` with a shared `InkLayerRow`. The component applies consistent
     selected styling, keeps title/subtitle text bounded, guarantees a 48px
     minimum target, and leaves visibility, lock, clipping, reordering, and
     layer-swipe behavior intact. Added narrow-dock/200%-text widget coverage;
     the focused layer gesture and accessibility-size tests pass.
211. Verified responsive editor-state retention at phone/tablet and desktop
     breakpoints. Android widget coverage opens a nested tool group, selects
     Bucket Fill, then crosses tablet portrait, tablet landscape, phone, and
     narrow-window sizes without replacing the canvas State or losing the
     selected tool. Desktop coverage switches to Brushes and resizes the
     window twice while retaining the canvas State and active palette. Both
     transition tests pass.
212. Replaced the in-window macOS editor menu row with Flutter's native
     `PlatformMenuBar` for production macOS desktop sessions. File/Edit/View/
     Layer/Select/Tool/Window/Help entries are generated from
     `EditorActionId`, use shared dispatch, and carry native Command-key
     shortcuts where defined. Windows/Linux retain the in-window hierarchy.
     A macOS-targeted widget test verifies native menu structure, confirms the
     redundant row is absent, and dispatches Undo through the shared action.
     Full Flutter tests pass (106), analysis is clean, and the macOS debug app
     builds. Live menu appearance remains pending restart/screenshot review.
213. Continued the shared-component audit by extracting the editor's repeated
     icon-only commands as `InkCommandButton` and migrating all toolbar and
     selection-launcher call sites away from the private `_CommandIcon` style.
     The component standardizes tooltip and screen-reader labels, selected and
     disabled states, and configurable hit targets. Tablet Simple toolbar
     actions now use 48px targets; compact desktop commands retain their dense
     layout. Added tests for semantics, selected state, activation, disabled
     behavior, and exact target sizing.
214. Fixed a long off-canvas drag reliability/performance gap in the generic
     pointer path. Rust already clips the first crossing sample and ignores
     re-entry; Flutter now stops forwarding captured moves after that crossing
     and still closes the stroke on release/cancel. Added a regression with
     100 outside moves followed by a fresh stroke. The focused pointer suite
     passes and Flutter analysis is clean. The full suite currently has five
     failures in document-action and touch-settings hit-testing tests, outside
     the pointer regression; no macOS app restart was performed.
215. Continued the reusable editor-control audit by replacing raw brush preset
     and tag `ChoiceChip`/`FilterChip` controls with `InkSelectableChip`. The
     shared component uses workspace theme tokens, bounded labels, explicit
     selected/button semantics, and a 48px default target. Added tests for its
     selected semantics, activation, and target size. Flutter analysis plus
     the component and brush-library suites pass. A real screenshot showed
     the still-running macOS app is on an older UI build, so it was not
     restarted and screenshot parity remains open.
216. Fixed the narrow-desktop command-bar overflow discovered during the live
     screenshot review. Below 1100 logical pixels, document and secondary
     actions are available from a labeled More commands menu while Undo/Redo,
     command search, Brushes, Layers, and Color remain directly visible.
     Added/updated widget interactions for the menu and all affected narrow-
     window workflows. All 110 Flutter tests pass, analysis is clean, and the
     macOS debug bundle builds. The already-running older build was not
     restarted, so screenshot verification of this new layout remains open.
217. Migrated the brush browser's core size, opacity, stabilization, pressure
     size/opacity, and pressure-response sliders to `InkPropertySlider`. The
     shared control now exposes an explicit accessible label/value and a
     configurable value column; the brush editor retains full values such as
     4096.0 px without clipping. All 110 Flutter tests pass, analysis is clean,
     and the macOS debug bundle builds. Live screenshot parity remains open
     because the running app was intentionally left untouched.
218. Extended the live-texture path to iOS: the implicit Flutter engine now
     registers the bounded IOSurface-backed texture adapter, and Flutter
     enables the shared live-surface controller on iOS as well as macOS. Rust's
     retained Metal-device/texture boundary is cfg-enabled for both Apple OSes;
     an iOS Rust cross-target build remains pending.
     `swiftc -typecheck` against the iOS Simulator SDK passed, Rust formatting,
     live-render tests (8), bridge tests (17), Flutter analysis, and the two
     live-surface adapter/controller test files passed. A full iOS build and
     physical latency check remain unverified; Android/Windows/Linux adapters
     and the Phase 3.75 GPU spatial-replacement gate are still open.
219. Reduced live-preview redraw work for ordinary confirmed dab batches. When
     every dab is new, the GPU appends only those quads with a load-preserving
     render pass; replacements, evictions, viewport changes, acknowledgement,
     and cancellation still rebuild from retained dabs to erase stale pixels.
     Added a GPU readback regression proving incremental output is byte-for-byte
     equal to a full rebuild. The live-render suite passes (9 tests), and the
     local Apple M1 Pro benchmark reports 600 frames, 1024x768 target, 299 µs
     p95 CPU prepare/submit (GPU completion and frame presentation not measured).
     A later release rerun measured append p95 199µs (3,134µs max) and
     forced-rebuild p95 241µs on Apple M1 Pro; neither run measures GPU
     completion or displayed-frame latency.
220. Finished the brush inspector's shared-control migration: advanced pressure
     curve points, tip hardness, spacing, texture scale, scatter, rotation
     jitter, smudge, and wetness now use the labeled `InkPropertySlider` with
     explicit ranges and accessible values. Disabled end points stay disabled.
     Updated the maximum-imported-texture UI test for the new label/value
     presentation. Flutter analysis is clean and the component plus brush
     library suites pass (11 tests).
221. Fixed long repeated strokes eventually losing visible dabs after brush
     changes. Several brush dabs emitted from one pointer sample shared the
     same `(stroke, sample sequence)` preview key, so later dabs replaced the
     earlier ones. Added a stable per-sample dab index to the live-dab identity
     and upgraded the bounded native packet to v3 (56-byte records); sample
     sequence remains the acknowledgement boundary. Added a long 900-sample
     spiral regression that drains batches like the runtime and checks GPU
     preview against committed CPU tiles for technical pen, pencil, and opaque
     round brushes. Pixel bounds and shape coverage stay within one pixel.
     Rust engine/live-render/bridge suites pass (61/10/17), targeted Clippy
     passes, Flutter analysis and all 256 Flutter tests pass, focused macOS and
     Android controller tests pass, and the Android debug APK plus macOS debug
     bundle build. This is local geometry/readback evidence, not a measurement
     of GPU completion or display scan-out; the end-to-end presentation gate
     remains open.
222. Corrected the Android live-texture adapter's maximum packet length from
     the old 52-byte record size to the v3 56-byte size. A full 2,048-dab
     packet was 8,192 bytes above the previous bound and could trigger native
     preview fallback on long strokes. Added exact-limit acceptance and
     one-byte-over-limit rejection coverage. The focused Android controller
     suite passes (6 tests), full Flutter analysis is clean, and the full
     Flutter suite passes (259 tests). An arm64 Android debug APK also builds
     successfully with the corrected transport bound.
223. Fixed a real completed-stroke loss path after repeated long drawing
     sessions: once the optional time-lapse recording reached its bounded
     stroke or sample limit, `EndStroke` returned an error and left the
     drawing transaction active. The document now commits strokes normally
     and simply stops appending optional time-lapse entries at the cap. Added
     a regression that fills the recording limit, draws three long spirals
     while switching brushes, then verifies their committed pixels and closed
     transactions. The focused regression, full Rust workspace tests,
     workspace Clippy with warnings denied, full Flutter analysis/tests (261),
     and macOS debug build all pass. The already-running app was not restarted,
     so live screenshot verification of the rebuilt binary remains open.
224. Made the shared Windows/Linux pixel-texture preview core transactional on
     viewport changes. It now verifies the complete redraw work budget before
     clearing the published pixels and restores the prior transform/generation
     when a viewport rebuild is rejected. Added a regression that zooms a
     retained dab set beyond the work limit and proves the last good frame
     remains intact. Declared C++17 for the Linux runner, matching the
     structured bindings and `std::clamp` used by the new sources. The
     standalone core test passes with clang++ warnings treated as errors.
     Source integration is present in both runners, but native Windows/Linux
     runner compilation and runtime texture validation remain unverified on
     this macOS host.
225. Prevented long strokes from being wholly cancelled when bounded sample or
     dab ceilings are reached. The engine preserves and commits the already
     rasterized prefix, closes the transaction, and ignores later input for
     that over-limit stroke; the next brush stroke remains usable. Added
     regressions for a dense spiral at a sample ceiling and a compiled brush at
     a low test dab ceiling followed by a brush switch. Rust workspace tests
     and warnings-denied Clippy pass. The running app was left untouched, so
     the new library code has not been exercised in that UI process.
226. Added an integration test that drives the actual Windows/Linux native
     method channel through texture registration, viewport setup, confirmed
     dab delivery, Flutter Texture composition, acknowledgement, disposal, and
     stale-ID rejection. Wired it into both native desktop CI jobs (Linux under
     Xvfb). Flutter analysis is clean and all 261 unit/widget tests pass. The
     hosted Windows/Linux integration runs are pending; local runtime execution
     is unavailable because this Mac lacks GTK development libraries and a
     Windows toolchain.
227. Added a repeated-session regression for 44 long spirals with 11 alternating
     legacy and compiled brushes. It checks a separate visible pixel after every
     commit and checks all earlier marks again at the end, guarding against
     cumulative worker, brush-state, and history failures. Corrected the pointer
     specification to match the safe-prefix behavior: work limits stop only the
     current stroke's tail and must not cancel the committed prefix or poison
     the next stroke. The focused engine test passes; user-reported loss has not
     yet been reproduced in the currently running Mac UI.
228. Hardened Flutter's serialized pointer queue with a terminal recovery
     boundary. Any unexpected async failure now attempts to cancel only the
     unfinished stroke and resolves the queue so later pointer events still
     execute. Added a widget regression that injects one transient packet
     failure and verifies the next stroke commits normally. Targeted pointer
     tests, all 262 Flutter tests, and Flutter analysis pass. The currently
     running app remains un-restarted to preserve its open canvas; rebuilt-app
     visual/runtime verification is still outstanding.
229. Added a CanvasScreen-level brush-switch stress test. It selects eight
     different presets through the professional workspace and draws a 48-step
     long mouse spiral with each, then verifies every stroke begins, ends, and
     submits pointer packets without cancellation. All 263 Flutter tests and
     Flutter analysis pass. This verifies the UI/serialization path with the
     in-memory engine; it does not replace the separate Rust persistence test
     or live native-app presentation gate.
