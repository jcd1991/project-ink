import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/canvas/canvas_clipboard_palette.dart';

void main() {
  group('CanvasColorClipboard', () {
    test('encodes and decodes six-digit RGB colors', () {
      const color = Color(0xff1a2b3c);
      expect(CanvasColorClipboard.encode(color), '#1a2b3c');
      expect(CanvasColorClipboard.decode('#1A2B3C'), color);
      expect(CanvasColorClipboard.decode(' 1a2b3c '), color);
    });

    test('rejects clipboard text that is not one RGB color', () {
      expect(CanvasColorClipboard.decode(null), isNull);
      expect(CanvasColorClipboard.decode('not a color'), isNull);
      expect(CanvasColorClipboard.decode('#12345'), isNull);
      expect(CanvasColorClipboard.decode('#12345678'), isNull);
    });
  });

  testWidgets('clipboard palette returns a typed command', (tester) async {
    CanvasClipboardPaletteAction? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder:
              (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    selected = await showModalBottomSheet<
                      CanvasClipboardPaletteAction
                    >(
                      context: context,
                      builder: (_) => const CanvasClipboardPalette(),
                    );
                  },
                  child: const Text('Open'),
                ),
              ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paste brush color'));
    await tester.pumpAndSettle();

    expect(selected, CanvasClipboardPaletteAction.pasteBrushColor);
  });

  testWidgets('palette flow applies a decoded clipboard color', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.getData') {
            return <String, Object?>{'text': '#1a2b3c'};
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    Color? appliedColor;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder:
              (context) => Scaffold(
                body: TextButton(
                  onPressed:
                      () => showCanvasClipboardPalette(
                        context: context,
                        isMounted: () => true,
                        activeColor: () => Colors.black,
                        applyPastedColor: (color) async => appliedColor = color,
                      ),
                  child: const Text('Open'),
                ),
              ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paste brush color'));
    await tester.pumpAndSettle();

    expect(appliedColor, const Color(0xff1a2b3c));
  });
}
