import 'dart:math' as math;

import 'package:flutter/gestures.dart';

/// Normalizes Flutter pressure values at the input boundary.
abstract final class CanvasPointerPressurePolicy {
  static double normalize(PointerEvent event) {
    // Flutter reports no meaningful pressure for a conventional mouse. A
    // zero-pressure mouse packet would make pressure-sensitive brushes vanish.
    if (event.kind == PointerDeviceKind.mouse) return 1.0;
    final pressure = event.pressure;
    if (!pressure.isFinite) return 1.0;

    final range = event.pressureMax - event.pressureMin;
    if (range <= 0 || !range.isFinite) {
      if (event.kind == PointerDeviceKind.touch) {
        // Some iPad touchscreens expose no force data. Contact area is a
        // bounded proxy; finger angle also affects it, so it is not force.
        final major = event.radiusMajor;
        final minor = event.radiusMinor > 0 ? event.radiusMinor : major;
        if (major.isFinite && minor.isFinite && major > 0 && minor > 0) {
          final contactRadius = math.sqrt(major * minor);
          return ((contactRadius - 5.0) / 13.0).clamp(0.0, 1.0).toDouble();
        }
      }
      return 1.0;
    }
    return ((pressure - event.pressureMin) / range).clamp(0.0, 1.0).toDouble();
  }
}
