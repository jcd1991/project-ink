import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_ink/bridge/engine_api.dart';
import 'package:project_ink/canvas/canvas_brush_actions.dart';
import 'package:project_ink/canvas/canvas_diagnostic_recorder.dart';
import 'package:project_ink/tools/brush_library.dart';

void main() {
  test(
    'brush selection leaves presets alone and active color is shared',
    () async {
      final engine = InMemoryEngineApi();
      final brushes = await engine.builtinBrushes();
      final selectedBrush = brushes.firstWhere((brush) => brush.id != 1);
      final library = BrushLibraryModel(const []);
      const activeColor = Color(0xff12ab34);
      var activeBrushId = 1;
      var markDirtyCount = 0;
      final messages = <String>[];
      final actions = CanvasBrushActions(
        CanvasBrushActionHost(
          engine: () => engine,
          library: () => library,
          context: () => throw StateError('No context required'),
          mounted: () => true,
          setState: (callback) => callback(),
          activeBrushId: () => activeBrushId,
          setActiveBrushId: (value) => activeBrushId = value,
          finishDanglingStrokeBeforeBrushEdit: () async {},
          endStaleStroke: () async {},
          loadPhase2Projections: () async {},
          markDirty: () => markDirtyCount++,
          diagnostics: CanvasDiagnosticRecorder.instance,
          showMessage: messages.add,
        ),
      );

      await actions.activateBrush(
        BrushPresetView(
          id: selectedBrush.id,
          name: selectedBrush.name,
          family: BrushFamily.paint,
        ),
      );
      expect(await actions.setActivePaintColor(activeColor), isTrue);

      expect(activeBrushId, selectedBrush.id);
      final unchanged = (await engine.builtinBrushes()).firstWhere(
        (brush) => brush.id == selectedBrush.id,
      );
      expect(unchanged.colorRgba, selectedBrush.colorRgba);
      expect(engine.activeBrushColorRgba, 0x12ab34ff);
      expect(markDirtyCount, 0);
      expect(messages, isEmpty);
    },
  );
}
