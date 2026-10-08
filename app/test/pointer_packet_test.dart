import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/canvas/pointer_packet.dart';

void main() {
  test('encodes a little-endian pointer packet v1 sample', () {
    final packet = encodePointerPacket(
      pointerId: 7,
      device: InkPointerDevice.stylus,
      phase: InkPointerPhase.move,
      x: 12.5,
      y: 30.25,
      pressure: 0.75,
      timestampNs: 1234,
      sequence: 9,
    );
    final data = ByteData.sublistView(packet);
    expect(data.getUint16(0, Endian.little), 1);
    expect(data.getUint16(2, Endian.little), 1);
    expect(data.getUint32(4, Endian.little), 7);
    expect(data.getUint8(10), InkPointerDevice.stylus.index);
    expect(data.getUint8(11), InkPointerPhase.move.index);
    expect(data.getFloat32(12, Endian.little), 12.5);
    expect(data.getUint64(40, Endian.little), 1234);
    expect(data.getUint32(48, Endian.little), 9);
  });

  test('slices a coalesced packet from its first re-entry sample', () {
    Uint8List sample(double x, int sequence) => encodePointerPacket(
      pointerId: 7,
      device: InkPointerDevice.stylus,
      phase: InkPointerPhase.move,
      x: x,
      y: 30,
      pressure: 1,
      timestampNs: sequence,
      sequence: sequence,
    );

    final samples = <Uint8List>[sample(120, 1), sample(40, 2)];
    final packet = Uint8List(4 + samples.length * 48);
    final packetData = ByteData.sublistView(packet);
    packetData.setUint16(0, 1, Endian.little);
    packetData.setUint16(2, samples.length, Endian.little);
    for (var index = 0; index < samples.length; index++) {
      packet.setRange(4 + index * 48, 4 + (index + 1) * 48, samples[index], 4);
    }

    final reentry = slicePointerPacket(packet, 1);
    final data = ByteData.sublistView(reentry);
    expect(data.getUint16(2, Endian.little), 1);
    expect(data.getFloat32(12, Endian.little), 40);
    expect(data.getUint32(48, Endian.little), 2);
  });
}
