# Phase 5 physical-device acceptance

This runbook validates the parts that simulator and host builds cannot prove:
stylus delivery, coalesced/history samples, visible-update latency, and process
RSS. It is intentionally deferred until Phase 5, after the implementation is
memory-stable enough for dedicated external runs. It is local-only; do not
upload traces or documents.

## Prepare the app

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
