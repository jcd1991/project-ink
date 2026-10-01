import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'app/project_ink_app.dart';
import 'canvas/canvas_diagnostic_recorder.dart';
import 'documents/platform_document_picker.dart';

const _phase1TraceEnabled = bool.fromEnvironment(
  'PROJECT_INK_TRACE',
  defaultValue: false,
);

Future<void> main() async {
  debugPrint('Project Ink startup: entering main');
  WidgetsFlutterBinding.ensureInitialized();
  final diagnostics = CanvasDiagnosticRecorder.instance;
  final previousFlutterErrorHandler = FlutterError.onError;
  FlutterError.onError = (details) {
    diagnostics.recordError(
      'flutter_framework',
      details.exception,
      details.stack,
    );
    previousFlutterErrorHandler?.call(details);
  };
  final platformDispatcher = WidgetsBinding.instance.platformDispatcher;
  final previousPlatformErrorHandler = platformDispatcher.onError;
  platformDispatcher.onError = (error, stack) {
    diagnostics.recordError('flutter_platform_dispatcher', error, stack);
    return previousPlatformErrorHandler?.call(error, stack) ?? false;
  };
  debugPrint('Project Ink startup: Flutter binding ready');
  try {
    final tracePath = await diagnostics.startRollingLog(
      metadata: <String, Object?>{'platform': Platform.operatingSystem},
    );
    debugPrint('Project Ink rolling canvas diagnostics: $tracePath');
  } catch (error, stack) {
    // Diagnostics are best-effort and must never prevent the editor opening.
    debugPrint('Project Ink rolling diagnostics unavailable: $error\n$stack');
  }
  // Keep a local recovery checkpoint for new sessions as well as for projects
  // opened through the document picker. Without this path a released stroke
  // was only an in-memory edit until the user completed an explicit Save
  // dialog, which made a responsive preview look like a lost drawing after a
  // restart or transient picker failure.
  String? recoveryPath;
  try {
    recoveryPath = await _recoveryProjectPath();
    debugPrint('Project Ink startup: recovery path ready');
  } catch (error, stack) {
    // A storage-provider failure must not prevent the editor from opening.
    // The document toolbar remains available for an explicit user-selected
    // save, while the session simply runs without the recovery checkpoint.
    debugPrint('Project Ink recovery path unavailable: $error\n$stack');
  }
  final tracePath = _phase1TraceEnabled ? await _phase1TracePath() : null;
  if (tracePath != null) {
    debugPrint('Project Ink Phase 1 trace path: $tracePath');
  }
  debugPrint('Project Ink startup: calling runApp');
  runApp(
    ProjectInkApp(
      documentPicker: PlatformDocumentPicker(),
      autosavePath: recoveryPath,
      performanceTracePath: tracePath,
    ),
  );
}

Future<String> _recoveryProjectPath() async {
  debugPrint('Project Ink startup: resolving app documents directory');
  final documents = await getApplicationDocumentsDirectory();
  final recovery = Directory(
    path.join(documents.path, 'Project Ink', 'Recovery'),
  );
  await recovery.create(recursive: true);
  debugPrint('Project Ink startup: recovery directory ready');
  return path.join(recovery.path, 'last-session.inkproj');
}

Future<String> _phase1TracePath() async {
  final documents = await getApplicationDocumentsDirectory();
  final traces = Directory(path.join(documents.path, 'phase1-traces'));
  await traces.create(recursive: true);
  final runId = DateTime.now().toUtc().millisecondsSinceEpoch;
  return path.join(traces.path, 'phase1-$runId.jsonl');
}
