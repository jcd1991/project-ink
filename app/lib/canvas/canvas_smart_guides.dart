import 'dart:math' as math;

/// Temporary alignments for one vector-object transform preview.
class CanvasSmartGuideResult {
  const CanvasSmartGuideResult({
    required this.delta,
    this.verticalX,
    this.horizontalY,
  });

  final math.Point<double> delta;
  final double? verticalX;
  final double? horizontalY;
}

/// Snap a selected object's edge, center, or anchor to nearby reference
/// features. Deltas and tolerance use document pixels; returned delta is the
/// corrected total translation for the current drag update.
CanvasSmartGuideResult snapCanvasSmartGuides({
  required List<double> movingX,
  required List<double> movingY,
  required List<double> referenceX,
  required List<double> referenceY,
  required math.Point<double> requestedDelta,
  required double tolerance,
}) {
  const maximumFeaturesPerAxis = 2048;
  if (!requestedDelta.x.isFinite ||
      !requestedDelta.y.isFinite ||
      !tolerance.isFinite ||
      tolerance < 0 ||
      movingX.length > maximumFeaturesPerAxis ||
      movingY.length > maximumFeaturesPerAxis ||
      referenceX.length > maximumFeaturesPerAxis ||
      referenceY.length > maximumFeaturesPerAxis ||
      _hasNonFinite(movingX) ||
      _hasNonFinite(movingY) ||
      _hasNonFinite(referenceX) ||
      _hasNonFinite(referenceY)) {
    return CanvasSmartGuideResult(delta: requestedDelta);
  }

  final x = _nearestAlignment(movingX, referenceX, requestedDelta.x, tolerance);
  final y = _nearestAlignment(movingY, referenceY, requestedDelta.y, tolerance);
  return CanvasSmartGuideResult(
    delta: math.Point<double>(
      x?.delta ?? requestedDelta.x,
      y?.delta ?? requestedDelta.y,
    ),
    verticalX: x?.target,
    horizontalY: y?.target,
  );
}

bool _hasNonFinite(List<double> values) {
  for (final value in values) {
    if (!value.isFinite) return true;
  }
  return false;
}

({double delta, double target})? _nearestAlignment(
  List<double> moving,
  List<double> references,
  double requestedDelta,
  double tolerance,
) {
  ({double delta, double target})? best;
  var bestDistance = double.infinity;
  final sortedReferences = references.toList()..sort();
  for (final feature in moving) {
    final moved = feature + requestedDelta;
    var low = 0;
    var high = sortedReferences.length;
    while (low < high) {
      final middle = low + ((high - low) >> 1);
      if (sortedReferences[middle] < moved) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    for (var offset = 0; offset < 2; offset++) {
      final index = offset == 0 ? low - 1 : low;
      if (index < 0 || index >= sortedReferences.length) continue;
      final target = sortedReferences[index];
      final correction = target - moved;
      final distance = correction.abs();
      if (distance > tolerance) continue;
      if (distance < bestDistance ||
          (distance == bestDistance &&
              (best == null || target < best.target))) {
        bestDistance = distance;
        best = (delta: requestedDelta + correction, target: target);
      }
    }
  }
  return best;
}
