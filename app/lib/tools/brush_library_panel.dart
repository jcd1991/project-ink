import 'dart:math' as math;
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../design_system/ink_components.dart';
import 'brush_library.dart';

typedef BrushPreviewRenderer =
    Future<Uint8List> Function(
      int brushId,
      int width,
      int height,
      List<BrushPreviewPointView> points,
    );

class BrushRenameDialog extends StatefulWidget {
  const BrushRenameDialog({super.key, required this.initialName});

  final String initialName;

  @override
  State<BrushRenameDialog> createState() => _BrushRenameDialogState();
}

class _BrushRenameDialogState extends State<BrushRenameDialog> {
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
    title: const Text('Rename brush'),
    content: TextField(
      key: const ValueKey('rename-brush-name-field'),
      controller: _controller,
      autofocus: true,
      maxLength: 256,
      decoration: const InputDecoration(labelText: 'Brush name'),
      onSubmitted: (value) => Navigator.of(context).pop(value),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(_controller.text),
        child: const Text('Rename'),
      ),
    ],
  );
}

/// Compact/desktop-safe brush browser. The callbacks are intentionally
/// separate from the model so a Rust bridge command can be inserted without
/// making Flutter the source of truth for brush rendering.
class BrushLibraryPanel extends StatelessWidget {
  static const double _minBrushSize = 0.25;
  static const double _maxBrushSize = 4096;
  static final double _brushSizeLogRange = math.log(
    _maxBrushSize / _minBrushSize,
  );
  static const double _minTextureScale = 0.01;
  static const double _maxTextureScale = 64;

  static double _brushSizeSliderValue(double size) =>
      (math.log(size.clamp(_minBrushSize, _maxBrushSize) / _minBrushSize) /
              _brushSizeLogRange)
          .clamp(0, 1);

  static double _brushSizeFromSliderValue(double value) =>
      _minBrushSize *
      math.pow(_maxBrushSize / _minBrushSize, value.clamp(0, 1)).toDouble();

  const BrushLibraryPanel({
    super.key,
    required this.library,
    this.onSelected,
    this.onChanged,
    this.onSizeChangeEnd,
    this.onImport,
    this.onExport,
    this.onDuplicate,
    this.onRename,
    this.hasUncommittedChanges = false,
    this.onCommitEdit,
    this.onCancelEdit,
    this.renderPreview,
  });

  final BrushLibraryModel library;

  /// Called when the active preset changes. Selection must not create a Rust
  /// edit draft; only actual control changes should do that.
  final ValueChanged<BrushPresetView>? onSelected;
  final ValueChanged<BrushPresetView>? onChanged;
  final ValueChanged<double>? onSizeChangeEnd;
  final VoidCallback? onImport;
  final VoidCallback? onExport;
  final VoidCallback? onDuplicate;
  final VoidCallback? onRename;
  final bool hasUncommittedChanges;
  final VoidCallback? onCommitEdit;
  final VoidCallback? onCancelEdit;
  final BrushPreviewRenderer? renderPreview;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: library,
    builder: (context, _) {
      return ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Brushes',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                tooltip: 'Import brush',
                onPressed: onImport,
                icon: const Icon(Icons.file_open_outlined),
              ),
              IconButton(
                tooltip: 'Export selected brush',
                onPressed: library.selected == null ? null : onExport,
                icon: const Icon(Icons.ios_share),
              ),
              PopupMenuButton<String>(
                tooltip: 'Brush actions',
                enabled: library.selected != null,
                onSelected: (action) {
                  switch (action) {
                    case 'duplicate':
                      onDuplicate?.call();
                    case 'rename':
                      onRename?.call();
                  }
                },
                itemBuilder:
                    (context) => [
                      const PopupMenuItem(
                        value: 'duplicate',
                        child: Text('Duplicate brush'),
                      ),
                      PopupMenuItem(
                        value: 'rename',
                        enabled: library.selected?.isBuiltin == false,
                        child: const Text('Rename brush'),
                      ),
                    ],
                icon: const Icon(Icons.more_horiz),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            children: BrushBrowserFilter.values
                .map((filter) {
                  final label = switch (filter) {
                    BrushBrowserFilter.all => 'All',
                    BrushBrowserFilter.recent => 'Recent',
                    BrushBrowserFilter.favorites => 'Favorites',
                    BrushBrowserFilter.custom => 'My brushes',
                  };
                  return ChoiceChip(
                    key:
                        filter == BrushBrowserFilter.favorites
                            ? const ValueKey('brush-favorites-filter')
                            : null,
                    label: Text(label),
                    selected: library.browserFilter == filter,
                    onSelected: (_) => library.setBrowserFilter(filter),
                  );
                })
                .toList(growable: false),
          ),
          if (library.sets.isNotEmpty || library.selected != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 42,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ChoiceChip(
                            label: const Text('All sets'),
                            selected: library.activeSetId == null,
                            onSelected: (_) => library.selectSet(null),
                          ),
                        ),
                        ...library.sets.map(
                          (set) => Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: ChoiceChip(
                              label: Text(
                                '${set.name} (${set.brushKeys.length})',
                              ),
                              selected: library.activeSetId == set.id,
                              onSelected: (_) => library.selectSet(set.id),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Create brush set',
                  onPressed: () async {
                    final name = await showDialog<String>(
                      context: context,
                      builder: (_) => const _BrushSetNameDialog(),
                    );
                    if (name != null && name.trim().isNotEmpty) {
                      library.createSet(name);
                    }
                  },
                  icon: const Icon(Icons.create_new_folder_outlined),
                ),
                if (library.activeSetId case final setId?)
                  PopupMenuButton<String>(
                    tooltip: 'Set actions',
                    onSelected: (action) {
                      if (action == 'add') library.addSelectedToSet(setId);
                      if (action == 'remove') {
                        library.removeSelectedFromSet(setId);
                      }
                      if (action == 'delete') library.deleteSet(setId);
                      if (action == 'rename') {
                        final set = library.sets.firstWhere(
                          (item) => item.id == setId,
                        );
                        showDialog<String>(
                          context: context,
                          builder:
                              (_) => _BrushSetNameDialog(
                                initialName: set.name,
                                editing: true,
                              ),
                        ).then((name) {
                          if (name != null && name.trim().isNotEmpty) {
                            library.renameSet(setId, name);
                          }
                        });
                      }
                    },
                    itemBuilder:
                        (_) => [
                          PopupMenuItem(
                            value: 'add',
                            enabled: library.selected != null,
                            child: const Text('Add selected brush'),
                          ),
                          PopupMenuItem(
                            value: 'remove',
                            enabled:
                                library.selected != null &&
                                library.sets
                                    .firstWhere(
                                      (set) => set.id == library.activeSetId,
                                    )
                                    .brushKeys
                                    .contains(library.selected!.libraryKey),
                            child: const Text('Remove selected brush'),
                          ),
                          const PopupMenuItem(
                            value: 'rename',
                            child: Text('Rename set'),
                          ),
                          const PopupMenuItem(
                            value: 'delete',
                            child: Text('Delete set'),
                          ),
                        ],
                    icon: const Icon(Icons.more_vert),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          TextField(
            decoration: InputDecoration(
              hintText: 'Search brushes',
              prefixIcon: const Icon(Icons.search),
              isDense: true,
              filled: true,
              fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
            ),
            onChanged: library.setSearchQuery,
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 42,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: const Text('Every type'),
                    selected: library.familyFilter == null,
                    onSelected: (_) => library.setFamilyFilter(null),
                  ),
                ),
                ...BrushFamily.values.map(
                  (family) => Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(_familyLabel(family)),
                      selected: library.familyFilter == family,
                      onSelected:
                          (_) => library.setFamilyFilter(
                            library.familyFilter == family ? null : family,
                          ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          ...library.filteredPresets.map((preset) {
            final selected = library.selected?.id == preset.id;
            return Card(
              margin: const EdgeInsets.symmetric(vertical: 3),
              clipBehavior: Clip.antiAlias,
              color:
                  selected
                      ? Theme.of(context).colorScheme.secondaryContainer
                      : Theme.of(context).colorScheme.surfaceContainerLow,
              child: ListTile(
                key: ValueKey('brush-row-${preset.id}'),
                minTileHeight: 66,
                title: Text(
                  preset.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${_familyLabel(preset.family)} · ${preset.isBuiltin ? 'Built-in' : 'Custom'}',
                ),
                leading: SizedBox(
                  width: 62,
                  height: 32,
                  child: _BrushThumbnail(
                    preset: preset,
                    renderer: renderPreview,
                    fallbackColor: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                trailing: IconButton(
                  key:
                      selected ? const ValueKey('toggle-brush-favorite') : null,
                  tooltip:
                      preset.favorite ? 'Remove favorite' : 'Add to favorites',
                  onPressed: () => library.toggleFavorite(preset.id),
                  icon: Icon(
                    preset.favorite
                        ? Icons.star_rounded
                        : Icons.star_border_rounded,
                    color:
                        preset.favorite
                            ? Theme.of(context).colorScheme.primary
                            : null,
                  ),
                ),
                onTap: () {
                  library.select(preset.id);
                  onSelected?.call(preset);
                },
              ),
            );
          }),
          if (library.filteredPresets.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'No brushes found',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          if (library.tags.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Tags', style: Theme.of(context).textTheme.labelMedium),
            Wrap(
              spacing: 6,
              children: library.tags
                  .map(
                    (tag) => InkSelectableChip(
                      label: tag,
                      selected: library.activeTagFilters.contains(tag),
                      minimumHeight: 40,
                      onPressed: () => library.toggleTagFilter(tag),
                    ),
                  )
                  .toList(growable: false),
            ),
          ],
          if (library.selected case final selected?) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Text(
                    selected.name,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip:
                      library.editorOpen ? 'Close brush editor' : 'Edit brush',
                  onPressed: library.toggleEditor,
                  icon: Icon(
                    library.editorOpen ? Icons.expand_less : Icons.tune,
                  ),
                ),
              ],
            ),
            if (library.editorOpen || hasUncommittedChanges) ...[
              const SizedBox(height: 6),
              if (selected.isBuiltin)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Factory brush'),
                        const SizedBox(height: 4),
                        const Text(
                          'Duplicate this brush to edit its pressure, texture, and paint behavior.',
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: onDuplicate,
                          icon: const Icon(Icons.content_copy),
                          label: const Text('Duplicate to customize'),
                        ),
                      ],
                    ),
                  ),
                )
              else ...[
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Test your brush',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Clear test strokes',
                      onPressed: () => library.clearScratchPad(),
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ],
                ),
                BrushScratchPad(
                  key: ValueKey('brush-pad-${library.scratchPadRevision}'),
                  preset: selected,
                  renderer: renderPreview,
                ),
                if (hasUncommittedChanges)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            key: const ValueKey('cancel-brush-edit'),
                            onPressed: onCancelEdit,
                            child: const Text('Discard'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: FilledButton(
                            key: const ValueKey('commit-brush-edit'),
                            onPressed: onCommitEdit,
                            child: const Text('Save changes'),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
            const SizedBox(height: 6),
            InkPropertySlider(
              label: 'Size',
              value: _brushSizeSliderValue(selected.size),
              min: 0,
              max: 1,
              valueLabel: '${selected.size.toStringAsFixed(1)} px',
              onChanged: (value) {
                final updated = selected.copyWith(
                  size: _brushSizeFromSliderValue(value),
                );
                library.updateDraft(updated);
                onChanged?.call(updated);
              },
              onChangeEnd:
                  library.editorOpen && !selected.isBuiltin
                      ? null
                      : (value) => onSizeChangeEnd?.call(
                          _brushSizeFromSliderValue(value),
                        ),
            ),
            InkPropertySlider(
              label: 'Opacity',
              value: selected.opacity,
              min: 0,
              max: 1,
              divisions: 100,
              valueLabel: '${(selected.opacity * 100).round()}%',
              onChanged: (value) {
                final updated = selected.copyWith(opacity: value);
                library.updateDraft(updated);
                onChanged?.call(updated);
              },
            ),
            if (library.editorOpen && !selected.isBuiltin) ...[
              Wrap(
                spacing: 6,
                children: BrushEditorSection.values
                    .map((section) {
                      final label = switch (section) {
                        BrushEditorSection.stroke => 'Stroke',
                        BrushEditorSection.pressure => 'Pressure',
                        BrushEditorSection.tip => 'Tip & texture',
                        BrushEditorSection.paint => 'Paint',
                      };
                      return ChoiceChip(
                        label: Text(label),
                        selected: library.editorSection == section,
                        onSelected: (_) => library.selectEditorSection(section),
                      );
                    })
                    .toList(growable: false),
              ),
              if (library.editorSection == BrushEditorSection.stroke)
                InkPropertySlider(
                  label: 'Stabilize',
                  value: selected.stabilization,
                  min: 0,
                  max: 1,
                  divisions: 100,
                  valueLabel: '${(selected.stabilization * 100).round()}%',
                  onChanged: (value) {
                    final updated = selected.copyWith(stabilization: value);
                    library.updateDraft(updated);
                    onChanged?.call(updated);
                  },
                ),
              if (library.editorSection == BrushEditorSection.pressure) ...[
                InkPropertySlider(
                  label: 'Pressure size',
                  value: selected.pressureSize,
                  min: 0,
                  max: 1,
                  divisions: 100,
                  valueLabel: '${(selected.pressureSize * 100).round()}%',
                  onChanged: (value) {
                    final updated = selected.copyWith(pressureSize: value);
                    library.updateDraft(updated);
                    onChanged?.call(updated);
                  },
                ),
                InkPropertySlider(
                  label: 'Pressure opacity',
                  value: selected.pressureOpacity,
                  min: 0,
                  max: 1,
                  divisions: 100,
                  valueLabel: '${(selected.pressureOpacity * 100).round()}%',
                  onChanged: (value) {
                    final updated = selected.copyWith(pressureOpacity: value);
                    library.updateDraft(updated);
                    onChanged?.call(updated);
                  },
                ),
                InkPropertySlider(
                  label: 'Curve response',
                  value: selected.pressureCurve,
                  min: 0,
                  max: 1,
                  divisions: 100,
                  valueLabel: '${(selected.pressureCurve * 100).round()}%',
                  onChanged: (value) {
                    final points = selected.pressureCurvePoints.toList();
                    final index = points.length > 2 ? 1 : points.length - 1;
                    points[index] = points[index].copyWith(y: value);
                    final updated = selected.copyWith(
                      pressureCurve: value,
                      pressureCurvePoints: points,
                    );
                    library.updateDraft(updated);
                    onChanged?.call(updated);
                  },
                ),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Advanced pressure curve (${selected.pressureCurvePoints.length} points)',
                      ),
                    ),
                    IconButton(
                      tooltip: 'Add pressure point',
                      onPressed:
                          selected.pressureCurvePoints.length >= 16
                              ? null
                              : () {
                                final points =
                                    selected.pressureCurvePoints.toList();
                                final right = points.removeLast();
                                final left = points.last;
                                points
                                  ..add(
                                    BrushCurvePointView(
                                      x: (left.x + right.x) * 0.5,
                                      y: (left.y + right.y) * 0.5,
                                    ),
                                  )
                                  ..add(right);
                                final updated = selected.copyWith(
                                  pressureCurvePoints: points,
                                );
                                library.updateDraft(updated);
                                onChanged?.call(updated);
                              },
                      icon: const Icon(Icons.add),
                    ),
                  ],
                ),
                ...selected.pressureCurvePoints.asMap().entries.map((entry) {
                  final index = entry.key;
                  final point = entry.value;
                  final previous =
                      index == 0
                          ? 0.0
                          : selected.pressureCurvePoints[index - 1].x;
                  final next =
                      index == selected.pressureCurvePoints.length - 1
                          ? 1.0
                          : selected.pressureCurvePoints[index + 1].x;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(child: Text('Point ${index + 1}')),
                          if (selected.pressureCurvePoints.length > 2)
                            IconButton(
                              tooltip: 'Remove pressure point',
                              onPressed: () {
                                final points =
                                    selected.pressureCurvePoints.toList()
                                      ..removeAt(index);
                                final updated = selected.copyWith(
                                  pressureCurvePoints: points,
                                );
                                library.updateDraft(updated);
                                onChanged?.call(updated);
                              },
                              icon: const Icon(Icons.remove_circle_outline),
                            ),
                        ],
                      ),
                      InkPropertySlider(
                        label: 'Input',
                        value: point.x,
                        min: index == 0 ? 0 : previous + 0.001,
                        max:
                            index == selected.pressureCurvePoints.length - 1
                                ? 1
                                : next - 0.001,
                        divisions: 1000,
                        valueLabel: '${(point.x * 100).round()}%',
                        onChanged:
                            index == 0 ||
                                    index ==
                                        selected.pressureCurvePoints.length - 1
                                ? null
                                : (value) {
                                  final points =
                                      selected.pressureCurvePoints.toList();
                                  points[index] = point.copyWith(x: value);
                                  final updated = selected.copyWith(
                                    pressureCurvePoints: points,
                                  );
                                  library.updateDraft(updated);
                                  onChanged?.call(updated);
                                },
                      ),
                      InkPropertySlider(
                        label: 'Output',
                        value: point.y,
                        min: 0,
                        max: 1,
                        divisions: 100,
                        valueLabel: '${(point.y * 100).round()}%',
                        onChanged: (value) {
                          final points = selected.pressureCurvePoints.toList();
                          points[index] = point.copyWith(y: value);
                          final updated = selected.copyWith(
                            pressureCurvePoints: points,
                            pressureCurve:
                                index == 1 ? value : selected.pressureCurve,
                          );
                          library.updateDraft(updated);
                          onChanged?.call(updated);
                        },
                      ),
                    ],
                  );
                }),
              ],
              if (library.editorSection == BrushEditorSection.tip) ...[
                InkPropertySlider(
                  label: 'Tip hardness',
                  value: selected.hardness,
                  min: 0,
                  max: 1,
                  divisions: 100,
                  valueLabel: '${(selected.hardness * 100).round()}%',
                  onChanged: (value) {
                    final updated = selected.copyWith(hardness: value);
                    library.updateDraft(updated);
                    onChanged?.call(updated);
                  },
                ),
                InkPropertySlider(
                  label: 'Spacing',
                  value: selected.spacing.clamp(0.01, 1.0).toDouble(),
                  min: 0.01,
                  max: 1,
                  divisions: 99,
                  valueLabel: '${(selected.spacing * 100).round()}%',
                  onChanged: (value) {
                    final updated = selected.copyWith(spacing: value);
                    library.updateDraft(updated);
                    onChanged?.call(updated);
                  },
                ),
                InkPropertySlider(
                  label: 'Texture scale',
                  value:
                      selected.textureScale
                          .clamp(_minTextureScale, _maxTextureScale)
                          .toDouble(),
                  min: _minTextureScale,
                  max: _maxTextureScale,
                  valueLabel: '${selected.textureScale.toStringAsFixed(2)}x',
                  onChanged: (value) {
                    final updated = selected.copyWith(textureScale: value);
                    library.updateDraft(updated);
                    onChanged?.call(updated);
                  },
                ),
                _ResourceInspector(
                  label: 'Tip texture',
                  hash: selected.tipResourceHash,
                ),
                _ResourceInspector(
                  label: 'Grain texture',
                  hash: selected.grainResourceHash,
                ),
                InkPropertySlider(
                  label: 'Scatter',
                  value: selected.scatter,
                  min: 0,
                  max: 1,
                  divisions: 100,
                  valueLabel: '${(selected.scatter * 100).round()}%',
                  onChanged: (value) {
                    final updated = selected.copyWith(scatter: value);
                    library.updateDraft(updated);
                    onChanged?.call(updated);
                  },
                ),
                InkPropertySlider(
                  label: 'Rotation jitter',
                  value: selected.rotationJitter,
                  min: 0,
                  max: 1,
                  divisions: 100,
                  valueLabel: '${(selected.rotationJitter * 100).round()}%',
                  onChanged: (value) {
                    final updated = selected.copyWith(rotationJitter: value);
                    library.updateDraft(updated);
                    onChanged?.call(updated);
                  },
                ),
              ],
              if (library.editorSection == BrushEditorSection.paint) ...[
                InkPropertySlider(
                  label: 'Smudge',
                  value: selected.smudge,
                  min: 0,
                  max: 1,
                  divisions: 100,
                  valueLabel: '${(selected.smudge * 100).round()}%',
                  onChanged: (value) {
                    final updated = selected.copyWith(smudge: value);
                    library.updateDraft(updated);
                    onChanged?.call(updated);
                  },
                ),
                InkPropertySlider(
                  label: 'Wetness',
                  value: selected.wetness,
                  min: 0,
                  max: 1,
                  divisions: 100,
                  valueLabel: '${(selected.wetness * 100).round()}%',
                  onChanged: (value) {
                    final updated = selected.copyWith(wetness: value);
                    library.updateDraft(updated);
                    onChanged?.call(updated);
                  },
                ),
              ],
            ],
          ],
        ],
      );
    },
  );
}

class _BrushSetNameDialog extends StatefulWidget {
  const _BrushSetNameDialog({this.initialName = '', this.editing = false});

  final String initialName;
  final bool editing;

  @override
  State<_BrushSetNameDialog> createState() => _BrushSetNameDialogState();
}

class _BrushSetNameDialogState extends State<_BrushSetNameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialName,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.editing ? 'Rename brush set' : 'Create brush set'),
    content: TextField(
      controller: _controller,
      autofocus: true,
      maxLength: 64,
      decoration: const InputDecoration(labelText: 'Set name'),
      onSubmitted: (value) => Navigator.of(context).pop(value),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(_controller.text),
        child: Text(widget.editing ? 'Save' : 'Create'),
      ),
    ],
  );
}

/// A local, disposable brush preview surface. It deliberately stays outside
/// the document engine so experiments never dirty or persist the artwork.
class BrushScratchPad extends StatefulWidget {
  const BrushScratchPad({super.key, required this.preset, this.renderer});

  final BrushPresetView preset;
  final BrushPreviewRenderer? renderer;

  @override
  State<BrushScratchPad> createState() => _BrushScratchPadState();
}

class _BrushScratchPadState extends State<BrushScratchPad> {
  static const int _height = 120;
  final List<Uint8List> _completedPreviews = <Uint8List>[];
  final List<Offset> _fallbackStroke = <Offset>[];
  List<BrushPreviewPointView> _points = <BrushPreviewPointView>[];
  Uint8List? _activePreview;
  Timer? _previewTimer;
  int _previewGeneration = 0;

  @override
  void didUpdateWidget(covariant BrushScratchPad oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.preset.libraryKey != widget.preset.libraryKey &&
        _points.isNotEmpty &&
        widget.renderer != null) {
      _schedulePreview(256);
    }
  }

  @override
  void dispose() {
    _previewTimer?.cancel();
    _previewGeneration++;
    super.dispose();
  }

  BrushPreviewPointView _point(
    Offset position,
    double width,
    PointerEvent event,
  ) {
    return BrushPreviewPointView(
      x: (position.dx / width * _previewWidth(width)).clamp(0, 256),
      y: position.dy.clamp(0, _height).toDouble(),
      pressure: event.pressure.clamp(0, 1),
    );
  }

  int _previewWidth(double width) => width.ceil().clamp(64, 256);

  void _appendPoint(PointerEvent event, double width) {
    final position = event.localPosition;
    _fallbackStroke.add(position);
    if (_points.length < 1024) {
      _points.add(_point(position, width, event));
    } else if (_points.length.isEven) {
      _points[_points.length - 1] = _point(position, width, event);
    }
  }

  void _schedulePreview(double width) {
    final renderer = widget.renderer;
    if (renderer == null || _points.isEmpty) return;
    _previewTimer?.cancel();
    final generation = ++_previewGeneration;
    _previewTimer = Timer(const Duration(milliseconds: 70), () {
      final points = List<BrushPreviewPointView>.unmodifiable(_points);
      unawaited(
        renderer(widget.preset.id, _previewWidth(width), _height, points)
            .then((pixels) {
              if (!mounted || generation != _previewGeneration) return;
              setState(() => _activePreview = pixels);
            })
            .catchError((Object error, StackTrace stack) {
              debugPrint('Brush scratch preview failed: $error\n$stack');
            }),
      );
    });
  }

  void _finishStroke(double width) {
    _previewTimer?.cancel();
    final renderer = widget.renderer;
    if (renderer == null || _points.isEmpty) {
      setState(() {
        _fallbackStroke.clear();
        _points = <BrushPreviewPointView>[];
      });
      return;
    }
    final generation = ++_previewGeneration;
    final points = List<BrushPreviewPointView>.unmodifiable(_points);
    setState(() {
      _points = <BrushPreviewPointView>[];
      _fallbackStroke.clear();
      _activePreview = null;
    });
    unawaited(
      renderer(widget.preset.id, _previewWidth(width), _height, points)
          .then((pixels) {
            if (!mounted || generation != _previewGeneration) return;
            setState(() {
              if (_completedPreviews.length >= 32) {
                _completedPreviews.removeAt(0);
              }
              _completedPreviews.add(pixels);
            });
          })
          .catchError((Object error, StackTrace stack) {
            debugPrint('Brush scratch preview failed: $error\n$stack');
          }),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      final previewWidth = _previewWidth(width);
      return DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: SizedBox(
          height: _height.toDouble(),
          width: double.infinity,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown:
                (event) => setState(() {
                  _points = <BrushPreviewPointView>[];
                  _fallbackStroke.clear();
                  _activePreview = null;
                  _appendPoint(event, width);
                  _schedulePreview(width);
                }),
            onPointerMove: (event) {
              if (_points.isEmpty) return;
              setState(() {
                _appendPoint(event, width);
                _schedulePreview(width);
              });
            },
            onPointerUp: (_) => _finishStroke(width),
            onPointerCancel: (_) => _finishStroke(width),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  for (final image in _completedPreviews)
                    Image.memory(
                      image,
                      fit: BoxFit.fill,
                      gaplessPlayback: true,
                    ),
                  if (_activePreview != null)
                    Image.memory(
                      _activePreview!,
                      fit: BoxFit.fill,
                      gaplessPlayback: true,
                    )
                  else if (_fallbackStroke.isNotEmpty &&
                      widget.renderer == null)
                    CustomPaint(
                      painter: _ScratchPadPainter(
                        strokes: <List<Offset>>[_fallbackStroke],
                        preset: widget.preset,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  Semantics(
                    label: 'Brush test pad',
                    child: SizedBox(
                      width: previewWidth.toDouble(),
                      height: _height.toDouble(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _BrushThumbnail extends StatefulWidget {
  const _BrushThumbnail({
    required this.preset,
    required this.renderer,
    required this.fallbackColor,
  });

  final BrushPresetView preset;
  final BrushPreviewRenderer? renderer;
  final Color fallbackColor;

  @override
  State<_BrushThumbnail> createState() => _BrushThumbnailState();
}

class _BrushThumbnailState extends State<_BrushThumbnail> {
  Uint8List? _image;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _render();
  }

  @override
  void didUpdateWidget(covariant _BrushThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.preset.libraryKey != widget.preset.libraryKey ||
        oldWidget.renderer != widget.renderer) {
      _image = null;
      _render();
    }
  }

  void _render() {
    final renderer = widget.renderer;
    if (renderer == null) return;
    final generation = ++_generation;
    final points = List<BrushPreviewPointView>.generate(
      12,
      (index) => BrushPreviewPointView(
        x: 4 + index * 4.5,
        y: 19 + math.sin(index * 0.72) * 9,
        pressure: index / 11,
      ),
      growable: false,
    );
    unawaited(
      renderer(widget.preset.id, 64, 40, points)
          .then((pixels) {
            if (mounted && generation == _generation) {
              setState(() => _image = pixels);
            }
          })
          .catchError((Object error, StackTrace stack) {
            debugPrint('Brush thumbnail render failed: $error\n$stack');
          }),
    );
  }

  @override
  Widget build(BuildContext context) => SizedBox.expand(
    child:
        _image != null
            ? Image.memory(_image!, fit: BoxFit.fill, gaplessPlayback: true)
            : widget.renderer == null
            ? CustomPaint(
              painter: _BrushRowPreviewPainter(
                color: widget.fallbackColor,
                size: widget.preset.size,
                hardness: widget.preset.hardness,
                opacity: widget.preset.opacity,
              ),
            )
            : ColoredBox(color: widget.fallbackColor.withValues(alpha: 0.08)),
  );
}

String _familyLabel(BrushFamily family) => switch (family) {
  BrushFamily.sketch => 'Sketch',
  BrushFamily.ink => 'Ink',
  BrushFamily.paint => 'Paint',
  BrushFamily.watercolor => 'Watercolor',
  BrushFamily.effect => 'Effects',
  BrushFamily.texture => 'Texture',
  BrushFamily.eraser => 'Eraser',
};

class _BrushRowPreviewPainter extends CustomPainter {
  const _BrushRowPreviewPainter({
    required this.color,
    required this.size,
    required this.hardness,
    required this.opacity,
  });

  final Color color;
  final double size;
  final double hardness;
  final double opacity;

  @override
  void paint(Canvas canvas, Size bounds) {
    final path =
        Path()
          ..moveTo(3, bounds.height * 0.72)
          ..cubicTo(
            bounds.width * 0.2,
            bounds.height * 0.05,
            bounds.width * 0.42,
            bounds.height * 0.96,
            bounds.width * 0.58,
            bounds.height * 0.47,
          )
          ..cubicTo(
            bounds.width * 0.72,
            bounds.height * 0.06,
            bounds.width * 0.82,
            bounds.height * 0.95,
            bounds.width - 3,
            bounds.height * 0.28,
          );
    final paint =
        Paint()
          ..color = color.withValues(alpha: opacity.clamp(0, 1))
          ..strokeWidth = size.clamp(1.5, 8).toDouble()
          ..strokeCap = hardness < 0.35 ? StrokeCap.square : StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..style = PaintingStyle.stroke;
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_BrushRowPreviewPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.size != size ||
      oldDelegate.hardness != hardness ||
      oldDelegate.opacity != opacity;
}

class _ScratchPadPainter extends CustomPainter {
  const _ScratchPadPainter({
    required this.strokes,
    required this.preset,
    required this.color,
  });

  final List<List<Offset>> strokes;
  final BrushPresetView preset;
  final Color color;

  @override
  void paint(Canvas canvas, Size canvasSize) {
    final baseSize = preset.size.clamp(0.5, 128.0).toDouble();
    final baseOpacity = preset.opacity.clamp(0.0, 1.0).toDouble();
    final paint =
        Paint()
          ..color = color.withValues(
            alpha: (baseOpacity * (0.65 + preset.pressureOpacity * 0.35)).clamp(
              0.0,
              1.0,
            ),
          )
          ..strokeWidth = baseSize
          ..strokeCap =
              preset.hardness < 0.35 ? StrokeCap.square : StrokeCap.round
          ..style = PaintingStyle.stroke;
    for (final stroke in strokes) {
      if (stroke.length == 1) {
        canvas.drawCircle(stroke.single, paint.strokeWidth / 2, paint);
        continue;
      }
      final path = Path()..moveTo(stroke.first.dx, stroke.first.dy);
      var previous = stroke.first;
      final spacing = (baseSize * preset.spacing.clamp(0.01, 1.0)).clamp(
        0.5,
        64.0,
      );
      var distanceSinceDab = 0.0;
      for (final point in stroke.skip(1)) {
        final distance = (point - previous).distance;
        distanceSinceDab += distance;
        if (distanceSinceDab < spacing) continue;
        final smoothing = preset.stabilization.clamp(0.0, 1.0);
        final smoothed = Offset(
          previous.dx + (point.dx - previous.dx) * (1 - smoothing * 0.7),
          previous.dy + (point.dy - previous.dy) * (1 - smoothing * 0.7),
        );
        path.lineTo(smoothed.dx, smoothed.dy);
        previous = smoothed;
        distanceSinceDab = 0.0;
      }
      canvas.drawPath(path, paint);

      // Keep the preview deterministic while making textured, scattered,
      // smudged, and wet presets visibly distinct without touching the Rust
      // document or allocating unbounded preview state.
      final effect =
          (preset.textureScale - 1).abs() / 8 +
          preset.scatter * 0.35 +
          preset.smudge * 0.2 +
          preset.wetness * 0.2;
      if (effect > 0.01) {
        final effectPaint =
            Paint()
              ..color = color.withValues(
                alpha: (baseOpacity * effect * 0.35).clamp(0.0, 1.0),
              )
              ..strokeWidth = (baseSize * 0.35).clamp(0.5, 32.0)
              ..strokeCap = StrokeCap.round;
        for (var index = 0; index < stroke.length; index += 2) {
          final point = stroke[index];
          final phase = (index % 7) - 3;
          final offset = Offset(
            phase * preset.scatter * baseSize * 0.25,
            phase * preset.rotationJitter * baseSize * 0.12,
          );
          canvas.drawCircle(
            point + offset,
            (baseSize * 0.12 * (1 + preset.wetness)).clamp(0.5, 16.0),
            effectPaint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_ScratchPadPainter oldDelegate) =>
      oldDelegate.strokes != strokes ||
      oldDelegate.preset != preset ||
      oldDelegate.color != color;
}

class _ResourceInspector extends StatelessWidget {
  const _ResourceInspector({required this.label, required this.hash});

  final String label;
  final List<int>? hash;

  @override
  Widget build(BuildContext context) {
    final value =
        hash == null
            ? 'procedural / none'
            : '${hash!.take(8).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join()}…';
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text('$label: $value'),
    );
  }
}
