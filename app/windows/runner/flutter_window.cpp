#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include <flutter/plugin_registrar_windows.h>

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  auto* native_registrar =
      flutter_controller_->engine()->GetRegistrarForPlugin(
          "ProjectInkLiveTexture");
  auto* platform_registrar =
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(native_registrar);
  live_textures_ = std::make_unique<project_ink::WindowsLiveTextureRegistry>(
      platform_registrar->messenger(), platform_registrar->texture_registrar());
  auto packet_handler =
      std::make_unique<project_ink::InkPointerStreamHandler>(false);
  pointer_stream_ = packet_handler.get();
  auto status_handler =
      std::make_unique<project_ink::InkPointerStreamHandler>(true);
  pointer_status_ = status_handler.get();
  auto* messenger = flutter_controller_->engine()->binary_messenger();
  pointer_channel_ = std::make_unique<
      flutter::EventChannel<flutter::EncodableValue>>(
      messenger, "org.projectink.studio/pointer_packets_v1",
      &flutter::StandardMethodCodec::GetInstance());
  pointer_status_channel_ = std::make_unique<
      flutter::EventChannel<flutter::EncodableValue>>(
      messenger, "org.projectink.studio/pointer_status_v1",
      &flutter::StandardMethodCodec::GetInstance());
  pointer_channel_->SetStreamHandler(std::move(packet_handler));
  pointer_status_channel_->SetStreamHandler(std::move(status_handler));
  pointer_adapter_ =
      std::make_unique<project_ink::InkPointerAdapter>(pointer_stream_);
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  live_textures_.reset();
  if (pointer_channel_) pointer_channel_->SetStreamHandler(nullptr);
  if (pointer_status_channel_) pointer_status_channel_->SetStreamHandler(nullptr);
  pointer_adapter_.reset();
  pointer_stream_ = nullptr;
  pointer_status_ = nullptr;
  pointer_channel_.reset();
  pointer_status_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (pointer_adapter_) {
    // A native adapter consumes a pen message only after the Flutter
    // EventChannel has a live listener and the packet was published. Returning
    // early prevents the same contact from being delivered a second time by
    // Flutter's generic pointer recognizer. During startup or after a channel
    // failure HandleMessage returns false, so Flutter keeps its fallback path.
    if (pointer_adapter_->HandleMessage(hwnd, message, wparam, lparam)) {
      return 0;
    }
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
