import 'package:flutter/foundation.dart';

import '../app/editor_action.dart';
import 'canvas_workspace_panel_selection.dart';

/// Ordered feature owners and UI effects for a shared editor command.
class CanvasEditorActionRouterHost {
  const CanvasEditorActionRouterHost({
    required this.isMounted,
    required this.isAdjustmentEditActive,
    required this.dispatchDocumentAction,
    required this.dispatchHistoryAction,
    required this.dispatchToolAction,
    required this.dispatchBrushColorAction,
    required this.viewportAction,
    required this.applyStateAction,
    required this.selectPanel,
    required this.toggleEraser,
    required this.fitCanvas,
    required this.toggleInterface,
    required this.showColorPicker,
    required this.armColorSampler,
    required this.toggleQuickMenu,
    required this.showCommandSearch,
  });

  final bool Function() isMounted;
  final bool Function() isAdjustmentEditActive;
  final bool Function(EditorActionId action) dispatchDocumentAction;
  final bool Function(EditorActionId action) dispatchHistoryAction;
  final bool Function(EditorActionId action) dispatchToolAction;
  final bool Function(EditorActionId action) dispatchBrushColorAction;
  final VoidCallback? Function(EditorActionId action) viewportAction;
  final void Function(VoidCallback action) applyStateAction;
  final ValueChanged<String> selectPanel;
  final VoidCallback toggleEraser;
  final VoidCallback fitCanvas;
  final VoidCallback toggleInterface;
  final VoidCallback showColorPicker;
  final VoidCallback armColorSampler;
  final VoidCallback toggleQuickMenu;
  final VoidCallback showCommandSearch;
}

/// Routes shared command IDs to their authoritative feature owner.
///
/// Owner order is intentional: document and history commands take precedence
/// over tool, color, viewport, and presentation fallbacks.
class CanvasEditorActionRouter {
  const CanvasEditorActionRouter(this.host);

  final CanvasEditorActionRouterHost host;

  void dispatch(EditorActionId action) {
    if (!host.isMounted() || host.isAdjustmentEditActive()) return;
    if (host.dispatchDocumentAction(action)) return;
    if (host.dispatchHistoryAction(action)) return;
    if (host.dispatchToolAction(action)) return;
    if (host.dispatchBrushColorAction(action)) return;

    final viewportAction = host.viewportAction(action);
    if (viewportAction != null) {
      host.applyStateAction(viewportAction);
      return;
    }

    final panel = canvasWorkspacePanelForAction(action);
    if (panel != null) {
      host.selectPanel(panel);
      return;
    }

    switch (action) {
      case EditorActionId.toggleEraser:
        host.toggleEraser();
      case EditorActionId.fitCanvas:
        host.fitCanvas();
      case EditorActionId.toggleInterface:
        host.toggleInterface();
      case EditorActionId.showColorPicker:
        host.showColorPicker();
      case EditorActionId.eyedropper:
        host.armColorSampler();
      case EditorActionId.quickMenu:
        host.toggleQuickMenu();
      case EditorActionId.commandSearch:
        host.showCommandSearch();
      default:
        return;
    }
  }
}
