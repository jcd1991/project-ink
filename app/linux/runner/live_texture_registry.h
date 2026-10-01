// SPDX-License-Identifier: MPL-2.0
#ifndef RUNNER_LIVE_TEXTURE_REGISTRY_H_
#define RUNNER_LIVE_TEXTURE_REGISTRY_H_

#include <flutter_linux/flutter_linux.h>

#include <cstdint>
#include <memory>
#include <unordered_map>

namespace project_ink {

class LinuxLiveTextureRegistry {
 public:
  LinuxLiveTextureRegistry(FlBinaryMessenger* messenger,
                           FlTextureRegistrar* registrar);
  ~LinuxLiveTextureRegistry();

  LinuxLiveTextureRegistry(const LinuxLiveTextureRegistry&) = delete;
  LinuxLiveTextureRegistry& operator=(const LinuxLiveTextureRegistry&) = delete;

 private:
  struct Entry;
  static void HandleMethodCall(FlMethodChannel* channel,
                               FlMethodCall* call,
                               gpointer user_data);
  void Handle(FlMethodCall* call);

  FlTextureRegistrar* registrar_;
  FlMethodChannel* channel_ = nullptr;
  std::unordered_map<int64_t, std::unique_ptr<Entry>> entries_;
};

}  // namespace project_ink

#endif  // RUNNER_LIVE_TEXTURE_REGISTRY_H_
