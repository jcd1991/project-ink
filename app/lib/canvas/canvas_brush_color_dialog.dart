import 'package:flutter/material.dart';

import 'canvas_color_picker_controls.dart';

/// Temporary color selection UI. Persistence remains with the caller.
class CanvasBrushColorDialog extends StatefulWidget {
  const CanvasBrushColorDialog({
    required this.initialColor,
    required this.title,
    required this.recentColors,
    super.key,
  });

  final Color initialColor;
  final String title;
  final List<String> recentColors;

  @override
  State<CanvasBrushColorDialog> createState() => _CanvasBrushColorDialogState();
}

class _CanvasBrushColorDialogState extends State<CanvasBrushColorDialog> {
  late HSVColor _hsv = HSVColor.fromColor(widget.initialColor);
  late int _alpha = (widget.initialColor.a * 255).round();

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Row(
      children: [
        Expanded(child: Text(widget.title)),
        const Text('C', style: TextStyle(fontSize: 13)),
      ],
    ),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            label: 'Selected ${widget.title.toLowerCase()}',
            value:
                '#${(_hsv.toColor().r * 255).round().toRadixString(16).padLeft(2, '0')}${(_hsv.toColor().g * 255).round().toRadixString(16).padLeft(2, '0')}${(_hsv.toColor().b * 255).round().toRadixString(16).padLeft(2, '0')}',
            child: CanvasColorWheel(
              color: _hsv.toColor(),
              onChanged: (next) => setState(() => _hsv = next),
            ),
          ),
          const SizedBox(height: 10),
          Semantics(
            label: 'Saturation and value square',
            hint: 'Drag horizontally for saturation and vertically for value',
            child: CanvasColorSquare(
              color: _hsv.toColor(),
              onChanged: (next) => setState(() => _hsv = next),
            ),
          ),
          const SizedBox(height: 8),
          _hsvSlider(
            label: 'Value',
            value: _hsv.value,
            color: _hsv.toColor(),
            onChanged: (value) => setState(() => _hsv = _hsv.withValue(value)),
          ),
          _hsvSlider(
            label: 'Alpha',
            value: _alpha / 255,
            color: Theme.of(context).colorScheme.primary,
            onChanged:
                (value) => setState(() => _alpha = (value * 255).round()),
          ),
          Text(
            'H ${_hsv.hue.round()}°  S ${(_hsv.saturation * 100).round()}%  V ${(_hsv.value * 100).round()}%',
            style: Theme.of(context).textTheme.labelMedium,
          ),
          _rgbSlider(
            label: 'Red',
            value: (_hsv.toColor().r * 255).round(),
            color: Colors.red,
            onChanged: (value) {
              final color = _hsv.toColor();
              setState(
                () =>
                    _hsv = HSVColor.fromColor(
                      Color.fromARGB(
                        255,
                        value,
                        (color.g * 255).round(),
                        (color.b * 255).round(),
                      ),
                    ),
              );
            },
          ),
          _rgbSlider(
            label: 'Green',
            value: (_hsv.toColor().g * 255).round(),
            color: Colors.green,
            onChanged: (value) {
              final color = _hsv.toColor();
              setState(
                () =>
                    _hsv = HSVColor.fromColor(
                      Color.fromARGB(
                        255,
                        (color.r * 255).round(),
                        value,
                        (color.b * 255).round(),
                      ),
                    ),
              );
            },
          ),
          _rgbSlider(
            label: 'Blue',
            value: (_hsv.toColor().b * 255).round(),
            color: Colors.blue,
            onChanged: (value) {
              final color = _hsv.toColor();
              setState(
                () =>
                    _hsv = HSVColor.fromColor(
                      Color.fromARGB(
                        255,
                        (color.r * 255).round(),
                        (color.g * 255).round(),
                        value,
                      ),
                    ),
              );
            },
          ),
          const SizedBox(height: 6),
          if (widget.recentColors.isNotEmpty) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Recent colors',
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final value in widget.recentColors)
                  _recentColorButton(context, value),
              ],
            ),
            const SizedBox(height: 8),
          ],
          const Text('I or Alt-I samples a color from the canvas'),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed:
            () =>
                Navigator.pop(context, _hsv.withAlpha(_alpha / 255).toColor()),
        child: const Text('Apply'),
      ),
    ],
  );

  Widget _recentColorButton(BuildContext context, String value) {
    final color = Color(int.parse(value.substring(1), radix: 16));
    return Tooltip(
      message: 'Use $value',
      child: Semantics(
        button: true,
        label: 'Recent color $value',
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap:
              () => setState(() {
                _hsv = HSVColor.fromColor(color);
                _alpha = (color.a * 255).round();
              }),
          child: Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: Theme.of(context).colorScheme.outline),
            ),
          ),
        ),
      ),
    );
  }

  Widget _hsvSlider({
    required String label,
    required double value,
    required Color color,
    required ValueChanged<double> onChanged,
  }) => Semantics(
    label: label,
    value: '${(value * 100).round()}%',
    child: Row(
      children: [
        SizedBox(width: 52, child: Text(label)),
        Expanded(
          child: Slider(
            activeColor: color,
            value: value.clamp(0.0, 1.0),
            min: 0,
            max: 1,
            divisions: 100,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 56,
          child: Text(
            '${(value * 100).round()}%',
            maxLines: 1,
            softWrap: false,
            textAlign: TextAlign.end,
          ),
        ),
      ],
    ),
  );

  Widget _rgbSlider({
    required String label,
    required int value,
    required Color color,
    required ValueChanged<int> onChanged,
  }) => Semantics(
    label: label,
    value: '$value',
    child: Row(
      children: [
        SizedBox(width: 48, child: Text(label)),
        Expanded(
          child: Slider(
            activeColor: color,
            value: value.toDouble(),
            min: 0,
            max: 255,
            divisions: 255,
            onChanged: (next) => onChanged(next.round()),
          ),
        ),
        SizedBox(width: 32, child: Text('$value')),
      ],
    ),
  );
}
