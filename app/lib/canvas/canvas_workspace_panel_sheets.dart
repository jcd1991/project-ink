import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app/editor_action.dart';
import '../app/workspace_preferences.dart';
import '../bridge/engine_api.dart';
import '../design_system/ink_components.dart';
import '../tools/brush_library.dart';
import 'canvas_compact_controls.dart';
import 'canvas_history_panel.dart';
import 'canvas_phone_color_picker.dart';
import 'canvas_quick_access_panel.dart';

/// Presents a draggable phone sheet around a screen-owned panel child.
Future<void> showCanvasPhonePanelSheet({
  required BuildContext context,
  required String title,
  double initialExtent = 0.5,
  required Widget child,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder:
        (sheetContext) => _CanvasPhonePanelSheet(
          title: title,
          initialExtent: initialExtent,
          child: child,
        ),
  );
}

class _CanvasPhonePanelSheet extends StatefulWidget {
  const _CanvasPhonePanelSheet({
    required this.title,
    required this.initialExtent,
    required this.child,
  });

  final String title;
  final Widget child;
  final double initialExtent;

  @override
  State<_CanvasPhonePanelSheet> createState() => _CanvasPhonePanelSheetState();
}

class _CanvasPhonePanelSheetState extends State<_CanvasPhonePanelSheet> {
  late double _extent = widget.initialExtent;

  void _resizeFromDrag(DragUpdateDetails details, double availableHeight) {
    if (availableHeight <= 0) return;
    setState(() {
      _extent =
          (_extent - details.delta.dy / availableHeight)
              .clamp(0.42, 0.92)
              .toDouble();
    });
  }

  void _toggleExtent() {
    setState(() => _extent = _extent < 0.72 ? 0.92 : widget.initialExtent);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final availableHeight = constraints.maxHeight;
      return Align(
        alignment: Alignment.bottomCenter,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          height: availableHeight * _extent,
          child: SafeArea(
            top: false,
            child: Material(
              color: inkColors(context).panel,
              clipBehavior: Clip.antiAlias,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(20),
              ),
              child: Column(
                children: [
                  GestureDetector(
                    key: const ValueKey('phone-panel-drag-handle'),
                    behavior: HitTestBehavior.opaque,
                    onTap: _toggleExtent,
                    onVerticalDragUpdate:
                        (details) => _resizeFromDrag(details, availableHeight),
                    child: Column(
                      children: [
                        const SizedBox(height: 10),
                        Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: inkColors(context).panelBorder,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        InkDockHeader(
                          title: widget.title,
                          actions: [
                            IconButton(
                              tooltip: 'Close ${widget.title}',
                              onPressed: () => Navigator.of(context).pop(),
                              icon: const Icon(Icons.close),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Expanded(child: widget.child),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// Presents the integrated phone color wheel and role controls.
Future<void> showCanvasPhoneColorSheet({
  required BuildContext context,
  required Color mainColor,
  required Color subColor,
  required List<String> recentColors,
  required Future<void> Function(Color mainColor, Color subColor) onApply,
  double initialExtent = 0.5,
}) => showCanvasPhonePanelSheet(
  context: context,
  title: 'Color',
  initialExtent: initialExtent,
  child: CanvasPhoneColorPickerPanel(
    mainColor: mainColor,
    subColor: subColor,
    recentColors: recentColors,
    onApply: onApply,
  ),
);

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
