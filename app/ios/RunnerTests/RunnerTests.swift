import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  func testPencilContactStartUsesFirstMeasuredMovePressure() {
    var buffer = InkPointerContactStartBuffer()
    buffer.hold(pointerSample(pointerID: 7, phase: 0, pressure: 0, sequence: 11))

    let start = buffer.take(for: 7, usingFirstMeasuredPressure: 0.016)

    XCTAssertEqual(start?.phase, 0)
    XCTAssertEqual(start?.pressure, 0.016)
    XCTAssertEqual(start?.canvasX, 12)
    XCTAssertEqual(start?.canvasY, 34)
    XCTAssertEqual(start?.timestampNS, 99)
    XCTAssertEqual(start?.sequence, 11)
    XCTAssertNil(buffer.take(for: 7))
  }

  func testStationaryPencilContactKeepsItsOriginalPressure() {
    var buffer = InkPointerContactStartBuffer()
    buffer.hold(pointerSample(pointerID: 9, phase: 0, pressure: 0, sequence: 20))

    let start = buffer.take(for: 9)

    XCTAssertEqual(start?.pressure, 0)
    XCTAssertEqual(start?.phase, 0)
  }

  func testPointerPacketBoundsRetainConfirmedSamples() {
    var samples: [InkPointerSampleV1] = []
    for index in 0..<350 {
      // 300 confirmed samples exceed one packet; predictions must not displace
      // any confirmed point when the batch is split.
      let flags: UInt16 = index < 300 ? (index < 100 ? 1 : 1 << 1) : 1 << 2
      samples.append(InkPointerSampleV1(
        pointerID: UInt32(index),
        flags: flags,
        deviceKind: 1,
        phase: 1,
        canvasX: 0,
        canvasY: 0,
        pressure: 1,
        tiltX: 0,
        tiltY: 0,
        azimuth: 0,
        twist: 0,
        timestampNS: UInt64(index),
        sequence: UInt32(index)
      ))
    }

    guard let packets = InkPointerPacketV1.encode(samples) else {
      XCTFail("valid samples must encode")
      return
    }
    XCTAssertEqual(packets.count, 2)
    let decoded = packets.flatMap { packet -> [UInt32] in
      XCTAssertGreaterThanOrEqual(packet.count, 4)
      let version = UInt16(packet[0]) | (UInt16(packet[1]) << 8)
      let count = Int(UInt16(packet[2]) | (UInt16(packet[3]) << 8))
      XCTAssertEqual(version, 1)
      XCTAssertLessThanOrEqual(count, InkPointerPacketV1.maxSamples)
      XCTAssertEqual(packet.count, 4 + count * 48)
      return (0..<count).map { index in
        let offset = 4 + index * 48 + 44
        return UInt32(packet[offset]) |
          (UInt32(packet[offset + 1]) << 8) |
          (UInt32(packet[offset + 2]) << 16) |
          (UInt32(packet[offset + 3]) << 24)
      }
    }
    XCTAssertEqual(decoded, Array(0..<300).map(UInt32.init))
  }

  func testPointerPacketRejectsNonFiniteCoordinates() {
    let sample = InkPointerSampleV1(
      pointerID: 1,
      flags: 1,
      deviceKind: 1,
      phase: 1,
      canvasX: .infinity,
      canvasY: 0,
      pressure: 1,
      tiltX: 0,
      tiltY: 0,
      azimuth: 0,
      twist: 0,
      timestampNS: 0,
      sequence: 0
    )
    XCTAssertNil(InkPointerPacketV1.encode([sample]))
  }

  func testPointerStatusEmitsReadyAfterListenerAttaches() {
    let expectation = expectation(description: "native pointer status ready")
    let status = InkPointerStatusEventStream()
    let error = status.onListen(withArguments: nil) { value in
      if let value = value as? String, value == "ready" {
        expectation.fulfill()
      }
    }

    XCTAssertNil(error)
    wait(for: [expectation], timeout: 1.0)
    XCTAssertNil(status.onCancel(withArguments: nil))
  }

  private func pointerSample(
    pointerID: UInt32,
    phase: UInt8,
    pressure: Float,
    sequence: UInt32
  ) -> InkPointerSampleV1 {
    InkPointerSampleV1(
      pointerID: pointerID,
      flags: 1,
      deviceKind: 1,
      phase: phase,
      canvasX: 12,
      canvasY: 34,
      pressure: pressure,
      tiltX: 0,
      tiltY: 0,
      azimuth: 0,
      twist: 0,
      timestampNS: 99,
      sequence: sequence
    )
  }

}
