import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/editor_action.dart';
import '../app/workspace_mode.dart';
import '../app/workspace_preferences.dart';
import '../bridge/engine_api.dart';
import '../bridge/generated/api.dart' as rust;
import '../comics/comic_workspace.dart';
import '../documents/autosave_coordinator.dart';
import '../documents/document_picker.dart';
import '../design_system/ink_components.dart';
import '../layers/layer_panel.dart';
import '../layers/layer_panel_model.dart';
import '../tools/brush_library.dart';
import '../tools/brush_library_panel.dart';
import '../tools/illustration_tools.dart';
import 'android_live_surface_controller.dart';
import 'canvas_diagnostic_recorder.dart';
import 'canvas_workspace_widgets.dart';
import 'live_stroke_coordinator.dart';
import 'desktop_live_texture_adapter.dart';
import 'gesture_defaults.dart';
import 'live_preview_controller.dart';
import 'mac_live_surface_controller.dart';
import 'native_pointer_stream.dart';
import 'performance_trace.dart';
import 'pointer_packet.dart';
import 'tile_cache.dart';
import 'viewport_transform.dart';
import 'workspace_dock_layout.dart';
import 'workspace_panels.dart';
import 'touch_gesture_classifier.dart';

part 'canvas_document_actions.dart';
part 'canvas_preview_synchronization.dart';

String _documentDisplayName(String? path) {
  if (path == null || path.isEmpty) return 'Untitled';
  final normalizedPath = path.replaceFirst(RegExp(r'[/\\]+$'), '');
  if (normalizedPath.isEmpty) return 'Untitled';
  final segments = normalizedPath.split(RegExp(r'[/\\]'));
  final filename = segments.isEmpty ? '' : segments.last;
  if (filename.isEmpty) return 'Untitled';
  return filename.toLowerCase().endsWith('.inkproj')
      ? filename.substring(0, filename.length - '.inkproj'.length)
      : filename;
}

const _comicProjectOpenFailureMessage =
    'Could not open the selected comic project. It may be damaged, unsupported, or inaccessible. Your current project remains open.';
const bool _autoStartCanvasDiagnostics = bool.fromEnvironment(
  'INK_AUTO_START_CANVAS_DIAGNOSTICS',
);
const bool _disableIpadDabRenderer = bool.fromEnvironment(
  'INK_DISABLE_IPAD_GPU_STROKE_RENDERER',
  // Keep the compiled brush dab surface as the normal iPad renderer. Define
  // this only for a comparison build that deliberately shows the approximate
  // Flutter path while diagnosing the Rust/GPU handoff.
  defaultValue: false,
);

String _autosaveStatusLabel(AutosaveState? state) {
  if (state == null) return 'Not saved';
  if (state.lastError != null) return 'Save failed';
  if (state.saving && state.dirty) return 'Saving…  •  Changes pending';
  if (state.saving) return 'Saving…';
  if (state.dirty) return 'Unsaved changes';
  return state.hasSavedCheckpoint ? 'Saved' : 'Not saved';
}

/// Reduce native Pencil bridge overhead when UIKit events arrive faster than
/// the serialized engine worker can consume them. Confirmed samples are kept
/// in order; predicted samples are omitted only when multiple event packets
/// have accumulated, since they become stale as soon as a newer contact lands.
List<Uint8List> _compactNativePointerPackets(List<Uint8List> packets) {
  if (packets.length <= 1) return packets;
  final result = <Uint8List>[];
  final movePackets = <Uint8List>[];
  void flushMoves() {
    if (movePackets.isEmpty) return;
    result.addAll(_mergeNativeMovePackets(movePackets));
    movePackets.clear();
  }

  for (final packet in packets) {
    final data = ByteData.sublistView(packet);
    final count = data.getUint16(2, Endian.little);
    var moveOnly = count > 0;
    for (var index = 0; index < count && moveOnly; index++) {
      moveOnly =
          data.getUint8(4 + index * 48 + 7) == InkPointerPhase.move.index;
    }
    if (moveOnly) {
      movePackets.add(packet);
    } else {
      // A down/up/cancel packet is an engine transaction boundary. Never
      // merge it with another event, or one packet could span two strokes.
      flushMoves();
      result.add(packet);
    }
  }
  flushMoves();
  return result;
}

List<Uint8List> _mergeNativeMovePackets(List<Uint8List> packets) {
  if (packets.length == 1) return packets;
  const sampleBytes = 48;
  const maxSamples = inkPointerMaxSamples;
  final samples = <Uint8List>[];
  for (final packet in packets) {
    final data = ByteData.sublistView(packet);
    final count = data.getUint16(2, Endian.little);
    for (var index = 0; index < count; index++) {
      final offset = 4 + index * sampleBytes;
      final flags = data.getUint16(offset + 4, Endian.little);
      if (flags & inkPointerPredicted != 0) continue;
      samples.add(Uint8List.sublistView(packet, offset, offset + sampleBytes));
    }
  }
  final result = <Uint8List>[];
  for (var start = 0; start < samples.length; start += maxSamples) {
    final end = math.min(start + maxSamples, samples.length);
    final packet = Uint8List(4 + (end - start) * sampleBytes);
    final data = ByteData.sublistView(packet);
    data.setUint16(0, 1, Endian.little);
    data.setUint16(2, end - start, Endian.little);
    var offset = 4;
    for (final sample in samples.getRange(start, end)) {
      packet.setRange(offset, offset + sampleBytes, sample);
      offset += sampleBytes;
    }
    result.add(packet);
  }
  return result;
}

enum SelectionEdit { invert, grow, shrink }

class CanvasScreen extends StatefulWidget {
  CanvasScreen({
    super.key,
    EngineApi? engine,
    this.autosave,
    this.autosaveState,
    this.documentPicker,
    this.targetPlatform,
    @visibleForTesting this.documentPickerTimeout = const Duration(minutes: 2),
    this.onNewDocument,
    this.onOpenDocument,
    this.activeDocumentPath,
    this.onDocumentSaved,
    this.onBeforeOpenStudioProject,
    this.onStudioProjectOpened,
    this.onEngineReplaced,
    this.onPerformanceSnapshot,
    this.comicWorkspaceController,
    this.desktopDockEnabled = false,
    this.workspaceModeOverride,
    this.workspaceDockWidth = 340,
    this.workspacePreferences,
    this.onWorkspacePreferencesChanged,
    @visibleForTesting this.nativePointerPacketsOverride,
    @visibleForTesting this.nativePointerReadyOverride,
    @visibleForTesting this.nativePencilCommandsOverride,
    @visibleForTesting this.livePreviewControllerFactory,
  }) : engine = engine ?? InMemoryEngineApi();
  final EngineApi engine;

  /// Optional local checkpoint scheduler supplied by the document session.
  /// Flutter never copies document state into the autosave coordinator.
  final AutosaveCoordinator? autosave;

  /// Latest save/checkpoint projection supplied by the owning app session.
  final AutosaveState? autosaveState;

  /// Platform-owned path chooser for Open/Save/Export actions.
  final DocumentPicker? documentPicker;

  /// Optional platform override for deterministic widget tests.
  final TargetPlatform? targetPlatform;

  @visibleForTesting
  final Duration documentPickerTimeout;

  /// Parent callback used to replace the active Rust document with a new one.
  final Future<void> Function({
    required int widthPx,
    required int heightPx,
    required double dpi,
  })?
  onNewDocument;

  /// Parent callback used to replace the current Rust document handle.
  final Future<void> Function(String path)? onOpenDocument;

  /// Destination selected by the document session after the last successful
  /// Save As. A recovery checkpoint path is deliberately not exposed here.
  final String? activeDocumentPath;

  /// Lets the app session bind autosave and subsequent Save commands to the
  /// destination only after Rust and provider write-back both succeed.
  final Future<void> Function(String path)? onDocumentSaved;
  final Future<void> Function()? onBeforeOpenStudioProject;
  final Future<void> Function(String path)? onStudioProjectOpened;
  final void Function(EngineApi previousEngine, Future<void> surfaceDisposal)?
  onEngineReplaced;

  /// Optional local diagnostics hook for Phase 1 physical-device traces.
  final ValueChanged<Phase1PerformanceSnapshot>? onPerformanceSnapshot;

  /// Optional seam for widget tests and host shells that already own the
  /// comic session lifecycle. Production binds the canvas to the shared page
  /// capability while retaining the document-attached metadata checkpoint for
  /// compatibility.
  final ComicWorkspaceController? comicWorkspaceController;

  /// Enables the desktop dock for the production shell. Tests can keep the
  /// compact floating-panel layout so toolbar hit targets remain deterministic.
  final bool desktopDockEnabled;

  /// Optional device-local layout override. It is intentionally not part of
  /// the document or Rust engine state.
  final WorkspaceMode? workspaceModeOverride;
  final double workspaceDockWidth;

  /// Device-local workspace settings loaded by the app shell. These are
  /// deliberately kept outside the Rust document authority.
  final WorkspacePreferences? workspacePreferences;
  final ValueChanged<WorkspacePreferences>? onWorkspacePreferencesChanged;

  /// Optional native input stream for deterministic adapter tests.
  @visibleForTesting
  final Stream<Uint8List>? nativePointerPacketsOverride;

  @visibleForTesting
  final Stream<void>? nativePointerReadyOverride;

  @visibleForTesting
  final Stream<String>? nativePencilCommandsOverride;

  @visibleForTesting
  final LivePreviewController Function(EngineApi engine)?
  livePreviewControllerFactory;

  @override
  State<CanvasScreen> createState() => _CanvasScreenState();
}

class _CanvasScreenState extends State<CanvasScreen>
    with _CanvasDocumentActions, _CanvasPreviewSynchronization {
  static const Duration _tilePollInterval = Duration(milliseconds: 16);
  static const int _maxCpuHandoffSnapshotTiles = 256;
  // Negative IDs cannot collide with persisted UUID-backed layer IDs. They
  // identify the authoritative Rust composite stream in the Flutter cache.
  static const int _compositeLayerId = -1;

  @override
  final GlobalKey _canvasKey = GlobalKey();
  final Map<int, Offset> _pointers = <int, Offset>{};
  final Map<int, Offset> _touchDown = <int, Offset>{};
  final Map<int, Offset> _touchCurrent = <int, Offset>{};
  final Set<int> _activeTouchPointers = <int>{};
  final Map<int, int> _activeBrushDrafts = <int, int>{};
  final Map<int, Future<void>> _brushEditQueues = <int, Future<void>>{};
  final TileCache _tileBytes = TileCache();
  final TileImageCache _tileImages = TileImageCache();
  @override
  final Phase1PerformanceTrace _performanceTrace = Phase1PerformanceTrace();
  @override
  late final ValueNotifier<LiveStrokePreview?> _strokePreview =
      ValueNotifier<LiveStrokePreview?>(null);
  late final EditorCommandRegistry _commands = EditorCommandRegistry(
    _dispatchAction,
  );
  Future<void> _strokeWork = Future<void>.value();
  final Queue<Future<void> Function()> _strokeOperations =
      Queue<Future<void> Function()>();
  bool _drainingStrokeOperations = false;
  final List<Uint8List> _pendingNativePackets = <Uint8List>[];
  final LiveStrokeCoordinator _liveStrokeCoordinator = LiveStrokeCoordinator();
  bool _nativePacketDrainQueued = false;
  bool _livePreviewFrameDiagnosticScheduled = false;
  Timer? _tilePollTimer;
  Timer? _touchLongPressTimer;
  Timer? _stylusHoldTimer;
  Timer? _quickBrushSizeTimer;
  double? _pendingQuickBrushSize;
  StreamSubscription<Uint8List>? _nativePointerSubscription;
  StreamSubscription<void>? _nativePointerStatusSubscription;
  StreamSubscription<String>? _nativePencilCommandSubscription;
  StreamSubscription<Map<String, Object?>>? _nativeCanvasDiagnosticSubscription;
  @override
  final CanvasDiagnosticRecorder _canvasDiagnostics =
      CanvasDiagnosticRecorder.instance;
  int _touchCount = 0;
  bool _touchMoved = false;
  DateTime? _touchStarted;
  int _sequence = 0;
  int _cpuCommitBatchId = 0;
  bool _strokeActive = false;
  bool _activeStrokeIsTouch = false;
  // After the crossing sample has been clipped by Rust, captured pointer
  // motion outside the artwork (and any re-entry) cannot alter the stroke.
  // Ignore those moves so a long off-canvas drag cannot backlog bridge work.
  bool _strokeCaptureEndedAtBoundary = false;
  StrokeAcknowledgement? _lastPublishedPreviewAcknowledgement;
  bool _nativeLastSampleInsideDocument = false;
  bool _previewStoppedAtPageEdge = false;
  bool _interfaceHidden = false;
  bool _refreshingTiles = false;
  bool _refreshRequested = false;
  bool _refreshInitialRequested = false;
  bool _initialTilesLoaded = false;
  @override
  bool _disposed = false;
  bool _nativePointerEnabled = false;
  int _nativeDiagnosticPacketCount = 0;
  int _nativeDiagnosticSampleCount = 0;
  double _nativeDiagnosticMinPressure = 1.0;
  double _nativeDiagnosticMaxPressure = 0.0;
  bool _nativePencilContactActive = false;
  bool _touchDrawingStrokeActive = false;
  bool _eraserActive = false;
  bool _quickMenuVisible = false;
  bool _colorSamplerArmed = false;
  @override
  bool _mirrorCanvas = false;
  bool _touchGestureTriggered = false;
  Offset? _touchGesturePosition;
  bool _straightenMode = false;
  bool _constrainMode = false;
  Offset? _constraintStrokeStart;
  Offset? _straightenDirection;
  Offset? _stylusLastPosition;
  final Stopwatch _nativeInputArrivalClock = Stopwatch()..start();
  int _lastNativeInputArrivalUs = 0;
  Color _activeColor = const Color(0xff202124);
  Color _subColor = Colors.white;
  GestureDefaults _gestureDefaults = const GestureDefaults();
  bool _singleFingerNavigation = false;
  bool _largeControls = false;
  bool _leftHandedToolbar = false;
  @override
  bool _documentActionRunning = false;
  @override
  int _documentActionGeneration = 0;
  @override
  LivePreviewController? _livePreviewSurface;
  @override
  Future<void> _pendingLiveSurfaceDisposal = Future<void>.value();
  final List<StrokeAcknowledgement> _pendingLiveStrokeAcks =
      <StrokeAcknowledgement>[];
  final List<StrokeAcknowledgement> _pendingCpuStrokeAcks =
      <StrokeAcknowledgement>[];
  bool _awaitingPreviewCommit = false;
  bool _showBrushes = false;
  bool _showLayers = false;
  bool _showTools = false;
  bool _showComics = false;
  bool _didInitializeTabletStudioDock = false;
  BigInt? _comicClipPanelId;
  int? _comicClipPageIndex;
  bool _workspaceDockCollapsed = false;
  bool _workspaceLeftDockCollapsed = false;
  String _desktopDockTab = 'layers';
  String _leftDockTab = 'tools';
  List<DockGroupLayout> _leftDockGroups = const [];
  List<DockGroupLayout> _rightDockGroups = const [];
  String? _temporaryDesktopPalette;
  late double _workspaceDockWidth;
  late double _workspaceLeftDockWidth;
  IllustrationTool _activeTool = IllustrationTool.brush;
  Offset? _toolStart;
  List<Offset> _toolPoints = const [];
  List<double> _toolVectorPoints = const [];
  Rect? _selectionGeometry;
  IllustrationTool? _selectionGeometryTool;
  Offset? _rulerStart;
  Offset? _rulerEnd;
  IllustrationTool? _rulerTool;
  @override
  int _activeBrushId = 1;
  @override
  late final BrushLibraryModel _brushLibrary = BrushLibraryModel(const []);
  @override
  late final ComicWorkspaceController _comicWorkspace =
      widget.comicWorkspaceController ??
      ComicWorkspaceController(
        onPersist: (bytes) => widget.engine.attachComicProject(bytes),
        readExisting: widget.engine.readComicProject,
        onPanelGeometryChanged: _syncComicPanelGeometry,
        onActivePageChanged: (handle) async {
          final engine = widget.engine;
          if (engine is FrbEngineApi) {
            await engine.rebindDocument(handle);
            if (mounted) setState(() {});
          }
        },
        onProjectChanged: (project) async {
          final engine = widget.engine;
          if (engine is FrbEngineApi) engine.bindStudioProject(project);
        },
      );
  final LayerSelectionModel _layerSelection = LayerSelectionModel();
  List<LayerView> _layers = const [];
  List<VectorStrokeSummaryView> _vectorStrokes = const [];
  bool _comicChangeScheduled = false;
  int _engineGeneration = 0;
  int? _lastPacketMicros;
  int _renderRevision = 0;
  @override
  Offset _pan = Offset.zero;
  @override
  double _scale = 1;
  @override
  double _rotation = 0;
  double _scaleGestureStartScale = 1;
  double _scaleGestureStartRotation = 0;
  Offset _scaleGestureStartPan = Offset.zero;
  Offset _scaleGestureStartFocalPoint = Offset.zero;

  @override
  void initState() {
    super.initState();
    _configureLivePreviewSurface();
    final preferences = widget.workspacePreferences;
    final layout = _workspaceLayoutFor(
      preferences?.workspaceId ?? 'illustration',
      preferences?.customWorkspaces ?? const <WorkspaceLayout>[],
    );
    final isCustomWorkspace =
        preferences?.customWorkspaces.any(
          (workspace) => workspace.id == preferences.workspaceId,
        ) ??
        false;
    _workspaceDockWidth =
        (isCustomWorkspace || preferences?.workspaceId == 'comic'
            ? layout.right?.width
            : preferences?.dockWidth) ??
        widget.workspaceDockWidth.clamp(220.0, 480.0).toDouble();
    _workspaceLeftDockWidth =
        (isCustomWorkspace
                ? layout.left?.width
                : preferences?.leftDockWidth ?? layout.left?.width ?? 248)
            ?.clamp(220, 480)
            .toDouble() ??
        248;
    _workspaceDockCollapsed = layout.right?.collapsed ?? layout.right == null;
    _workspaceLeftDockCollapsed = layout.left?.collapsed ?? layout.left == null;
    _leftHandedToolbar = preferences?.leftHanded ?? false;
    _desktopDockTab =
        preferences?.lastDock ??
        _paletteName(layout.right?.groups.firstOrNull?.activeTab) ??
        'layers';
    _leftDockTab =
        _paletteName(layout.left?.groups.firstOrNull?.activeTab) ?? 'tools';
    _leftDockGroups = layout.left?.groups ?? const [];
    _rightDockGroups = layout.right?.groups ?? const [];
    _comicWorkspace.addListener(_onComicWorkspaceChanged);
    _tilePollTimer = Timer.periodic(
      _tilePollInterval,
      (_) => unawaited(_refreshTiles()),
    );
    final platform = widget.targetPlatform ?? defaultTargetPlatform;
    if (_autoStartCanvasDiagnostics && platform == TargetPlatform.iOS) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_canvasDiagnostics.isRecording) {
          unawaited(_startCanvasDiagnostics(trigger: 'debug_launch_flag'));
        }
      });
    }
    if (platform == TargetPlatform.iOS) {
      _nativeCanvasDiagnosticSubscription = nativeCanvasDiagnosticEvents()
          .listen(
            (event) => _canvasDiagnostics.record(
              'native.${event['kind'] ?? 'event'}',
              event,
            ),
            onError:
                (Object error, StackTrace stack) => _canvasDiagnostics
                    .recordError('native_diagnostic_channel', error, stack),
          );
    }
    // Every desktop and mobile target has a native adapter. Keep the generic
    // Flutter stylus path enabled until the platform EventChannel announces
    // readiness, then route stylus packets through the native adapter exactly
    // once. Pencil command events are only registered on platforms that
    // provide them; Windows/Linux still use their pointer status channel.
    if (platform == TargetPlatform.iOS ||
        platform == TargetPlatform.android ||
        platform == TargetPlatform.macOS ||
        platform == TargetPlatform.windows ||
        platform == TargetPlatform.linux) {
      _nativePointerSubscription = (widget.nativePointerPacketsOverride ??
              nativePointerPackets())
          .listen(
            _handleNativePacket,
            onError: (Object error, StackTrace stack) {
              _nativePointerEnabled = false;
              _canvasDiagnostics.recordError(
                'native_pointer_stream',
                error,
                stack,
              );
              debugPrint(
                'Project Ink native pointer stream unavailable: $error',
              );
            },
          );
      _nativePointerStatusSubscription =
          (widget.nativePointerReadyOverride ?? nativePointerReady()).listen(
            (_) => _nativePointerEnabled = true,
            onError: (Object error, StackTrace stack) {
              _nativePointerEnabled = false;
              _canvasDiagnostics.recordError(
                'native_pointer_status',
                error,
                stack,
              );
              debugPrint(
                'Project Ink native pointer status unavailable: $error',
              );
            },
          );
      if (platform == TargetPlatform.iOS ||
          platform == TargetPlatform.android ||
          platform == TargetPlatform.macOS) {
        _nativePencilCommandSubscription =
            (widget.nativePencilCommandsOverride ?? nativePencilCommands())
                .listen(
                  _handlePencilCommand,
                  onError: (Object error, StackTrace stack) {
                    _canvasDiagnostics.recordError(
                      'native_pencil_commands',
                      error,
                      stack,
                    );
                    debugPrint(
                      'Project Ink Pencil command stream unavailable: $error',
                    );
                  },
                );
      }
    }
    unawaited(_loadPhase2Projections());
    unawaited(_refreshTiles(initial: true));
  }

  @override
  Future<void> _loadPhase2Projections() async {
    final generation = _engineGeneration;
    final engine = widget.engine;
    try {
      final brushes = await engine.builtinBrushes();
      if (!mounted ||
          generation != _engineGeneration ||
          engine != widget.engine) {
        return;
      }
      for (final brush in brushes) {
        final family = _familyFor(brush.tags);
        _brushLibrary.upsert(
          BrushPresetView(
            id: brush.id,
            name: brush.name,
            family: family,
            tags: brush.tags,
            size: brush.diameterPx,
            opacity: brush.opacity,
            spacing: brush.spacing,
            stabilization: brush.smoothing,
            pressureSize: brush.pressureSize,
            pressureOpacity: brush.pressureOpacity,
            hardness: brush.hardness,
            textureScale: brush.textureScale,
            scatter: brush.scatter,
            rotationJitter: brush.rotationJitter,
            smudge: brush.smudge,
            wetness: brush.wetness,
            pressureCurvePoints: _curvePointsFromFlat(
              brush.pressureCurvePoints,
            ),
            pressureCurve: _curveMidpointFromFlat(brush.pressureCurvePoints),
            tipResourceHash: brush.tipResourceHash,
            grainResourceHash: brush.grainResourceHash,
          ),
        );
      }
      if (brushes.isNotEmpty) {
        final currentBrushId = _brushLibrary.selected?.id;
        final selectedBrushId =
            brushes.any((brush) => brush.id == currentBrushId)
                ? currentBrushId!
                : brushes.first.id;
        _brushLibrary.select(selectedBrushId);
        _activeBrushId = selectedBrushId;
        final selectedSummary = brushes.firstWhere(
          (brush) => brush.id == selectedBrushId,
        );
        final color = selectedSummary.colorRgba;
        _activeColor = Color.fromARGB(
          color & 0xff,
          (color >> 24) & 0xff,
          (color >> 16) & 0xff,
          (color >> 8) & 0xff,
        );
      }
      await _refreshLayerProjection();
    } catch (error, stack) {
      debugPrint('Project Ink Phase 2 projections unavailable: $error\n$stack');
    }
  }

  Future<void> _refreshLayerProjection() async {
    final generation = _engineGeneration;
    final engine = widget.engine;
    try {
      final layers = await engine.layerSummaries();
      final projectedLayers = await Future.wait(
        layers.map((layer) async {
          Uint8List? thumbnail;
          try {
            thumbnail = await engine.readLayerThumbnail(layerId: layer.id);
          } catch (_) {
            // Thumbnail failure must not prevent the layer list from loading.
          }
          return LayerView(
            id: layer.id,
            parent: layer.parent,
            order: layer.order,
            name: layer.name,
            kind: _layerKindFor(layer.kind),
            opacity: layer.opacity,
            visible: layer.visible,
            blendMode: _layerBlendModeFor(layer.blendMode),
            groupMode:
                layer.groupMode == 'Pass-through'
                    ? LayerGroupMode.passThrough
                    : LayerGroupMode.isolated,
            alphaLock: layer.alphaLock,
            clipping: layer.clipping,
            reference: layer.reference,
            label: layer.labelRgba,
            thumbnail: thumbnail,
            adjustmentBrightness: layer.adjustmentBrightness,
            adjustmentContrast: layer.adjustmentContrast,
          );
        }),
      );
      if (!mounted ||
          generation != _engineGeneration ||
          engine != widget.engine) {
        return;
      }
      final validLayerIds = projectedLayers.map((layer) => layer.id).toSet();
      if (_layerSelection.selected.difference(validLayerIds).isNotEmpty) {
        _layerSelection.clear();
        final fallback =
            projectedLayers
                .where(
                  (layer) =>
                      layer.visible &&
                      (layer.kind == LayerKind.raster ||
                          layer.kind == LayerKind.vectorInk ||
                          layer.kind == LayerKind.tone),
                )
                .firstOrNull;
        if (fallback != null) _layerSelection.select(fallback.id);
      }
      setState(() => _layers = projectedLayers);
      await _loadVectorStrokesForSelection();
    } catch (error, stack) {
      debugPrint('Project Ink layer projection unavailable: $error\n$stack');
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didInitializeTabletStudioDock) return;
    final platform = widget.targetPlatform ?? defaultTargetPlatform;
    final isTouchPlatform =
        platform == TargetPlatform.iOS || platform == TargetPlatform.android;
    if (!isTouchPlatform || MediaQuery.sizeOf(context).width < 600) return;
    _didInitializeTabletStudioDock = true;
    _showLayers =
        widget.workspacePreferences?.tabletMode == TabletWorkspaceMode.studio;
  }

  BrushFamily _familyFor(List<String> tags) {
    for (final tag in tags) {
      switch (tag.toLowerCase()) {
        case 'sketch':
          return BrushFamily.sketch;
        case 'ink':
          return BrushFamily.ink;
        case 'watercolor':
          return BrushFamily.watercolor;
        case 'effect':
          return BrushFamily.effect;
        case 'paint':
          return BrushFamily.paint;
      }
    }
    return BrushFamily.paint;
  }

  LayerKind _layerKindFor(String kind) => switch (kind.toLowerCase()) {
    'vectorink' => LayerKind.vectorInk,
    'group' => LayerKind.group,
    'mask' => LayerKind.mask,
    'tone' => LayerKind.tone,
    'panelgroup' => LayerKind.panelGroup,
    'adjustment' => LayerKind.adjustment,
    _ => LayerKind.raster,
  };

  LayerBlendMode _layerBlendModeFor(String mode) => switch (mode) {
    'Multiply' => LayerBlendMode.multiply,
    'Screen' => LayerBlendMode.screen,
    'Overlay' => LayerBlendMode.overlay,
    'Darken' => LayerBlendMode.darken,
    'Lighten' => LayerBlendMode.lighten,
    'Add' => LayerBlendMode.add,
    'Subtract' => LayerBlendMode.subtract,
    'Color Burn' => LayerBlendMode.colorBurn,
    'Linear Burn' => LayerBlendMode.linearBurn,
    'Color Dodge' => LayerBlendMode.colorDodge,
    'Soft Light' => LayerBlendMode.softLight,
    'Hard Light' => LayerBlendMode.hardLight,
    'Difference' => LayerBlendMode.difference,
    'Exclusion' => LayerBlendMode.exclusion,
    'Divide' => LayerBlendMode.divide,
    _ => LayerBlendMode.normal,
  };

  @override
  void didUpdateWidget(covariant CanvasScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    var oldSurfaceDisposal = _pendingLiveSurfaceDisposal;
    if (oldWidget.engine != widget.engine ||
        oldWidget.targetPlatform != widget.targetPlatform) {
      final oldSurface = _livePreviewSurface;
      _livePreviewSurface = null;
      if (oldSurface != null) {
        oldSurface.gpuFrameReady.removeListener(_onLiveFrameReadinessChanged);
        oldSurfaceDisposal = _queueLiveSurfaceDisposal(oldSurface);
        unawaited(oldSurfaceDisposal);
      }
      _configureLivePreviewSurface();
      _pendingLiveStrokeAcks.clear();
    }
    if (oldWidget.workspacePreferences != widget.workspacePreferences) {
      final preferences = widget.workspacePreferences;
      if (preferences != null) {
        _leftHandedToolbar = preferences.leftHanded;
        final layout = _workspaceLayoutFor(
          preferences.workspaceId,
          preferences.customWorkspaces,
        );
        final isCustomWorkspace = preferences.customWorkspaces.any(
          (workspace) => workspace.id == preferences.workspaceId,
        );
        final useLayoutDockWidth =
            isCustomWorkspace || preferences.workspaceId == 'comic';
        _workspaceDockWidth =
            (useLayoutDockWidth
                    ? layout.right?.width ?? preferences.dockWidth
                    : preferences.dockWidth)
                .clamp(220.0, 480.0)
                .toDouble();
        _workspaceLeftDockWidth =
            (isCustomWorkspace
                    ? layout.left?.width ?? preferences.leftDockWidth
                    : preferences.leftDockWidth)
                .clamp(220, 480)
                .toDouble();
        if (oldWidget.workspacePreferences?.workspaceId !=
                preferences.workspaceId ||
            oldWidget.workspacePreferences?.workspaceOverrides !=
                preferences.workspaceOverrides) {
          _workspaceDockCollapsed =
              layout.right?.collapsed ?? layout.right == null;
          _workspaceLeftDockCollapsed =
              layout.left?.collapsed ?? layout.left == null;
          _desktopDockTab =
              _paletteName(layout.right?.groups.firstOrNull?.activeTab) ??
              'layers';
          _leftDockTab =
              _paletteName(layout.left?.groups.firstOrNull?.activeTab) ??
              'tools';
          _leftDockGroups = layout.left?.groups ?? const [];
          _rightDockGroups = layout.right?.groups ?? const [];
        }
        if (const {
              'tools',
              'brushes',
              'layers',
              'properties',
              'materials',
              'comics',
              'history',
              'quickAccess',
              'color',
            }.contains(preferences.lastDock) &&
            oldWidget.workspacePreferences?.lastDock != preferences.lastDock) {
          _desktopDockTab = preferences.lastDock;
        }
      }
    }
    if (oldWidget.engine != widget.engine) {
      for (final draftId in _activeBrushDrafts.values) {
        unawaited(
          oldWidget.engine.cancelBrushDraft(draftId).catchError((Object error) {
            debugPrint('Project Ink brush draft cleanup failed: $error');
          }),
        );
      }
      _activeBrushDrafts.clear();
      _brushEditQueues.clear();
      _engineGeneration++;
      widget.onEngineReplaced?.call(oldWidget.engine, oldSurfaceDisposal);
      _pendingNativePackets.clear();
      _nativePacketDrainQueued = false;
      _strokeActive = false;
      _activeStrokeIsTouch = false;
      _refreshRequested = false;
      _refreshInitialRequested = false;
      _tileBytes.clear();
      _tileImages.clear();
      _setStrokePreview(null);
      _pendingLiveStrokeAcks.clear();
      _initialTilesLoaded = false;
      _renderRevision = 0;
      _layerSelection.clear();
      _layers = const [];
      _vectorStrokes = const [];
      _selectionGeometry = null;
      _selectionGeometryTool = null;
      _toolPoints = const [];
      _toolVectorPoints = const [];
      unawaited(_comicWorkspace.republishEngineBindings());
      unawaited(_loadPhase2Projections());
      unawaited(_refreshTiles(initial: true));
    }
  }

  void _persistWorkspacePreferences({
    bool? leftHanded,
    String? lastDock,
    double? dockWidth,
    double? leftDockWidth,
    String? workspaceId,
    TabletWorkspaceMode? tabletMode,
    List<WorkspaceLayout>? customWorkspaces,
    bool? followDocumentType,
    List<QuickAccessSet>? quickAccessSets,
    String? activeQuickAccessSetId,
    List<String>? recentColors,
    Map<String, List<String>>? commandBarOverrides,
    Map<String, WorkspaceLayout>? workspaceOverrides,
  }) {
    final callback = widget.onWorkspacePreferencesChanged;
    if (callback == null) return;
    final current = widget.workspacePreferences ?? const WorkspacePreferences();
    callback(
      current.copyWith(
        leftHanded: leftHanded,
        lastDock: lastDock,
        dockWidth: dockWidth,
        leftDockWidth: leftDockWidth,
        workspaceId: workspaceId,
        tabletMode: tabletMode,
        customWorkspaces: customWorkspaces,
        followDocumentType: followDocumentType,
        quickAccessSets: quickAccessSets,
        activeQuickAccessSetId: activeQuickAccessSetId,
        recentColors: recentColors,
        commandBarOverrides: commandBarOverrides,
        workspaceOverrides: workspaceOverrides,
      ),
    );
  }

  List<String> _effectiveCommandBarItems() {
    final preferences =
        widget.workspacePreferences ?? const WorkspacePreferences();
    final layout = _workspaceLayoutFor(
      preferences.workspaceId,
      preferences.customWorkspaces,
    );
    if (layout.kind == WorkspacePresetKind.custom &&
        layout.commandBar.isNotEmpty) {
      return layout.commandBar;
    }
    final override = preferences.commandBarOverrides[preferences.workspaceId];
    return override == null || override.isEmpty
        ? defaultCommandBarItems
        : override;
  }

  Future<void> _customizeCommandBar() async {
    final current = _effectiveCommandBarItems();
    final edited = await showDialog<List<String>>(
      context: context,
      builder: (dialogContext) {
        var items = [...current];
        return StatefulBuilder(
          builder:
              (context, refresh) => AlertDialog(
                title: const Text('Customize command bar'),
                content: SizedBox(
                  width: 460,
                  height: 440,
                  child: Column(
                    children: [
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: [
                          PopupMenuButton<EditorActionId>(
                            tooltip: 'Add command',
                            onSelected:
                                (action) => refresh(() {
                                  if (items.length < 48) items.add(action.name);
                                }),
                            itemBuilder:
                                (_) => [
                                  for (final action in EditorActionId.values
                                      .where(
                                        (action) =>
                                            !items.contains(action.name),
                                      ))
                                    PopupMenuItem(
                                      value: action,
                                      child: Text(action.label),
                                    ),
                                ],
                            child: const Chip(
                              avatar: Icon(Icons.add, size: 16),
                              label: Text('Add command'),
                            ),
                          ),
                          TextButton.icon(
                            onPressed:
                                items.length >= 48 ||
                                        items.lastOrNull == 'separator'
                                    ? null
                                    : () =>
                                        refresh(() => items.add('separator')),
                            icon: const Icon(Icons.vertical_split),
                            label: const Text('Add separator'),
                          ),
                          TextButton(
                            onPressed:
                                () => refresh(
                                  () => items = [...defaultCommandBarItems],
                                ),
                            child: const Text('Reset'),
                          ),
                        ],
                      ),
                      const Divider(),
                      Expanded(
                        child: ReorderableListView.builder(
                          itemCount: items.length,
                          onReorderItem:
                              (oldIndex, newIndex) => refresh(() {
                                final item = items.removeAt(oldIndex);
                                items.insert(newIndex, item);
                              }),
                          itemBuilder: (context, index) {
                            final item = items[index];
                            final action =
                                EditorActionId.values
                                    .where(
                                      (candidate) => candidate.name == item,
                                    )
                                    .firstOrNull;
                            return ListTile(
                              key: ValueKey('command-bar-$index-$item'),
                              dense: true,
                              leading: Icon(
                                item == 'separator'
                                    ? Icons.vertical_split
                                    : _commandBarIcon(action!),
                              ),
                              title: Text(
                                action?.label ?? 'Separator',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  ReorderableDragStartListener(
                                    index: index,
                                    child: const Icon(Icons.drag_handle),
                                  ),
                                  IconButton(
                                    tooltip: 'Hide command',
                                    onPressed:
                                        items.length <= 1
                                            ? null
                                            : () => refresh(() {
                                              items.removeAt(index);
                                              while (items.isNotEmpty &&
                                                  items.last == 'separator') {
                                                items.removeLast();
                                              }
                                              for (
                                                var i = items.length - 1;
                                                i > 0;
                                                i--
                                              ) {
                                                if (items[i] == 'separator' &&
                                                    items[i - 1] ==
                                                        'separator') {
                                                  items.removeAt(i);
                                                }
                                              }
                                            }),
                                    icon: const Icon(
                                      Icons.remove_circle_outline,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed:
                        items.isEmpty || items.last == 'separator'
                            ? null
                            : () => Navigator.pop(dialogContext, items),
                    child: const Text('Save'),
                  ),
                ],
              ),
        );
      },
    );
    if (!mounted || edited == null) return;
    final preferences =
        widget.workspacePreferences ?? const WorkspacePreferences();
    final layout = _workspaceLayoutFor(
      preferences.workspaceId,
      preferences.customWorkspaces,
    );
    if (layout.kind == WorkspacePresetKind.custom) {
      final custom = [...preferences.customWorkspaces];
      final index = custom.indexWhere((item) => item.id == layout.id);
      if (index >= 0) {
        final currentLayout = custom[index];
        custom[index] = WorkspaceLayout(
          id: currentLayout.id,
          name: currentLayout.name,
          kind: currentLayout.kind,
          left: currentLayout.left,
          right: currentLayout.right,
          commandBar: edited,
        );
        _persistWorkspacePreferences(customWorkspaces: custom);
      }
    } else {
      final overrides = Map<String, List<String>>.from(
        preferences.commandBarOverrides,
      )..[preferences.workspaceId] = edited;
      _persistWorkspacePreferences(commandBarOverrides: overrides);
    }
  }

  void _persistDockWidth({required bool left, required double width}) {
    final preferences =
        widget.workspacePreferences ?? const WorkspacePreferences();
    final customIndex = preferences.customWorkspaces.indexWhere(
      (layout) => layout.id == preferences.workspaceId,
    );
    if (customIndex < 0) {
      if (const {
        'illustration',
        'comic',
        'minimal',
      }.contains(preferences.workspaceId)) {
        final current = _workspaceLayoutFor(
          preferences.workspaceId,
          preferences.customWorkspaces,
        );
        DockColumnLayout? resize(DockColumnLayout? column) =>
            column == null
                ? null
                : DockColumnLayout(
                  width: width,
                  collapsed: column.collapsed,
                  groups: column.groups,
                );
        final updated = WorkspaceLayout(
          id: current.id,
          name: current.name,
          kind: current.kind,
          left: left ? resize(current.left) : current.left,
          right: left ? current.right : resize(current.right),
          commandBar: current.commandBar,
        );
        final overrides = Map<String, WorkspaceLayout>.from(
          preferences.workspaceOverrides,
        )..[preferences.workspaceId] = updated;
        _persistWorkspacePreferences(
          dockWidth: left ? null : width,
          leftDockWidth: left ? width : null,
          workspaceOverrides: overrides,
        );
        return;
      }
      _persistWorkspacePreferences(
        dockWidth: left ? null : width,
        leftDockWidth: left ? width : null,
      );
      return;
    }
    final updated = [...preferences.customWorkspaces];
    final current = updated[customIndex];
    DockColumnLayout? resize(DockColumnLayout? column) =>
        column == null
            ? null
            : DockColumnLayout(
              width: width,
              collapsed: column.collapsed,
              groups: column.groups,
            );
    updated[customIndex] = WorkspaceLayout(
      id: current.id,
      name: current.name,
      kind: current.kind,
      left: left ? resize(current.left) : current.left,
      right: left ? current.right : resize(current.right),
      commandBar: current.commandBar,
    );
    _persistWorkspacePreferences(
      customWorkspaces: updated,
      dockWidth: left ? null : width,
      leftDockWidth: left ? width : null,
    );
  }

  WorkspaceLayout _workspaceLayoutFor(
    String id,
    List<WorkspaceLayout> customWorkspaces,
  ) {
    final override = widget.workspacePreferences?.workspaceOverrides[id];
    if (override != null) return override;
    return switch (id) {
      'comic' => comicWorkspace,
      'minimal' => minimalWorkspace,
      'illustration' => illustrationWorkspace,
      _ =>
        customWorkspaces.where((layout) => layout.id == id).firstOrNull ??
            illustrationWorkspace,
    };
  }

  String? _paletteName(InkPaletteId? palette) => switch (palette) {
    InkPaletteId.toolGroups => 'tools',
    InkPaletteId.brushPresets => 'brushes',
    InkPaletteId.toolProperties => 'properties',
    InkPaletteId.color => 'color',
    InkPaletteId.layers => 'layers',
    InkPaletteId.materials => 'materials',
    InkPaletteId.comics => 'comics',
    InkPaletteId.history => 'history',
    InkPaletteId.quickAccess => 'quickAccess',
    null => null,
  };

  String _paletteLabel(String tab) => switch (tab) {
    'tools' => 'Tool groups',
    'brushes' => 'Brush presets',
    'properties' => 'Tool properties',
    'color' => 'Color',
    'layers' => 'Layers',
    'materials' => 'Materials',
    'comics' => 'Comics',
    'history' => 'History',
    'quickAccess' => 'Quick Access',
    _ => 'Palette',
  };

  void _selectWorkspace(String workspaceId, {bool manual = true}) {
    final preferences =
        widget.workspacePreferences ?? const WorkspacePreferences();
    final layout = _workspaceLayoutFor(
      workspaceId,
      preferences.customWorkspaces,
    );
    final isCustomWorkspace = preferences.customWorkspaces.any(
      (workspace) => workspace.id == workspaceId,
    );
    final rightPalette = _paletteName(
      layout.right?.groups.firstOrNull?.activeTab,
    );
    final leftPalette = _paletteName(
      layout.left?.groups.firstOrNull?.activeTab,
    );
    setState(() {
      _workspaceDockCollapsed = layout.right?.collapsed ?? layout.right == null;
      _workspaceLeftDockCollapsed =
          layout.left?.collapsed ?? layout.left == null;
      _workspaceDockWidth =
          (isCustomWorkspace
                  ? layout.right?.width ?? preferences.dockWidth
                  : workspaceId == 'comic'
                  ? layout.right?.width ?? 400
                  : preferences.dockWidth)
              .clamp(220, 480)
              .toDouble();
      _workspaceLeftDockWidth =
          (isCustomWorkspace
                  ? layout.left?.width ?? preferences.leftDockWidth
                  : preferences.leftDockWidth)
              .clamp(220, 480)
              .toDouble();
      _desktopDockTab = rightPalette ?? 'layers';
      _leftDockTab = leftPalette ?? 'tools';
      _leftDockGroups = layout.left?.groups ?? const [];
      _rightDockGroups = layout.right?.groups ?? const [];
    });
    _persistWorkspacePreferences(
      workspaceId: workspaceId,
      lastDock: _desktopDockTab,
      followDocumentType:
          manual
              ? false
              : (widget.workspacePreferences?.followDocumentType ?? true),
    );
  }

  Future<void> _setFollowDocumentType(bool enabled) async {
    _persistWorkspacePreferences(followDocumentType: enabled);
    if (!enabled) return;
    final workspaceId =
        _comicWorkspace.snapshot == null ? 'illustration' : 'comic';
    _selectWorkspace(workspaceId, manual: false);
  }

  Future<void> _renameWorkspace(String id) async {
    final preferences =
        widget.workspacePreferences ?? const WorkspacePreferences();
    final index = preferences.customWorkspaces.indexWhere(
      (layout) => layout.id == id,
    );
    if (index < 0) return;
    final controller = TextEditingController(
      text: preferences.customWorkspaces[index].name,
    );
    final name = await showDialog<String>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('Rename workspace'),
            content: TextField(
              controller: controller,
              autofocus: true,
              maxLength: 64,
              decoration: const InputDecoration(labelText: 'Workspace name'),
              onSubmitted: (value) => Navigator.pop(dialogContext, value),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, controller.text),
                child: const Text('Rename'),
              ),
            ],
          ),
    );
    controller.dispose();
    final normalized = name?.trim();
    if (!mounted ||
        normalized == null ||
        normalized.isEmpty ||
        normalized.length > 64) {
      return;
    }
    final updated = [...preferences.customWorkspaces];
    updated[index] = WorkspaceLayout(
      id: updated[index].id,
      name: normalized,
      kind: WorkspacePresetKind.custom,
      left: updated[index].left,
      right: updated[index].right,
      commandBar: updated[index].commandBar,
    );
    _persistWorkspacePreferences(customWorkspaces: updated);
  }

  Future<void> _deleteWorkspace(String id) async {
    final preferences =
        widget.workspacePreferences ?? const WorkspacePreferences();
    final workspace =
        preferences.customWorkspaces
            .where((layout) => layout.id == id)
            .firstOrNull;
    if (workspace == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('Delete workspace?'),
            content: Text(
              '“${workspace.name}” will be removed from this device.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Delete'),
              ),
            ],
          ),
    );
    if (!mounted || confirmed != true) return;
    final remaining = preferences.customWorkspaces
        .where((layout) => layout.id != id)
        .toList(growable: false);
    if (preferences.workspaceId == id) {
      _selectWorkspace('illustration', manual: false);
    }
    _persistWorkspacePreferences(customWorkspaces: remaining);
  }

  Future<void> _saveWorkspaceAs() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('Save workspace as'),
            content: TextField(
              controller: controller,
              autofocus: true,
              maxLength: 64,
              decoration: const InputDecoration(labelText: 'Workspace name'),
              onSubmitted:
                  (value) => Navigator.pop(dialogContext, value.trim()),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed:
                    () => Navigator.pop(dialogContext, controller.text.trim()),
                child: const Text('Save'),
              ),
            ],
          ),
    );
    controller.dispose();
    final normalized = name?.trim();
    if (!mounted ||
        normalized == null ||
        normalized.isEmpty ||
        normalized.length > 64) {
      return;
    }
    final preferences =
        widget.workspacePreferences ?? const WorkspacePreferences();
    if (preferences.customWorkspaces.length >= 12) return;
    final id = 'custom-${DateTime.now().microsecondsSinceEpoch}';
    final selectedLayout = switch (preferences.workspaceId) {
      'comic' => comicWorkspace,
      'minimal' => minimalWorkspace,
      _ =>
        preferences.customWorkspaces
                .where((layout) => layout.id == preferences.workspaceId)
                .firstOrNull ??
            illustrationWorkspace,
    };
    final rightGroups =
        _rightDockGroups.isNotEmpty
            ? _rightDockGroups
            : selectedLayout.right?.groups ?? const <DockGroupLayout>[];
    final activeRight = _paletteForDockTab(_desktopDockTab);
    final savedRightGroups =
        rightGroups.isEmpty
            ? [
              DockGroupLayout(tabs: [activeRight], activeTab: activeRight),
            ]
            : [
              DockGroupLayout(
                flex: rightGroups.first.flex,
                tabs:
                    rightGroups.first.tabs.contains(activeRight)
                        ? rightGroups.first.tabs
                        : [
                          ...rightGroups.first.tabs,
                          activeRight,
                        ].take(8).toList(),
                activeTab: activeRight,
              ),
              ...rightGroups.skip(1),
            ];
    final custom = WorkspaceLayout(
      id: id,
      name: normalized,
      kind: WorkspacePresetKind.custom,
      left:
          selectedLayout.left == null
              ? null
              : DockColumnLayout(
                width: _workspaceLeftDockWidth,
                collapsed: _workspaceLeftDockCollapsed,
                groups:
                    _leftDockGroups.isNotEmpty
                        ? _leftDockGroups
                        : selectedLayout.left!.groups,
              ),
      right: DockColumnLayout(
        width: _workspaceDockWidth,
        collapsed: selectedLayout.right?.collapsed ?? false,
        groups: savedRightGroups,
      ),
      commandBar: _effectiveCommandBarItems(),
    );
    _persistWorkspacePreferences(
      workspaceId: id,
      customWorkspaces: [...preferences.customWorkspaces, custom],
    );
  }

  Future<void> _resetBuiltInWorkspace(String workspaceId) async {
    if (!const {'illustration', 'comic', 'minimal'}.contains(workspaceId)) {
      return;
    }
    final accepted = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('Reset workspace layout?'),
            content: const Text(
              'This restores the built-in dock groups, widths, and command bar. '
              'Your artwork and editor state will not change.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Reset layout'),
              ),
            ],
          ),
    );
    if (accepted != true || !mounted) return;

    final preferences =
        widget.workspacePreferences ?? const WorkspacePreferences();
    final workspaceOverrides = Map<String, WorkspaceLayout>.from(
      preferences.workspaceOverrides,
    )..remove(workspaceId);
    final commandBarOverrides = Map<String, List<String>>.from(
      preferences.commandBarOverrides,
    )..remove(workspaceId);
    final defaultLayout = switch (workspaceId) {
      'comic' => comicWorkspace,
      'minimal' => minimalWorkspace,
      _ => illustrationWorkspace,
    };
    final isCurrentWorkspace = preferences.workspaceId == workspaceId;
    if (isCurrentWorkspace) {
      setState(() {
        _workspaceDockWidth = defaultLayout.right?.width ?? 360;
        _workspaceLeftDockWidth = defaultLayout.left?.width ?? 248;
        _workspaceDockCollapsed = defaultLayout.right == null;
        _workspaceLeftDockCollapsed = defaultLayout.left == null;
        _rightDockGroups = defaultLayout.right?.groups ?? const [];
        _leftDockGroups = defaultLayout.left?.groups ?? const [];
        _desktopDockTab =
            _paletteName(defaultLayout.right?.groups.firstOrNull?.activeTab) ??
            'layers';
        _leftDockTab =
            _paletteName(defaultLayout.left?.groups.firstOrNull?.activeTab) ??
            'tools';
      });
    }
    _persistWorkspacePreferences(
      dockWidth: isCurrentWorkspace ? defaultLayout.right?.width ?? 360 : null,
      leftDockWidth:
          isCurrentWorkspace ? defaultLayout.left?.width ?? 248 : null,
      workspaceOverrides: workspaceOverrides,
      commandBarOverrides: commandBarOverrides,
    );
  }

  InkPaletteId _paletteForDockTab(String tab) => switch (tab) {
    'tools' => InkPaletteId.toolGroups,
    'brushes' => InkPaletteId.brushPresets,
    'properties' => InkPaletteId.toolProperties,
    'materials' => InkPaletteId.materials,
    'comics' => InkPaletteId.comics,
    'quickAccess' => InkPaletteId.quickAccess,
    'history' => InkPaletteId.history,
    'color' => InkPaletteId.color,
    _ => InkPaletteId.layers,
  };

  void _toggleTabletWorkspaceMode() {
    final current =
        widget.workspacePreferences?.tabletMode ?? TabletWorkspaceMode.simple;
    final enteringStudio = current == TabletWorkspaceMode.simple;
    setState(() {
      _showLayers = enteringStudio;
      if (enteringStudio) {
        _showTools = false;
        _showBrushes = false;
        _showComics = false;
      }
    });
    _persistWorkspacePreferences(
      tabletMode:
          enteringStudio
              ? TabletWorkspaceMode.studio
              : TabletWorkspaceMode.simple,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    if (_canvasDiagnostics.isRecording) {
      unawaited(_canvasDiagnostics.stopCapture(reason: 'canvas_disposed'));
    }
    for (final draftId in _activeBrushDrafts.values) {
      unawaited(
        widget.engine.cancelBrushDraft(draftId).catchError((Object error) {
          debugPrint('Project Ink brush draft cleanup failed: $error');
        }),
      );
    }
    _activeBrushDrafts.clear();
    _brushEditQueues.clear();
    _tilePollTimer?.cancel();
    _quickBrushSizeTimer?.cancel();
    final liveSurface = _livePreviewSurface;
    _livePreviewSurface = null;
    if (liveSurface != null) {
      liveSurface.gpuFrameReady.removeListener(_onLiveFrameReadinessChanged);
      unawaited(_queueLiveSurfaceDisposal(liveSurface));
    }
    _touchLongPressTimer?.cancel();
    _stylusHoldTimer?.cancel();
    unawaited(_nativePointerSubscription?.cancel());
    unawaited(_nativePointerStatusSubscription?.cancel());
    unawaited(_nativePencilCommandSubscription?.cancel());
    unawaited(_nativeCanvasDiagnosticSubscription?.cancel());
    _tileImages.dispose();
    _setStrokePreview(null);
    _strokePreview.dispose();
    _comicWorkspace.removeListener(_onComicWorkspaceChanged);
    _comicWorkspace.dispose();
    super.dispose();
  }

  void _onComicWorkspaceChanged() {
    if (!mounted || _comicChangeScheduled) return;
    if (_comicClipPanelId != null &&
        _comicWorkspace.pagePreviewIndex != _comicClipPageIndex) {
      unawaited(_clearSelection());
    }
    // ComicWorkspace starts its Rust-backed load from initState. Its first
    // notification can arrive while CanvasScreen is still building the dock;
    // defer one coalesced rebuild to the next frame instead of calling
    // setState from inside the build phase.
    _comicChangeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _comicChangeScheduled = false;
      if (!mounted) return;
      setState(() {});
      if (widget.workspacePreferences?.followDocumentType == true) {
        _selectWorkspace(
          _comicWorkspace.snapshot == null ? 'illustration' : 'comic',
          manual: false,
        );
      }
    });
  }

  void _handlePointer(PointerEvent event) {
    final packetArrivalUs =
        _canvasDiagnostics.isRecording
            ? _canvasDiagnostics.elapsedMicroseconds
            : null;
    if (event.kind == PointerDeviceKind.touch &&
        (event is PointerDownEvent ||
            event is PointerUpEvent ||
            event is PointerCancelEvent)) {
      _canvasDiagnostics.record('input.flutter_touch_boundary', {
        'pointerId': event.pointer,
        'phase':
            event is PointerDownEvent
                ? 'down'
                : event is PointerUpEvent
                ? 'up'
                : 'cancel',
        'strokeActive': _strokeActive,
        'activeStrokeIsTouch': _activeStrokeIsTouch,
        'touchPreviewActive': _touchDrawingStrokeActive,
        'activeTouchPointerCount': _activeTouchPointers.length,
        'trackedTouchCount': _touchDown.length,
        'singleFingerNavigation': _singleFingerNavigation,
        'nativePencilContactActive': _nativePencilContactActive,
        'x': event.localPosition.dx,
        'y': event.localPosition.dy,
      });
    }
    if (event.kind == PointerDeviceKind.touch && _nativePencilContactActive) {
      // UIKit reports Pencil and palm contacts simultaneously. Ignore finger
      // input for the duration of Pencil contact to prevent palm marks and
      // accidental gesture recognition.
      return;
    }
    if (event is PointerDownEvent || event is PointerMoveEvent) {
      _pointers[event.pointer] = event.localPosition;
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _pointers.remove(event.pointer);
    }
    if (event.kind == PointerDeviceKind.touch) {
      _recordTouchGesture(event);
    }
    // Sampling is a one-shot command. Consume the pointer-down before the
    // drawing pipeline so the eyedropper never creates a zero-length stroke.
    if (_colorSamplerArmed &&
        event is PointerDownEvent &&
        (event.kind == PointerDeviceKind.mouse ||
            event.kind == PointerDeviceKind.stylus ||
            event.kind == PointerDeviceKind.invertedStylus)) {
      _colorSamplerArmed = false;
      unawaited(_sampleCanvasColor(event.localPosition));
      return;
    }
    if (_activeTool != IllustrationTool.brush &&
        _activeTool != IllustrationTool.eraser &&
        (event.kind == PointerDeviceKind.stylus ||
            event.kind == PointerDeviceKind.invertedStylus ||
            event.kind == PointerDeviceKind.mouse ||
            event.kind == PointerDeviceKind.touch)) {
      _enqueueStrokeWork(() => _handleToolEventSafely(event));
      return;
    }
    if (event.kind == PointerDeviceKind.touch) {
      if (_touchDown.length > 1) {
        _cancelTouchDrawingStroke(reason: 'second_touch_during_stroke');
        return;
      }
      final canStartTouchStroke =
          event is PointerDownEvent &&
          !_singleFingerNavigation &&
          !_strokeActive;
      if (_touchDrawingStrokeActive || canStartTouchStroke) {
        if (canStartTouchStroke) _touchDrawingStrokeActive = true;
        final sourceSequence = _nextPointerSequence();
        final preparedPosition = _applyStrokeConstraint(
          _safeInputPosition(_canvasPosition(event.localPosition)),
          hasDown: event is PointerDownEvent,
        );
        final previewIndex = _updateStrokePreview(
          preparedPosition,
          isDown: event is PointerDownEvent,
          isUp: event is PointerUpEvent || event is PointerCancelEvent,
          pressure: _pointerPressure(event),
          sourceSequence: sourceSequence,
        );
        _canvasDiagnostics.record('canvas.live_input_accepted', {
          'device': 'touch',
          'confirmedSamples': 1,
          'confirmedPreviewIndexStart': previewIndex,
          'confirmedPreviewIndexEnd': previewIndex,
          'firstConfirmedSequence': sourceSequence,
          'lastConfirmedSequence': sourceSequence,
          'renderer': 'flutter_canvas',
          if (packetArrivalUs != null) 'packetArrivalUs': packetArrivalUs,
        });
        _scheduleLivePreviewFrameDiagnostic();
        _enqueueStrokeWork(
          () => _handleDrawingEventSafely(
            event,
            sourceSequence,
            preparedPosition,
          ),
        );
        if (event is PointerUpEvent || event is PointerCancelEvent) {
          _touchDrawingStrokeActive = false;
        }
      }
      return;
    }
    final usesGenericDrawingInput =
        (!_nativePointerEnabled &&
            (event.kind == PointerDeviceKind.stylus ||
                event.kind == PointerDeviceKind.invertedStylus)) ||
        event.kind == PointerDeviceKind.mouse;
    if (usesGenericDrawingInput) {
      // Keep visual feedback on Flutter's synchronous pointer path. Rust
      // packet submission remains serialized, but the cursor must not wait
      // behind older bridge calls to feel like a pencil.
      final previewStarted =
          widget.onPerformanceSnapshot == null
              ? null
              : _performanceTrace.nowMicros;
      final sourceSequence = _nextPointerSequence();
      final preparedPosition = _applyStrokeConstraint(
        _safeInputPosition(_canvasPosition(event.localPosition)),
        hasDown: event is PointerDownEvent,
      );
      final previewIndex = _updateStrokePreview(
        preparedPosition,
        isDown: event is PointerDownEvent,
        isUp: event is PointerUpEvent || event is PointerCancelEvent,
        pressure: _pointerPressure(event),
        sourceSequence: sourceSequence,
      );
      _canvasDiagnostics.record('canvas.live_input_accepted', {
        'device': event.kind.name,
        'confirmedSamples': 1,
        'confirmedPreviewIndexStart': previewIndex,
        'confirmedPreviewIndexEnd': previewIndex,
        'firstConfirmedSequence': sourceSequence,
        'lastConfirmedSequence': sourceSequence,
        'renderer': 'flutter_canvas',
        if (packetArrivalUs != null) 'packetArrivalUs': packetArrivalUs,
      });
      _scheduleLivePreviewFrameDiagnostic();
      if (previewStarted != null) {
        _performanceTrace.markPreviewUpdate(startedMicros: previewStarted);
      }
      _enqueueStrokeWork(
        () =>
            _handleDrawingEventSafely(event, sourceSequence, preparedPosition),
      );
    }
  }

  /// Serializes pointer work while ensuring one unexpected asynchronous error
  /// cannot leave `_strokeWork` permanently failed. Without this recovery,
  /// every later `.then` callback is skipped and subsequent strokes appear to
  /// vanish even though the input adapter continues delivering events.
  void _enqueueStrokeWork(Future<void> Function() operation) {
    _strokeOperations.add(operation);
    if (_drainingStrokeOperations) return;
    _drainingStrokeOperations = true;
    _strokeWork = _drainStrokeOperations();
  }

  Future<void> _drainStrokeOperations() async {
    while (_strokeOperations.isNotEmpty) {
      final operation = _strokeOperations.removeFirst();
      try {
        await operation();
      } catch (error, stack) {
        debugPrint(
          'Project Ink stroke queue recovered from error: $error\n$stack',
        );
        try {
          await _abortStrokeAfterPacketError();
        } catch (recoveryError, recoveryStack) {
          // Keep the serial queue usable even if recovery itself encounters a
          // disposed platform handle. The following pointer-down starts a
          // fresh engine transaction or reports its own concrete failure.
          debugPrint(
            'Project Ink stroke queue recovery failed: '
            '$recoveryError\n$recoveryStack',
          );
        }
      }
    }
    _drainingStrokeOperations = false;
    if (_strokeOperations.isNotEmpty) {
      _drainingStrokeOperations = true;
      _strokeWork = _drainStrokeOperations();
    }
  }

  void _handleEditorFocusChanged(bool hasFocus) {
    if (hasFocus || !_strokeActive) return;

    // Desktop platforms may lose pointer capture when the cursor leaves the
    // window or another application becomes active. If the matching release
    // never reaches Flutter, cancel the unfinished transaction so it cannot
    // block subsequent commands. Serialize after all already-received input.
    _enqueueStrokeWork(_abortStrokeAfterPacketError);
  }

  double _pointerPressure(PointerEvent event) {
    // Flutter reports no meaningful pressure for a conventional mouse. A
    // zero-pressure mouse packet is still valid input, but pressure-sensitive
    // brushes multiply opacity by it and become invisible. Treat mouse input
    // as a firm stroke while preserving the native stylus value unchanged.
    if (event.kind == PointerDeviceKind.mouse) return 1.0;
    final pressure = event.pressure;
    if (!pressure.isFinite) return 1.0;
    // Normalize the platform value to this pointer's reported range. Some
    // touchscreens expose no force data and report a fixed 1.0 range; those
    // correctly fall back to a solid, constant-width finger stroke.
    final range = event.pressureMax - event.pressureMin;
    if (range <= 0 || !range.isFinite) {
      if (event.kind == PointerDeviceKind.touch) {
        // This iPad reports no finger force. Approximate it from the touch
        // contact patch: a larger contact area usually means a firmer press.
        // It is intentionally a proxy, since finger angle also changes it.
        final major = event.radiusMajor;
        final minor = event.radiusMinor > 0 ? event.radiusMinor : major;
        if (major.isFinite && minor.isFinite && major > 0 && minor > 0) {
          final contactRadius = math.sqrt(major * minor);
          return ((contactRadius - 5.0) / 13.0).clamp(0.0, 1.0).toDouble();
        }
      }
      return 1.0;
    }
    return ((pressure - event.pressureMin) / range).clamp(0.0, 1.0).toDouble();
  }

  Future<void> _handleToolEventSafely(PointerEvent event) async {
    try {
      await _handleToolEvent(event);
    } catch (error, stack) {
      debugPrint('Project Ink tool event rejected: $error\n$stack');
      if (mounted) setState(() => _toolPoints = const []);
    }
  }

  Future<void> _handleToolEvent(PointerEvent event) async {
    final isDown = event is PointerDownEvent;
    final isUp = event is PointerUpEvent || event is PointerCancelEvent;
    final position = _canvasPosition(event.localPosition);
    final isRuler = _activeTool.name.endsWith('Ruler');
    final isPerspectiveTransform =
        _activeTool == IllustrationTool.perspectiveTransform;
    final isMeshTransform = _activeTool == IllustrationTool.meshTransform;
    final isLiquify = _activeTool == IllustrationTool.liquify;
    final isVectorPen = _activeTool == IllustrationTool.vectorPen;
    final isVectorTransform = _activeTool == IllustrationTool.vectorTransform;
    final isVectorEraser = _activeTool == IllustrationTool.vectorEraser;
    if (_activeTool == IllustrationTool.layerOpacitySelect && isDown) {
      await widget.engine.selectLayerOpacity(
        layerId: widget.engine.documentInfo.primaryRasterLayer,
        minimumAlpha: 1,
      );
      if (mounted) {
        setState(() {
          _selectionGeometry = null;
          _selectionGeometryTool = _activeTool;
        });
      }
      return;
    }
    if (_activeTool == IllustrationTool.colorRangeSelect && isDown) {
      await _chooseColorRange();
      return;
    }
    if (_activeTool == IllustrationTool.fill && isDown) {
      await _chooseFill(position);
      return;
    }
    if (isDown) {
      _toolStart = position;
      _toolPoints = [position];
      _toolVectorPoints =
          isVectorPen
              ? <double>[position.dx, position.dy, _pointerPressure(event), 0.0]
              : const [];
      if (isRuler) {
        _rulerStart = position;
        _rulerEnd = position;
        _rulerTool = _activeTool;
      }
      if (mounted) setState(() {});
      return;
    }
    if (event is PointerMoveEvent && _toolStart != null) {
      if (isRuler) {
        _rulerEnd = position;
      } else if (_activeTool == IllustrationTool.lassoSelect) {
        _toolPoints = [
          ..._toolPoints,
          position,
        ].take(1024).toList(growable: false);
      } else if (isPerspectiveTransform || isMeshTransform || isLiquify) {
        _selectionGeometry = Rect.fromPoints(_toolStart!, position);
        _selectionGeometryTool = _activeTool;
      } else if ((isVectorPen || isVectorTransform || isVectorEraser) &&
          (_toolPoints.isEmpty ||
              (_toolPoints.last - position).distance >= 0.5)) {
        _toolPoints = [
          ..._toolPoints,
          position,
        ].take(8192).toList(growable: false);
        if (isVectorPen) {
          final pressure = _pointerPressure(event);
          _toolVectorPoints = [
            ..._toolVectorPoints,
            position.dx,
            position.dy,
            pressure,
            0.0,
          ].take(8192 * 4).toList(growable: false);
        }
      }
      if (mounted) setState(() {});
      return;
    }
    if (!isUp || _toolStart == null) return;
    final start = _toolStart!;
    final end = position;
    final tool = _activeTool;
    _toolStart = null;
    if (tool == IllustrationTool.rectangleSelect) {
      final rect = Rect.fromPoints(start, end);
      await widget.engine.selectRectangle(
        x0: rect.left,
        y0: rect.top,
        x1: rect.right,
        y1: rect.bottom,
      );
      _selectionGeometry = rect;
      _selectionGeometryTool = tool;
    } else if (tool == IllustrationTool.ellipseSelect) {
      final rect = Rect.fromPoints(start, end);
      await widget.engine.selectEllipse(
        centerX: rect.center.dx,
        centerY: rect.center.dy,
        radiusX: rect.width / 2,
        radiusY: rect.height / 2,
      );
      _selectionGeometry = rect;
      _selectionGeometryTool = tool;
    } else if (tool == IllustrationTool.lassoSelect) {
      final points = [..._toolPoints, end];
      await widget.engine.selectLasso(
        points.expand((point) => [point.dx, point.dy]).toList(growable: false),
      );
      _selectionGeometry = null;
      _selectionGeometryTool = tool;
    } else if (tool == IllustrationTool.transform) {
      final delta = end - start;
      if (delta.distance >= 0.5) {
        await widget.engine.transformLayer(
          layerId: widget.engine.documentInfo.primaryRasterLayer,
          a: 1,
          b: 0,
          c: 0,
          d: 1,
          tx: delta.dx,
          ty: delta.dy,
        );
      }
    } else if (tool == IllustrationTool.perspectiveTransform) {
      final rect = Rect.fromPoints(start, end);
      if (rect.width >= 2 && rect.height >= 2) {
        await widget.engine.perspectiveLayer(
          layerId: widget.engine.documentInfo.primaryRasterLayer,
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
        _selectionGeometry = rect;
        _selectionGeometryTool = tool;
      }
    } else if (tool == IllustrationTool.meshTransform) {
      final rect = Rect.fromPoints(start, end);
      if (rect.width >= 2 && rect.height >= 2) {
        await _chooseMeshTransform(rect);
        _selectionGeometry = rect;
        _selectionGeometryTool = tool;
      }
    } else if (tool == IllustrationTool.liquify) {
      final delta = end - start;
      final radius = math.max(24.0, delta.distance);
      if (delta.distance >= 1) {
        await _chooseLiquify(start, delta, radius);
        _selectionGeometry = Rect.fromCircle(center: start, radius: radius);
        _selectionGeometryTool = tool;
      }
    } else if (tool == IllustrationTool.vectorPen) {
      final layerId = _selectedVectorLayerId;
      if (layerId == null || _toolVectorPoints.length < 4) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Add a vector layer before drawing vector ink.'),
            ),
          );
        }
      } else {
        await widget.engine.addVectorStroke(
          layerId: layerId,
          points: _toolVectorPoints,
          closed: false,
        );
        widget.autosave?.markDirty();
      }
    } else if (tool == IllustrationTool.vectorTransform) {
      final stroke = _vectorStrokes.firstOrNull;
      final layerId = _selectedVectorLayerId;
      final delta = end - start;
      if (stroke != null && layerId != null && delta.distance >= 0.5) {
        await widget.engine.transformVectorStroke(
          layerId: layerId,
          strokeId: stroke.id,
          a: 1,
          b: 0,
          c: 0,
          d: 1,
          tx: delta.dx,
          ty: delta.dy,
        );
        await _loadVectorStrokesForSelection();
        widget.autosave?.markDirty();
      }
    } else if (tool == IllustrationTool.vectorEraser) {
      final stroke = _vectorStrokes.firstOrNull;
      final layerId = _selectedVectorLayerId;
      final radius = math.max(4.0, (end - start).distance);
      if (stroke != null && layerId != null) {
        await widget.engine.eraseVectorSegment(
          layerId: layerId,
          strokeId: stroke.id,
          centerX: end.dx,
          centerY: end.dy,
          radius: radius,
        );
        await _loadVectorStrokesForSelection();
        widget.autosave?.markDirty();
      }
    } else if (isRuler) {
      _rulerStart = start;
      _rulerEnd = end;
      _rulerTool = tool;
    }
    _toolPoints = const [];
    _toolVectorPoints = const [];
    widget.autosave?.markDirty(restartTimer: false);
    if (mounted) setState(() {});
  }

  Future<void> _clearSelection() async {
    try {
      await widget.engine.clearSelection();
      if (mounted) {
        setState(() {
          _selectionGeometry = null;
          _selectionGeometryTool = null;
          _toolPoints = const [];
          _toolVectorPoints = const [];
          _comicClipPanelId = null;
          _comicClipPageIndex = null;
        });
      }
    } catch (error, stack) {
      debugPrint('Project Ink selection clear failed: $error\n$stack');
    }
  }

  Future<void> _modifySelection(SelectionEdit edit) async {
    try {
      switch (edit) {
        case SelectionEdit.invert:
          await widget.engine.invertSelection();
        case SelectionEdit.grow:
          await widget.engine.growSelection(1);
        case SelectionEdit.shrink:
          await widget.engine.shrinkSelection(1);
      }
      if (mounted) setState(() {});
    } catch (error, stack) {
      debugPrint('Project Ink selection update failed: $error\n$stack');
    }
  }

  /// Keep the active single-page canvas document's persisted panel masks in
  /// sync with comic metadata edits. The comic navigator remains a structural
  /// projection, while this callback updates the real Rust layer tree before
  /// the next stroke is accepted.
  Future<void> _syncComicPanelGeometry(rust.ComicProjectView snapshot) async {
    final pageIndex = _comicWorkspace.activePageIndex;
    if (pageIndex < 0 || pageIndex >= snapshot.pages.length) return;
    final page = snapshot.pages[pageIndex];
    if (page.widthPx <= 0 || page.heightPx <= 0) return;
    final scaleX = widget.engine.documentInfo.widthPx / page.widthPx;
    final scaleY = widget.engine.documentInfo.heightPx / page.heightPx;
    for (final panel in page.panels) {
      final panelGroupId = panel.panelGroupId;
      final maskLayerId = panel.maskLayerId;
      final sketchLayerId = panel.sketchLayerId;
      final inkLayerId = panel.inkLayerId;
      final colorLayerId = panel.colorLayerId;
      final toneLayerId = panel.toneLayerId;
      final effectsLayerId = panel.effectsLayerId;
      if (panelGroupId == null ||
          maskLayerId == null ||
          sketchLayerId == null ||
          inkLayerId == null ||
          colorLayerId == null ||
          toneLayerId == null ||
          effectsLayerId == null) {
        continue;
      }
      final sourcePoints =
          panel.polygon.length >= 6 && panel.polygon.length.isEven
              ? panel.polygon
              : <double>[
                panel.x,
                panel.y,
                panel.x + panel.width,
                panel.y,
                panel.x + panel.width,
                panel.y + panel.height,
                panel.x,
                panel.y + panel.height,
              ];
      final points = <double>[];
      for (var index = 0; index < sourcePoints.length; index += 2) {
        points.add(
          (sourcePoints[index] * scaleX).clamp(
            0.0,
            widget.engine.documentInfo.widthPx.toDouble(),
          ),
        );
        points.add(
          (sourcePoints[index + 1] * scaleY).clamp(
            0.0,
            widget.engine.documentInfo.heightPx.toDouble(),
          ),
        );
      }
      await widget.engine.createPanelLayerTree(
        panelId: panel.id.toInt(),
        panelGroupId: widget.engine.layerIdForUi(panelGroupId),
        maskLayerId: widget.engine.layerIdForUi(maskLayerId),
        sketchLayerId: widget.engine.layerIdForUi(sketchLayerId),
        inkLayerId: widget.engine.layerIdForUi(inkLayerId),
        colorLayerId: widget.engine.layerIdForUi(colorLayerId),
        toneLayerId: widget.engine.layerIdForUi(toneLayerId),
        effectsLayerId: widget.engine.layerIdForUi(effectsLayerId),
      );
      await widget.engine.setPanelMaskGeometry(
        maskLayerId: widget.engine.layerIdForUi(maskLayerId),
        points: points,
      );
    }
  }

  /// Constrain raster input to the selected comic panel. The panel model is
  /// page-space metadata while the active canvas may use a different pixel
  /// size, so coordinates are scaled at this boundary before Rust builds the
  /// authoritative selection mask. Tapping the same panel again releases the
  /// constraint through the normal selection command path.
  Future<void> _drawInsideComicPanel(
    int pageIndex,
    rust.ComicPanelPreviewView panel,
  ) async {
    final samePanel =
        _comicClipPageIndex == pageIndex && _comicClipPanelId == panel.id;
    try {
      if (samePanel) {
        await _clearSelection();
        return;
      }
      final snapshot = _comicWorkspace.snapshot;
      if (snapshot == null ||
          pageIndex < 0 ||
          pageIndex >= snapshot.pages.length) {
        return;
      }
      final page = snapshot.pages[pageIndex];
      if (page.widthPx <= 0 || page.heightPx <= 0) return;
      final scaleX = widget.engine.documentInfo.widthPx / page.widthPx;
      final scaleY = widget.engine.documentInfo.heightPx / page.heightPx;
      final sourcePoints =
          panel.polygon.length >= 6 && panel.polygon.length.isEven
              ? panel.polygon
              : <double>[
                panel.x,
                panel.y,
                panel.x + panel.width,
                panel.y,
                panel.x + panel.width,
                panel.y + panel.height,
                panel.x,
                panel.y + panel.height,
              ];
      final points = <double>[];
      for (var index = 0; index < sourcePoints.length; index += 2) {
        points.add(
          (sourcePoints[index] * scaleX).clamp(
            0.0,
            widget.engine.documentInfo.widthPx.toDouble(),
          ),
        );
        points.add(
          (sourcePoints[index + 1] * scaleY).clamp(
            0.0,
            widget.engine.documentInfo.heightPx.toDouble(),
          ),
        );
      }
      // Materialize the panel-owned layer tree before constraining input. The
      // panel guide is only a visual aid; the selected Ink child is now a
      // real Rust layer, so strokes cannot land behind an opaque preview.
      final panelGroupId = panel.panelGroupId;
      final maskLayerId = panel.maskLayerId;
      final sketchLayerId = panel.sketchLayerId;
      final inkLayerId = panel.inkLayerId;
      final colorLayerId = panel.colorLayerId;
      final toneLayerId = panel.toneLayerId;
      final effectsLayerId = panel.effectsLayerId;
      if (panelGroupId != null &&
          maskLayerId != null &&
          sketchLayerId != null &&
          inkLayerId != null &&
          colorLayerId != null &&
          toneLayerId != null &&
          effectsLayerId != null) {
        await widget.engine.createPanelLayerTree(
          panelId: panel.id.toInt(),
          panelGroupId: widget.engine.layerIdForUi(panelGroupId),
          maskLayerId: widget.engine.layerIdForUi(maskLayerId),
          sketchLayerId: widget.engine.layerIdForUi(sketchLayerId),
          inkLayerId: widget.engine.layerIdForUi(inkLayerId),
          colorLayerId: widget.engine.layerIdForUi(colorLayerId),
          toneLayerId: widget.engine.layerIdForUi(toneLayerId),
          effectsLayerId: widget.engine.layerIdForUi(effectsLayerId),
        );
        await widget.engine.setPanelMaskGeometry(
          maskLayerId: widget.engine.layerIdForUi(maskLayerId),
          points: points,
        );
        await _loadPhase2Projections();
        _layerSelection.select(widget.engine.layerIdForUi(inkLayerId));
      }
      await widget.engine.selectLasso(points);
      if (!mounted) return;
      setState(() {
        _comicClipPageIndex = pageIndex;
        _comicClipPanelId = panel.id;
        _selectionGeometry = null;
        _selectionGeometryTool = null;
      });
    } catch (error, stack) {
      debugPrint('Project Ink panel clip failed: $error\n$stack');
    }
  }

  Future<void> _chooseColorRange() async {
    final red = TextEditingController(text: '0');
    final green = TextEditingController(text: '0');
    final blue = TextEditingController(text: '0');
    final tolerance = TextEditingController(text: '80');
    final accepted = await showDialog<String>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('Select color range'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _boundedNumberField('Red', red),
                  _boundedNumberField('Green', green),
                  _boundedNumberField('Blue', blue),
                  _boundedNumberField('Tolerance', tolerance),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, 'cancel'),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, 'gradient'),
                child: const Text('Gradient'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, 'fill'),
                child: const Text('Select'),
              ),
            ],
          ),
    );
    if ((accepted != 'fill' && accepted != 'gradient') || !mounted) {
      for (final controller in [red, green, blue, tolerance]) {
        controller.dispose();
      }
      return;
    }
    final values = [red, green, blue, tolerance]
        .map((controller) => int.tryParse(controller.text.trim()))
        .toList(growable: false);
    if (values.any((value) => value == null)) return;
    final r = values[0]!.clamp(0, 255);
    final g = values[1]!.clamp(0, 255);
    final b = values[2]!.clamp(0, 255);
    final t = values[3]!.clamp(0, 1020);
    for (final controller in [red, green, blue, tolerance]) {
      controller.dispose();
    }
    try {
      await widget.engine.selectColorRange(
        layerId: widget.engine.documentInfo.primaryRasterLayer,
        red: r,
        green: g,
        blue: b,
        alpha: 255,
        tolerance: t,
      );
      if (mounted) setState(() => _selectionGeometryTool = _activeTool);
    } catch (error, stack) {
      debugPrint('Project Ink color range selection failed: $error\n$stack');
    }
  }

  Future<void> _chooseFill(Offset position) async {
    final red = TextEditingController(text: '255');
    final green = TextEditingController(text: '128');
    final blue = TextEditingController(text: '0');
    final tolerance = TextEditingController(text: '12');
    final gap = TextEditingController(text: '0');
    final accepted = await showDialog<String>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('Bucket fill'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _boundedNumberField('Red', red),
                  _boundedNumberField('Green', green),
                  _boundedNumberField('Blue', blue),
                  _boundedNumberField('Tolerance', tolerance),
                  _boundedNumberField('Gap closing (0–4)', gap),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, 'cancel'),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, 'gradient'),
                child: const Text('Gradient'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, 'fill'),
                child: const Text('Fill'),
              ),
            ],
          ),
    );
    final controllers = [red, green, blue, tolerance, gap];
    if ((accepted != 'fill' && accepted != 'gradient') || !mounted) {
      for (final controller in controllers) {
        controller.dispose();
      }
      return;
    }
    final values = controllers
        .map((controller) => int.tryParse(controller.text.trim()))
        .toList(growable: false);
    for (final controller in controllers) {
      controller.dispose();
    }
    if (values.any((value) => value == null)) return;
    try {
      final layerId = widget.engine.documentInfo.primaryRasterLayer;
      final x = position.dx.round().clamp(
        0,
        widget.engine.documentInfo.widthPx - 1,
      );
      final y = position.dy.round().clamp(
        0,
        widget.engine.documentInfo.heightPx - 1,
      );
      if (accepted == 'gradient') {
        await widget.engine.gradientFill(
          layerId: layerId,
          x: x,
          y: y,
          startX: position.dx,
          startY: position.dy,
          endX: position.dx + 128,
          endY: position.dy,
          fromRed: values[0]!.clamp(0, 255),
          fromGreen: values[1]!.clamp(0, 255),
          fromBlue: values[2]!.clamp(0, 255),
          fromAlpha: 255,
          toRed: 255,
          toGreen: 255,
          toBlue: 255,
          toAlpha: 255,
          tolerance: values[3]!.clamp(0, 1020),
          gap: values[4]!.clamp(0, 4),
          expansion: 0,
          paintInside: false,
          paintUnfilled: false,
        );
      } else {
        await widget.engine.fillRegion(
          layerId: layerId,
          x: x,
          y: y,
          red: values[0]!.clamp(0, 255),
          green: values[1]!.clamp(0, 255),
          blue: values[2]!.clamp(0, 255),
          alpha: 255,
          tolerance: values[3]!.clamp(0, 1020),
          gap: values[4]!.clamp(0, 4),
        );
      }
      widget.autosave?.markDirty();
      unawaited(_refreshTiles());
    } catch (error, stack) {
      debugPrint('Project Ink bucket fill failed: $error\n$stack');
    }
  }

  Widget _boundedNumberField(String label, TextEditingController controller) =>
      TextField(
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: false),
        decoration: InputDecoration(labelText: label),
      );

  Future<void> _chooseMeshTransform(Rect rect) async {
    final columns = TextEditingController(text: '2');
    final rows = TextEditingController(text: '2');
    final points = TextEditingController(
      text:
          '${rect.left},${rect.top};${rect.right},${rect.top};${rect.left},${rect.bottom};${rect.right},${rect.bottom}',
    );
    final accepted = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('Mesh transform'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _boundedNumberField('Columns (2–32)', columns),
                  _boundedNumberField('Rows (2–32)', rows),
                  TextField(
                    controller: points,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: 'Control points (x,y; x,y; …)',
                      helperText: 'Row-major; count must equal columns × rows.',
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Apply'),
              ),
            ],
          ),
    );
    if (accepted != true || !mounted) {
      columns.dispose();
      rows.dispose();
      points.dispose();
      return;
    }
    final columnCount = int.tryParse(columns.text.trim());
    final rowCount = int.tryParse(rows.text.trim());
    final parsed = points.text
        .split(';')
        .map(
          (pair) => pair
              .split(',')
              .map((value) => double.tryParse(value.trim()))
              .toList(growable: false),
        )
        .toList(growable: false);
    columns.dispose();
    rows.dispose();
    points.dispose();
    if (columnCount == null ||
        rowCount == null ||
        columnCount < 2 ||
        columnCount > 32 ||
        rowCount < 2 ||
        rowCount > 32 ||
        parsed.length != columnCount * rowCount ||
        parsed.any(
          (pair) =>
              pair.length != 2 ||
              pair.any((value) => value == null || !value.isFinite),
        )) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Mesh points do not match the requested grid.'),
          ),
        );
      }
      return;
    }
    await widget.engine.meshLayer(
      layerId: widget.engine.documentInfo.primaryRasterLayer,
      columns: columnCount,
      rows: rowCount,
      points: parsed
          .expand((pair) => [pair[0]!, pair[1]!])
          .toList(growable: false),
    );
  }

  Future<void> _chooseLiquify(
    Offset center,
    Offset delta,
    double radius,
  ) async {
    final strength = TextEditingController(text: '0.5');
    var mode = 0;
    final accepted = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => StatefulBuilder(
            builder:
                (context, setDialogState) => AlertDialog(
                  title: const Text('Liquify'),
                  content: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        DropdownButtonFormField<int>(
                          initialValue: mode,
                          items: const [
                            DropdownMenuItem(value: 0, child: Text('Push')),
                            DropdownMenuItem(value: 1, child: Text('Expand')),
                            DropdownMenuItem(value: 2, child: Text('Contract')),
                            DropdownMenuItem(value: 3, child: Text('Twirl')),
                          ],
                          onChanged:
                              (value) =>
                                  setDialogState(() => mode = value ?? 0),
                          decoration: const InputDecoration(labelText: 'Mode'),
                        ),
                        _boundedNumberField('Strength (-1 to 1)', strength),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(dialogContext, true),
                      child: const Text('Apply'),
                    ),
                  ],
                ),
          ),
    );
    if (accepted != true || !mounted) {
      strength.dispose();
      return;
    }
    final value = double.tryParse(strength.text.trim());
    strength.dispose();
    if (value == null || !value.isFinite || value < -1 || value > 1) return;
    await widget.engine.liquifyLayer(
      layerId: widget.engine.documentInfo.primaryRasterLayer,
      centerX: center.dx,
      centerY: center.dy,
      radius: radius,
      strength: value,
      mode: mode,
      directionX: delta.dx,
      directionY: delta.dy,
    );
  }

  Future<void> _applyTransformPreset(TransformPreset preset) async {
    final center = Offset(
      widget.engine.documentInfo.widthPx / 2,
      widget.engine.documentInfo.heightPx / 2,
    );
    final radians = switch (preset) {
      TransformPreset.rotateLeft => -math.pi / 12,
      TransformPreset.rotateRight => math.pi / 12,
      TransformPreset.scaleUp || TransformPreset.scaleDown => 0,
    };
    final scale = switch (preset) {
      TransformPreset.scaleUp => 1.1,
      TransformPreset.scaleDown => 0.9,
      _ => 1.0,
    };
    final a = math.cos(radians) * scale;
    final b = math.sin(radians) * scale;
    final c = -math.sin(radians) * scale;
    final d = math.cos(radians) * scale;
    try {
      await widget.engine.transformLayer(
        layerId: widget.engine.documentInfo.primaryRasterLayer,
        a: a,
        b: b,
        c: c,
        d: d,
        tx: center.dx - a * center.dx - c * center.dy,
        ty: center.dy - b * center.dx - d * center.dy,
      );
      widget.autosave?.markDirty();
      unawaited(_refreshTiles());
    } catch (error, stack) {
      debugPrint('Project Ink transform failed: $error\n$stack');
    }
  }

  void _selectTool(IllustrationTool tool) {
    if (!mounted) return;
    setState(() {
      _activeTool = tool;
      _toolStart = null;
      _toolPoints = const [];
      _toolVectorPoints = const [];
      _showTools = true;
      if (tool == IllustrationTool.eraser) _eraserActive = true;
      if (tool == IllustrationTool.brush) _eraserActive = false;
    });
  }

  int? get _selectedVectorLayerId {
    for (final id in _layerSelection.selected) {
      final layer = _layers.where((value) => value.id == id).firstOrNull;
      if (layer?.kind == LayerKind.vectorInk) return id;
    }
    return _layers
        .where((layer) => layer.kind == LayerKind.vectorInk)
        .firstOrNull
        ?.id;
  }

  String get _activeLayerName {
    for (final id in _layerSelection.selected) {
      final layer = _layers.where((value) => value.id == id).firstOrNull;
      if (layer != null) return layer.name;
    }
    return _layers.firstOrNull?.name ?? 'Canvas';
  }

  Future<void> _loadVectorStrokesForSelection() async {
    final layerId = _selectedVectorLayerId;
    if (layerId == null) {
      if (mounted) setState(() => _vectorStrokes = const []);
      return;
    }
    try {
      final strokes = await widget.engine.vectorStrokeSummaries(
        layerId: layerId,
      );
      if (mounted) setState(() => _vectorStrokes = strokes);
    } catch (error, stack) {
      debugPrint('Project Ink vector projection unavailable: $error\n$stack');
    }
  }

  Future<void> _simplifySelectedVector() async {
    final layerId = _selectedVectorLayerId;
    final stroke = _vectorStrokes.firstOrNull;
    if (layerId == null || stroke == null) return;
    try {
      await widget.engine.simplifyVectorStroke(
        layerId: layerId,
        strokeId: stroke.id,
        tolerance: 1.0,
      );
      await _loadVectorStrokesForSelection();
      widget.autosave?.markDirty();
    } catch (error, stack) {
      debugPrint('Project Ink vector simplify rejected: $error\n$stack');
    }
  }

  Future<void> _connectFirstTwoVectors() async {
    final layerId = _selectedVectorLayerId;
    if (layerId == null || _vectorStrokes.length < 2) return;
    try {
      await widget.engine.connectVectorStrokes(
        layerId: layerId,
        firstId: _vectorStrokes[0].id,
        secondId: _vectorStrokes[1].id,
        tolerance: 8.0,
      );
      await _loadVectorStrokesForSelection();
      widget.autosave?.markDirty();
    } catch (error, stack) {
      debugPrint('Project Ink vector connect rejected: $error\n$stack');
    }
  }

  Future<void> _editFirstVectorPoint() async {
    final layerId = _selectedVectorLayerId;
    final stroke = _vectorStrokes.firstOrNull;
    if (layerId == null || stroke == null || stroke.points.length < 4) return;
    final x = TextEditingController(text: stroke.points[0].toStringAsFixed(2));
    final y = TextEditingController(text: stroke.points[1].toStringAsFixed(2));
    final pressure = TextEditingController(
      text: stroke.points[2].toStringAsFixed(3),
    );
    final tilt = TextEditingController(
      text: stroke.points[3].toStringAsFixed(3),
    );
    final accepted = await showDialog<bool>(
      context: context,
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
    if (accepted != true || !mounted) {
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
      await widget.engine.setVectorPoint(
        layerId: layerId,
        strokeId: stroke.id,
        index: 0,
        x: values[0]!,
        y: values[1]!,
        pressure: values[2]!.clamp(0.0, 1.0),
        tilt: values[3]!,
      );
      await _loadVectorStrokesForSelection();
      widget.autosave?.markDirty();
      unawaited(_refreshTiles());
    } catch (error, stack) {
      debugPrint('Project Ink vector point edit rejected: $error\n$stack');
    }
  }

  void _handleNativePacket(Uint8List packet) {
    final packetArrivalUs =
        _canvasDiagnostics.isRecording
            ? _canvasDiagnostics.elapsedMicroseconds
            : null;
    _canvasDiagnostics.recordPacket(
      'input.native_packet',
      'ios_event_channel',
      packet,
    );
    final contactWasActive = _nativePencilContactActive;
    late final bool hasDown;
    late final bool hasUp;
    late final bool hasCancel;
    try {
      hasDown = packetHasPhase(packet, InkPointerPhase.down);
      hasUp = packetHasPhase(packet, InkPointerPhase.up);
      hasCancel = packetHasPhase(packet, InkPointerPhase.cancel);
      if (hasDown) {
        _nativePencilContactActive = true;
        _discardConcurrentTouchGesture();
      }
      if (hasUp || hasCancel) _nativePencilContactActive = false;
    } catch (error, stack) {
      _canvasDiagnostics.recordError('native_pointer_packet', error, stack);
      debugPrint('Project Ink native pointer packet rejected: $error\n$stack');
      return;
    }
    if (!contactWasActive && !hasDown) {
      _canvasDiagnostics.record('input.native_packet_ignored', {
        'reason': 'outside_active_pencil_contact',
        'terminalPacket': hasUp || hasCancel,
      });
      return;
    }
    if (_activeTool != IllustrationTool.brush &&
        _activeTool != IllustrationTool.eraser) {
      return;
    }
    if (widget.onPerformanceSnapshot == null) {
      _lastPacketMicros = null;
    } else {
      try {
        _lastPacketMicros = _performanceTrace.markPacketReceived(packet);
      } catch (error, stack) {
        _canvasDiagnostics.recordError('native_pointer_packet', error, stack);
        debugPrint(
          'Project Ink native pointer packet rejected: $error\n$stack',
        );
        return;
      }
    }
    // Transform and append confirmed history on packet arrival. Rust remains
    // serialized below, but its queue must never delay visible Pencil input.
    final preparedPacket = _prepareNativePointerPacket(
      packet,
      packetArrivalUs: packetArrivalUs,
    );
    final latestConfirmedPosition = _lastConfirmedNativePosition(
      preparedPacket,
    );
    if (latestConfirmedPosition != null) {
      // The engine worker can lag behind UIKit while a long Pencil stroke is
      // rasterizing. Track contact arrival here, before queuing Rust work, so
      // Draw-and-Hold cannot interpret a stale processed packet as a pause.
      _stylusLastPosition = latestConfirmedPosition;
      _lastNativeInputArrivalUs = _nativeInputArrivalClock.elapsedMicroseconds;
      _stylusHoldTimer?.cancel();
      if (!hasDown && !hasUp && !hasCancel) {
        _armDrawAndHold(latestConfirmedPosition);
      }
    }
    _pendingNativePackets.add(preparedPacket);
    if (_nativePacketDrainQueued) return;
    _nativePacketDrainQueued = true;
    _enqueueStrokeWork(_drainNativePacketQueue);
  }

  Offset? _lastConfirmedNativePosition(Uint8List packet) {
    if (packet.length < 4) return null;
    final data = ByteData.sublistView(packet);
    final count = data.getUint16(2, Endian.little);
    Offset? latest;
    for (var index = 0; index < count; index++) {
      final offset = 4 + index * 48;
      if (offset + 48 > packet.length) break;
      final flags = data.getUint16(offset + 4, Endian.little);
      final phase = data.getUint8(offset + 7);
      final confirmed =
          flags & (inkPointerActual | inkPointerCoalesced) != 0 &&
          flags &
                  (inkPointerPredicted |
                      inkPointerHover |
                      inkPointerPalmRejected) ==
              0;
      if (!confirmed ||
          (phase != InkPointerPhase.down.index &&
              phase != InkPointerPhase.move.index &&
              phase != InkPointerPhase.up.index)) {
        continue;
      }
      latest = Offset(
        data.getFloat32(offset + 8, Endian.little),
        data.getFloat32(offset + 12, Endian.little),
      );
    }
    return latest;
  }

  Uint8List _prepareNativePointerPacket(
    Uint8List packet, {
    int? packetArrivalUs,
  }) {
    final hasDown = packetHasPhase(packet, InkPointerPhase.down);
    final source = ByteData.sublistView(packet);
    var sampleIndex = 0;
    var firstSample = true;
    final canonicalSequences = <int>[];
    final previewSamples = <LiveStrokePreviewPoint>[];
    final transformed = transformPointerPacket(packet, (screenPosition) {
      final offset = 4 + sampleIndex * 48;
      final flags = source.getUint16(offset + 4, Endian.little);
      final phase = source.getUint8(offset + 7);
      final pressure = source.getFloat32(offset + 16, Endian.little);
      final isDownSample = hasDown && firstSample;
      final canonicalSequence = _nextPointerSequence();
      canonicalSequences.add(canonicalSequence);
      sampleIndex++;
      final position = _applyStrokeConstraint(
        _safeInputPosition(_canvasPosition(screenPosition)),
        hasDown: isDownSample,
      );
      final confirmed =
          flags & (inkPointerActual | inkPointerCoalesced) != 0 &&
          flags &
                  (inkPointerPredicted |
                      inkPointerHover |
                      inkPointerPalmRejected) ==
              0;
      if (confirmed &&
          (phase == InkPointerPhase.down.index ||
              phase == InkPointerPhase.move.index ||
              phase == InkPointerPhase.up.index)) {
        previewSamples.add(
          LiveStrokePreviewPoint(
            position,
            pressure,
            sourceSequence: canonicalSequence,
          ),
        );
      }
      firstSample = false;
      return position;
    });
    final transformedData = ByteData.sublistView(transformed);
    for (var index = 0; index < canonicalSequences.length; index++) {
      transformedData.setUint32(
        4 + index * 48 + 44,
        canonicalSequences[index],
        Endian.little,
      );
    }
    if (previewSamples.isNotEmpty) {
      _appendNativePreviewBatch(previewSamples, beginsStroke: hasDown);
      final firstPreviewIndex = _liveStrokeCoordinator
          .previewIndexForSourceSequence(previewSamples.first.sourceSequence);
      final lastPreviewIndex = _liveStrokeCoordinator
          .previewIndexForSourceSequence(previewSamples.last.sourceSequence);
      _canvasDiagnostics.record('canvas.live_input_accepted', {
        'device': 'apple_pencil',
        'confirmedSamples': previewSamples.length,
        'confirmedPreviewIndexStart': firstPreviewIndex,
        'confirmedPreviewIndexEnd': lastPreviewIndex,
        'firstConfirmedSequence': previewSamples.first.sourceSequence,
        'lastConfirmedSequence': previewSamples.last.sourceSequence,
        'strokeConstraintMode': _strokeConstraintMode,
        'renderer': 'flutter_canvas',
        if (packetArrivalUs != null) 'packetArrivalUs': packetArrivalUs,
      });
      _scheduleLivePreviewFrameDiagnostic();
    }
    return transformed;
  }

  int _nextPointerSequence() {
    final sequence = _sequence & 0xffffffff;
    _sequence = (_sequence + 1) & 0xffffffff;
    return sequence;
  }

  void _scheduleLivePreviewFrameDiagnostic() {
    if (_livePreviewFrameDiagnosticScheduled || _disposed) return;
    _livePreviewFrameDiagnosticScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _livePreviewFrameDiagnosticScheduled = false;
      if (!mounted || _disposed) return;
      final preview = _strokePreview.value;
      if (preview == null) return;
      final pendingStart =
          preview.confirmedThrough.clamp(0, preview.points.length).toInt();
      final pendingFirst =
          pendingStart < preview.points.length
              ? preview.points[pendingStart]
              : null;
      final pendingLast = preview.points.lastOrNull;
      final packetMicros = _lastPacketMicros;
      _canvasDiagnostics.record('canvas.live_preview_frame', {
        'pointCount': preview.points.length,
        'confirmedThrough': preview.confirmedThrough,
        'pendingPointCount': preview.points.length - preview.confirmedThrough,
        'pendingSourceSequenceStart': pendingFirst?.sourceSequence,
        'pendingSourceSequenceEnd': pendingLast?.sourceSequence,
        'visiblePreviewIndexStart': pendingStart,
        'visiblePreviewIndexEnd':
            pendingLast == null ? null : preview.points.length - 1,
        'previewRevision': preview.revision,
        'pendingPreviewChunkCount': _liveStrokeCoordinator.pendingChunkCount(
          preview,
        ),
        'oldestPendingPreviewChunkAgeUs': _liveStrokeCoordinator
            .oldestChunkAgeMicros(preview),
        'unbuiltPreviewPointCount': math.max(
          0,
          preview.points.length - preview.chunkedThrough,
        ),
        'strokeWorkQueueDepth': _strokeOperations.length,
        'nativePacketQueueDepth': _pendingNativePackets.length,
        'nativeTextureEnabled': _livePreviewSurface != null,
        'nativeTextureReady':
            _livePreviewSurface?.textureId.value != null &&
            (_livePreviewSurface?.gpuFrameReady.value ?? false),
        'renderer': 'flutter_canvas',
      });
      if (packetMicros != null && widget.onPerformanceSnapshot != null) {
        _performanceTrace.markLivePreviewFramePresented(
          packetMicros: packetMicros,
        );
        widget.onPerformanceSnapshot?.call(_performanceTrace.snapshot());
      }
    });
  }

  void _appendNativePreviewBatch(
    List<LiveStrokePreviewPoint> samples, {
    required bool beginsStroke,
  }) {
    var start = 0;
    if (beginsStroke) {
      _liveStrokeCoordinator.clear();
      _updateStrokePreview(
        samples.first.position,
        isDown: true,
        isUp: false,
        pressure: samples.first.pressure,
        sourceSequence: samples.first.sourceSequence,
      );
      _liveStrokeCoordinator.recordConfirmedSample(
        samples.first.sourceSequence,
        0,
      );
      start = 1;
    }
    var preview = _strokePreview.value;
    if (preview == null) return;
    final points = preview.points;
    var changed = false;
    for (var index = start; index < samples.length; index++) {
      final sample = samples[index];
      if (_previewStoppedAtPageEdge) break;
      final outside = !_positionIsInsideDocument(sample.position);
      final last = points.lastOrNull?.position;
      if (outside && last == null) continue;
      final point =
          outside && last != null
              ? _clipPreviewEndpoint(last, sample.position)
              : _boundedStrokePosition(sample.position);
      final previous = points.lastOrNull;
      if (previous == null ||
          point != last ||
          sample.pressure != previous.pressure) {
        final pointIndex = _liveStrokeCoordinator.appendPoint(
          preview,
          LiveStrokePreviewPoint(
            point,
            sample.pressure,
            sourceSequence: sample.sourceSequence,
          ),
        );
        _liveStrokeCoordinator.recordConfirmedSample(
          sample.sourceSequence,
          pointIndex,
        );
        changed = true;
      } else if (sample.sourceSequence >= 0 && points.isNotEmpty) {
        _liveStrokeCoordinator.recordConfirmedSample(
          sample.sourceSequence,
          points.length - 1,
        );
      }
      if (outside) _previewStoppedAtPageEdge = true;
    }
    final compacted = _liveStrokeCoordinator.compactCommittedPrefix(preview);
    changed |= !identical(compacted, preview);
    preview = compacted;
    if (changed) {
      _setStrokePreview(preview.copyWith(revision: preview.revision + 1));
    }
  }

  void _discardConcurrentTouchGesture() {
    for (final pointer in _activeTouchPointers) {
      _pointers.remove(pointer);
    }
    _touchLongPressTimer?.cancel();
    _activeTouchPointers.clear();
    _touchDown.clear();
    _touchCurrent.clear();
    _touchStarted = null;
    _touchCount = 0;
    _touchMoved = false;
    _touchGestureTriggered = false;
    _touchGesturePosition = null;
    if (_touchDrawingStrokeActive) {
      _cancelTouchDrawingStroke(reason: 'touch_state_reset');
    }
  }

  Future<void> _drainNativePacketQueue() async {
    try {
      while (_pendingNativePackets.isNotEmpty && !_disposed) {
        final batch = List<Uint8List>.of(_pendingNativePackets);
        _pendingNativePackets.clear();
        for (final packet in _compactNativePointerPackets(batch)) {
          _canvasDiagnostics.recordPacket(
            'input.native_packet',
            'canvas_queue_after_compaction',
            packet,
          );
          await _handleNativePacketSafely(packet);
        }
      }
    } finally {
      _nativePacketDrainQueued = false;
      if (_pendingNativePackets.isNotEmpty && !_disposed) {
        _nativePacketDrainQueued = true;
        _enqueueStrokeWork(_drainNativePacketQueue);
      } else if (!_disposed && _strokeActive && _stylusLastPosition != null) {
        // If the hold deadline elapsed while Rust was draining, evaluate it
        // only after all confirmed input has reached the engine.
        _armDrawAndHold(_stylusLastPosition!);
      }
    }
  }

  void _handlePencilCommand(String command) {
    if (!mounted) return;
    switch (command) {
      case 'toggleEraser':
        setState(() => _eraserActive = !_eraserActive);
        break;
      case 'quickMenu':
        setState(() => _quickMenuVisible = !_quickMenuVisible);
        break;
    }
  }

  Future<void> _handleNativePacketSerial(Uint8List packet) async {
    final hasDown = packetHasPhase(packet, InkPointerPhase.down);
    final hasUp = packetHasPhase(packet, InkPointerPhase.up);
    final hasCancel = packetHasPhase(packet, InkPointerPhase.cancel);
    // Native desktop/tablet streams can also lose a release when pointer
    // capture is interrupted by leaving the window or switching apps. Recover
    // in the same way as the generic Flutter pointer path on the next press.
    if (hasDown && _strokeActive) {
      await _abortStrokeAfterPacketError(preservePreview: true);
    }
    if (hasDown && !_strokeActive) {
      await _beginActiveBrushStroke();
      _strokeActive = true;
      _activeStrokeIsTouch = false;
      _strokeCaptureEndedAtBoundary = false;
      _nativeLastSampleInsideDocument = false;
      _nativeDiagnosticPacketCount = 0;
      _nativeDiagnosticSampleCount = 0;
      _nativeDiagnosticMinPressure = 1.0;
      _nativeDiagnosticMaxPressure = 0.0;
      debugPrint('Project Ink Pencil diagnostic: stroke began');
      widget.autosave?.markDirty();
    }
    if (!_strokeActive) {
      if (hasUp || hasCancel) {
        _canvasDiagnostics.record('input.native_terminal_ignored', {
          'terminalPhase': hasCancel ? 'cancel' : 'up',
          'reason': 'no_active_stroke',
        });
      }
      return;
    }
    if (packet.length >= 4) {
      final packetData = ByteData.sublistView(packet);
      final sampleCount = packetData.getUint16(2, Endian.little);
      _nativeDiagnosticPacketCount++;
      _nativeDiagnosticSampleCount += sampleCount;
    }
    // Rust clips and stops rasterizing after the first page-edge crossing,
    // but the native adapter can continue emitting captured stylus packets
    // while the pen is outside the page. Do not keep feeding those no-op
    // packets into the bounded worker queue. Still consume the terminal event
    // so the active stroke is always closed.
    if (_strokeCaptureEndedAtBoundary) {
      if (hasUp || hasCancel) {
        debugPrint(
          'Project Ink Pencil diagnostic: ${hasCancel ? 'cancel' : 'up'} '
          'after $_nativeDiagnosticPacketCount packets / '
          '$_nativeDiagnosticSampleCount samples; '
          'pressure=${_nativeDiagnosticMinPressure.toStringAsFixed(3)}..'
          '${_nativeDiagnosticMaxPressure.toStringAsFixed(3)}; edgeExit=true',
        );
        if (hasCancel) {
          await widget.engine.cancelStroke();
          unawaited(_livePreviewSurface?.cancelAllStrokes());
        } else {
          await widget.engine.endStroke();
          widget.autosave?.markDirty();
        }
        _strokeActive = false;
        _activeStrokeIsTouch = false;
        _strokeCaptureEndedAtBoundary = false;
        _nativeLastSampleInsideDocument = false;
        _awaitingPreviewCommit = !hasCancel;
        if (!hasCancel) {
          _retirePreviewIfAlreadyCpuCovered(
            source: 'native_pencil_boundary_end',
          );
        }
        if (hasCancel) {
          _liveStrokeCoordinator.clear();
          _lastPublishedPreviewAcknowledgement = null;
          _setStrokePreview(null);
        }
        _finishConstraintStroke();
        _stylusHoldTimer?.cancel();
        _stylusLastPosition = null;
        unawaited(_refreshLayerThumbnails());
        unawaited(_refreshTiles());
      }
      return;
    }
    var crossingSampleCount = 0;
    final sourceData = ByteData.sublistView(packet);
    final sampleCount = sourceData.getUint16(2, Endian.little);
    for (var index = 0; index < sampleCount; index++) {
      final sampleOffset = 4 + index * 48;
      final flags = sourceData.getUint16(sampleOffset + 4, Endian.little);
      final phase = sourceData.getUint8(sampleOffset + 7);
      final pressure = sourceData.getFloat32(sampleOffset + 16, Endian.little);
      final position = Offset(
        sourceData.getFloat32(sampleOffset + 8, Endian.little),
        sourceData.getFloat32(sampleOffset + 12, Endian.little),
      );
      final isInsideDocument = _positionIsInsideDocument(position);
      final isConfirmedContact =
          flags & (inkPointerActual | inkPointerCoalesced) != 0 &&
          flags &
                  (inkPointerPredicted |
                      inkPointerHover |
                      inkPointerPalmRejected) ==
              0;
      if (isConfirmedContact &&
          phase != InkPointerPhase.down.index &&
          _nativeLastSampleInsideDocument &&
          !isInsideDocument) {
        _strokeCaptureEndedAtBoundary = true;
        debugPrint(
          'Project Ink Pencil diagnostic: canvas edge exit after '
          '$_nativeDiagnosticPacketCount packets / '
          '$_nativeDiagnosticSampleCount samples at '
          '(${position.dx.toStringAsFixed(1)}, '
          '${position.dy.toStringAsFixed(1)}); packet will be clipped',
        );
        crossingSampleCount = index + 1;
      }
      if (isConfirmedContact) {
        _nativeLastSampleInsideDocument = isInsideDocument;
        if (pressure.isFinite) {
          _nativeDiagnosticMinPressure = math.min(
            _nativeDiagnosticMinPressure,
            pressure,
          );
          _nativeDiagnosticMaxPressure = math.max(
            _nativeDiagnosticMaxPressure,
            pressure,
          );
        }
      }
    }
    if (!hasUp && !hasCancel && _stylusLastPosition != null) {
      // Use the latest UIKit arrival position. Do not move this cursor
      // backward to an older packet while draining the serialized Rust queue.
      _armDrawAndHold(_stylusLastPosition!);
    }
    final boundedPacket =
        crossingSampleCount == 0
            ? packet
            : truncatePointerPacket(packet, crossingSampleCount);
    final rasterPacket =
        _eraserActive
            ? addPointerPacketFlags(boundedPacket, inkPointerEraser)
            : boundedPacket;
    _canvasDiagnostics.recordPacket(
      'input.engine_packet',
      'native_pencil_after_transform_clip_and_flags',
      rasterPacket,
      fields: <String, Object?>{
        'strokeActive': _strokeActive,
        'captureEndedAtBoundary': _strokeCaptureEndedAtBoundary,
      },
    );
    try {
      await widget.engine.pushPointerPacket(rasterPacket);
      _livePreviewSurface?.pump();
    } catch (error, stack) {
      if (widget.onPerformanceSnapshot != null) {
        _performanceTrace.markPacketRejected(rasterPacket);
      }
      _canvasDiagnostics.recordError(
        'native_pointer_engine_push',
        error,
        stack,
      );
      debugPrint('Project Ink pointer packet rejected: $error\n$stack');
      await _abortStrokeAfterPacketError();
      return;
    }
    widget.autosave?.markDirty(restartTimer: false);
    if (hasUp || hasCancel) {
      debugPrint(
        'Project Ink Pencil diagnostic: ${hasCancel ? 'cancel' : 'up'} '
        'after $_nativeDiagnosticPacketCount packets / '
        '$_nativeDiagnosticSampleCount samples; '
        'pressure=${_nativeDiagnosticMinPressure.toStringAsFixed(3)}..'
        '${_nativeDiagnosticMaxPressure.toStringAsFixed(3)}; '
        'edgeExit=$_strokeCaptureEndedAtBoundary',
      );
      _canvasDiagnostics.record('input.stroke_end', {
        'source': 'native_pencil',
        'terminalPhase': hasCancel ? 'cancel' : 'up',
        'packets': _nativeDiagnosticPacketCount,
        'samples': _nativeDiagnosticSampleCount,
        'pressureMin': _nativeDiagnosticMinPressure,
        'pressureMax': _nativeDiagnosticMaxPressure,
        'edgeExit': _strokeCaptureEndedAtBoundary,
      });
      if (hasCancel) {
        _canvasDiagnostics.record('canvas.stroke_cancelled', {
          'source': 'native_pencil',
          'engineRevision': widget.engine.revision,
        });
        await widget.engine.cancelStroke();
        unawaited(_livePreviewSurface?.cancelAllStrokes());
      } else {
        await widget.engine.endStroke();
        _canvasDiagnostics.record('canvas.stroke_committed', {
          'source': 'native_pencil',
          'engineRevision': widget.engine.revision,
          'previewAwaitingCpuCommit': true,
        });
        widget.autosave?.markDirty();
      }
      _strokeActive = false;
      _activeStrokeIsTouch = false;
      _strokeCaptureEndedAtBoundary = false;
      _nativeLastSampleInsideDocument = false;
      if (hasCancel) {
        _awaitingPreviewCommit = false;
        _liveStrokeCoordinator.clear();
        _lastPublishedPreviewAcknowledgement = null;
        _setStrokePreview(null);
      } else {
        // Keep the live surface visible until a dirty CPU tile is decoded. The
        // bridge acknowledgement only means the command was accepted; clearing
        // here would expose a one-to-several-frame gap on slower devices.
        _awaitingPreviewCommit = true;
        _retirePreviewIfAlreadyCpuCovered(source: 'native_pencil_end');
      }
      _finishConstraintStroke();
    }
    // The periodic 16 ms tile poll is the live presentation clock while a
    // stroke is active. Refreshing after every packet makes the CPU tile
    // snapshot path contend with the Rust input worker and eventually stalls
    // packet submission behind a long synchronous bridge call. The terminal
    // packet still requests an immediate refresh so the final pixels do not
    // wait for the next timer tick.
    if (hasUp || hasCancel) {
      unawaited(_refreshTiles());
    }
  }

  Future<void> _handleNativePacketSafely(Uint8List packet) async {
    try {
      await _handleNativePacketSerial(packet);
    } catch (error, stack) {
      _canvasDiagnostics.recordError('native_pointer_handler', error, stack);
      debugPrint('Project Ink native packet handling failed: $error\n$stack');
      await _abortStrokeAfterPacketError();
    }
  }

  void _cancelTouchDrawingStroke({required String reason}) {
    if (!_touchDrawingStrokeActive) return;
    _canvasDiagnostics.record('input.touch_stroke_cancel_requested', {
      'reason': reason,
      'strokeActive': _strokeActive,
      'activeStrokeIsTouch': _activeStrokeIsTouch,
      'activeTouchPointerCount': _activeTouchPointers.length,
      'trackedTouchCount': _touchDown.length,
    });
    _touchDrawingStrokeActive = false;
    _enqueueStrokeWork(() async {
      // Touch cancellation can sit in the shared input queue while a Pencil
      // down arrives. Never cancel whichever stroke happens to be active when
      // this task eventually runs; cancel only a stroke owned by touch.
      if (!_strokeActive || !_activeStrokeIsTouch) {
        _canvasDiagnostics.record('input.touch_cancel_ignored', {
          'activeStroke': _strokeActive,
          'activeStrokeIsTouch': _activeStrokeIsTouch,
        });
        return;
      }
      await widget.engine.cancelStroke();
      _canvasDiagnostics.record('input.stroke_end', {
        'source': 'touch_gesture_cancel',
        'terminalPhase': 'cancel',
        'reason': reason,
        'engineRevision': widget.engine.revision,
      });
      _canvasDiagnostics.record('canvas.stroke_cancelled', {
        'source': 'touch_gesture_cancel',
        'reason': reason,
        'engineRevision': widget.engine.revision,
      });
      _strokeActive = false;
      _activeStrokeIsTouch = false;
      unawaited(_livePreviewSurface?.cancelAllStrokes());
      _strokeCaptureEndedAtBoundary = false;
      _nativeLastSampleInsideDocument = false;
      _awaitingPreviewCommit = false;
      _liveStrokeCoordinator.clear();
      _lastPublishedPreviewAcknowledgement = null;
      _setStrokePreview(null);
      _stylusHoldTimer?.cancel();
      _stylusLastPosition = null;
      _finishConstraintStroke();
      unawaited(_refreshTiles());
    });
  }

  void _recordTouchGesture(PointerEvent event) {
    if (event is PointerDownEvent) {
      if (_touchDown.isEmpty) {
        _touchStarted = DateTime.now();
        _touchMoved = false;
        _touchCount = 0;
        _touchGestureTriggered = false;
        _touchGesturePosition = event.localPosition;
      }
      _touchDown[event.pointer] = event.localPosition;
      _touchCurrent[event.pointer] = event.localPosition;
      _activeTouchPointers.add(event.pointer);
      _touchCount =
          _touchCount < _touchDown.length ? _touchDown.length : _touchCount;
      if (_strokeActive &&
          !_touchDrawingStrokeActive &&
          _touchDown.length >= 2) {
        _runMappedGesture(
          _gestureDefaults.bindings['secondFingerWhileDrawing'],
        );
      }
      _touchLongPressTimer?.cancel();
      if (_touchDown.length == 1) {
        _touchLongPressTimer = Timer(const Duration(milliseconds: 550), () {
          if (_activeTouchPointers.length == 1 &&
              !_touchMoved &&
              !_touchDrawingStrokeActive &&
              !_touchGestureTriggered) {
            _touchGestureTriggered = true;
            _touchGesturePosition = _touchCurrent.values.first;
            _runMappedGesture(
              _gestureDefaults.bindings['longPress'],
              position: _touchGesturePosition,
            );
          }
        });
      }
    } else if (event is PointerMoveEvent) {
      _touchCurrent[event.pointer] = event.localPosition;
      final start = _touchDown[event.pointer];
      if (start != null && (event.localPosition - start).distance > 12) {
        _touchMoved = true;
        _touchLongPressTimer?.cancel();
      }
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _touchCurrent[event.pointer] = event.localPosition;
      _activeTouchPointers.remove(event.pointer);
      if (_activeTouchPointers.isEmpty && _touchStarted != null) {
        _touchLongPressTimer?.cancel();
        final elapsed = DateTime.now().difference(_touchStarted!);
        final kind =
            _touchGestureTriggered
                ? null
                : classifyTouchGesture(
                  starts: _touchDown,
                  ends: _touchCurrent,
                  duration: elapsed,
                  moved: _touchMoved,
                );
        switch (kind) {
          case TouchGestureKind.twoFingerTap:
            _runMappedGesture(_gestureDefaults.bindings['twoFingerTap']);
          case TouchGestureKind.threeFingerTap:
            _runMappedGesture(_gestureDefaults.bindings['threeFingerTap']);
          case TouchGestureKind.threeFingerSwipeDown:
            _runMappedGesture(
              _gestureDefaults.bindings['threeFingerSwipeDown'],
            );
          case TouchGestureKind.fourFingerTap:
            _runMappedGesture(_gestureDefaults.bindings['fourFingerTap']);
          case TouchGestureKind.longPress:
          case null:
            break;
        }
        _touchDown.clear();
        _touchCurrent.clear();
        _touchCount = 0;
        _touchStarted = null;
        _touchGestureTriggered = false;
      }
    }
  }

  void _runMappedGesture(InkGesture? gesture, {Offset? position}) {
    switch (gesture) {
      case InkGesture.undo:
        unawaited(_undo());
      case InkGesture.redo:
        unawaited(_redo());
      case InkGesture.fitCanvas:
        _fitCanvas();
      case InkGesture.toggleInterface:
        if (mounted) setState(() => _interfaceHidden = !_interfaceHidden);
      case InkGesture.toggleEraser:
        if (mounted) setState(() => _eraserActive = !_eraserActive);
      case InkGesture.clipboardPalette:
        unawaited(_showClipboardPalette());
      case InkGesture.eyedropper:
        if (position != null) unawaited(_sampleCanvasColor(position));
      case InkGesture.quickMenu:
        if (mounted) setState(() => _quickMenuVisible = !_quickMenuVisible);
      case InkGesture.straighten:
        if (mounted) {
          _straightenMode = true;
          _constrainMode = false;
        }
      case InkGesture.constrain:
        if (mounted) {
          _constrainMode = true;
          _straightenMode = false;
        }
      default:
        break;
    }
  }

  Future<void> _showClipboardPalette() async {
    if (!mounted) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder:
          (context) => SafeArea(
            child: Wrap(
              children: [
                ListTile(
                  leading: const Icon(Icons.copy),
                  title: const Text('Copy brush color'),
                  onTap: () => Navigator.of(context).pop('copy'),
                ),
                ListTile(
                  leading: const Icon(Icons.content_paste),
                  title: const Text('Paste brush color'),
                  onTap: () => Navigator.of(context).pop('paste'),
                ),
              ],
            ),
          ),
    );
    if (!mounted || action == null) return;
    if (action == 'copy') {
      final color = _activeColor;
      await Clipboard.setData(
        ClipboardData(
          text:
              '#${(color.r * 255).round().toRadixString(16).padLeft(2, '0')}'
              '${(color.g * 255).round().toRadixString(16).padLeft(2, '0')}'
              '${(color.b * 255).round().toRadixString(16).padLeft(2, '0')}',
        ),
      );
      return;
    }
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final match = RegExp(
      r'^#?([0-9a-fA-F]{6})$',
    ).firstMatch(data?.text?.trim() ?? '');
    if (match == null) return;
    final value = int.parse(match.group(1)!, radix: 16);
    try {
      await widget.engine.updateBrushColor(
        brushId: _activeBrushId,
        red: (value >> 16) & 0xff,
        green: (value >> 8) & 0xff,
        blue: value & 0xff,
        alpha: 255,
      );
      if (mounted) setState(() => _activeColor = Color(0xff000000 | value));
      widget.autosave?.markDirty();
    } catch (error, stack) {
      debugPrint('Project Ink clipboard color paste failed: $error\n$stack');
    }
  }

  Future<void> _sampleCanvasColor(Offset localPosition) async {
    final position = _canvasPosition(localPosition);
    if (!position.dx.isFinite ||
        !position.dy.isFinite ||
        position.dx < 0 ||
        position.dy < 0 ||
        position.dx >= widget.engine.documentInfo.widthPx ||
        position.dy >= widget.engine.documentInfo.heightPx) {
      return;
    }
    final tileX = position.dx ~/ TileCache.tileSize;
    final tileY = position.dy ~/ TileCache.tileSize;
    // Composite tiles are authoritative after Phase 3.5. Keep the layer
    // fallback for older engines and uncomposited fixtures.
    final bytes =
        _tileBytes.get(_compositeLayerId, tileX, tileY) ??
        _tileBytes.get(
          widget.engine.documentInfo.primaryRasterLayer,
          tileX,
          tileY,
        );
    if (bytes == null) return;
    final x = position.dx.floor() % TileCache.tileSize;
    final y = position.dy.floor() % TileCache.tileSize;
    final offset = (y * TileCache.tileSize + x) * 4;
    final blue = bytes[offset];
    final green = bytes[offset + 1];
    final red = bytes[offset + 2];
    final alpha = bytes[offset + 3];
    if (alpha == 0) return;
    final color = Color.fromARGB(
      alpha,
      (red * 255 / alpha).round().clamp(0, 255),
      (green * 255 / alpha).round().clamp(0, 255),
      (blue * 255 / alpha).round().clamp(0, 255),
    );
    try {
      await widget.engine.updateBrushColor(
        brushId: _activeBrushId,
        red: (color.r * 255).round().clamp(0, 255),
        green: (color.g * 255).round().clamp(0, 255),
        blue: (color.b * 255).round().clamp(0, 255),
        alpha: (color.a * 255).round().clamp(0, 255),
      );
      if (mounted) setState(() => _activeColor = color);
    } catch (error, stack) {
      debugPrint('Project Ink eyedropper failed: $error\n$stack');
    }
  }

  Future<void> _showCanvasDiagnostics() async {
    if (!mounted) return;
    final recorder = _canvasDiagnostics;
    await showDialog<void>(
      context: context,
      builder:
          (dialogContext) => AnimatedBuilder(
            animation: recorder,
            builder: (context, _) {
              final recording = recorder.isRecording;
              final path = recorder.activePath ?? recorder.latestPath;
              return AlertDialog(
                title: const Text('Canvas input diagnostics'),
                content: SizedBox(
                  width: 440,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        recorder.hitSizeLimit
                            ? 'Capture reached its 32 MB safety limit.'
                            : recording
                            ? 'Capture is running (${(recorder.writtenBytes / (1024 * 1024)).toStringAsFixed(1)} MB).'
                            : 'Capture is stopped.',
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'Records exact pointer packets, rendered GPU dab batches, committed canvas tile pixels, frame revisions, and native or engine errors. Captures stay on this device until you export them. No telemetry is uploaded automatically.',
                      ),
                      if (path != null) ...[
                        const SizedBox(height: 10),
                        SelectableText(
                          path,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: const Text('Close'),
                  ),
                  if (path != null && !recording)
                    TextButton.icon(
                      onPressed: () => unawaited(_exportCanvasDiagnostics()),
                      icon: const Icon(Icons.ios_share),
                      label: const Text('Export trace'),
                    ),
                  FilledButton.icon(
                    onPressed:
                        recording
                            ? () => unawaited(recorder.stopCapture())
                            : () => unawaited(_startCanvasDiagnostics()),
                    icon: Icon(
                      recording ? Icons.stop : Icons.fiber_manual_record,
                    ),
                    label: Text(recording ? 'Stop capture' : 'Start capture'),
                  ),
                ],
              );
            },
          ),
    );
  }

  Future<void> _startCanvasDiagnostics({String trigger = 'manual'}) async {
    try {
      final tracePath = await _canvasDiagnostics.startCapture(
        metadata: <String, Object?>{
          'platform': (widget.targetPlatform ?? defaultTargetPlatform).name,
          'documentWidth': widget.engine.documentInfo.widthPx,
          'documentHeight': widget.engine.documentInfo.heightPx,
          'engineRevision': widget.engine.revision,
          'activeTool': _activeTool.name,
          'captureTrigger': trigger,
          'nativeDabRendererEnabled':
              _livePreviewSurface is MacLiveSurfaceController,
          'brushId': _activeBrushId,
          'brushName': _brushLibrary.selected?.name ?? '',
          'liveGpuController': _livePreviewSurface != null,
          'devicePixelRatio':
              WidgetsBinding
                  .instance
                  .platformDispatcher
                  .views
                  .first
                  .devicePixelRatio,
        },
      );
      debugPrint('Project Ink canvas diagnostics recording to $tracePath');
    } catch (error, stack) {
      debugPrint(
        'Project Ink diagnostic capture could not start: $error\n$stack',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not start diagnostic capture: $error')),
        );
      }
    }
  }

  Future<void> _exportCanvasDiagnostics() async {
    final recorder = _canvasDiagnostics;
    final tracePath =
        recorder.isRecording
            ? await recorder.stopCapture(reason: 'export')
            : await recorder.flush();
    if (tracePath == null) return;
    try {
      final platform = widget.targetPlatform ?? defaultTargetPlatform;
      if (platform == TargetPlatform.iOS) {
        final didExport = await const MethodChannel(
          'org.projectink.studio/canvas_diagnostics_export_v1',
        ).invokeMethod<bool>('exportTrace', <String, Object?>{
          'path': tracePath,
        });
        if (didExport != true) return;
      } else {
        final saveLocation = await getSaveLocation(
          acceptedTypeGroups: const [
            XTypeGroup(
              label: 'Project Ink diagnostic trace',
              extensions: ['jsonl'],
            ),
          ],
          suggestedName: 'project-ink-canvas-trace.jsonl',
          confirmButtonText: 'Export trace',
        );
        if (saveLocation == null) return;
        var destination = saveLocation.path;
        if (!destination.toLowerCase().endsWith('.jsonl')) {
          destination = '$destination.jsonl';
        }
        await File(tracePath).copy(destination);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Diagnostic trace exported.')),
        );
      }
    } catch (error, stack) {
      debugPrint('Project Ink diagnostic trace export failed: $error\n$stack');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not export diagnostic trace: $error')),
        );
      }
    }
  }

  Future<void> _showGestureSettings() async {
    var singleFingerNavigation = _singleFingerNavigation;
    var twoFingerAction =
        _gestureDefaults.bindings['twoFingerTap'] ?? InkGesture.undo;
    var threeFingerAction =
        _gestureDefaults.bindings['threeFingerTap'] ?? InkGesture.redo;
    final accepted = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => StatefulBuilder(
            builder:
                (context, setDialogState) => AlertDialog(
                  title: const Text('Gesture settings'),
                  content: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Single-finger navigation'),
                          subtitle: const Text(
                            'When off, one finger draws. When on, one finger pans.',
                          ),
                          value: singleFingerNavigation,
                          onChanged:
                              (value) => setDialogState(
                                () => singleFingerNavigation = value,
                              ),
                        ),
                        DropdownButtonFormField<InkGesture>(
                          decoration: const InputDecoration(
                            labelText: 'Two-finger tap',
                          ),
                          initialValue: twoFingerAction,
                          items:
                              const [InkGesture.undo, InkGesture.redo]
                                  .map(
                                    (gesture) => DropdownMenuItem(
                                      value: gesture,
                                      child: Text(
                                        gesture == InkGesture.undo
                                            ? 'Undo'
                                            : 'Redo',
                                      ),
                                    ),
                                  )
                                  .toList(),
                          onChanged:
                              (value) => setDialogState(() {
                                if (value != null) twoFingerAction = value;
                              }),
                        ),
                        DropdownButtonFormField<InkGesture>(
                          decoration: const InputDecoration(
                            labelText: 'Three-finger tap',
                          ),
                          initialValue: threeFingerAction,
                          items:
                              const [InkGesture.undo, InkGesture.redo]
                                  .map(
                                    (gesture) => DropdownMenuItem(
                                      value: gesture,
                                      child: Text(
                                        gesture == InkGesture.undo
                                            ? 'Undo'
                                            : 'Redo',
                                      ),
                                    ),
                                  )
                                  .toList(),
                          onChanged:
                              (value) => setDialogState(() {
                                if (value != null) threeFingerAction = value;
                              }),
                        ),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(dialogContext, true),
                      child: const Text('Apply'),
                    ),
                  ],
                ),
          ),
    );
    if (accepted == true && mounted) {
      setState(() {
        _singleFingerNavigation = singleFingerNavigation;
        _gestureDefaults = _gestureDefaults.copyWith({
          'twoFingerTap': twoFingerAction,
          'threeFingerTap': threeFingerAction,
        });
      });
    }
  }

  Future<void> _showAccessibilitySettings() async {
    var largeControls = _largeControls;
    var leftHandedToolbar = _leftHandedToolbar;
    final accepted = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => StatefulBuilder(
            builder:
                (context, setDialogState) => AlertDialog(
                  title: const Text('Accessibility settings'),
                  content: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Larger controls'),
                          subtitle: const Text(
                            'Increase toolbar hit targets and icon sizes.',
                          ),
                          value: largeControls,
                          onChanged:
                              (value) =>
                                  setDialogState(() => largeControls = value),
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Left-handed toolbar'),
                          subtitle: const Text(
                            'Move the main toolbar to the upper-left edge.',
                          ),
                          value: leftHandedToolbar,
                          onChanged:
                              (value) => setDialogState(
                                () => leftHandedToolbar = value,
                              ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'All controls expose screen-reader labels and keyboard alternatives where available.',
                        ),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(dialogContext, true),
                      child: const Text('Apply'),
                    ),
                  ],
                ),
          ),
    );
    if (accepted == true && mounted) {
      setState(() {
        _largeControls = largeControls;
        _leftHandedToolbar = leftHandedToolbar;
      });
      _persistWorkspacePreferences(leftHanded: leftHandedToolbar);
    }
  }

  Future<void> _showBrushColorSettings() async {
    var hsv = HSVColor.fromColor(_activeColor);
    var alpha = (_activeColor.a * 255).round();
    final recentColors =
        widget.workspacePreferences?.recentColors ?? const <String>[];
    final selected = await showDialog<Color>(
      context: context,
      builder:
          (dialogContext) => StatefulBuilder(
            builder:
                (context, setDialogState) => AlertDialog(
                  title: const Row(
                    children: [
                      Expanded(child: Text('Brush color')),
                      Text('C', style: TextStyle(fontSize: 13)),
                    ],
                  ),
                  content: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Semantics(
                          label: 'Selected brush color',
                          value:
                              '#${(hsv.toColor().r * 255).round().toRadixString(16).padLeft(2, '0')}${(hsv.toColor().g * 255).round().toRadixString(16).padLeft(2, '0')}${(hsv.toColor().b * 255).round().toRadixString(16).padLeft(2, '0')}',
                          child: _ColorWheel(
                            color: hsv.toColor(),
                            onChanged:
                                (next) => setDialogState(() => hsv = next),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Semantics(
                          label: 'Saturation and value square',
                          hint:
                              'Drag horizontally for saturation and vertically for value',
                          child: _ColorSquare(
                            color: hsv.toColor(),
                            onChanged:
                                (next) => setDialogState(() => hsv = next),
                          ),
                        ),
                        const SizedBox(height: 8),
                        _hsvValueSlider(
                          label: 'Value',
                          value: hsv.value,
                          color: hsv.toColor(),
                          onChanged:
                              (value) => setDialogState(
                                () => hsv = hsv.withValue(value),
                              ),
                        ),
                        _hsvValueSlider(
                          label: 'Alpha',
                          value: alpha / 255,
                          color: Theme.of(context).colorScheme.primary,
                          onChanged:
                              (value) => setDialogState(
                                () => alpha = (value * 255).round(),
                              ),
                        ),
                        Text(
                          'H ${hsv.hue.round()}°  S ${(hsv.saturation * 100).round()}%  V ${(hsv.value * 100).round()}%',
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                        _colorSlider(
                          label: 'Red',
                          value: (hsv.toColor().r * 255).round(),
                          color: Colors.red,
                          onChanged: (value) {
                            final color = hsv.toColor();
                            setDialogState(
                              () =>
                                  hsv = HSVColor.fromColor(
                                    Color.fromARGB(
                                      255,
                                      value,
                                      (color.g * 255).round(),
                                      (color.b * 255).round(),
                                    ),
                                  ),
                            );
                          },
                        ),
                        _colorSlider(
                          label: 'Green',
                          value: (hsv.toColor().g * 255).round(),
                          color: Colors.green,
                          onChanged: (value) {
                            final color = hsv.toColor();
                            setDialogState(
                              () =>
                                  hsv = HSVColor.fromColor(
                                    Color.fromARGB(
                                      255,
                                      (color.r * 255).round(),
                                      value,
                                      (color.b * 255).round(),
                                    ),
                                  ),
                            );
                          },
                        ),
                        _colorSlider(
                          label: 'Blue',
                          value: (hsv.toColor().b * 255).round(),
                          color: Colors.blue,
                          onChanged: (value) {
                            final color = hsv.toColor();
                            setDialogState(
                              () =>
                                  hsv = HSVColor.fromColor(
                                    Color.fromARGB(
                                      255,
                                      (color.r * 255).round(),
                                      (color.g * 255).round(),
                                      value,
                                    ),
                                  ),
                            );
                          },
                        ),
                        const SizedBox(height: 6),
                        if (recentColors.isNotEmpty) ...[
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'Recent colors',
                              style: Theme.of(context).textTheme.labelMedium,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final value in recentColors)
                                Tooltip(
                                  message: 'Use $value',
                                  child: Semantics(
                                    button: true,
                                    label: 'Recent color $value',
                                    child: InkWell(
                                      customBorder: const CircleBorder(),
                                      onTap: () {
                                        final recent = Color(
                                          int.parse(
                                            value.substring(1),
                                            radix: 16,
                                          ),
                                        );
                                        setDialogState(() {
                                          hsv = HSVColor.fromColor(recent);
                                          alpha = (recent.a * 255).round();
                                        });
                                      },
                                      child: Container(
                                        width: 28,
                                        height: 28,
                                        decoration: BoxDecoration(
                                          color: Color(
                                            int.parse(
                                              value.substring(1),
                                              radix: 16,
                                            ),
                                          ),
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                            color:
                                                Theme.of(
                                                  context,
                                                ).colorScheme.outline,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                        ],
                        const Text(
                          'I or Alt-I samples a color from the canvas',
                        ),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed:
                          () => Navigator.pop(
                            dialogContext,
                            hsv.withAlpha(alpha / 255).toColor(),
                          ),
                      child: const Text('Apply'),
                    ),
                  ],
                ),
          ),
    );
    if (selected == null || !mounted) return;
    await _applyMainColor(selected);
  }

  Future<void> _applyMainColor(Color selected) async {
    // A native pointer-up can still be queued in Flutter when the color dialog
    // closes. Flush it before Rust mutates the brush, or Rust rejects the color
    // change while an active stroke is open and the UI appears to accept it.
    await _finishDanglingStrokeBeforeBrushEdit();
    final recentColor = selected.toARGB32().toRadixString(16).padLeft(8, '0');
    final normalizedColor = '#${recentColor.toUpperCase()}';
    final recentColors =
        widget.workspacePreferences?.recentColors ?? const <String>[];
    final updatedRecentColors = [
      normalizedColor,
      ...recentColors.where((value) => value.toUpperCase() != normalizedColor),
    ].take(24).toList(growable: false);
    if (mounted) {
      setState(() => _activeColor = selected);
      _persistWorkspacePreferences(recentColors: updatedRecentColors);
    }
    try {
      await widget.engine.updateBrushColor(
        brushId: _activeBrushId,
        red: (selected.r * 255).round(),
        green: (selected.g * 255).round(),
        blue: (selected.b * 255).round(),
        alpha: (selected.a * 255).round(),
      );
      widget.autosave?.markDirty();
    } catch (error, stack) {
      debugPrint('Project Ink brush color update failed: $error\n$stack');
    }
  }

  Widget _hsvValueSlider({
    required String label,
    required double value,
    required Color color,
    required ValueChanged<double> onChanged,
  }) => Semantics(
    label: label,
    value: '${(value * 100).round()}%',
    child: Row(
      children: [
        SizedBox(width: 52, child: Text(label)),
        Expanded(
          child: Slider(
            activeColor: color,
            value: value.clamp(0.0, 1.0),
            min: 0,
            max: 1,
            divisions: 100,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 56,
          child: Text(
            '${(value * 100).round()}%',
            maxLines: 1,
            softWrap: false,
            textAlign: TextAlign.end,
          ),
        ),
      ],
    ),
  );

  Widget _colorSlider({
    required String label,
    required int value,
    required Color color,
    required ValueChanged<int> onChanged,
  }) => Semantics(
    label: label,
    value: '$value',
    child: Row(
      children: [
        SizedBox(width: 48, child: Text(label)),
        Expanded(
          child: Slider(
            activeColor: color,
            value: value.toDouble(),
            min: 0,
            max: 255,
            divisions: 255,
            onChanged: (next) => onChanged(next.round()),
          ),
        ),
        SizedBox(width: 32, child: Text('$value')),
      ],
    ),
  );

  Future<void> _beginActiveBrushStroke() async {
    final pendingQuickSize = _pendingQuickBrushSize;
    if (pendingQuickSize != null) {
      _persistBrushSize(pendingQuickSize);
    }
    final brushId = _activeBrushId;
    // Quick-menu edits are serialized through this queue. A user can lift the
    // size slider and immediately start drawing before its async Rust commit
    // completes; wait here so the preview and committed raster capture the
    // same brush revision.
    final pendingBrushEdit = _brushEditQueues[brushId];
    if (pendingBrushEdit != null) await pendingBrushEdit;
    final selectedIds = _layerSelection.selected;
    final selectedPaintable = _layers.where(
      (layer) =>
          selectedIds.contains(layer.id) &&
          (layer.kind == LayerKind.raster || layer.kind == LayerKind.mask),
    );
    final targetLayer =
        selectedPaintable.isNotEmpty
            ? selectedPaintable.first.id
            : widget.engine.documentInfo.primaryRasterLayer;
    final selectedBrush = _brushLibrary.selected;
    _canvasDiagnostics.record('brush.stroke_begin', {
      'activeBrushId': brushId,
      'selectedBrushId': selectedBrush?.id,
      'selectedBrushSizePx': selectedBrush?.size,
      'selectedBrushMatchesActive': selectedBrush?.id == brushId,
    });
    await widget.engine.beginBrushStrokeOnLayer(brushId, targetLayer);
  }

  Future<void> _handleDrawingEvent(
    PointerEvent event,
    int sourceSequence,
    Offset preparedPosition,
  ) async {
    final isDown = event is PointerDownEvent;
    final isUp = event is PointerUpEvent || event is PointerCancelEvent;
    if (event.kind == PointerDeviceKind.touch &&
        !(isDown && !_strokeActive) &&
        (!_strokeActive || !_activeStrokeIsTouch)) {
      _canvasDiagnostics.record('input.touch_packet_ignored', {
        'phase':
            isDown
                ? 'down'
                : isUp
                ? 'up_or_cancel'
                : 'move',
        'activeStroke': _strokeActive,
        'activeStrokeIsTouch': _activeStrokeIsTouch,
      });
      return;
    }
    // Desktop platforms may stop delivering pointer events when a pressed
    // mouse leaves the app window. In that case we never receive the matching
    // up/cancel and the engine would keep treating later presses as part of
    // the abandoned stroke. A fresh down is an unambiguous new drawing
    // gesture; cancel any stale stroke before beginning it.
    if (isDown && _strokeActive) {
      await _abortStrokeAfterPacketError();
    }
    if (isDown && !_strokeActive) {
      await _beginActiveBrushStroke();
      _strokeActive = true;
      _activeStrokeIsTouch = event.kind == PointerDeviceKind.touch;
      _strokeCaptureEndedAtBoundary = false;
      widget.autosave?.markDirty();
    }
    if (!_strokeActive) return;
    final position = preparedPosition;
    // A zoomed page can extend past the visible drawing viewport. In that
    // case leaving the viewport does not necessarily leave document bounds,
    // so the document-edge guard would keep accepting captured mouse moves
    // through the hidden part of the page. Stop at the viewport, except when
    // this is also the document-edge crossing sample: Rust needs that sample
    // to clip the final visible segment precisely.
    if (!isDown &&
        !_isInsideCanvasViewport(event.localPosition) &&
        _positionIsInsideDocument(position)) {
      _strokeCaptureEndedAtBoundary = true;
      _previewStoppedAtPageEdge = true;
    }
    // Keep the first inside-to-outside sample below: Rust uses it to clip the
    // last visible segment at the page edge. Once accepted, captured moves
    // outside the artwork (including re-entry) cannot alter the stroke.
    if (_strokeCaptureEndedAtBoundary && !isDown) {
      if (!isUp) return;
      final cancelled = event is PointerCancelEvent;
      if (cancelled) {
        await widget.engine.cancelStroke();
        unawaited(_livePreviewSurface?.cancelAllStrokes());
      } else {
        await widget.engine.endStroke();
        widget.autosave?.markDirty();
      }
      _strokeActive = false;
      _activeStrokeIsTouch = false;
      _strokeCaptureEndedAtBoundary = false;
      _awaitingPreviewCommit = !cancelled;
      if (!cancelled) {
        _retirePreviewIfAlreadyCpuCovered(source: 'pointer_boundary_end');
      }
      if (cancelled) {
        _liveStrokeCoordinator.clear();
        _lastPublishedPreviewAcknowledgement = null;
        _setStrokePreview(null);
      }
      _finishConstraintStroke();
      _stylusHoldTimer?.cancel();
      _stylusLastPosition = null;
      unawaited(_refreshLayerThumbnails());
      unawaited(_refreshTiles());
      return;
    }
    _stylusLastPosition = position;
    if ((isDown || event is PointerMoveEvent) &&
        event.kind != PointerDeviceKind.mouse &&
        event.kind != PointerDeviceKind.touch) {
      _armDrawAndHold(position);
    }
    if (isUp) _stylusHoldTimer?.cancel();
    final packet = encodePointerPacket(
      pointerId: event.pointer,
      device:
          event.kind == PointerDeviceKind.mouse
              ? InkPointerDevice.mouse
              : event.kind == PointerDeviceKind.touch
              ? InkPointerDevice.touch
              : InkPointerDevice.stylus,
      phase:
          isDown
              ? InkPointerPhase.down
              : isUp
              ? (event is PointerCancelEvent
                  ? InkPointerPhase.cancel
                  : InkPointerPhase.up)
              : InkPointerPhase.move,
      x: position.dx,
      y: position.dy,
      pressure: _pointerPressure(event),
      timestampNs: event.timeStamp.inMicroseconds * 1000,
      sequence: sourceSequence,
      tiltX: event.tilt,
      azimuth: event.orientation,
      flags: inkPointerActual | (_eraserActive ? inkPointerEraser : 0),
    );
    final encodedPacket = Uint8List.fromList(packet);
    _canvasDiagnostics.recordPacket(
      'input.engine_packet',
      'flutter_pointer_after_transform',
      encodedPacket,
      fields: <String, Object?>{
        'pointerKind': event.kind.name,
        'phase':
            isDown
                ? 'down'
                : isUp
                ? (event is PointerCancelEvent ? 'cancel' : 'up')
                : 'move',
      },
    );
    _lastPacketMicros =
        widget.onPerformanceSnapshot == null
            ? null
            : _performanceTrace.markPacketReceived(encodedPacket);
    try {
      await widget.engine.pushPointerPacket(encodedPacket);
      _livePreviewSurface?.pump();
      if (!isDown &&
          (!_positionIsInsideDocument(position) ||
              !_isInsideCanvasViewport(event.localPosition))) {
        _strokeCaptureEndedAtBoundary = true;
      }
    } catch (error, stack) {
      if (widget.onPerformanceSnapshot != null) {
        _performanceTrace.markPacketRejected(encodedPacket);
      }
      _canvasDiagnostics.recordError(
        'flutter_pointer_engine_push',
        error,
        stack,
      );
      debugPrint('Project Ink pointer packet rejected: $error\n$stack');
      await _abortStrokeAfterPacketError();
      return;
    }
    widget.autosave?.markDirty(restartTimer: false);
    if (isUp) {
      if (event is PointerCancelEvent) {
        _canvasDiagnostics.record('input.stroke_end', {
          'source': 'flutter_pointer',
          'terminalPhase': 'cancel',
          'pointerKind': event.kind.name,
          'engineRevision': widget.engine.revision,
        });
        await widget.engine.cancelStroke();
        unawaited(_livePreviewSurface?.cancelAllStrokes());
      } else {
        await widget.engine.endStroke();
        _canvasDiagnostics.record('input.stroke_end', {
          'source': 'flutter_pointer',
          'terminalPhase': 'up',
          'pointerKind': event.kind.name,
          'engineRevision': widget.engine.revision,
        });
        widget.autosave?.markDirty();
      }
      _strokeActive = false;
      _activeStrokeIsTouch = false;
      _strokeCaptureEndedAtBoundary = false;
      if (event is PointerCancelEvent) {
        // Cancel rolls the Rust transaction back. Its stale preview has no
        // authoritative CPU tile to hand off, so discard it immediately.
        _awaitingPreviewCommit = false;
        _liveStrokeCoordinator.clear();
        _lastPublishedPreviewAcknowledgement = null;
        _setStrokePreview(null);
        _canvasDiagnostics.record('canvas.stroke_cancelled', {
          'source': 'flutter_pointer',
          'pointerKind': event.kind.name,
          'engineRevision': widget.engine.revision,
        });
      } else {
        // The committed tile is the source of truth, but the live preview stays
        // up until the tile refresh below publishes it on screen.
        _awaitingPreviewCommit = true;
        _retirePreviewIfAlreadyCpuCovered(source: 'flutter_pointer_end');
      }
      _finishConstraintStroke();
      _stylusHoldTimer?.cancel();
      _stylusLastPosition = null;
      unawaited(_refreshLayerThumbnails());
    }
    // Keep CPU presentation on the fixed 16 ms poll during the stroke. The
    // preview remains driven by pointer arrival; an extra tile snapshot for
    // every move only competes with the Rust worker and produces visible
    // stutter on long paths. Publish the terminal CPU frame promptly.
    if (isUp) {
      unawaited(_refreshTiles());
    }
  }

  int _updateStrokePreview(
    Offset position, {
    required bool isDown,
    required bool isUp,
    required double pressure,
    int sourceSequence = -1,
  }) {
    if (isDown) {
      _lastPublishedPreviewAcknowledgement = null;
      _canvasDiagnostics.record('gpu.preview_input_state', {
        'controllerAttached': _livePreviewSurface != null,
        'textureAvailable': _livePreviewSurface?.textureId.value != null,
        'gpuFrameReady': _livePreviewSurface?.gpuFrameReady.value ?? false,
      });
    }
    if (isDown || _strokeActive) {
      _livePreviewSurface?.markInputPending(strokeStart: isDown);
    }
    if (isDown) {
      _liveStrokeCoordinator.clear();
      _previewStoppedAtPageEdge = false;
      _awaitingPreviewCommit = false;
      _setStrokePreview(
        LiveStrokePreview(
          color: _eraserActive ? Colors.white : _activeColor,
          width: _brushLibrary.selected?.size ?? 8,
          pressureSize: _brushLibrary.selected?.pressureSize ?? 0,
          documentWidth: widget.engine.documentInfo.widthPx,
          documentHeight: widget.engine.documentInfo.heightPx,
          legacyTechnicalPen: _activeBrushId == 1,
          eraser: _eraserActive,
          points: <LiveStrokePreviewPoint>[
            if (_positionIsInsideDocument(position))
              LiveStrokePreviewPoint(
                _boundedStrokePosition(position),
                pressure,
                sourceSequence: sourceSequence,
              ),
          ],
          chunks: <LiveStrokePreviewChunk>[],
        ),
      );
      if (sourceSequence >= 0 && _strokePreview.value!.points.isNotEmpty) {
        _liveStrokeCoordinator.recordConfirmedSample(sourceSequence, 0);
      }
      _previewStoppedAtPageEdge = false;
      return 0;
    }
    final preview = _strokePreview.value;
    if (preview == null || _previewStoppedAtPageEdge) return -1;
    final outsideDocument = !_positionIsInsideDocument(position);
    final last = preview.points.lastOrNull?.position;
    if (outsideDocument && last == null) return -1;
    final visiblePosition =
        outsideDocument && last != null
            ? _clipPreviewEndpoint(last, position)
            : _boundedStrokePosition(position);
    // A terminal contact can carry the final confirmed position. Keep it in
    // the visible path and sequence map before EndStroke is serialized so CPU
    // coverage can retire the complete path, including the terminal sample.
    if (!isUp || sourceSequence >= 0) {
      final previous = preview.points.lastOrNull;
      if (previous == null ||
          visiblePosition != last ||
          pressure != previous.pressure) {
        // The preview is an ephemeral single-isolate path. Append in place so
        // every pointer sample does not copy the entire long stroke.
        final pointIndex = _liveStrokeCoordinator.appendPoint(
          preview,
          LiveStrokePreviewPoint(
            visiblePosition,
            pressure,
            sourceSequence: sourceSequence,
          ),
        );
        _liveStrokeCoordinator.recordConfirmedSample(
          sourceSequence,
          pointIndex,
        );
        var nextConfirmedThrough = preview.confirmedThrough;
        _setStrokePreview(
          preview.copyWith(
            confirmedThrough: nextConfirmedThrough,
            revision: preview.revision + 1,
          ),
        );
      }
      if ((last != null && visiblePosition == last) &&
          pressure == previous?.pressure &&
          sourceSequence >= 0 &&
          preview.points.isNotEmpty) {
        _liveStrokeCoordinator.recordConfirmedSample(
          sourceSequence,
          preview.points.length - 1,
        );
      }
    }
    if (outsideDocument) _previewStoppedAtPageEdge = true;
    return (_strokePreview.value?.points.length ?? preview.points.length) - 1;
  }

  /// Retires a preview when all confirmed samples were already handed off to
  /// CPU tiles before the terminal pointer packet closed the stroke. Touch
  /// acknowledgements can be drained during `endStroke`, leaving no later
  /// dirty-tile refresh to trigger the normal coverage-based retirement path.
  void _retirePreviewIfAlreadyCpuCovered({required String source}) {
    final preview = _strokePreview.value;
    if (_strokeActive ||
        !_awaitingPreviewCommit ||
        preview == null ||
        preview.points.isEmpty ||
        preview.confirmedThrough < preview.points.length) {
      return;
    }

    final acknowledgement = _lastPublishedPreviewAcknowledgement;
    _canvasDiagnostics.record('canvas.live_preview_retired', {
      'strokeId': acknowledgement?.stroke.toString(),
      'throughSourceSequence':
          acknowledgement?.highestCommittedSequence ??
          preview.points.last.sourceSequence,
      'previewIndex': preview.confirmedThrough - 1,
      'pointCount': preview.points.length,
      'cpuRevision': acknowledgement?.revision,
      'commitId': null,
      'terminalAcknowledgementInCurrentRefresh': false,
      'retirementAfterTerminalWithoutDirtyTiles': true,
      'source': source,
    });
    _setStrokePreview(null);
    _liveStrokeCoordinator.clear();
    _lastPublishedPreviewAcknowledgement = null;
    _awaitingPreviewCommit = false;
  }

  bool _positionIsInsideDocument(Offset position) {
    final document = widget.engine.documentInfo;
    return position.dx >= 0 &&
        position.dy >= 0 &&
        position.dx <= document.widthPx - 1 &&
        position.dy <= document.heightPx - 1;
  }

  bool _isInsideCanvasViewport(Offset localPosition) {
    final renderObject = _canvasKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return false;
    return Rect.fromLTWH(
      0,
      0,
      renderObject.size.width,
      renderObject.size.height,
    ).contains(localPosition);
  }

  Offset _clipPreviewEndpoint(Offset start, Offset end) {
    final document = widget.engine.documentInfo;
    final delta = end - start;
    var amount = 1.0;
    if (delta.dx < 0 && end.dx < 0) {
      amount = math.min(amount, -start.dx / delta.dx);
    } else if (delta.dx > 0 && end.dx > document.widthPx - 1) {
      amount = math.min(amount, (document.widthPx - 1 - start.dx) / delta.dx);
    }
    if (delta.dy < 0 && end.dy < 0) {
      amount = math.min(amount, -start.dy / delta.dy);
    } else if (delta.dy > 0 && end.dy > document.heightPx - 1) {
      amount = math.min(amount, (document.heightPx - 1 - start.dy) / delta.dy);
    }
    return _boundedStrokePosition(start + delta * amount.clamp(0.0, 1.0));
  }

  int _previewIndexForAcknowledgement(StrokeAcknowledgement acknowledgement) {
    return _liveStrokeCoordinator.previewIndexForSourceSequence(
      acknowledgement.highestCommittedSequence,
    );
  }

  Future<void> _handleDrawingEventSafely(
    PointerEvent event,
    int sourceSequence,
    Offset preparedPosition,
  ) async {
    try {
      await _handleDrawingEvent(event, sourceSequence, preparedPosition);
    } catch (error, stack) {
      debugPrint('Project Ink pointer handling failed: $error\n$stack');
      await _abortStrokeAfterPacketError();
    }
  }

  Future<void> _undo() async {
    try {
      // Input packets and EndStroke are serialized through this queue. Wait
      // for the active pointer transaction to commit before advancing history;
      // otherwise a fast Cmd/Ctrl+Z can undo the previous stroke while the
      // just-finished stroke is still being committed by the bridge.
      await _strokeWork;
      await widget.engine.undo();
      widget.autosave?.markDirty();
      await _refreshLayerProjection();
      unawaited(_refreshTiles());
    } catch (error, stack) {
      debugPrint('Project Ink undo failed: $error\n$stack');
    }
  }

  Future<void> _redo() async {
    try {
      await _strokeWork;
      await widget.engine.redo();
      widget.autosave?.markDirty();
      await _refreshLayerProjection();
      unawaited(_refreshTiles());
    } catch (error, stack) {
      debugPrint('Project Ink redo failed: $error\n$stack');
    }
  }

  Future<void> _navigateHistory(int sequence) async {
    try {
      await widget.engine.navigateHistory(sequence);
      widget.autosave?.markDirty();
      await _loadPhase2Projections();
      await _refreshTiles();
      await _loadVectorStrokesForSelection();
      if (mounted) setState(() {});
    } catch (error, stack) {
      debugPrint('Project Ink history navigation failed: $error\n$stack');
    }
  }

  Future<void> _abortStrokeAfterPacketError({
    bool preservePreview = false,
  }) async {
    if (!_strokeActive) {
      _awaitingPreviewCommit = false;
      if (!preservePreview) {
        _liveStrokeCoordinator.clear();
        _lastPublishedPreviewAcknowledgement = null;
        _setStrokePreview(null);
      }
      return;
    }
    try {
      await widget.engine.cancelStroke();
      unawaited(_livePreviewSurface?.cancelAllStrokes());
    } catch (error, stack) {
      debugPrint(
        'Project Ink failed to cancel rejected stroke: $error\n$stack',
      );
    }
    _strokeActive = false;
    _activeStrokeIsTouch = false;
    _strokeCaptureEndedAtBoundary = false;
    _nativeLastSampleInsideDocument = false;
    _awaitingPreviewCommit = false;
    if (!preservePreview) {
      _liveStrokeCoordinator.clear();
      _lastPublishedPreviewAcknowledgement = null;
      _setStrokePreview(null);
    }
    _finishConstraintStroke();
    _stylusHoldTimer?.cancel();
    _stylusLastPosition = null;
    widget.autosave?.markDirty();
  }

  void _armDrawAndHold(Offset position) {
    _stylusHoldTimer?.cancel();
    if (_straightenMode || _constrainMode) return;
    if (!_strokeActive || _constraintStrokeStart == null) return;
    if ((position - _constraintStrokeStart!).distance < 8) return;
    const holdDuration = Duration(milliseconds: 320);
    final elapsedSinceArrival =
        _nativeInputArrivalClock.elapsedMicroseconds -
        _lastNativeInputArrivalUs;
    final remainingMicros =
        math.max(0, holdDuration.inMicroseconds - elapsedSinceArrival).toInt();
    _stylusHoldTimer = Timer(Duration(microseconds: remainingMicros), () {
      if (!_strokeActive ||
          _stylusLastPosition != position ||
          _nativePacketDrainQueued ||
          _pendingNativePackets.isNotEmpty) {
        return;
      }
      _canvasDiagnostics.record('canvas.draw_and_hold_activated', {
        'gesture': _gestureDefaults.bindings['drawAndHold']?.name,
        'triggerPosition': {'x': position.dx, 'y': position.dy},
        'constraintStart': {
          'x': _constraintStrokeStart?.dx,
          'y': _constraintStrokeStart?.dy,
        },
        'latestInputAgeUs':
            _nativeInputArrivalClock.elapsedMicroseconds -
            _lastNativeInputArrivalUs,
        'nativePacketQueueDepth': _pendingNativePackets.length,
        'strokeWorkQueueDepth': _strokeOperations.length,
      });
      _runMappedGesture(_gestureDefaults.bindings['drawAndHold']);
    });
  }

  String get _strokeConstraintMode =>
      _straightenMode
          ? 'straighten'
          : _constrainMode
          ? 'constrain'
          : 'none';

  Offset _applyStrokeConstraint(Offset position, {required bool hasDown}) {
    if (hasDown || _constraintStrokeStart == null) {
      _constraintStrokeStart = position;
      _straightenDirection = null;
      return position;
    }
    final start = _constraintStrokeStart!;
    final delta = position - start;
    if (delta.distance < 0.5) return position;
    if (_straightenMode) {
      _straightenDirection ??= delta / delta.distance;
      final direction = _straightenDirection!;
      return start +
          direction * (delta.dx * direction.dx + delta.dy * direction.dy);
    }
    if (_constrainMode) {
      final angle = math.atan2(delta.dy, delta.dx);
      const increment = math.pi / 12;
      final snappedAngle = (angle / increment).round() * increment;
      final distance = delta.distance;
      return start +
          Offset(math.cos(snappedAngle), math.sin(snappedAngle)) * distance;
    }
    return position;
  }

  void _finishConstraintStroke() {
    _constraintStrokeStart = null;
    _straightenDirection = null;
    _straightenMode = false;
    _constrainMode = false;
  }

  Offset _canvasPosition(Offset localPosition) {
    final renderObject = _canvasKey.currentContext?.findRenderObject();
    final size = renderObject is RenderBox ? renderObject.size : Size.zero;
    final centered = localPosition - size.center(Offset.zero) - _pan;
    final inverseScale = centered / _scale;
    final sine = math.sin(_rotation);
    final cosine = math.cos(_rotation);
    final unrotated = Offset(
      inverseScale.dx * cosine + inverseScale.dy * sine,
      -inverseScale.dx * sine + inverseScale.dy * cosine,
    );
    return _snapCanvasPosition(
      unrotated +
          Offset(
            widget.engine.documentInfo.widthPx / 2,
            widget.engine.documentInfo.heightPx / 2,
          ),
    );
  }

  Offset _boundedStrokePosition(Offset position) {
    final document = widget.engine.documentInfo;
    return Offset(
      position.dx.clamp(0.0, (document.widthPx - 1).toDouble()).toDouble(),
      position.dy.clamp(0.0, (document.heightPx - 1).toDouble()).toDouble(),
    );
  }

  Offset _safeInputPosition(Offset position) => Offset(
    position.dx.clamp(-65536.0, 65536.0).toDouble(),
    position.dy.clamp(-65536.0, 65536.0).toDouble(),
  );

  Offset _snapCanvasPosition(Offset position) {
    if (_activeTool != IllustrationTool.brush &&
        _activeTool != IllustrationTool.eraser) {
      return position;
    }
    final start = _rulerStart;
    final end = _rulerEnd;
    final tool = _rulerTool;
    if (start == null ||
        end == null ||
        tool == null ||
        (end - start).distance < 0.01) {
      return position;
    }
    final delta = end - start;
    final lengthSquared = delta.dx * delta.dx + delta.dy * delta.dy;
    if (lengthSquared <= 0.0001) return position;
    final amount =
        ((position - start).dx * delta.dx + (position - start).dy * delta.dy) /
        lengthSquared;
    final projected = start + delta * amount;
    if (tool == IllustrationTool.straightRuler ||
        tool == IllustrationTool.parallelRuler ||
        tool == IllustrationTool.perspectiveRuler) {
      return projected;
    }
    if (tool == IllustrationTool.symmetryRuler) {
      return projected * 2 - position;
    }
    if (tool == IllustrationTool.radialRuler) {
      final center = start;
      final radius = (position - center).distance;
      final angle = math.atan2(
        position.dy - center.dy,
        position.dx - center.dx,
      );
      const spokes = 8;
      const step = 2 * math.pi / spokes;
      final snapped = (angle / step).round() * step;
      return center + Offset(math.cos(snapped), math.sin(snapped)) * radius;
    }
    return position;
  }

  Future<void> _refreshTiles({bool initial = false}) async {
    if (_disposed) return;
    if (_refreshingTiles) {
      // A release can arrive while an earlier refresh is decoding tiles. Do
      // not drop that request: the earlier batch may have been drained before
      // the release packet reached Rust, leaving the committed tile outside
      // the batch that is currently being painted.
      _refreshRequested = true;
      _refreshInitialRequested |= initial;
      return;
    }
    _refreshingTiles = true;
    final engine = widget.engine;
    final generation = _engineGeneration;
    final tileDecodeClock = Stopwatch()..start();
    var drainTileUpdatesUs = 0;
    var compositeSnapshotReadUs = 0;
    var tileImageDecodeUs = 0;
    var decodedTileCount = 0;
    var snapshotPartCount = 0;
    try {
      // Tile invalidations and their stroke coverage share one Rust event
      // drain. Two separate bridge calls could race a worker commit between
      // them, causing drainTileUpdates to consume an acknowledgement without
      // returning it and leaving the degraded live preview on screen forever.
      final tileDrainClock = Stopwatch()..start();
      final batch = await engine.drainTileUpdates();
      tileDrainClock.stop();
      drainTileUpdatesUs = tileDrainClock.elapsedMicroseconds;
      if (batch.rendererBusy) {
        _canvasDiagnostics.record('canvas.cpu_tile_poll_deferred', {
          'revision': batch.revision,
          'strokeWorkQueueDepth': _strokeOperations.length,
          'nativePacketQueueDepth': _pendingNativePackets.length,
          'renderer': 'flutter_canvas',
        });
      }
      final batchReceivedAtRefreshUs = tileDecodeClock.elapsedMicroseconds;
      final strokeAcknowledgements = batch.acknowledgements;
      final cpuCommitBatchId =
          batch.tiles.isNotEmpty || strokeAcknowledgements.isNotEmpty
              ? ++_cpuCommitBatchId
              : _cpuCommitBatchId;
      if (strokeAcknowledgements.isNotEmpty) {
        _canvasDiagnostics.record('canvas.cpu_commit_batch_received', {
          'commitId': cpuCommitBatchId,
          'revision': batch.revision,
          'tileUpdates': batch.tiles.length,
          'strokeAcknowledgements': strokeAcknowledgements.length,
          'strokeIds': strokeAcknowledgements
              .map((acknowledgement) => acknowledgement.stroke.toString())
              .toList(growable: false),
          'strokeMetrics': strokeAcknowledgements
              .map(
                (acknowledgement) => <String, Object?>{
                  'strokeId': acknowledgement.stroke.toString(),
                  'throughSourceSequence':
                      acknowledgement.highestCommittedSequence,
                  'revision': acknowledgement.revision,
                  'confirmedSampleCount': acknowledgement.confirmedSampleCount,
                  'pathLength': acknowledgement.pathLength,
                  'directLength': acknowledgement.directLength,
                  'legacyDabs': acknowledgement.legacyDabs,
                  'compiledDabs': acknowledgement.compiledDabs,
                  'cpuTilesWritten': acknowledgement.cpuTilesWritten,
                  'compiledCpuTileUpdates':
                      acknowledgement.compiledCpuTileUpdates,
                  'workSegments': acknowledgement.workSegments,
                  'workLimitReached': acknowledgement.workLimitReached,
                },
              )
              .toList(growable: false),
        });
      }
      if (_livePreviewSurface != null) {
        _pendingLiveStrokeAcks.addAll(strokeAcknowledgements);
      }
      for (final acknowledgement in strokeAcknowledgements) {
        if (!_pendingCpuStrokeAcks.any(
          (pending) =>
              pending.stroke == acknowledgement.stroke &&
              pending.highestCommittedSequence ==
                  acknowledgement.highestCommittedSequence,
        )) {
          _pendingCpuStrokeAcks.add(acknowledgement);
        }
      }
      if (_disposed ||
          generation != _engineGeneration ||
          engine != widget.engine) {
        return;
      }
      final fullRedraw = initial || !_initialTilesLoaded || batch.fullRedraw;
      if (!fullRedraw &&
          batch.tiles.isEmpty &&
          strokeAcknowledgements.isEmpty &&
          _pendingCpuStrokeAcks.isEmpty) {
        return;
      }
      final cpuStrokeAcknowledgements = List<StrokeAcknowledgement>.of(
        _pendingCpuStrokeAcks,
      );

      final visibleLayers =
          _layers
              .where((layer) => layer.visible)
              .map((layer) => layer.id)
              .toSet();
      if (visibleLayers.isEmpty) {
        visibleLayers.add(engine.documentInfo.primaryRasterLayer);
      }
      final updates = batch.tiles
          .where(
            (update) =>
                update.layer == _compositeLayerId ||
                visibleLayers.contains(update.layer),
          )
          .toList(growable: false);
      final coordinates = <String, (int x, int y)>{};
      for (final update in updates) {
        coordinates['${update.x}:${update.y}'] = (update.x, update.y);
      }
      var revision = math.max(batch.revision, engine.revision);
      int? snapshotRevision;
      var snapshotCoherent = true;
      final snapshotPixels = <String, Uint8List>{};
      final acknowledgedCoordinates = <String, StrokeTileCoordinate>{};
      final acknowledgedTileRevisions = <String, int>{};
      final selectedCpuAcknowledgements = <StrokeAcknowledgement>[];
      StrokeAcknowledgement? oversizedSnapshotAcknowledgement;
      for (final acknowledgement in cpuStrokeAcknowledgements) {
        final newCoordinates = acknowledgement.dirtyTiles
            .where(
              (coordinate) =>
                  !acknowledgedCoordinates.containsKey(
                    '${coordinate.x}:${coordinate.y}',
                  ),
            )
            .toList(growable: false);
        if (acknowledgedCoordinates.length + newCoordinates.length >
            _maxCpuHandoffSnapshotTiles) {
          // A single Rust acknowledgement is one CPU commit group. Keep it
          // intact even when it spans more than the usual per-refresh tile
          // budget: the bridge reads it in bounded 16 MiB parts below, and
          // the live path must not wait forever for an acknowledgement that
          // can never fit in the selection budget.
          if (selectedCpuAcknowledgements.isNotEmpty) break;
          oversizedSnapshotAcknowledgement = acknowledgement;
        }
        selectedCpuAcknowledgements.add(acknowledgement);
        for (final coordinate in acknowledgement.dirtyTiles) {
          final key = '${coordinate.x}:${coordinate.y}';
          acknowledgedCoordinates[key] = coordinate;
          acknowledgedTileRevisions[key] = math.max(
            acknowledgedTileRevisions[key] ?? 0,
            acknowledgement.revision,
          );
        }
      }
      if (selectedCpuAcknowledgements.length <
          cpuStrokeAcknowledgements.length) {
        _canvasDiagnostics.record('canvas.cpu_commit_snapshot_deferred', {
          'commitId': cpuCommitBatchId,
          'reason': 'bounded_snapshot_group',
          'selectedAcknowledgements': selectedCpuAcknowledgements.length,
          'pendingAcknowledgements': cpuStrokeAcknowledgements.length,
          'selectedTiles': acknowledgedCoordinates.length,
          'tileLimit': _maxCpuHandoffSnapshotTiles,
          'oversizedCommitTiles':
              oversizedSnapshotAcknowledgement?.dirtyTiles.length ?? 0,
        });
      }
      if (oversizedSnapshotAcknowledgement != null) {
        _canvasDiagnostics.record('canvas.cpu_commit_snapshot_multipart', {
          'commitId': cpuCommitBatchId,
          'strokeId': oversizedSnapshotAcknowledgement.stroke.toString(),
          'throughSourceSequence':
              oversizedSnapshotAcknowledgement.highestCommittedSequence,
          'tileCount': oversizedSnapshotAcknowledgement.dirtyTiles.length,
          'bridgePartCount':
              (oversizedSnapshotAcknowledgement.dirtyTiles.length +
                  maxCompositeTileSnapshotTiles -
                  1) ~/
              maxCompositeTileSnapshotTiles,
        });
      }
      for (final acknowledgement in selectedCpuAcknowledgements) {
        for (final coordinate in acknowledgement.dirtyTiles) {
          coordinates['${coordinate.x}:${coordinate.y}'] = (
            coordinate.x,
            coordinate.y,
          );
        }
      }
      final snapshotCoordinates =
          acknowledgedCoordinates.isNotEmpty
              ? acknowledgedCoordinates.values.toList(growable: false)
              : coordinates.values
                  .map(
                    (coordinate) =>
                        StrokeTileCoordinate(coordinate.$1, coordinate.$2),
                  )
                  .take(_maxCpuHandoffSnapshotTiles)
                  .toList(growable: false);
      Future<void> readSnapshotPart(
        List<StrokeTileCoordinate> partCoordinates,
      ) async {
        if (!snapshotCoherent || partCoordinates.isEmpty) return;
        final part = await engine.readCompositeTilesSnapshot(
          coordinates: partCoordinates,
        );
        if (snapshotRevision != null && snapshotRevision != part.revision) {
          snapshotCoherent = false;
          return;
        }
        snapshotRevision = part.revision;
        for (final tile in part.tiles) {
          snapshotPixels['${tile.x}:${tile.y}'] = tile.bytes;
        }
      }

      if (snapshotCoordinates.isNotEmpty) {
        snapshotPartCount =
            (snapshotCoordinates.length + maxCompositeTileSnapshotTiles - 1) ~/
            maxCompositeTileSnapshotTiles;
        var partIndex = 0;
        final snapshotReadClock = Stopwatch()..start();
        for (
          var start = 0;
          start < snapshotCoordinates.length && snapshotCoherent;
          start += maxCompositeTileSnapshotTiles
        ) {
          final end = math.min(
            start + maxCompositeTileSnapshotTiles,
            snapshotCoordinates.length,
          );
          _canvasDiagnostics.record('canvas.cpu_commit_snapshot_part', {
            'commitId': cpuCommitBatchId,
            'partIndex': partIndex,
            'partCount': snapshotPartCount,
            'tileCount': end - start,
          });
          await readSnapshotPart(snapshotCoordinates.sublist(start, end));
          partIndex++;
        }
        snapshotReadClock.stop();
        compositeSnapshotReadUs = snapshotReadClock.elapsedMicroseconds;
      }
      if (!snapshotCoherent) {
        snapshotPixels.clear();
        _canvasDiagnostics.record('canvas.cpu_commit_snapshot_deferred', {
          'commitId': cpuCommitBatchId,
          'reason': 'document_revision_changed_between_parts',
          'tileCount': snapshotCoordinates.length,
        });
      } else if (snapshotRevision != null) {
        revision = math.max(revision, snapshotRevision!);
        _canvasDiagnostics.record('canvas.cpu_commit_pixel_snapshot', {
          'commitId': cpuCommitBatchId,
          'snapshotRevision': snapshotRevision,
          'tileCount': snapshotPixels.length,
          'sameRevision': true,
        });
      }
      if (fullRedraw) {
        // Keep the previous frame visible while a full snapshot is decoded.
        // Clearing the GPU cache here makes layer changes flash white/empty
        // before the replacement tiles are ready.
        _tileBytes.clear();
      }

      var changed = false;
      var deferredAcknowledgedTiles = 0;
      for (final coordinate in coordinates.values) {
        final coordinateKey = '${coordinate.$1}:${coordinate.$2}';
        final snapshotBytes = snapshotPixels[coordinateKey];
        final requiredAcknowledgementRevision =
            acknowledgedTileRevisions[coordinateKey];
        if (requiredAcknowledgementRevision != null &&
            (!snapshotCoherent ||
                snapshotRevision == null ||
                snapshotRevision! < requiredAcknowledgementRevision ||
                snapshotBytes == null)) {
          // Never publish a separately-read tile from an acknowledgement
          // group whose immutable snapshot was missing or crossed revisions.
          // The confirmed live path remains visible until the same CPU pixels
          // are available together, avoiding double-darkening and a partial
          // CPU/live splice. The acknowledgement remains pending for retry.
          deferredAcknowledgedTiles++;
          continue;
        }
        final bytes =
            snapshotBytes ??
            await engine.readCompositeTile(x: coordinate.$1, y: coordinate.$2);
        if (_disposed ||
            generation != _engineGeneration ||
            engine != widget.engine) {
          return;
        }
        final accepted = _tileBytes.put(
          revision,
          _compositeLayerId,
          coordinate.$1,
          coordinate.$2,
          bytes,
        );
        if (!accepted) continue;
        _canvasDiagnostics.recordCompositeTile(
          revision: revision,
          x: coordinate.$1,
          y: coordinate.$2,
          pixelBytes: bytes,
          // Preserve exact CPU output for the committed final frame. During
          // the stroke only compact hashes are logged, keeping long captures
          // within their fixed size budget.
          includePixels: !_strokeActive && _awaitingPreviewCommit,
        );
        final key = TileCacheKey(
          revision,
          _compositeLayerId,
          coordinate.$1,
          coordinate.$2,
        );
        final tileImageClock = Stopwatch()..start();
        await _tileImages.put(key, bytes);
        tileImageClock.stop();
        tileImageDecodeUs += tileImageClock.elapsedMicroseconds;
        decodedTileCount++;
        changed = true;
      }
      if (deferredAcknowledgedTiles > 0) {
        _canvasDiagnostics.record('canvas.cpu_commit_tiles_deferred', {
          'commitId': cpuCommitBatchId,
          'tileCount': deferredAcknowledgedTiles,
          'snapshotCoherent': snapshotCoherent,
          'snapshotRevision': snapshotRevision,
          'reason': 'acknowledged_pixels_not_coherent',
        });
      }
      _initialTilesLoaded = true;
      if (fullRedraw) {
        _renderRevision = revision;
        _tileImages.retainRevision(revision);
      } else {
        // Dirty images are decoded into the new revision while the current
        // frame remains visible. Promote unchanged tiles only after every
        // replacement image is ready, then switch the revision in the same
        // state publication that advances live stroke coverage.
        final previousRevision = _renderRevision;
        _tileImages.promoteRevision(previousRevision, revision);
        _renderRevision = revision;
      }
      var acknowledgedPreviewThrough = -1;
      final publishedCpuAcknowledgements = <StrokeAcknowledgement>[];
      final publishedPixelAcknowledgements = <StrokeAcknowledgement>[];
      for (final acknowledgement in selectedCpuAcknowledgements) {
        if (acknowledgement.revision > revision) continue;
        final matchingCompositeTiles =
            acknowledgement.dirtyTiles
                .where(
                  (coordinate) => batch.tiles.any(
                    (tile) =>
                        tile.layer == _compositeLayerId &&
                        tile.revision == acknowledgement.revision &&
                        tile.x == coordinate.x &&
                        tile.y == coordinate.y,
                  ),
                )
                .length;
        final allDirtyTilePixelsDecoded = acknowledgement.dirtyTiles.every(
          (coordinate) =>
              snapshotPixels.containsKey('${coordinate.x}:${coordinate.y}'),
        );
        final hasPublishedPixels =
            acknowledgement.dirtyTiles.isEmpty ||
            (snapshotCoherent &&
                snapshotRevision != null &&
                snapshotRevision! >= acknowledgement.revision &&
                allDirtyTilePixelsDecoded);
        if (hasPublishedPixels) {
          publishedPixelAcknowledgements.add(acknowledgement);
        }
        final previewIndex =
            hasPublishedPixels
                ? _previewIndexForAcknowledgement(acknowledgement)
                : -1;
        if (previewIndex < 0) continue;
        _lastPublishedPreviewAcknowledgement = acknowledgement;
        _canvasDiagnostics.record('canvas.cpu_commit_handoff', {
          'commitId': cpuCommitBatchId,
          'strokeId': acknowledgement.stroke.toString(),
          'throughSourceSequence': acknowledgement.highestCommittedSequence,
          'ackRevision': acknowledgement.revision,
          'publishedRevision': revision,
          'matchingCompositeTiles': matchingCompositeTiles,
          'fullRedraw': batch.fullRedraw,
          'hasPublishedPixels': hasPublishedPixels,
          'previewIndex': previewIndex,
          'confirmedSampleCount': acknowledgement.confirmedSampleCount,
          'pathLength': acknowledgement.pathLength,
          'directLength': acknowledgement.directLength,
          'legacyDabs': acknowledgement.legacyDabs,
          'compiledDabs': acknowledgement.compiledDabs,
          'cpuTilesWritten': acknowledgement.cpuTilesWritten,
          'compiledCpuTileUpdates': acknowledgement.compiledCpuTileUpdates,
          'workSegments': acknowledgement.workSegments,
          'workLimitReached': acknowledgement.workLimitReached,
        });
        publishedCpuAcknowledgements.add(acknowledgement);
        acknowledgedPreviewThrough = math.max(
          acknowledgedPreviewThrough,
          previewIndex,
        );
      }
      if (acknowledgedPreviewThrough >= 0) {
        // Keep the visible prefix contiguous: a later acknowledgement cannot
        // retire the live path across an earlier commit whose matching CPU
        // pixels have not been published yet. Source sequences can skip due
        // to discarded prediction samples, so use preview indices for order.
        final publishedSet = publishedCpuAcknowledgements.toSet();
        for (final acknowledgement in _pendingCpuStrokeAcks) {
          if (publishedSet.contains(acknowledgement)) continue;
          final pendingIndex = _previewIndexForAcknowledgement(acknowledgement);
          // A missing index means this acknowledgement refers to a prefix
          // already compacted/retired from the live path (or a sample clipped
          // before it entered the preview). It must not block later coverage.
          if (pendingIndex >= 0 && pendingIndex <= acknowledgedPreviewThrough) {
            acknowledgedPreviewThrough = math.min(
              acknowledgedPreviewThrough,
              pendingIndex - 1,
            );
            break;
          }
        }
      }
      final previewProgressChanged = acknowledgedPreviewThrough >= 0;
      final cpuCoverageFrameFields =
          acknowledgedPreviewThrough >= 0
              ? <String, Object?>{
                'cpuCoveragePreviewIndex': acknowledgedPreviewThrough,
                'cpuCoverageCommitId': cpuCommitBatchId,
              }
              : const <String, Object?>{};
      Map<String, Object?>? retiredPreviewFields;
      // A pixel commit is complete even if its source sequence no longer has
      // a retained preview index. The preview prefix was already compacted,
      // clipped, or ended, so keeping this acknowledgement cannot advance UI
      // coverage and would cause the same tile snapshot to be reread forever.
      _pendingCpuStrokeAcks.removeWhere(
        (acknowledgement) =>
            publishedPixelAcknowledgements.contains(acknowledgement) &&
            (_strokePreview.value == null ||
                _previewIndexForAcknowledgement(acknowledgement) < 0),
      );
      // A full redraw with no tiles is a valid empty document (for example,
      // undoing the only stroke). The cache has already retired the previous
      // frame above, so repaint even when no replacement image was decoded.
      if ((changed || fullRedraw || previewProgressChanged) && mounted) {
        final livePreview = _strokePreview.value;
        if (livePreview != null) {
          final candidateThrough = acknowledgedPreviewThrough;
          if (candidateThrough >= 0) {
            final confirmedThrough =
                (candidateThrough + 1)
                    .clamp(
                      livePreview.confirmedThrough,
                      livePreview.points.length,
                    )
                    .toInt();
            _setStrokePreview(
              livePreview.copyWith(
                confirmedThrough: confirmedThrough,
                revision: livePreview.revision + 1,
              ),
            );
            _pendingCpuStrokeAcks.removeWhere((acknowledgement) {
              final index = _previewIndexForAcknowledgement(acknowledgement);
              return publishedCpuAcknowledgements.contains(acknowledgement) &&
                  (index < 0 || index <= candidateThrough);
            });
            _liveStrokeCoordinator.retireThrough(candidateThrough);
          }
          final committedPreview = _strokePreview.value;
          if (!_strokeActive &&
              _awaitingPreviewCommit &&
              committedPreview != null &&
              committedPreview.confirmedThrough >=
                  committedPreview.points.length) {
            final terminalAcknowledgement =
                publishedCpuAcknowledgements
                    .where(
                      (acknowledgement) =>
                          _previewIndexForAcknowledgement(acknowledgement) >=
                          candidateThrough,
                    )
                    .lastOrNull ??
                publishedCpuAcknowledgements.lastOrNull ??
                _lastPublishedPreviewAcknowledgement;
            retiredPreviewFields = <String, Object?>{
              'strokeId': terminalAcknowledgement?.stroke.toString(),
              'throughSourceSequence':
                  terminalAcknowledgement?.highestCommittedSequence ??
                  committedPreview.points.last.sourceSequence,
              'previewIndex': committedPreview.confirmedThrough - 1,
              'pointCount': committedPreview.points.length,
              'cpuRevision': revision,
              'commitId': cpuCommitBatchId,
              'terminalAcknowledgementInCurrentRefresh':
                  publishedCpuAcknowledgements.isNotEmpty,
            };
            _setStrokePreview(null);
            _liveStrokeCoordinator.clear();
            _lastPublishedPreviewAcknowledgement = null;
            _awaitingPreviewCommit = false;
            _pendingCpuStrokeAcks.clear();
          }
        }
        final packetMicros = _lastPacketMicros;
        final dirtyTiles = updates.length;
        final tileDecode = tileDecodeClock.elapsed;
        _canvasDiagnostics.record('canvas.cpu_commit_stage_timing', {
          'commitId': cpuCommitBatchId,
          'revision': revision,
          'tileUpdates': batch.tiles.length,
          'snapshotTilesRequested': snapshotCoordinates.length,
          'snapshotTilesReturned': snapshotPixels.length,
          'snapshotParts': snapshotPartCount,
          'decodedTiles': decodedTileCount,
          'drainTileUpdatesUs': drainTileUpdatesUs,
          'compositeSnapshotReadUs': compositeSnapshotReadUs,
          'tileImageDecodeUs': tileImageDecodeUs,
          'refreshToSetStateUs': tileDecode.inMicroseconds,
          'renderer': 'flutter_canvas',
        });
        setState(() {});
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _canvasDiagnostics.record('canvas.cpu_frame_presented', {
            'revision': revision,
            'dirtyTiles': dirtyTiles,
            'fullRedraw': fullRedraw,
            ...cpuCoverageFrameFields,
            'strokeWorkQueueDepth': _strokeOperations.length,
            'nativePacketQueueDepth': _pendingNativePackets.length,
            'batchToFrameUs':
                tileDecodeClock.elapsedMicroseconds - batchReceivedAtRefreshUs,
            'refreshToFrameUs': tileDecodeClock.elapsedMicroseconds,
            'renderer': 'flutter_canvas',
            'gpuPreviewReady':
                _livePreviewSurface?.gpuFrameReady.value ?? false,
          });
          final retired = retiredPreviewFields;
          if (retired != null) {
            _canvasDiagnostics.record('canvas.live_preview_retired', retired);
          }
        });
        _scheduleLiveStrokeAcknowledgements(revision);
        if (packetMicros != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _performanceTrace.markVisibleUpdate(
              packetMicros: packetMicros,
              tileDecode: tileDecode,
              dirtyTiles: dirtyTiles,
            );
            widget.onPerformanceSnapshot?.call(_performanceTrace.snapshot());
          });
        }
      }
      // CPU pixels may arrive after the UI preview has already ended (for
      // example after a tool/document transition). Once a commit's immutable
      // pixels are present, there is no live geometry left for it to retire;
      // discard its acknowledgement instead of snapshotting it on every poll.
      if (_strokePreview.value == null &&
          publishedCpuAcknowledgements.isNotEmpty) {
        _pendingCpuStrokeAcks.removeWhere(
          publishedCpuAcknowledgements.contains,
        );
      }
    } catch (error, stack) {
      if (!_disposed &&
          generation == _engineGeneration &&
          engine == widget.engine) {
        _canvasDiagnostics.recordError('canvas_tile_refresh', error, stack);
        debugPrint('Project Ink tile refresh failed: $error\n$stack');
      }
    } finally {
      _refreshingTiles = false;
      if (_refreshRequested && !_disposed) {
        final retryInitial = _refreshInitialRequested;
        _refreshRequested = false;
        _refreshInitialRequested = false;
        // Yield once so any queued pointer packet and its worker event are
        // visible before the follow-up drain. This is intentionally a single
        // coalesced retry; the regular 16 ms poll remains the backstop.
        scheduleMicrotask(() {
          if (!_disposed) unawaited(_refreshTiles(initial: retryInitial));
        });
      } else {
        _refreshInitialRequested = false;
      }
    }
  }

  void _scheduleLiveStrokeAcknowledgements(int publishedRevision) {
    final eligible = _pendingLiveStrokeAcks
        .where(
          (acknowledgement) => acknowledgement.revision <= publishedRevision,
        )
        .toList(growable: false);
    if (eligible.isEmpty) return;
    _pendingLiveStrokeAcks.removeWhere(eligible.contains);
    final liveSurface = _livePreviewSurface;
    if (liveSurface == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || !identical(liveSurface, _livePreviewSurface)) return;
      for (final acknowledgement in eligible) {
        unawaited(liveSurface.acknowledge(acknowledgement));
      }
    });
  }

  Future<void> _refreshLayerThumbnails() async {
    final engine = widget.engine;
    final generation = _engineGeneration;
    final current = _layers;
    if (current.isEmpty) return;
    final updated = await Future.wait(
      current.map((layer) async {
        try {
          final thumbnail = await engine.readLayerThumbnail(layerId: layer.id);
          return layer.copyWith(thumbnail: thumbnail);
        } catch (_) {
          return layer;
        }
      }),
    );
    if (!mounted ||
        generation != _engineGeneration ||
        engine != widget.engine) {
      return;
    }
    setState(() => _layers = updated);
  }

  Iterable<MapEntry<TileCacheKey, ui.Image>> get _visibleImages {
    final compositeEntries = _tileImages.entries
        .where(
          (entry) =>
              entry.key.revision == _renderRevision &&
              entry.key.layer == _compositeLayerId,
        )
        .toList(growable: false);
    if (compositeEntries.isNotEmpty) return compositeEntries;
    final visibleLayers =
        _layers
            .where((layer) => layer.visible)
            .map((layer) => layer.id)
            .toSet();
    if (visibleLayers.isEmpty) {
      visibleLayers.add(widget.engine.documentInfo.primaryRasterLayer);
    }
    final entries = _tileImages.entries
        .where(
          (entry) =>
              entry.key.revision == _renderRevision &&
              visibleLayers.contains(entry.key.layer),
        )
        .toList(growable: false);
    entries.sort((left, right) {
      final layerOrder = left.key.layer.compareTo(right.key.layer);
      if (layerOrder != 0) return layerOrder;
      final yOrder = left.key.y.compareTo(right.key.y);
      return yOrder != 0 ? yOrder : left.key.x.compareTo(right.key.x);
    });
    return entries;
  }

  void _applyBrushDraft(BrushPresetView preset) {
    if (!mounted) return;
    setState(() => _activeBrushId = preset.id);
    final brushId = preset.id;
    final previous = _brushEditQueues[brushId] ?? Future<void>.value();
    final operation = previous.then<void>((_) async {
      var draftId = _activeBrushDrafts[brushId];
      if (draftId == null) {
        await _finishDanglingStrokeBeforeBrushEdit();
        try {
          draftId = await widget.engine.beginBrushDraft(brushId);
        } catch (_) {
          // A native Pencil stream can lose its terminal packet after a very
          // long/high-rate gesture. Rust is authoritative about whether that
          // transaction is still active. Close only that stale transaction,
          // then retry the brush edit once so the UI draft cannot diverge
          // from the brush used by the committed renderer.
          await widget.engine.endStroke();
          _clearFinishedStrokeState();
          draftId = await widget.engine.beginBrushDraft(brushId);
        }
        _activeBrushDrafts[brushId] = draftId;
        if (mounted) setState(() {});
      }
      await widget.engine.updateBrushDraft(
        draftId: draftId,
        diameter: preset.size,
        opacity: preset.opacity,
        spacing: preset.spacing,
        smoothing: preset.stabilization,
        pressureSize: preset.pressureSize,
        pressureOpacity: preset.pressureOpacity,
        pressureCurve: preset.pressureCurve,
        pressureCurvePoints: preset.pressureCurvePoints,
        hardness: preset.hardness,
        textureScale: preset.textureScale,
        scatter: preset.scatter,
        rotationJitter: preset.rotationJitter,
        smudge: preset.smudge,
        wetness: preset.wetness,
      );
    });
    _brushEditQueues[brushId] = operation.catchError((
      Object error,
      StackTrace stack,
    ) async {
      debugPrint('Project Ink brush draft rejected: $error\n$stack');
      final draftId = _activeBrushDrafts.remove(brushId);
      if (draftId != null) {
        try {
          await widget.engine.cancelBrushDraft(draftId);
        } catch (cancelError, cancelStack) {
          debugPrint(
            'Project Ink rejected brush draft cleanup failed: '
            '$cancelError\n$cancelStack',
          );
        }
      }
      if (mounted) await _loadPhase2Projections();
    });
  }

  Future<void> _finishDanglingStrokeBeforeBrushEdit() async {
    // Let all pointer packets already accepted by Flutter reach Rust first.
    // If the last native Pencil packet was lost, finish the accepted prefix
    // rather than rejecting the brush edit and keeping a preview-only size.
    await _strokeWork;
    if (!_strokeActive) return;
    try {
      await widget.engine.endStroke();
    } catch (_) {
      // Flutter may believe a stroke is active after Rust already finished
      // it. Reset the local gesture; beginBrushDraft below remains the
      // authority if Rust still has a transaction open.
    }
    _clearFinishedStrokeState();
    widget.autosave?.markDirty();
    unawaited(_refreshLayerThumbnails());
    unawaited(_refreshTiles());
  }

  void _clearFinishedStrokeState() {
    _strokeActive = false;
    _activeStrokeIsTouch = false;
    _strokeCaptureEndedAtBoundary = false;
    _nativeLastSampleInsideDocument = false;
    _awaitingPreviewCommit = true;
    _finishConstraintStroke();
    _stylusHoldTimer?.cancel();
    _stylusLastPosition = null;
  }

  void _updateBrushDraft(BrushPresetView preset) {
    _brushLibrary.updateDraft(preset);
    _applyBrushDraft(preset);
  }

  void _updateQuickBrushSizePreview(double size) {
    final brush = _brushLibrary.selected;
    if (brush == null || !size.isFinite) return;
    _pendingQuickBrushSize = size.clamp(0.25, 128.0).toDouble();
    _canvasDiagnostics.record('brush.quick_size_preview', {
      'brushId': brush.id,
      'activeBrushId': _activeBrushId,
      'sizePx': _pendingQuickBrushSize,
      'selectedBrushMatchesActive': brush.id == _activeBrushId,
    });
    _brushLibrary.updateDraft(brush.copyWith(size: size));
    if (mounted) setState(() {});
    // Some iPad stylus/touch streams cancel the slider's terminal callback.
    // Persist after a brief pause; onChangeEnd still commits immediately.
    _quickBrushSizeTimer?.cancel();
    _quickBrushSizeTimer = Timer(const Duration(milliseconds: 180), () {
      final pendingSize = _pendingQuickBrushSize;
      if (pendingSize != null) _persistBrushSize(pendingSize);
    });
  }

  void _persistBrushSize(double size) {
    _quickBrushSizeTimer?.cancel();
    _quickBrushSizeTimer = null;
    _pendingQuickBrushSize = null;
    final brush = _brushLibrary.selected;
    if (brush == null || !size.isFinite) return;
    final preset = brush.copyWith(size: size.clamp(0.25, 4096.0).toDouble());
    final brushId = preset.id;
    _canvasDiagnostics.record('brush.size_save_requested', {
      'brushId': brushId,
      'activeBrushId': _activeBrushId,
      'sizePx': preset.size,
      'selectedBrushMatchesActive': brushId == _activeBrushId,
    });
    _brushLibrary.updateDraft(preset);
    final previous = _brushEditQueues[brushId] ?? Future<void>.value();
    final operation = previous.then<void>((_) async {
      await _finishDanglingStrokeBeforeBrushEdit();
      final draftId = _activeBrushDrafts.remove(brushId);
      if (draftId != null) {
        await widget.engine.cancelBrushDraft(draftId);
      }
      await widget.engine.updateBrushSettings(
        brushId: brushId,
        diameter: preset.size,
        opacity: preset.opacity,
        spacing: preset.spacing,
        smoothing: preset.stabilization,
        pressureSize: preset.pressureSize,
        pressureOpacity: preset.pressureOpacity,
        pressureCurve: preset.pressureCurve,
        pressureCurvePoints: preset.pressureCurvePoints,
        hardness: preset.hardness,
        textureScale: preset.textureScale,
        scatter: preset.scatter,
        rotationJitter: preset.rotationJitter,
        smudge: preset.smudge,
        wetness: preset.wetness,
      );
      final readBack = await widget.engine.builtinBrushes();
      final savedBrush = readBack.where((entry) => entry.id == brushId);
      final savedSize = savedBrush.isEmpty ? null : savedBrush.first.diameterPx;
      _canvasDiagnostics.record('brush.size_saved', {
        'brushId': brushId,
        'requestedSizePx': preset.size,
        'savedSizePx': savedSize,
        'matchesRequested':
            savedSize != null && (savedSize - preset.size).abs() < 0.01,
      });
      widget.autosave?.markDirty();
      await _loadPhase2Projections();
      if (mounted) setState(() {});
    });
    _brushEditQueues[brushId] = operation.catchError((
      Object error,
      StackTrace stack,
    ) async {
      _canvasDiagnostics.recordError('brush.size_save_failed', error, stack);
      debugPrint('Project Ink quick brush size update failed: $error\n$stack');
      final draftId = _activeBrushDrafts.remove(brushId);
      if (draftId != null) {
        try {
          await widget.engine.cancelBrushDraft(draftId);
        } catch (_) {}
      }
      await _loadPhase2Projections();
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('Could not update brush size: $error')),
        );
        setState(() {});
      }
    });
  }

  void _commitBrushDraft(int brushId) {
    final previous = _brushEditQueues[brushId] ?? Future<void>.value();
    final operation = previous.then<void>((_) async {
      final draftId = _activeBrushDrafts.remove(brushId);
      if (draftId != null) {
        await widget.engine.commitBrushDraft(draftId);
        widget.autosave?.markDirty();
      }
      _brushEditQueues.remove(brushId);
      if (mounted) setState(() {});
    });
    _brushEditQueues[brushId] = operation.catchError((
      Object error,
      StackTrace stack,
    ) async {
      debugPrint('Project Ink brush draft commit rejected: $error\n$stack');
      final draftId = _activeBrushDrafts.remove(brushId);
      if (draftId != null) {
        try {
          await widget.engine.cancelBrushDraft(draftId);
        } catch (cancelError, cancelStack) {
          debugPrint(
            'Project Ink rejected brush commit cleanup failed: '
            '$cancelError\n$cancelStack',
          );
        }
      }
      if (mounted) await _loadPhase2Projections();
    });
  }

  void _commitSelectedBrushDraft() {
    final brushId = _brushLibrary.selected?.id;
    if (brushId != null) _commitBrushDraft(brushId);
  }

  void _cancelBrushDraft() {
    final brushId = _brushLibrary.selected?.id;
    if (brushId == null) return;
    final previous = _brushEditQueues[brushId] ?? Future<void>.value();
    final operation = previous.then<void>((_) async {
      final draftId = _activeBrushDrafts.remove(brushId);
      if (draftId != null) {
        await widget.engine.cancelBrushDraft(draftId);
      }
      await _loadPhase2Projections();
      _brushEditQueues.remove(brushId);
    });
    _brushEditQueues[brushId] = operation.catchError((
      Object error,
      StackTrace stack,
    ) async {
      debugPrint(
        'Project Ink brush draft cancellation rejected: $error\n$stack',
      );
      _activeBrushDrafts.remove(brushId);
      _brushEditQueues.remove(brushId);
      if (mounted) await _loadPhase2Projections();
    });
  }

  Future<void> _duplicateBrush() async {
    final selected = _brushLibrary.selected;
    if (selected == null) return;
    try {
      final duplicateId = await widget.engine.duplicateBrush(selected.id);
      await _loadPhase2Projections();
      if (!mounted) return;
      setState(() {
        _brushLibrary.select(duplicateId);
        _activeBrushId = duplicateId;
      });
      widget.autosave?.markDirty();
    } catch (error, stack) {
      debugPrint('Project Ink brush duplicate failed: $error\n$stack');
    }
  }

  Future<void> _renameBrush() async {
    final selected = _brushLibrary.selected;
    if (selected == null || selected.id < 13) return;
    final name = await showDialog<String>(
      context: context,
      builder: (_) => BrushRenameDialog(initialName: selected.name),
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    try {
      await widget.engine.renameBrush(brushId: selected.id, name: name);
      await _loadPhase2Projections();
      if (!mounted) return;
      _brushLibrary.select(selected.id);
      widget.autosave?.markDirty();
    } catch (error, stack) {
      debugPrint('Project Ink brush rename failed: $error\\n$stack');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not rename brush: $error')),
        );
      }
    }
  }

  Future<void> _addLayer(LayerKind kind) async {
    final wireKind = switch (kind) {
      LayerKind.raster => 'Raster',
      LayerKind.vectorInk => 'VectorInk',
      LayerKind.group => 'Group',
      LayerKind.mask => 'Mask',
      LayerKind.tone => 'Tone',
      LayerKind.panelGroup => 'PanelGroup',
      LayerKind.adjustment => 'Adjustment',
    };
    try {
      final selectedParentId = selectedLayerParentForAdd(
        kind,
        _layers,
        _layerSelection.selected,
      );
      final id =
          selectedParentId == null
              ? await widget.engine.addLayer(kind: wireKind)
              : await widget.engine.addLayerToParent(
                kind: wireKind,
                parentId: selectedParentId,
              );
      await _loadPhase2Projections();
      _layerSelection.select(id);
      if (mounted) setState(() {});
    } catch (error, stack) {
      debugPrint('Project Ink layer creation rejected: $error\n$stack');
    }
  }

  Future<void> _moveLayerBy(LayerView layer, int delta) async {
    final siblings = _layers
      .where((candidate) => candidate.parent == layer.parent)
      .toList(growable: false)..sort((left, right) {
      final order = left.order.compareTo(right.order);
      return order != 0 ? order : left.id.compareTo(right.id);
    });
    final current = siblings.indexWhere(
      (candidate) => candidate.id == layer.id,
    );
    if (current < 0) return;
    final target = (current + delta).clamp(0, siblings.length - 1);
    if (target == current) return;
    try {
      await widget.engine.moveLayer(
        layerId: layer.id,
        parentId: layer.parent,
        index: target,
      );
      await _loadPhase2Projections();
      await _refreshTiles();
    } catch (error, stack) {
      debugPrint('Project Ink layer reorder rejected: $error\n$stack');
    }
  }

  Future<void> _deleteLayer(LayerView layer) async {
    final siblings = _layers
      .where((candidate) => candidate.parent == layer.parent)
      .toList(growable: false)..sort((left, right) {
      final order = left.order.compareTo(right.order);
      return order != 0 ? order : left.id.compareTo(right.id);
    });
    final index = siblings.indexWhere((candidate) => candidate.id == layer.id);
    final nextSelection =
        siblings.length > 1 ? siblings[index == 0 ? 1 : index - 1].id : null;
    try {
      await widget.engine.deleteLayer(layerId: layer.id);
      await _loadPhase2Projections();
      _layerSelection.clear();
      if (nextSelection != null &&
          _layers.any((item) => item.id == nextSelection)) {
        _layerSelection.select(nextSelection);
      } else if (_layers.isNotEmpty) {
        _layerSelection.select(_layers.last.id);
      }
      await _refreshTiles();
      if (mounted) setState(() {});
    } catch (error, stack) {
      debugPrint('Project Ink layer deletion rejected: $error\\n$stack');
      if (mounted) await _loadPhase2Projections();
    }
  }

  Future<void> _duplicateLayer(LayerView layer) async {
    try {
      final duplicateId = await widget.engine.duplicateLayer(layerId: layer.id);
      await _loadPhase2Projections();
      _layerSelection.clear();
      if (_layers.any((candidate) => candidate.id == duplicateId)) {
        _layerSelection.select(duplicateId);
      }
      await _refreshTiles();
      if (mounted) setState(() {});
    } catch (error, stack) {
      debugPrint('Project Ink layer duplication rejected: $error\n$stack');
      if (mounted) await _loadPhase2Projections();
    }
  }

  void _applyLayerChange(LayerView changed) {
    if (!mounted) return;
    unawaited(_commitLayerChange(changed));
  }

  void _applyLayerPresentation(LayerView changed) {
    if (!mounted) return;
    unawaited(_commitLayerPresentation(changed));
  }

  void _applyLayerAdjustment(LayerView changed) {
    if (!mounted) return;
    unawaited(_commitLayerAdjustment(changed));
  }

  Future<void> _commitLayerAdjustment(LayerView changed) async {
    try {
      await widget.engine.setLayerBrightnessContrast(
        layerId: changed.id,
        brightness: changed.adjustmentBrightness,
        contrast: changed.adjustmentContrast,
      );
      await _refreshTiles();
    } catch (error, stack) {
      debugPrint('Project Ink adjustment update rejected: $error\\n$stack');
    } finally {
      if (mounted) await _loadPhase2Projections();
    }
  }

  Future<void> _commitLayerChange(LayerView changed) async {
    try {
      await widget.engine.updateLayerProperties(
        layerId: changed.id,
        visible: changed.visible,
        opacity: changed.opacity,
        alphaLock: changed.alphaLock,
        clipping: changed.clipping,
        reference: changed.reference,
      );
    } catch (error, stack) {
      debugPrint('Project Ink layer update rejected: $error\n$stack');
    } finally {
      if (mounted) await _loadPhase2Projections();
    }
  }

  Future<void> _selectLayerContents(LayerView layer) async {
    try {
      await widget.engine.selectLayerOpacity(
        layerId: layer.id,
        minimumAlpha: 1,
      );
      if (mounted) {
        setState(() {
          _selectionGeometry = null;
          _selectionGeometryTool = IllustrationTool.layerOpacitySelect;
        });
      }
    } catch (error, stack) {
      debugPrint(
        'Project Ink layer contents selection rejected: $error\n$stack',
      );
    }
  }

  Future<void> _mergeLayers(LayerView source, LayerView target) async {
    if (source.kind != LayerKind.raster || target.kind != LayerKind.raster) {
      debugPrint('Project Ink layer merge requires two raster layers');
      return;
    }
    try {
      await widget.engine.mergeLayers(
        targetLayerId: target.id,
        sourceLayerId: source.id,
      );
      await _loadPhase2Projections();
      _layerSelection.select(target.id);
      await _refreshTiles();
      if (mounted) setState(() {});
    } catch (error, stack) {
      debugPrint('Project Ink layer merge rejected: $error\n$stack');
    }
  }

  Future<void> _commitLayerPresentation(LayerView changed) async {
    final blendMode = switch (changed.blendMode) {
      LayerBlendMode.normal => 'Normal',
      LayerBlendMode.multiply => 'Multiply',
      LayerBlendMode.screen => 'Screen',
      LayerBlendMode.overlay => 'Overlay',
      LayerBlendMode.darken => 'Darken',
      LayerBlendMode.lighten => 'Lighten',
      LayerBlendMode.add => 'Add',
      LayerBlendMode.subtract => 'Subtract',
      LayerBlendMode.colorBurn => 'Color Burn',
      LayerBlendMode.linearBurn => 'Linear Burn',
      LayerBlendMode.colorDodge => 'Color Dodge',
      LayerBlendMode.softLight => 'Soft Light',
      LayerBlendMode.hardLight => 'Hard Light',
      LayerBlendMode.difference => 'Difference',
      LayerBlendMode.exclusion => 'Exclusion',
      LayerBlendMode.divide => 'Divide',
    };
    final groupMode = switch (changed.groupMode) {
      LayerGroupMode.isolated => 'Isolated',
      LayerGroupMode.passThrough => 'Pass-through',
    };
    try {
      await widget.engine.updateLayerPresentation(
        layerId: changed.id,
        name: changed.name,
        blendMode: blendMode,
        groupMode: groupMode,
        labelRgba: changed.label,
      );
    } catch (error, stack) {
      debugPrint('Project Ink layer presentation rejected: $error\n$stack');
    } finally {
      if (mounted) await _loadPhase2Projections();
    }
  }

  void _fitCanvas() {
    final renderObject = _canvasKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return;
    final fitted = CanvasViewport.fitDocument(
      viewportSize: renderObject.size,
      documentSize: Size(
        widget.engine.documentInfo.widthPx.toDouble(),
        widget.engine.documentInfo.heightPx.toDouble(),
      ),
    );
    setState(() {
      _pan = fitted.pan;
      _scale = fitted.scale;
      _rotation = fitted.rotation;
    });
  }

  void _closeTransientPanels() {
    if (!mounted) return;
    setState(() {
      _showBrushes = false;
      _showLayers = false;
      _showTools = false;
      _showComics = false;
      _quickMenuVisible = false;
    });
  }

  bool _wideDesktop(BuildContext context) {
    if (!widget.desktopDockEnabled) return false;
    if (resolveWorkspaceMode(
          context,
          override: widget.workspaceModeOverride,
          desktopDockEnabled: widget.desktopDockEnabled,
          targetPlatform: widget.targetPlatform,
        ) !=
        WorkspaceMode.desktop) {
      return false;
    }
    final platform = widget.targetPlatform ?? defaultTargetPlatform;
    final width = MediaQuery.sizeOf(context).width;
    // Retina macOS windows report logical points. Two full dock columns at
    // 800 points leave too little room for the canvas, so compact windows use
    // the canvas-first shell and open palettes as overlays instead.
    if (platform == TargetPlatform.macOS) {
      return width >= 1024 && View.of(context).physicalSize.width >= 1200;
    }
    return (platform == TargetPlatform.windows ||
            platform == TargetPlatform.linux) &&
        width >= 1100;
  }

  void _dispatchAction(EditorActionId action) {
    if (!mounted) return;
    switch (action) {
      case EditorActionId.newDocument:
        unawaited(_newDocument());
      case EditorActionId.openProject:
        unawaited(_openProject());
      case EditorActionId.importPsd:
        unawaited(_importPsd());
      case EditorActionId.saveProject:
        unawaited(_saveProject());
      case EditorActionId.saveProjectAs:
        unawaited(_saveProjectAs());
      case EditorActionId.exportPng:
        unawaited(_exportPng());
      case EditorActionId.undo:
        unawaited(_undo());
      case EditorActionId.redo:
        unawaited(_redo());
      case EditorActionId.clearSelection:
        unawaited(_clearSelection());
      case EditorActionId.invertSelection:
        unawaited(_modifySelection(SelectionEdit.invert));
      case EditorActionId.growSelection:
        unawaited(_modifySelection(SelectionEdit.grow));
      case EditorActionId.shrinkSelection:
        unawaited(_modifySelection(SelectionEdit.shrink));
      case EditorActionId.toggleEraser:
        setState(() => _eraserActive = !_eraserActive);
      case EditorActionId.fitCanvas:
        _fitCanvas();
      case EditorActionId.toggleInterface:
        setState(() => _interfaceHidden = !_interfaceHidden);
      case EditorActionId.showTools:
        _selectPanel('tools', context);
      case EditorActionId.showBrushes:
        _selectPanel('brushes', context);
      case EditorActionId.showLayers:
        _selectPanel('layers', context);
      case EditorActionId.showComics:
        _selectPanel('comics', context);
      case EditorActionId.showColorPicker:
        unawaited(_showBrushColorSettings());
      case EditorActionId.showToolProperties:
        _selectPanel('properties', context);
      case EditorActionId.showMaterials:
        _selectPanel('materials', context);
      case EditorActionId.eyedropper:
        setState(() => _colorSamplerArmed = true);
      case EditorActionId.quickMenu:
        setState(() => _quickMenuVisible = !_quickMenuVisible);
      case EditorActionId.commandSearch:
        unawaited(_showCommandSearch());
      case EditorActionId.mirrorCanvas:
        setState(() => _mirrorCanvas = !_mirrorCanvas);
      case EditorActionId.resetRotation:
        setState(() => _rotation = 0);
      case EditorActionId.actualPixels:
        setState(() => _scale = 1);
      case EditorActionId.swapColors:
        unawaited(_swapColors());
      case EditorActionId.resetColors:
        unawaited(_resetColors());
      case EditorActionId.showHistory:
        _selectPanel('history', context);
      case EditorActionId.showQuickAccess:
        _selectPanel('quickAccess', context);
    }
  }

  List<PlatformMenuItem> _macOSApplicationMenus({
    required bool documentActionsEnabled,
  }) => [
    for (final category in const [
      'File',
      'Edit',
      'View',
      'Layer',
      'Select',
      'Tool',
      'Window',
      'Help',
    ])
      PlatformMenu(
        label: category,
        menus: [
          for (final action in EditorActionId.values.where(
            (action) =>
                action.category == category ||
                (category == 'Tool' && action.category == 'Color'),
          ))
            PlatformMenuItem(
              label: action.label,
              shortcut: _macOSShortcutFor(action),
              onSelected:
                  _isDocumentActionDisabled(action, documentActionsEnabled)
                      ? null
                      : () => _commands.dispatch(action),
            ),
        ],
      ),
  ];

  bool _isDocumentActionDisabled(
    EditorActionId action,
    bool documentActionsEnabled,
  ) =>
      (_documentActionRunning && action == EditorActionId.newDocument) ||
      (!documentActionsEnabled &&
          const {
            EditorActionId.openProject,
            EditorActionId.importPsd,
            EditorActionId.saveProject,
            EditorActionId.saveProjectAs,
            EditorActionId.exportPng,
          }.contains(action));

  SingleActivator? _macOSShortcutFor(EditorActionId action) => switch (action) {
    EditorActionId.newDocument => const SingleActivator(
      LogicalKeyboardKey.keyN,
      meta: true,
    ),
    EditorActionId.openProject => const SingleActivator(
      LogicalKeyboardKey.keyO,
      meta: true,
    ),
    EditorActionId.saveProject => const SingleActivator(
      LogicalKeyboardKey.keyS,
      meta: true,
    ),
    EditorActionId.saveProjectAs => const SingleActivator(
      LogicalKeyboardKey.keyS,
      meta: true,
      shift: true,
    ),
    EditorActionId.undo => const SingleActivator(
      LogicalKeyboardKey.keyZ,
      meta: true,
    ),
    EditorActionId.redo => const SingleActivator(
      LogicalKeyboardKey.keyZ,
      meta: true,
      shift: true,
    ),
    EditorActionId.showBrushes => const SingleActivator(
      LogicalKeyboardKey.keyB,
    ),
    EditorActionId.showColorPicker => const SingleActivator(
      LogicalKeyboardKey.keyC,
    ),
    EditorActionId.eyedropper => const SingleActivator(LogicalKeyboardKey.keyI),
    EditorActionId.toggleEraser => const SingleActivator(
      LogicalKeyboardKey.keyE,
    ),
    EditorActionId.commandSearch => const SingleActivator(
      LogicalKeyboardKey.keyK,
      meta: true,
    ),
    EditorActionId.swapColors => const SingleActivator(LogicalKeyboardKey.keyX),
    EditorActionId.resetColors => const SingleActivator(
      LogicalKeyboardKey.keyD,
    ),
    _ => null,
  };

  Future<void> _swapColors() async {
    final previous = _activeColor;
    setState(() {
      _activeColor = _subColor;
      _subColor = previous;
    });
    await _applyActiveBrushColor();
  }

  Future<void> _resetColors() async {
    setState(() {
      _activeColor = Colors.black;
      _subColor = Colors.white;
    });
    await _applyActiveBrushColor();
  }

  Future<void> _applyActiveBrushColor() async {
    final color = _activeColor;
    try {
      await widget.engine.updateBrushColor(
        brushId: _activeBrushId,
        red: (color.r * 255).round().clamp(0, 255),
        green: (color.g * 255).round().clamp(0, 255),
        blue: (color.b * 255).round().clamp(0, 255),
        alpha: (color.a * 255).round().clamp(0, 255),
      );
      widget.autosave?.markDirty();
    } catch (error, stack) {
      debugPrint('Project Ink color update failed: $error\n$stack');
    }
  }

  Future<void> _showCommandSearch() async {
    final selected = await showDialog<EditorActionId>(
      context: context,
      builder: (_) => const _CommandSearchDialog(),
    );
    if (selected != null && mounted) _commands.dispatch(selected);
  }

  void _selectPanel(String panel, BuildContext context) {
    final preferences =
        widget.workspacePreferences ?? const WorkspacePreferences();
    final platform = widget.targetPlatform ?? defaultTargetPlatform;
    final tabletStudio =
        (platform == TargetPlatform.iOS ||
            platform == TargetPlatform.android) &&
        MediaQuery.sizeOf(context).width >= 600 &&
        preferences.tabletMode == TabletWorkspaceMode.studio;
    if (tabletStudio && (panel == 'history' || panel == 'quickAccess')) {
      setState(() {
        _showTools = false;
        _showBrushes = false;
        _showLayers = false;
        _showComics = false;
      });
    }
    final layout = _workspaceLayoutFor(
      preferences.workspaceId,
      preferences.customWorkspaces,
    );
    if (_wideDesktop(context)) {
      const leftPalettes = {'tools', 'brushes', 'color', 'quickAccess'};
      final palette = _paletteForDockTab(panel);
      var selectedLeftDock = false;
      var selectedRightDock = false;
      final leftGroupIndex = _leftDockGroups.indexWhere(
        (group) => group.tabs.contains(palette),
      );
      final rightGroupIndex = _rightDockGroups.indexWhere(
        (group) => group.tabs.contains(palette),
      );
      setState(() {
        if (leftGroupIndex >= 0 ||
            (leftPalettes.contains(panel) && layout.left != null)) {
          selectedLeftDock = true;
          _selectDockPaletteState(
            left: true,
            groupIndex: leftGroupIndex,
            tab: panel,
          );
          _workspaceLeftDockCollapsed = false;
          _temporaryDesktopPalette = null;
        } else if (rightGroupIndex >= 0 || layout.right != null) {
          selectedRightDock = true;
          _selectDockPaletteState(
            left: false,
            groupIndex: rightGroupIndex,
            tab: panel,
          );
          _workspaceDockCollapsed = false;
          _temporaryDesktopPalette = null;
        } else {
          _temporaryDesktopPalette = panel;
        }
      });
      if (selectedLeftDock) _persistDockGroups(left: true);
      if (selectedRightDock) _persistDockGroups(left: false);
      _persistWorkspacePreferences(lastDock: panel);
      return;
    }
    if (panel == 'quickAccess') {
      unawaited(
        showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder:
              (sheetContext) => SafeArea(
                child: SizedBox(
                  height: MediaQuery.sizeOf(sheetContext).height * 0.68,
                  child: _QuickAccessPanel(
                    sets:
                        widget.workspacePreferences?.quickAccessSets ??
                        defaultQuickAccessSets,
                    activeSetId:
                        widget.workspacePreferences?.activeQuickAccessSetId ??
                        'default',
                    onAction: (action) {
                      Navigator.of(sheetContext).pop();
                      _commands.dispatch(action);
                    },
                    onChanged:
                        (sets, activeSetId) => _persistWorkspacePreferences(
                          quickAccessSets: sets,
                          activeQuickAccessSetId: activeSetId,
                        ),
                  ),
                ),
              ),
        ),
      );
      return;
    }
    if (panel == 'history') {
      unawaited(
        showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder:
              (sheetContext) => SizedBox(
                height: MediaQuery.sizeOf(sheetContext).height * 0.72,
                child: _HistoryPanel(
                  engine: widget.engine,
                  revisionToken: math.max(
                    _renderRevision,
                    widget.engine.revision,
                  ),
                  onNavigate: _navigateHistory,
                ),
              ),
        ),
      );
      return;
    }
    setState(() {
      if (tabletStudio) {
        final closing = switch (panel) {
          'tools' => _showTools,
          'brushes' => _showBrushes,
          'layers' => _showLayers,
          'comics' => _showComics,
          _ => false,
        };
        _showTools = !closing && panel == 'tools';
        _showBrushes = !closing && panel == 'brushes';
        _showLayers = !closing && panel == 'layers';
        _showComics = !closing && panel == 'comics';
      } else {
        _showTools = panel == 'tools' ? !_showTools : _showTools;
        _showBrushes = panel == 'brushes' ? !_showBrushes : _showBrushes;
        _showLayers = panel == 'layers' ? !_showLayers : _showLayers;
        _showComics = panel == 'comics' ? !_showComics : _showComics;
      }
    });
    _persistWorkspacePreferences(lastDock: panel);
  }

  void _selectDockPaletteState({
    required bool left,
    required int groupIndex,
    required String tab,
  }) {
    final palette = _paletteForDockTab(tab);
    var groups = left ? _leftDockGroups : _rightDockGroups;
    if (groups.isEmpty) {
      groups = [
        DockGroupLayout(tabs: [palette], activeTab: palette),
      ];
    } else {
      final index = groupIndex < 0 ? 0 : groupIndex.clamp(0, groups.length - 1);
      final current = groups[index];
      final tabs = [...current.tabs];
      if (!tabs.contains(palette) && tabs.length < 8) tabs.add(palette);
      groups = [...groups];
      groups[index] = DockGroupLayout(
        flex: current.flex,
        tabs: tabs,
        activeTab: palette,
      );
    }
    if (left) {
      _leftDockGroups = groups;
      _leftDockTab = tab;
    } else {
      _rightDockGroups = groups;
      _desktopDockTab = tab;
    }
  }

  void _reorderDockPalette({
    required bool left,
    required int groupIndex,
    required int fromIndex,
    required int toIndex,
  }) {
    final groups = [...(left ? _leftDockGroups : _rightDockGroups)];
    if (groupIndex < 0 || groupIndex >= groups.length) return;
    final current = groups[groupIndex];
    if (fromIndex < 0 || fromIndex >= current.tabs.length) return;
    final tabs = [...current.tabs];
    final palette = tabs.removeAt(fromIndex);
    final insertAt = toIndex.clamp(0, tabs.length);
    tabs.insert(insertAt, palette);
    groups[groupIndex] = DockGroupLayout(
      flex: current.flex,
      tabs: tabs,
      activeTab: current.activeTab,
    );
    setState(() {
      if (left) {
        _leftDockGroups = groups;
      } else {
        _rightDockGroups = groups;
      }
    });
    _persistDockGroups(left: left);
  }

  void _moveDockPalette({
    required _DockPaletteDragData source,
    required bool targetLeft,
    required int targetGroupIndex,
    required int targetTabIndex,
  }) {
    if (source.isLeft == targetLeft && source.groupIndex == targetGroupIndex) {
      _reorderDockPalette(
        left: targetLeft,
        groupIndex: targetGroupIndex,
        fromIndex: source.tabIndex,
        toIndex: targetTabIndex,
      );
      return;
    }

    final leftGroups = [..._leftDockGroups];
    final rightGroups = [..._rightDockGroups];
    final sourceGroups = source.isLeft ? leftGroups : rightGroups;
    final targetGroups = targetLeft ? leftGroups : rightGroups;
    if (source.groupIndex < 0 || source.groupIndex >= sourceGroups.length) {
      return;
    }
    if (targetGroupIndex < 0 || targetGroupIndex >= targetGroups.length) return;
    final sourceGroup = sourceGroups[source.groupIndex];
    if (source.tabIndex < 0 ||
        source.tabIndex >= sourceGroup.tabs.length ||
        sourceGroup.tabs[source.tabIndex] != source.palette) {
      return;
    }
    final targetGroup = targetGroups[targetGroupIndex];
    if (targetGroup.tabs.contains(source.palette)) return;

    final sourceTabs = [...sourceGroup.tabs]..removeAt(source.tabIndex);
    if (sourceTabs.isEmpty) {
      final fallback =
          source.isLeft
              ? (source.palette == InkPaletteId.toolGroups
                  ? InkPaletteId.brushPresets
                  : InkPaletteId.toolGroups)
              : (source.palette == InkPaletteId.layers
                  ? InkPaletteId.toolProperties
                  : InkPaletteId.layers);
      sourceGroups[source.groupIndex] = DockGroupLayout(
        flex: sourceGroup.flex,
        tabs: [fallback],
        activeTab: fallback,
      );
    } else {
      sourceGroups[source.groupIndex] = DockGroupLayout(
        flex: sourceGroup.flex,
        tabs: sourceTabs,
        activeTab:
            sourceGroup.activeTab == source.palette
                ? sourceTabs.first
                : sourceGroup.activeTab,
      );
    }
    final adjustedTargetIndex = targetGroups.indexOf(targetGroup);
    if (adjustedTargetIndex < 0 || adjustedTargetIndex >= targetGroups.length) {
      return;
    }
    final destination = targetGroups[adjustedTargetIndex];
    if (destination.tabs.length >= 8) return;
    final destinationTabs = [...destination.tabs];
    destinationTabs.insert(
      targetTabIndex.clamp(0, destinationTabs.length),
      source.palette,
    );
    targetGroups[adjustedTargetIndex] = DockGroupLayout(
      flex: destination.flex,
      tabs: destinationTabs,
      activeTab: source.palette,
    );
    setState(() {
      _leftDockGroups = leftGroups;
      _rightDockGroups = rightGroups;
      if (source.isLeft) {
        _leftDockTab =
            _paletteName(leftGroups.firstOrNull?.activeTab) ?? 'tools';
      } else {
        _desktopDockTab =
            _paletteName(rightGroups.firstOrNull?.activeTab) ?? 'layers';
      }
      if (targetLeft) {
        _leftDockTab = _paletteIdToName(source.palette);
      } else {
        _desktopDockTab = _paletteIdToName(source.palette);
      }
      _temporaryDesktopPalette = null;
    });
    _persistDockGroups(
      left: source.isLeft || targetLeft,
      right: !source.isLeft || !targetLeft,
      lastDock: _paletteIdToName(source.palette),
    );
  }

  void _persistDockGroups({
    required bool left,
    bool right = false,
    String? lastDock,
  }) {
    final preferences =
        widget.workspacePreferences ?? const WorkspacePreferences();
    final index = preferences.customWorkspaces.indexWhere(
      (layout) => layout.id == preferences.workspaceId,
    );
    final updatesLeft = left;
    final updatesRight = right || !left;
    final current = _workspaceLayoutFor(
      preferences.workspaceId,
      preferences.customWorkspaces,
    );
    DockColumnLayout? update(DockColumnLayout? column, {required bool left}) =>
        column == null
            ? null
            : DockColumnLayout(
              width: left ? _workspaceLeftDockWidth : _workspaceDockWidth,
              collapsed:
                  left ? _workspaceLeftDockCollapsed : _workspaceDockCollapsed,
              groups: left ? _leftDockGroups : _rightDockGroups,
            );
    final updatedLayout = WorkspaceLayout(
      id: current.id,
      name: current.name,
      kind: current.kind,
      left: updatesLeft ? update(current.left, left: true) : current.left,
      right: updatesRight ? update(current.right, left: false) : current.right,
      commandBar: current.commandBar,
    );
    if (index < 0) {
      if (!const {
        'illustration',
        'comic',
        'minimal',
      }.contains(preferences.workspaceId)) {
        return;
      }
      final overrides = Map<String, WorkspaceLayout>.from(
        preferences.workspaceOverrides,
      )..[preferences.workspaceId] = updatedLayout;
      _persistWorkspacePreferences(
        workspaceOverrides: overrides,
        lastDock: lastDock,
      );
      return;
    }
    final updatedWorkspaces = [...preferences.customWorkspaces];
    updatedWorkspaces[index] = updatedLayout;
    _persistWorkspacePreferences(
      customWorkspaces: updatedWorkspaces,
      lastDock: lastDock,
    );
  }

  void _resizeDockGroup({
    required bool left,
    required int dividerIndex,
    required double delta,
    required double availableHeight,
  }) {
    final groups = left ? _leftDockGroups : _rightDockGroups;
    if (dividerIndex < 0 || dividerIndex + 1 >= groups.length) return;
    final displayed = groups
        .map(
          (group) => (group.flex /
                  groups.fold<double>(0, (sum, item) => sum + item.flex))
              .clamp(0.15, 0.70),
        )
        .toList(growable: false);
    final displayedTotal = displayed.fold<double>(
      0,
      (sum, value) => sum + value,
    );
    final firstShare = displayed[dividerIndex] / displayedTotal;
    final secondShare = displayed[dividerIndex + 1] / displayedTotal;
    final pairShare = firstShare + secondShare;
    const minShare = 0.15;
    final maxFirstShare = math.min(0.70, pairShare - minShare);
    if (maxFirstShare < minShare || availableHeight <= 0) return;
    final nextFirstShare = (firstShare + delta / availableHeight).clamp(
      minShare,
      maxFirstShare,
    );
    final nextSecondShare = pairShare - nextFirstShare;
    final updated = [...groups];
    final first = groups[dividerIndex];
    final second = groups[dividerIndex + 1];
    updated[dividerIndex] = DockGroupLayout(
      flex: nextFirstShare,
      tabs: first.tabs,
      activeTab: first.activeTab,
    );
    updated[dividerIndex + 1] = DockGroupLayout(
      flex: nextSecondShare,
      tabs: second.tabs,
      activeTab: second.activeTab,
    );
    setState(() {
      if (left) {
        _leftDockGroups = updated;
      } else {
        _rightDockGroups = updated;
      }
    });
  }

  Widget _buildDockPalette(String tab, BuildContext context) => switch (tab) {
    'tools' => IllustrationToolPalette(
      selected: _activeTool,
      onSelected: _selectTool,
      onClearSelection: _clearSelection,
      onTransformPreset: _applyTransformPreset,
    ),
    'brushes' => BrushLibraryPanel(
      library: _brushLibrary,
      onSelected: (preset) => setState(() => _activeBrushId = preset.id),
      onChanged: _updateBrushDraft,
      onSizeChangeEnd: _persistBrushSize,
      onImport: widget.documentPicker is BrushPicker ? _importBrush : null,
      onExport: widget.documentPicker is BrushPicker ? _exportBrush : null,
      onDuplicate: _duplicateBrush,
      onRename: _renameBrush,
      hasUncommittedChanges: _activeBrushDrafts.containsKey(
        _brushLibrary.selected?.id,
      ),
      onCommitEdit: _commitSelectedBrushDraft,
      onCancelEdit: _cancelBrushDraft,
    ),
    'properties' => InkToolPropertiesPanel(
      library: _brushLibrary,
      activeTool: _activeTool.name,
      eraserActive: _eraserActive,
      activeLayerName: _activeLayerName,
      onBrushChanged: _updateBrushDraft,
      onToggleEraser: () => setState(() => _eraserActive = !_eraserActive),
      onBrushColor: _showBrushColorSettings,
      onOpenLayers: () => _selectPanel('layers', context),
    ),
    'color' => _ColorPalettePanel(
      mainColor: _activeColor,
      subColor: _subColor,
      recentColors:
          widget.workspacePreferences?.recentColors ?? const <String>[],
      eraserActive: _eraserActive,
      onChoose: _showBrushColorSettings,
      onSelectRecent: _applyMainColor,
      onSwap: () => _commands.dispatch(EditorActionId.swapColors),
      onReset: () => _commands.dispatch(EditorActionId.resetColors),
      onTransparent: () => _commands.dispatch(EditorActionId.toggleEraser),
    ),
    'materials' => InkMaterialsPanel(
      controller: _comicWorkspace,
      onOpenComics: () => _selectPanel('comics', context),
    ),
    'comics' => ComicWorkspace(
      controller: _comicWorkspace,
      onDrawInsidePanel: _drawInsideComicPanel,
      onClose: () => _selectPanel('layers', context),
      onBatchExport:
          widget.documentPicker is ComicExportPicker ? _exportComicPages : null,
    ),
    'quickAccess' => _QuickAccessPanel(
      sets:
          widget.workspacePreferences?.quickAccessSets ??
          defaultQuickAccessSets,
      activeSetId:
          widget.workspacePreferences?.activeQuickAccessSetId ?? 'default',
      onAction: _commands.dispatch,
      onChanged:
          (sets, activeSetId) => _persistWorkspacePreferences(
            quickAccessSets: sets,
            activeQuickAccessSetId: activeSetId,
          ),
    ),
    'history' => _HistoryPanel(
      engine: widget.engine,
      revisionToken: math.max(_renderRevision, widget.engine.revision),
      onNavigate: _navigateHistory,
    ),
    _ => _layerPanelContent(),
  };

  Widget _layerPanelContent() => Column(
    children: [
      Align(
        alignment: Alignment.centerRight,
        child: PopupMenuButton<LayerKind>(
          tooltip: 'Add layer',
          icon: const Icon(Icons.add_circle_outline),
          onSelected: (kind) => unawaited(_addLayer(kind)),
          itemBuilder:
              (context) => const [
                PopupMenuItem(
                  value: LayerKind.raster,
                  child: Text('Raster layer'),
                ),
                PopupMenuItem(
                  value: LayerKind.vectorInk,
                  child: Text('Vector layer'),
                ),
                PopupMenuItem(value: LayerKind.group, child: Text('Group')),
                PopupMenuItem(value: LayerKind.mask, child: Text('Mask')),
                PopupMenuItem(value: LayerKind.tone, child: Text('Tone layer')),
                PopupMenuItem(
                  value: LayerKind.panelGroup,
                  child: Text('Panel group'),
                ),
                PopupMenuItem(
                  value: LayerKind.adjustment,
                  child: Text('Adjustment layer'),
                ),
              ],
        ),
      ),
      Expanded(
        child: LayerPanel(
          layers: _layers,
          selection: _layerSelection,
          onLayerChanged: _applyLayerChange,
          onMoveLayer: (layer, delta) => unawaited(_moveLayerBy(layer, delta)),
          onDeleteLayer: (layer) => unawaited(_deleteLayer(layer)),
          onDuplicateLayer: (layer) => unawaited(_duplicateLayer(layer)),
          onPresentationChanged: _applyLayerPresentation,
          onAdjustmentChanged: _applyLayerAdjustment,
          onSelectContents: (layer) => unawaited(_selectLayerContents(layer)),
          onMergeLayers:
              (source, target) => unawaited(_mergeLayers(source, target)),
          onSelectionChanged: (_) {
            unawaited(_loadVectorStrokesForSelection());
            if (mounted) setState(() {});
          },
          // Keep the add action pinned above the scrolling layer list.
          onAddLayer: null,
        ),
      ),
      if (_selectedVectorLayerId != null)
        VectorInspector(
          strokes: _vectorStrokes,
          onSimplify: _simplifySelectedVector,
          onConnect: _connectFirstTwoVectors,
          onEditPoint: _editFirstVectorPoint,
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    _scheduleLiveViewportSync();
    final wideDesktop = _wideDesktop(context);
    final desktopDock = wideDesktop && !_interfaceHidden;
    final preferences =
        widget.workspacePreferences ?? const WorkspacePreferences();
    final layout = _workspaceLayoutFor(
      preferences.workspaceId,
      preferences.customWorkspaces,
    );
    final showLeftDock =
        desktopDock && !_workspaceLeftDockCollapsed && layout.left != null;
    final showRightDock =
        desktopDock && !_workspaceDockCollapsed && layout.right != null;
    final effectiveDocks = effectiveDockWidths(
      viewportWidth: MediaQuery.sizeOf(context).width,
      showLeftDock: showLeftDock,
      showRightDock: showRightDock,
      preferredLeftWidth: _workspaceLeftDockWidth,
      preferredRightWidth: _workspaceDockWidth,
    );
    final dockWidth = effectiveDocks.right;
    final leftDockWidth = effectiveDocks.left;
    final showComicCanvasPreview =
        _comicWorkspace.pagePreviewBytes != null &&
        ((_comicClipPanelId != null) ||
            (showRightDock && _desktopDockTab == 'comics') ||
            (!desktopDock && _showComics));
    final platform = widget.targetPlatform ?? defaultTargetPlatform;
    final tabletStudioMode =
        (platform == TargetPlatform.iOS ||
            platform == TargetPlatform.android) &&
        MediaQuery.sizeOf(context).width >= 600 &&
        preferences.tabletMode == TabletWorkspaceMode.studio;
    final tabletSimpleMode =
        (platform == TargetPlatform.iOS ||
            platform == TargetPlatform.android) &&
        (MediaQuery.sizeOf(context).width < 600 ||
            preferences.tabletMode == TabletWorkspaceMode.simple);
    final useNativeMacMenus =
        platform == TargetPlatform.macOS && widget.desktopDockEnabled;
    final documentActionsEnabled =
        widget.documentPicker != null && !_documentActionRunning;
    final editorShell = Scaffold(
      body: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.keyN, control: true):
              () => _commands.dispatch(EditorActionId.newDocument),
          const SingleActivator(LogicalKeyboardKey.keyN, meta: true):
              () => _commands.dispatch(EditorActionId.newDocument),
          const SingleActivator(LogicalKeyboardKey.keyO, control: true):
              () => _commands.dispatch(EditorActionId.openProject),
          const SingleActivator(LogicalKeyboardKey.keyO, meta: true):
              () => _commands.dispatch(EditorActionId.openProject),
          const SingleActivator(LogicalKeyboardKey.keyS, control: true):
              () => _commands.dispatch(EditorActionId.saveProject),
          const SingleActivator(LogicalKeyboardKey.keyS, meta: true):
              () => _commands.dispatch(EditorActionId.saveProject),
          const SingleActivator(
                LogicalKeyboardKey.keyS,
                control: true,
                shift: true,
              ):
              () => _commands.dispatch(EditorActionId.saveProjectAs),
          const SingleActivator(
                LogicalKeyboardKey.keyS,
                meta: true,
                shift: true,
              ):
              () => _commands.dispatch(EditorActionId.saveProjectAs),
          const SingleActivator(LogicalKeyboardKey.keyZ, control: true):
              () => _commands.dispatch(EditorActionId.undo),
          const SingleActivator(LogicalKeyboardKey.keyZ, meta: true):
              () => _commands.dispatch(EditorActionId.undo),
          const SingleActivator(
                LogicalKeyboardKey.keyZ,
                control: true,
                shift: true,
              ):
              () => _commands.dispatch(EditorActionId.redo),
          const SingleActivator(
                LogicalKeyboardKey.keyZ,
                meta: true,
                shift: true,
              ):
              () => _commands.dispatch(EditorActionId.redo),
          const SingleActivator(LogicalKeyboardKey.keyY, control: true):
              () => _commands.dispatch(EditorActionId.redo),
          const SingleActivator(LogicalKeyboardKey.keyY, meta: true):
              () => _commands.dispatch(EditorActionId.redo),
          const SingleActivator(LogicalKeyboardKey.keyB):
              () => _commands.dispatch(EditorActionId.showBrushes),
          const SingleActivator(LogicalKeyboardKey.keyC):
              () => _commands.dispatch(EditorActionId.showColorPicker),
          const SingleActivator(LogicalKeyboardKey.keyI):
              () => _commands.dispatch(EditorActionId.eyedropper),
          const SingleActivator(LogicalKeyboardKey.keyI, alt: true):
              () => _commands.dispatch(EditorActionId.eyedropper),
          const SingleActivator(LogicalKeyboardKey.keyE):
              () => _commands.dispatch(EditorActionId.toggleEraser),
          const SingleActivator(LogicalKeyboardKey.keyK, control: true):
              () => _commands.dispatch(EditorActionId.commandSearch),
          const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
              () => _commands.dispatch(EditorActionId.commandSearch),
          const SingleActivator(LogicalKeyboardKey.enter, control: true):
              () => _commands.dispatch(EditorActionId.commandSearch),
          const SingleActivator(LogicalKeyboardKey.keyX):
              () => _commands.dispatch(EditorActionId.swapColors),
          const SingleActivator(LogicalKeyboardKey.keyD):
              () => _commands.dispatch(EditorActionId.resetColors),
          const SingleActivator(LogicalKeyboardKey.escape):
              _closeTransientPanels,
        },
        child: Focus(
          autofocus: true,
          onFocusChange: _handleEditorFocusChanged,
          child: Stack(
            children: [
              Positioned(
                left: desktopDock ? 44 + leftDockWidth : 0,
                top: desktopDock ? 36 : 0,
                right: desktopDock ? dockWidth : 0,
                bottom: desktopDock ? 24 : 0,
                child: Semantics(
                  container: true,
                  label: 'Drawing canvas',
                  hint:
                      'Draw with your finger or stylus. Use two fingers to pan and zoom.',
                  child: Listener(
                    key: _canvasKey,
                    onPointerDown: _handlePointer,
                    onPointerMove: _handlePointer,
                    onPointerUp: _handlePointer,
                    onPointerCancel: _handlePointer,
                    // Canvas painters may rotate/scale the document beyond
                    // their layout bounds. Clip that transformed artwork to
                    // the canvas viewport so it can never overpaint the
                    // toolbar or workspace dock.
                    child: ClipRect(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        // Trackpad pinch events still arrive through the scale
                        // recognizer, while ordinary two-finger scrolling stays
                        // pan-only instead of unexpectedly changing zoom.
                        trackpadScrollCausesScale: false,
                        onScaleStart: (details) {
                          _scaleGestureStartScale = _scale;
                          _scaleGestureStartRotation = _rotation;
                          _scaleGestureStartPan = _pan;
                          _scaleGestureStartFocalPoint =
                              details.localFocalPoint;
                        },
                        onScaleUpdate: (details) {
                          if (details.pointerCount < 2 &&
                              !_singleFingerNavigation) {
                            return;
                          }
                          final renderObject =
                              _canvasKey.currentContext?.findRenderObject();
                          final size =
                              renderObject is RenderBox
                                  ? renderObject.size
                                  : Size.zero;
                          final next = CanvasViewport(
                            pan: _scaleGestureStartPan,
                            scale: _scaleGestureStartScale,
                            rotation: _scaleGestureStartRotation,
                          ).applyGesture(
                            viewportSize: size,
                            startFocalPoint: _scaleGestureStartFocalPoint,
                            focalPoint: details.localFocalPoint,
                            scaleFactor: details.scale,
                            rotationDelta: details.rotation,
                          );
                          setState(() {
                            _pan = next.pan;
                            _scale = next.scale;
                            _rotation = next.rotation;
                          });
                        },
                        onScaleEnd: (_) {
                          _scaleGestureStartScale = _scale;
                          _scaleGestureStartRotation = _rotation;
                          _scaleGestureStartPan = _pan;
                          _scaleGestureStartFocalPoint = Offset.zero;
                        },
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            CustomPaint(
                              painter: _CanvasPainter(
                                pan: _pan,
                                scale: _scale,
                                rotation: _rotation,
                                mirrored: _mirrorCanvas,
                                revision: _renderRevision,
                                documentWidth:
                                    widget.engine.documentInfo.widthPx,
                                documentHeight:
                                    widget.engine.documentInfo.heightPx,
                                layers: _layers,
                                tiles: _visibleImages.toList(growable: false),
                              ),
                              foregroundPainter: _CanvasOverlayPainter(
                                pan: _pan,
                                scale: _scale,
                                rotation: _rotation,
                                mirrored: _mirrorCanvas,
                                documentWidth:
                                    widget.engine.documentInfo.widthPx,
                                documentHeight:
                                    widget.engine.documentInfo.heightPx,
                                selection: _selectionGeometry,
                                selectionTool: _selectionGeometryTool,
                                previewPoints: _toolPoints,
                                rulerStart: _rulerStart,
                                rulerEnd: _rulerEnd,
                              ),
                            ),
                            ValueListenableBuilder<LiveStrokePreview?>(
                              valueListenable: _strokePreview,
                              builder: (context, preview, child) {
                                // iPad must display the compiled brush output,
                                // never the approximate Flutter path. Until a
                                // native frame is ready, keep the last CPU
                                // document frame visible; CPU tile commits
                                // remain the fallback if the native surface
                                // fails.
                                final isIpad =
                                    (widget.targetPlatform ??
                                        defaultTargetPlatform) ==
                                    TargetPlatform.iOS;
                                final nativeDabRendererExpected =
                                    isIpad &&
                                    _livePreviewSurface
                                        is MacLiveSurfaceController;
                                final showCpuPreview =
                                    !nativeDabRendererExpected &&
                                    _livePreviewSurface?.gpuFrameReady.value !=
                                        true;
                                if (!showCpuPreview || preview == null) {
                                  return const SizedBox.shrink();
                                }
                                return RepaintBoundary(
                                  key: const ValueKey(
                                    'live-stroke-preview-boundary',
                                  ),
                                  child: IgnorePointer(
                                    child: CustomPaint(
                                      painter: LiveStrokePreviewPainter(
                                        pan: _pan,
                                        scale: _scale,
                                        rotation: _rotation,
                                        mirrored: _mirrorCanvas,
                                        documentWidth:
                                            widget.engine.documentInfo.widthPx,
                                        documentHeight:
                                            widget.engine.documentInfo.heightPx,
                                        preview: preview,
                                        onSlowPaint: (
                                          elapsedMicros,
                                          directSegments,
                                          pictures,
                                        ) {
                                          _canvasDiagnostics.record(
                                            'canvas.live_preview_paint_slow',
                                            {
                                              'paintUs': elapsedMicros,
                                              'directSegments': directSegments,
                                              'pictures': pictures,
                                              'pointCount':
                                                  preview.points.length,
                                              'pendingPointCount':
                                                  preview.points.length -
                                                  preview.confirmedThrough,
                                            },
                                          );
                                        },
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                            if (_livePreviewSurface case final liveSurface?)
                              ValueListenableBuilder<int?>(
                                valueListenable: liveSurface.textureId,
                                builder: (context, textureId, child) {
                                  if (textureId == null) {
                                    return const SizedBox.shrink();
                                  }
                                  return ValueListenableBuilder<bool>(
                                    valueListenable: liveSurface.gpuFrameReady,
                                    builder: (context, frameReady, child) {
                                      if (!frameReady) {
                                        return const SizedBox.shrink();
                                      }
                                      return IgnorePointer(
                                        child: Texture(
                                          textureId: textureId,
                                          filterQuality: FilterQuality.none,
                                        ),
                                      );
                                    },
                                  );
                                },
                              ),
                            if (showComicCanvasPreview)
                              IgnorePointer(
                                child: ComicCanvasGuideOverlay(
                                  controller: _comicWorkspace,
                                  pan: _pan,
                                  scale: _scale,
                                  rotation: _rotation,
                                  mirrored: _mirrorCanvas,
                                  documentWidth:
                                      widget.engine.documentInfo.widthPx,
                                  documentHeight:
                                      widget.engine.documentInfo.heightPx,
                                  activePanelId: _comicClipPanelId,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (!_interfaceHidden)
                Positioned(
                  left: 0,
                  top: 0,
                  right: desktopDock ? dockWidth : 0,
                  child: _TopBar(
                    documentName: _documentDisplayName(
                      widget.activeDocumentPath,
                    ),
                    documentActionsEnabled: documentActionsEnabled,
                    documentActionRunning: _documentActionRunning,
                    onOpen: _openProject,
                    onSave: _saveProject,
                    onExport: _exportPng,
                    onExportMenu: _exportDocumentMenu,
                    onExportTimeLapse:
                        widget.documentPicker is DocumentExportPicker
                            ? _exportTimeLapse
                            : null,
                    onGestureSettings: _showGestureSettings,
                    onBrushColor: _showBrushColorSettings,
                    onAccessibilitySettings: _showAccessibilitySettings,
                    onCanvasDiagnostics: _showCanvasDiagnostics,
                    largeControls: _largeControls,
                    leftHanded: _leftHandedToolbar,
                    onTools: () => _selectPanel('tools', context),
                    onBrushes: () => _selectPanel('brushes', context),
                    onLayers: () => _selectPanel('layers', context),
                    onComics: () => _selectPanel('comics', context),
                    onUndo: () => _commands.dispatch(EditorActionId.undo),
                    onRedo: () => _commands.dispatch(EditorActionId.redo),
                    onCommandSearch:
                        () => _commands.dispatch(EditorActionId.commandSearch),
                    onMirror:
                        () => _commands.dispatch(EditorActionId.mirrorCanvas),
                    mirrored: _mirrorCanvas,
                    tabletSimpleMode: tabletSimpleMode,
                    tabletStudioMode: tabletStudioMode,
                    onToggleTabletMode: _toggleTabletWorkspaceMode,
                    workspaceId:
                        widget.workspacePreferences?.workspaceId ??
                        'illustration',
                    onWorkspaceSelected: _selectWorkspace,
                    professionalDesktop: desktopDock,
                    nativeMenuBar: useNativeMacMenus,
                    customWorkspaces:
                        widget.workspacePreferences?.customWorkspaces ??
                        const <WorkspaceLayout>[],
                    onSaveWorkspaceAs: _saveWorkspaceAs,
                    onResetWorkspace: _resetBuiltInWorkspace,
                    followDocumentType:
                        widget.workspacePreferences?.followDocumentType ?? true,
                    onFollowDocumentTypeChanged: _setFollowDocumentType,
                    onRenameWorkspace: _renameWorkspace,
                    onDeleteWorkspace: _deleteWorkspace,
                    onActionDispatch: _commands.dispatch,
                    commandBarItems: _effectiveCommandBarItems(),
                    onCustomizeCommandBar: _customizeCommandBar,
                    contextControls:
                        desktopDock && (showLeftDock || showRightDock)
                            ? _QuickControls(
                              selectedBrush: _brushLibrary.selected,
                              activeLayerName: _activeLayerName,
                              activeColor: _activeColor,
                              eraserActive: _eraserActive,
                              comicClipActive: _comicClipPanelId != null,
                              zoom: _scale,
                              largeControls: false,
                              onBrushChanged: _updateBrushDraft,
                              onBrushSizeChangeEnd: _persistBrushSize,
                              onBrushes: () => _selectPanel('brushes', context),
                              onBrushColor: _showBrushColorSettings,
                              onToggleEraser:
                                  () => setState(
                                    () => _eraserActive = !_eraserActive,
                                  ),
                              onTransparentColor:
                                  () => _commands.dispatch(
                                    EditorActionId.toggleEraser,
                                  ),
                              onFitCanvas: _fitCanvas,
                              onSettings: _showGestureSettings,
                              subColor: _subColor,
                              onSwapColors:
                                  () => _commands.dispatch(
                                    EditorActionId.swapColors,
                                  ),
                              onResetColors:
                                  () => _commands.dispatch(
                                    EditorActionId.resetColors,
                                  ),
                            )
                            : null,
                  ),
                ),
              if (!_interfaceHidden && tabletSimpleMode)
                Positioned(
                  left: _leftHandedToolbar ? null : 8,
                  right: _leftHandedToolbar ? 8 : null,
                  top: 72,
                  width: math.max(
                    72,
                    MediaQuery.textScalerOf(context).scale(64),
                  ),
                  child: _SimpleEdgeControls(
                    selectedBrush: _brushLibrary.selected,
                    onBrushChanged: _updateBrushDraft,
                    onBrushSizeChangeEnd: _persistBrushSize,
                    onUndo: () => _commands.dispatch(EditorActionId.undo),
                    onRedo: () => _commands.dispatch(EditorActionId.redo),
                    onEyedropper:
                        () => _commands.dispatch(EditorActionId.eyedropper),
                  ),
                ),
              if (!_interfaceHidden && tabletStudioMode)
                Positioned(
                  left: 0,
                  top: 52,
                  bottom: 0,
                  width: 48,
                  child: _TabletStudioToolRail(
                    activeTool: _activeTool,
                    eraserActive: _eraserActive,
                    onTools: () => _selectPanel('tools', context),
                    onBrushes: () => _selectPanel('brushes', context),
                    onEraser:
                        () => _commands.dispatch(EditorActionId.toggleEraser),
                    onLayers: () => _selectPanel('layers', context),
                    onComics: () => _selectPanel('comics', context),
                  ),
                ),
              if (!_interfaceHidden && _selectionGeometry != null)
                Positioned(
                  left: desktopDock ? 56 + leftDockWidth : 12,
                  top: desktopDock ? 84 : 64,
                  right: desktopDock ? dockWidth + 12 : 12,
                  child: _SelectionLauncher(
                    onDeselect:
                        () => _commands.dispatch(EditorActionId.clearSelection),
                    onInvert:
                        () =>
                            _commands.dispatch(EditorActionId.invertSelection),
                    onGrow:
                        () => _commands.dispatch(EditorActionId.growSelection),
                    onShrink:
                        () =>
                            _commands.dispatch(EditorActionId.shrinkSelection),
                  ),
                ),
              if (!_interfaceHidden &&
                  desktopDock &&
                  (showLeftDock || showRightDock))
                Positioned(
                  left: 0,
                  top: 36,
                  bottom: 24,
                  width: 44,
                  child: _DesktopToolRail(
                    activeTool: _activeTool,
                    onTools: () => _selectPanel('tools', context),
                    onBrushes: () => _selectPanel('brushes', context),
                    onLayers: () => _selectPanel('layers', context),
                    onEraser:
                        () => _commands.dispatch(EditorActionId.toggleEraser),
                    eraserActive: _eraserActive,
                  ),
                ),
              if (_quickMenuVisible)
                _QuickMenu(
                  eraserActive: _eraserActive,
                  brush: _brushLibrary.selected,
                  color: _activeColor,
                  onToggleEraser:
                      () => setState(() => _eraserActive = !_eraserActive),
                  onFitCanvas: _fitCanvas,
                  onBrushes: () {
                    setState(() => _quickMenuVisible = false);
                    _selectPanel('brushes', context);
                  },
                  onBrushSizeChanged: _updateQuickBrushSizePreview,
                  onBrushSizeChangeEnd: _persistBrushSize,
                  onColor: _showBrushColorSettings,
                  onClose: () => setState(() => _quickMenuVisible = false),
                ),
              if (showRightDock)
                Positioned(
                  left: MediaQuery.sizeOf(context).width - dockWidth - 8,
                  top: 36,
                  bottom: 24,
                  width: 16,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.resizeLeftRight,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragUpdate: (details) {
                        final next =
                            (dockWidth - details.delta.dx)
                                .clamp(220.0, 480.0)
                                .toDouble();
                        if (next == _workspaceDockWidth) return;
                        setState(() => _workspaceDockWidth = next);
                        _persistDockWidth(left: false, width: next);
                      },
                    ),
                  ),
                ),
              if (showLeftDock)
                Positioned(
                  left: 44,
                  top: 36,
                  bottom: 24,
                  width: leftDockWidth + 8,
                  child: Row(
                    children: [
                      SizedBox(
                        width: leftDockWidth,
                        child: _DesktopDock(
                          title: 'Tools & Color',
                          isLeft: true,
                          selectedTab: _leftDockTab,
                          groups: _leftDockGroups,
                          onTabSelected: (groupIndex, tab) {
                            setState(() {
                              _selectDockPaletteState(
                                left: true,
                                groupIndex: groupIndex,
                                tab: tab,
                              );
                              _temporaryDesktopPalette = null;
                            });
                            _persistDockGroups(left: true);
                            _persistWorkspacePreferences(lastDock: tab);
                          },
                          onCollapse:
                              () => setState(
                                () => _workspaceLeftDockCollapsed = true,
                              ),
                          onGroupResize:
                              (dividerIndex, delta, height) => _resizeDockGroup(
                                left: true,
                                dividerIndex: dividerIndex,
                                delta: delta,
                                availableHeight: height,
                              ),
                          onGroupResizeEnd:
                              () => _persistDockGroups(left: true),
                          onTabReorder:
                              (groupIndex, fromIndex, toIndex) =>
                                  _reorderDockPalette(
                                    left: true,
                                    groupIndex: groupIndex,
                                    fromIndex: fromIndex,
                                    toIndex: toIndex,
                                  ),
                          onTabMove:
                              (source, groupIndex, tabIndex) =>
                                  _moveDockPalette(
                                    source: source,
                                    targetLeft: true,
                                    targetGroupIndex: groupIndex,
                                    targetTabIndex: tabIndex,
                                  ),
                          buildPalette:
                              (tab) => _buildDockPalette(tab, context),
                        ),
                      ),
                      SizedBox(
                        width: 8,
                        child: MouseRegion(
                          cursor: SystemMouseCursors.resizeLeftRight,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onHorizontalDragUpdate: (details) {
                              final next =
                                  (leftDockWidth + details.delta.dx)
                                      .clamp(220.0, 480.0)
                                      .toDouble();
                              if (next == _workspaceLeftDockWidth) return;
                              setState(() => _workspaceLeftDockWidth = next);
                              _persistDockWidth(left: true, width: next);
                            },
                            child: Center(
                              child: Container(
                                width: 1,
                                color: inkColors(context).panelBorder,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (showRightDock)
                Positioned(
                  right: 0,
                  top: 36,
                  bottom: 24,
                  width: dockWidth,
                  child: _DesktopDock(
                    title: 'Workspace',
                    isLeft: false,
                    selectedTab: _desktopDockTab,
                    groups: _rightDockGroups,
                    onTabSelected: (groupIndex, tab) {
                      setState(() {
                        _selectDockPaletteState(
                          left: false,
                          groupIndex: groupIndex,
                          tab: tab,
                        );
                        _temporaryDesktopPalette = null;
                      });
                      _persistDockGroups(left: false);
                      _persistWorkspacePreferences(lastDock: tab);
                    },
                    onCollapse:
                        () => setState(() => _workspaceDockCollapsed = true),
                    onGroupResize:
                        (dividerIndex, delta, height) => _resizeDockGroup(
                          left: false,
                          dividerIndex: dividerIndex,
                          delta: delta,
                          availableHeight: height,
                        ),
                    onGroupResizeEnd: () => _persistDockGroups(left: false),
                    onTabReorder:
                        (groupIndex, fromIndex, toIndex) => _reorderDockPalette(
                          left: false,
                          groupIndex: groupIndex,
                          fromIndex: fromIndex,
                          toIndex: toIndex,
                        ),
                    onTabMove:
                        (source, groupIndex, tabIndex) => _moveDockPalette(
                          source: source,
                          targetLeft: false,
                          targetGroupIndex: groupIndex,
                          targetTabIndex: tabIndex,
                        ),
                    buildPalette: (tab) => _buildDockPalette(tab, context),
                  ),
                ),
              if (!_interfaceHidden && desktopDock)
                Positioned(
                  left: 44 + leftDockWidth,
                  right: dockWidth,
                  bottom: 0,
                  height: 24,
                  child: _EditorStatusBar(
                    brushName: _brushLibrary.selected?.name ?? 'Brush',
                    layerName: _activeLayerName,
                    zoom: _scale,
                    rotation: _rotation,
                    mirrored: _mirrorCanvas,
                    documentWidth: widget.engine.documentInfo.widthPx,
                    documentHeight: widget.engine.documentInfo.heightPx,
                    selected: _selectionGeometry != null,
                    saveStatus: _autosaveStatusLabel(widget.autosaveState),
                  ),
                ),
              if (wideDesktop &&
                  !_interfaceHidden &&
                  layout.right != null &&
                  _workspaceDockCollapsed)
                Positioned(
                  right: 0,
                  top: 88,
                  child: Material(
                    elevation: 6,
                    borderRadius: const BorderRadius.horizontal(
                      left: Radius.circular(12),
                    ),
                    child: Tooltip(
                      message: 'Expand Workspace dock',
                      child: IconButton(
                        onPressed:
                            () =>
                                setState(() => _workspaceDockCollapsed = false),
                        icon: const Icon(Icons.keyboard_double_arrow_left),
                      ),
                    ),
                  ),
                ),
              if (wideDesktop &&
                  !_interfaceHidden &&
                  layout.left != null &&
                  _workspaceLeftDockCollapsed)
                Positioned(
                  left: 44,
                  top: 88,
                  child: Material(
                    elevation: 6,
                    borderRadius: const BorderRadius.horizontal(
                      right: Radius.circular(12),
                    ),
                    child: Tooltip(
                      message: 'Expand Tools & Color dock',
                      child: IconButton(
                        onPressed:
                            () => setState(
                              () => _workspaceLeftDockCollapsed = false,
                            ),
                        icon: const Icon(Icons.keyboard_double_arrow_right),
                      ),
                    ),
                  ),
                ),
              if (desktopDock && _temporaryDesktopPalette != null)
                Positioned(
                  left: 52 + leftDockWidth,
                  top: 44,
                  bottom: 32,
                  width: 360,
                  child: _ToolPanel(
                    title: _paletteLabel(_temporaryDesktopPalette!),
                    onClose:
                        () => setState(() => _temporaryDesktopPalette = null),
                    child: _buildDockPalette(
                      _temporaryDesktopPalette!,
                      context,
                    ),
                  ),
                ),
              if (_showTools)
                if (!desktopDock)
                  Positioned(
                    left: tabletStudioMode ? 56 : 12,
                    top: tabletStudioMode ? 60 : 72,
                    bottom: 12,
                    width: tabletStudioMode ? 320 : 280,
                    child: _ToolPanel(
                      title: 'Illustration tools',
                      docked: tabletStudioMode,
                      onClose: () => setState(() => _showTools = false),
                      child: IllustrationToolPalette(
                        selected: _activeTool,
                        onSelected: _selectTool,
                        onClearSelection: _clearSelection,
                        onTransformPreset: _applyTransformPreset,
                      ),
                    ),
                  ),
              if (_showBrushes)
                if (!desktopDock)
                  Positioned(
                    left: tabletStudioMode ? 56 : 12,
                    top: tabletStudioMode ? 60 : 72,
                    bottom: 12,
                    width: tabletStudioMode ? 320 : 300,
                    child: _ToolPanel(
                      title: 'Brush library',
                      docked: tabletStudioMode,
                      onClose: () => setState(() => _showBrushes = false),
                      child: BrushLibraryPanel(
                        library: _brushLibrary,
                        onSelected:
                            (preset) =>
                                setState(() => _activeBrushId = preset.id),
                        onChanged: _updateBrushDraft,
                        onSizeChangeEnd: _persistBrushSize,
                        onImport:
                            widget.documentPicker is BrushPicker
                                ? _importBrush
                                : null,
                        onExport:
                            widget.documentPicker is BrushPicker
                                ? _exportBrush
                                : null,
                        onDuplicate: _duplicateBrush,
                        onRename: _renameBrush,
                        hasUncommittedChanges: _activeBrushDrafts.containsKey(
                          _brushLibrary.selected?.id,
                        ),
                        onCommitEdit: _commitSelectedBrushDraft,
                        onCancelEdit: _cancelBrushDraft,
                      ),
                    ),
                  ),
              if (_showLayers)
                if (!desktopDock)
                  Positioned(
                    right: tabletStudioMode ? 8 : 12,
                    top: tabletStudioMode ? 60 : 72,
                    bottom: 12,
                    width: tabletStudioMode ? 360 : 280,
                    child: Semantics(
                      container: true,
                      label:
                          tabletStudioMode ? 'Studio palette dock' : 'Layers',
                      child: _ToolPanel(
                        title: 'Layers',
                        docked: tabletStudioMode,
                        onClose: () => setState(() => _showLayers = false),
                        child: _layerPanelContent(),
                      ),
                    ),
                  ),
              if (_showComics)
                if (!desktopDock)
                  Positioned(
                    right: tabletStudioMode ? 8 : 12,
                    top: tabletStudioMode ? 60 : 72,
                    bottom: 12,
                    width: 360,
                    child: _ToolPanel(
                      title: 'Comic workspace',
                      docked: tabletStudioMode,
                      onClose: () => setState(() => _showComics = false),
                      child: ComicWorkspace(
                        controller: _comicWorkspace,
                        onDrawInsidePanel: _drawInsideComicPanel,
                        onClose: () => setState(() => _showComics = false),
                        onBatchExport:
                            widget.documentPicker is ComicExportPicker
                                ? _exportComicPages
                                : null,
                      ),
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
    if (!useNativeMacMenus) return editorShell;
    return PlatformMenuBar(
      menus: _macOSApplicationMenus(
        documentActionsEnabled: documentActionsEnabled,
      ),
      child: editorShell,
    );
  }
}

List<BrushCurvePointView> _curvePointsFromFlat(List<double> values) {
  if (values.length < 4 || values.length.isOdd) {
    return const <BrushCurvePointView>[
      BrushCurvePointView(x: 0, y: 0),
      BrushCurvePointView(x: 0.5, y: 0.5),
      BrushCurvePointView(x: 1, y: 1),
    ];
  }
  final points = <BrushCurvePointView>[];
  for (var index = 0; index < values.length; index += 2) {
    final x = values[index];
    final y = values[index + 1];
    if (!x.isFinite || !y.isFinite || x < 0 || x > 1 || y < 0 || y > 1) {
      return const <BrushCurvePointView>[
        BrushCurvePointView(x: 0, y: 0),
        BrushCurvePointView(x: 0.5, y: 0.5),
        BrushCurvePointView(x: 1, y: 1),
      ];
    }
    if (points.isNotEmpty && x <= points.last.x) {
      return const <BrushCurvePointView>[
        BrushCurvePointView(x: 0, y: 0),
        BrushCurvePointView(x: 0.5, y: 0.5),
        BrushCurvePointView(x: 1, y: 1),
      ];
    }
    points.add(BrushCurvePointView(x: x, y: y));
  }
  return points.length < 2
      ? const <BrushCurvePointView>[
        BrushCurvePointView(x: 0, y: 0),
        BrushCurvePointView(x: 0.5, y: 0.5),
        BrushCurvePointView(x: 1, y: 1),
      ]
      : List<BrushCurvePointView>.unmodifiable(points);
}

double _curveMidpointFromFlat(List<double> values) {
  for (var index = 0; index + 1 < values.length; index += 2) {
    if ((values[index] - 0.5).abs() < 0.001) return values[index + 1];
  }
  return values.length >= 2 ? values[values.length - 1] : 0.5;
}

final Finalizer<List<ui.Image>> _canvasPainterImageFinalizer = Finalizer((
  images,
) {
  for (final image in images) {
    image.dispose();
  }
});

class _CanvasPainter extends CustomPainter {
  _CanvasPainter({
    required this.pan,
    required this.scale,
    required this.rotation,
    required this.mirrored,
    required this.revision,
    required this.documentWidth,
    required this.documentHeight,
    required this.layers,
    required Iterable<MapEntry<TileCacheKey, ui.Image>> tiles,
  }) : tiles = List<MapEntry<TileCacheKey, ui.Image>>.unmodifiable(
         tiles.map((entry) => MapEntry(entry.key, entry.value.clone())),
       ) {
    _canvasPainterImageFinalizer.attach(
      this,
      this.tiles.map((entry) => entry.value).toList(growable: false),
      detach: this,
    );
  }

  static const int _tileSize = 256;

  final Offset pan;
  final double scale;
  final double rotation;
  final bool mirrored;
  final int revision;
  final int documentWidth;
  final int documentHeight;
  final List<LayerView> layers;
  final List<MapEntry<TileCacheKey, ui.Image>> tiles;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(const Color(0xff252525), BlendMode.src);
    canvas.save();
    canvas.translate(size.width / 2 + pan.dx, size.height / 2 + pan.dy);
    canvas.rotate(rotation);
    canvas.scale(mirrored ? -scale : scale, scale);
    canvas.drawRect(
      Rect.fromLTWH(
        -documentWidth / 2,
        -documentHeight / 2,
        documentWidth.toDouble(),
        documentHeight.toDouble(),
      ),
      Paint()..color = Colors.white,
    );
    final compositeTiles = tiles
        .where((entry) => entry.key.layer == -1)
        .toList(growable: false);
    if (compositeTiles.isNotEmpty) {
      const source = Rect.fromLTWH(0, 0, 256, 256);
      for (final entry in compositeTiles) {
        final key = entry.key;
        // Composite tiles use document-space coordinates whose origin is the
        // top-left of the document. The canvas transform is centered on the
        // document, so apply the same origin translation as the layer path;
        // omitting it places every committed tile outside the viewport while
        // the live preview still appears at the cursor.
        final destination = Rect.fromLTWH(
          key.x * _tileSize - documentWidth / 2,
          key.y * _tileSize - documentHeight / 2,
          _tileSize.toDouble(),
          _tileSize.toDouble(),
        );
        canvas.drawImageRect(entry.value, source, destination, Paint());
      }
      canvas.restore();
      return;
    }
    final tilesByLayer = <int, List<MapEntry<TileCacheKey, ui.Image>>>{};
    for (final entry in tiles) {
      (tilesByLayer[entry.key.layer] ??= <MapEntry<TileCacheKey, ui.Image>>[])
          .add(entry);
    }
    final layerById = <int, LayerView>{
      for (final layer in layers) layer.id: layer,
    };
    final orderedLayers = <LayerView>[
      ...layers.where(
        (layer) =>
            _isPaintLayer(layer) && _isEffectivelyVisible(layer, layerById),
      ),
    ];
    final knownLayerIds = orderedLayers.map((layer) => layer.id).toSet();
    for (final entry in tilesByLayer.entries) {
      if (!knownLayerIds.contains(entry.key)) {
        orderedLayers.add(
          LayerView(
            id: entry.key,
            name: 'Layer ${entry.key}',
            kind: LayerKind.raster,
          ),
        );
      }
    }
    final documentRect = Rect.fromLTWH(
      -documentWidth / 2,
      -documentHeight / 2,
      documentWidth.toDouble(),
      documentHeight.toDouble(),
    );
    for (final layer in orderedLayers) {
      final layerTiles = tilesByLayer[layer.id];
      if (layerTiles == null || layerTiles.isEmpty) continue;
      final blendMode = _blendMode(layer.blendMode);
      final opacity = _effectiveOpacity(layer, layerById);
      // The common case is an opaque normal raster layer. Avoiding saveLayer
      // here prevents a full-document offscreen buffer on every pointer
      // update; blend modes and translucent layers still use the isolated
      // compositing path below.
      final needsIsolation = blendMode != BlendMode.srcOver || opacity < 0.999;
      if (needsIsolation) {
        canvas.saveLayer(
          documentRect,
          Paint()
            ..blendMode = blendMode
            ..color = Color.fromRGBO(255, 255, 255, opacity),
        );
      }
      final paint = Paint()..filterQuality = FilterQuality.low;
      for (final entry in layerTiles) {
        final key = entry.key;
        canvas.drawImage(
          entry.value,
          Offset(
            key.x * _tileSize - documentWidth / 2,
            key.y * _tileSize - documentHeight / 2,
          ),
          paint,
        );
      }
      if (needsIsolation) canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CanvasPainter oldDelegate) =>
      pan != oldDelegate.pan ||
      scale != oldDelegate.scale ||
      rotation != oldDelegate.rotation ||
      mirrored != oldDelegate.mirrored ||
      revision != oldDelegate.revision ||
      documentWidth != oldDelegate.documentWidth ||
      documentHeight != oldDelegate.documentHeight ||
      layers != oldDelegate.layers ||
      tiles != oldDelegate.tiles;

  static BlendMode _blendMode(LayerBlendMode mode) => switch (mode) {
    LayerBlendMode.normal => BlendMode.srcOver,
    LayerBlendMode.multiply => BlendMode.multiply,
    LayerBlendMode.screen => BlendMode.screen,
    LayerBlendMode.overlay => BlendMode.overlay,
    LayerBlendMode.darken => BlendMode.darken,
    LayerBlendMode.lighten => BlendMode.lighten,
    LayerBlendMode.add => BlendMode.plus,
    LayerBlendMode.subtract => BlendMode.modulate,
    LayerBlendMode.colorBurn => BlendMode.darken,
    LayerBlendMode.linearBurn => BlendMode.darken,
    LayerBlendMode.colorDodge => BlendMode.plus,
    LayerBlendMode.softLight => BlendMode.softLight,
    LayerBlendMode.hardLight => BlendMode.hardLight,
    LayerBlendMode.difference => BlendMode.difference,
    LayerBlendMode.exclusion => BlendMode.exclusion,
    LayerBlendMode.divide => BlendMode.plus,
  };

  static bool _isPaintLayer(LayerView layer) =>
      layer.kind == LayerKind.raster || layer.kind == LayerKind.vectorInk;

  static bool _isEffectivelyVisible(
    LayerView layer,
    Map<int, LayerView> layerById,
  ) {
    final visited = <int>{};
    LayerView? current = layer;
    while (current != null) {
      if (!visited.add(current.id) || !current.visible) return false;
      current = current.parent == null ? null : layerById[current.parent];
    }
    return true;
  }

  static double _effectiveOpacity(
    LayerView layer,
    Map<int, LayerView> layerById,
  ) {
    final visited = <int>{};
    var opacity = 1.0;
    LayerView? current = layer;
    while (current != null && visited.add(current.id)) {
      opacity *= current.opacity.clamp(0.0, 1.0);
      current = current.parent == null ? null : layerById[current.parent];
    }
    return opacity.clamp(0.0, 1.0);
  }
}

class _CanvasOverlayPainter extends CustomPainter {
  const _CanvasOverlayPainter({
    required this.pan,
    required this.scale,
    required this.rotation,
    required this.mirrored,
    required this.documentWidth,
    required this.documentHeight,
    required this.selection,
    required this.selectionTool,
    required this.previewPoints,
    required this.rulerStart,
    required this.rulerEnd,
  });

  final Offset pan;
  final double scale;
  final double rotation;
  final bool mirrored;
  final int documentWidth;
  final int documentHeight;
  final Rect? selection;
  final IllustrationTool? selectionTool;
  final List<Offset> previewPoints;
  final Offset? rulerStart;
  final Offset? rulerEnd;

  Offset toScreen(Offset point, Size size) {
    final centered = point - Offset(documentWidth / 2, documentHeight / 2);
    final rotated = Offset(
      centered.dx * math.cos(rotation) - centered.dy * math.sin(rotation),
      centered.dx * math.sin(rotation) + centered.dy * math.cos(rotation),
    );
    return Offset(size.width / 2, size.height / 2) +
        pan +
        Offset(mirrored ? -rotated.dx : rotated.dx, rotated.dy) * scale;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final stroke =
        Paint()
          ..color = const Color(0xff3f8cff)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..isAntiAlias = true;
    if (selection != null) {
      final rect = Rect.fromPoints(
        toScreen(selection!.topLeft, size),
        toScreen(selection!.bottomRight, size),
      );
      if (selectionTool == IllustrationTool.ellipseSelect) {
        canvas.drawOval(rect, stroke);
      } else {
        canvas.drawRect(rect, stroke);
      }
    }
    if (previewPoints.length > 1) {
      final path =
          Path()..moveTo(
            toScreen(previewPoints.first, size).dx,
            toScreen(previewPoints.first, size).dy,
          );
      for (final point in previewPoints.skip(1)) {
        final screen = toScreen(point, size);
        path.lineTo(screen.dx, screen.dy);
      }
      canvas.drawPath(path, stroke);
    }
    if (rulerStart != null && rulerEnd != null) {
      final start = toScreen(rulerStart!, size);
      final end = toScreen(rulerEnd!, size);
      canvas.drawLine(start, end, stroke..color = const Color(0xffffb020));
    }
  }

  @override
  bool shouldRepaint(_CanvasOverlayPainter oldDelegate) =>
      pan != oldDelegate.pan ||
      scale != oldDelegate.scale ||
      rotation != oldDelegate.rotation ||
      selection != oldDelegate.selection ||
      selectionTool != oldDelegate.selectionTool ||
      previewPoints != oldDelegate.previewPoints ||
      rulerStart != oldDelegate.rulerStart ||
      rulerEnd != oldDelegate.rulerEnd;
}

class _QuickControls extends StatelessWidget {
  const _QuickControls({
    required this.selectedBrush,
    required this.activeLayerName,
    required this.activeColor,
    required this.eraserActive,
    required this.comicClipActive,
    required this.zoom,
    required this.largeControls,
    required this.onBrushChanged,
    required this.onBrushSizeChangeEnd,
    required this.onBrushes,
    required this.onBrushColor,
    required this.onToggleEraser,
    required this.onTransparentColor,
    required this.onFitCanvas,
    required this.onSettings,
    required this.subColor,
    required this.onSwapColors,
    required this.onResetColors,
  });

  final BrushPresetView? selectedBrush;
  final String activeLayerName;
  final Color activeColor;
  final bool eraserActive;
  final bool comicClipActive;
  final double zoom;
  final bool largeControls;
  final ValueChanged<BrushPresetView> onBrushChanged;
  final ValueChanged<double> onBrushSizeChangeEnd;
  final VoidCallback onBrushes;
  final VoidCallback onBrushColor;
  final VoidCallback onToggleEraser;
  final VoidCallback onTransparentColor;
  final VoidCallback onFitCanvas;
  final VoidCallback onSettings;
  final Color subColor;
  final VoidCallback onSwapColors;
  final VoidCallback onResetColors;

  @override
  Widget build(BuildContext context) {
    final brush = selectedBrush;
    final colorScheme = Theme.of(context).colorScheme;
    const controlHeight = 32.0;
    return Container(
      height: 36,
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: inkColors(context).panelBorder)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              button: true,
              label: brush == null ? 'Brush library' : 'Brush ${brush.name}',
              child: Tooltip(
                message: 'Open brush library (B)',
                child: InkWell(
                  onTap: onBrushes,
                  child: SizedBox(
                    height: controlHeight,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.brush, size: 16),
                          const SizedBox(width: 5),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 112),
                            child: Text(
                              brush?.name ?? 'Choose brush',
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            InkStatusChip(label: activeLayerName, icon: Icons.layers),
            const SizedBox(width: 4),
            _QuickSlider(
              label: 'Size',
              value: (brush?.size ?? 12).clamp(0.25, 512).toDouble(),
              min: 0.25,
              max: 512,
              displayValue:
                  brush == null ? '—' : '${brush.size.toStringAsFixed(1)} px',
              enabled: brush != null,
              height: controlHeight,
              onChanged: (value) {
                if (brush != null) {
                  onBrushChanged(brush.copyWith(size: value));
                }
              },
              onChangeEnd: onBrushSizeChangeEnd,
            ),
            const SizedBox(width: 8),
            _QuickSlider(
              label: 'Opacity',
              value: brush?.opacity ?? 1,
              min: 0,
              max: 1,
              displayValue:
                  brush == null ? '—' : '${(brush.opacity * 100).round()}%',
              enabled: brush != null,
              height: controlHeight,
              onChanged: (value) {
                if (brush != null) {
                  onBrushChanged(brush.copyWith(opacity: value));
                }
              },
            ),
            const SizedBox(width: 4),
            Tooltip(
              message: eraserActive ? 'Use brush' : 'Use eraser (E)',
              child: InkWell(
                onTap: onToggleEraser,
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        eraserActive ? Icons.cleaning_services : Icons.edit,
                        size: 15,
                        color: eraserActive ? colorScheme.primary : null,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        eraserActive ? 'Eraser' : 'Brush',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Tooltip(
              message: 'Transparent color — erase with the active brush',
              child: IconButton(
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(
                  width: 32,
                  height: 32,
                ),
                padding: EdgeInsets.zero,
                onPressed: onTransparentColor,
                style: IconButton.styleFrom(
                  backgroundColor:
                      eraserActive
                          ? Theme.of(context).colorScheme.secondaryContainer
                          : null,
                ),
                icon: const Icon(Icons.layers_clear, size: 18),
              ),
            ),
            if (comicClipActive) ...[
              const SizedBox(width: 4),
              const InkStatusChip(
                label: 'Panel clip on',
                icon: Icons.crop_free,
              ),
            ],
            const SizedBox(width: 4),
            Tooltip(
              message: 'Main and sub colors (X swaps, D resets, C opens color)',
              child: InkWell(
                onTap: onBrushColor,
                borderRadius: BorderRadius.circular(18),
                child: SizedBox(
                  width: 40,
                  height: 32,
                  child: Stack(
                    children: [
                      Positioned(
                        right: 2,
                        bottom: 2,
                        child: _ColorSwatch(
                          color: subColor,
                          size: 18,
                          onTap: onSwapColors,
                        ),
                      ),
                      Positioned(
                        left: 2,
                        top: 2,
                        child: _ColorSwatch(
                          color: activeColor,
                          size: 22,
                          onTap: onBrushColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Tooltip(
              message: 'Reset main/sub colors to black and white (D)',
              child: IconButton(
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(
                  width: 32,
                  height: 32,
                ),
                padding: EdgeInsets.zero,
                onPressed: onResetColors,
                icon: const Icon(Icons.refresh, size: 18),
              ),
            ),
            const VerticalDivider(width: 16),
            Text(
              '${(zoom * 100).round()}%',
              style: Theme.of(context).textTheme.labelMedium,
            ),
            Tooltip(
              message: 'Fit canvas',
              child: IconButton(
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(
                  width: 32,
                  height: 32,
                ),
                padding: EdgeInsets.zero,
                onPressed: onFitCanvas,
                icon: const Icon(Icons.fit_screen, size: 18),
              ),
            ),
            Tooltip(
              message: 'Canvas and gesture settings',
              child: IconButton(
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(
                  width: 32,
                  height: 32,
                ),
                padding: EdgeInsets.zero,
                onPressed: onSettings,
                icon: Icon(Icons.tune, size: 18, color: colorScheme.primary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickSlider extends StatelessWidget {
  const _QuickSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.displayValue,
    required this.enabled,
    required this.height,
    required this.onChanged,
    this.onChangeEnd,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String displayValue;
  final bool enabled;
  final double height;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 190,
    height: height,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelSmall),
        Expanded(
          child: Slider(
            value: value.clamp(min, max).toDouble(),
            min: min,
            max: max,
            onChanged: enabled ? onChanged : null,
            onChangeEnd: enabled ? onChangeEnd : null,
          ),
        ),
        SizedBox(
          width: 48,
          child: Text(
            displayValue,
            textAlign: TextAlign.end,
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ),
      ],
    ),
  );
}

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({
    required this.color,
    required this.size,
    required this.onTap,
  });

  final Color color;
  final double size;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Color swatch',
    child: InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: inkColors(context).panelBorder, width: 1.5),
        ),
      ),
    ),
  );
}

IconData _commandBarIcon(EditorActionId action) => switch (action) {
  EditorActionId.newDocument => Icons.note_add_outlined,
  EditorActionId.openProject => Icons.folder_open_outlined,
  EditorActionId.importPsd => Icons.image_search_outlined,
  EditorActionId.saveProject => Icons.save_outlined,
  EditorActionId.saveProjectAs => Icons.save_as_outlined,
  EditorActionId.exportPng => Icons.ios_share,
  EditorActionId.undo => Icons.undo,
  EditorActionId.redo => Icons.redo,
  EditorActionId.clearSelection => Icons.deselect,
  EditorActionId.invertSelection => Icons.flip_to_back,
  EditorActionId.growSelection => Icons.add_box_outlined,
  EditorActionId.shrinkSelection => Icons.indeterminate_check_box_outlined,
  EditorActionId.toggleEraser => Icons.cleaning_services_outlined,
  EditorActionId.fitCanvas => Icons.fit_screen,
  EditorActionId.toggleInterface => Icons.fullscreen,
  EditorActionId.showTools => Icons.build_outlined,
  EditorActionId.showBrushes => Icons.brush_outlined,
  EditorActionId.showLayers => Icons.layers_outlined,
  EditorActionId.showToolProperties => Icons.tune,
  EditorActionId.showMaterials => Icons.collections_bookmark_outlined,
  EditorActionId.showComics => Icons.auto_stories_outlined,
  EditorActionId.showHistory => Icons.history,
  EditorActionId.showQuickAccess => Icons.bolt_outlined,
  EditorActionId.showColorPicker => Icons.palette_outlined,
  EditorActionId.eyedropper => Icons.colorize,
  EditorActionId.quickMenu => Icons.apps,
  EditorActionId.commandSearch => Icons.search,
  EditorActionId.mirrorCanvas => Icons.flip,
  EditorActionId.resetRotation => Icons.screen_rotation,
  EditorActionId.actualPixels => Icons.one_x_mobiledata,
  EditorActionId.swapColors => Icons.swap_horiz,
  EditorActionId.resetColors => Icons.refresh,
};

class _ProjectNameDialog extends StatefulWidget {
  const _ProjectNameDialog();

  @override
  State<_ProjectNameDialog> createState() => _ProjectNameDialogState();
}

class _ProjectNameDialogState extends State<_ProjectNameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: 'untitled',
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final name = _controller.text.trim().replaceAll(RegExp(r'[/\\]'), '_');
    if (name.isEmpty || name == '.' || name == '..') {
      setState(() => _error = 'Enter a project name.');
      return;
    }
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Save project'),
    content: TextField(
      controller: _controller,
      autofocus: true,
      decoration: InputDecoration(
        labelText: 'Project name',
        suffixText: '.inkproj',
        errorText: _error,
      ),
      onSubmitted: (_) => _save(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _save, child: const Text('Save')),
    ],
  );
}

class _NewDocumentDialog extends StatefulWidget {
  const _NewDocumentDialog();

  @override
  State<_NewDocumentDialog> createState() => _NewDocumentDialogState();
}

class _NewDocumentDialogState extends State<_NewDocumentDialog> {
  final _formKey = GlobalKey<FormState>();
  final _width = TextEditingController(text: '2048');
  final _height = TextEditingController(text: '2048');
  final _dpi = TextEditingController(text: '300');

  @override
  void dispose() {
    _width.dispose();
    _height.dispose();
    _dpi.dispose();
    super.dispose();
  }

  String? _validateDimension(String? value) {
    final parsed = int.tryParse(value ?? '');
    if (parsed == null || parsed < 1 || parsed > 32768) {
      return 'Enter a value from 1 to 32768 pixels';
    }
    return null;
  }

  String? _validateDpi(String? value) {
    final parsed = double.tryParse(value ?? '');
    if (parsed == null || !parsed.isFinite || parsed <= 0) {
      return 'Enter a positive resolution';
    }
    return null;
  }

  void _create() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.of(context).pop((
      int.parse(_width.text),
      int.parse(_height.text),
      double.parse(_dpi.text),
    ));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('New document'),
    content: SizedBox(
      width: 360,
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Create a transparent sRGB canvas. Your current project is checkpointed before switching.',
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _width,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Width (pixels)'),
              validator: _validateDimension,
            ),
            TextFormField(
              controller: _height,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Height (pixels)'),
              validator: _validateDimension,
            ),
            TextFormField(
              controller: _dpi,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(labelText: 'Resolution (DPI)'),
              validator: _validateDpi,
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _create, child: const Text('Create document')),
    ],
  );
}

class _CommandSearchDialog extends StatefulWidget {
  const _CommandSearchDialog();

  @override
  State<_CommandSearchDialog> createState() => _CommandSearchDialogState();
}

class _CommandSearchDialogState extends State<_CommandSearchDialog> {
  final TextEditingController _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final match = searchEditorActions(_query).firstOrNull;
    if (match != null) Navigator.pop(context, match);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final bodyHeight = math.min(480.0, math.max(180.0, size.height - 220));
    final dialogWidth = math.min(480.0, math.max(240.0, size.width - 40));
    final actions = searchEditorActions(_query);
    return AlertDialog(
      title: const Text('Search commands'),
      content: SizedBox(
        width: dialogWidth,
        height: bodyHeight,
        child: Column(
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search tools, palettes, and actions',
              ),
              onChanged: (value) => setState(() => _query = value),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 8),
            Expanded(
              child:
                  actions.isEmpty
                      ? const Center(child: Text('No matching commands'))
                      : ListView.builder(
                        itemCount: actions.length,
                        itemBuilder: (context, index) {
                          final action = actions[index];
                          final details = <String>{
                            action.category,
                            if (action.paletteName != null) action.paletteName!,
                            if (action.toolName != null) action.toolName!,
                            if (action.shortcut != null) action.shortcut!,
                          }.join('  •  ');
                          return ListTile(
                            dense: true,
                            leading: const Icon(Icons.bolt_outlined),
                            title: Text(action.label),
                            subtitle: Text(details),
                            onTap: () => Navigator.pop(context, action),
                          );
                        },
                      ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EditorMenu extends StatelessWidget {
  const _EditorMenu({
    required this.label,
    this.icon,
    required this.actions,
    this.disabledActions = const {},
    required this.onAction,
  });

  final String label;
  final IconData? icon;
  final List<EditorActionId> actions;
  final Set<EditorActionId> disabledActions;
  final ValueChanged<EditorActionId> onAction;

  @override
  Widget build(BuildContext context) => PopupMenuButton<EditorActionId>(
    tooltip: '$label menu',
    padding: EdgeInsets.zero,
    onSelected: onAction,
    itemBuilder:
        (_) => actions
            .map(
              (action) => PopupMenuItem(
                value: action,
                enabled: !disabledActions.contains(action),
                child: Text(action.label),
              ),
            )
            .toList(growable: false),
    child: SizedBox(
      height: 30,
      child: Center(
        child:
            icon == null
                ? Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                )
                : Icon(icon, size: 17),
      ),
    ),
  );
}

class _DesktopToolRail extends StatelessWidget {
  const _DesktopToolRail({
    required this.activeTool,
    required this.onTools,
    required this.onBrushes,
    required this.onLayers,
    required this.onEraser,
    required this.eraserActive,
  });

  final IllustrationTool activeTool;
  final VoidCallback onTools;
  final VoidCallback onBrushes;
  final VoidCallback onLayers;
  final VoidCallback onEraser;
  final bool eraserActive;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: inkColors(context).panel,
      border: Border(right: BorderSide(color: inkColors(context).panelBorder)),
    ),
    child: Column(
      children: [
        const SizedBox(height: 8),
        _RailButton(
          icon: Icons.brush,
          customIcon: InkProjectIconId.brush,
          label: 'Draw tools',
          selected: activeTool == IllustrationTool.brush,
          onPressed: onTools,
        ),
        _RailButton(
          icon: Icons.auto_fix_high,
          label: 'Brush presets',
          onPressed: onBrushes,
        ),
        _RailButton(
          icon: Icons.cleaning_services,
          label: 'Erase',
          selected: eraserActive,
          onPressed: onEraser,
        ),
        const Divider(height: 12),
        _RailButton(icon: Icons.layers, label: 'Layers', onPressed: onLayers),
        _RailButton(icon: Icons.tune, label: 'Tool groups', onPressed: onTools),
        _RailButton(
          icon: Icons.straighten,
          customIcon: InkProjectIconId.ruler,
          label: 'Rulers',
          onPressed: onTools,
        ),
      ],
    ),
  );
}

class _TabletStudioToolRail extends StatelessWidget {
  const _TabletStudioToolRail({
    required this.activeTool,
    required this.eraserActive,
    required this.onTools,
    required this.onBrushes,
    required this.onEraser,
    required this.onLayers,
    required this.onComics,
  });

  final IllustrationTool activeTool;
  final bool eraserActive;
  final VoidCallback onTools;
  final VoidCallback onBrushes;
  final VoidCallback onEraser;
  final VoidCallback onLayers;
  final VoidCallback onComics;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: 'Studio tool rail',
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: inkColors(context).panel,
        border: Border(
          right: BorderSide(color: inkColors(context).panelBorder),
        ),
      ),
      child: SingleChildScrollView(
        child: Column(
          children: [
            const SizedBox(height: 4),
            InkCommandButton(
              icon: Icons.brush,
              label: 'Draw tools',
              selected:
                  activeTool == IllustrationTool.brush ||
                  activeTool == IllustrationTool.eraser,
              onPressed: onTools,
              hitSize: 48,
            ),
            InkCommandButton(
              icon: Icons.auto_fix_high,
              label: 'Brush presets',
              onPressed: onBrushes,
              hitSize: 48,
            ),
            InkCommandButton(
              icon: Icons.cleaning_services,
              label: 'Erase',
              selected: eraserActive,
              onPressed: onEraser,
              hitSize: 48,
            ),
            const Divider(height: 8),
            InkCommandButton(
              icon: Icons.layers,
              label: 'Layers',
              onPressed: onLayers,
              hitSize: 48,
            ),
            InkCommandButton(
              icon: Icons.auto_stories,
              label: 'Comics',
              onPressed: onComics,
              hitSize: 48,
            ),
          ],
        ),
      ),
    ),
  );
}

class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.selected = false,
    this.customIcon,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool selected;
  final InkProjectIconId? customIcon;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: label,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: IconButton(
        tooltip: label,
        onPressed: onPressed,
        visualDensity: VisualDensity.compact,
        iconSize: 19,
        color: selected ? inkColors(context).selectedStrong : null,
        icon:
            customIcon == null
                ? Icon(icon)
                : InkProjectIcon(
                  customIcon!,
                  color: selected ? inkColors(context).selectedStrong : null,
                ),
      ),
    ),
  );
}

class _QuickAccessPanel extends StatefulWidget {
  const _QuickAccessPanel({
    required this.sets,
    required this.activeSetId,
    required this.onAction,
    required this.onChanged,
  });

  final List<QuickAccessSet> sets;
  final String activeSetId;
  final ValueChanged<EditorActionId> onAction;
  final void Function(List<QuickAccessSet>, String activeSetId) onChanged;

  @override
  State<_QuickAccessPanel> createState() => _QuickAccessPanelState();
}

class _QuickAccessPanelState extends State<_QuickAccessPanel> {
  late String _activeSetId = widget.activeSetId;

  @override
  void didUpdateWidget(covariant _QuickAccessPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.sets.any((set) => set.id == _activeSetId)) {
      _activeSetId = widget.activeSetId;
    }
  }

  QuickAccessSet get _activeSet =>
      widget.sets.where((set) => set.id == _activeSetId).firstOrNull ??
      widget.sets.first;

  Future<void> _editSet({QuickAccessSet? existing}) async {
    final nameController = TextEditingController(text: existing?.name ?? '');
    final selected = <EditorActionId>{...?existing?.actions};
    final result = await showDialog<QuickAccessSet>(
      context: context,
      builder:
          (dialogContext) => StatefulBuilder(
            builder:
                (context, setDialogState) => AlertDialog(
                  title: Text(
                    existing == null ? 'New Quick Access set' : 'Edit set',
                  ),
                  content: SizedBox(
                    width: 360,
                    height: 420,
                    child: Column(
                      children: [
                        TextField(
                          controller: nameController,
                          maxLength: 64,
                          decoration: const InputDecoration(
                            labelText: 'Set name',
                          ),
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: ListView(
                            children: [
                              for (final action in EditorActionId.values)
                                CheckboxListTile(
                                  dense: true,
                                  value: selected.contains(action),
                                  title: Text(action.label),
                                  subtitle: Text(action.category),
                                  onChanged:
                                      (enabled) => setDialogState(() {
                                        if (enabled == true &&
                                            selected.length < 32) {
                                          selected.add(action);
                                        } else {
                                          selected.remove(action);
                                        }
                                      }),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed:
                          selected.isEmpty || nameController.text.trim().isEmpty
                              ? null
                              : () => Navigator.pop(
                                dialogContext,
                                QuickAccessSet(
                                  id:
                                      existing?.id ??
                                      'quick-${DateTime.now().microsecondsSinceEpoch}',
                                  name: nameController.text.trim(),
                                  actions: selected.toList(growable: false),
                                ),
                              ),
                      child: const Text('Save'),
                    ),
                  ],
                ),
          ),
    );
    nameController.dispose();
    if (!mounted || result == null) return;
    final updated = [...widget.sets];
    final index = updated.indexWhere((set) => set.id == result.id);
    if (index >= 0) {
      updated[index] = result;
    } else if (updated.length < 8) {
      updated.add(result);
    } else {
      return;
    }
    setState(() => _activeSetId = result.id);
    widget.onChanged(updated, result.id);
  }

  void _deleteActiveSet() {
    if (widget.sets.length <= 1) return;
    final updated = widget.sets.where((set) => set.id != _activeSetId).toList();
    final nextId = updated.first.id;
    setState(() => _activeSetId = nextId);
    widget.onChanged(updated, nextId);
  }

  @override
  Widget build(BuildContext context) {
    final active = _activeSet;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Quick Access',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'Manage Quick Access sets',
                onSelected: (value) {
                  if (value == 'new') {
                    if (widget.sets.length < 8) _editSet();
                  } else if (value == 'edit') {
                    _editSet(existing: active);
                  } else if (value == 'delete') {
                    _deleteActiveSet();
                  }
                },
                itemBuilder:
                    (_) => [
                      PopupMenuItem(
                        value: 'new',
                        enabled: widget.sets.length < 8,
                        child: const Text('New set'),
                      ),
                      const PopupMenuItem(
                        value: 'edit',
                        child: Text('Edit set…'),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        enabled: widget.sets.length > 1,
                        child: const Text('Delete set'),
                      ),
                    ],
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Icon(Icons.more_horiz),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          DropdownButton<String>(
            isExpanded: true,
            value: active.id,
            items: [
              for (final set in widget.sets)
                DropdownMenuItem(value: set.id, child: Text(set.name)),
            ],
            onChanged: (id) {
              if (id == null) return;
              setState(() => _activeSetId = id);
              widget.onChanged(widget.sets, id);
            },
          ),
          const SizedBox(height: 8),
          Expanded(
            child: GridView.extent(
              maxCrossAxisExtent: 150,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              children: [
                for (final action in active.actions)
                  InkToolButton(
                    icon: Icons.bolt,
                    label: action.label,
                    compact: true,
                    onPressed: () => widget.onAction(action),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ColorPalettePanel extends StatelessWidget {
  const _ColorPalettePanel({
    required this.mainColor,
    required this.subColor,
    required this.recentColors,
    required this.eraserActive,
    required this.onChoose,
    required this.onSelectRecent,
    required this.onSwap,
    required this.onReset,
    required this.onTransparent,
  });

  final Color mainColor;
  final Color subColor;
  final List<String> recentColors;
  final bool eraserActive;
  final VoidCallback onChoose;
  final ValueChanged<Color> onSelectRecent;
  final VoidCallback onSwap;
  final VoidCallback onReset;
  final VoidCallback onTransparent;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(12),
    children: [
      Text('Current colors', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 12),
      Row(
        children: [
          _ColorSwatch(color: mainColor, size: 36, onTap: onChoose),
          const SizedBox(width: 8),
          Text('Main', style: Theme.of(context).textTheme.bodyMedium),
          const Spacer(),
          _ColorSwatch(color: subColor, size: 28, onTap: onSwap),
          const SizedBox(width: 6),
          Text('Sub', style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
      const SizedBox(height: 10),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            onPressed: onChoose,
            icon: const Icon(Icons.color_lens_outlined),
            label: const Text('Color selector'),
          ),
          OutlinedButton.icon(
            onPressed: onSwap,
            icon: const Icon(Icons.swap_horiz),
            label: const Text('Swap'),
          ),
          OutlinedButton.icon(
            onPressed: onReset,
            icon: const Icon(Icons.refresh),
            label: const Text('Reset'),
          ),
          FilledButton.tonalIcon(
            onPressed: onTransparent,
            icon: const Icon(Icons.layers_clear),
            label: Text(eraserActive ? 'Transparent active' : 'Transparent'),
          ),
        ],
      ),
      const SizedBox(height: 16),
      Text('Recent colors', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 8),
      if (recentColors.isEmpty)
        Text(
          'Colors you apply appear here for quick reuse.',
          style: Theme.of(context).textTheme.bodySmall,
        )
      else
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final value in recentColors.take(24))
              Tooltip(
                message: value,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap:
                      () => onSelectRecent(
                        Color(int.parse(value.substring(1), radix: 16)),
                      ),
                  child: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: Color(int.parse(value.substring(1), radix: 16)),
                      shape: BoxShape.circle,
                      border: Border.all(color: inkColors(context).panelBorder),
                    ),
                  ),
                ),
              ),
          ],
        ),
    ],
  );
}

class _HistoryPanel extends StatefulWidget {
  const _HistoryPanel({
    required this.engine,
    required this.revisionToken,
    required this.onNavigate,
  });

  final EngineApi engine;
  final int revisionToken;
  final Future<void> Function(int sequence) onNavigate;

  @override
  State<_HistoryPanel> createState() => _HistoryPanelState();
}

class _HistoryPanelState extends State<_HistoryPanel> {
  late Future<rust.HistorySnapshotView> _history = _load();

  Future<rust.HistorySnapshotView> _load() =>
      widget.engine.historySnapshot(limit: 100);

  void _refresh() {
    final nextHistory = _load();
    setState(() {
      _history = nextHistory;
    });
  }

  Future<void> _navigate(BigInt sequence) async {
    await widget.onNavigate(sequence.toInt() + 1);
    if (mounted) _refresh();
  }

  @override
  void didUpdateWidget(covariant _HistoryPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.engine != widget.engine ||
        oldWidget.revisionToken != widget.revisionToken) {
      _history = _load();
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'History',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            IconButton(
              tooltip: 'Refresh history',
              onPressed: _refresh,
              icon: const Icon(Icons.refresh, size: 18),
            ),
          ],
        ),
      ),
      Expanded(
        child: FutureBuilder<rust.HistorySnapshotView>(
          future: _history,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                child: Text(
                  'History unavailable',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              );
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final history = snapshot.requireData;
            return Column(
              children: [
                if (history.wasTrimmed)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'Some older undo history was omitted to keep this document safe to open. Artwork is intact.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                Expanded(
                  child:
                      history.entries.isEmpty
                          ? Center(
                            child: Text(
                              'No edits yet',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          )
                          : ListView.builder(
                            reverse: true,
                            itemCount: history.entries.length,
                            itemBuilder: (context, index) {
                              final entry =
                                  history.entries[history.entries.length -
                                      1 -
                                      index];
                              return ListTile(
                                dense: true,
                                selected:
                                    entry.sequence.toInt() + 1 ==
                                    history.cursor,
                                enabled:
                                    entry.sequence.toInt() + 1 !=
                                    history.cursor,
                                leading: Icon(
                                  _iconFor(entry.kind),
                                  size: 18,
                                  color:
                                      entry.applied
                                          ? inkColors(context).selectedStrong
                                          : Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                ),
                                title: Text(
                                  entry.detail ?? _labelFor(entry.kind),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  entry.applied ? 'Applied' : 'Undone',
                                ),
                                onTap: () => _navigate(entry.sequence),
                              );
                            },
                          ),
                ),
              ],
            );
          },
        ),
      ),
    ],
  );

  IconData _iconFor(String kind) => switch (kind) {
    'stroke' => Icons.brush_outlined,
    'layer' || 'layer_property' => Icons.layers_outlined,
    'merge' => Icons.merge_type,
    'fill' => Icons.format_color_fill,
    'panel' => Icons.crop_square,
    'transform' => Icons.open_with,
    _ => Icons.edit_outlined,
  };

  String _labelFor(String kind) => switch (kind) {
    'stroke' => 'Brush stroke',
    'layer' => 'Layer change',
    'merge' => 'Merge layers',
    'fill' => 'Fill',
    'panel' => 'Panel edit',
    'transform' => 'Transform',
    _ => 'Edit',
  };
}

class _SelectionLauncher extends StatelessWidget {
  const _SelectionLauncher({
    required this.onDeselect,
    required this.onInvert,
    required this.onGrow,
    required this.onShrink,
  });

  final VoidCallback onDeselect;
  final VoidCallback onInvert;
  final VoidCallback onGrow;
  final VoidCallback onShrink;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topLeft,
    child: Material(
      elevation: 4,
      color: inkColors(context).panel,
      borderRadius: BorderRadius.circular(8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 10),
              child: Text('Selection'),
            ),
            InkCommandButton(
              icon: Icons.swap_horiz,
              label: 'Invert selection',
              onPressed: onInvert,
            ),
            InkCommandButton(
              icon: Icons.add,
              label: 'Grow by 1 px',
              onPressed: onGrow,
            ),
            InkCommandButton(
              icon: Icons.remove,
              label: 'Shrink by 1 px',
              onPressed: onShrink,
            ),
            InkCommandButton(
              icon: Icons.close,
              label: 'Deselect',
              onPressed: onDeselect,
            ),
          ],
        ),
      ),
    ),
  );
}

class _EditorStatusBar extends StatelessWidget {
  const _EditorStatusBar({
    required this.brushName,
    required this.layerName,
    required this.zoom,
    required this.rotation,
    required this.mirrored,
    required this.documentWidth,
    required this.documentHeight,
    required this.selected,
    required this.saveStatus,
  });

  final String brushName;
  final String layerName;
  final double zoom;
  final double rotation;
  final bool mirrored;
  final int documentWidth;
  final int documentHeight;
  final bool selected;
  final String saveStatus;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10),
    decoration: BoxDecoration(
      color: inkColors(context).panel,
      border: Border(top: BorderSide(color: inkColors(context).panelBorder)),
    ),
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _status(context, brushName),
          _status(context, layerName),
          _status(context, selected ? 'Selection active' : 'No selection'),
          const SizedBox(width: 12),
          _status(context, '$documentWidth×$documentHeight  •  8-bit sRGB'),
          _status(context, '${(zoom * 100).round()}%'),
          _status(
            context,
            '${(rotation * 180 / math.pi).round()}°${mirrored ? '  •  Mirrored' : ''}',
          ),
          _status(context, saveStatus),
        ],
      ),
    ),
  );

  Widget _status(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(right: 14),
    child: Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.labelSmall,
    ),
  );
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.documentName,
    required this.documentActionsEnabled,
    required this.documentActionRunning,
    required this.onOpen,
    required this.onSave,
    required this.onExport,
    required this.onExportMenu,
    this.onExportTimeLapse,
    required this.onGestureSettings,
    required this.onBrushColor,
    required this.onAccessibilitySettings,
    required this.onCanvasDiagnostics,
    required this.largeControls,
    required this.leftHanded,
    required this.onTools,
    required this.onBrushes,
    required this.onLayers,
    required this.onComics,
    required this.onUndo,
    required this.onRedo,
    required this.onCommandSearch,
    required this.onMirror,
    required this.mirrored,
    required this.tabletSimpleMode,
    required this.tabletStudioMode,
    required this.onToggleTabletMode,
    required this.workspaceId,
    required this.onWorkspaceSelected,
    required this.professionalDesktop,
    required this.nativeMenuBar,
    required this.customWorkspaces,
    required this.onSaveWorkspaceAs,
    required this.onResetWorkspace,
    required this.followDocumentType,
    required this.onFollowDocumentTypeChanged,
    required this.onRenameWorkspace,
    required this.onDeleteWorkspace,
    required this.onActionDispatch,
    required this.commandBarItems,
    required this.onCustomizeCommandBar,
    this.contextControls,
  });

  final String documentName;
  final bool documentActionsEnabled;
  final bool documentActionRunning;
  final VoidCallback onOpen;
  final VoidCallback onSave;
  final VoidCallback onExport;
  final VoidCallback onExportMenu;
  final VoidCallback? onExportTimeLapse;
  final VoidCallback onGestureSettings;
  final VoidCallback onBrushColor;
  final VoidCallback onAccessibilitySettings;
  final VoidCallback onCanvasDiagnostics;
  final bool largeControls;
  final bool leftHanded;
  final VoidCallback onTools;
  final VoidCallback onBrushes;
  final VoidCallback onLayers;
  final VoidCallback onComics;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback onCommandSearch;
  final VoidCallback onMirror;
  final bool mirrored;
  final bool tabletSimpleMode;
  final bool tabletStudioMode;
  final VoidCallback onToggleTabletMode;
  final String workspaceId;
  final ValueChanged<String> onWorkspaceSelected;
  final bool professionalDesktop;
  final bool nativeMenuBar;
  final List<WorkspaceLayout> customWorkspaces;
  final VoidCallback onSaveWorkspaceAs;
  final ValueChanged<String> onResetWorkspace;
  final bool followDocumentType;
  final ValueChanged<bool> onFollowDocumentTypeChanged;
  final ValueChanged<String> onRenameWorkspace;
  final ValueChanged<String> onDeleteWorkspace;
  final EditorActionHandler onActionDispatch;
  final List<String> commandBarItems;
  final VoidCallback onCustomizeCommandBar;
  final Widget? contextControls;

  bool _isDocumentActionDisabled(EditorActionId action) =>
      (documentActionRunning && action == EditorActionId.newDocument) ||
      (!documentActionsEnabled &&
          const {
            EditorActionId.openProject,
            EditorActionId.importPsd,
            EditorActionId.saveProject,
            EditorActionId.saveProjectAs,
            EditorActionId.exportPng,
          }.contains(action));

  @override
  Widget build(BuildContext context) {
    if (tabletSimpleMode) return _buildSimple(context);
    // Keep the desktop command bar discoverable in narrow windows. The full
    // palette of commands moves into a labeled menu instead of becoming
    // reachable only by horizontally scrolling tiny icons.
    final availableWidth = MediaQuery.sizeOf(context).width;
    // At standard laptop/desktop sizes keep the active brush controls visible,
    // but move secondary command-bar items into More commands before the
    // contextual controls get clipped by the edge of the viewport.
    final compactDesktop = availableWidth < 1600;
    const compactVisibleCommands = {
      'undo',
      'redo',
      'commandSearch',
      'showBrushes',
      'showLayers',
      'showColorPicker',
    };
    return SafeArea(
      bottom: false,
      child: Container(
        height: tabletStudioMode ? 48 : 36,
        decoration: BoxDecoration(
          color: inkColors(context).panel,
          border: Border(
            bottom: BorderSide(color: inkColors(context).panelBorder),
          ),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(width: 12),
              Text(
                '$documentName  •  Pen',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              PopupMenuButton<String>(
                tooltip: 'Workspace',
                onSelected: (value) {
                  if (value == 'saveAs') {
                    onSaveWorkspaceAs();
                  } else if (value == 'customize') {
                    onCustomizeCommandBar();
                  } else if (value == 'resetCurrent') {
                    onResetWorkspace(workspaceId);
                  } else if (value == 'follow') {
                    onFollowDocumentTypeChanged(!followDocumentType);
                  } else if (value.startsWith('rename:')) {
                    onRenameWorkspace(value.substring('rename:'.length));
                  } else if (value.startsWith('delete:')) {
                    onDeleteWorkspace(value.substring('delete:'.length));
                  } else {
                    onWorkspaceSelected(value);
                  }
                },
                itemBuilder: (_) {
                  final entries = <PopupMenuEntry<String>>[
                    const PopupMenuItem(
                      value: 'illustration',
                      child: Text('Illustration workspace'),
                    ),
                    const PopupMenuItem(
                      value: 'comic',
                      child: Text('Comic workspace'),
                    ),
                    const PopupMenuItem(
                      value: 'minimal',
                      child: Text('Minimal workspace'),
                    ),
                    CheckedPopupMenuItem(
                      value: 'follow',
                      checked: followDocumentType,
                      child: const Text('Follow document type'),
                    ),
                  ];
                  if (customWorkspaces.isNotEmpty) {
                    entries.add(const PopupMenuDivider());
                    for (final layout in customWorkspaces) {
                      entries.add(
                        PopupMenuItem(
                          value: layout.id,
                          child: Text(layout.name),
                        ),
                      );
                      entries.add(
                        PopupMenuItem(
                          value: 'rename:${layout.id}',
                          child: Text('Rename “${layout.name}”…'),
                        ),
                      );
                      entries.add(
                        PopupMenuItem(
                          value: 'delete:${layout.id}',
                          child: Text('Delete “${layout.name}”…'),
                        ),
                      );
                    }
                  }
                  entries.add(const PopupMenuDivider());
                  if (const {
                    'illustration',
                    'comic',
                    'minimal',
                  }.contains(workspaceId)) {
                    entries.add(
                      const PopupMenuItem(
                        value: 'resetCurrent',
                        child: Text('Reset current workspace layout…'),
                      ),
                    );
                  }
                  entries.add(
                    const PopupMenuItem(
                      value: 'saveAs',
                      child: Text('Save current workspace as…'),
                    ),
                  );
                  entries.add(
                    const PopupMenuItem(
                      value: 'customize',
                      child: Text('Customize command bar…'),
                    ),
                  );
                  return entries;
                },
                child: Tooltip(
                  message:
                      'Workspace: ${workspaceId == 'comic'
                          ? 'Comic'
                          : workspaceId == 'minimal'
                          ? 'Minimal'
                          : 'Illustration'}',
                  child: const SizedBox(
                    width: 32,
                    child: Icon(Icons.dashboard_customize_outlined, size: 18),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              if (!nativeMenuBar) ...[
                if (professionalDesktop && !compactDesktop)
                  for (final menu in const [
                    'File',
                    'Edit',
                    'View',
                    'Layer',
                    'Select',
                    'Tool',
                    'Window',
                    'Help',
                  ]) ...[
                    _EditorMenu(
                      label: menu,
                      actions: EditorActionId.values
                          .where(
                            (action) =>
                                action.category == menu ||
                                (menu == 'Tool' && action.category == 'Color'),
                          )
                          .toList(growable: false),
                      disabledActions:
                          documentActionsEnabled && !documentActionRunning
                              ? const {}
                              : {
                                if (!documentActionsEnabled) ...{
                                  EditorActionId.openProject,
                                  EditorActionId.importPsd,
                                  EditorActionId.saveProject,
                                  EditorActionId.saveProjectAs,
                                  EditorActionId.exportPng,
                                },
                                if (documentActionRunning)
                                  EditorActionId.newDocument,
                              },
                      onAction: onActionDispatch,
                    ),
                    const SizedBox(width: 4),
                  ]
                else
                  _EditorMenu(
                    label: 'Menu',
                    icon: Icons.menu,
                    actions: EditorActionId.values,
                    onAction: onActionDispatch,
                  ),
                const VerticalDivider(width: 8, indent: 7, endIndent: 7),
              ],
              if (compactDesktop) ...[
                for (final item in commandBarItems)
                  if (compactVisibleCommands.contains(item))
                    _commandBarButton(item),
                _commandOverflowMenu(context, compactVisibleCommands),
              ] else
                for (final item in commandBarItems)
                  if (item == 'separator')
                    const VerticalDivider(width: 12, indent: 7, endIndent: 7)
                  else
                    _commandBarButton(item),
              InkCommandButton(
                icon: Icons.touch_app,
                label: 'Gesture settings',
                onPressed: onGestureSettings,
                hitSize: tabletStudioMode ? 48 : 32,
              ),
              InkCommandButton(
                icon: Icons.accessibility_new,
                label: 'Accessibility settings',
                onPressed: onAccessibilitySettings,
                hitSize: tabletStudioMode ? 48 : 32,
              ),
              InkCommandButton(
                icon: Icons.monitor_heart_outlined,
                label: 'Canvas input diagnostics',
                onPressed: onCanvasDiagnostics,
                hitSize: tabletStudioMode ? 48 : 32,
              ),
              if (contextControls != null && !compactDesktop) ...[
                const VerticalDivider(width: 12, indent: 7, endIndent: 7),
                contextControls!,
              ],
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _commandOverflowMenu(
    BuildContext context,
    Set<String> excludedCommands,
  ) => PopupMenuButton<EditorActionId>(
    tooltip: 'More commands',
    onSelected: onActionDispatch,
    itemBuilder:
        (_) => [
          for (final name in commandBarItems)
            if (name != 'separator' && !excludedCommands.contains(name))
              for (final action in EditorActionId.values.where(
                (candidate) => candidate.name == name,
              ))
                PopupMenuItem(
                  value: action,
                  enabled: !_isDocumentActionDisabled(action),
                  child: Text(
                    _commandBarLabel(action),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
        ],
    child: const SizedBox(
      width: 40,
      height: 36,
      child: Icon(Icons.more_horiz, size: 20),
    ),
  );

  Widget _commandBarButton(String name) {
    final action =
        EditorActionId.values
            .where((candidate) => candidate.name == name)
            .firstOrNull;
    if (action == null) return const SizedBox.shrink();
    final disabled = _isDocumentActionDisabled(action);
    final toolbarLabel = _commandBarLabel(action);
    final label = [
      toolbarLabel,
      if (action.shortcut != null) action.shortcut!,
    ].join('  •  ');
    return InkCommandButton(
      icon: _commandBarIcon(action),
      label: label,
      selected: action == EditorActionId.mirrorCanvas && mirrored,
      onPressed: disabled ? null : () => onActionDispatch(action),
      hitSize: tabletStudioMode ? 48 : 32,
    );
  }

  String _commandBarLabel(EditorActionId action) => switch (action) {
    EditorActionId.showColorPicker => 'Brush color',
    EditorActionId.showBrushes => 'Brush library',
    EditorActionId.showComics => 'Comic workspace',
    _ => action.label,
  };

  Widget _buildSimple(BuildContext context) => SafeArea(
    bottom: false,
    child: Container(
      height: 52,
      decoration: BoxDecoration(
        color: inkColors(context).panel,
        border: Border(
          bottom: BorderSide(color: inkColors(context).panelBorder),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text('$documentName  •  Pen'),
            ),
            InkCommandButton(
              icon: Icons.photo_library_outlined,
              label: 'Gallery and documents',
              onPressed: onOpen,
              hitSize: 48,
            ),
            InkCommandButton(
              icon: Icons.tune,
              label: 'Actions',
              onPressed: onGestureSettings,
              hitSize: 48,
            ),
            InkCommandButton(
              icon: Icons.select_all,
              label: 'Selections',
              onPressed: onTools,
              hitSize: 48,
            ),
            InkCommandButton(
              icon: Icons.open_with,
              label: 'Transform',
              onPressed: onTools,
              hitSize: 48,
            ),
            const SizedBox(width: 8),
            InkCommandButton(
              icon: Icons.brush,
              label: 'Brush library',
              onPressed: onBrushes,
              hitSize: 48,
            ),
            InkCommandButton(
              icon: Icons.layers,
              label: 'Layers',
              onPressed: onLayers,
              hitSize: 48,
            ),
            InkCommandButton(
              icon: Icons.palette,
              label: 'Brush color',
              onPressed: onBrushColor,
              hitSize: 48,
            ),
            InkCommandButton(
              icon: Icons.auto_stories,
              label: 'Comic workspace',
              onPressed: onComics,
              hitSize: 48,
            ),
            if (documentActionsEnabled)
              InkCommandButton(
                icon: Icons.save,
                label: 'Save project',
                onPressed: onSave,
                hitSize: 48,
              ),
            PopupMenuButton<String>(
              tooltip: 'Workspace mode',
              onSelected: (value) {
                if (value == 'mode') onToggleTabletMode();
                if (value == 'comic') onWorkspaceSelected('comic');
                if (value == 'diagnostics') onCanvasDiagnostics();
              },
              itemBuilder:
                  (_) => [
                    PopupMenuItem(
                      value: 'mode',
                      child: Text(
                        'Switch to ${tabletSimpleMode ? 'Studio' : 'Simple'} mode',
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'comic',
                      child: Text('Comic workspace'),
                    ),
                    const PopupMenuItem(
                      value: 'diagnostics',
                      child: Text('Canvas input diagnostics'),
                    ),
                  ],
              child: const SizedBox(width: 40, child: Icon(Icons.more_horiz)),
            ),
            const SizedBox(width: 6),
          ],
        ),
      ),
    ),
  );
}

class _SimpleEdgeControls extends StatelessWidget {
  const _SimpleEdgeControls({
    required this.selectedBrush,
    required this.onBrushChanged,
    required this.onBrushSizeChangeEnd,
    required this.onUndo,
    required this.onRedo,
    required this.onEyedropper,
  });

  final BrushPresetView? selectedBrush;
  final ValueChanged<BrushPresetView> onBrushChanged;
  final ValueChanged<double> onBrushSizeChangeEnd;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback onEyedropper;

  @override
  Widget build(BuildContext context) {
    final brush = selectedBrush;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: inkColors(context).panel.withValues(alpha: 0.94),
        border: Border.all(color: inkColors(context).panelBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkCommandButton(
              icon: Icons.undo,
              label: 'Undo',
              onPressed: onUndo,
              hitSize: 48,
            ),
            InkCommandButton(
              icon: Icons.redo,
              label: 'Redo',
              onPressed: onRedo,
              hitSize: 48,
            ),
            const Divider(height: 4),
            _slider(
              context,
              label: 'Brush size',
              value: (brush?.size ?? 12).clamp(0.25, 512).toDouble(),
              min: 0.25,
              max: 512,
              valueLabel:
                  brush == null ? '—' : '${brush.size.toStringAsFixed(1)} px',
              enabled: brush != null,
              onChanged: (value) {
                if (brush != null) {
                  onBrushChanged(brush.copyWith(size: value));
                }
              },
              onChangeEnd: onBrushSizeChangeEnd,
            ),
            _slider(
              context,
              label: 'Brush opacity',
              value: brush?.opacity ?? 1,
              min: 0,
              max: 1,
              valueLabel:
                  brush == null ? '—' : '${(brush.opacity * 100).round()}%',
              enabled: brush != null,
              onChanged: (value) {
                if (brush != null) {
                  onBrushChanged(brush.copyWith(opacity: value));
                }
              },
            ),
            InkCommandButton(
              icon: Icons.colorize,
              label: 'Eyedropper',
              onPressed: onEyedropper,
              hitSize: 48,
            ),
          ],
        ),
      ),
    );
  }

  Widget _slider(
    BuildContext context, {
    required String label,
    required double value,
    required double min,
    required double max,
    required String valueLabel,
    required bool enabled,
    required ValueChanged<double> onChanged,
    ValueChanged<double>? onChangeEnd,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          label: label,
          value: valueLabel,
          child: ExcludeSemantics(
            child: RotatedBox(
              quarterTurns: 3,
              child: SizedBox(
                width: 144,
                height: 40,
                child: Slider(
                  value: value,
                  min: min,
                  max: max,
                  onChanged: enabled ? onChanged : null,
                  onChangeEnd: enabled ? onChangeEnd : null,
                ),
              ),
            ),
          ),
        ),
        SizedBox(
          width: math.max(64, MediaQuery.textScalerOf(context).scale(64)),
          child: Text(
            valueLabel,
            maxLines: 1,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ),
      ],
    ),
  );
}

class _DockPaletteDragData {
  const _DockPaletteDragData({
    required this.isLeft,
    required this.groupIndex,
    required this.tabIndex,
    required this.palette,
  });

  final bool isLeft;
  final int groupIndex;
  final int tabIndex;
  final InkPaletteId palette;
}

class _DesktopDock extends StatelessWidget {
  const _DesktopDock({
    required this.title,
    required this.isLeft,
    required this.selectedTab,
    required this.groups,
    required this.onTabSelected,
    required this.onCollapse,
    required this.onGroupResize,
    required this.onGroupResizeEnd,
    required this.onTabReorder,
    required this.onTabMove,
    required this.buildPalette,
  });

  final String title;
  final bool isLeft;
  final String selectedTab;
  final List<DockGroupLayout> groups;
  final void Function(int groupIndex, String tab) onTabSelected;
  final VoidCallback onCollapse;
  final void Function(int dividerIndex, double delta, double height)
  onGroupResize;
  final VoidCallback onGroupResizeEnd;
  final void Function(int groupIndex, int fromIndex, int toIndex) onTabReorder;
  final void Function(
    _DockPaletteDragData source,
    int targetGroupIndex,
    int targetTabIndex,
  )
  onTabMove;
  final Widget Function(String tab) buildPalette;

  @override
  Widget build(BuildContext context) {
    final effectiveGroups =
        groups.isEmpty
            ? const [
              DockGroupLayout(
                tabs: [InkPaletteId.layers],
                activeTab: InkPaletteId.layers,
              ),
            ]
            : groups;
    final totalFlex = effectiveGroups.fold<double>(
      0,
      (total, group) => total + group.flex,
    );
    return Material(
      elevation: 0,
      color: inkColors(context).panel,
      child: SafeArea(
        left: false,
        child: Column(
          children: [
            InkDockHeader(
              title: title,
              subtitle: selectedTab[0].toUpperCase() + selectedTab.substring(1),
              actions: [
                PopupMenuButton<String>(
                  tooltip: 'All palettes',
                  padding: EdgeInsets.zero,
                  onSelected: (tab) {
                    final palette = _paletteNameToId(tab);
                    final existingIndex =
                        palette == null
                            ? -1
                            : effectiveGroups.indexWhere(
                              (group) => group.tabs.contains(palette),
                            );
                    onTabSelected(existingIndex < 0 ? 0 : existingIndex, tab);
                  },
                  itemBuilder:
                      (_) => const [
                        PopupMenuItem(
                          value: 'tools',
                          child: Text('Tool groups'),
                        ),
                        PopupMenuItem(
                          value: 'brushes',
                          child: Text('Brush presets'),
                        ),
                        PopupMenuItem(
                          value: 'properties',
                          child: Text('Tool properties'),
                        ),
                        PopupMenuItem(value: 'layers', child: Text('Layers')),
                        PopupMenuItem(
                          value: 'materials',
                          child: Text('Materials'),
                        ),
                        PopupMenuItem(value: 'comics', child: Text('Comics')),
                        PopupMenuItem(value: 'history', child: Text('History')),
                        PopupMenuItem(
                          value: 'quickAccess',
                          child: Text('Quick Access'),
                        ),
                        PopupMenuItem(value: 'color', child: Text('Color')),
                      ],
                  child: const SizedBox(
                    width: 36,
                    child: Icon(Icons.grid_view, size: 18),
                  ),
                ),
                Tooltip(
                  message: 'Collapse Workspace dock',
                  child: IconButton(
                    onPressed: onCollapse,
                    icon: const Icon(Icons.keyboard_double_arrow_right),
                  ),
                ),
              ],
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  const dividerHeight = 8.0;
                  final availableHeight = math.max(
                    0.0,
                    constraints.maxHeight -
                        dividerHeight * (effectiveGroups.length - 1),
                  );
                  return Column(
                    children: [
                      for (
                        var index = 0;
                        index < effectiveGroups.length;
                        index++
                      ) ...[
                        if (index > 0)
                          Tooltip(
                            message: 'Resize palette groups',
                            child: MouseRegion(
                              cursor: SystemMouseCursors.resizeUpDown,
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onVerticalDragUpdate:
                                    (details) => onGroupResize(
                                      index - 1,
                                      details.delta.dy,
                                      availableHeight,
                                    ),
                                onVerticalDragEnd: (_) => onGroupResizeEnd(),
                                child: SizedBox(
                                  height: dividerHeight,
                                  child: Center(
                                    child: Container(
                                      height: 1,
                                      color: inkColors(context).panelBorder,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        Expanded(
                          flex:
                              ((effectiveGroups[index].flex / totalFlex).clamp(
                                        0.15,
                                        0.70,
                                      ) *
                                      100)
                                  .round(),
                          child: _DockPaletteGroup(
                            group: effectiveGroups[index],
                            isLeft: isLeft,
                            groupIndex: index,
                            selectedTab: _groupSelectedTab(
                              effectiveGroups[index],
                              index == 0 ? selectedTab : '',
                            ),
                            onTabSelected: (tab) => onTabSelected(index, tab),
                            onTabReorder:
                                (fromIndex, toIndex) =>
                                    onTabReorder(index, fromIndex, toIndex),
                            onTabMove:
                                (source, targetIndex) =>
                                    onTabMove(source, index, targetIndex),
                            buildPalette: buildPalette,
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _groupSelectedTab(DockGroupLayout group, String fallback) {
    final fallbackPalette = switch (fallback) {
      'tools' => InkPaletteId.toolGroups,
      'brushes' => InkPaletteId.brushPresets,
      'properties' => InkPaletteId.toolProperties,
      'color' => InkPaletteId.color,
      'materials' => InkPaletteId.materials,
      'comics' => InkPaletteId.comics,
      'history' => InkPaletteId.history,
      'quickAccess' => InkPaletteId.quickAccess,
      _ => InkPaletteId.layers,
    };
    final preferred = group.activeTab ?? fallbackPalette;
    return _paletteIdToName(
      group.tabs.contains(preferred) ? preferred : group.tabs.first,
    );
  }
}

class _DockPaletteGroup extends StatelessWidget {
  const _DockPaletteGroup({
    required this.group,
    required this.isLeft,
    required this.groupIndex,
    required this.selectedTab,
    required this.onTabSelected,
    required this.onTabReorder,
    required this.onTabMove,
    required this.buildPalette,
  });

  final DockGroupLayout group;
  final bool isLeft;
  final int groupIndex;
  final String selectedTab;
  final ValueChanged<String> onTabSelected;
  final void Function(int fromIndex, int toIndex) onTabReorder;
  final void Function(_DockPaletteDragData source, int targetIndex) onTabMove;
  final Widget Function(String tab) buildPalette;

  @override
  Widget build(BuildContext context) {
    final selectedId = _paletteNameToId(selectedTab);
    final tabs = [...group.tabs];
    if (selectedId != null && !tabs.contains(selectedId) && tabs.length < 8) {
      tabs.add(selectedId);
    }
    final visibleTabs = tabs.take(3).toList(growable: false);
    final overflowTabs = tabs.skip(3).toList(growable: false);
    return Column(
      children: [
        SizedBox(
          height: 38,
          child: Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    for (final palette in visibleTabs)
                      Flexible(
                        child: _draggableTab(palette, tabs.indexOf(palette)),
                      ),
                    if (overflowTabs.isNotEmpty)
                      PopupMenuButton<String>(
                        tooltip: 'More palettes',
                        onSelected: onTabSelected,
                        itemBuilder:
                            (_) => [
                              for (final palette in overflowTabs)
                                PopupMenuItem(
                                  value: _paletteIdToName(palette),
                                  child: Text(_paletteIdLabel(palette)),
                                ),
                            ],
                        child: const SizedBox(
                          width: 32,
                          height: 38,
                          child: Icon(Icons.more_horiz, size: 18),
                        ),
                      ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'Add palette to this group',
                onSelected: onTabSelected,
                itemBuilder:
                    (_) => [
                      for (final palette in InkPaletteId.values.where(
                        (item) => !tabs.contains(item),
                      ))
                        PopupMenuItem(
                          value: _paletteIdToName(palette),
                          child: Text(_paletteIdLabel(palette)),
                        ),
                    ],
                child: const SizedBox(
                  width: 32,
                  height: 38,
                  child: Icon(Icons.add, size: 18),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: buildPalette(selectedTab)),
      ],
    );
  }

  Widget _draggableTab(InkPaletteId palette, int tabIndex) {
    final tabName = _paletteIdToName(palette);
    return DragTarget<_DockPaletteDragData>(
      onWillAcceptWithDetails: (details) {
        return !(details.data.isLeft == isLeft &&
            details.data.groupIndex == groupIndex &&
            details.data.tabIndex == tabIndex);
      },
      onAcceptWithDetails: (details) {
        final source = details.data;
        if (source.isLeft == isLeft && source.groupIndex == groupIndex) {
          onTabReorder(source.tabIndex, tabIndex);
        } else {
          onTabMove(source, tabIndex);
        }
      },
      builder: (context, candidates, rejected) {
        final tab = _DockTabChip(
          tab: tabName,
          selected: tabName == selectedTab,
          onPressed: () => onTabSelected(tabName),
          dropTarget: candidates.isNotEmpty,
        );
        return Draggable<_DockPaletteDragData>(
          data: _DockPaletteDragData(
            isLeft: isLeft,
            groupIndex: groupIndex,
            tabIndex: tabIndex,
            palette: palette,
          ),
          feedback: Material(
            color: Colors.transparent,
            child: SizedBox(width: 108, child: tab),
          ),
          childWhenDragging: Opacity(opacity: 0.35, child: tab),
          child: tab,
        );
      },
    );
  }
}

class _DockTabChip extends StatelessWidget {
  const _DockTabChip({
    required this.tab,
    required this.selected,
    required this.onPressed,
    this.dropTarget = false,
  });

  final String tab;
  final bool selected;
  final VoidCallback onPressed;
  final bool dropTarget;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: _paletteIdLabel(_paletteNameToId(tab)!),
    child: InkWell(
      onTap: onPressed,
      child: Container(
        constraints: const BoxConstraints(minWidth: 64),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color:
              dropTarget
                  ? inkColors(context).selectedStrong.withValues(alpha: 0.3)
                  : selected
                  ? inkColors(context).selected
                  : null,
          border:
              selected || dropTarget
                  ? Border(
                    bottom: BorderSide(
                      color:
                          dropTarget
                              ? inkColors(context).selectedStrong
                              : inkColors(context).selectedStrong,
                      width: dropTarget ? 3 : 2,
                    ),
                  )
                  : null,
        ),
        child: Text(
          _paletteShortLabel(tab),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ),
    ),
  );
}

String _paletteIdToName(InkPaletteId id) => switch (id) {
  InkPaletteId.toolGroups => 'tools',
  InkPaletteId.brushPresets => 'brushes',
  InkPaletteId.toolProperties => 'properties',
  InkPaletteId.color => 'color',
  InkPaletteId.layers => 'layers',
  InkPaletteId.materials => 'materials',
  InkPaletteId.comics => 'comics',
  InkPaletteId.history => 'history',
  InkPaletteId.quickAccess => 'quickAccess',
};

InkPaletteId? _paletteNameToId(String name) => switch (name) {
  'tools' => InkPaletteId.toolGroups,
  'brushes' => InkPaletteId.brushPresets,
  'properties' => InkPaletteId.toolProperties,
  'color' => InkPaletteId.color,
  'layers' => InkPaletteId.layers,
  'materials' => InkPaletteId.materials,
  'comics' => InkPaletteId.comics,
  'history' => InkPaletteId.history,
  'quickAccess' => InkPaletteId.quickAccess,
  _ => null,
};

String _paletteIdLabel(InkPaletteId id) => switch (id) {
  InkPaletteId.toolGroups => 'Tool groups',
  InkPaletteId.brushPresets => 'Brush presets',
  InkPaletteId.toolProperties => 'Tool properties',
  InkPaletteId.color => 'Color',
  InkPaletteId.layers => 'Layers',
  InkPaletteId.materials => 'Materials',
  InkPaletteId.comics => 'Comics',
  InkPaletteId.history => 'History',
  InkPaletteId.quickAccess => 'Quick Access',
};

String _paletteShortLabel(String name) {
  if (name == 'tools') return 'Tools';
  if (name == 'brushes') return 'Brushes';
  if (name == 'properties') return 'Props';
  final id = _paletteNameToId(name);
  return id == null ? name : _paletteIdLabel(id);
}

class _ToolPanel extends StatelessWidget {
  const _ToolPanel({
    required this.title,
    required this.onClose,
    required this.child,
    this.docked = false,
  });

  final String title;
  final VoidCallback onClose;
  final Widget child;
  final bool docked;

  @override
  Widget build(BuildContext context) {
    final panel = Column(
      children: [
        InkDockHeader(
          title: title,
          actions: [
            IconButton(
              tooltip: 'Close $title',
              onPressed: onClose,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        Expanded(child: child),
      ],
    );
    if (docked) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: inkColors(context).panel,
          border: Border(
            left: BorderSide(color: inkColors(context).panelBorder),
          ),
        ),
        child: ClipRect(child: panel),
      );
    }
    return Material(
      color: inkColors(context).panel,
      elevation: 8,
      borderRadius: BorderRadius.circular(inkMetrics(context).panelRadius),
      clipBehavior: Clip.antiAlias,
      child: panel,
    );
  }
}

class _QuickMenu extends StatelessWidget {
  const _QuickMenu({
    required this.eraserActive,
    required this.brush,
    required this.color,
    required this.onToggleEraser,
    required this.onFitCanvas,
    required this.onBrushes,
    required this.onBrushSizeChanged,
    required this.onBrushSizeChangeEnd,
    required this.onColor,
    required this.onClose,
  });

  final bool eraserActive;
  final BrushPresetView? brush;
  final Color color;
  final VoidCallback onToggleEraser;
  final VoidCallback onFitCanvas;
  final VoidCallback onBrushes;
  final ValueChanged<double> onBrushSizeChanged;
  final ValueChanged<double> onBrushSizeChangeEnd;
  final VoidCallback onColor;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final currentBrush = brush;
    final brushSize = currentBrush?.size ?? 12;
    const minSize = 0.25;
    const maxSize = 128.0;
    double sizeForSliderValue(double value) =>
        (minSize * math.pow(maxSize / minSize, value)).toDouble();
    final sliderValue = (math.log(brushSize.clamp(minSize, maxSize) / minSize) /
            math.log(maxSize / minSize))
        .clamp(0.0, 1.0);
    return Center(
      child: Card(
        elevation: 8,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              IconButton.filledTonal(
                onPressed: onBrushes,
                tooltip: currentBrush?.name ?? 'Choose brush',
                icon: const Icon(Icons.brush),
              ),
              SizedBox(
                width: 220,
                child: Row(
                  children: [
                    const Text('Size'),
                    Expanded(
                      child: Slider(
                        value: sliderValue,
                        onChanged:
                            currentBrush == null
                                ? null
                                : (value) => onBrushSizeChanged(
                                  sizeForSliderValue(value),
                                ),
                        onChangeEnd:
                            currentBrush == null
                                ? null
                                : (value) => onBrushSizeChangeEnd(
                                  sizeForSliderValue(value),
                                ),
                      ),
                    ),
                    Text(brushSize.toStringAsFixed(1)),
                  ],
                ),
              ),
              IconButton.filledTonal(
                onPressed: onColor,
                tooltip: 'Brush color',
                icon: Icon(Icons.circle, color: color),
              ),
              IconButton.filledTonal(
                onPressed: onToggleEraser,
                tooltip: eraserActive ? 'Use brush' : 'Use eraser',
                icon: Icon(eraserActive ? Icons.brush : Icons.auto_fix_high),
              ),
              IconButton.filledTonal(
                onPressed: onFitCanvas,
                tooltip: 'Fit canvas',
                icon: const Icon(Icons.fit_screen),
              ),
              IconButton(
                onPressed: onClose,
                tooltip: 'Close quick menu',
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ColorWheel extends StatelessWidget {
  const _ColorWheel({required this.color, required this.onChanged});

  final Color color;
  final ValueChanged<HSVColor> onChanged;

  void _update(Offset local, Size size) {
    final center = size.center(Offset.zero);
    final delta = local - center;
    final radius = math.min(size.width, size.height) / 2;
    final saturation = (delta.distance / radius).clamp(0.0, 1.0);
    var hue = math.atan2(delta.dy, delta.dx) * 180 / math.pi + 90;
    if (hue < 0) hue += 360;
    onChanged(
      HSVColor.fromAHSV(
        color.a,
        hue % 360,
        saturation,
        HSVColor.fromColor(color).value,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Color wheel',
    hint: 'Drag to choose hue and saturation',
    child: GestureDetector(
      onPanDown:
          (details) => _update(
            details.localPosition,
            (context.findRenderObject()! as RenderBox).size,
          ),
      onPanUpdate:
          (details) => _update(
            details.localPosition,
            (context.findRenderObject()! as RenderBox).size,
          ),
      child: CustomPaint(
        size: const Size(180, 180),
        painter: _ColorWheelPainter(color),
      ),
    ),
  );
}

class _ColorWheelPainter extends CustomPainter {
  const _ColorWheelPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = math.min(size.width, size.height) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final hueShader = const SweepGradient(
      colors: [
        Colors.red,
        Colors.yellow,
        Colors.green,
        Colors.cyan,
        Colors.blue,
        Color(0xffff00ff),
        Colors.red,
      ],
    ).createShader(rect);
    canvas.drawCircle(center, radius, Paint()..shader = hueShader);
    final saturationShader = RadialGradient(
      colors: [Colors.white, Colors.white.withValues(alpha: 0)],
    ).createShader(rect);
    canvas.drawCircle(center, radius, Paint()..shader = saturationShader);
    final hsv = HSVColor.fromColor(color);
    final angle = (hsv.hue - 90) * math.pi / 180;
    final marker =
        center +
        Offset(math.cos(angle), math.sin(angle)) * radius * hsv.saturation;
    canvas.drawCircle(
      marker,
      8,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = hsv.value > 0.55 ? Colors.black : Colors.white,
    );
  }

  @override
  bool shouldRepaint(covariant _ColorWheelPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _ColorSquare extends StatelessWidget {
  const _ColorSquare({required this.color, required this.onChanged});

  final Color color;
  final ValueChanged<HSVColor> onChanged;

  void _update(Offset local, Size size) {
    final hsv = HSVColor.fromColor(color);
    onChanged(
      HSVColor.fromAHSV(
        hsv.alpha,
        hsv.hue,
        (local.dx / size.width).clamp(0.0, 1.0),
        (1 - local.dy / size.height).clamp(0.0, 1.0),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onPanDown: (details) {
      final box = context.findRenderObject()! as RenderBox;
      _update(details.localPosition, box.size);
    },
    onPanUpdate: (details) {
      final box = context.findRenderObject()! as RenderBox;
      _update(details.localPosition, box.size);
    },
    child: CustomPaint(
      size: const Size(220, 116),
      painter: _ColorSquarePainter(color),
    ),
  );
}

class _ColorSquarePainter extends CustomPainter {
  const _ColorSquarePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final hsv = HSVColor.fromColor(color);
    final hueColor = HSVColor.fromAHSV(1, hsv.hue, 1, 1).toColor();
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: [Colors.white, hueColor],
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00000000), Colors.black],
        ).createShader(rect),
    );
    final marker = Offset(
      hsv.saturation * size.width,
      (1 - hsv.value) * size.height,
    );
    canvas.drawCircle(
      marker,
      7,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = hsv.value > 0.55 ? Colors.black : Colors.white,
    );
  }

  @override
  bool shouldRepaint(covariant _ColorSquarePainter oldDelegate) =>
      oldDelegate.color != color;
}
