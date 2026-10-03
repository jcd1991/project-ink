import 'dart:math' as math;

import '../bridge/engine_api.dart';

/// A bounded, acknowledgement-atomic set of pixels to snapshot for CPU handoff.
class CanvasCpuAcknowledgementBatch {
  CanvasCpuAcknowledgementBatch._({
    required this.acknowledgements,
    required Map<String, StrokeTileCoordinate> coordinates,
    required Map<String, int> tileRevisions,
    required this.oversizedAcknowledgement,
    required int sourceAcknowledgementCount,
  }) : coordinates = Map<String, StrokeTileCoordinate>.unmodifiable(
         coordinates,
       ),
       tileRevisions = Map<String, int>.unmodifiable(tileRevisions),
       _sourceAcknowledgementCount = sourceAcknowledgementCount;

  final List<StrokeAcknowledgement> acknowledgements;
  final Map<String, StrokeTileCoordinate> coordinates;
  final Map<String, int> tileRevisions;
  final StrokeAcknowledgement? oversizedAcknowledgement;

  bool get hasDeferredAcknowledgements =>
      acknowledgements.length < _sourceAcknowledgementCount;

  final int _sourceAcknowledgementCount;

  /// Plans a snapshot batch without splitting an acknowledgement's dirty set.
  factory CanvasCpuAcknowledgementBatch.plan({
    required List<StrokeAcknowledgement> pending,
    required int maxTileCount,
  }) {
    if (maxTileCount <= 0) {
      throw ArgumentError.value(maxTileCount, 'maxTileCount');
    }
    final selected = <StrokeAcknowledgement>[];
    final coordinates = <String, StrokeTileCoordinate>{};
    final tileRevisions = <String, int>{};
    StrokeAcknowledgement? oversized;

    for (final acknowledgement in pending) {
      final newCoordinates = acknowledgement.dirtyTiles
          .where(
            (coordinate) =>
                !coordinates.containsKey(_coordinateKey(coordinate)),
          )
          .toList(growable: false);
      if (coordinates.length + newCoordinates.length > maxTileCount) {
        // One commit is indivisible. Allow the first commit to exceed the
        // usual budget so a large stroke can still reach CPU/GPU handoff.
        if (selected.isNotEmpty) break;
        oversized = acknowledgement;
      }
      selected.add(acknowledgement);
      for (final coordinate in acknowledgement.dirtyTiles) {
        final key = _coordinateKey(coordinate);
        coordinates[key] = coordinate;
        tileRevisions.update(
          key,
          (revision) => math.max(revision, acknowledgement.revision),
          ifAbsent: () => acknowledgement.revision,
        );
      }
    }

    return CanvasCpuAcknowledgementBatch._(
      acknowledgements: List<StrokeAcknowledgement>.unmodifiable(selected),
      coordinates: coordinates,
      tileRevisions: tileRevisions,
      oversizedAcknowledgement: oversized,
      sourceAcknowledgementCount: pending.length,
    );
  }
}

String _coordinateKey(StrokeTileCoordinate coordinate) =>
    '${coordinate.x}:${coordinate.y}';
