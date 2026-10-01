import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/canvas/workspace_panels.dart';
import 'package:project_ink/comics/comic_workspace.dart';
import 'package:project_ink/tools/brush_library.dart';

void main() {
  testWidgets('tool properties exposes the active brush settings', (
    tester,
  ) async {
    final library = BrushLibraryModel(const [
      BrushPresetView(id: 1, name: 'Test pen', family: BrushFamily.ink),
    ]);
    library.select(1);
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 360,
          height: 600,
          child: InkToolPropertiesPanel(
            library: library,
            activeTool: 'Brush',
            eraserActive: false,
            activeLayerName: 'Ink',
            onBrushChanged: (_) {},
            onToggleEraser: () {},
            onBrushColor: () {},
            onOpenLayers: () {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Tool Properties'), findsOneWidget);
    expect(find.text('Test pen'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('materials panel has a safe empty-project state', (tester) async {
    final controller = ComicWorkspaceController();
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 360,
          height: 600,
          child: InkMaterialsPanel(controller: controller, onOpenComics: () {}),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Materials'), findsOneWidget);
    expect(find.text('No project materials yet.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    controller.dispose();
  });
}
