import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/bridge/engine_api.dart';
import 'package:project_ink/canvas/canvas_layer_selection_reconciliation.dart';
import 'package:project_ink/layers/layer_panel_model.dart';

void main() {
  const layers = <LayerView>[
    LayerView(id: 1, name: 'Group', kind: LayerKind.group),
    LayerView(id: 2, name: 'Paint', kind: LayerKind.raster),
    LayerView(
      id: 3,
      name: 'Hidden paint',
      kind: LayerKind.raster,
      visible: false,
    ),
    LayerView(id: 4, name: 'Mask', kind: LayerKind.mask),
  ];

  group('CanvasLayerSelectionReconciliation', () {
    test('restores valid durable state and preserves its selection', () {
      final result = CanvasLayerSelectionReconciliation.resolve(
        layers: layers,
        storedPanelState: const LayerPanelStateView(
          primaryLayerId: 2,
          collapsedGroupIds: [1],
        ),
        shouldRestorePresentationState: true,
        selectedLayerIds: const {4},
        currentPrimaryLayerId: 4,
      );

      expect(result.restorePresentationState, isTrue);
      expect(result.primaryLayerId, 2);
      expect(result.collapsedGroupIds, {1});
      expect(result.repairSelection, isFalse);
      expect(result.panelStateNeedsRepair, isFalse);
    });

    test(
      'drops stale disclosure ids and selects a visible editable fallback',
      () {
        final result = CanvasLayerSelectionReconciliation.resolve(
          layers: layers,
          storedPanelState: const LayerPanelStateView(
            primaryLayerId: 99,
            collapsedGroupIds: [1, 88],
          ),
          shouldRestorePresentationState: true,
          selectedLayerIds: const {},
          currentPrimaryLayerId: null,
        );

        expect(result.collapsedGroupIds, {1});
        expect(result.repairSelection, isTrue);
        expect(result.fallbackLayerId, 2);
        expect(result.panelStateNeedsRepair, isTrue);
      },
    );

    test(
      'repairs a stale live selection without restoring stored presentation',
      () {
        final result = CanvasLayerSelectionReconciliation.resolve(
          layers: layers,
          storedPanelState: null,
          shouldRestorePresentationState: false,
          selectedLayerIds: const {99},
          currentPrimaryLayerId: 99,
        );

        expect(result.restorePresentationState, isFalse);
        expect(result.repairSelection, isTrue);
        expect(result.fallbackLayerId, 2);
        expect(result.collapsedGroupIds, isEmpty);
      },
    );

    test('does not replace a valid live selection', () {
      final result = CanvasLayerSelectionReconciliation.resolve(
        layers: layers,
        storedPanelState: null,
        shouldRestorePresentationState: false,
        selectedLayerIds: const {2, 4},
        currentPrimaryLayerId: 2,
      );

      expect(result.repairSelection, isFalse);
      expect(result.panelStateNeedsRepair, isFalse);
      expect(result.fallbackLayerId, isNull);
    });
  });
}
