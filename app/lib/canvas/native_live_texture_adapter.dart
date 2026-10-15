import 'dart:typed_data';

/// Platform texture control plane used by the optional native live-stroke
/// preview. Implementations must keep pixel/document data out of method
/// arguments; only bounded metadata and versioned dab packets cross the
/// channel. Rust CPU tiles remain authoritative.
abstract interface class NativeLiveTextureAdapter {
  Future<int> create({required int width, required int height});

  Future<void> setViewport(int textureId, List<double> matrix, int generation);

  Future<void> renderDabs(int textureId, Uint8List packet);

  /// Applies a bounded group of packets before publishing one native frame.
  Future<void> renderDabBatches(int textureId, List<Uint8List> packets);

  Future<void> acknowledge(int textureId, BigInt strokeId, int sequence);

  Future<void> cancelAll(int textureId);

  Future<void> dispose(int textureId);
}
