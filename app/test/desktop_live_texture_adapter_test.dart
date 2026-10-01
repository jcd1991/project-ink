import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/canvas/desktop_live_texture_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('org.projectink.studio/live_texture_v1');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'create' ? <String, Object>{'textureId': 4} : null;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('creates and drives a bounded v3 external texture', () async {
    final adapter = DesktopLiveTextureAdapter(channel: channel);
    expect(await adapter.create(width: 128, height: 96), 4);
    await adapter.setViewport(4, <double>[1, 0, 0, 1, 2, 3], 7);
    final packet = Uint8List(8 + 2048 * 56);
    await adapter.renderDabs(4, packet);
    await adapter.acknowledge(4, BigInt.from(0x1234), 19);
    await adapter.cancelAll(4);
    await adapter.dispose(4);

    expect(calls.map((call) => call.method), <String>[
      'create',
      'setViewport',
      'renderDabs',
      'acknowledge',
      'cancelAll',
      'dispose',
    ]);
    expect(calls[2].arguments['packet'], packet);
    expect(calls[3].arguments['strokeId'], '00000000000000000000000000001234');
  });

  test('rejects surfaces and packets above native limits', () async {
    final adapter = DesktopLiveTextureAdapter(channel: channel);
    await expectLater(
      adapter.create(width: 8192, height: 8192),
      throwsArgumentError,
    );
    await expectLater(
      adapter.renderDabs(4, Uint8List(8 + 2048 * 56 + 1)),
      throwsArgumentError,
    );
    expect(calls, isEmpty);
  });
}
