import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../design_system/ink_components.dart';
import 'layer_panel_model.dart';

typedef BeginAdjustmentEdit = Future<int> Function(int layerId);
typedef UpdateAdjustmentEdit =
    Future<void> Function(int editId, String adjustmentJson);
typedef FinishAdjustmentEdit = Future<void> Function(int editId);

/// Dialog for editing one Rust-owned non-destructive adjustment transaction.
class LayerAdjustmentEditor extends StatefulWidget {
  const LayerAdjustmentEditor({
    required this.layer,
    required this.beginEdit,
    required this.updateEdit,
    required this.commitEdit,
    required this.cancelEdit,
    super.key,
  });

  final LayerView layer;
  final BeginAdjustmentEdit beginEdit;
  final UpdateAdjustmentEdit updateEdit;
  final FinishAdjustmentEdit commitEdit;
  final FinishAdjustmentEdit cancelEdit;

  @override
  State<LayerAdjustmentEditor> createState() => _LayerAdjustmentEditorState();
}

class _LayerAdjustmentEditorState extends State<LayerAdjustmentEditor> {
  static const _curveChannels = <String>['master', 'red', 'green', 'blue'];

  late String _kind;
  late Map<String, dynamic> _settings;
  String _curveChannel = 'master';
  int? _editId;
  String? _error;
  bool _finishing = false;
  bool _allowPop = false;
  Future<void> _updates = Future<void>.value();

  @override
  void initState() {
    super.initState();
    final decoded = jsonDecode(widget.layer.adjustmentJson);
    if (decoded is Map<String, dynamic> && decoded.length == 1) {
      _kind = decoded.keys.single;
      final value = decoded[_kind];
      _settings =
          value is Map<String, dynamic>
              ? Map<String, dynamic>.from(value)
              : _defaultSettings('Levels');
    } else {
      _kind = 'BrightnessContrast';
      _settings = <String, dynamic>{'brightness': 0, 'contrast': 0};
    }
    unawaited(_begin());
  }

  Future<void> _begin() async {
    try {
      final id = await widget.beginEdit(widget.layer.id);
      if (!mounted) {
        await widget.cancelEdit(id);
        return;
      }
      setState(() => _editId = id);
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = 'Could not start adjustment: $error');
      }
    }
  }

  static Map<String, dynamic> _defaultSettings(String kind) => switch (kind) {
    'BrightnessContrast' => <String, dynamic>{'brightness': 0, 'contrast': 0},
    'Levels' => <String, dynamic>{
      'input_black': 0,
      'input_white': 255,
      'gamma_hundredths': 100,
      'output_black': 0,
      'output_white': 255,
    },
    'Curves' => <String, dynamic>{
      for (final channel in _curveChannels)
        channel: <String, dynamic>{
          'points': <Map<String, int>>[
            <String, int>{'x': 0, 'y': 0},
            <String, int>{'x': 255, 'y': 255},
            for (var index = 2; index < 16; index++)
              <String, int>{'x': 0, 'y': 0},
          ],
          'len': 2,
        },
    },
    _ => <String, dynamic>{'hue_degrees': 0, 'saturation': 0, 'lightness': 0},
  };

  String get _adjustmentJson => jsonEncode(<String, Object>{_kind: _settings});

  void _preview(VoidCallback mutation) {
    setState(mutation);
    final json = _adjustmentJson;
    _updates = _updates.then((_) async {
      final editId = _editId;
      if (editId == null) return;
      try {
        await widget.updateEdit(editId, json);
        if (mounted && _error != null) {
          setState(() => _error = null);
        }
      } on Object catch (error) {
        if (mounted) {
          setState(() => _error = 'Adjustment preview failed: $error');
        }
      }
    });
  }

  Future<void> _finish({required bool commit}) async {
    if (_finishing) return;
    setState(() => _finishing = true);
    await _updates;
    final editId = _editId;
    try {
      if (editId != null) {
        if (commit) {
          await widget.commitEdit(editId);
        } else {
          await widget.cancelEdit(editId);
        }
      }
      if (mounted) {
        setState(() => _allowPop = true);
        Navigator.of(context).pop();
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _finishing = false;
          _error =
              'Could not ${commit ? 'apply' : 'cancel'} adjustment: $error';
        });
      }
    }
  }

  @override
  void dispose() {
    final editId = _editId;
    if (editId != null && !_allowPop && !_finishing) {
      unawaited(widget.cancelEdit(editId));
    }
    super.dispose();
  }

  int _int(String key, [int fallback = 0]) =>
      (_settings[key] as num?)?.round() ?? fallback;

  Widget _slider({
    required String label,
    required int value,
    required int min,
    required int max,
    required ValueChanged<int> onChanged,
    String? display,
  }) => InkPropertySlider(
    label: label,
    value: value.toDouble(),
    min: min.toDouble(),
    max: max.toDouble(),
    divisions: max > min ? max - min : null,
    valueLabel: display ?? '$value',
    onChanged:
        _editId == null || _finishing
            ? null
            : (value) => onChanged(value.round()),
  );

  Widget _buildLevels() => Column(
    children: [
      _slider(
        label: 'Input black',
        value: _int('input_black'),
        min: 0,
        max: _int('input_white') - 1,
        onChanged: (value) => _preview(() => _settings['input_black'] = value),
      ),
      _slider(
        label: 'Input white',
        value: _int('input_white', 255),
        min: _int('input_black') + 1,
        max: 255,
        onChanged: (value) => _preview(() => _settings['input_white'] = value),
      ),
      _slider(
        label: 'Gamma',
        value: _int('gamma_hundredths', 100),
        min: 10,
        max: 1000,
        display: (_int('gamma_hundredths', 100) / 100).toStringAsFixed(2),
        onChanged:
            (value) => _preview(() => _settings['gamma_hundredths'] = value),
      ),
      _slider(
        label: 'Output black',
        value: _int('output_black'),
        min: 0,
        max: _int('output_white', 255),
        onChanged: (value) => _preview(() => _settings['output_black'] = value),
      ),
      _slider(
        label: 'Output white',
        value: _int('output_white', 255),
        min: _int('output_black'),
        max: 255,
        onChanged: (value) => _preview(() => _settings['output_white'] = value),
      ),
    ],
  );

  Widget _buildHueSaturation() => Column(
    children: [
      _slider(
        label: 'Hue',
        value: _int('hue_degrees'),
        min: -180,
        max: 180,
        onChanged: (value) => _preview(() => _settings['hue_degrees'] = value),
      ),
      _slider(
        label: 'Saturation',
        value: _int('saturation'),
        min: -100,
        max: 100,
        onChanged: (value) => _preview(() => _settings['saturation'] = value),
      ),
      _slider(
        label: 'Lightness',
        value: _int('lightness'),
        min: -100,
        max: 100,
        onChanged: (value) => _preview(() => _settings['lightness'] = value),
      ),
    ],
  );

  Map<String, dynamic> get _selectedCurve =>
      Map<String, dynamic>.from(_settings[_curveChannel] as Map);

  List<Map<String, dynamic>> get _points {
    final curve = _selectedCurve;
    final count = (curve['len'] as num).toInt();
    return (curve['points'] as List)
        .take(count)
        .map((point) => Map<String, dynamic>.from(point as Map))
        .toList(growable: false);
  }

  void _updateCurvePoints(List<Map<String, dynamic>> points) {
    final padded = <Map<String, int>>[
      for (final point in points)
        <String, int>{
          'x': (point['x'] as num).toInt(),
          'y': (point['y'] as num).toInt(),
        },
      for (var index = points.length; index < 16; index++)
        <String, int>{'x': 0, 'y': 0},
    ];
    _preview(() {
      _settings[_curveChannel] = <String, dynamic>{
        'points': padded,
        'len': points.length,
      };
    });
  }

  Widget _buildCurves() {
    final points = _points;
    final curve = _selectedCurve;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          initialValue: _curveChannel,
          decoration: const InputDecoration(labelText: 'Curve channel'),
          items: [
            for (final channel in _curveChannels)
              DropdownMenuItem(value: channel, child: Text(channel)),
          ],
          onChanged: (channel) {
            if (channel != null) setState(() => _curveChannel = channel);
          },
        ),
        const SizedBox(height: 8),
        AspectRatio(
          aspectRatio: 1.5,
          child: CustomPaint(
            painter: _CurvePainter(points),
            child: const SizedBox.expand(),
          ),
        ),
        for (var index = 1; index < points.length - 1; index++) ...[
          Text('Point ${index + 1}'),
          _slider(
            label: 'Input',
            value: (points[index]['x'] as num).toInt(),
            min: (points[index - 1]['x'] as num).toInt() + 1,
            max: (points[index + 1]['x'] as num).toInt() - 1,
            onChanged: (value) {
              final changed = points.map(Map<String, dynamic>.from).toList();
              changed[index]['x'] = value;
              _updateCurvePoints(changed);
            },
          ),
          _slider(
            label: 'Output',
            value: (points[index]['y'] as num).toInt(),
            min: 0,
            max: 255,
            onChanged: (value) {
              final changed = points.map(Map<String, dynamic>.from).toList();
              changed[index]['y'] = value;
              _updateCurvePoints(changed);
            },
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () {
                final changed =
                    points.map(Map<String, dynamic>.from).toList()
                      ..removeAt(index);
                _updateCurvePoints(changed);
              },
              icon: const Icon(Icons.remove_circle_outline),
              label: const Text('Remove point'),
            ),
          ),
        ],
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed:
                points.length >= 16
                    ? null
                    : () {
                      final gap = List.generate(points.length - 1, (index) {
                        final left = (points[index]['x'] as num).toInt();
                        final right = (points[index + 1]['x'] as num).toInt();
                        return (right - left, index);
                      })..sort((a, b) => b.$1.compareTo(a.$1));
                      final pair = gap.first;
                      final left = points[pair.$2];
                      final right = points[pair.$2 + 1];
                      final x =
                          (((left['x'] as num) + (right['x'] as num)) / 2)
                              .round();
                      final y =
                          (((left['y'] as num) + (right['y'] as num)) / 2)
                              .round();
                      final changed =
                          points.map(Map<String, dynamic>.from).toList()
                            ..insert(pair.$2 + 1, <String, dynamic>{
                              'x': x,
                              'y': y,
                            });
                      _updateCurvePoints(changed);
                    },
            icon: const Icon(Icons.add),
            label: const Text('Add curve point'),
          ),
        ),
        Text('Points: ${curve['len']} of 16'),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _editId != null && !_finishing && _error == null;
    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_finish(commit: false));
      },
      child: AlertDialog(
        title: Text('Edit ${widget.layer.name} adjustment'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: _kind,
                  decoration: const InputDecoration(labelText: 'Adjustment'),
                  items: const [
                    DropdownMenuItem(
                      value: 'BrightnessContrast',
                      child: Text('Brightness / Contrast'),
                    ),
                    DropdownMenuItem(value: 'Levels', child: Text('Levels')),
                    DropdownMenuItem(value: 'Curves', child: Text('Curves')),
                    DropdownMenuItem(
                      value: 'HueSaturation',
                      child: Text('Hue / Saturation'),
                    ),
                  ],
                  onChanged:
                      !enabled
                          ? null
                          : (kind) {
                            if (kind == null) return;
                            _preview(() {
                              _kind = kind;
                              _settings = _defaultSettings(kind);
                            });
                          },
                ),
                const SizedBox(height: 12),
                if (_kind == 'Levels') _buildLevels(),
                if (_kind == 'HueSaturation') _buildHueSaturation(),
                if (_kind == 'Curves') _buildCurves(),
                if (_kind == 'BrightnessContrast') ...[
                  _slider(
                    label: 'Brightness',
                    value: _int('brightness'),
                    min: -100,
                    max: 100,
                    onChanged:
                        (value) =>
                            _preview(() => _settings['brightness'] = value),
                  ),
                  _slider(
                    label: 'Contrast',
                    value: _int('contrast'),
                    min: -100,
                    max: 100,
                    onChanged:
                        (value) =>
                            _preview(() => _settings['contrast'] = value),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed:
                _finishing ? null : () => unawaited(_finish(commit: false)),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: enabled ? () => unawaited(_finish(commit: true)) : null,
            child: const Text('Apply'),
          ),
        ],
      ),
    );
  }
}

class _CurvePainter extends CustomPainter {
  const _CurvePainter(this.points);

  final List<Map<String, dynamic>> points;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..color = const Color(0xff202124)
        ..style = PaintingStyle.fill,
    );
    final grid =
        Paint()
          ..color = Colors.white24
          ..strokeWidth = 1;
    for (var index = 1; index < 4; index++) {
      final x = size.width * index / 4;
      final y = size.height * index / 4;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    final path = Path();
    for (var index = 0; index < points.length; index++) {
      final point = points[index];
      final offset = Offset(
        (point['x'] as num).toDouble() / 255 * size.width,
        (1 - (point['y'] as num).toDouble() / 255) * size.height,
      );
      if (index == 0) {
        path.moveTo(offset.dx, offset.dy);
      } else {
        path.lineTo(offset.dx, offset.dy);
      }
      canvas.drawCircle(offset, 4, Paint()..color = Colors.lightBlueAccent);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_CurvePainter oldDelegate) => oldDelegate.points != points;
}
