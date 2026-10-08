import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/design_system/ink_components.dart';
import 'package:project_ink/layers/layer_panel.dart';
import 'package:project_ink/layers/layer_panel_model.dart';

void main() {
  testWidgets('drag reorder handle has a named accessible target', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LayerPanel(
              layers: const [
                LayerView(id: 1, name: 'Ink', kind: LayerKind.raster),
              ],
              selection: LayerSelectionModel(),
              onReorderLayer: (_, _) {},
            ),
          ),
        ),
      );

      expect(find.bySemanticsLabel('Reorder Ink'), findsOneWidget);
      expect(
        find.byTooltip('Drag to reorder within this group'),
        findsOneWidget,
      );
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('long-pressing visibility requests Solo for that layer', (
    tester,
  ) async {
    const layers = [
      LayerView(id: 1, name: 'Ink', kind: LayerKind.raster),
      LayerView(id: 2, name: 'Color', kind: LayerKind.raster, order: 1),
    ];
    LayerView? soloed;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(
            layers: layers,
            selection: LayerSelectionModel(),
            soloLayerId: 1,
            onSoloLayer: (layer) => soloed = layer,
          ),
        ),
      ),
    );

    expect(find.byTooltip('Hide layer; long-press to solo'), findsNWidgets(2));
    expect(find.byTooltip('Solo'), findsOneWidget);
    await tester.longPress(
      find.byTooltip('Hide layer; long-press to solo').first,
    );

    expect(soloed?.id, 2);
  });

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

  testWidgets('attached mask row identifies its stable owner', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(
            layers: const [
              LayerView(id: 1, name: 'Ink', kind: LayerKind.raster),
              LayerView(
                id: 2,
                name: 'Ink mask',
                kind: LayerKind.mask,
                maskOwner: 1,
                order: 1,
              ),
            ],
            selection: LayerSelectionModel(),
          ),
        ),
      ),
    );

    expect(find.text('Mask · Ink'), findsOneWidget);
  });

  testWidgets('layer options disable reordering at sibling boundaries', (
    tester,
  ) async {
    const layers = [
      LayerView(id: 1, name: 'Bottom', kind: LayerKind.raster, order: 0),
      LayerView(id: 2, name: 'Middle', kind: LayerKind.raster, order: 1),
      LayerView(id: 3, name: 'Top', kind: LayerKind.raster, order: 2),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(
            layers: layers,
            selection: LayerSelectionModel(),
            onMoveLayer: (_, _) {},
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Layer options').first);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ListTile>(
            find.ancestor(
              of: find.text('Move up'),
              matching: find.byType(ListTile),
            ),
          )
          .onTap,
      isNull,
    );
    expect(
      tester
          .widget<ListTile>(
            find.ancestor(
              of: find.text('Move down'),
              matching: find.byType(ListTile),
            ),
          )
          .onTap,
      isNotNull,
    );
  });

  testWidgets('explicit drag handle reorders only within its sibling stack', (
    tester,
  ) async {
    final selection = LayerSelectionModel()..select(2);
    LayerView? moved;
    int? destinationIndex;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 420,
            child: LayerPanel(
              layers: const [
                LayerView(id: 1, name: 'Bottom', kind: LayerKind.raster),
                LayerView(
                  id: 2,
                  name: 'Middle',
                  kind: LayerKind.raster,
                  order: 1,
                ),
                LayerView(id: 3, name: 'Top', kind: LayerKind.raster, order: 2),
              ],
              selection: selection,
              onAddLayer: (_) {},
              onReorderLayer: (layer, index) {
                moved = layer;
                destinationIndex = index;
              },
            ),
          ),
        ),
      ),
    );

    expect(
      find.byTooltip('Drag to reorder within this group'),
      findsNWidgets(3),
    );
    final handle = find.byTooltip('Drag to reorder within this group').last;
    final start = tester.getCenter(handle);
    final target = tester.getCenter(find.text('Top'));
    await tester.dragFrom(start, target - start);
    await tester.pumpAndSettle();

    expect(moved?.id, 1);
    expect(destinationIndex, 2);
  });

  testWidgets(
    'dragging one selected layer reorders selected siblings as a block',
    (tester) async {
      final selection =
          LayerSelectionModel()
            ..select(1)
            ..toggleSecondary(2);
      List<LayerView>? moved;
      int? destinationIndex;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 420,
              child: LayerPanel(
                layers: const [
                  LayerView(id: 1, name: 'Bottom', kind: LayerKind.raster),
                  LayerView(
                    id: 2,
                    name: 'Middle',
                    kind: LayerKind.raster,
                    order: 1,
                  ),
                  LayerView(
                    id: 3,
                    name: 'Top',
                    kind: LayerKind.raster,
                    order: 2,
                  ),
                ],
                selection: selection,
                onAddLayer: (_) {},
                onReorderLayers: (layers, index) {
                  moved = layers;
                  destinationIndex = index;
                },
              ),
            ),
          ),
        ),
      );

      final handle = find.descendant(
        of: find.byKey(const ValueKey<int>(2)),
        matching: find.byTooltip('Drag to reorder within this group'),
      );
      final start = tester.getCenter(handle);
      final target = tester.getCenter(find.text('Top'));
      await tester.dragFrom(start, target - start);
      await tester.pumpAndSettle();

      expect(moved?.map((layer) => layer.id), [2, 1]);
      expect(destinationIndex, isNotNull);
    },
  );

  testWidgets(
    'group options expose one ungroup action for the selected group',
    (tester) async {
      LayerView? ungrouped;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LayerPanel(
              layers: const [
                LayerView(id: 7, name: 'Ink Group', kind: LayerKind.group),
                LayerView(
                  id: 8,
                  name: 'Ink',
                  kind: LayerKind.raster,
                  parent: 7,
                ),
              ],
              selection: LayerSelectionModel(),
              onUngroupLayer: (layer) => ungrouped = layer,
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Layer options').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ungroup layers'));
      await tester.pumpAndSettle();
      expect(ungrouped?.id, 7);
    },
  );

  testWidgets('mask options toggle, invert, and retain the selected mask', (
    tester,
  ) async {
    LayerView? enabledChange;
    LayerView? invertedChange;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(
            layers: const [
              LayerView(id: 1, name: 'Ink', kind: LayerKind.raster),
              LayerView(
                id: 2,
                name: 'Ink mask',
                kind: LayerKind.mask,
                maskOwner: 1,
              ),
            ],
            selection: LayerSelectionModel(),
            onMaskEnabledChanged: (layer) => enabledChange = layer,
            onMaskInvertedChanged: (layer) => invertedChange = layer,
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Layer options').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Disable mask'));
    await tester.pumpAndSettle();
    expect(enabledChange?.id, 2);
    expect(enabledChange?.maskEnabled, isFalse);

    await tester.tap(find.byTooltip('Layer options').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Invert mask'));
    await tester.pumpAndSettle();
    expect(invertedChange?.id, 2);
    expect(invertedChange?.maskInverted, isTrue);
  });

  testWidgets('apply mask confirms and targets its attached mask ID', (
    tester,
  ) async {
    LayerView? applied;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(
            layers: const [
              LayerView(id: 1, name: 'Ink', kind: LayerKind.raster),
              LayerView(
                id: 2,
                name: 'Ink mask',
                kind: LayerKind.mask,
                maskOwner: 1,
              ),
            ],
            selection: LayerSelectionModel(),
            onApplyMask: (mask) => applied = mask,
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Layer options').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply mask…'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Bake this mask into its raster layer and remove the mask. '
        'The change is one undoable action.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Apply mask').last);
    await tester.pumpAndSettle();
    expect(applied?.id, 2);
    expect(applied?.maskOwner, 1);
  });

  testWidgets('dragging onto a group center moves the layer into that group', (
    tester,
  ) async {
    LayerView? moved;
    int? destinationGroup;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 420,
            child: LayerPanel(
              layers: const [
                LayerView(id: 2, name: 'Group', kind: LayerKind.group),
                LayerView(
                  id: 3,
                  name: 'Outside layer',
                  kind: LayerKind.raster,
                  order: 1,
                ),
              ],
              selection: LayerSelectionModel(),
              onAddLayer: (_) {},
              onReorderLayer: (_, _) {},
              onMoveLayerTo: (layer, groupId) {
                moved = layer;
                destinationGroup = groupId;
              },
            ),
          ),
        ),
      ),
    );

    final handle = find.descendant(
      of: find.byKey(const ValueKey<int>(3)),
      matching: find.byTooltip('Drag to reorder within this group'),
    );
    final start = tester.getCenter(handle);
    final target = tester.getCenter(find.byKey(const ValueKey<int>(2)));
    await tester.dragFrom(start, target - start);
    await tester.pumpAndSettle();

    expect(moved?.id, 3);
    expect(destinationGroup, 2);
  });

  testWidgets('drag preview explains a group cycle before release', (
    tester,
  ) async {
    var moved = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 520,
            child: LayerPanel(
              layers: const [
                LayerView(id: 1, name: 'Outer group', kind: LayerKind.group),
                LayerView(
                  id: 2,
                  name: 'Inner group',
                  kind: LayerKind.group,
                  parent: 1,
                  order: 1,
                ),
                LayerView(
                  id: 3,
                  name: 'Child paint',
                  kind: LayerKind.raster,
                  parent: 2,
                  order: 2,
                ),
              ],
              selection: LayerSelectionModel(),
              onReorderLayer: (_, _) {},
              onMoveLayerTo: (_, _) => moved = true,
            ),
          ),
        ),
      ),
    );

    final handle = find.descendant(
      of: find.byKey(const ValueKey<int>(1)),
      matching: find.byTooltip('Drag to reorder within this group'),
    );
    final start = tester.getCenter(handle);
    final target = tester.getCenter(find.byKey(const ValueKey<int>(2)));
    final gesture = await tester.startGesture(start);
    await gesture.moveTo(target);
    await tester.pump();

    expect(
      find.byTooltip('Cannot move Outer group into its own descendant.'),
      findsOneWidget,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(moved, isFalse);
  });

  testWidgets('drag preview explains a comic-owned group destination', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 520,
            child: LayerPanel(
              layers: const [
                LayerView(
                  id: 1,
                  name: 'Comic panel',
                  kind: LayerKind.panelGroup,
                ),
                LayerView(
                  id: 2,
                  name: 'Panel group',
                  kind: LayerKind.group,
                  parent: 1,
                  order: 1,
                  canReceiveLayers: false,
                  receiveReason:
                      'Comic-owned groups can only be rearranged in Comics.',
                ),
                LayerView(
                  id: 3,
                  name: 'Free paint',
                  kind: LayerKind.raster,
                  order: 2,
                ),
              ],
              selection: LayerSelectionModel(),
              onReorderLayer: (_, _) {},
              onMoveLayerTo: (_, _) {},
            ),
          ),
        ),
      ),
    );

    final handle = find.descendant(
      of: find.byKey(const ValueKey<int>(3)),
      matching: find.byTooltip('Drag to reorder within this group'),
    );
    final start = tester.getCenter(handle);
    final target = tester.getCenter(find.byKey(const ValueKey<int>(2)));
    final gesture = await tester.startGesture(start);
    await gesture.moveTo(target);
    await tester.pump();

    expect(
      find.byTooltip(
        'Cannot drop into this comic-owned group: Comic-owned groups can only '
        'be rearranged in Comics.',
      ),
      findsOneWidget,
    );
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('Rust drag restrictions explain fixed sources and group targets', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(
            layers: const [
              LayerView(
                id: 1,
                name: 'Locked child',
                kind: LayerKind.raster,
                canDrag: false,
                dragReason: 'Locked by Sketch group; unlock it before moving.',
              ),
              LayerView(
                id: 2,
                name: 'Sketch group',
                kind: LayerKind.group,
                order: 1,
                canDrag: false,
                dragReason: 'Locked by Sketch group; unlock it before moving.',
                canReceiveLayers: false,
                receiveReason:
                    'Locked by Sketch group; unlock it before moving layers inside.',
              ),
            ],
            selection: LayerSelectionModel(),
            onAddLayer: (_) {},
            onReorderLayer: (_, _) {},
            onMoveLayerTo: (_, _) {},
          ),
        ),
      ),
    );

    expect(
      find.byTooltip('Locked by Sketch group; unlock it before moving.'),
      findsNWidgets(2),
    );
    expect(
      find.byTooltip(
        'Locked by Sketch group; unlock it before moving layers inside.',
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('Drag to reorder within this group'), findsNothing);
  });

  testWidgets('Rust action capabilities disable options with explanations', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(
            layers: const [
              LayerView(
                id: 1,
                name: 'Locked paint',
                kind: LayerKind.raster,
                canEditProperties: false,
                editPropertiesReason:
                    'Locked by Sketch group; unlock it before changing properties.',
                canDuplicate: false,
                duplicateReason:
                    'Locked by Sketch group; unlock it before this action.',
                canDelete: false,
                deleteReason:
                    'Locked by Sketch group; unlock it before this action.',
              ),
              LayerView(
                id: 2,
                name: 'Unsafe group',
                kind: LayerKind.group,
                order: 1,
                canUngroup: false,
                ungroupReason:
                    'Ungroup requires a pass-through, Normal, 100% group.',
              ),
              LayerView(
                id: 3,
                name: 'Detached mask',
                kind: LayerKind.mask,
                maskOwner: 1,
                order: 2,
                canApplyMask: false,
                applyMaskReason:
                    'Attach this mask to a layer before applying it.',
              ),
            ],
            selection: LayerSelectionModel(),
            onDuplicateLayer: (_) {},
            onDeleteLayer: (_) {},
            onUngroupLayer: (_) {},
            onApplyMask: (_) {},
          ),
        ),
      ),
    );

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<int>(1)),
        matching: find.byTooltip('Layer options'),
      ),
    );
    await tester.pumpAndSettle();
    final optionsScroll = find.byType(Scrollable).last;
    await tester.scrollUntilVisible(
      find.text('Rename'),
      240,
      scrollable: optionsScroll,
    );
    final renameTile = tester.widget<ListTile>(
      find.ancestor(of: find.text('Rename'), matching: find.byType(ListTile)),
    );
    expect(renameTile.enabled, isFalse);
    expect(
      (renameTile.subtitle! as Text).data,
      'Locked by Sketch group; unlock it before changing properties.',
    );
    await tester.scrollUntilVisible(
      find.text('Duplicate layer'),
      240,
      scrollable: optionsScroll,
    );
    final duplicateTile = tester.widget<ListTile>(
      find.ancestor(
        of: find.text('Duplicate layer'),
        matching: find.byType(ListTile),
      ),
    );
    expect(duplicateTile.enabled, isFalse);
    expect(
      (duplicateTile.subtitle! as Text).data,
      'Locked by Sketch group; unlock it before this action.',
    );
    await tester.scrollUntilVisible(
      find.text('Delete layer…'),
      240,
      scrollable: optionsScroll,
    );
    expect(
      tester
          .widget<ListTile>(
            find.ancestor(
              of: find.text('Delete layer…'),
              matching: find.byType(ListTile),
            ),
          )
          .enabled,
      isFalse,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<int>(2)),
        matching: find.byTooltip('Layer options'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Ungroup layers'),
      240,
      scrollable: find.byType(Scrollable).last,
    );
    final ungroupTile = tester.widget<ListTile>(
      find.ancestor(
        of: find.text('Ungroup layers'),
        matching: find.byType(ListTile),
      ),
    );
    expect(ungroupTile.enabled, isFalse);
    expect(
      (ungroupTile.subtitle! as Text).data,
      'Ungroup requires a pass-through, Normal, 100% group.',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<int>(3)),
        matching: find.byTooltip('Layer options'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Apply mask…'),
      240,
      scrollable: find.byType(Scrollable).last,
    );
    final applyMaskTile = tester.widget<ListTile>(
      find.ancestor(
        of: find.text('Apply mask…'),
        matching: find.byType(ListTile),
      ),
    );
    expect(applyMaskTile.enabled, isFalse);
    expect(
      (applyMaskTile.subtitle! as Text).data,
      'Attach this mask to a layer before applying it.',
    );
  });

  testWidgets('bulk selection keeps the current primary layer on deselect', (
    tester,
  ) async {
    final selection = LayerSelectionModel()..select(2);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(
            layers: const [
              LayerView(id: 1, name: 'Bottom', kind: LayerKind.raster),
              LayerView(
                id: 2,
                name: 'Middle',
                kind: LayerKind.raster,
                order: 1,
              ),
              LayerView(id: 3, name: 'Top', kind: LayerKind.raster, order: 2),
            ],
            selection: selection,
            onAddLayer: (_) {},
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Layer selection and bulk actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select all layers'));
    await tester.pumpAndSettle();
    expect(selection.selected, <int>{1, 2, 3});
    expect(selection.primaryId, 2);

    await tester.tap(find.byTooltip('Layer selection and bulk actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Deselect secondary layers'));
    await tester.pumpAndSettle();
    expect(selection.selected, <int>{2});
  });

  testWidgets('selection mode adds rows without changing the primary target', (
    tester,
  ) async {
    final selection = LayerSelectionModel()..select(1);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(
            layers: const [
              LayerView(id: 1, name: 'Ink', kind: LayerKind.raster),
              LayerView(
                id: 2,
                name: 'Sketch',
                kind: LayerKind.raster,
                order: 1,
              ),
            ],
            selection: selection,
            onAddLayer: (_) {},
            onSelectionChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Layer selection and bulk actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select mode'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<int>(2)));

    expect(selection.selected, {1, 2});
    expect(selection.primaryId, 1);
    expect(selection.selectMode, isTrue);
  });

  testWidgets('bulk visibility sends selected IDs as one hide action', (
    tester,
  ) async {
    final selection =
        LayerSelectionModel()
          ..select(1)
          ..toggleSecondary(2);
    List<LayerView>? changed;
    bool? visible;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(
            layers: const [
              LayerView(id: 1, name: 'Bottom', kind: LayerKind.raster),
              LayerView(id: 2, name: 'Top', kind: LayerKind.raster, order: 1),
              LayerView(
                id: 3,
                name: 'Hidden',
                kind: LayerKind.raster,
                order: 2,
                visible: false,
              ),
            ],
            selection: selection,
            onAddLayer: (_) {},
            onSetLayersVisibility: (layers, nextVisible) {
              changed = layers;
              visible = nextVisible;
            },
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Layer selection and bulk actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hide selected layers'));
    await tester.pumpAndSettle();

    expect(changed?.map((layer) => layer.id), <int>[2, 1]);
    expect(visible, isFalse);
  });

  testWidgets(
    'bulk Group action sends the selected sibling IDs in stack order',
    (tester) async {
      final selection =
          LayerSelectionModel()
            ..select(2)
            ..toggleSecondary(3);
      List<LayerView>? grouped;
      List<int>? preflighted;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LayerPanel(
              layers: const [
                LayerView(id: 1, name: 'Bottom', kind: LayerKind.raster),
                LayerView(
                  id: 2,
                  name: 'Middle',
                  kind: LayerKind.raster,
                  order: 1,
                ),
                LayerView(id: 3, name: 'Top', kind: LayerKind.raster, order: 2),
              ],
              selection: selection,
              onAddLayer: (_) {},
              onPreflightGroupLayers: (layers) async {
                preflighted = layers.map((layer) => layer.id).toList();
                return null;
              },
              onGroupLayers: (layers) => grouped = layers,
            ),
          ),
        ),
      );

      await tester.tap(find.byTooltip('Layer selection and bulk actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Group selected (2)'));
      await tester.pumpAndSettle();

      expect(grouped?.map((layer) => layer.id), [2, 3]);
      expect(preflighted, [2, 3]);
    },
  );

  testWidgets(
    'grouping an owner with its intervening attached mask carries both',
    (tester) async {
      final selection =
          LayerSelectionModel()
            ..select(1)
            ..toggleSecondary(3);
      List<LayerView>? grouped;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LayerPanel(
              layers: const [
                LayerView(id: 1, name: 'Ink', kind: LayerKind.raster),
                LayerView(
                  id: 2,
                  name: 'Ink mask',
                  kind: LayerKind.mask,
                  maskOwner: 1,
                  order: 1,
                ),
                LayerView(
                  id: 3,
                  name: 'Color',
                  kind: LayerKind.raster,
                  order: 2,
                ),
              ],
              selection: selection,
              onAddLayer: (_) {},
              onGroupLayers: (layers) => grouped = layers,
            ),
          ),
        ),
      );

      await tester.tap(find.byTooltip('Layer selection and bulk actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Group selected (2)'));
      await tester.pumpAndSettle();
      expect(find.text('Group selected layers?'), findsOneWidget);
      await tester.tap(find.text('Group').last);
      await tester.pumpAndSettle();

      expect(grouped?.map((layer) => layer.id), [1, 3]);
      expect(
        find.text('Grouping this range could move a mask away from its owner.'),
        findsNothing,
      );
    },
  );

  testWidgets('group menu reports the engine preflight reason', (tester) async {
    final selection =
        LayerSelectionModel()
          ..select(1)
          ..toggleSecondary(2);
    var grouped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(
            layers: const [
              LayerView(id: 1, name: 'Ink', kind: LayerKind.raster),
              LayerView(id: 2, name: 'Color', kind: LayerKind.raster, order: 1),
            ],
            selection: selection,
            onAddLayer: (_) {},
            onPreflightGroupLayers:
                (_) async => 'Rust says this layer is locked.',
            onGroupLayers: (_) => grouped = true,
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Layer selection and bulk actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Group selected (2)'));
    await tester.pumpAndSettle();

    expect(find.text('Rust says this layer is locked.'), findsOneWidget);
    expect(grouped, isFalse);
  });

  testWidgets('bulk Delete reports engine rejection before confirmation', (
    tester,
  ) async {
    final selection =
        LayerSelectionModel()
          ..select(1)
          ..toggleSecondary(2);
    var deleted = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(
            layers: const [
              LayerView(id: 1, name: 'Ink', kind: LayerKind.raster),
              LayerView(id: 2, name: 'Color', kind: LayerKind.raster, order: 1),
              LayerView(id: 3, name: 'Keep', kind: LayerKind.raster, order: 2),
            ],
            selection: selection,
            onAddLayer: (_) {},
            onPreflightDeleteLayers:
                (_) async =>
                    'layer ${1.toRadixString(16).padLeft(32, '0')} is locked by '
                    'layer ${2.toRadixString(16).padLeft(32, '0')}; unlock the '
                    'owning layer or group first',
            onDeleteLayers: (_) => deleted = true,
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Layer selection and bulk actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete selected (2)'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        '“Ink” is locked by “Color”. Unlock the owning layer or group first.',
      ),
      findsOneWidget,
    );
    expect(find.text('Delete 2 selected layers?'), findsNothing);
    expect(deleted, isFalse);
  });

  testWidgets('bulk Duplicate action sends selected roots in stack order', (
    tester,
  ) async {
    final selection =
        LayerSelectionModel()
          ..select(2)
          ..toggleSecondary(3);
    List<LayerView>? duplicated;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(
            layers: const [
              LayerView(id: 1, name: 'Bottom', kind: LayerKind.raster),
              LayerView(
                id: 2,
                name: 'Middle',
                kind: LayerKind.raster,
                order: 1,
              ),
              LayerView(id: 3, name: 'Top', kind: LayerKind.raster, order: 2),
            ],
            selection: selection,
            onAddLayer: (_) {},
            onDuplicateLayers: (layers) => duplicated = layers,
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Layer selection and bulk actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Duplicate selected (2)'));
    await tester.pumpAndSettle();

    expect(duplicated?.map((layer) => layer.id), [2, 3]);
  });

  testWidgets('bulk Merge confirms and sends selected roots in stack order', (
    tester,
  ) async {
    final selection =
        LayerSelectionModel()
          ..select(1)
          ..toggleSecondary(2);
    List<LayerView>? merged;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(
            layers: const [
              LayerView(id: 1, name: 'Bottom', kind: LayerKind.raster),
              LayerView(id: 2, name: 'Top', kind: LayerKind.raster, order: 1),
            ],
            selection: selection,
            onAddLayer: (_) {},
            onMergeSelected: (layers) => merged = layers,
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Layer selection and bulk actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Merge selected (2)'));
    await tester.pumpAndSettle();
    expect(find.text('Merge selected layers?'), findsOneWidget);
    await tester.tap(find.text('Merge'));
    await tester.pumpAndSettle();
    expect(merged?.map((layer) => layer.id), [1, 2]);
  });

  testWidgets('bulk lock sends selected IDs as one lock action', (
    tester,
  ) async {
    final selection =
        LayerSelectionModel()
          ..select(1)
          ..toggleSecondary(2);
    List<LayerView>? changed;
    bool? locked;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(
            layers: const [
              LayerView(id: 1, name: 'Sketch', kind: LayerKind.raster),
              LayerView(id: 2, name: 'Ink', kind: LayerKind.raster, order: 1),
            ],
            selection: selection,
            onAddLayer: (_) {},
            onSetLayersLocked: (layers, value) {
              changed = layers;
              locked = value;
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Layer selection and bulk actions'));
    await tester.pumpAndSettle();
    expect(find.text('Lock selected layers'), findsOneWidget);
    await tester.tap(find.text('Lock selected layers'));
    expect(changed?.map((layer) => layer.id), [2, 1]);
    expect(locked, isTrue);
  });

  testWidgets('bulk label sends selected layers in stack order', (
    tester,
  ) async {
    final selection =
        LayerSelectionModel()
          ..select(1)
          ..toggleSecondary(2);
    List<LayerView>? changed;
    int? label;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(
            layers: const [
              LayerView(id: 1, name: 'Sketch', kind: LayerKind.raster),
              LayerView(id: 2, name: 'Ink', kind: LayerKind.raster, order: 1),
            ],
            selection: selection,
            onAddLayer: (_) {},
            onSetLayersLabel: (layers, value) {
              changed = layers;
              label = value;
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Layer selection and bulk actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Label selected red'));
    await tester.pumpAndSettle();
    expect(changed?.map((layer) => layer.id), [2, 1]);
    expect(label, 0xe53935ff);
  });

  testWidgets('layer color labels are visible and accessible', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(
            layers: const [
              LayerView(
                id: 1,
                name: 'Ink',
                kind: LayerKind.raster,
                label: 0xe53935ff,
              ),
            ],
            selection: LayerSelectionModel()..select(1),
            onAddLayer: (_) {},
          ),
        ),
      ),
    );
    expect(find.byTooltip('Color label'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.label == 'Layer color label',
      ),
      findsOneWidget,
    );
  });

  testWidgets('bulk Delete confirms descendants and sends structural roots', (
    tester,
  ) async {
    final selection =
        LayerSelectionModel()
          ..select(10)
          ..toggleSecondary(11);
    List<LayerView>? deleted;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(
            layers: const [
              LayerView(id: 1, name: 'Keep', kind: LayerKind.raster),
              LayerView(
                id: 10,
                name: 'Group to delete',
                kind: LayerKind.group,
                order: 1,
              ),
              LayerView(
                id: 11,
                name: 'Child to delete',
                kind: LayerKind.raster,
                parent: 10,
              ),
            ],
            selection: selection,
            onAddLayer: (_) {},
            onDeleteLayers: (layers) => deleted = layers,
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Layer selection and bulk actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete selected (2)'));
    await tester.pumpAndSettle();
    expect(find.text('Delete 2 selected layers?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(deleted?.map((layer) => layer.id), [10]);
  });

  testWidgets('layer rows stay touch-sized with large text in a narrow dock', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 640);
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
              width: 560,
              child: LayerPanel(
                layers: const [
                  LayerView(id: 2, name: 'Layer 2', kind: LayerKind.group),
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
    expect(row, findsNWidgets(2));
    expect(tester.getSize(row.first).height, greaterThanOrEqualTo(48));
    expect(find.text('Layer 2'), findsOneWidget);
    expect(find.byTooltip('Collapse group'), findsOneWidget);
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

    await tester.tap(find.byTooltip('Layer options').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Duplicate layer'));
    await tester.pumpAndSettle();

    expect(duplicated?.id, 7);
    expect(duplicated?.name, 'Pencil sketch');
  });

  testWidgets('full layer lock is distinct from alpha lock in the menu', (
    tester,
  ) async {
    final selection = LayerSelectionModel()..select(1);
    LayerView? changed;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(
            layers: const [
              LayerView(id: 1, name: 'Ink', kind: LayerKind.raster),
            ],
            selection: selection,
            onLayerChanged: (layer) => changed = layer,
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Layer options').first);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Lock layer'),
      180,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('Lock layer'), findsOneWidget);
    await tester.tap(find.text('Lock layer'));
    expect(changed?.locked, isTrue);
    expect(changed?.alphaLock, isFalse);
  });

  testWidgets('layer options reparent to a selected group by stable IDs', (
    tester,
  ) async {
    final selection = LayerSelectionModel()..select(11);
    LayerView? moved;
    int? destination;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(
            layers: const [
              LayerView(id: 1, name: 'Background', kind: LayerKind.raster),
              LayerView(id: 2, name: 'Colors', kind: LayerKind.group, order: 1),
              LayerView(
                id: 11,
                name: 'Linework',
                kind: LayerKind.raster,
                parent: 2,
              ),
              LayerView(
                id: 3,
                name: 'Shading',
                kind: LayerKind.group,
                order: 2,
              ),
            ],
            selection: selection,
            onMoveLayerTo: (layer, parentId) {
              moved = layer;
              destination = parentId;
            },
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Layer options').at(2));
    await tester.pumpAndSettle();
    // The full-lock action adds a row to the options sheet; scroll to lower
    // destinations instead of relying on them being initially laid out.
    await tester.drag(find.byType(ListView).last, const Offset(0, -600));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move into Shading'));
    await tester.pumpAndSettle();

    expect(moved?.id, 11);
    expect(destination, 3);
  });

  testWidgets('layer options can move a child out to the root stack', (
    tester,
  ) async {
    final selection = LayerSelectionModel()..select(11);
    LayerView? moved;
    int? destination = 99;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(
            layers: const [
              LayerView(id: 2, name: 'Colors', kind: LayerKind.group),
              LayerView(
                id: 11,
                name: 'Linework',
                kind: LayerKind.raster,
                parent: 2,
              ),
            ],
            selection: selection,
            onMoveLayerTo: (layer, parentId) {
              moved = layer;
              destination = parentId;
            },
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Layer options').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move out of group'));
    await tester.pumpAndSettle();

    expect(moved?.id, 11);
    expect(destination, isNull);
  });

  testWidgets('comic-owned layers do not expose group reparent actions', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(
            layers: const [
              LayerView(
                id: 50,
                name: 'Panel',
                kind: LayerKind.panelGroup,
                order: 1,
              ),
              LayerView(
                id: 51,
                name: 'Panel ink',
                kind: LayerKind.raster,
                parent: 50,
              ),
              LayerView(
                id: 52,
                name: 'Other group',
                kind: LayerKind.group,
                order: 0,
              ),
            ],
            selection: LayerSelectionModel(),
            onMoveLayerTo: (_, _) {},
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Layer options').at(1));
    await tester.pumpAndSettle();

    expect(find.text('Move out of group'), findsNothing);
    expect(find.text('Move into Other group'), findsNothing);
  });

  testWidgets('layer options select contents for the explicit layer', (
    tester,
  ) async {
    final selection = LayerSelectionModel()..select(12);
    LayerView? selectedContents;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(
            layers: const [
              LayerView(id: 12, name: 'Paint', kind: LayerKind.raster),
            ],
            selection: selection,
            onSelectContents: (layer) => selectedContents = layer,
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Layer options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select contents'));
    await tester.pumpAndSettle();

    expect(selectedContents?.id, 12);
  });

  testWidgets('layer options clear paint without deleting the layer', (
    tester,
  ) async {
    final selection = LayerSelectionModel()..select(12);
    LayerView? clearedLayer;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(
            layers: const [
              LayerView(id: 12, name: 'Panel Frames', kind: LayerKind.raster),
            ],
            selection: selection,
            onClearLayer: (layer) => clearedLayer = layer,
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Layer options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear layer'));
    await tester.pumpAndSettle();

    expect(clearedLayer?.id, 12);
    expect(clearedLayer?.name, 'Panel Frames');
  });

  testWidgets('Merge down menu previews adjacent sibling IDs', (tester) async {
    final selection = LayerSelectionModel()..select(22);
    int? sourceId;
    int? targetId;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(
            layers: const [
              LayerView(id: 21, name: 'Lower', kind: LayerKind.raster),
              LayerView(
                id: 22,
                name: 'Upper',
                kind: LayerKind.raster,
                order: 1,
              ),
            ],
            selection: selection,
            onMergeLayers: (source, target) {
              sourceId = source.id;
              targetId = target.id;
            },
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Layer options').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Merge down…'));
    await tester.pumpAndSettle();
    expect(find.text('Preview layer merge'), findsOneWidget);
    await tester.tap(find.text('Merge'));
    await tester.pumpAndSettle();

    expect(sourceId, 22);
    expect(targetId, 21);
  });

  testWidgets('Rust merge preflight explains unsafe pixel coverage', (
    tester,
  ) async {
    var preflightSourceId = 0;
    var preflightTargetId = 0;
    var mergeCalled = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(
            layers: const [
              LayerView(id: 31, name: 'Lower', kind: LayerKind.raster),
              LayerView(
                id: 32,
                name: 'Upper',
                kind: LayerKind.raster,
                order: 1,
                hasMergeDownCapability: true,
              ),
            ],
            selection: LayerSelectionModel(),
            onPreflightMergeLayers: (source, target) async {
              preflightSourceId = source.id;
              preflightTargetId = target.id;
              return 'Exact merge requires opaque lower-layer coverage beneath source marks.';
            },
            onMergeLayers: (_, _) => mergeCalled = true,
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Layer options').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Merge down…'));
    await tester.pumpAndSettle();

    expect(preflightSourceId, 32);
    expect(preflightTargetId, 31);
    expect(
      find.text(
        'Exact merge requires opaque lower-layer coverage beneath source marks.',
      ),
      findsOneWidget,
    );
    final mergeButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Merge'),
    );
    expect(mergeButton.onPressed, isNull);
    expect(mergeCalled, isFalse);
  });

  testWidgets('Rust merge capability disables unsupported layer types', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(
            layers: const [
              LayerView(id: 21, name: 'Lower', kind: LayerKind.raster),
              LayerView(
                id: 22,
                name: 'Group',
                kind: LayerKind.group,
                order: 1,
                hasMergeDownCapability: true,
                mergeDownReason:
                    'Merge is available only between raster layers.',
              ),
            ],
            selection: LayerSelectionModel(),
            onMergeLayers: (_, _) {},
          ),
        ),
      ),
    );

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<int>(22)),
        matching: find.byTooltip('Layer options'),
      ),
    );
    await tester.pumpAndSettle();
    final optionsScroll = find.byType(Scrollable).last;
    await tester.scrollUntilVisible(
      find.text('Merge down…'),
      240,
      scrollable: optionsScroll,
    );
    final mergeTile = tester.widget<ListTile>(
      find.ancestor(
        of: find.text('Merge down…'),
        matching: find.byType(ListTile),
      ),
    );
    expect(mergeTile.enabled, isFalse);
    expect(
      find.text('Merge is available only between raster layers.'),
      findsOneWidget,
    );
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

    await tester.tap(find.byTooltip('New layer options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Adjustment layer'));
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
      await tester.tap(find.byTooltip('Hide layer; long-press to solo'));
      expect(changed?.visible, isFalse);

      await tester.ensureVisible(find.text('Layer states'));
      await tester.tap(find.text('Layer states'));
      await tester.pumpAndSettle();
      for (final label in const ['Alpha lock', 'Clipping', 'Reference']) {
        expect(find.bySemanticsLabel(label), findsOneWidget);
      }

      await tester.tap(find.bySemanticsLabel('Alpha lock'));
      expect(changed?.alphaLock, isTrue);
      await tester.ensureVisible(find.bySemanticsLabel('Clipping'));
      await tester.tap(find.bySemanticsLabel('Clipping'));
      expect(changed?.clipping, isTrue);
      await tester.ensureVisible(find.bySemanticsLabel('Reference'));
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

  testWidgets('opacity slider previews during drag and commits on release', (
    tester,
  ) async {
    LayerView? started;
    LayerView? committed;
    final previews = <double>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            child: LayerPanel(
              layers: const [
                LayerView(id: 41, name: 'Paint', kind: LayerKind.raster),
              ],
              selection: LayerSelectionModel()..select(41),
              onOpacityEditStarted: (layer) => started = layer,
              onOpacityPreviewChanged: (_, value) => previews.add(value),
              onOpacityEditCommitted: (layer) => committed = layer,
              onOpacityEditCancelled: (_) => fail('drag should commit'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final slider = tester.getRect(find.byType(Slider).first);
    await tester.dragFrom(
      Offset(slider.left + 12, slider.center.dy),
      Offset(slider.width * 0.28, 0),
    );
    await tester.pumpAndSettle();
    expect(started?.id, 41);
    expect(previews, isNotEmpty);
    expect(previews.last, lessThan(1));
    expect(committed?.id, 41);
  });

  testWidgets('Escape cancels an in-progress opacity preview', (tester) async {
    var cancelled = false;
    var committed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            child: LayerPanel(
              layers: const [
                LayerView(id: 42, name: 'Paint', kind: LayerKind.raster),
              ],
              selection: LayerSelectionModel()..select(42),
              onOpacityEditStarted: (_) {},
              onOpacityPreviewChanged: (_, __) {},
              onOpacityEditCommitted: (_) => committed = true,
              onOpacityEditCancelled: (_) => cancelled = true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final slider = tester.getRect(find.byType(Slider).first);
    final gesture = await tester.startGesture(
      Offset(slider.right - 12, slider.center.dy),
    );
    await gesture.moveBy(const Offset(-60, 0));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(cancelled, isTrue);
    expect(committed, isFalse);
  });

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
    await tester.ensureVisible(find.bySemanticsLabel('Clipping'));
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

  testWidgets('deleting an ordinary leaf is immediate and targets that layer', (
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
              LayerView(id: 2, name: 'Color', kind: LayerKind.raster),
            ],
            selection: selection,
            onDeleteLayer: (layer) => deleted = layer,
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Layer options').first);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Delete layer…'),
      80,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Delete layer…'));
    await tester.pumpAndSettle();
    expect(find.text('Delete layer?'), findsNothing);
    expect(deleted?.id, 1);
  });

  testWidgets('deleting the last layer is blocked with an explanation', (
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
    await tester.scrollUntilVisible(
      find.text('Delete layer…'),
      80,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Delete layer…'));
    await tester.pumpAndSettle();
    expect(find.text('Delete layer?'), findsNothing);
    expect(deleted, isNull);
    expect(
      find.text('A document must keep at least one layer.'),
      findsOneWidget,
    );
  });

  testWidgets('deleting the last group subtree is blocked', (tester) async {
    final selection = LayerSelectionModel()..select(1);
    var deleteCalled = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(
            layers: const [
              LayerView(id: 1, name: 'Group', kind: LayerKind.group),
              LayerView(
                id: 2,
                name: 'Only child',
                kind: LayerKind.raster,
                parent: 1,
              ),
            ],
            selection: selection,
            onDeleteLayer: (_) => deleteCalled = true,
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Layer options').first);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Delete layer…'),
      80,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Delete layer…'));
    await tester.pumpAndSettle();

    expect(find.text('Delete layer?'), findsNothing);
    expect(deleteCalled, isFalse);
    expect(
      find.text('A document must keep at least one layer.'),
      findsOneWidget,
    );
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
    await tester.ensureVisible(find.byKey(const ValueKey('reset-adjustment')));
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
              LayerView(id: 3, name: 'Keep', kind: LayerKind.raster),
            ],
            selection: selection,
            onDeleteLayer: (layer) => deleted = layer,
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Layer options').first);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Delete layer…'),
      80,
      scrollable: find.byType(Scrollable).last,
    );
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
    await tester.scrollUntilVisible(
      find.text('Delete layer…'),
      80,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Delete layer…'));
    await tester.pumpAndSettle();
    expect(find.textContaining('owns comic panel content'), findsOneWidget);
    expect(find.text('Delete'), findsNothing);
    expect(deleted, isNull);
  });
}
