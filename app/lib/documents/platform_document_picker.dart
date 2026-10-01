import 'dart:io';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'document_picker.dart';
import 'provider_project_picker.dart';

/// Native-first document picker with a local, offline fallback.
///
/// The Rust engine accepts ordinary filesystem paths because `.inkproj` is a
/// directory-backed format. Desktop selectors can return those paths directly.
/// Android's directory selector can do so for primary local storage; provider
/// URIs and iOS directory packages fall back to the app-owned Documents
/// container rather than leaking an unusable URI into Rust.
class PlatformDocumentPicker
    implements
        DocumentPicker,
        PsdImportPicker,
        BrushPicker,
        DocumentWriteback,
        DocumentPngWriteback,
        DocumentExportPicker,
        ComicExportPicker,
        ProviderDocumentState {
  PlatformDocumentPicker({
    FileSelectorPlatform? selector,
    TargetPlatform? targetPlatform,
    ProviderProjectPicker? providerPicker,
  }) : _selector = selector ?? FileSelectorPlatform.instance,
       _targetPlatform = targetPlatform ?? defaultTargetPlatform,
       _providerPicker = providerPicker ?? const ProviderProjectPicker();

  final FileSelectorPlatform _selector;
  final TargetPlatform _targetPlatform;
  final ProviderProjectPicker _providerPicker;
  ProviderProjectSelection? _activeProviderProject;
  ProviderPngExportSelection? _activeProviderPngExport;

  @override
  bool get hasActiveProviderProject => _activeProviderProject != null;

  bool get _supportsNativeDirectorySelection =>
      _targetPlatform == TargetPlatform.android ||
      _targetPlatform == TargetPlatform.linux ||
      _targetPlatform == TargetPlatform.macOS ||
      _targetPlatform == TargetPlatform.windows;

  bool get _supportsNativeSaveDialog =>
      _targetPlatform == TargetPlatform.linux ||
      _targetPlatform == TargetPlatform.macOS ||
      _targetPlatform == TargetPlatform.windows;

  @override
  Future<String?> openProject() async {
    _activeProviderPngExport = null;
    if (_targetPlatform == TargetPlatform.android ||
        _targetPlatform == TargetPlatform.iOS) {
      try {
        // A null result from an installed provider picker means cancellation;
        // only a missing channel falls through to the local/native fallback.
        final selection = await _providerPicker.openProjectSelection();
        _activeProviderProject = selection;
        return selection?.path;
      } on MissingPluginException {
        // Debug/widget hosts may not have the platform runner registered.
      }
    }
    if (_supportsNativeDirectorySelection) {
      try {
        final selected = await _selector.getDirectoryPathWithOptions(
          const FileDialogOptions(confirmButtonText: 'Open project'),
        );
        if (selected == null) return null;
        final normalizedSelection = path.normalize(selected);
        if (_isProjectDirectory(normalizedSelection)) {
          if (_targetPlatform == TargetPlatform.macOS) {
            // Atomic package saves write temporary and backup siblings beside
            // the .inkproj directory. Selecting the package grants access to
            // that package, but not necessarily to its parent directory.
            final parent = path.dirname(normalizedSelection);
            final grantedParent = await _selector.getDirectoryPathWithOptions(
              FileDialogOptions(
                // Start one level above so the containing folder itself is
                // the selected URL. Starting inside it can leave the project
                // package preselected, returning the package instead of its
                // parent and silently cancelling the open.
                initialDirectory: path.dirname(parent),
                confirmButtonText: 'Choose project folder',
              ),
            );
            if (grantedParent == null ||
                path.normalize(grantedParent) != path.normalize(parent)) {
              return null;
            }
          }
          _activeProviderProject = null;
          return normalizedSelection;
        }
        // A parent directory is useful when it contains exactly one project.
        // Do not guess among multiple projects; the fallback remains
        // deterministic and never passes an invalid path to Rust.
        final projects = await _projectsIn(Directory(selected));
        if (projects.length == 1) {
          _activeProviderProject = null;
          return projects.single;
        }
        if (projects.length > 1) {
          // The first selection grants access to this parent (needed for
          // atomic saves); the second chooses one of its known packages.
          final chosen = await _selector.getDirectoryPathWithOptions(
            FileDialogOptions(
              initialDirectory: selected,
              confirmButtonText: 'Choose project',
            ),
          );
          final normalizedChoice =
              chosen == null ? null : path.normalize(chosen);
          if (normalizedChoice != null && projects.contains(normalizedChoice)) {
            _activeProviderProject = null;
            return normalizedChoice;
          }
        }
        return null;
      } on Object catch (error, stack) {
        debugPrint('Native project picker unavailable: $error\n$stack');
      }
    }
    final localProject = await _openLocalProject();
    if (localProject != null) _activeProviderProject = null;
    return localProject;
  }

  @override
  Future<String?> openPsd() async {
    if (!_supportsNativeDirectorySelection) return null;
    try {
      final image = await _selector.openFile(
        acceptedTypeGroups: const [
          XTypeGroup(label: 'Flattened Photoshop image', extensions: ['psd']),
        ],
        confirmButtonText: 'Import PSD',
      );
      return image?.path;
    } on Object catch (error, stack) {
      debugPrint('PSD import picker unavailable: $error\n$stack');
      return null;
    }
  }

  @override
  Future<void> commitProject(String localPath) async {
    final selection = _activeProviderProject;
    if (selection == null ||
        selection.path != localPath ||
        !selection.canWriteBack) {
      return;
    }
    await _providerPicker.commitProject(localPath);
  }

  @override
  Future<void> commitPng(String localPath) async {
    final selection = _activeProviderPngExport;
    if (selection == null ||
        selection.path != localPath ||
        !selection.canWriteBack) {
      return;
    }
    await _providerPicker.commitPng(localPath);
    _activeProviderPngExport = null;
  }

  @override
  Future<String?> saveProject({
    String suggestedName = 'untitled.inkproj',
  }) async {
    final activeProviderProject = _activeProviderProject;
    if (activeProviderProject != null) return activeProviderProject.path;
    final name = _withExtension(suggestedName, '.inkproj');
    if (_supportsNativeDirectorySelection) {
      try {
        final parent = await _selector.getDirectoryPathWithOptions(
          const FileDialogOptions(confirmButtonText: 'Choose save location'),
        );
        return parent == null ? null : _unusedPath(parent, name);
      } on Object catch (error, stack) {
        debugPrint(
          'Native project location picker unavailable: $error\n$stack',
        );
      }
    }
    return _newLocalProjectPath(name);
  }

  @override
  Future<String?> exportPng({String suggestedName = 'untitled.png'}) async {
    final name = _withExtension(suggestedName, '.png');
    _activeProviderPngExport = null;
    if (_targetPlatform == TargetPlatform.android ||
        _targetPlatform == TargetPlatform.iOS) {
      try {
        final selection = await _providerPicker.preparePngExport(
          suggestedName: name,
        );
        if (selection != null && selection.canWriteBack) {
          _activeProviderPngExport = selection;
          return selection.path;
        }
      } on MissingPluginException {
        // Test/widget hosts may not have the native provider channel.
      }
    }
    if (_supportsNativeSaveDialog) {
      try {
        final location = await _selector.getSaveLocation(
          acceptedTypeGroups: const [
            XTypeGroup(label: 'PNG image', extensions: ['png']),
          ],
          options: SaveDialogOptions(
            suggestedName: name,
            confirmButtonText: 'Export PNG',
          ),
        );
        return location == null ? null : _withExtension(location.path, '.png');
      } on Object catch (error, stack) {
        debugPrint('Native PNG picker unavailable: $error\n$stack');
      }
    } else if (_targetPlatform == TargetPlatform.android) {
      try {
        final parent = await _selector.getDirectoryPathWithOptions(
          const FileDialogOptions(confirmButtonText: 'Choose export folder'),
        );
        return parent == null ? null : _unusedPath(parent, name);
      } on Object catch (error, stack) {
        debugPrint('Android export picker unavailable: $error\n$stack');
      }
    }
    return _newLocalExportPath(name);
  }

  @override
  Future<String?> saveExport({
    required String extension,
    String? suggestedName,
  }) async {
    final normalized = extension.replaceFirst('.', '').toLowerCase();
    const supported = <String>{
      'png',
      'jpg',
      'jpeg',
      'webp',
      'ora',
      'svg',
      'psd',
    };
    if (!supported.contains(normalized)) return null;
    final name = _safeFilename(
      _withExtension(suggestedName ?? 'untitled.$normalized', '.$normalized'),
      fallback: 'untitled.$normalized',
    );
    if (_supportsNativeSaveDialog) {
      try {
        final location = await _selector.getSaveLocation(
          acceptedTypeGroups: [
            XTypeGroup(label: 'Project Ink export', extensions: [normalized]),
          ],
          options: SaveDialogOptions(
            suggestedName: name,
            confirmButtonText: 'Export',
          ),
        );
        return location == null
            ? null
            : _withExtension(location.path, '.$normalized');
      } on Object catch (error, stack) {
        debugPrint('Document export picker unavailable: $error\n$stack');
      }
    } else if (_targetPlatform == TargetPlatform.android) {
      try {
        final parent = await _selector.getDirectoryPathWithOptions(
          const FileDialogOptions(confirmButtonText: 'Choose export folder'),
        );
        return parent == null ? null : _unusedPath(parent, name);
      } on Object catch (error, stack) {
        debugPrint(
          'Android document export picker unavailable: $error\n$stack',
        );
      }
    }
    return _newLocalExportPath(name);
  }

  @override
  Future<String?> chooseComicExportDirectory({
    String suggestedName = 'comic-pages',
  }) async {
    if (_supportsNativeDirectorySelection) {
      try {
        return await _selector.getDirectoryPathWithOptions(
          const FileDialogOptions(confirmButtonText: 'Export comic pages'),
        );
      } on Object catch (error, stack) {
        debugPrint('Comic export picker unavailable: $error\n$stack');
      }
    }
    final documents = await getApplicationDocumentsDirectory();
    final directory = Directory(
      await _unusedDirectoryPath(documents.path, suggestedName),
    );
    await directory.create(recursive: true);
    return directory.path;
  }

  @override
  Future<String?> openBrush() async {
    try {
      final selected = await _selector.openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'Project Ink or supported brush',
            extensions: [
              'inkbrush',
              'kpp',
              'myb',
              'abr',
              'sut',
              'tos',
              'brush',
              'brushset',
              'brushlibrary',
              'png',
              'jpg',
              'jpeg',
              'webp',
            ],
          ),
        ],
        confirmButtonText: 'Import brush',
      );
      return selected?.path;
    } on Object catch (error, stack) {
      debugPrint('Brush import picker unavailable: $error\n$stack');
      return null;
    }
  }

  @override
  Future<String?> saveBrush({String suggestedName = 'brush.inkbrush'}) async {
    final name = _safeFilename(
      _withExtension(suggestedName, '.inkbrush'),
      fallback: 'brush.inkbrush',
    );
    if (_supportsNativeSaveDialog) {
      try {
        final location = await _selector.getSaveLocation(
          acceptedTypeGroups: const [
            XTypeGroup(label: 'Project Ink brush', extensions: ['inkbrush']),
          ],
          options: SaveDialogOptions(
            // NSSavePanel adds the accepted extension itself. Pass only the
            // basename so the visible suggestion does not become
            // `brush.inkbrush.inkbrush`; normalize the chosen path below.
            suggestedName: path.withoutExtension(name),
            confirmButtonText: 'Export brush',
          ),
        );
        return location == null
            ? null
            : _withExtension(location.path, '.inkbrush');
      } on Object catch (error, stack) {
        debugPrint('Brush export picker unavailable: $error\n$stack');
      }
    }
    if (_targetPlatform == TargetPlatform.android) {
      try {
        final parent = await _selector.getDirectoryPathWithOptions(
          const FileDialogOptions(confirmButtonText: 'Choose brush folder'),
        );
        return parent == null ? null : _unusedPath(parent, name);
      } on Object catch (error, stack) {
        debugPrint('Android brush export picker unavailable: $error\n$stack');
      }
    }
    return _newLocalExportPath(name);
  }

  bool _isProjectDirectory(String candidate) =>
      path.extension(candidate).toLowerCase() == '.inkproj';

  Future<List<String>> _projectsIn(Directory directory) async {
    if (!await directory.exists()) return <String>[];
    final projects =
        await directory
            .list()
            .where((entry) => entry is Directory)
            .map((entry) => path.normalize(entry.path))
            .where(_isProjectDirectory)
            .toList();
    projects.sort();
    return projects;
  }

  Future<Directory> _localProjectsDirectory() async {
    final documents = await getApplicationDocumentsDirectory();
    final directory = Directory(path.join(documents.path, 'Projects'));
    await directory.create(recursive: true);
    return directory;
  }

  Future<String?> _openLocalProject() async {
    final projects = await _projectsIn(await _localProjectsDirectory());
    return projects.isEmpty ? null : projects.first;
  }

  Future<String> _newLocalProjectPath(String suggestedName) async {
    final directory = await _localProjectsDirectory();
    return _unusedPath(directory.path, suggestedName);
  }

  Future<String> _newLocalExportPath(String suggestedName) async {
    final documents = await getApplicationDocumentsDirectory();
    return _unusedPath(documents.path, suggestedName);
  }

  Future<String> _unusedDirectoryPath(
    String directory,
    String suggestedName,
  ) async {
    final safe = _safeFilename(suggestedName, fallback: 'comic-pages');
    var candidate = path.join(directory, safe);
    var index = 2;
    while (await Directory(candidate).exists()) {
      candidate = path.join(directory, '$safe-$index');
      index++;
    }
    return candidate;
  }

  String _unusedPath(String directory, String filename) {
    final safeFilename = _safeFilename(filename, fallback: 'untitled.inkproj');
    final base = path.basenameWithoutExtension(safeFilename);
    final extension = path.extension(safeFilename);
    var candidate = path.join(directory, '$base$extension');
    var index = 2;
    while (FileSystemEntity.typeSync(candidate) !=
        FileSystemEntityType.notFound) {
      candidate = path.join(directory, '$base-$index$extension');
      index++;
    }
    return candidate;
  }

  String _withExtension(String value, String extension) {
    return path.extension(value).toLowerCase() == extension
        ? value
        : '$value$extension';
  }

  String _safeFilename(String value, {required String fallback}) {
    final sanitized =
        value
            .replaceAll(RegExp(r'[/\\]'), '_')
            .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '_')
            .trim();
    if (sanitized.isEmpty || sanitized == '.' || sanitized == '..') {
      return fallback;
    }
    return sanitized.length <= 128 ? sanitized : sanitized.substring(0, 128);
  }
}
