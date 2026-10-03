import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/app/workspace_preferences.dart';
import 'package:project_ink/canvas/canvas_workspace_dock_state.dart';
import 'package:project_ink/canvas/canvas_workspace_layout_actions.dart';

void main() {
  test('initial state clamps host width and resolves built-in defaults', () {
    final state = _state();

    state.initialize(preferences: null, fallbackRightWidth: 700);

    expect(state.rightWidth, 480);
    expect(state.leftWidth, 248);
    expect(state.rightTab, 'properties');
    expect(state.leftTab, 'tools');
    expect(state.rightCollapsed, isFalse);
    expect(state.leftCollapsed, isFalse);
  });

  test('custom workspace initialization uses its own columns and tabs', () {
    const custom = WorkspaceLayout(
      id: 'custom-studio',
      name: 'Custom studio',
      kind: WorkspacePresetKind.custom,
      left: DockColumnLayout(
        width: 301,
        collapsed: true,
        groups: [
          DockGroupLayout(
            tabs: [InkPaletteId.color],
            activeTab: InkPaletteId.color,
          ),
        ],
      ),
      right: DockColumnLayout(
        width: 402,
        groups: [
          DockGroupLayout(
            tabs: [InkPaletteId.comics],
            activeTab: InkPaletteId.comics,
          ),
        ],
      ),
    );
    final preferences = const WorkspacePreferences().copyWith(
      workspaceId: custom.id,
      customWorkspaces: [custom],
      dockWidth: 350,
      leftDockWidth: 250,
      lastDock: 'tools',
    );
    final state = _state();

    state.initialize(preferences: preferences, fallbackRightWidth: 340);

    expect(state.leftWidth, 301);
    expect(state.rightWidth, 402);
    expect(state.leftCollapsed, isTrue);
    expect(state.leftTab, 'color');
    expect(state.rightTab, 'tools');
    expect(state.rightGroups.single.activeTab, InkPaletteId.comics);
  });

  test('preference updates preserve group state unless workspace changes', () {
    final state = _state();
    const previous = WorkspacePreferences();
    state.initialize(preferences: previous, fallbackRightWidth: 340);
    final originalLeftGroups = state.leftGroups;
    final sizesOnly = previous.copyWith(
      dockWidth: 700,
      leftDockWidth: 190,
      leftHanded: true,
      lastDock: 'color',
    );

    state.updatePreferences(previous: previous, current: sizesOnly);

    expect(state.rightWidth, 480);
    expect(state.leftWidth, 220);
    expect(state.leftHandedToolbar, isTrue);
    expect(state.rightTab, 'color');
    expect(state.leftGroups, same(originalLeftGroups));

    const comic = WorkspacePreferences(
      workspaceId: 'comic',
      lastDock: 'comics',
    );
    state.updatePreferences(previous: sizesOnly, current: comic);

    expect(state.rightWidth, comicWorkspace.right!.width);
    expect(state.rightTab, 'comics');
    expect(state.leftGroups, comicWorkspace.left!.groups);
  });
}

CanvasWorkspaceDockState _state() => CanvasWorkspaceDockState(
  CanvasWorkspaceLayoutActions(
    CanvasWorkspaceLayoutHost(
      preferences: () => const WorkspacePreferences(),
      onPreferencesChanged: () => null,
    ),
  ),
);
