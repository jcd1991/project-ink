part of 'canvas_screen.dart';

/// Owns native preview lifecycle, viewport synchronization, and preview image
/// retirement while the canvas state coordinates editor composition.
mixin _CanvasPreviewSynchronization on State<CanvasScreen> {
  bool get _disposed;
  GlobalKey get _canvasKey;
  CanvasDiagnosticRecorder get _canvasDiagnostics;
  LivePreviewController? get _livePreviewSurface;
  set _livePreviewSurface(LivePreviewController? value);
  Future<void> get _pendingLiveSurfaceDisposal;
  set _pendingLiveSurfaceDisposal(Future<void> value);
  ValueNotifier<LiveStrokePreview?> get _strokePreview;
  Phase1PerformanceTrace get _performanceTrace;
  bool get _mirrorCanvas;
  Offset get _pan;
  double get _rotation;
  double get _scale;

  bool _liveViewportSyncScheduled = false;

  void _configureLivePreviewSurface() {
    final factory = widget.livePreviewControllerFactory;
    if (factory != null) {
      final controller = factory(widget.engine);
      controller.gpuFrameReady.addListener(_onLiveFrameReadinessChanged);
      _livePreviewSurface = controller;
      return;
    }
    final platform = widget.targetPlatform ?? defaultTargetPlatform;
    final engine = widget.engine;
    // iPad presents the compiled brush dabs on the native GPU surface. The
    // incremental Flutter path is an approximate fallback and should only be
    // shown in explicit comparison builds; Rust CPU tiles remain authoritative
    // and replace matching GPU coverage after commit.
    final useDabTexturePreview =
        platform == TargetPlatform.macOS ||
        (platform == TargetPlatform.iOS && !_disableIpadDabRenderer);
    if (useDabTexturePreview && engine is LiveRenderEngineApi) {
      final controller = MacLiveSurfaceController(
        engine: engine as LiveRenderEngineApi,
        onDiagnosticEvent:
            (type, fields) => _canvasDiagnostics.record(type, fields),
        onTextureSubmission:
            widget.onPerformanceSnapshot == null
                ? null
                : _performanceTrace.markNativeTextureSubmission,
      );
      controller.gpuFrameReady.addListener(_onLiveFrameReadinessChanged);
      _livePreviewSurface = controller;
    } else if (platform == TargetPlatform.android &&
        engine is LiveDabSourceApi) {
      final controller = AndroidLiveSurfaceController(
        engine: engine as LiveDabSourceApi,
      );
      controller.gpuFrameReady.addListener(_onLiveFrameReadinessChanged);
      _livePreviewSurface = controller;
    } else if ((platform == TargetPlatform.windows ||
            platform == TargetPlatform.linux) &&
        engine is LiveDabSourceApi) {
      final controller = NativeLiveSurfaceController(
        engine: engine as LiveDabSourceApi,
        textureAdapter: DesktopLiveTextureAdapter(),
        platformName: platform == TargetPlatform.windows ? 'Windows' : 'Linux',
        maxSurfaceBytes: 64 * 1024 * 1024,
      );
      controller.gpuFrameReady.addListener(_onLiveFrameReadinessChanged);
      _livePreviewSurface = controller;
    }
  }

  Future<void> _queueLiveSurfaceDisposal(LivePreviewController surface) {
    final disposal = _pendingLiveSurfaceDisposal
        .then((_) => surface.dispose())
        .catchError((Object error, StackTrace stack) {
          debugPrint('Project Ink live surface cleanup failed: $error\n$stack');
        });
    _pendingLiveSurfaceDisposal = disposal;
    return disposal;
  }

  void _onLiveFrameReadinessChanged() {
    final preview = _strokePreview.value;
    if (preview != null) {
      _setStrokePreview(preview.copyWith(revision: preview.revision + 1));
    }
  }

  /// Replaces the current ephemeral path and releases cached GPU pictures
  /// whose chunks are no longer reachable from the new path. ValueNotifier
  /// listeners run synchronously, so a painter cannot still be using a removed
  /// picture when it is disposed here.
  void _setStrokePreview(LiveStrokePreview? next) {
    final previous = _strokePreview.value;
    _strokePreview.value = next;
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

  void _scheduleLiveViewportSync() {
    final liveSurface = _livePreviewSurface;
    if (liveSurface == null || _liveViewportSyncScheduled || _disposed) return;
    _liveViewportSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _liveViewportSyncScheduled = false;
      if (!mounted ||
          _disposed ||
          !identical(liveSurface, _livePreviewSurface)) {
        return;
      }
      unawaited(_synchronizeLiveViewportAfterCleanup(liveSurface));
    });
  }

  Future<void> _synchronizeLiveViewportAfterCleanup(
    LivePreviewController liveSurface,
  ) async {
    await _pendingLiveSurfaceDisposal;
    if (!mounted || _disposed || !identical(liveSurface, _livePreviewSurface)) {
      return;
    }
    final renderObject = _canvasKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return;
    liveSurface.synchronizeViewport(
      viewportSize: renderObject.size,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      pan: _pan,
      scale: _scale,
      rotation: _rotation,
      mirrored: _mirrorCanvas,
      documentWidth: widget.engine.documentInfo.widthPx,
      documentHeight: widget.engine.documentInfo.heightPx,
    );
  }
}
