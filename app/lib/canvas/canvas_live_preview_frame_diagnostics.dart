import 'package:flutter/widgets.dart';

import 'performance_trace.dart';

/// Immutable live-preview values captured when the next Flutter frame paints.
@immutable
class CanvasLivePreviewFrameSnapshot {
  const CanvasLivePreviewFrameSnapshot({
    required this.pointCount,
    required this.confirmedThrough,
    required this.pendingSourceSequenceStart,
    required this.pendingSourceSequenceEnd,
    required this.previewRevision,
    required this.pendingPreviewChunkCount,
    required this.oldestPendingPreviewChunkAgeUs,
    required this.unbuiltPreviewPointCount,
    required this.strokeWorkQueueDepth,
    required this.nativePacketQueueDepth,
    required this.autosaveDeferredForStroke,
    required this.nativeTextureEnabled,
    required this.nativeTextureReady,
    required this.packetMicros,
  });

  final int pointCount;
  final int confirmedThrough;
  final int? pendingSourceSequenceStart;
  final int? pendingSourceSequenceEnd;
  final int previewRevision;
  final int pendingPreviewChunkCount;
  final int? oldestPendingPreviewChunkAgeUs;
  final int unbuiltPreviewPointCount;
  final int strokeWorkQueueDepth;
  final int nativePacketQueueDepth;
  final bool autosaveDeferredForStroke;
  final bool nativeTextureEnabled;
  final bool nativeTextureReady;
  final int? packetMicros;

  Map<String, Object?> toDiagnosticFields() => <String, Object?>{
    'pointCount': pointCount,
    'confirmedThrough': confirmedThrough,
    'pendingPointCount': pointCount - confirmedThrough,
    'pendingSourceSequenceStart': pendingSourceSequenceStart,
    'pendingSourceSequenceEnd': pendingSourceSequenceEnd,
    'visiblePreviewIndexStart': confirmedThrough.clamp(0, pointCount).toInt(),
    'visiblePreviewIndexEnd': pointCount == 0 ? null : pointCount - 1,
    'previewRevision': previewRevision,
    'pendingPreviewChunkCount': pendingPreviewChunkCount,
    'oldestPendingPreviewChunkAgeUs': oldestPendingPreviewChunkAgeUs,
    'unbuiltPreviewPointCount': unbuiltPreviewPointCount,
    'strokeWorkQueueDepth': strokeWorkQueueDepth,
    'nativePacketQueueDepth': nativePacketQueueDepth,
    'autosaveDeferredForStroke': autosaveDeferredForStroke,
    'nativeTextureEnabled': nativeTextureEnabled,
    'nativeTextureReady': nativeTextureReady,
    'renderer': 'flutter_canvas',
  };
}

/// Coalesces live-preview diagnostics to one sample per Flutter frame.
class CanvasLivePreviewFrameDiagnostics {
  CanvasLivePreviewFrameDiagnostics({
    required this.isMounted,
    required this.isDisposed,
    required this.snapshot,
    required this.record,
    required this.performanceTrace,
    required this.performanceSnapshotCallback,
  });

  final bool Function() isMounted;
  final bool Function() isDisposed;
  final CanvasLivePreviewFrameSnapshot? Function() snapshot;
  final void Function(String event, Map<String, Object?> fields) record;
  final Phase1PerformanceTrace performanceTrace;
  final ValueChanged<Phase1PerformanceSnapshot>? Function()
  performanceSnapshotCallback;

  bool _scheduled = false;
  bool _disposed = false;

  void schedule() {
    if (_scheduled || _disposed || isDisposed()) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (_disposed || !isMounted() || isDisposed()) return;
      final frame = snapshot();
      if (frame == null) return;

      record('canvas.live_preview_frame', frame.toDiagnosticFields());
      if (frame.packetMicros case final packetMicros?
          when performanceSnapshotCallback() != null) {
        final latencyMicros = performanceTrace.markLivePreviewFramePresented(
          packetMicros: packetMicros,
        );
        record('canvas.pointer_to_visible_sample', <String, Object?>{
          'path': 'live_preview_frame',
          'packetToVisibleUs': latencyMicros,
          'previewRevision': frame.previewRevision,
          'visiblePreviewIndexEnd':
              frame.pointCount == 0 ? null : frame.pointCount - 1,
          'pointCount': frame.pointCount,
        });
        performanceSnapshotCallback()?.call(performanceTrace.snapshot());
      }
    });
  }

  void dispose() {
    _disposed = true;
  }
}
