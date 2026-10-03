import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/canvas/canvas_touch_stroke_cancellation_coordinator.dart';

void main() {
  test('ignores cancellation when no touch stroke is active', () {
    final operations = <Future<void> Function()>[];
    final coordinator = _coordinator(operations: operations);

    coordinator.cancel(reason: 'touch_state_reset');

    expect(operations, isEmpty);
  });

  test('checks stroke ownership when queued work executes', () async {
    final events = <String>[];
    final operations = <Future<void> Function()>[];
    var active = true;
    var activeTouch = true;
    final coordinator = _coordinator(
      events: events,
      operations: operations,
      strokeActive: () => active,
      activeStrokeIsTouch: () => activeTouch,
    );
    coordinator.setActive(true);

    coordinator.cancel(reason: 'touch_state_reset');
    active = true;
    activeTouch = false;
    await operations.single();

    expect(coordinator.isActive, isFalse);
    expect(events, contains('input.touch_stroke_cancel_requested'));
    expect(events, contains('input.touch_cancel_ignored'));
    expect(events, isNot(contains('cancel_rust')));
  });

  test('cancels an owned touch stroke then publishes common cleanup', () async {
    final events = <String>[];
    final operations = <Future<void> Function()>[];
    final coordinator = _coordinator(events: events, operations: operations);
    coordinator.setActive(true);

    coordinator.cancel(reason: 'touch_cancel');
    await operations.single();

    expect(events, [
      'input.touch_stroke_cancel_requested',
      'cancel_rust',
      'input.stroke_end',
      'canvas.stroke_cancelled',
      'finish:touch_cancel',
      'refresh_tiles',
    ]);
  });
}

CanvasTouchStrokeCancellationCoordinator _coordinator({
  List<String>? events,
  required List<Future<void> Function()> operations,
  bool Function()? strokeActive,
  bool Function()? activeStrokeIsTouch,
}) {
  final output = events ?? <String>[];
  return CanvasTouchStrokeCancellationCoordinator(
    CanvasTouchStrokeCancellationHost(
      enqueueStrokeWork: operations.add,
      strokeActive: strokeActive ?? () => true,
      activeStrokeIsTouch: activeStrokeIsTouch ?? () => true,
      touchPointerCounts: () => (active: 2, tracked: 2),
      cancelRustStroke: () async => output.add('cancel_rust'),
      engineRevision: () => 4,
      finishExternalCancellation:
          ({required reason}) => output.add('finish:$reason'),
      refreshTiles: () => output.add('refresh_tiles'),
      recordDiagnostic: (event, fields) => output.add(event),
    ),
  );
}
