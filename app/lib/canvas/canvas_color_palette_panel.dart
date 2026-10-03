import 'package:flutter/material.dart';

import '../design_system/ink_components.dart';
import 'canvas_quick_controls.dart';

class CanvasColorPalettePanel extends StatelessWidget {
  const CanvasColorPalettePanel({
    super.key,
    required this.mainColor,
    required this.subColor,
    required this.recentColors,
    required this.eraserActive,
    required this.onChoose,
    required this.onChooseSub,
    required this.onSelectRecent,
    required this.onSwap,
    required this.onReset,
    required this.onTransparent,
  });

  final Color mainColor;
  final Color subColor;
  final List<String> recentColors;
  final bool eraserActive;
  final VoidCallback onChoose;
  final VoidCallback onChooseSub;
  final ValueChanged<Color> onSelectRecent;
  final VoidCallback onSwap;
  final VoidCallback onReset;
  final VoidCallback onTransparent;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(12),
    children: [
      Text('Current colors', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 12),
      Row(
        children: [
          CanvasColorSwatch(color: mainColor, size: 36, onTap: onChoose),
          const SizedBox(width: 8),
          Text('Main', style: Theme.of(context).textTheme.bodyMedium),
          const Spacer(),
          CanvasColorSwatch(color: subColor, size: 28, onTap: onChooseSub),
          const SizedBox(width: 6),
          Text('Sub', style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
      const SizedBox(height: 10),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            onPressed: onChoose,
            icon: const Icon(Icons.color_lens_outlined),
            label: const Text('Color selector'),
          ),
          OutlinedButton.icon(
            onPressed: onSwap,
            icon: const Icon(Icons.swap_horiz),
            label: const Text('Swap'),
          ),
          OutlinedButton.icon(
            onPressed: onReset,
            icon: const Icon(Icons.refresh),
            label: const Text('Reset'),
          ),
          FilledButton.tonalIcon(
            onPressed: onTransparent,
            icon: const Icon(Icons.layers_clear),
            label: Text(eraserActive ? 'Transparent active' : 'Transparent'),
          ),
        ],
      ),
      const SizedBox(height: 16),
      Text('Recent colors', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 8),
      if (recentColors.isEmpty)
        Text(
          'Colors you apply appear here for quick reuse.',
          style: Theme.of(context).textTheme.bodySmall,
        )
      else
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final value in recentColors.take(24))
              Tooltip(
                message: value,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap:
                      () => onSelectRecent(
                        Color(int.parse(value.substring(1), radix: 16)),
                      ),
                  child: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: Color(int.parse(value.substring(1), radix: 16)),
                      shape: BoxShape.circle,
                      border: Border.all(color: inkColors(context).panelBorder),
                    ),
                  ),
                ),
              ),
          ],
        ),
    ],
  );
}
