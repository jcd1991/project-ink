import Cocoa
import CoreVideo
import FlutterMacOS
import Metal
import XCTest
@testable import project_ink

class RunnerTests: XCTestCase {

  func testLiveTextureReplacementWithoutUnregisterCallback() throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("A Metal device is required for the native texture lifecycle.")
    }
    let devicePointer = Unmanaged.passUnretained(device as AnyObject).toOpaque()
    let deviceHandle = Int64(bitPattern: UInt64(UInt(bitPattern: devicePointer)))
    let flutter = TextureRegistryWithoutRetirementCallback()
    let owner = InkLiveTextureRegistry(registry: flutter)

    for width in [64, 96, 128] {
      var created: Any?
      owner.handle(FlutterMethodCall(methodName: "create", arguments: [
        "deviceHandle": deviceHandle, "width": width, "height": 64,
      ])) { created = $0 }
      let response = try XCTUnwrap(created as? [String: Int64])
      let textureID = try XCTUnwrap(response["textureId"])
      // Model a raster consumer keeping its +1 buffer reference across native
      // unregistration. The fake deliberately never invokes the optional
      // callback, matching Flutter 3.47.5's macOS Metal embedder.
      let buffer = try XCTUnwrap(flutter.textures[textureID]?.copyPixelBuffer()?.takeRetainedValue())
      var disposalError: FlutterError?
      owner.handle(FlutterMethodCall(methodName: "dispose", arguments: [
        "textureId": textureID,
      ])) { disposalError = $0 as? FlutterError }
      XCTAssertNil(disposalError)
      XCTAssertTrue(flutter.textures.isEmpty)
      XCTAssertEqual(CVPixelBufferGetWidth(buffer), width)
      XCTAssertEqual(CVPixelBufferGetHeight(buffer), 64)
    }
  }

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

private final class TextureRegistryWithoutRetirementCallback: NSObject, FlutterTextureRegistry {
  var textures: [Int64: FlutterTexture] = [:]
  private var nextID: Int64 = 1

  func register(_ texture: FlutterTexture) -> Int64 {
    let id = nextID
    nextID += 1
    textures[id] = texture
    return id
  }

  func textureFrameAvailable(_ textureId: Int64) {}

  func unregisterTexture(_ textureId: Int64) {
    textures.removeValue(forKey: textureId)
  }
}
