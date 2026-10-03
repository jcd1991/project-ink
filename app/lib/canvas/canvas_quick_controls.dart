import 'package:flutter/material.dart';

import '../design_system/ink_components.dart';
import '../tools/brush_library.dart';

class CanvasQuickControls extends StatelessWidget {
  const CanvasQuickControls({
    super.key,
    required this.selectedBrush,
    required this.activeLayerName,
    required this.activeColor,
    required this.eraserActive,
    required this.transparentColorActive,
    required this.comicClipActive,
    required this.zoom,
    required this.largeControls,
    required this.onBrushChanged,
    required this.onBrushSizeChangeEnd,
    required this.onBrushOpacityChangeEnd,
    required this.onBrushes,
    required this.onBrushColor,
    required this.onToggleEraser,
    required this.onTransparentColor,
    required this.onFitCanvas,
    required this.onSettings,
    required this.subColor,
    required this.onSwapColors,
    required this.onResetColors,
  });

  final BrushPresetView? selectedBrush;
  final String activeLayerName;
  final Color activeColor;
  final bool eraserActive;
  final bool transparentColorActive;
  final bool comicClipActive;
  final double zoom;
  final bool largeControls;
  final ValueChanged<BrushPresetView> onBrushChanged;
  final ValueChanged<double> onBrushSizeChangeEnd;
  final ValueChanged<double> onBrushOpacityChangeEnd;
  final VoidCallback onBrushes;
  final VoidCallback onBrushColor;
  final VoidCallback onToggleEraser;
  final VoidCallback onTransparentColor;
  final VoidCallback onFitCanvas;
  final VoidCallback onSettings;
  final Color subColor;
  final VoidCallback onSwapColors;
  final VoidCallback onResetColors;

  @override
  Widget build(BuildContext context) {
    final brush = selectedBrush;
    final colorScheme = Theme.of(context).colorScheme;
    const controlHeight = 32.0;
    return Container(
      height: 36,
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: inkColors(context).panelBorder)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              button: true,
              label: brush == null ? 'Brush library' : 'Brush ${brush.name}',
              child: Tooltip(
                message: 'Open brush library (B)',
                child: InkWell(
                  onTap: onBrushes,
                  child: SizedBox(
                    height: controlHeight,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.brush, size: 16),
                          const SizedBox(width: 5),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 112),
                            child: Text(
                              brush?.name ?? 'Choose brush',
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            InkStatusChip(label: activeLayerName, icon: Icons.layers),
            const SizedBox(width: 4),
            _QuickSlider(
              label: 'Size',
              value: (brush?.size ?? 12).clamp(0.25, 512).toDouble(),
              min: 0.25,
              max: 512,
              displayValue:
                  brush == null ? '—' : '${brush.size.toStringAsFixed(1)} px',
              enabled: brush != null,
              height: controlHeight,
              onChanged: (value) {
                if (brush != null) {
                  onBrushChanged(brush.copyWith(size: value));
                }
              },
              onChangeEnd: onBrushSizeChangeEnd,
            ),
            const SizedBox(width: 8),
            _QuickSlider(
              label: 'Opacity',
              value: brush?.opacity ?? 1,
              min: 0,
              max: 1,
              displayValue:
                  brush == null ? '—' : '${(brush.opacity * 100).round()}%',
              enabled: brush != null,
              height: controlHeight,
              onChanged: (value) {
                if (brush != null) {
                  onBrushChanged(brush.copyWith(opacity: value));
                }
              },
              onChangeEnd: onBrushOpacityChangeEnd,
            ),
            const SizedBox(width: 4),
            Tooltip(
              message: eraserActive ? 'Use brush' : 'Use eraser (E)',
              child: InkWell(
                onTap: onToggleEraser,
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        eraserActive ? Icons.cleaning_services : Icons.edit,
                        size: 15,
                        color: eraserActive ? colorScheme.primary : null,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        eraserActive ? 'Eraser' : 'Brush',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Tooltip(
              message: 'Transparent color — erase with the active brush',
              child: IconButton(
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(
                  width: 32,
                  height: 32,
                ),
                padding: EdgeInsets.zero,
                onPressed: onTransparentColor,
                style: IconButton.styleFrom(
                  backgroundColor:
                      transparentColorActive
                          ? Theme.of(context).colorScheme.secondaryContainer
                          : null,
                ),
                icon: const Icon(Icons.layers_clear, size: 18),
              ),
            ),
            if (comicClipActive) ...[
              const SizedBox(width: 4),
              const InkStatusChip(
                label: 'Panel clip on',
                icon: Icons.crop_free,
              ),
            ],
            const SizedBox(width: 4),
            Tooltip(
              message: 'Main and sub colors (X swaps, D resets, C opens color)',
              child: InkWell(
                onTap: onBrushColor,
                borderRadius: BorderRadius.circular(18),
                child: SizedBox(
                  width: 40,
                  height: 32,
                  child: Stack(
                    children: [
                      Positioned(
                        right: 2,
                        bottom: 2,
                        child: CanvasColorSwatch(
                          color: subColor,
                          size: 18,
                          onTap: onSwapColors,
                        ),
                      ),
                      Positioned(
                        left: 2,
                        top: 2,
                        child: CanvasColorSwatch(
                          color: activeColor,
                          size: 22,
                          onTap: onBrushColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Tooltip(
              message: 'Reset main/sub colors to black and white (D)',
              child: IconButton(
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(
                  width: 32,
                  height: 32,
                ),
                padding: EdgeInsets.zero,
                onPressed: onResetColors,
                icon: const Icon(Icons.refresh, size: 18),
              ),
            ),
            const VerticalDivider(width: 16),
            Text(
              '${(zoom * 100).round()}%',
              style: Theme.of(context).textTheme.labelMedium,
            ),
            Tooltip(
              message: 'Fit canvas',
              child: IconButton(
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(
                  width: 32,
                  height: 32,
                ),
                padding: EdgeInsets.zero,
                onPressed: onFitCanvas,
                icon: const Icon(Icons.fit_screen, size: 18),
              ),
            ),
            Tooltip(
              message: 'Canvas and gesture settings',
              child: IconButton(
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(
                  width: 32,
                  height: 32,
                ),
                padding: EdgeInsets.zero,
                onPressed: onSettings,
                icon: Icon(Icons.tune, size: 18, color: colorScheme.primary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickSlider extends StatelessWidget {
  const _QuickSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.displayValue,
    required this.enabled,
    required this.height,
    required this.onChanged,
    this.onChangeEnd,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String displayValue;
  final bool enabled;
  final double height;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 190,
    height: height,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelSmall),
        Expanded(
          child: Slider(
            value: value.clamp(min, max).toDouble(),
            min: min,
            max: max,
            onChanged: enabled ? onChanged : null,
            onChangeEnd: enabled ? onChangeEnd : null,
          ),
        ),
        SizedBox(
          width: 48,
          child: Text(
            displayValue,
            textAlign: TextAlign.end,
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ),
      ],
    ),
  );
}

class CanvasColorSwatch extends StatelessWidget {
  const CanvasColorSwatch({
    super.key,
    required this.color,
    required this.size,
    required this.onTap,
  });

  final Color color;
  final double size;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Color swatch',
    child: InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: inkColors(context).panelBorder, width: 1.5),
        ),
      ),
    ),
  );
}
