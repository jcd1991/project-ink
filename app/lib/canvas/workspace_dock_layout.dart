import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../app/workspace_mode.dart';
import '../app/workspace_preferences.dart';

/// Widths actually used by the desktop workspace after reserving enough room
/// for the canvas. Persisted preferred widths are not rewritten when a window
/// is temporarily narrow; they become active again when space is available.
class EffectiveDockWidths {
  const EffectiveDockWidths({required this.left, required this.right});

  final double left;
  final double right;
}

/// Presentation decisions for the canvas workspace at one layout frame.
///
/// This is a projection only: persisted preferences and live screen state stay
/// owned by their existing controllers. [wideDesktop] is resolved by the
/// screen because it depends on inherited media and platform mode overrides.
class CanvasWorkspaceFrame {
  const CanvasWorkspaceFrame({
    required this.desktopDock,
    required this.showLeftDock,
    required this.showRightDock,
    required this.dockWidths,
    required this.studioTouchLayout,
    required this.simpleMode,
    required this.simpleTouchLayout,
    required this.phoneLayout,
    required this.useNativeMacMenus,
  });

  final bool desktopDock;
  final bool showLeftDock;
  final bool showRightDock;
  final EffectiveDockWidths dockWidths;
  final bool studioTouchLayout;
  final bool simpleMode;
  final bool simpleTouchLayout;
  final bool phoneLayout;
  final bool useNativeMacMenus;
}

/// Resolves whether the professional desktop dock fits the current host.
///
/// The route reads inherited logical/physical dimensions; this policy remains
/// pure so platform thresholds can be verified independently of widget media.
bool shouldUseWideDesktopLayout({
  required bool desktopDockEnabled,
  required CanvasLayoutMode layoutMode,
  required TargetPlatform platform,
  required double logicalWidth,
  required double physicalWidth,
}) {
  if (!desktopDockEnabled || layoutMode != CanvasLayoutMode.desktop) {
    return false;
  }
  if (platform == TargetPlatform.macOS) {
    return logicalWidth >= 1024 && physicalWidth >= 1200;
  }
  return (platform == TargetPlatform.windows ||
          platform == TargetPlatform.linux) &&
      logicalWidth >= 1100;
}

/// Resolves workspace presentation from explicit, immutable frame inputs.
CanvasWorkspaceFrame resolveCanvasWorkspaceFrame({
  required TargetPlatform platform,
  required double viewportWidth,
  required bool wideDesktop,
  required bool interfaceHidden,
  required bool leftDockCollapsed,
  required bool rightDockCollapsed,
  required bool hasLeftDock,
  required bool hasRightDock,
  required double preferredLeftDockWidth,
  required double preferredRightDockWidth,
  required EditorMode editorMode,
  required bool desktopDockEnabled,
  bool isWeb = false,
}) {
  final studioMode = editorMode == EditorMode.studio;
  final simpleMode = editorMode == EditorMode.simple;
  final touchPlatform =
      platform == TargetPlatform.iOS || platform == TargetPlatform.android;
  final touchHost = touchPlatform || isWeb;
  final phoneLayout = viewportWidth < 600 && touchHost;
  final desktopDock = wideDesktop && !interfaceHidden;
  final showLeftDock = desktopDock && !leftDockCollapsed && hasLeftDock;
  final showRightDock = desktopDock && !rightDockCollapsed && hasRightDock;
  final studioTouchLayout =
      studioMode &&
      !phoneLayout &&
      !desktopDock &&
      (touchPlatform || (isWeb && viewportWidth < 1100));
  final simpleTouchLayout =
      simpleMode &&
      !phoneLayout &&
      !desktopDock &&
      (touchPlatform || (isWeb && viewportWidth < 1100));
  return CanvasWorkspaceFrame(
    desktopDock: desktopDock,
    showLeftDock: showLeftDock,
    showRightDock: showRightDock,
    dockWidths: effectiveDockWidths(
      viewportWidth: viewportWidth,
      showLeftDock: showLeftDock,
      showRightDock: showRightDock,
      preferredLeftWidth: preferredLeftDockWidth,
      preferredRightWidth: preferredRightDockWidth,
    ),
    studioTouchLayout: studioTouchLayout,
    simpleMode: simpleMode,
    simpleTouchLayout: simpleTouchLayout,
    phoneLayout: phoneLayout,
    useNativeMacMenus: platform == TargetPlatform.macOS && desktopDockEnabled,
  );
}

EffectiveDockWidths effectiveDockWidths({
  required double viewportWidth,
  required bool showLeftDock,
  required bool showRightDock,
  required double preferredLeftWidth,
  required double preferredRightWidth,
  double minimumCanvasWidth = 400,
  double toolRailWidth = 44,
  double minimumDockWidth = 220,
  double maximumDockWidth = 480,
}) {
  final left =
      showLeftDock
          ? _boundedWidth(
            preferredLeftWidth,
            minimumDockWidth,
            maximumDockWidth,
          )
          : 0.0;
  final right =
      showRightDock
          ? _boundedWidth(
            preferredRightWidth,
            minimumDockWidth,
            maximumDockWidth,
          )
          : 0.0;
  if (!viewportWidth.isFinite || viewportWidth <= 0) {
    return EffectiveDockWidths(left: left, right: right);
  }

  final dockBudget = math.max(
    0.0,
    viewportWidth - toolRailWidth - minimumCanvasWidth,
  );
  final total = left + right;
  if (total <= dockBudget) {
    return EffectiveDockWidths(left: left, right: right);
  }

  final leftCapacity = math.max(0.0, left - minimumDockWidth);
  final rightCapacity = math.max(0.0, right - minimumDockWidth);
  final totalCapacity = leftCapacity + rightCapacity;
  if (totalCapacity == 0) {
    return EffectiveDockWidths(left: left, right: right);
  }

  final reduction = total - dockBudget;
  final reducible = math.min(reduction, totalCapacity);
  final leftReduction = reducible * leftCapacity / totalCapacity;
  final rightReduction = reducible - leftReduction;
  return EffectiveDockWidths(
    left: showLeftDock ? math.max(minimumDockWidth, left - leftReduction) : 0,
    right:
        showRightDock ? math.max(minimumDockWidth, right - rightReduction) : 0,
  );
}

double _boundedWidth(double width, double minimum, double maximum) =>
    (width.isFinite ? width : minimum).clamp(minimum, maximum).toDouble();
