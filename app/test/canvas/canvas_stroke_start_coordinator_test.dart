import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/canvas/canvas_stroke_start_coordinator.dart';
import 'package:project_ink/layers/layer_panel_model.dart';

void main() {
  const paintLayer = LayerView(id: 7, name: 'Paint', kind: LayerKind.raster);

  test(
    'waits for a pending brush edit before beginning the Rust stroke',
    () async {
      final events = <String>[];
      final pendingEdit = Completer<void>();
      final coordinator = _coordinator(
        events: events,
        layers: const [paintLayer],
        primaryLayerId: 7,
        pendingEdit: pendingEdit.future,
      );

      final begin = coordinator.begin();
      await Future<void>.delayed(Duration.zero);
      expect(events, ['hold_begin', 'persist_size', 'wait_for_brush_edit']);

      pendingEdit.complete();
      expect(await begin, isTrue);
      expect(events.last, 'begin:12:7');
    },
  );

  test(
    'rejects a missing paint target and releases the autosave hold',
    () async {
      final events = <String>[];
      LayerView? rejectedLayer;
      var reportedVisibility = true;
      var reportedLock = true;
      final coordinator = _coordinator(
        events: events,
        layers: const [paintLayer],
        primaryLayerId: null,
        onRejected: (
          layer, {
          required effectivelyVisible,
          required effectivelyLocked,
        }) {
          rejectedLayer = layer;
          reportedVisibility = effectivelyVisible;
          reportedLock = effectivelyLocked;
        },
      );

      expect(await coordinator.begin(), isFalse);
      expect(rejectedLayer, isNull);
      expect(reportedVisibility, isFalse);
      expect(reportedLock, isFalse);
      expect(events, [
        'hold_begin',
        'persist_size',
        'hold_finish:invalid_layer_target',
        'reject:null',
      ]);
    },
  );

  test(
    'rejects hidden, locked, and non-paint targets without beginning a stroke',
    () async {
      for (final target in [
        const LayerView(
          id: 7,
          name: 'Hidden paint',
          kind: LayerKind.raster,
          visible: false,
        ),
        const LayerView(id: 7, name: 'Group', kind: LayerKind.group),
        const LayerView(id: 7, name: 'Vector', kind: LayerKind.vectorInk),
        const LayerView(
          id: 7,
          name: 'Hidden mask',
          kind: LayerKind.mask,
          visible: false,
        ),
        const LayerView(
          id: 7,
          name: 'Locked paint',
          kind: LayerKind.raster,
          locked: true,
        ),
        const LayerView(
          id: 7,
          name: 'Locked mask',
          kind: LayerKind.mask,
          locked: true,
        ),
      ]) {
        final events = <String>[];
        LayerView? rejectedLayer;
        final coordinator = _coordinator(
          events: events,
          layers: [target],
          primaryLayerId: 7,
          visible: target.visible,
          onRejected: (
            layer, {
            required effectivelyVisible,
            required effectivelyLocked,
          }) {
            rejectedLayer = layer;
          },
        );

        expect(await coordinator.begin(), isFalse);
        expect(rejectedLayer, same(target));
        expect(events, contains('hold_finish:invalid_layer_target'));
        expect(events.where((event) => event.startsWith('begin:')), isEmpty);
      }
    },
  );

  test('rejects a paint target beneath a locked group', () async {
    final events = <String>[];
    var reportedLock = false;
    final coordinator = _coordinator(
      events: events,
      primaryLayerId: 8,
      layers: const [
        LayerView(
          id: 7,
          name: 'Locked group',
          kind: LayerKind.group,
          locked: true,
        ),
        LayerView(id: 8, name: 'Mask', kind: LayerKind.mask, parent: 7),
      ],
      onRejected: (
        _, {
        required effectivelyVisible,
        required effectivelyLocked,
      }) {
        reportedLock = effectivelyLocked;
      },
    );

    expect(await coordinator.begin(), isFalse);
    expect(reportedLock, isTrue);
    expect(events, contains('hold_finish:invalid_layer_target'));
    expect(events.where((event) => event.startsWith('begin:')), isEmpty);
  });

  test('allows a selected mask through to the Rust stroke path', () async {
    final events = <String>[];
    const mask = LayerView(
      id: 8,
      name: 'Ink Mask',
      kind: LayerKind.mask,
      maskOwner: 7,
    );
    final coordinator = _coordinator(
      events: events,
      layers: [mask],
      primaryLayerId: mask.id,
    );

    expect(await coordinator.begin(), isTrue);
    expect(events, contains('begin:12:8'));
    expect(events.where((event) => event.startsWith('reject:')), isEmpty);
  });

  test(
    'a selected panel group routes drawing to its visible Ink layer',
    () async {
      final events = <String>[];
      final coordinator = _coordinator(
        events: events,
        primaryLayerId: 8,
        layers: const [
          LayerView(id: 8, name: 'Panel', kind: LayerKind.panelGroup),
          LayerView(id: 9, name: 'Sketch', kind: LayerKind.raster, parent: 8),
          LayerView(id: 10, name: 'Ink', kind: LayerKind.raster, parent: 8),
          LayerView(
            id: 11,
            name: 'Panel Mask',
            kind: LayerKind.mask,
            parent: 8,
          ),
        ],
        onSelectTarget: (id) => events.add('select:$id'),
      );

      expect(await coordinator.begin(), isTrue);
      expect(events, contains('select:10'));
      expect(events.last, 'begin:12:10');
      expect(events.where((event) => event.startsWith('reject:')), isEmpty);
    },
  );
}

CanvasStrokeStartCoordinator _coordinator({
  required List<String> events,
  required List<LayerView> layers,
  required int? primaryLayerId,
  bool visible = true,
  Future<void>? pendingEdit,
  void Function(
    LayerView? layer, {
    required bool effectivelyVisible,
    required bool effectivelyLocked,
  })?
  onRejected,
  void Function(int layerId)? onSelectTarget,
}) => CanvasStrokeStartCoordinator(
  CanvasStrokeStartHost(
    beginAutosaveHold: () => events.add('hold_begin'),
    finishAutosaveHold:
        ({required reason}) => events.add('hold_finish:$reason'),
    persistPendingQuickSize: () => events.add('persist_size'),
    activeBrushId: () => 12,
    pendingBrushEditForBrush: (_) {
      if (pendingEdit != null) events.add('wait_for_brush_edit');
      return pendingEdit;
    },
    primaryLayerId: () => primaryLayerId,
    layers: () => layers,
    layerEffectivelyVisible: (_) => visible,
    selectTargetLayer: (id) {
      final select = onSelectTarget;
      if (select != null) {
        select(id);
      } else {
        events.add('select:$id');
      }
    },
    showInvalidTarget: (
      layer, {
      required effectivelyVisible,
      required effectivelyLocked,
    }) {
      events.add('reject:${layer?.name}');
      onRejected?.call(
        layer,
        effectivelyVisible: effectivelyVisible,
        effectivelyLocked: effectivelyLocked,
      );
    },
    selectedBrush: () => null,
    recordStrokeBegin: (brushId, _) => events.add('record:$brushId'),
    beginBrushStrokeOnLayer:
        (brushId, targetLayerId) async =>
            events.add('begin:$brushId:$targetLayerId'),
  ),
);
