import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/bridge/engine_api.dart';
import 'package:project_ink/canvas/canvas_screen.dart';
import 'package:project_ink/canvas/live_preview_controller.dart';
import 'package:project_ink/comics/comic_workspace.dart';
import 'package:project_ink/documents/autosave_coordinator.dart';
import 'package:project_ink/documents/document_picker.dart';
import 'package:project_ink/tools/brush_library_panel.dart';

class _Picker implements DocumentPicker {
  String? suggestedName;
  int saveRequests = 0;

  @override
  Future<String?> openProject() async => '/tmp/open.inkproj';

  @override
  Future<String?> saveProject({
    String suggestedName = 'untitled.inkproj',
  }) async {
    saveRequests++;
    this.suggestedName = suggestedName;
    return '/tmp/save.inkproj';
  }

  @override
  Future<String?> exportPng({String suggestedName = 'untitled.png'}) async =>
      '/tmp/export.png';
}

class _CancelDocumentPicker extends _Picker {
  @override
  Future<String?> openProject() async => null;

  @override
  Future<String?> saveProject({
    String suggestedName = 'untitled.inkproj',
  }) async {
    saveRequests++;
    return null;
  }
}

class _PsdPicker extends _Picker implements PsdImportPicker {
  @override
  Future<String?> openPsd() async => '/tmp/replacement.psd';
}

class _StudioPicker extends _Picker {
  _StudioPicker(this.path);

  final String path;

  @override
  Future<String?> openProject() async => path;
}

class _RecordingComicController extends ComicWorkspaceController {
  String? openedPath;

  @override
  Future<bool> openProjectFromPath(String path) async {
    openedPath = path;
    return true;
  }
}

class _FailingComicController extends _RecordingComicController {
  @override
  Future<bool> openProjectFromPath(String path) async {
    openedPath = path;
    return false;
  }
}

class _BrushPicker implements DocumentPicker, BrushPicker, BrushTipImagePicker {
  @override
  Future<String?> openProject() async => null;

  @override
  Future<String?> saveProject({
    String suggestedName = 'untitled.inkproj',
  }) async => null;

  @override
  Future<String?> exportPng({String suggestedName = 'untitled.png'}) async =>
      null;

  @override
  Future<String?> openBrush() async => '/tmp/converted.kpp';

  @override
  Future<String?> openBrushTipImage() async => '/tmp/tip.png';

  @override
  Future<String?> saveBrush({String suggestedName = 'brush.inkbrush'}) async =>
      '/tmp/$suggestedName';
}

class _RecordingEngine extends InMemoryEngineApi {
  String? savedPath;
  String? exportedPath;
  int saveAttempts = 0;
  bool failSave = false;
  Future<void> Function()? beforeSaveCompletes;

  @override
  Future<void> saveAs(String path) async {
    saveAttempts++;
    if (failSave) throw StateError('disk full');
    await beforeSaveCompletes?.call();
    savedPath = path;
  }

  @override
  Future<void> exportPng(String path) async => exportedPath = path;
}

class _DeferredLivePreview implements LivePreviewController {
  final ValueNotifier<int?> _textureId = ValueNotifier<int?>(null);
  final ValueNotifier<bool> _gpuFrameReady = ValueNotifier<bool>(false);
  Completer<void>? disposalGate;
  int viewportSyncCount = 0;
  bool disposed = false;

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
  }) {
    viewportSyncCount++;
  }

  @override
  void pump() {}

  @override
  Future<void> acknowledge(StrokeAcknowledgement acknowledgement) async {}

  @override
  Future<void> cancelAllStrokes() async {}

  @override
  Future<void> dispose() {
    disposed = true;
    return disposalGate?.future ?? Future<void>.value();
  }
}

class _FailingSaveEngine extends _RecordingEngine {
  @override
  Future<void> saveAs(String path) async {
    throw StateError('disk full');
  }
}

class _DelayedSavePicker extends _Picker {
  final Completer<String?> delayed = Completer<String?>();

  @override
  Future<String?> saveProject({
    String suggestedName = 'untitled.inkproj',
  }) async {
    saveRequests++;
    if (saveRequests == 1) return delayed.future;
    return '/tmp/retry.inkproj';
  }
}

class _ImportEngine extends InMemoryEngineApi {
  String? inspectedPath;
  String? convertedPath;
  String? importedPath;
  bool customBrushInstalled = false;
  int? duplicatedBrushId;
  String? renamedBrush;

  static final Uint8List sourceHash = Uint8List.fromList(
    List<int>.filled(32, 7),
  );

  @override
  Future<BrushImportInspectionView> inspectBrushImport(String path) async {
    inspectedPath = path;
    return BrushImportInspectionView(
      sourceFormat: 'KritaKpp',
      sourceSha256: _ImportEngine.sourceHash,
      bytes: 12,
      fidelity: 'Approximate',
      importerVersion: 'test',
    );
  }

  @override
  Future<BrushImportReportView> convertBrushImport(String path) async {
    convertedPath = path;
    return BrushImportReportView(
      sourceFormat: 'KritaKpp',
      sourceSha256: _ImportEngine.sourceHash,
      importerVersion: 'test',
      fidelity: 'Approximate',
      mappings: <String>['diameter -> tip.diameter_px (Normalized)'],
      omitted: <String>[],
      warnings: <String>[],
      resourceCount: 0,
      previewWidth: 160,
      previewHeight: 64,
    );
  }

  @override
  Future<int> importBrush(String path) async {
    importedPath = path;
    customBrushInstalled = true;
    return 13;
  }

  @override
  Future<List<BrushSummaryView>> builtinBrushes() async {
    final brushes = await super.builtinBrushes();
    if (customBrushInstalled) {
      return <BrushSummaryView>[
        ...brushes,
        const BrushSummaryView(
          id: 13,
          name: 'Imported test brush',
          tags: ['ink'],
        ),
      ];
    }
    return brushes;
  }

  @override
  Future<int> importBrushVerified(String path, Uint8List sourceSha256) async {
    expect(sourceSha256, orderedEquals(sourceHash));
    return importBrush(path);
  }

  @override
  Future<int> duplicateBrush(int brushId) async {
    duplicatedBrushId = brushId;
    return 1013;
  }

  @override
  Future<void> renameBrush({required int brushId, required String name}) async {
    expect(brushId, 1013);
    renamedBrush = name;
  }
}

class _BundleImportEngine extends _ImportEngine {
  String? bundleImportedPath;

  @override
  Future<BrushImportInspectionView> inspectBrushImport(String path) async {
    inspectedPath = path;
    return BrushImportInspectionView(
      sourceFormat: 'KritaBundle',
      sourceSha256: _ImportEngine.sourceHash,
      bytes: 128,
      fidelity: 'Approximate',
      importerVersion: 'test',
    );
  }

  @override
  Future<BrushImportReportView> convertBrushImport(String path) async {
    convertedPath = path;
    return BrushImportReportView(
      sourceFormat: 'KritaBundle',
      sourceSha256: _ImportEngine.sourceHash,
      importerVersion: 'test',
      fidelity: 'Approximate',
      mappings: <String>[],
      omitted: <String>[],
      warnings: <String>['Unrelated bundle resources remain inert.'],
      resourceCount: 0,
      previewWidth: 160,
      previewHeight: 64,
      brushCount: 2,
    );
  }

  @override
  Future<List<int>> importKritaBundleVerified(
    String path,
    Uint8List sourceSha256,
  ) async {
    expect(sourceSha256, orderedEquals(_ImportEngine.sourceHash));
    bundleImportedPath = path;
    return <int>[13, 14];
  }
}

class _GuidedImageImportEngine extends _ImportEngine {
  bool includeExtractedAssets = false;
  @override
  Future<BrushImportInspectionView> inspectBrushImport(String path) async {
    inspectedPath = path;
    return BrushImportInspectionView(
      sourceFormat: path.endsWith('.png') ? 'Image' : 'ProcreateBrush',
      sourceSha256: _ImportEngine.sourceHash,
      bytes: 128,
      fidelity: path.endsWith('.png') ? 'Approximate' : 'GuidedRecreation',
      importerVersion: 'test',
    );
  }

  @override
  Future<BrushImportReportView> convertBrushImport(String path) async {
    convertedPath = path;
    return BrushImportReportView(
      sourceFormat: path.endsWith('.png') ? 'Image' : 'ProcreateBrush',
      sourceSha256: _ImportEngine.sourceHash,
      importerVersion: 'test',
      fidelity: path.endsWith('.png') ? 'Approximate' : 'GuidedRecreation',
      mappings: <String>[],
      omitted: path.endsWith('.png') ? <String>[] : <String>['source settings'],
      warnings: <String>[],
      resourceCount: path.endsWith('.png') || includeExtractedAssets ? 1 : 0,
      previewWidth: 160,
      previewHeight: 64,
    );
  }
}

class _WritebackPicker implements DocumentPicker, DocumentWriteback {
  String? committedPath;

  @override
  Future<String?> openProject() async => null;

  @override
  Future<String?> saveProject({
    String suggestedName = 'untitled.inkproj',
  }) async => '/tmp/staged.inkproj';

  @override
  Future<String?> exportPng({String suggestedName = 'untitled.png'}) async =>
      null;

  @override
  Future<void> commitProject(String localPath) async {
    committedPath = localPath;
  }
}

class _FailingWritebackPicker extends _WritebackPicker {
  @override
  Future<void> commitProject(String localPath) async {
    throw StateError('provider write-back failed');
  }
}

class _PngWritebackPicker implements DocumentPicker, DocumentPngWriteback {
  String? committedPath;

  @override
  Future<String?> openProject() async => null;

  @override
  Future<String?> saveProject({
    String suggestedName = 'untitled.inkproj',
  }) async => null;

  @override
  Future<String?> exportPng({String suggestedName = 'untitled.png'}) async =>
      '/tmp/staged.png';

  @override
  Future<void> commitPng(String localPath) async {
    committedPath = localPath;
  }
}

void main() {
  testWidgets('native window close cancels or discards dirty recovery', (
    tester,
  ) async {
    const closeChannel = MethodChannel('org.projectink.studio/window_close_v1');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final nativeReplies = <String>[];
    messenger.setMockMethodCallHandler(closeChannel, (call) async {
      nativeReplies.add(call.method);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(closeChannel, null));

    var recoveryDiscards = 0;
    final engine = _RecordingEngine();
    final picker = _Picker();
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: engine,
          documentPicker: picker,
          activeDocumentPath: '/tmp/current.inkproj',
          targetPlatform: TargetPlatform.macOS,
          autosaveState: const AutosaveState(
            dirty: false,
            hasUnsavedChanges: true,
            saving: false,
            lastError: null,
            hasSavedCheckpoint: true,
          ),
          onDiscardRecovery: () async => recoveryDiscards++,
        ),
      ),
    );
    await tester.pump();

    Future<ByteData?> requestNativeClose() => messenger.handlePlatformMessage(
      closeChannel.name,
      closeChannel.codec.encodeMethodCall(const MethodCall('requestClose')),
      null,
    );

    final cancelledClose = requestNativeClose();
    await tester.pump();
    expect(find.text('Unsaved changes'), findsOneWidget);
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    await cancelledClose;
    expect(nativeReplies, <String>['cancelClose']);
    expect(recoveryDiscards, 0);

    final discardedClose = requestNativeClose();
    await tester.pump();
    expect(find.text('Unsaved changes'), findsOneWidget);
    await tester.tap(find.text('Discard').last);
    await tester.pumpAndSettle();
    await discardedClose;
    expect(nativeReplies, <String>['cancelClose', 'allowClose']);
    expect(recoveryDiscards, 1);

    Future<ByteData?> requestNativeQuit() => messenger.handlePlatformMessage(
      closeChannel.name,
      closeChannel.codec.encodeMethodCall(const MethodCall('requestQuit')),
      null,
    );

    final cancelledQuit = requestNativeQuit();
    await tester.pump();
    expect(find.text('Unsaved changes'), findsOneWidget);
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    await cancelledQuit;
    expect(nativeReplies, <String>[
      'cancelClose',
      'allowClose',
      'cancelTerminate',
    ]);
    expect(recoveryDiscards, 1);

    final discardedQuit = requestNativeQuit();
    await tester.pump();
    expect(find.text('Unsaved changes'), findsOneWidget);
    await tester.tap(find.text('Discard').last);
    await tester.pumpAndSettle();
    await discardedQuit;
    expect(nativeReplies, <String>[
      'cancelClose',
      'allowClose',
      'cancelTerminate',
      'allowTerminate',
    ]);
    expect(recoveryDiscards, 2);

    final savedQuit = requestNativeQuit();
    await tester.pump();
    expect(find.text('Unsaved changes'), findsOneWidget);
    await tester.tap(find.text('Save').last);
    await tester.pumpAndSettle();
    await savedQuit;
    expect(engine.savedPath, '/tmp/current.inkproj');
    expect(nativeReplies.last, 'allowTerminate');
    expect(recoveryDiscards, 2);

    engine.failSave = true;
    final failedSaveQuit = requestNativeQuit();
    await tester.pump();
    await tester.tap(find.text('Save').last);
    await tester.pumpAndSettle();
    await failedSaveQuit;
    expect(nativeReplies.last, 'cancelTerminate');
    expect(engine.saveAttempts, 2);
    expect(recoveryDiscards, 2);
  });

  testWidgets('native close stays open when edits arrive during Save', (
    tester,
  ) async {
    const closeChannel = MethodChannel('org.projectink.studio/window_close_v1');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final nativeReplies = <String>[];
    messenger.setMockMethodCallHandler(closeChannel, (call) async {
      nativeReplies.add(call.method);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(closeChannel, null));

    final engine = _RecordingEngine();
    engine.beforeSaveCompletes = engine.clearSelection;
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: engine,
          documentPicker: _Picker(),
          activeDocumentPath: '/tmp/current.inkproj',
          targetPlatform: TargetPlatform.macOS,
          autosaveState: const AutosaveState(
            dirty: false,
            hasUnsavedChanges: true,
            saving: false,
            lastError: null,
            hasSavedCheckpoint: true,
          ),
        ),
      ),
    );
    await tester.pump();

    final request = messenger.handlePlatformMessage(
      closeChannel.name,
      closeChannel.codec.encodeMethodCall(const MethodCall('requestQuit')),
      null,
    );
    await tester.pump();
    expect(find.text('Unsaved changes'), findsOneWidget);
    await tester.tap(find.text('Save').last);
    await tester.pumpAndSettle();
    await request;

    expect(engine.savedPath, '/tmp/current.inkproj');
    expect(nativeReplies, <String>['cancelTerminate']);
    expect(
      find.text('New edits arrived while saving. Save again before closing.'),
      findsOneWidget,
    );
  });

  testWidgets('new document validates and forwards canvas settings', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final engine = InMemoryEngineApi();
    (int, int, double)? created;
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: engine,
          targetPlatform: TargetPlatform.macOS,
          onNewDocument: ({
            required int widthPx,
            required int heightPx,
            required double dpi,
          }) async {
            created = (widthPx, heightPx, dpi);
          },
        ),
      ),
    );
    await tester.pump();

    await _invokeCommand(tester, 'New canvas');
    expect(
      find.textContaining('The canvas is transparent sRGB'),
      findsOneWidget,
    );

    final fields = find.byType(TextFormField);
    expect(tester.widget<TextFormField>(fields.at(0)).controller!.text, '1440');
    expect(tester.widget<TextFormField>(fields.at(1)).controller!.text, '2400');
    await tester.tap(find.text('Square'));
    await tester.pump();
    expect(tester.widget<TextFormField>(fields.at(0)).controller!.text, '2048');
    expect(tester.widget<TextFormField>(fields.at(1)).controller!.text, '2048');
    await tester.tap(find.text('A4 print'));
    await tester.pump();
    expect(tester.widget<TextFormField>(fields.at(0)).controller!.text, '2480');
    expect(tester.widget<TextFormField>(fields.at(1)).controller!.text, '3508');
    expect(
      tester.widget<TextFormField>(fields.at(2)).controller!.text,
      '300.0',
    );
    await tester.tap(find.text('Screen size'));
    await tester.pump();
    await tester.enterText(fields.at(0), '640');
    await tester.enterText(fields.at(1), '480');
    await tester.enterText(fields.at(2), '144');
    expect(find.text('Custom'), findsOneWidget);
    await tester.tap(find.text('Create canvas'));
    await tester.pumpAndSettle();

    expect(created, (640, 480, 144.0));
  });

  testWidgets('New offers cancel and discard for unsaved recovery changes', (
    tester,
  ) async {
    final engine = InMemoryEngineApi();
    (int, int, double)? created;
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: engine,
          targetPlatform: TargetPlatform.linux,
          autosaveState: const AutosaveState(
            dirty: false,
            hasUnsavedChanges: true,
            saving: false,
            lastError: null,
            hasSavedCheckpoint: true,
          ),
          onNewDocument: ({
            required int widthPx,
            required int heightPx,
            required double dpi,
          }) async {
            created = (widthPx, heightPx, dpi);
          },
        ),
      ),
    );
    await tester.pump();

    Future<void> requestNew() async {
      await _invokeCommand(tester, 'New canvas');
      await tester.tap(find.text('Create canvas'));
      await tester.pumpAndSettle();
    }

    await requestNew();
    expect(find.text('Unsaved changes'), findsOneWidget);
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(created, isNull);

    await requestNew();
    await tester.tap(find.text('Discard').last);
    await tester.pumpAndSettle();
    expect(created, isNotNull);
  });

  testWidgets('replacing the engine keeps the canvas subtree valid', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: CanvasScreen(engine: _RecordingEngine())),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      MaterialApp(home: CanvasScreen(engine: _RecordingEngine())),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.bySemanticsLabel('Drawing canvas'), findsOneWidget);
  });

  testWidgets('replacement live surface waits for prior disposal', (
    tester,
  ) async {
    final firstEngine = InMemoryEngineApi();
    final secondEngine = InMemoryEngineApi();
    final previews = <EngineApi, _DeferredLivePreview>{};
    _DeferredLivePreview createPreview(EngineApi engine) {
      final preview = _DeferredLivePreview();
      previews[engine] = preview;
      return preview;
    }

    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: firstEngine,
          livePreviewControllerFactory: createPreview,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final firstPreview = previews[firstEngine]!;
    expect(firstPreview.viewportSyncCount, greaterThan(0));

    final disposalGate = Completer<void>();
    firstPreview.disposalGate = disposalGate;
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: secondEngine,
          livePreviewControllerFactory: createPreview,
        ),
      ),
    );
    await tester.pump();

    final secondPreview = previews[secondEngine]!;
    expect(firstPreview.disposed, isTrue);
    expect(secondPreview.viewportSyncCount, 0);
    disposalGate.complete();
    await tester.pumpAndSettle();
    expect(secondPreview.viewportSyncCount, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('save-name route remains safe through document replacement', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: _RecordingEngine(),
          documentPicker: _Picker(),
          targetPlatform: TargetPlatform.macOS,
        ),
      ),
    );
    await tester.pump();

    await _invokeCommand(tester, 'Save project as');
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      MaterialApp(home: CanvasScreen(engine: _RecordingEngine())),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.bySemanticsLabel('Drawing canvas'), findsOneWidget);
  });

  testWidgets('invalid new-document dimensions cannot be submitted', (
    tester,
  ) async {
    var created = false;
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: InMemoryEngineApi(),
          targetPlatform: TargetPlatform.macOS,
          onNewDocument: ({
            required int widthPx,
            required int heightPx,
            required double dpi,
          }) async {
            created = true;
          },
        ),
      ),
    );
    await tester.pump();

    await _invokeCommand(tester, 'New canvas');
    await tester.enterText(find.byType(TextFormField).at(0), '0');
    await tester.tap(find.text('Create canvas'));
    await tester.pump();

    expect(find.text('Enter a value from 1 to 32768 pixels'), findsOneWidget);
    expect(created, isFalse);
  });

  testWidgets('document toolbar routes picker paths to the engine', (
    tester,
  ) async {
    final engine = _RecordingEngine();
    String? openedPath;
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: engine,
          documentPicker: _Picker(),
          targetPlatform: TargetPlatform.macOS,
          onOpenDocument: (path) async => openedPath = path,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('More commands'));
    await tester.pumpAndSettle();
    expect(find.text('Save project'), findsOneWidget);
    expect(find.text('Export PNG'), findsOneWidget);
    expect(find.text('Open project'), findsOneWidget);
    await _invokeCommand(tester, 'Save project');
    await _invokeCommand(tester, 'Export PNG');
    await _invokeCommand(tester, 'Open project');

    expect(engine.savedPath, '/tmp/save.inkproj');
    expect(engine.exportedPath, '/tmp/export.png');
    expect(openedPath, '/tmp/open.inkproj');
  });

  testWidgets('comic package Open uses the multi-page project route', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'project-ink-comic-open-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    File(
      '${directory.path}${Platform.pathSeparator}comic.json',
    ).writeAsStringSync('{}');
    final controller = _RecordingComicController();
    var standaloneOpens = 0;
    var beforeOpen = 0;
    String? openedPath;
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: _RecordingEngine(),
          documentPicker: _StudioPicker(directory.path),
          targetPlatform: TargetPlatform.macOS,
          comicWorkspaceController: controller,
          onOpenDocument: (_) async => standaloneOpens++,
          onBeforeOpenStudioProject: () async => beforeOpen++,
          onStudioProjectOpened: (path) async => openedPath = path,
        ),
      ),
    );
    await tester.pump();

    await _invokeCommand(tester, 'Open project');

    expect(controller.openedPath, directory.path);
    expect(standaloneOpens, 0);
    expect(beforeOpen, 1);
    expect(openedPath, directory.path);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rejected comic Open preserves the current document route', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'project-ink-comic-open-rejected-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    File(
      '${directory.path}${Platform.pathSeparator}comic.json',
    ).writeAsStringSync('{}');
    final controller = _FailingComicController();
    var standaloneOpens = 0;
    var studioOpened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: _RecordingEngine(),
          documentPicker: _StudioPicker(directory.path),
          targetPlatform: TargetPlatform.macOS,
          activeDocumentPath: '/tmp/current.inkproj',
          comicWorkspaceController: controller,
          onOpenDocument: (_) async => standaloneOpens++,
          onStudioProjectOpened: (_) async => studioOpened = true,
        ),
      ),
    );
    await tester.pump();

    await _invokeCommand(tester, 'Open project');

    expect(controller.openedPath, directory.path);
    expect(standaloneOpens, 0);
    expect(studioOpened, isFalse);
    expect(
      tester.widget<CanvasScreen>(find.byType(CanvasScreen)).activeDocumentPath,
      '/tmp/current.inkproj',
    );
    expect(find.bySemanticsLabel('Drawing canvas'), findsOneWidget);
    expect(
      find.text(
        'Could not open the selected comic project. It may be damaged, unsupported, or inaccessible. Your current project remains open.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('EngineErrorImpl'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelled open and save pickers leave the document untouched', (
    tester,
  ) async {
    final engine = _RecordingEngine();
    final picker = _CancelDocumentPicker();
    var openRequests = 0;
    var savedNotifications = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: engine,
          documentPicker: picker,
          targetPlatform: TargetPlatform.macOS,
          activeDocumentPath: '/tmp/current.inkproj',
          autosaveState: const AutosaveState(
            dirty: false,
            hasUnsavedChanges: true,
            saving: false,
            lastError: null,
            hasSavedCheckpoint: true,
          ),
          onOpenDocument: (_) async => openRequests++,
          onDocumentSaved: (_) async => savedNotifications++,
        ),
      ),
    );
    await tester.pump();

    await _invokeCommand(tester, 'Open project');
    await _invokeCommand(tester, 'Save project as');

    expect(openRequests, 0);
    expect(picker.saveRequests, 1);
    expect(engine.savedPath, isNull);
    expect(savedNotifications, 0);
    final canvas = tester.widget<CanvasScreen>(find.byType(CanvasScreen));
    expect(canvas.activeDocumentPath, '/tmp/current.inkproj');
    expect(canvas.autosaveState?.hasUnsavedChanges, isTrue);
    expect(find.bySemanticsLabel('Drawing canvas'), findsOneWidget);
  });

  testWidgets('Open offers cancel and discard for unsaved recovery changes', (
    tester,
  ) async {
    final engine = _RecordingEngine();
    var openRequests = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: engine,
          documentPicker: _Picker(),
          autosaveState: const AutosaveState(
            dirty: false,
            hasUnsavedChanges: true,
            saving: false,
            lastError: null,
            hasSavedCheckpoint: true,
          ),
          targetPlatform: TargetPlatform.linux,
          onOpenDocument: (_) async => openRequests++,
        ),
      ),
    );
    await tester.pump();

    await _invokeCommand(tester, 'Open project');
    expect(
      find.text(
        'Your recovery copy contains changes since the last explicit save. If you continue with Discard, the recovery copy and those changes will be removed. The last explicitly saved project will remain unchanged.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(openRequests, 0);

    await _invokeCommand(tester, 'Open project');
    await tester.tap(find.text('Discard').last);
    await tester.pumpAndSettle();
    expect(openRequests, 1);
  });

  testWidgets('PSD replacement offers cancel and discard for recovery edits', (
    tester,
  ) async {
    final engine = _RecordingEngine();
    String? importedPath;
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: engine,
          documentPicker: _PsdPicker(),
          autosaveState: const AutosaveState(
            dirty: false,
            hasUnsavedChanges: true,
            saving: false,
            lastError: null,
            hasSavedCheckpoint: true,
          ),
          targetPlatform: TargetPlatform.macOS,
          onOpenDocument: (path) async => importedPath = path,
        ),
      ),
    );
    await tester.pump();

    Future<void> importPsd() async {
      await tester.tap(find.byTooltip('Menu menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import PSD').last);
      await tester.pumpAndSettle();
    }

    await importPsd();
    expect(find.text('Unsaved changes'), findsOneWidget);
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(importedPath, isNull);

    await importPsd();
    expect(find.text('Unsaved changes'), findsOneWidget);
    await tester.tap(find.text('Discard').last);
    await tester.pumpAndSettle();
    expect(importedPath, '/tmp/replacement.psd');
  });

  testWidgets('failed project open keeps canvas and explains likely cause', (
    tester,
  ) async {
    final engine = _RecordingEngine();
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: engine,
          documentPicker: _Picker(),
          targetPlatform: TargetPlatform.macOS,
          onOpenDocument: (_) async {
            throw const DocumentOpenException(
              'Could not open the selected document. It may be damaged, unsupported, or inaccessible.',
            );
          },
        ),
      ),
    );
    await tester.pump();

    await _invokeCommand(tester, 'Open project');

    expect(find.bySemanticsLabel('Drawing canvas'), findsOneWidget);
    expect(
      find.text(
        'Could not open the selected document. It may be damaged, unsupported, or inaccessible.',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('document replacement blocks new strokes until it completes', (
    tester,
  ) async {
    final engine = _RecordingEngine();
    final replacementStarted = Completer<void>();
    final finishReplacement = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: engine,
          documentPicker: _Picker(),
          targetPlatform: TargetPlatform.macOS,
          onOpenDocument: (_) async {
            replacementStarted.complete();
            await finishReplacement.future;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final revisionBeforeReplacement = engine.revision;

    await _invokeCommand(tester, 'Open project');
    await tester.pump();
    expect(replacementStarted.isCompleted, isTrue);

    final gesture = await tester.startGesture(
      tester.getCenter(find.bySemanticsLabel('Drawing canvas')),
      kind: PointerDeviceKind.stylus,
    );
    await gesture.moveBy(const Offset(30, 20));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(engine.revision, revisionBeforeReplacement);

    finishReplacement.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('provider write-back waits for a successful local save', (
    tester,
  ) async {
    final engine = _RecordingEngine();
    final picker = _WritebackPicker();
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: engine,
          documentPicker: picker,
          targetPlatform: TargetPlatform.macOS,
        ),
      ),
    );
    await tester.pump();

    await _invokeCommand(tester, 'Save project');

    expect(engine.savedPath, '/tmp/staged.inkproj');
    expect(picker.committedPath, '/tmp/staged.inkproj');
  });

  testWidgets('failed provider write-back does not report a completed save', (
    tester,
  ) async {
    final engine = _RecordingEngine();
    final picker = _FailingWritebackPicker();
    var savedPathNotification = false;
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: engine,
          documentPicker: picker,
          activeDocumentPath: '/tmp/current.inkproj',
          onDocumentSaved: (_) async => savedPathNotification = true,
          targetPlatform: TargetPlatform.macOS,
        ),
      ),
    );
    await tester.pump();

    await _invokeCommand(tester, 'Save project as');

    expect(engine.savedPath, '/tmp/staged.inkproj');
    expect(savedPathNotification, isFalse);
    expect(
      tester.widget<CanvasScreen>(find.byType(CanvasScreen)).activeDocumentPath,
      '/tmp/current.inkproj',
    );
    expect(find.textContaining('Document action failed:'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Save uses the current project path without reopening the picker',
    (tester) async {
      final engine = _RecordingEngine();
      final picker = _Picker();
      String? savedPath;
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasScreen(
            engine: engine,
            documentPicker: picker,
            activeDocumentPath: '/tmp/current.inkproj',
            onDocumentSaved: (path) async => savedPath = path,
            targetPlatform: TargetPlatform.macOS,
          ),
        ),
      );
      await tester.pump();

      await _invokeCommand(tester, 'Save project');

      expect(engine.savedPath, '/tmp/current.inkproj');
      expect(picker.saveRequests, 0);
      expect(savedPath, '/tmp/current.inkproj');
    },
  );

  testWidgets(
    'Save As chooses a new destination and reports it to the session',
    (tester) async {
      final engine = _RecordingEngine();
      final picker = _Picker();
      String? savedPath;
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasScreen(
            engine: engine,
            documentPicker: picker,
            activeDocumentPath: '/tmp/current.inkproj',
            onDocumentSaved: (path) async => savedPath = path,
            targetPlatform: TargetPlatform.macOS,
          ),
        ),
      );
      await tester.pump();

      await _invokeCommand(tester, 'Save project as');

      expect(engine.savedPath, '/tmp/save.inkproj');
      expect(picker.saveRequests, 1);
      expect(savedPath, '/tmp/save.inkproj');
    },
  );

  testWidgets('failed Save As does not adopt its selected destination', (
    tester,
  ) async {
    final engine = _FailingSaveEngine();
    var savedPathNotification = false;
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: engine,
          documentPicker: _Picker(),
          activeDocumentPath: '/tmp/current.inkproj',
          onDocumentSaved: (_) async => savedPathNotification = true,
          targetPlatform: TargetPlatform.macOS,
        ),
      ),
    );
    await tester.pump();

    await _invokeCommand(tester, 'Save project as');

    expect(engine.savedPath, isNull);
    expect(savedPathNotification, isFalse);
    expect(
      tester.widget<CanvasScreen>(find.byType(CanvasScreen)).activeDocumentPath,
      '/tmp/current.inkproj',
    );
    expect(find.textContaining('Document action failed:'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a stalled picker releases file actions and ignores late results',
    (tester) async {
      final engine = _RecordingEngine();
      final picker = _DelayedSavePicker();
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasScreen(
            engine: engine,
            documentPicker: picker,
            documentPickerTimeout: const Duration(milliseconds: 30),
            targetPlatform: TargetPlatform.macOS,
          ),
        ),
      );
      await tester.pump();

      await _invokeCommand(tester, 'Save project');
      await tester.pump(const Duration(milliseconds: 31));
      await tester.pumpAndSettle();

      expect(
        find.text('The file dialog did not respond. You can try again.'),
        findsOneWidget,
      );
      await _invokeCommand(tester, 'Save project');
      expect(engine.savedPath, '/tmp/retry.inkproj');

      picker.delayed.complete('/tmp/late.inkproj');
      await tester.pump();
      expect(engine.savedPath, '/tmp/retry.inkproj');
    },
  );

  testWidgets('provider PNG write-back waits for a successful local export', (
    tester,
  ) async {
    final engine = _RecordingEngine();
    final picker = _PngWritebackPicker();
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: engine,
          documentPicker: picker,
          targetPlatform: TargetPlatform.macOS,
        ),
      ),
    );
    await tester.pump();

    await _invokeCommand(tester, 'Export PNG');

    expect(engine.exportedPath, '/tmp/staged.png');
    expect(picker.committedPath, '/tmp/staged.png');
  });

  testWidgets('mobile save prompts for a project name', (tester) async {
    final engine = _RecordingEngine();
    final picker = _Picker();
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: engine,
          documentPicker: picker,
          targetPlatform: TargetPlatform.iOS,
        ),
      ),
    );
    await tester.pump();

    await _invokeCommand(tester, 'Save project', submitProjectName: false);
    expect(find.text('Project name'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'chapter 1');
    await tester.tap(find.text('Save'));
    await tester.pump();

    expect(picker.suggestedName, 'chapter 1');
  });

  testWidgets('desktop Save As forwards the entered project name', (
    tester,
  ) async {
    final engine = _RecordingEngine();
    final picker = _Picker();
    String? savedPath;
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: engine,
          documentPicker: picker,
          targetPlatform: TargetPlatform.macOS,
          onDocumentSaved: (path) async => savedPath = path,
        ),
      ),
    );
    await tester.pump();

    await _invokeCommand(tester, 'Save project as', submitProjectName: false);
    expect(find.text('Project name'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'phase385be-pathcheck');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(picker.suggestedName, 'phase385be-pathcheck');
    expect(engine.savedPath, '/tmp/save.inkproj');
    expect(savedPath, '/tmp/save.inkproj');
  });

  testWidgets('cancelling the project-name prompt performs no save', (
    tester,
  ) async {
    final engine = _RecordingEngine();
    final picker = _Picker();
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: engine,
          documentPicker: picker,
          targetPlatform: TargetPlatform.iOS,
        ),
      ),
    );
    await tester.pump();

    await _invokeCommand(tester, 'Save project', submitProjectName: false);
    expect(find.text('Project name'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(picker.saveRequests, 0);
    expect(engine.savedPath, isNull);
    expect(find.text('Project name'), findsNothing);
    expect(find.bySemanticsLabel('Drawing canvas'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('brush import shows install summary before install', (
    tester,
  ) async {
    final engine = _ImportEngine();
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: engine,
          documentPicker: _BrushPicker(),
          targetPlatform: TargetPlatform.macOS,
        ),
      ),
    );
    await tester.pump();

    await _invokeCommand(tester, 'Brush library');
    await tester.pump();
    await tester.tap(find.byTooltip('Import brush'));
    await tester.pump();
    expect(find.text('Brush is ready to install'), findsOneWidget);
    expect(engine.inspectedPath, '/tmp/converted.kpp');
    expect(engine.convertedPath, '/tmp/converted.kpp');
    expect(engine.importedPath, isNull);

    await tester.tap(find.text('Install brush'));
    await tester.pumpAndSettle();
    expect(engine.importedPath, '/tmp/converted.kpp');

    // Installation must refresh the library, select the returned stable ID,
    // and route the next real pointer stroke through that custom preset.
    final importedBrushLibrary =
        tester
            .widget<BrushLibraryPanel>(find.byType(BrushLibraryPanel))
            .library;
    expect(
      importedBrushLibrary.filteredPresets.map((brush) => brush.name),
      contains('Imported test brush'),
    );
    expect(importedBrushLibrary.activeTagFilters, isEmpty);
    expect(importedBrushLibrary.selected?.id, 13);
  });

  testWidgets('guided recreation can create a brush from a tip image', (
    tester,
  ) async {
    final engine = _GuidedImageImportEngine();
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: engine,
          documentPicker: _BrushPicker(),
          targetPlatform: TargetPlatform.macOS,
        ),
      ),
    );
    await tester.pump();

    await _invokeCommand(tester, 'Brush library');
    await tester.pump();
    await tester.tap(find.byTooltip('Import brush'));
    await tester.pump();

    expect(find.text('Choose a tip image'), findsOneWidget);
    expect(
      find.textContaining('wasn’t converted or installed'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Choose a tip image'),
          )
          .onPressed,
      isNotNull,
    );
    expect(engine.importedPath, isNull);

    await tester.tap(find.text('Choose a tip image'));
    await tester.pumpAndSettle();
    expect(find.text('Brush tip image ready'), findsOneWidget);
    expect(find.text('Create brush'), findsOneWidget);
    expect(engine.convertedPath, '/tmp/tip.png');
    expect(engine.importedPath, isNull);

    await tester.tap(find.text('Create brush'));
    await tester.pumpAndSettle();
    expect(engine.importedPath, '/tmp/tip.png');
  });

  testWidgets('guided recreation can start from a Project Ink default', (
    tester,
  ) async {
    final engine = _GuidedImageImportEngine();
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: engine,
          documentPicker: _BrushPicker(),
          targetPlatform: TargetPlatform.macOS,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _invokeCommand(tester, 'Brush library');
    await tester.pump();
    await tester.tap(find.byTooltip('Import brush'));
    await tester.pumpAndSettle();
    expect(find.text('More options'), findsOneWidget);
    await tester.tap(find.text('More options'));
    await tester.pumpAndSettle();
    expect(find.text('Start from a Project Ink brush'), findsOneWidget);

    await tester.tap(find.text('Start from a Project Ink brush'));
    await tester.pumpAndSettle();
    expect(find.text('Choose a starter brush'), findsOneWidget);
    await tester.tap(find.text('Round tip'));
    await tester.pumpAndSettle();

    expect(engine.duplicatedBrushId, greaterThan(0));
    expect(engine.renamedBrush, 'Recreated — converted');
    expect(engine.importedPath, isNull);
  });

  testWidgets('guided recreation can explicitly create from extracted images', (
    tester,
  ) async {
    final engine = _GuidedImageImportEngine()..includeExtractedAssets = true;
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: engine,
          documentPicker: _BrushPicker(),
          targetPlatform: TargetPlatform.macOS,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _invokeCommand(tester, 'Brush library');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Import brush'));
    await tester.pumpAndSettle();
    expect(find.text('Create brush from these images'), findsOneWidget);
    expect(
      find.textContaining('wasn’t converted or installed'),
      findsOneWidget,
    );

    await tester.tap(find.text('Create brush from these images'));
    await tester.pumpAndSettle();
    expect(engine.importedPath, '/tmp/converted.kpp');
  });

  testWidgets('Krita bundle import uses the transactional bundle operation', (
    tester,
  ) async {
    final engine = _BundleImportEngine();
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: engine,
          documentPicker: _BrushPicker(),
          targetPlatform: TargetPlatform.macOS,
        ),
      ),
    );
    await tester.pump();

    await _invokeCommand(tester, 'Brush library');
    await tester.pump();
    await tester.tap(find.byTooltip('Import brush'));
    await tester.pump();
    expect(find.text('Brush is ready to install'), findsOneWidget);
    await tester.tap(find.text('Import details'));
    await tester.pumpAndSettle();
    expect(find.text('Brushes in pack: 2'), findsOneWidget);

    await tester.tap(find.text('Install brush'));
    await tester.pump();
    expect(engine.bundleImportedPath, '/tmp/converted.kpp');
    expect(engine.importedPath, isNull);
  });
}

Finder _command(String labelPrefix) => find.byWidgetPredicate(
  (widget) =>
      widget is Tooltip && (widget.message?.startsWith(labelPrefix) ?? false),
);

Future<void> _invokeCommand(
  WidgetTester tester,
  String labelPrefix, {
  bool submitProjectName = true,
}) async {
  await tester.pumpAndSettle();
  final directCommand = _command(labelPrefix);
  if (directCommand.evaluate().isNotEmpty) {
    await tester.tap(directCommand);
  } else {
    final menuItem = find.text(labelPrefix);
    if (menuItem.evaluate().isEmpty) {
      await tester.tap(find.byTooltip('More commands'));
      await tester.pumpAndSettle();
    }
    await tester.ensureVisible(menuItem);
    await tester.pumpAndSettle();
    await tester.tap(menuItem);
  }
  await tester.pump(const Duration(milliseconds: 1));
  if (submitProjectName && find.text('Project name').evaluate().isNotEmpty) {
    await tester.enterText(find.byType(TextField), 'untitled');
    await tester.tap(find.text('Save'));
    await tester.pump();
  }
  await tester.pumpAndSettle();
}
