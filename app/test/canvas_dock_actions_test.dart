import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/app/workspace_preferences.dart';
import 'package:project_ink/canvas/canvas_dock_actions.dart';
import 'package:project_ink/canvas/canvas_workspace_layout_actions.dart';

void main() {
  test('dock width changes are bounded and persisted by the action owner', () {
    final fixture = _DockActionFixture();

    fixture.actions.adjustWidth(left: false, delta: 500);

    expect(fixture.rightWidth, 480);
    expect(fixture.preferences.dockWidth, 480);
    expect(fixture.stateUpdates, 1);
    expect(fixture.preferenceUpdates, 1);

    fixture.actions.adjustWidth(left: false, delta: 10);

    expect(fixture.rightWidth, 480);
    expect(fixture.stateUpdates, 1);
    expect(fixture.preferenceUpdates, 1);
  });

  test(
    'collapse changes are applied and persisted with the active workspace',
    () {
      final fixture = _DockActionFixture();

      fixture.actions.setCollapsed(left: false, collapsed: true);

      expect(fixture.rightCollapsed, isTrue);
      expect(fixture.stateUpdates, 1);
      expect(
        fixture
            .preferences
            .workspaceOverrides['illustration']!
            .right!
            .collapsed,
        isTrue,
      );
      expect(fixture.preferenceUpdates, 1);

      fixture.actions.setCollapsed(left: false, collapsed: true);

      expect(fixture.stateUpdates, 1);
      expect(fixture.preferenceUpdates, 1);
    },
  );
}

class _DockActionFixture {
  WorkspacePreferences preferences = const WorkspacePreferences();
  double leftWidth = 248;
  double rightWidth = 340;
  bool leftCollapsed = false;
  bool rightCollapsed = false;
  int stateUpdates = 0;
  int preferenceUpdates = 0;

  late final CanvasWorkspaceLayoutActions layoutActions =
      CanvasWorkspaceLayoutActions(
        CanvasWorkspaceLayoutHost(
          preferences: () => preferences,
          onPreferencesChanged:
              () => (next) {
                preferences = next;
                preferenceUpdates++;
              },
        ),
      );

  late final CanvasDockActions actions = CanvasDockActions(
    CanvasDockActionHost(
      preferences: () => preferences,
      layoutActions: layoutActions,
      groups: ({required left}) => const [],
      setGroups: ({required left, required groups}) {},
      setTab: ({required left, required tab}) {},
      dockWidth: ({required left}) => left ? leftWidth : rightWidth,
      dockCollapsed: ({required left}) => left ? leftCollapsed : rightCollapsed,
      setDockWidth: ({required left, required width}) {
        if (left) {
          leftWidth = width;
        } else {
          rightWidth = width;
        }
      },
      setDockCollapsed: ({required left, required collapsed}) {
        if (left) {
          leftCollapsed = collapsed;
        } else {
          rightCollapsed = collapsed;
        }
      },
      clearTemporaryPalette: () {},
      updateState: (update) {
        stateUpdates++;
        update();
      },
    ),
  );
}
