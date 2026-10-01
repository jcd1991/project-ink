// SPDX-License-Identifier: MPL-2.0
#ifndef PROJECT_INK_LIVE_TEXTURE_CORE_H_
#define PROJECT_INK_LIVE_TEXTURE_CORE_H_

#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <functional>
#include <string>
#include <unordered_map>
#include <vector>

namespace project_ink {

// Shared bounded native dab rasterizer for desktop Flutter external textures.
// It only produces an ephemeral premultiplied RGBA preview; Rust CPU tiles
// remain authoritative for the document, undo, save, and export.
class LiveTextureCore {
 public:
  static constexpr uint32_t kMaxDimension = 8192;
  static constexpr uint64_t kMaxSurfaceBytes = 64ULL * 1024ULL * 1024ULL;
  static constexpr size_t kMaxRetainedDabs = 65536;
  static constexpr size_t kMaxRecordsPerPacket = 2048;
  static constexpr size_t kHeaderBytes = 8;
  static constexpr size_t kRecordBytes = 56;

  LiveTextureCore(uint32_t width, uint32_t height);

  bool valid() const { return valid_; }
  uint32_t width() const { return width_; }
  uint32_t height() const { return height_; }

  bool SetViewport(const std::array<double, 6>& matrix,
                   uint64_t generation,
                   std::string* error);
  bool RenderPacket(const uint8_t* packet,
                    size_t packet_size,
                    std::string* error);
  bool Acknowledge(const std::array<uint8_t, 16>& stroke_id,
                   uint32_t sequence,
                   std::string* error);
  void CancelAll();

  // The immutable snapshot remains valid while Flutter copies pixels even if
  // a subsequent frame arrives. The renderer uses copy-on-write in that case.
  std::shared_ptr<const std::vector<uint8_t>> Snapshot() const;

 private:
  struct Dab {
    std::array<uint8_t, 24> key{};
    std::array<uint8_t, 16> stroke_id{};
    uint32_t sequence = 0;
    uint32_t dab_index = 0;
    float x = 0;
    float y = 0;
    float radius = 0;
    float opacity = 0;
    std::array<uint8_t, 4> color{};
  };

  struct DabKeyHash {
    size_t operator()(const std::array<uint8_t, 24>& value) const noexcept {
      size_t result = 1469598103934665603ULL;
      for (const uint8_t byte : value) {
        result = (result ^ byte) * 1099511628211ULL;
      }
      return result;
    }
  };

  bool DecodePacket(const uint8_t* packet,
                    size_t packet_size,
                    std::vector<Dab>* dabs,
                    std::string* error) const;
  bool DrawDabs(const std::vector<Dab>& dabs,
                std::string* error);
  bool IsWorkWithinBudget(const std::vector<Dab>& dabs,
                          std::string* error) const;
  bool Redraw(std::string* error);
  void EnsureWritablePixels();
  void Publish();

  const uint32_t width_;
  const uint32_t height_;
  const bool valid_;
  mutable std::mutex mutex_;
  std::array<double, 6> viewport_{1, 0, 0, 1, 0, 0};
  uint64_t viewport_generation_ = 0;
  std::vector<Dab> dabs_;
  std::unordered_map<std::array<uint8_t, 24>, size_t, DabKeyHash> dab_indices_;
  std::shared_ptr<std::vector<uint8_t>> pixels_;
};

}  // namespace project_ink

#endif  // PROJECT_INK_LIVE_TEXTURE_CORE_H_
