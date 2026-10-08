import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'canvas_color_picker_controls.dart';

enum _PhoneColorAction { swap, reset }

/// One-surface color editor for phone-sized canvas workspaces.
class CanvasPhoneColorPickerPanel extends StatefulWidget {
  const CanvasPhoneColorPickerPanel({
    super.key,
    required this.mainColor,
    required this.subColor,
    required this.recentColors,
    required this.onApply,
  });

  final Color mainColor;
  final Color subColor;
  final List<String> recentColors;
  final Future<void> Function(Color mainColor, Color subColor) onApply;

  @override
  State<CanvasPhoneColorPickerPanel> createState() =>
      _CanvasPhoneColorPickerPanelState();
}

class _CanvasPhoneColorPickerPanelState
    extends State<CanvasPhoneColorPickerPanel> {
  late Color _mainColor = widget.mainColor;
  late Color _subColor = widget.subColor;
  bool _editingMain = true;
  bool _applying = false;

  Color get _activeColor => _editingMain ? _mainColor : _subColor;

  void _setActiveColor(Color color) {
    setState(() {
      if (_editingMain) {
        _mainColor = color;
      } else {
        _subColor = color;
      }
    });
  }

  void _setActiveHsv(HSVColor hsv) {
    _setActiveColor(hsv.withAlpha(_activeColor.a).toColor());
  }

  void _setRgb(int channel, int value) {
    final current = _activeColor.toARGB32();
    final alpha = (current >> 24) & 0xff;
    final red = channel == 0 ? value : (current >> 16) & 0xff;
    final green = channel == 1 ? value : (current >> 8) & 0xff;
    final blue = channel == 2 ? value : current & 0xff;
    _setActiveColor(Color.fromARGB(alpha, red, green, blue));
  }

  void _selectRecent(Color color) => _setActiveColor(color);

  Future<void> _apply() async {
    setState(() => _applying = true);
    try {
      await widget.onApply(_mainColor, _subColor);
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: _roleButton(context, main: true)),
                    const SizedBox(width: 8),
                    Expanded(child: _roleButton(context, main: false)),
                    PopupMenuButton<_PhoneColorAction>(
                      tooltip: 'More color actions',
                      onSelected: (action) {
                        setState(() {
                          if (action == _PhoneColorAction.swap) {
                            final current = _mainColor;
                            _mainColor = _subColor;
                            _subColor = current;
                          } else {
                            _mainColor = Colors.black;
                            _subColor = Colors.white;
                          }
                        });
                      },
                      itemBuilder:
                          (context) => const [
                            PopupMenuItem(
                              value: _PhoneColorAction.swap,
                              child: Text('Swap colors'),
                            ),
                            PopupMenuItem(
                              value: _PhoneColorAction.reset,
                              child: Text('Reset colors'),
                            ),
                          ],
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final wheelSize = math.min(
                      164.0,
                      constraints.maxWidth * 0.42,
                    );
                    return Row(
                      children: [
                        SizedBox.square(
                          dimension: wheelSize,
                          child: CanvasColorWheel(
                            color: _activeColor,
                            onChanged: _setActiveHsv,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: SizedBox(
                            height: wheelSize,
                            child: CanvasColorSquare(
                              color: _activeColor,
                              onChanged: _setActiveHsv,
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 4),
                Text(
                  '${_editingMain ? 'Main' : 'Sub'}  ${_hexColor(_activeColor)}',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                const SizedBox(height: 6),
                _recentColorStrip(context),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: EdgeInsets.zero,
                  title: const Text('Advanced color controls'),
                  children: [
                    _valueSlider(
                      label: 'Alpha',
                      value: _activeColor.a,
                      max: 1,
                      divisions: 255,
                      valueLabel: '${(_activeColor.a * 100).round()}%',
                      onChanged: (value) {
                        final color = _activeColor.toARGB32();
                        _setActiveColor(
                          Color.fromARGB(
                            (value * 255).round(),
                            (color >> 16) & 0xff,
                            (color >> 8) & 0xff,
                            color & 0xff,
                          ),
                        );
                      },
                    ),
                    for (final channel in [0, 1, 2])
                      _valueSlider(
                        label: ['Red', 'Green', 'Blue'][channel],
                        value: _rgbChannel(_activeColor, channel).toDouble(),
                        max: 255,
                        divisions: 255,
                        valueLabel: '${_rgbChannel(_activeColor, channel)}',
                        onChanged: (value) => _setRgb(channel, value.round()),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        Row(
          children: [
            const Spacer(),
            TextButton(
              onPressed: _applying ? null : () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 4),
            FilledButton(
              onPressed: _applying ? null : _apply,
              child:
                  _applying
                      ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                      : const Text('Apply'),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _roleButton(BuildContext context, {required bool main}) {
    final color = main ? _mainColor : _subColor;
    final selected = _editingMain == main;
    return Semantics(
      button: true,
      selected: selected,
      label: '${main ? 'Main' : 'Sub'} color',
      value: _hexColor(color),
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: const Size(0, 48),
          side: BorderSide(
            color:
                selected
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        onPressed: () => setState(() => _editingMain = main),
        child: Row(
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(main ? 'Main' : 'Sub')),
            if (selected) const Icon(Icons.check, size: 18),
          ],
        ),
      ),
    );
  }

  Widget _recentColorStrip(BuildContext context) {
    if (widget.recentColors.isEmpty) {
      return SizedBox(
        height: 44,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'Recent colors appear here',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      );
    }
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: widget.recentColors.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final value = widget.recentColors[index];
          final color = _parseColor(value);
          if (color == null) return const SizedBox.shrink();
          return Tooltip(
            message: 'Use $value for ${_editingMain ? 'Main' : 'Sub'}',
            child: Semantics(
              button: true,
              label: 'Recent color $value',
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => _selectRecent(color),
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _valueSlider({
    required String label,
    required double value,
    required double max,
    required int divisions,
    required String valueLabel,
    required ValueChanged<double> onChanged,
  }) => Semantics(
    label: label,
    value: valueLabel,
    child: Row(
      children: [
        SizedBox(width: 44, child: Text(label)),
        Expanded(
          child: Slider(
            value: value.clamp(0, max).toDouble(),
            min: 0,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
        SizedBox(width: 42, child: Text(valueLabel, textAlign: TextAlign.end)),
      ],
    ),
  );

  static int _rgbChannel(Color color, int channel) {
    final value = color.toARGB32();
    return switch (channel) {
      0 => (value >> 16) & 0xff,
      1 => (value >> 8) & 0xff,
      _ => value & 0xff,
    };
  }

  static String _hexColor(Color color) =>
      '#${color.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';

  static Color? _parseColor(String value) {
    final digits = value.startsWith('#') ? value.substring(1) : value;
    if (digits.length == 6) {
      final rgb = int.tryParse(digits, radix: 16);
      return rgb == null ? null : Color(0xff000000 | rgb);
    }
    if (digits.length != 8) return null;
    final number = int.tryParse(digits, radix: 16);
    return number == null ? null : Color(number);
  }
}
