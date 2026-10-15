import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../bridge/engine_api.dart';
import '../layers/layer_panel_model.dart';
import '../tools/illustration_tools.dart';

/// Canvas state needed by Rust-backed raster and selection tool workflows.
class CanvasToolActionHost {
  const CanvasToolActionHost({
    required this.engine,
    required this.context,
    required this.mounted,
    required this.layers,
    required this.primaryLayerId,
    required this.activeTool,
    required this.setSelectionGeometryTool,
    required this.markDirty,
    required this.refreshTiles,
    this.activeColor,
    this.pickFillColor,
    this.showMessage,
  });

  final EngineApi Function() engine;
  final BuildContext Function() context;
  final bool Function() mounted;
  final List<LayerView> Function() layers;
  final int? Function() primaryLayerId;
  final IllustrationTool Function() activeTool;
  final void Function(IllustrationTool tool) setSelectionGeometryTool;
  final void Function() markDirty;
  final Future<void> Function() refreshTiles;
  final Color Function()? activeColor;
  final Future<Color?> Function(Color initialColor)? pickFillColor;
  final void Function(String message)? showMessage;
}

/// Owns selection, fill, and transform workflows for raster tool gestures.
class CanvasToolActions {
  const CanvasToolActions(this.host);

  final CanvasToolActionHost host;
  EngineApi get engine => host.engine();

  Future<void> chooseColorRange(int layerId) async {
    final red = TextEditingController(text: '0');
    final green = TextEditingController(text: '0');
    final blue = TextEditingController(text: '0');
    final tolerance = TextEditingController(text: '80');
    final accepted = await showDialog<String>(
      context: host.context(),
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('Select color range'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  boundedNumberField('Red', red),
                  boundedNumberField('Green', green),
                  boundedNumberField('Blue', blue),
                  boundedNumberField('Tolerance', tolerance),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, 'cancel'),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, 'gradient'),
                child: const Text('Gradient'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, 'fill'),
                child: const Text('Select'),
              ),
            ],
          ),
    );
    if ((accepted != 'fill' && accepted != 'gradient') || !host.mounted()) {
      for (final controller in [red, green, blue, tolerance]) {
        controller.dispose();
      }
      return;
    }
    final values = [red, green, blue, tolerance]
        .map((controller) => int.tryParse(controller.text.trim()))
        .toList(growable: false);
    if (values.any((value) => value == null)) {
      for (final controller in [red, green, blue, tolerance]) {
        controller.dispose();
      }
      return;
    }
    final r = values[0]!.clamp(0, 255);
    final g = values[1]!.clamp(0, 255);
    final b = values[2]!.clamp(0, 255);
    final t = values[3]!.clamp(0, 1020);
    for (final controller in [red, green, blue, tolerance]) {
      controller.dispose();
    }
    try {
      await engine.selectColorRange(
        layerId: layerId,
        red: r,
        green: g,
        blue: b,
        alpha: 255,
        tolerance: t,
      );
      if (host.mounted()) host.setSelectionGeometryTool(host.activeTool());
    } catch (error, stack) {
      debugPrint('Project Ink color range selection failed: $error\n$stack');
    }
  }

  Future<void> chooseFill(Offset position, int layerId) async {
    final initialColor = host.activeColor?.call() ?? Colors.black;
    final initialArgb = initialColor.toARGB32();
    var red = ((initialArgb >> 16) & 0xff).toString();
    var green = ((initialArgb >> 8) & 0xff).toString();
    var blue = (initialArgb & 0xff).toString();
    var tolerance = '12';
    var gap = '0';
    var fillColor = initialColor;
    var colorRevision = 0;
    List<int>? acceptedValues;
    var acceptedColor = initialColor;
    var validationMessage = _fillValidationMessage(
      red,
      green,
      blue,
      tolerance,
      gap,
    );
    final accepted = await showDialog<String>(
      context: host.context(),
      builder:
          (dialogContext) => StatefulBuilder(
            builder: (dialogContext, setDialogState) {
              void updatePreview() {
                final r = int.tryParse(red);
                final g = int.tryParse(green);
                final b = int.tryParse(blue);
                final message = _fillValidationMessage(
                  red,
                  green,
                  blue,
                  tolerance,
                  gap,
                );
                setDialogState(() {
                  validationMessage = message;
                  if (r != null &&
                      g != null &&
                      b != null &&
                      r >= 0 &&
                      r <= 255 &&
                      g >= 0 &&
                      g <= 255 &&
                      b >= 0 &&
                      b <= 255) {
                    fillColor = Color.fromARGB(
                      _alphaChannel(fillColor),
                      r,
                      g,
                      b,
                    );
                  }
                });
              }

              Future<void> chooseColor() async {
                final picker = host.pickFillColor;
                if (picker == null) return;
                final selected = await picker(fillColor);
                if (!dialogContext.mounted || selected == null) return;
                setDialogState(() {
                  fillColor = selected;
                  final argb = selected.toARGB32();
                  red = ((argb >> 16) & 0xff).toString();
                  green = ((argb >> 8) & 0xff).toString();
                  blue = (argb & 0xff).toString();
                  colorRevision++;
                  validationMessage = _fillValidationMessage(
                    red,
                    green,
                    blue,
                    tolerance,
                    gap,
                  );
                });
              }

              void finish(String operation) {
                acceptedValues = [red, green, blue, tolerance, gap]
                    .map((value) => int.parse(value.trim()))
                    .toList(growable: false);
                acceptedColor = fillColor;
                Navigator.pop(dialogContext, operation);
              }

              return AlertDialog(
                title: const Text('Bucket fill'),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Container(
                            key: const ValueKey<String>('fill-color-swatch'),
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              color: fillColor,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color:
                                    Theme.of(dialogContext).colorScheme.outline,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Expanded(child: Text('Fill color')),
                          TextButton.icon(
                            onPressed:
                                host.pickFillColor == null ? null : chooseColor,
                            icon: const Icon(Icons.color_lens_outlined),
                            label: const Text('Choose'),
                          ),
                        ],
                      ),
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: EdgeInsets.only(bottom: 8),
                          child: Text(
                            'Fills connected pixels on this layer. Tolerance matches nearby colors; gap closing seals small breaks.',
                          ),
                        ),
                      ),
                      _fillNumberField(
                        'Red',
                        red,
                        key: ValueKey<String>('fill-red-$colorRevision'),
                        onChanged: (value) {
                          red = value;
                          updatePreview();
                        },
                      ),
                      _fillNumberField(
                        'Green',
                        green,
                        key: ValueKey<String>('fill-green-$colorRevision'),
                        onChanged: (value) {
                          green = value;
                          updatePreview();
                        },
                      ),
                      _fillNumberField(
                        'Blue',
                        blue,
                        key: ValueKey<String>('fill-blue-$colorRevision'),
                        onChanged: (value) {
                          blue = value;
                          updatePreview();
                        },
                      ),
                      _fillNumberField(
                        'Tolerance',
                        tolerance,
                        key: ValueKey<String>('fill-tolerance-$colorRevision'),
                        onChanged: (value) {
                          tolerance = value;
                          updatePreview();
                        },
                      ),
                      _fillNumberField(
                        'Gap closing (0–4)',
                        gap,
                        key: ValueKey<String>('fill-gap-$colorRevision'),
                        onChanged: (value) {
                          gap = value;
                          updatePreview();
                        },
                      ),
                      if (validationMessage != null)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              validationMessage!,
                              style: Theme.of(
                                dialogContext,
                              ).textTheme.bodySmall?.copyWith(
                                color:
                                    Theme.of(dialogContext).colorScheme.error,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('Cancel'),
                  ),
                  TextButton(
                    onPressed:
                        validationMessage == null
                            ? () => finish('gradient')
                            : null,
                    child: const Text('Gradient'),
                  ),
                  FilledButton(
                    onPressed:
                        validationMessage == null ? () => finish('fill') : null,
                    child: const Text('Fill'),
                  ),
                ],
              );
            },
          ),
    );
    if ((accepted != 'fill' && accepted != 'gradient') ||
        acceptedValues == null ||
        !host.mounted()) {
      return;
    }
    final values = acceptedValues!;
    try {
      final x = position.dx.round().clamp(0, engine.documentInfo.widthPx - 1);
      final y = position.dy.round().clamp(0, engine.documentInfo.heightPx - 1);
      if (accepted == 'gradient') {
        await engine.gradientFill(
          layerId: layerId,
          x: x,
          y: y,
          startX: position.dx,
          startY: position.dy,
          endX: position.dx + 128,
          endY: position.dy,
          fromRed: values[0],
          fromGreen: values[1],
          fromBlue: values[2],
          fromAlpha: _alphaChannel(acceptedColor),
          toRed: 255,
          toGreen: 255,
          toBlue: 255,
          toAlpha: 255,
          tolerance: values[3],
          gap: values[4],
          expansion: 0,
          paintInside: false,
          paintUnfilled: false,
        );
      } else {
        await engine.fillRegion(
          layerId: layerId,
          x: x,
          y: y,
          red: values[0],
          green: values[1],
          blue: values[2],
          alpha: _alphaChannel(acceptedColor),
          tolerance: values[3],
          gap: values[4],
        );
      }
      host.markDirty();
      unawaited(host.refreshTiles());
    } catch (error, stack) {
      debugPrint('Project Ink bucket fill failed: $error\n$stack');
      _showFillFeedback(
        'The fill could not be applied. Check the selected layer and try again.',
      );
    }
  }

  void _showFillFeedback(String message) {
    final showMessage = host.showMessage;
    if (showMessage != null) {
      showMessage(message);
      return;
    }
    final context = host.context();
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  int _alphaChannel(Color color) => (color.a * 255).round().clamp(0, 255);

  String? _fillValidationMessage(
    String red,
    String green,
    String blue,
    String tolerance,
    String gap,
  ) {
    final values = [
      red,
      green,
      blue,
      tolerance,
      gap,
    ].map((value) => int.tryParse(value.trim())).toList(growable: false);
    if (values.any((value) => value == null)) {
      return 'Enter whole numbers for color, tolerance, and gap closing.';
    }
    if (values[0]! < 0 ||
        values[0]! > 255 ||
        values[1]! < 0 ||
        values[1]! > 255 ||
        values[2]! < 0 ||
        values[2]! > 255 ||
        values[3]! < 0 ||
        values[3]! > 1020 ||
        values[4]! < 0 ||
        values[4]! > 4) {
      return 'Use RGB values from 0–255, tolerance from 0–1020, and gap from 0–4.';
    }
    return null;
  }

  Widget _fillNumberField(
    String label,
    String initialValue, {
    required Key key,
    required ValueChanged<String> onChanged,
  }) => TextFormField(
    key: key,
    initialValue: initialValue,
    keyboardType: const TextInputType.numberWithOptions(decimal: false),
    onChanged: onChanged,
    decoration: InputDecoration(labelText: label),
  );

  Widget boundedNumberField(
    String label,
    TextEditingController controller, {
    ValueChanged<String>? onChanged,
  }) => TextField(
    controller: controller,
    keyboardType: const TextInputType.numberWithOptions(decimal: false),
    onChanged: onChanged,
    decoration: InputDecoration(labelText: label),
  );

  Future<void> chooseMeshTransform(Rect rect, int layerId) async {
    final columns = TextEditingController(text: '2');
    final rows = TextEditingController(text: '2');
    final points = TextEditingController(
      text:
          '${rect.left},${rect.top};${rect.right},${rect.top};${rect.left},${rect.bottom};${rect.right},${rect.bottom}',
    );
    final accepted = await showDialog<bool>(
      context: host.context(),
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('Mesh transform'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  boundedNumberField('Columns (2–32)', columns),
                  boundedNumberField('Rows (2–32)', rows),
                  TextField(
                    controller: points,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: 'Control points (x,y; x,y; …)',
                      helperText: 'Row-major; count must equal columns × rows.',
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Apply'),
              ),
            ],
          ),
    );
    if (accepted != true || !host.mounted()) {
      columns.dispose();
      rows.dispose();
      points.dispose();
      return;
    }
    final columnCount = int.tryParse(columns.text.trim());
    final rowCount = int.tryParse(rows.text.trim());
    final parsed = points.text
        .split(';')
        .map(
          (pair) => pair
              .split(',')
              .map((value) => double.tryParse(value.trim()))
              .toList(growable: false),
        )
        .toList(growable: false);
    columns.dispose();
    rows.dispose();
    points.dispose();
    if (columnCount == null ||
        rowCount == null ||
        columnCount < 2 ||
        columnCount > 32 ||
        rowCount < 2 ||
        rowCount > 32 ||
        parsed.length != columnCount * rowCount ||
        parsed.any(
          (pair) =>
              pair.length != 2 ||
              pair.any((value) => value == null || !value.isFinite),
        )) {
      if (host.mounted()) {
        ScaffoldMessenger.of(host.context()).showSnackBar(
          const SnackBar(
            content: Text('Mesh points do not match the requested grid.'),
          ),
        );
      }
      return;
    }
    await engine.meshLayer(
      layerId: layerId,
      columns: columnCount,
      rows: rowCount,
      points: parsed
          .expand((pair) => [pair[0]!, pair[1]!])
          .toList(growable: false),
    );
  }

  Future<void> chooseLiquify(
    Offset center,
    Offset delta,
    double radius,
    int layerId,
  ) async {
    final strength = TextEditingController(text: '0.5');
    var mode = 0;
    final accepted = await showDialog<bool>(
      context: host.context(),
      builder:
          (dialogContext) => StatefulBuilder(
            builder:
                (context, setDialogState) => AlertDialog(
                  title: const Text('Liquify'),
                  content: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        DropdownButtonFormField<int>(
                          initialValue: mode,
                          items: const [
                            DropdownMenuItem(value: 0, child: Text('Push')),
                            DropdownMenuItem(value: 1, child: Text('Expand')),
                            DropdownMenuItem(value: 2, child: Text('Contract')),
                            DropdownMenuItem(value: 3, child: Text('Twirl')),
                          ],
                          onChanged:
                              (value) =>
                                  setDialogState(() => mode = value ?? 0),
                          decoration: const InputDecoration(labelText: 'Mode'),
                        ),
                        boundedNumberField('Strength (-1 to 1)', strength),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(dialogContext, true),
                      child: const Text('Apply'),
                    ),
                  ],
                ),
          ),
    );
    if (accepted != true || !host.mounted()) {
      strength.dispose();
      return;
    }
    final value = double.tryParse(strength.text.trim());
    strength.dispose();
    if (value == null || !value.isFinite || value < -1 || value > 1) return;
    await engine.liquifyLayer(
      layerId: layerId,
      centerX: center.dx,
      centerY: center.dy,
      radius: radius,
      strength: value,
      mode: mode,
      directionX: delta.dx,
      directionY: delta.dy,
    );
  }

  Future<void> applyTransformPreset(TransformPreset preset) async {
    final layerId = requireSelectedRasterLayer(action: 'transform');
    if (layerId == null) return;
    final center = Offset(
      engine.documentInfo.widthPx / 2,
      engine.documentInfo.heightPx / 2,
    );
    final radians = switch (preset) {
      TransformPreset.rotateLeft => -math.pi / 12,
      TransformPreset.rotateRight => math.pi / 12,
      TransformPreset.scaleUp || TransformPreset.scaleDown => 0,
    };
    final scale = switch (preset) {
      TransformPreset.scaleUp => 1.1,
      TransformPreset.scaleDown => 0.9,
      _ => 1.0,
    };
    final a = math.cos(radians) * scale;
    final b = math.sin(radians) * scale;
    final c = -math.sin(radians) * scale;
    final d = math.cos(radians) * scale;
    try {
      await engine.transformLayer(
        layerId: layerId,
        a: a,
        b: b,
        c: c,
        d: d,
        tx: center.dx - a * center.dx - c * center.dy,
        ty: center.dy - b * center.dx - d * center.dy,
      );
      host.markDirty();
      unawaited(host.refreshTiles());
    } catch (error, stack) {
      debugPrint('Project Ink transform failed: $error\n$stack');
    }
  }

  int? requireSelectedRasterLayer({required String action}) {
    final primaryId = host.primaryLayerId();
    final layer =
        primaryId == null
            ? null
            : host.layers().where((value) => value.id == primaryId).firstOrNull;
    String? reason;
    if (layer == null) {
      reason = 'Select a paint layer before you $action.';
    } else if (layer.kind != LayerKind.raster) {
      reason = '“${layer.name}” cannot be used to $action with this tool.';
    } else if (!layerEffectivelyVisible(layer)) {
      reason = '“${layer.name}” or one of its groups is hidden.';
    }
    if (reason != null) {
      if (host.mounted()) {
        ScaffoldMessenger.of(
          host.context(),
        ).showSnackBar(SnackBar(content: Text(reason)));
      }
      return null;
    }
    return layer!.id;
  }

  bool layerEffectivelyVisible(LayerView layer) {
    final byId = {for (final value in host.layers()) value.id: value};
    final visited = <int>{};
    var current = layer;
    while (true) {
      if (!current.visible || !visited.add(current.id)) return false;
      final parentId = current.parent;
      if (parentId == null) return true;
      final parent = byId[parentId];
      if (parent == null) return false;
      current = parent;
    }
  }
}
