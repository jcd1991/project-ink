import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/app/project_ink_app.dart';
import 'package:project_ink/bridge/engine_api.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _LayerRenameEngine extends InMemoryEngineApi {
  String layerName = 'Ink';

  @override
  Future<List<LayerSummaryView>> layerSummaries() async => [
    LayerSummaryView(id: 1, name: layerName, kind: 'Raster'),
  ];

  @override
  Future<void> updateLayerPresentation({
    required int layerId,
    required String name,
    required String blendMode,
    required String groupMode,
    required int? labelRgba,
  }) async {
    if (layerId != 1) throw StateError('unexpected layer id: $layerId');
    layerName = name;
  }
}

void main() {
  testWidgets('renaming a layer refreshes its Rust-backed projection', (
    tester,
  ) async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    addTearDown(() => SharedPreferencesAsyncPlatform.instance = null);
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final engine = _LayerRenameEngine();
    await tester.pumpWidget(ProjectInkApp(engineOverride: engine));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Layers').first);
    await tester.pumpAndSettle();
    expect(find.text('Ink'), findsOneWidget);

    await tester.tap(find.byTooltip('Layer options').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Highlights');
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();

    expect(engine.layerName, 'Highlights');
    expect(find.text('Highlights'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
