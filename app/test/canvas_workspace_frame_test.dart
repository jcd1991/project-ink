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
            layoutMode: CanvasLayoutMode.desktop,
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
            layoutMode: CanvasLayoutMode.desktop,
            platform: platform,
            logicalWidth: 1100,
            physicalWidth: 1,
          ),
          isTrue,
        );
        expect(
          shouldUseWideDesktopLayout(
            desktopDockEnabled: true,
            layoutMode: CanvasLayoutMode.desktop,
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
        CanvasLayoutMode.compactTouch,
        CanvasLayoutMode.expandedTouch,
      ]) {
        expect(
          shouldUseWideDesktopLayout(
            desktopDockEnabled: true,
            layoutMode: mode,
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
          layoutMode: CanvasLayoutMode.desktop,
          platform: TargetPlatform.macOS,
          logicalWidth: 2048,
          physicalWidth: 4096,
        ),
        isFalse,
      );
    });
  });

  group('resolveCanvasWorkspaceFrame', () {
    test('desktop dock visibility is independent of touch editor mode', () {
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
        editorMode: EditorMode.simple,
        desktopDockEnabled: true,
      );

      expect(frame.desktopDock, isTrue);
      expect(frame.simpleMode, isTrue);
      expect(frame.showLeftDock, isFalse);
      expect(frame.showRightDock, isFalse);
      expect(frame.dockWidths.left, 0);
      expect(frame.dockWidths.right, 0);
      expect(frame.useNativeMacMenus, isTrue);
    });

    test(
      'interface hiding closes desktop docks without changing editor mode',
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
          editorMode: EditorMode.studio,
          desktopDockEnabled: true,
        );

        expect(frame.desktopDock, isFalse);
        expect(frame.showLeftDock, isFalse);
        expect(frame.showRightDock, isFalse);
        expect(frame.studioTouchLayout, isTrue);
        expect(frame.simpleMode, isFalse);
        expect(frame.useNativeMacMenus, isFalse);
      },
    );

    test('phone layout stays compact while preserving the selected mode', () {
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
        editorMode: EditorMode.studio,
        desktopDockEnabled: false,
      );

      expect(frame.studioTouchLayout, isFalse);
      expect(frame.simpleMode, isFalse);
      expect(frame.phoneLayout, isTrue);
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
        editorMode: EditorMode.studio,
        desktopDockEnabled: true,
      );

      expect(frame.showLeftDock, isTrue);
      expect(frame.showRightDock, isTrue);
      expect(frame.dockWidths.left + frame.dockWidths.right, 656);
    });

    test('editor mode is shared across desktop, web, and touch layouts', () {
      final macStudio = resolveCanvasWorkspaceFrame(
        platform: TargetPlatform.macOS,
        viewportWidth: 1440,
        wideDesktop: true,
        interfaceHidden: false,
        leftDockCollapsed: false,
        rightDockCollapsed: false,
        hasLeftDock: true,
        hasRightDock: true,
        preferredLeftDockWidth: 280,
        preferredRightDockWidth: 320,
        editorMode: EditorMode.studio,
        desktopDockEnabled: true,
      );
      expect(macStudio.desktopDock, isTrue);
      expect(macStudio.studioTouchLayout, isFalse);

      final narrowWebStudio = resolveCanvasWorkspaceFrame(
        platform: TargetPlatform.linux,
        viewportWidth: 820,
        wideDesktop: false,
        interfaceHidden: false,
        leftDockCollapsed: false,
        rightDockCollapsed: false,
        hasLeftDock: true,
        hasRightDock: true,
        preferredLeftDockWidth: 280,
        preferredRightDockWidth: 320,
        editorMode: EditorMode.studio,
        desktopDockEnabled: true,
        isWeb: true,
      );
      expect(narrowWebStudio.studioTouchLayout, isTrue);
      expect(narrowWebStudio.phoneLayout, isFalse);

      final phoneStudio = resolveCanvasWorkspaceFrame(
        platform: TargetPlatform.android,
        viewportWidth: 412,
        wideDesktop: false,
        interfaceHidden: false,
        leftDockCollapsed: false,
        rightDockCollapsed: false,
        hasLeftDock: true,
        hasRightDock: true,
        preferredLeftDockWidth: 280,
        preferredRightDockWidth: 320,
        editorMode: EditorMode.studio,
        desktopDockEnabled: false,
      );
      expect(phoneStudio.phoneLayout, isTrue);
      expect(phoneStudio.studioTouchLayout, isFalse);
      expect(phoneStudio.simpleMode, isFalse);
    });

    test('narrow macOS windows retain the desktop header shell', () {
      final frame = resolveCanvasWorkspaceFrame(
        platform: TargetPlatform.macOS,
        viewportWidth: 820,
        wideDesktop: false,
        interfaceHidden: false,
        leftDockCollapsed: false,
        rightDockCollapsed: false,
        hasLeftDock: true,
        hasRightDock: true,
        preferredLeftDockWidth: 280,
        preferredRightDockWidth: 320,
        editorMode: EditorMode.simple,
        desktopDockEnabled: true,
      );

      expect(frame.phoneLayout, isFalse);
      expect(frame.simpleTouchLayout, isFalse);
    });
  });
}
