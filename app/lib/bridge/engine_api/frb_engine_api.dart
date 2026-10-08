import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../generated/api.dart' as rust;
import '../generated/frb_generated.dart' show RustLib;
import '../../tools/brush_library.dart'
    show BrushCurvePointView, BrushPreviewPointView;
import 'engine_api_contract.dart';
import 'engine_api_models.dart';
import 'engine_api_packets.dart';
import 'layer_id_projection.dart';

class FrbEngineApi implements EngineApi, LiveRenderEngineApi {
  FrbEngineApi._(
    rust.DocumentHandle handle,
    this._revision,
    this.documentInfo,
    this._layerIds,
  ) : _handle = handle,
      _fallbackHandle = handle;

  rust.DocumentHandle _handle;
  rust.DocumentHandle? _fallbackHandle;
  rust.StudioProjectHandle? _projectHandle;
  rust.StudioProjectHandle? _pendingRecoveryStudioProject;
  bool _usingProjectHandle = false;
  @override
  DocumentInfo documentInfo;
  int _revision;
  bool _closed = false;
  final LayerIdProjection _layerIds;

  @override
  int layerIdForUi(BigInt rustLayerId) => _layerIds.toDart(rustLayerId);

  static const int _maxSafeLayerId = 0x7fffffffffffffff;
  static Future<void>? _bridgeInitialization;

  static int _safeId(BigInt value, String label) {
    if (value.isNegative || value > BigInt.from(_maxSafeLayerId)) {
      throw StateError('$label identifier exceeds Dart safety range');
    }
    return value.toInt();
  }

  static Future<FrbEngineApi> create({
    int widthPx = 2048,
    int heightPx = 2048,
    double dpi = 300,
  }) async {
    debugPrint('Project Ink startup: initializing engine for new document');
    await _initializeBridge();
    debugPrint('Project Ink startup: creating Rust document');
    final handle = await rust.createDefaultDocument(
      id: BigInt.from(DateTime.now().microsecondsSinceEpoch),
      widthPx: widthPx,
      heightPx: heightPx,
      dpi: dpi,
    );
    debugPrint('Project Ink: default document created');
    return _fromHandle(handle);
  }

  /// Open a previously saved native `.inkproj` directory.
  ///
  /// The source is opened read/write by the Rust engine, but it is never
  /// modified merely by opening it. Callers should keep the chosen path and
  /// invoke [saveAs] explicitly when the user confirms a save operation.
  static Future<FrbEngineApi> open(String path) async {
    debugPrint('Project Ink startup: initializing engine for project open');
    await _initializeBridge();
    debugPrint('Project Ink startup: Rust project open started');
    late final rust.DocumentHandle handle;
    try {
      handle = await rust.openDocument(path: path);
    } on rust.EngineError catch (error, stack) {
      debugPrint('Project Ink: project open failed: $error\n$stack');
      Error.throwWithStackTrace(
        const DocumentOpenException(
          'Could not open the selected document. It may be damaged, unsupported, or inaccessible.',
        ),
        stack,
      );
    }
    debugPrint('Project Ink: document opened');
    return _fromHandle(handle);
  }

  /// Reopen the app-owned recovery checkpoint using its persisted project
  /// type. Studio packages must be opened as complete projects so page
  /// documents, comic structure, and the canvas all share one Rust authority.
  static Future<FrbEngineApi> openRecovery(String path) async {
    await _initializeBridge();
    if (!await _isStudioProjectDirectory(path)) return open(path);

    rust.StudioProjectHandle? project;
    rust.DocumentHandle? page;
    try {
      project = await rust.openStudioProject(path: path);
      final snapshot = await rust.projectSnapshot(handle: project);
      if (snapshot.pages.isEmpty) {
        throw const DocumentOpenException(
          'The recovery project does not contain a page.',
        );
      }
      page = await rust.projectActiveDocument(handle: project);
      final engine = await _fromHandle(page);
      engine._projectHandle = project;
      engine._usingProjectHandle = true;
      engine._pendingRecoveryStudioProject = project;
      return engine;
    } catch (error, stack) {
      if (page != null) {
        await rust.closeDocument(handle: page);
      }
      if (project != null) {
        await rust.closeStudioProject(handle: project);
      }
      if (error is DocumentOpenException) {
        Error.throwWithStackTrace(error, stack);
      }
      Error.throwWithStackTrace(
        const DocumentOpenException(
          'Could not open the saved recovery project. It was left untouched.',
        ),
        stack,
      );
    }
  }

  static Future<bool> _isStudioProjectDirectory(String path) async {
    final manifestFile = File('$path${Platform.pathSeparator}manifest.json');
    if (!await manifestFile.exists()) return false;
    final length = await manifestFile.length();
    // Storage accepts a bounded manifest. Keep the type probe bounded too.
    if (length > 256 * 1024) return false;
    try {
      final decoded = jsonDecode(await manifestFile.readAsString());
      return isStudioProjectManifest(decoded);
    } on FormatException {
      return false;
    }
  }

  @visibleForTesting
  static bool isStudioProjectManifest(Object? manifest) =>
      manifest is Map &&
      manifest['project_id'] is String &&
      manifest['page_count'] is int;

  /// Transfer the recovery project's owning capability to the comic session.
  /// The engine retains a non-owning reference for complete-project saves.
  rust.StudioProjectHandle? takeRecoveryStudioProject() {
    final project = _pendingRecoveryStudioProject;
    _pendingRecoveryStudioProject = null;
    return project;
  }

  static Future<void> _initializeBridge() async {
    final inFlight = _bridgeInitialization;
    if (inFlight != null) {
      await inFlight;
      return;
    }
    final initialization = _initializeBridgeOnce();
    _bridgeInitialization = initialization;
    try {
      await initialization;
    } catch (_) {
      // A failed dynamic-library load should be retryable after the platform
      // runner has finished registering plugins. Do not retain a failed
      // future as a permanent process-wide initialization state.
      if (identical(_bridgeInitialization, initialization)) {
        _bridgeInitialization = null;
      }
      rethrow;
    }
  }

  static Future<void> _initializeBridgeOnce() async {
    // Keep initialization checkpoints visible in debug logs so a platform
    // runner that cannot load the native library does not look like a generic
    // Flutter startup hang during device acceptance.
    debugPrint('Project Ink: RustLib.init starting');
    await RustLib.init();
    debugPrint('Project Ink: RustLib.init complete');
    final health = await rust.engineHealth();
    if (health != 'project-ink-engine-v1') {
      throw StateError('unexpected Rust engine health marker: $health');
    }
    debugPrint('Project Ink: engine health passed ($health)');
  }

  static Future<FrbEngineApi> _fromHandle(rust.DocumentHandle handle) async {
    final revision = await rust.revision(handle: handle);
    final info = await rust.documentInfo(handle: handle);
    final summaries = await rust.layerSummaries(handle: handle);
    final layerIds =
        LayerIdProjection()..reset(<BigInt>[
          info.primaryRasterLayer,
          for (final summary in summaries) ...<BigInt>[
            summary.id,
            if (summary.parent != null) summary.parent!,
          ],
        ]);
    debugPrint('Project Ink: initial revision loaded');
    return FrbEngineApi._(
      handle,
      revision.toInt(),
      DocumentInfo(
        widthPx: info.widthPx,
        heightPx: info.heightPx,
        dpi: info.dpi,
        primaryRasterLayer: layerIds.toDart(info.primaryRasterLayer),
      ),
      layerIds,
    );
  }

  void _requireOpen() {
    if (_closed) throw StateError('document engine is closed');
  }

  /// Rebind this control-plane adapter to a shared page document owned by a
  /// StudioProjectHandle. The Rust handle is a capability view over the same
  /// document, so existing canvas code keeps its EngineApi contract while
  /// project snapshots and saves observe the exact same state.
  Future<void> rebindDocument(rust.DocumentHandle? handle) async {
    _requireOpen();
    final target = handle ?? _fallbackHandle;
    if (target == null) {
      throw StateError('no fallback document is available');
    }
    if (handle != null && !_usingProjectHandle) {
      _fallbackHandle = _handle;
    }
    final revision = await rust.revision(handle: target);
    final info = await rust.documentInfo(handle: target);
    final summaries = await rust.layerSummaries(handle: target);
    _layerIds.reset(<BigInt>[
      info.primaryRasterLayer,
      for (final summary in summaries) ...<BigInt>[
        summary.id,
        if (summary.parent != null) summary.parent!,
      ],
    ]);
    _handle = target;
    _usingProjectHandle = handle != null;
    _revision = revision.toInt();
    documentInfo = DocumentInfo(
      widthPx: info.widthPx,
      heightPx: info.heightPx,
      dpi: info.dpi,
      primaryRasterLayer: _layerIds.toDart(info.primaryRasterLayer),
    );
  }

  /// Bind complete-project persistence to the same Rust project that owns the
  /// active page capability. Passing null restores standalone document saves.
  void bindStudioProject(rust.StudioProjectHandle? handle) {
    _projectHandle = handle;
  }

  /// Create or reuse a one-page project capability around the active
  /// illustration document, preserving its pixels and document history.
  Future<rust.StudioProjectHandle> createStudioProjectForCurrentDocument({
    required BigInt projectId,
    required BigInt pageId,
    required String title,
  }) async {
    _requireOpen();
    final existing = _projectHandle;
    if (existing != null) return existing;
    final fallback = _fallbackHandle;
    if (fallback == null) throw StateError('no illustration document is open');
    final project = await rust.createStudioProjectForDocument(
      handle: _handle,
      projectId: projectId,
      pageId: pageId,
      title: title,
    );
    _fallbackHandle ??= _handle;
    _projectHandle = project;
    _usingProjectHandle = true;
    _handle = await rust.projectActiveDocument(handle: project);
    return project;
  }

  @override
  int get revision => _revision;

  @override
  Future<void> beginStroke() async {
    _requireOpen();
    _revision = (await rust.beginDefaultStroke(handle: _handle)).toInt();
  }

  @override
  Future<void> beginBrushStroke(int brushId) async {
    _requireOpen();
    if (brushId < 0) throw ArgumentError.value(brushId, 'brushId');
    _revision =
        (await rust.beginBrushStroke(
          handle: _handle,
          brushId: BigInt.from(brushId),
        )).toInt();
  }

  @override
  Future<void> beginBrushStrokeOnLayer(int brushId, int layerId) async {
    _requireOpen();
    if (brushId < 0 || layerId < 0) {
      throw ArgumentError('brush and layer IDs must be non-negative');
    }
    _revision =
        (await rust.beginBrushStrokeOnLayer(
          handle: _handle,
          brushId: BigInt.from(brushId),
          layerId: _layerIds.toRust(layerId),
        )).toInt();
  }

  @override
  Future<void> updateBrushColor({
    required int brushId,
    required int red,
    required int green,
    required int blue,
    required int alpha,
  }) async {
    _requireOpen();
    if (brushId < 0 ||
        [red, green, blue, alpha].any((value) => value < 0 || value > 255)) {
      throw ArgumentError('invalid brush color');
    }
    _revision =
        (await rust.updateBrushColor(
          handle: _handle,
          brushId: BigInt.from(brushId),
          red: red,
          green: green,
          blue: blue,
          alpha: alpha,
        )).toInt();
  }

  @override
  Future<void> setActiveBrushColor({
    required int red,
    required int green,
    required int blue,
    required int alpha,
  }) async {
    _requireOpen();
    if ([red, green, blue, alpha].any((value) => value < 0 || value > 255)) {
      throw ArgumentError('invalid active brush color');
    }
    await rust.setActiveBrushColor(
      handle: _handle,
      red: red,
      green: green,
      blue: blue,
      alpha: alpha,
    );
  }

  @override
  Future<void> transformVectorStroke({
    required int layerId,
    required int strokeId,
    required double a,
    required double b,
    required double c,
    required double d,
    required double tx,
    required double ty,
  }) async {
    _requireOpen();
    if (layerId < 0 ||
        strokeId < 0 ||
        [a, b, c, d, tx, ty].any((value) => !value.isFinite) ||
        (a * d - b * c).abs() < 0.000001) {
      throw ArgumentError('invalid vector transform');
    }
    _revision =
        (await rust.transformVectorStroke(
          handle: _handle,
          layerId: _layerIds.toRust(layerId),
          strokeId: BigInt.from(strokeId),
          a: a,
          b: b,
          c: c,
          d: d,
          translateX: tx,
          translateY: ty,
        )).toInt();
  }

  @override
  Future<void> simplifyVectorStroke({
    required int layerId,
    required int strokeId,
    required double tolerance,
  }) async {
    _requireOpen();
    if (layerId < 0 ||
        strokeId < 0 ||
        !tolerance.isFinite ||
        tolerance <= 0 ||
        tolerance > 256) {
      throw ArgumentError('invalid vector simplification');
    }
    _revision =
        (await rust.simplifyVectorStroke(
          handle: _handle,
          layerId: _layerIds.toRust(layerId),
          strokeId: BigInt.from(strokeId),
          tolerance: tolerance,
        )).toInt();
  }

  @override
  Future<void> connectVectorStrokes({
    required int layerId,
    required int firstId,
    required int secondId,
    required double tolerance,
  }) async {
    _requireOpen();
    if (layerId < 0 ||
        firstId < 0 ||
        secondId < 0 ||
        firstId == secondId ||
        !tolerance.isFinite ||
        tolerance <= 0 ||
        tolerance > 256) {
      throw ArgumentError('invalid vector connection');
    }
    _revision =
        (await rust.connectVectorStrokes(
          handle: _handle,
          layerId: _layerIds.toRust(layerId),
          firstId: BigInt.from(firstId),
          secondId: BigInt.from(secondId),
          tolerance: tolerance,
        )).toInt();
  }

  @override
  Future<void> eraseVectorSegment({
    required int layerId,
    required int strokeId,
    required double centerX,
    required double centerY,
    required double radius,
  }) async {
    _requireOpen();
    if (layerId < 0 ||
        strokeId < 0 ||
        [centerX, centerY, radius].any((value) => !value.isFinite) ||
        radius <= 0 ||
        radius > 4096) {
      throw ArgumentError('invalid vector eraser');
    }
    _revision =
        (await rust.eraseVectorSegment(
          handle: _handle,
          layerId: _layerIds.toRust(layerId),
          strokeId: BigInt.from(strokeId),
          centerX: centerX,
          centerY: centerY,
          radius: radius,
        )).toInt();
  }

  @override
  Future<void> exportBrush({required int brushId, required String path}) {
    _requireOpen();
    if (brushId < 0) throw ArgumentError.value(brushId, 'brushId');
    return rust.exportBrush(
      handle: _handle,
      brushId: BigInt.from(brushId),
      path: path,
    );
  }

  @override
  Future<int> duplicateBrush(int brushId) async {
    _requireOpen();
    if (brushId < 0) throw ArgumentError.value(brushId, 'brushId');
    final id = await rust.duplicateBrush(
      handle: _handle,
      brushId: BigInt.from(brushId),
    );
    _revision = (await rust.revision(handle: _handle)).toInt();
    return _safeId(id, 'brush');
  }

  @override
  Future<void> renameBrush({required int brushId, required String name}) async {
    _requireOpen();
    if (brushId < 0) throw ArgumentError.value(brushId, 'brushId');
    await rust.renameBrush(
      handle: _handle,
      brushId: BigInt.from(brushId),
      name: name,
    );
    _revision = (await rust.revision(handle: _handle)).toInt();
  }

  @override
  Future<BrushImportInspectionView> inspectBrushImport(String path) async {
    _requireOpen();
    final value = await rust.inspectBrushImport(path: path);
    return BrushImportInspectionView(
      sourceFormat: value.sourceFormat,
      sourceSha256: value.sourceSha256,
      bytes: value.bytes.toInt(),
      fidelity: value.fidelity,
      importerVersion: value.importerVersion,
    );
  }

  @override
  Future<BrushImportReportView> convertBrushImport(String path) async {
    _requireOpen();
    final value = await rust.convertBrushImport(path: path);
    return BrushImportReportView(
      sourceFormat: value.sourceFormat,
      sourceSha256: value.sourceSha256,
      importerVersion: value.importerVersion,
      fidelity: value.fidelity,
      mappings: value.mappings,
      omitted: value.omitted,
      warnings: value.warnings,
      resourceCount: value.resourceCount,
      previewWidth: value.previewWidth,
      previewHeight: value.previewHeight,
      brushCount: value.brushCount,
    );
  }

  @override
  Future<BrushImportStageView> stageBrushImport(String path) async {
    _requireOpen();
    if (path.isEmpty) throw ArgumentError('invalid brush staging path');
    final value = await rust.stageBrushImport(handle: _handle, path: path);
    return BrushImportStageView(
      operationId: value.operationId.toInt(),
      inspection: BrushImportInspectionView(
        sourceFormat: value.inspection.sourceFormat,
        sourceSha256: value.inspection.sourceSha256,
        bytes: value.inspection.bytes.toInt(),
        fidelity: value.inspection.fidelity,
        importerVersion: value.inspection.importerVersion,
      ),
      expiresInSeconds: value.expiresInSeconds,
    );
  }

  @override
  Future<BrushImportReportView> convertStagedBrushImport(
    int operationId,
  ) async {
    _requireOpen();
    if (operationId <= 0) throw ArgumentError('invalid brush operation');
    final value = await rust.convertStagedBrushImport(
      handle: _handle,
      operationId: BigInt.from(operationId),
    );
    return BrushImportReportView(
      sourceFormat: value.sourceFormat,
      sourceSha256: value.sourceSha256,
      importerVersion: value.importerVersion,
      fidelity: value.fidelity,
      mappings: value.mappings,
      omitted: value.omitted,
      warnings: value.warnings,
      resourceCount: value.resourceCount,
      previewWidth: value.previewWidth,
      previewHeight: value.previewHeight,
      brushCount: value.brushCount,
    );
  }

  @override
  Future<int> commitStagedBrushImport(int operationId) async {
    _requireOpen();
    if (operationId <= 0) throw ArgumentError('invalid brush operation');
    final id = await rust.commitStagedBrushImport(
      handle: _handle,
      operationId: BigInt.from(operationId),
    );
    _revision = (await rust.revision(handle: _handle)).toInt();
    return id.toInt();
  }

  @override
  Future<void> discardStagedBrushImport(int operationId) async {
    _requireOpen();
    if (operationId <= 0) throw ArgumentError('invalid brush operation');
    await rust.discardStagedBrushImport(
      handle: _handle,
      operationId: BigInt.from(operationId),
    );
  }

  @override
  Future<int> importBrush(String path) async {
    _requireOpen();
    final id = await rust.importBrush(handle: _handle, path: path);
    _revision = (await rust.revision(handle: _handle)).toInt();
    return id.toInt();
  }

  @override
  Future<int> importBrushVerified(String path, Uint8List sourceSha256) async {
    _requireOpen();
    if (sourceSha256.length != 32) {
      throw ArgumentError.value(sourceSha256.length, 'sourceSha256');
    }
    final id = await rust.importBrushVerified(
      handle: _handle,
      path: path,
      sourceSha256: sourceSha256,
    );
    _revision = (await rust.revision(handle: _handle)).toInt();
    return id.toInt();
  }

  @override
  Future<List<int>> importBrushPackVerified(
    String path,
    Uint8List sourceSha256,
  ) async {
    _requireOpen();
    if (sourceSha256.length != 32) {
      throw ArgumentError.value(sourceSha256.length, 'sourceSha256');
    }
    final ids = await rust.importBrushPackVerified(
      handle: _handle,
      path: path,
      sourceSha256: sourceSha256,
    );
    _revision = (await rust.revision(handle: _handle)).toInt();
    return ids.map((id) => id.toInt()).toList(growable: false);
  }

  @override
  Future<List<int>> importKritaBundleVerified(
    String path,
    Uint8List sourceSha256,
  ) async {
    _requireOpen();
    if (sourceSha256.length != 32) {
      throw ArgumentError.value(sourceSha256.length, 'sourceSha256');
    }
    final ids = await rust.importKritaBundleVerified(
      handle: _handle,
      path: path,
      sourceSha256: sourceSha256,
    );
    _revision = (await rust.revision(handle: _handle)).toInt();
    return ids.map((id) => id.toInt()).toList(growable: false);
  }

  @override
  Future<void> updateBrushSettings({
    required int brushId,
    required double diameter,
    required double opacity,
    required double spacing,
    required double smoothing,
    required double pressureSize,
    required double pressureOpacity,
    required double pressureCurve,
    required List<BrushCurvePointView> pressureCurvePoints,
    required double hardness,
    required double textureScale,
    required double scatter,
    required double rotationJitter,
    required double smudge,
    required double wetness,
  }) async {
    _requireOpen();
    if (brushId < 0) throw ArgumentError.value(brushId, 'brushId');
    _revision =
        (await rust.updateBrushSettings(
          handle: _handle,
          brushId: BigInt.from(brushId),
          diameterPx: diameter,
          opacity: opacity,
          spacing: spacing,
          smoothing: smoothing,
          pressureSize: pressureSize,
          pressureOpacity: pressureOpacity,
          pressureCurve: pressureCurve,
          pressureCurvePoints: pressureCurvePoints
              .expand((point) => <double>[point.x, point.y])
              .toList(growable: false),
          hardness: hardness,
          textureScale: textureScale,
          scatter: scatter,
          rotationJitter: rotationJitter,
          smudge: smudge,
          wetness: wetness,
        )).toInt();
  }

  @override
  Future<int> beginBrushDraft(int brushId) async {
    _requireOpen();
    return (await rust.beginBrushDraft(
      handle: _handle,
      brushId: BigInt.from(brushId),
    )).toInt();
  }

  @override
  Future<void> setVectorPoint({
    required int layerId,
    required int strokeId,
    required int index,
    required double x,
    required double y,
    required double pressure,
    required double tilt,
  }) async {
    _requireOpen();
    if (layerId < 0 ||
        strokeId < 0 ||
        index < 0 ||
        [x, y, pressure, tilt].any((value) => !value.isFinite) ||
        pressure < 0 ||
        pressure > 1) {
      throw ArgumentError('invalid vector control point');
    }
    _revision =
        (await rust.setVectorPoint(
          handle: _handle,
          layerId: _layerIds.toRust(layerId),
          strokeId: BigInt.from(strokeId),
          index: index,
          x: x,
          y: y,
          pressure: pressure,
          tilt: tilt,
        )).toInt();
  }

  @override
  Future<void> updateBrushDraft({
    required int draftId,
    required double diameter,
    required double opacity,
    required double spacing,
    required double smoothing,
    required double pressureSize,
    required double pressureOpacity,
    required double pressureCurve,
    required List<BrushCurvePointView> pressureCurvePoints,
    required double hardness,
    required double textureScale,
    required double scatter,
    required double rotationJitter,
    required double smudge,
    required double wetness,
  }) async {
    _requireOpen();
    await rust.updateBrushDraft(
      handle: _handle,
      draftId: BigInt.from(draftId),
      diameterPx: diameter,
      opacity: opacity,
      spacing: spacing,
      smoothing: smoothing,
      pressureSize: pressureSize,
      pressureOpacity: pressureOpacity,
      pressureCurve: pressureCurve,
      pressureCurvePoints: pressureCurvePoints
          .expand((point) => <double>[point.x, point.y])
          .toList(growable: false),
      hardness: hardness,
      textureScale: textureScale,
      scatter: scatter,
      rotationJitter: rotationJitter,
      smudge: smudge,
      wetness: wetness,
    );
  }

  @override
  Future<void> commitBrushDraft(int draftId) async {
    _requireOpen();
    _revision =
        (await rust.commitBrushDraft(
          handle: _handle,
          draftId: BigInt.from(draftId),
        )).toInt();
  }

  @override
  Future<void> cancelBrushDraft(int draftId) async {
    _requireOpen();
    await rust.cancelBrushDraft(handle: _handle, draftId: BigInt.from(draftId));
  }

  @override
  Future<Uint8List> renderBrushPreview({
    required int brushId,
    required int width,
    required int height,
    required List<BrushPreviewPointView> points,
  }) async {
    _requireOpen();
    return rust.renderBrushPreviewPng(
      handle: _handle,
      brushId: BigInt.from(brushId),
      width: width,
      height: height,
      points: points
          .map(
            (point) => rust.BrushPreviewPoint(
              x: point.x,
              y: point.y,
              pressure: point.pressure,
            ),
          )
          .toList(growable: false),
    );
  }

  @override
  Future<void> endStroke() async {
    _requireOpen();
    _revision = (await rust.endStroke(handle: _handle)).toInt();
  }

  @override
  Future<void> cancelStroke() async {
    _requireOpen();
    _revision = (await rust.cancelStroke(handle: _handle)).toInt();
  }

  @override
  Future<void> pushPointerPacket(Uint8List packet) async {
    _requireOpen();
    await rust.pushPointerPacket(handle: _handle, packet: packet);
  }

  @override
  Future<rust.LiveSurfaceHandle> createLiveSurface({
    required int physicalWidth,
    required int physicalHeight,
    required int scaleMilli,
  }) {
    _requireOpen();
    return rust.createLiveSurface(
      physicalWidth: physicalWidth,
      physicalHeight: physicalHeight,
      scaleMilli: scaleMilli,
    );
  }

  @override
  Future<BigInt> liveSurfaceNativeDeviceHandle(rust.LiveSurfaceHandle surface) {
    _requireOpen();
    return rust.liveSurfaceNativeDeviceHandle(surface: surface);
  }

  @override
  Future<void> attachLiveSurfaceNativeTexture(
    rust.LiveSurfaceHandle surface,
    BigInt textureHandle,
  ) {
    _requireOpen();
    return rust.attachLiveSurfaceNativeTexture(
      surface: surface,
      textureHandle: textureHandle,
    );
  }

  @override
  Future<void> attachLiveSurface(rust.LiveSurfaceHandle surface) {
    _requireOpen();
    return rust.attachLiveSurface(documentHandle: _handle, surface: surface);
  }

  @override
  Future<void> setLiveViewport(
    rust.LiveSurfaceHandle surface,
    List<double> matrix,
    int generation,
  ) {
    _requireOpen();
    if (generation < 0 || generation > 0x7fffffffffffffff) {
      throw RangeError.range(generation, 0, 0x7fffffffffffffff, 'generation');
    }
    return rust.setLiveViewport(
      surface: surface,
      matrix: matrix,
      generation: BigInt.from(generation),
    );
  }

  @override
  Future<Uint8List> drainLiveDabs({int limit = 2048}) {
    _requireOpen();
    if (limit < 1 || limit > 65_536) {
      throw RangeError.range(limit, 1, 65_536, 'limit');
    }
    return rust.drainLiveDabs(handle: _handle, limit: limit);
  }

  @override
  @override
  Future<void> renderLiveDabPacket(
    rust.LiveSurfaceHandle surface,
    Uint8List packet,
  ) {
    _requireOpen();
    return rust.renderLiveDabPacket(surface: surface, packet: packet);
  }

  @override
  Future<void> acknowledgeLiveSurface(
    rust.LiveSurfaceHandle surface,
    BigInt strokeId,
    int highestCommittedSequence,
  ) {
    _requireOpen();
    if (strokeId.isNegative ||
        strokeId >= (BigInt.one << 128) ||
        highestCommittedSequence < 0 ||
        highestCommittedSequence > 0xffffffff) {
      throw ArgumentError('invalid live stroke acknowledgement');
    }
    return rust.acknowledgeLiveSurface(
      surface: surface,
      strokeId: strokeId,
      highestCommittedSequence: highestCommittedSequence,
    );
  }

  @override
  Future<void> cancelLiveSurfaceStroke(
    rust.LiveSurfaceHandle surface,
    BigInt strokeId,
  ) {
    _requireOpen();
    if (strokeId.isNegative || strokeId >= (BigInt.one << 128)) {
      throw ArgumentError.value(strokeId, 'strokeId');
    }
    return rust.cancelLiveSurfaceStroke(surface: surface, strokeId: strokeId);
  }

  @override
  Future<void> detachLiveSurface(rust.LiveSurfaceHandle surface) {
    _requireOpen();
    return rust.detachLiveSurface(documentHandle: _handle, surface: surface);
  }

  @override
  Future<void> disposeLiveSurface(rust.LiveSurfaceHandle surface) =>
      rust.disposeLiveSurface(surface: surface);

  @override
  Future<void> undo() async {
    _requireOpen();
    _revision = (await rust.undo(handle: _handle)).toInt();
  }

  @override
  Future<void> redo() async {
    _requireOpen();
    _revision = (await rust.redo(handle: _handle)).toInt();
  }

  @override
  Future<rust.HistorySnapshotView> historySnapshot({int limit = 100}) async {
    _requireOpen();
    if (limit < 1 || limit > 100) {
      throw RangeError.range(limit, 1, 100, 'limit');
    }
    final snapshot = await rust.historySnapshot(handle: _handle, limit: limit);
    _revision = snapshot.revision.toInt();
    return snapshot;
  }

  @override
  Future<void> navigateHistory(int sequence) async {
    _requireOpen();
    if (sequence < 0) throw RangeError.value(sequence, 'sequence');
    _revision =
        (await rust.navigateHistory(
          handle: _handle,
          sequence: BigInt.from(sequence),
        )).toInt();
  }

  @override
  Future<int> addLayer({required String kind}) async {
    _requireOpen();
    final kindValue = switch (kind) {
      'Raster' => 0,
      'VectorInk' => 1,
      'Group' => 2,
      'Mask' => 3,
      'Tone' => 4,
      'PanelGroup' => 5,
      'Adjustment' => 6,
      _ => throw ArgumentError('unknown layer kind'),
    };
    return _layerIds.toDart(
      await rust.addLayer(handle: _handle, kind: kindValue),
    );
  }

  @override
  Future<int> addLayerToParent({
    required String kind,
    required int parentId,
  }) async {
    _requireOpen();
    if (parentId < 0) throw ArgumentError('invalid layer parent');
    final kindValue = switch (kind) {
      'Raster' => 0,
      'VectorInk' => 1,
      'Group' => 2,
      'Mask' => 3,
      'Tone' => 4,
      'PanelGroup' => 5,
      'Adjustment' => 6,
      _ => throw ArgumentError('unknown layer kind'),
    };
    return _layerIds.toDart(
      await rust.addLayerToParent(
        handle: _handle,
        kind: kindValue,
        parent: _layerIds.toRust(parentId),
      ),
    );
  }

  @override
  Future<void> moveLayer({
    required int layerId,
    required int? parentId,
    required int index,
  }) async {
    _requireOpen();
    if (layerId < 0 || (parentId != null && parentId < 0) || index < 0) {
      throw ArgumentError('invalid layer move');
    }
    _revision =
        (await rust.moveLayer(
          handle: _handle,
          layer: _layerIds.toRust(layerId),
          parent: parentId == null ? null : _layerIds.toRust(parentId),
          index: index,
        )).toInt();
  }

  @override
  Future<void> reorderLayers({
    required List<int> layerIds,
    required int index,
  }) async {
    _requireOpen();
    if (layerIds.isEmpty ||
        layerIds.any((id) => id <= 0) ||
        layerIds.toSet().length != layerIds.length ||
        index < 0) {
      throw ArgumentError(
        'reorder requires unique IDs and a non-negative index',
      );
    }
    _revision =
        (await rust.reorderLayers(
          handle: _handle,
          layers: layerIds.map(_layerIds.toRust).toList(growable: false),
          index: index,
        )).toInt();
  }

  @override
  Future<void> deleteLayer({required int layerId}) async {
    _requireOpen();
    if (layerId <= 0) throw ArgumentError('invalid layer ID');
    final project = _projectHandle;
    _revision =
        project != null && _usingProjectHandle
            ? (await rust.deleteProjectLayer(
              handle: project,
              layer: _layerIds.toRust(layerId),
            )).toInt()
            : (await rust.deleteLayer(
              handle: _handle,
              layer: _layerIds.toRust(layerId),
            )).toInt();
  }

  @override
  Future<void> clearLayer({required int layerId}) async {
    _requireOpen();
    if (layerId <= 0) throw ArgumentError.value(layerId, 'layerId');
    _revision =
        (await rust.clearLayer(
          handle: _handle,
          layer: _layerIds.toRust(layerId),
        )).toInt();
  }

  @override
  Future<void> deleteLayers({required List<int> layerIds}) async {
    _requireOpen();
    if (layerIds.isEmpty ||
        layerIds.any((id) => id <= 0) ||
        layerIds.toSet().length != layerIds.length) {
      throw ArgumentError('delete requires unique layer IDs');
    }
    final project = _projectHandle;
    _revision =
        project != null && _usingProjectHandle
            ? (await rust.deleteProjectLayers(
              handle: project,
              layerIds: layerIds.map(_layerIds.toRust).toList(growable: false),
            )).toInt()
            : (await rust.deleteLayers(
              handle: _handle,
              layers: layerIds.map(_layerIds.toRust).toList(growable: false),
            )).toInt();
  }

  @override
  Future<String?> preflightDeleteLayers({required List<int> layerIds}) async {
    _requireOpen();
    if (layerIds.isEmpty ||
        layerIds.any((id) => id <= 0) ||
        layerIds.toSet().length != layerIds.length) {
      throw ArgumentError('delete requires unique positive layer IDs');
    }
    final ids = layerIds.map(_layerIds.toRust).toList(growable: false);
    final project = _projectHandle;
    if (project != null && _usingProjectHandle) {
      return rust.preflightDeleteProjectLayers(handle: project, layerIds: ids);
    }
    return rust.preflightDeleteLayers(handle: _handle, layers: ids);
  }

  @override
  Future<void> setLayersVisibility({
    required List<int> layerIds,
    required bool visible,
  }) async {
    _requireOpen();
    if (layerIds.isEmpty ||
        layerIds.any((id) => id <= 0) ||
        layerIds.toSet().length != layerIds.length) {
      throw ArgumentError('visibility requires unique layer IDs');
    }
    _revision =
        (await rust.setLayersVisibility(
          handle: _handle,
          layers: layerIds.map(_layerIds.toRust).toList(growable: false),
          visible: visible,
        )).toInt();
  }

  @override
  Future<void> setLayerSolo({required int? layerId}) async {
    _requireOpen();
    if (layerId != null && layerId <= 0) {
      throw ArgumentError('invalid solo layer ID');
    }
    _revision =
        (await rust.setLayerSolo(
          handle: _handle,
          layer: layerId == null ? null : _layerIds.toRust(layerId),
        )).toInt();
  }

  @override
  Future<LayerPanelStateView> layerPanelState() async {
    _requireOpen();
    final state = await rust.layerPanelState(handle: _handle);
    return LayerPanelStateView(
      primaryLayerId:
          state.primaryLayerId == null
              ? null
              : _layerIds.toDart(state.primaryLayerId!),
      collapsedGroupIds: state.collapsedGroupIds
          .map((id) => _layerIds.toDart(BigInt.parse(id)))
          .toList(growable: false),
    );
  }

  @override
  Future<void> setLayerPanelState({
    required int? primaryLayerId,
    required List<int> collapsedGroupIds,
  }) async {
    _requireOpen();
    final primary =
        primaryLayerId == null ? null : _layerIds.toRust(primaryLayerId);
    final collapsed = collapsedGroupIds
        .map(_layerIds.toRust)
        .toList(growable: false);
    _revision =
        (await rust.setLayerPanelState(
          handle: _handle,
          primaryLayerId: primary,
          collapsedGroupIds: collapsed,
        )).toInt();
  }

  @override
  Future<void> setLayersLocked({
    required List<int> layerIds,
    required bool locked,
  }) async {
    _requireOpen();
    if (layerIds.isEmpty ||
        layerIds.any((id) => id <= 0) ||
        layerIds.toSet().length != layerIds.length) {
      throw ArgumentError('lock requires unique layer IDs');
    }
    _revision =
        (await rust.setLayersLocked(
          handle: _handle,
          layers: layerIds.map(_layerIds.toRust).toList(growable: false),
          locked: locked,
        )).toInt();
  }

  @override
  Future<void> setLayersLabel({
    required List<int> layerIds,
    required int? labelRgba,
  }) async {
    _requireOpen();
    if (layerIds.isEmpty ||
        layerIds.any((id) => id <= 0) ||
        layerIds.toSet().length != layerIds.length ||
        (labelRgba != null && (labelRgba < 0 || labelRgba > 0xffffffff))) {
      throw ArgumentError('label requires unique layer IDs and valid color');
    }
    _revision =
        (await rust.setLayersLabel(
          handle: _handle,
          layers: layerIds.map(_layerIds.toRust).toList(growable: false),
          labelRgba: labelRgba,
        )).toInt();
  }

  @override
  Future<void> setLayerLocked({
    required int layerId,
    required bool locked,
  }) async {
    _requireOpen();
    if (layerId <= 0) throw ArgumentError.value(layerId, 'layerId');
    _revision =
        (await rust.setLayerLocked(
          handle: _handle,
          layer: _layerIds.toRust(layerId),
          locked: locked,
        )).toInt();
  }

  @override
  Future<void> setMaskEnabled({
    required int maskId,
    required bool enabled,
  }) async {
    _requireOpen();
    if (maskId <= 0) throw ArgumentError.value(maskId, 'maskId');
    _revision =
        (await rust.setMaskEnabled(
          handle: _handle,
          mask: _layerIds.toRust(maskId),
          enabled: enabled,
        )).toInt();
  }

  @override
  Future<void> setMaskInverted({
    required int maskId,
    required bool inverted,
  }) async {
    _requireOpen();
    if (maskId <= 0) throw ArgumentError.value(maskId, 'maskId');
    _revision =
        (await rust.setMaskInverted(
          handle: _handle,
          mask: _layerIds.toRust(maskId),
          inverted: inverted,
        )).toInt();
  }

  @override
  Future<void> applyLayerMask({required int maskId}) async {
    _requireOpen();
    if (maskId <= 0) throw ArgumentError.value(maskId, 'maskId');
    _revision =
        (await rust.applyLayerMask(
          handle: _handle,
          mask: _layerIds.toRust(maskId),
        )).toInt();
  }

  @override
  Future<int> duplicateLayer({required int layerId}) async {
    _requireOpen();
    if (layerId <= 0) throw ArgumentError('invalid layer ID');
    final project = _projectHandle;
    final duplicate =
        project != null && _usingProjectHandle
            ? await rust.duplicateProjectLayer(
              handle: project,
              source: _layerIds.toRust(layerId),
            )
            : await rust.duplicateLayer(
              handle: _handle,
              source: _layerIds.toRust(layerId),
            );
    return _layerIds.toDart(duplicate);
  }

  @override
  Future<List<int>> duplicateLayers({required List<int> layerIds}) async {
    _requireOpen();
    if (layerIds.length < 2 ||
        layerIds.any((id) => id <= 0) ||
        layerIds.toSet().length != layerIds.length) {
      throw ArgumentError('duplicate requires at least two unique layer IDs');
    }
    final sources = layerIds.map(_layerIds.toRust).toList(growable: false);
    final project = _projectHandle;
    final duplicates =
        project != null && _usingProjectHandle
            ? await rust.duplicateProjectLayers(
              handle: project,
              sources: sources,
            )
            : await rust.duplicateLayers(handle: _handle, sources: sources);
    return duplicates.map(_layerIds.toDart).toList(growable: false);
  }

  @override
  Future<int> groupLayers({required List<int> layerIds}) async {
    _requireOpen();
    if (layerIds.length < 2 ||
        layerIds.any((id) => id <= 0) ||
        layerIds.toSet().length != layerIds.length) {
      throw ArgumentError('group requires at least two unique layer IDs');
    }
    final members = layerIds.map(_layerIds.toRust).toList(growable: false);
    final reason = await rust.preflightGroupLayers(
      handle: _handle,
      members: members,
    );
    if (reason != null) {
      throw StateError(reason);
    }
    final group = await rust.groupLayers(handle: _handle, members: members);
    _revision++;
    return _layerIds.toDart(group);
  }

  @override
  Future<String?> preflightGroupLayers({required List<int> layerIds}) async {
    _requireOpen();
    if (layerIds.length < 2 ||
        layerIds.any((id) => id <= 0) ||
        layerIds.toSet().length != layerIds.length) {
      throw ArgumentError('group requires at least two unique layer IDs');
    }
    return rust.preflightGroupLayers(
      handle: _handle,
      members: layerIds.map(_layerIds.toRust).toList(growable: false),
    );
  }

  @override
  Future<void> ungroupLayer({required int groupId}) async {
    _requireOpen();
    if (groupId <= 0) throw ArgumentError.value(groupId, 'groupId');
    _revision =
        (await rust.ungroupLayer(
          handle: _handle,
          group: _layerIds.toRust(groupId),
        )).toInt();
  }

  @override
  Future<void> createPanelLayerTree({
    required int panelId,
    required int panelGroupId,
    required int maskLayerId,
    required int sketchLayerId,
    required int inkLayerId,
    required int colorLayerId,
    required int toneLayerId,
    required int effectsLayerId,
  }) async {
    _requireOpen();
    final ids = <int>[
      panelId,
      panelGroupId,
      maskLayerId,
      sketchLayerId,
      inkLayerId,
      colorLayerId,
      toneLayerId,
      effectsLayerId,
    ];
    if (ids.any((id) => id <= 0) || ids.toSet().length != ids.length) {
      throw ArgumentError('invalid panel layer tree IDs');
    }
    _revision =
        (await rust.createPanelLayerTree(
          handle: _handle,
          panel: BigInt.from(panelId),
          panelGroup: _layerIds.toRust(panelGroupId),
          mask: _layerIds.toRust(maskLayerId),
          sketch: _layerIds.toRust(sketchLayerId),
          ink: _layerIds.toRust(inkLayerId),
          color: _layerIds.toRust(colorLayerId),
          tone: _layerIds.toRust(toneLayerId),
          effects: _layerIds.toRust(effectsLayerId),
        )).toInt();
  }

  @override
  Future<void> setPanelMaskGeometry({
    required int maskLayerId,
    required List<double> points,
  }) async {
    _requireOpen();
    if (maskLayerId <= 0 ||
        points.length < 6 ||
        points.length > 128 ||
        !points.length.isEven ||
        points.any((value) => !value.isFinite)) {
      throw ArgumentError('invalid panel mask geometry');
    }
    _revision =
        (await rust.setPanelMaskGeometry(
          handle: _handle,
          mask: _layerIds.toRust(maskLayerId),
          points: points,
        )).toInt();
  }

  @override
  Future<void> setPanelFrames({
    required int layerId,
    required List<double> points,
    required List<int> pointCounts,
    required double borderPx,
  }) async {
    _requireOpen();
    if (layerId <= 0 ||
        pointCounts.length > 256 ||
        pointCounts.any((count) => count < 3 || count > 64) ||
        pointCounts.fold<int>(0, (sum, count) => sum + count) * 2 !=
            points.length ||
        points.any((value) => !value.isFinite) ||
        !borderPx.isFinite ||
        borderPx < 0 ||
        borderPx > 128) {
      throw ArgumentError('invalid panel frame layer data');
    }
    _revision =
        (await rust.setPanelFrames(
          handle: _handle,
          layer: _layerIds.toRust(layerId),
          points: points,
          pointCounts: pointCounts,
          borderPx: borderPx,
        )).toInt();
  }

  @override
  Future<void> mergeLayers({
    required int targetLayerId,
    required int sourceLayerId,
  }) async {
    _requireOpen();
    if (targetLayerId < 0 ||
        sourceLayerId < 0 ||
        targetLayerId == sourceLayerId) {
      throw ArgumentError('invalid layer merge');
    }
    _revision =
        (await rust.mergeLayers(
          handle: _handle,
          targetLayer: _layerIds.toRust(targetLayerId),
          sourceLayer: _layerIds.toRust(sourceLayerId),
        )).toInt();
  }

  @override
  Future<int> mergeLayersBulk({required List<int> layerIds}) async {
    _requireOpen();
    if (layerIds.length < 2 ||
        layerIds.any((id) => id <= 0) ||
        layerIds.toSet().length != layerIds.length) {
      throw ArgumentError('bulk merge requires unique layer IDs');
    }
    final ids = layerIds.map(_layerIds.toRust).toList(growable: false);
    final project = _projectHandle;
    final target =
        project != null && _usingProjectHandle
            ? await rust.mergeProjectLayersBulk(handle: project, layers: ids)
            : await rust.mergeLayersBulk(handle: _handle, layers: ids);
    return _layerIds.toDart(target);
  }

  @override
  Future<String?> preflightMergeLayers({
    required int targetLayerId,
    required int sourceLayerId,
  }) async {
    _requireOpen();
    if (targetLayerId <= 0 ||
        sourceLayerId <= 0 ||
        targetLayerId == sourceLayerId) {
      throw ArgumentError('invalid layer merge preflight');
    }
    final reason = await rust.preflightMergeLayers(
      handle: _handle,
      targetLayer: _layerIds.toRust(targetLayerId),
      sourceLayer: _layerIds.toRust(sourceLayerId),
    );
    return reason.isEmpty ? null : reason;
  }

  @override
  Future<void> selectRectangle({
    required double x0,
    required double y0,
    required double x1,
    required double y1,
  }) async {
    _requireOpen();
    _revision =
        (await rust.selectRectangle(
          handle: _handle,
          left: x0,
          top: y0,
          right: x1,
          bottom: y1,
        )).toInt();
  }

  @override
  Future<void> selectEllipse({
    required double centerX,
    required double centerY,
    required double radiusX,
    required double radiusY,
  }) async {
    _requireOpen();
    _revision =
        (await rust.selectEllipse(
          handle: _handle,
          centerX: centerX,
          centerY: centerY,
          radiusX: radiusX,
          radiusY: radiusY,
        )).toInt();
  }

  @override
  Future<void> selectLasso(List<double> points) async {
    _requireOpen();
    _revision =
        (await rust.selectLasso(handle: _handle, points: points)).toInt();
  }

  @override
  Future<void> selectLayerOpacity({
    required int layerId,
    required int minimumAlpha,
  }) async {
    _requireOpen();
    _revision =
        (await rust.selectLayerOpacity(
          handle: _handle,
          layerId: _layerIds.toRust(layerId),
          minimumAlpha: minimumAlpha,
        )).toInt();
  }

  @override
  Future<void> selectColorRange({
    required int layerId,
    required int red,
    required int green,
    required int blue,
    required int alpha,
    required int tolerance,
  }) async {
    _requireOpen();
    _revision =
        (await rust.selectColorRange(
          handle: _handle,
          layerId: _layerIds.toRust(layerId),
          red: red,
          green: green,
          blue: blue,
          alpha: alpha,
          tolerance: tolerance,
        )).toInt();
  }

  @override
  Future<void> clearSelection() async {
    _requireOpen();
    _revision = (await rust.clearSelection(handle: _handle)).toInt();
  }

  @override
  Future<void> invertSelection() async {
    _requireOpen();
    _revision = (await rust.invertSelection(handle: _handle)).toInt();
  }

  @override
  Future<void> growSelection(int radius) async {
    _requireOpen();
    if (radius < 1 || radius > 256) throw RangeError.range(radius, 1, 256);
    _revision =
        (await rust.growSelection(handle: _handle, radius: radius)).toInt();
  }

  @override
  Future<void> shrinkSelection(int radius) async {
    _requireOpen();
    if (radius < 1 || radius > 256) throw RangeError.range(radius, 1, 256);
    _revision =
        (await rust.shrinkSelection(handle: _handle, radius: radius)).toInt();
  }

  @override
  Future<void> fillRegion({
    required int layerId,
    required int x,
    required int y,
    required int red,
    required int green,
    required int blue,
    required int alpha,
    required int tolerance,
    required int gap,
  }) async {
    _requireOpen();
    if (layerId < 0 ||
        x < 0 ||
        y < 0 ||
        [red, green, blue, alpha].any((value) => value < 0 || value > 255) ||
        tolerance < 0 ||
        gap < 0) {
      throw ArgumentError('invalid fill region');
    }
    _revision =
        (await rust.fillRegion(
          handle: _handle,
          layerId: _layerIds.toRust(layerId),
          x: x,
          y: y,
          red: red,
          green: green,
          blue: blue,
          alpha: alpha,
          tolerance: tolerance,
          gap: gap,
        )).toInt();
  }

  @override
  Future<void> gradientFill({
    required int layerId,
    required int x,
    required int y,
    required double startX,
    required double startY,
    required double endX,
    required double endY,
    required int fromRed,
    required int fromGreen,
    required int fromBlue,
    required int fromAlpha,
    required int toRed,
    required int toGreen,
    required int toBlue,
    required int toAlpha,
    required int tolerance,
    required int gap,
    required int expansion,
    required bool paintInside,
    required bool paintUnfilled,
  }) async {
    _requireOpen();
    if (layerId < 0 ||
        x < 0 ||
        y < 0 ||
        [
          fromRed,
          fromGreen,
          fromBlue,
          fromAlpha,
          toRed,
          toGreen,
          toBlue,
          toAlpha,
        ].any((value) => value < 0 || value > 255) ||
        [startX, startY, endX, endY].any((value) => !value.isFinite) ||
        tolerance < 0 ||
        gap < 0 ||
        expansion < 0) {
      throw ArgumentError('invalid gradient fill');
    }
    _revision =
        (await rust.gradientFill(
          handle: _handle,
          layerId: _layerIds.toRust(layerId),
          x: x,
          y: y,
          startX: startX,
          startY: startY,
          endX: endX,
          endY: endY,
          fromRed: fromRed,
          fromGreen: fromGreen,
          fromBlue: fromBlue,
          fromAlpha: fromAlpha,
          toRed: toRed,
          toGreen: toGreen,
          toBlue: toBlue,
          toAlpha: toAlpha,
          tolerance: tolerance,
          gap: gap,
          expansion: expansion,
          paintInside: paintInside,
          paintUnfilled: paintUnfilled,
        )).toInt();
  }

  @override
  Future<void> perspectiveLayer({
    required int layerId,
    required List<double> target,
  }) async {
    _requireOpen();
    if (layerId < 0 ||
        target.length != 8 ||
        target.any((value) => !value.isFinite)) {
      throw ArgumentError('invalid perspective transform');
    }
    _revision =
        (await rust.perspectiveLayer(
          handle: _handle,
          layerId: _layerIds.toRust(layerId),
          target: target,
        )).toInt();
  }

  @override
  Future<void> meshLayer({
    required int layerId,
    required int columns,
    required int rows,
    required List<double> points,
  }) async {
    _requireOpen();
    if (layerId < 0 ||
        columns < 2 ||
        rows < 2 ||
        columns > 32 ||
        rows > 32 ||
        points.length != columns * rows * 2 ||
        points.any((value) => !value.isFinite)) {
      throw ArgumentError('invalid mesh transform');
    }
    _revision =
        (await rust.meshLayer(
          handle: _handle,
          layerId: _layerIds.toRust(layerId),
          columns: columns,
          rows: rows,
          points: points,
        )).toInt();
  }

  @override
  Future<void> liquifyLayer({
    required int layerId,
    required double centerX,
    required double centerY,
    required double radius,
    required double strength,
    required int mode,
    required double directionX,
    required double directionY,
  }) async {
    _requireOpen();
    if (layerId < 0 ||
        [
          centerX,
          centerY,
          radius,
          strength,
          directionX,
          directionY,
        ].any((value) => !value.isFinite) ||
        radius <= 0 ||
        mode < 0 ||
        mode > 3) {
      throw ArgumentError('invalid liquify transform');
    }
    _revision =
        (await rust.liquifyLayer(
          handle: _handle,
          layerId: _layerIds.toRust(layerId),
          centerX: centerX,
          centerY: centerY,
          radius: radius,
          strength: strength,
          mode: mode,
          directionX: directionX,
          directionY: directionY,
        )).toInt();
  }

  @override
  Future<void> addVectorStroke({
    required int layerId,
    required List<double> points,
    required bool closed,
  }) async {
    _requireOpen();
    if (layerId < 0 ||
        points.isEmpty ||
        points.length > 8_192 * 4 ||
        points.length % 4 != 0 ||
        points.any((value) => !value.isFinite)) {
      throw ArgumentError('invalid vector stroke');
    }
    _revision =
        (await rust.addVectorStroke(
          handle: _handle,
          layerId: _layerIds.toRust(layerId),
          points: points,
          closed: closed,
        )).toInt();
  }

  @override
  Future<void> transformLayer({
    required int layerId,
    required double a,
    required double b,
    required double c,
    required double d,
    required double tx,
    required double ty,
  }) async {
    _requireOpen();
    if (layerId < 0 || [a, b, c, d, tx, ty].any((value) => !value.isFinite)) {
      throw ArgumentError('invalid layer transform');
    }
    _revision =
        (await rust.transformLayer(
          handle: _handle,
          layerId: _layerIds.toRust(layerId),
          a: a,
          b: b,
          c: c,
          d: d,
          translateX: tx,
          translateY: ty,
        )).toInt();
  }

  @override
  Future<void> saveAs(String path) {
    _requireOpen();
    final project = _projectHandle;
    if (project != null) {
      return rust.saveProjectAs(handle: project, path: path);
    }
    return rust.saveDocument(handle: _handle, path: path);
  }

  @override
  Future<void> attachComicProject(Uint8List bytes) async {
    _requireOpen();
    _revision =
        (await rust.attachComicProject(handle: _handle, bytes: bytes)).toInt();
  }

  @override
  Future<Uint8List?> readComicProject() {
    _requireOpen();
    return rust.readComicProject(handle: _handle);
  }

  @override
  Future<void> exportPng(String path) {
    _requireOpen();
    return rust.exportPng(handle: _handle, path: path);
  }

  @override
  Future<void> exportTimeLapse(String path) {
    _requireOpen();
    if (path.isEmpty) throw ArgumentError('invalid time-lapse export');
    return rust.exportTimeLapse(handle: _handle, path: path);
  }

  @override
  Future<void> exportDocument({required String path, required String format}) {
    _requireOpen();
    final kind = switch (format.toLowerCase()) {
      'png' => rust.ExportKind.png,
      'jpg' || 'jpeg' => rust.ExportKind.jpeg,
      'webp' => rust.ExportKind.webp,
      'ora' || 'openraster' => rust.ExportKind.openRaster,
      'svg' => rust.ExportKind.svg,
      'psd' => rust.ExportKind.psd,
      _ => throw ArgumentError.value(format, 'format'),
    };
    return rust.exportDocument(handle: _handle, path: path, format: kind);
  }

  @override
  Future<List<BrushSummaryView>> builtinBrushes() async {
    _requireOpen();
    final summaries = await rust.brushes(handle: _handle);
    return summaries
        .map((summary) {
          if (summary.id.isNegative ||
              summary.id > BigInt.from(_maxSafeLayerId)) {
            throw StateError('brush identifier exceeds Dart safety range');
          }
          return BrushSummaryView(
            id: summary.id.toInt(),
            name: summary.name,
            isBuiltin: summary.isBuiltin,
            tags: List<String>.unmodifiable(summary.tags),
            diameterPx: summary.diameterPx,
            opacity: summary.opacity,
            spacing: summary.spacing,
            smoothing: summary.smoothing,
            pressureSize: summary.pressureSize,
            pressureOpacity: summary.pressureOpacity,
            hardness: summary.hardness,
            textureScale: summary.textureScale,
            scatter: summary.scatter,
            rotationJitter: summary.rotationJitter,
            smudge: summary.smudge,
            wetness: summary.wetness,
            colorRgba: summary.colorRgba,
            pressureCurvePoints: List<double>.unmodifiable(
              summary.pressureCurvePoints,
            ),
            tipResourceHash:
                summary.tipResourceHash == null
                    ? null
                    : Uint8List.fromList(summary.tipResourceHash!),
            grainResourceHash:
                summary.grainResourceHash == null
                    ? null
                    : Uint8List.fromList(summary.grainResourceHash!),
          );
        })
        .toList(growable: false);
  }

  @override
  Future<List<LayerSummaryView>> layerSummaries() async {
    _requireOpen();
    final summaries = await rust.layerSummaries(handle: _handle);
    return summaries
        .map((summary) {
          final parent = summary.parent;
          return LayerSummaryView(
            id: _layerIds.toDart(summary.id),
            parent: parent == null ? null : _layerIds.toDart(parent),
            maskOwner:
                summary.maskOwner == null
                    ? null
                    : _layerIds.toDart(summary.maskOwner!),
            maskEnabled: summary.maskEnabled,
            maskInverted: summary.maskInverted,
            order: summary.order,
            name: summary.name,
            kind: summary.kind,
            opacity: summary.opacity / 65535,
            visible: summary.visible,
            blendMode: summary.blendMode,
            groupMode: summary.groupMode,
            alphaLock: summary.alphaLock,
            locked: summary.locked,
            clipping: summary.clipping,
            reference: summary.reference,
            labelRgba: summary.labelRgba,
            adjustmentBrightness: summary.adjustmentBrightness,
            adjustmentContrast: summary.adjustmentContrast,
            canDrag: summary.canDrag,
            dragReason: summary.dragReason,
            canReceiveLayers: summary.canReceiveLayers,
            receiveReason: summary.receiveReason,
            canEditProperties: summary.canEditProperties,
            editPropertiesReason: summary.editPropertiesReason,
            canDuplicate: summary.canDuplicate,
            duplicateReason: summary.duplicateReason,
            canDelete: summary.canDelete,
            deleteReason: summary.deleteReason,
            canUngroup: summary.canUngroup,
            ungroupReason: summary.ungroupReason,
            canApplyMask: summary.canApplyMask,
            applyMaskReason: summary.applyMaskReason,
            hasMergeDownCapability: true,
            mergeDownReason: summary.mergeDownReason,
          );
        })
        .toList(growable: false);
  }

  @override
  Future<List<VectorStrokeSummaryView>> vectorStrokeSummaries({
    required int layerId,
  }) async {
    _requireOpen();
    if (layerId < 0) throw ArgumentError('invalid vector layer');
    final summaries = await rust.vectorStrokeSummaries(
      handle: _handle,
      layerId: _layerIds.toRust(layerId),
    );
    return summaries
        .map(
          (summary) => VectorStrokeSummaryView(
            id: _safeId(summary.id, 'vector stroke'),
            pointCount: summary.pointCount,
            points: List<double>.unmodifiable(summary.points),
            minX: summary.minX,
            minY: summary.minY,
            maxX: summary.maxX,
            maxY: summary.maxY,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<void> updateLayerProperties({
    required int layerId,
    required bool visible,
    required double opacity,
    required bool alphaLock,
    required bool clipping,
    required bool reference,
  }) async {
    _requireOpen();
    if (layerId < 0 || !opacity.isFinite || opacity < 0 || opacity > 1) {
      throw ArgumentError('invalid layer properties');
    }
    _revision =
        (await rust.updateLayerProperties(
          handle: _handle,
          layerId: _layerIds.toRust(layerId),
          visible: visible,
          opacity: (opacity * 65535).round(),
          alphaLock: alphaLock,
          clipping: clipping,
          reference: reference,
        )).toInt();
  }

  @override
  Future<int> beginLayerOpacityEdit({required int layerId}) async {
    _requireOpen();
    if (layerId <= 0) throw ArgumentError.value(layerId, 'layerId');
    return (await rust.beginLayerOpacityEdit(
      handle: _handle,
      layerId: _layerIds.toRust(layerId),
    )).toInt();
  }

  @override
  Future<void> updateLayerOpacityEdit({
    required int editId,
    required double opacity,
  }) async {
    _requireOpen();
    if (editId <= 0 || !opacity.isFinite || opacity < 0 || opacity > 1) {
      throw ArgumentError('invalid opacity edit');
    }
    _revision =
        (await rust.updateLayerOpacityEdit(
          handle: _handle,
          editId: BigInt.from(editId),
          opacity: (opacity * 65535).round(),
        )).toInt();
  }

  @override
  Future<void> commitLayerOpacityEdit({required int editId}) async {
    _requireOpen();
    if (editId <= 0) throw ArgumentError.value(editId, 'editId');
    _revision =
        (await rust.commitLayerOpacityEdit(
          handle: _handle,
          editId: BigInt.from(editId),
        )).toInt();
  }

  @override
  Future<void> cancelLayerOpacityEdit({required int editId}) async {
    _requireOpen();
    if (editId <= 0) throw ArgumentError.value(editId, 'editId');
    _revision =
        (await rust.cancelLayerOpacityEdit(
          handle: _handle,
          editId: BigInt.from(editId),
        )).toInt();
  }

  @override
  Future<void> updateLayerPresentation({
    required int layerId,
    required String name,
    required String blendMode,
    required String groupMode,
    required int? labelRgba,
  }) async {
    _requireOpen();
    const modes = <String>{
      'Normal',
      'Multiply',
      'Screen',
      'Overlay',
      'Darken',
      'Lighten',
      'Add',
      'Subtract',
      'Color Burn',
      'Linear Burn',
      'Color Dodge',
      'Soft Light',
      'Hard Light',
      'Difference',
      'Exclusion',
      'Divide',
    };
    if (layerId < 0 ||
        name.length > 128 ||
        !modes.contains(blendMode) ||
        !{'Isolated', 'Pass-through'}.contains(groupMode)) {
      throw ArgumentError('invalid layer presentation');
    }
    if (labelRgba != null && (labelRgba < 0 || labelRgba > 0xffffffff)) {
      throw ArgumentError('invalid layer label');
    }
    final mode = switch (blendMode) {
      'Normal' => 0,
      'Multiply' => 1,
      'Screen' => 2,
      'Overlay' => 3,
      'Darken' => 4,
      'Lighten' => 5,
      'Add' => 6,
      'Subtract' => 7,
      'Color Burn' => 8,
      'Linear Burn' => 9,
      'Color Dodge' => 10,
      'Soft Light' => 11,
      'Hard Light' => 12,
      'Difference' => 13,
      'Exclusion' => 14,
      'Divide' => 15,
      _ => throw ArgumentError('unknown blend mode'),
    };
    final groupModeValue = switch (groupMode) {
      'Isolated' => 0,
      'Pass-through' => 1,
      _ => throw ArgumentError('unknown group mode'),
    };
    _revision =
        (await rust.updateLayerPresentation(
          handle: _handle,
          layerId: _layerIds.toRust(layerId),
          name: name,
          blendMode: mode,
          groupMode: groupModeValue,
          labelRgba: labelRgba,
        )).toInt();
  }

  @override
  Future<void> setLayerBrightnessContrast({
    required int layerId,
    required int brightness,
    required int contrast,
  }) async {
    _requireOpen();
    if (layerId < 0 ||
        brightness < -100 ||
        brightness > 100 ||
        contrast < -100 ||
        contrast > 100) {
      throw ArgumentError('invalid adjustment settings');
    }
    _revision =
        (await rust.setLayerBrightnessContrast(
          handle: _handle,
          layerId: _layerIds.toRust(layerId),
          brightness: brightness,
          contrast: contrast,
        )).toInt();
  }

  @override
  Future<TileUpdateBatch> drainTileUpdates() async {
    _requireOpen();
    final decoded = decodeTileUpdatePacket(
      await rust.drainTileUpdates(handle: _handle),
      projectLayerId: _layerIds.toDart,
    );
    // A tile poll may intentionally return an empty batch while the CPU
    // renderer owns the document state lock. Do not follow it with a blocking
    // revision() call; retain the last observed revision and pick up newer
    // revisions with the next nonblocking tile poll.
    _revision = math.max(_revision, decoded.revision);
    return TileUpdateBatch(
      revision: _revision,
      fullRedraw: decoded.fullRedraw,
      tiles: decoded.tiles,
      acknowledgements: decoded.acknowledgements,
    );
  }

  @override
  Future<List<StrokeAcknowledgement>> drainStrokeAcknowledgements() async {
    _requireOpen();
    return decodeStrokeAcknowledgementPacket(
      await rust.drainStrokeAcknowledgements(handle: _handle),
    );
  }

  @override
  Future<int> drainLiveDabOverflowCount() async {
    _requireOpen();
    return (await rust.drainLiveDabOverflowCount(handle: _handle)).toInt();
  }

  @override
  Future<Uint8List> readTile({
    required int layer,
    required int x,
    required int y,
  }) {
    _requireOpen();
    return rust.readTile(
      handle: _handle,
      layer: _layerIds.toRust(layer),
      x: x,
      y: y,
    );
  }

  @override
  Future<Uint8List> readCompositeTile({required int x, required int y}) {
    _requireOpen();
    return rust.readCompositeTile(handle: _handle, x: x, y: y);
  }

  @override
  Future<CompositeTileSnapshot> readCompositeTilesSnapshot({
    required List<StrokeTileCoordinate> coordinates,
  }) async {
    _requireOpen();
    if (coordinates.length > maxCompositeTileSnapshotTiles) {
      throw ArgumentError('too many composite tiles in one immutable snapshot');
    }
    final flatCoordinates = <int>[];
    for (final coordinate in coordinates) {
      flatCoordinates
        ..add(coordinate.x)
        ..add(coordinate.y);
    }
    final captured = await rust.captureCompositeTilesSnapshot(
      handle: _handle,
      coordinates: flatCoordinates,
    );
    // Pixel composition runs against a separate immutable Rust handle. The
    // expensive work must not retain the document's opaque bridge lock, which
    // would serialize incoming Pencil and touch packets behind tile reads.
    final packet = await rust.composeCompositeTilesSnapshot(
      snapshotHandle: captured,
    );
    return decodeCompositeTileSnapshot(packet);
  }

  @override
  Future<Uint8List> readLayerThumbnail({
    required int layerId,
    int size = 48,
  }) async {
    _requireOpen();
    if (layerId < 0 || size < 16 || size > 128) {
      throw ArgumentError('invalid layer thumbnail');
    }
    final bytes = await rust.readLayerThumbnail(
      handle: _handle,
      layer: _layerIds.toRust(layerId),
      size: size,
    );
    if (bytes.length != size * size * 4) {
      throw StateError('layer thumbnail payload has an invalid length');
    }
    return Uint8List.fromList(bytes);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final pendingProject = _pendingRecoveryStudioProject;
    _pendingRecoveryStudioProject = null;
    if (pendingProject != null) {
      await rust.closeStudioProject(handle: pendingProject);
    }
    final fallback = _fallbackHandle;
    if (_usingProjectHandle && fallback != null) {
      await rust.closeDocument(handle: fallback);
    } else {
      await rust.closeDocument(handle: _handle);
    }
  }
}
