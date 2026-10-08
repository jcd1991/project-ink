/// Shared command identifiers used by menus, shortcuts, gestures, and native
/// stylus buttons.  UI surfaces may render these differently, but they must
/// dispatch the same ID so actions never drift between platforms.
enum EditorActionId {
  newDocument,
  openProject,
  importPsd,
  saveProject,
  saveProjectAs,
  exportPng,
  undo,
  redo,
  clearSelection,
  invertSelection,
  growSelection,
  shrinkSelection,
  toggleEraser,
  fitCanvas,
  toggleInterface,
  showTools,
  showBrushes,
  showLayers,
  showToolProperties,
  showMaterials,
  showComics,
  showHistory,
  showQuickAccess,
  showColorPicker,
  eyedropper,
  quickMenu,
  commandSearch,
  mirrorCanvas,
  resetRotation,
  actualPixels,
  swapColors,
  resetColors,
}

extension EditorActionLabels on EditorActionId {
  String get label => switch (this) {
    EditorActionId.newDocument => 'New canvas',
    EditorActionId.openProject => 'Open project',
    EditorActionId.importPsd => 'Import PSD',
    EditorActionId.saveProject => 'Save project',
    EditorActionId.saveProjectAs => 'Save project as',
    EditorActionId.exportPng => 'Export PNG',
    EditorActionId.undo => 'Undo',
    EditorActionId.redo => 'Redo',
    EditorActionId.clearSelection => 'Deselect',
    EditorActionId.invertSelection => 'Invert selection',
    EditorActionId.growSelection => 'Grow selection by 1 px',
    EditorActionId.shrinkSelection => 'Shrink selection by 1 px',
    EditorActionId.toggleEraser => 'Toggle eraser',
    EditorActionId.fitCanvas => 'Fit canvas',
    EditorActionId.toggleInterface => 'Hide or show interface',
    EditorActionId.showTools => 'Tools',
    EditorActionId.showBrushes => 'Brushes',
    EditorActionId.showLayers => 'Layers',
    EditorActionId.showToolProperties => 'Tool properties',
    EditorActionId.showMaterials => 'Materials',
    EditorActionId.showComics => 'Comics',
    EditorActionId.showHistory => 'History',
    EditorActionId.showQuickAccess => 'Quick Access',
    EditorActionId.showColorPicker => 'Color',
    EditorActionId.eyedropper => 'Eyedropper',
    EditorActionId.quickMenu => 'Quick menu',
    EditorActionId.commandSearch => 'Search commands',
    EditorActionId.mirrorCanvas => 'Mirror canvas',
    EditorActionId.resetRotation => 'Reset canvas rotation',
    EditorActionId.actualPixels => 'Actual pixels',
    EditorActionId.swapColors => 'Swap main and sub colors',
    EditorActionId.resetColors => 'Reset colors to black and white',
  };
}

extension EditorActionMetadata on EditorActionId {
  String get category => switch (this) {
    EditorActionId.openProject ||
    EditorActionId.importPsd ||
    EditorActionId.newDocument ||
    EditorActionId.saveProject ||
    EditorActionId.saveProjectAs ||
    EditorActionId.exportPng => 'File',
    EditorActionId.undo ||
    EditorActionId.redo ||
    EditorActionId.resetColors ||
    EditorActionId.swapColors => 'Edit',
    EditorActionId.clearSelection ||
    EditorActionId.invertSelection ||
    EditorActionId.growSelection ||
    EditorActionId.shrinkSelection => 'Select',
    EditorActionId.fitCanvas ||
    EditorActionId.toggleInterface ||
    EditorActionId.mirrorCanvas ||
    EditorActionId.resetRotation ||
    EditorActionId.actualPixels => 'View',
    EditorActionId.showTools ||
    EditorActionId.showBrushes ||
    EditorActionId.showToolProperties ||
    EditorActionId.toggleEraser ||
    EditorActionId.eyedropper => 'Tool',
    EditorActionId.showLayers => 'Layer',
    EditorActionId.showComics ||
    EditorActionId.showMaterials ||
    EditorActionId.showHistory ||
    EditorActionId.showQuickAccess => 'Window',
    EditorActionId.showColorPicker => 'Color',
    EditorActionId.commandSearch => 'Help',
    EditorActionId.quickMenu => 'Quick Access',
  };

  String? get shortcut => switch (this) {
    EditorActionId.newDocument => 'Ctrl/⌘+N',
    EditorActionId.openProject => 'Ctrl/⌘+O',
    EditorActionId.saveProject => 'Ctrl/⌘+S',
    EditorActionId.saveProjectAs => 'Ctrl/⌘+Shift+S',
    EditorActionId.undo => 'Ctrl/⌘+Z',
    EditorActionId.redo => 'Ctrl/⌘+Shift+Z',
    EditorActionId.showBrushes => 'B',
    EditorActionId.showColorPicker => 'C',
    EditorActionId.eyedropper => 'I',
    EditorActionId.toggleEraser => 'E',
    EditorActionId.commandSearch => 'Ctrl/⌘+K, Ctrl+Enter',
    EditorActionId.swapColors => 'X',
    EditorActionId.resetColors => 'D',
    _ => null,
  };

  /// Palette opened or affected by this command, when applicable.
  String? get paletteName => switch (this) {
    EditorActionId.showTools => 'Tool groups',
    EditorActionId.showBrushes => 'Brush presets',
    EditorActionId.showLayers => 'Layers',
    EditorActionId.showToolProperties => 'Tool properties',
    EditorActionId.showMaterials => 'Materials',
    EditorActionId.showComics => 'Comics',
    EditorActionId.showHistory => 'History',
    EditorActionId.showQuickAccess ||
    EditorActionId.quickMenu => 'Quick Access',
    EditorActionId.showColorPicker => 'Color',
    _ => null,
  };

  /// Drawing tool associated with a command, when applicable.
  String? get toolName => switch (this) {
    EditorActionId.toggleEraser => 'Eraser',
    EditorActionId.eyedropper => 'Eyedropper',
    EditorActionId.showTools => 'Tool groups',
    EditorActionId.showBrushes => 'Brush',
    _ => null,
  };

  /// Synonyms are local, stable search metadata rather than UI-only labels.
  List<String> get keywords => switch (this) {
    EditorActionId.newDocument => ['new', 'create', 'blank', 'canvas'],
    EditorActionId.openProject => ['open', 'document', 'file browser'],
    EditorActionId.importPsd => ['photoshop', 'psd', 'import image'],
    EditorActionId.saveProject => ['save', 'save as', 'document'],
    EditorActionId.saveProjectAs => ['save as', 'copy', 'document'],
    EditorActionId.exportPng => ['export', 'image', 'render'],
    EditorActionId.undo => ['back', 'revert', 'history'],
    EditorActionId.redo => ['forward', 'repeat', 'history'],
    EditorActionId.clearSelection => ['deselect', 'remove selection'],
    EditorActionId.invertSelection => ['selection inverse'],
    EditorActionId.growSelection => ['expand selection', 'selection border'],
    EditorActionId.shrinkSelection => ['contract selection'],
    EditorActionId.toggleEraser => [
      'erase',
      'eraser tool',
      'transparent color',
    ],
    EditorActionId.fitCanvas => ['zoom to fit', 'fit page', 'zoom'],
    EditorActionId.toggleInterface => ['hide ui', 'fullscreen', 'show ui'],
    EditorActionId.showTools => ['tool palette', 'tools palette'],
    EditorActionId.showBrushes => ['brush library', 'brush palette'],
    EditorActionId.showLayers => ['layer palette', 'layer panel'],
    EditorActionId.showToolProperties => ['properties palette', 'inspector'],
    EditorActionId.showMaterials => ['materials palette', 'assets'],
    EditorActionId.showComics => ['comic workspace', 'pages', 'panels'],
    EditorActionId.showHistory => ['history palette', 'undo history'],
    EditorActionId.showQuickAccess => [
      'quick menu',
      'favorites',
      'radial menu',
    ],
    EditorActionId.showColorPicker => [
      'color wheel',
      'color palette',
      'swatches',
    ],
    EditorActionId.eyedropper => [
      'sample color',
      'color sampler',
      'pick color',
    ],
    EditorActionId.quickMenu => ['radial menu', 'quick access menu'],
    EditorActionId.commandSearch => ['find command', 'action search'],
    EditorActionId.mirrorCanvas => ['flip canvas', 'horizontal flip'],
    EditorActionId.resetRotation => ['straighten canvas', 'zero rotation'],
    EditorActionId.actualPixels => ['100 percent', 'pixel size', 'zoom 100'],
    EditorActionId.swapColors => ['swap colors', 'foreground background'],
    EditorActionId.resetColors => ['default colors', 'black white'],
  };

  String get searchCorpus =>
      <String?>[
        label,
        category,
        shortcut,
        paletteName,
        toolName,
        ...keywords,
      ].whereType<String>().join(' ').toLowerCase();
}

/// Searches every implemented command by its label, category, shortcut,
/// palette, tool, or synonym. All query words must match for predictable
/// multi-word searches such as "brush palette".
List<EditorActionId> searchEditorActions(String query) {
  final terms = query.trim().toLowerCase().split(RegExp(r'\s+'))
    ..removeWhere((term) => term.isEmpty);
  if (terms.isEmpty) return EditorActionId.values;
  return EditorActionId.values
      .where((action) => terms.every(action.searchCorpus.contains))
      .toList(growable: false);
}

typedef EditorActionHandler = void Function(EditorActionId action);

/// Returns whether an editor action is temporarily unavailable in the UI.
/// The Rust bridge remains responsible for validating document mutations.
bool isEditorActionDisabled({
  required EditorActionId action,
  required bool documentActionsEnabled,
  required bool documentActionRunning,
}) =>
    (documentActionRunning && action == EditorActionId.newDocument) ||
    (!documentActionsEnabled &&
        const {
          EditorActionId.openProject,
          EditorActionId.importPsd,
          EditorActionId.saveProject,
          EditorActionId.saveProjectAs,
          EditorActionId.exportPng,
        }.contains(action));

class EditorCommandRegistry {
  EditorCommandRegistry(this._handler);

  final EditorActionHandler _handler;

  void dispatch(EditorActionId action) => _handler(action);
}
