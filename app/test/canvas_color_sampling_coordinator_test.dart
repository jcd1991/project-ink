import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/bridge/engine_api.dart';
import 'package:project_ink/canvas/canvas_color_sampling_coordinator.dart';
import 'package:project_ink/canvas/tile_cache.dart';

void main() {
  test('applies a sampled color before publishing its UI projection', () async {
    final tiles = _tilesWithPixel();
    final order = <String>[];
    Color? published;
    final coordinator = CanvasColorSamplingCoordinator(
      CanvasColorSamplingHost(
        documentInfo: () => _documentInfo,
        tiles: () => tiles,
        documentPosition: (_) => const Offset(4, 7),
        applyActiveBrushColor: (color) async {
          order.add('apply');
          expect(color, const Color(0xff123456));
          return true;
        },
        isMounted: () => true,
        publishColor: (color) {
          order.add('publish');
          published = color;
        },
      ),
    );

    expect(await coordinator.sample(Offset.zero), isTrue);
    expect(order, ['apply', 'publish']);
    expect(published, const Color(0xff123456));
  });

  test('does not mutate a brush when the sampled tile has no pixel', () async {
    var applied = false;
    final coordinator = CanvasColorSamplingCoordinator(
      CanvasColorSamplingHost(
        documentInfo: () => _documentInfo,
        tiles: TileCache.new,
        documentPosition: (_) => const Offset(4, 7),
        applyActiveBrushColor: (_) async {
          applied = true;
          return true;
        },
        isMounted: () => true,
        publishColor: (_) => fail('no color should be published'),
      ),
    );

    expect(await coordinator.sample(Offset.zero), isFalse);
    expect(applied, isFalse);
  });

  test('does not publish when the Rust-backed brush update fails', () async {
    var published = false;
    final coordinator = CanvasColorSamplingCoordinator(
      CanvasColorSamplingHost(
        documentInfo: () => _documentInfo,
        tiles: _tilesWithPixel,
        documentPosition: (_) => const Offset(4, 7),
        applyActiveBrushColor: (_) async => false,
        isMounted: () => true,
        publishColor: (_) => published = true,
      ),
    );

    expect(await coordinator.sample(Offset.zero), isFalse);
    expect(published, isFalse);
  });

  test(
    'does not publish if the route is disposed during brush update',
    () async {
      final apply = Completer<bool>();
      var mounted = true;
      var published = false;
      final coordinator = CanvasColorSamplingCoordinator(
        CanvasColorSamplingHost(
          documentInfo: () => _documentInfo,
          tiles: _tilesWithPixel,
          documentPosition: (_) => const Offset(4, 7),
          applyActiveBrushColor: (_) => apply.future,
          isMounted: () => mounted,
          publishColor: (_) => published = true,
        ),
      );
      final sampling = coordinator.sample(Offset.zero);
      mounted = false;
      apply.complete(true);

      expect(await sampling, isFalse);
      expect(published, isFalse);
    },
  );
}

const _documentInfo = DocumentInfo(
  widthPx: 32,
  heightPx: 32,
  dpi: 300,
  primaryRasterLayer: 1,
);

TileCache _tilesWithPixel() {
  final bytes = Uint8List(TileCache.tileBytes);
  const offset = (7 * TileCache.tileSize + 4) * 4;
  bytes[offset] = 0x56;
  bytes[offset + 1] = 0x34;
  bytes[offset + 2] = 0x12;
  bytes[offset + 3] = 0xff;
  return TileCache()..put(1, compositeTileLayerId, 0, 0, bytes);
}
