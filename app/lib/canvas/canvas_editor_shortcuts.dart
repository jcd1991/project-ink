import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../app/editor_action.dart';

/// Builds the editor's keyboard bindings from the shared action registry.
Map<ShortcutActivator, VoidCallback> buildCanvasEditorShortcutBindings({
  required ValueChanged<EditorActionId> dispatch,
  required VoidCallback closeTransientPanels,
}) => {
  const SingleActivator(LogicalKeyboardKey.keyN, control: true):
      () => dispatch(EditorActionId.newDocument),
  const SingleActivator(LogicalKeyboardKey.keyN, meta: true):
      () => dispatch(EditorActionId.newDocument),
  const SingleActivator(LogicalKeyboardKey.keyO, control: true):
      () => dispatch(EditorActionId.openProject),
  const SingleActivator(LogicalKeyboardKey.keyO, meta: true):
      () => dispatch(EditorActionId.openProject),
  const SingleActivator(LogicalKeyboardKey.keyS, control: true):
      () => dispatch(EditorActionId.saveProject),
  const SingleActivator(LogicalKeyboardKey.keyS, meta: true):
      () => dispatch(EditorActionId.saveProject),
  const SingleActivator(LogicalKeyboardKey.keyS, control: true, shift: true):
      () => dispatch(EditorActionId.saveProjectAs),
  const SingleActivator(LogicalKeyboardKey.keyS, meta: true, shift: true):
      () => dispatch(EditorActionId.saveProjectAs),
  const SingleActivator(LogicalKeyboardKey.keyZ, control: true):
      () => dispatch(EditorActionId.undo),
  const SingleActivator(LogicalKeyboardKey.keyZ, meta: true):
      () => dispatch(EditorActionId.undo),
  const SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true):
      () => dispatch(EditorActionId.redo),
  const SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true):
      () => dispatch(EditorActionId.redo),
  const SingleActivator(LogicalKeyboardKey.keyY, control: true):
      () => dispatch(EditorActionId.redo),
  const SingleActivator(LogicalKeyboardKey.keyY, meta: true):
      () => dispatch(EditorActionId.redo),
  const SingleActivator(LogicalKeyboardKey.keyB):
      () => dispatch(EditorActionId.showBrushes),
  const SingleActivator(LogicalKeyboardKey.keyC):
      () => dispatch(EditorActionId.showColorPicker),
  const SingleActivator(LogicalKeyboardKey.keyI):
      () => dispatch(EditorActionId.eyedropper),
  const SingleActivator(LogicalKeyboardKey.keyI, alt: true):
      () => dispatch(EditorActionId.eyedropper),
  const SingleActivator(LogicalKeyboardKey.keyE):
      () => dispatch(EditorActionId.toggleEraser),
  const SingleActivator(LogicalKeyboardKey.keyK, control: true):
      () => dispatch(EditorActionId.commandSearch),
  const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
      () => dispatch(EditorActionId.commandSearch),
  const SingleActivator(LogicalKeyboardKey.enter, control: true):
      () => dispatch(EditorActionId.commandSearch),
  const SingleActivator(LogicalKeyboardKey.keyX):
      () => dispatch(EditorActionId.swapColors),
  const SingleActivator(LogicalKeyboardKey.keyD):
      () => dispatch(EditorActionId.resetColors),
  const SingleActivator(LogicalKeyboardKey.escape): closeTransientPanels,
};
