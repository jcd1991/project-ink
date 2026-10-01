// SPDX-License-Identifier: MPL-2.0
#pragma once

// GDK/Wayland tablet normalization. GTK exposes the tablet axes for both
// Wayland and X11; the Flutter view still receives ordinary pointer events as
// a fallback when a compositor does not expose a tablet device.

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

#include <cstdint>
#include <cstring>
#include <vector>

namespace project_ink {

constexpr uint16_t kPointerFlagActual = 1 << 0;
constexpr uint16_t kPointerFlagEraser = 1 << 3;
constexpr uint16_t kPointerFlagBarrel = 1 << 4;

class InkPointerAdapter final {
 public:
  InkPointerAdapter() = default;
  InkPointerAdapter(const InkPointerAdapter&) = delete;
  InkPointerAdapter& operator=(const InkPointerAdapter&) = delete;

  void Attach(FlBinaryMessenger* messenger, GtkWidget* widget) {
    Detach();
    FlMethodCodec* codec = FL_METHOD_CODEC(fl_standard_method_codec_new());
    packet_channel_ = fl_event_channel_new(
        messenger, "org.projectink.studio/pointer_packets_v1", codec);
    status_channel_ = fl_event_channel_new(
        messenger, "org.projectink.studio/pointer_status_v1", codec);
    g_object_unref(codec);
    fl_event_channel_set_stream_handlers(packet_channel_, &OnListen,
                                         &OnCancel, this, nullptr);
    fl_event_channel_set_stream_handlers(status_channel_, &OnStatusListen,
                                         &OnStatusCancel, this, nullptr);
    gtk_widget_add_events(widget, GDK_POINTER_MOTION_MASK |
                                     GDK_BUTTON_PRESS_MASK |
                                     GDK_BUTTON_RELEASE_MASK |
                                     GDK_PROXIMITY_IN_MASK |
                                     GDK_PROXIMITY_OUT_MASK);
    widget_ = widget;
    event_handler_id_ = g_signal_connect(
        widget_, "event", G_CALLBACK(&OnWidgetEvent), this);
  }

  void Detach() {
    if (widget_ != nullptr && event_handler_id_ != 0) {
      g_signal_handler_disconnect(widget_, event_handler_id_);
    }
    event_handler_id_ = 0;
    widget_ = nullptr;
    g_clear_object(&packet_channel_);
    g_clear_object(&status_channel_);
  }

  ~InkPointerAdapter() { Detach(); }

 private:
  static FlMethodErrorResponse* OnListen(FlEventChannel* /*channel*/,
                                         FlValue* /*args*/,
                                         gpointer user_data) {
    auto* self = static_cast<InkPointerAdapter*>(user_data);
    self->packet_listening_ = true;
    return nullptr;
  }

  static FlMethodErrorResponse* OnCancel(FlEventChannel* /*channel*/,
                                         FlValue* /*args*/,
                                         gpointer user_data) {
    static_cast<InkPointerAdapter*>(user_data)->packet_listening_ = false;
    return nullptr;
  }

  static FlMethodErrorResponse* OnStatusListen(FlEventChannel* /*channel*/,
                                               FlValue* /*args*/,
                                               gpointer user_data) {
    auto* self = static_cast<InkPointerAdapter*>(user_data);
    self->status_listening_ = true;
    g_autoptr(FlValue) ready = fl_value_new_string("ready");
    fl_event_channel_send(self->status_channel_, ready, nullptr, nullptr);
    return nullptr;
  }

  static FlMethodErrorResponse* OnStatusCancel(FlEventChannel* /*channel*/,
                                               FlValue* /*args*/,
                                               gpointer user_data) {
    static_cast<InkPointerAdapter*>(user_data)->status_listening_ = false;
    return nullptr;
  }

  static gboolean OnWidgetEvent(GtkWidget* /*widget*/, GdkEvent* event,
                                gpointer user_data) {
    return static_cast<InkPointerAdapter*>(user_data)->HandleEvent(event)
               ? TRUE
               : FALSE;
  }

  bool HandleEvent(GdkEvent* event) {
    if (!packet_listening_ || event == nullptr) return false;
    GdkDevice* device = nullptr;
    GdkEventType type = event->type;
    double x = 0;
    double y = 0;
    guint32 time = 0;
    guint state = 0;
    guint button = 0;
    switch (type) {
      case GDK_MOTION_NOTIFY:
        device = event->motion.device;
        x = event->motion.x;
        y = event->motion.y;
        time = event->motion.time;
        state = event->motion.state;
        break;
      case GDK_BUTTON_PRESS:
      case GDK_BUTTON_RELEASE:
        device = event->button.device;
        x = event->button.x;
        y = event->button.y;
        time = event->button.time;
        state = event->button.state;
        button = event->button.button;
        break;
      default:
        return false;
    }
    if (device == nullptr) {
      return false;
    }
    const GdkInputSource source = gdk_device_get_source(device);
    if (source != GDK_SOURCE_PEN && source != GDK_SOURCE_ERASER) {
      return false;
    }
    double pressure = 0.5;
    double tilt_x = 0;
    double tilt_y = 0;
    gdk_event_get_axis(event, GDK_AXIS_PRESSURE, &pressure);
    gdk_event_get_axis(event, GDK_AXIS_TILT_X, &tilt_x);
    gdk_event_get_axis(event, GDK_AXIS_TILT_Y, &tilt_y);
    InkPointerSample sample;
    sample.pointer_id = static_cast<uint32_t>(gdk_device_get_device_id(device));
    sample.phase = type == GDK_BUTTON_PRESS ? 0 :
                   type == GDK_BUTTON_RELEASE ? 2 : 1;
    sample.canvas_x = static_cast<float>(x);
    sample.canvas_y = static_cast<float>(y);
    sample.pressure = static_cast<float>(pressure < 0 ? 0 : pressure > 1 ? 1 : pressure);
    sample.tilt_x = static_cast<float>(tilt_x);
    sample.tilt_y = static_cast<float>(tilt_y);
    sample.timestamp_ns = static_cast<uint64_t>(time) * 1000000ULL;
    if (source == GDK_SOURCE_ERASER) sample.flags |= kPointerFlagEraser;
    if ((state & GDK_BUTTON2_MASK) != 0 || button == 2) {
      sample.flags |= kPointerFlagBarrel;
    }
    sample.sequence = sequence_++;

    std::vector<uint8_t> packet(52, 0);
    WriteU16(packet.data(), 1);
    WriteU16(packet.data() + 2, 1);
    uint8_t* output = packet.data() + 4;
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
    g_autoptr(FlValue) value =
        fl_value_new_uint8_list(packet.data(), packet.size());
    fl_event_channel_send(packet_channel_, value, nullptr, nullptr);
    return true;
  }

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

  static void WriteU16(uint8_t* target, uint16_t value) {
    target[0] = value & 0xff;
    target[1] = (value >> 8) & 0xff;
  }
  static void WriteU32(uint8_t* target, uint32_t value) {
    for (int i = 0; i < 4; ++i) target[i] = (value >> (8 * i)) & 0xff;
  }
  static void WriteU64(uint8_t* target, uint64_t value) {
    for (int i = 0; i < 8; ++i) target[i] = (value >> (8 * i)) & 0xff;
  }
  static void WriteFloat(uint8_t* target, float value) {
    uint32_t bits = 0;
    std::memcpy(&bits, &value, sizeof(bits));
    WriteU32(target, bits);
  }

  FlEventChannel* packet_channel_ = nullptr;
  FlEventChannel* status_channel_ = nullptr;
  GtkWidget* widget_ = nullptr;
  gulong event_handler_id_ = 0;
  bool packet_listening_ = false;
  bool status_listening_ = false;
  uint32_t sequence_ = 0;
};

}  // namespace project_ink
