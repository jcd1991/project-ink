import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../bridge/engine_api.dart';
import 'canvas_diagnostic_recorder.dart';
import 'canvas_composite_tile_snapshot_reader.dart';
import 'canvas_cpu_acknowledgement_batch.dart';
import 'canvas_preview_synchronization.dart';
import 'canvas_stroke_preview_actions.dart';
import 'tile_cache.dart';

const int _maxCpuHandoffSnapshotTiles = 256;

/// Engine identity captured for one tile refresh operation.
@immutable
class CanvasTileSynchronizationSession {
  const CanvasTileSynchronizationSession({
    required this.engine,
    required this.generation,
  });

  final EngineApi engine;
  final int generation;
}

/// Immutable view of route state needed by one tile refresh decision.
///
/// The host creates this value at the point where a refresh needs the data,
/// so asynchronous work does not retain mutable layer lists or queue owners.
@immutable
class CanvasTileSynchronizationSnapshot {
  CanvasTileSynchronizationSnapshot({
    required this.lastPacketMicros,
    required Iterable<int> visibleRasterLayerIds,
    required this.strokeWorkQueueDepth,
    required this.pendingNativePacketCount,
  }) : visibleRasterLayerIds = List<int>.unmodifiable(visibleRasterLayerIds);

  final int? lastPacketMicros;
  final List<int> visibleRasterLayerIds;
  final int strokeWorkQueueDepth;
  final int pendingNativePacketCount;
}

/// UI effects performed only after a coherent tile publication is prepared.
class CanvasTileSynchronizationEffects {
  const CanvasTileSynchronizationEffects({
    required this.publishCanvasState,
    required this.markVisibleUpdate,
  });

  final VoidCallback publishCanvasState;
  final void Function({
    required int packetMicros,
    required Duration tileDecode,
    required int dirtyTiles,
  })
  markVisibleUpdate;
}

/// State and callbacks consumed by the ordered CPU tile publication service.
abstract interface class CanvasTileSynchronizationHost {
  bool get disposed;
  bool get isMounted;
  CanvasTileSynchronizationSession captureSession();
  bool isSessionCurrent(CanvasTileSynchronizationSession session);
  CanvasTileSynchronizationSnapshot captureSnapshot();
  bool get strokeActive;
}

/// Serializes CPU tile refreshes with preview acknowledgements so tile
/// publication and stroke coverage advance as one coherent revision.
class CanvasTileSynchronization {
  CanvasTileSynchronization(
    this.host, {
    required this.diagnostics,
    required this.previewSynchronization,
    required this.strokePreviewActions,
    required this.effects,
    CanvasCompositeTileSnapshotReader snapshotReader =
        const CanvasCompositeTileSnapshotReader(),
  }) : _snapshotReader = snapshotReader;

  final CanvasTileSynchronizationHost host;
  final CanvasDiagnosticRecorder diagnostics;
  final CanvasPreviewSynchronization previewSynchronization;
  final CanvasTilePreviewActions strokePreviewActions;
  final CanvasTileSynchronizationEffects effects;
  final CanvasCompositeTileSnapshotReader _snapshotReader;
  final TileCache tileBytes = TileCache();
  TileImageCache tileImages = TileImageCache();
  bool _refreshingTiles = false;
  bool _refreshRequested = false;
  bool _refreshInitialRequested = false;
  bool _initialTilesLoaded = false;
  Timer? _pollTimer;
  int _cpuCommitBatchId = 0;
  int _renderRevision = 0;
  final List<StrokeAcknowledgement> _pendingCpuStrokeAcks =
      <StrokeAcknowledgement>[];
  final List<StrokeAcknowledgement> _pendingLiveStrokeAcks =
      <StrokeAcknowledgement>[];

  bool get isPolling => _pollTimer != null;

  int get renderRevision => _renderRevision;

  /// Starts the periodic fallback that discovers Rust tile invalidations.
  ///
  /// Pointer completion and history actions still request immediate refreshes;
  /// polling only catches renderer work that completes asynchronously.
  void startPolling({required Duration interval}) {
    if (host.disposed || _pollTimer != null) return;
    _pollTimer = Timer.periodic(interval, (_) => unawaited(refreshTiles()));
  }

  /// Stops refresh polling when the canvas route releases this owner.
  void dispose() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _pendingCpuStrokeAcks.clear();
    _pendingLiveStrokeAcks.clear();
    tileBytes.clear();
    tileImages.dispose();
  }

  void resetForEngineReplacement() {
    _refreshRequested = false;
    _refreshInitialRequested = false;
    _initialTilesLoaded = false;
    clearPendingLiveAcknowledgements();
    tileBytes.clear();
    tileImages.dispose();
    tileImages = TileImageCache();
    _renderRevision = 0;
  }

  void clearPendingLiveAcknowledgements() {
    _pendingLiveStrokeAcks.clear();
  }

  Future<void> refreshTiles({bool initial = false}) async {
    if (host.disposed) return;
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
    final session = host.captureSession();
    final engine = session.engine;
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
        final snapshot = host.captureSnapshot();
        diagnostics.record('canvas.cpu_tile_poll_deferred', {
          'revision': batch.revision,
          'strokeWorkQueueDepth': snapshot.strokeWorkQueueDepth,
          'nativePacketQueueDepth': snapshot.pendingNativePacketCount,
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
        diagnostics.record('canvas.cpu_commit_batch_received', {
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
      if (previewSynchronization.surface != null) {
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
      if (!host.isSessionCurrent(session)) {
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
          host.captureSnapshot().visibleRasterLayerIds.toSet();
      if (visibleLayers.isEmpty) {
        visibleLayers.add(engine.documentInfo.primaryRasterLayer);
      }
      final updates = batch.tiles
          .where(
            (update) =>
                // Layer-property changes (especially visibility) arrive as
                // full redraws with per-layer tile descriptors. Keep hidden
                // layer descriptors in that batch so their coordinates are
                // still recomposited: filtering them here can consume the
                // only invalidation before the updated layer projection is
                // published, leaving stale/blank composite tiles behind.
                fullRedraw ||
                update.layer == compositeTileLayerId ||
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
      final acknowledgementBatch = CanvasCpuAcknowledgementBatch.plan(
        pending: cpuStrokeAcknowledgements,
        maxTileCount: _maxCpuHandoffSnapshotTiles,
      );
      final acknowledgedCoordinates = acknowledgementBatch.coordinates;
      final acknowledgedTileRevisions = acknowledgementBatch.tileRevisions;
      final selectedCpuAcknowledgements = acknowledgementBatch.acknowledgements;
      final oversizedSnapshotAcknowledgement =
          acknowledgementBatch.oversizedAcknowledgement;
      if (acknowledgementBatch.hasDeferredAcknowledgements) {
        diagnostics.record('canvas.cpu_commit_snapshot_deferred', {
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
        diagnostics.record('canvas.cpu_commit_snapshot_multipart', {
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
      final snapshot = await _snapshotReader.read(
        engine: engine,
        coordinates: snapshotCoordinates,
        onPartStarted: ({
          required partIndex,
          required partCount,
          required tileCount,
        }) {
          diagnostics.record('canvas.cpu_commit_snapshot_part', {
            'commitId': cpuCommitBatchId,
            'partIndex': partIndex,
            'partCount': partCount,
            'tileCount': tileCount,
          });
        },
      );
      snapshotPartCount = snapshot.partCount;
      compositeSnapshotReadUs = snapshot.elapsedMicroseconds;
      snapshotRevision = snapshot.revision;
      snapshotCoherent = snapshot.isCoherent;
      snapshotPixels.addAll(snapshot.pixels);
      if (!snapshotCoherent) {
        snapshotPixels.clear();
        diagnostics.record('canvas.cpu_commit_snapshot_deferred', {
          'commitId': cpuCommitBatchId,
          'reason': 'document_revision_changed_between_parts',
          'tileCount': snapshotCoordinates.length,
        });
      } else if (snapshotRevision != null) {
        revision = math.max(revision, snapshotRevision);
        diagnostics.record('canvas.cpu_commit_pixel_snapshot', {
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
        tileBytes.clear();
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
                snapshotRevision < requiredAcknowledgementRevision ||
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
        if (!host.isSessionCurrent(session)) {
          return;
        }
        final accepted = tileBytes.put(
          revision,
          compositeTileLayerId,
          coordinate.$1,
          coordinate.$2,
          bytes,
        );
        if (!accepted) continue;
        diagnostics.recordCompositeTile(
          revision: revision,
          x: coordinate.$1,
          y: coordinate.$2,
          pixelBytes: bytes,
          // Preserve exact CPU output for the committed final frame. During
          // the stroke only compact hashes are logged, keeping long captures
          // within their fixed size budget.
          includePixels:
              !host.strokeActive &&
              previewSynchronization.awaitingPreviewCommit,
        );
        final key = TileCacheKey(
          revision,
          compositeTileLayerId,
          coordinate.$1,
          coordinate.$2,
        );
        final tileImageClock = Stopwatch()..start();
        await tileImages.put(key, bytes);
        tileImageClock.stop();
        tileImageDecodeUs += tileImageClock.elapsedMicroseconds;
        decodedTileCount++;
        changed = true;
      }
      if (deferredAcknowledgedTiles > 0) {
        diagnostics.record('canvas.cpu_commit_tiles_deferred', {
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
        tileImages.retainRevision(revision);
      } else {
        // Dirty images are decoded into the new revision while the current
        // frame remains visible. Promote unchanged tiles only after every
        // replacement image is ready, then switch the revision in the same
        // state publication that advances live stroke coverage.
        final previousRevision = renderRevision;
        tileImages.promoteRevision(previousRevision, revision);
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
                        tile.layer == compositeTileLayerId &&
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
                snapshotRevision >= acknowledgement.revision &&
                allDirtyTilePixelsDecoded);
        if (hasPublishedPixels) {
          publishedPixelAcknowledgements.add(acknowledgement);
        }
        final previewIndex =
            hasPublishedPixels
                ? _previewIndexForAcknowledgement(acknowledgement)
                : -1;
        if (previewIndex < 0) continue;
        previewSynchronization.lastPublishedPreviewAcknowledgement =
            acknowledgement;
        diagnostics.record('canvas.cpu_commit_handoff', {
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
            (previewSynchronization.strokePreview.value == null ||
                _previewIndexForAcknowledgement(acknowledgement) < 0),
      );
      // A full redraw with no tiles is a valid empty document (for example,
      // undoing the only stroke). The cache has already retired the previous
      // frame above, so repaint even when no replacement image was decoded.
      if ((changed || fullRedraw || previewProgressChanged) && host.isMounted) {
        final livePreview = previewSynchronization.strokePreview.value;
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
            previewSynchronization.setStrokePreview(
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
            strokePreviewActions.retireThrough(candidateThrough);
          }
          final committedPreview = previewSynchronization.strokePreview.value;
          if (!host.strokeActive &&
              previewSynchronization.awaitingPreviewCommit &&
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
                previewSynchronization.lastPublishedPreviewAcknowledgement;
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
            previewSynchronization.setStrokePreview(null);
            strokePreviewActions.clear();
            previewSynchronization.lastPublishedPreviewAcknowledgement = null;
            previewSynchronization.awaitingPreviewCommit = false;
            _pendingCpuStrokeAcks.clear();
          }
        }
        final packetMicros = host.captureSnapshot().lastPacketMicros;
        final dirtyTiles = updates.length;
        final tileDecode = tileDecodeClock.elapsed;
        diagnostics.record('canvas.cpu_commit_stage_timing', {
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
        effects.publishCanvasState();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final frameSnapshot = host.captureSnapshot();
          diagnostics.record('canvas.cpu_frame_presented', {
            'revision': revision,
            'dirtyTiles': dirtyTiles,
            'fullRedraw': fullRedraw,
            ...cpuCoverageFrameFields,
            'strokeWorkQueueDepth': frameSnapshot.strokeWorkQueueDepth,
            'nativePacketQueueDepth': frameSnapshot.pendingNativePacketCount,
            'batchToFrameUs':
                tileDecodeClock.elapsedMicroseconds - batchReceivedAtRefreshUs,
            'refreshToFrameUs': tileDecodeClock.elapsedMicroseconds,
            'renderer': 'flutter_canvas',
            'gpuPreviewReady':
                previewSynchronization.surface?.gpuFrameReady.value ?? false,
          });
          final retired = retiredPreviewFields;
          if (retired != null) {
            diagnostics.record('canvas.live_preview_retired', retired);
          }
        });
        _scheduleLiveStrokeAcknowledgements(revision);
        if (packetMicros != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!host.isMounted) return;
            effects.markVisibleUpdate(
              packetMicros: packetMicros,
              tileDecode: tileDecode,
              dirtyTiles: dirtyTiles,
            );
          });
        }
      }
      // CPU pixels may arrive after the UI preview has already ended (for
      // example after a tool/document transition). Once a commit's immutable
      // pixels are present, there is no live geometry left for it to retire;
      // discard its acknowledgement instead of snapshotting it on every poll.
      if (previewSynchronization.strokePreview.value == null &&
          publishedCpuAcknowledgements.isNotEmpty) {
        _pendingCpuStrokeAcks.removeWhere(
          publishedCpuAcknowledgements.contains,
        );
      }
    } catch (error, stack) {
      if (host.isSessionCurrent(session)) {
        diagnostics.recordError('canvas_tile_refresh', error, stack);
        debugPrint('Project Ink tile refresh failed: $error\n$stack');
      }
    } finally {
      _refreshingTiles = false;
      if (_refreshRequested && !host.disposed) {
        final retryInitial = _refreshInitialRequested;
        _refreshRequested = false;
        _refreshInitialRequested = false;
        // Yield once so any queued pointer packet and its worker event are
        // visible before the follow-up drain. This is intentionally a single
        // coalesced retry; the regular 16 ms poll remains the backstop.
        scheduleMicrotask(() {
          if (!host.disposed) unawaited(refreshTiles(initial: retryInitial));
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
    final liveSurface = previewSynchronization.surface;
    if (liveSurface == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (host.disposed ||
          !identical(liveSurface, previewSynchronization.surface)) {
        return;
      }
      for (final acknowledgement in eligible) {
        unawaited(liveSurface.acknowledge(acknowledgement));
      }
    });
  }

  int _previewIndexForAcknowledgement(StrokeAcknowledgement acknowledgement) =>
      strokePreviewActions.previewIndexForAcknowledgement(acknowledgement);
}
