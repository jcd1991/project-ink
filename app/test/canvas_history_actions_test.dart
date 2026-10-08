import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/app/editor_action.dart';
import 'package:project_ink/bridge/engine_api.dart';
import 'package:project_ink/canvas/canvas_history_actions.dart';

class _HistoryEngine extends InMemoryEngineApi {
  _HistoryEngine(this.events);

  final List<String> events;

  @override
  Future<void> undo() async => events.add('undo');

  @override
  Future<void> redo() async => events.add('redo');

  @override
  Future<void> navigateHistory(int sequence) async =>
      events.add('navigate:$sequence');
}

void main() {
  test(
    'undo drains strokes and starts canvas refresh before projections',
    () async {
      final events = <String>[];
      final actions = _actions(events);

      await actions.undo();

      expect(events, ['drain', 'undo', 'dirty', 'tiles', 'layers']);
    },
  );

  test('undo completes while the layer projection is still loading', () async {
    final events = <String>[];
    final projection = Completer<void>();
    final actions = _actions(
      events,
      refreshLayerProjection: () async {
        events.add('layers-start');
        await projection.future;
        events.add('layers-finish');
      },
    );

    await actions.undo();

    expect(events, ['drain', 'undo', 'dirty', 'tiles', 'layers-start']);
    projection.complete();
    await Future<void>.delayed(Duration.zero);
    expect(events.last, 'layers-finish');
  });

  test('redo command dispatch routes to the history owner', () async {
    final events = <String>[];
    final actions = _actions(events);

    expect(actions.dispatchEditorAction(EditorActionId.redo), isTrue);
    await Future<void>.delayed(Duration.zero);

    expect(events, ['drain', 'redo', 'dirty', 'tiles', 'layers']);
    expect(actions.dispatchEditorAction(EditorActionId.fitCanvas), isFalse);
  });

  test('history navigation refreshes document projections in order', () async {
    final events = <String>[];
    final actions = _actions(events);

    await actions.navigateHistory(7);

    expect(events, [
      'navigate:7',
      'dirty',
      'phase2',
      'tiles',
      'vectors',
      'state',
    ]);
  });
}

CanvasHistoryActions _actions(
  List<String> events, {
  Future<void> Function()? refreshLayerProjection,
}) => CanvasHistoryActions(
  CanvasHistoryActionHost(
    engine: () => _HistoryEngine(events),
    waitForStrokeOperations: () async => events.add('drain'),
    markDirty: () => events.add('dirty'),
    refreshLayerProjection:
        refreshLayerProjection ?? (() async => events.add('layers')),
    refreshTiles: () async => events.add('tiles'),
    loadPhase2Projections: () async => events.add('phase2'),
    loadVectorSelection: () async => events.add('vectors'),
    mounted: () => true,
    setState: (update) {
      events.add('state');
      update();
    },
  ),
);
