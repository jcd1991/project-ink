import 'package:flutter/services.dart';

import 'native_live_texture_adapter.dart';

/// Bounded Android SurfaceProducer control plane. Dab samples cross as a
/// validated binary packet; no pixel buffers or document data use JSON.
class AndroidLiveTextureAdapter implements NativeLiveTextureAdapter {
  AndroidLiveTextureAdapter({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'org.projectink.studio/live_texture_v1';
  static const int _maxRecordsPerPacket = 2048;
  static const int _maxPacketsPerBatch = 4;
  static const int _headerBytes = 8;
  static const int _recordBytes = 56;
  final MethodChannel _channel;

  @override
  Future<int> create({required int width, required int height}) async {
    if (width < 1 || width > 8192 || height < 1 || height > 8192) {
      throw ArgumentError(
        'Live texture dimensions must be between 1 and 8192.',
      );
    }
    // SurfaceProducer can queue multiple buffers. Bound this allocation so
    // total native preview memory remains below the shared 256 MiB budget.
    if (width * height * 4 > 85_333_333) {
      throw ArgumentError('Live texture exceeds the Android buffer budget.');
    }
    final response = await _channel.invokeMapMethod<Object?, Object?>(
      'create',
      <String, Object>{'width': width, 'height': height},
    );
    final textureId = response?['textureId'];
    if (textureId is! int || textureId < 0) {
      throw PlatformException(
        code: 'invalid_texture_id',
        message: 'The Android texture adapter returned an invalid ID.',
      );
    }
    return textureId;
  }

  @override
  Future<void> setViewport(
    int textureId,
    List<double> matrix,
    int generation,
  ) async {
    _validateTextureId(textureId);
    if (matrix.length != 6 || matrix.any((value) => !value.isFinite)) {
      throw ArgumentError.value(matrix, 'matrix');
    }
    if (generation < 0 || generation > 0x7fffffffffffffff) {
      throw RangeError.range(generation, 0, 0x7fffffffffffffff, 'generation');
    }
    await _channel.invokeMethod<void>('setViewport', <String, Object>{
      'textureId': textureId,
      'matrix': matrix,
      'generation': generation,
    });
  }

  @override
  Future<void> renderDabs(int textureId, Uint8List packet) async {
    _validateTextureId(textureId);
    if (packet.length < _headerBytes ||
        packet.length > _headerBytes + _maxRecordsPerPacket * _recordBytes) {
      throw ArgumentError.value(packet.length, 'packet.length');
    }
    await _channel.invokeMethod<void>('renderDabs', <String, Object>{
      'textureId': textureId,
      'packet': packet,
    });
  }

  @override
  Future<void> renderDabBatches(int textureId, List<Uint8List> packets) async {
    _validateTextureId(textureId);
    if (packets.isEmpty || packets.length > _maxPacketsPerBatch) {
      throw ArgumentError.value(packets.length, 'packets.length');
    }
    for (final packet in packets) {
      if (packet.length < _headerBytes ||
          packet.length > _headerBytes + _maxRecordsPerPacket * _recordBytes) {
        throw ArgumentError.value(packet.length, 'packet.length');
      }
    }
    await _channel.invokeMethod<void>('renderDabBatches', <String, Object>{
      'textureId': textureId,
      'packets': packets,
    });
  }

  @override
  Future<void> acknowledge(int textureId, BigInt strokeId, int sequence) async {
    _validateTextureId(textureId);
    if (strokeId.isNegative || strokeId >= (BigInt.one << 128)) {
      throw ArgumentError.value(strokeId, 'strokeId');
    }
    if (sequence < 0 || sequence > 0xffffffff) {
      throw RangeError.range(sequence, 0, 0xffffffff, 'sequence');
    }
    await _channel.invokeMethod<void>('acknowledge', <String, Object>{
      'textureId': textureId,
      'strokeId': strokeId.toRadixString(16).padLeft(32, '0'),
      'sequence': sequence,
    });
  }

  @override
  Future<void> cancelAll(int textureId) async {
    _validateTextureId(textureId);
    await _channel.invokeMethod<void>('cancelAll', <String, Object>{
      'textureId': textureId,
    });
  }

  @override
  Future<void> dispose(int textureId) async {
    _validateTextureId(textureId);
    await _channel.invokeMethod<void>('dispose', <String, Object>{
      'textureId': textureId,
    });
  }

  static void _validateTextureId(int textureId) {
    if (textureId < 0) throw ArgumentError.value(textureId, 'textureId');
  }
}
