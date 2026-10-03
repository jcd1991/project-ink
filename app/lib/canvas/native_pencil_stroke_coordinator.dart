import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../bridge/engine_api.dart';
import 'canvas_diagnostic_recorder.dart';
import 'live_preview_controller.dart';
import 'native_pencil_packet_metrics.dart';
import 'native_pointer_stream.dart';
import 'performance_trace.dart';
import 'pointer_packet.dart';

/// Screen-owned state and operations required by the native Pencil stroke
/// coordinator.
class NativePencilStrokeHost {
  const NativePencilStrokeHost({
    required this.engine,
    required this.strokeActive,
    required this.setStrokeActive,
    required this.captureEndedAtBoundary,
    required this.setCaptureEndedAtBoundary,
    required this.beginBrushStroke,
    required this.abortStroke,
    required this.eraserEnabled,
    required this.stylusLastPosition,
    required this.armDrawAndHold,
    required this.livePreviewSurface,
    required this.markDirty,
    required this.onStrokeFinished,
    required this.diagnostics,
    required this.performanceTrace,
    required this.performanceSnapshotsEnabled,
  });

  final EngineApi Function() engine;
  final bool Function() strokeActive;
  final ValueChanged<bool> setStrokeActive;
  final bool Function() captureEndedAtBoundary;
  final ValueChanged<bool> setCaptureEndedAtBoundary;
  final Future<bool> Function() beginBrushStroke;
  final Future<void> Function({bool preservePreview}) abortStroke;
  final bool Function() eraserEnabled;
  final Offset? Function() stylusLastPosition;
  final ValueChanged<Offset> armDrawAndHold;
  final LivePreviewController? Function() livePreviewSurface;
  final void Function({bool restartTimer}) markDirty;
  final void Function({
    required bool cancelled,
    required bool boundaryEnded,
    required String reason,
  })
  onStrokeFinished;
  final CanvasDiagnosticRecorder diagnostics;
  final Phase1PerformanceTrace performanceTrace;
  final bool performanceSnapshotsEnabled;
}

/// Owns the serialized native Pencil packet-to-Rust stroke workflow.
///
/// The screen still owns shared canvas presentation state and provides its
/// lifecycle callbacks through [NativePencilStrokeHost].
class NativePencilStrokeCoordinator {
  NativePencilStrokeCoordinator(this.host);

  final NativePencilStrokeHost host;
  final NativePencilPacketMetrics _metrics = NativePencilPacketMetrics();

  void clearPageContact() => _metrics.clearPageContact();

  Future<void> handlePacket(Uint8List packet) async {
    final engine = host.engine();
    final diagnostics = host.diagnostics;
    final hasDown = packetHasPhase(packet, InkPointerPhase.down);
    final hasUp = packetHasPhase(packet, InkPointerPhase.up);
    final hasCancel = packetHasPhase(packet, InkPointerPhase.cancel);

    // A missing release may leave a stale transaction open when the next
    // native contact starts. Recover before opening its new transaction.
    if (hasDown && host.strokeActive()) {
      await host.abortStroke(preservePreview: true);
    }
    if (hasDown && !host.strokeActive()) {
      if (!await host.beginBrushStroke()) return;
      host.setStrokeActive(true);
      host.setCaptureEndedAtBoundary(false);
      _metrics.beginStroke();
      debugPrint('Project Ink Pencil diagnostic: stroke began');
      host.markDirty();
    }
    if (!host.strokeActive()) {
      if (hasUp || hasCancel) {
        diagnostics.record('input.native_terminal_ignored', {
          'terminalPhase': hasCancel ? 'cancel' : 'up',
          'reason': 'no_active_stroke',
        });
      }
      return;
    }

    final observation = _metrics.observePacket(
      packet,
      captureAlreadyEnded: host.captureEndedAtBoundary(),
      isInsideDocument: (position) {
        final size = engine.documentInfo;
        return position.dx >= 0 &&
            position.dy >= 0 &&
            position.dx < size.widthPx &&
            position.dy < size.heightPx;
      },
    );
    if (host.captureEndedAtBoundary()) {
      if (hasUp || hasCancel) {
        _logTerminal(hasCancel: hasCancel, edgeExit: true, includeEvent: false);
        await _finishBoundaryStroke(engine: engine, cancelled: hasCancel);
      }
      return;
    }

    final crossingSampleCount = observation.crossingSampleCount ?? 0;
    final crossingPosition = observation.crossingPosition;
    if (crossingPosition != null) {
      host.setCaptureEndedAtBoundary(true);
      debugPrint(
        'Project Ink Pencil diagnostic: canvas edge exit after '
        '${_metrics.packetCount} packets / ${_metrics.sampleCount} samples at '
        '(${crossingPosition.dx.toStringAsFixed(1)}, '
        '${crossingPosition.dy.toStringAsFixed(1)}); packet will be clipped',
      );
    }
    if (!hasUp && !hasCancel) {
      final position = host.stylusLastPosition();
      if (position != null) host.armDrawAndHold(position);
    }

    final boundedPacket =
        crossingSampleCount == 0
            ? packet
            : truncatePointerPacket(packet, crossingSampleCount);
    final rasterPacket =
        host.eraserEnabled()
            ? addPointerPacketFlags(boundedPacket, inkPointerEraser)
            : boundedPacket;
    diagnostics.recordPacket(
      'input.engine_packet',
      'native_pencil_after_transform_clip_and_flags',
      rasterPacket,
      fields: <String, Object?>{
        'strokeActive': host.strokeActive(),
        'captureEndedAtBoundary': host.captureEndedAtBoundary(),
      },
    );
    try {
      await engine.pushPointerPacket(rasterPacket);
      host.livePreviewSurface()?.pump();
    } catch (error, stack) {
      if (host.performanceSnapshotsEnabled) {
        host.performanceTrace.markPacketRejected(rasterPacket);
      }
      diagnostics.recordError('native_pointer_engine_push', error, stack);
      debugPrint('Project Ink pointer packet rejected: $error\n$stack');
      await host.abortStroke();
      return;
    }
    host.markDirty(restartTimer: false);
    if (!hasUp && !hasCancel) return;

    _logTerminal(hasCancel: hasCancel, edgeExit: host.captureEndedAtBoundary());
    if (hasCancel) {
      diagnostics.record('canvas.stroke_cancelled', {
        'source': 'native_pencil',
        'engineRevision': engine.revision,
      });
      await engine.cancelStroke();
      unawaited(host.livePreviewSurface()?.cancelAllStrokes());
    } else {
      await engine.endStroke();
      diagnostics.record('canvas.stroke_committed', {
        'source': 'native_pencil',
        'engineRevision': engine.revision,
        'previewAwaitingCpuCommit': true,
      });
      host.markDirty();
    }
    host.onStrokeFinished(
      cancelled: hasCancel,
      boundaryEnded: false,
      reason: hasCancel ? 'pencil_cancel' : 'pencil_up',
    );
  }

  Future<void> _finishBoundaryStroke({
    required EngineApi engine,
    required bool cancelled,
  }) async {
    if (cancelled) {
      await engine.cancelStroke();
      unawaited(host.livePreviewSurface()?.cancelAllStrokes());
    } else {
      await engine.endStroke();
      host.markDirty();
    }
    host.onStrokeFinished(
      cancelled: cancelled,
      boundaryEnded: true,
      reason: cancelled ? 'pencil_boundary_cancel' : 'pencil_boundary_up',
    );
  }

  void _logTerminal({
    required bool hasCancel,
    required bool edgeExit,
    bool includeEvent = true,
  }) {
    debugPrint(
      'Project Ink Pencil diagnostic: ${hasCancel ? 'cancel' : 'up'} '
      'after ${_metrics.packetCount} packets / ${_metrics.sampleCount} samples; '
      'pressure=${_metrics.minPressure.toStringAsFixed(3)}..'
      '${_metrics.maxPressure.toStringAsFixed(3)}; edgeExit=$edgeExit',
    );
    if (includeEvent) {
      host.diagnostics.record('input.stroke_end', {
        'source': 'native_pencil',
        'terminalPhase': hasCancel ? 'cancel' : 'up',
        'packets': _metrics.packetCount,
        'samples': _metrics.sampleCount,
        'pressureMin': _metrics.minPressure,
        'pressureMax': _metrics.maxPressure,
        'edgeExit': edgeExit,
      });
    }
  }
}
