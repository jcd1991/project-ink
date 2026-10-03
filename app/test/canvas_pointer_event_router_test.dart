import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/canvas/canvas_diagnostic_recorder.dart';
import 'package:project_ink/canvas/canvas_pointer_event_router.dart';
import 'package:project_ink/tools/illustration_tools.dart';

void main() {
  test('router owns pointer tracking and can retire stale contacts', () {
    final router = CanvasPointerEventRouter(_host());

    router.handle(
      const PointerDownEvent(
        pointer: 1,
        kind: PointerDeviceKind.mouse,
        position: Offset(5, 8),
      ),
    );
    router.handle(
      const PointerMoveEvent(
        pointer: 2,
        kind: PointerDeviceKind.mouse,
        position: Offset(9, 10),
      ),
    );
    expect(router.trackedPointerCount, 2);

    router.forgetPointers(<int>[1]);
    expect(router.trackedPointerCount, 1);

    router.clearPointers();
    expect(router.trackedPointerCount, 0);
  });
}

CanvasPointerEventRouterHost _host() => CanvasPointerEventRouterHost(
  documentReplacementActive: () => false,
  nativePencilContactActive: () => false,
  recordTouchGesture: (_) {},
  touchGestureCounts: () => (active: 0, tracked: 0),
  activeTool: () => IllustrationTool.brush,
  colorSamplerArmed: () => false,
  disarmColorSampler: () {},
  sampleCanvasColor: (_) async {},
  handleToolEvent: (_) async {},
  nativePointerEnabled: () => true,
  strokeActive: () => false,
  activeStrokeIsTouch: () => false,
  singleFingerNavigation: () => false,
  touchDrawingStrokeActive: () => false,
  setTouchDrawingStrokeActive: (_) {},
  cancelTouchDrawingStroke: ({required reason}) {},
  beginStrokeAutosaveHold: () {},
  nextPointerSequence: () => 0,
  prepareDrawingPosition: (event) => event.localPosition,
  updatePreview:
      (
        position, {
        required isDown,
        required isUp,
        required pressure,
        required sourceSequence,
      }) => 0,
  pointerPressure: (_) => 1,
  schedulePreviewFrameDiagnostic: () {},
  enqueueStrokeWork: (_) {},
  handleDrawingEvent: (_, _, _) async {},
  previewPerformanceTimingEnabled: () => false,
  nowMicros: () => 0,
  markPreviewUpdated: ({required startedMicros}) {},
  diagnostics: CanvasDiagnosticRecorder.instance,
);
