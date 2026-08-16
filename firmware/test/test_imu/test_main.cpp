#include <unity.h>

#include <cmath>

#include "imu_processor.h"

namespace {

constexpr float kPi = 3.14159265358979323846F;

kataster::ImuSample sampleAt(float rollDegrees, float pitchDegrees,
                             uint32_t timestampMs,
                             float accelerationMagnitudeG = 1.0F) {
  const float roll = rollDegrees * kPi / 180.0F;
  const float pitch = pitchDegrees * kPi / 180.0F;
  kataster::ImuSample sample;
  sample.accelerationXG = -std::sin(pitch) * accelerationMagnitudeG;
  sample.accelerationYG =
      std::sin(roll) * std::cos(pitch) * accelerationMagnitudeG;
  sample.accelerationZG =
      std::cos(roll) * std::cos(pitch) * accelerationMagnitudeG;
  sample.timestampMs = timestampMs;
  return sample;
}

void setUp() {}
void tearDown() {}

void calibrateVertical(kataster::ImuProcessor& processor,
                       uint32_t& timestamp) {
  processor.beginCalibration();
  for (uint16_t index = 0;
       index < kataster::ImuProcessor::kCalibrationSampleCount; ++index) {
    processor.update(sampleAt(0.35F, -0.20F, timestamp));
    timestamp += 20;
  }
}

void calibrateDirection(kataster::ImuProcessor& processor,
                        uint32_t& timestamp) {
  processor.beginDirectionCalibration();
  for (uint16_t index = 0;
       index < kataster::ImuProcessor::kMarkerCalibrationSampleCount; ++index) {
    // Keep the housing marker toward the operator and tilt the pole top
    // toward it. In the documented mounting that is negative sensor roll.
    processor.update(sampleAt(-3.65F, -0.20F, timestamp));
    timestamp += 20;
  }
}

void calibrate(kataster::ImuProcessor& processor, uint32_t& timestamp) {
  calibrateVertical(processor, timestamp);
  calibrateDirection(processor, timestamp);
}

void testCalibrationRemovesMountingOffsetAndEnablesReadyGate() {
  kataster::ImuProcessor processor;
  uint32_t timestamp = 100;
  calibrate(processor, timestamp);

  TEST_ASSERT_EQUAL_UINT32(400,
                           kataster::ImuProcessor::kReadyHoldMilliseconds);
  TEST_ASSERT_TRUE(processor.calibration().valid);
  TEST_ASSERT_TRUE(processor.calibration().markerValid);
  TEST_ASSERT_TRUE(processor.takeCalibrationCompleted());
  TEST_ASSERT_FLOAT_WITHIN(0.01F, 0.35F,
                           processor.calibration().mountingRollDegrees);
  TEST_ASSERT_FLOAT_WITHIN(0.01F, -0.20F,
                           processor.calibration().mountingPitchDegrees);
  TEST_ASSERT_FLOAT_WITHIN(0.1F, -90.0F,
                           processor.calibration().markerDirectionDegrees);

  kataster::ImuReading reading;
  for (int index = 0; index < 100; ++index) {
    reading = processor.update(sampleAt(0.35F, -0.20F, timestamp));
    timestamp += 20;
  }
  TEST_ASSERT_TRUE(reading.calibrated);
  TEST_ASSERT_TRUE(reading.level);
  TEST_ASSERT_FALSE(reading.moving);
  TEST_ASSERT_TRUE(reading.measurementReady);
  TEST_ASSERT_GREATER_OR_EQUAL(
      kataster::ImuProcessor::kReadyHoldMilliseconds,
      reading.stableMilliseconds);
  TEST_ASSERT_EQUAL_UINT32(1, reading.readySequence);
  TEST_ASSERT_FLOAT_WITHIN(0.05F, 0.0F, reading.totalTiltDegrees);
}

void testReadySequenceAdvancesOnlyAfterLeavingAndReenteringLevel() {
  kataster::ImuProcessor processor;
  uint32_t timestamp = 100;
  calibrate(processor, timestamp);

  kataster::ImuReading reading;
  for (int index = 0; index < 120; ++index) {
    reading = processor.update(sampleAt(0.35F, -0.20F, timestamp));
    timestamp += 20;
  }
  TEST_ASSERT_EQUAL_UINT32(1, reading.readySequence);
  for (int index = 0; index < 20; ++index) {
    reading = processor.update(sampleAt(0.35F, -0.20F, timestamp));
    timestamp += 20;
  }
  TEST_ASSERT_EQUAL_UINT32(1, reading.readySequence);

  for (int index = 0; index < 100; ++index) {
    reading = processor.update(sampleAt(3.0F, 0.0F, timestamp));
    timestamp += 20;
  }
  TEST_ASSERT_FALSE(reading.measurementReady);
  for (int index = 0; index < 100; ++index) {
    reading = processor.update(sampleAt(0.35F, -0.20F, timestamp));
    timestamp += 20;
  }
  TEST_ASSERT_EQUAL_UINT32(2, reading.readySequence);
}

void testTiltClosesMeasurementGate() {
  kataster::ImuProcessor processor;
  uint32_t timestamp = 100;
  calibrate(processor, timestamp);

  kataster::ImuReading reading;
  for (int index = 0; index < 150; ++index) {
    reading = processor.update(sampleAt(3.0F, -2.0F, timestamp));
    timestamp += 20;
  }
  TEST_ASSERT_FALSE(reading.level);
  TEST_ASSERT_FALSE(reading.measurementReady);
  TEST_ASSERT_FLOAT_WITHIN(0.15F, std::sqrt(2.65F * 2.65F + 1.8F * 1.8F),
                           reading.totalTiltDegrees);
}

void testMeasurementMotionGateAllowsSmallHandMotion() {
  kataster::ImuProcessor processor;
  uint32_t timestamp = 100;
  calibrate(processor, timestamp);

  auto sample = sampleAt(0.35F, -0.20F, timestamp, 1.05F);
  sample.gyroXDps = 3.5F;
  auto reading = processor.update(sample);
  TEST_ASSERT_FALSE(reading.moving);

  timestamp += 20;
  sample = sampleAt(0.35F, -0.20F, timestamp, 1.07F);
  sample.gyroXDps = 4.5F;
  reading = processor.update(sample);
  TEST_ASSERT_TRUE(reading.moving);
}

void testMotionPreventsCalibrationProgress() {
  kataster::ImuProcessor processor;
  processor.beginCalibration();
  uint32_t timestamp = 100;
  for (int index = 0; index < 50; ++index) {
    auto sample = sampleAt(0.0F, 0.0F, timestamp);
    sample.gyroXDps = 40.0F;
    processor.update(sample);
    timestamp += 20;
  }
  TEST_ASSERT_FALSE(processor.calibration().valid);
  TEST_ASSERT_EQUAL_UINT16(0, processor.reading().calibrationSamples);
  TEST_ASSERT_EQUAL_STRING(
      "calibrating",
      kataster::calibrationStateName(processor.reading().calibrationState));
}

void testVerticalCalibrationCompletesWithoutDirectionCalibration() {
  kataster::ImuProcessor processor;
  uint32_t timestamp = 100;
  calibrateVertical(processor, timestamp);

  TEST_ASSERT_TRUE(processor.calibration().valid);
  TEST_ASSERT_FALSE(processor.calibration().markerValid);
  TEST_ASSERT_TRUE(processor.takeCalibrationCompleted());
  TEST_ASSERT_TRUE(processor.reading().calibrated);
  TEST_ASSERT_FALSE(processor.reading().directionCalibrated);
  TEST_ASSERT_FALSE(processor.reading().measurementReady);
  TEST_ASSERT_EQUAL_STRING(
      "ready",
      kataster::calibrationStateName(processor.reading().calibrationState));
  TEST_ASSERT_EQUAL_UINT16(0, processor.reading().calibrationSamples);
}

void testDirectionCalibrationRequiresVerticalCalibration() {
  kataster::ImuProcessor processor;
  TEST_ASSERT_FALSE(processor.beginDirectionCalibration());
  TEST_ASSERT_EQUAL_STRING(
      "required",
      kataster::calibrationStateName(processor.reading().calibrationState));
}

void testMarkerPhaseLearnsArbitraryHousingDirection() {
  kataster::ImuProcessor processor;
  processor.beginCalibration();
  uint32_t timestamp = 100;
  for (uint16_t index = 0;
       index < kataster::ImuProcessor::kCalibrationSampleCount; ++index) {
    processor.update(sampleAt(0.4F, -0.3F, timestamp));
    timestamp += 20;
  }
  TEST_ASSERT_TRUE(processor.beginDirectionCalibration());
  for (uint16_t index = 0;
       index < kataster::ImuProcessor::kMarkerCalibrationSampleCount; ++index) {
    // Corrected marker vector: pitch=4.33, roll=-2.5 => -30 degrees.
    processor.update(sampleAt(-2.1F, 4.03F, timestamp));
    timestamp += 20;
  }

  TEST_ASSERT_TRUE(processor.calibration().valid);
  TEST_ASSERT_TRUE(processor.takeCalibrationCompleted());
  TEST_ASSERT_FLOAT_WITHIN(0.2F, -30.0F,
                           processor.calibration().markerDirectionDegrees);
}

void testMarkerPhaseRequiresAStableTiltDirection() {
  kataster::ImuProcessor processor;
  processor.beginCalibration();
  uint32_t timestamp = 100;
  for (uint16_t index = 0;
       index < kataster::ImuProcessor::kCalibrationSampleCount; ++index) {
    processor.update(sampleAt(0.0F, 0.0F, timestamp));
    timestamp += 20;
  }
  TEST_ASSERT_TRUE(processor.beginDirectionCalibration());
  for (uint16_t index = 0;
       index < kataster::ImuProcessor::kMarkerCalibrationSampleCount; ++index) {
    const bool alternate = index % 2 == 0;
    processor.update(sampleAt(alternate ? -4.0F : 0.0F,
                              alternate ? 0.0F : 4.0F, timestamp));
    timestamp += 20;
  }

  TEST_ASSERT_TRUE(processor.calibration().valid);
  TEST_ASSERT_FALSE(processor.calibration().markerValid);
  TEST_ASSERT_FALSE(processor.reading().directionCalibrated);
}

void testMarkerPhaseToleratesFiveRejectedSamples() {
  kataster::ImuProcessor processor;
  uint32_t timestamp = 100;
  calibrateVertical(processor, timestamp);
  TEST_ASSERT_TRUE(processor.beginDirectionCalibration());

  for (int index = 0; index < 10; ++index) {
    processor.update(sampleAt(-5.0F, 0.0F, timestamp));
    timestamp += 20;
  }
  for (int index = 0; index < 5; ++index) {
    processor.update(sampleAt(-25.0F, 0.0F, timestamp));
    timestamp += 20;
  }
  for (uint16_t index = 10;
       index < kataster::ImuProcessor::kMarkerCalibrationSampleCount; ++index) {
    processor.update(sampleAt(-5.0F, 0.0F, timestamp));
    timestamp += 20;
  }

  TEST_ASSERT_TRUE(processor.calibration().markerValid);
  TEST_ASSERT_TRUE(processor.reading().directionCalibrated);
}

void testMarkerPhaseResetsAfterSixRejectedSamples() {
  kataster::ImuProcessor processor;
  uint32_t timestamp = 100;
  calibrateVertical(processor, timestamp);
  TEST_ASSERT_TRUE(processor.beginDirectionCalibration());

  for (int index = 0; index < 15; ++index) {
    processor.update(sampleAt(-5.0F, 0.0F, timestamp));
    timestamp += 20;
  }
  for (int index = 0; index < 6; ++index) {
    processor.update(sampleAt(-25.0F, 0.0F, timestamp));
    timestamp += 20;
  }

  TEST_ASSERT_FALSE(processor.calibration().markerValid);
  TEST_ASSERT_EQUAL_UINT16(0, processor.reading().calibrationSamples);
}

void testCalibrationAcceptsAndRemovesStaticGyroBias() {
  kataster::ImuProcessor processor;
  processor.beginCalibration();
  uint32_t timestamp = 100;
  for (uint16_t index = 0;
       index < kataster::ImuProcessor::kCalibrationSampleCount; ++index) {
    auto sample = sampleAt(0.0F, 0.0F, timestamp);
    sample.gyroXDps = 8.0F;
    sample.gyroYDps = -3.0F;
    sample.gyroZDps = 2.0F;
    processor.update(sample);
    timestamp += 20;
  }
  TEST_ASSERT_TRUE(processor.beginDirectionCalibration());
  for (uint16_t index = 0;
       index < kataster::ImuProcessor::kMarkerCalibrationSampleCount; ++index) {
    auto sample = sampleAt(-4.0F, 0.0F, timestamp);
    sample.gyroXDps = 8.0F;
    sample.gyroYDps = -3.0F;
    sample.gyroZDps = 2.0F;
    processor.update(sample);
    timestamp += 20;
  }
  TEST_ASSERT_TRUE(processor.calibration().valid);
  TEST_ASSERT_FLOAT_WITHIN(0.01F, 8.0F,
                           processor.calibration().gyroBiasXDps);
  TEST_ASSERT_FLOAT_WITHIN(0.01F, -3.0F,
                           processor.calibration().gyroBiasYDps);
  TEST_ASSERT_FLOAT_WITHIN(0.01F, 2.0F,
                           processor.calibration().gyroBiasZDps);
}

void testCalibrationLearnsIndividualGravityReference() {
  kataster::ImuProcessor processor;
  processor.beginCalibration();
  uint32_t timestamp = 100;
  for (uint16_t index = 0;
       index < kataster::ImuProcessor::kCalibrationSampleCount; ++index) {
    auto sample = sampleAt(1.2F, -0.4F, timestamp, 0.907F);
    sample.gyroXDps = 1.9F;
    sample.gyroYDps = -0.2F;
    sample.gyroZDps = 0.1F;
    processor.update(sample);
    timestamp += 20;
  }
  TEST_ASSERT_TRUE(processor.beginDirectionCalibration());
  for (uint16_t index = 0;
       index < kataster::ImuProcessor::kMarkerCalibrationSampleCount; ++index) {
    auto sample = sampleAt(-2.8F, -0.4F, timestamp, 0.907F);
    sample.gyroXDps = 1.9F;
    sample.gyroYDps = -0.2F;
    sample.gyroZDps = 0.1F;
    processor.update(sample);
    timestamp += 20;
  }

  TEST_ASSERT_TRUE(processor.calibration().valid);
  TEST_ASSERT_FLOAT_WITHIN(
      0.001F, 0.907F, processor.calibration().accelerationReferenceG);

  kataster::ImuReading reading;
  for (int index = 0; index < 100; ++index) {
    auto sample = sampleAt(1.2F, -0.4F, timestamp, 0.907F);
    sample.gyroXDps = 1.9F;
    sample.gyroYDps = -0.2F;
    sample.gyroZDps = 0.1F;
    reading = processor.update(sample);
    timestamp += 20;
  }
  TEST_ASSERT_FALSE(reading.moving);
  TEST_ASSERT_TRUE(reading.measurementReady);
  TEST_ASSERT_FLOAT_WITHIN(0.001F, 1.0F,
                           reading.accelerationMagnitudeG);

  reading = processor.update(sampleAt(1.2F, -0.4F, timestamp, 1.0F));
  TEST_ASSERT_TRUE(reading.moving);
  TEST_ASSERT_FALSE(reading.measurementReady);
}

void testCalibrationRejectsImplausibleGravityMagnitude() {
  kataster::ImuProcessor processor;
  processor.beginCalibration();
  uint32_t timestamp = 100;
  for (int index = 0; index < 50; ++index) {
    processor.update(sampleAt(0.0F, 0.0F, timestamp, 0.5F));
    timestamp += 20;
  }
  TEST_ASSERT_FALSE(processor.calibration().valid);
  TEST_ASSERT_EQUAL_UINT16(0, processor.reading().calibrationSamples);
}

}  // namespace

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(testCalibrationRemovesMountingOffsetAndEnablesReadyGate);
  RUN_TEST(testTiltClosesMeasurementGate);
  RUN_TEST(testMeasurementMotionGateAllowsSmallHandMotion);
  RUN_TEST(testMotionPreventsCalibrationProgress);
  RUN_TEST(testVerticalCalibrationCompletesWithoutDirectionCalibration);
  RUN_TEST(testDirectionCalibrationRequiresVerticalCalibration);
  RUN_TEST(testMarkerPhaseLearnsArbitraryHousingDirection);
  RUN_TEST(testMarkerPhaseRequiresAStableTiltDirection);
  RUN_TEST(testMarkerPhaseToleratesFiveRejectedSamples);
  RUN_TEST(testMarkerPhaseResetsAfterSixRejectedSamples);
  RUN_TEST(testCalibrationAcceptsAndRemovesStaticGyroBias);
  RUN_TEST(testCalibrationLearnsIndividualGravityReference);
  RUN_TEST(testCalibrationRejectsImplausibleGravityMagnitude);
  RUN_TEST(testReadySequenceAdvancesOnlyAfterLeavingAndReenteringLevel);
  return UNITY_END();
}
