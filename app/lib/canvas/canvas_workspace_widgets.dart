import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../bridge/engine_api.dart';
import '../bridge/generated/api.dart' as rust;
import '../comics/comic_workspace_controller.dart';
import 'canvas_vector_actions.dart';

class VectorInspector extends StatelessWidget {
  const VectorInspector({
    super.key,
    required this.strokes,
    required this.selectedStrokeIds,
    required this.candidate,
    required this.onToggleSelection,
    required this.onSimplify,
    required this.onConnect,
    required this.onEditPoint,
    required this.onRecognize,
    required this.onFitCurve,
    required this.onApplyCandidate,
    required this.onConstrainCandidate,
    required this.onCancelCandidate,
    required this.hasMore,
    required this.onLoadMore,
    required this.onRestoreOriginalInk,
    required this.onEditPath,
    required this.onRepeat,
  });

  final List<VectorObjectSummaryView> strokes;
  final Set<int> selectedStrokeIds;
  final VectorCandidateView? candidate;
  final ValueChanged<int> onToggleSelection;
  final VoidCallback onSimplify;
  final VoidCallback onConnect;
  final VoidCallback onEditPoint;
  final VoidCallback onRecognize;
  final ValueChanged<double> onFitCurve;
  final VoidCallback onApplyCandidate;
  final ValueChanged<int> onConstrainCandidate;
  final VoidCallback onCancelCandidate;
  final bool hasMore;
  final VoidCallback onLoadMore;
  final VoidCallback onRestoreOriginalInk;
  final ValueChanged<CanvasVectorEditRequest> onEditPath;
  final ValueChanged<CanvasVectorRepeatOptions> onRepeat;

  bool get _oneSelectedLegacy =>
      selectedStrokeIds.length == 1 &&
      strokes
          .where((stroke) => selectedStrokeIds.contains(stroke.id))
          .any((stroke) => stroke.kind == 'LegacyInk');
  bool get _oneSelectedPath =>
      selectedStrokeIds.length == 1 &&
      strokes
          .where((stroke) => selectedStrokeIds.contains(stroke.id))
          .any((stroke) => stroke.kind == 'BezierPath');

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.all(8),
    child: Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Vector ink', style: Theme.of(context).textTheme.labelLarge),
          Text('${strokes.length} vector object(s) loaded'),
          if (strokes.isNotEmpty)
            SizedBox(
              height: strokes.length > 4 ? 112 : strokes.length * 36,
              child: ListView.builder(
                itemCount: strokes.length,
                itemBuilder: (context, index) {
                  final stroke = strokes[index];
                  return CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    value: selectedStrokeIds.contains(stroke.id),
                    title: Text(
                      '${stroke.kind == 'LegacyInk' ? 'Ink' : 'Path'} ${stroke.id}',
                    ),
                    subtitle: Text(
                      '${stroke.pointCount} ${stroke.kind == 'LegacyInk' ? 'samples' : 'anchors'}',
                    ),
                    onChanged: (_) => onToggleSelection(stroke.id),
                  );
                },
              ),
            ),
          if (hasMore)
            TextButton(
              onPressed: onLoadMore,
              child: const Text('Load more vector objects'),
            ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 4,
            children: [
              OutlinedButton(
                onPressed: !_oneSelectedLegacy ? null : onSimplify,
                child: const Text('Simplify selected'),
              ),
              OutlinedButton(
                onPressed: selectedStrokeIds.length != 2 ? null : onConnect,
                child: const Text('Connect selected'),
              ),
              OutlinedButton(
                onPressed: !_oneSelectedLegacy ? null : onEditPoint,
                child: const Text('Edit selected point'),
              ),
              OutlinedButton(
                onPressed: !_oneSelectedLegacy ? null : onRecognize,
                child: const Text('Recognize shape'),
              ),
              OutlinedButton(
                onPressed:
                    !_oneSelectedLegacy
                        ? null
                        : () async {
                          final tolerance = await showDialog<double>(
                            context: context,
                            builder:
                                (context) => const _VectorFitToleranceDialog(),
                          );
                          if (tolerance != null) onFitCurve(tolerance);
                        },
                child: const Text('Fit curve'),
              ),
              OutlinedButton(
                onPressed:
                    !_oneSelectedPath
                        ? null
                        : () async {
                          final request =
                              await showDialog<CanvasVectorEditRequest>(
                                context: context,
                                builder:
                                    (context) => const _VectorPathEditDialog(),
                              );
                          if (request != null) onEditPath(request);
                        },
                child: const Text('Edit Bézier path'),
              ),
              OutlinedButton(
                onPressed:
                    !_oneSelectedPath
                        ? null
                        : () async {
                          final options =
                              await showDialog<CanvasVectorRepeatOptions>(
                                context: context,
                                builder:
                                    (context) => const _VectorRepeatDialog(),
                              );
                          if (options != null) onRepeat(options);
                        },
                child: const Text('Repeat path'),
              ),
              OutlinedButton(
                onPressed:
                    selectedStrokeIds.length != 1 ||
                            strokes
                                .where(
                                  (stroke) =>
                                      selectedStrokeIds.contains(stroke.id),
                                )
                                .every((stroke) => !stroke.hasSourceArchive)
                        ? null
                        : onRestoreOriginalInk,
                child: const Text('Restore original ink'),
              ),
            ],
          ),
          if (candidate case final preview?) ...[
            const SizedBox(height: 8),
            Text(
              preview.matched ? 'Preview: ${preview.kind}' : preview.notice,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (preview.matched) ...[
              const SizedBox(height: 4),
              SizedBox(
                height: 76,
                child: CustomPaint(
                  painter: _VectorCandidatePreviewPainter(preview),
                  child: const SizedBox.expand(),
                ),
              ),
              Text(
                preview.notice,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Wrap(
                spacing: 4,
                children: [
                  if (preview.kind == 'Rectangle')
                    OutlinedButton(
                      onPressed: () => onConstrainCandidate(0),
                      child: const Text('Square'),
                    ),
                  if (preview.kind == 'Ellipse')
                    OutlinedButton(
                      onPressed: () => onConstrainCandidate(1),
                      child: const Text('Circle'),
                    ),
                  FilledButton(
                    onPressed: onApplyCandidate,
                    child: const Text('Apply'),
                  ),
                  TextButton(
                    onPressed: onCancelCandidate,
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            ],
          ],
          if (strokes.isNotEmpty)
            Text(
              'Use Vector transform on canvas. Vector eraser edits selected '
              'legacy ink only; Bézier paths are not segment-erasable. '
              'Every edit is undoable.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
    ),
  );
}

class _VectorRepeatDialog extends StatefulWidget {
  const _VectorRepeatDialog();

  @override
  State<_VectorRepeatDialog> createState() => _VectorRepeatDialogState();
}

class _VectorRepeatDialogState extends State<_VectorRepeatDialog> {
  CanvasVectorRepeatMode _mode = CanvasVectorRepeatMode.radial;
  final _copies = TextEditingController(text: '8');
  final _columns = TextEditingController(text: '3');
  final _rows = TextEditingController(text: '3');
  final _spacingX = TextEditingController(text: '32');
  final _spacingY = TextEditingController(text: '32');
  final _stepDegrees = TextEditingController(text: '45');
  final _scalePerCopy = TextEditingController(text: '1');

  @override
  void dispose() {
    for (final controller in [
      _copies,
      _columns,
      _rows,
      _spacingX,
      _spacingY,
      _stepDegrees,
      _scalePerCopy,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Repeat Bézier path'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<CanvasVectorRepeatMode>(
            initialValue: _mode,
            decoration: const InputDecoration(labelText: 'Repeat pattern'),
            items: const [
              DropdownMenuItem(
                value: CanvasVectorRepeatMode.radial,
                child: Text('Radial'),
              ),
              DropdownMenuItem(
                value: CanvasVectorRepeatMode.grid,
                child: Text('Grid'),
              ),
              DropdownMenuItem(
                value: CanvasVectorRepeatMode.mirrorVertical,
                child: Text('Mirror across vertical center'),
              ),
              DropdownMenuItem(
                value: CanvasVectorRepeatMode.mirrorHorizontal,
                child: Text('Mirror across horizontal center'),
              ),
              DropdownMenuItem(
                value: CanvasVectorRepeatMode.mirrorBoth,
                child: Text('Mirror across both centers'),
              ),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _mode = value);
            },
          ),
          if (_mode == CanvasVectorRepeatMode.radial) ...[
            _repeatNumber('Additional copies (1–64)', _copies, integer: true),
            _repeatNumber('Rotation per copy (degrees)', _stepDegrees),
            _repeatNumber('Scale per copy (0.25–4)', _scalePerCopy),
          ],
          if (_mode == CanvasVectorRepeatMode.grid) ...[
            _repeatNumber(
              'Columns (including source)',
              _columns,
              integer: true,
            ),
            _repeatNumber('Rows (including source)', _rows, integer: true),
            _repeatNumber('Horizontal spacing (pixels)', _spacingX),
            _repeatNumber('Vertical spacing (pixels)', _spacingY),
          ],
          const SizedBox(height: 8),
          const Text(
            'Copies become ordinary editable paths and are added in one undo step.',
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Create copies')),
    ],
  );

  Widget _repeatNumber(
    String label,
    TextEditingController controller, {
    bool integer = false,
  }) => TextField(
    controller: controller,
    keyboardType: TextInputType.numberWithOptions(decimal: !integer),
    decoration: InputDecoration(labelText: label),
    textInputAction: TextInputAction.next,
  );

  void _submit() {
    final copies = int.tryParse(_copies.text.trim());
    final columns = int.tryParse(_columns.text.trim());
    final rows = int.tryParse(_rows.text.trim());
    final spacingX = double.tryParse(_spacingX.text.trim());
    final spacingY = double.tryParse(_spacingY.text.trim());
    final step = double.tryParse(_stepDegrees.text.trim());
    final scale = double.tryParse(_scalePerCopy.text.trim());
    if (copies == null ||
        copies < 1 ||
        copies > 64 ||
        columns == null ||
        columns < 1 ||
        rows == null ||
        rows < 1 ||
        columns * rows - 1 > 64 ||
        spacingX == null ||
        !spacingX.isFinite ||
        spacingY == null ||
        !spacingY.isFinite ||
        step == null ||
        !step.isFinite ||
        scale == null ||
        !scale.isFinite ||
        scale < 0.25 ||
        scale > 4) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter repeat settings within the shown limits.'),
        ),
      );
      return;
    }
    Navigator.of(context).pop(
      CanvasVectorRepeatOptions(
        mode: _mode,
        copies: copies,
        columns: columns,
        rows: rows,
        spacingX: spacingX,
        spacingY: spacingY,
        stepDegrees: step,
        scalePerCopy: scale,
      ),
    );
  }
}

class _VectorFitToleranceDialog extends StatefulWidget {
  const _VectorFitToleranceDialog();

  @override
  State<_VectorFitToleranceDialog> createState() =>
      _VectorFitToleranceDialogState();
}

class _VectorFitToleranceDialogState extends State<_VectorFitToleranceDialog> {
  double _tolerancePx = 1.0;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Fit curve tolerance'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('${_tolerancePx.toStringAsFixed(2)} document pixels'),
        Slider(
          min: 0.25,
          max: 8,
          divisions: 31,
          value: _tolerancePx,
          label: _tolerancePx.toStringAsFixed(2),
          onChanged: (value) => setState(() => _tolerancePx = value),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(_tolerancePx),
        child: const Text('Preview'),
      ),
    ],
  );
}

class _VectorPathEditDialog extends StatefulWidget {
  const _VectorPathEditDialog();

  @override
  State<_VectorPathEditDialog> createState() => _VectorPathEditDialogState();
}

class _VectorPathEditDialogState extends State<_VectorPathEditDialog> {
  final _subpath = TextEditingController(text: '0');
  final _index = TextEditingController(text: '0');
  final _dx = TextEditingController(text: '0');
  final _dy = TextEditingController(text: '0');
  final _parameter = TextEditingController(text: '0.5');
  final _rotation = TextEditingController(text: '0');
  final _scale = TextEditingController(text: '1');
  CanvasVectorEditKind _kind = CanvasVectorEditKind.moveAnchor;

  @override
  void dispose() {
    for (final controller in [
      _subpath,
      _index,
      _dx,
      _dy,
      _parameter,
      _rotation,
      _scale,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final subpath = int.tryParse(_subpath.text);
    final index = int.tryParse(_index.text);
    final dx = double.tryParse(_dx.text);
    final dy = double.tryParse(_dy.text);
    final t = double.tryParse(_parameter.text);
    final rotation = double.tryParse(_rotation.text);
    final scale = double.tryParse(_scale.text);
    if (subpath == null ||
        index == null ||
        subpath < 0 ||
        index < 0 ||
        [
          dx,
          dy,
          t,
          rotation,
          scale,
        ].any((value) => value == null || !value.isFinite)) {
      return;
    }
    Navigator.of(context).pop(
      CanvasVectorEditRequest(
        kind: _kind,
        subpath: subpath,
        index: index,
        dx: dx!,
        dy: dy!,
        t: t!,
        rotationDegrees: rotation!,
        uniformScale: scale!,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Edit Bézier path'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<CanvasVectorEditKind>(
            initialValue: _kind,
            decoration: const InputDecoration(labelText: 'Operation'),
            items: CanvasVectorEditKind.values
                .map(
                  (kind) => DropdownMenuItem(
                    value: kind,
                    child: Text(switch (kind) {
                      CanvasVectorEditKind.moveAnchor => 'Move anchor',
                      CanvasVectorEditKind.moveIncomingHandle =>
                        'Move incoming handle',
                      CanvasVectorEditKind.moveOutgoingHandle =>
                        'Move outgoing handle',
                      CanvasVectorEditKind.makeSmooth => 'Make smooth',
                      CanvasVectorEditKind.makeCorner => 'Make corner',
                      CanvasVectorEditKind.splitSegment => 'Split segment',
                      CanvasVectorEditKind.deleteAnchor => 'Delete anchor',
                      CanvasVectorEditKind.transform =>
                        'Translate / rotate / scale',
                    }),
                  ),
                )
                .toList(growable: false),
            onChanged: (kind) {
              if (kind != null) setState(() => _kind = kind);
            },
          ),
          TextField(
            controller: _subpath,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Subpath index'),
          ),
          TextField(
            controller: _index,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Anchor or segment index',
            ),
          ),
          TextField(
            controller: _dx,
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
              signed: true,
            ),
            decoration: const InputDecoration(
              labelText: 'Delta X / handle X / translation X',
            ),
          ),
          TextField(
            controller: _dy,
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
              signed: true,
            ),
            decoration: const InputDecoration(
              labelText: 'Delta Y / handle Y / translation Y',
            ),
          ),
          TextField(
            controller: _parameter,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Split parameter (0–1)',
            ),
          ),
          TextField(
            controller: _rotation,
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
              signed: true,
            ),
            decoration: const InputDecoration(labelText: 'Rotation degrees'),
          ),
          TextField(
            controller: _scale,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Positive uniform scale',
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Preview')),
    ],
  );
}

class _VectorCandidatePreviewPainter extends CustomPainter {
  const _VectorCandidatePreviewPainter(this.candidate);

  final VectorCandidateView candidate;

  @override
  void paint(Canvas canvas, Size size) {
    final geometry = candidate.geometry;
    final anchorCount = geometry.length ~/ 6;
    if (anchorCount == 0 || candidate.subpathStarts.isEmpty) return;
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    for (var index = 0; index < anchorCount; index++) {
      final x = geometry[index * 6];
      final y = geometry[index * 6 + 1];
      minX = minX < x ? minX : x;
      minY = minY < y ? minY : y;
      maxX = maxX > x ? maxX : x;
      maxY = maxY > y ? maxY : y;
    }
    final path = Path();
    for (var part = 0; part < candidate.subpathStarts.length; part++) {
      final start = candidate.subpathStarts[part];
      final end =
          part + 1 < candidate.subpathStarts.length
              ? candidate.subpathStarts[part + 1]
              : anchorCount;
      final count = end - start;
      if (count <= 0) continue;
      path.moveTo(geometry[start * 6], geometry[start * 6 + 1]);
      final segmentCount = candidate.closed[part] ? count : count - 1;
      for (var offset = 0; offset < segmentCount; offset++) {
        final from = start + offset;
        final to = start + ((offset + 1) % count);
        path.cubicTo(
          geometry[from * 6 + 4],
          geometry[from * 6 + 5],
          geometry[to * 6 + 2],
          geometry[to * 6 + 3],
          geometry[to * 6],
          geometry[to * 6 + 1],
        );
      }
      if (candidate.closed[part]) path.close();
    }
    final width = (maxX - minX).abs().clamp(1.0, double.infinity);
    final height = (maxY - minY).abs().clamp(1.0, double.infinity);
    final scale = (size.width / width).clamp(0.001, size.height / height);
    final color = candidate.strokeRgba;
    final alpha = color & 0xff;
    final red = (color >> 24) & 0xff;
    final green = (color >> 16) & 0xff;
    final blue = (color >> 8) & 0xff;
    canvas.save();
    canvas.translate(
      (size.width - width * scale) / 2,
      (size.height - height * scale) / 2,
    );
    canvas.scale(scale);
    canvas.translate(-minX, -minY);
    canvas.drawPath(
      path,
      Paint()
        ..color = Color.fromARGB(alpha, red, green, blue)
        ..style = PaintingStyle.stroke
        ..strokeWidth = candidate.strokeWidth.clamp(0.5, 8),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_VectorCandidatePreviewPainter oldDelegate) =>
      candidate != oldDelegate.candidate;
}

class ComicCanvasGuideOverlay extends StatelessWidget {
  const ComicCanvasGuideOverlay({
    super.key,
    required this.controller,
    required this.pan,
    required this.scale,
    required this.rotation,
    required this.mirrored,
    required this.documentWidth,
    required this.documentHeight,
    this.previewBytes,
    this.activePanelId,
  });

  final ComicWorkspaceController controller;
  final Offset pan;
  final double scale;
  final double rotation;
  final bool mirrored;
  final int documentWidth;
  final int documentHeight;
  final Uint8List? previewBytes;
  final BigInt? activePanelId;

  @override
  Widget build(BuildContext context) {
    final snapshot = controller.snapshot;
    // Structural panel edits invalidate the rasterized page preview. The
    // panel guide still needs the active page projection while that preview
    // is being regenerated, otherwise committed dividers disappear.
    final pageIndex = controller.activePageIndex;
    final page =
        snapshot != null && pageIndex >= 0 && pageIndex < snapshot.pages.length
            ? snapshot.pages[pageIndex]
            : null;
    if (page == null) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final pageTransform =
            Matrix4.identity()
              ..translateByDouble(
                constraints.maxWidth / 2 + pan.dx,
                constraints.maxHeight / 2 + pan.dy,
                0,
                1,
              )
              ..rotateZ(rotation)
              ..scaleByDouble(mirrored ? -scale : scale, scale, 1, 1)
              ..translateByDouble(
                -documentWidth / 2,
                -documentHeight / 2,
                0,
                1,
              );
        return Stack(
          fit: StackFit.expand,
          children: [
            if (previewBytes case final bytes?)
              Positioned.fill(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Transform(
                    alignment: Alignment.topLeft,
                    transform: pageTransform,
                    child: SizedBox(
                      width: documentWidth.toDouble(),
                      height: documentHeight.toDouble(),
                      child: Image.memory(
                        bytes,
                        fit: BoxFit.fill,
                        filterQuality: FilterQuality.medium,
                        gaplessPlayback: true,
                        excludeFromSemantics: true,
                      ),
                    ),
                  ),
                ),
              ),
            Positioned.fill(
              child: CustomPaint(
                painter: _ComicCanvasGuidePainter(
                  page: page,
                  pan: pan,
                  scale: scale,
                  rotation: rotation,
                  mirrored: mirrored,
                  documentWidth: documentWidth,
                  documentHeight: documentHeight,
                  activePanelId: activePanelId,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ComicCanvasGuidePainter extends CustomPainter {
  const _ComicCanvasGuidePainter({
    required this.page,
    required this.pan,
    required this.scale,
    required this.rotation,
    required this.mirrored,
    required this.documentWidth,
    required this.documentHeight,
    this.activePanelId,
  });

  final rust.ComicPageView page;
  final Offset pan;
  final double scale;
  final double rotation;
  final bool mirrored;
  final int documentWidth;
  final int documentHeight;
  final BigInt? activePanelId;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(size.width / 2 + pan.dx, size.height / 2 + pan.dy);
    canvas.rotate(rotation);
    canvas.scale(mirrored ? -scale : scale, scale);
    final scaleX = documentWidth / page.widthPx.clamp(1, 32768);
    final scaleY = documentHeight / page.heightPx.clamp(1, 32768);
    final origin = Offset(documentWidth / 2, documentHeight / 2);
    Offset toDocument(double x, double y) =>
        Offset(x * scaleX - origin.dx, y * scaleY - origin.dy);
    final border =
        Paint()
          ..color = const Color(0xff38bdf8).withValues(alpha: 0.88)
          ..style = PaintingStyle.stroke
          ..strokeWidth = (2 / scale.clamp(0.1, 32)).clamp(0.5, 4);
    final activeBorder =
        Paint()
          ..color = const Color(0xff34d399).withValues(alpha: 0.95)
          ..style = PaintingStyle.stroke
          ..strokeWidth = (3 / scale.clamp(0.1, 32)).clamp(1.0, 5);
    for (final panel in page.panels) {
      final rect = Rect.fromLTWH(
        panel.x * scaleX - origin.dx,
        panel.y * scaleY - origin.dy,
        panel.width * scaleX,
        panel.height * scaleY,
      );
      final points = panel.polygon;
      border.strokeWidth = (panel.borderPx * math.min(scaleX, scaleY) * scale)
          .clamp(0.5, 24);
      activeBorder.strokeWidth = (border.strokeWidth + 2 / scale.clamp(0.1, 32))
          .clamp(1.0, 28);
      if (points.length >= 6 && points.length.isEven) {
        final path =
            Path()..moveTo(
              toDocument(points[0], points[1]).dx,
              toDocument(points[0], points[1]).dy,
            );
        for (var i = 2; i < points.length; i += 2) {
          final point = toDocument(points[i], points[i + 1]);
          path.lineTo(point.dx, point.dy);
        }
        path.close();
        canvas.drawPath(
          path,
          panel.id == activePanelId ? activeBorder : border,
        );
      } else {
        canvas.drawRect(
          rect,
          panel.id == activePanelId ? activeBorder : border,
        );
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ComicCanvasGuidePainter oldDelegate) =>
      page != oldDelegate.page ||
      pan != oldDelegate.pan ||
      scale != oldDelegate.scale ||
      rotation != oldDelegate.rotation ||
      mirrored != oldDelegate.mirrored ||
      activePanelId != oldDelegate.activePanelId;
}
