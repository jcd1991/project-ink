import 'dart:typed_data';

/// Platform-neutral values matching `specifications/pointer-packet.md`.
enum InkPointerDevice { unknown, stylus, touch, mouse }

enum InkPointerPhase { down, move, up, cancel }

const int inkPointerActual = 1;
const int inkPointerMaxSamples = 256;
const int inkPointerCoalesced = 1 << 1;
const int inkPointerPredicted = 1 << 2;
const int inkPointerEraser = 1 << 3;
const int inkPointerBarrel = 1 << 4;
const int inkPointerHover = 1 << 5;
const int inkPointerPalmRejected = 1 << 6;
const int _inkPointerSourceFlags =
    inkPointerActual | inkPointerCoalesced | inkPointerPredicted;
const int _inkPointerKnownFlags =
    _inkPointerSourceFlags |
    inkPointerEraser |
    inkPointerBarrel |
    inkPointerHover |
    inkPointerPalmRejected;

/// Packet-level accounting used by the local Phase 1 acceptance trace.
///
/// [sequences] contains every sequence value in wire order. Native adapters
/// increment this value for every emitted sample, including historical and
/// predicted samples, so the trace can identify gaps before the Rust queue.
class PointerPacketSummary {
  const PointerPacketSummary({
    required this.sampleCount,
    required this.confirmedSampleCount,
    required this.predictedSampleCount,
    required this.sequences,
  });

  final int sampleCount;
  final int confirmedSampleCount;
  final int predictedSampleCount;
  final List<int> sequences;
}

/// Read sample counts and sequence values without decoding or rewriting the
/// packet. The same strict length/version checks as coordinate transforms are
/// applied so malformed native input cannot pollute acceptance evidence.
PointerPacketSummary summarizePointerPacket(Uint8List packet) {
  _validatePacket(packet);
  final data = ByteData.sublistView(packet);
  final count = data.getUint16(2, Endian.little);
  var confirmed = 0;
  var predicted = 0;
  final sequences = <int>[];
  for (var index = 0; index < count; index++) {
    final offset = 4 + index * 48;
    final flags = data.getUint16(offset + 4, Endian.little);
    if (flags & inkPointerPredicted != 0) {
      predicted++;
    } else {
      confirmed++;
    }
    sequences.add(data.getUint32(offset + 44, Endian.little));
  }
  return PointerPacketSummary(
    sampleCount: count,
    confirmedSampleCount: confirmed,
    predictedSampleCount: predicted,
    sequences: List.unmodifiable(sequences),
  );
}

void _validatePacket(Uint8List packet) {
  if (packet.length < 4) {
    throw const FormatException('pointer packet header is truncated');
  }
  final data = ByteData.sublistView(packet);
  if (data.getUint16(0, Endian.little) != 1) {
    throw const FormatException('unsupported pointer packet version');
  }
  final count = data.getUint16(2, Endian.little);
  if (count > inkPointerMaxSamples) {
    throw const FormatException('pointer packet has too many samples');
  }
  if (packet.length != 4 + count * 48) {
    throw const FormatException('pointer packet length is invalid');
  }
}

/// Encode one confirmed pointer sample as pointer packet v1.
Uint8List encodePointerPacket({
  required int pointerId,
  required InkPointerDevice device,
  required InkPointerPhase phase,
  required double x,
  required double y,
  required double pressure,
  required int timestampNs,
  required int sequence,
  double tiltX = 0,
  double tiltY = 0,
  double azimuth = 0,
  double twist = 0,
  int flags = inkPointerActual,
}) {
  final bytes = ByteData(4 + 48);
  bytes.setUint16(0, 1, Endian.little);
  bytes.setUint16(2, 1, Endian.little);
  bytes.setUint32(4, pointerId, Endian.little);
  bytes.setUint16(8, flags, Endian.little);
  bytes.setUint8(10, device.index);
  bytes.setUint8(11, phase.index);
  bytes.setFloat32(12, x, Endian.little);
  bytes.setFloat32(16, y, Endian.little);
  bytes.setFloat32(20, pressure.clamp(0, 1), Endian.little);
  bytes.setFloat32(24, tiltX, Endian.little);
  bytes.setFloat32(28, tiltY, Endian.little);
  bytes.setFloat32(32, azimuth, Endian.little);
  bytes.setFloat32(36, twist, Endian.little);
  bytes.setUint64(40, timestampNs, Endian.little);
  bytes.setUint32(48, sequence, Endian.little);
  return bytes.buffer.asUint8List();
}

/// Add a mode flag to every sample without changing packet layout or floats.
Uint8List addPointerPacketFlags(Uint8List packet, int flags) {
  _validatePacket(packet);
  if (flags < 0 || (flags & ~_inkPointerKnownFlags) != 0) {
    throw const FormatException('pointer packet flags are unknown');
  }
  if ((flags & _inkPointerSourceFlags) != 0) {
    throw const FormatException(
      'pointer packet source flags cannot be rewritten',
    );
  }
  final data = ByteData.sublistView(packet);
  final count = data.getUint16(2, Endian.little);
  final result = Uint8List.fromList(packet);
  final resultData = ByteData.sublistView(result);
  for (var index = 0; index < count; index++) {
    final offset = 4 + index * 48 + 4;
    resultData.setUint16(
      offset,
      resultData.getUint16(offset, Endian.little) | flags,
      Endian.little,
    );
  }
  return result;
}

/// Return the first [sampleCount] samples from a validated pointer packet.
///
/// This is used when a native coalesced batch crosses a document edge: keep
/// the crossing sample so the engine can clip the final segment, but avoid
/// queueing later captured samples that cannot affect the stroke.
Uint8List truncatePointerPacket(Uint8List packet, int sampleCount) {
  _validatePacket(packet);
  final data = ByteData.sublistView(packet);
  final packetSampleCount = data.getUint16(2, Endian.little);
  if (sampleCount < 0 || sampleCount > packetSampleCount) {
    throw RangeError.range(sampleCount, 0, packetSampleCount, 'sampleCount');
  }
  if (sampleCount == packetSampleCount) return packet;
  final length = 4 + sampleCount * 48;
  final result = Uint8List.fromList(packet.sublist(0, length));
  ByteData.sublistView(result).setUint16(2, sampleCount, Endian.little);
  return result;
}
