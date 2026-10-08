import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/bridge/engine_api.dart';

void main() {
  test('recovery manifest type detection recognizes Studio projects', () {
    expect(
      FrbEngineApi.isStudioProjectManifest(<String, Object?>{
        'format_version': 2,
        'project_id': 'comic-project',
        'page_count': 3,
      }),
      isTrue,
    );
    expect(
      FrbEngineApi.isStudioProjectManifest(<String, Object?>{
        'format_version': 6,
        'document_id': 'illustration-document',
      }),
      isFalse,
    );
    expect(FrbEngineApi.isStudioProjectManifest(null), isFalse);
  });

  test(
    'in-memory control plane exposes save and PNG export operations',
    () async {
      final engine = InMemoryEngineApi();

      await engine.saveAs('/tmp/example.inkproj');
      await engine.exportPng('/tmp/example.png');

      expect(engine.revision, 0);
    },
  );

  test('in-memory control plane validates and routes layer merge', () async {
    final engine = InMemoryEngineApi();
    await engine.mergeLayers(targetLayerId: 1, sourceLayerId: 2);
    expect(engine.revision, 1);
    expect(
      () => engine.mergeLayers(targetLayerId: 1, sourceLayerId: 1),
      throwsArgumentError,
    );
  });

  test('in-memory merge preflight never commits a layer edit', () async {
    final engine = InMemoryEngineApi();

    await expectLater(
      engine.preflightMergeLayers(targetLayerId: 1, sourceLayerId: 1),
      throwsArgumentError,
    );
    expect(
      await engine.preflightMergeLayers(targetLayerId: 1, sourceLayerId: 2),
      'Merge layer no longer exists.',
    );
    expect(engine.revision, 0);
  });

  test(
    'in-memory group preflight validates requests without committing',
    () async {
      final engine = InMemoryEngineApi();

      await expectLater(
        engine.preflightGroupLayers(layerIds: <int>[1]),
        throwsArgumentError,
      );
      expect(await engine.preflightGroupLayers(layerIds: <int>[1, 2]), isNull);
      expect(engine.revision, 0);
    },
  );

  test(
    'in-memory delete preflight validates requests without committing',
    () async {
      final engine = InMemoryEngineApi();

      await expectLater(
        engine.preflightDeleteLayers(layerIds: const <int>[]),
        throwsArgumentError,
      );
      expect(
        await engine.preflightDeleteLayers(layerIds: const <int>[1, 2]),
        isNull,
      );
      expect(engine.revision, 0);
    },
  );

  test(
    'in-memory layer panel state preserves its primary and disclosures',
    () async {
      final engine = InMemoryEngineApi();

      await engine.setLayerPanelState(
        primaryLayerId: 17,
        collapsedGroupIds: <int>[9, 4],
      );

      expect(
        await engine.layerPanelState(),
        isA<LayerPanelStateView>()
            .having((state) => state.primaryLayerId, 'primary', 17)
            .having((state) => state.collapsedGroupIds, 'collapsed', <int>[
              4,
              9,
            ]),
      );
      await expectLater(
        engine.setLayerPanelState(
          primaryLayerId: 17,
          collapsedGroupIds: <int>[4, 4],
        ),
        throwsArgumentError,
      );
    },
  );

  test('decodes compact dirty tile packets', () {
    final packet = ByteData(8 + 32);
    packet.setUint16(0, 1, Endian.little);
    packet.setUint16(2, 1, Endian.little);
    packet.setUint32(4, 1, Endian.little);
    packet.setUint64(8, 7, Endian.little);
    packet.setUint64(16, 1, Endian.little);
    packet.setUint32(32, 2, Endian.little);
    packet.setInt32(36, -3, Endian.little);
    final decoded = decodeTileUpdatePacket(packet.buffer.asUint8List());

    expect(decoded.fullRedraw, isTrue);
    expect(decoded.revision, 7);
    expect(decoded.tiles, hasLength(1));
    expect(decoded.tiles.single.layer, 1);
    expect(decoded.tiles.single.x, 2);
    expect(decoded.tiles.single.y, -3);
  });

  test('decodes a deferred tile poll while the CPU renderer is busy', () {
    final packet = ByteData(12);
    packet.setUint16(0, 4, Endian.little);
    packet.setUint16(2, 2, Endian.little);
    packet.setUint32(4, 0, Endian.little);
    packet.setUint32(8, 0, Endian.little);

    final decoded = decodeTileUpdatePacket(packet.buffer.asUint8List());

    expect(decoded.rendererBusy, isTrue);
    expect(decoded.tiles, isEmpty);
    expect(decoded.acknowledgements, isEmpty);
    expect(decoded.fullRedraw, isFalse);
  });

  test('decodes stroke coverage atomically with its tile invalidations', () {
    final packet = ByteData(12 + 32 + 56);
    packet.setUint16(0, 3, Endian.little);
    packet.setUint16(2, 0, Endian.little);
    packet.setUint32(4, 1, Endian.little);
    packet.setUint32(8, 1, Endian.little);
    packet.setUint64(12, 19, Endian.little);
    for (var index = 0; index < 16; index++) {
      packet.setUint8(20 + index, 0xff);
      packet.setUint8(44 + index, index + 1);
    }
    packet.setInt32(36, 2, Endian.little);
    packet.setInt32(40, -3, Endian.little);
    packet.setUint64(60, 19, Endian.little);
    packet.setUint32(68, 27, Endian.little);
    packet.setInt32(72, 2, Endian.little);
    packet.setInt32(76, -3, Endian.little);
    packet.setInt32(80, 2, Endian.little);
    packet.setInt32(84, -3, Endian.little);
    packet.setUint32(88, 1, Endian.little);
    packet.setInt32(92, 2, Endian.little);
    packet.setInt32(96, -3, Endian.little);

    final decoded = decodeTileUpdatePacket(packet.buffer.asUint8List());

    expect(decoded.tiles, hasLength(1));
    expect(decoded.tiles.single.layer, -1);
    expect(decoded.tiles.single.x, 2);
    expect(decoded.tiles.single.y, -3);
    expect(decoded.acknowledgements, hasLength(1));
    expect(decoded.acknowledgements.single.highestCommittedSequence, 27);
    expect(decoded.acknowledgements.single.revision, 19);
    expect(decoded.acknowledgements.single.minTileX, 2);
    expect(decoded.acknowledgements.single.minTileY, -3);
    expect(decoded.acknowledgements.single.dirtyTiles, hasLength(1));
    expect(decoded.acknowledgements.single.dirtyTiles.single.x, 2);
    expect(decoded.acknowledgements.single.dirtyTiles.single.y, -3);
  });

  test('decodes Rust stroke work metrics with CPU coverage', () {
    const acknowledgementOffset = 12;
    const metricsOffset = acknowledgementOffset + 48;
    final packet = ByteData(acknowledgementOffset + 48 + 65);
    packet.setUint16(0, 4, Endian.little);
    packet.setUint16(2, 0, Endian.little);
    packet.setUint32(4, 0, Endian.little);
    packet.setUint32(8, 1, Endian.little);
    for (var index = 0; index < 16; index++) {
      packet.setUint8(acknowledgementOffset + index, index + 1);
    }
    packet.setUint64(acknowledgementOffset + 16, 91, Endian.little);
    packet.setUint32(acknowledgementOffset + 24, 202, Endian.little);
    packet.setInt32(acknowledgementOffset + 28, 1, Endian.little);
    packet.setInt32(acknowledgementOffset + 32, 2, Endian.little);
    packet.setInt32(acknowledgementOffset + 36, 3, Endian.little);
    packet.setInt32(acknowledgementOffset + 40, 4, Endian.little);
    packet.setUint32(acknowledgementOffset + 44, 0, Endian.little);

    packet.setUint64(metricsOffset, 77, Endian.little);
    packet.setFloat64(metricsOffset + 8, 1440.5, Endian.little);
    packet.setFloat64(metricsOffset + 16, 12.25, Endian.little);
    packet.setUint64(metricsOffset + 24, 8000, Endian.little);
    packet.setUint64(metricsOffset + 32, 4000, Endian.little);
    packet.setUint64(metricsOffset + 40, 18, Endian.little);
    packet.setUint64(metricsOffset + 48, 12, Endian.little);
    packet.setUint64(metricsOffset + 56, 3, Endian.little);
    packet.setUint8(metricsOffset + 64, 1);

    final decoded = decodeTileUpdatePacket(packet.buffer.asUint8List());
    final acknowledgement = decoded.acknowledgements.single;
    expect(acknowledgement.highestCommittedSequence, 202);
    expect(acknowledgement.confirmedSampleCount, 77);
    expect(acknowledgement.pathLength, 1440.5);
    expect(acknowledgement.directLength, 12.25);
    expect(acknowledgement.legacyDabs, 8000);
    expect(acknowledgement.compiledDabs, 4000);
    expect(acknowledgement.cpuTilesWritten, 18);
    expect(acknowledgement.compiledCpuTileUpdates, 12);
    expect(acknowledgement.workSegments, 3);
    expect(acknowledgement.workLimitReached, isTrue);
  });

  test('decodes reserved composite tile invalidations', () {
    final packet = ByteData(8 + 32);
    packet.setUint16(0, 1, Endian.little);
    packet.setUint16(2, 0, Endian.little);
    packet.setUint32(4, 1, Endian.little);
    packet.setUint64(8, 12, Endian.little);
    // Reserved all-ones u128 layer identifier means the committed composite.
    for (var index = 0; index < 16; index++) {
      packet.setUint8(16 + index, 0xff);
    }
    packet.setInt32(32, 4, Endian.little);
    packet.setInt32(36, -2, Endian.little);

    final decoded = decodeTileUpdatePacket(packet.buffer.asUint8List());

    expect(decoded.tiles.single.layer, -1);
    expect(decoded.tiles.single.x, 4);
    expect(decoded.tiles.single.y, -2);
  });

  test('projects legacy u128 layer IDs through tile invalidations', () {
    final legacyLayerId = BigInt.one << 100;
    final projection =
        LayerIdProjection()
          ..reset(<BigInt>[BigInt.one, BigInt.from(3), legacyLayerId]);
    final alias = projection.toDart(legacyLayerId);
    expect(alias, isNot(1));
    expect(alias, isNot(3));
    expect(projection.toRust(alias), legacyLayerId);
    expect(projection.toRust(3), BigInt.from(3));

    final packet = ByteData(8 + 32);
    packet.setUint16(0, 1, Endian.little);
    packet.setUint16(2, 0, Endian.little);
    packet.setUint32(4, 1, Endian.little);
    packet.setUint64(8, 24, Endian.little);
    for (var index = 0; index < 16; index++) {
      packet.setUint8(
        16 + index,
        ((legacyLayerId >> (index * 8)) & BigInt.from(0xff)).toInt(),
      );
    }
    packet.setInt32(32, -7, Endian.little);
    packet.setInt32(36, 9, Endian.little);

    expect(
      () => decodeTileUpdatePacket(packet.buffer.asUint8List()),
      throwsFormatException,
    );
    final decoded = decodeTileUpdatePacket(
      packet.buffer.asUint8List(),
      projectLayerId: projection.toDart,
    );
    expect(decoded.tiles.single.layer, alias);
    expect(decoded.tiles.single.x, -7);
    expect(decoded.tiles.single.y, 9);
  });

  test('decodes fixed-width stroke acknowledgements', () {
    final packet = ByteData(8 + 44);
    packet.setUint16(0, 1, Endian.little);
    packet.setUint16(2, 0, Endian.little);
    packet.setUint32(4, 1, Endian.little);
    for (var index = 0; index < 16; index++) {
      packet.setUint8(8 + index, index + 1);
    }
    packet.setUint64(24, 19, Endian.little);
    packet.setUint32(32, 27, Endian.little);
    packet.setInt32(36, -1, Endian.little);
    packet.setInt32(40, 2, Endian.little);
    packet.setInt32(44, 3, Endian.little);
    packet.setInt32(48, 4, Endian.little);

    final decoded = decodeStrokeAcknowledgementPacket(
      packet.buffer.asUint8List(),
    );

    expect(decoded, hasLength(1));
    expect(
      decoded.single.stroke,
      BigInt.parse('100f0e0d0c0b0a090807060504030201', radix: 16),
    );
    expect(decoded.single.highestCommittedSequence, 27);
    expect(decoded.single.revision, 19);
    expect(decoded.single.hasDirtyBounds, isTrue);
    expect(decoded.single.minTileX, -1);
    expect(decoded.single.maxTileY, 4);
  });

  test('rejects malformed dirty tile packets', () {
    expect(
      () => decodeTileUpdatePacket(Uint8List.fromList(<int>[1, 0])),
      throwsFormatException,
    );
  });

  test(
    'decodes immutable composite tile pixels with their snapshot revision',
    () {
      const headerBytes = 16;
      const tileBytes = 256 * 256 * 4;
      final packet = Uint8List(headerBytes + 8 + tileBytes);
      final data = ByteData.sublistView(packet);
      data.setUint16(0, 1, Endian.little);
      data.setUint16(2, 0, Endian.little);
      data.setUint64(4, 42, Endian.little);
      data.setUint32(12, 1, Endian.little);
      data.setInt32(16, -2, Endian.little);
      data.setInt32(20, 7, Endian.little);
      packet[24 + 3] = 255;

      final snapshot = decodeCompositeTileSnapshot(packet);

      expect(snapshot.revision, 42);
      expect(snapshot.tiles, hasLength(1));
      expect(snapshot.tiles.single.x, -2);
      expect(snapshot.tiles.single.y, 7);
      expect(snapshot.tiles.single.bytes.length, tileBytes);
      expect(snapshot.tiles.single.bytes[3], 255);
    },
  );
}
