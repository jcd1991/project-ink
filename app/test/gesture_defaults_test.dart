import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/canvas/gesture_defaults.dart';

void main() {
  test('gesture defaults include undo, redo, and canvas rotation', () {
    const defaults = GestureDefaults();
    expect(defaults.bindings['twoFingerTap'], InkGesture.undo);
    expect(defaults.bindings['threeFingerTap'], InkGesture.redo);
    expect(defaults.bindings['pinchTwist'], InkGesture.rotate);
    expect(defaults.bindings['stylusDoubleTap'], InkGesture.toggleEraser);
    expect(defaults.bindings.containsKey('quickPinch'), isFalse);
  });

  test('gesture bindings can be remapped without mutating defaults', () {
    const defaults = GestureDefaults();
    final remapped = defaults.copyWith(<String, InkGesture>{
      'twoFingerTap': InkGesture.redo,
    });
    expect(defaults.bindings['twoFingerTap'], InkGesture.undo);
    expect(remapped.bindings['twoFingerTap'], InkGesture.redo);
  });
}
