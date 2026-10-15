import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'pointer_packet.dart';

/// A bounded snapshot of the local drawing pipeline's recent timings.
///
/// The pointer timestamp starts when Flutter receives a normalized packet, and
/// the visible timestamp is recorded by a post-frame callback. This is an
/// app-side latency trace for physical-device acceptance testing; it does not
/// claim to measure hardware scan-out or display scheduling.
class Phase1PerformanceSnapshot {
  const Phase1PerformanceSnapshot({
    required this.packetCount,
    required this.visibleUpdateCount,
    required this.dirtyTileCount,
    required this.pointerToVisibleMicros,
    required this.pointerToPreviewMicros,
    this.pointerToTextureSubmissionMicros = const <int>[],
    required this.tileDecodeMicros,
    this.sampleCount = 0,
    this.confirmedSampleCount = 0,
    this.predictedSampleCount = 0,
    this.inputSequenceGapCount = 0,
    this.rejectedPacketCount = 0,
    this.rejectedConfirmedSampleCount = 0,
    this.rssBytes,
  });

  final int packetCount;
  final int visibleUpdateCount;
  final int dirtyTileCount;
  final List<int> pointerToVisibleMicros;
  final List<int> pointerToPreviewMicros;

  /// Input-to-native texture frame request completion. This is not GPU
  /// completion, Flutter presentation, or display scan-out latency.
  final List<int> pointerToTextureSubmissionMicros;
  final List<int> tileDecodeMicros;
  final int sampleCount;
  final int confirmedSampleCount;
  final int predictedSampleCount;
  final int inputSequenceGapCount;
  final int rejectedPacketCount;
  final int rejectedConfirmedSampleCount;
  final int? rssBytes;

  double? get p95PointerToVisibleMs => _p95Milliseconds(pointerToVisibleMicros);

  double? get p99PointerToVisibleMs =>
      _percentileMilliseconds(pointerToVisibleMicros, 99);

  double? get p95TileDecodeMs => _p95Milliseconds(tileDecodeMicros);

  double? get p95PointerToPreviewMs => _p95Milliseconds(pointerToPreviewMicros);

  double? get p99PointerToPreviewMs =>
      _percentileMilliseconds(pointerToPreviewMicros, 99);

  double? get p95PointerToTextureSubmissionMs =>
      _p95Milliseconds(pointerToTextureSubmissionMicros);

  double? get p99PointerToTextureSubmissionMs =>
      _percentileMilliseconds(pointerToTextureSubmissionMicros, 99);

  Map<String, Object?> toJson() => <String, Object?>{
    'packet_count': packetCount,
    'sample_count': sampleCount,
    'confirmed_sample_count': confirmedSampleCount,
    'predicted_sample_count': predictedSampleCount,
    'input_sequence_gap_count': inputSequenceGapCount,
    'rejected_packet_count': rejectedPacketCount,
    'rejected_confirmed_sample_count': rejectedConfirmedSampleCount,
    'visible_update_count': visibleUpdateCount,
    'dirty_tile_count': dirtyTileCount,
    'p95_pointer_to_visible_ms': p95PointerToVisibleMs,
    'p99_pointer_to_visible_ms': p99PointerToVisibleMs,
    'p95_pointer_to_preview_ms': p95PointerToPreviewMs,
    'p99_pointer_to_preview_ms': p99PointerToPreviewMs,
    'p95_pointer_to_texture_submission_ms': p95PointerToTextureSubmissionMs,
    'p99_pointer_to_texture_submission_ms': p99PointerToTextureSubmissionMs,
    'p95_tile_decode_ms': p95TileDecodeMs,
    'rss_bytes': rssBytes,
  };

  Phase1PerformanceSnapshot withRssBytes(int? value) =>
      Phase1PerformanceSnapshot(
        packetCount: packetCount,
        visibleUpdateCount: visibleUpdateCount,
        dirtyTileCount: dirtyTileCount,
        pointerToVisibleMicros: pointerToVisibleMicros,
        pointerToPreviewMicros: pointerToPreviewMicros,
        pointerToTextureSubmissionMicros: pointerToTextureSubmissionMicros,
        tileDecodeMicros: tileDecodeMicros,
        sampleCount: sampleCount,
        confirmedSampleCount: confirmedSampleCount,
        predictedSampleCount: predictedSampleCount,
        inputSequenceGapCount: inputSequenceGapCount,
        rejectedPacketCount: rejectedPacketCount,
        rejectedConfirmedSampleCount: rejectedConfirmedSampleCount,
        rssBytes: value,
      );

  static double? _p95Milliseconds(List<int> samples) =>
      _percentileMilliseconds(samples, 95);

  static double? _percentileMilliseconds(List<int> samples, int percentile) {
    if (samples.isEmpty) return null;
    final sorted = List<int>.of(samples)..sort();
    final rank = math.max(0, (sorted.length * percentile + 99) ~/ 100 - 1);
    return sorted[rank] / Duration.microsecondsPerMillisecond;
  }
}

/// Native process-memory sample used only for local acceptance traces.
class Phase1MemorySampler {
  const Phase1MemorySampler();

  static const MethodChannel _channel = MethodChannel(
    'org.projectink.studio/performance_v1',
  );

  Future<int?> readRssBytes() async {
    try {
      final value = await _channel.invokeMethod<Object?>('readRssBytes');
      return value is int ? value : null;
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      debugPrint('Project Ink RSS sample unavailable: ${error.message}');
      return null;
    }
  }
}

/// Bounded monotonic trace used by the canvas and physical-device harnesses.
class Phase1PerformanceTrace {
  Phase1PerformanceTrace({this.capacity = 120})
    : assert(capacity > 0),
      _clock = Stopwatch()..start();

  final int capacity;
  final Stopwatch _clock;
  final List<int> _pointerToVisibleMicros = <int>[];
  final List<int> _pointerToPreviewMicros = <int>[];
  final List<int> _pointerToTextureSubmissionMicros = <int>[];
  final List<int> _tileDecodeMicros = <int>[];
  int _packetCount = 0;
  int _sampleCount = 0;
  int _confirmedSampleCount = 0;
  int _predictedSampleCount = 0;
  int _inputSequenceGapCount = 0;
  int _rejectedPacketCount = 0;
  int _rejectedConfirmedSampleCount = 0;
  int _visibleUpdateCount = 0;
  int _dirtyTileCount = 0;
  final Map<String, int> _lastInputSequenceBySource = <String, int>{};

  int markPacketReceived([Uint8List? packet]) =>
      _markPacketReceived(packet, source: 'default');

  /// Records a packet whose sequence space is independent of other inputs.
  int markPacketReceivedFromSource(
    Uint8List packet, {
    required String source,
  }) => _markPacketReceived(packet, source: source);

  int _markPacketReceived(Uint8List? packet, {required String source}) {
    _packetCount++;
    if (packet != null) _recordPacket(packet, source: source);
    return _clock.elapsedMicroseconds;
  }

  int get nowMicros => _clock.elapsedMicroseconds;

  /// Records the time from pointer dispatch to the ephemeral live surface.
  /// This is intentionally separate from committed-tile latency.
  void markPreviewUpdate({required int startedMicros}) {
    _append(
      _pointerToPreviewMicros,
      math.max(0, _clock.elapsedMicroseconds - startedMicros),
    );
  }

  /// Records input-to-texture-frame-request latency, separately from the
  /// immediate Flutter preview and committed CPU-tile visibility. Platform
  /// adapters call this after requesting a texture frame; it must not be
  /// interpreted as GPU completion or display presentation.
  void markNativeTextureSubmission(int latencyMicros) {
    _append(_pointerToTextureSubmissionMicros, math.max(0, latencyMicros));
  }

  /// Records a packet rejected by the Rust control plane. Confirmed samples
  /// are never silently treated as delivered when the bounded queue is full.
  void markPacketRejected(Uint8List packet) {
    final summary = summarizePointerPacket(packet);
    _rejectedPacketCount++;
    _rejectedConfirmedSampleCount += summary.confirmedSampleCount;
  }

  int markVisibleUpdate({
    required int packetMicros,
    required Duration tileDecode,
    required int dirtyTiles,
  }) {
    _visibleUpdateCount++;
    _dirtyTileCount += dirtyTiles;
    final latencyMicros = math.max(
      0,
      _clock.elapsedMicroseconds - packetMicros,
    );
    _append(_pointerToVisibleMicros, latencyMicros);
    _append(_tileDecodeMicros, math.max(0, tileDecode.inMicroseconds));
    return latencyMicros;
  }

  /// Records the first Flutter frame that painted the live path. This
  /// measures app-side packet-to-frame latency, not display scan-out.
  int markLivePreviewFramePresented({required int packetMicros}) {
    _visibleUpdateCount++;
    final latencyMicros = math.max(
      0,
      _clock.elapsedMicroseconds - packetMicros,
    );
    _append(_pointerToVisibleMicros, latencyMicros);
    return latencyMicros;
  }

  Phase1PerformanceSnapshot snapshot() => Phase1PerformanceSnapshot(
    packetCount: _packetCount,
    visibleUpdateCount: _visibleUpdateCount,
    dirtyTileCount: _dirtyTileCount,
    pointerToVisibleMicros: List.unmodifiable(_pointerToVisibleMicros),
    pointerToPreviewMicros: List.unmodifiable(_pointerToPreviewMicros),
    pointerToTextureSubmissionMicros: List.unmodifiable(
      _pointerToTextureSubmissionMicros,
    ),
    tileDecodeMicros: List.unmodifiable(_tileDecodeMicros),
    sampleCount: _sampleCount,
    confirmedSampleCount: _confirmedSampleCount,
    predictedSampleCount: _predictedSampleCount,
    inputSequenceGapCount: _inputSequenceGapCount,
    rejectedPacketCount: _rejectedPacketCount,
    rejectedConfirmedSampleCount: _rejectedConfirmedSampleCount,
  );

  void _recordPacket(Uint8List packet, {required String source}) {
    final summary = summarizePointerPacket(packet);
    _sampleCount += summary.sampleCount;
    _confirmedSampleCount += summary.confirmedSampleCount;
    _predictedSampleCount += summary.predictedSampleCount;
    for (final sequence in summary.sequences) {
      final previous = _lastInputSequenceBySource[source];
      if (previous != null) {
        final expected = (previous + 1) & 0xffffffff;
        if (sequence != expected) _inputSequenceGapCount++;
      }
      _lastInputSequenceBySource[source] = sequence;
    }
  }

  void _append(List<int> samples, int value) {
    if (samples.length == capacity) samples.removeAt(0);
    samples.add(value);
  }
}

/// Appends local-only performance snapshots for physical-device acceptance.
///
/// Records are newline-delimited JSON so a terminated run still leaves every
/// successfully flushed sample readable. File access is serialized and kept
/// off the canvas frame callback's synchronous path.
class Phase1PerformanceRecorder {
  Phase1PerformanceRecorder(this.path);

  final String path;
  Future<void> _pending = Future<void>.value();

  void append(Phase1PerformanceSnapshot snapshot) {
    _pending = _pending
        .then<void>((_) async {
          final file = File(path);
          await file.parent.create(recursive: true);
          await file.writeAsString(
            '${jsonEncode(snapshot.toJson())}\n',
            mode: FileMode.append,
            flush: true,
          );
        })
        .then<void>(
          (_) {},
          onError: (Object error, StackTrace stack) {
            debugPrint('Project Ink performance trace write failed: $error');
          },
        );
  }

  Future<void> flush() => _pending;
}
