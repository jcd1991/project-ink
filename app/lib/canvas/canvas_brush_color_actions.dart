import 'dart:async';

import 'package:flutter/material.dart';

import '../app/editor_action.dart';
import 'canvas_brush_color_dialog.dart';

/// Screen-owned effects required by [CanvasBrushColorActions].
class CanvasBrushColorActionsHost {
  const CanvasBrushColorActionsHost({
    required this.isMounted,
    required this.mainColor,
    required this.subColor,
    required this.recentColors,
    required this.finishDanglingStroke,
    required this.publishColors,
    required this.persistRecentColors,
    required this.updateRustBrushColor,
  });

  final bool Function() isMounted;
  final Color Function() mainColor;
  final Color Function() subColor;
  final List<String> Function() recentColors;
  final Future<void> Function() finishDanglingStroke;
  final void Function({Color? mainColor, Color? subColor, bool cacheMainColor})
  publishColors;
  final void Function(List<String> colors) persistRecentColors;
  final Future<bool> Function(Color color) updateRustBrushColor;
}

/// Owns brush color workflows while leaving presentation and Rust state with
/// their existing owners.
class CanvasBrushColorActions {
  CanvasBrushColorActions(this.host);

  static const recentColorLimit = 24;

  final CanvasBrushColorActionsHost host;

  /// Presents the main/sub-color picker and applies its accepted result.
  Future<void> showColorPicker({
    required BuildContext context,
    bool editSubColor = false,
  }) async {
    final selected = await showDialog<Color>(
      context: context,
      builder:
          (_) => CanvasBrushColorDialog(
            initialColor: editSubColor ? host.subColor() : host.mainColor(),
            title: editSubColor ? 'Sub color' : 'Brush color',
            recentColors: host.recentColors(),
          ),
    );
    if (selected == null || !host.isMounted()) return;
    if (editSubColor) {
      selectSubColor(selected);
    } else {
      await applyMainColor(selected);
    }
  }

  /// Dispatches color commands to the color workflows owned here.
  bool dispatchEditorAction(EditorActionId action) {
    switch (action) {
      case EditorActionId.swapColors:
        unawaited(swapColors());
        return true;
      case EditorActionId.resetColors:
        unawaited(resetColors());
        return true;
      default:
        return false;
    }
  }

  /// Flushes a native pointer-up before publishing the selection or editing
  /// the Rust brush. This order prevents a queued stroke terminal from racing
  /// the brush-color command.
  Future<void> applyMainColor(Color selected) async {
    await host.finishDanglingStroke();
    final updatedRecentColors = _recentColorsWith(
      selected,
      host.recentColors(),
    );
    if (host.isMounted()) {
      host.publishColors(mainColor: selected, cacheMainColor: true);
      host.persistRecentColors(updatedRecentColors);
    }
    await host.updateRustBrushColor(selected);
  }

  /// Clipboard paste preserves its existing behavior: update Rust first and
  /// publish the UI color only after the bridge accepts it.
  Future<void> applyPastedColor(Color color) async {
    if (await host.updateRustBrushColor(color) && host.isMounted()) {
      host.publishColors(mainColor: color);
    }
  }

  void selectSubColor(Color selected) {
    final normalized = _normalizeColor(selected);
    final recentColors = host.recentColors();
    if (host.isMounted()) {
      host.publishColors(subColor: selected);
      host.persistRecentColors(
        [
          normalized,
          ...recentColors.where((value) => value.toUpperCase() != normalized),
        ].take(recentColorLimit).toList(growable: false),
      );
    }
  }

  Future<void> swapColors() async {
    final previousMainColor = host.mainColor();
    final nextMainColor = host.subColor();
    host.publishColors(mainColor: nextMainColor, subColor: previousMainColor);
    await host.updateRustBrushColor(nextMainColor);
  }

  Future<void> resetColors() async {
    const mainColor = Colors.black;
    const subColor = Colors.white;
    host.publishColors(mainColor: mainColor, subColor: subColor);
    await host.updateRustBrushColor(mainColor);
  }

  static List<String> _recentColorsWith(
    Color color,
    List<String> existingColors,
  ) {
    final normalized = _normalizeColor(color);
    return [
      normalized,
      ...existingColors.where((value) => value.toUpperCase() != normalized),
    ].take(recentColorLimit).toList(growable: false);
  }

  static String _normalizeColor(Color color) =>
      '#${color.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';
}
