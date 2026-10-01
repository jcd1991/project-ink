import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/canvas/native_pointer_stream.dart';
import 'package:project_ink/canvas/pointer_packet.dart';

void main() {
  test('rewrites native screen coordinates without changing packet layout', () {
    final packet = encodePointerPacket(
      pointerId: 7,
      device: InkPointerDevice.stylus,
      phase: InkPointerPhase.down,
      x: 10,
      y: 20,
      pressure: 1,
      timestampNs: 9,
      sequence: 1,
    );
    final transformed = transformPointerPacket(
      packet,
      (position) => position + const Offset(100, 200),
    );
    final data = ByteData.sublistView(transformed);

    expect(data.getFloat32(12, Endian.little), 110);
    expect(data.getFloat32(16, Endian.little), 220);
    expect(packetHasPhase(transformed, InkPointerPhase.down), isTrue);
    expect(packetHasPhase(transformed, InkPointerPhase.up), isFalse);
  });

  test('rejects malformed native packets', () {
    expect(
      () => transformPointerPacket(
        Uint8List.fromList(<int>[1, 0, 1, 0]),
        (position) => position,
      ),
      throwsFormatException,
    );
  });

  test('rejects packets above the bounded sample limit', () {
    final packet = Uint8List(4 + (inkPointerMaxSamples + 1) * 48);
    final data = ByteData.sublistView(packet);
    data.setUint16(0, 1, Endian.little);
    data.setUint16(2, inkPointerMaxSamples + 1, Endian.little);
    expect(
      () => transformPointerPacket(packet, (position) => position),
      throwsFormatException,
    );
  });

  test('adds mode flags without changing sample payloads', () {
    final packet = encodePointerPacket(
      pointerId: 4,
      device: InkPointerDevice.stylus,
      phase: InkPointerPhase.move,
      x: 12,
      y: 18,
      pressure: 0.5,
      timestampNs: 99,
      sequence: 7,
    );
    final flagged = addPointerPacketFlags(packet, inkPointerEraser);
    final data = ByteData.sublistView(flagged);
    expect(
      data.getUint16(8, Endian.little),
      inkPointerActual | inkPointerEraser,
    );
    expect(data.getFloat32(12, Endian.little), 12);
    expect(data.getFloat32(16, Endian.little), 18);
    expect(data.getUint32(48, Endian.little), 7);
  });

  test('truncates a validated packet without changing retained samples', () {
    final first = encodePointerPacket(
      pointerId: 4,
      device: InkPointerDevice.stylus,
      phase: InkPointerPhase.move,
      x: 12,
      y: 18,
      pressure: 0.5,
      timestampNs: 99,
      sequence: 7,
    );
    final second = encodePointerPacket(
      pointerId: 4,
      device: InkPointerDevice.stylus,
      phase: InkPointerPhase.move,
      x: 13,
      y: 19,
      pressure: 0.6,
      timestampNs: 100,
      sequence: 8,
    );
    final batch = Uint8List(4 + 2 * 48);
    final batchData = ByteData.sublistView(batch);
    batchData.setUint16(0, 1, Endian.little);
    batchData.setUint16(2, 2, Endian.little);
    batch.setRange(4, 52, first, 4);
    batch.setRange(52, 100, second, 4);

    final retained = truncatePointerPacket(batch, 1);
    final data = ByteData.sublistView(retained);
    expect(retained.length, 52);
    expect(data.getUint16(2, Endian.little), 1);
    expect(data.getUint32(48, Endian.little), 7);
    expect(() => truncatePointerPacket(batch, 3), throwsRangeError);
  });

  test('rejects malformed packets and source flags before rewriting', () {
    final packet = encodePointerPacket(
      pointerId: 4,
      device: InkPointerDevice.stylus,
      phase: InkPointerPhase.move,
      x: 12,
      y: 18,
      pressure: 0.5,
      timestampNs: 99,
      sequence: 7,
    );
    final malformed = Uint8List.fromList(packet);
    ByteData.sublistView(malformed).setUint16(0, 2, Endian.little);
    expect(
      () => addPointerPacketFlags(malformed, inkPointerEraser),
      throwsFormatException,
    );
    expect(
      () => addPointerPacketFlags(packet, inkPointerPredicted),
      throwsFormatException,
    );
    expect(() => addPointerPacketFlags(packet, 1 << 15), throwsFormatException);
  });
}
