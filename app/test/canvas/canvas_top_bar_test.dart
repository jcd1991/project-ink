import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/app/editor_action.dart';
import 'package:project_ink/app/workspace_preferences.dart';
import 'package:project_ink/canvas/canvas_top_bar.dart';

void main() {
  testWidgets('tablet top bar keeps essentials visible at narrow width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: _topBar())));

    expect(find.byTooltip('Undo'), findsOneWidget);
    expect(find.byTooltip('Redo'), findsOneWidget);
    expect(find.byTooltip('Canvas Focus'), findsOneWidget);
    expect(find.text('Simple'), findsOneWidget);
    expect(
      tester
          .renderObject<RenderParagraph>(find.text('Simple'))
          .didExceedMaxLines,
      isFalse,
    );
    expect(
      find.byTooltip('More actions and workspace settings'),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Color'), findsNothing);
    expect(find.byType(SingleChildScrollView), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('More actions and workspace settings'));
    await tester.pumpAndSettle();
    expect(find.text('Open project…'), findsOneWidget);
    expect(find.text('Workspace layout'), findsOneWidget);
    expect(find.text('Color'), findsNothing);
    await tester.tapAt(const Offset(12, 550));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byTooltip('Simple mode selected. Choose Simple or Studio.'),
    );
    await tester.pumpAndSettle();
    expect(find.text('Studio'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop command bar remains independent of touch editor mode', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _topBar(
            simpleTouchLayout: false,
            editorMode: EditorMode.studio,
            phoneLayout: false,
            professionalDesktop: true,
          ),
        ),
      ),
    );

    expect(find.byTooltip('More commands'), findsOneWidget);
    expect(
      find.byTooltip('Studio mode selected. Choose Simple or Studio.'),
      findsNothing,
    );
  });

  testWidgets('phone Studio More menu exposes advanced panels', (tester) async {
    String? selectedPanel;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _topBar(
            editorMode: EditorMode.studio,
            onSelectPanel: (panel) => selectedPanel = panel,
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('More actions and workspace settings'));
    await tester.pumpAndSettle();
    expect(find.text('Studio panels'), findsOneWidget);
    expect(find.text('Tool properties'), findsOneWidget);
    expect(find.text('Materials'), findsOneWidget);
    expect(find.text('History'), findsOneWidget);
    expect(find.text('Quick Access'), findsOneWidget);
    await tester.tap(find.text('History'));
    expect(selectedPanel, 'history');
  });
}

CanvasTopBar _topBar({
  bool simpleTouchLayout = true,
  bool studioTouchLayout = false,
  EditorMode editorMode = EditorMode.simple,
  bool phoneLayout = true,
  bool professionalDesktop = false,
  ValueChanged<String> onSelectPanel = _ignoreString,
}) => CanvasTopBar(
  documentName: 'Untitled',
  activeToolLabel: 'Brush',
  activeBrushLabel: 'Opaque Round',
  saveStatusLabel: 'Saved',
  documentActionsEnabled: true,
  documentActionRunning: false,
  onOpen: _noop,
  onSave: _noop,
  onExportMenu: _noop,
  onGestureSettings: _noop,
  onAccessibilitySettings: _noop,
  onComics: _noop,
  onSelectPanel: onSelectPanel,
  onUndo: _noop,
  onRedo: _noop,
  onCommandSearch: _noop,
  mirrored: false,
  simpleTouchLayout: simpleTouchLayout,
  studioTouchLayout: studioTouchLayout,
  editorMode: editorMode,
  phoneLayout: phoneLayout,
  onEditorModeSelected: _ignoreMode,
  onToggleFocus: _noop,
  workspaceId: 'illustration',
  onWorkspaceSelected: _ignoreString,
  professionalDesktop: professionalDesktop,
  nativeMenuBar: false,
  customWorkspaces: [],
  onSaveWorkspaceAs: _noop,
  onResetWorkspace: _ignoreString,
  followDocumentType: true,
  onFollowDocumentTypeChanged: _ignoreBool,
  onRenameWorkspace: _ignoreString,
  onDeleteWorkspace: _ignoreString,
  onActionDispatch: _ignoreAction,
  commandBarItems: [],
  onCustomizeCommandBar: _noop,
);

void _noop() {}

void _ignoreMode(EditorMode _) {}

void _ignoreString(String _) {}

void _ignoreBool(bool _) {}

void _ignoreAction(EditorActionId _) {}
