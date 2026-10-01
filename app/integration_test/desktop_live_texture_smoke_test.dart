import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _channel = MethodChannel('org.projectink.studio/live_texture_v1');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('desktop native live texture completes a frame lifecycle', (
    tester,
  ) async {
    final created = await _channel.invokeMapMethod<String, Object?>(
      'create',
      <String, Object>{'width': 64, 'height': 64},
    );
    final textureId = created?['textureId'];
    expect(textureId, isA<int>());
    final id = textureId! as int;

    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 64,
                height: 64,
                child: Texture(textureId: id),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await _channel.invokeMethod<void>('setViewport', <String, Object>{
        'textureId': id,
        'matrix': <double>[1, 0, 0, 1, 0, 0],
        'generation': 1,
      });
      await _channel.invokeMethod<void>('renderDabs', <String, Object>{
        'textureId': id,
        'packet': _oneConfirmedDab(),
      });
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.byType(Texture), findsOneWidget);
      expect(tester.takeException(), isNull);

      await _channel.invokeMethod<void>('acknowledge', <String, Object>{
        'textureId': id,
        'strokeId': '00000000000000000000000000000001',
        'sequence': 1,
      });
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.takeException(), isNull);
    } finally {
      await _channel.invokeMethod<void>('dispose', <String, Object>{
        'textureId': id,
      });
    }

    await expectLater(
      _channel.invokeMethod<void>('cancelAll', <String, Object>{
        'textureId': id,
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
