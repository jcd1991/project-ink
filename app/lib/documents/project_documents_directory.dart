import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// Resolve Project Ink's local documents directory.
///
/// Debug builds may supply `PROJECT_INK_TEST_DOCUMENTS_PATH` to isolate
/// recovery and diagnostic files during desktop acceptance. Release builds
/// always use the platform documents directory.
Future<Directory> projectDocumentsDirectory() async {
  const testPath = String.fromEnvironment('PROJECT_INK_TEST_DOCUMENTS_PATH');
  final normalizedTestPath = testPath.trim();
  if (kDebugMode && normalizedTestPath.isNotEmpty) {
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
