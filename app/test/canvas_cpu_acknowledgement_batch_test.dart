import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/bridge/engine_api.dart';
import 'package:project_ink/canvas/canvas_cpu_acknowledgement_batch.dart';

void main() {
  test('deduplicates shared dirty tiles and keeps the newest revision', () {
    final first = _acknowledgement(
      stroke: 1,
      revision: 4,
      tiles: const [StrokeTileCoordinate(0, 0), StrokeTileCoordinate(1, 0)],
    );
    final second = _acknowledgement(
      stroke: 1,
      revision: 7,
      tiles: const [StrokeTileCoordinate(1, 0), StrokeTileCoordinate(2, 0)],
    );

    final batch = CanvasCpuAcknowledgementBatch.plan(
      pending: [first, second],
      maxTileCount: 3,
    );

    expect(batch.acknowledgements, [first, second]);
    expect(batch.coordinates.keys, unorderedEquals(['0:0', '1:0', '2:0']));
    expect(batch.tileRevisions['1:0'], 7);
    expect(batch.hasDeferredAcknowledgements, isFalse);
  });

  test(
    'defers later acknowledgements rather than splitting a commit group',
    () {
      final first = _acknowledgement(
        stroke: 1,
        revision: 4,
        tiles: const [StrokeTileCoordinate(0, 0), StrokeTileCoordinate(1, 0)],
      );
      final second = _acknowledgement(
        stroke: 2,
        revision: 5,
        tiles: const [StrokeTileCoordinate(2, 0), StrokeTileCoordinate(3, 0)],
      );

      final batch = CanvasCpuAcknowledgementBatch.plan(
        pending: [first, second],
        maxTileCount: 2,
      );

      expect(batch.acknowledgements, [first]);
      expect(batch.coordinates.length, 2);
      expect(batch.hasDeferredAcknowledgements, isTrue);
      expect(batch.oversizedAcknowledgement, isNull);
    },
  );

  test('allows one oversized acknowledgement to make progress atomically', () {
    final oversized = _acknowledgement(
      stroke: 3,
      revision: 8,
      tiles: const [
        StrokeTileCoordinate(0, 0),
        StrokeTileCoordinate(1, 0),
        StrokeTileCoordinate(2, 0),
      ],
    );
    final later = _acknowledgement(
      stroke: 4,
      revision: 9,
      tiles: const [StrokeTileCoordinate(3, 0)],
    );

    final batch = CanvasCpuAcknowledgementBatch.plan(
      pending: [oversized, later],
      maxTileCount: 2,
    );

    expect(batch.acknowledgements, [oversized]);
    expect(batch.coordinates.length, 3);
    expect(batch.oversizedAcknowledgement, same(oversized));
    expect(batch.hasDeferredAcknowledgements, isTrue);
  });

  test('rejects a non-positive tile limit', () {
    expect(
      () => CanvasCpuAcknowledgementBatch.plan(
        pending: const [],
        maxTileCount: 0,
      ),
      throwsArgumentError,
    );
  });
}

StrokeAcknowledgement _acknowledgement({
  required int stroke,
  required int revision,
  required List<StrokeTileCoordinate> tiles,
}) => StrokeAcknowledgement(
  stroke: BigInt.from(stroke),
  highestCommittedSequence: revision,
  revision: revision,
  minTileX: 0,
  minTileY: 0,
  maxTileX: 4,
  maxTileY: 4,
  dirtyTiles: tiles,
);
