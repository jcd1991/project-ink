/// Platform-owned path selection for Project Ink documents and exports.
///
/// The native project is directory-backed, so each platform chooses how to
/// present its document browser. The drawing engine only receives the chosen
/// path after the user confirms an action.
abstract interface class DocumentPicker {
  Future<String?> openProject();

  Future<String?> saveProject({String suggestedName = 'untitled.inkproj'});

  Future<String?> exportPng({String suggestedName = 'untitled.png'});
}

/// Optional PSD import flow, separate from opening directory-backed projects.
abstract interface class PsdImportPicker {
  Future<String?> openPsd();
}

/// Optional brush-pack picker. Kept separate from [DocumentPicker] so custom
/// document pickers and widget-test fakes do not need to implement brush I/O.
/// Implementations must return a local filesystem path that Rust can read or
/// write; provider-backed paths should be staged by the platform adapter.
abstract interface class BrushPicker {
  Future<String?> openBrush();

  Future<String?> saveBrush({String suggestedName = 'brush.inkbrush'});
}

/// Optional write-back capability for a provider-imported project.
///
/// A picker may keep saves local when the provider cannot offer a safe
/// transactional destination. The canvas checks this interface after Rust has
/// successfully published the local `.inkproj` snapshot.
abstract interface class DocumentWriteback {
  Future<void> commitProject(String localPath);
}

/// Optional write-back capability for a provider-backed PNG export.
///
/// The engine always writes the PNG to a local filesystem path first. Native
/// code may then promote that completed file into the provider using a
/// collision-safe, bounded copy.
abstract interface class DocumentPngWriteback {
  Future<void> commitPng(String localPath);
}

/// Chooses a local destination for a non-PNG document export. Provider
/// write-back remains intentionally PNG/project-specific until each platform
/// can offer the same transactional contract.
abstract interface class DocumentExportPicker {
  Future<String?> saveExport({
    required String extension,
    String? suggestedName,
  });
}

/// Chooses a local directory for a multi-page comic export. The Rust bridge
/// writes only after the user has selected the destination.
abstract interface class ComicExportPicker {
  Future<String?> chooseComicExportDirectory({
    String suggestedName = 'comic-pages',
  });
}

/// Exposes whether a mobile picker is currently editing a staged provider
/// project. The canvas uses this to avoid prompting for a new name when Save
/// is meant to update the imported project in place.
abstract interface class ProviderDocumentState {
  bool get hasActiveProviderProject;
}
