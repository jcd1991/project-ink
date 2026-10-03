import 'package:flutter/foundation.dart';

import '../app/workspace_preferences.dart';
import 'canvas_workspace_panel_selection.dart';

@immutable
class WorkspaceDockSelection {
  const WorkspaceDockSelection({
    required this.rightCollapsed,
    required this.leftCollapsed,
    required this.rightWidth,
    required this.leftWidth,
    required this.rightTab,
    required this.leftTab,
    required this.rightGroups,
    required this.leftGroups,
  });

  final bool rightCollapsed;
  final bool leftCollapsed;
  final double rightWidth;
  final double leftWidth;
  final String rightTab;
  final String leftTab;
  final List<DockGroupLayout> rightGroups;
  final List<DockGroupLayout> leftGroups;
}

/// Preferences boundary used by [CanvasWorkspaceLayoutActions].
class CanvasWorkspaceLayoutHost {
  const CanvasWorkspaceLayoutHost({
    required this.preferences,
    required this.onPreferencesChanged,
  });

  final WorkspacePreferences Function() preferences;
  final ValueChanged<WorkspacePreferences>? Function() onPreferencesChanged;
}

/// Owns workspace layout decisions and device-local preference updates.
///
/// It does not own the active dock presentation state or editor document.
class CanvasWorkspaceLayoutActions {
  const CanvasWorkspaceLayoutActions(this.host);

  final CanvasWorkspaceLayoutHost host;

  WorkspacePreferences get _preferences => host.preferences();

  void persistPreferences({
    bool? leftHanded,
    String? lastDock,
    double? dockWidth,
    double? leftDockWidth,
    String? workspaceId,
    TabletWorkspaceMode? tabletMode,
    List<WorkspaceLayout>? customWorkspaces,
    bool? followDocumentType,
    List<QuickAccessSet>? quickAccessSets,
    String? activeQuickAccessSetId,
    List<String>? recentColors,
    Map<String, List<String>>? commandBarOverrides,
    Map<String, WorkspaceLayout>? workspaceOverrides,
  }) {
    final callback = host.onPreferencesChanged();
    if (callback == null) return;
    callback(
      _preferences.copyWith(
        leftHanded: leftHanded,
        lastDock: lastDock,
        dockWidth: dockWidth,
        leftDockWidth: leftDockWidth,
        workspaceId: workspaceId,
        tabletMode: tabletMode,
        customWorkspaces: customWorkspaces,
        followDocumentType: followDocumentType,
        quickAccessSets: quickAccessSets,
        activeQuickAccessSetId: activeQuickAccessSetId,
        recentColors: recentColors,
        commandBarOverrides: commandBarOverrides,
        workspaceOverrides: workspaceOverrides,
      ),
    );
  }

  List<String> effectiveCommandBarItems() {
    final preferences = _preferences;
    final layout = layoutFor(preferences.workspaceId);
    if (layout.kind == WorkspacePresetKind.custom &&
        layout.commandBar.isNotEmpty) {
      return layout.commandBar;
    }
    final override = preferences.commandBarOverrides[preferences.workspaceId];
    return override == null || override.isEmpty
        ? defaultCommandBarItems
        : override;
  }

  void persistDockWidth({required bool left, required double width}) {
    final preferences = _preferences;
    final customIndex = preferences.customWorkspaces.indexWhere(
      (layout) => layout.id == preferences.workspaceId,
    );
    if (customIndex < 0) {
      if (const {
        'illustration',
        'comic',
        'minimal',
      }.contains(preferences.workspaceId)) {
        final current = layoutFor(preferences.workspaceId);
        DockColumnLayout? resize(DockColumnLayout? column) =>
            column == null
                ? null
                : DockColumnLayout(
                  width: width,
                  collapsed: column.collapsed,
                  groups: column.groups,
                );
        final updated = WorkspaceLayout(
          id: current.id,
          name: current.name,
          kind: current.kind,
          left: left ? resize(current.left) : current.left,
          right: left ? current.right : resize(current.right),
          commandBar: current.commandBar,
        );
        final overrides = Map<String, WorkspaceLayout>.from(
          preferences.workspaceOverrides,
        )..[preferences.workspaceId] = updated;
        persistPreferences(
          dockWidth: left ? null : width,
          leftDockWidth: left ? width : null,
          workspaceOverrides: overrides,
        );
        return;
      }
      persistPreferences(
        dockWidth: left ? null : width,
        leftDockWidth: left ? width : null,
      );
      return;
    }

    final updated = [...preferences.customWorkspaces];
    final current = updated[customIndex];
    DockColumnLayout? resize(DockColumnLayout? column) =>
        column == null
            ? null
            : DockColumnLayout(
              width: width,
              collapsed: column.collapsed,
              groups: column.groups,
            );
    updated[customIndex] = WorkspaceLayout(
      id: current.id,
      name: current.name,
      kind: current.kind,
      left: left ? resize(current.left) : current.left,
      right: left ? current.right : resize(current.right),
      commandBar: current.commandBar,
    );
    persistPreferences(
      customWorkspaces: updated,
      dockWidth: left ? null : width,
      leftDockWidth: left ? width : null,
    );
  }

  WorkspaceLayout layoutFor(
    String id, [
    List<WorkspaceLayout>? customWorkspaces,
  ]) {
    final preferences = _preferences;
    final override = preferences.workspaceOverrides[id];
    final custom = customWorkspaces ?? preferences.customWorkspaces;
    if (override != null) return override;
    return switch (id) {
      'comic' => comicWorkspace,
      'minimal' => minimalWorkspace,
      'illustration' => illustrationWorkspace,
      _ =>
        custom.where((layout) => layout.id == id).firstOrNull ??
            illustrationWorkspace,
    };
  }

  /// Resolves active dock presentation when switching workspace layouts.
  WorkspaceDockSelection dockSelectionFor(String workspaceId) {
    final preferences = _preferences;
    final layout = layoutFor(workspaceId, preferences.customWorkspaces);
    final custom = preferences.customWorkspaces.any(
      (workspace) => workspace.id == workspaceId,
    );
    final rightWidth =
        custom
            ? layout.right?.width ?? preferences.dockWidth
            : workspaceId == 'comic'
            ? layout.right?.width ?? 400
            : preferences.dockWidth;
    final leftWidth =
        custom
            ? layout.left?.width ?? preferences.leftDockWidth
            : preferences.leftDockWidth;
    return WorkspaceDockSelection(
      rightCollapsed: layout.right?.collapsed ?? layout.right == null,
      leftCollapsed: layout.left?.collapsed ?? layout.left == null,
      rightWidth: rightWidth.clamp(220, 480).toDouble(),
      leftWidth: leftWidth.clamp(220, 480).toDouble(),
      rightTab:
          paletteName(layout.right?.groups.firstOrNull?.activeTab) ?? 'layers',
      leftTab:
          paletteName(layout.left?.groups.firstOrNull?.activeTab) ?? 'tools',
      rightGroups: layout.right?.groups ?? const [],
      leftGroups: layout.left?.groups ?? const [],
    );
  }

  /// Resolves and persists a workspace selection as one preference transition.
  WorkspaceDockSelection selectWorkspace(
    String workspaceId, {
    bool manual = true,
    bool? followDocumentType,
  }) {
    final selection = dockSelectionFor(workspaceId);
    persistPreferences(
      workspaceId: workspaceId,
      lastDock: selection.rightTab,
      followDocumentType:
          manual
              ? false
              : (followDocumentType ?? _preferences.followDocumentType),
    );
    return selection;
  }

  /// Updates document-follow behavior and selects the document's workspace.
  ///
  /// Returns the dock selection to apply when following is enabled. The caller
  /// owns publishing that selection through its widget state lifecycle.
  WorkspaceDockSelection? setFollowDocumentType({
    required bool enabled,
    required String documentWorkspaceId,
  }) {
    persistPreferences(followDocumentType: enabled);
    if (!enabled) return null;
    return selectWorkspace(
      documentWorkspaceId,
      manual: false,
      followDocumentType: true,
    );
  }

  String? paletteName(InkPaletteId? palette) => switch (palette) {
    InkPaletteId.toolGroups => 'tools',
    InkPaletteId.brushPresets => 'brushes',
    InkPaletteId.toolProperties => 'properties',
    InkPaletteId.color => 'color',
    InkPaletteId.layers => 'layers',
    InkPaletteId.materials => 'materials',
    InkPaletteId.comics => 'comics',
    InkPaletteId.history => 'history',
    InkPaletteId.quickAccess => 'quickAccess',
    null => null,
  };

  String paletteLabel(String tab) => switch (tab) {
    'tools' => 'Tool groups',
    'brushes' => 'Brush presets',
    'properties' => 'Tool properties',
    'color' => 'Color',
    'layers' => 'Layers',
    'materials' => 'Materials',
    'comics' => 'Comics',
    'history' => 'History',
    'quickAccess' => 'Quick Access',
    _ => 'Palette',
  };

  InkPaletteId paletteForDockTab(String tab) => canvasPaletteForDockTab(tab);
}
