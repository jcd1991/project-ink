import 'dart:math' as math;

/// Widths actually used by the desktop workspace after reserving enough room
/// for the canvas. Persisted preferred widths are not rewritten when a window
/// is temporarily narrow; they become active again when space is available.
class EffectiveDockWidths {
  const EffectiveDockWidths({required this.left, required this.right});

  final double left;
  final double right;
}

EffectiveDockWidths effectiveDockWidths({
  required double viewportWidth,
  required bool showLeftDock,
  required bool showRightDock,
  required double preferredLeftWidth,
  required double preferredRightWidth,
  double minimumCanvasWidth = 400,
  double toolRailWidth = 44,
  double minimumDockWidth = 220,
  double maximumDockWidth = 480,
}) {
  final left =
      showLeftDock
          ? _boundedWidth(
            preferredLeftWidth,
            minimumDockWidth,
            maximumDockWidth,
          )
          : 0.0;
  final right =
      showRightDock
          ? _boundedWidth(
            preferredRightWidth,
            minimumDockWidth,
            maximumDockWidth,
          )
          : 0.0;
  if (!viewportWidth.isFinite || viewportWidth <= 0) {
    return EffectiveDockWidths(left: left, right: right);
  }

  final dockBudget = math.max(
    0.0,
    viewportWidth - toolRailWidth - minimumCanvasWidth,
  );
  final total = left + right;
  if (total <= dockBudget) {
    return EffectiveDockWidths(left: left, right: right);
  }

  final leftCapacity = math.max(0.0, left - minimumDockWidth);
  final rightCapacity = math.max(0.0, right - minimumDockWidth);
  final totalCapacity = leftCapacity + rightCapacity;
  if (totalCapacity == 0) {
    return EffectiveDockWidths(left: left, right: right);
  }

  final reduction = total - dockBudget;
  final reducible = math.min(reduction, totalCapacity);
  final leftReduction = reducible * leftCapacity / totalCapacity;
  final rightReduction = reducible - leftReduction;
  return EffectiveDockWidths(
    left: showLeftDock ? math.max(minimumDockWidth, left - leftReduction) : 0,
    right:
        showRightDock ? math.max(minimumDockWidth, right - rightReduction) : 0,
  );
}

double _boundedWidth(double width, double minimum, double maximum) =>
    (width.isFinite ? width : minimum).clamp(minimum, maximum).toDouble();
