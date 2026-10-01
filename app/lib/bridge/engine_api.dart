import 'dart:math' as math;
import 'package:flutter/foundation.dart';

import 'generated/api.dart' as rust;
import 'generated/frb_generated.dart' show RustLib;
import '../tools/brush_library.dart' show BrushCurvePointView;

const int _compositeSnapshotPacketVersion = 1;
const int _compositeSnapshotHeaderBytes = 16;
const int _compositeSnapshotTileBytes = 256 * 256 * 4;
const int _compositeSnapshotRecordBytes = 8 + _compositeSnapshotTileBytes;
const int maxCompositeTileSnapshotTiles =
    (16 * 1024 * 1024 - _compositeSnapshotHeaderBytes) ~/
    _compositeSnapshotRecordBytes;

CompositeTileSnapshot decodeCompositeTileSnapshot(Uint8List packet) {
  if (packet.length < _compositeSnapshotHeaderBytes ||
      packet.length > 16 * 1024 * 1024) {
    throw const FormatException('composite tile snapshot has an invalid size');
  }
  final data = ByteData.sublistView(packet);
  final version = data.getUint16(0, Endian.little);
  final flags = data.getUint16(2, Endian.little);
  final revision = data.getUint64(4, Endian.little);
  final count = data.getUint32(12, Endian.little);
  final expectedLength =
      _compositeSnapshotHeaderBytes + count * _compositeSnapshotRecordBytes;
  if (version != _compositeSnapshotPacketVersion ||
      flags != 0 ||
      count > maxCompositeTileSnapshotTiles ||
      packet.length != expectedLength) {
    throw const FormatException('composite tile snapshot header is invalid');
  }
  final tiles = <CompositeTilePixels>[];
  var offset = _compositeSnapshotHeaderBytes;
  for (var index = 0; index < count; index++) {
    final x = data.getInt32(offset, Endian.little);
    final y = data.getInt32(offset + 4, Endian.little);
    final pixelsStart = offset + 8;
    final pixelsEnd = pixelsStart + _compositeSnapshotTileBytes;
    tiles.add(
      CompositeTilePixels(
        x: x,
        y: y,
        bytes: Uint8List.fromList(packet.sublist(pixelsStart, pixelsEnd)),
      ),
    );
    offset = pixelsEnd;
  }
  return CompositeTileSnapshot(revision: revision, tiles: tiles);
}

/// Safe, user-facing failure raised when a selected project cannot be opened.
class DocumentOpenException implements Exception {
  const DocumentOpenException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Dart-side control-plane contract. FRB generated implementations replace the
/// in-memory implementation without changing widgets or gesture routing.
abstract interface class EngineApi {
  DocumentInfo get documentInfo;

  /// Projects a Rust layer ID into the safe Dart ID space used by widgets.
  int layerIdForUi(BigInt rustLayerId);

  /// Last revision observed at a synchronization boundary.
  int get revision;
  Future<void> beginStroke();
  Future<void> beginBrushStroke(int brushId);
  Future<void> beginBrushStrokeOnLayer(int brushId, int layerId);
  Future<void> updateBrushColor({
    required int brushId,
    required int red,
    required int green,
    required int blue,
    required int alpha,
  });
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
  });
  Future<int> beginBrushDraft(int brushId);
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
  });
  Future<void> commitBrushDraft(int draftId);
  Future<void> cancelBrushDraft(int draftId);
  Future<void> endStroke();
  Future<void> cancelStroke();
  Future<void> pushPointerPacket(Uint8List packet);
  Future<void> undo();
  Future<void> redo();
  Future<rust.HistorySnapshotView> historySnapshot({int limit = 100});
  Future<void> navigateHistory(int sequence);
  Future<int> addLayer({required String kind});
  Future<int> addLayerToParent({required String kind, required int parentId});
  Future<void> deleteLayer({required int layerId});
  Future<int> duplicateLayer({required int layerId});
  Future<void> moveLayer({
    required int layerId,
    required int? parentId,
    required int index,
  });
  Future<void> createPanelLayerTree({
    required int panelId,
    required int panelGroupId,
    required int maskLayerId,
    required int sketchLayerId,
    required int inkLayerId,
    required int colorLayerId,
    required int toneLayerId,
    required int effectsLayerId,
  });
  Future<void> setPanelMaskGeometry({
    required int maskLayerId,
    required List<double> points,
  });

  /// Merge [sourceLayerId] into [targetLayerId] as one undoable operation.
  Future<void> mergeLayers({
    required int targetLayerId,
    required int sourceLayerId,
  });
  Future<void> selectRectangle({
    required double x0,
    required double y0,
    required double x1,
    required double y1,
  });
  Future<void> selectEllipse({
    required double centerX,
    required double centerY,
    required double radiusX,
    required double radiusY,
  });
  Future<void> selectLasso(List<double> points);
  Future<void> selectLayerOpacity({
    required int layerId,
    required int minimumAlpha,
  });
  Future<void> selectColorRange({
    required int layerId,
    required int red,
    required int green,
    required int blue,
    required int alpha,
    required int tolerance,
  });
  Future<void> clearSelection();
  Future<void> invertSelection();
  Future<void> growSelection(int radius);
  Future<void> shrinkSelection(int radius);
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
  });
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
  });
  Future<void> perspectiveLayer({
    required int layerId,
    required List<double> target,
  });
  Future<void> meshLayer({
    required int layerId,
    required int columns,
    required int rows,
    required List<double> points,
  });
  Future<void> liquifyLayer({
    required int layerId,
    required double centerX,
    required double centerY,
    required double radius,
    required double strength,
    required int mode,
    required double directionX,
    required double directionY,
  });
  Future<void> addVectorStroke({
    required int layerId,
    required List<double> points,
    required bool closed,
  });
  Future<void> transformVectorStroke({
    required int layerId,
    required int strokeId,
    required double a,
    required double b,
    required double c,
    required double d,
    required double tx,
    required double ty,
  });
  Future<void> simplifyVectorStroke({
    required int layerId,
    required int strokeId,
    required double tolerance,
  });
  Future<void> connectVectorStrokes({
    required int layerId,
    required int firstId,
    required int secondId,
    required double tolerance,
  });
  Future<void> eraseVectorSegment({
    required int layerId,
    required int strokeId,
    required double centerX,
    required double centerY,
    required double radius,
  });
  Future<void> setVectorPoint({
    required int layerId,
    required int strokeId,
    required int index,
    required double x,
    required double y,
    required double pressure,
    required double tilt,
  });
  Future<void> transformLayer({
    required int layerId,
    required double a,
    required double b,
    required double c,
    required double d,
    required double tx,
    required double ty,
  });

  /// Atomically save the native `.inkproj` document at [path].
  Future<void> saveAs(String path);

  /// Attach validated comic structure to the native document checkpoint.
  Future<void> attachComicProject(Uint8List bytes);

  /// Read comic structure attached to the native document, if present.
  Future<Uint8List?> readComicProject();

  /// Export the visible raster composite as deterministic PNG at [path].
  Future<void> exportPng(String path);
  Future<void> exportDocument({required String path, required String format});

  /// Export committed stroke samples for a local, deterministic time-lapse
  /// recorder. The JSON contains no document pixels or external paths.
  Future<void> exportTimeLapse(String path);
  Future<List<BrushSummaryView>> builtinBrushes();
  Future<List<LayerSummaryView>> layerSummaries();
  Future<List<VectorStrokeSummaryView>> vectorStrokeSummaries({
    required int layerId,
  });
  Future<void> exportBrush({required int brushId, required String path});
  Future<int> duplicateBrush(int brushId);
  Future<void> renameBrush({required int brushId, required String name});
  Future<BrushImportInspectionView> inspectBrushImport(String path);
  Future<BrushImportReportView> convertBrushImport(String path);
  Future<BrushImportStageView> stageBrushImport(String path);
  Future<BrushImportReportView> convertStagedBrushImport(int operationId);
  Future<int> commitStagedBrushImport(int operationId);
  Future<void> discardStagedBrushImport(int operationId);
  Future<int> importBrush(String path);
  Future<int> importBrushVerified(String path, Uint8List sourceSha256);
  Future<List<int>> importBrushPackVerified(
    String path,
    Uint8List sourceSha256,
  );
  Future<List<int>> importKritaBundleVerified(
    String path,
    Uint8List sourceSha256,
  );
  Future<void> updateLayerProperties({
    required int layerId,
    required bool visible,
    required double opacity,
    required bool alphaLock,
    required bool clipping,
    required bool reference,
  });
  Future<void> updateLayerPresentation({
    required int layerId,
    required String name,
    required String blendMode,
    required String groupMode,
    required int? labelRgba,
  });
  Future<void> setLayerBrightnessContrast({
    required int layerId,
    required int brightness,
    required int contrast,
  });
  Future<TileUpdateBatch> drainTileUpdates();
  Future<List<StrokeAcknowledgement>> drainStrokeAcknowledgements();
  Future<int> drainLiveDabOverflowCount();
  Future<Uint8List> readTile({
    required int layer,
    required int x,
    required int y,
  });

  /// Read the authoritative committed composite tile for the viewport.
  Future<Uint8List> readCompositeTile({required int x, required int y});

  /// Read a bounded group of immutable composite tiles from one Rust revision.
  Future<CompositeTileSnapshot> readCompositeTilesSnapshot({
    required List<StrokeTileCoordinate> coordinates,
  });
  Future<Uint8List> readLayerThumbnail({required int layerId, int size});

  /// Release native resources. Implementations must make this idempotent.
  Future<void> close();
}

/// Optional bounded GPU-preview capability. Documents continue to use
/// [EngineApi] as their only pixel authority; this interface only presents
/// Rust-generated transient brush dabs on a platform texture.
abstract interface class LiveDabSourceApi {
  Future<Uint8List> drainLiveDabs({int limit = 2048});
  Future<int> drainLiveDabOverflowCount();
}

abstract interface class LiveRenderEngineApi implements LiveDabSourceApi {
  Future<rust.LiveSurfaceHandle> createLiveSurface({
    required int physicalWidth,
    required int physicalHeight,
    required int scaleMilli,
  });
  Future<BigInt> liveSurfaceNativeDeviceHandle(rust.LiveSurfaceHandle surface);
  Future<void> attachLiveSurfaceNativeTexture(
    rust.LiveSurfaceHandle surface,
    BigInt textureHandle,
  );
  Future<void> attachLiveSurface(rust.LiveSurfaceHandle surface);
  Future<void> setLiveViewport(
    rust.LiveSurfaceHandle surface,
    List<double> matrix,
    int generation,
  );
  Future<void> renderLiveDabPacket(
    rust.LiveSurfaceHandle surface,
    Uint8List packet,
  );
  Future<void> acknowledgeLiveSurface(
    rust.LiveSurfaceHandle surface,
    BigInt strokeId,
    int highestCommittedSequence,
  );
  Future<void> cancelLiveSurfaceStroke(
    rust.LiveSurfaceHandle surface,
    BigInt strokeId,
  );
  Future<void> detachLiveSurface(rust.LiveSurfaceHandle surface);
  Future<void> disposeLiveSurface(rust.LiveSurfaceHandle surface);
}

class BrushSummaryView {
  const BrushSummaryView({
    required this.id,
    required this.name,
    this.tags = const [],
    this.diameterPx = 12,
    this.opacity = 1,
    this.spacing = 0.1,
    this.smoothing = 0,
    this.pressureSize = 0,
    this.pressureOpacity = 0,
    this.hardness = 0.75,
    this.textureScale = 1,
    this.scatter = 0,
    this.rotationJitter = 0,
    this.smudge = 0,
    this.wetness = 0,
    this.colorRgba = 0x202124ff,
    this.pressureCurvePoints = const <double>[0, 0, 1, 1],
    this.tipResourceHash,
    this.grainResourceHash,
  });
  final int id;
  final String name;
  final List<String> tags;
  final double diameterPx;
  final double opacity;
  final double spacing;
  final double smoothing;
  final double pressureSize;
  final double pressureOpacity;
  final double hardness;
  final double textureScale;
  final double scatter;
  final double rotationJitter;
  final double smudge;
  final double wetness;
  final int colorRgba;

  /// Flattened normalized `(x, y)` pairs from the Rust preset.
  final List<double> pressureCurvePoints;
  final Uint8List? tipResourceHash;
  final Uint8List? grainResourceHash;
}

class BrushImportInspectionView {
  const BrushImportInspectionView({
    required this.sourceFormat,
    required this.sourceSha256,
    required this.bytes,
    required this.fidelity,
    required this.importerVersion,
  });

  final String sourceFormat;
  final Uint8List sourceSha256;
  final int bytes;
  final String fidelity;
  final String importerVersion;
}

class BrushImportReportView {
  const BrushImportReportView({
    required this.sourceFormat,
    required this.sourceSha256,
    required this.importerVersion,
    required this.fidelity,
    required this.mappings,
    required this.omitted,
    required this.warnings,
    required this.resourceCount,
    required this.previewWidth,
    required this.previewHeight,
    this.brushCount = 1,
  });

  final String sourceFormat;
  final Uint8List sourceSha256;
  final String importerVersion;
  final String fidelity;
  final List<String> mappings;
  final List<String> omitted;
  final List<String> warnings;
  final int resourceCount;
  final int previewWidth;
  final int previewHeight;
  final int brushCount;
}

class BrushImportStageView {
  const BrushImportStageView({
    required this.operationId,
    required this.inspection,
    required this.expiresInSeconds,
  });

  final int operationId;
  final BrushImportInspectionView inspection;
  final int expiresInSeconds;
}

class LayerSummaryView {
  const LayerSummaryView({
    required this.id,
    required this.name,
    required this.kind,
    this.order = 0,
    this.parent,
    this.opacity = 1,
    this.visible = true,
    this.blendMode = 'Normal',
    this.groupMode = 'Pass-through',
    this.alphaLock = false,
    this.clipping = false,
    this.reference = false,
    this.labelRgba,
    this.adjustmentBrightness = 0,
    this.adjustmentContrast = 0,
  });
  final int id;
  final int? parent;
  final String name;
  final String kind;
  final int order;
  final double opacity;
  final bool visible;
  final String blendMode;
  final String groupMode;
  final bool alphaLock;
  final bool clipping;
  final bool reference;
  final int? labelRgba;
  final int adjustmentBrightness;
  final int adjustmentContrast;
}

class VectorStrokeSummaryView {
  const VectorStrokeSummaryView({
    required this.id,
    required this.pointCount,
    this.points = const <double>[],
    required this.minX,
    required this.minY,
    required this.maxX,
    required this.maxY,
  });

  final int id;
  final int pointCount;
  final List<double> points;
  final double minX;
  final double minY;
  final double maxX;
  final double maxY;
}

/// Immutable document metadata needed by the viewport and tile cache.
///
/// Layer identifiers are currently represented as Dart [int] values at the UI
/// boundary. The bridge rejects identifiers outside the signed 64-bit range
/// instead of silently truncating them.
class DocumentInfo {
  const DocumentInfo({
    required this.widthPx,
    required this.heightPx,
    required this.dpi,
    required this.primaryRasterLayer,
  });

  final int widthPx;
  final int heightPx;
  final double dpi;
  final int primaryRasterLayer;
}

class TileUpdate {
  const TileUpdate({
    required this.revision,
    required this.layer,
    required this.x,
    required this.y,
  });

  final int revision;
  final int layer;
  final int x;
  final int y;
}

class TileUpdateBatch {
  const TileUpdateBatch({
    required this.revision,
    required this.fullRedraw,
    required this.tiles,
    this.acknowledgements = const <StrokeAcknowledgement>[],
    this.rendererBusy = false,
  });

  const TileUpdateBatch.empty(this.revision)
    : fullRedraw = false,
      tiles = const <TileUpdate>[],
      acknowledgements = const <StrokeAcknowledgement>[],
      rendererBusy = false;

  final int revision;
  final bool fullRedraw;
  final List<TileUpdate> tiles;

  /// Input coverage captured in the same Rust event drain as [tiles].
  final List<StrokeAcknowledgement> acknowledgements;

  /// The tile poll skipped a busy render lock and will retry on a later frame.
  final bool rendererBusy;
}

class StrokeAcknowledgement {
  const StrokeAcknowledgement({
    required this.stroke,
    required this.highestCommittedSequence,
    required this.revision,
    required this.minTileX,
    required this.minTileY,
    required this.maxTileX,
    required this.maxTileY,
    this.dirtyTiles = const <StrokeTileCoordinate>[],
    this.confirmedSampleCount = 0,
    this.pathLength = 0,
    this.directLength = 0,
    this.legacyDabs = 0,
    this.compiledDabs = 0,
    this.cpuTilesWritten = 0,
    this.compiledCpuTileUpdates = 0,
    this.workSegments = 0,
    this.workLimitReached = false,
  });

  final BigInt stroke;
  final int highestCommittedSequence;
  final int revision;
  final int minTileX;
  final int minTileY;
  final int maxTileX;
  final int maxTileY;
  final List<StrokeTileCoordinate> dirtyTiles;
  final int confirmedSampleCount;
  final double pathLength;
  final double directLength;
  final int legacyDabs;
  final int compiledDabs;
  final int cpuTilesWritten;
  final int compiledCpuTileUpdates;
  final int workSegments;
  final bool workLimitReached;

  bool get hasDirtyBounds => minTileX <= maxTileX && minTileY <= maxTileY;
}

class StrokeTileCoordinate {
  const StrokeTileCoordinate(this.x, this.y);

  final int x;
  final int y;
}

class CompositeTilePixels {
  const CompositeTilePixels({
    required this.x,
    required this.y,
    required this.bytes,
  });

  final int x;
  final int y;
  final Uint8List bytes;
}

class CompositeTileSnapshot {
  const CompositeTileSnapshot({required this.revision, required this.tiles});

  final int revision;
  final List<CompositeTilePixels> tiles;
}

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
class LayerIdProjection {
  static const int maxSafeId = 0x7fffffffffffffff;

  final Map<BigInt, int> _dartIdsByRustId = <BigInt, int>{};
  final Map<int, BigInt> _rustIdsByDartId = <int, BigInt>{};
  final Set<int> _reserved = <int>{};
  int _nextAlias = maxSafeId;

  /// Reserves real Dart-range IDs before assigning aliases to legacy IDs.
  /// Existing high IDs keep stable aliases until the active page changes.
  void reset(Iterable<BigInt> rustIds) {
    final ids = rustIds.toList(growable: false);
    _dartIdsByRustId.clear();
    _rustIdsByDartId.clear();
    _reserved
      ..clear()
      ..addAll(
        ids
            .where((id) => !id.isNegative && id <= BigInt.from(maxSafeId))
            .map((id) => id.toInt()),
      );
    _nextAlias = maxSafeId;
    for (final id in ids) {
      if (id.isNegative) throw StateError('negative layer identifier');
      if (id > BigInt.from(maxSafeId)) _alias(id);
    }
  }

  int toDart(BigInt rustId) {
    if (rustId.isNegative) throw StateError('negative layer identifier');
    return rustId <= BigInt.from(maxSafeId) ? rustId.toInt() : _alias(rustId);
  }

  BigInt toRust(int dartId) {
    if (dartId < 0) throw ArgumentError.value(dartId, 'dartId');
    return _rustIdsByDartId[dartId] ?? BigInt.from(dartId);
  }

  int _alias(BigInt rustId) {
    final existing = _dartIdsByRustId[rustId];
    if (existing != null) return existing;
    while (_nextAlias > 0 &&
        (_reserved.contains(_nextAlias) ||
            _rustIdsByDartId.containsKey(_nextAlias))) {
      _nextAlias--;
    }
    if (_nextAlias <= 0) {
      throw StateError('no safe Dart aliases remain for legacy layer IDs');
    }
    final alias = _nextAlias--;
    _dartIdsByRustId[rustId] = alias;
    _rustIdsByDartId[alias] = rustId;
    return alias;
  }
}

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
            order: summary.order,
            name: summary.name,
            kind: summary.kind,
            opacity: summary.opacity / 65535,
            visible: summary.visible,
            blendMode: summary.blendMode,
            groupMode: summary.groupMode,
            alphaLock: summary.alphaLock,
            clipping: summary.clipping,
            reference: summary.reference,
            labelRgba: summary.labelRgba,
            adjustmentBrightness: summary.adjustmentBrightness,
            adjustmentContrast: summary.adjustmentContrast,
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
    return decodeCompositeTileSnapshot(
      await rust.readCompositeTilesSnapshot(
        handle: _handle,
        coordinates: flatCoordinates,
      ),
    );
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
    final fallback = _fallbackHandle;
    if (_usingProjectHandle && fallback != null) {
      await rust.closeDocument(handle: fallback);
    } else {
      await rust.closeDocument(handle: _handle);
    }
  }
}

TileUpdateBatch decodeTileUpdatePacket(
  Uint8List packet, {
  int Function(BigInt rustLayerId)? projectLayerId,
}) {
  if (packet.length < 8) {
    throw const FormatException('tile update packet header is truncated');
  }
  final data = ByteData.sublistView(packet);
  final version = data.getUint16(0, Endian.little);
  if (version < 1 || version > 4) {
    throw FormatException('unsupported tile update packet version $version');
  }
  final flags = data.getUint16(2, Endian.little);
  if (flags & ~3 != 0) {
    throw const FormatException('tile update packet contains unknown flags');
  }
  if (version >= 2 && packet.length < 12) {
    throw const FormatException('tile update packet header is truncated');
  }
  const maxPacketBytes = 16 * 1024 * 1024;
  if (packet.length > maxPacketBytes) {
    throw const FormatException('tile update packet exceeds the byte limit');
  }
  final count = data.getUint32(4, Endian.little);
  const maxTileUpdates = 262144;
  if (count > maxTileUpdates) {
    throw const FormatException('tile update packet contains too many records');
  }
  final acknowledgementCount =
      version >= 2 ? data.getUint32(8, Endian.little) : 0;
  const maxAcknowledgements = 65536;
  if (acknowledgementCount > maxAcknowledgements) {
    throw const FormatException(
      'tile update packet contains too many stroke acknowledgements',
    );
  }
  const recordBytes = 32;
  const acknowledgementBytes = 44;
  final headerBytes = version >= 2 ? 12 : 8;
  final compositeLayerId = (BigInt.one << 128) - BigInt.one;
  final fixedExpectedLength =
      headerBytes +
      count * recordBytes +
      acknowledgementCount * acknowledgementBytes;
  if (version < 3 && packet.length != fixedExpectedLength) {
    throw const FormatException('tile update packet length is invalid');
  }
  var revision = 0;
  final updates = <TileUpdate>[];
  for (var index = 0; index < count; index++) {
    final offset = headerBytes + index * recordBytes;
    final eventRevision = data.getUint64(offset, Endian.little);
    final layer = _readLittleEndianU128(packet, offset + 8);
    final x = data.getInt32(offset + 24, Endian.little);
    final y = data.getInt32(offset + 28, Endian.little);
    revision = revision > eventRevision ? revision : eventRevision;
    final isComposite = layer == compositeLayerId;
    if (!isComposite &&
        layer > BigInt.from(LayerIdProjection.maxSafeId) &&
        projectLayerId == null) {
      throw const FormatException(
        'tile update packet contains an unsafe layer identifier',
      );
    }
    updates.add(
      TileUpdate(
        revision: eventRevision,
        layer:
            isComposite
                ? -1
                : projectLayerId == null
                ? layer.toInt()
                : projectLayerId(layer),
        x: x,
        y: y,
      ),
    );
  }
  final acknowledgements = <StrokeAcknowledgement>[];
  var acknowledgementOffset = headerBytes + count * recordBytes;
  for (var index = 0; index < acknowledgementCount; index++) {
    final remaining = packet.length - acknowledgementOffset;
    if (remaining < (version >= 3 ? 48 : acknowledgementBytes)) {
      throw const FormatException('stroke acknowledgement record is truncated');
    }
    final dirtyTileCount =
        version >= 3
            ? data.getUint32(acknowledgementOffset + 44, Endian.little)
            : 0;
    const maxDirtyTilesPerAcknowledgement = 262144;
    if (dirtyTileCount > maxDirtyTilesPerAcknowledgement) {
      throw const FormatException(
        'stroke acknowledgement contains too many dirty tiles',
      );
    }
    final dirtyTilesOffset = acknowledgementOffset + 48;
    final metricsBytes = version >= 4 ? 65 : 0;
    final recordLength =
        version >= 3
            ? 48 + dirtyTileCount * 8 + metricsBytes
            : acknowledgementBytes;
    if (remaining < recordLength) {
      throw const FormatException(
        'stroke acknowledgement tile coverage is truncated',
      );
    }
    final dirtyTiles = <StrokeTileCoordinate>[
      for (var tile = 0; tile < dirtyTileCount; tile++)
        StrokeTileCoordinate(
          data.getInt32(dirtyTilesOffset + tile * 8, Endian.little),
          data.getInt32(dirtyTilesOffset + tile * 8 + 4, Endian.little),
        ),
    ];
    final metricsOffset = acknowledgementOffset + 48 + dirtyTileCount * 8;
    if (version >= 4) {
      final pathLength = data.getFloat64(metricsOffset + 8, Endian.little);
      final directLength = data.getFloat64(metricsOffset + 16, Endian.little);
      if (!pathLength.isFinite || !directLength.isFinite) {
        throw const FormatException(
          'stroke acknowledgement contains non-finite path metrics',
        );
      }
      if (data.getUint8(metricsOffset + 64) > 1) {
        throw const FormatException(
          'stroke acknowledgement contains an invalid work-limit flag',
        );
      }
    }
    acknowledgements.add(
      _decodeStrokeAcknowledgement(
        data,
        packet,
        acknowledgementOffset,
        dirtyTiles: dirtyTiles,
        confirmedSampleCount:
            version >= 4 ? data.getUint64(metricsOffset, Endian.little) : 0,
        pathLength:
            version >= 4
                ? data.getFloat64(metricsOffset + 8, Endian.little)
                : 0,
        directLength:
            version >= 4
                ? data.getFloat64(metricsOffset + 16, Endian.little)
                : 0,
        legacyDabs:
            version >= 4
                ? data.getUint64(metricsOffset + 24, Endian.little)
                : 0,
        compiledDabs:
            version >= 4
                ? data.getUint64(metricsOffset + 32, Endian.little)
                : 0,
        cpuTilesWritten:
            version >= 4
                ? data.getUint64(metricsOffset + 40, Endian.little)
                : 0,
        compiledCpuTileUpdates:
            version >= 4
                ? data.getUint64(metricsOffset + 48, Endian.little)
                : 0,
        workSegments:
            version >= 4
                ? data.getUint64(metricsOffset + 56, Endian.little)
                : 0,
        workLimitReached:
            version >= 4 && data.getUint8(metricsOffset + 64) == 1,
      ),
    );
    revision = math.max(revision, acknowledgements.last.revision);
    acknowledgementOffset += recordLength;
  }
  if (acknowledgementOffset != packet.length) {
    throw const FormatException('tile update packet has trailing bytes');
  }
  return TileUpdateBatch(
    revision: revision,
    fullRedraw: flags & 1 != 0,
    tiles: List.unmodifiable(updates),
    acknowledgements: List.unmodifiable(acknowledgements),
    rendererBusy: flags & 2 != 0,
  );
}

List<StrokeAcknowledgement> decodeStrokeAcknowledgementPacket(
  Uint8List packet,
) {
  if (packet.length < 8) {
    throw const FormatException('stroke acknowledgement header is truncated');
  }
  final data = ByteData.sublistView(packet);
  final version = data.getUint16(0, Endian.little);
  if (version != 1) {
    throw FormatException(
      'unsupported stroke acknowledgement packet version $version',
    );
  }
  final flags = data.getUint16(2, Endian.little);
  if (flags != 0) {
    throw const FormatException(
      'stroke acknowledgement packet contains unknown flags',
    );
  }
  final count = data.getUint32(4, Endian.little);
  const recordBytes = 44;
  const maxRecords = 65536;
  if (count > maxRecords) {
    throw const FormatException(
      'stroke acknowledgement packet contains too many records',
    );
  }
  final expectedLength = 8 + count * recordBytes;
  if (packet.length != expectedLength) {
    throw const FormatException(
      'stroke acknowledgement packet length is invalid',
    );
  }
  final acknowledgements = <StrokeAcknowledgement>[];
  for (var index = 0; index < count; index++) {
    final offset = 8 + index * recordBytes;
    acknowledgements.add(_decodeStrokeAcknowledgement(data, packet, offset));
  }
  return List.unmodifiable(acknowledgements);
}

StrokeAcknowledgement _decodeStrokeAcknowledgement(
  ByteData data,
  Uint8List packet,
  int offset, {
  List<StrokeTileCoordinate> dirtyTiles = const <StrokeTileCoordinate>[],
  int confirmedSampleCount = 0,
  double pathLength = 0,
  double directLength = 0,
  int legacyDabs = 0,
  int compiledDabs = 0,
  int cpuTilesWritten = 0,
  int compiledCpuTileUpdates = 0,
  int workSegments = 0,
  bool workLimitReached = false,
}) {
  return StrokeAcknowledgement(
    stroke: _readLittleEndianU128(packet, offset),
    revision: data.getUint64(offset + 16, Endian.little),
    highestCommittedSequence: data.getUint32(offset + 24, Endian.little),
    minTileX: data.getInt32(offset + 28, Endian.little),
    minTileY: data.getInt32(offset + 32, Endian.little),
    maxTileX: data.getInt32(offset + 36, Endian.little),
    maxTileY: data.getInt32(offset + 40, Endian.little),
    dirtyTiles: List.unmodifiable(dirtyTiles),
    confirmedSampleCount: confirmedSampleCount,
    pathLength: pathLength,
    directLength: directLength,
    legacyDabs: legacyDabs,
    compiledDabs: compiledDabs,
    cpuTilesWritten: cpuTilesWritten,
    compiledCpuTileUpdates: compiledCpuTileUpdates,
    workSegments: workSegments,
    workLimitReached: workLimitReached,
  );
}

BigInt _readLittleEndianU128(Uint8List bytes, int offset) {
  var value = BigInt.zero;
  for (var index = 15; index >= 0; index--) {
    value = (value << 8) + BigInt.from(bytes[offset + index]);
  }
  return value;
}

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
