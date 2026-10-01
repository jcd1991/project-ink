// SPDX-License-Identifier: MPL-2.0
import Flutter
import Foundation
import UIKit

/// Presents a user-controlled Files export for a completed local trace.
final class InkCanvasDiagnosticsExporter: NSObject, UIDocumentPickerDelegate {
  private var completion: FlutterResult?

  func export(path: String, from presenter: UIViewController, result: @escaping FlutterResult) {
    guard completion == nil else {
      result(FlutterError(code: "busy", message: "A diagnostic export is already open.", details: nil))
      return
    }
    let source = URL(fileURLWithPath: path).standardizedFileURL
    guard source.pathExtension.lowercased() == "jsonl",
      FileManager.default.fileExists(atPath: source.path)
    else {
      result(FlutterError(code: "invalid_trace", message: "The diagnostic trace is missing or invalid.", details: nil))
      return
    }
    completion = result
    let picker = UIDocumentPickerViewController(forExporting: [source], asCopy: true)
    picker.delegate = self
    presenter.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    finish(true)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finish(false)
  }

  private func finish(_ didExport: Bool) {
    let result = completion
    completion = nil
    result?(didExport)
  }
}
