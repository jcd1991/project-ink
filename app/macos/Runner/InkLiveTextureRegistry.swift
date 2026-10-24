import CoreVideo
import FlutterMacOS
import IOSurface
import Metal

/// Owns the Flutter texture registration and the CoreVideo storage that backs
/// the macOS live-stroke surface. Pixel data is shared through IOSurface; no
/// CPU readback or pixel copy is performed.
final class InkLiveTextureRegistry {
  private let registry: FlutterTextureRegistry
  private var textures: [Int64: InkLiveTexture] = [:]

  init(registry: FlutterTextureRegistry) {
    self.registry = registry
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let arguments = call.arguments as? [String: Any] else {
      result(FlutterError(code: "invalid_arguments", message: "Expected a map.", details: nil))
      return
    }

    do {
      switch call.method {
      case "create":
        let deviceHandle = try positiveInt64(arguments, key: "deviceHandle")
        let width = try boundedDimension(arguments, key: "width")
        let height = try boundedDimension(arguments, key: "height")
        let byteCount = UInt64(width) * UInt64(height) * 4
        guard byteCount <= 256 * 1024 * 1024 else {
          throw TextureRegistryError.invalidSurface("Surface exceeds the 256 MiB limit.")
        }
        guard textures.isEmpty else {
          throw TextureRegistryError.invalidSurface(
            "A live surface already occupies this window."
          )
        }
        let texture = try InkLiveTexture(
          deviceHandle: deviceHandle,
          width: width,
          height: height
        )
        let textureId = registry.register(texture)
        guard textureId >= 0 else {
          throw TextureRegistryError.registrationFailed
        }
        textures[textureId] = texture
        result(["textureId": textureId])

      case "takeMetalTextureHandle":
        let textureId = try nonnegativeInt64(arguments, key: "textureId")
        guard let texture = textures[textureId] else {
          throw TextureRegistryError.unknownTexture
        }
        result(texture.takeRetainedMetalTextureHandle())

      case "frameAvailable":
        let textureId = try nonnegativeInt64(arguments, key: "textureId")
        guard textures[textureId] != nil else {
          throw TextureRegistryError.unknownTexture
        }
        registry.textureFrameAvailable(textureId)
        result(nil)

#if DEBUG
      case "debugCopyPixelBufferCount":
        let textureId = try nonnegativeInt64(arguments, key: "textureId")
        guard let texture = textures[textureId] else {
          throw TextureRegistryError.unknownTexture
        }
        result(texture.copyPixelBufferCount)
#endif

#if DEBUG
      case "debugTextureLifecycleState":
        let textureId = try nonnegativeInt64(arguments, key: "textureId")
        let texture = textures[textureId]
        result([
          "phase": texture != nil ? "active" : "released",
          "copyPixelBufferCount": texture?.copyPixelBufferCount ?? 0,
          "hasUnregisterSelector": texture?.responds(
            to: NSSelectorFromString("onTextureUnregistered:")
          ) ?? true,
          "receivedUnregisterCallback": texture?.receivedUnregisterCallback ?? false,
          "requiresUnregisterCallback": false,
        ])
#endif

      case "dispose":
        let textureId = try nonnegativeInt64(arguments, key: "textureId")
        guard let texture = textures[textureId] else {
          result(nil)
          return
        }
        registry.unregisterTexture(textureId)
        // Flutter 3.47.5's macOS registrar removes its strong external-texture
        // wrapper on unregister; its Metal embedder does not forward the
        // optional onTextureUnregistered callback. Waiting for that callback
        // here retains a buffer forever and prevents every later resize.
        // In-flight wrapper calls retain the texture, and copyPixelBuffer
        // transfers a separate +1 buffer reference to Flutter. Rust has
        // already detached/disposed its surface before this channel call.
        // Keep our owner through unregister, then release it normally.
        withExtendedLifetime(texture) {
          _ = textures.removeValue(forKey: textureId)
        }
        result(nil)

      default:
        result(FlutterMethodNotImplemented)
      }
    } catch let error as TextureRegistryError {
      result(FlutterError(code: error.code, message: error.message, details: nil))
    } catch {
      result(FlutterError(code: "live_texture_failed", message: error.localizedDescription, details: nil))
    }
  }

  private func positiveInt64(_ values: [String: Any], key: String) throws -> Int64 {
    guard let number = values[key] as? NSNumber else {
      throw TextureRegistryError.invalidArgument(key)
    }
    let value = number.int64Value
    guard value > 0 else {
      throw TextureRegistryError.invalidArgument(key)
    }
    return value
  }

  private func nonnegativeInt64(_ values: [String: Any], key: String) throws -> Int64 {
    guard let number = values[key] as? NSNumber else {
      throw TextureRegistryError.invalidArgument(key)
    }
    let value = number.int64Value
    guard value >= 0 else {
      throw TextureRegistryError.invalidArgument(key)
    }
    return value
  }

  private func boundedDimension(_ values: [String: Any], key: String) throws -> Int {
    guard let number = values[key] as? NSNumber else {
      throw TextureRegistryError.invalidArgument(key)
    }
    let value = number.intValue
    guard number.doubleValue == Double(value), (1...8192).contains(value) else {
      throw TextureRegistryError.invalidArgument(key)
    }
    return value
  }
}

private final class InkLiveTexture: NSObject, FlutterTexture {
  private let pixelBuffer: CVPixelBuffer
  private let metalTexture: MTLTexture
#if DEBUG
  private let copyCountLock = NSLock()
  private var recordedCopyPixelBufferCount = 0
  private var didReceiveUnregisterCallback = false
#endif

#if DEBUG
  var copyPixelBufferCount: Int {
    copyCountLock.lock()
    defer { copyCountLock.unlock() }
    return recordedCopyPixelBufferCount
  }

  var receivedUnregisterCallback: Bool {
    copyCountLock.lock()
    defer { copyCountLock.unlock() }
    return didReceiveUnregisterCallback
  }
#endif

  init(deviceHandle: Int64, width: Int, height: Int) throws {
    guard let devicePointer = UnsafeRawPointer(bitPattern: UInt(deviceHandle)) else {
      throw TextureRegistryError.invalidDevice
    }
    let unmanagedDevice = Unmanaged<AnyObject>.fromOpaque(devicePointer)
    guard let device = unmanagedDevice.takeUnretainedValue() as? MTLDevice else {
      throw TextureRegistryError.invalidDevice
    }

    let attributes: [String: Any] = [
      kCVPixelBufferMetalCompatibilityKey as String: true,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ]
    var createdBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      width,
      height,
      kCVPixelFormatType_32BGRA,
      attributes as CFDictionary,
      &createdBuffer
    )
    guard status == kCVReturnSuccess, let createdBuffer else {
      throw TextureRegistryError.pixelBufferCreationFailed(status)
    }
    guard let surface = CVPixelBufferGetIOSurface(createdBuffer)?.takeUnretainedValue() else {
      throw TextureRegistryError.missingIOSurface
    }

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm,
      width: width,
      height: height,
      mipmapped: false
    )
    descriptor.storageMode = .shared
    descriptor.usage = [.renderTarget, .shaderRead]
    guard let texture = device.makeTexture(
      descriptor: descriptor,
      iosurface: surface,
      plane: 0
    ) else {
      throw TextureRegistryError.metalTextureCreationFailed
    }

    self.pixelBuffer = createdBuffer
    self.metalTexture = texture
    super.init()
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    // `copyPixelBuffer` is in Objective-C's Copy method family, so Flutter
    // consumes a +1 CoreVideo reference from each callback. Returning an
    // unretained value lets the renderer release our stored buffer and leaves
    // a dangling `pixelBuffer` ivar for the next raster frame.
#if DEBUG
    copyCountLock.lock()
    recordedCopyPixelBufferCount += 1
    copyCountLock.unlock()
#endif
    return Unmanaged.passRetained(pixelBuffer)
  }

  /// Transfers a +1 reference to wgpu exactly once per request. Flutter keeps
  /// its own texture and pixel-buffer ownership until `dispose` unregisters it.
  func takeRetainedMetalTextureHandle() -> Int64 {
    let pointer = Unmanaged.passRetained(metalTexture as AnyObject).toOpaque()
    return Int64(bitPattern: UInt64(UInt(bitPattern: pointer)))
  }

  func onTextureUnregistered(_ texture: FlutterTexture) {
#if DEBUG
    copyCountLock.lock()
    didReceiveUnregisterCallback = true
    copyCountLock.unlock()
#endif
  }
}

private enum TextureRegistryError: LocalizedError {
  case invalidArgument(String)
  case invalidDevice
  case invalidSurface(String)
  case registrationFailed
  case unknownTexture
  case pixelBufferCreationFailed(CVReturn)
  case missingIOSurface
  case metalTextureCreationFailed

  var code: String {
    switch self {
    case .invalidArgument: return "invalid_argument"
    case .invalidDevice: return "invalid_device"
    case .invalidSurface: return "invalid_surface"
    case .registrationFailed: return "registration_failed"
    case .unknownTexture: return "unknown_texture"
    case .pixelBufferCreationFailed: return "pixel_buffer_creation_failed"
    case .missingIOSurface: return "missing_iosurface"
    case .metalTextureCreationFailed: return "metal_texture_creation_failed"
    }
  }

  var message: String { errorDescription ?? "The live texture operation failed." }

  var errorDescription: String? {
    switch self {
    case .invalidArgument(let key): return "Invalid or missing \(key)."
    case .invalidDevice: return "The renderer supplied an invalid Metal device."
    case .invalidSurface(let reason): return reason
    case .registrationFailed: return "Flutter could not register the live texture."
    case .unknownTexture: return "The live texture identifier is stale or unknown."
    case .pixelBufferCreationFailed(let status): return "CoreVideo failed to create a pixel buffer (\(status))."
    case .missingIOSurface: return "CoreVideo did not create an IOSurface-backed pixel buffer."
    case .metalTextureCreationFailed: return "Metal could not create a texture for the IOSurface."
    }
  }
}
