import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'brush_library.dart';

/// Editable normalized response curve. The owner validates and persists edits.
class BrushPressureCurveEditor extends StatelessWidget {
  const BrushPressureCurveEditor({
    required this.points,
    required this.onChanged,
    required this.resetPoints,
    this.enabled = true,
    super.key,
  });

  final List<BrushCurvePointView> points;
  final ValueChanged<List<BrushCurvePointView>> onChanged;
  final List<BrushCurvePointView> resetPoints;
  final bool enabled;

  static const _presets = <String, List<BrushCurvePointView>>{
    'Linear': [
      BrushCurvePointView(x: 0, y: 0),
      BrushCurvePointView(x: 1, y: 1),
    ],
    'Soft': [
      BrushCurvePointView(x: 0, y: 0),
      BrushCurvePointView(x: .3, y: .6),
      BrushCurvePointView(x: 1, y: 1),
    ],
    'Hard': [
      BrushCurvePointView(x: 0, y: 0),
      BrushCurvePointView(x: .6, y: .3),
      BrushCurvePointView(x: 1, y: 1),
    ],
  };

  int? _widestInsertIndex() {
    if (points.length >= 16 || points.length < 2) return null;
    var widestIndex = 0;
    var widestGap = 0.0;
    for (var index = 0; index < points.length - 1; index++) {
      final gap = points[index + 1].x - points[index].x;
      final midpoint = points[index].x + gap / 2;
      if (gap > widestGap &&
          midpoint > points[index].x &&
          midpoint < points[index + 1].x) {
        widestGap = gap;
        widestIndex = index;
      }
    }
    return widestGap > 0 ? widestIndex : null;
  }

  void _addPoint() {
    final index = _widestInsertIndex();
    if (index == null) return;
    final left = points[index];
    final right = points[index + 1];
    final x = left.x + (right.x - left.x) / 2;
    final y = left.y + (right.y - left.y) / 2;
    final updated =
        points.toList()..insert(index + 1, BrushCurvePointView(x: x, y: y));
    onChanged(List.unmodifiable(updated));
  }

  void _updatePoint(int index, BrushCurvePointView point) {
    final updated = points.toList()..[index] = point;
    onChanged(List.unmodifiable(updated));
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SizedBox(
        height: 190,
        child: LayoutBuilder(
          builder:
              (context, constraints) => GestureDetector(
                key: const ValueKey('pressure-curve-graph'),
                behavior: HitTestBehavior.opaque,
                onTapUp:
                    enabled
                        ? (event) {
                          if (points.length >= 16 || points.length < 2) return;
                          final x = (event.localPosition.dx /
                                  constraints.maxWidth)
                              .clamp(0.0, 1.0);
                          final y = (1 -
                                  event.localPosition.dy /
                                      constraints.maxHeight)
                              .clamp(0.0, 1.0);
                          final index = points.indexWhere(
                            (point) => point.x > x,
                          );
                          if (index <= 0) return;
                          final left = points[index - 1].x;
                          final right = points[index].x;
                          if (right - left <= 0.000002) return;
                          final boundedX = x.clamp(
                            left + 0.000001,
                            right - 0.000001,
                          );
                          final next =
                              points.toList()..insert(
                                index,
                                BrushCurvePointView(x: boundedX, y: y),
                              );
                          onChanged(List.unmodifiable(next));
                        }
                        : null,
                onPanUpdate:
                    enabled
                        ? (event) {
                          if (points.length < 3) return;
                          final current = points.toList();
                          final position = event.localPosition;
                          final x = (position.dx / constraints.maxWidth).clamp(
                            .001,
                            .999,
                          );
                          final y = (1 - position.dy / constraints.maxHeight)
                              .clamp(0.0, 1.0);
                          var index = 1;
                          for (
                            var candidate = 1;
                            candidate < current.length - 1;
                            candidate++
                          ) {
                            final dx =
                                current[candidate].x * constraints.maxWidth -
                                position.dx;
                            final dy =
                                (1 - current[candidate].y) *
                                    constraints.maxHeight -
                                position.dy;
                            if (dx * dx + dy * dy < 28 * 28) {
                              index = candidate;
                              break;
                            }
                          }
                          final previousX = current[index - 1].x;
                          final nextX = current[index + 1].x;
                          var low =
                              previousX +
                              math.min(
                                .000001,
                                (current[index].x - previousX) / 2,
                              );
                          var high =
                              nextX -
                              math.min(.000001, (nextX - current[index].x) / 2);
                          if (low <= previousX) low = current[index].x;
                          if (high >= nextX) high = current[index].x;
                          current[index] = BrushCurvePointView(
                            x: x.clamp(low, high),
                            y: y,
                          );
                          onChanged(List.unmodifiable(current));
                        }
                        : null,
                child: CustomPaint(
                  painter: _PressureCurvePainter(points),
                  child: const SizedBox.expand(),
                ),
              ),
        ),
      ),
      Wrap(
        spacing: 8,
        children: [
          TextButton.icon(
            onPressed:
                enabled && _widestInsertIndex() != null ? _addPoint : null,
            icon: const Icon(Icons.add),
            label: const Text('Add point'),
          ),
          for (final entry in _presets.entries)
            TextButton(
              onPressed:
                  enabled
                      ? () => onChanged(List.unmodifiable(entry.value))
                      : null,
              child: Text(entry.key),
            ),
          TextButton(
            onPressed:
                enabled
                    ? () => onChanged(List.unmodifiable(resetPoints))
                    : null,
            child: const Text('Reset'),
          ),
        ],
      ),
      for (var index = 0; index < points.length; index++)
        _CurvePointFields(
          key: ValueKey(
            'pressure-point-row-$index-${points[index].x}-${points[index].y}',
          ),
          index: index,
          point: points[index],
          previous: index == 0 ? null : points[index - 1],
          next: index == points.length - 1 ? null : points[index + 1],
          enabled: enabled,
          onChanged: (point) => _updatePoint(index, point),
          onRemove:
              enabled && points.length > 2
                  ? () {
                    final updated = points.toList()..removeAt(index);
                    onChanged(List.unmodifiable(updated));
                  }
                  : null,
        ),
    ],
  );
}

class _CurvePointFields extends StatelessWidget {
  const _CurvePointFields({
    required this.index,
    required this.point,
    required this.previous,
    required this.next,
    required this.enabled,
    required this.onChanged,
    required this.onRemove,
    super.key,
  });

  final int index;
  final BrushCurvePointView point;
  final BrushCurvePointView? previous;
  final BrushCurvePointView? next;
  final bool enabled;
  final ValueChanged<BrushCurvePointView> onChanged;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(child: Text('Point ${index + 1}')),
          IconButton(
            tooltip: 'Remove pressure point ${index + 1}',
            onPressed: onRemove,
            icon: const Icon(Icons.remove_circle_outline),
          ),
        ],
      ),
      Row(
        children: [
          Expanded(
            child: TextFormField(
              key: ValueKey('pressure-point-$index-x-${point.x}'),
              enabled: enabled,
              initialValue: point.x.toStringAsPrecision(7),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(labelText: 'Input (0–1)'),
              onFieldSubmitted: (text) {
                final value = double.tryParse(text);
                if (value == null ||
                    !value.isFinite ||
                    value < 0 ||
                    value > 1 ||
                    (previous != null && value <= previous!.x) ||
                    (next != null && value >= next!.x)) {
                  return;
                }
                onChanged(point.copyWith(x: value));
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextFormField(
              key: ValueKey('pressure-point-$index-y-${point.y}'),
              enabled: enabled,
              initialValue: point.y.toStringAsPrecision(7),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(labelText: 'Output (0–1)'),
              onFieldSubmitted: (text) {
                final value = double.tryParse(text);
                if (value == null ||
                    !value.isFinite ||
                    value < 0 ||
                    value > 1) {
                  return;
                }
                onChanged(point.copyWith(y: value));
              },
            ),
          ),
        ],
      ),
    ],
  );
}

class _PressureCurvePainter extends CustomPainter {
  const _PressureCurvePainter(this.points);
  final List<BrushCurvePointView> points;

  @override
  void paint(Canvas canvas, Size size) {
    final grid =
        Paint()
          ..color = Colors.grey.withValues(alpha: .35)
          ..strokeWidth = 1;
    final curve =
        Paint()
          ..color = Colors.lightBlueAccent
          ..strokeWidth = 2.5
          ..style = PaintingStyle.stroke;
    final dot = Paint()..color = Colors.white;
    for (var i = 0; i <= 4; i++) {
      final x = size.width * i / 4;
      final y = size.height * i / 4;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final p = Offset(
        points[i].x * size.width,
        (1 - points[i].y) * size.height,
      );
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawCircle(p, 5, dot);
      canvas.drawCircle(
        p,
        5,
        Paint()
          ..color = Colors.lightBlueAccent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
    canvas.drawPath(path, curve);
  }

  @override
  bool shouldRepaint(_PressureCurvePainter oldDelegate) =>
      oldDelegate.points != points;
}
