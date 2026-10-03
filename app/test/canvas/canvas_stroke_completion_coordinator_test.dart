import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/canvas/canvas_stroke_completion_coordinator.dart';

void main() {
  test(
    'completed Flutter strokes retire the right preview and refresh state',
    () {
      final events = <String>[];
      final coordinator = _coordinator(events);

      coordinator.finish(
        origin: CanvasStrokeCompletionOrigin.flutterPointer,
        cancelled: false,
        boundaryEnded: false,
        reason: 'pointer_up',
        pointerKind: 'stylus',
      );

      expect(events, [
        'reset',
        'awaiting:true',
        'retire:flutter_pointer_end',
        'constraint',
        'cancel_hold_timer',
        'clear_stylus_position',
        'autosave:pointer_up',
        'refresh_layers',
        'refresh_tiles',
      ]);
    },
  );

  test('native boundary completion uses native cleanup and preview source', () {
    final events = <String>[];
    final coordinator = _coordinator(events);

    coordinator.finish(
      origin: CanvasStrokeCompletionOrigin.nativePencil,
      cancelled: false,
      boundaryEnded: true,
      reason: 'native_boundary_up',
    );

    expect(events, [
      'reset',
      'clear_native_contact',
      'awaiting:true',
      'retire:native_pencil_boundary_end',
      'constraint',
      'cancel_hold_timer',
      'clear_stylus_position',
      'autosave:native_boundary_up',
      'refresh_layers',
      'refresh_tiles',
    ]);
  });

  test(
    'Flutter cancellation clears preview and suppresses boundary diagnostics',
    () {
      final events = <String>[];
      final coordinator = _coordinator(events);

      coordinator.finish(
        origin: CanvasStrokeCompletionOrigin.flutterPointer,
        cancelled: true,
        boundaryEnded: true,
        reason: 'pointer_boundary_cancel',
        pointerKind: 'touch',
      );

      expect(events, contains('clear_preview'));
      expect(events, isNot(contains('record_cancel:touch')));
      expect(events, contains('awaiting:false'));
      expect(events, contains('refresh_layers'));
    },
  );

  test('ordinary Flutter cancellation records its pointer kind', () {
    final events = <String>[];
    final coordinator = _coordinator(events);

    coordinator.finish(
      origin: CanvasStrokeCompletionOrigin.flutterPointer,
      cancelled: true,
      boundaryEnded: false,
      reason: 'pointer_cancel',
      pointerKind: 'mouse',
    );

    expect(events, contains('clear_preview'));
    expect(events, contains('record_cancel:mouse'));
    expect(events, isNot(contains('retire:flutter_pointer_end')));
  });
}

CanvasStrokeCompletionCoordinator _coordinator(List<String> events) =>
    CanvasStrokeCompletionCoordinator(
      CanvasStrokeCompletionHost(
        resetActiveStroke: () => events.add('reset'),
        clearNativePageContact: () => events.add('clear_native_contact'),
        setAwaitingPreviewCommit: (value) => events.add('awaiting:$value'),
        clearPreview: () => events.add('clear_preview'),
        retirePreview: (source) => events.add('retire:$source'),
        recordFlutterCancellation:
            (pointerKind) => events.add('record_cancel:$pointerKind'),
        finishConstraint: () => events.add('constraint'),
        cancelStylusHold: () => events.add('cancel_hold_timer'),
        clearStylusPosition: () => events.add('clear_stylus_position'),
        finishAutosaveHold:
            ({required reason}) => events.add('autosave:$reason'),
        refreshLayerThumbnails: () => events.add('refresh_layers'),
        refreshTiles: () => events.add('refresh_tiles'),
      ),
    );
