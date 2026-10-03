import 'package:flutter/material.dart';

import 'canvas_compact_controls.dart';
import 'canvas_floating_panel_visibility.dart';

/// Describes one floating editor panel without transferring its state owner.
@immutable
class CanvasWorkspaceOverlay {
  const CanvasWorkspaceOverlay({
    required this.title,
    required this.visible,
    required this.onClose,
    required this.child,
    this.rightAligned = false,
    this.semanticsLabel,
    required this.width,
    required this.studioWidth,
  });

  final String title;
  final bool visible;
  final VoidCallback onClose;
  final Widget child;
  final bool rightAligned;
  final String? semanticsLabel;
  final double width;
  final double studioWidth;
}

/// Places tool panels around the canvas for compact and tablet layouts.
///
/// The caller owns panel visibility and child lifecycles; this widget only
/// applies the common placement and docking presentation.
class CanvasWorkspaceOverlays extends StatelessWidget {
  const CanvasWorkspaceOverlays({
    required this.overlays,
    required this.interfaceHidden,
    required this.desktopDock,
    required this.tabletStudioMode,
    required this.safeAreaTop,
    super.key,
  });

  final List<CanvasWorkspaceOverlay> overlays;
  final bool interfaceHidden;
  final bool desktopDock;
  final bool tabletStudioMode;
  final double safeAreaTop;

  @override
  Widget build(BuildContext context) {
    final canShowPanels = !interfaceHidden && !desktopDock;
    final studioOffset = tabletStudioMode ? 60.0 : 72.0;
    final top = safeAreaTop + studioOffset;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (canShowPanels)
          for (final overlay in overlays)
            if (overlay.visible)
              Positioned(
                left:
                    overlay.rightAligned ? null : (tabletStudioMode ? 56 : 12),
                right:
                    overlay.rightAligned ? (tabletStudioMode ? 8 : 12) : null,
                top: top,
                bottom: 12,
                width: tabletStudioMode ? overlay.studioWidth : overlay.width,
                child: _buildPanel(overlay),
              ),
      ],
    );
  }

  Widget _buildPanel(CanvasWorkspaceOverlay overlay) {
    final panel = CanvasToolPanel(
      key: ValueKey('canvas-workspace-overlay-${overlay.title}'),
      title: overlay.title,
      docked: tabletStudioMode,
      onClose: overlay.onClose,
      child: overlay.child,
    );
    if (overlay.semanticsLabel == null) return panel;
    return Semantics(
      container: true,
      label: overlay.semanticsLabel,
      child: panel,
    );
  }
}

/// Builds the four canvas-owned floating panels from a visibility snapshot.
///
/// The route remains the owner of visibility state and supplies its publication
/// callback. This widget owns the panel titles, widths, alignment, semantics,
/// and close-to-visibility transitions.
class CanvasFloatingWorkspacePanels extends StatelessWidget {
  const CanvasFloatingWorkspacePanels({
    super.key,
    required this.visibility,
    required this.onVisibilityChanged,
    required this.interfaceHidden,
    required this.desktopDock,
    required this.tabletStudioMode,
    required this.safeAreaTop,
    required this.tools,
    required this.brushes,
    required this.layers,
    required this.comics,
  });

  final CanvasFloatingPanelVisibility visibility;
  final ValueChanged<CanvasFloatingPanelVisibility> onVisibilityChanged;
  final bool interfaceHidden;
  final bool desktopDock;
  final bool tabletStudioMode;
  final double safeAreaTop;
  final Widget tools;
  final Widget brushes;
  final Widget layers;
  final Widget comics;

  void _close(CanvasFloatingPanel panel) {
    onVisibilityChanged(visibility.setVisible(panel, false));
  }

  @override
  Widget build(BuildContext context) => CanvasWorkspaceOverlays(
    interfaceHidden: interfaceHidden,
    desktopDock: desktopDock,
    tabletStudioMode: tabletStudioMode,
    safeAreaTop: safeAreaTop,
    overlays: [
      CanvasWorkspaceOverlay(
        title: 'Illustration tools',
        visible: visibility.tools,
        width: 280,
        studioWidth: 320,
        onClose: () => _close(CanvasFloatingPanel.tools),
        child: tools,
      ),
      CanvasWorkspaceOverlay(
        title: 'Brush library',
        visible: visibility.brushes,
        width: 300,
        studioWidth: 320,
        onClose: () => _close(CanvasFloatingPanel.brushes),
        child: brushes,
      ),
      CanvasWorkspaceOverlay(
        title: 'Layers',
        visible: visibility.layers,
        width: 280,
        studioWidth: 360,
        rightAligned: true,
        semanticsLabel: tabletStudioMode ? 'Studio palette dock' : 'Layers',
        onClose: () => _close(CanvasFloatingPanel.layers),
        child: layers,
      ),
      CanvasWorkspaceOverlay(
        title: 'Comic workspace',
        visible: visibility.comics,
        width: 360,
        studioWidth: 360,
        rightAligned: true,
        onClose: () => _close(CanvasFloatingPanel.comics),
        child: comics,
      ),
    ],
  );
}
