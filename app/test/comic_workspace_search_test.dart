import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/bridge/generated/api.dart' as rust;
import 'package:project_ink/comics/comic_workspace.dart';

class _SearchController extends ComicWorkspaceController {
  _SearchController(this.project, {this.errorMessage}) : super();

  final rust.ComicProjectView project;
  final String? errorMessage;

  @override
  rust.ComicProjectView? get snapshot => project;

  @override
  String? get userFacingError => comicWorkspaceErrorMessage(errorMessage);

  @override
  Future<void> ensureExampleLoaded() async => notifyListeners();

  @override
  Future<List<rust.ComicDialogueHitView>> searchDialogue(String query) async =>
      query.trim().isEmpty
          ? const []
          : <rust.ComicDialogueHitView>[
            rust.ComicDialogueHitView(
              pageIndex: 1,
              balloonId: BigInt.from(202),
              matchStart: 7,
              matchEnd: 13,
            ),
          ];

  @override
  Future<Uint8List?> loadPagePreview(int pageIndex) async => null;

  @override
  Future<List<rust.ComicWebtoonSegmentView>> segmentsFor(
    int pageIndex, {
    int maxHeightPx = 2048,
  }) async => const [
    rust.ComicWebtoonSegmentView(
      pageIndex: 0,
      segmentIndex: 0,
      sourceY: 0,
      heightPx: 2048,
    ),
    rust.ComicWebtoonSegmentView(
      pageIndex: 0,
      segmentIndex: 1,
      sourceY: 2048,
      heightPx: 904,
    ),
  ];
}

class _TemplateController extends _SearchController {
  _TemplateController(super.project);

  int? selectedTemplate;

  @override
  Future<void> createTemplate(int template) async {
    selectedTemplate = template;
    notifyListeners();
  }
}

class _ScriptController extends _SearchController {
  _ScriptController(super.project) : current = project;

  rust.ComicProjectView current;
  int? editedPageIndex;
  BigInt? editedBalloonId;
  String? editedText;

  @override
  rust.ComicProjectView? get snapshot => current;

  @override
  Future<List<rust.ComicDialogueHitView>> searchDialogue(String query) async {
    if (query.trim().isEmpty) return const [];
    final folded = query.toLowerCase();
    final hits = <rust.ComicDialogueHitView>[];
    for (var pageIndex = 0; pageIndex < current.pages.length; pageIndex++) {
      for (final balloon in current.pages[pageIndex].balloons) {
        final start = balloon.text.toLowerCase().indexOf(folded);
        if (start < 0) continue;
        hits.add(
          rust.ComicDialogueHitView(
            pageIndex: pageIndex,
            balloonId: balloon.id,
            matchStart: start,
            matchEnd: start + query.length,
          ),
        );
      }
    }
    return hits;
  }

  @override
  Future<void> setDialogue({
    required int pageIndex,
    required BigInt balloonId,
    required String text,
  }) async {
    editedPageIndex = pageIndex;
    editedBalloonId = balloonId;
    editedText = text;
  }

  @override
  Future<void> reorderPage(int from, int to) async {
    final pages = List<rust.ComicPageView>.of(current.pages);
    final moved = pages.removeAt(from);
    pages.insert(to, moved);
    current = rust.ComicProjectView(
      id: current.id,
      template: current.template,
      title: current.title,
      pageCount: pages.length,
      pages: pages,
      materials: current.materials,
    );
    notifyListeners();
  }
}

Future<void> _selectComicSection(WidgetTester tester, String label) async {
  final tab = find.bySemanticsLabel(label);
  if (tab.evaluate().isNotEmpty) {
    await tester.ensureVisible(tab);
    await tester.tap(tab);
  } else {
    await tester.tap(find.byTooltip('More comic sections'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
  }
  await tester.pumpAndSettle();
}

class _HistoryController extends _SearchController {
  _HistoryController(super.project);

  bool undoCalled = false;
  bool redoCalled = false;
  bool splitCalled = false;
  int? splitAxis;
  double? splitRatio;

  @override
  bool get canUndo => true;

  @override
  bool get canRedo => true;

  @override
  Future<void> undo() async => undoCalled = true;

  @override
  Future<void> redo() async => redoCalled = true;

  @override
  Future<void> splitFirstPanel({
    int pageIndex = 0,
    int axis = 0,
    double ratio = 0.5,
  }) async {
    splitCalled = true;
    splitAxis = axis;
    splitRatio = ratio;
  }
}

class _BalloonController extends _SearchController {
  _BalloonController(super.project);

  int? addedShape;

  @override
  Future<void> addBalloon({
    int pageIndex = 0,
    int shape = 0,
    bool verticalText = false,
  }) async {
    addedShape = shape;
  }
}

class _MaterialController extends _SearchController {
  _MaterialController(super.project);

  BigInt? removedMaterial;
  String? addedMaterialName;
  String? addedMaterialKind;
  String? addedMaterialLicense;
  String? addedMaterialAttribution;
  String? addedMaterialSource;

  @override
  Future<void> addLocalMaterial({
    String kind = 'balloon-style',
    String? name,
    String license = 'MPL-2.0',
    String? attribution,
    String? source,
  }) async {
    addedMaterialName = name;
    addedMaterialKind = kind;
    addedMaterialLicense = license;
    addedMaterialAttribution = attribution;
    addedMaterialSource = source;
  }

  @override
  Future<void> removeMaterial(BigInt materialId) async {
    removedMaterial = materialId;
  }
}

class _PageOrderController extends _SearchController {
  _PageOrderController(super.project);

  int? movedFrom;
  int? movedTo;

  @override
  Future<void> reorderPage(int from, int to) async {
    movedFrom = from;
    movedTo = to;
  }
}

class _RemovePageController extends _SearchController {
  _RemovePageController(super.project) : current = project;

  rust.ComicProjectView current;
  int? removedIndex;

  @override
  rust.ComicProjectView? get snapshot => current;

  @override
  Future<void> removePage(int pageIndex) async {
    removedIndex = pageIndex;
    final pages = List<rust.ComicPageView>.of(current.pages)
      ..removeAt(pageIndex);
    current = rust.ComicProjectView(
      id: current.id,
      template: current.template,
      title: current.title,
      pageCount: pages.length,
      pages: pages,
      materials: current.materials,
    );
    notifyListeners();
  }
}

class _ToneController extends _SearchController {
  _ToneController(super.project);

  String? toneShape;
  double? toneFrequency;
  double? toneAngle;
  double? toneDensity;
  String? editedToneShape;
  BigInt? removedTone;

  @override
  Future<void> addTone({
    int pageIndex = 0,
    String shape = 'circle',
    double frequencyLpi = 60,
    double angleDegrees = 45,
    double density = 0.35,
  }) async {
    toneShape = shape;
    toneFrequency = frequencyLpi;
    toneAngle = angleDegrees;
    toneDensity = density;
  }

  @override
  Future<void> setTone({
    required int pageIndex,
    required rust.ComicTonePreviewView tone,
    required String shape,
    required double frequencyLpi,
    required double angleDegrees,
    required double density,
  }) async {
    editedToneShape = shape;
  }

  @override
  Future<void> removeTone({
    required int pageIndex,
    required BigInt toneId,
  }) async {
    removedTone = toneId;
  }
}

class _LayoutController extends _SearchController {
  _LayoutController(super.project);

  double? layoutDpi;
  double? layoutTrimWidth;
  double? layoutSafetyLeft;

  @override
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
    layoutDpi = dpi;
    layoutTrimWidth = trimWidth;
    layoutSafetyLeft = safetyLeft;
  }
}

class _BoundsController extends _SearchController {
  _BoundsController(super.project);

  double? boundsX;
  double? boundsWidth;

  @override
  Future<void> setPanelBounds({
    required int pageIndex,
    required BigInt panelId,
    required double x,
    required double y,
    required double width,
    required double height,
  }) async {
    boundsX = x;
    boundsWidth = width;
  }
}

class _EffectController extends _SearchController {
  _EffectController(super.project);

  String? effectKind;
  double? effectWidth;
  double? effectOpacity;
  String? editedEffectKind;
  BigInt? removedEffect;

  @override
  Future<void> addEffectLine({
    int pageIndex = 0,
    String kind = 'speed',
    double widthPx = 8,
    double opacity = 0.75,
  }) async {
    effectKind = kind;
    effectWidth = widthPx;
    effectOpacity = opacity;
  }

  @override
  Future<void> setEffectLine({
    required int pageIndex,
    required rust.ComicEffectLinePreviewView line,
    required String kind,
    required double widthPx,
    required double opacity,
  }) async {
    editedEffectKind = kind;
  }

  @override
  Future<void> removeEffectLine({
    required int pageIndex,
    required BigInt effectId,
  }) async {
    removedEffect = effectId;
  }
}

rust.ComicPageView _page(
  int pageNumber,
  String text,
  BigInt balloonId, {
  List<rust.ComicTonePreviewView> tones = const [],
  List<rust.ComicEffectLinePreviewView> effectLines = const [],
}) {
  final balloon = rust.ComicBalloonPreviewView(
    id: balloonId,
    shape: 0,
    x: 100,
    y: 100,
    width: 400,
    height: 220,
    text: text,
    fontFamily: 'sans-serif',
    fontSizePx: 32,
    outlinePx: 0,
    orientation: 0,
    tail: Float32List.fromList(<double>[300, 320, 280, 380]),
  );
  return rust.ComicPageView(
    id: BigInt.from(pageNumber),
    pageNumber: pageNumber,
    widthPx: 1200,
    heightPx: 1600,
    dpi: 300,
    panelCount: 0,
    balloonCount: 1,
    toneCount: tones.length,
    effectLineCount: effectLines.length,
    panels: const [],
    balloons: <rust.ComicBalloonPreviewView>[balloon],
    tones: tones,
    effectLines: effectLines,
    bleedLeft: 24,
    bleedTop: 24,
    bleedRight: 24,
    bleedBottom: 24,
    trimX: 48,
    trimY: 48,
    trimWidth: 1104,
    trimHeight: 1504,
    safetyLeft: 48,
    safetyTop: 48,
    safetyRight: 48,
    safetyBottom: 48,
  );
}

void main() {
  test('page reorder keeps the active page index attached to its page', () {
    // Moving a page across the active page shifts the active index; moving
    // the active page itself carries selection with it.
    expect(
      ComicWorkspaceController.activePageIndexAfterReorder(
        activeIndex: 2,
        from: 0,
        to: 3,
      ),
      1,
    );
    expect(
      ComicWorkspaceController.activePageIndexAfterReorder(
        activeIndex: 1,
        from: 3,
        to: 0,
      ),
      2,
    );
    expect(
      ComicWorkspaceController.activePageIndexAfterReorder(
        activeIndex: 2,
        from: 2,
        to: 0,
      ),
      0,
    );
    expect(
      ComicWorkspaceController.activePageIndexAfterReorder(
        activeIndex: 0,
        from: 2,
        to: 3,
      ),
      0,
    );
  });

  test('comic workspace errors do not expose opaque bridge exceptions', () {
    expect(
      comicWorkspaceErrorMessage(comicExportFailureMessage),
      comicExportFailureMessage,
    );
    expect(
      comicWorkspaceErrorMessage(Object()),
      'Comic operation failed. Please try again.',
    );
    expect(comicWorkspaceErrorMessage(null), isNull);
  });

  testWidgets('comic export failure gives the user a retryable action', (
    tester,
  ) async {
    final controller = _SearchController(
      rust.ComicProjectView(
        id: BigInt.from(10),
        template: 1,
        title: 'Export fixture',
        pageCount: 1,
        pages: <rust.ComicPageView>[_page(1, 'Page one', BigInt.from(1001))],
        materials: const [],
      ),
      errorMessage: comicExportFailureMessage,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: ComicWorkspace(controller: controller)),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Comic project error: $comicExportFailureMessage'),
      findsOneWidget,
    );
    expect(find.textContaining('Instance of'), findsNothing);
  });

  testWidgets('project actions menu keeps comic templates discoverable', (
    tester,
  ) async {
    final controller = _TemplateController(
      rust.ComicProjectView(
        id: BigInt.from(10),
        template: 1,
        title: 'Template fixture',
        pageCount: 1,
        pages: <rust.ComicPageView>[_page(1, 'Page one', BigInt.from(1001))],
        materials: const [],
      ),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: ComicWorkspace(controller: controller)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Project actions'));
    await tester.pumpAndSettle();

    expect(find.text('New illustration'), findsOneWidget);
    expect(find.text('New print comic'), findsOneWidget);
    expect(find.text('New webtoon'), findsOneWidget);
    await tester.tap(find.text('New webtoon'));
    await tester.pumpAndSettle();

    expect(controller.selectedTemplate, 2);
  });

  testWidgets('dialogue search result selects its page', (tester) async {
    final controller = _SearchController(
      rust.ComicProjectView(
        id: BigInt.from(1),
        template: 1,
        title: 'Search fixture',
        pageCount: 2,
        pages: <rust.ComicPageView>[
          _page(1, 'First page', BigInt.from(101)),
          _page(2, 'Second page dialogue', BigInt.from(202)),
        ],
        materials: const [],
      ),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: ComicWorkspace(controller: controller)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Edit page 1'), findsOneWidget);

    await _selectComicSection(tester, 'Text/Balloon');
    await tester.enterText(find.byType(TextField), 'dialogue');
    await tester.tap(find.byTooltip('Search dialogue'));
    await tester.pumpAndSettle();
    expect(find.text('Page 2 • Balloon 202'), findsOneWidget);

    await tester.tap(find.text('Page 2 • Balloon 202'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Page').first);
    await tester.pumpAndSettle();
    expect(find.text('Edit page 2'), findsOneWidget);
  });

  testWidgets('cross-page script saves through the Rust dialogue command', (
    tester,
  ) async {
    final controller = _ScriptController(
      rust.ComicProjectView(
        id: BigInt.from(31),
        template: 1,
        title: 'Script edit fixture',
        pageCount: 2,
        pages: <rust.ComicPageView>[
          _page(1, 'First page line', BigInt.from(3101)),
          _page(2, 'Second page dialogue', BigInt.from(3102)),
        ],
        materials: const [],
      ),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: ComicWorkspace(controller: controller)),
    );
    await tester.pumpAndSettle();
    await _selectComicSection(tester, 'Text/Balloon');
    await tester.enterText(find.byType(TextField).first, 'dialogue');
    await tester.tap(find.byTooltip('Search dialogue'));
    await tester.pumpAndSettle();

    final line = find.byKey(const ValueKey('script-line-3102'));
    expect(line, findsOneWidget);
    await tester.enterText(line, 'Edited from the script view');
    await tester.tap(find.byTooltip('Save dialogue on page 2'));
    await tester.pumpAndSettle();

    expect(controller.editedPageIndex, 1);
    expect(controller.editedBalloonId, BigInt.from(3102));
    expect(controller.editedText, 'Edited from the script view');
  });

  testWidgets('script results resolve their page after page reorder', (
    tester,
  ) async {
    final controller = _ScriptController(
      rust.ComicProjectView(
        id: BigInt.from(32),
        template: 1,
        title: 'Script reorder fixture',
        pageCount: 2,
        pages: <rust.ComicPageView>[
          _page(1, 'First page line', BigInt.from(3201)),
          _page(2, 'Second page dialogue', BigInt.from(3202)),
        ],
        materials: const [],
      ),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: ComicWorkspace(controller: controller)),
    );
    await tester.pumpAndSettle();
    await _selectComicSection(tester, 'Text/Balloon');
    await tester.enterText(find.byType(TextField).first, 'dialogue');
    await tester.tap(find.byTooltip('Search dialogue'));
    await tester.pumpAndSettle();

    await controller.reorderPage(1, 0);
    await tester.pumpAndSettle();
    expect(find.text('Page 1 • Balloon 3202'), findsOneWidget);
    await tester.tap(find.byTooltip('Save dialogue on page 1'));
    await tester.pumpAndSettle();
    expect(controller.editedPageIndex, 0);
    expect(controller.editedBalloonId, BigInt.from(3202));
  });

  testWidgets('script result list reorders with current page order', (
    tester,
  ) async {
    final controller = _ScriptController(
      rust.ComicProjectView(
        id: BigInt.from(33),
        template: 1,
        title: 'Script order fixture',
        pageCount: 2,
        pages: <rust.ComicPageView>[
          _page(1, 'First script line', BigInt.from(3301)),
          _page(2, 'Second script line', BigInt.from(3302)),
        ],
        materials: const [],
      ),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: ComicWorkspace(controller: controller)),
    );
    await tester.pumpAndSettle();
    await _selectComicSection(tester, 'Text/Balloon');
    await tester.enterText(find.byType(TextField).first, 'script');
    await tester.tap(find.byTooltip('Search dialogue'));
    await tester.pumpAndSettle();

    final firstResult = find.text('Page 1 • Balloon 3301');
    final secondResult = find.text('Page 2 • Balloon 3302');
    expect(
      tester.getTopLeft(firstResult).dy,
      lessThan(tester.getTopLeft(secondResult).dy),
    );

    await controller.reorderPage(1, 0);
    await tester.pumpAndSettle();
    final reorderedFirst = find.text('Page 1 • Balloon 3302');
    final reorderedSecond = find.text('Page 2 • Balloon 3301');
    expect(
      tester.getTopLeft(reorderedFirst).dy,
      lessThan(tester.getTopLeft(reorderedSecond).dy),
    );
  });

  testWidgets('removing a page requires confirmation and updates the list', (
    tester,
  ) async {
    final controller = _RemovePageController(
      rust.ComicProjectView(
        id: BigInt.from(21),
        template: 1,
        title: 'Remove page fixture',
        pageCount: 2,
        pages: <rust.ComicPageView>[
          _page(1, 'Keep this page', BigInt.from(2101)),
          _page(2, 'Remove this page', BigInt.from(2102)),
        ],
        materials: const [],
      ),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: ComicWorkspace(controller: controller)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Remove page').last);
    await tester.pumpAndSettle();
    expect(find.text('Remove page?'), findsOneWidget);
    expect(controller.removedIndex, isNull);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(controller.removedIndex, isNull);
    expect(controller.snapshot!.pageCount, 2);

    await tester.tap(find.byTooltip('Remove page').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove page').last);
    await tester.pumpAndSettle();
    expect(controller.removedIndex, 1);
    expect(controller.snapshot!.pageCount, 1);
    expect(find.byTooltip('Remove page'), findsOneWidget);
    expect(find.text('Edit page 1'), findsOneWidget);
  });

  testWidgets('webtoon segmentation shows inspectable slice metadata', (
    tester,
  ) async {
    final controller = _SearchController(
      rust.ComicProjectView(
        id: BigInt.from(2),
        template: 2,
        title: 'Webtoon fixture',
        pageCount: 1,
        pages: <rust.ComicPageView>[_page(1, 'Long page', BigInt.from(301))],
        materials: const [],
      ),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: ComicWorkspace(controller: controller)),
    );
    await tester.pumpAndSettle();
    await _selectComicSection(tester, 'Export');
    await tester.tap(find.text('Webtoon segments'));
    await tester.pumpAndSettle();

    expect(find.text('2 webtoon segments'), findsOneWidget);
    expect(find.text('Source y 2048 • 904px high'), findsOneWidget);
  });

  testWidgets('comic undo and redo controls dispatch editor history', (
    tester,
  ) async {
    final controller = _HistoryController(
      rust.ComicProjectView(
        id: BigInt.from(3),
        template: 1,
        title: 'History fixture',
        pageCount: 1,
        pages: <rust.ComicPageView>[_page(1, 'History page', BigInt.from(401))],
        materials: const [],
      ),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: ComicWorkspace(controller: controller)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Undo comic edit'));
    await tester.tap(find.byTooltip('Redo comic edit'));

    expect(controller.undoCalled, isTrue);
    expect(controller.redoCalled, isTrue);
  });

  testWidgets('panel division exposes direction and ratio before dispatch', (
    tester,
  ) async {
    final controller = _HistoryController(
      rust.ComicProjectView(
        id: BigInt.from(4),
        template: 1,
        title: 'Panel fixture',
        pageCount: 1,
        pages: <rust.ComicPageView>[_page(1, 'Panel page', BigInt.from(501))],
        materials: const [],
      ),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: ComicWorkspace(controller: controller)),
    );
    await tester.pumpAndSettle();
    await _selectComicSection(tester, 'Panel');
    final split = find.text('Split panel');
    await tester.ensureVisible(split);
    await tester.tap(split);
    await tester.pumpAndSettle();
    expect(find.text('Divide panel'), findsOneWidget);
    expect(find.text('Division direction'), findsOneWidget);
    expect(find.text('First panel size'), findsOneWidget);
    expect(find.text('50%'), findsOneWidget);
    await tester.drag(
      find.byKey(const ValueKey<String>('panel-split-preview')),
      const Offset(1000, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text('90%'), findsOneWidget);
    await tester.tap(find.text('Divide'));
    await tester.pumpAndSettle();

    expect(controller.splitCalled, isTrue);
    expect(controller.splitAxis, 0);
    expect(controller.splitRatio, closeTo(0.9, 0.001));
  });

  testWidgets('balloon type menu exposes thought and burst authoring', (
    tester,
  ) async {
    final controller = _BalloonController(
      rust.ComicProjectView(
        id: BigInt.from(5),
        template: 1,
        title: 'Balloon fixture',
        pageCount: 1,
        pages: <rust.ComicPageView>[_page(1, 'Balloon page', BigInt.from(601))],
        materials: const [],
      ),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: ComicWorkspace(controller: controller)),
    );
    await tester.pumpAndSettle();
    await _selectComicSection(tester, 'Text/Balloon');
    await tester.tap(find.byTooltip('Add balloon type'));
    await tester.pumpAndSettle();
    expect(find.text('Thought balloon'), findsOneWidget);
    expect(find.text('Burst balloon'), findsOneWidget);
    await tester.tap(find.text('Thought balloon'));
    await tester.pumpAndSettle();
    expect(controller.addedShape, 1);
  });

  testWidgets('local material library can remove a project asset', (
    tester,
  ) async {
    final material = rust.ComicMaterialView(
      id: BigInt.from(700),
      name: 'Paper texture',
      kind: 'texture',
      license: 'CC0',
      attribution: 'Example artist',
      source: 'local://paper',
    );
    final controller = _MaterialController(
      rust.ComicProjectView(
        id: BigInt.from(6),
        template: 1,
        title: 'Material fixture',
        pageCount: 1,
        pages: <rust.ComicPageView>[
          _page(1, 'Material page', BigInt.from(701)),
        ],
        materials: <rust.ComicMaterialView>[material],
      ),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: ComicWorkspace(controller: controller)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('1 local material'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Remove Paper texture'));
    expect(controller.removedMaterial, BigInt.from(700));
  });

  testWidgets('local material authoring captures license metadata', (
    tester,
  ) async {
    final controller = _MaterialController(
      rust.ComicProjectView(
        id: BigInt.from(7),
        template: 1,
        title: 'Material authoring fixture',
        pageCount: 1,
        pages: <rust.ComicPageView>[
          _page(1, 'Material page', BigInt.from(701)),
        ],
        materials: const [],
      ),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: ComicWorkspace(controller: controller)),
    );
    await tester.pumpAndSettle();
    await _selectComicSection(tester, 'Export');
    await tester.ensureVisible(find.byTooltip('Add local material'));
    await tester.tap(find.byTooltip('Add local material'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add material…'));
    await tester.pumpAndSettle();
    expect(find.text('Add local material'), findsOneWidget);
    final fields = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(fields.at(0), 'Halftone paper');
    await tester.enterText(fields.at(1), 'CC0-1.0');
    await tester.enterText(fields.at(2), 'Example artist');
    await tester.enterText(fields.at(3), 'local://halftone-paper');
    await tester.tap(find.text('Add material'));
    await tester.pumpAndSettle();

    expect(controller.addedMaterialName, 'Halftone paper');
    expect(controller.addedMaterialKind, 'brush');
    expect(controller.addedMaterialLicense, 'CC0-1.0');
    expect(controller.addedMaterialAttribution, 'Example artist');
    expect(controller.addedMaterialSource, 'local://halftone-paper');
  });

  testWidgets('page manager exposes accessible move controls', (tester) async {
    final controller = _PageOrderController(
      rust.ComicProjectView(
        id: BigInt.from(8),
        template: 1,
        title: 'Page order fixture',
        pageCount: 2,
        pages: <rust.ComicPageView>[
          _page(1, 'First page', BigInt.from(801)),
          _page(2, 'Second page', BigInt.from(802)),
        ],
        materials: const [],
      ),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: ComicWorkspace(controller: controller)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Move page down').first);
    expect(controller.movedFrom, 0);
    expect(controller.movedTo, 1);
  });

  testWidgets('screentone editor exposes pattern and print controls', (
    tester,
  ) async {
    final controller = _ToneController(
      rust.ComicProjectView(
        id: BigInt.from(9),
        template: 1,
        title: 'Tone fixture',
        pageCount: 1,
        pages: <rust.ComicPageView>[_page(1, 'Tone page', BigInt.from(901))],
        materials: const [],
      ),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: ComicWorkspace(controller: controller)),
    );
    await tester.pumpAndSettle();
    await _selectComicSection(tester, 'Tone/Effects');
    await tester.ensureVisible(find.text('Screentone'));
    await tester.tap(find.text('Screentone'));
    await tester.pumpAndSettle();
    expect(find.text('Add screentone'), findsOneWidget);
    expect(find.text('Frequency'), findsOneWidget);
    expect(find.text('60 LPI'), findsOneWidget);
    expect(find.text('Density'), findsOneWidget);
    expect(find.text('35%'), findsOneWidget);
    await tester.tap(find.text('Add tone'));
    await tester.pumpAndSettle();
    expect(controller.toneShape, 'circle');
    expect(controller.toneFrequency, closeTo(60, 0.001));
    expect(controller.toneAngle, closeTo(45, 0.001));
    expect(controller.toneDensity, closeTo(0.35, 0.001));
  });

  testWidgets('effect-line editor exposes kind, width, and opacity', (
    tester,
  ) async {
    final controller = _EffectController(
      rust.ComicProjectView(
        id: BigInt.from(10),
        template: 1,
        title: 'Effect fixture',
        pageCount: 1,
        pages: <rust.ComicPageView>[_page(1, 'Effect page', BigInt.from(1001))],
        materials: const [],
      ),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: ComicWorkspace(controller: controller)),
    );
    await tester.pumpAndSettle();
    await _selectComicSection(tester, 'Tone/Effects');
    await tester.ensureVisible(find.text('Effect lines'));
    await tester.tap(find.text('Effect lines'));
    await tester.pumpAndSettle();
    expect(find.text('Add effect lines'), findsOneWidget);
    expect(find.text('Width'), findsOneWidget);
    expect(find.text('8.0 px'), findsOneWidget);
    expect(find.text('Opacity'), findsOneWidget);
    expect(find.text('75%'), findsOneWidget);
    await tester.tap(find.text('Add lines'));
    await tester.pumpAndSettle();
    expect(controller.effectKind, 'speed');
    expect(controller.effectWidth, closeTo(8, 0.001));
    expect(controller.effectOpacity, closeTo(0.75, 0.001));
  });

  testWidgets('existing screentones expose edit and remove actions', (
    tester,
  ) async {
    final tone = rust.ComicTonePreviewView(
      id: BigInt.from(1301),
      frequencyLpi: 72,
      angleDegrees: 30,
      density: 0.5,
      shape: 'line',
      x: 120,
      y: 120,
      width: 960,
      height: 1200,
    );
    final controller = _ToneController(
      rust.ComicProjectView(
        id: BigInt.from(13),
        template: 1,
        title: 'Tone editing fixture',
        pageCount: 1,
        pages: <rust.ComicPageView>[
          _page(
            1,
            'Tone page',
            BigInt.from(1302),
            tones: <rust.ComicTonePreviewView>[tone],
          ),
        ],
        materials: const [],
      ),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: ComicWorkspace(controller: controller)),
    );
    await tester.pumpAndSettle();
    await _selectComicSection(tester, 'Tone/Effects');
    expect(find.text('Line screentone'), findsOneWidget);
    await tester.ensureVisible(find.byTooltip('Edit screentone'));
    await tester.tap(find.byTooltip('Edit screentone'));
    await tester.pumpAndSettle();
    expect(find.text('Edit screentone'), findsOneWidget);
    expect(find.text('Frequency'), findsOneWidget);
    expect(find.text('72 LPI'), findsOneWidget);
    await tester.tap(find.text('Save tone'));
    await tester.pumpAndSettle();
    expect(controller.editedToneShape, 'line');
    await tester.ensureVisible(find.byTooltip('Remove screentone'));
    await tester.tap(find.byTooltip('Remove screentone'));
    expect(controller.removedTone, BigInt.from(1301));
  });

  testWidgets('existing effect lines expose edit and remove actions', (
    tester,
  ) async {
    final line = rust.ComicEffectLinePreviewView(
      id: BigInt.from(1401),
      kind: 'radial',
      points: Float32List.fromList(const <double>[600, 800, 1100, 400]),
      widthPx: 12,
      opacity: 0.6,
    );
    final controller = _EffectController(
      rust.ComicProjectView(
        id: BigInt.from(14),
        template: 1,
        title: 'Effect editing fixture',
        pageCount: 1,
        pages: <rust.ComicPageView>[
          _page(
            1,
            'Effect page',
            BigInt.from(1402),
            effectLines: <rust.ComicEffectLinePreviewView>[line],
          ),
        ],
        materials: const [],
      ),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: ComicWorkspace(controller: controller)),
    );
    await tester.pumpAndSettle();
    await _selectComicSection(tester, 'Tone/Effects');
    expect(find.text('Radial effect lines'), findsOneWidget);
    await tester.ensureVisible(find.byTooltip('Edit effect lines'));
    await tester.tap(find.byTooltip('Edit effect lines'));
    await tester.pumpAndSettle();
    expect(find.text('Edit effect lines'), findsOneWidget);
    expect(find.text('Width'), findsOneWidget);
    expect(find.text('12.0 px'), findsOneWidget);
    await tester.tap(find.text('Save lines'));
    await tester.pumpAndSettle();
    expect(controller.editedEffectKind, 'radial');
    await tester.ensureVisible(find.byTooltip('Remove effect lines'));
    await tester.tap(find.byTooltip('Remove effect lines'));
    expect(controller.removedEffect, BigInt.from(1401));
  });

  testWidgets(
    'page settings editor exposes print metadata without repainting',
    (tester) async {
      final controller = _LayoutController(
        rust.ComicProjectView(
          id: BigInt.from(11),
          template: 1,
          title: 'Layout fixture',
          pageCount: 1,
          pages: <rust.ComicPageView>[
            _page(1, 'Layout page', BigInt.from(1101)),
          ],
          materials: const [],
        ),
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(home: ComicWorkspace(controller: controller)),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Page settings'));
      await tester.tap(find.text('Page settings'));
      await tester.pumpAndSettle();
      expect(find.text('Save settings'), findsOneWidget);
      expect(find.text('Bleed (px)'), findsOneWidget);
      expect(find.text('Trim (px)'), findsOneWidget);
      expect(find.text('Safety (px)'), findsOneWidget);
      expect(find.text('DPI'), findsOneWidget);
      await tester.tap(find.text('Save settings'));
      await tester.pumpAndSettle();
      expect(controller.layoutDpi, closeTo(300, 0.001));
      expect(controller.layoutTrimWidth, closeTo(1104, 0.001));
      expect(controller.layoutSafetyLeft, closeTo(48, 0.001));
    },
  );

  testWidgets('rectangular panel bounds are directly editable', (tester) async {
    final base = _page(1, 'Panel page', BigInt.from(1201));
    final panel = rust.ComicPanelPreviewView(
      id: BigInt.from(1202),
      shape: 0,
      x: 120,
      y: 180,
      width: 480,
      height: 960,
      gutterPx: 24,
      maskLayerId: BigInt.from(1203),
      polygon: Float32List.fromList(const <double>[]),
    );
    final page = rust.ComicPageView(
      id: base.id,
      pageNumber: base.pageNumber,
      widthPx: base.widthPx,
      heightPx: base.heightPx,
      dpi: base.dpi,
      panelCount: 1,
      balloonCount: base.balloonCount,
      toneCount: base.toneCount,
      effectLineCount: base.effectLineCount,
      panels: <rust.ComicPanelPreviewView>[panel],
      balloons: base.balloons,
      tones: base.tones,
      effectLines: base.effectLines,
      bleedLeft: base.bleedLeft,
      bleedTop: base.bleedTop,
      bleedRight: base.bleedRight,
      bleedBottom: base.bleedBottom,
      trimX: base.trimX,
      trimY: base.trimY,
      trimWidth: base.trimWidth,
      trimHeight: base.trimHeight,
      safetyLeft: base.safetyLeft,
      safetyTop: base.safetyTop,
      safetyRight: base.safetyRight,
      safetyBottom: base.safetyBottom,
    );
    final controller = _BoundsController(
      rust.ComicProjectView(
        id: BigInt.from(12),
        template: 1,
        title: 'Bounds fixture',
        pageCount: 1,
        pages: <rust.ComicPageView>[page],
        materials: const [],
      ),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: ComicWorkspace(controller: controller)),
    );
    await tester.pumpAndSettle();
    await _selectComicSection(tester, 'Panel');
    await tester.ensureVisible(find.byTooltip('Edit panel bounds'));
    await tester.tap(find.byTooltip('Edit panel bounds'));
    await tester.pumpAndSettle();
    expect(find.text('Edit panel bounds'), findsOneWidget);
    expect(find.text('Save bounds'), findsOneWidget);
    await tester.tap(find.text('Save bounds'));
    await tester.pumpAndSettle();
    expect(controller.boundsX, closeTo(120, 0.001));
    expect(controller.boundsWidth, closeTo(480, 0.001));
  });
}
