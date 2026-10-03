import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../design_system/ink_components.dart';
import '../tools/brush_library.dart';

class CanvasSimpleEdgeControls extends StatelessWidget {
  const CanvasSimpleEdgeControls({
    super.key,
    required this.selectedBrush,
    required this.eraserActive,
    required this.onBrushChanged,
    required this.onBrushSizeChangeEnd,
    required this.onBrushOpacityChangeEnd,
    required this.onEyedropper,
    required this.onTools,
    required this.onBrushes,
    required this.onLayers,
    required this.onComics,
    required this.activeColor,
    required this.subColor,
    required this.transparentColorActive,
    required this.onMainColor,
    required this.onSubColor,
    required this.onTransparentColor,
    required this.onToggleEraser,
  });

  final BrushPresetView? selectedBrush;
  final bool eraserActive;
  final ValueChanged<BrushPresetView> onBrushChanged;
  final ValueChanged<double> onBrushSizeChangeEnd;
  final ValueChanged<double> onBrushOpacityChangeEnd;
  final VoidCallback onEyedropper;
  final VoidCallback onTools;
  final VoidCallback onBrushes;
  final VoidCallback onLayers;
  final VoidCallback onComics;
  final Color activeColor;
  final Color subColor;
  final bool transparentColorActive;
  final VoidCallback onMainColor;
  final VoidCallback onSubColor;
  final VoidCallback onTransparentColor;
  final VoidCallback onToggleEraser;

  @override
  Widget build(BuildContext context) {
    final brush = selectedBrush;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: inkColors(context).panel.withValues(alpha: 0.94),
        border: Border.all(color: inkColors(context).panelBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkCommandButton(
              icon: Icons.select_all,
              label: 'Selections',
              onPressed: onTools,
              hitSize: 48,
            ),
            InkCommandButton(
              icon: Icons.brush,
              label: 'Brush library',
              onPressed: onBrushes,
              hitSize: 48,
            ),
            InkCommandButton(
              icon: eraserActive ? Icons.brush : Icons.auto_fix_high,
              label: eraserActive ? 'Use brush' : 'Eraser',
              selected: eraserActive,
              onPressed: onToggleEraser,
              hitSize: 48,
            ),
            InkCommandButton(
              icon: Icons.layers,
              label: 'Layers',
              onPressed: onLayers,
              hitSize: 48,
            ),
            IconButton(
              tooltip: 'Main color',
              onPressed: onMainColor,
              constraints: const BoxConstraints.tightFor(width: 48, height: 48),
              icon: Icon(Icons.circle, color: activeColor),
            ),
            IconButton(
              tooltip: 'Sub color',
              onPressed: onSubColor,
              constraints: const BoxConstraints.tightFor(width: 48, height: 48),
              icon: Icon(Icons.circle, color: subColor),
            ),
            InkCommandButton(
              icon: Icons.invert_colors,
              label: 'Transparent paint',
              selected: transparentColorActive,
              onPressed: onTransparentColor,
              hitSize: 48,
            ),
            InkCommandButton(
              icon: Icons.view_carousel_outlined,
              label: 'Comic workspace',
              onPressed: onComics,
              hitSize: 48,
            ),
            _slider(
              context,
              label: 'Brush size',
              value: (brush?.size ?? 12).clamp(0.25, 512).toDouble(),
              min: 0.25,
              max: 512,
              valueLabel:
                  brush == null ? '—' : '${brush.size.toStringAsFixed(1)} px',
              enabled: brush != null,
              onChanged: (value) {
                if (brush != null) {
                  onBrushChanged(brush.copyWith(size: value));
                }
              },
              onChangeEnd: onBrushSizeChangeEnd,
            ),
            _slider(
              context,
              label: 'Brush opacity',
              value: brush?.opacity ?? 1,
              min: 0,
              max: 1,
              valueLabel:
                  brush == null ? '—' : '${(brush.opacity * 100).round()}%',
              enabled: brush != null,
              onChanged: (value) {
                if (brush != null) {
                  onBrushChanged(brush.copyWith(opacity: value));
                }
              },
              onChangeEnd: onBrushOpacityChangeEnd,
            ),
            InkCommandButton(
              icon: Icons.colorize,
              label: 'Eyedropper',
              onPressed: onEyedropper,
              hitSize: 48,
            ),
          ],
        ),
      ),
    );
  }

  Widget _slider(
    BuildContext context, {
    required String label,
    required double value,
    required double min,
    required double max,
    required String valueLabel,
    required bool enabled,
    required ValueChanged<double> onChanged,
    ValueChanged<double>? onChangeEnd,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          label: label,
          value: valueLabel,
          child: ExcludeSemantics(
            child: RotatedBox(
              quarterTurns: 3,
              child: SizedBox(
                width: 144,
                height: 40,
                child: Slider(
                  value: value,
                  min: min,
                  max: max,
                  onChanged: enabled ? onChanged : null,
                  onChangeEnd: enabled ? onChangeEnd : null,
                ),
              ),
            ),
          ),
        ),
        SizedBox(
          width: math.max(64, MediaQuery.textScalerOf(context).scale(64)),
          child: Text(
            valueLabel,
            maxLines: 1,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ),
      ],
    ),
  );
}

class CanvasToolPanel extends StatelessWidget {
  const CanvasToolPanel({
    super.key,
    required this.title,
    required this.onClose,
    required this.child,
    this.docked = false,
  });

  final String title;
  final VoidCallback onClose;
  final Widget child;
  final bool docked;

  @override
  Widget build(BuildContext context) {
    final panel = Column(
      children: [
        InkDockHeader(
          title: title,
          actions: [
            IconButton(
              tooltip: 'Close $title',
              onPressed: onClose,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        Expanded(child: child),
      ],
    );
    if (docked) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: inkColors(context).panel,
          border: Border(
            left: BorderSide(color: inkColors(context).panelBorder),
          ),
        ),
        child: ClipRect(child: panel),
      );
    }
    return Material(
      color: inkColors(context).panel,
      elevation: 8,
      borderRadius: BorderRadius.circular(inkMetrics(context).panelRadius),
      clipBehavior: Clip.antiAlias,
      child: panel,
    );
  }
}

class CanvasFocusQuickControls extends StatefulWidget {
  const CanvasFocusQuickControls({
    super.key,
    required this.brush,
    required this.color,
    required this.onUndo,
    required this.onRedo,
    required this.onBrushes,
    required this.onColor,
    required this.onChanged,
    required this.onSizeChangeEnd,
    required this.onOpacityChangeEnd,
  });

  final BrushPresetView brush;
  final Color color;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback onBrushes;
  final VoidCallback onColor;
  final ValueChanged<BrushPresetView> onChanged;
  final ValueChanged<double> onSizeChangeEnd;
  final VoidCallback onOpacityChangeEnd;

  @override
  State<CanvasFocusQuickControls> createState() => _FocusQuickControlsState();
}

class _FocusQuickControlsState extends State<CanvasFocusQuickControls> {
  late BrushPresetView _brush = widget.brush;

  double get _sizeSliderValue =>
      (math.log(_brush.size.clamp(0.25, 512) / 0.25) / math.log(512 / 0.25))
          .clamp(0.0, 1.0);

  double _sizeForSlider(double value) =>
      (0.25 * math.pow(512 / 0.25, value)).toDouble();

  void _update(BrushPresetView brush) {
    setState(() => _brush = brush);
    widget.onChanged(brush);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Focus controls', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: 8,
          children: [
            IconButton.filledTonal(
              tooltip: 'Undo',
              onPressed: widget.onUndo,
              icon: const Icon(Icons.undo),
            ),
            IconButton.filledTonal(
              tooltip: 'Redo',
              onPressed: widget.onRedo,
              icon: const Icon(Icons.redo),
            ),
            IconButton.filledTonal(
              tooltip: 'Brush library',
              onPressed: widget.onBrushes,
              icon: const Icon(Icons.brush),
            ),
            IconButton.filledTonal(
              tooltip: 'Main color',
              onPressed: widget.onColor,
              icon: Icon(Icons.circle, color: widget.color),
            ),
          ],
        ),
        Row(
          children: [
            const SizedBox(width: 64, child: Text('Size')),
            Expanded(
              child: Slider(
                value: _sizeSliderValue,
                onChanged:
                    (value) =>
                        _update(_brush.copyWith(size: _sizeForSlider(value))),
                onChangeEnd:
                    (value) => widget.onSizeChangeEnd(_sizeForSlider(value)),
              ),
            ),
            SizedBox(
              width: 64,
              child: Text('${_brush.size.toStringAsFixed(1)} px'),
            ),
          ],
        ),
        Row(
          children: [
            const SizedBox(width: 64, child: Text('Opacity')),
            Expanded(
              child: Slider(
                value: _brush.opacity,
                onChanged: (value) => _update(_brush.copyWith(opacity: value)),
                onChangeEnd: (_) => widget.onOpacityChangeEnd(),
              ),
            ),
            SizedBox(
              width: 64,
              child: Text('${(_brush.opacity * 100).round()}%'),
            ),
          ],
        ),
      ],
    ),
  );
}

class CanvasQuickMenu extends StatelessWidget {
  const CanvasQuickMenu({
    super.key,
    required this.eraserActive,
    required this.brush,
    required this.color,
    required this.onToggleEraser,
    required this.onFitCanvas,
    required this.onBrushes,
    required this.onBrushSizeChanged,
    required this.onBrushSizeChangeEnd,
    required this.onColor,
    required this.onClose,
  });

  final bool eraserActive;
  final BrushPresetView? brush;
  final Color color;
  final VoidCallback onToggleEraser;
  final VoidCallback onFitCanvas;
  final VoidCallback onBrushes;
  final ValueChanged<double> onBrushSizeChanged;
  final ValueChanged<double> onBrushSizeChangeEnd;
  final VoidCallback onColor;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final currentBrush = brush;
    final brushSize = currentBrush?.size ?? 12;
    const minSize = 0.25;
    const maxSize = 128.0;
    double sizeForSliderValue(double value) =>
        (minSize * math.pow(maxSize / minSize, value)).toDouble();
    final sliderValue = (math.log(brushSize.clamp(minSize, maxSize) / minSize) /
            math.log(maxSize / minSize))
        .clamp(0.0, 1.0);
    return Center(
      child: Card(
        elevation: 8,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              IconButton.filledTonal(
                onPressed: onBrushes,
                tooltip: currentBrush?.name ?? 'Choose brush',
                icon: const Icon(Icons.brush),
              ),
              SizedBox(
                width: 220,
                child: Row(
                  children: [
                    const Text('Size'),
                    Expanded(
                      child: Slider(
                        value: sliderValue,
                        onChanged:
                            currentBrush == null
                                ? null
                                : (value) => onBrushSizeChanged(
                                  sizeForSliderValue(value),
                                ),
                        onChangeEnd:
                            currentBrush == null
                                ? null
                                : (value) => onBrushSizeChangeEnd(
                                  sizeForSliderValue(value),
                                ),
                      ),
                    ),
                    Text(brushSize.toStringAsFixed(1)),
                  ],
                ),
              ),
              IconButton.filledTonal(
                onPressed: onColor,
                tooltip: 'Main color',
                icon: Icon(Icons.circle, color: color),
              ),
              IconButton.filledTonal(
                onPressed: onToggleEraser,
                tooltip: eraserActive ? 'Use brush' : 'Use eraser',
                icon: Icon(eraserActive ? Icons.brush : Icons.auto_fix_high),
              ),
              IconButton.filledTonal(
                onPressed: onFitCanvas,
                tooltip: 'Fit canvas',
                icon: const Icon(Icons.fit_screen),
              ),
              IconButton(
                onPressed: onClose,
                tooltip: 'Close quick menu',
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
