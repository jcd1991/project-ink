import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/canvas/canvas_stroke_cancellation_coordinator.dart';

void main() {
  test(
    'abort cancels Rust then resets local preview and autosave state',
    () async {
      final events = <String>[];
      final coordinator = _coordinator(events: events);

      await coordinator.abort();

      expect(events, [
        'cancel_engine',
        'cancel_surface',
        'reset',
        'clear_contact',
        'awaiting:false',
        'clear_preview',
        'constraint',
        'cancel_timer',
        'clear_position',
        'mark_dirty',
        'autosave:stroke_abort',
      ]);
    },
  );

  test(
    'inactive abort releases autosave and preview without cancelling Rust',
    () async {
      final events = <String>[];
      final coordinator = _coordinator(events: events, active: false);

      await coordinator.abort();

      expect(events, [
        'awaiting:false',
        'autosave:stroke_abort_without_active_stroke',
        'clear_preview',
      ]);
    },
  );

  test('preserved preview survives a swallowed cancellation failure', () async {
    final events = <String>[];
    final coordinator = _coordinator(
      events: events,
      cancelError: StateError('engine already closed'),
    );

    await coordinator.abort(preservePreview: true);

    expect(events, [
      'cancel_engine',
      'record_failure',
      'reset',
      'clear_contact',
      'awaiting:false',
      'constraint',
      'cancel_timer',
      'clear_position',
      'mark_dirty',
      'autosave:stroke_abort',
    ]);
  });

  test(
    'rethrow leaves stroke state untouched when cancellation must succeed',
    () async {
      final events = <String>[];
      final coordinator = _coordinator(
        events: events,
        cancelError: StateError('engine already closed'),
      );

      await expectLater(
        coordinator.abort(rethrowCancelFailure: true),
        throwsStateError,
      );
      expect(events, ['cancel_engine', 'record_failure']);
    },
  );

  test(
    'external touch cancellation uses shared cleanup without dirty marking',
    () {
      final events = <String>[];
      final coordinator = _coordinator(events: events);

      coordinator.finishExternalCancellation(reason: 'touch_cancel');

      expect(events, [
        'reset',
        'cancel_surface',
        'clear_contact',
        'awaiting:false',
        'clear_preview',
        'constraint',
        'cancel_timer',
        'clear_position',
        'autosave:touch_cancel',
      ]);
      expect(events, isNot(contains('cancel_engine')));
      expect(events, isNot(contains('mark_dirty')));
    },
  );
}

CanvasStrokeCancellationCoordinator _coordinator({
  required List<String> events,
  bool active = true,
  Object? cancelError,
}) => CanvasStrokeCancellationCoordinator(
  CanvasStrokeCancellationHost(
    strokeActive: () => active,
    cancelEngineStroke: () async {
      events.add('cancel_engine');
      if (cancelError case final error?) throw error;
    },
    cancelPreviewSurface: () => events.add('cancel_surface'),
    recordCancelFailure: (_, _) => events.add('record_failure'),
    resetActiveStroke: () => events.add('reset'),
    clearNativePageContact: () => events.add('clear_contact'),
    setAwaitingPreviewCommit: (value) => events.add('awaiting:$value'),
    clearPreview: () => events.add('clear_preview'),
    finishConstraint: () => events.add('constraint'),
    cancelStylusHold: () => events.add('cancel_timer'),
    clearStylusPosition: () => events.add('clear_position'),
    markDirty: () => events.add('mark_dirty'),
    finishAutosaveHold: ({required reason}) => events.add('autosave:$reason'),
  ),
);
