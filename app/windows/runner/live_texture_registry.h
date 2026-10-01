// SPDX-License-Identifier: MPL-2.0
#ifndef RUNNER_LIVE_TEXTURE_REGISTRY_H_
#define RUNNER_LIVE_TEXTURE_REGISTRY_H_

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter/texture_registrar.h>

#include <memory>
#include <unordered_map>

#include "../../native/live_texture_core.h"

namespace project_ink {

struct WindowsLiveTextureEntry;

class WindowsLiveTextureRegistry {
 public:
  WindowsLiveTextureRegistry(flutter::BinaryMessenger* messenger,
                             flutter::TextureRegistrar* registrar);
  ~WindowsLiveTextureRegistry();

  WindowsLiveTextureRegistry(const WindowsLiveTextureRegistry&) = delete;
  WindowsLiveTextureRegistry& operator=(const WindowsLiveTextureRegistry&) = delete;

 private:
  using Result = std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>;

  void Handle(const flutter::MethodCall<flutter::EncodableValue>& call,
              Result result);
  std::shared_ptr<WindowsLiveTextureEntry> FindEntry(
      const flutter::EncodableValue& arguments,
      Result* result) const;
  void MarkFrame(int64_t texture_id, Result* result) const;

  flutter::TextureRegistrar* registrar_;
  flutter::MethodChannel<flutter::EncodableValue> channel_;
  std::unordered_map<int64_t, std::shared_ptr<WindowsLiveTextureEntry>> entries_;
};

}  // namespace project_ink

#endif  // RUNNER_LIVE_TEXTURE_REGISTRY_H_
