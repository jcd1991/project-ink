import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/bridge/engine_api.dart';
import 'package:project_ink/canvas/canvas_composite_tile_snapshot_reader.dart';

void main() {
  test(
    'reads coordinates in bounded parts and keeps one coherent revision',
    () async {
      final engine = _SnapshotEngine(revisions: [7, 7]);
      final partSizes = <int>[];
      final coordinates = List<StrokeTileCoordinate>.generate(
        maxCompositeTileSnapshotTiles + 1,
        (index) => StrokeTileCoordinate(index, 0),
      );

      final snapshot = await const CanvasCompositeTileSnapshotReader().read(
        engine: engine,
        coordinates: coordinates,
        onPartStarted: ({
          required partIndex,
          required partCount,
          required tileCount,
        }) {
          expect(partIndex, partSizes.length);
          expect(partCount, 2);
          partSizes.add(tileCount);
        },
      );

      expect(snapshot.isCoherent, isTrue);
      expect(snapshot.revision, 7);
      expect(snapshot.partCount, 2);
      expect(partSizes, [maxCompositeTileSnapshotTiles, 1]);
      expect(engine.readCount, 2);
    },
  );

  test('rejects tile pixels read from different revisions', () async {
    final engine = _SnapshotEngine(
      revisions: [7, 8],
      firstPartTiles: [
        CompositeTilePixels(x: 0, y: 0, bytes: Uint8List.fromList([1])),
      ],
    );
    final coordinates = List<StrokeTileCoordinate>.generate(
      maxCompositeTileSnapshotTiles + 1,
      (index) => StrokeTileCoordinate(index, 0),
    );

    final snapshot = await const CanvasCompositeTileSnapshotReader().read(
      engine: engine,
      coordinates: coordinates,
      onPartStarted:
          ({required partIndex, required partCount, required tileCount}) {},
    );

    expect(snapshot.isCoherent, isFalse);
    expect(snapshot.revision, 7);
    expect(snapshot.pixels, isEmpty);
    expect(engine.readCount, 2);
  });

  test('empty tile lists do not call the engine', () async {
    final engine = _SnapshotEngine(revisions: const []);
    final snapshot = await const CanvasCompositeTileSnapshotReader().read(
      engine: engine,
      coordinates: const [],
      onPartStarted: ({
        required partIndex,
        required partCount,
        required tileCount,
      }) {
        fail('there is no snapshot part');
      },
    );

    expect(snapshot.isCoherent, isTrue);
    expect(snapshot.revision, isNull);
    expect(snapshot.partCount, 0);
    expect(snapshot.pixels, isEmpty);
    expect(engine.readCount, 0);
  });
}

class _SnapshotEngine extends InMemoryEngineApi {
  _SnapshotEngine({required this.revisions, this.firstPartTiles = const []});

  final List<int> revisions;
  final List<CompositeTilePixels> firstPartTiles;
  int readCount = 0;

  @override
  Future<CompositeTileSnapshot> readCompositeTilesSnapshot({
    required List<StrokeTileCoordinate> coordinates,
  }) async {
    final index = readCount++;
    return CompositeTileSnapshot(
      revision: revisions[index],
      tiles: index == 0 ? firstPartTiles : const [],
    );
  }
}
