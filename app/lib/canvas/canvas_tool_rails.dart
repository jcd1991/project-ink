import 'package:flutter/material.dart';

import '../app/editor_action.dart';
import '../design_system/ink_components.dart';
import '../tools/illustration_tools.dart';

class EditorActionMenu extends StatelessWidget {
  const EditorActionMenu({
    super.key,
    required this.label,
    this.icon,
    required this.actions,
    this.disabledActions = const {},
    required this.onAction,
  });

  final String label;
  final IconData? icon;
  final List<EditorActionId> actions;
  final Set<EditorActionId> disabledActions;
  final ValueChanged<EditorActionId> onAction;

  @override
  Widget build(BuildContext context) => PopupMenuButton<EditorActionId>(
    tooltip: '$label menu',
    padding: EdgeInsets.zero,
    onSelected: onAction,
    itemBuilder:
        (_) => actions
            .map(
              (action) => PopupMenuItem(
                value: action,
                enabled: !disabledActions.contains(action),
                child: Text(action.label),
              ),
            )
            .toList(growable: false),
    child: SizedBox(
      height: 30,
      child: Center(
        child:
            icon == null
                ? Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                )
                : Icon(icon, size: 17),
      ),
    ),
  );
}

class DesktopToolRail extends StatelessWidget {
  const DesktopToolRail({
    super.key,
    required this.activeTool,
    required this.onTools,
    required this.onBrushes,
    required this.onLayers,
    required this.onEraser,
    required this.eraserActive,
  });

  final IllustrationTool activeTool;
  final VoidCallback onTools;
  final VoidCallback onBrushes;
  final VoidCallback onLayers;
  final VoidCallback onEraser;
  final bool eraserActive;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: inkColors(context).panel,
      border: Border(right: BorderSide(color: inkColors(context).panelBorder)),
    ),
    child: Column(
      children: [
        const SizedBox(height: 8),
        _RailButton(
          icon: Icons.brush,
          customIcon: InkProjectIconId.brush,
          label: 'Draw tools',
          selected: activeTool == IllustrationTool.brush,
          onPressed: onTools,
        ),
        _RailButton(
          icon: Icons.auto_fix_high,
          label: 'Brush presets',
          onPressed: onBrushes,
        ),
        _RailButton(
          icon: Icons.cleaning_services,
          label: 'Erase',
          selected: eraserActive,
          onPressed: onEraser,
        ),
        const Divider(height: 12),
        _RailButton(icon: Icons.layers, label: 'Layers', onPressed: onLayers),
        _RailButton(icon: Icons.tune, label: 'Tool groups', onPressed: onTools),
        _RailButton(
          icon: Icons.straighten,
          customIcon: InkProjectIconId.ruler,
          label: 'Rulers',
          onPressed: onTools,
        ),
      ],
    ),
  );
}

class TabletStudioToolRail extends StatelessWidget {
  const TabletStudioToolRail({
    super.key,
    required this.activeTool,
    required this.eraserActive,
    required this.onTools,
    required this.onBrushes,
    required this.onEraser,
    required this.onLayers,
    required this.onComics,
    required this.onProperties,
    required this.onMaterials,
    required this.onHistory,
    required this.onQuickAccess,
    this.leftHanded = false,
  });

  final IllustrationTool activeTool;
  final bool eraserActive;
  final VoidCallback onTools;
  final VoidCallback onBrushes;
  final VoidCallback onEraser;
  final VoidCallback onLayers;
  final VoidCallback onComics;
  final VoidCallback onProperties;
  final VoidCallback onMaterials;
  final VoidCallback onHistory;
  final VoidCallback onQuickAccess;
  final bool leftHanded;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: 'Studio tool rail',
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: inkColors(context).panel,
        border: Border(
          left:
              leftHanded
                  ? BorderSide(color: inkColors(context).panelBorder)
                  : BorderSide.none,
          right:
              leftHanded
                  ? BorderSide.none
                  : BorderSide(color: inkColors(context).panelBorder),
        ),
      ),
      child: SingleChildScrollView(
        child: Column(
          children: [
            const SizedBox(height: 4),
            InkCommandButton(
              icon: Icons.brush,
              label: 'Draw tools',
              selected:
                  activeTool == IllustrationTool.brush ||
                  activeTool == IllustrationTool.eraser,
              onPressed: onTools,
              hitSize: 48,
            ),
            InkCommandButton(
              icon: Icons.auto_fix_high,
              label: 'Brush presets',
              onPressed: onBrushes,
              hitSize: 48,
            ),
            InkCommandButton(
              icon: Icons.cleaning_services,
              label: eraserActive ? 'Use brush' : 'Eraser',
              selected: eraserActive,
              onPressed: onEraser,
              hitSize: 48,
            ),
            const Divider(height: 8),
            InkCommandButton(
              icon: Icons.layers,
              label: 'Layers',
              onPressed: onLayers,
              hitSize: 48,
            ),
            InkCommandButton(
              icon: Icons.auto_stories,
              label: 'Comics',
              onPressed: onComics,
              hitSize: 48,
            ),
            InkCommandButton(
              icon: Icons.tune,
              label: 'Tool properties',
              onPressed: onProperties,
              hitSize: 48,
            ),
            InkCommandButton(
              icon: Icons.collections_bookmark_outlined,
              label: 'Materials',
              onPressed: onMaterials,
              hitSize: 48,
            ),
            const Divider(height: 8),
            InkCommandButton(
              icon: Icons.history,
              label: 'History',
              onPressed: onHistory,
              hitSize: 48,
            ),
            InkCommandButton(
              icon: Icons.bolt_outlined,
              label: 'Quick Access',
              onPressed: onQuickAccess,
              hitSize: 48,
            ),
          ],
        ),
      ),
    ),
  );
}

class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.selected = false,
    this.customIcon,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool selected;
  final InkProjectIconId? customIcon;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: label,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: IconButton(
        tooltip: label,
        onPressed: onPressed,
        visualDensity: VisualDensity.compact,
        iconSize: 19,
        color: selected ? inkColors(context).selectedStrong : null,
        icon:
            customIcon == null
                ? Icon(icon)
                : InkProjectIcon(
                  customIcon!,
                  color: selected ? inkColors(context).selectedStrong : null,
                ),
      ),
    ),
  );
}
