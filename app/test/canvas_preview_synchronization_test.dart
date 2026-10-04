import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/bridge/engine_api.dart';
import 'package:project_ink/canvas/canvas_diagnostic_recorder.dart';
import 'package:project_ink/canvas/canvas_preview_synchronization.dart';
import 'package:project_ink/canvas/live_preview_controller.dart';
import 'package:project_ink/canvas/live_stroke_coordinator.dart';
import 'package:project_ink/canvas/performance_trace.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('engine replacement resets preview commit handoff state', () {
    final synchronization = CanvasPreviewSynchronization();
    synchronization.awaitingPreviewCommit = true;
    synchronization.lastPublishedPreviewAcknowledgement = StrokeAcknowledgement(
      stroke: BigInt.parse('1'),
      highestCommittedSequence: 3,
      revision: 4,
      minTileX: 0,
      minTileY: 0,
      maxTileX: 0,
      maxTileY: 0,
    );

    synchronization.resetStrokeCommitState();

    expect(synchronization.awaitingPreviewCommit, isFalse);
    expect(synchronization.lastPublishedPreviewAcknowledgement, isNull);
    synchronization.dispose();
  });

  test(
    'owns frame invalidation and detaches before retiring the surface',
    () async {
      final synchronization = CanvasPreviewSynchronization();
      final surface = _FakeLivePreviewController();
      synchronization.configureSurface(
        engine: InMemoryEngineApi(),
        targetPlatform: null,
        factory: (_) => surface,
        diagnostics: CanvasDiagnosticRecorder.instance,
        performanceTrace: Phase1PerformanceTrace(),
        hasPerformanceSnapshot: false,
        disableIpadDabRenderer: false,
      );
      synchronization.setStrokePreview(_preview());

      surface.gpuFrameReady.value = true;

      expect(synchronization.strokePreview.value?.revision, 1);
      expect(synchronization.surface, same(surface));

      final disposal = synchronization.detachSurface();
      expect(synchronization.surface, isNull);
      await disposal;
      expect(synchronization.strokePreview.value?.revision, 1);
      expect(surface.disposeCount, 1);

      synchronization.dispose();
    },
  );

  test(
    'dispose clears the preview and retires the surface exactly once',
    () async {
      final synchronization = CanvasPreviewSynchronization();
      final surface = _FakeLivePreviewController();
      synchronization.configureSurface(
        engine: InMemoryEngineApi(),
        targetPlatform: null,
        factory: (_) => surface,
        diagnostics: CanvasDiagnosticRecorder.instance,
        performanceTrace: Phase1PerformanceTrace(),
        hasPerformanceSnapshot: false,
        disableIpadDabRenderer: false,
      );
      synchronization.setStrokePreview(_preview());

      synchronization.dispose();
      await synchronization.pendingSurfaceDisposal;

      expect(surface.disposeCount, 1);
      expect(synchronization.surface, isNull);
      expect(synchronization.strokePreview.value, isNull);
    },
  );
}

LiveStrokePreview _preview() => LiveStrokePreview(
  color: const Color(0xff000000),
  width: 2,
  pressureSize: 0,
  documentWidth: 100,
  documentHeight: 100,
  eraser: false,
  points: const <LiveStrokePreviewPoint>[],
  chunks: const <LiveStrokePreviewChunk>[],
);

class _FakeLivePreviewController implements LivePreviewController {
  @override
  final ValueNotifier<bool> gpuFrameReady = ValueNotifier<bool>(false);

  @override
  final ValueNotifier<int?> textureId = ValueNotifier<int?>(null);

  int disposeCount = 0;

  @override
  void markInputPending({bool strokeStart = false}) {}

  @override
  void synchronizeViewport({
    required Size viewportSize,
    required double devicePixelRatio,
    required Offset pan,
    required double scale,
    required double rotation,
    required bool mirrored,
    required int documentWidth,
    required int documentHeight,
  }) {}

  @override
  void pump() {}

  @override
  Future<void> acknowledge(StrokeAcknowledgement acknowledgement) async {}

  @override
  Future<void> cancelAllStrokes() async {}

  @override
  Future<void> dispose() async {
    disposeCount++;
    gpuFrameReady.dispose();
    textureId.dispose();
  }
}
