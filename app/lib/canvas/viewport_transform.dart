import 'dart:math' as math;
import 'dart:ui';

/// The viewport transform used by the drawing canvas.
///
/// The document remains centered in the canvas. [pan] is a screen-space
/// translation, while [scale] and [rotation] transform the document around
/// that center. Keeping this math outside the widget makes the gesture path
/// deterministic and gives every platform the same zoom behavior.
class CanvasViewport {
  const CanvasViewport({
    required this.pan,
    required this.scale,
    required this.rotation,
  });

  static const minScale = 0.001;
  static const maxScale = 32.0;

  final Offset pan;
  final double scale;
  final double rotation;

  /// Return a neutral, centered transform that fits the complete document in
  /// the available viewport. The margin leaves a small amount of breathing
  /// room around the page, while the lower zoom bound still allows the largest
  /// supported documents to fit on compact displays.
  static CanvasViewport fitDocument({
    required Size viewportSize,
    required Size documentSize,
    double margin = 0.92,
  }) {
    if (!_isUsableSize(viewportSize) || !_isUsableSize(documentSize)) {
      return const CanvasViewport(pan: Offset.zero, scale: 1, rotation: 0);
    }

    final safeMargin = margin.isFinite ? margin.clamp(0.1, 1.0) : 0.92;
    final fitScale =
        math.min(
          viewportSize.width / documentSize.width,
          viewportSize.height / documentSize.height,
        ) *
        safeMargin;
    return CanvasViewport(
      pan: Offset.zero,
      scale: clampScale(fitScale),
      rotation: 0,
    );
  }

  static bool _isUsableSize(Size size) =>
      size.width.isFinite &&
      size.height.isFinite &&
      size.width > 0 &&
      size.height > 0;

  /// Apply one Flutter scale gesture while keeping the content beneath the
  /// gesture's focal point stationary. This avoids jumps when a second
  /// finger lands or lifts during a pinch.
  CanvasViewport applyGesture({
    required Size viewportSize,
    required Offset startFocalPoint,
    required Offset focalPoint,
    required double scaleFactor,
    required double rotationDelta,
  }) {
    if (viewportSize.isEmpty) return this;

    final safeScaleFactor =
        scaleFactor.isFinite && scaleFactor > 0 ? scaleFactor : 1.0;
    final safeStartScale = clampScale(scale);
    final nextScale = clampScale(safeStartScale * safeScaleFactor);
    final safeStartRotation = rotation.isFinite ? rotation : 0.0;
    final nextRotation =
        safeStartRotation + (rotationDelta.isFinite ? rotationDelta : 0.0);
    final center = viewportSize.center(Offset.zero);

    // Convert the point under the initial focal point back into document
    // centered coordinates, then map that same point into the new transform.
    final startScreenVector = startFocalPoint - center - pan;
    final documentVector = _rotate(
      startScreenVector / safeStartScale,
      -safeStartRotation,
    );
    final nextScreenVector = _rotate(documentVector * nextScale, nextRotation);
    final nextPan = focalPoint - center - nextScreenVector;
    return CanvasViewport(
      pan: nextPan,
      scale: nextScale,
      rotation: nextRotation,
    );
  }

  static double clampScale(double value) =>
      (value.isFinite ? value : 1.0).clamp(minScale, maxScale).toDouble();

  static Offset _rotate(Offset value, double radians) {
    final sine = math.sin(radians);
    final cosine = math.cos(radians);
    return Offset(
      value.dx * cosine - value.dy * sine,
      value.dx * sine + value.dy * cosine,
    );
  }
}
