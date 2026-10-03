import 'package:flutter/material.dart';

import '../app/editor_action.dart';
import '../app/workspace_preferences.dart';
import 'canvas_top_bar.dart';

/// Edits the temporary command-bar selection and returns it only on Save.
class CanvasCommandBarEditorDialog extends StatefulWidget {
  const CanvasCommandBarEditorDialog({required this.initialItems, super.key});

  final List<String> initialItems;

  @override
  State<CanvasCommandBarEditorDialog> createState() =>
      _CanvasCommandBarEditorDialogState();
}

class _CanvasCommandBarEditorDialogState
    extends State<CanvasCommandBarEditorDialog> {
  late List<String> _items = List<String>.of(widget.initialItems);

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Customize command bar'),
    content: SizedBox(
      width: 460,
      height: 440,
      child: Column(
        children: [
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              PopupMenuButton<EditorActionId>(
                tooltip: 'Add command',
                onSelected:
                    (action) => setState(() {
                      if (_items.length < 48) _items.add(action.name);
                    }),
                itemBuilder:
                    (_) => [
                      for (final action in EditorActionId.values.where(
                        (action) => !_items.contains(action.name),
                      ))
                        PopupMenuItem(value: action, child: Text(action.label)),
                    ],
                child: const Chip(
                  avatar: Icon(Icons.add, size: 16),
                  label: Text('Add command'),
                ),
              ),
              TextButton.icon(
                onPressed:
                    _items.length >= 48 || _items.lastOrNull == 'separator'
                        ? null
                        : () => setState(() => _items.add('separator')),
                icon: const Icon(Icons.vertical_split),
                label: const Text('Add separator'),
              ),
              TextButton(
                onPressed:
                    () => setState(
                      () => _items = List<String>.of(defaultCommandBarItems),
                    ),
                child: const Text('Reset'),
              ),
            ],
          ),
          const Divider(),
          Expanded(
            child: ReorderableListView.builder(
              itemCount: _items.length,
              onReorderItem:
                  (oldIndex, newIndex) => setState(() {
                    final item = _items.removeAt(oldIndex);
                    _items.insert(newIndex, item);
                  }),
              itemBuilder: (context, index) {
                final item = _items[index];
                final action =
                    EditorActionId.values
                        .where((candidate) => candidate.name == item)
                        .firstOrNull;
                return ListTile(
                  key: ValueKey('command-bar-$index-$item'),
                  dense: true,
                  leading: Icon(
                    item == 'separator'
                        ? Icons.vertical_split
                        : commandBarIcon(action!),
                  ),
                  title: Text(
                    action?.label ?? 'Separator',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ReorderableDragStartListener(
                        index: index,
                        child: const Icon(Icons.drag_handle),
                      ),
                      IconButton(
                        tooltip: 'Hide command',
                        onPressed:
                            _items.length <= 1
                                ? null
                                : () => setState(() {
                                  _items.removeAt(index);
                                  while (_items.isNotEmpty &&
                                      _items.last == 'separator') {
                                    _items.removeLast();
                                  }
                                  for (var i = _items.length - 1; i > 0; i--) {
                                    if (_items[i] == 'separator' &&
                                        _items[i - 1] == 'separator') {
                                      _items.removeAt(i);
                                    }
                                  }
                                }),
                        icon: const Icon(Icons.remove_circle_outline),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
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
            _items.isEmpty || _items.last == 'separator'
                ? null
                : () => Navigator.pop(context, _items),
        child: const Text('Save'),
      ),
    ],
  );
}
