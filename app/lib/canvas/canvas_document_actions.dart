part of 'canvas_screen.dart';

/// Owns file, project, import, export, and document-picker workflows.
mixin _CanvasDocumentActions on State<CanvasScreen> {
  set _activeBrushId(int value);

  BrushLibraryModel get _brushLibrary;
  ComicWorkspaceController get _comicWorkspace;

  int get _documentActionGeneration;
  set _documentActionGeneration(int value);
  bool get _documentActionRunning;
  set _documentActionRunning(bool value);

  Future<void> _loadPhase2Projections();

  Future<void> _newDocument() async {
    final onNewDocument = widget.onNewDocument;
    if (onNewDocument == null) return;
    await _runDocumentAction((generation) async {
      final settings = await showDialog<(int, int, double)>(
        context: context,
        builder: (_) => const _NewDocumentDialog(),
      );
      if (settings == null || !_isCurrentDocumentAction(generation)) return;
      await onNewDocument(
        widthPx: settings.$1,
        heightPx: settings.$2,
        dpi: settings.$3,
      );
    });
  }

  Future<void> _openProject() async {
    final picker = widget.documentPicker;
    final onOpen = widget.onOpenDocument;
    if (picker == null || onOpen == null) return;
    await _runDocumentAction((generation) async {
      final path = await _awaitDocumentPickerResult(
        picker.openProject(),
        generation,
      );
      if (path != null && _isCurrentDocumentAction(generation)) {
        final isStudioProject =
            Directory(path).existsSync() &&
            File('$path${Platform.pathSeparator}comic.json').existsSync();
        if (isStudioProject) {
          await widget.onBeforeOpenStudioProject?.call();
          final opened = await _comicWorkspace.openProjectFromPath(path);
          if (!opened) {
            // Rust bridge errors are opaque Dart wrappers on some failures;
            // never expose their implementation-only `toString()` to users.
            throw const DocumentOpenException(_comicProjectOpenFailureMessage);
          }
          await widget.onStudioProjectOpened?.call(path);
        } else {
          await onOpen(path);
        }
      }
    });
  }

  Future<void> _importPsd() async {
    final picker = widget.documentPicker;
    final onOpen = widget.onOpenDocument;
    if (picker is! PsdImportPicker || onOpen == null) return;
    await _runDocumentAction((generation) async {
      final path = await _awaitDocumentPickerResult(
        (picker as PsdImportPicker).openPsd(),
        generation,
      );
      if (path != null && _isCurrentDocumentAction(generation)) {
        await onOpen(path);
      }
    });
  }

  Future<void> _saveProject() async {
    final picker = widget.documentPicker;
    if (picker == null) return;
    await _runDocumentAction((generation) async {
      await _saveProjectToSelectedDestination(
        picker,
        saveAs: false,
        generation: generation,
      );
    });
  }

  Future<void> _saveProjectAs() async {
    final picker = widget.documentPicker;
    if (picker == null) return;
    await _runDocumentAction(
      (generation) => _saveProjectToSelectedDestination(
        picker,
        saveAs: true,
        generation: generation,
      ),
    );
  }

  Future<void> _saveProjectToSelectedDestination(
    DocumentPicker picker, {
    required bool saveAs,
    required int generation,
  }) async {
    var path = saveAs ? null : widget.activeDocumentPath;
    if (path == null) {
      final suggestedName = await _suggestedProjectName(picker);
      if (suggestedName == null) return;
      path = await _awaitDocumentPickerResult(
        picker.saveProject(suggestedName: suggestedName),
        generation,
      );
    }
    if (path == null || !_isCurrentDocumentAction(generation)) return;
    // Drain any debounced checkpoint before copying a staged provider
    // project. This prevents native write-back from racing a Rust save.
    await widget.autosave?.flush();
    await widget.engine.saveAs(path);
    if (picker case final DocumentWriteback writeback) {
      await writeback.commitProject(path);
    }
    await widget.onDocumentSaved?.call(path);
  }

  Future<String?> _suggestedProjectName(DocumentPicker picker) async {
    final providerState =
        picker is ProviderDocumentState
            ? (picker as ProviderDocumentState).hasActiveProviderProject
            : false;
    if (providerState) return 'untitled.inkproj';

    return showDialog<String>(
      context: context,
      builder: (_) => const _ProjectNameDialog(),
    );
  }

  Future<void> _exportPng() async {
    final picker = widget.documentPicker;
    if (picker == null) return;
    await _runDocumentAction((generation) async {
      final path = await _awaitDocumentPickerResult(
        picker.exportPng(),
        generation,
      );
      if (path != null && _isCurrentDocumentAction(generation)) {
        await widget.engine.exportPng(path);
        if (picker case final DocumentPngWriteback writeback) {
          await writeback.commitPng(path);
        }
      }
    });
  }

  Future<void> _exportDocumentMenu() async {
    final picker = widget.documentPicker;
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
      if (mounted) {
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
        await widget.engine.exportDocument(path: destination, format: format);
      }
    });
  }

  Future<void> _exportComicPages() async {
    final picker = widget.documentPicker;
    if (picker is! ComicExportPicker) return;
    final comicPicker = picker as ComicExportPicker;
    await _runDocumentAction((generation) async {
      final directory = await _awaitDocumentPickerResult(
        comicPicker.chooseComicExportDirectory(),
        generation,
      );
      if (directory == null || !_isCurrentDocumentAction(generation)) return;
      final count = await _comicWorkspace.batchExportPages(directory);
      if (!mounted || count == null) return;
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

  Future<void> _exportTimeLapse() async {
    final picker = widget.documentPicker;
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
        await widget.engine.exportTimeLapse(destination);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Time-lapse stroke data exported.')),
          );
        }
      }
    });
  }

  Future<void> _importBrush() async {
    final picker = widget.documentPicker;
    if (picker is! BrushPicker) return;
    final brushPicker = picker as BrushPicker;
    await _runDocumentAction((generation) async {
      final source = await _awaitDocumentPickerResult(
        brushPicker.openBrush(),
        generation,
      );
      if (source == null || !_isCurrentDocumentAction(generation)) return;
      final inspection = await widget.engine.inspectBrushImport(source);
      if (!_isCurrentDocumentAction(generation)) return;
      final report = await widget.engine.convertBrushImport(source);
      if (!_isCurrentDocumentAction(generation)) return;
      final install = await _confirmBrushImport(inspection, report);
      if (install != true) return;
      final ids =
          report.sourceFormat == 'InkBrushPack'
              ? await widget.engine.importBrushPackVerified(
                source,
                report.sourceSha256,
              )
              : report.sourceFormat == 'KritaBundle'
              ? await widget.engine.importKritaBundleVerified(
                source,
                report.sourceSha256,
              )
              : <int>[
                await widget.engine.importBrushVerified(
                  source,
                  report.sourceSha256,
                ),
              ];
      await _loadPhase2Projections();
      if (ids.isNotEmpty) {
        _brushLibrary.select(ids.first);
        if (mounted) setState(() => _activeBrushId = ids.first);
      }
    });
  }

  Future<bool?> _confirmBrushImport(
    BrushImportInspectionView inspection,
    BrushImportReportView report,
  ) => showDialog<bool>(
    context: context,
    builder: (context) {
      final installable =
          report.fidelity != 'GuidedRecreation' &&
          report.fidelity != 'Rejected';
      final sections = <Widget>[
        Text('Source: ${inspection.sourceFormat}'),
        Text('Fidelity: ${report.fidelity}'),
        Text('Importer: ${report.importerVersion}'),
        if (report.brushCount > 1)
          Text('Brushes in pack: ${report.brushCount}'),
        if (report.resourceCount > 0)
          Text('Resources staged: ${report.resourceCount}'),
        if (report.previewWidth > 0)
          Text('Preview: ${report.previewWidth} × ${report.previewHeight}'),
        if (report.mappings.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text('Mapped settings'),
          ...report.mappings.map((value) => Text('• $value')),
        ],
        if (report.omitted.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text('Omitted settings'),
          ...report.omitted.map((value) => Text('• $value')),
        ],
        if (report.warnings.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text('Warnings'),
          ...report.warnings.map((value) => Text('• $value')),
        ],
        if (!installable) ...[
          const SizedBox(height: 12),
          const Text(
            'This source is guided recreation only. Supply a tip or grain image and create a new Project Ink brush.',
          ),
        ],
      ];
      return AlertDialog(
        title: const Text('Brush compatibility report'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(child: Column(children: sections)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed:
                installable ? () => Navigator.of(context).pop(true) : null,
            child: const Text('Install converted brush'),
          ),
        ],
      );
    },
  );

  Future<void> _exportBrush() async {
    final picker = widget.documentPicker;
    final selected = _brushLibrary.selected;
    if (picker is! BrushPicker || selected == null) return;
    final brushPicker = picker as BrushPicker;
    await _runDocumentAction((generation) async {
      final destination = await _awaitDocumentPickerResult(
        brushPicker.saveBrush(suggestedName: '${selected.name}.inkbrush'),
        generation,
      );
      if (destination != null && _isCurrentDocumentAction(generation)) {
        await widget.engine.exportBrush(
          brushId: selected.id,
          path: destination,
        );
      }
    });
  }

  bool _isCurrentDocumentAction(int generation) =>
      mounted && generation == _documentActionGeneration;

  Future<T?> _awaitDocumentPickerResult<T>(
    Future<T?> pending,
    int generation,
  ) async {
    try {
      final value = await pending.timeout(widget.documentPickerTimeout);
      return _isCurrentDocumentAction(generation) ? value : null;
    } on TimeoutException {
      if (!mounted) return null;
      if (_isCurrentDocumentAction(generation)) {
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
      if (!mounted) return;
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
