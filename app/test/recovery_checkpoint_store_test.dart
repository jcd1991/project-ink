import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/documents/recovery_checkpoint_store.dart';

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'project-ink-recovery-store-',
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test(
    'deletes recovery directory and preserves named project bytes',
    () async {
      final namedProject = File('${temporaryDirectory.path}/saved.inkproj');
      const namedProjectBytes = <int>[3, 17, 29, 41, 53, 67];
      await namedProject.writeAsBytes(namedProjectBytes, flush: true);

      final recovery = Directory(
        '${temporaryDirectory.path}/last-session.inkproj',
      );
      await recovery.create();
      await File(
        '${recovery.path}/checkpoint.bin',
      ).writeAsBytes(const <int>[89, 101, 113], flush: true);

      await RecoveryCheckpointStore(
        recoveryDirectory: temporaryDirectory.path,
      ).delete(recovery.path);

      expect(await recovery.exists(), isFalse);
      expect(await namedProject.readAsBytes(), namedProjectBytes);
    },
  );

  test('deleting a missing or empty recovery path is harmless', () async {
    final store = RecoveryCheckpointStore(
      recoveryDirectory: temporaryDirectory.path,
    );

    await store.delete('');
    await store.delete('${temporaryDirectory.path}/last-session.inkproj');

    expect(await temporaryDirectory.exists(), isTrue);
  });

  test('refuses to recursively delete a named project', () async {
    final namedProject = Directory(
      '${temporaryDirectory.path}/artwork.inkproj',
    );
    await namedProject.create();
    final content = File('${namedProject.path}/project.json');
    await content.writeAsString('preserve me');

    await expectLater(
      RecoveryCheckpointStore(
        recoveryDirectory: temporaryDirectory.path,
      ).delete(namedProject.path),
      throwsArgumentError,
    );
    expect(await content.readAsString(), 'preserve me');
  });
}
