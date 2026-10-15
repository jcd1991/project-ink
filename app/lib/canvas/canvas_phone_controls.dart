import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../design_system/ink_components.dart';
import '../tools/brush_library.dart';

enum _PhoneMoreAction { tools, eyedropper, transparent }

/// Thumb-reachable phone controls that keep the portrait canvas full width.
class CanvasPhoneBottomControls extends StatelessWidget {
  const CanvasPhoneBottomControls({
    super.key,
    required this.selectedBrush,
    required this.eraserActive,
    required this.onBrushChanged,
    required this.onBrushSizeChangeEnd,
    required this.onBrushOpacityChangeEnd,
    required this.onEyedropper,
    required this.onTools,
    required this.onBrushes,
    required this.onBrushEditorSection,
    required this.onSelectBrush,
    required this.onLayers,
    required this.activeColor,
    required this.subColor,
    required this.transparentColorActive,
    required this.onMainColor,
    required this.onTransparentColor,
    required this.onSelectEraser,
  });

  final BrushPresetView? selectedBrush;
  final bool eraserActive;
  final ValueChanged<BrushPresetView> onBrushChanged;
  final ValueChanged<double> onBrushSizeChangeEnd;
  final ValueChanged<double> onBrushOpacityChangeEnd;
  final VoidCallback onEyedropper;
  final VoidCallback onTools;
  final VoidCallback onBrushes;
  final ValueChanged<BrushEditorSection> onBrushEditorSection;
  final VoidCallback onSelectBrush;
  final VoidCallback onLayers;
  final Color activeColor;
  final Color subColor;
  final bool transparentColorActive;
  final VoidCallback onMainColor;
  final VoidCallback onTransparentColor;
  final VoidCallback onSelectEraser;

  Future<void> _showBrushControls(BuildContext context) async {
    final brush = selectedBrush;
    if (brush == null) return;
    final section = await showCanvasPhoneBrushControlsSheet(
      context,
      brush: brush,
      onBrushChanged: onBrushChanged,
      onSizeChangeEnd: onBrushSizeChangeEnd,
      onOpacityChangeEnd: onBrushOpacityChangeEnd,
    );
    if (section != null) onBrushEditorSection(section);
  }

  void _handleMore(_PhoneMoreAction action) {
    switch (action) {
      case _PhoneMoreAction.tools:
        onTools();
      case _PhoneMoreAction.eyedropper:
        onEyedropper();
      case _PhoneMoreAction.transparent:
        onTransparentColor();
    }
  }

  @override
  Widget build(BuildContext context) {
    final brush = selectedBrush;
    final colorName =
        '#${activeColor.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: inkColors(context).panel.withValues(alpha: 0.96),
        border: Border.all(color: inkColors(context).panelBorder),
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.16),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: SizedBox(
        height: 56,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Keep a 48 dp target for each action. The tool palette moves into
            // More on the narrowest phones; brush selection stays on the bar.
            final showToolsButton = constraints.maxWidth >= 336;
            return Row(
              children: [
                if (showToolsButton)
                  Expanded(
                    child: IconButton(
                      tooltip: 'Draw tools',
                      onPressed: onTools,
                      icon: const Icon(Icons.build_outlined),
                    ),
                  ),
                Expanded(
                  child: IconButton(
                    tooltip: 'Brushes',
                    onPressed: onBrushes,
                    icon: const Icon(Icons.brush_outlined),
                  ),
                ),
                Expanded(
                  child: IconButton(
                    tooltip:
                        eraserActive ? 'Switch to brush' : 'Switch to eraser',
                    onPressed: eraserActive ? onSelectBrush : onSelectEraser,
                    icon: Icon(
                      eraserActive ? Icons.brush : Icons.cleaning_services,
                    ),
                  ),
                ),
                Expanded(
                  child: IconButton(
                    tooltip: 'Brush controls',
                    onPressed:
                        brush == null
                            ? null
                            : () => _showBrushControls(context),
                    icon: const Icon(Icons.tune),
                  ),
                ),
                Expanded(
                  child: Semantics(
                    button: true,
                    label: 'Color selector',
                    value: 'Main $colorName',
                    onTap: onMainColor,
                    child: IconButton(
                      tooltip: 'Color selector',
                      onPressed: onMainColor,
                      icon: _PhoneColorIcon(main: activeColor, sub: subColor),
                    ),
                  ),
                ),
                Expanded(
                  child: IconButton(
                    tooltip: 'Layers',
                    onPressed: onLayers,
                    icon: const Icon(Icons.layers_outlined),
                  ),
                ),
                Expanded(
                  child: PopupMenuButton<_PhoneMoreAction>(
                    tooltip: 'More drawing controls',
                    onSelected: _handleMore,
                    itemBuilder:
                        (context) => [
                          if (!showToolsButton)
                            PopupMenuItem(
                              value: _PhoneMoreAction.tools,
                              child: _menuItem(
                                Icons.build_outlined,
                                'Draw tools',
                              ),
                            ),
                          PopupMenuItem(
                            value: _PhoneMoreAction.eyedropper,
                            child: _menuItem(Icons.colorize, 'Eyedropper'),
                          ),
                          PopupMenuItem(
                            value: _PhoneMoreAction.transparent,
                            child: _menuItem(
                              Icons.invert_colors,
                              transparentColorActive
                                  ? 'Disable transparent paint'
                                  : 'Transparent paint',
                            ),
                          ),
                        ],
                    icon: const Icon(Icons.more_horiz),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _menuItem(IconData icon, String label) => Row(
    children: [
      Icon(icon),
      const SizedBox(width: 12),
      Expanded(
        child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    ],
  );
}

class _PhoneColorIcon extends StatelessWidget {
  const _PhoneColorIcon({required this.main, required this.sub});

  final Color main;
  final Color sub;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 32,
    height: 32,
    child: Stack(
      children: [
        Positioned(
          left: 1,
          top: 1,
          child: Container(
            width: 25,
            height: 25,
            decoration: BoxDecoration(
              color: main,
              shape: BoxShape.circle,
              border: Border.all(color: inkColors(context).panelBorder),
            ),
          ),
        ),
        Positioned(
          right: 0,
          bottom: 0,
          child: Container(
            width: 15,
            height: 15,
            decoration: BoxDecoration(
              color: sub,
              shape: BoxShape.circle,
              border: Border.all(color: inkColors(context).panel, width: 2),
            ),
          ),
        ),
      ],
    ),
  );
}

Future<BrushEditorSection?> showCanvasPhoneBrushControlsSheet(
  BuildContext context, {
  required BrushPresetView brush,
  required ValueChanged<BrushPresetView> onBrushChanged,
  required ValueChanged<double> onSizeChangeEnd,
  required ValueChanged<double> onOpacityChangeEnd,
}) async {
  const minimumSize = 0.25;
  const maximumSize = 512.0;
  double sizeSliderValue(double size) =>
      (math.log(size.clamp(minimumSize, maximumSize) / minimumSize) /
              math.log(maximumSize / minimumSize))
          .clamp(0.0, 1.0);
  double brushSize(double sliderValue) =>
      (minimumSize * math.pow(maximumSize / minimumSize, sliderValue))
          .toDouble();

  var current = brush;
  return showModalBottomSheet<BrushEditorSection>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    builder:
        (_) => StatefulBuilder(
          builder:
              (context, setSheetState) => SafeArea(
                bottom: true,
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Brush controls',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            const Expanded(child: Text('Brush size')),
                            Text('${current.size.toStringAsFixed(1)} px'),
                          ],
                        ),
                        Semantics(
                          label: 'Brush size',
                          child: Slider(
                            semanticFormatterCallback:
                                (value) =>
                                    '${brushSize(value).toStringAsFixed(1)} pixels',
                            value: sizeSliderValue(current.size),
                            min: 0,
                            max: 1,
                            onChanged: (value) {
                              final next = current.copyWith(
                                size: brushSize(value),
                              );
                              setSheetState(() => current = next);
                              onBrushChanged(next);
                            },
                            onChangeEnd:
                                (value) => onSizeChangeEnd(brushSize(value)),
                          ),
                        ),
                        Row(
                          children: [
                            const Expanded(child: Text('Brush opacity')),
                            Text('${(current.opacity * 100).round()}%'),
                          ],
                        ),
                        Semantics(
                          label: 'Brush opacity',
                          child: Slider(
                            semanticFormatterCallback:
                                (value) => '${(value * 100).round()} percent',
                            value: current.opacity,
                            min: 0,
                            max: 1,
                            onChanged: (value) {
                              final next = current.copyWith(opacity: value);
                              setSheetState(() => current = next);
                              onBrushChanged(next);
                            },
                            onChangeEnd: onOpacityChangeEnd,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Settings for ${current.name}',
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                        Text(
                          'Smoothing ${(current.stabilization * 100).round()}% · '
                          'Pulled string ${current.pulledString ? 'on' : 'off'}',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            OutlinedButton.icon(
                              onPressed:
                                  () => Navigator.of(
                                    context,
                                  ).pop(BrushEditorSection.stroke),
                              icon: const Icon(Icons.gesture),
                              label: const Text('Stroke settings'),
                            ),
                            OutlinedButton.icon(
                              onPressed:
                                  () => Navigator.of(
                                    context,
                                  ).pop(BrushEditorSection.pressure),
                              icon: const Icon(Icons.show_chart),
                              label: const Text('Pressure settings'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
        ),
  );
}
