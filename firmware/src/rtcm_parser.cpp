#include "rtcm_parser.h"

namespace kataster {

RtcmParser::RtcmParser(FrameCallback callback, void* context)
    : callback_(callback), context_(context) {}

void RtcmParser::reset() {
  size_ = 0;
  expectedSize_ = 0;
}

void RtcmParser::resetStatistics() {
  validFrames_ = 0;
  crcErrors_ = 0;
  discardedBytes_ = 0;
}

void RtcmParser::feed(const uint8_t* bytes, std::size_t length) {
  for (std::size_t index = 0; index < length; ++index) {
    feedByte(bytes[index]);
  }
}

void RtcmParser::restartFrom(uint8_t byte) {
  reset();
  if (byte == 0xD3U) {
    buffer_[0] = byte;
    size_ = 1;
  } else {
    ++discardedBytes_;
  }
}

void RtcmParser::feedByte(uint8_t byte) {
  if (size_ == 0) {
    restartFrom(byte);
    return;
  }

  if (size_ == 1 && (byte & 0xFCU) != 0) {
    ++discardedBytes_;
    restartFrom(byte);
    return;
  }

  if (size_ >= buffer_.size()) {
    ++discardedBytes_;
    restartFrom(byte);
    return;
  }

  buffer_[size_++] = byte;

  if (size_ == 3) {
    const std::size_t payloadLength =
        (static_cast<std::size_t>(buffer_[1] & 0x03U) << 8U) |
        static_cast<std::size_t>(buffer_[2]);
    expectedSize_ = 3 + payloadLength + 3;
    if (payloadLength == 0 || expectedSize_ > buffer_.size()) {
      ++discardedBytes_;
      restartFrom(byte);
      return;
    }
  }

  if (expectedSize_ == 0 || size_ < expectedSize_) {
    return;
  }

  const uint32_t expectedCrc =
      (static_cast<uint32_t>(buffer_[expectedSize_ - 3]) << 16U) |
      (static_cast<uint32_t>(buffer_[expectedSize_ - 2]) << 8U) |
      static_cast<uint32_t>(buffer_[expectedSize_ - 1]);
  const uint32_t actualCrc = crc24q(buffer_.data(), expectedSize_ - 3);

  if (expectedCrc == actualCrc) {
    ++validFrames_;
    const uint16_t messageType =
        expectedSize_ >= 8
            ? static_cast<uint16_t>((buffer_[3] << 4U) | (buffer_[4] >> 4U))
            : 0;
    if (callback_ != nullptr) {
      callback_(buffer_.data(), expectedSize_, messageType, context_);
    }
  } else {
    ++crcErrors_;
  }

  const uint8_t finalByte = buffer_[expectedSize_ - 1];
  reset();
  if (expectedCrc != actualCrc && finalByte == 0xD3U) {
    buffer_[0] = finalByte;
    size_ = 1;
  }
}

uint32_t RtcmParser::crc24q(const uint8_t* bytes, std::size_t length) {
  uint32_t crc = 0;
  for (std::size_t index = 0; index < length; ++index) {
    crc ^= static_cast<uint32_t>(bytes[index]) << 16U;
    for (uint8_t bit = 0; bit < 8; ++bit) {
      crc <<= 1U;
      if ((crc & 0x1000000U) != 0) {
        crc ^= 0x1864CFBU;
      }
    }
  }
  return crc & 0xFFFFFFU;
}

}  // namespace kataster
