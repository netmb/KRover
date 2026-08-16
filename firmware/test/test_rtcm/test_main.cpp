#include <unity.h>

#include <array>
#include <cstdint>
#include <vector>

#include "rtcm_parser.h"

namespace {

uint32_t callbackCount = 0;
uint16_t callbackType = 0;

void onFrame(const uint8_t*, std::size_t, uint16_t messageType, void*) {
  ++callbackCount;
  callbackType = messageType;
}

std::vector<uint8_t> makeFrame(uint16_t messageType) {
  std::array<uint8_t, 4> payload{
      static_cast<uint8_t>((messageType >> 4U) & 0xFFU),
      static_cast<uint8_t>((messageType & 0x0FU) << 4U), 0x12, 0x34};
  std::vector<uint8_t> frame{0xD3, 0x00,
                             static_cast<uint8_t>(payload.size())};
  frame.insert(frame.end(), payload.begin(), payload.end());
  const uint32_t crc =
      kataster::RtcmParser::crc24q(frame.data(), frame.size());
  frame.push_back(static_cast<uint8_t>((crc >> 16U) & 0xFFU));
  frame.push_back(static_cast<uint8_t>((crc >> 8U) & 0xFFU));
  frame.push_back(static_cast<uint8_t>(crc & 0xFFU));
  return frame;
}

void setUp() {
  callbackCount = 0;
  callbackType = 0;
}

void tearDown() {}

void testParsesChunkedFrame() {
  kataster::RtcmParser parser(onFrame);
  auto frame = makeFrame(1074);
  parser.feed(frame.data(), 2);
  parser.feed(frame.data() + 2, frame.size() - 2);
  TEST_ASSERT_EQUAL_UINT32(1, parser.validFrames());
  TEST_ASSERT_EQUAL_UINT32(1, callbackCount);
  TEST_ASSERT_EQUAL_UINT16(1074, callbackType);
}

void testRejectsCorruptFrameAndRecovers() {
  kataster::RtcmParser parser(onFrame);
  auto broken = makeFrame(1084);
  broken[4] ^= 0x01;
  auto valid = makeFrame(1124);
  parser.feed(broken.data(), broken.size());
  parser.feed(valid.data(), valid.size());
  TEST_ASSERT_EQUAL_UINT32(1, parser.crcErrors());
  TEST_ASSERT_EQUAL_UINT32(1, parser.validFrames());
  TEST_ASSERT_EQUAL_UINT16(1124, callbackType);
}

}  // namespace

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(testParsesChunkedFrame);
  RUN_TEST(testRejectsCorruptFrameAndRecovers);
  return UNITY_END();
}
