import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/canvas/canvas_color_picker_controls.dart';
import 'package:project_ink/canvas/canvas_phone_color_picker.dart';
import 'package:project_ink/canvas/canvas_workspace_panel_sheets.dart';

void main() {
  testWidgets('phone color sheet edits both roles in one surface', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Color? appliedMain;
    Color? appliedSub;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder:
                (context) => FilledButton(
                  onPressed: () {
                    showCanvasPhoneColorSheet(
                      context: context,
                      mainColor: Colors.black,
                      subColor: Colors.white,
                      recentColors: const ['#FFFF0000'],
                      onApply: (main, sub) async {
                        appliedMain = main;
                        appliedSub = sub;
                      },
                    );
                  },
                  child: const Text('Open color'),
                ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open color'));
    await tester.pumpAndSettle();
    expect(find.byType(CanvasPhoneColorPickerPanel), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Advanced color controls'), findsOneWidget);
    expect(tester.takeException(), isNull);

    final dragHandle = find.byKey(const ValueKey('phone-panel-drag-handle'));
    final initialHandleTop = tester.getTopLeft(dragHandle).dy;
    await tester.drag(dragHandle, const Offset(0, -180));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(dragHandle).dy, lessThan(initialHandleTop));

    await tester.tap(find.bySemanticsLabel('Sub color'));
    await tester.pumpAndSettle();
    final squareBounds = tester.getRect(find.byType(CanvasColorSquare));
    await tester.tapAt(
      squareBounds.topLeft +
          Offset(squareBounds.width * 0.8, squareBounds.height * 0.2),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    expect(appliedMain, Colors.black);
    expect(appliedSub, isNot(Colors.white));
    expect(find.byType(CanvasPhoneColorPickerPanel), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
