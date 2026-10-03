import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/canvas/canvas_pointer_pressure_policy.dart';

void main() {
  group('CanvasPointerPressurePolicy', () {
    test('treats mouse input as firm despite zero reported pressure', () {
      const event = PointerDownEvent(
        kind: PointerDeviceKind.mouse,
        pressure: 0,
        pressureMin: 0,
        pressureMax: 1,
      );

      expect(CanvasPointerPressurePolicy.normalize(event), 1);
    });

    test('normalizes stylus pressure within the reported range', () {
      const event = PointerDownEvent(
        kind: PointerDeviceKind.stylus,
        pressure: 0.5,
        pressureMin: 0.2,
        pressureMax: 0.6,
      );

      expect(CanvasPointerPressurePolicy.normalize(event), closeTo(0.75, 1e-9));
    });

    test('uses bounded touch contact area when pressure is unavailable', () {
      const event = PointerDownEvent(
        kind: PointerDeviceKind.touch,
        pressure: 1,
        pressureMin: 0,
        pressureMax: 0,
        radiusMajor: 10,
        radiusMinor: 10,
      );

      expect(
        CanvasPointerPressurePolicy.normalize(event),
        closeTo(5 / 13, 1e-9),
      );
    });

    test('falls back to firm input for invalid or unavailable ranges', () {
      const event = PointerDownEvent(
        kind: PointerDeviceKind.stylus,
        pressure: double.nan,
        pressureMin: 0,
        pressureMax: 0,
      );

      expect(CanvasPointerPressurePolicy.normalize(event), 1);
    });
  });
}
