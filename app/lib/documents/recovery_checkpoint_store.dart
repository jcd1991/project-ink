import 'dart:io';
import 'package:path/path.dart' as p;

/// Deletes only the app-owned recovery checkpoint inside [recoveryDirectory].
class RecoveryCheckpointStore {
  const RecoveryCheckpointStore({required this.recoveryDirectory});

  final String recoveryDirectory;

  Future<void> delete(String path) async {
    if (path.isEmpty) return;

    final root = Directory(recoveryDirectory).absolute;
    final targetPath = p.normalize(Directory(path).absolute.path);
    final rootPath = p.normalize(root.path);
    final relative = p.relative(targetPath, from: rootPath);
    if (relative == '.' ||
        p.isAbsolute(relative) ||
        relative.startsWith('..${Platform.pathSeparator}') ||
        relative != 'last-session.inkproj') {
      throw ArgumentError.value(
        path,
        'path',
        'Recovery deletion is restricted to last-session.inkproj under the app recovery directory.',
      );
    }

    final entryType = await FileSystemEntity.type(
      targetPath,
      followLinks: false,
    );
    if (entryType != FileSystemEntityType.directory) {
      if (entryType == FileSystemEntityType.notFound) return;
      throw ArgumentError.value(
        path,
        'path',
        'Recovery checkpoint must be a real directory, not a file or symbolic link.',
      );
    }
    final checkpoint = Directory(targetPath);
    if (await checkpoint.exists()) {
      await checkpoint.delete(recursive: true);
    }
  }
}
