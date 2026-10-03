// SPDX-License-Identifier: MPL-2.0
import UIKit

/// Converts high-fidelity Pencil touches into the platform-neutral packet.
final class InkPointerAdapter {
    private var sequence: UInt32 = 0

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
                for candidate in coalesced.dropLast() {
                    samples.append(sample(candidate, in: view, phase: phase, flags: 1 << 1))
                }
            }
            samples.append(sample(touch, in: view, phase: phase, flags: 1))
            guard phase == 1 else { continue }
            let predicted = event?.predictedTouches(for: touch) ?? []
            for candidate in predicted {
                samples.append(sample(candidate, in: view, phase: phase, flags: 1 << 2))
            }
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
            // UIKit can provide an estimated force on initial contact. Start
            // the first dab at minimum width; later move/estimate samples
            // carry the measured force so an optimistic estimate cannot make
            // a fat isolated dot before the line begins.
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
