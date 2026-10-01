import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/layers/layer_panel_model.dart';

void main() {
  test(
    'layer tree sorts top-to-bottom and keeps group descendants together',
    () {
      final ordered = orderLayerTree(const <LayerView>[
        LayerView(id: 30, name: 'Background', kind: LayerKind.raster, order: 0),
        LayerView(
          id: 22,
          name: 'Ink',
          kind: LayerKind.raster,
          parent: 20,
          order: 1,
        ),
        LayerView(id: 20, name: 'Character', kind: LayerKind.group, order: 0),
        LayerView(id: 15, name: 'Effects', kind: LayerKind.group, order: 2),
        LayerView(
          id: 16,
          name: 'Color correction',
          kind: LayerKind.adjustment,
          parent: 15,
          order: 0,
        ),
        LayerView(
          id: 21,
          name: 'Sketch',
          kind: LayerKind.raster,
          parent: 20,
          order: 0,
        ),
        LayerView(id: 10, name: 'Linework', kind: LayerKind.raster, order: 1),
      ]);

      expect(ordered.map((layer) => layer.id), <int>[
        15,
        16,
        10,
        20,
        22,
        21,
        30,
      ]);
    },
  );

  test('layer selection supports additive, toggle, and range gestures', () {
    final layers = <LayerView>[
      const LayerView(id: 1, name: 'Sketch', kind: LayerKind.raster),
      const LayerView(id: 2, name: 'Ink', kind: LayerKind.raster),
      const LayerView(id: 3, name: 'Color', kind: LayerKind.raster),
    ];
    final selection = LayerSelectionModel()..select(1);
    selection.selectRange(layers, 1, 3);
    expect(selection.selected, containsAll(<int>[1, 2, 3]));
    selection.toggle(2);
    expect(selection.selected, containsAll(<int>[1, 3]));
    selection.select(2, additive: true);
    expect(selection.selected, containsAll(<int>[1, 2, 3]));
  });

  test('adjustment layers nest in groups but not comic panel groups', () {
    const ordinaryGroup = LayerView(
      id: 10,
      name: 'Group',
      kind: LayerKind.group,
    );
    const panelGroup = LayerView(
      id: 11,
      name: 'Panel',
      kind: LayerKind.panelGroup,
    );

    expect(
      selectedLayerParentForAdd(
        LayerKind.adjustment,
        <LayerView>[ordinaryGroup],
        <int>{10},
      ),
      10,
    );
    expect(
      selectedLayerParentForAdd(
        LayerKind.adjustment,
        <LayerView>[panelGroup],
        <int>{11},
      ),
      isNull,
    );
    expect(
      selectedLayerParentForAdd(
        LayerKind.raster,
        <LayerView>[panelGroup],
        <int>{11},
      ),
      11,
    );
  });
}
