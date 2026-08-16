#pragma once

#include <Arduino.h>
#include <Wire.h>

#include <cstddef>
#include <cstdint>

#include "imu_processor.h"

namespace kataster {

enum class SimulatedImuMode : uint8_t {
  kLevel,
  kTilted,
  kMotion,
  kLeft,
  kRight,
  kForward,
  kBackward,
};

class ImuSource {
 public:
  virtual ~ImuSource() = default;
  virtual bool begin() = 0;
  virtual bool read(ImuSample& sample) = 0;
  virtual const char* name() const = 0;
  virtual bool isSimulation() const = 0;
};

class Mpu6050Source final : public ImuSource {
 public:
  Mpu6050Source(TwoWire& wire, int sdaPin, int sclPin)
      : wire_(wire), sdaPin_(sdaPin), sclPin_(sclPin) {}

  bool begin() override;
  bool read(ImuSample& sample) override;
  const char* name() const override { return "mpu6050"; }
  bool isSimulation() const override { return false; }
  uint8_t address() const { return address_; }

 private:
  bool writeRegister(uint8_t reg, uint8_t value);
  bool readRegisters(uint8_t reg, uint8_t* target, std::size_t length);

  TwoWire& wire_;
  int sdaPin_;
  int sclPin_;
  uint8_t address_ = 0;
};

class SimulatedImuSource final : public ImuSource {
 public:
  bool begin() override { return true; }
  bool read(ImuSample& sample) override;
  const char* name() const override { return "simulation"; }
  bool isSimulation() const override { return true; }
  void setMode(SimulatedImuMode mode) { mode_ = mode; }
  SimulatedImuMode mode() const { return mode_; }

 private:
  SimulatedImuMode mode_ = SimulatedImuMode::kLevel;
};

const char* simulatedImuModeName(SimulatedImuMode mode);

}  // namespace kataster
