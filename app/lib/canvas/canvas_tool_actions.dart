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
    final red = TextEditingController(text: '255');
    final green = TextEditingController(text: '128');
    final blue = TextEditingController(text: '0');
    final tolerance = TextEditingController(text: '12');
    final gap = TextEditingController(text: '0');
    final accepted = await showDialog<String>(
      context: host.context(),
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('Bucket fill'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  boundedNumberField('Red', red),
                  boundedNumberField('Green', green),
                  boundedNumberField('Blue', blue),
                  boundedNumberField('Tolerance', tolerance),
                  boundedNumberField('Gap closing (0–4)', gap),
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
                child: const Text('Fill'),
              ),
            ],
          ),
    );
    final controllers = [red, green, blue, tolerance, gap];
    if ((accepted != 'fill' && accepted != 'gradient') || !host.mounted()) {
      for (final controller in controllers) {
        controller.dispose();
      }
      return;
    }
    final values = controllers
        .map((controller) => int.tryParse(controller.text.trim()))
        .toList(growable: false);
    for (final controller in controllers) {
      controller.dispose();
    }
    if (values.any((value) => value == null)) return;
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
          fromRed: values[0]!.clamp(0, 255),
          fromGreen: values[1]!.clamp(0, 255),
          fromBlue: values[2]!.clamp(0, 255),
          fromAlpha: 255,
          toRed: 255,
          toGreen: 255,
          toBlue: 255,
          toAlpha: 255,
          tolerance: values[3]!.clamp(0, 1020),
          gap: values[4]!.clamp(0, 4),
          expansion: 0,
          paintInside: false,
          paintUnfilled: false,
        );
      } else {
        await engine.fillRegion(
          layerId: layerId,
          x: x,
          y: y,
          red: values[0]!.clamp(0, 255),
          green: values[1]!.clamp(0, 255),
          blue: values[2]!.clamp(0, 255),
          alpha: 255,
          tolerance: values[3]!.clamp(0, 1020),
          gap: values[4]!.clamp(0, 4),
        );
      }
      host.markDirty();
      unawaited(host.refreshTiles());
    } catch (error, stack) {
      debugPrint('Project Ink bucket fill failed: $error\n$stack');
    }
  }

  Widget boundedNumberField(String label, TextEditingController controller) =>
      TextField(
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: false),
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
