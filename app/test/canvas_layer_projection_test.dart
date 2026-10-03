import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/bridge/engine_api.dart';
import 'package:project_ink/canvas/canvas_layer_projection.dart';
import 'package:project_ink/layers/layer_panel_model.dart';

void main() {
  test(
    'maps Rust summaries and reuses thumbnails for the same revision',
    () async {
      final engine = _ProjectionEngine();
      final service = CanvasLayerProjectionService();

      final first = await service.load(
        engine: engine,
        engineGeneration: 2,
        isCurrent: () => true,
        includePanelState: true,
      );
      expect(first, isNotNull);
      expect(first!.layers, hasLength(2));
      expect(first.layers.first.kind, LayerKind.vectorInk);
      expect(first.layers.first.blendMode, LayerBlendMode.multiply);
      expect(first.layers.first.thumbnail, isNotNull);
      expect(first.panelState?.primaryLayerId, 7);
      expect(engine.thumbnailReads, 2);
      expect(engine.panelStateReads, 1);

      final second = await service.load(
        engine: engine,
        engineGeneration: 2,
        isCurrent: () => true,
        includePanelState: false,
      );
      expect(second, isNotNull);
      expect(engine.thumbnailReads, 2);
      expect(second!.panelState, isNull);

      service.clear();
      await service.load(
        engine: engine,
        engineGeneration: 2,
        isCurrent: () => true,
        includePanelState: false,
      );
      expect(engine.thumbnailReads, 4);
    },
  );

  test('does not publish a projection for a stale screen generation', () async {
    final service = CanvasLayerProjectionService();
    final projection = await service.load(
      engine: _ProjectionEngine(),
      engineGeneration: 1,
      isCurrent: () => false,
      includePanelState: true,
    );

    expect(projection, isNull);
  });
}

class _ProjectionEngine extends InMemoryEngineApi {
  int thumbnailReads = 0;
  int panelStateReads = 0;

  @override
  Future<List<LayerSummaryView>> layerSummaries() async => const [
    LayerSummaryView(
      id: 7,
      name: 'Ink',
      kind: 'VectorInk',
      blendMode: 'Multiply',
    ),
    LayerSummaryView(id: 8, name: 'Paint', kind: 'Raster'),
  ];

  @override
  Future<Uint8List> readLayerThumbnail({
    required int layerId,
    int size = 48,
  }) async {
    thumbnailReads++;
    return Uint8List(size * size * 4);
  }

  @override
  Future<LayerPanelStateView> layerPanelState() async {
    panelStateReads++;
    return const LayerPanelStateView(primaryLayerId: 7, collapsedGroupIds: [9]);
  }
}
