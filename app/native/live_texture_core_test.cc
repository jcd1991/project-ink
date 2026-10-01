// SPDX-License-Identifier: MPL-2.0
#include "live_texture_core.h"

#include <algorithm>
#include <cassert>
#include <cstring>

namespace {

void WriteU32(uint8_t* bytes, uint32_t value) {
  bytes[0] = static_cast<uint8_t>(value);
  bytes[1] = static_cast<uint8_t>(value >> 8);
  bytes[2] = static_cast<uint8_t>(value >> 16);
  bytes[3] = static_cast<uint8_t>(value >> 24);
}

void WriteF32(uint8_t* bytes, float value) {
  uint32_t bits = 0;
  std::memcpy(&bits, &value, sizeof(bits));
  WriteU32(bytes, bits);
}

std::vector<uint8_t> Packet(size_t count) {
  std::vector<uint8_t> packet(8 + count * 56, 0);
  packet[0] = 3;
  WriteU32(packet.data() + 4, static_cast<uint32_t>(count));
  return packet;
}

void WriteDab(std::vector<uint8_t>* packet,
              size_t index,
              uint32_t sequence,
              uint32_t dab_index,
              float x,
              float y) {
  uint8_t* record = packet->data() + 8 + index * 56;
  record[0] = 0x34;
  record[15] = 0x12;
  WriteU32(record + 16, sequence);
  WriteU32(record + 20, dab_index);
  WriteF32(record + 24, x);
  WriteF32(record + 28, y);
  WriteF32(record + 32, 1.5F);
  WriteF32(record + 36, 1.0F);
  WriteF32(record + 40, 0.0F);
  record[44] = 2;
  record[45] = 255;
  record[46] = 80;
  record[47] = 24;
  record[48] = 255;
}

}  // namespace

int main() {
  project_ink::LiveTextureCore texture(16, 16);
  assert(texture.valid());

  std::string error;
  auto packet = Packet(2);
  WriteDab(&packet, 0, 7, 0, 3.0F, 4.0F);
  WriteDab(&packet, 1, 7, 1, 11.0F, 10.0F);
  assert(texture.RenderPacket(packet.data(), packet.size(), &error));

  auto first_frame = texture.Snapshot();
  const auto pixel = [&](size_t x, size_t y) {
    return (*first_frame)[(y * texture.width() + x) * 4 + 3];
  };
  assert(pixel(3, 4) > 0);
  assert(pixel(11, 10) > 0);

  auto malformed = Packet(1);
  WriteDab(&malformed, 0, 8, 0, 6.0F, 6.0F);
  malformed[8 + 55] = 1;
  assert(!texture.RenderPacket(malformed.data(), malformed.size(), &error));
  assert((*first_frame)[(6 * texture.width() + 6) * 4 + 3] == 0);

  // A viewport transform can make a previously safe retained dab set exceed
  // the frame-work budget. Rejection must preserve both the current frame and
  // the last accepted generation, rather than publishing a cleared texture.
  project_ink::LiveTextureCore transactional_texture(2048, 2048);
  auto large_packet = Packet(20);
  for (size_t index = 0; index < 20; ++index) {
    WriteDab(&large_packet, index, 1, static_cast<uint32_t>(index), 0.25F,
             0.25F);
    WriteF32(large_packet.data() + 8 + index * 56 + 32, 64.0F);
  }
  assert(transactional_texture.RenderPacket(large_packet.data(),
                                             large_packet.size(), &error));
  const auto stable_frame = transactional_texture.Snapshot();
  assert(!transactional_texture.SetViewport({64, 0, 0, 64, 0, 0}, 1, &error));
  assert(transactional_texture.Snapshot() == stable_frame);
  assert(transactional_texture.SetViewport({1, 0, 0, 1, 0, 0}, 1, &error));
  assert(*transactional_texture.Snapshot() == *stable_frame);

  const std::array<uint8_t, 16> stroke_id = {
      0x34, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x12};
  assert(texture.Acknowledge(stroke_id, 7, &error));
  auto acknowledged_frame = texture.Snapshot();
  assert((*acknowledged_frame)[(4 * texture.width() + 3) * 4 + 3] == 0);
  assert((*acknowledged_frame)[(10 * texture.width() + 11) * 4 + 3] == 0);
  // Frame snapshots stay valid across later redraws via copy-on-write.
  assert(pixel(3, 4) > 0);

  assert(texture.SetViewport({1, 0, 0, 1, 0, 0}, 5, &error));
  assert(!texture.SetViewport({1, 0, 0, 1, 0, 0}, 4, &error));
  texture.CancelAll();
  const auto cancelled_frame = texture.Snapshot();
  assert(std::all_of(cancelled_frame->begin(), cancelled_frame->end(),
                     [](uint8_t byte) { return byte == 0; }));
  return 0;
}
