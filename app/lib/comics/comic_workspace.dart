import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../bridge/generated/api.dart' as rust;
import '../design_system/ink_components.dart';

enum _ComicInspectorSection { page, panel, text, toneEffects, export }

const comicExportFailureMessage =
    'Export failed. Choose a different, writable folder and try again.';

String? comicWorkspaceErrorMessage(Object? error) => switch (error) {
  null => null,
  String message => message,
  _ => 'Comic operation failed. Please try again.',
};

extension on _ComicInspectorSection {
  String get label => switch (this) {
    _ComicInspectorSection.page => 'Page',
    _ComicInspectorSection.panel => 'Panel',
    _ComicInspectorSection.text => 'Text/Balloon',
    _ComicInspectorSection.toneEffects => 'Tone/Effects',
    _ComicInspectorSection.export => 'Export',
  };

  String get compactLabel => switch (this) {
    _ComicInspectorSection.page => 'Page',
    _ComicInspectorSection.panel => 'Panel',
    _ComicInspectorSection.text => 'Text',
    _ComicInspectorSection.toneEffects => 'Tone',
    _ComicInspectorSection.export => 'Export',
  };
}

/// Rust-backed Phase 3.5 comic session. The controller only caches immutable
/// projections; page/panel/dialogue state and structural history remain inside
/// the opaque StudioProjectHandle.
class ComicWorkspaceController extends ChangeNotifier {
  /// Returns the active page's index after moving another page in the list.
  ///
  /// This keeps the controller's index-based selection aligned with the
  /// Rust-owned page order. The active page itself moves with the reorder;
  /// pages crossed by the move shift by one in the opposite direction.
  @visibleForTesting
  static int activePageIndexAfterReorder({
    required int activeIndex,
    required int from,
    required int to,
  }) {
    if (activeIndex == from) return to;
    if (from < to && activeIndex > from && activeIndex <= to) {
      return activeIndex - 1;
    }
    if (from > to && activeIndex >= to && activeIndex < from) {
      return activeIndex + 1;
    }
    return activeIndex;
  }

  ComicWorkspaceController({
    this.onPersist,
    this.readExisting,
    this.onPanelGeometryChanged,
    this.onActivePageChanged,
    this.onProjectChanged,
  });

  final Future<void> Function(Uint8List bytes)? onPersist;
  final Future<Uint8List?> Function()? readExisting;

  /// Compatibility seam for panel geometry. It updates the canvas document's
  /// generated mask when a panel is added, resized, reshaped, or split; page
  /// drawing and persistence use the shared active-page capability. The
  /// callback is optional so metadata-only consumers and widget tests remain
  /// independent of a canvas.
  final Future<void> Function(rust.ComicProjectView snapshot)?
  onPanelGeometryChanged;

  /// Publishes a shared capability view of the active page document. The
  /// canvas host can rebind its existing EngineApi without creating a second
  /// raster authority; null means the project was closed.
  final Future<void> Function(rust.DocumentHandle? handle)? onActivePageChanged;

  /// Publishes the owning project capability to the document host so saves
  /// and autosaves can use the complete multi-page container.
  final Future<void> Function(rust.StudioProjectHandle? handle)?
  onProjectChanged;

  rust.StudioProjectHandle? _handle;
  rust.ComicProjectView? _snapshot;
  rust.ComicPrintPreviewView? _printPreview;
  Uint8List? _pagePreviewBytes;
  int? _pagePreviewIndex;
  int _lastKnownPageIndex = 0;
  int _nextLocalId = DateTime.now().microsecondsSinceEpoch;
  Uint8List? _lastPersistedJson;
  Object? _error;
  bool _loading = false;
  bool _canUndo = false;
  bool _canRedo = false;

  rust.ComicProjectView? get snapshot => _snapshot;
  rust.ComicPrintPreviewView? get printPreview => _printPreview;
  Uint8List? get pagePreviewBytes => _pagePreviewBytes;
  int? get pagePreviewIndex => _pagePreviewIndex;
  int get activePageIndex => _pagePreviewIndex ?? _lastKnownPageIndex;
  Object? get error => _error;
  String? get userFacingError => comicWorkspaceErrorMessage(_error);
  bool get loading => _loading;
  bool get canUndo => _canUndo;
  bool get canRedo => _canRedo;

  BigInt _newLocalId() => BigInt.from(_nextLocalId++);

  Future<void> _publishActivePage() async {
    final callback = onActivePageChanged;
    if (callback == null) return;
    final handle = _handle;
    if (handle == null) {
      await callback(null);
      return;
    }
    await callback(await rust.projectActiveDocument(handle: handle));
  }

  Future<void> _publishProject() async {
    await onProjectChanged?.call(_handle);
  }

  /// Re-publish both capabilities after the host replaces its EngineApi
  /// instance (for example, when opening another native document).
  Future<void> republishEngineBindings() async {
    await _publishProject();
    await _publishActivePage();
  }

  Future<void> _persist() async {
    // A structural edit invalidates the rasterized preview. The next
    // workspace frame will request a fresh Rust-owned preview for the
    // selected page instead of showing stale artwork.
    _pagePreviewBytes = null;
    _pagePreviewIndex = null;
    final handle = _handle;
    final persist = onPersist;
    if (handle == null) return;
    try {
      final bytes = await rust.studioProjectToJson(handle: handle);
      _lastPersistedJson = Uint8List.fromList(bytes);
      if (persist != null) await persist(bytes);
      _canUndo = await rust.projectCanUndo(handle: handle);
      _canRedo = await rust.projectCanRedo(handle: handle);
    } catch (error) {
      _error = error;
    }
  }

  Future<void> undo() async {
    final handle = _handle;
    if (handle == null || !_canUndo) return;
    try {
      _snapshot = await rust.undoProject(handle: handle);
      await _persist();
      _error = null;
    } catch (error) {
      _error = error;
    }
    notifyListeners();
  }

  Future<void> redo() async {
    final handle = _handle;
    if (handle == null || !_canRedo) return;
    try {
      _snapshot = await rust.redoProject(handle: handle);
      await _persist();
      _error = null;
    } catch (error) {
      _error = error;
    }
    notifyListeners();
  }

  Future<void> ensureExampleLoaded() async {
    if (_handle != null || _loading) return;
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final existing = await readExisting?.call();
      _handle =
          existing == null
              ? await rust.createStudioXkcdStickFigureProject()
              : await rust.createStudioProjectFromJson(bytes: existing);
      _snapshot = await rust.projectSnapshot(handle: _handle!);
      await _publishProject();
      await _publishActivePage();
      if (existing == null) {
        await _persist();
      } else {
        _lastPersistedJson = Uint8List.fromList(existing);
        _canUndo = await rust.projectCanUndo(handle: _handle!);
        _canRedo = await rust.projectCanRedo(handle: _handle!);
      }
    } catch (error) {
      _error = error;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Close the current comic handle without deleting the last persisted copy.
  /// The workspace can then create a new template or recover that copy.
  Future<void> closeProject() async {
    final handle = _handle;
    _handle = null;
    _snapshot = null;
    _printPreview = null;
    _pagePreviewBytes = null;
    _pagePreviewIndex = null;
    _canUndo = false;
    _canRedo = false;
    // Keep the last validated checkpoint available for an in-session
    // recovery, even when the host did not provide a file-backed callback.
    // Creating a new template deliberately replaces this checkpoint; closing
    // a project must not make the recovery action a no-op.
    _error = null;
    await _publishProject();
    await onActivePageChanged?.call(null);
    if (handle != null) await rust.closeStudioProject(handle: handle);
    notifyListeners();
  }

  /// Reopen the last project bytes supplied by the host document session.
  /// Recovery never mutates the existing handle until the replacement has
  /// decoded and validated successfully.
  Future<bool> recoverPersistedProject() async {
    final persisted = await readExisting?.call() ?? _lastPersistedJson;
    if (persisted == null || persisted.isEmpty) {
      _error = StateError('No saved comic project is available.');
      notifyListeners();
      return false;
    }
    _loading = true;
    _error = null;
    notifyListeners();
    rust.StudioProjectHandle? next;
    try {
      next = await rust.createStudioProjectFromJson(bytes: persisted);
      final nextSnapshot = await rust.projectSnapshot(handle: next);
      final old = _handle;
      _handle = next;
      _snapshot = nextSnapshot;
      await _publishProject();
      await _publishActivePage();
      _printPreview = null;
      _pagePreviewBytes = null;
      _pagePreviewIndex = null;
      _canUndo = await rust.projectCanUndo(handle: next);
      _canRedo = await rust.projectCanRedo(handle: next);
      _lastPersistedJson = Uint8List.fromList(persisted);
      if (old != null) await rust.closeStudioProject(handle: old);
      next = null;
      return true;
    } catch (error) {
      if (next != null) await rust.closeStudioProject(handle: next);
      _error = error;
      return false;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Open a complete multi-page project from its native package. The current
  /// project remains bound until both the Rust loader and first page snapshot
  /// validate; on failure the old capability and canvas projection survive.
  Future<bool> openProjectFromPath(String path) async {
    if (path.trim().isEmpty || _loading) return false;
    _loading = true;
    _error = null;
    notifyListeners();
    rust.StudioProjectHandle? next;
    final previousHandle = _handle;
    final previousSnapshot = _snapshot;
    final previousCanUndo = _canUndo;
    final previousCanRedo = _canRedo;
    try {
      next = await rust.openStudioProject(path: path);
      final snapshot = await rust.projectSnapshot(handle: next);
      if (snapshot.pages.isEmpty) {
        throw StateError('The comic project has no pages.');
      }
      _handle = next;
      _snapshot = snapshot;
      await _publishProject();
      await _publishActivePage();
      _lastKnownPageIndex = 0;
      _printPreview = null;
      _pagePreviewBytes = null;
      _pagePreviewIndex = null;
      _lastPersistedJson = Uint8List.fromList(
        await rust.studioProjectToJson(handle: next),
      );
      _canUndo = await rust.projectCanUndo(handle: next);
      _canRedo = await rust.projectCanRedo(handle: next);
      if (previousHandle != null) {
        await rust.closeStudioProject(handle: previousHandle);
      }
      next = null;
      return true;
    } catch (error) {
      if (next != null) {
        _handle = previousHandle;
        _snapshot = previousSnapshot;
        _canUndo = previousCanUndo;
        _canRedo = previousCanRedo;
        try {
          await _publishProject();
          await _publishActivePage();
        } catch (_) {}
        await rust.closeStudioProject(handle: next);
      }
      _error = error;
      return false;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> createTemplate(int template) async {
    final oldHandle = _handle;
    try {
      final webtoon = template == 2;
      final handle = await rust.createStudioProject(
        projectId: _newLocalId(),
        template: template,
        title: switch (template) {
          0 => 'Illustration project',
          1 => 'Print comic project',
          _ => 'Webtoon project',
        },
        pageId: _newLocalId(),
        widthPx: webtoon ? 1080 : 2400,
        heightPx: webtoon ? 5000 : 1800,
        dpi: webtoon ? 144 : 300,
      );
      _handle = handle;
      try {
        _snapshot = await rust.projectSnapshot(handle: handle);
        await _publishProject();
        await _publishActivePage();
      } catch (_) {
        _handle = null;
        await rust.closeStudioProject(handle: handle);
        rethrow;
      }
      if (oldHandle != null) {
        await rust.closeStudioProject(handle: oldHandle);
      }
      _canUndo = false;
      _canRedo = false;
      _lastPersistedJson = null;
      await _persist();
      _error = null;
    } catch (error) {
      _error = error;
    }
    notifyListeners();
  }

  /// Switch the active page in the single Rust project authority. Navigation
  /// is deliberately not an undoable edit, but it invalidates page previews.
  Future<void> activatePage(int pageIndex) async {
    final handle = _handle;
    final snapshot = _snapshot;
    if (handle == null ||
        snapshot == null ||
        pageIndex < 0 ||
        pageIndex >= snapshot.pages.length) {
      return;
    }
    try {
      await rust.activatePage(
        handle: handle,
        pageId: snapshot.pages[pageIndex].id,
      );
      await _publishProject();
      await _publishActivePage();
      _lastKnownPageIndex = pageIndex;
      _pagePreviewBytes = null;
      _pagePreviewIndex = null;
      _error = null;
    } catch (error) {
      _error = error;
    }
    notifyListeners();
  }

  Future<void> reorderPage(int from, int to) async {
    final handle = _handle;
    if (handle == null) return;
    try {
      _snapshot = await rust.studioReorderPage(
        handle: handle,
        from: from,
        to: to,
      );
      _lastKnownPageIndex = activePageIndexAfterReorder(
        activeIndex: _lastKnownPageIndex,
        from: from,
        to: to,
      );
      await _persist();
      _error = null;
    } catch (error) {
      _error = error;
    }
    notifyListeners();
  }

  Future<void> removePage(int pageIndex) async {
    final handle = _handle;
    final snapshot = _snapshot;
    if (handle == null ||
        snapshot == null ||
        pageIndex < 0 ||
        pageIndex >= snapshot.pages.length ||
        snapshot.pages.length <= 1) {
      return;
    }
    final activePageId =
        snapshot
            .pages[_lastKnownPageIndex.clamp(0, snapshot.pages.length - 1)]
            .id;
    try {
      _snapshot = await rust.studioRemovePage(
        handle: handle,
        pageIndex: pageIndex,
      );
      final pages = _snapshot!.pages;
      final preservedIndex = pages.indexWhere(
        (page) => page.id == activePageId,
      );
      final nextIndex =
          preservedIndex >= 0
              ? preservedIndex
              : pageIndex.clamp(0, pages.length - 1);
      await rust.activatePage(handle: handle, pageId: pages[nextIndex].id);
      _lastKnownPageIndex = nextIndex;
      _pagePreviewBytes = null;
      _pagePreviewIndex = null;
      await _publishProject();
      await _publishActivePage();
      await _persist();
      _error = null;
    } catch (error) {
      _error = error;
    }
    notifyListeners();
  }

  Future<void> setPageLayout({
    required int pageIndex,
    required double dpi,
    required double bleedLeft,
    required double bleedTop,
    required double bleedRight,
    required double bleedBottom,
    required double trimX,
    required double trimY,
    required double trimWidth,
    required double trimHeight,
    required double safetyLeft,
    required double safetyTop,
    required double safetyRight,
    required double safetyBottom,
  }) async {
    final handle = _handle;
    final snapshot = _snapshot;
    if (handle == null ||
        snapshot == null ||
        pageIndex < 0 ||
        pageIndex >= snapshot.pages.length) {
      return;
    }
    try {
      _snapshot = await rust.studioSetPageLayout(
        handle: handle,
        pageIndex: pageIndex,
        dpi: dpi,
        bleedLeft: bleedLeft,
        bleedTop: bleedTop,
        bleedRight: bleedRight,
        bleedBottom: bleedBottom,
        trimX: trimX,
        trimY: trimY,
        trimWidth: trimWidth,
        trimHeight: trimHeight,
        safetyLeft: safetyLeft,
        safetyTop: safetyTop,
        safetyRight: safetyRight,
        safetyBottom: safetyBottom,
      );
      await _persist();
      _error = null;
    } catch (error) {
      _error = error;
    }
    notifyListeners();
  }

  Future<void> addPrintPage() async {
    final handle = _handle;
    final snapshot = _snapshot;
    if (handle == null || snapshot == null) return;
    final webtoon = snapshot.template == 2;
    try {
      _snapshot = await rust.addProjectPage(
        handle: handle,
        pageId: _newLocalId(),
        widthPx: webtoon ? 1080 : 2400,
        heightPx: webtoon ? 5000 : 1800,
        dpi: webtoon ? 144 : 300,
      );
      await _persist();
      _error = null;
    } catch (error) {
      _error = error;
    }
    notifyListeners();
  }

  Future<void> addPanel({int pageIndex = 0}) async {
    final handle = _handle;
    if (handle == null) return;
    try {
      _snapshot = await rust.addProjectPanel(
        handle: handle,
        pageIndex: pageIndex,
        panelId: _newLocalId(),
        x: 160,
        y: 700,
        width: 420,
        height: 420,
        gutterPx: 24,
      );
      await _persist();
      await onPanelGeometryChanged?.call(_snapshot!);
      _error = null;
    } catch (error) {
      _error = error;
    }
    notifyListeners();
  }

  Future<void> setPanelBounds({
    required int pageIndex,
    required BigInt panelId,
    required double x,
    required double y,
    required double width,
    required double height,
  }) async {
    final handle = _handle;
    if (handle == null) return;
    try {
      _snapshot = await rust.setProjectPanelBounds(
        handle: handle,
        pageIndex: pageIndex,
        panelId: panelId,
        x: x,
        y: y,
        width: width,
        height: height,
      );
      await _persist();
      await onPanelGeometryChanged?.call(_snapshot!);
      _error = null;
    } catch (error) {
      _error = error;
    }
    notifyListeners();
  }

  Future<void> addBalloon({
    int pageIndex = 0,
    int shape = 0,
    bool verticalText = false,
  }) async {
    final handle = _handle;
    if (handle == null) return;
    try {
      _snapshot = await rust.studioAddStyledBalloon(
        handle: handle,
        pageIndex: pageIndex,
        balloonId: _newLocalId(),
        panelId: null,
        shape: shape,
        tail: <double>[420, 1060, 380, 1120],
        orientation: verticalText ? 1 : 0,
        fontFamily: verticalText ? 'serif' : 'sans-serif',
        fontSizePx: 32,
        outlinePx: shape == 2 ? 2 : 0,
        x: 180,
        y: 900,
        width: 300,
        height: 160,
        text: 'New dialogue',
      );
      await _persist();
      _error = null;
    } catch (error) {
      _error = error;
    }
    notifyListeners();
  }

  Future<void> makeFirstPanelPolygon({int pageIndex = 0}) async {
    final handle = _handle;
    final snapshot = _snapshot;
    if (handle == null ||
        snapshot == null ||
        pageIndex < 0 ||
        pageIndex >= snapshot.pages.length) {
      return;
    }
    final panels = snapshot.pages[pageIndex].panels;
    if (panels.isEmpty) return;
    try {
      _snapshot = await rust.setProjectPanelPolygon(
        handle: handle,
        pageIndex: pageIndex,
        panelId: panels.first.id,
        points: <double>[
          panels.first.x,
          panels.first.y,
          panels.first.x + panels.first.width,
          panels.first.y,
          panels.first.x + panels.first.width - 24,
          panels.first.y + panels.first.height,
          panels.first.x,
          panels.first.y + panels.first.height,
        ],
      );
      await _persist();
      await onPanelGeometryChanged?.call(_snapshot!);
      _error = null;
    } catch (error) {
      _error = error;
    }
    notifyListeners();
  }

  Future<void> setPanelPolygon({
    required int pageIndex,
    required BigInt panelId,
    required List<double> points,
  }) async {
    final handle = _handle;
    if (handle == null) return;
    try {
      _snapshot = await rust.setProjectPanelPolygon(
        handle: handle,
        pageIndex: pageIndex,
        panelId: panelId,
        points: points,
      );
      await _persist();
      await onPanelGeometryChanged?.call(_snapshot!);
      _error = null;
    } catch (error) {
      _error = error;
    }
    notifyListeners();
  }

  Future<void> addTone({
    int pageIndex = 0,
    String shape = 'circle',
    double frequencyLpi = 60,
    double angleDegrees = 45,
    double density = 0.35,
  }) async {
    final handle = _handle;
    final snapshot = _snapshot;
    if (handle == null ||
        snapshot == null ||
        pageIndex < 0 ||
        pageIndex >= snapshot.pages.length) {
      return;
    }
    final page = snapshot.pages[pageIndex];
    try {
      _snapshot = await rust.studioAddTone(
        handle: handle,
        pageIndex: pageIndex,
        toneId: _newLocalId(),
        frequencyLpi: frequencyLpi,
        angleDegrees: angleDegrees,
        density: density,
        shape: shape,
        x: page.widthPx * 0.1,
        y: page.heightPx * 0.1,
        width: page.widthPx * 0.8,
        height: page.heightPx * 0.8,
      );
      await _persist();
      _error = null;
    } catch (error) {
      _error = error;
    }
    notifyListeners();
  }

  Future<void> setTone({
    required int pageIndex,
    required rust.ComicTonePreviewView tone,
    required String shape,
    required double frequencyLpi,
    required double angleDegrees,
    required double density,
  }) async {
    final handle = _handle;
    if (handle == null) return;
    try {
      _snapshot = await rust.studioSetTone(
        handle: handle,
        pageIndex: pageIndex,
        toneId: tone.id,
        frequencyLpi: frequencyLpi,
        angleDegrees: angleDegrees,
        density: density,
        shape: shape,
        x: tone.x,
        y: tone.y,
        width: tone.width,
        height: tone.height,
      );
      await _persist();
      _error = null;
    } catch (error) {
      _error = error;
    }
    notifyListeners();
  }

  Future<void> removeTone({
    required int pageIndex,
    required BigInt toneId,
  }) async {
    final handle = _handle;
    if (handle == null) return;
    try {
      _snapshot = await rust.studioRemoveTone(
        handle: handle,
        pageIndex: pageIndex,
        toneId: toneId,
      );
      await _persist();
      _error = null;
    } catch (error) {
      _error = error;
    }
    notifyListeners();
  }

  Future<void> addEffectLine({
    int pageIndex = 0,
    String kind = 'speed',
    double widthPx = 8,
    double opacity = 0.75,
  }) async {
    final handle = _handle;
    final snapshot = _snapshot;
    if (handle == null ||
        snapshot == null ||
        pageIndex < 0 ||
        pageIndex >= snapshot.pages.length) {
      return;
    }
    final page = snapshot.pages[pageIndex];
    try {
      _snapshot = await rust.studioAddEffectLine(
        handle: handle,
        pageIndex: pageIndex,
        effectId: _newLocalId(),
        kind: kind,
        points: switch (kind) {
          'focus' => <double>[
            page.widthPx * 0.5,
            page.heightPx * 0.5,
            page.widthPx * 0.15,
            page.heightPx * 0.15,
          ],
          'radial' => <double>[
            page.widthPx * 0.5,
            page.heightPx * 0.5,
            page.widthPx * 0.9,
            page.heightPx * 0.25,
          ],
          _ => <double>[
            page.widthPx * 0.1,
            page.heightPx * 0.1,
            page.widthPx * 0.9,
            page.heightPx * 0.9,
          ],
        },
        widthPx: widthPx,
        opacity: opacity,
      );
      await _persist();
      _error = null;
    } catch (error) {
      _error = error;
    }
    notifyListeners();
  }

  Future<void> setEffectLine({
    required int pageIndex,
    required rust.ComicEffectLinePreviewView line,
    required String kind,
    required double widthPx,
    required double opacity,
  }) async {
    final handle = _handle;
    if (handle == null) return;
    try {
      _snapshot = await rust.studioSetEffectLine(
        handle: handle,
        pageIndex: pageIndex,
        effectId: line.id,
        kind: kind,
        points: line.points,
        widthPx: widthPx,
        opacity: opacity,
      );
      await _persist();
      _error = null;
    } catch (error) {
      _error = error;
    }
    notifyListeners();
  }

  Future<void> removeEffectLine({
    required int pageIndex,
    required BigInt effectId,
  }) async {
    final handle = _handle;
    if (handle == null) return;
    try {
      _snapshot = await rust.studioRemoveEffectLine(
        handle: handle,
        pageIndex: pageIndex,
        effectId: effectId,
      );
      await _persist();
      _error = null;
    } catch (error) {
      _error = error;
    }
    notifyListeners();
  }

  Future<void> addLocalMaterial({
    String kind = 'balloon-style',
    String? name,
    String license = 'MPL-2.0',
    String? attribution,
    String? source,
  }) async {
    final handle = _handle;
    if (handle == null) return;
    final normalizedKind = kind.trim().isEmpty ? 'balloon-style' : kind.trim();
    final normalizedName =
        name?.trim().isNotEmpty == true
            ? name!.trim()
            : switch (normalizedKind) {
              'brush' => 'Local brush preset',
              'texture' => 'Local paper texture',
              'template' => 'Local page template',
              _ => 'Local balloon style',
            };
    final normalizedLicense =
        license.trim().isEmpty ? 'NOASSERTION' : license.trim();
    final normalizedAttribution = attribution?.trim();
    final normalizedSource = source?.trim();
    try {
      _snapshot = await rust.studioAddMaterial(
        handle: handle,
        materialId: _newLocalId(),
        name: normalizedName,
        kind: normalizedKind,
        license: normalizedLicense,
        attribution:
            normalizedAttribution?.isEmpty == true
                ? null
                : normalizedAttribution,
        source: normalizedSource?.isEmpty == true ? null : normalizedSource,
      );
      await _persist();
      _error = null;
    } catch (error) {
      _error = error;
    }
    notifyListeners();
  }

  Future<void> removeMaterial(BigInt materialId) async {
    final handle = _handle;
    if (handle == null) return;
    try {
      _snapshot = await rust.studioRemoveMaterial(
        handle: handle,
        materialId: materialId,
      );
      await _persist();
      _error = null;
    } catch (error) {
      _error = error;
    }
    notifyListeners();
  }

  Future<void> splitFirstPanel({
    int pageIndex = 0,
    int axis = 0,
    double ratio = 0.5,
  }) async {
    final handle = _handle;
    final snapshot = _snapshot;
    if (handle == null ||
        snapshot == null ||
        pageIndex < 0 ||
        pageIndex >= snapshot.pages.length ||
        snapshot.pages[pageIndex].panels.isEmpty) {
      return;
    }
    try {
      final panel = snapshot.pages[pageIndex].panels.firstWhere(
        (candidate) => candidate.shape == 0,
        orElse: () => snapshot.pages[pageIndex].panels.first,
      );
      _snapshot = await rust.splitProjectPanel(
        handle: handle,
        pageIndex: pageIndex,
        panelId: panel.id,
        firstId: _newLocalId(),
        secondId: _newLocalId(),
        axis: axis,
        ratio: ratio.clamp(0.1, 0.9),
      );
      await _persist();
      await onPanelGeometryChanged?.call(_snapshot!);
      _error = null;
    } catch (error) {
      _error = error;
    }
    notifyListeners();
  }

  Future<void> resizeGutter({
    required int pageIndex,
    required BigInt panelId,
    required double gutterPx,
  }) async {
    final handle = _handle;
    if (handle == null) return;
    try {
      _snapshot = await rust.studioResizeGutter(
        handle: handle,
        pageIndex: pageIndex,
        panelId: panelId,
        gutterPx: gutterPx,
      );
      await _persist();
      _error = null;
    } catch (error) {
      _error = error;
    }
    notifyListeners();
  }

  Future<void> setDialogue({
    required int pageIndex,
    required BigInt balloonId,
    required String text,
  }) async {
    final handle = _handle;
    if (handle == null) return;
    try {
      _snapshot = await rust.studioSetDialogue(
        handle: handle,
        pageIndex: pageIndex,
        balloonId: balloonId,
        text: text,
      );
      await _persist();
      _error = null;
    } catch (error) {
      _error = error;
    }
    notifyListeners();
  }

  Future<void> setBalloonTail({
    required int pageIndex,
    required BigInt balloonId,
    required List<double> points,
  }) async {
    final handle = _handle;
    if (handle == null) return;
    try {
      _snapshot = await rust.studioSetBalloonTail(
        handle: handle,
        pageIndex: pageIndex,
        balloonId: balloonId,
        points: points,
      );
      await _persist();
      _error = null;
    } catch (error) {
      _error = error;
    }
    notifyListeners();
  }

  Future<void> setBalloonStyle({
    required int pageIndex,
    required BigInt balloonId,
    required String fontFamily,
    required double fontSizePx,
    required double outlinePx,
    required bool vertical,
  }) async {
    final handle = _handle;
    if (handle == null) return;
    try {
      _snapshot = await rust.studioSetBalloonStyle(
        handle: handle,
        pageIndex: pageIndex,
        balloonId: balloonId,
        fontFamily: fontFamily,
        fontSizePx: fontSizePx,
        outlinePx: outlinePx,
        orientation: vertical ? 1 : 0,
      );
      await _persist();
      _error = null;
    } catch (error) {
      _error = error;
    }
    notifyListeners();
  }

  Future<List<rust.ComicDialogueHitView>> searchDialogue(String query) async {
    final handle = _handle;
    if (handle == null || query.trim().isEmpty) return const [];
    try {
      return await rust.studioSearchDialogue(handle: handle, query: query);
    } catch (error) {
      _error = error;
      notifyListeners();
      return const [];
    }
  }

  Future<List<rust.ComicWebtoonSegmentView>> segmentsFor(
    int pageIndex, {
    int maxHeightPx = 2048,
  }) async {
    final handle = _handle;
    if (handle == null) return const [];
    try {
      return await rust.studioWebtoonSegments(
        handle: handle,
        pageIndex: pageIndex,
        maxHeightPx: maxHeightPx,
      );
    } catch (error) {
      _error = error;
      notifyListeners();
      return const [];
    }
  }

  Future<rust.ComicPrintPreviewView?> loadPrintPreview() async {
    final handle = _handle;
    if (handle == null) return null;
    try {
      _printPreview = await rust.studioPrintPreviewReport(handle: handle);
      _error = null;
    } catch (error) {
      _error = error;
    }
    notifyListeners();
    return _printPreview;
  }

  Future<Uint8List?> loadPagePreview(int pageIndex) async {
    final handle = _handle;
    if (handle == null) return null;
    try {
      _lastKnownPageIndex = pageIndex;
      _pagePreviewBytes = await rust.studioRenderPagePreview(
        handle: handle,
        pageIndex: pageIndex,
        maxDimension: 1024,
      );
      _pagePreviewIndex = pageIndex;
      _error = null;
    } catch (error) {
      _error = error;
      _pagePreviewBytes = null;
      _pagePreviewIndex = null;
    }
    notifyListeners();
    return _pagePreviewBytes;
  }

  Future<int?> batchExportPageManifests(String directory) async {
    final handle = _handle;
    if (handle == null || directory.trim().isEmpty) return null;
    try {
      final count = await rust.studioBatchExportPageManifests(
        handle: handle,
        directory: directory,
      );
      _error = null;
      notifyListeners();
      return count;
    } catch (error) {
      _error = error;
      notifyListeners();
      return null;
    }
  }

  Future<int?> batchExportPages(String directory) async {
    final handle = _handle;
    if (handle == null || directory.trim().isEmpty) return null;
    try {
      final count =
          _snapshot?.template == 2
              ? await rust.studioBatchExportWebtoonSegments(
                handle: handle,
                directory: directory,
                maxHeightPx: 2048,
              )
              : await rust.studioBatchExportPages(
                handle: handle,
                directory: directory,
              );
      _error = null;
      notifyListeners();
      return count;
    } catch (_) {
      _error = comicExportFailureMessage;
      notifyListeners();
      return null;
    }
  }

  Future<String?> portableDigest() async {
    final handle = _handle;
    if (handle == null) return null;
    try {
      final digest = await rust.studioProjectPortableDigest(handle: handle);
      _error = null;
      return digest;
    } catch (error) {
      _error = error;
      notifyListeners();
      return null;
    }
  }

  /// Atomically save the complete multi-page project. This is intentionally
  /// separate from the legacy metadata checkpoint callback used by older
  /// document hosts.
  Future<bool> saveProjectAs(String path) async {
    final handle = _handle;
    if (handle == null || path.trim().isEmpty) return false;
    try {
      await rust.saveProjectAs(handle: handle, path: path);
      _lastPersistedJson = Uint8List.fromList(
        await rust.studioProjectToJson(handle: handle),
      );
      _error = null;
      notifyListeners();
      return true;
    } catch (error) {
      _error = error;
      notifyListeners();
      return false;
    }
  }

  @override
  void dispose() {
    final handle = _handle;
    _handle = null;
    final pageNotification = onActivePageChanged?.call(null);
    if (pageNotification != null) unawaited(pageNotification);
    final projectNotification = onProjectChanged?.call(null);
    if (projectNotification != null) unawaited(projectNotification);
    if (handle != null) unawaited(rust.closeStudioProject(handle: handle));
    super.dispose();
  }
}

/// Compact touch-friendly comic navigator. It is intentionally usable beside
/// the canvas: page thumbnails, dialogue search, and webtoon segmentation are
/// visible without hiding the drawing surface behind a modal workflow.
class ComicWorkspace extends StatefulWidget {
  const ComicWorkspace({
    super.key,
    required this.controller,
    this.onClose,
    this.onBatchExport,
    this.onDrawInsidePanel,
  });

  final ComicWorkspaceController controller;
  final VoidCallback? onClose;
  final Future<void> Function()? onBatchExport;

  /// Activates the shared canvas selection mask for a panel. The canvas owns
  /// the actual pixels; this callback only communicates the user's intent.
  final Future<void> Function(int pageIndex, rust.ComicPanelPreviewView panel)?
  onDrawInsidePanel;

  @override
  State<ComicWorkspace> createState() => _ComicWorkspaceState();
}

class _ComicWorkspaceState extends State<ComicWorkspace> {
  final _searchController = TextEditingController();
  List<rust.ComicDialogueHitView> _hits = const [];
  List<rust.ComicWebtoonSegmentView> _segments = const [];
  rust.ComicPrintPreviewView? _printPreview;
  BigInt? _observedProjectId;
  int _selectedPageIndex = 0;
  _ComicInspectorSection _selectedInspectorSection =
      _ComicInspectorSection.page;
  bool _previewLoadInFlight = false;
  int? _pendingPreviewIndex;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    unawaited(widget.controller.ensureExampleLoaded());
  }

  @override
  void didUpdateWidget(covariant ComicWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
      unawaited(widget.controller.ensureExampleLoaded());
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _searchController.dispose();
    super.dispose();
  }

  void _changed() {
    final snapshot = widget.controller.snapshot;
    final projectId = snapshot?.id;
    if (projectId != _observedProjectId) {
      _observedProjectId = projectId;
      // These are projections of a specific project. Keeping them after a
      // template replacement or recovery would show stale segments, search
      // hits, and print warnings beside the new Rust-owned snapshot.
      _hits = const [];
      _segments = const [];
      _printPreview = null;
    }
    if (snapshot == null || snapshot.pages.isEmpty) {
      _selectedPageIndex = 0;
    } else if (_selectedPageIndex >= snapshot.pages.length) {
      _selectedPageIndex = snapshot.pages.length - 1;
    }
    _hits = _orderDialogueHits(_hits, snapshot);
    if (snapshot != null &&
        snapshot.pages.isNotEmpty &&
        widget.controller.error == null &&
        widget.controller.pagePreviewIndex != _selectedPageIndex) {
      unawaited(_refreshSelectedPagePreview(_selectedPageIndex));
    }
    if (mounted) setState(() {});
  }

  Future<void> _refreshSelectedPagePreview(int pageIndex) async {
    _pendingPreviewIndex = pageIndex;
    if (_previewLoadInFlight) return;
    _previewLoadInFlight = true;
    try {
      while (_pendingPreviewIndex != null && mounted) {
        final requestedIndex = _pendingPreviewIndex!;
        _pendingPreviewIndex = null;
        await widget.controller.loadPagePreview(requestedIndex);
        if (widget.controller.error != null) break;
      }
    } finally {
      _previewLoadInFlight = false;
    }
  }

  Future<void> _selectPage(int pageIndex) async {
    final snapshot = widget.controller.snapshot;
    if (snapshot == null ||
        pageIndex < 0 ||
        pageIndex >= snapshot.pages.length) {
      return;
    }
    setState(() => _selectedPageIndex = pageIndex);
    await widget.controller.activatePage(pageIndex);
    await _refreshSelectedPagePreview(pageIndex);
  }

  Future<void> _reorderPage(int from, int to) async {
    final snapshot = widget.controller.snapshot;
    if (snapshot == null ||
        from < 0 ||
        to < 0 ||
        from >= snapshot.pages.length ||
        to >= snapshot.pages.length ||
        from == to) {
      return;
    }
    await widget.controller.reorderPage(from, to);
    if (!mounted) return;
    setState(() {
      if (_selectedPageIndex == from) {
        _selectedPageIndex = to;
      } else if (from < _selectedPageIndex && to >= _selectedPageIndex) {
        _selectedPageIndex--;
      } else if (from > _selectedPageIndex && to <= _selectedPageIndex) {
        _selectedPageIndex++;
      }
    });
  }

  Future<void> _confirmRemovePage(int pageIndex) async {
    final snapshot = widget.controller.snapshot;
    if (snapshot == null || snapshot.pages.length <= 1) return;
    final selectedPageId =
        _selectedPageIndex < snapshot.pages.length
            ? snapshot.pages[_selectedPageIndex].id
            : snapshot.pages.first.id;
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('Remove page?'),
            content: const Text(
              'The page and its drawing layers will be removed from this project. You can undo this change.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Remove page'),
              ),
            ],
          ),
    );
    if (confirmed != true || !mounted) return;
    await widget.controller.removePage(pageIndex);
    final next = widget.controller.snapshot;
    if (!mounted ||
        next == null ||
        next.pages.length == snapshot.pages.length) {
      return;
    }
    final preservedIndex = next.pages.indexWhere(
      (page) => page.id == selectedPageId,
    );
    final nextIndex =
        preservedIndex >= 0
            ? preservedIndex
            : pageIndex.clamp(0, next.pages.length - 1);
    setState(() => _selectedPageIndex = nextIndex);
    await _refreshSelectedPagePreview(nextIndex);
  }

  Future<void> _search() async {
    final hits = await widget.controller.searchDialogue(_searchController.text);
    if (!mounted) return;
    final snapshot = widget.controller.snapshot;
    setState(() {
      _hits = _orderDialogueHits(hits, snapshot);
    });
  }

  List<rust.ComicDialogueHitView> _orderDialogueHits(
    Iterable<rust.ComicDialogueHitView> hits,
    rust.ComicProjectView? snapshot,
  ) {
    final pages = snapshot?.pages;
    if (pages == null || pages.isEmpty) return const [];
    final resolved = <(int, rust.ComicDialogueHitView)>[];
    for (final hit in hits) {
      final pageIndex = _pageIndexForBalloon(pages, hit.balloonId);
      if (pageIndex != null) resolved.add((pageIndex, hit));
    }
    resolved.sort((left, right) {
      final byPage = left.$1.compareTo(right.$1);
      if (byPage != 0) return byPage;
      final byStart = left.$2.matchStart.compareTo(right.$2.matchStart);
      if (byStart != 0) return byStart;
      return left.$2.balloonId.compareTo(right.$2.balloonId);
    });
    return resolved.map((entry) => entry.$2).toList(growable: false);
  }

  int? _pageIndexForBalloon(List<rust.ComicPageView> pages, BigInt balloonId) {
    for (var pageIndex = 0; pageIndex < pages.length; pageIndex++) {
      if (pages[pageIndex].balloons.any((balloon) => balloon.id == balloonId)) {
        return pageIndex;
      }
    }
    return null;
  }

  Future<void> _openDialogueHit(rust.ComicDialogueHitView hit) async {
    final pages = widget.controller.snapshot?.pages;
    if (pages == null) return;
    final pageIndex = _pageIndexForBalloon(pages, hit.balloonId);
    if (pageIndex == null) {
      await _search();
      return;
    }
    await _selectPage(pageIndex);
  }

  Future<void> _saveDialogueHit(
    rust.ComicDialogueHitView hit,
    String text,
  ) async {
    final pages = widget.controller.snapshot?.pages;
    if (pages == null) return;
    final pageIndex = _pageIndexForBalloon(pages, hit.balloonId);
    if (pageIndex == null) {
      await _search();
      return;
    }
    await widget.controller.setDialogue(
      pageIndex: pageIndex,
      balloonId: hit.balloonId,
      text: text,
    );
    if (mounted && widget.controller.error == null) await _search();
  }

  Future<void> _segmentSelectedPage() async {
    final snapshot = widget.controller.snapshot;
    if (snapshot == null || snapshot.pages.isEmpty) return;
    final pageIndex = _safeSelectedIndex(snapshot);
    final segments = await widget.controller.segmentsFor(pageIndex);
    if (mounted) setState(() => _segments = segments);
  }

  Future<void> _showPrintPreview() async {
    final snapshot = widget.controller.snapshot;
    final pageIndex =
        snapshot == null || snapshot.pages.isEmpty
            ? 0
            : _safeSelectedIndex(snapshot);
    await widget.controller.loadPagePreview(pageIndex);
    final report = await widget.controller.loadPrintPreview();
    if (mounted) setState(() => _printPreview = report);
  }

  Future<void> _showPortableDigest() async {
    final digest = await widget.controller.portableDigest();
    if (!mounted || digest == null) return;
    await showDialog<void>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Transfer fingerprint'),
            content: SelectableText(
              digest,
              semanticsLabel: 'Portable comic transfer fingerprint $digest',
            ),
            actions: [
              InkDialogAction(
                label: 'Close',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
    );
  }

  Future<void> _recoverProject() async {
    setState(() {
      _selectedPageIndex = 0;
      _hits = const [];
      _segments = const [];
      _printPreview = null;
    });
    await widget.controller.recoverPersistedProject();
  }

  Future<void> _closeProject() async {
    await widget.controller.closeProject();
    if (!mounted) return;
    setState(() {
      _selectedPageIndex = 0;
      _hits = const [];
      _segments = const [];
      _printPreview = null;
    });
  }

  int _safeSelectedIndex(rust.ComicProjectView snapshot) {
    if (snapshot.pages.isEmpty) return 0;
    return _selectedPageIndex.clamp(0, snapshot.pages.length - 1).toInt();
  }

  Future<void> _editDialogue(
    int pageIndex,
    rust.ComicBalloonPreviewView balloon,
  ) async {
    final text = await showDialog<String>(
      context: context,
      builder:
          (_) => _TextEntryDialog(
            title: 'Edit dialogue',
            initialText: balloon.text,
            labelText: 'Balloon text',
            autofocus: true,
            maxLines: 6,
            maxLength: 16 * 1024,
          ),
    );
    if (text == null || !mounted) return;
    await widget.controller.setDialogue(
      pageIndex: pageIndex,
      balloonId: balloon.id,
      text: text,
    );
  }

  Future<void> _editPanelPolygon(
    int pageIndex,
    rust.ComicPanelPreviewView panel,
  ) async {
    final fallback = <double>[
      panel.x,
      panel.y,
      panel.x + panel.width,
      panel.y,
      panel.x + panel.width,
      panel.y + panel.height,
      panel.x,
      panel.y + panel.height,
    ];
    final points = await showDialog<List<double>>(
      context: context,
      builder:
          (_) => _TextEntryDialog(
            title: 'Edit panel polygon',
            initialText: _tailText(
              panel.polygon.isEmpty ? fallback : panel.polygon,
            ),
            labelText: 'Vertices',
            hintText: 'x,y x,y x,y',
            helperText: 'Enter 3–32 coordinate pairs separated by spaces.',
            maxLines: 5,
            parse: (value) {
              final values = _parseCoordinatePairs(value);
              if (values == null || values.length < 6 || values.length > 64) {
                return null;
              }
              return values;
            },
          ),
    );
    if (!mounted || points == null) return;
    await widget.controller.setPanelPolygon(
      pageIndex: pageIndex,
      panelId: panel.id,
      points: points,
    );
  }

  Future<void> _editPanelBounds(
    int pageIndex,
    rust.ComicPanelPreviewView panel,
  ) async {
    final draft = await showDialog<_PanelBoundsDraft>(
      context: context,
      builder: (_) => _PanelBoundsDialog(panel: panel),
    );
    if (!mounted || draft == null) return;
    await widget.controller.setPanelBounds(
      pageIndex: pageIndex,
      panelId: panel.id,
      x: draft.x,
      y: draft.y,
      width: draft.width,
      height: draft.height,
    );
  }

  Future<void> _editPageLayout(int pageIndex, rust.ComicPageView page) async {
    final draft = await showDialog<_PageLayoutDraft>(
      context: context,
      builder: (_) => _PageLayoutDialog(page: page),
    );
    if (!mounted || draft == null) return;
    await widget.controller.setPageLayout(
      pageIndex: pageIndex,
      dpi: draft.dpi,
      bleedLeft: draft.bleedLeft,
      bleedTop: draft.bleedTop,
      bleedRight: draft.bleedRight,
      bleedBottom: draft.bleedBottom,
      trimX: draft.trimX,
      trimY: draft.trimY,
      trimWidth: draft.trimWidth,
      trimHeight: draft.trimHeight,
      safetyLeft: draft.safetyLeft,
      safetyTop: draft.safetyTop,
      safetyRight: draft.safetyRight,
      safetyBottom: draft.safetyBottom,
    );
  }

  Future<void> _editBalloonTail(
    int pageIndex,
    rust.ComicBalloonPreviewView balloon,
  ) async {
    final points = await showDialog<List<double>>(
      context: context,
      builder:
          (_) => _TextEntryDialog(
            title: 'Edit balloon tail',
            initialText: _tailText(balloon.tail),
            labelText: 'Points',
            hintText: 'x,y x,y',
            helperText: 'Enter up to 32 coordinate pairs separated by spaces.',
            maxLines: 3,
            parse: (value) {
              final values = _parseCoordinatePairs(value);
              return values == null || values.length > 64 ? null : values;
            },
          ),
    );
    if (!mounted || points == null) return;
    await widget.controller.setBalloonTail(
      pageIndex: pageIndex,
      balloonId: balloon.id,
      points: points,
    );
  }

  Future<void> _editBalloonStyle(
    int pageIndex,
    rust.ComicBalloonPreviewView balloon,
  ) async {
    final draft = await showDialog<_BalloonStyleDraft>(
      context: context,
      builder:
          (_) => _BalloonStyleDialog(
            family: balloon.fontFamily,
            sizePx: balloon.fontSizePx,
            outlinePx: balloon.outlinePx,
            vertical: balloon.orientation == 1,
          ),
    );
    if (!mounted || draft == null) return;
    await widget.controller.setBalloonStyle(
      pageIndex: pageIndex,
      balloonId: balloon.id,
      fontFamily: draft.family,
      fontSizePx: draft.fontSizePx,
      outlinePx: draft.outlinePx,
      vertical: draft.vertical,
    );
  }

  Future<void> _splitSelectedPanel() async {
    final draft = await showDialog<_PanelSplitDraft>(
      context: context,
      builder: (_) => const _PanelSplitDialog(),
    );
    if (!mounted || draft == null) return;
    final snapshot = widget.controller.snapshot;
    if (snapshot == null || snapshot.pages.isEmpty) return;
    await widget.controller.splitFirstPanel(
      pageIndex: _safeSelectedIndex(snapshot),
      axis: draft.axis,
      ratio: draft.ratio,
    );
  }

  Future<void> _addScreentone() async {
    final draft = await showDialog<_ToneDraft>(
      context: context,
      builder: (_) => const _ToneDialog(),
    );
    if (!mounted || draft == null) return;
    final snapshot = widget.controller.snapshot;
    if (snapshot == null || snapshot.pages.isEmpty) return;
    await widget.controller.addTone(
      pageIndex: _safeSelectedIndex(snapshot),
      shape: draft.shape,
      frequencyLpi: draft.frequencyLpi,
      angleDegrees: draft.angleDegrees,
      density: draft.density,
    );
  }

  Future<void> _editScreentone(
    int pageIndex,
    rust.ComicTonePreviewView tone,
  ) async {
    final draft = await showDialog<_ToneDraft>(
      context: context,
      builder:
          (_) => _ToneDialog(
            initial: _ToneDraft(
              shape: tone.shape,
              frequencyLpi: tone.frequencyLpi,
              angleDegrees: tone.angleDegrees,
              density: tone.density,
            ),
            editing: true,
          ),
    );
    if (!mounted || draft == null) return;
    await widget.controller.setTone(
      pageIndex: pageIndex,
      tone: tone,
      shape: draft.shape,
      frequencyLpi: draft.frequencyLpi,
      angleDegrees: draft.angleDegrees,
      density: draft.density,
    );
  }

  Future<void> _addEffectLine() async {
    final draft = await showDialog<_EffectLineDraft>(
      context: context,
      builder: (_) => const _EffectLineDialog(),
    );
    if (!mounted || draft == null) return;
    final snapshot = widget.controller.snapshot;
    if (snapshot == null || snapshot.pages.isEmpty) return;
    await widget.controller.addEffectLine(
      pageIndex: _safeSelectedIndex(snapshot),
      kind: draft.kind,
      widthPx: draft.widthPx,
      opacity: draft.opacity,
    );
  }

  Future<void> _editEffectLine(
    int pageIndex,
    rust.ComicEffectLinePreviewView line,
  ) async {
    final draft = await showDialog<_EffectLineDraft>(
      context: context,
      builder:
          (_) => _EffectLineDialog(
            initial: _EffectLineDraft(
              kind: line.kind,
              widthPx: line.widthPx,
              opacity: line.opacity,
            ),
            editing: true,
          ),
    );
    if (!mounted || draft == null) return;
    await widget.controller.setEffectLine(
      pageIndex: pageIndex,
      line: line,
      kind: draft.kind,
      widthPx: draft.widthPx,
      opacity: draft.opacity,
    );
  }

  Future<void> _addMaterial() async {
    final draft = await showDialog<_MaterialDraft>(
      context: context,
      builder: (_) => const _MaterialDialog(),
    );
    if (!mounted || draft == null) return;
    await widget.controller.addLocalMaterial(
      kind: draft.kind,
      name: draft.name,
      license: draft.license,
      attribution: draft.attribution,
      source: draft.source,
    );
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.controller.snapshot;
    final selectedIndex = snapshot == null ? 0 : _safeSelectedIndex(snapshot);
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              fit: FlexFit.loose,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    InkDockHeader(
                      title: snapshot?.title ?? 'Comic workspace',
                      subtitle:
                          snapshot == null
                              ? 'Loading example…'
                              : '${snapshot.pageCount} pages',
                      leading: const Icon(Icons.auto_stories),
                      actions: [
                        InkCommandButton(
                          label: 'Undo comic edit',
                          icon: Icons.undo,
                          onPressed:
                              widget.controller.canUndo
                                  ? () => unawaited(widget.controller.undo())
                                  : null,
                        ),
                        InkCommandButton(
                          label: 'Redo comic edit',
                          icon: Icons.redo,
                          onPressed:
                              widget.controller.canRedo
                                  ? () => unawaited(widget.controller.redo())
                                  : null,
                        ),
                        PopupMenuButton<String>(
                          tooltip: 'Project actions',
                          onSelected: (action) {
                            switch (action) {
                              case 'illustration':
                                setState(() => _selectedPageIndex = 0);
                                unawaited(widget.controller.createTemplate(0));
                              case 'printComic':
                                setState(() => _selectedPageIndex = 0);
                                unawaited(widget.controller.createTemplate(1));
                              case 'webtoon':
                                setState(() => _selectedPageIndex = 0);
                                unawaited(widget.controller.createTemplate(2));
                              case 'recover':
                                unawaited(_recoverProject());
                              case 'close':
                                unawaited(_closeProject());
                              case 'closeWorkspace':
                                widget.onClose?.call();
                            }
                          },
                          itemBuilder:
                              (context) => [
                                const PopupMenuItem(
                                  value: 'illustration',
                                  child: Text('New illustration'),
                                ),
                                const PopupMenuItem(
                                  value: 'printComic',
                                  child: Text('New print comic'),
                                ),
                                const PopupMenuItem(
                                  value: 'webtoon',
                                  child: Text('New webtoon'),
                                ),
                                const PopupMenuDivider(),
                                const PopupMenuItem(
                                  value: 'recover',
                                  child: Text('Recover saved project'),
                                ),
                                const PopupMenuItem(
                                  value: 'close',
                                  child: Text('Close project'),
                                ),
                                if (widget.onClose != null)
                                  const PopupMenuItem(
                                    value: 'closeWorkspace',
                                    child: Text('Close comic workspace'),
                                  ),
                              ],
                          icon: const Icon(Icons.more_horiz),
                        ),
                      ],
                    ),
                    if (widget.controller.userFacingError != null)
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          'Comic project error: ${widget.controller.userFacingError}',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    if (_hits.isNotEmpty) ...[
                      InkInspectorRow(
                        icon: const Icon(Icons.chat_bubble_outline),
                        title: '${_hits.length} dialogue matches',
                        subtitle:
                            _hits.length > 12
                                ? 'Showing the first 12 results; tap one to open its page.'
                                : 'Tap a result to open its page.',
                        selected: false,
                      ),
                      for (final hit in _hits.take(12))
                        _DialogueSearchResult(
                          hit: hit,
                          snapshot: snapshot,
                          onOpen: () => unawaited(_openDialogueHit(hit)),
                          onSave:
                              (text) => unawaited(_saveDialogueHit(hit, text)),
                        ),
                    ],
                    if (snapshot != null && snapshot.materials.isNotEmpty)
                      _MaterialsSummary(
                        materials: snapshot.materials,
                        onRemove:
                            (materialId) =>
                                widget.controller.removeMaterial(materialId),
                      ),
                    SizedBox(
                      height: 56,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          const sections = _ComicInspectorSection.values;
                          final visibleCount =
                              constraints.maxWidth < 480 ? 3 : sections.length;
                          final visible = sections.take(visibleCount);
                          final overflow = sections.skip(visibleCount);
                          return Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            child: Row(
                              children: [
                                for (final section in visible)
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.only(right: 4),
                                      child: Semantics(
                                        button: true,
                                        label: section.label,
                                        selected:
                                            section ==
                                            _selectedInspectorSection,
                                        onTap:
                                            () => setState(
                                              () =>
                                                  _selectedInspectorSection =
                                                      section,
                                            ),
                                        child: ExcludeSemantics(
                                          child: Tooltip(
                                            message: section.label,
                                            child: InkSelectableChip(
                                              label: section.compactLabel,
                                              selected:
                                                  section ==
                                                  _selectedInspectorSection,
                                              onPressed:
                                                  () => setState(
                                                    () =>
                                                        _selectedInspectorSection =
                                                            section,
                                                  ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                if (overflow.isNotEmpty)
                                  PopupMenuButton<_ComicInspectorSection>(
                                    tooltip: 'More comic sections',
                                    onSelected:
                                        (section) => setState(
                                          () =>
                                              _selectedInspectorSection =
                                                  section,
                                        ),
                                    itemBuilder:
                                        (context) => [
                                          for (final section in overflow)
                                            PopupMenuItem(
                                              value: section,
                                              child: Text(section.label),
                                            ),
                                        ],
                                    icon: const Icon(Icons.more_horiz),
                                  ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                    if (_selectedInspectorSection ==
                        _ComicInspectorSection.text)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _searchController,
                                onSubmitted: (_) => unawaited(_search()),
                                decoration: const InputDecoration(
                                  labelText: 'Search dialogue',
                                  prefixIcon: Icon(Icons.search),
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Search dialogue',
                              onPressed: _search,
                              icon: const Icon(Icons.arrow_forward),
                            ),
                          ],
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          if (_selectedInspectorSection ==
                              _ComicInspectorSection.page)
                            FilledButton.tonalIcon(
                              onPressed:
                                  snapshot == null
                                      ? null
                                      : () => unawaited(
                                        widget.controller.addPrintPage(),
                                      ),
                              icon: const Icon(Icons.note_add),
                              label: const Text('Page'),
                            ),
                          if (_selectedInspectorSection ==
                              _ComicInspectorSection.panel)
                            FilledButton.tonalIcon(
                              onPressed:
                                  snapshot == null
                                      ? null
                                      : () => unawaited(
                                        widget.controller.addPanel(
                                          pageIndex: _selectedPageIndex,
                                        ),
                                      ),
                              icon: const Icon(Icons.crop_square),
                              label: const Text('Panel'),
                            ),
                          if (_selectedInspectorSection ==
                              _ComicInspectorSection.text)
                            FilledButton.tonalIcon(
                              onPressed:
                                  snapshot == null
                                      ? null
                                      : () => unawaited(
                                        widget.controller.addBalloon(
                                          pageIndex: _selectedPageIndex,
                                        ),
                                      ),
                              icon: const Icon(Icons.chat_bubble_outline),
                              label: const Text('Balloon'),
                            ),
                          if (_selectedInspectorSection ==
                              _ComicInspectorSection.text)
                            PopupMenuButton<int>(
                              enabled: snapshot != null,
                              tooltip: 'Add balloon type',
                              icon: const Icon(Icons.forum_outlined),
                              onSelected:
                                  (shape) => unawaited(
                                    widget.controller.addBalloon(
                                      pageIndex: _selectedPageIndex,
                                      shape: shape,
                                    ),
                                  ),
                              itemBuilder:
                                  (context) => const [
                                    PopupMenuItem(
                                      value: 0,
                                      child: Text('Speech balloon'),
                                    ),
                                    PopupMenuItem(
                                      value: 1,
                                      child: Text('Thought balloon'),
                                    ),
                                    PopupMenuItem(
                                      value: 2,
                                      child: Text('Narration box'),
                                    ),
                                    PopupMenuItem(
                                      value: 3,
                                      child: Text('Burst balloon'),
                                    ),
                                  ],
                            ),
                          if (_selectedInspectorSection ==
                              _ComicInspectorSection.text)
                            FilledButton.tonalIcon(
                              onPressed:
                                  snapshot == null
                                      ? null
                                      : () => unawaited(
                                        widget.controller.addBalloon(
                                          pageIndex: _selectedPageIndex,
                                          shape: 2,
                                        ),
                                      ),
                              icon: const Icon(Icons.notes),
                              label: const Text('Narration'),
                            ),
                          if (_selectedInspectorSection ==
                              _ComicInspectorSection.text)
                            FilledButton.tonalIcon(
                              onPressed:
                                  snapshot == null
                                      ? null
                                      : () => unawaited(
                                        widget.controller.addBalloon(
                                          pageIndex: _selectedPageIndex,
                                          verticalText: true,
                                        ),
                                      ),
                              icon: const Icon(Icons.text_rotation_none),
                              label: const Text('Vertical text'),
                            ),
                          if (_selectedInspectorSection ==
                              _ComicInspectorSection.export)
                            FilledButton.tonalIcon(
                              onPressed:
                                  snapshot == null
                                      ? null
                                      : _segmentSelectedPage,
                              icon: const Icon(Icons.view_stream),
                              label: const Text('Webtoon segments'),
                            ),
                          if (_selectedInspectorSection ==
                              _ComicInspectorSection.export)
                            FilledButton.tonalIcon(
                              onPressed:
                                  snapshot == null ? null : _showPrintPreview,
                              icon: const Icon(Icons.print_outlined),
                              label: const Text('Print preview'),
                            ),
                          if (_selectedInspectorSection ==
                              _ComicInspectorSection.export)
                            FilledButton.tonalIcon(
                              onPressed:
                                  snapshot == null ? null : _showPortableDigest,
                              icon: const Icon(Icons.verified_outlined),
                              label: const Text('Transfer check'),
                            ),
                          if (_selectedInspectorSection ==
                              _ComicInspectorSection.export)
                            FilledButton.tonalIcon(
                              onPressed:
                                  snapshot == null ||
                                          widget.onBatchExport == null
                                      ? null
                                      : () =>
                                          unawaited(widget.onBatchExport!()),
                              icon: const Icon(Icons.file_download_outlined),
                              label: Text(
                                snapshot?.template == 2
                                    ? 'Export webtoon segments'
                                    : 'Export pages (PNG + SVG)',
                              ),
                            ),
                          if (_selectedInspectorSection ==
                              _ComicInspectorSection.panel)
                            FilledButton.tonalIcon(
                              onPressed:
                                  snapshot == null
                                      ? null
                                      : () => unawaited(
                                        widget.controller.makeFirstPanelPolygon(
                                          pageIndex: _selectedPageIndex,
                                        ),
                                      ),
                              icon: const Icon(Icons.polyline_outlined),
                              label: const Text('Polygon panel'),
                            ),
                          if (_selectedInspectorSection ==
                              _ComicInspectorSection.toneEffects)
                            FilledButton.tonalIcon(
                              onPressed:
                                  snapshot == null
                                      ? null
                                      : () => unawaited(_addScreentone()),
                              icon: const Icon(Icons.grain),
                              label: const Text('Screentone'),
                            ),
                          if (_selectedInspectorSection ==
                              _ComicInspectorSection.toneEffects)
                            FilledButton.tonalIcon(
                              onPressed:
                                  snapshot == null
                                      ? null
                                      : () => unawaited(_addEffectLine()),
                              icon: const Icon(Icons.speed),
                              label: const Text('Effect lines'),
                            ),
                          if (_selectedInspectorSection ==
                              _ComicInspectorSection.panel)
                            FilledButton.tonalIcon(
                              onPressed:
                                  snapshot == null
                                      ? null
                                      : () => unawaited(_splitSelectedPanel()),
                              icon: const Icon(Icons.call_split),
                              label: const Text('Split panel'),
                            ),
                          if (_selectedInspectorSection ==
                              _ComicInspectorSection.export)
                            PopupMenuButton<String>(
                              enabled: snapshot != null,
                              tooltip: 'Add local material',
                              icon: const Icon(
                                Icons.collections_bookmark_outlined,
                              ),
                              onSelected: (_) => unawaited(_addMaterial()),
                              itemBuilder:
                                  (context) => const [
                                    PopupMenuItem(
                                      value: 'edit',
                                      child: Text('Add material…'),
                                    ),
                                  ],
                            ),
                        ],
                      ),
                    ),
                    if (_segments.isNotEmpty)
                      _WebtoonSegmentsSummary(segments: _segments),
                    if (_printPreview != null)
                      _PrintPreviewSummary(
                        report: _printPreview!,
                        previewBytes: widget.controller.pagePreviewBytes,
                        page:
                            snapshot?.pages.isNotEmpty == true
                                ? snapshot!.pages[selectedIndex]
                                : null,
                      ),
                    if (snapshot != null &&
                        snapshot.pages.isNotEmpty &&
                        _selectedInspectorSection !=
                            _ComicInspectorSection.export)
                      _ComicPageInspector(
                        pageIndex: selectedIndex,
                        section: _selectedInspectorSection,
                        page: snapshot.pages[selectedIndex],
                        controller: widget.controller,
                        onEditPageLayout: _editPageLayout,
                        onEditPanelBounds: _editPanelBounds,
                        onEditDialogue: _editDialogue,
                        onEditPanelPolygon: _editPanelPolygon,
                        onDrawInsidePanel: widget.onDrawInsidePanel,
                        onEditBalloonTail: _editBalloonTail,
                        onEditBalloonStyle: _editBalloonStyle,
                        onEditTone: _editScreentone,
                        onRemoveTone:
                            (pageIndex, tone) => widget.controller.removeTone(
                              pageIndex: pageIndex,
                              toneId: tone.id,
                            ),
                        onEditEffectLine: _editEffectLine,
                        onRemoveEffectLine:
                            (pageIndex, line) =>
                                widget.controller.removeEffectLine(
                                  pageIndex: pageIndex,
                                  effectId: line.id,
                                ),
                        previewBytes: widget.controller.pagePreviewBytes,
                        previewPageIndex: widget.controller.pagePreviewIndex,
                      ),
                  ],
                ),
              ),
            ),
            Expanded(
              child:
                  snapshot == null
                      ? Center(
                        child:
                            widget.controller.loading
                                ? const CircularProgressIndicator()
                                : SingleChildScrollView(
                                  padding: const EdgeInsets.all(24),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      const Icon(
                                        Icons.auto_stories_outlined,
                                        size: 48,
                                      ),
                                      const SizedBox(height: 12),
                                      Text(
                                        'No comic project open',
                                        textAlign: TextAlign.center,
                                        style:
                                            Theme.of(
                                              context,
                                            ).textTheme.titleMedium,
                                      ),
                                      const SizedBox(height: 12),
                                      FilledButton.tonalIcon(
                                        onPressed:
                                            () => unawaited(
                                              widget.controller.createTemplate(
                                                1,
                                              ),
                                            ),
                                        icon: const Icon(Icons.menu_book),
                                        label: const Text('New print comic'),
                                      ),
                                      FilledButton.tonalIcon(
                                        onPressed:
                                            () => unawaited(
                                              widget.controller.createTemplate(
                                                2,
                                              ),
                                            ),
                                        icon: const Icon(Icons.view_stream),
                                        label: const Text('New webtoon'),
                                      ),
                                      OutlinedButton.icon(
                                        onPressed:
                                            () => unawaited(_recoverProject()),
                                        icon: const Icon(Icons.restore),
                                        label: const Text(
                                          'Recover saved project',
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                      )
                      : ReorderableListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: snapshot.pages.length,
                        onReorderItem: (from, to) {
                          unawaited(_reorderPage(from, to));
                        },
                        itemBuilder: (context, index) {
                          final page = snapshot.pages[index];
                          return Padding(
                            key: ValueKey(page.id),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            child: InkInspectorRow(
                              selected: index == _selectedPageIndex,
                              onTap: () => unawaited(_selectPage(index)),
                              icon: _ComicPageThumbnail(page: page),
                              title:
                                  'Page ${page.pageNumber} • ${page.widthPx}×${page.heightPx} @ ${page.dpi.round()} DPI',
                              subtitle:
                                  '${page.panelCount} panels • ${page.balloonCount} balloons • ${page.toneCount} tones',
                              trailing: Wrap(
                                spacing: 0,
                                children: [
                                  InkCommandButton(
                                    icon: Icons.arrow_upward,
                                    label: 'Move page up',
                                    onPressed:
                                        index == 0
                                            ? null
                                            : () => unawaited(
                                              _reorderPage(index, index - 1),
                                            ),
                                  ),
                                  InkCommandButton(
                                    icon: Icons.arrow_downward,
                                    label: 'Move page down',
                                    onPressed:
                                        index == snapshot.pages.length - 1
                                            ? null
                                            : () => unawaited(
                                              _reorderPage(index, index + 1),
                                            ),
                                  ),
                                  InkCommandButton(
                                    icon: Icons.delete_outline,
                                    label: 'Remove page',
                                    onPressed:
                                        snapshot.pages.length <= 1
                                            ? null
                                            : () => unawaited(
                                              _confirmRemovePage(index),
                                            ),
                                  ),
                                  const Icon(Icons.drag_handle),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DialogueSearchResult extends StatefulWidget {
  const _DialogueSearchResult({
    required this.hit,
    required this.snapshot,
    required this.onOpen,
    required this.onSave,
  });

  final rust.ComicDialogueHitView hit;
  final rust.ComicProjectView? snapshot;
  final VoidCallback onOpen;
  final ValueChanged<String> onSave;

  @override
  State<_DialogueSearchResult> createState() => _DialogueSearchResultState();
}

class _DialogueSearchResultState extends State<_DialogueSearchResult> {
  late final TextEditingController _textController;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: _balloon?.text ?? '');
  }

  @override
  void didUpdateWidget(covariant _DialogueSearchResult oldWidget) {
    super.didUpdateWidget(oldWidget);
    final latestText = _balloon?.text ?? '';
    final previousText =
        _findBalloon(oldWidget.snapshot, oldWidget.hit.balloonId)?.text;
    if (previousText != latestText && _textController.text == previousText) {
      _textController.value = TextEditingValue(
        text: latestText,
        selection: TextSelection.collapsed(offset: latestText.length),
      );
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final balloon = _balloonForHit();
    final pageIndex = _resolvedPageIndex;
    if (balloon == null || pageIndex == null) {
      return const InkInspectorRow(
        icon: Icon(Icons.warning_amber_outlined, size: 18),
        title: 'Dialogue result is no longer available',
        subtitle: 'Search again to refresh the script list.',
        selected: false,
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkInspectorRow(
            icon: const Icon(Icons.subdirectory_arrow_right, size: 18),
            title: 'Page ${pageIndex + 1} • Balloon ${balloon.id}',
            subtitle:
                'Match ${widget.hit.matchStart + 1}–${widget.hit.matchEnd}',
            selected: false,
            onTap: widget.onOpen,
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  key: ValueKey('script-line-${balloon.id}'),
                  controller: _textController,
                  minLines: 1,
                  maxLines: 3,
                  maxLength: 16 * 1024,
                  decoration: InputDecoration(
                    labelText: 'Page ${pageIndex + 1} dialogue',
                    isDense: true,
                    counterText: '',
                  ),
                  onSubmitted: widget.onSave,
                ),
              ),
              IconButton(
                tooltip: 'Save dialogue on page ${pageIndex + 1}',
                onPressed: () => widget.onSave(_textController.text),
                icon: const Icon(Icons.save_outlined),
              ),
            ],
          ),
        ],
      ),
    );
  }

  rust.ComicBalloonPreviewView? get _balloon => _balloonForHit();

  int? get _resolvedPageIndex {
    final pages = widget.snapshot?.pages;
    if (pages == null) return null;
    for (var index = 0; index < pages.length; index++) {
      if (pages[index].balloons.any(
        (balloon) => balloon.id == widget.hit.balloonId,
      )) {
        return index;
      }
    }
    return null;
  }

  rust.ComicBalloonPreviewView? _balloonForHit() {
    return _findBalloon(widget.snapshot, widget.hit.balloonId);
  }

  rust.ComicBalloonPreviewView? _findBalloon(
    rust.ComicProjectView? snapshot,
    BigInt balloonId,
  ) {
    final pages = snapshot?.pages;
    if (pages == null) return null;
    for (final page in pages) {
      for (final balloon in page.balloons) {
        if (balloon.id == balloonId) return balloon;
      }
    }
    return null;
  }
}

class _WebtoonSegmentsSummary extends StatelessWidget {
  const _WebtoonSegmentsSummary({required this.segments});

  final List<rust.ComicWebtoonSegmentView> segments;

  @override
  Widget build(BuildContext context) {
    const visibleLimit = 16;
    final visible = segments.take(visibleLimit).toList(growable: false);
    return InkPanelSurface(
      padding: EdgeInsets.zero,
      child: InkInspectorSection(
        title: '${segments.length} webtoon segments',
        leading: const Icon(Icons.view_stream),
        initiallyExpanded: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final segment in visible)
              InkInspectorRow(
                icon: const Icon(Icons.crop_free, size: 18),
                title: 'Segment ${segment.segmentIndex + 1}',
                subtitle:
                    'Source y ${segment.sourceY} • ${segment.heightPx}px high',
                selected: false,
              ),
            if (segments.length > visibleLimit)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'Showing the first $visibleLimit slices; export includes all ${segments.length}.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ComicPageThumbnail extends StatelessWidget {
  const _ComicPageThumbnail({required this.page});

  final rust.ComicPageView page;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 54,
      height: 72,
      child: CustomPaint(
        painter: _ComicThumbnailPainter(page: page),
        child: Center(
          child: Text(
            '${page.pageNumber}',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Colors.black54,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}

class _ComicPageInspector extends StatelessWidget {
  const _ComicPageInspector({
    required this.pageIndex,
    required this.section,
    required this.page,
    required this.controller,
    required this.onEditPageLayout,
    required this.onEditPanelBounds,
    this.onDrawInsidePanel,
    required this.onEditDialogue,
    required this.onEditPanelPolygon,
    required this.onEditBalloonTail,
    required this.onEditBalloonStyle,
    required this.onEditTone,
    required this.onRemoveTone,
    required this.onEditEffectLine,
    required this.onRemoveEffectLine,
    this.previewBytes,
    this.previewPageIndex,
  });

  final int pageIndex;
  final _ComicInspectorSection section;
  final rust.ComicPageView page;
  final ComicWorkspaceController controller;
  final Future<void> Function(int pageIndex, rust.ComicPageView page)
  onEditPageLayout;
  final Future<void> Function(int pageIndex, rust.ComicPanelPreviewView panel)
  onEditPanelBounds;
  final Future<void> Function(int pageIndex, rust.ComicPanelPreviewView panel)?
  onDrawInsidePanel;
  final Future<void> Function(
    int pageIndex,
    rust.ComicBalloonPreviewView balloon,
  )
  onEditDialogue;
  final Future<void> Function(int pageIndex, rust.ComicPanelPreviewView panel)
  onEditPanelPolygon;
  final Future<void> Function(
    int pageIndex,
    rust.ComicBalloonPreviewView balloon,
  )
  onEditBalloonTail;
  final Future<void> Function(
    int pageIndex,
    rust.ComicBalloonPreviewView balloon,
  )
  onEditBalloonStyle;
  final Future<void> Function(int pageIndex, rust.ComicTonePreviewView tone)
  onEditTone;
  final Future<void> Function(int pageIndex, rust.ComicTonePreviewView tone)
  onRemoveTone;
  final Future<void> Function(
    int pageIndex,
    rust.ComicEffectLinePreviewView line,
  )
  onEditEffectLine;
  final Future<void> Function(
    int pageIndex,
    rust.ComicEffectLinePreviewView line,
  )
  onRemoveEffectLine;
  final Uint8List? previewBytes;
  final int? previewPageIndex;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: InkPanelSurface(
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkDockHeader(
              title: 'Edit page ${page.pageNumber}',
              subtitle: 'Page, panel, text, and tone settings stay editable',
              leading: const Icon(Icons.tune),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (section == _ComicInspectorSection.page)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      child: SizedBox(
                        height: 220,
                        width: double.infinity,
                        child:
                            previewBytes != null &&
                                    previewPageIndex == pageIndex
                                ? Image.memory(
                                  previewBytes!,
                                  fit: BoxFit.contain,
                                  gaplessPlayback: true,
                                  semanticLabel:
                                      'Rendered page ${page.pageNumber} preview',
                                )
                                : CustomPaint(
                                  painter: _ComicPageCanvasPainter(page: page),
                                ),
                      ),
                    ),
                  if (section == _ComicInspectorSection.page)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        child: InkMenuItem(
                          label: 'Page settings',
                          icon: Icons.straighten,
                          onPressed: () => onEditPageLayout(pageIndex, page),
                        ),
                      ),
                    ),
                  if (section == _ComicInspectorSection.panel)
                    for (final panel in page.panels)
                      Column(
                        key: ValueKey('panel-editor-${panel.id}'),
                        children: [
                          InkInspectorRow(
                            selected: false,
                            icon: Icon(
                              panel.shape == 1
                                  ? Icons.polyline_outlined
                                  : Icons.crop_square,
                            ),
                            title:
                                'Panel ${page.panels.indexOf(panel) + 1} • ${panel.shape == 1 ? 'polygon' : 'rectangle'}',
                            subtitle:
                                panel.maskLayerId == null
                                    ? null
                                    : 'Linked mask',
                            trailing: Wrap(
                              spacing: 0,
                              children: [
                                if (onDrawInsidePanel != null)
                                  InkCommandButton(
                                    label: 'Draw inside panel',
                                    icon: Icons.draw_outlined,
                                    onPressed:
                                        () => onDrawInsidePanel!(
                                          pageIndex,
                                          panel,
                                        ),
                                  ),
                                if (panel.shape == 0)
                                  InkCommandButton(
                                    label: 'Edit panel bounds',
                                    icon: Icons.open_with,
                                    onPressed:
                                        () =>
                                            onEditPanelBounds(pageIndex, panel),
                                  ),
                                InkCommandButton(
                                  label: 'Edit panel polygon',
                                  icon: Icons.edit_location_alt_outlined,
                                  onPressed:
                                      () =>
                                          onEditPanelPolygon(pageIndex, panel),
                                ),
                              ],
                            ),
                          ),
                          _GutterSlider(
                            panel: panel,
                            onChanged:
                                (value) => controller.resizeGutter(
                                  pageIndex: pageIndex,
                                  panelId: panel.id,
                                  gutterPx: value,
                                ),
                          ),
                        ],
                      ),
                  if (section == _ComicInspectorSection.text)
                    for (final balloon in page.balloons)
                      InkInspectorRow(
                        selected: false,
                        icon: Icon(
                          balloon.shape == 2
                              ? Icons.notes
                              : balloon.orientation == 1
                              ? Icons.text_rotation_none
                              : Icons.chat_bubble_outline,
                        ),
                        title:
                            balloon.text.isEmpty
                                ? '(empty dialogue)'
                                : balloon.text,
                        subtitle:
                            '${_balloonShapeName(balloon.shape)} • ${balloon.orientation == 1 ? 'vertical' : 'horizontal'} text',
                        trailing: Wrap(
                          spacing: 0,
                          children: [
                            InkCommandButton(
                              label: 'Edit dialogue',
                              icon: Icons.edit_outlined,
                              onPressed:
                                  () => onEditDialogue(pageIndex, balloon),
                            ),
                            InkCommandButton(
                              label: 'Edit balloon tail',
                              icon: Icons.timeline_outlined,
                              onPressed:
                                  () => onEditBalloonTail(pageIndex, balloon),
                            ),
                            InkCommandButton(
                              label: 'Edit balloon style',
                              icon: Icons.text_fields,
                              onPressed:
                                  () => onEditBalloonStyle(pageIndex, balloon),
                            ),
                          ],
                        ),
                      ),
                  if (section == _ComicInspectorSection.toneEffects)
                    for (final tone in page.tones)
                      InkInspectorRow(
                        key: ValueKey('tone-editor-${tone.id}'),
                        selected: false,
                        icon: const Icon(Icons.grain),
                        title: '${_toneShapeName(tone.shape)} screentone',
                        subtitle:
                            '${tone.frequencyLpi.round()} LPI • ${tone.angleDegrees.round()}° • ${(tone.density * 100).round()}% density',
                        trailing: Wrap(
                          spacing: 0,
                          children: [
                            InkCommandButton(
                              label: 'Edit screentone',
                              icon: Icons.tune,
                              onPressed: () => onEditTone(pageIndex, tone),
                            ),
                            InkCommandButton(
                              label: 'Remove screentone',
                              icon: Icons.delete_outline,
                              onPressed: () => onRemoveTone(pageIndex, tone),
                            ),
                          ],
                        ),
                      ),
                  if (section == _ComicInspectorSection.toneEffects)
                    for (final line in page.effectLines)
                      InkInspectorRow(
                        key: ValueKey('effect-editor-${line.id}'),
                        selected: false,
                        icon: const Icon(Icons.speed),
                        title: '${_effectLineKindName(line.kind)} effect lines',
                        subtitle:
                            '${line.widthPx.toStringAsFixed(1)} px • ${(line.opacity * 100).round()}% opacity',
                        trailing: Wrap(
                          spacing: 0,
                          children: [
                            InkCommandButton(
                              label: 'Edit effect lines',
                              icon: Icons.tune,
                              onPressed:
                                  () => onEditEffectLine(pageIndex, line),
                            ),
                            InkCommandButton(
                              label: 'Remove effect lines',
                              icon: Icons.delete_outline,
                              onPressed:
                                  () => onRemoveEffectLine(pageIndex, line),
                            ),
                          ],
                        ),
                      ),
                  if (section == _ComicInspectorSection.panel &&
                      page.panels.isNotEmpty)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: InkCommandButton(
                        label: 'Make first panel polygonal',
                        icon: Icons.polyline_outlined,
                        onPressed:
                            () => controller.makeFirstPanelPolygon(
                              pageIndex: pageIndex,
                            ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ComicPageCanvasPainter extends CustomPainter {
  const _ComicPageCanvasPainter({required this.page});

  final rust.ComicPageView page;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xfff7f7f5),
    );
    if (page.widthPx <= 0 || page.heightPx <= 0) return;
    final scale = math.min(
      (size.width - 8) / page.widthPx,
      (size.height - 8) / page.heightPx,
    );
    canvas.save();
    canvas.translate((size.width - page.widthPx * scale) / 2, 4);
    canvas.scale(scale, scale);
    final panelFill = Paint()..color = const Color.fromRGBO(55, 100, 160, .12);
    final panelBorder =
        Paint()
          ..color = const Color(0xff234f7d)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4 / scale;
    final balloonFill = Paint()..color = const Color(0xeeffffff);
    final balloonBorder =
        Paint()
          ..color = const Color(0xff252525)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3 / scale;
    final guide =
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 / scale;
    guide.color = const Color(0xff2563eb);
    canvas.drawRect(
      Rect.fromLTWH(page.trimX, page.trimY, page.trimWidth, page.trimHeight),
      guide,
    );
    guide.color = const Color(0xffd97706);
    canvas.drawRect(
      Rect.fromLTWH(
        page.trimX + page.safetyLeft,
        page.trimY + page.safetyTop,
        page.trimWidth - page.safetyLeft - page.safetyRight,
        page.trimHeight - page.safetyTop - page.safetyBottom,
      ),
      guide,
    );
    for (final panel in page.panels) {
      final rect = Rect.fromLTWH(panel.x, panel.y, panel.width, panel.height);
      canvas.drawRect(rect, panelFill);
      if (panel.shape == 1 && panel.polygon.length >= 6) {
        final path = Path()..moveTo(panel.polygon[0], panel.polygon[1]);
        for (var i = 2; i + 1 < panel.polygon.length; i += 2) {
          path.lineTo(panel.polygon[i], panel.polygon[i + 1]);
        }
        path.close();
        canvas.drawPath(path, panelBorder);
      } else {
        canvas.drawRect(rect, panelBorder);
      }
    }
    Path burstPath(Rect rect) {
      final path = Path();
      final center = rect.center;
      for (var index = 0; index < 24; index++) {
        final angle = index * math.pi * 2 / 24 - math.pi / 2;
        final radiusX = (index.isEven ? rect.width : rect.width * .68) / 2;
        final radiusY = (index.isEven ? rect.height : rect.height * .68) / 2;
        final point = Offset(
          center.dx + radiusX * math.cos(angle),
          center.dy + radiusY * math.sin(angle),
        );
        if (index == 0) {
          path.moveTo(point.dx, point.dy);
        } else {
          path.lineTo(point.dx, point.dy);
        }
      }
      return path..close();
    }

    for (final balloon in page.balloons) {
      final rect = Rect.fromLTWH(
        balloon.x,
        balloon.y,
        balloon.width,
        balloon.height,
      );
      if (balloon.tail.length >= 4) {
        final tail = Path()..moveTo(balloon.tail[0], balloon.tail[1]);
        for (var i = 2; i + 1 < balloon.tail.length; i += 2) {
          tail.lineTo(balloon.tail[i], balloon.tail[i + 1]);
        }
        canvas.drawPath(tail, balloonBorder);
      }
      if (balloon.shape == 2) {
        final rounded = RRect.fromRectAndRadius(
          rect,
          const Radius.circular(12),
        );
        canvas.drawRRect(rounded, balloonFill);
        canvas.drawRRect(rounded, balloonBorder);
      } else if (balloon.shape == 1) {
        canvas.drawOval(rect, balloonFill);
        canvas.drawOval(rect, balloonBorder);
        final minDimension = math.min(rect.width, rect.height);
        final bubbleOne = Rect.fromCircle(
          center: Offset(
            rect.left + rect.width * .2,
            rect.bottom + minDimension * .08,
          ),
          radius: math.max(4, minDimension * .07),
        );
        final bubbleTwo = Rect.fromCircle(
          center: Offset(
            rect.left + rect.width * .1,
            rect.bottom + minDimension * .17,
          ),
          radius: math.max(3, minDimension * .045),
        );
        for (final bubble in [bubbleOne, bubbleTwo]) {
          canvas.drawOval(bubble, balloonFill);
          canvas.drawOval(bubble, balloonBorder);
        }
      } else if (balloon.shape == 3) {
        final burst = burstPath(rect);
        canvas.drawPath(burst, balloonFill);
        canvas.drawPath(burst, balloonBorder);
      } else {
        canvas.drawOval(rect, balloonFill);
        canvas.drawOval(rect, balloonBorder);
      }
      final previewText =
          balloon.text.length > 80
              ? '${balloon.text.substring(0, 80)}…'
              : balloon.text;
      final textPainter = TextPainter(
        text: TextSpan(
          text: previewText,
          style: const TextStyle(color: Colors.black, fontSize: 26),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 3,
        ellipsis: '…',
      )..layout(maxWidth: (rect.width - 24).clamp(1, 2000).toDouble());
      textPainter.paint(
        canvas,
        Offset(
          rect.center.dx - textPainter.width / 2,
          rect.center.dy - textPainter.height / 2,
        ),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ComicPageCanvasPainter oldDelegate) =>
      oldDelegate.page != page;
}

class _GutterSlider extends StatefulWidget {
  const _GutterSlider({required this.panel, required this.onChanged});

  final rust.ComicPanelPreviewView panel;
  final Future<void> Function(double value) onChanged;

  @override
  State<_GutterSlider> createState() => _GutterSliderState();
}

class _GutterSliderState extends State<_GutterSlider> {
  late double _value = widget.panel.gutterPx;

  @override
  void didUpdateWidget(covariant _GutterSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.panel.gutterPx != widget.panel.gutterPx) {
      _value = widget.panel.gutterPx;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: InkPropertySlider(
        label: 'Panel gutter',
        value: _value,
        min: 0,
        max: 256,
        divisions: 64,
        valueLabel: '${_value.round()} px',
        onChanged: (value) => setState(() => _value = value),
        onChangeEnd: widget.onChanged,
      ),
    );
  }
}

String _balloonShapeName(int shape) => switch (shape) {
  1 => 'thought balloon',
  2 => 'narration box',
  3 => 'burst balloon',
  _ => 'speech balloon',
};

String _toneShapeName(String shape) => switch (shape) {
  'line' => 'Line',
  'noise' => 'Noise',
  _ => 'Circle-dot',
};

String _effectLineKindName(String kind) => switch (kind) {
  'focus' => 'Focus',
  'radial' => 'Radial',
  _ => 'Speed',
};

String _tailText(List<double> points) {
  final values = <String>[];
  for (var index = 0; index + 1 < points.length; index += 2) {
    values.add('${points[index]},${points[index + 1]}');
  }
  return values.join(' ');
}

List<double>? _parseCoordinatePairs(String input) {
  final values = <double>[];
  final tokens = input
      .replaceAll(';', ' ')
      .split(RegExp(r'\s+'))
      .where((token) => token.trim().isNotEmpty);
  for (final token in tokens) {
    final pair = token.split(',');
    if (pair.length != 2) return null;
    final x = double.tryParse(pair[0]);
    final y = double.tryParse(pair[1]);
    if (x == null || y == null || !x.isFinite || !y.isFinite) return null;
    values
      ..add(x)
      ..add(y);
  }
  return values;
}

/// Owns its editing controller for the full lifetime of the dialog route.
/// Disposing controllers in the caller immediately after `showDialog` can
/// race the route's reverse animation and make Flutter rebuild a TextField
/// with a disposed controller.
class _TextEntryDialog extends StatefulWidget {
  const _TextEntryDialog({
    required this.title,
    required this.initialText,
    required this.labelText,
    this.hintText,
    this.helperText,
    this.autofocus = false,
    this.maxLines = 1,
    this.maxLength,
    this.parse,
  });

  final String title;
  final String initialText;
  final String labelText;
  final String? hintText;
  final String? helperText;
  final bool autofocus;
  final int maxLines;
  final int? maxLength;
  final Object? Function(String value)? parse;

  @override
  State<_TextEntryDialog> createState() => _TextEntryDialogState();
}

class _TextEntryDialogState extends State<_TextEntryDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final parser = widget.parse;
    final Object? value =
        parser == null ? _controller.text : parser(_controller.text);
    if (value == null) return;
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: widget.autofocus,
        maxLines: widget.maxLines,
        maxLength: widget.maxLength,
        decoration: InputDecoration(
          labelText: widget.labelText,
          hintText: widget.hintText,
          helperText: widget.helperText,
        ),
      ),
      actions: [
        InkDialogAction(
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
        ),
        InkDialogAction(label: 'Save', onPressed: _save, primary: true),
      ],
    );
  }
}

class _PanelBoundsDraft {
  const _PanelBoundsDraft({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final double x;
  final double y;
  final double width;
  final double height;
}

class _PanelBoundsDialog extends StatefulWidget {
  const _PanelBoundsDialog({required this.panel});

  final rust.ComicPanelPreviewView panel;

  @override
  State<_PanelBoundsDialog> createState() => _PanelBoundsDialogState();
}

class _PanelBoundsDialogState extends State<_PanelBoundsDialog> {
  late final TextEditingController _x;
  late final TextEditingController _y;
  late final TextEditingController _width;
  late final TextEditingController _height;
  String? _error;

  @override
  void initState() {
    super.initState();
    _x = _controller(widget.panel.x);
    _y = _controller(widget.panel.y);
    _width = _controller(widget.panel.width);
    _height = _controller(widget.panel.height);
  }

  TextEditingController _controller(double value) =>
      TextEditingController(text: value.toStringAsFixed(1));

  @override
  void dispose() {
    _x.dispose();
    _y.dispose();
    _width.dispose();
    _height.dispose();
    super.dispose();
  }

  void _save() {
    final values = [_x, _y, _width, _height]
        .map((controller) => double.tryParse(controller.text.trim()))
        .toList(growable: false);
    if (values.any((value) => value == null || !value.isFinite) ||
        values[2]! <= 0 ||
        values[3]! <= 0) {
      setState(
        () => _error = 'Use finite coordinates and positive dimensions.',
      );
      return;
    }
    Navigator.of(context).pop(
      _PanelBoundsDraft(
        x: values[0]!,
        y: values[1]!,
        width: values[2]!,
        height: values[3]!,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit panel bounds'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _x,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(labelText: 'X'),
            ),
            TextField(
              controller: _y,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(labelText: 'Y'),
            ),
            TextField(
              controller: _width,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(labelText: 'Width'),
            ),
            TextField(
              controller: _height,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(labelText: 'Height'),
            ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        InkDialogAction(
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
        ),
        InkDialogAction(label: 'Save bounds', onPressed: _save, primary: true),
      ],
    );
  }
}

class _PageLayoutDraft {
  const _PageLayoutDraft({
    required this.dpi,
    required this.bleedLeft,
    required this.bleedTop,
    required this.bleedRight,
    required this.bleedBottom,
    required this.trimX,
    required this.trimY,
    required this.trimWidth,
    required this.trimHeight,
    required this.safetyLeft,
    required this.safetyTop,
    required this.safetyRight,
    required this.safetyBottom,
  });

  final double dpi;
  final double bleedLeft;
  final double bleedTop;
  final double bleedRight;
  final double bleedBottom;
  final double trimX;
  final double trimY;
  final double trimWidth;
  final double trimHeight;
  final double safetyLeft;
  final double safetyTop;
  final double safetyRight;
  final double safetyBottom;
}

class _PageLayoutDialog extends StatefulWidget {
  const _PageLayoutDialog({required this.page});

  final rust.ComicPageView page;

  @override
  State<_PageLayoutDialog> createState() => _PageLayoutDialogState();
}

class _PageLayoutDialogState extends State<_PageLayoutDialog> {
  late final TextEditingController _dpi;
  late final TextEditingController _bleedLeft;
  late final TextEditingController _bleedTop;
  late final TextEditingController _bleedRight;
  late final TextEditingController _bleedBottom;
  late final TextEditingController _trimX;
  late final TextEditingController _trimY;
  late final TextEditingController _trimWidth;
  late final TextEditingController _trimHeight;
  late final TextEditingController _safetyLeft;
  late final TextEditingController _safetyTop;
  late final TextEditingController _safetyRight;
  late final TextEditingController _safetyBottom;
  String? _error;

  @override
  void initState() {
    super.initState();
    final page = widget.page;
    _dpi = _controller(page.dpi);
    _bleedLeft = _controller(page.bleedLeft);
    _bleedTop = _controller(page.bleedTop);
    _bleedRight = _controller(page.bleedRight);
    _bleedBottom = _controller(page.bleedBottom);
    _trimX = _controller(page.trimX);
    _trimY = _controller(page.trimY);
    _trimWidth = _controller(page.trimWidth);
    _trimHeight = _controller(page.trimHeight);
    _safetyLeft = _controller(page.safetyLeft);
    _safetyTop = _controller(page.safetyTop);
    _safetyRight = _controller(page.safetyRight);
    _safetyBottom = _controller(page.safetyBottom);
  }

  TextEditingController _controller(double value) =>
      TextEditingController(text: value.roundToDouble().toStringAsFixed(0));

  @override
  void dispose() {
    for (final controller in [
      _dpi,
      _bleedLeft,
      _bleedTop,
      _bleedRight,
      _bleedBottom,
      _trimX,
      _trimY,
      _trimWidth,
      _trimHeight,
      _safetyLeft,
      _safetyTop,
      _safetyRight,
      _safetyBottom,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  double? _parse(TextEditingController controller) {
    final value = double.tryParse(controller.text.trim());
    return value == null || !value.isFinite ? null : value;
  }

  void _save() {
    final values = [
      _parse(_dpi),
      _parse(_bleedLeft),
      _parse(_bleedTop),
      _parse(_bleedRight),
      _parse(_bleedBottom),
      _parse(_trimX),
      _parse(_trimY),
      _parse(_trimWidth),
      _parse(_trimHeight),
      _parse(_safetyLeft),
      _parse(_safetyTop),
      _parse(_safetyRight),
      _parse(_safetyBottom),
    ];
    if (values.any((value) => value == null)) {
      setState(() => _error = 'Enter finite numeric values in every field.');
      return;
    }
    final v = values.cast<double>();
    final dpi = v[0];
    final trimWidth = v[7];
    final trimHeight = v[8];
    if (dpi <= 0 ||
        trimWidth <= 0 ||
        trimHeight <= 0 ||
        v[1] < 0 ||
        v[2] < 0 ||
        v[3] < 0 ||
        v[4] < 0 ||
        v[9] < 0 ||
        v[10] < 0 ||
        v[11] < 0 ||
        v[12] < 0 ||
        v[9] + v[11] >= trimWidth ||
        v[10] + v[12] >= trimHeight) {
      setState(
        () =>
            _error =
                'DPI, trim size, and margins must be positive and fit inside the trim.',
      );
      return;
    }
    Navigator.of(context).pop(
      _PageLayoutDraft(
        dpi: dpi,
        bleedLeft: v[1],
        bleedTop: v[2],
        bleedRight: v[3],
        bleedBottom: v[4],
        trimX: v[5],
        trimY: v[6],
        trimWidth: trimWidth,
        trimHeight: trimHeight,
        safetyLeft: v[9],
        safetyTop: v[10],
        safetyRight: v[11],
        safetyBottom: v[12],
      ),
    );
  }

  Widget _field(String label, TextEditingController controller) {
    return SizedBox(
      width: 132,
      child: TextField(
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: label),
      ),
    );
  }

  Widget _group(String label, List<Widget> fields) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        Wrap(spacing: 8, runSpacing: 4, children: fields),
        const SizedBox(height: 12),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Page settings'),
      content: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 430),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _field('DPI', _dpi),
              const SizedBox(height: 12),
              _group('Bleed (px)', [
                _field('Left', _bleedLeft),
                _field('Top', _bleedTop),
                _field('Right', _bleedRight),
                _field('Bottom', _bleedBottom),
              ]),
              _group('Trim (px)', [
                _field('X', _trimX),
                _field('Y', _trimY),
                _field('Width', _trimWidth),
                _field('Height', _trimHeight),
              ]),
              _group('Safety (px)', [
                _field('Left', _safetyLeft),
                _field('Top', _safetyTop),
                _field('Right', _safetyRight),
                _field('Bottom', _safetyBottom),
              ]),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        InkDialogAction(
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
        ),
        InkDialogAction(
          label: 'Save settings',
          onPressed: _save,
          primary: true,
        ),
      ],
    );
  }
}

class _BalloonStyleDialog extends StatefulWidget {
  const _BalloonStyleDialog({
    required this.family,
    required this.sizePx,
    required this.outlinePx,
    required this.vertical,
  });

  final String family;
  final double sizePx;
  final double outlinePx;
  final bool vertical;

  @override
  State<_BalloonStyleDialog> createState() => _BalloonStyleDialogState();
}

class _BalloonStyleDialogState extends State<_BalloonStyleDialog> {
  late final TextEditingController _family;
  late final TextEditingController _size;
  late final TextEditingController _outline;
  late bool _vertical;

  @override
  void initState() {
    super.initState();
    _family = TextEditingController(text: widget.family);
    _size = TextEditingController(text: widget.sizePx.toStringAsFixed(1));
    _outline = TextEditingController(text: widget.outlinePx.toStringAsFixed(1));
    _vertical = widget.vertical;
  }

  @override
  void dispose() {
    _family.dispose();
    _size.dispose();
    _outline.dispose();
    super.dispose();
  }

  void _save() {
    final parsedSize = double.tryParse(_size.text);
    final parsedOutline = double.tryParse(_outline.text);
    if (_family.text.trim().isEmpty ||
        parsedSize == null ||
        parsedOutline == null ||
        !parsedSize.isFinite ||
        !parsedOutline.isFinite) {
      return;
    }
    Navigator.of(context).pop(
      _BalloonStyleDraft(
        _family.text.trim(),
        parsedSize,
        parsedOutline,
        _vertical,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit balloon style'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _family,
              maxLength: 256,
              decoration: const InputDecoration(
                labelText: 'Font fallback family',
              ),
            ),
            TextField(
              controller: _size,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(labelText: 'Font size (px)'),
            ),
            TextField(
              controller: _outline,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(labelText: 'Outline (px)'),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: InkToggleChip(
                label: 'Vertical text',
                value: _vertical,
                icon: Icons.text_rotation_none,
                onChanged: (value) => setState(() => _vertical = value),
              ),
            ),
          ],
        ),
      ),
      actions: [
        InkDialogAction(
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
        ),
        InkDialogAction(label: 'Save', onPressed: _save, primary: true),
      ],
    );
  }
}

class _BalloonStyleDraft {
  const _BalloonStyleDraft(
    this.family,
    this.fontSizePx,
    this.outlinePx,
    this.vertical,
  );

  final String family;
  final double fontSizePx;
  final double outlinePx;
  final bool vertical;
}

class _MaterialDraft {
  const _MaterialDraft({
    required this.name,
    required this.kind,
    required this.license,
    this.attribution,
    this.source,
  });

  final String name;
  final String kind;
  final String license;
  final String? attribution;
  final String? source;
}

class _MaterialDialog extends StatefulWidget {
  const _MaterialDialog();

  @override
  State<_MaterialDialog> createState() => _MaterialDialogState();
}

class _MaterialDialogState extends State<_MaterialDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _licenseController;
  late final TextEditingController _attributionController;
  late final TextEditingController _sourceController;
  String _kind = 'brush';
  String? _error;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _licenseController = TextEditingController(text: 'MPL-2.0');
    _attributionController = TextEditingController();
    _sourceController = TextEditingController();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _licenseController.dispose();
    _attributionController.dispose();
    _sourceController.dispose();
    super.dispose();
  }

  void _save() {
    final name = _nameController.text.trim();
    final license = _licenseController.text.trim();
    if (name.isEmpty || license.isEmpty) {
      setState(() => _error = 'Name and license are required.');
      return;
    }
    if (name.length > 256 || license.length > 256) {
      setState(
        () => _error = 'Name and license must be 256 characters or less.',
      );
      return;
    }
    Navigator.of(context).pop(
      _MaterialDraft(
        name: name,
        kind: _kind,
        license: license,
        attribution: _optional(_attributionController.text),
        source: _optional(_sourceController.text),
      ),
    );
  }

  String? _optional(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add local material'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameController,
              autofocus: true,
              maxLength: 256,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'e.g. Rough pencil texture',
              ),
            ),
            DropdownButtonFormField<String>(
              initialValue: _kind,
              decoration: const InputDecoration(labelText: 'Material type'),
              items: const [
                DropdownMenuItem(value: 'brush', child: Text('Brush')),
                DropdownMenuItem(value: 'texture', child: Text('Texture')),
                DropdownMenuItem(value: 'template', child: Text('Template')),
                DropdownMenuItem(
                  value: 'balloon-style',
                  child: Text('Balloon style'),
                ),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _kind = value);
              },
            ),
            TextField(
              controller: _licenseController,
              maxLength: 256,
              decoration: const InputDecoration(
                labelText: 'License',
                hintText: 'CC0-1.0, MIT, or proprietary',
              ),
            ),
            TextField(
              controller: _attributionController,
              maxLength: 256,
              decoration: const InputDecoration(
                labelText: 'Attribution (optional)',
              ),
            ),
            TextField(
              controller: _sourceController,
              maxLength: 256,
              decoration: const InputDecoration(
                labelText: 'Source (optional)',
                hintText: 'Local file or project reference',
              ),
            ),
            if (_error != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        InkDialogAction(
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
        ),
        InkDialogAction(label: 'Add material', onPressed: _save, primary: true),
      ],
    );
  }
}

class _MaterialsSummary extends StatelessWidget {
  const _MaterialsSummary({required this.materials, required this.onRemove});

  final List<rust.ComicMaterialView> materials;
  final Future<void> Function(BigInt materialId) onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: InkPanelSurface(
        padding: EdgeInsets.zero,
        child: InkInspectorSection(
          leading: const Icon(Icons.collections_bookmark_outlined),
          title:
              '${materials.length} local material${materials.length == 1 ? '' : 's'}',
          subtitle: 'License and attribution travel with the project',
          initiallyExpanded: false,
          child: Column(
            children: [
              for (final material in materials)
                InkInspectorRow(
                  selected: false,
                  title: material.name,
                  subtitle:
                      '${material.kind} • ${material.license}${material.attribution == null ? '' : ' • ${material.attribution}'}',
                  icon: const Icon(Icons.collections_bookmark_outlined),
                  trailing: InkCommandButton(
                    label: 'Remove ${material.name}',
                    icon: Icons.delete_outline,
                    onPressed: () => onRemove(material.id),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PanelSplitDraft {
  const _PanelSplitDraft({required this.axis, required this.ratio});

  final int axis;
  final double ratio;
}

class _ToneDraft {
  const _ToneDraft({
    required this.shape,
    required this.frequencyLpi,
    required this.angleDegrees,
    required this.density,
  });

  final String shape;
  final double frequencyLpi;
  final double angleDegrees;
  final double density;
}

class _ToneDialog extends StatefulWidget {
  const _ToneDialog({this.initial, this.editing = false});

  final _ToneDraft? initial;
  final bool editing;

  @override
  State<_ToneDialog> createState() => _ToneDialogState();
}

class _ToneDialogState extends State<_ToneDialog> {
  late String _shape = widget.initial?.shape ?? 'circle';
  late double _frequency = widget.initial?.frequencyLpi ?? 60;
  late double _angle = widget.initial?.angleDegrees ?? 45;
  late double _density = widget.initial?.density ?? 0.35;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.editing ? 'Edit screentone' : 'Add screentone'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String>(
            initialValue: _shape,
            decoration: const InputDecoration(labelText: 'Pattern'),
            items: const [
              DropdownMenuItem(value: 'circle', child: Text('Circle dots')),
              DropdownMenuItem(value: 'line', child: Text('Lines')),
              DropdownMenuItem(value: 'noise', child: Text('Noise')),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _shape = value);
            },
          ),
          const SizedBox(height: 12),
          InkPropertySlider(
            label: 'Frequency',
            value: _frequency,
            min: 10,
            max: 300,
            divisions: 58,
            valueLabel: '${_frequency.round()} LPI',
            onChanged: (value) => setState(() => _frequency = value),
          ),
          InkPropertySlider(
            label: 'Angle',
            value: _angle,
            min: -180,
            max: 180,
            divisions: 72,
            valueLabel: '${_angle.round()}°',
            onChanged: (value) => setState(() => _angle = value),
          ),
          InkPropertySlider(
            label: 'Density',
            value: _density,
            min: 0,
            max: 1,
            divisions: 20,
            valueLabel: '${(_density * 100).round()}%',
            onChanged: (value) => setState(() => _density = value),
          ),
        ],
      ),
    ),
    actions: [
      InkDialogAction(label: 'Cancel', onPressed: () => Navigator.pop(context)),
      InkDialogAction(
        primary: true,
        label: widget.editing ? 'Save tone' : 'Add tone',
        onPressed:
            () => Navigator.pop(
              context,
              _ToneDraft(
                shape: _shape,
                frequencyLpi: _frequency,
                angleDegrees: _angle,
                density: _density,
              ),
            ),
      ),
    ],
  );
}

class _EffectLineDraft {
  const _EffectLineDraft({
    required this.kind,
    required this.widthPx,
    required this.opacity,
  });

  final String kind;
  final double widthPx;
  final double opacity;
}

class _EffectLineDialog extends StatefulWidget {
  const _EffectLineDialog({this.initial, this.editing = false});

  final _EffectLineDraft? initial;
  final bool editing;

  @override
  State<_EffectLineDialog> createState() => _EffectLineDialogState();
}

class _EffectLineDialogState extends State<_EffectLineDialog> {
  late String _kind = widget.initial?.kind ?? 'speed';
  late double _width = widget.initial?.widthPx ?? 8;
  late double _opacity = widget.initial?.opacity ?? 0.75;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.editing ? 'Edit effect lines' : 'Add effect lines'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          initialValue: _kind,
          decoration: const InputDecoration(labelText: 'Line type'),
          items: const [
            DropdownMenuItem(value: 'speed', child: Text('Speed lines')),
            DropdownMenuItem(value: 'focus', child: Text('Focus lines')),
            DropdownMenuItem(value: 'radial', child: Text('Radial lines')),
          ],
          onChanged: (value) {
            if (value != null) setState(() => _kind = value);
          },
        ),
        const SizedBox(height: 12),
        InkPropertySlider(
          label: 'Width',
          value: _width,
          min: 1,
          max: 64,
          divisions: 63,
          valueLabel: '${_width.toStringAsFixed(1)} px',
          onChanged: (value) => setState(() => _width = value),
        ),
        InkPropertySlider(
          label: 'Opacity',
          value: _opacity,
          min: 0,
          max: 1,
          divisions: 20,
          valueLabel: '${(_opacity * 100).round()}%',
          onChanged: (value) => setState(() => _opacity = value),
        ),
      ],
    ),
    actions: [
      InkDialogAction(label: 'Cancel', onPressed: () => Navigator.pop(context)),
      InkDialogAction(
        primary: true,
        label: widget.editing ? 'Save lines' : 'Add lines',
        onPressed:
            () => Navigator.pop(
              context,
              _EffectLineDraft(kind: _kind, widthPx: _width, opacity: _opacity),
            ),
      ),
    ],
  );
}

class _PanelSplitDialog extends StatefulWidget {
  const _PanelSplitDialog();

  @override
  State<_PanelSplitDialog> createState() => _PanelSplitDialogState();
}

class _PanelSplitDialogState extends State<_PanelSplitDialog> {
  int _axis = 0;
  double _ratio = 0.5;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Divide panel'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<int>(
          initialValue: _axis,
          decoration: const InputDecoration(labelText: 'Division direction'),
          items: const [
            DropdownMenuItem(value: 0, child: Text('Horizontal')),
            DropdownMenuItem(value: 1, child: Text('Vertical')),
          ],
          onChanged: (value) {
            if (value != null) setState(() => _axis = value);
          },
        ),
        const SizedBox(height: 12),
        Semantics(
          label: 'Drag the divider to choose the first panel size',
          child: SizedBox(
            key: const ValueKey<String>('panel-split-preview'),
            width: 320,
            height: 140,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanUpdate: (details) {
                const width = 320.0;
                const height = 140.0;
                final extent = _axis == 0 ? width : height;
                final position =
                    _axis == 0
                        ? details.localPosition.dx
                        : details.localPosition.dy;
                setState(() => _ratio = (position / extent).clamp(0.1, 0.9));
              },
              child: CustomPaint(
                painter: _PanelSplitPreviewPainter(axis: _axis, ratio: _ratio),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        InkPropertySlider(
          label: 'First panel size',
          value: _ratio,
          min: 0.1,
          max: 0.9,
          divisions: 16,
          valueLabel: '${(_ratio * 100).round()}%',
          onChanged: (value) => setState(() => _ratio = value),
        ),
      ],
    ),
    actions: [
      InkDialogAction(label: 'Cancel', onPressed: () => Navigator.pop(context)),
      InkDialogAction(
        primary: true,
        label: 'Divide',
        onPressed:
            () => Navigator.pop(
              context,
              _PanelSplitDraft(axis: _axis, ratio: _ratio),
            ),
      ),
    ],
  );
}

class _PanelSplitPreviewPainter extends CustomPainter {
  const _PanelSplitPreviewPainter({required this.axis, required this.ratio});

  final int axis;
  final double ratio;

  @override
  void paint(Canvas canvas, Size size) {
    final background = Paint()..color = const Color(0xfff5f7fb);
    final first = Paint()..color = const Color(0xffdbeafe);
    final second = Paint()..color = const Color(0xffede9fe);
    final border =
        Paint()
          ..color = const Color(0xff475569)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2;
    final divider =
        Paint()
          ..color = const Color(0xff1d4ed8)
          ..strokeWidth = 4;
    final rect = Offset.zero & size;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(8)),
      background,
    );
    final clamped = ratio.clamp(0.1, 0.9).toDouble();
    if (axis == 0) {
      final splitX = size.width * clamped;
      canvas.drawRect(Rect.fromLTRB(0, 0, splitX, size.height), first);
      canvas.drawRect(
        Rect.fromLTRB(splitX, 0, size.width, size.height),
        second,
      );
      canvas.drawLine(Offset(splitX, 0), Offset(splitX, size.height), divider);
    } else {
      final splitY = size.height * clamped;
      canvas.drawRect(Rect.fromLTRB(0, 0, size.width, splitY), first);
      canvas.drawRect(
        Rect.fromLTRB(0, splitY, size.width, size.height),
        second,
      );
      canvas.drawLine(Offset(0, splitY), Offset(size.width, splitY), divider);
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(8)),
      border,
    );
  }

  @override
  bool shouldRepaint(_PanelSplitPreviewPainter oldDelegate) =>
      axis != oldDelegate.axis || ratio != oldDelegate.ratio;
}

class _ComicThumbnailPainter extends CustomPainter {
  const _ComicThumbnailPainter({required this.page});

  final rust.ComicPageView page;

  @override
  void paint(Canvas canvas, Size size) {
    final pagePaint = Paint()..color = const Color(0xfffafafa);
    final borderPaint =
        Paint()
          ..color = const Color(0xff616161)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1;
    final pageRect = Offset.zero & size;
    canvas.drawRRect(
      RRect.fromRectAndRadius(pageRect, const Radius.circular(4)),
      pagePaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(pageRect, const Radius.circular(4)),
      borderPaint,
    );
    if (page.widthPx <= 0 || page.heightPx <= 0) return;
    final scale = math.min(
      (size.width - 6) / page.widthPx,
      (size.height - 6) / page.heightPx,
    );
    canvas.save();
    canvas.translate(3, 3);
    canvas.scale(scale, scale);
    final panelFill = Paint()..color = const Color.fromRGBO(80, 120, 180, .12);
    final panelBorder =
        Paint()
          ..color = const Color(0xff355a89)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3 / scale;
    final maskBorder =
        Paint()
          ..color = const Color(0xffc77c00)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 / scale;
    for (final panel in page.panels) {
      final rect = Rect.fromLTWH(panel.x, panel.y, panel.width, panel.height);
      canvas.drawRect(rect, panelFill);
      final panelPaint = panel.maskLayerId == null ? panelBorder : maskBorder;
      if (panel.shape == 1 && panel.polygon.length >= 6) {
        final path = Path()..moveTo(panel.polygon[0], panel.polygon[1]);
        for (var i = 2; i + 1 < panel.polygon.length; i += 2) {
          path.lineTo(panel.polygon[i], panel.polygon[i + 1]);
        }
        path.close();
        canvas.drawPath(path, panelPaint);
      } else {
        canvas.drawRect(rect, panelPaint);
      }
      if (panel.maskLayerId != null) {
        canvas.drawLine(rect.topLeft, rect.bottomRight, maskBorder);
        canvas.drawLine(rect.topRight, rect.bottomLeft, maskBorder);
      }
    }
    final balloonFill = Paint()..color = const Color(0xeeffffff);
    final balloonBorder =
        Paint()
          ..color = const Color(0xff303030)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 / scale;
    for (final balloon in page.balloons) {
      final rect = Rect.fromLTWH(
        balloon.x,
        balloon.y,
        balloon.width,
        balloon.height,
      );
      if (balloon.shape == 2) {
        canvas.drawRect(rect, balloonFill);
        canvas.drawRect(rect, balloonBorder);
      } else {
        canvas.drawOval(rect, balloonFill);
        canvas.drawOval(rect, balloonBorder);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ComicThumbnailPainter oldDelegate) =>
      oldDelegate.page != page;
}

class _PrintPreviewSummary extends StatelessWidget {
  const _PrintPreviewSummary({
    required this.report,
    this.previewBytes,
    this.page,
  });

  final rust.ComicPrintPreviewView report;
  final Uint8List? previewBytes;
  final rust.ComicPageView? page;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final safe = report.bleedSafe && report.safetySafe;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: InkPanelSurface(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  safe ? Icons.check_circle : Icons.warning_amber,
                  color: safe ? colorScheme.primary : colorScheme.error,
                ),
                const SizedBox(width: 8),
                Text(
                  safe
                      ? 'Print-safe geometry'
                      : 'Print preview needs attention',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ],
            ),
            Text(
              '${report.pageCount} pages • bleed ${report.bleedSafe ? 'OK' : 'outside trim'} • safety ${report.safetySafe ? 'OK' : 'too tight'}',
            ),
            if (previewBytes != null)
              ConstrainedBox(
                constraints: const BoxConstraints(
                  maxHeight: 220,
                  maxWidth: 180,
                ),
                child: Image.memory(
                  previewBytes!,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  semanticLabel: 'Raster print preview',
                ),
              )
            else if (page != null)
              SizedBox(
                height: 120,
                width: 92,
                child: CustomPaint(painter: _PrintGuidePainter(page: page!)),
              ),
            for (final warning in report.moireWarnings)
              Text(warning, style: TextStyle(color: colorScheme.error)),
          ],
        ),
      ),
    );
  }
}

class _PrintGuidePainter extends CustomPainter {
  const _PrintGuidePainter({required this.page});

  final rust.ComicPageView page;

  @override
  void paint(Canvas canvas, Size size) {
    final pagePaint = Paint()..color = const Color(0xfffafafa);
    final border =
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1;
    canvas.drawRect(Offset.zero & size, pagePaint);
    if (page.widthPx <= 0 || page.heightPx <= 0) return;
    final scale = math.min(
      (size.width - 4) / page.widthPx,
      (size.height - 4) / page.heightPx,
    );
    canvas.save();
    canvas.translate(2, 2);
    canvas.scale(scale, scale);
    border.color = const Color(0xff2563eb);
    canvas.drawRect(
      Rect.fromLTWH(page.trimX, page.trimY, page.trimWidth, page.trimHeight),
      border,
    );
    border.color = const Color(0xffd97706);
    canvas.drawRect(
      Rect.fromLTWH(
        page.trimX + page.safetyLeft,
        page.trimY + page.safetyTop,
        page.trimWidth - page.safetyLeft - page.safetyRight,
        page.trimHeight - page.safetyTop - page.safetyBottom,
      ),
      border,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _PrintGuidePainter oldDelegate) =>
      oldDelegate.page != page;
}
