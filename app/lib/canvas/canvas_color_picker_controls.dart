import 'dart:math' as math;

import 'package:flutter/material.dart';

class CanvasColorWheel extends StatelessWidget {
  const CanvasColorWheel({
    super.key,
    required this.color,
    required this.onChanged,
  });

  final Color color;
  final ValueChanged<HSVColor> onChanged;

  void _update(Offset local, Size size) {
    final center = size.center(Offset.zero);
    final delta = local - center;
    final radius = math.min(size.width, size.height) / 2;
    final saturation = (delta.distance / radius).clamp(0.0, 1.0);
    var hue = math.atan2(delta.dy, delta.dx) * 180 / math.pi + 90;
    if (hue < 0) hue += 360;
    onChanged(
      HSVColor.fromAHSV(
        color.a,
        hue % 360,
        saturation,
        HSVColor.fromColor(color).value,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Color wheel',
    hint: 'Drag to choose hue and saturation',
    child: GestureDetector(
      onPanDown:
          (details) => _update(
            details.localPosition,
            (context.findRenderObject()! as RenderBox).size,
          ),
      onPanUpdate:
          (details) => _update(
            details.localPosition,
            (context.findRenderObject()! as RenderBox).size,
          ),
      child: CustomPaint(
        size: const Size(180, 180),
        painter: _ColorWheelPainter(color),
      ),
    ),
  );
}

class _ColorWheelPainter extends CustomPainter {
  const _ColorWheelPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = math.min(size.width, size.height) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final hueShader = const SweepGradient(
      colors: [
        Colors.red,
        Colors.yellow,
        Colors.green,
        Colors.cyan,
        Colors.blue,
        Color(0xffff00ff),
        Colors.red,
      ],
    ).createShader(rect);
    canvas.drawCircle(center, radius, Paint()..shader = hueShader);
    final saturationShader = RadialGradient(
      colors: [Colors.white, Colors.white.withValues(alpha: 0)],
    ).createShader(rect);
    canvas.drawCircle(center, radius, Paint()..shader = saturationShader);
    final hsv = HSVColor.fromColor(color);
    final angle = (hsv.hue - 90) * math.pi / 180;
    final marker =
        center +
        Offset(math.cos(angle), math.sin(angle)) * radius * hsv.saturation;
    canvas.drawCircle(
      marker,
      8,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = hsv.value > 0.55 ? Colors.black : Colors.white,
    );
  }

  @override
  bool shouldRepaint(covariant _ColorWheelPainter oldDelegate) =>
      oldDelegate.color != color;
}

class CanvasColorSquare extends StatelessWidget {
  const CanvasColorSquare({
    super.key,
    required this.color,
    required this.onChanged,
  });

  final Color color;
  final ValueChanged<HSVColor> onChanged;

  void _update(Offset local, Size size) {
    final hsv = HSVColor.fromColor(color);
    onChanged(
      HSVColor.fromAHSV(
        hsv.alpha,
        hsv.hue,
        (local.dx / size.width).clamp(0.0, 1.0),
        (1 - local.dy / size.height).clamp(0.0, 1.0),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onPanDown: (details) {
      final box = context.findRenderObject()! as RenderBox;
      _update(details.localPosition, box.size);
    },
    onPanUpdate: (details) {
      final box = context.findRenderObject()! as RenderBox;
      _update(details.localPosition, box.size);
    },
    child: CustomPaint(
      size: const Size(220, 116),
      painter: _ColorSquarePainter(color),
    ),
  );
}

class _ColorSquarePainter extends CustomPainter {
  const _ColorSquarePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final hsv = HSVColor.fromColor(color);
    final hueColor = HSVColor.fromAHSV(1, hsv.hue, 1, 1).toColor();
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: [Colors.white, hueColor],
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00000000), Colors.black],
        ).createShader(rect),
    );
    final marker = Offset(
      hsv.saturation * size.width,
      (1 - hsv.value) * size.height,
    );
    canvas.drawCircle(
      marker,
      7,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = hsv.value > 0.55 ? Colors.black : Colors.white,
    );
  }

  @override
  bool shouldRepaint(covariant _ColorSquarePainter oldDelegate) =>
      oldDelegate.color != color;
}
