import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../design_system/ink_components.dart';
import '../tools/brush_library.dart';

class CanvasSimpleEdgeControls extends StatelessWidget {
  const CanvasSimpleEdgeControls({
    super.key,
    required this.selectedBrush,
    required this.brushToolActive,
    required this.eraserActive,
    required this.onBrushChanged,
    required this.onBrushSizeChangeEnd,
    required this.onBrushOpacityChangeEnd,
    required this.onEyedropper,
    required this.onTools,
    required this.onBrushes,
    required this.onSelectBrush,
    required this.onLayers,
    required this.activeColor,
    required this.subColor,
    required this.transparentColorActive,
    required this.onMainColor,
    required this.onTransparentColor,
    required this.onSelectEraser,
    this.compactPhone = false,
  });

  final BrushPresetView? selectedBrush;
  final bool brushToolActive;
  final bool eraserActive;
  final ValueChanged<BrushPresetView> onBrushChanged;
  final ValueChanged<double> onBrushSizeChangeEnd;
  final ValueChanged<double> onBrushOpacityChangeEnd;
  final VoidCallback onEyedropper;
  final VoidCallback onTools;
  final VoidCallback onBrushes;
  final VoidCallback onSelectBrush;
  final VoidCallback onLayers;
  final Color activeColor;
  final Color subColor;
  final bool transparentColorActive;
  final VoidCallback onMainColor;
  final VoidCallback onTransparentColor;
  final VoidCallback onSelectEraser;
  final bool compactPhone;

  static const _minimumBrushSize = 0.25;
  static const _maximumBrushSize = 512.0;

  double _sizeSliderValue(double size) => (math.log(
            size.clamp(_minimumBrushSize, _maximumBrushSize) /
                _minimumBrushSize,
          ) /
          math.log(_maximumBrushSize / _minimumBrushSize))
      .clamp(0.0, 1.0);

  double _brushSizeForSlider(double value) =>
      (_minimumBrushSize *
              math.pow(_maximumBrushSize / _minimumBrushSize, value))
          .toDouble();

  @override
  Widget build(BuildContext context) {
    final brush = selectedBrush;
    final useSliderSheets =
        compactPhone ||
        MediaQuery.sizeOf(context).height < 560 ||
        MediaQuery.textScalerOf(context).scale(1) > 1.4;
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
              icon: Icons.build_outlined,
              label: 'Draw tools',
              onPressed: onTools,
              hitSize: 48,
            ),
            InkCommandButton(
              icon: Icons.brush,
              label: brushToolActive ? 'Brush presets' : 'Brush',
              selected: brushToolActive,
              onPressed: brushToolActive ? onBrushes : onSelectBrush,
              hitSize: 48,
            ),
            InkCommandButton(
              icon: Icons.cleaning_services,
              label: eraserActive ? 'Eraser brush presets' : 'Eraser',
              selected: eraserActive,
              onPressed: eraserActive ? onBrushes : onSelectEraser,
              hitSize: 48,
            ),
            InkCommandButton(
              icon: Icons.layers,
              label: 'Layers',
              onPressed: onLayers,
              hitSize: 48,
            ),
            Semantics(
              button: true,
              label: 'Color selector',
              value:
                  'Main ${_colorLabel(activeColor)}, sub ${_colorLabel(subColor)}',
              onTap: onMainColor,
              child: ExcludeSemantics(
                child: Tooltip(
                  message: 'Color selector',
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: onMainColor,
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        width: 56,
                        height: 48,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Container(
                              width: 26,
                              height: 26,
                              decoration: BoxDecoration(
                                color: activeColor,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: inkColors(context).panelBorder,
                                ),
                              ),
                              child: Icon(
                                Icons.palette_outlined,
                                size: 17,
                                color:
                                    activeColor.computeLuminance() > 0.5
                                        ? Colors.black
                                        : Colors.white,
                              ),
                            ),
                            Positioned(
                              right: 8,
                              bottom: 4,
                              child: Container(
                                width: 12,
                                height: 12,
                                decoration: BoxDecoration(
                                  color: subColor,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: inkColors(context).panel,
                                    width: 1.5,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            InkCommandButton(
              icon: Icons.invert_colors,
              label: 'Transparent paint',
              selected: transparentColorActive,
              onPressed: onTransparentColor,
              hitSize: 48,
            ),
            if (useSliderSheets && brush != null)
              _StudioControlButton(
                label: 'Brush size',
                value: '${brush.size.toStringAsFixed(1)} px',
                displayValue: '${brush.size.round()} px',
                compact: compactPhone,
                onPressed:
                    () => showCanvasBrushAdjustmentSheet(
                      context,
                      brush: brush,
                      size: true,
                      onBrushChanged: onBrushChanged,
                      onChangeEnd: onBrushSizeChangeEnd,
                    ),
                child: const Icon(Icons.line_weight),
              )
            else
              _slider(
                context,
                label: 'Brush size',
                value: _sizeSliderValue(brush?.size ?? 12),
                min: 0,
                max: 1,
                valueLabel:
                    brush == null ? '—' : '${brush.size.toStringAsFixed(1)} px',
                enabled: brush != null,
                onChanged: (value) {
                  if (brush != null) {
                    onBrushChanged(
                      brush.copyWith(size: _brushSizeForSlider(value)),
                    );
                  }
                },
                onChangeEnd:
                    (value) => onBrushSizeChangeEnd(_brushSizeForSlider(value)),
                semanticFormatter:
                    (value) =>
                        '${_brushSizeForSlider(value).toStringAsFixed(1)} pixels',
              ),
            if (useSliderSheets && brush != null)
              _StudioControlButton(
                label: 'Brush opacity',
                value: '${(brush.opacity * 100).round()}%',
                compact: compactPhone,
                onPressed:
                    () => showCanvasBrushAdjustmentSheet(
                      context,
                      brush: brush,
                      size: false,
                      onBrushChanged: onBrushChanged,
                      onChangeEnd: onBrushOpacityChangeEnd,
                    ),
                child: const Icon(Icons.opacity),
              )
            else
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
                semanticFormatter:
                    (value) => '${(value * 100).round()} percent',
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
    String Function(double)? semanticFormatter,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label == 'Brush opacity' ? 'Opacity' : 'Size',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall,
        ),
        Semantics(
          label: label,
          child: RotatedBox(
            quarterTurns: 3,
            child: SizedBox(
              width: 144,
              height: 48,
              child: Slider(
                value: value,
                min: min,
                max: max,
                semanticFormatterCallback: semanticFormatter,
                onChanged: enabled ? onChanged : null,
                onChangeEnd: enabled ? onChangeEnd : null,
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

  String _colorLabel(Color color) =>
      '#${color.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';
}

Future<void> showCanvasBrushAdjustmentSheet(
  BuildContext context, {
  required BrushPresetView brush,
  required bool size,
  required ValueChanged<BrushPresetView> onBrushChanged,
  required ValueChanged<double> onChangeEnd,
}) async {
  const minimumSize = 0.25;
  const maximumSize = 512.0;
  double sliderValue(double brushSize) =>
      (math.log(brushSize.clamp(minimumSize, maximumSize) / minimumSize) /
              math.log(maximumSize / minimumSize))
          .clamp(0.0, 1.0);
  double brushSize(double sliderValue) =>
      (minimumSize * math.pow(maximumSize / minimumSize, sliderValue))
          .toDouble();
  var current =
      size
          ? brush.size.clamp(minimumSize, maximumSize).toDouble()
          : brush.opacity.clamp(0.0, 1.0).toDouble();
  final title = size ? 'Brush size' : 'Brush opacity';
  await showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    builder:
        (sheetContext) => StatefulBuilder(
          builder:
              (context, setSheetState) => Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Close ${title.toLowerCase()}',
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    Text(
                      size
                          ? '${current.toStringAsFixed(1)} px'
                          : '${(current * 100).round()}%',
                    ),
                    Semantics(
                      label: title,
                      child: Slider(
                        semanticFormatterCallback:
                            (value) =>
                                size
                                    ? '${brushSize(value).toStringAsFixed(1)} pixels'
                                    : '${(value * 100).round()} percent',
                        value: size ? sliderValue(current) : current,
                        min: 0,
                        max: 1,
                        onChanged: (value) {
                          final next = size ? brushSize(value) : value;
                          setSheetState(() => current = next);
                          onBrushChanged(
                            size
                                ? brush.copyWith(size: next)
                                : brush.copyWith(opacity: next),
                          );
                        },
                        onChangeEnd:
                            (value) =>
                                onChangeEnd(size ? brushSize(value) : value),
                      ),
                    ),
                    Text(size ? '0.25 px to 512 px' : '0% to 100%'),
                  ],
                ),
              ),
        ),
  );
}

/// Keeps active color and the two most-used brush adjustments visible in
/// Studio while routing precise slider interaction through accessible sheets.
class CanvasStudioDrawingControls extends StatelessWidget {
  const CanvasStudioDrawingControls({
    super.key,
    required this.brush,
    required this.mainColor,
    required this.subColor,
    required this.onColor,
    required this.onBrushChanged,
    required this.onSizeChangeEnd,
    required this.onOpacityChangeEnd,
  });

  final BrushPresetView? brush;
  final Color mainColor;
  final Color subColor;
  final VoidCallback onColor;
  final ValueChanged<BrushPresetView> onBrushChanged;
  final ValueChanged<double> onSizeChangeEnd;
  final ValueChanged<double> onOpacityChangeEnd;

  static const _minimumSize = 0.25;
  static const _maximumSize = 512.0;

  double _sizeSliderValue(double size) =>
      (math.log(size.clamp(_minimumSize, _maximumSize) / _minimumSize) /
              math.log(_maximumSize / _minimumSize))
          .clamp(0.0, 1.0);

  double _sizeForSlider(double value) =>
      (_minimumSize * math.pow(_maximumSize / _minimumSize, value)).toDouble();

  String _colorLabel(Color color) =>
      '#${color.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';

  @override
  Widget build(BuildContext context) {
    final currentBrush = brush;
    final useSliderSheets =
        MediaQuery.sizeOf(context).height < 560 ||
        MediaQuery.textScalerOf(context).scale(1) > 1.4;
    return Material(
      color: inkColors(context).panel.withValues(alpha: 0.96),
      shape: RoundedRectangleBorder(
        side: BorderSide(color: inkColors(context).panelBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: SizedBox(
        width: 76,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _StudioControlButton(
                label: 'Color',
                value: 'Main ${_colorLabel(mainColor)}',
                displayValue: 'Color',
                onPressed: onColor,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: mainColor,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outline,
                          width: 2,
                        ),
                      ),
                    ),
                    Positioned(
                      right: 7,
                      bottom: 7,
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: subColor,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: inkColors(context).panel,
                            width: 1.5,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (currentBrush == null)
                const _StudioControlButton(
                  label: 'Brush size',
                  value: 'Unavailable',
                  onPressed: null,
                  child: Icon(Icons.line_weight),
                )
              else if (useSliderSheets)
                _StudioControlButton(
                  label: 'Brush size',
                  value: '${currentBrush.size.toStringAsFixed(1)} px',
                  displayValue:
                      MediaQuery.textScalerOf(context).scale(1) > 1.4
                          ? currentBrush.size.toStringAsFixed(1)
                          : '${currentBrush.size.toStringAsFixed(1)} px',
                  onPressed: () => _showSizeSheet(context),
                  child: const Icon(Icons.line_weight),
                )
              else
                _StudioVerticalSlider(
                  label: 'Brush size',
                  valueLabel: '${currentBrush.size.toStringAsFixed(1)} px',
                  value: _sizeSliderValue(currentBrush.size),
                  formatter:
                      (value) =>
                          '${_sizeForSlider(value).toStringAsFixed(1)} pixels',
                  onChanged:
                      (value) => onBrushChanged(
                        currentBrush.copyWith(size: _sizeForSlider(value)),
                      ),
                  onChangeEnd:
                      (value) => onSizeChangeEnd(_sizeForSlider(value)),
                ),
              if (currentBrush == null)
                const _StudioControlButton(
                  label: 'Brush opacity',
                  value: 'Unavailable',
                  onPressed: null,
                  child: Icon(Icons.opacity),
                )
              else if (useSliderSheets)
                _StudioControlButton(
                  label: 'Brush opacity',
                  value: '${(currentBrush.opacity * 100).round()}%',
                  onPressed: () => _showOpacitySheet(context),
                  child: const Icon(Icons.opacity),
                )
              else
                _StudioVerticalSlider(
                  label: 'Brush opacity',
                  valueLabel: '${(currentBrush.opacity * 100).round()}%',
                  value: currentBrush.opacity,
                  formatter: (value) => '${(value * 100).round()} percent',
                  onChanged:
                      (value) =>
                          onBrushChanged(currentBrush.copyWith(opacity: value)),
                  onChangeEnd: onOpacityChangeEnd,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showSizeSheet(BuildContext context) async {
    final currentBrush = brush;
    if (currentBrush == null) return;
    var currentSize =
        currentBrush.size.clamp(_minimumSize, _maximumSize).toDouble();
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder:
          (sheetContext) => StatefulBuilder(
            builder:
                (context, setSheetState) => Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Brush size',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          IconButton(
                            tooltip: 'Close brush size',
                            onPressed: () => Navigator.of(context).pop(),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                      Text('${currentSize.toStringAsFixed(1)} px'),
                      Semantics(
                        label: 'Brush size',
                        child: Slider(
                          semanticFormatterCallback:
                              (value) =>
                                  '${_sizeForSlider(value).toStringAsFixed(1)} pixels',
                          value: _sizeSliderValue(currentSize),
                          min: 0,
                          max: 1,
                          onChanged: (value) {
                            final size = _sizeForSlider(value);
                            setSheetState(() => currentSize = size);
                            onBrushChanged(currentBrush.copyWith(size: size));
                          },
                          onChangeEnd:
                              (value) => onSizeChangeEnd(_sizeForSlider(value)),
                        ),
                      ),
                      const Text('0.25 px to 512 px'),
                    ],
                  ),
                ),
          ),
    );
  }

  Future<void> _showOpacitySheet(BuildContext context) async {
    final currentBrush = brush;
    if (currentBrush == null) return;
    var currentOpacity = currentBrush.opacity.clamp(0.0, 1.0).toDouble();
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder:
          (sheetContext) => StatefulBuilder(
            builder:
                (context, setSheetState) => Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Brush opacity',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          IconButton(
                            tooltip: 'Close brush opacity',
                            onPressed: () => Navigator.of(context).pop(),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                      Text('${(currentOpacity * 100).round()}%'),
                      Semantics(
                        label: 'Brush opacity',
                        child: Slider(
                          semanticFormatterCallback:
                              (value) => '${(value * 100).round()} percent',
                          value: currentOpacity,
                          min: 0,
                          max: 1,
                          onChanged: (value) {
                            setSheetState(() => currentOpacity = value);
                            onBrushChanged(
                              currentBrush.copyWith(opacity: value),
                            );
                          },
                          onChangeEnd: onOpacityChangeEnd,
                        ),
                      ),
                      const Text('0% to 100%'),
                    ],
                  ),
                ),
          ),
    );
  }
}

class _StudioVerticalSlider extends StatelessWidget {
  const _StudioVerticalSlider({
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.formatter,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final String label;
  final String valueLabel;
  final double value;
  final String Function(double) formatter;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 72,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label == 'Brush size' ? 'Size' : 'Opacity',
          style: Theme.of(context).textTheme.labelSmall,
        ),
        Semantics(
          label: label,
          child: RotatedBox(
            quarterTurns: 3,
            child: SizedBox(
              width: 136,
              height: 48,
              child: Slider(
                value: value.clamp(0.0, 1.0).toDouble(),
                min: 0,
                max: 1,
                semanticFormatterCallback: formatter,
                onChanged: onChanged,
                onChangeEnd: onChangeEnd,
              ),
            ),
          ),
        ),
        Text(
          valueLabel,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ],
    ),
  );
}

class _StudioControlButton extends StatelessWidget {
  const _StudioControlButton({
    required this.label,
    required this.value,
    required this.onPressed,
    required this.child,
    this.displayValue,
    this.compact = false,
  });

  final String label;
  final String value;
  final VoidCallback? onPressed;
  final Widget child;
  final String? displayValue;
  final bool compact;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: onPressed != null,
    label: label,
    value: value,
    onTap: onPressed,
    child: ExcludeSemantics(
      child: Tooltip(
        message: '$label: $value',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: compact ? 56 : 72,
              height: compact ? 56 : 68,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(width: 36, height: 32, child: Center(child: child)),
                  Text(
                    displayValue ?? value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
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
              child: Semantics(
                label: 'Brush size',
                child: Slider(
                  value: _sizeSliderValue,
                  semanticFormatterCallback:
                      (value) =>
                          '${_sizeForSlider(value).toStringAsFixed(1)} pixels',
                  onChanged:
                      (value) =>
                          _update(_brush.copyWith(size: _sizeForSlider(value))),
                  onChangeEnd:
                      (value) => widget.onSizeChangeEnd(_sizeForSlider(value)),
                ),
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
              child: Semantics(
                label: 'Brush opacity',
                child: Slider(
                  value: _brush.opacity,
                  semanticFormatterCallback:
                      (value) => '${(value * 100).round()} percent',
                  onChanged:
                      (value) => _update(_brush.copyWith(opacity: value)),
                  onChangeEnd: (_) => widget.onOpacityChangeEnd(),
                ),
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
