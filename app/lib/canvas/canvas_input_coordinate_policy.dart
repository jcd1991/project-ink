import 'dart:math' as math;
import 'dart:ui';

import '../tools/illustration_tools.dart';

/// Coordinate bounds and ruler projection rules for canvas input.
///
/// Callers pass the active tool and ruler snapshot explicitly so input
/// translation does not depend on widget-private state.
abstract final class CanvasInputCoordinatePolicy {
  static const maxSafeInputCoordinate = 65536.0;

  static Offset safeInput(Offset position) => Offset(
    position.dx
        .clamp(-maxSafeInputCoordinate, maxSafeInputCoordinate)
        .toDouble(),
    position.dy
        .clamp(-maxSafeInputCoordinate, maxSafeInputCoordinate)
        .toDouble(),
  );

  static Offset boundToDocument(Offset position, Size documentSize) => Offset(
    position.dx.clamp(0.0, documentSize.width - 1).toDouble(),
    position.dy.clamp(0.0, documentSize.height - 1).toDouble(),
  );

  static Offset snapToRuler({
    required Offset position,
    required IllustrationTool activeTool,
    required Offset? rulerStart,
    required Offset? rulerEnd,
    required IllustrationTool? rulerTool,
  }) {
    if (activeTool != IllustrationTool.brush &&
        activeTool != IllustrationTool.eraser) {
      return position;
    }
    final start = rulerStart;
    final end = rulerEnd;
    final tool = rulerTool;
    if (start == null ||
        end == null ||
        tool == null ||
        (end - start).distance < 0.01) {
      return position;
    }
    final delta = end - start;
    final lengthSquared = delta.dx * delta.dx + delta.dy * delta.dy;
    if (lengthSquared <= 0.0001) return position;
    final amount =
        ((position - start).dx * delta.dx + (position - start).dy * delta.dy) /
        lengthSquared;
    final projected = start + delta * amount;
    if (tool == IllustrationTool.straightRuler ||
        tool == IllustrationTool.parallelRuler ||
        tool == IllustrationTool.perspectiveRuler) {
      return projected;
    }
    if (tool == IllustrationTool.symmetryRuler) {
      return projected * 2 - position;
    }
    if (tool == IllustrationTool.radialRuler) {
      final center = start;
      final radius = (position - center).distance;
      final angle = math.atan2(
        position.dy - center.dy,
        position.dx - center.dx,
      );
      const spokes = 8;
      const step = 2 * math.pi / spokes;
      final snapped = (angle / step).round() * step;
      return center + Offset(math.cos(snapped), math.sin(snapped)) * radius;
    }
    return position;
  }
}
