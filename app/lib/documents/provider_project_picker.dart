import 'package:flutter/services.dart';

/// Opens a provider-backed `.inkproj` directory and returns a local staged
/// path. Native code copies the selected directory before this future resolves;
/// Rust never receives a `content://` or security-scoped provider URI.
class ProviderProjectPicker {
  const ProviderProjectPicker({
    MethodChannel? channel,
    Future<String?> Function()? openProjectCallback,
    Future<Object?> Function(String suggestedName)? preparePngExportCallback,
    Future<void> Function(String localPath)? commitPngCallback,
  }) : _channel = channel ?? _defaultChannel,
       _openProjectCallback = openProjectCallback,
       _preparePngExportCallback = preparePngExportCallback,
       _commitPngCallback = commitPngCallback;

  static const MethodChannel _defaultChannel = MethodChannel(
    'org.projectink.studio/provider_documents_v1',
  );
  final MethodChannel _channel;
  final Future<String?> Function()? _openProjectCallback;
  final Future<Object?> Function(String suggestedName)?
  _preparePngExportCallback;
  final Future<void> Function(String localPath)? _commitPngCallback;

  Future<ProviderProjectSelection?> openProjectSelection() async {
    final result =
        _openProjectCallback != null
            ? await _openProjectCallback()
            : await _channel.invokeMethod<Object?>('openProject');
    if (result == null) return null;
    if (result is String) {
      return ProviderProjectSelection(path: result, canWriteBack: false);
    }
    if (result is Map) {
      final path = result['path'];
      if (path is String && path.isNotEmpty) {
        return ProviderProjectSelection(
          path: path,
          canWriteBack: result['canWriteBack'] == true,
        );
      }
    }
    throw const FormatException('Invalid provider project selection.');
  }

  Future<String?> openProject() async => (await openProjectSelection())?.path;

  Future<void> commitProject(String localPath) async {
    await _channel.invokeMethod<void>('commitProject', <String, Object?>{
      'localPath': localPath,
    });
  }

  Future<ProviderPngExportSelection?> preparePngExport({
    required String suggestedName,
  }) async {
    final result =
        _preparePngExportCallback != null
            ? await _preparePngExportCallback(suggestedName)
            : await _channel.invokeMethod<Object?>(
              'preparePngExport',
              <String, Object?>{'suggestedName': suggestedName},
            );
    if (result == null) return null;
    if (result is String) {
      return ProviderPngExportSelection(path: result, canWriteBack: false);
    }
    if (result is Map) {
      final path = result['path'];
      if (path is String && path.isNotEmpty) {
        return ProviderPngExportSelection(
          path: path,
          canWriteBack: result['canWriteBack'] == true,
        );
      }
    }
    throw const FormatException('Invalid provider PNG export selection.');
  }

  Future<void> commitPng(String localPath) async {
    final callback = _commitPngCallback;
    if (callback != null) {
      await callback(localPath);
      return;
    }
    await _channel.invokeMethod<void>('commitPng', <String, Object?>{
      'localPath': localPath,
    });
  }
}

class ProviderProjectSelection {
  const ProviderProjectSelection({
    required this.path,
    required this.canWriteBack,
  });

  final String path;
  final bool canWriteBack;
}

class ProviderPngExportSelection {
  const ProviderPngExportSelection({
    required this.path,
    required this.canWriteBack,
  });

  final String path;
  final bool canWriteBack;
}
