import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/app/workspace_mode.dart';

void main() {
  testWidgets('desktop dock opt-in never forces a mobile workspace', (
    tester,
  ) async {
    late WorkspaceMode mode;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            mode = resolveWorkspaceMode(
              context,
              desktopDockEnabled: true,
              targetPlatform: TargetPlatform.iOS,
            );
            return const SizedBox();
          },
        ),
      ),
    );
    expect(mode, WorkspaceMode.expandedTouch);
  });

  testWidgets('narrow Android layouts resolve to compact touch mode', (
    tester,
  ) async {
    late WorkspaceMode mode;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(390, 844)),
        child: MaterialApp(
          home: Builder(
            builder: (context) {
              mode = resolveWorkspaceMode(
                context,
                desktopDockEnabled: true,
                targetPlatform: TargetPlatform.android,
              );
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    expect(mode, WorkspaceMode.compactTouch);
  });

  testWidgets('desktop targets retain the professional desktop mode', (
    tester,
  ) async {
    late WorkspaceMode mode;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            mode = resolveWorkspaceMode(
              context,
              desktopDockEnabled: true,
              targetPlatform: TargetPlatform.macOS,
            );
            return const SizedBox();
          },
        ),
      ),
    );
    expect(mode, WorkspaceMode.desktop);
  });
}
