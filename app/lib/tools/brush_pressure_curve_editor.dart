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
                          final low = current[index - 1].x + .000001;
                          final high = current[index + 1].x - .000001;
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
          IconButton(
            tooltip: 'Remove pressure point',
            onPressed:
                enabled && points.length > 2
                    ? () => onChanged(
                      List.unmodifiable(points.take(points.length - 1)),
                    )
                    : null,
            icon: const Icon(Icons.remove_circle_outline),
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
