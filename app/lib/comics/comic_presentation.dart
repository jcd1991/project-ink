import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../bridge/generated/api.dart' as rust;
import '../design_system/ink_components.dart';

class ComicPageCanvasPainter extends CustomPainter {
  const ComicPageCanvasPainter({required this.page});

  final rust.ComicPageView page;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xfff7f7f5),
    );
    if (page.widthPx <= 0 || page.heightPx <= 0) return;
    final scale = math.min(
      (size.width - 8) / page.widthPx,
      (size.height - 8) / page.heightPx,
    );
    canvas.save();
    canvas.translate((size.width - page.widthPx * scale) / 2, 4);
    canvas.scale(scale, scale);
    final panelFill = Paint()..color = const Color.fromRGBO(55, 100, 160, .12);
    final panelBorder =
        Paint()
          ..color = const Color(0xff234f7d)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4 / scale;
    final balloonFill = Paint()..color = const Color(0xeeffffff);
    final balloonBorder =
        Paint()
          ..color = const Color(0xff252525)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3 / scale;
    final guide =
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 / scale;
    guide.color = const Color(0xff2563eb);
    canvas.drawRect(
      Rect.fromLTWH(page.trimX, page.trimY, page.trimWidth, page.trimHeight),
      guide,
    );
    guide.color = const Color(0xffd97706);
    canvas.drawRect(
      Rect.fromLTWH(
        page.trimX + page.safetyLeft,
        page.trimY + page.safetyTop,
        page.trimWidth - page.safetyLeft - page.safetyRight,
        page.trimHeight - page.safetyTop - page.safetyBottom,
      ),
      guide,
    );
    for (final panel in page.panels) {
      final rect = Rect.fromLTWH(panel.x, panel.y, panel.width, panel.height);
      canvas.drawRect(rect, panelFill);
      if (panel.shape == 1 && panel.polygon.length >= 6) {
        final path = Path()..moveTo(panel.polygon[0], panel.polygon[1]);
        for (var i = 2; i + 1 < panel.polygon.length; i += 2) {
          path.lineTo(panel.polygon[i], panel.polygon[i + 1]);
        }
        path.close();
        canvas.drawPath(path, panelBorder);
      } else {
        canvas.drawRect(rect, panelBorder);
      }
    }
    Path burstPath(Rect rect) {
      final path = Path();
      final center = rect.center;
      for (var index = 0; index < 24; index++) {
        final angle = index * math.pi * 2 / 24 - math.pi / 2;
        final radiusX = (index.isEven ? rect.width : rect.width * .68) / 2;
        final radiusY = (index.isEven ? rect.height : rect.height * .68) / 2;
        final point = Offset(
          center.dx + radiusX * math.cos(angle),
          center.dy + radiusY * math.sin(angle),
        );
        if (index == 0) {
          path.moveTo(point.dx, point.dy);
        } else {
          path.lineTo(point.dx, point.dy);
        }
      }
      return path..close();
    }

    for (final balloon in page.balloons) {
      final rect = Rect.fromLTWH(
        balloon.x,
        balloon.y,
        balloon.width,
        balloon.height,
      );
      if (balloon.tail.length >= 4) {
        final tail = Path()..moveTo(balloon.tail[0], balloon.tail[1]);
        for (var i = 2; i + 1 < balloon.tail.length; i += 2) {
          tail.lineTo(balloon.tail[i], balloon.tail[i + 1]);
        }
        canvas.drawPath(tail, balloonBorder);
      }
      if (balloon.shape == 2) {
        final rounded = RRect.fromRectAndRadius(
          rect,
          const Radius.circular(12),
        );
        canvas.drawRRect(rounded, balloonFill);
        canvas.drawRRect(rounded, balloonBorder);
      } else if (balloon.shape == 1) {
        canvas.drawOval(rect, balloonFill);
        canvas.drawOval(rect, balloonBorder);
        final minDimension = math.min(rect.width, rect.height);
        final bubbleOne = Rect.fromCircle(
          center: Offset(
            rect.left + rect.width * .2,
            rect.bottom + minDimension * .08,
          ),
          radius: math.max(4, minDimension * .07),
        );
        final bubbleTwo = Rect.fromCircle(
          center: Offset(
            rect.left + rect.width * .1,
            rect.bottom + minDimension * .17,
          ),
          radius: math.max(3, minDimension * .045),
        );
        for (final bubble in [bubbleOne, bubbleTwo]) {
          canvas.drawOval(bubble, balloonFill);
          canvas.drawOval(bubble, balloonBorder);
        }
      } else if (balloon.shape == 3) {
        final burst = burstPath(rect);
        canvas.drawPath(burst, balloonFill);
        canvas.drawPath(burst, balloonBorder);
      } else {
        canvas.drawOval(rect, balloonFill);
        canvas.drawOval(rect, balloonBorder);
      }
      final previewText =
          balloon.text.length > 80
              ? '${balloon.text.substring(0, 80)}…'
              : balloon.text;
      final textPainter = TextPainter(
        text: TextSpan(
          text: previewText,
          style: const TextStyle(color: Colors.black, fontSize: 26),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 3,
        ellipsis: '…',
      )..layout(maxWidth: (rect.width - 24).clamp(1, 2000).toDouble());
      textPainter.paint(
        canvas,
        Offset(
          rect.center.dx - textPainter.width / 2,
          rect.center.dy - textPainter.height / 2,
        ),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant ComicPageCanvasPainter oldDelegate) =>
      oldDelegate.page != page;
}

class PanelSplitPreviewPainter extends CustomPainter {
  const PanelSplitPreviewPainter({required this.axis, required this.ratio});

  final int axis;
  final double ratio;

  @override
  void paint(Canvas canvas, Size size) {
    final background = Paint()..color = const Color(0xfff5f7fb);
    final first = Paint()..color = const Color(0xffdbeafe);
    final second = Paint()..color = const Color(0xffede9fe);
    final border =
        Paint()
          ..color = const Color(0xff475569)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2;
    final divider =
        Paint()
          ..color = const Color(0xff1d4ed8)
          ..strokeWidth = 4;
    final rect = Offset.zero & size;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(8)),
      background,
    );
    final clamped = ratio.clamp(0.1, 0.9).toDouble();
    if (axis == 0) {
      final splitX = size.width * clamped;
      canvas.drawRect(Rect.fromLTRB(0, 0, splitX, size.height), first);
      canvas.drawRect(
        Rect.fromLTRB(splitX, 0, size.width, size.height),
        second,
      );
      canvas.drawLine(Offset(splitX, 0), Offset(splitX, size.height), divider);
    } else {
      final splitY = size.height * clamped;
      canvas.drawRect(Rect.fromLTRB(0, 0, size.width, splitY), first);
      canvas.drawRect(
        Rect.fromLTRB(0, splitY, size.width, size.height),
        second,
      );
      canvas.drawLine(Offset(0, splitY), Offset(size.width, splitY), divider);
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(8)),
      border,
    );
  }

  @override
  bool shouldRepaint(PanelSplitPreviewPainter oldDelegate) =>
      axis != oldDelegate.axis || ratio != oldDelegate.ratio;
}

class ComicThumbnailPainter extends CustomPainter {
  const ComicThumbnailPainter({required this.page});

  final rust.ComicPageView page;

  @override
  void paint(Canvas canvas, Size size) {
    final pagePaint = Paint()..color = const Color(0xfffafafa);
    final borderPaint =
        Paint()
          ..color = const Color(0xff616161)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1;
    final pageRect = Offset.zero & size;
    canvas.drawRRect(
      RRect.fromRectAndRadius(pageRect, const Radius.circular(4)),
      pagePaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(pageRect, const Radius.circular(4)),
      borderPaint,
    );
    if (page.widthPx <= 0 || page.heightPx <= 0) return;
    final scale = math.min(
      (size.width - 6) / page.widthPx,
      (size.height - 6) / page.heightPx,
    );
    canvas.save();
    canvas.translate(3, 3);
    canvas.scale(scale, scale);
    final panelFill = Paint()..color = const Color.fromRGBO(80, 120, 180, .12);
    final panelBorder =
        Paint()
          ..color = const Color(0xff355a89)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3 / scale;
    final maskBorder =
        Paint()
          ..color = const Color(0xffc77c00)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 / scale;
    for (final panel in page.panels) {
      final rect = Rect.fromLTWH(panel.x, panel.y, panel.width, panel.height);
      canvas.drawRect(rect, panelFill);
      final panelPaint = panel.maskLayerId == null ? panelBorder : maskBorder;
      if (panel.shape == 1 && panel.polygon.length >= 6) {
        final path = Path()..moveTo(panel.polygon[0], panel.polygon[1]);
        for (var i = 2; i + 1 < panel.polygon.length; i += 2) {
          path.lineTo(panel.polygon[i], panel.polygon[i + 1]);
        }
        path.close();
        canvas.drawPath(path, panelPaint);
      } else {
        canvas.drawRect(rect, panelPaint);
      }
      if (panel.maskLayerId != null) {
        canvas.drawLine(rect.topLeft, rect.bottomRight, maskBorder);
        canvas.drawLine(rect.topRight, rect.bottomLeft, maskBorder);
      }
    }
    final balloonFill = Paint()..color = const Color(0xeeffffff);
    final balloonBorder =
        Paint()
          ..color = const Color(0xff303030)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 / scale;
    for (final balloon in page.balloons) {
      final rect = Rect.fromLTWH(
        balloon.x,
        balloon.y,
        balloon.width,
        balloon.height,
      );
      if (balloon.shape == 2) {
        canvas.drawRect(rect, balloonFill);
        canvas.drawRect(rect, balloonBorder);
      } else {
        canvas.drawOval(rect, balloonFill);
        canvas.drawOval(rect, balloonBorder);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant ComicThumbnailPainter oldDelegate) =>
      oldDelegate.page != page;
}

class PrintPreviewSummary extends StatelessWidget {
  const PrintPreviewSummary({
    super.key,
    required this.report,
    this.previewBytes,
    this.page,
  });

  final rust.ComicPrintPreviewView report;
  final Uint8List? previewBytes;
  final rust.ComicPageView? page;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final safe = report.bleedSafe && report.safetySafe;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: InkPanelSurface(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  safe ? Icons.check_circle : Icons.warning_amber,
                  color: safe ? colorScheme.primary : colorScheme.error,
                ),
                const SizedBox(width: 8),
                Text(
                  safe
                      ? 'Print-safe geometry'
                      : 'Print preview needs attention',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ],
            ),
            Text(
              '${report.pageCount} pages • bleed ${report.bleedSafe ? 'OK' : 'outside trim'} • safety ${report.safetySafe ? 'OK' : 'too tight'}',
            ),
            if (previewBytes != null)
              ConstrainedBox(
                constraints: const BoxConstraints(
                  maxHeight: 220,
                  maxWidth: 180,
                ),
                child: Image.memory(
                  previewBytes!,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  semanticLabel: 'Raster print preview',
                ),
              )
            else if (page != null)
              SizedBox(
                height: 120,
                width: 92,
                child: CustomPaint(painter: PrintGuidePainter(page: page!)),
              ),
            for (final warning in report.moireWarnings)
              Text(warning, style: TextStyle(color: colorScheme.error)),
          ],
        ),
      ),
    );
  }
}

class PrintGuidePainter extends CustomPainter {
  const PrintGuidePainter({required this.page});

  final rust.ComicPageView page;

  @override
  void paint(Canvas canvas, Size size) {
    final pagePaint = Paint()..color = const Color(0xfffafafa);
    final border =
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1;
    canvas.drawRect(Offset.zero & size, pagePaint);
    if (page.widthPx <= 0 || page.heightPx <= 0) return;
    final scale = math.min(
      (size.width - 4) / page.widthPx,
      (size.height - 4) / page.heightPx,
    );
    canvas.save();
    canvas.translate(2, 2);
    canvas.scale(scale, scale);
    border.color = const Color(0xff2563eb);
    canvas.drawRect(
      Rect.fromLTWH(page.trimX, page.trimY, page.trimWidth, page.trimHeight),
      border,
    );
    border.color = const Color(0xffd97706);
    canvas.drawRect(
      Rect.fromLTWH(
        page.trimX + page.safetyLeft,
        page.trimY + page.safetyTop,
        page.trimWidth - page.safetyLeft - page.safetyRight,
        page.trimHeight - page.safetyTop - page.safetyBottom,
      ),
      border,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant PrintGuidePainter oldDelegate) =>
      oldDelegate.page != page;
}

class WebtoonSegmentsSummary extends StatelessWidget {
  const WebtoonSegmentsSummary({super.key, required this.segments});

  final List<rust.ComicWebtoonSegmentView> segments;

  @override
  Widget build(BuildContext context) {
    const visibleLimit = 16;
    final visible = segments.take(visibleLimit).toList(growable: false);
    return InkPanelSurface(
      padding: EdgeInsets.zero,
      child: InkInspectorSection(
        title: '${segments.length} webtoon segments',
        leading: const Icon(Icons.view_stream),
        initiallyExpanded: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final segment in visible)
              InkInspectorRow(
                icon: const Icon(Icons.crop_free, size: 18),
                title: 'Segment ${segment.segmentIndex + 1}',
                subtitle:
                    'Source y ${segment.sourceY} • ${segment.heightPx}px high',
                selected: false,
              ),
            if (segments.length > visibleLimit)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'Showing the first $visibleLimit slices; export includes all ${segments.length}.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class ComicPageThumbnail extends StatelessWidget {
  const ComicPageThumbnail({super.key, required this.page});

  final rust.ComicPageView page;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 54,
      height: 72,
      child: CustomPaint(
        painter: ComicThumbnailPainter(page: page),
        child: Center(
          child: Text(
            '${page.pageNumber}',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Colors.black54,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}

class MaterialsSummary extends StatelessWidget {
  const MaterialsSummary({
    super.key,
    required this.materials,
    required this.onRemove,
  });

  final List<rust.ComicMaterialView> materials;
  final Future<void> Function(BigInt materialId) onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: InkPanelSurface(
        padding: EdgeInsets.zero,
        child: InkInspectorSection(
          leading: const Icon(Icons.collections_bookmark_outlined),
          title:
              '${materials.length} local material${materials.length == 1 ? '' : 's'}',
          subtitle: 'License and attribution travel with the project',
          initiallyExpanded: false,
          child: Column(
            children: [
              for (final material in materials)
                InkInspectorRow(
                  selected: false,
                  title: material.name,
                  subtitle:
                      '${material.kind} • ${material.license}${material.attribution == null ? '' : ' • ${material.attribution}'}',
                  icon: const Icon(Icons.collections_bookmark_outlined),
                  trailing: InkCommandButton(
                    label: 'Remove ${material.name}',
                    icon: Icons.delete_outline,
                    onPressed: () => onRemove(material.id),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
