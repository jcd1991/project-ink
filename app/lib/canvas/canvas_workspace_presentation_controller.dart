import 'canvas_floating_panel_visibility.dart';
import '../app/workspace_preferences.dart';

/// Owns transient canvas chrome state shared by the route's presentation
/// regions: floating panels, quick menu, and focus mode.
class CanvasWorkspacePresentationController {
  bool _interfaceHidden = false;
  bool _quickMenuVisible = false;
  String? _simpleLastPalette;
  String? _studioLastPalette;
  CanvasFloatingPanelVisibility _floatingPanels =
      const CanvasFloatingPanelVisibility();

  bool get interfaceHidden => _interfaceHidden;
  bool get quickMenuVisible => _quickMenuVisible;
  CanvasFloatingPanelVisibility get floatingPanels => _floatingPanels;

  void toggleQuickMenu() => _quickMenuVisible = !_quickMenuVisible;

  void closeQuickMenu() => _quickMenuVisible = false;

  void setFloatingPanels(CanvasFloatingPanelVisibility visibility) {
    _floatingPanels = visibility;
  }

  void toggleFocusMode() {
    _interfaceHidden = !_interfaceHidden;
    if (_interfaceHidden) _quickMenuVisible = false;
  }

  void exitFocusMode() => _interfaceHidden = false;

  void closePanels() {
    _floatingPanels = const CanvasFloatingPanelVisibility();
    _quickMenuVisible = false;
  }

  void rememberStudioPalette(EditorMode mode) {
    final palette = _floatingPanels.lastVisiblePanel?.name;
    if (mode == EditorMode.simple) {
      _simpleLastPalette = palette;
    } else {
      _studioLastPalette = palette;
    }
  }

  /// Switches editor mode and restores that mode's last palette.
  EditorMode toggleEditorMode(EditorMode currentMode) {
    rememberStudioPalette(currentMode);

    final nextMode =
        currentMode == EditorMode.simple
            ? EditorMode.studio
            : EditorMode.simple;
    final nextPalette =
        nextMode == EditorMode.studio
            ? (_studioLastPalette ?? 'layers')
            : _simpleLastPalette;
    _floatingPanels = _floatingPanels.only(
      CanvasFloatingPanelVisibility.fromName(nextPalette),
    );
    return nextMode;
  }
}
