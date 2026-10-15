import 'package:flutter/services.dart';

import 'native_live_texture_adapter.dart';

/// Bounded Windows/Linux Flutter external-texture control plane. Binary v3
/// dab packets carry preview geometry only; Rust CPU tiles remain authoritative.
class DesktopLiveTextureAdapter implements NativeLiveTextureAdapter {
  DesktopLiveTextureAdapter({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'org.projectink.studio/live_texture_v1';
  static const int _maxDimension = 8192;
  static const int _maxSurfaceBytes = 64 * 1024 * 1024;
  static const int _headerBytes = 8;
  static const int _recordBytes = 56;
  static const int _maxRecordsPerPacket = 2048;
  static const int _maxPacketsPerBatch = 4;

  final MethodChannel _channel;

  @override
  Future<int> create({required int width, required int height}) async {
    if (width < 1 ||
        width > _maxDimension ||
        height < 1 ||
        height > _maxDimension ||
        width * height * 4 > _maxSurfaceBytes) {
      throw ArgumentError('Desktop live texture exceeds its surface bounds.');
    }
    final response = await _channel.invokeMapMethod<Object?, Object?>(
      'create',
      <String, Object>{'width': width, 'height': height},
    );
    final textureId = response?['textureId'];
    if (textureId is! int || textureId < 0) {
      throw PlatformException(
        code: 'invalid_texture_id',
        message: 'The desktop texture adapter returned an invalid ID.',
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
    if (packets.isEmpty || packets.length > _maxPacketsPerBatch) {
      throw ArgumentError.value(packets.length, 'packets.length');
    }
    for (final packet in packets) {
      await renderDabs(textureId, packet);
    }
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
