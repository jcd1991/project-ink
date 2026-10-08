import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show ValueListenable, ValueNotifier, debugPrint;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:project_ink/bridge/engine_api.dart';
import 'package:project_ink/canvas/canvas_screen.dart';
import 'package:project_ink/canvas/live_preview_controller.dart';
import 'package:project_ink/design_system/ink_components.dart'
    show InkLayerRow, InkPropertySlider;
import 'package:project_ink/documents/document_picker.dart';
import 'package:project_ink/tools/brush_library_panel.dart'
    show BrushLibraryPanel;
import 'package:project_ink/tools/brush_library.dart'
    show BrushPreviewPointView;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'macOS illustration alpha layers, brushes, and PNG survive save and reopen',
    (tester) async {
      tester.view.physicalSize = const Size(1800, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final temporary = await _createAlphaTemporaryDirectory(
        'project-ink-illustration-alpha-',
      );
      addTearDown(() async {
        const preserveFixtures = bool.fromEnvironment(
          'PROJECT_INK_PRESERVE_ALPHA_FIXTURES',
        );
        if (!preserveFixtures && await temporary.exists()) {
          await temporary.delete(recursive: true);
        }
      });

      final projectPath = '${temporary.path}/illustration.inkproj';
      final pngPath = '${temporary.path}/illustration.png';
      final picker = _WorkflowDocumentPicker(projectPath, pngPath);
      final engine = await FrbEngineApi.create(
        widthPx: 512,
        heightPx: 512,
        dpi: 144,
      );
      FrbEngineApi? reopened;

      try {
        await tester.pumpWidget(
          MaterialApp(
            home: CanvasScreen(
              engine: engine,
              documentPicker: picker,
              targetPlatform: TargetPlatform.macOS,
              desktopDockEnabled: true,
              livePreviewControllerFactory: (_) => _NoopLivePreviewController(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final originalLayers = await engine.layerSummaries();
        expect(originalLayers, isNotEmpty);
        final baseLayer = originalLayers.firstWhere(
          (layer) => layer.kind == 'Raster',
        );

        // Create both layers through the canvas layer panel.
        await _tapEditorMenuAction(tester, 'Layers');
        await _tapAddPaintLayer(tester);
        var layerSummaries = await engine.layerSummaries();
        final targetLayerId =
            layerSummaries
                .firstWhere(
                  (layer) => !originalLayers.any((old) => old.id == layer.id),
                )
                .id;
        await _tapAddPaintLayer(tester);
        layerSummaries = await engine.layerSummaries();
        final disposableLayerId =
            layerSummaries
                .firstWhere(
                  (layer) =>
                      layer.id != baseLayer.id && layer.id != targetLayerId,
                )
                .id;

        // Rename and reorder the selected paint layer in the panel.
        await _openLayerOptions(tester, targetLayerId);
        await tester.ensureVisible(find.text('Rename').last);
        await tester.tap(find.text('Rename').last);
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, 'Alpha Target');
        await tester.tap(find.widgetWithText(FilledButton, 'Rename').last);
        await tester.pumpAndSettle();
        expect(
          (await engine.layerSummaries())
              .singleWhere((layer) => layer.id == targetLayerId)
              .name,
          'Alpha Target',
        );

        final orderBeforeMove =
            (await engine.layerSummaries())
                .singleWhere((layer) => layer.id == targetLayerId)
                .order;
        await _openLayerOptions(tester, targetLayerId);
        await tester.ensureVisible(find.text('Move up'));
        await tester.tap(find.text('Move up'));
        await tester.pumpAndSettle();
        expect(
          (await engine.layerSummaries())
              .singleWhere((layer) => layer.id == targetLayerId)
              .order,
          isNot(orderBeforeMove),
        );
        final targetOrderAfterMove =
            (await engine.layerSummaries())
                .singleWhere((layer) => layer.id == targetLayerId)
                .order;

        // Hide and show the layer, then commit an opacity edit from its
        // properties sheet.
        await tester.tap(_layerVisibilityButton(targetLayerId, 'Hide'));
        await tester.pumpAndSettle();
        expect(
          (await engine.layerSummaries())
              .singleWhere((layer) => layer.id == targetLayerId)
              .visible,
          isFalse,
        );
        await tester.tap(_layerVisibilityButton(targetLayerId, 'Show'));
        await tester.pumpAndSettle();

        await _openLayerOpacity(tester, targetLayerId);
        expect(find.text('Opacity · Alpha Target'), findsOneWidget);
        final opacity = find.byType(Slider).last;
        await tester.ensureVisible(opacity);
        await tester.drag(opacity, const Offset(42, 0));
        await tester.pumpAndSettle();
        final opacityAfterEdit =
            (await engine.layerSummaries())
                .singleWhere((layer) => layer.id == targetLayerId)
                .opacity;
        expect(opacityAfterEdit, greaterThan(0));
        expect(opacityAfterEdit, lessThan(1));
        await tester.tapAt(const Offset(700, 96));
        await tester.pumpAndSettle();

        // Select the target through the UI and verify the real pointer path
        // commits pixels to that layer only.
        final targetRow = _layerRow(targetLayerId);
        await tester.ensureVisible(targetRow);
        await tester.tap(targetRow);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<InkLayerRow>(
                find.descendant(
                  of: targetRow,
                  matching: find.byType(InkLayerRow),
                ),
              )
              .selected,
          isTrue,
          reason: 'brush workflow starts on the selected raster layer',
        );
        final afterDeleteUndo = await _layerPixelDigest(engine, targetLayerId);
        await _drawCanvasStroke(tester, const Offset(165, -150));
        expect(
          await _layerPixelDigest(engine, targetLayerId),
          isNot(afterDeleteUndo),
          reason: 'the selected layer remains drawable after delete and undo',
        );
        final targetBefore = await _layerPixelDigest(engine, targetLayerId);
        final baseBefore = await _layerPixelDigest(engine, baseLayer.id);
        await _drawCanvasStroke(tester, const Offset(-34, -92));
        final targetAfterFirstStroke = await _layerPixelDigest(
          engine,
          targetLayerId,
        );
        expect(targetAfterFirstStroke, isNot(targetBefore));
        expect(
          await _layerPixelDigest(engine, baseLayer.id),
          baseBefore,
          reason: 'drawing on Alpha Target leaves the base raster untouched',
        );

        // Delete one layer from its options and undo through the editor menu.
        await _openLayerOptions(tester, disposableLayerId);
        await tester.drag(find.byType(ListView).last, const Offset(0, -700));
        await tester.pumpAndSettle();
        final deleteItem = find.textContaining('Delete layer').last;
        await tester.ensureVisible(deleteItem);
        await tester.tap(deleteItem);
        await tester.pumpAndSettle();
        expect(
          (await engine.layerSummaries()).any(
            (layer) => layer.id == disposableLayerId,
          ),
          isFalse,
        );
        await _tapEditorMenuAction(tester, 'Undo');
        expect(
          (await engine.layerSummaries()).any(
            (layer) => layer.id == disposableLayerId,
          ),
          isTrue,
          reason: 'Undo restores the deleted raster layer',
        );
        await tester.tap(_layerRow(targetLayerId));
        await tester.pumpAndSettle();

        // Select two built-in families in the real brush panel. Change each
        // size through the brush control and set distinct Rust-owned colors.
        await _tapEditorMenuAction(tester, 'Brushes');
        final builtins = await engine.builtinBrushes();
        final sketchBrush = builtins.firstWhere(
          (brush) => brush.isBuiltin && brush.tags.contains('sketch'),
        );
        final inkBrush = builtins.firstWhere(
          (brush) => brush.isBuiltin && brush.tags.contains('ink'),
        );
        for (final entry in [
          (
            brush: sketchBrush,
            size: 22.0,
            color: (red: 255, green: 0, blue: 0),
            offset: const Offset(-150, -140),
          ),
          (
            brush: inkBrush,
            size: 96.0,
            color: (red: 0, green: 0, blue: 255),
            offset: const Offset(120, 130),
          ),
        ]) {
          await _searchBrush(tester, entry.brush.name);
          final row = find.byKey(ValueKey('brush-row-${entry.brush.id}'));
          await tester.ensureVisible(row);
          await tester.tap(row);
          await tester.pumpAndSettle();
          await _scrollBrushLibraryToEditor(tester);
          final beforeFamilyMark = await _layerPixelDigest(
            engine,
            targetLayerId,
          );
          await _drawCanvasStroke(tester, const Offset(-145, 55));
          expect(
            await _layerPixelDigest(engine, targetLayerId),
            isNot(beforeFamilyMark),
            reason: '${entry.brush.name} can draw before size editing',
          );
          if (_brushSizeSlider().evaluate().isEmpty) {
            final edit = find.byTooltip('Edit brush');
            await tester.ensureVisible(edit);
            await tester.tap(edit);
            await tester.pumpAndSettle();
          }
          await _setBrushSize(tester, entry.size);
          final updatedBrush = (await engine.builtinBrushes()).singleWhere(
            (brush) => brush.id == entry.brush.id,
          );
          expect(
            updatedBrush.diameterPx,
            greaterThan(entry.brush.diameterPx),
            reason: '${entry.brush.name} size control commits to Rust',
          );
          await _searchBrush(tester, entry.brush.name);
          await tester.ensureVisible(row);
          await tester.tap(row);
          await tester.pumpAndSettle();
          await _chooseRgbColor(
            tester,
            red: entry.color.red,
            green: entry.color.green,
            blue: entry.color.blue,
          );
          final beforeBrushPixels = <int, int>{};
          for (final layer in await engine.layerSummaries()) {
            beforeBrushPixels[layer.id] = await _layerPixelDigest(
              engine,
              layer.id,
            );
          }
          await _drawCanvasStroke(tester, entry.offset);
          final changedLayers = <String>[];
          for (final layer in await engine.layerSummaries()) {
            final after = await _layerPixelDigest(engine, layer.id);
            if (after != beforeBrushPixels[layer.id]) {
              changedLayers.add('${layer.name}(${layer.id})');
            }
          }
          debugPrint(
            'ALPHA_WORKFLOW_STROKE brush=${entry.brush.name} '
            'changedLayers=$changedLayers',
          );
          final pixels = await _layerPixelDigest(engine, targetLayerId);
          expect(
            pixels,
            isNot(beforeBrushPixels[targetLayerId]),
            reason: '${entry.brush.name} commits a rendered mark',
          );
        }

        // Duplicate a built-in and use the custom editor's Discard and Save
        // actions against real Rust brush drafts.
        await _searchBrush(tester, inkBrush.name);
        final selectedInkRow = find.byKey(ValueKey('brush-row-${inkBrush.id}'));
        await tester.ensureVisible(selectedInkRow);
        await tester.tap(selectedInkRow);
        await tester.pumpAndSettle();
        await _scrollBrushLibraryToTop(tester);
        final brushActions = find.byTooltip('Brush actions');
        await tester.ensureVisible(brushActions);
        await tester.tap(brushActions);
        await tester.pumpAndSettle();
        final duplicateBrush = find.text('Duplicate brush').last;
        await tester.ensureVisible(duplicateBrush);
        await tester.tap(duplicateBrush);
        await tester.pumpAndSettle();
        final customBrush = (await engine.builtinBrushes()).firstWhere(
          (brush) => !brush.isBuiltin && brush.name.contains(inkBrush.name),
        );
        final customId = customBrush.id;
        final initialPreview = await _renderBrushPreview(engine, customId);
        await _searchBrush(tester, customBrush.name);
        final customRow = find.byKey(ValueKey('brush-row-$customId'));
        await tester.ensureVisible(customRow);
        await tester.tap(customRow);
        await tester.pumpAndSettle();
        await _scrollBrushLibraryToEditor(tester);
        await _setCustomBrushEditorOpen(tester, true);
        await _scrollBrushLibraryToEditor(tester);

        final originalCustomSize = customBrush.diameterPx;
        await _setBrushSize(tester, _differentBrushSize(originalCustomSize));
        await _waitForBrushDraft(tester);
        final cancelBrushEdit = find.byKey(const ValueKey('cancel-brush-edit'));
        await _scrollBrushLibraryUntilBuilt(tester, cancelBrushEdit);
        await tester.ensureVisible(cancelBrushEdit);
        await tester.tap(cancelBrushEdit);
        await tester.pumpAndSettle();
        expect(
          (await engine.builtinBrushes())
              .singleWhere((brush) => brush.id == customId)
              .diameterPx,
          closeTo(originalCustomSize, 0.001),
          reason: 'Discard leaves the committed custom brush unchanged',
        );
        expect(
          await _renderBrushPreview(engine, customId),
          initialPreview,
          reason: 'Discard leaves the rendered custom brush unchanged',
        );

        final currentCustom = (await engine.builtinBrushes()).singleWhere(
          (brush) => brush.id == customId,
        );
        await _setCustomBrushEditorOpen(tester, true);
        await _scrollBrushLibraryToEditor(tester);
        await _setBrushSize(
          tester,
          _differentBrushSize(currentCustom.diameterPx),
        );
        await _waitForBrushDraft(tester);
        final saveBrushEdit = find.byKey(const ValueKey('commit-brush-edit'));
        await _scrollBrushLibraryUntilBuilt(tester, saveBrushEdit);
        await tester.ensureVisible(saveBrushEdit);
        await tester.tap(saveBrushEdit);
        await tester.pumpAndSettle();
        final savedCustom = (await engine.builtinBrushes()).singleWhere(
          (brush) => brush.id == customId,
        );
        expect(savedCustom.diameterPx, greaterThan(currentCustom.diameterPx));
        expect(
          await _renderBrushPreview(engine, customId),
          isNot(initialPreview),
          reason: 'Save changes alters the Rust-rendered brush output',
        );

        // The deleted spare, renamed target, ordering, visibility, opacity,
        // strokes, and custom-brush edit all travel through the Save command.
        await _tapEditorMenuAction(tester, 'Save project');
        await _waitForFilesystemPath(tester, projectPath);
        expect(await Directory(projectPath).exists(), isTrue);
        expect(await File('$projectPath/manifest.json').exists(), isTrue);
        await tester.pumpWidget(const SizedBox.shrink());
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await engine.close();

        reopened = await FrbEngineApi.open(projectPath);
        final savedLayers = await reopened.layerSummaries();
        final savedTarget = savedLayers.singleWhere(
          (layer) => layer.id == targetLayerId,
        );
        expect(savedTarget.name, 'Alpha Target');
        expect(savedTarget.order, targetOrderAfterMove);
        expect(savedTarget.visible, isTrue);
        expect(savedTarget.opacity, closeTo(opacityAfterEdit, 0.02));
        expect(
          savedLayers.any((layer) => layer.id == disposableLayerId),
          isTrue,
          reason: 'the delete was undone before saving',
        );
        expect(
          (await reopened.builtinBrushes())
              .singleWhere((brush) => brush.id == customId)
              .diameterPx,
          closeTo(savedCustom.diameterPx, 0.001),
        );

        // Export from the reopened project through the editor's Export PNG
        // action, then inspect decoded pixels rather than only the file header.
        await tester.pumpWidget(
          MaterialApp(
            home: CanvasScreen(
              engine: reopened,
              documentPicker: picker,
              targetPlatform: TargetPlatform.macOS,
              desktopDockEnabled: true,
              livePreviewControllerFactory: (_) => _NoopLivePreviewController(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await _tapEditorMenuAction(tester, 'Export PNG');
        await _waitForFilesystemPath(tester, pngPath);
        expect(await File(pngPath).exists(), isTrue);
        final decoded = await _decodePng(File(pngPath));
        expect(decoded.width, 512);
        expect(decoded.height, 512);
        expect(
          decoded.rgba[(10 * decoded.width + 10) * 4 + 3],
          0,
          reason: 'the blank page corner remains transparent in PNG export',
        );
        final redPixels = _countRedPixels(decoded.rgba);
        final bluePixels = _countBluePixels(decoded.rgba);
        expect(redPixels, greaterThan(0), reason: 'sketch color exports');
        expect(
          bluePixels,
          greaterThan(redPixels),
          reason: 'larger ink size exports more blue pixels',
        );
        debugPrint(
          'ALPHA_WORKFLOW_ARTIFACT project=$projectPath png=$pngPath '
          'redPixels=$redPixels bluePixels=$bluePixels',
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (reopened != null) await reopened.close();
        await engine.close();
      }
    },
  );
}

Future<void> _tapAddPaintLayer(WidgetTester tester) async {
  final longLabel = find.text('Add paint layer');
  final addButton =
      longLabel.evaluate().isNotEmpty ? longLabel : find.text('Add');
  expect(addButton, findsOneWidget);
  await tester.tap(addButton);
  await tester.pumpAndSettle();
}

Finder _layerRow(int id) => find.byKey(ValueKey<int>(id));

Finder _brushSizeSlider() => find.descendant(
  of: find.byType(BrushLibraryPanel),
  matching: find.byWidgetPredicate(
    (widget) => widget is InkPropertySlider && widget.label == 'Size',
  ),
);

Future<void> _searchBrush(WidgetTester tester, String name) async {
  final library = _brushLibraryScrollView();
  await tester.drag(library, const Offset(0, 1800));
  await tester.pumpAndSettle();
  final search = find.byWidgetPredicate(
    (widget) =>
        widget is TextField && widget.decoration?.hintText == 'Search brushes',
  );
  expect(search, findsOneWidget);
  await tester.ensureVisible(search);
  await tester.enterText(search, name);
  await tester.pumpAndSettle();
}

Future<void> _setBrushSize(WidgetTester tester, double sizePx) async {
  final sizeControl = _brushSizeSlider().first;
  final slider = find.descendant(
    of: sizeControl,
    matching: find.byType(Slider),
  );
  await tester.ensureVisible(slider);
  final bounds = tester.getRect(slider);
  final fraction = math.log(sizePx / 0.25) / math.log(4096 / 0.25);
  const thumbInset = 12.0;
  await tester.tapAt(
    Offset(
      bounds.left + thumbInset + (bounds.width - thumbInset * 2) * fraction,
      bounds.center.dy,
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _chooseRgbColor(
  WidgetTester tester, {
  required int red,
  required int green,
  required int blue,
}) async {
  await _tapEditorMenuAction(tester, 'Color');
  final editMainColor = find.byTooltip('Edit Main color');
  await tester.ensureVisible(editMainColor);
  await tester.tap(editMainColor);
  await tester.pumpAndSettle();
  expect(find.text('Main color'), findsOneWidget);
  for (final entry in <(String, int)>[
    ('Red', red),
    ('Green', green),
    ('Blue', blue),
  ]) {
    final row =
        find
            .ancestor(of: find.text(entry.$1), matching: find.byType(Row))
            .first;
    final slider = find.descendant(of: row, matching: find.byType(Slider));
    await tester.ensureVisible(slider);
    final bounds = tester.getRect(slider);
    const thumbInset = 12.0;
    await tester.tapAt(
      Offset(
        bounds.left +
            thumbInset +
            (bounds.width - thumbInset * 2) * (entry.$2 / 255),
        bounds.center.dy,
      ),
    );
    await tester.pumpAndSettle();
  }
  await tester.tap(find.text('Apply').last);
  await tester.pumpAndSettle();
}

Future<void> _waitForFilesystemPath(WidgetTester tester, String path) async {
  for (var attempt = 0; attempt < 120; attempt++) {
    if (await FileSystemEntity.type(path) != FileSystemEntityType.notFound) {
      return;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump();
  }
  expect(
    await FileSystemEntity.type(path),
    isNot(FileSystemEntityType.notFound),
  );
}

Future<void> _scrollBrushLibraryToEditor(WidgetTester tester) async {
  await tester.drag(_brushLibraryScrollView(), const Offset(0, -1800));
  await tester.pumpAndSettle();
}

Future<void> _scrollBrushLibraryToTop(WidgetTester tester) async {
  await tester.drag(_brushLibraryScrollView(), const Offset(0, 1800));
  await tester.pumpAndSettle();
}

Future<void> _setCustomBrushEditorOpen(WidgetTester tester, bool open) async {
  final panelFinder = find.byType(BrushLibraryPanel);
  final panel = tester.widget<BrushLibraryPanel>(panelFinder);
  if (panel.library.editorOpen == open) return;
  final button = find.byTooltip(open ? 'Edit brush' : 'Close brush editor');
  await _scrollBrushLibraryUntilBuilt(tester, button);
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Future<void> _scrollBrushLibraryUntilBuilt(
  WidgetTester tester,
  Finder target,
) async {
  for (var attempt = 0; attempt < 12; attempt++) {
    if (target.evaluate().isNotEmpty) return;
    await tester.drag(_brushLibraryScrollView(), const Offset(0, 80));
    await tester.pumpAndSettle();
  }
  expect(target, findsOneWidget);
}

Future<void> _waitForBrushDraft(WidgetTester tester) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    final panel = tester.widget<BrushLibraryPanel>(
      find.byType(BrushLibraryPanel),
    );
    if (panel.hasUncommittedChanges) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump();
  }
  expect(
    tester
        .widget<BrushLibraryPanel>(find.byType(BrushLibraryPanel))
        .hasUncommittedChanges,
    isTrue,
  );
}

double _differentBrushSize(double current) =>
    current >= 2048 ? current / 2 : current * 2;

Finder _brushLibraryScrollView() =>
    find
        .descendant(
          of: find.byType(BrushLibraryPanel),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is ListView && widget.scrollDirection == Axis.vertical,
          ),
        )
        .first;

Future<void> _openLayerOptions(WidgetTester tester, int id) async {
  final options = find.descendant(
    of: _layerRow(id),
    matching: find.byTooltip('Layer options'),
  );
  await tester.ensureVisible(options);
  await tester.tap(options);
  await tester.pumpAndSettle();
}

Future<void> _openLayerOpacity(WidgetTester tester, int id) async {
  final row = _layerRow(id);
  await tester.ensureVisible(row);
  final center = tester.getCenter(row);
  final first = await tester.startGesture(
    center - const Offset(6, 0),
    pointer: 121,
    kind: PointerDeviceKind.touch,
  );
  final second = await tester.startGesture(
    center + const Offset(6, 0),
    pointer: 122,
    kind: PointerDeviceKind.touch,
  );
  await tester.pump();
  await first.up();
  await second.up();
  await tester.pumpAndSettle();
}

Finder _layerVisibilityButton(int id, String action) => find.descendant(
  of: _layerRow(id),
  matching: find.byWidgetPredicate(
    (widget) =>
        widget is Tooltip &&
        (widget.message?.startsWith('$action layer;') ?? false),
  ),
);

Future<void> _tapEditorMenuAction(WidgetTester tester, String label) async {
  final menu = find.byTooltip('Menu menu');
  if (menu.evaluate().isNotEmpty) {
    await tester.tap(menu);
    await tester.pumpAndSettle();
    final action = find.text(label).last;
    expect(action, findsOneWidget);
    await tester.ensureVisible(action);
    await tester.tap(action);
    await tester.pumpAndSettle();
    await _completeSaveNameDialog(tester, label);
    return;
  }

  if (label == 'Undo') {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    return;
  }

  final directAction = switch (label) {
    'Layers' => find.byTooltip('Layers'),
    'Brushes' => find.byTooltip('Open brush library (B)'),
    'Color' => find.byTooltip(
      'Main and sub colors (X swaps, D resets, C opens color)',
    ),
    _ => find.byTooltip('More commands'),
  };
  expect(directAction, findsAtLeastNWidgets(1), reason: 'macOS action: $label');
  await tester.ensureVisible(directAction.last);
  await tester.tap(directAction.last);
  await tester.pumpAndSettle();
  if (label == 'Save project' || label == 'Export PNG') {
    final action = find.text(label).last;
    expect(action, findsOneWidget);
    await tester.ensureVisible(action);
    await tester.tap(action);
    await tester.pumpAndSettle();
    await _completeSaveNameDialog(tester, label);
  }
}

Future<void> _completeSaveNameDialog(
  WidgetTester tester,
  String actionLabel,
) async {
  if (actionLabel != 'Save project') return;
  final nameField = find.byWidgetPredicate(
    (widget) =>
        widget is TextField && widget.decoration?.labelText == 'Project name',
  );
  if (nameField.evaluate().isEmpty) return;
  await tester.enterText(nameField, 'Illustration Alpha');
  await tester.tap(find.widgetWithText(FilledButton, 'Save').last);
  await tester.pumpAndSettle();
}

Future<void> _drawCanvasStroke(WidgetTester tester, Offset offset) async {
  final canvas = find.bySemanticsLabel('Drawing canvas');
  expect(canvas, findsOneWidget);
  final bounds = tester.getRect(canvas);
  final midpoint = bounds.center + offset;
  final start = midpoint - const Offset(60, 0);
  final finish = midpoint + const Offset(60, 0);
  final gesture = await tester.startGesture(
    start,
    kind: PointerDeviceKind.mouse,
  );
  for (var index = 1; index <= 36; index++) {
    final fraction = index / 36;
    await gesture.moveTo(Offset.lerp(start, finish, fraction)!);
    if (index % 6 == 0) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }
  await gesture.up();
  for (var frame = 0; frame < 20; frame++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<int> _layerPixelDigest(EngineApi engine, int layerId) async {
  var hash = 0x811c9dc5;
  for (var y = 0; y < 2; y++) {
    for (var x = 0; x < 2; x++) {
      final tile = await engine.readTile(layer: layerId, x: x, y: y);
      for (final byte in tile) {
        hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
      }
    }
  }
  return hash;
}

Future<Uint8List> _renderBrushPreview(EngineApi engine, int brushId) =>
    engine.renderBrushPreview(
      brushId: brushId,
      width: 64,
      height: 48,
      points: const <BrushPreviewPointView>[
        BrushPreviewPointView(x: 8, y: 24, pressure: 0.8),
        BrushPreviewPointView(x: 18, y: 24, pressure: 0.8),
        BrushPreviewPointView(x: 28, y: 24, pressure: 0.8),
        BrushPreviewPointView(x: 38, y: 24, pressure: 0.8),
        BrushPreviewPointView(x: 48, y: 24, pressure: 0.8),
        BrushPreviewPointView(x: 56, y: 24, pressure: 0.8),
      ],
    );

Future<_DecodedPng> _decodePng(File file) async {
  final codec = await ui.instantiateImageCodec(await file.readAsBytes());
  try {
    final frame = await codec.getNextFrame();
    try {
      final data = await frame.image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (data == null) throw StateError('PNG pixel decode returned no bytes');
      return _DecodedPng(
        width: frame.image.width,
        height: frame.image.height,
        rgba: Uint8List.fromList(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        ),
      );
    } finally {
      frame.image.dispose();
    }
  } finally {
    codec.dispose();
  }
}

int _countRedPixels(Uint8List rgba) {
  var count = 0;
  for (var index = 0; index < rgba.length; index += 4) {
    final red = rgba[index];
    final green = rgba[index + 1];
    final blue = rgba[index + 2];
    if (rgba[index + 3] > 32 &&
        red > 100 &&
        red > green * 1.5 &&
        red > blue * 1.5) {
      count++;
    }
  }
  return count;
}

int _countBluePixels(Uint8List rgba) {
  var count = 0;
  for (var index = 0; index < rgba.length; index += 4) {
    final red = rgba[index];
    final green = rgba[index + 1];
    final blue = rgba[index + 2];
    if (rgba[index + 3] > 32 &&
        blue > 100 &&
        blue > red * 1.5 &&
        blue > green * 1.5) {
      count++;
    }
  }
  return count;
}

Future<Directory> _createAlphaTemporaryDirectory(String prefix) async {
  const configuredRoot = String.fromEnvironment(
    'PROJECT_INK_TEST_DOCUMENTS_PATH',
  );
  if (configuredRoot.isEmpty) return Directory.systemTemp.createTemp(prefix);
  final root = Directory(configuredRoot);
  await root.create(recursive: true);
  return root.createTemp(prefix);
}

class _DecodedPng {
  const _DecodedPng({
    required this.width,
    required this.height,
    required this.rgba,
  });

  final int width;
  final int height;
  final Uint8List rgba;
}

class _WorkflowDocumentPicker implements DocumentPicker {
  const _WorkflowDocumentPicker(this.projectPath, this.pngPath);

  final String projectPath;
  final String pngPath;

  @override
  Future<String?> openProject() async => null;

  @override
  Future<String?> saveProject({
    String suggestedName = 'untitled.inkproj',
  }) async => projectPath;

  @override
  Future<String?> exportPng({String suggestedName = 'untitled.png'}) async =>
      pngPath;
}

class _NoopLivePreviewController implements LivePreviewController {
  final ValueNotifier<int?> _textureId = ValueNotifier<int?>(null);
  final ValueNotifier<bool> _gpuFrameReady = ValueNotifier<bool>(false);

  @override
  ValueListenable<int?> get textureId => _textureId;

  @override
  ValueListenable<bool> get gpuFrameReady => _gpuFrameReady;

  @override
  void markInputPending({bool strokeStart = false}) {}

  @override
  void synchronizeViewport({
    required Size viewportSize,
    required double devicePixelRatio,
    required Offset pan,
    required double scale,
    required double rotation,
    required bool mirrored,
    required int documentWidth,
    required int documentHeight,
  }) {}

  @override
  void pump() {}

  @override
  Future<void> acknowledge(StrokeAcknowledgement acknowledgement) async {}

  @override
  Future<void> cancelAllStrokes() async {}

  @override
  Future<void> dispose() async {
    _textureId.dispose();
    _gpuFrameReady.dispose();
  }
}
