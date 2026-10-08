import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:project_ink/bridge/engine_api.dart';
import 'package:project_ink/bridge/generated/api.dart' as rust;
import 'package:project_ink/comics/comic_workspace_controller.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('artist creates, saves, reopens, and exports a two-page comic', (
    tester,
  ) async {
    const preserveFixture = bool.fromEnvironment(
      'PROJECT_INK_PRESERVE_COMIC_JOURNEY',
    );
    final temporary = await Directory.systemTemp.createTemp(
      'project-ink-comic-journey-',
    );
    addTearDown(() async {
      if (!await temporary.exists()) return;
      if (preserveFixture) {
        debugPrint('Preserved comic artist journey: ${temporary.path}');
      } else {
        await temporary.delete(recursive: true);
      }
    });

    final projectPath = '${temporary.path}/the-save-test.inkproj';
    final exportPath = '${temporary.path}/exports';
    await Directory(exportPath).create();
    final engine = await FrbEngineApi.create(
      widthPx: 64,
      heightPx: 64,
      dpi: 144,
    );
    rust.StudioProjectHandle? boundProject;
    final comic = ComicWorkspaceController(
      onProjectChanged: (handle) async {
        boundProject = handle;
        engine.bindStudioProject(handle);
      },
      onActivePageChanged: (handle) async {
        if (handle != null) await engine.rebindDocument(handle);
      },
    );
    int? exportedPages;

    await tester.pumpWidget(const SizedBox.shrink());

    try {
      await comic.createTemplate(1);
      expect(comic.snapshot?.pages, hasLength(1));
      expect(boundProject, isNotNull);

      await comic.applyPanelLayout(
        pageIndex: 0,
        panelCount: 4,
        gutterPx: 24,
        borderPx: 3,
      );
      expect(comic.snapshot!.pages.first.panels, hasLength(4));
      await _addLinkedDialogue(
        comic,
        pageIndex: 0,
        texts: const [
          'I made a comic.',
          'Did you save it?',
          'I did.',
          'Did you reopen it?',
        ],
      );
      await comic.addPrintPage();
      expect(
        comic.snapshot?.pages,
        hasLength(2),
        reason: 'adding a print page failed: ${comic.error}',
      );
      await comic.activatePage(1);
      expect(comic.activePageIndex, 1);

      await comic.applyPanelLayout(
        pageIndex: 1,
        panelCount: 4,
        gutterPx: 24,
        borderPx: 3,
      );
      expect(comic.snapshot!.pages[1].panels, hasLength(4));
      await _addLinkedDialogue(
        comic,
        pageIndex: 1,
        texts: const [
          'Yes.',
          'And the words?',
          'Still here.',
          'Then make a copy.',
        ],
      );
      await comic.activatePage(0);
      await _drawPage(engine, comic.snapshot!.pages.first);
      await comic.activatePage(1);
      await _drawPage(engine, comic.snapshot!.pages[1]);

      expect(await comic.saveProjectAs(projectPath), isTrue);
      await comic.closeProject();
      expect(comic.snapshot, isNull);
      expect(await comic.openProjectFromPath(projectPath), isTrue);

      final reopened = comic.snapshot!;
      expect(reopened.pages, hasLength(2));
      for (var pageIndex = 0; pageIndex < reopened.pages.length; pageIndex++) {
        final page = reopened.pages[pageIndex];
        expect(page.panels, hasLength(4));
        expect(page.balloons, hasLength(4));
        for (
          var panelIndex = 0;
          panelIndex < page.panels.length;
          panelIndex++
        ) {
          expect(
            page.balloons[panelIndex].panelId,
            page.panels[panelIndex].id,
            reason: 'dialogue stays attached to its panel after reopen',
          );
        }
      }
      expect(
        reopened.pages.first.balloons.map((balloon) => balloon.text),
        containsAll(const [
          'I made a comic.',
          'Did you save it?',
          'I did.',
          'Did you reopen it?',
        ]),
      );
      expect(
        reopened.pages.last.balloons.map((balloon) => balloon.text),
        containsAll(const [
          'Yes.',
          'And the words?',
          'Still here.',
          'Then make a copy.',
        ]),
      );

      exportedPages = await comic.batchExportPages(exportPath);
      expect(exportedPages, 2);

      for (var pageNumber = 1; pageNumber <= 2; pageNumber++) {
        final pageName = 'page-${pageNumber.toString().padLeft(4, '0')}';
        final png = File('$exportPath/$pageName.png');
        final svg = File('$exportPath/$pageName.svg');
        expect(await png.exists(), isTrue);
        expect(await svg.exists(), isTrue);
        final svgText = await svg.readAsString();
        final svgTextContent = svgText
            .replaceAll(RegExp(r'<[^>]*>'), ' ')
            .replaceAll('&amp;', '&')
            .replaceAll('&lt;', '<')
            .replaceAll('&gt;', '>')
            .replaceAll('&quot;', '"')
            .replaceAll('&apos;', "'")
            .replaceAll(RegExp(r'\s+'), ' ');
        final page = reopened.pages[pageNumber - 1];
        expect(svgText, contains('data-page-artwork="true"'));
        expect(svgText, contains('data:image/png;base64,'));
        for (
          var panelIndex = 0;
          panelIndex < page.panels.length;
          panelIndex++
        ) {
          final panel = page.panels[panelIndex];
          final balloon = page.balloons[panelIndex];
          expect(svgText, contains('data-panel-id="${panel.id}"'));
          expect(svgText, contains('data-balloon-id="${balloon.id}"'));
          expect(svgText, contains('data-balloon-panel-id="${panel.id}"'));
          expect(svgTextContent, contains(balloon.text));
        }
        await _expectVisibleInkPng(png);
      }
      expect(tester.takeException(), isNull);
      debugPrint('Comic artist journey project: $projectPath');
      debugPrint('Comic artist journey exports: $exportPath');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await comic.closeProject();
      comic.dispose();
      await engine.close();
    }
  });
}

Future<void> _addLinkedDialogue(
  ComicWorkspaceController comic, {
  required int pageIndex,
  required List<String> texts,
}) async {
  final page = comic.snapshot!.pages[pageIndex];
  for (var panelIndex = 0; panelIndex < page.panels.length; panelIndex++) {
    await comic.addBalloon(
      pageIndex: pageIndex,
      panelId: page.panels[panelIndex].id,
    );
    expect(
      comic.snapshot!.pages[pageIndex].balloons,
      isNotEmpty,
      reason:
          'adding dialogue to panel ${page.panels[panelIndex].id} failed: ${comic.error}',
    );
    final balloon = comic.snapshot!.pages[pageIndex].balloons.last;
    await comic.setDialogue(
      pageIndex: pageIndex,
      balloonId: balloon.id,
      text: texts[panelIndex],
    );
  }
}

Future<void> _drawPage(FrbEngineApi engine, rust.ComicPageView page) async {
  debugPrint('Drawing test comic page ${page.pageNumber}');
  final layerId = await engine.addLayer(kind: 'VectorInk');
  await engine.updateLayerPresentation(
    layerId: layerId,
    name: 'Ink',
    blendMode: 'Normal',
    groupMode: 'Pass-through',
    labelRgba: null,
  );
  final panel = page.panels.first;
  final centerX = panel.x + panel.width * 0.36;
  final headY = panel.y + panel.height * 0.64;
  final radius = math.min(panel.width, panel.height) * 0.065;
  final shoulderY = headY + radius * 1.45;
  final hipY = panel.y + panel.height * 0.86;
  final figure = List<Offset>.generate(17, (index) {
    final angle = math.pi / 2 + math.pi * 2 * index / 16;
    return Offset(
      centerX + radius * math.cos(angle),
      headY + radius * math.sin(angle),
    );
  });
  figure.addAll([
    Offset(centerX, headY + radius),
    Offset(centerX, shoulderY),
    Offset(centerX - panel.width * 0.12, shoulderY + panel.height * 0.09),
    Offset(centerX, shoulderY),
    Offset(centerX + panel.width * 0.12, shoulderY + panel.height * 0.07),
    Offset(centerX, shoulderY),
    Offset(centerX, hipY),
    Offset(centerX + panel.width * 0.1, panel.y + panel.height * 0.97),
    Offset(centerX, hipY),
    Offset(centerX - panel.width * 0.1, panel.y + panel.height * 0.97),
  ]);
  await _inkStroke(engine, layerId, figure);
  debugPrint('Finished test comic page ${page.pageNumber}');
}

Future<void> _inkStroke(
  FrbEngineApi engine,
  int layerId,
  List<Offset> points,
) async {
  await engine.addVectorStroke(
    layerId: layerId,
    points: <double>[
      for (final point in points) ...<double>[point.dx, point.dy, 1, 0],
    ],
    closed: false,
  );
}

Future<void> _expectVisibleInkPng(File file) async {
  final codec = await ui.instantiateImageCodec(await file.readAsBytes());
  try {
    final frame = await codec.getNextFrame();
    final image = frame.image;
    expect(image.width, 2400);
    expect(image.height, 1800);
    final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    expect(pixels, isNotNull);
    var darkPixelCount = 0;
    for (var offset = 0; offset < pixels!.lengthInBytes; offset += 4) {
      final red = pixels.getUint8(offset);
      final green = pixels.getUint8(offset + 1);
      final blue = pixels.getUint8(offset + 2);
      if (red < 96 && green < 96 && blue < 96) darkPixelCount++;
    }
    expect(darkPixelCount, greaterThan(100));
    image.dispose();
  } finally {
    codec.dispose();
  }
}
