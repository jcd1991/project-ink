import 'dart:ui' as ui;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/bridge/engine_api/engine_api_models.dart';
import 'package:project_ink/canvas/canvas_painters.dart';
import 'package:project_ink/canvas/canvas_smart_guides.dart';

void main() {
  test('records the Bézier candidate in the viewport overlay', () {
    const candidate = VectorCandidateView(
      token: 1,
      sourceId: 9,
      revision: 3,
      matched: true,
      kind: 'BezierPath',
      geometry: <double>[2, 2, 2, 2, 7, 2, 18, 2, 13, 2, 18, 2],
      subpathStarts: <int>[0],
      closed: <bool>[false],
      strokeRgba: 0xff0000ff,
      strokeWidth: 2,
      notice: '',
    );
    const painter = CanvasOverlayPainter(
      pan: Offset.zero,
      scale: 1,
      rotation: 0,
      mirrored: false,
      documentWidth: 20,
      documentHeight: 20,
      selection: null,
      selectionTool: null,
      previewPoints: <Offset>[],
      vectorCandidate: candidate,
      smartGuides: CanvasSmartGuideResult(
        delta: math.Point<double>(0, 0),
        verticalX: 10,
        horizontalY: 12,
      ),
      rulerStart: null,
      rulerEnd: null,
    );
    final recorder = ui.PictureRecorder();
    expect(
      () => painter.paint(Canvas(recorder), const Size(20, 20)),
      returnsNormally,
    );
    recorder.endRecording().dispose();
  });
}
