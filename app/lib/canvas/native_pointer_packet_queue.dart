import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'pointer_packet.dart';

/// Owns native packet buffering and ordered move-packet compaction.
///
/// The canvas supplies the serial work queue and packet handler. Transaction
/// boundary packets (down, up, cancel) are always kept intact and in order.
class NativePointerPacketQueue {
  final List<Uint8List> _pending = <Uint8List>[];
  bool _drainScheduled = false;

  int get pendingCount => _pending.length;
  bool get isDrainScheduled => _drainScheduled;

  /// Returns true only when the caller must enqueue a drain operation.
  bool enqueue(Uint8List packet) {
    _pending.add(packet);
    if (_drainScheduled) return false;
    _drainScheduled = true;
    return true;
  }

  void clear() {
    _pending.clear();
    _drainScheduled = false;
  }

  Future<void> drain({
    required bool Function() isActive,
    required Future<void> Function(Uint8List packet) handlePacket,
    required VoidCallback scheduleDrain,
    required VoidCallback onIdle,
  }) async {
    try {
      while (_pending.isNotEmpty && isActive()) {
        final batch = List<Uint8List>.of(_pending);
        _pending.clear();
        for (final packet in compactNativePointerPackets(batch)) {
          await handlePacket(packet);
        }
      }
    } finally {
      _drainScheduled = false;
      if (_pending.isNotEmpty && isActive()) {
        _drainScheduled = true;
        scheduleDrain();
      } else if (isActive()) {
        onIdle();
      }
    }
  }
}

/// Merge adjacent move-only packets while retaining every confirmed sample.
/// Predicted samples are disposable; down/up/cancel packets form transaction
/// boundaries and are never merged with neighboring packets.
List<Uint8List> compactNativePointerPackets(List<Uint8List> packets) {
  if (packets.length <= 1) return packets;
  final result = <Uint8List>[];
  final movePackets = <Uint8List>[];
  void flushMoves() {
    if (movePackets.isEmpty) return;
    result.addAll(_mergeNativeMovePackets(movePackets));
    movePackets.clear();
  }

  for (final packet in packets) {
    final data = ByteData.sublistView(packet);
    final count = data.getUint16(2, Endian.little);
    var moveOnly = count > 0;
    for (var index = 0; index < count && moveOnly; index++) {
      moveOnly =
          data.getUint8(4 + index * 48 + 7) == InkPointerPhase.move.index;
    }
    if (moveOnly) {
      movePackets.add(packet);
    } else {
      flushMoves();
      result.add(packet);
    }
  }
  flushMoves();
  return result;
}

List<Uint8List> _mergeNativeMovePackets(List<Uint8List> packets) {
  if (packets.length == 1) return packets;
  const sampleBytes = 48;
  const maxSamples = inkPointerMaxSamples;
  final samples = <Uint8List>[];
  for (final packet in packets) {
    final data = ByteData.sublistView(packet);
    final count = data.getUint16(2, Endian.little);
    for (var index = 0; index < count; index++) {
      final offset = 4 + index * sampleBytes;
      final flags = data.getUint16(offset + 4, Endian.little);
      if (flags & inkPointerPredicted != 0) continue;
      samples.add(Uint8List.sublistView(packet, offset, offset + sampleBytes));
    }
  }
  final result = <Uint8List>[];
  for (var start = 0; start < samples.length; start += maxSamples) {
    final end = math.min(start + maxSamples, samples.length);
    final packet = Uint8List(4 + (end - start) * sampleBytes);
    final data = ByteData.sublistView(packet);
    data.setUint16(0, 1, Endian.little);
    data.setUint16(2, end - start, Endian.little);
    var offset = 4;
    for (final sample in samples.getRange(start, end)) {
      packet.setRange(offset, offset + sampleBytes, sample);
      offset += sampleBytes;
    }
    result.add(packet);
  }
  return result;
}
