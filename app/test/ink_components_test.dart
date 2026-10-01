import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/design_system/ink_components.dart';
import 'package:project_ink/design_system/ink_theme.dart';

void main() {
  testWidgets(
    'InkCommandButton exposes its label, selection, and touch target',
    (tester) async {
      final semanticsHandle = tester.ensureSemantics();
      var activations = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: InkTheme.dark(),
          home: Scaffold(
            body: Center(
              child: InkCommandButton(
                icon: Icons.flip,
                label: 'Mirror canvas',
                selected: true,
                hitSize: 48,
                onPressed: () => activations++,
              ),
            ),
          ),
        ),
      );

      final button = find.byType(InkCommandButton);
      expect(tester.getSize(button), const Size(48, 48));
      expect(find.bySemanticsLabel('Mirror canvas'), findsOneWidget);
      expect(
        find.semantics.byFlag(ui.SemanticsFlag.isSelected),
        findsOneWidget,
      );
      expect(find.semantics.byAction(ui.SemanticsAction.tap), findsWidgets);

      await tester.tap(button);
      expect(activations, 1);
      expect(tester.takeException(), isNull);
      semanticsHandle.dispose();
    },
  );

  testWidgets('disabled InkCommandButton does not dispatch its action', (
    tester,
  ) async {
    var activations = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: InkTheme.dark(),
        home: const Scaffold(
          body: InkCommandButton(
            icon: Icons.save,
            label: 'Save project',
            onPressed: null,
          ),
        ),
      ),
    );

    await tester.tap(find.byType(InkCommandButton));
    expect(activations, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('InkDialogAction is labeled and touch-sized on narrow layouts', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final semanticsHandle = tester.ensureSemantics();
    var activations = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: InkTheme.dark(),
        home: Scaffold(
          body: Center(
            child: InkDialogAction(
              label: 'Save settings',
              primary: true,
              onPressed: () => activations++,
            ),
          ),
        ),
      ),
    );

    final action = find.byType(InkDialogAction);
    expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
    expect(find.bySemanticsLabel('Save settings'), findsOneWidget);
    await tester.tap(action);
    expect(activations, 1);
    expect(tester.takeException(), isNull);
    semanticsHandle.dispose();
  });

  testWidgets('InkSelectableChip exposes selection and touch-sized semantics', (
    tester,
  ) async {
    final semanticsHandle = tester.ensureSemantics();
    var activations = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: InkTheme.dark(),
        home: Scaffold(
          body: Center(
            child: InkSelectableChip(
              label: 'Watercolor',
              selected: true,
              leading: const Icon(Icons.brush),
              onPressed: () => activations++,
            ),
          ),
        ),
      ),
    );

    final chip = find.byType(InkSelectableChip);
    expect(tester.getSize(chip).height, greaterThanOrEqualTo(48));
    expect(find.bySemanticsLabel('Watercolor'), findsOneWidget);
    expect(find.semantics.byFlag(ui.SemanticsFlag.isSelected), findsOneWidget);
    await tester.tap(chip);
    expect(activations, 1);
    expect(tester.takeException(), isNull);
    semanticsHandle.dispose();
  });

  testWidgets('InkInspectorRow remains readable and touch-sized at 200% text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final semanticsHandle = tester.ensureSemantics();
    var activations = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: InkTheme.dark(highContrast: true),
        home: Builder(
          builder:
              (context) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(2)),
                child: Scaffold(
                  body: InkInspectorRow(
                    title: 'Very long active drawing layer name',
                    subtitle: 'Raster layer • clipping enabled',
                    icon: const Icon(Icons.layers),
                    selected: true,
                    onTap: () => activations++,
                  ),
                ),
              ),
        ),
      ),
    );

    final row = find.byType(InkInspectorRow);
    expect(tester.getSize(row).height, greaterThanOrEqualTo(48));
    expect(find.text('Very long active drawing layer name'), findsOneWidget);
    expect(find.semantics.byFlag(ui.SemanticsFlag.isSelected), findsOneWidget);
    await tester.tap(row);
    expect(activations, 1);
    expect(tester.takeException(), isNull);
    semanticsHandle.dispose();
  });

  testWidgets('InkToggleChip exposes its toggle state and touch target', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final semanticsHandle = tester.ensureSemantics();
    var nextValue = true;
    await tester.pumpWidget(
      MaterialApp(
        theme: InkTheme.dark(),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: 248,
                child: InkToggleChip(
                  label: 'Alpha lock',
                  value: false,
                  icon: Icons.lock,
                  onChanged: (value) => nextValue = value,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final toggle = find.byType(InkToggleChip);
    expect(tester.getSize(toggle).height, greaterThanOrEqualTo(40));
    expect(find.bySemanticsLabel('Alpha lock'), findsOneWidget);
    await tester.tap(toggle);
    expect(nextValue, isTrue);
    expect(tester.takeException(), isNull);
    semanticsHandle.dispose();
  });

  testWidgets('InkMenuItem is readable at touch scale and invokes once', (
    tester,
  ) async {
    var activations = 0;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: InkTheme.dark(),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: 248,
                child: InkMenuItem(
                  label: 'Enable clipping',
                  subtitle: 'Clip to the layer beneath',
                  icon: Icons.layers,
                  onPressed: () => activations++,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final item = find.byType(InkMenuItem);
    expect(tester.getSize(item).height, greaterThanOrEqualTo(48));
    expect(find.bySemanticsLabel('Enable clipping'), findsOneWidget);
    await tester.tap(item);
    expect(activations, 1);
    expect(tester.takeException(), isNull);
  });
}
