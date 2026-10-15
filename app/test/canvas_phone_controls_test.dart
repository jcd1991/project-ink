import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/canvas/canvas_phone_controls.dart';
import 'package:project_ink/tools/brush_library.dart';

const _brush = BrushPresetView(
  id: 1,
  name: 'Round pen',
  family: BrushFamily.ink,
  size: 8,
  opacity: 0.72,
);

void main() {
  testWidgets('phone toolbar keeps primary panels one tap away', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var layersOpened = false;
    var colorOpened = false;
    await tester.pumpWidget(
      _host(
        onLayers: () => layersOpened = true,
        onMainColor: () => colorOpened = true,
      ),
    );

    expect(find.byTooltip('Layers'), findsOneWidget);
    expect(find.byTooltip('Color selector'), findsOneWidget);
    await tester.tap(find.byTooltip('Layers'));
    await tester.tap(find.byTooltip('Color selector'));
    expect(layersOpened, isTrue);
    expect(colorOpened, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('brush and eraser toggle is directly available', (tester) async {
    var eraserSelected = false;
    var brushSelected = false;
    await tester.pumpWidget(
      _host(
        onSelectEraser: () => eraserSelected = true,
        onSelectBrush: () => brushSelected = true,
      ),
    );

    expect(find.byTooltip('Switch to eraser'), findsOneWidget);
    await tester.tap(find.byTooltip('Switch to eraser'));
    expect(eraserSelected, isTrue);

    await tester.pumpWidget(
      _host(eraserActive: true, onSelectBrush: () => brushSelected = true),
    );
    expect(find.byTooltip('Switch to brush'), findsOneWidget);
    await tester.tap(find.byTooltip('Switch to brush'));
    expect(brushSelected, isTrue);
  });

  testWidgets('brush library has its own one-tap phone toolbar button', (
    tester,
  ) async {
    var brushesOpened = false;
    await tester.pumpWidget(_host(onBrushes: () => brushesOpened = true));

    await tester.tap(find.byTooltip('Brushes'));
    expect(brushesOpened, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('brush controls expose size and opacity together', (
    tester,
  ) async {
    await tester.pumpWidget(_host());

    await tester.tap(find.byTooltip('Brush controls'));
    await tester.pumpAndSettle();

    expect(find.text('Brush controls'), findsOneWidget);
    expect(find.text('Brush size'), findsOneWidget);
    expect(find.text('Brush opacity'), findsOneWidget);
    expect(find.byType(Slider), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('brush dynamics are reachable beside phone size and opacity', (
    tester,
  ) async {
    BrushEditorSection? selectedSection;
    await tester.pumpWidget(
      _host(onBrushEditorSection: (section) => selectedSection = section),
    );

    await tester.tap(find.byTooltip('Brush controls'));
    await tester.pumpAndSettle();
    expect(find.text('Smoothing 0% · Pulled string off'), findsOneWidget);
    await tester.ensureVisible(find.text('Pressure settings'));
    await tester.tap(find.text('Pressure settings'));
    await tester.pumpAndSettle();

    expect(selectedSection, BrushEditorSection.pressure);
    expect(tester.takeException(), isNull);
  });

  testWidgets('draw tools move into More on narrow phones', (tester) async {
    var toolsOpened = false;
    await tester.pumpWidget(
      _host(width: 320, onTools: () => toolsOpened = true),
    );

    await tester.tap(find.byTooltip('More drawing controls'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Draw tools'));
    expect(toolsOpened, isTrue);
    expect(find.byTooltip('Brushes'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Widget _host({
  double width = 360,
  bool eraserActive = false,
  VoidCallback? onBrushes,
  VoidCallback? onTools,
  VoidCallback? onSelectBrush,
  VoidCallback? onSelectEraser,
  VoidCallback? onLayers,
  VoidCallback? onMainColor,
  ValueChanged<BrushEditorSection>? onBrushEditorSection,
}) => MaterialApp(
  home: Scaffold(
    body: Align(
      alignment: Alignment.bottomCenter,
      child: SizedBox(
        width: width,
        height: 56,
        child: CanvasPhoneBottomControls(
          selectedBrush: _brush,
          eraserActive: eraserActive,
          onBrushChanged: (_) {},
          onBrushSizeChangeEnd: (_) {},
          onBrushOpacityChangeEnd: (_) {},
          onEyedropper: () {},
          onTools: onTools ?? () {},
          onBrushes: onBrushes ?? () {},
          onBrushEditorSection: onBrushEditorSection ?? (_) {},
          onSelectBrush: onSelectBrush ?? () {},
          onLayers: onLayers ?? () {},
          activeColor: Colors.black,
          subColor: Colors.white,
          transparentColorActive: false,
          onMainColor: onMainColor ?? () {},
          onTransparentColor: () {},
          onSelectEraser: onSelectEraser ?? () {},
        ),
      ),
    ),
  ),
);
