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
    required this.setRustActiveColor,
  });

  final bool Function() isMounted;
  final Color Function() mainColor;
  final Color Function() subColor;
  final List<String> Function() recentColors;
  final Future<void> Function() finishDanglingStroke;
  final void Function({Color? mainColor, Color? subColor}) publishColors;
  final void Function(List<String> colors) persistRecentColors;
  final Future<bool> Function(Color color) setRustActiveColor;
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
            title: editSubColor ? 'Sub color' : 'Main color',
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

  /// Finishes accepted input before changing the shared color used by future
  /// strokes. Existing strokes retain the color they started with.
  Future<void> applyMainColor(Color selected) async {
    await host.finishDanglingStroke();
    if (!await host.setRustActiveColor(selected) || !host.isMounted()) return;
    final updatedRecentColors = _recentColorsWith(
      selected,
      host.recentColors(),
    );
    if (host.isMounted()) {
      host.publishColors(mainColor: selected);
      host.persistRecentColors(updatedRecentColors);
    }
  }

  /// Clipboard paste preserves its existing behavior: update Rust first and
  /// publish the UI color only after the bridge accepts it.
  Future<void> applyPastedColor(Color color) async {
    if (await host.setRustActiveColor(color) && host.isMounted()) {
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
    await host.finishDanglingStroke();
    if (await host.setRustActiveColor(nextMainColor) && host.isMounted()) {
      host.publishColors(mainColor: nextMainColor, subColor: previousMainColor);
    }
  }

  Future<void> resetColors() async {
    const mainColor = Colors.black;
    const subColor = Colors.white;
    await host.finishDanglingStroke();
    if (await host.setRustActiveColor(mainColor) && host.isMounted()) {
      host.publishColors(mainColor: mainColor, subColor: subColor);
    }
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
