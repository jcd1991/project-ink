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
    required this.documentActionsEnabled,
    required this.documentActionRunning,
    required this.onOpen,
    required this.onSave,
    required this.onExport,
    required this.onExportMenu,
    this.onExportTimeLapse,
    required this.onGestureSettings,
    required this.onBrushColor,
    required this.onAccessibilitySettings,
    required this.largeControls,
    required this.leftHanded,
    required this.onTools,
    required this.onBrushes,
    required this.onLayers,
    required this.onComics,
    required this.onUndo,
    required this.onRedo,
    required this.onCommandSearch,
    required this.onMirror,
    required this.mirrored,
    required this.tabletSimpleMode,
    required this.tabletStudioMode,
    required this.onToggleTabletMode,
    required this.onToggleFocus,
    required this.onToggleTransparent,
    required this.transparentColorActive,
    this.eraserActive = false,
    required this.onEditSubColor,
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
  final bool documentActionsEnabled;
  final bool documentActionRunning;
  final VoidCallback onOpen;
  final VoidCallback onSave;
  final VoidCallback onExport;
  final VoidCallback onExportMenu;
  final VoidCallback? onExportTimeLapse;
  final VoidCallback onGestureSettings;
  final VoidCallback onBrushColor;
  final VoidCallback onAccessibilitySettings;
  final bool largeControls;
  final bool leftHanded;
  final VoidCallback onTools;
  final VoidCallback onBrushes;
  final VoidCallback onLayers;
  final VoidCallback onComics;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback onCommandSearch;
  final VoidCallback onMirror;
  final bool mirrored;
  final bool tabletSimpleMode;
  final bool tabletStudioMode;
  final VoidCallback onToggleTabletMode;
  final VoidCallback onToggleFocus;
  final VoidCallback onToggleTransparent;
  final bool transparentColorActive;
  final bool eraserActive;
  final VoidCallback onEditSubColor;
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
    if (tabletSimpleMode) return _buildSimple(context);
    // Keep the desktop command bar discoverable in narrow windows. The full
    // palette of commands moves into a labeled menu instead of becoming
    // reachable only by horizontally scrolling tiny icons.
    final availableWidth = MediaQuery.sizeOf(context).width;
    // At standard laptop/desktop sizes keep the active brush controls visible,
    // but move secondary command-bar items into More commands before the
    // contextual controls get clipped by the edge of the viewport.
    final compactDesktop = availableWidth < 1600;
    const compactVisibleCommands = {
      'undo',
      'redo',
      'commandSearch',
      'showBrushes',
      'showLayers',
      'showColorPicker',
    };
    return SafeArea(
      bottom: false,
      child: Container(
        height: tabletStudioMode ? 48 : 36,
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
                tabletStudioMode
                    ? '$documentName  •  $activeToolLabel  •  $activeBrushLabel'
                    : '$documentName  •  Pen',
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
              if (tabletStudioMode) ...[
                InkCommandButton(
                  icon: Icons.fullscreen,
                  label: 'Canvas Focus',
                  onPressed: onToggleFocus,
                  hitSize: 48,
                ),
                InkCommandButton(
                  icon: Icons.view_compact_alt_outlined,
                  label: 'Switch to Simple mode',
                  onPressed: onToggleTabletMode,
                  hitSize: 48,
                ),
                InkCommandButton(
                  icon: Icons.palette_outlined,
                  label: 'Color',
                  onPressed: onBrushColor,
                  hitSize: 48,
                ),
                InkCommandButton(
                  icon: Icons.cleaning_services_outlined,
                  label: eraserActive ? 'Return to brush' : 'Eraser',
                  selected: eraserActive,
                  onPressed:
                      () => onActionDispatch(EditorActionId.toggleEraser),
                  hitSize: 48,
                ),
                InkCommandButton(
                  icon: Icons.circle_outlined,
                  label: 'Edit sub color',
                  onPressed: onEditSubColor,
                  hitSize: 48,
                ),
                InkCommandButton(
                  icon: Icons.layers_clear,
                  label: 'Transparent paint',
                  selected: transparentColorActive,
                  onPressed: onToggleTransparent,
                  hitSize: 48,
                ),
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
              if (contextControls != null && !compactDesktop) ...[
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
        width: 40,
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

  Widget _buildSimple(BuildContext context) => SafeArea(
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
          const SizedBox(width: 6),
          Flexible(
            fit: FlexFit.tight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                '$documentName  •  Pen',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
          ),
          InkCommandButton(
            icon: Icons.folder_open_outlined,
            label: 'Open project',
            identifier: 'open-project',
            onPressed: onOpen,
            hitSize: 48,
          ),
          if (documentActionsEnabled)
            InkCommandButton(
              icon: Icons.save_outlined,
              label: 'Save project',
              identifier: 'save-project',
              onPressed: onSave,
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
          InkCommandButton(
            icon: Icons.palette_outlined,
            label: 'Color',
            onPressed: onBrushColor,
            hitSize: 48,
          ),
          InkCommandButton(
            icon: Icons.view_compact_alt_outlined,
            label: 'Switch to Studio mode',
            onPressed: onToggleTabletMode,
            hitSize: 48,
          ),
          PopupMenuButton<String>(
            tooltip: 'More drawing controls',
            onSelected: (value) {
              switch (value) {
                case 'focus':
                  onToggleFocus();
                case 'mode':
                  onToggleTabletMode();
                case 'tools':
                  onTools();
                case 'brushes':
                  onBrushes();
                case 'layers':
                  onLayers();
                case 'color':
                  onBrushColor();
                case 'subColor':
                  onEditSubColor();
                case 'transparent':
                  onToggleTransparent();
                case 'comics':
                  onComics();
                case 'open':
                  onOpen();
                case 'export':
                  onExportMenu();
                case 'settings':
                  onGestureSettings();
                case 'search':
                  onCommandSearch();
              }
            },
            itemBuilder:
                (_) => [
                  const PopupMenuItem(
                    value: 'focus',
                    child: Text('Canvas Focus'),
                  ),
                  PopupMenuItem(
                    value: 'mode',
                    child: Text(
                      'Switch to ${tabletSimpleMode ? 'Studio' : 'Simple'} mode',
                    ),
                  ),
                  const PopupMenuDivider(),
                  const PopupMenuItem(
                    value: 'tools',
                    child: Text('Tools and selection'),
                  ),
                  const PopupMenuItem(
                    value: 'brushes',
                    child: Text('Brush library'),
                  ),
                  const PopupMenuItem(value: 'layers', child: Text('Layers')),
                  const PopupMenuItem(value: 'color', child: Text('Color')),
                  const PopupMenuItem(
                    value: 'subColor',
                    child: Text('Edit sub color'),
                  ),
                  const PopupMenuItem(
                    value: 'transparent',
                    child: Text('Transparent paint'),
                  ),
                  const PopupMenuItem(
                    value: 'comics',
                    child: Text('Comics and materials'),
                  ),
                  const PopupMenuDivider(),
                  const PopupMenuItem(
                    value: 'export',
                    child: Text('Export image'),
                  ),
                  const PopupMenuItem(
                    value: 'search',
                    child: Text('Search commands'),
                  ),
                  const PopupMenuItem(
                    value: 'settings',
                    child: Text('Gesture settings'),
                  ),
                ],
            child: const SizedBox(
              width: 48,
              height: 48,
              child: Icon(Icons.more_horiz),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
    ),
  );
}
