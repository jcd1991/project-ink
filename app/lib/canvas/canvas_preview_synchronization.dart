import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../bridge/engine_api.dart';
import 'android_live_surface_controller.dart';
import 'canvas_diagnostic_recorder.dart';
import 'desktop_live_texture_adapter.dart';
import 'live_preview_controller.dart';
import 'live_stroke_coordinator.dart';
import 'mac_live_surface_controller.dart';
import 'performance_trace.dart';

/// The current Flutter viewport used to synchronize a native live surface.
///
/// The snapshot is requested after the next frame and again after queued
/// surface cleanup, so it always describes the current canvas layout.
class CanvasLiveViewport {
  const CanvasLiveViewport({
    required this.canvasKey,
    required this.devicePixelRatio,
    required this.pan,
    required this.scale,
    required this.rotation,
    required this.mirrored,
    required this.documentWidth,
    required this.documentHeight,
  });

  final GlobalKey canvasKey;
  final double devicePixelRatio;
  final Offset pan;
  final double scale;
  final double rotation;
  final bool mirrored;
  final int documentWidth;
  final int documentHeight;
}

/// Owns native live-preview surfaces and ephemeral preview picture lifetimes.
///
/// CanvasScreen supplies engine and viewport state at explicit boundaries;
/// this service owns controller creation, surface retirement, and preview
/// invalidation without sharing the screen's private State through a `part`.
class CanvasPreviewSynchronization {
  LivePreviewController? _surface;
  Future<void> _pendingSurfaceDisposal = Future<void>.value();
  bool _viewportSyncScheduled = false;
  bool _disposed = false;

  final ValueNotifier<LiveStrokePreview?> strokePreview =
      ValueNotifier<LiveStrokePreview?>(null);
  StrokeAcknowledgement? lastPublishedPreviewAcknowledgement;
  bool awaitingPreviewCommit = false;

  LivePreviewController? get surface => _surface;
  Future<void> get pendingSurfaceDisposal => _pendingSurfaceDisposal;

  void configureSurface({
    required EngineApi engine,
    required TargetPlatform? targetPlatform,
    required LivePreviewController Function(EngineApi engine)? factory,
    required CanvasDiagnosticRecorder diagnostics,
    required Phase1PerformanceTrace performanceTrace,
    required bool hasPerformanceSnapshot,
    required bool disableIpadDabRenderer,
  }) {
    if (_disposed) return;
    final platform = targetPlatform ?? defaultTargetPlatform;
    if (factory case final makeController?) {
      _attach(makeController(engine));
      return;
    }

    // iPad presents compiled brush dabs on the native GPU surface. The
    // incremental Flutter path is an approximate fallback; Rust CPU tiles
    // remain authoritative and replace matching GPU coverage after commit.
    final useDabTexturePreview =
        platform == TargetPlatform.macOS ||
        (platform == TargetPlatform.iOS && !disableIpadDabRenderer);
    if (useDabTexturePreview && engine is LiveRenderEngineApi) {
      _attach(
        MacLiveSurfaceController(
          engine: engine as LiveRenderEngineApi,
          onDiagnosticEvent: (type, fields) => diagnostics.record(type, fields),
          onTextureSubmission:
              hasPerformanceSnapshot
                  ? performanceTrace.markNativeTextureSubmission
                  : null,
        ),
      );
    } else if (platform == TargetPlatform.android &&
        engine is LiveDabSourceApi) {
      _attach(AndroidLiveSurfaceController(engine: engine as LiveDabSourceApi));
    } else if ((platform == TargetPlatform.windows ||
            platform == TargetPlatform.linux) &&
        engine is LiveDabSourceApi) {
      _attach(
        NativeLiveSurfaceController(
          engine: engine as LiveDabSourceApi,
          textureAdapter: DesktopLiveTextureAdapter(),
          platformName:
              platform == TargetPlatform.windows ? 'Windows' : 'Linux',
          maxSurfaceBytes: 64 * 1024 * 1024,
        ),
      );
    }
  }

  void _attach(LivePreviewController surface) {
    _surface = surface;
    surface.gpuFrameReady.addListener(_onFrameReadinessChanged);
  }

  Future<void> detachSurface() {
    final surface = _surface;
    _surface = null;
    if (surface == null) return _pendingSurfaceDisposal;
    surface.gpuFrameReady.removeListener(_onFrameReadinessChanged);
    final disposal = _pendingSurfaceDisposal
        .then((_) => surface.dispose())
        .catchError((Object error, StackTrace stack) {
          debugPrint('Project Ink live surface cleanup failed: $error\n$stack');
        });
    _pendingSurfaceDisposal = disposal;
    return disposal;
  }

  void setStrokePreview(LiveStrokePreview? next) {
    final previous = strokePreview.value;
    strokePreview.value = next;
    if (previous == null) return;
    final retained = <ui.Picture>{
      for (final chunk in next?.chunks ?? const <LiveStrokePreviewChunk>[])
        chunk.picture,
    };
    final disposed = <ui.Picture>{};
    for (final chunk in previous.chunks) {
      if (!retained.contains(chunk.picture) && disposed.add(chunk.picture)) {
        chunk.picture.dispose();
      }
    }
  }

  /// Resets CPU handoff state when the active engine changes.
  void resetStrokeCommitState() {
    lastPublishedPreviewAcknowledgement = null;
    awaitingPreviewCommit = false;
  }

  void _onFrameReadinessChanged() {
    final preview = strokePreview.value;
    if (preview != null) {
      setStrokePreview(preview.copyWith(revision: preview.revision + 1));
    }
  }

  void scheduleViewportSync({
    required bool Function() isActive,
    required CanvasLiveViewport Function() viewport,
  }) {
    final surface = _surface;
    if (surface == null || _viewportSyncScheduled || _disposed) return;
    _viewportSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _viewportSyncScheduled = false;
      if (!isActive() || _disposed || !identical(surface, _surface)) return;
      unawaited(_synchronizeViewport(surface, isActive, viewport));
    });
  }

  Future<void> _synchronizeViewport(
    LivePreviewController surface,
    bool Function() isActive,
    CanvasLiveViewport Function() viewport,
  ) async {
    await _pendingSurfaceDisposal;
    if (!isActive() || _disposed || !identical(surface, _surface)) return;
    final current = viewport();
    final renderObject = current.canvasKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return;
    surface.synchronizeViewport(
      viewportSize: renderObject.size,
      devicePixelRatio: current.devicePixelRatio,
      pan: current.pan,
      scale: current.scale,
      rotation: current.rotation,
      mirrored: current.mirrored,
      documentWidth: current.documentWidth,
      documentHeight: current.documentHeight,
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(detachSurface());
    setStrokePreview(null);
    resetStrokeCommitState();
    strokePreview.dispose();
  }
}
