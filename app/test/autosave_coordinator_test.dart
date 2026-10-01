import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/bridge/engine_api.dart';
import 'package:project_ink/documents/autosave_coordinator.dart';
import 'dart:async';

class _RecordingEngine extends InMemoryEngineApi {
  final List<String> savedPaths = <String>[];

  @override
  Future<void> saveAs(String path) async {
    savedPaths.add(path);
  }
}

void main() {
  test('coalesces dirty notifications into one immediate checkpoint', () async {
    final engine = _RecordingEngine();
    final autosave = AutosaveCoordinator(
      engine: engine,
      path: '/tmp/drawing.inkproj',
      debounce: Duration.zero,
    );
    expect(autosave.state.hasSavedCheckpoint, isFalse);

    autosave.markDirty();
    autosave.markDirty(restartTimer: false);
    await autosave.flush();

    expect(engine.savedPaths, ['/tmp/drawing.inkproj']);
    expect(autosave.isDirty, isFalse);
    expect(autosave.state.hasSavedCheckpoint, isTrue);
    await autosave.dispose(flush: false);
  });

  test(
    'periodic packet notifications do not postpone the first checkpoint',
    () async {
      final engine = _RecordingEngine();
      final autosave = AutosaveCoordinator(
        engine: engine,
        path: '/tmp/long-stroke.inkproj',
        debounce: const Duration(milliseconds: 1),
      );

      autosave.markDirty();
      autosave.markDirty(restartTimer: false);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await autosave.flush();

      expect(engine.savedPaths, ['/tmp/long-stroke.inkproj']);
      await autosave.dispose(flush: false);
    },
  );

  test('save errors keep the revision dirty for a later retry', () async {
    final engine = _FailingEngine();
    final autosave = AutosaveCoordinator(
      engine: engine,
      path: '/tmp/retry.inkproj',
      debounce: Duration.zero,
    );

    autosave.markDirty();
    await expectLater(autosave.flush(), throwsA(isA<StateError>()));
    expect(autosave.isDirty, isTrue);
    expect(autosave.lastError, isA<StateError>());
    expect(autosave.state.hasSavedCheckpoint, isFalse);
    engine.fail = false;
    await autosave.flush();
    expect(autosave.isDirty, isFalse);
    expect(autosave.state.hasSavedCheckpoint, isTrue);
    await autosave.dispose(flush: false);
  });

  test('flush waits for an in-flight save after dirty has cleared', () async {
    final engine = _DelayedEngine();
    final autosave = AutosaveCoordinator(
      engine: engine,
      path: '/tmp/in-flight.inkproj',
      debounce: Duration.zero,
    );

    autosave.markDirty();
    await Future<void>.delayed(Duration.zero);
    expect(autosave.isDirty, isFalse);
    expect(autosave.isSaving, isTrue);

    var flushed = false;
    final flushing = autosave.flush().then((_) => flushed = true);
    await Future<void>.delayed(Duration.zero);
    expect(flushed, isFalse);

    engine.completeSave();
    await flushing;
    expect(flushed, isTrue);
    expect(autosave.isSaving, isFalse);
    await autosave.dispose(flush: false);
  });
}

class _FailingEngine extends InMemoryEngineApi {
  bool fail = true;

  @override
  Future<void> saveAs(String path) async {
    if (fail) throw StateError('checkpoint failed');
  }
}

class _DelayedEngine extends InMemoryEngineApi {
  final Completer<void> _save = Completer<void>();

  @override
  Future<void> saveAs(String path) => _save.future;

  void completeSave() => _save.complete();
}
