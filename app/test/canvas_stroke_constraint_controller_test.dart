import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/canvas/canvas_stroke_constraint_controller.dart';

void main() {
  group('CanvasStrokeConstraintController', () {
    test('straighten locks the first nontrivial stroke direction', () {
      final controller = CanvasStrokeConstraintController()..enableStraighten();
      controller.apply(Offset.zero, hasDown: true);
      controller.apply(const Offset(3, 4), hasDown: false);

      expect(
        controller.apply(const Offset(0, 10), hasDown: false),
        const Offset(4.8, 6.4),
      );
      expect(controller.mode, 'straighten');
      expect(controller.isActive, isTrue);
    });

    test('constrain snaps direction in 15 degree increments', () {
      final controller = CanvasStrokeConstraintController()..enableConstrain();
      controller.apply(Offset.zero, hasDown: true);
      final constrained = controller.apply(const Offset(10, 3), hasDown: false);

      expect(
        math.atan2(constrained.dy, constrained.dx),
        closeTo(math.pi / 12, 1e-9),
      );
      expect(constrained.distance, closeTo(math.sqrt(109), 1e-9));
      expect(controller.mode, 'constrain');
    });

    test('changing mode and resetting releases stroke-local state', () {
      final controller =
          CanvasStrokeConstraintController()
            ..enableStraighten()
            ..apply(const Offset(5, 8), hasDown: true)
            ..enableConstrain();

      expect(controller.mode, 'constrain');
      expect(controller.strokeStart, const Offset(5, 8));
      controller.reset();
      expect(controller.mode, 'none');
      expect(controller.isActive, isFalse);
      expect(controller.strokeStart, isNull);

      expect(
        controller.apply(const Offset(12, 14), hasDown: false),
        const Offset(12, 14),
      );
    });
  });
}
