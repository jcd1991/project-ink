import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:project_ink/bridge/engine_api.dart';
import 'package:project_ink/app/project_ink_app.dart';
import 'package:project_ink/canvas/canvas_screen.dart';
import 'package:project_ink/comics/comic_workspace.dart';
import 'package:project_ink/documents/document_picker.dart';
import 'package:project_ink/tools/brush_library.dart' show BrushCurvePointView;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Rust bridge persists a representative layer workflow on disk', (
    tester,
  ) async {
    final temporary = await Directory.systemTemp.createTemp(
      'project-ink-layer-alpha-',
    );
    addTearDown(() async {
      if (await temporary.exists()) await temporary.delete(recursive: true);
    });
    final engine = await FrbEngineApi.create(
      widthPx: 512,
      heightPx: 512,
      dpi: 144,
    );
    FrbEngineApi? reopened;
    try {
      final layerId = await engine.addLayer(kind: 'Raster');
      await engine.updateLayerPresentation(
        layerId: layerId,
        name: 'Alpha Ink Layer',
        blendMode: 'Normal',
        groupMode: 'Pass-through',
        labelRgba: 0xff3366ff,
      );
      await engine.setLayersVisibility(layerIds: [layerId], visible: false);
      final projectPath = '${temporary.path}/layers.inkproj';
      await engine.saveAs(projectPath);
      await engine.close();
      reopened = await FrbEngineApi.open(projectPath);

      final layers = await reopened.layerSummaries();
      final persistedLayer = layers.singleWhere((layer) => layer.id == layerId);
      expect(persistedLayer.name, 'Alpha Ink Layer');
      expect(persistedLayer.visible, isFalse);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      if (reopened != null) await reopened.close();
      await engine.close();
    }
  });

  testWidgets(
    'Rust bridge persists edited and re-imported custom brush settings',
    (tester) async {
      final temporary = await Directory.systemTemp.createTemp(
        'project-ink-brush-alpha-',
      );
      addTearDown(() async {
        if (await temporary.exists()) await temporary.delete(recursive: true);
      });
      final engine = await FrbEngineApi.create(
        widthPx: 512,
        heightPx: 512,
        dpi: 144,
      );
      FrbEngineApi? reopened;
      try {
        final brush = (await engine.builtinBrushes()).firstWhere(
          (candidate) => candidate.isBuiltin,
        );
        final draftId = await engine.beginBrushDraft(brush.id);
        final editedDiameter = brush.diameterPx + 7;
        await engine.updateBrushDraft(
          draftId: draftId,
          diameter: editedDiameter,
          opacity: brush.opacity,
          spacing: brush.spacing,
          smoothing: brush.smoothing,
          pressureSize: brush.pressureSize,
          pressureOpacity: brush.pressureOpacity,
          pressureCurve: 1,
          pressureCurvePoints: const <BrushCurvePointView>[
            BrushCurvePointView(x: 0, y: 0),
            BrushCurvePointView(x: 1, y: 1),
          ],
          hardness: brush.hardness,
          textureScale: brush.textureScale,
          scatter: brush.scatter,
          rotationJitter: brush.rotationJitter,
          smudge: brush.smudge,
          wetness: brush.wetness,
        );
        await engine.commitBrushDraft(draftId);

        final brushPath = '${temporary.path}/edited.inkbrush';
        await engine.exportBrush(brushId: brush.id, path: brushPath);
        final importedBrushId = await engine.importBrush(brushPath);
        final importedBrush = (await engine.builtinBrushes()).firstWhere(
          (candidate) => candidate.id == importedBrushId,
        );
        expect(importedBrush.diameterPx, closeTo(editedDiameter, 0.001));

        final projectPath = '${temporary.path}/brushes.inkproj';
        await engine.saveAs(projectPath);
        await engine.close();
        reopened = await FrbEngineApi.open(projectPath);
        final persistedBrush = (await reopened.builtinBrushes()).singleWhere(
          (candidate) => candidate.id == importedBrushId,
        );
        expect(persistedBrush.diameterPx, closeTo(editedDiameter, 0.001));
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        if (reopened != null) await reopened.close();
        await engine.close();
      }
    },
  );

  testWidgets(
    'Rust comic workflow saves, reopens, and exports multiple pages',
    (tester) async {
      final temporary = await Directory.systemTemp.createTemp(
        'project-ink-comic-alpha-',
      );
      addTearDown(() async {
        if (await temporary.exists()) await temporary.delete(recursive: true);
      });
      final comicPath = '${temporary.path}/alpha-comic.inkproj';
      final exportPath = '${temporary.path}/exported-pages';
      await Directory(exportPath).create();
      final comic = ComicWorkspaceController();
      final reopenedComic = ComicWorkspaceController();
      try {
        await comic.createTemplate(1);
        await comic.addPanel();
        await comic.addBalloon();
        final balloon = comic.snapshot!.pages.first.balloons.first;
        await comic.setDialogue(
          pageIndex: 0,
          balloonId: balloon.id,
          text: 'Alpha round trip',
        );
        await comic.addPrintPage();
        expect(comic.snapshot?.pages, hasLength(2));
        expect(await comic.saveProjectAs(comicPath), isTrue);

        await comic.closeProject();
        expect(await reopenedComic.openProjectFromPath(comicPath), isTrue);
        final snapshot = reopenedComic.snapshot!;
        expect(snapshot.pages, hasLength(2));
        expect(snapshot.pages.first.panels, isNotEmpty);
        expect(snapshot.pages.first.balloons.single.text, 'Alpha round trip');
        expect(await reopenedComic.batchExportPages(exportPath), 2);
        final exports =
            await Directory(exportPath)
                .list()
                .where(
                  (entity) => entity is File && entity.path.endsWith('.svg'),
                )
                .length;
        expect(exports, 2);
        expect(tester.takeException(), isNull);
      } finally {
        await comic.closeProject();
        await reopenedComic.closeProject();
        comic.dispose();
        reopenedComic.dispose();
      }
    },
  );

  testWidgets(
    'Rust bridge round-trip preserves pixels and recovery on corrupt Open',
    (tester) async {
      final temporary = await Directory.systemTemp.createTemp(
        'project-ink-release-round-trip-',
      );
      addTearDown(() async {
        if (await temporary.exists()) await temporary.delete(recursive: true);
      });
      final projectPath = '${temporary.path}/round-trip.inkproj';
      final engine = await FrbEngineApi.create(
        widthPx: 1024,
        heightPx: 1024,
        dpi: 144,
      );
      FrbEngineApi? reopened;

      try {
        await tester.pumpWidget(
          MaterialApp(
            home: CanvasScreen(
              engine: engine,
              targetPlatform: TargetPlatform.macOS,
              comicWorkspaceController: ComicWorkspaceController(),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));

        final canvas = find.bySemanticsLabel('Drawing canvas');
        expect(canvas, findsOneWidget);
        final bounds = tester.getRect(canvas);
        final start = bounds.center - const Offset(100, 35);
        final finish = bounds.center + const Offset(100, 35);
        const tileX = 1;
        const tileY = 1;
        final emptyPixels = await engine.readCompositeTile(x: tileX, y: tileY);
        final emptyHash = _fnv1a32(emptyPixels);

        final gesture = await tester.startGesture(
          start,
          kind: PointerDeviceKind.touch,
        );
        for (var index = 1; index <= 48; index++) {
          final fraction = index / 48;
          await gesture.moveTo(Offset.lerp(start, finish, fraction)!);
          if (index % 6 == 0) {
            await tester.pump(const Duration(milliseconds: 16));
          }
        }
        await gesture.up();
        for (var frame = 0; frame < 20; frame++) {
          await tester.pump(const Duration(milliseconds: 50));
        }

        final drawnHash = _fnv1a32(
          await engine.readCompositeTile(x: tileX, y: tileY),
        );
        expect(drawnHash, isNot(emptyHash), reason: 'stroke commits to Rust');
        expect(engine.revision, greaterThan(0));

        await engine.saveAs(projectPath);
        expect(await Directory(projectPath).exists(), isTrue);
        await tester.pumpWidget(const SizedBox.shrink());
        await engine.close();

        reopened = await FrbEngineApi.open(projectPath);
        final reopenedHash = _fnv1a32(
          await reopened.readCompositeTile(x: tileX, y: tileY),
        );
        expect(reopenedHash, drawnHash, reason: 'saved pixels survive reopen');

        final recoveryPath = '${temporary.path}/recovery.inkproj';
        await reopened.saveAs(recoveryPath);
        final corruptPath = '${temporary.path}/corrupt.inkproj';
        final corruptDirectory = Directory(corruptPath);
        await corruptDirectory.create();
        final corruptManifest = File('$corruptPath/manifest.json');
        const corruptBytes = <int>[110, 111, 116, 45, 106, 115, 111, 110];
        await corruptManifest.writeAsBytes(corruptBytes);
        await expectLater(
          FrbEngineApi.open(corruptPath),
          throwsA(isA<DocumentOpenException>()),
        );
        expect(await corruptManifest.readAsBytes(), corruptBytes);
        expect(
          _fnv1a32(await reopened.readCompositeTile(x: tileX, y: tileY)),
          drawnHash,
          reason: 'a corrupt replacement does not invalidate the open engine',
        );
        final recovery = await FrbEngineApi.open(recoveryPath);
        try {
          expect(
            _fnv1a32(await recovery.readCompositeTile(x: tileX, y: tileY)),
            drawnHash,
            reason: 'the recovery copy remains readable after corrupt Open',
          );
        } finally {
          await recovery.close();
        }

        await reopened.undo();
        final undoneHash = _fnv1a32(
          await reopened.readCompositeTile(x: tileX, y: tileY),
        );
        expect(undoneHash, emptyHash, reason: 'Undo restores the empty canvas');

        await reopened.redo();
        final redoneHash = _fnv1a32(
          await reopened.readCompositeTile(x: tileX, y: tileY),
        );
        expect(
          redoneHash,
          drawnHash,
          reason: 'Redo restores the committed stroke',
        );

        await reopened.saveAs(projectPath);
        await reopened.close();
        reopened = await FrbEngineApi.open(projectPath);
        final finalHash = _fnv1a32(
          await reopened.readCompositeTile(x: tileX, y: tileY),
        );
        expect(
          finalHash,
          drawnHash,
          reason: 'redo remains after save and reopen',
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        if (reopened != null) await reopened.close();
        await engine.close();
      }
    },
  );

  testWidgets(
    'ProjectInkApp keeps Rust recovery and active engine after corrupt Open',
    (tester) async {
      final temporary = await Directory.systemTemp.createTemp(
        'project-ink-app-recovery-',
      );
      final comicWorkspace = ComicWorkspaceController();
      final recoveryPath = '${temporary.path}/recovery.inkproj';
      final corruptPath = '${temporary.path}/corrupt.inkproj';
      final blockedParent = File('${temporary.path}/not-a-directory');
      const blockerContents = 'preserve this destination blocker';
      await blockedParent.writeAsString(blockerContents);
      final failedSavePath = '${blockedParent.path}/failed.inkproj';
      final engine = await FrbEngineApi.create(
        widthPx: 512,
        heightPx: 512,
        dpi: 144,
      );
      try {
        final addedLayerId = await engine.addLayer(kind: 'Raster');
        await tester.pumpWidget(
          ProjectInkApp(
            engineOverride: engine,
            autosavePath: recoveryPath,
            documentPicker: _FailingSavePicker(failedSavePath),
            targetPlatformOverride: TargetPlatform.macOS,
            comicWorkspaceController: comicWorkspace,
          ),
        );
        await tester.pumpAndSettle();

        final originalCanvas = tester.widget<CanvasScreen>(
          find.byType(CanvasScreen),
        );
        final autosave = originalCanvas.autosave!;
        autosave.markDirty();
        await autosave.flush();
        expect(await Directory(recoveryPath).exists(), isTrue);

        await tester.tap(find.byTooltip('Save project'));
        await tester.pumpAndSettle();
        final afterFailedSave = tester.widget<CanvasScreen>(
          find.byType(CanvasScreen),
        );
        expect(afterFailedSave.engine, same(engine));
        expect(afterFailedSave.activeDocumentPath, isNull);
        expect(afterFailedSave.autosaveState?.hasUnsavedChanges, isTrue);
        expect(await blockedParent.readAsString(), blockerContents);
        expect(await File(failedSavePath).exists(), isFalse);

        final corruptDirectory = Directory(corruptPath);
        await corruptDirectory.create();
        final corruptManifest = File('$corruptPath/manifest.json');
        const corruptBytes = <int>[
          98,
          97,
          100,
          45,
          112,
          114,
          111,
          106,
          101,
          99,
          116,
        ];
        await corruptManifest.writeAsBytes(corruptBytes);

        await expectLater(
          originalCanvas.onOpenDocument!(corruptPath),
          throwsA(isA<DocumentOpenException>()),
        );

        final currentCanvas = tester.widget<CanvasScreen>(
          find.byType(CanvasScreen),
        );
        expect(currentCanvas.engine, same(engine));
        expect(currentCanvas.autosave, same(autosave));
        expect(currentCanvas.autosaveState?.hasUnsavedChanges, isTrue);
        expect(await corruptManifest.readAsBytes(), corruptBytes);

        final recoveryEngine = await FrbEngineApi.open(recoveryPath);
        try {
          final summaries = await recoveryEngine.layerSummaries();
          expect(
            summaries.any((layer) => layer.id == addedLayerId),
            isTrue,
            reason: 'the production recovery copy retains the last layer edit',
          );
        } finally {
          await recoveryEngine.close();
        }
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await engine.close();
        if (await temporary.exists()) await temporary.delete(recursive: true);
      }
    },
  );
}

int _fnv1a32(List<int> bytes) {
  var hash = 0x811c9dc5;
  for (final byte in bytes) {
    hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
  }
  return hash;
}

class _FailingSavePicker implements DocumentPicker {
  const _FailingSavePicker(this.destination);

  final String destination;

  @override
  Future<String?> openProject() async => null;

  @override
  Future<String?> saveProject({
    String suggestedName = 'untitled.inkproj',
  }) async => destination;

  @override
  Future<String?> exportPng({String suggestedName = 'untitled.png'}) async =>
      null;
}
