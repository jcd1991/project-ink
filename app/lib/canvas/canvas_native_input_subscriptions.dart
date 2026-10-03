import 'dart:async';
import 'dart:typed_data';

/// Owns the subscriptions that feed native input into a canvas session.
///
/// Platform channel selection remains at the screen boundary; this owner
/// manages readiness, forwarding, error reporting, and cancellation.
class CanvasNativeInputSubscriptions {
  CanvasNativeInputSubscriptions({
    required this.onPointerPacket,
    required this.onPencilCommand,
    required this.onCanvasDiagnostic,
    required this.onChannelError,
  });

  final void Function(Uint8List packet) onPointerPacket;
  final void Function(String command) onPencilCommand;
  final void Function(Map<String, Object?> event) onCanvasDiagnostic;
  final void Function(String channel, Object error, StackTrace stack)
  onChannelError;

  StreamSubscription<Uint8List>? _pointerPackets;
  StreamSubscription<void>? _pointerReadiness;
  StreamSubscription<String>? _pencilCommands;
  StreamSubscription<Map<String, Object?>>? _canvasDiagnostics;
  bool _nativePointerEnabled = false;
  bool _started = false;
  bool _disposed = false;

  bool get nativePointerEnabled => _nativePointerEnabled;

  void start({
    Stream<Uint8List>? pointerPackets,
    Stream<void>? pointerReadiness,
    Stream<String>? pencilCommands,
    Stream<Map<String, Object?>>? canvasDiagnostics,
  }) {
    if (_started || _disposed) {
      throw StateError('Native input subscriptions can only start once.');
    }
    if ((pointerPackets == null) != (pointerReadiness == null)) {
      throw ArgumentError(
        'Pointer packets and readiness streams must be supplied together.',
      );
    }
    _started = true;
    _canvasDiagnostics = canvasDiagnostics?.listen(
      onCanvasDiagnostic,
      onError:
          (Object error, StackTrace stack) =>
              onChannelError('native_diagnostic_channel', error, stack),
    );
    _pointerPackets = pointerPackets?.listen(
      onPointerPacket,
      onError: (Object error, StackTrace stack) {
        _nativePointerEnabled = false;
        onChannelError('native_pointer_stream', error, stack);
      },
    );
    _pointerReadiness = pointerReadiness?.listen(
      (_) => _nativePointerEnabled = true,
      onError: (Object error, StackTrace stack) {
        _nativePointerEnabled = false;
        onChannelError('native_pointer_status', error, stack);
      },
    );
    _pencilCommands = pencilCommands?.listen(
      onPencilCommand,
      onError:
          (Object error, StackTrace stack) =>
              onChannelError('native_pencil_commands', error, stack),
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _nativePointerEnabled = false;
    final cancellations = <Future<void>>[
      if (_pointerPackets case final subscription?) subscription.cancel(),
      if (_pointerReadiness case final subscription?) subscription.cancel(),
      if (_pencilCommands case final subscription?) subscription.cancel(),
      if (_canvasDiagnostics case final subscription?) subscription.cancel(),
    ];
    await Future.wait(cancellations);
  }
}
