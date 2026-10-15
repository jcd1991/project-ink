import 'dart:convert';
import 'dart:collection';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One normalized pressure-response control point.
class BrushCurvePointView {
  const BrushCurvePointView({required this.x, required this.y})
    : assert(x >= 0 && x <= 1),
      assert(y >= 0 && y <= 1);

  final double x;
  final double y;

  BrushCurvePointView copyWith({double? x, double? y}) =>
      BrushCurvePointView(x: x ?? this.x, y: y ?? this.y);
}

/// Normalized stylus sample sent to Rust's isolated brush preview renderer.
class BrushPreviewPointView {
  const BrushPreviewPointView({
    required this.x,
    required this.y,
    required this.pressure,
  });

  final double x;
  final double y;
  final double pressure;
}

/// Broad brush families shown by the responsive library UI.
enum BrushFamily { sketch, ink, paint, watercolor, effect, texture, eraser }

enum BrushBrowserFilter { all, recent, favorites, custom }

enum BrushEditorSection { stroke, pressure, tip, paint }

/// Device-local collection that organizes stable Rust-brush content keys.
class BrushSetView {
  const BrushSetView({
    required this.id,
    required this.name,
    required this.brushKeys,
  });

  final String id;
  final String name;
  final Set<String> brushKeys;
}

/// Immutable UI projection of a Rust-owned brush preset.
///
/// The engine remains authoritative for rendering and persistence. These
/// values are a safe projection/draft for controls; edits are committed through
/// the generated bridge command back to Rust.
class BrushPresetView {
  const BrushPresetView({
    required this.id,
    required this.name,
    required this.family,
    this.isBuiltin = false,
    this.tags = const <String>[],
    this.size = 12,
    this.opacity = 1,
    this.colorRgba = 0x202124ff,
    this.spacing = 0.1,
    this.stabilization = 0,
    this.pulledString = false,
    this.stabilizerDistancePx = 0,
    this.catchUpOnEnd = false,
    this.pressureSize = 0.55,
    this.pressureSizeReplace = false,
    this.pressureOpacity = 0,
    this.pressureCurve = 0.5,
    this.pressureCurvePoints = const <BrushCurvePointView>[
      BrushCurvePointView(x: 0, y: 0),
      BrushCurvePointView(x: 0.5, y: 0.5),
      BrushCurvePointView(x: 1, y: 1),
    ],
    this.tipResourceHash,
    this.grainResourceHash,
    this.hardness = 0.75,
    this.textureScale = 1,
    this.scatter = 0,
    this.rotationJitter = 0,
    this.smudge = 0,
    this.wetness = 0,
    this.favorite = false,
  }) : assert(size > 0),
       assert(opacity >= 0 && opacity <= 1),
       assert(spacing > 0 && spacing <= 4),
       assert(stabilization >= 0 && stabilization <= 1),
       assert(stabilizerDistancePx >= 0 && stabilizerDistancePx <= 100),
       assert(pressureSize >= 0 && pressureSize <= 1),
       assert(pressureOpacity >= 0 && pressureOpacity <= 1),
       assert(pressureCurve >= 0 && pressureCurve <= 1),
       assert(hardness >= 0 && hardness <= 1),
       assert(textureScale > 0),
       assert(scatter >= 0 && scatter <= 1),
       assert(rotationJitter >= 0 && rotationJitter <= 1),
       assert(smudge >= 0 && smudge <= 1),
       assert(wetness >= 0 && wetness <= 1);

  final int id;
  final String name;
  final BrushFamily family;
  final bool isBuiltin;
  final List<String> tags;
  final double size;
  final double opacity;
  final int colorRgba;
  final double spacing;
  final double stabilization;
  final bool pulledString;
  final double stabilizerDistancePx;
  final bool catchUpOnEnd;
  final double pressureSize;
  final bool pressureSizeReplace;
  final double pressureOpacity;
  final double pressureCurve;
  final List<BrushCurvePointView> pressureCurvePoints;
  final List<int>? tipResourceHash;
  final List<int>? grainResourceHash;
  final double hardness;
  final double textureScale;
  final double scatter;
  final double rotationJitter;
  final double smudge;
  final double wetness;
  final bool favorite;

  /// Content identity shared by equivalent copies across artwork documents.
  String get libraryKey => jsonEncode(<Object?>[
    name,
    family.name,
    tags.toList()..sort(),
    size,
    opacity,
    colorRgba,
    spacing,
    stabilization,
    pulledString,
    stabilizerDistancePx,
    catchUpOnEnd,
    pressureSize,
    pressureSizeReplace,
    pressureOpacity,
    pressureCurve,
    pressureCurvePoints.map((point) => <double>[point.x, point.y]).toList(),
    tipResourceHash,
    grainResourceHash,
    hardness,
    textureScale,
    scatter,
    rotationJitter,
    smudge,
    wetness,
  ]);

  BrushPresetView copyWith({
    String? name,
    BrushFamily? family,
    List<String>? tags,
    double? size,
    double? opacity,
    int? colorRgba,
    double? spacing,
    double? stabilization,
    bool? pulledString,
    double? stabilizerDistancePx,
    bool? catchUpOnEnd,
    double? pressureSize,
    bool? pressureSizeReplace,
    double? pressureOpacity,
    double? pressureCurve,
    List<BrushCurvePointView>? pressureCurvePoints,
    List<int>? tipResourceHash,
    List<int>? grainResourceHash,
    double? hardness,
    double? textureScale,
    double? scatter,
    double? rotationJitter,
    double? smudge,
    double? wetness,
    bool? favorite,
  }) => BrushPresetView(
    id: id,
    name: name ?? this.name,
    family: family ?? this.family,
    isBuiltin: isBuiltin,
    tags: List<String>.unmodifiable(tags ?? this.tags),
    size: size ?? this.size,
    opacity: opacity ?? this.opacity,
    colorRgba: colorRgba ?? this.colorRgba,
    spacing: spacing ?? this.spacing,
    stabilization: stabilization ?? this.stabilization,
    pulledString: pulledString ?? this.pulledString,
    stabilizerDistancePx: stabilizerDistancePx ?? this.stabilizerDistancePx,
    catchUpOnEnd: catchUpOnEnd ?? this.catchUpOnEnd,
    pressureSize: pressureSize ?? this.pressureSize,
    pressureSizeReplace: pressureSizeReplace ?? this.pressureSizeReplace,
    pressureOpacity: pressureOpacity ?? this.pressureOpacity,
    pressureCurve: pressureCurve ?? this.pressureCurve,
    pressureCurvePoints: List<BrushCurvePointView>.unmodifiable(
      pressureCurvePoints ?? this.pressureCurvePoints,
    ),
    tipResourceHash: tipResourceHash ?? this.tipResourceHash,
    grainResourceHash: grainResourceHash ?? this.grainResourceHash,
    hardness: hardness ?? this.hardness,
    textureScale: textureScale ?? this.textureScale,
    scatter: scatter ?? this.scatter,
    rotationJitter: rotationJitter ?? this.rotationJitter,
    smudge: smudge ?? this.smudge,
    wetness: wetness ?? this.wetness,
    favorite: favorite ?? this.favorite,
  );
}

/// Library state for a compact, touch, or desktop brush browser.
class BrushLibraryModel extends ChangeNotifier {
  BrushLibraryModel(Iterable<BrushPresetView> presets)
    : _presets = <int, BrushPresetView>{
        for (final preset in presets) preset.id: preset,
      };

  final Map<int, BrushPresetView> _presets;
  String _query = '';
  final Set<String> _tagFilters = <String>{};
  BrushBrowserFilter _browserFilter = BrushBrowserFilter.all;
  BrushFamily? _familyFilter;
  bool _editorOpen = false;
  int _scratchPadRevision = 0;
  final List<String> _recentBrushKeys = <String>[];
  final Set<String> _savedFavoriteKeys = <String>{};
  final Map<String, BrushSetView> _sets = <String, BrushSetView>{};
  String? _activeSetId;
  BrushEditorSection _editorSection = BrushEditorSection.stroke;
  Future<void> _persistQueue = Future<void>.value();
  int? _selectedId;
  int? _pendingSelectionId;

  UnmodifiableListView<BrushPresetView> get presets =>
      UnmodifiableListView<BrushPresetView>(
        _presets.values.toList(growable: false),
      );

  UnmodifiableListView<BrushPresetView> get favorites =>
      UnmodifiableListView<BrushPresetView>(
        _presets.values
            .where((preset) => preset.favorite)
            .toList(growable: false),
      );

  UnmodifiableListView<BrushPresetView> get filteredPresets {
    final query = _query.trim().toLowerCase();
    final values = _presets.values
        .where((preset) {
          final matchesQuery =
              query.isEmpty ||
              preset.name.toLowerCase().contains(query) ||
              preset.tags.any((tag) => tag.toLowerCase().contains(query));
          final matchesTags = _tagFilters.every(preset.tags.contains);
          final matchesFamily =
              _familyFilter == null || preset.family == _familyFilter;
          final activeSet = _activeSetId == null ? null : _sets[_activeSetId];
          final matchesSet =
              activeSet == null ||
              activeSet.brushKeys.contains(preset.libraryKey);
          final matchesBrowserFilter = switch (_browserFilter) {
            BrushBrowserFilter.all => true,
            BrushBrowserFilter.recent => _recentBrushKeys.contains(
              preset.libraryKey,
            ),
            BrushBrowserFilter.favorites => preset.favorite,
            BrushBrowserFilter.custom => !preset.isBuiltin,
          };
          return matchesQuery &&
              matchesTags &&
              matchesFamily &&
              matchesSet &&
              matchesBrowserFilter;
        })
        .toList(growable: false);
    return UnmodifiableListView<BrushPresetView>(values);
  }

  UnmodifiableListView<String> get tags => UnmodifiableListView<String>(
    _presets.values
      .expand((preset) => preset.tags)
      .toSet()
      .toList(growable: false)..sort(),
  );

  UnmodifiableSetView<String> get activeTagFilters =>
      UnmodifiableSetView<String>(_tagFilters);

  bool get favoritesOnly => _browserFilter == BrushBrowserFilter.favorites;
  BrushBrowserFilter get browserFilter => _browserFilter;
  BrushFamily? get familyFilter => _familyFilter;
  UnmodifiableListView<BrushSetView> get sets =>
      UnmodifiableListView(_sets.values.toList(growable: false));
  String? get activeSetId => _activeSetId;
  BrushEditorSection get editorSection => _editorSection;
  bool get editorOpen => _editorOpen;
  int get scratchPadRevision => _scratchPadRevision;

  void clearScratchPad() {
    _scratchPadRevision++;
    notifyListeners();
  }

  void setBrowserFilter(BrushBrowserFilter filter) {
    if (_browserFilter == filter) return;
    _browserFilter = filter;
    notifyListeners();
  }

  void setFamilyFilter(BrushFamily? family) {
    if (_familyFilter == family) return;
    _familyFilter = family;
    notifyListeners();
  }

  void selectSet(String? id) {
    if (id != null && !_sets.containsKey(id)) return;
    if (_activeSetId == id) return;
    _activeSetId = id;
    notifyListeners();
  }

  String createSet(String name) {
    final normalized = name.trim();
    if (normalized.isEmpty) throw ArgumentError.value(name, 'name');
    final id = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    _sets[id] = BrushSetView(id: id, name: normalized, brushKeys: <String>{});
    _activeSetId = id;
    unawaited(persistLocalState());
    notifyListeners();
    return id;
  }

  void addSelectedToSet(String id) {
    final current = _sets[id];
    final preset = selected;
    if (current == null ||
        preset == null ||
        current.brushKeys.contains(preset.libraryKey)) {
      return;
    }
    _sets[id] = BrushSetView(
      id: current.id,
      name: current.name,
      brushKeys: <String>{...current.brushKeys, preset.libraryKey},
    );
    unawaited(persistLocalState());
    notifyListeners();
  }

  void removeSelectedFromSet(String id) {
    final current = _sets[id];
    final preset = selected;
    if (current == null ||
        preset == null ||
        !current.brushKeys.contains(preset.libraryKey)) {
      return;
    }
    _sets[id] = BrushSetView(
      id: current.id,
      name: current.name,
      brushKeys: Set<String>.of(current.brushKeys)..remove(preset.libraryKey),
    );
    unawaited(persistLocalState());
    notifyListeners();
  }

  void renameSet(String id, String name) {
    final current = _sets[id];
    final normalized = name.trim();
    if (current == null || normalized.isEmpty) return;
    _sets[id] = BrushSetView(
      id: current.id,
      name: normalized,
      brushKeys: Set<String>.of(current.brushKeys),
    );
    unawaited(persistLocalState());
    notifyListeners();
  }

  void deleteSet(String id) {
    if (_sets.remove(id) == null) return;
    if (_activeSetId == id) _activeSetId = null;
    unawaited(persistLocalState());
    notifyListeners();
  }

  void toggleEditor() {
    _editorOpen = !_editorOpen;
    notifyListeners();
  }

  void selectEditorSection(BrushEditorSection section) {
    if (_editorSection == section) return;
    _editorSection = section;
    notifyListeners();
  }

  Future<void> restoreLocalState() async {
    final preferences = await SharedPreferences.getInstance();
    _savedFavoriteKeys
      ..clear()
      ..addAll(
        _restoreBrushKeys(
          preferences.getStringList('brush_library.favorite_ids') ?? const [],
        ),
      );
    _recentBrushKeys
      ..clear()
      ..addAll(
        _restoreBrushKeys(
          preferences.getStringList('brush_library.recent_ids') ?? const [],
        ).take(20),
      );
    _sets.clear();
    try {
      final decoded = jsonDecode(
        preferences.getString('brush_library.sets') ?? '[]',
      );
      if (decoded is List) {
        for (final item in decoded.whereType<Map>()) {
          final id = item['id'];
          final name = item['name'];
          final keys = item['brushKeys'];
          final legacyIds = item['brushIds'];
          if (id is String &&
              name is String &&
              (keys is List || legacyIds is List)) {
            final brushKeys = <String>{
              ...?keys?.whereType<String>(),
              ...?legacyIds
                  ?.whereType<int>()
                  .map((brushId) => _presets[brushId]?.libraryKey)
                  .whereType<String>(),
            };
            _sets[id] = BrushSetView(id: id, name: name, brushKeys: brushKeys);
          }
        }
      }
    } on FormatException {
      _sets.clear();
    }
    for (final preset in _presets.values.toList(growable: false)) {
      final favorite = _savedFavoriteKeys.contains(preset.libraryKey);
      if (preset.favorite != favorite) {
        _presets[preset.id] = preset.copyWith(favorite: favorite);
      }
    }
    notifyListeners();
  }

  Future<void> persistLocalState() {
    final operation = _persistQueue.then((_) async {
      try {
        final preferences = await SharedPreferences.getInstance();
        await preferences.setStringList(
          'brush_library.favorite_ids',
          _savedFavoriteKeys.toList(growable: false),
        );
        await preferences.setStringList(
          'brush_library.recent_ids',
          _recentBrushKeys.toList(growable: false),
        );
        await preferences.setString(
          'brush_library.sets',
          jsonEncode(
            _sets.values
                .map(
                  (set) => <String, Object>{
                    'id': set.id,
                    'name': set.name,
                    'brushKeys': set.brushKeys.toList(growable: false),
                  },
                )
                .toList(growable: false),
          ),
        );
      } catch (error, stack) {
        debugPrint('Could not save local brush preferences: $error\n$stack');
      }
    });
    _persistQueue = operation;
    return operation;
  }

  void toggleFavoritesOnly() {
    setBrowserFilter(
      favoritesOnly ? BrushBrowserFilter.all : BrushBrowserFilter.favorites,
    );
  }

  void setSearchQuery(String value) {
    if (_query == value) return;
    _query = value;
    notifyListeners();
  }

  void toggleTagFilter(String tag) {
    if (!_tagFilters.add(tag)) _tagFilters.remove(tag);
    notifyListeners();
  }

  BrushPresetView? get selected =>
      _selectedId == null ? null : _presets[_selectedId];

  void select(int id) {
    if (_presets.containsKey(id) && _selectedId != id) {
      _selectedId = id;
      final key = _presets[id]!.libraryKey;
      _recentBrushKeys.remove(key);
      _recentBrushKeys.insert(0, key);
      if (_recentBrushKeys.length > 20) _recentBrushKeys.removeLast();
      unawaited(persistLocalState());
      notifyListeners();
    }
  }

  /// Selects [id] when its Rust-owned projection arrives in the library.
  void selectWhenAvailable(int id) {
    if (_presets.containsKey(id)) {
      _pendingSelectionId = null;
      select(id);
    } else {
      _pendingSelectionId = id;
    }
  }

  void toggleFavorite(int id) {
    final preset = _presets[id];
    if (preset != null) {
      _presets[id] = preset.copyWith(favorite: !preset.favorite);
      if (_presets[id]!.favorite) {
        _savedFavoriteKeys.add(preset.libraryKey);
      } else {
        _savedFavoriteKeys.remove(preset.libraryKey);
      }
      unawaited(persistLocalState());
      notifyListeners();
    }
  }

  void updateDraft(BrushPresetView preset) {
    final current = _presets[preset.id];
    if (current != null) {
      _replaceSetKey(current.libraryKey, preset.libraryKey);
      _presets[preset.id] = preset;
      notifyListeners();
    }
  }

  /// Replace or add a Rust-owned preset projection after an asynchronous
  /// bridge refresh. The model never becomes the source of rendered pixels.
  void upsert(BrushPresetView preset) {
    final current = _presets[preset.id];
    if (current == null) {
      _presets[preset.id] = preset;
      if (_pendingSelectionId == preset.id) {
        _pendingSelectionId = null;
        select(preset.id);
      }
      notifyListeners();
      return;
    }
    // Rust owns every pixel-affecting control and now projects the complete
    // persisted editor state. Only the favorite flag is UI-only and may be
    // retained across a refresh.
    final refreshed = preset.copyWith(favorite: current.favorite);
    _replaceSetKey(current.libraryKey, refreshed.libraryKey);
    _presets[preset.id] = refreshed;
    if (_savedFavoriteKeys.contains(preset.libraryKey) != current.favorite) {
      _presets[preset.id] = _presets[preset.id]!.copyWith(
        favorite: _savedFavoriteKeys.contains(preset.libraryKey),
      );
    }
    if (_pendingSelectionId == preset.id) {
      _pendingSelectionId = null;
      select(preset.id);
    }
    notifyListeners();
  }

  void _replaceSetKey(String oldKey, String newKey) {
    if (oldKey == newKey) return;
    final wasFavorite = _savedFavoriteKeys.remove(oldKey);
    if (wasFavorite) _savedFavoriteKeys.add(newKey);
    final recentIndex = _recentBrushKeys.indexOf(oldKey);
    if (recentIndex >= 0) _recentBrushKeys[recentIndex] = newKey;
    for (final entry in _sets.entries.toList(growable: false)) {
      if (!entry.value.brushKeys.contains(oldKey)) continue;
      _sets[entry.key] = BrushSetView(
        id: entry.value.id,
        name: entry.value.name,
        brushKeys:
            Set<String>.of(entry.value.brushKeys)
              ..remove(oldKey)
              ..add(newKey),
      );
    }
  }

  Iterable<String> _restoreBrushKeys(Iterable<String> storedValues) sync* {
    for (final value in storedValues) {
      final legacyId = int.tryParse(value);
      if (legacyId != null) {
        final preset = _presets[legacyId];
        if (preset != null) yield preset.libraryKey;
      } else {
        yield value;
      }
    }
  }
}
