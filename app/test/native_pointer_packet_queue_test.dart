import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/canvas/native_pointer_packet_queue.dart';
import 'package:project_ink/canvas/pointer_packet.dart';

void main() {
  test('compacts adjacent move packets without crossing stroke boundaries', () {
    final down = _packet(InkPointerPhase.down, 0);
    final firstMove = _packet(InkPointerPhase.move, 1);
    final predictedMove = _packet(
      InkPointerPhase.move,
      2,
      flags: inkPointerPredicted,
    );
    final secondMove = _packet(InkPointerPhase.move, 3);
    final up = _packet(InkPointerPhase.up, 4);

    final compacted = compactNativePointerPackets([
      down,
      firstMove,
      predictedMove,
      secondMove,
      up,
    ]);

    expect(compacted, hasLength(3));
    expect(identical(compacted.first, down), isTrue);
    expect(identical(compacted.last, up), isTrue);
    final summary = summarizePointerPacket(compacted[1]);
    expect(summary.sequences, <int>[1, 3]);
    expect(summary.predictedSampleCount, 0);
  });

  test(
    'drain keeps work enqueued during processing in the same drain',
    () async {
      final queue = NativePointerPacketQueue();
      final first = _packet(InkPointerPhase.down, 1);
      final second = _packet(InkPointerPhase.up, 2);
      final processed = <Uint8List>[];
      var scheduledDrains = 0;
      var idleCalls = 0;

      expect(queue.enqueue(first), isTrue);
      expect(queue.enqueue(second), isFalse);
      await queue.drain(
        isActive: () => true,
        handlePacket: (packet) async {
          processed.add(packet);
          if (processed.length == 1) {
            expect(queue.enqueue(_packet(InkPointerPhase.move, 3)), isFalse);
          }
        },
        scheduleDrain: () => scheduledDrains++,
        onIdle: () => idleCalls++,
      );

      expect(
        processed.map((packet) => summarizePointerPacket(packet).sequences),
        [
          [1],
          [2],
          [3],
        ],
      );
      expect(queue.pendingCount, 0);
      expect(queue.isDrainScheduled, isFalse);
      expect(scheduledDrains, 0);
      expect(idleCalls, 1);
    },
  );

  test('clear retires queued packets and the scheduled drain marker', () {
    final queue = NativePointerPacketQueue();
    expect(queue.enqueue(_packet(InkPointerPhase.down, 1)), isTrue);

    queue.clear();

    expect(queue.pendingCount, 0);
    expect(queue.isDrainScheduled, isFalse);
  });
}

Uint8List _packet(
  InkPointerPhase phase,
  int sequence, {
  int flags = inkPointerActual,
}) => encodePointerPacket(
  pointerId: 9,
  device: InkPointerDevice.stylus,
  phase: phase,
  x: sequence.toDouble(),
  y: 20,
  pressure: 1,
  timestampNs: sequence,
  sequence: sequence,
  flags: flags,
);
