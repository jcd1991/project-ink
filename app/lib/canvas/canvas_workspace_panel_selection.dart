import '../app/editor_action.dart';
import '../app/workspace_preferences.dart';
import 'canvas_floating_panel_visibility.dart';

enum CanvasPanelSheet { color, history, quickAccess, layers }

/// Resolves panel-oriented editor commands to the workspace panel identifier.
String? canvasWorkspacePanelForAction(EditorActionId action) =>
    switch (action) {
      EditorActionId.showTools => 'tools',
      EditorActionId.showBrushes => 'brushes',
      EditorActionId.showLayers => 'layers',
      EditorActionId.showComics => 'comics',
      EditorActionId.showColorPicker => 'color',
      EditorActionId.showToolProperties => 'properties',
      EditorActionId.showMaterials => 'materials',
      EditorActionId.showHistory => 'history',
      EditorActionId.showQuickAccess => 'quickAccess',
      _ => null,
    };

enum CanvasDockSide { left, right }

/// Result of applying a palette-selection intent to workspace presentation.
class CanvasWorkspacePanelSelection {
  const CanvasWorkspacePanelSelection({
    required this.floatingPanels,
    this.sheet,
    this.dockSide,
    this.dockGroupIndex,
    this.temporaryPalette,
  });

  final CanvasFloatingPanelVisibility floatingPanels;
  final CanvasPanelSheet? sheet;
  final CanvasDockSide? dockSide;
  final int? dockGroupIndex;
  final String? temporaryPalette;

  bool get selectsDesktopDock => dockSide != null;
}

/// Applies compact-phone, Studio-touch, and desktop-dock selection rules.
///
/// This is a pure policy boundary. The route owns widgets, context, state
/// publication, and preference persistence.
CanvasWorkspacePanelSelection selectCanvasWorkspacePanel({
  required String panel,
  required bool wideDesktop,
  required bool studioTouchLayout,
  bool compactPhone = false,
  required WorkspaceLayout layout,
  required List<DockGroupLayout> leftGroups,
  required List<DockGroupLayout> rightGroups,
  required CanvasFloatingPanelVisibility floatingPanels,
}) {
  var nextPanels = floatingPanels;
  if (studioTouchLayout && (panel == 'history' || panel == 'quickAccess')) {
    nextPanels = const CanvasFloatingPanelVisibility();
  }

  if (wideDesktop) {
    const leftPalettes = {'tools', 'brushes', 'color', 'quickAccess'};
    final palette = canvasPaletteForDockTab(panel);
    final leftGroupIndex = leftGroups.indexWhere(
      (group) => group.tabs.contains(palette),
    );
    final rightGroupIndex = rightGroups.indexWhere(
      (group) => group.tabs.contains(palette),
    );
    if (leftGroupIndex >= 0 ||
        (leftPalettes.contains(panel) && layout.left != null)) {
      return CanvasWorkspacePanelSelection(
        floatingPanels: nextPanels,
        dockSide: CanvasDockSide.left,
        dockGroupIndex: leftGroupIndex,
      );
    }
    if (rightGroupIndex >= 0 || layout.right != null) {
      return CanvasWorkspacePanelSelection(
        floatingPanels: nextPanels,
        dockSide: CanvasDockSide.right,
        dockGroupIndex: rightGroupIndex,
      );
    }
    return CanvasWorkspacePanelSelection(
      floatingPanels: nextPanels,
      temporaryPalette: panel,
    );
  }

  if (compactPhone && (panel == 'color' || panel == 'layers')) {
    return CanvasWorkspacePanelSelection(
      floatingPanels: const CanvasFloatingPanelVisibility(),
      sheet:
          panel == 'layers' ? CanvasPanelSheet.layers : CanvasPanelSheet.color,
    );
  }

  final sheet = switch (panel) {
    'color' => CanvasPanelSheet.color,
    'history' => CanvasPanelSheet.history,
    'quickAccess' => CanvasPanelSheet.quickAccess,
    _ => null,
  };
  if (sheet != null) {
    return CanvasWorkspacePanelSelection(
      floatingPanels: nextPanels,
      sheet: sheet,
    );
  }

  final floatingPanel = CanvasFloatingPanelVisibility.fromName(panel);
  if (floatingPanel != null) {
    nextPanels =
        studioTouchLayout
            ? nextPanels.toggleExclusive(floatingPanel)
            : nextPanels.toggle(floatingPanel);
  } else if (studioTouchLayout) {
    nextPanels = nextPanels.toggleExclusive(null);
  }
  return CanvasWorkspacePanelSelection(floatingPanels: nextPanels);
}

InkPaletteId canvasPaletteForDockTab(String tab) => switch (tab) {
  'tools' => InkPaletteId.toolGroups,
  'brushes' => InkPaletteId.brushPresets,
  'properties' => InkPaletteId.toolProperties,
  'materials' => InkPaletteId.materials,
  'comics' => InkPaletteId.comics,
  'quickAccess' => InkPaletteId.quickAccess,
  'history' => InkPaletteId.history,
  'color' => InkPaletteId.color,
  _ => InkPaletteId.layers,
};
