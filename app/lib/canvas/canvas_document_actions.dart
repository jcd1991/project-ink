import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../app/editor_action.dart';
import '../bridge/engine_api.dart';
import '../comics/comic_workspace.dart';
import '../documents/document_picker.dart';
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
      final path = await _awaitDocumentPickerResult(
        picker.openProject(),
        generation,
      );
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
        if (!await _confirmDocumentReplacement(generation)) return;
        await _runWithDocumentReplacementBarrier(() => onOpen(path));
      }
    });
  }

  Future<void> saveProject() async {
    final picker = session.documentPicker;
    if (picker == null) return;
    await _runDocumentAction((generation) async {
      await _saveProjectToSelectedDestination(
        picker,
        saveAs: false,
        generation: generation,
      );
    });
  }

  Future<void> saveProjectAs() async {
    final picker = session.documentPicker;
    if (picker == null) return;
    await _runDocumentAction((generation) async {
      await _saveProjectToSelectedDestination(
        picker,
        saveAs: true,
        generation: generation,
      );
    });
  }

  Future<bool> _saveProjectToSelectedDestination(
    DocumentPicker picker, {
    required bool saveAs,
    required int generation,
  }) async {
    var path = saveAs ? null : session.activeDocumentPath;
    if (path == null) {
      final suggestedName = await _suggestedProjectName(picker);
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

  Future<String?> _suggestedProjectName(DocumentPicker picker) async {
    final providerState =
        picker is ProviderDocumentState
            ? (picker as ProviderDocumentState).hasActiveProviderProject
            : false;
    if (providerState) return 'untitled.inkproj';

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
    final extension = format == 'jpeg' ? 'jpg' : format;
    await _runDocumentAction((generation) async {
      final destination = await _awaitDocumentPickerResult(
        exportPicker.saveExport(
          extension: extension,
          suggestedName: 'untitled.$extension',
        ),
        generation,
      );
      if (destination != null && _isCurrentDocumentAction(generation)) {
        await session.engine.exportDocument(path: destination, format: format);
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
      final count = await _comicWorkspace.batchExportPages(directory);
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
    Future<void> Function(int generation) action,
  ) async {
    if (_documentActionRunning || !mounted) return;
    final generation = ++_documentActionGeneration;
    setState(() => _documentActionRunning = true);
    try {
      await action(generation);
    } catch (error) {
      if (!context.mounted) return;
      final message =
          error is DocumentOpenException
              ? error.message
              : 'Document action failed: $error';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (_isCurrentDocumentAction(generation)) {
        setState(() => _documentActionRunning = false);
      }
    }
  }
}

enum DocumentReplacementChoice { clean, save, discard, cancel }

enum _BrushImportChoice {
  install,
  chooseTipImage,
  chooseStarter,
  createFromExtractedAssets,
}
