/// Screen-owned effects required to cancel an active canvas stroke.
class CanvasStrokeCancellationHost {
  const CanvasStrokeCancellationHost({
    required this.strokeActive,
    required this.cancelEngineStroke,
    required this.cancelPreviewSurface,
    required this.recordCancelFailure,
    required this.resetActiveStroke,
    required this.clearNativePageContact,
    required this.setAwaitingPreviewCommit,
    required this.clearPreview,
    required this.finishConstraint,
    required this.cancelStylusHold,
    required this.clearStylusPosition,
    required this.markDirty,
    required this.finishAutosaveHold,
  });

  final bool Function() strokeActive;
  final Future<void> Function() cancelEngineStroke;
  final void Function() cancelPreviewSurface;
  final void Function(Object error, StackTrace stack) recordCancelFailure;
  final void Function() resetActiveStroke;
  final void Function() clearNativePageContact;
  final void Function(bool awaiting) setAwaitingPreviewCommit;
  final void Function() clearPreview;
  final void Function() finishConstraint;
  final void Function() cancelStylusHold;
  final void Function() clearStylusPosition;
  final void Function() markDirty;
  final void Function({required String reason}) finishAutosaveHold;
}

/// Owns stroke cancellation and recovery cleanup shared across input paths.
class CanvasStrokeCancellationCoordinator {
  CanvasStrokeCancellationCoordinator(this.host);

  final CanvasStrokeCancellationHost host;

  /// Cancels the Rust transaction and recovers local state after packet errors.
  Future<void> abort({
    bool preservePreview = false,
    bool rethrowCancelFailure = false,
  }) async {
    if (!host.strokeActive()) {
      host.setAwaitingPreviewCommit(false);
      host.finishAutosaveHold(reason: 'stroke_abort_without_active_stroke');
      if (!preservePreview) host.clearPreview();
      return;
    }

    try {
      await host.cancelEngineStroke();
      host.cancelPreviewSurface();
    } catch (error, stack) {
      host.recordCancelFailure(error, stack);
      if (rethrowCancelFailure) Error.throwWithStackTrace(error, stack);
    }
    _resetAfterCancellation(
      reason: 'stroke_abort',
      preservePreview: preservePreview,
      markDirty: true,
    );
  }

  /// Resets local state after the caller has cancelled Rust at its queue edge.
  ///
  /// Touch cancellation uses this after its serialized active-touch ownership
  /// check and engine cancellation, and intentionally leaves dirty marking to
  /// its existing behavior.
  void finishExternalCancellation({
    required String reason,
    bool preservePreview = false,
    bool markDirty = false,
  }) {
    host.resetActiveStroke();
    host.cancelPreviewSurface();
    _resetAfterCancellation(
      reason: reason,
      preservePreview: preservePreview,
      markDirty: markDirty,
      resetActiveStroke: false,
    );
  }

  void _resetAfterCancellation({
    required String reason,
    required bool preservePreview,
    required bool markDirty,
    bool resetActiveStroke = true,
  }) {
    if (resetActiveStroke) host.resetActiveStroke();
    host.clearNativePageContact();
    host.setAwaitingPreviewCommit(false);
    if (!preservePreview) host.clearPreview();
    host.finishConstraint();
    host.cancelStylusHold();
    host.clearStylusPosition();
    if (markDirty) host.markDirty();
    host.finishAutosaveHold(reason: reason);
  }
}
