import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/app/workspace_mode.dart';
import 'package:project_ink/app/workspace_preferences.dart';
import 'package:project_ink/bridge/engine_api.dart';
import 'package:project_ink/canvas/canvas_screen.dart';
import 'package:project_ink/canvas/pointer_packet.dart';
import 'package:project_ink/comics/comic_workspace.dart';
import 'package:project_ink/tools/brush_library.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FocusComicController extends ComicWorkspaceController {
  @override
  Future<void> ensureExampleLoaded() async {}
}

class _BrushSettingsCall {
  const _BrushSettingsCall(this.brushId, this.diameter, this.opacity);

  final int brushId;
  final double diameter;
  final double opacity;
}

class _RecordingBrushEngine extends InMemoryEngineApi {
  final settings = <_BrushSettingsCall>[];
  final colorBrushIds = <int>[];
  final packets = <Uint8List>[];

  @override
  Future<List<BrushSummaryView>> builtinBrushes() async =>
      (await super.builtinBrushes())
          .map(
            (brush) => BrushSummaryView(
              id: brush.id,
              name: brush.name,
              tags: brush.tags,
              diameterPx: brush.diameterPx,
              opacity: brush.opacity,
              colorRgba: brush.id == 2 ? 0xe53935ff : 0x202124ff,
            ),
          )
          .toList(growable: false);

  @override
  Future<void> updateBrushColor({
    required int brushId,
    required int red,
    required int green,
    required int blue,
    required int alpha,
  }) async {
    colorBrushIds.add(brushId);
    await super.updateBrushColor(
      brushId: brushId,
      red: red,
      green: green,
      blue: blue,
      alpha: alpha,
    );
  }

  @override
  Future<void> pushPointerPacket(Uint8List packet) async {
    packets.add(Uint8List.fromList(packet));
    await super.pushPointerPacket(packet);
  }

  @override
  Future<void> updateBrushSettings({
    required int brushId,
    required double diameter,
    required double opacity,
    required double spacing,
    required double smoothing,
    required double pressureSize,
    required double pressureOpacity,
    required double pressureCurve,
    required List<BrushCurvePointView> pressureCurvePoints,
    required double hardness,
    required double textureScale,
    required double scatter,
    required double rotationJitter,
    required double smudge,
    required double wetness,
  }) async {
    settings.add(_BrushSettingsCall(brushId, diameter, opacity));
    await super.updateBrushSettings(
      brushId: brushId,
      diameter: diameter,
      opacity: opacity,
      spacing: spacing,
      smoothing: smoothing,
      pressureSize: pressureSize,
      pressureOpacity: pressureOpacity,
      pressureCurve: pressureCurve,
      pressureCurvePoints: pressureCurvePoints,
      hardness: hardness,
      textureScale: textureScale,
      scatter: scatter,
      rotationJitter: rotationJitter,
      smudge: smudge,
      wetness: wetness,
    );
  }
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets(
    'Focus hides and restores the selected Studio palette across modes',
    (tester) async {
      await _setTabletViewport(tester);
      await _pumpWorkspace(
        tester,
        const WorkspacePreferences(
          tabletMode: TabletWorkspaceMode.studio,
          followDocumentType: false,
        ),
      );

      expect(find.byTooltip('Close Layers'), findsOneWidget);
      await tester.tap(find.byTooltip('Brush presets'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close Brush library'), findsOneWidget);

      await tester.tap(find.byTooltip('Canvas Focus'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close Brush library'), findsNothing);
      expect(find.byTooltip('Exit Focus'), findsOneWidget);

      await tester.tap(find.byTooltip('Focus controls'));
      await tester.pumpAndSettle();
      expect(find.text('Focus controls'), findsOneWidget);
      expect(find.text('Opacity'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Exit Focus'), findsOneWidget);

      await tester.tap(find.byTooltip('Exit Focus'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close Brush library'), findsOneWidget);

      await tester.tap(find.byTooltip('Switch to Simple mode'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close Brush library'), findsNothing);
      expect(find.bySemanticsLabel('Brush opacity'), findsOneWidget);

      await tester.tap(find.byTooltip('More drawing controls'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Switch to Studio mode'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close Brush library'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Simple opacity release commits the selected brush settings', (
    tester,
  ) async {
    await _setTabletViewport(tester);
    final engine = _RecordingBrushEngine();
    await _pumpWorkspace(
      tester,
      const WorkspacePreferences(
        tabletMode: TabletWorkspaceMode.simple,
        followDocumentType: false,
      ),
      engine: engine,
    );

    final opacity = find.bySemanticsLabel('Brush opacity');
    expect(opacity, findsOneWidget);
    final sliderRect = tester.getRect(opacity);
    await tester.tapAt(sliderRect.center + const Offset(0, -28));
    await tester.pump(const Duration(milliseconds: 30));
    await tester.pump(const Duration(milliseconds: 300));

    expect(engine.settings, isNotEmpty);
    expect(engine.settings.last.brushId, 1);
    expect(engine.settings.last.opacity, lessThan(1));
    expect(engine.settings.last.opacity, greaterThan(0));

    final size = find.bySemanticsLabel('Brush size');
    final sizeRect = tester.getRect(size);
    await tester.tapAt(sizeRect.center + const Offset(0, -28));
    await tester.pump(const Duration(milliseconds: 30));
    await tester.pump(const Duration(milliseconds: 300));
    expect(engine.settings.last.brushId, 1);
    expect(engine.settings.last.diameter, isNot(12));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Focus sliders commit to the selected brush', (tester) async {
    await _setTabletViewport(tester);
    final engine = _RecordingBrushEngine();
    await _pumpWorkspace(
      tester,
      const WorkspacePreferences(
        tabletMode: TabletWorkspaceMode.studio,
        followDocumentType: false,
      ),
      engine: engine,
    );

    await tester.tap(find.byTooltip('Canvas Focus'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Focus controls'));
    await tester.pumpAndSettle();

    final sizeSlider = find.byType(Slider).at(0);
    await tester.tapAt(tester.getRect(sizeSlider).center + const Offset(80, 0));
    await tester.pumpAndSettle();
    expect(engine.settings.last.brushId, 1);
    expect(engine.settings.last.diameter, isNot(12));

    final opacitySlider = find.byType(Slider).at(1);
    await tester.tapAt(
      tester.getRect(opacitySlider).center + const Offset(70, 0),
    );
    await tester.pumpAndSettle();
    expect(engine.settings.last.brushId, 1);
    expect(engine.settings.last.opacity, lessThan(1));
    expect(engine.settings.last.opacity, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Simple brush and color controls target the selected brush', (
    tester,
  ) async {
    await _setTabletViewport(tester);
    final engine = _RecordingBrushEngine();
    await _pumpWorkspace(
      tester,
      const WorkspacePreferences(
        tabletMode: TabletWorkspaceMode.simple,
        followDocumentType: false,
      ),
      engine: engine,
    );

    await tester.tap(find.byTooltip('More drawing controls'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Brush library'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('HB Sketch Pencil'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byTooltip('Close Brush library'));
    await tester.pumpAndSettle();

    final opacity = find.bySemanticsLabel('Brush opacity');
    await tester.tapAt(tester.getRect(opacity).center + const Offset(0, -28));
    await tester.pumpAndSettle();
    expect(engine.settings.last.brushId, 2);
    expect(engine.settings.last.opacity, lessThan(1));

    await tester.tap(find.byTooltip('Sub color'));
    await tester.pumpAndSettle();
    expect(find.text('Sub color'), findsOneWidget);
    await tester.tap(find.text('Apply'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(engine.colorBrushIds, isEmpty);

    await tester.tap(find.byTooltip('Main color'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(engine.colorBrushIds, contains(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Transparent paint uses the eraser packet flag', (tester) async {
    await _setTabletViewport(tester);
    final engine = _RecordingBrushEngine();
    await _pumpWorkspace(
      tester,
      const WorkspacePreferences(
        tabletMode: TabletWorkspaceMode.simple,
        followDocumentType: false,
      ),
      engine: engine,
    );

    await tester.tap(find.byTooltip('Transparent paint'));
    await tester.pumpAndSettle();

    final canvas = find.bySemanticsLabel('Drawing canvas');
    final point = tester.getCenter(canvas);
    final gesture = await tester.startGesture(
      point,
      kind: PointerDeviceKind.stylus,
    );
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.moveBy(const Offset(24, 12));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 200));

    expect(engine.packets, isNotEmpty);
    final data = ByteData.sublistView(engine.packets.first);
    expect(data.getUint16(8, Endian.little) & inkPointerEraser, isNot(0));
    expect(tester.takeException(), isNull);
  });
}

Future<void> _setTabletViewport(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1600, 2400);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _pumpWorkspace(
  WidgetTester tester,
  WorkspacePreferences preferences, {
  EngineApi? engine,
}) async {
  var activePreferences = preferences;
  await tester.pumpWidget(
    MaterialApp(
      home: StatefulBuilder(
        builder:
            (context, setState) => CanvasScreen(
              engine: engine ?? InMemoryEngineApi(),
              comicWorkspaceController: _FocusComicController(),
              targetPlatform: TargetPlatform.iOS,
              desktopDockEnabled: true,
              workspaceModeOverride: WorkspaceMode.expandedTouch,
              workspacePreferences: activePreferences,
              onWorkspacePreferencesChanged:
                  (next) => setState(() => activePreferences = next),
              nativePointerPacketsOverride: const Stream.empty(),
              nativePointerReadyOverride: const Stream.empty(),
              nativePencilCommandsOverride: const Stream.empty(),
              nativeCanvasDiagnosticEventsOverride: const Stream.empty(),
            ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 250));
}
