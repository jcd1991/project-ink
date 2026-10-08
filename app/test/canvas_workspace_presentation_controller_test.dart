import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/app/workspace_preferences.dart';
import 'package:project_ink/canvas/canvas_floating_panel_visibility.dart';
import 'package:project_ink/canvas/canvas_workspace_presentation_controller.dart';

void main() {
  test('focus mode hides interface and closes the quick menu', () {
    final controller = CanvasWorkspacePresentationController();
    controller.toggleQuickMenu();

    controller.toggleFocusMode();

    expect(controller.interfaceHidden, isTrue);
    expect(controller.quickMenuVisible, isFalse);
  });

  test('exiting focus mode preserves floating panels', () {
    final controller = CanvasWorkspacePresentationController();
    controller.setFloatingPanels(
      const CanvasFloatingPanelVisibility(brushes: true),
    );
    controller.toggleFocusMode();

    controller.exitFocusMode();

    expect(controller.interfaceHidden, isFalse);
    expect(controller.floatingPanels.brushes, isTrue);
  });

  test('closing panels clears floating panels and quick menu', () {
    final controller = CanvasWorkspacePresentationController();
    controller.setFloatingPanels(
      const CanvasFloatingPanelVisibility(tools: true, comics: true),
    );
    controller.toggleQuickMenu();

    controller.closePanels();

    expect(controller.floatingPanels.tools, isFalse);
    expect(controller.floatingPanels.comics, isFalse);
    expect(controller.quickMenuVisible, isFalse);
  });

  test('tablet mode switches restore each mode last floating palette', () {
    final controller = CanvasWorkspacePresentationController();
    controller.setFloatingPanels(
      const CanvasFloatingPanelVisibility(tools: true),
    );

    expect(controller.toggleEditorMode(EditorMode.simple), EditorMode.studio);
    expect(controller.floatingPanels.layers, isTrue);

    controller.setFloatingPanels(
      const CanvasFloatingPanelVisibility(comics: true),
    );
    expect(controller.toggleEditorMode(EditorMode.studio), EditorMode.simple);
    expect(controller.floatingPanels.tools, isTrue);

    expect(controller.toggleEditorMode(EditorMode.simple), EditorMode.studio);
    expect(controller.floatingPanels.comics, isTrue);
  });
}
