import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/app/editor_action.dart';
import 'package:project_ink/app/workspace_preferences.dart';
import 'package:project_ink/canvas/canvas_floating_panel_visibility.dart';
import 'package:project_ink/canvas/canvas_workspace_panel_selection.dart';

void main() {
  test('maps panel commands to workspace identifiers', () {
    expect(canvasWorkspacePanelForAction(EditorActionId.showTools), 'tools');
    expect(
      canvasWorkspacePanelForAction(EditorActionId.showBrushes),
      'brushes',
    );
    expect(canvasWorkspacePanelForAction(EditorActionId.showLayers), 'layers');
    expect(canvasWorkspacePanelForAction(EditorActionId.showComics), 'comics');
    expect(
      canvasWorkspacePanelForAction(EditorActionId.showColorPicker),
      'color',
    );
    expect(
      canvasWorkspacePanelForAction(EditorActionId.showToolProperties),
      'properties',
    );
    expect(
      canvasWorkspacePanelForAction(EditorActionId.showMaterials),
      'materials',
    );
    expect(
      canvasWorkspacePanelForAction(EditorActionId.showHistory),
      'history',
    );
    expect(
      canvasWorkspacePanelForAction(EditorActionId.showQuickAccess),
      'quickAccess',
    );
    expect(canvasWorkspacePanelForAction(EditorActionId.undo), isNull);
  });

  test('compact selection toggles only the selected floating panel', () {
    const current = CanvasFloatingPanelVisibility(tools: true);
    final selection = selectCanvasWorkspacePanel(
      panel: 'layers',
      wideDesktop: false,
      studioTouchLayout: false,
      layout: illustrationWorkspace,
      leftGroups: const [],
      rightGroups: const [],
      floatingPanels: current,
    );

    expect(selection.floatingPanels.tools, isTrue);
    expect(selection.floatingPanels.layers, isTrue);
    expect(selection.sheet, isNull);
  });

  test('phone Layers uses a sheet and clears floating panels', () {
    final selection = selectCanvasWorkspacePanel(
      panel: 'layers',
      wideDesktop: false,
      studioTouchLayout: false,
      compactPhone: true,
      layout: illustrationWorkspace,
      leftGroups: const [],
      rightGroups: const [],
      floatingPanels: const CanvasFloatingPanelVisibility(tools: true),
    );

    expect(selection.sheet, CanvasPanelSheet.layers);
    expect(selection.floatingPanels.lastVisiblePanel, isNull);
  });

  test('phone Color uses its compact picker sheet', () {
    final selection = selectCanvasWorkspacePanel(
      panel: 'color',
      wideDesktop: false,
      studioTouchLayout: false,
      compactPhone: true,
      layout: illustrationWorkspace,
      leftGroups: const [],
      rightGroups: const [],
      floatingPanels: const CanvasFloatingPanelVisibility(layers: true),
    );

    expect(selection.sheet, CanvasPanelSheet.color);
    expect(selection.floatingPanels.lastVisiblePanel, isNull);
  });

  test('Studio selection is exclusive and reselecting the panel closes it', () {
    final first = selectCanvasWorkspacePanel(
      panel: 'layers',
      wideDesktop: false,
      studioTouchLayout: true,
      layout: illustrationWorkspace,
      leftGroups: const [],
      rightGroups: const [],
      floatingPanels: const CanvasFloatingPanelVisibility(tools: true),
    );
    final second = selectCanvasWorkspacePanel(
      panel: 'layers',
      wideDesktop: false,
      studioTouchLayout: true,
      layout: illustrationWorkspace,
      leftGroups: const [],
      rightGroups: const [],
      floatingPanels: first.floatingPanels,
    );

    expect(first.floatingPanels.layers, isTrue);
    expect(first.floatingPanels.tools, isFalse);
    expect(second.floatingPanels.lastVisiblePanel, isNull);
  });

  test('mobile history sheets close the active Studio panel first', () {
    final selection = selectCanvasWorkspacePanel(
      panel: 'history',
      wideDesktop: false,
      studioTouchLayout: true,
      layout: illustrationWorkspace,
      leftGroups: const [],
      rightGroups: const [],
      floatingPanels: const CanvasFloatingPanelVisibility(layers: true),
    );

    expect(selection.sheet, CanvasPanelSheet.history);
    expect(selection.floatingPanels.lastVisiblePanel, isNull);
  });

  test('Color sheet preserves the currently open Studio palette', () {
    final selection = selectCanvasWorkspacePanel(
      panel: 'color',
      wideDesktop: false,
      studioTouchLayout: true,
      layout: illustrationWorkspace,
      leftGroups: const [],
      rightGroups: const [],
      floatingPanels: const CanvasFloatingPanelVisibility(layers: true),
    );

    expect(selection.sheet, CanvasPanelSheet.color);
    expect(selection.floatingPanels.layers, isTrue);
  });

  test('desktop selection routes panels to the matching dock group', () {
    const leftGroups = [
      DockGroupLayout(
        tabs: [InkPaletteId.toolGroups, InkPaletteId.brushPresets],
        activeTab: InkPaletteId.brushPresets,
      ),
    ];
    const rightGroups = [
      DockGroupLayout(
        tabs: [InkPaletteId.layers, InkPaletteId.comics],
        activeTab: InkPaletteId.layers,
      ),
    ];
    final selection = selectCanvasWorkspacePanel(
      panel: 'comics',
      wideDesktop: true,
      studioTouchLayout: false,
      layout: illustrationWorkspace,
      leftGroups: leftGroups,
      rightGroups: rightGroups,
      floatingPanels: const CanvasFloatingPanelVisibility(),
    );

    expect(selection.dockSide, CanvasDockSide.right);
    expect(selection.dockGroupIndex, 0);
    expect(selection.temporaryPalette, isNull);
  });

  test('desktop workspaces without dock columns open a temporary palette', () {
    const layout = WorkspaceLayout(
      id: 'canvas-only',
      name: 'Canvas only',
      kind: WorkspacePresetKind.custom,
    );
    final selection = selectCanvasWorkspacePanel(
      panel: 'layers',
      wideDesktop: true,
      studioTouchLayout: false,
      layout: layout,
      leftGroups: const [],
      rightGroups: const [],
      floatingPanels: const CanvasFloatingPanelVisibility(),
    );

    expect(selection.selectsDesktopDock, isFalse);
    expect(selection.temporaryPalette, 'layers');
  });
}
