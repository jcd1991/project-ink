import 'dart:math' as math;
import 'dart:ui';

/// Applies temporary straighten/constrain behavior to an active stroke.
///
/// The controller owns the constraint mode and per-stroke direction snapshot;
/// input coordinators decide when a stroke begins and ends.
class CanvasStrokeConstraintController {
  bool _straighten = false;
  bool _constrain = false;
  Offset? _strokeStart;
  Offset? _straightenDirection;

  bool get isActive => _straighten || _constrain;
  Offset? get strokeStart => _strokeStart;
  String get mode =>
      _straighten
          ? 'straighten'
          : _constrain
          ? 'constrain'
          : 'none';

  void enableStraighten() {
    _straighten = true;
    _constrain = false;
  }

  void enableConstrain() {
    _constrain = true;
    _straighten = false;
  }

  Offset apply(Offset position, {required bool hasDown}) {
    if (hasDown || _strokeStart == null) {
      _strokeStart = position;
      _straightenDirection = null;
      return position;
    }
    final start = _strokeStart!;
    final delta = position - start;
    if (delta.distance < 0.5) return position;
    if (_straighten) {
      _straightenDirection ??= delta / delta.distance;
      final direction = _straightenDirection!;
      return start +
          direction * (delta.dx * direction.dx + delta.dy * direction.dy);
    }
    if (_constrain) {
      final angle = math.atan2(delta.dy, delta.dx);
      const increment = math.pi / 12;
      final snappedAngle = (angle / increment).round() * increment;
      final distance = delta.distance;
      return start +
          Offset(math.cos(snappedAngle), math.sin(snappedAngle)) * distance;
    }
    return position;
  }

  void reset() {
    _strokeStart = null;
    _straightenDirection = null;
    _straighten = false;
    _constrain = false;
  }
}
