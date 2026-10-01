// SPDX-License-Identifier: MPL-2.0
import AppKit

final class InkPointerAdapter {
    private var sequence: UInt32 = 0

    func packet(
        from event: NSEvent,
        in view: NSView,
        phase: UInt8,
        flags: UInt16
    ) -> Data? {
        let point = view.convert(event.locationInWindow, from: nil)
        // NSEvent.rotation is degrees; pointer packet v1 stores a normalized
        // turn so response curves behave identically across platforms.
        let normalizedRotation = (Double(event.rotation) / 360.0)
            .truncatingRemainder(dividingBy: 1.0)
        let normalizedRotationInRange = normalizedRotation >= 0
            ? normalizedRotation
            : normalizedRotation + 1.0
        let timestamp = event.timestamp.isFinite && event.timestamp >= 0
            ? min(event.timestamp, Double(UInt64.max) / 1_000_000_000)
            : 0
        let sample: InkPointerSampleV1 = (
            pointerID: UInt32(truncatingIfNeeded: event.deviceID),
            flags: flags,
            deviceKind: 1,
            phase: phase,
            canvasX: Float(point.x),
            canvasY: Float(point.y),
            pressure: Float(min(max(event.pressure, 0), 1)),
            tiltX: Float(event.tilt.x),
            tiltY: Float(event.tilt.y),
            azimuth: 0,
            twist: Float(normalizedRotationInRange),
            timestampNS: UInt64(timestamp * 1_000_000_000),
            sequence: nextSequence()
        )
        return InkPointerPacketV1.encode([sample])
    }

    private func nextSequence() -> UInt32 {
        defer { sequence &+= 1 }
        return sequence
    }
}
