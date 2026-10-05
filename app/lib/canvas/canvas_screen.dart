import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
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
import '../layers/layer_panel_model.dart';
import '../tools/brush_library.dart';
import '../tools/illustration_tools.dart';
import 'canvas_diagnostic_recorder.dart';
import 'canvas_editor_auxiliary_overlays.dart';
import 'canvas_pointer_event_router.dart';
import 'canvas_pointer_pressure_policy.dart';
import 'flutter_pointer_stroke_coordinator.dart';
import 'canvas_input_coordinate_policy.dart';
import 'canvas_input_replacement_coordinator.dart';
import 'canvas_stroke_constraint_controller.dart';
import 'canvas_stroke_autosave_hold.dart';
import 'canvas_stroke_cancellation_coordinator.dart';
import 'canvas_touch_stroke_cancellation_coordinator.dart';
import 'canvas_stroke_completion_coordinator.dart';
import 'canvas_stroke_start_coordinator.dart';
import 'canvas_clipboard_palette.dart';
import 'canvas_color_sampling_coordinator.dart';
import 'canvas_brush_actions.dart';
import 'canvas_brush_color_actions.dart';
import 'canvas_gesture_coordinator.dart';
import 'canvas_history_actions.dart';
import 'canvas_brush_projection.dart';
import 'canvas_comic_panel_actions.dart';
import 'canvas_comic_workspace_notifications.dart';
import 'canvas_command_search_dialog.dart';
import 'canvas_macos_application_menu.dart';
import 'canvas_native_input_subscriptions.dart';
import 'canvas_compact_controls.dart';
import 'canvas_document_actions.dart';
import 'canvas_document_action_session.dart';
import 'canvas_dangling_stroke_finalizer.dart';
import 'canvas_draw_and_hold_coordinator.dart';
import 'canvas_live_stroke_preview_input.dart';
import 'canvas_live_preview_frame_diagnostics.dart';
import 'canvas_editor_action_router.dart';
import 'canvas_editor_shortcuts.dart';
import 'canvas_floating_panel_visibility.dart';
import 'canvas_dock_actions.dart';
import 'canvas_layer_actions.dart';
import 'canvas_layer_panel_content.dart';
import 'canvas_layer_projection.dart';
import 'canvas_layer_presentation_state.dart';
import 'canvas_desktop_workspace.dart';
import 'canvas_palette_content.dart';
import 'canvas_input_settings_controller.dart';
import 'canvas_preview_synchronization.dart';
import 'canvas_quick_controls.dart';
import 'canvas_status_widgets.dart';
import 'canvas_tile_synchronization.dart';
import 'canvas_top_bar.dart';
import 'canvas_tool_actions.dart';
import 'canvas_tool_event_coordinator.dart';
import 'canvas_viewport_surface.dart';
import 'canvas_stroke_preview_actions.dart';
import 'canvas_vector_actions.dart';
import 'canvas_workspace_layout_actions.dart';
import 'canvas_workspace_panel_sheets.dart';
import 'canvas_workspace_panel_actions.dart';
import 'canvas_workspace_panel_selection.dart';
import 'canvas_workspace_palette.dart';
import 'canvas_workspace_presentation_controller.dart';
import 'canvas_visible_tile_projection.dart';
import 'canvas_workspace_editor_actions.dart';
import 'canvas_workspace_dock_state.dart';
import 'canvas_workspace_overlays.dart';
import 'document_replacement_barrier.dart';
import 'canvas_viewport_controller.dart';
import 'canvas_workspace_widgets.dart';
import 'live_stroke_coordinator.dart';
import 'live_preview_controller.dart';
import 'mac_live_surface_controller.dart';
import 'native_pencil_stroke_coordinator.dart';
import 'native_pencil_input_coordinator.dart';
import 'native_pointer_stream.dart';
import 'performance_trace.dart';
import 'tile_cache.dart';
import 'workspace_dock_layout.dart';

export 'canvas_tool_event_coordinator.dart' show SelectionEdit;
import 'stroke_operation_queue.dart';

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
  if (state.hasUnsavedChanges) return 'Unsaved changes';
  return state.hasSavedCheckpoint ? 'Saved' : 'Not saved';
}

class CanvasScreen extends StatefulWidget
    implements CanvasDocumentActionSession {
  CanvasScreen({
    super.key,
    EngineApi? engine,
    this.autosave,
    this.autosaveState,
    this.documentPicker,
    this.targetPlatform,
    this.documentPickerTimeout = const Duration(minutes: 2),
    this.onNewDocument,
    this.onOpenDocument,
    this.activeDocumentPath,
    this.onDocumentSaved,
    this.onBeforeOpenStudioProject,
    this.onStudioProjectOpened,
    this.onDiscardRecovery,
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
    @visibleForTesting this.nativeCanvasDiagnosticEventsOverride,
    this.livePreviewControllerFactory,
  }) : engine = engine ?? InMemoryEngineApi();
  @override
  final EngineApi engine;

  /// Optional local checkpoint scheduler supplied by the document session.
  /// Flutter never copies document state into the autosave coordinator.
  @override
  final AutosaveCoordinator? autosave;

  /// Latest save/checkpoint projection supplied by the owning app session.
  @override
  final AutosaveState? autosaveState;

  /// Platform-owned path chooser for Open/Save/Export actions.
  @override
  final DocumentPicker? documentPicker;

  /// Optional platform override for deterministic widget tests.
  final TargetPlatform? targetPlatform;

  @override
  final Duration documentPickerTimeout;

  /// Parent callback used to replace the active Rust document with a new one.
  @override
  final Future<void> Function({
    required int widthPx,
    required int heightPx,
    required double dpi,
  })?
  onNewDocument;

  /// Parent callback used to replace the current Rust document handle.
  @override
  final Future<void> Function(String path)? onOpenDocument;

  /// Destination selected by the document session after the last successful
  /// Save As. A recovery checkpoint path is deliberately not exposed here.
  @override
  final String? activeDocumentPath;

  /// Lets the app session bind autosave and subsequent Save commands to the
  /// destination only after Rust and provider write-back both succeed.
  @override
  final Future<void> Function(String path)? onDocumentSaved;
  @override
  final Future<void> Function()? onBeforeOpenStudioProject;
  @override
  final Future<void> Function(String path)? onStudioProjectOpened;

  /// Removes the session recovery copy after an explicit Discard decision.
  @override
  final Future<void> Function()? onDiscardRecovery;
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
  final Stream<Map<String, Object?>>? nativeCanvasDiagnosticEventsOverride;

  @visibleForTesting
  final LivePreviewController Function(EngineApi engine)?
  livePreviewControllerFactory;

  @override
  State<CanvasScreen> createState() => _CanvasScreenState();
}

class _CanvasScreenState extends State<CanvasScreen>
    implements CanvasTileSynchronizationHost {
  static const Duration _tilePollInterval = Duration(milliseconds: 16);
  static const MethodChannel _nativeWindowCloseChannel = MethodChannel(
    'org.projectink.studio/window_close_v1',
  );
  bool _nativeWindowCloseHandlerInstalled = false;
  // Negative IDs cannot collide with persisted UUID-backed layer IDs. They
  // identify the authoritative Rust composite stream in the Flutter cache.

  final GlobalKey _canvasKey = GlobalKey();
  late final CanvasGestureCoordinator _gestureCoordinator =
      CanvasGestureCoordinator(
        CanvasGestureActionHost(
          defaults: () => _inputSettings.gestureDefaults,
          isMounted: () => mounted,
          dispatchEditorAction: _commands.dispatch,
          showClipboardPalette:
              () => unawaited(
                showCanvasClipboardPalette(
                  context: context,
                  isMounted: () => mounted,
                  activeColor: () => _activeColor,
                  applyPastedColor: _brushColorActions.applyPastedColor,
                ),
              ),
          sampleColor: (position) => unawaited(_sampleCanvasColor(position)),
          enableStraighten: _strokeConstraintController.enableStraighten,
          enableConstrain: _strokeConstraintController.enableConstrain,
        ),
      );
  late final CanvasPointerEventRouter _pointerEventRouter =
      CanvasPointerEventRouter(
        CanvasPointerEventRouterHost(
          documentReplacementActive: () => _documentReplacementInProgress,
          nativePencilContactActive:
              () => _nativePencilInputCoordinator.contactActive,
          recordTouchGesture: _recordTouchGesture,
          touchGestureCounts:
              () => (
                active: _gestureCoordinator.activePointerCount,
                tracked: _gestureCoordinator.trackedPointerCount,
              ),
          activeTool: () => _activeTool,
          colorSamplerArmed: () => _colorSamplerArmed,
          disarmColorSampler: () => _colorSamplerArmed = false,
          sampleCanvasColor: _sampleCanvasColor,
          handleToolEvent: _handleToolEventSafely,
          nativePointerEnabled: () => _nativePointerEnabled,
          strokeActive: () => _strokeActive,
          activeStrokeIsTouch: () => _activeStrokeIsTouch,
          singleFingerNavigation: () => _inputSettings.singleFingerNavigation,
          touchDrawingStrokeActive:
              () => _touchStrokeCancellationCoordinator.isActive,
          setTouchDrawingStrokeActive:
              _touchStrokeCancellationCoordinator.setActive,
          cancelTouchDrawingStroke: _touchStrokeCancellationCoordinator.cancel,
          beginStrokeAutosaveHold: _beginStrokeAutosaveHold,
          nextPointerSequence: _nextPointerSequence,
          prepareDrawingPosition:
              (event) => _applyStrokeConstraint(
                CanvasInputCoordinatePolicy.safeInput(
                  _canvasPosition(event.localPosition),
                ),
                hasDown: event is PointerDownEvent,
              ),
          updatePreview: _updateStrokePreview,
          pointerPressure: CanvasPointerPressurePolicy.normalize,
          schedulePreviewFrameDiagnostic: _scheduleLivePreviewFrameDiagnostic,
          enqueueStrokeWork: _enqueueStrokeWork,
          handleDrawingEvent: _handleDrawingEventSafely,
          previewPerformanceTimingEnabled:
              () => widget.onPerformanceSnapshot != null,
          nowMicros: () => _performanceTrace.nowMicros,
          markPreviewUpdated:
              ({required startedMicros}) => _performanceTrace.markPreviewUpdate(
                startedMicros: startedMicros,
              ),
          diagnostics: _canvasDiagnostics,
        ),
      );
  final Phase1PerformanceTrace _performanceTrace = Phase1PerformanceTrace();
  late final CanvasPreviewSynchronization _previewSynchronization =
      CanvasPreviewSynchronization();
  late final CanvasTileSynchronization _tileSynchronization =
      CanvasTileSynchronization(
        this,
        diagnostics: _canvasDiagnostics,
        previewSynchronization: _previewSynchronization,
        strokePreviewActions: _strokePreviewActions,
        effects: CanvasTileSynchronizationEffects(
          publishCanvasState: () => setState(() {}),
          markVisibleUpdate: _markVisibleTileUpdate,
        ),
      );
  TileCache get _tileBytes => _tileSynchronization.tileBytes;
  TileImageCache get _tileImages => _tileSynchronization.tileImages;
  int get _renderRevision => _tileSynchronization.renderRevision;
  ValueNotifier<LiveStrokePreview?> get _strokePreview =>
      _previewSynchronization.strokePreview;
  late final EditorCommandRegistry _commands = EditorCommandRegistry(
    _dispatchAction,
  );
  late final StrokeOperationQueue _strokeOperations = StrokeOperationQueue(
    onError: _recoverStrokeOperation,
  );
  late final CanvasStrokePreviewActions _strokePreviewActions =
      CanvasStrokePreviewActions(
        CanvasStrokePreviewHost(
          preview: () => _strokePreview.value,
          publishPreview: _setStrokePreview,
          documentWidth: () => widget.engine.documentInfo.widthPx,
          documentHeight: () => widget.engine.documentInfo.heightPx,
          isInsideDocument: _positionIsInsideDocument,
          boundPosition:
              (position) => CanvasInputCoordinatePolicy.boundToDocument(
                position,
                Size(
                  widget.engine.documentInfo.widthPx.toDouble(),
                  widget.engine.documentInfo.heightPx.toDouble(),
                ),
              ),
          color:
              () =>
                  _eraserActive || _transparentColorActive
                      ? Colors.white
                      : _activeColor,
          width: () => _brushLibrary.selected?.size ?? 8,
          pressureSize: () => _brushLibrary.selected?.pressureSize ?? 0,
          opacity: () => _brushLibrary.selected?.opacity ?? 1,
          pressureOpacity: () => _brushLibrary.selected?.pressureOpacity ?? 0,
          pressureCurvePoints:
              () => [
                for (final point
                    in _brushLibrary.selected?.pressureCurvePoints ??
                        const <BrushCurvePointView>[]) ...<double>[
                  point.x,
                  point.y,
                ],
              ],
          eraser: () => _eraserActive || _transparentColorActive,
          previewStoppedAtPageEdge: () => _previewStoppedAtPageEdge,
          setPreviewStoppedAtPageEdge:
              (value) => _previewStoppedAtPageEdge = value,
          strokeActive: () => _strokeActive,
          awaitingPreviewCommit: () => _awaitingPreviewCommit,
          setAwaitingPreviewCommit: (value) => _awaitingPreviewCommit = value,
          lastAcknowledgement: () => _lastPublishedPreviewAcknowledgement,
          clearLastAcknowledgement:
              () => _lastPublishedPreviewAcknowledgement = null,
          diagnostics: _canvasDiagnostics,
        ),
      );
  late final CanvasLiveStrokePreviewInput _liveStrokePreviewInput =
      CanvasLiveStrokePreviewInput(
        CanvasLiveStrokePreviewInputHost(
          livePreviewSurface: () => _livePreviewSurface,
          strokeActive: () => _strokeActive,
          beginPreview:
              (position, pressure, sequence) =>
                  _strokePreviewActions.beginStroke(
                    position: position,
                    pressure: pressure,
                    sourceSequence: sequence,
                  ),
          appendPreview:
              (position, pressure, sequence, isUp) =>
                  _strokePreviewActions.appendSample(
                    position: position,
                    pressure: pressure,
                    sourceSequence: sequence,
                    isUp: isUp,
                  ),
          recordDiagnostic: _canvasDiagnostics.record,
        ),
      );
  late final CanvasLivePreviewFrameDiagnostics _livePreviewFrameDiagnostics =
      CanvasLivePreviewFrameDiagnostics(
        isMounted: () => mounted,
        isDisposed: () => _disposed,
        snapshot: () {
          final preview = _strokePreview.value;
          if (preview == null) return null;
          final pendingStart =
              preview.confirmedThrough.clamp(0, preview.points.length).toInt();
          final pendingFirst =
              pendingStart < preview.points.length
                  ? preview.points[pendingStart]
                  : null;
          final pendingLast = preview.points.lastOrNull;
          return CanvasLivePreviewFrameSnapshot(
            pointCount: preview.points.length,
            confirmedThrough: preview.confirmedThrough,
            pendingSourceSequenceStart: pendingFirst?.sourceSequence,
            pendingSourceSequenceEnd: pendingLast?.sourceSequence,
            previewRevision: preview.revision,
            pendingPreviewChunkCount: _strokePreviewActions.pendingChunkCount(
              preview,
            ),
            oldestPendingPreviewChunkAgeUs: _strokePreviewActions
                .oldestChunkAgeMicros(preview),
            unbuiltPreviewPointCount: math.max(
              0,
              preview.points.length - preview.chunkedThrough,
            ),
            strokeWorkQueueDepth: _strokeOperations.pendingCount,
            nativePacketQueueDepth:
                _nativePencilInputCoordinator.pendingPacketCount,
            autosaveDeferredForStroke: _strokeAutosaveHoldActive,
            nativeTextureEnabled: _livePreviewSurface != null,
            nativeTextureReady:
                _livePreviewSurface?.textureId.value != null &&
                (_livePreviewSurface?.gpuFrameReady.value ?? false),
            packetMicros: _lastPacketMicros,
          );
        },
        record: _canvasDiagnostics.record,
        performanceTrace: _performanceTrace,
        performanceSnapshotCallback: () => widget.onPerformanceSnapshot,
      );
  late final CanvasDrawAndHoldCoordinator
  _drawAndHoldCoordinator = CanvasDrawAndHoldCoordinator(
    snapshot:
        () => CanvasDrawAndHoldSnapshot(
          strokeActive: _strokeActive,
          constraintActive: _strokeConstraintController.isActive,
          constraintStart: _strokeConstraintController.strokeStart,
          stylusPosition: _stylusLastPosition,
          inputAgeMicros:
              _nativePencilInputCoordinator.elapsedMicroseconds -
              _lastNativeInputArrivalUs,
          nativeDrainScheduled: _nativePencilInputCoordinator.drainScheduled,
          pendingNativePackets:
              _nativePencilInputCoordinator.pendingPacketCount,
          strokeWorkQueueDepth: _strokeOperations.pendingCount,
          gesture: _inputSettings.gestureDefaults.bindings['drawAndHold'],
        ),
    recordActivation:
        (event) =>
            _canvasDiagnostics.record('canvas.draw_and_hold_activated', event),
    dispatch: _gestureCoordinator.dispatchMapped,
  );
  final CanvasDiagnosticRecorder _canvasDiagnostics =
      CanvasDiagnosticRecorder.instance;
  late final CanvasNativeInputSubscriptions _nativeInputSubscriptions =
      CanvasNativeInputSubscriptions(
        onPointerPacket: _handleNativePacket,
        onPencilCommand: _handlePencilCommand,
        onCanvasDiagnostic:
            (event) => _canvasDiagnostics.record(
              'native.${event['kind'] ?? 'event'}',
              event,
            ),
        onChannelError: (channel, error, stack) {
          _canvasDiagnostics.recordError(channel, error, stack);
          final description = switch (channel) {
            'native_pointer_stream' => 'native pointer stream',
            'native_pointer_status' => 'native pointer status',
            'native_pencil_commands' => 'Pencil command stream',
            _ => null,
          };
          if (description != null) {
            debugPrint('Project Ink $description unavailable: $error');
          }
        },
      );
  late final CanvasStrokeAutosaveHold _strokeAutosaveHold =
      CanvasStrokeAutosaveHold(
        beginContinuousEdit: () => widget.autosave?.beginContinuousEdit(),
        endContinuousEdit: () => widget.autosave?.endContinuousEdit(),
        nativePacketQueueDepth:
            () => _nativePencilInputCoordinator.pendingPacketCount,
        strokeWorkQueueDepth: () => _strokeOperations.pendingCount,
        recordDiagnostic: _canvasDiagnostics.record,
      );
  late final CanvasStrokeCompletionCoordinator _strokeCompletionCoordinator =
      CanvasStrokeCompletionCoordinator(
        CanvasStrokeCompletionHost(
          resetActiveStroke: () {
            _strokeActive = false;
            _activeStrokeIsTouch = false;
            _strokeCaptureEndedAtBoundary = false;
          },
          clearNativePageContact:
              _nativePencilStrokeCoordinator.clearPageContact,
          setAwaitingPreviewCommit: (value) => _awaitingPreviewCommit = value,
          clearPreview: () {
            _strokePreviewActions.clear();
            _lastPublishedPreviewAcknowledgement = null;
            _setStrokePreview(null);
          },
          retirePreview:
              (source) => _retirePreviewIfAlreadyCpuCovered(source: source),
          recordFlutterCancellation: (pointerKind) {
            _canvasDiagnostics.record('canvas.stroke_cancelled', {
              'source': 'flutter_pointer',
              'pointerKind': pointerKind,
              'engineRevision': widget.engine.revision,
            });
          },
          finishConstraint: _finishConstraintStroke,
          cancelStylusHold: _drawAndHoldCoordinator.cancel,
          clearStylusPosition: () => _stylusLastPosition = null,
          finishAutosaveHold: _finishStrokeAutosaveHold,
          refreshLayerThumbnails: () => unawaited(_refreshLayerThumbnails()),
          refreshTiles: () => unawaited(_refreshTiles()),
        ),
      );
  late final CanvasStrokeCancellationCoordinator
  _strokeCancellationCoordinator = CanvasStrokeCancellationCoordinator(
    CanvasStrokeCancellationHost(
      strokeActive: () => _strokeActive,
      cancelEngineStroke: () => widget.engine.cancelStroke(),
      cancelPreviewSurface:
          () => unawaited(_livePreviewSurface?.cancelAllStrokes()),
      recordCancelFailure:
          (error, stack) => debugPrint(
            'Project Ink failed to cancel rejected stroke: $error\n$stack',
          ),
      resetActiveStroke: () {
        _strokeActive = false;
        _activeStrokeIsTouch = false;
        _strokeCaptureEndedAtBoundary = false;
      },
      clearNativePageContact: _nativePencilStrokeCoordinator.clearPageContact,
      setAwaitingPreviewCommit: (value) => _awaitingPreviewCommit = value,
      clearPreview: () {
        _strokePreviewActions.clear();
        _lastPublishedPreviewAcknowledgement = null;
        _setStrokePreview(null);
      },
      finishConstraint: _finishConstraintStroke,
      cancelStylusHold: _drawAndHoldCoordinator.cancel,
      clearStylusPosition: () => _stylusLastPosition = null,
      markDirty: () => widget.autosave?.markDirty(),
      finishAutosaveHold: _finishStrokeAutosaveHold,
    ),
  );
  late final CanvasTouchStrokeCancellationCoordinator
  _touchStrokeCancellationCoordinator =
      CanvasTouchStrokeCancellationCoordinator(
        CanvasTouchStrokeCancellationHost(
          enqueueStrokeWork: _enqueueStrokeWork,
          strokeActive: () => _strokeActive,
          activeStrokeIsTouch: () => _activeStrokeIsTouch,
          touchPointerCounts:
              () => (
                active: _gestureCoordinator.activePointerCount,
                tracked: _gestureCoordinator.trackedPointerCount,
              ),
          cancelRustStroke: () => widget.engine.cancelStroke(),
          engineRevision: () => widget.engine.revision,
          finishExternalCancellation:
              ({required reason}) => _strokeCancellationCoordinator
                  .finishExternalCancellation(reason: reason),
          refreshTiles: () => unawaited(_refreshTiles()),
          recordDiagnostic: _canvasDiagnostics.record,
        ),
      );
  int _sequence = 0;
  bool _strokeActive = false;
  bool _activeStrokeIsTouch = false;
  bool get _strokeAutosaveHoldActive => _strokeAutosaveHold.isActive;
  // After the crossing sample has been clipped by Rust, captured pointer
  // motion outside the artwork (and any re-entry) cannot alter the stroke.
  // Ignore those moves so a long off-canvas drag cannot backlog bridge work.
  bool _strokeCaptureEndedAtBoundary = false;
  late final NativePencilStrokeCoordinator _nativePencilStrokeCoordinator =
      NativePencilStrokeCoordinator(
        NativePencilStrokeHost(
          engine: () => widget.engine,
          strokeActive: () => _strokeActive,
          setStrokeActive: (value) => _strokeActive = value,
          captureEndedAtBoundary: () => _strokeCaptureEndedAtBoundary,
          setCaptureEndedAtBoundary:
              (value) => _strokeCaptureEndedAtBoundary = value,
          beginBrushStroke: _beginActiveBrushStroke,
          abortStroke: _abortStrokeAfterPacketError,
          eraserEnabled: () => _eraserActive || _transparentColorActive,
          stylusLastPosition: () => _stylusLastPosition,
          armDrawAndHold: _armDrawAndHold,
          livePreviewSurface: () => _livePreviewSurface,
          markDirty:
              ({restartTimer = true}) =>
                  widget.autosave?.markDirty(restartTimer: restartTimer),
          onStrokeFinished: ({
            required cancelled,
            required boundaryEnded,
            required reason,
          }) {
            _strokeCompletionCoordinator.finish(
              origin: CanvasStrokeCompletionOrigin.nativePencil,
              cancelled: cancelled,
              boundaryEnded: boundaryEnded,
              reason: reason,
            );
          },
          diagnostics: _canvasDiagnostics,
          performanceTrace: _performanceTrace,
          performanceSnapshotsEnabled: widget.onPerformanceSnapshot != null,
        ),
      );
  late final NativePencilInputCoordinator _nativePencilInputCoordinator =
      NativePencilInputCoordinator(
        NativePencilInputHost(
          documentReplacementInProgress: () => _documentReplacementInProgress,
          disposed: () => _disposed,
          activeTool: () => _activeTool,
          diagnostics: _canvasDiagnostics,
          discardConcurrentTouchGesture: _discardConcurrentTouchGesture,
          beginStrokeAutosaveHold: _beginStrokeAutosaveHold,
          markPacketReceived: (packet) {
            _lastPacketMicros =
                widget.onPerformanceSnapshot == null
                    ? null
                    : _performanceTrace.markPacketReceivedFromSource(
                      packet,
                      source: 'native_pencil',
                    );
          },
          transformPosition:
              (screenPosition, isDownSample) => _applyStrokeConstraint(
                CanvasInputCoordinatePolicy.safeInput(
                  _canvasPosition(screenPosition),
                ),
                hasDown: isDownSample,
              ),
          transformHoverPosition: _canvasPosition,
          updateHoverPosition: (value) {
            if (_pencilHoverPosition.value != value) {
              _pencilHoverPosition.value = value;
            }
          },
          nextSequence: _nextPointerSequence,
          appendPreviewBatch: _appendNativePreviewBatch,
          schedulePreviewFrameDiagnostic: _scheduleLivePreviewFrameDiagnostic,
          previewIndexForSequence:
              _strokePreviewActions.previewIndexForSourceSequence,
          strokeConstraintMode: () => _strokeConstraintController.mode,
          setStylusLastPosition: (value) => _stylusLastPosition = value,
          recordInputArrival: (value) => _lastNativeInputArrivalUs = value,
          armDrawAndHold: _armDrawAndHold,
          handleSerialPacket: _nativePencilStrokeCoordinator.handlePacket,
          abortStrokeAfterPacketError: _abortStrokeAfterPacketError,
          scheduleDrain:
              () =>
                  _enqueueStrokeWork(_nativePencilInputCoordinator.drainQueue),
          onQueueIdle: () {
            if (_strokeActive && _stylusLastPosition != null) {
              _armDrawAndHold(_stylusLastPosition!);
            }
          },
        ),
      );
  late final FlutterPointerStrokeCoordinator _flutterPointerStrokeCoordinator =
      FlutterPointerStrokeCoordinator(
        FlutterPointerStrokeHost(
          engine: () => widget.engine,
          strokeActive: () => _strokeActive,
          setStrokeActive: (value) => _strokeActive = value,
          activeStrokeIsTouch: () => _activeStrokeIsTouch,
          setActiveStrokeIsTouch: (value) => _activeStrokeIsTouch = value,
          captureEndedAtBoundary: () => _strokeCaptureEndedAtBoundary,
          setCaptureEndedAtBoundary:
              (value) => _strokeCaptureEndedAtBoundary = value,
          beginBrushStroke: _beginActiveBrushStroke,
          abortStroke: _abortStrokeAfterPacketError,
          isInsideDocument: _positionIsInsideDocument,
          isInsideViewport: _isInsideCanvasViewport,
          setStylusLastPosition: (value) => _stylusLastPosition = value,
          armDrawAndHold: _armDrawAndHold,
          cancelStylusHold: _drawAndHoldCoordinator.cancel,
          markPreviewStoppedAtPageEdge: () => _previewStoppedAtPageEdge = true,
          eraserEnabled: () => _eraserActive || _transparentColorActive,
          pointerPressure: CanvasPointerPressurePolicy.normalize,
          livePreviewSurface: () => _livePreviewSurface,
          markDirty:
              ({restartTimer = true}) =>
                  widget.autosave?.markDirty(restartTimer: restartTimer),
          onPacketReceived: (packet) {
            _lastPacketMicros =
                widget.onPerformanceSnapshot == null
                    ? null
                    : _performanceTrace.markPacketReceivedFromSource(
                      packet,
                      source: 'flutter_pointer',
                    );
          },
          onPacketRejected: (packet) {
            if (widget.onPerformanceSnapshot != null) {
              _performanceTrace.markPacketRejected(packet);
            }
          },
          onStrokeFinished: ({
            required cancelled,
            required boundaryEnded,
            required reason,
            required pointerKind,
          }) {
            _strokeCompletionCoordinator.finish(
              origin: CanvasStrokeCompletionOrigin.flutterPointer,
              cancelled: cancelled,
              boundaryEnded: boundaryEnded,
              reason: reason,
              pointerKind: pointerKind.name,
            );
          },
          diagnostics: _canvasDiagnostics,
        ),
      );
  bool _previewStoppedAtPageEdge = false;
  bool _disposed = false;
  bool get _nativePointerEnabled =>
      _nativeInputSubscriptions.nativePointerEnabled;
  bool _eraserActive = false;
  bool _transparentColorActive = false;
  bool _colorSamplerArmed = false;
  final _strokeConstraintController = CanvasStrokeConstraintController();
  Offset? _stylusLastPosition;
  final ValueNotifier<Offset?> _pencilHoverPosition = ValueNotifier<Offset?>(
    null,
  );
  int _lastNativeInputArrivalUs = 0;
  Color _activeColor = const Color(0xff202124);
  Color _subColor = Colors.white;
  final ValueNotifier<int> _colorPaletteRevision = ValueNotifier<int>(0);
  bool _activeColorInitialized = false;
  bool _hasUserSelectedColor = false;
  final CanvasInputSettingsController _inputSettings =
      CanvasInputSettingsController();
  bool _documentActionRunning = false;
  late final CanvasDanglingStrokeFinalizer _danglingStrokeFinalizer =
      CanvasDanglingStrokeFinalizer(
        CanvasDanglingStrokeFinalizerHost(
          drainAcceptedInput: () => _strokeOperations.idle,
          hasActiveStroke: () => _strokeActive,
          endRustStroke: () => widget.engine.endStroke(),
          resetLocalStroke: _clearFinishedStrokeState,
          markDirty: () => widget.autosave?.markDirty(),
          refreshLayerThumbnails: () => unawaited(_refreshLayerThumbnails()),
          refreshTiles: () => unawaited(_refreshTiles()),
        ),
      );
  late final DocumentReplacementBarrier _documentReplacementBarrier =
      DocumentReplacementBarrier(
        drainAcceptedInput: () => _strokeOperations.idle,
        cancelActiveStroke:
            () => _abortStrokeAfterPacketError(rethrowCancelFailure: true),
        flushRecovery: () async => await widget.autosave?.flush(),
        onChanged: (active) {
          if (mounted) setState(() {});
        },
      );
  late final CanvasInputReplacementCoordinator _inputReplacementCoordinator =
      CanvasInputReplacementCoordinator(
        CanvasInputReplacementHost(
          isMounted: () => mounted,
          prepareInput: _prepareInputForDocumentReplacement,
          barrier: _documentReplacementBarrier,
        ),
      );
  bool get _documentReplacementInProgress =>
      _documentReplacementBarrier.isActive;
  int _documentActionGeneration = 0;
  LivePreviewController? get _livePreviewSurface =>
      _previewSynchronization.surface;
  StrokeAcknowledgement? get _lastPublishedPreviewAcknowledgement =>
      _previewSynchronization.lastPublishedPreviewAcknowledgement;
  set _lastPublishedPreviewAcknowledgement(StrokeAcknowledgement? value) =>
      _previewSynchronization.lastPublishedPreviewAcknowledgement = value;
  bool get _awaitingPreviewCommit =>
      _previewSynchronization.awaitingPreviewCommit;
  set _awaitingPreviewCommit(bool value) =>
      _previewSynchronization.awaitingPreviewCommit = value;
  Future<void> get _pendingLiveSurfaceDisposal =>
      _previewSynchronization.pendingSurfaceDisposal;
  final _workspacePresentation = CanvasWorkspacePresentationController();
  bool _didInitializeTabletStudioDock = false;
  BigInt? _comicClipPanelId;
  int? _comicClipPageIndex;
  String? _temporaryDesktopPalette;
  late final CanvasWorkspaceDockState _workspaceDockState =
      CanvasWorkspaceDockState(_workspaceLayoutActions);
  bool get _leftHandedToolbar => _workspaceDockState.leftHandedToolbar;
  set _leftHandedToolbar(bool value) =>
      _workspaceDockState.leftHandedToolbar = value;
  bool get _workspaceDockCollapsed => _workspaceDockState.rightCollapsed;
  set _workspaceDockCollapsed(bool value) =>
      _workspaceDockState.setCollapsed(left: false, collapsed: value);
  bool get _workspaceLeftDockCollapsed => _workspaceDockState.leftCollapsed;
  set _workspaceLeftDockCollapsed(bool value) =>
      _workspaceDockState.setCollapsed(left: true, collapsed: value);
  String get _desktopDockTab => _workspaceDockState.rightTab;
  String get _leftDockTab => _workspaceDockState.leftTab;
  List<DockGroupLayout> get _leftDockGroups => _workspaceDockState.leftGroups;
  List<DockGroupLayout> get _rightDockGroups => _workspaceDockState.rightGroups;
  IllustrationTool _activeTool = IllustrationTool.brush;
  Rect? _selectionGeometry;
  IllustrationTool? _selectionGeometryTool;
  int _activeBrushId = 1;
  // The selected drawing color is workspace-wide. Rust applies it to a
  // temporary brush copy when each stroke begins.
  late final BrushLibraryModel _brushLibrary = BrushLibraryModel(const []);
  late final CanvasBrushActions _brushActions = CanvasBrushActions(
    CanvasBrushActionHost(
      engine: () => widget.engine,
      library: () => _brushLibrary,
      context: () => context,
      mounted: () => mounted,
      setState: setState,
      activeBrushId: () => _activeBrushId,
      setActiveBrushId: (value) => _activeBrushId = value,
      finishDanglingStrokeBeforeBrushEdit: _finishDanglingStrokeBeforeBrushEdit,
      endStaleStroke: () async {
        await widget.engine.endStroke();
        _clearFinishedStrokeState();
      },
      loadPhase2Projections: _loadPhase2Projections,
      markDirty: () => widget.autosave?.markDirty(),
      diagnostics: _canvasDiagnostics,
      showMessage: (message) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text(message)));
      },
    ),
  );
  late final CanvasColorSamplingCoordinator _colorSamplingCoordinator =
      CanvasColorSamplingCoordinator(
        CanvasColorSamplingHost(
          documentInfo: () => widget.engine.documentInfo,
          tiles: () => _tileBytes,
          documentPosition: _canvasPosition,
          applyActiveBrushColor: _brushActions.setActivePaintColor,
          isMounted: () => mounted,
          publishColor: _publishActiveColor,
        ),
      );
  late final CanvasBrushColorActions
  _brushColorActions = CanvasBrushColorActions(
    CanvasBrushColorActionsHost(
      isMounted: () => mounted,
      mainColor: () => _activeColor,
      subColor: () => _subColor,
      recentColors:
          () => widget.workspacePreferences?.recentColors ?? const <String>[],
      finishDanglingStroke: _finishDanglingStrokeBeforeBrushEdit,
      publishColors: ({mainColor, subColor}) {
        setState(() {
          if (mainColor != null) {
            _activeColor = mainColor;
            _activeColorInitialized = true;
            _hasUserSelectedColor = true;
          }
          if (subColor != null) _subColor = subColor;
        });
        _colorPaletteRevision.value++;
        if (mainColor != null || subColor != null) {
          _workspaceLayoutActions.persistPreferences(
            activeColorArgb: mainColor?.toARGB32(),
            subColorArgb: subColor?.toARGB32(),
          );
        }
      },
      persistRecentColors:
          (colors) =>
              _workspaceLayoutActions.persistPreferences(recentColors: colors),
      setRustActiveColor: _brushActions.setActivePaintColor,
    ),
  );
  late final CanvasBrushProjection _brushProjection = CanvasBrushProjection(
    CanvasBrushProjectionHost(
      engine: () => widget.engine,
      engineGeneration: () => _engineGeneration,
      mounted: () => mounted,
      library: () => _brushLibrary,
      activeBrushId: () => _activeBrushId,
      setActiveBrushId: (value) => _activeBrushId = value,
      setActiveColor: (value) {
        if (_activeColorInitialized) return;
        _activeColor = value;
        _activeColorInitialized = true;
        unawaited(_brushActions.setActivePaintColor(value));
      },
      refreshLayerProjection: _refreshLayerProjection,
    ),
  );
  late final ComicWorkspaceController _comicWorkspace =
      widget.comicWorkspaceController ??
      ComicWorkspaceController(
        onPersist: (bytes) => widget.engine.attachComicProject(bytes),
        readExisting: widget.engine.readComicProject,
        onPanelGeometryChanged: _comicPanelActions.syncPanelGeometry,
        onActivePageChanged: (handle) async {
          final engine = widget.engine;
          if (engine is FrbEngineApi) {
            if (_layerActions.hasActiveOpacityEdit) {
              _layerActions.finishActiveOpacityEdit(commit: true);
              await _layerActions.opacityQueue;
            }
            await _layerActions.panelStateQueue;
            await widget.autosave?.flush();
            if (_soloLayerId != null) {
              await engine.setLayerSolo(layerId: null);
              _soloLayerId = null;
            }
            await engine.rebindDocument(handle);
            await _restoreActiveBrushColor();
            if (mounted) {
              _layerPresentationState.resetPanelStateGeneration();
              _layerSelection.clear();
              setState(() {});
              await _loadPhase2Projections();
            }
          }
        },
        onProjectChanged: (project) async {
          final engine = widget.engine;
          if (engine is FrbEngineApi) {
            await _layerActions.panelStateQueue;
            await widget.autosave?.flush();
            if (_soloLayerId != null) {
              await engine.setLayerSolo(layerId: null);
              _soloLayerId = null;
            }
            engine.bindStudioProject(project);
            await _restoreActiveBrushColor();
            _layerPresentationState.resetPanelStateGeneration();
            _layerSelection.clear();
            await _loadPhase2Projections();
          }
        },
      );
  late final CanvasComicPanelActions _comicPanelActions =
      CanvasComicPanelActions(
        CanvasComicPanelActionHost(
          engine: () => widget.engine,
          mounted: () => mounted,
          activePageIndex: () => _comicWorkspace.activePageIndex,
          workspaceSnapshot: () => _comicWorkspace.snapshot,
          clippedPanelId: () => _comicClipPanelId,
          clippedPageIndex: () => _comicClipPageIndex,
          setClippedPanel: ({required pageIndex, required panelId}) {
            setState(() {
              _comicClipPageIndex = pageIndex;
              _comicClipPanelId = panelId;
              _selectionGeometry = null;
              _selectionGeometryTool = null;
            });
          },
          clearSelection: _clearSelection,
          loadLayerProjections: _refreshLayerProjection,
          selectLayer: _layerSelection.select,
          persistPanelState: _layerActions.queuePanelStatePersistence,
        ),
      );
  late final CanvasDocumentActions _documentActions = CanvasDocumentActions(
    CanvasDocumentActionHost(
      session: () => widget,
      context: () => context,
      mounted: () => mounted,
      setState: setState,
      setActiveBrushId: (value) => _activeBrushId = value,
      brushLibrary: () => _brushLibrary,
      comicWorkspace: () => _comicWorkspace,
      documentActionGeneration: () => _documentActionGeneration,
      setDocumentActionGeneration: (value) => _documentActionGeneration = value,
      documentActionRunning: () => _documentActionRunning,
      setDocumentActionRunning: (value) => _documentActionRunning = value,
      loadPhase2Projections: _loadPhase2Projections,
      runWithDocumentReplacementBarrier: _inputReplacementCoordinator.run,
      respondToNativeWindowClose:
          (method) => _nativeWindowCloseChannel.invokeMethod<void>(method),
      showNativeWindowCloseError: (error) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not close safely: $error')),
        );
      },
    ),
  );
  late final CanvasStrokeStartCoordinator
  _strokeStartCoordinator = CanvasStrokeStartCoordinator(
    CanvasStrokeStartHost(
      beginAutosaveHold: _beginStrokeAutosaveHold,
      finishAutosaveHold: _finishStrokeAutosaveHold,
      persistPendingQuickSize: _brushActions.persistPendingQuickSize,
      activeBrushId: () => _activeBrushId,
      pendingBrushEditForBrush: _brushActions.pendingEditForBrush,
      primaryLayerId: () => _layerSelection.primaryId,
      layers: () => _layers,
      layerEffectivelyVisible: _toolActions.layerEffectivelyVisible,
      showInvalidTarget: (target, {required effectivelyVisible}) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              target == null
                  ? 'Choose a layer before drawing.'
                  : !effectivelyVisible
                  ? '“${target.name}” or one of its groups is hidden. Show it before drawing.'
                  : '“${target.name}” cannot receive brush strokes.',
            ),
          ),
        );
      },
      selectedBrush: () => _brushLibrary.selected,
      recordStrokeBegin: (brushId, selectedBrush) {
        _canvasDiagnostics.record('brush.stroke_begin', {
          'activeBrushId': brushId,
          'selectedBrushId': selectedBrush?.id,
          'selectedBrushSizePx': selectedBrush?.size,
          'selectedBrushMatchesActive': selectedBrush?.id == brushId,
        });
      },
      beginBrushStrokeOnLayer:
          (brushId, targetLayerId) =>
              widget.engine.beginBrushStrokeOnLayer(brushId, targetLayerId),
    ),
  );
  late final CanvasHistoryActions _historyActions = CanvasHistoryActions(
    CanvasHistoryActionHost(
      engine: () => widget.engine,
      waitForStrokeOperations: () => _strokeOperations.idle,
      markDirty: () => widget.autosave?.markDirty(),
      refreshLayerProjection: _refreshLayerProjection,
      refreshTiles: () => _refreshTiles(),
      loadPhase2Projections: _loadPhase2Projections,
      loadVectorSelection: _vectorActions.loadForSelection,
      mounted: () => mounted,
      setState: setState,
    ),
  );
  late final CanvasToolActions _toolActions = CanvasToolActions(
    CanvasToolActionHost(
      engine: () => widget.engine,
      context: () => context,
      mounted: () => mounted,
      layers: () => _layers,
      primaryLayerId: () => _layerSelection.primaryId,
      activeTool: () => _activeTool,
      setSelectionGeometryTool:
          (tool) => setState(() => _selectionGeometryTool = tool),
      markDirty: () => widget.autosave?.markDirty(),
      refreshTiles: _refreshTiles,
    ),
  );
  late final CanvasWorkspaceLayoutActions _workspaceLayoutActions =
      CanvasWorkspaceLayoutActions(
        CanvasWorkspaceLayoutHost(
          preferences:
              () => widget.workspacePreferences ?? const WorkspacePreferences(),
          onPreferencesChanged: () => widget.onWorkspacePreferencesChanged,
        ),
      );
  late final CanvasWorkspaceEditorActions _workspaceEditorActions =
      CanvasWorkspaceEditorActions(
        CanvasWorkspaceEditorHost(
          context: () => context,
          mounted: () => mounted,
          preferences:
              () => widget.workspacePreferences ?? const WorkspacePreferences(),
          layoutActions: _workspaceLayoutActions,
          rightDockWidth: () => _workspaceDockState.rightWidth,
          leftDockWidth: () => _workspaceDockState.leftWidth,
          leftDockCollapsed: () => _workspaceDockState.leftCollapsed,
          rightDockGroups: () => _workspaceDockState.rightGroups,
          leftDockGroups: () => _workspaceDockState.leftGroups,
          rightDockTab: () => _workspaceDockState.rightTab,
          selectWorkspace: _selectWorkspace,
          applyWorkspaceLayout: (layout) {
            setState(() => _workspaceDockState.applyLayout(layout));
          },
        ),
      );
  late final CanvasDockActions _dockActions = CanvasDockActions(
    CanvasDockActionHost(
      preferences:
          () => widget.workspacePreferences ?? const WorkspacePreferences(),
      layoutActions: _workspaceLayoutActions,
      groups: _workspaceDockState.groups,
      setGroups: _workspaceDockState.setGroups,
      setTab: _workspaceDockState.setTab,
      dockWidth: _workspaceDockState.width,
      dockCollapsed: _workspaceDockState.collapsed,
      setDockWidth: _workspaceDockState.setWidth,
      setDockCollapsed: _workspaceDockState.setCollapsed,
      clearTemporaryPalette: () => _temporaryDesktopPalette = null,
      updateState: (update) => setState(update),
    ),
  );
  late final CanvasWorkspacePanelActions
  _workspacePanelActions = CanvasWorkspacePanelActions(
    CanvasWorkspacePanelActionHost(
      setFloatingPanels:
          (visibility) => setState(
            () => _workspacePresentation.setFloatingPanels(visibility),
          ),
      selectDesktopDock: (side, groupIndex, panel, floatingPanels) {
        final isLeft = side == CanvasDockSide.left;
        setState(() {
          _workspacePresentation.setFloatingPanels(floatingPanels);
          _dockActions.selectPaletteState(
            left: isLeft,
            groupIndex: groupIndex,
            tab: panel,
          );
          if (isLeft) {
            _workspaceLeftDockCollapsed = false;
          } else {
            _workspaceDockCollapsed = false;
          }
          _temporaryDesktopPalette = null;
        });
        _dockActions.persistGroups(left: isLeft);
      },
      selectTemporaryPalette:
          (palette) => setState(() => _temporaryDesktopPalette = palette),
      rememberTabletPalette: _workspacePresentation.rememberTabletPalette,
      persistLastDock:
          (panel) =>
              _workspaceLayoutActions.persistPreferences(lastDock: panel),
      showQuickAccessSheet: (sheetContext) {
        unawaited(
          showCanvasQuickAccessSheet(
            context: sheetContext,
            sets:
                widget.workspacePreferences?.quickAccessSets ??
                defaultQuickAccessSets,
            activeSetId:
                widget.workspacePreferences?.activeQuickAccessSetId ??
                'default',
            onAction: _commands.dispatch,
            onChanged: (sets, activeSetId) {
              _workspaceLayoutActions.persistPreferences(
                quickAccessSets: sets,
                activeQuickAccessSetId: activeSetId,
              );
            },
          ),
        );
      },
      showHistorySheet: (sheetContext) {
        unawaited(
          showCanvasHistorySheet(
            context: sheetContext,
            engine: widget.engine,
            revisionToken: math.max(_renderRevision, widget.engine.revision),
            onNavigate: _historyActions.navigateHistory,
          ),
        );
      },
      showColorSheet: (sheetContext) {
        unawaited(
          showCanvasColorPaletteSheet(
            context: sheetContext,
            child: ValueListenableBuilder<int>(
              valueListenable: _colorPaletteRevision,
              builder: (context, _, _) => _buildDockPalette('color', context),
            ),
          ),
        );
      },
    ),
  );
  late final CanvasEditorActionRouter
  _editorActionRouter = CanvasEditorActionRouter(
    CanvasEditorActionRouterHost(
      isMounted: () => mounted,
      dispatchDocumentAction: _documentActions.dispatchEditorAction,
      dispatchHistoryAction: _historyActions.dispatchEditorAction,
      dispatchToolAction: _toolEventCoordinator.dispatchEditorAction,
      dispatchBrushColorAction: _brushColorActions.dispatchEditorAction,
      viewportAction: _viewportController.editorActionHandler,
      applyStateAction: setState,
      selectPanel: (panel) => _selectPanel(panel, context),
      toggleEraser: () => setState(() => _eraserActive = !_eraserActive),
      fitCanvas: _fitCanvas,
      toggleInterface: _toggleFocusMode,
      showColorPicker:
          () => unawaited(_brushColorActions.showColorPicker(context: context)),
      armColorSampler: () => setState(() => _colorSamplerArmed = true),
      toggleQuickMenu: () => setState(_workspacePresentation.toggleQuickMenu),
      showCommandSearch:
          () => unawaited(
            showCanvasCommandSearch(
              context: context,
              isMounted: () => mounted,
              dispatch: _commands.dispatch,
            ),
          ),
    ),
  );
  final CanvasLayerPresentationState _layerPresentationState =
      CanvasLayerPresentationState();
  LayerSelectionModel get _layerSelection => _layerPresentationState.selection;
  List<LayerView> get _layers => _layerPresentationState.layers;
  set _layers(List<LayerView> value) => _layerPresentationState.layers = value;
  int? get _soloLayerId => _layerPresentationState.soloLayerId;
  set _soloLayerId(int? value) => _layerPresentationState.soloLayerId = value;
  final CanvasLayerProjectionService _layerProjectionService =
      CanvasLayerProjectionService();
  late final CanvasVectorActions _vectorActions = CanvasVectorActions(
    CanvasVectorActionHost(
      engine: () => widget.engine,
      context: () => context,
      mounted: () => mounted,
      engineGeneration: () => _engineGeneration,
      selectedLayerId: () => _selectedVectorLayerId,
      onStrokesChanged: () => setState(() {}),
      markDirty: () => widget.autosave?.markDirty(),
      refreshTiles: _refreshTiles,
    ),
  );
  late final CanvasToolEventCoordinator _toolEventCoordinator =
      CanvasToolEventCoordinator(
        CanvasToolEventHost(
          engine: () => widget.engine,
          mounted: () => mounted,
          updateState: (update) => setState(update),
          activeTool: () => _activeTool,
          canvasPosition: _canvasPosition,
          pointerPressure: CanvasPointerPressurePolicy.normalize,
          setSelectionGeometry: (value) => _selectionGeometry = value,
          setSelectionGeometryTool: (value) => _selectionGeometryTool = value,
          vectorOperations: _vectorActions,
          toolActions: _toolActions,
          markDirty:
              ({restartTimer = true}) =>
                  widget.autosave?.markDirty(restartTimer: restartTimer),
          onSelectionCleared: () {
            setState(() {
              _selectionGeometry = null;
              _selectionGeometryTool = null;
              _comicClipPanelId = null;
              _comicClipPageIndex = null;
            });
          },
        ),
      );
  late final CanvasLayerActions _layerActions = CanvasLayerActions(
    CanvasLayerActionHost(
      engine: () => widget.engine,
      mounted: () => mounted,
      setState: setState,
      layers: () => _layers,
      selection: () => _layerSelection,
      engineGeneration: () => _engineGeneration,
      loadPhase2Projections: _refreshLayerProjection,
      refreshTiles: _refreshTiles,
      markDirty: () => widget.autosave?.markDirty(),
      soloLayerId: () => _soloLayerId,
      setSoloLayerId: (value) => _soloLayerId = value,
      selectLayerContents:
          () => setState(() {
            _selectionGeometry = null;
            _selectionGeometryTool = IllustrationTool.layerOpacitySelect;
          }),
      showMessage: (message) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      },
    ),
  );
  late final CanvasComicWorkspaceNotifications _comicWorkspaceNotifications =
      CanvasComicWorkspaceNotifications(
        source: _comicWorkspace,
        isMounted: () => mounted,
        shouldClearSelection:
            () =>
                _comicClipPanelId != null &&
                _comicWorkspace.pagePreviewIndex != _comicClipPageIndex,
        clearSelection: _clearSelection,
        rebuild: () => setState(() {}),
        followsDocumentType:
            () => widget.workspacePreferences?.followDocumentType == true,
        workspaceForDocument:
            () => _comicWorkspace.snapshot == null ? 'illustration' : 'comic',
        selectWorkspace:
            (workspaceId) => _selectWorkspace(workspaceId, manual: false),
      );
  int _engineGeneration = 0;
  int? _lastPacketMicros;
  final _viewportController = CanvasViewportController();

  @override
  bool get disposed => _disposed;
  @override
  bool get isMounted => mounted;
  @override
  CanvasTileSynchronizationSession captureSession() =>
      CanvasTileSynchronizationSession(
        engine: widget.engine,
        generation: _engineGeneration,
      );
  @override
  bool isSessionCurrent(CanvasTileSynchronizationSession session) =>
      !_disposed &&
      session.engine == widget.engine &&
      session.generation == _engineGeneration;
  @override
  CanvasTileSynchronizationSnapshot captureSnapshot() =>
      CanvasTileSynchronizationSnapshot(
        lastPacketMicros: _lastPacketMicros,
        visibleRasterLayerIds: _layers
            .where((layer) => layer.visible)
            .map((layer) => layer.id),
        strokeWorkQueueDepth: _strokeOperations.pendingCount,
        pendingNativePacketCount:
            _nativePencilInputCoordinator.pendingPacketCount,
      );
  @override
  bool get strokeActive => _strokeActive;
  void _markVisibleTileUpdate({
    required int packetMicros,
    required Duration tileDecode,
    required int dirtyTiles,
  }) {
    _performanceTrace.markVisibleUpdate(
      packetMicros: packetMicros,
      tileDecode: tileDecode,
      dirtyTiles: dirtyTiles,
    );
    widget.onPerformanceSnapshot?.call(_performanceTrace.snapshot());
  }

  Future<void> _refreshTiles({bool initial = false}) =>
      _tileSynchronization.refreshTiles(initial: initial);

  void _configureLivePreviewSurface() {
    _previewSynchronization.configureSurface(
      engine: widget.engine,
      targetPlatform: widget.targetPlatform,
      factory: widget.livePreviewControllerFactory,
      diagnostics: _canvasDiagnostics,
      performanceTrace: _performanceTrace,
      hasPerformanceSnapshot: widget.onPerformanceSnapshot != null,
      disableIpadDabRenderer: _disableIpadDabRenderer,
    );
  }

  void _setStrokePreview(LiveStrokePreview? next) {
    _previewSynchronization.setStrokePreview(next);
  }

  void _scheduleLiveViewportSync() {
    _previewSynchronization.scheduleViewportSync(
      isActive: () => mounted && !_disposed,
      viewport:
          () => CanvasLiveViewport(
            canvasKey: _canvasKey,
            devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
            pan: _viewportController.viewport.pan,
            scale: _viewportController.viewport.scale,
            rotation: _viewportController.viewport.rotation,
            mirrored: _viewportController.mirrored,
            documentWidth: widget.engine.documentInfo.widthPx,
            documentHeight: widget.engine.documentInfo.heightPx,
          ),
    );
  }

  @override
  void initState() {
    super.initState();
    final preferences = widget.workspacePreferences;
    if (preferences?.activeColorArgb case final activeColor?) {
      _activeColor = Color(activeColor);
      _activeColorInitialized = true;
      _hasUserSelectedColor = true;
    }
    if (preferences?.subColorArgb case final subColor?) {
      _subColor = Color(subColor);
    }
    if (_activeColorInitialized) unawaited(_restoreActiveBrushColor());
    if (!kIsWeb &&
        (widget.targetPlatform ?? defaultTargetPlatform) ==
            TargetPlatform.macOS) {
      _nativeWindowCloseHandlerInstalled = true;
      _nativeWindowCloseChannel.setMethodCallHandler(
        _handleNativeWindowCloseCall,
      );
    }
    _configureLivePreviewSurface();
    _canvasDiagnostics.record('canvas.session_started', <String, Object?>{
      'platform': (widget.targetPlatform ?? defaultTargetPlatform).name,
      'documentWidth': widget.engine.documentInfo.widthPx,
      'documentHeight': widget.engine.documentInfo.heightPx,
      'engineRevision': widget.engine.revision,
      'activeTool': _activeTool.name,
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
    });
    _workspaceDockState.initialize(
      preferences: preferences,
      fallbackRightWidth: widget.workspaceDockWidth,
    );
    _comicWorkspaceNotifications.start();
    _tileSynchronization.startPolling(interval: _tilePollInterval);
    final platform = widget.targetPlatform ?? defaultTargetPlatform;
    // Every desktop and mobile target has a native adapter. Keep the generic
    // Flutter stylus path enabled until the platform EventChannel announces
    // readiness, then route stylus packets through the native adapter exactly
    // once. Pencil command events are only registered on platforms that
    // provide them; Windows/Linux still use their pointer status channel.
    final supportsNativePointer =
        platform == TargetPlatform.iOS ||
        platform == TargetPlatform.android ||
        platform == TargetPlatform.macOS ||
        platform == TargetPlatform.windows ||
        platform == TargetPlatform.linux;
    final supportsPencilCommands =
        platform == TargetPlatform.iOS ||
        platform == TargetPlatform.android ||
        platform == TargetPlatform.macOS;
    _nativeInputSubscriptions.start(
      canvasDiagnostics:
          platform == TargetPlatform.iOS
              ? (widget.nativeCanvasDiagnosticEventsOverride ??
                  nativeCanvasDiagnosticEvents())
              : null,
      pointerPackets:
          supportsNativePointer
              ? (widget.nativePointerPacketsOverride ?? nativePointerPackets())
              : null,
      pointerReadiness:
          supportsNativePointer
              ? (widget.nativePointerReadyOverride ?? nativePointerReady())
              : null,
      pencilCommands:
          supportsPencilCommands
              ? (widget.nativePencilCommandsOverride ?? nativePencilCommands())
              : null,
    );
    // Layer targeting is core document state. Load it independently from
    // brush-library preferences so a slow preferences plugin cannot leave
    // the canvas with no valid paint target.
    unawaited(_refreshLayerProjection());
    unawaited(_loadPhase2Projections());
    unawaited(_refreshTiles(initial: true));
  }

  Future<Object?> _handleNativeWindowCloseCall(MethodCall call) =>
      _documentActions.handleNativeWindowCloseRequest(call.method);

  Future<void> _loadPhase2Projections() => _brushProjection.load();

  Future<void> _refreshLayerProjection() async {
    final generation = _engineGeneration;
    final engine = widget.engine;
    try {
      final projection = await _layerProjectionService.load(
        engine: engine,
        engineGeneration: generation,
        isCurrent:
            () =>
                mounted &&
                generation == _engineGeneration &&
                engine == widget.engine,
        includePanelState: _layerPresentationState.needsPanelStateForGeneration(
          generation,
        ),
      );
      if (projection == null || !mounted) return;
      final application = _layerPresentationState.applyProjection(
        projection,
        engineGeneration: generation,
      );
      if (application == null) return;
      setState(() {});
      if (application.panelStateNeedsRepair) {
        _layerActions.queuePanelStatePersistence();
      }
      await _vectorActions.loadForSelection();
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
    _workspacePresentation.setFloatingPanels(
      _workspacePresentation.floatingPanels.setVisible(
        CanvasFloatingPanel.layers,
        widget.workspacePreferences?.tabletMode == TabletWorkspaceMode.studio,
      ),
    );
  }

  @override
  void didUpdateWidget(covariant CanvasScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    var oldSurfaceDisposal = _pendingLiveSurfaceDisposal;
    if (oldWidget.engine != widget.engine ||
        oldWidget.targetPlatform != widget.targetPlatform) {
      if (oldWidget.engine != widget.engine) {
        if (_soloLayerId != null) {
          unawaited(_layerActions.clearLayerSolo(oldWidget.engine));
        }
        _soloLayerId = null;
      }
      oldSurfaceDisposal = _previewSynchronization.detachSurface();
      unawaited(oldSurfaceDisposal);
      _configureLivePreviewSurface();
      if (oldWidget.engine == widget.engine) {
        _tileSynchronization.clearPendingLiveAcknowledgements();
      }
    }
    if (oldWidget.workspacePreferences != widget.workspacePreferences) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _colorPaletteRevision.value++;
      });
      _workspaceDockState.updatePreferences(
        previous: oldWidget.workspacePreferences,
        current: widget.workspacePreferences,
      );
      final savedColor = widget.workspacePreferences?.activeColorArgb;
      if (savedColor != null &&
          savedColor != oldWidget.workspacePreferences?.activeColorArgb &&
          !_hasUserSelectedColor) {
        _activeColor = Color(savedColor);
        _activeColorInitialized = true;
        unawaited(_restoreActiveBrushColor());
      }
    }
    if (oldWidget.engine != widget.engine) {
      if (_layerActions.hasActiveOpacityEdit) {
        _layerActions.finishActiveOpacityEdit(commit: false);
      }
      _brushActions.cancelDraftsForEngine(oldWidget.engine);
      _engineGeneration++;
      _layerPresentationState.resetPanelStateGeneration();
      _layerSelection.clear();
      widget.onEngineReplaced?.call(oldWidget.engine, oldSurfaceDisposal);
      _nativePencilInputCoordinator.clearQueuedPackets();
      _finishStrokeAutosaveHold(reason: 'engine_replaced');
      _strokeActive = false;
      _activeStrokeIsTouch = false;
      _tileSynchronization.resetForEngineReplacement();
      _layerProjectionService.clear();
      _setStrokePreview(null);
      _previewSynchronization.resetStrokeCommitState();
      _layerSelection.clear();
      _layers = const [];
      _vectorActions.clearStrokes();
      _selectionGeometry = null;
      _selectionGeometryTool = null;
      if (_activeColorInitialized) unawaited(_restoreActiveBrushColor());
      _toolEventCoordinator.resetTransientState();
      unawaited(_comicWorkspace.republishEngineBindings());
      unawaited(_loadPhase2Projections());
      unawaited(_refreshTiles(initial: true));
    }
  }

  Future<void> _customizeCommandBar() =>
      _workspaceEditorActions.customizeCommandBar();

  void _selectWorkspace(String workspaceId, {bool manual = true}) {
    final dock = _workspaceLayoutActions.selectWorkspace(
      workspaceId,
      manual: manual,
    );
    setState(() => _workspaceDockState.applySelection(dock));
  }

  void _setFollowDocumentType(bool enabled) {
    final selection = _workspaceLayoutActions.setFollowDocumentType(
      enabled: enabled,
      documentWorkspaceId:
          _comicWorkspace.snapshot == null ? 'illustration' : 'comic',
    );
    if (selection == null) return;
    setState(() => _workspaceDockState.applySelection(selection));
  }

  Future<void> _renameWorkspace(String id) =>
      _workspaceEditorActions.renameWorkspace(id);

  Future<void> _deleteWorkspace(String id) =>
      _workspaceEditorActions.deleteWorkspace(id);

  Future<void> _saveWorkspaceAs() => _workspaceEditorActions.saveWorkspaceAs();

  Future<void> _resetBuiltInWorkspace(String workspaceId) =>
      _workspaceEditorActions.resetBuiltInWorkspace(workspaceId);

  void _toggleTabletWorkspaceMode() {
    final current =
        widget.workspacePreferences?.tabletMode ?? TabletWorkspaceMode.simple;
    late final TabletWorkspaceMode nextMode;
    setState(() => nextMode = _workspacePresentation.toggleTabletMode(current));
    _workspaceLayoutActions.persistPreferences(tabletMode: nextMode);
  }

  void _setTabletWorkspaceMode(TabletWorkspaceMode mode) {
    final current =
        widget.workspacePreferences?.tabletMode ?? TabletWorkspaceMode.simple;
    if (mode == current) return;
    _toggleTabletWorkspaceMode();
  }

  void _toggleFocusMode() {
    if (_strokeActive) return;
    setState(_workspacePresentation.toggleFocusMode);
  }

  void _exitFocusMode() {
    if (!_workspacePresentation.interfaceHidden) return;
    setState(_workspacePresentation.exitFocusMode);
  }

  Future<void> _showFocusQuickControls() async {
    final brush = _brushLibrary.selected;
    if (brush == null) return;
    await showCanvasFocusQuickControlsSheet(
      context: context,
      brush: brush,
      color: _activeColor,
      onUndo: () => _commands.dispatch(EditorActionId.undo),
      onRedo: () => _commands.dispatch(EditorActionId.redo),
      onBrushes: () {
        _exitFocusMode();
        _selectPanel('brushes', context);
      },
      onColor: () {
        _exitFocusMode();
        _selectPanel('color', context);
      },
      onChanged: _brushActions.updateBrushDraft,
      onSizeChangeEnd: _brushActions.persistBrushSize,
      onOpacityChangeEnd: _brushActions.persistSelectedBrushSettings,
    );
  }

  void _toggleTransparentColor() {
    setState(() => _transparentColorActive = !_transparentColorActive);
    _colorPaletteRevision.value++;
  }

  void _publishActiveColor(Color color) {
    if (!mounted) return;
    setState(() {
      _activeColor = color;
      _activeColorInitialized = true;
      _hasUserSelectedColor = true;
    });
    _colorPaletteRevision.value++;
    _workspaceLayoutActions.persistPreferences(
      activeColorArgb: color.toARGB32(),
    );
  }

  Future<void> _restoreActiveBrushColor() async {
    if (!mounted || !_activeColorInitialized) return;
    await _brushActions.setActivePaintColor(_activeColor);
  }

  @override
  void dispose() {
    if (_nativeWindowCloseHandlerInstalled) {
      _nativeWindowCloseChannel.setMethodCallHandler(null);
    }
    if (_layerActions.hasActiveOpacityEdit) {
      _layerActions.finishActiveOpacityEdit(commit: false);
    }
    _finishStrokeAutosaveHold(reason: 'canvas_disposed');
    _disposed = true;
    _pencilHoverPosition.dispose();
    _colorPaletteRevision.dispose();
    _tileSynchronization.dispose();
    _canvasDiagnostics.record('canvas.session_ended', <String, Object?>{
      'engineRevision': widget.engine.revision,
    });
    _brushActions.dispose(widget.engine);
    _previewSynchronization.dispose();
    _livePreviewFrameDiagnostics.dispose();
    _gestureCoordinator.dispose();
    _drawAndHoldCoordinator.dispose();
    unawaited(_nativeInputSubscriptions.dispose());
    _comicWorkspaceNotifications.dispose();
    _comicWorkspace.dispose();
    super.dispose();
  }

  void _handlePointer(PointerEvent event) => _pointerEventRouter.handle(event);

  /// Submits pointer operations to the ordered bridge-work queue.
  void _enqueueStrokeWork(Future<void> Function() operation) {
    _strokeOperations.enqueue(operation);
  }

  Future<void> _recoverStrokeOperation(Object error, StackTrace stack) async {
    debugPrint('Project Ink stroke queue recovered from error: $error\n$stack');
    try {
      await _abortStrokeAfterPacketError();
    } catch (recoveryError, recoveryStack) {
      // Keep the serial queue usable even if recovery encounters a disposed
      // platform handle. The next pointer-down can start a fresh transaction.
      debugPrint(
        'Project Ink stroke queue recovery failed: '
        '$recoveryError\n$recoveryStack',
      );
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

  Future<void> _handleToolEventSafely(PointerEvent event) =>
      _toolEventCoordinator.handleSafely(event);

  Future<void> _clearSelection() => _toolEventCoordinator.clearSelection();

  Future<void> _drawInsideComicPanel(
    int pageIndex,
    rust.ComicPanelPreviewView panel,
  ) => _comicPanelActions.drawInsidePanel(pageIndex, panel);

  void _selectTool(IllustrationTool tool) {
    if (!mounted) return;
    _toolEventCoordinator.resetTransientState();
    setState(() {
      _activeTool = tool;
      _workspacePresentation.setFloatingPanels(
        _workspacePresentation.floatingPanels.setVisible(
          CanvasFloatingPanel.tools,
          true,
        ),
      );
      if (tool == IllustrationTool.eraser) _eraserActive = true;
      if (tool == IllustrationTool.brush) _eraserActive = false;
    });
  }

  int? get _selectedVectorLayerId {
    final id = _layerSelection.primaryId;
    final layer =
        id == null
            ? null
            : _layers.where((value) => value.id == id).firstOrNull;
    return layer?.kind == LayerKind.vectorInk &&
            _toolActions.layerEffectivelyVisible(layer!)
        ? id
        : null;
  }

  String get _activeLayerName {
    final id = _layerSelection.primaryId;
    return _layers.where((value) => value.id == id).firstOrNull?.name ??
        'Choose a layer';
  }

  void _handleNativePacket(Uint8List packet) =>
      _nativePencilInputCoordinator.handlePacket(packet);

  int _nextPointerSequence() {
    final sequence = _sequence & 0xffffffff;
    _sequence = (_sequence + 1) & 0xffffffff;
    return sequence;
  }

  void _scheduleLivePreviewFrameDiagnostic() =>
      _livePreviewFrameDiagnostics.schedule();

  void _appendNativePreviewBatch(
    List<LiveStrokePreviewPoint> samples, {
    required bool beginsStroke,
  }) {
    if (beginsStroke) _prepareLivePreviewInput(strokeStart: true);
    _strokePreviewActions.appendNativeBatch(
      samples,
      beginsStroke: beginsStroke,
    );
  }

  void _discardConcurrentTouchGesture() {
    _pointerEventRouter.forgetPointers(_gestureCoordinator.activePointerIds);
    _gestureCoordinator.reset();
    if (_touchStrokeCancellationCoordinator.isActive) {
      _touchStrokeCancellationCoordinator.cancel(reason: 'touch_state_reset');
    }
  }

  void _handlePencilCommand(String command) {
    if (!mounted) return;
    switch (command) {
      case 'toggleEraser':
        setState(() => _eraserActive = !_eraserActive);
        break;
      case 'quickMenu':
        setState(_workspacePresentation.toggleQuickMenu);
        break;
    }
  }

  void _recordTouchGesture(PointerEvent event) => _gestureCoordinator.record(
    event,
    strokeActive: _strokeActive,
    touchDrawingStrokeActive:
        () => _touchStrokeCancellationCoordinator.isActive,
  );

  Future<void> _sampleCanvasColor(Offset localPosition) =>
      _colorSamplingCoordinator.sample(localPosition);

  Future<void> _showGestureSettings() => _inputSettings.showGestureSettings(
    context: context,
    isMounted: () => mounted,
    onChanged: () => setState(() {}),
  );

  Future<void> _showAccessibilitySettings() =>
      _inputSettings.showAccessibilitySettings(
        context: context,
        isMounted: () => mounted,
        leftHandedToolbar: _leftHandedToolbar,
        updateLeftHandedToolbar: (value) => _leftHandedToolbar = value,
        persistLeftHandedToolbar:
            (value) =>
                _workspaceLayoutActions.persistPreferences(leftHanded: value),
        onChanged: () => setState(() {}),
      );

  Future<bool> _beginActiveBrushStroke() => _strokeStartCoordinator.begin();

  Future<void> _handleDrawingEvent(
    PointerEvent event,
    int sourceSequence,
    Offset preparedPosition,
  ) => _flutterPointerStrokeCoordinator.handleEvent(
    event,
    sourceSequence,
    preparedPosition,
  );

  int _updateStrokePreview(
    Offset position, {
    required bool isDown,
    required bool isUp,
    required double pressure,
    int sourceSequence = -1,
  }) => _liveStrokePreviewInput.update(
    position,
    isDown: isDown,
    isUp: isUp,
    pressure: pressure,
    sourceSequence: sourceSequence,
  );

  void _prepareLivePreviewInput({
    required bool strokeStart,
    bool markInputPending = true,
  }) {
    if (!strokeStart) return;
    _liveStrokePreviewInput.prepareStrokeStart(
      markInputPending: markInputPending,
    );
  }

  /// Retires previews already covered by CPU tiles at stroke completion.
  void _retirePreviewIfAlreadyCpuCovered({required String source}) =>
      _strokePreviewActions.retireIfAlreadyCpuCovered(source: source);

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

  Future<void> _abortStrokeAfterPacketError({
    bool preservePreview = false,
    bool rethrowCancelFailure = false,
  }) => _strokeCancellationCoordinator.abort(
    preservePreview: preservePreview,
    rethrowCancelFailure: rethrowCancelFailure,
  );

  void _prepareInputForDocumentReplacement() {
    _gestureCoordinator.cancelLongPress();
    _drawAndHoldCoordinator.cancel();
    _pointerEventRouter.clearPointers();
    _gestureCoordinator.reset();
    _inputSettings.resetSingleFingerNavigation();
    _touchStrokeCancellationCoordinator.setActive(false);
    // Require a fresh native down after replacement. Continued packets from
    // the contact that was active at the barrier are intentionally discarded.
    _nativePencilInputCoordinator.resetContact();
  }

  void _beginStrokeAutosaveHold() {
    _strokeAutosaveHold.begin();
  }

  void _finishStrokeAutosaveHold({required String reason}) {
    _strokeAutosaveHold.finish(reason: reason);
  }

  void _armDrawAndHold(Offset position) {
    _drawAndHoldCoordinator.arm(position);
  }

  Offset _applyStrokeConstraint(Offset position, {required bool hasDown}) {
    return _strokeConstraintController.apply(position, hasDown: hasDown);
  }

  void _finishConstraintStroke() => _strokeConstraintController.reset();

  Offset _canvasPosition(Offset localPosition) {
    final renderObject = _canvasKey.currentContext?.findRenderObject();
    final size = renderObject is RenderBox ? renderObject.size : Size.zero;
    return CanvasInputCoordinatePolicy.snapToRuler(
      position: _viewportController.documentPosition(
        localPosition: localPosition,
        viewportSize: size,
        documentSize: Size(
          widget.engine.documentInfo.widthPx.toDouble(),
          widget.engine.documentInfo.heightPx.toDouble(),
        ),
      ),
      activeTool: _activeTool,
      rulerStart: _toolEventCoordinator.ruler.start,
      rulerEnd: _toolEventCoordinator.ruler.end,
      rulerTool: _toolEventCoordinator.ruler.tool,
    );
  }

  Future<void> _refreshLayerThumbnails() async {
    // Reuse the revision-aware projection path so thumbnail refreshes remain
    // bounded to two bridge requests and stale document results are dropped.
    await _refreshLayerProjection();
  }

  Iterable<MapEntry<TileCacheKey, ui.Image>> get _visibleImages {
    return projectVisibleTileEntries(
      entries: _tileImages.entries,
      revision: _renderRevision,
      visibleRasterLayers: _layers
          .where((layer) => layer.visible)
          .map((layer) => layer.id),
      primaryRasterLayer: widget.engine.documentInfo.primaryRasterLayer,
    );
  }

  Future<void> _finishDanglingStrokeBeforeBrushEdit() =>
      _danglingStrokeFinalizer.finishBeforeEdit();

  void _clearFinishedStrokeState() {
    _strokeActive = false;
    _activeStrokeIsTouch = false;
    _strokeCaptureEndedAtBoundary = false;
    _nativePencilStrokeCoordinator.clearPageContact();
    _awaitingPreviewCommit = true;
    _finishConstraintStroke();
    _drawAndHoldCoordinator.cancel();
    _stylusLastPosition = null;
    _finishStrokeAutosaveHold(reason: 'vector_stroke_finished');
  }

  void _fitCanvas() {
    final renderObject = _canvasKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return;
    setState(
      () => _viewportController.fitDocument(
        viewportSize: renderObject.size,
        documentSize: Size(
          widget.engine.documentInfo.widthPx.toDouble(),
          widget.engine.documentInfo.heightPx.toDouble(),
        ),
      ),
    );
  }

  void _closeTransientPanels() {
    if (!mounted) return;
    if (_workspacePresentation.interfaceHidden) {
      _exitFocusMode();
      return;
    }
    setState(_workspacePresentation.closePanels);
  }

  bool _wideDesktop(BuildContext context) {
    final platform = widget.targetPlatform ?? defaultTargetPlatform;
    return shouldUseWideDesktopLayout(
      desktopDockEnabled: widget.desktopDockEnabled,
      workspaceMode: resolveWorkspaceMode(
        context,
        override: widget.workspaceModeOverride,
        desktopDockEnabled: widget.desktopDockEnabled,
        targetPlatform: widget.targetPlatform,
      ),
      platform: platform,
      logicalWidth: MediaQuery.sizeOf(context).width,
      physicalWidth: View.of(context).physicalSize.width,
    );
  }

  void _dispatchAction(EditorActionId action) =>
      _editorActionRouter.dispatch(action);

  void _selectPanel(String panel, BuildContext context) {
    final preferences =
        widget.workspacePreferences ?? const WorkspacePreferences();
    final platform = widget.targetPlatform ?? defaultTargetPlatform;
    final tabletPlatform =
        platform == TargetPlatform.iOS || platform == TargetPlatform.android;
    final tabletStudio =
        tabletPlatform &&
        MediaQuery.sizeOf(context).width >= 600 &&
        preferences.tabletMode == TabletWorkspaceMode.studio;
    _workspacePanelActions.selectPanel(
      panel: panel,
      context: context,
      snapshot: CanvasWorkspacePanelActionSnapshot(
        wideDesktop: _wideDesktop(context),
        tabletStudio: tabletStudio,
        tabletPlatform: tabletPlatform,
        tabletMode: preferences.tabletMode,
        layout: _workspaceLayoutActions.layoutFor(
          preferences.workspaceId,
          preferences.customWorkspaces,
        ),
        leftGroups: _leftDockGroups,
        rightGroups: _rightDockGroups,
        floatingPanels: _workspacePresentation.floatingPanels,
      ),
    );
  }

  Widget _toolPaletteContent() => CanvasToolPaletteContent(
    selected: _activeTool,
    onSelected: _selectTool,
    onClearSelection: _clearSelection,
    onTransformPreset: _toolActions.applyTransformPreset,
  );

  Widget _brushPaletteContent() => CanvasBrushPaletteContent(
    library: _brushLibrary,
    actions: _brushActions,
    onImport:
        widget.documentPicker is BrushPicker
            ? _documentActions.importBrush
            : null,
    onExport:
        widget.documentPicker is BrushPicker
            ? _documentActions.exportBrush
            : null,
  );

  Widget _comicPaletteContent({required VoidCallback onClose}) =>
      CanvasComicPaletteContent(
        controller: _comicWorkspace,
        onDrawInsidePanel: _drawInsideComicPanel,
        onClose: onClose,
        onBatchExport:
            widget.documentPicker is ComicExportPicker
                ? _documentActions.exportComicPages
                : null,
      );

  Widget _buildDockPalette(String tab, BuildContext context) =>
      CanvasWorkspacePalette(
        snapshot: CanvasWorkspacePaletteSnapshot(
          tab: tab,
          buildTools: _toolPaletteContent,
          buildBrushes: _brushPaletteContent,
          buildComics:
              () => _comicPaletteContent(
                onClose: () => _selectPanel('layers', context),
              ),
          buildLayers: _layerPanelContent,
          brushLibrary: _brushLibrary,
          activeToolName: _activeTool.name,
          eraserActive: _eraserActive,
          activeLayerName: _activeLayerName,
          mainColor: _activeColor,
          subColor: _subColor,
          recentColors:
              widget.workspacePreferences?.recentColors ?? const <String>[],
          transparentColorActive: _transparentColorActive,
          comicWorkspace: _comicWorkspace,
          quickAccessSets:
              widget.workspacePreferences?.quickAccessSets ??
              defaultQuickAccessSets,
          activeQuickAccessSetId:
              widget.workspacePreferences?.activeQuickAccessSetId ?? 'default',
          engine: widget.engine,
          renderRevision: _renderRevision,
        ),
        actions: CanvasWorkspacePaletteActions(
          onBrushChanged: _brushActions.updateBrushDraft,
          onToggleEraser: () => setState(() => _eraserActive = !_eraserActive),
          onBrushColor: () => _selectPanel('color', context),
          onOpenLayers: () => _selectPanel('layers', context),
          onChooseColor:
              () => _brushColorActions.showColorPicker(context: context),
          onChooseSubColor:
              () => _brushColorActions.showColorPicker(
                context: context,
                editSubColor: true,
              ),
          onSelectRecentColor: _brushColorActions.applyMainColor,
          onSelectRecentSubColor: _brushColorActions.selectSubColor,
          onSwapColors: () => _commands.dispatch(EditorActionId.swapColors),
          onResetColors: () => _commands.dispatch(EditorActionId.resetColors),
          onTransparentColor: _toggleTransparentColor,
          onOpenComics: () => _selectPanel('comics', context),
          onQuickAccessAction: _commands.dispatch,
          onQuickAccessChanged:
              (sets, activeSetId) => _workspaceLayoutActions.persistPreferences(
                quickAccessSets: sets,
                activeQuickAccessSetId: activeSetId,
              ),
          onNavigateHistory: _historyActions.navigateHistory,
        ),
      );

  Widget _layerPanelContent() => CanvasLayerPanelContent(
    engine: widget.engine,
    layers: _layers,
    selection: _layerSelection,
    soloLayerId: _soloLayerId,
    selectedVectorLayerId: _selectedVectorLayerId,
    layerActions: _layerActions,
    vectorActions: _vectorActions,
    tabletMode:
        widget.workspacePreferences?.tabletMode ?? TabletWorkspaceMode.simple,
    targetPlatform: widget.targetPlatform,
    onPanelChanged: () {
      if (mounted) setState(() {});
    },
  );

  @override
  Widget build(BuildContext context) {
    _scheduleLiveViewportSync();
    final wideDesktop = _wideDesktop(context);
    final preferences =
        widget.workspacePreferences ?? const WorkspacePreferences();
    final layout = _workspaceLayoutActions.layoutFor(
      preferences.workspaceId,
      preferences.customWorkspaces,
    );
    final platform = widget.targetPlatform ?? defaultTargetPlatform;
    final workspaceFrame = resolveCanvasWorkspaceFrame(
      platform: platform,
      viewportWidth: MediaQuery.sizeOf(context).width,
      wideDesktop: wideDesktop,
      interfaceHidden: _workspacePresentation.interfaceHidden,
      leftDockCollapsed: _workspaceLeftDockCollapsed,
      rightDockCollapsed: _workspaceDockCollapsed,
      hasLeftDock: layout.left != null,
      hasRightDock: layout.right != null,
      preferredLeftDockWidth: _workspaceDockState.leftWidth,
      preferredRightDockWidth: _workspaceDockState.rightWidth,
      tabletMode: preferences.tabletMode,
      desktopDockEnabled: widget.desktopDockEnabled,
    );
    final desktopDock = workspaceFrame.desktopDock;
    final showLeftDock = workspaceFrame.showLeftDock;
    final showRightDock = workspaceFrame.showRightDock;
    final dockWidth = workspaceFrame.dockWidths.right;
    final leftDockWidth = workspaceFrame.dockWidths.left;
    final showComicCanvasPreview =
        _comicWorkspace.pagePreviewBytes != null &&
        ((_comicClipPanelId != null) ||
            (showRightDock && _desktopDockTab == 'comics') ||
            (!desktopDock &&
                _workspacePresentation.floatingPanels.isVisible(
                  CanvasFloatingPanel.comics,
                )));
    final safeAreaTop = MediaQuery.paddingOf(context).top;
    final tabletStudioMode = workspaceFrame.tabletStudioMode;
    final tabletSimpleMode = workspaceFrame.tabletSimpleMode;
    final useNativeMacMenus = workspaceFrame.useNativeMacMenus;
    final documentActionsEnabled =
        widget.documentPicker != null && !_documentActionRunning;
    final editorShell = Scaffold(
      body: CallbackShortcuts(
        bindings: buildCanvasEditorShortcutBindings(
          dispatch: _commands.dispatch,
          closeTransientPanels: _closeTransientPanels,
        ),
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
                child: CanvasViewportSurface(
                  canvasKey: _canvasKey,
                  paintState: CanvasViewportPaintState(
                    transform: _viewportController.viewport,
                    mirrored: _viewportController.mirrored,
                    revision: _renderRevision,
                    documentWidth: widget.engine.documentInfo.widthPx,
                    documentHeight: widget.engine.documentInfo.heightPx,
                    layers: _layers,
                    tiles: _visibleImages.toList(growable: false),
                    selection: _selectionGeometry,
                    selectionTool: _selectionGeometryTool,
                    previewPoints: _toolEventCoordinator.previewPoints,
                    rulerStart: _toolEventCoordinator.ruler.start,
                    rulerEnd: _toolEventCoordinator.ruler.end,
                  ),
                  strokePreview: _strokePreview,
                  hoverPosition: _pencilHoverPosition,
                  livePreviewSurface: _livePreviewSurface,
                  isIpad: platform == TargetPlatform.iOS,
                  onPointerEvent: _handlePointer,
                  onScaleStart: (details) {
                    _viewportController.beginScaleGesture(
                      details.localFocalPoint,
                    );
                  },
                  onScaleUpdate: (details) {
                    if (details.pointerCount < 2 &&
                        !_inputSettings.singleFingerNavigation) {
                      return;
                    }
                    final renderObject =
                        _canvasKey.currentContext?.findRenderObject();
                    final size =
                        renderObject is RenderBox
                            ? renderObject.size
                            : Size.zero;
                    setState(
                      () => _viewportController.updateScaleGesture(
                        viewportSize: size,
                        focalPoint: details.localFocalPoint,
                        scaleFactor: details.scale,
                        rotationDelta: details.rotation,
                      ),
                    );
                  },
                  onScaleEnd: (_) {
                    _viewportController.endScaleGesture();
                  },
                  onSlowPreviewPaint: (
                    preview,
                    elapsedMicros,
                    directSegments,
                    pictures,
                  ) {
                    _canvasDiagnostics
                        .record('canvas.live_preview_paint_slow', {
                          'paintUs': elapsedMicros,
                          'directSegments': directSegments,
                          'pictures': pictures,
                          'pointCount': preview.points.length,
                          'pendingPointCount':
                              preview.points.length - preview.confirmedThrough,
                        });
                  },
                  comicPreview:
                      showComicCanvasPreview
                          ? ComicCanvasGuideOverlay(
                            controller: _comicWorkspace,
                            pan: _viewportController.viewport.pan,
                            scale: _viewportController.viewport.scale,
                            rotation: _viewportController.viewport.rotation,
                            mirrored: _viewportController.mirrored,
                            documentWidth: widget.engine.documentInfo.widthPx,
                            documentHeight: widget.engine.documentInfo.heightPx,
                            activePanelId: _comicClipPanelId,
                          )
                          : null,
                ),
              ),
              if (!_workspacePresentation.interfaceHidden)
                Positioned(
                  left: 0,
                  top: 0,
                  right: desktopDock ? dockWidth : 0,
                  child: CanvasTopBar(
                    documentName: _documentDisplayName(
                      widget.activeDocumentPath,
                    ),
                    activeToolLabel: _activeTool.label,
                    activeBrushLabel: _brushLibrary.selected?.name ?? 'Brush',
                    saveStatusLabel: _autosaveStatusLabel(widget.autosaveState),
                    documentActionsEnabled: documentActionsEnabled,
                    documentActionRunning: _documentActionRunning,
                    onOpen: _documentActions.openProject,
                    onSave: _documentActions.saveProject,
                    onExportMenu: _documentActions.exportDocumentMenu,
                    onGestureSettings: _showGestureSettings,
                    onAccessibilitySettings: _showAccessibilitySettings,
                    onComics: () => _selectPanel('comics', context),
                    onUndo: () => _commands.dispatch(EditorActionId.undo),
                    onRedo: () => _commands.dispatch(EditorActionId.redo),
                    onCommandSearch:
                        () => _commands.dispatch(EditorActionId.commandSearch),
                    mirrored: _viewportController.mirrored,
                    tabletSimpleMode: tabletSimpleMode,
                    tabletStudioMode: tabletStudioMode,
                    tabletModePreference:
                        widget.workspacePreferences?.tabletMode ??
                        TabletWorkspaceMode.simple,
                    onTabletModeSelected: _setTabletWorkspaceMode,
                    onToggleFocus: _toggleFocusMode,
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
                    commandBarItems:
                        _workspaceLayoutActions.effectiveCommandBarItems(),
                    onCustomizeCommandBar: _customizeCommandBar,
                    contextControls:
                        desktopDock && (showLeftDock || showRightDock)
                            ? CanvasQuickControls(
                              selectedBrush: _brushLibrary.selected,
                              activeLayerName: _activeLayerName,
                              activeColor: _activeColor,
                              eraserActive: _eraserActive,
                              comicClipActive: _comicClipPanelId != null,
                              zoom: _viewportController.viewport.scale,
                              largeControls: false,
                              onBrushChanged: _brushActions.updateBrushDraft,
                              onBrushSizeChangeEnd:
                                  _brushActions.persistBrushSize,
                              onBrushOpacityChangeEnd:
                                  (_) =>
                                      _brushActions
                                          .persistSelectedBrushSettings(),
                              onBrushes: () => _selectPanel('brushes', context),
                              onBrushColor:
                                  () => _selectPanel('color', context),
                              onToggleEraser:
                                  () => setState(
                                    () => _eraserActive = !_eraserActive,
                                  ),
                              onTransparentColor: _toggleTransparentColor,
                              transparentColorActive: _transparentColorActive,
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
              if (!_workspacePresentation.interfaceHidden && tabletSimpleMode)
                Positioned(
                  left: _leftHandedToolbar ? null : 8,
                  right: _leftHandedToolbar ? 8 : null,
                  top: safeAreaTop + 72,
                  bottom: MediaQuery.paddingOf(context).bottom + 8,
                  width: math.max(
                    72,
                    MediaQuery.textScalerOf(context).scale(64),
                  ),
                  child: CanvasSimpleEdgeControls(
                    selectedBrush: _brushLibrary.selected,
                    brushToolActive: _activeTool == IllustrationTool.brush,
                    eraserActive: _eraserActive,
                    onBrushChanged: _brushActions.updateBrushDraft,
                    onBrushSizeChangeEnd: _brushActions.persistBrushSize,
                    onBrushOpacityChangeEnd:
                        (_) => _brushActions.persistSelectedBrushSettings(),
                    onEyedropper:
                        () => _commands.dispatch(EditorActionId.eyedropper),
                    onTools: () => _selectPanel('tools', context),
                    onBrushes: () => _selectPanel('brushes', context),
                    onSelectBrush: () => _selectTool(IllustrationTool.brush),
                    onLayers: () => _selectPanel('layers', context),
                    activeColor: _activeColor,
                    subColor: _subColor,
                    transparentColorActive: _transparentColorActive,
                    onMainColor: () => _selectPanel('color', context),
                    onTransparentColor: _toggleTransparentColor,
                    onSelectEraser: () => _selectTool(IllustrationTool.eraser),
                  ),
                ),
              Positioned.fill(
                child: CanvasEditorAuxiliaryOverlays(
                  snapshot: CanvasEditorAuxiliaryOverlaySnapshot(
                    interfaceHidden: _workspacePresentation.interfaceHidden,
                    tabletStudioMode: tabletStudioMode,
                    leftHanded: _leftHandedToolbar,
                    hasSelection: _selectionGeometry != null,
                    desktopDock: desktopDock,
                    showLeftDock: showLeftDock,
                    showRightDock: showRightDock,
                    quickMenuVisible: _workspacePresentation.quickMenuVisible,
                    safeAreaTop: safeAreaTop,
                    leftDockWidth: leftDockWidth,
                    rightDockWidth: dockWidth,
                    activeTool: _activeTool,
                    eraserActive: _eraserActive,
                    brush: _brushLibrary.selected,
                    color: _activeColor,
                    subColor: _subColor,
                  ),
                  actions: CanvasEditorAuxiliaryOverlayActions(
                    onShowFocusControls: _showFocusQuickControls,
                    onExitFocus: _exitFocusMode,
                    onSelectPanel: (panel) => _selectPanel(panel, context),
                    onToggleEraser:
                        () => _commands.dispatch(EditorActionId.toggleEraser),
                    onDeselect:
                        () => _commands.dispatch(EditorActionId.clearSelection),
                    onInvertSelection:
                        () =>
                            _commands.dispatch(EditorActionId.invertSelection),
                    onGrowSelection:
                        () => _commands.dispatch(EditorActionId.growSelection),
                    onShrinkSelection:
                        () =>
                            _commands.dispatch(EditorActionId.shrinkSelection),
                    onToggleQuickEraser:
                        () => setState(() => _eraserActive = !_eraserActive),
                    onFitCanvas: _fitCanvas,
                    onShowBrushes: () {
                      setState(_workspacePresentation.closeQuickMenu);
                      _selectPanel('brushes', context);
                    },
                    onQuickBrushSizeChanged:
                        _brushActions.updateQuickBrushSizePreview,
                    onQuickBrushSizeChangeEnd: _brushActions.persistBrushSize,
                    onShowBrushColor: () {
                      _exitFocusMode();
                      _selectPanel('color', context);
                    },
                    onBrushChanged: _brushActions.updateBrushDraft,
                    onBrushSizeChangeEnd: _brushActions.persistBrushSize,
                    onBrushOpacityChangeEnd:
                        (_) => _brushActions.persistSelectedBrushSettings(),
                    onCloseQuickMenu:
                        () => setState(_workspacePresentation.closeQuickMenu),
                  ),
                ),
              ),
              CanvasDesktopWorkspace(
                snapshot: CanvasDesktopWorkspaceSnapshot(
                  frame: workspaceFrame,
                  wideDesktop: wideDesktop,
                  interfaceHidden: _workspacePresentation.interfaceHidden,
                  hasLeftDock: layout.left != null,
                  hasRightDock: layout.right != null,
                  leftDockCollapsed: _workspaceLeftDockCollapsed,
                  rightDockCollapsed: _workspaceDockCollapsed,
                  leftDock: CanvasDesktopDockSnapshot(
                    isLeft: true,
                    width: leftDockWidth,
                    title: 'Tools & Color',
                    selectedTab: _leftDockTab,
                    groups: _leftDockGroups,
                  ),
                  rightDock: CanvasDesktopDockSnapshot(
                    isLeft: false,
                    width: dockWidth,
                    title: 'Workspace',
                    selectedTab: _desktopDockTab,
                    groups: _rightDockGroups,
                  ),
                  statusBar: CanvasEditorStatusBar(
                    brushName: _brushLibrary.selected?.name ?? 'Brush',
                    layerName: _activeLayerName,
                    zoom: _viewportController.viewport.scale,
                    rotation: _viewportController.viewport.rotation,
                    mirrored: _viewportController.mirrored,
                    documentWidth: widget.engine.documentInfo.widthPx,
                    documentHeight: widget.engine.documentInfo.heightPx,
                    selected: _selectionGeometry != null,
                    saveStatus: _autosaveStatusLabel(widget.autosaveState),
                  ),
                ),
                actions: CanvasDesktopWorkspaceActions(
                  onWidthDelta: (isLeft, currentWidth, delta) {
                    _dockActions.adjustWidth(left: isLeft, delta: delta);
                  },
                  onTabSelected: (isLeft, groupIndex, tab) {
                    setState(() {
                      _dockActions.selectPaletteState(
                        left: isLeft,
                        groupIndex: groupIndex,
                        tab: tab,
                      );
                      _temporaryDesktopPalette = null;
                    });
                    _dockActions.persistGroups(left: isLeft);
                    _workspaceLayoutActions.persistPreferences(lastDock: tab);
                  },
                  onCollapse:
                      (isLeft) => _dockActions.setCollapsed(
                        left: isLeft,
                        collapsed: true,
                      ),
                  onGroupResize:
                      (isLeft, dividerIndex, delta, availableHeight) =>
                          _dockActions.resizeGroup(
                            left: isLeft,
                            dividerIndex: dividerIndex,
                            delta: delta,
                            availableHeight: availableHeight,
                          ),
                  onGroupResizeEnd:
                      (isLeft) => _dockActions.persistGroups(left: isLeft),
                  onTabReorder:
                      (isLeft, groupIndex, fromIndex, toIndex) =>
                          _dockActions.reorderPalette(
                            left: isLeft,
                            groupIndex: groupIndex,
                            fromIndex: fromIndex,
                            toIndex: toIndex,
                          ),
                  onTabMove:
                      (targetLeft, source, targetGroupIndex, targetTabIndex) =>
                          _dockActions.movePalette(
                            source: source,
                            targetLeft: targetLeft,
                            targetGroupIndex: targetGroupIndex,
                            targetTabIndex: targetTabIndex,
                          ),
                  onExpand:
                      (isLeft) => _dockActions.setCollapsed(
                        left: isLeft,
                        collapsed: false,
                      ),
                ),
                buildPalette: (tab) => _buildDockPalette(tab, context),
              ),
              if (desktopDock && _temporaryDesktopPalette != null)
                Positioned(
                  left: 52 + leftDockWidth,
                  top: 44,
                  bottom: 32,
                  width: 360,
                  child: CanvasToolPanel(
                    title: _workspaceLayoutActions.paletteLabel(
                      _temporaryDesktopPalette!,
                    ),
                    onClose:
                        () => setState(() => _temporaryDesktopPalette = null),
                    child: _buildDockPalette(
                      _temporaryDesktopPalette!,
                      context,
                    ),
                  ),
                ),
              CanvasFloatingWorkspacePanels(
                visibility: _workspacePresentation.floatingPanels,
                onVisibilityChanged:
                    (visibility) => setState(
                      () =>
                          _workspacePresentation.setFloatingPanels(visibility),
                    ),
                interfaceHidden: _workspacePresentation.interfaceHidden,
                desktopDock: desktopDock,
                tabletStudioMode: tabletStudioMode,
                leftHanded: _leftHandedToolbar,
                safeAreaTop: safeAreaTop,
                tools: _toolPaletteContent(),
                brushes: _brushPaletteContent(),
                properties: _buildDockPalette('properties', context),
                materials: _buildDockPalette('materials', context),
                layers: _layerPanelContent(),
                comics: _comicPaletteContent(
                  onClose:
                      () => setState(
                        () => _workspacePresentation.setFloatingPanels(
                          _workspacePresentation.floatingPanels.setVisible(
                            CanvasFloatingPanel.comics,
                            false,
                          ),
                        ),
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
      menus: buildCanvasMacOSApplicationMenus(
        documentActionsEnabled: documentActionsEnabled,
        documentActionRunning: _documentActionRunning,
        onActionSelected: _commands.dispatch,
        onQuit:
            () => unawaited(
              _nativeWindowCloseChannel.invokeMethod<void>('terminate'),
            ),
      ),
      child: editorShell,
    );
  }
}
