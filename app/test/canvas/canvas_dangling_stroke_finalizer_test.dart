import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/canvas/canvas_dangling_stroke_finalizer.dart';

void main() {
  test(
    'drains input, ends the stroke, then publishes local completion',
    () async {
      final events = <String>[];
      final finalizer = _finalizer(events: events, active: true);

      await finalizer.finishBeforeEdit();

      expect(events, ['drain', 'end', 'reset', 'dirty', 'thumbnails', 'tiles']);
    },
  );

  test(
    'resets and refreshes when Rust reports the stroke already ended',
    () async {
      final events = <String>[];
      final finalizer = _finalizer(events: events, active: true, failEnd: true);

      await expectLater(finalizer.finishBeforeEdit(), completes);

      expect(events, ['drain', 'end', 'reset', 'dirty', 'thumbnails', 'tiles']);
    },
  );

  test('does not publish completion when there is no active stroke', () async {
    final events = <String>[];
    final finalizer = _finalizer(events: events, active: false);

    await finalizer.finishBeforeEdit();

    expect(events, ['drain']);
  });
}

CanvasDanglingStrokeFinalizer _finalizer({
  required List<String> events,
  required bool active,
  bool failEnd = false,
}) => CanvasDanglingStrokeFinalizer(
  CanvasDanglingStrokeFinalizerHost(
    drainAcceptedInput: () async => events.add('drain'),
    hasActiveStroke: () => active,
    endRustStroke: () async {
      events.add('end');
      if (failEnd) throw StateError('stroke already ended');
    },
    resetLocalStroke: () => events.add('reset'),
    markDirty: () => events.add('dirty'),
    refreshLayerThumbnails: () => events.add('thumbnails'),
    refreshTiles: () => events.add('tiles'),
  ),
);
