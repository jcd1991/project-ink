import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:project_ink/design_system/ink_components.dart';
import 'package:project_ink/bridge/engine_api/in_memory_engine_api.dart';
import 'package:project_ink/tools/brush_library.dart';
import 'package:project_ink/tools/brush_library_panel.dart';

void main() {
  test('all in-memory built-in brushes expose stylus pressure response', () async {
    final summaries = await InMemoryEngineApi().builtinBrushes();

    expect(summaries, hasLength(20));
    for (final brush in summaries) {
      expect(
        brush.pressureSize > 0 || brush.pressureOpacity > 0,
        isTrue,
        reason: '${brush.name} should respond to stylus pressure',
      );
      expect(brush.pressureCurvePoints, isNotEmpty);
    }
  });

  test('selection requested before projection is applied when it arrives', () {
    final library = BrushLibraryModel(const <BrushPresetView>[]);
    library.selectWhenAvailable(13);

    library.upsert(
      const BrushPresetView(
        id: 13,
        name: 'Imported brush',
        family: BrushFamily.ink,
      ),
    );

    expect(library.selected?.id, 13);
  });

  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(<String, Object>{});
  test('brush library supports favorites and bounded configurable drafts', () {
    final library = BrushLibraryModel(<BrushPresetView>[
      const BrushPresetView(id: 7, name: 'G-Pen', family: BrushFamily.ink),
      const BrushPresetView(
        id: 8,
        name: 'Watercolor',
        family: BrushFamily.watercolor,
      ),
    ]);
    library.select(8);
    library.toggleFavorite(8);
    library.updateDraft(library.selected!.copyWith(size: 24, wetness: 0.8));
    expect(library.favorites.single.id, 8);
    expect(library.selected!.size, 24);
    expect(library.selected!.wetness, 0.8);
  });

  test(
    'projection refresh trusts Rust controls and preserves UI favorites',
    () {
      final library = BrushLibraryModel(<BrushPresetView>[
        const BrushPresetView(id: 7, name: 'G-Pen', family: BrushFamily.ink),
      ]);
      library.select(7);
      library.toggleFavorite(7);
      library.updateDraft(
        library.selected!.copyWith(size: 28, opacity: 0.7, wetness: 0.4),
      );

      library.upsert(
        const BrushPresetView(
          id: 7,
          name: 'G-Pen (Rust projection)',
          family: BrushFamily.ink,
          size: 42,
          opacity: 0.9,
          wetness: 0.1,
          pressureCurvePoints: <BrushCurvePointView>[
            BrushCurvePointView(x: 0, y: 0),
            BrushCurvePointView(x: 1, y: 1),
          ],
        ),
      );

      expect(library.selected!.size, 42);
      expect(library.selected!.opacity, 0.9);
      expect(library.selected!.wetness, 0.1);
      expect(library.selected!.favorite, isTrue);
      expect(library.selected!.name, 'G-Pen (Rust projection)');
      expect(library.selected!.pressureCurvePoints, hasLength(2));
    },
  );

  test('search and tag filters are reactive and composable', () {
    final library = BrushLibraryModel(<BrushPresetView>[
      const BrushPresetView(
        id: 1,
        name: 'Technical Pen',
        family: BrushFamily.ink,
        tags: <String>['ink', 'line'],
      ),
      const BrushPresetView(
        id: 2,
        name: 'Watercolor Wash',
        family: BrushFamily.watercolor,
        tags: <String>['paint', 'wash'],
      ),
    ]);
    var notifications = 0;
    library.addListener(() => notifications++);

    library.setSearchQuery('water');
    expect(library.filteredPresets.map((preset) => preset.id).toList(), <int>[
      2,
    ]);
    library.setSearchQuery('');
    library.toggleTagFilter('ink');
    expect(library.filteredPresets.map((preset) => preset.id).toList(), <int>[
      1,
    ]);
    expect(library.tags, <String>['ink', 'line', 'paint', 'wash']);
    expect(notifications, 3);
  });

  test('family filters and recents compose with search and favorites', () {
    final library = BrushLibraryModel(<BrushPresetView>[
      const BrushPresetView(
        id: 1,
        name: 'G-Pen',
        family: BrushFamily.ink,
        isBuiltin: true,
      ),
      const BrushPresetView(
        id: 2,
        name: 'Graphite',
        family: BrushFamily.sketch,
      ),
    ]);

    library.select(2);
    library.setBrowserFilter(BrushBrowserFilter.recent);
    expect(library.filteredPresets.map((preset) => preset.id), <int>[2]);
    library.setFamilyFilter(BrushFamily.ink);
    expect(library.filteredPresets, isEmpty);
    library.setFamilyFilter(null);
    library.setSearchQuery('graph');
    expect(library.filteredPresets.map((preset) => preset.id), <int>[2]);
  });

  test(
    'favorites and recent brushes restore across library instances',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final presets = <BrushPresetView>[
        const BrushPresetView(
          id: 1,
          name: 'Technical Pen',
          family: BrushFamily.ink,
          isBuiltin: true,
        ),
      ];
      final first = BrushLibraryModel(presets)..select(1);
      first.toggleFavorite(1);
      await first.persistLocalState();

      final reopened = BrushLibraryModel(presets);
      await reopened.restoreLocalState();
      reopened.setBrowserFilter(BrushBrowserFilter.recent);
      expect(reopened.filteredPresets.map((preset) => preset.id), <int>[1]);
      expect(reopened.favorites.single.id, 1);
    },
  );

  test('device-local brush sets filter and restore their membership', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final presets = <BrushPresetView>[
      const BrushPresetView(
        id: 1,
        name: 'Technical Pen',
        family: BrushFamily.ink,
      ),
      const BrushPresetView(
        id: 2,
        name: 'Graphite',
        family: BrushFamily.sketch,
      ),
    ];
    final first = BrushLibraryModel(presets)..select(1);
    final setId = first.createSet('Line work');
    first.addSelectedToSet(setId);
    first.toggleFavorite(1);
    first.updateDraft(first.selected!.copyWith(size: 18));
    await first.persistLocalState();

    // A copy stored in another artwork may receive a different local ID.
    final reopened = BrushLibraryModel(<BrushPresetView>[
      const BrushPresetView(
        id: 99,
        name: 'Technical Pen',
        family: BrushFamily.ink,
        size: 18,
      ),
      const BrushPresetView(
        id: 100,
        name: 'Graphite',
        family: BrushFamily.sketch,
      ),
    ]);
    await reopened.restoreLocalState();
    reopened.selectSet(setId);
    expect(reopened.sets.single.name, 'Line work');
    expect(reopened.filteredPresets.map((preset) => preset.id), <int>[99]);
    expect(reopened.favorites.single.id, 99);
    reopened.setBrowserFilter(BrushBrowserFilter.recent);
    expect(reopened.filteredPresets.map((preset) => preset.id), <int>[99]);
  });

  testWidgets('brush favorites can be marked and filtered in the panel', (
    tester,
  ) async {
    final library = BrushLibraryModel(<BrushPresetView>[
      const BrushPresetView(id: 1, name: 'G-Pen', family: BrushFamily.ink),
      const BrushPresetView(
        id: 2,
        name: 'Watercolor',
        family: BrushFamily.watercolor,
      ),
    ])..select(1);

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: BrushLibraryPanel(library: library))),
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('toggle-brush-favorite')),
    );
    await tester.tap(find.byKey(const ValueKey('toggle-brush-favorite')));
    await tester.pumpAndSettle();
    expect(library.favorites.single.id, 1);

    await tester.drag(find.byType(ListView).first, const Offset(0, 1600));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('brush-favorites-filter')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('brush-favorites-filter')));
    await tester.pumpAndSettle();
    expect(library.filteredPresets.map((preset) => preset.id), <int>[1]);
  });

  testWidgets('brush thumbnail asks the engine API for preview pixels', (
    tester,
  ) async {
    final engine = InMemoryEngineApi();
    var previewCalls = 0;
    final library = BrushLibraryModel(<BrushPresetView>[
      const BrushPresetView(
        id: 1,
        name: 'Technical Pen',
        family: BrushFamily.ink,
        isBuiltin: true,
      ),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BrushLibraryPanel(
            library: library,
            renderPreview: (id, width, height, points) async {
              previewCalls++;
              return engine.renderBrushPreview(
                brushId: id,
                width: width,
                height: height,
                points: points,
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(previewCalls, 1);
    expect(find.byType(Image), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('scratchpad forwards stylus samples to the preview renderer', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final engine = InMemoryEngineApi();
    var scratchSamples = 0;
    final library = BrushLibraryModel(<BrushPresetView>[
      const BrushPresetView(id: 13, name: 'Ink Copy', family: BrushFamily.ink),
    ])..select(13);
    library.toggleEditor();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BrushLibraryPanel(
            library: library,
            renderPreview: (id, width, height, points) {
              if (height == 120) scratchSamples = points.length;
              return engine.renderBrushPreview(
                brushId: id,
                width: width,
                height: height,
                points: points,
              );
            },
          ),
        ),
      ),
    );
    final pad = find.bySemanticsLabel('Brush test pad');
    expect(pad, findsOneWidget);
    // The semantics node marks the pad's actionable region.
    final center = tester.getRect(pad).center;
    final gesture = await tester.startGesture(
      center.translate(-24, 0),
      kind: PointerDeviceKind.stylus,
    );
    await gesture.moveTo(center, timeStamp: const Duration(milliseconds: 20));
    await gesture.moveTo(
      center.translate(24, 4),
      timeStamp: const Duration(milliseconds: 40),
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(scratchSamples, greaterThanOrEqualTo(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('custom brush rename action is only enabled for user brushes', (
    tester,
  ) async {
    var renameCount = 0;
    final library = BrushLibraryModel(<BrushPresetView>[
      const BrushPresetView(
        id: 1,
        name: 'G-Pen',
        family: BrushFamily.ink,
        isBuiltin: true,
      ),
      const BrushPresetView(
        id: 13,
        name: 'G-Pen Copy',
        family: BrushFamily.ink,
      ),
    ])..select(1);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BrushLibraryPanel(
            library: library,
            onRename: () => renameCount++,
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Brush actions'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<PopupMenuItem<String>>(
            find.byType(PopupMenuItem<String>).last,
          )
          .enabled,
      isFalse,
    );
    await tester.tapAt(const Offset(10, 10));
    library.select(13);
    await tester.pump();
    await tester.tap(find.byTooltip('Brush actions'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<PopupMenuItem<String>>(
            find.byType(PopupMenuItem<String>).last,
          )
          .enabled,
      isTrue,
    );
    await tester.tap(find.text('Rename brush').last);
    expect(renameCount, 1);
  });

  testWidgets('brush draft exposes an explicit save and cancel boundary', (
    tester,
  ) async {
    var commitCount = 0;
    var cancelCount = 0;
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final library = BrushLibraryModel(<BrushPresetView>[
      const BrushPresetView(
        id: 13,
        name: 'Ink Pen Copy',
        family: BrushFamily.ink,
      ),
    ])..select(13);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BrushLibraryPanel(
            library: library,
            hasUncommittedChanges: true,
            onCommitEdit: () => commitCount++,
            onCancelEdit: () => cancelCount++,
          ),
        ),
      ),
    );

    final saveButton = find.byKey(const ValueKey('commit-brush-edit'));
    final cancelButton = find.byKey(const ValueKey('cancel-brush-edit'));
    expect(tester.widget<FilledButton>(saveButton).onPressed, isNotNull);
    expect(tester.widget<OutlinedButton>(cancelButton).onPressed, isNotNull);
    await tester.tap(saveButton);
    await tester.tap(cancelButton);
    expect(commitCount, 1);
    expect(cancelCount, 1);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BrushLibraryPanel(library: library, onCommitEdit: () {}),
        ),
      ),
    );
    expect(saveButton, findsNothing);
  });

  testWidgets('pulled-string brush settings are editable in the stroke draft', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final library = BrushLibraryModel(<BrushPresetView>[
      const BrushPresetView(
        id: 13,
        name: 'Ink Pen Copy',
        family: BrushFamily.ink,
      ),
    ])..select(13);
    library.toggleEditor();
    BrushPresetView? changed;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BrushLibraryPanel(
            library: library,
            onChanged: (preset) => changed = preset,
          ),
        ),
      ),
    );

    final stabilizerSwitch = find.text('Pulled-string stabilizer');
    await tester.ensureVisible(stabilizerSwitch);
    await tester.tap(stabilizerSwitch);
    await tester.pumpAndSettle();
    expect(library.selected!.pulledString, isTrue);
    expect(find.text('String distance'), findsOneWidget);
    expect(changed!.pulledString, isTrue);

    final distanceSlider = find.byType(Slider).last;
    await tester.ensureVisible(distanceSlider);
    await tester.drag(distanceSlider, const Offset(48, 0));
    await tester.pumpAndSettle();
    expect(library.selected!.stabilizerDistancePx, greaterThan(0));
    expect(changed!.stabilizerDistancePx, greaterThan(0));

    final catchUpSwitch = find.text('Catch up at stroke end');
    await tester.ensureVisible(catchUpSwitch);
    await tester.tap(catchUpSwitch);
    await tester.pumpAndSettle();
    expect(library.selected!.catchUpOnEnd, isTrue);
    expect(changed!.catchUpOnEnd, isTrue);
  });

  testWidgets('advanced custom brush size stays inside the draft boundary', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var onSizeChangeEndCalls = 0;
    var onChangedCalls = 0;
    final library = BrushLibraryModel(<BrushPresetView>[
      const BrushPresetView(id: 13, name: 'Ink Copy', family: BrushFamily.ink),
    ])..select(13);
    final originalSize = library.selected!.size;
    library.toggleEditor();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BrushLibraryPanel(
            library: library,
            onChanged: (_) => onChangedCalls++,
            onSizeChangeEnd: (_) => onSizeChangeEndCalls++,
          ),
        ),
      ),
    );
    final sizeSlider = find.byType(Slider).first;
    await tester.ensureVisible(sizeSlider);
    await tester.drag(sizeSlider, const Offset(48, 0));
    await tester.pumpAndSettle();

    expect(onChangedCalls, greaterThan(0));
    expect(onSizeChangeEndCalls, 0);
    expect(library.selected!.size, isNot(originalSize));
  });

  testWidgets('brush rename dialog returns edited text and disposes safely', (
    tester,
  ) async {
    String? renamed;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder:
              (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    renamed = await showDialog<String>(
                      context: context,
                      builder:
                          (_) => const BrushRenameDialog(
                            initialName: 'G-Pen Copy',
                          ),
                    );
                  },
                  child: const Text('Open rename'),
                ),
              ),
        ),
      ),
    );
    await tester.tap(find.text('Open rename'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('rename-brush-name-field')),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const ValueKey('rename-brush-name-field')),
      'Ink Manga Pen',
    );
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    expect(renamed, 'Ink Manga Pen');
    expect(tester.takeException(), isNull);
  });

  testWidgets('brush editor accepts the engine maximum imported values', (
    tester,
  ) async {
    final library = BrushLibraryModel(<BrushPresetView>[
      const BrushPresetView(
        id: 99,
        name: 'Imported oversized texture',
        family: BrushFamily.texture,
        size: 4096,
        textureScale: 64,
      ),
    ])..select(99);
    library.toggleEditor();
    library.selectEditorSection(BrushEditorSection.tip);

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: BrushLibraryPanel(library: library))),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Size'), findsOneWidget);
    expect(find.text('4096.0 px'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Texture scale'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Texture scale'), findsOneWidget);
    expect(find.text('64.00x'), findsOneWidget);
  });

  testWidgets('brush size slider maps practical sizes logarithmically', (
    tester,
  ) async {
    final library = BrushLibraryModel(<BrushPresetView>[
      const BrushPresetView(
        id: 7,
        name: 'G-Pen',
        family: BrushFamily.ink,
        size: 10,
      ),
    ])..select(7);

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: BrushLibraryPanel(library: library))),
    );

    final sizeControlFinder = find.byWidgetPredicate(
      (widget) => widget is InkPropertySlider && widget.label == 'Size',
    );
    final sizeControl = tester.widget<InkPropertySlider>(sizeControlFinder);
    expect(sizeControl.min, 0);
    expect(sizeControl.max, 1);
    expect(sizeControl.value, closeTo(0.38, 0.02));

    sizeControl.onChanged!(0.5);
    await tester.pump();

    expect(library.selected!.size, closeTo(32, 0.001));
    expect(find.text('32.0 px'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('visible brush controls stay in Flutter semantics after scroll', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final library = BrushLibraryModel(<BrushPresetView>[
      const BrushPresetView(
        id: 99,
        name: 'Imported oversized texture',
        family: BrushFamily.texture,
        size: 4096,
        textureScale: 64,
      ),
    ])..select(99);
    library.toggleEditor();
    library.selectEditorSection(BrushEditorSection.tip);

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: BrushLibraryPanel(library: library))),
    );
    await tester.scrollUntilVisible(
      find.text('Texture scale'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    // Slider semantics combine the explicit label, child text, and value;
    // match the label within that composed string.
    expect(find.bySemanticsLabel(RegExp('Texture scale')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Tip hardness')), findsOneWidget);
    await tester.ensureVisible(find.text('Paint'));
    await tester.tap(find.text('Paint'));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel(RegExp('Wetness')), findsOneWidget);
    semantics.dispose();
  });
}
