import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../tools/illustration_tools.dart';
import 'canvas_diagnostic_recorder.dart';
import 'live_stroke_coordinator.dart';
import 'native_pointer_packet_adapter.dart';
import 'native_pointer_packet_queue.dart';
import 'native_pointer_stream.dart';
import 'pointer_packet.dart';

/// Screen callbacks needed to compose native Pencil packet arrival services.
class NativePencilInputHost {
  const NativePencilInputHost({
    required this.documentReplacementInProgress,
    required this.disposed,
    required this.activeTool,
    required this.diagnostics,
    required this.discardConcurrentTouchGesture,
    required this.beginStrokeAutosaveHold,
    required this.markPacketReceived,
    required this.transformPosition,
    this.transformHoverPosition,
    this.updateHoverPosition,
    required this.nextSequence,
    required this.appendPreviewBatch,
    required this.schedulePreviewFrameDiagnostic,
    required this.previewIndexForSequence,
    required this.strokeConstraintMode,
    required this.setStylusLastPosition,
    required this.recordInputArrival,
    required this.armDrawAndHold,
    required this.handleSerialPacket,
    required this.abortStrokeAfterPacketError,
    required this.scheduleDrain,
    required this.onQueueIdle,
  });

  final bool Function() documentReplacementInProgress;
  final bool Function() disposed;
  final IllustrationTool Function() activeTool;
  final CanvasDiagnosticRecorder diagnostics;
  final VoidCallback discardConcurrentTouchGesture;
  final VoidCallback beginStrokeAutosaveHold;
  final void Function(Uint8List packet) markPacketReceived;
  final Offset Function(Offset position, bool isDownSample) transformPosition;
  final Offset Function(Offset position)? transformHoverPosition;
  final ValueChanged<Offset?>? updateHoverPosition;
  final int Function() nextSequence;
  final void Function(
    List<LiveStrokePreviewPoint> samples, {
    required bool beginsStroke,
  })
  appendPreviewBatch;
  final VoidCallback schedulePreviewFrameDiagnostic;
  final int? Function(int sequence) previewIndexForSequence;
  final String Function() strokeConstraintMode;
  final ValueChanged<Offset> setStylusLastPosition;
  final VoidCallback recordInputArrival;
  final ValueChanged<Offset> armDrawAndHold;
  final Future<void> Function(Uint8List packet) handleSerialPacket;
  final Future<void> Function() abortStrokeAfterPacketError;
  final VoidCallback scheduleDrain;
  final VoidCallback onQueueIdle;
}

/// Owns native Pencil contact filtering, packet adaptation, and queue dispatch.
///
/// Preview construction and canvas transforms stay with the screen host;
/// ordered engine work remains in the native Pencil stroke coordinator.
class NativePencilInputCoordinator {
  NativePencilInputCoordinator(this.host);

  final NativePencilInputHost host;
  final NativePointerPacketAdapter _packetAdapter =
      NativePointerPacketAdapter();
  final NativePointerPacketQueue _packetQueue = NativePointerPacketQueue();
  final Stopwatch _arrivalClock = Stopwatch()..start();
  bool _contactActive = false;

  bool get contactActive => _contactActive;
  int get pendingPacketCount => _packetQueue.pendingCount;
  bool get drainScheduled => _packetQueue.isDrainScheduled;
  int get elapsedMicroseconds => _arrivalClock.elapsedMicroseconds;

  void clearQueuedPackets() => _packetQueue.clear();

  void resetContact() => _contactActive = false;

  void handlePacket(Uint8List packet) {
    final diagnostics = host.diagnostics;
    final packetArrivalUs =
        diagnostics.isRecording ? diagnostics.elapsedMicroseconds : null;
    diagnostics.recordPacket(
      'input.native_packet',
      'native_pointer_event_channel',
      packet,
    );

    if (_packetAdapter.containsHoverSample(packet)) {
      final position = _packetAdapter.hoverPosition(packet);
      host.updateHoverPosition?.call(
        position == null
            ? null
            : (host.transformHoverPosition ?? (value) => value)(position),
      );
      return;
    }

    if (host.documentReplacementInProgress()) {
      try {
        if (packetHasPhase(packet, InkPointerPhase.up) ||
            packetHasPhase(packet, InkPointerPhase.cancel)) {
          _contactActive = false;
        }
      } catch (error, stack) {
        diagnostics.recordError('native_pointer_packet', error, stack);
      }
      return;
    }

    final contactWasActive = _contactActive;
    late final bool hasDown;
    late final bool hasUp;
    late final bool hasCancel;
    try {
      hasDown = packetHasPhase(packet, InkPointerPhase.down);
      hasUp = packetHasPhase(packet, InkPointerPhase.up);
      hasCancel = packetHasPhase(packet, InkPointerPhase.cancel);
      if (hasDown) {
        _contactActive = true;
        host.discardConcurrentTouchGesture();
      }
      if (hasUp || hasCancel) _contactActive = false;
    } catch (error, stack) {
      diagnostics.recordError('native_pointer_packet', error, stack);
      debugPrint('Project Ink native pointer packet rejected: $error\n$stack');
      return;
    }
    if (!contactWasActive && !hasDown) {
      diagnostics.record('input.native_packet_ignored', {
        'reason': 'outside_active_pencil_contact',
        'terminalPacket': hasUp || hasCancel,
      });
      return;
    }
    final activeTool = host.activeTool();
    if (activeTool != IllustrationTool.brush &&
        activeTool != IllustrationTool.eraser) {
      return;
    }
    if (hasDown) host.beginStrokeAutosaveHold();
    try {
      host.markPacketReceived(packet);
    } catch (error, stack) {
      diagnostics.recordError('native_pointer_packet', error, stack);
      debugPrint('Project Ink native pointer packet rejected: $error\n$stack');
      return;
    }

    // Prepare confirmed presentation samples before queuing Rust work so the
    // visible Pencil path does not wait for the serial engine worker.
    final preparedPacket = _packetAdapter.prepare(
      packet,
      transformPosition: host.transformPosition,
      nextSequence: host.nextSequence,
    );
    if (preparedPacket.previewSamples.isNotEmpty) {
      final samples = preparedPacket.previewSamples;
      host.appendPreviewBatch(
        samples,
        beginsStroke: preparedPacket.beginsStroke,
      );
      host.schedulePreviewFrameDiagnostic();
      diagnostics.record('canvas.live_input_accepted', {
        'device': 'stylus',
        'confirmedSamples': samples.length,
        'confirmedPreviewIndexStart': host.previewIndexForSequence(
          samples.first.sourceSequence,
        ),
        'confirmedPreviewIndexEnd': host.previewIndexForSequence(
          samples.last.sourceSequence,
        ),
        'firstConfirmedSequence': samples.first.sourceSequence,
        'lastConfirmedSequence': samples.last.sourceSequence,
        'strokeConstraintMode': host.strokeConstraintMode(),
        'renderer': 'flutter_canvas',
        if (packetArrivalUs != null) 'packetArrivalUs': packetArrivalUs,
      });
    }

    final latestConfirmedPosition = _packetAdapter.lastConfirmedPosition(
      preparedPacket.bytes,
    );
    if (latestConfirmedPosition != null) {
      host.setStylusLastPosition(latestConfirmedPosition);
      host.recordInputArrival();
      if (!hasDown && !hasUp && !hasCancel) {
        host.armDrawAndHold(latestConfirmedPosition);
      }
    }
    if (_packetQueue.enqueue(preparedPacket.bytes)) host.scheduleDrain();
  }

  Future<void> drainQueue() => _packetQueue.drain(
    isActive: () => !host.disposed(),
    handlePacket: _handleSerialPacketSafely,
    scheduleDrain: host.scheduleDrain,
    onIdle: host.onQueueIdle,
  );

  Future<void> _handleSerialPacketSafely(Uint8List packet) async {
    try {
      await host.handleSerialPacket(packet);
    } catch (error, stack) {
      host.diagnostics.recordError('native_pointer_handler', error, stack);
      debugPrint('Project Ink native packet handling failed: $error\n$stack');
      await host.abortStrokeAfterPacketError();
    }
  }
}
