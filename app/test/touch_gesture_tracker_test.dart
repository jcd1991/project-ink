import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/canvas/touch_gesture_classifier.dart';
import 'package:project_ink/canvas/touch_gesture_tracker.dart';

void main() {
  test('emits a completed two-finger tap and clears sequence state', () {
    final tracker = TouchGestureTracker();
    final gestures = <TouchGestureKind>[];
    void record(PointerEvent event) => tracker.record(
      event,
      strokeActive: false,
      touchDrawingStrokeActive: () => false,
      onSecondFingerWhileDrawing: () {},
      onLongPress: (_) {},
      onGesture: gestures.add,
    );

    record(_touchDown(1, const Offset(20, 30)));
    record(_touchDown(2, const Offset(45, 32)));
    expect(tracker.hasMultipleTouches, isTrue);
    expect(tracker.maximumTouchCount, 2);
    record(_touchUp(1, const Offset(20, 30)));
    record(_touchUp(2, const Offset(45, 32)));

    expect(gestures, <TouchGestureKind>[TouchGestureKind.twoFingerTap]);
    expect(tracker.trackedPointerCount, 0);
    expect(tracker.activePointerCount, 0);
  });

  test('reset cancels tracked contacts without emitting a gesture', () {
    final tracker = TouchGestureTracker();
    var emitted = false;
    tracker.record(
      _touchDown(1, Offset.zero),
      strokeActive: false,
      touchDrawingStrokeActive: () => false,
      onSecondFingerWhileDrawing: () {},
      onLongPress: (_) {},
      onGesture: (_) => emitted = true,
    );

    tracker.reset();

    expect(tracker.trackedPointerCount, 0);
    expect(tracker.activePointerCount, 0);
    expect(emitted, isFalse);
    tracker.dispose();
  });

  test('two-finger tap tolerates small phone touch drift', () {
    final tracker = TouchGestureTracker();
    final gestures = <TouchGestureKind>[];
    void record(PointerEvent event) => tracker.record(
      event,
      strokeActive: false,
      touchDrawingStrokeActive: () => false,
      onSecondFingerWhileDrawing: () {},
      onLongPress: (_) {},
      onGesture: gestures.add,
    );

    record(_touchDown(1, const Offset(20, 30)));
    record(_touchDown(2, const Offset(45, 32)));
    record(_touchMove(1, const Offset(37, 30)));
    record(_touchMove(2, const Offset(62, 32)));
    record(_touchUp(1, const Offset(37, 30)));
    record(_touchUp(2, const Offset(62, 32)));

    expect(gestures, <TouchGestureKind>[TouchGestureKind.twoFingerTap]);
    tracker.dispose();
  });

  test('two-finger movement beyond tap tolerance is not undo', () {
    final tracker = TouchGestureTracker();
    final gestures = <TouchGestureKind>[];
    void record(PointerEvent event) => tracker.record(
      event,
      strokeActive: false,
      touchDrawingStrokeActive: () => false,
      onSecondFingerWhileDrawing: () {},
      onLongPress: (_) {},
      onGesture: gestures.add,
    );

    record(_touchDown(1, const Offset(20, 30)));
    record(_touchDown(2, const Offset(45, 32)));
    record(_touchMove(1, const Offset(46, 30)));
    record(_touchMove(2, const Offset(71, 32)));
    record(_touchUp(1, const Offset(46, 30)));
    record(_touchUp(2, const Offset(71, 32)));

    expect(gestures, isEmpty);
    tracker.dispose();
  });

  test('three-finger Redo tolerates extra finger drift', () {
    final tracker = TouchGestureTracker();
    final gestures = <TouchGestureKind>[];
    void record(PointerEvent event) => tracker.record(
      event,
      strokeActive: false,
      touchDrawingStrokeActive: () => false,
      onSecondFingerWhileDrawing: () {},
      onLongPress: (_) {},
      onGesture: gestures.add,
    );

    record(_touchDown(1, const Offset(20, 30)));
    record(_touchDown(2, const Offset(45, 32)));
    record(_touchMove(1, const Offset(48, 30)));
    record(_touchDown(3, const Offset(70, 33)));
    record(_touchUp(1, const Offset(48, 30)));
    record(_touchUp(2, const Offset(45, 32)));
    record(_touchUp(3, const Offset(70, 33)));

    expect(gestures, <TouchGestureKind>[TouchGestureKind.threeFingerTap]);
    tracker.dispose();
  });
}

PointerMoveEvent _touchMove(int pointer, Offset position) => PointerMoveEvent(
  pointer: pointer,
  kind: PointerDeviceKind.touch,
  position: position,
);

PointerDownEvent _touchDown(int pointer, Offset position) => PointerDownEvent(
  pointer: pointer,
  kind: PointerDeviceKind.touch,
  position: position,
);

PointerUpEvent _touchUp(int pointer, Offset position) => PointerUpEvent(
  pointer: pointer,
  kind: PointerDeviceKind.touch,
  position: position,
);
