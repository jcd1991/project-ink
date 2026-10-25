import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/canvas/tile_cache.dart';

void main() {
  test('stale tile revisions are ignored', () {
    final cache = TileCache();
    expect(cache.put(2, 1, 0, 0, Uint8List.fromList(<int>[2])), isTrue);
    expect(cache.put(1, 1, 0, 0, Uint8List.fromList(<int>[1])), isFalse);
    expect(cache.get(1, 0, 0), orderedEquals(<int>[2]));
  });

  test('new revisions preserve unchanged visible tiles', () {
    final cache = TileCache();
    cache.put(1, 1, 0, 0, Uint8List.fromList(<int>[1]));
    cache.put(1, 1, 1, 0, Uint8List.fromList(<int>[9]));
    cache.put(2, 1, 0, 0, Uint8List.fromList(<int>[2]));
    expect(cache.revision, 2);
    expect(cache.get(1, 0, 0), orderedEquals(<int>[2]));
    expect(cache.get(1, 1, 0), orderedEquals(<int>[9]));
  });

  test('tile image decoding preserves premultiplied BGRA channels', () async {
    final cache = TileImageCache();
    final bytes = Uint8List(TileCache.tileBytes);
    // BGRA premultiplied sample: blue=20, green=40, red=60, alpha=128.
    bytes.setRange(0, 4, const <int>[20, 40, 60, 128]);

    await cache.put(const TileCacheKey(1, -1, 0, 0), bytes);
    final image = cache.get(1, -1, 0, 0)!;
    final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);

    expect(raw!.getUint8(0), 60);
    expect(raw.getUint8(1), 40);
    expect(raw.getUint8(2), 20);
    expect(raw.getUint8(3), 128);
    cache.dispose();
  });
}
