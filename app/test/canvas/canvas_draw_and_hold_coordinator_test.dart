import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/canvas/canvas_draw_and_hold_coordinator.dart';
import 'package:project_ink/canvas/gesture_defaults.dart';

void main() {
  const position = Offset(20, 20);
  const start = Offset.zero;

  test(
    'fires after the quiet interval and records the latest queue state',
    () async {
      var state = _snapshot(
        strokeActive: true,
        constraintStart: start,
        stylusPosition: position,
      );
      final events = <String>[];
      Map<String, Object?>? diagnostic;
      final coordinator = _coordinator(
        state: () => state,
        onActivation: (event) => diagnostic = event,
        onDispatch: (gesture) => events.add('dispatch:${gesture?.name}'),
      );

      coordinator.recordInputArrival();
      coordinator.arm(position);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(events, ['dispatch:straighten']);
      expect(diagnostic?['latestInputAgeUs'], greaterThanOrEqualTo(1000));
      expect(diagnostic?['strokeWorkQueueDepth'], 0);
      coordinator.dispose();
    },
  );

  test(
    'cancels firing when newer position or queued native input appears',
    () async {
      for (final changed in [
        _snapshot(
          strokeActive: true,
          constraintStart: start,
          stylusPosition: const Offset(21, 20),
        ),
        _snapshot(
          strokeActive: true,
          constraintStart: start,
          stylusPosition: position,
          pendingNativePackets: 1,
        ),
      ]) {
        var state = _snapshot(
          strokeActive: true,
          constraintStart: start,
          stylusPosition: position,
        );
        var dispatched = false;
        final coordinator = _coordinator(
          state: () => state,
          onDispatch: (_) => dispatched = true,
        );
        coordinator.recordInputArrival();
        coordinator.arm(position);
        state = changed;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(dispatched, isFalse);
        coordinator.dispose();
      }
    },
  );

  test(
    'does not arm when a stroke or usable constraint anchor is absent',
    () async {
      for (final state in [
        _snapshot(strokeActive: false, constraintStart: start),
        _snapshot(strokeActive: true, constraintStart: null),
        _snapshot(
          strokeActive: true,
          constraintStart: start,
          constraintActive: true,
        ),
        _snapshot(
          strokeActive: true,
          constraintStart: start,
          stylusPosition: const Offset(4, 4),
        ),
      ]) {
        var dispatched = false;
        final coordinator = _coordinator(
          state: () => state,
          onDispatch: (_) => dispatched = true,
        );
        coordinator.arm(position);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(dispatched, isFalse);
        coordinator.dispose();
      }
    },
  );

  test('new pointer input restarts the quiet interval', () async {
    var state = _snapshot(
      strokeActive: true,
      constraintStart: start,
      stylusPosition: position,
    );
    var dispatched = false;
    final coordinator = _coordinator(
      state: () => state,
      holdDuration: const Duration(milliseconds: 50),
      onDispatch: (_) => dispatched = true,
    );

    coordinator.recordInputArrival();
    coordinator.arm(position);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    coordinator.recordInputArrival();
    state = _snapshot(
      strokeActive: true,
      constraintStart: start,
      stylusPosition: position,
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(dispatched, isFalse);

    coordinator.arm(position);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(dispatched, isTrue);
    coordinator.dispose();
  });

  test('does not fire when new input arrives at the timer boundary', () async {
    var state = _snapshot(
      strokeActive: true,
      constraintStart: start,
      stylusPosition: position,
    );
    var dispatched = false;
    final coordinator = _coordinator(
      state: () => state,
      holdDuration: const Duration(milliseconds: 10),
      onDispatch: (_) => dispatched = true,
    );
    coordinator.recordInputArrival();
    coordinator.arm(position);
    coordinator.recordInputArrival();
    state = _snapshot(
      strokeActive: true,
      constraintStart: start,
      stylusPosition: position,
    );
    await Future<void>.delayed(const Duration(milliseconds: 15));
    expect(dispatched, isFalse);
    coordinator.dispose();
  });
}

CanvasDrawAndHoldSnapshot _snapshot({
  required bool strokeActive,
  required Offset? constraintStart,
  Offset? stylusPosition,
  bool constraintActive = false,
  bool nativeDrainScheduled = false,
  int pendingNativePackets = 0,
}) => CanvasDrawAndHoldSnapshot(
  strokeActive: strokeActive,
  constraintActive: constraintActive,
  constraintStart: constraintStart,
  stylusPosition: stylusPosition,
  nativeDrainScheduled: nativeDrainScheduled,
  pendingNativePackets: pendingNativePackets,
  strokeWorkQueueDepth: 0,
  gesture: InkGesture.straighten,
);

CanvasDrawAndHoldCoordinator _coordinator({
  required CanvasDrawAndHoldSnapshot Function() state,
  void Function(Map<String, Object?>)? onActivation,
  void Function(InkGesture?)? onDispatch,
  Duration holdDuration = const Duration(milliseconds: 1),
}) => CanvasDrawAndHoldCoordinator(
  snapshot: state,
  recordActivation: onActivation ?? (_) {},
  dispatch: onDispatch ?? (_) {},
  holdDuration: holdDuration,
);
