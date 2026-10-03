import 'tile_cache.dart';

/// Selects and orders the cached tile images that should be presented.
///
/// A current-revision composite tile set takes precedence. If no composite is
/// available, visible raster layers are used, with the primary raster as the
/// fallback when the layer projection has no visible raster.
List<MapEntry<TileCacheKey, T>> projectVisibleTileEntries<T>({
  required Iterable<MapEntry<TileCacheKey, T>> entries,
  required int revision,
  required Iterable<int> visibleRasterLayers,
  required int primaryRasterLayer,
}) {
  final snapshot = entries.toList(growable: false);
  final compositeEntries = snapshot
      .where(
        (entry) =>
            entry.key.revision == revision &&
            entry.key.layer == compositeTileLayerId,
      )
      .toList(growable: false);
  if (compositeEntries.isNotEmpty) return compositeEntries;

  final layers = visibleRasterLayers.toSet();
  if (layers.isEmpty) layers.add(primaryRasterLayer);
  final visibleEntries = snapshot
      .where(
        (entry) =>
            entry.key.revision == revision && layers.contains(entry.key.layer),
      )
      .toList(growable: false);
  visibleEntries.sort((left, right) {
    final layerOrder = left.key.layer.compareTo(right.key.layer);
    if (layerOrder != 0) return layerOrder;
    final yOrder = left.key.y.compareTo(right.key.y);
    return yOrder != 0 ? yOrder : left.key.x.compareTo(right.key.x);
  });
  return visibleEntries;
}
