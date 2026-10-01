import Cocoa
import Darwin
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var inkLiveTextures: InkLiveTextureRegistry?

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
    InkPointerMonitor.shared.start(view: flutterViewController.view)

    super.awakeFromNib()
  }
}
