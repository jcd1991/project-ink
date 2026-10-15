import 'dart:async';
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
        (call) => call.method == 'renderDabBatches',
      );
      expect(renderCall.arguments['textureId'], 0);
      expect(renderCall.arguments['packets'], <Uint8List>[engine.packet]);
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
    'coalesces a stroke acknowledgement burst into one texture rebuild',
    () async {
      const stroke = 0x3456;
      engine.packets = <Uint8List>[
        _oneDabPacket(strokeId: BigInt.from(stroke), sequence: 1),
        _oneDabPacket(strokeId: BigInt.from(stroke), sequence: 2),
        _oneDabPacket(strokeId: BigInt.from(stroke), sequence: 3),
      ];
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
      calls.clear();

      await Future.wait(<Future<void>>[
        for (var sequence = 1; sequence <= 3; sequence++)
          controller.acknowledge(
            StrokeAcknowledgement(
              stroke: BigInt.from(stroke),
              highestCommittedSequence: sequence,
              revision: sequence,
              minTileX: 0,
              minTileY: 0,
              maxTileX: 0,
              maxTileY: 0,
            ),
          ),
      ]);

      final acknowledgements =
          calls.where((call) => call.method == 'acknowledge').toList();
      expect(acknowledgements, hasLength(1));
      expect(acknowledgements.single.arguments['sequence'], 3);
      expect(controller.gpuFrameReady.value, isFalse);
      await controller.dispose();
    },
  );

  test(
    'hides CPU-covered live texture before native cleanup finishes',
    () async {
      const stroke = 0x7890;
      final nativeAcknowledgementStarted = Completer<void>();
      final finishNativeAcknowledgement = Completer<void>();
      engine.packet = _oneDabPacket(strokeId: BigInt.from(stroke), sequence: 1);
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'create') {
          return <String, Object>{'textureId': 0};
        }
        if (call.method == 'acknowledge') {
          if (!nativeAcknowledgementStarted.isCompleted) {
            nativeAcknowledgementStarted.complete();
          }
          await finishNativeAcknowledgement.future;
        }
        return null;
      });
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
      expect(controller.gpuFrameReady.value, isTrue);

      final acknowledgement = controller.acknowledge(
        StrokeAcknowledgement(
          stroke: BigInt.from(stroke),
          highestCommittedSequence: 1,
          revision: 2,
          minTileX: 0,
          minTileY: 0,
          maxTileX: 0,
          maxTileY: 0,
        ),
      );
      var acknowledgementCompleted = false;
      unawaited(acknowledgement.then((_) => acknowledgementCompleted = true));
      await nativeAcknowledgementStarted.future;

      expect(controller.gpuFrameReady.value, isFalse);
      expect(acknowledgementCompleted, isFalse);

      finishNativeAcknowledgement.complete();
      await acknowledgement;
      await controller.dispose();
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
      expect(calls.any((call) => call.method == 'renderDabBatches'), isFalse);
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
        containsAll(<String>['create', 'setViewport', 'renderDabBatches']),
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
      await adapter.create(width: 4096, height: 4096);
      expect(calls.single.method, 'create');

      calls.clear();
      await expectLater(
        adapter.create(width: 4620, height: 4620),
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

    final renderCall = calls.singleWhere(
      (call) => call.method == 'renderDabBatches',
    );
    final packets =
        (renderCall.arguments['packets'] as List<Object?>).cast<Uint8List>();
    final packet = packets.single;
    expect(ByteData.sublistView(packet).getUint32(4, Endian.little), 2);
    await controller.dispose();
  });

  test('groups a bounded long-stroke drain into one surface frame', () async {
    engine.packets = <Uint8List>[
      _manyDabPacket(2048),
      _oneDabPacket(strokeId: BigInt.from(0x1234), sequence: 10),
      Uint8List.fromList(<int>[3, 0, 0, 0, 0, 0, 0, 0]),
    ];
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

    final renderCalls =
        calls.where((call) => call.method == 'renderDabBatches').toList();
    expect(renderCalls, hasLength(1));
    final packets =
        (renderCalls.single.arguments['packets'] as List<Object?>)
            .cast<Uint8List>();
    expect(packets, hasLength(2));
    expect(
      ByteData.sublistView(packets.first).getUint32(4, Endian.little),
      2048,
    );
    expect(ByteData.sublistView(packets.last).getUint32(4, Endian.little), 1);
    expect(controller.gpuFrameReady.value, isTrue);
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

  test('Android adapter bounds grouped packet submission', () async {
    final adapter = AndroidLiveTextureAdapter(channel: channel);
    final one = _oneDabPacket(strokeId: BigInt.from(8), sequence: 1);
    await adapter.renderDabBatches(0, <Uint8List>[one, one]);
    expect(calls.single.method, 'renderDabBatches');
    expect(calls.single.arguments['packets'], <Uint8List>[one, one]);

    calls.clear();
    await expectLater(
      adapter.renderDabBatches(0, <Uint8List>[]),
      throwsArgumentError,
    );
    await expectLater(
      adapter.renderDabBatches(0, List<Uint8List>.filled(5, one)),
      throwsArgumentError,
    );
    expect(calls, isEmpty);
  });
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

Uint8List _manyDabPacket(int count) {
  final packet = Uint8List(8 + count * 56);
  final data = ByteData.sublistView(packet);
  data.setUint16(0, 3, Endian.little);
  data.setUint16(2, 0, Endian.little);
  data.setUint32(4, count, Endian.little);
  final template = _oneDabPacket(strokeId: BigInt.from(8), sequence: 1);
  for (var index = 0; index < count; index++) {
    final offset = 8 + index * 56;
    packet.setRange(offset, offset + 56, template, 8);
    data.setUint32(offset + 20, index, Endian.little);
  }
  return packet;
}

class _FakeDabSource implements LiveDabSourceApi {
  Uint8List packet = Uint8List.fromList(<int>[3, 0, 0, 0, 0, 0, 0, 0]);
  List<Uint8List> packets = <Uint8List>[];

  @override
  Future<Uint8List> drainLiveDabs({int limit = 2048}) async =>
      packets.isEmpty ? packet : packets.removeAt(0);

  @override
  Future<int> drainLiveDabOverflowCount() async => 0;
}
