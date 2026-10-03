import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/canvas/canvas_input_coordinate_policy.dart';
import 'package:project_ink/tools/illustration_tools.dart';

void main() {
  group('CanvasInputCoordinatePolicy', () {
    test('clamps external input and stroke positions to their bounds', () {
      expect(
        CanvasInputCoordinatePolicy.safeInput(const Offset(90000, -90000)),
        const Offset(65536, -65536),
      );
      expect(
        CanvasInputCoordinatePolicy.boundToDocument(
          const Offset(-10, 200),
          const Size(100, 80),
        ),
        const Offset(0, 79),
      );
    });

    test('projects brush positions to straight and symmetry rulers', () {
      expect(
        CanvasInputCoordinatePolicy.snapToRuler(
          position: const Offset(30, 12),
          activeTool: IllustrationTool.brush,
          rulerStart: Offset.zero,
          rulerEnd: const Offset(20, 0),
          rulerTool: IllustrationTool.straightRuler,
        ),
        const Offset(30, 0),
      );
      expect(
        CanvasInputCoordinatePolicy.snapToRuler(
          position: const Offset(30, 12),
          activeTool: IllustrationTool.brush,
          rulerStart: Offset.zero,
          rulerEnd: const Offset(20, 0),
          rulerTool: IllustrationTool.symmetryRuler,
        ),
        const Offset(30, -12),
      );
    });

    test('leaves non-brush tools and inactive rulers unchanged', () {
      const position = Offset(13, 17);
      expect(
        CanvasInputCoordinatePolicy.snapToRuler(
          position: position,
          activeTool: IllustrationTool.rectangleSelect,
          rulerStart: Offset.zero,
          rulerEnd: const Offset(20, 0),
          rulerTool: IllustrationTool.straightRuler,
        ),
        position,
      );
      expect(
        CanvasInputCoordinatePolicy.snapToRuler(
          position: position,
          activeTool: IllustrationTool.eraser,
          rulerStart: null,
          rulerEnd: null,
          rulerTool: null,
        ),
        position,
      );
    });
  });
}
