import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/canvas/canvas_visible_tile_projection.dart';
import 'package:project_ink/canvas/tile_cache.dart';

void main() {
  test('prefers current composite tiles over raster layers', () {
    const entries = [
      MapEntry(TileCacheKey(4, 2, 0, 0), 'raster'),
      MapEntry(TileCacheKey(4, compositeTileLayerId, 1, 0), 'composite'),
      MapEntry(TileCacheKey(3, compositeTileLayerId, 0, 0), 'stale'),
    ];

    final visible = projectVisibleTileEntries(
      entries: entries,
      revision: 4,
      visibleRasterLayers: const [2],
      primaryRasterLayer: 2,
    );

    expect(visible.map((entry) => entry.value), ['composite']);
  });

  test('filters by revision and sorts visible rasters by layer and tile', () {
    const entries = [
      MapEntry(TileCacheKey(8, 3, 1, 0), 'layer3-x1'),
      MapEntry(TileCacheKey(8, 2, 0, 1), 'layer2-y1'),
      MapEntry(TileCacheKey(7, 2, 0, 0), 'stale'),
      MapEntry(TileCacheKey(8, 2, 1, 0), 'layer2-x1'),
      MapEntry(TileCacheKey(8, 1, 0, 0), 'hidden'),
    ];

    final visible = projectVisibleTileEntries(
      entries: entries,
      revision: 8,
      visibleRasterLayers: const [2, 3],
      primaryRasterLayer: 1,
    );

    expect(visible.map((entry) => entry.value), [
      'layer2-x1',
      'layer2-y1',
      'layer3-x1',
    ]);
  });

  test('uses the primary raster if no visible raster is selected', () {
    const entries = [
      MapEntry(TileCacheKey(2, 4, 0, 0), 'other'),
      MapEntry(TileCacheKey(2, 9, 0, 0), 'primary'),
    ];

    final visible = projectVisibleTileEntries(
      entries: entries,
      revision: 2,
      visibleRasterLayers: const [],
      primaryRasterLayer: 9,
    );

    expect(visible.map((entry) => entry.value), ['primary']);
  });
}
