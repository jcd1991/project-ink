import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:project_ink/bridge/engine_api.dart';
import 'package:project_ink/canvas/canvas_screen.dart';
import 'package:project_ink/comics/comic_workspace.dart';

const _fixtureSubdirectory = String.fromEnvironment(
  'INK_BRUSH_GALLERY_FIXTURE_DIR',
);
const _readySubdirectory = 'BrushQA/device-gallery-control';
const _expectedFixtureCount = int.fromEnvironment(
  'INK_BRUSH_GALLERY_FIXTURE_COUNT',
  defaultValue: 0,
);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('imports brushes and captures a touch-stroke gallery', (
    tester,
  ) async {
    expect(
      _fixtureSubdirectory,
      isNotEmpty,
      reason: 'run with the device gallery helper and a brush fixture',
    );
    final documents = await getApplicationDocumentsDirectory();
    final fixtureDirectory = Directory(
      path.join(documents.path, _fixtureSubdirectory),
    );
    // The device runner reuses stable paths so incremental Flutter builds can
    // reuse the integration app. Clear stale fixtures before announcing
    // readiness, then wait for an explicit transfer-complete marker.
    if (await fixtureDirectory.exists()) {
      await fixtureDirectory.delete(recursive: true);
    }
    await fixtureDirectory.create(recursive: true);
    final readyDirectory = Directory(
      path.join(documents.path, _readySubdirectory),
    );
    await readyDirectory.create(recursive: true);
    final readyFile = File(path.join(readyDirectory.path, 'READY'));
    if (await readyFile.exists()) await readyFile.delete();
    await File(readyFile.path).writeAsString('ready');
    final completeFile = File(path.join(readyDirectory.path, 'COMPLETE'));
    if (await completeFile.exists()) await completeFile.delete();
    final fixtures = await _waitForFixtures(fixtureDirectory, completeFile);

    final engine = await FrbEngineApi.create(
      widthPx: 1024,
      heightPx: 1024,
      dpi: 144,
    );
    final imports = <Map<String, Object?>>[];
    try {
      for (final fixture in fixtures) {
        late final BrushImportStageView stage;
        try {
          stage = await engine.stageBrushImport(fixture.path);
        } catch (error, stackTrace) {
          throw StateError(
            'Could not stage ${path.basename(fixture.path)}: $error\n$stackTrace',
          );
        }
        late final BrushImportReportView report;
        try {
          report = await engine.convertStagedBrushImport(stage.operationId);
        } catch (error, stackTrace) {
          throw StateError(
            'Could not convert ${path.basename(fixture.path)}: $error\n$stackTrace',
          );
        }
        late final int brushId;
        try {
          brushId = await engine.commitStagedBrushImport(stage.operationId);
        } catch (error, stackTrace) {
          throw StateError(
            'Could not commit ${path.basename(fixture.path)}: $error\n$stackTrace',
          );
        }
        imports.add(<String, Object?>{
          'file': path.basename(fixture.path),
          'format': report.sourceFormat,
          'fidelity': report.fidelity,
          'resourceCount': report.resourceCount,
          'brushId': brushId,
          'warnings': report.warnings,
        });
      }

      final importedIds =
          imports.map((entry) => entry['brushId']! as int).toSet();
      final importById = <int, Map<String, Object?>>{
        for (final entry in imports) entry['brushId']! as int: entry,
      };
      final importedBrushes = (await engine.builtinBrushes())
          .where((brush) => importedIds.contains(brush.id))
          .toList(growable: false);
      expect(importedBrushes.length, imports.length);

      final comicWorkspace = ComicWorkspaceController();
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasScreen(
            engine: engine,
            targetPlatform: TargetPlatform.iOS,
            comicWorkspaceController: comicWorkspace,
          ),
        ),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      final canvasFinder = find.bySemanticsLabel('Drawing canvas');
      expect(canvasFinder, findsOneWidget);
      final standardBrushButton = find.byTooltip('Open brush library (B)');
      final compactBrushButton = find.byTooltip('Brush library');
      final brushButton =
          standardBrushButton.evaluate().isNotEmpty
              ? standardBrushButton
              : compactBrushButton;
      expect(brushButton, findsOneWidget);
      final canvas = tester.getRect(canvasFinder);
      final shortSide = math.min(canvas.width, canvas.height);
      final startX = canvas.center.dx - shortSide * 0.22;
      final endX = canvas.center.dx + shortSide * 0.22;
      final verticalStep = math.min(34.0, shortSide * 0.055);
      final firstY =
          canvas.center.dy - verticalStep * (importedBrushes.length - 1) / 2;
      final strokeResults = <Map<String, Object?>>[];
      const tileCoordinates = <(int, int)>[(1, 1), (2, 1), (1, 2), (2, 2)];

      for (var index = 0; index < importedBrushes.length; index++) {
        final brush = importedBrushes[index];
        final source = importById[brush.id]!;
        await tester.tap(brushButton);
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        await tester.tap(find.text('My brushes'));
        await tester.pumpAndSettle(const Duration(milliseconds: 100));

        final row = find.byKey(ValueKey('brush-row-${brush.id}'));
        for (var frame = 0; frame < 20 && row.evaluate().isEmpty; frame++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        if (row.evaluate().isEmpty) {
          debugPrint(
            'PROJECT_INK_BRUSH_GALLERY_ROW_MISSING id=${brush.id} name=${brush.name}',
          );
          debugDumpApp();
          await binding.takeScreenshot('brush-device-gallery-ui-failure');
        }
        expect(row, findsOneWidget);
        await tester.ensureVisible(row);
        await tester.tap(row);
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        await tester.tap(find.byTooltip('Close Brush library'));
        await tester.pumpAndSettle(const Duration(milliseconds: 100));

        final y = firstY + verticalStep * index;
        final beforeRevision = engine.revision;
        final initialTileHashes = <String, int>{};
        for (final (x, y) in tileCoordinates) {
          initialTileHashes['$x:$y'] = _fnv1a32(
            await engine.readCompositeTile(x: x, y: y),
          );
        }
        final pointer = 100 + index;
        final start = Offset(startX, y);
        final gesture = await tester.createGesture(
          pointer: pointer,
          kind: PointerDeviceKind.touch,
        );
        await gesture.moveTo(start);
        await gesture.downWithCustomEvent(
          start,
          PointerDownEvent(
            pointer: pointer,
            kind: PointerDeviceKind.touch,
            position: start,
            buttons: kPrimaryButton,
            pressure: 0.2,
            pressureMin: 0,
            pressureMax: 1,
          ),
        );
        const samples = 80;
        var previous = start;
        for (var sample = 1; sample <= samples; sample++) {
          final progress = sample / samples;
          final next = Offset(
            startX + (endX - startX) * progress,
            y + math.sin(progress * math.pi * 2) * 2,
          );
          await gesture.updateWithCustomEvent(
            PointerMoveEvent(
              pointer: pointer,
              kind: PointerDeviceKind.touch,
              position: next,
              delta: next - previous,
              buttons: kPrimaryButton,
              pressure: 0.2 + progress * 0.8,
              pressureMin: 0,
              pressureMax: 1,
            ),
          );
          previous = next;
          if (sample % 8 == 0) {
            await tester.pump(const Duration(milliseconds: 16));
          }
        }
        await gesture.up();
        for (var frame = 0; frame < 20; frame++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(
          engine.revision,
          greaterThan(beforeRevision),
          reason: 'touch stroke for ${brush.name} must commit to Rust',
        );
        final changedTiles = <String>[];
        for (final (x, y) in tileCoordinates) {
          final key = '$x:$y';
          final finalHash = _fnv1a32(
            await engine.readCompositeTile(x: x, y: y),
          );
          if (finalHash != initialTileHashes[key]) changedTiles.add(key);
        }
        expect(
          changedTiles,
          isNotEmpty,
          reason: 'touch stroke for ${brush.name} must change Rust pixels',
        );
        strokeResults.add(<String, Object?>{
          'id': brush.id,
          'name': brush.name,
          'source': path.basename(source['file']! as String),
          'fidelity': source['fidelity'],
          'resources': source['resourceCount'],
          'changedTiles': changedTiles,
          'committedRevision': engine.revision,
        });
      }

      debugPrint(
        'PROJECT_INK_BRUSH_DEVICE_GALLERY ${jsonEncode(<String, Object?>{'fixtureDirectory': _fixtureSubdirectory, 'imports': imports, 'strokes': strokeResults})}',
      );
      expect(tester.takeException(), isNull);
      await binding.takeScreenshot('brush-device-gallery');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await engine.close();
      if (await fixtureDirectory.exists()) {
        await fixtureDirectory.delete(recursive: true);
      }
      if (await readyDirectory.exists()) {
        await readyDirectory.delete(recursive: true);
      }
    }
  });
}

int _fnv1a32(List<int> bytes) {
  var hash = 0x811c9dc5;
  for (final byte in bytes) {
    hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
  }
  return hash;
}

Future<List<File>> _waitForFixtures(
  Directory directory,
  File completeMarker,
) async {
  if (_expectedFixtureCount <= 0) {
    throw StateError('INK_BRUSH_GALLERY_FIXTURE_COUNT must be positive');
  }
  debugPrint(
    'PROJECT_INK_BRUSH_GALLERY_WAIT expected=$_expectedFixtureCount directory=${directory.path}',
  );
  for (var attempt = 0; attempt < 240; attempt++) {
    final fixtures =
        await directory.exists()
            ? await directory
                .list()
                .where((entity) => entity is File)
                .cast<File>()
                .where((file) {
                  final extension = path.extension(file.path).toLowerCase();
                  return extension == '.brush' || extension == '.sut';
                })
                .toList()
            : <File>[];
    if (fixtures.length >= _expectedFixtureCount &&
        await completeMarker.exists()) {
      fixtures.sort((left, right) => left.path.compareTo(right.path));
      debugPrint(
        'PROJECT_INK_BRUSH_GALLERY_FIXTURES_READY files=${fixtures.map((file) => path.basename(file.path)).join(',')}',
      );
      return fixtures;
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  throw StateError(
    'Timed out waiting for $_expectedFixtureCount brush fixtures in ${directory.path}',
  );
}
