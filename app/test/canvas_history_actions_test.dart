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
  test('undo drains strokes before mutation and projection refresh', () async {
    final events = <String>[];
    final actions = _actions(events);

    await actions.undo();

    expect(events, ['drain', 'undo', 'dirty', 'layers', 'tiles']);
  });

  test('redo command dispatch routes to the history owner', () async {
    final events = <String>[];
    final actions = _actions(events);

    expect(actions.dispatchEditorAction(EditorActionId.redo), isTrue);
    await Future<void>.delayed(Duration.zero);

    expect(events, ['drain', 'redo', 'dirty', 'layers', 'tiles']);
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

CanvasHistoryActions _actions(List<String> events) => CanvasHistoryActions(
  CanvasHistoryActionHost(
    engine: () => _HistoryEngine(events),
    waitForStrokeOperations: () async => events.add('drain'),
    markDirty: () => events.add('dirty'),
    refreshLayerProjection: () async => events.add('layers'),
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
