#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <flutter/event_channel.h>
#include <flutter/encodable_value.h>
#include <flutter/standard_method_codec.h>

#include <memory>

#include "win32_window.h"
#include "../ink_pointer_adapter.h"
#include "live_texture_registry.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  project_ink::InkPointerStreamHandler* pointer_stream_ = nullptr;
  project_ink::InkPointerStreamHandler* pointer_status_ = nullptr;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>>
      pointer_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>>
      pointer_status_channel_;
  std::unique_ptr<project_ink::InkPointerAdapter> pointer_adapter_;
  std::unique_ptr<project_ink::WindowsLiveTextureRegistry> live_textures_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
