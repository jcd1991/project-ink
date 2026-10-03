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
    final engine = await FrbEngineApi.create(
      widthPx: 64,
      heightPx: 64,
      dpi: 144,
    );
    final surface = await engine.createLiveSurface(
      physicalWidth: 64,
      physicalHeight: 64,
      scaleMilli: 1000,
    );
    int? textureId;

    try {
      final deviceHandle = await engine.liveSurfaceNativeDeviceHandle(surface);
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
      final nativeTextureHandle = await _channel.invokeMethod<int>(
        'takeMetalTextureHandle',
        <String, Object>{'textureId': textureId},
      );
      expect(nativeTextureHandle, isPositive);
      await engine.attachLiveSurfaceNativeTexture(
        surface,
        BigInt.from(nativeTextureHandle!),
      );
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

      await engine.renderLiveDabPacket(surface, _oneConfirmedDab());
      await _channel.invokeMethod<void>('frameAvailable', <String, Object>{
        'textureId': textureId,
      });
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.byType(Texture), findsOneWidget);
      expect(tester.takeException(), isNull);

      await engine.acknowledgeLiveSurface(surface, BigInt.one, 1);
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      try {
        await engine.detachLiveSurface(surface);
      } catch (_) {}
      try {
        await engine.disposeLiveSurface(surface);
      } catch (_) {}
      if (textureId != null) {
        try {
          await _channel.invokeMethod<void>('dispose', <String, Object>{
            'textureId': textureId,
          });
        } catch (_) {}
      }
      await engine.close();
    }

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
