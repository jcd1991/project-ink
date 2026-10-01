enum InkGesture {
  pan,
  zoom,
  rotate,
  fitCanvas,
  undo,
  redo,
  clipboardPalette,
  toggleInterface,
  eyedropper,
  straighten,
  constrain,
  toggleEraser,
  quickMenu,
}

/// User-remappable gesture bindings. Navigation gestures are intentionally
/// separate from command gestures so palm rejection can arbitrate contacts.
class GestureDefaults {
  const GestureDefaults()
    : bindings = const {
        'twoFingerDrag': InkGesture.pan,
        'pinch': InkGesture.zoom,
        'pinchTwist': InkGesture.rotate,
        'twoFingerTap': InkGesture.undo,
        'threeFingerTap': InkGesture.redo,
        'threeFingerSwipeDown': InkGesture.clipboardPalette,
        'fourFingerTap': InkGesture.toggleInterface,
        'longPress': InkGesture.eyedropper,
        'drawAndHold': InkGesture.straighten,
        'secondFingerWhileDrawing': InkGesture.constrain,
        'stylusDoubleTap': InkGesture.toggleEraser,
        'pencilProSqueeze': InkGesture.quickMenu,
      };

  GestureDefaults.fromBindings(Map<String, InkGesture> bindings)
    : bindings = Map<String, InkGesture>.unmodifiable(bindings);

  final Map<String, InkGesture> bindings;

  GestureDefaults copyWith(Map<String, InkGesture> overrides) =>
      GestureDefaults.fromBindings({...bindings, ...overrides});
}
