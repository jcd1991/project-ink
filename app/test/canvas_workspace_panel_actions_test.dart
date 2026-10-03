import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/app/workspace_preferences.dart';
import 'package:project_ink/canvas/canvas_floating_panel_visibility.dart';
import 'package:project_ink/canvas/canvas_workspace_panel_actions.dart';
import 'package:project_ink/canvas/canvas_workspace_panel_selection.dart';

void main() {
  testWidgets('desktop selection updates its dock and persists the panel', (
    tester,
  ) async {
    CanvasDockSide? selectedSide;
    var selectedGroup = -1;
    String? selectedPanel;
    String? persistedPanel;
    CanvasFloatingPanelVisibility? updatedPanels;
    final actions = CanvasWorkspacePanelActions(
      CanvasWorkspacePanelActionHost(
        setFloatingPanels: (visibility) => updatedPanels = visibility,
        selectDesktopDock: (side, groupIndex, panel, floatingPanels) {
          selectedSide = side;
          selectedGroup = groupIndex;
          selectedPanel = panel;
          updatedPanels = floatingPanels;
        },
        selectTemporaryPalette: (_) => fail('unexpected temporary palette'),
        rememberTabletPalette: (_) => fail('unexpected tablet preference'),
        persistLastDock: (panel) => persistedPanel = panel,
        showQuickAccessSheet: (_) => fail('unexpected sheet'),
        showHistorySheet: (_) => fail('unexpected sheet'),
      ),
    );
    late BuildContext actionContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            actionContext = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    actions.selectPanel(
      panel: 'tools',
      context: actionContext,
      snapshot: _snapshot(wideDesktop: true),
    );

    expect(selectedSide, CanvasDockSide.left);
    expect(selectedGroup, -1);
    expect(selectedPanel, 'tools');
    expect(persistedPanel, 'tools');
    expect(updatedPanels, isNotNull);
  });

  testWidgets('tablet selection updates floating visibility and preference', (
    tester,
  ) async {
    CanvasFloatingPanelVisibility? updatedPanels;
    TabletWorkspaceMode? rememberedMode;
    String? persistedPanel;
    final actions = CanvasWorkspacePanelActions(
      CanvasWorkspacePanelActionHost(
        setFloatingPanels: (visibility) => updatedPanels = visibility,
        selectDesktopDock: (_, _, _, _) => fail('unexpected desktop dock'),
        selectTemporaryPalette: (_) => fail('unexpected temporary palette'),
        rememberTabletPalette: (mode) => rememberedMode = mode,
        persistLastDock: (panel) => persistedPanel = panel,
        showQuickAccessSheet: (_) => fail('unexpected sheet'),
        showHistorySheet: (_) => fail('unexpected sheet'),
      ),
    );
    late BuildContext actionContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            actionContext = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    const mode = TabletWorkspaceMode.studio;

    actions.selectPanel(
      panel: 'layers',
      context: actionContext,
      snapshot: _snapshot(
        tabletStudio: true,
        tabletPlatform: true,
        tabletMode: mode,
      ),
    );

    expect(updatedPanels?.isVisible(CanvasFloatingPanel.layers), isTrue);
    expect(rememberedMode, mode);
    expect(persistedPanel, 'layers');
  });

  testWidgets('tablet Quick Access clears exclusive panels before its sheet', (
    tester,
  ) async {
    CanvasFloatingPanelVisibility? updatedPanels;
    var quickAccessShown = false;
    final actions = CanvasWorkspacePanelActions(
      CanvasWorkspacePanelActionHost(
        setFloatingPanels: (visibility) => updatedPanels = visibility,
        selectDesktopDock: (_, _, _, _) => fail('unexpected desktop dock'),
        selectTemporaryPalette: (_) => fail('unexpected temporary palette'),
        rememberTabletPalette: (_) => fail('unexpected tablet preference'),
        persistLastDock: (_) => fail('unexpected preference write'),
        showQuickAccessSheet: (_) => quickAccessShown = true,
        showHistorySheet: (_) => fail('unexpected history sheet'),
      ),
    );
    late BuildContext actionContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            actionContext = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    actions.selectPanel(
      panel: 'quickAccess',
      context: actionContext,
      snapshot: _snapshot(
        tabletStudio: true,
        tabletPlatform: true,
        floatingPanels: const CanvasFloatingPanelVisibility(
          tools: true,
          brushes: true,
        ),
      ),
    );

    expect(updatedPanels, const CanvasFloatingPanelVisibility());
    expect(quickAccessShown, isTrue);
  });
}

CanvasWorkspacePanelActionSnapshot _snapshot({
  bool wideDesktop = false,
  bool tabletStudio = false,
  bool tabletPlatform = false,
  TabletWorkspaceMode tabletMode = TabletWorkspaceMode.simple,
  CanvasFloatingPanelVisibility floatingPanels =
      const CanvasFloatingPanelVisibility(),
}) => CanvasWorkspacePanelActionSnapshot(
  wideDesktop: wideDesktop,
  tabletStudio: tabletStudio,
  tabletPlatform: tabletPlatform,
  tabletMode: tabletMode,
  layout: illustrationWorkspace,
  leftGroups: const [],
  rightGroups: const [],
  floatingPanels: floatingPanels,
);
