import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/app/editor_action.dart';
import 'package:project_ink/canvas/canvas_gesture_coordinator.dart';
import 'package:project_ink/canvas/gesture_defaults.dart';

void main() {
  test('records touch chords and routes their configured command', () {
    final actions = <EditorActionId>[];
    final diagnostics = <Map<String, Object?>>[];
    final coordinator = CanvasGestureCoordinator(
      CanvasGestureActionHost(
        defaults: () => const GestureDefaults(),
        isMounted: () => true,
        dispatchEditorAction: actions.add,
        showClipboardPalette: () {},
        sampleColor: (_) {},
        enableStraighten: () {},
        enableConstrain: () {},
        recordDiagnostic: (event, fields) {
          expect(event, 'input.touch_gesture_classified');
          diagnostics.add(fields);
        },
      ),
    );

    coordinator.record(
      const PointerDownEvent(pointer: 1, position: Offset(10, 10)),
      strokeActive: false,
      touchDrawingStrokeActive: () => false,
    );
    coordinator.record(
      const PointerDownEvent(pointer: 2, position: Offset(20, 10)),
      strokeActive: false,
      touchDrawingStrokeActive: () => false,
    );
    coordinator.record(
      const PointerUpEvent(pointer: 1, position: Offset(10, 10)),
      strokeActive: false,
      touchDrawingStrokeActive: () => false,
    );
    coordinator.record(
      const PointerUpEvent(pointer: 2, position: Offset(20, 10)),
      strokeActive: false,
      touchDrawingStrokeActive: () => false,
    );

    expect(actions, [EditorActionId.undo]);
    expect(diagnostics, [
      {'gesture': 'twoFingerTap', 'binding': 'twoFingerTap', 'action': 'undo'},
    ]);
    expect(coordinator.activePointerCount, 0);
    expect(coordinator.trackedPointerCount, 0);
    coordinator.dispose();
  });

  test('routes a completed three-finger tap to Redo', () {
    final actions = <EditorActionId>[];
    final coordinator = CanvasGestureCoordinator(
      CanvasGestureActionHost(
        defaults: () => const GestureDefaults(),
        isMounted: () => true,
        dispatchEditorAction: actions.add,
        showClipboardPalette: () {},
        sampleColor: (_) {},
        enableStraighten: () {},
        enableConstrain: () {},
      ),
    );

    for (var pointer = 1; pointer <= 3; pointer++) {
      coordinator.record(
        PointerDownEvent(
          pointer: pointer,
          position: Offset(pointer * 12, 20),
          kind: PointerDeviceKind.touch,
        ),
        strokeActive: false,
        touchDrawingStrokeActive: () => false,
      );
    }
    for (var pointer = 1; pointer <= 3; pointer++) {
      coordinator.record(
        PointerUpEvent(
          pointer: pointer,
          position: Offset(pointer * 12, 20),
          kind: PointerDeviceKind.touch,
        ),
        strokeActive: false,
        touchDrawingStrokeActive: () => false,
      );
    }

    expect(actions, [EditorActionId.redo]);
    coordinator.dispose();
  });

  test('routes position gestures and honors the mounted gate', () {
    var mounted = true;
    final sampledPositions = <Offset>[];
    var clipboardOpened = false;
    final actions = <EditorActionId>[];
    final coordinator = CanvasGestureCoordinator(
      CanvasGestureActionHost(
        defaults: () => const GestureDefaults(),
        isMounted: () => mounted,
        dispatchEditorAction: actions.add,
        showClipboardPalette: () => clipboardOpened = true,
        sampleColor: sampledPositions.add,
        enableStraighten: () => fail('Unmounted action should be ignored'),
        enableConstrain: () {},
      ),
    );

    coordinator.dispatchMapped(
      InkGesture.eyedropper,
      position: const Offset(12, 24),
    );
    coordinator.dispatchMapped(InkGesture.clipboardPalette);
    expect(sampledPositions, [const Offset(12, 24)]);
    expect(clipboardOpened, isTrue);

    mounted = false;
    coordinator.dispatchMapped(InkGesture.straighten);
    coordinator.dispatchMapped(InkGesture.eyedropper, position: Offset.zero);
    expect(sampledPositions, [const Offset(12, 24)]);
    coordinator.dispose();
  });
}
