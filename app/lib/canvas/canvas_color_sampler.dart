import 'dart:ui';

import 'tile_cache.dart';

/// Samples a composited BGRA tile at a document-space location.
abstract final class CanvasColorSampler {
  static Color? sample({
    required Offset position,
    required int documentWidth,
    required int documentHeight,
    required int primaryRasterLayer,
    required TileCache tiles,
  }) {
    if (!position.dx.isFinite ||
        !position.dy.isFinite ||
        position.dx < 0 ||
        position.dy < 0 ||
        position.dx >= documentWidth ||
        position.dy >= documentHeight) {
      return null;
    }

    final tileX = position.dx ~/ TileCache.tileSize;
    final tileY = position.dy ~/ TileCache.tileSize;
    // Composite tiles are authoritative; use the primary raster tile only
    // when a composite has not been published for this location.
    final bytes =
        tiles.get(compositeTileLayerId, tileX, tileY) ??
        tiles.get(primaryRasterLayer, tileX, tileY);
    if (bytes == null) return null;

    final x = position.dx.floor() % TileCache.tileSize;
    final y = position.dy.floor() % TileCache.tileSize;
    final offset = (y * TileCache.tileSize + x) * 4;
    final blue = bytes[offset];
    final green = bytes[offset + 1];
    final red = bytes[offset + 2];
    final alpha = bytes[offset + 3];
    if (alpha == 0) return null;
    return Color.fromARGB(
      alpha,
      (red * 255 / alpha).round().clamp(0, 255),
      (green * 255 / alpha).round().clamp(0, 255),
      (blue * 255 / alpha).round().clamp(0, 255),
    );
  }
}
