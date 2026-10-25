import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/bridge/engine_api.dart';
import 'package:project_ink/bridge/generated/api.dart' as rust;
import 'package:project_ink/canvas/mac_live_surface_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('org.projectink.studio/live_texture_v1');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late _FakeLiveEngine engine;
  late List<String> nativeCalls;

  setUp(() {
    engine = _FakeLiveEngine();
    nativeCalls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      nativeCalls.add(call.method);
      return switch (call.method) {
        'create' => <String, Object>{'textureId': 0},
        'takeMetalTextureHandle' => 1234,
        _ => null,
      };
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'registers the surface, transforms the viewport, and renders dabs',
    () async {
      engine.dabPacket = _oneDabPacket(
        strokeId: BigInt.from(0x1234),
        sequence: 9,
      );
      final textureSubmissionMicros = <int>[];
      final controller = MacLiveSurfaceController(
        engine: engine,
        onTextureSubmission: textureSubmissionMicros.add,
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
      expect(engine.createdDimensions, (800, 600));
      expect(engine.viewportMatrix, <double>[1, 0, 0, 1, -80, 90]);
      expect(controller.gpuFrameReady.value, isFalse);

      controller.markInputPending();
      controller.pump();
      await controller.pendingWork;
      expect(engine.renderedPackets, hasLength(1));
      expect(engine.renderedPackets.single, engine.dabPacket);
      expect(controller.gpuFrameReady.value, isTrue);
      expect(textureSubmissionMicros, hasLength(1));
      expect(textureSubmissionMicros.single, greaterThanOrEqualTo(0));
      expect(nativeCalls, [
        'create',
        'takeMetalTextureHandle',
        'frameAvailable',
        'frameAvailable',
      ]);

      final cleanup = controller.acknowledge(
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
      expect(
        controller.gpuFrameReady.value,
        isFalse,
        reason: 'CPU-covered pixels must hide before asynchronous GPU cleanup',
      );
      await cleanup;
      expect(engine.acknowledgements, [(BigInt.from(0x1234), 9)]);
      expect(controller.gpuFrameReady.value, isFalse);
      expect(
        textureSubmissionMicros,
        hasLength(1),
        reason: 'tile acknowledgement is not a live input frame sample',
      );

      await controller.dispose();
      expect(nativeCalls.last, 'dispose');
      expect(engine.disposedSurfaces, 1);
    },
  );

  test(
    'falls back to the CPU preview when a dab packet is malformed',
    () async {
      engine.dabPacket = Uint8List.fromList(<int>[2, 0, 0]);
      final controller = MacLiveSurfaceController(engine: engine);
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
      expect(engine.renderedPackets, isEmpty);
      expect(engine.disposedSurfaces, 1);
      expect(nativeCalls.last, 'dispose');
      await controller.dispose();
    },
  );

  test('keeps distinct dabs that share one input sample sequence', () async {
    engine.dabPacket = _twoDabPacket(
      strokeId: BigInt.from(0x1234),
      sequence: 9,
    );
    final controller = MacLiveSurfaceController(engine: engine);
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

    final rendered = ByteData.sublistView(engine.renderedPackets.single);
    expect(rendered.getUint32(4, Endian.little), 2);
    await controller.dispose();
  });

  test('coalesces pump requests while a native drain is in flight', () async {
    final drainStarted = Completer<void>();
    final blockedDrain = Completer<Uint8List>();
    engine.drainStarted = drainStarted;
    engine.blockedDrain = blockedDrain;
    final controller = MacLiveSurfaceController(engine: engine);
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
    await drainStarted.future;
    for (var index = 0; index < 8; index++) {
      controller.pump();
    }
    expect(engine.drainCalls, 1);

    blockedDrain.complete(_emptyDabPacket());
    await controller.pendingWork;
    expect(engine.drainCalls, 2);
    await controller.dispose();
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
  data.setUint64(
    8,
    (strokeId & ((BigInt.one << 64) - BigInt.one)).toInt(),
    Endian.little,
  );
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

class _FakeLiveEngine implements LiveRenderEngineApi {
  final rust.LiveSurfaceHandle _surface = _FakeSurface();
  (int, int)? createdDimensions;
  List<double>? viewportMatrix;
  Uint8List dabPacket = Uint8List.fromList(<int>[3, 0, 0, 0, 0, 0, 0, 0]);
  final List<Uint8List> renderedPackets = <Uint8List>[];
  final List<(BigInt, int)> acknowledgements = <(BigInt, int)>[];
  int disposedSurfaces = 0;
  Completer<void>? drainStarted;
  Completer<Uint8List>? blockedDrain;
  int drainCalls = 0;

  @override
  Future<rust.LiveSurfaceHandle> createLiveSurface({
    required int physicalWidth,
    required int physicalHeight,
    required int scaleMilli,
  }) async {
    createdDimensions = (physicalWidth, physicalHeight);
    return _surface;
  }

  @override
  Future<BigInt> liveSurfaceNativeDeviceHandle(
    rust.LiveSurfaceHandle surface,
  ) async => BigInt.from(4321);

  @override
  Future<void> attachLiveSurfaceNativeTexture(
    rust.LiveSurfaceHandle surface,
    BigInt textureHandle,
  ) async {}

  @override
  Future<void> attachLiveSurface(rust.LiveSurfaceHandle surface) async {}

  @override
  Future<void> setLiveViewport(
    rust.LiveSurfaceHandle surface,
    List<double> matrix,
    int generation,
  ) async {
    viewportMatrix = matrix;
  }

  @override
  Future<Uint8List> drainLiveDabs({int limit = 2048}) async {
    drainCalls++;
    final pending = blockedDrain;
    if (drainCalls == 1 && pending != null) {
      drainStarted?.complete();
      return pending.future;
    }
    return dabPacket;
  }

  @override
  Future<int> drainLiveDabOverflowCount() async => 0;

  @override
  Future<void> renderLiveDabPacket(
    rust.LiveSurfaceHandle surface,
    Uint8List packet,
  ) async {
    renderedPackets.add(Uint8List.fromList(packet));
  }

  @override
  Future<void> acknowledgeLiveSurface(
    rust.LiveSurfaceHandle surface,
    BigInt strokeId,
    int highestCommittedSequence,
  ) async {
    acknowledgements.add((strokeId, highestCommittedSequence));
  }

  @override
  Future<void> cancelLiveSurfaceStroke(
    rust.LiveSurfaceHandle surface,
    BigInt strokeId,
  ) async {}

  @override
  Future<void> detachLiveSurface(rust.LiveSurfaceHandle surface) async {}

  @override
  Future<void> disposeLiveSurface(rust.LiveSurfaceHandle surface) async {
    disposedSurfaces++;
  }
}

Uint8List _emptyDabPacket() =>
    Uint8List.fromList(<int>[3, 0, 0, 0, 0, 0, 0, 0]);

class _FakeSurface implements rust.LiveSurfaceHandle {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
