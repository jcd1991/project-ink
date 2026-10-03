import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../design_system/ink_components.dart';

class CanvasSelectionLauncher extends StatelessWidget {
  const CanvasSelectionLauncher({
    super.key,
    required this.onDeselect,
    required this.onInvert,
    required this.onGrow,
    required this.onShrink,
  });

  final VoidCallback onDeselect;
  final VoidCallback onInvert;
  final VoidCallback onGrow;
  final VoidCallback onShrink;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topLeft,
    child: Material(
      elevation: 4,
      color: inkColors(context).panel,
      borderRadius: BorderRadius.circular(8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 10),
              child: Text('Selection'),
            ),
            InkCommandButton(
              icon: Icons.swap_horiz,
              label: 'Invert selection',
              onPressed: onInvert,
            ),
            InkCommandButton(
              icon: Icons.add,
              label: 'Grow by 1 px',
              onPressed: onGrow,
            ),
            InkCommandButton(
              icon: Icons.remove,
              label: 'Shrink by 1 px',
              onPressed: onShrink,
            ),
            InkCommandButton(
              icon: Icons.close,
              label: 'Deselect',
              onPressed: onDeselect,
            ),
          ],
        ),
      ),
    ),
  );
}

class CanvasEditorStatusBar extends StatelessWidget {
  const CanvasEditorStatusBar({
    super.key,
    required this.brushName,
    required this.layerName,
    required this.zoom,
    required this.rotation,
    required this.mirrored,
    required this.documentWidth,
    required this.documentHeight,
    required this.selected,
    required this.saveStatus,
  });

  final String brushName;
  final String layerName;
  final double zoom;
  final double rotation;
  final bool mirrored;
  final int documentWidth;
  final int documentHeight;
  final bool selected;
  final String saveStatus;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10),
    decoration: BoxDecoration(
      color: inkColors(context).panel,
      border: Border(top: BorderSide(color: inkColors(context).panelBorder)),
    ),
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _status(context, brushName),
          _status(context, layerName),
          _status(context, selected ? 'Selection active' : 'No selection'),
          const SizedBox(width: 12),
          _status(context, '$documentWidth×$documentHeight  •  8-bit sRGB'),
          _status(context, '${(zoom * 100).round()}%'),
          _status(
            context,
            '${(rotation * 180 / math.pi).round()}°${mirrored ? '  •  Mirrored' : ''}',
          ),
          _status(context, saveStatus),
        ],
      ),
    ),
  );

  Widget _status(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(right: 14),
    child: Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.labelSmall,
    ),
  );
}
