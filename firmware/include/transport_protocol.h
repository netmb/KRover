#pragma once

#include <cstddef>
#include <cstdint>

namespace kataster {

inline constexpr uint8_t kProtocolVersion = 1;
inline constexpr std::size_t kStreamHeaderSize = 4;

inline constexpr char kServiceUuid[] =
    "7A1E0001-9B6D-4C7A-8F21-6D3E5C790001";
inline constexpr char kRtcmRxUuid[] =
    "7A1E0002-9B6D-4C7A-8F21-6D3E5C790001";
inline constexpr char kGnssTxUuid[] =
    "7A1E0003-9B6D-4C7A-8F21-6D3E5C790001";
inline constexpr char kStatusUuid[] =
    "7A1E0004-9B6D-4C7A-8F21-6D3E5C790001";
inline constexpr char kControlUuid[] =
    "7A1E0005-9B6D-4C7A-8F21-6D3E5C790001";
inline constexpr char kImuTxUuid[] =
    "7A1E0006-9B6D-4C7A-8F21-6D3E5C790001";

inline uint16_t decodeSequence(const uint8_t* bytes) {
  return static_cast<uint16_t>(bytes[2]) |
         (static_cast<uint16_t>(bytes[3]) << 8U);
}

inline void encodeHeader(uint8_t* target, uint8_t session, uint16_t sequence) {
  target[0] = kProtocolVersion;
  target[1] = session;
  target[2] = static_cast<uint8_t>(sequence & 0xFFU);
  target[3] = static_cast<uint8_t>((sequence >> 8U) & 0xFFU);
}

}  // namespace kataster
