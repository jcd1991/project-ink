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
  panel,
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
    IllustrationTool.panel => 'Panel divider',
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
    IllustrationTool.panel => Icons.view_quilt_outlined,
  };
}

class IllustrationToolPalette extends StatelessWidget {
  const IllustrationToolPalette({
    super.key,
    required this.selected,
    required this.onSelected,
    required this.onClearSelection,
    required this.onTransformPreset,
    this.onApplyPanelLayout,
    this.onPanelStyleChanged,
    this.panelCount = 0,
    this.gutterPx = 24,
    this.borderPx = 2,
    this.panelLoading = false,
  });

  final IllustrationTool selected;
  final ValueChanged<IllustrationTool> onSelected;
  final VoidCallback onClearSelection;
  final ValueChanged<TransformPreset> onTransformPreset;
  final ValueChanged<int>? onApplyPanelLayout;
  final void Function(double gutterPx, double borderPx)? onPanelStyleChanged;
  final int panelCount;
  final double gutterPx;
  final double borderPx;
  final bool panelLoading;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(12),
    children: [
      InkInspectorRow(
        title: IllustrationTool.brush.label,
        icon: Icon(IllustrationTool.brush.icon, size: 18),
        selected: selected == IllustrationTool.brush,
        onTap: () => onSelected(IllustrationTool.brush),
      ),
      InkInspectorRow(
        title: IllustrationTool.eraser.label,
        icon: Icon(IllustrationTool.eraser.icon, size: 18),
        selected: selected == IllustrationTool.eraser,
        onTap: () => onSelected(IllustrationTool.eraser),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: InkInspectorRow(
          title: IllustrationTool.panel.label,
          subtitle: 'Choose a layout or drag across a frame to split it',
          icon: Icon(IllustrationTool.panel.icon, size: 18),
          selected: selected == IllustrationTool.panel,
          onTap: () => onSelected(IllustrationTool.panel),
        ),
      ),
      if (selected == IllustrationTool.panel) ...[
        const SizedBox(height: 8),
        _PanelToolControls(
          panelCount: panelCount,
          gutterPx: gutterPx,
          borderPx: borderPx,
          onApplyLayout: onApplyPanelLayout,
          onStyleChanged: onPanelStyleChanged,
          loading: panelLoading,
        ),
        const Divider(height: 20),
      ],
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

class _PanelToolControls extends StatefulWidget {
  const _PanelToolControls({
    required this.panelCount,
    required this.gutterPx,
    required this.borderPx,
    required this.onApplyLayout,
    required this.onStyleChanged,
    required this.loading,
  });

  final int panelCount;
  final double gutterPx;
  final double borderPx;
  final ValueChanged<int>? onApplyLayout;
  final void Function(double gutterPx, double borderPx)? onStyleChanged;
  final bool loading;

  @override
  State<_PanelToolControls> createState() => _PanelToolControlsState();
}

class _PanelToolControlsState extends State<_PanelToolControls> {
  late double _gutter = widget.gutterPx;
  late double _border = widget.borderPx;

  @override
  void didUpdateWidget(covariant _PanelToolControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.gutterPx != widget.gutterPx) _gutter = widget.gutterPx;
    if (oldWidget.borderPx != widget.borderPx) _border = widget.borderPx;
  }

  @override
  Widget build(BuildContext context) {
    final hasPanels = widget.panelCount > 0;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            hasPanels ? 'Split or adjust a frame' : 'Create your first split',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 4),
          Text(
            hasPanels
                ? 'Drag through a frame to split it. Start inside the frame you want to divide; the preview shows the cut. Drag a gutter to move its divider.'
                : 'On the canvas, drag left to right for a horizontal divider or top to bottom for a vertical one. The preview shows where it will go; release to add it.',
          ),
          if (!hasPanels) ...[
            const SizedBox(height: 10),
            Text(
              'Or start with a ready-made layout',
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ],
          if (widget.loading) ...[
            const SizedBox(height: 8),
            const LinearProgressIndicator(minHeight: 2),
            const SizedBox(height: 4),
            const Text('Preparing panel editing…'),
          ],
          if (!hasPanels) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              children: [
                for (final count in const [2, 3, 4])
                  OutlinedButton(
                    onPressed:
                        !widget.loading
                            ? () => widget.onApplyLayout?.call(count)
                            : null,
                    child: Text('$count panels'),
                  ),
              ],
            ),
          ],
          if (hasPanels) ...[
            const SizedBox(height: 8),
            Text('Gutter  ${_gutter.round()} px'),
            Slider(
              min: 0,
              max: 96,
              divisions: 48,
              value: _gutter.clamp(0, 96),
              onChanged:
                  widget.loading
                      ? null
                      : (value) => setState(() => _gutter = value),
              onChangeEnd: (_) => widget.onStyleChanged?.call(_gutter, _border),
            ),
            Text('Border  ${_border.toStringAsFixed(1)} px'),
            Slider(
              min: 0,
              max: 16,
              divisions: 32,
              value: _border.clamp(0, 16),
              onChanged:
                  widget.loading
                      ? null
                      : (value) => setState(() => _border = value),
              onChangeEnd: (_) => widget.onStyleChanged?.call(_gutter, _border),
            ),
          ],
        ],
      ),
    );
  }
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
            subtitle:
                tool == IllustrationTool.vectorEraser
                    ? 'Legacy ink only; not Bézier paths'
                    : null,
            icon: Icon(tool.icon, size: 18),
            selected: selected == tool,
            onTap: () => onSelected(tool),
          ),
      ],
    ),
  );
}
