#include "imu_source.h"

#include <cmath>

namespace kataster {
namespace {

constexpr uint8_t kWhoAmI = 0x75;
constexpr uint8_t kPowerManagement1 = 0x6B;
constexpr uint8_t kSampleRateDivider = 0x19;
constexpr uint8_t kConfiguration = 0x1A;
constexpr uint8_t kGyroConfiguration = 0x1B;
constexpr uint8_t kAccelerometerConfiguration = 0x1C;
constexpr uint8_t kAccelerometerData = 0x3B;
constexpr float kPi = 3.14159265358979323846F;

int16_t decodeSigned(const uint8_t* bytes) {
  return static_cast<int16_t>((static_cast<uint16_t>(bytes[0]) << 8U) |
                              bytes[1]);
}

}  // namespace

const char* simulatedImuModeName(SimulatedImuMode mode) {
  switch (mode) {
    case SimulatedImuMode::kTilted:
      return "tilted";
    case SimulatedImuMode::kMotion:
      return "motion";
    case SimulatedImuMode::kLeft:
      return "left";
    case SimulatedImuMode::kRight:
      return "right";
    case SimulatedImuMode::kForward:
      return "forward";
    case SimulatedImuMode::kBackward:
      return "backward";
    case SimulatedImuMode::kLevel:
    default:
      return "level";
  }
}

bool Mpu6050Source::begin() {
  wire_.begin(sdaPin_, sclPin_, 400000U);
  for (const uint8_t candidate : {uint8_t{0x68}, uint8_t{0x69}}) {
    address_ = candidate;
    uint8_t identity = 0;
    if (readRegisters(kWhoAmI, &identity, 1) &&
        (identity == 0x68U || identity == 0x70U || identity == 0x72U)) {
      break;
    }
    address_ = 0;
  }
  if (address_ == 0) {
    return false;
  }

  // PLL clock, 100 Hz sample rate, 44 Hz DLPF, gyro +/-250 dps,
  // accelerometer +/-2 g.
  return writeRegister(kPowerManagement1, 0x01) &&
         writeRegister(kSampleRateDivider, 0x09) &&
         writeRegister(kConfiguration, 0x03) &&
         writeRegister(kGyroConfiguration, 0x00) &&
         writeRegister(kAccelerometerConfiguration, 0x00);
}

bool Mpu6050Source::writeRegister(uint8_t reg, uint8_t value) {
  wire_.beginTransmission(address_);
  wire_.write(reg);
  wire_.write(value);
  return wire_.endTransmission(true) == 0;
}

bool Mpu6050Source::readRegisters(uint8_t reg, uint8_t* target,
                                  std::size_t length) {
  if (address_ == 0) {
    return false;
  }
  wire_.beginTransmission(address_);
  wire_.write(reg);
  if (wire_.endTransmission(false) != 0) {
    return false;
  }
  const std::size_t received =
      wire_.requestFrom(static_cast<int>(address_), static_cast<int>(length),
                        static_cast<int>(true));
  if (received != length) {
    return false;
  }
  for (std::size_t index = 0; index < length; ++index) {
    target[index] = static_cast<uint8_t>(wire_.read());
  }
  return true;
}

bool Mpu6050Source::read(ImuSample& sample) {
  uint8_t bytes[14]{};
  if (!readRegisters(kAccelerometerData, bytes, sizeof(bytes))) {
    return false;
  }
  sample.accelerationXG = static_cast<float>(decodeSigned(bytes)) / 16384.0F;
  sample.accelerationYG =
      static_cast<float>(decodeSigned(bytes + 2)) / 16384.0F;
  sample.accelerationZG =
      static_cast<float>(decodeSigned(bytes + 4)) / 16384.0F;
  sample.gyroXDps = static_cast<float>(decodeSigned(bytes + 8)) / 131.0F;
  sample.gyroYDps = static_cast<float>(decodeSigned(bytes + 10)) / 131.0F;
  sample.gyroZDps = static_cast<float>(decodeSigned(bytes + 12)) / 131.0F;
  sample.timestampMs = millis();
  return true;
}

bool SimulatedImuSource::read(ImuSample& sample) {
  const uint32_t now = millis();
  const float seconds = static_cast<float>(now) / 1000.0F;
  float rollDegrees = 0.0F;
  float pitchDegrees = 0.0F;

  switch (mode_) {
    case SimulatedImuMode::kTilted:
      rollDegrees = 3.5F + std::sin(seconds * 0.7F) * 0.7F;
      pitchDegrees = -2.0F + std::cos(seconds * 0.6F) * 0.5F;
      sample.gyroXDps = std::cos(seconds * 0.7F) * 0.49F;
      sample.gyroYDps = -std::sin(seconds * 0.6F) * 0.30F;
      break;
    case SimulatedImuMode::kMotion:
      rollDegrees = std::sin(seconds * 3.0F) * 5.0F;
      pitchDegrees = std::cos(seconds * 2.4F) * 4.0F;
      sample.gyroXDps = std::cos(seconds * 3.0F) * 15.0F;
      sample.gyroYDps = -std::sin(seconds * 2.4F) * 9.6F;
      sample.gyroZDps = std::sin(seconds * 1.7F) * 8.0F;
      break;
    case SimulatedImuMode::kLeft:
      pitchDegrees = 3.0F + std::sin(seconds * 0.5F) * 0.15F;
      sample.gyroYDps = std::cos(seconds * 0.5F) * 0.075F;
      break;
    case SimulatedImuMode::kRight:
      pitchDegrees = -3.0F + std::sin(seconds * 0.5F) * 0.15F;
      sample.gyroYDps = std::cos(seconds * 0.5F) * 0.075F;
      break;
    case SimulatedImuMode::kForward:
      rollDegrees = -3.0F + std::sin(seconds * 0.5F) * 0.15F;
      sample.gyroXDps = std::cos(seconds * 0.5F) * 0.075F;
      break;
    case SimulatedImuMode::kBackward:
      rollDegrees = 3.0F + std::sin(seconds * 0.5F) * 0.15F;
      sample.gyroXDps = std::cos(seconds * 0.5F) * 0.075F;
      break;
    case SimulatedImuMode::kLevel:
    default:
      rollDegrees = std::sin(seconds * 0.4F) * 0.08F;
      pitchDegrees = std::cos(seconds * 0.35F) * 0.06F;
      sample.gyroXDps = std::cos(seconds * 0.4F) * 0.032F;
      sample.gyroYDps = -std::sin(seconds * 0.35F) * 0.021F;
      break;
  }

  const float roll = rollDegrees * kPi / 180.0F;
  const float pitch = pitchDegrees * kPi / 180.0F;
  sample.accelerationXG = -std::sin(pitch);
  sample.accelerationYG = std::sin(roll) * std::cos(pitch);
  sample.accelerationZG = std::cos(roll) * std::cos(pitch);
  if (mode_ == SimulatedImuMode::kMotion) {
    sample.accelerationXG += std::sin(seconds * 6.0F) * 0.07F;
    sample.accelerationYG += std::cos(seconds * 5.0F) * 0.05F;
  }
  sample.timestampMs = now;
  return true;
}

}  // namespace kataster
