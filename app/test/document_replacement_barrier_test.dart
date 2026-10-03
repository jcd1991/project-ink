import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/canvas/document_replacement_barrier.dart';

void main() {
  test(
    'drains, cancels, flushes, then replaces while input is gated',
    () async {
      final events = <String>[];
      late DocumentReplacementBarrier barrier;
      barrier = DocumentReplacementBarrier(
        drainAcceptedInput: () async => events.add('drain'),
        cancelActiveStroke: () async => events.add('cancel'),
        flushRecovery: () async => events.add('flush'),
        onChanged: (active) => events.add('gate:$active'),
      );

      await barrier.run(() async {
        events.add('replace');
        expect(barrier.isActive, isTrue);
      });

      expect(events, <String>[
        'gate:true',
        'drain',
        'cancel',
        'flush',
        'replace',
        'gate:false',
      ]);
      expect(barrier.isActive, isFalse);
    },
  );

  test(
    'releases the gate and does not replace after preparation fails',
    () async {
      final gateChanges = <bool>[];
      final barrier = DocumentReplacementBarrier(
        drainAcceptedInput: () async => throw StateError('drain failed'),
        cancelActiveStroke: () async {},
        flushRecovery: () async {},
        onChanged: gateChanges.add,
      );
      var replaced = false;

      await expectLater(
        barrier.run(() async => replaced = true),
        throwsStateError,
      );

      expect(replaced, isFalse);
      expect(gateChanges, <bool>[true, false]);
      expect(barrier.isActive, isFalse);
    },
  );
}
