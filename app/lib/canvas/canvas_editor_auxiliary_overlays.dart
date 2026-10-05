import 'package:flutter/material.dart';

import '../tools/brush_library.dart';
import '../tools/illustration_tools.dart';
import 'canvas_compact_controls.dart';
import 'canvas_status_widgets.dart';
import 'canvas_tool_rails.dart';

/// Immutable values needed to compose canvas controls above the drawing area.
class CanvasEditorAuxiliaryOverlaySnapshot {
  const CanvasEditorAuxiliaryOverlaySnapshot({
    required this.interfaceHidden,
    required this.tabletStudioMode,
    required this.leftHanded,
    required this.hasSelection,
    required this.desktopDock,
    required this.showLeftDock,
    required this.showRightDock,
    required this.quickMenuVisible,
    required this.safeAreaTop,
    required this.leftDockWidth,
    required this.rightDockWidth,
    required this.activeTool,
    required this.eraserActive,
    required this.brush,
    required this.color,
    required this.subColor,
  });

  final bool interfaceHidden;
  final bool tabletStudioMode;
  final bool leftHanded;
  final bool hasSelection;
  final bool desktopDock;
  final bool showLeftDock;
  final bool showRightDock;
  final bool quickMenuVisible;
  final double safeAreaTop;
  final double leftDockWidth;
  final double rightDockWidth;
  final IllustrationTool activeTool;
  final bool eraserActive;
  final BrushPresetView? brush;
  final Color color;
  final Color subColor;
}

/// User actions available to the auxiliary canvas controls.
class CanvasEditorAuxiliaryOverlayActions {
  const CanvasEditorAuxiliaryOverlayActions({
    required this.onShowFocusControls,
    required this.onExitFocus,
    required this.onSelectPanel,
    required this.onToggleEraser,
    required this.onDeselect,
    required this.onInvertSelection,
    required this.onGrowSelection,
    required this.onShrinkSelection,
    required this.onToggleQuickEraser,
    required this.onFitCanvas,
    required this.onShowBrushes,
    required this.onQuickBrushSizeChanged,
    required this.onQuickBrushSizeChangeEnd,
    required this.onShowBrushColor,
    required this.onBrushChanged,
    required this.onBrushSizeChangeEnd,
    required this.onBrushOpacityChangeEnd,
    required this.onCloseQuickMenu,
  });

  final VoidCallback onShowFocusControls;
  final VoidCallback onExitFocus;
  final ValueChanged<String> onSelectPanel;
  final VoidCallback onToggleEraser;
  final VoidCallback onDeselect;
  final VoidCallback onInvertSelection;
  final VoidCallback onGrowSelection;
  final VoidCallback onShrinkSelection;
  final VoidCallback onToggleQuickEraser;
  final VoidCallback onFitCanvas;
  final VoidCallback onShowBrushes;
  final ValueChanged<double> onQuickBrushSizeChanged;
  final ValueChanged<double> onQuickBrushSizeChangeEnd;
  final VoidCallback onShowBrushColor;
  final ValueChanged<BrushPresetView> onBrushChanged;
  final ValueChanged<double> onBrushSizeChangeEnd;
  final ValueChanged<double> onBrushOpacityChangeEnd;
  final VoidCallback onCloseQuickMenu;
}

/// Composes the controls that float above the canvas viewport.
class CanvasEditorAuxiliaryOverlays extends StatelessWidget {
  const CanvasEditorAuxiliaryOverlays({
    super.key,
    required this.snapshot,
    required this.actions,
  });

  final CanvasEditorAuxiliaryOverlaySnapshot snapshot;
  final CanvasEditorAuxiliaryOverlayActions actions;

  @override
  Widget build(BuildContext context) {
    final state = snapshot;
    final callbacks = actions;
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        if (state.interfaceHidden)
          Positioned(
            top: state.safeAreaTop + 8,
            right: 8,
            child: SafeArea(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton.filledTonal(
                    tooltip: 'Focus controls',
                    onPressed: callbacks.onShowFocusControls,
                    icon: const Icon(Icons.tune),
                  ),
                  const SizedBox(width: 4),
                  IconButton.filledTonal(
                    tooltip: 'Exit Focus',
                    onPressed: callbacks.onExitFocus,
                    icon: const Icon(Icons.fullscreen_exit),
                  ),
                ],
              ),
            ),
          ),
        if (!state.interfaceHidden && state.tabletStudioMode)
          Positioned(
            left: state.leftHanded ? null : 0,
            right: state.leftHanded ? 0 : null,
            top: state.safeAreaTop + 52,
            bottom: MediaQuery.paddingOf(context).bottom + 8,
            width: 48,
            child: TabletStudioToolRail(
              activeTool: state.activeTool,
              eraserActive: state.eraserActive,
              onTools: () => callbacks.onSelectPanel('tools'),
              onBrushes: () => callbacks.onSelectPanel('brushes'),
              onEraser: callbacks.onToggleEraser,
              onLayers: () => callbacks.onSelectPanel('layers'),
              onComics: () => callbacks.onSelectPanel('comics'),
              onProperties: () => callbacks.onSelectPanel('properties'),
              onMaterials: () => callbacks.onSelectPanel('materials'),
              onHistory: () => callbacks.onSelectPanel('history'),
              onQuickAccess: () => callbacks.onSelectPanel('quickAccess'),
              leftHanded: state.leftHanded,
            ),
          ),
        if (!state.interfaceHidden && state.tabletStudioMode)
          Positioned(
            left: state.leftHanded ? 0 : null,
            right: state.leftHanded ? null : 0,
            top: state.safeAreaTop + 52,
            child: CanvasStudioDrawingControls(
              brush: state.brush,
              mainColor: state.color,
              subColor: state.subColor,
              onColor: callbacks.onShowBrushColor,
              onBrushChanged: callbacks.onBrushChanged,
              onSizeChangeEnd: callbacks.onBrushSizeChangeEnd,
              onOpacityChangeEnd: callbacks.onBrushOpacityChangeEnd,
            ),
          ),
        if (!state.interfaceHidden && state.hasSelection)
          Positioned(
            left: state.desktopDock ? 56 + state.leftDockWidth : 12,
            top: state.desktopDock ? 84 : state.safeAreaTop + 64,
            right: state.desktopDock ? state.rightDockWidth + 12 : 12,
            child: CanvasSelectionLauncher(
              onDeselect: callbacks.onDeselect,
              onInvert: callbacks.onInvertSelection,
              onGrow: callbacks.onGrowSelection,
              onShrink: callbacks.onShrinkSelection,
            ),
          ),
        if (!state.interfaceHidden &&
            state.desktopDock &&
            (state.showLeftDock || state.showRightDock))
          Positioned(
            left: 0,
            top: 36,
            bottom: 24,
            width: 44,
            child: DesktopToolRail(
              activeTool: state.activeTool,
              onTools: () => callbacks.onSelectPanel('tools'),
              onBrushes: () => callbacks.onSelectPanel('brushes'),
              onLayers: () => callbacks.onSelectPanel('layers'),
              onEraser: callbacks.onToggleEraser,
              eraserActive: state.eraserActive,
            ),
          ),
        if (!state.interfaceHidden && state.quickMenuVisible)
          CanvasQuickMenu(
            eraserActive: state.eraserActive,
            brush: state.brush,
            color: state.color,
            onToggleEraser: callbacks.onToggleQuickEraser,
            onFitCanvas: callbacks.onFitCanvas,
            onBrushes: callbacks.onShowBrushes,
            onBrushSizeChanged: callbacks.onQuickBrushSizeChanged,
            onBrushSizeChangeEnd: callbacks.onQuickBrushSizeChangeEnd,
            onColor: callbacks.onShowBrushColor,
            onClose: callbacks.onCloseQuickMenu,
          ),
      ],
    );
  }
}
