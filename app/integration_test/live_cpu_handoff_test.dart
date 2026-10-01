import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:project_ink/bridge/engine_api.dart';
import 'package:project_ink/canvas/canvas_diagnostic_recorder.dart';
import 'package:project_ink/canvas/pointer_packet.dart';
import 'package:project_ink/canvas/canvas_screen.dart';
import 'package:project_ink/comics/comic_workspace.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('long touch spiral publishes authoritative CPU tiles', (
    tester,
  ) async {
    final engine = await FrbEngineApi.create(
      widthPx: 1024,
      heightPx: 1024,
      dpi: 144,
    );
    final recorder = CanvasDiagnosticRecorder.instance;
    await recorder.startCapture(
      metadata: <String, Object?>{
        'scenario': 'integration_long_touch_spiral_cpu_handoff',
        'inputSource': 'flutter_integration_test',
        'documentWidth': engine.documentInfo.widthPx,
        'documentHeight': engine.documentInfo.heightPx,
      },
    );
    String? tracePath;

    try {
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasScreen(
            engine: engine,
            targetPlatform:
                Platform.isIOS ? TargetPlatform.iOS : TargetPlatform.macOS,
            // The canvas builds its comic workspace alongside illustration
            // controls. Keep that unrelated workspace from rebinding this
            // test's fresh raster document to its sample comic page.
            comicWorkspaceController: ComicWorkspaceController(),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));

      final canvas = find.bySemanticsLabel('Drawing canvas');
      expect(canvas, findsOneWidget);
      final bounds = tester.getRect(canvas);
      final center = bounds.center;
      final maxRadius = math.min(bounds.width, bounds.height) * 0.32;
      // The test spiral is centered in the document and stays within these
      // four tiles. Keep a byte-level baseline so the test proves that the
      // authoritative composite raster changed, not only that Rust emitted
      // an acknowledgement or Flutter retired its live overlay.
      const tileCoordinates = <(int, int)>[(1, 1), (2, 1), (1, 2), (2, 2)];
      final initialTileHashes = <String, int>{};
      for (final (x, y) in tileCoordinates) {
        initialTileHashes['$x:$y'] = _fnv1a32(
          await engine.readCompositeTile(x: x, y: y),
        );
      }
      final gesture = await tester.startGesture(
        center,
        kind: PointerDeviceKind.touch,
      );
      const sampleCount = 720;
      for (var index = 1; index <= sampleCount; index++) {
        final progress = index / sampleCount;
        final angle = progress * math.pi * 10;
        final radius = maxRadius * progress;
        await gesture.moveTo(
          center + Offset(math.cos(angle) * radius, math.sin(angle) * radius),
        );
        if (index % 4 == 0) {
          await tester.pump(const Duration(milliseconds: 16));
        }
      }
      await gesture.up();

      // Give serialized Rust input, tile polling, immutable snapshot decoding,
      // and the coverage-aware preview handoff time to finish.
      for (var frame = 0; frame < 30; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(engine.revision, greaterThan(0));
      final changedCompositeTiles = <String>[];
      for (final (x, y) in tileCoordinates) {
        final key = '$x:$y';
        final finalHash = _fnv1a32(await engine.readCompositeTile(x: x, y: y));
        if (finalHash != initialTileHashes[key]) {
          changedCompositeTiles.add(key);
        }
      }
      debugPrint(
        'LIVE_CPU_RASTER_METRICS ${jsonEncode(<String, Object?>{'changedCompositeTiles': changedCompositeTiles, 'candidateTileCount': tileCoordinates.length})}',
      );
      expect(
        changedCompositeTiles,
        isNotEmpty,
        reason:
            'the Rust CPU raster must change composite pixels for the spiral',
      );
      expect(tester.takeException(), isNull);
    } finally {
      tracePath = await recorder.stopCapture(reason: 'integration_test');
      await tester.pumpWidget(const SizedBox.shrink());
      await engine.close();
    }

    expect(tracePath, isNotNull);
    final events = (await File(tracePath!).readAsLines())
        .where((line) => line.isNotEmpty)
        .map((line) => jsonDecode(line) as Map<String, dynamic>)
        .toList(growable: false);
    final liveInputs = events
        .where((event) => event['type'] == 'canvas.live_input_accepted')
        .toList(growable: false);
    final snapshots = events
        .where((event) => event['type'] == 'canvas.cpu_commit_pixel_snapshot')
        .toList(growable: false);
    final publishedHandoffs = events
        .where(
          (event) =>
              event['type'] == 'canvas.cpu_commit_handoff' &&
              event['hasPublishedPixels'] == true &&
              (event['previewIndex'] as int? ?? -1) >= 0,
        )
        .toList(growable: false);
    final retiredPreviews = events
        .where((event) => event['type'] == 'canvas.live_preview_retired')
        .toList(growable: false);
    final cpuFramesWithCoverage = events
        .where(
          (event) =>
              event['type'] == 'canvas.cpu_frame_presented' &&
              event['cpuCoveragePreviewIndex'] is int,
        )
        .toList(growable: false);
    final batchesWithStrokeMetrics = events
        .where(
          (event) =>
              event['type'] == 'canvas.cpu_commit_batch_received' &&
              event['strokeMetrics'] is List &&
              (event['strokeMetrics'] as List).isNotEmpty,
        )
        .toList(growable: false);
    final terminalStrokeMetrics =
        batchesWithStrokeMetrics.isEmpty
            ? const <String, dynamic>{}
            : (batchesWithStrokeMetrics.last['strokeMetrics'] as List).last
                as Map<String, dynamic>;
    final lastAcceptedPreviewIndex = liveInputs.fold<int>(
      -1,
      (last, event) =>
          math.max(last, event['confirmedPreviewIndexEnd'] as int? ?? -1),
    );
    final lastPublishedPreviewIndex = publishedHandoffs.fold<int>(
      -1,
      (last, event) => math.max(last, event['previewIndex'] as int),
    );
    debugPrint(
      'LIVE_CPU_HANDOFF_METRICS ${jsonEncode(<String, Object?>{'traceEvents': events.length, 'liveInputPackets': liveInputs.length, 'lastAcceptedPreviewIndex': lastAcceptedPreviewIndex, 'cpuCommitBatches': events.where((event) => event['type'] == 'canvas.cpu_commit_batch_received').length, 'cpuPixelSnapshots': snapshots.length, 'publishedHandoffs': publishedHandoffs.length, 'lastPublishedPreviewIndex': lastPublishedPreviewIndex, 'cpuFramesWithCoverage': cpuFramesWithCoverage.length, 'lastCpuFrameCoverage': cpuFramesWithCoverage.isEmpty ? -1 : cpuFramesWithCoverage.last['cpuCoveragePreviewIndex'], 'retiredPreviewFrames': retiredPreviews.length, 'strokeMetricBatches': batchesWithStrokeMetrics.length, 'terminalConfirmedSamples': terminalStrokeMetrics['confirmedSampleCount'], 'terminalWorkSegments': terminalStrokeMetrics['workSegments'], 'terminalWorkLimitReached': terminalStrokeMetrics['workLimitReached'], 'finalRevision': engine.revision})}',
    );
    expect(
      events.any((event) => event['type'] == 'canvas.live_input_accepted'),
      isTrue,
      reason: 'the synthetic touch spiral must reach the live path',
    );
    expect(
      events.any(
        (event) => event['type'] == 'canvas.cpu_commit_batch_received',
      ),
      isTrue,
      reason: 'Rust must acknowledge a committed CPU tile batch',
    );
    expect(
      events.any(
        (event) => event['type'] == 'canvas.cpu_commit_pixel_snapshot',
      ),
      isTrue,
      reason: 'CPU tile pixels must be read from a coherent revision',
    );
    expect(
      events.any(
        (event) =>
            event['type'] == 'canvas.cpu_commit_handoff' &&
            event['hasPublishedPixels'] == true &&
            (event['previewIndex'] as int? ?? -1) >= 0,
      ),
      isTrue,
      reason: 'published CPU coverage must retire the matching live prefix',
    );
    expect(
      lastPublishedPreviewIndex,
      greaterThanOrEqualTo(lastAcceptedPreviewIndex),
      reason:
          'the terminal CPU tile publication must replace the entire confirmed live stroke',
    );
    expect(
      retiredPreviews,
      isNotEmpty,
      reason:
          'the live preview must actually disappear on a frame after its final CPU pixels are published',
    );
    expect(
      retiredPreviews.last['previewIndex'],
      lastAcceptedPreviewIndex,
      reason: 'the retired overlay must cover the final accepted input point',
    );
    expect(
      cpuFramesWithCoverage,
      isNotEmpty,
      reason: 'a Flutter frame must present the authoritative CPU tile update',
    );
    expect(
      cpuFramesWithCoverage.last['cpuCoveragePreviewIndex'],
      lastAcceptedPreviewIndex,
      reason:
          'the CPU-presented frame must cover the final accepted input point',
    );
    expect(
      batchesWithStrokeMetrics,
      isNotEmpty,
      reason:
          'Rust stroke metrics must be present in the saved diagnostic trace',
    );
    expect(terminalStrokeMetrics['confirmedSampleCount'], greaterThan(0));
    expect(terminalStrokeMetrics['pathLength'], greaterThan(0));
    expect(terminalStrokeMetrics['cpuTilesWritten'], greaterThan(0));
    expect(terminalStrokeMetrics['workLimitReached'], isFalse);
  });

  testWidgets('native Pencil packet spiral publishes authoritative CPU tiles', (
    tester,
  ) async {
    final engine = await FrbEngineApi.create(
      widthPx: 1024,
      heightPx: 1024,
      dpi: 144,
    );
    final packets = StreamController<Uint8List>.broadcast();
    addTearDown(packets.close);
    final recorder = CanvasDiagnosticRecorder.instance;
    await recorder.startCapture(
      metadata: <String, Object?>{
        'scenario': 'integration_native_pencil_spiral_cpu_handoff',
        'inputSource': 'ios_native_packet_override',
        'documentWidth': engine.documentInfo.widthPx,
        'documentHeight': engine.documentInfo.heightPx,
      },
    );
    String? tracePath;

    try {
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasScreen(
            engine: engine,
            targetPlatform:
                Platform.isIOS ? TargetPlatform.iOS : TargetPlatform.macOS,
            nativePointerPacketsOverride: packets.stream,
            comicWorkspaceController: ComicWorkspaceController(),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));

      final canvas = find.bySemanticsLabel('Drawing canvas');
      expect(canvas, findsOneWidget);
      final bounds = tester.getRect(canvas);
      final center = bounds.center;
      final maxRadius = math.min(bounds.width, bounds.height) * 0.32;
      const tileCoordinates = <(int, int)>[(1, 1), (2, 1), (1, 2), (2, 2)];
      final initialTileHashes = <String, int>{};
      for (final (x, y) in tileCoordinates) {
        initialTileHashes['$x:$y'] = _fnv1a32(
          await engine.readCompositeTile(x: x, y: y),
        );
      }

      packets.add(
        _nativeStylusPacket(<Uint8List>[
          _stylusSample(
            phase: InkPointerPhase.down,
            position: center,
            pressure: 0.35,
            timestampNs: 1,
            sequence: 1,
            flags: inkPointerActual,
          ),
        ]),
      );
      await tester.pump(const Duration(milliseconds: 16));

      const sampleCount = 720;
      const packetSampleLimit = 128;
      for (var first = 1; first <= sampleCount; first += packetSampleLimit) {
        final end = math.min(first + packetSampleLimit - 1, sampleCount);
        final samples = <Uint8List>[];
        for (var index = first; index <= end; index++) {
          final progress = index / sampleCount;
          final angle = progress * math.pi * 10;
          final radius = maxRadius * progress;
          samples.add(
            _stylusSample(
              phase:
                  index == sampleCount
                      ? InkPointerPhase.up
                      : InkPointerPhase.move,
              position:
                  center +
                  Offset(math.cos(angle) * radius, math.sin(angle) * radius),
              pressure: 0.2 + 0.6 * progress,
              timestampNs: index * 1_000_000,
              sequence: index + 1,
              flags: inkPointerCoalesced,
            ),
          );
        }
        packets.add(_nativeStylusPacket(samples));
        await tester.pump(const Duration(milliseconds: 16));
      }

      for (var frame = 0; frame < 30; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final changedCompositeTiles = <String>[];
      for (final (x, y) in tileCoordinates) {
        final key = '$x:$y';
        final finalHash = _fnv1a32(await engine.readCompositeTile(x: x, y: y));
        if (finalHash != initialTileHashes[key]) {
          changedCompositeTiles.add(key);
        }
      }

      expect(changedCompositeTiles, isNotEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      tracePath = await recorder.stopCapture(reason: 'integration_test');
      await tester.pumpWidget(const SizedBox.shrink());
      await engine.close();
    }

    expect(tracePath, isNotNull);
    final events = (await File(tracePath!).readAsLines())
        .where((line) => line.isNotEmpty)
        .map((line) => jsonDecode(line) as Map<String, dynamic>)
        .toList(growable: false);
    final liveInputs = events
        .where(
          (event) =>
              event['type'] == 'canvas.live_input_accepted' &&
              event['device'] == 'apple_pencil',
        )
        .toList(growable: false);
    final handoffs = events
        .where(
          (event) =>
              event['type'] == 'canvas.cpu_commit_handoff' &&
              event['hasPublishedPixels'] == true &&
              (event['previewIndex'] as int? ?? -1) >= 0,
        )
        .toList(growable: false);
    final retired = events
        .where((event) => event['type'] == 'canvas.live_preview_retired')
        .toList(growable: false);
    final cpuFrames = events
        .where(
          (event) =>
              event['type'] == 'canvas.cpu_frame_presented' &&
              event['cpuCoveragePreviewIndex'] is int,
        )
        .toList(growable: false);
    final metricBatches = events
        .where(
          (event) =>
              event['type'] == 'canvas.cpu_commit_batch_received' &&
              event['strokeMetrics'] is List &&
              (event['strokeMetrics'] as List).isNotEmpty,
        )
        .toList(growable: false);
    final terminalMetrics =
        metricBatches.isEmpty
            ? const <String, dynamic>{}
            : (metricBatches.last['strokeMetrics'] as List).last
                as Map<String, dynamic>;
    final acceptedThrough = liveInputs.fold<int>(
      -1,
      (last, event) =>
          math.max(last, event['confirmedPreviewIndexEnd'] as int? ?? -1),
    );
    final publishedThrough = handoffs.fold<int>(
      -1,
      (last, event) => math.max(last, event['previewIndex'] as int),
    );
    debugPrint(
      'NATIVE_PENCIL_CPU_HANDOFF_METRICS ${jsonEncode(<String, Object?>{'liveInputBatches': liveInputs.length, 'acceptedThrough': acceptedThrough, 'publishedHandoffs': handoffs.length, 'publishedThrough': publishedThrough, 'cpuFrames': cpuFrames.length, 'retiredPreviews': retired.length, 'cpuTilesWritten': terminalMetrics['cpuTilesWritten'], 'confirmedSampleCount': terminalMetrics['confirmedSampleCount'], 'pathLength': terminalMetrics['pathLength'], 'workLimitReached': terminalMetrics['workLimitReached']})}',
    );
    expect(liveInputs, isNotEmpty);
    expect(acceptedThrough, greaterThan(0));
    expect(publishedThrough, greaterThanOrEqualTo(acceptedThrough));
    expect(cpuFrames.last['cpuCoveragePreviewIndex'], acceptedThrough);
    expect(retired, isNotEmpty);
    expect(retired.last['previewIndex'], acceptedThrough);
    expect(terminalMetrics['confirmedSampleCount'], greaterThan(0));
    expect(terminalMetrics['cpuTilesWritten'], greaterThan(0));
    expect(terminalMetrics['workLimitReached'], isFalse);
  });
}

Uint8List _nativeStylusPacket(List<Uint8List> samples) {
  final packet = Uint8List(4 + samples.length * 48);
  final data = ByteData.sublistView(packet);
  data.setUint16(0, 1, Endian.little);
  data.setUint16(2, samples.length, Endian.little);
  for (var index = 0; index < samples.length; index++) {
    packet.setRange(4 + index * 48, 4 + (index + 1) * 48, samples[index], 4);
  }
  return packet;
}

Uint8List _stylusSample({
  required InkPointerPhase phase,
  required Offset position,
  required double pressure,
  required int timestampNs,
  required int sequence,
  required int flags,
}) => encodePointerPacket(
  pointerId: 7,
  device: InkPointerDevice.stylus,
  phase: phase,
  x: position.dx,
  y: position.dy,
  pressure: pressure,
  timestampNs: timestampNs,
  sequence: sequence,
  flags: flags,
);

int _fnv1a32(List<int> bytes) {
  var hash = 0x811c9dc5;
  for (final byte in bytes) {
    hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
  }
  return hash;
}
