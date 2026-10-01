import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/canvas/performance_trace.dart';
import 'package:project_ink/canvas/pointer_packet.dart';

void main() {
  test('keeps a bounded trace and reports p95 and p99', () async {
    final trace = Phase1PerformanceTrace(capacity: 3);
    final first = trace.markPacketReceived();
    await Future<void>.delayed(const Duration(milliseconds: 1));
    trace.markVisibleUpdate(
      packetMicros: first,
      tileDecode: const Duration(microseconds: 10),
      dirtyTiles: 2,
    );
    final second = trace.markPacketReceived();
    trace.markVisibleUpdate(
      packetMicros: second,
      tileDecode: const Duration(microseconds: 20),
      dirtyTiles: 3,
    );
    final third = trace.markPacketReceived();
    trace.markVisibleUpdate(
      packetMicros: third,
      tileDecode: const Duration(microseconds: 30),
      dirtyTiles: 4,
    );
    final fourth = trace.markPacketReceived();
    trace.markVisibleUpdate(
      packetMicros: fourth,
      tileDecode: const Duration(microseconds: 40),
      dirtyTiles: 5,
    );
    for (final sample in <int>[10, 20, 30, 40]) {
      trace.markNativeTextureSubmission(sample);
    }

    final snapshot = trace.snapshot();
    expect(snapshot.packetCount, 4);
    expect(snapshot.visibleUpdateCount, 4);
    expect(snapshot.dirtyTileCount, 14);
    expect(snapshot.tileDecodeMicros, <int>[20, 30, 40]);
    expect(snapshot.p95TileDecodeMs, 0.04);
    expect(snapshot.pointerToTextureSubmissionMicros, <int>[20, 30, 40]);
    expect(snapshot.p95PointerToTextureSubmissionMs, 0.04);
    expect(snapshot.p99PointerToTextureSubmissionMs, 0.04);
    expect(snapshot.toJson()['visible_update_count'], 4);
    expect(snapshot.toJson()['p95_pointer_to_texture_submission_ms'], 0.04);
    expect(snapshot.toJson()['p99_pointer_to_texture_submission_ms'], 0.04);
  });

  test('counts the first Flutter preview frame as a visible update', () async {
    final trace = Phase1PerformanceTrace();
    final packet = trace.markPacketReceived();
    await Future<void>.delayed(const Duration(milliseconds: 1));
    trace.markLivePreviewFramePresented(packetMicros: packet);

    final snapshot = trace.snapshot();
    expect(snapshot.visibleUpdateCount, 1);
    expect(snapshot.pointerToVisibleMicros.single, greaterThan(0));
    expect(snapshot.p99PointerToVisibleMs, greaterThan(0));
  });

  test('writes local snapshots as newline-delimited JSON', () async {
    final directory = await Directory.systemTemp.createTemp(
      'project-ink-trace-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/phase1.jsonl';
    final recorder = Phase1PerformanceRecorder(path);
    recorder.append(
      const Phase1PerformanceSnapshot(
        packetCount: 4,
        visibleUpdateCount: 2,
        dirtyTileCount: 3,
        pointerToVisibleMicros: [1000, 2000],
        pointerToPreviewMicros: [20, 30],
        tileDecodeMicros: [400, 600],
        rssBytes: 1234,
      ),
    );
    await recorder.flush();

    final lines = await File(path).readAsLines();
    expect(lines, hasLength(1));
    final decoded = jsonDecode(lines.single) as Map<String, dynamic>;
    expect(decoded['packet_count'], 4);
    expect(decoded['p95_pointer_to_visible_ms'], 2.0);
    expect(decoded['dirty_tile_count'], 3);
    expect(decoded['rss_bytes'], 1234);
  });

  test('accounts for confirmed, predicted, rejected, and gapped samples', () {
    final trace = Phase1PerformanceTrace();
    trace.markPacketReceived(
      encodePointerPacket(
        pointerId: 1,
        device: InkPointerDevice.stylus,
        phase: InkPointerPhase.down,
        x: 10,
        y: 10,
        pressure: 1,
        timestampNs: 1,
        sequence: 10,
      ),
    );
    trace.markPacketReceived(
      encodePointerPacket(
        pointerId: 1,
        device: InkPointerDevice.stylus,
        phase: InkPointerPhase.move,
        x: 11,
        y: 11,
        pressure: 1,
        timestampNs: 2,
        sequence: 11,
        flags: inkPointerPredicted,
      ),
    );
    final rejected = encodePointerPacket(
      pointerId: 1,
      device: InkPointerDevice.stylus,
      phase: InkPointerPhase.up,
      x: 12,
      y: 12,
      pressure: 1,
      timestampNs: 3,
      sequence: 13,
    );
    trace.markPacketReceived(rejected);
    trace.markPacketRejected(rejected);

    final snapshot = trace.snapshot();
    expect(snapshot.sampleCount, 3);
    expect(snapshot.confirmedSampleCount, 2);
    expect(snapshot.predictedSampleCount, 1);
    expect(snapshot.inputSequenceGapCount, 1);
    expect(snapshot.rejectedPacketCount, 1);
    expect(snapshot.rejectedConfirmedSampleCount, 1);
    expect(snapshot.toJson()['confirmed_sample_count'], 2);
    expect(snapshot.toJson()['input_sequence_gap_count'], 1);
  });

  test('tracks sequence continuity independently for each input source', () {
    final trace = Phase1PerformanceTrace();

    Uint8List packet(int sequence) => encodePointerPacket(
      pointerId: 1,
      device: InkPointerDevice.stylus,
      phase: InkPointerPhase.move,
      x: 10,
      y: 10,
      pressure: 1,
      timestampNs: sequence,
      sequence: sequence,
    );

    trace.markPacketReceivedFromSource(packet(620), source: 'flutter_pointer');
    trace.markPacketReceivedFromSource(packet(0), source: 'native_pencil');
    trace.markPacketReceivedFromSource(packet(1), source: 'native_pencil');
    trace.markPacketReceivedFromSource(packet(621), source: 'flutter_pointer');

    expect(trace.snapshot().inputSequenceGapCount, 0);
  });
}
