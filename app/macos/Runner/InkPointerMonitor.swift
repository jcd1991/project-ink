// SPDX-License-Identifier: MPL-2.0
import AppKit

/// Consumes tablet-point events and leaves ordinary mouse/trackpad events to Flutter.
final class InkPointerMonitor {
    static let shared = InkPointerMonitor()

    private let adapter = InkPointerAdapter()
    private var monitor: Any?
    private var activeDevices = Set<UInt32>()
    private var sideButtonDown = false

    func start(view: NSView) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.tabletPoint, .tabletProximity]) {
            [weak self, weak view] event in
            guard let self, let view else { return event }
            return self.handle(event, in: view)
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        activeDevices.removeAll()
        sideButtonDown = false
    }

    private func handle(_ event: NSEvent, in view: NSView) -> NSEvent? {
        guard event.type == .tabletPoint else { return event }
        guard event.pointingDeviceType == .pen || event.pointingDeviceType == .eraser else {
            return event
        }

        let sideButtonDownNow = event.buttonMask.contains(.penLowerSide)
            || event.buttonMask.contains(.penUpperSide)
        if sideButtonDownNow && !sideButtonDown {
            _ = InkPencilCommandEventStream.shared.publish("toggleEraser")
        }
        sideButtonDown = sideButtonDownNow

        let pointerID = UInt32(truncatingIfNeeded: event.deviceID)
        let pressed = event.buttonMask.contains(.penTip)
        let wasActive = activeDevices.contains(pointerID)
        let phase: UInt8
        if pressed && !wasActive {
            phase = 0
            activeDevices.insert(pointerID)
        } else if pressed {
            phase = 1
        } else if wasActive {
            phase = 2
            activeDevices.remove(pointerID)
        } else {
            phase = 1
        }

        var flags: UInt16 = 1
        if event.pointingDeviceType == .eraser { flags |= 1 << 3 }
        if !pressed { flags |= 1 << 5 }
        guard let packet = adapter.packet(from: event, in: view, phase: phase, flags: flags) else {
            return event
        }
        return InkPointerEventStream.shared.publish(packet) ? nil : event
    }
}
