# Phase 5 physical-device acceptance

For local iOS automation plus the guided physical Pencil flow, use
specifications/ios-acceptance.md. The Acceptance scheme has a separate bundle
identifier and app data container; disposable files belong in that app.

This runbook validates the parts that simulator and host builds cannot prove:
stylus delivery, coalesced/history samples, visible-update latency, and process
RSS. It is intentionally deferred until Phase 5, after the implementation is
memory-stable enough for dedicated external runs. It is local-only; do not
upload traces or documents.

## Prepare the app

The CUA bridge controls desktop applications and does not send touch or Pencil
input to iPadOS. For brush rendering on a physical iPad, use the integration
gallery from `app/` with local `.brush` and `.sut` fixtures:

```sh
./tool/run_brush_device_gallery.sh DEVICE_UDID /path/to/sample.brush /path/to/sample.sut
```

It copies fixture files to a dedicated directory in the app container,
imports them into a fresh disposable Rust document, draws a synthetic
pressure-changing touch stroke for each imported brush, asserts that committed
Rust pixels changed, and saves a screenshot under
`app/build/brush-device-gallery/`. The helper snapshots the launchable Profile
app before the test build and reinstalls that snapshot afterward, because
`flutter drive --profile` may replace Flutter's shared Profile output with the
integration-test runner. It leaves the user's active artwork untouched.
Synthetic pressure does not validate Apple Pencil pressure, tilt,
hover, latency, or brush feel; perform those checks manually with the Pencil.
The first run may require trusting the Apple Development identity in iPad
Settings → General → VPN & Device Management before Xcode can launch its
integration-test app.

Build or run the app with the opt-in trace flag. Normal builds leave tracing
disabled and create no trace file:

```sh
flutter run -d DEVICE_ID --dart-define=PROJECT_INK_TRACE=true
```

The app creates a separate timestamped file under its app Documents
`phase1-traces/` directory. Keep a separate run for each device and start from
a new document. The recorder writes newline-delimited JSON after each visible
update. Where the native performance channel is available, each record also
carries a diagnostic `rss_bytes` sample: task resident size on Apple
platforms and an Android PSS estimate. Treat platform memory tools as
authoritative. Each record also reports `confirmed_sample_count`,
`predicted_sample_count`, `input_sequence_gap_count`,
`rejected_packet_count`, and `rejected_confirmed_sample_count`.

Use a representative 4096×4096 document with 20 ordinary raster layers for the
memory run, then a smaller 2048×2048 document for latency practice. Draw the
same recorded-stroke fixture before collecting freehand samples so the canvas
and tile cache are warm.

## Install and collect

For a disposable Android device run, keep recovery documents in a separate
app-private directory by supplying an absolute path in a non-release build:

```sh
flutter build apk --profile --target-platform android-arm64 \
  --dart-define=PROJECT_INK_TEST_DOCUMENTS_PATH=/data/user/0/org.projectink.studio/files/ProjectInkAlphaValidation/android-s23
```

Profile and debug builds honor this override; release builds ignore it. Use a
new directory for each run. Do not point it at an existing project or the
normal app documents directory.

Android:

```sh
flutter build apk --debug --target-platform android-arm64 \
  --dart-define=PROJECT_INK_TRACE=true
adb install -r app/build/app/outputs/flutter-apk/app-debug.apk
adb shell dumpsys meminfo org.projectink.studio > android-meminfo.txt
```

After the run, list and copy the trace from the app sandbox (the exact file
name is printed by the app):

```sh
adb shell run-as org.projectink.studio find files -path '*phase1-traces/*.jsonl'
adb exec-out run-as org.projectink.studio cat files/phase1-traces/TRACE.jsonl > phase1.jsonl
```

Collect `dumpsys meminfo` immediately after the 4096×4096/20-layer scenario and
again after a one-hour drawing session. Keep the trace file with the run ID.

iOS/iPadOS:

```sh
flutter build ios --debug --no-codesign \
  --dart-define=PROJECT_INK_TRACE=true
```

For a physical device, install through Xcode using the free Personal Team and
the device's trusted developer profile. For a simulator-only smoke check:

```sh
xcrun simctl install DEVICE_UDID app/build/ios/iphonesimulator/Runner.app
xcrun simctl launch DEVICE_UDID org.projectink.studio
```

Capture memory with Instruments Allocations/Memory Graph or the Xcode device
report while repeating the same scenario. Simulator results are build/startup
evidence only and must not be reported as Pencil latency.

After an iOS run, use Xcode's Devices and Simulators window to download the
application container and copy `Documents/phase1-traces/*.jsonl` to the
repository root. The app prints the timestamped file name at startup.

macOS, Windows, and Linux:

```sh
flutter run -d macos --dart-define=PROJECT_INK_TRACE=true
# or use -d windows / -d linux on the corresponding host
```

Copy the printed JSONL path to the repository root after the run. Use the
platform process monitor alongside the trace for memory evidence, and repeat
the same save/reopen scenario with a Wacom, Huion, or XP-Pen tablet where
available. A desktop trace or process monitor does not replace the hosted
Windows/Linux build lanes.

## Shared Illustration Panel tool

Run this interaction pass on iOS/iPadOS, macOS, and Android, in both Simple and
Studio layouts. Start from a saved illustration containing visible strokes.
Apply each 2-, 3-, and 4-panel preset on a blank panel map; use one-finger drag
to split a frame; drag an existing gutter; then change Gutter and Border.
Switch to a drawing tool and confirm guides remain visible while new strokes
stay on their raster layer. Undo and redo each panel operation, save, close,
and reopen. Confirm the original and new strokes are intact and panel geometry,
gutter, and border values return exactly. Repeat the pointer gestures with
touch and stylus where supported, checking that divider handles stay within
comfortable reach and input follows the visible contact point.

Record the OS/device, layout mode, input type, save path, and any pointer offset
or geometry/history mismatch. A successful build or simulator/emulator launch
checks platform compilation only; it does not complete this interaction pass.

### Sidecar limitation

An iPad used through macOS Sidecar is useful as a smoke test for the macOS
`NSEvent`/tablet path, including basic Apple Pencil contact and app layout. It
does not validate the iPadOS UIKit adapter, coalesced/predicted touch delivery,
Pencil Pro squeeze/hover/rotation semantics, iPad display scheduling, or the
physical iPad latency targets. Record Sidecar runs as macOS input evidence and
still perform the direct iPadOS run for Apple Pencil acceptance.

## Evaluate the trace

Copy the JSONL file to the repository root and run:

```sh
dart tools/phase1_trace_report.dart phase1.jsonl ipad-m1
dart tools/phase1_trace_report.dart phase1.jsonl ipad-m4
dart tools/phase1_trace_report.dart phase1.jsonl android-s23
```

The evaluator uses the worst complete recorded p95 and fails if any confirmed
sample was rejected or if any native input sequence gap was observed.
Acceptance targets are:

| Device | Target |
| --- | ---: |
| iPad Pro M1 + Apple Pencil 2 | ≤40 ms |
| iPad Pro M4 + Apple Pencil Pro | ≤25 ms |
| Galaxy S23 Ultra + S Pen | ≤40 ms |
| Samsung Android tablet | no dropped confirmed samples |

The report's `acceptance_pass` must be true. `target_pass` covers the latency
target; `confirmed_sample_delivery_pass` covers sequence gaps and rejected
confirmed samples; `confirmed_delivery_schema_present` must also be true so
older traces cannot pass by omission. A physical run must also attach
authoritative RSS evidence.

Record the exact OS version, app/Rust revision, document dimensions, layer
count, brush preset, sample count, trace path, p95 result, and RSS evidence.
Mark the device accepted only when both the input/latency target and the
memory ceiling are evidenced. A simulator launch, APK installation, or green
Flutter test is not a substitute for this record.
