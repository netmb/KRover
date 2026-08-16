#pragma once

#include <cstdint>

namespace kataster {

struct ImuSample {
  float accelerationXG = 0.0F;
  float accelerationYG = 0.0F;
  float accelerationZG = 1.0F;
  float gyroXDps = 0.0F;
  float gyroYDps = 0.0F;
  float gyroZDps = 0.0F;
  uint32_t timestampMs = 0;
};

struct ImuCalibration {
  float gyroBiasXDps = 0.0F;
  float gyroBiasYDps = 0.0F;
  float gyroBiasZDps = 0.0F;
  float mountingRollDegrees = 0.0F;
  float mountingPitchDegrees = 0.0F;
  float accelerationReferenceG = 1.0F;
  // Direction of the housing marker in the sensor tilt plane. The angle is
  // atan2(roll, pitch), measured while the pole top is tilted toward the
  // marker/operator. -90 degrees matches the documented +Y marker mounting.
  float markerDirectionDegrees = -90.0F;
  bool valid = false;
  bool markerValid = false;
};

enum class ImuCalibrationState : uint8_t {
  kRequired,
  kCollectingLevel,
  kCollectingMarker,
  kReady,
};

struct ImuReading {
  float rollDegrees = 0.0F;
  float pitchDegrees = 0.0F;
  float totalTiltDegrees = 0.0F;
  float markerDirectionDegrees = -90.0F;
  float accelerationMagnitudeG = 1.0F;
  float angularRateDps = 0.0F;
  bool moving = true;
  bool level = false;
  bool measurementReady = false;
  bool calibrated = false;
  bool directionCalibrated = false;
  uint16_t calibrationSamples = 0;
  uint32_t stableMilliseconds = 0;
  uint32_t readySequence = 0;
  ImuCalibrationState calibrationState = ImuCalibrationState::kRequired;
  uint32_t timestampMs = 0;
};

class ImuProcessor {
 public:
  static constexpr float kLevelThresholdDegrees = 0.5F;
  static constexpr uint32_t kReadyHoldMilliseconds = 400;
  static constexpr uint16_t kCalibrationSampleCount = 125;
  static constexpr uint16_t kMarkerCalibrationSampleCount = 30;

  ImuReading update(const ImuSample& sample);
  void beginCalibration();
  bool beginDirectionCalibration();
  void resetCalibration();
  void setCalibration(const ImuCalibration& calibration);

  const ImuCalibration& calibration() const { return calibration_; }
  const ImuReading& reading() const { return reading_; }
  bool takeCalibrationCompleted();

 private:
  static float radiansToDegrees(float radians);
  static float vectorMagnitude(float x, float y, float z);
  void resetCalibrationSums();

  ImuCalibration calibration_;
  ImuReading reading_;
  bool filterInitialized_ = false;
  bool hasTimestamp_ = false;
  bool calibrationCompleted_ = false;
  uint32_t previousTimestampMs_ = 0;
  uint32_t stableSinceMs_ = 0;
  uint32_t readySequence_ = 0;
  float filteredRollDegrees_ = 0.0F;
  float filteredPitchDegrees_ = 0.0F;

  uint16_t calibrationSamples_ = 0;
  float calibrationGyroXSum_ = 0.0F;
  float calibrationGyroYSum_ = 0.0F;
  float calibrationGyroZSum_ = 0.0F;
  float calibrationRollSum_ = 0.0F;
  float calibrationPitchSum_ = 0.0F;
  float calibrationAccelerationMagnitudeSum_ = 0.0F;
  float markerPitchSum_ = 0.0F;
  float markerRollSum_ = 0.0F;
  uint8_t markerRejectedSamples_ = 0;
};

const char* calibrationStateName(ImuCalibrationState state);

}  // namespace kataster
