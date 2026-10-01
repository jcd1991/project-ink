// SPDX-License-Identifier: MPL-2.0
import Foundation

struct InkPointerSampleV1 {
    let pointerID: UInt32
    let flags: UInt16
    let deviceKind: UInt8
    let phase: UInt8
    let canvasX: Float
    let canvasY: Float
    let pressure: Float
    let tiltX: Float
    let tiltY: Float
    let azimuth: Float
    let twist: Float
    let timestampNS: UInt64
    let sequence: UInt32
}

enum InkPointerPacketV1 {
    static let maxSamples = 256
    private static let maxCoordinateAbs: Float = 65_536
    private static let predictedFlag: UInt16 = 1 << 2

    static func encode(_ samples: [InkPointerSampleV1]) -> [Data]? {
        guard samples.allSatisfy(valid) else { return nil }
        guard !samples.isEmpty else { return [] }
        let confirmed = samples.filter { $0.flags & predictedFlag == 0 }
        // Confirmed history is part of the authored path. When UIKit returns
        // more than one packet can carry, split it in order instead of
        // subsampling points and making the renderer bridge across a curve.
        // Predictions are disposable and are omitted for this oversized case.
        let packets: [[InkPointerSampleV1]]
        if confirmed.count > maxSamples {
            packets = stride(from: 0, to: confirmed.count, by: maxSamples).map { start in
                Array(confirmed[start..<min(start + maxSamples, confirmed.count)])
            }
        } else if samples.count > maxSamples {
            // Predictions may be dropped to satisfy the packet bound; the
            // confirmed path remains complete.
            packets = confirmed.isEmpty ? [] : [confirmed]
        } else {
            packets = [samples]
        }
        return packets.map(encodePacket)
    }

    private static func encodePacket(_ boundedSamples: [InkPointerSampleV1]) -> Data {
        var data = Data(capacity: 4 + boundedSamples.count * 48)
        append(UInt16(1), to: &data)
        append(UInt16(boundedSamples.count), to: &data)
        for sample in boundedSamples {
            append(sample.pointerID, to: &data)
            append(sample.flags, to: &data)
            data.append(sample.deviceKind)
            data.append(sample.phase)
            append(sample.canvasX.bitPattern, to: &data)
            append(sample.canvasY.bitPattern, to: &data)
            append(sample.pressure.bitPattern, to: &data)
            append(sample.tiltX.bitPattern, to: &data)
            append(sample.tiltY.bitPattern, to: &data)
            append(sample.azimuth.bitPattern, to: &data)
            append(sample.twist.bitPattern, to: &data)
            append(sample.timestampNS, to: &data)
            append(sample.sequence, to: &data)
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

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
