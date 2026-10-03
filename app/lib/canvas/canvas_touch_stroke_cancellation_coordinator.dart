/// Input and effects needed by serialized touch-stroke cancellation.
class CanvasTouchStrokeCancellationHost {
  const CanvasTouchStrokeCancellationHost({
    required this.enqueueStrokeWork,
    required this.strokeActive,
    required this.activeStrokeIsTouch,
    required this.touchPointerCounts,
    required this.cancelRustStroke,
    required this.engineRevision,
    required this.finishExternalCancellation,
    required this.refreshTiles,
    required this.recordDiagnostic,
  });

  final void Function(Future<void> Function() operation) enqueueStrokeWork;
  final bool Function() strokeActive;
  final bool Function() activeStrokeIsTouch;
  final ({int active, int tracked}) Function() touchPointerCounts;
  final Future<void> Function() cancelRustStroke;
  final int Function() engineRevision;
  final void Function({required String reason}) finishExternalCancellation;
  final void Function() refreshTiles;
  final void Function(String event, Map<String, Object?> fields)
  recordDiagnostic;
}

/// Owns the touch-stroke marker and protects queued cancellation by ownership.
///
/// A touch cancel may wait behind earlier bridge work. It checks ownership at
/// execution time so a later Pencil stroke cannot be canceled by that queued
/// touch operation. Shared Rust/local stroke cleanup remains with the stroke
/// cancellation coordinator supplied by the host.
class CanvasTouchStrokeCancellationCoordinator {
  CanvasTouchStrokeCancellationCoordinator(this.host);

  final CanvasTouchStrokeCancellationHost host;
  bool _touchStrokeActive = false;

  bool get isActive => _touchStrokeActive;

  void setActive(bool active) {
    _touchStrokeActive = active;
  }

  void cancel({required String reason}) {
    if (!_touchStrokeActive) return;
    final counts = host.touchPointerCounts();
    host.recordDiagnostic('input.touch_stroke_cancel_requested', {
      'reason': reason,
      'strokeActive': host.strokeActive(),
      'activeStrokeIsTouch': host.activeStrokeIsTouch(),
      'activeTouchPointerCount': counts.active,
      'trackedTouchCount': counts.tracked,
    });
    _touchStrokeActive = false;

    host.enqueueStrokeWork(() async {
      if (!host.strokeActive() || !host.activeStrokeIsTouch()) {
        host.recordDiagnostic('input.touch_cancel_ignored', {
          'activeStroke': host.strokeActive(),
          'activeStrokeIsTouch': host.activeStrokeIsTouch(),
        });
        return;
      }

      await host.cancelRustStroke();
      final revision = host.engineRevision();
      host.recordDiagnostic('input.stroke_end', {
        'source': 'touch_gesture_cancel',
        'terminalPhase': 'cancel',
        'reason': reason,
        'engineRevision': revision,
      });
      host.recordDiagnostic('canvas.stroke_cancelled', {
        'source': 'touch_gesture_cancel',
        'reason': reason,
        'engineRevision': revision,
      });
      host.finishExternalCancellation(reason: 'touch_cancel');
      host.refreshTiles();
    });
  }
}
