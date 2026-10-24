import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../tools/illustration_tools.dart';
import 'canvas_diagnostic_recorder.dart';

typedef CanvasPreviewInputUpdate =
    int Function(
      Offset position, {
      required bool isDown,
      required bool isUp,
      required double pressure,
      required int sourceSequence,
    });

/// Screen state and operations used by [CanvasPointerEventRouter].
class CanvasPointerEventRouterHost {
  const CanvasPointerEventRouterHost({
    required this.documentReplacementActive,
    required this.nativePencilContactActive,
    required this.recordTouchGesture,
    required this.touchGestureCounts,
    required this.activeTool,
    required this.colorSamplerArmed,
    required this.disarmColorSampler,
    required this.sampleCanvasColor,
    required this.handleToolEvent,
    required this.nativePointerEnabled,
    required this.strokeActive,
    required this.activeStrokeIsTouch,
    required this.singleFingerNavigation,
    required this.touchDrawingStrokeActive,
    required this.setTouchDrawingStrokeActive,
    required this.cancelTouchDrawingStroke,
    required this.beginStrokeAutosaveHold,
    required this.recordInputArrival,
    required this.nextPointerSequence,
    required this.prepareDrawingPosition,
    required this.isInsideViewport,
    required this.isInsideDocument,
    required this.updatePreview,
    required this.pointerPressure,
    required this.schedulePreviewFrameDiagnostic,
    required this.enqueueStrokeWork,
    required this.handleDrawingEvent,
    required this.previewPerformanceTimingEnabled,
    required this.nowMicros,
    required this.markPreviewUpdated,
    required this.diagnostics,
  });

  final bool Function() documentReplacementActive;
  final bool Function() nativePencilContactActive;
  final void Function(PointerEvent event) recordTouchGesture;
  final ({int active, int tracked}) Function() touchGestureCounts;
  final IllustrationTool Function() activeTool;
  final bool Function() colorSamplerArmed;
  final void Function() disarmColorSampler;
  final Future<void> Function(Offset position) sampleCanvasColor;
  final Future<void> Function(PointerEvent event) handleToolEvent;
  final bool Function() nativePointerEnabled;
  final bool Function() strokeActive;
  final bool Function() activeStrokeIsTouch;
  final bool Function() singleFingerNavigation;
  final bool Function() touchDrawingStrokeActive;
  final ValueChanged<bool> setTouchDrawingStrokeActive;
  final void Function({required String reason}) cancelTouchDrawingStroke;
  final VoidCallback beginStrokeAutosaveHold;
  final VoidCallback recordInputArrival;
  final int Function() nextPointerSequence;
  final Offset Function(PointerEvent event) prepareDrawingPosition;
  final bool Function(Offset position) isInsideViewport;
  final bool Function(Offset position) isInsideDocument;
  final CanvasPreviewInputUpdate updatePreview;
  final double Function(PointerEvent event) pointerPressure;
  final VoidCallback schedulePreviewFrameDiagnostic;
  final void Function(Future<void> Function() operation) enqueueStrokeWork;
  final Future<void> Function(
    PointerEvent event,
    int sourceSequence,
    Offset preparedPosition,
  )
  handleDrawingEvent;
  final bool Function() previewPerformanceTimingEnabled;
  final int Function() nowMicros;
  final void Function({required int startedMicros}) markPreviewUpdated;
  final CanvasDiagnosticRecorder diagnostics;
}

/// Routes Flutter pointer events while keeping live preview synchronous.
/// Native and Flutter stroke delivery still converge on the screen's ordered
/// bridge queue and the established stroke coordinator.
class CanvasPointerEventRouter {
  CanvasPointerEventRouter(this.host);

  final CanvasPointerEventRouterHost host;
  final Set<int> _trackedPointers = <int>{};
  final Set<int> _viewportEndedPointers = <int>{};

  int get trackedPointerCount => _trackedPointers.length;

  void forgetPointers(Iterable<int> pointers) {
    _trackedPointers.removeAll(pointers);
    _viewportEndedPointers.removeAll(pointers);
  }

  void clearPointers() {
    _trackedPointers.clear();
    _viewportEndedPointers.clear();
  }

  void handle(PointerEvent event) {
    final packetArrivalUs =
        host.diagnostics.isRecording
            ? host.diagnostics.elapsedMicroseconds
            : null;
    if (event.kind == PointerDeviceKind.touch &&
        (event is PointerDownEvent ||
            event is PointerUpEvent ||
            event is PointerCancelEvent)) {
      final touchCounts = host.touchGestureCounts();
      host.diagnostics.record('input.flutter_touch_boundary', {
        'pointerId': event.pointer,
        'phase':
            event is PointerDownEvent
                ? 'down'
                : event is PointerUpEvent
                ? 'up'
                : 'cancel',
        'strokeActive': host.strokeActive(),
        'activeStrokeIsTouch': host.activeStrokeIsTouch(),
        'touchPreviewActive': host.touchDrawingStrokeActive(),
        'activeTouchPointerCount': touchCounts.active,
        'trackedTouchCount': touchCounts.tracked,
        'singleFingerNavigation': host.singleFingerNavigation(),
        'nativePencilContactActive': host.nativePencilContactActive(),
        'x': event.localPosition.dx,
        'y': event.localPosition.dy,
      });
    }
    if (host.documentReplacementActive()) return;
    if (event.kind == PointerDeviceKind.touch &&
        host.nativePencilContactActive()) {
      // UIKit reports Pencil and palm contacts together. Ignore finger input
      // during Pencil contact to prevent palm marks and accidental gestures.
      return;
    }
    if (event.kind == PointerDeviceKind.stylus ||
        event.kind == PointerDeviceKind.invertedStylus) {
      host.recordInputArrival();
    }
    _trackPointer(event);
    if (event.kind == PointerDeviceKind.touch) {
      host.recordTouchGesture(event);
    }
    if (host.colorSamplerArmed() &&
        event is PointerDownEvent &&
        _isSamplingPointer(event.kind)) {
      host.disarmColorSampler();
      unawaited(host.sampleCanvasColor(event.localPosition));
      return;
    }
    if (!_isDrawingTool(host.activeTool()) && _supportsToolInput(event.kind)) {
      host.enqueueStrokeWork(() => host.handleToolEvent(event));
      return;
    }
    if (event is PointerDownEvent && _startsAutosaveHeldStroke(event.kind)) {
      host.beginStrokeAutosaveHold();
    }
    if (event.kind == PointerDeviceKind.touch) {
      _handleTouch(event, packetArrivalUs);
      return;
    }
    if (_usesGenericDrawingInput(event.kind)) {
      _handleGenericDrawing(event, packetArrivalUs);
    }
  }

  void _trackPointer(PointerEvent event) {
    if (event is PointerDownEvent || event is PointerMoveEvent) {
      _trackedPointers.add(event.pointer);
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _trackedPointers.remove(event.pointer);
    }
  }

  void _handleTouch(PointerEvent event, int? packetArrivalUs) {
    if (host.touchGestureCounts().tracked > 1) {
      host.cancelTouchDrawingStroke(reason: 'second_touch_during_stroke');
      return;
    }
    final canStartTouchStroke =
        event is PointerDownEvent &&
        !host.singleFingerNavigation() &&
        !host.strokeActive();
    if (!host.touchDrawingStrokeActive() && !canStartTouchStroke) return;
    if (canStartTouchStroke) {
      host.setTouchDrawingStrokeActive(true);
      host.beginStrokeAutosaveHold();
    }
    final sourceSequence = host.nextPointerSequence();
    final preparedPosition = host.prepareDrawingPosition(event);
    final previewIndex = _updateDrawingPreview(
      event,
      preparedPosition,
      isDown: event is PointerDownEvent,
      isUp: event is PointerUpEvent || event is PointerCancelEvent,
      pressure: host.pointerPressure(event),
      sourceSequence: sourceSequence,
    );
    _recordLiveInputAccepted(
      device: 'touch',
      previewIndex: previewIndex,
      sourceSequence: sourceSequence,
      packetArrivalUs: packetArrivalUs,
    );
    host.schedulePreviewFrameDiagnostic();
    host.enqueueStrokeWork(
      () => host.handleDrawingEvent(event, sourceSequence, preparedPosition),
    );
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      host.setTouchDrawingStrokeActive(false);
    }
  }

  void _handleGenericDrawing(PointerEvent event, int? packetArrivalUs) {
    final previewStarted =
        host.previewPerformanceTimingEnabled() ? host.nowMicros() : null;
    final sourceSequence = host.nextPointerSequence();
    final preparedPosition = host.prepareDrawingPosition(event);
    final previewIndex = _updateDrawingPreview(
      event,
      preparedPosition,
      isDown: event is PointerDownEvent,
      isUp: event is PointerUpEvent || event is PointerCancelEvent,
      pressure: host.pointerPressure(event),
      sourceSequence: sourceSequence,
    );
    _recordLiveInputAccepted(
      device: event.kind.name,
      previewIndex: previewIndex,
      sourceSequence: sourceSequence,
      packetArrivalUs: packetArrivalUs,
    );
    host.schedulePreviewFrameDiagnostic();
    if (previewStarted != null) {
      host.markPreviewUpdated(startedMicros: previewStarted);
    }
    host.enqueueStrokeWork(
      () => host.handleDrawingEvent(event, sourceSequence, preparedPosition),
    );
  }

  int _updateDrawingPreview(
    PointerEvent event,
    Offset position, {
    required bool isDown,
    required bool isUp,
    required double pressure,
    required int sourceSequence,
  }) {
    if (isDown) _viewportEndedPointers.remove(event.pointer);
    final outsideViewport = !host.isInsideViewport(event.localPosition);
    // The engine ends a captured stroke when the window cuts through the
    // document. Do not build a different preview path, or reconnect it on
    // re-entry while the original mouse button is still held.
    if (!isDown && outsideViewport && host.isInsideDocument(position)) {
      _viewportEndedPointers.add(event.pointer);
    }
    final ended = _viewportEndedPointers.contains(event.pointer);
    if (isUp) _viewportEndedPointers.remove(event.pointer);
    if (ended) return -1;
    return host.updatePreview(
      position,
      isDown: isDown,
      isUp: isUp,
      pressure: pressure,
      sourceSequence: sourceSequence,
    );
  }

  void _recordLiveInputAccepted({
    required String device,
    required int previewIndex,
    required int sourceSequence,
    required int? packetArrivalUs,
  }) {
    host.diagnostics.record('canvas.live_input_accepted', {
      'device': device,
      'confirmedSamples': 1,
      'confirmedPreviewIndexStart': previewIndex,
      'confirmedPreviewIndexEnd': previewIndex,
      'firstConfirmedSequence': sourceSequence,
      'lastConfirmedSequence': sourceSequence,
      'renderer': 'flutter_canvas',
      if (packetArrivalUs != null) 'packetArrivalUs': packetArrivalUs,
    });
  }

  bool _usesGenericDrawingInput(PointerDeviceKind kind) =>
      (!host.nativePointerEnabled() &&
          (kind == PointerDeviceKind.stylus ||
              kind == PointerDeviceKind.invertedStylus)) ||
      kind == PointerDeviceKind.mouse;

  bool _startsAutosaveHeldStroke(PointerDeviceKind kind) =>
      kind == PointerDeviceKind.stylus ||
      kind == PointerDeviceKind.invertedStylus ||
      kind == PointerDeviceKind.mouse;

  bool _isSamplingPointer(PointerDeviceKind kind) =>
      kind == PointerDeviceKind.mouse ||
      kind == PointerDeviceKind.stylus ||
      kind == PointerDeviceKind.invertedStylus;

  bool _supportsToolInput(PointerDeviceKind kind) =>
      kind == PointerDeviceKind.stylus ||
      kind == PointerDeviceKind.invertedStylus ||
      kind == PointerDeviceKind.mouse ||
      kind == PointerDeviceKind.touch;

  bool _isDrawingTool(IllustrationTool tool) =>
      tool == IllustrationTool.brush || tool == IllustrationTool.eraser;
}
