import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/canvas/canvas_color_palette_panel.dart';
import 'package:project_ink/canvas/canvas_compact_controls.dart';
import 'package:project_ink/tools/brush_library.dart';

void main() {
  const brush = BrushPresetView(
    id: 1,
    name: 'Opaque Round',
    family: BrushFamily.ink,
    size: 12,
    opacity: 0.75,
  );

  testWidgets('Simple drawing controls expose a single named color target', (
    tester,
  ) async {
    var colorOpened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 72,
              height: 620,
              child: CanvasSimpleEdgeControls(
                selectedBrush: brush,
                brushToolActive: true,
                eraserActive: false,
                onBrushChanged: (_) {},
                onBrushSizeChangeEnd: (_) {},
                onBrushOpacityChangeEnd: (_) {},
                onEyedropper: () {},
                onTools: () {},
                onBrushes: () {},
                onSelectBrush: () {},
                onLayers: () {},
                activeColor: Colors.black,
                subColor: Colors.white,
                transparentColorActive: false,
                onMainColor: () => colorOpened = true,
                onTransparentColor: () {},
                onSelectEraser: () {},
              ),
            ),
          ),
        ),
      ),
    );

    final colorTarget = find.bySemanticsLabel('Color selector');
    expect(colorTarget, findsOneWidget);
    expect(find.bySemanticsLabel('Sub color'), findsNothing);
    expect(tester.getSize(colorTarget).width, greaterThanOrEqualTo(48));
    expect(tester.getSize(colorTarget).height, greaterThanOrEqualTo(48));
    expect(find.bySemanticsLabel('Brush size'), findsOneWidget);

    await tester.tap(colorTarget);
    expect(colorOpened, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Simple tool buttons select tools and reopen active presets', (
    tester,
  ) async {
    var selectedBrush = false;
    var selectedEraser = false;
    var openedBrushes = 0;

    Future<void> showControls({
      required bool brushActive,
      required bool eraserActive,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 72,
              height: 620,
              child: CanvasSimpleEdgeControls(
                selectedBrush: brush,
                brushToolActive: brushActive,
                eraserActive: eraserActive,
                onBrushChanged: (_) {},
                onBrushSizeChangeEnd: (_) {},
                onBrushOpacityChangeEnd: (_) {},
                onEyedropper: () {},
                onTools: () {},
                onBrushes: () => openedBrushes++,
                onSelectBrush: () => selectedBrush = true,
                onLayers: () {},
                activeColor: Colors.black,
                subColor: Colors.white,
                transparentColorActive: false,
                onMainColor: () {},
                onTransparentColor: () {},
                onSelectEraser: () => selectedEraser = true,
              ),
            ),
          ),
        ),
      );
    }

    await showControls(brushActive: false, eraserActive: false);
    await tester.tap(find.bySemanticsLabel('Brush'));
    await tester.tap(find.bySemanticsLabel('Eraser'));
    expect(selectedBrush, isTrue);
    expect(selectedEraser, isTrue);

    await showControls(brushActive: true, eraserActive: false);
    await tester.tap(find.bySemanticsLabel('Brush presets'));
    await showControls(brushActive: false, eraserActive: true);
    await tester.tap(find.bySemanticsLabel('Eraser brush presets'));
    expect(openedBrushes, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Simple enlarged text opens a labeled brush size slider', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: SizedBox(
              width: 72,
              height: 620,
              child: CanvasSimpleEdgeControls(
                selectedBrush: brush,
                brushToolActive: true,
                eraserActive: false,
                onBrushChanged: (_) {},
                onBrushSizeChangeEnd: (_) {},
                onBrushOpacityChangeEnd: (_) {},
                onEyedropper: () {},
                onTools: () {},
                onBrushes: () {},
                onSelectBrush: () {},
                onLayers: () {},
                activeColor: Colors.black,
                subColor: Colors.white,
                transparentColorActive: false,
                onMainColor: () {},
                onTransparentColor: () {},
                onSelectEraser: () {},
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.bySemanticsLabel('Brush size'));
    await tester.pumpAndSettle();
    expect(find.text('Brush size'), findsOneWidget);
    expect(find.text('0.25 px to 512 px'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Compact phone rail moves brush sliders into adjustment sheets', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 56,
            height: 520,
            child: CanvasSimpleEdgeControls(
              selectedBrush: brush,
              brushToolActive: true,
              eraserActive: false,
              onBrushChanged: (_) {},
              onBrushSizeChangeEnd: (_) {},
              onBrushOpacityChangeEnd: (_) {},
              onEyedropper: () {},
              onTools: () {},
              onBrushes: () {},
              onSelectBrush: () {},
              onLayers: () {},
              activeColor: Colors.black,
              subColor: Colors.white,
              transparentColorActive: false,
              onMainColor: () {},
              onTransparentColor: () {},
              onSelectEraser: () {},
              compactPhone: true,
            ),
          ),
        ),
      ),
    );

    expect(find.byType(Slider), findsNothing);
    final sizeButton = find.bySemanticsLabel('Brush size');
    expect(sizeButton, findsOneWidget);
    expect(tester.getSize(sizeButton).width, greaterThanOrEqualTo(48));

    await tester.tap(sizeButton);
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsOneWidget);
    expect(find.text('0.25 px to 512 px'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Color palette names both roles and distinguishes transparency', (
    tester,
  ) async {
    Color? mainRecent;
    Color? subRecent;
    var subEditorOpened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CanvasColorPalettePanel(
            mainColor: Colors.black,
            subColor: Colors.white,
            recentColors: const ['#FF123456'],
            transparentColorActive: true,
            onChoose: () {},
            onChooseSub: () => subEditorOpened = true,
            onSelectRecent: (color) => mainRecent = color,
            onSelectRecentSub: (color) => subRecent = color,
            onSwap: () {},
            onReset: () {},
            onTransparent: () {},
          ),
        ),
      ),
    );

    final main = find.bySemanticsLabel('Main color #FF000000');
    final sub = find.bySemanticsLabel('Sub color #FFFFFFFF');
    expect(main, findsOneWidget);
    expect(sub, findsOneWidget);
    for (final target in [main, sub]) {
      expect(tester.getSize(target).width, greaterThanOrEqualTo(48));
      expect(tester.getSize(target).height, greaterThanOrEqualTo(48));
    }
    expect(find.text('Transparent active'), findsOneWidget);
    await tester.tap(find.byTooltip('Apply recent color #FF123456 to Main'));
    expect(mainRecent, const Color(0xFF123456));
    await tester.tap(sub);
    await tester.pump();
    expect(find.text('Recent colors apply to Sub.'), findsOneWidget);
    await tester.tap(find.byTooltip('Apply recent color #FF123456 to Sub'));
    expect(subRecent, const Color(0xFF123456));
    await tester.tap(find.byTooltip('Edit Sub color'));
    expect(subEditorOpened, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Studio short layout opens accessible slider sheets', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    BrushPresetView? lastBrush;
    double? persistedSize;
    double? persistedOpacity;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topRight,
            child: CanvasStudioDrawingControls(
              brush: brush,
              mainColor: Colors.black,
              subColor: Colors.white,
              onColor: () {},
              onBrushChanged: (value) => lastBrush = value,
              onSizeChangeEnd: (value) => persistedSize = value,
              onOpacityChangeEnd: (value) => persistedOpacity = value,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Brush size: 12.0 px'));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Brush size'), findsWidgets);
    expect(find.byType(Slider), findsOneWidget);
    await tester.drag(find.byType(Slider), const Offset(90, 0));
    await tester.pumpAndSettle();
    expect(lastBrush?.size, isNot(12));
    expect(persistedSize, isNotNull);
    await tester.tap(find.byTooltip('Close brush size'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Brush opacity: 75%'));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Brush opacity'), findsWidgets);
    expect(find.byType(Slider), findsOneWidget);
    await tester.drag(find.byType(Slider), const Offset(-60, 0));
    await tester.pumpAndSettle();
    expect(lastBrush?.opacity, isNot(0.75));
    expect(persistedOpacity, isNotNull);
    await tester.tap(find.byTooltip('Close brush opacity'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Studio normal layout keeps direct size and opacity sliders', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var sizeSaved = false;
    var opacitySaved = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topRight,
            child: CanvasStudioDrawingControls(
              brush: brush,
              mainColor: Colors.black,
              subColor: Colors.white,
              onColor: () {},
              onBrushChanged: (_) {},
              onSizeChangeEnd: (_) => sizeSaved = true,
              onOpacityChangeEnd: (_) => opacitySaved = true,
            ),
          ),
        ),
      ),
    );

    expect(find.byType(Slider), findsNWidgets(2));
    expect(find.bySemanticsLabel('Brush size'), findsOneWidget);
    expect(find.bySemanticsLabel('Brush opacity'), findsOneWidget);
    await tester.drag(find.byType(Slider).first, const Offset(0, -60));
    await tester.drag(find.byType(Slider).last, const Offset(0, -60));
    await tester.pumpAndSettle();
    expect(sizeSaved, isTrue);
    expect(opacitySaved, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Studio uses named controls with enlarged text', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(800, 800),
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(
            body: Align(
              alignment: Alignment.topRight,
              child: CanvasStudioDrawingControls(
                brush: brush,
                mainColor: Colors.black,
                subColor: Colors.white,
                onColor: () {},
                onBrushChanged: (_) {},
                onSizeChangeEnd: (_) {},
                onOpacityChangeEnd: (_) {},
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byTooltip('Brush size: 12.0 px'), findsOneWidget);
    expect(find.byTooltip('Brush opacity: 75%'), findsOneWidget);
    expect(find.byType(Slider), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
