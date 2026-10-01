import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// User-started, device-local input/render trace for canvas troubleshooting.
///
/// Captures exact pointer and live-dab packets plus committed composite tiles.
/// A strict byte ceiling bounds storage. Nothing is uploaded automatically.
class CanvasDiagnosticRecorder extends ChangeNotifier {
  CanvasDiagnosticRecorder._();

  static final CanvasDiagnosticRecorder instance = CanvasDiagnosticRecorder._();
  static const int maxSessionBytes = 32 * 1024 * 1024;

  IOSink? _sink;
  String? _activePath;
  String? _latestPath;
  int _writtenBytes = 0;
  int _sequence = 0;
  final Stopwatch _clock = Stopwatch();
  bool _truncated = false;
  bool _ioFailed = false;

  bool get isRecording => _sink != null && !_ioFailed;
  bool get hitSizeLimit => _truncated;
  String? get activePath => _activePath;
  String? get latestPath => _latestPath;
  int get writtenBytes => _writtenBytes;
  int get elapsedMicroseconds => _clock.elapsedMicroseconds;

  Future<String> startCapture({
    Map<String, Object?> metadata = const {},
  }) async {
    if (isRecording) return _activePath!;
    final documents = await getApplicationDocumentsDirectory();
    final directory = Directory(
      path.join(documents.path, 'Project Ink', 'Diagnostics'),
    );
    await directory.create(recursive: true);
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
    final file = File(path.join(directory.path, 'canvas-$stamp.jsonl'));
    _sink = file.openWrite(mode: FileMode.writeOnlyAppend);
    _activePath = file.path;
    _latestPath = file.path;
    _writtenBytes = 0;
    _sequence = 0;
    _truncated = false;
    _ioFailed = false;
    _clock
      ..reset()
      ..start();
    record('capture.start', <String, Object?>{
      'schema': 'project-ink-canvas-trace-v1',
      'maxBytes': maxSessionBytes,
      ...metadata,
    });
    notifyListeners();
    return file.path;
  }

  void record(String type, [Map<String, Object?> fields = const {}]) {
    final sink = _sink;
    if (sink == null || _truncated || _ioFailed) return;
    final row = <String, Object?>{
      'seq': _sequence++,
      'tUs': _clock.elapsedMicroseconds,
      'type': type,
      ...fields,
    };
    final encoded = '${jsonEncode(row)}\n';
    final bytes = utf8.encode(encoded).length;
    // Leave space for a final truncation marker so readers can distinguish a
    // complete capture from one cut short by the resource bound.
    if (_writtenBytes + bytes > maxSessionBytes - 256) {
      _truncated = true;
      final marker =
          '${jsonEncode(<String, Object?>{'seq': _sequence++, 'tUs': _clock.elapsedMicroseconds, 'type': 'capture.truncated', 'reason': 'session_byte_limit', 'maxBytes': maxSessionBytes})}\n';
      sink.add(utf8.encode(marker));
      _writtenBytes += utf8.encode(marker).length;
      notifyListeners();
      return;
    }
    sink.add(utf8.encode(encoded));
    _writtenBytes += bytes;
  }

  void recordPacket(
    String type,
    String stage,
    List<int> packet, {
    Map<String, Object?> fields = const {},
  }) {
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

  Future<String?> stopCapture({String reason = 'user'}) async {
    final sink = _sink;
    if (sink == null) return _latestPath;
    record('capture.stop', <String, Object?>{
      'reason': reason,
      'durationUs': _clock.elapsedMicroseconds,
      'writtenBytes': _writtenBytes,
      'truncated': _truncated,
    });
    _sink = null;
    _activePath = null;
    _clock.stop();
    try {
      await sink.flush();
      await sink.close();
    } catch (error) {
      _ioFailed = true;
      debugPrint('Project Ink diagnostic trace write failed: $error');
    }
    notifyListeners();
    return _latestPath;
  }

  Future<String?> flush() async {
    // IOSink.flush binds its internal stream while pending bytes drain. Pointer
    // events are recorded synchronously on the UI isolate, so flushing during
    // a live capture can make a concurrent add throw. Stop the capture first;
    // stopCapture performs the final flush after detaching the sink.
    if (isRecording) return _activePath ?? _latestPath;
    try {
      await _sink?.flush();
      return _activePath ?? _latestPath;
    } catch (error) {
      recordError('diagnostic_storage', error);
      _ioFailed = true;
      notifyListeners();
      return _latestPath;
    }
  }

  Future<void> markIoFailure(Object error) async {
    _ioFailed = true;
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
    notifyListeners();
  }
}
