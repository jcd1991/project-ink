import 'dart:collection';

import 'package:flutter/foundation.dart';

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

/// Broad brush families shown by the responsive library UI.
enum BrushFamily { sketch, ink, paint, watercolor, effect, texture, eraser }

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
    this.tags = const <String>[],
    this.size = 12,
    this.opacity = 1,
    this.spacing = 0.1,
    this.stabilization = 0,
    this.pressureSize = 0.55,
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
  final List<String> tags;
  final double size;
  final double opacity;
  final double spacing;
  final double stabilization;
  final double pressureSize;
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

  BrushPresetView copyWith({
    String? name,
    BrushFamily? family,
    List<String>? tags,
    double? size,
    double? opacity,
    double? spacing,
    double? stabilization,
    double? pressureSize,
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
    tags: List<String>.unmodifiable(tags ?? this.tags),
    size: size ?? this.size,
    opacity: opacity ?? this.opacity,
    spacing: spacing ?? this.spacing,
    stabilization: stabilization ?? this.stabilization,
    pressureSize: pressureSize ?? this.pressureSize,
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
  bool _favoritesOnly = false;
  int? _selectedId;

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
          return matchesQuery &&
              matchesTags &&
              (!_favoritesOnly || preset.favorite);
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

  bool get favoritesOnly => _favoritesOnly;

  void toggleFavoritesOnly() {
    _favoritesOnly = !_favoritesOnly;
    notifyListeners();
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
      notifyListeners();
    }
  }

  void toggleFavorite(int id) {
    final preset = _presets[id];
    if (preset != null) {
      _presets[id] = preset.copyWith(favorite: !preset.favorite);
      notifyListeners();
    }
  }

  void updateDraft(BrushPresetView preset) {
    if (_presets.containsKey(preset.id)) {
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
      notifyListeners();
      return;
    }
    // Rust owns every pixel-affecting control and now projects the complete
    // persisted editor state. Only the favorite flag is UI-only and may be
    // retained across a refresh.
    _presets[preset.id] = preset.copyWith(favorite: current.favorite);
    notifyListeners();
  }
}
