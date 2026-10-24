import 'dart:io';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/documents/provider_project_picker.dart';
import 'package:project_ink/documents/platform_document_picker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'desktop project save selects a parent for atomic package writes',
    () async {
      final selector = _FakeFileSelector(
        directory: '/tmp/story.inkproj',
        saveDirectory: '/tmp/phase385be-test-output',
        directorySelections: [
          '/tmp/story.inkproj/',
          '/tmp',
          '/tmp/phase385be-test-output',
        ],
        saveLocation: const FileSaveLocation('/tmp/story-copy'),
      );
      final picker = PlatformDocumentPicker(
        selector: selector,
        targetPlatform: TargetPlatform.macOS,
      );

      expect(await picker.openProject(), '/tmp/story.inkproj');
      expect(selector.directoryPrompts, [
        'Open project',
        'Choose project folder',
      ]);
      expect(selector.directoryInitials.take(2), [null, '/']);
      expect(selector.openFileCalls, 0);
      expect(
        await picker.saveProject(suggestedName: 'story.inkproj'),
        '/tmp/phase385be-test-output/story.inkproj',
      );
      expect(selector.lastSaveOptions.suggestedName, isNull);
      expect(
        await picker.exportPng(suggestedName: 'preview'),
        '/tmp/story-copy.png',
      );
      expect(selector.lastSaveOptions.suggestedName, 'preview.png');
    },
  );

  test(
    'desktop project save cancellation does not invent a destination',
    () async {
      final picker = PlatformDocumentPicker(
        selector: _FakeFileSelector(),
        targetPlatform: TargetPlatform.macOS,
      );
      expect(await picker.saveProject(suggestedName: 'story.inkproj'), isNull);
    },
  );

  test(
    'macOS parent selection chooses among multiple project packages',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'project-ink-picker-multiple-',
      );
      addTearDown(() => root.delete(recursive: true));
      final first = Directory('${root.path}/first.inkproj');
      final second = Directory('${root.path}/second.inkproj');
      await first.create();
      await second.create();
      final selector = _FakeFileSelector(
        directorySelections: [root.path, '${second.path}/'],
      );
      final picker = PlatformDocumentPicker(
        selector: selector,
        targetPlatform: TargetPlatform.macOS,
      );

      expect(await picker.openProject(), second.path);
      expect(selector.directoryPrompts, ['Open project', 'Choose project']);
      expect(selector.directoryInitials, [null, root.path]);
    },
  );

  test('PSD import uses a separate native file-picker action', () async {
    final selector = _FakeFileSelector(
      directory: '/tmp/story.inkproj',
      directorySelections: ['/tmp/story.inkproj', '/tmp'],
      selectedFile: XFile('/tmp/reference.psd'),
    );
    final picker = PlatformDocumentPicker(
      selector: selector,
      targetPlatform: TargetPlatform.macOS,
    );
    expect(await picker.openProject(), '/tmp/story.inkproj');
    expect(selector.openFileCalls, 0);
    expect(await picker.openPsd(), '/tmp/reference.psd');
    expect(selector.openFileCalls, 1);
    expect(selector.lastAcceptedTypeGroups, isNull);
  });

  test('brush picker restricts import and export to local paths', () async {
    final selector = _FakeFileSelector(
      selectedFile: XFile('/tmp/source.kpp'),
      saveLocation: const FileSaveLocation('/tmp/ink-brush'),
    );
    final picker = PlatformDocumentPicker(
      selector: selector,
      targetPlatform: TargetPlatform.macOS,
    );

    expect(await picker.openBrush(), '/tmp/source.kpp');
    expect(
      await picker.saveBrush(suggestedName: 'pencil.inkbrush'),
      '/tmp/ink-brush.inkbrush',
    );
    expect(selector.lastSaveOptions.suggestedName, 'pencil');
  });

  test('iOS brush import allows custom brush document types', () async {
    final selector = _FakeFileSelector(selectedFile: XFile('/tmp/sample.sut'));
    final picker = PlatformDocumentPicker(
      selector: selector,
      targetPlatform: TargetPlatform.iOS,
    );

    expect(await picker.openBrush(), '/tmp/sample.sut');
    expect(selector.lastAcceptedTypeGroups, hasLength(1));
    expect(selector.lastAcceptedTypeGroups!.single.uniformTypeIdentifiers, [
      'public.data',
    ]);
  });

  test('iOS brush tip picker filters for images', () async {
    final selector = _FakeFileSelector(selectedFile: XFile('/tmp/tip.png'));
    final picker = PlatformDocumentPicker(
      selector: selector,
      targetPlatform: TargetPlatform.iOS,
    );

    expect(await picker.openBrushTipImage(), '/tmp/tip.png');
    expect(selector.lastAcceptedTypeGroups, hasLength(1));
    expect(selector.lastAcceptedTypeGroups!.single.uniformTypeIdentifiers, [
      'public.image',
    ]);
  });

  test('native cancellation remains cancellation', () async {
    final picker = PlatformDocumentPicker(
      selector: _FakeFileSelector(),
      targetPlatform: TargetPlatform.android,
      providerPicker: const ProviderProjectPicker(
        openProjectCallback: _missingProvider,
      ),
    );

    expect(await picker.openProject(), isNull);
    expect(await picker.saveProject(), isNull);
    expect(await picker.exportPng(), isNull);
  });

  test(
    'Android chooses a local parent directory for directory-backed output',
    () async {
      final picker = PlatformDocumentPicker(
        selector: _FakeFileSelector(
          directory: '/tmp/phase385be-picker-android',
        ),
        targetPlatform: TargetPlatform.android,
        providerPicker: const ProviderProjectPicker(
          openProjectCallback: _missingProvider,
        ),
      );

      expect(
        await picker.saveProject(),
        '/tmp/phase385be-picker-android/untitled.inkproj',
      );
      expect(
        await picker.exportPng(),
        '/tmp/phase385be-picker-android/untitled.png',
      );
      expect(
        await picker.chooseComicExportDirectory(),
        '/tmp/phase385be-picker-android',
      );
    },
  );

  for (final platform in [TargetPlatform.android, TargetPlatform.macOS]) {
    for (final folder in [
      '/tmp/story.inkproj',
      '/tmp/story.inkproj/tiles',
      '/tmp/STORY.INKPROJ/child',
      '/tmp/story.inkproj.bak/child',
    ]) {
      test('$platform rejects nested project saves in $folder', () async {
        final picker = PlatformDocumentPicker(
          selector: _FakeFileSelector(directory: folder),
          targetPlatform: platform,
        );
        await expectLater(
          picker.saveProject(),
          throwsA(isA<FileSystemException>()),
        );
      });
    }
  }

  test(
    'provider picker returns the staged local path from native code',
    () async {
      const channel = MethodChannel('test/provider_documents_v1');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'openProject');
            return '/app/Application Support/ProviderImports/story.inkproj';
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      expect(
        await const ProviderProjectPicker(channel: channel).openProject(),
        '/app/Application Support/ProviderImports/story.inkproj',
      );
    },
  );

  test('provider PNG export parses a staged path and commits it', () async {
    const channel = MethodChannel('test/provider_png_documents_v1');
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          if (call.method == 'preparePngExport') {
            expect(call.arguments, {
              'suggestedName': 'preview.png',
              'localProjectPath': '/app/ProviderImports/current.inkproj',
            });
            return {
              'path': '/app/ProviderExports/preview.png',
              'canWriteBack': true,
            };
          }
          expect(call.method, 'commitPng');
          expect(call.arguments, {
            'localPath': '/app/ProviderExports/preview.png',
          });
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    const picker = ProviderProjectPicker(channel: channel);
    final selection = await picker.preparePngExport(
      suggestedName: 'preview.png',
      localProjectPath: '/app/ProviderImports/current.inkproj',
    );
    expect(selection?.path, '/app/ProviderExports/preview.png');
    expect(selection?.canWriteBack, isTrue);
    await picker.commitPng(selection!.path);
    expect(calls, ['preparePngExport', 'commitPng']);
  });

  test(
    'provider Save As chooses a fresh destination until it is bound',
    () async {
      final picker = PlatformDocumentPicker(
        selector: _FakeFileSelector(directory: '/tmp/new-project-parent'),
        targetPlatform: TargetPlatform.android,
        providerPicker: ProviderProjectPicker(
          openProjectCallback: () async => '/tmp/staged-old.inkproj',
        ),
      );
      final opened = await picker.openProject();
      picker.bindProject(opened);
      expect(picker.hasActiveProviderProject, isTrue);
      expect(
        await picker.saveProject(suggestedName: 'copy.inkproj'),
        '/tmp/new-project-parent/copy.inkproj',
      );
      expect(picker.hasActiveProviderProject, isTrue);
      picker.bindProject('/tmp/new-project-parent/copy.inkproj');
      expect(picker.hasActiveProviderProject, isFalse);
    },
  );

  test(
    'cancelled or rejected Open preserves the current provider write-back',
    () async {
      const channel = MethodChannel('test/provider_binding');
      final selections = <Object?>[
        {'path': '/tmp/staged-old.inkproj', 'canWriteBack': true},
        null,
        {'path': '/tmp/rejected.inkproj', 'canWriteBack': true},
      ];
      final committed = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'openProject') return selections.removeAt(0);
            expect(call.method, 'commitProject');
            committed.add((call.arguments as Map)['localPath'] as String);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final picker = PlatformDocumentPicker(
        targetPlatform: TargetPlatform.android,
        providerPicker: const ProviderProjectPicker(channel: channel),
      );
      final opened = await picker.openProject();
      picker.bindProject(opened);
      expect(await picker.openProject(), isNull);
      await picker.commitProject(opened!);
      expect(await picker.openProject(), '/tmp/rejected.inkproj');
      // A failed Rust open does not bind the rejected candidate.
      await picker.commitProject(opened);
      expect(committed, [opened, opened]);
      picker.bindProject(null);
      expect(picker.hasActiveProviderProject, isFalse);
      await picker.commitProject(opened);
      expect(committed, [opened, opened]);
    },
  );

  test(
    'New canvas export does not reuse the previous provider folder',
    () async {
      var providerExports = 0;
      final picker = PlatformDocumentPicker(
        selector: _FakeFileSelector(directory: '/tmp/new-canvas-export'),
        targetPlatform: TargetPlatform.android,
        providerPicker: ProviderProjectPicker(
          openProjectCallback: () async => '/tmp/provider/old.inkproj',
          preparePngExportCallback: (_) async {
            providerExports++;
            return null;
          },
        ),
      );
      picker.bindProject(await picker.openProject());
      picker.bindProject(null);
      expect(await picker.exportPng(), '/tmp/new-canvas-export/untitled.png');
      expect(providerExports, 0);
    },
  );

  test(
    'rejected provider Open cannot redirect a local canvas export',
    () async {
      var providerExports = 0;
      final picker = PlatformDocumentPicker(
        selector: _FakeFileSelector(directory: '/tmp/local-export'),
        targetPlatform: TargetPlatform.android,
        providerPicker: ProviderProjectPicker(
          openProjectCallback: () async => '/tmp/provider/rejected.inkproj',
          preparePngExportCallback: (_) async {
            providerExports++;
            return null;
          },
        ),
      );
      picker.bindProject('/tmp/local.inkproj');
      await picker.openProject();
      // Rust rejects this selection, so the application does not bind it.
      expect(picker.hasActiveProviderProject, isFalse);
      expect(await picker.exportPng(), '/tmp/local-export/untitled.png');
      expect(providerExports, 0);
    },
  );

  test('mobile provider PNG export stays on the local path contract', () async {
    String? committed;
    final picker = PlatformDocumentPicker(
      selector: _FakeFileSelector(directory: '/tmp'),
      targetPlatform: TargetPlatform.iOS,
      providerPicker: ProviderProjectPicker(
        openProjectCallback: () async => '/tmp/provider/project.inkproj',
        preparePngExportCallback:
            (name) async => <String, Object?>{
              'path': '/tmp/provider/$name',
              'canWriteBack': true,
            },
        commitPngCallback: (path) async => committed = path,
      ),
    );

    await picker.openProject();
    picker.bindProject('/tmp/provider/project.inkproj');
    final path = await picker.exportPng(suggestedName: 'panel');
    expect(path, '/tmp/provider/panel.png');
    await picker.commitPng(path!);
    expect(committed, path);
  });
}

Future<String?> _missingProvider() => throw MissingPluginException();

class _FakeFileSelector extends FileSelectorPlatform {
  _FakeFileSelector({
    this.directory,
    this.saveDirectory,
    this.directorySelections,
    this.saveLocation,
    this.selectedFile,
  });

  final String? directory;
  final String? saveDirectory;
  final List<String?>? directorySelections;
  final FileSaveLocation? saveLocation;
  final XFile? selectedFile;
  SaveDialogOptions lastSaveOptions = const SaveDialogOptions();
  final List<String?> directoryPrompts = [];
  final List<String?> directoryInitials = [];
  int openFileCalls = 0;
  List<XTypeGroup>? lastAcceptedTypeGroups;

  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    openFileCalls++;
    lastAcceptedTypeGroups = acceptedTypeGroups;
    return selectedFile;
  }

  @override
  Future<String?> getDirectoryPath({
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    directoryPrompts.add(confirmButtonText);
    if (directorySelections != null && directorySelections!.isNotEmpty) {
      return directorySelections!.removeAt(0);
    }
    return directory;
  }

  @override
  Future<String?> getDirectoryPathWithOptions(FileDialogOptions options) async {
    directoryPrompts.add(options.confirmButtonText);
    directoryInitials.add(options.initialDirectory);
    return directorySelections?.isNotEmpty == true
        ? directorySelections!.removeAt(0)
        : saveDirectory ?? directory;
  }

  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) async {
    lastSaveOptions = options;
    return saveLocation;
  }
}
