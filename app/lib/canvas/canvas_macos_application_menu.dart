import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/editor_action.dart';

/// Builds the native macOS menu from the shared editor action registry.
List<PlatformMenuItem> buildCanvasMacOSApplicationMenus({
  required bool documentActionsEnabled,
  required bool documentActionRunning,
  bool adjustmentEditActive = false,
  required ValueChanged<EditorActionId> onActionSelected,
  required VoidCallback onQuit,
}) => [
  for (final category in const [
    'File',
    'Edit',
    'View',
    'Layer',
    'Select',
    'Tool',
    'Window',
    'Help',
  ])
    PlatformMenu(
      label: category,
      menus: [
        for (final action in EditorActionId.values.where(
          (action) =>
              action.category == category ||
              (category == 'Tool' && action.category == 'Color'),
        ))
          PlatformMenuItem(
            label: action.label,
            shortcut: _shortcutFor(action),
            onSelected:
                isEditorActionDisabled(
                      action: action,
                      documentActionsEnabled: documentActionsEnabled,
                      documentActionRunning: documentActionRunning,
                      adjustmentEditActive: adjustmentEditActive,
                    )
                    ? null
                    : () => onActionSelected(action),
          ),
        if (category == 'File')
          PlatformMenuItem(
            label: 'Quit Project Ink',
            shortcut: const SingleActivator(
              LogicalKeyboardKey.keyQ,
              meta: true,
            ),
            onSelected: onQuit,
          ),
      ],
    ),
];

SingleActivator? _shortcutFor(EditorActionId action) => switch (action) {
  EditorActionId.newDocument => const SingleActivator(
    LogicalKeyboardKey.keyN,
    meta: true,
  ),
  EditorActionId.openProject => const SingleActivator(
    LogicalKeyboardKey.keyO,
    meta: true,
  ),
  EditorActionId.saveProject => const SingleActivator(
    LogicalKeyboardKey.keyS,
    meta: true,
  ),
  EditorActionId.saveProjectAs => const SingleActivator(
    LogicalKeyboardKey.keyS,
    meta: true,
    shift: true,
  ),
  EditorActionId.undo => const SingleActivator(
    LogicalKeyboardKey.keyZ,
    meta: true,
  ),
  EditorActionId.redo => const SingleActivator(
    LogicalKeyboardKey.keyZ,
    meta: true,
    shift: true,
  ),
  EditorActionId.showBrushes => const SingleActivator(LogicalKeyboardKey.keyB),
  EditorActionId.showColorPicker => const SingleActivator(
    LogicalKeyboardKey.keyC,
  ),
  EditorActionId.eyedropper => const SingleActivator(LogicalKeyboardKey.keyI),
  EditorActionId.toggleEraser => const SingleActivator(LogicalKeyboardKey.keyE),
  EditorActionId.commandSearch => const SingleActivator(
    LogicalKeyboardKey.keyK,
    meta: true,
  ),
  EditorActionId.swapColors => const SingleActivator(LogicalKeyboardKey.keyX),
  EditorActionId.resetColors => const SingleActivator(LogicalKeyboardKey.keyD),
  _ => null,
};
