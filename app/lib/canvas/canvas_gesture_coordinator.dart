import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';

import '../app/editor_action.dart';
import 'gesture_defaults.dart';
import 'touch_gesture_classifier.dart';
import 'touch_gesture_tracker.dart';

/// Effects used when a touch gesture resolves to an editor command.
class CanvasGestureActionHost {
  const CanvasGestureActionHost({
    required this.defaults,
    required this.isMounted,
    required this.dispatchEditorAction,
    required this.showClipboardPalette,
    required this.sampleColor,
    required this.enableStraighten,
    required this.enableConstrain,
    this.recordDiagnostic,
  });

  final GestureDefaults Function() defaults;
  final bool Function() isMounted;
  final ValueChanged<EditorActionId> dispatchEditorAction;
  final void Function() showClipboardPalette;
  final void Function(Offset position) sampleColor;
  final void Function() enableStraighten;
  final void Function() enableConstrain;
  final void Function(String event, Map<String, Object?> fields)?
  recordDiagnostic;
}

/// Owns touch-contact tracking and maps completed touch gestures to editor
/// commands. Stroke lifecycle and command effects remain with their owners.
class CanvasGestureCoordinator {
  CanvasGestureCoordinator(this.host);

  final CanvasGestureActionHost host;
  final TouchGestureTracker _tracker = TouchGestureTracker();

  int get activePointerCount => _tracker.activePointerCount;
  int get trackedPointerCount => _tracker.trackedPointerCount;
  Iterable<int> get activePointerIds => _tracker.activePointerIds;

  void record(
    PointerEvent event, {
    required bool strokeActive,
    required bool Function() touchDrawingStrokeActive,
  }) {
    _tracker.record(
      event,
      strokeActive: strokeActive,
      touchDrawingStrokeActive: touchDrawingStrokeActive,
      onSecondFingerWhileDrawing:
          () => dispatchMapped(
            host.defaults().bindings['secondFingerWhileDrawing'],
          ),
      onLongPress:
          (position) => dispatchMapped(
            host.defaults().bindings['longPress'],
            position: position,
          ),
      onSequenceCompleted: (gesture, duration, moved, pointerCount) {
        if (gesture == null && pointerCount >= 2) {
          host.recordDiagnostic?.call('input.touch_gesture_rejected', {
            'pointerCount': pointerCount,
            'durationMs': duration.inMilliseconds,
            'moved': moved,
            'reason': moved ? 'movement' : 'duration_or_unsupported_chord',
          });
        }
      },
      onGesture: (gesture) {
        final bindingName = switch (gesture) {
          TouchGestureKind.twoFingerTap => 'twoFingerTap',
          TouchGestureKind.threeFingerTap => 'threeFingerTap',
          TouchGestureKind.threeFingerSwipeDown => 'threeFingerSwipeDown',
          TouchGestureKind.fourFingerTap => 'fourFingerTap',
          TouchGestureKind.longPress => null,
        };
        host.recordDiagnostic?.call('input.touch_gesture_classified', {
          'gesture': gesture.name,
          'binding': bindingName,
          'action':
              bindingName == null
                  ? null
                  : host.defaults().bindings[bindingName]?.name,
        });
        if (bindingName != null) {
          dispatchMapped(host.defaults().bindings[bindingName]);
        }
      },
    );
  }

  void dispatchMapped(InkGesture? gesture, {Offset? position}) {
    switch (gesture) {
      case InkGesture.undo:
        host.dispatchEditorAction(EditorActionId.undo);
      case InkGesture.redo:
        host.dispatchEditorAction(EditorActionId.redo);
      case InkGesture.fitCanvas:
        host.dispatchEditorAction(EditorActionId.fitCanvas);
      case InkGesture.toggleInterface:
        host.dispatchEditorAction(EditorActionId.toggleInterface);
      case InkGesture.toggleEraser:
        host.dispatchEditorAction(EditorActionId.toggleEraser);
      case InkGesture.clipboardPalette:
        if (host.isMounted()) host.showClipboardPalette();
      case InkGesture.eyedropper:
        if (host.isMounted() && position != null) host.sampleColor(position);
      case InkGesture.quickMenu:
        host.dispatchEditorAction(EditorActionId.quickMenu);
      case InkGesture.straighten:
        if (host.isMounted()) host.enableStraighten();
      case InkGesture.constrain:
        if (host.isMounted()) host.enableConstrain();
      case InkGesture.pan ||
          InkGesture.zoom ||
          InkGesture.rotate ||
          InkGesture.disabled ||
          null:
        break;
    }
  }

  void cancelLongPress() => _tracker.cancelLongPress();

  void reset() => _tracker.reset();

  void dispose() => _tracker.dispose();
}
