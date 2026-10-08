import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/bridge/engine_api.dart';
import 'package:project_ink/bridge/generated/api.dart' as rust;
import 'package:project_ink/canvas/canvas_comic_panel_actions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'materializes the panel tree before selecting its clipped area',
    () async {
      final engine = InMemoryEngineApi();
      var selectedLayerId = -1;
      var persistedPanelState = 0;
      var clippedPanelId = BigInt.zero;
      var clippedPageIndex = -1;
      var selectionGeometryCleared = false;
      final actions = CanvasComicPanelActions(
        CanvasComicPanelActionHost(
          engine: () => engine,
          mounted: () => true,
          activePageIndex: () => 0,
          workspaceSnapshot: () => _project(_page(_panel())),
          clippedPanelId: () => clippedPanelId,
          clippedPageIndex: () => clippedPageIndex,
          setClippedPanel: ({required pageIndex, required panelId}) {
            clippedPageIndex = pageIndex;
            clippedPanelId = panelId;
            selectionGeometryCleared = true;
          },
          clearSelection: () async {
            await engine.clearSelection();
            clippedPanelId = BigInt.zero;
            clippedPageIndex = -1;
          },
          loadLayerProjections: () async {},
          selectLayer: (layerId) => selectedLayerId = layerId,
          persistPanelState: () => persistedPanelState++,
        ),
      );

      await actions.drawInsidePanel(0, _panel());

      expect(engine.revision, 3);
      expect(selectedLayerId, 105);
      expect(persistedPanelState, 1);
      expect(clippedPanelId, BigInt.from(7));
      expect(clippedPageIndex, 0);
      expect(selectionGeometryCleared, isTrue);

      await actions.drawInsidePanel(0, _panel());
      expect(engine.revision, 4);
      expect(clippedPanelId, BigInt.zero);
    },
  );

  test('panel geometry sync skips invalid active-page indexes', () async {
    final engine = InMemoryEngineApi();
    final actions = CanvasComicPanelActions(
      CanvasComicPanelActionHost(
        engine: () => engine,
        mounted: () => true,
        activePageIndex: () => 1,
        workspaceSnapshot: () => null,
        clippedPanelId: () => null,
        clippedPageIndex: () => null,
        setClippedPanel: ({required pageIndex, required panelId}) {},
        clearSelection: engine.clearSelection,
        loadLayerProjections: () async {},
        selectLayer: (_) {},
        persistPanelState: () {},
      ),
    );

    await actions.syncPanelGeometry(_project(_page(_panel())));

    expect(engine.revision, 0);
  });
}

rust.ComicPanelPreviewView _panel() => rust.ComicPanelPreviewView(
  id: BigInt.from(7),
  shape: 0,
  x: 10,
  y: 20,
  width: 100,
  height: 80,
  gutterPx: 0,
  borderPx: 1,
  panelGroupId: BigInt.from(101),
  maskLayerId: BigInt.from(102),
  sketchLayerId: BigInt.from(103),
  inkLayerId: BigInt.from(105),
  colorLayerId: BigInt.from(106),
  toneLayerId: BigInt.from(107),
  effectsLayerId: BigInt.from(108),
  polygon: Float32List.fromList(const [10, 20, 110, 20, 110, 100, 10, 100]),
);

rust.ComicProjectView _project(rust.ComicPageView page) =>
    rust.ComicProjectView(
      id: BigInt.from(1),
      template: 0,
      title: 'Project',
      pageCount: 1,
      pages: [page],
      materials: const [],
    );

rust.ComicPageView _page(rust.ComicPanelPreviewView panel) =>
    rust.ComicPageView(
      id: BigInt.from(2),
      pageNumber: 1,
      widthPx: 1024,
      heightPx: 1024,
      dpi: 300,
      panelCount: 1,
      balloonCount: 0,
      toneCount: 0,
      effectLineCount: 0,
      panels: [panel],
      balloons: const [],
      tones: const [],
      effectLines: const [],
      bleedLeft: 0,
      bleedTop: 0,
      bleedRight: 0,
      bleedBottom: 0,
      trimX: 0,
      trimY: 0,
      trimWidth: 1024,
      trimHeight: 1024,
      safetyLeft: 0,
      safetyTop: 0,
      safetyRight: 0,
      safetyBottom: 0,
    );
