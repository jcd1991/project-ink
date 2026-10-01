import 'dart:math' as math;

import 'package:flutter/material.dart';

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

/// Layer list that supports touch-friendly multiselect while leaving all
/// mutations to the shared Rust command IDs.
class LayerPanel extends StatelessWidget {
  const LayerPanel({
    super.key,
    required this.layers,
    required this.selection,
    this.onSelectionChanged,
    this.onLayerChanged,
    this.onPresentationChanged,
    this.onAdjustmentChanged,
    this.onAddLayer,
    this.onMoveLayer,
    this.onDeleteLayer,
    this.onDuplicateLayer,
    this.onSelectContents,
    this.onMergeLayers,
  });

  final List<LayerView> layers;
  final LayerSelectionModel selection;
  final ValueChanged<Set<int>>? onSelectionChanged;
  final ValueChanged<LayerView>? onLayerChanged;
  final ValueChanged<LayerView>? onPresentationChanged;
  final ValueChanged<LayerView>? onAdjustmentChanged;
  final ValueChanged<LayerKind>? onAddLayer;
  final void Function(LayerView layer, int delta)? onMoveLayer;
  final ValueChanged<LayerView>? onDeleteLayer;
  final ValueChanged<LayerView>? onDuplicateLayer;
  final ValueChanged<LayerView>? onSelectContents;
  final void Function(LayerView source, LayerView target)? onMergeLayers;

  @override
  Widget build(BuildContext context) {
    final orderedLayers = orderLayerTree(layers);
    final selected = orderedLayers.where(
      (layer) => selection.isSelected(layer.id),
    );
    final inspector = selected.length == 1 ? selected.first : null;
    return ListView(
      children: [
        if (inspector != null)
          InkInspectorSection(
            key: ValueKey<String>(
              'layer-inspector-${inspector.id}-${inspector.kind.name}',
            ),
            title: 'Layer properties',
            child: _LayerProperties(
              layer: inspector,
              onChanged: onLayerChanged,
              onPresentationChanged: onPresentationChanged,
              onAdjustmentChanged: onAdjustmentChanged,
            ),
          ),
        if (onAddLayer != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                _addLayerChip(
                  context,
                  label: 'Raster',
                  icon: Icons.add,
                  kind: LayerKind.raster,
                ),
                _addLayerChip(
                  context,
                  label: 'Vector',
                  icon: Icons.edit,
                  kind: LayerKind.vectorInk,
                ),
                _addLayerChip(
                  context,
                  label: 'Group',
                  icon: Icons.folder,
                  kind: LayerKind.group,
                ),
                _addLayerChip(
                  context,
                  label: 'Mask',
                  icon: Icons.layers_clear,
                  kind: LayerKind.mask,
                ),
                _addLayerChip(
                  context,
                  label: 'Tone',
                  icon: Icons.grain,
                  kind: LayerKind.tone,
                ),
                _addLayerChip(
                  context,
                  label: 'Panel',
                  icon: Icons.dashboard_customize,
                  kind: LayerKind.panelGroup,
                ),
                _addLayerChip(
                  context,
                  label: 'Adjustment',
                  icon: Icons.tune,
                  kind: LayerKind.adjustment,
                ),
              ],
            ),
          ),
        ...orderedLayers.asMap().entries.map(
          (entry) => _layerTile(context, orderedLayers, entry.value, entry.key),
        ),
      ],
    );
  }

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

  Widget _layerTile(
    BuildContext context,
    List<LayerView> orderedLayers,
    LayerView layer,
    int layerIndex,
  ) {
    final siblings = orderedLayers
        .where((candidate) => candidate.parent == layer.parent)
        .toList(growable: false);
    final siblingIndex = siblings.indexWhere(
      (candidate) => candidate.id == layer.id,
    );
    final starts = <int, Offset>{};
    final current = <int, Offset>{};
    final active = <int>{};
    double? initialPinchDistance;

    double? pinchDistance(Map<int, Offset> positions) {
      if (positions.length != 2) return null;
      final values = positions.values.toList(growable: false);
      return (values[0] - values[1]).distance;
    }

    void finishPointer(int pointer) {
      active.remove(pointer);
      if (active.isNotEmpty) return;
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
        } else if (averageDelta.dx.abs() > 72) {
          // Two-finger layer swipe: alpha-lock is the non-destructive gesture
          // action, and therefore goes through the same Rust mutation path.
          onLayerChanged?.call(layer.copyWith(alphaLock: !layer.alphaLock));
        } else {
          // Two-finger hold: select opaque contents through the engine's
          // opacity-selection command.
          onSelectContents?.call(layer);
        }
      } else if (starts.length == 1 && averageDelta.dx > 72) {
        // Clip Studio-style right swipe: additive selection.
        selection.toggle(layer.id);
        onSelectionChanged?.call(selection.selected.toSet());
      } else if (starts.length == 1 && averageDelta.dx < -72) {
        // Left swipe opens the same bounded actions as the desktop menu.
        _showSwipeActions(context, layer);
      }
      starts.clear();
      current.clear();
      initialPinchDistance = null;
    }

    return Listener(
      key: ValueKey<int>(layer.id),
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) {
        starts[event.pointer] = event.localPosition;
        current[event.pointer] = event.localPosition;
        active.add(event.pointer);
        if (active.length == 2) {
          initialPinchDistance = pinchDistance(starts);
        }
      },
      onPointerMove: (event) {
        current[event.pointer] = event.localPosition;
      },
      onPointerUp: (event) {
        current[event.pointer] = event.localPosition;
        finishPointer(event.pointer);
      },
      onPointerCancel: (event) => finishPointer(event.pointer),
      child: InkLayerRow(
        selected: selection.isSelected(layer.id),
        leading: SizedBox(
          width: 36,
          height: 36,
          child:
              layer.thumbnail == null
                  ? Icon(
                    layer.visible ? Icons.visibility : Icons.visibility_off,
                  )
                  : ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Image.memory(
                      layer.thumbnail!,
                      width: 36,
                      height: 36,
                      fit: BoxFit.cover,
                      filterQuality: FilterQuality.low,
                      errorBuilder:
                          (context, error, stack) => Icon(
                            layer.visible
                                ? Icons.visibility
                                : Icons.visibility_off,
                          ),
                    ),
                  ),
        ),
        title: Text(layer.name),
        subtitle: Text(layer.kind.name),
        trailing: SizedBox(
          width: 164,
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: 0,
            runSpacing: 0,
            children: [
              InkCommandButton(
                icon: Icons.keyboard_arrow_up,
                label: 'Move layer up',
                onPressed:
                    onMoveLayer == null || siblingIndex <= 0
                        ? null
                        : () => onMoveLayer!(layer, 1),
              ),
              InkCommandButton(
                icon: Icons.keyboard_arrow_down,
                label: 'Move layer down',
                onPressed:
                    onMoveLayer == null ||
                            siblingIndex < 0 ||
                            siblingIndex >= siblings.length - 1
                        ? null
                        : () => onMoveLayer!(layer, -1),
              ),
              InkCommandButton(
                label: layer.visible ? 'Hide layer' : 'Show layer',
                icon: layer.visible ? Icons.visibility : Icons.visibility_off,
                selected: layer.visible,
                onPressed:
                    () => onLayerChanged?.call(
                      layer.copyWith(visible: !layer.visible),
                    ),
              ),
              InkCommandButton(
                label: 'Delete layer',
                icon: Icons.delete_outline,
                onPressed: () => _confirmDelete(context, layer),
              ),
              PopupMenuButton<String>(
                tooltip: 'Layer options',
                icon: const Icon(Icons.more_vert, size: 18),
                onSelected: (value) => _applyMenuAction(context, layer, value),
                itemBuilder:
                    (context) => [
                      const PopupMenuItem(
                        value: 'rename',
                        child: Text('Rename'),
                      ),
                      if (onDuplicateLayer != null)
                        const PopupMenuItem(
                          value: 'duplicate',
                          child: Text('Duplicate layer'),
                        ),
                      ...const <PopupMenuEntry<String>>[
                        PopupMenuItem(
                          value: 'delete',
                          child: Text('Delete layer…'),
                        ),
                        PopupMenuDivider(),
                        PopupMenuItem(
                          value: 'blend-Normal',
                          child: Text('Normal blend'),
                        ),
                        PopupMenuItem(
                          value: 'blend-Multiply',
                          child: Text('Multiply blend'),
                        ),
                        PopupMenuItem(
                          value: 'blend-Screen',
                          child: Text('Screen blend'),
                        ),
                        PopupMenuItem(
                          value: 'blend-Overlay',
                          child: Text('Overlay blend'),
                        ),
                        PopupMenuItem(
                          value: 'blend-Add',
                          child: Text('Add blend'),
                        ),
                        PopupMenuItem(
                          value: 'blend-Color Burn',
                          child: Text('Color Burn blend'),
                        ),
                        PopupMenuItem(
                          value: 'blend-Linear Burn',
                          child: Text('Linear Burn blend'),
                        ),
                        PopupMenuItem(
                          value: 'blend-Color Dodge',
                          child: Text('Color Dodge blend'),
                        ),
                        PopupMenuItem(
                          value: 'blend-Soft Light',
                          child: Text('Soft Light blend'),
                        ),
                        PopupMenuItem(
                          value: 'blend-Hard Light',
                          child: Text('Hard Light blend'),
                        ),
                        PopupMenuItem(
                          value: 'blend-Difference',
                          child: Text('Difference blend'),
                        ),
                        PopupMenuItem(
                          value: 'blend-Exclusion',
                          child: Text('Exclusion blend'),
                        ),
                        PopupMenuItem(
                          value: 'blend-Divide',
                          child: Text('Divide blend'),
                        ),
                        PopupMenuDivider(),
                        PopupMenuItem(
                          value: 'label-red',
                          child: Text('Red label'),
                        ),
                        PopupMenuItem(
                          value: 'label-blue',
                          child: Text('Blue label'),
                        ),
                        PopupMenuItem(
                          value: 'label-clear',
                          child: Text('Clear label'),
                        ),
                      ],
                    ],
              ),
              InkCommandButton(
                label: layer.alphaLock ? 'Unlock alpha' : 'Lock alpha',
                icon: layer.alphaLock ? Icons.lock : Icons.lock_open,
                selected: layer.alphaLock,
                onPressed:
                    () => onLayerChanged?.call(
                      layer.copyWith(alphaLock: !layer.alphaLock),
                    ),
              ),
              if (!_isPassThroughGroup(layer) || layer.clipping)
                InkCommandButton(
                  label:
                      layer.clipping ? 'Disable clipping' : 'Enable clipping',
                  icon: layer.clipping ? Icons.layers : Icons.layers_outlined,
                  selected: layer.clipping,
                  onPressed:
                      () => onLayerChanged?.call(
                        layer.copyWith(clipping: !layer.clipping),
                      ),
                ),
              InkCommandButton(
                label: layer.reference ? 'Unmark reference' : 'Mark reference',
                icon: layer.reference ? Icons.star : Icons.star_border,
                selected: layer.reference,
                onPressed:
                    () => onLayerChanged?.call(
                      layer.copyWith(reference: !layer.reference),
                    ),
              ),
            ],
          ),
        ),
        onTap: () {
          selection.select(layer.id);
          onSelectionChanged?.call(selection.selected.toSet());
        },
        onLongPress: () {
          selection.toggle(layer.id);
          onSelectionChanged?.call(selection.selected.toSet());
        },
      ),
    );
  }

  Future<void> _showMergePreview(
    BuildContext context,
    LayerView source,
    LayerView target,
  ) async {
    final unavailableReason = _mergeUnavailableReason(source, target);
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
                              'target. This remains undoable.',
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
    return null;
  }

  void _applyMenuAction(BuildContext context, LayerView layer, String value) {
    if (value == 'duplicate') {
      onDuplicateLayer?.call(layer);
    } else if (value == 'delete') {
      _confirmDelete(context, layer);
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
      onPresentationChanged?.call(layer.copyWith(label: 0xffe53935));
    } else if (value == 'label-blue') {
      onPresentationChanged?.call(layer.copyWith(label: 0xff1e88e5));
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

class _LayerProperties extends StatelessWidget {
  const _LayerProperties({
    required this.layer,
    required this.onChanged,
    required this.onPresentationChanged,
    required this.onAdjustmentChanged,
  });

  final LayerView layer;
  final ValueChanged<LayerView>? onChanged;
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
      InkPropertySlider(
        label: 'Opacity',
        value: layer.opacity,
        min: 0,
        max: 1,
        divisions: 100,
        valueLabel: '${(layer.opacity * 100).round()}%',
        onChanged: (value) => onChanged?.call(layer.copyWith(opacity: value)),
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
