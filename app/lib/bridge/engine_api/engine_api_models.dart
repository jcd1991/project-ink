import 'dart:typed_data';

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
