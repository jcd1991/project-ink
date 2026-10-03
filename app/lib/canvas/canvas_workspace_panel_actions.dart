import 'package:flutter/material.dart';

import '../app/workspace_preferences.dart';
import 'canvas_floating_panel_visibility.dart';
import 'canvas_workspace_panel_selection.dart';

/// Workspace and device state used to resolve one panel-selection intent.
@immutable
class CanvasWorkspacePanelActionSnapshot {
  const CanvasWorkspacePanelActionSnapshot({
    required this.wideDesktop,
    required this.tabletStudio,
    required this.tabletPlatform,
    required this.tabletMode,
    required this.layout,
    required this.leftGroups,
    required this.rightGroups,
    required this.floatingPanels,
  });

  final bool wideDesktop;
  final bool tabletStudio;
  final bool tabletPlatform;
  final TabletWorkspaceMode tabletMode;
  final WorkspaceLayout layout;
  final List<DockGroupLayout> leftGroups;
  final List<DockGroupLayout> rightGroups;
  final CanvasFloatingPanelVisibility floatingPanels;
}

/// Effect boundary for workspace panel routing.
class CanvasWorkspacePanelActionHost {
  const CanvasWorkspacePanelActionHost({
    required this.setFloatingPanels,
    required this.selectDesktopDock,
    required this.selectTemporaryPalette,
    required this.rememberTabletPalette,
    required this.persistLastDock,
    required this.showQuickAccessSheet,
    required this.showHistorySheet,
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
  final ValueChanged<TabletWorkspaceMode> rememberTabletPalette;
  final ValueChanged<String> persistLastDock;
  final void Function(BuildContext context) showQuickAccessSheet;
  final void Function(BuildContext context) showHistorySheet;
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
      tabletStudio: snapshot.tabletStudio,
      layout: snapshot.layout,
      leftGroups: snapshot.leftGroups,
      rightGroups: snapshot.rightGroups,
      floatingPanels: snapshot.floatingPanels,
    );

    switch (selection.sheet) {
      case CanvasPanelSheet.quickAccess:
        if (snapshot.tabletStudio) {
          host.setFloatingPanels(selection.floatingPanels);
        }
        host.showQuickAccessSheet(context);
        return;
      case CanvasPanelSheet.history:
        if (snapshot.tabletStudio) {
          host.setFloatingPanels(selection.floatingPanels);
        }
        host.showHistorySheet(context);
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
    if (snapshot.tabletPlatform) {
      host.rememberTabletPalette(snapshot.tabletMode);
    }
    host.persistLastDock(panel);
  }
}
