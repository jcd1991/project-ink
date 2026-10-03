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
    title: const Text('New document'),
    content: SizedBox(
      width: 360,
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Create a transparent sRGB canvas. Your current project is checkpointed before switching.',
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _width,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Width (pixels)'),
              validator: _validateDimension,
            ),
            TextFormField(
              controller: _height,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Height (pixels)'),
              validator: _validateDimension,
            ),
            TextFormField(
              controller: _dpi,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(labelText: 'Resolution (DPI)'),
              validator: _validateDpi,
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
      FilledButton(onPressed: _create, child: const Text('Create document')),
    ],
  );
}
