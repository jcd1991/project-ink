import 'document_replacement_barrier.dart';

/// Screen-owned operations needed to retire transient input before replacing
/// the document attached to a canvas route.
class CanvasInputReplacementHost {
  const CanvasInputReplacementHost({
    required this.isMounted,
    required this.prepareInput,
    required this.barrier,
  });

  final bool Function() isMounted;
  final void Function() prepareInput;
  final DocumentReplacementBarrier barrier;
}

/// Orders transient input retirement before the document replacement barrier.
///
/// The coordinator owns this cross-owner transition while the screen supplies
/// the concrete gesture, pointer, navigation, and native-contact effects.
class CanvasInputReplacementCoordinator {
  const CanvasInputReplacementCoordinator(this.host);

  final CanvasInputReplacementHost host;

  Future<void> run(Future<void> Function() replaceDocument) async {
    if (!host.isMounted()) return;
    host.prepareInput();
    await host.barrier.run(replaceDocument);
  }
}
