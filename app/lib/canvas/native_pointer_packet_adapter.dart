import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'live_stroke_coordinator.dart';
import 'native_pointer_stream.dart';
import 'pointer_packet.dart';

/// A validated packet translated into canvas coordinates and ordered sequences.
class PreparedNativePointerPacket {
  PreparedNativePointerPacket({
    required this.bytes,
    required this.beginsStroke,
    required List<LiveStrokePreviewPoint> previewSamples,
  }) : previewSamples = List.unmodifiable(previewSamples);

  final Uint8List bytes;
  final bool beginsStroke;
  final List<LiveStrokePreviewPoint> previewSamples;
}

/// Translates native packet coordinates and derives confirmed preview samples.
///
/// The caller supplies the current viewport/constraint transform and sequence
/// source because those belong to the active canvas session, not the platform
/// packet format.
class NativePointerPacketAdapter {
  bool containsHoverSample(Uint8List packet) {
    if (packet.length < 4) return false;
    final data = ByteData.sublistView(packet);
    final count = data.getUint16(2, Endian.little);
    for (var index = 0; index < count; index++) {
      final offset = 4 + index * 48;
      if (offset + 48 > packet.length) break;
      if (data.getUint16(offset + 4, Endian.little) & inkPointerHover != 0) {
        return true;
      }
    }
    return false;
  }

  Offset? hoverPosition(Uint8List packet) {
    if (packet.length < 4) return null;
    final data = ByteData.sublistView(packet);
    final count = data.getUint16(2, Endian.little);
    Offset? latest;
    for (var index = 0; index < count; index++) {
      final offset = 4 + index * 48;
      if (offset + 48 > packet.length) break;
      final flags = data.getUint16(offset + 4, Endian.little);
      final phase = data.getUint8(offset + 7);
      if (flags & inkPointerHover == 0 ||
          phase == InkPointerPhase.cancel.index) {
        continue;
      }
      latest = Offset(
        data.getFloat32(offset + 8, Endian.little),
        data.getFloat32(offset + 12, Endian.little),
      );
    }
    return latest;
  }

  Offset? lastConfirmedPosition(Uint8List packet) {
    if (packet.length < 4) return null;
    final data = ByteData.sublistView(packet);
    final count = data.getUint16(2, Endian.little);
    Offset? latest;
    for (var index = 0; index < count; index++) {
      final offset = 4 + index * 48;
      if (offset + 48 > packet.length) break;
      final flags = data.getUint16(offset + 4, Endian.little);
      final phase = data.getUint8(offset + 7);
      final confirmed =
          flags & (inkPointerActual | inkPointerCoalesced) != 0 &&
          flags &
                  (inkPointerPredicted |
                      inkPointerHover |
                      inkPointerPalmRejected) ==
              0;
      if (!confirmed ||
          (phase != InkPointerPhase.down.index &&
              phase != InkPointerPhase.move.index &&
              phase != InkPointerPhase.up.index)) {
        continue;
      }
      latest = Offset(
        data.getFloat32(offset + 8, Endian.little),
        data.getFloat32(offset + 12, Endian.little),
      );
    }
    return latest;
  }

  PreparedNativePointerPacket prepare(
    Uint8List packet, {
    required Offset Function(Offset screenPosition, bool isDownSample)
    transformPosition,
    required int Function() nextSequence,
  }) {
    final beginsStroke = packetHasPhase(packet, InkPointerPhase.down);
    final source = ByteData.sublistView(packet);
    var sampleIndex = 0;
    var firstSample = true;
    final canonicalSequences = <int>[];
    final previewSamples = <LiveStrokePreviewPoint>[];
    final transformed = transformPointerPacket(packet, (screenPosition) {
      final offset = 4 + sampleIndex * 48;
      final flags = source.getUint16(offset + 4, Endian.little);
      final phase = source.getUint8(offset + 7);
      final pressure = source.getFloat32(offset + 16, Endian.little);
      final isDownSample = beginsStroke && firstSample;
      final sequence = nextSequence();
      canonicalSequences.add(sequence);
      sampleIndex++;
      final position = transformPosition(screenPosition, isDownSample);
      final confirmed =
          flags & (inkPointerActual | inkPointerCoalesced) != 0 &&
          flags &
                  (inkPointerPredicted |
                      inkPointerHover |
                      inkPointerPalmRejected) ==
              0;
      if (confirmed &&
          (phase == InkPointerPhase.down.index ||
              phase == InkPointerPhase.move.index ||
              phase == InkPointerPhase.up.index)) {
        previewSamples.add(
          LiveStrokePreviewPoint(position, pressure, sourceSequence: sequence),
        );
      }
      firstSample = false;
      return position;
    });
    final transformedData = ByteData.sublistView(transformed);
    for (var index = 0; index < canonicalSequences.length; index++) {
      transformedData.setUint32(
        4 + index * 48 + 44,
        canonicalSequences[index],
        Endian.little,
      );
    }
    return PreparedNativePointerPacket(
      bytes: transformed,
      beginsStroke: beginsStroke,
      previewSamples: previewSamples,
    );
  }
}
