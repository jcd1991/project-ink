import 'dart:typed_data';

import '../generated/api.dart' as rust;
import 'engine_api_contract.dart';
import 'engine_api_models.dart';
import 'layer_id_projection.dart';
import '../../tools/brush_library.dart' show BrushCurvePointView;

class InMemoryEngineApi implements EngineApi {
  InMemoryEngineApi();

  int _revision = 0;
  int _nextBrushDraft = 1;
  final Set<int> _brushDrafts = <int>{};
  Uint8List? _comicBytes;

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
  }

  @override
  Future<int> beginBrushDraft(int brushId) async {
    if (brushId < 0) throw ArgumentError('invalid brush draft brush');
    final id = _nextBrushDraft++;
    _brushDrafts.add(id);
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
    );
  }

  @override
  Future<void> commitBrushDraft(int draftId) async {
    if (!_brushDrafts.remove(draftId)) {
      throw StateError('brush draft is not active');
    }
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
  }

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
    return _revision;
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
    return _revision;
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
  Future<void> deleteLayer({required int layerId}) async {
    if (layerId <= 0) throw ArgumentError('invalid layer ID');
    _revision++;
  }

  @override
  Future<int> duplicateLayer({required int layerId}) async {
    if (layerId <= 0) throw ArgumentError('invalid layer ID');
    return ++_revision;
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
  Future<List<BrushSummaryView>> builtinBrushes() async => const [
    BrushSummaryView(id: 1, name: 'Technical Pen', tags: ['ink']),
    BrushSummaryView(id: 2, name: 'HB Sketch Pencil', tags: ['sketch']),
    BrushSummaryView(id: 3, name: 'Opaque Round', tags: ['paint']),
    BrushSummaryView(id: 4, name: 'Soft Airbrush', tags: ['paint']),
    BrushSummaryView(id: 5, name: 'Marker', tags: ['ink', 'paint']),
    BrushSummaryView(id: 6, name: 'G-Pen', tags: ['ink']),
    BrushSummaryView(id: 7, name: 'Dry Gouache', tags: ['paint']),
    BrushSummaryView(
      id: 8,
      name: 'Digital Watercolor Wash',
      tags: ['watercolor'],
    ),
    BrushSummaryView(id: 9, name: 'Watercolor Blender', tags: ['watercolor']),
    BrushSummaryView(id: 10, name: 'Ink Spatter', tags: ['effect']),
    BrushSummaryView(id: 11, name: 'Ribbon Chain', tags: ['effect']),
    BrushSummaryView(id: 12, name: 'Acrylic Rake', tags: ['paint']),
  ];

  @override
  Future<List<LayerSummaryView>> layerSummaries() async => const [
    LayerSummaryView(id: 1, name: 'Paint Layer 1', kind: 'Raster'),
  ];

  @override
  Future<List<VectorStrokeSummaryView>> vectorStrokeSummaries({
    required int layerId,
  }) async {
    if (layerId < 0) throw ArgumentError('invalid vector layer');
    return const <VectorStrokeSummaryView>[];
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
