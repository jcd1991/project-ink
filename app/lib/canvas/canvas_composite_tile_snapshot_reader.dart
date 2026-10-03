import 'dart:math' as math;
import 'dart:typed_data';

import '../bridge/engine_api.dart';

typedef CompositeTileSnapshotPartObserver =
    void Function({
      required int partIndex,
      required int partCount,
      required int tileCount,
    });

/// A revision-consistent set of composite tile pixels read from Rust.
class CanvasCompositeTileSnapshot {
  CanvasCompositeTileSnapshot({
    required this.revision,
    required this.isCoherent,
    required Map<String, Uint8List> pixels,
    required this.partCount,
    required this.elapsedMicroseconds,
  }) : pixels = Map<String, Uint8List>.unmodifiable(pixels);

  final int? revision;
  final bool isCoherent;
  final Map<String, Uint8List> pixels;
  final int partCount;
  final int elapsedMicroseconds;
}

/// Reads bounded composite-tile batches and rejects cross-revision mixtures.
class CanvasCompositeTileSnapshotReader {
  const CanvasCompositeTileSnapshotReader();

  Future<CanvasCompositeTileSnapshot> read({
    required EngineApi engine,
    required List<StrokeTileCoordinate> coordinates,
    required CompositeTileSnapshotPartObserver onPartStarted,
  }) async {
    final partCount =
        (coordinates.length + maxCompositeTileSnapshotTiles - 1) ~/
        maxCompositeTileSnapshotTiles;
    final pixels = <String, Uint8List>{};
    final clock = Stopwatch()..start();
    int? revision;
    var isCoherent = true;

    for (var partIndex = 0; partIndex < partCount; partIndex++) {
      final start = partIndex * maxCompositeTileSnapshotTiles;
      final end = math.min(
        start + maxCompositeTileSnapshotTiles,
        coordinates.length,
      );
      onPartStarted(
        partIndex: partIndex,
        partCount: partCount,
        tileCount: end - start,
      );
      final part = await engine.readCompositeTilesSnapshot(
        coordinates: coordinates.sublist(start, end),
      );
      if (revision != null && revision != part.revision) {
        isCoherent = false;
        break;
      }
      revision = part.revision;
      for (final tile in part.tiles) {
        pixels['${tile.x}:${tile.y}'] = tile.bytes;
      }
    }

    clock.stop();
    if (!isCoherent) pixels.clear();
    return CanvasCompositeTileSnapshot(
      revision: revision,
      isCoherent: isCoherent,
      pixels: pixels,
      partCount: partCount,
      elapsedMicroseconds: clock.elapsedMicroseconds,
    );
  }
}
