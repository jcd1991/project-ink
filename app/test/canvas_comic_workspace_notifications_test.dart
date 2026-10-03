import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/canvas/canvas_comic_workspace_notifications.dart';

void main() {
  testWidgets(
    'coalesces notifications and applies page and workspace effects',
    (tester) async {
      final source = ChangeNotifier();
      final events = <String>[];
      final notifications = CanvasComicWorkspaceNotifications(
        source: source,
        isMounted: () => true,
        shouldClearSelection: () => true,
        clearSelection: () async => events.add('clear_selection'),
        rebuild: () => events.add('rebuild'),
        followsDocumentType: () => true,
        workspaceForDocument: () => 'comic',
        selectWorkspace: (workspace) => events.add('workspace:$workspace'),
      );
      notifications.start();
      notifications.start();

      source.notifyListeners();
      source.notifyListeners();
      expect(events, ['clear_selection']);
      await tester.pump();

      expect(events, ['clear_selection', 'rebuild', 'workspace:comic']);
      notifications.dispose();
      source.dispose();
    },
  );

  testWidgets('disposed owner ignores already scheduled notifications', (
    tester,
  ) async {
    final source = ChangeNotifier();
    var rebuilds = 0;
    final notifications = CanvasComicWorkspaceNotifications(
      source: source,
      isMounted: () => true,
      shouldClearSelection: () => false,
      clearSelection: () async {},
      rebuild: () => rebuilds++,
      followsDocumentType: () => false,
      workspaceForDocument: () => 'comic',
      selectWorkspace: (_) {},
    );
    notifications.start();
    source.notifyListeners();
    notifications.dispose();
    await tester.pump();

    expect(rebuilds, 0);
    source.dispose();
  });
}
