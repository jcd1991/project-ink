import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/design_system/ink_theme.dart';
import 'package:project_ink/layers/layer_panel.dart';
import 'package:project_ink/layers/layer_panel_model.dart';

Uint8List _thumbnail(Color color) {
  final bytes = Uint8List(48 * 48 * 4);
  for (var y = 0; y < 48; y++) {
    for (var x = 0; x < 48; x++) {
      final index = (y * 48 + x) * 4;
      final painted =
          ((x - 16) * (x - 16) + (y - 30) * (y - 30) < 170) ||
          (x > 28 && x < 38 && y > 10 && y < 54);
      bytes[index] = painted ? (color.r * 255).round() : 0;
      bytes[index + 1] = painted ? (color.g * 255).round() : 0;
      bytes[index + 2] = painted ? (color.b * 255).round() : 0;
      bytes[index + 3] = painted ? 255 : 0;
    }
  }
  return bytes;
}

void main() {
  testWidgets('populated Layers panel Simple and Studio screenshots', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1024, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final selection =
        LayerSelectionModel()
          ..select(2)
          ..toggleSecondary(3);
    final artwork = _thumbnail(const Color(0xff6bc4ff));
    final layers = [
      const LayerView(
        id: 1,
        name: 'Character',
        kind: LayerKind.group,
        order: 4,
      ),
      LayerView(
        id: 2,
        name: 'Linework',
        kind: LayerKind.raster,
        parent: 1,
        order: 3,
        thumbnail: artwork,
        alphaLock: true,
        label: 0xffe53935,
      ),
      const LayerView(
        id: 3,
        name: 'Shadows',
        kind: LayerKind.raster,
        parent: 1,
        order: 2,
        clipping: true,
        opacity: .68,
      ),
      const LayerView(
        id: 4,
        name: 'Layer mask',
        kind: LayerKind.mask,
        parent: 1,
        order: 1,
      ),
      LayerView(
        id: 5,
        name: 'Reference',
        kind: LayerKind.raster,
        order: 0,
        thumbnail: artwork,
        reference: true,
      ),
    ];

    Future<void> showMode(bool studio) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: InkTheme.dark(),
          home: Scaffold(
            backgroundColor: const Color(0xff17191d),
            body: Center(
              child: SizedBox(
                width: 380,
                height: 760,
                child: RepaintBoundary(
                  key: ValueKey<String>(
                    studio ? 'layers-studio' : 'layers-simple',
                  ),
                  child: LayerPanel(
                    layers: layers,
                    selection: selection,
                    studioMode: studio,
                    onAddLayer: (_) {},
                    onLayerChanged: (_) {},
                    onPresentationChanged: (_) {},
                    onAdjustmentChanged: (_) {},
                    onMoveLayer: (_, _) {},
                    onDeleteLayer: (_) {},
                    onDuplicateLayer: (_) {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      expect(find.byType(RawImage), findsNWidgets(2));
      await expectLater(
        find.byKey(
          ValueKey<String>(studio ? 'layers-studio' : 'layers-simple'),
        ),
        matchesGoldenFile(
          studio
              ? 'goldens/layer_panel_studio.png'
              : 'goldens/layer_panel_simple.png',
        ),
      );
    }

    await showMode(false);
    await showMode(true);
  });
}
