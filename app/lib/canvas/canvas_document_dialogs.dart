import 'package:flutter/material.dart';

class ProjectNameDialog extends StatefulWidget {
  const ProjectNameDialog({super.key});

  @override
  State<ProjectNameDialog> createState() => _ProjectNameDialogState();
}

class _ProjectNameDialogState extends State<ProjectNameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: 'untitled',
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final name = _controller.text.trim().replaceAll(RegExp(r'[/\\]'), '_');
    if (name.isEmpty || name == '.' || name == '..') {
      setState(() => _error = 'Enter a project name.');
      return;
    }
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Save project'),
    content: TextField(
      controller: _controller,
      autofocus: true,
      decoration: InputDecoration(
        labelText: 'Project name',
        suffixText: '.inkproj',
        errorText: _error,
      ),
      onSubmitted: (_) => _save(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _save, child: const Text('Save')),
    ],
  );
}

class NewDocumentDialog extends StatefulWidget {
  const NewDocumentDialog({super.key});

  @override
  State<NewDocumentDialog> createState() => _NewDocumentDialogState();
}

class _NewDocumentDialogState extends State<NewDocumentDialog> {
  final _formKey = GlobalKey<FormState>();
  final _width = TextEditingController(text: '2048');
  final _height = TextEditingController(text: '2048');
  final _dpi = TextEditingController(text: '300');
  _CanvasSizePreset? _selectedPreset = _CanvasSizePreset.screen;
  bool _initialized = false;

  static const _presets = <_CanvasSizePreset, String>{
    _CanvasSizePreset.square: 'Square',
    _CanvasSizePreset.portrait: 'Portrait',
    _CanvasSizePreset.story: 'Story',
    _CanvasSizePreset.landscape: 'Landscape',
    _CanvasSizePreset.a4: 'A4 print',
  };

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _applyPreset(_CanvasSizePreset.screen, updateState: false);
  }

  @override
  void dispose() {
    _width.dispose();
    _height.dispose();
    _dpi.dispose();
    super.dispose();
  }

  String? _validateDimension(String? value) {
    final parsed = int.tryParse(value ?? '');
    if (parsed == null || parsed < 1 || parsed > 32768) {
      return 'Enter a value from 1 to 32768 pixels';
    }
    return null;
  }

  String? _validateDpi(String? value) {
    final parsed = double.tryParse(value ?? '');
    if (parsed == null || !parsed.isFinite || parsed <= 0) {
      return 'Enter a positive resolution';
    }
    return null;
  }

  (int, int, double) _presetSettings(_CanvasSizePreset preset) {
    switch (preset) {
      case _CanvasSizePreset.screen:
        final media = MediaQuery.of(context);
        final pixelRatio =
            media.devicePixelRatio.isFinite && media.devicePixelRatio > 0
                ? media.devicePixelRatio
                : 1.0;
        final width =
            (media.size.width * pixelRatio).round().clamp(1, 32768).toInt();
        final height =
            (media.size.height * pixelRatio).round().clamp(1, 32768).toInt();
        return (width, height, 72);
      case _CanvasSizePreset.square:
        return (2048, 2048, 300);
      case _CanvasSizePreset.portrait:
        return (1800, 2400, 300);
      case _CanvasSizePreset.story:
        return (1440, 2560, 72);
      case _CanvasSizePreset.landscape:
        return (2400, 1800, 300);
      case _CanvasSizePreset.a4:
        return (2480, 3508, 300);
    }
  }

  void _applyPreset(_CanvasSizePreset preset, {bool updateState = true}) {
    final settings = _presetSettings(preset);
    _width.text = '${settings.$1}';
    _height.text = '${settings.$2}';
    _dpi.text = '${settings.$3}';
    if (!updateState) {
      _selectedPreset = preset;
      return;
    }
    setState(() => _selectedPreset = preset);
  }

  void _markCustom(String _) {
    if (_selectedPreset == null) return;
    setState(() => _selectedPreset = null);
  }

  Widget _dimensionFields(BuildContext context) {
    final widthField = TextFormField(
      controller: _width,
      keyboardType: TextInputType.number,
      decoration: const InputDecoration(labelText: 'Width (px)'),
      validator: _validateDimension,
      onChanged: _markCustom,
    );
    final heightField = TextFormField(
      controller: _height,
      keyboardType: TextInputType.number,
      decoration: const InputDecoration(labelText: 'Height (px)'),
      validator: _validateDimension,
      onChanged: _markCustom,
    );
    if (MediaQuery.sizeOf(context).width < 400) {
      return Column(children: [widthField, heightField]);
    }
    return Row(
      children: [
        Expanded(child: widthField),
        const SizedBox(width: 12),
        Expanded(child: heightField),
      ],
    );
  }

  void _create() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.of(context).pop((
      int.parse(_width.text),
      int.parse(_height.text),
      double.parse(_dpi.text),
    ));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
    title: const Text('New canvas'),
    content: SizedBox(
      width: 440,
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Choose a starting size or enter custom dimensions. The canvas is transparent sRGB.',
            ),
            const SizedBox(height: 16),
            Text(
              'Popular sizes',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                ChoiceChip(
                  label: const Text('Screen size'),
                  selected: _selectedPreset == _CanvasSizePreset.screen,
                  onSelected: (_) => _applyPreset(_CanvasSizePreset.screen),
                ),
                ..._presets.entries.map(
                  (entry) => ChoiceChip(
                    label: Text(entry.value),
                    selected: _selectedPreset == entry.key,
                    onSelected: (_) => _applyPreset(entry.key),
                  ),
                ),
                if (_selectedPreset == null)
                  const ChoiceChip(
                    label: Text('Custom'),
                    selected: true,
                    onSelected: null,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            _dimensionFields(context),
            TextFormField(
              controller: _dpi,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(labelText: 'Resolution (DPI)'),
              validator: _validateDpi,
              onChanged: _markCustom,
            ),
            const SizedBox(height: 8),
            Text(
              'Screen size uses the current app window’s pixel dimensions. Larger canvases use more memory.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _create, child: const Text('Create canvas')),
    ],
  );
}

enum _CanvasSizePreset { screen, square, portrait, story, landscape, a4 }
