import 'dart:typed_data';

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
}
