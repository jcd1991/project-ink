// SPDX-License-Identifier: MPL-2.0
#include "live_texture_registry.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "../../native/live_texture_core.h"

namespace {

struct TextureState {
  std::shared_ptr<project_ink::LiveTextureCore> core;
  std::mutex mutex;
  std::deque<std::shared_ptr<const std::vector<uint8_t>>> frames;
};

typedef struct _InkLivePixelTexture {
  FlPixelBufferTexture parent_instance;
  TextureState* state;
} InkLivePixelTexture;

typedef struct _InkLivePixelTextureClass {
  FlPixelBufferTextureClass parent_class;
} InkLivePixelTextureClass;

G_DEFINE_TYPE(InkLivePixelTexture,
              ink_live_pixel_texture,
              fl_pixel_buffer_texture_get_type())

gboolean CopyPixels(FlPixelBufferTexture* texture,
                    const uint8_t** buffer,
                    uint32_t* width,
                    uint32_t* height,
                    GError**) {
  auto* self = reinterpret_cast<InkLivePixelTexture*>(texture);
  if (self->state == nullptr || self->state->core == nullptr) return FALSE;
  auto snapshot = self->state->core->Snapshot();
  {
    std::lock_guard<std::mutex> lock(self->state->mutex);
    self->state->frames.push_back(std::move(snapshot));
    // Linux's pixel-buffer contract requires storage to survive beyond the
    // callback. Three retained frames stay within the desktop texture budget.
    while (self->state->frames.size() > 3) {
      self->state->frames.pop_front();
    }
    const auto& frame = self->state->frames.back();
    *buffer = frame->data();
    *width = self->state->core->width();
    *height = self->state->core->height();
  }
  return TRUE;
}

void Finalize(GObject* object) {
  auto* self = reinterpret_cast<InkLivePixelTexture*>(object);
  delete self->state;
  self->state = nullptr;
  G_OBJECT_CLASS(ink_live_pixel_texture_parent_class)->finalize(object);
}

void ink_live_pixel_texture_class_init(InkLivePixelTextureClass* klass) {
  FL_PIXEL_BUFFER_TEXTURE_CLASS(klass)->copy_pixels = CopyPixels;
  G_OBJECT_CLASS(klass)->finalize = Finalize;
}

void ink_live_pixel_texture_init(InkLivePixelTexture* self) {
  self->state = new TextureState();
}

FlValue* Lookup(FlValue* map, const char* key) {
  if (map == nullptr || fl_value_get_type(map) != FL_VALUE_TYPE_MAP) return nullptr;
  return fl_value_lookup_string(map, key);
}

bool ReadInteger(FlValue* value, int64_t minimum, int64_t maximum,
                 int64_t* result) {
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_INT) return false;
  const int64_t number = fl_value_get_int(value);
  if (number < minimum || number > maximum) return false;
  *result = number;
  return true;
}

bool ReadNumber(FlValue* value, double* result) {
  if (value == nullptr) return false;
  const auto type = fl_value_get_type(value);
  if (type == FL_VALUE_TYPE_INT) {
    *result = static_cast<double>(fl_value_get_int(value));
  } else if (type == FL_VALUE_TYPE_FLOAT) {
    *result = fl_value_get_float(value);
  } else {
    return false;
  }
  return std::isfinite(*result);
}

bool ReadStroke(FlValue* value, std::array<uint8_t, 16>* stroke) {
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_STRING) return false;
  const std::string text = fl_value_get_string(value);
  if (text.size() != 32) return false;
  auto nibble = [](char value) -> int {
    if (value >= '0' && value <= '9') return value - '0';
    if (value >= 'a' && value <= 'f') return value - 'a' + 10;
    if (value >= 'A' && value <= 'F') return value - 'A' + 10;
    return -1;
  };
  for (size_t index = 0; index < stroke->size(); ++index) {
    const int high = nibble(text[index * 2]);
    const int low = nibble(text[index * 2 + 1]);
    if (high < 0 || low < 0) return false;
    (*stroke)[stroke->size() - 1 - index] =
        static_cast<uint8_t>((high << 4) | low);
  }
  return true;
}

void RespondError(FlMethodCall* call, const char* code, const std::string& message) {
  fl_method_call_respond_error(call, code, message.c_str(), nullptr, nullptr);
}

void RespondSuccess(FlMethodCall* call, FlValue* value = nullptr) {
  fl_method_call_respond_success(call, value, nullptr);
}

}  // namespace

namespace project_ink {

struct LinuxLiveTextureRegistry::Entry {
  InkLivePixelTexture* texture = nullptr;
  std::shared_ptr<LiveTextureCore> core;
};

LinuxLiveTextureRegistry::LinuxLiveTextureRegistry(
    FlBinaryMessenger* messenger,
    FlTextureRegistrar* registrar)
    : registrar_(registrar) {
  FlStandardMethodCodec* codec = fl_standard_method_codec_new();
  channel_ = fl_method_channel_new(
      messenger, "org.projectink.studio/live_texture_v1",
      FL_METHOD_CODEC(codec));
  g_object_unref(codec);
  fl_method_channel_set_method_call_handler(channel_, HandleMethodCall, this,
                                             nullptr);
}

LinuxLiveTextureRegistry::~LinuxLiveTextureRegistry() {
  fl_method_channel_set_method_call_handler(channel_, nullptr, nullptr, nullptr);
  for (auto& [id, entry] : entries_) {
    fl_texture_registrar_unregister_texture(
        registrar_, FL_TEXTURE(entry->texture));
    g_object_unref(entry->texture);
  }
  entries_.clear();
  g_object_unref(channel_);
}

void LinuxLiveTextureRegistry::HandleMethodCall(FlMethodChannel*,
                                               FlMethodCall* call,
                                               gpointer user_data) {
  static_cast<LinuxLiveTextureRegistry*>(user_data)->Handle(call);
}

void LinuxLiveTextureRegistry::Handle(FlMethodCall* call) {
  const gchar* method = fl_method_call_get_name(call);
  FlValue* arguments = fl_method_call_get_args(call);
  if (arguments == nullptr || fl_value_get_type(arguments) != FL_VALUE_TYPE_MAP) {
    RespondError(call, "invalid_arguments", "Expected a map.");
    return;
  }
  if (g_strcmp0(method, "create") == 0) {
    int64_t width = 0;
    int64_t height = 0;
    if (!ReadInteger(Lookup(arguments, "width"), 1,
                     LiveTextureCore::kMaxDimension, &width) ||
        !ReadInteger(Lookup(arguments, "height"), 1,
                     LiveTextureCore::kMaxDimension, &height) ||
        static_cast<uint64_t>(width) * static_cast<uint64_t>(height) * 4 >
            LiveTextureCore::kMaxSurfaceBytes) {
      RespondError(call, "invalid_surface", "Surface dimensions exceed their bounds.");
      return;
    }
    if (!entries_.empty()) {
      RespondError(call, "surface_busy", "Only one live texture may be active.");
      return;
    }
    auto entry = std::make_unique<Entry>();
    entry->core = std::make_shared<LiveTextureCore>(
        static_cast<uint32_t>(width), static_cast<uint32_t>(height));
    entry->texture = reinterpret_cast<InkLivePixelTexture*>(
        g_object_new(ink_live_pixel_texture_get_type(), nullptr));
    entry->texture->state->core = entry->core;
    if (!fl_texture_registrar_register_texture(registrar_,
                                               FL_TEXTURE(entry->texture))) {
      g_object_unref(entry->texture);
      RespondError(call, "registration_failed", "Flutter could not register texture.");
      return;
    }
    const int64_t id = fl_texture_get_id(FL_TEXTURE(entry->texture));
    entries_.emplace(id, std::move(entry));
    FlValue* result = fl_value_new_map();
    fl_value_set_string_take(result, "textureId", fl_value_new_int(id));
    RespondSuccess(call, result);
    fl_value_unref(result);
    return;
  }

  int64_t texture_id = 0;
  if (!ReadInteger(Lookup(arguments, "textureId"), 0, G_MAXINT64,
                   &texture_id)) {
    RespondError(call, "invalid_argument", "Texture identifier is invalid.");
    return;
  }
  const auto found = entries_.find(texture_id);
  if (found == entries_.end()) {
    RespondError(call, "unknown_texture", "Texture identifier is stale or unknown.");
    return;
  }
  Entry& entry = *found->second;
  std::string error;
  if (g_strcmp0(method, "setViewport") == 0) {
    FlValue* values = Lookup(arguments, "matrix");
    int64_t generation = 0;
    if (values == nullptr || fl_value_get_type(values) != FL_VALUE_TYPE_LIST ||
        fl_value_get_length(values) != 6 ||
        !ReadInteger(Lookup(arguments, "generation"), 0, G_MAXINT64,
                     &generation)) {
      RespondError(call, "invalid_viewport", "Viewport matrix is invalid.");
      return;
    }
    std::array<double, 6> matrix{};
    for (size_t index = 0; index < matrix.size(); ++index) {
      if (!ReadNumber(fl_value_get_list_value(values, index), &matrix[index])) {
        RespondError(call, "invalid_viewport", "Viewport matrix is invalid.");
        return;
      }
    }
    if (!entry.core->SetViewport(matrix, static_cast<uint64_t>(generation),
                                 &error)) {
      RespondError(call, "invalid_viewport", error);
      return;
    }
  } else if (g_strcmp0(method, "renderDabs") == 0) {
    FlValue* packet = Lookup(arguments, "packet");
    if (packet == nullptr ||
        fl_value_get_type(packet) != FL_VALUE_TYPE_UINT8_LIST ||
        !entry.core->RenderPacket(fl_value_get_uint8_list(packet),
                                  fl_value_get_length(packet), &error)) {
      RespondError(call, "invalid_packet", error.empty() ? "Dab packet is invalid." : error);
      return;
    }
  } else if (g_strcmp0(method, "acknowledge") == 0) {
    std::array<uint8_t, 16> stroke{};
    int64_t sequence = 0;
    if (!ReadStroke(Lookup(arguments, "strokeId"), &stroke) ||
        !ReadInteger(Lookup(arguments, "sequence"), 0, 0xffffffffLL,
                     &sequence) ||
        !entry.core->Acknowledge(stroke, static_cast<uint32_t>(sequence),
                                 &error)) {
      RespondError(call, "invalid_acknowledgement",
                   error.empty() ? "Acknowledgement is invalid." : error);
      return;
    }
  } else if (g_strcmp0(method, "cancelAll") == 0) {
    entry.core->CancelAll();
  } else if (g_strcmp0(method, "dispose") == 0) {
    if (!fl_texture_registrar_unregister_texture(
            registrar_, FL_TEXTURE(entry.texture))) {
      RespondError(call, "unregister_failed", "Flutter could not release texture.");
      return;
    }
    g_object_unref(entry.texture);
    entries_.erase(found);
    RespondSuccess(call);
    return;
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }
  if (!fl_texture_registrar_mark_texture_frame_available(
          registrar_, FL_TEXTURE(entry.texture))) {
    RespondError(call, "texture_unavailable", "Flutter texture is unavailable.");
    return;
  }
  RespondSuccess(call);
}

}  // namespace project_ink
