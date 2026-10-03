import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app/editor_action.dart';
import '../app/workspace_preferences.dart';
import '../bridge/engine_api.dart';
import '../comics/comic_workspace.dart';
import '../tools/brush_library.dart';
import 'canvas_color_palette_panel.dart';
import 'canvas_history_panel.dart';
import 'canvas_quick_access_panel.dart';
import 'workspace_panels.dart';

/// Values required to select and construct one workspace dock palette.
class CanvasWorkspacePaletteSnapshot {
  const CanvasWorkspacePaletteSnapshot({
    required this.tab,
    required this.buildTools,
    required this.buildBrushes,
    required this.buildComics,
    required this.buildLayers,
    required this.brushLibrary,
    required this.activeToolName,
    required this.eraserActive,
    required this.activeLayerName,
    required this.mainColor,
    required this.subColor,
    required this.recentColors,
    required this.transparentColorActive,
    required this.comicWorkspace,
    required this.quickAccessSets,
    required this.activeQuickAccessSetId,
    required this.engine,
    required this.renderRevision,
  });

  final String tab;
  final Widget Function() buildTools;
  final Widget Function() buildBrushes;
  final Widget Function() buildComics;
  final Widget Function() buildLayers;
  final BrushLibraryModel brushLibrary;
  final String activeToolName;
  final bool eraserActive;
  final String activeLayerName;
  final Color mainColor;
  final Color subColor;
  final List<String> recentColors;
  final bool transparentColorActive;
  final ComicWorkspaceController comicWorkspace;
  final List<QuickAccessSet> quickAccessSets;
  final String activeQuickAccessSetId;
  final EngineApi engine;
  final int renderRevision;
}

/// Effects delegated by workspace palettes to their existing owners.
class CanvasWorkspacePaletteActions {
  const CanvasWorkspacePaletteActions({
    required this.onBrushChanged,
    required this.onToggleEraser,
    required this.onBrushColor,
    required this.onOpenLayers,
    required this.onChooseColor,
    required this.onChooseSubColor,
    required this.onSelectRecentColor,
    required this.onSwapColors,
    required this.onResetColors,
    required this.onTransparentColor,
    required this.onOpenComics,
    required this.onQuickAccessAction,
    required this.onQuickAccessChanged,
    required this.onNavigateHistory,
  });

  final void Function(BrushPresetView) onBrushChanged;
  final VoidCallback onToggleEraser;
  final void Function({bool editSubColor}) onBrushColor;
  final VoidCallback onOpenLayers;
  final VoidCallback onChooseColor;
  final VoidCallback onChooseSubColor;
  final ValueChanged<Color> onSelectRecentColor;
  final VoidCallback onSwapColors;
  final VoidCallback onResetColors;
  final VoidCallback onTransparentColor;
  final VoidCallback onOpenComics;
  final ValueChanged<EditorActionId> onQuickAccessAction;
  final void Function(List<QuickAccessSet>, String) onQuickAccessChanged;
  final Future<void> Function(int) onNavigateHistory;
}

/// Routes a workspace tab to its presentation using explicit values/actions.
class CanvasWorkspacePalette extends StatelessWidget {
  const CanvasWorkspacePalette({
    super.key,
    required this.snapshot,
    required this.actions,
  });

  final CanvasWorkspacePaletteSnapshot snapshot;
  final CanvasWorkspacePaletteActions actions;

  @override
  Widget build(BuildContext context) {
    final state = snapshot;
    final callbacks = actions;
    return switch (state.tab) {
      'tools' => state.buildTools(),
      'brushes' => state.buildBrushes(),
      'properties' => InkToolPropertiesPanel(
        library: state.brushLibrary,
        activeTool: state.activeToolName,
        eraserActive: state.eraserActive,
        activeLayerName: state.activeLayerName,
        onBrushChanged: callbacks.onBrushChanged,
        onToggleEraser: callbacks.onToggleEraser,
        onBrushColor: callbacks.onBrushColor,
        onOpenLayers: callbacks.onOpenLayers,
      ),
      'color' => CanvasColorPalettePanel(
        mainColor: state.mainColor,
        subColor: state.subColor,
        recentColors: state.recentColors,
        eraserActive: state.transparentColorActive,
        onChoose: callbacks.onChooseColor,
        onChooseSub: callbacks.onChooseSubColor,
        onSelectRecent: callbacks.onSelectRecentColor,
        onSwap: callbacks.onSwapColors,
        onReset: callbacks.onResetColors,
        onTransparent: callbacks.onTransparentColor,
      ),
      'materials' => InkMaterialsPanel(
        controller: state.comicWorkspace,
        onOpenComics: callbacks.onOpenComics,
      ),
      'comics' => state.buildComics(),
      'quickAccess' => CanvasQuickAccessPanel(
        sets: state.quickAccessSets,
        activeSetId: state.activeQuickAccessSetId,
        onAction: callbacks.onQuickAccessAction,
        onChanged: callbacks.onQuickAccessChanged,
      ),
      'history' => CanvasHistoryPanel(
        engine: state.engine,
        revisionToken: math.max(state.renderRevision, state.engine.revision),
        onNavigate: callbacks.onNavigateHistory,
      ),
      _ => state.buildLayers(),
    };
  }
}
