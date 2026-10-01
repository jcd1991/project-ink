import 'dart:math' as math;
import 'dart:typed_data';

import 'engine_api_models.dart';
import 'layer_id_projection.dart';

const int _compositeSnapshotPacketVersion = 1;
const int _compositeSnapshotHeaderBytes = 16;
const int _compositeSnapshotTileBytes = 256 * 256 * 4;
const int _compositeSnapshotRecordBytes = 8 + _compositeSnapshotTileBytes;
const int maxCompositeTileSnapshotTiles =
    (16 * 1024 * 1024 - _compositeSnapshotHeaderBytes) ~/
    _compositeSnapshotRecordBytes;

CompositeTileSnapshot decodeCompositeTileSnapshot(Uint8List packet) {
  if (packet.length < _compositeSnapshotHeaderBytes ||
      packet.length > 16 * 1024 * 1024) {
    throw const FormatException('composite tile snapshot has an invalid size');
  }
  final data = ByteData.sublistView(packet);
  final version = data.getUint16(0, Endian.little);
  final flags = data.getUint16(2, Endian.little);
  final revision = data.getUint64(4, Endian.little);
  final count = data.getUint32(12, Endian.little);
  final expectedLength =
      _compositeSnapshotHeaderBytes + count * _compositeSnapshotRecordBytes;
  if (version != _compositeSnapshotPacketVersion ||
      flags != 0 ||
      count > maxCompositeTileSnapshotTiles ||
      packet.length != expectedLength) {
    throw const FormatException('composite tile snapshot header is invalid');
  }
  final tiles = <CompositeTilePixels>[];
  var offset = _compositeSnapshotHeaderBytes;
  for (var index = 0; index < count; index++) {
    final x = data.getInt32(offset, Endian.little);
    final y = data.getInt32(offset + 4, Endian.little);
    final pixelsStart = offset + 8;
    final pixelsEnd = pixelsStart + _compositeSnapshotTileBytes;
    tiles.add(
      CompositeTilePixels(
        x: x,
        y: y,
        bytes: Uint8List.fromList(packet.sublist(pixelsStart, pixelsEnd)),
      ),
    );
    offset = pixelsEnd;
  }
  return CompositeTileSnapshot(revision: revision, tiles: tiles);
}

TileUpdateBatch decodeTileUpdatePacket(
  Uint8List packet, {
  int Function(BigInt rustLayerId)? projectLayerId,
}) {
  if (packet.length < 8) {
    throw const FormatException('tile update packet header is truncated');
  }
  final data = ByteData.sublistView(packet);
  final version = data.getUint16(0, Endian.little);
  if (version < 1 || version > 4) {
    throw FormatException('unsupported tile update packet version $version');
  }
  final flags = data.getUint16(2, Endian.little);
  if (flags & ~3 != 0) {
    throw const FormatException('tile update packet contains unknown flags');
  }
  if (version >= 2 && packet.length < 12) {
    throw const FormatException('tile update packet header is truncated');
  }
  const maxPacketBytes = 16 * 1024 * 1024;
  if (packet.length > maxPacketBytes) {
    throw const FormatException('tile update packet exceeds the byte limit');
  }
  final count = data.getUint32(4, Endian.little);
  const maxTileUpdates = 262144;
  if (count > maxTileUpdates) {
    throw const FormatException('tile update packet contains too many records');
  }
  final acknowledgementCount =
      version >= 2 ? data.getUint32(8, Endian.little) : 0;
  const maxAcknowledgements = 65536;
  if (acknowledgementCount > maxAcknowledgements) {
    throw const FormatException(
      'tile update packet contains too many stroke acknowledgements',
    );
  }
  const recordBytes = 32;
  const acknowledgementBytes = 44;
  final headerBytes = version >= 2 ? 12 : 8;
  final compositeLayerId = (BigInt.one << 128) - BigInt.one;
  final fixedExpectedLength =
      headerBytes +
      count * recordBytes +
      acknowledgementCount * acknowledgementBytes;
  if (version < 3 && packet.length != fixedExpectedLength) {
    throw const FormatException('tile update packet length is invalid');
  }
  var revision = 0;
  final updates = <TileUpdate>[];
  for (var index = 0; index < count; index++) {
    final offset = headerBytes + index * recordBytes;
    final eventRevision = data.getUint64(offset, Endian.little);
    final layer = _readLittleEndianU128(packet, offset + 8);
    final x = data.getInt32(offset + 24, Endian.little);
    final y = data.getInt32(offset + 28, Endian.little);
    revision = revision > eventRevision ? revision : eventRevision;
    final isComposite = layer == compositeLayerId;
    if (!isComposite &&
        layer > BigInt.from(LayerIdProjection.maxSafeId) &&
        projectLayerId == null) {
      throw const FormatException(
        'tile update packet contains an unsafe layer identifier',
      );
    }
    updates.add(
      TileUpdate(
        revision: eventRevision,
        layer:
            isComposite
                ? -1
                : projectLayerId == null
                ? layer.toInt()
                : projectLayerId(layer),
        x: x,
        y: y,
      ),
    );
  }
  final acknowledgements = <StrokeAcknowledgement>[];
  var acknowledgementOffset = headerBytes + count * recordBytes;
  for (var index = 0; index < acknowledgementCount; index++) {
    final remaining = packet.length - acknowledgementOffset;
    if (remaining < (version >= 3 ? 48 : acknowledgementBytes)) {
      throw const FormatException('stroke acknowledgement record is truncated');
    }
    final dirtyTileCount =
        version >= 3
            ? data.getUint32(acknowledgementOffset + 44, Endian.little)
            : 0;
    const maxDirtyTilesPerAcknowledgement = 262144;
    if (dirtyTileCount > maxDirtyTilesPerAcknowledgement) {
      throw const FormatException(
        'stroke acknowledgement contains too many dirty tiles',
      );
    }
    final dirtyTilesOffset = acknowledgementOffset + 48;
    final metricsBytes = version >= 4 ? 65 : 0;
    final recordLength =
        version >= 3
            ? 48 + dirtyTileCount * 8 + metricsBytes
            : acknowledgementBytes;
    if (remaining < recordLength) {
      throw const FormatException(
        'stroke acknowledgement tile coverage is truncated',
      );
    }
    final dirtyTiles = <StrokeTileCoordinate>[
      for (var tile = 0; tile < dirtyTileCount; tile++)
        StrokeTileCoordinate(
          data.getInt32(dirtyTilesOffset + tile * 8, Endian.little),
          data.getInt32(dirtyTilesOffset + tile * 8 + 4, Endian.little),
        ),
    ];
    final metricsOffset = acknowledgementOffset + 48 + dirtyTileCount * 8;
    if (version >= 4) {
      final pathLength = data.getFloat64(metricsOffset + 8, Endian.little);
      final directLength = data.getFloat64(metricsOffset + 16, Endian.little);
      if (!pathLength.isFinite || !directLength.isFinite) {
        throw const FormatException(
          'stroke acknowledgement contains non-finite path metrics',
        );
      }
      if (data.getUint8(metricsOffset + 64) > 1) {
        throw const FormatException(
          'stroke acknowledgement contains an invalid work-limit flag',
        );
      }
    }
    acknowledgements.add(
      _decodeStrokeAcknowledgement(
        data,
        packet,
        acknowledgementOffset,
        dirtyTiles: dirtyTiles,
        confirmedSampleCount:
            version >= 4 ? data.getUint64(metricsOffset, Endian.little) : 0,
        pathLength:
            version >= 4
                ? data.getFloat64(metricsOffset + 8, Endian.little)
                : 0,
        directLength:
            version >= 4
                ? data.getFloat64(metricsOffset + 16, Endian.little)
                : 0,
        legacyDabs:
            version >= 4
                ? data.getUint64(metricsOffset + 24, Endian.little)
                : 0,
        compiledDabs:
            version >= 4
                ? data.getUint64(metricsOffset + 32, Endian.little)
                : 0,
        cpuTilesWritten:
            version >= 4
                ? data.getUint64(metricsOffset + 40, Endian.little)
                : 0,
        compiledCpuTileUpdates:
            version >= 4
                ? data.getUint64(metricsOffset + 48, Endian.little)
                : 0,
        workSegments:
            version >= 4
                ? data.getUint64(metricsOffset + 56, Endian.little)
                : 0,
        workLimitReached:
            version >= 4 && data.getUint8(metricsOffset + 64) == 1,
      ),
    );
    revision = math.max(revision, acknowledgements.last.revision);
    acknowledgementOffset += recordLength;
  }
  if (acknowledgementOffset != packet.length) {
    throw const FormatException('tile update packet has trailing bytes');
  }
  return TileUpdateBatch(
    revision: revision,
    fullRedraw: flags & 1 != 0,
    tiles: List.unmodifiable(updates),
    acknowledgements: List.unmodifiable(acknowledgements),
    rendererBusy: flags & 2 != 0,
  );
}

List<StrokeAcknowledgement> decodeStrokeAcknowledgementPacket(
  Uint8List packet,
) {
  if (packet.length < 8) {
    throw const FormatException('stroke acknowledgement header is truncated');
  }
  final data = ByteData.sublistView(packet);
  final version = data.getUint16(0, Endian.little);
  if (version != 1) {
    throw FormatException(
      'unsupported stroke acknowledgement packet version $version',
    );
  }
  final flags = data.getUint16(2, Endian.little);
  if (flags != 0) {
    throw const FormatException(
      'stroke acknowledgement packet contains unknown flags',
    );
  }
  final count = data.getUint32(4, Endian.little);
  const recordBytes = 44;
  const maxRecords = 65536;
  if (count > maxRecords) {
    throw const FormatException(
      'stroke acknowledgement packet contains too many records',
    );
  }
  final expectedLength = 8 + count * recordBytes;
  if (packet.length != expectedLength) {
    throw const FormatException(
      'stroke acknowledgement packet length is invalid',
    );
  }
  final acknowledgements = <StrokeAcknowledgement>[];
  for (var index = 0; index < count; index++) {
    final offset = 8 + index * recordBytes;
    acknowledgements.add(_decodeStrokeAcknowledgement(data, packet, offset));
  }
  return List.unmodifiable(acknowledgements);
}

StrokeAcknowledgement _decodeStrokeAcknowledgement(
  ByteData data,
  Uint8List packet,
  int offset, {
  List<StrokeTileCoordinate> dirtyTiles = const <StrokeTileCoordinate>[],
  int confirmedSampleCount = 0,
  double pathLength = 0,
  double directLength = 0,
  int legacyDabs = 0,
  int compiledDabs = 0,
  int cpuTilesWritten = 0,
  int compiledCpuTileUpdates = 0,
  int workSegments = 0,
  bool workLimitReached = false,
}) {
  return StrokeAcknowledgement(
    stroke: _readLittleEndianU128(packet, offset),
    revision: data.getUint64(offset + 16, Endian.little),
    highestCommittedSequence: data.getUint32(offset + 24, Endian.little),
    minTileX: data.getInt32(offset + 28, Endian.little),
    minTileY: data.getInt32(offset + 32, Endian.little),
    maxTileX: data.getInt32(offset + 36, Endian.little),
    maxTileY: data.getInt32(offset + 40, Endian.little),
    dirtyTiles: List.unmodifiable(dirtyTiles),
    confirmedSampleCount: confirmedSampleCount,
    pathLength: pathLength,
    directLength: directLength,
    legacyDabs: legacyDabs,
    compiledDabs: compiledDabs,
    cpuTilesWritten: cpuTilesWritten,
    compiledCpuTileUpdates: compiledCpuTileUpdates,
    workSegments: workSegments,
    workLimitReached: workLimitReached,
  );
}

BigInt _readLittleEndianU128(Uint8List bytes, int offset) {
  var value = BigInt.zero;
  for (var index = 15; index >= 0; index--) {
    value = (value << 8) + BigInt.from(bytes[offset + index]);
  }
  return value;
}
