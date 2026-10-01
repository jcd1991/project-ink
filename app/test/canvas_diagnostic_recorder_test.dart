import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/canvas/canvas_diagnostic_recorder.dart';

void main() {
  test(
    'rolling log retains two segments with monotonic event sequence',
    () async {
      final documents = await Directory.systemTemp.createTemp(
        'project-ink-diagnostics-',
      );
      addTearDown(() => documents.delete(recursive: true));
      final recorder = CanvasDiagnosticRecorder.forTesting(
        documentsDirectory: documents,
        segmentByteLimit: 1024,
      );

      await recorder.startRollingLog(metadata: const {'platform': 'test'});
      final payload = List<String>.filled(80, 'm').join();
      for (var batch = 0; batch < 20; batch++) {
        for (var index = 0; index < 8; index++) {
          recorder.record('test.event', {'batch': batch, 'payload': payload});
        }
        await recorder.flush();
      }
      final latestPath = await recorder.stopCapture(reason: 'unit_test');

      expect(latestPath, isNotNull);
      final traceDirectory = Directory(
        '${documents.path}/Project Ink/Diagnostics',
      );
      final segments =
          (await traceDirectory
                .list()
                .where((entity) => entity is File)
                .cast<File>()
                .toList())
            ..sort((a, b) => a.path.compareTo(b.path));
      expect(segments, hasLength(CanvasDiagnosticRecorder.maxRetainedSegments));

      final rows = <Map<String, dynamic>>[];
      for (final segment in segments) {
        for (final line in await segment.readAsLines()) {
          if (line.isNotEmpty) {
            rows.add(jsonDecode(line) as Map<String, dynamic>);
          }
        }
      }
      expect(rows.any((row) => row['type'] == 'log.segment_rotated'), isTrue);
      expect(rows.any((row) => row['type'] == 'log.stop'), isTrue);
      final sequence = rows.map((row) => row['seq'] as int).toList();
      for (var index = 1; index < sequence.length; index++) {
        expect(sequence[index], greaterThan(sequence[index - 1]));
      }
    },
  );
}
