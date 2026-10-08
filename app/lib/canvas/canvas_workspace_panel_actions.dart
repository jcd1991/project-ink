import 'package:flutter/material.dart';

import '../app/workspace_preferences.dart';
import 'canvas_floating_panel_visibility.dart';
import 'canvas_workspace_panel_selection.dart';

/// Workspace and device state used to resolve one panel-selection intent.
@immutable
class CanvasWorkspacePanelActionSnapshot {
  const CanvasWorkspacePanelActionSnapshot({
    required this.wideDesktop,
    required this.studioTouchLayout,
    required this.editorMode,
    required this.layout,
    required this.leftGroups,
    required this.rightGroups,
    required this.floatingPanels,
    this.compactPhone = false,
  });

  final bool wideDesktop;
  final bool studioTouchLayout;
  final EditorMode editorMode;
  final WorkspaceLayout layout;
  final List<DockGroupLayout> leftGroups;
  final List<DockGroupLayout> rightGroups;
  final CanvasFloatingPanelVisibility floatingPanels;
  final bool compactPhone;
}

/// Effect boundary for workspace panel routing.
class CanvasWorkspacePanelActionHost {
  const CanvasWorkspacePanelActionHost({
    required this.setFloatingPanels,
    required this.selectDesktopDock,
    required this.selectTemporaryPalette,
    required this.rememberStudioPalette,
    required this.persistLastDock,
    required this.showQuickAccessSheet,
    required this.showHistorySheet,
    required this.showColorSheet,
    required this.showLayersSheet,
  });

  final void Function(CanvasFloatingPanelVisibility visibility)
  setFloatingPanels;
  final void Function(
    CanvasDockSide side,
    int groupIndex,
    String panel,
    CanvasFloatingPanelVisibility floatingPanels,
  )
  selectDesktopDock;
  final ValueChanged<String> selectTemporaryPalette;
  final ValueChanged<EditorMode> rememberStudioPalette;
  final ValueChanged<String> persistLastDock;
  final void Function(BuildContext context) showQuickAccessSheet;
  final void Function(BuildContext context) showHistorySheet;
  final void Function(BuildContext context) showColorSheet;
  final void Function(BuildContext context) showLayersSheet;
}

/// Owns panel-selection branching while the screen supplies snapshots/effects.
class CanvasWorkspacePanelActions {
  const CanvasWorkspacePanelActions(this.host);

  final CanvasWorkspacePanelActionHost host;

  void selectPanel({
    required String panel,
    required BuildContext context,
    required CanvasWorkspacePanelActionSnapshot snapshot,
  }) {
    final selection = selectCanvasWorkspacePanel(
      panel: panel,
      wideDesktop: snapshot.wideDesktop,
      studioTouchLayout: snapshot.studioTouchLayout,
      compactPhone: snapshot.compactPhone,
      layout: snapshot.layout,
      leftGroups: snapshot.leftGroups,
      rightGroups: snapshot.rightGroups,
      floatingPanels: snapshot.floatingPanels,
    );

    switch (selection.sheet) {
      case CanvasPanelSheet.color:
        if (snapshot.compactPhone) {
          host.setFloatingPanels(selection.floatingPanels);
        }
        host.showColorSheet(context);
        return;
      case CanvasPanelSheet.quickAccess:
        if (snapshot.studioTouchLayout) {
          host.setFloatingPanels(selection.floatingPanels);
        }
        host.showQuickAccessSheet(context);
        return;
      case CanvasPanelSheet.history:
        if (snapshot.studioTouchLayout) {
          host.setFloatingPanels(selection.floatingPanels);
        }
        host.showHistorySheet(context);
        return;
      case CanvasPanelSheet.layers:
        host.setFloatingPanels(selection.floatingPanels);
        host.showLayersSheet(context);
        return;
      case null:
        break;
    }

    final dockSide = selection.dockSide;
    if (dockSide != null) {
      host.selectDesktopDock(
        dockSide,
        selection.dockGroupIndex ?? 0,
        panel,
        selection.floatingPanels,
      );
      host.persistLastDock(panel);
      return;
    }

    host.setFloatingPanels(selection.floatingPanels);
    final temporaryPalette = selection.temporaryPalette;
    if (temporaryPalette != null) {
      host.selectTemporaryPalette(temporaryPalette);
    }
    host.rememberStudioPalette(snapshot.editorMode);
    host.persistLastDock(panel);
  }
}
