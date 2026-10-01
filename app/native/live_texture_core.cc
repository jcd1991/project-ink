// SPDX-License-Identifier: MPL-2.0
#include "live_texture_core.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <iterator>
#include <limits>

namespace project_ink {
namespace {

uint16_t ReadU16(const uint8_t* data) {
  return static_cast<uint16_t>(data[0]) |
         (static_cast<uint16_t>(data[1]) << 8);
}

uint32_t ReadU32(const uint8_t* data) {
  return static_cast<uint32_t>(data[0]) |
         (static_cast<uint32_t>(data[1]) << 8) |
         (static_cast<uint32_t>(data[2]) << 16) |
         (static_cast<uint32_t>(data[3]) << 24);
}

float ReadF32(const uint8_t* data) {
  const uint32_t bits = ReadU32(data);
  float value = 0;
  static_assert(sizeof(value) == sizeof(bits));
  std::memcpy(&value, &bits, sizeof(value));
  return value;
}

bool IsFiniteAndBounded(double value) {
  return std::isfinite(value) && std::abs(value) <= 1000000.0;
}

void StoreChannel(uint8_t* destination, double value) {
  *destination = static_cast<uint8_t>(
      std::clamp(std::lround(value * 255.0), 0L, 255L));
}

}  // namespace

LiveTextureCore::LiveTextureCore(uint32_t width, uint32_t height)
    : width_(width),
      height_(height),
      valid_(width > 0 && height > 0 && width <= kMaxDimension &&
             height <= kMaxDimension &&
             static_cast<uint64_t>(width) * height * 4 <= kMaxSurfaceBytes),
      pixels_(valid_ ? std::make_shared<std::vector<uint8_t>>(
                           static_cast<size_t>(width) * height * 4, 0)
                     : nullptr) {}

bool LiveTextureCore::SetViewport(const std::array<double, 6>& matrix,
                                  uint64_t generation,
                                  std::string* error) {
  if (std::any_of(matrix.begin(), matrix.end(),
                  [](double value) { return !IsFiniteAndBounded(value); })) {
    if (error) *error = "viewport matrix contains an invalid value";
    return false;
  }
  std::lock_guard<std::mutex> lock(mutex_);
  if (generation < viewport_generation_) {
    if (error) *error = "viewport generation is stale";
    return false;
  }
  const auto previous_viewport = viewport_;
  const uint64_t previous_generation = viewport_generation_;
  viewport_ = matrix;
  viewport_generation_ = generation;
  if (Redraw(error)) return true;
  viewport_ = previous_viewport;
  viewport_generation_ = previous_generation;
  return false;
}

bool LiveTextureCore::RenderPacket(const uint8_t* packet,
                                   size_t packet_size,
                                   std::string* error) {
  std::vector<Dab> incoming;
  if (!DecodePacket(packet, packet_size, &incoming, error)) return false;
  std::lock_guard<std::mutex> lock(mutex_);
  const auto old_dabs = dabs_;
  const auto old_indices = dab_indices_;
  std::vector<Dab> appended;
  bool append_only = true;
  for (const Dab& dab : incoming) {
    const auto found = dab_indices_.find(dab.key);
    if (found != dab_indices_.end()) {
      if (dabs_[found->second].x != dab.x || dabs_[found->second].y != dab.y ||
          dabs_[found->second].radius != dab.radius ||
          dabs_[found->second].opacity != dab.opacity ||
          dabs_[found->second].color != dab.color) {
        dabs_[found->second] = dab;
        append_only = false;
      }
      continue;
    }
    if (dabs_.size() == kMaxRetainedDabs) {
      dabs_ = old_dabs;
      dab_indices_ = old_indices;
      if (error) *error = "native live preview reached its dab limit";
      return false;
    }
    dab_indices_.emplace(dab.key, dabs_.size());
    dabs_.push_back(dab);
    appended.push_back(dab);
  }
  const bool rendered = append_only ? DrawDabs(appended, error) : Redraw(error);
  if (!rendered) {
    dabs_ = old_dabs;
    dab_indices_ = old_indices;
    return false;
  }
  Publish();
  return true;
}

bool LiveTextureCore::Acknowledge(const std::array<uint8_t, 16>& stroke_id,
                                 uint32_t sequence,
                                 std::string* error) {
  std::lock_guard<std::mutex> lock(mutex_);
  const auto old_dabs = dabs_;
  const auto old_indices = dab_indices_;
  dabs_.erase(std::remove_if(dabs_.begin(), dabs_.end(),
                             [&](const Dab& dab) {
                               return dab.stroke_id == stroke_id &&
                                      dab.sequence <= sequence;
                             }),
              dabs_.end());
  dab_indices_.clear();
  for (size_t index = 0; index < dabs_.size(); ++index) {
    dab_indices_.emplace(dabs_[index].key, index);
  }
  if (!Redraw(error)) {
    dabs_ = old_dabs;
    dab_indices_ = old_indices;
    return false;
  }
  Publish();
  return true;
}

void LiveTextureCore::CancelAll() {
  std::lock_guard<std::mutex> lock(mutex_);
  dabs_.clear();
  dab_indices_.clear();
  EnsureWritablePixels();
  std::fill(pixels_->begin(), pixels_->end(), 0);
  Publish();
}

std::shared_ptr<const std::vector<uint8_t>> LiveTextureCore::Snapshot() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return pixels_;
}

bool LiveTextureCore::DecodePacket(const uint8_t* packet,
                                   size_t packet_size,
                                   std::vector<Dab>* dabs,
                                   std::string* error) const {
  if (!valid_ || packet == nullptr || packet_size < kHeaderBytes ||
      packet_size > kHeaderBytes + kMaxRecordsPerPacket * kRecordBytes) {
    if (error) *error = "live dab packet length is invalid";
    return false;
  }
  const uint32_t count = ReadU32(packet + 4);
  if (ReadU16(packet) != 3 || ReadU16(packet + 2) != 0 ||
      count > kMaxRecordsPerPacket ||
      packet_size != kHeaderBytes + static_cast<size_t>(count) * kRecordBytes) {
    if (error) *error = "live dab packet header or size is invalid";
    return false;
  }
  dabs->reserve(count);
  for (uint32_t index = 0; index < count; ++index) {
    const uint8_t* record = packet + kHeaderBytes + index * kRecordBytes;
    if (record[44] > 2 ||
        std::any_of(record + 49, record + kRecordBytes,
                    [](uint8_t byte) { return byte != 0; })) {
      if (error) *error = "live dab phase or reserved bytes are invalid";
      return false;
    }
    Dab dab;
    std::copy(record, record + 16, dab.stroke_id.begin());
    std::copy(record, record + 24, dab.key.begin());
    dab.sequence = ReadU32(record + 16);
    dab.dab_index = ReadU32(record + 20);
    const float values[] = {ReadF32(record + 24), ReadF32(record + 28),
                            ReadF32(record + 32), ReadF32(record + 36),
                            ReadF32(record + 40)};
    if (std::any_of(std::begin(values), std::end(values),
                    [](float value) { return !std::isfinite(value); }) ||
        std::abs(values[0]) > 1000000000.0F ||
        std::abs(values[1]) > 1000000000.0F || values[2] < 0 ||
        values[2] > 131072 || values[3] < 0 ||
        values[3] > 1) {
      if (error) *error = "live dab contains an invalid float";
      return false;
    }
    dab.x = values[0];
    dab.y = values[1];
    dab.radius = values[2];
    dab.opacity = values[3];
    std::copy(record + 45, record + 49, dab.color.begin());
    dabs->push_back(dab);
  }
  return true;
}

bool LiveTextureCore::DrawDabs(const std::vector<Dab>& dabs,
                               std::string* error) {
  if (!IsWorkWithinBudget(dabs, error)) return false;
  EnsureWritablePixels();
  const double a = viewport_[0];
  const double b = viewport_[1];
  const double c = viewport_[2];
  const double d = viewport_[3];
  const double scale = std::max(std::hypot(a, b), std::hypot(c, d));
  for (const Dab& dab : dabs) {
    const double center_x = a * dab.x + c * dab.y + viewport_[4];
    const double center_y = b * dab.x + d * dab.y + viewport_[5];
    const double radius = std::min<double>(dab.radius * scale, 131072.0);
    const int64_t left = std::max<int64_t>(0, static_cast<int64_t>(std::floor(center_x - radius - 1)));
    const int64_t top = std::max<int64_t>(0, static_cast<int64_t>(std::floor(center_y - radius - 1)));
    const int64_t right = std::min<int64_t>(width_, static_cast<int64_t>(std::ceil(center_x + radius + 1)));
    const int64_t bottom = std::min<int64_t>(height_, static_cast<int64_t>(std::ceil(center_y + radius + 1)));
    for (int64_t y = top; y < bottom; ++y) {
      for (int64_t x = left; x < right; ++x) {
        const double distance = std::hypot((x + 0.5) - center_x, (y + 0.5) - center_y);
        const double coverage = std::clamp(radius + 0.5 - distance, 0.0, 1.0);
        const double alpha = coverage * dab.opacity * dab.color[3] / 255.0;
        if (alpha <= 0) continue;
        uint8_t* pixel = pixels_->data() +
                         (static_cast<size_t>(y) * width_ + static_cast<size_t>(x)) * 4;
        const double inverse = 1.0 - alpha;
        for (size_t channel = 0; channel < 3; ++channel) {
          const double source = dab.color[channel] / 255.0 * alpha;
          const double destination = pixel[channel] / 255.0;
          StoreChannel(pixel + channel, source + destination * inverse);
        }
        const double destination_alpha = pixel[3] / 255.0;
        StoreChannel(pixel + 3, alpha + destination_alpha * inverse);
      }
    }
  }
  return true;
}

bool LiveTextureCore::IsWorkWithinBudget(const std::vector<Dab>& dabs,
                                         std::string* error) const {
  const double a = viewport_[0];
  const double b = viewport_[1];
  const double c = viewport_[2];
  const double d = viewport_[3];
  const double scale = std::max(std::hypot(a, b), std::hypot(c, d));
  uint64_t work = 0;
  for (const Dab& dab : dabs) {
    const double center_x = a * dab.x + c * dab.y + viewport_[4];
    const double center_y = b * dab.x + d * dab.y + viewport_[5];
    const double radius = std::min<double>(dab.radius * scale, 131072.0);
    const int64_t left = std::max<int64_t>(0, static_cast<int64_t>(std::floor(center_x - radius - 1)));
    const int64_t top = std::max<int64_t>(0, static_cast<int64_t>(std::floor(center_y - radius - 1)));
    const int64_t right = std::min<int64_t>(width_, static_cast<int64_t>(std::ceil(center_x + radius + 1)));
    const int64_t bottom = std::min<int64_t>(height_, static_cast<int64_t>(std::ceil(center_y + radius + 1)));
    const uint64_t area = static_cast<uint64_t>(std::max<int64_t>(0, right - left)) *
                          static_cast<uint64_t>(std::max<int64_t>(0, bottom - top));
    if (area > 16777216ULL - work) {
      if (error) *error = "native live preview raster work exceeded its frame budget";
      return false;
    }
    work += area;
  }
  return true;
}

bool LiveTextureCore::Redraw(std::string* error) {
  // Validate the complete redraw before changing the published frame. Failed
  // viewport/acknowledgement rebuilds must leave the last good pixels visible.
  if (!IsWorkWithinBudget(dabs_, error)) return false;
  EnsureWritablePixels();
  std::fill(pixels_->begin(), pixels_->end(), 0);
  if (!DrawDabs(dabs_, error)) return false;
  return true;
}

void LiveTextureCore::EnsureWritablePixels() {
  if (pixels_.use_count() > 1) {
    pixels_ = std::make_shared<std::vector<uint8_t>>(*pixels_);
  }
}

void LiveTextureCore::Publish() {
  // pixels_ itself is the immutable frame shared with any outstanding copy.
  // A later mutation first detaches it in EnsureWritablePixels().
}

}  // namespace project_ink
