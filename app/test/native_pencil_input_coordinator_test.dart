import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/canvas/canvas_diagnostic_recorder.dart';
import 'package:project_ink/canvas/native_pencil_input_coordinator.dart';
import 'package:project_ink/canvas/pointer_packet.dart';
import 'package:project_ink/tools/illustration_tools.dart';

void main() {
  test('native stylus diagnostics use cross-platform labels', () async {
    final documents = await Directory.systemTemp.createTemp(
      'project-ink-native-diagnostics-',
    );
    final diagnostics = CanvasDiagnosticRecorder.forTesting(
      documentsDirectory: documents,
    );
    try {
      await diagnostics.startCapture();
      var nextSequence = 0;
      final coordinator = NativePencilInputCoordinator(
        NativePencilInputHost(
          documentReplacementInProgress: () => false,
          disposed: () => false,
          activeTool: () => IllustrationTool.brush,
          diagnostics: diagnostics,
          discardConcurrentTouchGesture: () {},
          beginStrokeAutosaveHold: () {},
          markPacketReceived: (_) {},
          transformPosition: (position, _) => position,
          nextSequence: () => nextSequence++,
          appendPreviewBatch: (_, {required beginsStroke}) {},
          schedulePreviewFrameDiagnostic: () {},
          previewIndexForSequence: (_) => null,
          strokeConstraintMode: () => 'none',
          setStylusLastPosition: (_) {},
          recordInputArrival: (_) {},
          armDrawAndHold: (_) {},
          handleSerialPacket: (_) async {},
          abortStrokeAfterPacketError: () async {},
          scheduleDrain: () {},
          onQueueIdle: () {},
        ),
      );
      coordinator.handlePacket(_packet(InkPointerPhase.down, 1));
      await coordinator.drainQueue();
      final logPath = await diagnostics.stopCapture();
      final rows = File(logPath!).readAsLinesSync().map(
        (line) => jsonDecode(line) as Map<String, dynamic>,
      );

      expect(
        rows.singleWhere(
          (row) => row['type'] == 'input.native_packet',
        )['stage'],
        'native_pointer_event_channel',
      );
      expect(
        rows.singleWhere(
          (row) => row['type'] == 'canvas.live_input_accepted',
        )['device'],
        'stylus',
      );
    } finally {
      if (diagnostics.isRecording) await diagnostics.stopCapture();
      await documents.delete(recursive: true);
    }
  });

  test(
    'hover packets update the pointer without entering the stroke queue',
    () async {
      Offset? hover;
      var serialPacketCount = 0;
      final coordinator = NativePencilInputCoordinator(
        NativePencilInputHost(
          documentReplacementInProgress: () => false,
          disposed: () => false,
          activeTool: () => IllustrationTool.brush,
          diagnostics: CanvasDiagnosticRecorder.instance,
          discardConcurrentTouchGesture: () {},
          beginStrokeAutosaveHold: () {},
          markPacketReceived: (_) {},
          transformPosition: (position, _) => position,
          transformHoverPosition: (position) => position + const Offset(2, 3),
          updateHoverPosition: (position) => hover = position,
          nextSequence: () => 0,
          appendPreviewBatch: (_, {required beginsStroke}) {},
          schedulePreviewFrameDiagnostic: () {},
          previewIndexForSequence: (_) => null,
          strokeConstraintMode: () => 'none',
          setStylusLastPosition: (_) {},
          recordInputArrival: (_) {},
          armDrawAndHold: (_) {},
          handleSerialPacket: (_) async => serialPacketCount++,
          abortStrokeAfterPacketError: () async {},
          scheduleDrain: () {},
          onQueueIdle: () {},
        ),
      );

      coordinator.handlePacket(
        encodePointerPacket(
          pointerId: 1,
          device: InkPointerDevice.stylus,
          phase: InkPointerPhase.move,
          x: 10,
          y: 20,
          pressure: 0,
          timestampNs: 1,
          sequence: 1,
          flags: inkPointerActual | inkPointerHover,
        ),
      );

      expect(hover, const Offset(12, 23));
      expect(coordinator.pendingPacketCount, 0);
      await coordinator.drainQueue();
      expect(serialPacketCount, 0);
    },
  );

  test(
    'a failed native packet is recovered and does not stop the drain',
    () async {
      var packetCount = 0;
      var recoveryCount = 0;
      var idleCount = 0;
      var nextSequence = 0;
      final coordinator = NativePencilInputCoordinator(
        NativePencilInputHost(
          documentReplacementInProgress: () => false,
          disposed: () => false,
          activeTool: () => IllustrationTool.brush,
          diagnostics: CanvasDiagnosticRecorder.instance,
          discardConcurrentTouchGesture: () {},
          beginStrokeAutosaveHold: () {},
          markPacketReceived: (_) {},
          transformPosition: (position, _) => position,
          nextSequence: () => nextSequence++,
          appendPreviewBatch: (_, {required beginsStroke}) {},
          schedulePreviewFrameDiagnostic: () {},
          previewIndexForSequence: (_) => null,
          strokeConstraintMode: () => 'none',
          setStylusLastPosition: (_) {},
          recordInputArrival: (_) {},
          armDrawAndHold: (_) {},
          handleSerialPacket: (_) async {
            packetCount++;
            throw StateError('simulated packet failure');
          },
          abortStrokeAfterPacketError: () async {
            recoveryCount++;
          },
          scheduleDrain: () {},
          onQueueIdle: () => idleCount++,
        ),
      );

      coordinator.handlePacket(_packet(InkPointerPhase.down, 1));
      coordinator.handlePacket(_packet(InkPointerPhase.move, 2));
      await coordinator.drainQueue();

      expect(packetCount, 2);
      expect(recoveryCount, 2);
      expect(coordinator.pendingPacketCount, 0);
      expect(idleCount, 1);
    },
  );
}

Uint8List _packet(InkPointerPhase phase, int sequence) => encodePointerPacket(
  pointerId: 9,
  device: InkPointerDevice.stylus,
  phase: phase,
  x: sequence.toDouble(),
  y: 20,
  pressure: 1,
  timestampNs: sequence,
  sequence: sequence,
);
