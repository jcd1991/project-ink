import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../bridge/engine_api.dart';
import '../layers/layer_panel_model.dart';

class _LayerOpacityGesture {
  _LayerOpacityGesture(this.engine, this.layerId);

  final EngineApi engine;
  final int layerId;
  int? editId;
}

/// Screen-owned state and services used by [CanvasLayerActions].
class CanvasLayerActionHost {
  const CanvasLayerActionHost({
    required this.engine,
    required this.mounted,
    required this.setState,
    required this.layers,
    required this.selection,
    required this.engineGeneration,
    required this.loadPhase2Projections,
    required this.refreshTiles,
    required this.markDirty,
    required this.soloLayerId,
    required this.setSoloLayerId,
    required this.selectLayerContents,
    required this.showMessage,
    required this.setAdjustmentEditActive,
  });

  final EngineApi Function() engine;
  final bool Function() mounted;
  final void Function(VoidCallback callback) setState;
  final List<LayerView> Function() layers;
  final LayerSelectionModel Function() selection;
  final int Function() engineGeneration;
  final Future<void> Function() loadPhase2Projections;
  final Future<void> Function() refreshTiles;
  final void Function() markDirty;
  final int? Function() soloLayerId;
  final ValueChanged<int?> setSoloLayerId;
  final void Function() selectLayerContents;
  final void Function(String message) showMessage;
  final ValueChanged<bool> setAdjustmentEditActive;
}

/// Owns Rust-backed layer commands and preserves their serialized UI state.
class CanvasLayerActions {
  CanvasLayerActions(this.host);

  final CanvasLayerActionHost host;
  EngineApi get engine => host.engine();
  List<LayerView> get layers => host.layers();
  LayerSelectionModel get selection => host.selection();
  int get engineGeneration => host.engineGeneration();
  int? get soloLayerId => host.soloLayerId();
  set soloLayerId(int? value) => host.setSoloLayerId(value);
  Future<void> get panelStateQueue => _panelStateQueue;
  Future<void> get opacityQueue => _opacityQueue;
  Future<void> get adjustmentQueue => _adjustmentQueue;
  bool get hasActiveOpacityEdit => _activeOpacityGesture != null;

  Future<void> loadPhase2Projections() => host.loadPhase2Projections();
  Future<void> refreshTiles() => host.refreshTiles();
  Future<void> get idle async {
    await _opacityQueue;
    await _adjustmentQueue;
    await _panelStateQueue;
  }

  Future<void> _panelStateQueue = Future<void>.value();
  Future<void> _opacityQueue = Future<void>.value();
  Future<void> _adjustmentQueue = Future<void>.value();
  _LayerOpacityGesture? _activeOpacityGesture;
  int? _activeAdjustmentEditId;

  Future<void> addLayer(LayerKind kind) async {
    final wireKind = switch (kind) {
      LayerKind.raster => 'Raster',
      LayerKind.vectorInk => 'VectorInk',
      LayerKind.group => 'Group',
      LayerKind.mask => 'Mask',
      LayerKind.tone => 'Tone',
      LayerKind.panelGroup => 'PanelGroup',
      LayerKind.adjustment => 'Adjustment',
    };
    try {
      final selectedParentId = selectedLayerParentForAdd(
        kind,
        layers,
        selection.selected,
      );
      final id =
          selectedParentId == null
              ? await engine.addLayer(kind: wireKind)
              : await engine.addLayerToParent(
                kind: wireKind,
                parentId: selectedParentId,
              );
      await loadPhase2Projections();
      selection.select(id);
      queuePanelStatePersistence();
      if (host.mounted()) host.setState(() {});
    } catch (error, stack) {
      debugPrint('Project Ink layer creation rejected: $error\n$stack');
    }
  }

  Future<void> moveLayerBy(LayerView layer, int delta) async {
    final siblings = layers
      .where((candidate) => candidate.parent == layer.parent)
      .toList(growable: false)..sort((left, right) {
      final order = left.order.compareTo(right.order);
      return order != 0 ? order : left.id.compareTo(right.id);
    });
    final current = siblings.indexWhere(
      (candidate) => candidate.id == layer.id,
    );
    if (current < 0) return;
    final target = (current + delta).clamp(0, siblings.length - 1);
    if (target == current) return;
    try {
      await engine.moveLayer(
        layerId: layer.id,
        parentId: layer.parent,
        index: target,
      );
      await loadPhase2Projections();
      await refreshTiles();
    } catch (error, stack) {
      debugPrint('Project Ink layer reorder rejected: $error\n$stack');
    }
  }

  Future<void> moveLayerToGroup(LayerView layer, int? parentId) async {
    final index =
        layers.where((candidate) => candidate.parent == parentId).length;
    try {
      await engine.moveLayer(
        layerId: layer.id,
        parentId: parentId,
        index: index,
      );
      await loadPhase2Projections();
      await refreshTiles();
    } catch (error, stack) {
      debugPrint('Project Ink layer reparent rejected: $error\n$stack');
    }
  }

  Future<void> reorderLayerToIndex(LayerView layer, int index) async {
    try {
      await engine.moveLayer(
        layerId: layer.id,
        parentId: layer.parent,
        index: index,
      );
      await loadPhase2Projections();
      await refreshTiles();
    } catch (error, stack) {
      debugPrint('Project Ink layer drag reorder rejected: $error\n$stack');
    }
  }

  Future<void> reorderLayersToIndex(List<LayerView> layers, int index) async {
    try {
      await engine.reorderLayers(
        layerIds: layers.map((layer) => layer.id).toList(growable: false),
        index: index,
      );
      await loadPhase2Projections();
      await refreshTiles();
    } catch (error, stack) {
      debugPrint('Project Ink selected layer reorder rejected: $error\n$stack');
    }
  }

  Future<void> groupSelectedLayers(List<LayerView> selected) async {
    try {
      final groupId = await engine.groupLayers(
        layerIds: selected.map((layer) => layer.id).toList(growable: false),
      );
      await loadPhase2Projections();
      selection.select(groupId);
      queuePanelStatePersistence();
      await refreshTiles();
      if (host.mounted()) host.setState(() {});
    } catch (error, stack) {
      debugPrint('Project Ink layer grouping rejected: $error\n$stack');
    }
  }

  Future<void> duplicateSelectedLayers(List<LayerView> selected) async {
    if (selected.length < 2) return;
    try {
      final duplicateIds = await engine.duplicateLayers(
        layerIds: selected.map((layer) => layer.id).toList(growable: false),
      );
      await loadPhase2Projections();
      selection.clear();
      for (final id in duplicateIds) {
        if (layers.any((layer) => layer.id == id)) selection.select(id);
      }
      queuePanelStatePersistence();
      await refreshTiles();
      if (host.mounted()) host.setState(() {});
    } catch (error, stack) {
      debugPrint(
        'Project Ink selected layer duplication rejected: $error\\n$stack',
      );
      if (host.mounted()) await loadPhase2Projections();
    }
  }

  Future<void> mergeSelectedLayers(List<LayerView> selected) async {
    if (selected.length < 2) return;
    try {
      final targetId = await engine.mergeLayersBulk(
        layerIds: selected.map((layer) => layer.id).toList(growable: false),
      );
      await loadPhase2Projections();
      selection.select(targetId);
      queuePanelStatePersistence();
      await refreshTiles();
      if (host.mounted()) host.setState(() {});
    } catch (error, stack) {
      debugPrint('Project Ink selected layer merge rejected: $error\\n$stack');
      if (host.mounted()) await loadPhase2Projections();
    }
  }

  Future<void> setSelectedLayersVisibility(
    List<LayerView> selected,
    bool visible,
  ) async {
    if (selected.isEmpty) return;
    try {
      await engine.setLayersVisibility(
        layerIds: selected.map((layer) => layer.id).toList(growable: false),
        visible: visible,
      );
      await loadPhase2Projections();
      await refreshTiles();
      if (host.mounted()) host.setState(() {});
    } catch (error, stack) {
      debugPrint('Project Ink bulk visibility change rejected: $error\n$stack');
    }
  }

  Future<void> setSelectedLayersLocked(
    List<LayerView> selected,
    bool locked,
  ) async {
    if (selected.isEmpty) return;
    try {
      await engine.setLayersLocked(
        layerIds: selected.map((layer) => layer.id).toList(growable: false),
        locked: locked,
      );
      await loadPhase2Projections();
      if (host.mounted()) host.setState(() {});
    } catch (error, stack) {
      debugPrint('Project Ink bulk lock change rejected: $error\n$stack');
    }
  }

  Future<void> setSelectedLayersLabel(
    List<LayerView> selected,
    int? labelRgba,
  ) async {
    if (selected.isEmpty) return;
    try {
      await engine.setLayersLabel(
        layerIds: selected.map((layer) => layer.id).toList(growable: false),
        labelRgba: labelRgba,
      );
      await loadPhase2Projections();
      if (host.mounted()) host.setState(() {});
    } catch (error, stack) {
      debugPrint('Project Ink bulk label change rejected: $error\n$stack');
    }
  }

  Future<void> ungroupLayer(LayerView layer) async {
    try {
      await engine.ungroupLayer(groupId: layer.id);
      await loadPhase2Projections();
      await refreshTiles();
      if (host.mounted()) host.setState(() {});
    } catch (error, stack) {
      debugPrint('Project Ink layer ungroup rejected: $error\n$stack');
    }
  }

  Future<void> deleteSelectedLayers(List<LayerView> selected) async {
    if (selected.isEmpty) return;
    final roots = selected.map((layer) => layer.id).toSet();
    final byId = {for (final layer in layers) layer.id: layer};
    final removed = <int>{};
    for (final rootId in roots) {
      final pending = <int>[rootId];
      for (var index = 0; index < pending.length; index++) {
        final parentId = pending[index];
        if (!removed.add(parentId)) continue;
        pending.addAll(
          layers
              .where((candidate) => candidate.parent == parentId)
              .map((candidate) => candidate.id),
        );
      }
    }
    final fallback =
        layers.where((layer) => !removed.contains(layer.id)).firstOrNull?.id;
    try {
      await engine.deleteLayers(
        layerIds: selected.map((layer) => layer.id).toList(growable: false),
      );
      await loadPhase2Projections();
      selection.clear();
      if (fallback != null &&
          byId.containsKey(fallback) &&
          layers.any((layer) => layer.id == fallback)) {
        selection.select(fallback);
      } else if (layers.isNotEmpty) {
        selection.select(layers.last.id);
      }
      queuePanelStatePersistence();
      await refreshTiles();
      if (host.mounted()) host.setState(() {});
    } catch (error, stack) {
      debugPrint('Project Ink bulk layer deletion rejected: $error\\n$stack');
      if (host.mounted()) await loadPhase2Projections();
    }
  }

  Future<void> deleteLayer(LayerView layer) async {
    final siblings = layers
      .where((candidate) => candidate.parent == layer.parent)
      .toList(growable: false)..sort((left, right) {
      final order = left.order.compareTo(right.order);
      return order != 0 ? order : left.id.compareTo(right.id);
    });
    final index = siblings.indexWhere((candidate) => candidate.id == layer.id);
    final nextSelection =
        siblings.length > 1 ? siblings[index == 0 ? 1 : index - 1].id : null;
    try {
      await engine.deleteLayer(layerId: layer.id);
      await loadPhase2Projections();
      selection.clear();
      if (nextSelection != null &&
          layers.any((item) => item.id == nextSelection)) {
        selection.select(nextSelection);
      } else if (layers.isNotEmpty) {
        selection.select(layers.last.id);
      }
      queuePanelStatePersistence();
      await refreshTiles();
      if (host.mounted()) host.setState(() {});
    } catch (error, stack) {
      debugPrint('Project Ink layer deletion rejected: $error\\n$stack');
      if (host.mounted()) await loadPhase2Projections();
    }
  }

  Future<void> duplicateLayer(LayerView layer) async {
    try {
      final duplicateId = await engine.duplicateLayer(layerId: layer.id);
      await loadPhase2Projections();
      selection.clear();
      if (layers.any((candidate) => candidate.id == duplicateId)) {
        selection.select(duplicateId);
      }
      queuePanelStatePersistence();
      await refreshTiles();
      if (host.mounted()) host.setState(() {});
    } catch (error, stack) {
      debugPrint('Project Ink layer duplication rejected: $error\n$stack');
      if (host.mounted()) await loadPhase2Projections();
    }
  }

  void applyLayerChange(LayerView changed) {
    if (!host.mounted()) return;
    unawaited(commitLayerChange(changed));
  }

  void queuePanelStatePersistence() {
    final currentEngine = engine;
    final generation = engineGeneration;
    final primaryLayerId = selection.primaryId;
    final collapsedGroupIds = selection.collapsedGroups.toList()..sort();
    Future<void> persist() async {
      if (!host.mounted() ||
          generation != engineGeneration ||
          currentEngine != engine) {
        return;
      }
      try {
        final previousRevision = currentEngine.revision;
        await currentEngine.setLayerPanelState(
          primaryLayerId: primaryLayerId,
          collapsedGroupIds: collapsedGroupIds,
        );
        if (currentEngine.revision != previousRevision) {
          host.markDirty();
        }
      } catch (error, stack) {
        debugPrint('Project Ink layer-panel state save failed: $error\n$stack');
      }
    }

    _panelStateQueue = _panelStateQueue.then(
      (_) => persist(),
      onError: (Object _, StackTrace __) => persist(),
    );
  }

  Future<void> toggleLayerSolo(LayerView layer) async {
    final nextLayerId = soloLayerId == layer.id ? null : layer.id;
    try {
      await engine.setLayerSolo(layerId: nextLayerId);
      if (!host.mounted()) return;
      host.setState(() => soloLayerId = nextLayerId);
      await refreshTiles();
    } catch (error, stack) {
      debugPrint('Project Ink layer solo rejected: $error\n$stack');
    }
  }

  Future<void> clearLayerSolo(EngineApi engine) async {
    try {
      await engine.setLayerSolo(layerId: null);
    } catch (error, stack) {
      debugPrint('Project Ink layer solo cleanup failed: $error\n$stack');
    }
  }

  Future<void> clearLayerContent(LayerView layer) async {
    if (!layer.canEditProperties || layer.locked) {
      host.showMessage(
        layer.editPropertiesReason ?? 'Unlock this layer first.',
      );
      return;
    }
    try {
      await engine.clearLayer(layerId: layer.id);
      await loadPhase2Projections();
      await refreshTiles();
      host.markDirty();
      if (host.mounted()) host.setState(() {});
    } catch (error, stack) {
      debugPrint('Project Ink layer clear rejected: $error\n$stack');
    }
  }

  void applyLayerPresentation(LayerView changed) {
    if (!host.mounted()) return;
    unawaited(commitLayerPresentation(changed));
  }

  void beginLayerOpacityEdit(LayerView layer) {
    final current = _activeOpacityGesture;
    if (current != null) _finishLayerOpacityEdit(current, commit: true);
    final gesture = _LayerOpacityGesture(engine, layer.id);
    _activeOpacityGesture = gesture;
    queueLayerOpacityOperation(() async {
      gesture.editId = await gesture.engine.beginLayerOpacityEdit(
        layerId: gesture.layerId,
      );
    });
  }

  void previewLayerOpacityEdit(LayerView layer, double opacity) {
    final gesture = _activeOpacityGesture;
    if (gesture == null || gesture.layerId != layer.id) return;
    queueLayerOpacityOperation(() async {
      final editId = gesture.editId;
      if (editId == null) return;
      await gesture.engine.updateLayerOpacityEdit(
        editId: editId,
        opacity: opacity,
      );
      await refreshTiles();
    });
  }

  void commitLayerOpacityEdit(LayerView layer) {
    final gesture = _activeOpacityGesture;
    if (gesture != null && gesture.layerId == layer.id) {
      _finishLayerOpacityEdit(gesture, commit: true);
    }
  }

  void cancelLayerOpacityEdit(LayerView layer) {
    final gesture = _activeOpacityGesture;
    if (gesture != null && gesture.layerId == layer.id) {
      _finishLayerOpacityEdit(gesture, commit: false);
    }
  }

  void finishActiveOpacityEdit({required bool commit}) {
    final gesture = _activeOpacityGesture;
    if (gesture != null) _finishLayerOpacityEdit(gesture, commit: commit);
  }

  void _finishLayerOpacityEdit(
    _LayerOpacityGesture gesture, {
    required bool commit,
  }) {
    if (identical(_activeOpacityGesture, gesture)) {
      _activeOpacityGesture = null;
    }
    queueLayerOpacityOperation(() async {
      final editId = gesture.editId;
      if (editId == null) return;
      if (commit) {
        await gesture.engine.commitLayerOpacityEdit(editId: editId);
      } else {
        await gesture.engine.cancelLayerOpacityEdit(editId: editId);
      }
      if (host.mounted()) {
        await refreshTiles();
        await loadPhase2Projections();
      }
    });
  }

  void queueLayerOpacityOperation(Future<void> Function() operation) {
    _opacityQueue = _opacityQueue.then((_) => operation()).catchError((
      Object error,
      StackTrace stack,
    ) {
      debugPrint('Project Ink opacity edit failed: $error\n$stack');
    });
  }

  void applyLayerAdjustment(LayerView changed) {
    if (!host.mounted()) return;
    unawaited(commitLayerAdjustment(changed));
  }

  Future<void> commitLayerAdjustment(LayerView changed) async {
    try {
      await engine.setLayerBrightnessContrast(
        layerId: changed.id,
        brightness: changed.adjustmentBrightness,
        contrast: changed.adjustmentContrast,
      );
      await refreshTiles();
    } catch (error, stack) {
      debugPrint('Project Ink adjustment update rejected: $error\\n$stack');
    } finally {
      if (host.mounted()) await loadPhase2Projections();
    }
  }

  Future<int> beginLayerAdjustmentEdit(int layerId) async {
    host.setAdjustmentEditActive(true);
    try {
      final editId = await _queueAdjustmentOperation(
        () => engine.beginLayerAdjustmentEdit(layerId: layerId),
      );
      _activeAdjustmentEditId = editId;
      return editId;
    } on Object {
      host.setAdjustmentEditActive(false);
      rethrow;
    }
  }

  Future<void> updateLayerAdjustmentEdit(int editId, String adjustmentJson) =>
      _queueAdjustmentOperation(() async {
        await engine.updateLayerAdjustmentEdit(
          editId: editId,
          adjustmentJson: adjustmentJson,
        );
        if (host.mounted()) {
          await refreshTiles();
        }
      });

  Future<void> commitLayerAdjustmentEdit(int editId) =>
      _queueAdjustmentOperation(() async {
        await engine.commitLayerAdjustmentEdit(editId: editId);
        _finishAdjustmentEdit(editId);
        if (host.mounted()) {
          host.markDirty();
          await refreshTiles();
          await loadPhase2Projections();
        }
      });

  Future<void> cancelLayerAdjustmentEdit(int editId) =>
      _queueAdjustmentOperation(() async {
        await engine.cancelLayerAdjustmentEdit(editId: editId);
        _finishAdjustmentEdit(editId);
        if (host.mounted()) {
          await refreshTiles();
          await loadPhase2Projections();
        }
      });

  void _finishAdjustmentEdit(int editId) {
    if (_activeAdjustmentEditId != editId) return;
    _activeAdjustmentEditId = null;
    host.setAdjustmentEditActive(false);
  }

  Future<T> _queueAdjustmentOperation<T>(Future<T> Function() operation) {
    final next = _adjustmentQueue
        .catchError((Object _) {})
        .then((_) => operation());
    _adjustmentQueue = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return next;
  }

  Future<void> commitLayerChange(LayerView changed) async {
    try {
      final previous = layers.where((layer) => layer.id == changed.id);
      final wasLocked = previous.isNotEmpty && previous.first.locked;
      if (soloLayerId != null &&
          previous.isNotEmpty &&
          previous.first.visible != changed.visible) {
        await engine.setLayerSolo(layerId: null);
        soloLayerId = null;
      }
      if (wasLocked && !changed.locked) {
        // Unlock before property writes: the Rust layer lock correctly rejects
        // property edits until the lock command has committed.
        await engine.setLayerLocked(layerId: changed.id, locked: false);
      }
      await engine.updateLayerProperties(
        layerId: changed.id,
        visible: changed.visible,
        opacity: changed.opacity,
        alphaLock: changed.alphaLock,
        clipping: changed.clipping,
        reference: changed.reference,
      );
      if (!wasLocked && changed.locked) {
        await engine.setLayerLocked(layerId: changed.id, locked: true);
      }
    } catch (error, stack) {
      debugPrint('Project Ink layer update rejected: $error\n$stack');
    } finally {
      if (host.mounted()) await loadPhase2Projections();
    }
  }

  Future<void> setMaskEnabled(LayerView layer) async {
    try {
      await engine.setMaskEnabled(maskId: layer.id, enabled: layer.maskEnabled);
      await refreshTiles();
    } catch (error, stack) {
      debugPrint('Project Ink mask enable change rejected: $error\\n$stack');
    } finally {
      if (host.mounted()) await loadPhase2Projections();
    }
  }

  Future<void> setMaskInverted(LayerView layer) async {
    try {
      await engine.setMaskInverted(
        maskId: layer.id,
        inverted: layer.maskInverted,
      );
      await refreshTiles();
    } catch (error, stack) {
      debugPrint('Project Ink mask inversion rejected: $error\\n$stack');
    } finally {
      if (host.mounted()) await loadPhase2Projections();
    }
  }

  Future<void> applyLayerMask(LayerView layer) async {
    try {
      await engine.applyLayerMask(maskId: layer.id);
      await refreshTiles();
    } catch (error, stack) {
      debugPrint('Project Ink mask apply rejected: $error\n$stack');
    } finally {
      if (host.mounted()) await loadPhase2Projections();
    }
  }

  Future<void> selectLayerContents(LayerView layer) async {
    try {
      await engine.selectLayerOpacity(layerId: layer.id, minimumAlpha: 1);
      if (host.mounted()) host.selectLayerContents();
    } catch (error, stack) {
      debugPrint(
        'Project Ink layer contents selection rejected: $error\n$stack',
      );
    }
  }

  Future<void> mergeLayers(LayerView source, LayerView target) async {
    if (source.kind != LayerKind.raster || target.kind != LayerKind.raster) {
      debugPrint('Project Ink layer merge requires two raster layers');
      return;
    }
    try {
      await engine.mergeLayers(
        targetLayerId: target.id,
        sourceLayerId: source.id,
      );
      await loadPhase2Projections();
      selection.select(target.id);
      queuePanelStatePersistence();
      await refreshTiles();
      if (host.mounted()) host.setState(() {});
    } catch (error, stack) {
      debugPrint('Project Ink layer merge rejected: $error\n$stack');
      if (host.mounted()) {
        host.showMessage('Merge not applied: $error');
      }
    }
  }

  Future<String?> preflightMergeLayers(
    LayerView source,
    LayerView target,
  ) async {
    return engine.preflightMergeLayers(
      targetLayerId: target.id,
      sourceLayerId: source.id,
    );
  }

  Future<void> commitLayerPresentation(LayerView changed) async {
    final blendMode = switch (changed.blendMode) {
      LayerBlendMode.normal => 'Normal',
      LayerBlendMode.multiply => 'Multiply',
      LayerBlendMode.screen => 'Screen',
      LayerBlendMode.overlay => 'Overlay',
      LayerBlendMode.darken => 'Darken',
      LayerBlendMode.lighten => 'Lighten',
      LayerBlendMode.add => 'Add',
      LayerBlendMode.subtract => 'Subtract',
      LayerBlendMode.colorBurn => 'Color Burn',
      LayerBlendMode.linearBurn => 'Linear Burn',
      LayerBlendMode.colorDodge => 'Color Dodge',
      LayerBlendMode.softLight => 'Soft Light',
      LayerBlendMode.hardLight => 'Hard Light',
      LayerBlendMode.difference => 'Difference',
      LayerBlendMode.exclusion => 'Exclusion',
      LayerBlendMode.divide => 'Divide',
    };
    final groupMode = switch (changed.groupMode) {
      LayerGroupMode.isolated => 'Isolated',
      LayerGroupMode.passThrough => 'Pass-through',
    };
    try {
      await engine.updateLayerPresentation(
        layerId: changed.id,
        name: changed.name,
        blendMode: blendMode,
        groupMode: groupMode,
        labelRgba:
            changed.label == null || changed.label == 0 ? null : changed.label,
      );
    } catch (error, stack) {
      debugPrint('Project Ink layer presentation rejected: $error\n$stack');
    } finally {
      if (host.mounted()) await loadPhase2Projections();
    }
  }
}
