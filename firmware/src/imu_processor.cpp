#include "imu_processor.h"

#include <algorithm>
#include <cmath>

namespace kataster {
namespace {

constexpr float kPi = 3.14159265358979323846F;
constexpr float kFilterTimeConstantSeconds = 0.35F;
constexpr float kMovingAccelerationToleranceG = 0.06F;
constexpr float kMovingAngularRateDps = 4.0F;
constexpr float kCalibrationAngularRateDps = 25.0F;
constexpr float kCalibrationMinimumAccelerationG = 0.75F;
constexpr float kCalibrationMaximumAccelerationG = 1.25F;
constexpr float kCalibrationAccelerationVariationG = 0.025F;
constexpr float kMarkerCalibrationMinimumTiltDegrees = 3.0F;
constexpr float kMarkerCalibrationMaximumTiltDegrees = 20.0F;
constexpr float kMarkerCalibrationAngularRateDps = 5.0F;
constexpr float kMarkerCalibrationDirectionCosine = 0.9781476F;  // 12 degrees
constexpr uint8_t kMarkerCalibrationAllowedRejectedSamples = 5;

float clamp(float value, float lower, float upper) {
  return std::max(lower, std::min(value, upper));
}

}  // namespace

float ImuProcessor::radiansToDegrees(float radians) {
  return radians * 180.0F / kPi;
}

float ImuProcessor::vectorMagnitude(float x, float y, float z) {
  return std::sqrt(x * x + y * y + z * z);
}

const char* calibrationStateName(ImuCalibrationState state) {
  switch (state) {
    case ImuCalibrationState::kCollectingLevel:
      return "calibrating";
    case ImuCalibrationState::kCollectingMarker:
      return "aligning";
    case ImuCalibrationState::kReady:
      return "ready";
    case ImuCalibrationState::kRequired:
    default:
      return "required";
  }
}

void ImuProcessor::resetCalibrationSums() {
  calibrationSamples_ = 0;
  calibrationGyroXSum_ = 0.0F;
  calibrationGyroYSum_ = 0.0F;
  calibrationGyroZSum_ = 0.0F;
  calibrationRollSum_ = 0.0F;
  calibrationPitchSum_ = 0.0F;
  calibrationAccelerationMagnitudeSum_ = 0.0F;
  markerPitchSum_ = 0.0F;
  markerRollSum_ = 0.0F;
  markerRejectedSamples_ = 0;
}

void ImuProcessor::beginCalibration() {
  calibration_ = {};
  resetCalibrationSums();
  calibrationCompleted_ = false;
  stableSinceMs_ = 0;
  readySequence_ = 0;
  reading_.calibrated = false;
  reading_.directionCalibrated = false;
  reading_.calibrationState = ImuCalibrationState::kCollectingLevel;
  reading_.calibrationSamples = 0;
  reading_.stableMilliseconds = 0;
  reading_.measurementReady = false;
}

bool ImuProcessor::beginDirectionCalibration() {
  if (!calibration_.valid) {
    return false;
  }
  resetCalibrationSums();
  calibrationCompleted_ = false;
  stableSinceMs_ = 0;
  readySequence_ = 0;
  calibration_.markerValid = false;
  reading_.calibrated = true;
  reading_.directionCalibrated = false;
  reading_.calibrationState = ImuCalibrationState::kCollectingMarker;
  reading_.calibrationSamples = 0;
  reading_.stableMilliseconds = 0;
  reading_.measurementReady = false;
  return true;
}

void ImuProcessor::resetCalibration() {
  calibration_ = {};
  resetCalibrationSums();
  calibrationCompleted_ = false;
  filterInitialized_ = false;
  stableSinceMs_ = 0;
  readySequence_ = 0;
  reading_.calibrated = false;
  reading_.directionCalibrated = false;
  reading_.calibrationState = ImuCalibrationState::kRequired;
  reading_.calibrationSamples = 0;
  reading_.stableMilliseconds = 0;
  reading_.measurementReady = false;
}

void ImuProcessor::setCalibration(const ImuCalibration& calibration) {
  calibration_ = calibration;
  resetCalibrationSums();
  calibrationCompleted_ = false;
  filterInitialized_ = false;
  stableSinceMs_ = 0;
  readySequence_ = 0;
  reading_.calibrated = calibration.valid;
  reading_.directionCalibrated =
      calibration.valid && calibration.markerValid;
  reading_.calibrationState = calibration.valid
                                  ? ImuCalibrationState::kReady
                                  : ImuCalibrationState::kRequired;
  reading_.calibrationSamples = 0;
  reading_.markerDirectionDegrees = calibration.markerDirectionDegrees;
  reading_.stableMilliseconds = 0;
  reading_.measurementReady = false;
}

bool ImuProcessor::takeCalibrationCompleted() {
  const bool completed = calibrationCompleted_;
  calibrationCompleted_ = false;
  return completed;
}

ImuReading ImuProcessor::update(const ImuSample& sample) {
  const float accelerationMagnitude =
      vectorMagnitude(sample.accelerationXG, sample.accelerationYG,
                      sample.accelerationZG);
  const float rawAngularRate =
      vectorMagnitude(sample.gyroXDps, sample.gyroYDps, sample.gyroZDps);
  const float rawRoll = radiansToDegrees(
      std::atan2(sample.accelerationYG, sample.accelerationZG));
  const float rawPitch = radiansToDegrees(std::atan2(
      -sample.accelerationXG,
      std::sqrt(sample.accelerationYG * sample.accelerationYG +
                sample.accelerationZG * sample.accelerationZG)));

  if (reading_.calibrationState == ImuCalibrationState::kCollectingLevel) {
    const float runningAccelerationMean =
        calibrationSamples_ == 0
            ? accelerationMagnitude
            : calibrationAccelerationMagnitudeSum_ /
                  static_cast<float>(calibrationSamples_);
    const bool calibrationSampleStable =
        accelerationMagnitude >= kCalibrationMinimumAccelerationG &&
        accelerationMagnitude <= kCalibrationMaximumAccelerationG &&
        std::fabs(accelerationMagnitude - runningAccelerationMean) <=
            kCalibrationAccelerationVariationG &&
        rawAngularRate <= kCalibrationAngularRateDps;
    if (calibrationSampleStable) {
      calibrationGyroXSum_ += sample.gyroXDps;
      calibrationGyroYSum_ += sample.gyroYDps;
      calibrationGyroZSum_ += sample.gyroZDps;
      calibrationRollSum_ += rawRoll;
      calibrationPitchSum_ += rawPitch;
      calibrationAccelerationMagnitudeSum_ += accelerationMagnitude;
      ++calibrationSamples_;
    } else {
      resetCalibrationSums();
    }

    if (calibrationSamples_ >= kCalibrationSampleCount) {
      const float divisor = static_cast<float>(calibrationSamples_);
      calibration_.gyroBiasXDps = calibrationGyroXSum_ / divisor;
      calibration_.gyroBiasYDps = calibrationGyroYSum_ / divisor;
      calibration_.gyroBiasZDps = calibrationGyroZSum_ / divisor;
      calibration_.mountingRollDegrees = calibrationRollSum_ / divisor;
      calibration_.mountingPitchDegrees = calibrationPitchSum_ / divisor;
      calibration_.accelerationReferenceG =
          calibrationAccelerationMagnitudeSum_ / divisor;
      calibration_.valid = true;
      calibration_.markerValid = false;
      calibrationCompleted_ = true;
      resetCalibrationSums();
      filterInitialized_ = false;
      reading_.calibrationState = ImuCalibrationState::kReady;
    }
  }

  const float gyroX = sample.gyroXDps - calibration_.gyroBiasXDps;
  const float gyroY = sample.gyroYDps - calibration_.gyroBiasYDps;
  const float gyroZ = sample.gyroZDps - calibration_.gyroBiasZDps;
  const float angularRate = vectorMagnitude(gyroX, gyroY, gyroZ);
  const float accelerationReference =
      calibration_.accelerationReferenceG >=
                  kCalibrationMinimumAccelerationG &&
              calibration_.accelerationReferenceG <=
                  kCalibrationMaximumAccelerationG
          ? calibration_.accelerationReferenceG
          : 1.0F;
  const float normalizedAccelerationMagnitude =
      accelerationMagnitude / accelerationReference;
  const float accelerationRoll = rawRoll - calibration_.mountingRollDegrees;
  const float accelerationPitch = rawPitch - calibration_.mountingPitchDegrees;

  if (reading_.calibrationState == ImuCalibrationState::kCollectingMarker) {
    const float markerTilt =
        vectorMagnitude(accelerationPitch, accelerationRoll, 0.0F);
    const bool markerSampleStable =
        std::fabs(normalizedAccelerationMagnitude - 1.0F) <=
            kCalibrationAccelerationVariationG &&
        angularRate <= kMarkerCalibrationAngularRateDps &&
        markerTilt >= kMarkerCalibrationMinimumTiltDegrees &&
        markerTilt <= kMarkerCalibrationMaximumTiltDegrees;
    const float markerSumMagnitude =
        vectorMagnitude(markerPitchSum_, markerRollSum_, 0.0F);
    const bool directionConsistent =
        calibrationSamples_ == 0 ||
        accelerationPitch * markerPitchSum_ +
                accelerationRoll * markerRollSum_ >=
            kMarkerCalibrationDirectionCosine * markerTilt *
                markerSumMagnitude;

    if (markerSampleStable && directionConsistent) {
      if (calibrationSamples_ == 0) {
        markerRejectedSamples_ = 0;
      }
      markerPitchSum_ += accelerationPitch;
      markerRollSum_ += accelerationRoll;
      ++calibrationSamples_;
    } else if (calibrationSamples_ > 0 &&
               ++markerRejectedSamples_ >
                   kMarkerCalibrationAllowedRejectedSamples) {
      calibrationSamples_ = 0;
      markerPitchSum_ = 0.0F;
      markerRollSum_ = 0.0F;
      markerRejectedSamples_ = 0;
    }

    if (calibrationSamples_ >= kMarkerCalibrationSampleCount) {
      calibration_.markerDirectionDegrees = radiansToDegrees(
          std::atan2(markerRollSum_, markerPitchSum_));
      calibration_.markerValid = true;
      calibrationCompleted_ = true;
      filterInitialized_ = false;
      reading_.calibrationState = ImuCalibrationState::kReady;
    }
  }

  float deltaSeconds = 0.02F;
  if (hasTimestamp_) {
    deltaSeconds = static_cast<float>(sample.timestampMs - previousTimestampMs_) /
                   1000.0F;
    deltaSeconds = clamp(deltaSeconds, 0.001F, 0.2F);
  }
  previousTimestampMs_ = sample.timestampMs;
  hasTimestamp_ = true;

  if (!filterInitialized_) {
    filteredRollDegrees_ = accelerationRoll;
    filteredPitchDegrees_ = accelerationPitch;
    filterInitialized_ = true;
  } else {
    const float alpha = kFilterTimeConstantSeconds /
                        (kFilterTimeConstantSeconds + deltaSeconds);
    filteredRollDegrees_ =
        alpha * (filteredRollDegrees_ + gyroX * deltaSeconds) +
        (1.0F - alpha) * accelerationRoll;
    filteredPitchDegrees_ =
        alpha * (filteredPitchDegrees_ + gyroY * deltaSeconds) +
        (1.0F - alpha) * accelerationPitch;
  }

  const float rollRadians = filteredRollDegrees_ * kPi / 180.0F;
  const float pitchRadians = filteredPitchDegrees_ * kPi / 180.0F;
  const float totalTilt = radiansToDegrees(
      std::acos(clamp(std::cos(rollRadians) * std::cos(pitchRadians),
                      -1.0F, 1.0F)));
  const bool moving =
      std::fabs(normalizedAccelerationMagnitude - 1.0F) >
          kMovingAccelerationToleranceG ||
      angularRate > kMovingAngularRateDps;
  const bool calibrated = calibration_.valid;
  const bool directionCalibrated = calibrated && calibration_.markerValid;
  const bool level = calibrated && totalTilt <= kLevelThresholdDegrees;

  if (!moving && level) {
    if (stableSinceMs_ == 0) {
      stableSinceMs_ = sample.timestampMs == 0 ? 1 : sample.timestampMs;
    }
  } else {
    stableSinceMs_ = 0;
  }
  const uint32_t stableMilliseconds = stableSinceMs_ == 0
                                          ? 0
                                          : sample.timestampMs - stableSinceMs_;
  const bool heldLongEnough =
      stableSinceMs_ != 0 && stableMilliseconds >= kReadyHoldMilliseconds;
  const bool measurementReady =
      calibrated && directionCalibrated && heldLongEnough;
  if (measurementReady && !reading_.measurementReady) {
    ++readySequence_;
  }

  reading_.rollDegrees = filteredRollDegrees_;
  reading_.pitchDegrees = filteredPitchDegrees_;
  reading_.totalTiltDegrees = totalTilt;
  reading_.markerDirectionDegrees = calibration_.markerDirectionDegrees;
  reading_.accelerationMagnitudeG = normalizedAccelerationMagnitude;
  reading_.angularRateDps = angularRate;
  reading_.moving = moving;
  reading_.level = level;
  reading_.measurementReady = measurementReady;
  reading_.calibrated = calibrated;
  reading_.directionCalibrated = directionCalibrated;
  reading_.calibrationSamples = calibrationSamples_;
  reading_.stableMilliseconds = stableMilliseconds;
  reading_.readySequence = readySequence_;
  reading_.timestampMs = sample.timestampMs;
  return reading_;
}

}  // namespace kataster
