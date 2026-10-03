import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/app/editor_action.dart';
import 'package:project_ink/canvas/canvas_brush_color_actions.dart';

void main() {
  testWidgets('accepted picker result runs through color action ownership', (
    tester,
  ) async {
    final events = <String>[];
    final actions = CanvasBrushColorActions(
      CanvasBrushColorActionsHost(
        isMounted: () => true,
        mainColor: () => Colors.blue,
        subColor: () => Colors.white,
        recentColors: () => const [],
        finishDanglingStroke: () async => events.add('drain'),
        publishColors: ({mainColor, subColor, cacheMainColor = false}) {
          events.add('publish:${mainColor?.toARGB32()}');
        },
        persistRecentColors: (_) => events.add('persist'),
        updateRustBrushColor: (color) async {
          events.add('rust:${color.toARGB32()}');
          return true;
        },
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder:
              (context) => Scaffold(
                body: TextButton(
                  onPressed: () => actions.showColorPicker(context: context),
                  child: const Text('Choose'),
                ),
              ),
        ),
      ),
    );

    await tester.tap(find.text('Choose'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    expect(events, [
      'drain',
      'publish:${Colors.blue.toARGB32()}',
      'persist',
      'rust:${Colors.blue.toARGB32()}',
    ]);
  });

  test(
    'main color drains input, publishes and persists, then updates Rust',
    () async {
      final events = <String>[];
      List<String>? persisted;
      Color? publishedMain;
      var cachedMain = false;
      final actions = CanvasBrushColorActions(
        CanvasBrushColorActionsHost(
          isMounted: () => true,
          mainColor: () => Colors.black,
          subColor: () => Colors.white,
          recentColors: () => ['#FF112233', '#AABBCC80'],
          finishDanglingStroke: () async => events.add('drain'),
          publishColors: ({mainColor, subColor, cacheMainColor = false}) {
            events.add('publish');
            publishedMain = mainColor;
            cachedMain = cacheMainColor;
          },
          persistRecentColors: (colors) {
            events.add('persist');
            persisted = colors;
          },
          updateRustBrushColor: (color) async {
            events.add('rust');
            return true;
          },
        ),
      );

      await actions.applyMainColor(const Color(0xff112233));

      expect(events, ['drain', 'publish', 'persist', 'rust']);
      expect(publishedMain, const Color(0xff112233));
      expect(cachedMain, isTrue);
      expect(persisted, ['#FF112233', '#AABBCC80']);
    },
  );

  test('pasted color waits for Rust acceptance before publishing', () async {
    final events = <String>[];
    final actions = CanvasBrushColorActions(
      CanvasBrushColorActionsHost(
        isMounted: () => true,
        mainColor: () => Colors.black,
        subColor: () => Colors.white,
        recentColors: () => const [],
        finishDanglingStroke: () async => events.add('unexpected drain'),
        publishColors: ({mainColor, subColor, cacheMainColor = false}) {
          events.add('publish');
        },
        persistRecentColors: (_) => events.add('unexpected persist'),
        updateRustBrushColor: (_) async {
          events.add('rust');
          return false;
        },
      ),
    );

    await actions.applyPastedColor(Colors.red);

    expect(events, ['rust']);
  });

  test(
    'sub color updates presentation and recent history without a Rust write',
    () {
      List<String>? persisted;
      var publishedSubColor = Colors.transparent;
      final actions = CanvasBrushColorActions(
        CanvasBrushColorActionsHost(
          isMounted: () => true,
          mainColor: () => Colors.black,
          subColor: () => Colors.white,
          recentColors: () => ['#FFFFFFFF'],
          finishDanglingStroke: () async {},
          publishColors: ({mainColor, subColor, cacheMainColor = false}) {
            publishedSubColor = subColor ?? publishedSubColor;
          },
          persistRecentColors: (colors) => persisted = colors,
          updateRustBrushColor:
              (_) async => fail('Unexpected Rust brush write'),
        ),
      );

      actions.selectSubColor(const Color(0xff123456));

      expect(publishedSubColor, const Color(0xff123456));
      expect(persisted, ['#FF123456', '#FFFFFFFF']);
    },
  );

  test('swap and reset publish colors before bridge writes', () async {
    Color projectedMainColor = Colors.blue;
    Color projectedSubColor = Colors.orange;
    final writes = <Color>[];
    final actions = CanvasBrushColorActions(
      CanvasBrushColorActionsHost(
        isMounted: () => true,
        mainColor: () => projectedMainColor,
        subColor: () => projectedSubColor,
        recentColors: () => const [],
        finishDanglingStroke: () async {},
        publishColors: ({mainColor, subColor, cacheMainColor = false}) {
          projectedMainColor = mainColor ?? projectedMainColor;
          projectedSubColor = subColor ?? projectedSubColor;
        },
        persistRecentColors: (_) {},
        updateRustBrushColor: (color) async {
          writes.add(color);
          return true;
        },
      ),
    );

    await actions.swapColors();
    expect(projectedMainColor, Colors.orange);
    expect(projectedSubColor, Colors.blue);
    await actions.resetColors();
    expect(projectedMainColor, Colors.black);
    expect(projectedSubColor, Colors.white);
    expect(writes, [Colors.orange, Colors.black]);
  });

  test('routes color commands and declines unrelated editor actions', () async {
    var updateCount = 0;
    final actions = CanvasBrushColorActions(
      CanvasBrushColorActionsHost(
        isMounted: () => true,
        mainColor: () => Colors.black,
        subColor: () => Colors.white,
        recentColors: () => const [],
        finishDanglingStroke: () async {},
        publishColors: ({mainColor, subColor, cacheMainColor = false}) {},
        persistRecentColors: (_) {},
        updateRustBrushColor: (_) async {
          updateCount++;
          return true;
        },
      ),
    );

    expect(actions.dispatchEditorAction(EditorActionId.swapColors), isTrue);
    expect(actions.dispatchEditorAction(EditorActionId.undo), isFalse);
    await Future<void>.delayed(Duration.zero);

    expect(updateCount, 1);
  });
}
