import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/bridge/engine_api.dart';
import 'package:project_ink/canvas/canvas_tool_actions.dart';
import 'package:project_ink/layers/layer_panel_model.dart';
import 'package:project_ink/tools/illustration_tools.dart';

void main() {
  testWidgets('fill starts from brush color and accepts the existing picker', (
    tester,
  ) async {
    final engine = _RecordingFillEngine();
    BuildContext? pageContext;
    Color? pickerInitialColor;
    Future<void>? fillFuture;
    var dirty = false;
    var refreshed = false;
    final actions = CanvasToolActions(
      CanvasToolActionHost(
        engine: () => engine,
        context: () => pageContext!,
        mounted: () => true,
        layers: () => const <LayerView>[],
        primaryLayerId: () => 1,
        activeTool: () => IllustrationTool.brush,
        setSelectionGeometryTool: (_) {},
        markDirty: () => dirty = true,
        refreshTiles: () async => refreshed = true,
        activeColor: () => const Color(0xff804020),
        pickFillColor: (initialColor) async {
          pickerInitialColor = initialColor;
          return const Color(0xff12abef);
        },
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            pageContext = context;
            return Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed:
                      () =>
                          fillFuture = actions.chooseFill(
                            const Offset(10, 20),
                            1,
                          ),
                  child: const Text('Start fill'),
                ),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('Start fill'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('fill-color-swatch')),
      findsOneWidget,
    );
    await tester.tap(find.text('Choose'));
    await tester.pumpAndSettle();
    expect(pickerInitialColor, const Color(0xff804020));
    await tester.tap(find.text('Fill'));
    await tester.pumpAndSettle();
    await fillFuture;

    expect(engine.fillColor, (0x12, 0xab, 0xef, 255));
    expect(dirty, isTrue);
    expect(refreshed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fill reports out-of-range values before dispatch', (
    tester,
  ) async {
    final engine = _RecordingFillEngine();
    BuildContext? pageContext;
    Future<void>? fillFuture;
    final actions = CanvasToolActions(
      CanvasToolActionHost(
        engine: () => engine,
        context: () => pageContext!,
        mounted: () => true,
        layers: () => const <LayerView>[],
        primaryLayerId: () => 1,
        activeTool: () => IllustrationTool.brush,
        setSelectionGeometryTool: (_) {},
        markDirty: () {},
        refreshTiles: () async {},
        activeColor: () => Colors.black,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            pageContext = context;
            return Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed:
                      () =>
                          fillFuture = actions.chooseFill(
                            const Offset(10, 20),
                            1,
                          ),
                  child: const Text('Start fill'),
                ),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('Start fill'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(3), '1021');
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Use RGB values from 0–255, tolerance from 0–1020, and gap from 0–4.',
      ),
      findsOneWidget,
    );
    final fillButton = find.ancestor(
      of: find.text('Fill'),
      matching: find.byType(FilledButton),
    );
    expect(tester.widget<FilledButton>(fillButton).onPressed, isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await fillFuture;

    expect(engine.fillColor, isNull);
  });

  testWidgets('canceling the fill leaves the document unchanged', (
    tester,
  ) async {
    final engine = _RecordingFillEngine();
    BuildContext? pageContext;
    Future<void>? fillFuture;
    var dirty = false;
    final actions = CanvasToolActions(
      CanvasToolActionHost(
        engine: () => engine,
        context: () => pageContext!,
        mounted: () => true,
        layers: () => const <LayerView>[],
        primaryLayerId: () => 1,
        activeTool: () => IllustrationTool.brush,
        setSelectionGeometryTool: (_) {},
        markDirty: () => dirty = true,
        refreshTiles: () async {},
        activeColor: () => const Color(0xff804020),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            pageContext = context;
            return Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed:
                      () =>
                          fillFuture = actions.chooseFill(
                            const Offset(10, 20),
                            1,
                          ),
                  child: const Text('Start fill'),
                ),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('Start fill'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await fillFuture;

    expect(engine.fillColor, isNull);
    expect(dirty, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'failed fill reports an error without marking the document dirty',
    (tester) async {
      final engine = _RecordingFillEngine()..failFillRegion = true;
      BuildContext? pageContext;
      Future<void>? fillFuture;
      final messages = <String>[];
      var dirty = false;
      var refreshed = false;
      final actions = CanvasToolActions(
        CanvasToolActionHost(
          engine: () => engine,
          context: () => pageContext!,
          mounted: () => true,
          layers: () => const <LayerView>[],
          primaryLayerId: () => 1,
          activeTool: () => IllustrationTool.brush,
          setSelectionGeometryTool: (_) {},
          markDirty: () => dirty = true,
          refreshTiles: () async => refreshed = true,
          activeColor: () => const Color(0xff804020),
          showMessage: messages.add,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              pageContext = context;
              return Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed:
                        () =>
                            fillFuture = actions.chooseFill(
                              const Offset(10, 20),
                              1,
                            ),
                    child: const Text('Start fill'),
                  ),
                ),
              );
            },
          ),
        ),
      );

      await tester.tap(find.text('Start fill'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fill'));
      await tester.pumpAndSettle();
      await fillFuture;

      expect(messages, [
        'The fill could not be applied. Check the selected layer and try again.',
      ]);
      expect(dirty, isFalse);
      expect(refreshed, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}

class _RecordingFillEngine extends InMemoryEngineApi {
  (int, int, int, int)? fillColor;
  bool failFillRegion = false;

  @override
  Future<void> fillRegion({
    required int layerId,
    required int x,
    required int y,
    required int red,
    required int green,
    required int blue,
    required int alpha,
    required int tolerance,
    required int gap,
  }) async {
    if (failFillRegion) throw StateError('simulated fill failure');
    fillColor = (red, green, blue, alpha);
    await super.fillRegion(
      layerId: layerId,
      x: x,
      y: y,
      red: red,
      green: green,
      blue: blue,
      alpha: alpha,
      tolerance: tolerance,
      gap: gap,
    );
  }
}
