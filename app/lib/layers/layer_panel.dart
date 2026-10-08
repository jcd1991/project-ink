import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design_system/ink_components.dart';
import 'layer_panel_model.dart';

LayerBlendMode _blendModeFromWire(String value) => switch (value) {
  'Multiply' => LayerBlendMode.multiply,
  'Screen' => LayerBlendMode.screen,
  'Overlay' => LayerBlendMode.overlay,
  'Darken' => LayerBlendMode.darken,
  'Lighten' => LayerBlendMode.lighten,
  'Add' => LayerBlendMode.add,
  'Subtract' => LayerBlendMode.subtract,
  'Color Burn' => LayerBlendMode.colorBurn,
  'Linear Burn' => LayerBlendMode.linearBurn,
  'Color Dodge' => LayerBlendMode.colorDodge,
  'Soft Light' => LayerBlendMode.softLight,
  'Hard Light' => LayerBlendMode.hardLight,
  'Difference' => LayerBlendMode.difference,
  'Exclusion' => LayerBlendMode.exclusion,
  'Divide' => LayerBlendMode.divide,
  _ => LayerBlendMode.normal,
};

bool _isPassThroughGroup(LayerView layer) =>
    (layer.kind == LayerKind.group || layer.kind == LayerKind.panelGroup) &&
    layer.groupMode == LayerGroupMode.passThrough;

List<LayerView> _normalizeReorderRoots(
  List<LayerView> selectedSiblings,
  List<LayerView> allLayers,
) {
  final byId = {for (final layer in allLayers) layer.id: layer};
  final selectedIds =
      selectedSiblings.map((layer) => layer.maskOwner ?? layer.id).toSet();
  return selectedIds
      .where((id) {
        var parentId = byId[id]?.parent;
        final visited = <int>{id};
        while (parentId != null && visited.add(parentId)) {
          if (selectedIds.contains(parentId)) return false;
          parentId = byId[parentId]?.parent;
        }
        return true;
      })
      .map((id) => byId[id])
      .whereType<LayerView>()
      .toList(growable: false);
}

enum _LayerPanelAction {
  toggleSelectMode,
  selectAll,
  deselectAll,
  groupSelected,
  duplicateSelected,
  mergeSelected,
  deleteSelected,
  setSelectedVisibility,
  setSelectedLocked,
  setSelectedLabelRed,
  setSelectedLabelBlue,
  clearSelectedLabel,
}

enum _LayerDropPlacement { before, after, inside }

/// Layer list that supports touch-friendly multiselect while leaving all
/// mutations to the shared Rust command IDs.
class LayerPanel extends StatelessWidget {
  const LayerPanel({
    super.key,
    required this.layers,
    required this.selection,
    this.studioMode = true,
    this.soloLayerId,
    this.onSelectionChanged,
    this.onLayerChanged,
    this.onSoloLayer,
    this.onOpacityEditStarted,
    this.onOpacityPreviewChanged,
    this.onOpacityEditCommitted,
    this.onOpacityEditCancelled,
    this.onPresentationChanged,
    this.onAdjustmentChanged,
    this.onAddLayer,
    this.onMoveLayer,
    this.onReorderLayer,
    this.onReorderLayers,
    this.onMoveLayerTo,
    this.onGroupLayers,
    this.onPreflightGroupLayers,
    this.onDuplicateLayers,
    this.onMergeSelected,
    this.onUngroupLayer,
    this.onDeleteLayers,
    this.onPreflightDeleteLayers,
    this.onSetLayersVisibility,
    this.onSetLayersLocked,
    this.onSetLayersLabel,
    this.onDeleteLayer,
    this.onClearLayer,
    this.onDuplicateLayer,
    this.onSelectContents,
    this.onMergeLayers,
    this.onPreflightMergeLayers,
    this.onMaskEnabledChanged,
    this.onMaskInvertedChanged,
    this.onApplyMask,
  });

  final List<LayerView> layers;
  final LayerSelectionModel selection;
  final bool studioMode;
  final int? soloLayerId;
  final ValueChanged<Set<int>>? onSelectionChanged;
  final ValueChanged<LayerView>? onLayerChanged;
  final ValueChanged<LayerView>? onSoloLayer;
  final ValueChanged<LayerView>? onOpacityEditStarted;
  final void Function(LayerView, double)? onOpacityPreviewChanged;
  final ValueChanged<LayerView>? onOpacityEditCommitted;
  final ValueChanged<LayerView>? onOpacityEditCancelled;
  final ValueChanged<LayerView>? onPresentationChanged;
  final ValueChanged<LayerView>? onAdjustmentChanged;
  final ValueChanged<LayerKind>? onAddLayer;
  final void Function(LayerView layer, int delta)? onMoveLayer;
  final void Function(LayerView layer, int index)? onReorderLayer;
  final void Function(List<LayerView> layers, int index)? onReorderLayers;
  final void Function(LayerView layer, int? parentId)? onMoveLayerTo;
  final ValueChanged<List<LayerView>>? onGroupLayers;
  final Future<String?> Function(List<LayerView>)? onPreflightGroupLayers;
  final ValueChanged<List<LayerView>>? onDuplicateLayers;
  final ValueChanged<List<LayerView>>? onMergeSelected;
  final ValueChanged<LayerView>? onUngroupLayer;
  final ValueChanged<List<LayerView>>? onDeleteLayers;
  final Future<String?> Function(List<LayerView>)? onPreflightDeleteLayers;
  final void Function(List<LayerView> layers, bool visible)?
  onSetLayersVisibility;
  final void Function(List<LayerView> layers, bool locked)? onSetLayersLocked;
  final void Function(List<LayerView> layers, int? labelRgba)? onSetLayersLabel;
  final ValueChanged<LayerView>? onDeleteLayer;
  final ValueChanged<LayerView>? onClearLayer;
  final ValueChanged<LayerView>? onDuplicateLayer;
  final ValueChanged<LayerView>? onSelectContents;
  final void Function(LayerView source, LayerView target)? onMergeLayers;
  final Future<String?> Function(LayerView source, LayerView target)?
  onPreflightMergeLayers;
  final ValueChanged<LayerView>? onMaskEnabledChanged;
  final ValueChanged<LayerView>? onMaskInvertedChanged;
  final ValueChanged<LayerView>? onApplyMask;

  @override
  Widget build(BuildContext context) {
    final orderedLayers = orderLayerTree(layers);
    final layerById = {for (final layer in orderedLayers) layer.id: layer};
    final visibleLayers = orderedLayers
        .where((layer) {
          var parent = layer.parent;
          final visited = <int>{};
          while (parent != null && visited.add(parent)) {
            if (selection.collapsedGroups.contains(parent)) return false;
            parent = layerById[parent]?.parent;
          }
          return true;
        })
        .toList(growable: false);
    final inspector =
        orderedLayers
            .where((layer) => layer.id == selection.primaryId)
            .firstOrNull;
    final inspectorLockOwner =
        inspector == null
            ? null
            : _effectiveLockOwner(inspector, orderedLayers);
    return LayoutBuilder(
      builder: (context, constraints) {
        // A dock can be short even when the app window is tall (for example
        // when the canvas and two other palettes share the available height).
        final showStudio = studioMode && constraints.maxHeight >= 520;
        return Column(
          children: [
            if (showStudio && inspector != null)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: SingleChildScrollView(
                  child:
                      inspectorLockOwner != null
                          ? ListTile(
                            leading: const Icon(Icons.lock),
                            title: Text(
                              inspectorLockOwner.id == inspector.id
                                  ? 'Layer locked'
                                  : 'Locked by ${inspectorLockOwner.name}',
                            ),
                            subtitle: const Text(
                              'Unlock to edit this layer’s properties.',
                            ),
                          )
                          : InkInspectorSection(
                            key: ValueKey<String>(
                              'layer-inspector-${inspector.id}-${inspector.kind.name}',
                            ),
                            title: 'Layer properties',
                            child: _LayerProperties(
                              layer: inspector,
                              onChanged: onLayerChanged,
                              onOpacityEditStarted: onOpacityEditStarted,
                              onOpacityPreviewChanged: onOpacityPreviewChanged,
                              onOpacityEditCommitted: onOpacityEditCommitted,
                              onOpacityEditCancelled: onOpacityEditCancelled,
                              onPresentationChanged: onPresentationChanged,
                              onAdjustmentChanged: onAdjustmentChanged,
                            ),
                          ),
                ),
              ),
            if (onAddLayer != null)
              LayoutBuilder(
                builder: (context, constraints) {
                  // Leave room for the three fixed-size menu buttons and
                  // horizontal padding in docked/narrow panels.
                  final compactHeader = constraints.maxWidth < 420;
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Layers',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        _addLayerChip(
                          context,
                          label: compactHeader ? 'Add' : 'Add paint layer',
                          icon: Icons.add,
                          kind: LayerKind.raster,
                        ),
                        PopupMenuButton<LayerKind>(
                          tooltip: 'New layer options',
                          icon: const Icon(Icons.more_horiz),
                          onSelected: onAddLayer,
                          itemBuilder:
                              (context) => const [
                                PopupMenuItem(
                                  value: LayerKind.vectorInk,
                                  child: Text('Vector layer'),
                                ),
                                PopupMenuItem(
                                  value: LayerKind.group,
                                  child: Text('Group'),
                                ),
                                PopupMenuItem(
                                  value: LayerKind.mask,
                                  child: Text('Attached mask'),
                                ),
                                PopupMenuItem(
                                  value: LayerKind.tone,
                                  child: Text('Tone layer'),
                                ),
                                PopupMenuItem(
                                  value: LayerKind.adjustment,
                                  child: Text('Adjustment layer'),
                                ),
                                PopupMenuItem(
                                  value: LayerKind.panelGroup,
                                  child: Text('Panel group'),
                                ),
                              ],
                        ),
                        PopupMenuButton<_LayerPanelAction>(
                          tooltip: 'Layer selection and bulk actions',
                          icon: const Icon(Icons.checklist),
                          onSelected: (action) {
                            switch (action) {
                              case _LayerPanelAction.selectAll:
                                selection.selectAll(
                                  orderedLayers.map((layer) => layer.id),
                                );
                                onSelectionChanged?.call(
                                  selection.selected.toSet(),
                                );
                                break;
                              case _LayerPanelAction.toggleSelectMode:
                                selection.toggleSelectMode();
                                onSelectionChanged?.call(
                                  selection.selected.toSet(),
                                );
                                break;
                              case _LayerPanelAction.deselectAll:
                                selection.deselectAll();
                                onSelectionChanged?.call(
                                  selection.selected.toSet(),
                                );
                                break;
                              case _LayerPanelAction.groupSelected:
                                _groupSelected(context, orderedLayers);
                                break;
                              case _LayerPanelAction.duplicateSelected:
                                final selected =
                                    orderedLayers
                                        .where(
                                          (layer) => selection.selected
                                              .contains(layer.id),
                                        )
                                        .toList()
                                      ..sort((left, right) {
                                        final order = left.order.compareTo(
                                          right.order,
                                        );
                                        return order != 0
                                            ? order
                                            : left.id.compareTo(right.id);
                                      });
                                onDuplicateLayers?.call(selected);
                                break;
                              case _LayerPanelAction.mergeSelected:
                                _confirmMergeSelected(context, orderedLayers);
                                break;
                              case _LayerPanelAction.deleteSelected:
                                _deleteSelected(context, orderedLayers);
                                break;
                              case _LayerPanelAction.setSelectedVisibility:
                                final selected = orderedLayers
                                    .where(
                                      (layer) =>
                                          selection.selected.contains(layer.id),
                                    )
                                    .toList(growable: false);
                                final makeVisible = selected.any(
                                  (layer) => !layer.visible,
                                );
                                onSetLayersVisibility?.call(
                                  selected,
                                  makeVisible,
                                );
                                break;
                              case _LayerPanelAction.setSelectedLocked:
                                final selectedIds = selection.selected;
                                final byId = {
                                  for (final layer in orderedLayers)
                                    layer.id: layer,
                                };
                                final selected = orderedLayers
                                    .where((layer) {
                                      if (!selectedIds.contains(layer.id)) {
                                        return false;
                                      }
                                      var parentId = layer.parent;
                                      final visited = <int>{};
                                      while (parentId != null &&
                                          visited.add(parentId)) {
                                        if (selectedIds.contains(parentId)) {
                                          return false;
                                        }
                                        parentId = byId[parentId]?.parent;
                                      }
                                      return true;
                                    })
                                    .toList(growable: false);
                                final makeLocked = selected.any(
                                  (layer) => !layer.locked,
                                );
                                onSetLayersLocked?.call(selected, makeLocked);
                                break;
                              case _LayerPanelAction.setSelectedLabelRed:
                                onSetLayersLabel?.call(
                                  orderedLayers
                                      .where(
                                        (layer) => selection.selected.contains(
                                          layer.id,
                                        ),
                                      )
                                      .toList(growable: false),
                                  0xe53935ff,
                                );
                                break;
                              case _LayerPanelAction.setSelectedLabelBlue:
                                onSetLayersLabel?.call(
                                  orderedLayers
                                      .where(
                                        (layer) => selection.selected.contains(
                                          layer.id,
                                        ),
                                      )
                                      .toList(growable: false),
                                  0x1e88e5ff,
                                );
                                break;
                              case _LayerPanelAction.clearSelectedLabel:
                                onSetLayersLabel?.call(
                                  orderedLayers
                                      .where(
                                        (layer) => selection.selected.contains(
                                          layer.id,
                                        ),
                                      )
                                      .toList(growable: false),
                                  null,
                                );
                                break;
                            }
                          },
                          itemBuilder:
                              (context) => [
                                PopupMenuItem(
                                  value: _LayerPanelAction.toggleSelectMode,
                                  child: Text(
                                    selection.selectMode
                                        ? 'Exit selection mode'
                                        : 'Select mode',
                                  ),
                                ),
                                const PopupMenuItem(
                                  value: _LayerPanelAction.selectAll,
                                  child: Text('Select all layers'),
                                ),
                                const PopupMenuItem(
                                  value: _LayerPanelAction.deselectAll,
                                  child: Text('Deselect secondary layers'),
                                ),
                                PopupMenuItem(
                                  value: _LayerPanelAction.groupSelected,
                                  enabled:
                                      onGroupLayers != null &&
                                      selection.selected.length > 1,
                                  child: Text(
                                    'Group selected (${selection.selected.length})',
                                  ),
                                ),
                                PopupMenuItem(
                                  value: _LayerPanelAction.duplicateSelected,
                                  enabled:
                                      onDuplicateLayers != null &&
                                      selection.selected.length > 1,
                                  child: Text(
                                    'Duplicate selected (${selection.selected.length})',
                                  ),
                                ),
                                PopupMenuItem(
                                  value: _LayerPanelAction.mergeSelected,
                                  enabled:
                                      onMergeSelected != null &&
                                      selection.selected.length > 1,
                                  child: Text(
                                    'Merge selected (${selection.selected.length})',
                                  ),
                                ),
                                PopupMenuItem(
                                  value: _LayerPanelAction.deleteSelected,
                                  enabled:
                                      onDeleteLayers != null &&
                                      selection.selected.isNotEmpty,
                                  child: Text(
                                    'Delete selected (${selection.selected.length})',
                                  ),
                                ),
                                PopupMenuItem(
                                  value:
                                      _LayerPanelAction.setSelectedVisibility,
                                  enabled:
                                      onSetLayersVisibility != null &&
                                      selection.selected.isNotEmpty,
                                  child: Text(
                                    orderedLayers
                                                .where(
                                                  (layer) => selection.selected
                                                      .contains(layer.id),
                                                )
                                                .isNotEmpty &&
                                            orderedLayers
                                                .where(
                                                  (layer) => selection.selected
                                                      .contains(layer.id),
                                                )
                                                .every((layer) => layer.visible)
                                        ? 'Hide selected layers'
                                        : 'Show selected layers',
                                  ),
                                ),
                                PopupMenuItem(
                                  value: _LayerPanelAction.setSelectedLocked,
                                  enabled:
                                      onSetLayersLocked != null &&
                                      selection.selected.isNotEmpty,
                                  child: Text(
                                    orderedLayers
                                                .where(
                                                  (layer) => selection.selected
                                                      .contains(layer.id),
                                                )
                                                .isNotEmpty &&
                                            orderedLayers
                                                .where(
                                                  (layer) => selection.selected
                                                      .contains(layer.id),
                                                )
                                                .every((layer) => layer.locked)
                                        ? 'Unlock selected layers'
                                        : 'Lock selected layers',
                                  ),
                                ),
                                PopupMenuItem(
                                  value: _LayerPanelAction.setSelectedLabelRed,
                                  enabled:
                                      onSetLayersLabel != null &&
                                      selection.selected.isNotEmpty,
                                  child: const Text('Label selected red'),
                                ),
                                PopupMenuItem(
                                  value: _LayerPanelAction.setSelectedLabelBlue,
                                  enabled:
                                      onSetLayersLabel != null &&
                                      selection.selected.isNotEmpty,
                                  child: const Text('Label selected blue'),
                                ),
                                PopupMenuItem(
                                  value: _LayerPanelAction.clearSelectedLabel,
                                  enabled:
                                      onSetLayersLabel != null &&
                                      selection.selected.isNotEmpty,
                                  child: const Text('Clear selected labels'),
                                ),
                              ],
                        ),
                      ],
                    ),
                  );
                },
              ),
            Expanded(
              child: ListView.builder(
                itemCount: visibleLayers.length,
                itemBuilder:
                    (context, index) => _layerTile(
                      context,
                      orderedLayers,
                      visibleLayers[index],
                      index,
                    ),
              ),
            ),
            if (showStudio) _studioCommandBar(context, inspector),
          ],
        );
      },
    );
  }

  Widget _studioCommandBar(BuildContext context, LayerView? active) => Material(
    elevation: 2,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButton(
            tooltip: 'New group',
            icon: const Icon(Icons.create_new_folder_outlined),
            onPressed:
                onAddLayer == null ? null : () => onAddLayer!(LayerKind.group),
          ),
          IconButton(
            tooltip: 'Add mask',
            icon: const Icon(Icons.layers_outlined),
            onPressed:
                onAddLayer == null ? null : () => onAddLayer!(LayerKind.mask),
          ),
          IconButton(
            tooltip: 'Duplicate selected layer',
            icon: const Icon(Icons.copy_outlined),
            onPressed:
                active == null ? null : () => onDuplicateLayer?.call(active),
          ),
          IconButton(
            tooltip: 'Delete selected layer',
            icon: const Icon(Icons.delete_outline),
            onPressed:
                active == null ? null : () => _confirmDelete(context, active),
          ),
        ],
      ),
    ),
  );

  Widget _addLayerChip(
    BuildContext context, {
    required String label,
    required IconData icon,
    required LayerKind kind,
  }) => InkSelectableChip(
    label: label,
    leading: Icon(icon),
    selected: false,
    onPressed: () => onAddLayer?.call(kind),
    minimumHeight: inkMetrics(context).touchControlHeight,
  );

  Future<void> _groupSelected(
    BuildContext context,
    List<LayerView> orderedLayers,
  ) async {
    final ids = selection.selected;
    if (ids.length < 2 || onGroupLayers == null) return;
    final selected =
        orderedLayers.where((layer) => ids.contains(layer.id)).toList()
          ..sort((left, right) {
            final order = left.order.compareTo(right.order);
            return order != 0 ? order : left.id.compareTo(right.id);
          });
    final engineReason = await onPreflightGroupLayers?.call(selected);
    if (!context.mounted) return;
    if (engineReason != null) {
      _showLayerNotice(
        context,
        _presentLayerActionReason(engineReason, layers),
      );
      return;
    }
    if (selected.length != ids.length ||
        selected.any(_isComicOwned) ||
        selected.any((layer) => layer.kind == LayerKind.panelGroup)) {
      _showLayerNotice(context, 'Comic-owned layers cannot be grouped here.');
      return;
    }
    final parent = selected.first.parent;
    if (selected.any((layer) => layer.parent != parent)) {
      _showLayerNotice(
        context,
        'Group layers from the same parent. Select one sibling stack.',
      );
      return;
    }
    final siblings = orderLayerTree(
        layers,
      ).where((layer) => layer.parent == parent).toList(growable: false)
      ..sort((left, right) => left.order.compareTo(right.order));
    final selectedIndices = <int>[];
    for (var index = 0; index < siblings.length; index++) {
      if (ids.contains(siblings[index].id)) selectedIndices.add(index);
    }
    if (selectedIndices.length < 2) return;
    final first = selectedIndices.first;
    final last = selectedIndices.last;
    final selectedIds = ids.toSet();
    final selectedRange = siblings.sublist(first, last + 1);
    if (selectedRange.any(
      (layer) =>
          layer.kind == LayerKind.mask &&
          (layer.maskOwner == null || !selectedIds.contains(layer.maskOwner)),
    )) {
      _showLayerNotice(
        context,
        'Grouping this range could move a mask away from its owner.',
      );
      return;
    }
    if (selectedRange.any((layer) => layer.clipping)) {
      _showLayerNotice(
        context,
        'Grouping this range could change clipping behavior.',
      );
      return;
    }
    final hasInterveningLayers = last - first + 1 != selectedIndices.length;
    if (hasInterveningLayers) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder:
            (context) => AlertDialog(
              title: const Text('Group selected layers?'),
              content: const Text(
                'Unselected layers between these layers will move below the new group in the stack.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Group'),
                ),
              ],
            ),
      );
      if (confirmed != true || !context.mounted) return;
    }
    onGroupLayers?.call(
      siblings.where((layer) => ids.contains(layer.id)).toList(growable: false),
    );
  }

  Future<void> _deleteSelected(
    BuildContext context,
    List<LayerView> layers,
  ) async {
    final byId = {for (final layer in layers) layer.id: layer};
    final selected = selection.selected;
    final roots = layers
        .where((layer) {
          if (!selected.contains(layer.id)) return false;
          var parentId = layer.parent;
          final visited = <int>{};
          while (parentId != null && visited.add(parentId)) {
            if (selected.contains(parentId)) return false;
            parentId = byId[parentId]?.parent;
          }
          return true;
        })
        .toList(growable: false);
    if (roots.isEmpty) {
      _showLayerNotice(context, 'Select one or more layers to delete.');
      return;
    }
    final engineReason = await onPreflightDeleteLayers?.call(roots);
    if (!context.mounted) return;
    if (engineReason != null) {
      _showLayerNotice(
        context,
        _presentLayerActionReason(engineReason, layers),
      );
      return;
    }
    final rootIds = roots.map((layer) => layer.id).toSet();
    final affected =
        layers.where((layer) {
          var current = layer;
          final visited = <int>{};
          while (visited.add(current.id)) {
            if (rootIds.contains(current.id)) return true;
            final parentId = current.parent;
            final parent = parentId == null ? null : byId[parentId];
            if (parent == null) return false;
            current = parent;
          }
          return false;
        }).length;
    if (affected >= layers.length) {
      _showLayerNotice(context, 'A document must keep at least one layer.');
      return;
    }
    if (affected == 1 &&
        roots.length == 1 &&
        roots.single.kind != LayerKind.group &&
        roots.single.kind != LayerKind.panelGroup &&
        onDeleteLayer != null) {
      onDeleteLayer!(roots.single);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: Text(
              'Delete $affected selected layer${affected == 1 ? '' : 's'}?',
            ),
            content: const Text(
              'This removes the selected layers and any children of selected groups. Undo can restore them.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete'),
              ),
            ],
          ),
    );
    if (confirmed == true && context.mounted) onDeleteLayers?.call(roots);
  }

  Future<void> _confirmMergeSelected(
    BuildContext context,
    List<LayerView> orderedLayers,
  ) async {
    final selected =
        orderedLayers
            .where((layer) => selection.selected.contains(layer.id))
            .toList()
          ..sort((left, right) {
            final order = left.order.compareTo(right.order);
            return order != 0 ? order : left.id.compareTo(right.id);
          });
    if (selected.length < 2 || onMergeSelected == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Merge selected layers?'),
            content: Text(
              'Combine ${selected.length} layers into “${selected.first.name}”. This creates one Undo step.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Merge'),
              ),
            ],
          ),
    );
    if (confirmed == true && context.mounted) onMergeSelected?.call(selected);
  }

  void _showLayerNotice(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String _presentLayerActionReason(String reason, List<LayerView> layers) {
    final layersByEngineId = {
      for (final layer in layers)
        layer.id.toRadixString(16).padLeft(32, '0'): layer,
    };
    final lockReason = RegExp(
      r'^layer ([0-9a-f]{32}) is locked by layer ([0-9a-f]{32}); unlock the owning layer or group first$',
    ).firstMatch(reason);
    if (lockReason == null) return reason;

    final lockedLayer = layersByEngineId[lockReason.group(1)];
    final ownerLayer = layersByEngineId[lockReason.group(2)];
    if (lockedLayer == null || ownerLayer == null) return reason;
    if (lockedLayer.id == ownerLayer.id) {
      return '“${lockedLayer.name}” is locked. Unlock it before changing it.';
    }
    return '“${lockedLayer.name}” is locked by “${ownerLayer.name}”. '
        'Unlock the owning layer or group first.';
  }

  Widget _layerTile(
    BuildContext context,
    List<LayerView> orderedLayers,
    LayerView layer,
    int layerIndex,
  ) {
    final lockOwner = _effectiveLockOwner(layer, orderedLayers);
    final siblings = orderedLayers
        .where((candidate) => candidate.parent == layer.parent)
        .toList(growable: false);
    final siblingIndex = siblings.indexWhere(
      (candidate) => candidate.id == layer.id,
    );
    final isGroup =
        layer.kind == LayerKind.group || layer.kind == LayerKind.panelGroup;
    void toggleGroup() {
      selection.toggleGroupExpanded(layer.id);
      onSelectionChanged?.call(selection.selected.toSet());
    }

    final starts = <int, Offset>{};
    final current = <int, Offset>{};
    final active = <int>{};
    double? initialPinchDistance;
    Timer? holdTimer;
    var twoFingerHeld = false;

    double? pinchDistance(Map<int, Offset> positions) {
      if (positions.length != 2) return null;
      final values = positions.values.toList(growable: false);
      return (values[0] - values[1]).distance;
    }

    void finishPointer(int pointer) {
      active.remove(pointer);
      if (active.isNotEmpty) return;
      holdTimer?.cancel();
      if (starts.isEmpty) return;
      var averageDelta = Offset.zero;
      for (final entry in starts.entries) {
        averageDelta += current[entry.key]! - entry.value;
      }
      averageDelta /= starts.length.toDouble();
      if (starts.length == 2) {
        final finalPinchDistance = pinchDistance(current);
        final pinchDelta =
            initialPinchDistance != null && finalPinchDistance != null
                ? (finalPinchDistance - initialPinchDistance!).abs()
                : 0;
        final pinchThreshold = math.max(48, (initialPinchDistance ?? 0) * 0.25);
        if (initialPinchDistance != null && pinchDelta >= pinchThreshold) {
          final targetIndex =
              layerIndex + 1 < orderedLayers.length
                  ? layerIndex + 1
                  : layerIndex > 0
                  ? layerIndex - 1
                  : -1;
          if (targetIndex >= 0) {
            _showMergePreview(context, layer, orderedLayers[targetIndex]);
          }
        } else if (twoFingerHeld) {
          // The hold timer already selected the layer's opaque contents.
        } else if (averageDelta.dx > 72 && averageDelta.dy.abs() < 48) {
          // Two-finger right swipe toggles alpha lock.
          onLayerChanged?.call(layer.copyWith(alphaLock: !layer.alphaLock));
        } else if (averageDelta.dx.abs() < 24 && averageDelta.dy.abs() < 24) {
          _showOpacitySheet(context, layer);
        }
      } else if (starts.length == 1 &&
          averageDelta.dx > 72 &&
          averageDelta.dy.abs() < 48) {
        // Clip Studio-style right swipe: additive selection.
        selection.toggleSecondary(layer.id);
        onSelectionChanged?.call(selection.selected.toSet());
      } else if (starts.length == 1 &&
          averageDelta.dx < -72 &&
          averageDelta.dy.abs() < 48) {
        // Left swipe opens the same bounded actions as the desktop menu.
        _showSwipeActions(context, layer);
      }
      starts.clear();
      current.clear();
      initialPinchDistance = null;
    }

    final canDragReorder =
        (onReorderLayer != null ||
            onReorderLayers != null ||
            onMoveLayerTo != null) &&
        layer.canDrag &&
        !_isComicOwned(layer);
    final canBeDropTarget =
        (onReorderLayer != null ||
            onReorderLayers != null ||
            onMoveLayerTo != null) &&
        !_isComicOwned(layer);
    String rejectedDropReason(LayerView source, _LayerDropPlacement placement) {
      if (source.id == layer.id) {
        return 'This layer is already in that position.';
      }
      if (!source.canDrag || _isComicOwned(source)) {
        return source.dragReason ??
            'Comic-owned layers can only be rearranged in Comics.';
      }
      if (placement == _LayerDropPlacement.inside &&
          layer.kind == LayerKind.group) {
        var ancestorId = layer.id;
        final byId = {
          for (final candidate in orderedLayers) candidate.id: candidate,
        };
        final visited = <int>{};
        while (visited.add(ancestorId)) {
          if (ancestorId == source.id) {
            return 'Cannot move ${source.name} into its own descendant.';
          }
          final parentId = byId[ancestorId]?.parent;
          if (parentId == null) break;
          ancestorId = parentId;
        }
      }
      if (_isComicOwned(layer)) {
        return 'Cannot drop into this comic-owned group: '
            '${layer.receiveReason ?? 'Comic-owned groups can only be rearranged in Comics.'}';
      }
      if (placement == _LayerDropPlacement.inside && !layer.canReceiveLayers) {
        return 'Cannot drop into this group: '
            '${layer.receiveReason ?? 'This group cannot receive layers in its current state.'}';
      }
      return 'These layers cannot be moved to that position.';
    }

    final row = Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) {
        starts[event.pointer] = event.localPosition;
        current[event.pointer] = event.localPosition;
        active.add(event.pointer);
        if (active.length == 2) {
          initialPinchDistance = pinchDistance(starts);
          twoFingerHeld = false;
          holdTimer?.cancel();
          holdTimer = Timer(const Duration(milliseconds: 480), () {
            final moved = starts.entries.any(
              (entry) => (current[entry.key]! - entry.value).distance > 16,
            );
            if (active.length == 2 && !moved) {
              twoFingerHeld = true;
              onSelectContents?.call(layer);
            }
          });
        }
      },
      onPointerMove: (event) {
        current[event.pointer] = event.localPosition;
      },
      onPointerUp: (event) {
        current[event.pointer] = event.localPosition;
        finishPointer(event.pointer);
      },
      onPointerCancel: (event) {
        holdTimer?.cancel();
        active.clear();
        starts.clear();
        current.clear();
        initialPinchDistance = null;
      },
      child: InkLayerRow(
        selected: selection.primaryId == layer.id,
        secondarySelected:
            selection.isSelected(layer.id) && selection.primaryId != layer.id,
        minimumHeight: 72,
        leading: Padding(
          padding: EdgeInsets.only(
            left: _layerDepth(layer, orderedLayers) * 16.0,
          ),
          child: SizedBox(
            width: 48,
            height: 48,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _LayerThumbnail(layer: layer),
                if (isGroup)
                  Align(
                    alignment: Alignment.topLeft,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      alignment: Alignment.topLeft,
                      tooltip:
                          selection.collapsedGroups.contains(layer.id)
                              ? 'Expand group'
                              : 'Collapse group',
                      icon: Icon(
                        selection.collapsedGroups.contains(layer.id)
                            ? Icons.chevron_right
                            : Icons.expand_more,
                      ),
                      onPressed: toggleGroup,
                    ),
                  ),
              ],
            ),
          ),
        ),
        title: Text(layer.name),
        subtitle: Row(
          children: [
            Flexible(child: Text(_friendlyStatus(layer, orderedLayers))),
            if (selection.primaryId == layer.id) const _ActiveLayerBadge(),
            if (soloLayerId == layer.id)
              const _LayerBadge(icon: Icons.filter_center_focus, label: 'Solo'),
            if (layer.alphaLock)
              const _LayerBadge(
                icon: Icons.lock_outline,
                label: 'Alpha locked',
              ),
            if (lockOwner != null)
              _LayerBadge(
                icon: Icons.lock,
                label:
                    lockOwner.id == layer.id
                        ? 'Locked'
                        : 'Locked by ${lockOwner.name}',
              ),
            if (layer.clipping)
              const _LayerBadge(icon: Icons.layers, label: 'Clipped'),
            if (layer.reference)
              const _LayerBadge(icon: Icons.star_outline, label: 'Reference'),
            if (!layer.canDrag && layer.dragReason != null)
              _LayerBadge(
                icon: Icons.block,
                label: 'Fixed',
                tooltip: layer.dragReason!,
              ),
            if (layer.kind == LayerKind.group &&
                !layer.canReceiveLayers &&
                layer.receiveReason != null)
              _LayerBadge(
                icon: Icons.block,
                label: 'Cannot contain layers',
                tooltip: layer.receiveReason!,
              ),
            if (layer.label != null && layer.label != 0)
              _LayerColorBadge(rgba: layer.label!),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (canDragReorder)
              Draggable<LayerView>(
                data: layer,
                feedback: Material(
                  elevation: 4,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text('Move ${layer.name}'),
                  ),
                ),
                childWhenDragging: const Opacity(
                  opacity: 0.35,
                  child: Icon(Icons.drag_handle),
                ),
                child: Semantics(
                  container: true,
                  button: true,
                  label: 'Reorder ${layer.name}',
                  hint: 'Drag to reorder within this group',
                  child: const Tooltip(
                    message: 'Drag to reorder within this group',
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: Icon(Icons.drag_handle),
                    ),
                  ),
                ),
              ),
            Tooltip(
              message:
                  '${layer.visible ? 'Hide' : 'Show'} layer; long-press to solo',
              child: InkWell(
                borderRadius: BorderRadius.circular(24),
                onTap:
                    () => onLayerChanged?.call(
                      layer.copyWith(visible: !layer.visible),
                    ),
                onLongPress: () => onSoloLayer?.call(layer),
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: Icon(
                    layer.visible ? Icons.visibility : Icons.visibility_off,
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Layer options',
              icon: const Icon(Icons.more_vert),
              onPressed:
                  () =>
                      _showLayerOptions(context, layer, siblings, siblingIndex),
            ),
          ],
        ),
        onTap: () {
          if (selection.selectMode) {
            selection.toggleSecondary(layer.id);
          } else {
            selection.select(layer.id);
          }
          onSelectionChanged?.call(selection.selected.toSet());
        },
      ),
    );
    return _LayerDropTarget(
      key: ValueKey<int>(layer.id),
      layer: layer,
      layers: orderedLayers,
      enabled: canBeDropTarget,
      rejectedReason: rejectedDropReason,
      canAccept: (source, placement) {
        if (source.id == layer.id || !source.canDrag || _isComicOwned(source)) {
          return false;
        }
        if (placement != _LayerDropPlacement.inside &&
            source.parent == layer.parent &&
            (onReorderLayer != null || onReorderLayers != null)) {
          return true;
        }
        if (placement != _LayerDropPlacement.inside ||
            layer.kind != LayerKind.group ||
            !layer.canReceiveLayers ||
            _isComicOwned(layer) ||
            onMoveLayerTo == null) {
          return false;
        }
        var ancestorId = layer.id;
        final byId = {
          for (final candidate in orderedLayers) candidate.id: candidate,
        };
        final visited = <int>{};
        while (visited.add(ancestorId)) {
          if (ancestorId == source.id) return false;
          final parentId = byId[ancestorId]?.parent;
          if (parentId == null) break;
          ancestorId = parentId;
        }
        return true;
      },
      onDrop: (source, placement) {
        if (!source.canDrag || _isComicOwned(source)) return;
        if (placement == _LayerDropPlacement.inside) {
          if (layer.kind == LayerKind.group &&
              layer.canReceiveLayers &&
              !_isComicOwned(layer) &&
              source.id != layer.id) {
            onMoveLayerTo?.call(source, layer.id);
          }
          return;
        }
        if (source.parent != layer.parent || source.id == layer.id) return;
        if (onReorderLayer == null && onReorderLayers == null) {
          return;
        }
        final selected = selection.selected;
        final candidates = orderedLayers
            .where(
              (candidate) =>
                  candidate.parent == source.parent &&
                  (selected.contains(source.id)
                      ? selected.contains(candidate.id)
                      : candidate.id == source.id),
            )
            .toList(growable: false);
        final moving = _normalizeReorderRoots(candidates, orderedLayers);
        final movingIds = moving.map((item) => item.id).toSet();
        if (movingIds.isEmpty) movingIds.add(source.id);
        final targetIndex = siblings
            .where((candidate) => !movingIds.contains(candidate.id))
            .toList(growable: false)
          ..sort((left, right) => left.order.compareTo(right.order));
        final index = targetIndex.indexWhere(
          (candidate) => candidate.id == layer.id,
        );
        if (index >= 0) {
          final insertion =
              placement == _LayerDropPlacement.before ? index + 1 : index;
          final targets = orderedLayers
              .where((candidate) => movingIds.contains(candidate.id))
              .toList(growable: false);
          if (targets.length > 1 && onReorderLayers != null) {
            onReorderLayers!(targets, insertion);
          } else {
            onReorderLayer?.call(source, insertion);
          }
        }
      },
      child: row,
    );
  }

  int _layerDepth(LayerView layer, List<LayerView> ordered) {
    final byId = {for (final item in ordered) item.id: item};
    var depth = 0;
    var parent = layer.parent;
    final visited = <int>{layer.id};
    while (parent != null && visited.add(parent)) {
      depth++;
      parent = byId[parent]?.parent;
    }
    return depth;
  }

  String _friendlyKind(LayerKind kind) => switch (kind) {
    LayerKind.raster => 'Paint layer',
    LayerKind.vectorInk => 'Vector layer',
    LayerKind.group => 'Group',
    LayerKind.mask => 'Mask',
    LayerKind.tone => 'Tone layer',
    LayerKind.panelGroup => 'Comic panel group',
    LayerKind.adjustment => 'Adjustment layer',
  };

  String _friendlyStatus(LayerView layer, List<LayerView> allLayers) {
    if (layer.kind != LayerKind.mask) return _friendlyKind(layer.kind);
    final ownerId = layer.maskOwner;
    if (ownerId == null) return 'Mask · Unattached';
    for (final candidate in allLayers) {
      if (candidate.id == ownerId) return 'Mask · ${candidate.name}';
    }
    return 'Mask · Owner unavailable';
  }

  LayerView? _effectiveLockOwner(LayerView layer, List<LayerView> allLayers) {
    final byId = {for (final candidate in allLayers) candidate.id: candidate};
    var current = layer;
    final visited = <int>{};
    while (visited.add(current.id)) {
      if (current.locked) return current;
      final parentId = current.parent;
      if (parentId == null) return null;
      final parent = byId[parentId];
      if (parent == null) return null;
      current = parent;
    }
    return null;
  }

  Future<void> _showOpacitySheet(BuildContext context, LayerView layer) async {
    var preview = layer.opacity;
    var editStarted = false;
    var editFinished = false;
    await showModalBottomSheet<void>(
      context: context,
      builder:
          (context) => StatefulBuilder(
            builder:
                (context, setState) => SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Opacity · ${layer.name}'),
                        Slider(
                          value: preview.clamp(0, 1),
                          divisions: 100,
                          onChangeStart: (_) {
                            editStarted = true;
                            onOpacityEditStarted?.call(layer);
                          },
                          onChanged: (value) {
                            setState(() => preview = value);
                            onOpacityPreviewChanged?.call(layer, value);
                          },
                          onChangeEnd: (_) {
                            editFinished = true;
                            if (onOpacityEditCommitted != null) {
                              onOpacityEditCommitted!(layer);
                            } else {
                              onLayerChanged?.call(
                                layer.copyWith(opacity: preview),
                              );
                            }
                          },
                        ),
                        Text('${(preview * 100).round()}%'),
                      ],
                    ),
                  ),
                ),
          ),
    );
    if (editStarted && !editFinished) onOpacityEditCancelled?.call(layer);
  }

  Future<void> _showLayerOptions(
    BuildContext context,
    LayerView layer,
    List<LayerView> siblings,
    int siblingIndex,
  ) async {
    final lockOwner = _effectiveLockOwner(layer, layers);
    final isLocked = lockOwner != null;
    final canEditProperties = layer.canEditProperties && !isLocked;
    final editPropertiesReason =
        layer.editPropertiesReason ??
        (isLocked
            ? 'Unlock the owning layer or group to edit properties.'
            : null);
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder:
          (context) => SafeArea(
            child: FractionallySizedBox(
              heightFactor: 0.85,
              child: ListView(
                children: [
                  ListTile(
                    title: Text(layer.name),
                    subtitle: Text(_friendlyKind(layer.kind)),
                  ),
                  if (isLocked)
                    ListTile(
                      leading: const Icon(Icons.lock),
                      title: Text(
                        lockOwner.id == layer.id
                            ? 'Layer is locked'
                            : 'Locked by ${lockOwner.name}',
                      ),
                      subtitle: const Text(
                        'Unlock the owning layer or group to edit properties.',
                      ),
                    ),
                  if (layer.dragReason != null ||
                      (layer.kind == LayerKind.group &&
                          layer.receiveReason != null))
                    ListTile(
                      leading: const Icon(Icons.block),
                      title: const Text('Layer movement unavailable'),
                      subtitle: Text(layer.dragReason ?? layer.receiveReason!),
                    ),
                  if (!studioMode)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: _LayerProperties(
                        layer: layer,
                        onChanged: canEditProperties ? onLayerChanged : null,
                        onOpacityEditStarted:
                            canEditProperties ? onOpacityEditStarted : null,
                        onOpacityPreviewChanged:
                            canEditProperties ? onOpacityPreviewChanged : null,
                        onOpacityEditCommitted:
                            canEditProperties ? onOpacityEditCommitted : null,
                        onOpacityEditCancelled:
                            canEditProperties ? onOpacityEditCancelled : null,
                        onPresentationChanged:
                            canEditProperties ? onPresentationChanged : null,
                        onAdjustmentChanged:
                            canEditProperties ? onAdjustmentChanged : null,
                      ),
                    ),
                  _option(
                    context,
                    'rename',
                    'Rename',
                    Icons.edit,
                    enabled: canEditProperties,
                    reason: canEditProperties ? null : editPropertiesReason,
                  ),
                  if (layer.kind == LayerKind.mask) ...[
                    _option(
                      context,
                      'mask-enabled',
                      layer.maskEnabled ? 'Disable mask' : 'Enable mask',
                      layer.maskEnabled
                          ? Icons.visibility_off
                          : Icons.visibility,
                      enabled:
                          canEditProperties && onMaskEnabledChanged != null,
                      reason: canEditProperties ? null : editPropertiesReason,
                    ),
                    _option(
                      context,
                      'mask-invert',
                      layer.maskInverted ? 'Restore mask' : 'Invert mask',
                      Icons.invert_colors,
                      enabled:
                          canEditProperties && onMaskInvertedChanged != null,
                      reason: canEditProperties ? null : editPropertiesReason,
                    ),
                    if (layer.maskOwner != null)
                      _option(
                        context,
                        'mask-apply',
                        'Apply mask…',
                        Icons.layers_clear,
                        enabled: layer.canApplyMask && onApplyMask != null,
                        reason:
                            layer.canApplyMask ? null : layer.applyMaskReason,
                      ),
                  ],
                  if (layer.kind == LayerKind.group && onUngroupLayer != null)
                    _option(
                      context,
                      'ungroup',
                      'Ungroup layers',
                      Icons.layers_clear,
                      enabled: layer.canUngroup && !isLocked,
                      reason: layer.canUngroup ? null : layer.ungroupReason,
                    ),
                  if (onDuplicateLayer != null)
                    _option(
                      context,
                      'duplicate',
                      'Duplicate layer',
                      Icons.copy,
                      enabled: layer.canDuplicate && !isLocked,
                      reason:
                          layer.canDuplicate
                              ? editPropertiesReason
                              : layer.duplicateReason,
                    ),
                  if (onSelectContents != null &&
                      (layer.kind == LayerKind.raster ||
                          layer.kind == LayerKind.vectorInk))
                    _option(
                      context,
                      'select-contents',
                      'Select contents',
                      Icons.select_all,
                    ),
                  if (onClearLayer != null &&
                      (layer.kind == LayerKind.raster ||
                          layer.kind == LayerKind.vectorInk))
                    _option(
                      context,
                      'clear-layer',
                      'Clear layer',
                      Icons.layers_clear,
                      enabled: !isLocked,
                      reason: isLocked ? editPropertiesReason : null,
                    ),
                  if (onMergeLayers != null)
                    _option(
                      context,
                      'merge-down',
                      'Merge down…',
                      Icons.merge_type,
                      enabled:
                          layer.hasMergeDownCapability
                              ? layer.mergeDownReason == null
                              : !isLocked &&
                                  layer.canDrag &&
                                  siblingIndex >= 0 &&
                                  siblingIndex < siblings.length - 1,
                      reason:
                          layer.hasMergeDownCapability
                              ? layer.mergeDownReason
                              : (layer.canDrag ? null : layer.dragReason),
                    ),
                  if (lockOwner == null || lockOwner.id == layer.id)
                    _option(
                      context,
                      'lock',
                      layer.locked ? 'Unlock layer' : 'Lock layer',
                      layer.locked ? Icons.lock_open : Icons.lock,
                    )
                  else
                    _option(
                      context,
                      'lock-inherited',
                      'Locked by ${lockOwner.name}',
                      Icons.lock,
                      enabled: false,
                    ),
                  _option(
                    context,
                    'alpha',
                    layer.alphaLock ? 'Unlock alpha' : 'Lock alpha',
                    Icons.lock_outline,
                    enabled: !isLocked,
                    reason: isLocked ? editPropertiesReason : null,
                  ),
                  _option(
                    context,
                    'clipping',
                    layer.clipping ? 'Disable clipping' : 'Clip to layer below',
                    Icons.layers_outlined,
                    enabled: !isLocked,
                    reason: isLocked ? editPropertiesReason : null,
                  ),
                  _option(
                    context,
                    'reference',
                    layer.reference ? 'Remove reference' : 'Set as reference',
                    Icons.star_outline,
                    enabled: !isLocked,
                    reason: isLocked ? editPropertiesReason : null,
                  ),
                  _option(
                    context,
                    'move-up',
                    'Move up',
                    Icons.keyboard_arrow_up,
                    enabled:
                        onMoveLayer != null &&
                        layer.canDrag &&
                        !isLocked &&
                        siblingIndex > 0,
                    reason: layer.canDrag ? null : layer.dragReason,
                  ),
                  _option(
                    context,
                    'move-down',
                    'Move down',
                    Icons.keyboard_arrow_down,
                    enabled:
                        onMoveLayer != null &&
                        layer.canDrag &&
                        !isLocked &&
                        siblingIndex >= 0 &&
                        siblingIndex < siblings.length - 1,
                    reason: layer.canDrag ? null : layer.dragReason,
                  ),
                  if (onMoveLayerTo != null && _canMoveOut(layer))
                    _option(
                      context,
                      'move-out',
                      'Move out of group',
                      Icons.drive_file_move_outline,
                      enabled: layer.canDrag && !isLocked,
                      reason: layer.canDrag ? null : layer.dragReason,
                    ),
                  ..._movableGroups(layer).map(
                    (group) => _option(
                      context,
                      'move-into-${group.id}',
                      'Move into ${group.name}',
                      Icons.drive_file_move_outline,
                      enabled:
                          layer.canDrag && group.canReceiveLayers && !isLocked,
                      reason:
                          !layer.canDrag
                              ? layer.dragReason
                              : group.receiveReason,
                    ),
                  ),
                  _option(
                    context,
                    'blend-Normal',
                    'Normal blend',
                    Icons.layers,
                    enabled: !isLocked,
                    reason: isLocked ? editPropertiesReason : null,
                  ),
                  _option(
                    context,
                    'blend-Multiply',
                    'Multiply blend',
                    Icons.layers,
                    enabled: !isLocked,
                    reason: isLocked ? editPropertiesReason : null,
                  ),
                  _option(
                    context,
                    'blend-Screen',
                    'Screen blend',
                    Icons.layers,
                    enabled: !isLocked,
                    reason: isLocked ? editPropertiesReason : null,
                  ),
                  _option(
                    context,
                    'blend-Overlay',
                    'Overlay blend',
                    Icons.layers,
                    enabled: canEditProperties,
                    reason: canEditProperties ? null : editPropertiesReason,
                  ),
                  _option(
                    context,
                    'label-red',
                    'Red label',
                    Icons.label,
                    enabled: canEditProperties,
                    reason: canEditProperties ? null : editPropertiesReason,
                  ),
                  _option(
                    context,
                    'label-blue',
                    'Blue label',
                    Icons.label,
                    enabled: canEditProperties,
                    reason: canEditProperties ? null : editPropertiesReason,
                  ),
                  _option(
                    context,
                    'label-clear',
                    'Clear label',
                    Icons.label_outline,
                    enabled: canEditProperties,
                    reason: canEditProperties ? null : editPropertiesReason,
                  ),
                  const Divider(),
                  _option(
                    context,
                    'delete',
                    'Delete layer…',
                    Icons.delete_outline,
                    enabled: layer.canDelete && !isLocked,
                    reason:
                        layer.canDelete
                            ? editPropertiesReason
                            : layer.deleteReason,
                  ),
                ],
              ),
            ),
          ),
    );
    if (selected != null && context.mounted) {
      if (selected == 'mask-apply') {
        await _showApplyMaskConfirmation(context, layer);
      } else {
        _applyMenuAction(context, layer, selected);
      }
    }
  }

  Future<void> _showApplyMaskConfirmation(
    BuildContext context,
    LayerView mask,
  ) async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      builder:
          (context) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Wrap(
                runSpacing: 8,
                children: [
                  const ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.layers_clear),
                    title: Text('Apply mask'),
                    subtitle: Text(
                      'Bake this mask into its raster layer and remove the '
                      'mask. The change is one undoable action.',
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: () => Navigator.of(context).pop(true),
                        child: const Text('Apply mask'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
    );
    if (confirmed == true) onApplyMask?.call(mask);
  }

  LayerView? _ordinaryParent(int? parentId) {
    if (parentId == null) return null;
    for (final candidate in layers) {
      if (candidate.id == parentId && candidate.kind == LayerKind.group) {
        return candidate;
      }
    }
    return null;
  }

  int? _moveOutTarget(LayerView layer) {
    if (_isComicOwned(layer)) return null;
    final parent = _ordinaryParent(layer.parent);
    return parent?.parent;
  }

  bool _canMoveOut(LayerView layer) {
    if (_isComicOwned(layer)) return false;
    final parent = _ordinaryParent(layer.parent);
    if (parent == null || parent.parent == null) return parent != null;
    return _ordinaryParent(parent.parent) != null;
  }

  bool _isComicOwned(LayerView layer) {
    if (layer.kind == LayerKind.panelGroup) return true;
    final byId = {for (final candidate in layers) candidate.id: candidate};
    var parentId = layer.parent;
    final visited = <int>{layer.id};
    while (parentId != null && visited.add(parentId)) {
      final parent = byId[parentId];
      if (parent?.kind == LayerKind.panelGroup) return true;
      parentId = parent?.parent;
    }
    return false;
  }

  List<LayerView> _movableGroups(LayerView layer) {
    if (onMoveLayerTo == null || _isComicOwned(layer)) {
      return const <LayerView>[];
    }
    final descendants = <int>{};
    var changed = true;
    while (changed) {
      changed = false;
      for (final candidate in layers) {
        if (candidate.parent == layer.id ||
            (candidate.parent != null &&
                descendants.contains(candidate.parent))) {
          if (descendants.add(candidate.id)) changed = true;
        }
      }
    }
    return orderLayerTree(layers)
        .where(
          (candidate) =>
              candidate.kind == LayerKind.group &&
              !_isComicOwned(candidate) &&
              candidate.id != layer.id &&
              candidate.id != layer.parent &&
              !descendants.contains(candidate.id),
        )
        .toList(growable: false);
  }

  Widget _option(
    BuildContext context,
    String value,
    String label,
    IconData icon, {
    bool enabled = true,
    String? reason,
  }) => ListTile(
    enabled: enabled,
    leading: Icon(icon),
    title: Text(label),
    subtitle: reason == null ? null : Text(reason),
    onTap: enabled ? () => Navigator.of(context).pop(value) : null,
  );

  Future<void> _showMergePreview(
    BuildContext context,
    LayerView source,
    LayerView target,
  ) async {
    final sourceSiblings = orderLayerTree(layers)
        .where((candidate) => candidate.parent == source.parent)
        .toList(growable: false);
    final sourceIndex = sourceSiblings.indexWhere(
      (candidate) => candidate.id == source.id,
    );
    final targetIndex = sourceSiblings.indexWhere(
      (candidate) => candidate.id == target.id,
    );
    final isMergeDownPair = sourceIndex >= 0 && targetIndex == sourceIndex + 1;
    var unavailableReason =
        isMergeDownPair && source.hasMergeDownCapability
            ? source.mergeDownReason
            : _mergeUnavailableReason(source, target);
    if (unavailableReason == null && onPreflightMergeLayers != null) {
      try {
        unavailableReason = await onPreflightMergeLayers!(source, target);
      } on Object catch (error) {
        unavailableReason = error.toString();
      }
    }
    if (!context.mounted) return;
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      builder:
          (context) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: Wrap(
                runSpacing: 8,
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.merge_type),
                    title: const Text('Preview layer merge'),
                    subtitle: Text(
                      unavailableReason ??
                          'The source layer will be composited into the '
                              'target. Exact opaque coverage is checked '
                              'before commit. This remains undoable.',
                    ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(source.name),
                    trailing: const Icon(Icons.arrow_downward),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(target.name),
                    subtitle: Text(target.kind.name),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed:
                            unavailableReason == null
                                ? () => Navigator.of(context).pop(true)
                                : null,
                        child: const Text('Merge'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
    );
    if (confirmed == true) onMergeLayers?.call(source, target);
  }

  String? _mergeUnavailableReason(LayerView source, LayerView target) {
    if (source.id == target.id) return 'Choose two different layers.';
    if (source.kind != LayerKind.raster || target.kind != LayerKind.raster) {
      return 'Merge is available only between raster layers.';
    }
    if (source.parent != target.parent) {
      return 'Layers must be in the same group to merge.';
    }
    if (_descendantsOf(source.id).isNotEmpty ||
        _descendantsOf(target.id).isNotEmpty) {
      return 'Layers with child layers cannot be merged.';
    }
    if (source.clipping || target.clipping) {
      return 'Turn off clipping on both layers before merging.';
    }
    if (!source.visible || !target.visible) {
      return 'Show both layers before merging.';
    }
    if (source.blendMode != LayerBlendMode.normal ||
        target.blendMode != LayerBlendMode.normal) {
      return 'Safe merge requires Normal blending on both layers.';
    }
    if (target.opacity < 0.999) {
      return 'Exact merge requires the lower target at 100% opacity.';
    }
    final siblings = orderLayerTree(layers)
      .where((candidate) => candidate.parent == source.parent)
      .toList(growable: true)..sort((left, right) {
      final byOrder = left.order.compareTo(right.order);
      return byOrder != 0 ? byOrder : left.id.compareTo(right.id);
    });
    final sourceIndex = siblings.indexWhere(
      (candidate) => candidate.id == source.id,
    );
    if (sourceIndex <= 0 || siblings[sourceIndex - 1].id != target.id) {
      return 'Choose adjacent layers with the target directly below the source.';
    }
    if (siblings.any((candidate) => candidate.kind == LayerKind.mask)) {
      return 'Remove or apply attached masks before merging layers.';
    }
    return null;
  }

  void _applyMenuAction(BuildContext context, LayerView layer, String value) {
    if (value == 'clear-layer') {
      onClearLayer?.call(layer);
    } else if (value == 'mask-enabled') {
      onMaskEnabledChanged?.call(
        layer.copyWith(maskEnabled: !layer.maskEnabled),
      );
    } else if (value == 'mask-invert') {
      onMaskInvertedChanged?.call(
        layer.copyWith(maskInverted: !layer.maskInverted),
      );
    } else if (value == 'duplicate') {
      onDuplicateLayer?.call(layer);
    } else if (value == 'ungroup') {
      onUngroupLayer?.call(layer);
    } else if (value == 'select-contents') {
      onSelectContents?.call(layer);
    } else if (value == 'merge-down') {
      final siblings = orderLayerTree(layers)
          .where((candidate) => candidate.parent == layer.parent)
          .toList(growable: false);
      final index = siblings.indexWhere(
        (candidate) => candidate.id == layer.id,
      );
      if (index >= 0 && index + 1 < siblings.length) {
        _showMergePreview(context, layer, siblings[index + 1]);
      }
    } else if (value == 'delete') {
      _confirmDelete(context, layer);
    } else if (value == 'alpha') {
      onLayerChanged?.call(layer.copyWith(alphaLock: !layer.alphaLock));
    } else if (value == 'lock') {
      onLayerChanged?.call(layer.copyWith(locked: !layer.locked));
    } else if (value == 'clipping') {
      onLayerChanged?.call(layer.copyWith(clipping: !layer.clipping));
    } else if (value == 'reference') {
      onLayerChanged?.call(layer.copyWith(reference: !layer.reference));
    } else if (value == 'move-up') {
      onMoveLayer?.call(layer, 1);
    } else if (value == 'move-down') {
      onMoveLayer?.call(layer, -1);
    } else if (value == 'move-out') {
      final targetParent = _moveOutTarget(layer);
      if (_canMoveOut(layer)) {
        onMoveLayerTo?.call(layer, targetParent);
      }
    } else if (value.startsWith('move-into-')) {
      final groupId = int.tryParse(value.substring('move-into-'.length));
      if (groupId != null) onMoveLayerTo?.call(layer, groupId);
    } else if (value == 'rename') {
      showDialog<String>(
        context: context,
        builder: (_) => _RenameLayerDialog(initialName: layer.name),
      ).then((name) {
        if (name != null && name.isNotEmpty) {
          onPresentationChanged?.call(layer.copyWith(name: name));
        }
      });
    } else if (value == 'label-red') {
      onPresentationChanged?.call(layer.copyWith(label: 0xe53935ff));
    } else if (value == 'label-blue') {
      onPresentationChanged?.call(layer.copyWith(label: 0x1e88e5ff));
    } else if (value == 'label-clear') {
      onPresentationChanged?.call(layer.copyWith(label: 0));
    } else if (value.startsWith('blend-')) {
      onPresentationChanged?.call(
        layer.copyWith(blendMode: _blendModeFromWire(value.substring(6))),
      );
    }
  }

  Future<void> _confirmDelete(BuildContext context, LayerView layer) async {
    final descendants = _descendantsOf(layer.id);
    final containsComicPanel =
        layer.kind == LayerKind.panelGroup ||
        descendants.any((candidate) => candidate.kind == LayerKind.panelGroup);
    final hasChildren = descendants.isNotEmpty;
    final blocked =
        containsComicPanel || (hasChildren && layer.kind != LayerKind.group);
    if (!blocked && descendants.length + 1 >= layers.length) {
      _showLayerNotice(context, 'A document must keep at least one layer.');
      return;
    }
    if (!blocked && !hasChildren && layer.kind != LayerKind.group) {
      onDeleteLayer?.call(layer);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('Delete layer?'),
            content: Text(
              containsComicPanel
                  ? '“${layer.name}” owns comic panel content. Remove it from '
                      'the Comics workspace so its panel and mask links stay valid.'
                  : hasChildren && layer.kind != LayerKind.group
                  ? '“${layer.name}” contains child layers. Move or delete '
                      'those layers first; only groups can be removed with their contents.'
                  : hasChildren
                  ? '“${layer.name}” and its ${descendants.length} descendant '
                      '${descendants.length == 1 ? 'layer' : 'layers'} will be '
                      'removed together. You can undo this action.'
                  : '“${layer.name}” will be removed. You can undo this action.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              if (!blocked)
                FilledButton.tonal(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: const Text('Delete'),
                ),
            ],
          ),
    );
    if (confirmed == true) onDeleteLayer?.call(layer);
  }

  List<LayerView> _descendantsOf(int parentId) {
    final descendants = <LayerView>[];
    final pending = <int>[parentId];
    while (pending.isNotEmpty) {
      final currentParent = pending.removeLast();
      for (final child in layers.where(
        (candidate) => candidate.parent == currentParent,
      )) {
        descendants.add(child);
        pending.add(child.id);
      }
    }
    return descendants;
  }

  Future<void> _showSwipeActions(BuildContext context, LayerView layer) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder:
          (context) => SafeArea(
            child: Wrap(
              children: [
                InkMenuItem(
                  icon: Icons.visibility,
                  label:
                      layer.visible
                          ? 'Hide ${layer.name}'
                          : 'Show ${layer.name}',
                  onPressed: () => Navigator.of(context).pop('visibility'),
                ),
                InkMenuItem(
                  icon: Icons.lock,
                  label: layer.alphaLock ? 'Unlock alpha' : 'Lock alpha',
                  onPressed: () => Navigator.of(context).pop('alpha'),
                ),
                if (!_isPassThroughGroup(layer) || layer.clipping)
                  InkMenuItem(
                    icon: Icons.layers,
                    label:
                        layer.clipping ? 'Disable clipping' : 'Enable clipping',
                    onPressed: () => Navigator.of(context).pop('clipping'),
                  ),
                InkMenuItem(
                  icon: Icons.star,
                  label:
                      layer.reference ? 'Unmark reference' : 'Mark reference',
                  onPressed: () => Navigator.of(context).pop('reference'),
                ),
              ],
            ),
          ),
    );
    switch (action) {
      case 'visibility':
        onLayerChanged?.call(layer.copyWith(visible: !layer.visible));
      case 'alpha':
        onLayerChanged?.call(layer.copyWith(alphaLock: !layer.alphaLock));
      case 'clipping':
        onLayerChanged?.call(layer.copyWith(clipping: !layer.clipping));
      case 'reference':
        onLayerChanged?.call(layer.copyWith(reference: !layer.reference));
      case null:
        break;
    }
  }
}

class _LayerBadge extends StatelessWidget {
  const _LayerBadge({required this.icon, required this.label, this.tooltip});

  final IconData icon;
  final String label;
  final String? tooltip;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 6),
    child: Tooltip(
      message: tooltip ?? label,
      child: Semantics(label: label, child: Icon(icon, size: 14)),
    ),
  );
}

class _ActiveLayerBadge extends StatelessWidget {
  const _ActiveLayerBadge();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textStyle = Theme.of(context).textTheme.labelSmall;
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Tooltip(
        message: 'Active paint layer',
        child: Semantics(
          label: 'Active paint layer',
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: colorScheme.primary,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              'Active',
              style: textStyle?.copyWith(
                color: colorScheme.onPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LayerColorBadge extends StatelessWidget {
  const _LayerColorBadge({required this.rgba});

  final int rgba;

  @override
  Widget build(BuildContext context) {
    final color = Color.fromARGB(
      rgba & 0xff,
      (rgba >> 24) & 0xff,
      (rgba >> 16) & 0xff,
      (rgba >> 8) & 0xff,
    );
    return Tooltip(
      message: 'Color label',
      child: Semantics(
        label: 'Layer color label',
        container: true,
        child: Container(
          width: 12,
          height: 12,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Theme.of(context).colorScheme.outline),
          ),
        ),
      ),
    );
  }
}

class _OpacityLayerSlider extends StatefulWidget {
  const _OpacityLayerSlider({
    super.key,
    required this.value,
    required this.onEditStarted,
    required this.onPreviewChanged,
    required this.onCommit,
    required this.onCancel,
  });

  final double value;
  final VoidCallback onEditStarted;
  final ValueChanged<double> onPreviewChanged;
  final ValueChanged<double> onCommit;
  final VoidCallback onCancel;

  @override
  State<_OpacityLayerSlider> createState() => _OpacityLayerSliderState();
}

class _OpacityLayerSliderState extends State<_OpacityLayerSlider> {
  late double _preview = widget.value;
  bool _cancelled = false;
  final FocusNode _focusNode = FocusNode(debugLabel: 'Layer opacity slider');

  @override
  void didUpdateWidget(covariant _OpacityLayerSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) _preview = widget.value;
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.escape): () {
        _cancelled = true;
        setState(() => _preview = widget.value);
        widget.onCancel();
      },
    },
    child: Focus(
      focusNode: _focusNode,
      child: InkPropertySlider(
        label: 'Opacity',
        value: _preview,
        min: 0,
        max: 1,
        divisions: 100,
        valueLabel: '${(_preview * 100).round()}%',
        onChangeStart: (_) {
          _cancelled = false;
          _focusNode.requestFocus();
          widget.onEditStarted();
        },
        onChanged: (value) {
          if (_cancelled) return;
          setState(() => _preview = value);
          widget.onPreviewChanged(value);
        },
        onChangeEnd: (value) {
          if (!_cancelled) widget.onCommit(value);
        },
      ),
    ),
  );
}

class _LayerThumbnail extends StatefulWidget {
  const _LayerThumbnail({required this.layer});

  final LayerView layer;

  @override
  State<_LayerThumbnail> createState() => _LayerThumbnailState();
}

class _LayerThumbnailState extends State<_LayerThumbnail> {
  ui.Image? _image;
  int _decodeGeneration = 0;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(covariant _LayerThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.layer.thumbnail != widget.layer.thumbnail ||
        oldWidget.layer.thumbnailWidth != widget.layer.thumbnailWidth ||
        oldWidget.layer.thumbnailHeight != widget.layer.thumbnailHeight) {
      _image?.dispose();
      _image = null;
      _decode();
    }
  }

  void _decode() {
    final generation = ++_decodeGeneration;
    final pixels = widget.layer.thumbnail;
    final width = widget.layer.thumbnailWidth;
    final height = widget.layer.thumbnailHeight;
    if (pixels == null ||
        width < 1 ||
        height < 1 ||
        pixels.length != width * height * 4) {
      return;
    }
    ui.decodeImageFromPixels(pixels, width, height, ui.PixelFormat.rgba8888, (
      image,
    ) {
      if (!mounted || generation != _decodeGeneration) {
        image.dispose();
        return;
      }
      setState(() => _image = image);
    });
  }

  @override
  void dispose() {
    _decodeGeneration++;
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(4),
    child: CustomPaint(
      painter: const _TransparencyCheckerboard(),
      child: Center(
        child:
            _image == null
                ? Icon(
                  widget.layer.visible
                      ? Icons.layers_outlined
                      : Icons.visibility_off,
                )
                : RawImage(
                  image: _image,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.low,
                ),
      ),
    ),
  );
}

class _TransparencyCheckerboard extends CustomPainter {
  const _TransparencyCheckerboard();

  @override
  void paint(Canvas canvas, Size size) {
    const cell = 8.0;
    final light = Paint()..color = const Color(0xffeeeeee);
    final dark = Paint()..color = const Color(0xffc7c7c7);
    for (var y = 0; y < size.height / cell; y++) {
      for (var x = 0; x < size.width / cell; x++) {
        canvas.drawRect(
          Rect.fromLTWH(x * cell, y * cell, cell, cell),
          (x + y).isEven ? light : dark,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _TransparencyCheckerboard oldDelegate) => false;
}

class _LayerProperties extends StatelessWidget {
  const _LayerProperties({
    required this.layer,
    required this.onChanged,
    required this.onOpacityEditStarted,
    required this.onOpacityPreviewChanged,
    required this.onOpacityEditCommitted,
    required this.onOpacityEditCancelled,
    required this.onPresentationChanged,
    required this.onAdjustmentChanged,
  });

  final LayerView layer;
  final ValueChanged<LayerView>? onChanged;
  final ValueChanged<LayerView>? onOpacityEditStarted;
  final void Function(LayerView, double)? onOpacityPreviewChanged;
  final ValueChanged<LayerView>? onOpacityEditCommitted;
  final ValueChanged<LayerView>? onOpacityEditCancelled;
  final ValueChanged<LayerView>? onPresentationChanged;
  final ValueChanged<LayerView>? onAdjustmentChanged;

  static const _labels = <LayerBlendMode, String>{
    LayerBlendMode.normal: 'Normal',
    LayerBlendMode.multiply: 'Multiply',
    LayerBlendMode.screen: 'Screen',
    LayerBlendMode.overlay: 'Overlay',
    LayerBlendMode.darken: 'Darken',
    LayerBlendMode.lighten: 'Lighten',
    LayerBlendMode.add: 'Add',
    LayerBlendMode.subtract: 'Subtract',
    LayerBlendMode.colorBurn: 'Color Burn',
    LayerBlendMode.linearBurn: 'Linear Burn',
    LayerBlendMode.colorDodge: 'Color Dodge',
    LayerBlendMode.softLight: 'Soft Light',
    LayerBlendMode.hardLight: 'Hard Light',
    LayerBlendMode.difference: 'Difference',
    LayerBlendMode.exclusion: 'Exclusion',
    LayerBlendMode.divide: 'Divide',
  };

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _OpacityLayerSlider(
        key: ValueKey('opacity-${layer.id}'),
        value: layer.opacity,
        onEditStarted: () => onOpacityEditStarted?.call(layer),
        onPreviewChanged:
            (value) => onOpacityPreviewChanged?.call(layer, value),
        onCommit: (value) {
          if (onOpacityEditCommitted != null) {
            onOpacityEditCommitted!(layer);
          } else {
            onChanged?.call(layer.copyWith(opacity: value));
          }
        },
        onCancel: () => onOpacityEditCancelled?.call(layer),
      ),
      if (layer.kind == LayerKind.adjustment) ...[
        const SizedBox(height: 8),
        InkInspectorSection(
          title: 'Brightness / Contrast',
          child: Column(
            children: [
              InkPropertySlider(
                label: 'Brightness',
                value: layer.adjustmentBrightness.toDouble(),
                min: -100,
                max: 100,
                divisions: 200,
                valueLabel: '${layer.adjustmentBrightness}%',
                onChanged:
                    (value) => onAdjustmentChanged?.call(
                      layer.copyWith(adjustmentBrightness: value.round()),
                    ),
              ),
              InkPropertySlider(
                label: 'Contrast',
                value: layer.adjustmentContrast.toDouble(),
                min: -100,
                max: 100,
                divisions: 200,
                valueLabel: '${layer.adjustmentContrast}%',
                onChanged:
                    (value) => onAdjustmentChanged?.call(
                      layer.copyWith(adjustmentContrast: value.round()),
                    ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  key: const ValueKey('reset-adjustment'),
                  onPressed:
                      layer.adjustmentBrightness == 0 &&
                              layer.adjustmentContrast == 0
                          ? null
                          : () => onAdjustmentChanged?.call(
                            layer.copyWith(
                              adjustmentBrightness: 0,
                              adjustmentContrast: 0,
                            ),
                          ),
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('Reset'),
                ),
              ),
            ],
          ),
        ),
      ],
      const SizedBox(height: 4),
      Row(
        children: [
          const SizedBox(width: 76, child: Text('Blend')),
          Expanded(
            child: DropdownButtonFormField<LayerBlendMode>(
              initialValue: layer.blendMode,
              isExpanded: true,
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
              ),
              items: _labels.entries
                  .map(
                    (entry) => DropdownMenuItem(
                      value: entry.key,
                      child: Text(entry.value),
                    ),
                  )
                  .toList(growable: false),
              onChanged: (value) {
                if (value != null) {
                  onPresentationChanged?.call(layer.copyWith(blendMode: value));
                }
              },
            ),
          ),
        ],
      ),
      if (layer.kind == LayerKind.group || layer.kind == LayerKind.panelGroup)
        Row(
          children: [
            const SizedBox(width: 76, child: Text('Group')),
            Expanded(
              child: DropdownButtonFormField<LayerGroupMode>(
                key: ValueKey('group-mode-${layer.id}'),
                initialValue: layer.groupMode,
                isExpanded: true,
                decoration: const InputDecoration(
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                ),
                items: [
                  const DropdownMenuItem(
                    value: LayerGroupMode.isolated,
                    child: Text('Isolated'),
                  ),
                  DropdownMenuItem(
                    value: LayerGroupMode.passThrough,
                    enabled:
                        !layer.clipping ||
                        layer.groupMode == LayerGroupMode.passThrough,
                    child: const Text('Pass-through'),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) {
                    onPresentationChanged?.call(
                      layer.copyWith(groupMode: value),
                    );
                  }
                },
              ),
            ),
          ],
        ),
      InkInspectorSection(
        title: 'Layer states',
        initiallyExpanded: false,
        child: Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            InkToggleChip(
              label: 'Alpha lock',
              icon: Icons.lock,
              value: layer.alphaLock,
              onChanged:
                  (value) => onChanged?.call(layer.copyWith(alphaLock: value)),
            ),
            Tooltip(
              message:
                  _isPassThroughGroup(layer) && !layer.clipping
                      ? 'Set Group to Isolated before clipping it to the layer below.'
                      : '',
              child: InkToggleChip(
                label: 'Clipping',
                icon: Icons.layers,
                value: layer.clipping,
                enabled: !_isPassThroughGroup(layer) || layer.clipping,
                onChanged:
                    (value) => onChanged?.call(layer.copyWith(clipping: value)),
              ),
            ),
            InkToggleChip(
              label: 'Reference',
              icon: Icons.star,
              value: layer.reference,
              onChanged:
                  (value) => onChanged?.call(layer.copyWith(reference: value)),
            ),
          ],
        ),
      ),
    ],
  );
}

/// Owns its text controller for the full route lifetime, including the
/// reverse transition after the user submits or cancels the dialog.
class _RenameLayerDialog extends StatefulWidget {
  const _RenameLayerDialog({required this.initialName});

  final String initialName;

  @override
  State<_RenameLayerDialog> createState() => _RenameLayerDialogState();
}

class _RenameLayerDialogState extends State<_RenameLayerDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Rename layer'),
    content: TextField(
      controller: _controller,
      autofocus: true,
      maxLength: 128,
      textInputAction: TextInputAction.done,
      onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
        child: const Text('Rename'),
      ),
    ],
  );
}

class _LayerDropTarget extends StatefulWidget {
  const _LayerDropTarget({
    super.key,
    required this.layer,
    required this.layers,
    required this.enabled,
    required this.rejectedReason,
    required this.canAccept,
    required this.onDrop,
    required this.child,
  });

  final LayerView layer;
  final List<LayerView> layers;
  final bool enabled;
  final String Function(LayerView source, _LayerDropPlacement placement)
  rejectedReason;
  final bool Function(LayerView source, _LayerDropPlacement placement)
  canAccept;
  final void Function(LayerView source, _LayerDropPlacement placement) onDrop;
  final Widget child;

  @override
  State<_LayerDropTarget> createState() => _LayerDropTargetState();
}

class _LayerDropTargetState extends State<_LayerDropTarget> {
  final GlobalKey _targetKey = GlobalKey();
  _LayerDropPlacement _placement = _LayerDropPlacement.before;

  _LayerDropPlacement _placementAt(Offset globalPosition) {
    final box = _targetKey.currentContext?.findRenderObject();
    if (box is! RenderBox) return _placement;
    // DragTarget reports the feedback's anchored origin. The reorder handle
    // is 48px tall and uses its center as the drag anchor, so classify the
    // user's pointer position rather than the feedback's top edge.
    final localY = box.globalToLocal(globalPosition + const Offset(0, 24)).dy;
    final ratio = localY / box.size.height;
    if (widget.layer.kind == LayerKind.group &&
        ratio >= 0.25 &&
        ratio <= 0.75) {
      return _LayerDropPlacement.inside;
    }
    return ratio < 0.5 ? _LayerDropPlacement.before : _LayerDropPlacement.after;
  }

  @override
  Widget build(BuildContext context) => DragTarget<LayerView>(
    onWillAcceptWithDetails:
        (details) =>
            widget.enabled &&
            widget.canAccept(details.data, _placementAt(details.offset)),
    onMove: (details) {
      final next = _placementAt(details.offset);
      if (next != _placement) setState(() => _placement = next);
    },
    onAcceptWithDetails:
        (details) => widget.onDrop(details.data, _placementAt(details.offset)),
    builder:
        (context, candidates, rejected) => DecoratedBox(
          key: _targetKey,
          decoration: BoxDecoration(
            color:
                candidates.isNotEmpty &&
                        _placement == _LayerDropPlacement.inside
                    ? Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.14)
                    : null,
            border:
                candidates.isEmpty || _placement == _LayerDropPlacement.inside
                    ? null
                    : Border(
                      top:
                          _placement == _LayerDropPlacement.before
                              ? BorderSide(
                                color: Theme.of(context).colorScheme.primary,
                                width: 3,
                              )
                              : BorderSide.none,
                      bottom:
                          _placement == _LayerDropPlacement.before
                              ? BorderSide.none
                              : BorderSide(
                                color: Theme.of(context).colorScheme.primary,
                                width: 3,
                              ),
                    ),
          ),
          child: Stack(
            children: [
              widget.child,
              if (rejected.isNotEmpty)
                Positioned(
                  right: 4,
                  top: 4,
                  child: Tooltip(
                    message: widget.rejectedReason(rejected.first, _placement),
                    child: Semantics(
                      label: widget.rejectedReason(rejected.first, _placement),
                      child: Icon(
                        Icons.block,
                        size: 20,
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
  );
}
