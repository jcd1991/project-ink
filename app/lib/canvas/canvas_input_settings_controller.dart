import 'package:flutter/material.dart';

import 'canvas_input_settings_dialogs.dart';
import 'gesture_defaults.dart';

/// Owns transient gesture and accessibility settings plus their dialog flow.
/// Handedness remains owned by the workspace dock state and its persistence
/// remains with the workspace layout actions.
class CanvasInputSettingsController {
  CanvasInputSettingsController({
    GestureDefaults gestureDefaults = const GestureDefaults(),
    bool singleFingerNavigation = false,
    bool largeControls = false,
  }) : _gestureDefaults = gestureDefaults,
       _singleFingerNavigation = singleFingerNavigation,
       _largeControls = largeControls;

  GestureDefaults _gestureDefaults;
  bool _singleFingerNavigation;
  bool _largeControls;

  GestureDefaults get gestureDefaults => _gestureDefaults;
  bool get singleFingerNavigation => _singleFingerNavigation;
  bool get largeControls => _largeControls;

  void resetSingleFingerNavigation() {
    _singleFingerNavigation = false;
  }

  Future<void> showGestureSettings({
    required BuildContext context,
    required bool Function() isMounted,
    required VoidCallback onChanged,
  }) async {
    final result = await showDialog<CanvasGestureSettingsResult>(
      context: context,
      builder:
          (_) => CanvasGestureSettingsDialog(
            singleFingerNavigation: _singleFingerNavigation,
            gestureDefaults: _gestureDefaults,
          ),
    );
    if (result == null || !isMounted()) return;
    _singleFingerNavigation = result.singleFingerNavigation;
    _gestureDefaults = result.applyTo(_gestureDefaults);
    onChanged();
  }

  Future<void> showAccessibilitySettings({
    required BuildContext context,
    required bool Function() isMounted,
    required bool leftHandedToolbar,
    required ValueChanged<bool> updateLeftHandedToolbar,
    required ValueChanged<bool> persistLeftHandedToolbar,
    required VoidCallback onChanged,
  }) async {
    final result = await showDialog<CanvasAccessibilitySettingsResult>(
      context: context,
      builder:
          (_) => CanvasAccessibilitySettingsDialog(
            largeControls: _largeControls,
            leftHandedToolbar: leftHandedToolbar,
          ),
    );
    if (result == null || !isMounted()) return;
    _largeControls = result.largeControls;
    updateLeftHandedToolbar(result.leftHandedToolbar);
    onChanged();
    persistLeftHandedToolbar(result.leftHandedToolbar);
  }
}
