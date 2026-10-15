import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/canvas/canvas_layer_panel_content.dart';
import 'package:project_ink/layers/layer_panel_model.dart';

void main() {
  testWidgets('active target identifies its mask owner', (tester) async {
    final selection = LayerSelectionModel()..select(2);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ActiveLayerTargetHeader(
            selection: selection,
            layers: const [
              LayerView(id: 1, name: 'Ink', kind: LayerKind.raster),
              LayerView(
                id: 2,
                name: 'Ink mask',
                kind: LayerKind.mask,
                maskOwner: 1,
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Ink mask'), findsOneWidget);
    expect(find.textContaining('Mask · Mask of Ink'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('active-layer-target-context')),
      findsOneWidget,
    );
  });

  testWidgets('active clipped target names its base layer', (tester) async {
    final selection = LayerSelectionModel()..select(2);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ActiveLayerTargetHeader(
            selection: selection,
            layers: const [
              LayerView(
                id: 1,
                name: 'Color base',
                kind: LayerKind.raster,
                order: 2,
              ),
              LayerView(
                id: 2,
                name: 'Shadow',
                kind: LayerKind.raster,
                order: 1,
                clipping: true,
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Paint layer · Clipped to Color base'), findsOneWidget);
  });
}
