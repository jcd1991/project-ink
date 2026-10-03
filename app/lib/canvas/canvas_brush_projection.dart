import 'package:flutter/material.dart';

import '../bridge/engine_api.dart';
import '../tools/brush_library.dart';

/// Screen-owned brush projection inputs and selection state.
class CanvasBrushProjectionHost {
  const CanvasBrushProjectionHost({
    required this.engine,
    required this.engineGeneration,
    required this.mounted,
    required this.library,
    required this.activeBrushId,
    required this.setActiveBrushId,
    required this.setActiveColor,
    required this.refreshLayerProjection,
  });

  final EngineApi Function() engine;
  final int Function() engineGeneration;
  final bool Function() mounted;
  final BrushLibraryModel Function() library;
  final int Function() activeBrushId;
  final ValueChanged<int> setActiveBrushId;
  final ValueChanged<Color> setActiveColor;
  final Future<void> Function() refreshLayerProjection;
}

/// Owns the async projection from Rust brush summaries to the Flutter library.
///
/// Rust remains authoritative for preset content. Local preferences restore
/// only the library's device-local organization and selection conveniences.
class CanvasBrushProjection {
  CanvasBrushProjection(this.host);

  final CanvasBrushProjectionHost host;
  int _requestGeneration = 0;

  Future<void> load() async {
    final generation = host.engineGeneration();
    final request = ++_requestGeneration;
    final engine = host.engine();
    bool isCurrent() =>
        host.mounted() &&
        request == _requestGeneration &&
        generation == host.engineGeneration() &&
        engine == host.engine();

    try {
      final brushes = await engine.builtinBrushes();
      if (!isCurrent()) return;
      final library = host.library();
      for (final brush in brushes) {
        library.upsert(
          BrushPresetView(
            id: brush.id,
            name: brush.name,
            isBuiltin: brush.isBuiltin,
            family: _familyFor(brush.tags),
            tags: brush.tags,
            size: brush.diameterPx,
            opacity: brush.opacity,
            colorRgba: brush.colorRgba,
            spacing: brush.spacing,
            stabilization: brush.smoothing,
            pressureSize: brush.pressureSize,
            pressureOpacity: brush.pressureOpacity,
            hardness: brush.hardness,
            textureScale: brush.textureScale,
            scatter: brush.scatter,
            rotationJitter: brush.rotationJitter,
            smudge: brush.smudge,
            wetness: brush.wetness,
            pressureCurvePoints: _curvePointsFromFlat(
              brush.pressureCurvePoints,
            ),
            pressureCurve: _curveMidpointFromFlat(brush.pressureCurvePoints),
            tipResourceHash: brush.tipResourceHash,
            grainResourceHash: brush.grainResourceHash,
          ),
        );
      }
      try {
        await library.restoreLocalState();
      } catch (error, stack) {
        // Brush preferences are optional; a local-store failure cannot block
        // the authoritative layer projection or prevent drawing.
        debugPrint('Project Ink brush preferences unavailable: $error\n$stack');
      }
      if (!isCurrent()) return;
      if (brushes.isNotEmpty) {
        final currentBrushId = library.selected?.id;
        final activeBrushId = host.activeBrushId();
        final selectedBrushId =
            brushes.any((brush) => brush.id == activeBrushId)
                ? activeBrushId
                : brushes.any((brush) => brush.id == currentBrushId)
                ? currentBrushId!
                : brushes.first.id;
        library.select(selectedBrushId);
        host.setActiveBrushId(selectedBrushId);
        final selectedSummary = brushes.firstWhere(
          (brush) => brush.id == selectedBrushId,
        );
        host.setActiveColor(_colorFromRgba(selectedSummary.colorRgba));
      }
      await host.refreshLayerProjection();
    } catch (error, stack) {
      debugPrint('Project Ink Phase 2 projections unavailable: $error\n$stack');
    }
  }
}

Color _colorFromRgba(int colorRgba) => Color.fromARGB(
  colorRgba & 0xff,
  (colorRgba >> 24) & 0xff,
  (colorRgba >> 16) & 0xff,
  (colorRgba >> 8) & 0xff,
);

BrushFamily _familyFor(List<String> tags) {
  for (final tag in tags) {
    switch (tag.toLowerCase()) {
      case 'sketch':
        return BrushFamily.sketch;
      case 'ink':
        return BrushFamily.ink;
      case 'watercolor':
        return BrushFamily.watercolor;
      case 'effect':
        return BrushFamily.effect;
      case 'eraser':
        return BrushFamily.eraser;
      case 'texture':
        return BrushFamily.texture;
      case 'paint':
        return BrushFamily.paint;
    }
  }
  return BrushFamily.paint;
}

List<BrushCurvePointView> _curvePointsFromFlat(List<double> values) {
  if (values.length < 4 || values.length.isOdd) return _defaultCurvePoints;
  final points = <BrushCurvePointView>[];
  for (var index = 0; index < values.length; index += 2) {
    final x = values[index];
    final y = values[index + 1];
    if (!x.isFinite || !y.isFinite || x < 0 || x > 1 || y < 0 || y > 1) {
      return _defaultCurvePoints;
    }
    if (points.isNotEmpty && x <= points.last.x) return _defaultCurvePoints;
    points.add(BrushCurvePointView(x: x, y: y));
  }
  return points.length < 2
      ? _defaultCurvePoints
      : List<BrushCurvePointView>.unmodifiable(points);
}

const _defaultCurvePoints = <BrushCurvePointView>[
  BrushCurvePointView(x: 0, y: 0),
  BrushCurvePointView(x: 0.5, y: 0.5),
  BrushCurvePointView(x: 1, y: 1),
];

double _curveMidpointFromFlat(List<double> values) {
  for (var index = 0; index + 1 < values.length; index += 2) {
    if ((values[index] - 0.5).abs() < 0.001) return values[index + 1];
  }
  return values.length >= 2 ? values[values.length - 1] : 0.5;
}
