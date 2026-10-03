import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/canvas/canvas_diagnostic_recorder.dart';
import 'package:project_ink/canvas/native_pencil_input_coordinator.dart';
import 'package:project_ink/canvas/pointer_packet.dart';
import 'package:project_ink/tools/illustration_tools.dart';

void main() {
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
