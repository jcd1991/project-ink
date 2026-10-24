import 'dart:convert';
import 'dart:typed_data';

import '../generated/api.dart' as rust;
import 'engine_api_contract.dart';
import 'engine_api_models.dart';
import 'layer_id_projection.dart';
import '../../tools/brush_library.dart'
    show BrushCurvePointView, BrushPreviewPointView;

const int _additionalBuiltinBrushIdBase = 4000000000000000;
const List<double> _starterPressureCurvePoints = <double>[
  0,
  0,
  0.003,
  0.005,
  0.006,
  0.02,
  0.01,
  0.08,
  0.015,
  0.3,
  0.02,
  0.45,
  0.04,
  0.63,
  0.08,
  0.78,
  0.15,
  0.9,
  0.3,
  0.99,
  1,
  1,
];
const List<double> _technicalPenPressureCurvePoints = <double>[
  0,
  0.12,
  .003,
  .13,
  .006,
  .15,
  .01,
  .2,
  .015,
  .24,
  .02,
  .27,
  .04,
  .32,
  .08,
  .36,
  .12,
  .4,
  .2,
  .56,
  .3,
  .75,
  .42,
  .9,
  .55,
  .96,
  1,
  1,
];

class InMemoryEngineApi implements EngineApi {
  InMemoryEngineApi();

  int _revision = 0;
  int _nextLayerId = 2;
  final List<LayerSummaryView> _layers = <LayerSummaryView>[
    const LayerSummaryView(id: 1, name: 'Paint Layer 1', kind: 'Raster'),
  ];
  int? activeBrushColorRgba;
  int _nextOpacityEditId = 1;
  int _nextAdjustmentEditId = 1;
  final Map<int, int> _adjustmentEdits = <int, int>{};
  int _nextBrushDraft = 1;
  final Set<int> _brushDrafts = <int>{};
  final Map<int, Map<BrushPressureTargetView, BrushPressureResponseView>>
  _pressureResponseDrafts = {};
  Uint8List? _comicBytes;
  LayerPanelStateView _layerPanelState = const LayerPanelStateView(
    primaryLayerId: 1,
  );

  @override
  final DocumentInfo documentInfo = const DocumentInfo(
    widthPx: 2048,
    heightPx: 2048,
    dpi: 300,
    primaryRasterLayer: 1,
  );

  @override
  int layerIdForUi(BigInt rustLayerId) {
    if (rustLayerId.isNegative ||
        rustLayerId > BigInt.from(LayerIdProjection.maxSafeId)) {
      throw StateError('in-memory layer ID exceeds its supported range');
    }
    return rustLayerId.toInt();
  }

  @override
  Future<void> beginStroke() async => _revision++;

  @override
  Future<void> beginBrushStroke(int brushId) async => beginStroke();

  @override
  Future<void> beginBrushStrokeOnLayer(int brushId, int layerId) async =>
      beginBrushStroke(brushId);

  @override
  Future<void> updateBrushColor({
    required int brushId,
    required int red,
    required int green,
    required int blue,
    required int alpha,
  }) async {
    if (brushId < 0 ||
        [red, green, blue, alpha].any((value) => value < 0 || value > 255)) {
      throw ArgumentError('invalid brush color');
    }
    _revision++;
  }

  @override
  Future<void> setActiveBrushColor({
    required int red,
    required int green,
    required int blue,
    required int alpha,
  }) async {
    if ([red, green, blue, alpha].any((value) => value < 0 || value > 255)) {
      throw ArgumentError('invalid active brush color');
    }
    activeBrushColorRgba = (red << 24) | (green << 16) | (blue << 8) | alpha;
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
    required bool pulledString,
    required double stabilizerDistancePx,
    required bool catchUpOnEnd,
  }) async {
    if (brushId < 0 ||
        !diameter.isFinite ||
        !opacity.isFinite ||
        !spacing.isFinite ||
        !smoothing.isFinite ||
        !pressureSize.isFinite ||
        !pressureOpacity.isFinite ||
        !pressureCurve.isFinite ||
        !hardness.isFinite ||
        !textureScale.isFinite ||
        !scatter.isFinite ||
        !rotationJitter.isFinite ||
        !smudge.isFinite ||
        !wetness.isFinite) {
      throw ArgumentError('invalid brush settings');
    }
    _validateCurvePoints(pressureCurvePoints);
    if (!stabilizerDistancePx.isFinite ||
        stabilizerDistancePx < 0 ||
        stabilizerDistancePx > 100 ||
        (!pulledString && catchUpOnEnd)) {
      throw ArgumentError('invalid path stabilizer settings');
    }
  }

  @override
  Future<void> updateBrushPressureResponse({
    required int draftId,
    required BrushPressureTargetView target,
    required double amount,
    required bool enabled,
    required List<BrushCurvePointView> curvePoints,
  }) async {
    if (!_brushDrafts.contains(draftId) ||
        !amount.isFinite ||
        amount < 0 ||
        amount > 1) {
      throw ArgumentError('invalid pressure response');
    }
    _validateCurvePoints(curvePoints);
    _pressureResponseDrafts.putIfAbsent(
      draftId,
      () => {},
    )[target] = BrushPressureResponseView(
      target: target,
      curvePoints: List<double>.unmodifiable(
        curvePoints.expand((point) => [point.x, point.y]),
      ),
      amount: amount,
      enabled: enabled,
      replace: false,
      editable: true,
    );
  }

  @override
  Future<int> beginBrushDraft(int brushId) async {
    if (brushId < 0) throw ArgumentError('invalid brush draft brush');
    final id = _nextBrushDraft++;
    _brushDrafts.add(id);
    _pressureResponseDrafts[id] = {};
    return id;
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
    required bool pulledString,
    required double stabilizerDistancePx,
    required bool catchUpOnEnd,
  }) async {
    if (!_brushDrafts.contains(draftId)) {
      throw StateError('brush draft is not active');
    }
    await updateBrushSettings(
      brushId: 0,
      diameter: diameter,
      opacity: opacity,
      spacing: spacing,
      smoothing: smoothing,
      pressureSize: pressureSize,
      pressureOpacity: pressureOpacity,
      pressureCurve: pressureCurve,
      pressureCurvePoints: pressureCurvePoints,
      hardness: hardness,
      textureScale: textureScale,
      scatter: scatter,
      rotationJitter: rotationJitter,
      smudge: smudge,
      wetness: wetness,
      pulledString: pulledString,
      stabilizerDistancePx: stabilizerDistancePx,
      catchUpOnEnd: catchUpOnEnd,
    );
  }

  @override
  Future<void> commitBrushDraft(int draftId) async {
    if (!_brushDrafts.remove(draftId)) {
      throw StateError('brush draft is not active');
    }
    _pressureResponseDrafts.remove(draftId);
  }

  @override
  Future<void> updateLayerPresentation({
    required int layerId,
    required String name,
    required String blendMode,
    required String groupMode,
    required int? labelRgba,
  }) async {
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
    final index = _layers.indexWhere((layer) => layer.id == layerId);
    if (index >= 0) {
      final old = _layers[index];
      _layers[index] = LayerSummaryView(
        id: old.id,
        name: name,
        kind: old.kind,
        order: old.order,
        parent: old.parent,
        maskOwner: old.maskOwner,
        maskEnabled: old.maskEnabled,
        maskInverted: old.maskInverted,
        opacity: old.opacity,
        visible: old.visible,
        blendMode: blendMode,
        groupMode: groupMode,
        alphaLock: old.alphaLock,
        locked: old.locked,
        clipping: old.clipping,
        reference: old.reference,
        labelRgba: labelRgba,
      );
    }
    _revision++;
  }

  @override
  Future<void> setLayerBrightnessContrast({
    required int layerId,
    required int brightness,
    required int contrast,
  }) async {
    if (layerId < 0 ||
        brightness < -100 ||
        brightness > 100 ||
        contrast < -100 ||
        contrast > 100) {
      throw ArgumentError('invalid adjustment settings');
    }
    _revision++;
  }

  @override
  Future<int> beginLayerAdjustmentEdit({required int layerId}) async {
    final layer = _layers.where((candidate) => candidate.id == layerId);
    if (layer.isEmpty || layer.first.kind != 'Adjustment') {
      throw ArgumentError('adjustment preview requires an adjustment layer');
    }
    final id = _nextAdjustmentEditId++;
    _adjustmentEdits[id] = layerId;
    return id;
  }

  @override
  Future<void> updateLayerAdjustmentEdit({
    required int editId,
    required String adjustmentJson,
  }) async {
    final layerId = _adjustmentEdits[editId];
    if (layerId == null || adjustmentJson.length > 4096) {
      throw ArgumentError('invalid adjustment preview');
    }
    final decoded = jsonDecode(adjustmentJson);
    if (decoded is! Map<String, dynamic> || decoded.length != 1) {
      throw ArgumentError('invalid adjustment preview payload');
    }
    // The in-memory adapter has no compositor; accept the transaction without
    // replacing the layer summary and losing unrelated projected properties.
    _revision++;
  }

  @override
  Future<void> commitLayerAdjustmentEdit({required int editId}) async {
    if (_adjustmentEdits.remove(editId) == null) {
      throw ArgumentError('adjustment edit is no longer active');
    }
    _revision++;
  }

  @override
  Future<void> cancelLayerAdjustmentEdit({required int editId}) async {
    if (_adjustmentEdits.remove(editId) == null) return;
    _revision++;
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
    if (layerId < 0 ||
        strokeId < 0 ||
        index < 0 ||
        [x, y, pressure, tilt].any((value) => !value.isFinite) ||
        pressure < 0 ||
        pressure > 1) {
      throw ArgumentError('invalid vector control point');
    }
    _revision++;
  }

  @override
  Future<void> cancelBrushDraft(int draftId) async {
    if (!_brushDrafts.remove(draftId)) {
      throw StateError('brush draft is not active');
    }
    _pressureResponseDrafts.remove(draftId);
  }

  @override
  Future<Uint8List> renderBrushPreview({
    required int brushId,
    required int width,
    required int height,
    required List<BrushPreviewPointView> points,
  }) async => Uint8List.fromList(
    base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a7HcAAAAASUVORK5CYII=',
    ),
  );

  @override
  Future<void> exportBrush({required int brushId, required String path}) async {
    if (brushId < 0 || path.isEmpty) {
      throw ArgumentError('invalid brush export');
    }
  }

  @override
  Future<int> duplicateBrush(int brushId) async {
    if (brushId < 0) throw ArgumentError.value(brushId, 'brushId');
    _revision++;
    return brushId + 1000;
  }

  @override
  Future<void> renameBrush({required int brushId, required String name}) async {
    if (brushId < 13 || name.trim().isEmpty || name.trim().length > 256) {
      throw ArgumentError('invalid custom brush name');
    }
    _revision++;
  }

  @override
  Future<BrushImportInspectionView> inspectBrushImport(String path) async {
    if (path.isEmpty) throw ArgumentError('invalid brush inspection path');
    return BrushImportInspectionView(
      sourceFormat: 'Image',
      sourceSha256: Uint8List(0),
      bytes: 0,
      fidelity: 'Approximate',
      importerVersion: 'in-memory-test',
    );
  }

  @override
  Future<PsdImportInspectionView> inspectPsdImport(String path) async {
    if (path.isEmpty) throw ArgumentError('invalid PSD inspection path');
    return const PsdImportInspectionView(
      widthPx: 256,
      heightPx: 256,
      depth: 8,
      layerCount: 1,
      editableImportAvailable: false,
      flattenedImportAvailable: true,
      supportedFeatures: <String>['RGB 8-bit composite'],
      incompatibilities: <String>['Editable PSD conversion is not available.'],
      flattenedImportIssues: <String>[],
      estimatedEditableWorkingSetBytes: 0,
      estimatedFlattenedWorkingSetBytes: 0,
    );
  }

  @override
  Future<EngineApi> openEditablePsdCandidate(String path) async =>
      throw UnsupportedError(
        'Editable PSD candidates require the Rust engine.',
      );

  @override
  Future<BrushImportReportView> convertBrushImport(String path) async {
    if (path.isEmpty) throw ArgumentError('invalid brush conversion path');
    return BrushImportReportView(
      sourceFormat: 'Image',
      sourceSha256: Uint8List(0),
      importerVersion: 'in-memory-test',
      fidelity: 'Approximate',
      mappings: <String>[],
      omitted: <String>[],
      warnings: <String>['Preview is provided by the in-memory test engine.'],
      resourceCount: 0,
      previewWidth: 0,
      previewHeight: 0,
      brushCount: 1,
    );
  }

  @override
  Future<BrushImportStageView> stageBrushImport(String path) async {
    if (path.isEmpty) throw ArgumentError('invalid brush staging path');
    final inspection = await inspectBrushImport(path);
    return BrushImportStageView(
      operationId: 1,
      inspection: inspection,
      expiresInSeconds: 600,
    );
  }

  @override
  Future<BrushImportReportView> convertStagedBrushImport(int operationId) {
    if (operationId <= 0) throw ArgumentError('invalid brush operation');
    return convertBrushImport('staged');
  }

  @override
  Future<int> commitStagedBrushImport(int operationId) async {
    if (operationId <= 0) throw ArgumentError('invalid brush operation');
    return importBrush('staged');
  }

  @override
  Future<void> discardStagedBrushImport(int operationId) async {
    if (operationId <= 0) throw ArgumentError('invalid brush operation');
  }

  @override
  Future<int> importBrush(String path) async {
    if (path.isEmpty) {
      throw ArgumentError('invalid brush import path');
    }
    return 13;
  }

  @override
  Future<int> importBrushVerified(String path, Uint8List sourceSha256) async {
    if (path.isEmpty || sourceSha256.length != 32) {
      throw ArgumentError('invalid brush verification hash');
    }
    return importBrush(path);
  }

  @override
  Future<List<int>> importBrushPackVerified(
    String path,
    Uint8List sourceSha256,
  ) async {
    if (path.isEmpty || sourceSha256.length != 32) {
      throw ArgumentError('invalid brush pack verification hash');
    }
    return <int>[13, 14];
  }

  @override
  Future<List<int>> importKritaBundleVerified(
    String path,
    Uint8List sourceSha256,
  ) async {
    if (path.isEmpty || sourceSha256.length != 32) {
      throw ArgumentError('invalid Krita bundle verification hash');
    }
    return <int>[13, 14];
  }

  @override
  Future<List<int>> importPhotoshopAbrVerified(
    String path,
    Uint8List sourceSha256,
  ) async {
    if (path.isEmpty || sourceSha256.length != 32) {
      throw ArgumentError('invalid Photoshop ABR verification hash');
    }
    return <int>[13, 14];
  }

  @override
  Future<void> endStroke() async => _revision++;

  @override
  Future<void> cancelStroke() async => _revision++;

  @override
  int get revision => _revision;

  @override
  Future<void> pushPointerPacket(Uint8List packet) async => _revision++;

  @override
  Future<void> undo() async => _revision++;

  @override
  Future<void> redo() async => _revision++;

  @override
  Future<rust.HistorySnapshotView> historySnapshot({int limit = 100}) async =>
      rust.HistorySnapshotView(
        revision: BigInt.from(_revision),
        cursor: 0,
        entries: const <rust.HistoryEntryView>[],
        wasTrimmed: false,
      );

  @override
  Future<void> navigateHistory(int sequence) async {
    if (sequence != 0) throw RangeError('history sequence is not available');
    _revision++;
  }

  @override
  Future<int> addLayer({required String kind}) async {
    const valid = <String>{
      'Raster',
      'VectorInk',
      'Group',
      'Mask',
      'Tone',
      'PanelGroup',
      'Adjustment',
    };
    if (!valid.contains(kind)) throw ArgumentError('unknown layer kind');
    _revision++;
    final id = _nextLayerId++;
    _layers.add(LayerSummaryView(id: id, name: kind, kind: kind));
    return id;
  }

  @override
  Future<int> addLayerToParent({
    required String kind,
    required int parentId,
  }) async {
    if (parentId < 0) throw ArgumentError('invalid layer parent');
    const valid = <String>{
      'Raster',
      'VectorInk',
      'Group',
      'Mask',
      'Tone',
      'PanelGroup',
      'Adjustment',
    };
    if (!valid.contains(kind)) throw ArgumentError('unknown layer kind');
    _revision++;
    final id = _nextLayerId++;
    _layers.add(
      LayerSummaryView(id: id, name: kind, kind: kind, parent: parentId),
    );
    return id;
  }

  @override
  Future<void> moveLayer({
    required int layerId,
    required int? parentId,
    required int index,
  }) async {
    if (layerId < 0 || (parentId != null && parentId < 0) || index < 0) {
      throw ArgumentError('invalid layer move');
    }
    _revision++;
  }

  @override
  Future<void> reorderLayers({
    required List<int> layerIds,
    required int index,
  }) async {
    if (layerIds.isEmpty ||
        layerIds.any((id) => id <= 0) ||
        layerIds.toSet().length != layerIds.length ||
        index < 0) {
      throw ArgumentError(
        'reorder requires unique IDs and a non-negative index',
      );
    }
    _revision++;
  }

  @override
  Future<void> deleteLayer({required int layerId}) async {
    if (layerId <= 0) throw ArgumentError('invalid layer ID');
    _layers.removeWhere((layer) => layer.id == layerId);
    _revision++;
  }

  @override
  Future<void> clearLayer({required int layerId}) async {
    if (layerId <= 0) throw ArgumentError('invalid layer ID');
    _revision++;
  }

  @override
  Future<void> deleteLayers({required List<int> layerIds}) async {
    if (layerIds.isEmpty ||
        layerIds.any((id) => id <= 0) ||
        layerIds.toSet().length != layerIds.length) {
      throw ArgumentError('delete requires unique layer IDs');
    }
    _layers.removeWhere((layer) => layerIds.contains(layer.id));
    _revision++;
  }

  @override
  Future<String?> preflightDeleteLayers({required List<int> layerIds}) async {
    if (layerIds.isEmpty ||
        layerIds.any((id) => id <= 0) ||
        layerIds.toSet().length != layerIds.length) {
      throw ArgumentError('delete requires unique positive layer IDs');
    }
    return null;
  }

  @override
  Future<void> setLayersVisibility({
    required List<int> layerIds,
    required bool visible,
  }) async {
    if (layerIds.isEmpty ||
        layerIds.any((id) => id <= 0) ||
        layerIds.toSet().length != layerIds.length) {
      throw ArgumentError('visibility requires unique layer IDs');
    }
    _revision++;
  }

  @override
  Future<void> setLayerSolo({required int? layerId}) async {
    if (layerId != null && layerId <= 0) {
      throw ArgumentError('invalid solo layer ID');
    }
    _revision++;
  }

  @override
  Future<LayerPanelStateView> layerPanelState() async => _layerPanelState;

  @override
  Future<void> setLayerPanelState({
    required int? primaryLayerId,
    required List<int> collapsedGroupIds,
  }) async {
    if ((primaryLayerId != null && primaryLayerId <= 0) ||
        collapsedGroupIds.any((id) => id <= 0) ||
        collapsedGroupIds.toSet().length != collapsedGroupIds.length) {
      throw ArgumentError('invalid layer-panel state');
    }
    final collapsed = collapsedGroupIds.toList()..sort();
    final candidate = LayerPanelStateView(
      primaryLayerId: primaryLayerId,
      collapsedGroupIds: List<int>.unmodifiable(collapsed),
    );
    if (candidate.primaryLayerId == _layerPanelState.primaryLayerId &&
        _sameIds(
          candidate.collapsedGroupIds,
          _layerPanelState.collapsedGroupIds,
        )) {
      return;
    }
    _layerPanelState = candidate;
    _revision++;
  }

  bool _sameIds(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }

  @override
  Future<void> setLayersLocked({
    required List<int> layerIds,
    required bool locked,
  }) async {
    if (layerIds.isEmpty ||
        layerIds.any((id) => id <= 0) ||
        layerIds.toSet().length != layerIds.length) {
      throw ArgumentError('lock requires unique layer IDs');
    }
    _revision++;
  }

  @override
  Future<void> setLayersLabel({
    required List<int> layerIds,
    required int? labelRgba,
  }) async {
    if (layerIds.isEmpty ||
        layerIds.any((id) => id <= 0) ||
        layerIds.toSet().length != layerIds.length ||
        (labelRgba != null && (labelRgba < 0 || labelRgba > 0xffffffff))) {
      throw ArgumentError('label requires unique layer IDs and valid color');
    }
    _revision++;
  }

  @override
  Future<void> setLayerLocked({
    required int layerId,
    required bool locked,
  }) async {
    if (layerId <= 0) throw ArgumentError.value(layerId, 'layerId');
    _revision++;
  }

  @override
  Future<void> setMaskEnabled({
    required int maskId,
    required bool enabled,
  }) async {
    if (maskId <= 0) throw ArgumentError.value(maskId, 'maskId');
    _revision++;
  }

  @override
  Future<void> setMaskInverted({
    required int maskId,
    required bool inverted,
  }) async {
    if (maskId <= 0) throw ArgumentError.value(maskId, 'maskId');
    _revision++;
  }

  @override
  Future<void> applyLayerMask({required int maskId}) async {
    if (maskId <= 0) throw ArgumentError.value(maskId, 'maskId');
    _revision++;
  }

  @override
  Future<int> duplicateLayer({required int layerId}) async {
    if (layerId <= 0) throw ArgumentError('invalid layer ID');
    return ++_revision;
  }

  @override
  Future<List<int>> duplicateLayers({required List<int> layerIds}) async {
    if (layerIds.length < 2 ||
        layerIds.any((id) => id <= 0) ||
        layerIds.toSet().length != layerIds.length) {
      throw ArgumentError('duplicate requires at least two unique layer IDs');
    }
    final first = _revision + 1;
    _revision++;
    return List<int>.generate(layerIds.length, (index) => first + index);
  }

  @override
  Future<int> groupLayers({required List<int> layerIds}) async {
    if (layerIds.length < 2 ||
        layerIds.any((id) => id <= 0) ||
        layerIds.toSet().length != layerIds.length) {
      throw ArgumentError('group requires at least two unique layer IDs');
    }
    return ++_revision;
  }

  @override
  Future<String?> preflightGroupLayers({required List<int> layerIds}) async {
    if (layerIds.length < 2 ||
        layerIds.any((id) => id <= 0) ||
        layerIds.toSet().length != layerIds.length) {
      throw ArgumentError('group requires at least two unique layer IDs');
    }
    return null;
  }

  @override
  Future<void> ungroupLayer({required int groupId}) async {
    if (groupId <= 0) throw ArgumentError.value(groupId, 'groupId');
    _revision++;
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
    _revision++;
  }

  @override
  Future<void> setPanelMaskGeometry({
    required int maskLayerId,
    required List<double> points,
  }) async {
    if (maskLayerId <= 0 ||
        points.length < 6 ||
        points.length > 128 ||
        !points.length.isEven ||
        points.any((value) => !value.isFinite)) {
      throw ArgumentError('invalid panel mask geometry');
    }
    _revision++;
  }

  @override
  Future<void> setPanelFrames({
    required int layerId,
    required List<double> points,
    required List<int> pointCounts,
    required double borderPx,
  }) async {
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
    _revision++;
  }

  @override
  Future<void> mergeLayers({
    required int targetLayerId,
    required int sourceLayerId,
  }) async {
    if (targetLayerId < 0 ||
        sourceLayerId < 0 ||
        targetLayerId == sourceLayerId) {
      throw ArgumentError('invalid layer merge');
    }
    _revision++;
  }

  @override
  Future<String?> preflightMergeLayers({
    required int targetLayerId,
    required int sourceLayerId,
  }) async {
    if (targetLayerId <= 0 ||
        sourceLayerId <= 0 ||
        targetLayerId == sourceLayerId) {
      throw ArgumentError('invalid layer merge preflight');
    }
    final layers = await layerSummaries();
    final source = layers.where((layer) => layer.id == sourceLayerId);
    final target = layers.where((layer) => layer.id == targetLayerId);
    if (source.isEmpty || target.isEmpty) {
      return 'Merge layer no longer exists.';
    }
    if (source.single.kind != 'Raster' || target.single.kind != 'Raster') {
      return 'Layer merge currently requires two raster layers.';
    }
    return 'Merge preview is unavailable in the in-memory engine.';
  }

  @override
  Future<int> mergeLayersBulk({required List<int> layerIds}) async {
    if (layerIds.length < 2 ||
        layerIds.any((id) => id <= 0) ||
        layerIds.toSet().length != layerIds.length) {
      throw ArgumentError('bulk merge requires unique layer IDs');
    }
    _revision++;
    return layerIds.first;
  }

  @override
  Future<void> selectRectangle({
    required double x0,
    required double y0,
    required double x1,
    required double y1,
  }) async {
    if ([x0, y0, x1, y1].any((value) => !value.isFinite)) {
      throw ArgumentError('invalid rectangle selection');
    }
    _revision++;
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
    if (layerId < 0 ||
        strokeId < 0 ||
        [a, b, c, d, tx, ty].any((value) => !value.isFinite) ||
        (a * d - b * c).abs() < 0.000001) {
      throw ArgumentError('invalid vector transform');
    }
    _revision++;
  }

  @override
  Future<void> simplifyVectorStroke({
    required int layerId,
    required int strokeId,
    required double tolerance,
  }) async {
    if (layerId < 0 ||
        strokeId < 0 ||
        !tolerance.isFinite ||
        tolerance <= 0 ||
        tolerance > 256) {
      throw ArgumentError('invalid vector simplification');
    }
    _revision++;
  }

  @override
  Future<void> connectVectorStrokes({
    required int layerId,
    required int firstId,
    required int secondId,
    required double tolerance,
  }) async {
    if (layerId < 0 ||
        firstId < 0 ||
        secondId < 0 ||
        firstId == secondId ||
        !tolerance.isFinite ||
        tolerance <= 0 ||
        tolerance > 256) {
      throw ArgumentError('invalid vector connection');
    }
    _revision++;
  }

  @override
  Future<void> eraseVectorSegment({
    required int layerId,
    required int strokeId,
    required double centerX,
    required double centerY,
    required double radius,
  }) async {
    if (layerId < 0 ||
        strokeId < 0 ||
        [centerX, centerY, radius].any((value) => !value.isFinite) ||
        radius <= 0 ||
        radius > 4096) {
      throw ArgumentError('invalid vector eraser');
    }
    _revision++;
  }

  @override
  Future<void> selectEllipse({
    required double centerX,
    required double centerY,
    required double radiusX,
    required double radiusY,
  }) async {
    if ([centerX, centerY, radiusX, radiusY].any((value) => !value.isFinite) ||
        radiusX <= 0 ||
        radiusY <= 0) {
      throw ArgumentError('invalid ellipse selection');
    }
    _revision++;
  }

  @override
  Future<void> selectLasso(List<double> points) async {
    if (points.length < 6 ||
        points.length > 2048 ||
        points.length.isOdd ||
        points.any((value) => !value.isFinite)) {
      throw ArgumentError('invalid lasso selection');
    }
    _revision++;
  }

  @override
  Future<void> selectLayerOpacity({
    required int layerId,
    required int minimumAlpha,
  }) async {
    if (layerId < 0 || minimumAlpha < 0 || minimumAlpha > 255) {
      throw ArgumentError('invalid opacity selection');
    }
    _revision++;
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
    if (layerId < 0 ||
        [red, green, blue, alpha].any((value) => value < 0 || value > 255) ||
        tolerance < 0 ||
        tolerance > 1020) {
      throw ArgumentError('invalid color range selection');
    }
    _revision++;
  }

  @override
  Future<void> clearSelection() async => _revision++;

  @override
  Future<void> invertSelection() async => _revision++;

  @override
  Future<void> growSelection(int radius) async {
    if (radius < 1 || radius > 256) throw RangeError.range(radius, 1, 256);
    _revision++;
  }

  @override
  Future<void> shrinkSelection(int radius) async {
    if (radius < 1 || radius > 256) throw RangeError.range(radius, 1, 256);
    _revision++;
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
    if (layerId < 0 ||
        x < 0 ||
        y < 0 ||
        [red, green, blue, alpha].any((value) => value < 0 || value > 255) ||
        tolerance < 0 ||
        gap < 0) {
      throw ArgumentError('invalid fill region');
    }
    _revision++;
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
    _revision++;
  }

  @override
  Future<void> perspectiveLayer({
    required int layerId,
    required List<double> target,
  }) async {
    if (layerId < 0 ||
        target.length != 8 ||
        target.any((value) => !value.isFinite)) {
      throw ArgumentError('invalid perspective transform');
    }
    _revision++;
  }

  @override
  Future<void> meshLayer({
    required int layerId,
    required int columns,
    required int rows,
    required List<double> points,
  }) async {
    if (layerId < 0 ||
        columns < 2 ||
        rows < 2 ||
        columns > 32 ||
        rows > 32 ||
        points.length != columns * rows * 2 ||
        points.any((value) => !value.isFinite)) {
      throw ArgumentError('invalid mesh transform');
    }
    _revision++;
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
    _revision++;
  }

  @override
  Future<void> addVectorStroke({
    required int layerId,
    required List<double> points,
    required bool closed,
  }) async {
    if (layerId < 0 ||
        points.isEmpty ||
        points.length > 8_192 * 4 ||
        points.length % 4 != 0 ||
        points.any((value) => !value.isFinite)) {
      throw ArgumentError('invalid vector stroke');
    }
    _revision++;
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
    if (layerId < 0 || [a, b, c, d, tx, ty].any((value) => !value.isFinite)) {
      throw ArgumentError('invalid layer transform');
    }
    if ((a * d - b * c).abs() < 0.000001) {
      throw ArgumentError('layer transform must be invertible');
    }
    _revision++;
  }

  @override
  Future<void> saveAs(String path) async {}

  @override
  Future<void> attachComicProject(Uint8List bytes) async {
    _comicBytes = Uint8List.fromList(bytes);
    _revision++;
  }

  @override
  Future<Uint8List?> readComicProject() async =>
      _comicBytes == null ? null : Uint8List.fromList(_comicBytes!);

  @override
  Future<void> exportPng(String path) async {}

  @override
  Future<void> exportTimeLapse(String path) async {
    if (path.isEmpty) throw ArgumentError('invalid time-lapse export');
  }

  @override
  Future<void> exportDocument({
    required String path,
    required String format,
  }) async {
    if (path.isEmpty || format.isEmpty) throw ArgumentError('invalid export');
  }

  @override
  Future<void> exportEditablePsd(String path) async {
    if (path.isEmpty) throw ArgumentError('invalid PSD export path');
    throw UnsupportedError('Editable PSD export requires the Rust engine.');
  }

  @override
  Future<List<BrushSummaryView>> builtinBrushes() async => const [
    BrushSummaryView(
      id: 1,
      name: 'Technical Pen',
      isBuiltin: true,
      tags: ['ink'],
      diameterPx: 12,
      pressureSize: 1,
      pressureSizeReplace: true,
      pressureCurvePoints: <double>[
        0,
        0.12,
        0.003,
        0.13,
        0.006,
        0.15,
        0.01,
        0.2,
        0.015,
        0.24,
        0.02,
        0.27,
        0.04,
        0.32,
        0.08,
        0.36,
        0.12,
        0.4,
        0.2,
        0.56,
        0.3,
        0.75,
        0.42,
        0.9,
        0.55,
        0.96,
        1,
        1,
      ],
    ),
    BrushSummaryView(
      id: 2,
      name: 'HB Sketch Pencil',
      isBuiltin: true,
      tags: ['sketch'],
      pressureSize: 0.55,
      pressureOpacity: 0.35,
      pressureCurvePoints: _starterPressureCurvePoints,
    ),
    BrushSummaryView(
      id: 3,
      name: 'Opaque Round',
      isBuiltin: true,
      tags: ['paint'],
      pressureSize: 0.8,
      pressureCurvePoints: _starterPressureCurvePoints,
    ),
    BrushSummaryView(
      id: 4,
      name: 'Soft Airbrush',
      isBuiltin: true,
      tags: ['paint'],
      pressureOpacity: 0.85,
      pressureCurvePoints: _starterPressureCurvePoints,
    ),
    BrushSummaryView(
      id: 5,
      name: 'Marker',
      isBuiltin: true,
      tags: ['ink', 'paint'],
      pressureSize: 0.55,
      pressureOpacity: 0.3,
      pressureCurvePoints: _starterPressureCurvePoints,
    ),
    BrushSummaryView(
      id: 6,
      name: 'G-Pen',
      isBuiltin: true,
      tags: ['ink'],
      pressureSize: 0.85,
      pressureCurvePoints: _starterPressureCurvePoints,
    ),
    BrushSummaryView(
      id: 7,
      name: 'Dry Gouache',
      isBuiltin: true,
      tags: ['paint'],
      pressureSize: 0.25,
      pressureOpacity: 0.35,
      pressureCurvePoints: _starterPressureCurvePoints,
    ),
    BrushSummaryView(
      id: 8,
      name: 'Digital Watercolor Wash',
      isBuiltin: true,
      tags: ['watercolor'],
      pressureOpacity: 0.45,
      pressureCurvePoints: _starterPressureCurvePoints,
    ),
    BrushSummaryView(
      id: 9,
      name: 'Watercolor Blender',
      isBuiltin: true,
      tags: ['watercolor'],
      pressureSize: 0.2,
      pressureOpacity: 0.4,
      pressureCurvePoints: _starterPressureCurvePoints,
    ),
    BrushSummaryView(
      id: 10,
      name: 'Ink Spatter',
      isBuiltin: true,
      tags: ['effect'],
      pressureSize: 0.45,
      pressureOpacity: 0.45,
      pressureCurvePoints: _starterPressureCurvePoints,
    ),
    BrushSummaryView(
      id: 11,
      name: 'Ribbon Chain',
      isBuiltin: true,
      tags: ['effect'],
      pressureSize: 0.65,
      pressureCurvePoints: _starterPressureCurvePoints,
    ),
    BrushSummaryView(
      id: 12,
      name: 'Acrylic Rake',
      isBuiltin: true,
      tags: ['paint'],
      pressureSize: 0.45,
      pressureCurvePoints: _starterPressureCurvePoints,
    ),
    BrushSummaryView(
      id: _additionalBuiltinBrushIdBase + 1,
      name: 'Soft Graphite',
      isBuiltin: true,
      tags: ['sketch', 'pencil', 'soft'],
      pressureSize: 0.62,
      pressureOpacity: 0.35,
      pressureCurvePoints: _starterPressureCurvePoints,
    ),
    BrushSummaryView(
      id: _additionalBuiltinBrushIdBase + 2,
      name: 'Charcoal',
      isBuiltin: true,
      tags: ['sketch', 'charcoal', 'texture'],
      pressureSize: 0.62,
      pressureOpacity: 0.4,
      pressureCurvePoints: _starterPressureCurvePoints,
    ),
    BrushSummaryView(
      id: _additionalBuiltinBrushIdBase + 3,
      name: 'Brush Pen',
      isBuiltin: true,
      tags: ['ink', 'pressure', 'taper'],
      pressureSize: 0.62,
      pressureCurvePoints: _starterPressureCurvePoints,
    ),
    BrushSummaryView(
      id: _additionalBuiltinBrushIdBase + 4,
      name: 'Dry Ink',
      isBuiltin: true,
      tags: ['ink', 'texture', 'dry'],
      pressureSize: 0.62,
      pressureCurvePoints: _starterPressureCurvePoints,
    ),
    BrushSummaryView(
      id: _additionalBuiltinBrushIdBase + 5,
      name: 'Flat Paint',
      isBuiltin: true,
      tags: ['paint', 'opaque', 'flat'],
      pressureSize: 0.25,
      pressureCurvePoints: _starterPressureCurvePoints,
    ),
    BrushSummaryView(
      id: _additionalBuiltinBrushIdBase + 6,
      name: 'Soft Blender',
      isBuiltin: true,
      tags: ['blend', 'smudge', 'soft'],
      pressureSize: 0.25,
      pressureOpacity: 0.3,
      pressureCurvePoints: _starterPressureCurvePoints,
    ),
    BrushSummaryView(
      id: _additionalBuiltinBrushIdBase + 7,
      name: 'Hard Eraser',
      isBuiltin: true,
      tags: ['eraser', 'hard', 'clean'],
      pressureSize: 0.65,
      pressureCurvePoints: _starterPressureCurvePoints,
    ),
    BrushSummaryView(
      id: _additionalBuiltinBrushIdBase + 8,
      name: 'Soft Eraser',
      isBuiltin: true,
      tags: ['eraser', 'soft'],
      pressureSize: 0.55,
      pressureOpacity: 0.3,
      pressureCurvePoints: _starterPressureCurvePoints,
    ),
    BrushSummaryView(
      id: _additionalBuiltinBrushIdBase + 9,
      name: 'Experimental Inking Pen',
      isBuiltin: true,
      tags: ['ink', 'experimental', 'tuning-reference'],
      pressureSize: 1,
      pressureSizeReplace: true,
      pressureCurvePoints: _technicalPenPressureCurvePoints,
      pressureResponses: [
        BrushPressureResponseView(
          target: BrushPressureTargetView.size,
          curvePoints: _technicalPenPressureCurvePoints,
          amount: 1,
          enabled: true,
          replace: true,
          editable: true,
        ),
        BrushPressureResponseView(
          target: BrushPressureTargetView.opacity,
          curvePoints: [0, 0, 1, 1],
          amount: 0,
          enabled: false,
          replace: false,
          editable: true,
        ),
        BrushPressureResponseView(
          target: BrushPressureTargetView.flow,
          curvePoints: [0, 0, 1, 1],
          amount: 0,
          enabled: false,
          replace: false,
          editable: true,
        ),
      ],
    ),
    BrushSummaryView(
      id: _additionalBuiltinBrushIdBase + 10,
      name: 'Experimental Tilt Pencil',
      isBuiltin: true,
      tags: ['sketch', 'pencil', 'experimental', 'tuning-reference'],
      pressureSize: .55,
      pressureCurvePoints: _starterPressureCurvePoints,
    ),
    BrushSummaryView(
      id: _additionalBuiltinBrushIdBase + 11,
      name: 'Experimental Flow Marker',
      isBuiltin: true,
      tags: ['paint', 'marker', 'experimental', 'tuning-reference'],
      pressureSize: .55,
      pressureResponses: [
        BrushPressureResponseView(
          target: BrushPressureTargetView.size,
          curvePoints: [0, 0, 1, 1],
          amount: .55,
          enabled: true,
          replace: false,
          editable: true,
        ),
        BrushPressureResponseView(
          target: BrushPressureTargetView.opacity,
          curvePoints: [0, 0, 1, 1],
          amount: 0,
          enabled: false,
          replace: false,
          editable: true,
        ),
        BrushPressureResponseView(
          target: BrushPressureTargetView.flow,
          curvePoints: [0, 0, 1, 1],
          amount: .45,
          enabled: true,
          replace: false,
          editable: true,
        ),
      ],
    ),
    BrushSummaryView(
      id: _additionalBuiltinBrushIdBase + 12,
      name: 'Experimental Calligraphic Raster',
      isBuiltin: true,
      tags: ['ink', 'calligraphy', 'experimental', 'tuning-reference'],
      pressureSize: .62,
      pressureCurvePoints: _starterPressureCurvePoints,
    ),
  ];

  @override
  Future<List<LayerSummaryView>> layerSummaries() async =>
      List<LayerSummaryView>.unmodifiable(_layers);

  @override
  Future<List<VectorStrokeSummaryView>> vectorStrokeSummaries({
    required int layerId,
  }) async {
    if (layerId < 0) throw ArgumentError('invalid vector layer');
    return const <VectorStrokeSummaryView>[];
  }

  @override
  Future<List<VectorObjectSummaryView>> vectorObjectSummaries({
    required int layerId,
    required int offset,
    required int limit,
  }) async {
    if (layerId < 0 || offset < 0 || limit < 1 || limit > 64) {
      throw ArgumentError('invalid vector summary page');
    }
    return const <VectorObjectSummaryView>[];
  }

  @override
  Future<VectorObjectSummaryView?> vectorObjectDetail({
    required int layerId,
    required int objectId,
  }) async {
    if (layerId < 0 || objectId <= 0) {
      throw ArgumentError('invalid vector object detail target');
    }
    return null;
  }

  @override
  Future<int?> hitTestVectorObject({
    required int layerId,
    required double x,
    required double y,
    required double tolerancePx,
  }) async {
    if (layerId < 0 ||
        !x.isFinite ||
        !y.isFinite ||
        !tolerancePx.isFinite ||
        tolerancePx < 0 ||
        tolerancePx > 4096) {
      throw ArgumentError('invalid vector hit-test point or tolerance');
    }
    return null;
  }

  @override
  Future<VectorCandidateView> previewVectorShape({
    required int layerId,
    required int strokeId,
  }) async {
    if (layerId < 0 || strokeId <= 0) {
      throw ArgumentError('invalid vector shape target');
    }
    return VectorCandidateView(
      token: 0,
      sourceId: strokeId,
      revision: _revision,
      matched: false,
      kind: 'NoMatch',
      geometry: const <double>[],
      subpathStarts: const <int>[],
      closed: const <bool>[],
      strokeRgba: 0,
      strokeWidth: 0,
      notice: 'No supported shape recognized.',
    );
  }

  @override
  Future<VectorCandidateView> previewVectorShapeConstraint({
    required int candidateToken,
    required int constraint,
  }) async {
    if (candidateToken <= 0 || (constraint != 0 && constraint != 1)) {
      throw ArgumentError('invalid vector shape constraint');
    }
    throw UnsupportedError('shape constraints require the Rust vector engine');
  }

  @override
  Future<VectorCandidateView> previewVectorLegacyTranslation({
    required int layerId,
    required int strokeId,
    required double tx,
    required double ty,
  }) async {
    if (layerId < 0 || strokeId <= 0 || !tx.isFinite || !ty.isFinite) {
      throw ArgumentError('invalid legacy vector translation');
    }
    throw UnsupportedError('vector previews require the Rust vector engine');
  }

  @override
  Future<VectorCandidateView> previewVectorCurveFit({
    required int layerId,
    required int strokeId,
    required double tolerancePx,
  }) async {
    if (layerId < 0 ||
        strokeId <= 0 ||
        !tolerancePx.isFinite ||
        tolerancePx < 0.25 ||
        tolerancePx > 8.0) {
      throw ArgumentError('invalid vector curve-fit target or tolerance');
    }
    throw UnsupportedError('curve fitting requires the Rust vector engine');
  }

  @override
  Future<VectorCandidateView> previewVectorAnchorMove({
    required int layerId,
    required int objectId,
    required int subpath,
    required int anchor,
    required double dx,
    required double dy,
  }) => _unsupportedPathEdit(layerId, objectId, subpath, anchor);

  @override
  Future<VectorCandidateView> previewVectorHandleMove({
    required int layerId,
    required int objectId,
    required int subpath,
    required int anchor,
    required bool incoming,
    required double x,
    required double y,
  }) => _unsupportedPathEdit(layerId, objectId, subpath, anchor);

  @override
  Future<VectorCandidateView> previewVectorAnchorSmooth({
    required int layerId,
    required int objectId,
    required int subpath,
    required int anchor,
    required bool smooth,
  }) => _unsupportedPathEdit(layerId, objectId, subpath, anchor);

  @override
  Future<VectorCandidateView> previewVectorSegmentSplit({
    required int layerId,
    required int objectId,
    required int subpath,
    required int segment,
    required double t,
  }) => _unsupportedPathEdit(layerId, objectId, subpath, segment);

  @override
  Future<VectorCandidateView> previewVectorAnchorDelete({
    required int layerId,
    required int objectId,
    required int subpath,
    required int anchor,
  }) => _unsupportedPathEdit(layerId, objectId, subpath, anchor);

  @override
  Future<VectorCandidateView> previewVectorPathTransform({
    required int layerId,
    required int objectId,
    required double tx,
    required double ty,
    required double rotationDegrees,
    required double uniformScale,
  }) => _unsupportedPathEdit(layerId, objectId, 0, 0);

  Future<VectorCandidateView> _unsupportedPathEdit(
    int layerId,
    int objectId,
    int subpath,
    int index,
  ) {
    if (layerId < 0 || objectId <= 0 || subpath < 0 || index < 0) {
      return Future.error(ArgumentError('invalid Bézier path edit target'));
    }
    return Future.error(
      UnsupportedError('Bézier edits require the Rust vector engine'),
    );
  }

  @override
  Future<void> applyVectorCandidate({required int token}) async {
    if (token <= 0) throw ArgumentError('invalid vector candidate token');
  }

  @override
  Future<void> cancelVectorCandidate({required int token}) async {}

  @override
  Future<void> restoreVectorOriginalInk({
    required int layerId,
    required int objectId,
  }) async {
    if (layerId < 0 || objectId <= 0) {
      throw ArgumentError('invalid vector restoration target');
    }
  }

  @override
  Future<List<int>> repeatVectorPath({
    required int layerId,
    required int objectId,
    required CanvasVectorRepeatOptions options,
  }) async {
    if (layerId < 0 || objectId <= 0) {
      throw ArgumentError('invalid vector repeat target');
    }
    throw UnsupportedError('Vector repeat requires the Rust vector engine');
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
    if (layerId < 0 || !opacity.isFinite || opacity < 0 || opacity > 1) {
      throw ArgumentError('invalid layer properties');
    }
  }

  @override
  Future<int> beginLayerOpacityEdit({required int layerId}) async {
    if (layerId <= 0) throw ArgumentError.value(layerId, 'layerId');
    return _nextOpacityEditId++;
  }

  @override
  Future<void> updateLayerOpacityEdit({
    required int editId,
    required double opacity,
  }) async {
    if (editId <= 0 || !opacity.isFinite || opacity < 0 || opacity > 1) {
      throw ArgumentError('invalid opacity edit');
    }
  }

  @override
  Future<void> commitLayerOpacityEdit({required int editId}) async {
    if (editId <= 0) throw ArgumentError.value(editId, 'editId');
  }

  @override
  Future<void> cancelLayerOpacityEdit({required int editId}) async {
    if (editId <= 0) throw ArgumentError.value(editId, 'editId');
  }

  @override
  Future<TileUpdateBatch> drainTileUpdates() async =>
      TileUpdateBatch.empty(_revision);

  @override
  Future<List<StrokeAcknowledgement>> drainStrokeAcknowledgements() async =>
      const <StrokeAcknowledgement>[];

  @override
  Future<int> drainLiveDabOverflowCount() async => 0;

  @override
  Future<Uint8List> readTile({
    required int layer,
    required int x,
    required int y,
  }) async => Uint8List(256 * 256 * 4);

  @override
  Future<Uint8List> readCompositeTile({required int x, required int y}) async {
    if (x < -1_000_000 || y < -1_000_000 || x > 1_000_000 || y > 1_000_000) {
      throw ArgumentError('invalid composite tile coordinate');
    }
    return Uint8List(256 * 256 * 4);
  }

  @override
  Future<CompositeTileSnapshot> readCompositeTilesSnapshot({
    required List<StrokeTileCoordinate> coordinates,
  }) async => CompositeTileSnapshot(
    revision: _revision,
    tiles: coordinates
        .map(
          (coordinate) => CompositeTilePixels(
            x: coordinate.x,
            y: coordinate.y,
            bytes: Uint8List(256 * 256 * 4),
          ),
        )
        .toList(growable: false),
  );

  @override
  Future<Uint8List> readLayerThumbnail({
    required int layerId,
    int size = 48,
  }) async {
    if (layerId < 0 || size < 16 || size > 128) {
      throw ArgumentError('invalid layer thumbnail');
    }
    return Uint8List(size * size * 4);
  }

  @override
  Future<void> close() async {}
}

/// FRB-backed implementation used by production builds.
///
/// Construction is asynchronous because the native Rust library must be
/// loaded before a document handle can be created. Widgets can keep using the
/// same [EngineApi] contract while the app bootstrap selects this adapter.

void _validateCurvePoints(List<BrushCurvePointView> points) {
  if (points.length < 2 || points.length > 16) {
    throw ArgumentError.value(points.length, 'pressureCurvePoints');
  }
  var previousX = -1.0;
  for (final point in points) {
    if (!point.x.isFinite ||
        !point.y.isFinite ||
        point.x < 0 ||
        point.x > 1 ||
        point.y < 0 ||
        point.y > 1 ||
        point.x <= previousX) {
      throw ArgumentError.value(points, 'pressureCurvePoints');
    }
    previousX = point.x;
  }
}
