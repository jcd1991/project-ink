import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../layers/layer_panel_model.dart';
import '../tools/illustration_tools.dart';
import 'tile_cache.dart';

final Finalizer<List<ui.Image>> _canvasPainterImageFinalizer = Finalizer((
  images,
) {
  for (final image in images) {
    image.dispose();
  }
});

/// Paints Rust-owned tile projections into the current Flutter viewport.
class CanvasTilePainter extends CustomPainter {
  CanvasTilePainter({
    required this.pan,
    required this.scale,
    required this.rotation,
    required this.mirrored,
    required this.revision,
    required this.documentWidth,
    required this.documentHeight,
    required this.layers,
    required Iterable<MapEntry<TileCacheKey, ui.Image>> tiles,
  }) : tiles = List<MapEntry<TileCacheKey, ui.Image>>.unmodifiable(
         tiles.map((entry) => MapEntry(entry.key, entry.value.clone())),
       ) {
    _canvasPainterImageFinalizer.attach(
      this,
      this.tiles.map((entry) => entry.value).toList(growable: false),
      detach: this,
    );
  }

  static const int _tileSize = 256;

  final Offset pan;
  final double scale;
  final double rotation;
  final bool mirrored;
  final int revision;
  final int documentWidth;
  final int documentHeight;
  final List<LayerView> layers;
  final List<MapEntry<TileCacheKey, ui.Image>> tiles;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(const Color(0xff252525), BlendMode.src);
    canvas.save();
    canvas.translate(size.width / 2 + pan.dx, size.height / 2 + pan.dy);
    canvas.rotate(rotation);
    canvas.scale(mirrored ? -scale : scale, scale);
    canvas.drawRect(
      Rect.fromLTWH(
        -documentWidth / 2,
        -documentHeight / 2,
        documentWidth.toDouble(),
        documentHeight.toDouble(),
      ),
      Paint()..color = Colors.white,
    );
    final compositeTiles = tiles
        .where((entry) => entry.key.layer == -1)
        .toList(growable: false);
    if (compositeTiles.isNotEmpty) {
      const source = Rect.fromLTWH(0, 0, 256, 256);
      for (final entry in compositeTiles) {
        final key = entry.key;
        final destination = Rect.fromLTWH(
          key.x * _tileSize - documentWidth / 2,
          key.y * _tileSize - documentHeight / 2,
          _tileSize.toDouble(),
          _tileSize.toDouble(),
        );
        canvas.drawImageRect(entry.value, source, destination, Paint());
      }
      canvas.restore();
      return;
    }
    final tilesByLayer = <int, List<MapEntry<TileCacheKey, ui.Image>>>{};
    for (final entry in tiles) {
      (tilesByLayer[entry.key.layer] ??= <MapEntry<TileCacheKey, ui.Image>>[])
          .add(entry);
    }
    final layerById = <int, LayerView>{
      for (final layer in layers) layer.id: layer,
    };
    final orderedLayers = <LayerView>[
      ...layers.where(
        (layer) =>
            _isPaintLayer(layer) && _isEffectivelyVisible(layer, layerById),
      ),
    ];
    final knownLayerIds = orderedLayers.map((layer) => layer.id).toSet();
    for (final entry in tilesByLayer.entries) {
      if (!knownLayerIds.contains(entry.key)) {
        orderedLayers.add(
          LayerView(
            id: entry.key,
            name: 'Layer ${entry.key}',
            kind: LayerKind.raster,
          ),
        );
      }
    }
    final documentRect = Rect.fromLTWH(
      -documentWidth / 2,
      -documentHeight / 2,
      documentWidth.toDouble(),
      documentHeight.toDouble(),
    );
    for (final layer in orderedLayers) {
      final layerTiles = tilesByLayer[layer.id];
      if (layerTiles == null || layerTiles.isEmpty) continue;
      final blendMode = _blendMode(layer.blendMode);
      final opacity = _effectiveOpacity(layer, layerById);
      final needsIsolation = blendMode != BlendMode.srcOver || opacity < 0.999;
      if (needsIsolation) {
        canvas.saveLayer(
          documentRect,
          Paint()
            ..blendMode = blendMode
            ..color = Color.fromRGBO(255, 255, 255, opacity),
        );
      }
      final paint = Paint()..filterQuality = FilterQuality.low;
      for (final entry in layerTiles) {
        final key = entry.key;
        canvas.drawImage(
          entry.value,
          Offset(
            key.x * _tileSize - documentWidth / 2,
            key.y * _tileSize - documentHeight / 2,
          ),
          paint,
        );
      }
      if (needsIsolation) canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(CanvasTilePainter oldDelegate) =>
      pan != oldDelegate.pan ||
      scale != oldDelegate.scale ||
      rotation != oldDelegate.rotation ||
      mirrored != oldDelegate.mirrored ||
      revision != oldDelegate.revision ||
      documentWidth != oldDelegate.documentWidth ||
      documentHeight != oldDelegate.documentHeight ||
      layers != oldDelegate.layers ||
      tiles != oldDelegate.tiles;

  static BlendMode _blendMode(LayerBlendMode mode) => switch (mode) {
    LayerBlendMode.normal => BlendMode.srcOver,
    LayerBlendMode.multiply => BlendMode.multiply,
    LayerBlendMode.screen => BlendMode.screen,
    LayerBlendMode.overlay => BlendMode.overlay,
    LayerBlendMode.darken => BlendMode.darken,
    LayerBlendMode.lighten => BlendMode.lighten,
    LayerBlendMode.add => BlendMode.plus,
    LayerBlendMode.subtract => BlendMode.modulate,
    LayerBlendMode.colorBurn => BlendMode.darken,
    LayerBlendMode.linearBurn => BlendMode.darken,
    LayerBlendMode.colorDodge => BlendMode.plus,
    LayerBlendMode.softLight => BlendMode.softLight,
    LayerBlendMode.hardLight => BlendMode.hardLight,
    LayerBlendMode.difference => BlendMode.difference,
    LayerBlendMode.exclusion => BlendMode.exclusion,
    LayerBlendMode.divide => BlendMode.plus,
  };

  static bool _isPaintLayer(LayerView layer) =>
      layer.kind == LayerKind.raster || layer.kind == LayerKind.vectorInk;

  static bool _isEffectivelyVisible(
    LayerView layer,
    Map<int, LayerView> layerById,
  ) {
    final visited = <int>{};
    LayerView? current = layer;
    while (current != null) {
      if (!visited.add(current.id) || !current.visible) return false;
      current = current.parent == null ? null : layerById[current.parent];
    }
    return true;
  }

  static double _effectiveOpacity(
    LayerView layer,
    Map<int, LayerView> layerById,
  ) {
    final visited = <int>{};
    var opacity = 1.0;
    LayerView? current = layer;
    while (current != null && visited.add(current.id)) {
      opacity *= current.opacity.clamp(0.0, 1.0);
      current = current.parent == null ? null : layerById[current.parent];
    }
    return opacity.clamp(0.0, 1.0);
  }
}

/// Paints ephemeral selection, tool preview, and ruler overlays.
class CanvasOverlayPainter extends CustomPainter {
  const CanvasOverlayPainter({
    required this.pan,
    required this.scale,
    required this.rotation,
    required this.mirrored,
    required this.documentWidth,
    required this.documentHeight,
    required this.selection,
    required this.selectionTool,
    required this.previewPoints,
    required this.rulerStart,
    required this.rulerEnd,
  });

  final Offset pan;
  final double scale;
  final double rotation;
  final bool mirrored;
  final int documentWidth;
  final int documentHeight;
  final Rect? selection;
  final IllustrationTool? selectionTool;
  final List<Offset> previewPoints;
  final Offset? rulerStart;
  final Offset? rulerEnd;

  Offset toScreen(Offset point, Size size) {
    final centered = point - Offset(documentWidth / 2, documentHeight / 2);
    final rotated = Offset(
      centered.dx * math.cos(rotation) - centered.dy * math.sin(rotation),
      centered.dx * math.sin(rotation) + centered.dy * math.cos(rotation),
    );
    return Offset(size.width / 2, size.height / 2) +
        pan +
        Offset(mirrored ? -rotated.dx : rotated.dx, rotated.dy) * scale;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final stroke =
        Paint()
          ..color = const Color(0xff3f8cff)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..isAntiAlias = true;
    if (selection != null) {
      final rect = Rect.fromPoints(
        toScreen(selection!.topLeft, size),
        toScreen(selection!.bottomRight, size),
      );
      if (selectionTool == IllustrationTool.ellipseSelect) {
        canvas.drawOval(rect, stroke);
      } else {
        canvas.drawRect(rect, stroke);
      }
    }
    if (previewPoints.length > 1) {
      final path =
          Path()..moveTo(
            toScreen(previewPoints.first, size).dx,
            toScreen(previewPoints.first, size).dy,
          );
      for (final point in previewPoints.skip(1)) {
        final screen = toScreen(point, size);
        path.lineTo(screen.dx, screen.dy);
      }
      canvas.drawPath(path, stroke);
    }
    if (rulerStart != null && rulerEnd != null) {
      final start = toScreen(rulerStart!, size);
      final end = toScreen(rulerEnd!, size);
      canvas.drawLine(start, end, stroke..color = const Color(0xffffb020));
    }
  }

  @override
  bool shouldRepaint(CanvasOverlayPainter oldDelegate) =>
      pan != oldDelegate.pan ||
      scale != oldDelegate.scale ||
      rotation != oldDelegate.rotation ||
      selection != oldDelegate.selection ||
      selectionTool != oldDelegate.selectionTool ||
      previewPoints != oldDelegate.previewPoints ||
      rulerStart != oldDelegate.rulerStart ||
      rulerEnd != oldDelegate.rulerEnd;
}
