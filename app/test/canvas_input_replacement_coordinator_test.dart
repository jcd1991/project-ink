import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/canvas/canvas_input_replacement_coordinator.dart';
import 'package:project_ink/canvas/document_replacement_barrier.dart';

void main() {
  test(
    'prepares transient input before draining and replacing the document',
    () async {
      final events = <String>[];
      final barrier = DocumentReplacementBarrier(
        drainAcceptedInput: () async => events.add('drain'),
        cancelActiveStroke: () async => events.add('cancel'),
        flushRecovery: () async => events.add('flush'),
        onChanged: (active) => events.add('gate:$active'),
      );
      final coordinator = CanvasInputReplacementCoordinator(
        CanvasInputReplacementHost(
          isMounted: () => true,
          prepareInput: () => events.add('prepare'),
          barrier: barrier,
        ),
      );

      await coordinator.run(() async => events.add('replace'));

      expect(events, [
        'prepare',
        'gate:true',
        'drain',
        'cancel',
        'flush',
        'replace',
        'gate:false',
      ]);
    },
  );

  test(
    'does not prepare or replace after the canvas route is unmounted',
    () async {
      final events = <String>[];
      final barrier = DocumentReplacementBarrier(
        drainAcceptedInput: () async => events.add('drain'),
        cancelActiveStroke: () async => events.add('cancel'),
        flushRecovery: () async => events.add('flush'),
        onChanged: (active) => events.add('gate:$active'),
      );
      final coordinator = CanvasInputReplacementCoordinator(
        CanvasInputReplacementHost(
          isMounted: () => false,
          prepareInput: () => events.add('prepare'),
          barrier: barrier,
        ),
      );

      await coordinator.run(() async => events.add('replace'));

      expect(events, isEmpty);
    },
  );
}
