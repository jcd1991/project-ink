import 'package:flutter/material.dart';

import '../bridge/engine_api.dart';
import 'canvas_diagnostic_recorder.dart';
import 'live_stroke_coordinator.dart';

/// Screen-owned values needed to construct and retire transient stroke preview.
class CanvasStrokePreviewHost {
  const CanvasStrokePreviewHost({
    required this.publishPreviews,
    required this.documentWidth,
    required this.documentHeight,
    required this.isInsideDocument,
    required this.boundPosition,
    required this.color,
    required this.width,
    required this.pressureSize,
    this.pressureSizeReplace,
    required this.opacity,
    required this.pressureOpacity,
    this.pressureCurvePoints = _identityPressureCurve,
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

  final void Function(List<LiveStrokePreview> previews) publishPreviews;
  final int Function() documentWidth;
  final int Function() documentHeight;
  final bool Function(Offset position) isInsideDocument;
  final Offset Function(Offset position) boundPosition;
  final Color Function() color;
  final double Function() width;
  final double Function() pressureSize;
  final bool Function()? pressureSizeReplace;
  final double Function() opacity;
  final double Function() pressureOpacity;
  final List<double> Function() pressureCurvePoints;
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
  CanvasPreviewCoverage? coverageForAcknowledgement(
    StrokeAcknowledgement acknowledgement,
  );
  void advanceCoverage(Map<LiveStrokePreview, int> throughByPreview);
  List<LiveStrokePreview> retireCpuCoveredPreviews();
  void clear();
}

@immutable
class CanvasPreviewCoverage {
  const CanvasPreviewCoverage({required this.preview, required this.index});

  final LiveStrokePreview preview;
  final int index;
}

class _TrackedStrokePreview {
  _TrackedStrokePreview(this.preview);

  LiveStrokePreview preview;
  final LiveStrokeCoordinator coordinator = LiveStrokeCoordinator();
  bool ended = false;
}

/// Owns ephemeral preview point ordering, chunk compaction, and CPU retirement.
/// Rust remains authoritative; the host only exposes screen projections and
/// document coordinate policy needed to draw temporary feedback.
class CanvasStrokePreviewActions implements CanvasTilePreviewActions {
  CanvasStrokePreviewActions(this.host);

  final CanvasStrokePreviewHost host;
  final List<_TrackedStrokePreview> _trackedPreviews =
      <_TrackedStrokePreview>[];
  _TrackedStrokePreview? _activePreview;

  LiveStrokePreview? get currentPreview => _activePreview?.preview;

  @override
  void clear() {
    _activePreview = null;
    _trackedPreviews.clear();
    host.publishPreviews(const <LiveStrokePreview>[]);
    host.setAwaitingPreviewCommit(false);
  }

  @override
  CanvasPreviewCoverage? coverageForAcknowledgement(
    StrokeAcknowledgement acknowledgement,
  ) {
    final sequence = acknowledgement.highestCommittedSequence;
    for (final tracked in _trackedPreviews.reversed) {
      final index = tracked.coordinator.previewIndexForSourceSequence(sequence);
      if (index >= 0) {
        return CanvasPreviewCoverage(preview: tracked.preview, index: index);
      }
    }
    return null;
  }

  @override
  void advanceCoverage(Map<LiveStrokePreview, int> throughByPreview) {
    if (throughByPreview.isEmpty) return;
    for (final tracked in _trackedPreviews) {
      final through = throughByPreview[tracked.preview];
      if (through == null) continue;
      final coveredThrough =
          (through + 1)
              .clamp(
                tracked.preview.confirmedThrough,
                tracked.preview.points.length,
              )
              .toInt();
      tracked.preview = tracked.preview.copyWith(
        confirmedThrough: coveredThrough,
        revision: tracked.preview.revision + 1,
      );
      tracked.coordinator.retireThrough(through);
    }
    _publish();
  }

  @override
  List<LiveStrokePreview> retireCpuCoveredPreviews() {
    final retired = _trackedPreviews
        .where(
          (tracked) =>
              tracked.ended &&
              tracked.preview.confirmedThrough >= tracked.preview.points.length,
        )
        .map((tracked) => tracked.preview)
        .toList(growable: false);
    if (retired.isEmpty) return retired;
    _trackedPreviews.removeWhere(
      (tracked) => retired.contains(tracked.preview),
    );
    _publish();
    _updateAwaitingState();
    return retired;
  }

  int previewIndexForSourceSequence(int sequence) =>
      _coverageForSequence(sequence)?.index ?? -1;

  CanvasPreviewCoverage? _coverageForSequence(int sequence) {
    for (final tracked in _trackedPreviews.reversed) {
      final index = tracked.coordinator.previewIndexForSourceSequence(sequence);
      if (index >= 0) {
        return CanvasPreviewCoverage(preview: tracked.preview, index: index);
      }
    }
    return null;
  }

  int pendingChunkCount(LiveStrokePreview preview) =>
      _trackedFor(preview)?.coordinator.pendingChunkCount(preview) ?? 0;

  int oldestChunkAgeMicros(LiveStrokePreview preview) =>
      _trackedFor(preview)?.coordinator.oldestChunkAgeMicros(preview) ?? 0;

  _TrackedStrokePreview? _trackedFor(LiveStrokePreview preview) =>
      _trackedPreviews
          .where((tracked) => identical(tracked.preview, preview))
          .firstOrNull;

  void _publish() => host.publishPreviews(
    _trackedPreviews.map((tracked) => tracked.preview).toList(growable: false),
  );

  void _updateAwaitingState() => host.setAwaitingPreviewCommit(
    _trackedPreviews.any((tracked) => tracked.ended),
  );

  int beginStroke({
    required Offset position,
    required double pressure,
    required int sourceSequence,
  }) {
    final preview = LiveStrokePreview(
      color: host.color(),
      width: host.width(),
      pressureSize: host.pressureSize(),
      pressureSizeReplace: host.pressureSizeReplace?.call() ?? false,
      opacity: host.opacity(),
      pressureOpacity: host.pressureOpacity(),
      pressureCurvePoints: host.pressureCurvePoints(),
      documentWidth: host.documentWidth(),
      documentHeight: host.documentHeight(),
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
    final tracked = _TrackedStrokePreview(preview);
    _trackedPreviews.add(tracked);
    _activePreview = tracked;
    host.clearLastAcknowledgement();
    host.setPreviewStoppedAtPageEdge(false);
    _publish();
    if (sourceSequence >= 0 && preview.points.isNotEmpty) {
      tracked.coordinator.recordConfirmedSample(sourceSequence, 0);
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
    final tracked = _activePreview;
    if (tracked == null) return -1;
    final preview = tracked.preview;
    final outsideDocument = !host.isInsideDocument(position);
    final startsPath = host.previewStoppedAtPageEdge() && !outsideDocument;
    if (host.previewStoppedAtPageEdge() && !startsPath) return -1;
    if (startsPath) host.setPreviewStoppedAtPageEdge(false);
    final last = preview.points.lastOrNull?.position;
    if (outsideDocument && last == null) return -1;
    final visiblePosition =
        startsPath
            ? host.boundPosition(position)
            : outsideDocument && last != null
            ? _clipEndpoint(last, position)
            : host.boundPosition(position);
    // Include a terminal confirmed position before the bridge commit so CPU
    // acknowledgement can retire the entire visible path.
    if (!isUp || sourceSequence >= 0) {
      final previous = preview.points.lastOrNull;
      if (previous == null ||
          visiblePosition != last ||
          pressure != previous.pressure) {
        final pointIndex = tracked.coordinator.appendPoint(
          preview,
          LiveStrokePreviewPoint(
            visiblePosition,
            pressure,
            sourceSequence: sourceSequence,
          ),
          startsPath: startsPath,
        );
        tracked.coordinator.recordConfirmedSample(sourceSequence, pointIndex);
        tracked.preview = preview.copyWith(
          confirmedThrough: preview.confirmedThrough,
          revision: preview.revision + 1,
        );
        _publish();
      }
      if (last != null &&
          visiblePosition == last &&
          pressure == previous?.pressure &&
          sourceSequence >= 0 &&
          preview.points.isNotEmpty) {
        tracked.coordinator.recordConfirmedSample(
          sourceSequence,
          preview.points.length - 1,
        );
      }
    }
    if (outsideDocument) host.setPreviewStoppedAtPageEdge(true);
    return preview.points.length - 1;
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
    final tracked = _activePreview;
    if (tracked == null) return;
    var preview = tracked.preview;
    final points = preview.points;
    var changed = false;
    for (var index = start; index < samples.length; index++) {
      final sample = samples[index];
      final outside = !host.isInsideDocument(sample.position);
      final startsPath = host.previewStoppedAtPageEdge() && !outside;
      if (host.previewStoppedAtPageEdge() && !startsPath) continue;
      if (startsPath) host.setPreviewStoppedAtPageEdge(false);
      final last = points.lastOrNull?.position;
      if (outside && last == null) continue;
      final point =
          startsPath
              ? host.boundPosition(sample.position)
              : outside && last != null
              ? _clipEndpoint(last, sample.position)
              : host.boundPosition(sample.position);
      final previous = points.lastOrNull;
      if (previous == null ||
          point != last ||
          sample.pressure != previous.pressure) {
        final pointIndex = tracked.coordinator.appendPoint(
          preview,
          LiveStrokePreviewPoint(
            point,
            sample.pressure,
            sourceSequence: sample.sourceSequence,
          ),
          startsPath: startsPath,
        );
        tracked.coordinator.recordConfirmedSample(
          sample.sourceSequence,
          pointIndex,
        );
        changed = true;
      } else if (sample.sourceSequence >= 0 && points.isNotEmpty) {
        tracked.coordinator.recordConfirmedSample(
          sample.sourceSequence,
          points.length - 1,
        );
      }
      // Keep off-page gaps out of the preview path. A later in-page sample
      // starts a new visible segment without connecting across the gap.
      if (outside && last != null) host.setPreviewStoppedAtPageEdge(true);
    }
    final compacted = tracked.coordinator.compactCommittedPrefix(preview);
    changed |= !identical(compacted, preview);
    preview = compacted;
    if (changed) {
      tracked.preview = preview.copyWith(revision: preview.revision + 1);
      _publish();
    }
  }

  void cancelActivePreview() {
    final active = _activePreview;
    _activePreview = null;
    if (active == null) return;
    _trackedPreviews.remove(active);
    _publish();
    _updateAwaitingState();
  }

  void retireIfAlreadyCpuCovered({required String source}) {
    final tracked = _activePreview;
    if (host.strokeActive() || tracked == null) return;
    _activePreview = null;
    tracked.ended = true;
    _updateAwaitingState();
    final preview = tracked.preview;
    if (preview.points.isEmpty) {
      _trackedPreviews.remove(tracked);
      _publish();
      _updateAwaitingState();
      return;
    }
    if (preview.confirmedThrough < preview.points.length) {
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
    _trackedPreviews.remove(tracked);
    _publish();
    host.clearLastAcknowledgement();
    _updateAwaitingState();
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
