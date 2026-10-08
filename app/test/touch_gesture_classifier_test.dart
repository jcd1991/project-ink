import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/canvas/touch_gesture_classifier.dart';

void main() {
  Map<int, Offset> points(int count, {double dy = 0}) => {
    for (var index = 0; index < count; index++)
      index: Offset(index.toDouble() * 10, dy),
  };

  test('recognizes the default tap and swipe command grammar', () {
    expect(
      classifyTouchGesture(
        starts: points(2),
        ends: points(2),
        duration: const Duration(milliseconds: 100),
        moved: false,
      ),
      TouchGestureKind.twoFingerTap,
    );
    expect(
      classifyTouchGesture(
        starts: points(3),
        ends: points(3, dy: 100),
        duration: const Duration(milliseconds: 180),
        moved: true,
      ),
      TouchGestureKind.threeFingerSwipeDown,
    );
    expect(
      classifyTouchGesture(
        starts: points(4),
        ends: points(4),
        duration: const Duration(milliseconds: 120),
        moved: false,
      ),
      TouchGestureKind.fourFingerTap,
    );
  });

  test('recognizes a deliberate long press and rejects diagonal swipes', () {
    expect(
      classifyTouchGesture(
        starts: points(1),
        ends: points(1),
        duration: const Duration(milliseconds: 600),
        moved: false,
      ),
      TouchGestureKind.longPress,
    );
    expect(
      classifyTouchGesture(
        starts: points(3),
        ends: {
          0: const Offset(100, 100),
          1: const Offset(110, 100),
          2: const Offset(120, 100),
        },
        duration: const Duration(milliseconds: 200),
        moved: true,
      ),
      isNull,
    );
  });

  test('allows enough time to place and release a three-finger Redo tap', () {
    expect(
      classifyTouchGesture(
        starts: points(3),
        ends: points(3),
        duration: const Duration(milliseconds: 500),
        moved: false,
      ),
      TouchGestureKind.threeFingerTap,
    );
    expect(
      classifyTouchGesture(
        starts: points(3),
        ends: points(3),
        duration: const Duration(milliseconds: 601),
        moved: false,
      ),
      isNull,
    );
  });
}
