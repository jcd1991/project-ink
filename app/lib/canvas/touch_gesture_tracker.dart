import 'dart:async';

import 'package:flutter/material.dart';

import 'touch_gesture_classifier.dart';

/// Tracks a touch sequence and emits classified gestures without owning the
/// actions those gestures invoke.
class TouchGestureTracker {
  final Map<int, Offset> _starts = <int, Offset>{};
  final Map<int, Offset> _current = <int, Offset>{};
  final Set<int> _activePointers = <int>{};
  Timer? _longPressTimer;
  DateTime? _startedAt;
  int _maximumTouchCount = 0;
  bool _moved = false;
  bool _gestureTriggered = false;
  Offset? _gesturePosition;

  int get activePointerCount => _activePointers.length;
  int get trackedPointerCount => _starts.length;
  int get maximumTouchCount => _maximumTouchCount;
  bool get hasMultipleTouches => _starts.length > 1;
  bool get moved => _moved;
  bool get gestureTriggered => _gestureTriggered;
  Offset? get gesturePosition => _gesturePosition;
  Iterable<int> get activePointerIds => List<int>.unmodifiable(_activePointers);

  void record(
    PointerEvent event, {
    required bool strokeActive,
    required bool Function() touchDrawingStrokeActive,
    required VoidCallback onSecondFingerWhileDrawing,
    required ValueChanged<Offset?> onLongPress,
    required ValueChanged<TouchGestureKind> onGesture,
  }) {
    if (event is PointerDownEvent) {
      if (_starts.isEmpty) {
        _startedAt = DateTime.now();
        _moved = false;
        _maximumTouchCount = 0;
        _gestureTriggered = false;
        _gesturePosition = event.localPosition;
      }
      _starts[event.pointer] = event.localPosition;
      _current[event.pointer] = event.localPosition;
      _activePointers.add(event.pointer);
      if (_maximumTouchCount < _starts.length) {
        _maximumTouchCount = _starts.length;
      }
      if (strokeActive && !touchDrawingStrokeActive() && _starts.length >= 2) {
        onSecondFingerWhileDrawing();
      }
      _longPressTimer?.cancel();
      if (_starts.length == 1) {
        _longPressTimer = Timer(const Duration(milliseconds: 550), () {
          if (_activePointers.length == 1 &&
              !_moved &&
              !touchDrawingStrokeActive() &&
              !_gestureTriggered) {
            _gestureTriggered = true;
            _gesturePosition = _current.values.first;
            onLongPress(_gesturePosition);
          }
        });
      }
      return;
    }

    if (event is PointerMoveEvent) {
      _current[event.pointer] = event.localPosition;
      final start = _starts[event.pointer];
      if (start != null && (event.localPosition - start).distance > 12) {
        _moved = true;
        _longPressTimer?.cancel();
      }
      return;
    }

    if (event is PointerUpEvent || event is PointerCancelEvent) {
      _current[event.pointer] = event.localPosition;
      _activePointers.remove(event.pointer);
      if (_activePointers.isNotEmpty || _startedAt == null) return;

      _longPressTimer?.cancel();
      final startedAt = _startedAt!;
      if (!_gestureTriggered) {
        final gesture = classifyTouchGesture(
          starts: _starts,
          ends: _current,
          duration: DateTime.now().difference(startedAt),
          moved: _moved,
        );
        if (gesture != null) onGesture(gesture);
      }
      _resetSequence();
    }
  }

  void cancelLongPress() => _longPressTimer?.cancel();

  void reset() {
    _longPressTimer?.cancel();
    _activePointers.clear();
    _resetSequence();
  }

  void _resetSequence() {
    _starts.clear();
    _current.clear();
    _maximumTouchCount = 0;
    _startedAt = null;
    _gestureTriggered = false;
    _moved = false;
    _gesturePosition = null;
  }

  void dispose() => _longPressTimer?.cancel();
}
