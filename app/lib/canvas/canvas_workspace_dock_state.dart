import '../app/workspace_preferences.dart';
import 'canvas_workspace_layout_actions.dart';

/// Owns the local desktop-dock projection derived from workspace preferences.
///
/// Rust remains authoritative for document state. This controller contains
/// only device-local dock sizing, grouping, collapse, and handedness state.
class CanvasWorkspaceDockState {
  CanvasWorkspaceDockState(this._layoutActions);

  final CanvasWorkspaceLayoutActions _layoutActions;

  bool leftHandedToolbar = false;
  bool _rightCollapsed = false;
  bool _leftCollapsed = false;
  String _rightTab = 'layers';
  String _leftTab = 'tools';
  List<DockGroupLayout> _leftGroups = const [];
  List<DockGroupLayout> _rightGroups = const [];
  double _rightWidth = 340;
  double _leftWidth = 248;

  bool get rightCollapsed => _rightCollapsed;
  bool get leftCollapsed => _leftCollapsed;
  String get rightTab => _rightTab;
  String get leftTab => _leftTab;
  List<DockGroupLayout> get leftGroups => _leftGroups;
  List<DockGroupLayout> get rightGroups => _rightGroups;
  double get rightWidth => _rightWidth;
  double get leftWidth => _leftWidth;

  List<DockGroupLayout> groups({required bool left}) =>
      left ? _leftGroups : _rightGroups;

  String tab({required bool left}) => left ? _leftTab : _rightTab;

  double width({required bool left}) => left ? _leftWidth : _rightWidth;

  bool collapsed({required bool left}) =>
      left ? _leftCollapsed : _rightCollapsed;

  void setWidth({required bool left, required double width}) {
    if (left) {
      _leftWidth = width;
    } else {
      _rightWidth = width;
    }
  }

  void setCollapsed({required bool left, required bool collapsed}) {
    if (left) {
      _leftCollapsed = collapsed;
    } else {
      _rightCollapsed = collapsed;
    }
  }

  void setGroups({required bool left, required List<DockGroupLayout> groups}) {
    if (left) {
      _leftGroups = groups;
    } else {
      _rightGroups = groups;
    }
  }

  void setTab({required bool left, required String tab}) {
    if (left) {
      _leftTab = tab;
    } else {
      _rightTab = tab;
    }
  }

  /// Loads the first local dock presentation for a canvas route.
  void initialize({
    required WorkspacePreferences? preferences,
    required double fallbackRightWidth,
  }) {
    final workspaceId = preferences?.workspaceId ?? 'illustration';
    final customWorkspaces =
        preferences?.customWorkspaces ?? const <WorkspaceLayout>[];
    final layout = _layoutActions.layoutFor(workspaceId, customWorkspaces);
    final isCustomWorkspace =
        preferences?.customWorkspaces.any(
          (workspace) => workspace.id == preferences.workspaceId,
        ) ??
        false;

    _rightWidth =
        (isCustomWorkspace || preferences?.workspaceId == 'comic'
            ? layout.right?.width
            : preferences?.dockWidth) ??
        fallbackRightWidth.clamp(220.0, 480.0).toDouble();
    _leftWidth =
        (isCustomWorkspace
                ? layout.left?.width
                : preferences?.leftDockWidth ?? layout.left?.width ?? 248)
            ?.clamp(220, 480)
            .toDouble() ??
        248;
    _rightCollapsed = layout.right?.collapsed ?? layout.right == null;
    _leftCollapsed = layout.left?.collapsed ?? layout.left == null;
    leftHandedToolbar = preferences?.leftHanded ?? false;
    _rightTab =
        preferences?.lastDock ??
        _layoutActions.paletteName(
          layout.right?.groups.firstOrNull?.activeTab,
        ) ??
        'layers';
    _leftTab =
        _layoutActions.paletteName(
          layout.left?.groups.firstOrNull?.activeTab,
        ) ??
        'tools';
    _leftGroups = layout.left?.groups ?? const [];
    _rightGroups = layout.right?.groups ?? const [];
  }

  /// Applies the same preference-change rules previously owned by the route.
  void updatePreferences({
    required WorkspacePreferences? previous,
    required WorkspacePreferences? current,
  }) {
    if (current == null) return;
    leftHandedToolbar = current.leftHanded;
    final layout = _layoutActions.layoutFor(
      current.workspaceId,
      current.customWorkspaces,
    );
    final isCustomWorkspace = current.customWorkspaces.any(
      (workspace) => workspace.id == current.workspaceId,
    );
    final useLayoutDockWidth =
        isCustomWorkspace || current.workspaceId == 'comic';
    _rightWidth =
        (useLayoutDockWidth
                ? layout.right?.width ?? current.dockWidth
                : current.dockWidth)
            .clamp(220.0, 480.0)
            .toDouble();
    _leftWidth =
        (isCustomWorkspace
                ? layout.left?.width ?? current.leftDockWidth
                : current.leftDockWidth)
            .clamp(220, 480)
            .toDouble();

    if (previous?.workspaceId != current.workspaceId ||
        previous?.workspaceOverrides != current.workspaceOverrides) {
      _rightCollapsed = layout.right?.collapsed ?? layout.right == null;
      _leftCollapsed = layout.left?.collapsed ?? layout.left == null;
      _rightTab =
          _layoutActions.paletteName(
            layout.right?.groups.firstOrNull?.activeTab,
          ) ??
          'layers';
      _leftTab =
          _layoutActions.paletteName(
            layout.left?.groups.firstOrNull?.activeTab,
          ) ??
          'tools';
      _leftGroups = layout.left?.groups ?? const [];
      _rightGroups = layout.right?.groups ?? const [];
    }
    const validDockTabs = {
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
    if (validDockTabs.contains(current.lastDock) &&
        previous?.lastDock != current.lastDock) {
      _rightTab = current.lastDock;
    }
  }

  /// Applies a selected workspace's already-resolved dock presentation.
  void applySelection(WorkspaceDockSelection selection) {
    _rightCollapsed = selection.rightCollapsed;
    _leftCollapsed = selection.leftCollapsed;
    _rightWidth = selection.rightWidth;
    _leftWidth = selection.leftWidth;
    _rightTab = selection.rightTab;
    _leftTab = selection.leftTab;
    _leftGroups = selection.leftGroups;
    _rightGroups = selection.rightGroups;
  }

  /// Applies a complete built-in/custom layout selected by workspace editing.
  void applyLayout(WorkspaceLayout layout) {
    _rightWidth = layout.right?.width ?? 360;
    _leftWidth = layout.left?.width ?? 248;
    _rightCollapsed = layout.right == null;
    _leftCollapsed = layout.left == null;
    _rightGroups = layout.right?.groups ?? const [];
    _leftGroups = layout.left?.groups ?? const [];
    _rightTab =
        _layoutActions.paletteName(
          layout.right?.groups.firstOrNull?.activeTab,
        ) ??
        'layers';
    _leftTab =
        _layoutActions.paletteName(
          layout.left?.groups.firstOrNull?.activeTab,
        ) ??
        'tools';
  }
}
