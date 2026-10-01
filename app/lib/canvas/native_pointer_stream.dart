import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'pointer_packet.dart';

const nativePointerPacketChannel = 'org.projectink.studio/pointer_packets_v1';
const nativePointerStatusChannel = 'org.projectink.studio/pointer_status_v1';
const nativePencilCommandChannel = 'org.projectink.studio/pencil_commands_v1';
const nativeCanvasDiagnosticsChannel =
    'org.projectink.studio/canvas_diagnostics_v1';

/// Binary stylus packets emitted by the iOS Pencil and Android S Pen seams.
Stream<Uint8List> nativePointerPackets() => const EventChannel(
  nativePointerPacketChannel,
).receiveBroadcastStream().map<Uint8List>((dynamic value) {
  if (value is Uint8List) return value;
  if (value is List<dynamic>) {
    return Uint8List.fromList(value.cast<int>());
  }
  throw const FormatException('native pointer event is not binary');
});

/// Emits once the native packet channel has a live Flutter listener. Until
/// this signal arrives, the canvas keeps the generic stylus path available so
/// a startup race cannot swallow the first contact.
Stream<void> nativePointerReady() =>
    const EventChannel(nativePointerStatusChannel)
        .receiveBroadcastStream()
        .where((dynamic value) => value == 'ready')
        .map<void>((_) {});

/// Discrete Apple Pencil Pro/double-tap commands, separate from stroke data.
Stream<String> nativePencilCommands() =>
    const EventChannel(nativePencilCommandChannel)
        .receiveBroadcastStream()
        .where((dynamic value) => value is String)
        .cast<String>();

/// Low-rate UIKit/Metal status events. Pointer samples remain on the binary
/// packet channel so diagnostics cannot add a per-sample platform round-trip.
Stream<Map<String, Object?>> nativeCanvasDiagnosticEvents() =>
    const EventChannel(nativeCanvasDiagnosticsChannel)
        .receiveBroadcastStream()
        .where((dynamic value) => value is Map)
        .map<Map<String, Object?>>(
          (dynamic value) => Map<String, Object?>.from(value as Map),
        );

/// Rewrites screen-space packet coordinates into the current canvas space.
/// Native adapters intentionally do not know Flutter's pan/zoom/rotation.
Uint8List transformPointerPacket(
  Uint8List packet,
  Offset Function(Offset screenPosition) transform,
) {
  _validatePacket(packet);
  final result = Uint8List.fromList(packet);
  final data = ByteData.sublistView(result);
  final count = data.getUint16(2, Endian.little);
  for (var index = 0; index < count; index++) {
    final offset = 4 + index * 48;
    final transformed = transform(
      Offset(
        data.getFloat32(offset + 8, Endian.little),
        data.getFloat32(offset + 12, Endian.little),
      ),
    );
    data.setFloat32(offset + 8, transformed.dx, Endian.little);
    data.setFloat32(offset + 12, transformed.dy, Endian.little);
  }
  return result;
}

bool packetHasPhase(Uint8List packet, InkPointerPhase phase) {
  _validatePacket(packet);
  final data = ByteData.sublistView(packet);
  final count = data.getUint16(2, Endian.little);
  for (var index = 0; index < count; index++) {
    final offset = 4 + index * 48;
    if (data.getUint8(offset + 7) == phase.index) return true;
  }
  return false;
}

void _validatePacket(Uint8List packet) {
  if (packet.length < 4) {
    throw const FormatException('native pointer packet header is truncated');
  }
  final data = ByteData.sublistView(packet);
  if (data.getUint16(0, Endian.little) != 1) {
    throw const FormatException('unsupported native pointer packet version');
  }
  final count = data.getUint16(2, Endian.little);
  if (count > inkPointerMaxSamples) {
    throw const FormatException('native pointer packet has too many samples');
  }
  if (packet.length != 4 + count * 48) {
    throw const FormatException('native pointer packet length is invalid');
  }
}
