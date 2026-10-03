import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/canvas/canvas_floating_panel_visibility.dart';

void main() {
  test('compact panels toggle independently', () {
    const initial = CanvasFloatingPanelVisibility();
    final toolsOpen = initial.toggle(CanvasFloatingPanel.tools);
    final layersOpen = toolsOpen.toggle(CanvasFloatingPanel.layers);
    final toolsClosed = layersOpen.toggle(CanvasFloatingPanel.tools);

    expect(toolsOpen.tools, isTrue);
    expect(layersOpen.tools, isTrue);
    expect(layersOpen.layers, isTrue);
    expect(toolsClosed.tools, isFalse);
    expect(toolsClosed.layers, isTrue);
  });

  test(
    'studio selection opens one panel and closes it when selected again',
    () {
      const initial = CanvasFloatingPanelVisibility();
      final toolsOpen = initial.toggleExclusive(CanvasFloatingPanel.tools);
      final layersOpen = toolsOpen.toggleExclusive(CanvasFloatingPanel.layers);
      final allClosed = layersOpen.toggleExclusive(CanvasFloatingPanel.layers);

      expect(toolsOpen.tools, isTrue);
      expect(layersOpen.tools, isFalse);
      expect(layersOpen.layers, isTrue);
      expect(allClosed.lastVisiblePanel, isNull);
    },
  );

  test('remembers the current palette using workspace selection order', () {
    const panels = CanvasFloatingPanelVisibility(brushes: true, layers: true);

    expect(panels.lastVisiblePanel, CanvasFloatingPanel.brushes);
    expect(
      CanvasFloatingPanelVisibility.fromName('comics'),
      CanvasFloatingPanel.comics,
    );
    expect(CanvasFloatingPanelVisibility.fromName('history'), isNull);
  });
}
