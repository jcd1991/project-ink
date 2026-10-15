import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app/workspace_preferences.dart';
import '../bridge/engine_api.dart';
import '../design_system/ink_components.dart';
import '../layers/layer_panel.dart';
import '../layers/layer_panel_model.dart';
import 'canvas_layer_actions.dart';
import 'canvas_vector_actions.dart';
import 'canvas_workspace_widgets.dart';

/// A compact reminder of the active paint target and its layer relationship.
class ActiveLayerTargetHeader extends StatelessWidget {
  const ActiveLayerTargetHeader({
    required this.layers,
    required this.selection,
    super.key,
  });

  final List<LayerView> layers;
  final LayerSelectionModel selection;

  @override
  Widget build(BuildContext context) {
    final target =
        layers.where((layer) => layer.id == selection.primaryId).firstOrNull;
    if (target == null) return const SizedBox.shrink();

    final kind = switch (target.kind) {
      LayerKind.raster => 'Paint layer',
      LayerKind.vectorInk => 'Vector layer',
      LayerKind.group => 'Group',
      LayerKind.mask => 'Mask',
      LayerKind.tone => 'Tone layer',
      LayerKind.panelGroup => 'Comic panel group',
      LayerKind.adjustment => 'Adjustment layer',
    };
    final relation = _targetRelation(target, layers);
    return Semantics(
      key: const ValueKey<String>('active-layer-target-context'),
      container: true,
      label: 'Active paint target',
      value: '$kind ${target.name}${relation == null ? '' : ', $relation'}',
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          border: Border(
            bottom: BorderSide(color: inkColors(context).panelBorder),
          ),
        ),
        child: Row(
          children: [
            Icon(
              target.kind == LayerKind.mask
                  ? Icons.layers_clear_outlined
                  : Icons.layers_outlined,
              size: 18,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    target.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  Text(
                    relation == null ? kind : '$kind · $relation',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            const _ActiveTargetBadge(),
          ],
        ),
      ),
    );
  }

  String? _targetRelation(LayerView target, List<LayerView> allLayers) {
    if (target.kind == LayerKind.mask) {
      final owner =
          allLayers.where((layer) => layer.id == target.maskOwner).firstOrNull;
      return owner == null
          ? 'Unattached mask · Black hides; white reveals'
          : 'Mask of ${owner.name} · Black hides; white reveals';
    }
    if (target.clipping) {
      final ordered = orderLayerTree(allLayers);
      final index = ordered.indexWhere((layer) => layer.id == target.id);
      final base =
          index <= 0
              ? null
              : ordered
                  .take(index)
                  .toList(growable: false)
                  .reversed
                  .where(
                    (layer) =>
                        layer.visible &&
                        !layer.clipping &&
                        (layer.kind == LayerKind.raster ||
                            layer.kind == LayerKind.vectorInk),
                  )
                  .firstOrNull;
      return base == null ? 'Clipped' : 'Clipped to ${base.name}';
    }
    final parent =
        allLayers.where((layer) => layer.id == target.parent).firstOrNull;
    return parent == null ? null : 'Inside ${parent.name}';
  }
}

class _ActiveTargetBadge extends StatelessWidget {
  const _ActiveTargetBadge();

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.primaryContainer,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      child: Text('Target', style: Theme.of(context).textTheme.labelSmall),
    ),
  );
}

/// Composes the layer list and vector inspector from their owning services.
///
/// Rust-backed edits remain in [CanvasLayerActions] and [CanvasVectorActions];
/// this widget owns only the layer panel presentation and its local layout.
class CanvasLayerPanelContent extends StatelessWidget {
  const CanvasLayerPanelContent({
    required this.engine,
    required this.layers,
    required this.selection,
    required this.soloLayerId,
    required this.selectedVectorLayerId,
    required this.layerActions,
    required this.vectorActions,
    required this.editorMode,
    required this.targetPlatform,
    required this.onPanelChanged,
    super.key,
  });

  final EngineApi engine;
  final List<LayerView> layers;
  final LayerSelectionModel selection;
  final int? soloLayerId;
  final int? selectedVectorLayerId;
  final CanvasLayerActions layerActions;
  final CanvasVectorActions vectorActions;
  final EditorMode editorMode;
  final TargetPlatform? targetPlatform;
  final VoidCallback onPanelChanged;

  @override
  Widget build(BuildContext context) {
    final platform = targetPlatform ?? defaultTargetPlatform;
    final isTablet =
        platform == TargetPlatform.iOS || platform == TargetPlatform.android;
    final size = MediaQuery.sizeOf(context);
    // Short docks use the Simple presentation so the layer list and Options
    // remain reachable without stacking the inspector above a compressed list.
    final studioMode =
        size.height >= 700 &&
        (!isTablet || (size.width >= 600 && editorMode == EditorMode.studio));

    return Column(
      children: [
        ActiveLayerTargetHeader(layers: layers, selection: selection),
        Expanded(
          child: LayerPanel(
            layers: layers,
            selection: selection,
            studioMode: studioMode,
            soloLayerId: soloLayerId,
            onLayerChanged: layerActions.applyLayerChange,
            onSoloLayer:
                (layer) => unawaited(layerActions.toggleLayerSolo(layer)),
            onOpacityEditStarted: layerActions.beginLayerOpacityEdit,
            onOpacityPreviewChanged: layerActions.previewLayerOpacityEdit,
            onOpacityEditCommitted: layerActions.commitLayerOpacityEdit,
            onOpacityEditCancelled: layerActions.cancelLayerOpacityEdit,
            onMoveLayer:
                (layer, delta) =>
                    unawaited(layerActions.moveLayerBy(layer, delta)),
            onReorderLayer:
                (layer, index) =>
                    unawaited(layerActions.reorderLayerToIndex(layer, index)),
            onReorderLayers:
                (selected, index) => unawaited(
                  layerActions.reorderLayersToIndex(selected, index),
                ),
            onMoveLayerTo:
                (layer, parentId) =>
                    unawaited(layerActions.moveLayerToGroup(layer, parentId)),
            onGroupLayers:
                (selected) =>
                    unawaited(layerActions.groupSelectedLayers(selected)),
            onPreflightGroupLayers:
                (selected) => engine.preflightGroupLayers(
                  layerIds: selected
                      .map((layer) => layer.id)
                      .toList(growable: false),
                ),
            onDuplicateLayers:
                (selected) =>
                    unawaited(layerActions.duplicateSelectedLayers(selected)),
            onMergeSelected:
                (selected) =>
                    unawaited(layerActions.mergeSelectedLayers(selected)),
            onUngroupLayer:
                (layer) => unawaited(layerActions.ungroupLayer(layer)),
            onDeleteLayers:
                (selected) =>
                    unawaited(layerActions.deleteSelectedLayers(selected)),
            onPreflightDeleteLayers:
                (selected) => engine.preflightDeleteLayers(
                  layerIds: selected
                      .map((layer) => layer.id)
                      .toList(growable: false),
                ),
            onSetLayersVisibility:
                (selected, visible) => unawaited(
                  layerActions.setSelectedLayersVisibility(selected, visible),
                ),
            onSetLayersLocked:
                (selected, locked) => unawaited(
                  layerActions.setSelectedLayersLocked(selected, locked),
                ),
            onSetLayersLabel:
                (selected, labelRgba) => unawaited(
                  layerActions.setSelectedLayersLabel(selected, labelRgba),
                ),
            onDeleteLayer:
                (layer) => unawaited(layerActions.deleteLayer(layer)),
            onClearLayer:
                (layer) => unawaited(layerActions.clearLayerContent(layer)),
            onDuplicateLayer:
                (layer) => unawaited(layerActions.duplicateLayer(layer)),
            onPresentationChanged: layerActions.applyLayerPresentation,
            onBeginAdjustmentEdit: layerActions.beginLayerAdjustmentEdit,
            onUpdateAdjustmentEdit: layerActions.updateLayerAdjustmentEdit,
            onCommitAdjustmentEdit: layerActions.commitLayerAdjustmentEdit,
            onCancelAdjustmentEdit: layerActions.cancelLayerAdjustmentEdit,
            onSelectContents:
                (layer) => unawaited(layerActions.selectLayerContents(layer)),
            onMergeLayers:
                (source, target) =>
                    unawaited(layerActions.mergeLayers(source, target)),
            onPreflightMergeLayers: layerActions.preflightMergeLayers,
            onMaskEnabledChanged:
                (layer) => unawaited(layerActions.setMaskEnabled(layer)),
            onMaskInvertedChanged:
                (layer) => unawaited(layerActions.setMaskInverted(layer)),
            onApplyMask:
                (layer) => unawaited(layerActions.applyLayerMask(layer)),
            onSelectionChanged: (_) {
              layerActions.queuePanelStatePersistence();
              unawaited(vectorActions.loadForSelection());
              onPanelChanged();
            },
            onAddLayer: (kind) => unawaited(layerActions.addLayer(kind)),
          ),
        ),
        if (selectedVectorLayerId != null)
          VectorInspector(
            strokes: vectorActions.strokes,
            selectedStrokeIds: vectorActions.selectedStrokeIds,
            candidate: vectorActions.candidate,
            onToggleSelection: vectorActions.toggleStrokeSelection,
            onSimplify: vectorActions.simplifySelected,
            onConnect: vectorActions.connectSelected,
            onEditPoint: vectorActions.editSelectedPoint,
            onRecognize: vectorActions.recognizeSelected,
            onFitCurve:
                (tolerancePx) =>
                    unawaited(vectorActions.fitSelected(tolerancePx)),
            onApplyCandidate: vectorActions.applyCandidate,
            onConstrainCandidate:
                (constraint) =>
                    unawaited(vectorActions.constrainCandidate(constraint)),
            onCancelCandidate: vectorActions.cancelCandidate,
            hasMore: vectorActions.hasMore,
            onLoadMore: vectorActions.loadNextPage,
            onRestoreOriginalInk: vectorActions.restoreOriginalInk,
            onEditPath:
                (request) => unawaited(vectorActions.previewPathEdit(request)),
            onRepeat:
                (options) => unawaited(vectorActions.repeatSelected(options)),
          ),
      ],
    );
  }
}
