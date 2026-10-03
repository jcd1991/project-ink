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

  void rememberTabletPalette(TabletWorkspaceMode mode) {
    final palette = _floatingPanels.lastVisiblePanel?.name;
    if (mode == TabletWorkspaceMode.simple) {
      _simpleLastPalette = palette;
    } else {
      _studioLastPalette = palette;
    }
  }

  /// Switches tablet presentation and restores the last palette for that mode.
  TabletWorkspaceMode toggleTabletMode(TabletWorkspaceMode currentMode) {
    rememberTabletPalette(currentMode);

    final nextMode =
        currentMode == TabletWorkspaceMode.simple
            ? TabletWorkspaceMode.studio
            : TabletWorkspaceMode.simple;
    final nextPalette =
        nextMode == TabletWorkspaceMode.studio
            ? (_studioLastPalette ?? 'layers')
            : _simpleLastPalette;
    _floatingPanels = _floatingPanels.only(
      CanvasFloatingPanelVisibility.fromName(nextPalette),
    );
    return nextMode;
  }
}
