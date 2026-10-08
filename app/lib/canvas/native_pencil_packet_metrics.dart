import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';

import 'pointer_packet.dart';

class NativePencilPacketObservation {
  const NativePencilPacketObservation({
    this.crossingSampleCount,
    this.crossingPosition,
    this.reentrySampleIndex,
  });

  final int? crossingSampleCount;
  final Offset? crossingPosition;
  final int? reentrySampleIndex;
}

/// Per-stroke diagnostics and page-edge detection for confirmed Pencil input.
///
/// Rust still clips the committed raster. This tracker stops queuing off-page
/// samples after a confirmed exit while retaining the crossing sample, and
/// identifies the first confirmed sample after the pointer re-enters.
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
  /// [captureAlreadyEnded] suppresses another exit notification while still
  /// tracking confirmed re-entry.
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
    int? crossingSampleCount;
    Offset? crossingPosition;
    int? reentrySampleIndex;
    var outsideGap = captureAlreadyEnded;
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
          !captureAlreadyEnded &&
          phase != InkPointerPhase.down.index &&
          lastConfirmedSampleInside &&
          !inside &&
          crossingSampleCount == null) {
        crossingSampleCount = index + 1;
        crossingPosition = position;
        outsideGap = true;
      }
      if (confirmed) {
        if (outsideGap && inside && reentrySampleIndex == null) {
          reentrySampleIndex = index;
          outsideGap = false;
        }
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
      reentrySampleIndex: reentrySampleIndex,
    );
  }
}
