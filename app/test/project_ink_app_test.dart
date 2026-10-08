import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/app/project_ink_app.dart';
import 'package:project_ink/bridge/engine_api.dart';
import 'package:project_ink/canvas/canvas_screen.dart';
import 'package:project_ink/comics/comic_workspace.dart';
import 'package:project_ink/documents/autosave_coordinator.dart';
import 'package:project_ink/documents/document_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

class _CloseTrackingEngine extends InMemoryEngineApi {
  bool closed = false;

  @override
  Future<void> close() async {
    closed = true;
  }
}

class _TestComicWorkspaceController extends ComicWorkspaceController {
  _TestComicWorkspaceController() : super();

  @override
  Future<void> ensureProjectLoaded() async {}
}

class _EagerComicWorkspaceController extends ComicWorkspaceController {
  _EagerComicWorkspaceController() : super();

  @override
  Future<void> ensureProjectLoaded() async => notifyListeners();
}

void main() {
  testWidgets('uses an explicitly injected engine for widget tests', (
    tester,
  ) async {
    await tester.pumpWidget(ProjectInkApp(engineOverride: InMemoryEngineApi()));
    await tester.pump();

    expect(find.byType(CanvasScreen), findsOneWidget);
  });

  testWidgets('failed startup recovery preserves the checkpoint and stops', (
    tester,
  ) async {
    final temporary =
        (await tester.runAsync(
          () => Directory.systemTemp.createTemp('project-ink-startup-'),
        ))!;
    addTearDown(() async {
      await tester.runAsync(() => temporary.delete(recursive: true));
    });
    final recovery = Directory('${temporary.path}/last-session.inkproj');
    await tester.runAsync(recovery.create);
    final sentinel = File('${recovery.path}/sentinel.checkpoint');
    const originalBytes = <int>[3, 17, 29, 41];
    await tester.runAsync(() => sentinel.writeAsBytes(originalBytes));
    var attemptedPath = '';

    await tester.pumpWidget(
      ProjectInkApp(
        autosavePath: recovery.path,
        recoveryProjectExists: (_) async => true,
        openRecoveryEngine: (path) async {
          attemptedPath = path;
          throw const DocumentOpenException('recovery could not be opened');
        },
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(attemptedPath, recovery.path);
    expect(find.byType(CanvasScreen), findsNothing);
    expect(
      find.textContaining('Any existing recovery project was left untouched.'),
      findsOneWidget,
    );
    expect(await tester.runAsync(sentinel.readAsBytes), originalBytes);
    expect(tester.takeException(), isNull);
  });

  testWidgets('successful startup recovery opens the recovered session', (
    tester,
  ) async {
    final temporary =
        (await tester.runAsync(
          () => Directory.systemTemp.createTemp('project-ink-startup-ok-'),
        ))!;
    addTearDown(() async {
      await tester.runAsync(() => temporary.delete(recursive: true));
    });
    final recovery = Directory('${temporary.path}/last-session.inkproj');
    await tester.runAsync(recovery.create);
    final engine = InMemoryEngineApi();
    var attemptedPath = '';

    await tester.pumpWidget(
      ProjectInkApp(
        autosavePath: recovery.path,
        recoveryProjectExists: (_) async => true,
        openRecoveryEngine: (path) async {
          attemptedPath = path;
          return engine;
        },
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final canvas = tester.widget<CanvasScreen>(find.byType(CanvasScreen));
    expect(attemptedPath, recovery.path);
    expect(canvas.engine, same(engine));
    expect(canvas.autosaveState?.hasUnsavedChanges, isTrue);
  });

  testWidgets('falls back to English for an unsupported system locale', (
    tester,
  ) async {
    tester.binding.platformDispatcher.localesTestValue = const [
      Locale('es', 'MX'),
    ];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);

    await tester.pumpWidget(ProjectInkApp(engineOverride: InMemoryEngineApi()));
    await tester.pump();

    expect(
      Localizations.localeOf(tester.element(find.byType(CanvasScreen))),
      const Locale('en'),
    );
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

    tester
        .widget<CanvasScreen>(find.byType(CanvasScreen))
        .autosave!
        .markDirty();
    expect(
      tester.widget<CanvasScreen>(find.byType(CanvasScreen)).autosave?.isDirty,
      isTrue,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await engine.saveStarted.future;
    expect(engine.events, ['save-started']);

    engine.finishSave.complete();
    await tester.pump();
    await tester.pumpAndSettle();
    expect(engine.events, ['save-started', 'save-finished', 'engine-closed']);
  });

  testWidgets('Save As keeps autosave in the separate recovery path', (
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

    expect(find.textContaining('Phase385Title'), findsOneWidget);
    expect(engine.savedPaths, ['/tmp/Phase385Title.inkproj']);

    tester
        .widget<CanvasScreen>(find.byType(CanvasScreen))
        .autosave!
        .markDirty();
    await tester.pump();
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
    expect(state.hasUnsavedChanges, isTrue);
    expect(state.hasSavedCheckpoint, isTrue);
    expect(find.text('Unsaved changes'), findsOneWidget);
    expect(engine.savedPaths.last, '/tmp/phase385-recovery.inkproj');
    expect(engine.savedPaths, contains('/tmp/Phase385Title.inkproj'));
  });

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
    expect(find.textContaining('SecondProject'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closes an opened candidate if the app unmounts before rebind', (
    tester,
  ) async {
    final initialEngine = InMemoryEngineApi();
    final candidate = _CloseTrackingEngine();
    final candidateReady = Completer<EngineApi>();
    await tester.pumpWidget(
      ProjectInkApp(
        engineOverride: initialEngine,
        targetPlatformOverride: TargetPlatform.fuchsia,
        openDocumentEngine: (_) => candidateReady.future,
      ),
    );
    await tester.pumpAndSettle();

    final canvas = tester.widget<CanvasScreen>(find.byType(CanvasScreen));
    final opening = canvas.onOpenDocument!('/tmp/dispose-during-open.inkproj');
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    candidateReady.complete(candidate);
    await opening;

    expect(candidate.closed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed project open preserves the active engine and recovery', (
    tester,
  ) async {
    final temporary =
        (await tester.runAsync(
          () => Directory.systemTemp.createTemp('project-ink-failed-open-'),
        ))!;
    addTearDown(() async {
      await tester.runAsync(() => temporary.delete(recursive: true));
    });
    final recoveryPath = '${temporary.path}/recovery.inkproj';
    final recovery = Directory(recoveryPath);
    await tester.runAsync(recovery.create);
    final checkpoint = File('${recovery.path}/sentinel.checkpoint');
    const checkpointBytes = <int>[7, 19, 31, 43, 59];
    await tester.runAsync(() => checkpoint.writeAsBytes(checkpointBytes));

    final initialEngine = InMemoryEngineApi();
    await tester.pumpWidget(
      ProjectInkApp(
        engineOverride: initialEngine,
        targetPlatformOverride: TargetPlatform.fuchsia,
        autosavePath: recoveryPath,
        documentPicker: _OpenFlowPicker(),
        openDocumentEngine: (_) async {
          throw const FormatException('corrupt project fixture');
        },
      ),
    );
    await tester.pump();
    await tester.pump();

    final canvas = tester.widget<CanvasScreen>(find.byType(CanvasScreen));
    await expectLater(
      canvas.onOpenDocument!('/tmp/corrupt.inkproj'),
      throwsA(isA<FormatException>()),
    );
    expect(canvas.engine, same(initialEngine));
    expect(await tester.runAsync(checkpoint.readAsBytes), checkpointBytes);
    expect(await tester.runAsync(recovery.exists), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('discard then corrupt Open keeps the current engine and recovery', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final temporary =
        (await tester.runAsync(
          () => Directory.systemTemp.createTemp(
            'project-ink-discard-corrupt-open-',
          ),
        ))!;
    addTearDown(() async {
      await tester.runAsync(() => temporary.delete(recursive: true));
    });
    final recoveryPath = '${temporary.path}/recovery.inkproj';
    final recovery = Directory(recoveryPath);
    await tester.runAsync(recovery.create);
    final checkpoint = File('${recovery.path}/sentinel.checkpoint');
    const checkpointBytes = <int>[13, 29, 31, 47, 61];
    await tester.runAsync(() => checkpoint.writeAsBytes(checkpointBytes));

    final currentEngine = InMemoryEngineApi();
    await tester.pumpWidget(
      ProjectInkApp(
        engineOverride: currentEngine,
        targetPlatformOverride: TargetPlatform.fuchsia,
        autosavePath: recoveryPath,
        documentPicker: _OpenFlowPicker(),
        openDocumentEngine: (_) async {
          throw const DocumentOpenException(
            'Could not open the selected project. The current project remains open.',
          );
        },
      ),
    );
    await tester.pumpAndSettle();

    final originalCanvas = tester.widget<CanvasScreen>(
      find.byType(CanvasScreen),
    );
    final autosave = originalCanvas.autosave!;
    autosave.markDirty();
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyK, character: 'k');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Open project');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open project').last);
    await tester.pumpAndSettle();

    expect(find.text('Unsaved changes'), findsOneWidget);
    await tester.tap(find.text('Discard').last);
    await tester.pumpAndSettle();

    final currentCanvas = tester.widget<CanvasScreen>(
      find.byType(CanvasScreen),
    );
    expect(currentCanvas.engine, same(currentEngine));
    expect(currentCanvas.autosave, same(autosave));
    expect(currentCanvas.autosaveState?.hasUnsavedChanges, isTrue);
    expect(
      find.text(
        'Could not open the selected project. The current project remains open.',
      ),
      findsOneWidget,
    );
    expect(await tester.runAsync(() => recovery.exists()), isTrue);
    expect(await tester.runAsync(checkpoint.readAsBytes), checkpointBytes);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed recovery cleanup preserves current engine and recovery', (
    tester,
  ) async {
    final temporary =
        (await tester.runAsync(
          () => Directory.systemTemp.createTemp(
            'project-ink-open-cleanup-failure-',
          ),
        ))!;
    addTearDown(() async {
      await tester.runAsync(() => temporary.delete(recursive: true));
    });
    final recoveryPath = '${temporary.path}/recovery.inkproj';
    final recovery = Directory(recoveryPath);
    await tester.runAsync(recovery.create);
    final sentinel = File('${recovery.path}/sentinel.checkpoint');
    const sentinelBytes = <int>[11, 23, 37, 41, 53];
    await tester.runAsync(() => sentinel.writeAsBytes(sentinelBytes));

    final activeEngine = _RecordingAutosaveEngine();
    final candidateEngine = _CloseTrackingEngine();
    await tester.pumpWidget(
      ProjectInkApp(
        engineOverride: activeEngine,
        autosavePath: recoveryPath,
        targetPlatformOverride: TargetPlatform.fuchsia,
        openDocumentEngine: (_) async => candidateEngine,
        deleteRecoveryCheckpoint: (_) async {
          throw const FileSystemException('recovery cleanup unavailable');
        },
      ),
    );
    await tester.pumpAndSettle();

    final originalCanvas = tester.widget<CanvasScreen>(
      find.byType(CanvasScreen),
    );
    final autosave = originalCanvas.autosave!;
    autosave.markDirty();
    await tester.pump();

    await expectLater(
      originalCanvas.onOpenDocument!('/tmp/replacement.inkproj'),
      throwsA(isA<FileSystemException>()),
    );

    final currentCanvas = tester.widget<CanvasScreen>(
      find.byType(CanvasScreen),
    );
    expect(currentCanvas.engine, same(activeEngine));
    expect(currentCanvas.autosave, same(autosave));
    expect(currentCanvas.autosaveState?.hasUnsavedChanges, isTrue);
    expect(candidateEngine.closed, isTrue);
    expect(await tester.runAsync(() => recovery.exists()), isTrue);
    expect(await tester.runAsync(sentinel.readAsBytes), sentinelBytes);
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

    tester
        .widget<CanvasScreen>(find.byType(CanvasScreen))
        .autosave!
        .markDirty();
    await tester.pump();
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
    expect(checkpointed.hasUnsavedChanges, isTrue);
    expect(find.text('Unsaved changes'), findsOneWidget);
    expect(states.last.hasSavedCheckpoint, isTrue);
  });

  testWidgets('failed recovery deletion cancels close and restores autosave', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const closeChannel = MethodChannel('org.projectink.studio/window_close_v1');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final replies = <String>[];
    messenger.setMockMethodCallHandler(closeChannel, (call) async {
      replies.add(call.method);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(closeChannel, null));

    final engine = _RecordingAutosaveEngine();
    await tester.pumpWidget(
      ProjectInkApp(
        engineOverride: engine,
        autosavePath: '/tmp/project-ink-delete-failure.inkproj',
        targetPlatformOverride: TargetPlatform.macOS,
        deleteRecoveryCheckpoint: (_) async {
          throw const FileSystemException('recovery is busy');
        },
      ),
    );
    await tester.pumpAndSettle();
    final originalAutosave =
        tester.widget<CanvasScreen>(find.byType(CanvasScreen)).autosave!;
    originalAutosave.markDirty();
    await tester.pump();

    final closeRequest = messenger.handlePlatformMessage(
      closeChannel.name,
      closeChannel.codec.encodeMethodCall(const MethodCall('requestClose')),
      null,
    );
    await tester.pump();
    expect(find.text('Unsaved changes'), findsNWidgets(2));
    await tester.tap(find.text('Discard').last);
    await tester.pumpAndSettle();
    await closeRequest;

    expect(replies, <String>['cancelClose']);
    final restoredCanvas = tester.widget<CanvasScreen>(
      find.byType(CanvasScreen),
    );
    final restoredAutosave = restoredCanvas.autosave!;
    expect(restoredAutosave, isNot(same(originalAutosave)));
    expect(restoredAutosave.hasUnsavedChanges, isTrue);
    expect(restoredAutosave.isDirty, isTrue);
    await restoredAutosave.flush();
    expect(engine.savedPaths, <String>[
      '/tmp/project-ink-delete-failure.inkproj',
    ]);
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
    await tester.tap(find.byTooltip('More actions and workspace settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Comics workspace').last);
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
