import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/bridge/engine_api.dart';
import 'package:project_ink/canvas/android_live_surface_controller.dart';
import 'package:project_ink/canvas/android_live_texture_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('org.projectink.studio/live_texture_v1');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late _FakeDabSource engine;
  late List<MethodCall> calls;

  setUp(() {
    engine = _FakeDabSource();
    calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'create' => <String, Object>{'textureId': 0},
        _ => null,
      };
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'registers, streams, acknowledges, resizes, and releases a texture',
    () async {
      engine.packet = _oneDabPacket(strokeId: BigInt.from(0x1234), sequence: 9);
      final controller = AndroidLiveSurfaceController(
        engine: engine,
        textureAdapter: AndroidLiveTextureAdapter(channel: channel),
      );
      controller.synchronizeViewport(
        viewportSize: const Size(400, 300),
        devicePixelRatio: 2,
        pan: const Offset(10, 20),
        scale: 0.5,
        rotation: 0,
        mirrored: false,
        documentWidth: 1000,
        documentHeight: 500,
      );
      await controller.pendingWork;

      expect(controller.textureId.value, 0);
      final initialViewport = calls.singleWhere(
        (call) => call.method == 'setViewport',
      );
      expect(initialViewport.arguments['matrix'], <double>[
        1,
        0,
        0,
        1,
        -80,
        90,
      ]);

      controller.pump();
      await controller.pendingWork;
      final renderCall = calls.singleWhere(
        (call) => call.method == 'renderDabs',
      );
      expect(renderCall.arguments['textureId'], 0);
      expect(renderCall.arguments['packet'], engine.packet);
      expect(controller.gpuFrameReady.value, isTrue);

      await controller.acknowledge(
        StrokeAcknowledgement(
          stroke: BigInt.from(0x1234),
          highestCommittedSequence: 9,
          revision: 4,
          minTileX: 0,
          minTileY: 0,
          maxTileX: 0,
          maxTileY: 0,
        ),
      );
      final acknowledgement = calls.singleWhere(
        (call) => call.method == 'acknowledge',
      );
      expect(
        acknowledgement.arguments['strokeId'],
        '00000000000000000000000000001234',
      );
      expect(acknowledgement.arguments['sequence'], 9);

      controller.synchronizeViewport(
        viewportSize: const Size(500, 300),
        devicePixelRatio: 2,
        pan: const Offset(10, 20),
        scale: 0.5,
        rotation: 0,
        mirrored: false,
        documentWidth: 1000,
        documentHeight: 500,
      );
      await controller.pendingWork;
      expect(calls.where((call) => call.method == 'dispose'), hasLength(1));
      expect(calls.where((call) => call.method == 'create'), hasLength(2));

      await controller.dispose();
      expect(calls.where((call) => call.method == 'dispose'), hasLength(2));
    },
  );

  test(
    'malformed Rust dabs disable the adapter and retain CPU fallback',
    () async {
      engine.packet = Uint8List.fromList(<int>[2, 0, 0]);
      final controller = AndroidLiveSurfaceController(
        engine: engine,
        textureAdapter: AndroidLiveTextureAdapter(channel: channel),
      );
      controller.synchronizeViewport(
        viewportSize: const Size(100, 100),
        devicePixelRatio: 1,
        pan: Offset.zero,
        scale: 1,
        rotation: 0,
        mirrored: false,
        documentWidth: 100,
        documentHeight: 100,
      );
      await controller.pendingWork;
      controller.pump();
      await controller.pendingWork;

      expect(controller.textureId.value, isNull);
      expect(controller.gpuFrameReady.value, isFalse);
      expect(calls.last.method, 'dispose');
      expect(calls.any((call) => call.method == 'renderDabs'), isFalse);
      await controller.dispose();
    },
  );

  test(
    'platform-neutral controller uses injected native texture backends',
    () async {
      engine.packet = _oneDabPacket(strokeId: BigInt.from(7), sequence: 2);
      final controller = NativeLiveSurfaceController(
        engine: engine,
        textureAdapter: AndroidLiveTextureAdapter(channel: channel),
        platformName: 'Test desktop',
        maxSurfaceBytes: 256 * 1024 * 1024,
      );
      controller.synchronizeViewport(
        viewportSize: const Size(64, 64),
        devicePixelRatio: 1,
        pan: Offset.zero,
        scale: 1,
        rotation: 0,
        mirrored: false,
        documentWidth: 64,
        documentHeight: 64,
      );
      await controller.pendingWork;
      controller.pump();
      await controller.pendingWork;

      expect(controller.textureId.value, 0);
      expect(
        calls.map((call) => call.method),
        containsAll(<String>['create', 'setViewport', 'renderDabs']),
      );
      expect(controller.gpuFrameReady.value, isTrue);

      await controller.dispose();
      expect(calls.last.method, 'dispose');
    },
  );

  test(
    'surfaces above the triple-buffer budget are rejected before creation',
    () async {
      final adapter = AndroidLiveTextureAdapter(channel: channel);
      await expectLater(
        adapter.create(width: 8192, height: 8192),
        throwsArgumentError,
      );
      expect(calls, isEmpty);

      final controller = AndroidLiveSurfaceController(
        engine: engine,
        textureAdapter: adapter,
      );
      controller.synchronizeViewport(
        viewportSize: const Size(8192, 8192),
        devicePixelRatio: 1,
        pan: Offset.zero,
        scale: 1,
        rotation: 0,
        mirrored: false,
        documentWidth: 1024,
        documentHeight: 1024,
      );
      await controller.pendingWork;
      expect(controller.textureId.value, isNull);
      expect(calls, isEmpty);
      await controller.dispose();
    },
  );

  test('retains multiple dabs from the same input sample', () async {
    engine.packet = _twoDabPacket(strokeId: BigInt.from(0x1234), sequence: 9);
    final controller = AndroidLiveSurfaceController(
      engine: engine,
      textureAdapter: AndroidLiveTextureAdapter(channel: channel),
    );
    controller.synchronizeViewport(
      viewportSize: const Size(100, 100),
      devicePixelRatio: 1,
      pan: Offset.zero,
      scale: 1,
      rotation: 0,
      mirrored: false,
      documentWidth: 100,
      documentHeight: 100,
    );
    await controller.pendingWork;
    controller.pump();
    await controller.pendingWork;

    final renderCall = calls.singleWhere((call) => call.method == 'renderDabs');
    final packet = renderCall.arguments['packet'] as Uint8List;
    expect(ByteData.sublistView(packet).getUint32(4, Endian.little), 2);
    await controller.dispose();
  });

  test(
    'accepts a full v3 dab batch without disabling the native preview',
    () async {
      final adapter = AndroidLiveTextureAdapter(channel: channel);
      final maximumV3Packet = Uint8List(8 + 2048 * 56);

      await adapter.renderDabs(0, maximumV3Packet);

      expect(calls.single.method, 'renderDabs');
      expect(
        (calls.single.arguments['packet'] as Uint8List).length,
        8 + 2048 * 56,
      );
      await expectLater(
        adapter.renderDabs(0, Uint8List(9 + 2048 * 56)),
        throwsArgumentError,
      );
      expect(calls, hasLength(1));
    },
  );
}

Uint8List _oneDabPacket({required BigInt strokeId, required int sequence}) {
  const headerBytes = 8;
  const recordBytes = 56;
  final packet = Uint8List(headerBytes + recordBytes);
  final data = ByteData.sublistView(packet);
  data.setUint16(0, 3, Endian.little);
  data.setUint16(2, 0, Endian.little);
  data.setUint32(4, 1, Endian.little);
  final lowMask = (BigInt.one << 64) - BigInt.one;
  data.setUint64(8, (strokeId & lowMask).toInt(), Endian.little);
  data.setUint64(16, (strokeId >> 64).toInt(), Endian.little);
  data.setUint32(24, sequence, Endian.little);
  data.setUint32(28, 0, Endian.little);
  data.setFloat32(32, 50, Endian.little);
  data.setFloat32(36, 60, Endian.little);
  data.setFloat32(40, 4, Endian.little);
  data.setFloat32(44, 1, Endian.little);
  data.setFloat32(48, 0, Endian.little);
  data.setUint8(52, 2);
  packet.setRange(53, 57, <int>[0, 0, 0, 255]);
  return packet;
}

Uint8List _twoDabPacket({required BigInt strokeId, required int sequence}) {
  final oneDab = _oneDabPacket(strokeId: strokeId, sequence: sequence);
  final packet = Uint8List(8 + 2 * 56);
  packet.setRange(0, oneDab.length, oneDab);
  packet.setRange(8 + 56, packet.length, oneDab, 8);
  final data = ByteData.sublistView(packet);
  data.setUint32(4, 2, Endian.little);
  data.setUint32(8 + 56 + 20, 1, Endian.little);
  data.setFloat32(8 + 56 + 24, 70, Endian.little);
  return packet;
}

class _FakeDabSource implements LiveDabSourceApi {
  Uint8List packet = Uint8List.fromList(<int>[3, 0, 0, 0, 0, 0, 0, 0]);

  @override
  Future<Uint8List> drainLiveDabs({int limit = 2048}) async => packet;

  @override
  Future<int> drainLiveDabOverflowCount() async => 0;
}
