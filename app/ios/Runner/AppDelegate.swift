import Flutter
import Darwin
import Foundation
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let providerDocumentPicker = InkProviderDocumentPicker()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterEventChannel(
      name: "org.projectink.studio/pointer_packets_v1",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setStreamHandler(InkPointerEventStream.shared)
    let pointerStatus = FlutterEventChannel(
      name: "org.projectink.studio/pointer_status_v1",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    pointerStatus.setStreamHandler(InkPointerStatusEventStream.shared)
    let nativeDiagnosticsChannel = FlutterEventChannel(
      name: "org.projectink.studio/canvas_diagnostics_v1",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    nativeDiagnosticsChannel.setStreamHandler(InkCanvasDiagnosticEventStream.shared)
    let pencilCommands = FlutterEventChannel(
      name: "org.projectink.studio/pencil_commands_v1",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    pencilCommands.setStreamHandler(InkPencilCommandEventStream.shared)
    let liveTextures = InkLiveTextureRegistry(
      registry: engineBridge.applicationRegistrar.textures()
    )
    let liveTextureChannel = FlutterMethodChannel(
      name: "org.projectink.studio/live_texture_v1",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    liveTextureChannel.setMethodCallHandler { call, result in
      liveTextures.handle(call, result: result)
    }
    let providerChannel = FlutterMethodChannel(
      name: "org.projectink.studio/provider_documents_v1",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    providerChannel.setMethodCallHandler { [weak self] call, result in
      if call.method == "preparePngExport" {
        guard let self else {
          result(
            FlutterError(code: "unavailable", message: "App delegate unavailable.", details: nil)
          )
          return
        }
        let arguments = call.arguments as? [String: Any]
        let suggestedName = arguments?["suggestedName"] as? String ?? "untitled.png"
        do {
          guard let selection = try self.providerDocumentPicker.preparePngExport(
            suggestedName: suggestedName
          ) else {
            result(nil)
            return
          }
          result([
            "path": selection.path,
            "canWriteBack": selection.canWriteBack,
          ])
        } catch {
          result(
            FlutterError(
              code: "export_unavailable",
              message: error.localizedDescription,
              details: nil
            )
          )
        }
        return
      }
      if call.method == "commitProject" {
        guard let arguments = call.arguments as? [String: Any],
          let localPath = arguments["localPath"] as? String
        else {
          result(
            FlutterError(code: "invalid_arguments", message: "Missing localPath.", details: nil)
          )
          return
        }
        guard let self else {
          result(
            FlutterError(code: "unavailable", message: "App delegate unavailable.", details: nil)
          )
          return
        }
        DispatchQueue.global(qos: .userInitiated).async {
          do {
            try self.providerDocumentPicker.commitProject(localPath: localPath)
            DispatchQueue.main.async { result(nil) }
          } catch {
            DispatchQueue.main.async {
              result(
                FlutterError(
                  code: "writeback_failed",
                  message: error.localizedDescription,
                  details: nil
                )
              )
            }
          }
        }
        return
      }
      if call.method == "commitPng" {
        guard let arguments = call.arguments as? [String: Any],
          let localPath = arguments["localPath"] as? String
        else {
          result(
            FlutterError(code: "invalid_arguments", message: "Missing localPath.", details: nil)
          )
          return
        }
        guard let self else {
          result(
            FlutterError(code: "unavailable", message: "App delegate unavailable.", details: nil)
          )
          return
        }
        DispatchQueue.global(qos: .userInitiated).async {
          do {
            try self.providerDocumentPicker.commitPng(localPath: localPath)
            DispatchQueue.main.async { result(nil) }
          } catch {
            DispatchQueue.main.async {
              result(
                FlutterError(
                  code: "writeback_failed",
                  message: error.localizedDescription,
                  details: nil
                )
              )
            }
          }
        }
        return
      }
      guard call.method == "openProject" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let self, let presenter = self.topViewController() else {
        result(
          FlutterError(
            code: "unavailable",
            message: "No iOS view controller is available.",
            details: nil
          )
        )
        return
      }
      do {
        try self.providerDocumentPicker.present(from: presenter) { outcome in
          switch outcome {
          case .success(let selection):
            guard let selection else {
              result(nil)
              return
            }
            result([
              "path": selection.path,
              "canWriteBack": selection.canWriteBack,
            ])
          case .failure(let error):
            result(
              FlutterError(
                code: "copy_failed",
                message: error.localizedDescription,
                details: nil
              )
            )
          }
        }
      } catch {
        result(
          FlutterError(
            code: "unavailable",
            message: error.localizedDescription,
            details: nil
          )
        )
      }
    }

    let performanceChannel = FlutterMethodChannel(
      name: "org.projectink.studio/performance_v1",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    performanceChannel.setMethodCallHandler { call, result in
      guard call.method == "readRssBytes" else {
        result(FlutterMethodNotImplemented)
        return
      }
      var info = mach_task_basic_info()
      var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
      )
      let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: 1) { rebound in
          task_info(
            mach_task_self_,
            task_flavor_t(MACH_TASK_BASIC_INFO),
            rebound,
            &count
          )
        }
      }
      guard status == KERN_SUCCESS else {
        result(nil)
        return
      }
      result(Int64(info.resident_size))
    }

  }

  private func topViewController() -> UIViewController? {
    let window = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first { $0.isKeyWindow }
    var controller = window?.rootViewController
    while let presented = controller?.presentedViewController {
      controller = presented
    }
    return controller
  }
}

enum InkProviderDocumentError: LocalizedError {
  case busy
  case invalidSelection
  case copyFailed(String)

  var errorDescription: String? {
    switch self {
    case .busy:
      return "A provider picker is already open."
    case .invalidSelection:
      return "Select one .inkproj project folder or .psd image."
    case .copyFailed(let message):
      return message
    }
  }
}

struct InkProviderProjectSelection {
  let path: String
  let canWriteBack: Bool
}

/// Presents the iOS Files provider and stages a selected project locally.
/// The Rust engine is deliberately given only the staged filesystem path.
final class InkProviderDocumentPicker: NSObject, UIDocumentPickerDelegate {
  private static let maxProviderEntries = 100_000
  private static let maxProviderBytes: Int64 = 1 << 30
  private static let maxProviderDepth = 64

  private var completion: ((Result<InkProviderProjectSelection?, Error>) -> Void)?
  private var activeSourceURL: URL?
  private var activeLocalProjectURL: URL?
  private var activeCanWriteBack = false
  private var activePngExportURL: URL?
  private var activePngExportName: String?

  func present(
    from presenter: UIViewController,
    completion: @escaping (Result<InkProviderProjectSelection?, Error>) -> Void
  ) throws {
    guard self.completion == nil else {
      throw InkProviderDocumentError.busy
    }
    self.completion = completion
    let picker = UIDocumentPickerViewController(
      forOpeningContentTypes: [.folder, .data],
      asCopy: false
    )
    picker.delegate = self
    presenter.present(picker, animated: true)
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    guard let selectedURL = urls.first else {
      finish(.success(nil))
      return
    }
    let securityScoped = selectedURL.startAccessingSecurityScopedResource()
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      defer {
        if securityScoped {
          selectedURL.stopAccessingSecurityScopedResource()
        }
      }
      do {
        let selection = try Self.stageProject(at: selectedURL)
        DispatchQueue.main.async {
          self?.activeSourceURL = selection.sourceURL
          self?.activeLocalProjectURL = URL(
            fileURLWithPath: selection.path,
            isDirectory: selection.path.lowercased().hasSuffix(".inkproj")
          )
          self?.activeCanWriteBack = selection.canWriteBack
          self?.activePngExportURL = nil
          self?.activePngExportName = nil
          self?.finish(.success(selection.selection))
        }
      } catch {
        DispatchQueue.main.async { self?.finish(.failure(error)) }
      }
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finish(.success(nil))
  }

  func commitProject(localPath: String) throws {
    guard activeCanWriteBack, let sourceURL = activeSourceURL else { return }
    let fileManager = FileManager.default
    let localURL = URL(fileURLWithPath: localPath, isDirectory: true)
      .resolvingSymlinksInPath().standardizedFileURL
    guard let expectedLocalURL = activeLocalProjectURL?
      .resolvingSymlinksInPath().standardizedFileURL,
      localURL == expectedLocalURL
    else {
      throw InkProviderDocumentError.copyFailed("The staged project path does not match.")
    }
    var localIsDirectory = ObjCBool(false)
    guard fileManager.fileExists(atPath: localURL.path, isDirectory: &localIsDirectory),
      localIsDirectory.boolValue
    else {
      throw InkProviderDocumentError.copyFailed("The staged project is missing.")
    }
    let scoped = sourceURL.startAccessingSecurityScopedResource()
    defer {
      if scoped { sourceURL.stopAccessingSecurityScopedResource() }
    }
    let parent = sourceURL.deletingLastPathComponent()
    let temp = parent.appendingPathComponent(
      "\(sourceURL.lastPathComponent).inkproj.tmp-\(UUID().uuidString)",
      isDirectory: true
    )
    let backup = parent.appendingPathComponent(
      "\(sourceURL.lastPathComponent).inkproj.backup-\(UUID().uuidString)",
      isDirectory: true
    )
    do {
      var budget = CopyBudget()
      try Self.copyTree(at: localURL, to: temp, budget: &budget, depth: 0)
      try fileManager.moveItem(at: sourceURL, to: backup)
      do {
        try fileManager.moveItem(at: temp, to: sourceURL)
      } catch {
        try? fileManager.moveItem(at: backup, to: sourceURL)
        throw error
      }
      try? fileManager.removeItem(at: backup)
      activeSourceURL = sourceURL
      activePngExportURL = nil
      activePngExportName = nil
    } catch {
      try? fileManager.removeItem(at: temp)
      throw InkProviderDocumentError.copyFailed(error.localizedDescription)
    }
  }

  func preparePngExport(suggestedName: String) throws -> InkProviderProjectSelection? {
    guard activeCanWriteBack, activeSourceURL != nil else { return nil }
    let fileManager = FileManager.default
    let appSupport = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let exports = appSupport.appendingPathComponent("ProviderExports", isDirectory: true)
    try fileManager.createDirectory(at: exports, withIntermediateDirectories: true)
    let name = Self.pngName(suggestedName)
    let destination = Self.uniqueFileDestination(in: exports, name: name)
    guard fileManager.createFile(atPath: destination.path, contents: nil) else {
      throw InkProviderDocumentError.copyFailed("Unable to create a local PNG export.")
    }
    activePngExportURL = destination
    activePngExportName = destination.lastPathComponent
    return InkProviderProjectSelection(path: destination.path, canWriteBack: true)
  }

  func commitPng(localPath: String) throws {
    guard activeCanWriteBack,
      let sourceURL = activeSourceURL,
      let exportURL = activePngExportURL,
      let exportName = activePngExportName
    else { return }
    let fileManager = FileManager.default
    let localURL = URL(fileURLWithPath: localPath, isDirectory: false)
      .resolvingSymlinksInPath().standardizedFileURL
    let expectedExportURL = exportURL.resolvingSymlinksInPath().standardizedFileURL
    let exportValues = try localURL.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
    )
    guard localURL == expectedExportURL,
      exportValues.isRegularFile == true,
      exportValues.isSymbolicLink != true
    else {
      throw InkProviderDocumentError.copyFailed("The staged PNG path does not match.")
    }
    let fileSize = try localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard Int64(fileSize) <= Self.maxProviderBytes else {
      throw InkProviderDocumentError.copyFailed("The PNG export exceeds the write limit.")
    }
    let scoped = sourceURL.startAccessingSecurityScopedResource()
    defer {
      if scoped { sourceURL.stopAccessingSecurityScopedResource() }
    }
    let parent = sourceURL.deletingLastPathComponent()
    let destinationName = Self.nextAvailableFileName(in: parent, requested: exportName)
    let destination = parent.appendingPathComponent(destinationName, isDirectory: false)
    let temp = parent.appendingPathComponent(
      ".\(destinationName).tmp-\(UUID().uuidString)",
      isDirectory: false
    )
    do {
      try fileManager.copyItem(at: localURL, to: temp)
      try fileManager.moveItem(at: temp, to: destination)
      try? fileManager.removeItem(at: localURL)
      activePngExportURL = nil
      activePngExportName = nil
    } catch {
      try? fileManager.removeItem(at: temp)
      throw InkProviderDocumentError.copyFailed(error.localizedDescription)
    }
  }

  private func finish(_ result: Result<InkProviderProjectSelection?, Error>) {
    let callback = completion
    completion = nil
    callback?(result)
  }

  private struct StagedProject {
    let path: String
    let sourceURL: URL
    let canWriteBack: Bool

    var selection: InkProviderProjectSelection {
      InkProviderProjectSelection(path: path, canWriteBack: canWriteBack)
    }
  }

  private static func stageProject(at selectedURL: URL) throws -> StagedProject {
    let source = try projectSource(at: selectedURL)
    let fileManager = FileManager.default
    let appSupport = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let imports = appSupport.appendingPathComponent("ProviderImports", isDirectory: true)
    try fileManager.createDirectory(at: imports, withIntermediateDirectories: true)
    if source.source.pathExtension.lowercased() == "psd" {
      let destination = uniqueDestination(
        in: imports,
        name: safeComponent(source.source.lastPathComponent)
      )
      do {
        var budget = CopyBudget()
        try copyFile(at: source.source, to: destination, budget: &budget)
        return StagedProject(
          path: destination.path,
          sourceURL: source.source,
          canWriteBack: false
        )
      } catch {
        try? fileManager.removeItem(at: destination)
        throw InkProviderDocumentError.copyFailed(error.localizedDescription)
      }
    }
    let destination = uniqueDestination(
      in: imports,
      name: projectName(source.source.lastPathComponent)
    )
    do {
      var budget = CopyBudget()
      try copyTree(at: source.source, to: destination, budget: &budget, depth: 0)
      return StagedProject(
        path: destination.path,
        sourceURL: source.source,
        canWriteBack: source.parent != nil
      )
    } catch {
      try? fileManager.removeItem(at: destination)
      throw InkProviderDocumentError.copyFailed(error.localizedDescription)
    }
  }

  private struct CopyBudget {
    var entries = 0
    var bytes: Int64 = 0
  }

  private static func copyTree(
    at source: URL,
    to destination: URL,
    budget: inout CopyBudget,
    depth: Int
  ) throws {
    guard depth <= maxProviderDepth else {
      throw InkProviderDocumentError.copyFailed(
        "The provider project directory nesting is too deep."
      )
    }
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
    let children = try fileManager.contentsOfDirectory(
      at: source,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: []
    )
    for child in children {
      budget.entries += 1
      guard budget.entries <= maxProviderEntries else {
        throw InkProviderDocumentError.copyFailed(
          "The provider project contains too many entries."
        )
      }
      let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isSymbolicLink != true else {
        throw InkProviderDocumentError.copyFailed(
          "Project folders cannot contain symbolic links."
        )
      }
      let isDirectory = values.isDirectory == true
      let target = uniqueChild(
        in: destination,
        name: safeComponent(child.lastPathComponent),
        isDirectory: isDirectory
      )
      if isDirectory {
        try copyTree(at: child, to: target, budget: &budget, depth: depth + 1)
      } else {
        try copyFile(at: child, to: target, budget: &budget)
      }
    }
  }

  private static func copyFile(
    at source: URL,
    to destination: URL,
    budget: inout CopyBudget
  ) throws {
    let fileManager = FileManager.default
    guard fileManager.createFile(atPath: destination.path, contents: nil) else {
      throw InkProviderDocumentError.copyFailed("Unable to create a staged file.")
    }
    let input = try FileHandle(forReadingFrom: source)
    let output = try FileHandle(forWritingTo: destination)
    defer {
      try? input.close()
      try? output.close()
    }
    while let data = try input.read(upToCount: 64 * 1024), !data.isEmpty {
      budget.bytes += Int64(data.count)
      guard budget.bytes <= maxProviderBytes else {
        throw InkProviderDocumentError.copyFailed(
          "The provider project exceeds the import limit."
        )
      }
      try output.write(contentsOf: data)
    }
  }

  private static func uniqueChild(in directory: URL, name: String, isDirectory: Bool) -> URL {
    let fileManager = FileManager.default
    var candidate = directory.appendingPathComponent(name, isDirectory: isDirectory)
    var index = 2
    while fileManager.fileExists(atPath: candidate.path) {
      let stem = candidate.deletingPathExtension().lastPathComponent
      let suffix = candidate.pathExtension.isEmpty ? "" : ".\(candidate.pathExtension)"
      candidate = directory.appendingPathComponent(
        "\(stem)-\(index)\(suffix)",
        isDirectory: isDirectory
      )
      index += 1
    }
    return candidate
  }

  private static func safeComponent(_ value: String) -> String {
    let filtered = value.unicodeScalars.map { scalar -> Character in
      if CharacterSet.alphanumerics.contains(scalar) ||
        scalar == "." || scalar == "_" || scalar == "-" || scalar == " " {
        return Character(String(scalar))
      }
      return "_"
    }
    let safe = String(filtered)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "..", with: "_")
    let bounded = String(safe.prefix(240))
    return bounded.isEmpty || bounded == "." || bounded == ".." ? "unnamed" : bounded
  }

  private static func projectSource(at selectedURL: URL) throws -> (source: URL, parent: URL?) {
    let fileManager = FileManager.default
    let selectedValues = try selectedURL.resourceValues(forKeys: [.isSymbolicLinkKey])
    guard selectedValues.isSymbolicLink != true else {
      throw InkProviderDocumentError.invalidSelection
    }
    var isDirectory = ObjCBool(false)
    guard fileManager.fileExists(atPath: selectedURL.path, isDirectory: &isDirectory) else {
      throw InkProviderDocumentError.invalidSelection
    }
    if !isDirectory.boolValue {
      guard selectedURL.pathExtension.lowercased() == "psd" else {
        throw InkProviderDocumentError.invalidSelection
      }
      return (selectedURL, nil)
    }
    if selectedURL.pathExtension.lowercased() == "inkproj" {
      return (selectedURL, nil)
    }
    let children = try fileManager.contentsOfDirectory(
      at: selectedURL,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    )
    let projects = try children.filter { child in
      guard child.pathExtension.lowercased() == "inkproj" else { return false }
      let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      return values.isDirectory == true && values.isSymbolicLink != true
    }
    guard projects.count == 1, let project = projects.first else {
      throw InkProviderDocumentError.invalidSelection
    }
    return (project, selectedURL)
  }

  private static func projectName(_ value: String) -> String {
    let safe = safeComponent(value)
    return safe.lowercased().hasSuffix(".inkproj") ? safe : "\(safe).inkproj"
  }

  private static func pngName(_ value: String) -> String {
    let safe = safeComponent(value)
    return safe.lowercased().hasSuffix(".png") ? safe : "\(safe).png"
  }

  private static func uniqueFileDestination(in directory: URL, name: String) -> URL {
    let fileManager = FileManager.default
    var candidate = directory.appendingPathComponent(name, isDirectory: false)
    var index = 2
    while fileManager.fileExists(atPath: candidate.path) {
      let stem = candidate.deletingPathExtension().lastPathComponent
      let suffix = candidate.pathExtension.isEmpty ? "" : ".\(candidate.pathExtension)"
      candidate = directory.appendingPathComponent(
        "\(stem)-\(index)\(suffix)",
        isDirectory: false
      )
      index += 1
    }
    return candidate
  }

  private static func nextAvailableFileName(in directory: URL, requested: String) -> String {
    let fileManager = FileManager.default
    if !fileManager.fileExists(atPath: directory.appendingPathComponent(requested).path) {
      return requested
    }
    let requestedURL = URL(fileURLWithPath: requested)
    let stem = requestedURL.deletingPathExtension().lastPathComponent
    let suffix = requestedURL.pathExtension.isEmpty ? "" : ".\(requestedURL.pathExtension)"
    var index = 2
    while fileManager.fileExists(
      atPath: directory.appendingPathComponent("\(stem)-\(index)\(suffix)").path
    ) {
      index += 1
    }
    return "\(stem)-\(index)\(suffix)"
  }

  private static func uniqueDestination(in directory: URL, name: String) -> URL {
    let fileManager = FileManager.default
    var candidate = directory.appendingPathComponent(name, isDirectory: true)
    var index = 2
    while fileManager.fileExists(atPath: candidate.path) {
      let stem = candidate.deletingPathExtension().lastPathComponent
      candidate = directory.appendingPathComponent(
        "\(stem)-\(index).inkproj",
        isDirectory: true
      )
      index += 1
    }
    return candidate
  }
}
