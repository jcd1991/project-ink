import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/canvas/canvas_editor_auxiliary_overlays.dart';
import 'package:project_ink/tools/brush_library.dart';
import 'package:project_ink/tools/illustration_tools.dart';

void main() {
  testWidgets('focus controls remain available when the interface is hidden', (
    tester,
  ) async {
    var focusControlsOpened = false;
    await tester.pumpWidget(
      _harness(
        snapshot: _snapshot(interfaceHidden: true),
        actions: _actions(
          onShowFocusControls: () => focusControlsOpened = true,
        ),
      ),
    );

    expect(find.byTooltip('Focus controls'), findsOneWidget);
    expect(find.text('Selection'), findsNothing);
    await tester.tap(find.byTooltip('Focus controls'));
    expect(focusControlsOpened, isTrue);
  });

  testWidgets('selection and quick-menu actions use the supplied callbacks', (
    tester,
  ) async {
    var deselected = false;
    var fitRequested = false;
    await tester.pumpWidget(
      _harness(
        snapshot: _snapshot(hasSelection: true, quickMenuVisible: true),
        actions: _actions(
          onDeselect: () => deselected = true,
          onFitCanvas: () => fitRequested = true,
        ),
      ),
    );

    expect(find.text('Selection'), findsOneWidget);
    await tester.tap(find.byTooltip('Deselect'));
    await tester.tap(find.byTooltip('Fit canvas'));
    expect(deselected, isTrue);
    expect(fitRequested, isTrue);
  });

  testWidgets('Studio exposes labeled drawing controls and palette routes', (
    tester,
  ) async {
    final selectedPanels = <String>[];
    await tester.pumpWidget(
      _harness(
        snapshot: _snapshot(tabletStudioMode: true),
        actions: _actions(onSelectPanel: selectedPanels.add),
      ),
    );

    for (final label in [
      'Draw tools',
      'Brush presets',
      'Eraser',
      'Layers',
      'Comics',
      'Tool properties',
      'Materials',
      'History',
      'Quick Access',
    ]) {
      expect(find.byTooltip(label), findsOneWidget, reason: label);
    }

    expect(find.byTooltip('Color: Main #FF000000'), findsOneWidget);
    expect(find.bySemanticsLabel('Brush size'), findsOneWidget);
    expect(find.bySemanticsLabel('Brush opacity'), findsOneWidget);
    expect(tester.getSize(find.byTooltip('Color: Main #FF000000')).width, 72);
    expect(tester.getSize(find.byTooltip('Color: Main #FF000000')).height, 68);
    await tester.tap(find.byTooltip('Tool properties'));
    await tester.tap(find.byTooltip('Materials'));
    expect(selectedPanels, ['properties', 'materials']);
  });
}

Widget _harness({
  required CanvasEditorAuxiliaryOverlaySnapshot snapshot,
  required CanvasEditorAuxiliaryOverlayActions actions,
}) => MaterialApp(
  home: Scaffold(
    body: SizedBox.expand(
      child: CanvasEditorAuxiliaryOverlays(
        snapshot: snapshot,
        actions: actions,
      ),
    ),
  ),
);

CanvasEditorAuxiliaryOverlaySnapshot _snapshot({
  bool interfaceHidden = false,
  bool tabletStudioMode = false,
  bool hasSelection = false,
  bool desktopDock = false,
  bool showLeftDock = false,
  bool showRightDock = false,
  bool quickMenuVisible = false,
  bool leftHanded = false,
}) => CanvasEditorAuxiliaryOverlaySnapshot(
  interfaceHidden: interfaceHidden,
  tabletStudioMode: tabletStudioMode,
  leftHanded: leftHanded,
  hasSelection: hasSelection,
  desktopDock: desktopDock,
  showLeftDock: showLeftDock,
  showRightDock: showRightDock,
  quickMenuVisible: quickMenuVisible,
  safeAreaTop: 0,
  leftDockWidth: 280,
  rightDockWidth: 320,
  activeTool: IllustrationTool.brush,
  eraserActive: false,
  brush: null,
  color: Colors.black,
  subColor: Colors.white,
);

CanvasEditorAuxiliaryOverlayActions _actions({
  VoidCallback onShowFocusControls = _noop,
  VoidCallback onExitFocus = _noop,
  ValueChanged<String> onSelectPanel = _ignoreString,
  VoidCallback onToggleEraser = _noop,
  VoidCallback onDeselect = _noop,
  VoidCallback onInvertSelection = _noop,
  VoidCallback onGrowSelection = _noop,
  VoidCallback onShrinkSelection = _noop,
  VoidCallback onToggleQuickEraser = _noop,
  VoidCallback onFitCanvas = _noop,
  VoidCallback onShowBrushes = _noop,
  ValueChanged<double> onQuickBrushSizeChanged = _ignoreDouble,
  ValueChanged<double> onQuickBrushSizeChangeEnd = _ignoreDouble,
  VoidCallback onShowBrushColor = _noop,
  ValueChanged<BrushPresetView> onBrushChanged = _ignoreBrush,
  ValueChanged<double> onBrushSizeChangeEnd = _ignoreDouble,
  ValueChanged<double> onBrushOpacityChangeEnd = _ignoreDouble,
  VoidCallback onCloseQuickMenu = _noop,
}) => CanvasEditorAuxiliaryOverlayActions(
  onShowFocusControls: onShowFocusControls,
  onExitFocus: onExitFocus,
  onSelectPanel: onSelectPanel,
  onToggleEraser: onToggleEraser,
  onDeselect: onDeselect,
  onInvertSelection: onInvertSelection,
  onGrowSelection: onGrowSelection,
  onShrinkSelection: onShrinkSelection,
  onToggleQuickEraser: onToggleQuickEraser,
  onFitCanvas: onFitCanvas,
  onShowBrushes: onShowBrushes,
  onQuickBrushSizeChanged: onQuickBrushSizeChanged,
  onQuickBrushSizeChangeEnd: onQuickBrushSizeChangeEnd,
  onShowBrushColor: onShowBrushColor,
  onBrushChanged: onBrushChanged,
  onBrushSizeChangeEnd: onBrushSizeChangeEnd,
  onBrushOpacityChangeEnd: onBrushOpacityChangeEnd,
  onCloseQuickMenu: onCloseQuickMenu,
);

void _noop() {}

void _ignoreString(String _) {}

void _ignoreDouble(double _) {}

void _ignoreBrush(BrushPresetView _) {}
