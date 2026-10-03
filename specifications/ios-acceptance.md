# iOS and iPad acceptance runner

This local runner automates repeatable Flutter/Rust integration checks and a
small set of native iOS UI checks, then guides a person through physical Apple
Pencil acceptance. It does not turn simulator or injected input into evidence
of real Pencil behavior.

## Run it

Run from the repository root on the Mac with pinned Flutter 3.47.5:

    app/tool/run_ios_acceptance.sh --preflight
    app/tool/run_ios_acceptance.sh --simulator
    app/tool/run_ios_acceptance.sh --device DEVICE_UDID
    app/tool/run_ios_acceptance.sh --pencil DEVICE_UDID
    app/tool/run_ios_acceptance.sh --full DEVICE_UDID
    app/tool/run_ios_acceptance.sh --resume /path/to/run --full DEVICE_UDID

Full mode runs the Rust workspace and Flutter host suites, iPad simulator
integration/native UI checks, the same integration/native checks on the
connected iPad, then pauses for the physical Pencil session. Device mode runs
only connected-device automation. Pencil mode builds a launchable Profile app
using the production UIKit adapter and opens a guided checklist. Preflight
reports Xcode, Flutter, revision, local changes, scheme, and optionally device
visibility without installing or launching an app.

The shared Xcode scheme Acceptance installs as Project Ink Acceptance with
bundle identifier org.projectink.studio.acceptance. This gives it a separate
app container, recovery state, and diagnostic directory. Flutter build products
are kept in `app/build/ios-acceptance-output/`, separate from the ordinary app.
The runner uses CocoaPods integration for its private Flutter configuration so
Flutter integration tests and native XCUITest resolve the same plugin modules.
Flutter's intermediate objects still use Xcode's standard
`~/Library/Developer/Xcode/DerivedData/` cache, and the runner serializes its
build stages to prevent concurrent Xcode builds. Per-run configuration, native
Xcode DerivedData, logs, traces, and XCTest result bundles are kept under
`app/build/ios-acceptance/runs/` unless
`PROJECT_INK_IOS_ACCEPTANCE_RESULTS_DIR` selects another local directory.
PROJECT_INK_IOS_SIMULATOR_UDID selects a simulator.
PROJECT_INK_IPAD_PROFILE may be ipad-m1 or ipad-m4 if model detection fails.

Each runner invocation isolates Flutter configuration under that run directory.
Physical-device runs disable Flutter's LLDB debugging transport for the run and
use Xcode's device debugging path; this works around a CoreDevice VM-service
connection reset observed on the paired iPad. Flutter drive and Xcode test
commands have bounded timeouts and terminate their process groups on timeout.
After Flutter integration tests, XCUITest explicitly builds with
`FLUTTER_TARGET=lib/main.dart`, so a generated integration-test target cannot
leave the native UI tests launching an integration harness instead of the app.
The artifact checksum manifest excludes per-run `xcode-derived-*` build caches
but includes XCTest result bundles and test logs.

Each run records state.json, run.log, run.pid, report.md, stage logs, Xcode
result bundles, copied traces, and manually supplied memory evidence. A device
lock prevents concurrent runs on one iPad. Resume checks Git revision, tracked
diff fingerprint, Flutter version, and device before skipping completed
stages. A failed or interrupted stage runs again with fresh fixtures. Artifacts
remain local; the runner does not upload artwork or traces.

## Automated evidence

- release_document_round_trip_test.dart runs disk-backed production Rust
  bridge cases for pixel save/reopen and history, layer persistence, brush
  editing/import, comic round trips and exports, corrupt-project rejection,
  and recovery-write failures.
- live_cpu_handoff_test.dart exercises synthetic touch and native Pencil
  packet paths through rendering, confirmed-sample delivery, and CPU tile
  publication. Packet injection remains synthetic evidence.
- Swift RunnerTests verify packet bounds, malformed-input rejection, and
  native event-stream readiness. RunnerUITests checks canvas availability
  after terminating and relaunching the acceptance app and opens/dismisses the
  native project picker.

The macOS-layout ProjectInkApp recovery fixture is skipped by iOS integration
runs; keep app-level failed-provider and recovery prompt flows manual pending
until a tablet-native fixture replaces it. These checks do not automate every
visible product journey across all layer, adjustment, Files-provider, or comic workflows. The report marks uncovered
requirements as not run. A disk-backed bridge save/reopen does not prove
reopening a user-saved document through Files after a fresh process. Continue
tracking each required journey in release-readiness.md.

## Guided physical Pencil run

Use a new disposable document in Project Ink Acceptance. For each prompt, the
runner records pass, failure, or skip with a short observation:

- Pressure range and initial contact; tilt response; slow and fast curves;
  long strokes across the autosave debounce; brush/color changes; undo/redo;
  save and fresh reopen.
- Palm contact, touch navigation, cancellation/interruption, canvas edges,
  and live preview versus committed pixels.
- Pencil double tap and configured eraser action. Test hover, squeeze, and
  barrel rotation only when the iPad and Pencil support them.
- A warmed 2048×2048 latency session and a 4096×4096 document with 20 raster
  layers for memory evidence. Keep a one-hour drawing session as its own
  physical-device observation.

Run dart tools/phase1_trace_report.dart TRACE.jsonl ipad-m1 or ipad-m4. The
evaluator requires the device-specific p95 target, zero rejected confirmed
samples and sequence gaps, and the delivery schema. The trace measures the
app's input-to-post-frame path; display scan-out is outside that measurement.
Attach authoritative Instruments/Xcode RSS evidence separately. The engine's
900 MB estimate is not an app-process RSS ceiling; keep memory acceptance
pending until the project defines that device budget.

Apple's published XCTest APIs support UI and iPad pointer interactions. Its
Pencil documentation describes input received from physical Pencil hardware.
No supported XCTest API was found for synthesizing pressure, tilt, hover,
barrel rotation, double tap, or squeeze. Treat packet-injection cases as
adapter/rendering regressions and physical Pencil checks as manual acceptance.

## Reliability and evidence

The test shape follows Google's testing pyramid: extensive unit/engine
coverage, focused integration checks, and fewer complete UI journeys. Tests
use disposable inputs, accessibility identifiers, and state-based XCTest waits
instead of fixed sleeps. Keep scenarios independent. Retain failures and their
Xcode result bundles; do not turn infrastructure or cleanup failures into a
pass through silent retries.

Firebase Test Lab is outside this local workflow. The physical-device runbook
keeps artwork and traces local, while cloud execution would upload test
artifacts beyond the user's Mac.
