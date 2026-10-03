import 'package:flutter/material.dart';

import '../bridge/engine_api.dart';
import '../bridge/generated/api.dart' as rust;
import '../design_system/ink_components.dart';

class CanvasHistoryPanel extends StatefulWidget {
  const CanvasHistoryPanel({
    super.key,
    required this.engine,
    required this.revisionToken,
    required this.onNavigate,
  });

  final EngineApi engine;
  final int revisionToken;
  final Future<void> Function(int sequence) onNavigate;

  @override
  State<CanvasHistoryPanel> createState() => _HistoryPanelState();
}

class _HistoryPanelState extends State<CanvasHistoryPanel> {
  late Future<rust.HistorySnapshotView> _history = _load();

  Future<rust.HistorySnapshotView> _load() =>
      widget.engine.historySnapshot(limit: 100);

  void _refresh() {
    final nextHistory = _load();
    setState(() {
      _history = nextHistory;
    });
  }

  Future<void> _navigate(BigInt sequence) async {
    await widget.onNavigate(sequence.toInt() + 1);
    if (mounted) _refresh();
  }

  @override
  void didUpdateWidget(covariant CanvasHistoryPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.engine != widget.engine ||
        oldWidget.revisionToken != widget.revisionToken) {
      _history = _load();
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'History',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            IconButton(
              tooltip: 'Refresh history',
              onPressed: _refresh,
              icon: const Icon(Icons.refresh, size: 18),
            ),
          ],
        ),
      ),
      Expanded(
        child: FutureBuilder<rust.HistorySnapshotView>(
          future: _history,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                child: Text(
                  'History unavailable',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              );
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final history = snapshot.requireData;
            return Column(
              children: [
                if (history.wasTrimmed)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'Some older undo history was omitted to keep this document safe to open. Artwork is intact.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                Expanded(
                  child:
                      history.entries.isEmpty
                          ? Center(
                            child: Text(
                              'No edits yet',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          )
                          : ListView.builder(
                            reverse: true,
                            itemCount: history.entries.length,
                            itemBuilder: (context, index) {
                              final entry =
                                  history.entries[history.entries.length -
                                      1 -
                                      index];
                              return ListTile(
                                dense: true,
                                selected:
                                    entry.sequence.toInt() + 1 ==
                                    history.cursor,
                                enabled:
                                    entry.sequence.toInt() + 1 !=
                                    history.cursor,
                                leading: Icon(
                                  _iconFor(entry.kind),
                                  size: 18,
                                  color:
                                      entry.applied
                                          ? inkColors(context).selectedStrong
                                          : Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                ),
                                title: Text(
                                  entry.detail ?? _labelFor(entry.kind),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  entry.applied ? 'Applied' : 'Undone',
                                ),
                                onTap: () => _navigate(entry.sequence),
                              );
                            },
                          ),
                ),
              ],
            );
          },
        ),
      ),
    ],
  );

  IconData _iconFor(String kind) => switch (kind) {
    'stroke' => Icons.brush_outlined,
    'layer' || 'layer_property' => Icons.layers_outlined,
    'merge' => Icons.merge_type,
    'fill' => Icons.format_color_fill,
    'panel' => Icons.crop_square,
    'transform' => Icons.open_with,
    _ => Icons.edit_outlined,
  };

  String _labelFor(String kind) => switch (kind) {
    'stroke' => 'Brush stroke',
    'layer' => 'Layer change',
    'merge' => 'Merge layers',
    'fill' => 'Fill',
    'panel' => 'Panel edit',
    'transform' => 'Transform',
    _ => 'Edit',
  };
}
