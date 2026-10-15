import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/documents/recent_projects.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  test(
    'records local projects in most-recent-first order with a cap',
    () async {
      final root = await Directory.systemTemp.createTemp('ink-recents-');
      addTearDown(() => root.delete(recursive: true));
      final store = RecentProjectsStore(
        temporaryDirectory: '${root.path}/cache',
      );

      for (var index = 0; index < 21; index++) {
        final project = Directory('${root.path}/project-$index.inkproj');
        await project.create();
        await store.add(project.path);
      }
      final firstProject = Directory('${root.path}/project-0.inkproj');
      await store.add(firstProject.path);

      final entries = await store.list();
      expect(entries, hasLength(RecentProjectsStore.maxEntries));
      expect(entries.first.path, firstProject.path);
      expect(entries.first.name, 'project-0');
      expect(entries.first.lastUsed, isNotNull);
      expect(entries.every((entry) => entry.available), isTrue);
      final reloaded =
          await RecentProjectsStore(
            temporaryDirectory: '${root.path}/cache',
          ).list();
      expect(reloaded.first.path, firstProject.path);
    },
  );

  test('keeps missing entries visible and supports removing them', () async {
    final root = await Directory.systemTemp.createTemp('ink-recents-');
    addTearDown(() => root.delete(recursive: true));
    final missingPath = '${root.path}/missing.inkproj';
    final store = RecentProjectsStore(temporaryDirectory: '${root.path}/cache');
    final missingProject = Directory(missingPath);
    await missingProject.create();
    await store.add(missingPath);
    await missingProject.delete();

    final entries = await store.list();
    expect(entries, hasLength(1));
    expect(entries.single.path, missingPath);
    expect(entries.single.available, isFalse);

    await store.remove(missingPath);
    expect(await store.list(), isEmpty);
  });

  test('rejects provider URIs and paths under the temporary directory', () {
    expect(
      RecentProjectsStore.normalizePath('content://provider/document/1'),
      isNull,
    );
    expect(
      RecentProjectsStore.normalizePath(
        '${Directory.systemTemp.path}/staged/project.inkproj',
      ),
      isNull,
    );
  });
}
