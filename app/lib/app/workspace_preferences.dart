import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'editor_action.dart';
import 'workspace_mode.dart';

enum TabletWorkspaceMode { simple, studio }

enum WorkspacePresetKind { illustration, comic, minimal, custom }

const defaultCommandBarItems = [
  'undo',
  'redo',
  'separator',
  'commandSearch',
  'mirrorCanvas',
  'showBrushes',
  'showLayers',
  'showComics',
  'showColorPicker',
  'separator',
  'newDocument',
  'openProject',
  'saveProject',
  'saveProjectAs',
  'exportPng',
];

List<String>? _validatedCommandBarItems(Object? rawItems) {
  if (rawItems is! List || rawItems.length > 48) return null;
  final validActions =
      EditorActionId.values.map((action) => action.name).toSet();
  final items = <String>[];
  for (final item in rawItems) {
    if (item is! String ||
        (item != 'separator' && !validActions.contains(item)) ||
        (item == 'separator' && (items.isEmpty || items.last == 'separator'))) {
      return null;
    }
    items.add(item);
  }
  if (items.lastOrNull == 'separator') return null;
  return items;
}

enum InkPaletteId {
  toolGroups,
  brushPresets,
  toolProperties,
  color,
  layers,
  materials,
  comics,
  history,
  quickAccess,
}

class DockGroupLayout {
  const DockGroupLayout({this.flex = 1, this.tabs = const [], this.activeTab});

  final double flex;
  final List<InkPaletteId> tabs;
  final InkPaletteId? activeTab;

  Map<String, Object?> toJson() => {
    'flex': flex,
    'tabs': tabs.map((tab) => tab.name).toList(growable: false),
    'active': activeTab?.name,
  };

  static DockGroupLayout? fromJson(Object? value) {
    if (value is! Map) return null;
    final flex = value['flex'];
    final tabsValue = value['tabs'];
    if (flex is! num ||
        !flex.isFinite ||
        tabsValue is! List ||
        tabsValue.isEmpty ||
        tabsValue.length > 8) {
      return null;
    }
    final tabs = <InkPaletteId>[];
    for (final item in tabsValue) {
      if (item is! String) return null;
      final tab =
          InkPaletteId.values
              .where((candidate) => candidate.name == item)
              .firstOrNull;
      if (tab == null || tabs.contains(tab)) return null;
      tabs.add(tab);
    }
    final activeName = value['active'];
    final active =
        activeName is String
            ? InkPaletteId.values
                .where((tab) => tab.name == activeName)
                .firstOrNull
            : null;
    if (activeName != null && (active == null || !tabs.contains(active))) {
      return null;
    }
    return DockGroupLayout(
      flex: flex.toDouble().clamp(0.15, 20),
      tabs: tabs,
      activeTab: active ?? tabs.first,
    );
  }
}

class DockColumnLayout {
  const DockColumnLayout({
    required this.width,
    this.collapsed = false,
    this.groups = const [],
  });

  final double width;
  final bool collapsed;
  final List<DockGroupLayout> groups;

  Map<String, Object?> toJson() => {
    'width': width,
    'collapsed': collapsed,
    'groups': groups.map((group) => group.toJson()).toList(growable: false),
  };

  static DockColumnLayout? fromJson(Object? value) {
    if (value is! Map) return null;
    final width = value['width'];
    final groupValues = value['groups'];
    if (width is! num ||
        !width.isFinite ||
        groupValues is! List ||
        groupValues.length > 3) {
      return null;
    }
    if (groupValues.any((group) => DockGroupLayout.fromJson(group) == null)) {
      return null;
    }
    final groups = groupValues
        .map(DockGroupLayout.fromJson)
        .whereType<DockGroupLayout>()
        .toList(growable: false);
    return DockColumnLayout(
      width: width.toDouble().clamp(220, 480),
      collapsed: value['collapsed'] == true,
      groups: groups,
    );
  }
}

class WorkspaceLayout {
  const WorkspaceLayout({
    required this.id,
    required this.name,
    required this.kind,
    this.left,
    this.right,
    this.commandBar = const [],
  });

  final String id;
  final String name;
  final WorkspacePresetKind kind;
  final DockColumnLayout? left;
  final DockColumnLayout? right;
  final List<String> commandBar;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'left': left?.toJson(),
    'right': right?.toJson(),
    'command_bar': commandBar.take(48).toList(growable: false),
  };

  static WorkspaceLayout? fromJson(Object? value) {
    if (value is! Map || value.length > 16) return null;
    final id = value['id'];
    final name = value['name'];
    final kindName = value['kind'];
    final rawItems = value['command_bar'];
    if (id is! String ||
        id.isEmpty ||
        id.length > 64 ||
        name is! String ||
        name.trim().isEmpty ||
        name.trim().length > 64 ||
        kindName is! String ||
        rawItems is! List) {
      return null;
    }
    final kind =
        WorkspacePresetKind.values
            .where((item) => item.name == kindName)
            .firstOrNull;
    if (kind == null) return null;
    final left = DockColumnLayout.fromJson(value['left']);
    final right = DockColumnLayout.fromJson(value['right']);
    if ((value['left'] != null && left == null) ||
        (value['right'] != null && right == null)) {
      return null;
    }
    final commandBar = _validatedCommandBarItems(rawItems);
    if (commandBar == null) return null;
    return WorkspaceLayout(
      id: id,
      name: name.trim(),
      kind: kind,
      left: left,
      right: right,
      commandBar: commandBar,
    );
  }
}

class QuickAccessSet {
  const QuickAccessSet({
    required this.id,
    required this.name,
    required this.actions,
  });

  final String id;
  final String name;
  final List<EditorActionId> actions;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'actions': actions.take(32).map((action) => action.name).toList(),
  };

  static QuickAccessSet? fromJson(Object? value) {
    if (value is! Map || value.length > 4) return null;
    final id = value['id'];
    final name = value['name'];
    final rawActions = value['actions'];
    if (id is! String ||
        id.isEmpty ||
        id.length > 64 ||
        name is! String ||
        name.trim().isEmpty ||
        name.trim().length > 64 ||
        rawActions is! List ||
        rawActions.length > 32) {
      return null;
    }
    final actions = rawActions
        .whereType<String>()
        .map(
          (value) =>
              EditorActionId.values
                  .where((action) => action.name == value)
                  .firstOrNull,
        )
        .whereType<EditorActionId>()
        .toSet()
        .toList(growable: false);
    if (actions.isEmpty) return null;
    return QuickAccessSet(id: id, name: name.trim(), actions: actions);
  }
}

const defaultQuickAccessSets = <QuickAccessSet>[
  QuickAccessSet(
    id: 'default',
    name: 'Default',
    actions: [
      EditorActionId.undo,
      EditorActionId.redo,
      EditorActionId.fitCanvas,
      EditorActionId.toggleEraser,
      EditorActionId.showBrushes,
      EditorActionId.showLayers,
      EditorActionId.showColorPicker,
      EditorActionId.eyedropper,
    ],
  ),
];

WorkspaceLayout get illustrationWorkspace => const WorkspaceLayout(
  id: 'illustration',
  name: 'Illustration',
  kind: WorkspacePresetKind.illustration,
  left: DockColumnLayout(
    width: 248,
    groups: [
      DockGroupLayout(
        flex: 1,
        tabs: [InkPaletteId.toolGroups, InkPaletteId.brushPresets],
        activeTab: InkPaletteId.toolGroups,
      ),
      DockGroupLayout(
        flex: 1,
        tabs: [InkPaletteId.color, InkPaletteId.quickAccess],
        activeTab: InkPaletteId.color,
      ),
    ],
  ),
  right: DockColumnLayout(
    width: 360,
    groups: [
      DockGroupLayout(
        flex: 1,
        tabs: [InkPaletteId.toolProperties, InkPaletteId.history],
        activeTab: InkPaletteId.toolProperties,
      ),
      DockGroupLayout(
        flex: 1,
        tabs: [InkPaletteId.layers, InkPaletteId.materials],
        activeTab: InkPaletteId.layers,
      ),
    ],
  ),
);

WorkspaceLayout get comicWorkspace => const WorkspaceLayout(
  id: 'comic',
  name: 'Comic',
  kind: WorkspacePresetKind.comic,
  left: DockColumnLayout(
    width: 248,
    groups: [
      DockGroupLayout(
        flex: 1,
        tabs: [InkPaletteId.toolGroups, InkPaletteId.brushPresets],
        activeTab: InkPaletteId.toolGroups,
      ),
      DockGroupLayout(
        flex: 1,
        tabs: [InkPaletteId.color, InkPaletteId.quickAccess],
        activeTab: InkPaletteId.color,
      ),
    ],
  ),
  right: DockColumnLayout(
    width: 400,
    groups: [
      DockGroupLayout(
        flex: 1,
        tabs: [
          InkPaletteId.comics,
          InkPaletteId.layers,
          InkPaletteId.toolProperties,
        ],
        activeTab: InkPaletteId.comics,
      ),
    ],
  ),
);

const minimalWorkspace = WorkspaceLayout(
  id: 'minimal',
  name: 'Minimal',
  kind: WorkspacePresetKind.minimal,
);

/// Versioned, device-local settings. None of these values are part of a document.
class WorkspacePreferences {
  const WorkspacePreferences({
    this.modeOverride,
    this.tabletMode = TabletWorkspaceMode.simple,
    this.leftHanded = false,
    this.theme = 'dark',
    this.dockWidth = 360,
    this.leftDockWidth = 248,
    this.visiblePanels = const [
      'tools',
      'brushes',
      'layers',
      'properties',
      'materials',
      'comics',
    ],
    this.lastDock = 'layers',
    this.workspaceId = 'illustration',
    this.followDocumentType = true,
    this.customWorkspaces = const [],
    this.quickAccessSets = defaultQuickAccessSets,
    this.activeQuickAccessSetId = 'default',
    this.recentColors = const [],
    this.activeColorArgb,
    this.subColorArgb,
    this.commandBarOverrides = const {},
    this.workspaceOverrides = const {},
  });

  final WorkspaceMode? modeOverride;
  final TabletWorkspaceMode tabletMode;
  final bool leftHanded;
  final String theme;
  final double dockWidth;
  final double leftDockWidth;
  final List<String> visiblePanels;
  final String lastDock;
  final String workspaceId;
  final bool followDocumentType;
  final List<WorkspaceLayout> customWorkspaces;
  final List<QuickAccessSet> quickAccessSets;
  final String activeQuickAccessSetId;
  final List<String> recentColors;
  final int? activeColorArgb;
  final int? subColorArgb;
  final Map<String, List<String>> commandBarOverrides;
  final Map<String, WorkspaceLayout> workspaceOverrides;

  WorkspacePreferences copyWith({
    WorkspaceMode? modeOverride,
    bool clearModeOverride = false,
    TabletWorkspaceMode? tabletMode,
    bool? leftHanded,
    String? theme,
    double? dockWidth,
    double? leftDockWidth,
    List<String>? visiblePanels,
    String? lastDock,
    String? workspaceId,
    bool? followDocumentType,
    List<WorkspaceLayout>? customWorkspaces,
    List<QuickAccessSet>? quickAccessSets,
    String? activeQuickAccessSetId,
    List<String>? recentColors,
    int? activeColorArgb,
    int? subColorArgb,
    Map<String, List<String>>? commandBarOverrides,
    Map<String, WorkspaceLayout>? workspaceOverrides,
  }) => WorkspacePreferences(
    modeOverride:
        clearModeOverride ? null : (modeOverride ?? this.modeOverride),
    tabletMode: tabletMode ?? this.tabletMode,
    leftHanded: leftHanded ?? this.leftHanded,
    theme: theme ?? this.theme,
    dockWidth: dockWidth ?? this.dockWidth,
    leftDockWidth: leftDockWidth ?? this.leftDockWidth,
    visiblePanels: visiblePanels ?? this.visiblePanels,
    lastDock: lastDock ?? this.lastDock,
    workspaceId: workspaceId ?? this.workspaceId,
    followDocumentType: followDocumentType ?? this.followDocumentType,
    customWorkspaces: customWorkspaces ?? this.customWorkspaces,
    quickAccessSets: quickAccessSets ?? this.quickAccessSets,
    activeQuickAccessSetId:
        activeQuickAccessSetId ?? this.activeQuickAccessSetId,
    recentColors: recentColors ?? this.recentColors,
    activeColorArgb: activeColorArgb ?? this.activeColorArgb,
    subColorArgb: subColorArgb ?? this.subColorArgb,
    commandBarOverrides: commandBarOverrides ?? this.commandBarOverrides,
    workspaceOverrides: workspaceOverrides ?? this.workspaceOverrides,
  );

  static const _version = 2;

  Map<String, Object?> toJson() => {
    'version': _version,
    'mode_override': modeOverride?.name,
    'tablet_mode': tabletMode.name,
    'left_handed': leftHanded,
    'theme': theme,
    'dock_width': dockWidth,
    'left_dock_width': leftDockWidth,
    'visible_panels': visiblePanels,
    'last_dock': lastDock,
    'workspace_id': workspaceId,
    'follow_document_type': followDocumentType,
    'custom_workspaces': customWorkspaces
        .take(12)
        .map((layout) => layout.toJson())
        .toList(growable: false),
    'quick_access_sets': quickAccessSets
        .take(8)
        .map((set) => set.toJson())
        .toList(growable: false),
    'active_quick_access_set': activeQuickAccessSetId,
    'recent_colors': recentColors.take(24).toList(growable: false),
    if (activeColorArgb != null) 'active_color_argb': activeColorArgb,
    if (subColorArgb != null) 'sub_color_argb': subColorArgb,
    'command_bar_overrides': {
      for (final entry in commandBarOverrides.entries.take(3))
        entry.key: entry.value.take(48).toList(growable: false),
    },
    'workspace_overrides': {
      for (final entry in workspaceOverrides.entries.take(3))
        entry.key: entry.value.toJson(),
    },
  };

  static WorkspacePreferences fromJson(Object? value) {
    if (value is! Map || value.length > 32) return const WorkspacePreferences();
    T? enumValue<T extends Enum>(List<T> values, Object? name) =>
        name is String
            ? values.where((item) => item.name == name).firstOrNull
            : null;
    final mode = enumValue(WorkspaceMode.values, value['mode_override']);
    final tabletMode =
        enumValue(TabletWorkspaceMode.values, value['tablet_mode']) ??
        TabletWorkspaceMode.simple;
    final theme = value['theme'];
    final width = value['dock_width'];
    final leftWidth = value['left_dock_width'];
    final rawPanels = value['visible_panels'];
    final allowedPanels = {
      'tools',
      'brushes',
      'layers',
      'properties',
      'materials',
      'comics',
      'history',
      'quickAccess',
      'color',
    };
    final panels =
        rawPanels is List
            ? rawPanels
                .whereType<String>()
                .where(allowedPanels.contains)
                .take(9)
                .toList(growable: false)
            : const <String>[];
    final last = value['last_dock'];
    final customRaw = value['custom_workspaces'];
    if (customRaw is List && customRaw.length > 12) {
      return const WorkspacePreferences();
    }
    final custom =
        customRaw is List
            ? customRaw
                .map(WorkspaceLayout.fromJson)
                .whereType<WorkspaceLayout>()
                .where((layout) => layout.kind == WorkspacePresetKind.custom)
                .take(12)
                .toList(growable: false)
            : const <WorkspaceLayout>[];
    if (customRaw is List &&
        (custom.length != customRaw.length ||
            custom.map((layout) => layout.id).toSet().length !=
                custom.length)) {
      return const WorkspacePreferences();
    }
    final selected = value['workspace_id'];
    final rawQuickSets = value['quick_access_sets'];
    if (rawQuickSets is List && rawQuickSets.length > 8) {
      return const WorkspacePreferences();
    }
    final quickSets =
        rawQuickSets is List
            ? rawQuickSets
                .map(QuickAccessSet.fromJson)
                .whereType<QuickAccessSet>()
                .take(8)
                .toList(growable: false)
            : defaultQuickAccessSets;
    final safeQuickSets =
        quickSets.isEmpty ? defaultQuickAccessSets : quickSets;
    if (rawQuickSets is List &&
        (quickSets.length != rawQuickSets.length ||
            quickSets.map((set) => set.id).toSet().length !=
                quickSets.length)) {
      return const WorkspacePreferences();
    }
    final activeQuickSet = value['active_quick_access_set'];
    final rawRecentColors = value['recent_colors'];
    if (rawRecentColors is List && rawRecentColors.length > 24) {
      return const WorkspacePreferences();
    }
    final recentColors =
        rawRecentColors is List
            ? rawRecentColors
                .whereType<String>()
                .where((color) => RegExp(r'^#[0-9a-fA-F]{8}$').hasMatch(color))
                .map((color) => color.toUpperCase())
                .toSet()
                .take(24)
                .toList(growable: false)
            : const <String>[];
    const builtInWorkspaceIds = {'illustration', 'comic', 'minimal'};
    final rawCommandBars = value['command_bar_overrides'];
    if (rawCommandBars != null &&
        (rawCommandBars is! Map || rawCommandBars.length > 3)) {
      return const WorkspacePreferences();
    }
    final commandBarOverrides = <String, List<String>>{};
    if (rawCommandBars is Map) {
      for (final entry in rawCommandBars.entries) {
        if (entry.key is! String || !builtInWorkspaceIds.contains(entry.key)) {
          return const WorkspacePreferences();
        }
        final items = _validatedCommandBarItems(entry.value);
        if (items == null || items.isEmpty) {
          return const WorkspacePreferences();
        }
        commandBarOverrides[entry.key as String] = items;
      }
    }
    const builtInKinds = {
      'illustration': WorkspacePresetKind.illustration,
      'comic': WorkspacePresetKind.comic,
      'minimal': WorkspacePresetKind.minimal,
    };
    final rawWorkspaceOverrides = value['workspace_overrides'];
    if (rawWorkspaceOverrides != null &&
        (rawWorkspaceOverrides is! Map || rawWorkspaceOverrides.length > 3)) {
      return const WorkspacePreferences();
    }
    final workspaceOverrides = <String, WorkspaceLayout>{};
    if (rawWorkspaceOverrides is Map) {
      for (final entry in rawWorkspaceOverrides.entries) {
        if (entry.key is! String ||
            !builtInKinds.containsKey(entry.key as String)) {
          return const WorkspacePreferences();
        }
        final layout = WorkspaceLayout.fromJson(entry.value);
        final id = entry.key as String;
        if (layout == null ||
            layout.id != id ||
            layout.kind != builtInKinds[id]) {
          return const WorkspacePreferences();
        }
        workspaceOverrides[id] = layout;
      }
    }
    final quickSetIds = safeQuickSets.map((set) => set.id).toSet();
    final validIds = {
      'illustration',
      'comic',
      'minimal',
      ...custom.map((layout) => layout.id),
    };
    return WorkspacePreferences(
      modeOverride: mode,
      tabletMode: tabletMode,
      leftHanded: value['left_handed'] == true,
      theme:
          theme is String && {'system', 'light', 'dark'}.contains(theme)
              ? theme
              : 'dark',
      dockWidth:
          width is num && width.isFinite
              ? width.toDouble().clamp(220, 480)
              : 360,
      leftDockWidth:
          leftWidth is num && leftWidth.isFinite
              ? leftWidth.toDouble().clamp(220, 480)
              : 248,
      visiblePanels:
          panels.isEmpty
              ? const [
                'tools',
                'brushes',
                'layers',
                'properties',
                'materials',
                'comics',
              ]
              : panels,
      lastDock:
          last is String && allowedPanels.contains(last) ? last : 'layers',
      workspaceId:
          selected is String && validIds.contains(selected)
              ? selected
              : 'illustration',
      followDocumentType: value['follow_document_type'] != false,
      customWorkspaces: custom,
      quickAccessSets: safeQuickSets,
      activeQuickAccessSetId:
          activeQuickSet is String && quickSetIds.contains(activeQuickSet)
              ? activeQuickSet
              : safeQuickSets.first.id,
      recentColors: recentColors,
      activeColorArgb: _validatedArgb(value['active_color_argb']),
      subColorArgb: _validatedArgb(value['sub_color_argb']),
      commandBarOverrides: commandBarOverrides,
      workspaceOverrides: workspaceOverrides,
    );
  }
}

int? _validatedArgb(Object? value) =>
    value is int && value >= 0 && value <= 0xffffffff ? value : null;

class WorkspacePreferencesStore {
  const WorkspacePreferencesStore();

  static const _versionKey = 'project_ink.workspace.version';
  static const _valueKey = 'project_ink.workspace.v2';
  static const _stageKey = 'project_ink.workspace.v2.staged';
  static const _legacyKeys = <String>{
    _versionKey,
    'project_ink.workspace.mode',
    'project_ink.workspace.left_handed',
    'project_ink.workspace.theme',
    'project_ink.workspace.dock_width',
    'project_ink.workspace.visible_panels',
    'project_ink.workspace.last_dock',
  };

  Future<WorkspacePreferences> load() async {
    try {
      final store = SharedPreferencesAsync();
      final version = await store.getInt(_versionKey);
      final encoded = await store.getString(_valueKey);
      if (version == 2 && encoded != null && encoded.length <= 65536) {
        return WorkspacePreferences.fromJson(jsonDecode(encoded));
      }
      final legacy = await store.getAll(allowList: _legacyKeys);
      if (legacy[_versionKey] == 1) {
        final migrated = WorkspacePreferences.fromJson({
          'mode_override': legacy['project_ink.workspace.mode'],
          'left_handed': legacy['project_ink.workspace.left_handed'],
          'theme': legacy['project_ink.workspace.theme'],
          'dock_width': legacy['project_ink.workspace.dock_width'],
          'visible_panels': legacy['project_ink.workspace.visible_panels'],
          'last_dock': legacy['project_ink.workspace.last_dock'],
        });
        await save(migrated);
        return migrated;
      }
      return const WorkspacePreferences();
    } catch (_) {
      return const WorkspacePreferences();
    }
  }

  Future<void> save(WorkspacePreferences preferences) async {
    final safe = WorkspacePreferences.fromJson(preferences.toJson());
    final encoded = jsonEncode(safe.toJson());
    if (encoded.length > 65536) {
      throw ArgumentError('Workspace settings exceed the size limit.');
    }
    final store = SharedPreferencesAsync();
    await store.setInt(_versionKey, 0);
    await store.setString(_stageKey, encoded);
    await store.setString(_valueKey, encoded);
    await store.setInt(_versionKey, 2);
    await store.remove(_stageKey);
  }
}
