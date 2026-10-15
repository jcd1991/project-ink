import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/bridge/engine_api/engine_api_contract.dart';
import 'package:project_ink/bridge/engine_api/engine_api_models.dart';
import 'package:project_ink/canvas/canvas_vector_actions.dart';

void main() {
  test(
    'late vector preview is cancelled after a newer preview completes',
    () async {
      final engine = _DeferredPreviewEngine();
      final actions = CanvasVectorActions(
        CanvasVectorActionHost(
          engine: () => engine,
          context: () => throw StateError('Preview does not need a context'),
          mounted: () => true,
          engineGeneration: () => 1,
          selectedLayerId: () => 7,
          onStrokesChanged: () {},
          markDirty: () {},
          refreshTiles: () async {},
        ),
      );
      await actions.loadForSelection();
      await actions.toggleStrokeSelection(11);

      final older = actions.recognizeSelected();
      final newer = actions.fitSelected();
      engine.previews[1].complete(_candidate(2));
      await newer;
      engine.previews[0].complete(_candidate(1));
      await older;

      expect(actions.candidate?.token, 2);
      expect(engine.cancelledCandidates, <int>[1]);
    },
  );

  test('curve fit sends the selected tolerance to Rust preview', () async {
    final engine = _DeferredPreviewEngine();
    final actions = CanvasVectorActions(
      CanvasVectorActionHost(
        engine: () => engine,
        context: () => throw StateError('Preview does not need a context'),
        mounted: () => true,
        engineGeneration: () => 1,
        selectedLayerId: () => 7,
        onStrokesChanged: () {},
        markDirty: () {},
        refreshTiles: () async {},
      ),
    );
    await actions.loadForSelection();
    await actions.toggleStrokeSelection(11);

    final preview = actions.fitSelected(0.25);
    engine.previews.single.complete(_candidate(4));
    await preview;

    expect(engine.fitTolerancePx, <double>[0.25]);
  });

  test('Bezier translation applies the visible preview as one edit', () async {
    final engine = _DeferredTransformEngine();
    var dirtyMarks = 0;
    final actions = CanvasVectorActions(
      CanvasVectorActionHost(
        engine: () => engine,
        context: () => throw StateError('Transform does not need a context'),
        mounted: () => true,
        engineGeneration: () => 1,
        selectedLayerId: () => 7,
        onStrokesChanged: () {},
        markDirty: () => dirtyMarks++,
        refreshTiles: () async {},
      ),
    );
    await actions.loadForSelection();
    await actions.toggleStrokeSelection(11);

    const delta = Offset(5, 4);
    final preview = actions.previewVectorTransform(delta);
    engine.transformPreview.complete(_candidate(8));
    await preview;
    expect(actions.candidate?.token, 8);
    expect(engine.appliedCandidates, isEmpty);

    await actions.transformFirstStroke(delta);
    expect(engine.appliedCandidates, <int>[8]);
    expect(actions.candidate, isNull);
    expect(dirtyMarks, 1);
  });

  test(
    'LegacyInk translation previews samples then applies one edit',
    () async {
      final engine = _LegacyTranslationEngine();
      var dirtyMarks = 0;
      final actions = CanvasVectorActions(
        CanvasVectorActionHost(
          engine: () => engine,
          context: () => throw StateError('Transform does not need a context'),
          mounted: () => true,
          engineGeneration: () => 1,
          selectedLayerId: () => 7,
          onStrokesChanged: () {},
          markDirty: () => dirtyMarks++,
          refreshTiles: () async {},
        ),
      );
      await actions.loadForSelection();
      await actions.toggleStrokeSelection(11);

      await actions.transformFirstStroke(const Offset(5, 4));

      expect(engine.translations, <(double, double)>[(5, 4)]);
      expect(engine.appliedCandidates, <int>[17]);
      expect(engine.preview?.points, <double>[
        5,
        4,
        0.25,
        0.1,
        15,
        14,
        0.75,
        0.3,
      ]);
      expect(actions.candidate, isNull);
      expect(dirtyMarks, 1);
    },
  );

  test(
    'vector transform preview snaps to a peer anchor and exposes its guide',
    () async {
      final engine = _SmartGuideEngine();
      final actions = CanvasVectorActions(
        CanvasVectorActionHost(
          engine: () => engine,
          context: () => throw StateError('Transform does not need a context'),
          mounted: () => true,
          engineGeneration: () => 1,
          selectedLayerId: () => 7,
          onStrokesChanged: () {},
          markDirty: () {},
          refreshTiles: () async {},
          viewportScale: () => 1,
        ),
      );
      await actions.loadForSelection();
      await actions.selectVectorObjectAt(Offset.zero, 8);
      await Future<void>.delayed(Duration.zero);

      await actions.previewVectorTransform(const Offset(5, 4));

      expect(engine.translations, <(double, double)>[(6, 4)]);
      expect(actions.smartGuides?.verticalX, 26);
    },
  );

  test(
    'Bezier handle hit testing preserves subpath-local anchor indices',
    () async {
      final engine = _DeferredTransformEngine();
      final actions = CanvasVectorActions(
        CanvasVectorActionHost(
          engine: () => engine,
          context:
              () => throw StateError('Hit testing does not need a context'),
          mounted: () => true,
          engineGeneration: () => 1,
          selectedLayerId: () => 7,
          onStrokesChanged: () {},
          markDirty: () {},
          refreshTiles: () async {},
        ),
      );
      await actions.loadForSelection();
      await actions.toggleStrokeSelection(11);

      final target = actions.hitTestSelectedPathHandle(const Offset(30, 0), 2);

      expect(target, isNotNull);
      expect(target!.subpath, 1);
      expect(target.anchor, 0);
      expect(target.kind, CanvasVectorHandleKind.anchor);
    },
  );

  test('shape constraint replaces only the staged preview candidate', () async {
    final engine = _ConstraintEngine();
    var dirtyMarks = 0;
    final actions = CanvasVectorActions(
      CanvasVectorActionHost(
        engine: () => engine,
        context: () => throw StateError('Preview does not need a context'),
        mounted: () => true,
        engineGeneration: () => 1,
        selectedLayerId: () => 7,
        onStrokesChanged: () {},
        markDirty: () => dirtyMarks++,
        refreshTiles: () async {},
      ),
    );
    await actions.loadForSelection();
    await actions.toggleStrokeSelection(11);
    await actions.recognizeSelected();
    expect(actions.candidate?.kind, 'Rectangle');

    await actions.constrainCandidate(0);

    expect(actions.candidate?.kind, 'Square');
    expect(actions.candidate?.token, 42);
    expect(engine.constraints, <(int, int)>[(42, 0)]);
    expect(dirtyMarks, 0);
  });
}

class _SmartGuideEngine extends _DeferredPreviewEngine {
  static const _moving = VectorObjectSummaryView(
    id: 11,
    kind: 'BezierPath',
    pointCount: 2,
    geometry: <double>[0, 0, 0, 0, 0, 0, 20, 0, 20, 0, 20, 0],
    subpathStarts: <int>[0],
    closed: <bool>[false],
    minX: 0,
    minY: 0,
    maxX: 20,
    maxY: 0,
  );
  static const _peer = VectorObjectSummaryView(
    id: 12,
    kind: 'BezierPath',
    pointCount: 2,
    geometry: <double>[26, 0, 26, 0, 26, 0, 30, 4, 30, 4, 30, 4],
    subpathStarts: <int>[0],
    closed: <bool>[false],
    minX: 26,
    minY: 0,
    maxX: 30,
    maxY: 4,
  );

  final List<(double, double)> translations = <(double, double)>[];

  @override
  Future<List<VectorObjectSummaryView>> vectorObjectSummaries({
    required int layerId,
    required int offset,
    required int limit,
  }) async => offset == 0 ? const [_moving, _peer] : const [];

  @override
  Future<VectorObjectSummaryView?> vectorObjectDetail({
    required int layerId,
    required int objectId,
  }) async => objectId == _moving.id ? _moving : _peer;

  @override
  Future<int?> hitTestVectorObject({
    required int layerId,
    required double x,
    required double y,
    required double tolerancePx,
  }) async => _moving.id;

  @override
  Future<VectorCandidateView> previewVectorPathTransform({
    required int layerId,
    required int objectId,
    required double tx,
    required double ty,
    required double rotationDegrees,
    required double uniformScale,
  }) async {
    translations.add((tx, ty));
    return _candidate(55);
  }
}

VectorCandidateView _candidate(int token, {String kind = 'BezierPath'}) =>
    VectorCandidateView(
      token: token,
      sourceId: 11,
      revision: 1,
      matched: true,
      kind: kind,
      geometry: const <double>[0, 0, 0, 0, 1, 0],
      subpathStarts: const <int>[0],
      closed: const <bool>[false],
      strokeRgba: 0x000000ff,
      strokeWidth: 1,
      notice: '',
    );

class _DeferredPreviewEngine implements EngineApi {
  static const _summary = VectorObjectSummaryView(
    id: 11,
    kind: 'LegacyInk',
    pointCount: 2,
    points: <double>[0, 0, 1, 0, 1, 1, 1, 0],
    minX: 0,
    minY: 0,
    maxX: 1,
    maxY: 1,
  );

  final List<Completer<VectorCandidateView>> previews =
      <Completer<VectorCandidateView>>[];
  final List<int> cancelledCandidates = <int>[];
  final List<double> fitTolerancePx = <double>[];

  @override
  Future<List<VectorObjectSummaryView>> vectorObjectSummaries({
    required int layerId,
    required int offset,
    required int limit,
  }) async => offset == 0 ? <VectorObjectSummaryView>[_summary] : const [];

  @override
  Future<VectorObjectSummaryView?> vectorObjectDetail({
    required int layerId,
    required int objectId,
  }) async => objectId == _summary.id ? _summary : null;

  @override
  Future<VectorCandidateView> previewVectorShape({
    required int layerId,
    required int strokeId,
  }) {
    final completer = Completer<VectorCandidateView>();
    previews.add(completer);
    return completer.future;
  }

  @override
  Future<VectorCandidateView> previewVectorCurveFit({
    required int layerId,
    required int strokeId,
    required double tolerancePx,
  }) {
    fitTolerancePx.add(tolerancePx);
    final completer = Completer<VectorCandidateView>();
    previews.add(completer);
    return completer.future;
  }

  @override
  Future<void> cancelVectorCandidate({required int token}) async {
    cancelledCandidates.add(token);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DeferredTransformEngine extends _DeferredPreviewEngine {
  static const _path = VectorObjectSummaryView(
    id: 11,
    kind: 'BezierPath',
    pointCount: 3,
    geometry: <double>[
      0,
      0,
      0,
      0,
      10,
      0,
      20,
      0,
      20,
      0,
      20,
      0,
      30,
      0,
      30,
      0,
      30,
      0,
    ],
    subpathStarts: <int>[0, 2],
    closed: <bool>[false, true],
    minX: 0,
    minY: 0,
    maxX: 20,
    maxY: 0,
  );

  final Completer<VectorCandidateView> transformPreview =
      Completer<VectorCandidateView>();
  final List<int> appliedCandidates = <int>[];

  @override
  Future<List<VectorObjectSummaryView>> vectorObjectSummaries({
    required int layerId,
    required int offset,
    required int limit,
  }) async => offset == 0 ? <VectorObjectSummaryView>[_path] : const [];

  @override
  Future<VectorObjectSummaryView?> vectorObjectDetail({
    required int layerId,
    required int objectId,
  }) async => objectId == _path.id ? _path : null;

  @override
  Future<VectorCandidateView> previewVectorPathTransform({
    required int layerId,
    required int objectId,
    required double tx,
    required double ty,
    required double rotationDegrees,
    required double uniformScale,
  }) => transformPreview.future;

  @override
  Future<void> applyVectorCandidate({required int token}) async {
    appliedCandidates.add(token);
  }
}

class _ConstraintEngine extends _DeferredPreviewEngine {
  static const _rectangle = VectorObjectSummaryView(
    id: 11,
    kind: 'LegacyInk',
    pointCount: 5,
    points: <double>[
      0,
      0,
      0.5,
      0,
      10,
      0,
      0.5,
      0,
      10,
      5,
      0.5,
      0,
      0,
      5,
      0.5,
      0,
      0,
      0,
      0.5,
      0,
    ],
    minX: 0,
    minY: 0,
    maxX: 10,
    maxY: 5,
  );
  final List<(int, int)> constraints = <(int, int)>[];

  @override
  Future<List<VectorObjectSummaryView>> vectorObjectSummaries({
    required int layerId,
    required int offset,
    required int limit,
  }) async => offset == 0 ? <VectorObjectSummaryView>[_rectangle] : const [];

  @override
  Future<VectorObjectSummaryView?> vectorObjectDetail({
    required int layerId,
    required int objectId,
  }) async => objectId == _rectangle.id ? _rectangle : null;

  @override
  Future<VectorCandidateView> previewVectorShape({
    required int layerId,
    required int strokeId,
  }) async => _candidate(42, kind: 'Rectangle');

  @override
  Future<VectorCandidateView> previewVectorShapeConstraint({
    required int candidateToken,
    required int constraint,
  }) async {
    constraints.add((candidateToken, constraint));
    return _candidate(candidateToken, kind: 'Square');
  }
}

class _LegacyTranslationEngine extends _DeferredTransformEngine {
  static const _legacy = VectorObjectSummaryView(
    id: 11,
    kind: 'LegacyInk',
    pointCount: 2,
    points: <double>[0, 0, 0.25, 0.1, 10, 10, 0.75, 0.3],
    minX: 0,
    minY: 0,
    maxX: 10,
    maxY: 10,
  );

  final List<(double, double)> translations = <(double, double)>[];
  VectorCandidateView? preview;

  @override
  Future<List<VectorObjectSummaryView>> vectorObjectSummaries({
    required int layerId,
    required int offset,
    required int limit,
  }) async => offset == 0 ? <VectorObjectSummaryView>[_legacy] : const [];

  @override
  Future<VectorObjectSummaryView?> vectorObjectDetail({
    required int layerId,
    required int objectId,
  }) async => objectId == _legacy.id ? _legacy : null;

  @override
  Future<VectorCandidateView> previewVectorLegacyTranslation({
    required int layerId,
    required int strokeId,
    required double tx,
    required double ty,
  }) async {
    translations.add((tx, ty));
    preview = VectorCandidateView(
      token: 17,
      sourceId: strokeId,
      revision: 1,
      matched: true,
      kind: 'LegacyInk',
      points: const <double>[5, 4, 0.25, 0.1, 15, 14, 0.75, 0.3],
      geometry: const <double>[],
      subpathStarts: const <int>[],
      closed: const <bool>[],
      strokeRgba: 0x18181cff,
      strokeWidth: 0,
      notice: '',
    );
    return preview!;
  }
}
