import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/bridge/engine_api.dart';
import 'package:project_ink/canvas/canvas_tool_actions.dart';
import 'package:project_ink/canvas/canvas_tool_event_coordinator.dart';
import 'package:project_ink/canvas/canvas_vector_actions.dart';
import 'package:project_ink/tools/illustration_tools.dart';

void main() {
  test('vector pen delegates committed stroke data to vector owner', () async {
    final engine = InMemoryEngineApi();
    final vectorOperations = _RecordingVectorToolOperations();
    final toolActions = CanvasToolActions(
      CanvasToolActionHost(
        engine: () => engine,
        context:
            () => throw StateError('Vector pen input does not need a context'),
        mounted: () => true,
        layers: () => const [],
        primaryLayerId: () => null,
        activeTool: () => IllustrationTool.vectorPen,
        setSelectionGeometryTool: (_) {},
        markDirty: () {},
        refreshTiles: () async {},
      ),
    );
    final coordinator = CanvasToolEventCoordinator(
      CanvasToolEventHost(
        engine: () => engine,
        mounted: () => true,
        updateState: (update) => update(),
        activeTool: () => IllustrationTool.vectorPen,
        canvasPosition: (position) => position,
        pointerPressure: (_) => 0.75,
        setSelectionGeometry: (_) {},
        setSelectionGeometryTool: (_) {},
        vectorOperations: vectorOperations,
        toolActions: toolActions,
        markDirty: ({restartTimer = true}) {},
        onSelectionCleared: () {},
      ),
    );

    await coordinator.handleEvent(
      const PointerDownEvent(pointer: 1, position: Offset(10, 20)),
    );
    await coordinator.handleEvent(
      const PointerMoveEvent(pointer: 1, position: Offset(30, 40)),
    );
    await coordinator.handleEvent(
      const PointerUpEvent(pointer: 1, position: Offset(30, 40)),
    );

    expect(vectorOperations.addedStrokes, <List<double>>[
      <double>[10, 20, 0.75, 0, 30, 40, 0.75, 0],
    ]);
  });

  test(
    'owns ruler updates and keeps them across pointer-path resets',
    () async {
      final engine = InMemoryEngineApi();
      var activeTool = IllustrationTool.straightRuler;
      final toolActions = CanvasToolActions(
        CanvasToolActionHost(
          engine: () => engine,
          context: () => throw StateError('Ruler events do not need a context'),
          mounted: () => true,
          layers: () => const [],
          primaryLayerId: () => null,
          activeTool: () => activeTool,
          setSelectionGeometryTool: (_) {},
          markDirty: () {},
          refreshTiles: () async {},
        ),
      );
      final coordinator = CanvasToolEventCoordinator(
        CanvasToolEventHost(
          engine: () => engine,
          mounted: () => true,
          updateState: (update) => update(),
          activeTool: () => activeTool,
          canvasPosition: (position) => position,
          pointerPressure: (_) => 1,
          setSelectionGeometry: (_) {},
          setSelectionGeometryTool: (_) {},
          vectorOperations: _RecordingVectorToolOperations(),
          toolActions: toolActions,
          markDirty: ({restartTimer = true}) {},
          onSelectionCleared: () {},
        ),
      );

      await coordinator.handleEvent(
        const PointerDownEvent(pointer: 1, position: Offset(10, 20)),
      );
      expect(coordinator.ruler.start, const Offset(10, 20));
      expect(coordinator.ruler.end, const Offset(10, 20));
      expect(coordinator.ruler.tool, IllustrationTool.straightRuler);

      await coordinator.handleEvent(
        const PointerMoveEvent(pointer: 1, position: Offset(35, 45)),
      );
      expect(coordinator.ruler.end, const Offset(35, 45));

      coordinator.resetTransientState();
      expect(coordinator.previewPoints, isEmpty);
      expect(coordinator.ruler.start, const Offset(10, 20));
      expect(coordinator.ruler.end, const Offset(35, 45));

      activeTool = IllustrationTool.brush;
      await coordinator.handleEvent(
        const PointerUpEvent(pointer: 1, position: Offset(35, 45)),
      );
      expect(coordinator.ruler.tool, IllustrationTool.straightRuler);
    },
  );
}

class _RecordingVectorToolOperations implements CanvasVectorToolOperations {
  final List<List<double>> addedStrokes = <List<double>>[];

  @override
  Future<void> addStroke(List<double> points) async {
    addedStrokes.add(points);
  }

  @override
  Future<void> eraseFirstStroke({
    required Offset center,
    required double radius,
  }) async {}

  @override
  Future<void> transformFirstStroke(Offset delta) async {}
}
