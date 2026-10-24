import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../bridge/engine_api.dart';
import 'canvas_diagnostic_recorder.dart';
import 'live_preview_controller.dart';
import 'pointer_packet.dart';

/// Screen-owned state and operations used by Flutter pointer stroke handling.
class FlutterPointerStrokeHost {
  const FlutterPointerStrokeHost({
    required this.engine,
    required this.strokeActive,
    required this.setStrokeActive,
    required this.activeStrokeIsTouch,
    required this.setActiveStrokeIsTouch,
    required this.captureEndedAtBoundary,
    required this.setCaptureEndedAtBoundary,
    required this.beginBrushStroke,
    required this.abortStroke,
    required this.isInsideDocument,
    required this.isInsideViewport,
    required this.setStylusLastPosition,
    required this.armDrawAndHold,
    required this.cancelStylusHold,
    required this.markPreviewStoppedAtPageEdge,
    required this.eraserEnabled,
    required this.pointerPressure,
    required this.livePreviewSurface,
    required this.markDirty,
    required this.onPacketReceived,
    required this.onPacketRejected,
    required this.onStrokeFinished,
    required this.diagnostics,
  });

  final EngineApi Function() engine;
  final bool Function() strokeActive;
  final ValueChanged<bool> setStrokeActive;
  final bool Function() activeStrokeIsTouch;
  final ValueChanged<bool> setActiveStrokeIsTouch;
  final bool Function() captureEndedAtBoundary;
  final ValueChanged<bool> setCaptureEndedAtBoundary;
  final Future<bool> Function() beginBrushStroke;
  final Future<void> Function({bool preservePreview}) abortStroke;
  final bool Function(Offset position) isInsideDocument;
  final bool Function(Offset localPosition) isInsideViewport;
  final ValueChanged<Offset> setStylusLastPosition;
  final ValueChanged<Offset> armDrawAndHold;
  final VoidCallback cancelStylusHold;
  final VoidCallback markPreviewStoppedAtPageEdge;
  final bool Function() eraserEnabled;
  final double Function(PointerEvent event) pointerPressure;
  final LivePreviewController? Function() livePreviewSurface;
  final void Function({bool restartTimer}) markDirty;
  final void Function(Uint8List packet) onPacketReceived;
  final void Function(Uint8List packet) onPacketRejected;
  final void Function({
    required bool cancelled,
    required bool boundaryEnded,
    required String reason,
    required PointerDeviceKind pointerKind,
  })
  onStrokeFinished;
  final CanvasDiagnosticRecorder diagnostics;
}

/// Owns ordered Flutter pointer-to-Rust stroke delivery and terminal policy.
///
/// Preview construction and screen presentation remain with the canvas state.
class FlutterPointerStrokeCoordinator {
  FlutterPointerStrokeCoordinator(this.host);

  final FlutterPointerStrokeHost host;

  Future<void> handleEvent(
    PointerEvent event,
    int sourceSequence,
    Offset preparedPosition,
  ) async {
    final engine = host.engine();
    final isDown = event is PointerDownEvent;
    final isUp = event is PointerUpEvent || event is PointerCancelEvent;
    final isCancelled = event is PointerCancelEvent;

    if (event.kind == PointerDeviceKind.touch &&
        !(isDown && !host.strokeActive()) &&
        (!host.strokeActive() || !host.activeStrokeIsTouch())) {
      host.diagnostics.record('input.touch_packet_ignored', {
        'phase':
            isDown
                ? 'down'
                : isUp
                ? 'up_or_cancel'
                : 'move',
        'activeStroke': host.strokeActive(),
        'activeStrokeIsTouch': host.activeStrokeIsTouch(),
      });
      return;
    }

    // A fresh press recovers desktop strokes whose release was lost when the
    // pointer left the app window.
    if (isDown && host.strokeActive()) {
      await host.abortStroke();
    }
    if (isDown && !host.strokeActive()) {
      if (!await host.beginBrushStroke()) return;
      host.setStrokeActive(true);
      host.setActiveStrokeIsTouch(event.kind == PointerDeviceKind.touch);
      host.setCaptureEndedAtBoundary(false);
      host.markDirty();
    }
    if (!host.strokeActive()) return;

    final position = preparedPosition;
    final insideCanvas =
        host.isInsideDocument(position) &&
        host.isInsideViewport(event.localPosition);
    if (host.captureEndedAtBoundary() && !isDown && insideCanvas) {
      // Pointer capture may continue after leaving the artwork. Resume the
      // same transaction when it re-enters; Rust starts a separate path there.
      host.setCaptureEndedAtBoundary(false);
    }
    if (!isDown &&
        !host.isInsideViewport(event.localPosition) &&
        host.isInsideDocument(position)) {
      host.setCaptureEndedAtBoundary(true);
      host.markPreviewStoppedAtPageEdge();
      host.cancelStylusHold();
      // No off-window sample was sent to Rust. Resuming this transaction on
      // re-entry would interpolate directly from the last visible sample,
      // drawing a straight chord across the missing captured input.
      if (isCancelled) {
        await engine.cancelStroke();
        unawaited(host.livePreviewSurface()?.cancelAllStrokes());
      } else {
        await engine.endStroke();
        host.markDirty();
      }
      host.diagnostics.record('input.viewport_stroke_end', {
        'sourceSequence': sourceSequence,
        'pointerKind': event.kind.name,
        'cancelled': isCancelled,
      });
      host.onStrokeFinished(
        cancelled: isCancelled,
        boundaryEnded: true,
        reason: 'pointer_viewport_exit',
        pointerKind: event.kind,
      );
      return;
    }
    if (host.captureEndedAtBoundary() && !isDown) {
      if (!isUp) return;
      if (isCancelled) {
        await engine.cancelStroke();
        unawaited(host.livePreviewSurface()?.cancelAllStrokes());
      } else {
        await engine.endStroke();
        host.markDirty();
      }
      host.onStrokeFinished(
        cancelled: isCancelled,
        boundaryEnded: true,
        reason: isCancelled ? 'pointer_boundary_cancel' : 'pointer_boundary_up',
        pointerKind: event.kind,
      );
      return;
    }

    host.setStylusLastPosition(position);
    if ((isDown || event is PointerMoveEvent) &&
        event.kind != PointerDeviceKind.mouse &&
        event.kind != PointerDeviceKind.touch) {
      host.armDrawAndHold(position);
    }
    if (isUp) host.cancelStylusHold();

    final packet = Uint8List.fromList(
      encodePointerPacket(
        pointerId: event.pointer,
        device: switch (event.kind) {
          PointerDeviceKind.mouse => InkPointerDevice.mouse,
          PointerDeviceKind.touch => InkPointerDevice.touch,
          _ => InkPointerDevice.stylus,
        },
        phase:
            isDown
                ? InkPointerPhase.down
                : isUp
                ? (isCancelled ? InkPointerPhase.cancel : InkPointerPhase.up)
                : InkPointerPhase.move,
        x: position.dx,
        y: position.dy,
        pressure: host.pointerPressure(event),
        timestampNs: event.timeStamp.inMicroseconds * 1000,
        sequence: sourceSequence,
        tiltX: event.tilt,
        azimuth: event.orientation,
        flags: inkPointerActual | (host.eraserEnabled() ? inkPointerEraser : 0),
      ),
    );
    host.diagnostics.recordPacket(
      'input.engine_packet',
      'flutter_pointer_after_transform',
      packet,
      fields: <String, Object?>{
        'pointerKind': event.kind.name,
        'phase':
            isDown
                ? 'down'
                : isUp
                ? (isCancelled ? 'cancel' : 'up')
                : 'move',
      },
    );
    host.onPacketReceived(packet);
    try {
      await engine.pushPointerPacket(packet);
      host.livePreviewSurface()?.pump();
      if (!isDown &&
          (!host.isInsideDocument(position) ||
              !host.isInsideViewport(event.localPosition))) {
        host.setCaptureEndedAtBoundary(true);
      }
    } catch (error, stack) {
      host.onPacketRejected(packet);
      host.diagnostics.recordError('flutter_pointer_engine_push', error, stack);
      debugPrint('Project Ink pointer packet rejected: $error\n$stack');
      await host.abortStroke();
      return;
    }
    host.markDirty(restartTimer: false);
    if (!isUp) return;

    if (isCancelled) {
      host.diagnostics.record('input.stroke_end', {
        'source': 'flutter_pointer',
        'terminalPhase': 'cancel',
        'pointerKind': event.kind.name,
        'engineRevision': engine.revision,
      });
      await engine.cancelStroke();
      unawaited(host.livePreviewSurface()?.cancelAllStrokes());
    } else {
      await engine.endStroke();
      host.diagnostics.record('input.stroke_end', {
        'source': 'flutter_pointer',
        'terminalPhase': 'up',
        'pointerKind': event.kind.name,
        'engineRevision': engine.revision,
      });
      host.markDirty();
    }
    host.onStrokeFinished(
      cancelled: isCancelled,
      boundaryEnded: false,
      reason: isCancelled ? 'pointer_cancel' : 'pointer_up',
      pointerKind: event.kind,
    );
  }
}
