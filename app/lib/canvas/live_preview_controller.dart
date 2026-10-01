import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../bridge/engine_api.dart';

/// Common lifecycle for optional native live-stroke textures.
///
/// Implementations present only ephemeral Rust-generated dab packets. The
/// document's CPU tiles remain the saved/exported/undoable source of truth;
/// unsupported or failed native renderers leave the Flutter preview active.
abstract interface class LivePreviewController {
  ValueListenable<int?> get textureId;
  ValueListenable<bool> get gpuFrameReady;

  void markInputPending({bool strokeStart = false});

  void synchronizeViewport({
    required Size viewportSize,
    required double devicePixelRatio,
    required Offset pan,
    required double scale,
    required double rotation,
    required bool mirrored,
    required int documentWidth,
    required int documentHeight,
  });

  void pump();
  Future<void> acknowledge(StrokeAcknowledgement acknowledgement);
  Future<void> cancelAllStrokes();
  Future<void> dispose();
}
