import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/app/editor_action.dart';
import 'package:project_ink/app/workspace_mode.dart';
import 'package:project_ink/app/workspace_preferences.dart';

void main() {
  test('malformed workspace values fail closed to bounded defaults', () {
    final preferences = WorkspacePreferences.fromJson({
      'version': 1,
      'mode_override': 'not-a-mode',
      'left_handed': 'yes',
      'theme': 'remote',
      'dock_width': 999999,
      'visible_panels': List<String>.generate(40, (index) => 'x' * 100),
      'last_dock': 'unknown',
    });

    expect(preferences.modeOverride, isNull);
    expect(preferences.leftHanded, isFalse);
    expect(preferences.theme, 'dark');
    expect(preferences.dockWidth, 480);
    expect(preferences.visiblePanels, [
      'tools',
      'brushes',
      'layers',
      'properties',
      'materials',
      'comics',
    ]);
    expect(preferences.lastDock, 'layers');
  });

  test('copyWith preserves unrelated workspace settings', () {
    const original = WorkspacePreferences(
      modeOverride: WorkspaceMode.expandedTouch,
      leftHanded: true,
      theme: 'dark',
      dockWidth: 420,
      leftDockWidth: 280,
      lastDock: 'comics',
    );
    final updated = original.copyWith(dockWidth: 480, leftDockWidth: 312);

    expect(updated.modeOverride, WorkspaceMode.expandedTouch);
    expect(updated.leftHanded, isTrue);
    expect(updated.theme, 'dark');
    expect(updated.dockWidth, 480);
    expect(updated.leftDockWidth, 312);
    expect(updated.lastDock, 'comics');
    final restored = WorkspacePreferences.fromJson(updated.toJson());
    expect(restored.leftDockWidth, 312);
  });

  test('v2 workspace layout validation rejects excessive structure', () {
    final layout = WorkspaceLayout.fromJson({
      'id': 'layout',
      'name': '  My layout  ',
      'kind': 'custom',
      'left': {
        'width': 900,
        'collapsed': false,
        'groups': [
          {
            'flex': 0,
            'tabs': ['toolGroups', 'layers'],
            'active': 'toolGroups',
          },
          {
            'flex': 1,
            'tabs': ['color'],
          },
          {
            'flex': 1,
            'tabs': ['history'],
          },
        ],
      },
      'command_bar': List<String>.generate(
        48,
        (index) =>
            index == 47
                ? 'redo'
                : index.isEven
                ? 'undo'
                : 'separator',
      ),
    });
    expect(layout, isNotNull);
    expect(layout!.name, 'My layout');
    expect(layout.left!.width, 480);
    expect(layout.left!.groups, hasLength(3));
    expect(layout.left!.groups.first.flex, 0.15);
    expect(layout.left!.groups.first.tabs, [
      InkPaletteId.toolGroups,
      InkPaletteId.layers,
    ]);
    expect(layout.commandBar, hasLength(48));
    expect(
      WorkspaceLayout.fromJson({
        'id': 'too-many',
        'name': 'Too many',
        'kind': 'custom',
        'command_bar': List<String>.generate(
          49,
          (index) => index.isEven ? 'undo' : 'separator',
        ),
      }),
      isNull,
    );
    expect(
      WorkspaceLayout.fromJson({
        'id': 'unknown-command',
        'name': 'Unknown command',
        'kind': 'custom',
        'command_bar': ['notAnAction'],
      }),
      isNull,
    );
    expect(
      WorkspaceLayout.fromJson({
        'id': 'unknown-palette',
        'name': 'Unknown palette',
        'kind': 'custom',
        'left': {
          'width': 240,
          'groups': [
            {
              'flex': 1,
              'tabs': ['notAPalette'],
            },
          ],
        },
        'command_bar': [],
      }),
      isNull,
    );
  });

  test('built-in command bar overrides stay local and bounded', () {
    final preferences = WorkspacePreferences.fromJson({
      'command_bar_overrides': {
        'illustration': ['undo', 'separator', 'showLayers'],
      },
    });
    expect(
      WorkspacePreferences.fromJson(
        preferences.toJson(),
      ).commandBarOverrides['illustration'],
      ['undo', 'separator', 'showLayers'],
    );
    expect(
      WorkspacePreferences.fromJson({
        'command_bar_overrides': {
          'illustration': ['undo', 'separator', 'separator'],
        },
      }).commandBarOverrides,
      isEmpty,
    );
    expect(
      WorkspacePreferences.fromJson({
        'command_bar_overrides': {
          'unknown-workspace': ['undo'],
        },
      }).commandBarOverrides,
      isEmpty,
    );
  });

  test('built-in dock group layouts persist and reject mismatched presets', () {
    const layout = WorkspaceLayout(
      id: 'illustration',
      name: 'Illustration',
      kind: WorkspacePresetKind.illustration,
      left: DockColumnLayout(
        width: 248,
        groups: [
          DockGroupLayout(
            flex: 0.65,
            tabs: [InkPaletteId.toolGroups, InkPaletteId.brushPresets],
            activeTab: InkPaletteId.toolGroups,
          ),
          DockGroupLayout(
            flex: 0.35,
            tabs: [InkPaletteId.color, InkPaletteId.quickAccess],
            activeTab: InkPaletteId.color,
          ),
        ],
      ),
      commandBar: [],
    );
    const preferences = WorkspacePreferences(
      workspaceOverrides: {'illustration': layout},
    );
    final restored = WorkspacePreferences.fromJson(preferences.toJson());
    expect(
      restored.workspaceOverrides['illustration']!.left!.groups.map(
        (group) => group.flex,
      ),
      [0.65, 0.35],
    );
    expect(
      WorkspacePreferences.fromJson({
        'workspace_overrides': {'comic': layout.toJson()},
      }).workspaceOverrides,
      isEmpty,
    );
  });

  test('Quick Access sets are bounded and ignore unknown actions', () {
    final parsed = QuickAccessSet.fromJson({
      'id': 'paint',
      'name': '  Paint  ',
      'actions': ['undo', 'notAnAction', 'showColorPicker', 'undo'],
    });
    expect(parsed, isNotNull);
    expect(parsed!.name, 'Paint');
    expect(parsed.actions, [
      EditorActionId.undo,
      EditorActionId.showColorPicker,
    ]);
    expect(
      QuickAccessSet.fromJson({
        'id': 'bad',
        'name': 'Bad',
        'actions': List<String>.generate(33, (index) => 'undo'),
      }),
      isNull,
    );
  });

  test('workspace preferences round trip local Quick Access sets', () {
    final preferences = WorkspacePreferences.fromJson({
      'quick_access_sets': [
        {
          'id': 'paint',
          'name': 'Paint',
          'actions': ['undo', 'showBrushes'],
        },
      ],
      'active_quick_access_set': 'paint',
    });
    final restored = WorkspacePreferences.fromJson(preferences.toJson());
    expect(restored.quickAccessSets, hasLength(1));
    expect(restored.activeQuickAccessSetId, 'paint');
    expect(restored.quickAccessSets.single.actions, [
      EditorActionId.undo,
      EditorActionId.showBrushes,
    ]);
  });

  test('recent colors stay local, validated, and bounded', () {
    final restored = WorkspacePreferences.fromJson({
      'recent_colors': ['#112233FF', '#AABBCC80', 'not-a-color', '#112233FF'],
    });
    expect(restored.recentColors, ['#112233FF', '#AABBCC80']);
    expect(
      WorkspacePreferences.fromJson({
        'recent_colors': List<String>.filled(25, '#112233FF'),
      }).recentColors,
      isEmpty,
    );
    expect(
      restored.copyWith(recentColors: ['#000000FF']).toJson()['recent_colors'],
      ['#000000FF'],
    );
  });
}
