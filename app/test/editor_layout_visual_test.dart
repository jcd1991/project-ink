import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/app/workspace_mode.dart';
import 'package:project_ink/app/workspace_preferences.dart';
import 'package:project_ink/bridge/engine_api.dart';
import 'package:project_ink/canvas/canvas_screen.dart';
import 'package:project_ink/comics/comic_workspace.dart';
import 'package:project_ink/design_system/ink_theme.dart';

final _themes = <(String, ThemeData)>[
  ('dark', InkTheme.dark()),
  ('light', InkTheme.light()),
  ('dark_hc', InkTheme.dark(highContrast: true)),
  ('light_hc', InkTheme.light(highContrast: true)),
];

class _VisualComicController extends ComicWorkspaceController {
  _VisualComicController() : super();

  @override
  Future<void> ensureExampleLoaded() async {}
}

void main() {
  setUpAll(_loadVisualFonts);
  const desktopWorkspaces = <String>['illustration', 'comic', 'minimal'];
  for (final workspaceId in desktopWorkspaces) {
    for (final (themeName, theme) in _themes) {
      testWidgets('desktop $workspaceId $themeName layout', (tester) async {
        await _setViewport(tester, const Size(1024, 640), 2);
        await _pumpEditor(
          tester,
          theme: theme,
          platform: TargetPlatform.macOS,
          mode: WorkspaceMode.desktop,
          preferences: WorkspacePreferences(
            workspaceId: workspaceId,
            followDocumentType: false,
          ),
        );

        expect(find.bySemanticsLabel('Drawing canvas'), findsOneWidget);
        final exception = tester.takeException();
        expect(
          exception,
          isNull,
          reason: _exceptionDetails(
            exception,
            'desktop $workspaceId / $themeName',
          ),
        );
        await expectLater(
          find.byType(CanvasScreen),
          matchesGoldenFile(
            'goldens/editor_layout/desktop_${workspaceId}_$themeName.png',
          ),
        );
      });
    }
  }

  for (final (viewportName, size) in <(String, Size)>[
    ('standard', const Size(1440, 900)),
    ('wide', const Size(2048, 1280)),
  ]) {
    for (final workspaceId in desktopWorkspaces) {
      for (final (themeName, theme) in _themes) {
        testWidgets('desktop $workspaceId $viewportName $themeName layout', (
          tester,
        ) async {
          await _setViewport(tester, size, 1);
          await _pumpEditor(
            tester,
            theme: theme,
            platform: TargetPlatform.macOS,
            mode: WorkspaceMode.desktop,
            preferences: WorkspacePreferences(
              workspaceId: workspaceId,
              followDocumentType: false,
            ),
          );

          expect(find.bySemanticsLabel('Drawing canvas'), findsOneWidget);
          final exception = tester.takeException();
          expect(
            exception,
            isNull,
            reason: _exceptionDetails(
              exception,
              'desktop $workspaceId / $viewportName / $themeName',
            ),
          );
          await expectLater(
            find.byType(CanvasScreen),
            matchesGoldenFile(
              'goldens/editor_layout/desktop_${workspaceId}_${viewportName}_$themeName.png',
            ),
          );
        });
      }
    }
  }

  testWidgets('compact Mac desktop keeps a usable canvas width', (
    tester,
  ) async {
    await _setViewport(tester, const Size(800, 632), 2);
    await _pumpEditor(
      tester,
      theme: InkTheme.dark(),
      platform: TargetPlatform.macOS,
      mode: WorkspaceMode.desktop,
      preferences: const WorkspacePreferences(followDocumentType: false),
    );

    final canvas = find.bySemanticsLabel('Drawing canvas');
    expect(canvas, findsOneWidget);
    expect(
      tester.getRect(canvas).width,
      greaterThan(400),
      reason: 'compact desktop must not squeeze the canvas between two docks',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('resizable desktop docks preserve the minimum canvas width', (
    tester,
  ) async {
    await _setViewport(tester, const Size(1200, 800), 1);
    await _pumpEditor(
      tester,
      theme: InkTheme.dark(),
      platform: TargetPlatform.macOS,
      mode: WorkspaceMode.desktop,
      preferences: const WorkspacePreferences(
        dockWidth: 480,
        leftDockWidth: 480,
        followDocumentType: false,
      ),
    );

    final canvas = find.bySemanticsLabel('Drawing canvas');
    expect(canvas, findsOneWidget);
    expect(
      tester.getRect(canvas).width,
      greaterThanOrEqualTo(400),
      reason: 'the dock widths must yield to the canvas on smaller desktops',
    );
    expect(tester.takeException(), isNull);
  });

  for (final tabletMode in TabletWorkspaceMode.values) {
    for (final (themeName, theme) in _themes) {
      testWidgets('tablet ${tabletMode.name} $themeName layout', (
        tester,
      ) async {
        await _setViewport(tester, const Size(834, 1194), 2);
        await _pumpEditor(
          tester,
          theme: theme,
          platform: TargetPlatform.iOS,
          mode: WorkspaceMode.expandedTouch,
          preferences: WorkspacePreferences(
            tabletMode: tabletMode,
            followDocumentType: false,
          ),
        );

        expect(find.bySemanticsLabel('Drawing canvas'), findsOneWidget);
        if (tabletMode == TabletWorkspaceMode.simple) {
          expect(find.bySemanticsLabel('Brush size'), findsOneWidget);
          expect(find.bySemanticsLabel('Brush opacity'), findsOneWidget);
          expect(find.bySemanticsLabel('Undo'), findsOneWidget);
          expect(find.bySemanticsLabel('Eyedropper'), findsOneWidget);
        } else {
          expect(find.bySemanticsLabel('Studio tool rail'), findsOneWidget);
          expect(find.byTooltip('Close Layers'), findsOneWidget);
        }
        final exception = tester.takeException();
        expect(
          exception,
          isNull,
          reason: _exceptionDetails(
            exception,
            'tablet ${tabletMode.name} / $themeName',
          ),
        );
        await expectLater(
          find.byType(CanvasScreen),
          matchesGoldenFile(
            'goldens/editor_layout/tablet_${tabletMode.name}_$themeName.png',
          ),
        );
      });
    }
  }

  for (final (themeName, theme) in _themes) {
    testWidgets('tablet Simple landscape $themeName layout', (tester) async {
      await _setViewport(tester, const Size(1194, 834), 2);
      await _pumpEditor(
        tester,
        theme: theme,
        platform: TargetPlatform.iOS,
        mode: WorkspaceMode.expandedTouch,
        preferences: const WorkspacePreferences(
          tabletMode: TabletWorkspaceMode.simple,
          followDocumentType: false,
        ),
      );

      expect(find.bySemanticsLabel('Drawing canvas'), findsOneWidget);
      expect(find.bySemanticsLabel('Brush size'), findsOneWidget);
      expect(find.bySemanticsLabel('Undo'), findsOneWidget);
      final exception = tester.takeException();
      expect(
        exception,
        isNull,
        reason: _exceptionDetails(
          exception,
          'tablet Simple landscape / $themeName',
        ),
      );
      await expectLater(
        find.byType(CanvasScreen),
        matchesGoldenFile(
          'goldens/editor_layout/tablet_simple_landscape_$themeName.png',
        ),
      );
    });
  }

  for (final tabletMode in TabletWorkspaceMode.values) {
    for (final (themeName, theme) in _themes) {
      testWidgets('Android tablet ${tabletMode.name} $themeName layout', (
        tester,
      ) async {
        await _setViewport(tester, const Size(1280, 800), 1);
        await _pumpEditor(
          tester,
          theme: theme,
          platform: TargetPlatform.android,
          mode: WorkspaceMode.expandedTouch,
          preferences: WorkspacePreferences(
            tabletMode: tabletMode,
            followDocumentType: false,
          ),
        );

        expect(find.bySemanticsLabel('Drawing canvas'), findsOneWidget);
        if (tabletMode == TabletWorkspaceMode.simple) {
          expect(find.bySemanticsLabel('Brush size'), findsOneWidget);
          expect(find.bySemanticsLabel('Undo'), findsOneWidget);
        } else {
          expect(find.bySemanticsLabel('Studio tool rail'), findsOneWidget);
          expect(find.byTooltip('Close Layers'), findsOneWidget);
        }
        final exception = tester.takeException();
        expect(
          exception,
          isNull,
          reason: _exceptionDetails(
            exception,
            'Android tablet ${tabletMode.name} / $themeName',
          ),
        );
        await expectLater(
          find.byType(CanvasScreen),
          matchesGoldenFile(
            'goldens/editor_layout/android_tablet_${tabletMode.name}_$themeName.png',
          ),
        );
      });
    }
  }

  for (final (themeName, theme) in _themes) {
    testWidgets('tablet Studio landscape $themeName layout', (tester) async {
      await _setViewport(tester, const Size(1194, 834), 2);
      await _pumpEditor(
        tester,
        theme: theme,
        platform: TargetPlatform.iOS,
        mode: WorkspaceMode.expandedTouch,
        preferences: const WorkspacePreferences(
          tabletMode: TabletWorkspaceMode.studio,
          followDocumentType: false,
        ),
      );

      expect(find.bySemanticsLabel('Drawing canvas'), findsOneWidget);
      expect(find.bySemanticsLabel('Studio tool rail'), findsOneWidget);
      expect(find.byTooltip('Close Layers'), findsOneWidget);
      final exception = tester.takeException();
      expect(
        exception,
        isNull,
        reason: _exceptionDetails(
          exception,
          'tablet Studio landscape / $themeName',
        ),
      );
      await expectLater(
        find.byType(CanvasScreen),
        matchesGoldenFile(
          'goldens/editor_layout/tablet_studio_landscape_$themeName.png',
        ),
      );
    });
  }

  for (final (themeName, theme) in _themes) {
    testWidgets('phone simple $themeName layout', (tester) async {
      await _setViewport(tester, const Size(390, 844), 3);
      await _pumpEditor(
        tester,
        theme: theme,
        platform: TargetPlatform.iOS,
        mode: WorkspaceMode.compactTouch,
        // Phone layouts stay canvas-first even if a saved tablet preference
        // was left in Studio mode.
        preferences: const WorkspacePreferences(
          tabletMode: TabletWorkspaceMode.studio,
          followDocumentType: false,
        ),
      );

      expect(find.bySemanticsLabel('Drawing canvas'), findsOneWidget);
      expect(find.bySemanticsLabel('Gallery and documents'), findsOneWidget);
      expect(find.bySemanticsLabel('Brush size'), findsOneWidget);
      final exception = tester.takeException();
      expect(
        exception,
        isNull,
        reason: _exceptionDetails(exception, 'phone / $themeName'),
      );
      await expectLater(
        find.byType(CanvasScreen),
        matchesGoldenFile('goldens/editor_layout/phone_$themeName.png'),
      );
    });
  }

  testWidgets('tablet Studio switches between one touch palette at a time', (
    tester,
  ) async {
    await _setViewport(tester, const Size(834, 1194), 2);
    await _pumpEditor(
      tester,
      theme: InkTheme.dark(),
      platform: TargetPlatform.iOS,
      mode: WorkspaceMode.expandedTouch,
      preferences: const WorkspacePreferences(
        tabletMode: TabletWorkspaceMode.studio,
        followDocumentType: false,
      ),
    );

    expect(find.byTooltip('Close Layers'), findsOneWidget);
    await tester.tap(find.byTooltip('Brush presets'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Close Brush library'), findsOneWidget);
    expect(find.byTooltip('Close Layers'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  final scaledLayouts = <
    (String, Size, double, TargetPlatform, WorkspaceMode, WorkspacePreferences)
  >[
    for (final workspaceId in desktopWorkspaces)
      (
        'desktop_$workspaceId',
        const Size(1440, 900),
        1,
        TargetPlatform.macOS,
        WorkspaceMode.desktop,
        WorkspacePreferences(
          workspaceId: workspaceId,
          followDocumentType: false,
        ),
      ),
    for (final tabletMode in TabletWorkspaceMode.values)
      (
        'tablet_${tabletMode.name}',
        const Size(1194, 834),
        2,
        TargetPlatform.iOS,
        WorkspaceMode.expandedTouch,
        WorkspacePreferences(tabletMode: tabletMode, followDocumentType: false),
      ),
    (
      'phone_simple',
      const Size(390, 844),
      3,
      TargetPlatform.iOS,
      WorkspaceMode.compactTouch,
      const WorkspacePreferences(followDocumentType: false),
    ),
  ];
  for (final textScale in <double>[1.5, 2]) {
    final scaleName = textScale == 1.5 ? '150' : '200';
    for (final (layoutName, size, pixelRatio, platform, mode, preferences)
        in scaledLayouts) {
      for (final (themeName, theme) in _themes) {
        testWidgets('$layoutName $themeName text $scaleName layout', (
          tester,
        ) async {
          await _setViewport(tester, size, pixelRatio);
          await _pumpEditor(
            tester,
            theme: theme,
            platform: platform,
            mode: mode,
            preferences: preferences,
            textScale: textScale,
          );

          expect(find.bySemanticsLabel('Drawing canvas'), findsOneWidget);
          final exception = tester.takeException();
          expect(
            exception,
            isNull,
            reason: _exceptionDetails(
              exception,
              '$layoutName / $themeName / text $textScale',
            ),
          );
          await expectLater(
            find.byType(CanvasScreen),
            matchesGoldenFile(
              'goldens/editor_layout/${layoutName}_${themeName}_text_$scaleName.png',
            ),
          );
        });
      }
    }
  }

  testWidgets('large text keeps essential editor controls available', (
    tester,
  ) async {
    final cases =
        <(Size, double, TargetPlatform, WorkspaceMode, WorkspacePreferences)>[
          (
            const Size(1024, 640),
            2,
            TargetPlatform.macOS,
            WorkspaceMode.desktop,
            const WorkspacePreferences(
              workspaceId: 'illustration',
              followDocumentType: false,
            ),
          ),
          for (final mode in TabletWorkspaceMode.values)
            (
              const Size(834, 1194),
              2,
              TargetPlatform.iOS,
              WorkspaceMode.expandedTouch,
              WorkspacePreferences(tabletMode: mode, followDocumentType: false),
            ),
          (
            const Size(390, 844),
            3,
            TargetPlatform.iOS,
            WorkspaceMode.compactTouch,
            const WorkspacePreferences(followDocumentType: false),
          ),
        ];
    for (final textScale in <double>[1.5, 2]) {
      for (final (size, ratio, platform, mode, preferences) in cases) {
        for (final (_, theme) in _themes) {
          await _setViewport(tester, size, ratio);
          await _pumpEditor(
            tester,
            theme: theme,
            platform: platform,
            mode: mode,
            preferences: preferences,
            textScale: textScale,
          );
          expect(find.bySemanticsLabel('Drawing canvas'), findsOneWidget);
          final exception = tester.takeException();
          expect(
            exception,
            isNull,
            reason: _exceptionDetails(
              exception,
              '$platform ${mode.name}, text scale $textScale',
            ),
          );
          await tester.pumpWidget(const SizedBox.shrink());
        }
      }
    }
  });
}

Future<void> _setViewport(
  WidgetTester tester,
  Size logicalSize,
  double devicePixelRatio,
) async {
  tester.view.devicePixelRatio = devicePixelRatio;
  tester.view.physicalSize = logicalSize * devicePixelRatio;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pump();
}

Future<void> _pumpEditor(
  WidgetTester tester, {
  required ThemeData theme,
  required TargetPlatform platform,
  required WorkspaceMode mode,
  required WorkspacePreferences preferences,
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme.copyWith(
        textTheme: theme.textTheme.apply(fontFamily: 'Roboto'),
      ),
      home: Builder(
        builder:
            (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: CanvasScreen(
                engine: InMemoryEngineApi(),
                comicWorkspaceController: _VisualComicController(),
                targetPlatform: platform,
                desktopDockEnabled: true,
                workspaceModeOverride: mode,
                workspacePreferences: preferences,
                nativePointerPacketsOverride: const Stream.empty(),
                nativePointerReadyOverride: const Stream.empty(),
                nativePencilCommandsOverride: const Stream.empty(),
                nativeCanvasDiagnosticEventsOverride: const Stream.empty(),
              ),
            ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 200));
}

Future<void> _loadVisualFonts() async {
  final flutterRoot =
      Platform.environment['FLUTTER_ROOT'] ??
      Directory(
        Platform.resolvedExecutable,
      ).parent.parent.parent.parent.parent.path;
  final fonts = Directory('$flutterRoot/bin/cache/artifacts/material_fonts');
  final roboto = await File('${fonts.path}/Roboto-Regular.ttf').readAsBytes();
  final icons =
      await File('${fonts.path}/MaterialIcons-Regular.otf').readAsBytes();
  await (FontLoader('Roboto')
    ..addFont(Future<ByteData>.value(ByteData.sublistView(roboto)))).load();
  await (FontLoader('MaterialIcons')
    ..addFont(Future<ByteData>.value(ByteData.sublistView(icons)))).load();
}

String _exceptionDetails(Object? exception, String scenario) {
  final diagnostics =
      exception is FlutterError
          ? exception.diagnostics.map((item) => item.toStringDeep()).join('\n')
          : exception.toString();
  return '$diagnostics at $scenario';
}
