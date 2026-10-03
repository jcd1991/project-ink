import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import '../documents/project_documents_directory.dart';

/// Bounded, device-local rolling trace for canvas troubleshooting.
///
/// The logger retains the current and previous 32 MB segments. It starts once
/// per app process and is independent of canvas screen lifetime. Nothing is
/// uploaded automatically.
class CanvasDiagnosticRecorder {
  CanvasDiagnosticRecorder._()
    : _documentsDirectoryProvider = projectDocumentsDirectory,
      _segmentByteLimit = maxSegmentBytes;

  @visibleForTesting
  CanvasDiagnosticRecorder.forTesting({
    required Directory documentsDirectory,
    int segmentByteLimit = maxSegmentBytes,
  }) : _documentsDirectoryProvider = (() async => documentsDirectory),
       _segmentByteLimit = segmentByteLimit;

  static final CanvasDiagnosticRecorder instance = CanvasDiagnosticRecorder._();

  static const int maxSegmentBytes = 32 * 1024 * 1024;
  static const int maxRetainedSegments = 2;
  static const int maxRotationBufferBytes = 4 * 1024 * 1024;

  final Future<Directory> Function() _documentsDirectoryProvider;
  final int _segmentByteLimit;

  IOSink? _sink;
  String? _activePath;
  String? _latestPath;
  int _writtenBytes = 0;
  int _sequence = 0;
  int _segment = 0;
  String? _sessionStamp;
  Directory? _directory;
  Future<void>? _rotation;
  final List<String> _rotationBuffer = <String>[];
  int _rotationBufferBytes = 0;
  int _rotationDroppedRows = 0;
  final Stopwatch _clock = Stopwatch();
  bool _recording = false;
  bool _ioFailed = false;

  bool get isRecording => _recording && !_ioFailed;
  String? get activePath => _activePath;
  String? get latestPath => _latestPath;
  int get writtenBytes => _writtenBytes;
  int get elapsedMicroseconds => _clock.elapsedMicroseconds;

  /// Starts rolling diagnostics once for the current application process.
  /// Calling this more than once is safe and leaves an active log untouched.
  Future<String> startRollingLog({
    Map<String, Object?> metadata = const {},
  }) async {
    if (isRecording) return _activePath ?? _latestPath!;
    return _startNewLog(metadata: metadata);
  }

  /// Starts a fresh segment for deterministic tests and local tooling.
  /// Production code should use [startRollingLog].
  @visibleForTesting
  Future<String> startCapture({
    Map<String, Object?> metadata = const {},
  }) async {
    if (isRecording) await stopCapture(reason: 'capture_restarted');
    return _startNewLog(metadata: metadata);
  }

  Future<String> _startNewLog({required Map<String, Object?> metadata}) async {
    final documents = await _documentsDirectoryProvider();
    final directory = Directory(
      path.join(documents.path, 'Project Ink', 'Diagnostics'),
    );
    await directory.create(recursive: true);

    _directory = directory;
    _sessionStamp = DateTime.now().toUtc().toIso8601String().replaceAll(
      ':',
      '-',
    );
    _segment = 0;
    _sequence = 0;
    _writtenBytes = 0;
    _ioFailed = false;
    _rotationBuffer.clear();
    _rotationBufferBytes = 0;
    _rotationDroppedRows = 0;
    _clock
      ..reset()
      ..start();
    _recording = false;
    try {
      await _openSegment();
    } catch (_) {
      _activePath = null;
      _clock.stop();
      rethrow;
    }
    _recording = true;
    record('log.start', <String, Object?>{
      'schema': 'project-ink-canvas-trace-v1',
      'maxSegmentBytes': _segmentByteLimit,
      'maxRetainedSegments': maxRetainedSegments,
      ...metadata,
    });
    await _pruneOldSegments();
    return _activePath!;
  }

  Future<void> _openSegment() async {
    final directory = _directory;
    final stamp = _sessionStamp;
    if (directory == null || stamp == null) {
      throw StateError('Canvas diagnostics were not initialized.');
    }
    final fileName =
        'canvas-$stamp-${_segment.toString().padLeft(3, '0')}.jsonl';
    final file = File(path.join(directory.path, fileName));
    _sink = file.openWrite(mode: FileMode.writeOnly);
    _activePath = file.path;
    _latestPath = file.path;
    _writtenBytes = 0;
  }

  void record(String type, [Map<String, Object?> fields = const {}]) {
    if (!isRecording) return;
    _write(<String, Object?>{
      'seq': _sequence++,
      'tUs': _clock.elapsedMicroseconds,
      'type': type,
      ...fields,
    });
  }

  void _write(Map<String, Object?> row) {
    final encoded = '${jsonEncode(row)}\n';
    final bytes = utf8.encode(encoded);
    final rotation = _rotation;
    if (rotation != null) {
      _bufferDuringRotation(encoded, bytes.length);
      return;
    }

    if (_writtenBytes + bytes.length > _segmentByteLimit - 512) {
      _bufferDuringRotation(encoded, bytes.length);
      _rotation = _rotateSegment();
      return;
    }
    _sink?.add(bytes);
    _writtenBytes += bytes.length;
  }

  void _bufferDuringRotation(String encoded, int bytes) {
    _rotationBuffer.add(encoded);
    _rotationBufferBytes += bytes;
    while (_rotationBufferBytes > maxRotationBufferBytes &&
        _rotationBuffer.isNotEmpty) {
      _rotationBufferBytes -= utf8.encode(_rotationBuffer.removeAt(0)).length;
      _rotationDroppedRows++;
    }
  }

  Future<void> _rotateSegment() async {
    final previousSink = _sink;
    _sink = null;
    try {
      await previousSink?.flush();
      await previousSink?.close();
      _segment++;
      await _openSegment();
      for (final line in _rotationBuffer) {
        final bytes = utf8.encode(line);
        _sink?.add(bytes);
        _writtenBytes += bytes.length;
      }
      _rotationBuffer.clear();
      _rotationBufferBytes = 0;
      final rotationMarker = utf8.encode(
        '${jsonEncode(<String, Object?>{'seq': _sequence++, 'tUs': _clock.elapsedMicroseconds, 'type': 'log.segment_rotated', 'segment': _segment, 'rowsDroppedDuringRotation': _rotationDroppedRows})}\n',
      );
      _sink?.add(rotationMarker);
      _writtenBytes += rotationMarker.length;
      _rotationDroppedRows = 0;
      // New records can go directly to the open sink while old segments are
      // removed from the directory.
      _rotation = null;
      await _pruneOldSegments();
    } catch (error) {
      _ioFailed = true;
      _recording = false;
      _activePath = null;
      _clock.stop();
      debugPrint('Project Ink rolling diagnostic log failed: $error');
    } finally {
      _rotation = null;
    }
  }

  Future<void> _pruneOldSegments() async {
    final directory = _directory;
    if (directory == null) return;
    try {
      final files =
          await directory
              .list()
              .where(
                (entity) =>
                    entity is File &&
                    path.basename(entity.path).startsWith('canvas-') &&
                    entity.path.endsWith('.jsonl'),
              )
              .cast<File>()
              .toList();
      files.sort((a, b) => a.path.compareTo(b.path));
      final excess = files.length - maxRetainedSegments;
      for (final file in files.take(excess > 0 ? excess : 0)) {
        if (file.path == _activePath) continue;
        try {
          await file.delete();
        } catch (error) {
          debugPrint(
            'Project Ink old diagnostic segment cleanup failed: $error',
          );
        }
      }
    } catch (error) {
      debugPrint('Project Ink diagnostic segment listing failed: $error');
    }
  }

  void recordPacket(
    String type,
    String stage,
    List<int> packet, {
    Map<String, Object?> fields = const {},
  }) {
    if (!isRecording) return;
    record(type, <String, Object?>{
      'stage': stage,
      'byteLength': packet.length,
      'packetBase64': base64Encode(packet),
      ...fields,
    });
  }

  void recordError(String source, Object error, [StackTrace? stack]) {
    record('error', <String, Object?>{
      'source': source,
      'message': error.toString(),
      if (stack != null) 'stack': stack.toString(),
    });
  }

  void recordCompositeTile({
    required int revision,
    required int x,
    required int y,
    required List<int> pixelBytes,
    required bool includePixels,
  }) {
    if (!isRecording) return;
    int? hash;
    if (includePixels) {
      var computedHash = 0x811c9dc5;
      for (final byte in pixelBytes) {
        computedHash = ((computedHash ^ byte) * 0x01000193) & 0xffffffff;
      }
      hash = computedHash;
    }
    record('canvas.cpu_composite_tile', <String, Object?>{
      'revision': revision,
      'tileX': x,
      'tileY': y,
      'byteLength': pixelBytes.length,
      if (hash != null) 'fnv1a32': hash.toRadixString(16).padLeft(8, '0'),
      if (includePixels) 'tileBytesBase64': base64Encode(pixelBytes),
    });
  }

  @visibleForTesting
  Future<String?> stopCapture({String reason = 'test'}) async {
    final rotation = _rotation;
    if (rotation != null) await rotation;
    if (!_recording) return _latestPath;
    _write(<String, Object?>{
      'seq': _sequence++,
      'tUs': _clock.elapsedMicroseconds,
      'type': 'log.stop',
      'reason': reason,
      'writtenBytes': _writtenBytes,
      'rotationBufferDroppedRows': _rotationDroppedRows,
    });
    final finalRotation = _rotation;
    if (finalRotation != null) await finalRotation;
    _recording = false;
    final sink = _sink;
    _sink = null;
    _activePath = null;
    _clock.stop();
    try {
      await sink?.flush();
      await sink?.close();
    } catch (error) {
      _ioFailed = true;
      debugPrint('Project Ink diagnostic trace write failed: $error');
    }
    return _latestPath;
  }

  Future<String?> flush() async {
    final rotation = _rotation;
    if (rotation != null) await rotation;
    if (!isRecording) return _latestPath;
    try {
      await _sink?.flush();
      return _activePath ?? _latestPath;
    } catch (error) {
      recordError('diagnostic_storage', error);
      _ioFailed = true;
      _recording = false;
      _clock.stop();
      return _latestPath;
    }
  }

  Future<void> markIoFailure(Object error) async {
    _ioFailed = true;
    _recording = false;
    final sink = _sink;
    _sink = null;
    _activePath = null;
    _clock.stop();
    if (sink != null) {
      try {
        await sink.close();
      } catch (_) {}
    }
    debugPrint(
      'Project Ink diagnostic trace disabled after storage error: $error',
    );
  }
}
