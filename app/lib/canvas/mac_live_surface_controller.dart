import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../bridge/engine_api.dart';
import '../bridge/generated/api.dart' as rust;
import 'live_preview_controller.dart';
import 'mac_live_texture_adapter.dart';

/// Owns the optional Apple-platform Flutter texture and Rust live renderer as one
/// recoverable presentation session. The document engine remains authoritative
/// and callers keep their Flutter preview active until a GPU frame is ready.
class MacLiveSurfaceController implements LivePreviewController {
  MacLiveSurfaceController({
    required LiveRenderEngineApi engine,
    MacLiveTextureAdapter? textureAdapter,
    this.onTextureSubmission,
    this.onDiagnosticEvent,
  }) : _engine = engine,
       _textureAdapter = textureAdapter ?? MacLiveTextureAdapter();

  static const int _packetVersion = 3;
  static const int _headerBytes = 8;
  static const int _recordBytes = 56;
  static const int _maxRecordsPerPacket = 8192;
  static const int _maxPendingDabs = 65_536;
  static const int _maxSurfaceBytes = 128 * 1024 * 1024;
  static const Duration _gpuPumpInterval = Duration(milliseconds: 16);
  static const Duration _gpuPumpIdleTimeout = Duration(milliseconds: 120);

  final LiveRenderEngineApi _engine;
  final MacLiveTextureAdapter _textureAdapter;
  final void Function(int latencyMicros)? onTextureSubmission;
  final void Function(String type, Map<String, Object?> fields)?
  onDiagnosticEvent;
  final Stopwatch _latencyClock = Stopwatch()..start();
  int? _latestInputMicros;
  @override
  final ValueNotifier<int?> textureId = ValueNotifier<int?>(null);
  @override
  final ValueNotifier<bool> gpuFrameReady = ValueNotifier<bool>(false);
  final Map<_LiveDabKey, Uint8List> _pendingDabs = <_LiveDabKey, Uint8List>{};
  final Map<BigInt, StrokeAcknowledgement> _pendingAcknowledgements =
      <BigInt, StrokeAcknowledgement>{};

  rust.LiveSurfaceHandle? _surface;
  int? _registeredTextureId;
  int _physicalWidth = 0;
  int _physicalHeight = 0;
  int _viewportGeneration = 0;
  List<double>? _viewportMatrix;
  final Queue<_LiveSurfaceWorkItem> _tasks = Queue<_LiveSurfaceWorkItem>();
  Completer<void>? _idleCompleter;
  bool _drainingTasks = false;
  bool _pumpRequested = false;
  bool _pumpQueued = false;
  Completer<void>? _acknowledgementFlush;
  Timer? _acknowledgementTimer;
  Timer? _gpuPumpTimer;
  Timer? _gpuPumpIdleTimer;
  int? _lastAcknowledgementFlushMicros;
  bool _failed = false;
  bool _disposed = false;

  bool get isAvailable =>
      !_failed && _surface != null && textureId.value != null;

  @visibleForTesting
  Future<void> get pendingWork =>
      _idleCompleter?.future ?? Future<void>.value();

  /// Keep the immediate Flutter stroke preview visible while the next native
  /// texture frame is being submitted.
  @override
  void markInputPending({bool strokeStart = false}) {
    if (_disposed || _failed) {
      if (strokeStart) {
        onDiagnosticEvent?.call('gpu.preview_unavailable_at_stroke_start', {
          'disposed': _disposed,
          'failed': _failed,
        });
      }
      return;
    }
    if (onTextureSubmission != null) {
      _latestInputMicros = _latencyClock.elapsedMicroseconds;
    }
    // Keep the previous GPU frame on screen while new dabs are queued. The
    // GPU surface is the visible stroke path once it has produced a frame;
    // dropping back to the Flutter tail on every new stroke creates the
    // preview-line flash users see at stroke boundaries.
    if (strokeStart) onDiagnosticEvent?.call('gpu.stroke_preview_started', {});
    _startGpuPumpHeartbeat();
  }

  void _startGpuPumpHeartbeat() {
    if (_disposed || _failed) return;
    _gpuPumpIdleTimer?.cancel();
    _gpuPumpIdleTimer = Timer(_gpuPumpIdleTimeout, () {
      _gpuPumpIdleTimer = null;
      _gpuPumpTimer?.cancel();
      _gpuPumpTimer = null;
    });
    _gpuPumpTimer ??= Timer.periodic(_gpuPumpInterval, (_) => pump());
  }

  /// Synchronize the native target and document-to-physical-pixel transform
  /// with the actual canvas viewport. Repeated identical layouts are no-ops.
  @override
  void synchronizeViewport({
    required Size viewportSize,
    required double devicePixelRatio,
    required Offset pan,
    required double scale,
    required double rotation,
    required bool mirrored,
    required int documentWidth,
    required int documentHeight,
  }) {
    if (_disposed ||
        _failed ||
        !devicePixelRatio.isFinite ||
        devicePixelRatio <= 0 ||
        !scale.isFinite ||
        scale <= 0 ||
        !rotation.isFinite ||
        !pan.dx.isFinite ||
        !pan.dy.isFinite ||
        viewportSize.width <= 0 ||
        viewportSize.height <= 0 ||
        documentWidth <= 0 ||
        documentHeight <= 0) {
      return;
    }

    final width = (viewportSize.width * devicePixelRatio).ceil();
    final height = (viewportSize.height * devicePixelRatio).ceil();
    if (width < 1 ||
        height < 1 ||
        width > 8192 ||
        height > 8192 ||
        width * height * 4 > _maxSurfaceBytes) {
      _disable(StateError('Live preview target exceeds its memory budget.'));
      return;
    }
    final matrix = _documentToSurfaceMatrix(
      viewportSize: viewportSize,
      devicePixelRatio: devicePixelRatio,
      pan: pan,
      scale: scale,
      rotation: rotation,
      mirrored: mirrored,
      documentWidth: documentWidth,
      documentHeight: documentHeight,
    );
    if (_surface != null &&
        width == _physicalWidth &&
        height == _physicalHeight &&
        _sameMatrix(_viewportMatrix, matrix)) {
      return;
    }
    unawaited(
      _enqueue(() async {
        if (_disposed || _failed) return;
        final dimensionsChanged =
            _surface != null &&
            (width != _physicalWidth || height != _physicalHeight);
        if (_surface == null || dimensionsChanged) {
          await _replaceSurface(width, height, devicePixelRatio, matrix);
          return;
        }
        await _setViewport(matrix);
      }),
    );
  }

  /// Schedule a bounded drain/render pass without making the pointer callback
  /// wait for worker completion or GPU presentation.
  @override
  void pump() {
    if (_disposed || _failed) return;
    _pumpRequested = true;
    if (_surface == null) return;
    if (_pumpQueued) return;
    _pumpQueued = true;
    unawaited(_enqueue(_drainAndRender));
  }

  @override
  Future<void> acknowledge(StrokeAcknowledgement acknowledgement) {
    if (_disposed || _failed) return Future<void>.value();
    final previous = _pendingAcknowledgements[acknowledgement.stroke];
    if (previous == null ||
        acknowledgement.highestCommittedSequence >
            previous.highestCommittedSequence) {
      _pendingAcknowledgements[acknowledgement.stroke] = acknowledgement;
    }
    // The caller has already published the matching CPU pixels. Retire local
    // coverage now, before the coalesced GPU cleanup can wait on its timer or
    // the native queue, so a fully covered texture cannot double-paint them.
    _pendingDabs.removeWhere(
      (key, _) =>
          key.strokeId == acknowledgement.stroke &&
          key.sequence <= acknowledgement.highestCommittedSequence,
    );
    if (_pendingDabs.isEmpty) gpuFrameReady.value = false;

    // The CPU worker can publish one acknowledgement for every input packet.
    // Enqueuing a texture rebuild for each one makes the live surface replay
    // its entire retained dab set at Pencil sample rate. Coalesce those
    // monotonic acknowledgements and repaint once after retiring them; this
    // keeps texture work bounded by the canvas frame rate rather than input
    // packet count.
    final flush = _acknowledgementFlush ??= Completer<void>();
    _scheduleAcknowledgementFlush();
    return flush.future;
  }

  /// Acknowledgements clear and redraw the retained texture before publishing
  /// it. Tile commits can arrive faster than display refresh (about 90/s in
  /// the long Pencil trace), so let them coalesce and redraw at most once per
  /// 16 ms. This bounds full-surface GPU synchronization while keeping the
  /// overlay retirement delay to roughly one display frame.
  void _scheduleAcknowledgementFlush() {
    if (_disposed || _failed || _acknowledgementTimer != null) return;
    final nowMicros = _latencyClock.elapsedMicroseconds;
    final lastFlushMicros = _lastAcknowledgementFlushMicros;
    final remainingMicros =
        lastFlushMicros == null
            ? 0
            : (16000 - (nowMicros - lastFlushMicros)).clamp(0, 16000);
    _acknowledgementTimer = Timer(Duration(microseconds: remainingMicros), () {
      _acknowledgementTimer = null;
      final flush = _acknowledgementFlush;
      if (flush == null || flush.isCompleted) return;
      _lastAcknowledgementFlushMicros = _latencyClock.elapsedMicroseconds;
      unawaited(
        _enqueue(_flushAcknowledgements).then(
          (_) {
            if (_pendingAcknowledgements.isNotEmpty) {
              _scheduleAcknowledgementFlush();
              return;
            }
            if (!flush.isCompleted) flush.complete();
            if (identical(_acknowledgementFlush, flush)) {
              _acknowledgementFlush = null;
            }
          },
          onError: (Object error, StackTrace stack) {
            if (!flush.isCompleted) flush.completeError(error, stack);
            if (identical(_acknowledgementFlush, flush)) {
              _acknowledgementFlush = null;
            }
          },
        ),
      );
    });
  }

  Future<void> _flushAcknowledgements() async {
    final surface = _surface;
    var retiredAny = false;
    var acknowledgementCount = 0;
    while (_pendingAcknowledgements.isNotEmpty) {
      final batch = Map<BigInt, StrokeAcknowledgement>.of(
        _pendingAcknowledgements,
      );
      _pendingAcknowledgements.clear();
      acknowledgementCount += batch.length;
      for (final acknowledgement in batch.values) {
        _pendingDabs.removeWhere(
          (key, _) =>
              key.strokeId == acknowledgement.stroke &&
              key.sequence <= acknowledgement.highestCommittedSequence,
        );
        if (surface == null) continue;
        final acknowledgementStarted = _latencyClock.elapsedMicroseconds;
        await _engine.acknowledgeLiveSurface(
          surface,
          acknowledgement.stroke,
          acknowledgement.highestCommittedSequence,
        );
        retiredAny = true;
        onDiagnosticEvent?.call('gpu.stroke_acknowledged', {
          'strokeId': acknowledgement.stroke.toString(),
          'highestCommittedSequence': acknowledgement.highestCommittedSequence,
          'documentRevision': acknowledgement.revision,
          'pendingDabs': _pendingDabs.length,
          'coalescedBatch': true,
          'acknowledgementCallUs':
              _latencyClock.elapsedMicroseconds - acknowledgementStarted,
          'surfaceWorkQueueDepth': _tasks.length,
        });
      }
    }
    if (retiredAny) {
      onDiagnosticEvent?.call('gpu.acknowledgements_coalesced', {
        'acknowledgementCount': acknowledgementCount,
        'pendingDabs': _pendingDabs.length,
        'surfaceWorkQueueDepth': _tasks.length,
      });
      await _publishFrame();
    }
  }

  @override
  Future<void> cancelAllStrokes() {
    return _enqueue(() async {
      final surface = _surface;
      final strokeIds = _pendingDabs.keys.map((dab) => dab.strokeId).toSet();
      _pendingDabs.clear();
      if (surface == null) return;
      for (final strokeId in strokeIds) {
        await _engine.cancelLiveSurfaceStroke(surface, strokeId);
        onDiagnosticEvent?.call('gpu.stroke_cancelled', {
          'strokeId': strokeId.toString(),
        });
      }
      await _publishFrame();
    });
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _acknowledgementTimer?.cancel();
    _acknowledgementTimer = null;
    _gpuPumpTimer?.cancel();
    _gpuPumpTimer = null;
    _gpuPumpIdleTimer?.cancel();
    _gpuPumpIdleTimer = null;
    _pendingAcknowledgements.clear();
    final acknowledgementFlush = _acknowledgementFlush;
    _acknowledgementFlush = null;
    if (acknowledgementFlush != null && !acknowledgementFlush.isCompleted) {
      acknowledgementFlush.complete();
    }
    gpuFrameReady.value = false;
    textureId.value = null;
    try {
      await pendingWork;
    } catch (_) {
      // The ordinary CPU renderer remains available if cleanup follows a
      // device/driver error.
    }
    await _releaseSurface();
    _pendingDabs.clear();
    textureId.dispose();
    gpuFrameReady.dispose();
  }

  Future<void> _enqueue(Future<void> Function() task) {
    if (_disposed || _failed) return Future<void>.value();
    final completion = Completer<void>();
    _tasks.add(_LiveSurfaceWorkItem(task, completion));
    _idleCompleter ??= Completer<void>();
    if (!_drainingTasks) unawaited(_drainTasks());
    return completion.future;
  }

  Future<void> _drainTasks() async {
    if (_drainingTasks) return;
    _drainingTasks = true;
    try {
      while (_tasks.isNotEmpty) {
        final item = _tasks.removeFirst();
        if (!_disposed && !_failed) {
          try {
            await item.task();
          } catch (error, stack) {
            await _disable(error, stack);
          }
        }
        if (!item.completion.isCompleted) item.completion.complete();
      }
    } finally {
      _drainingTasks = false;
      final idle = _idleCompleter;
      _idleCompleter = null;
      if (idle != null && !idle.isCompleted) idle.complete();
    }
  }

  Future<void> _replaceSurface(
    int width,
    int height,
    double devicePixelRatio,
    List<double> matrix,
  ) async {
    gpuFrameReady.value = false;
    textureId.value = null;
    await _releaseSurface();

    rust.LiveSurfaceHandle? surface;
    int? registeredId;
    try {
      surface = await _engine.createLiveSurface(
        physicalWidth: width,
        physicalHeight: height,
        scaleMilli: (devicePixelRatio * 1000).round().clamp(1, 100000).toInt(),
      );
      final device = await _engine.liveSurfaceNativeDeviceHandle(surface);
      registeredId = await _textureAdapter.create(
        metalDeviceHandle: device,
        width: width,
        height: height,
      );
      final nativeTexture = await _textureAdapter.takeMetalTextureHandle(
        registeredId,
      );
      await _engine.attachLiveSurfaceNativeTexture(surface, nativeTexture);
      await _engine.attachLiveSurface(surface);
      _surface = surface;
      _registeredTextureId = registeredId;
      _physicalWidth = width;
      _physicalHeight = height;
      await _engine.setLiveViewport(surface, matrix, ++_viewportGeneration);
      _viewportMatrix = matrix;
      await _replayPendingDabs();
      await _textureAdapter.frameAvailable(registeredId);
      textureId.value = registeredId;
      onDiagnosticEvent?.call('gpu.surface_created', {
        'width': width,
        'height': height,
        'devicePixelRatio': devicePixelRatio,
        'textureId': registeredId,
      });
      if (_pendingDabs.isNotEmpty) gpuFrameReady.value = true;
      if (_pumpRequested) pump();
    } catch (_) {
      // The surface owns the transferred Metal reference after attachment, so
      // dispose Rust before unregistering the CoreVideo/IOSurface owner.
      if (surface != null) {
        try {
          await _engine.disposeLiveSurface(surface);
        } catch (_) {}
      }
      if (registeredId != null) {
        try {
          await _textureAdapter.dispose(registeredId);
        } catch (_) {}
      }
      rethrow;
    }
  }

  Future<void> _setViewport(List<double> matrix) async {
    final surface = _surface;
    final texture = _registeredTextureId;
    if (surface == null || texture == null) return;
    gpuFrameReady.value = false;
    await _engine.setLiveViewport(surface, matrix, ++_viewportGeneration);
    _viewportMatrix = matrix;
    await _textureAdapter.frameAvailable(texture);
    if (_pendingDabs.isNotEmpty) gpuFrameReady.value = true;
  }

  Future<void> _drainAndRender() async {
    final surface = _surface;
    if (surface == null) {
      _pumpQueued = false;
      return;
    }
    var remainingFullBatches = 4;
    var renderedAny = false;
    try {
      do {
        _pumpRequested = false;
        final packet = await _engine.drainLiveDabs(limit: _maxRecordsPerPacket);
        final records = _validateAndReadDabs(packet);
        if (records.isNotEmpty) {
          if (_pendingDabs.length + records.length > _maxPendingDabs) {
            throw StateError('Live preview dab retention reached its bound.');
          }
          await _engine.renderLiveDabPacket(surface, packet);
          onDiagnosticEvent?.call('canvas.gpu_dab_batch', {
            'dabCount': records.length,
            'packetBytes': packet.length,
            'strokeIds':
                records
                    .map((record) => record.key.strokeId.toString())
                    .toSet()
                    .length,
            'packetBase64': base64Encode(packet),
          });
          for (final record in records) {
            _pendingDabs[record.key] = record.bytes;
          }
          renderedAny = true;
        }
        final overflow = await _engine.drainLiveDabOverflowCount();
        if (overflow != 0) {
          // The CPU document has already accepted these confirmed samples, but
          // the GPU overlay is now incomplete. Stop showing that partial overlay
          // and let committed CPU tiles plus the Flutter tail preview carry the
          // rest of the stroke. Keeping a stale texture visible here can make a
          // correct CPU stroke appear to break or change shape.
          debugPrint(
            'Project Ink GPU preview fell behind by $overflow dabs; '
            'CPU commit remains authoritative.',
          );
          onDiagnosticEvent?.call('gpu.dab_overflow', {'dabs': overflow});
          await _fallbackToCpuPreview(overflow);
          return;
        }
        if (records.length == _maxRecordsPerPacket) {
          remainingFullBatches--;
          _pumpRequested = remainingFullBatches > 0;
        }
      } while (_pumpRequested && !_disposed && !_failed);
      if (renderedAny) await _publishFrame(measureInputLatency: true);
    } finally {
      // Keep _pumpQueued true for the entire drain/render operation. Clearing
      // it at entry let each 16 ms timer tick enqueue another full task while
      // Rust was still processing the current one, building a stale work queue
      // and delaying both texture frames and acknowledgements.
      _pumpQueued = false;
      if (_pumpRequested && !_disposed && !_failed) pump();
    }
  }

  Future<void> _replayPendingDabs() async {
    final surface = _surface;
    if (surface == null || _pendingDabs.isEmpty) return;
    final records = _pendingDabs.values.toList(growable: false);
    for (
      var offset = 0;
      offset < records.length;
      offset += _maxRecordsPerPacket
    ) {
      final end = math.min(offset + _maxRecordsPerPacket, records.length);
      final packet = _encodeDabPacket(records.sublist(offset, end));
      await _engine.renderLiveDabPacket(surface, packet);
    }
  }

  Future<void> _publishFrame({bool measureInputLatency = false}) async {
    final texture = _registeredTextureId;
    if (texture == null) return;
    await _textureAdapter.frameAvailable(texture);
    if (measureInputLatency) {
      final startedMicros = _latestInputMicros;
      _latestInputMicros = null;
      if (startedMicros != null) {
        onTextureSubmission?.call(
          _latencyClock.elapsedMicroseconds - startedMicros,
        );
      }
    }
    gpuFrameReady.value = _pendingDabs.isNotEmpty;
    onDiagnosticEvent?.call('canvas.gpu_frame_available', {
      'textureId': texture,
      'pendingDabs': _pendingDabs.length,
    });
  }

  Future<void> _releaseSurface() async {
    final surface = _surface;
    final texture = _registeredTextureId;
    _surface = null;
    _registeredTextureId = null;
    _physicalWidth = 0;
    _physicalHeight = 0;
    _viewportMatrix = null;
    if (surface != null) {
      try {
        await _engine.detachLiveSurface(surface);
      } catch (_) {}
      try {
        await _engine.disposeLiveSurface(surface);
      } catch (_) {}
    }
    if (texture != null) {
      try {
        await _textureAdapter.dispose(texture);
      } catch (_) {}
    }
  }

  Future<void> _disable(Object error, [StackTrace? stack]) async {
    if (_failed || _disposed) return;
    _failed = true;
    gpuFrameReady.value = false;
    textureId.value = null;
    debugPrint(
      'Project Ink native live preview unavailable; using CPU preview: $error',
    );
    onDiagnosticEvent?.call('hardware.gpu_preview_error', {
      'message': error.toString(),
      if (stack != null) 'stack': stack.toString(),
    });
    if (stack != null) debugPrint('$stack');
    await _releaseSurface();
  }

  Future<void> _fallbackToCpuPreview(int overflowDabs) async {
    if (_failed || _disposed) return;
    _failed = true;
    gpuFrameReady.value = false;
    textureId.value = null;
    _pendingDabs.clear();
    onDiagnosticEvent?.call('gpu.preview_fallback', {
      'reason': 'confirmed_dab_overflow',
      'overflowDabs': overflowDabs,
    });
    await _releaseSurface();
  }

  static List<_LiveDabRecord> _validateAndReadDabs(Uint8List packet) {
    if (packet.length < _headerBytes) {
      throw const FormatException('Live dab packet header is truncated.');
    }
    final data = ByteData.sublistView(packet);
    final version = data.getUint16(0, Endian.little);
    final flags = data.getUint16(2, Endian.little);
    final count = data.getUint32(4, Endian.little);
    if (version != _packetVersion ||
        flags != 0 ||
        count > _maxRecordsPerPacket ||
        packet.length != _headerBytes + count * _recordBytes) {
      throw const FormatException(
        'Live dab packet is malformed or exceeds its bound.',
      );
    }
    final records = <_LiveDabRecord>[];
    for (var index = 0; index < count; index++) {
      final offset = _headerBytes + index * _recordBytes;
      final phase = data.getUint8(offset + 44);
      if (phase > 2) {
        throw const FormatException(
          'Live dab packet contains an unknown phase.',
        );
      }
      for (
        var reserved = offset + 49;
        reserved < offset + _recordBytes;
        reserved++
      ) {
        if (data.getUint8(reserved) != 0) {
          throw const FormatException(
            'Live dab packet reserved bytes must be zero.',
          );
        }
      }
      final low = data.getUint64(offset, Endian.little);
      final high = data.getUint64(offset + 8, Endian.little);
      final strokeId = (BigInt.from(high) << 64) | BigInt.from(low);
      final sequence = data.getUint32(offset + 16, Endian.little);
      final dabIndex = data.getUint32(offset + 20, Endian.little);
      records.add(
        _LiveDabRecord(
          key: _LiveDabKey(strokeId, sequence, dabIndex),
          bytes: Uint8List.fromList(
            packet.sublist(offset, offset + _recordBytes),
          ),
        ),
      );
    }
    return records;
  }

  static Uint8List _encodeDabPacket(List<Uint8List> records) {
    final packet = Uint8List(_headerBytes + records.length * _recordBytes);
    final data = ByteData.sublistView(packet);
    data.setUint16(0, _packetVersion, Endian.little);
    data.setUint16(2, 0, Endian.little);
    data.setUint32(4, records.length, Endian.little);
    var offset = _headerBytes;
    for (final record in records) {
      if (record.length != _recordBytes) {
        throw const FormatException('Live dab record has an invalid width.');
      }
      packet.setRange(offset, offset + _recordBytes, record);
      offset += _recordBytes;
    }
    return packet;
  }

  static List<double> _documentToSurfaceMatrix({
    required Size viewportSize,
    required double devicePixelRatio,
    required Offset pan,
    required double scale,
    required double rotation,
    required bool mirrored,
    required int documentWidth,
    required int documentHeight,
  }) {
    final direction = mirrored ? -1.0 : 1.0;
    final cosine = math.cos(rotation);
    final sine = math.sin(rotation);
    final a = cosine * scale * direction;
    final b = sine * scale * direction;
    final c = -sine * scale;
    final d = cosine * scale;
    final tx =
        viewportSize.width / 2 +
        pan.dx -
        a * documentWidth / 2 -
        c * documentHeight / 2;
    final ty =
        viewportSize.height / 2 +
        pan.dy -
        b * documentWidth / 2 -
        d * documentHeight / 2;
    return <double>[
      a * devicePixelRatio,
      b * devicePixelRatio,
      c * devicePixelRatio,
      d * devicePixelRatio,
      tx * devicePixelRatio,
      ty * devicePixelRatio,
    ];
  }

  static bool _sameMatrix(List<double>? left, List<double> right) {
    if (left == null || left.length != right.length) return false;
    for (var index = 0; index < right.length; index++) {
      if ((left[index] - right[index]).abs() > 0.000001) return false;
    }
    return true;
  }
}

class _LiveDabRecord {
  const _LiveDabRecord({required this.key, required this.bytes});
  final _LiveDabKey key;
  final Uint8List bytes;
}

class _LiveDabKey {
  const _LiveDabKey(this.strokeId, this.sequence, this.dabIndex);
  final BigInt strokeId;
  final int sequence;
  final int dabIndex;

  @override
  int get hashCode => Object.hash(strokeId, sequence, dabIndex);

  @override
  bool operator ==(Object other) =>
      other is _LiveDabKey &&
      strokeId == other.strokeId &&
      sequence == other.sequence &&
      dabIndex == other.dabIndex;
}

class _LiveSurfaceWorkItem {
  const _LiveSurfaceWorkItem(this.task, this.completion);

  final Future<void> Function() task;
  final Completer<void> completion;
}
