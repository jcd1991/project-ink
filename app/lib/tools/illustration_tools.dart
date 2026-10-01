import 'package:flutter/material.dart';

import '../design_system/ink_components.dart';

/// User-facing tools that share the canvas pointer/command pipeline.
///
/// The Rust engine remains authoritative for selection masks and raster
/// constraints; this enum is only the responsive UI projection.
enum IllustrationTool {
  brush,
  eraser,
  rectangleSelect,
  ellipseSelect,
  lassoSelect,
  layerOpacitySelect,
  colorRangeSelect,
  fill,
  transform,
  perspectiveTransform,
  meshTransform,
  liquify,
  vectorPen,
  vectorTransform,
  vectorEraser,
  straightRuler,
  parallelRuler,
  symmetryRuler,
  radialRuler,
  perspectiveRuler,
}

enum TransformPreset { rotateLeft, rotateRight, scaleUp, scaleDown }

extension IllustrationToolLabels on IllustrationTool {
  String get label => switch (this) {
    IllustrationTool.brush => 'Brush',
    IllustrationTool.eraser => 'Eraser',
    IllustrationTool.rectangleSelect => 'Rectangle select',
    IllustrationTool.ellipseSelect => 'Ellipse select',
    IllustrationTool.lassoSelect => 'Lasso select',
    IllustrationTool.layerOpacitySelect => 'Select layer opacity',
    IllustrationTool.colorRangeSelect => 'Select color range',
    IllustrationTool.fill => 'Bucket fill',
    IllustrationTool.transform => 'Transform layer',
    IllustrationTool.perspectiveTransform => 'Perspective transform',
    IllustrationTool.meshTransform => 'Mesh transform',
    IllustrationTool.liquify => 'Liquify push',
    IllustrationTool.vectorPen => 'Vector pen',
    IllustrationTool.vectorTransform => 'Vector transform',
    IllustrationTool.vectorEraser => 'Vector eraser',
    IllustrationTool.straightRuler => 'Straight ruler',
    IllustrationTool.parallelRuler => 'Parallel ruler',
    IllustrationTool.symmetryRuler => 'Symmetry ruler',
    IllustrationTool.radialRuler => 'Radial ruler',
    IllustrationTool.perspectiveRuler => 'Perspective ruler',
  };

  IconData get icon => switch (this) {
    IllustrationTool.brush => Icons.brush,
    IllustrationTool.eraser => Icons.cleaning_services,
    IllustrationTool.rectangleSelect => Icons.crop_square,
    IllustrationTool.ellipseSelect => Icons.circle_outlined,
    IllustrationTool.lassoSelect => Icons.gesture,
    IllustrationTool.layerOpacitySelect => Icons.opacity,
    IllustrationTool.colorRangeSelect => Icons.colorize,
    IllustrationTool.fill => Icons.format_color_fill,
    IllustrationTool.transform => Icons.transform,
    IllustrationTool.perspectiveTransform => Icons.crop_rotate,
    IllustrationTool.meshTransform => Icons.grid_4x4,
    IllustrationTool.liquify => Icons.blur_on,
    IllustrationTool.vectorPen => Icons.edit,
    IllustrationTool.vectorTransform => Icons.open_with,
    IllustrationTool.vectorEraser => Icons.auto_fix_high,
    IllustrationTool.straightRuler => Icons.straighten,
    IllustrationTool.parallelRuler => Icons.view_week,
    IllustrationTool.symmetryRuler => Icons.flip,
    IllustrationTool.radialRuler => Icons.radar,
    IllustrationTool.perspectiveRuler => Icons.grid_on,
  };
}

class IllustrationToolPalette extends StatelessWidget {
  const IllustrationToolPalette({
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
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(12),
    children: [
      _ToolGroup(
        title: 'Draw',
        icon: Icons.brush_outlined,
        initiallyExpanded: selected == IllustrationTool.brush,
        tools: const [IllustrationTool.brush],
        selected: selected,
        onSelected: onSelected,
      ),
      _ToolGroup(
        title: 'Erase and blend',
        icon: Icons.water_drop_outlined,
        initiallyExpanded: selected == IllustrationTool.eraser,
        tools: const [IllustrationTool.eraser],
        selected: selected,
        onSelected: onSelected,
      ),
      _ToolGroup(
        title: 'Select and fill',
        icon: Icons.select_all,
        initiallyExpanded: _selectionTools.contains(selected),
        tools: _selectionTools,
        selected: selected,
        onSelected: onSelected,
      ),
      _ToolGroup(
        title: 'Transform',
        icon: Icons.transform,
        initiallyExpanded: _transformTools.contains(selected),
        tools: _transformTools,
        selected: selected,
        onSelected: onSelected,
      ),
      _ToolGroup(
        title: 'Vector',
        icon: Icons.gesture,
        initiallyExpanded: _vectorTools.contains(selected),
        tools: _vectorTools,
        selected: selected,
        onSelected: onSelected,
      ),
      _ToolGroup(
        title: 'Rulers',
        icon: Icons.straighten,
        initiallyExpanded: _rulerTools.contains(selected),
        tools: _rulerTools,
        selected: selected,
        onSelected: onSelected,
      ),
      if (_selectionTools.contains(selected)) ...[
        const SizedBox(height: 8),
        InkCommandButton(
          icon: Icons.clear,
          label: 'Clear selection',
          onPressed: onClearSelection,
        ),
      ],
      if (selected == IllustrationTool.transform) ...[
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            InkCommandButton(
              label: 'Rotate left 15°',
              icon: Icons.rotate_left,
              onPressed: () => onTransformPreset(TransformPreset.rotateLeft),
            ),
            InkCommandButton(
              label: 'Rotate right 15°',
              icon: Icons.rotate_right,
              onPressed: () => onTransformPreset(TransformPreset.rotateRight),
            ),
            InkCommandButton(
              label: 'Scale up 10%',
              icon: Icons.zoom_in,
              onPressed: () => onTransformPreset(TransformPreset.scaleUp),
            ),
            InkCommandButton(
              label: 'Scale down 10%',
              icon: Icons.zoom_out,
              onPressed: () => onTransformPreset(TransformPreset.scaleDown),
            ),
          ],
        ),
      ],
    ],
  );
}

const _selectionTools = <IllustrationTool>[
  IllustrationTool.rectangleSelect,
  IllustrationTool.ellipseSelect,
  IllustrationTool.lassoSelect,
  IllustrationTool.layerOpacitySelect,
  IllustrationTool.colorRangeSelect,
  IllustrationTool.fill,
];
const _transformTools = <IllustrationTool>[
  IllustrationTool.transform,
  IllustrationTool.perspectiveTransform,
  IllustrationTool.meshTransform,
  IllustrationTool.liquify,
];
const _vectorTools = <IllustrationTool>[
  IllustrationTool.vectorPen,
  IllustrationTool.vectorTransform,
  IllustrationTool.vectorEraser,
];
const _rulerTools = <IllustrationTool>[
  IllustrationTool.straightRuler,
  IllustrationTool.parallelRuler,
  IllustrationTool.symmetryRuler,
  IllustrationTool.radialRuler,
  IllustrationTool.perspectiveRuler,
];

class _ToolGroup extends StatelessWidget {
  const _ToolGroup({
    required this.title,
    required this.icon,
    required this.tools,
    required this.selected,
    required this.onSelected,
    required this.initiallyExpanded,
  });

  final String title;
  final IconData icon;
  final List<IllustrationTool> tools;
  final IllustrationTool selected;
  final ValueChanged<IllustrationTool> onSelected;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) => InkInspectorSection(
    title: title,
    leading: Icon(icon, size: 18),
    initiallyExpanded: initiallyExpanded,
    child: Column(
      children: [
        for (final tool in tools)
          InkInspectorRow(
            title: tool.label,
            icon: Icon(tool.icon, size: 18),
            selected: selected == tool,
            onTap: () => onSelected(tool),
          ),
      ],
    ),
  );
}
