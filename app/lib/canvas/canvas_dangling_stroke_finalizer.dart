/// Screen effects needed to finish an input stroke before a brush edit.
class CanvasDanglingStrokeFinalizerHost {
  const CanvasDanglingStrokeFinalizerHost({
    required this.drainAcceptedInput,
    required this.hasActiveStroke,
    required this.endRustStroke,
    required this.resetLocalStroke,
    required this.markDirty,
    required this.refreshLayerThumbnails,
    required this.refreshTiles,
  });

  final Future<void> Function() drainAcceptedInput;
  final bool Function() hasActiveStroke;
  final Future<void> Function() endRustStroke;
  final void Function() resetLocalStroke;
  final void Function() markDirty;
  final void Function() refreshLayerThumbnails;
  final void Function() refreshTiles;
}

/// Drains accepted packets and finalizes a dangling Rust stroke before edits.
///
/// Rust remains authoritative: if Flutter's local active flag is stale, the
/// Rust end operation may reject because the stroke already ended. In that
/// case the local gesture is still reset and the edit caller proceeds to its
/// normal Rust draft operation, which determines whether editing is valid.
class CanvasDanglingStrokeFinalizer {
  CanvasDanglingStrokeFinalizer(this.host);

  final CanvasDanglingStrokeFinalizerHost host;

  Future<void> finishBeforeEdit() async {
    await host.drainAcceptedInput();
    if (!host.hasActiveStroke()) return;

    try {
      await host.endRustStroke();
    } catch (_) {
      // See the class contract: this handles a stale Flutter active flag.
    }

    host.resetLocalStroke();
    host.markDirty();
    host.refreshLayerThumbnails();
    host.refreshTiles();
  }
}
