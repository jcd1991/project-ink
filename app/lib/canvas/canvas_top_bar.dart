import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app/editor_action.dart';
import '../app/workspace_preferences.dart';
import '../design_system/ink_components.dart';
import 'canvas_tool_rails.dart';

IconData commandBarIcon(EditorActionId action) => switch (action) {
  EditorActionId.newDocument => Icons.note_add_outlined,
  EditorActionId.openProject => Icons.folder_open_outlined,
  EditorActionId.importPsd => Icons.image_search_outlined,
  EditorActionId.saveProject => Icons.save_outlined,
  EditorActionId.saveProjectAs => Icons.save_as_outlined,
  EditorActionId.exportPng => Icons.ios_share,
  EditorActionId.undo => Icons.undo,
  EditorActionId.redo => Icons.redo,
  EditorActionId.clearSelection => Icons.deselect,
  EditorActionId.invertSelection => Icons.flip_to_back,
  EditorActionId.growSelection => Icons.add_box_outlined,
  EditorActionId.shrinkSelection => Icons.indeterminate_check_box_outlined,
  EditorActionId.toggleEraser => Icons.cleaning_services_outlined,
  EditorActionId.fitCanvas => Icons.fit_screen,
  EditorActionId.toggleInterface => Icons.fullscreen,
  EditorActionId.showTools => Icons.build_outlined,
  EditorActionId.showBrushes => Icons.brush_outlined,
  EditorActionId.showLayers => Icons.layers_outlined,
  EditorActionId.showToolProperties => Icons.tune,
  EditorActionId.showMaterials => Icons.collections_bookmark_outlined,
  EditorActionId.showComics => Icons.auto_stories_outlined,
  EditorActionId.showHistory => Icons.history,
  EditorActionId.showQuickAccess => Icons.bolt_outlined,
  EditorActionId.showColorPicker => Icons.palette_outlined,
  EditorActionId.eyedropper => Icons.colorize,
  EditorActionId.quickMenu => Icons.apps,
  EditorActionId.commandSearch => Icons.search,
  EditorActionId.mirrorCanvas => Icons.flip,
  EditorActionId.resetRotation => Icons.screen_rotation,
  EditorActionId.actualPixels => Icons.one_x_mobiledata,
  EditorActionId.swapColors => Icons.swap_horiz,
  EditorActionId.resetColors => Icons.refresh,
};

class _CommandSearchDialog extends StatefulWidget {
  const _CommandSearchDialog();

  @override
  State<_CommandSearchDialog> createState() => _CommandSearchDialogState();
}

class _CommandSearchDialogState extends State<_CommandSearchDialog> {
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

class CanvasTopBar extends StatelessWidget {
  const CanvasTopBar({
    super.key,
    required this.documentName,
    required this.activeToolLabel,
    required this.activeBrushLabel,
    required this.saveStatusLabel,
    required this.documentActionsEnabled,
    required this.documentActionRunning,
    required this.onOpen,
    required this.onSave,
    required this.onExportMenu,
    required this.onGestureSettings,
    required this.onAccessibilitySettings,
    required this.onComics,
    required this.onUndo,
    required this.onRedo,
    required this.onCommandSearch,
    required this.mirrored,
    required this.tabletSimpleMode,
    required this.tabletStudioMode,
    required this.tabletModePreference,
    required this.onTabletModeSelected,
    required this.onToggleFocus,
    required this.workspaceId,
    required this.onWorkspaceSelected,
    required this.professionalDesktop,
    required this.nativeMenuBar,
    required this.customWorkspaces,
    required this.onSaveWorkspaceAs,
    required this.onResetWorkspace,
    required this.followDocumentType,
    required this.onFollowDocumentTypeChanged,
    required this.onRenameWorkspace,
    required this.onDeleteWorkspace,
    required this.onActionDispatch,
    required this.commandBarItems,
    required this.onCustomizeCommandBar,
    this.contextControls,
  });

  final String documentName;
  final String activeToolLabel;
  final String activeBrushLabel;
  final String saveStatusLabel;
  final bool documentActionsEnabled;
  final bool documentActionRunning;
  final VoidCallback onOpen;
  final VoidCallback onSave;
  final VoidCallback onExportMenu;
  final VoidCallback onGestureSettings;
  final VoidCallback onAccessibilitySettings;
  final VoidCallback onComics;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback onCommandSearch;
  final bool mirrored;
  final bool tabletSimpleMode;
  final bool tabletStudioMode;
  final TabletWorkspaceMode tabletModePreference;
  final ValueChanged<TabletWorkspaceMode> onTabletModeSelected;
  final VoidCallback onToggleFocus;
  final String workspaceId;
  final ValueChanged<String> onWorkspaceSelected;
  final bool professionalDesktop;
  final bool nativeMenuBar;
  final List<WorkspaceLayout> customWorkspaces;
  final VoidCallback onSaveWorkspaceAs;
  final ValueChanged<String> onResetWorkspace;
  final bool followDocumentType;
  final ValueChanged<bool> onFollowDocumentTypeChanged;
  final ValueChanged<String> onRenameWorkspace;
  final ValueChanged<String> onDeleteWorkspace;
  final EditorActionHandler onActionDispatch;
  final List<String> commandBarItems;
  final VoidCallback onCustomizeCommandBar;
  final Widget? contextControls;

  bool _isDocumentActionDisabled(EditorActionId action) =>
      isEditorActionDisabled(
        action: action,
        documentActionsEnabled: documentActionsEnabled,
        documentActionRunning: documentActionRunning,
      );

  @override
  Widget build(BuildContext context) {
    if (tabletSimpleMode) return _buildTabletTopBar(context);
    if (tabletStudioMode) return _buildTabletTopBar(context);
    // Keep the desktop command bar discoverable in narrow windows. The full
    // palette of commands moves into a labeled menu instead of becoming
    // reachable only by horizontally scrolling tiny icons.
    final availableWidth = MediaQuery.sizeOf(context).width;
    // At standard laptop/desktop sizes keep the active brush controls visible,
    // but move secondary command-bar items into More commands before the
    // contextual controls get clipped by the edge of the viewport.
    final compactDesktop = availableWidth < 2400;
    const compactVisibleCommands = {'undo', 'redo', 'commandSearch'};
    return SafeArea(
      bottom: false,
      child: Container(
        height: 36,
        decoration: BoxDecoration(
          color: inkColors(context).panel,
          border: Border(
            bottom: BorderSide(color: inkColors(context).panelBorder),
          ),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(width: 12),
              Text(
                availableWidth < 1100
                    ? documentName
                    : '$documentName  •  $activeToolLabel  •  $activeBrushLabel',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              PopupMenuButton<String>(
                tooltip: 'Workspace',
                onSelected: (value) {
                  if (value == 'saveAs') {
                    onSaveWorkspaceAs();
                  } else if (value == 'customize') {
                    onCustomizeCommandBar();
                  } else if (value == 'resetCurrent') {
                    onResetWorkspace(workspaceId);
                  } else if (value == 'follow') {
                    onFollowDocumentTypeChanged(!followDocumentType);
                  } else if (value.startsWith('rename:')) {
                    onRenameWorkspace(value.substring('rename:'.length));
                  } else if (value.startsWith('delete:')) {
                    onDeleteWorkspace(value.substring('delete:'.length));
                  } else {
                    onWorkspaceSelected(value);
                  }
                },
                itemBuilder: (_) {
                  final entries = <PopupMenuEntry<String>>[
                    const PopupMenuItem(
                      value: 'illustration',
                      child: Text('Illustration workspace'),
                    ),
                    const PopupMenuItem(
                      value: 'comic',
                      child: Text('Comic workspace'),
                    ),
                    const PopupMenuItem(
                      value: 'minimal',
                      child: Text('Minimal workspace'),
                    ),
                    CheckedPopupMenuItem(
                      value: 'follow',
                      checked: followDocumentType,
                      child: const Text('Follow document type'),
                    ),
                  ];
                  if (customWorkspaces.isNotEmpty) {
                    entries.add(const PopupMenuDivider());
                    for (final layout in customWorkspaces) {
                      entries.add(
                        PopupMenuItem(
                          value: layout.id,
                          child: Text(layout.name),
                        ),
                      );
                      entries.add(
                        PopupMenuItem(
                          value: 'rename:${layout.id}',
                          child: Text('Rename “${layout.name}”…'),
                        ),
                      );
                      entries.add(
                        PopupMenuItem(
                          value: 'delete:${layout.id}',
                          child: Text('Delete “${layout.name}”…'),
                        ),
                      );
                    }
                  }
                  entries.add(const PopupMenuDivider());
                  if (const {
                    'illustration',
                    'comic',
                    'minimal',
                  }.contains(workspaceId)) {
                    entries.add(
                      const PopupMenuItem(
                        value: 'resetCurrent',
                        child: Text('Reset current workspace layout…'),
                      ),
                    );
                  }
                  entries.add(
                    const PopupMenuItem(
                      value: 'saveAs',
                      child: Text('Save current workspace as…'),
                    ),
                  );
                  entries.add(
                    const PopupMenuItem(
                      value: 'customize',
                      child: Text('Customize command bar…'),
                    ),
                  );
                  return entries;
                },
                child: Tooltip(
                  message:
                      'Workspace: ${workspaceId == 'comic'
                          ? 'Comic'
                          : workspaceId == 'minimal'
                          ? 'Minimal'
                          : 'Illustration'}',
                  child: const SizedBox(
                    width: 32,
                    child: Icon(Icons.dashboard_customize_outlined, size: 18),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              if (!nativeMenuBar) ...[
                if (professionalDesktop && !compactDesktop)
                  for (final menu in const [
                    'File',
                    'Edit',
                    'View',
                    'Layer',
                    'Select',
                    'Tool',
                    'Window',
                    'Help',
                  ]) ...[
                    EditorActionMenu(
                      label: menu,
                      actions: EditorActionId.values
                          .where(
                            (action) =>
                                action.category == menu ||
                                (menu == 'Tool' && action.category == 'Color'),
                          )
                          .toList(growable: false),
                      disabledActions:
                          documentActionsEnabled && !documentActionRunning
                              ? const {}
                              : {
                                if (!documentActionsEnabled) ...{
                                  EditorActionId.openProject,
                                  EditorActionId.importPsd,
                                  EditorActionId.saveProject,
                                  EditorActionId.saveProjectAs,
                                  EditorActionId.exportPng,
                                },
                                if (documentActionRunning)
                                  EditorActionId.newDocument,
                              },
                      onAction: onActionDispatch,
                    ),
                    const SizedBox(width: 4),
                  ]
                else
                  EditorActionMenu(
                    label: 'Menu',
                    icon: Icons.menu,
                    actions: EditorActionId.values,
                    onAction: onActionDispatch,
                  ),
                const VerticalDivider(width: 8, indent: 7, endIndent: 7),
              ],
              if (compactDesktop) ...[
                for (final item in commandBarItems)
                  if (compactVisibleCommands.contains(item))
                    _commandBarButton(item),
                _commandOverflowMenu(context, compactVisibleCommands),
              ] else
                for (final item in commandBarItems)
                  if (item == 'separator')
                    const VerticalDivider(width: 12, indent: 7, endIndent: 7)
                  else
                    _commandBarButton(item),
              InkCommandButton(
                icon: Icons.touch_app,
                label: 'Gesture settings',
                onPressed: onGestureSettings,
                hitSize: tabletStudioMode ? 48 : 32,
              ),
              InkCommandButton(
                icon: Icons.accessibility_new,
                label: 'Accessibility settings',
                onPressed: onAccessibilitySettings,
                hitSize: tabletStudioMode ? 48 : 32,
              ),
              if (contextControls != null && availableWidth >= 1600) ...[
                const VerticalDivider(width: 12, indent: 7, endIndent: 7),
                contextControls!,
              ],
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _commandOverflowMenu(
    BuildContext context,
    Set<String> excludedCommands,
  ) => Semantics(
    identifier: 'more-commands',
    child: PopupMenuButton<EditorActionId>(
      tooltip: 'More commands',
      onSelected: onActionDispatch,
      itemBuilder:
          (_) => [
            for (final name in commandBarItems)
              if (name != 'separator' && !excludedCommands.contains(name))
                for (final action in EditorActionId.values.where(
                  (candidate) => candidate.name == name,
                ))
                  PopupMenuItem(
                    value: action,
                    enabled: !_isDocumentActionDisabled(action),
                    child: Text(
                      _commandBarLabel(action),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
          ],
      child: const SizedBox(
        width: 48,
        height: 36,
        child: Icon(Icons.more_horiz, size: 20),
      ),
    ),
  );

  Widget _commandBarButton(String name) {
    final action =
        EditorActionId.values
            .where((candidate) => candidate.name == name)
            .firstOrNull;
    if (action == null) return const SizedBox.shrink();
    final disabled = _isDocumentActionDisabled(action);
    final toolbarLabel = _commandBarLabel(action);
    final label = [
      toolbarLabel,
      if (action.shortcut != null) action.shortcut!,
    ].join('  •  ');
    return InkCommandButton(
      icon: commandBarIcon(action),
      label: label,
      selected: action == EditorActionId.mirrorCanvas && mirrored,
      onPressed: disabled ? null : () => onActionDispatch(action),
      hitSize: tabletStudioMode ? 48 : 32,
    );
  }

  String _commandBarLabel(EditorActionId action) => switch (action) {
    EditorActionId.showColorPicker => 'Color',
    EditorActionId.showBrushes => 'Brush library',
    EditorActionId.showComics => 'Comic workspace',
    _ => action.label,
  };

  Widget _buildTabletTopBar(BuildContext context) {
    final status =
        '$documentName  •  $activeToolLabel  •  $activeBrushLabel  •  $saveStatusLabel';
    return SafeArea(
      bottom: false,
      child: Container(
        height: 52,
        decoration: BoxDecoration(
          color: inkColors(context).panel,
          border: Border(
            bottom: BorderSide(color: inkColors(context).panelBorder),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Tooltip(
                message: status,
                child: Text(
                  status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
            ),
            if (documentActionsEnabled)
              InkCommandButton(
                icon: Icons.save_outlined,
                label: 'Save project',
                identifier: 'save-project',
                onPressed:
                    _isDocumentActionDisabled(EditorActionId.saveProject)
                        ? null
                        : onSave,
                hitSize: 48,
              ),
            InkCommandButton(
              icon: Icons.undo,
              label: 'Undo',
              identifier: 'undo',
              onPressed: onUndo,
              hitSize: 48,
            ),
            InkCommandButton(
              icon: Icons.redo,
              label: 'Redo',
              identifier: 'redo',
              onPressed: onRedo,
              hitSize: 48,
            ),
            InkCommandButton(
              icon: Icons.fullscreen,
              label: 'Canvas Focus',
              onPressed: onToggleFocus,
              hitSize: 48,
            ),
            _tabletModeMenu(context),
            _tabletMoreMenu(context),
          ],
        ),
      ),
    );
  }

  Widget _tabletModeMenu(BuildContext context) {
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final availableWidth = MediaQuery.sizeOf(context).width;
    final modeButtonWidth = math.min(
      math.max(80.0, MediaQuery.textScalerOf(context).scale(52)),
      math.max(80.0, availableWidth - (documentActionsEnabled ? 240 : 192)),
    );
    final compactStudio =
        tabletModePreference == TabletWorkspaceMode.studio && !tabletStudioMode;
    final modeName =
        tabletModePreference == TabletWorkspaceMode.studio
            ? 'Studio'
            : 'Simple';
    final tooltip =
        compactStudio
            ? 'Studio mode selected. Compact controls are shown at this width.'
            : '$modeName mode selected. Choose Simple or Studio.';
    return PopupMenuButton<TabletWorkspaceMode>(
      tooltip: tooltip,
      onSelected: onTabletModeSelected,
      itemBuilder:
          (_) => [
            CheckedPopupMenuItem(
              value: TabletWorkspaceMode.simple,
              checked: tabletModePreference == TabletWorkspaceMode.simple,
              child: const Text('Simple'),
            ),
            CheckedPopupMenuItem(
              value: TabletWorkspaceMode.studio,
              checked: tabletModePreference == TabletWorkspaceMode.studio,
              child: Text(compactStudio ? 'Studio (compact layout)' : 'Studio'),
            ),
          ],
      child: Semantics(
        label: tooltip,
        child: ExcludeSemantics(
          child: SizedBox(
            width: modeButtonWidth,
            height: 48,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: Text(
                    modeName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
                if (availableWidth >= 600 && textScale <= 1.4)
                  const Icon(Icons.arrow_drop_down, size: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _tabletMoreMenu(BuildContext context) => PopupMenuButton<String>(
    tooltip: 'More actions and workspace settings',
    onSelected: (value) {
      if (value.startsWith('workspace:')) {
        onWorkspaceSelected(value.substring('workspace:'.length));
        return;
      }
      if (value.startsWith('rename:')) {
        onRenameWorkspace(value.substring('rename:'.length));
        return;
      }
      if (value.startsWith('delete:')) {
        onDeleteWorkspace(value.substring('delete:'.length));
        return;
      }
      switch (value) {
        case 'open':
          onOpen();
        case 'import':
          onActionDispatch(EditorActionId.importPsd);
        case 'new':
          onActionDispatch(EditorActionId.newDocument);
        case 'saveAs':
          onActionDispatch(EditorActionId.saveProjectAs);
        case 'export':
          onExportMenu();
        case 'comics':
          onComics();
        case 'search':
          onCommandSearch();
        case 'gesture':
          onGestureSettings();
        case 'accessibility':
          onAccessibilitySettings();
        case 'follow':
          onFollowDocumentTypeChanged(!followDocumentType);
        case 'resetCurrent':
          onResetWorkspace(workspaceId);
        case 'saveWorkspace':
          onSaveWorkspaceAs();
        case 'customize':
          onCustomizeCommandBar();
      }
    },
    itemBuilder: (_) {
      final entries = <PopupMenuEntry<String>>[
        PopupMenuItem(
          value: 'new',
          enabled: !_isDocumentActionDisabled(EditorActionId.newDocument),
          child: const Text('New canvas'),
        ),
        PopupMenuItem(
          value: 'open',
          enabled: !_isDocumentActionDisabled(EditorActionId.openProject),
          child: const Text('Open project…'),
        ),
        PopupMenuItem(
          value: 'import',
          enabled: !_isDocumentActionDisabled(EditorActionId.importPsd),
          child: const Text('Import Photoshop document…'),
        ),
        PopupMenuItem(
          value: 'saveAs',
          enabled: !_isDocumentActionDisabled(EditorActionId.saveProjectAs),
          child: const Text('Save project as…'),
        ),
        PopupMenuItem(
          value: 'export',
          enabled: !_isDocumentActionDisabled(EditorActionId.exportPng),
          child: const Text('Export…'),
        ),
        const PopupMenuItem(value: 'comics', child: Text('Comics workspace')),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(enabled: false, child: Text('Workspace')),
        for (final layout in const [
          ('illustration', 'Illustration'),
          ('comic', 'Comic'),
          ('minimal', 'Minimal'),
        ])
          CheckedPopupMenuItem<String>(
            value: 'workspace:${layout.$1}',
            checked: workspaceId == layout.$1,
            child: Text('${layout.$2} workspace'),
          ),
        CheckedPopupMenuItem<String>(
          value: 'follow',
          checked: followDocumentType,
          child: const Text('Follow document type'),
        ),
      ];
      for (final layout in customWorkspaces) {
        entries.add(
          CheckedPopupMenuItem<String>(
            value: 'workspace:${layout.id}',
            checked: workspaceId == layout.id,
            child: Text(layout.name),
          ),
        );
        entries.add(
          PopupMenuItem(
            value: 'rename:${layout.id}',
            child: Text('Rename “${layout.name}”…'),
          ),
        );
        entries.add(
          PopupMenuItem(
            value: 'delete:${layout.id}',
            child: Text('Delete “${layout.name}”…'),
          ),
        );
      }
      if (const {'illustration', 'comic', 'minimal'}.contains(workspaceId)) {
        entries.add(const PopupMenuDivider());
        entries.add(
          const PopupMenuItem(
            value: 'resetCurrent',
            child: Text('Reset workspace layout…'),
          ),
        );
      }
      entries.addAll([
        const PopupMenuItem(
          value: 'saveWorkspace',
          child: Text('Save workspace as…'),
        ),
        const PopupMenuItem(
          value: 'customize',
          child: Text('Customize command bar…'),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'search', child: Text('Search commands')),
        const PopupMenuItem(value: 'gesture', child: Text('Gesture settings')),
        const PopupMenuItem(
          value: 'accessibility',
          child: Text('Accessibility settings'),
        ),
      ]);
      return entries;
    },
    child: const SizedBox(width: 48, height: 48, child: Icon(Icons.more_horiz)),
  );
}
