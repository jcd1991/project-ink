import 'package:flutter/material.dart';

import '../bridge/generated/api.dart' as rust;
import '../comics/comic_workspace.dart';
import '../tools/brush_library.dart';
import '../tools/brush_library_panel.dart';
import '../tools/illustration_tools.dart';
import 'canvas_brush_actions.dart';

/// Adapts the screen's current tool and actions to the reusable tool palette.
class CanvasToolPaletteContent extends StatelessWidget {
  const CanvasToolPaletteContent({
    super.key,
    required this.selected,
    required this.onSelected,
    required this.onClearSelection,
    required this.onTransformPreset,
  });

  final IllustrationTool selected;
  final ValueChanged<IllustrationTool> onSelected;
  final VoidCallback onClearSelection;
  final ValueChanged<TransformPreset> onTransformPreset;

  @override
  Widget build(BuildContext context) => IllustrationToolPalette(
    selected: selected,
    onSelected: onSelected,
    onClearSelection: onClearSelection,
    onTransformPreset: onTransformPreset,
  );
}

/// Presents brush editing through the existing brush action owner.
class CanvasBrushPaletteContent extends StatelessWidget {
  const CanvasBrushPaletteContent({
    super.key,
    required this.library,
    required this.actions,
    this.onImport,
    this.onExport,
  });

  final BrushLibraryModel library;
  final CanvasBrushActions actions;
  final Future<void> Function()? onImport;
  final Future<void> Function()? onExport;

  @override
  Widget build(BuildContext context) => BrushLibraryPanel(
    library: library,
    renderPreview: actions.renderBrushPreview,
    onSelected: actions.activateBrush,
    onChanged: actions.updateBrushDraft,
    onSizeChangeEnd: actions.persistBrushSize,
    onImport: onImport,
    onExport: onExport,
    onDuplicate: actions.duplicateBrush,
    onRename: actions.renameBrush,
    hasUncommittedChanges: actions.hasUncommittedChanges(library.selected?.id),
    onCommitEdit: actions.commitSelectedBrushDraft,
    onCancelEdit: actions.cancelBrushDraft,
  );
}

/// Displays the comic workspace with host-owned close and export actions.
class CanvasComicPaletteContent extends StatelessWidget {
  const CanvasComicPaletteContent({
    super.key,
    required this.controller,
    required this.onDrawInsidePanel,
    required this.onClose,
    this.onBatchExport,
  });

  final ComicWorkspaceController controller;
  final Future<void> Function(int pageIndex, rust.ComicPanelPreviewView panel)
  onDrawInsidePanel;
  final VoidCallback onClose;
  final Future<void> Function()? onBatchExport;

  @override
  Widget build(BuildContext context) => ComicWorkspace(
    controller: controller,
    onDrawInsidePanel: onDrawInsidePanel,
    onClose: onClose,
    onBatchExport: onBatchExport,
  );
}
