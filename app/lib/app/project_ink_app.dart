import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../canvas/canvas_screen.dart';
import '../canvas/live_preview_controller.dart';
import '../canvas/performance_trace.dart';
import '../bridge/engine_api.dart';
import '../comics/comic_workspace.dart';
import '../documents/autosave_coordinator.dart';
import '../documents/document_picker.dart';
import '../documents/recovery_checkpoint_store.dart';
import '../design_system/ink_theme.dart';
import 'workspace_preferences.dart';

class ProjectInkApp extends StatefulWidget {
  const ProjectInkApp({
    super.key,
    this.engineOverride,
    this.autosavePath,
    this.recoveryDirectory,
    this.documentPicker,
    @visibleForTesting this.targetPlatformOverride,
    this.openDocumentEngine,
    @visibleForTesting this.openRecoveryEngine,
    @visibleForTesting this.recoveryProjectExists,
    this.onOpenDocument,
    @visibleForTesting this.deleteRecoveryCheckpoint,
    this.onAutosaveStateChanged,
    this.onPerformanceSnapshot,
    this.performanceTracePath,
    @visibleForTesting this.livePreviewControllerFactory,
    @visibleForTesting this.comicWorkspaceController,
  });

  /// Optional engine seam for widget tests. Production entry points leave this
  /// null so Rust remains the only document and pixel authority.
  final EngineApi? engineOverride;

  /// Optional native `.inkproj` destination selected by the document session.
  /// When omitted, the app remains a new unsaved document.
  final String? autosavePath;

  /// Trusted app-owned directory allowed to contain a disposable checkpoint.
  /// Custom [autosavePath] values are never recursively deleted by default.
  final String? recoveryDirectory;

  /// Optional platform implementation for the document toolbar.
  final DocumentPicker? documentPicker;

  /// Optional platform override for desktop UI widget tests.
  @visibleForTesting
  final TargetPlatform? targetPlatformOverride;

  /// Optional engine factory for document-open lifecycle tests. Production
  /// keeps the Rust project loader as the sole default implementation.
  final Future<EngineApi> Function(String path)? openDocumentEngine;

  /// Optional recovery opener seam for startup lifecycle tests. Production
  /// routes standalone and Studio checkpoints through the Rust-backed loader.
  @visibleForTesting
  final Future<EngineApi> Function(String path)? openRecoveryEngine;

  @visibleForTesting
  final Future<bool> Function(String path)? recoveryProjectExists;

  /// Parent-owned document replacement callback for an approved open path.
  final Future<void> Function(String path)? onOpenDocument;

  /// Optional deletion seam for deterministic recovery-cleanup failure tests.
  @visibleForTesting
  final Future<void> Function(String path)? deleteRecoveryCheckpoint;

  /// Local-only status hook for a document shell or accessibility surface.
  final ValueChanged<AutosaveState>? onAutosaveStateChanged;

  /// Optional local-only hook for Phase 1 physical-device acceptance traces.
  final ValueChanged<Phase1PerformanceSnapshot>? onPerformanceSnapshot;

  /// Optional newline-delimited JSON path for local Phase 1 trace capture.
  /// No file is created when this is omitted.
  final String? performanceTracePath;

  /// Optional renderer seam for integration tests that focus on document
  /// persistence rather than the native texture lifecycle.
  @visibleForTesting
  final LivePreviewController Function(EngineApi engine)?
  livePreviewControllerFactory;

  /// Isolates document-session tests from sample comic loading and page binds.
  @visibleForTesting
  final ComicWorkspaceController? comicWorkspaceController;

  @override
  State<ProjectInkApp> createState() => _ProjectInkAppState();
}

class _ProjectInkAppState extends State<ProjectInkApp> {
  late Future<EngineApi> _engine;
  late String? _activeAutosavePath;
  String? _activeDocumentPath;
  bool _autosaveInitiallyUnsavedChanges = false;
  AutosaveCoordinator? _autosave;
  final Set<EngineApi> _retiringEngines = <EngineApi>{};
  AutosaveState? _autosaveState;
  EngineApi? _autosaveEngine;
  String? _autosaveBoundPath;
  Phase1PerformanceRecorder? _performanceRecorder;
  WorkspacePreferences _workspacePreferences = const WorkspacePreferences();
  final WorkspacePreferencesStore _workspacePreferenceStore =
      const WorkspacePreferencesStore();
  static const _memorySampler = Phase1MemorySampler();
  static const _memorySampleInterval = Duration(seconds: 1);
  DateTime? _lastMemorySampleAt;
  int? _lastRssBytes;

  @override
  void initState() {
    super.initState();
    _activeAutosavePath = widget.autosavePath;
    final tracePath = widget.performanceTracePath;
    if (tracePath != null && tracePath.isNotEmpty) {
      _performanceRecorder = Phase1PerformanceRecorder(tracePath);
    }
    _engine = _createEngine();
    unawaited(_loadWorkspacePreferences());
  }

  Future<void> _loadWorkspacePreferences() async {
    final preferences = await _workspacePreferenceStore.load();
    if (mounted) setState(() => _workspacePreferences = preferences);
  }

  void _onWorkspacePreferencesChanged(WorkspacePreferences preferences) {
    if (!mounted) return;
    setState(() => _workspacePreferences = preferences);
    // Preference writes are device-local and never block pointer or document
    // work. The store validates and bounds values before serializing them.
    unawaited(_saveWorkspacePreferences(preferences));
  }

  Future<void> _saveWorkspacePreferences(
    WorkspacePreferences preferences,
  ) async {
    try {
      await _workspacePreferenceStore.save(preferences);
    } catch (error, stack) {
      // A preference failure must not affect drawing or document persistence.
      debugPrint(
        'Project Ink workspace preferences unavailable: $error\n$stack',
      );
    }
  }

  Future<EngineApi> _createEngine() async {
    debugPrint('Project Ink startup: creating engine');
    final override = widget.engineOverride;
    if (override != null) {
      debugPrint('Project Ink startup: using injected engine');
      return override;
    }

    final recoveryPath = _activeAutosavePath;
    if (recoveryPath != null && recoveryPath.isNotEmpty) {
      try {
        // A recovery project is a directory-backed atomic checkpoint. Only
        // attempt to open an existing directory; a missing path is the normal
        // first-run case and must not delay engine startup with an error.
        debugPrint('Project Ink startup: checking recovery project');
        final exists =
            await (widget.recoveryProjectExists?.call(recoveryPath) ??
                Directory(recoveryPath).exists());
        if (exists) {
          debugPrint('Project Ink startup: opening recovery project');
          final openRecovery =
              widget.openRecoveryEngine ?? FrbEngineApi.openRecovery;
          final recovered = await openRecovery(recoveryPath);
          _autosaveInitiallyUnsavedChanges = true;
          return recovered;
        }
        debugPrint('Project Ink startup: recovery project does not exist');
      } catch (error, stack) {
        // Do not replace an unreadable or unsupported recovery with a blank
        // document: subsequent edits could otherwise autosave over the only
        // remaining copy of the user's work.
        debugPrint('Project Ink recovery open failed: $error\n$stack');
        Error.throwWithStackTrace(error, stack);
      }
    }
    debugPrint('Project Ink startup: creating default document');
    return FrbEngineApi.create();
  }

  @override
  void didUpdateWidget(covariant ProjectInkApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.engineOverride != widget.engineOverride) {
      _engine = _createEngine();
    }
    if (oldWidget.autosavePath != widget.autosavePath ||
        oldWidget.onAutosaveStateChanged != widget.onAutosaveStateChanged) {
      _activeAutosavePath = widget.autosavePath;
      final previous = _autosave;
      _autosave = null;
      _autosaveEngine = null;
      _autosaveState = null;
      unawaited(previous?.dispose());
    }
    if (oldWidget.performanceTracePath != widget.performanceTracePath) {
      final previous = _performanceRecorder;
      _performanceRecorder = null;
      unawaited(previous?.flush());
      final tracePath = widget.performanceTracePath;
      if (tracePath != null && tracePath.isNotEmpty) {
        _performanceRecorder = Phase1PerformanceRecorder(tracePath);
      }
    }
  }

  AutosaveCoordinator? _autosaveFor(EngineApi engine) {
    final path = _activeAutosavePath;
    if (path == null || path.isEmpty) return null;
    if (_autosave == null ||
        _autosaveEngine != engine ||
        _autosaveBoundPath != path) {
      final previous = _autosave;
      late final AutosaveCoordinator coordinator;
      coordinator = AutosaveCoordinator(
        engine: engine,
        path: path,
        hasSavedCheckpoint: _activeDocumentPath != null,
        hasUnsavedChanges: _autosaveInitiallyUnsavedChanges,
        onStateChanged: (state) {
          if (!identical(_autosave, coordinator)) return;
          _autosaveState = state;
          widget.onAutosaveStateChanged?.call(state);
          if (mounted) setState(() {});
        },
      );
      _autosave = coordinator;
      _autosaveState = coordinator.state;
      _autosaveEngine = engine;
      _autosaveBoundPath = path;
      if (previous != null) unawaited(previous.dispose());
    }
    return _autosave;
  }

  Future<void> _openDocument(String path) async {
    final previous = _autosave;
    // A save in flight has already cleared the dirty flag. Always drain the
    // coordinator before replacing/closing its engine, including that state.
    if (previous != null) await previous.flush();

    // Construct the new Rust handle before replacing the current one. A
    // rejected or unreadable project therefore leaves the current canvas
    // untouched.
    final next =
        await (widget.openDocumentEngine?.call(path) ??
            FrbEngineApi.open(path));
    if (!mounted) {
      await next.close();
      return;
    }
    try {
      // The candidate is now known-good. Remove only the old session copy;
      // future edits to this named project checkpoint to the recovery path.
      await _clearRecoveryCheckpoint();
    } catch (_) {
      await next.close();
      rethrow;
    }
    _autosave = null;
    _autosaveEngine = null;
    _autosaveBoundPath = null;
    _autosaveState = null;
    try {
      await previous?.dispose(flush: false);
    } catch (_) {
      await next.close();
      rethrow;
    }
    if (!mounted) {
      await next.close();
      return;
    }
    setState(() {
      _activeAutosavePath = widget.autosavePath;
      _activeDocumentPath = path;
      _autosaveInitiallyUnsavedChanges = false;
      _engine = Future<EngineApi>.value(next);
    });
  }

  Future<void> _newDocument({
    required int widthPx,
    required int heightPx,
    required double dpi,
  }) async {
    final next =
        widget.engineOverride == null
            ? await FrbEngineApi.create(
              widthPx: widthPx,
              heightPx: heightPx,
              dpi: dpi,
            )
            : InMemoryEngineApi();
    if (!mounted) {
      await next.close();
      return;
    }

    final previousAutosave = _autosave;
    try {
      // Preserve the current project/checkpoint before this explicit document
      // replacement. A failure here leaves the visible engine untouched.
      await previousAutosave?.flush();
      await _clearRecoveryCheckpoint();
    } catch (_) {
      await next.close();
      rethrow;
    }
    _autosave = null;
    _autosaveEngine = null;
    _autosaveBoundPath = null;
    _autosaveState = null;
    await previousAutosave?.dispose(flush: false);
    if (!mounted) {
      await next.close();
      return;
    }
    setState(() {
      _activeAutosavePath = widget.autosavePath;
      _activeDocumentPath = null;
      _autosaveInitiallyUnsavedChanges = false;
      _engine = Future<EngineApi>.value(next);
    });
  }

  Future<void> _documentSaved(String path) async {
    final previous = _autosave;
    // Finish edits that arrived while the explicit save was in flight. They
    // remain in recovery if they were not part of the saved revision.
    await previous?.flush();
    final changesAfterSave = previous?.hasUnsavedChanges ?? false;
    _activeDocumentPath = path;
    _autosaveInitiallyUnsavedChanges = changesAfterSave;
    if (!changesAfterSave) await _clearRecoveryCheckpoint();
    if (mounted) setState(() {});
  }

  Future<void> _beforeOpenStudioProject() async {
    // Drain the old document checkpoint before the shared engine capability
    // is rebound to the incoming project's first page.
    await _autosave?.flush();
  }

  Future<void> _studioProjectOpened(String path) async {
    final previous = _autosave;
    _autosave = null;
    _autosaveEngine = null;
    _autosaveBoundPath = null;
    _autosaveState = null;
    await _clearRecoveryCheckpoint();
    _activeAutosavePath = widget.autosavePath;
    _activeDocumentPath = path;
    _autosaveInitiallyUnsavedChanges = false;
    // The old coordinator was flushed before the capability rebind. It must
    // not issue another save against the now-rebound studio project.
    await previous?.dispose(flush: false);
    if (mounted) setState(() {});
  }

  Future<void> _clearRecoveryCheckpoint() async {
    final recoveryPath = _activeAutosavePath;
    if (recoveryPath == null || recoveryPath.isEmpty) return;
    final deleteOverride = widget.deleteRecoveryCheckpoint;
    if (deleteOverride != null) {
      await deleteOverride(recoveryPath);
      return;
    }
    final recoveryDirectory = widget.recoveryDirectory;
    if (recoveryDirectory == null) return;
    await RecoveryCheckpointStore(
      recoveryDirectory: recoveryDirectory,
    ).delete(recoveryPath);
  }

  Future<void> _discardRecoveryForClose() async {
    final previous = _autosave;
    _autosave = null;
    _autosaveEngine = null;
    _autosaveBoundPath = null;
    _autosaveState = null;
    try {
      await previous?.discard();
      await _clearRecoveryCheckpoint();
    } catch (error, stack) {
      // Close will be canceled on cleanup failure. Rebind autosave so further
      // edits in the still-open document continue producing recovery copies.
      _autosaveInitiallyUnsavedChanges = true;
      try {
        if (mounted && _activeAutosavePath?.isNotEmpty == true) {
          final engine = await _engine;
          if (mounted) _autosaveFor(engine)?.markDirty();
        }
      } catch (restoreError, restoreStack) {
        debugPrint(
          'Project Ink recovery scheduling could not be restored: '
          '$restoreError\n$restoreStack',
        );
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  @override
  void dispose() {
    final autosave = _autosave;
    final retiringEngines = _retiringEngines.toList(growable: false);
    // Invalidate the callback before dispose flushes a pending checkpoint;
    // disposal must not schedule a rebuild on this state object.
    _autosave = null;
    _autosaveState = null;
    unawaited(_performanceRecorder?.flush());
    unawaited(_disposeDocumentResources(autosave, _engine, retiringEngines));
    super.dispose();
  }

  Future<void> _disposeDocumentResources(
    AutosaveCoordinator? autosave,
    Future<EngineApi> engine,
    List<EngineApi> retiringEngines,
  ) async {
    // A final autosave and engine.close() use the same Rust handle. Drain the
    // checkpoint first; closing concurrently can invalidate an in-flight save
    // and lose the last confirmed document revision.
    try {
      await autosave?.dispose();
    } catch (error, stack) {
      debugPrint(
        'Project Ink final recovery checkpoint failed: $error\n$stack',
      );
    }
    await _closeEngine(engine);
    for (final retiringEngine in retiringEngines) {
      await _closeEngine(Future<EngineApi>.value(retiringEngine));
    }
  }

  Future<void> _closeEngine(Future<EngineApi> engineFuture) async {
    try {
      final engine = await engineFuture;
      await engine.close();
    } catch (error, stack) {
      debugPrint('Project Ink engine shutdown failed: $error\n$stack');
    }
  }

  void _retireEngineAfterCanvasCleanup(
    EngineApi previousEngine,
    Future<void> surfaceDisposal,
  ) {
    if (!_retiringEngines.add(previousEngine)) return;
    unawaited(() async {
      try {
        await surfaceDisposal;
        await previousEngine.close();
      } catch (error, stack) {
        debugPrint(
          'Project Ink retired engine shutdown failed: $error\n$stack',
        );
      } finally {
        _retiringEngines.remove(previousEngine);
      }
    }());
  }

  void _handlePerformanceSnapshot(Phase1PerformanceSnapshot snapshot) {
    widget.onPerformanceSnapshot?.call(snapshot);
    final recorder = _performanceRecorder;
    if (recorder == null) return;
    // Keep trace records ordered and sample native memory at a low cadence so
    // the diagnostics channel cannot become part of the drawing hot path.
    recorder.append(snapshot.withRssBytes(_lastRssBytes));
    final now = DateTime.now();
    final previous = _lastMemorySampleAt;
    if (previous != null && now.difference(previous) < _memorySampleInterval) {
      return;
    }
    _lastMemorySampleAt = now;
    unawaited(_sampleMemory());
  }

  Future<void> _sampleMemory() async {
    final rssBytes = await _memorySampler.readRssBytes();
    if (rssBytes != null) _lastRssBytes = rssBytes;
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Project Ink',
    debugShowCheckedModeBanner: false,
    // The current product ships English-only interface copy. Keep the chosen
    // app locale deterministic when the host OS requests an unsupported one.
    supportedLocales: const [Locale('en')],
    theme: InkTheme.light(),
    highContrastTheme: InkTheme.light(highContrast: true),
    darkTheme: InkTheme.dark(),
    highContrastDarkTheme: InkTheme.dark(highContrast: true),
    themeMode: switch (_workspacePreferences.theme) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.dark,
    },
    home: FutureBuilder<EngineApi>(
      future: _engine,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _EngineUnavailable(error: snapshot.error!);
        }
        if (!snapshot.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final engine = snapshot.data!;
        return CanvasScreen(
          engine: engine,
          comicWorkspaceController: widget.comicWorkspaceController,
          targetPlatform: widget.targetPlatformOverride,
          livePreviewControllerFactory: widget.livePreviewControllerFactory,
          autosave: _autosaveFor(engine),
          autosaveState: _autosaveState,
          documentPicker: widget.documentPicker,
          onNewDocument: _newDocument,
          activeDocumentPath: _activeDocumentPath,
          onDocumentSaved: _documentSaved,
          onBeforeOpenStudioProject: _beforeOpenStudioProject,
          onStudioProjectOpened: _studioProjectOpened,
          onDiscardRecovery: _discardRecoveryForClose,
          onEngineReplaced: _retireEngineAfterCanvasCleanup,
          desktopDockEnabled: true,
          layoutModeOverride: _workspacePreferences.layoutModeOverride,
          workspaceDockWidth: _workspacePreferences.dockWidth,
          workspacePreferences: _workspacePreferences,
          onWorkspacePreferencesChanged: _onWorkspacePreferencesChanged,
          onOpenDocument: widget.onOpenDocument ?? _openDocument,
          onPerformanceSnapshot:
              widget.onPerformanceSnapshot != null ||
                      _performanceRecorder != null
                  ? _handlePerformanceSnapshot
                  : null,
        );
      },
    ),
  );
}

class _EngineUnavailable extends StatelessWidget {
  const _EngineUnavailable({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: 16),
            const Text(
              'Project Ink could not open the drawing engine or recovery project. '
              'Any existing recovery project was left untouched.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            SelectableText('$error', textAlign: TextAlign.center),
          ],
        ),
      ),
    ),
  );
}
