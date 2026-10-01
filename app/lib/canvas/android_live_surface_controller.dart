import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../bridge/engine_api.dart';
import 'android_live_texture_adapter.dart';
import 'live_preview_controller.dart';
import 'native_live_texture_adapter.dart';

/// Shared lifecycle for platform-native dab textures. Native surfaces are an
/// ephemeral preview only; Rust CPU tiles remain authoritative for the
/// document and the ordinary Flutter painter remains visible until native
/// presentation succeeds.
class NativeLiveSurfaceController implements LivePreviewController {
  NativeLiveSurfaceController({
    required LiveDabSourceApi engine,
    required NativeLiveTextureAdapter textureAdapter,
    required String platformName,
    required int maxSurfaceBytes,
  }) : _engine = engine,
       _textureAdapter = textureAdapter,
       _platformName = platformName,
       _maxSurfaceBytes = maxSurfaceBytes;

  static const int _packetVersion = 3;
  static const int _headerBytes = 8;
  static const int _recordBytes = 56;
  static const int _maxRecordsPerPacket = 2048;
  static const int _maxPendingDabs = 65_536;
  final LiveDabSourceApi _engine;
  final NativeLiveTextureAdapter _textureAdapter;
  final String _platformName;
  final int _maxSurfaceBytes;

  @override
  final ValueNotifier<int?> textureId = ValueNotifier<int?>(null);
  @override
  final ValueNotifier<bool> gpuFrameReady = ValueNotifier<bool>(false);

  final Map<_DabKey, Uint8List> _pendingDabs = <_DabKey, Uint8List>{};
  Future<void> _work = Future<void>.value();
  bool _pumpRequested = false;
  bool _pumpQueued = false;
  bool _failed = false;
  bool _disposed = false;
  int? _registeredTextureId;
  int _physicalWidth = 0;
  int _physicalHeight = 0;
  int _viewportGeneration = 0;
  List<double>? _viewportMatrix;

  @visibleForTesting
  Future<void> get pendingWork => _work;

  @override
  void markInputPending({bool strokeStart = false}) {
    if (strokeStart && !_disposed && !_failed && gpuFrameReady.value) {
      gpuFrameReady.value = false;
    }
  }

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
      _disable(
        StateError('$_platformName live preview exceeds its surface budget.'),
      );
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
    if (_registeredTextureId != null &&
        width == _physicalWidth &&
        height == _physicalHeight &&
        _sameMatrix(_viewportMatrix, matrix)) {
      return;
    }
    unawaited(
      _enqueue(() async {
        if (_disposed || _failed) return;
        await _ensureTexture(width, height, matrix);
      }),
    );
  }

  @override
  void pump() {
    if (_disposed || _failed) return;
    _pumpRequested = true;
    if (_registeredTextureId == null || _pumpQueued) return;
    _pumpQueued = true;
    unawaited(_enqueue(_drainAndRender));
  }

  @override
  Future<void> acknowledge(StrokeAcknowledgement acknowledgement) {
    return _enqueue(() async {
      final texture = _registeredTextureId;
      _pendingDabs.removeWhere(
        (key, _) =>
            key.strokeId == acknowledgement.stroke &&
            key.sequence <= acknowledgement.highestCommittedSequence,
      );
      if (texture == null) return;
      await _textureAdapter.acknowledge(
        texture,
        acknowledgement.stroke,
        acknowledgement.highestCommittedSequence,
      );
      gpuFrameReady.value = true;
    });
  }

  @override
  Future<void> cancelAllStrokes() {
    return _enqueue(() async {
      _pendingDabs.clear();
      final texture = _registeredTextureId;
      if (texture == null) return;
      await _textureAdapter.cancelAll(texture);
      gpuFrameReady.value = false;
    });
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    gpuFrameReady.value = false;
    textureId.value = null;
    try {
      await _work;
    } catch (_) {
      // Native preview teardown is best-effort; document state is unaffected.
    }
    await _releaseTexture();
    _pendingDabs.clear();
    textureId.dispose();
    gpuFrameReady.dispose();
  }

  Future<void> _ensureTexture(
    int width,
    int height,
    List<double> matrix,
  ) async {
    final dimensionsChanged =
        _registeredTextureId != null &&
        (width != _physicalWidth || height != _physicalHeight);
    if (_registeredTextureId == null || dimensionsChanged) {
      gpuFrameReady.value = false;
      textureId.value = null;
      await _releaseTexture();
      final id = await _textureAdapter.create(width: width, height: height);
      try {
        await _textureAdapter.setViewport(id, matrix, ++_viewportGeneration);
      } catch (_) {
        await _textureAdapter.dispose(id);
        rethrow;
      }
      _registeredTextureId = id;
      _physicalWidth = width;
      _physicalHeight = height;
      _viewportMatrix = matrix;
      textureId.value = id;
      await _replayPendingDabs(id);
      if (_pendingDabs.isNotEmpty) gpuFrameReady.value = true;
      if (_pumpRequested) pump();
      return;
    }
    final id = _registeredTextureId!;
    gpuFrameReady.value = false;
    await _textureAdapter.setViewport(id, matrix, ++_viewportGeneration);
    _viewportMatrix = matrix;
    if (_pendingDabs.isNotEmpty) gpuFrameReady.value = true;
  }

  Future<void> _drainAndRender() async {
    _pumpQueued = false;
    final texture = _registeredTextureId;
    if (texture == null) return;
    var remainingFullBatches = 4;
    do {
      _pumpRequested = false;
      final packet = await _engine.drainLiveDabs(limit: _maxRecordsPerPacket);
      final records = _validateAndReadDabs(packet);
      if (records.isNotEmpty) {
        if (_pendingDabs.length + records.length > _maxPendingDabs) {
          throw StateError(
            '$_platformName live preview retention reached its bound.',
          );
        }
        await _textureAdapter.renderDabs(texture, packet);
        for (final record in records) {
          _pendingDabs[record.key] = record.bytes;
        }
        gpuFrameReady.value = true;
      }
      if (await _engine.drainLiveDabOverflowCount() != 0) {
        throw StateError('Rust reported confirmed-dab live-preview overflow.');
      }
      if (records.length == _maxRecordsPerPacket) {
        remainingFullBatches--;
        _pumpRequested = remainingFullBatches > 0;
      }
    } while (_pumpRequested && !_disposed && !_failed);
    if (_pumpRequested && !_disposed && !_failed) pump();
  }

  Future<void> _enqueue(Future<void> Function() task) {
    final next = _work.then((_) async {
      if (_disposed || _failed) return;
      await task();
    });
    _work = next.catchError((Object error, StackTrace stack) async {
      await _disable(error, stack);
    });
    return _work;
  }

  Future<void> _releaseTexture() async {
    final texture = _registeredTextureId;
    _registeredTextureId = null;
    _physicalWidth = 0;
    _physicalHeight = 0;
    _viewportMatrix = null;
    if (texture != null) {
      try {
        await _textureAdapter.dispose(texture);
      } catch (_) {}
    }
  }

  Future<void> _replayPendingDabs(int texture) async {
    final records = _pendingDabs.values.toList(growable: false);
    for (
      var offset = 0;
      offset < records.length;
      offset += _maxRecordsPerPacket
    ) {
      final end = math.min(offset + _maxRecordsPerPacket, records.length);
      final packet = _encodeDabPacket(records.sublist(offset, end));
      await _textureAdapter.renderDabs(texture, packet);
    }
  }

  Future<void> _disable(Object error, [StackTrace? stack]) async {
    if (_failed || _disposed) return;
    _failed = true;
    gpuFrameReady.value = false;
    textureId.value = null;
    debugPrint(
      'Project Ink $_platformName live preview unavailable; using Flutter preview: $error',
    );
    if (stack != null) debugPrint('$stack');
    await _releaseTexture();
  }

  static List<_DabRecord> _validateAndReadDabs(Uint8List packet) {
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
      throw const FormatException('Live dab packet is malformed.');
    }
    final records = <_DabRecord>[];
    for (var index = 0; index < count; index++) {
      final offset = _headerBytes + index * _recordBytes;
      final phase = data.getUint8(offset + 44);
      final x = data.getFloat32(offset + 24, Endian.little);
      final y = data.getFloat32(offset + 28, Endian.little);
      final radius = data.getFloat32(offset + 32, Endian.little);
      final opacity = data.getFloat32(offset + 36, Endian.little);
      final rotation = data.getFloat32(offset + 40, Endian.little);
      if (phase > 2 ||
          <double>[
            x,
            y,
            radius,
            opacity,
            rotation,
          ].any((value) => !value.isFinite) ||
          radius < 0 ||
          radius > 131072 ||
          opacity < 0 ||
          opacity > 1) {
        throw const FormatException('Live dab record is invalid.');
      }
      for (
        var reserved = offset + 49;
        reserved < offset + _recordBytes;
        reserved++
      ) {
        if (data.getUint8(reserved) != 0) {
          throw const FormatException('Live dab reserved bytes are nonzero.');
        }
      }
      final low = _readUint64(data, offset);
      final high = _readUint64(data, offset + 8);
      final strokeId = (high << 64) | low;
      final sequence = data.getUint32(offset + 16, Endian.little);
      final dabIndex = data.getUint32(offset + 20, Endian.little);
      records.add(
        _DabRecord(
          key: _DabKey(strokeId, sequence, dabIndex),
          bytes: Uint8List.fromList(
            packet.sublist(offset, offset + _recordBytes),
          ),
        ),
      );
    }
    return records;
  }

  static BigInt _readUint64(ByteData data, int offset) =>
      (BigInt.from(data.getUint32(offset + 4, Endian.little)) << 32) |
      BigInt.from(data.getUint32(offset, Endian.little));

  static Uint8List _encodeDabPacket(List<Uint8List> records) {
    final packet = Uint8List(_headerBytes + records.length * _recordBytes);
    final data = ByteData.sublistView(packet);
    data.setUint16(0, _packetVersion, Endian.little);
    data.setUint16(2, 0, Endian.little);
    data.setUint32(4, records.length, Endian.little);
    var offset = _headerBytes;
    for (final record in records) {
      if (record.length != _recordBytes) {
        throw const FormatException('Live dab record has an invalid size.');
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

/// Android currently uses a SurfaceProducer with a triple-buffer-safe memory
/// ceiling. Keep this public wrapper stable while sharing lifecycle and packet
/// validation with other native texture backends.
class AndroidLiveSurfaceController extends NativeLiveSurfaceController {
  AndroidLiveSurfaceController({
    required super.engine,
    AndroidLiveTextureAdapter? textureAdapter,
  }) : super(
         textureAdapter: textureAdapter ?? AndroidLiveTextureAdapter(),
         platformName: 'Android',
         maxSurfaceBytes: 85_333_333,
       );
}

class _DabRecord {
  const _DabRecord({required this.key, required this.bytes});
  final _DabKey key;
  final Uint8List bytes;
}

class _DabKey {
  const _DabKey(this.strokeId, this.sequence, this.dabIndex);
  final BigInt strokeId;
  final int sequence;
  final int dabIndex;

  @override
  int get hashCode => Object.hash(strokeId, sequence, dabIndex);

  @override
  bool operator ==(Object other) =>
      other is _DabKey &&
      strokeId == other.strokeId &&
      sequence == other.sequence &&
      dabIndex == other.dabIndex;
}
