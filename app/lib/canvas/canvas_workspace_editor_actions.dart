import 'package:flutter/material.dart';

import '../app/workspace_preferences.dart';
import 'canvas_command_bar_editor_dialog.dart';
import 'canvas_workspace_layout_actions.dart';

/// Explicit screen state used by workspace editing and preference workflows.
class CanvasWorkspaceEditorHost {
  const CanvasWorkspaceEditorHost({
    required this.context,
    required this.mounted,
    required this.preferences,
    required this.layoutActions,
    required this.rightDockWidth,
    required this.leftDockWidth,
    required this.leftDockCollapsed,
    required this.rightDockGroups,
    required this.leftDockGroups,
    required this.rightDockTab,
    required this.selectWorkspace,
    required this.applyWorkspaceLayout,
  });

  final BuildContext Function() context;
  final bool Function() mounted;
  final WorkspacePreferences Function() preferences;
  final CanvasWorkspaceLayoutActions layoutActions;
  final double Function() rightDockWidth;
  final double Function() leftDockWidth;
  final bool Function() leftDockCollapsed;
  final List<DockGroupLayout> Function() rightDockGroups;
  final List<DockGroupLayout> Function() leftDockGroups;
  final String Function() rightDockTab;
  final void Function(String id, {bool manual}) selectWorkspace;
  final void Function(WorkspaceLayout layout) applyWorkspaceLayout;
}

/// Owns workspace editing flows and their device-local preference updates.
/// Dock presentation state is read through the host and remains screen-owned.
class CanvasWorkspaceEditorActions {
  const CanvasWorkspaceEditorActions(this.host);

  final CanvasWorkspaceEditorHost host;

  Future<void> customizeCommandBar() async {
    final current = host.layoutActions.effectiveCommandBarItems();
    final edited = await showDialog<List<String>>(
      context: host.context(),
      builder: (_) => CanvasCommandBarEditorDialog(initialItems: current),
    );
    if (!host.mounted() || edited == null) return;
    final preferences = host.preferences();
    final layout = host.layoutActions.layoutFor(
      preferences.workspaceId,
      preferences.customWorkspaces,
    );
    if (layout.kind == WorkspacePresetKind.custom) {
      final custom = [...preferences.customWorkspaces];
      final index = custom.indexWhere((item) => item.id == layout.id);
      if (index < 0) return;
      final currentLayout = custom[index];
      custom[index] = WorkspaceLayout(
        id: currentLayout.id,
        name: currentLayout.name,
        kind: currentLayout.kind,
        left: currentLayout.left,
        right: currentLayout.right,
        commandBar: edited,
      );
      host.layoutActions.persistPreferences(customWorkspaces: custom);
      return;
    }
    final overrides = Map<String, List<String>>.from(
      preferences.commandBarOverrides,
    )..[preferences.workspaceId] = edited;
    host.layoutActions.persistPreferences(commandBarOverrides: overrides);
  }

  Future<void> renameWorkspace(String id) async {
    final preferences = host.preferences();
    final index = preferences.customWorkspaces.indexWhere(
      (layout) => layout.id == id,
    );
    if (index < 0) return;
    final controller = TextEditingController(
      text: preferences.customWorkspaces[index].name,
    );
    final name = await showDialog<String>(
      context: host.context(),
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('Rename workspace'),
            content: TextField(
              controller: controller,
              autofocus: true,
              maxLength: 64,
              decoration: const InputDecoration(labelText: 'Workspace name'),
              onSubmitted: (value) => Navigator.pop(dialogContext, value),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, controller.text),
                child: const Text('Rename'),
              ),
            ],
          ),
    );
    controller.dispose();
    final normalized = name?.trim();
    if (!host.mounted() ||
        normalized == null ||
        normalized.isEmpty ||
        normalized.length > 64) {
      return;
    }
    final updated = [...preferences.customWorkspaces];
    final layout = updated[index];
    updated[index] = WorkspaceLayout(
      id: layout.id,
      name: normalized,
      kind: WorkspacePresetKind.custom,
      left: layout.left,
      right: layout.right,
      commandBar: layout.commandBar,
    );
    host.layoutActions.persistPreferences(customWorkspaces: updated);
  }

  Future<void> deleteWorkspace(String id) async {
    final preferences = host.preferences();
    final workspace =
        preferences.customWorkspaces
            .where((layout) => layout.id == id)
            .firstOrNull;
    if (workspace == null) return;
    final confirmed = await showDialog<bool>(
      context: host.context(),
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('Delete workspace?'),
            content: Text(
              '“${workspace.name}” will be removed from this device.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Delete'),
              ),
            ],
          ),
    );
    if (!host.mounted() || confirmed != true) return;
    final remaining = preferences.customWorkspaces
        .where((layout) => layout.id != id)
        .toList(growable: false);
    if (preferences.workspaceId == id) {
      host.selectWorkspace('illustration', manual: false);
    }
    host.layoutActions.persistPreferences(customWorkspaces: remaining);
  }

  Future<void> saveWorkspaceAs() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: host.context(),
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('Save workspace as'),
            content: TextField(
              controller: controller,
              autofocus: true,
              maxLength: 64,
              decoration: const InputDecoration(labelText: 'Workspace name'),
              onSubmitted:
                  (value) => Navigator.pop(dialogContext, value.trim()),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed:
                    () => Navigator.pop(dialogContext, controller.text.trim()),
                child: const Text('Save'),
              ),
            ],
          ),
    );
    controller.dispose();
    final normalized = name?.trim();
    if (!host.mounted() ||
        normalized == null ||
        normalized.isEmpty ||
        normalized.length > 64) {
      return;
    }
    final preferences = host.preferences();
    if (preferences.customWorkspaces.length >= 12) return;
    final id = 'custom-${DateTime.now().microsecondsSinceEpoch}';
    final selectedLayout = switch (preferences.workspaceId) {
      'comic' => comicWorkspace,
      'minimal' => minimalWorkspace,
      _ =>
        preferences.customWorkspaces
                .where((layout) => layout.id == preferences.workspaceId)
                .firstOrNull ??
            illustrationWorkspace,
    };
    final rightGroups =
        host.rightDockGroups().isNotEmpty
            ? host.rightDockGroups()
            : selectedLayout.right?.groups ?? const <DockGroupLayout>[];
    final activeRight = host.layoutActions.paletteForDockTab(
      host.rightDockTab(),
    );
    final savedRightGroups =
        rightGroups.isEmpty
            ? [
              DockGroupLayout(tabs: [activeRight], activeTab: activeRight),
            ]
            : [
              DockGroupLayout(
                flex: rightGroups.first.flex,
                tabs:
                    rightGroups.first.tabs.contains(activeRight)
                        ? rightGroups.first.tabs
                        : [
                          ...rightGroups.first.tabs,
                          activeRight,
                        ].take(8).toList(),
                activeTab: activeRight,
              ),
              ...rightGroups.skip(1),
            ];
    final custom = WorkspaceLayout(
      id: id,
      name: normalized,
      kind: WorkspacePresetKind.custom,
      left:
          selectedLayout.left == null
              ? null
              : DockColumnLayout(
                width: host.leftDockWidth(),
                collapsed: host.leftDockCollapsed(),
                groups:
                    host.leftDockGroups().isNotEmpty
                        ? host.leftDockGroups()
                        : selectedLayout.left!.groups,
              ),
      right: DockColumnLayout(
        width: host.rightDockWidth(),
        collapsed: selectedLayout.right?.collapsed ?? false,
        groups: savedRightGroups,
      ),
      commandBar: host.layoutActions.effectiveCommandBarItems(),
    );
    host.layoutActions.persistPreferences(
      workspaceId: id,
      customWorkspaces: [...preferences.customWorkspaces, custom],
    );
  }

  Future<void> resetBuiltInWorkspace(String workspaceId) async {
    if (!const {'illustration', 'comic', 'minimal'}.contains(workspaceId)) {
      return;
    }
    final accepted = await showDialog<bool>(
      context: host.context(),
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('Reset workspace layout?'),
            content: const Text(
              'This restores the built-in dock groups, widths, and command bar. '
              'Your artwork and editor state will not change.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Reset layout'),
              ),
            ],
          ),
    );
    if (accepted != true || !host.mounted()) return;
    final preferences = host.preferences();
    final workspaceOverrides = Map<String, WorkspaceLayout>.from(
      preferences.workspaceOverrides,
    )..remove(workspaceId);
    final commandBarOverrides = Map<String, List<String>>.from(
      preferences.commandBarOverrides,
    )..remove(workspaceId);
    final defaultLayout = switch (workspaceId) {
      'comic' => comicWorkspace,
      'minimal' => minimalWorkspace,
      _ => illustrationWorkspace,
    };
    final isCurrentWorkspace = preferences.workspaceId == workspaceId;
    if (isCurrentWorkspace) host.applyWorkspaceLayout(defaultLayout);
    host.layoutActions.persistPreferences(
      dockWidth: isCurrentWorkspace ? defaultLayout.right?.width ?? 360 : null,
      leftDockWidth:
          isCurrentWorkspace ? defaultLayout.left?.width ?? 248 : null,
      workspaceOverrides: workspaceOverrides,
      commandBarOverrides: commandBarOverrides,
    );
  }
}
