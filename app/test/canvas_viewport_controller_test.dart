import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/app/editor_action.dart';
import 'package:project_ink/canvas/canvas_viewport_controller.dart';
import 'package:project_ink/canvas/viewport_transform.dart';

void main() {
  group('CanvasViewportController', () {
    test('routes viewport actions and declines unrelated editor actions', () {
      final controller = CanvasViewportController(
        viewport: const CanvasViewport(
          pan: Offset(2, 3),
          scale: 2,
          rotation: 0.4,
        ),
      );

      final mirrorAction = controller.editorActionHandler(
        EditorActionId.mirrorCanvas,
      );
      expect(mirrorAction, isNotNull);
      mirrorAction!();
      expect(controller.mirrored, isTrue);
      final resetRotationAction = controller.editorActionHandler(
        EditorActionId.resetRotation,
      );
      expect(resetRotationAction, isNotNull);
      resetRotationAction!();
      expect(controller.viewport.rotation, 0);
      final actualPixelsAction = controller.editorActionHandler(
        EditorActionId.actualPixels,
      );
      expect(actualPixelsAction, isNotNull);
      actualPixelsAction!();
      expect(controller.viewport.scale, 1);
      expect(controller.editorActionHandler(EditorActionId.undo), isNull);
    });

    test('fits, mirrors, resets rotation, and shows actual pixels', () {
      final controller = CanvasViewportController(
        viewport: const CanvasViewport(
          pan: Offset(7, -4),
          scale: 2,
          rotation: 0.5,
        ),
      );

      controller.toggleMirror();
      expect(controller.mirrored, isTrue);
      controller.resetRotation();
      expect(controller.viewport.rotation, 0);
      expect(controller.viewport.pan, const Offset(7, -4));
      controller.showActualPixels();
      expect(controller.viewport.scale, 1);
      expect(controller.viewport.rotation, 0);

      controller.fitDocument(
        viewportSize: const Size(400, 300),
        documentSize: const Size(200, 100),
      );
      expect(controller.viewport.pan, Offset.zero);
      expect(controller.viewport.scale, closeTo(1.84, 1e-9));
      expect(controller.viewport.rotation, 0);
    });

    test('maps local positions through inverse viewport transform', () {
      final controller = CanvasViewportController(
        viewport: const CanvasViewport(
          pan: Offset(30, -20),
          scale: 2,
          rotation: 0,
        ),
      );

      expect(
        controller.documentPosition(
          localPosition: const Offset(430, 280),
          viewportSize: const Size(400, 300),
          documentSize: const Size(1000, 800),
        ),
        const Offset(600, 475),
      );
    });

    test('applies a scale gesture from its captured baseline', () {
      final controller = CanvasViewportController();
      controller.beginScaleGesture(const Offset(200, 150));
      controller.updateScaleGesture(
        viewportSize: const Size(400, 300),
        focalPoint: const Offset(220, 170),
        scaleFactor: 2,
        rotationDelta: 0,
      );

      expect(controller.viewport.scale, 2);
      expect(controller.viewport.pan, const Offset(20, 20));
      controller.endScaleGesture();
      final ended = controller.viewport;
      controller.updateScaleGesture(
        viewportSize: const Size(400, 300),
        focalPoint: Offset.zero,
        scaleFactor: 4,
        rotationDelta: 1,
      );
      expect(controller.viewport, same(ended));
    });
  });
}
