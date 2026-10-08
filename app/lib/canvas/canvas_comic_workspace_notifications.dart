import 'dart:async';

import 'package:flutter/widgets.dart';

/// Resolves automatic workspace selection from the owning document type.
/// Illustration panel metadata is still an illustration document and should
/// not move the user into the multi-page Comic workspace.
String canvasWorkspaceForDocument({
  required bool hasProject,
  required bool isIllustrationPanelProject,
}) => !hasProject || isIllustrationPanelProject ? 'illustration' : 'comic';

/// Owns listener registration and frame-coalesced workspace-change handling.
///
/// The route supplies the comic-page and document-type projections because it
/// owns those selections. This coordinator owns notification timing and
/// removes its listener when the route releases it.
class CanvasComicWorkspaceNotifications {
  CanvasComicWorkspaceNotifications({
    required Listenable source,
    required bool Function() isMounted,
    required bool Function() shouldClearSelection,
    required Future<void> Function() clearSelection,
    required VoidCallback rebuild,
    required bool Function() followsDocumentType,
    required String Function() workspaceForDocument,
    required ValueChanged<String> selectWorkspace,
  }) : _source = source,
       _isMounted = isMounted,
       _shouldClearSelection = shouldClearSelection,
       _clearSelection = clearSelection,
       _rebuild = rebuild,
       _followsDocumentType = followsDocumentType,
       _workspaceForDocument = workspaceForDocument,
       _selectWorkspace = selectWorkspace;

  final Listenable _source;
  final bool Function() _isMounted;
  final bool Function() _shouldClearSelection;
  final Future<void> Function() _clearSelection;
  final VoidCallback _rebuild;
  final bool Function() _followsDocumentType;
  final String Function() _workspaceForDocument;
  final ValueChanged<String> _selectWorkspace;
  bool _started = false;
  bool _notificationScheduled = false;
  bool _disposed = false;

  void start() {
    if (_started || _disposed) return;
    _started = true;
    _source.addListener(_onChanged);
  }

  void _onChanged() {
    if (_disposed || !_isMounted() || _notificationScheduled) return;
    if (_shouldClearSelection()) unawaited(_clearSelection());

    _notificationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _notificationScheduled = false;
      if (_disposed || !_isMounted()) return;
      _rebuild();
      if (_followsDocumentType()) {
        _selectWorkspace(_workspaceForDocument());
      }
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_started) _source.removeListener(_onChanged);
    _started = false;
  }
}
