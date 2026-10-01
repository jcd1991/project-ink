part of 'canvas_screen.dart';

const int _compositeLayerId = -1;
const int _maxCpuHandoffSnapshotTiles = 256;

/// Serializes CPU tile refreshes with preview acknowledgements so tile
/// publication and stroke coverage advance as one coherent revision.
mixin _CanvasTileSynchronization on State<CanvasScreen> {
  bool get _awaitingPreviewCommit;
  set _awaitingPreviewCommit(bool value);
  CanvasDiagnosticRecorder get _canvasDiagnostics;
  int get _cpuCommitBatchId;
  set _cpuCommitBatchId(int value);
  bool get _disposed;
  int get _engineGeneration;
  int? get _lastPacketMicros;
  StrokeAcknowledgement? get _lastPublishedPreviewAcknowledgement;
  set _lastPublishedPreviewAcknowledgement(StrokeAcknowledgement? value);
  List<LayerView> get _layers;
  LivePreviewController? get _livePreviewSurface;
  LiveStrokeCoordinator get _liveStrokeCoordinator;
  List<StrokeAcknowledgement> get _pendingCpuStrokeAcks;
  List<StrokeAcknowledgement> get _pendingLiveStrokeAcks;
  List<Uint8List> get _pendingNativePackets;
  Phase1PerformanceTrace get _performanceTrace;
  int _previewIndexForAcknowledgement(StrokeAcknowledgement acknowledgement);
  int get _renderRevision;
  set _renderRevision(int value);
  bool get _strokeActive;
  StrokeOperationQueue get _strokeOperations;
  ValueNotifier<LiveStrokePreview?> get _strokePreview;
  TileCache get _tileBytes;
  TileImageCache get _tileImages;
  void _setStrokePreview(LiveStrokePreview? next);

  bool _refreshingTiles = false;
  bool _refreshRequested = false;
  bool _refreshInitialRequested = false;
  bool _initialTilesLoaded = false;

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
          'strokeWorkQueueDepth': _strokeOperations.pendingCount,
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
            'strokeWorkQueueDepth': _strokeOperations.pendingCount,
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
}
