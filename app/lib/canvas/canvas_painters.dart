import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../bridge/engine_api/engine_api_models.dart';
import '../layers/layer_panel_model.dart';
import '../tools/illustration_tools.dart';
import 'canvas_smart_guides.dart';
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
    this.vectorCandidate,
    this.vectorEditObject,
    this.smartGuides,
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
  final VectorCandidateView? vectorCandidate;
  final VectorObjectSummaryView? vectorEditObject;
  final CanvasSmartGuideResult? smartGuides;
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
    final guides = smartGuides;
    if (guides != null) {
      final guidePaint =
          Paint()
            ..color = const Color(0xff00c9a7).withValues(alpha: 0.9)
            ..strokeWidth = 1
            ..style = PaintingStyle.stroke;
      final verticalX = guides.verticalX;
      if (verticalX != null) {
        canvas.drawLine(
          toScreen(Offset(verticalX, 0), size),
          toScreen(Offset(verticalX, documentHeight.toDouble()), size),
          guidePaint,
        );
      }
      final horizontalY = guides.horizontalY;
      if (horizontalY != null) {
        canvas.drawLine(
          toScreen(Offset(0, horizontalY), size),
          toScreen(Offset(documentWidth.toDouble(), horizontalY), size),
          guidePaint,
        );
      }
    }
    final candidate = vectorCandidate;
    if (candidate != null && candidate.matched) {
      _paintVectorCandidate(canvas, size, candidate);
    }
    final editObject = vectorEditObject;
    if (editObject != null && editObject.kind == 'BezierPath') {
      final useCandidate =
          candidate != null &&
          candidate.matched &&
          candidate.sourceId == editObject.id;
      final geometry = useCandidate ? candidate.geometry : editObject.geometry;
      final subpathStarts =
          useCandidate ? candidate.subpathStarts : editObject.subpathStarts;
      _paintVectorHandles(canvas, size, geometry, subpathStarts);
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
      vectorCandidate != oldDelegate.vectorCandidate ||
      vectorEditObject != oldDelegate.vectorEditObject ||
      smartGuides != oldDelegate.smartGuides ||
      rulerStart != oldDelegate.rulerStart ||
      rulerEnd != oldDelegate.rulerEnd;

  void _paintVectorHandles(
    Canvas canvas,
    Size size,
    List<double> geometry,
    List<int> subpathStarts,
  ) {
    if (geometry.length % 6 != 0 || subpathStarts.isEmpty) return;
    final anchorCount = geometry.length ~/ 6;
    final handleLine =
        Paint()
          ..color = const Color(0xff63d6ff).withValues(alpha: 0.75)
          ..strokeWidth = 1
          ..style = PaintingStyle.stroke
          ..isAntiAlias = true;
    final handlePaint =
        Paint()
          ..color = const Color(0xff63d6ff)
          ..style = PaintingStyle.fill
          ..isAntiAlias = true;
    final anchorPaint =
        Paint()
          ..color = const Color(0xffffffff)
          ..style = PaintingStyle.fill
          ..isAntiAlias = true;
    for (var part = 0; part < subpathStarts.length; part++) {
      final start = subpathStarts[part];
      final end =
          part + 1 < subpathStarts.length
              ? subpathStarts[part + 1]
              : anchorCount;
      if (start < 0 || end > anchorCount || end <= start) return;
      for (var anchor = start; anchor < end; anchor++) {
        final offset = anchor * 6;
        final point = _candidatePoint(geometry, offset, size);
        for (final handleOffset in <int>[2, 4]) {
          final handle = _candidatePoint(geometry, offset + handleOffset, size);
          if ((handle - point).distance < 0.25 * scale) continue;
          canvas.drawLine(point, handle, handleLine);
          canvas.drawCircle(handle, 3, handlePaint);
        }
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: point, width: 9, height: 9),
            const Radius.circular(1.5),
          ),
          handleLine..style = PaintingStyle.stroke,
        );
        canvas.drawCircle(point, 3, anchorPaint);
      }
    }
  }

  void _paintVectorCandidate(
    Canvas canvas,
    Size size,
    VectorCandidateView candidate,
  ) {
    if (candidate.kind == 'LegacyInk') {
      final points = candidate.points;
      if (points.length < 4 || points.length % 4 != 0) return;
      final path = Path();
      final first = toScreen(Offset(points[0], points[1]), size);
      path.moveTo(first.dx, first.dy);
      for (var offset = 4; offset < points.length; offset += 4) {
        final point = toScreen(
          Offset(points[offset], points[offset + 1]),
          size,
        );
        path.lineTo(point.dx, point.dy);
      }
      final rgba = candidate.strokeRgba;
      canvas.drawPath(
        path,
        Paint()
          ..color = Color.fromARGB(
            220,
            (rgba >> 24) & 0xff,
            (rgba >> 16) & 0xff,
            (rgba >> 8) & 0xff,
          )
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.5 * scale
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..isAntiAlias = true,
      );
      return;
    }
    final geometry = candidate.geometry;
    final anchorCount = geometry.length ~/ 6;
    if (anchorCount == 0 || candidate.subpathStarts.isEmpty) return;
    final path = Path();
    for (var part = 0; part < candidate.subpathStarts.length; part++) {
      final start = candidate.subpathStarts[part];
      final end =
          part + 1 < candidate.subpathStarts.length
              ? candidate.subpathStarts[part + 1]
              : anchorCount;
      if (start < 0 || end > anchorCount || end <= start) return;
      final count = end - start;
      final first = _candidatePoint(geometry, start * 6, size);
      path.moveTo(first.dx, first.dy);
      final isClosed = part < candidate.closed.length && candidate.closed[part];
      final segmentCount = isClosed ? count : count - 1;
      for (var offset = 0; offset < segmentCount; offset++) {
        final from = start + offset;
        final to = start + ((offset + 1) % count);
        final outgoing = _candidatePoint(geometry, from * 6 + 4, size);
        final incoming = _candidatePoint(geometry, to * 6 + 2, size);
        final endPoint = _candidatePoint(geometry, to * 6, size);
        path.cubicTo(
          outgoing.dx,
          outgoing.dy,
          incoming.dx,
          incoming.dy,
          endPoint.dx,
          endPoint.dy,
        );
      }
      if (isClosed) path.close();
    }
    final rgba = candidate.strokeRgba;
    canvas.drawPath(
      path,
      Paint()
        ..color = Color.fromARGB(
          rgba & 0xff,
          (rgba >> 24) & 0xff,
          (rgba >> 16) & 0xff,
          (rgba >> 8) & 0xff,
        )
        ..style = PaintingStyle.stroke
        ..strokeWidth = candidate.strokeWidth * scale
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true,
    );
  }

  Offset _candidatePoint(List<double> geometry, int index, Size size) =>
      toScreen(Offset(geometry[index], geometry[index + 1]), size);
}

/// Shows the Apple Pencil's projected tip position without changing the
/// document or competing with the active stroke preview.
class PencilHoverCrosshairPainter extends CustomPainter {
  const PencilHoverCrosshairPainter({
    required this.pan,
    required this.scale,
    required this.rotation,
    required this.mirrored,
    required this.documentWidth,
    required this.documentHeight,
    required this.position,
  });

  final Offset pan;
  final double scale;
  final double rotation;
  final bool mirrored;
  final int documentWidth;
  final int documentHeight;
  final Offset position;

  @override
  void paint(Canvas canvas, Size size) {
    final centered = position - Offset(documentWidth / 2, documentHeight / 2);
    final rotated = Offset(
      centered.dx * math.cos(rotation) - centered.dy * math.sin(rotation),
      centered.dx * math.sin(rotation) + centered.dy * math.cos(rotation),
    );
    final tip =
        Offset(size.width / 2, size.height / 2) +
        pan +
        Offset(mirrored ? -rotated.dx : rotated.dx, rotated.dy) * scale;
    for (final (color, strokeWidth) in <(Color, double)>[
      (Colors.white, 3),
      (Colors.black, 1),
    ]) {
      final paint =
          Paint()
            ..color = color.withValues(alpha: 0.9)
            ..strokeWidth = strokeWidth
            ..style = PaintingStyle.stroke
            ..isAntiAlias = true;
      canvas.drawCircle(tip, 5, paint);
      canvas.drawLine(tip.translate(-9, 0), tip.translate(-3, 0), paint);
      canvas.drawLine(tip.translate(3, 0), tip.translate(9, 0), paint);
      canvas.drawLine(tip.translate(0, -9), tip.translate(0, -3), paint);
      canvas.drawLine(tip.translate(0, 3), tip.translate(0, 9), paint);
    }
  }

  @override
  bool shouldRepaint(PencilHoverCrosshairPainter oldDelegate) =>
      pan != oldDelegate.pan ||
      scale != oldDelegate.scale ||
      rotation != oldDelegate.rotation ||
      mirrored != oldDelegate.mirrored ||
      position != oldDelegate.position ||
      documentWidth != oldDelegate.documentWidth ||
      documentHeight != oldDelegate.documentHeight;
}
