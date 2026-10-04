import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/bridge/engine_api.dart';
import 'package:project_ink/canvas/canvas_diagnostic_recorder.dart';
import 'package:project_ink/canvas/canvas_stroke_preview_actions.dart';
import 'package:project_ink/canvas/live_stroke_coordinator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('clips the confirmed preview at the document edge', () {
    final host = _PreviewHostState();
    final actions = host.actions;

    actions.beginStroke(
      position: const Offset(10, 20),
      pressure: 0.4,
      sourceSequence: 5,
    );
    final index = actions.appendSample(
      position: const Offset(120, 20),
      pressure: 0.7,
      sourceSequence: 9,
      isUp: false,
    );

    expect(index, 1);
    expect(host.preview!.points.last.position, const Offset(99, 20));
    expect(actions.previewIndexForSourceSequence(9), 1);
    expect(host.previewStoppedAtPageEdge, isTrue);
    expect(
      actions.appendSample(
        position: const Offset(40, 20),
        pressure: 0.7,
        sourceSequence: 10,
        isUp: false,
      ),
      -1,
    );
  });

  test('native batches can enter the page after off-page samples', () {
    final host = _PreviewHostState();
    host.actions.appendNativeBatch(const [
      LiveStrokePreviewPoint(Offset(-10, 20), 0.3, sourceSequence: 1),
      LiveStrokePreviewPoint(Offset(12, 20), 0.4, sourceSequence: 2),
      LiveStrokePreviewPoint(Offset(30, 20), 0.5, sourceSequence: 3),
      LiveStrokePreviewPoint(Offset(120, 20), 0.6, sourceSequence: 4),
    ], beginsStroke: true);

    expect(host.preview!.points.map((point) => point.position), [
      const Offset(12, 20),
      const Offset(30, 20),
      const Offset(99, 20),
    ]);
    expect(host.actions.previewIndexForSourceSequence(1), -1);
    expect(host.actions.previewIndexForSourceSequence(2), 0);
    expect(host.actions.previewIndexForSourceSequence(4), 2);
    expect(host.previewStoppedAtPageEdge, isTrue);
  });

  test('retires only a completed preview already covered by CPU', () {
    final host = _PreviewHostState();
    host.actions.beginStroke(
      position: const Offset(10, 10),
      pressure: 1,
      sourceSequence: 1,
    );
    host.actions.appendSample(
      position: const Offset(20, 20),
      pressure: 1,
      sourceSequence: 2,
      isUp: false,
    );
    host.awaitingPreviewCommit = true;
    host.strokeActive = false;
    host.preview = host.preview!.copyWith(confirmedThrough: 2);

    host.actions.retireIfAlreadyCpuCovered(source: 'test');

    expect(host.preview, isNull);
    expect(host.awaitingPreviewCommit, isFalse);
    expect(host.actions.previewIndexForSourceSequence(2), -1);
  });
}

class _PreviewHostState {
  LiveStrokePreview? preview;
  bool previewStoppedAtPageEdge = false;
  bool strokeActive = true;
  bool awaitingPreviewCommit = false;
  StrokeAcknowledgement? lastAcknowledgement;

  late final CanvasStrokePreviewActions actions = CanvasStrokePreviewActions(
    CanvasStrokePreviewHost(
      preview: () => preview,
      publishPreview: (value) => preview = value,
      documentWidth: () => 100,
      documentHeight: () => 100,
      isInsideDocument:
          (position) =>
              position.dx >= 0 &&
              position.dy >= 0 &&
              position.dx <= 99 &&
              position.dy <= 99,
      boundPosition:
          (position) => Offset(
            position.dx.clamp(0, 99).toDouble(),
            position.dy.clamp(0, 99).toDouble(),
          ),
      color: () => Colors.black,
      width: () => 8,
      pressureSize: () => 0,
      opacity: () => 1,
      pressureOpacity: () => 0,
      eraser: () => false,
      previewStoppedAtPageEdge: () => previewStoppedAtPageEdge,
      setPreviewStoppedAtPageEdge: (value) => previewStoppedAtPageEdge = value,
      strokeActive: () => strokeActive,
      awaitingPreviewCommit: () => awaitingPreviewCommit,
      setAwaitingPreviewCommit: (value) => awaitingPreviewCommit = value,
      lastAcknowledgement: () => lastAcknowledgement,
      clearLastAcknowledgement: () => lastAcknowledgement = null,
      diagnostics: CanvasDiagnosticRecorder.instance,
    ),
  );
}
