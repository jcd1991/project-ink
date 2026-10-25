import '../layers/layer_panel_model.dart';
import '../tools/brush_library.dart';

/// Screen-owned operations needed to begin a brush stroke.
class CanvasStrokeStartHost {
  const CanvasStrokeStartHost({
    required this.beginAutosaveHold,
    required this.waitForActiveAutosave,
    required this.finishAutosaveHold,
    required this.persistPendingQuickSize,
    required this.activeBrushId,
    required this.pendingBrushEditForBrush,
    required this.primaryLayerId,
    required this.layers,
    required this.layerEffectivelyVisible,
    required this.selectTargetLayer,
    required this.showInvalidTarget,
    required this.selectedBrush,
    required this.recordStrokeBegin,
    required this.beginBrushStrokeOnLayer,
  });

  final void Function() beginAutosaveHold;
  final Future<void> Function() waitForActiveAutosave;
  final void Function({required String reason}) finishAutosaveHold;
  final void Function() persistPendingQuickSize;
  final int Function() activeBrushId;
  final Future<void>? Function(int brushId) pendingBrushEditForBrush;
  final int? Function() primaryLayerId;
  final List<LayerView> Function() layers;
  final bool Function(LayerView layer) layerEffectivelyVisible;
  final void Function(int layerId) selectTargetLayer;
  final void Function(
    LayerView? target, {
    required bool effectivelyVisible,
    required bool effectivelyLocked,
  })
  showInvalidTarget;
  final BrushPresetView? Function() selectedBrush;
  final void Function(int brushId, BrushPresetView? selectedBrush)
  recordStrokeBegin;
  final Future<void> Function(int brushId, int targetLayerId)
  beginBrushStrokeOnLayer;
}

/// Orders pending brush edits, target validation, and Rust stroke creation.
class CanvasStrokeStartCoordinator {
  CanvasStrokeStartCoordinator(this.host);

  final CanvasStrokeStartHost host;

  Future<bool> begin() async {
    host.beginAutosaveHold();
    await host.waitForActiveAutosave();
    host.persistPendingQuickSize();
    final brushId = host.activeBrushId();
    final pendingBrushEdit = host.pendingBrushEditForBrush(brushId);
    // A quick-menu size edit can still be committing after its slider closes.
    // Wait so the preview and Rust stroke begin from the same brush revision.
    if (pendingBrushEdit != null) await pendingBrushEdit;

    final primaryLayerId = host.primaryLayerId();
    final layers = host.layers();
    var target =
        primaryLayerId == null
            ? null
            : layers.where((layer) => layer.id == primaryLayerId).firstOrNull;
    if (target?.kind == LayerKind.panelGroup &&
        !_isEffectivelyLocked(target!, layers)) {
      final panelGroupId = target.id;
      final editableChildren = layers
          .where(
            (layer) =>
                layer.parent == panelGroupId &&
                layer.kind == LayerKind.raster &&
                !_isEffectivelyLocked(layer, layers) &&
                host.layerEffectivelyVisible(layer),
          )
          .toList(growable: false);
      target =
          editableChildren
              .where((layer) => layer.name.trim().toLowerCase() == 'ink')
              .firstOrNull;
      target ??= editableChildren.firstOrNull;
      if (target != null) host.selectTargetLayer(target.id);
    }
    final visible = target != null && host.layerEffectivelyVisible(target);
    final locked = target != null && _isEffectivelyLocked(target, layers);
    if (target == null ||
        !visible ||
        locked ||
        (target.kind != LayerKind.raster && target.kind != LayerKind.mask)) {
      host.finishAutosaveHold(reason: 'invalid_layer_target');
      host.showInvalidTarget(
        target,
        effectivelyVisible: visible,
        effectivelyLocked: locked,
      );
      return false;
    }

    final selectedBrush = host.selectedBrush();
    host.recordStrokeBegin(brushId, selectedBrush);
    await host.beginBrushStrokeOnLayer(brushId, target.id);
    return true;
  }

  bool _isEffectivelyLocked(LayerView layer, List<LayerView> layers) {
    final layersById = <int, LayerView>{
      for (final candidate in layers) candidate.id: candidate,
    };
    final visited = <int>{layer.id};
    var current = layer;
    while (true) {
      if (current.locked) return true;
      final parentId = current.parent;
      if (parentId == null) return false;
      if (!visited.add(parentId)) return true;
      final parent = layersById[parentId];
      if (parent == null) return true;
      current = parent;
    }
  }
}
