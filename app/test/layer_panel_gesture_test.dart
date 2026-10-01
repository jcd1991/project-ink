import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/design_system/ink_components.dart';
import 'package:project_ink/layers/layer_panel.dart';
import 'package:project_ink/layers/layer_panel_model.dart';

void main() {
  testWidgets('layer list displays highest stack order first', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(
            layers: const [
              LayerView(
                id: 1,
                name: 'Background',
                kind: LayerKind.raster,
                order: 0,
              ),
              LayerView(
                id: 2,
                name: 'Foreground',
                kind: LayerKind.raster,
                order: 1,
              ),
            ],
            selection: LayerSelectionModel(),
          ),
        ),
      ),
    );

    expect(
      tester.getTopLeft(find.text('Foreground')).dy,
      lessThan(tester.getTopLeft(find.text('Background')).dy),
    );
  });

  testWidgets('reorder controls disable at visible sibling boundaries', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(
            layers: const [
              LayerView(
                id: 1,
                name: 'Bottom',
                kind: LayerKind.raster,
                order: 0,
              ),
              LayerView(
                id: 2,
                name: 'Middle',
                kind: LayerKind.raster,
                order: 1,
              ),
              LayerView(id: 3, name: 'Top', kind: LayerKind.raster, order: 2),
            ],
            selection: LayerSelectionModel(),
            onMoveLayer: (_, _) {},
          ),
        ),
      ),
    );

    final upButtons = find.byTooltip('Move layer up');
    final downButtons = find.byTooltip('Move layer down');
    expect(upButtons, findsNWidgets(3));
    expect(downButtons, findsNWidgets(3));

    InkCommandButton buttonFor(Finder tooltip) =>
        tester.widget<InkCommandButton>(
          find.ancestor(of: tooltip, matching: find.byType(InkCommandButton)),
        );

    expect(buttonFor(upButtons.at(0)).onPressed, isNull);
    expect(buttonFor(downButtons.at(0)).onPressed, isNotNull);
    expect(buttonFor(upButtons.at(1)).onPressed, isNotNull);
    expect(buttonFor(downButtons.at(1)).onPressed, isNotNull);
    expect(buttonFor(upButtons.at(2)).onPressed, isNotNull);
    expect(buttonFor(downButtons.at(2)).onPressed, isNull);
  });

  testWidgets('layer rows stay touch-sized with large text in a narrow dock', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final selection = LayerSelectionModel()..select(1);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: SizedBox(
              width: 280,
              child: LayerPanel(
                layers: const [
                  LayerView(
                    id: 1,
                    name: 'Detailed illustration linework layer',
                    kind: LayerKind.raster,
                  ),
                ],
                selection: selection,
              ),
            ),
          ),
        ),
      ),
    );

    final row = find.byType(InkLayerRow);
    expect(row, findsOneWidget);
    expect(tester.getSize(row).height, greaterThanOrEqualTo(48));
    await tester.ensureVisible(find.text('Layer states'));
    await tester.tap(find.text('Layer states'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('right-swipe layer gesture adds the layer to selection', (
    tester,
  ) async {
    final selection = LayerSelectionModel()..select(1);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(
            layers: const [
              LayerView(id: 1, name: 'Sketch', kind: LayerKind.raster),
              LayerView(id: 2, name: 'Ink', kind: LayerKind.raster),
            ],
            selection: selection,
          ),
        ),
      ),
    );

    await tester.drag(find.text('Ink'), const Offset(120, 0));
    await tester.pump();

    expect(selection.selected, containsAll(<int>[1, 2]));
  });

  testWidgets('duplicate layer menu invokes the selected layer callback', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final selection = LayerSelectionModel()..select(7);
    LayerView? duplicated;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(
            layers: const [
              LayerView(id: 7, name: 'Pencil sketch', kind: LayerKind.raster),
            ],
            selection: selection,
            onDuplicateLayer: (layer) => duplicated = layer,
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Layer options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Duplicate layer'));
    await tester.pumpAndSettle();

    expect(duplicated?.id, 7);
    expect(duplicated?.name, 'Pencil sketch');
  });

  testWidgets('renaming disposes its text controller after the dialog route', (
    tester,
  ) async {
    final selection = LayerSelectionModel()..select(7);
    LayerView? presentationChanged;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(
            layers: const [
              LayerView(id: 7, name: 'Pencil sketch', kind: LayerKind.raster),
            ],
            selection: selection,
            onPresentationChanged: (layer) => presentationChanged = layer,
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Layer options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Final inks');
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();

    expect(presentationChanged?.name, 'Final inks');
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelling rename does not change layer presentation', (
    tester,
  ) async {
    final selection = LayerSelectionModel()..select(7);
    LayerView? presentationChanged;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(
            layers: const [
              LayerView(id: 7, name: 'Pencil sketch', kind: LayerKind.raster),
            ],
            selection: selection,
            onPresentationChanged: (layer) => presentationChanged = layer,
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Layer options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Discard this');
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(presentationChanged, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('nested adjustment insertion keeps layer semantics stable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final semanticsHandle = tester.ensureSemantics();
    var layers = const <LayerView>[
      LayerView(id: 1, name: 'Shading group', kind: LayerKind.group),
      LayerView(id: 2, name: 'Color pass', kind: LayerKind.raster, parent: 1),
    ];
    final selection = LayerSelectionModel()..select(1);
    var adjustmentAdds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder:
                (context, setState) => LayerPanel(
                  layers: layers,
                  selection: selection,
                  onAddLayer: (kind) {
                    if (kind != LayerKind.adjustment) return;
                    adjustmentAdds += 1;
                    setState(() {
                      layers = [
                        ...layers,
                        const LayerView(
                          id: 3,
                          name: 'Hue adjustment',
                          kind: LayerKind.adjustment,
                          parent: 1,
                        ),
                      ];
                      selection.select(3);
                    });
                  },
                ),
          ),
        ),
      ),
    );
    expect(tester.getSemantics(find.text('Color pass')), isNotNull);

    await tester.tap(find.byType(InkSelectableChip).last);
    await tester.pumpAndSettle();

    expect(adjustmentAdds, 1);
    expect(find.text('Hue adjustment'), findsOneWidget);
    expect(tester.getSemantics(find.text('Hue adjustment')), isNotNull);
    expect(tester.getSemantics(find.text('Color pass')), isNotNull);
    expect(find.text('Brightness / Contrast'), findsOneWidget);
    expect(tester.takeException(), isNull);
    semanticsHandle.dispose();
  });

  testWidgets(
    'layer properties expose visible opacity, blend, and state controls',
    (tester) async {
      final semanticsHandle = tester.ensureSemantics();
      final selection = LayerSelectionModel()..select(1);
      LayerView? changed;
      LayerView? presentationChanged;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 360,
              child: LayerPanel(
                layers: const [
                  LayerView(id: 1, name: 'Ink', kind: LayerKind.raster),
                ],
                selection: selection,
                onLayerChanged: (layer) => changed = layer,
                onPresentationChanged: (layer) => presentationChanged = layer,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Layer properties'), findsOneWidget);
      expect(find.text('Opacity'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Opacity')), findsOneWidget);
      final opacitySlider = tester.getRect(find.byType(Slider).first);
      await tester.tapAt(
        Offset(
          opacitySlider.left + opacitySlider.width * 0.25,
          opacitySlider.center.dy,
        ),
      );
      expect(changed?.opacity, lessThan(1));
      expect(
        find.byType(DropdownButtonFormField<LayerBlendMode>),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Hide layer'));
      expect(changed?.visible, isFalse);

      await tester.ensureVisible(find.text('Layer states'));
      await tester.tap(find.text('Layer states'));
      await tester.pumpAndSettle();
      for (final label in const ['Alpha lock', 'Clipping', 'Reference']) {
        expect(find.bySemanticsLabel(label), findsOneWidget);
      }

      await tester.tap(find.bySemanticsLabel('Alpha lock'));
      expect(changed?.alphaLock, isTrue);
      await tester.tap(find.bySemanticsLabel('Clipping'));
      expect(changed?.clipping, isTrue);
      await tester.tap(find.bySemanticsLabel('Reference'));
      expect(changed?.reference, isTrue);

      await tester.tap(find.byType(DropdownButtonFormField<LayerBlendMode>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Color Burn').last);
      await tester.pumpAndSettle();
      expect(presentationChanged?.blendMode, LayerBlendMode.colorBurn);
      expect(tester.takeException(), isNull);
      semanticsHandle.dispose();
    },
  );

  testWidgets('pass-through groups cannot enable clipping in the inspector', (
    tester,
  ) async {
    final semanticsHandle = tester.ensureSemantics();
    final selection = LayerSelectionModel()..select(22);
    LayerView? changed;
    LayerView? presentationChanged;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            child: LayerPanel(
              layers: const [
                LayerView(
                  id: 22,
                  name: 'Pass-through group',
                  kind: LayerKind.group,
                  groupMode: LayerGroupMode.passThrough,
                ),
              ],
              selection: selection,
              onLayerChanged: (layer) => changed = layer,
              onPresentationChanged: (layer) => presentationChanged = layer,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Layer states'));
    await tester.tap(find.text('Layer states'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<InkToggleChip>(find.byType(InkToggleChip).at(1)).enabled,
      isFalse,
    );
    await tester.tap(find.bySemanticsLabel('Clipping'));
    expect(changed, isNull);

    await tester.tap(find.byType(DropdownButtonFormField<LayerGroupMode>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Isolated').last);
    await tester.pumpAndSettle();
    expect(presentationChanged?.groupMode, LayerGroupMode.isolated);
    expect(tester.takeException(), isNull);
    semanticsHandle.dispose();
  });

  testWidgets('group opacity inspector targets the selected group ID', (
    tester,
  ) async {
    final selection = LayerSelectionModel()..select(22);
    LayerView? changed;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            child: LayerPanel(
              layers: const [
                LayerView(id: 22, name: 'Group', kind: LayerKind.group),
                LayerView(
                  id: 23,
                  name: 'Child',
                  kind: LayerKind.raster,
                  parent: 22,
                ),
              ],
              selection: selection,
              onLayerChanged: (layer) => changed = layer,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Layer properties'), findsOneWidget);
    final opacitySlider = tester.getRect(find.byType(Slider).first);
    await tester.tapAt(
      Offset(
        opacitySlider.left + opacitySlider.width * 0.25,
        opacitySlider.center.dy,
      ),
    );

    expect(changed?.id, 22);
    expect(changed?.kind, LayerKind.group);
    expect(changed?.opacity, lessThan(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('group inspector exposes isolated and pass-through modes', (
    tester,
  ) async {
    final selection = LayerSelectionModel()..select(31);
    LayerView? changed;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            child: LayerPanel(
              layers: const [
                LayerView(id: 31, name: 'Group', kind: LayerKind.group),
                LayerView(
                  id: 32,
                  name: 'Child',
                  kind: LayerKind.raster,
                  parent: 31,
                ),
              ],
              selection: selection,
              onPresentationChanged: (layer) => changed = layer,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Group'), findsWidgets);
    final groupModeDropdown = find.byType(
      DropdownButtonFormField<LayerGroupMode>,
    );
    expect(groupModeDropdown, findsOneWidget);
    await tester.tap(groupModeDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pass-through').last);
    await tester.pumpAndSettle();

    expect(changed?.id, 31);
    expect(changed?.groupMode, LayerGroupMode.passThrough);
    expect(tester.takeException(), isNull);
  });

  testWidgets('layer pinch opens a merge preview and confirms stable IDs', (
    tester,
  ) async {
    final selection = LayerSelectionModel()..select(2);
    int? mergedSource;
    int? mergedTarget;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(
            layers: const [
              LayerView(id: 1, name: 'Sketch', kind: LayerKind.raster),
              LayerView(id: 2, name: 'Ink', kind: LayerKind.raster),
            ],
            selection: selection,
            onMergeLayers: (source, target) {
              mergedSource = source.id;
              mergedTarget = target.id;
            },
          ),
        ),
      ),
    );

    final center = tester.getCenter(find.text('Ink'));
    final first = await tester.startGesture(
      center.translate(-24, 0),
      pointer: 1,
    );
    final second = await tester.startGesture(
      center.translate(24, 0),
      pointer: 2,
    );
    await first.moveBy(const Offset(-40, 0));
    await second.moveBy(const Offset(40, 0));
    await first.up();
    await second.up();
    await tester.pumpAndSettle();

    expect(find.text('Preview layer merge'), findsOneWidget);
    await tester.tap(find.text('Merge'));
    await tester.pumpAndSettle();
    expect(mergedSource, 2);
    expect(mergedTarget, 1);
  });

  testWidgets('merge pinch targets the adjacent visible row after reorder', (
    tester,
  ) async {
    final selection = LayerSelectionModel()..select(2);
    int? mergedSource;
    int? mergedTarget;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(
            // Deliberately make raw engine order disagree with compositor
            // order: visible stack is Ink (2), Color (3), Sketch (1).
            layers: const [
              LayerView(
                id: 1,
                name: 'Sketch',
                kind: LayerKind.raster,
                order: 0,
              ),
              LayerView(id: 2, name: 'Ink', kind: LayerKind.raster, order: 2),
              LayerView(id: 3, name: 'Color', kind: LayerKind.raster, order: 1),
            ],
            selection: selection,
            onMergeLayers: (source, target) {
              mergedSource = source.id;
              mergedTarget = target.id;
            },
          ),
        ),
      ),
    );

    final center = tester.getCenter(find.text('Ink'));
    final first = await tester.startGesture(
      center.translate(-24, 0),
      pointer: 1,
    );
    final second = await tester.startGesture(
      center.translate(24, 0),
      pointer: 2,
    );
    await first.moveBy(const Offset(-40, 0));
    await second.moveBy(const Offset(40, 0));
    await first.up();
    await second.up();
    await tester.pumpAndSettle();

    expect(find.text('Preview layer merge'), findsOneWidget);
    await tester.tap(find.text('Merge'));
    await tester.pumpAndSettle();
    expect(mergedSource, 2);
    expect(mergedTarget, 3);
  });

  testWidgets('merge preview disables unsupported non-raster target', (
    tester,
  ) async {
    final selection = LayerSelectionModel()..select(1);
    var mergeCalled = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(
            layers: const [
              LayerView(id: 1, name: 'Ink', kind: LayerKind.raster),
              LayerView(id: 2, name: 'Group', kind: LayerKind.group),
            ],
            selection: selection,
            onMergeLayers: (_, _) => mergeCalled = true,
          ),
        ),
      ),
    );

    final center = tester.getCenter(find.text('Ink'));
    final first = await tester.startGesture(
      center.translate(-24, 0),
      pointer: 1,
    );
    final second = await tester.startGesture(
      center.translate(24, 0),
      pointer: 2,
    );
    await first.moveBy(const Offset(-40, 0));
    await second.moveBy(const Offset(40, 0));
    await first.up();
    await second.up();
    await tester.pumpAndSettle();

    expect(
      find.text('Merge is available only between raster layers.'),
      findsOneWidget,
    );
    final mergeButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Merge'),
    );
    expect(mergeButton.onPressed, isNull);
    expect(mergeCalled, isFalse);
  });

  testWidgets(
    'merge preview explains clipping restriction before confirmation',
    (tester) async {
      final selection = LayerSelectionModel()..select(1);
      var mergeCalled = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LayerPanel(
              layers: const [
                LayerView(
                  id: 1,
                  name: 'Ink',
                  kind: LayerKind.raster,
                  clipping: true,
                ),
                LayerView(id: 2, name: 'Color', kind: LayerKind.raster),
              ],
              selection: selection,
              onMergeLayers: (_, _) => mergeCalled = true,
            ),
          ),
        ),
      );

      final center = tester.getCenter(find.text('Ink'));
      final first = await tester.startGesture(
        center.translate(-24, 0),
        pointer: 1,
      );
      final second = await tester.startGesture(
        center.translate(24, 0),
        pointer: 2,
      );
      await first.moveBy(const Offset(-40, 0));
      await second.moveBy(const Offset(40, 0));
      await first.up();
      await second.up();
      await tester.pumpAndSettle();

      expect(
        find.text('Turn off clipping on both layers before merging.'),
        findsOneWidget,
      );
      final mergeButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Merge'),
      );
      expect(mergeButton.onPressed, isNull);
      expect(mergeCalled, isFalse);
    },
  );

  testWidgets('deleting a layer requires confirmation and can be cancelled', (
    tester,
  ) async {
    final selection = LayerSelectionModel()..select(1);
    LayerView? deleted;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(
            layers: const [
              LayerView(id: 1, name: 'Ink', kind: LayerKind.raster),
            ],
            selection: selection,
            onDeleteLayer: (layer) => deleted = layer,
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Layer options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete layer…'));
    await tester.pumpAndSettle();
    expect(find.text('Delete layer?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(deleted, isNull);
  });

  testWidgets('labeled delete action opens the guarded confirmation', (
    tester,
  ) async {
    final selection = LayerSelectionModel()..select(1);
    LayerView? deleted;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(
            layers: const [
              LayerView(id: 1, name: 'Ink', kind: LayerKind.raster),
            ],
            selection: selection,
            onDeleteLayer: (layer) => deleted = layer,
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Delete layer'));
    await tester.pumpAndSettle();
    expect(find.text('Delete layer?'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(deleted?.id, 1);
  });

  testWidgets('adjustment layer exposes bounded brightness and contrast', (
    tester,
  ) async {
    final selection = LayerSelectionModel()..select(7);
    LayerView? changed;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(
            layers: const [
              LayerView(
                id: 7,
                name: 'Adjustment',
                kind: LayerKind.adjustment,
                adjustmentBrightness: -10,
                adjustmentContrast: 15,
              ),
            ],
            selection: selection,
            onAdjustmentChanged: (layer) => changed = layer,
          ),
        ),
      ),
    );

    expect(find.text('Brightness / Contrast'), findsOneWidget);
    expect(find.text('Brightness'), findsOneWidget);
    expect(find.text('Contrast'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics && widget.properties.label == 'Brightness',
      ),
      findsOneWidget,
    );
    expect(find.byType(Slider), findsNWidgets(3));
    tester.widget<Slider>(find.byType(Slider).at(1)).onChanged!(22);
    expect(changed?.adjustmentBrightness, 22);
    tester.widget<Slider>(find.byType(Slider).at(2)).onChanged!(-31);
    expect(changed?.adjustmentContrast, -31);
    await tester.tap(find.byKey(const ValueKey('reset-adjustment')));
    expect(changed?.adjustmentBrightness, 0);
    expect(changed?.adjustmentContrast, 0);
  });

  testWidgets('group deletion confirms the full descendant count', (
    tester,
  ) async {
    final selection = LayerSelectionModel()..select(1);
    LayerView? deleted;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(
            layers: const [
              LayerView(id: 1, name: 'Panel group', kind: LayerKind.group),
              LayerView(id: 2, name: 'Ink', kind: LayerKind.raster, parent: 1),
            ],
            selection: selection,
            onDeleteLayer: (layer) => deleted = layer,
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Layer options').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete layer…'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('1 descendant layer will be removed'),
      findsOneWidget,
    );
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(deleted?.id, 1);
  });

  testWidgets('comic panel group deletion is routed back to Comics', (
    tester,
  ) async {
    final selection = LayerSelectionModel()..select(1);
    LayerView? deleted;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(
            layers: const [
              LayerView(id: 1, name: 'Panel', kind: LayerKind.panelGroup),
              LayerView(id: 2, name: 'Ink', kind: LayerKind.raster, parent: 1),
            ],
            selection: selection,
            onDeleteLayer: (layer) => deleted = layer,
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Layer options').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete layer…'));
    await tester.pumpAndSettle();
    expect(find.textContaining('owns comic panel content'), findsOneWidget);
    expect(find.text('Delete'), findsNothing);
    expect(deleted, isNull);
  });
}
