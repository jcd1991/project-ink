import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/canvas/viewport_transform.dart';

void main() {
  const viewportSize = Size(800, 600);
  const startFocalPoint = Offset(320, 240);

  test('pinch zoom keeps the content below the focal point anchored', () {
    const start = CanvasViewport(
      pan: Offset(24, -12),
      scale: 1.5,
      rotation: 0.2,
    );
    final next = start.applyGesture(
      viewportSize: viewportSize,
      startFocalPoint: startFocalPoint,
      focalPoint: startFocalPoint,
      scaleFactor: 2,
      rotationDelta: 0,
    );

    expect(next.scale, 3);
    expect(next.pan, isNot(equals(start.pan)));
    expect(next.rotation, start.rotation);
  });

  test(
    'two-finger translation remains a translation when scale is unchanged',
    () {
      const start = CanvasViewport(
        pan: Offset(24, -12),
        scale: 1.5,
        rotation: 0.2,
      );
      final next = start.applyGesture(
        viewportSize: viewportSize,
        startFocalPoint: startFocalPoint,
        focalPoint: const Offset(350, 275),
        scaleFactor: 1,
        rotationDelta: 0,
      );

      expect(next.scale, start.scale);
      expect(next.rotation, start.rotation);
      expect(next.pan, start.pan + const Offset(30, 35));
    },
  );

  test('invalid and extreme scale values fail closed to bounded values', () {
    const start = CanvasViewport(pan: Offset.zero, scale: 1, rotation: 0);
    final next = start.applyGesture(
      viewportSize: viewportSize,
      startFocalPoint: startFocalPoint,
      focalPoint: startFocalPoint,
      scaleFactor: double.infinity,
      rotationDelta: double.nan,
    );

    expect(next.scale, 1);
    expect(next.rotation, 0);
    expect(CanvasViewport.clampScale(-100), CanvasViewport.minScale);
    expect(CanvasViewport.clampScale(100), CanvasViewport.maxScale);
  });

  test('fit document scales both dimensions inside the viewport', () {
    final fitted = CanvasViewport.fitDocument(
      viewportSize: const Size(800, 600),
      documentSize: const Size(2048, 1024),
    );

    expect(fitted.scale, closeTo((800 / 2048) * 0.92, 1e-12));
    expect(2048 * fitted.scale, lessThanOrEqualTo(800));
    expect(1024 * fitted.scale, lessThanOrEqualTo(600));
    expect(fitted.pan, Offset.zero);
    expect(fitted.rotation, 0);
  });

  test('fit document supports large pages on compact viewports', () {
    final fitted = CanvasViewport.fitDocument(
      viewportSize: const Size(280, 520),
      documentSize: const Size(32768, 32768),
    );

    expect(fitted.scale, greaterThan(CanvasViewport.minScale));
    expect(32768 * fitted.scale, lessThanOrEqualTo(280));
    expect(32768 * fitted.scale, lessThanOrEqualTo(520));
  });

  test('invalid fit dimensions return a neutral transform', () {
    final fitted = CanvasViewport.fitDocument(
      viewportSize: Size.zero,
      documentSize: const Size(2048, 2048),
    );

    expect(fitted.scale, 1);
    expect(fitted.pan, Offset.zero);
    expect(fitted.rotation, 0);
  });
}
