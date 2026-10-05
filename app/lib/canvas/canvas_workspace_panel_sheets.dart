import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app/editor_action.dart';
import '../app/workspace_preferences.dart';
import '../bridge/engine_api.dart';
import '../design_system/ink_components.dart';
import '../tools/brush_library.dart';
import 'canvas_compact_controls.dart';
import 'canvas_history_panel.dart';
import 'canvas_quick_access_panel.dart';

/// Presents the full color-role palette from one compact color entry point.
Future<void> showCanvasColorPaletteSheet({
  required BuildContext context,
  required Widget child,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) {
      final height = math.min(
        MediaQuery.sizeOf(sheetContext).height * 0.78,
        680.0,
      );
      return SizedBox(
        height: height,
        child: Column(
          children: [
            InkDockHeader(
              title: 'Color',
              actions: [
                IconButton(
                  tooltip: 'Close color selector',
                  onPressed: () => Navigator.of(sheetContext).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            Expanded(child: child),
          ],
        ),
      );
    },
  );
}

/// Presents the Quick Access sheet without owning workspace preference state.
Future<void> showCanvasQuickAccessSheet({
  required BuildContext context,
  required List<QuickAccessSet> sets,
  required String activeSetId,
  required ValueChanged<EditorActionId> onAction,
  required void Function(List<QuickAccessSet> sets, String activeSetId)
  onChanged,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder:
        (sheetContext) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(sheetContext).height * 0.68,
            child: CanvasQuickAccessPanel(
              sets: sets,
              activeSetId: activeSetId,
              onAction: (action) {
                Navigator.of(sheetContext).pop();
                onAction(action);
              },
              onChanged: onChanged,
            ),
          ),
        ),
  );
}

/// Presents the authoritative history panel as a scroll-controlled sheet.
Future<void> showCanvasHistorySheet({
  required BuildContext context,
  required EngineApi engine,
  required int revisionToken,
  required Future<void> Function(int sequence) onNavigate,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder:
        (sheetContext) => SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * 0.72,
          child: CanvasHistoryPanel(
            engine: engine,
            revisionToken: revisionToken,
            onNavigate: onNavigate,
          ),
        ),
  );
}

/// Presents focus-mode drawing controls with route-owned brush actions.
Future<void> showCanvasFocusQuickControlsSheet({
  required BuildContext context,
  required BrushPresetView brush,
  required Color color,
  required VoidCallback onUndo,
  required VoidCallback onRedo,
  required VoidCallback onBrushes,
  required VoidCallback onColor,
  required ValueChanged<BrushPresetView> onChanged,
  required ValueChanged<double> onSizeChangeEnd,
  required VoidCallback onOpacityChangeEnd,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder:
        (sheetContext) => CanvasFocusQuickControls(
          brush: brush,
          color: color,
          onUndo: onUndo,
          onRedo: onRedo,
          onBrushes: () {
            Navigator.of(sheetContext).pop();
            onBrushes();
          },
          onColor: () {
            Navigator.of(sheetContext).pop();
            onColor();
          },
          onChanged: onChanged,
          onSizeChangeEnd: onSizeChangeEnd,
          onOpacityChangeEnd: onOpacityChangeEnd,
        ),
  );
}
