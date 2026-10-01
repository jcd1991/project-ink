import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/canvas/mac_live_texture_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('org.projectink.studio/live_texture_v1');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'forwards bounded creation and permits Flutter texture ID zero',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'create' => <String, Object>{'textureId': 0},
          'takeMetalTextureHandle' => 1234,
          _ => null,
        };
      });
      final adapter = MacLiveTextureAdapter(channel: channel);

      final textureId = await adapter.create(
        metalDeviceHandle: BigInt.from(4321),
        width: 1024,
        height: 768,
      );
      final textureHandle = await adapter.takeMetalTextureHandle(textureId);
      await adapter.frameAvailable(textureId);
      await adapter.dispose(textureId);

      expect(textureId, 0);
      expect(textureHandle, BigInt.from(1234));
      expect(calls.map((call) => call.method), [
        'create',
        'takeMetalTextureHandle',
        'frameAvailable',
        'dispose',
      ]);
      expect(calls.first.arguments, {
        'deviceHandle': 4321,
        'width': 1024,
        'height': 768,
      });
    },
  );

  test('rejects invalid surface bounds before platform calls', () async {
    var callCount = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      callCount++;
      return null;
    });
    final adapter = MacLiveTextureAdapter(channel: channel);

    await expectLater(
      adapter.create(metalDeviceHandle: BigInt.one, width: 8192, height: 8193),
      throwsArgumentError,
    );
    await expectLater(
      adapter.create(metalDeviceHandle: BigInt.zero, width: 100, height: 100),
      throwsArgumentError,
    );
    expect(callCount, 0);
  });
}
