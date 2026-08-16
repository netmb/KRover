#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

namespace kataster {

class RtcmParser {
 public:
  using FrameCallback = void (*)(const uint8_t* frame, std::size_t length,
                                 uint16_t messageType, void* context);

  RtcmParser(FrameCallback callback = nullptr, void* context = nullptr);

  void feed(const uint8_t* bytes, std::size_t length);
  void reset();
  void resetStatistics();

  uint32_t validFrames() const { return validFrames_; }
  uint32_t crcErrors() const { return crcErrors_; }
  uint32_t discardedBytes() const { return discardedBytes_; }

  static uint32_t crc24q(const uint8_t* bytes, std::size_t length);

 private:
  void feedByte(uint8_t byte);
  void restartFrom(uint8_t byte);

  static constexpr std::size_t kMaximumFrameSize = 3 + 1023 + 3;
  std::array<uint8_t, kMaximumFrameSize> buffer_{};
  std::size_t size_ = 0;
  std::size_t expectedSize_ = 0;
  FrameCallback callback_ = nullptr;
  void* context_ = nullptr;
  uint32_t validFrames_ = 0;
  uint32_t crcErrors_ = 0;
  uint32_t discardedBytes_ = 0;
};

}  // namespace kataster
