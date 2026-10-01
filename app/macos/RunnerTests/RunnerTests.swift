import Cocoa
import FlutterMacOS
import XCTest
@testable import project_ink

class RunnerTests: XCTestCase {

  func testPointerPacketBoundsRetainConfirmedSamples() {
    let samples: [InkPointerSampleV1] = (0..<300).map { index in
      let flags: UInt16 = index < 100 ? 1 : (index < 200 ? 1 << 1 : 1 << 2)
      return (
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
      )
    }

    guard let packet = InkPointerPacketV1.encode(samples) else {
      XCTFail("valid samples must encode")
      return
    }
    let version = UInt16(packet[0]) | (UInt16(packet[1]) << 8)
    let count = UInt16(packet[2]) | (UInt16(packet[3]) << 8)
    let firstPointerID = UInt32(packet[4]) |
      (UInt32(packet[5]) << 8) |
      (UInt32(packet[6]) << 16) |
      (UInt32(packet[7]) << 24)
    XCTAssertEqual(version, 1)
    XCTAssertEqual(count, 256)
    XCTAssertEqual(firstPointerID, 0)
  }

  func testPointerPacketRejectsNonFiniteCoordinates() {
    let sample: InkPointerSampleV1 = (
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

}
