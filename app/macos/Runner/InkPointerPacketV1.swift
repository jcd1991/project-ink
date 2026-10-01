// SPDX-License-Identifier: MPL-2.0
import Foundation

typealias InkPointerSampleV1 = (pointerID: UInt32, flags: UInt16, deviceKind: UInt8, phase: UInt8, canvasX: Float, canvasY: Float, pressure: Float, tiltX: Float, tiltY: Float, azimuth: Float, twist: Float, timestampNS: UInt64, sequence: UInt32)

enum InkPointerPacketV1 {
    static let maxSamples = 256
    private static let maxCoordinateAbs: Float = 65_536
    private static let coalescedFlag: UInt16 = 1 << 1
    private static let predictedFlag: UInt16 = 1 << 2

    static func encode(_ samples: [InkPointerSampleV1]) -> Data? {
        guard samples.allSatisfy(valid) else { return nil }
        let boundedSamples = bound(samples)
        var data = Data(capacity: 4 + boundedSamples.count * 48)
        append(UInt16(1), to: &data)
        append(UInt16(boundedSamples.count), to: &data)
        for sample in boundedSamples {
            append(sample.pointerID, to: &data); append(sample.flags, to: &data)
            data.append(sample.deviceKind); data.append(sample.phase)
            append(sample.canvasX.bitPattern, to: &data); append(sample.canvasY.bitPattern, to: &data); append(sample.pressure.bitPattern, to: &data)
            append(sample.tiltX.bitPattern, to: &data); append(sample.tiltY.bitPattern, to: &data); append(sample.azimuth.bitPattern, to: &data); append(sample.twist.bitPattern, to: &data)
            append(sample.timestampNS, to: &data); append(sample.sequence, to: &data)
        }
        return data
    }

    private static func valid(_ sample: InkPointerSampleV1) -> Bool {
        let values = [
            sample.canvasX,
            sample.canvasY,
            sample.pressure,
            sample.tiltX,
            sample.tiltY,
            sample.azimuth,
            sample.twist,
        ]
        return values.allSatisfy { $0.isFinite } &&
            abs(sample.canvasX) <= maxCoordinateAbs &&
            abs(sample.canvasY) <= maxCoordinateAbs
    }

    private static func bound(_ samples: [InkPointerSampleV1]) -> [InkPointerSampleV1] {
        guard samples.count > maxSamples else { return samples }
        let selected = samples.enumerated()
            .sorted { left, right in
                let leftPriority = priority(left.element.flags)
                let rightPriority = priority(right.element.flags)
                if leftPriority == rightPriority { return left.offset < right.offset }
                return leftPriority < rightPriority
            }
            .prefix(maxSamples)
            .map(\.offset)
        let selectedOffsets = Set(selected)
        return samples.enumerated()
            .filter { selectedOffsets.contains($0.offset) }
            .map(\.element)
    }

    private static func priority(_ flags: UInt16) -> Int {
        if flags & predictedFlag != 0 { return 2 }
        if flags & coalescedFlag != 0 { return 1 }
        return 0
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
