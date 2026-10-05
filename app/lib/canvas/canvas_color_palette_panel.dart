import 'package:flutter/material.dart';

import '../design_system/ink_components.dart';
import 'canvas_quick_controls.dart';

enum _ColorRole { main, sub }

class CanvasColorPalettePanel extends StatefulWidget {
  const CanvasColorPalettePanel({
    super.key,
    required this.mainColor,
    required this.subColor,
    required this.recentColors,
    required this.transparentColorActive,
    required this.onChoose,
    required this.onChooseSub,
    required this.onSelectRecent,
    required this.onSelectRecentSub,
    required this.onSwap,
    required this.onReset,
    required this.onTransparent,
  });

  final Color mainColor;
  final Color subColor;
  final List<String> recentColors;
  final bool transparentColorActive;
  final VoidCallback onChoose;
  final VoidCallback onChooseSub;
  final ValueChanged<Color> onSelectRecent;
  final ValueChanged<Color> onSelectRecentSub;
  final VoidCallback onSwap;
  final VoidCallback onReset;
  final VoidCallback onTransparent;

  @override
  State<CanvasColorPalettePanel> createState() =>
      _CanvasColorPalettePanelState();
}

class _CanvasColorPalettePanelState extends State<CanvasColorPalettePanel> {
  _ColorRole _selectedRole = _ColorRole.main;

  void _selectRole(_ColorRole role) => setState(() => _selectedRole = role);

  void _editRole(_ColorRole role) {
    _selectRole(role);
    if (role == _ColorRole.main) {
      widget.onChoose();
    } else {
      widget.onChooseSub();
    }
  }

  Widget _roleControl(BuildContext context, _ColorRole role) {
    final isMain = role == _ColorRole.main;
    final label = isMain ? 'Main' : 'Sub';
    final color = isMain ? widget.mainColor : widget.subColor;
    final selected = _selectedRole == role;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(
          color:
              selected
                  ? Theme.of(context).colorScheme.primary
                  : inkColors(context).panelBorder,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CanvasColorSwatch(
            color: color,
            size: isMain ? 32 : 28,
            hitSize: 48,
            selected: selected,
            semanticLabel: '$label color ${_colorLabel(color)}',
            onTap: () => _selectRole(role),
          ),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          IconButton(
            tooltip: 'Edit $label color',
            onPressed: () => _editRole(role),
            constraints: const BoxConstraints.tightFor(width: 48, height: 48),
            icon: const Icon(Icons.edit_outlined, size: 18),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(12),
    children: [
      Text('Current colors', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 12),
      LayoutBuilder(
        builder: (context, constraints) {
          final controls = [
            _roleControl(context, _ColorRole.main),
            _roleControl(context, _ColorRole.sub),
          ];
          if (constraints.maxWidth < 300 ||
              MediaQuery.textScalerOf(context).scale(1) > 1.4) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                controls.first,
                const SizedBox(height: 8),
                controls.last,
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: controls.first),
              const SizedBox(width: 8),
              Expanded(child: controls.last),
            ],
          );
        },
      ),
      const SizedBox(height: 8),
      Text(
        'Recent colors apply to ${_selectedRole == _ColorRole.main ? 'Main' : 'Sub'}.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 10),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            onPressed: widget.onSwap,
            icon: const Icon(Icons.swap_horiz),
            label: const Text('Swap'),
          ),
          OutlinedButton.icon(
            onPressed: widget.onReset,
            icon: const Icon(Icons.refresh),
            label: const Text('Reset'),
          ),
          FilledButton.tonalIcon(
            onPressed: widget.onTransparent,
            icon: const Icon(Icons.layers_clear),
            label: Text(
              widget.transparentColorActive
                  ? 'Transparent active'
                  : 'Transparent',
            ),
          ),
        ],
      ),
      const SizedBox(height: 4),
      Text(
        'Transparent paints with the active brush. Eraser is a separate tool.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 16),
      Text('Recent colors', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 8),
      if (widget.recentColors.isEmpty)
        Text(
          'Colors you apply appear here for quick reuse.',
          style: Theme.of(context).textTheme.bodySmall,
        )
      else
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final value in widget.recentColors.take(24))
              IconButton(
                tooltip:
                    'Apply recent color $value to ${_selectedRole == _ColorRole.main ? 'Main' : 'Sub'}',
                onPressed: () {
                  final color = Color(int.parse(value.substring(1), radix: 16));
                  if (_selectedRole == _ColorRole.main) {
                    widget.onSelectRecent(color);
                  } else {
                    widget.onSelectRecentSub(color);
                  }
                },
                constraints: const BoxConstraints.tightFor(
                  width: 48,
                  height: 48,
                ),
                icon: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: Color(int.parse(value.substring(1), radix: 16)),
                    shape: BoxShape.circle,
                    border: Border.all(color: inkColors(context).panelBorder),
                  ),
                ),
              ),
          ],
        ),
    ],
  );

  String _colorLabel(Color color) =>
      '#${color.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';
}
