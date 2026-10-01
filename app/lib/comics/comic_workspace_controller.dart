import 'dart:async';

import 'package:flutter/foundation.dart';

import '../bridge/generated/api.dart' as rust;

const comicExportFailureMessage =
    'Export failed. Choose a different, writable folder and try again.';

String? comicWorkspaceErrorMessage(Object? error) => switch (error) {
  null => null,
  String message => message,
  _ => 'Comic operation failed. Please try again.',
};

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
