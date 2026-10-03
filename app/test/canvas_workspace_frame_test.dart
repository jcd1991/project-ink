import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/app/workspace_mode.dart';
import 'package:project_ink/app/workspace_preferences.dart';
import 'package:project_ink/canvas/workspace_dock_layout.dart';

void main() {
  group('shouldUseWideDesktopLayout', () {
    test('macOS requires both logical and physical width thresholds', () {
      bool resolve({required double logical, required double physical}) =>
          shouldUseWideDesktopLayout(
            desktopDockEnabled: true,
            workspaceMode: WorkspaceMode.desktop,
            platform: TargetPlatform.macOS,
            logicalWidth: logical,
            physicalWidth: physical,
          );

      expect(resolve(logical: 1024, physical: 1200), isTrue);
      expect(resolve(logical: 1023, physical: 2048), isFalse);
      expect(resolve(logical: 1440, physical: 1199), isFalse);
    });

    test('Windows and Linux use the logical width threshold', () {
      for (final platform in [TargetPlatform.windows, TargetPlatform.linux]) {
        expect(
          shouldUseWideDesktopLayout(
            desktopDockEnabled: true,
            workspaceMode: WorkspaceMode.desktop,
            platform: platform,
            logicalWidth: 1100,
            physicalWidth: 1,
          ),
          isTrue,
        );
        expect(
          shouldUseWideDesktopLayout(
            desktopDockEnabled: true,
            workspaceMode: WorkspaceMode.desktop,
            platform: platform,
            logicalWidth: 1099,
            physicalWidth: 4096,
          ),
          isFalse,
        );
      }
    });

    test('disabled docks and non-desktop modes never select wide layout', () {
      for (final mode in [
        WorkspaceMode.compactTouch,
        WorkspaceMode.expandedTouch,
      ]) {
        expect(
          shouldUseWideDesktopLayout(
            desktopDockEnabled: true,
            workspaceMode: mode,
            platform: TargetPlatform.macOS,
            logicalWidth: 2048,
            physicalWidth: 4096,
          ),
          isFalse,
        );
      }
      expect(
        shouldUseWideDesktopLayout(
          desktopDockEnabled: false,
          workspaceMode: WorkspaceMode.desktop,
          platform: TargetPlatform.macOS,
          logicalWidth: 2048,
          physicalWidth: 4096,
        ),
        isFalse,
      );
    });
  });

  group('resolveCanvasWorkspaceFrame', () {
    test('hides collapsed and unavailable desktop docks', () {
      final frame = resolveCanvasWorkspaceFrame(
        platform: TargetPlatform.macOS,
        viewportWidth: 1440,
        wideDesktop: true,
        interfaceHidden: false,
        leftDockCollapsed: true,
        rightDockCollapsed: false,
        hasLeftDock: true,
        hasRightDock: false,
        preferredLeftDockWidth: 280,
        preferredRightDockWidth: 320,
        tabletMode: TabletWorkspaceMode.simple,
        desktopDockEnabled: true,
      );

      expect(frame.desktopDock, isTrue);
      expect(frame.showLeftDock, isFalse);
      expect(frame.showRightDock, isFalse);
      expect(frame.dockWidths.left, 0);
      expect(frame.dockWidths.right, 0);
      expect(frame.useNativeMacMenus, isTrue);
    });

    test(
      'interface hiding closes desktop docks without changing tablet mode',
      () {
        final frame = resolveCanvasWorkspaceFrame(
          platform: TargetPlatform.iOS,
          viewportWidth: 1024,
          wideDesktop: true,
          interfaceHidden: true,
          leftDockCollapsed: false,
          rightDockCollapsed: false,
          hasLeftDock: true,
          hasRightDock: true,
          preferredLeftDockWidth: 280,
          preferredRightDockWidth: 320,
          tabletMode: TabletWorkspaceMode.studio,
          desktopDockEnabled: true,
        );

        expect(frame.desktopDock, isFalse);
        expect(frame.showLeftDock, isFalse);
        expect(frame.showRightDock, isFalse);
        expect(frame.tabletStudioMode, isTrue);
        expect(frame.tabletSimpleMode, isFalse);
        expect(frame.useNativeMacMenus, isFalse);
      },
    );

    test('uses compact tablet mode below the tablet width threshold', () {
      final frame = resolveCanvasWorkspaceFrame(
        platform: TargetPlatform.android,
        viewportWidth: 599,
        wideDesktop: false,
        interfaceHidden: false,
        leftDockCollapsed: false,
        rightDockCollapsed: false,
        hasLeftDock: false,
        hasRightDock: false,
        preferredLeftDockWidth: 280,
        preferredRightDockWidth: 320,
        tabletMode: TabletWorkspaceMode.studio,
        desktopDockEnabled: false,
      );

      expect(frame.tabletStudioMode, isFalse);
      expect(frame.tabletSimpleMode, isTrue);
    });

    test('bounds visible dock widths to preserve the canvas budget', () {
      final frame = resolveCanvasWorkspaceFrame(
        platform: TargetPlatform.windows,
        viewportWidth: 1100,
        wideDesktop: true,
        interfaceHidden: false,
        leftDockCollapsed: false,
        rightDockCollapsed: false,
        hasLeftDock: true,
        hasRightDock: true,
        preferredLeftDockWidth: 400,
        preferredRightDockWidth: 400,
        tabletMode: TabletWorkspaceMode.simple,
        desktopDockEnabled: true,
      );

      expect(frame.showLeftDock, isTrue);
      expect(frame.showRightDock, isTrue);
      expect(frame.dockWidths.left + frame.dockWidths.right, 656);
    });
  });
}
