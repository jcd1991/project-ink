import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/bridge/engine_api.dart';
import 'package:project_ink/canvas/canvas_diagnostic_recorder.dart';
import 'package:project_ink/canvas/canvas_preview_synchronization.dart';
import 'package:project_ink/canvas/canvas_stroke_preview_actions.dart';
import 'package:project_ink/canvas/canvas_tile_synchronization.dart';
import 'package:project_ink/canvas/live_stroke_coordinator.dart';

void main() {
  test('tile synchronization snapshots copy visible layer state', () {
    final visibleLayerIds = <int>[3, 8];
    final snapshot = CanvasTileSynchronizationSnapshot(
      lastPacketMicros: 42,
      visibleRasterLayerIds: visibleLayerIds,
      strokeWorkQueueDepth: 1,
      pendingNativePacketCount: 2,
    );

    visibleLayerIds.add(13);

    expect(snapshot.visibleRasterLayerIds, <int>[3, 8]);
    expect(snapshot.lastPacketMicros, 42);
    expect(snapshot.strokeWorkQueueDepth, 1);
    expect(snapshot.pendingNativePacketCount, 2);
  });

  test('tile polling starts once and is cancelled by its owner', () async {
    final host = _TileHost();
    final synchronization = _createSynchronization(host);

    expect(synchronization.isPolling, isFalse);
    synchronization.startPolling(interval: const Duration(milliseconds: 2));
    synchronization.startPolling(interval: const Duration(milliseconds: 1));
    expect(synchronization.isPolling, isTrue);
    final readsAfterStart = host.disposedReads;

    host.isDisposed = true;
    await Future<void>.delayed(const Duration(milliseconds: 8));
    expect(host.disposedReads, greaterThan(readsAfterStart));

    synchronization.dispose();
    expect(synchronization.isPolling, isFalse);
    final readsAfterDispose = host.disposedReads;
    await Future<void>.delayed(const Duration(milliseconds: 8));
    expect(host.disposedReads, readsAfterDispose);
    synchronization.previewSynchronization.dispose();
  });

  test('engine replacement resets and retires tile cache state', () {
    final synchronization = _createSynchronization(_TileHost());
    final oldImageCache = synchronization.tileImages;
    synchronization.tileBytes.put(7, 1, 2, 3, Uint8List(4));

    synchronization.resetForEngineReplacement();

    expect(synchronization.renderRevision, 0);
    expect(synchronization.tileBytes.revision, 0);
    expect(synchronization.tileBytes.get(1, 2, 3), isNull);
    expect(synchronization.tileImages, isNot(same(oldImageCache)));
    expect(oldImageCache.isEmpty, isTrue);
    synchronization.dispose();
    synchronization.previewSynchronization.dispose();
  });
}

CanvasTileSynchronization _createSynchronization(
  CanvasTileSynchronizationHost host,
) {
  return CanvasTileSynchronization(
    host,
    diagnostics: CanvasDiagnosticRecorder.instance,
    previewSynchronization: CanvasPreviewSynchronization(),
    strokePreviewActions: _TilePreviewActions(),
    effects: CanvasTileSynchronizationEffects(
      publishCanvasState: () {},
      markVisibleUpdate:
          ({
            required int packetMicros,
            required Duration tileDecode,
            required int dirtyTiles,
            required int commitId,
            required int revision,
          }) {},
    ),
  );
}

class _TilePreviewActions implements CanvasTilePreviewActions {
  @override
  CanvasPreviewCoverage? coverageForAcknowledgement(
    StrokeAcknowledgement acknowledgement,
  ) => null;

  @override
  void advanceCoverage(Map<LiveStrokePreview, int> throughByPreview) {}

  @override
  List<LiveStrokePreview> retireCpuCoveredPreviews() =>
      const <LiveStrokePreview>[];

  @override
  void clear() {}
}

class _TileHost implements CanvasTileSynchronizationHost {
  bool isDisposed = false;
  int disposedReads = 0;

  @override
  bool get disposed {
    disposedReads++;
    return isDisposed;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
