import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'gesture_defaults.dart';

/// Immutable input state used to decide whether a stylus hold may fire.
class CanvasDrawAndHoldSnapshot {
  const CanvasDrawAndHoldSnapshot({
    required this.strokeActive,
    required this.constraintActive,
    required this.constraintStart,
    required this.stylusPosition,
    required this.nativeDrainScheduled,
    required this.pendingNativePackets,
    required this.strokeWorkQueueDepth,
    required this.gesture,
  });

  final bool strokeActive;
  final bool constraintActive;
  final Offset? constraintStart;
  final Offset? stylusPosition;
  final bool nativeDrainScheduled;
  final int pendingNativePackets;
  final int strokeWorkQueueDepth;
  final InkGesture? gesture;
}

/// Owns stylus draw-and-hold timing and rechecks queued input before firing.
class CanvasDrawAndHoldCoordinator {
  CanvasDrawAndHoldCoordinator({
    required this.snapshot,
    required this.recordActivation,
    required this.dispatch,
    this.holdDuration = const Duration(milliseconds: 320),
  });

  final CanvasDrawAndHoldSnapshot Function() snapshot;
  final void Function(Map<String, Object?> event) recordActivation;
  final void Function(InkGesture? gesture) dispatch;
  final Duration holdDuration;
  final Stopwatch _arrivalClock = Stopwatch()..start();

  Timer? _timer;
  int _lastInputArrivalUs = 0;
  bool _disposed = false;

  void recordInputArrival() {
    if (_disposed) return;
    _lastInputArrivalUs = _arrivalClock.elapsedMicroseconds;
    cancel();
  }

  void arm(Offset position) {
    cancel();
    if (_disposed) return;
    final current = snapshot();
    final constraintStart = current.constraintStart;
    if (current.constraintActive ||
        !current.strokeActive ||
        constraintStart == null) {
      return;
    }
    if ((position - constraintStart).distance < 8) return;

    final inputAgeMicros =
        _arrivalClock.elapsedMicroseconds - _lastInputArrivalUs;
    final remainingMicros = math.max(
      0,
      holdDuration.inMicroseconds - inputAgeMicros,
    );
    _timer = Timer(Duration(microseconds: remainingMicros), () {
      if (_disposed) return;
      final latest = snapshot();
      if (!latest.strokeActive ||
          latest.stylusPosition != position ||
          latest.nativeDrainScheduled ||
          latest.pendingNativePackets > 0 ||
          _arrivalClock.elapsedMicroseconds - _lastInputArrivalUs <
              holdDuration.inMicroseconds) {
        return;
      }
      recordActivation({
        'gesture': latest.gesture?.name,
        'triggerPosition': {'x': position.dx, 'y': position.dy},
        'constraintStart': {'x': constraintStart.dx, 'y': constraintStart.dy},
        'latestInputAgeUs':
            _arrivalClock.elapsedMicroseconds - _lastInputArrivalUs,
        'nativePacketQueueDepth': latest.pendingNativePackets,
        'strokeWorkQueueDepth': latest.strokeWorkQueueDepth,
      });
      dispatch(latest.gesture);
    });
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    _disposed = true;
    cancel();
  }
}
