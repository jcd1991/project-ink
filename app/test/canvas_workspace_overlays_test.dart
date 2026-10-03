import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/canvas/canvas_floating_panel_visibility.dart';
import 'package:project_ink/canvas/canvas_workspace_overlays.dart';

void main() {
  testWidgets('floating panel close publishes an updated visibility value', (
    tester,
  ) async {
    const visibility = CanvasFloatingPanelVisibility(tools: true, layers: true);
    CanvasFloatingPanelVisibility? published;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CanvasFloatingWorkspacePanels(
            visibility: visibility,
            onVisibilityChanged: (next) => published = next,
            interfaceHidden: false,
            desktopDock: false,
            tabletStudioMode: false,
            safeAreaTop: 0,
            tools: const SizedBox(key: Key('tools-content')),
            brushes: const SizedBox(key: Key('brushes-content')),
            layers: const SizedBox(key: Key('layers-content')),
            comics: const SizedBox(key: Key('comics-content')),
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('tools-content')), findsOneWidget);
    expect(find.byKey(const Key('layers-content')), findsOneWidget);
    expect(find.byKey(const Key('brushes-content')), findsNothing);
    await tester.tap(find.byTooltip('Close Illustration tools'));

    expect(published?.tools, isFalse);
    expect(published?.brushes, isFalse);
    expect(published?.layers, isTrue);
    expect(published?.comics, isFalse);
  });

  testWidgets('places visible panels on their configured canvas edges', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 600,
            child: Stack(
              children: [
                CanvasWorkspaceOverlays(
                  overlays: [
                    CanvasWorkspaceOverlay(
                      title: 'Tools',
                      visible: true,
                      width: 280,
                      studioWidth: 320,
                      onClose: () {},
                      child: const SizedBox(key: Key('tools-content')),
                    ),
                    CanvasWorkspaceOverlay(
                      title: 'Layers',
                      visible: true,
                      width: 280,
                      studioWidth: 360,
                      rightAligned: true,
                      semanticsLabel: 'Layers panel',
                      onClose: () {},
                      child: const SizedBox(key: Key('layers-content')),
                    ),
                    CanvasWorkspaceOverlay(
                      title: 'Hidden',
                      visible: false,
                      width: 280,
                      studioWidth: 320,
                      onClose: () {},
                      child: const SizedBox(key: Key('hidden-content')),
                    ),
                  ],
                  interfaceHidden: false,
                  desktopDock: false,
                  tabletStudioMode: false,
                  safeAreaTop: 10,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('tools-content')), findsOneWidget);
    expect(find.byKey(const Key('layers-content')), findsOneWidget);
    expect(find.byKey(const Key('hidden-content')), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics && widget.properties.label == 'Layers panel',
      ),
      findsOneWidget,
    );
    expect(
      tester
          .getTopLeft(find.byKey(const Key('canvas-workspace-overlay-Tools')))
          .dx,
      12,
    );
    expect(
      tester
          .getTopLeft(find.byKey(const Key('canvas-workspace-overlay-Layers')))
          .dx,
      greaterThan(500),
    );
  });

  testWidgets('hides overlays in desktop dock and focus layouts', (
    tester,
  ) async {
    for (final configuration in [
      (interfaceHidden: true, desktopDock: false),
      (interfaceHidden: false, desktopDock: true),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CanvasWorkspaceOverlays(
              overlays: [
                CanvasWorkspaceOverlay(
                  title: 'Tools',
                  visible: true,
                  width: 280,
                  studioWidth: 320,
                  onClose: () {},
                  child: const SizedBox(key: Key('tools-content')),
                ),
              ],
              interfaceHidden: configuration.interfaceHidden,
              desktopDock: configuration.desktopDock,
              tabletStudioMode: false,
              safeAreaTop: 0,
            ),
          ),
        ),
      );

      expect(find.byKey(const Key('tools-content')), findsNothing);
    }
  });
}
