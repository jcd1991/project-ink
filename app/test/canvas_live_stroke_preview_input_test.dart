import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/bridge/engine_api.dart';
import 'package:project_ink/canvas/canvas_live_stroke_preview_input.dart';
import 'package:project_ink/canvas/live_preview_controller.dart';

void main() {
  test('stroke start signals the surface before beginning the preview', () {
    final calls = <String>[];
    final surface = _PreviewSurface(calls);
    final input = CanvasLiveStrokePreviewInput(
      CanvasLiveStrokePreviewInputHost(
        livePreviewSurface: () => surface,
        strokeActive: () => false,
        beginPreview: (_, _, _) {
          calls.add('begin');
          return 0;
        },
        appendPreview: (_, _, _, _) {
          calls.add('append');
          return 1;
        },
        recordDiagnostic: (event, fields) {
          expect(event, 'gpu.preview_input_state');
          expect(fields['controllerAttached'], isTrue);
          calls.add('diagnostic');
        },
      ),
    );

    final index = input.update(
      const Offset(4, 8),
      isDown: true,
      isUp: false,
      pressure: 0.5,
      sourceSequence: 12,
    );

    expect(index, 0);
    expect(calls, <String>['diagnostic', 'pending:start', 'begin']);
  });

  test('active stroke samples signal pending before appending', () {
    final calls = <String>[];
    final input = CanvasLiveStrokePreviewInput(
      CanvasLiveStrokePreviewInputHost(
        livePreviewSurface: () => _PreviewSurface(calls),
        strokeActive: () => true,
        beginPreview: (_, _, _) => 0,
        appendPreview: (_, _, _, isUp) {
          calls.add(isUp ? 'append:up' : 'append');
          return 5;
        },
        recordDiagnostic: (_, _) => calls.add('diagnostic'),
      ),
    );

    final index = input.update(
      const Offset(5, 8),
      isDown: false,
      isUp: true,
      pressure: 0.8,
      sourceSequence: 13,
    );

    expect(index, 5);
    expect(calls, <String>['pending:sample', 'append:up']);
  });

  test('native start preparation can defer the pending marker', () {
    final calls = <String>[];
    final input = CanvasLiveStrokePreviewInput(
      CanvasLiveStrokePreviewInputHost(
        livePreviewSurface: () => _PreviewSurface(calls),
        strokeActive: () => false,
        beginPreview: (_, _, _) => 0,
        appendPreview: (_, _, _, _) => 0,
        recordDiagnostic: (_, _) => calls.add('diagnostic'),
      ),
    );

    input.prepareStrokeStart(markInputPending: false);

    expect(calls, <String>['diagnostic']);
  });
}

class _PreviewSurface implements LivePreviewController {
  _PreviewSurface(this.calls);

  final List<String> calls;

  @override
  ValueListenable<int?> get textureId => const _Value<int?>(null);

  @override
  ValueListenable<bool> get gpuFrameReady => const _Value<bool>(true);

  @override
  void markInputPending({bool strokeStart = false}) {
    calls.add(strokeStart ? 'pending:start' : 'pending:sample');
  }

  @override
  void synchronizeViewport({
    required Size viewportSize,
    required double devicePixelRatio,
    required Offset pan,
    required double scale,
    required double rotation,
    required bool mirrored,
    required int documentWidth,
    required int documentHeight,
  }) {}

  @override
  void pump() {}

  @override
  Future<void> acknowledge(StrokeAcknowledgement acknowledgement) async {}

  @override
  Future<void> cancelAllStrokes() async {}

  @override
  Future<void> dispose() async {}
}

class _Value<T> implements ValueListenable<T> {
  const _Value(this.value);

  @override
  final T value;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}
