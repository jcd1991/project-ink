import 'package:flutter/widgets.dart';

import 'live_preview_controller.dart';

/// Explicit state and effects used while routing confirmed input to the
/// ephemeral Flutter preview and optional native live surface.
class CanvasLiveStrokePreviewInputHost {
  const CanvasLiveStrokePreviewInputHost({
    required this.livePreviewSurface,
    required this.strokeActive,
    required this.beginPreview,
    required this.appendPreview,
    required this.recordDiagnostic,
  });

  final LivePreviewController? Function() livePreviewSurface;
  final bool Function() strokeActive;
  final int Function(Offset position, double pressure, int sourceSequence)
  beginPreview;
  final int Function(
    Offset position,
    double pressure,
    int sourceSequence,
    bool isUp,
  )
  appendPreview;
  final void Function(String event, Map<String, Object?> fields)
  recordDiagnostic;
}

/// Owns input-pending signaling order and routes stroke starts versus samples.
/// Preview point ordering itself remains with the stroke preview actions owner.
class CanvasLiveStrokePreviewInput {
  const CanvasLiveStrokePreviewInput(this.host);

  final CanvasLiveStrokePreviewInputHost host;

  int update(
    Offset position, {
    required bool isDown,
    required bool isUp,
    required double pressure,
    required int sourceSequence,
  }) {
    if (isDown) prepareStrokeStart(markInputPending: false);
    final surface = host.livePreviewSurface();
    if (isDown || host.strokeActive()) {
      surface?.markInputPending(strokeStart: isDown);
    }
    if (isDown) return host.beginPreview(position, pressure, sourceSequence);
    return host.appendPreview(position, pressure, sourceSequence, isUp);
  }

  void prepareStrokeStart({bool markInputPending = true}) {
    final surface = host.livePreviewSurface();
    host.recordDiagnostic('gpu.preview_input_state', {
      'controllerAttached': surface != null,
      'textureAvailable': surface?.textureId.value != null,
      'gpuFrameReady': surface?.gpuFrameReady.value ?? false,
    });
    if (markInputPending) surface?.markInputPending(strokeStart: true);
  }
}
