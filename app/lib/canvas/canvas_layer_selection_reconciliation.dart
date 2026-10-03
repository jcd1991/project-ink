import '../bridge/engine_api.dart';
import '../layers/layer_panel_model.dart';

/// Resolves durable layer-panel state against the current Rust layer snapshot.
///
/// The resolver is deliberately pure: the canvas owns applying the returned
/// presentation and selection state, while Rust remains authoritative for the
/// document and the stored panel state.
class CanvasLayerSelectionReconciliation {
  const CanvasLayerSelectionReconciliation({
    required this.restorePresentationState,
    required this.primaryLayerId,
    required this.collapsedGroupIds,
    required this.repairSelection,
    required this.fallbackLayerId,
    required this.panelStateNeedsRepair,
  });

  final bool restorePresentationState;
  final int? primaryLayerId;
  final Set<int> collapsedGroupIds;
  final bool repairSelection;
  final int? fallbackLayerId;
  final bool panelStateNeedsRepair;

  factory CanvasLayerSelectionReconciliation.resolve({
    required List<LayerView> layers,
    required LayerPanelStateView? storedPanelState,
    required bool shouldRestorePresentationState,
    required Set<int> selectedLayerIds,
    required int? currentPrimaryLayerId,
  }) {
    final validLayerIds = layers.map((layer) => layer.id).toSet();
    var panelStateNeedsRepair = false;
    var primaryLayerId = currentPrimaryLayerId;
    var collapsedGroupIds = <int>{};

    if (shouldRestorePresentationState) {
      final state = storedPanelState;
      if (state == null) {
        throw ArgumentError.value(
          storedPanelState,
          'storedPanelState',
          'is required when restoring presentation state',
        );
      }
      final ordinaryGroupIds =
          layers
              .where((layer) => layer.kind == LayerKind.group)
              .map((layer) => layer.id)
              .toSet();
      collapsedGroupIds =
          state.collapsedGroupIds.where(ordinaryGroupIds.contains).toSet();
      panelStateNeedsRepair =
          collapsedGroupIds.length != state.collapsedGroupIds.length;
      primaryLayerId =
          state.primaryLayerId != null &&
                  validLayerIds.contains(state.primaryLayerId)
              ? state.primaryLayerId
              : null;
      panelStateNeedsRepair |= primaryLayerId != state.primaryLayerId;
    }

    final effectiveSelection =
        shouldRestorePresentationState
            ? (primaryLayerId == null ? <int>{} : <int>{primaryLayerId})
            : selectedLayerIds;
    final selectionIsInvalid =
        effectiveSelection.difference(validLayerIds).isNotEmpty ||
        primaryLayerId == null ||
        !validLayerIds.contains(primaryLayerId);
    if (selectionIsInvalid) {
      panelStateNeedsRepair = true;
      primaryLayerId = null;
    }
    final fallbackLayerId =
        selectionIsInvalid
            ? layers
                .where(
                  (layer) =>
                      layer.visible &&
                      (layer.kind == LayerKind.raster ||
                          layer.kind == LayerKind.vectorInk ||
                          layer.kind == LayerKind.tone),
                )
                .firstOrNull
                ?.id
            : null;

    return CanvasLayerSelectionReconciliation(
      restorePresentationState: shouldRestorePresentationState,
      primaryLayerId: primaryLayerId,
      collapsedGroupIds: Set<int>.unmodifiable(collapsedGroupIds),
      repairSelection: selectionIsInvalid,
      fallbackLayerId: fallbackLayerId,
      panelStateNeedsRepair: panelStateNeedsRepair,
    );
  }
}
