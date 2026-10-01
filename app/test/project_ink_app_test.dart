import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/app/project_ink_app.dart';
import 'package:project_ink/bridge/engine_api.dart';
import 'package:project_ink/canvas/canvas_screen.dart';
import 'package:project_ink/comics/comic_workspace.dart';
import 'package:project_ink/documents/autosave_coordinator.dart';
import 'package:project_ink/documents/document_picker.dart';

class _TitleFlowPicker implements DocumentPicker {
  @override
  Future<String?> openProject() async => null;

  @override
  Future<String?> saveProject({
    String suggestedName = 'untitled.inkproj',
  }) async => '/tmp/Phase385Title.inkproj';

  @override
  Future<String?> exportPng({String suggestedName = 'untitled.png'}) async =>
      null;
}

class _OpenFlowPicker implements DocumentPicker {
  @override
  Future<String?> openProject() async => '/tmp/SecondProject.inkproj';

  @override
  Future<String?> saveProject({
    String suggestedName = 'untitled.inkproj',
  }) async => null;

  @override
  Future<String?> exportPng({String suggestedName = 'untitled.png'}) async =>
      null;
}

class _RecordingAutosaveEngine extends InMemoryEngineApi {
  final savedPaths = <String>[];

  @override
  Future<void> saveAs(String path) async => savedPaths.add(path);
}

class _DelayedSaveEngine extends InMemoryEngineApi {
  final saveStarted = Completer<void>();
  final finishSave = Completer<void>();
  final events = <String>[];

  @override
  Future<void> saveAs(String path) async {
    events.add('save-started');
    saveStarted.complete();
    await finishSave.future;
    events.add('save-finished');
  }

  @override
  Future<void> close() async {
    events.add('engine-closed');
  }
}

class _TestComicWorkspaceController extends ComicWorkspaceController {
  _TestComicWorkspaceController() : super();

  @override
  Future<void> ensureExampleLoaded() async {}
}

class _EagerComicWorkspaceController extends ComicWorkspaceController {
  _EagerComicWorkspaceController() : super();

  @override
  Future<void> ensureExampleLoaded() async => notifyListeners();
}

void main() {
  testWidgets('uses an explicitly injected engine for widget tests', (
    tester,
  ) async {
    await tester.pumpWidget(ProjectInkApp(engineOverride: InMemoryEngineApi()));
    await tester.pump();

    expect(find.byType(CanvasScreen), findsOneWidget);
  });

  testWidgets('final recovery save completes before the engine closes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final engine = _DelayedSaveEngine();
    await tester.pumpWidget(
      ProjectInkApp(
        engineOverride: engine,
        autosavePath: '/tmp/project-ink-shutdown-test.inkproj',
      ),
    );
    await tester.pumpAndSettle();

    final canvas = find.bySemanticsLabel('Drawing canvas');
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    final center = tester.getCenter(canvas);
    await gesture.moveTo(center);
    await gesture.down(center);
    await gesture.moveBy(const Offset(20, 12));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.pumpWidget(const SizedBox.shrink());
    await engine.saveStarted.future;
    expect(engine.events, ['save-started']);

    engine.finishSave.complete();
    await tester.pump();
    await tester.pumpAndSettle();
    expect(engine.events, ['save-started', 'save-finished', 'engine-closed']);
  });

  testWidgets('Save As binds later autosaves to the selected project path', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final engine = _RecordingAutosaveEngine();
    await tester.pumpWidget(
      ProjectInkApp(
        engineOverride: engine,
        autosavePath: '/tmp/phase385-recovery.inkproj',
        targetPlatformOverride: TargetPlatform.macOS,
        documentPicker: _TitleFlowPicker(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyK, character: 'k');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Save project as');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save project as').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Phase385Title');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Phase385Title  •  Pen'), findsOneWidget);
    expect(engine.savedPaths, ['/tmp/Phase385Title.inkproj']);

    final canvas = find.bySemanticsLabel('Drawing canvas');
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    final center = tester.getCenter(canvas);
    await gesture.moveTo(center);
    await gesture.down(center);
    await gesture.moveBy(const Offset(20, 12));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      tester
          .widget<CanvasScreen>(find.byType(CanvasScreen))
          .autosaveState
          ?.dirty,
      isTrue,
    );

    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    final state =
        tester.widget<CanvasScreen>(find.byType(CanvasScreen)).autosaveState!;
    expect(state.dirty, isFalse);
    expect(state.hasSavedCheckpoint, isTrue);
    expect(find.text('Saved'), findsOneWidget);
    expect(engine.savedPaths.last, '/tmp/Phase385Title.inkproj');
    expect(
      engine.savedPaths,
      isNot(contains('/tmp/phase385-recovery.inkproj')),
    );
  });

  testWidgets(
    'New after Save As clears the project path and checkpoint state',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProjectInkApp(
          engineOverride: InMemoryEngineApi(),
          autosavePath: '/tmp/project-ink-test-recovery.inkproj',
          documentPicker: _TitleFlowPicker(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyK, character: 'k');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Save project as');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save project as').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Phase385Title');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.text('Phase385Title  •  Pen'), findsOneWidget);
      expect(
        tester
            .widget<CanvasScreen>(find.byType(CanvasScreen))
            .activeDocumentPath,
        '/tmp/Phase385Title.inkproj',
      );

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyN, character: 'n');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create document'));
      await tester.pumpAndSettle();

      final newCanvas = tester.widget<CanvasScreen>(find.byType(CanvasScreen));
      expect(find.text('Untitled  •  Pen'), findsOneWidget);
      expect(newCanvas.activeDocumentPath, isNull);
      expect(newCanvas.autosaveState?.hasSavedCheckpoint, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('New document replaces the Rust-session engine after creation', (
    tester,
  ) async {
    final initialEngine = InMemoryEngineApi();
    await tester.pumpWidget(ProjectInkApp(engineOverride: initialEngine));
    await tester.pumpAndSettle();

    final initialCanvas = tester.widget<CanvasScreen>(
      find.byType(CanvasScreen),
    );
    expect(initialCanvas.engine, same(initialEngine));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyN, character: 'n');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.text('New document'), findsOneWidget);

    await tester.tap(find.text('Create document'));
    await tester.pumpAndSettle();

    final newCanvas = tester.widget<CanvasScreen>(find.byType(CanvasScreen));
    expect(newCanvas.engine, isNot(same(initialEngine)));
  });

  testWidgets('opening another valid document replaces the active session', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final initialEngine = InMemoryEngineApi();
    final openedEngine = InMemoryEngineApi();
    String? requestedPath;
    await tester.pumpWidget(
      ProjectInkApp(
        engineOverride: initialEngine,
        documentPicker: _OpenFlowPicker(),
        openDocumentEngine: (path) async {
          requestedPath = path;
          return openedEngine;
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyK, character: 'k');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Open project');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open project').last);
    await tester.pumpAndSettle();

    final canvas = tester.widget<CanvasScreen>(find.byType(CanvasScreen));
    expect(requestedPath, '/tmp/SecondProject.inkproj');
    expect(canvas.engine, same(openedEngine));
    expect(canvas.activeDocumentPath, '/tmp/SecondProject.inkproj');
    expect(find.text('SecondProject  •  Pen'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('app projects autosave changes into the editor status bar', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final states = <AutosaveState>[];
    await tester.pumpWidget(
      ProjectInkApp(
        engineOverride: InMemoryEngineApi(),
        autosavePath: '/tmp/project-ink-status-test.inkproj',
        targetPlatformOverride: TargetPlatform.macOS,
        onAutosaveStateChanged: states.add,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CanvasScreen>(find.byType(CanvasScreen))
          .autosaveState
          ?.hasSavedCheckpoint,
      isFalse,
    );

    final canvas = find.bySemanticsLabel('Drawing canvas');
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    final center = tester.getCenter(canvas);
    await gesture.moveTo(center);
    await gesture.down(center);
    await gesture.moveBy(const Offset(20, 12));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 100));
    expect(states, isNotEmpty);
    expect(states.last.dirty, isTrue);
    expect(
      tester
          .widget<CanvasScreen>(find.byType(CanvasScreen))
          .autosaveState
          ?.dirty,
      isTrue,
    );

    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    final checkpointed =
        tester.widget<CanvasScreen>(find.byType(CanvasScreen)).autosaveState!;
    expect(checkpointed.dirty, isFalse);
    expect(checkpointed.saving, isFalse);
    expect(checkpointed.lastError, isNull);
    expect(checkpointed.hasSavedCheckpoint, isTrue);
    expect(find.text('Saved'), findsOneWidget);
    expect(states.last.hasSavedCheckpoint, isTrue);
  });

  testWidgets('comic workspace opens from the main canvas toolbar', (
    tester,
  ) async {
    final comic = _TestComicWorkspaceController();
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: InMemoryEngineApi(),
          comicWorkspaceController: comic,
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Comic workspace'));
    await tester.pump();

    expect(find.byType(ComicWorkspace), findsOneWidget);
  });

  testWidgets('comic load notifications are deferred out of the build phase', (
    tester,
  ) async {
    final comic = _EagerComicWorkspaceController();
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: InMemoryEngineApi(),
          comicWorkspaceController: comic,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
