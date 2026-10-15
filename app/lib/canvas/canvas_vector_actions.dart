import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../bridge/engine_api.dart';
import 'canvas_smart_guides.dart';

enum CanvasVectorEditKind {
  moveAnchor,
  moveIncomingHandle,
  moveOutgoingHandle,
  makeSmooth,
  makeCorner,
  splitSegment,
  deleteAnchor,
  transform,
}

enum CanvasVectorHandleKind { anchor, incoming, outgoing }

@immutable
class CanvasVectorHandleTarget {
  const CanvasVectorHandleTarget({
    required this.subpath,
    required this.anchor,
    required this.kind,
    required this.point,
  });

  final int subpath;
  final int anchor;
  final CanvasVectorHandleKind kind;
  final Offset point;
}

class CanvasVectorEditRequest {
  const CanvasVectorEditRequest({
    required this.kind,
    required this.subpath,
    required this.index,
    required this.dx,
    required this.dy,
    required this.t,
    required this.rotationDegrees,
    required this.uniformScale,
  });

  final CanvasVectorEditKind kind;
  final int subpath;
  final int index;
  final double dx;
  final double dy;
  final double t;
  final double rotationDegrees;
  final double uniformScale;
}

/// Vector mutations initiated by pointer-driven canvas tools.
abstract interface class CanvasVectorToolOperations {
  Future<void> addStroke(List<double> points);
  Future<bool> selectVectorObjectAt(
    Offset point,
    double tolerancePx, {
    bool additive = false,
  });
  void cancelPendingVectorSelection();
  CanvasVectorHandleTarget? hitTestSelectedPathHandle(
    Offset point,
    double tolerancePx,
  );
  Future<void> previewPathHandleDrag(
    CanvasVectorHandleTarget target,
    Offset delta,
  );
  Future<void> commitPathHandleDrag();
  Future<void> previewVectorTransform(Offset delta);
  void cancelVectorTransformPreview();
  Future<void> transformFirstStroke(Offset delta);
  Future<void> eraseFirstStroke({
    required Offset center,
    required double radius,
  });
}

/// Active-session inputs for Rust-backed vector editing actions.
class CanvasVectorActionHost {
  const CanvasVectorActionHost({
    required this.engine,
    required this.context,
    required this.mounted,
    required this.engineGeneration,
    required this.selectedLayerId,
    required this.onStrokesChanged,
    required this.markDirty,
    required this.refreshTiles,
    this.viewportScale,
  });

  final EngineApi Function() engine;
  final BuildContext Function() context;
  final bool Function() mounted;
  final int Function() engineGeneration;
  final int? Function() selectedLayerId;
  final void Function() onStrokesChanged;
  final void Function() markDirty;
  final Future<void> Function() refreshTiles;
  final double Function()? viewportScale;
}

/// Owns the selected vector projection and Rust vector edit workflows.
class CanvasVectorActions implements CanvasVectorToolOperations {
  CanvasVectorActions(this.host);

  final CanvasVectorActionHost host;
  List<VectorObjectSummaryView> _strokes = const [];
  final Set<int> _selectedIds = <int>{};
  final Map<int, VectorObjectSummaryView> _details =
      <int, VectorObjectSummaryView>{};
  final Map<int, VectorObjectSummaryView> _guideDetails =
      <int, VectorObjectSummaryView>{};
  VectorCandidateView? _candidate;
  CanvasSmartGuideResult? _smartGuides;
  EngineApi? _lastEngine;
  int? _lastLayerId;
  int? _lastEngineGeneration;
  bool _hasMore = false;
  int _nextOffset = 0;
  int _selectionRequest = 0;
  int _guideDetailRequest = 0;
  int _candidateRequest = 0;
  Offset? _candidateRequestedDelta;
  Offset? _candidateTransformDelta;
  Future<void>? _candidatePreviewFuture;
  Future<void>? _pathHandlePreviewFuture;

  List<VectorObjectSummaryView> get strokes => _strokes;
  Set<int> get selectedStrokeIds => Set<int>.unmodifiable(_selectedIds);
  List<VectorObjectSummaryView> get selectedStrokes => _selectedIds
      .map((id) => _details[id])
      .whereType<VectorObjectSummaryView>()
      .toList(growable: false);
  VectorCandidateView? get candidate => _candidate;
  CanvasSmartGuideResult? get smartGuides => _smartGuides;
  VectorObjectSummaryView? get selectedBezierPath {
    final object = _singleSelectedStroke;
    return object?.kind == 'BezierPath' ? object : null;
  }

  bool get hasMore => _hasMore;

  Future<void> toggleStrokeSelection(int strokeId) async {
    if (_strokes.every((stroke) => stroke.id != strokeId)) return;
    if (!_selectedIds.add(strokeId)) {
      _selectedIds.remove(strokeId);
      _details.remove(strokeId);
      _guideDetails.remove(strokeId);
    } else {
      await _fetchDetail(strokeId);
    }
    _discardCandidate();
    if (host.mounted()) host.onStrokesChanged();
  }

  @override
  Future<bool> selectVectorObjectAt(
    Offset point,
    double tolerancePx, {
    bool additive = false,
  }) async {
    final request = ++_selectionRequest;
    final layerId = host.selectedLayerId();
    if (layerId == null) return false;
    final engine = host.engine();
    final generation = host.engineGeneration();
    try {
      final id = await engine.hitTestVectorObject(
        layerId: layerId,
        x: point.dx,
        y: point.dy,
        tolerancePx: tolerancePx,
      );
      if (!host.mounted() ||
          request != _selectionRequest ||
          engine != host.engine() ||
          generation != host.engineGeneration() ||
          host.selectedLayerId() != layerId) {
        return false;
      }
      final wasSelected = id != null && _selectedIds.contains(id);
      if (additive) {
        if (id == null) return false;
        _guideDetailRequest++;
        if (wasSelected) {
          _selectedIds.remove(id);
          _details.remove(id);
          _guideDetails.remove(id);
        } else {
          _selectedIds.add(id);
        }
      } else {
        _guideDetailRequest++;
        _selectedIds
          ..clear()
          ..addAll(id == null ? const <int>[] : <int>[id]);
        _details.clear();
        _guideDetails.clear();
      }
      if (id != null && _selectedIds.contains(id)) {
        await _fetchDetail(id, engine: engine, layerId: layerId);
        if (request != _selectionRequest ||
            !host.mounted() ||
            engine != host.engine() ||
            generation != host.engineGeneration() ||
            host.selectedLayerId() != layerId) {
          return false;
        }
        unawaited(_loadGuideDetails(id, engine, layerId, generation));
      }
      _discardCandidate();
      host.onStrokesChanged();
      return !additive && wasSelected;
    } catch (error, stack) {
      debugPrint('Project Ink vector object hit-test failed: $error\n$stack');
      return false;
    }
  }

  @override
  void cancelPendingVectorSelection() {
    _selectionRequest++;
  }

  void _discardCandidate() {
    _candidateRequest++;
    _candidateRequestedDelta = null;
    _candidateTransformDelta = null;
    _candidatePreviewFuture = null;
    final previous = _candidate;
    _candidate = null;
    _smartGuides = null;
    if (previous != null && previous.token > 0) {
      final engine = _lastEngine;
      if (engine != null) {
        unawaited(engine.cancelVectorCandidate(token: previous.token));
      }
    }
  }

  @override
  CanvasVectorHandleTarget? hitTestSelectedPathHandle(
    Offset point,
    double tolerancePx,
  ) {
    final object = selectedBezierPath;
    if (object == null ||
        object.geometry.length % 6 != 0 ||
        object.subpathStarts.isEmpty ||
        object.subpathStarts.length != object.closed.length ||
        !tolerancePx.isFinite ||
        tolerancePx < 0) {
      return null;
    }
    final anchorCount = object.geometry.length ~/ 6;
    CanvasVectorHandleTarget? closest;
    var closestDistance = tolerancePx;
    for (var subpath = 0; subpath < object.subpathStarts.length; subpath++) {
      final start = object.subpathStarts[subpath];
      final end =
          subpath + 1 < object.subpathStarts.length
              ? object.subpathStarts[subpath + 1]
              : anchorCount;
      if (start < 0 || end > anchorCount || end <= start) return null;
      for (var globalAnchor = start; globalAnchor < end; globalAnchor++) {
        final anchor = globalAnchor - start;
        final offset = globalAnchor * 6;
        final anchorPoint = Offset(
          object.geometry[offset],
          object.geometry[offset + 1],
        );
        final points = <(CanvasVectorHandleKind, Offset)>[
          (CanvasVectorHandleKind.anchor, anchorPoint),
          (
            CanvasVectorHandleKind.incoming,
            Offset(object.geometry[offset + 2], object.geometry[offset + 3]),
          ),
          (
            CanvasVectorHandleKind.outgoing,
            Offset(object.geometry[offset + 4], object.geometry[offset + 5]),
          ),
        ];
        for (final (kind, handlePoint) in points) {
          if (kind != CanvasVectorHandleKind.anchor &&
              (handlePoint - anchorPoint).distance < 0.25) {
            continue;
          }
          final distance = (handlePoint - point).distance;
          if (distance <= closestDistance) {
            closestDistance = distance;
            closest = CanvasVectorHandleTarget(
              subpath: subpath,
              anchor: anchor,
              kind: kind,
              point: handlePoint,
            );
          }
        }
      }
    }
    return closest;
  }

  @override
  Future<void> previewPathHandleDrag(
    CanvasVectorHandleTarget target,
    Offset delta,
  ) {
    final kind = switch (target.kind) {
      CanvasVectorHandleKind.anchor => CanvasVectorEditKind.moveAnchor,
      CanvasVectorHandleKind.incoming =>
        CanvasVectorEditKind.moveIncomingHandle,
      CanvasVectorHandleKind.outgoing =>
        CanvasVectorEditKind.moveOutgoingHandle,
    };
    final request = CanvasVectorEditRequest(
      kind: kind,
      subpath: target.subpath,
      index: target.anchor,
      dx:
          target.kind == CanvasVectorHandleKind.anchor
              ? delta.dx
              : target.point.dx + delta.dx,
      dy:
          target.kind == CanvasVectorHandleKind.anchor
              ? delta.dy
              : target.point.dy + delta.dy,
      t: 0,
      rotationDegrees: 0,
      uniformScale: 1,
    );
    final task = previewPathEdit(request);
    _pathHandlePreviewFuture = task;
    return task;
  }

  @override
  Future<void> commitPathHandleDrag() async {
    final pending = _pathHandlePreviewFuture;
    _pathHandlePreviewFuture = null;
    if (pending != null) await pending;
    await applyCandidate();
  }

  @override
  Future<void> addStroke(List<double> points) async {
    final layerId = host.selectedLayerId();
    if (layerId == null || points.length < 4) {
      if (host.mounted()) {
        ScaffoldMessenger.of(host.context()).showSnackBar(
          const SnackBar(
            content: Text('Add a vector layer before drawing vector ink.'),
          ),
        );
      }
      return;
    }
    await host.engine().addVectorStroke(
      layerId: layerId,
      points: points,
      closed: false,
    );
    host.markDirty();
  }

  @override
  Future<void> transformFirstStroke(Offset delta) async {
    final layerId = host.selectedLayerId();
    final stroke = _singleSelectedStroke;
    if (stroke == null || layerId == null || delta.distance < 0.5) {
      return;
    }
    if (stroke.kind != 'BezierPath' && stroke.kind != 'LegacyInk') return;
    if (_candidateRequestedDelta != delta || _candidatePreviewFuture == null) {
      await previewVectorTransform(delta);
    } else {
      await _candidatePreviewFuture;
    }
    final candidate = _candidate;
    final engine = host.engine();
    final generation = host.engineGeneration();
    if (candidate == null || !candidate.matched || candidate.token <= 0) return;
    try {
      await engine.applyVectorCandidate(token: candidate.token);
      if (!host.mounted() ||
          engine != host.engine() ||
          generation != host.engineGeneration()) {
        return;
      }
      _discardCandidate();
      host.onStrokesChanged();
      await loadForSelection();
      host.markDirty();
      await host.refreshTiles();
    } catch (error, stack) {
      debugPrint('Project Ink vector transform rejected: $error\n$stack');
    }
  }

  @override
  Future<void> previewVectorTransform(Offset delta) async {
    final layerId = host.selectedLayerId();
    final object = _singleSelectedStroke;
    if (layerId == null ||
        object == null ||
        (object.kind != 'BezierPath' && object.kind != 'LegacyInk') ||
        delta.distance < 0.5) {
      return;
    }
    _discardCandidate();
    final snapped = _snapVectorDelta(object, delta);
    _smartGuides =
        snapped.verticalX == null && snapped.horizontalY == null
            ? null
            : snapped;
    final request = _candidateRequest;
    final engine = host.engine();
    final generation = host.engineGeneration();
    _candidateRequestedDelta = delta;
    _candidateTransformDelta = Offset(snapped.delta.x, snapped.delta.y);
    final task = _completeTransformPreview(
      request: request,
      engine: engine,
      generation: generation,
      layerId: layerId,
      objectId: object.id,
      objectKind: object.kind,
      delta: _candidateTransformDelta!,
    );
    _candidatePreviewFuture = task;
    await task;
  }

  CanvasSmartGuideResult _snapVectorDelta(
    VectorObjectSummaryView moving,
    Offset requested,
  ) {
    final movingDetail = _details[moving.id] ?? moving;
    final movingX = <double>[];
    final movingY = <double>[];
    _appendGuideFeatures(movingDetail, movingX, movingY, includeAnchors: true);
    if (movingX.isEmpty || movingY.isEmpty) {
      return CanvasSmartGuideResult(
        delta: math.Point<double>(requested.dx, requested.dy),
      );
    }

    final referenceX = <double>[];
    final referenceY = <double>[];
    for (final summary in _strokes) {
      if (summary.id == moving.id) continue;
      _appendGuideFeatures(summary, referenceX, referenceY);
      final detail = _guideDetails[summary.id];
      if (detail != null) {
        _appendGuideFeatures(
          detail,
          referenceX,
          referenceY,
          includeAnchors: true,
        );
      }
    }
    final scale = (host.viewportScale?.call() ?? 1.0).clamp(0.1, 32.0);
    return snapCanvasSmartGuides(
      movingX: movingX,
      movingY: movingY,
      referenceX: referenceX,
      referenceY: referenceY,
      requestedDelta: math.Point<double>(requested.dx, requested.dy),
      tolerance: 8.0 / scale,
    );
  }

  void _appendGuideFeatures(
    VectorObjectSummaryView object,
    List<double> x,
    List<double> y, {
    bool includeAnchors = false,
  }) {
    const maximumFeatures = 2048;
    if (x.length <= maximumFeatures - 3) {
      x.addAll([object.minX, (object.minX + object.maxX) / 2, object.maxX]);
    }
    if (y.length <= maximumFeatures - 3) {
      y.addAll([object.minY, (object.minY + object.maxY) / 2, object.maxY]);
    }
    if (!includeAnchors) return;
    if (object.kind == 'BezierPath' && object.geometry.length % 6 == 0) {
      for (var index = 0; index < object.geometry.length; index += 6) {
        if (x.length < maximumFeatures) x.add(object.geometry[index]);
        if (y.length < maximumFeatures) y.add(object.geometry[index + 1]);
      }
    } else if (object.kind == 'LegacyInk' && object.points.length % 4 == 0) {
      for (var index = 0; index < object.points.length; index += 4) {
        if (x.length < maximumFeatures) x.add(object.points[index]);
        if (y.length < maximumFeatures) y.add(object.points[index + 1]);
      }
    }
  }

  Future<void> _loadGuideDetails(
    int movingId,
    EngineApi engine,
    int layerId,
    int generation,
  ) async {
    final request = ++_guideDetailRequest;
    final selectedIndex = _strokes.indexWhere(
      (object) => object.id == movingId,
    );
    if (selectedIndex < 0) return;
    final selected = _strokes[selectedIndex];
    final peers =
        _strokes.where((object) => object.id != movingId).toList()
          ..sort((first, second) {
            final firstDistance = _boundsDistanceSquared(selected, first);
            final secondDistance = _boundsDistanceSquared(selected, second);
            return firstDistance.compareTo(secondDistance);
          });
    final nearby = peers.take(8).toList(growable: false);
    try {
      final details = await Future.wait(
        nearby.map(
          (object) =>
              engine.vectorObjectDetail(layerId: layerId, objectId: object.id),
        ),
      );
      if (!host.mounted() ||
          engine != host.engine() ||
          generation != host.engineGeneration() ||
          host.selectedLayerId() != layerId ||
          request != _guideDetailRequest ||
          !_selectedIds.contains(movingId)) {
        return;
      }
      for (var index = 0; index < nearby.length; index++) {
        final detail = details[index];
        if (detail != null) _guideDetails[nearby[index].id] = detail;
      }
      host.onStrokesChanged();
    } catch (error, stack) {
      debugPrint('Project Ink smart-guide details unavailable: $error\n$stack');
    }
  }

  double _boundsDistanceSquared(
    VectorObjectSummaryView first,
    VectorObjectSummaryView second,
  ) {
    final dx = (first.minX + first.maxX - second.minX - second.maxX) / 2;
    final dy = (first.minY + first.maxY - second.minY - second.maxY) / 2;
    return dx * dx + dy * dy;
  }

  Future<void> _completeTransformPreview({
    required int request,
    required EngineApi engine,
    required int generation,
    required int layerId,
    required int objectId,
    required String objectKind,
    required Offset delta,
  }) async {
    try {
      final candidate =
          objectKind == 'LegacyInk'
              ? await engine.previewVectorLegacyTranslation(
                layerId: layerId,
                strokeId: objectId,
                tx: delta.dx,
                ty: delta.dy,
              )
              : await engine.previewVectorPathTransform(
                layerId: layerId,
                objectId: objectId,
                tx: delta.dx,
                ty: delta.dy,
                rotationDegrees: 0,
                uniformScale: 1,
              );
      if (!host.mounted() ||
          request != _candidateRequest ||
          engine != host.engine() ||
          generation != host.engineGeneration() ||
          host.selectedLayerId() != layerId ||
          !_selectedIds.contains(objectId)) {
        if (candidate.token > 0) {
          unawaited(engine.cancelVectorCandidate(token: candidate.token));
        }
        return;
      }
      _candidate = candidate;
      host.onStrokesChanged();
    } catch (error, stack) {
      debugPrint(
        'Project Ink vector transform preview failed: $error\\n$stack',
      );
    }
  }

  @override
  void cancelVectorTransformPreview() {
    _pathHandlePreviewFuture = null;
    _discardCandidate();
    if (host.mounted()) host.onStrokesChanged();
  }

  @override
  Future<void> eraseFirstStroke({
    required Offset center,
    required double radius,
  }) async {
    final layerId = host.selectedLayerId();
    final stroke = _singleSelectedStroke;
    if (stroke == null || stroke.kind != 'LegacyInk' || layerId == null) return;
    await host.engine().eraseVectorSegment(
      layerId: layerId,
      strokeId: stroke.id,
      centerX: center.dx,
      centerY: center.dy,
      radius: radius,
    );
    await loadForSelection();
    host.markDirty();
  }

  void clearStrokes() {
    cancelPendingVectorSelection();
    _guideDetailRequest++;
    _strokes = const [];
    _selectedIds.clear();
    _details.clear();
    _guideDetails.clear();
    _discardCandidate();
    _lastEngine = null;
    _lastLayerId = null;
    _lastEngineGeneration = null;
    _hasMore = false;
    _nextOffset = 0;
  }

  Future<void> loadForSelection() async {
    final layerId = host.selectedLayerId();
    if (layerId == null) {
      clearStrokes();
      if (host.mounted()) host.onStrokesChanged();
      return;
    }
    final engine = host.engine();
    final generation = host.engineGeneration();
    if (!identical(engine, _lastEngine) ||
        generation != _lastEngineGeneration ||
        layerId != _lastLayerId) {
      cancelPendingVectorSelection();
      _guideDetailRequest++;
      _selectedIds.clear();
      _details.clear();
      _guideDetails.clear();
      _discardCandidate();
      _lastEngine = engine;
      _lastEngineGeneration = generation;
      _lastLayerId = layerId;
      _strokes = const [];
      _nextOffset = 0;
      _hasMore = false;
    }
    try {
      final page = await engine.vectorObjectSummaries(
        layerId: layerId,
        offset: 0,
        limit: 64,
      );
      if (host.mounted() &&
          engine == host.engine() &&
          generation == host.engineGeneration() &&
          host.selectedLayerId() == layerId) {
        _strokes = page;
        _nextOffset = page.length;
        _hasMore = page.length == 64;
        if (!_hasMore) _reconcileSelection(page);
        await _loadSelectedDetails(engine, layerId, generation);
        host.onStrokesChanged();
      }
    } catch (error, stack) {
      debugPrint('Project Ink vector projection unavailable: $error\n$stack');
    }
  }

  Future<void> loadNextPage() async {
    final layerId = host.selectedLayerId();
    final engine = host.engine();
    final generation = host.engineGeneration();
    if (layerId == null || !_hasMore) return;
    try {
      final page = await engine.vectorObjectSummaries(
        layerId: layerId,
        offset: _nextOffset,
        limit: 64,
      );
      if (!host.mounted() ||
          engine != host.engine() ||
          generation != host.engineGeneration() ||
          host.selectedLayerId() != layerId) {
        return;
      }
      _strokes = List<VectorObjectSummaryView>.unmodifiable([
        ..._strokes,
        ...page,
      ]);
      _nextOffset += page.length;
      _hasMore = page.length == 64;
      if (!_hasMore) {
        _reconcileSelection(_strokes);
      }
      await _loadSelectedDetails(engine, layerId, generation);
      host.onStrokesChanged();
    } catch (error, stack) {
      debugPrint('Project Ink vector summary page unavailable: $error\n$stack');
    }
  }

  void _reconcileSelection(List<VectorObjectSummaryView> current) {
    _selectedIds.removeWhere(
      (id) => current.every((stroke) => stroke.id != id),
    );
    _details.removeWhere((id, _) => !_selectedIds.contains(id));
  }

  Future<void> _loadSelectedDetails(
    EngineApi engine,
    int layerId,
    int generation,
  ) async {
    for (final id in _selectedIds.toList(growable: false)) {
      await _fetchDetail(
        id,
        engine: engine,
        layerId: layerId,
        generation: generation,
      );
    }
  }

  Future<void> _fetchDetail(
    int id, {
    EngineApi? engine,
    int? layerId,
    int? generation,
  }) async {
    final activeEngine = engine ?? host.engine();
    final activeLayer = layerId ?? host.selectedLayerId();
    final activeGeneration = generation ?? host.engineGeneration();
    if (activeLayer == null) return;
    try {
      final detail = await activeEngine.vectorObjectDetail(
        layerId: activeLayer,
        objectId: id,
      );
      if (!host.mounted() ||
          activeEngine != host.engine() ||
          activeGeneration != host.engineGeneration() ||
          activeLayer != host.selectedLayerId() ||
          !_selectedIds.contains(id)) {
        return;
      }
      if (detail == null) {
        _selectedIds.remove(id);
        _details.remove(id);
      } else {
        _details[id] = detail;
      }
    } catch (error, stack) {
      debugPrint(
        'Project Ink selected vector detail unavailable: $error\n$stack',
      );
    }
  }

  Future<void> simplifySelected() async {
    final layerId = host.selectedLayerId();
    final stroke = _singleSelectedStroke;
    if (layerId == null || stroke == null || stroke.kind != 'LegacyInk') return;
    try {
      await host.engine().simplifyVectorStroke(
        layerId: layerId,
        strokeId: stroke.id,
        tolerance: 1.0,
      );
      await loadForSelection();
      host.markDirty();
    } catch (error, stack) {
      debugPrint('Project Ink vector simplify rejected: $error\n$stack');
    }
  }

  Future<void> connectSelected() async {
    final layerId = host.selectedLayerId();
    final selected = selectedStrokes;
    if (layerId == null || selected.length != 2) return;
    try {
      await host.engine().connectVectorStrokes(
        layerId: layerId,
        firstId: selected[0].id,
        secondId: selected[1].id,
        tolerance: 8.0,
      );
      await loadForSelection();
      host.markDirty();
    } catch (error, stack) {
      debugPrint('Project Ink vector connect rejected: $error\n$stack');
    }
  }

  Future<void> editSelectedPoint() async {
    final layerId = host.selectedLayerId();
    final stroke = _singleSelectedStroke;
    if (layerId == null ||
        stroke == null ||
        stroke.kind != 'LegacyInk' ||
        stroke.points.length < 4) {
      return;
    }
    final x = TextEditingController(text: stroke.points[0].toStringAsFixed(2));
    final y = TextEditingController(text: stroke.points[1].toStringAsFixed(2));
    final pressure = TextEditingController(
      text: stroke.points[2].toStringAsFixed(3),
    );
    final tilt = TextEditingController(
      text: stroke.points[3].toStringAsFixed(3),
    );
    final accepted = await showDialog<bool>(
      context: host.context(),
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('Edit vector control point'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _boundedNumberField('X', x),
                  _boundedNumberField('Y', y),
                  _boundedNumberField('Pressure (0–1)', pressure),
                  _boundedNumberField('Tilt', tilt),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Apply'),
              ),
            ],
          ),
    );
    final controllers = [x, y, pressure, tilt];
    if (accepted != true || !host.mounted()) {
      for (final controller in controllers) {
        controller.dispose();
      }
      return;
    }
    final values = controllers
        .map((controller) => double.tryParse(controller.text.trim()))
        .toList(growable: false);
    for (final controller in controllers) {
      controller.dispose();
    }
    if (values.any((value) => value == null || !value.isFinite)) return;
    try {
      await host.engine().setVectorPoint(
        layerId: layerId,
        strokeId: stroke.id,
        index: 0,
        x: values[0]!,
        y: values[1]!,
        pressure: values[2]!.clamp(0.0, 1.0),
        tilt: values[3]!,
      );
      await loadForSelection();
      host.markDirty();
      unawaited(host.refreshTiles());
    } catch (error, stack) {
      debugPrint('Project Ink vector point edit rejected: $error\n$stack');
    }
  }

  VectorObjectSummaryView? get _singleSelectedStroke =>
      selectedStrokes.length == 1 ? selectedStrokes.single : null;

  Future<void> recognizeSelected() => _previewSelected(fitTolerancePx: null);

  Future<void> fitSelected([double tolerancePx = 1.0]) {
    if (!tolerancePx.isFinite || tolerancePx < 0.25 || tolerancePx > 8.0) {
      return Future<void>.value();
    }
    return _previewSelected(fitTolerancePx: tolerancePx);
  }

  Future<void> _previewSelected({required double? fitTolerancePx}) async {
    final layerId = host.selectedLayerId();
    final stroke = _singleSelectedStroke;
    if (layerId == null || stroke == null) return;
    final engine = host.engine();
    final generation = host.engineGeneration();
    _discardCandidate();
    final request = _candidateRequest;
    try {
      final candidate =
          fitTolerancePx == null
              ? await engine.previewVectorShape(
                layerId: layerId,
                strokeId: stroke.id,
              )
              : await engine.previewVectorCurveFit(
                layerId: layerId,
                strokeId: stroke.id,
                tolerancePx: fitTolerancePx,
              );
      if (!host.mounted() ||
          request != _candidateRequest ||
          !identical(engine, host.engine()) ||
          generation != host.engineGeneration() ||
          host.selectedLayerId() != layerId ||
          !_selectedIds.contains(stroke.id)) {
        if (candidate.token > 0) {
          unawaited(engine.cancelVectorCandidate(token: candidate.token));
        }
        return;
      }
      _candidate = candidate;
      host.onStrokesChanged();
    } catch (error, stack) {
      debugPrint('Project Ink vector preview rejected: $error\\n$stack');
    }
  }

  Future<void> applyCandidate() async {
    final candidate = _candidate;
    if (candidate == null || !candidate.matched || candidate.token <= 0) return;
    final engine = host.engine();
    final generation = host.engineGeneration();
    try {
      await engine.applyVectorCandidate(token: candidate.token);
      if (!host.mounted() ||
          !identical(engine, host.engine()) ||
          generation != host.engineGeneration()) {
        return;
      }
      _candidate = null;
      await loadForSelection();
      host.markDirty();
      await host.refreshTiles();
    } catch (error, stack) {
      debugPrint(
        'Project Ink vector candidate apply rejected: $error\\n$stack',
      );
    }
  }

  Future<void> constrainCandidate(int constraint) async {
    final current = _candidate;
    if (current == null ||
        !current.matched ||
        current.token <= 0 ||
        (constraint == 0 && current.kind != 'Rectangle') ||
        (constraint == 1 && current.kind != 'Ellipse') ||
        (constraint != 0 && constraint != 1)) {
      return;
    }
    final engine = host.engine();
    final generation = host.engineGeneration();
    final request = _candidateRequest;
    try {
      final constrained = await engine.previewVectorShapeConstraint(
        candidateToken: current.token,
        constraint: constraint,
      );
      if (!host.mounted() ||
          request != _candidateRequest ||
          !identical(engine, host.engine()) ||
          generation != host.engineGeneration() ||
          !identical(_candidate, current)) {
        if (constrained.token > 0) {
          unawaited(engine.cancelVectorCandidate(token: constrained.token));
        }
        return;
      }
      _candidate = constrained;
      host.onStrokesChanged();
    } catch (error, stack) {
      debugPrint(
        'Project Ink shape constraint preview failed: $error\\n$stack',
      );
    }
  }

  Future<void> restoreOriginalInk() async {
    final layerId = host.selectedLayerId();
    final object = _singleSelectedStroke;
    if (layerId == null || object == null || !object.hasSourceArchive) return;
    final engine = host.engine();
    final generation = host.engineGeneration();
    _discardCandidate();
    try {
      await engine.restoreVectorOriginalInk(
        layerId: layerId,
        objectId: object.id,
      );
      if (!host.mounted() ||
          engine != host.engine() ||
          generation != host.engineGeneration()) {
        return;
      }
      await loadForSelection();
      host.markDirty();
      await host.refreshTiles();
    } catch (error, stack) {
      debugPrint(
        'Project Ink original vector ink restore failed: $error\n$stack',
      );
    }
  }

  Future<void> repeatSelected(CanvasVectorRepeatOptions options) async {
    final layerId = host.selectedLayerId();
    final object = _singleSelectedStroke;
    if (layerId == null || object == null || object.kind != 'BezierPath') {
      return;
    }
    final engine = host.engine();
    final generation = host.engineGeneration();
    try {
      final ids = await engine.repeatVectorPath(
        layerId: layerId,
        objectId: object.id,
        options: options,
      );
      if (!host.mounted() ||
          engine != host.engine() ||
          generation != host.engineGeneration() ||
          host.selectedLayerId() != layerId) {
        return;
      }
      _selectedIds
        ..clear()
        ..addAll(ids);
      _guideDetails.clear();
      await loadForSelection();
      host.markDirty();
      await host.refreshTiles();
      if (host.mounted()) {
        ScaffoldMessenger.of(host.context()).showSnackBar(
          SnackBar(
            content: Text('Added ${ids.length} editable vector copies.'),
          ),
        );
      }
    } catch (error, stack) {
      debugPrint('Project Ink vector repeat failed: $error\n$stack');
      if (host.mounted()) {
        ScaffoldMessenger.of(host.context()).showSnackBar(
          const SnackBar(content: Text('Could not repeat the selected path.')),
        );
      }
    }
  }

  Future<void> previewPathEdit(CanvasVectorEditRequest request) async {
    final layerId = host.selectedLayerId();
    final object = _singleSelectedStroke;
    if (layerId == null || object == null || object.kind != 'BezierPath') {
      return;
    }
    final engine = host.engine();
    final generation = host.engineGeneration();
    _discardCandidate();
    final candidateRequest = _candidateRequest;
    try {
      final candidate = switch (request.kind) {
        CanvasVectorEditKind.moveAnchor => await engine.previewVectorAnchorMove(
          layerId: layerId,
          objectId: object.id,
          subpath: request.subpath,
          anchor: request.index,
          dx: request.dx,
          dy: request.dy,
        ),
        CanvasVectorEditKind.moveIncomingHandle ||
        CanvasVectorEditKind.moveOutgoingHandle => await engine
            .previewVectorHandleMove(
              layerId: layerId,
              objectId: object.id,
              subpath: request.subpath,
              anchor: request.index,
              incoming: request.kind == CanvasVectorEditKind.moveIncomingHandle,
              x: request.dx,
              y: request.dy,
            ),
        CanvasVectorEditKind.makeSmooth || CanvasVectorEditKind.makeCorner =>
          await engine.previewVectorAnchorSmooth(
            layerId: layerId,
            objectId: object.id,
            subpath: request.subpath,
            anchor: request.index,
            smooth: request.kind == CanvasVectorEditKind.makeSmooth,
          ),
        CanvasVectorEditKind.splitSegment => await engine
            .previewVectorSegmentSplit(
              layerId: layerId,
              objectId: object.id,
              subpath: request.subpath,
              segment: request.index,
              t: request.t,
            ),
        CanvasVectorEditKind.deleteAnchor => await engine
            .previewVectorAnchorDelete(
              layerId: layerId,
              objectId: object.id,
              subpath: request.subpath,
              anchor: request.index,
            ),
        CanvasVectorEditKind.transform => await engine
            .previewVectorPathTransform(
              layerId: layerId,
              objectId: object.id,
              tx: request.dx,
              ty: request.dy,
              rotationDegrees: request.rotationDegrees,
              uniformScale: request.uniformScale,
            ),
      };
      if (!host.mounted() ||
          candidateRequest != _candidateRequest ||
          engine != host.engine() ||
          generation != host.engineGeneration()) {
        if (candidate.token > 0) {
          unawaited(engine.cancelVectorCandidate(token: candidate.token));
        }
        return;
      }
      _candidate = candidate;
      host.onStrokesChanged();
    } catch (error, stack) {
      debugPrint('Project Ink Bézier edit preview rejected: $error\n$stack');
    }
  }

  Future<void> cancelCandidate() async {
    final candidate = _candidate;
    _candidate = null;
    if (candidate != null && candidate.token > 0) {
      try {
        await host.engine().cancelVectorCandidate(token: candidate.token);
      } catch (error, stack) {
        debugPrint(
          'Project Ink vector candidate cancel failed: $error\\n$stack',
        );
      }
    }
    if (host.mounted()) host.onStrokesChanged();
  }

  Widget _boundedNumberField(String label, TextEditingController controller) =>
      TextField(
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: false),
        decoration: InputDecoration(labelText: label),
      );
}
