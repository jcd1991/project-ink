import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app/workspace_preferences.dart';
import '../bridge/engine_api.dart';
import '../layers/layer_panel.dart';
import '../layers/layer_panel_model.dart';
import 'canvas_layer_actions.dart';
import 'canvas_vector_actions.dart';
import 'canvas_workspace_widgets.dart';

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
            onAdjustmentChanged: layerActions.applyLayerAdjustment,
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
            onSimplify: vectorActions.simplifySelected,
            onConnect: vectorActions.connectFirstTwo,
            onEditPoint: vectorActions.editFirstPoint,
          ),
      ],
    );
  }
}
