import 'dart:collection';
import 'dart:typed_data';

import '../bridge/engine_api.dart';
import '../layers/layer_panel_model.dart';

/// Immutable layer presentation snapshot read from the current Rust document.
class CanvasLayerProjection {
  const CanvasLayerProjection({required this.layers, required this.panelState});

  final List<LayerView> layers;
  final LayerPanelStateView? panelState;
}

/// Loads Rust layer summaries and bounded thumbnail batches for Flutter.
///
/// This service owns only its disposable thumbnail cache. Selection,
/// visibility presentation, and publishing snapshots into widgets stay with
/// the screen. Call [clear] when the engine generation is replaced.
class CanvasLayerProjectionService {
  final LinkedHashMap<(int, int, int), Uint8List> _thumbnailCache =
      LinkedHashMap<(int, int, int), Uint8List>();
  int _thumbnailCacheBytes = 0;

  Future<CanvasLayerProjection?> load({
    required EngineApi engine,
    required int engineGeneration,
    required bool Function() isCurrent,
    required bool includePanelState,
  }) async {
    final summaries = await engine.layerSummaries();
    final revision = engine.revision;
    final projectedLayers = <LayerView>[];

    for (var start = 0; start < summaries.length; start += 2) {
      final batch = await Future.wait(
        summaries.skip(start).take(2).map((summary) async {
          Uint8List? thumbnail;
          final key = (engineGeneration, revision, summary.id);
          try {
            thumbnail = _getThumbnail(key);
            if (thumbnail == null) {
              thumbnail = await engine.readLayerThumbnail(layerId: summary.id);
              if (engine.revision == revision && isCurrent()) {
                _cacheThumbnail(key, thumbnail);
              } else {
                thumbnail = null;
              }
            }
          } catch (_) {
            // A thumbnail failure must not hide the authoritative layer list.
          }
          return _toLayerView(summary, thumbnail);
        }),
      );
      if (!isCurrent() || engine.revision != revision) return null;
      projectedLayers.addAll(batch);
    }

    if (!isCurrent()) return null;
    final panelState =
        includePanelState ? await engine.layerPanelState() : null;
    if (!isCurrent()) return null;
    return CanvasLayerProjection(
      layers: List<LayerView>.unmodifiable(projectedLayers),
      panelState: panelState,
    );
  }

  void clear() {
    _thumbnailCache.clear();
    _thumbnailCacheBytes = 0;
  }

  Uint8List? _getThumbnail((int, int, int) key) {
    final value = _thumbnailCache.remove(key);
    if (value == null) return null;
    _thumbnailCache[key] = value;
    return value;
  }

  void _cacheThumbnail((int, int, int) key, Uint8List value) {
    final old = _thumbnailCache.remove(key);
    if (old != null) _thumbnailCacheBytes -= old.length;
    _thumbnailCache[key] = value;
    _thumbnailCacheBytes += value.length;
    while (_thumbnailCacheBytes > 8 * 1024 * 1024 &&
        _thumbnailCache.isNotEmpty) {
      final oldestKey = _thumbnailCache.keys.first;
      _thumbnailCacheBytes -= _thumbnailCache.remove(oldestKey)!.length;
    }
  }
}

LayerView _toLayerView(LayerSummaryView layer, Uint8List? thumbnail) =>
    LayerView(
      id: layer.id,
      parent: layer.parent,
      maskOwner: layer.maskOwner,
      maskEnabled: layer.maskEnabled,
      maskInverted: layer.maskInverted,
      order: layer.order,
      name: layer.name,
      kind: _layerKindFor(layer.kind),
      opacity: layer.opacity,
      visible: layer.visible,
      blendMode: _layerBlendModeFor(layer.blendMode),
      groupMode:
          layer.groupMode == 'Pass-through'
              ? LayerGroupMode.passThrough
              : LayerGroupMode.isolated,
      alphaLock: layer.alphaLock,
      locked: layer.locked,
      clipping: layer.clipping,
      reference: layer.reference,
      label: layer.labelRgba,
      thumbnail: thumbnail,
      adjustmentBrightness: layer.adjustmentBrightness,
      adjustmentContrast: layer.adjustmentContrast,
      adjustmentJson:
          layer.adjustmentJson ??
          '{"BrightnessContrast":{"brightness":${layer.adjustmentBrightness},"contrast":${layer.adjustmentContrast}}}',
      canDrag: layer.canDrag,
      dragReason: layer.dragReason,
      canReceiveLayers: layer.canReceiveLayers,
      receiveReason: layer.receiveReason,
      canEditProperties: layer.canEditProperties,
      editPropertiesReason: layer.editPropertiesReason,
      canDuplicate: layer.canDuplicate,
      duplicateReason: layer.duplicateReason,
      canDelete: layer.canDelete,
      deleteReason: layer.deleteReason,
      canUngroup: layer.canUngroup,
      ungroupReason: layer.ungroupReason,
      canApplyMask: layer.canApplyMask,
      applyMaskReason: layer.applyMaskReason,
      hasMergeDownCapability: layer.hasMergeDownCapability,
      mergeDownReason: layer.mergeDownReason,
    );

LayerKind _layerKindFor(String kind) => switch (kind.toLowerCase()) {
  'vectorink' => LayerKind.vectorInk,
  'group' => LayerKind.group,
  'mask' => LayerKind.mask,
  'tone' => LayerKind.tone,
  'panelgroup' => LayerKind.panelGroup,
  'adjustment' => LayerKind.adjustment,
  _ => LayerKind.raster,
};

LayerBlendMode _layerBlendModeFor(String mode) => switch (mode) {
  'Multiply' => LayerBlendMode.multiply,
  'Screen' => LayerBlendMode.screen,
  'Overlay' => LayerBlendMode.overlay,
  'Darken' => LayerBlendMode.darken,
  'Lighten' => LayerBlendMode.lighten,
  'Add' => LayerBlendMode.add,
  'Subtract' => LayerBlendMode.subtract,
  'Color Burn' => LayerBlendMode.colorBurn,
  'Linear Burn' => LayerBlendMode.linearBurn,
  'Color Dodge' => LayerBlendMode.colorDodge,
  'Soft Light' => LayerBlendMode.softLight,
  'Hard Light' => LayerBlendMode.hardLight,
  'Difference' => LayerBlendMode.difference,
  'Exclusion' => LayerBlendMode.exclusion,
  'Divide' => LayerBlendMode.divide,
  _ => LayerBlendMode.normal,
};
