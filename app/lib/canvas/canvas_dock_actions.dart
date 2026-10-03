import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../app/workspace_preferences.dart';
import 'canvas_desktop_dock.dart';
import 'canvas_workspace_layout_actions.dart';

/// State and persistence seams used by desktop dock arrangement actions.
class CanvasDockActionHost {
  const CanvasDockActionHost({
    required this.preferences,
    required this.layoutActions,
    required this.groups,
    required this.setGroups,
    required this.setTab,
    required this.dockWidth,
    required this.dockCollapsed,
    required this.setDockWidth,
    required this.setDockCollapsed,
    required this.clearTemporaryPalette,
    required this.updateState,
  });

  final WorkspacePreferences Function() preferences;
  final CanvasWorkspaceLayoutActions layoutActions;
  final List<DockGroupLayout> Function({required bool left}) groups;
  final void Function({
    required bool left,
    required List<DockGroupLayout> groups,
  })
  setGroups;
  final void Function({required bool left, required String tab}) setTab;
  final double Function({required bool left}) dockWidth;
  final bool Function({required bool left}) dockCollapsed;
  final void Function({required bool left, required double width}) setDockWidth;
  final void Function({required bool left, required bool collapsed})
  setDockCollapsed;
  final VoidCallback clearTemporaryPalette;
  final void Function(VoidCallback update) updateState;
}

/// Owns desktop dock tab selection, movement, resizing, and persistence.
class CanvasDockActions {
  const CanvasDockActions(this.host);

  final CanvasDockActionHost host;

  /// Applies a bounded dock-width change and persists the selected column.
  void adjustWidth({required bool left, required double delta}) {
    final currentWidth = host.dockWidth(left: left);
    final nextWidth = (currentWidth + delta).clamp(220.0, 480.0).toDouble();
    if (nextWidth == currentWidth) return;
    host.updateState(() => host.setDockWidth(left: left, width: nextWidth));
    host.layoutActions.persistDockWidth(left: left, width: nextWidth);
  }

  /// Applies a dock visibility change and persists it with the active layout.
  void setCollapsed({required bool left, required bool collapsed}) {
    if (host.dockCollapsed(left: left) == collapsed) return;
    host.updateState(
      () => host.setDockCollapsed(left: left, collapsed: collapsed),
    );
    persistGroups(left: left, right: !left);
  }

  void selectPaletteState({
    required bool left,
    required int groupIndex,
    required String tab,
  }) {
    final palette = host.layoutActions.paletteForDockTab(tab);
    var groups = host.groups(left: left);
    if (groups.isEmpty) {
      groups = [
        DockGroupLayout(tabs: [palette], activeTab: palette),
      ];
    } else {
      final index = groupIndex < 0 ? 0 : groupIndex.clamp(0, groups.length - 1);
      final current = groups[index];
      final tabs = [...current.tabs];
      if (!tabs.contains(palette) && tabs.length < 8) tabs.add(palette);
      groups = [...groups];
      groups[index] = DockGroupLayout(
        flex: current.flex,
        tabs: tabs,
        activeTab: palette,
      );
    }
    host.setGroups(left: left, groups: groups);
    host.setTab(left: left, tab: tab);
  }

  void reorderPalette({
    required bool left,
    required int groupIndex,
    required int fromIndex,
    required int toIndex,
  }) {
    final groups = [...host.groups(left: left)];
    if (groupIndex < 0 || groupIndex >= groups.length) return;
    final current = groups[groupIndex];
    if (fromIndex < 0 || fromIndex >= current.tabs.length) return;
    final tabs = [...current.tabs];
    final palette = tabs.removeAt(fromIndex);
    tabs.insert(toIndex.clamp(0, tabs.length), palette);
    groups[groupIndex] = DockGroupLayout(
      flex: current.flex,
      tabs: tabs,
      activeTab: current.activeTab,
    );
    host.updateState(() => host.setGroups(left: left, groups: groups));
    persistGroups(left: left);
  }

  void movePalette({
    required DockPaletteDragData source,
    required bool targetLeft,
    required int targetGroupIndex,
    required int targetTabIndex,
  }) {
    if (source.isLeft == targetLeft && source.groupIndex == targetGroupIndex) {
      reorderPalette(
        left: targetLeft,
        groupIndex: targetGroupIndex,
        fromIndex: source.tabIndex,
        toIndex: targetTabIndex,
      );
      return;
    }

    final leftGroups = [...host.groups(left: true)];
    final rightGroups = [...host.groups(left: false)];
    final sourceGroups = source.isLeft ? leftGroups : rightGroups;
    final targetGroups = targetLeft ? leftGroups : rightGroups;
    if (source.groupIndex < 0 || source.groupIndex >= sourceGroups.length) {
      return;
    }
    if (targetGroupIndex < 0 || targetGroupIndex >= targetGroups.length) return;
    final sourceGroup = sourceGroups[source.groupIndex];
    if (source.tabIndex < 0 ||
        source.tabIndex >= sourceGroup.tabs.length ||
        sourceGroup.tabs[source.tabIndex] != source.palette) {
      return;
    }
    final targetGroup = targetGroups[targetGroupIndex];
    if (targetGroup.tabs.contains(source.palette)) return;

    final sourceTabs = [...sourceGroup.tabs]..removeAt(source.tabIndex);
    if (sourceTabs.isEmpty) {
      final fallback =
          source.isLeft
              ? (source.palette == InkPaletteId.toolGroups
                  ? InkPaletteId.brushPresets
                  : InkPaletteId.toolGroups)
              : (source.palette == InkPaletteId.layers
                  ? InkPaletteId.toolProperties
                  : InkPaletteId.layers);
      sourceGroups[source.groupIndex] = DockGroupLayout(
        flex: sourceGroup.flex,
        tabs: [fallback],
        activeTab: fallback,
      );
    } else {
      sourceGroups[source.groupIndex] = DockGroupLayout(
        flex: sourceGroup.flex,
        tabs: sourceTabs,
        activeTab:
            sourceGroup.activeTab == source.palette
                ? sourceTabs.first
                : sourceGroup.activeTab,
      );
    }
    final adjustedTargetIndex = targetGroups.indexOf(targetGroup);
    if (adjustedTargetIndex < 0 || adjustedTargetIndex >= targetGroups.length) {
      return;
    }
    final destination = targetGroups[adjustedTargetIndex];
    if (destination.tabs.length >= 8) return;
    final destinationTabs = [
      ...destination.tabs,
    ]..insert(targetTabIndex.clamp(0, destination.tabs.length), source.palette);
    targetGroups[adjustedTargetIndex] = DockGroupLayout(
      flex: destination.flex,
      tabs: destinationTabs,
      activeTab: source.palette,
    );

    host.updateState(() {
      host.setGroups(left: true, groups: leftGroups);
      host.setGroups(left: false, groups: rightGroups);
      if (source.isLeft) {
        host.setTab(
          left: true,
          tab: _tabForGroups(leftGroups, fallback: 'tools'),
        );
      } else {
        host.setTab(
          left: false,
          tab: _tabForGroups(rightGroups, fallback: 'layers'),
        );
      }
      host.setTab(left: targetLeft, tab: paletteIdToName(source.palette));
      host.clearTemporaryPalette();
    });
    persistGroups(
      left: source.isLeft || targetLeft,
      right: !source.isLeft || !targetLeft,
      lastDock: paletteIdToName(source.palette),
    );
  }

  void persistGroups({
    required bool left,
    bool right = false,
    String? lastDock,
  }) {
    final preferences = host.preferences();
    final index = preferences.customWorkspaces.indexWhere(
      (layout) => layout.id == preferences.workspaceId,
    );
    final updatesLeft = left;
    final updatesRight = right || !left;
    final current = host.layoutActions.layoutFor(
      preferences.workspaceId,
      preferences.customWorkspaces,
    );
    DockColumnLayout? update(DockColumnLayout? column, {required bool left}) =>
        column == null
            ? null
            : DockColumnLayout(
              width: host.dockWidth(left: left),
              collapsed: host.dockCollapsed(left: left),
              groups: host.groups(left: left),
            );
    final updatedLayout = WorkspaceLayout(
      id: current.id,
      name: current.name,
      kind: current.kind,
      left: updatesLeft ? update(current.left, left: true) : current.left,
      right: updatesRight ? update(current.right, left: false) : current.right,
      commandBar: current.commandBar,
    );
    if (index < 0) {
      if (!const {
        'illustration',
        'comic',
        'minimal',
      }.contains(preferences.workspaceId)) {
        return;
      }
      final overrides = Map<String, WorkspaceLayout>.from(
        preferences.workspaceOverrides,
      )..[preferences.workspaceId] = updatedLayout;
      host.layoutActions.persistPreferences(
        workspaceOverrides: overrides,
        lastDock: lastDock,
      );
      return;
    }
    final updatedWorkspaces = [...preferences.customWorkspaces];
    updatedWorkspaces[index] = updatedLayout;
    host.layoutActions.persistPreferences(
      customWorkspaces: updatedWorkspaces,
      lastDock: lastDock,
    );
  }

  String _tabForGroups(
    List<DockGroupLayout> groups, {
    required String fallback,
  }) =>
      host.layoutActions.paletteName(groups.firstOrNull?.activeTab) ?? fallback;

  void resizeGroup({
    required bool left,
    required int dividerIndex,
    required double delta,
    required double availableHeight,
  }) {
    final groups = host.groups(left: left);
    if (dividerIndex < 0 || dividerIndex + 1 >= groups.length) return;
    final displayed = groups
        .map(
          (group) => (group.flex /
                  groups.fold<double>(0, (sum, item) => sum + item.flex))
              .clamp(0.15, 0.70),
        )
        .toList(growable: false);
    final displayedTotal = displayed.fold<double>(
      0,
      (sum, value) => sum + value,
    );
    final firstShare = displayed[dividerIndex] / displayedTotal;
    final secondShare = displayed[dividerIndex + 1] / displayedTotal;
    final pairShare = firstShare + secondShare;
    const minShare = 0.15;
    final maxFirstShare = math.min(0.70, pairShare - minShare);
    if (maxFirstShare < minShare || availableHeight <= 0) return;
    final nextFirstShare = (firstShare + delta / availableHeight).clamp(
      minShare,
      maxFirstShare,
    );
    final nextSecondShare = pairShare - nextFirstShare;
    final updated = [...groups];
    final first = groups[dividerIndex];
    final second = groups[dividerIndex + 1];
    updated[dividerIndex] = DockGroupLayout(
      flex: nextFirstShare,
      tabs: first.tabs,
      activeTab: first.activeTab,
    );
    updated[dividerIndex + 1] = DockGroupLayout(
      flex: nextSecondShare,
      tabs: second.tabs,
      activeTab: second.activeTab,
    );
    host.updateState(() => host.setGroups(left: left, groups: updated));
  }
}
