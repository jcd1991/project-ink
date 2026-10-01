import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../design_system/ink_components.dart';
import 'brush_library.dart';

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

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: library,
    builder: (context, _) {
      return ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Text('Brushes', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: onImport,
                icon: const Icon(Icons.file_open, size: 18),
                label: const Text('Import'),
              ),
              OutlinedButton.icon(
                onPressed: library.selected == null ? null : onExport,
                icon: const Icon(Icons.save_alt, size: 18),
                label: const Text('Export'),
              ),
              OutlinedButton.icon(
                onPressed: library.selected == null ? null : onDuplicate,
                icon: const Icon(Icons.content_copy, size: 18),
                label: const Text('Duplicate'),
              ),
              OutlinedButton.icon(
                key: const ValueKey('rename-brush'),
                onPressed:
                    library.selected == null || library.selected!.id < 13
                        ? null
                        : onRename,
                icon: const Icon(Icons.drive_file_rename_outline, size: 18),
                label: const Text('Rename'),
              ),
              OutlinedButton.icon(
                key: const ValueKey('commit-brush-edit'),
                onPressed: hasUncommittedChanges ? onCommitEdit : null,
                icon: const Icon(Icons.check, size: 18),
                label: const Text('Save brush changes'),
              ),
              OutlinedButton.icon(
                key: const ValueKey('cancel-brush-edit'),
                onPressed: library.selected == null ? null : onCancelEdit,
                icon: const Icon(Icons.undo, size: 18),
                label: const Text('Cancel edit'),
              ),
              OutlinedButton.icon(
                key: const ValueKey('brush-favorites-filter'),
                onPressed: library.toggleFavoritesOnly,
                icon: Icon(
                  library.favoritesOnly ? Icons.star : Icons.star_border,
                  size: 18,
                ),
                label: Text(
                  library.favoritesOnly ? 'Favorites' : 'All brushes',
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            decoration: const InputDecoration(
              labelText: 'Search brushes',
              prefixIcon: Icon(Icons.search),
              isDense: true,
            ),
            onChanged: library.setSearchQuery,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: library.filteredPresets
                .map((preset) {
                  final selected = library.selected?.id == preset.id;
                  return InkSelectableChip(
                    selected: selected,
                    label: preset.name,
                    leading: Icon(preset.favorite ? Icons.star : Icons.brush),
                    onPressed: () {
                      library.select(preset.id);
                      onSelected?.call(preset);
                    },
                  );
                })
                .toList(growable: false),
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
                    'Scratch pad',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
                IconButton(
                  key: const ValueKey('toggle-brush-favorite'),
                  tooltip:
                      selected.favorite
                          ? 'Remove brush from favorites'
                          : 'Add brush to favorites',
                  onPressed: () => library.toggleFavorite(selected.id),
                  icon: Icon(
                    selected.favorite ? Icons.star : Icons.star_border,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            BrushScratchPad(preset: selected),
            const SizedBox(height: 12),
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
                  (value) =>
                      onSizeChangeEnd?.call(_brushSizeFromSliderValue(value)),
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
                  index == 0 ? 0.0 : selected.pressureCurvePoints[index - 1].x;
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
                                index == selected.pressureCurvePoints.length - 1
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
      );
    },
  );
}

/// A local, disposable brush preview surface. It deliberately stays outside
/// the document engine so experiments never dirty or persist the artwork.
class BrushScratchPad extends StatefulWidget {
  const BrushScratchPad({super.key, required this.preset});

  final BrushPresetView preset;

  @override
  State<BrushScratchPad> createState() => _BrushScratchPadState();
}

class _BrushScratchPadState extends State<BrushScratchPad> {
  final List<List<Offset>> _strokes = <List<Offset>>[];

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
    ),
    child: SizedBox(
      height: 120,
      child: GestureDetector(
        onPanStart:
            (details) => setState(() => _strokes.add([details.localPosition])),
        onPanUpdate:
            (details) =>
                setState(() => _strokes.last.add(details.localPosition)),
        onDoubleTap: () => setState(_strokes.clear),
        child: CustomPaint(
          painter: _ScratchPadPainter(
            strokes: _strokes,
            preset: widget.preset,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
      ),
    ),
  );
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
