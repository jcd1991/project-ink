import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// Resolve Project Ink's local documents directory.
///
/// Non-release builds may supply `PROJECT_INK_TEST_DOCUMENTS_PATH` to isolate
/// recovery and diagnostic files during desktop or device acceptance. Release
/// builds always use the platform documents directory.
Future<Directory> projectDocumentsDirectory() async {
  const compileTimeTestPath = String.fromEnvironment(
    'PROJECT_INK_TEST_DOCUMENTS_PATH',
  );
  final runtimeTestPath =
      !kReleaseMode
          ? Platform.environment['PROJECT_INK_TEST_DOCUMENTS_PATH']
          : null;
  final normalizedTestPath =
      (runtimeTestPath?.trim().isNotEmpty == true
              ? runtimeTestPath!
              : compileTimeTestPath)
          .trim();
  if (!kReleaseMode && normalizedTestPath.isNotEmpty) {
    if (!path.isAbsolute(normalizedTestPath)) {
      throw ArgumentError.value(
        normalizedTestPath,
        'PROJECT_INK_TEST_DOCUMENTS_PATH',
        'must be an absolute path',
      );
    }
    final directory = Directory(normalizedTestPath);
    await directory.create(recursive: true);
    return directory;
  }
  return getApplicationDocumentsDirectory();
}
