import 'package:flutter/foundation.dart';

enum CanvasFloatingPanel { tools, brushes, layers, comics }

@immutable
class CanvasFloatingPanelVisibility {
  const CanvasFloatingPanelVisibility({
    this.tools = false,
    this.brushes = false,
    this.layers = false,
    this.comics = false,
  });

  final bool tools;
  final bool brushes;
  final bool layers;
  final bool comics;

  bool isVisible(CanvasFloatingPanel panel) => switch (panel) {
    CanvasFloatingPanel.tools => tools,
    CanvasFloatingPanel.brushes => brushes,
    CanvasFloatingPanel.layers => layers,
    CanvasFloatingPanel.comics => comics,
  };

  CanvasFloatingPanelVisibility setVisible(
    CanvasFloatingPanel panel,
    bool visible,
  ) => switch (panel) {
    CanvasFloatingPanel.tools => copyWith(tools: visible),
    CanvasFloatingPanel.brushes => copyWith(brushes: visible),
    CanvasFloatingPanel.layers => copyWith(layers: visible),
    CanvasFloatingPanel.comics => copyWith(comics: visible),
  };

  CanvasFloatingPanelVisibility toggle(CanvasFloatingPanel panel) =>
      setVisible(panel, !isVisible(panel));

  CanvasFloatingPanelVisibility toggleExclusive(CanvasFloatingPanel? panel) {
    if (panel == null || isVisible(panel)) {
      return const CanvasFloatingPanelVisibility();
    }
    return only(panel);
  }

  CanvasFloatingPanelVisibility only(CanvasFloatingPanel? panel) =>
      CanvasFloatingPanelVisibility(
        tools: panel == CanvasFloatingPanel.tools,
        brushes: panel == CanvasFloatingPanel.brushes,
        layers: panel == CanvasFloatingPanel.layers,
        comics: panel == CanvasFloatingPanel.comics,
      );

  CanvasFloatingPanel? get lastVisiblePanel =>
      tools
          ? CanvasFloatingPanel.tools
          : brushes
          ? CanvasFloatingPanel.brushes
          : layers
          ? CanvasFloatingPanel.layers
          : comics
          ? CanvasFloatingPanel.comics
          : null;

  CanvasFloatingPanelVisibility copyWith({
    bool? tools,
    bool? brushes,
    bool? layers,
    bool? comics,
  }) => CanvasFloatingPanelVisibility(
    tools: tools ?? this.tools,
    brushes: brushes ?? this.brushes,
    layers: layers ?? this.layers,
    comics: comics ?? this.comics,
  );

  static CanvasFloatingPanel? fromName(String? name) => switch (name) {
    'tools' => CanvasFloatingPanel.tools,
    'brushes' => CanvasFloatingPanel.brushes,
    'layers' => CanvasFloatingPanel.layers,
    'comics' => CanvasFloatingPanel.comics,
    _ => null,
  };
}
