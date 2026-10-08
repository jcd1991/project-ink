import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Ephemeral pointer feedback. It is deliberately separate from the Rust
/// raster tiles: the preview can update at pointer frequency without forcing
/// the layer compositor or side panels to rebuild, and it is never saved.
class LiveStrokePreviewPoint {
  const LiveStrokePreviewPoint(
    this.position,
    this.pressure, {
    this.sourceSequence = -1,
  });

  final Offset position;
  final double pressure;
  final int sourceSequence;
}

// Keep the path drawn directly each frame small. Larger immutable pictures
// remain cached, while the moving tail is limited to 32 pressure-aware edges.
const liveStrokePreviewChunkSize = 32;

/// Owns confirmed input coverage and bounded preview geometry for one active
/// stroke. Source packet sequences may skip because predicted UIKit samples
/// are disposable, so coverage is tracked by both source sequence and the
/// consecutive preview index assigned to each confirmed point.
class LiveStrokeCoordinator {
  final Map<int, int> _previewIndexBySequence = <int, int>{};
  final Stopwatch _chunkAgeClock = Stopwatch()..start();

  void clear() => _previewIndexBySequence.clear();

  void recordConfirmedSample(int sourceSequence, int previewIndex) {
    if (sourceSequence >= 0) {
      _previewIndexBySequence[sourceSequence] = previewIndex;
    }
  }

  int previewIndexForSourceSequence(int sourceSequence) =>
      _previewIndexBySequence[sourceSequence] ?? -1;

  void retireThrough(int previewIndex) {
    _previewIndexBySequence.removeWhere((_, index) => index <= previewIndex);
  }

  int appendPoint(
    LiveStrokePreview preview,
    LiveStrokePreviewPoint point, {
    bool startsPath = false,
  }) {
    preview.points.add(point);
    final lastIndex = preview.points.length - 1;
    if (startsPath) preview.pathStartIndices.add(lastIndex);
    while (lastIndex - preview.chunkedThrough >= liveStrokePreviewChunkSize) {
      final firstIndex = preview.chunkedThrough;
      final finalIndex = firstIndex + liveStrokePreviewChunkSize;
      preview.chunks.add(
        buildLiveStrokePreviewChunk(
          preview,
          firstIndex,
          finalIndex,
          createdAtUs: _chunkAgeClock.elapsedMicroseconds,
        ),
      );
      preview.chunkedThrough = finalIndex;
    }
    recordConfirmedSample(point.sourceSequence, lastIndex);
    return lastIndex;
  }

  LiveStrokePreview compactCommittedPrefix(LiveStrokePreview preview) {
    if (preview.points.length <= 9216 || preview.confirmedThrough <= 1) {
      return preview;
    }
    final removable =
        math.min(preview.points.length - 8192, preview.confirmedThrough - 1) ~/
        liveStrokePreviewChunkSize *
        liveStrokePreviewChunkSize;
    if (removable <= 0) return preview;
    preview.points.removeRange(0, removable);
    final retainedChunks = preview.chunks
        .where((chunk) => chunk.lastPointIndex > removable)
        .map(
          (chunk) => chunk.copyWith(
            firstPointIndex: chunk.firstPointIndex - removable,
            lastPointIndex: chunk.lastPointIndex - removable,
          ),
        )
        .toList(growable: true);
    final entries = _previewIndexBySequence.entries.toList();
    _previewIndexBySequence
      ..clear()
      ..addEntries(
        entries
            .where((entry) => entry.value >= removable)
            .map((entry) => MapEntry(entry.key, entry.value - removable)),
      );
    final retainedPathStarts =
        preview.pathStartIndices
            .where((index) => index > removable)
            .map((index) => index - removable)
            .toSet();
    return preview.copyWith(
      confirmedThrough:
          (preview.confirmedThrough - removable)
              .clamp(1, preview.points.length)
              .toInt(),
      revision: preview.revision + 1,
      chunks: retainedChunks,
      chunkedThrough: math.max(0, preview.chunkedThrough - removable),
      pathStartIndices: retainedPathStarts,
    );
  }

  int oldestChunkAgeMicros(LiveStrokePreview preview) {
    // CPU-covered chunks remain cached until the stroke ends so the painter
    // can reuse them if the uncommitted tail crosses a chunk boundary. They
    // are not pending preview work once their final point is CPU-covered.
    final oldest =
        preview.chunks
            .where((chunk) => chunk.lastPointIndex >= preview.confirmedThrough)
            .firstOrNull;
    if (oldest == null) return 0;
    return (_chunkAgeClock.elapsedMicroseconds - oldest.createdAtUs).clamp(
      0,
      0x7fffffffffffffff,
    );
  }

  int pendingChunkCount(LiveStrokePreview preview) =>
      preview.chunks
          .where((chunk) => chunk.lastPointIndex >= preview.confirmedThrough)
          .length;
}

class LiveStrokePreviewChunk {
  const LiveStrokePreviewChunk({
    required this.firstPointIndex,
    required this.lastPointIndex,
    required this.picture,
    required this.createdAtUs,
  });

  final int firstPointIndex;
  final int lastPointIndex;
  final ui.Picture picture;
  final int createdAtUs;

  LiveStrokePreviewChunk copyWith({
    int? firstPointIndex,
    int? lastPointIndex,
  }) => LiveStrokePreviewChunk(
    firstPointIndex: firstPointIndex ?? this.firstPointIndex,
    lastPointIndex: lastPointIndex ?? this.lastPointIndex,
    picture: picture,
    createdAtUs: createdAtUs,
  );
}

LiveStrokePreviewChunk buildLiveStrokePreviewChunk(
  LiveStrokePreview preview,
  int firstPointIndex,
  int lastPointIndex, {
  required int createdAtUs,
}) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final origin = Offset(preview.documentWidth / 2, preview.documentHeight / 2);
  final paint =
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
  for (var index = firstPointIndex + 1; index <= lastPointIndex; index++) {
    if (preview.pathStartIndices.contains(index)) continue;
    final previous = preview.points[index - 1];
    final current = preview.points[index];
    paint.color = _liveStrokePreviewColorAt(
      preview,
      (previous.pressure + current.pressure) * 0.5,
    );
    paint.strokeWidth =
        (liveStrokePreviewWidthAt(preview, previous) +
            liveStrokePreviewWidthAt(preview, current)) *
        0.5;
    canvas.drawLine(
      previous.position - origin,
      current.position - origin,
      paint,
    );
  }
  return LiveStrokePreviewChunk(
    firstPointIndex: firstPointIndex,
    lastPointIndex: lastPointIndex,
    picture: recorder.endRecording(),
    createdAtUs: createdAtUs,
  );
}

double liveStrokePreviewWidthAt(
  LiveStrokePreview preview,
  LiveStrokePreviewPoint point,
) {
  final pressure = point.pressure.clamp(0.0, 1.0);
  final mappedPressure = _evaluatePressureCurve(
    preview.pressureCurvePoints,
    pressure,
  );
  final pressureScale = 1 + preview.pressureSize * mappedPressure;
  return math.max(0.75, preview.width * pressureScale).toDouble();
}

double liveStrokePreviewOpacityAt(LiveStrokePreview preview, double pressure) {
  final mappedPressure = _evaluatePressureCurve(
    preview.pressureCurvePoints,
    pressure.clamp(0.0, 1.0),
  );
  return (preview.opacity * (1 + preview.pressureOpacity * mappedPressure))
      .clamp(0.0, 1.0)
      .toDouble();
}

Color _liveStrokePreviewColorAt(LiveStrokePreview preview, double pressure) =>
    preview.color.withValues(
      alpha:
          preview.color.a *
          liveStrokePreviewOpacityAt(preview, pressure) *
          (preview.eraser ? 0.82 : 1.0),
    );

double _evaluatePressureCurve(List<double> points, double pressure) {
  if (points.length < 4 || points.length.isOdd) return pressure;
  for (var index = 0; index + 3 < points.length; index += 2) {
    final leftX = points[index];
    final leftY = points[index + 1];
    final rightX = points[index + 2];
    final rightY = points[index + 3];
    if (pressure <= rightX) {
      final span = rightX - leftX;
      if (span <= 0) return rightY;
      final progress = ((pressure - leftX) / span).clamp(0.0, 1.0);
      return leftY + (rightY - leftY) * progress;
    }
  }
  return points.last;
}

class LiveStrokePreview {
  LiveStrokePreview({
    required this.color,
    required this.width,
    required this.pressureSize,
    this.opacity = 1.0,
    this.pressureOpacity = 0.0,
    required this.documentWidth,
    required this.documentHeight,
    this.pressureCurvePoints = const <double>[0, 0, 1, 1],
    required this.eraser,
    required this.points,
    required this.chunks,
    Set<int>? pathStartIndices,
    this.chunkedThrough = 0,
    this.revision = 0,
    this.confirmedThrough = 0,
  }) : pathStartIndices = pathStartIndices ?? <int>{};

  final Color color;
  final double width;
  final double pressureSize;
  final double opacity;
  final double pressureOpacity;
  final int documentWidth;
  final int documentHeight;
  final List<double> pressureCurvePoints;
  final bool eraser;
  final List<LiveStrokePreviewPoint> points;
  final List<LiveStrokePreviewChunk> chunks;
  final Set<int> pathStartIndices;
  int chunkedThrough;
  final int revision;

  /// Number of leading preview samples already accepted by Rust. The painter
  /// draws only the unconfirmed suffix, preventing duplicate pixels while the
  /// bridge queue catches up.
  final int confirmedThrough;

  LiveStrokePreview copyWith({
    List<LiveStrokePreviewPoint>? points,
    int? revision,
    int? confirmedThrough,
    List<LiveStrokePreviewChunk>? chunks,
    int? chunkedThrough,
    Set<int>? pathStartIndices,
  }) => LiveStrokePreview(
    color: color,
    width: width,
    pressureSize: pressureSize,
    opacity: opacity,
    pressureOpacity: pressureOpacity,
    documentWidth: documentWidth,
    documentHeight: documentHeight,
    pressureCurvePoints: pressureCurvePoints,
    eraser: eraser,
    points: points ?? this.points,
    chunks: chunks ?? this.chunks,
    pathStartIndices: pathStartIndices ?? this.pathStartIndices,
    chunkedThrough: chunkedThrough ?? this.chunkedThrough,
    revision: revision ?? this.revision,
    confirmedThrough: confirmedThrough ?? this.confirmedThrough,
  );
}

class LiveStrokePreviewPainter extends CustomPainter {
  const LiveStrokePreviewPainter({
    required this.pan,
    required this.scale,
    required this.rotation,
    required this.mirrored,
    required this.documentWidth,
    required this.documentHeight,
    required this.preview,
    this.onSlowPaint,
  });

  final Offset pan;
  final double scale;
  final double rotation;
  final bool mirrored;
  final int documentWidth;
  final int documentHeight;
  final LiveStrokePreview? preview;
  final void Function(int elapsedMicros, int directSegments, int pictures)?
  onSlowPaint;

  @override
  void paint(Canvas canvas, Size size) {
    final active = preview;
    if (active == null || active.points.isEmpty) return;
    if (active.confirmedThrough >= active.points.length) return;
    final paintClock = Stopwatch()..start();
    var directSegments = 0;
    var pictures = 0;
    final startIndex = math.max(0, active.confirmedThrough - 1);
    final visiblePointCount = active.points.length - startIndex;
    canvas.save();
    canvas.translate(size.width / 2 + pan.dx, size.height / 2 + pan.dy);
    canvas.rotate(rotation);
    canvas.scale(mirrored ? -scale : scale, scale);
    final paint =
        Paint()
          ..color = _liveStrokePreviewColorAt(
            active,
            active.points[startIndex].pressure,
          )
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = liveStrokePreviewWidthAt(
            active,
            active.points[startIndex],
          );
    if (visiblePointCount == 1) {
      final point = active.points[startIndex].position;
      canvas.drawCircle(
        point - Offset(documentWidth / 2, documentHeight / 2),
        paint.strokeWidth / 2,
        paint..style = PaintingStyle.fill,
      );
    } else {
      final origin = Offset(documentWidth / 2, documentHeight / 2);
      var paintedThrough = startIndex;
      void drawRawThrough(int finalIndex) {
        for (var index = paintedThrough + 1; index <= finalIndex; index++) {
          if (index >= active.points.length) break;
          if (active.pathStartIndices.contains(index)) continue;
          final previous = active.points[index - 1];
          final current = active.points[index];
          paint.color = _liveStrokePreviewColorAt(
            active,
            (previous.pressure + current.pressure) * 0.5,
          );
          paint.strokeWidth =
              (liveStrokePreviewWidthAt(active, previous) +
                  liveStrokePreviewWidthAt(active, current)) *
              0.5;
          canvas.drawLine(
            previous.position - origin,
            current.position - origin,
            paint,
          );
          directSegments++;
        }
        paintedThrough = math.max(paintedThrough, finalIndex);
      }

      for (final chunk in active.chunks) {
        if (chunk.lastPointIndex <= paintedThrough) continue;
        if (chunk.firstPointIndex > paintedThrough) {
          drawRawThrough(chunk.firstPointIndex);
        }
        if (chunk.firstPointIndex >= paintedThrough) {
          canvas.drawPicture(chunk.picture);
          pictures++;
        } else {
          drawRawThrough(chunk.lastPointIndex);
        }
        paintedThrough = math.max(paintedThrough, chunk.lastPointIndex);
      }
      drawRawThrough(active.points.length - 1);
    }
    canvas.restore();
    paintClock.stop();
    if (paintClock.elapsedMicroseconds >= 2000) {
      onSlowPaint?.call(
        paintClock.elapsedMicroseconds,
        directSegments,
        pictures,
      );
    }
  }

  @override
  bool shouldRepaint(covariant LiveStrokePreviewPainter oldDelegate) =>
      preview?.revision != oldDelegate.preview?.revision ||
      preview?.confirmedThrough != oldDelegate.preview?.confirmedThrough ||
      pan != oldDelegate.pan ||
      scale != oldDelegate.scale ||
      rotation != oldDelegate.rotation ||
      mirrored != oldDelegate.mirrored;
}
