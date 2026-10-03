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
        inputAgeMicros: 0,
      );
      final events = <String>[];
      Map<String, Object?>? diagnostic;
      final coordinator = _coordinator(
        state: () => state,
        onActivation: (event) => diagnostic = event,
        onDispatch: (gesture) => events.add('dispatch:${gesture?.name}'),
      );

      coordinator.arm(position);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(events, ['dispatch:straighten']);
      expect(diagnostic?['latestInputAgeUs'], 0);
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
          inputAgeMicros: 0,
        ),
        _snapshot(
          strokeActive: true,
          constraintStart: start,
          stylusPosition: position,
          inputAgeMicros: 0,
          pendingNativePackets: 1,
        ),
      ]) {
        var state = _snapshot(
          strokeActive: true,
          constraintStart: start,
          stylusPosition: position,
          inputAgeMicros: 0,
        );
        var dispatched = false;
        final coordinator = _coordinator(
          state: () => state,
          onDispatch: (_) => dispatched = true,
        );
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
}

CanvasDrawAndHoldSnapshot _snapshot({
  required bool strokeActive,
  required Offset? constraintStart,
  Offset? stylusPosition,
  bool constraintActive = false,
  int inputAgeMicros = 0,
  bool nativeDrainScheduled = false,
  int pendingNativePackets = 0,
}) => CanvasDrawAndHoldSnapshot(
  strokeActive: strokeActive,
  constraintActive: constraintActive,
  constraintStart: constraintStart,
  stylusPosition: stylusPosition,
  inputAgeMicros: inputAgeMicros,
  nativeDrainScheduled: nativeDrainScheduled,
  pendingNativePackets: pendingNativePackets,
  strokeWorkQueueDepth: 0,
  gesture: InkGesture.straighten,
);

CanvasDrawAndHoldCoordinator _coordinator({
  required CanvasDrawAndHoldSnapshot Function() state,
  void Function(Map<String, Object?>)? onActivation,
  void Function(InkGesture?)? onDispatch,
}) => CanvasDrawAndHoldCoordinator(
  snapshot: state,
  recordActivation: onActivation ?? (_) {},
  dispatch: onDispatch ?? (_) {},
  holdDuration: const Duration(milliseconds: 1),
);
