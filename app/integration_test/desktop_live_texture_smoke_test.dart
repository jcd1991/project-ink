import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:project_ink/bridge/engine_api.dart';

const _channel = MethodChannel('org.projectink.studio/live_texture_v1');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('desktop native live texture completes a frame lifecycle', (
    tester,
  ) async {
    debugPrint('[live-texture-smoke] creating Rust engine');
    final engine = await FrbEngineApi.create(
      widthPx: 64,
      heightPx: 64,
      dpi: 144,
    );
    debugPrint('[live-texture-smoke] creating Rust surface');
    final surface = await engine.createLiveSurface(
      physicalWidth: 64,
      physicalHeight: 64,
      scaleMilli: 1000,
    );
    int? textureId;
    Object? unregisterError;

    try {
      debugPrint('[live-texture-smoke] acquiring Metal device handle');
      final deviceHandle = await engine.liveSurfaceNativeDeviceHandle(surface);
      debugPrint('[live-texture-smoke] registering CoreVideo texture');
      final created = await _channel.invokeMapMethod<String, Object?>(
        'create',
        <String, Object>{
          'deviceHandle': deviceHandle.toInt(),
          'width': 64,
          'height': 64,
        },
      );
      expect(created?['textureId'], isA<int>());
      textureId = created!['textureId']! as int;
      debugPrint('[live-texture-smoke] transferring Metal texture handle');
      final nativeTextureHandle = await _channel.invokeMethod<int>(
        'takeMetalTextureHandle',
        <String, Object>{'textureId': textureId},
      );
      expect(nativeTextureHandle, isPositive);
      await engine.attachLiveSurfaceNativeTexture(
        surface,
        BigInt.from(nativeTextureHandle!),
      );
      debugPrint('[live-texture-smoke] attaching Rust surface and viewport');
      await engine.attachLiveSurface(surface);
      await engine.setLiveViewport(surface, const <double>[
        1,
        0,
        0,
        1,
        0,
        0,
      ], 1);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 64,
                height: 64,
                child: Texture(textureId: textureId),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      debugPrint('[live-texture-smoke] rendering confirmed dab');
      await engine.renderLiveDabPacket(surface, _oneConfirmedDab());
      debugPrint('[live-texture-smoke] notifying Flutter texture frame');
      await _channel.invokeMethod<void>('frameAvailable', <String, Object>{
        'textureId': textureId,
      });
      await tester.pump(const Duration(milliseconds: 16));
      final copyBufferCount = await _channel.invokeMethod<int>(
        'debugCopyPixelBufferCount',
        <String, Object>{'textureId': textureId},
      );
      debugPrint(
        '[live-texture-smoke] raster copied $copyBufferCount pixel buffers',
      );
      expect(copyBufferCount, isPositive);
      expect(find.byType(Texture), findsOneWidget);
      expect(tester.takeException(), isNull);

      debugPrint('[live-texture-smoke] acknowledging frame');
      await engine.acknowledgeLiveSurface(surface, BigInt.one, 1);
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.takeException(), isNull);
    } finally {
      debugPrint('[live-texture-smoke] releasing Flutter texture widget');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 16));
      try {
        await engine.detachLiveSurface(surface);
      } catch (_) {}
      try {
        await engine.disposeLiveSurface(surface);
      } catch (_) {}
      if (textureId != null) {
        debugPrint('[live-texture-smoke] unregistering CoreVideo texture');
        final unregister = _channel.invokeMethod<void>(
          'dispose',
          <String, Object>{'textureId': textureId},
        );
        try {
          await tester.pump(const Duration(milliseconds: 16));
          await unregister.timeout(const Duration(seconds: 10));
        } catch (error) {
          unregisterError = error;
        }
      }
      debugPrint('[live-texture-smoke] closing Rust engine');
      await engine.close();
    }

    Map<String, Object?>? lifecycleState;
    for (var attempt = 0; attempt < 100; attempt++) {
      // `pump(Duration)` advances Flutter's test clock but does not guarantee
      // a wall-clock turn for Flutter's native raster thread. Give the
      // asynchronous texture-retirement callback up to two real seconds.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      lifecycleState = await _channel.invokeMapMethod<String, Object?>(
        'debugTextureLifecycleState',
        <String, Object>{'textureId': textureId},
      );
      if (lifecycleState?['phase'] == 'released') break;
    }
    debugPrint('[live-texture-smoke] unregister state: $lifecycleState');
    expect(
      unregisterError,
      isNull,
      reason: 'Native texture unregistration must return without blocking.',
    );
    expect(lifecycleState?['hasUnregisterSelector'], isTrue);
    expect(
      lifecycleState?['phase'],
      'released',
      reason: 'Flutter must release the backing buffer on its raster callback.',
    );
    debugPrint('[live-texture-smoke] verifying stale texture rejection');
    await expectLater(
      _channel.invokeMethod<void>('frameAvailable', <String, Object>{
        'textureId': textureId,
      }),
      throwsA(isA<PlatformException>()),
    );
  });
}

Uint8List _oneConfirmedDab() {
  const headerBytes = 8;
  const recordBytes = 56;
  final packet = Uint8List(headerBytes + recordBytes);
  final data = ByteData.sublistView(packet);
  data.setUint16(0, 3, Endian.little);
  data.setUint16(2, 0, Endian.little);
  data.setUint32(4, 1, Endian.little);

  const offset = headerBytes;
  data.setUint64(offset, 1, Endian.little); // low half of stroke ID
  data.setUint64(offset + 8, 0, Endian.little);
  data.setUint32(offset + 16, 1, Endian.little); // sample sequence
  data.setUint32(offset + 20, 0, Endian.little); // dab index
  data.setFloat32(offset + 24, 32, Endian.little);
  data.setFloat32(offset + 28, 32, Endian.little);
  data.setFloat32(offset + 32, 5, Endian.little);
  data.setFloat32(offset + 36, 1, Endian.little);
  data.setFloat32(offset + 40, 0, Endian.little);
  data.setUint8(offset + 44, 2); // confirmed
  packet.setRange(offset + 45, offset + 49, const <int>[20, 20, 24, 255]);
  return packet;
}
