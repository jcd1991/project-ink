import '../bridge/engine_api.dart';
import '../documents/autosave_coordinator.dart';
import '../documents/document_picker.dart';

/// Document-session values and callbacks consumed by canvas document actions.
///
/// This boundary keeps document workflows independent of the concrete
/// `CanvasScreen` widget and its implementation library.
abstract interface class CanvasDocumentActionSession {
  EngineApi get engine;
  AutosaveCoordinator? get autosave;
  AutosaveState? get autosaveState;
  DocumentPicker? get documentPicker;
  Duration get documentPickerTimeout;
  String? get activeDocumentPath;

  Future<void> Function({
    required int widthPx,
    required int heightPx,
    required double dpi,
  })?
  get onNewDocument;

  Future<void> Function(String path)? get onOpenDocument;
  Future<void> Function(String path)? get onDocumentSaved;
  Future<void> Function()? get onBeforeOpenStudioProject;
  Future<void> Function(String path)? get onStudioProjectOpened;
  Future<void> Function()? get onDiscardRecovery;
}
