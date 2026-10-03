import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:project_ink/canvas/canvas_live_preview_frame_diagnostics.dart';
import 'package:project_ink/canvas/performance_trace.dart';

void main() {
  testWidgets('coalesces diagnostics and samples the visible frame once', (
    tester,
  ) async {
    final events = <String>[];
    final trace = Phase1PerformanceTrace();
    var callbackCount = 0;
    var snapshotCount = 0;
    var disposed = false;
    final diagnostics = CanvasLivePreviewFrameDiagnostics(
      isMounted: () => true,
      isDisposed: () => disposed,
      snapshot: () {
        snapshotCount++;
        return const CanvasLivePreviewFrameSnapshot(
          pointCount: 4,
          confirmedThrough: 1,
          pendingSourceSequenceStart: 8,
          pendingSourceSequenceEnd: 10,
          previewRevision: 3,
          pendingPreviewChunkCount: 2,
          oldestPendingPreviewChunkAgeUs: 8000,
          unbuiltPreviewPointCount: 1,
          strokeWorkQueueDepth: 1,
          nativePacketQueueDepth: 0,
          autosaveDeferredForStroke: true,
          nativeTextureEnabled: true,
          nativeTextureReady: false,
          packetMicros: 10,
        );
      },
      record: (event, fields) => events.add(event),
      performanceTrace: trace,
      performanceSnapshotCallback: () => (_) => callbackCount++,
    );

    diagnostics.schedule();
    diagnostics.schedule();
    await tester.pumpWidget(const SizedBox());

    expect(snapshotCount, 1);
    expect(events, ['canvas.live_preview_frame']);
    expect(callbackCount, 1);
    expect(trace.snapshot().visibleUpdateCount, 1);
    diagnostics.dispose();
  });

  testWidgets('does not capture after disposal', (tester) async {
    var snapshots = 0;
    final diagnostics = CanvasLivePreviewFrameDiagnostics(
      isMounted: () => true,
      isDisposed: () => false,
      snapshot: () {
        snapshots++;
        return null;
      },
      record: (_, _) {},
      performanceTrace: Phase1PerformanceTrace(),
      performanceSnapshotCallback: () => null,
    );

    diagnostics.schedule();
    diagnostics.dispose();
    await tester.pumpWidget(const SizedBox());

    expect(snapshots, 0);
  });
}
