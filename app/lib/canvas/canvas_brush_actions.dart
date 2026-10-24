import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../bridge/engine_api.dart';
import '../tools/brush_library.dart';
import '../tools/brush_library_panel.dart';
import 'canvas_diagnostic_recorder.dart';

/// Screen-owned seams required by [CanvasBrushActions].
class CanvasBrushActionHost {
  const CanvasBrushActionHost({
    required this.engine,
    required this.library,
    required this.context,
    required this.mounted,
    required this.setState,
    required this.activeBrushId,
    required this.setActiveBrushId,
    required this.finishDanglingStrokeBeforeBrushEdit,
    required this.endStaleStroke,
    required this.loadPhase2Projections,
    required this.markDirty,
    required this.diagnostics,
    required this.showMessage,
  });

  final EngineApi Function() engine;
  final BrushLibraryModel Function() library;
  final BuildContext Function() context;
  final bool Function() mounted;
  final void Function(VoidCallback callback) setState;
  final int Function() activeBrushId;
  final ValueChanged<int> setActiveBrushId;
  final Future<void> Function() finishDanglingStrokeBeforeBrushEdit;
  final Future<void> Function() endStaleStroke;
  final Future<void> Function() loadPhase2Projections;
  final void Function() markDirty;
  final CanvasDiagnosticRecorder diagnostics;
  final void Function(String message) showMessage;
}

/// Owns brush preview, edit drafts, edit queues, and brush setting commits.
class CanvasBrushActions {
  CanvasBrushActions(this.host);

  final CanvasBrushActionHost host;
  EngineApi get engine => host.engine();
  BrushLibraryModel get library => host.library();
  final Map<int, int> _draftIds = <int, int>{};
  final Map<int, Future<void>> _editQueues = <int, Future<void>>{};
  final Map<String, Uint8List> _thumbnailCache = <String, Uint8List>{};
  Timer? _quickSizeTimer;
  double? _pendingQuickSize;

  bool hasUncommittedChanges(int? brushId) =>
      brushId != null && _draftIds.containsKey(brushId);

  Future<void>? pendingEditForBrush(int brushId) => _editQueues[brushId];

  Future<void> persistPendingQuickSize() async {
    final pendingSize = _pendingQuickSize;
    if (pendingSize != null) persistBrushSize(pendingSize);
  }

  void cancelDraftsForEngine(EngineApi engine) {
    for (final draftId in _draftIds.values) {
      unawaited(
        engine.cancelBrushDraft(draftId).catchError((Object error) {
          debugPrint('Project Ink brush draft cleanup failed: $error');
        }),
      );
    }
    _draftIds.clear();
    _editQueues.clear();
  }

  void dispose(EngineApi engine) {
    _quickSizeTimer?.cancel();
    _quickSizeTimer = null;
    cancelDraftsForEngine(engine);
    _thumbnailCache.clear();
  }

  void applyBrushDraft(BrushPresetView preset) {
    if (!host.mounted()) return;
    host.setState(() => host.setActiveBrushId(preset.id));
    final brushId = preset.id;
    final previous = _editQueues[brushId] ?? Future<void>.value();
    final operation = previous.then<void>((_) async {
      var draftId = _draftIds[brushId];
      if (draftId == null) {
        await host.finishDanglingStrokeBeforeBrushEdit();
        try {
          draftId = await engine.beginBrushDraft(brushId);
        } catch (_) {
          // A native Pencil stream can lose its terminal packet after a very
          // long/high-rate gesture. Rust is authoritative about whether that
          // transaction is still active. Close only that stale transaction,
          // then retry the brush edit once so the UI draft cannot diverge
          // from the brush used by the committed renderer.
          await engine.endStroke();
          await host.endStaleStroke();
          draftId = await engine.beginBrushDraft(brushId);
        }
        _draftIds[brushId] = draftId;
        if (host.mounted()) host.setState(() {});
      }
      await engine.updateBrushDraft(
        draftId: draftId,
        diameter: preset.size,
        opacity: preset.opacity,
        spacing: preset.spacing,
        smoothing: preset.stabilization,
        pressureSize: preset.pressureSize,
        pressureOpacity: preset.pressureOpacity,
        pressureCurve: preset.pressureCurve,
        pressureCurvePoints: preset.pressureCurvePoints,
        hardness: preset.hardness,
        textureScale: preset.textureScale,
        scatter: preset.scatter,
        rotationJitter: preset.rotationJitter,
        smudge: preset.smudge,
        wetness: preset.wetness,
        pulledString: preset.pulledString,
        stabilizerDistancePx: preset.stabilizerDistancePx,
        catchUpOnEnd: preset.catchUpOnEnd,
      );
    });
    _editQueues[brushId] = operation.catchError((
      Object error,
      StackTrace stack,
    ) async {
      debugPrint('Project Ink brush draft rejected: $error\n$stack');
      final draftId = _draftIds.remove(brushId);
      if (draftId != null) {
        try {
          await engine.cancelBrushDraft(draftId);
        } catch (cancelError, cancelStack) {
          debugPrint(
            'Project Ink rejected brush draft cleanup failed: '
            '$cancelError\n$cancelStack',
          );
        }
      }
      if (host.mounted()) await host.loadPhase2Projections();
    });
  }

  void updateBrushDraft(BrushPresetView preset) {
    library.updateDraft(preset);
    applyBrushDraft(preset);
  }

  Future<void> updatePressureResponse({
    required int brushId,
    required BrushPressureTargetView target,
    required double amount,
    required bool enabled,
    required List<BrushCurvePointView> curvePoints,
  }) {
    final previous = _editQueues[brushId] ?? Future<void>.value();
    final operation = previous.then<void>((_) async {
      var draftId = _draftIds[brushId];
      if (draftId == null) {
        final preset = library.presets.firstWhere((item) => item.id == brushId);
        await host.finishDanglingStrokeBeforeBrushEdit();
        draftId = await engine.beginBrushDraft(brushId);
        _draftIds[brushId] = draftId;
        await engine.updateBrushDraft(
          draftId: draftId,
          diameter: preset.size,
          opacity: preset.opacity,
          spacing: preset.spacing,
          smoothing: preset.stabilization,
          pressureSize: preset.pressureSize,
          pressureOpacity: preset.pressureOpacity,
          pressureCurve: preset.pressureCurve,
          pressureCurvePoints: preset.pressureCurvePoints,
          hardness: preset.hardness,
          textureScale: preset.textureScale,
          scatter: preset.scatter,
          rotationJitter: preset.rotationJitter,
          smudge: preset.smudge,
          wetness: preset.wetness,
          pulledString: preset.pulledString,
          stabilizerDistancePx: preset.stabilizerDistancePx,
          catchUpOnEnd: preset.catchUpOnEnd,
        );
      }
      await engine.updateBrushPressureResponse(
        draftId: draftId,
        target: target,
        amount: amount,
        enabled: enabled,
        curvePoints: curvePoints,
      );
      if (host.mounted()) host.setState(() {});
    });
    _editQueues[brushId] = operation.catchError((
      Object error,
      StackTrace stack,
    ) {
      debugPrint('Project Ink pressure response rejected: $error\\n$stack');
    });
    return operation;
  }

  Future<Uint8List> renderBrushPreview(
    int brushId,
    int width,
    int height,
    List<BrushPreviewPointView> points,
  ) async {
    String? thumbnailKey;
    if (width == 64 && height == 40 && points.length == 12) {
      for (final preset in library.presets) {
        if (preset.id == brushId) {
          thumbnailKey = '$brushId:${preset.libraryKey}';
          break;
        }
      }
      final cached =
          thumbnailKey == null ? null : _thumbnailCache[thumbnailKey];
      if (cached != null) return cached;
    }
    final image = await engine.renderBrushPreview(
      brushId: brushId,
      width: width,
      height: height,
      points: points,
    );
    if (thumbnailKey != null) {
      if (_thumbnailCache.length >= 64) _thumbnailCache.clear();
      _thumbnailCache[thumbnailKey] = image;
    }
    return image;
  }

  Future<void> activateBrush(BrushPresetView preset) async {
    host.setState(() {
      host.setActiveBrushId(preset.id);
    });
  }

  /// Applies the shared foreground color to strokes without editing a preset.
  Future<bool> setActivePaintColor(Color color) async {
    try {
      await engine.setActiveBrushColor(
        red: (color.r * 255).round().clamp(0, 255),
        green: (color.g * 255).round().clamp(0, 255),
        blue: (color.b * 255).round().clamp(0, 255),
        alpha: (color.a * 255).round().clamp(0, 255),
      );
      return true;
    } catch (error, stack) {
      debugPrint('Project Ink active color update failed: $error\n$stack');
      return false;
    }
  }

  void updateQuickBrushSizePreview(double size) {
    final brush = library.selected;
    if (brush == null || !size.isFinite) return;
    _pendingQuickSize = size.clamp(0.25, 128.0).toDouble();
    host.diagnostics.record('brush.quick_size_preview', {
      'brushId': brush.id,
      'activeBrushId': host.activeBrushId(),
      'sizePx': _pendingQuickSize,
      'selectedBrushMatchesActive': brush.id == host.activeBrushId(),
    });
    library.updateDraft(brush.copyWith(size: size));
    if (host.mounted()) host.setState(() {});
    // Some iPad stylus/touch streams cancel the slider's terminal callback.
    // Persist after a brief pause; onChangeEnd still commits immediately.
    _quickSizeTimer?.cancel();
    _quickSizeTimer = Timer(const Duration(milliseconds: 180), () {
      final pendingSize = _pendingQuickSize;
      if (pendingSize != null) persistBrushSize(pendingSize);
    });
  }

  void persistBrushSize(double size) {
    _quickSizeTimer?.cancel();
    _quickSizeTimer = null;
    _pendingQuickSize = null;
    final brush = library.selected;
    if (brush == null || !size.isFinite) return;
    final preset = brush.copyWith(size: size.clamp(0.25, 4096.0).toDouble());
    final brushId = preset.id;
    host.diagnostics.record('brush.size_save_requested', {
      'brushId': brushId,
      'activeBrushId': host.activeBrushId(),
      'sizePx': preset.size,
      'selectedBrushMatchesActive': brushId == host.activeBrushId(),
    });
    library.updateDraft(preset);
    final previous = _editQueues[brushId] ?? Future<void>.value();
    final operation = previous.then<void>((_) async {
      await host.finishDanglingStrokeBeforeBrushEdit();
      final draftId = _draftIds.remove(brushId);
      if (draftId != null) {
        await engine.cancelBrushDraft(draftId);
      }
      await engine.updateBrushSettings(
        brushId: brushId,
        diameter: preset.size,
        opacity: preset.opacity,
        spacing: preset.spacing,
        smoothing: preset.stabilization,
        pressureSize: preset.pressureSize,
        pressureOpacity: preset.pressureOpacity,
        pressureCurve: preset.pressureCurve,
        pressureCurvePoints: preset.pressureCurvePoints,
        hardness: preset.hardness,
        textureScale: preset.textureScale,
        scatter: preset.scatter,
        rotationJitter: preset.rotationJitter,
        smudge: preset.smudge,
        wetness: preset.wetness,
        pulledString: preset.pulledString,
        stabilizerDistancePx: preset.stabilizerDistancePx,
        catchUpOnEnd: preset.catchUpOnEnd,
      );
      final readBack = await engine.builtinBrushes();
      final savedBrush = readBack.where((entry) => entry.id == brushId);
      final savedSize = savedBrush.isEmpty ? null : savedBrush.first.diameterPx;
      host.diagnostics.record('brush.size_saved', {
        'brushId': brushId,
        'requestedSizePx': preset.size,
        'savedSizePx': savedSize,
        'matchesRequested':
            savedSize != null && (savedSize - preset.size).abs() < 0.01,
      });
      host.markDirty();
      await host.loadPhase2Projections();
      if (host.mounted()) host.setState(() {});
    });
    _editQueues[brushId] = operation.catchError((
      Object error,
      StackTrace stack,
    ) async {
      host.diagnostics.recordError('brush.size_save_failed', error, stack);
      debugPrint('Project Ink quick brush size update failed: $error\n$stack');
      final draftId = _draftIds.remove(brushId);
      if (draftId != null) {
        try {
          await engine.cancelBrushDraft(draftId);
        } catch (_) {}
      }
      await host.loadPhase2Projections();
      if (host.mounted()) {
        host.showMessage('Could not update brush size: $error');
        host.setState(() {});
      }
    });
  }

  void persistSelectedBrushSettings() {
    final brush = library.selected;
    if (brush != null) persistBrushSize(brush.size);
  }

  void commitBrushDraft(int brushId) {
    final previous = _editQueues[brushId] ?? Future<void>.value();
    final operation = previous.then<void>((_) async {
      final draftId = _draftIds.remove(brushId);
      if (draftId != null) {
        await engine.commitBrushDraft(draftId);
        host.markDirty();
      }
      _editQueues.remove(brushId);
      if (host.mounted()) host.setState(() {});
    });
    _editQueues[brushId] = operation.catchError((
      Object error,
      StackTrace stack,
    ) async {
      debugPrint('Project Ink brush draft commit rejected: $error\n$stack');
      final draftId = _draftIds.remove(brushId);
      if (draftId != null) {
        try {
          await engine.cancelBrushDraft(draftId);
        } catch (cancelError, cancelStack) {
          debugPrint(
            'Project Ink rejected brush commit cleanup failed: '
            '$cancelError\n$cancelStack',
          );
        }
      }
      if (host.mounted()) await host.loadPhase2Projections();
    });
  }

  void commitSelectedBrushDraft() {
    final brushId = library.selected?.id;
    if (brushId != null) commitBrushDraft(brushId);
  }

  void cancelBrushDraft() {
    final brushId = library.selected?.id;
    if (brushId == null) return;
    final previous = _editQueues[brushId] ?? Future<void>.value();
    final operation = previous.then<void>((_) async {
      final draftId = _draftIds.remove(brushId);
      if (draftId != null) {
        await engine.cancelBrushDraft(draftId);
      }
      await host.loadPhase2Projections();
      _editQueues.remove(brushId);
    });
    _editQueues[brushId] = operation.catchError((
      Object error,
      StackTrace stack,
    ) async {
      debugPrint(
        'Project Ink brush draft cancellation rejected: $error\n$stack',
      );
      _draftIds.remove(brushId);
      _editQueues.remove(brushId);
      if (host.mounted()) await host.loadPhase2Projections();
    });
  }

  Future<void> duplicateBrush() async {
    final selected = library.selected;
    if (selected == null) return;
    try {
      final duplicateId = await engine.duplicateBrush(selected.id);
      await host.loadPhase2Projections();
      if (!host.mounted()) return;
      host.setState(() {
        library.select(duplicateId);
        host.setActiveBrushId(duplicateId);
      });
      host.markDirty();
    } catch (error, stack) {
      debugPrint('Project Ink brush duplicate failed: $error\n$stack');
    }
  }

  Future<void> renameBrush() async {
    final selected = library.selected;
    if (selected == null || selected.isBuiltin) return;
    final name = await showDialog<String>(
      context: host.context(),
      builder: (_) => BrushRenameDialog(initialName: selected.name),
    );
    if (name == null || name.trim().isEmpty || !host.mounted()) return;
    try {
      await engine.renameBrush(brushId: selected.id, name: name);
      await host.loadPhase2Projections();
      if (!host.mounted()) return;
      library.select(selected.id);
      host.markDirty();
    } catch (error, stack) {
      debugPrint('Project Ink brush rename failed: $error\\n$stack');
      if (host.mounted()) {
        host.showMessage('Could not rename brush: $error');
      }
    }
  }
}
