import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/bridge/engine_api.dart';
import 'package:project_ink/app/workspace_preferences.dart';
import 'package:project_ink/canvas/canvas_screen.dart';
import 'package:project_ink/canvas/live_stroke_coordinator.dart';
import 'package:project_ink/canvas/pointer_packet.dart';

class _FailingPointerEngine extends InMemoryEngineApi {
  int beginCount = 0;
  int pushCount = 0;
  int cancelCount = 0;

  @override
  Future<void> beginStroke() async {
    beginCount++;
    await super.beginStroke();
  }

  @override
  Future<void> pushPointerPacket(Uint8List packet) async {
    pushCount++;
    throw StateError('simulated bridge failure');
  }

  @override
  Future<void> cancelStroke() async {
    cancelCount++;
    await super.cancelStroke();
  }
}

class _IntermittentPointerEngine extends _RecordingPointerEngine {
  bool failNextPacket = true;

  @override
  Future<void> pushPointerPacket(Uint8List packet) async {
    if (failNextPacket) {
      failNextPacket = false;
      throw StateError('simulated one-time bridge failure');
    }
    await super.pushPointerPacket(packet);
  }
}

class _RecordingPointerEngine extends InMemoryEngineApi {
  final List<double> pressures = <double>[];
  final List<Offset> positions = <Offset>[];
  final List<int> sampleCounts = <int>[];
  final List<int> deviceKinds = <int>[];
  final List<int> brushIds = <int>[];
  final List<int> targetLayerIds = <int>[];
  int pushCount = 0;

  int beginCount = 0;
  int endCount = 0;
  int cancelCount = 0;

  @override
  Future<void> beginBrushStroke(int brushId) async {
    beginCount++;
    brushIds.add(brushId);
    await super.beginBrushStroke(brushId);
  }

  @override
  Future<void> beginBrushStrokeOnLayer(int brushId, int layerId) async {
    targetLayerIds.add(layerId);
    await super.beginBrushStrokeOnLayer(brushId, layerId);
  }

  @override
  Future<void> cancelStroke() async {
    cancelCount++;
    await super.cancelStroke();
  }

  @override
  Future<void> endStroke() async {
    endCount++;
    await super.endStroke();
  }

  @override
  Future<void> pushPointerPacket(Uint8List packet) async {
    pushCount++;
    final data = ByteData.sublistView(packet);
    sampleCounts.add(data.getUint16(2, Endian.little));
    deviceKinds.add(data.getUint8(10));
    pressures.add(data.getFloat32(20, Endian.little));
    positions.add(
      Offset(
        data.getFloat32(12, Endian.little),
        data.getFloat32(16, Endian.little),
      ),
    );
    await super.pushPointerPacket(packet);
  }
}

class _TwoRasterLayerEngine extends _RecordingPointerEngine {
  @override
  Future<List<LayerSummaryView>> layerSummaries() async => const [
    LayerSummaryView(id: 1, name: 'Paint Layer 1', kind: 'Raster', order: 0),
    LayerSummaryView(id: 2, name: 'Paint Layer 2', kind: 'Raster', order: 1),
  ];
}

class _DelayedEndStrokeEngine extends _RecordingPointerEngine {
  final Completer<void> endStrokeStarted = Completer<void>();
  final Completer<void> allowEndStroke = Completer<void>();
  int undoCount = 0;

  @override
  Future<void> endStroke() async {
    if (!endStrokeStarted.isCompleted) endStrokeStarted.complete();
    await allowEndStroke.future;
    await super.endStroke();
  }

  @override
  Future<void> undo() async {
    undoCount++;
    await super.undo();
  }
}

class _GatedPointerEngine extends InMemoryEngineApi {
  final Completer<void> firstPushStarted = Completer<void>();
  final Completer<void> allowPushes = Completer<void>();
  int pushesStarted = 0;
  int pushesCompleted = 0;
  int endCount = 0;

  @override
  Future<void> pushPointerPacket(Uint8List packet) async {
    pushesStarted++;
    if (!firstPushStarted.isCompleted) firstPushStarted.complete();
    await allowPushes.future;
    pushesCompleted++;
    await super.pushPointerPacket(packet);
  }

  @override
  Future<void> endStroke() async {
    endCount++;
    await super.endStroke();
  }
}

class _CancelAfterCpuCoverageEngine extends InMemoryEngineApi {
  _CancelAfterCpuCoverageEngine({this.fullRedrawOnEnd = true});

  final bool fullRedrawOnEnd;
  bool _acknowledgementPending = false;
  bool _fullRedrawPending = false;
  int _lastConfirmedSequence = 0;

  @override
  Future<void> pushPointerPacket(Uint8List packet) async {
    final data = ByteData.sublistView(packet);
    final count = data.getUint16(2, Endian.little);
    final phase = count > 0 ? data.getUint8(4 + 7) : -1;
    if (phase == InkPointerPhase.down.index ||
        phase == InkPointerPhase.move.index) {
      _lastConfirmedSequence = data.getUint32(4 + 44, Endian.little);
      _acknowledgementPending = true;
    }
    await super.pushPointerPacket(packet);
  }

  @override
  Future<void> endStroke() async {
    await super.endStroke();
    if (fullRedrawOnEnd) _fullRedrawPending = true;
  }

  @override
  Future<void> cancelStroke() async {
    await super.cancelStroke();
    _fullRedrawPending = true;
  }

  @override
  Future<TileUpdateBatch> drainTileUpdates() async {
    if (_acknowledgementPending) {
      _acknowledgementPending = false;
      return TileUpdateBatch(
        revision: revision,
        fullRedraw: false,
        tiles: const <TileUpdate>[],
        acknowledgements: <StrokeAcknowledgement>[
          StrokeAcknowledgement(
            stroke: BigInt.one,
            highestCommittedSequence: _lastConfirmedSequence,
            revision: revision,
            minTileX: 1,
            minTileY: 1,
            maxTileX: 0,
            maxTileY: 0,
          ),
        ],
      );
    }
    if (_fullRedrawPending) {
      _fullRedrawPending = false;
      return TileUpdateBatch(
        revision: revision,
        fullRedraw: true,
        tiles: const <TileUpdate>[],
      );
    }
    return super.drainTileUpdates();
  }
}

class _IncoherentCpuSnapshotEngine extends InMemoryEngineApi {
  bool _acknowledgementPending = false;
  int _lastConfirmedSequence = 0;
  int fallbackTileReads = 0;
  bool allowCoherentSnapshot = false;
  int _snapshotAttempt = 0;
  static final List<StrokeTileCoordinate> _dirtyTiles = List.generate(
    64,
    (index) => StrokeTileCoordinate(index % 8, index ~/ 8),
    growable: false,
  );

  @override
  Future<void> pushPointerPacket(Uint8List packet) async {
    final data = ByteData.sublistView(packet);
    if (data.getUint16(2, Endian.little) > 0) {
      _lastConfirmedSequence = data.getUint32(4 + 44, Endian.little);
      _acknowledgementPending = true;
    }
    await super.pushPointerPacket(packet);
  }

  @override
  Future<TileUpdateBatch> drainTileUpdates() async {
    if (!_acknowledgementPending) return super.drainTileUpdates();
    _acknowledgementPending = false;
    return TileUpdateBatch(
      revision: revision,
      fullRedraw: false,
      tiles: const <TileUpdate>[],
      acknowledgements: <StrokeAcknowledgement>[
        StrokeAcknowledgement(
          stroke: BigInt.one,
          highestCommittedSequence: _lastConfirmedSequence,
          revision: revision,
          minTileX: 0,
          minTileY: 0,
          maxTileX: 7,
          maxTileY: 7,
          dirtyTiles: _dirtyTiles,
        ),
      ],
    );
  }

  @override
  Future<CompositeTileSnapshot> readCompositeTilesSnapshot({
    required List<StrokeTileCoordinate> coordinates,
  }) async {
    final attempt = _snapshotAttempt++ ~/ 2;
    final revision =
        allowCoherentSnapshot || _snapshotAttempt % 2 == 1
            ? this.revision
            : this.revision + attempt + 1;
    return CompositeTileSnapshot(
      revision: revision,
      tiles: coordinates
          .map(
            (coordinate) => CompositeTilePixels(
              x: coordinate.x,
              y: coordinate.y,
              bytes: Uint8List(256 * 256 * 4),
            ),
          )
          .toList(growable: false),
    );
  }

  @override
  Future<Uint8List> readCompositeTile({required int x, required int y}) async {
    fallbackTileReads++;
    return super.readCompositeTile(x: x, y: y);
  }
}

void main() {
  testWidgets('drawing targets the selected raster layer', (tester) async {
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final engine = _TwoRasterLayerEngine();
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: engine,
          targetPlatform: TargetPlatform.iOS,
          workspacePreferences: const WorkspacePreferences(
            tabletMode: TabletWorkspaceMode.studio,
          ),
        ),
      ),
    );
    await tester.pump();

    final layer = find.text('Paint Layer 2');
    await tester.ensureVisible(layer);
    await tester.tap(layer);
    await tester.pump();

    final canvas = find.bySemanticsLabel('Drawing canvas');
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.down(tester.getCenter(canvas));
    await tester.pump();
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400));

    expect(engine.targetLayerIds, [2]);
  });

  testWidgets(
    'finger contact size drives touch brush pressure when force is absent',
    (tester) async {
      final engine = _RecordingPointerEngine();
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasScreen(
            engine: engine,
            targetPlatform: TargetPlatform.macOS,
          ),
        ),
      );
      await tester.pump();

      final center = tester.getCenter(find.bySemanticsLabel('Drawing canvas'));
      final gesture = await tester.createGesture(
        pointer: 91,
        kind: PointerDeviceKind.touch,
      );
      await gesture.moveTo(center);
      await gesture.downWithCustomEvent(
        center,
        PointerDownEvent(
          pointer: 91,
          kind: PointerDeviceKind.touch,
          position: center,
          pressure: 1,
          pressureMin: 1,
          pressureMax: 1,
          radiusMajor: 5,
          radiusMinor: 5,
        ),
      );
      await gesture.updateWithCustomEvent(
        PointerMoveEvent(
          pointer: 91,
          kind: PointerDeviceKind.touch,
          position: center + const Offset(24, 12),
          delta: const Offset(24, 12),
          buttons: kPrimaryButton,
          pressure: 1,
          pressureMin: 1,
          pressureMax: 1,
          radiusMajor: 18,
          radiusMinor: 18,
        ),
      );
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 400));

      expect(engine.beginCount, 1);
      expect(engine.endCount, 1);
      expect(engine.deviceKinds, isNotEmpty);
      expect(engine.deviceKinds, everyElement(2)); // InkPointerDevice.touch
      expect(engine.pressures, contains(0.0));
      expect(engine.pressures, contains(1.0));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('live stroke preview is isolated from committed canvas tiles', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: InMemoryEngineApi(),
          targetPlatform: TargetPlatform.macOS,
        ),
      ),
    );
    await tester.pump();

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    final center = tester.getCenter(find.byType(CanvasScreen));
    await gesture.moveTo(center);
    await gesture.down(center);
    await tester.pump();

    final previewBoundary = find.byKey(
      const ValueKey('live-stroke-preview-boundary'),
    );
    expect(previewBoundary, findsOneWidget);
    expect(
      find.descendant(of: previewBoundary, matching: find.byType(CustomPaint)),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets(
    'confirmed finger path stays visible while the engine bridge is stalled',
    (tester) async {
      final engine = _GatedPointerEngine();
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasScreen(
            engine: engine,
            targetPlatform: TargetPlatform.iOS,
          ),
        ),
      );
      await tester.pump();

      final canvas = find.bySemanticsLabel('Drawing canvas');
      final bounds = tester.getRect(canvas);
      final center = bounds.center;
      final gesture = await tester.startGesture(
        center,
        kind: PointerDeviceKind.touch,
      );
      await tester.pump();
      await engine.firstPushStarted.future;

      // Keep sending a curved confirmed path while its first engine packet is
      // blocked. Flutter must append and paint every input sample without
      // waiting for Rust/bridge progress.
      const sampleCount = 96;
      final radiusLimit = math.min(bounds.width, bounds.height) * 0.3;
      for (var index = 1; index <= sampleCount; index++) {
        final progress = index / sampleCount;
        final angle = progress * math.pi * 8;
        final radius = radiusLimit * progress;
        await gesture.moveTo(
          center + Offset(math.cos(angle) * radius, math.sin(angle) * radius),
        );
        if (index % 12 == 0) {
          await tester.pump(const Duration(milliseconds: 16));
        }
      }
      await tester.pump();

      final previewFinder = find.byKey(
        const ValueKey('live-stroke-preview-boundary'),
      );
      expect(previewFinder, findsOneWidget);
      final previewPaint = tester.widget<CustomPaint>(
        find.descendant(of: previewFinder, matching: find.byType(CustomPaint)),
      );
      final painter = previewPaint.painter! as LiveStrokePreviewPainter;
      expect(painter.preview!.points.length, greaterThanOrEqualTo(sampleCount));
      expect(engine.pushesStarted, 1);
      expect(engine.pushesCompleted, 0);
      expect(tester.takeException(), isNull);

      await gesture.up();
      await tester.pump();
      engine.allowPushes.complete();
      for (var frame = 0; frame < 12; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(engine.pushesCompleted, greaterThanOrEqualTo(sampleCount));
      expect(engine.endCount, 1);
      expect(engine.revision, greaterThan(0));
      expect(tester.takeException(), isNull);
      // InMemoryEngineApi does not emit CPU tile acknowledgements, so this
      // test covers responsiveness under backpressure only. Rust-to-Flutter
      // tile handoff is covered by live_cpu_handoff_test.dart.
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('pointer cancel removes a CPU-covered live preview safely', (
    tester,
  ) async {
    final engine = _CancelAfterCpuCoverageEngine();
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: engine,
          targetPlatform: TargetPlatform.windows,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 40));

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    final center = tester.getCenter(find.bySemanticsLabel('Drawing canvas'));
    await gesture.moveTo(center);
    await gesture.down(center);
    await tester.pump(const Duration(milliseconds: 40));
    expect(
      find.byKey(const ValueKey('live-stroke-preview-boundary')),
      findsOneWidget,
    );

    await gesture.cancel();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.byKey(const ValueKey('live-stroke-preview-boundary')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'terminal full redraw retires previously CPU-covered preview without a new ack',
    (tester) async {
      final engine = _CancelAfterCpuCoverageEngine();
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasScreen(
            engine: engine,
            targetPlatform: TargetPlatform.windows,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 40));

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      final center = tester.getCenter(find.bySemanticsLabel('Drawing canvas'));
      await gesture.moveTo(center);
      await gesture.down(center);
      await tester.pump(const Duration(milliseconds: 40));
      expect(
        find.byKey(const ValueKey('live-stroke-preview-boundary')),
        findsOneWidget,
      );

      await gesture.up();
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        find.byKey(const ValueKey('live-stroke-preview-boundary')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'stroke end retires CPU-covered preview when terminal commit has no tiles',
    (tester) async {
      final engine = _CancelAfterCpuCoverageEngine(fullRedrawOnEnd: false);
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasScreen(
            engine: engine,
            targetPlatform: TargetPlatform.windows,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 40));

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      final center = tester.getCenter(find.bySemanticsLabel('Drawing canvas'));
      await gesture.moveTo(center);
      await gesture.down(center);
      await gesture.moveBy(const Offset(35, 18));
      await tester.pump(const Duration(milliseconds: 60));
      expect(
        find.byKey(const ValueKey('live-stroke-preview-boundary')),
        findsOneWidget,
      );

      await gesture.up();
      await tester.pump(const Duration(milliseconds: 40));

      expect(
        find.byKey(const ValueKey('live-stroke-preview-boundary')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('touch preview waits for coherent multipart CPU handoff', (
    tester,
  ) async {
    final engine = _IncoherentCpuSnapshotEngine();
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: engine,
          targetPlatform: TargetPlatform.windows,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 40));

    final canvas = find.bySemanticsLabel('Drawing canvas');
    final gesture = await tester.createGesture(
      pointer: 92,
      kind: PointerDeviceKind.touch,
    );
    final start = tester.getCenter(canvas);
    await gesture.moveTo(start);
    await gesture.down(start);
    await gesture.moveBy(const Offset(80, 35));
    await tester.pump(const Duration(milliseconds: 60));

    expect(engine.fallbackTileReads, 0);
    expect(
      find.byKey(const ValueKey('live-stroke-preview-boundary')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await gesture.cancel();
    await tester.pump(const Duration(milliseconds: 40));
  });

  testWidgets('bridge failure cancels the active stroke', (tester) async {
    final engine = _FailingPointerEngine();
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: engine,
          // Desktop input stays on the generic Flutter path in Phase 1.
          targetPlatform: TargetPlatform.windows,
        ),
      ),
    );
    await tester.pump();

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.down(tester.getCenter(find.byType(CanvasScreen)));
    await tester.pump(const Duration(milliseconds: 20));

    expect(engine.beginCount, 1);
    expect(engine.pushCount, 1);
    expect(engine.cancelCount, 1);

    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('a one-time packet failure does not poison later strokes', (
    tester,
  ) async {
    final engine = _IntermittentPointerEngine();
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: engine,
          targetPlatform: TargetPlatform.windows,
        ),
      ),
    );
    await tester.pump();

    final center = tester.getCenter(find.byType(CanvasScreen));
    final failedStroke = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await failedStroke.moveTo(center);
    await failedStroke.down(center);
    await tester.pump(const Duration(milliseconds: 20));
    await failedStroke.up();
    await tester.pump(const Duration(milliseconds: 20));

    final nextStroke = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await nextStroke.moveTo(center + const Offset(24, 12));
    await nextStroke.down(center + const Offset(24, 12));
    await nextStroke.moveBy(const Offset(20, 10));
    await nextStroke.up();
    await tester.pump(const Duration(milliseconds: 400));

    expect(engine.beginCount, 2);
    expect(engine.cancelCount, 1);
    expect(engine.endCount, 1);
    expect(engine.pushCount, greaterThanOrEqualTo(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('repeated long mouse strokes survive brush changes in the UI', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final engine = _RecordingPointerEngine();
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: engine,
          targetPlatform: TargetPlatform.windows,
        ),
      ),
    );
    await tester.pump();
    // Use the documented B command to open the library regardless of whether
    // a wide test viewport routes it through a floating panel or a dock tab.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyB);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyB);
    await tester.pumpAndSettle();

    const brushNames = <String>[
      'Technical Pen',
      'HB Sketch Pencil',
      'Opaque Round',
      'Soft Airbrush',
      'Marker',
      'G-Pen',
      'Dry Gouache',
      'Digital Watercolor Wash',
      'Watercolor Blender',
      'Ink Spatter',
      'Ribbon Chain',
      'Acrylic Rake',
    ];
    final canvas = find.bySemanticsLabel('Drawing canvas');
    expect(canvas, findsOneWidget);
    final center = tester.getCenter(canvas);

    for (final brushName in brushNames) {
      final preset = find.text(brushName).last;
      await tester.ensureVisible(preset);
      await tester.pumpAndSettle();
      await tester.tap(preset);
      await tester.pump(const Duration(milliseconds: 20));

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      const steps = 48;
      for (var step = 0; step <= steps; step++) {
        final progress = step / steps;
        final angle = progress * 8 * math.pi;
        final radius = 2 + progress * 36;
        final point =
            center + Offset(math.cos(angle), math.sin(angle)) * radius;
        if (step == 0) {
          await gesture.moveTo(point);
          await gesture.down(point);
        } else {
          await gesture.moveTo(point);
        }
      }
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(engine.beginCount, brushNames.length);
    expect(engine.endCount, brushNames.length);
    expect(engine.cancelCount, 0);
    expect(engine.brushIds.toSet(), hasLength(brushNames.length));
    expect(engine.pushCount, greaterThan(brushNames.length));
    expect(tester.takeException(), isNull);
  });

  testWidgets('undo waits until the current stroke is committed', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final engine = _DelayedEndStrokeEngine();
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: engine,
          targetPlatform: TargetPlatform.windows,
        ),
      ),
    );
    await tester.pump();

    final center = tester.getCenter(find.byType(CanvasScreen));
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.moveTo(center);
    await gesture.down(center);
    await tester.pump();
    await gesture.up();
    await tester.pump();
    await engine.endStrokeStarted.future;

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyZ, character: 'z');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(engine.undoCount, 0);

    engine.allowEndStroke.complete();
    await tester.pump(const Duration(milliseconds: 400));
    expect(engine.undoCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('macOS mouse drawing uses firm pressure for visible dabs', (
    tester,
  ) async {
    final engine = _RecordingPointerEngine();
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: engine,
          targetPlatform: TargetPlatform.macOS,
        ),
      ),
    );
    await tester.pump();

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    final center = tester.getCenter(find.byType(CanvasScreen));
    await gesture.moveTo(center);
    await gesture.down(center);
    await gesture.moveBy(const Offset(24, 12));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400));

    expect(engine.pressures, isNotEmpty);
    expect(engine.pressures.first, closeTo(1.0, 0.001));
  });

  testWidgets(
    'off-canvas mouse drags stay bounded and do not break the editor',
    (tester) async {
      final engine = _RecordingPointerEngine();
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasScreen(
            engine: engine,
            targetPlatform: TargetPlatform.macOS,
          ),
        ),
      );
      await tester.pump();

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      final center = tester.getCenter(find.byType(CanvasScreen));
      await gesture.moveTo(center);
      await gesture.down(center);
      await gesture.moveBy(const Offset(10000, -10000));
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 400));

      expect(engine.positions, isNotEmpty);
      for (final position in engine.positions) {
        expect(position.dx.abs(), lessThanOrEqualTo(65536));
        expect(position.dy.abs(), lessThanOrEqualTo(65536));
      }
      expect(
        engine.positions.any(
          (position) =>
              position.dx < 0 ||
              position.dy < 0 ||
              position.dx >= engine.documentInfo.widthPx ||
              position.dy >= engine.documentInfo.heightPx,
        ),
        isTrue,
        reason: 'the Rust engine needs raw off-page positions to clip segments',
      );

      // Pointer capture may keep delivering events after the cursor exits the
      // artwork. A later ordinary stroke must still reach the same engine.
      final nextStroke = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        pointer: 2,
      );
      await nextStroke.moveTo(center);
      await nextStroke.down(center);
      await nextStroke.moveBy(const Offset(12, 8));
      await nextStroke.up();
      await tester.pump(const Duration(milliseconds: 400));

      expect(engine.pushCount, greaterThan(3));
      expect(find.bySemanticsLabel('Drawing canvas'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'long off-canvas drags stop queuing samples and leave the editor usable',
    (tester) async {
      final engine = _RecordingPointerEngine();
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasScreen(
            engine: engine,
            targetPlatform: TargetPlatform.macOS,
          ),
        ),
      );
      await tester.pump();

      final center = tester.getCenter(find.byType(CanvasScreen));
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.moveTo(center);
      await gesture.down(center);
      await gesture.moveBy(const Offset(10000, -10000));
      for (var sample = 0; sample < 100; sample++) {
        await gesture.moveBy(const Offset(1, 1));
      }
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 400));

      // Down plus the first crossing sample are sufficient. The release still
      // closes the Rust transaction without forwarding 100 captured moves.
      expect(engine.pushCount, 2);
      expect(engine.endCount, 1);
      expect(engine.cancelCount, 0);
      expect(find.bySemanticsLabel('Drawing canvas'), findsOneWidget);
      expect(tester.takeException(), isNull);

      final nextStroke = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        pointer: 2,
      );
      await nextStroke.moveTo(center);
      await nextStroke.down(center);
      await nextStroke.moveBy(const Offset(12, 8));
      await nextStroke.up();
      await tester.pump(const Duration(milliseconds: 400));

      expect(engine.beginCount, 2);
      expect(engine.endCount, 2);
      expect(find.bySemanticsLabel('Drawing canvas'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'leaving the visible viewport stops a zoomed-page stroke cleanly',
    (tester) async {
      final engine = _RecordingPointerEngine();
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasScreen(
            engine: engine,
            targetPlatform: TargetPlatform.macOS,
          ),
        ),
      );
      await tester.pump();

      final canvas = find.bySemanticsLabel('Drawing canvas');
      final bounds = tester.getRect(canvas);
      final center = bounds.center;
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.moveTo(center);
      await gesture.down(center);

      // At 1:1 zoom the 2048px page is larger than the visible viewport. A
      // point just beyond the right side still maps inside document bounds,
      // which used to keep the captured stream drawing into the hidden page.
      await gesture.moveTo(Offset(bounds.right + 8, center.dy));
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 300));

      expect(engine.pushCount, 1, reason: 'do not forward off-viewport moves');
      expect(engine.endCount, 1, reason: 'release must close the transaction');
      expect(engine.cancelCount, 0);
      expect(find.bySemanticsLabel('Drawing canvas'), findsOneWidget);
      expect(tester.takeException(), isNull);

      final nextStroke = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        pointer: 2,
      );
      await nextStroke.moveTo(center);
      await nextStroke.down(center);
      await nextStroke.moveBy(const Offset(12, 8));
      await nextStroke.up();
      await tester.pump(const Duration(milliseconds: 300));

      expect(engine.beginCount, 2);
      expect(engine.endCount, 2);
      expect(find.bySemanticsLabel('Drawing canvas'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'native stylus packets stop at the page edge and the next stroke works',
    (tester) async {
      final engine = _RecordingPointerEngine();
      final packets = StreamController<Uint8List>.broadcast();
      addTearDown(packets.close);
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasScreen(
            engine: engine,
            targetPlatform: TargetPlatform.macOS,
            nativePointerPacketsOverride: packets.stream,
          ),
        ),
      );
      await tester.pump();

      final center = tester.getCenter(find.byType(CanvasScreen));
      Uint8List packet(
        InkPointerPhase phase,
        Offset point,
        int sequence, {
        int flags = inkPointerActual,
      }) => encodePointerPacket(
        pointerId: 9,
        device: InkPointerDevice.stylus,
        phase: phase,
        x: point.dx,
        y: point.dy,
        pressure: 1,
        timestampNs: sequence * 1_000_000,
        sequence: sequence,
        flags: flags,
      );

      packets.add(packet(InkPointerPhase.down, center, 1));
      await tester.pump(const Duration(milliseconds: 20));
      packets.add(
        packet(InkPointerPhase.move, center + const Offset(10000, 0), 2),
      );
      await tester.pump(const Duration(milliseconds: 20));
      for (var sequence = 3; sequence < 103; sequence++) {
        packets.add(
          packet(
            InkPointerPhase.move,
            center + Offset((10000 + sequence).toDouble(), 0),
            sequence,
          ),
        );
      }
      packets.add(
        packet(InkPointerPhase.up, center + const Offset(10103, 0), 103),
      );
      await tester.pump(const Duration(milliseconds: 300));

      // Only the contact and first clipped edge sample reach the engine; the
      // captured off-page stream is ignored, while release still closes it.
      expect(engine.pushCount, 2);
      expect(engine.endCount, 1);
      expect(engine.cancelCount, 0);
      expect(tester.takeException(), isNull);

      final packetsAfterClippedStroke = engine.pushCount;
      final samplesAfterClippedStroke = engine.positions.length;
      packets.add(packet(InkPointerPhase.down, center, 104));
      packets.add(
        packet(InkPointerPhase.move, center + const Offset(12, 8), 105),
      );
      packets.add(
        packet(InkPointerPhase.up, center + const Offset(16, 12), 106),
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(engine.beginCount, 2);
      expect(engine.pushCount, greaterThan(packetsAfterClippedStroke));
      expect(engine.positions.length, greaterThan(samplesAfterClippedStroke));
      expect(engine.endCount, 2);

      // A predicted point outside the page must not stop a confirmed stroke
      // that continues inside the page.
      final packetsBeforePredictedStroke = engine.pushCount;
      packets.add(packet(InkPointerPhase.down, center, 107));
      packets.add(
        packet(
          InkPointerPhase.move,
          center + const Offset(10000, 0),
          108,
          flags: inkPointerPredicted,
        ),
      );
      packets.add(
        packet(InkPointerPhase.move, center + const Offset(20, 10), 109),
      );
      packets.add(
        packet(InkPointerPhase.up, center + const Offset(30, 20), 110),
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(engine.beginCount, 3);
      expect(engine.pushCount, greaterThan(packetsBeforePredictedStroke));
      expect(engine.endCount, 3);
      expect(find.bySemanticsLabel('Drawing canvas'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'native coalesced batch stops at its first confirmed page-edge crossing',
    (tester) async {
      final engine = _RecordingPointerEngine();
      final packets = StreamController<Uint8List>.broadcast();
      addTearDown(packets.close);
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasScreen(
            engine: engine,
            targetPlatform: TargetPlatform.macOS,
            nativePointerPacketsOverride: packets.stream,
          ),
        ),
      );
      await tester.pump();

      final center = tester.getCenter(find.byType(CanvasScreen));
      Uint8List packet(InkPointerPhase phase, Offset point, int sequence) =>
          encodePointerPacket(
            pointerId: 10,
            device: InkPointerDevice.stylus,
            phase: phase,
            x: point.dx,
            y: point.dy,
            pressure: 1,
            timestampNs: sequence * 1_000_000,
            sequence: sequence,
          );

      Uint8List batch(List<Uint8List> samples) {
        final bytes = Uint8List(4 + samples.length * 48);
        final data = ByteData.sublistView(bytes);
        data.setUint16(0, 1, Endian.little);
        data.setUint16(2, samples.length, Endian.little);
        for (var index = 0; index < samples.length; index++) {
          bytes.setRange(
            4 + index * 48,
            4 + (index + 1) * 48,
            samples[index],
            4,
          );
        }
        return bytes;
      }

      packets.add(packet(InkPointerPhase.down, center, 1));
      await tester.pump(const Duration(milliseconds: 20));
      packets.add(
        batch([
          packet(InkPointerPhase.move, center + const Offset(12, 8), 2),
          packet(InkPointerPhase.move, center + const Offset(10000, 0), 3),
          ...List<Uint8List>.generate(
            80,
            (index) => packet(
              InkPointerPhase.move,
              center + Offset(10001 + index.toDouble(), 0),
              4 + index,
            ),
          ),
        ]),
      );
      await tester.pump(const Duration(milliseconds: 30));
      packets.add(
        packet(InkPointerPhase.up, center + const Offset(10100, 0), 84),
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(engine.sampleCounts, <int>[1, 2]);
      expect(engine.endCount, 1);
      expect(engine.cancelCount, 0);
      expect(find.bySemanticsLabel('Drawing canvas'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a new press recovers if an off-window stroke missed release', (
    tester,
  ) async {
    final engine = _RecordingPointerEngine();
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasScreen(
          engine: engine,
          targetPlatform: TargetPlatform.macOS,
        ),
      ),
    );
    await tester.pump();

    final abandoned = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      pointer: 1,
    );
    final center = tester.getCenter(find.byType(CanvasScreen));
    await abandoned.moveTo(center);
    await abandoned.down(center);
    await abandoned.moveTo(const Offset(10000, -10000));
    await tester.pump(const Duration(milliseconds: 20));

    // Model a desktop window losing the pointer-up while the mouse is outside.
    // A fresh press must cancel that stale transaction and start a new one.
    final nextStroke = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      pointer: 2,
    );
    await nextStroke.moveTo(center);
    await nextStroke.down(center);
    await tester.pump(const Duration(milliseconds: 20));
    expect(engine.beginCount, 2);
    expect(engine.cancelCount, 1);

    await nextStroke.moveBy(const Offset(18, 10));
    await nextStroke.up();
    await tester.pump(const Duration(milliseconds: 400));
    await abandoned.cancel();
    await tester.pump(const Duration(milliseconds: 20));

    expect(engine.pushCount, greaterThan(2));
    expect(find.bySemanticsLabel('Drawing canvas'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'focus loss cancels an off-window stroke and keeps editing usable',
    (tester) async {
      final engine = _RecordingPointerEngine();
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasScreen(
            engine: engine,
            targetPlatform: TargetPlatform.macOS,
          ),
        ),
      );
      await tester.pump();

      final center = tester.getCenter(find.bySemanticsLabel('Drawing canvas'));
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.moveTo(center);
      await gesture.down(center);
      await gesture.moveBy(const Offset(24, 16));
      await tester.pump(const Duration(milliseconds: 30));
      expect(engine.beginCount, 1);
      expect(engine.cancelCount, 0);

      // Model the app window losing focus while the pointer is still pressed,
      // so Flutter never delivers the matching pointer-up event.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(engine.cancelCount, 1);
      expect(engine.endCount, 0);
      expect(find.bySemanticsLabel('Drawing canvas'), findsOneWidget);

      final nextStroke = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        pointer: 2,
      );
      await nextStroke.moveTo(center);
      await nextStroke.down(center);
      await nextStroke.moveBy(const Offset(12, 8));
      await nextStroke.up();
      await tester.pump(const Duration(milliseconds: 300));

      expect(engine.beginCount, 2);
      expect(engine.endCount, 1);
      expect(tester.takeException(), isNull);
      await gesture.cancel();
    },
  );
}
