import 'dart:async';
import 'dart:ui' as ui;
import 'dart:typed_data';

const int compositeTileLayerId = -1;

class TileCacheKey {
  const TileCacheKey(this.revision, this.layer, this.x, this.y);
  final int revision;
  final int layer;
  final int x;
  final int y;

  @override
  bool operator ==(Object other) =>
      other is TileCacheKey &&
      other.revision == revision &&
      other.layer == layer &&
      other.x == x &&
      other.y == y;

  @override
  int get hashCode => Object.hash(revision, layer, x, y);
}

/// Immutable visible-tile cache. Unchanged content is promoted across
/// revisions; stale events are ignored rather than composited over the canvas.
class TileCache {
  static const int tileSize = 256;
  static const int tileBytes = 256 * 256 * 4;
  final Map<TileCacheKey, Uint8List> _tiles = <TileCacheKey, Uint8List>{};
  int _revision = 0;

  int get revision => _revision;

  bool put(int revision, int layer, int x, int y, Uint8List bytes) {
    if (revision < _revision) return false;
    if (revision > _revision) {
      final promoted = <TileCacheKey, Uint8List>{};
      for (final entry in _tiles.entries) {
        final key = entry.key;
        promoted[TileCacheKey(revision, key.layer, key.x, key.y)] = entry.value;
      }
      _tiles
        ..clear()
        ..addAll(promoted);
      _revision = revision;
    }
    _tiles[TileCacheKey(revision, layer, x, y)] = bytes;
    return true;
  }

  Uint8List? get(int layer, int x, int y) =>
      _tiles[TileCacheKey(_revision, layer, x, y)];

  void clear() {
    _tiles.clear();
    _revision = 0;
  }
}

/// GPU-ready tile images kept separate from the byte cache so native reads
/// and image decoding never happen during [CustomPainter.paint].
class TileImageCache {
  final Map<TileCacheKey, ui.Image> _images = <TileCacheKey, ui.Image>{};
  bool _disposed = false;

  bool get isEmpty => _images.isEmpty;

  ui.Image? get(int revision, int layer, int x, int y) =>
      _images[TileCacheKey(revision, layer, x, y)];

  Future<void> put(TileCacheKey key, Uint8List bytes) async {
    if (_disposed) return;
    final image = await _decodeBgraTile(bytes);
    if (_disposed) {
      image.dispose();
      return;
    }
    final previous = _images[key];
    if (previous != null && !identical(previous, image)) {
      _retire(previous);
    }
    _images[key] = image;
  }

  /// Preserve unchanged tiles when only a dirty subset advances revision.
  void promoteRevision(int fromRevision, int toRevision) {
    if (_disposed) return;
    if (fromRevision == toRevision) return;
    final entries = _images.entries
        .where((entry) => entry.key.revision == fromRevision)
        .toList(growable: false);
    for (final entry in entries) {
      final key = entry.key;
      final promotedKey = TileCacheKey(toRevision, key.layer, key.x, key.y);
      final previous = _images[promotedKey];
      if (previous != null) {
        // A replacement image for this tile has already been decoded and
        // staged at the new revision. Keep it; promoting the old image over
        // it would expose stale pixels during the revision swap.
        _images.remove(key);
        if (!identical(previous, entry.value)) _retire(entry.value);
        continue;
      }
      _images[promotedKey] = entry.value;
      _images.remove(key);
    }
  }

  /// Drop staged images from older revisions after the new frame has been
  /// published. Callers deliberately wait until all dirty tiles are decoded;
  /// removing them earlier exposes a blank frame between revisions.
  void retainRevision(int revision) {
    if (_disposed) return;
    final staleKeys = _images.keys
        .where((key) => key.revision != revision)
        .toList(growable: false);
    for (final key in staleKeys) {
      final image = _images.remove(key);
      if (image != null) _retire(image);
    }
  }

  void clear() {
    if (_disposed) return;
    for (final image in _images.values) {
      _retire(image);
    }
    _images.clear();
  }

  void removeWhere(bool Function(TileCacheKey key) predicate) {
    if (_disposed) return;
    final keys = _images.keys.where(predicate).toList(growable: false);
    for (final key in keys) {
      final image = _images.remove(key);
      if (image != null) _retire(image);
    }
  }

  /// Returns borrowed handles. A painter that outlives the current synchronous
  /// build must clone each image and own those clones for its full lifetime.
  Iterable<MapEntry<TileCacheKey, ui.Image>> get entries =>
      _disposed
          ? const <MapEntry<TileCacheKey, ui.Image>>[]
          : _images.entries
              .map((entry) => MapEntry(entry.key, entry.value))
              .toList(growable: false);

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // Painters own clones of any images they captured, so releasing the cache
    // handles here cannot invalidate an older painter snapshot.
    for (final image in _images.values) {
      image.dispose();
    }
    _images.clear();
  }

  void _retire(ui.Image image) {
    image.dispose();
  }
}

Future<ui.Image> _decodeBgraTile(Uint8List bytes) {
  if (bytes.length != TileCache.tileBytes) {
    return Future<ui.Image>.error(
      const FormatException('tile payload has an invalid byte length'),
    );
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    _unpremultiplyBgra(bytes),
    256,
    256,
    ui.PixelFormat.bgra8888,
    completer.complete,
    rowBytes: 256 * 4,
  );
  return completer.future;
}

Uint8List _unpremultiplyBgra(Uint8List bytes) {
  final result = Uint8List.fromList(bytes);
  for (var offset = 0; offset + 3 < result.length; offset += 4) {
    final alpha = result[offset + 3];
    if (alpha == 0 || alpha == 255) continue;
    for (var channel = 0; channel < 3; channel++) {
      result[offset + channel] = ((result[offset + channel] * 255) / alpha)
          .round()
          .clamp(0, 255);
    }
  }
  return result;
}
