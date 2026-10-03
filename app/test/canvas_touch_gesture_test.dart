import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/bridge/engine_api.dart';
import 'package:project_ink/canvas/canvas_screen.dart';
import 'package:project_ink/documents/autosave_coordinator.dart';
import 'package:project_ink/app/workspace_preferences.dart';
import 'package:project_ink/layers/layer_panel.dart';
import 'package:project_ink/bridge/generated/api.dart' as rust;
import 'package:project_ink/design_system/ink_components.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _GestureEngine extends InMemoryEngineApi {
  bool historyWasTrimmed = false;
  int undoCount = 0;
  int redoCount = 0;
  int colorUpdateCount = 0;
  int brushDraftCount = 0;
  int rectangleSelectionCount = 0;
  int clearSelectionCount = 0;
  int invertSelectionCount = 0;
  final List<int> grownSelectionBy = <int>[];
  final List<int> shrunkSelectionBy = <int>[];
  final List<int> navigatedHistory = <int>[];
  List<int>? lastAppliedColor;

  @override
  Future<void> undo() async {
    undoCount++;
    await super.undo();
  }

  @override
  Future<void> redo() async {
    redoCount++;
    await super.redo();
  }

  @override
  Future<void> setActiveBrushColor({
    required int red,
    required int green,
    required int blue,
    required int alpha,
  }) async {
    colorUpdateCount++;
    lastAppliedColor = <int>[red, green, blue, alpha];
    await super.setActiveBrushColor(
      red: red,
      green: green,
      blue: blue,
      alpha: alpha,
    );
  }

  @override
  Future<int> beginBrushDraft(int brushId) async {
    brushDraftCount++;
    return super.beginBrushDraft(brushId);
  }

  @override
  Future<void> selectRectangle({
    required double x0,
    required double y0,
    required double x1,
    required double y1,
  }) async {
    rectangleSelectionCount++;
    await super.selectRectangle(x0: x0, y0: y0, x1: x1, y1: y1);
  }

  @override
  Future<void> clearSelection() async {
    clearSelectionCount++;
    await super.clearSelection();
  }

  @override
  Future<void> invertSelection() async {
    invertSelectionCount++;
    await super.invertSelection();
  }

  @override
  Future<void> growSelection(int radius) async {
    grownSelectionBy.add(radius);
    await super.growSelection(radius);
  }

  @override
  Future<void> shrinkSelection(int radius) async {
    shrunkSelectionBy.add(radius);
    await super.shrinkSelection(radius);
  }

  @override
  Future<rust.HistorySnapshotView> historySnapshot({int limit = 100}) async =>
      rust.HistorySnapshotView(
        revision: BigInt.from(revision),
        cursor: 2,
        wasTrimmed: historyWasTrimmed,
        entries: <rust.HistoryEntryView>[
          rust.HistoryEntryView(
            sequence: BigInt.from(0),
            kind: 'stroke',
            detail: 'Technical Pen stroke',
            applied: true,
          ),
          rust.HistoryEntryView(
            sequence: BigInt.from(1),
            kind: 'layer',
            detail: 'Rename layer',
            applied: true,
          ),
        ].take(limit).toList(growable: false),
      );

  @override
  Future<void> navigateHistory(int sequence) async {
    navigatedHistory.add(sequence);
  }
}

class _PrimaryLayerTargetEngine extends _GestureEngine {
  int? lastStrokeLayerId;
  int? lastFillLayerId;

  @override
  Future<List<LayerSummaryView>> layerSummaries() async => const [
    LayerSummaryView(id: 1, name: 'Primary', kind: 'Raster', order: 0),
    LayerSummaryView(id: 2, name: 'Secondary', kind: 'Raster', order: 1),
  ];

  @override
  Future<void> beginBrushStrokeOnLayer(int brushId, int layerId) async {
    lastStrokeLayerId = layerId;
    await super.beginBrushStrokeOnLayer(brushId, layerId);
  }

  @override
  Future<void> fillRegion({
    required int layerId,
    required int x,
    required int y,
    required int red,
    required int green,
    required int blue,
    required int alpha,
    required int tolerance,
    required int gap,
  }) async {
    lastFillLayerId = layerId;
  }
}

class _LayerVisibilityRefreshEngine extends _PrimaryLayerTargetEngine {
  bool secondaryVisible = true;
  TileUpdateBatch? pendingLayerInvalidation;
  final List<(int, int)> compositeSnapshotCoordinates = <(int, int)>[];

  @override
  Future<List<LayerSummaryView>> layerSummaries() async => [
    const LayerSummaryView(id: 1, name: 'Primary', kind: 'Raster', order: 0),
    LayerSummaryView(
      id: 2,
      name: 'Secondary',
      kind: 'Raster',
      order: 1,
      visible: secondaryVisible,
    ),
  ];

  @override
  Future<void> updateLayerProperties({
    required int layerId,
    required bool visible,
    required double opacity,
    required bool alphaLock,
    required bool clipping,
    required bool reference,
  }) async {
    if (layerId == 2) secondaryVisible = visible;
    final nextRevision = revision + 1;
    pendingLayerInvalidation = TileUpdateBatch(
      revision: nextRevision,
      fullRedraw: true,
      tiles: [TileUpdate(revision: nextRevision, layer: layerId, x: 0, y: 0)],
    );
  }

  @override
  Future<TileUpdateBatch> drainTileUpdates() async {
    final pending = pendingLayerInvalidation;
    pendingLayerInvalidation = null;
    return pending ?? TileUpdateBatch.empty(revision);
  }

  @override
  Future<CompositeTileSnapshot> readCompositeTilesSnapshot({
    required List<StrokeTileCoordinate> coordinates,
  }) async {
    compositeSnapshotCoordinates.addAll(
      coordinates.map((coordinate) => (coordinate.x, coordinate.y)),
    );
    return super.readCompositeTilesSnapshot(coordinates: coordinates);
  }
}

class _RejectingLayerEngine extends _GestureEngine {
  @override
  Future<void> updateLayerProperties({
    required int layerId,
    required bool visible,
    required double opacity,
    required bool alphaLock,
    required bool clipping,
    required bool reference,
  }) async {
    throw StateError('simulated layer rejection');
  }
}

class _LayerUndoEngine extends _GestureEngine {
  bool includeScratchLayer = true;
  int layerSnapshotCount = 0;

  @override
  Future<void> undo() async {
    includeScratchLayer = false;
    await super.undo();
  }

  @override
  Future<void> redo() async {
    includeScratchLayer = true;
    await super.redo();
  }

  @override
  Future<List<LayerSummaryView>> layerSummaries() async {
    layerSnapshotCount++;
    final layers = await super.layerSummaries();
    if (!includeScratchLayer) return layers;
    return <LayerSummaryView>[
      ...layers,
      const LayerSummaryView(id: 2, name: 'Scratch Layer', kind: 'Raster'),
    ];
  }
}

class _DuplicateGroupEngine extends _GestureEngine {
  final List<LayerSummaryView> summaries = <LayerSummaryView>[
    const LayerSummaryView(id: 1, name: 'Paint', kind: 'Raster', order: 0),
    const LayerSummaryView(id: 2, name: 'Ink Group', kind: 'Group', order: 1),
    const LayerSummaryView(
      id: 3,
      name: 'Ink strokes',
      kind: 'Raster',
      order: 0,
      parent: 2,
    ),
  ];
  int duplicateSource = 0;
  int projectionReads = 0;

  @override
  Future<List<LayerSummaryView>> layerSummaries() async {
    projectionReads++;
    return List<LayerSummaryView>.unmodifiable(summaries);
  }

  @override
  Future<int> duplicateLayer({required int layerId}) async {
    duplicateSource = layerId;
    summaries.addAll(const <LayerSummaryView>[
      LayerSummaryView(id: 4, name: 'Ink Group Copy', kind: 'Group', order: 2),
      LayerSummaryView(
        id: 5,
        name: 'Ink strokes',
        kind: 'Raster',
        order: 0,
        parent: 4,
      ),
    ]);
    return 4;
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('secondary layer selection never redirects brush strokes', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(2200, 1800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final engine = _PrimaryLayerTargetEngine();
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: engine,
          targetPlatform: TargetPlatform.macOS,
          desktopDockEnabled: true,
          workspacePreferences: const WorkspacePreferences(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final panel = tester.widget<LayerPanel>(find.byType(LayerPanel));
    expect(panel.selection.primaryId, 1);
    panel.selection.toggleSecondary(2);
    expect(panel.selection.selected, <int>{1, 2});

    final canvas = find.bySemanticsLabel('Drawing canvas');
    final gesture = await tester.startGesture(
      tester.getCenter(canvas),
      kind: PointerDeviceKind.stylus,
    );
    await gesture.moveBy(const Offset(12, 8));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(engine.lastStrokeLayerId, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('bucket fill uses the selected primary raster layer', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(820, 1180);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final engine = _PrimaryLayerTargetEngine();
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: engine,
          targetPlatform: TargetPlatform.android,
          workspacePreferences: const WorkspacePreferences(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Layers').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Secondary').first);
    await tester.pumpAndSettle();
    expect(
      tester.widget<LayerPanel>(find.byType(LayerPanel)).selection.primaryId,
      2,
    );

    await tester.tap(find.byTooltip('Layers'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Selections'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select and fill'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Bucket fill'));
    await tester.tap(find.text('Bucket fill'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Drawing canvas'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fill'));
    await tester.pumpAndSettle();

    expect(engine.lastFillLayerId, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('visibility full redraw composites hidden layer coordinates', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(2200, 1800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final engine = _LayerVisibilityRefreshEngine();
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: engine,
          targetPlatform: TargetPlatform.macOS,
          desktopDockEnabled: true,
          workspacePreferences: const WorkspacePreferences(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Layers').first);
    await tester.pumpAndSettle();
    await tester.tap(_layerVisibilityTooltip('Hide').first);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();

    expect(engine.secondaryVisible, isFalse);
    expect(engine.compositeSnapshotCoordinates, contains((0, 0)));
    expect(tester.takeException(), isNull);
  });

  testWidgets('two-finger tap invokes undo', (tester) async {
    final engine = _GestureEngine();
    await _pumpCanvas(tester, engine);

    await _tapWithFingers(tester, 2);

    expect(engine.undoCount, 1);
    expect(engine.redoCount, 0);
  });

  testWidgets('three-finger tap invokes redo', (tester) async {
    final engine = _GestureEngine();
    await _pumpCanvas(tester, engine);

    await _tapWithFingers(tester, 3);

    expect(engine.undoCount, 0);
    expect(engine.redoCount, 1);
  });

  testWidgets('desktop keyboard shortcuts share the undo and redo commands', (
    tester,
  ) async {
    final engine = _GestureEngine();
    await _pumpCanvas(tester, engine);
    await tester.tap(find.byType(CanvasScreen));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(engine.undoCount, 1);
    expect(engine.redoCount, 1);
  });

  testWidgets('four-finger tap toggles the interface', (tester) async {
    await _pumpCanvas(tester, _GestureEngine());
    expect(find.text('Untitled  •  Pen'), findsOneWidget);

    await _tapWithFingers(tester, 4);
    expect(find.text('Untitled  •  Pen'), findsNothing);

    await _tapWithFingers(tester, 4);
    expect(find.text('Untitled  •  Pen'), findsOneWidget);
  });

  testWidgets('toolbar identifies the active saved project by filename', (
    tester,
  ) async {
    await _pumpCanvas(
      tester,
      _GestureEngine(),
      activeDocumentPath: '/tmp/Comic Draft.inkproj',
    );

    expect(find.text('Comic Draft  •  Pen'), findsOneWidget);
  });

  testWidgets('toolbar handles native directory paths with trailing slash', (
    tester,
  ) async {
    await _pumpCanvas(
      tester,
      _GestureEngine(),
      activeDocumentPath: '/tmp/Comic Draft.inkproj/',
    );

    expect(find.text('Comic Draft  •  Pen'), findsOneWidget);
  });

  testWidgets('toolbar falls back to Untitled when no project path is active', (
    tester,
  ) async {
    await _pumpCanvas(tester, _GestureEngine());

    expect(find.text('Untitled  •  Pen'), findsOneWidget);
  });

  testWidgets('status bar distinguishes autosave lifecycle states', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final engine = _GestureEngine();

    Future<void> showStatus(AutosaveState? state) async {
      await _pumpCanvas(
        tester,
        engine,
        desktopDockEnabled: true,
        autosaveState: state,
      );
    }

    await showStatus(null);
    expect(find.text('Not saved'), findsOneWidget);
    await showStatus(
      const AutosaveState(
        dirty: true,
        hasUnsavedChanges: true,
        saving: false,
        lastError: null,
      ),
    );
    expect(find.text('Unsaved changes'), findsOneWidget);
    await showStatus(
      const AutosaveState(dirty: false, saving: true, lastError: null),
    );
    expect(find.text('Saving…'), findsOneWidget);
    await showStatus(
      const AutosaveState(
        dirty: true,
        hasUnsavedChanges: true,
        saving: true,
        lastError: null,
      ),
    );
    expect(find.text('Saving…  •  Changes pending'), findsOneWidget);
    await showStatus(
      const AutosaveState(
        dirty: true,
        hasUnsavedChanges: true,
        saving: false,
        lastError: 'disk unavailable',
      ),
    );
    expect(find.text('Save failed'), findsOneWidget);
    await showStatus(
      const AutosaveState(
        dirty: false,
        saving: false,
        lastError: null,
        hasSavedCheckpoint: true,
      ),
    );
    expect(find.text('Saved'), findsOneWidget);
  });

  testWidgets('transformed canvas is clipped before it reaches the UI chrome', (
    tester,
  ) async {
    await _pumpCanvas(tester, _GestureEngine());

    // The canvas painter applies rotation and scale, so this boundary is
    // required to prevent transformed tiles from painting over the toolbar or
    // workspace dock.
    expect(find.byType(ClipRect), findsAtLeastNWidgets(1));
  });

  testWidgets('gesture settings expose touch navigation and tap remapping', (
    tester,
  ) async {
    await _pumpCanvas(tester, _GestureEngine());

    await tester.tap(find.byTooltip('Gesture settings'));
    await tester.pumpAndSettle();

    expect(find.text('Gesture settings'), findsOneWidget);
    expect(find.text('Single-finger navigation'), findsOneWidget);
    expect(find.text('Two-finger tap'), findsOneWidget);
    expect(find.text('Three-finger tap'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Gesture settings'), findsNothing);
  });

  testWidgets('accessibility settings expose larger and left-handed controls', (
    tester,
  ) async {
    await _pumpCanvas(tester, _GestureEngine());

    await tester.tap(find.byTooltip('Accessibility settings'));
    await tester.pumpAndSettle();

    expect(find.text('Accessibility settings'), findsOneWidget);
    expect(find.text('Larger controls'), findsOneWidget);
    expect(find.text('Left-handed toolbar'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Accessibility settings'), findsNothing);
  });

  testWidgets('brush color control routes bounded color to the engine', (
    tester,
  ) async {
    final engine = _GestureEngine();
    await _pumpCanvas(tester, engine);
    final initialColorUpdateCount = engine.colorUpdateCount;

    await tester.tap(_toolbarCommand('Color'));
    await tester.pumpAndSettle();
    expect(find.text('Main color'), findsOneWidget);
    expect(find.text('Red'), findsOneWidget);
    expect(find.text('Green'), findsOneWidget);
    expect(find.text('Blue'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    expect(tester.getSize(find.text('100%')).width, greaterThanOrEqualTo(56));
    expect(tester.getSize(find.text('100%')).height, lessThanOrEqualTo(24));

    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(engine.colorUpdateCount, initialColorUpdateCount + 1);
    expect(find.text('Main color'), findsNothing);
  });

  testWidgets('C opens the brush color selector', (tester) async {
    await _pumpCanvas(tester, _GestureEngine());
    await tester.tap(find.byType(CanvasScreen));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.pumpAndSettle();

    expect(find.text('Main color'), findsOneWidget);
    expect(find.text('Red'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('color palette role controls expose and update main color', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(2200, 1800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final engine = _GestureEngine();
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: engine,
          targetPlatform: TargetPlatform.macOS,
          desktopDockEnabled: true,
          workspacePreferences: const WorkspacePreferences(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('All palettes').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Color').last);
    await tester.pumpAndSettle();

    expect(find.text('Main'), findsOneWidget);
    expect(find.text('Sub'), findsOneWidget);
    await tester.tap(find.text('Swap'));
    await tester.pumpAndSettle();
    expect(engine.lastAppliedColor, <int>[255, 255, 255, 255]);

    await tester.ensureVisible(find.text('Reset'));
    await tester.tap(find.text('Reset'));
    await tester.pumpAndSettle();
    expect(engine.lastAppliedColor, <int>[0, 0, 0, 255]);

    await tester.ensureVisible(find.text('Transparent'));
    await tester.tap(find.text('Transparent'));
    await tester.pumpAndSettle();
    expect(find.text('Transparent active'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'rectangle selection launcher actions are visible, labeled, and dispatched',
    (tester) async {
      tester.view.physicalSize = const Size(820, 1180);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semanticsHandle = tester.ensureSemantics();
      final engine = _GestureEngine();
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasScreen(
            engine: engine,
            targetPlatform: TargetPlatform.android,
            workspacePreferences: const WorkspacePreferences(),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byTooltip('Selections'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select and fill'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rectangle select'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      final canvas = find.bySemanticsLabel('Drawing canvas');
      final start = tester.getCenter(canvas);
      final drag = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await drag.moveTo(start);
      await drag.down(start);
      await drag.moveBy(const Offset(100, 80));
      await drag.up();
      await tester.pumpAndSettle();

      expect(engine.rectangleSelectionCount, 1);
      for (final action in const [
        'Invert selection',
        'Grow by 1 px',
        'Shrink by 1 px',
        'Deselect',
      ]) {
        expect(find.bySemanticsLabel(action), findsOneWidget);
      }
      await tester.tap(find.bySemanticsLabel('Invert selection'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Grow by 1 px'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Shrink by 1 px'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Deselect'));
      await tester.pumpAndSettle();

      expect(engine.invertSelectionCount, 1);
      expect(engine.grownSelectionBy, [1]);
      expect(engine.shrunkSelectionBy, [1]);
      expect(engine.clearSelectionCount, 1);
      expect(find.bySemanticsLabel('Invert selection'), findsNothing);
      expect(tester.takeException(), isNull);
      semanticsHandle.dispose();
    },
  );

  testWidgets('History palette exposes and navigates authoritative entries', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(2200, 1200);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final engine = _GestureEngine();
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: engine,
          targetPlatform: TargetPlatform.macOS,
          desktopDockEnabled: true,
          workspacePreferences: const WorkspacePreferences(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('All palettes').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('History').last);
    await tester.pumpAndSettle();

    expect(find.text('Technical Pen stroke'), findsOneWidget);
    expect(find.text('Applied'), findsNWidgets(2));
    final semanticsHandle = tester.ensureSemantics();
    expect(
      find.bySemanticsLabel(RegExp('Technical Pen stroke')),
      findsOneWidget,
    );
    await tester.tap(find.text('Technical Pen stroke'));
    await tester.pumpAndSettle();
    expect(engine.navigatedHistory, [1]);
    expect(tester.takeException(), isNull);
    semanticsHandle.dispose();
  });

  testWidgets('History palette discloses trimmed persisted undo history', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(2200, 1200);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final engine = _GestureEngine()..historyWasTrimmed = true;
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: engine,
          targetPlatform: TargetPlatform.macOS,
          desktopDockEnabled: true,
          workspacePreferences: const WorkspacePreferences(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('All palettes').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('History').last);
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Some older undo history was omitted to keep this document safe to open. Artwork is intact.',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('undo and redo refresh the authoritative layer projection', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(2200, 1200);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final engine = _LayerUndoEngine();
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: engine,
          targetPlatform: TargetPlatform.macOS,
          desktopDockEnabled: true,
          workspacePreferences: const WorkspacePreferences(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(_toolbarCommand('Layers').last);
    await tester.pumpAndSettle();

    expect(engine.includeScratchLayer, isTrue);
    final initialLayerPanel = tester.widget<LayerPanel>(
      find.byType(LayerPanel),
    );
    expect(
      initialLayerPanel.layers.any((layer) => layer.name == 'Scratch Layer'),
      isTrue,
      reason:
          'snapshots=${engine.layerSnapshotCount}, layers=${initialLayerPanel.layers.map((layer) => '${layer.id}:${layer.name}').join(',')}',
    );
    final snapshotsBeforeUndo = engine.layerSnapshotCount;
    await tester.tap(_toolbarCommand('Undo'));
    await tester.pumpAndSettle();

    expect(engine.layerSnapshotCount, greaterThan(snapshotsBeforeUndo));
    expect(engine.includeScratchLayer, isFalse);
    final undoneLayerPanel = tester.widget<LayerPanel>(find.byType(LayerPanel));
    expect(
      undoneLayerPanel.layers.any((layer) => layer.name == 'Scratch Layer'),
      isFalse,
    );

    await tester.tap(_toolbarCommand('Redo'));
    await tester.pumpAndSettle();
    expect(engine.includeScratchLayer, isTrue);
    expect(engine.layerSnapshotCount, greaterThan(snapshotsBeforeUndo + 1));
    final redoneLayerPanel = tester.widget<LayerPanel>(find.byType(LayerPanel));
    expect(
      redoneLayerPanel.layers.any((layer) => layer.name == 'Scratch Layer'),
      isTrue,
    );
    expect(find.byType(CanvasScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('duplicating a group refreshes the tree and selects its copy', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(2200, 1200);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final engine = _DuplicateGroupEngine();
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: engine,
          targetPlatform: TargetPlatform.macOS,
          desktopDockEnabled: true,
          workspacePreferences: const WorkspacePreferences(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final initialPanel = tester.widget<LayerPanel>(find.byType(LayerPanel));
    final group = initialPanel.layers.singleWhere((layer) => layer.id == 2);
    final beforeReads = engine.projectionReads;
    initialPanel.onDuplicateLayer!(group);
    await tester.pumpAndSettle();

    final panel = tester.widget<LayerPanel>(find.byType(LayerPanel));
    expect(engine.duplicateSource, 2);
    expect(engine.projectionReads, greaterThan(beforeReads));
    expect(
      panel.layers.any((layer) => layer.id == 4 && layer.parent == null),
      isTrue,
    );
    expect(
      panel.layers.any((layer) => layer.id == 5 && layer.parent == 4),
      isTrue,
    );
    expect(panel.selection.selected, contains(4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop palette overflow opens the Color palette', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(2200, 1200);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: InMemoryEngineApi(),
          targetPlatform: TargetPlatform.macOS,
          desktopDockEnabled: true,
          workspacePreferences: const WorkspacePreferences(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('All palettes'), findsNWidgets(2));
    expect(find.byTooltip('Add palette to this group'), findsNWidgets(4));
    expect(find.text('Quick Access'), findsOneWidget);
    expect(find.text('History'), findsOneWidget);
    expect(find.text('Tools & Color'), findsOneWidget);
    expect(find.text('Workspace'), findsOneWidget);
    await tester.tap(find.byTooltip('All palettes').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Color').last);
    await tester.pumpAndSettle();

    expect(find.text('Current colors'), findsOneWidget);
    expect(find.text('Color selector'), findsOneWidget);
    await tester.drag(find.text('Current colors'), const Offset(0, -360));
    await tester.pumpAndSettle();
    expect(find.text('Recent colors'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('command search finds palette aliases and dispatches commands', (
    tester,
  ) async {
    await _pumpCanvas(tester, _GestureEngine());
    await tester.tap(_toolbarCommand('Search commands'));
    await tester.pumpAndSettle();
    expect(find.text('Search commands'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'brush palette');
    await tester.pumpAndSettle();
    expect(find.text('Brushes'), findsOneWidget);

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Search commands'), findsNothing);
    expect(find.text('Brush library'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Fit canvas uses the available viewport instead of 100 percent', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pumpCanvas(
      tester,
      _GestureEngine(),
      desktopDockEnabled: true,
      workspacePreferences: const WorkspacePreferences(),
    );
    await tester.tap(_toolbarCommand('Search commands'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'fit canvas');
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    final percentageLabels =
        tester
            .widgetList<Text>(find.textContaining('%'))
            .map((text) => text.data)
            .toList();
    expect(percentageLabels, isNotEmpty);
    expect(percentageLabels, contains('100%')); // Brush opacity is unchanged.
    expect(percentageLabels, contains('34%')); // Canvas zoom is fitted.
    expect(tester.takeException(), isNull);
  });

  testWidgets('command bar customization persists action visibility', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(1600, 1200);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    WorkspacePreferences? changed;
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: InMemoryEngineApi(),
          targetPlatform: TargetPlatform.macOS,
          desktopDockEnabled: true,
          workspacePreferences: const WorkspacePreferences(),
          onWorkspacePreferencesChanged: (preferences) => changed = preferences,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Workspace').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Customize command bar…'));
    await tester.pumpAndSettle();
    expect(find.text('Customize command bar'), findsOneWidget);

    await tester.tap(find.byTooltip('Hide command').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(changed?.commandBarOverrides['illustration'], isNotNull);
    expect(
      changed!.commandBarOverrides['illustration'],
      isNot(contains('undo')),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop dock dividers resize and persist palette groups', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    WorkspacePreferences? updated;
    await _pumpCanvas(
      tester,
      _GestureEngine(),
      desktopDockEnabled: true,
      workspacePreferences: const WorkspacePreferences(),
      onWorkspacePreferencesChanged: (preferences) => updated = preferences,
    );

    final dividers = find.byTooltip('Resize palette groups');
    expect(dividers, findsNWidgets(2));
    await tester.drag(dividers.first, const Offset(0, 120));
    await tester.pumpAndSettle();

    final groups = updated!.workspaceOverrides['illustration']!.left!.groups;
    expect(groups, hasLength(2));
    expect(groups.first.flex, greaterThan(0.5));
    expect(groups.last.flex, lessThan(0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop palette tabs move across dock groups and persist', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    WorkspacePreferences? updated;
    final engine = _GestureEngine();
    await _pumpCanvas(
      tester,
      engine,
      desktopDockEnabled: true,
      workspacePreferences: const WorkspacePreferences(),
      onWorkspacePreferencesChanged: (preferences) => updated = preferences,
    );

    final sourceTab = find.text('Brushes').first;
    final targetTab = find.text('Materials').first;
    expect(sourceTab, findsOneWidget);
    expect(targetTab, findsOneWidget);
    final start = tester.getCenter(sourceTab);
    final end = tester.getCenter(targetTab);
    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveTo(start + const Offset(20, 0));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveTo(end);
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(updated, isNotNull);
    final layout = updated!.workspaceOverrides['illustration']!;
    expect(
      layout.left!.groups.expand((group) => group.tabs),
      isNot(contains(InkPaletteId.brushPresets)),
    );
    expect(
      layout.right!.groups.expand((group) => group.tabs),
      contains(InkPaletteId.brushPresets),
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop palette tabs can be reordered and persist', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    WorkspacePreferences? updated;
    await _pumpCanvas(
      tester,
      _GestureEngine(),
      desktopDockEnabled: true,
      workspacePreferences: const WorkspacePreferences(),
      onWorkspacePreferencesChanged: (preferences) => updated = preferences,
    );

    final source = find.text('Brushes').first;
    final target = find.text('Tools').last;
    expect(source, findsOneWidget);
    expect(target, findsOneWidget);
    final start = tester.getCenter(source);
    final end = tester.getCenter(target);
    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveTo(start + const Offset(20, 0));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveTo(end);
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      updated!.workspaceOverrides['illustration']!.left!.groups.first.tabs,
      [InkPaletteId.brushPresets, InkPaletteId.toolGroups],
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone and tablet rotations retain the selected drawing tool', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(820, 1180);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: _GestureEngine(),
          targetPlatform: TargetPlatform.android,
          workspacePreferences: const WorkspacePreferences(),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('Selections'));
    await tester.pumpAndSettle();
    expect(find.text('Illustration tools'), findsOneWidget);
    await tester.tap(find.text('Select and fill'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bucket fill'));
    await tester.pumpAndSettle();

    final canvasState = tester.state(find.byType(CanvasScreen));
    final bucketFillRow = find.ancestor(
      of: find.text('Bucket fill'),
      matching: find.byType(InkInspectorRow),
    );
    expect(tester.widget<InkInspectorRow>(bucketFillRow).selected, isTrue);

    for (final size in const [
      Size(1180, 820),
      Size(390, 844),
      Size(520, 700),
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(CanvasScreen)), same(canvasState));
      expect(find.text('Illustration tools'), findsOneWidget);
      expect(tester.widget<InkInspectorRow>(bucketFillRow).selected, isTrue);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('desktop window resizing retains the active workspace palette', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pumpCanvas(
      tester,
      _GestureEngine(),
      desktopDockEnabled: true,
      workspacePreferences: const WorkspacePreferences(),
    );

    final canvasState = tester.state(find.byType(CanvasScreen));
    await tester.tap(_toolbarCommand('Brush library'));
    await tester.pumpAndSettle();
    expect(find.text('Technical Pen'), findsWidgets);

    for (final size in const [Size(1280, 800), Size(1720, 1080)]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(CanvasScreen)), same(canvasState));
      expect(find.text('Technical Pen'), findsWidgets);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('macOS desktop uses native menus backed by shared actions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final engine = _GestureEngine();
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: engine,
          targetPlatform: TargetPlatform.macOS,
          desktopDockEnabled: true,
          workspacePreferences: const WorkspacePreferences(),
        ),
      ),
    );
    await tester.pump();

    final menuBar = tester.widget<PlatformMenuBar>(
      find.byType(PlatformMenuBar),
    );
    expect(menuBar.menus.map((menu) => menu.label), [
      'File',
      'Edit',
      'View',
      'Layer',
      'Select',
      'Tool',
      'Window',
      'Help',
    ]);
    expect(find.text('File'), findsNothing);

    final editMenu = menuBar.menus.whereType<PlatformMenu>().singleWhere(
      (menu) => menu.label == 'Edit',
    );
    final undoItem = editMenu.menus.singleWhere((item) => item.label == 'Undo');
    expect(undoItem.shortcut, isA<SingleActivator>());
    expect((undoItem.shortcut! as SingleActivator).meta, isTrue);
    undoItem.onSelected!();
    await tester.pumpAndSettle();

    expect(engine.undoCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('built-in workspace reset confirms and clears local overrides', (
    tester,
  ) async {
    const defaults = WorkspacePreferences();
    final modified = defaults.copyWith(
      workspaceOverrides: {
        'illustration': const WorkspaceLayout(
          id: 'illustration',
          name: 'Illustration',
          kind: WorkspacePresetKind.illustration,
          left: DockColumnLayout(
            width: 248,
            groups: [
              DockGroupLayout(
                flex: 0.8,
                tabs: [InkPaletteId.toolGroups, InkPaletteId.brushPresets],
              ),
              DockGroupLayout(
                flex: 0.2,
                tabs: [InkPaletteId.color, InkPaletteId.quickAccess],
              ),
            ],
          ),
          commandBar: defaultCommandBarItems,
        ),
      },
      commandBarOverrides: const {
        'illustration': ['undo'],
      },
    );
    WorkspacePreferences? updated;
    await _pumpCanvas(
      tester,
      _GestureEngine(),
      workspacePreferences: modified,
      onWorkspacePreferencesChanged: (preferences) => updated = preferences,
    );

    await tester.tap(find.byTooltip('Workspace'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset current workspace layout…'));
    await tester.pumpAndSettle();
    expect(find.text('Reset workspace layout?'), findsOneWidget);
    await tester.tap(find.text('Reset layout'));
    await tester.pumpAndSettle();

    expect(updated!.workspaceOverrides, isEmpty);
    expect(updated!.commandBarOverrides, isEmpty);
    expect(updated!.dockWidth, 360);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selecting a brush does not create an edit draft', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final engine = _GestureEngine();
    await _pumpCanvas(
      tester,
      engine,
      desktopDockEnabled: true,
      workspacePreferences: const WorkspacePreferences(),
    );

    await tester.tap(_toolbarCommand('Brush library'));
    await tester.pumpAndSettle();
    final brush = find.bySemanticsLabel('Technical Pen');
    await tester.tap(brush);
    await tester.pump(const Duration(milliseconds: 500));

    expect(engine.brushDraftCount, 0);
  });

  testWidgets('rejected layer edits refresh the Rust-owned projection', (
    tester,
  ) async {
    await _pumpCanvas(tester, _RejectingLayerEngine());

    await tester.tap(find.byTooltip('Layers'));
    await tester.pumpAndSettle();
    expect(_layerVisibilityTooltip('Hide'), findsOneWidget);

    await tester.tap(_layerVisibilityTooltip('Hide'));
    await tester.pumpAndSettle();

    expect(_layerVisibilityTooltip('Hide'), findsOneWidget);
    expect(_layerVisibilityTooltip('Show'), findsNothing);
  });
}

Future<void> _pumpCanvas(
  WidgetTester tester,
  EngineApi engine, {
  bool desktopDockEnabled = false,
  String? activeDocumentPath,
  AutosaveState? autosaveState,
  WorkspacePreferences? workspacePreferences,
  ValueChanged<WorkspacePreferences>? onWorkspacePreferencesChanged,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: CanvasScreen(
        engine: engine,
        targetPlatform: TargetPlatform.windows,
        desktopDockEnabled: desktopDockEnabled,
        activeDocumentPath: activeDocumentPath,
        autosaveState: autosaveState,
        workspacePreferences: workspacePreferences,
        onWorkspacePreferencesChanged: onWorkspacePreferencesChanged,
      ),
    ),
  );
  await tester.pump();
}

Finder _toolbarCommand(String labelPrefix) => find.byWidgetPredicate(
  (widget) =>
      widget is Tooltip && (widget.message?.startsWith(labelPrefix) ?? false),
);

Finder _layerVisibilityTooltip(String action) => find.byWidgetPredicate(
  (widget) =>
      widget is Tooltip &&
      (widget.message?.startsWith('$action layer;') ?? false),
);

Future<void> _tapWithFingers(WidgetTester tester, int count) async {
  final center = tester.getCenter(find.byType(CanvasScreen));
  final gestures = <TestGesture>[];
  for (var index = 0; index < count; index++) {
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.touch,
      pointer: index + 1,
    );
    gestures.add(gesture);
    await gesture.down(center + Offset(index * 2, 0));
  }
  await tester.pump(const Duration(milliseconds: 20));
  for (final gesture in gestures) {
    await gesture.up();
  }
  await tester.pump(const Duration(milliseconds: 20));
}
