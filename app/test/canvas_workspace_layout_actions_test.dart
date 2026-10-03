import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/app/workspace_preferences.dart';
import 'package:project_ink/canvas/canvas_workspace_layout_actions.dart';

void main() {
  test('resolves built-in layouts and palette labels', () {
    const preferences = WorkspacePreferences();
    final actions = CanvasWorkspaceLayoutActions(
      CanvasWorkspaceLayoutHost(
        preferences: () => preferences,
        onPreferencesChanged: () => null,
      ),
    );

    expect(actions.layoutFor('comic'), comicWorkspace);
    expect(actions.layoutFor('minimal'), minimalWorkspace);
    expect(actions.layoutFor('unknown'), illustrationWorkspace);
    expect(actions.paletteName(InkPaletteId.quickAccess), 'quickAccess');
    expect(actions.paletteLabel('quickAccess'), 'Quick Access');
    expect(actions.paletteForDockTab('tools'), InkPaletteId.toolGroups);
  });

  test('uses custom command bars and workspace overrides', () {
    const custom = WorkspaceLayout(
      id: 'custom-sketch',
      name: 'Sketch',
      kind: WorkspacePresetKind.custom,
      commandBar: ['undo', 'redo'],
    );
    const override = WorkspaceLayout(
      id: 'illustration',
      name: 'Illustration override',
      kind: WorkspacePresetKind.illustration,
    );
    final preferences = WorkspacePreferences(
      workspaceId: custom.id,
      customWorkspaces: const [custom],
      workspaceOverrides: const {'illustration': override},
      commandBarOverrides: const {
        'custom-sketch': ['saveProject'],
      },
    );
    final actions = CanvasWorkspaceLayoutActions(
      CanvasWorkspaceLayoutHost(
        preferences: () => preferences,
        onPreferencesChanged: () => null,
      ),
    );

    expect(actions.layoutFor(custom.id), custom);
    expect(actions.layoutFor('illustration'), override);
    expect(actions.effectiveCommandBarItems(), custom.commandBar);

    final fallbackActions = CanvasWorkspaceLayoutActions(
      CanvasWorkspaceLayoutHost(
        preferences:
            () => preferences.copyWith(
              customWorkspaces: const [
                WorkspaceLayout(
                  id: 'custom-sketch',
                  name: 'Sketch',
                  kind: WorkspacePresetKind.custom,
                ),
              ],
            ),
        onPreferencesChanged: () => null,
      ),
    );
    expect(fallbackActions.effectiveCommandBarItems(), const ['saveProject']);
  });

  test('persists a built-in dock resize into its layout override', () {
    var current = const WorkspacePreferences(workspaceId: 'illustration');
    final actions = CanvasWorkspaceLayoutActions(
      CanvasWorkspaceLayoutHost(
        preferences: () => current,
        onPreferencesChanged: () => (updated) => current = updated,
      ),
    );

    actions.persistDockWidth(left: false, width: 420);

    expect(current.dockWidth, 420);
    expect(current.workspaceOverrides['illustration']?.right?.width, 420);
    expect(
      current.workspaceOverrides['illustration']?.left?.width,
      illustrationWorkspace.left?.width,
    );
  });

  test('projects dock state when switching built-in and custom workspaces', () {
    const custom = WorkspaceLayout(
      id: 'custom-drawing',
      name: 'Drawing',
      kind: WorkspacePresetKind.custom,
      left: DockColumnLayout(
        width: 210,
        collapsed: true,
        groups: [
          DockGroupLayout(
            tabs: [InkPaletteId.toolGroups],
            activeTab: InkPaletteId.toolGroups,
          ),
        ],
      ),
      right: DockColumnLayout(
        width: 520,
        groups: [
          DockGroupLayout(
            tabs: [InkPaletteId.comics],
            activeTab: InkPaletteId.comics,
          ),
        ],
      ),
    );
    const preferences = WorkspacePreferences(
      customWorkspaces: [custom],
      dockWidth: 300,
      leftDockWidth: 280,
    );
    final actions = CanvasWorkspaceLayoutActions(
      CanvasWorkspaceLayoutHost(
        preferences: () => preferences,
        onPreferencesChanged: () => null,
      ),
    );

    final selected = actions.dockSelectionFor(custom.id);
    expect(selected.leftCollapsed, isTrue);
    expect(selected.rightWidth, 480);
    expect(selected.leftWidth, 220);
    expect(selected.rightTab, 'comics');
    expect(selected.leftTab, 'tools');
    expect(selected.rightGroups, custom.right!.groups);

    final comic = actions.dockSelectionFor('comic');
    expect(comic.rightWidth, 400);
    expect(comic.leftTab, 'tools');
  });

  test(
    'manual workspace selection persists dock and disables document follow',
    () {
      var current = const WorkspacePreferences(followDocumentType: true);
      final actions = CanvasWorkspaceLayoutActions(
        CanvasWorkspaceLayoutHost(
          preferences: () => current,
          onPreferencesChanged: () => (updated) => current = updated,
        ),
      );

      final selected = actions.selectWorkspace('comic');

      expect(selected.rightTab, 'comics');
      expect(current.workspaceId, 'comic');
      expect(current.lastDock, 'comics');
      expect(current.followDocumentType, isFalse);
    },
  );

  test(
    'following document type selects its workspace and preserves enabled preference',
    () {
      var current = const WorkspacePreferences(followDocumentType: false);
      final actions = CanvasWorkspaceLayoutActions(
        CanvasWorkspaceLayoutHost(
          preferences: () => current,
          onPreferencesChanged: () => (updated) => current = updated,
        ),
      );

      final disabled = actions.setFollowDocumentType(
        enabled: false,
        documentWorkspaceId: 'comic',
      );
      expect(disabled, isNull);
      expect(current.followDocumentType, isFalse);
      expect(current.workspaceId, 'illustration');

      final enabled = actions.setFollowDocumentType(
        enabled: true,
        documentWorkspaceId: 'comic',
      );
      expect(enabled?.rightTab, 'comics');
      expect(current.workspaceId, 'comic');
      expect(current.lastDock, 'comics');
      expect(current.followDocumentType, isTrue);
    },
  );

  test('persists a custom dock resize without changing its other column', () {
    const custom = WorkspaceLayout(
      id: 'custom-sketch',
      name: 'Sketch',
      kind: WorkspacePresetKind.custom,
      left: DockColumnLayout(width: 260),
      right: DockColumnLayout(width: 340),
    );
    var current = const WorkspacePreferences(
      workspaceId: 'custom-sketch',
      customWorkspaces: [custom],
    );
    final actions = CanvasWorkspaceLayoutActions(
      CanvasWorkspaceLayoutHost(
        preferences: () => current,
        onPreferencesChanged: () => (updated) => current = updated,
      ),
    );

    actions.persistDockWidth(left: true, width: 280);

    final saved = current.customWorkspaces.single;
    expect(saved.left?.width, 280);
    expect(saved.right?.width, 340);
  });
}
