/// Input source whose terminal event completed the current canvas stroke.
enum CanvasStrokeCompletionOrigin { flutterPointer, nativePencil }

/// Screen-owned effects used to publish a stroke's terminal transition.
class CanvasStrokeCompletionHost {
  const CanvasStrokeCompletionHost({
    required this.resetActiveStroke,
    required this.clearNativePageContact,
    required this.setAwaitingPreviewCommit,
    required this.clearPreview,
    required this.retirePreview,
    required this.recordFlutterCancellation,
    required this.finishConstraint,
    required this.cancelStylusHold,
    required this.clearStylusPosition,
    required this.finishAutosaveHold,
    required this.refreshLayerThumbnails,
    required this.refreshTiles,
  });

  final void Function() resetActiveStroke;
  final void Function() clearNativePageContact;
  final void Function(bool awaiting) setAwaitingPreviewCommit;
  final void Function() clearPreview;
  final void Function(String source) retirePreview;
  final void Function(String pointerKind) recordFlutterCancellation;
  final void Function() finishConstraint;
  final void Function() cancelStylusHold;
  final void Function() clearStylusPosition;
  final void Function({required String reason}) finishAutosaveHold;
  final void Function() refreshLayerThumbnails;
  final void Function() refreshTiles;
}

/// Owns the shared terminal ordering for native and Flutter input strokes.
///
/// Source-specific cleanup differences (native contact reset, preview labels,
/// and Flutter cancellation diagnostics) are represented explicitly so the
/// callers share one lifecycle sequence without collapsing input semantics.
class CanvasStrokeCompletionCoordinator {
  CanvasStrokeCompletionCoordinator(this.host);

  final CanvasStrokeCompletionHost host;

  void finish({
    required CanvasStrokeCompletionOrigin origin,
    required bool cancelled,
    required bool boundaryEnded,
    required String reason,
    String? pointerKind,
  }) {
    host.resetActiveStroke();
    if (origin == CanvasStrokeCompletionOrigin.nativePencil) {
      host.clearNativePageContact();
    }
    host.setAwaitingPreviewCommit(!cancelled);
    if (cancelled) {
      host.clearPreview();
      if (origin == CanvasStrokeCompletionOrigin.flutterPointer &&
          !boundaryEnded &&
          pointerKind != null) {
        host.recordFlutterCancellation(pointerKind);
      }
    } else {
      host.retirePreview(_previewSource(origin, boundaryEnded));
    }
    host.finishConstraint();
    host.cancelStylusHold();
    host.clearStylusPosition();
    host.finishAutosaveHold(reason: reason);
    if (origin == CanvasStrokeCompletionOrigin.flutterPointer ||
        boundaryEnded) {
      host.refreshLayerThumbnails();
    }
    host.refreshTiles();
  }

  String _previewSource(
    CanvasStrokeCompletionOrigin origin,
    bool boundaryEnded,
  ) => switch ((origin, boundaryEnded)) {
    (CanvasStrokeCompletionOrigin.nativePencil, true) =>
      'native_pencil_boundary_end',
    (CanvasStrokeCompletionOrigin.nativePencil, false) => 'native_pencil_end',
    (CanvasStrokeCompletionOrigin.flutterPointer, true) =>
      'pointer_boundary_end',
    (CanvasStrokeCompletionOrigin.flutterPointer, false) =>
      'flutter_pointer_end',
  };
}
