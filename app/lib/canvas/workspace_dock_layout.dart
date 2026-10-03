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
    required this.tabletStudioMode,
    required this.tabletSimpleMode,
    required this.useNativeMacMenus,
  });

  final bool desktopDock;
  final bool showLeftDock;
  final bool showRightDock;
  final EffectiveDockWidths dockWidths;
  final bool tabletStudioMode;
  final bool tabletSimpleMode;
  final bool useNativeMacMenus;
}

/// Resolves whether the professional desktop dock fits the current host.
///
/// The route reads inherited logical/physical dimensions; this policy remains
/// pure so platform thresholds can be verified independently of widget media.
bool shouldUseWideDesktopLayout({
  required bool desktopDockEnabled,
  required WorkspaceMode workspaceMode,
  required TargetPlatform platform,
  required double logicalWidth,
  required double physicalWidth,
}) {
  if (!desktopDockEnabled || workspaceMode != WorkspaceMode.desktop) {
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
  required TabletWorkspaceMode tabletMode,
  required bool desktopDockEnabled,
}) {
  final desktopDock = wideDesktop && !interfaceHidden;
  final showLeftDock = desktopDock && !leftDockCollapsed && hasLeftDock;
  final showRightDock = desktopDock && !rightDockCollapsed && hasRightDock;
  final isTabletPlatform =
      platform == TargetPlatform.iOS || platform == TargetPlatform.android;
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
    tabletStudioMode:
        isTabletPlatform &&
        viewportWidth >= 600 &&
        tabletMode == TabletWorkspaceMode.studio,
    tabletSimpleMode:
        isTabletPlatform &&
        (viewportWidth < 600 || tabletMode == TabletWorkspaceMode.simple),
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
