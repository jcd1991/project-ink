import 'package:flutter/material.dart';

import '../app/workspace_preferences.dart';
import 'canvas_desktop_dock.dart';
import 'workspace_dock_layout.dart';

/// Immutable presentation inputs for one side of the desktop workspace.
class CanvasDesktopDockSnapshot {
  const CanvasDesktopDockSnapshot({
    required this.isLeft,
    required this.width,
    required this.title,
    required this.selectedTab,
    required this.groups,
  });

  final bool isLeft;
  final double width;
  final String title;
  final String selectedTab;
  final List<DockGroupLayout> groups;
}

/// Immutable values needed to compose the desktop dock and its chrome.
class CanvasDesktopWorkspaceSnapshot {
  const CanvasDesktopWorkspaceSnapshot({
    required this.frame,
    required this.wideDesktop,
    required this.interfaceHidden,
    required this.hasLeftDock,
    required this.hasRightDock,
    required this.leftDockCollapsed,
    required this.rightDockCollapsed,
    required this.leftDock,
    required this.rightDock,
    required this.statusBar,
  });

  final CanvasWorkspaceFrame frame;
  final bool wideDesktop;
  final bool interfaceHidden;
  final bool hasLeftDock;
  final bool hasRightDock;
  final bool leftDockCollapsed;
  final bool rightDockCollapsed;
  final CanvasDesktopDockSnapshot leftDock;
  final CanvasDesktopDockSnapshot rightDock;
  final Widget statusBar;
}

/// Screen-owned state transitions consumed by the desktop dock composition.
class CanvasDesktopWorkspaceActions {
  const CanvasDesktopWorkspaceActions({
    required this.onWidthDelta,
    required this.onTabSelected,
    required this.onCollapse,
    required this.onGroupResize,
    required this.onGroupResizeEnd,
    required this.onTabReorder,
    required this.onTabMove,
    required this.onExpand,
  });

  final void Function(bool isLeft, double currentWidth, double delta)
  onWidthDelta;
  final void Function(bool isLeft, int groupIndex, String tab) onTabSelected;
  final ValueChanged<bool> onCollapse;
  final void Function(
    bool isLeft,
    int dividerIndex,
    double delta,
    double availableHeight,
  )
  onGroupResize;
  final ValueChanged<bool> onGroupResizeEnd;
  final void Function(bool isLeft, int groupIndex, int fromIndex, int toIndex)
  onTabReorder;
  final void Function(
    bool targetLeft,
    DockPaletteDragData source,
    int targetGroupIndex,
    int targetTabIndex,
  )
  onTabMove;
  final ValueChanged<bool> onExpand;
}

/// Composes desktop docks and desktop chrome from screen-owned snapshots.
///
/// This widget owns layout only. Preferences, dock groups, and collapse state
/// remain with the screen and its workspace action controllers.
class CanvasDesktopWorkspace extends StatelessWidget {
  const CanvasDesktopWorkspace({
    super.key,
    required this.snapshot,
    required this.actions,
    required this.buildPalette,
  });

  final CanvasDesktopWorkspaceSnapshot snapshot;
  final CanvasDesktopWorkspaceActions actions;
  final Widget Function(String tab) buildPalette;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      if (snapshot.frame.showLeftDock) _buildDock(snapshot.leftDock),
      if (snapshot.frame.showRightDock) _buildDock(snapshot.rightDock),
      CanvasDesktopWorkspaceChrome(
        frame: snapshot.frame,
        wideDesktop: snapshot.wideDesktop,
        interfaceHidden: snapshot.interfaceHidden,
        hasLeftDock: snapshot.hasLeftDock,
        hasRightDock: snapshot.hasRightDock,
        leftDockCollapsed: snapshot.leftDockCollapsed,
        rightDockCollapsed: snapshot.rightDockCollapsed,
        statusBar: snapshot.statusBar,
        onExpandLeftDock: () => actions.onExpand(true),
        onExpandRightDock: () => actions.onExpand(false),
      ),
    ],
  );

  Widget _buildDock(CanvasDesktopDockSnapshot dock) => CanvasDesktopDockRegion(
    isLeft: dock.isLeft,
    width: dock.width,
    onWidthDelta:
        (delta) => actions.onWidthDelta(dock.isLeft, dock.width, delta),
    dock: CanvasDesktopDock(
      title: dock.title,
      isLeft: dock.isLeft,
      selectedTab: dock.selectedTab,
      groups: dock.groups,
      onTabSelected:
          (groupIndex, tab) =>
              actions.onTabSelected(dock.isLeft, groupIndex, tab),
      onCollapse: () => actions.onCollapse(dock.isLeft),
      onGroupResize:
          (dividerIndex, delta, height) =>
              actions.onGroupResize(dock.isLeft, dividerIndex, delta, height),
      onGroupResizeEnd: () => actions.onGroupResizeEnd(dock.isLeft),
      onTabReorder:
          (groupIndex, fromIndex, toIndex) =>
              actions.onTabReorder(dock.isLeft, groupIndex, fromIndex, toIndex),
      onTabMove:
          (source, groupIndex, tabIndex) =>
              actions.onTabMove(dock.isLeft, source, groupIndex, tabIndex),
      buildPalette: buildPalette,
    ),
  );
}
