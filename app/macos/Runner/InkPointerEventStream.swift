// SPDX-License-Identifier: MPL-2.0
import FlutterMacOS

final class InkPointerEventStream: NSObject, FlutterStreamHandler {
    static let shared = InkPointerEventStream()

    private var sink: FlutterEventSink?

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        return nil
    }

    @discardableResult
    func publish(_ packet: Data) -> Bool {
        guard sink != nil else { return false }
        DispatchQueue.main.async { [weak self] in
            self?.sink?(FlutterStandardTypedData(bytes: packet))
        }
        return true
    }
}

/// Readiness signal used to arbitrate generic stylus fallback during startup.
final class InkPointerStatusEventStream: NSObject, FlutterStreamHandler {
    static let shared = InkPointerStatusEventStream()

    private var sink: FlutterEventSink?

    func onListen(withArguments _: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        DispatchQueue.main.async { [weak self] in
            self?.sink?("ready")
        }
        return nil
    }

    func onCancel(withArguments _: Any?) -> FlutterError? {
        sink = nil
        return nil
    }
}

/// Discrete tablet-button commands are separate from the high-frequency
/// sample stream so a side-button press cannot begin or end a stroke.
final class InkPencilCommandEventStream: NSObject, FlutterStreamHandler {
    static let shared = InkPencilCommandEventStream()

    private var sink: FlutterEventSink?

    func onListen(withArguments _: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        return nil
    }

    func onCancel(withArguments _: Any?) -> FlutterError? {
        sink = nil
        return nil
    }

    @discardableResult
    func publish(_ command: String) -> Bool {
        guard sink != nil else { return false }
        DispatchQueue.main.async { [weak self] in
            self?.sink?(command)
        }
        return true
    }
}
