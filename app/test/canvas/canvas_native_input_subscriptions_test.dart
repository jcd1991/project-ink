import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/canvas/canvas_native_input_subscriptions.dart';

void main() {
  test(
    'forwards streams, gates native readiness, and cancels on dispose',
    () async {
      final packets = StreamController<Uint8List>();
      final readiness = StreamController<void>();
      final commands = StreamController<String>();
      final diagnostics = StreamController<Map<String, Object?>>();
      final receivedPackets = <Uint8List>[];
      final receivedCommands = <String>[];
      final receivedDiagnostics = <Map<String, Object?>>[];
      final errors = <String>[];
      final subscriptions = CanvasNativeInputSubscriptions(
        onPointerPacket: receivedPackets.add,
        onPencilCommand: receivedCommands.add,
        onCanvasDiagnostic: receivedDiagnostics.add,
        onChannelError: (channel, _, _) => errors.add(channel),
      );
      subscriptions.start(
        pointerPackets: packets.stream,
        pointerReadiness: readiness.stream,
        pencilCommands: commands.stream,
        canvasDiagnostics: diagnostics.stream,
      );

      expect(subscriptions.nativePointerEnabled, isFalse);
      packets.add(Uint8List.fromList([1, 2]));
      commands.add('toggleEraser');
      diagnostics.add({'kind': 'pressure'});
      readiness.add(null);
      await Future<void>.delayed(Duration.zero);

      expect(subscriptions.nativePointerEnabled, isTrue);
      expect(receivedPackets.single, [1, 2]);
      expect(receivedCommands, ['toggleEraser']);
      expect(receivedDiagnostics, [
        <String, Object?>{'kind': 'pressure'},
      ]);
      expect(errors, isEmpty);

      await subscriptions.dispose();
      expect(subscriptions.nativePointerEnabled, isFalse);
      packets.add(Uint8List.fromList([3]));
      await Future<void>.delayed(Duration.zero);
      expect(receivedPackets, hasLength(1));

      await Future.wait([
        packets.close(),
        readiness.close(),
        commands.close(),
        diagnostics.close(),
      ]);
    },
  );

  test('a native pointer stream error disables the native path', () async {
    final packets = StreamController<Uint8List>();
    final readiness = StreamController<void>();
    final errors = <String>[];
    final subscriptions = CanvasNativeInputSubscriptions(
      onPointerPacket: (_) {},
      onPencilCommand: (_) {},
      onCanvasDiagnostic: (_) {},
      onChannelError: (channel, _, _) => errors.add(channel),
    );
    subscriptions.start(
      pointerPackets: packets.stream,
      pointerReadiness: readiness.stream,
    );
    readiness.add(null);
    await Future<void>.delayed(Duration.zero);
    expect(subscriptions.nativePointerEnabled, isTrue);

    packets.addError(StateError('channel closed'));
    await Future<void>.delayed(Duration.zero);

    expect(subscriptions.nativePointerEnabled, isFalse);
    expect(errors, ['native_pointer_stream']);
    await subscriptions.dispose();
    await Future.wait([packets.close(), readiness.close()]);
  });

  test('requires pointer packets and readiness as a pair', () {
    final subscriptions = CanvasNativeInputSubscriptions(
      onPointerPacket: (_) {},
      onPencilCommand: (_) {},
      onCanvasDiagnostic: (_) {},
      onChannelError: (_, _, _) {},
    );

    expect(
      () => subscriptions.start(pointerPackets: const Stream.empty()),
      throwsArgumentError,
    );
  });
}
