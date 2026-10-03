import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/canvas/canvas_color_sampler.dart';
import 'package:project_ink/canvas/tile_cache.dart';

Uint8List _tileWithPixel(
  int x,
  int y, {
  required int b,
  required int g,
  required int r,
  required int a,
}) {
  final bytes = Uint8List(TileCache.tileBytes);
  final offset = (y * TileCache.tileSize + x) * 4;
  bytes[offset] = b;
  bytes[offset + 1] = g;
  bytes[offset + 2] = r;
  bytes[offset + 3] = a;
  return bytes;
}

void main() {
  group('CanvasColorSampler', () {
    test('samples composited premultiplied BGRA pixels', () {
      final tiles =
          TileCache()..put(
            4,
            compositeTileLayerId,
            0,
            0,
            _tileWithPixel(8, 12, b: 16, g: 32, r: 64, a: 128),
          );

      expect(
        CanvasColorSampler.sample(
          position: const Offset(8.5, 12.5),
          documentWidth: 100,
          documentHeight: 100,
          primaryRasterLayer: 1,
          tiles: tiles,
        ),
        const Color(0x80804020),
      );
    });

    test('falls back to the primary raster tile', () {
      final bytes = _tileWithPixel(3, 5, b: 30, g: 20, r: 10, a: 255);
      final tiles = TileCache()..put(1, 8, 0, 0, bytes);
      expect(
        CanvasColorSampler.sample(
          position: const Offset(3, 5),
          documentWidth: 100,
          documentHeight: 100,
          primaryRasterLayer: 8,
          tiles: tiles,
        ),
        const Color(0xff0a141e),
      );
      expect(
        CanvasColorSampler.sample(
          position: const Offset(100, 5),
          documentWidth: 100,
          documentHeight: 100,
          primaryRasterLayer: 8,
          tiles: tiles,
        ),
        isNull,
      );
    });

    test('ignores transparent and out-of-document samples', () {
      final bytes = _tileWithPixel(3, 5, b: 0, g: 0, r: 0, a: 0);
      final tiles = TileCache()..put(1, 8, 0, 0, bytes);
      expect(
        CanvasColorSampler.sample(
          position: const Offset(3, 5),
          documentWidth: 100,
          documentHeight: 100,
          primaryRasterLayer: 8,
          tiles: tiles,
        ),
        isNull,
      );
      expect(
        CanvasColorSampler.sample(
          position: const Offset(100, 5),
          documentWidth: 100,
          documentHeight: 100,
          primaryRasterLayer: 8,
          tiles: tiles,
        ),
        isNull,
      );
    });
  });
}
