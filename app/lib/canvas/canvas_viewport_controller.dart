import 'dart:math' as math;
import 'dart:ui';

import '../app/editor_action.dart';
import 'viewport_transform.dart';

/// Owns the canvas transform and the baseline for an active scale gesture.
///
/// The screen remains responsible for repaint scheduling and obtaining the
/// canvas bounds. This controller owns only viewport state and transform math.
class CanvasViewportController {
  CanvasViewportController({
    CanvasViewport viewport = const CanvasViewport(
      pan: Offset.zero,
      scale: 1,
      rotation: 0,
    ),
    bool mirrored = false,
  }) : _viewport = viewport,
       _mirrored = mirrored;

  CanvasViewport _viewport;
  bool _mirrored;
  CanvasViewport? _gestureStartViewport;
  Offset? _gestureStartFocalPoint;

  CanvasViewport get viewport => _viewport;
  bool get mirrored => _mirrored;

  void beginScaleGesture(Offset focalPoint) {
    _gestureStartViewport = _viewport;
    _gestureStartFocalPoint = focalPoint;
  }

  void updateScaleGesture({
    required Size viewportSize,
    required Offset focalPoint,
    required double scaleFactor,
    required double rotationDelta,
  }) {
    final startViewport = _gestureStartViewport;
    final startFocalPoint = _gestureStartFocalPoint;
    if (startViewport == null || startFocalPoint == null) return;
    _viewport = startViewport.applyGesture(
      viewportSize: viewportSize,
      startFocalPoint: startFocalPoint,
      focalPoint: focalPoint,
      scaleFactor: scaleFactor,
      rotationDelta: rotationDelta,
    );
  }

  void endScaleGesture() {
    _gestureStartViewport = null;
    _gestureStartFocalPoint = null;
  }

  void fitDocument({required Size viewportSize, required Size documentSize}) {
    _viewport = CanvasViewport.fitDocument(
      viewportSize: viewportSize,
      documentSize: documentSize,
    );
  }

  void toggleMirror() => _mirrored = !_mirrored;

  /// Returns viewport commands that need no widget or layout access.
  ///
  /// Fit-to-document remains with the screen because it must obtain the live
  /// render bounds and document dimensions. The screen invokes this callback
  /// inside its rebuild boundary.
  void Function()? editorActionHandler(EditorActionId action) =>
      switch (action) {
        EditorActionId.mirrorCanvas => toggleMirror,
        EditorActionId.resetRotation => resetRotation,
        EditorActionId.actualPixels => showActualPixels,
        _ => null,
      };

  void resetRotation() =>
      _viewport = CanvasViewport(
        pan: _viewport.pan,
        scale: _viewport.scale,
        rotation: 0,
      );

  void showActualPixels() =>
      _viewport = CanvasViewport(
        pan: _viewport.pan,
        scale: 1,
        rotation: _viewport.rotation,
      );

  Offset documentPosition({
    required Offset localPosition,
    required Size viewportSize,
    required Size documentSize,
  }) {
    final centered =
        localPosition - viewportSize.center(Offset.zero) - _viewport.pan;
    final inverseScale = centered / _viewport.scale;
    final sine = math.sin(_viewport.rotation);
    final cosine = math.cos(_viewport.rotation);
    final unrotated = Offset(
      inverseScale.dx * cosine + inverseScale.dy * sine,
      -inverseScale.dx * sine + inverseScale.dy * cosine,
    );
    return unrotated + documentSize.center(Offset.zero);
  }
}
