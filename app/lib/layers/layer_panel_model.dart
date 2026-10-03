import 'dart:collection';
import 'dart:typed_data';

enum LayerKind { raster, vectorInk, group, mask, tone, panelGroup, adjustment }

enum LayerBlendMode {
  normal,
  multiply,
  screen,
  overlay,
  darken,
  lighten,
  add,
  subtract,
  colorBurn,
  linearBurn,
  colorDodge,
  softLight,
  hardLight,
  difference,
  exclusion,
  divide,
}

enum LayerGroupMode { isolated, passThrough }

/// Immutable layer projection used by the Flutter layer panel.
class LayerView {
  const LayerView({
    required this.id,
    required this.name,
    required this.kind,
    this.order = 0,
    this.parent,
    this.maskOwner,
    this.maskEnabled = true,
    this.maskInverted = false,
    this.opacity = 1,
    this.visible = true,
    this.blendMode = LayerBlendMode.normal,
    this.groupMode = LayerGroupMode.isolated,
    this.alphaLock = false,
    this.locked = false,
    this.clipping = false,
    this.reference = false,
    this.label,
    this.thumbnail,
    this.thumbnailWidth = 48,
    this.thumbnailHeight = 48,
    this.adjustmentBrightness = 0,
    this.adjustmentContrast = 0,
    this.canDrag = true,
    this.dragReason,
    this.canReceiveLayers = true,
    this.receiveReason,
    this.canEditProperties = true,
    this.editPropertiesReason,
    this.canDuplicate = true,
    this.duplicateReason,
    this.canDelete = true,
    this.deleteReason,
    this.canUngroup = true,
    this.ungroupReason,
    this.canApplyMask = true,
    this.applyMaskReason,
    this.hasMergeDownCapability = false,
    this.mergeDownReason,
  });

  final int id;
  final String name;
  final LayerKind kind;
  final int order;
  final int? parent;
  final int? maskOwner;
  final bool maskEnabled;
  final bool maskInverted;
  final double opacity;
  final bool visible;
  final LayerBlendMode blendMode;
  final LayerGroupMode groupMode;
  final bool alphaLock;
  final bool locked;
  final bool clipping;
  final bool reference;
  final int? label;
  final Uint8List? thumbnail;
  final int thumbnailWidth;
  final int thumbnailHeight;
  final int adjustmentBrightness;
  final int adjustmentContrast;
  final bool canDrag;
  final String? dragReason;
  final bool canReceiveLayers;
  final String? receiveReason;
  final bool canEditProperties;
  final String? editPropertiesReason;
  final bool canDuplicate;
  final String? duplicateReason;
  final bool canDelete;
  final String? deleteReason;
  final bool canUngroup;
  final String? ungroupReason;
  final bool canApplyMask;
  final String? applyMaskReason;
  final bool hasMergeDownCapability;
  final String? mergeDownReason;

  LayerView copyWith({
    String? name,
    double? opacity,
    bool? visible,
    LayerBlendMode? blendMode,
    LayerGroupMode? groupMode,
    bool? alphaLock,
    bool? locked,
    bool? clipping,
    bool? reference,
    int? label,
    Uint8List? thumbnail,
    int? thumbnailWidth,
    int? thumbnailHeight,
    int? adjustmentBrightness,
    int? adjustmentContrast,
    bool? maskEnabled,
    bool? maskInverted,
  }) => LayerView(
    id: id,
    name: name ?? this.name,
    kind: kind,
    order: order,
    parent: parent,
    maskOwner: maskOwner,
    maskEnabled: maskEnabled ?? this.maskEnabled,
    maskInverted: maskInverted ?? this.maskInverted,
    opacity: opacity ?? this.opacity,
    visible: visible ?? this.visible,
    blendMode: blendMode ?? this.blendMode,
    groupMode: groupMode ?? this.groupMode,
    alphaLock: alphaLock ?? this.alphaLock,
    locked: locked ?? this.locked,
    clipping: clipping ?? this.clipping,
    reference: reference ?? this.reference,
    label: label ?? this.label,
    thumbnail: thumbnail ?? this.thumbnail,
    thumbnailWidth: thumbnailWidth ?? this.thumbnailWidth,
    thumbnailHeight: thumbnailHeight ?? this.thumbnailHeight,
    adjustmentBrightness: adjustmentBrightness ?? this.adjustmentBrightness,
    adjustmentContrast: adjustmentContrast ?? this.adjustmentContrast,
    canDrag: canDrag,
    dragReason: dragReason,
    canReceiveLayers: canReceiveLayers,
    receiveReason: receiveReason,
    canEditProperties: canEditProperties,
    editPropertiesReason: editPropertiesReason,
    canDuplicate: canDuplicate,
    duplicateReason: duplicateReason,
    canDelete: canDelete,
    deleteReason: deleteReason,
    canUngroup: canUngroup,
    ungroupReason: ungroupReason,
    canApplyMask: canApplyMask,
    applyMaskReason: applyMaskReason,
    hasMergeDownCapability: hasMergeDownCapability,
    mergeDownReason: mergeDownReason,
  );
}

/// Orders a flat Rust layer projection as the user-facing layer tree.
///
/// Siblings are displayed top-to-bottom (highest compositor order first), and
/// each group's descendants remain contiguous directly below that group.
/// Stable IDs break malformed duplicate-order ties, while `visited` makes the
/// projection safe if a corrupt/stale parent reference ever reaches Flutter.
List<LayerView> orderLayerTree(Iterable<LayerView> layers) {
  final allLayers = layers.toList(growable: false);
  final childrenByParent = <int?, List<LayerView>>{};
  for (final layer in allLayers) {
    childrenByParent.putIfAbsent(layer.parent, () => <LayerView>[]).add(layer);
  }
  int compareSiblingOrder(LayerView left, LayerView right) {
    final byStackOrder = right.order.compareTo(left.order);
    return byStackOrder != 0 ? byStackOrder : left.id.compareTo(right.id);
  }

  for (final siblings in childrenByParent.values) {
    siblings.sort(compareSiblingOrder);
  }

  final result = <LayerView>[];
  final visited = <int>{};
  void appendChildren(int? parentId) {
    for (final layer in childrenByParent[parentId] ?? const <LayerView>[]) {
      if (!visited.add(layer.id)) continue;
      result.add(layer);
      appendChildren(layer.id);
    }
  }

  appendChildren(null);
  // Keep orphaned/cyclic entries inspectable rather than hiding them. Rust
  // normally rejects these structures; this is a defensive UI projection.
  final unattached = allLayers
    .where((layer) => !visited.contains(layer.id))
    .toList(growable: false)..sort(compareSiblingOrder);
  for (final layer in unattached) {
    if (!visited.add(layer.id)) continue;
    result.add(layer);
    appendChildren(layer.id);
  }
  return result;
}

/// Selection state only; layer content and mutation commands stay in Rust.
class LayerSelectionModel {
  final Set<int> _selected = <int>{};
  final Set<int> _collapsedGroups = <int>{};
  int? _primaryId;
  bool _selectMode = false;

  int? get primaryId => _primaryId;
  bool get selectMode => _selectMode;

  UnmodifiableSetView<int> get selected => UnmodifiableSetView<int>(_selected);
  UnmodifiableSetView<int> get collapsedGroups =>
      UnmodifiableSetView<int>(_collapsedGroups);

  bool isSelected(int id) => _selected.contains(id);

  void clear() {
    _selected.clear();
    _primaryId = null;
  }

  void restorePresentationState({
    required int? primaryId,
    required Iterable<int> collapsedGroups,
  }) {
    _selected
      ..clear()
      ..addAll(primaryId == null ? const <int>[] : <int>[primaryId]);
    _primaryId = primaryId;
    _collapsedGroups
      ..clear()
      ..addAll(collapsedGroups);
  }

  void toggleGroupExpanded(int id) {
    if (!_collapsedGroups.add(id)) _collapsedGroups.remove(id);
  }

  void toggleSelectMode() {
    _selectMode = !_selectMode;
  }

  void select(int id, {bool additive = false}) {
    if (!additive) _selected.clear();
    _selected.add(id);
    _primaryId = id;
  }

  void toggle(int id) {
    if (_selected.add(id)) return;
    _selected.remove(id);
    if (_primaryId == id) {
      _primaryId = _selected.isEmpty ? null : _selected.last;
    }
  }

  /// Updates secondary selection without changing the active edit target.
  void toggleSecondary(int id) {
    if (_primaryId == id) return;
    if (!_selected.add(id)) _selected.remove(id);
  }

  void selectAll(Iterable<int> ids) {
    _selected
      ..clear()
      ..addAll(ids);
    if (_primaryId == null || !_selected.contains(_primaryId)) {
      _primaryId = _selected.isEmpty ? null : _selected.first;
    }
  }

  /// Keeps the active layer selected while clearing all secondary layers.
  void deselectAll() {
    final primary = _primaryId;
    _selected
      ..clear()
      ..addAll(primary == null ? const <int>[] : <int>[primary]);
  }

  void selectRange(List<LayerView> ordered, int anchor, int target) {
    final start = ordered.indexWhere((layer) => layer.id == anchor);
    final end = ordered.indexWhere((layer) => layer.id == target);
    if (start < 0 || end < 0) return;
    _primaryId = anchor;
    final low = start < end ? start : end;
    final high = start < end ? end : start;
    _selected
      ..clear()
      ..addAll(ordered.sublist(low, high + 1).map((layer) => layer.id));
  }
}

/// Resolve the selected structural parent for a new layer. Adjustment layers
/// may be nested in ordinary groups only; panel groups remain owned by the
/// comic authoring workflow.
int? selectedLayerParentForAdd(
  LayerKind kind,
  Iterable<LayerView> layers,
  Set<int> selectedIds,
) {
  for (final layer in layers) {
    final canContain =
        layer.kind == LayerKind.group ||
        (kind != LayerKind.adjustment && layer.kind == LayerKind.panelGroup);
    if (selectedIds.contains(layer.id) && canContain) return layer.id;
  }
  return null;
}
