import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// One locally stored project path, display name, recency, and availability.
class RecentProjectEntry {
  const RecentProjectEntry({
    required this.path,
    required this.available,
    this.displayName,
    this.lastUsed,
  });

  final String path;
  final bool available;
  final String? displayName;
  final DateTime? lastUsed;

  String get name => displayName?.isNotEmpty == true
      ? displayName!
      : _displayNameFromPath(path);
}

/// Device-local MRU index for durable Project Ink directories.
class RecentProjectsStore {
  RecentProjectsStore({String? temporaryDirectory})
    : _temporaryDirectory = _trimTrailingSeparators(
        (temporaryDirectory ?? Directory.systemTemp.path),
      );

  static const storageKey = 'project_ink.recent_projects.v1';
  static const maxEntries = 20;
  static const _formatVersion = 1;
  static const _maxStoredCharacters = 65536;

  final String _temporaryDirectory;

  Future<List<RecentProjectEntry>> list() async {
    try {
      final records = await _readRecords();
      final entries = <RecentProjectEntry>[];
      for (final record in records.take(maxEntries)) {
        entries.add(
          RecentProjectEntry(
            path: record.path,
            displayName: record.displayName,
            lastUsed: record.lastUsed,
            available: await Directory(record.path).exists(),
          ),
        );
      }
      return entries;
    } catch (_) {
      return const <RecentProjectEntry>[];
    }
  }

  Future<void> add(String path) async {
    final normalized = normalizePath(
      path,
      temporaryDirectory: _temporaryDirectory,
    );
    if (normalized == null || !await Directory(normalized).exists()) return;
    final records = await _readRecords();
    final now = DateTime.now().toUtc();
    records.removeWhere((record) => record.path == normalized);
    records.add(
      _RecentProjectRecord(
        path: normalized,
        displayName: _displayNameFromPath(normalized),
        lastUsed: now,
      ),
    );
    records.sort((left, right) => right.lastUsed.compareTo(left.lastUsed));
    await _writeRecords(records.take(maxEntries).toList(growable: false));
  }

  Future<void> remove(String path) async {
    final normalized = normalizePath(
      path,
      temporaryDirectory: _temporaryDirectory,
    );
    if (normalized == null) return;
    final records = await _readRecords();
    records.removeWhere((record) => record.path == normalized);
    await _writeRecords(records.take(maxEntries).toList(growable: false));
  }

  Future<List<_RecentProjectRecord>> _readRecords() async {
    try {
      final encoded = await SharedPreferencesAsync().getString(storageKey);
      if (encoded == null || encoded.length > _maxStoredCharacters) {
        return <_RecentProjectRecord>[];
      }
      final decoded = jsonDecode(encoded);
      if (decoded is! Map ||
          decoded['version'] != _formatVersion ||
          decoded['projects'] is! List) {
        return <_RecentProjectRecord>[];
      }
      final records = <_RecentProjectRecord>[];
      final seenPaths = <String>{};
      for (final value in (decoded['projects'] as List).take(128)) {
        if (value is! Map) continue;
        final path = value['path'];
        final normalized =
            path is String
                ? normalizePath(
                  path,
                  temporaryDirectory: _temporaryDirectory,
                )
                : null;
        final displayName = value['display_name'];
        final lastUsedMillis = value['last_used_ms'];
        if (normalized == null ||
            !seenPaths.add(normalized) ||
            displayName is! String ||
            displayName.trim().isEmpty ||
            displayName.length > 256 ||
            lastUsedMillis is! int ||
            lastUsedMillis < 0) {
          continue;
        }
        records.add(
          _RecentProjectRecord(
            path: normalized,
            displayName: displayName.trim(),
            lastUsed: DateTime.fromMillisecondsSinceEpoch(
              lastUsedMillis,
              isUtc: true,
            ),
          ),
        );
      }
      records.sort((left, right) => right.lastUsed.compareTo(left.lastUsed));
      return records;
    } catch (_) {
      return <_RecentProjectRecord>[];
    }
  }

  Future<void> _writeRecords(List<_RecentProjectRecord> records) async {
    final encoded = jsonEncode({
      'version': _formatVersion,
      'projects': [
        for (final record in records)
          {
            'path': record.path,
            'display_name': record.displayName,
            'last_used_ms': record.lastUsed.millisecondsSinceEpoch,
          },
      ],
    });
    if (encoded.length > _maxStoredCharacters) {
      throw StateError('Recent project index exceeded its storage limit.');
    }
    await SharedPreferencesAsync().setString(storageKey, encoded);
  }

  static String? normalizePath(String value, {String? temporaryDirectory}) {
    final path = value.trim();
    if (path.isEmpty || path.contains('://') || !_isAbsolutePath(path)) {
      return null;
    }
    final normalized = _trimTrailingSeparators(File(path).absolute.path);
    final temporary = _trimTrailingSeparators(
      Directory(
        temporaryDirectory ?? Directory.systemTemp.path,
      ).absolute.path,
    );
    if (normalized == temporary ||
        normalized.startsWith('$temporary${Platform.pathSeparator}')) {
      return null;
    }
    return normalized;
  }

  static bool _isAbsolutePath(String path) =>
      Platform.isWindows
          ? RegExp(r'^[A-Za-z]:[\\/]|^\\\\').hasMatch(path)
          : path.startsWith('/');

  static String _trimTrailingSeparators(String path) {
    final root = Directory(path).absolute.path;
    if (root == Platform.pathSeparator ||
        (Platform.isWindows && RegExp(r'^[A-Za-z]:[\\/]$').hasMatch(root))) {
      return root;
    }
    return path.replaceFirst(RegExp(r'[/\\]+$'), '');
  }
}

class _RecentProjectRecord {
  const _RecentProjectRecord({
    required this.path,
    required this.displayName,
    required this.lastUsed,
  });

  final String path;
  final String displayName;
  final DateTime lastUsed;
}

String _displayNameFromPath(String path) {
  final normalized = path.replaceFirst(RegExp(r'[/\\]+$'), '');
  final segments = normalized.split(RegExp(r'[/\\]'));
  final basename = segments.isEmpty ? normalized : segments.last;
  return basename.toLowerCase().endsWith('.inkproj')
      ? basename.substring(0, basename.length - '.inkproj'.length)
      : basename;
}
