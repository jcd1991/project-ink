// SPDX-License-Identifier: MPL-2.0
import UIKit

/// Converts high-fidelity Pencil touches into the platform-neutral packet.
final class InkPointerAdapter {
    private var sequence: UInt32 = 0
    private var pendingContactStarts = InkPointerContactStartBuffer()

    func isStylus(_ touch: UITouch) -> Bool {
        touch.type == .pencil
    }

    func packet(
        from touches: [UITouch],
        event: UIEvent?,
        in view: UIView,
        phase: UInt8
    ) -> [Data]? {
        var samples: [InkPointerSampleV1] = []
        for touch in touches where isStylus(touch) {
            let pointerID = UInt32(truncatingIfNeeded: touch.hash)
            if phase == 0 {
                pendingContactStarts.hold(
                    sample(touch, in: view, phase: phase, flags: 1)
                )
                continue
            }

            if phase == 1 {
                // UIKit returns historical/coalesced samples in time order.
                // Emit them before the current sample so the renderer never
                // walks backward along the stroke within a packet.
                let coalesced = event?.coalescedTouches(for: touch) ?? []
                // UIKit includes a copy of the current touch as the final
                // coalesced element. Object identity is not a safe way to
                // remove it: the documented element is a copy, not
                // necessarily the same UITouch instance. Emit the historical
                // prefix, then append `touch` exactly once below.
                let historical = coalesced.dropLast().map {
                    sample($0, in: view, phase: phase, flags: 1 << 1)
                }
                let current = sample(touch, in: view, phase: phase, flags: 1)
                if let start = pendingContactStarts.take(
                    for: pointerID,
                    usingFirstMeasuredPressure: historical.first?.pressure ?? current.pressure
                ) {
                    samples.append(start)
                }
                samples.append(contentsOf: historical)
                samples.append(current)
                let predicted = event?.predictedTouches(for: touch) ?? []
                for candidate in predicted {
                    samples.append(sample(candidate, in: view, phase: phase, flags: 1 << 2))
                }
                continue
            }

            if let start = pendingContactStarts.take(for: pointerID) {
                // A stationary tap has no measured move sample to calibrate
                // its starting dab. Preserve its initial contact pressure
                // and deliver the down and terminal samples together.
                samples.append(start)
            }
            samples.append(sample(touch, in: view, phase: phase, flags: 1))
        }
        return InkPointerPacketV1.encode(samples)
    }

    func hoverPacket(at point: CGPoint?) -> [Data]? {
        let phase: UInt8 = point == nil ? 3 : 1
        let location = point ?? .zero
        let sample = InkPointerSampleV1(
            pointerID: 0,
            flags: (1 << 0) | (1 << 5),
            deviceKind: 1,
            phase: phase,
            canvasX: Float(location.x),
            canvasY: Float(location.y),
            pressure: 0,
            tiltX: 0,
            tiltY: 0,
            azimuth: 0,
            twist: 0,
            timestampNS: UInt64(max(0, ProcessInfo.processInfo.systemUptime) * 1_000_000_000),
            sequence: nextSequence()
        )
        return InkPointerPacketV1.encode([sample])
    }

    private func sample(_ touch: UITouch, in view: UIView, phase: UInt8, flags: UInt16) -> InkPointerSampleV1 {
        let point = touch.preciseLocation(in: view)
        let maximumForce = max(touch.maximumPossibleForce, 1)
        let timestamp = touch.timestamp.isFinite && touch.timestamp >= 0
            ? min(touch.timestamp, Double(UInt64.max) / 1_000_000_000)
            : 0
        let timestampNS = UInt64(timestamp * 1_000_000_000)
        let azimuth = Double(touch.azimuthAngle(in: view))
        let tiltMagnitude = max(0, Double.pi / 2 - Double(touch.altitudeAngle))
        let roll = if #available(iOS 17.5, *) {
            Double(touch.rollAngle)
        } else {
            0.0
        }
        // Pointer packet v1 stores barrel rotation as a normalized turn so
        // every platform feeds the same response-curve domain.
        let normalizedRoll = (roll / (2 * Double.pi)).truncatingRemainder(dividingBy: 1.0)
        let normalizedRollInRange = normalizedRoll >= 0 ? normalizedRoll : normalizedRoll + 1.0
        return InkPointerSampleV1(
            pointerID: UInt32(truncatingIfNeeded: touch.hash),
            flags: flags,
            deviceKind: 1,
            phase: phase,
            canvasX: Float(point.x),
            canvasY: Float(point.y),
            // The initial contact is buffered until the first measured move.
            // Its pressure is then aligned with the earliest confirmed move
            // sample, avoiding a separate base-size dab before the line. A
            // stationary tap retains its initial contact pressure.
            pressure: phase == 0 ? 0 : Float(touch.force / maximumForce),
            tiltX: Float(tiltMagnitude * cos(azimuth)),
            tiltY: Float(tiltMagnitude * sin(azimuth)),
            azimuth: Float(azimuth),
            twist: Float(normalizedRollInRange),
            timestampNS: timestampNS,
            sequence: nextSequence()
        )
    }

    private func nextSequence() -> UInt32 {
        defer { sequence &+= 1 }
        return sequence
    }
}

/// Holds the first contact sample until a measured Pencil move can supply its
/// pressure, while preserving the original position, timestamp, and sequence.
struct InkPointerContactStartBuffer {
    private var starts: [UInt32: InkPointerSampleV1] = [:]

    mutating func hold(_ sample: InkPointerSampleV1) {
        starts[sample.pointerID] = sample
    }

    mutating func take(
        for pointerID: UInt32,
        usingFirstMeasuredPressure pressure: Float? = nil
    ) -> InkPointerSampleV1? {
        guard let start = starts.removeValue(forKey: pointerID) else { return nil }
        guard let pressure else { return start }
        return InkPointerSampleV1(
            pointerID: start.pointerID,
            flags: start.flags,
            deviceKind: start.deviceKind,
            phase: start.phase,
            canvasX: start.canvasX,
            canvasY: start.canvasY,
            pressure: pressure,
            tiltX: start.tiltX,
            tiltY: start.tiltY,
            azimuth: start.azimuth,
            twist: start.twist,
            timestampNS: start.timestampNS,
            sequence: start.sequence
        )
    }
}
