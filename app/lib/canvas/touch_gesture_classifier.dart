import 'dart:ui';

/// Gesture classes that can be recognized without touching editor state.
enum TouchGestureKind {
  twoFingerTap,
  threeFingerTap,
  threeFingerSwipeDown,
  fourFingerTap,
  longPress,
}

/// Classifies the deliberately small, stylus-safe touch grammar used by the
/// canvas. Navigation remains owned by Flutter's scale recognizer; this class
/// only decides when a touch sequence is a command gesture.
TouchGestureKind? classifyTouchGesture({
  required Map<int, Offset> starts,
  required Map<int, Offset> ends,
  required Duration duration,
  required bool moved,
  double swipeDistance = 72,
}) {
  if (starts.isEmpty || starts.length != ends.length) return null;
  if (starts.length == 1 &&
      !moved &&
      duration >= const Duration(milliseconds: 500)) {
    return TouchGestureKind.longPress;
  }
  if (moved) {
    if (starts.length != 3) return null;
    final displacement = _averageDisplacement(starts, ends);
    if (displacement.dy < swipeDistance ||
        displacement.dx.abs() > swipeDistance) {
      return null;
    }
    return TouchGestureKind.threeFingerSwipeDown;
  }
  // Three contacts take longer to place and release together on a phone.
  // Keep the tighter window for two- and four-finger taps while allowing a
  // deliberate three-finger Redo chord to complete within 600 ms.
  final tapDurationLimit =
      starts.length == 3
          ? const Duration(milliseconds: 600)
          : const Duration(milliseconds: 350);
  if (duration > tapDurationLimit) return null;
  return switch (starts.length) {
    2 => TouchGestureKind.twoFingerTap,
    3 => TouchGestureKind.threeFingerTap,
    4 => TouchGestureKind.fourFingerTap,
    _ => null,
  };
}

Offset _averageDisplacement(Map<int, Offset> starts, Map<int, Offset> ends) {
  var total = Offset.zero;
  for (final entry in starts.entries) {
    total += ends[entry.key]! - entry.value;
  }
  return total / starts.length.toDouble();
}
