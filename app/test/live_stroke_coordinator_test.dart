import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/canvas/live_stroke_coordinator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('live preview uses the selected brush pressure curve', () {
    final preview = LiveStrokePreview(
      color: Colors.black,
      width: 10,
      pressureSize: 0.5,
      pressureCurvePoints: const <double>[0, 0, 0.2, 0.32, 0.5, 0.68, 1, 1],
      documentWidth: 100,
      documentHeight: 100,
      legacyTechnicalPen: false,
      eraser: false,
      points: <LiveStrokePreviewPoint>[],
      chunks: <LiveStrokePreviewChunk>[],
    );

    final width = liveStrokePreviewWidthAt(
      preview,
      const LiveStrokePreviewPoint(Offset.zero, 0.2),
    );

    expect(width, closeTo(8.2, 0.001));
  });

  test('confirmed source gaps map to ordered preview coverage and chunks', () {
    final coordinator = LiveStrokeCoordinator();
    final preview = LiveStrokePreview(
      color: Colors.black,
      width: 8,
      pressureSize: 0.5,
      documentWidth: 1024,
      documentHeight: 1024,
      legacyTechnicalPen: false,
      eraser: false,
      points: <LiveStrokePreviewPoint>[
        const LiveStrokePreviewPoint(Offset(512, 512), 0.2, sourceSequence: 40),
      ],
      chunks: <LiveStrokePreviewChunk>[],
    );
    coordinator.recordConfirmedSample(40, 0);

    for (var index = 1; index <= 257; index++) {
      final previewIndex = coordinator.appendPoint(
        preview,
        LiveStrokePreviewPoint(
          Offset(512 + index.toDouble(), 512),
          index / 257,
          // Sequence gaps represent discarded predicted UIKit samples.
          sourceSequence: 40 + index * 2,
        ),
      );
      expect(previewIndex, index);
    }

    expect(coordinator.previewIndexForSourceSequence(40), 0);
    expect(coordinator.previewIndexForSourceSequence(42), 1);
    expect(coordinator.previewIndexForSourceSequence(44), 2);
    expect(coordinator.previewIndexForSourceSequence(41), -1);
    expect(preview.chunks, hasLength(8));
    expect(
      preview.chunks.map(
        (chunk) => (chunk.firstPointIndex, chunk.lastPointIndex),
      ),
      <(int, int)>[
        (0, 32),
        (32, 64),
        (64, 96),
        (96, 128),
        (128, 160),
        (160, 192),
        (192, 224),
        (224, 256),
      ],
    );
    expect(coordinator.pendingChunkCount(preview), 8);
    expect(
      coordinator.pendingChunkCount(preview.copyWith(confirmedThrough: 129)),
      4,
    );
    final fullyCommitted = preview.copyWith(confirmedThrough: 257);
    expect(coordinator.pendingChunkCount(fullyCommitted), 0);
    expect(coordinator.oldestChunkAgeMicros(fullyCommitted), 0);

    coordinator.retireThrough(128);
    expect(coordinator.previewIndexForSourceSequence(296), -1);
    expect(coordinator.previewIndexForSourceSequence(298), 129);

    for (final chunk in preview.chunks) {
      chunk.picture.dispose();
    }
  });
}
