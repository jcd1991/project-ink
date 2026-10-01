class LayerIdProjection {
  static const int maxSafeId = 0x7fffffffffffffff;

  final Map<BigInt, int> _dartIdsByRustId = <BigInt, int>{};
  final Map<int, BigInt> _rustIdsByDartId = <int, BigInt>{};
  final Set<int> _reserved = <int>{};
  int _nextAlias = maxSafeId;

  /// Reserves real Dart-range IDs before assigning aliases to legacy IDs.
  /// Existing high IDs keep stable aliases until the active page changes.
  void reset(Iterable<BigInt> rustIds) {
    final ids = rustIds.toList(growable: false);
    _dartIdsByRustId.clear();
    _rustIdsByDartId.clear();
    _reserved
      ..clear()
      ..addAll(
        ids
            .where((id) => !id.isNegative && id <= BigInt.from(maxSafeId))
            .map((id) => id.toInt()),
      );
    _nextAlias = maxSafeId;
    for (final id in ids) {
      if (id.isNegative) throw StateError('negative layer identifier');
      if (id > BigInt.from(maxSafeId)) _alias(id);
    }
  }

  int toDart(BigInt rustId) {
    if (rustId.isNegative) throw StateError('negative layer identifier');
    return rustId <= BigInt.from(maxSafeId) ? rustId.toInt() : _alias(rustId);
  }

  BigInt toRust(int dartId) {
    if (dartId < 0) throw ArgumentError.value(dartId, 'dartId');
    return _rustIdsByDartId[dartId] ?? BigInt.from(dartId);
  }

  int _alias(BigInt rustId) {
    final existing = _dartIdsByRustId[rustId];
    if (existing != null) return existing;
    while (_nextAlias > 0 &&
        (_reserved.contains(_nextAlias) ||
            _rustIdsByDartId.containsKey(_nextAlias))) {
      _nextAlias--;
    }
    if (_nextAlias <= 0) {
      throw StateError('no safe Dart aliases remain for legacy layer IDs');
    }
    final alias = _nextAlias--;
    _dartIdsByRustId[rustId] = alias;
    _rustIdsByDartId[alias] = rustId;
    return alias;
  }
}
