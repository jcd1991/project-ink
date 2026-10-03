import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/bridge/engine_api.dart';
import 'package:project_ink/canvas/canvas_layer_presentation_state.dart';
import 'package:project_ink/canvas/canvas_layer_projection.dart';
import 'package:project_ink/layers/layer_panel_model.dart';

void main() {
  const layers = <LayerView>[
    LayerView(id: 1, name: 'Group', kind: LayerKind.group),
    LayerView(id: 2, name: 'Paint', kind: LayerKind.raster),
  ];

  test('applies Rust panel state and prunes invalid solo layers', () {
    final state = CanvasLayerPresentationState()..soloLayerId = 99;

    final result = state.applyProjection(
      const CanvasLayerProjection(
        layers: layers,
        panelState: LayerPanelStateView(
          primaryLayerId: 2,
          collapsedGroupIds: [1],
        ),
      ),
      engineGeneration: 4,
    );

    expect(result?.panelStateNeedsRepair, isFalse);
    expect(state.layers, layers);
    expect(state.selection.primaryId, 2);
    expect(state.selection.collapsedGroups, {1});
    expect(state.soloLayerId, isNull);
  });

  test(
    'waits for initial panel state without publishing an incomplete layer list',
    () {
      final state = CanvasLayerPresentationState();

      final result = state.applyProjection(
        const CanvasLayerProjection(layers: layers, panelState: null),
        engineGeneration: 4,
      );

      expect(result, isNull);
      expect(state.layers, isEmpty);
      expect(state.selection.primaryId, isNull);
    },
  );

  test(
    'repairs stale live selection and falls back to a visible paint layer',
    () {
      final state = CanvasLayerPresentationState();
      state.applyProjection(
        const CanvasLayerProjection(
          layers: layers,
          panelState: LayerPanelStateView(primaryLayerId: 2),
        ),
        engineGeneration: 4,
      );
      state.selection.select(99);
      state.applyProjection(
        const CanvasLayerProjection(layers: layers, panelState: null),
        engineGeneration: 4,
      );

      expect(state.selection.selected, {2});
      expect(state.selection.primaryId, 2);
    },
  );

  test('reloads durable panel state after its generation is reset', () {
    final state = CanvasLayerPresentationState();
    const projection = CanvasLayerProjection(
      layers: layers,
      panelState: LayerPanelStateView(primaryLayerId: 2),
    );
    state.applyProjection(projection, engineGeneration: 4);
    state.selection.select(1);

    state.resetPanelStateGeneration();
    state.applyProjection(projection, engineGeneration: 5);

    expect(state.selection.primaryId, 2);
  });
}
