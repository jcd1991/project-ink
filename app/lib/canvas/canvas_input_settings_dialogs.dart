import 'package:flutter/material.dart';

import 'gesture_defaults.dart';

@immutable
class CanvasGestureSettingsResult {
  const CanvasGestureSettingsResult({
    required this.singleFingerNavigation,
    required this.twoFingerTap,
    required this.threeFingerTap,
  });

  final bool singleFingerNavigation;
  final InkGesture twoFingerTap;
  final InkGesture threeFingerTap;

  GestureDefaults applyTo(GestureDefaults defaults) => defaults.copyWith({
    'twoFingerTap': twoFingerTap,
    'threeFingerTap': threeFingerTap,
  });
}

class CanvasGestureSettingsDialog extends StatefulWidget {
  const CanvasGestureSettingsDialog({
    required this.singleFingerNavigation,
    required this.gestureDefaults,
    super.key,
  });

  final bool singleFingerNavigation;
  final GestureDefaults gestureDefaults;

  @override
  State<CanvasGestureSettingsDialog> createState() =>
      _CanvasGestureSettingsDialogState();
}

class _CanvasGestureSettingsDialogState
    extends State<CanvasGestureSettingsDialog> {
  late bool _singleFingerNavigation = widget.singleFingerNavigation;
  late InkGesture _twoFingerTap =
      widget.gestureDefaults.bindings['twoFingerTap'] ?? InkGesture.undo;
  late InkGesture _threeFingerTap =
      widget.gestureDefaults.bindings['threeFingerTap'] ?? InkGesture.redo;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Gesture settings'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Single-finger navigation'),
            subtitle: const Text(
              'When off, one finger draws. When on, one finger pans.',
            ),
            value: _singleFingerNavigation,
            onChanged:
                (value) => setState(() => _singleFingerNavigation = value),
          ),
          DropdownButtonFormField<InkGesture>(
            decoration: const InputDecoration(labelText: 'Two-finger tap'),
            initialValue: _twoFingerTap,
            items: _tapActions,
            onChanged: (value) {
              if (value != null) setState(() => _twoFingerTap = value);
            },
          ),
          DropdownButtonFormField<InkGesture>(
            decoration: const InputDecoration(labelText: 'Three-finger tap'),
            initialValue: _threeFingerTap,
            items: _tapActions,
            onChanged: (value) {
              if (value != null) setState(() => _threeFingerTap = value);
            },
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed:
            () => Navigator.pop(
              context,
              CanvasGestureSettingsResult(
                singleFingerNavigation: _singleFingerNavigation,
                twoFingerTap: _twoFingerTap,
                threeFingerTap: _threeFingerTap,
              ),
            ),
        child: const Text('Apply'),
      ),
    ],
  );
}

const _tapActions = <DropdownMenuItem<InkGesture>>[
  DropdownMenuItem(value: InkGesture.undo, child: Text('Undo')),
  DropdownMenuItem(value: InkGesture.redo, child: Text('Redo')),
  DropdownMenuItem(value: InkGesture.disabled, child: Text('Off')),
];

@immutable
class CanvasAccessibilitySettingsResult {
  const CanvasAccessibilitySettingsResult({
    required this.largeControls,
    required this.leftHandedToolbar,
  });

  final bool largeControls;
  final bool leftHandedToolbar;
}

class CanvasAccessibilitySettingsDialog extends StatefulWidget {
  const CanvasAccessibilitySettingsDialog({
    required this.largeControls,
    required this.leftHandedToolbar,
    super.key,
  });

  final bool largeControls;
  final bool leftHandedToolbar;

  @override
  State<CanvasAccessibilitySettingsDialog> createState() =>
      _CanvasAccessibilitySettingsDialogState();
}

class _CanvasAccessibilitySettingsDialogState
    extends State<CanvasAccessibilitySettingsDialog> {
  late bool _largeControls = widget.largeControls;
  late bool _leftHandedToolbar = widget.leftHandedToolbar;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Accessibility settings'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Larger controls'),
            subtitle: const Text(
              'Increase toolbar hit targets and icon sizes.',
            ),
            value: _largeControls,
            onChanged: (value) => setState(() => _largeControls = value),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Left-handed toolbar'),
            subtitle: const Text(
              'Move the main toolbar to the upper-left edge.',
            ),
            value: _leftHandedToolbar,
            onChanged: (value) => setState(() => _leftHandedToolbar = value),
          ),
          const SizedBox(height: 8),
          const Text(
            'All controls expose screen-reader labels and keyboard alternatives where available.',
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed:
            () => Navigator.pop(
              context,
              CanvasAccessibilitySettingsResult(
                largeControls: _largeControls,
                leftHandedToolbar: _leftHandedToolbar,
              ),
            ),
        child: const Text('Apply'),
      ),
    ],
  );
}
