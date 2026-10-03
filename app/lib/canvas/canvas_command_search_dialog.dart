import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app/editor_action.dart';

/// Presents command search and dispatches the selected action to its owner.
Future<void> showCanvasCommandSearch({
  required BuildContext context,
  required bool Function() isMounted,
  required ValueChanged<EditorActionId> dispatch,
}) async {
  final selected = await showDialog<EditorActionId>(
    context: context,
    builder: (_) => const CanvasCommandSearchDialog(),
  );
  if (selected != null && isMounted()) dispatch(selected);
}

/// Searches available editor actions and returns the selected action.
class CanvasCommandSearchDialog extends StatefulWidget {
  const CanvasCommandSearchDialog({super.key});

  @override
  State<CanvasCommandSearchDialog> createState() =>
      _CanvasCommandSearchDialogState();
}

class _CanvasCommandSearchDialogState extends State<CanvasCommandSearchDialog> {
  final TextEditingController _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final match = searchEditorActions(_query).firstOrNull;
    if (match != null) Navigator.pop(context, match);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final bodyHeight = math.min(480.0, math.max(180.0, size.height - 220));
    final dialogWidth = math.min(480.0, math.max(240.0, size.width - 40));
    final actions = searchEditorActions(_query);
    return AlertDialog(
      title: const Text('Search commands'),
      content: SizedBox(
        width: dialogWidth,
        height: bodyHeight,
        child: Column(
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search tools, palettes, and actions',
              ),
              onChanged: (value) => setState(() => _query = value),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 8),
            Expanded(
              child:
                  actions.isEmpty
                      ? const Center(child: Text('No matching commands'))
                      : ListView.builder(
                        itemCount: actions.length,
                        itemBuilder: (context, index) {
                          final action = actions[index];
                          final details = <String>{
                            action.category,
                            if (action.paletteName != null) action.paletteName!,
                            if (action.toolName != null) action.toolName!,
                            if (action.shortcut != null) action.shortcut!,
                          }.join('  •  ');
                          return ListTile(
                            dense: true,
                            leading: const Icon(Icons.bolt_outlined),
                            title: Text(action.label),
                            subtitle: Text(details),
                            onTap: () => Navigator.pop(context, action),
                          );
                        },
                      ),
            ),
          ],
        ),
      ),
    );
  }
}
