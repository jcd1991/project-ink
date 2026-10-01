import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:project_ink/design_system/ink_components.dart';
import 'package:project_ink/tools/brush_library.dart';
import 'package:project_ink/tools/brush_library_panel.dart';

void main() {
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

  testWidgets('custom brush rename action is only enabled for user brushes', (
    tester,
  ) async {
    var renameCount = 0;
    final library = BrushLibraryModel(<BrushPresetView>[
      const BrushPresetView(id: 1, name: 'G-Pen', family: BrushFamily.ink),
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
    final renameButton = find.byKey(const ValueKey('rename-brush'));
    expect(tester.widget<OutlinedButton>(renameButton).onPressed, isNull);
    library.select(13);
    await tester.pump();
    expect(tester.widget<OutlinedButton>(renameButton).onPressed, isNotNull);
    await tester.tap(renameButton);
    expect(renameCount, 1);
  });

  testWidgets('brush draft exposes an explicit save and cancel boundary', (
    tester,
  ) async {
    var commitCount = 0;
    var cancelCount = 0;
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
    expect(tester.widget<OutlinedButton>(saveButton).onPressed, isNotNull);
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
    expect(tester.widget<OutlinedButton>(saveButton).onPressed, isNull);
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
    expect(find.bySemanticsLabel(RegExp('Wetness')), findsOneWidget);
    semantics.dispose();
  });
}
