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
}
