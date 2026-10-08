import 'dart:async';

import 'package:flutter/foundation.dart';

import '../app/editor_action.dart';
import '../bridge/engine_api.dart';

/// Screen integrations used by [CanvasHistoryActions].
class CanvasHistoryActionHost {
  const CanvasHistoryActionHost({
    required this.engine,
    required this.waitForStrokeOperations,
    required this.markDirty,
    required this.refreshLayerProjection,
    required this.refreshTiles,
    required this.loadPhase2Projections,
    required this.loadVectorSelection,
    required this.mounted,
    required this.setState,
    this.undoProjectIfLatest,
    this.redoProjectIfLatest,
  });

  final EngineApi Function() engine;
  final Future<void> Function() waitForStrokeOperations;
  final void Function() markDirty;
  final Future<void> Function() refreshLayerProjection;
  final Future<void> Function() refreshTiles;
  final Future<void> Function() loadPhase2Projections;
  final Future<void> Function() loadVectorSelection;
  final bool Function() mounted;
  final void Function(VoidCallback update) setState;
  final Future<bool> Function()? undoProjectIfLatest;
  final Future<bool> Function()? redoProjectIfLatest;
}

/// Owns undo, redo, and history navigation ordering and projection refreshes.
class CanvasHistoryActions {
  const CanvasHistoryActions(this.host);

  final CanvasHistoryActionHost host;

  /// Routes undo/redo commands to this history owner.
  bool dispatchEditorAction(EditorActionId action) {
    switch (action) {
      case EditorActionId.undo:
        unawaited(undo());
        return true;
      case EditorActionId.redo:
        unawaited(redo());
        return true;
      default:
        return false;
    }
  }

  Future<void> undo() async {
    try {
      // Stroke packets and EndStroke share a serial queue. Drain it before
      // advancing history so a fast shortcut cannot undo the previous item.
      await host.waitForStrokeOperations();
      final projectUndone = await host.undoProjectIfLatest?.call() ?? false;
      if (!projectUndone) await host.engine().undo();
      host.markDirty();
      unawaited(host.refreshTiles());
      unawaited(host.refreshLayerProjection());
    } catch (error, stack) {
      debugPrint('Project Ink undo failed: $error\n$stack');
    }
  }

  Future<void> redo() async {
    try {
      await host.waitForStrokeOperations();
      final projectRedone = await host.redoProjectIfLatest?.call() ?? false;
      if (!projectRedone) await host.engine().redo();
      host.markDirty();
      unawaited(host.refreshTiles());
      unawaited(host.refreshLayerProjection());
    } catch (error, stack) {
      debugPrint('Project Ink redo failed: $error\n$stack');
    }
  }

  Future<void> navigateHistory(int sequence) async {
    try {
      await host.engine().navigateHistory(sequence);
      host.markDirty();
      await host.loadPhase2Projections();
      await host.refreshTiles();
      await host.loadVectorSelection();
      if (host.mounted()) host.setState(() {});
    } catch (error, stack) {
      debugPrint('Project Ink history navigation failed: $error\n$stack');
    }
  }
}
