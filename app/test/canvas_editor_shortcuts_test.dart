import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:project_ink/app/editor_action.dart';
import 'package:project_ink/canvas/canvas_editor_shortcuts.dart';

void main() {
  test('platform shortcuts dispatch shared editor actions', () {
    final dispatched = <EditorActionId>[];
    var closedTransientPanels = false;
    final bindings = buildCanvasEditorShortcutBindings(
      dispatch: dispatched.add,
      closeTransientPanels: () => closedTransientPanels = true,
    );

    bindings[const SingleActivator(
      LogicalKeyboardKey.keyS,
      meta: true,
      shift: true,
    )]!();
    bindings[const SingleActivator(LogicalKeyboardKey.keyZ, control: true)]!();
    bindings[const SingleActivator(LogicalKeyboardKey.escape)]!();

    expect(dispatched, [EditorActionId.saveProjectAs, EditorActionId.undo]);
    expect(closedTransientPanels, isTrue);
  });
}
