import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/canvas/canvas_stroke_autosave_hold.dart';

void main() {
  test('pairs one continuous edit with one finish and records both edges', () {
    final events = <String>[];
    final diagnostics = _RecordingDiagnostics(events);
    final hold = CanvasStrokeAutosaveHold(
      beginContinuousEdit: () => events.add('begin'),
      endContinuousEdit: () => events.add('end'),
      nativePacketQueueDepth: () => 3,
      strokeWorkQueueDepth: () => 2,
      recordDiagnostic: diagnostics.record,
    );

    hold.begin();
    hold.begin();
    expect(hold.isActive, isTrue);
    hold.finish(reason: 'stroke_complete');
    hold.finish(reason: 'duplicate_finish');

    expect(hold.isActive, isFalse);
    expect(events, [
      'begin',
      'canvas.autosave_deferred_for_stroke',
      'end',
      'canvas.autosave_resumed_after_stroke',
    ]);
    expect(diagnostics.fields, [
      {'nativePacketQueueDepth': 3, 'strokeWorkQueueDepth': 2},
      {
        'reason': 'stroke_complete',
        'nativePacketQueueDepth': 3,
        'strokeWorkQueueDepth': 2,
      },
    ]);
  });

  test('finishing an inactive hold has no autosave side effects', () {
    final events = <String>[];
    final hold = CanvasStrokeAutosaveHold(
      beginContinuousEdit: () => events.add('begin'),
      endContinuousEdit: () => events.add('end'),
      nativePacketQueueDepth: () => 0,
      strokeWorkQueueDepth: () => 0,
      recordDiagnostic: _RecordingDiagnostics(events).record,
    );

    hold.finish(reason: 'never_started');

    expect(hold.isActive, isFalse);
    expect(events, isEmpty);
  });
}

class _RecordingDiagnostics {
  _RecordingDiagnostics(this.events);

  final List<String> events;
  final List<Map<String, Object?>> fields = [];

  void record(String event, [Map<String, Object?> values = const {}]) {
    events.add(event);
    fields.add(values);
  }
}
