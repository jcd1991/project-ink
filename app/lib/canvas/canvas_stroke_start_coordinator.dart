import '../layers/layer_panel_model.dart';
import '../tools/brush_library.dart';

/// Screen-owned operations needed to begin a brush stroke.
class CanvasStrokeStartHost {
  const CanvasStrokeStartHost({
    required this.beginAutosaveHold,
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
  final void Function({required String reason}) finishAutosaveHold;
  final void Function() persistPendingQuickSize;
  final int Function() activeBrushId;
  final Future<void>? Function(int brushId) pendingBrushEditForBrush;
  final int? Function() primaryLayerId;
  final List<LayerView> Function() layers;
  final bool Function(LayerView layer) layerEffectivelyVisible;
  final void Function(int layerId) selectTargetLayer;
  final void Function(LayerView? target, {required bool effectivelyVisible})
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
    host.persistPendingQuickSize();
    final brushId = host.activeBrushId();
    final pendingBrushEdit = host.pendingBrushEditForBrush(brushId);
    // A quick-menu size edit can still be committing after its slider closes.
    // Wait so the preview and Rust stroke begin from the same brush revision.
    if (pendingBrushEdit != null) await pendingBrushEdit;

    final primaryLayerId = host.primaryLayerId();
    var target =
        primaryLayerId == null
            ? null
            : host
                .layers()
                .where((layer) => layer.id == primaryLayerId)
                .firstOrNull;
    if (target?.kind == LayerKind.panelGroup) {
      final panelGroupId = target!.id;
      final editableChildren = host
          .layers()
          .where(
            (layer) =>
                layer.parent == panelGroupId &&
                layer.kind == LayerKind.raster &&
                !layer.locked &&
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
    if (target == null || !visible || target.kind != LayerKind.raster) {
      host.finishAutosaveHold(reason: 'invalid_layer_target');
      host.showInvalidTarget(target, effectivelyVisible: visible);
      return false;
    }

    final selectedBrush = host.selectedBrush();
    host.recordStrokeBegin(brushId, selectedBrush);
    await host.beginBrushStrokeOnLayer(brushId, target.id);
    return true;
  }
}
