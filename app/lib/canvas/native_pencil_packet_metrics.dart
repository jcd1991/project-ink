import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';

import 'pointer_packet.dart';

class NativePencilPacketObservation {
  const NativePencilPacketObservation({
    this.crossingSampleCount,
    this.crossingPosition,
  });

  final int? crossingSampleCount;
  final Offset? crossingPosition;
}

/// Per-stroke diagnostics and page-edge detection for confirmed Pencil input.
///
/// Rust still clips the committed raster. This tracker stops queuing samples
/// after the first confirmed exit while retaining the crossing sample so Rust
/// can finish the visible segment.
class NativePencilPacketMetrics {
  int packetCount = 0;
  int sampleCount = 0;
  double minPressure = 1.0;
  double maxPressure = 0.0;
  bool lastConfirmedSampleInside = false;

  void beginStroke() {
    packetCount = 0;
    sampleCount = 0;
    minPressure = 1.0;
    maxPressure = 0.0;
    lastConfirmedSampleInside = false;
  }

  void clearPageContact() => lastConfirmedSampleInside = false;

  /// Records packet accounting and returns the first crossing sample index.
  /// [captureAlreadyEnded] keeps later captured packets from moving the
  /// boundary tracker back into the document.
  NativePencilPacketObservation observePacket(
    Uint8List packet, {
    required bool captureAlreadyEnded,
    required bool Function(Offset position) isInsideDocument,
  }) {
    if (packet.length < 4) return const NativePencilPacketObservation();
    final data = ByteData.sublistView(packet);
    final count = data.getUint16(2, Endian.little);
    packetCount++;
    sampleCount += count;
    if (captureAlreadyEnded) return const NativePencilPacketObservation();

    int? crossingSampleCount;
    Offset? crossingPosition;
    for (var index = 0; index < count; index++) {
      final offset = 4 + index * 48;
      final flags = data.getUint16(offset + 4, Endian.little);
      final phase = data.getUint8(offset + 7);
      final pressure = data.getFloat32(offset + 16, Endian.little);
      final position = Offset(
        data.getFloat32(offset + 8, Endian.little),
        data.getFloat32(offset + 12, Endian.little),
      );
      final inside = isInsideDocument(position);
      final confirmed =
          flags & (inkPointerActual | inkPointerCoalesced) != 0 &&
          flags &
                  (inkPointerPredicted |
                      inkPointerHover |
                      inkPointerPalmRejected) ==
              0;
      if (confirmed &&
          phase != InkPointerPhase.down.index &&
          lastConfirmedSampleInside &&
          !inside &&
          crossingSampleCount == null) {
        crossingSampleCount = index + 1;
        crossingPosition = position;
      }
      if (confirmed) {
        lastConfirmedSampleInside = inside;
        if (pressure.isFinite) {
          minPressure = math.min(minPressure, pressure);
          maxPressure = math.max(maxPressure, pressure);
        }
      }
    }
    return NativePencilPacketObservation(
      crossingSampleCount: crossingSampleCount,
      crossingPosition: crossingPosition,
    );
  }
}
