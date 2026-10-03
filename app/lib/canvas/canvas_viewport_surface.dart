import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../layers/layer_panel_model.dart';
import '../tools/illustration_tools.dart';
import 'canvas_painters.dart';
import 'live_preview_controller.dart';
import 'live_stroke_coordinator.dart';
import 'mac_live_surface_controller.dart';
import 'tile_cache.dart';
import 'viewport_transform.dart';

@immutable
class CanvasViewportPaintState {
  const CanvasViewportPaintState({
    required this.transform,
    required this.mirrored,
    required this.revision,
    required this.documentWidth,
    required this.documentHeight,
    required this.layers,
    required this.tiles,
    required this.selection,
    required this.selectionTool,
    required this.previewPoints,
    required this.rulerStart,
    required this.rulerEnd,
  });

  final CanvasViewport transform;
  final bool mirrored;
  final int revision;
  final int documentWidth;
  final int documentHeight;
  final List<LayerView> layers;
  final List<MapEntry<TileCacheKey, ui.Image>> tiles;
  final Rect? selection;
  final IllustrationTool? selectionTool;
  final List<Offset> previewPoints;
  final Offset? rulerStart;
  final Offset? rulerEnd;
}

/// Owns the drawing viewport's render stack and gesture surface.
/// Document state, coordinate mapping, and transform updates remain supplied
/// by the parent canvas composition.
class CanvasViewportSurface extends StatelessWidget {
  const CanvasViewportSurface({
    required this.canvasKey,
    required this.paintState,
    required this.strokePreview,
    required this.hoverPosition,
    required this.livePreviewSurface,
    required this.isIpad,
    required this.onPointerEvent,
    required this.onScaleStart,
    required this.onScaleUpdate,
    required this.onScaleEnd,
    required this.onSlowPreviewPaint,
    this.comicPreview,
    super.key,
  });

  final GlobalKey canvasKey;
  final CanvasViewportPaintState paintState;
  final ValueListenable<LiveStrokePreview?> strokePreview;
  final ValueListenable<Offset?> hoverPosition;
  final LivePreviewController? livePreviewSurface;
  final bool isIpad;
  final ValueChanged<PointerEvent> onPointerEvent;
  final ValueChanged<ScaleStartDetails> onScaleStart;
  final ValueChanged<ScaleUpdateDetails> onScaleUpdate;
  final ValueChanged<ScaleEndDetails> onScaleEnd;
  final void Function(
    LiveStrokePreview preview,
    int elapsedMicros,
    int directSegments,
    int pictures,
  )
  onSlowPreviewPaint;
  final Widget? comicPreview;

  @override
  Widget build(BuildContext context) {
    final transform = paintState.transform;
    return Semantics(
      container: true,
      label: 'Drawing canvas',
      hint: 'Draw with your finger or stylus. Use two fingers to pan and zoom.',
      child: Listener(
        key: canvasKey,
        onPointerDown: onPointerEvent,
        onPointerMove: onPointerEvent,
        onPointerUp: onPointerEvent,
        onPointerCancel: onPointerEvent,
        // Clip transformed art to the viewport so it cannot cover editor UI.
        child: ClipRect(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // Trackpad pinch still arrives through scale; ordinary two-finger
            // scrolling stays pan-only instead of changing zoom.
            trackpadScrollCausesScale: false,
            onScaleStart: onScaleStart,
            onScaleUpdate: onScaleUpdate,
            onScaleEnd: onScaleEnd,
            child: Stack(
              fit: StackFit.expand,
              children: [
                CustomPaint(
                  painter: CanvasTilePainter(
                    pan: transform.pan,
                    scale: transform.scale,
                    rotation: transform.rotation,
                    mirrored: paintState.mirrored,
                    revision: paintState.revision,
                    documentWidth: paintState.documentWidth,
                    documentHeight: paintState.documentHeight,
                    layers: paintState.layers,
                    tiles: paintState.tiles,
                  ),
                  foregroundPainter: CanvasOverlayPainter(
                    pan: transform.pan,
                    scale: transform.scale,
                    rotation: transform.rotation,
                    mirrored: paintState.mirrored,
                    documentWidth: paintState.documentWidth,
                    documentHeight: paintState.documentHeight,
                    selection: paintState.selection,
                    selectionTool: paintState.selectionTool,
                    previewPoints: paintState.previewPoints,
                    rulerStart: paintState.rulerStart,
                    rulerEnd: paintState.rulerEnd,
                  ),
                ),
                ValueListenableBuilder<Offset?>(
                  valueListenable: hoverPosition,
                  builder: (context, position, child) {
                    if (position == null) return const SizedBox.shrink();
                    return IgnorePointer(
                      child: CustomPaint(
                        painter: PencilHoverCrosshairPainter(
                          pan: transform.pan,
                          scale: transform.scale,
                          rotation: transform.rotation,
                          mirrored: paintState.mirrored,
                          documentWidth: paintState.documentWidth,
                          documentHeight: paintState.documentHeight,
                          position: position,
                        ),
                      ),
                    );
                  },
                ),
                ValueListenableBuilder<LiveStrokePreview?>(
                  valueListenable: strokePreview,
                  builder: (context, preview, child) {
                    // On iPad the compiled brush output is authoritative for
                    // live feedback. CPU tile updates remain its fallback.
                    final nativeDabRendererExpected =
                        isIpad &&
                        livePreviewSurface is MacLiveSurfaceController;
                    final showCpuPreview =
                        !nativeDabRendererExpected &&
                        livePreviewSurface?.gpuFrameReady.value != true;
                    if (!showCpuPreview || preview == null) {
                      return const SizedBox.shrink();
                    }
                    return RepaintBoundary(
                      key: const ValueKey('live-stroke-preview-boundary'),
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: LiveStrokePreviewPainter(
                            pan: transform.pan,
                            scale: transform.scale,
                            rotation: transform.rotation,
                            mirrored: paintState.mirrored,
                            documentWidth: paintState.documentWidth,
                            documentHeight: paintState.documentHeight,
                            preview: preview,
                            onSlowPaint:
                                (elapsedMicros, direct, pictures) =>
                                    onSlowPreviewPaint(
                                      preview,
                                      elapsedMicros,
                                      direct,
                                      pictures,
                                    ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
                if (livePreviewSurface case final liveSurface?)
                  ValueListenableBuilder<int?>(
                    valueListenable: liveSurface.textureId,
                    builder: (context, textureId, child) {
                      if (textureId == null) return const SizedBox.shrink();
                      return ValueListenableBuilder<bool>(
                        valueListenable: liveSurface.gpuFrameReady,
                        builder: (context, frameReady, child) {
                          if (!frameReady) return const SizedBox.shrink();
                          return IgnorePointer(
                            child: Texture(
                              textureId: textureId,
                              filterQuality: FilterQuality.none,
                            ),
                          );
                        },
                      );
                    },
                  ),
                if (comicPreview case final preview?)
                  IgnorePointer(child: preview),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
