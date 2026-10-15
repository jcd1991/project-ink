import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/editor_action.dart';
import '../bridge/engine_api.dart';
import '../tools/illustration_tools.dart';
import 'canvas_tool_actions.dart';
import 'canvas_vector_actions.dart';

enum SelectionEdit { invert, grow, shrink }

@immutable
class CanvasRulerState {
  const CanvasRulerState({this.start, this.end, this.tool});

  final Offset? start;
  final Offset? end;
  final IllustrationTool? tool;
}

/// Screen-owned state and services required by pointer-driven tool workflows.
class CanvasToolEventHost {
  const CanvasToolEventHost({
    required this.engine,
    required this.mounted,
    required this.updateState,
    required this.activeTool,
    required this.canvasPosition,
    required this.pointerPressure,
    required this.setSelectionGeometry,
    required this.setSelectionGeometryTool,
    required this.vectorOperations,
    required this.vectorSelectionTolerance,
    this.vectorSelectionAdditive,
    required this.toolActions,
    required this.markDirty,
    required this.onSelectionCleared,
    this.panelToolEvent,
  });

  final EngineApi Function() engine;
  final bool Function() mounted;
  final void Function(VoidCallback update) updateState;
  final IllustrationTool Function() activeTool;
  final Offset Function(Offset localPosition) canvasPosition;
  final double Function(PointerEvent event) pointerPressure;
  final ValueChanged<Rect?> setSelectionGeometry;
  final ValueChanged<IllustrationTool?> setSelectionGeometryTool;
  final CanvasVectorToolOperations vectorOperations;
  final double Function() vectorSelectionTolerance;
  final bool Function()? vectorSelectionAdditive;
  final CanvasToolActions toolActions;
  final void Function({bool restartTimer}) markDirty;
  final VoidCallback onSelectionCleared;
  final Future<void> Function(PointerEvent event, Offset documentPosition)?
  panelToolEvent;
}

/// Owns pointer sampling and command dispatch for non-brush canvas tools.
class CanvasToolEventCoordinator {
  CanvasToolEventCoordinator(this.host);

  final CanvasToolEventHost host;
  Offset? _toolStart;
  int? _targetLayerId;
  List<Offset> _toolPoints = const [];
  List<double> _vectorPoints = const [];
  CanvasRulerState _ruler = const CanvasRulerState();
  bool _vectorTransformWasSelected = false;
  Future<bool>? _vectorSelectionFuture;
  int _vectorGestureGeneration = 0;
  CanvasVectorHandleTarget? _vectorPathHandleTarget;

  EngineApi get engine => host.engine();
  List<Offset> get previewPoints => _toolPoints;
  CanvasRulerState get ruler => _ruler;

  void _setRuler({
    required Offset? start,
    required Offset? end,
    required IllustrationTool? tool,
  }) {
    _ruler = CanvasRulerState(start: start, end: end, tool: tool);
  }

  void _setRulerEnd(Offset end) {
    _ruler = CanvasRulerState(start: _ruler.start, end: end, tool: _ruler.tool);
  }

  /// Clears transient pointer-path state when the tool or engine changes.
  void resetTransientState() {
    _vectorGestureGeneration++;
    host.vectorOperations.cancelPendingVectorSelection();
    host.vectorOperations.cancelVectorTransformPreview();
    _vectorSelectionFuture = null;
    _vectorPathHandleTarget = null;
    _toolStart = null;
    _targetLayerId = null;
    _toolPoints = const [];
    _vectorPoints = const [];
    _vectorTransformWasSelected = false;
  }

  /// Routes selection commands to the selection workflows owned here.
  bool dispatchEditorAction(EditorActionId action) {
    switch (action) {
      case EditorActionId.clearSelection:
        unawaited(clearSelection());
        return true;
      case EditorActionId.invertSelection:
        unawaited(modifySelection(SelectionEdit.invert));
        return true;
      case EditorActionId.growSelection:
        unawaited(modifySelection(SelectionEdit.grow));
        return true;
      case EditorActionId.shrinkSelection:
        unawaited(modifySelection(SelectionEdit.shrink));
        return true;
      default:
        return false;
    }
  }

  Future<void> handleSafely(PointerEvent event) async {
    try {
      await handleEvent(event);
    } catch (error, stack) {
      debugPrint('Project Ink tool event rejected: $error\n$stack');
      if (host.mounted()) {
        host.updateState(() => _toolPoints = const []);
      }
    }
  }

  Future<void> handleEvent(PointerEvent event) async {
    if (event is PointerCancelEvent) {
      await host.panelToolEvent?.call(event, Offset.zero);
      resetTransientState();
      if (host.mounted()) {
        host.updateState(() {
          host.setSelectionGeometry(null);
          host.setSelectionGeometryTool(null);
        });
      }
      return;
    }
    final isDown = event is PointerDownEvent;
    final isUp = event is PointerUpEvent;
    final position = host.canvasPosition(event.localPosition);
    final activeTool = host.activeTool();
    if (activeTool == IllustrationTool.panel) {
      await host.panelToolEvent?.call(event, position);
      return;
    }
    final isRuler = activeTool.name.endsWith('Ruler');
    final isPerspectiveTransform =
        activeTool == IllustrationTool.perspectiveTransform;
    final isMeshTransform = activeTool == IllustrationTool.meshTransform;
    final isLiquify = activeTool == IllustrationTool.liquify;
    final isVectorPen = activeTool == IllustrationTool.vectorPen;
    final isVectorTransform = activeTool == IllustrationTool.vectorTransform;
    final isVectorEraser = activeTool == IllustrationTool.vectorEraser;

    if (isVectorTransform && isDown) {
      final gestureGeneration = ++_vectorGestureGeneration;
      host.vectorOperations.cancelPendingVectorSelection();
      host.vectorOperations.cancelVectorTransformPreview();
      final handleTarget = host.vectorOperations.hitTestSelectedPathHandle(
        position,
        host.vectorSelectionTolerance(),
      );
      if (handleTarget != null) {
        _vectorPathHandleTarget = handleTarget;
        _toolStart = position;
        _targetLayerId = null;
        _toolPoints = [position];
        if (host.mounted()) host.updateState(() {});
        return;
      }
      _vectorTransformWasSelected = false;
      _vectorPathHandleTarget = null;
      final selectionFuture = host.vectorOperations.selectVectorObjectAt(
        position,
        host.vectorSelectionTolerance(),
        additive:
            host.vectorSelectionAdditive?.call() ??
            HardwareKeyboard.instance.isShiftPressed,
      );
      _vectorSelectionFuture = selectionFuture;
      _toolStart = position;
      _targetLayerId = null;
      _toolPoints = [position];
      unawaited(
        selectionFuture.then((selected) {
          if (gestureGeneration != _vectorGestureGeneration ||
              _toolStart == null) {
            return;
          }
          _vectorTransformWasSelected = selected;
          final points = _toolPoints;
          if (selected && points.isNotEmpty) {
            final delta = points.last - position;
            if (delta.distance >= 0.5) {
              unawaited(host.vectorOperations.previewVectorTransform(delta));
            }
          }
        }),
      );
      if (host.mounted()) host.updateState(() {});
      return;
    }

    if (activeTool == IllustrationTool.layerOpacitySelect && isDown) {
      final layerId = host.toolActions.requireSelectedRasterLayer(
        action: 'select opacity from',
      );
      if (layerId == null) return;
      await engine.selectLayerOpacity(layerId: layerId, minimumAlpha: 1);
      if (host.mounted()) {
        host.updateState(() {
          host.setSelectionGeometry(null);
          host.setSelectionGeometryTool(host.activeTool());
        });
      }
      return;
    }
    if (activeTool == IllustrationTool.colorRangeSelect && isDown) {
      final layerId = host.toolActions.requireSelectedRasterLayer(
        action: 'select colors from',
      );
      if (layerId == null) return;
      await host.toolActions.chooseColorRange(layerId);
      return;
    }
    if (activeTool == IllustrationTool.fill && isDown) {
      final layerId = host.toolActions.requireSelectedRasterLayer(
        action: 'fill',
      );
      if (layerId == null) return;
      await host.toolActions.chooseFill(position, layerId);
      return;
    }

    if (isDown) {
      final layerEditTool = <IllustrationTool>{
        IllustrationTool.transform,
        IllustrationTool.perspectiveTransform,
        IllustrationTool.meshTransform,
        IllustrationTool.liquify,
      }.contains(activeTool);
      final targetLayerId =
          layerEditTool
              ? host.toolActions.requireSelectedRasterLayer(action: 'edit')
              : null;
      if (layerEditTool && targetLayerId == null) return;
      _targetLayerId = targetLayerId;
      _toolStart = position;
      _toolPoints = [position];
      _vectorPoints =
          isVectorPen
              ? <double>[
                position.dx,
                position.dy,
                host.pointerPressure(event),
                0.0,
              ]
              : const [];
      if (isRuler) {
        _setRuler(start: position, end: position, tool: activeTool);
      }
      if (host.mounted()) host.updateState(() {});
      return;
    }

    final startPosition = _toolStart;
    if (event is PointerMoveEvent && startPosition != null) {
      if (isRuler) {
        _setRulerEnd(position);
      } else if (activeTool == IllustrationTool.lassoSelect) {
        _toolPoints = [
          ..._toolPoints,
          position,
        ].take(1024).toList(growable: false);
      } else if (isPerspectiveTransform || isMeshTransform || isLiquify) {
        host.setSelectionGeometry(Rect.fromPoints(startPosition, position));
        host.setSelectionGeometryTool(activeTool);
      } else if ((isVectorPen || isVectorTransform || isVectorEraser) &&
          (_toolPoints.isEmpty ||
              (_toolPoints.last - position).distance >= 0.5)) {
        _toolPoints = [
          ..._toolPoints,
          position,
        ].take(8192).toList(growable: false);
        if (isVectorPen) {
          _vectorPoints = [
            ..._vectorPoints,
            position.dx,
            position.dy,
            host.pointerPressure(event),
            0.0,
          ].take(8192 * 4).toList(growable: false);
        } else if (isVectorTransform) {
          final handleTarget = _vectorPathHandleTarget;
          if (handleTarget != null) {
            unawaited(
              host.vectorOperations.previewPathHandleDrag(
                handleTarget,
                position - startPosition,
              ),
            );
          } else if (_vectorTransformWasSelected) {
            unawaited(
              host.vectorOperations.previewVectorTransform(
                position - startPosition,
              ),
            );
          }
        }
      }
      if (host.mounted()) host.updateState(() {});
      return;
    }

    if (!isUp || startPosition == null) return;
    final start = startPosition;
    final end = position;
    final targetLayerId = _targetLayerId;
    _toolStart = null;
    _targetLayerId = null;
    var shouldMarkDirty = true;
    if (activeTool == IllustrationTool.rectangleSelect) {
      final rect = Rect.fromPoints(start, end);
      await engine.selectRectangle(
        x0: rect.left,
        y0: rect.top,
        x1: rect.right,
        y1: rect.bottom,
      );
      host.setSelectionGeometry(rect);
      host.setSelectionGeometryTool(activeTool);
    } else if (activeTool == IllustrationTool.ellipseSelect) {
      final rect = Rect.fromPoints(start, end);
      await engine.selectEllipse(
        centerX: rect.center.dx,
        centerY: rect.center.dy,
        radiusX: rect.width / 2,
        radiusY: rect.height / 2,
      );
      host.setSelectionGeometry(rect);
      host.setSelectionGeometryTool(activeTool);
    } else if (activeTool == IllustrationTool.lassoSelect) {
      final points = [..._toolPoints, end];
      await engine.selectLasso(
        points.expand((point) => [point.dx, point.dy]).toList(growable: false),
      );
      host.setSelectionGeometry(null);
      host.setSelectionGeometryTool(activeTool);
    } else if (activeTool == IllustrationTool.transform) {
      final delta = end - start;
      if (targetLayerId != null && delta.distance >= 0.5) {
        await engine.transformLayer(
          layerId: targetLayerId,
          a: 1,
          b: 0,
          c: 0,
          d: 1,
          tx: delta.dx,
          ty: delta.dy,
        );
      }
    } else if (activeTool == IllustrationTool.perspectiveTransform) {
      final rect = Rect.fromPoints(start, end);
      if (targetLayerId != null && rect.width >= 2 && rect.height >= 2) {
        await engine.perspectiveLayer(
          layerId: targetLayerId,
          target: <double>[
            rect.left,
            rect.top,
            rect.right,
            rect.top,
            rect.right,
            rect.bottom,
            rect.left,
            rect.bottom,
          ],
        );
        host.setSelectionGeometry(rect);
        host.setSelectionGeometryTool(activeTool);
      }
    } else if (activeTool == IllustrationTool.meshTransform) {
      final rect = Rect.fromPoints(start, end);
      if (targetLayerId != null && rect.width >= 2 && rect.height >= 2) {
        await host.toolActions.chooseMeshTransform(rect, targetLayerId);
        host.setSelectionGeometry(rect);
        host.setSelectionGeometryTool(activeTool);
      }
    } else if (activeTool == IllustrationTool.liquify) {
      final delta = end - start;
      final radius = math.max(24.0, delta.distance);
      if (targetLayerId != null && delta.distance >= 1) {
        await host.toolActions.chooseLiquify(
          start,
          delta,
          radius,
          targetLayerId,
        );
        host.setSelectionGeometry(
          Rect.fromCircle(center: start, radius: radius),
        );
        host.setSelectionGeometryTool(activeTool);
      }
    } else if (isVectorPen) {
      await host.vectorOperations.addStroke(_vectorPoints);
      shouldMarkDirty = false;
    } else if (activeTool == IllustrationTool.vectorTransform) {
      final handleTarget = _vectorPathHandleTarget;
      _vectorPathHandleTarget = null;
      if (handleTarget != null) {
        if ((end - start).distance >= 0.5) {
          await host.vectorOperations.commitPathHandleDrag();
        } else {
          host.vectorOperations.cancelVectorTransformPreview();
        }
        shouldMarkDirty = false;
      } else {
        final selectionFuture = _vectorSelectionFuture;
        _vectorSelectionFuture = null;
        if (selectionFuture != null) {
          _vectorTransformWasSelected = await selectionFuture;
        }
        final delta = end - start;
        shouldMarkDirty = _vectorTransformWasSelected && delta.distance >= 0.5;
        if (shouldMarkDirty) {
          await host.vectorOperations.transformFirstStroke(delta);
        } else {
          host.vectorOperations.cancelVectorTransformPreview();
        }
        shouldMarkDirty = false;
      }
    } else if (activeTool == IllustrationTool.vectorEraser) {
      final radius = math.max(4.0, (end - start).distance);
      await host.vectorOperations.eraseFirstStroke(center: end, radius: radius);
      shouldMarkDirty = false;
    } else if (isRuler) {
      _setRuler(start: start, end: end, tool: activeTool);
    }
    _toolPoints = const [];
    _vectorPoints = const [];
    _vectorTransformWasSelected = false;
    if (shouldMarkDirty) host.markDirty(restartTimer: false);
    if (host.mounted()) host.updateState(() {});
  }

  Future<void> clearSelection() async {
    try {
      await engine.clearSelection();
      resetTransientState();
      if (host.mounted()) host.onSelectionCleared();
    } catch (error, stack) {
      debugPrint('Project Ink selection clear failed: $error\n$stack');
    }
  }

  Future<void> modifySelection(SelectionEdit edit) async {
    try {
      switch (edit) {
        case SelectionEdit.invert:
          await engine.invertSelection();
        case SelectionEdit.grow:
          await engine.growSelection(1);
        case SelectionEdit.shrink:
          await engine.shrinkSelection(1);
      }
      if (host.mounted()) host.updateState(() {});
    } catch (error, stack) {
      debugPrint('Project Ink selection update failed: $error\n$stack');
    }
  }
}
