import 'dart:io';

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:project_ink/bridge/engine_api.dart';
import 'package:project_ink/app/project_ink_app.dart';
import 'package:project_ink/canvas/canvas_screen.dart';
import 'package:project_ink/canvas/live_preview_controller.dart';
import 'package:project_ink/comics/comic_workspace.dart';
import 'package:project_ink/documents/document_picker.dart';
import 'package:project_ink/tools/brush_library.dart' show BrushCurvePointView;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Rust bridge persists a representative layer workflow on disk', (
    tester,
  ) async {
    final temporary = await _createAlphaTemporaryDirectory(
      'project-ink-layer-alpha-',
    );
    const preserveFixtures = bool.fromEnvironment(
      'PROJECT_INK_PRESERVE_ALPHA_FIXTURES',
    );
    addTearDown(() async {
      if (!await temporary.exists()) return;
      if (preserveFixtures) {
        debugPrint('Preserved alpha layer fixture: ${temporary.path}');
      } else {
        await temporary.delete(recursive: true);
      }
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
      debugPrint('Alpha layer project saved at: $projectPath');
      await engine.close();
      reopened = await FrbEngineApi.open(projectPath);

      final layers = await reopened.layerSummaries();
      final persistedLayer = layers.singleWhere((layer) => layer.id == layerId);
      expect(persistedLayer.name, 'Alpha Ink Layer');
      expect(persistedLayer.visible, isFalse);
      await reopened.setLayersVisibility(layerIds: [layerId], visible: true);
      await reopened.undo();
      expect(
        (await reopened.layerSummaries())
            .singleWhere((layer) => layer.id == layerId)
            .visible,
        isFalse,
        reason: 'Undo restores the saved hidden state',
      );
      await reopened.redo();
      expect(
        (await reopened.layerSummaries())
            .singleWhere((layer) => layer.id == layerId)
            .visible,
        isTrue,
        reason: 'Redo restores the visibility edit',
      );
      await reopened.saveAs(projectPath);
      await reopened.close();
      reopened = await FrbEngineApi.open(projectPath);
      expect(
        (await reopened.layerSummaries())
            .singleWhere((layer) => layer.id == layerId)
            .visible,
        isTrue,
        reason: 'the redone layer edit survives another save and reopen',
      );
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
      final temporary = await _createAlphaTemporaryDirectory(
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
          pulledString: brush.pulledString,
          stabilizerDistancePx: brush.stabilizerDistancePx,
          catchUpOnEnd: brush.catchUpOnEnd,
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

  testWidgets('failed disk-backed brush import preserves source and document', (
    tester,
  ) async {
    final temporary = await _createAlphaTemporaryDirectory(
      'project-ink-failed-brush-import-',
    );
    addTearDown(() async {
      if (await temporary.exists()) await temporary.delete(recursive: true);
    });
    final source = File('${temporary.path}/damaged.inkbrush');
    const sourceBytes = <int>[
      80,
      75,
      3,
      4,
      110,
      111,
      116,
      45,
      97,
      45,
      122,
      105,
      112,
    ];
    await source.writeAsBytes(sourceBytes);
    final engine = await FrbEngineApi.create(
      widthPx: 512,
      heightPx: 512,
      dpi: 144,
    );
    try {
      final revisionBefore = engine.revision;
      final brushIdsBefore =
          (await engine.builtinBrushes()).map((brush) => brush.id).toSet();
      await expectLater(engine.importBrush(source.path), throwsA(anything));
      expect(await source.readAsBytes(), sourceBytes);
      expect(engine.revision, revisionBefore);
      expect(
        (await engine.builtinBrushes()).map((brush) => brush.id).toSet(),
        brushIdsBefore,
        reason: 'a failed import does not install a partial brush',
      );
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await engine.close();
    }
  });

  testWidgets(
    'Rust comic workflow saves, reopens, and exports multiple pages',
    (tester) async {
      final temporary = await _createAlphaTemporaryDirectory(
        'project-ink-comic-alpha-',
      );
      addTearDown(() async {
        if (await temporary.exists()) await temporary.delete(recursive: true);
      });
      final comicPath = '${temporary.path}/alpha-comic.inkproj';
      final exportPath = '${temporary.path}/exported-pages';
      await Directory(exportPath).create();
      final bridgeBootstrap = await FrbEngineApi.create(
        widthPx: 64,
        heightPx: 64,
        dpi: 144,
      );
      await bridgeBootstrap.close();
      final comic = ComicWorkspaceController();
      final reopenedComic = ComicWorkspaceController();
      try {
        await comic.createTemplate(1);
        expect(
          comic.snapshot,
          isNotNull,
          reason: 'comic template creation failed: ${comic.error}',
        );
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
      final temporary = await _createAlphaTemporaryDirectory(
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
              livePreviewControllerFactory: (_) => _NoopLivePreviewController(),
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
      final temporary = await _createAlphaTemporaryDirectory(
        'project-ink-app-recovery-',
      );
      final comicWorkspace = ComicWorkspaceController();
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
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
            livePreviewControllerFactory: (_) => _NoopLivePreviewController(),
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

        final saveCommand = find.byTooltip('Save project');
        if (saveCommand.evaluate().isNotEmpty) {
          await tester.tap(saveCommand);
        } else {
          await tester.tap(find.byTooltip('More commands'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Save project'));
        }
        await tester.pumpAndSettle();
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
    // The fixture forces desktop workspace behavior; iPad app-level recovery
    // remains a separate physical acceptance check.
    skip: Platform.isIOS,
  );

  testWidgets('failed disk-backed recovery write keeps dirty Rust document', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final temporary = await _createAlphaTemporaryDirectory(
      'project-ink-failed-recovery-write-',
    );
    final blocker = File('${temporary.path}/not-a-directory');
    const blockerBytes = 'preserve recovery destination blocker';
    await blocker.writeAsString(blockerBytes);
    final engine = await FrbEngineApi.create(
      widthPx: 512,
      heightPx: 512,
      dpi: 144,
    );
    final comicWorkspace = ComicWorkspaceController();
    try {
      await engine.addLayer(kind: 'Raster');
      await tester.pumpWidget(
        ProjectInkApp(
          engineOverride: engine,
          autosavePath: '${blocker.path}/recovery.inkproj',
          targetPlatformOverride: TargetPlatform.macOS,
          livePreviewControllerFactory: (_) => _NoopLivePreviewController(),
          comicWorkspaceController: comicWorkspace,
        ),
      );
      await tester.pumpAndSettle();
      final canvas = tester.widget<CanvasScreen>(find.byType(CanvasScreen));
      canvas.autosave!.markDirty();
      await expectLater(canvas.autosave!.flush(), throwsA(anything));
      final currentCanvas = tester.widget<CanvasScreen>(
        find.byType(CanvasScreen),
      );

      expect(currentCanvas.engine, same(engine));
      expect(currentCanvas.autosaveState?.hasUnsavedChanges, isTrue);
      expect(await blocker.readAsString(), blockerBytes);
      expect(
        await Directory('${blocker.path}/recovery.inkproj').exists(),
        isFalse,
      );
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await engine.close();
      if (await temporary.exists()) await temporary.delete(recursive: true);
    }
  });
}

class _NoopLivePreviewController implements LivePreviewController {
  final ValueNotifier<int?> _textureId = ValueNotifier<int?>(null);
  final ValueNotifier<bool> _gpuFrameReady = ValueNotifier<bool>(false);

  @override
  ValueListenable<int?> get textureId => _textureId;

  @override
  ValueListenable<bool> get gpuFrameReady => _gpuFrameReady;

  @override
  void markInputPending({bool strokeStart = false}) {}

  @override
  void synchronizeViewport({
    required Size viewportSize,
    required double devicePixelRatio,
    required Offset pan,
    required double scale,
    required double rotation,
    required bool mirrored,
    required int documentWidth,
    required int documentHeight,
  }) {}

  @override
  void pump() {}

  @override
  Future<void> acknowledge(StrokeAcknowledgement acknowledgement) async {}

  @override
  Future<void> cancelAllStrokes() async {}

  @override
  Future<void> dispose() async {
    _textureId.dispose();
    _gpuFrameReady.dispose();
  }
}

int _fnv1a32(List<int> bytes) {
  var hash = 0x811c9dc5;
  for (final byte in bytes) {
    hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
  }
  return hash;
}

Future<Directory> _createAlphaTemporaryDirectory(String prefix) async {
  const configuredRoot = String.fromEnvironment(
    'PROJECT_INK_TEST_DOCUMENTS_PATH',
  );
  if (configuredRoot.isEmpty) return Directory.systemTemp.createTemp(prefix);
  final root = Directory(configuredRoot);
  await root.create(recursive: true);
  return root.createTemp(prefix);
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
