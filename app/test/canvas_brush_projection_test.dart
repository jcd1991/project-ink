import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/bridge/engine_api.dart';
import 'package:project_ink/canvas/canvas_brush_projection.dart';
import 'package:project_ink/tools/brush_library.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('maps Rust summaries and applies the current active brush', () async {
    final engine = InMemoryEngineApi();
    final library = BrushLibraryModel(const []);
    final colors = <int, Color>{};
    var activeBrushId = 7;
    Color? activeColor;
    var refreshCount = 0;
    final projection = CanvasBrushProjection(
      CanvasBrushProjectionHost(
        engine: () => engine,
        engineGeneration: () => 1,
        mounted: () => true,
        library: () => library,
        brushColors: () => colors,
        activeBrushId: () => activeBrushId,
        setActiveBrushId: (value) => activeBrushId = value,
        setActiveColor: (value) => activeColor = value,
        refreshLayerProjection: () async => refreshCount++,
      ),
    );

    await projection.load();

    expect(library.presets, isNotEmpty);
    expect(library.presets.any((brush) => brush.id == 7), isTrue);
    expect(library.selected?.id, 7);
    expect(library.selected?.family, BrushFamily.paint);
    expect(activeBrushId, 7);
    expect(colors[7], const Color(0xff202124));
    expect(activeColor, const Color(0xff202124));
    expect(refreshCount, 1);
  });

  test('discards a brush response from a replaced engine', () async {
    final pendingEngine = _PendingBrushEngine();
    EngineApi currentEngine = pendingEngine;
    final library = BrushLibraryModel(const []);
    var activeBrushId = 1;
    final projection = CanvasBrushProjection(
      CanvasBrushProjectionHost(
        engine: () => currentEngine,
        engineGeneration: () => 1,
        mounted: () => true,
        library: () => library,
        brushColors: () => <int, Color>{},
        activeBrushId: () => activeBrushId,
        setActiveBrushId: (value) => activeBrushId = value,
        setActiveColor: (_) {},
        refreshLayerProjection: () async {},
      ),
    );

    final staleLoad = projection.load();
    currentEngine = InMemoryEngineApi();
    await projection.load();
    final projectedCount = library.presets.length;
    pendingEngine.brushes.complete(const [
      BrushSummaryView(id: 99, name: 'Stale'),
    ]);
    await staleLoad;

    expect(library.presets, hasLength(projectedCount));
    expect(library.presets.any((brush) => brush.id == 99), isFalse);
  });
}

class _PendingBrushEngine extends InMemoryEngineApi {
  final Completer<List<BrushSummaryView>> brushes =
      Completer<List<BrushSummaryView>>();

  @override
  Future<List<BrushSummaryView>> builtinBrushes() => brushes.future;
}
