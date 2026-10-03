import '../layers/layer_panel_model.dart';
import 'canvas_layer_projection.dart';
import 'canvas_layer_selection_reconciliation.dart';

/// Result of applying one current Rust layer projection to Flutter state.
class CanvasLayerProjectionApplication {
  const CanvasLayerProjectionApplication({required this.panelStateNeedsRepair});

  final bool panelStateNeedsRepair;
}

/// Owns projected layer presentation, selection, and solo state for a route.
///
/// Rust supplies the durable layer and panel snapshots. This owner reconciles
/// those snapshots with transient Flutter selection and presentation state.
class CanvasLayerPresentationState {
  final LayerSelectionModel selection = LayerSelectionModel();
  List<LayerView> layers = const <LayerView>[];
  int? soloLayerId;
  int? _panelStateLoadedGeneration;

  bool needsPanelStateForGeneration(int generation) =>
      _panelStateLoadedGeneration != generation;

  void resetPanelStateGeneration() {
    _panelStateLoadedGeneration = null;
  }

  /// Applies a projection, returning null when initial panel state is pending.
  CanvasLayerProjectionApplication? applyProjection(
    CanvasLayerProjection projection, {
    required int engineGeneration,
  }) {
    final shouldRestorePresentationState =
        needsPanelStateForGeneration(engineGeneration);
    if (shouldRestorePresentationState && projection.panelState == null) {
      return null;
    }

    final reconciliation = CanvasLayerSelectionReconciliation.resolve(
      layers: projection.layers,
      storedPanelState: projection.panelState,
      shouldRestorePresentationState: shouldRestorePresentationState,
      selectedLayerIds: selection.selected,
      currentPrimaryLayerId: selection.primaryId,
    );
    if (reconciliation.restorePresentationState) {
      selection.restorePresentationState(
        primaryId: reconciliation.primaryLayerId,
        collapsedGroups: reconciliation.collapsedGroupIds,
      );
      _panelStateLoadedGeneration = engineGeneration;
    }
    if (reconciliation.repairSelection) {
      selection.clear();
      final fallbackLayerId = reconciliation.fallbackLayerId;
      if (fallbackLayerId != null) selection.select(fallbackLayerId);
    }

    layers = projection.layers;
    final validLayerIds = layers.map((layer) => layer.id).toSet();
    if (soloLayerId != null && !validLayerIds.contains(soloLayerId)) {
      soloLayerId = null;
    }
    return CanvasLayerProjectionApplication(
      panelStateNeedsRepair: reconciliation.panelStateNeedsRepair,
    );
  }
}
