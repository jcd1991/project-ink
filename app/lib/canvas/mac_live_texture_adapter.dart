import 'package:flutter/services.dart';

/// Flutter's Apple-platform texture-registry control plane. Pixel memory is shared via
/// IOSurface; this channel carries only bounded dimensions and process-local
/// handles, never dab samples or pixel bytes.
class MacLiveTextureAdapter {
  MacLiveTextureAdapter({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'org.projectink.studio/live_texture_v1';
  final MethodChannel _channel;

  Future<int> create({
    required BigInt metalDeviceHandle,
    required int width,
    required int height,
  }) async {
    if (metalDeviceHandle <= BigInt.zero ||
        metalDeviceHandle > BigInt.from(0x7fffffffffffffff)) {
      throw ArgumentError.value(metalDeviceHandle, 'metalDeviceHandle');
    }
    if (width < 1 || width > 8192 || height < 1 || height > 8192) {
      throw ArgumentError('Live texture dimensions must be between 1 and 8192.');
    }
    if (width * height * 4 > 256 * 1024 * 1024) {
      throw ArgumentError('Live texture exceeds the 256 MiB limit.');
    }
    final response = await _channel.invokeMapMethod<Object?, Object?>(
      'create',
      <String, Object>{
        'deviceHandle': metalDeviceHandle.toInt(),
        'width': width,
        'height': height,
      },
    );
    final textureId = response?['textureId'];
    if (textureId is! int || textureId < 0) {
      throw PlatformException(
        code: 'invalid_texture_id',
        message: 'The native texture adapter returned an invalid texture ID.',
      );
    }
    return textureId;
  }

  /// Obtain one +1 Metal texture reference for transfer to the Rust renderer.
  Future<BigInt> takeMetalTextureHandle(int textureId) async {
    _validateTextureId(textureId);
    final pointer = await _channel.invokeMethod<int>(
      'takeMetalTextureHandle',
      <String, Object>{'textureId': textureId},
    );
    if (pointer == null || pointer <= 0) {
      throw PlatformException(
        code: 'invalid_texture_handle',
        message: 'The native texture adapter returned an invalid Metal handle.',
      );
    }
    return BigInt.from(pointer);
  }

  Future<void> frameAvailable(int textureId) async {
    _validateTextureId(textureId);
    await _channel.invokeMethod<void>(
      'frameAvailable',
      <String, Object>{'textureId': textureId},
    );
  }

  Future<void> dispose(int textureId) async {
    _validateTextureId(textureId);
    await _channel.invokeMethod<void>(
      'dispose',
      <String, Object>{'textureId': textureId},
    );
  }

  static void _validateTextureId(int textureId) {
    if (textureId < 0) throw ArgumentError.value(textureId, 'textureId');
  }
}
