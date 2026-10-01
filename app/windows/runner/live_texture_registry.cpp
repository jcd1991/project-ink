// SPDX-License-Identifier: MPL-2.0
#include "live_texture_registry.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <limits>
#include <optional>
#include <string>
#include <variant>
#include <vector>

namespace project_ink {

struct WindowsLiveTextureEntry {
  WindowsLiveTextureEntry(uint32_t width, uint32_t height) : core(width, height) {}
  LiveTextureCore core;
  std::unique_ptr<flutter::TextureVariant> texture;
  std::shared_ptr<std::atomic_size_t> in_flight_frames =
      std::make_shared<std::atomic_size_t>(0);
};

namespace {

using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;

const Value* Find(const Value& value, const char* key) {
  const auto* map = std::get_if<Map>(&value);
  if (map == nullptr) return nullptr;
  const auto found = map->find(Value(key));
  return found == map->end() ? nullptr : &found->second;
}

std::optional<double> Number(const Value* value) {
  if (value == nullptr) return std::nullopt;
  if (const auto* number = std::get_if<double>(value)) return *number;
  if (const auto* number = std::get_if<int32_t>(value)) return *number;
  if (const auto* number = std::get_if<int64_t>(value)) return *number;
  return std::nullopt;
}

bool Integer(const Value* value, int64_t minimum, int64_t maximum, int64_t* out) {
  if (value == nullptr) return false;
  if (const auto* number = std::get_if<int32_t>(value)) {
    if (*number < minimum || *number > maximum) return false;
    *out = *number;
    return true;
  }
  if (const auto* number = std::get_if<int64_t>(value)) {
    if (*number < minimum || *number > maximum) return false;
    *out = *number;
    return true;
  }
  const auto* number = std::get_if<double>(value);
  if (number == nullptr || !std::isfinite(*number) ||
      std::trunc(*number) != *number ||
      static_cast<long double>(*number) < static_cast<long double>(minimum) ||
      static_cast<long double>(*number) > static_cast<long double>(maximum)) {
    return false;
  }
  *out = static_cast<int64_t>(*number);
  return true;
}

bool ReadTextureId(const Value& arguments, int64_t* id) {
  return Integer(Find(arguments, "textureId"), 0,
                 std::numeric_limits<int64_t>::max(), id);
}

struct PixelFrame {
  std::shared_ptr<const std::vector<uint8_t>> pixels;
  std::shared_ptr<std::atomic_size_t> in_flight_frames;
  FlutterDesktopPixelBuffer buffer{};
};

const FlutterDesktopPixelBuffer* CopyPixels(size_t, size_t, void* user_data) {
  const auto* entry =
      static_cast<const std::weak_ptr<WindowsLiveTextureEntry>*>(user_data);
  const auto shared_entry = entry->lock();
  if (!shared_entry) return nullptr;
  const auto in_flight = shared_entry->in_flight_frames;
  if (in_flight->fetch_add(1, std::memory_order_relaxed) >= 3) {
    in_flight->fetch_sub(1, std::memory_order_relaxed);
    return nullptr;
  }
  auto* frame = new PixelFrame{shared_entry->core.Snapshot(), in_flight, {}};
  frame->buffer.buffer = frame->pixels->data();
  frame->buffer.width = shared_entry->core.width();
  frame->buffer.height = shared_entry->core.height();
  frame->buffer.release_callback = [](void* release_context) {
    auto* released_frame = static_cast<PixelFrame*>(release_context);
    released_frame->in_flight_frames->fetch_sub(1, std::memory_order_relaxed);
    delete released_frame;
  };
  frame->buffer.release_context = frame;
  return &frame->buffer;
}

bool ReadMatrix(const Value& arguments, std::array<double, 6>* matrix) {
  const Value* value = Find(arguments, "matrix");
  const auto* list = value == nullptr ? nullptr
                                      : std::get_if<flutter::EncodableList>(value);
  if (list == nullptr || list->size() != matrix->size()) return false;
  for (size_t index = 0; index < matrix->size(); ++index) {
    const auto number = Number(&(*list)[index]);
    if (!number || !std::isfinite(*number) || std::abs(*number) > 1000000.0) {
      return false;
    }
    (*matrix)[index] = *number;
  }
  return true;
}

bool ReadStroke(const Value& arguments, std::array<uint8_t, 16>* stroke) {
  const Value* value = Find(arguments, "strokeId");
  const auto* text = value == nullptr ? nullptr : std::get_if<std::string>(value);
  if (text == nullptr || text->size() != 32) return false;
  const auto nibble = [](char character) -> int {
    if (character >= '0' && character <= '9') return character - '0';
    if (character >= 'a' && character <= 'f') return character - 'a' + 10;
    if (character >= 'A' && character <= 'F') return character - 'A' + 10;
    return -1;
  };
  for (size_t index = 0; index < stroke->size(); ++index) {
    const int high = nibble((*text)[index * 2]);
    const int low = nibble((*text)[index * 2 + 1]);
    if (high < 0 || low < 0) return false;
    // The channel identifier is canonical big-endian hex; v3 dab records
    // carry the Rust u128 little-endian byte representation.
    (*stroke)[stroke->size() - 1 - index] =
        static_cast<uint8_t>((high << 4) | low);
  }
  return true;
}

}  // namespace

WindowsLiveTextureRegistry::WindowsLiveTextureRegistry(
    flutter::BinaryMessenger* messenger,
    flutter::TextureRegistrar* registrar)
    : registrar_(registrar),
      channel_(messenger, "org.projectink.studio/live_texture_v1",
               &flutter::StandardMethodCodec::GetInstance()) {
  channel_.SetMethodCallHandler(
      [this](const auto& call, auto result) { Handle(call, std::move(result)); });
}

WindowsLiveTextureRegistry::~WindowsLiveTextureRegistry() {
  channel_.SetMethodCallHandler(nullptr);
  for (auto& [id, entry] : entries_) {
    registrar_->UnregisterTexture(id, [entry]() {});
  }
  entries_.clear();
}

void WindowsLiveTextureRegistry::Handle(
    const flutter::MethodCall<Value>& call,
    Result result) {
  const Value* arguments = call.arguments();
  if (arguments == nullptr || std::get_if<Map>(arguments) == nullptr) {
    result->Error("invalid_arguments", "Expected a map.");
    return;
  }
  if (call.method_name() == "create") {
    int64_t width = 0;
    int64_t height = 0;
    if (!Integer(Find(*arguments, "width"), 1, LiveTextureCore::kMaxDimension,
                 &width) ||
        !Integer(Find(*arguments, "height"), 1,
                 LiveTextureCore::kMaxDimension, &height) ||
        static_cast<uint64_t>(width) * static_cast<uint64_t>(height) * 4 >
            LiveTextureCore::kMaxSurfaceBytes) {
      result->Error("invalid_surface", "Surface dimensions exceed their bounds.");
      return;
    }
    if (!entries_.empty()) {
      result->Error("surface_busy", "Only one live texture may be active.");
      return;
    }
    auto entry = std::make_shared<WindowsLiveTextureEntry>(
        static_cast<uint32_t>(width), static_cast<uint32_t>(height));
    auto weak_entry = std::make_shared<std::weak_ptr<WindowsLiveTextureEntry>>(entry);
    auto pixel_texture = flutter::PixelBufferTexture(
        [weak_entry](size_t requested_width, size_t requested_height) {
          return CopyPixels(requested_width, requested_height, weak_entry.get());
        });
    entry->texture = std::make_unique<flutter::TextureVariant>(
        std::move(pixel_texture));
    const int64_t id = registrar_->RegisterTexture(entry->texture.get());
    if (id < 0) {
      result->Error("registration_failed", "Flutter could not register texture.");
      return;
    }
    entries_.emplace(id, entry);
    result->Success(Value(Map{{Value("textureId"), Value(id)}}));
    return;
  }

  int64_t id = 0;
  if (!ReadTextureId(*arguments, &id)) {
    result->Error("invalid_argument", "Texture identifier is invalid.");
    return;
  }
  auto entry = FindEntry(*arguments, &result);
  if (!entry) return;
  std::string error;
  if (call.method_name() == "setViewport") {
    std::array<double, 6> matrix{};
    int64_t generation = 0;
    if (!ReadMatrix(*arguments, &matrix) ||
        !Integer(Find(*arguments, "generation"), 0,
                 std::numeric_limits<int64_t>::max(), &generation) ||
        !entry->core.SetViewport(matrix, static_cast<uint64_t>(generation),
                                 &error)) {
      result->Error("invalid_viewport", error.empty() ? "Viewport is invalid." : error);
      return;
    }
  } else if (call.method_name() == "renderDabs") {
    const Value* packet_value = Find(*arguments, "packet");
    const auto* packet = packet_value == nullptr
                             ? nullptr
                             : std::get_if<std::vector<uint8_t>>(packet_value);
    if (packet == nullptr ||
        !entry->core.RenderPacket(packet == nullptr ? nullptr : packet->data(),
                                  packet == nullptr ? 0 : packet->size(), &error)) {
      result->Error("invalid_packet", error.empty() ? "Dab packet is invalid." : error);
      return;
    }
  } else if (call.method_name() == "acknowledge") {
    std::array<uint8_t, 16> stroke{};
    int64_t sequence = 0;
    if (!ReadStroke(*arguments, &stroke) ||
        !Integer(Find(*arguments, "sequence"), 0, 0xffffffffLL, &sequence) ||
        !entry->core.Acknowledge(stroke, static_cast<uint32_t>(sequence),
                                 &error)) {
      result->Error("invalid_acknowledgement",
                    error.empty() ? "Acknowledgement is invalid." : error);
      return;
    }
  } else if (call.method_name() == "cancelAll") {
    entry->core.CancelAll();
  } else if (call.method_name() == "dispose") {
    entries_.erase(id);
    auto shared_result = std::shared_ptr<flutter::MethodResult<Value>>(result.release());
    registrar_->UnregisterTexture(id, [entry, shared_result]() {
      shared_result->Success();
    });
    return;
  } else {
    result->NotImplemented();
    return;
  }
  MarkFrame(id, &result);
}

std::shared_ptr<WindowsLiveTextureEntry>
WindowsLiveTextureRegistry::FindEntry(const Value& arguments,
                                      Result* result) const {
  int64_t id = 0;
  if (!ReadTextureId(arguments, &id)) {
    (*result)->Error("invalid_argument", "Texture identifier is invalid.");
    return nullptr;
  }
  const auto found = entries_.find(id);
  if (found == entries_.end()) {
    (*result)->Error("unknown_texture", "Texture identifier is stale or unknown.");
    return nullptr;
  }
  return found->second;
}

void WindowsLiveTextureRegistry::MarkFrame(int64_t texture_id,
                                           Result* result) const {
  if (!registrar_->MarkTextureFrameAvailable(texture_id)) {
    (*result)->Error("texture_unavailable", "Flutter texture is unavailable.");
    return;
  }
  (*result)->Success();
}

}  // namespace project_ink
