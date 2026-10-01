import 'dart:async';

import '../bridge/engine_api.dart';

/// Debounced, local-only checkpoint scheduling for an open Project Ink file.
///
/// The coordinator owns no document data. It only records that the Rust
/// engine has changed and asks the engine to publish an atomic `.inkproj`
/// snapshot. Calling [markDirty] repeatedly is safe while a stroke is being
/// streamed; a save already in flight is never overlapped by another save.
class AutosaveCoordinator {
  AutosaveCoordinator({
    required EngineApi engine,
    required String path,
    this.debounce = const Duration(seconds: 2),
    this.onStateChanged,
    bool hasSavedCheckpoint = false,
  }) : _engine = engine,
       _path = path,
       _hasSavedCheckpoint = hasSavedCheckpoint;

  final EngineApi _engine;
  final String _path;
  final Duration debounce;
  final void Function(AutosaveState state)? onStateChanged;

  Timer? _timer;
  Future<void>? _activeSave;
  Object? _lastError;
  bool _dirty = false;
  bool _hasSavedCheckpoint;
  bool _disposed = false;

  bool get isDirty => _dirty;
  bool get isSaving => _activeSave != null;
  Object? get lastError => _lastError;

  AutosaveState get state => AutosaveState(
    dirty: _dirty,
    saving: isSaving,
    lastError: _lastError,
    hasSavedCheckpoint: _hasSavedCheckpoint,
  );

  /// Mark the document dirty and schedule an atomic save.
  ///
  /// Pointer packets can pass `restartTimer: false` so a long stroke is
  /// checkpointed at the current interval rather than postponing the first
  /// checkpoint forever.
  void markDirty({bool restartTimer = true}) {
    if (_disposed) return;
    _dirty = true;
    _lastError = null;
    if (restartTimer || _timer == null) {
      _schedule();
    }
    _notify();
  }

  /// Save immediately, waiting for any save already in flight first.
  Future<void> flush() async {
    if (_disposed) return;
    _timer?.cancel();
    _timer = null;
    while (_dirty || _activeSave != null) {
      final active = _activeSave;
      if (active != null) {
        await active;
      } else {
        await _saveNow();
      }
    }
  }

  /// Stop scheduling. By default, publish the final dirty revision first.
  Future<void> dispose({bool flush = true}) async {
    if (_disposed) return;
    if (flush) await this.flush();
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _notify();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(debounce, () {
      _timer = null;
      // The coordinator records the error in [lastError]. Do not leak a
      // timer-triggered save failure as an uncaught async error; the next
      // mutation or explicit flush can retry it.
      unawaited(
        _saveNow().then<void>(
          (_) {},
          onError: (Object error, StackTrace stack) {},
        ),
      );
    });
  }

  Future<void> _saveNow() {
    final active = _activeSave;
    if (active != null) return active;
    if (!_dirty || _disposed) return Future<void>.value();

    _dirty = false;
    _lastError = null;
    final save = _engine
        .saveAs(_path)
        .then<void>(
          (_) {
            _hasSavedCheckpoint = true;
          },
          onError: (Object error, StackTrace stack) {
            _dirty = true;
            _lastError = error;
            _notify();
            Error.throwWithStackTrace(error, stack);
          },
        );
    _activeSave = save;
    _notify();
    return save.whenComplete(() {
      _activeSave = null;
      if (_dirty && !_disposed) _schedule();
      _notify();
    });
  }

  void _notify() => onStateChanged?.call(state);
}

class AutosaveState {
  const AutosaveState({
    required this.dirty,
    required this.saving,
    required this.lastError,
    this.hasSavedCheckpoint = false,
  });

  final bool dirty;
  final bool saving;
  final Object? lastError;
  final bool hasSavedCheckpoint;
}
