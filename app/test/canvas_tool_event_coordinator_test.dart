import 'dart:async';

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
        vectorSelectionTolerance: () => 8,
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
    'vector transform schedules hit testing without waiting on pointer down',
    () async {
      final engine = InMemoryEngineApi();
      final vectorOperations = _RecordingVectorToolOperations();
      final toolActions = CanvasToolActions(
        CanvasToolActionHost(
          engine: () => engine,
          context: () => throw StateError('Vector transform needs no context'),
          mounted: () => true,
          layers: () => const [],
          primaryLayerId: () => null,
          activeTool: () => IllustrationTool.vectorTransform,
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
          activeTool: () => IllustrationTool.vectorTransform,
          canvasPosition: (position) => position,
          pointerPressure: (_) => 1,
          vectorSelectionTolerance: () => 8,
          vectorSelectionAdditive: () => false,
          setSelectionGeometry: (_) {},
          setSelectionGeometryTool: (_) {},
          vectorOperations: vectorOperations,
          toolActions: toolActions,
          markDirty: ({restartTimer = true}) {},
          onSelectionCleared: () {},
        ),
      );
      final selection = Completer<bool>();
      vectorOperations.selection = selection;

      await coordinator.handleEvent(
        const PointerDownEvent(pointer: 1, position: Offset(10, 20)),
      );
      expect(vectorOperations.selectionCalls, 1);
      expect(vectorOperations.additiveSelection, false);
      expect(vectorOperations.transformed, isEmpty);

      final release = coordinator.handleEvent(
        const PointerUpEvent(pointer: 1, position: Offset(25, 35)),
      );
      selection.complete(true);
      await release;
      expect(vectorOperations.transformed, <Offset>[const Offset(15, 15)]);
    },
  );

  test(
    'vector transform previews movement and commits once on release',
    () async {
      final engine = InMemoryEngineApi();
      final vectorOperations =
          _RecordingVectorToolOperations()..selectionResult = true;
      var coordinatorDirtyMarks = 0;
      final toolActions = CanvasToolActions(
        CanvasToolActionHost(
          engine: () => engine,
          context: () => throw StateError('Vector transform needs no context'),
          mounted: () => true,
          layers: () => const [],
          primaryLayerId: () => null,
          activeTool: () => IllustrationTool.vectorTransform,
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
          activeTool: () => IllustrationTool.vectorTransform,
          canvasPosition: (position) => position,
          pointerPressure: (_) => 1,
          vectorSelectionTolerance: () => 8,
          vectorSelectionAdditive: () => false,
          setSelectionGeometry: (_) {},
          setSelectionGeometryTool: (_) {},
          vectorOperations: vectorOperations,
          toolActions: toolActions,
          markDirty: ({restartTimer = true}) => coordinatorDirtyMarks++,
          onSelectionCleared: () {},
        ),
      );

      await coordinator.handleEvent(
        const PointerDownEvent(pointer: 1, position: Offset(10, 20)),
      );
      await coordinator.handleEvent(
        const PointerMoveEvent(pointer: 1, position: Offset(14, 26)),
      );
      expect(vectorOperations.previews, <Offset>[const Offset(4, 6)]);

      await coordinator.handleEvent(
        const PointerUpEvent(pointer: 1, position: Offset(14, 26)),
      );
      expect(vectorOperations.transformed, <Offset>[const Offset(4, 6)]);
      expect(coordinatorDirtyMarks, 0);
    },
  );

  test('Bezier handle drag previews and commits one handle edit', () async {
    final engine = InMemoryEngineApi();
    const target = CanvasVectorHandleTarget(
      subpath: 1,
      anchor: 2,
      kind: CanvasVectorHandleKind.outgoing,
      point: Offset(10, 10),
    );
    final vectorOperations =
        _RecordingVectorToolOperations()..handleHit = target;
    final toolActions = CanvasToolActions(
      CanvasToolActionHost(
        engine: () => engine,
        context: () => throw StateError('Vector transform needs no context'),
        mounted: () => true,
        layers: () => const [],
        primaryLayerId: () => null,
        activeTool: () => IllustrationTool.vectorTransform,
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
        activeTool: () => IllustrationTool.vectorTransform,
        canvasPosition: (position) => position,
        pointerPressure: (_) => 1,
        vectorSelectionTolerance: () => 8,
        vectorSelectionAdditive: () => false,
        setSelectionGeometry: (_) {},
        setSelectionGeometryTool: (_) {},
        vectorOperations: vectorOperations,
        toolActions: toolActions,
        markDirty: ({restartTimer = true}) {},
        onSelectionCleared: () {},
      ),
    );

    await coordinator.handleEvent(
      const PointerDownEvent(pointer: 1, position: Offset(10, 10)),
    );
    await coordinator.handleEvent(
      const PointerMoveEvent(pointer: 1, position: Offset(14, 13)),
    );
    await coordinator.handleEvent(
      const PointerUpEvent(pointer: 1, position: Offset(14, 13)),
    );

    expect(vectorOperations.handlePreviews, <CanvasVectorHandleTarget>[target]);
    expect(vectorOperations.previews, <Offset>[const Offset(4, 3)]);
    expect(vectorOperations.handleCommits, 1);
    expect(vectorOperations.transformed, isEmpty);
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
          vectorSelectionTolerance: () => 8,
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
  final List<Offset> transformed = <Offset>[];
  final List<Offset> previews = <Offset>[];
  final List<CanvasVectorHandleTarget> handlePreviews =
      <CanvasVectorHandleTarget>[];
  CanvasVectorHandleTarget? handleHit;
  int handleCommits = 0;
  int selectionCalls = 0;
  bool? additiveSelection;
  int transformPreviewCancellations = 0;
  bool selectionResult = false;
  Completer<bool>? selection;

  @override
  Future<void> addStroke(List<double> points) async {
    addedStrokes.add(points);
  }

  @override
  Future<bool> selectVectorObjectAt(
    Offset point,
    double tolerancePx, {
    bool additive = false,
  }) {
    selectionCalls++;
    additiveSelection = additive;
    return selection?.future ?? Future<bool>.value(selectionResult);
  }

  @override
  void cancelPendingVectorSelection() {}

  @override
  Future<void> previewVectorTransform(Offset delta) async {
    previews.add(delta);
  }

  @override
  CanvasVectorHandleTarget? hitTestSelectedPathHandle(
    Offset point,
    double tolerancePx,
  ) => handleHit;

  @override
  Future<void> previewPathHandleDrag(
    CanvasVectorHandleTarget target,
    Offset delta,
  ) async {
    handlePreviews.add(target);
    previews.add(delta);
  }

  @override
  Future<void> commitPathHandleDrag() async {
    handleCommits++;
  }

  @override
  void cancelVectorTransformPreview() {
    transformPreviewCancellations++;
  }

  @override
  Future<void> eraseFirstStroke({
    required Offset center,
    required double radius,
  }) async {}

  @override
  Future<void> transformFirstStroke(Offset delta) async {
    transformed.add(delta);
  }
}
