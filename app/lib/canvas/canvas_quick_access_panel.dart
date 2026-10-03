import 'package:flutter/material.dart';

import '../app/editor_action.dart';
import '../app/workspace_preferences.dart';
import '../design_system/ink_components.dart';

class CanvasQuickAccessPanel extends StatefulWidget {
  const CanvasQuickAccessPanel({
    super.key,
    required this.sets,
    required this.activeSetId,
    required this.onAction,
    required this.onChanged,
  });

  final List<QuickAccessSet> sets;
  final String activeSetId;
  final ValueChanged<EditorActionId> onAction;
  final void Function(List<QuickAccessSet>, String activeSetId) onChanged;

  @override
  State<CanvasQuickAccessPanel> createState() => _QuickAccessPanelState();
}

class _QuickAccessPanelState extends State<CanvasQuickAccessPanel> {
  late String _activeSetId = widget.activeSetId;

  @override
  void didUpdateWidget(covariant CanvasQuickAccessPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.sets.any((set) => set.id == _activeSetId)) {
      _activeSetId = widget.activeSetId;
    }
  }

  QuickAccessSet get _activeSet =>
      widget.sets.where((set) => set.id == _activeSetId).firstOrNull ??
      widget.sets.first;

  Future<void> _editSet({QuickAccessSet? existing}) async {
    final nameController = TextEditingController(text: existing?.name ?? '');
    final selected = <EditorActionId>{...?existing?.actions};
    final result = await showDialog<QuickAccessSet>(
      context: context,
      builder:
          (dialogContext) => StatefulBuilder(
            builder:
                (context, setDialogState) => AlertDialog(
                  title: Text(
                    existing == null ? 'New Quick Access set' : 'Edit set',
                  ),
                  content: SizedBox(
                    width: 360,
                    height: 420,
                    child: Column(
                      children: [
                        TextField(
                          controller: nameController,
                          maxLength: 64,
                          decoration: const InputDecoration(
                            labelText: 'Set name',
                          ),
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: ListView(
                            children: [
                              for (final action in EditorActionId.values)
                                CheckboxListTile(
                                  dense: true,
                                  value: selected.contains(action),
                                  title: Text(action.label),
                                  subtitle: Text(action.category),
                                  onChanged:
                                      (enabled) => setDialogState(() {
                                        if (enabled == true &&
                                            selected.length < 32) {
                                          selected.add(action);
                                        } else {
                                          selected.remove(action);
                                        }
                                      }),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed:
                          selected.isEmpty || nameController.text.trim().isEmpty
                              ? null
                              : () => Navigator.pop(
                                dialogContext,
                                QuickAccessSet(
                                  id:
                                      existing?.id ??
                                      'quick-${DateTime.now().microsecondsSinceEpoch}',
                                  name: nameController.text.trim(),
                                  actions: selected.toList(growable: false),
                                ),
                              ),
                      child: const Text('Save'),
                    ),
                  ],
                ),
          ),
    );
    nameController.dispose();
    if (!mounted || result == null) return;
    final updated = [...widget.sets];
    final index = updated.indexWhere((set) => set.id == result.id);
    if (index >= 0) {
      updated[index] = result;
    } else if (updated.length < 8) {
      updated.add(result);
    } else {
      return;
    }
    setState(() => _activeSetId = result.id);
    widget.onChanged(updated, result.id);
  }

  void _deleteActiveSet() {
    if (widget.sets.length <= 1) return;
    final updated = widget.sets.where((set) => set.id != _activeSetId).toList();
    final nextId = updated.first.id;
    setState(() => _activeSetId = nextId);
    widget.onChanged(updated, nextId);
  }

  @override
  Widget build(BuildContext context) {
    final active = _activeSet;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Quick Access',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'Manage Quick Access sets',
                onSelected: (value) {
                  if (value == 'new') {
                    if (widget.sets.length < 8) _editSet();
                  } else if (value == 'edit') {
                    _editSet(existing: active);
                  } else if (value == 'delete') {
                    _deleteActiveSet();
                  }
                },
                itemBuilder:
                    (_) => [
                      PopupMenuItem(
                        value: 'new',
                        enabled: widget.sets.length < 8,
                        child: const Text('New set'),
                      ),
                      const PopupMenuItem(
                        value: 'edit',
                        child: Text('Edit set…'),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        enabled: widget.sets.length > 1,
                        child: const Text('Delete set'),
                      ),
                    ],
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Icon(Icons.more_horiz),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          DropdownButton<String>(
            isExpanded: true,
            value: active.id,
            items: [
              for (final set in widget.sets)
                DropdownMenuItem(value: set.id, child: Text(set.name)),
            ],
            onChanged: (id) {
              if (id == null) return;
              setState(() => _activeSetId = id);
              widget.onChanged(widget.sets, id);
            },
          ),
          const SizedBox(height: 8),
          Expanded(
            child: GridView.extent(
              maxCrossAxisExtent: 150,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              children: [
                for (final action in active.actions)
                  InkToolButton(
                    icon: Icons.bolt,
                    label: action.label,
                    compact: true,
                    onPressed: () => widget.onAction(action),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
