import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/canvas/canvas_smart_guides.dart';

void main() {
  test('snaps edge, center, and anchor features on both axes', () {
    final result = snapCanvasSmartGuides(
      movingX: const [10, 20],
      movingY: const [10, 30],
      referenceX: const [34, 39],
      referenceY: const [41],
      requestedDelta: const math.Point(18, 10),
      tolerance: 3,
    );

    expect(result.delta, const math.Point<double>(19, 11));
    expect(result.verticalX, 39);
    expect(result.horizontalY, 41);
  });

  test('uses deterministic tie breaking and ignores distant references', () {
    final tied = snapCanvasSmartGuides(
      movingX: const [0],
      movingY: const [0],
      referenceX: const [2, -2],
      referenceY: const [100],
      requestedDelta: const math.Point(0, 0),
      tolerance: 2,
    );
    expect(tied.verticalX, -2);
    expect(tied.horizontalY, isNull);

    final distant = snapCanvasSmartGuides(
      movingX: const [0],
      movingY: const [0],
      referenceX: const [20],
      referenceY: const [20],
      requestedDelta: const math.Point(0, 0),
      tolerance: 2,
    );
    expect(distant.delta, const math.Point<double>(0, 0));
    expect(distant.verticalX, isNull);
    expect(distant.horizontalY, isNull);
  });
}
