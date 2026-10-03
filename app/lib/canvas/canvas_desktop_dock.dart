import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app/workspace_preferences.dart';
import '../design_system/ink_components.dart';
import 'workspace_dock_layout.dart';

class DockPaletteDragData {
  const DockPaletteDragData({
    required this.isLeft,
    required this.groupIndex,
    required this.tabIndex,
    required this.palette,
  });

  final bool isLeft;
  final int groupIndex;
  final int tabIndex;
  final InkPaletteId palette;
}

class CanvasDesktopDock extends StatelessWidget {
  const CanvasDesktopDock({
    super.key,
    required this.title,
    required this.isLeft,
    required this.selectedTab,
    required this.groups,
    required this.onTabSelected,
    required this.onCollapse,
    required this.onGroupResize,
    required this.onGroupResizeEnd,
    required this.onTabReorder,
    required this.onTabMove,
    required this.buildPalette,
  });

  final String title;
  final bool isLeft;
  final String selectedTab;
  final List<DockGroupLayout> groups;
  final void Function(int groupIndex, String tab) onTabSelected;
  final VoidCallback onCollapse;
  final void Function(int dividerIndex, double delta, double height)
  onGroupResize;
  final VoidCallback onGroupResizeEnd;
  final void Function(int groupIndex, int fromIndex, int toIndex) onTabReorder;
  final void Function(
    DockPaletteDragData source,
    int targetGroupIndex,
    int targetTabIndex,
  )
  onTabMove;
  final Widget Function(String tab) buildPalette;

  @override
  Widget build(BuildContext context) {
    final effectiveGroups =
        groups.isEmpty
            ? const [
              DockGroupLayout(
                tabs: [InkPaletteId.layers],
                activeTab: InkPaletteId.layers,
              ),
            ]
            : groups;
    final totalFlex = effectiveGroups.fold<double>(
      0,
      (total, group) => total + group.flex,
    );
    return Material(
      elevation: 0,
      color: inkColors(context).panel,
      child: SafeArea(
        left: false,
        child: Column(
          children: [
            InkDockHeader(
              title: title,
              subtitle: selectedTab[0].toUpperCase() + selectedTab.substring(1),
              actions: [
                PopupMenuButton<String>(
                  tooltip: 'All palettes',
                  padding: EdgeInsets.zero,
                  onSelected: (tab) {
                    final palette = _paletteNameToId(tab);
                    final existingIndex =
                        palette == null
                            ? -1
                            : effectiveGroups.indexWhere(
                              (group) => group.tabs.contains(palette),
                            );
                    onTabSelected(existingIndex < 0 ? 0 : existingIndex, tab);
                  },
                  itemBuilder:
                      (_) => const [
                        PopupMenuItem(
                          value: 'tools',
                          child: Text('Tool groups'),
                        ),
                        PopupMenuItem(
                          value: 'brushes',
                          child: Text('Brush presets'),
                        ),
                        PopupMenuItem(
                          value: 'properties',
                          child: Text('Tool properties'),
                        ),
                        PopupMenuItem(value: 'layers', child: Text('Layers')),
                        PopupMenuItem(
                          value: 'materials',
                          child: Text('Materials'),
                        ),
                        PopupMenuItem(value: 'comics', child: Text('Comics')),
                        PopupMenuItem(value: 'history', child: Text('History')),
                        PopupMenuItem(
                          value: 'quickAccess',
                          child: Text('Quick Access'),
                        ),
                        PopupMenuItem(value: 'color', child: Text('Color')),
                      ],
                  child: const SizedBox(
                    width: 36,
                    child: Icon(Icons.grid_view, size: 18),
                  ),
                ),
                Tooltip(
                  message: 'Collapse Workspace dock',
                  child: IconButton(
                    onPressed: onCollapse,
                    icon: const Icon(Icons.keyboard_double_arrow_right),
                  ),
                ),
              ],
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  const dividerHeight = 8.0;
                  final availableHeight = math.max(
                    0.0,
                    constraints.maxHeight -
                        dividerHeight * (effectiveGroups.length - 1),
                  );
                  return Column(
                    children: [
                      for (
                        var index = 0;
                        index < effectiveGroups.length;
                        index++
                      ) ...[
                        if (index > 0)
                          Tooltip(
                            message: 'Resize palette groups',
                            child: MouseRegion(
                              cursor: SystemMouseCursors.resizeUpDown,
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onVerticalDragUpdate:
                                    (details) => onGroupResize(
                                      index - 1,
                                      details.delta.dy,
                                      availableHeight,
                                    ),
                                onVerticalDragEnd: (_) => onGroupResizeEnd(),
                                child: SizedBox(
                                  height: dividerHeight,
                                  child: Center(
                                    child: Container(
                                      height: 1,
                                      color: inkColors(context).panelBorder,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        Expanded(
                          flex:
                              ((effectiveGroups[index].flex / totalFlex).clamp(
                                        0.15,
                                        0.70,
                                      ) *
                                      100)
                                  .round(),
                          child: _DockPaletteGroup(
                            group: effectiveGroups[index],
                            isLeft: isLeft,
                            groupIndex: index,
                            selectedTab: _groupSelectedTab(
                              effectiveGroups[index],
                              index == 0 ? selectedTab : '',
                            ),
                            onTabSelected: (tab) => onTabSelected(index, tab),
                            onTabReorder:
                                (fromIndex, toIndex) =>
                                    onTabReorder(index, fromIndex, toIndex),
                            onTabMove:
                                (source, targetIndex) =>
                                    onTabMove(source, index, targetIndex),
                            buildPalette: buildPalette,
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _groupSelectedTab(DockGroupLayout group, String fallback) {
    final fallbackPalette = switch (fallback) {
      'tools' => InkPaletteId.toolGroups,
      'brushes' => InkPaletteId.brushPresets,
      'properties' => InkPaletteId.toolProperties,
      'color' => InkPaletteId.color,
      'materials' => InkPaletteId.materials,
      'comics' => InkPaletteId.comics,
      'history' => InkPaletteId.history,
      'quickAccess' => InkPaletteId.quickAccess,
      _ => InkPaletteId.layers,
    };
    final preferred = group.activeTab ?? fallbackPalette;
    return paletteIdToName(
      group.tabs.contains(preferred) ? preferred : group.tabs.first,
    );
  }
}

/// Positions one workspace dock and owns its edge-resize hit target.
///
/// The workspace screen supplies the current width and persists changes. This
/// widget owns only the repeated dock-region layout and pointer-delta
/// orientation for left and right docks.
class CanvasDesktopDockRegion extends StatelessWidget {
  const CanvasDesktopDockRegion({
    super.key,
    required this.isLeft,
    required this.width,
    required this.dock,
    required this.onWidthDelta,
  });

  final bool isLeft;
  final double width;
  final Widget dock;
  final ValueChanged<double> onWidthDelta;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: isLeft ? 44 : null,
      right: isLeft ? null : 0,
      top: 36,
      bottom: 24,
      width: width + 8,
      child:
          isLeft
              ? Row(
                children: [
                  SizedBox(width: width, child: dock),
                  SizedBox(
                    width: 8,
                    child: _DockResizeHandle(
                      isLeft: true,
                      onWidthDelta: onWidthDelta,
                    ),
                  ),
                ],
              )
              : Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    right: 0,
                    top: 0,
                    bottom: 0,
                    width: width,
                    child: dock,
                  ),
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: 16,
                    child: _DockResizeHandle(
                      isLeft: false,
                      onWidthDelta: onWidthDelta,
                    ),
                  ),
                ],
              ),
    );
  }
}

/// Owns placement of the desktop status bar and collapsed-dock controls.
///
/// The workspace owner supplies the visible frame and collapse state. This
/// widget owns only their shared desktop chrome presentation.
class CanvasDesktopWorkspaceChrome extends StatelessWidget {
  const CanvasDesktopWorkspaceChrome({
    super.key,
    required this.frame,
    required this.wideDesktop,
    required this.interfaceHidden,
    required this.hasLeftDock,
    required this.hasRightDock,
    required this.leftDockCollapsed,
    required this.rightDockCollapsed,
    required this.statusBar,
    required this.onExpandLeftDock,
    required this.onExpandRightDock,
  });

  final CanvasWorkspaceFrame frame;
  final bool wideDesktop;
  final bool interfaceHidden;
  final bool hasLeftDock;
  final bool hasRightDock;
  final bool leftDockCollapsed;
  final bool rightDockCollapsed;
  final Widget statusBar;
  final VoidCallback onExpandLeftDock;
  final VoidCallback onExpandRightDock;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      if (frame.desktopDock)
        Positioned(
          left: 44 + frame.dockWidths.left,
          right: frame.dockWidths.right,
          bottom: 0,
          height: 24,
          child: statusBar,
        ),
      if (wideDesktop && !interfaceHidden && hasRightDock && rightDockCollapsed)
        Positioned(
          right: 0,
          top: 88,
          child: Material(
            elevation: 6,
            borderRadius: const BorderRadius.horizontal(
              left: Radius.circular(12),
            ),
            child: Tooltip(
              message: 'Expand Workspace dock',
              child: IconButton(
                onPressed: onExpandRightDock,
                icon: const Icon(Icons.keyboard_double_arrow_left),
              ),
            ),
          ),
        ),
      if (wideDesktop && !interfaceHidden && hasLeftDock && leftDockCollapsed)
        Positioned(
          left: 44,
          top: 88,
          child: Material(
            elevation: 6,
            borderRadius: const BorderRadius.horizontal(
              right: Radius.circular(12),
            ),
            child: Tooltip(
              message: 'Expand Tools & Color dock',
              child: IconButton(
                onPressed: onExpandLeftDock,
                icon: const Icon(Icons.keyboard_double_arrow_right),
              ),
            ),
          ),
        ),
    ],
  );
}

class _DockResizeHandle extends StatelessWidget {
  const _DockResizeHandle({required this.isLeft, required this.onWidthDelta});

  final bool isLeft;
  final ValueChanged<double> onWidthDelta;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.resizeLeftRight,
    child: GestureDetector(
      key: ValueKey<String>(
        isLeft ? 'canvas.dock.resize.left' : 'canvas.dock.resize.right',
      ),
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: (details) {
        onWidthDelta(isLeft ? details.delta.dx : -details.delta.dx);
      },
      child:
          isLeft
              ? Center(
                child: Container(
                  width: 1,
                  color: inkColors(context).panelBorder,
                ),
              )
              : null,
    ),
  );
}

class _DockPaletteGroup extends StatelessWidget {
  const _DockPaletteGroup({
    required this.group,
    required this.isLeft,
    required this.groupIndex,
    required this.selectedTab,
    required this.onTabSelected,
    required this.onTabReorder,
    required this.onTabMove,
    required this.buildPalette,
  });

  final DockGroupLayout group;
  final bool isLeft;
  final int groupIndex;
  final String selectedTab;
  final ValueChanged<String> onTabSelected;
  final void Function(int fromIndex, int toIndex) onTabReorder;
  final void Function(DockPaletteDragData source, int targetIndex) onTabMove;
  final Widget Function(String tab) buildPalette;

  @override
  Widget build(BuildContext context) {
    final selectedId = _paletteNameToId(selectedTab);
    final tabs = [...group.tabs];
    if (selectedId != null && !tabs.contains(selectedId) && tabs.length < 8) {
      tabs.add(selectedId);
    }
    final visibleTabs = tabs.take(3).toList(growable: false);
    final overflowTabs = tabs.skip(3).toList(growable: false);
    return Column(
      children: [
        SizedBox(
          height: 38,
          child: Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    for (final palette in visibleTabs)
                      Flexible(
                        child: _draggableTab(palette, tabs.indexOf(palette)),
                      ),
                    if (overflowTabs.isNotEmpty)
                      PopupMenuButton<String>(
                        tooltip: 'More palettes',
                        onSelected: onTabSelected,
                        itemBuilder:
                            (_) => [
                              for (final palette in overflowTabs)
                                PopupMenuItem(
                                  value: paletteIdToName(palette),
                                  child: Text(_paletteIdLabel(palette)),
                                ),
                            ],
                        child: const SizedBox(
                          width: 32,
                          height: 38,
                          child: Icon(Icons.more_horiz, size: 18),
                        ),
                      ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'Add palette to this group',
                onSelected: onTabSelected,
                itemBuilder:
                    (_) => [
                      for (final palette in InkPaletteId.values.where(
                        (item) => !tabs.contains(item),
                      ))
                        PopupMenuItem(
                          value: paletteIdToName(palette),
                          child: Text(_paletteIdLabel(palette)),
                        ),
                    ],
                child: const SizedBox(
                  width: 32,
                  height: 38,
                  child: Icon(Icons.add, size: 18),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: buildPalette(selectedTab)),
      ],
    );
  }

  Widget _draggableTab(InkPaletteId palette, int tabIndex) {
    final tabName = paletteIdToName(palette);
    return DragTarget<DockPaletteDragData>(
      onWillAcceptWithDetails: (details) {
        return !(details.data.isLeft == isLeft &&
            details.data.groupIndex == groupIndex &&
            details.data.tabIndex == tabIndex);
      },
      onAcceptWithDetails: (details) {
        final source = details.data;
        if (source.isLeft == isLeft && source.groupIndex == groupIndex) {
          onTabReorder(source.tabIndex, tabIndex);
        } else {
          onTabMove(source, tabIndex);
        }
      },
      builder: (context, candidates, rejected) {
        final tab = _DockTabChip(
          tab: tabName,
          selected: tabName == selectedTab,
          onPressed: () => onTabSelected(tabName),
          dropTarget: candidates.isNotEmpty,
        );
        return Draggable<DockPaletteDragData>(
          data: DockPaletteDragData(
            isLeft: isLeft,
            groupIndex: groupIndex,
            tabIndex: tabIndex,
            palette: palette,
          ),
          feedback: Material(
            color: Colors.transparent,
            child: SizedBox(width: 108, child: tab),
          ),
          childWhenDragging: Opacity(opacity: 0.35, child: tab),
          child: tab,
        );
      },
    );
  }
}

class _DockTabChip extends StatelessWidget {
  const _DockTabChip({
    required this.tab,
    required this.selected,
    required this.onPressed,
    this.dropTarget = false,
  });

  final String tab;
  final bool selected;
  final VoidCallback onPressed;
  final bool dropTarget;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: _paletteIdLabel(_paletteNameToId(tab)!),
    child: InkWell(
      onTap: onPressed,
      child: Container(
        constraints: const BoxConstraints(minWidth: 64),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color:
              dropTarget
                  ? inkColors(context).selectedStrong.withValues(alpha: 0.3)
                  : selected
                  ? inkColors(context).selected
                  : null,
          border:
              selected || dropTarget
                  ? Border(
                    bottom: BorderSide(
                      color:
                          dropTarget
                              ? inkColors(context).selectedStrong
                              : inkColors(context).selectedStrong,
                      width: dropTarget ? 3 : 2,
                    ),
                  )
                  : null,
        ),
        child: Text(
          _paletteShortLabel(tab),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ),
    ),
  );
}

String paletteIdToName(InkPaletteId id) => switch (id) {
  InkPaletteId.toolGroups => 'tools',
  InkPaletteId.brushPresets => 'brushes',
  InkPaletteId.toolProperties => 'properties',
  InkPaletteId.color => 'color',
  InkPaletteId.layers => 'layers',
  InkPaletteId.materials => 'materials',
  InkPaletteId.comics => 'comics',
  InkPaletteId.history => 'history',
  InkPaletteId.quickAccess => 'quickAccess',
};

InkPaletteId? _paletteNameToId(String name) => switch (name) {
  'tools' => InkPaletteId.toolGroups,
  'brushes' => InkPaletteId.brushPresets,
  'properties' => InkPaletteId.toolProperties,
  'color' => InkPaletteId.color,
  'layers' => InkPaletteId.layers,
  'materials' => InkPaletteId.materials,
  'comics' => InkPaletteId.comics,
  'history' => InkPaletteId.history,
  'quickAccess' => InkPaletteId.quickAccess,
  _ => null,
};

String _paletteIdLabel(InkPaletteId id) => switch (id) {
  InkPaletteId.toolGroups => 'Tool groups',
  InkPaletteId.brushPresets => 'Brush presets',
  InkPaletteId.toolProperties => 'Tool properties',
  InkPaletteId.color => 'Color',
  InkPaletteId.layers => 'Layers',
  InkPaletteId.materials => 'Materials',
  InkPaletteId.comics => 'Comics',
  InkPaletteId.history => 'History',
  InkPaletteId.quickAccess => 'Quick Access',
};

String _paletteShortLabel(String name) {
  if (name == 'tools') return 'Tools';
  if (name == 'brushes') return 'Brushes';
  if (name == 'properties') return 'Props';
  final id = _paletteNameToId(name);
  return id == null ? name : _paletteIdLabel(id);
}
