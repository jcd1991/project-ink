import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/bridge/engine_api.dart';
import 'package:project_ink/documents/autosave_coordinator.dart';

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
    expect(autosave.hasUnsavedChanges, isTrue);
    expect(autosave.state.hasSavedCheckpoint, isTrue);
    await autosave.dispose(flush: false);
  });

  test(
    'explicit save clears unsaved state only for the saved revision',
    () async {
      final engine = _RecordingEngine();
      final autosave = AutosaveCoordinator(
        engine: engine,
        path: '/tmp/explicit-save.inkproj',
        debounce: Duration.zero,
      );

      autosave.markDirty();
      await autosave.flush();
      final savedRevision = engine.revision;
      expect(
        autosave.markExplicitlySaved(savedRevision: savedRevision),
        isTrue,
      );
      expect(autosave.state.hasUnsavedChanges, isFalse);

      autosave.markDirty();
      final staleRevision = engine.revision;
      await engine.beginStroke();
      expect(
        autosave.markExplicitlySaved(savedRevision: staleRevision),
        isFalse,
      );
      expect(autosave.state.hasUnsavedChanges, isTrue);

      await autosave.dispose(flush: false);
    },
  );

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

  test(
    'defers checkpoints and explicit flush until a continuous edit ends',
    () async {
      final engine = _RecordingEngine();
      final autosave = AutosaveCoordinator(
        engine: engine,
        path: '/tmp/active-stroke.inkproj',
        debounce: const Duration(milliseconds: 1),
      );

      autosave.beginContinuousEdit();
      autosave.markDirty();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(engine.savedPaths, isEmpty);
      expect(autosave.autosaveDeferred, isTrue);
      expect(autosave.isDirty, isTrue);

      var flushed = false;
      final flushing = autosave.flush().then((_) => flushed = true);
      await Future<void>.delayed(Duration.zero);
      expect(flushed, isFalse);
      expect(engine.savedPaths, isEmpty);

      autosave.endContinuousEdit();
      await flushing;

      expect(engine.savedPaths, ['/tmp/active-stroke.inkproj']);
      expect(autosave.autosaveDeferred, isFalse);
      expect(autosave.isDirty, isFalse);
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

  test(
    'discard waits for an in-flight recovery write before returning',
    () async {
      final engine = _DelayedEngine();
      final autosave = AutosaveCoordinator(
        engine: engine,
        path: '/tmp/discard.inkproj',
        debounce: Duration.zero,
      );

      autosave.markDirty();
      await Future<void>.delayed(Duration.zero);
      expect(autosave.isSaving, isTrue);
      final discarding = autosave.discard();
      var discarded = false;
      unawaited(discarding.then((_) => discarded = true));
      await Future<void>.delayed(Duration.zero);
      expect(discarded, isFalse);

      engine.completeSave();
      await discarding;
      expect(discarded, isTrue);
      expect(autosave.isDirty, isFalse);
      expect(autosave.hasUnsavedChanges, isFalse);
    },
  );
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
