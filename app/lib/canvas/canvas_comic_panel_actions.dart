import 'package:flutter/material.dart';

import '../bridge/engine_api.dart';
import '../bridge/generated/api.dart' as rust;

/// Canvas session capabilities used by comic panel synchronization and clipping.
class CanvasComicPanelActionHost {
  const CanvasComicPanelActionHost({
    required this.engine,
    required this.mounted,
    required this.activePageIndex,
    required this.workspaceSnapshot,
    required this.clippedPanelId,
    required this.clippedPageIndex,
    required this.setClippedPanel,
    required this.clearSelection,
    required this.loadLayerProjections,
    required this.selectLayer,
    required this.persistPanelState,
  });

  final EngineApi Function() engine;
  final bool Function() mounted;
  final int Function() activePageIndex;
  final rust.ComicProjectView? Function() workspaceSnapshot;
  final BigInt? Function() clippedPanelId;
  final int? Function() clippedPageIndex;
  final void Function({required int pageIndex, required BigInt panelId})
  setClippedPanel;
  final Future<void> Function() clearSelection;
  final Future<void> Function() loadLayerProjections;
  final void Function(int layerId) selectLayer;
  final void Function() persistPanelState;
}

/// Owns the mapping between comic page panels and the active canvas document.
///
/// Rust remains authoritative for panel layer trees and the clipping mask;
/// this service translates immutable comic projections into canvas coordinates.
class CanvasComicPanelActions {
  const CanvasComicPanelActions(this.host);

  final CanvasComicPanelActionHost host;
  EngineApi get engine => host.engine();

  Future<void> syncPanelGeometry(rust.ComicProjectView snapshot) async {
    final pageIndex = host.activePageIndex();
    if (pageIndex < 0 || pageIndex >= snapshot.pages.length) return;
    final page = snapshot.pages[pageIndex];
    if (page.widthPx <= 0 || page.heightPx <= 0) return;
    final scaleX = engine.documentInfo.widthPx / page.widthPx;
    final scaleY = engine.documentInfo.heightPx / page.heightPx;
    for (final panel in page.panels) {
      final layerIds = _panelLayerIds(panel);
      if (layerIds == null) continue;
      final points = _canvasPoints(
        polygon: panel.polygon,
        x: panel.x,
        y: panel.y,
        width: panel.width,
        height: panel.height,
        scaleX: scaleX,
        scaleY: scaleY,
      );
      await engine.createPanelLayerTree(
        panelId: panel.id.toInt(),
        panelGroupId: engine.layerIdForUi(layerIds.group),
        maskLayerId: engine.layerIdForUi(layerIds.mask),
        sketchLayerId: engine.layerIdForUi(layerIds.sketch),
        inkLayerId: engine.layerIdForUi(layerIds.ink),
        colorLayerId: engine.layerIdForUi(layerIds.color),
        toneLayerId: engine.layerIdForUi(layerIds.tone),
        effectsLayerId: engine.layerIdForUi(layerIds.effects),
      );
      await engine.setPanelMaskGeometry(
        maskLayerId: engine.layerIdForUi(layerIds.mask),
        points: points,
      );
    }
  }

  Future<void> drawInsidePanel(
    int pageIndex,
    rust.ComicPanelPreviewView panel,
  ) async {
    final samePanel =
        host.clippedPageIndex() == pageIndex &&
        host.clippedPanelId() == panel.id;
    try {
      if (samePanel) {
        await host.clearSelection();
        return;
      }
      final snapshot = host.workspaceSnapshot();
      if (snapshot == null ||
          pageIndex < 0 ||
          pageIndex >= snapshot.pages.length) {
        return;
      }
      final page = snapshot.pages[pageIndex];
      if (page.widthPx <= 0 || page.heightPx <= 0) return;
      final scaleX = engine.documentInfo.widthPx / page.widthPx;
      final scaleY = engine.documentInfo.heightPx / page.heightPx;
      final points = _canvasPoints(
        polygon: panel.polygon,
        x: panel.x,
        y: panel.y,
        width: panel.width,
        height: panel.height,
        scaleX: scaleX,
        scaleY: scaleY,
      );

      // Materialize the panel-owned layer tree before constraining input so
      // the guide cannot hide ink committed behind the preview.
      final layerIds = _panelLayerIds(panel);
      if (layerIds != null) {
        await engine.createPanelLayerTree(
          panelId: panel.id.toInt(),
          panelGroupId: engine.layerIdForUi(layerIds.group),
          maskLayerId: engine.layerIdForUi(layerIds.mask),
          sketchLayerId: engine.layerIdForUi(layerIds.sketch),
          inkLayerId: engine.layerIdForUi(layerIds.ink),
          colorLayerId: engine.layerIdForUi(layerIds.color),
          toneLayerId: engine.layerIdForUi(layerIds.tone),
          effectsLayerId: engine.layerIdForUi(layerIds.effects),
        );
        await engine.setPanelMaskGeometry(
          maskLayerId: engine.layerIdForUi(layerIds.mask),
          points: points,
        );
        await host.loadLayerProjections();
        host.selectLayer(engine.layerIdForUi(layerIds.ink));
        host.persistPanelState();
      }
      await engine.selectLasso(points);
      if (!host.mounted()) return;
      host.setClippedPanel(pageIndex: pageIndex, panelId: panel.id);
    } catch (error, stack) {
      debugPrint('Project Ink panel clip failed: $error\n$stack');
    }
  }

  List<double> _canvasPoints({
    required List<double> polygon,
    required double x,
    required double y,
    required double width,
    required double height,
    required double scaleX,
    required double scaleY,
  }) {
    final document = engine.documentInfo;
    final sourcePoints =
        polygon.length >= 6 && polygon.length.isEven
            ? polygon
            : <double>[
              x,
              y,
              x + width,
              y,
              x + width,
              y + height,
              x,
              y + height,
            ];
    final points = <double>[];
    for (var index = 0; index < sourcePoints.length; index += 2) {
      points.add(
        (sourcePoints[index] * scaleX).clamp(0.0, document.widthPx.toDouble()),
      );
      points.add(
        (sourcePoints[index + 1] * scaleY).clamp(
          0.0,
          document.heightPx.toDouble(),
        ),
      );
    }
    return points;
  }

  _PanelLayerIds? _panelLayerIds(rust.ComicPanelPreviewView panel) {
    final group = panel.panelGroupId;
    final mask = panel.maskLayerId;
    final sketch = panel.sketchLayerId;
    final ink = panel.inkLayerId;
    final color = panel.colorLayerId;
    final tone = panel.toneLayerId;
    final effects = panel.effectsLayerId;
    if (group == null ||
        mask == null ||
        sketch == null ||
        ink == null ||
        color == null ||
        tone == null ||
        effects == null) {
      return null;
    }
    return _PanelLayerIds(
      group: group,
      mask: mask,
      sketch: sketch,
      ink: ink,
      color: color,
      tone: tone,
      effects: effects,
    );
  }
}

class _PanelLayerIds {
  const _PanelLayerIds({
    required this.group,
    required this.mask,
    required this.sketch,
    required this.ink,
    required this.color,
    required this.tone,
    required this.effects,
  });

  final BigInt group;
  final BigInt mask;
  final BigInt sketch;
  final BigInt ink;
  final BigInt color;
  final BigInt tone;
  final BigInt effects;
}
