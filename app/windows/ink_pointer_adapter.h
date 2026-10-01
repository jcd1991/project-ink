// SPDX-License-Identifier: MPL-2.0
#pragma once

// Windows Ink/WM_POINTER adapter. This file deliberately contains only input
// normalization and EventChannel plumbing; brush semantics remain in Rust.

#include <windows.h>

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include <flutter/encodable_value.h>
#include <flutter/event_sink.h>
#include <flutter/event_stream_handler.h>

namespace project_ink {

constexpr uint16_t kPointerPacketVersion = 1;
constexpr size_t kPointerSampleBytes = 48;
constexpr uint16_t kPointerFlagActual = 1 << 0;
constexpr uint16_t kPointerFlagEraser = 1 << 3;
constexpr uint16_t kPointerFlagBarrel = 1 << 4;

struct InkPointerSample {
  uint32_t pointer_id = 0;
  uint16_t flags = kPointerFlagActual;
  uint8_t device_kind = 1;
  uint8_t phase = 1;
  float canvas_x = 0;
  float canvas_y = 0;
  float pressure = 0.5f;
  float tilt_x = 0;
  float tilt_y = 0;
  float azimuth = 0;
  float twist = 0;
  uint64_t timestamp_ns = 0;
  uint32_t sequence = 0;
};

class InkPointerStreamHandler final
    : public flutter::StreamHandler<flutter::EncodableValue> {
 public:
  explicit InkPointerStreamHandler(bool readiness) : readiness_(readiness) {}

  InkPointerStreamHandler(const InkPointerStreamHandler&) = delete;
  InkPointerStreamHandler& operator=(const InkPointerStreamHandler&) = delete;

  bool Publish(const std::vector<uint8_t>& packet) {
    if (!sink_) return false;
    sink_->Success(flutter::EncodableValue(packet));
    return true;
  }

  bool PublishSample(const InkPointerSample& sample) {
    std::vector<uint8_t> packet(4 + kPointerSampleBytes, 0);
    WriteU16(packet.data(), kPointerPacketVersion);
    WriteU16(packet.data() + 2, 1);
    auto* output = packet.data() + 4;
    WriteU32(output, sample.pointer_id);
    WriteU16(output + 4, sample.flags);
    output[6] = sample.device_kind;
    output[7] = sample.phase;
    WriteFloat(output + 8, sample.canvas_x);
    WriteFloat(output + 12, sample.canvas_y);
    WriteFloat(output + 16, sample.pressure);
    WriteFloat(output + 20, sample.tilt_x);
    WriteFloat(output + 24, sample.tilt_y);
    WriteFloat(output + 28, sample.azimuth);
    WriteFloat(output + 32, sample.twist);
    WriteU64(output + 36, sample.timestamp_ns);
    WriteU32(output + 44, sample.sequence);
    return Publish(packet);
  }

 protected:
  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
  OnListenInternal(
      const flutter::EncodableValue* /*arguments*/,
      std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events)
      override {
    sink_ = std::move(events);
    if (readiness_ && sink_) {
      sink_->Success(flutter::EncodableValue(std::string("ready")));
    }
    return nullptr;
  }

  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
  OnCancelInternal(const flutter::EncodableValue* /*arguments*/) override {
    sink_.reset();
    return nullptr;
  }

 private:
  static void WriteU16(uint8_t* target, uint16_t value) {
    target[0] = static_cast<uint8_t>(value & 0xff);
    target[1] = static_cast<uint8_t>((value >> 8) & 0xff);
  }
  static void WriteU32(uint8_t* target, uint32_t value) {
    for (int index = 0; index < 4; ++index) {
      target[index] = static_cast<uint8_t>((value >> (index * 8)) & 0xff);
    }
  }
  static void WriteU64(uint8_t* target, uint64_t value) {
    for (int index = 0; index < 8; ++index) {
      target[index] = static_cast<uint8_t>((value >> (index * 8)) & 0xff);
    }
  }
  static void WriteFloat(uint8_t* target, float value) {
    static_assert(sizeof(float) == 4, "pointer packet requires float32");
    std::uint32_t bits = 0;
    std::memcpy(&bits, &value, sizeof(bits));
    WriteU32(target, bits);
  }

  const bool readiness_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink_;
};

// Optional WinTab compatibility path for older tablet drivers. It is loaded
// dynamically, so Windows Ink remains the default and no vendor SDK or import
// library is required at build time. The packet mask is intentionally bounded
// to the fields Project Ink normalizes.
class WinTabFallback final {
 public:
  WinTabFallback() = default;
  WinTabFallback(const WinTabFallback&) = delete;
  WinTabFallback& operator=(const WinTabFallback&) = delete;

  ~WinTabFallback() { Close(); }

  bool Attach(HWND window) {
    if (window == window_ && attempted_) return context_ != nullptr;
    if (window != window_) Close();
    if (attempted_) return context_ != nullptr;
    window_ = window;
    attempted_ = true;
    // Restrict lookup to the system directory; never load a same-named DLL
    // from the project, working, or user-writable directory.
    module_ = LoadLibraryExW(L"wintab32.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (module_ == nullptr) {
      module_ = LoadLibraryExW(L"wintab64.dll", nullptr,
                               LOAD_LIBRARY_SEARCH_SYSTEM32);
    }
    if (module_ == nullptr) return false;

    wt_info_ = Load<WtInfo>("WTInfoW");
    wt_open_ = Load<WtOpen>("WTOpenW");
    wt_close_ = Load<WtClose>("WTClose");
    wt_packet_ = Load<WtPacket>("WTPacket");
    if (wt_info_ == nullptr || wt_open_ == nullptr || wt_close_ == nullptr ||
        wt_packet_ == nullptr) {
      Unload();
      return false;
    }

    LogContext context{};
    if (wt_info_(kWtiDefSysCtx, 0, &context) == 0) {
      Unload();
      return false;
    }
    context.lcOptions |= kCxoMessages;
    context.lcMsgBase = kWtDefBase;
    context.lcPktData = kPkStatus | kPkTime | kPkButtons | kPkX | kPkY |
                        kPkNormalPressure | kPkOrientation;
    context.lcPktMode = 0;
    context_ = wt_open_(window_, &context, TRUE);
    if (context_ == nullptr) {
      Unload();
      return false;
    }

    pressure_min_ = 0;
    pressure_max_ = 65535;
    Axis pressure_axis{};
    if (wt_info_(kWtiDevices, kDvcNPressure, &pressure_axis) != 0 &&
        pressure_axis.axMax > pressure_axis.axMin) {
      pressure_min_ = pressure_axis.axMin;
      pressure_max_ = pressure_axis.axMax;
    }
    return true;
  }

  bool HandleMessage(HWND window, UINT message, WPARAM wparam,
                     LPARAM lparam) {
    if (message == WM_DESTROY || message == WM_NCDESTROY) {
      Close();
      return false;
    }
    if (message != kWtPacket || context_ == nullptr ||
        reinterpret_cast<Hctx>(lparam) != context_ || wt_packet_ == nullptr) {
      return false;
    }

    Packet packet{};
    if (!wt_packet_(context_, static_cast<UINT>(wparam), &packet)) {
      return false;
    }
    POINT point{packet.pkX, packet.pkY};
    ScreenToClient(window, &point);

    InkPointerSample sample;
    sample.pointer_id = 0x80000000u;
    sample.canvas_x = static_cast<float>(point.x);
    sample.canvas_y = static_cast<float>(point.y);
    const LONG bounded_pressure = std::clamp(
        static_cast<LONG>(packet.pkNormalPressure), pressure_min_,
        pressure_max_);
    sample.pressure = static_cast<float>(bounded_pressure - pressure_min_) /
                      static_cast<float>(pressure_max_ - pressure_min_);
    sample.pressure = std::clamp(sample.pressure, 0.0f, 1.0f);
    sample.tilt_x = static_cast<float>(packet.pkOrientation.orAzimuth) /
                    180.0f;
    sample.tilt_y = static_cast<float>(packet.pkOrientation.orAltitude) /
                    90.0f;
    sample.timestamp_ns = static_cast<uint64_t>(packet.pkTime) * 1000000ULL;
    sample.sequence = sequence_++;
    if ((packet.pkStatus & kTpsInvert) != 0) sample.flags |= kPointerFlagEraser;

    const bool in_contact = packet.pkButtons != 0;
    sample.phase = in_contact ? (in_contact_ ? 1 : 0) : (in_contact_ ? 2 : 1);
    in_contact_ = in_contact;
    return stream_ != nullptr && stream_->PublishSample(sample);
  }

  void SetStream(InkPointerStreamHandler* stream) { stream_ = stream; }
  void Disable() { Close(); }

 private:
  using Hctx = HANDLE;

  struct Axis {
    LONG axMin;
    LONG axMax;
    UINT axUnits;
    DWORD axResolution;
  };

  struct Orientation {
    int orAzimuth;
    int orAltitude;
    int orTwist;
  };

  struct LogContext {
    WCHAR lcName[40];
    UINT lcOptions;
    UINT lcStatus;
    UINT lcLocks;
    UINT lcMsgBase;
    UINT lcDevice;
    UINT lcPktRate;
    DWORD lcPktData;
    DWORD lcPktMode;
    DWORD lcMoveMask;
    DWORD lcBtnDnMask;
    DWORD lcBtnUpMask;
    LONG lcInOrgX;
    LONG lcInOrgY;
    LONG lcInOrgZ;
    LONG lcInExtX;
    LONG lcInExtY;
    LONG lcInExtZ;
    LONG lcOutOrgX;
    LONG lcOutOrgY;
    LONG lcOutOrgZ;
    LONG lcOutExtX;
    LONG lcOutExtY;
    LONG lcOutExtZ;
    DWORD lcSensX;
    DWORD lcSensY;
    DWORD lcSensZ;
    BOOL lcSysMode;
    int lcSysOrgX;
    int lcSysOrgY;
    int lcSysExtX;
    int lcSysExtY;
    DWORD lcSysSensX;
    DWORD lcSysSensY;
  };

  // Fields follow the ascending packet-mask order requested above.
  struct Packet {
    int pkStatus;
    DWORD pkTime;
    UINT pkButtons;
    LONG pkX;
    LONG pkY;
    int pkNormalPressure;
    Orientation pkOrientation;
  };

  using WtInfo = UINT(WINAPI*)(UINT, UINT, LPVOID);
  using WtOpen = Hctx(WINAPI*)(HWND, LogContext*, BOOL);
  using WtClose = BOOL(WINAPI*)(Hctx);
  using WtPacket = BOOL(WINAPI*)(Hctx, UINT, LPVOID);

  template <typename Function>
  Function Load(const char* name) {
    const FARPROC symbol = GetProcAddress(module_, name);
    Function function = nullptr;
    static_assert(sizeof(function) == sizeof(symbol),
                  "WinTab function pointers must match FARPROC size");
    std::memcpy(&function, &symbol, sizeof(function));
    return function;
  }

  void Close() {
    Unload();
    attempted_ = false;
    window_ = nullptr;
  }

  void Unload() {
    if (context_ != nullptr && wt_close_ != nullptr) wt_close_(context_);
    context_ = nullptr;
    wt_info_ = nullptr;
    wt_open_ = nullptr;
    wt_close_ = nullptr;
    wt_packet_ = nullptr;
    if (module_ != nullptr) FreeLibrary(module_);
    module_ = nullptr;
    in_contact_ = false;
  }

  static constexpr UINT kWtDefBase = 0x7FF0;
  static constexpr UINT kWtPacket = kWtDefBase;
  static constexpr UINT kWtiDefSysCtx = 4;
  static constexpr UINT kWtiDevices = 100;
  static constexpr UINT kDvcNPressure = 15;
  static constexpr UINT kCxoMessages = 0x0004;
  static constexpr DWORD kPkStatus = 0x0002;
  static constexpr DWORD kPkTime = 0x0004;
  static constexpr DWORD kPkButtons = 0x0040;
  static constexpr DWORD kPkX = 0x0080;
  static constexpr DWORD kPkY = 0x0100;
  static constexpr DWORD kPkNormalPressure = 0x0400;
  static constexpr DWORD kPkOrientation = 0x1000;
  static constexpr int kTpsInvert = 0x0010;

  HMODULE module_ = nullptr;
  Hctx context_ = nullptr;
  HWND window_ = nullptr;
  bool attempted_ = false;
  WtInfo wt_info_ = nullptr;
  WtOpen wt_open_ = nullptr;
  WtClose wt_close_ = nullptr;
  WtPacket wt_packet_ = nullptr;
  InkPointerStreamHandler* stream_ = nullptr;
  LONG pressure_min_ = 0;
  LONG pressure_max_ = 65535;
  bool in_contact_ = false;
  uint32_t sequence_ = 0;
};

class InkPointerAdapter final {
 public:
  explicit InkPointerAdapter(InkPointerStreamHandler* stream)
      : stream_(stream) {
    wintab_.SetStream(stream_);
  }

  bool HandleMessage(HWND window, UINT message, WPARAM wparam,
                     LPARAM lparam) {
    if (message == WM_DESTROY || message == WM_NCDESTROY) {
      wintab_.HandleMessage(window, message, wparam, lparam);
      return false;
    }
    if (windows_ink_active_ && message != WM_POINTERDOWN &&
        message != WM_POINTERUPDATE && message != WM_POINTERUP &&
        message != WM_POINTERCANCEL) {
      return false;
    }
    const uint32_t pointer_id = GET_POINTERID_WPARAM(wparam);
    if (message != WM_POINTERDOWN && message != WM_POINTERUPDATE &&
        message != WM_POINTERUP && message != WM_POINTERCANCEL) {
      return wintab_.Attach(window) &&
             wintab_.HandleMessage(window, message, wparam, lparam);
    }
    POINTER_INFO info{};
    if (!GetPointerInfo(pointer_id, &info) || info.pointerType != PT_PEN) {
      return wintab_.Attach(window) &&
             wintab_.HandleMessage(window, message, wparam, lparam);
    }
    POINTER_PEN_INFO pen{};
    if (!GetPointerPenInfo(pointer_id, &pen)) {
      return wintab_.Attach(window) &&
             wintab_.HandleMessage(window, message, wparam, lparam);
    }

    InkPointerSample sample;
    sample.pointer_id = pointer_id;
    sample.phase = message == WM_POINTERDOWN
                       ? 0
                       : message == WM_POINTERUP
                           ? 2
                           : message == WM_POINTERCANCEL ? 3 : 1;
    sample.pressure = static_cast<float>(pen.pressure) / 1024.0f;
    sample.tilt_x = static_cast<float>(pen.tiltX) / 90.0f;
    sample.tilt_y = static_cast<float>(pen.tiltY) / 90.0f;
    sample.twist = static_cast<float>(pen.rotation) / 360.0f;
    if ((pen.penFlags & PEN_FLAG_ERASER) != 0) sample.flags |= kPointerFlagEraser;
    if ((pen.penFlags & PEN_FLAG_BARREL) != 0) sample.flags |= kPointerFlagBarrel;
    POINT client_point = info.ptPixelLocation;
    ScreenToClient(window, &client_point);
    sample.canvas_x = static_cast<float>(client_point.x);
    sample.canvas_y = static_cast<float>(client_point.y);
    sample.timestamp_ns = static_cast<uint64_t>(info.dwTime) * 1000000ULL;
    sample.sequence = sequence_++;

    const bool published = stream_ != nullptr && stream_->PublishSample(sample);
    if (published && !windows_ink_active_) wintab_.Disable();
    if (published) windows_ink_active_ = true;
    return published;
  }

 private:

  InkPointerStreamHandler* stream_;
  WinTabFallback wintab_;
  bool windows_ink_active_ = false;
  uint32_t sequence_ = 0;
};

}  // namespace project_ink
