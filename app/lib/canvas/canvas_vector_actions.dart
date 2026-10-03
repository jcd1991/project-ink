import 'dart:async';

import 'package:flutter/material.dart';

import '../bridge/engine_api.dart';

/// Vector mutations initiated by pointer-driven canvas tools.
abstract interface class CanvasVectorToolOperations {
  Future<void> addStroke(List<double> points);
  Future<void> transformFirstStroke(Offset delta);
  Future<void> eraseFirstStroke({
    required Offset center,
    required double radius,
  });
}

/// Active-session inputs for Rust-backed vector editing actions.
class CanvasVectorActionHost {
  const CanvasVectorActionHost({
    required this.engine,
    required this.context,
    required this.mounted,
    required this.engineGeneration,
    required this.selectedLayerId,
    required this.onStrokesChanged,
    required this.markDirty,
    required this.refreshTiles,
  });

  final EngineApi Function() engine;
  final BuildContext Function() context;
  final bool Function() mounted;
  final int Function() engineGeneration;
  final int? Function() selectedLayerId;
  final void Function() onStrokesChanged;
  final void Function() markDirty;
  final Future<void> Function() refreshTiles;
}

/// Owns the selected vector projection and Rust vector edit workflows.
class CanvasVectorActions implements CanvasVectorToolOperations {
  CanvasVectorActions(this.host);

  final CanvasVectorActionHost host;
  List<VectorStrokeSummaryView> _strokes = const [];

  List<VectorStrokeSummaryView> get strokes => _strokes;

  @override
  Future<void> addStroke(List<double> points) async {
    final layerId = host.selectedLayerId();
    if (layerId == null || points.length < 4) {
      if (host.mounted()) {
        ScaffoldMessenger.of(host.context()).showSnackBar(
          const SnackBar(
            content: Text('Add a vector layer before drawing vector ink.'),
          ),
        );
      }
      return;
    }
    await host.engine().addVectorStroke(
      layerId: layerId,
      points: points,
      closed: false,
    );
    host.markDirty();
  }

  @override
  Future<void> transformFirstStroke(Offset delta) async {
    final layerId = host.selectedLayerId();
    final stroke = _strokes.firstOrNull;
    if (stroke == null || layerId == null || delta.distance < 0.5) return;
    await host.engine().transformVectorStroke(
      layerId: layerId,
      strokeId: stroke.id,
      a: 1,
      b: 0,
      c: 0,
      d: 1,
      tx: delta.dx,
      ty: delta.dy,
    );
    await loadForSelection();
    host.markDirty();
  }

  @override
  Future<void> eraseFirstStroke({
    required Offset center,
    required double radius,
  }) async {
    final layerId = host.selectedLayerId();
    final stroke = _strokes.firstOrNull;
    if (stroke == null || layerId == null) return;
    await host.engine().eraseVectorSegment(
      layerId: layerId,
      strokeId: stroke.id,
      centerX: center.dx,
      centerY: center.dy,
      radius: radius,
    );
    await loadForSelection();
    host.markDirty();
  }

  void clearStrokes() {
    _strokes = const [];
  }

  Future<void> loadForSelection() async {
    final layerId = host.selectedLayerId();
    if (layerId == null) {
      clearStrokes();
      if (host.mounted()) host.onStrokesChanged();
      return;
    }
    final engine = host.engine();
    final generation = host.engineGeneration();
    try {
      final strokes = await engine.vectorStrokeSummaries(layerId: layerId);
      if (host.mounted() &&
          engine == host.engine() &&
          generation == host.engineGeneration() &&
          host.selectedLayerId() == layerId) {
        _strokes = strokes;
        host.onStrokesChanged();
      }
    } catch (error, stack) {
      debugPrint('Project Ink vector projection unavailable: $error\n$stack');
    }
  }

  Future<void> simplifySelected() async {
    final layerId = host.selectedLayerId();
    final stroke = _strokes.firstOrNull;
    if (layerId == null || stroke == null) return;
    try {
      await host.engine().simplifyVectorStroke(
        layerId: layerId,
        strokeId: stroke.id,
        tolerance: 1.0,
      );
      await loadForSelection();
      host.markDirty();
    } catch (error, stack) {
      debugPrint('Project Ink vector simplify rejected: $error\n$stack');
    }
  }

  Future<void> connectFirstTwo() async {
    final layerId = host.selectedLayerId();
    if (layerId == null || _strokes.length < 2) return;
    try {
      await host.engine().connectVectorStrokes(
        layerId: layerId,
        firstId: _strokes[0].id,
        secondId: _strokes[1].id,
        tolerance: 8.0,
      );
      await loadForSelection();
      host.markDirty();
    } catch (error, stack) {
      debugPrint('Project Ink vector connect rejected: $error\n$stack');
    }
  }

  Future<void> editFirstPoint() async {
    final layerId = host.selectedLayerId();
    final stroke = _strokes.firstOrNull;
    if (layerId == null || stroke == null || stroke.points.length < 4) return;
    final x = TextEditingController(text: stroke.points[0].toStringAsFixed(2));
    final y = TextEditingController(text: stroke.points[1].toStringAsFixed(2));
    final pressure = TextEditingController(
      text: stroke.points[2].toStringAsFixed(3),
    );
    final tilt = TextEditingController(
      text: stroke.points[3].toStringAsFixed(3),
    );
    final accepted = await showDialog<bool>(
      context: host.context(),
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('Edit vector control point'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _boundedNumberField('X', x),
                  _boundedNumberField('Y', y),
                  _boundedNumberField('Pressure (0–1)', pressure),
                  _boundedNumberField('Tilt', tilt),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Apply'),
              ),
            ],
          ),
    );
    final controllers = [x, y, pressure, tilt];
    if (accepted != true || !host.mounted()) {
      for (final controller in controllers) {
        controller.dispose();
      }
      return;
    }
    final values = controllers
        .map((controller) => double.tryParse(controller.text.trim()))
        .toList(growable: false);
    for (final controller in controllers) {
      controller.dispose();
    }
    if (values.any((value) => value == null || !value.isFinite)) return;
    try {
      await host.engine().setVectorPoint(
        layerId: layerId,
        strokeId: stroke.id,
        index: 0,
        x: values[0]!,
        y: values[1]!,
        pressure: values[2]!.clamp(0.0, 1.0),
        tilt: values[3]!,
      );
      await loadForSelection();
      host.markDirty();
      unawaited(host.refreshTiles());
    } catch (error, stack) {
      debugPrint('Project Ink vector point edit rejected: $error\n$stack');
    }
  }

  Widget _boundedNumberField(String label, TextEditingController controller) =>
      TextField(
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: false),
        decoration: InputDecoration(labelText: label),
      );
}
