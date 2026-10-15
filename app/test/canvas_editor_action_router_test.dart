import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/app/editor_action.dart';
import 'package:project_ink/canvas/canvas_editor_action_router.dart';

void main() {
  test('feature owners are consulted in order and stop after handling', () {
    final calls = <String>[];
    final router = _router(calls, dispatchHistoryAction: (_) => true);

    router.dispatch(EditorActionId.undo);

    expect(calls, ['document', 'history']);
  });

  test('viewport actions run before panel and presentation fallbacks', () {
    final calls = <String>[];
    final router = _router(
      calls,
      viewportAction: (action) {
        expect(action, EditorActionId.actualPixels);
        return () => calls.add('viewport action');
      },
    );

    router.dispatch(EditorActionId.actualPixels);

    expect(calls, [
      'document',
      'history',
      'tool',
      'brush color',
      'setState',
      'viewport action',
    ]);
  });

  test('panel commands and local fallback commands use their owners', () {
    final panelCalls = <String>[];
    _router(panelCalls).dispatch(EditorActionId.showBrushes);
    expect(panelCalls.last, 'panel:brushes');

    final localCalls = <String>[];
    _router(localCalls).dispatch(EditorActionId.toggleEraser);
    expect(localCalls.last, 'toggle eraser');
  });

  test('disposed screen does not dispatch commands', () {
    final calls = <String>[];
    _router(calls, isMounted: false).dispatch(EditorActionId.toggleEraser);
    expect(calls, isEmpty);
  });

  test('adjustment draft blocks conflicting editor actions', () {
    final calls = <String>[];
    _router(calls, adjustmentEditActive: true).dispatch(EditorActionId.undo);
    expect(calls, isEmpty);
    expect(
      isEditorActionDisabled(
        action: EditorActionId.saveProject,
        documentActionsEnabled: true,
        documentActionRunning: false,
        adjustmentEditActive: true,
      ),
      isTrue,
    );
  });
}

CanvasEditorActionRouter _router(
  List<String> calls, {
  bool isMounted = true,
  bool adjustmentEditActive = false,
  bool Function(EditorActionId action)? dispatchDocumentAction,
  bool Function(EditorActionId action)? dispatchHistoryAction,
  bool Function(EditorActionId action)? dispatchToolAction,
  bool Function(EditorActionId action)? dispatchBrushColorAction,
  VoidCallback? Function(EditorActionId action)? viewportAction,
}) => CanvasEditorActionRouter(
  CanvasEditorActionRouterHost(
    isMounted: () => isMounted,
    isAdjustmentEditActive: () => adjustmentEditActive,
    dispatchDocumentAction: (action) {
      calls.add('document');
      return dispatchDocumentAction?.call(action) ?? false;
    },
    dispatchHistoryAction: (action) {
      calls.add('history');
      return dispatchHistoryAction?.call(action) ?? false;
    },
    dispatchToolAction: (action) {
      calls.add('tool');
      return dispatchToolAction?.call(action) ?? false;
    },
    dispatchBrushColorAction: (action) {
      calls.add('brush color');
      return dispatchBrushColorAction?.call(action) ?? false;
    },
    viewportAction: (action) => viewportAction?.call(action),
    applyStateAction: (action) {
      calls.add('setState');
      action();
    },
    selectPanel: (panel) => calls.add('panel:$panel'),
    toggleEraser: () => calls.add('toggle eraser'),
    fitCanvas: () => calls.add('fit canvas'),
    toggleInterface: () => calls.add('toggle interface'),
    showColorPicker: () => calls.add('show color picker'),
    armColorSampler: () => calls.add('arm color sampler'),
    toggleQuickMenu: () => calls.add('toggle quick menu'),
    showCommandSearch: () => calls.add('command search'),
  ),
);
