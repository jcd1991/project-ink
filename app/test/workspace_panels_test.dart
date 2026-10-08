import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/bridge/generated/api.dart' as rust;
import 'package:project_ink/canvas/canvas_workspace_widgets.dart';
import 'package:project_ink/canvas/workspace_panels.dart';
import 'package:project_ink/comics/comic_workspace.dart';
import 'package:project_ink/comics/comic_workspace_controller.dart';
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

  testWidgets('panel guide uses the active page without a raster preview', (
    tester,
  ) async {
    final controller = _PanelGuideWorkspace(_panelProject());
    expect(controller.pagePreviewIndex, isNull);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ComicCanvasGuideOverlay(
            controller: controller,
            pan: Offset.zero,
            scale: 1,
            rotation: 0,
            mirrored: false,
            documentWidth: 1024,
            documentHeight: 1024,
          ),
        ),
      ),
    );

    expect(
      find.descendant(
        of: find.byType(ComicCanvasGuideOverlay),
        matching: find.byType(CustomPaint),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    controller.dispose();
  });
}

class _PanelGuideWorkspace extends ComicWorkspaceController {
  _PanelGuideWorkspace(this.project);

  final rust.ComicProjectView project;

  @override
  rust.ComicProjectView? get snapshot => project;

  @override
  int get activePageIndex => 0;
}

rust.ComicProjectView _panelProject() => rust.ComicProjectView(
  id: BigInt.one,
  template: 0,
  title: 'Illustration',
  pageCount: 1,
  pages: [
    rust.ComicPageView(
      id: BigInt.from(2),
      pageNumber: 1,
      widthPx: 1024,
      heightPx: 1024,
      dpi: 300,
      panelCount: 1,
      balloonCount: 0,
      toneCount: 0,
      effectLineCount: 0,
      panels: [
        rust.ComicPanelPreviewView(
          id: BigInt.from(3),
          shape: 0,
          x: 0,
          y: 0,
          width: 1024,
          height: 1024,
          gutterPx: 24,
          borderPx: 2,
          panelGroupId: BigInt.from(4),
          maskLayerId: BigInt.from(5),
          sketchLayerId: BigInt.from(6),
          inkLayerId: BigInt.from(7),
          colorLayerId: BigInt.from(8),
          toneLayerId: BigInt.from(9),
          effectsLayerId: BigInt.from(10),
          polygon: Float32List.fromList(const []),
        ),
      ],
      balloons: const [],
      tones: const [],
      effectLines: const [],
      bleedLeft: 0,
      bleedTop: 0,
      bleedRight: 0,
      bleedBottom: 0,
      trimX: 0,
      trimY: 0,
      trimWidth: 1024,
      trimHeight: 1024,
      safetyLeft: 0,
      safetyTop: 0,
      safetyRight: 0,
      safetyBottom: 0,
    ),
  ],
  materials: const [],
);
