import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../bridge/engine_api.dart';
import '../bridge/generated/api.dart' as rust;
import '../comics/comic_workspace_controller.dart';

class VectorInspector extends StatelessWidget {
  const VectorInspector({
    super.key,
    required this.strokes,
    required this.onSimplify,
    required this.onConnect,
    required this.onEditPoint,
  });

  final List<VectorStrokeSummaryView> strokes;
  final VoidCallback onSimplify;
  final VoidCallback onConnect;
  final VoidCallback onEditPoint;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.all(8),
    child: Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Vector ink', style: Theme.of(context).textTheme.labelLarge),
          Text('${strokes.length} stroke(s)'),
          const SizedBox(height: 4),
          Wrap(
            spacing: 4,
            children: [
              OutlinedButton(
                onPressed: strokes.isEmpty ? null : onSimplify,
                child: const Text('Simplify first'),
              ),
              OutlinedButton(
                onPressed: strokes.length < 2 ? null : onConnect,
                child: const Text('Connect first two'),
              ),
              OutlinedButton(
                onPressed:
                    strokes.isEmpty || strokes.first.points.length < 4
                        ? null
                        : onEditPoint,
                child: const Text('Edit first point'),
              ),
            ],
          ),
          if (strokes.isNotEmpty)
            Text(
              'Use Vector transform or Vector eraser on canvas. '
              'Every edit is undoable.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
    ),
  );
}

class ComicCanvasGuideOverlay extends StatelessWidget {
  const ComicCanvasGuideOverlay({
    super.key,
    required this.controller,
    required this.pan,
    required this.scale,
    required this.rotation,
    required this.mirrored,
    required this.documentWidth,
    required this.documentHeight,
    this.activePanelId,
  });

  final ComicWorkspaceController controller;
  final Offset pan;
  final double scale;
  final double rotation;
  final bool mirrored;
  final int documentWidth;
  final int documentHeight;
  final BigInt? activePanelId;

  @override
  Widget build(BuildContext context) {
    final snapshot = controller.snapshot;
    final pageIndex = controller.pagePreviewIndex;
    final page =
        snapshot != null &&
                pageIndex != null &&
                pageIndex >= 0 &&
                pageIndex < snapshot.pages.length
            ? snapshot.pages[pageIndex]
            : null;
    if (page == null) return const SizedBox.shrink();
    return CustomPaint(
      painter: _ComicCanvasGuidePainter(
        page: page,
        pan: pan,
        scale: scale,
        rotation: rotation,
        mirrored: mirrored,
        documentWidth: documentWidth,
        documentHeight: documentHeight,
        activePanelId: activePanelId,
      ),
      child: const SizedBox.expand(),
    );
  }
}

class _ComicCanvasGuidePainter extends CustomPainter {
  const _ComicCanvasGuidePainter({
    required this.page,
    required this.pan,
    required this.scale,
    required this.rotation,
    required this.mirrored,
    required this.documentWidth,
    required this.documentHeight,
    this.activePanelId,
  });

  final rust.ComicPageView page;
  final Offset pan;
  final double scale;
  final double rotation;
  final bool mirrored;
  final int documentWidth;
  final int documentHeight;
  final BigInt? activePanelId;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(size.width / 2 + pan.dx, size.height / 2 + pan.dy);
    canvas.rotate(rotation);
    canvas.scale(mirrored ? -scale : scale, scale);
    final scaleX = documentWidth / page.widthPx.clamp(1, 32768);
    final scaleY = documentHeight / page.heightPx.clamp(1, 32768);
    final origin = Offset(documentWidth / 2, documentHeight / 2);
    Offset toDocument(double x, double y) =>
        Offset(x * scaleX - origin.dx, y * scaleY - origin.dy);
    final border =
        Paint()
          ..color = const Color(0xff38bdf8).withValues(alpha: 0.88)
          ..style = PaintingStyle.stroke
          ..strokeWidth = (2 / scale.clamp(0.1, 32)).clamp(0.5, 4);
    final activeBorder =
        Paint()
          ..color = const Color(0xff34d399).withValues(alpha: 0.95)
          ..style = PaintingStyle.stroke
          ..strokeWidth = (3 / scale.clamp(0.1, 32)).clamp(1.0, 5);
    final gutter =
        Paint()
          ..color = const Color(0xfffbbf24).withValues(alpha: 0.72)
          ..style = PaintingStyle.stroke
          ..strokeWidth = (1 / scale.clamp(0.1, 32)).clamp(0.5, 3);
    for (final panel in page.panels) {
      final rect = Rect.fromLTWH(
        panel.x * scaleX - origin.dx,
        panel.y * scaleY - origin.dy,
        panel.width * scaleX,
        panel.height * scaleY,
      );
      final points = panel.polygon;
      if (points.length >= 6 && points.length.isEven) {
        final path =
            Path()..moveTo(
              toDocument(points[0], points[1]).dx,
              toDocument(points[0], points[1]).dy,
            );
        for (var i = 2; i < points.length; i += 2) {
          final point = toDocument(points[i], points[i + 1]);
          path.lineTo(point.dx, point.dy);
        }
        path.close();
        canvas.drawPath(
          path,
          panel.id == activePanelId ? activeBorder : border,
        );
      } else {
        canvas.drawRect(
          rect,
          panel.id == activePanelId ? activeBorder : border,
        );
      }
      if (panel.gutterPx > 0) {
        canvas.drawRect(
          rect.deflate(panel.gutterPx * math.min(scaleX, scaleY) / 2),
          gutter,
        );
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ComicCanvasGuidePainter oldDelegate) =>
      page != oldDelegate.page ||
      pan != oldDelegate.pan ||
      scale != oldDelegate.scale ||
      rotation != oldDelegate.rotation ||
      mirrored != oldDelegate.mirrored ||
      activePanelId != oldDelegate.activePanelId;
}
