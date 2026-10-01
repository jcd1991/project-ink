import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Layout density selected by the editor shell.  It is deliberately separate
/// from document state so a project can move between an iPad, desktop, and
/// split-screen window without changing its data.
enum WorkspaceMode { compactTouch, expandedTouch, desktop }

WorkspaceMode resolveWorkspaceMode(
  BuildContext context, {
  WorkspaceMode? override,
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
    return WorkspaceMode.desktop;
  }
  return width < 600 ? WorkspaceMode.compactTouch : WorkspaceMode.expandedTouch;
}
