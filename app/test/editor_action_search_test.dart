import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/app/editor_action.dart';

void main() {
  test('every editor action has searchable user-facing metadata', () {
    for (final action in EditorActionId.values) {
      expect(action.label, isNotEmpty, reason: action.name);
      expect(action.category, isNotEmpty, reason: action.name);
      expect(action.searchCorpus, contains(action.label.toLowerCase()));
      expect(searchEditorActions(action.category), contains(action));
      if (action.shortcut != null) {
        expect(searchEditorActions(action.shortcut!), contains(action));
      }
      if (action.paletteName != null) {
        expect(searchEditorActions(action.paletteName!), contains(action));
      }
      if (action.toolName != null) {
        expect(searchEditorActions(action.toolName!), contains(action));
      }
    }
  });

  test('search covers aliases, categories, shortcuts, palettes, and tools', () {
    expect(searchEditorActions('brush palette'), [EditorActionId.showBrushes]);
    expect(searchEditorActions('Ctrl/⌘+O'), [EditorActionId.openProject]);
    expect(searchEditorActions('view mirror'), [EditorActionId.mirrorCanvas]);
    expect(searchEditorActions('color wheel'), [
      EditorActionId.showColorPicker,
    ]);
    expect(searchEditorActions('eraser tool'), [EditorActionId.toggleEraser]);
    expect(searchEditorActions('zoom fit page'), [EditorActionId.fitCanvas]);
    expect(searchEditorActions('no such command'), isEmpty);
  });

  test('empty search returns all implemented actions in registry order', () {
    expect(searchEditorActions('  '), EditorActionId.values);
  });
}
