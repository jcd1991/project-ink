import Cocoa
import Darwin
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  private var inkLiveTextures: InkLiveTextureRegistry?
  private var windowCloseChannel: FlutterMethodChannel?
  private var closeRequestPending = false
  private var allowNextClose = false
  private var terminationDecisionPending = false
  private var lastWindowCloseApproved = false

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    let channel = FlutterEventChannel(
      name: "org.projectink.studio/pointer_packets_v1",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    channel.setStreamHandler(InkPointerEventStream.shared)
    let pointerStatus = FlutterEventChannel(
      name: "org.projectink.studio/pointer_status_v1",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    pointerStatus.setStreamHandler(InkPointerStatusEventStream.shared)
    let pencilCommands = FlutterEventChannel(
      name: "org.projectink.studio/pencil_commands_v1",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    pencilCommands.setStreamHandler(InkPencilCommandEventStream.shared)
    let performanceChannel = FlutterMethodChannel(
      name: "org.projectink.studio/performance_v1",
      binaryMessenger: flutterViewController.engine.binaryMessenger
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
    let liveTextures = InkLiveTextureRegistry(registry: flutterViewController.engine)
    inkLiveTextures = liveTextures
    let liveTextureChannel = FlutterMethodChannel(
      name: "org.projectink.studio/live_texture_v1",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    liveTextureChannel.setMethodCallHandler { call, result in
      liveTextures.handle(call, result: result)
    }
    let closeChannel = FlutterMethodChannel(
      name: "org.projectink.studio/window_close_v1",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    windowCloseChannel = closeChannel
    closeChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "window_unavailable", message: nil, details: nil))
        return
      }
      switch call.method {
      case "allowClose":
        self.closeRequestPending = false
        self.allowNextClose = true
        self.lastWindowCloseApproved = NSApp.windows.filter {
          $0.isVisible && !$0.isMiniaturized && !($0 is NSPanel)
        }.count <= 1
        self.performClose(nil)
        result(nil)
      case "cancelClose":
        self.closeRequestPending = false
        result(nil)
      case "allowTerminate":
        result(nil)
        DispatchQueue.main.async { [weak self] in
          self?.replyToTermination(allow: true)
        }
      case "cancelTerminate":
        result(nil)
        DispatchQueue.main.async { [weak self] in
          self?.replyToTermination(allow: false)
        }
      case "terminate":
        result(nil)
        DispatchQueue.main.async {
          NSApp.terminate(nil)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    InkPointerMonitor.shared.start(view: flutterViewController.view)

    super.awakeFromNib()
    delegate = self
  }

  func requestApplicationTermination() -> NSApplication.TerminateReply {
    if lastWindowCloseApproved {
      lastWindowCloseApproved = false
      return .terminateNow
    }
    guard !terminationDecisionPending else { return .terminateCancel }
    terminationDecisionPending = true
    guard let windowCloseChannel else {
      terminationDecisionPending = false
      return .terminateCancel
    }
    windowCloseChannel.invokeMethod("requestQuit", arguments: nil) {
      [weak self] result in
      if let error = result as? FlutterError {
        NSLog("Project Ink quit confirmation unavailable: %@", error.message ?? error.code)
        self?.replyToTermination(allow: false)
      }
    }
    return .terminateLater
  }

  private func replyToTermination(allow: Bool) {
    guard terminationDecisionPending else { return }
    terminationDecisionPending = false
    NSApp.reply(toApplicationShouldTerminate: allow)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if allowNextClose {
      allowNextClose = false
      return true
    }
    guard !closeRequestPending else { return false }
    closeRequestPending = true
    guard let windowCloseChannel else {
      // Keep the window open if Flutter cannot decide whether unsaved work is
      // safe to discard. Reset the latch so a later close can retry after the
      // channel becomes available.
      closeRequestPending = false
      NSLog("Project Ink close confirmation unavailable: channel not ready")
      return false
    }
    windowCloseChannel.invokeMethod("requestClose", arguments: nil) { [weak self] result in
      if let error = result as? FlutterError {
        NSLog("Project Ink close confirmation unavailable: %@", error.message ?? error.code)
        self?.closeRequestPending = false
      }
    }
    return false
  }
}
