import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';
import 'package:path/path.dart' as path;

Future<void> main() async {
  final outputDirectory = Directory(
    Platform.environment['PROJECT_INK_BRUSH_GALLERY_OUTPUT'] ??
        'build/brush-device-gallery',
  );
  await outputDirectory.create(recursive: true);

  await integrationDriver(
    onScreenshot: (name, bytes, [args]) async {
      final output = File(path.join(outputDirectory.path, '$name.png'));
      await output.writeAsBytes(bytes, flush: true);
      stdout.writeln('Brush gallery screenshot: ${output.path}');
      return true;
    },
  );
}
