import 'package:flutter/foundation.dart';

class PsdImportInspectionView {
  const PsdImportInspectionView({
    required this.widthPx,
    required this.heightPx,
    required this.depth,
    required this.layerCount,
    required this.editableImportAvailable,
    required this.flattenedImportAvailable,
    required this.supportedFeatures,
    required this.incompatibilities,
    required this.flattenedImportIssues,
    required this.estimatedEditableWorkingSetBytes,
    required this.estimatedFlattenedWorkingSetBytes,
  });

  final int widthPx;
  final int heightPx;
  final int depth;
  final int layerCount;
  final bool editableImportAvailable;
  final bool flattenedImportAvailable;
  final List<String> supportedFeatures;
  final List<String> incompatibilities;
  final List<String> flattenedImportIssues;
  final int estimatedEditableWorkingSetBytes;
  final int estimatedFlattenedWorkingSetBytes;

  /// Human-readable notes for accepted features that are converted on import.
  List<String> get conversionNotices => supportedFeatures
      .where((feature) => feature.startsWith('Conversion: '))
      .map((feature) => feature.substring('Conversion: '.length))
      .toList(growable: false);
}

class BrushSummaryView {
  const BrushSummaryView({
    required this.id,
    required this.name,
    this.isBuiltin = false,
    this.tags = const [],
    this.diameterPx = 12,
    this.opacity = 1,
    this.spacing = 0.1,
    this.smoothing = 0,
    this.pulledString = false,
    this.stabilizerDistancePx = 0,
    this.catchUpOnEnd = false,
    this.pressureSize = 0,
    this.pressureSizeReplace = false,
    this.pressureOpacity = 0,
    this.hardness = 0.75,
    this.textureScale = 1,
    this.scatter = 0,
    this.rotationJitter = 0,
    this.smudge = 0,
    this.wetness = 0,
    this.colorRgba = 0x202124ff,
    this.pressureCurvePoints = const <double>[0, 0, 1, 1],
    this.pressureResponses = const <BrushPressureResponseView>[],
    this.tipResourceHash,
    this.grainResourceHash,
  });
  final int id;
  final String name;
  final bool isBuiltin;
  final List<String> tags;
  final double diameterPx;
  final double opacity;
  final double spacing;
  final double smoothing;
  final bool pulledString;
  final double stabilizerDistancePx;
  final bool catchUpOnEnd;
  final double pressureSize;
  final bool pressureSizeReplace;
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
  final List<BrushPressureResponseView> pressureResponses;
  final Uint8List? tipResourceHash;
  final Uint8List? grainResourceHash;
}

enum BrushPressureTargetView { size, opacity, flow }

class BrushPressureResponseView {
  const BrushPressureResponseView({
    required this.target,
    required this.curvePoints,
    required this.amount,
    required this.enabled,
    required this.replace,
    required this.editable,
    List<double>? initialCurvePoints,
  }) : initialCurvePoints = initialCurvePoints ?? curvePoints;
  final BrushPressureTargetView target;
  final List<double> curvePoints;
  final double amount;
  final bool enabled;
  final bool replace;
  final bool editable;
  final List<double> initialCurvePoints;

  BrushPressureResponseView copyWith({
    List<double>? curvePoints,
    double? amount,
    bool? enabled,
  }) => BrushPressureResponseView(
    target: target,
    curvePoints: List<double>.unmodifiable(curvePoints ?? this.curvePoints),
    amount: amount ?? this.amount,
    enabled: enabled ?? this.enabled,
    replace: replace,
    editable: editable,
    initialCurvePoints: initialCurvePoints,
  );
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
    this.maskOwner,
    this.maskEnabled = true,
    this.maskInverted = false,
    this.opacity = 1,
    this.visible = true,
    this.blendMode = 'Normal',
    this.groupMode = 'Pass-through',
    this.alphaLock = false,
    this.locked = false,
    this.clipping = false,
    this.reference = false,
    this.labelRgba,
    this.adjustmentBrightness = 0,
    this.adjustmentContrast = 0,
    this.adjustmentJson,
    this.canDrag = true,
    this.dragReason,
    this.canReceiveLayers = true,
    this.receiveReason,
    this.canEditProperties = true,
    this.editPropertiesReason,
    this.canDuplicate = true,
    this.duplicateReason,
    this.canDelete = true,
    this.deleteReason,
    this.canUngroup = true,
    this.ungroupReason,
    this.canApplyMask = true,
    this.applyMaskReason,
    this.hasMergeDownCapability = false,
    this.mergeDownReason,
  });
  final int id;
  final int? parent;
  final int? maskOwner;
  final bool maskEnabled;
  final bool maskInverted;
  final String name;
  final String kind;
  final int order;
  final double opacity;
  final bool visible;
  final String blendMode;
  final String groupMode;
  final bool alphaLock;
  final bool locked;
  final bool clipping;
  final bool reference;
  final int? labelRgba;
  final int adjustmentBrightness;
  final int adjustmentContrast;
  final String? adjustmentJson;
  final bool canDrag;
  final String? dragReason;
  final bool canReceiveLayers;
  final String? receiveReason;
  final bool canEditProperties;
  final String? editPropertiesReason;
  final bool canDuplicate;
  final String? duplicateReason;
  final bool canDelete;
  final String? deleteReason;
  final bool canUngroup;
  final String? ungroupReason;
  final bool canApplyMask;
  final String? applyMaskReason;
  final bool hasMergeDownCapability;
  final String? mergeDownReason;
}

/// Durable layer-panel selection and disclosure state for one document page.
class LayerPanelStateView {
  const LayerPanelStateView({
    this.primaryLayerId,
    this.collapsedGroupIds = const <int>[],
  });

  final int? primaryLayerId;
  final List<int> collapsedGroupIds;
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

/// Bounded projection of one legacy or Bézier vector object.
class VectorObjectSummaryView {
  const VectorObjectSummaryView({
    required this.id,
    required this.kind,
    required this.pointCount,
    required this.minX,
    required this.minY,
    required this.maxX,
    required this.maxY,
    this.points = const <double>[],
    this.geometry = const <double>[],
    this.subpathStarts = const <int>[],
    this.closed = const <bool>[],
    this.hasSourceArchive = false,
  });

  final int id;
  final String kind;
  final int pointCount;
  final List<double> points;
  final List<double> geometry;
  final List<int> subpathStarts;
  final List<bool> closed;
  final bool hasSourceArchive;
  final double minX;
  final double minY;
  final double maxX;
  final double maxY;
}

/// Temporary immutable Bézier projection returned by Rust for inspection.
/// Geometry stores six document-pixel values per anchor: position, incoming
/// handle, and outgoing handle. It is not document state until Apply succeeds.
class VectorCandidateView {
  const VectorCandidateView({
    required this.token,
    required this.sourceId,
    required this.revision,
    required this.matched,
    required this.kind,
    this.points = const <double>[],
    required this.geometry,
    required this.subpathStarts,
    required this.closed,
    required this.strokeRgba,
    required this.strokeWidth,
    required this.notice,
  });

  final int token;
  final int sourceId;
  final int revision;
  final bool matched;
  final String kind;
  final List<double> points;
  final List<double> geometry;
  final List<int> subpathStarts;
  final List<bool> closed;
  final int strokeRgba;
  final double strokeWidth;
  final String notice;
}

enum CanvasVectorRepeatMode {
  radial,
  grid,
  mirrorVertical,
  mirrorHorizontal,
  mirrorBoth,
}

@immutable
class CanvasVectorRepeatOptions {
  const CanvasVectorRepeatOptions({
    required this.mode,
    this.copies = 8,
    this.columns = 3,
    this.rows = 3,
    this.spacingX = 32,
    this.spacingY = 32,
    this.stepDegrees = 45,
    this.scalePerCopy = 1,
  });

  final CanvasVectorRepeatMode mode;
  final int copies;
  final int columns;
  final int rows;
  final double spacingX;
  final double spacingY;
  final double stepDegrees;
  final double scalePerCopy;
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
