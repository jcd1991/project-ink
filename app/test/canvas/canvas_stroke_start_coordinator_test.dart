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
      final coordinator = _coordinator(
        events: events,
        layers: const [paintLayer],
        primaryLayerId: null,
        onRejected: (layer, {required effectivelyVisible}) {
          rejectedLayer = layer;
          reportedVisibility = effectivelyVisible;
        },
      );

      expect(await coordinator.begin(), isFalse);
      expect(rejectedLayer, isNull);
      expect(reportedVisibility, isFalse);
      expect(events, [
        'hold_begin',
        'persist_size',
        'hold_finish:invalid_layer_target',
      ]);
    },
  );

  test(
    'rejects hidden and non-raster targets without beginning a stroke',
    () async {
      for (final target in [
        const LayerView(
          id: 7,
          name: 'Hidden paint',
          kind: LayerKind.raster,
          visible: false,
        ),
        const LayerView(id: 7, name: 'Group', kind: LayerKind.group),
      ]) {
        final events = <String>[];
        LayerView? rejectedLayer;
        final coordinator = _coordinator(
          events: events,
          layers: [target],
          primaryLayerId: 7,
          visible: target.visible,
          onRejected: (layer, {required effectivelyVisible}) {
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
}

CanvasStrokeStartCoordinator _coordinator({
  required List<String> events,
  required List<LayerView> layers,
  required int? primaryLayerId,
  bool visible = true,
  Future<void>? pendingEdit,
  void Function(LayerView? layer, {required bool effectivelyVisible})?
  onRejected,
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
    showInvalidTarget:
        (layer, {required effectivelyVisible}) =>
            onRejected?.call(layer, effectivelyVisible: effectivelyVisible),
    selectedBrush: () => null,
    recordStrokeBegin: (brushId, _) => events.add('record:$brushId'),
    beginBrushStrokeOnLayer:
        (brushId, targetLayerId) async =>
            events.add('begin:$brushId:$targetLayerId'),
  ),
);
