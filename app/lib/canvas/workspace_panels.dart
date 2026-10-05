import 'dart:async';

import 'package:flutter/material.dart';

import '../comics/comic_workspace.dart';
import '../design_system/ink_components.dart';
import '../tools/brush_library.dart';

/// Tool-local controls kept separate from the brush browser so artists can
/// change the active brush without losing the tool context.
class InkToolPropertiesPanel extends StatelessWidget {
  const InkToolPropertiesPanel({
    super.key,
    required this.library,
    required this.activeTool,
    required this.eraserActive,
    required this.activeLayerName,
    required this.onBrushChanged,
    required this.onToggleEraser,
    required this.onBrushColor,
    required this.onOpenLayers,
  });

  final BrushLibraryModel library;
  final String activeTool;
  final bool eraserActive;
  final String activeLayerName;
  final ValueChanged<BrushPresetView> onBrushChanged;
  final VoidCallback onToggleEraser;
  final VoidCallback onBrushColor;
  final VoidCallback onOpenLayers;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: library,
    builder: (context, _) {
      final brush = library.selected;
      return Material(
        color: Colors.transparent,
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Text(
              'Tool Properties',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            InkInspectorRow(
              icon: Icon(eraserActive ? Icons.cleaning_services : Icons.brush),
              title: eraserActive ? 'Eraser' : activeTool,
              subtitle: brush?.name ?? 'No brush selected',
              trailing: SizedBox(
                width: 52,
                child: Switch(
                  value: eraserActive,
                  onChanged: (_) => onToggleEraser(),
                ),
              ),
            ),
            InkInspectorSection(
              title: 'Brush',
              child:
                  brush == null
                      ? const Text('Choose a brush from the Brushes dock.')
                      : Column(
                        children: [
                          InkPropertySlider(
                            label: 'Size',
                            value: brush.size,
                            min: 0.25,
                            max: 4096,
                            divisions: 4095,
                            valueLabel: '${brush.size.toStringAsFixed(1)} px',
                            onChanged:
                                (value) =>
                                    onBrushChanged(brush.copyWith(size: value)),
                          ),
                          InkPropertySlider(
                            label: 'Opacity',
                            value: brush.opacity,
                            min: 0,
                            max: 1,
                            divisions: 100,
                            valueLabel: '${(brush.opacity * 100).round()}%',
                            onChanged:
                                (value) => onBrushChanged(
                                  brush.copyWith(opacity: value),
                                ),
                          ),
                          InkPropertySlider(
                            label: 'Stabilize',
                            value: brush.stabilization,
                            min: 0,
                            max: 1,
                            divisions: 100,
                            valueLabel:
                                '${(brush.stabilization * 100).round()}%',
                            onChanged:
                                (value) => onBrushChanged(
                                  brush.copyWith(stabilization: value),
                                ),
                          ),
                        ],
                      ),
            ),
            InkInspectorSection(
              title: 'Color',
              child: SizedBox(
                width: double.infinity,
                child: InkToolButton(
                  onPressed: onBrushColor,
                  icon: Icons.palette_outlined,
                  label: 'Choose main color',
                ),
              ),
            ),
            InkInspectorSection(
              title: 'Layer target',
              child: InkInspectorRow(
                icon: const Icon(Icons.layers_outlined),
                title: activeLayerName,
                trailing: InkCommandButton(
                  label: 'Open Layers',
                  onPressed: onOpenLayers,
                  icon: Icons.open_in_new,
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// Materials are project metadata, so this dock observes the comic controller
/// rather than maintaining a second list in the canvas screen.
class InkMaterialsPanel extends StatelessWidget {
  const InkMaterialsPanel({
    super.key,
    required this.controller,
    required this.onOpenComics,
  });

  final ComicWorkspaceController controller;
  final VoidCallback onOpenComics;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final materials = controller.snapshot?.materials ?? const [];
      return Material(
        color: Colors.transparent,
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Text('Materials', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Project metadata for brushes, textures, templates, and balloon styles. These entries do not insert artwork onto the canvas.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (materials.isEmpty)
              InkPanelSurface(
                child: Column(
                  children: [
                    const Icon(Icons.collections_bookmark_outlined, size: 32),
                    const SizedBox(height: 8),
                    const Text('No project materials yet.'),
                    const SizedBox(height: 8),
                    InkToolButton(
                      onPressed: onOpenComics,
                      icon: Icons.add,
                      label: 'Open Comics workspace',
                    ),
                  ],
                ),
              )
            else
              for (final material in materials)
                InkInspectorRow(
                  icon: const Icon(Icons.collections_bookmark_outlined),
                  title: material.name,
                  subtitle: '${material.kind} • ${material.license}',
                  trailing: InkCommandButton(
                    label: 'Remove ${material.name}',
                    onPressed:
                        () => unawaited(controller.removeMaterial(material.id)),
                    icon: Icons.delete_outline,
                  ),
                ),
          ],
        ),
      );
    },
  );
}
