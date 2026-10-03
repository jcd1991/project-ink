/// Owns the autosave continuous-edit hold shared by canvas stroke paths.
///
/// The screen supplies the autosave effects and queue observations; this
/// controller guarantees that one accepted hold has at most one matching end.
class CanvasStrokeAutosaveHold {
  CanvasStrokeAutosaveHold({
    required this.beginContinuousEdit,
    required this.endContinuousEdit,
    required this.nativePacketQueueDepth,
    required this.strokeWorkQueueDepth,
    required this.recordDiagnostic,
  });

  final void Function() beginContinuousEdit;
  final void Function() endContinuousEdit;
  final int Function() nativePacketQueueDepth;
  final int Function() strokeWorkQueueDepth;
  final void Function(String event, Map<String, Object?> fields)
  recordDiagnostic;

  bool _active = false;

  bool get isActive => _active;

  void begin() {
    if (_active) return;
    _active = true;
    beginContinuousEdit();
    recordDiagnostic('canvas.autosave_deferred_for_stroke', {
      'nativePacketQueueDepth': nativePacketQueueDepth(),
      'strokeWorkQueueDepth': strokeWorkQueueDepth(),
    });
  }

  void finish({required String reason}) {
    if (!_active) return;
    _active = false;
    endContinuousEdit();
    recordDiagnostic('canvas.autosave_resumed_after_stroke', {
      'reason': reason,
      'nativePacketQueueDepth': nativePacketQueueDepth(),
      'strokeWorkQueueDepth': strokeWorkQueueDepth(),
    });
  }
}
