import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../comics/comic_workspace_controller.dart';
import '../bridge/generated/api.dart' as rust;

/// Coordinates one-finger panel splits and divider drags for the shared canvas.
/// Panel geometry and history stay in the Rust-backed workspace controller.
class CanvasPanelToolActions {
  CanvasPanelToolActions({
    required this.workspace,
    required this.documentSize,
    required this.dividerHitTolerance,
    required this.dragThreshold,
    required this.gutterPx,
    required this.borderPx,
    required this.onApplied,
    required this.onPreviewChanged,
    required this.onError,
  });

  final ComicWorkspaceController workspace;
  final Size Function() documentSize;
  final double Function() dividerHitTolerance;
  final double Function() dragThreshold;
  final double Function() gutterPx;
  final double Function() borderPx;
  final Future<void> Function() onApplied;
  final ValueChanged<List<Offset>> onPreviewChanged;
  final ValueChanged<String> onError;

  int? _pointer;
  Offset? _start;
  List<Offset> _points = const [];
  rust.ComicPanelPreviewView? _targetPanel;
  _PanelDivider? _divider;
  static int _nextPanelId = DateTime.now().microsecondsSinceEpoch * 16;

  Future<void> handleEvent(PointerEvent event, Offset position) async {
    if (event is PointerCancelEvent) {
      reset();
      return;
    }
    if (event is PointerDownEvent) {
      if (_pointer != null && _pointer != event.pointer) {
        reset();
        return;
      }
      _pointer = event.pointer;
      if (!workspace.isIllustrationPanelProject) {
        if (!workspace.loading) {
          unawaited(workspace.ensureIllustrationPanelProject());
        }
        _showError('Preparing the Panel tool. Try again in a moment.');
        reset();
        return;
      }
      final page = _activePage;
      if (page == null || workspace.loading) {
        _showError();
        reset();
        return;
      }
      _start = position;
      _targetPanel = _panelAt(page.panels, position);
      _divider = _findDivider(page.panels, position);
      _points =
          _divider == null ? const [] : _dividerPreview(_divider!, position);
      onPreviewChanged(_points);
      return;
    }
    if (_pointer != event.pointer || _start == null) return;
    if (event is PointerMoveEvent) {
      final hasDragged = (position - _start!).distance >= dragThreshold();
      final divider = _divider;
      final nextPoints =
          divider != null
              ? _dividerPreview(divider, position)
              : hasDragged
              ? _splitPreview(_start!, position)
              : const <Offset>[];
      if (nextPoints != _points) {
        _points = nextPoints;
        onPreviewChanged(_points);
      }
      return;
    }
    if (event is! PointerUpEvent) return;

    final start = _start!;
    final pageIndex = workspace.activePageIndex;
    final page = _activePage;
    final divider = _divider;
    try {
      if (page != null && divider != null) {
        await workspace.resizePanelDivider(
          pageIndex: pageIndex,
          firstPanelId: divider.first.id,
          secondPanelId: divider.second.id,
          axis: divider.axis,
          position: divider.axis == 0 ? position.dx : position.dy,
        );
        await onApplied();
      } else if (page != null &&
          (position - start).distance >= dragThreshold()) {
        final panel = _targetPanel;
        final bounds =
            panel == null
                ? Rect.fromLTWH(
                  0,
                  0,
                  documentSize().width,
                  documentSize().height,
                )
                : Rect.fromLTWH(panel.x, panel.y, panel.width, panel.height);
        final horizontal =
            (position.dx - start.dx).abs() >= (position.dy - start.dy).abs();
        final axis = horizontal ? 1 : 0;
        final dividerPosition =
            horizontal
                ? (position.dy + start.dy) / 2
                : (position.dx + start.dx) / 2;
        final extent = axis == 0 ? bounds.width : bounds.height;
        final origin = axis == 0 ? bounds.left : bounds.top;
        final ratio = ((dividerPosition - origin) / extent).clamp(0.1, 0.9);
        await workspace.splitPanel(
          pageIndex: pageIndex,
          panelId: panel?.id ?? _newPanelId(),
          axis: axis,
          ratio: ratio,
          gutterPx: gutterPx(),
          borderPx: borderPx(),
        );
        await onApplied();
      }
    } catch (_) {
      _showError();
    } finally {
      reset();
    }
  }

  void reset() {
    _pointer = null;
    _start = null;
    _points = const [];
    _targetPanel = null;
    _divider = null;
    onPreviewChanged(const []);
  }

  rust.ComicPageView? get _activePage {
    final snapshot = workspace.snapshot;
    final index = workspace.activePageIndex;
    if (snapshot == null || index < 0 || index >= snapshot.pages.length) {
      return null;
    }
    return snapshot.pages[index];
  }

  rust.ComicPanelPreviewView? _panelAt(
    List<rust.ComicPanelPreviewView> panels,
    Offset point,
  ) {
    for (final panel in panels.reversed) {
      if (Rect.fromLTWH(
        panel.x,
        panel.y,
        panel.width,
        panel.height,
      ).contains(point)) {
        return panel;
      }
    }
    return null;
  }

  List<Offset> _dividerPreview(_PanelDivider divider, Offset position) {
    if (divider.axis == 0) {
      final top = math.max(divider.first.y, divider.second.y).toDouble();
      final bottom =
          math
              .min(
                divider.first.y + divider.first.height,
                divider.second.y + divider.second.height,
              )
              .toDouble();
      return [Offset(position.dx, top), Offset(position.dx, bottom)];
    }
    final left = math.max(divider.first.x, divider.second.x).toDouble();
    final right =
        math
            .min(
              divider.first.x + divider.first.width,
              divider.second.x + divider.second.width,
            )
            .toDouble();
    return [Offset(left, position.dy), Offset(right, position.dy)];
  }

  List<Offset> _splitPreview(Offset start, Offset current) {
    final panel = _targetPanel;
    final bounds =
        panel == null
            ? Rect.fromLTWH(0, 0, documentSize().width, documentSize().height)
            : Rect.fromLTWH(panel.x, panel.y, panel.width, panel.height);
    final horizontal =
        (current.dx - start.dx).abs() >= (current.dy - start.dy).abs();
    if (horizontal) {
      final y = (current.dy + start.dy) / 2;
      return [Offset(bounds.left, y), Offset(bounds.right, y)];
    }
    final x = (current.dx + start.dx) / 2;
    return [Offset(x, bounds.top), Offset(x, bounds.bottom)];
  }

  _PanelDivider? _findDivider(
    List<rust.ComicPanelPreviewView> panels,
    Offset point,
  ) {
    final tolerance = dividerHitTolerance();
    _PanelDivider? nearest;
    var nearestDistance = double.infinity;
    for (var firstIndex = 0; firstIndex < panels.length; firstIndex++) {
      for (
        var secondIndex = firstIndex + 1;
        secondIndex < panels.length;
        secondIndex++
      ) {
        final a = panels[firstIndex];
        final b = panels[secondIndex];
        if (a.shape != 0 || b.shape != 0) continue;
        if ((a.y - b.y).abs() <= 1 && (a.height - b.height).abs() <= 1) {
          final left = a.x <= b.x ? a : b;
          final right = identical(left, a) ? b : a;
          final boundary = left.x + left.width;
          final expectedGap = (left.gutterPx + right.gutterPx) / 2;
          final actualGap = right.x - boundary;
          final hitRange = tolerance + expectedGap / 2;
          if (actualGap >= -1 &&
              (actualGap - expectedGap).abs() <= 1 &&
              point.dy >= left.y - tolerance &&
              point.dy <= left.y + left.height + tolerance) {
            final position = (boundary + right.x) / 2;
            final distance = (point.dx - position).abs();
            if (distance <= hitRange && distance < nearestDistance) {
              nearestDistance = distance;
              nearest = _PanelDivider(first: left, second: right, axis: 0);
            }
          }
        }
        if ((a.x - b.x).abs() <= 1 && (a.width - b.width).abs() <= 1) {
          final top = a.y <= b.y ? a : b;
          final bottom = identical(top, a) ? b : a;
          final boundary = top.y + top.height;
          final expectedGap = (top.gutterPx + bottom.gutterPx) / 2;
          final actualGap = bottom.y - boundary;
          final hitRange = tolerance + expectedGap / 2;
          if (actualGap >= -1 &&
              (actualGap - expectedGap).abs() <= 1 &&
              point.dx >= top.x - tolerance &&
              point.dx <= top.x + top.width + tolerance) {
            final position = (boundary + bottom.y) / 2;
            final distance = (point.dy - position).abs();
            if (distance <= hitRange && distance < nearestDistance) {
              nearestDistance = distance;
              nearest = _PanelDivider(first: top, second: bottom, axis: 1);
            }
          }
        }
      }
    }
    return nearest;
  }

  BigInt _newPanelId() => BigInt.from(_nextPanelId++);

  void _showError([String? fallback]) {
    final message = workspace.userFacingError;
    onError(message ?? fallback ?? 'Could not update panels. Try again.');
  }
}

class _PanelDivider {
  const _PanelDivider({
    required this.first,
    required this.second,
    required this.axis,
  });

  final rust.ComicPanelPreviewView first;
  final rust.ComicPanelPreviewView second;
  final int axis;
}
