import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/bridge/engine_api/engine_api_models.dart';
import 'package:project_ink/canvas/canvas_workspace_widgets.dart';

void main() {
  testWidgets('shape preview discloses uniform-width pressure conversion', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              _inspector(
                candidate: _candidate(
                  matched: true,
                  kind: 'Rectangle',
                  notice:
                      'Pressure variation becomes a uniform-width vector '
                      'stroke. The original ink remains recoverable.',
                ),
              ),
            ],
          ),
        ),
      ),
    );

    expect(
      find.text(
        'Pressure variation becomes a uniform-width vector stroke. '
        'The original ink remains recoverable.',
      ),
      findsOneWidget,
    );
    expect(find.text('Apply'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
  });

  testWidgets('NoMatch preview shows the supported-shape message', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              _inspector(
                candidate: _candidate(
                  matched: false,
                  kind: 'NoMatch',
                  notice: 'No supported shape recognized.',
                ),
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('No supported shape recognized.'), findsOneWidget);
    expect(find.text('Apply'), findsNothing);
  });

  testWidgets('inspector explains the vector eraser selection limit', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ListView(children: [_inspector(candidate: null)])),
      ),
    );

    expect(
      find.textContaining(
        'Vector eraser edits selected legacy ink only; Bézier paths are not '
        'segment-erasable.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('selected Bézier paths expose the repeat settings dialog', (
    tester,
  ) async {
    CanvasVectorRepeatOptions? applied;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              _inspector(
                candidate: null,
                kind: 'BezierPath',
                onRepeat: (options) => applied = options,
              ),
            ],
          ),
        ),
      ),
    );

    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Repeat path'),
          )
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.text('Repeat path'));
    await tester.pumpAndSettle();
    expect(find.text('Repeat Bézier path'), findsOneWidget);
    expect(find.text('Additional copies (1–64)'), findsOneWidget);

    await tester.tap(find.text('Radial'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Grid').last);
    await tester.pumpAndSettle();
    expect(find.text('Columns (including source)'), findsOneWidget);
    await tester.tap(find.text('Create copies'));
    await tester.pumpAndSettle();
    expect(applied?.mode, CanvasVectorRepeatMode.grid);
    expect(applied?.columns, 3);
    expect(applied?.rows, 3);
  });
}

VectorInspector _inspector({
  required VectorCandidateView? candidate,
  String kind = 'LegacyInk',
  ValueChanged<CanvasVectorRepeatOptions>? onRepeat,
}) => VectorInspector(
  strokes: [
    VectorObjectSummaryView(
      id: 1,
      kind: kind,
      pointCount: 5,
      minX: 0,
      minY: 0,
      maxX: 10,
      maxY: 10,
      hasSourceArchive: false,
    ),
  ],
  selectedStrokeIds: const {1},
  candidate: candidate,
  onToggleSelection: (_) {},
  onSimplify: () {},
  onConnect: () {},
  onEditPoint: () {},
  onRecognize: () {},
  onFitCurve: (_) {},
  onApplyCandidate: () {},
  onConstrainCandidate: (_) {},
  onCancelCandidate: () {},
  hasMore: false,
  onLoadMore: () {},
  onRestoreOriginalInk: () {},
  onEditPath: (_) {},
  onRepeat: onRepeat ?? (_) {},
);

VectorCandidateView _candidate({
  required bool matched,
  required String kind,
  required String notice,
}) => VectorCandidateView(
  token: 1,
  sourceId: 1,
  revision: 1,
  matched: matched,
  kind: kind,
  geometry: const <double>[],
  subpathStarts: const <int>[],
  closed: const <bool>[],
  strokeRgba: 0xff0000ff,
  strokeWidth: 2,
  notice: notice,
);
