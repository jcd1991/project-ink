import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/app/editor_action.dart';
import 'package:project_ink/app/workspace_preferences.dart';
import 'package:project_ink/bridge/engine_api.dart';
import 'package:project_ink/canvas/canvas_workspace_panel_sheets.dart';

void main() {
  testWidgets('Quick Access sheet dispatches selected actions', (tester) async {
    final dispatched = <EditorActionId>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder:
              (context) => Scaffold(
                body: TextButton(
                  onPressed: () {
                    showCanvasQuickAccessSheet(
                      context: context,
                      sets: defaultQuickAccessSets,
                      activeSetId: 'default',
                      onAction: dispatched.add,
                      onChanged: (_, _) {},
                    );
                  },
                  child: const Text('Open Quick Access'),
                ),
              ),
        ),
      ),
    );

    await tester.tap(find.text('Open Quick Access'));
    await tester.pumpAndSettle();
    expect(find.text('Quick Access'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel(EditorActionId.undo.label));
    await tester.pumpAndSettle();

    expect(dispatched, [EditorActionId.undo]);
    expect(find.text('Quick Access'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('History sheet reads from the provided engine', (tester) async {
    final engine = InMemoryEngineApi();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder:
              (context) => Scaffold(
                body: TextButton(
                  onPressed: () {
                    showCanvasHistorySheet(
                      context: context,
                      engine: engine,
                      revisionToken: 0,
                      onNavigate: (_) async {},
                    );
                  },
                  child: const Text('Open History'),
                ),
              ),
        ),
      ),
    );

    await tester.tap(find.text('Open History'));
    await tester.pumpAndSettle();

    expect(find.text('History'), findsOneWidget);
    expect(find.text('No edits yet'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
