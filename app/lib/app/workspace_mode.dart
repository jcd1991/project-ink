import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Responsive canvas shell selected from the host and viewport.
///
/// This is separate from the Simple/Studio editor mode and the chosen
/// workspace layout preset. It never changes document state.
enum CanvasLayoutMode { compactTouch, expandedTouch, desktop }

CanvasLayoutMode resolveCanvasLayoutMode(
  BuildContext context, {
  CanvasLayoutMode? override,
  bool desktopDockEnabled = false,
  TargetPlatform? targetPlatform,
}) {
  if (override != null) return override;
  final width = MediaQuery.sizeOf(context).width;
  final platform = targetPlatform ?? defaultTargetPlatform;
  final desktopPlatform =
      platform == TargetPlatform.macOS ||
      platform == TargetPlatform.windows ||
      platform == TargetPlatform.linux;
  // `desktopDockEnabled` opts a desktop host into the professional dock; it
  // must never force a tablet or phone into desktop density. This matters for
  // iPad/Android hosts that share the same Flutter shell with macOS/Windows.
  if (desktopPlatform && (desktopDockEnabled || desktopPlatform)) {
    return CanvasLayoutMode.desktop;
  }
  return width < 600
      ? CanvasLayoutMode.compactTouch
      : CanvasLayoutMode.expandedTouch;
}
