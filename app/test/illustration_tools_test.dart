import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/tools/illustration_tools.dart';

void main() {
  testWidgets(
    'brush, eraser, and panel divider are directly visible tool rows',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: IllustrationToolPalette(
              selected: IllustrationTool.brush,
              onSelected: (_) {},
              onClearSelection: () {},
              onTransformPreset: (_) {},
            ),
          ),
        ),
      );

      expect(find.text('Brush'), findsOneWidget);
      expect(find.text('Eraser'), findsOneWidget);
      expect(find.text('Paint'), findsNothing);
      expect(find.text('Panel divider'), findsOneWidget);
      expect(
        find.text('Choose a layout or drag across a frame to split it'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Panel tool exposes the shared 2/3/4 layout presets', (
    tester,
  ) async {
    int? selectedLayout;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: IllustrationToolPalette(
            selected: IllustrationTool.panel,
            onSelected: (_) {},
            onClearSelection: () {},
            onTransformPreset: (_) {},
            onApplyPanelLayout: (count) => selectedLayout = count,
          ),
        ),
      ),
    );

    for (final count in [2, 3, 4]) {
      final preset = find.text('$count panels');
      expect(preset, findsOneWidget);
      await tester.ensureVisible(preset);
      await tester.tap(preset);
      expect(selectedLayout, count);
    }
    expect(
      find.textContaining('drag left to right for a horizontal divider'),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(find.text('Create your first split')).dy,
      lessThan(tester.getTopLeft(find.text('Select and fill')).dy),
    );
  });

  testWidgets('layout presets stay disabled while the panel project loads', (
    tester,
  ) async {
    var selectedLayout = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: IllustrationToolPalette(
            selected: IllustrationTool.panel,
            onSelected: (_) {},
            onClearSelection: () {},
            onTransformPreset: (_) {},
            onApplyPanelLayout: (_) => selectedLayout = true,
            panelLoading: true,
          ),
        ),
      ),
    );

    expect(find.text('Preparing panel editing…'), findsOneWidget);
    final preset = find.ancestor(
      of: find.text('2 panels'),
      matching: find.byType(OutlinedButton),
    );
    expect(tester.widget<OutlinedButton>(preset).onPressed, isNull);
    expect(selectedLayout, isFalse);
  });

  testWidgets('existing panels explain split and gutter gestures', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: IllustrationToolPalette(
            selected: IllustrationTool.panel,
            onSelected: (_) {},
            onClearSelection: () {},
            onTransformPreset: (_) {},
            panelCount: 2,
          ),
        ),
      ),
    );

    expect(find.text('Split or adjust a frame'), findsOneWidget);
    expect(
      find.textContaining('Drag through a frame to split it'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Drag a gutter to move its divider'),
      findsOneWidget,
    );
    expect(find.text('Gutter  24 px'), findsOneWidget);
    expect(find.text('Border  2.0 px'), findsOneWidget);
    expect(find.text('2 panels'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
