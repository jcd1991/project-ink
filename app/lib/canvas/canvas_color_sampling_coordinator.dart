import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../bridge/engine_api.dart';
import 'canvas_color_sampler.dart';
import 'tile_cache.dart';

/// Explicit session seams used by [CanvasColorSamplingCoordinator].
class CanvasColorSamplingHost {
  const CanvasColorSamplingHost({
    required this.documentInfo,
    required this.tiles,
    required this.documentPosition,
    required this.applyActiveBrushColor,
    required this.isMounted,
    required this.publishColor,
  });

  final DocumentInfo Function() documentInfo;
  final TileCache Function() tiles;
  final Offset Function(Offset localPosition) documentPosition;
  final Future<bool> Function(Color color) applyActiveBrushColor;
  final bool Function() isMounted;
  final ValueChanged<Color> publishColor;
}

/// Coordinates a sampled pixel through the tile, brush, and UI projections.
///
/// Sampling policy remains pure in [CanvasColorSampler], while Rust-backed
/// brush mutation remains owned by the injected brush action.
class CanvasColorSamplingCoordinator {
  const CanvasColorSamplingCoordinator(this.host);

  final CanvasColorSamplingHost host;

  Future<bool> sample(Offset localPosition) async {
    final info = host.documentInfo();
    final color = CanvasColorSampler.sample(
      position: host.documentPosition(localPosition),
      documentWidth: info.widthPx,
      documentHeight: info.heightPx,
      primaryRasterLayer: info.primaryRasterLayer,
      tiles: host.tiles(),
    );
    if (color == null) return false;
    if (!await host.applyActiveBrushColor(color) || !host.isMounted()) {
      return false;
    }
    host.publishColor(color);
    return true;
  }
}
