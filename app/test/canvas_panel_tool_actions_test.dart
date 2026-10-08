import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/bridge/generated/api.dart' as rust;
import 'package:project_ink/canvas/canvas_panel_tool_actions.dart';
import 'package:project_ink/comics/comic_workspace_controller.dart';

void main() {
  test('small finger drift does not add an unintended panel', () async {
    final workspace = _PanelWorkspace(_project(const []));
    final actions = _actions(workspace);

    await actions.handleEvent(
      const PointerDownEvent(pointer: 1),
      const Offset(400, 100),
    );
    await actions.handleEvent(
      const PointerMoveEvent(pointer: 1),
      const Offset(414, 108),
    );
    await actions.handleEvent(
      const PointerUpEvent(pointer: 1),
      const Offset(414, 108),
    );

    expect(workspace.splitCalls, isEmpty);
  });

  test('one-finger drag splits the active illustration panel', () async {
    final workspace = _PanelWorkspace(_project(const []));
    final actions = _actions(workspace);

    await actions.handleEvent(
      const PointerDownEvent(pointer: 1),
      const Offset(400, 100),
    );
    await actions.handleEvent(
      const PointerMoveEvent(pointer: 1),
      const Offset(400, 900),
    );
    await actions.handleEvent(
      const PointerUpEvent(pointer: 1),
      const Offset(400, 900),
    );

    expect(workspace.splitCalls, hasLength(1));
    expect(workspace.splitCalls.single.axis, 0);
    expect(workspace.splitCalls.single.ratio, closeTo(400 / 1024, 0.001));
    expect(workspace.splitCalls.single.gutterPx, 24);
    expect(workspace.splitCalls.single.borderPx, 2);
  });

  test('dragging the gutter resizes its adjacent panels', () async {
    final workspace = _PanelWorkspace(
      _project([
        _panel(id: 7, x: 0, y: 0, width: 492, height: 1024),
        _panel(id: 8, x: 532, y: 0, width: 492, height: 1024),
      ]),
    );
    final actions = _actions(workspace);

    await actions.handleEvent(
      const PointerDownEvent(pointer: 1),
      const Offset(512, 300),
    );
    await actions.handleEvent(
      const PointerMoveEvent(pointer: 1),
      const Offset(548, 300),
    );
    await actions.handleEvent(
      const PointerUpEvent(pointer: 1),
      const Offset(548, 300),
    );

    expect(workspace.resizeCalls, hasLength(1));
    expect(workspace.resizeCalls.single.axis, 0);
    expect(workspace.resizeCalls.single.firstPanelId, BigInt.from(7));
    expect(workspace.resizeCalls.single.secondPanelId, BigInt.from(8));
    expect(workspace.resizeCalls.single.position, 548);
  });

  test('dragging a vertical gutter adjusts the stacked panels', () async {
    final workspace = _PanelWorkspace(
      _project([
        _panel(id: 9, x: 0, y: 0, width: 1024, height: 492),
        _panel(id: 10, x: 0, y: 532, width: 1024, height: 492),
      ]),
    );
    final actions = _actions(workspace);

    await actions.handleEvent(
      const PointerDownEvent(pointer: 1),
      const Offset(400, 512),
    );
    await actions.handleEvent(
      const PointerMoveEvent(pointer: 1),
      const Offset(400, 548),
    );
    await actions.handleEvent(
      const PointerUpEvent(pointer: 1),
      const Offset(400, 548),
    );

    expect(workspace.resizeCalls, hasLength(1));
    expect(workspace.resizeCalls.single.axis, 1);
    expect(workspace.resizeCalls.single.firstPanelId, BigInt.from(9));
    expect(workspace.resizeCalls.single.secondPanelId, BigInt.from(10));
    expect(workspace.resizeCalls.single.position, 548);
  });
}

CanvasPanelToolActions _actions(_PanelWorkspace workspace) =>
    CanvasPanelToolActions(
      workspace: workspace,
      documentSize: () => const Size(1024, 1024),
      dividerHitTolerance: () => 24,
      dragThreshold: () => 24,
      gutterPx: () => 24,
      borderPx: () => 2,
      onApplied: () async {},
      onPreviewChanged: (_) {},
      onError: fail,
    );

class _PanelWorkspace extends ComicWorkspaceController {
  _PanelWorkspace(this.project);

  final rust.ComicProjectView project;
  final List<({int axis, double ratio, double gutterPx, double borderPx})>
  splitCalls = [];
  final List<
    ({BigInt firstPanelId, BigInt secondPanelId, int axis, double position})
  >
  resizeCalls = [];

  @override
  rust.ComicProjectView? get snapshot => project;

  @override
  int get activePageIndex => 0;

  @override
  bool get loading => false;

  @override
  String? get userFacingError => null;

  @override
  bool get isIllustrationPanelProject => true;

  @override
  Future<void> ensureIllustrationPanelProject() async {}

  @override
  Future<void> splitPanel({
    required int pageIndex,
    required BigInt panelId,
    required int axis,
    required double ratio,
    required double gutterPx,
    required double borderPx,
  }) async {
    splitCalls.add((
      axis: axis,
      ratio: ratio,
      gutterPx: gutterPx,
      borderPx: borderPx,
    ));
  }

  @override
  Future<void> resizePanelDivider({
    required int pageIndex,
    required BigInt firstPanelId,
    required BigInt secondPanelId,
    required int axis,
    required double position,
  }) async {
    resizeCalls.add((
      firstPanelId: firstPanelId,
      secondPanelId: secondPanelId,
      axis: axis,
      position: position,
    ));
  }
}

rust.ComicProjectView _project(List<rust.ComicPanelPreviewView> panels) =>
    rust.ComicProjectView(
      id: BigInt.one,
      template: 0,
      title: 'Illustration',
      pageCount: 1,
      pages: [
        rust.ComicPageView(
          id: BigInt.from(2),
          pageNumber: 1,
          widthPx: 1024,
          heightPx: 1024,
          dpi: 300,
          panelCount: panels.length,
          balloonCount: 0,
          toneCount: 0,
          effectLineCount: 0,
          panels: panels,
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
        ),
      ],
      materials: const [],
    );

rust.ComicPanelPreviewView _panel({
  required int id,
  required double x,
  required double y,
  required double width,
  required double height,
}) => rust.ComicPanelPreviewView(
  id: BigInt.from(id),
  shape: 0,
  x: x,
  y: y,
  width: width,
  height: height,
  gutterPx: 40,
  borderPx: 2,
  panelGroupId: BigInt.from(100 + id),
  maskLayerId: BigInt.from(200 + id),
  sketchLayerId: BigInt.from(300 + id),
  inkLayerId: BigInt.from(400 + id),
  colorLayerId: BigInt.from(500 + id),
  toneLayerId: BigInt.from(600 + id),
  effectsLayerId: BigInt.from(700 + id),
  polygon: Float32List.fromList(const []),
);
