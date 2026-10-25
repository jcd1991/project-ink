import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/bridge/engine_api.dart';
import 'package:project_ink/canvas/canvas_diagnostic_recorder.dart';
import 'package:project_ink/canvas/canvas_preview_synchronization.dart';
import 'package:project_ink/canvas/canvas_stroke_preview_actions.dart';
import 'package:project_ink/canvas/canvas_tile_synchronization.dart';
import 'package:project_ink/canvas/live_stroke_coordinator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  test('active strokes can defer CPU tile polling until completion', () async {
    final host = _SessionHost(InMemoryEngineApi())..isStrokeActive = true;
    final synchronization = _createSynchronization(
      host,
      shouldSkipActiveStrokePolling: () => true,
    );

    synchronization.startPolling(interval: const Duration(milliseconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(host.captureSessionCount, 0);

    host.isStrokeActive = false;
    await Future<void>.delayed(const Duration(milliseconds: 8));
    expect(host.captureSessionCount, greaterThan(0));
    synchronization.dispose();
    synchronization.previewSynchronization.dispose();
  });

  test(
    'replacement during snapshot preserves the new document cache',
    () async {
      final engine = _DelayedSnapshotEngine();
      final host = _SessionHost(engine);
      final synchronization = _createSynchronization(host);
      final refresh = synchronization.refreshTiles(initial: true);
      await engine.started.future;
      host.generation++;
      synchronization.resetForEngineReplacement();
      synchronization.tileBytes.put(1, -1, 0, 0, Uint8List.fromList([99]));
      engine.pending.complete(
        CompositeTileSnapshot(
          revision: 7,
          tiles: [
            CompositeTilePixels(x: 0, y: 0, bytes: Uint8List(256 * 256 * 4)),
          ],
        ),
      );
      await refresh;
      expect(synchronization.tileBytes.get(-1, 0, 0), orderedEquals([99]));
      expect(synchronization.tileBytes.revision, 1);
      expect(synchronization.renderRevision, 0);
      synchronization.dispose();
      synchronization.previewSynchronization.dispose();
    },
  );

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
  CanvasTileSynchronizationHost host, {
  bool Function() shouldSkipActiveStrokePolling = _neverSkipActiveStrokePolling,
}) {
  return CanvasTileSynchronization(
    host,
    diagnostics: CanvasDiagnosticRecorder.instance,
    previewSynchronization: CanvasPreviewSynchronization(),
    strokePreviewActions: _TilePreviewActions(),
    shouldSkipActiveStrokePolling: shouldSkipActiveStrokePolling,
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

bool _neverSkipActiveStrokePolling() => false;

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
  bool get strokeActive => false;

  @override
  bool get isMounted => true;

  @override
  bool get disposed {
    disposedReads++;
    return isDisposed;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DelayedSnapshotEngine extends InMemoryEngineApi {
  final started = Completer<void>();
  final pending = Completer<CompositeTileSnapshot>();

  @override
  Future<TileUpdateBatch> drainTileUpdates() async => const TileUpdateBatch(
    revision: 7,
    fullRedraw: true,
    tiles: [TileUpdate(revision: 7, layer: 1, x: 0, y: 0)],
  );

  @override
  Future<CompositeTileSnapshot> readCompositeTilesSnapshot({
    required List<StrokeTileCoordinate> coordinates,
  }) {
    started.complete();
    return pending.future;
  }
}

class _SessionHost extends _TileHost {
  _SessionHost(this.engine);
  final EngineApi engine;
  int generation = 0;
  int captureSessionCount = 0;
  bool isStrokeActive = false;
  @override
  bool get strokeActive => isStrokeActive;
  @override
  CanvasTileSynchronizationSession captureSession() {
    captureSessionCount++;
    return CanvasTileSynchronizationSession(
      engine: engine,
      generation: generation,
    );
  }

  @override
  bool isSessionCurrent(CanvasTileSynchronizationSession session) =>
      !isDisposed &&
      identical(session.engine, engine) &&
      session.generation == generation;
  @override
  CanvasTileSynchronizationSnapshot captureSnapshot() =>
      CanvasTileSynchronizationSnapshot(
        lastPacketMicros: null,
        visibleRasterLayerIds: [1],
        strokeWorkQueueDepth: 0,
        pendingNativePacketCount: 0,
      );
}
