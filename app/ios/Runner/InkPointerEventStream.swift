// SPDX-License-Identifier: MPL-2.0
import Flutter
import Foundation

/// Event-channel transport for high-fidelity Pencil packets.
final class InkPointerEventStream: NSObject, FlutterStreamHandler {
    static let shared = InkPointerEventStream()

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
    func publish(_ packet: Data) -> Bool {
        guard !packet.isEmpty, sink != nil else { return false }
        // Keep Flutter channel delivery outside the UIKit recognizer callback.
        // This preserves the established asynchronous boundary for high-rate
        // Pencil samples and avoids re-entering Flutter while UIKit is
        // dispatching touch updates.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sink?(FlutterStandardTypedData(bytes: packet))
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

/// Low-rate native input/render failures for the opt-in local canvas trace.
final class InkCanvasDiagnosticEventStream: NSObject, FlutterStreamHandler {
    static let shared = InkCanvasDiagnosticEventStream()

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
    func publish(_ event: [String: Any]) -> Bool {
        guard sink != nil else { return false }
        DispatchQueue.main.async { [weak self] in
            self?.sink?(event)
        }
        return true
    }
}

/// Discrete Apple Pencil commands are separate from the high-frequency sample
/// stream so they cannot accidentally start or end a stroke.
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
