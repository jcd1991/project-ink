import 'package:flutter/material.dart';

import '../bridge/engine_api.dart';
import 'canvas_diagnostic_recorder.dart';
import 'live_stroke_coordinator.dart';

/// Screen-owned values needed to construct and retire transient stroke preview.
class CanvasStrokePreviewHost {
  const CanvasStrokePreviewHost({
    required this.preview,
    required this.publishPreview,
    required this.documentWidth,
    required this.documentHeight,
    required this.isInsideDocument,
    required this.boundPosition,
    required this.color,
    required this.width,
    required this.pressureSize,
    this.pressureCurvePoints = _identityPressureCurve,
    required this.legacyTechnicalPen,
    required this.eraser,
    required this.previewStoppedAtPageEdge,
    required this.setPreviewStoppedAtPageEdge,
    required this.strokeActive,
    required this.awaitingPreviewCommit,
    required this.setAwaitingPreviewCommit,
    required this.lastAcknowledgement,
    required this.clearLastAcknowledgement,
    required this.diagnostics,
  });

  final LiveStrokePreview? Function() preview;
  final void Function(LiveStrokePreview? preview) publishPreview;
  final int Function() documentWidth;
  final int Function() documentHeight;
  final bool Function(Offset position) isInsideDocument;
  final Offset Function(Offset position) boundPosition;
  final Color Function() color;
  final double Function() width;
  final double Function() pressureSize;
  final List<double> Function() pressureCurvePoints;
  final bool Function() legacyTechnicalPen;
  final bool Function() eraser;
  final bool Function() previewStoppedAtPageEdge;
  final void Function(bool stopped) setPreviewStoppedAtPageEdge;
  final bool Function() strokeActive;
  final bool Function() awaitingPreviewCommit;
  final void Function(bool awaiting) setAwaitingPreviewCommit;
  final StrokeAcknowledgement? Function() lastAcknowledgement;
  final void Function() clearLastAcknowledgement;
  final CanvasDiagnosticRecorder diagnostics;
}

List<double> _identityPressureCurve() => const <double>[0, 0, 1, 1];

/// The acknowledgement operations needed by CPU tile publication.
abstract interface class CanvasTilePreviewActions {
  int previewIndexForAcknowledgement(StrokeAcknowledgement acknowledgement);
  void retireThrough(int previewIndex);
  void clear();
}

/// Owns ephemeral preview point ordering, chunk compaction, and CPU retirement.
/// Rust remains authoritative; the host only exposes screen projections and
/// document coordinate policy needed to draw temporary feedback.
class CanvasStrokePreviewActions implements CanvasTilePreviewActions {
  CanvasStrokePreviewActions(this.host);

  final CanvasStrokePreviewHost host;
  final LiveStrokeCoordinator _coordinator = LiveStrokeCoordinator();

  @override
  void clear() => _coordinator.clear();

  @override
  void retireThrough(int previewIndex) =>
      _coordinator.retireThrough(previewIndex);

  @override
  int previewIndexForAcknowledgement(StrokeAcknowledgement acknowledgement) =>
      previewIndexForSourceSequence(acknowledgement.highestCommittedSequence);

  int previewIndexForSourceSequence(int sequence) =>
      _coordinator.previewIndexForSourceSequence(sequence);

  int pendingChunkCount(LiveStrokePreview preview) =>
      _coordinator.pendingChunkCount(preview);

  int oldestChunkAgeMicros(LiveStrokePreview preview) =>
      _coordinator.oldestChunkAgeMicros(preview);

  int beginStroke({
    required Offset position,
    required double pressure,
    required int sourceSequence,
  }) {
    _coordinator.clear();
    host.clearLastAcknowledgement();
    host.setPreviewStoppedAtPageEdge(false);
    host.setAwaitingPreviewCommit(false);
    final preview = LiveStrokePreview(
      color: host.color(),
      width: host.width(),
      pressureSize: host.pressureSize(),
      pressureCurvePoints: host.pressureCurvePoints(),
      documentWidth: host.documentWidth(),
      documentHeight: host.documentHeight(),
      legacyTechnicalPen: host.legacyTechnicalPen(),
      eraser: host.eraser(),
      points: <LiveStrokePreviewPoint>[
        if (host.isInsideDocument(position))
          LiveStrokePreviewPoint(
            host.boundPosition(position),
            pressure,
            sourceSequence: sourceSequence,
          ),
      ],
      chunks: <LiveStrokePreviewChunk>[],
    );
    host.publishPreview(preview);
    if (sourceSequence >= 0 && preview.points.isNotEmpty) {
      _coordinator.recordConfirmedSample(sourceSequence, 0);
    }
    host.setPreviewStoppedAtPageEdge(false);
    return 0;
  }

  int appendSample({
    required Offset position,
    required double pressure,
    required int sourceSequence,
    required bool isUp,
  }) {
    final preview = host.preview();
    if (preview == null || host.previewStoppedAtPageEdge()) return -1;
    final outsideDocument = !host.isInsideDocument(position);
    final last = preview.points.lastOrNull?.position;
    if (outsideDocument && last == null) return -1;
    final visiblePosition =
        outsideDocument && last != null
            ? _clipEndpoint(last, position)
            : host.boundPosition(position);
    // Include a terminal confirmed position before the bridge commit so CPU
    // acknowledgement can retire the entire visible path.
    if (!isUp || sourceSequence >= 0) {
      final previous = preview.points.lastOrNull;
      if (previous == null ||
          visiblePosition != last ||
          pressure != previous.pressure) {
        final pointIndex = _coordinator.appendPoint(
          preview,
          LiveStrokePreviewPoint(
            visiblePosition,
            pressure,
            sourceSequence: sourceSequence,
          ),
        );
        _coordinator.recordConfirmedSample(sourceSequence, pointIndex);
        host.publishPreview(
          preview.copyWith(
            confirmedThrough: preview.confirmedThrough,
            revision: preview.revision + 1,
          ),
        );
      }
      if (last != null &&
          visiblePosition == last &&
          pressure == previous?.pressure &&
          sourceSequence >= 0 &&
          preview.points.isNotEmpty) {
        _coordinator.recordConfirmedSample(
          sourceSequence,
          preview.points.length - 1,
        );
      }
    }
    if (outsideDocument) host.setPreviewStoppedAtPageEdge(true);
    return (host.preview()?.points.length ?? preview.points.length) - 1;
  }

  void appendNativeBatch(
    List<LiveStrokePreviewPoint> samples, {
    required bool beginsStroke,
  }) {
    if (samples.isEmpty) return;
    var start = 0;
    if (beginsStroke) {
      beginStroke(
        position: samples.first.position,
        pressure: samples.first.pressure,
        sourceSequence: samples.first.sourceSequence,
      );
      start = 1;
    }
    var preview = host.preview();
    if (preview == null) return;
    final points = preview.points;
    var changed = false;
    for (var index = start; index < samples.length; index++) {
      final sample = samples[index];
      if (host.previewStoppedAtPageEdge()) break;
      final outside = !host.isInsideDocument(sample.position);
      final last = points.lastOrNull?.position;
      if (outside && last == null) continue;
      final point =
          outside && last != null
              ? _clipEndpoint(last, sample.position)
              : host.boundPosition(sample.position);
      final previous = points.lastOrNull;
      if (previous == null ||
          point != last ||
          sample.pressure != previous.pressure) {
        final pointIndex = _coordinator.appendPoint(
          preview,
          LiveStrokePreviewPoint(
            point,
            sample.pressure,
            sourceSequence: sample.sourceSequence,
          ),
        );
        _coordinator.recordConfirmedSample(sample.sourceSequence, pointIndex);
        changed = true;
      } else if (sample.sourceSequence >= 0 && points.isNotEmpty) {
        _coordinator.recordConfirmedSample(
          sample.sourceSequence,
          points.length - 1,
        );
      }
      // Off-page initial samples do not suppress a path that later enters the
      // document. An exit after a visible point stops the ephemeral tail.
      if (outside && last != null) host.setPreviewStoppedAtPageEdge(true);
    }
    final compacted = _coordinator.compactCommittedPrefix(preview);
    changed |= !identical(compacted, preview);
    preview = compacted;
    if (changed) {
      host.publishPreview(preview.copyWith(revision: preview.revision + 1));
    }
  }

  void retireIfAlreadyCpuCovered({required String source}) {
    final preview = host.preview();
    if (host.strokeActive() ||
        !host.awaitingPreviewCommit() ||
        preview == null ||
        preview.points.isEmpty ||
        preview.confirmedThrough < preview.points.length) {
      return;
    }
    final acknowledgement = host.lastAcknowledgement();
    host.diagnostics.record('canvas.live_preview_retired', {
      'strokeId': acknowledgement?.stroke.toString(),
      'throughSourceSequence':
          acknowledgement?.highestCommittedSequence ??
          preview.points.last.sourceSequence,
      'previewIndex': preview.confirmedThrough - 1,
      'pointCount': preview.points.length,
      'cpuRevision': acknowledgement?.revision,
      'commitId': null,
      'terminalAcknowledgementInCurrentRefresh': false,
      'retirementAfterTerminalWithoutDirtyTiles': true,
      'source': source,
    });
    host.publishPreview(null);
    _coordinator.clear();
    host.clearLastAcknowledgement();
    host.setAwaitingPreviewCommit(false);
  }

  Offset _clipEndpoint(Offset start, Offset end) {
    final delta = end - start;
    var amount = 1.0;
    final maxX = host.documentWidth() - 1;
    final maxY = host.documentHeight() - 1;
    if (delta.dx < 0 && end.dx < 0) {
      amount = amount < -start.dx / delta.dx ? amount : -start.dx / delta.dx;
    } else if (delta.dx > 0 && end.dx > maxX) {
      final crossing = (maxX - start.dx) / delta.dx;
      amount = amount < crossing ? amount : crossing;
    }
    if (delta.dy < 0 && end.dy < 0) {
      final crossing = -start.dy / delta.dy;
      amount = amount < crossing ? amount : crossing;
    } else if (delta.dy > 0 && end.dy > maxY) {
      final crossing = (maxY - start.dy) / delta.dy;
      amount = amount < crossing ? amount : crossing;
    }
    return host.boundPosition(start + delta * amount.clamp(0.0, 1.0));
  }
}
