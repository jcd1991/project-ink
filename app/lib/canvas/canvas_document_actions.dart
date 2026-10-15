import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../app/editor_action.dart';
import '../bridge/engine_api.dart';
import '../comics/comic_workspace.dart';
import '../documents/document_picker.dart';
import '../documents/recent_projects.dart';
import '../tools/brush_library.dart';
import 'canvas_document_action_session.dart';
import 'canvas_document_dialogs.dart';

const _comicProjectOpenFailureMessage =
    'Could not open the selected comic project. It may be damaged, unsupported, or inaccessible. Your current project remains open.';

/// Explicit screen services and state used by [CanvasDocumentActions].
class CanvasDocumentActionHost {
  const CanvasDocumentActionHost({
    required this.session,
    required this.context,
    required this.mounted,
    required this.setState,
    required this.setActiveBrushId,
    required this.brushLibrary,
    required this.comicWorkspace,
    required this.documentActionGeneration,
    required this.setDocumentActionGeneration,
    required this.documentActionRunning,
    required this.setDocumentActionRunning,
    required this.loadPhase2Projections,
    required this.runWithDocumentReplacementBarrier,
    required this.respondToNativeWindowClose,
    required this.showNativeWindowCloseError,
  });

  final CanvasDocumentActionSession Function() session;
  final BuildContext Function() context;
  final bool Function() mounted;
  final void Function(VoidCallback callback) setState;
  final ValueChanged<int> setActiveBrushId;
  final BrushLibraryModel Function() brushLibrary;
  final ComicWorkspaceController Function() comicWorkspace;
  final int Function() documentActionGeneration;
  final ValueChanged<int> setDocumentActionGeneration;
  final bool Function() documentActionRunning;
  final ValueChanged<bool> setDocumentActionRunning;
  final Future<void> Function() loadPhase2Projections;
  final Future<void> Function(Future<void> Function() action)
  runWithDocumentReplacementBarrier;
  final Future<void> Function(String method) respondToNativeWindowClose;
  final void Function(Object error) showNativeWindowCloseError;
}

/// Owns file, project, import, export, and document-picker workflows.
class CanvasDocumentActions {
  CanvasDocumentActions(this.host);

  final CanvasDocumentActionHost host;

  CanvasDocumentActionSession get session => host.session();
  BuildContext get context => host.context();
  bool get mounted => host.mounted();
  void setState(VoidCallback callback) => host.setState(callback);
  set _activeBrushId(int value) => host.setActiveBrushId(value);
  BrushLibraryModel get _brushLibrary => host.brushLibrary();
  ComicWorkspaceController get _comicWorkspace => host.comicWorkspace();
  int get _documentActionGeneration => host.documentActionGeneration();
  set _documentActionGeneration(int value) =>
      host.setDocumentActionGeneration(value);
  bool get _documentActionRunning => host.documentActionRunning();
  set _documentActionRunning(bool value) =>
      host.setDocumentActionRunning(value);

  Future<void> _loadPhase2Projections() => host.loadPhase2Projections();
  Future<void> _runWithDocumentReplacementBarrier(
    Future<void> Function() action,
  ) => host.runWithDocumentReplacementBarrier(action);

  /// Routes file and document commands to the workflows owned here.
  ///
  /// Returns false for actions owned by another canvas subsystem so the route
  /// can continue dispatching them without duplicating document workflow
  /// knowledge.
  bool dispatchEditorAction(EditorActionId action) {
    switch (action) {
      case EditorActionId.newDocument:
        unawaited(newDocument());
        return true;
      case EditorActionId.openProject:
        unawaited(openProject());
        return true;
      case EditorActionId.importPsd:
        unawaited(importPsd());
        return true;
      case EditorActionId.saveProject:
        unawaited(saveProject());
        return true;
      case EditorActionId.saveProjectAs:
        unawaited(saveProjectAs());
        return true;
      case EditorActionId.exportPng:
        unawaited(exportPng());
        return true;
      default:
        return false;
    }
  }

  Future<void> newDocument() async {
    final onNewDocument = session.onNewDocument;
    if (onNewDocument == null) return;
    await _runDocumentAction((generation) async {
      final settings = await showDialog<(int, int, double)>(
        context: context,
        builder: (_) => const NewDocumentDialog(),
      );
      if (settings == null || !_isCurrentDocumentAction(generation)) return;
      if (!await _confirmDocumentReplacement(generation)) return;
      await _runWithDocumentReplacementBarrier(
        () => onNewDocument(
          widthPx: settings.$1,
          heightPx: settings.$2,
          dpi: settings.$3,
        ),
      );
    });
  }

  bool _isCurrentDocumentAction(int generation) =>
      isCurrentDocumentAction(generation);

  Future<void> _exportPng() => exportPng();

  Future<void> openProject() async {
    final picker = session.documentPicker;
    final onOpen = session.onOpenDocument;
    if (picker == null || onOpen == null) return;
    await _runDocumentAction((generation) async {
      final path = await _chooseOpenProjectPath(picker, generation);
      if (path != null && _isCurrentDocumentAction(generation)) {
        if (!await _confirmDocumentReplacement(generation)) return;
        await _runWithDocumentReplacementBarrier(() async {
          final isStudioProject =
              Directory(path).existsSync() &&
              File('$path${Platform.pathSeparator}comic.json').existsSync();
          if (isStudioProject) {
            await session.onBeforeOpenStudioProject?.call();
            final opened = await _comicWorkspace.openProjectFromPath(path);
            if (!opened) {
              // Rust bridge errors are opaque Dart wrappers on some failures;
              // never expose their implementation-only `toString()` to users.
              throw const DocumentOpenException(
                _comicProjectOpenFailureMessage,
              );
            }
            await session.onStudioProjectOpened?.call(path);
          } else {
            await onOpen(path);
          }
        });
      }
    });
  }

  Future<String?> _chooseOpenProjectPath(
    DocumentPicker picker,
    int generation,
  ) async {
    final loadRecentProjects = session.loadRecentProjects;
    if (loadRecentProjects == null) {
      return _awaitDocumentPickerResult(picker.openProject(), generation);
    }
    List<RecentProjectEntry> recentProjects;
    try {
      recentProjects = await loadRecentProjects();
    } catch (_) {
      recentProjects = const <RecentProjectEntry>[];
    }
    if (!context.mounted || !_isCurrentDocumentAction(generation)) return null;
    if (recentProjects.isEmpty) {
      return _awaitDocumentPickerResult(picker.openProject(), generation);
    }
    final choice = await showDialog<_ProjectOpenChoice>(
      context: context,
      builder:
          (dialogContext) => _OpenRecentProjectsDialog(
            entries: recentProjects,
            onRemove: session.removeRecentProject,
          ),
    );
    if (choice == null || !_isCurrentDocumentAction(generation)) return null;
    if (choice.browse) {
      return _awaitDocumentPickerResult(picker.openProject(), generation);
    }
    return choice.path;
  }

  Future<void> importPsd() async {
    final picker = session.documentPicker;
    final onOpen = session.onOpenDocument;
    if (picker is! PsdImportPicker || onOpen == null) return;
    await _runDocumentAction((generation) async {
      final path = await _awaitDocumentPickerResult(
        (picker as PsdImportPicker).openPsd(),
        generation,
      );
      if (path != null && _isCurrentDocumentAction(generation)) {
        final inspection = await session.engine.inspectPsdImport(path);
        if (!context.mounted || !_isCurrentDocumentAction(generation)) return;
        final choice = await showDialog<_PsdImportChoice>(
          context: context,
          builder:
              (dialogContext) => _PsdImportConfirmationDialog(
                inspection: inspection,
                onCancel: () => Navigator.of(dialogContext).pop(),
                onImportEditable:
                    inspection.editableImportAvailable &&
                            session.onImportEditablePsd != null
                        ? () => Navigator.of(
                          dialogContext,
                        ).pop(_PsdImportChoice.editable)
                        : null,
                onImportFlattened:
                    inspection.flattenedImportAvailable
                        ? () => Navigator.of(
                          dialogContext,
                        ).pop(_PsdImportChoice.flattened)
                        : null,
              ),
        );
        if (choice == null || !_isCurrentDocumentAction(generation)) return;
        if (!await _confirmDocumentReplacement(generation)) return;
        await _runWithDocumentReplacementBarrier(() async {
          if (choice == _PsdImportChoice.editable) {
            await session.onImportEditablePsd?.call(path);
          } else {
            await onOpen(path);
          }
        });
      }
    });
  }

  Future<void> saveProject() async {
    final picker = session.documentPicker;
    if (picker == null) return;
    await _runDocumentAction(
      (generation) async {
        await _saveProjectToSelectedDestination(
          picker,
          saveAs: false,
          generation: generation,
        );
      },
      errorMessage: 'Project save failed.',
      retry: saveProject,
    );
  }

  Future<void> saveProjectAs() async {
    final picker = session.documentPicker;
    if (picker == null) return;
    await _runDocumentAction(
      (generation) async {
        await _saveProjectToSelectedDestination(
          picker,
          saveAs: true,
          generation: generation,
        );
      },
      errorMessage: 'Project save failed.',
      retry: saveProjectAs,
    );
  }

  Future<bool> _saveProjectToSelectedDestination(
    DocumentPicker picker, {
    required bool saveAs,
    required int generation,
  }) async {
    var path = saveAs ? null : session.activeDocumentPath;
    if (path == null) {
      final suggestedName = await _suggestedProjectName(
        picker,
        forceNamePrompt: saveAs,
      );
      if (suggestedName == null) return false;
      path = await _awaitDocumentPickerResult(
        picker.saveProject(suggestedName: suggestedName),
        generation,
      );
    }
    if (path == null || !_isCurrentDocumentAction(generation)) return false;
    // Drain any debounced checkpoint before copying a staged provider
    // project. This prevents native write-back from racing a Rust save.
    await session.autosave?.flush();
    final savedRevision = session.engine.revision;
    await session.engine.saveAs(path);
    if (picker case final DocumentWriteback writeback) {
      await writeback.commitProject(path);
    }
    final revisionWasMarkedSaved =
        session.autosave?.markExplicitlySaved(savedRevision: savedRevision) ??
        (session.engine.revision == savedRevision);
    await session.onDocumentSaved?.call(path);
    final documentStillAtSavedRevision =
        session.engine.revision == savedRevision &&
        session.autosave?.hasUnsavedChanges != true;
    if (!revisionWasMarkedSaved || !documentStillAtSavedRevision) {
      if (context.mounted && session.engine.revision != savedRevision) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'New edits arrived while saving. Save again before closing.',
            ),
          ),
        );
      }
      return false;
    }
    return true;
  }

  Future<bool> _confirmDocumentReplacement(int generation) async {
    final choice = await chooseDocumentReplacement(generation);
    return choice == DocumentReplacementChoice.clean ||
        choice == DocumentReplacementChoice.discard ||
        choice == DocumentReplacementChoice.save;
  }

  Future<DocumentReplacementChoice?> chooseDocumentReplacement(
    int generation,
  ) async {
    final hasUnsavedChanges =
        session.autosave?.hasUnsavedChanges ??
        session.autosaveState?.hasUnsavedChanges ??
        false;
    if (!hasUnsavedChanges) return DocumentReplacementChoice.clean;

    final choice = await showDialog<DocumentReplacementChoice>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Unsaved changes'),
            content: const Text(
              'Your recovery copy contains changes since the last explicit save. If you continue with Discard, the recovery copy and those changes will be removed. The last explicitly saved project will remain unchanged.',
            ),
            actions: [
              TextButton(
                onPressed:
                    () => Navigator.of(
                      context,
                    ).pop(DocumentReplacementChoice.cancel),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed:
                    () => Navigator.of(
                      context,
                    ).pop(DocumentReplacementChoice.discard),
                child: const Text('Discard'),
              ),
              FilledButton(
                onPressed:
                    () => Navigator.of(
                      context,
                    ).pop(DocumentReplacementChoice.save),
                child: const Text('Save'),
              ),
            ],
          ),
    );
    if (!_isCurrentDocumentAction(generation)) return null;
    return switch (choice) {
      DocumentReplacementChoice.discard => DocumentReplacementChoice.discard,
      DocumentReplacementChoice.save => await _saveForReplacement(generation),
      _ => null,
    };
  }

  /// Handles a native close/quit request using the document replacement flow.
  Future<Object?> handleNativeWindowCloseRequest(String method) async {
    final isQuitRequest = method == 'requestQuit';
    if (!isQuitRequest && method != 'requestClose') return null;
    if (!mounted || _documentActionRunning) {
      await host.respondToNativeWindowClose(
        isQuitRequest ? 'cancelTerminate' : 'cancelClose',
      );
      return null;
    }

    final generation = ++_documentActionGeneration;
    setState(() => _documentActionRunning = true);
    var allowClose = false;
    try {
      final choice = await chooseDocumentReplacement(generation);
      if (choice == DocumentReplacementChoice.clean ||
          choice == DocumentReplacementChoice.save) {
        allowClose = true;
      } else if (choice == DocumentReplacementChoice.discard) {
        await session.onDiscardRecovery?.call();
        allowClose = true;
      }
    } catch (error) {
      if (mounted) host.showNativeWindowCloseError(error);
    } finally {
      if (mounted && isCurrentDocumentAction(generation)) {
        setState(() => _documentActionRunning = false);
      }
      await host.respondToNativeWindowClose(
        isQuitRequest
            ? (allowClose ? 'allowTerminate' : 'cancelTerminate')
            : (allowClose ? 'allowClose' : 'cancelClose'),
      );
    }
    return null;
  }

  Future<DocumentReplacementChoice?> _saveForReplacement(int generation) async {
    final picker = session.documentPicker;
    if (picker == null) return null;
    final saved = await _saveProjectToSelectedDestination(
      picker,
      saveAs: false,
      generation: generation,
    );
    return saved ? DocumentReplacementChoice.save : null;
  }

  Future<String?> _suggestedProjectName(
    DocumentPicker picker, {
    bool forceNamePrompt = false,
  }) async {
    final providerState =
        picker is ProviderDocumentState
            ? (picker as ProviderDocumentState).hasActiveProviderProject
            : false;
    if (providerState && !forceNamePrompt) return 'untitled.inkproj';

    return showDialog<String>(
      context: context,
      builder: (_) => const ProjectNameDialog(),
    );
  }

  Future<void> exportPng() async {
    final picker = session.documentPicker;
    if (picker == null) return;
    await _runDocumentAction((generation) async {
      final path = await _awaitDocumentPickerResult(
        picker.exportPng(),
        generation,
      );
      if (path != null && _isCurrentDocumentAction(generation)) {
        await session.engine.exportPng(path);
        if (picker case final DocumentPngWriteback writeback) {
          await writeback.commitPng(path);
        }
      }
    });
  }

  Future<void> exportDocumentMenu() async {
    final picker = session.documentPicker;
    if (picker == null || !mounted) return;
    final format = await showDialog<String>(
      context: context,
      builder:
          (context) => SimpleDialog(
            title: const Text('Export artwork'),
            children: [
              for (final option in const <(String, String)>[
                ('png', 'PNG'),
                ('jpeg', 'JPEG'),
                ('webp', 'WebP'),
                ('ora', 'OpenRaster'),
                ('svg', 'SVG'),
                ('psd', 'Flattened PSD'),
                ('psd_editable', 'Editable PSD'),
              ])
                SimpleDialogOption(
                  onPressed: () => Navigator.of(context).pop(option.$1),
                  child: Text(option.$2),
                ),
            ],
          ),
    );
    if (format == null) return;
    if (format == 'png') {
      await _exportPng();
      return;
    }
    if (picker is! DocumentExportPicker) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('This picker supports PNG export only.'),
          ),
        );
      }
      return;
    }
    final exportPicker = picker as DocumentExportPicker;
    final extension =
        format == 'jpeg'
            ? 'jpg'
            : format == 'psd_editable'
            ? 'psd'
            : format;
    await _runDocumentAction((generation) async {
      final destination = await _awaitDocumentPickerResult(
        exportPicker.saveExport(
          extension: extension,
          suggestedName: 'untitled.$extension',
        ),
        generation,
      );
      if (destination != null && _isCurrentDocumentAction(generation)) {
        if (format == 'psd_editable') {
          await session.engine.exportEditablePsd(destination);
        } else {
          await session.engine.exportDocument(
            path: destination,
            format: format,
          );
        }
      }
    });
  }

  Future<void> exportComicPages() async {
    final picker = session.documentPicker;
    if (picker is! ComicExportPicker) return;
    final comicPicker = picker as ComicExportPicker;
    await _runDocumentAction((generation) async {
      final directory = await _awaitDocumentPickerResult(
        comicPicker.chooseComicExportDirectory(),
        generation,
      );
      if (directory == null || !_isCurrentDocumentAction(generation)) return;
      final warnings = await _comicWorkspace.renderWarnings();
      if (!_isCurrentDocumentAction(generation)) return;
      if (warnings == null) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Could not check comic lettering. Export was canceled.',
              ),
            ),
          );
        }
        return;
      }
      var allowRenderWarnings = false;
      if (warnings.isNotEmpty) {
        final dialogHostContext = context;
        if (!dialogHostContext.mounted) return;
        final warningListHeight =
            MediaQuery.sizeOf(
              dialogHostContext,
            ).height.clamp(180.0, 360.0).toDouble();
        final accepted = await showDialog<bool>(
          context: dialogHostContext,
          builder:
              (dialogContext) => AlertDialog(
                title: const Text('Export with lettering warnings?'),
                content: SizedBox(
                  width: 480,
                  height: warningListHeight,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${warnings.length} warning(s): some dialogue may use a fallback font, omit unsupported characters, or be clipped.',
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: ListView.builder(
                          key: const ValueKey('comic-export-warning-list'),
                          itemCount: warnings.length,
                          itemBuilder:
                              (context, index) => Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Text('• ${warnings[index]}'),
                              ),
                        ),
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(false),
                    child: const Text('Cancel export'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.of(dialogContext).pop(true),
                    child: const Text('Export with warnings'),
                  ),
                ],
              ),
        );
        if (accepted != true || !_isCurrentDocumentAction(generation)) return;
        final latestWarnings = await _comicWorkspace.renderWarnings();
        if (!_isCurrentDocumentAction(generation) ||
            latestWarnings == null ||
            !listEquals(latestWarnings, warnings)) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Comic lettering changed. Review the updated export warnings and try again.',
                ),
              ),
            );
          }
          return;
        }
        allowRenderWarnings = true;
      }
      final count = await _comicWorkspace.batchExportPages(
        directory,
        allowRenderWarnings: allowRenderWarnings,
      );
      if (!context.mounted || count == null) return;
      final isWebtoon = _comicWorkspace.snapshot?.template == 2;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isWebtoon
                ? 'Exported $count webtoon SVG segments.'
                : 'Exported $count comic pages as PNG artwork and composited SVG.',
          ),
        ),
      );
    });
  }

  Future<void> exportTimeLapse() async {
    final picker = session.documentPicker;
    if (picker is! DocumentExportPicker) return;
    final exportPicker = picker as DocumentExportPicker;
    await _runDocumentAction((generation) async {
      final destination = await _awaitDocumentPickerResult(
        exportPicker.saveExport(
          extension: 'json',
          suggestedName: 'project-ink-timelapse.json',
        ),
        generation,
      );
      if (destination != null && _isCurrentDocumentAction(generation)) {
        await session.engine.exportTimeLapse(destination);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Time-lapse stroke data exported.')),
          );
        }
      }
    });
  }

  Future<void> importBrush() async {
    final picker = session.documentPicker;
    if (picker is! BrushPicker) return;
    final brushPicker = picker as BrushPicker;
    await _runDocumentAction((generation) async {
      final source = await _awaitDocumentPickerResult(
        brushPicker.openBrush(),
        generation,
      );
      if (source == null || !_isCurrentDocumentAction(generation)) return;
      final inspection = await session.engine.inspectBrushImport(source);
      if (!_isCurrentDocumentAction(generation)) return;
      final report = await session.engine.convertBrushImport(source);
      if (!_isCurrentDocumentAction(generation)) return;
      var installSource = source;
      var installHash = report.sourceSha256;
      var isTipImageRecreation = false;
      final choice = await _confirmBrushImport(
        inspection,
        report,
        canChooseTipImage: picker is BrushTipImagePicker,
      );
      final createFromExtractedAssets =
          choice == _BrushImportChoice.createFromExtractedAssets;
      if (choice == _BrushImportChoice.chooseStarter) {
        final starter = await _chooseBrushStarter();
        if (starter == null || !_isCurrentDocumentAction(generation)) return;
        final duplicateId = await session.engine.duplicateBrush(starter.id);
        if (!_isCurrentDocumentAction(generation)) return;
        final sourceName = source.replaceAll('\\', '/').split('/').last;
        final cleanName = sourceName.replaceFirst(RegExp(r'\.[^.]+$'), '');
        await session.engine.renameBrush(
          brushId: duplicateId,
          name: 'Recreated — $cleanName',
        );
        if (!_isCurrentDocumentAction(generation)) return;
        _brushLibrary.selectWhenAvailable(duplicateId);
        if (mounted) setState(() => _activeBrushId = duplicateId);
        await _loadPhase2Projections();
        if (!_isCurrentDocumentAction(generation)) return;
        _brushLibrary.selectWhenAvailable(duplicateId);
        if (mounted) setState(() => _activeBrushId = duplicateId);
        session.autosave?.markDirty();
        return;
      }
      if (choice == _BrushImportChoice.chooseTipImage) {
        final imagePicker = picker as BrushTipImagePicker;
        final imagePath = await _awaitDocumentPickerResult(
          imagePicker.openBrushTipImage(),
          generation,
        );
        if (imagePath == null || !_isCurrentDocumentAction(generation)) return;
        final imageInspection = await session.engine.inspectBrushImport(
          imagePath,
        );
        if (!_isCurrentDocumentAction(generation)) return;
        if (imageInspection.sourceFormat != 'Image') {
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Choose a PNG, JPEG, or WebP image.')),
          );
          return;
        }
        final imageReport = await session.engine.convertBrushImport(imagePath);
        if (!_isCurrentDocumentAction(generation)) return;
        final imageChoice = await _confirmBrushImport(
          imageInspection,
          imageReport,
          imageTip: true,
        );
        if (imageChoice != _BrushImportChoice.install) return;
        installSource = imagePath;
        installHash = imageReport.sourceSha256;
        isTipImageRecreation = true;
      } else if (choice != _BrushImportChoice.install &&
          !createFromExtractedAssets) {
        return;
      }
      final ids =
          !isTipImageRecreation && report.sourceFormat == 'InkBrushPack'
              ? await session.engine.importBrushPackVerified(
                installSource,
                installHash,
              )
              : !isTipImageRecreation && report.sourceFormat == 'KritaBundle'
              ? await session.engine.importKritaBundleVerified(
                installSource,
                installHash,
              )
              : !isTipImageRecreation && report.sourceFormat == 'PhotoshopAbr'
              ? await session.engine.importPhotoshopAbrVerified(
                installSource,
                installHash,
              )
              : <int>[
                await session.engine.importBrushVerified(
                  installSource,
                  installHash,
                ),
              ];
      if (ids.isNotEmpty) {
        _brushLibrary.selectWhenAvailable(ids.first);
        if (mounted) setState(() => _activeBrushId = ids.first);
      }
      await _loadPhase2Projections();
      if (!_isCurrentDocumentAction(generation)) return;
      if (ids.isNotEmpty) {
        _brushLibrary.selectWhenAvailable(ids.first);
        if (mounted) setState(() => _activeBrushId = ids.first);
      }
    });
  }

  Future<_BrushImportChoice?> _confirmBrushImport(
    BrushImportInspectionView inspection,
    BrushImportReportView report, {
    bool canChooseTipImage = false,
    bool imageTip = false,
  }) => showDialog<_BrushImportChoice>(
    context: context,
    builder: (context) {
      final guided = report.fidelity == 'GuidedRecreation';
      final installable = !guided && report.fidelity != 'Rejected';
      final canCreateFromExtracted = guided && report.resourceCount > 0;
      final canUseAlternatives =
          guided && (canChooseTipImage || report.resourceCount > 0);
      final statusTitle = switch ((imageTip, guided, installable)) {
        (true, _, _) => 'Brush tip image ready',
        (_, true, _) => 'Brush needs a quick setup',
        (_, false, true) => 'Brush is ready to install',
        _ => 'Brush can’t be installed',
      };
      final statusMessage = switch ((imageTip, guided, installable)) {
        (true, _, _) =>
          'This image can be used to make a new brush. It doesn’t include the source brush’s settings.',
        (_, true, _) when report.resourceCount > 0 =>
          'The source brush wasn’t converted or installed. We found ${report.resourceCount} image${report.resourceCount == 1 ? '' : 's'} you can use to create a new Project Ink brush. Its original settings and rendering won’t carry over.',
        (_, true, _) =>
          'The source brush wasn’t converted or installed. Choose a tip image or start with a Project Ink brush.',
        (_, false, true) =>
          'This brush can be installed. Some source settings may be approximated or omitted.',
        _ =>
          'This file can’t be installed as a brush. Review the import details for more information.',
      };
      final mainChoice =
          canCreateFromExtracted
              ? _BrushImportChoice.createFromExtractedAssets
              : guided && canChooseTipImage
              ? _BrushImportChoice.chooseTipImage
              : guided
              ? _BrushImportChoice.chooseStarter
              : _BrushImportChoice.install;
      final mainActionLabel = switch ((imageTip, mainChoice, installable)) {
        (true, _, true) => 'Create brush',
        (_, _BrushImportChoice.createFromExtractedAssets, _) =>
          'Create brush from these images',
        (_, _BrushImportChoice.chooseTipImage, _) => 'Choose a tip image',
        (_, _BrushImportChoice.chooseStarter, _) => 'Choose a starter brush',
        (_, _, true) => 'Install brush',
        _ => 'Unavailable',
      };
      final details = <Widget>[
        Text('Source: ${inspection.sourceFormat}'),
        Text('Compatibility: ${report.fidelity}'),
        Text('Importer: ${report.importerVersion}'),
        if (report.brushCount > 1)
          Text('Brushes in pack: ${report.brushCount}'),
        if (report.resourceCount > 0)
          Text('Images found: ${report.resourceCount}'),
        if (report.previewWidth > 0)
          Text(
            'Preview size: ${report.previewWidth} × ${report.previewHeight}',
          ),
        if (report.mappings.isNotEmpty) ...[
          const SizedBox(height: 8),
          const Text('Approximated settings'),
          ...report.mappings.map((value) => Text('• $value')),
        ],
        if (report.omitted.isNotEmpty) ...[
          const SizedBox(height: 8),
          const Text('Not carried over'),
          ...report.omitted.map((value) => Text('• $value')),
        ],
        if (report.warnings.isNotEmpty) ...[
          const SizedBox(height: 8),
          const Text('Notes'),
          ...report.warnings.map((value) => Text('• $value')),
        ],
      ];
      return AlertDialog(
        title: Text(statusTitle),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(statusMessage),
                if (details.isNotEmpty)
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: const EdgeInsets.only(bottom: 8),
                    title: const Text('Import details'),
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: details,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          if (canUseAlternatives)
            PopupMenuButton<_BrushImportChoice>(
              tooltip: 'Other options',
              onSelected: (choice) => Navigator.of(context).pop(choice),
              itemBuilder:
                  (context) => [
                    if (canChooseTipImage && canCreateFromExtracted)
                      const PopupMenuItem(
                        value: _BrushImportChoice.chooseTipImage,
                        child: Text('Choose a different tip image'),
                      ),
                    const PopupMenuItem(
                      value: _BrushImportChoice.chooseStarter,
                      child: Text('Start from a Project Ink brush'),
                    ),
                  ],
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.more_horiz),
                  SizedBox(width: 4),
                  Text('More options'),
                ],
              ),
            ),
          if (installable || guided)
            FilledButton(
              onPressed: () => Navigator.of(context).pop(mainChoice),
              child: Text(mainActionLabel),
            ),
        ],
      );
    },
  );

  Future<BrushPresetView?> _chooseBrushStarter() {
    const choices = <(String, String, String)>[
      (
        'Opaque Round',
        'Round tip',
        'Closest to a basic Circle or round shape.',
      ),
      (
        'Soft Airbrush',
        'Soft round',
        'Soft edge with an airbrush-like falloff.',
      ),
      ('Flat Paint', 'Flat tip', 'A broad, flat mark for material-tip styles.'),
      ('Dry Ink', 'Dry textured', 'A broken, dry mark for textured styles.'),
    ];
    final byName = <String, BrushPresetView>{
      for (final preset in _brushLibrary.presets) preset.name: preset,
    };
    final available = choices
        .where((choice) => byName.containsKey(choice.$1))
        .toList(growable: false);
    return showDialog<BrushPresetView>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Choose a starter brush'),
            content: SizedBox(
              width: 440,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'These are Project Ink brushes. Pick the closest starting style, then tune it in Brush Studio.',
                    ),
                    const SizedBox(height: 12),
                    ...available.map(
                      (choice) => ListTile(
                        leading: const Icon(Icons.circle_outlined),
                        title: Text(choice.$2),
                        subtitle: Text(choice.$3),
                        onTap:
                            () => Navigator.of(context).pop(byName[choice.$1]),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
            ],
          ),
    );
  }

  Future<void> exportBrush() async {
    final picker = session.documentPicker;
    final selected = _brushLibrary.selected;
    if (picker is! BrushPicker || selected == null) return;
    final brushPicker = picker as BrushPicker;
    await _runDocumentAction((generation) async {
      final destination = await _awaitDocumentPickerResult(
        brushPicker.saveBrush(suggestedName: '${selected.name}.inkbrush'),
        generation,
      );
      if (destination != null && _isCurrentDocumentAction(generation)) {
        await session.engine.exportBrush(
          brushId: selected.id,
          path: destination,
        );
      }
    });
  }

  bool isCurrentDocumentAction(int generation) =>
      mounted && generation == _documentActionGeneration;

  Future<T?> _awaitDocumentPickerResult<T>(
    Future<T?> pending,
    int generation,
  ) async {
    try {
      final value = await pending.timeout(session.documentPickerTimeout);
      return isCurrentDocumentAction(generation) ? value : null;
    } on TimeoutException {
      if (!context.mounted) return null;
      if (isCurrentDocumentAction(generation)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'The file dialog did not respond. You can try again.',
            ),
          ),
        );
      }
      return null;
    }
  }

  Future<void> _runDocumentAction(
    Future<void> Function(int generation) action, {
    String? errorMessage,
    Future<void> Function()? retry,
  }) async {
    if (_documentActionRunning || !mounted) return;
    final generation = ++_documentActionGeneration;
    setState(() => _documentActionRunning = true);
    try {
      await action(generation);
    } catch (error) {
      if (!context.mounted) return;
      final message =
          errorMessage ??
          (error is DocumentOpenException
              ? error.message
              : 'Document action failed: $error');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          action:
              retry == null
                  ? null
                  : SnackBarAction(
                    label: 'Retry',
                    onPressed: () => unawaited(retry()),
                  ),
        ),
      );
    } finally {
      if (_isCurrentDocumentAction(generation)) {
        setState(() => _documentActionRunning = false);
      }
    }
  }
}

enum DocumentReplacementChoice { clean, save, discard, cancel }

enum _PsdImportChoice { editable, flattened }

class _ProjectOpenChoice {
  const _ProjectOpenChoice.open(this.path) : browse = false;
  const _ProjectOpenChoice.browse() : path = null, browse = true;

  final String? path;
  final bool browse;
}

class _OpenRecentProjectsDialog extends StatefulWidget {
  const _OpenRecentProjectsDialog({
    required this.entries,
    required this.onRemove,
  });

  final List<RecentProjectEntry> entries;
  final Future<void> Function(String path)? onRemove;

  @override
  State<_OpenRecentProjectsDialog> createState() =>
      _OpenRecentProjectsDialogState();
}

class _OpenRecentProjectsDialogState extends State<_OpenRecentProjectsDialog> {
  late final List<RecentProjectEntry> _entries = List.of(widget.entries);

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    return AlertDialog(
      title: const Text('Open project'),
      content: SizedBox(
        width: 520,
        height: height < 560 ? height * 0.38 : 360,
        child:
            _entries.isEmpty
                ? const Center(child: Text('No recent projects'))
                : ListView.separated(
                  itemCount: _entries.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final entry = _entries[index];
                    final description =
                        entry.available
                            ? entry.path
                            : 'Unavailable · ${entry.path}';
                    final lastUsed = entry.lastUsed;
                    return ListTile(
                      leading: Icon(
                        entry.available
                            ? Icons.folder_outlined
                            : Icons.folder_off_outlined,
                      ),
                      title: Text(
                        entry.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        [
                          description,
                          if (lastUsed != null)
                            'Last used ${MaterialLocalizations.of(context).formatShortDate(lastUsed)}',
                        ].join('\n'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      enabled: entry.available,
                      onTap:
                          entry.available
                              ? () => Navigator.of(
                                context,
                              ).pop(_ProjectOpenChoice.open(entry.path))
                              : null,
                      trailing: IconButton(
                        tooltip: 'Remove ${entry.name} from recents',
                        onPressed: widget.onRemove == null
                            ? null
                            : () async {
                          try {
                            await widget.onRemove!.call(entry.path);
                          } catch (_) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Recent projects could not be updated.',
                                  ),
                                ),
                              );
                            }
                            return;
                          }
                          if (!mounted) return;
                          setState(() => _entries.removeAt(index));
                        },
                        icon: const Icon(Icons.close),
                      ),
                    );
                  },
                ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.tonalIcon(
          onPressed:
              () =>
                  Navigator.of(context).pop(const _ProjectOpenChoice.browse()),
          icon: const Icon(Icons.folder_open_outlined),
          label: const Text('Browse…'),
        ),
      ],
    );
  }
}

enum _BrushImportChoice {
  install,
  chooseTipImage,
  chooseStarter,
  createFromExtractedAssets,
}

class _PsdImportConfirmationDialog extends StatelessWidget {
  const _PsdImportConfirmationDialog({
    required this.inspection,
    required this.onCancel,
    required this.onImportEditable,
    required this.onImportFlattened,
  });

  final PsdImportInspectionView inspection;
  final VoidCallback onCancel;
  final VoidCallback? onImportEditable;
  final VoidCallback? onImportFlattened;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Import PSD'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${inspection.widthPx} × ${inspection.heightPx} px, ${inspection.depth}-bit, ${inspection.layerCount} logical layer node(s) (groups included).',
            ),
            const SizedBox(height: 12),
            const Text(
              'Editable import creates a new unsaved Ink document from supported PSD layers. Flattened import creates one raster layer from the merged image. The source PSD is not changed.',
            ),
            if (inspection.conversionNotices.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('Import conversions'),
              for (final item in inspection.conversionNotices)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('• $item'),
                ),
            ],
            if (inspection.incompatibilities.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('Editable import limitations'),
              for (final item in inspection.incompatibilities.take(12))
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('• $item'),
                ),
            ],
            if (!inspection.flattenedImportAvailable) ...[
              const SizedBox(height: 12),
              const Text('Flattened import is unavailable for this file.'),
              for (final item in inspection.flattenedImportIssues.take(12))
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('• $item'),
                ),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: onCancel, child: const Text('Cancel')),
      if (onImportEditable != null)
        FilledButton.tonal(
          onPressed: onImportEditable,
          child: const Text('Import editable layers'),
        ),
      if (onImportFlattened != null)
        FilledButton(
          onPressed: onImportFlattened,
          child: const Text('Import flattened image'),
        ),
    ],
  );
}
