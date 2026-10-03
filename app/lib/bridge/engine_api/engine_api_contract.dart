import 'dart:typed_data';

import '../generated/api.dart' as rust;
import '../../tools/brush_library.dart'
    show BrushCurvePointView, BrushPreviewPointView;
import 'engine_api_models.dart';

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
  Future<void> setActiveBrushColor({
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
  Future<Uint8List> renderBrushPreview({
    required int brushId,
    required int width,
    required int height,
    required List<BrushPreviewPointView> points,
  });
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
  Future<void> deleteLayers({required List<int> layerIds});

  /// Return an engine-authored reason when selected layer roots cannot be
  /// deleted. The query does not modify the document.
  Future<String?> preflightDeleteLayers({required List<int> layerIds});
  Future<void> setLayersVisibility({
    required List<int> layerIds,
    required bool visible,
  });
  Future<void> setLayerSolo({required int? layerId});
  Future<LayerPanelStateView> layerPanelState();
  Future<void> setLayerPanelState({
    required int? primaryLayerId,
    required List<int> collapsedGroupIds,
  });
  Future<void> setLayersLocked({
    required List<int> layerIds,
    required bool locked,
  });
  Future<void> setLayersLabel({
    required List<int> layerIds,
    required int? labelRgba,
  });
  Future<void> setLayerLocked({required int layerId, required bool locked});
  Future<void> setMaskEnabled({required int maskId, required bool enabled});
  Future<void> setMaskInverted({required int maskId, required bool inverted});
  Future<void> applyLayerMask({required int maskId});
  Future<int> duplicateLayer({required int layerId});
  Future<List<int>> duplicateLayers({required List<int> layerIds});

  /// Return a Rust-authoritative explanation when the selected sibling roots
  /// cannot be grouped. This check does not mutate the document.
  Future<String?> preflightGroupLayers({required List<int> layerIds});
  Future<int> groupLayers({required List<int> layerIds});
  Future<void> ungroupLayer({required int groupId});
  Future<void> moveLayer({
    required int layerId,
    required int? parentId,
    required int index,
  });
  Future<void> reorderLayers({required List<int> layerIds, required int index});
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

  /// Returns an actionable reason when the merge cannot be performed.
  Future<String?> preflightMergeLayers({
    required int targetLayerId,
    required int sourceLayerId,
  });
  Future<int> mergeLayersBulk({required List<int> layerIds});
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
  Future<int> beginLayerOpacityEdit({required int layerId});
  Future<void> updateLayerOpacityEdit({
    required int editId,
    required double opacity,
  });
  Future<void> commitLayerOpacityEdit({required int editId});
  Future<void> cancelLayerOpacityEdit({required int editId});
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
