#include <Arduino.h>
#include <NimBLEDevice.h>
#include <Preferences.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>

#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "imu_processor.h"
#include "imu_source.h"
#include "rtcm_parser.h"
#include "transport_protocol.h"

#ifndef KATASTER_IMU_SDA
#define KATASTER_IMU_SDA 8
#endif

#ifndef KATASTER_IMU_SCL
#define KATASTER_IMU_SCL 9
#endif

#ifndef KATASTER_LG290P_RX
#define KATASTER_LG290P_RX 7
#endif

#ifndef KATASTER_LG290P_TX
#define KATASTER_LG290P_TX 10
#endif

#ifndef KATASTER_LG290P_BAUD
#define KATASTER_LG290P_BAUD 460800
#endif

#ifndef KATASTER_GNSS_SIMULATION
#define KATASTER_GNSS_SIMULATION 0
#endif

namespace {

constexpr std::size_t kMaximumBleValue = 512;
constexpr std::size_t kRtcmQueueDepth = 20;
constexpr std::size_t kGnssPayloadSize = 160;
constexpr uint32_t kImuCalibrationMagic = 0x4B494D34U;  // KIM4

struct StoredImuCalibration {
  uint32_t magic = kImuCalibrationMagic;
  kataster::ImuCalibration calibration;
};

struct BlePacket {
  uint16_t length = 0;
  uint8_t bytes[kMaximumBleValue]{};
};

struct TransportStats {
  uint32_t rtcmBytes = 0;
  uint32_t rtcmFrames = 0;
  uint32_t rtcmCrcErrors = 0;
  uint32_t sequenceGaps = 0;
  uint32_t queueDrops = 0;
  uint32_t lastValidRtcmMs = 0;
  bool hasValidRtcm = false;
};

enum class DummyMode { kStatic, kWalk, kQuality };

QueueHandle_t rtcmQueue = nullptr;
NimBLECharacteristic* gnssCharacteristic = nullptr;
NimBLECharacteristic* statusCharacteristic = nullptr;
NimBLECharacteristic* controlCharacteristic = nullptr;
NimBLECharacteristic* imuCharacteristic = nullptr;

portMUX_TYPE statsMux = portMUX_INITIALIZER_UNLOCKED;
TransportStats transportStats;
volatile bool bleConnected = false;
volatile DummyMode dummyMode = DummyMode::kWalk;
volatile kataster::SimulatedImuMode requestedImuMode =
    kataster::SimulatedImuMode::kLevel;
volatile bool imuCalibrationRequested = false;
volatile bool imuDirectionCalibrationRequested = false;
volatile bool imuCalibrationResetRequested = false;
volatile bool imuHardwarePresent = false;
volatile uint32_t imuHardwareSamples = 0;
volatile uint32_t lg290pRxBytes = 0;
volatile uint32_t lg290pValidNmeaSentences = 0;

kataster::Mpu6050Source mpu6050(Wire, KATASTER_IMU_SDA, KATASTER_IMU_SCL);
kataster::SimulatedImuSource simulatedImu;
HardwareSerial lg290pSerial(1);

uint8_t gnssSession = 1;
uint16_t gnssSequence = 0;

const char* modeName(DummyMode mode) {
  switch (mode) {
    case DummyMode::kStatic:
      return "static";
    case DummyMode::kQuality:
      return "quality";
    case DummyMode::kWalk:
    default:
      return "walk";
  }
}

const char* gnssModeName() {
#if KATASTER_GNSS_SIMULATION
  return modeName(dummyMode);
#else
  return "lg290p";
#endif
}

void resetTransportStats() {
  portENTER_CRITICAL(&statsMux);
  transportStats = {};
  portEXIT_CRITICAL(&statsMux);
}

void onValidRtcmFrame(const uint8_t* frame, std::size_t length,
                      uint16_t messageType, void*) {
  portENTER_CRITICAL(&statsMux);
  ++transportStats.rtcmFrames;
  transportStats.lastValidRtcmMs = millis();
  transportStats.hasValidRtcm = true;
  portEXIT_CRITICAL(&statsMux);

#if !KATASTER_GNSS_SIMULATION
  const std::size_t written = lg290pSerial.write(frame, length);
  if (written != length) {
    Serial.printf("LG290P RTCM write incomplete: %u/%u bytes\n",
                  static_cast<unsigned>(written),
                  static_cast<unsigned>(length));
  }
#endif

  if ((transportStats.rtcmFrames % 25U) == 1U) {
    Serial.printf("RTCM valid: type=%u frames=%lu\n", messageType,
                  static_cast<unsigned long>(transportStats.rtcmFrames));
  }
}

class RoverServerCallbacks final : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer*, NimBLEConnInfo&) override {
    bleConnected = true;
    ++gnssSession;
    gnssSequence = 0;
    Serial.println("BLE central connected");
  }

  void onDisconnect(NimBLEServer*, NimBLEConnInfo&, int reason) override {
    bleConnected = false;
    Serial.printf("BLE central disconnected, reason=%d\n", reason);
  }
};

class RtcmCallbacks final : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* characteristic,
               NimBLEConnInfo&) override {
    const NimBLEAttValue value = characteristic->getValue();
    if (value.size() < kataster::kStreamHeaderSize ||
        value.size() > kMaximumBleValue) {
      return;
    }

    BlePacket packet;
    packet.length = static_cast<uint16_t>(value.size());
    std::memcpy(packet.bytes, value.data(), value.size());
    if (xQueueSend(rtcmQueue, &packet, 0) != pdTRUE) {
      portENTER_CRITICAL(&statsMux);
      ++transportStats.queueDrops;
      portEXIT_CRITICAL(&statsMux);
    }
  }
};

class ControlCallbacks final : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* characteristic,
               NimBLEConnInfo&) override {
    const std::string value = characteristic->getValue();
    if (value.find("resetStats") != std::string::npos) {
      resetTransportStats();
      Serial.println("Transport statistics reset");
    }
    if (value.find("static") != std::string::npos) {
      dummyMode = DummyMode::kStatic;
    } else if (value.find("quality") != std::string::npos) {
      dummyMode = DummyMode::kQuality;
    } else if (value.find("walk") != std::string::npos) {
      dummyMode = DummyMode::kWalk;
    }
    if (value.find("imuMode") != std::string::npos) {
      if (value.find("forward") != std::string::npos) {
        requestedImuMode = kataster::SimulatedImuMode::kForward;
      } else if (value.find("backward") != std::string::npos) {
        requestedImuMode = kataster::SimulatedImuMode::kBackward;
      } else if (value.find("left") != std::string::npos) {
        requestedImuMode = kataster::SimulatedImuMode::kLeft;
      } else if (value.find("right") != std::string::npos) {
        requestedImuMode = kataster::SimulatedImuMode::kRight;
      } else if (value.find("tilted") != std::string::npos) {
        requestedImuMode = kataster::SimulatedImuMode::kTilted;
      } else if (value.find("motion") != std::string::npos) {
        requestedImuMode = kataster::SimulatedImuMode::kMotion;
      } else if (value.find("level") != std::string::npos) {
        requestedImuMode = kataster::SimulatedImuMode::kLevel;
      }
    }
    if (value.find("\"calibrateImuDirection\"") != std::string::npos) {
      imuDirectionCalibrationRequested = true;
    } else if (value.find("\"calibrateImu\"") != std::string::npos) {
      imuCalibrationRequested = true;
    }
    if (value.find("resetImuCalibration") != std::string::npos) {
      imuCalibrationResetRequested = true;
    }
  }
};

bool loadImuCalibration(Preferences& preferences, const char* key,
                        kataster::ImuCalibration& calibration) {
  if (preferences.getBytesLength(key) != sizeof(StoredImuCalibration)) {
    return false;
  }
  StoredImuCalibration stored;
  if (preferences.getBytes(key, &stored, sizeof(stored)) != sizeof(stored) ||
      stored.magic != kImuCalibrationMagic || !stored.calibration.valid) {
    return false;
  }
  calibration = stored.calibration;
  return true;
}

void saveImuCalibration(Preferences& preferences, const char* key,
                        const kataster::ImuCalibration& calibration) {
  StoredImuCalibration stored;
  stored.calibration = calibration;
  preferences.putBytes(key, &stored, sizeof(stored));
}

void publishImu(const kataster::ImuReading& reading, const char* source,
                bool simulation, uint32_t ageMilliseconds) {
  if (imuCharacteristic == nullptr) {
    return;
  }
  const bool available = ageMilliseconds < 500U;
  char json[380]{};
  std::snprintf(
      json, sizeof(json),
      "{\"v\":1,\"s\":\"%s\",\"x\":%s,\"r\":%.3f,\"p\":%.3f,"
      "\"t\":%.3f,\"k\":%.3f,\"a\":%.4f,\"g\":%.3f,\"m\":%s,\"l\":%s,"
      "\"o\":%s,\"c\":%s,\"y\":%s,\"q\":\"%s\",\"n\":%u,\"u\":%s,"
      "\"d\":%lu,\"h\":%lu,\"e\":%lu}",
      source, simulation ? "true" : "false", reading.rollDegrees,
      reading.pitchDegrees, reading.totalTiltDegrees,
      reading.markerDirectionDegrees,
      reading.accelerationMagnitudeG, reading.angularRateDps,
      reading.moving ? "true" : "false",
      reading.level ? "true" : "false",
      reading.measurementReady ? "true" : "false",
      reading.calibrated ? "true" : "false",
      reading.directionCalibrated ? "true" : "false",
      kataster::calibrationStateName(reading.calibrationState),
      reading.calibrationSamples, available ? "true" : "false",
      static_cast<unsigned long>(ageMilliseconds),
      static_cast<unsigned long>(reading.stableMilliseconds),
      static_cast<unsigned long>(reading.readySequence));
  imuCharacteristic->setValue(json);
  if (bleConnected) {
    imuCharacteristic->notify();
  }
}

void imuTask(void*) {
  kataster::ImuSource* source = nullptr;
  if (mpu6050.begin()) {
    source = &mpu6050;
    imuHardwarePresent = true;
    Serial.printf("GY-521 detected: MPU-6050 at 0x%02X, SDA=%d, SCL=%d\n",
                  mpu6050.address(), KATASTER_IMU_SDA, KATASTER_IMU_SCL);
  } else {
    simulatedImu.begin();
    source = &simulatedImu;
    Serial.printf(
        "No MPU-6050 detected on SDA=%d/SCL=%d; IMU simulator active\n",
        KATASTER_IMU_SDA, KATASTER_IMU_SCL);
  }

  Preferences preferences;
  preferences.begin("kataster-imu", false);
  const char* calibrationKey = source->isSimulation() ? "sim-cal" : "mpu-cal";
  kataster::ImuProcessor processor;
  kataster::ImuCalibration storedCalibration;
  if (loadImuCalibration(preferences, calibrationKey, storedCalibration)) {
    processor.setCalibration(storedCalibration);
    Serial.printf("IMU calibration loaded for %s (direction=%s)\n",
                  source->name(),
                  storedCalibration.markerValid ? "calibrated" : "required");
  }

  kataster::ImuReading latest;
  uint32_t lastSampleMs = 0;
  uint32_t lastPublishMs = 0;
  while (true) {
    if (source->isSimulation()) {
      simulatedImu.setMode(requestedImuMode);
    }
    if (imuCalibrationResetRequested) {
      imuCalibrationResetRequested = false;
      processor.resetCalibration();
      preferences.remove(calibrationKey);
      Serial.println("IMU calibration reset");
    }
    if (imuCalibrationRequested) {
      imuCalibrationRequested = false;
      processor.beginCalibration();
      Serial.println("IMU vertical calibration started; hold pole still and vertical");
    }
    if (imuDirectionCalibrationRequested) {
      imuDirectionCalibrationRequested = false;
      if (processor.beginDirectionCalibration()) {
        Serial.println(
            "IMU direction calibration started; tilt pole top 3-20 degrees "
            "toward the housing marker");
      } else {
        Serial.println(
            "IMU direction calibration rejected: vertical calibration required");
      }
    }

    kataster::ImuSample sample;
    if (source->read(sample)) {
      if (!source->isSimulation()) {
        ++imuHardwareSamples;
      }
      latest = processor.update(sample);
      lastSampleMs = sample.timestampMs;
      if (processor.takeCalibrationCompleted()) {
        saveImuCalibration(preferences, calibrationKey,
                           processor.calibration());
        if (processor.calibration().markerValid) {
          Serial.printf(
              "IMU direction calibration completed and stored (marker=%.2f "
              "deg)\n",
              processor.calibration().markerDirectionDegrees);
        } else {
          Serial.printf(
              "IMU vertical calibration completed and stored (1g=%.4f g); "
              "direction calibration remains separate\n",
              processor.calibration().accelerationReferenceG);
        }
      }
    }

    const uint32_t now = millis();
    if (now - lastPublishMs >= 100U) {
      const uint32_t age = lastSampleMs == 0 ? UINT32_MAX : now - lastSampleMs;
      publishImu(latest, source->name(), source->isSimulation(), age);
      lastPublishMs = now;
    }
    vTaskDelay(pdMS_TO_TICKS(20));
  }
}

void rtcmTask(void*) {
  kataster::RtcmParser parser(onValidRtcmFrame);
  bool hasSession = false;
  uint8_t currentSession = 0;
  uint16_t expectedSequence = 0;
  uint32_t previousCrcErrors = 0;

  BlePacket packet;
  while (true) {
    if (xQueueReceive(rtcmQueue, &packet, portMAX_DELAY) != pdTRUE) {
      continue;
    }
    if (packet.length < kataster::kStreamHeaderSize ||
        packet.bytes[0] != kataster::kProtocolVersion) {
      continue;
    }

    const uint8_t session = packet.bytes[1];
    const uint16_t sequence = kataster::decodeSequence(packet.bytes);
    if (!hasSession || session != currentSession) {
      currentSession = session;
      expectedSequence = sequence;
      hasSession = true;
      parser.reset();
    }
    if (sequence != expectedSequence) {
      portENTER_CRITICAL(&statsMux);
      ++transportStats.sequenceGaps;
      portEXIT_CRITICAL(&statsMux);
      parser.reset();
    }
    expectedSequence = static_cast<uint16_t>(sequence + 1U);

    const std::size_t payloadLength =
        packet.length - kataster::kStreamHeaderSize;
    portENTER_CRITICAL(&statsMux);
    transportStats.rtcmBytes += static_cast<uint32_t>(payloadLength);
    portEXIT_CRITICAL(&statsMux);

    parser.feed(packet.bytes + kataster::kStreamHeaderSize, payloadLength);
    const uint32_t crcErrors = parser.crcErrors();
    if (crcErrors != previousCrcErrors) {
      portENTER_CRITICAL(&statsMux);
      transportStats.rtcmCrcErrors += crcErrors - previousCrcErrors;
      portEXIT_CRITICAL(&statsMux);
      previousCrcErrors = crcErrors;
    }
  }
}

uint8_t nmeaChecksum(const char* body) {
  uint8_t checksum = 0;
  while (*body != '\0') {
    checksum ^= static_cast<uint8_t>(*body++);
  }
  return checksum;
}

void notifyGnssBytes(const uint8_t* bytes, std::size_t length) {
  if (!bleConnected || gnssCharacteristic == nullptr) {
    return;
  }

  std::size_t offset = 0;
  while (offset < length) {
    const std::size_t payloadLength =
        std::min(kGnssPayloadSize, length - offset);
    uint8_t packet[kGnssPayloadSize + kataster::kStreamHeaderSize]{};
    kataster::encodeHeader(packet, gnssSession, gnssSequence++);
    std::memcpy(packet + kataster::kStreamHeaderSize, bytes + offset,
                payloadLength);
    if (!gnssCharacteristic->notify(packet,
                                    payloadLength +
                                        kataster::kStreamHeaderSize)) {
      break;
    }
    offset += payloadLength;
  }
}

void notifyNmeaBody(const char* body) {
  char sentence[196]{};
  std::snprintf(sentence, sizeof(sentence), "$%s*%02X\r\n", body,
                nmeaChecksum(body));
  notifyGnssBytes(reinterpret_cast<const uint8_t*>(sentence),
                  std::strlen(sentence));
}

int nmeaHexValue(char value) {
  if (value >= '0' && value <= '9') {
    return value - '0';
  }
  if (value >= 'A' && value <= 'F') {
    return value - 'A' + 10;
  }
  if (value >= 'a' && value <= 'f') {
    return value - 'a' + 10;
  }
  return -1;
}

bool hasValidNmeaChecksum(const char* sentence, std::size_t length) {
  if (sentence == nullptr || length < 7 || sentence[0] != '$') {
    return false;
  }

  uint8_t calculated = 0;
  std::size_t checksumPosition = 0;
  for (std::size_t index = 1; index < length; ++index) {
    if (sentence[index] == '*') {
      checksumPosition = index;
      break;
    }
    calculated ^= static_cast<uint8_t>(sentence[index]);
  }

  if (checksumPosition == 0 || checksumPosition + 2 >= length) {
    return false;
  }
  const int high = nmeaHexValue(sentence[checksumPosition + 1]);
  const int low = nmeaHexValue(sentence[checksumPosition + 2]);
  return high >= 0 && low >= 0 &&
         calculated == static_cast<uint8_t>((high << 4) | low);
}

void lg290pGnssTask(void*) {
  uint8_t buffer[256]{};
  bool receptionAnnounced = false;
  bool validNmeaAnnounced = false;
  char sentence[192]{};
  std::size_t sentenceLength = 0;

  while (true) {
    const int available = lg290pSerial.available();
    if (available <= 0) {
      vTaskDelay(pdMS_TO_TICKS(2));
      continue;
    }

    const std::size_t requested =
        std::min<std::size_t>(static_cast<std::size_t>(available),
                              sizeof(buffer));
    std::size_t received = 0;
    while (received < requested) {
      const int value = lg290pSerial.read();
      if (value < 0) {
        break;
      }
      buffer[received++] = static_cast<uint8_t>(value);
    }

    if (received > 0) {
      lg290pRxBytes += static_cast<uint32_t>(received);
      if (!receptionAnnounced) {
        receptionAnnounced = true;
        Serial.println("LG290P UART data received");
      }
      for (std::size_t index = 0; index < received; ++index) {
        const char value = static_cast<char>(buffer[index]);
        if (value == '$') {
          sentence[0] = value;
          sentenceLength = 1;
        } else if (sentenceLength > 0 && value == '\n') {
          sentence[sentenceLength] = '\0';
          if (hasValidNmeaChecksum(sentence, sentenceLength)) {
            ++lg290pValidNmeaSentences;
            if (!validNmeaAnnounced) {
              validNmeaAnnounced = true;
              Serial.printf("LG290P NMEA verified: %.6s checksum OK\n",
                            sentence);
            }
          }
          sentenceLength = 0;
        } else if (sentenceLength > 0) {
          if (sentenceLength + 1 < sizeof(sentence)) {
            sentence[sentenceLength++] = value;
          } else {
            sentenceLength = 0;
          }
        }
      }
      notifyGnssBytes(buffer, received);
    }
    vTaskDelay(pdMS_TO_TICKS(1));
  }
}

void formatCoordinate(double degrees, bool latitude, char* value,
                      std::size_t valueSize, char* hemisphere) {
  const double absolute = std::fabs(degrees);
  const int wholeDegrees = static_cast<int>(absolute);
  const double minutes = (absolute - wholeDegrees) * 60.0;
  if (latitude) {
    std::snprintf(value, valueSize, "%02d%08.5f", wholeDegrees, minutes);
    *hemisphere = degrees >= 0 ? 'N' : 'S';
  } else {
    std::snprintf(value, valueSize, "%03d%08.5f", wholeDegrees, minutes);
    *hemisphere = degrees >= 0 ? 'E' : 'W';
  }
}

void dummyGnssTask(void*) {
  while (true) {
    const uint32_t now = millis();
    const DummyMode mode = dummyMode;
    // Deliberately synthetic demo coordinates; do not encode a private test site.
    double latitude = 51.0;
    double longitude = 7.0;
    int quality = 4;
    const char* qualityText = "RTK FIX";

    if (mode == DummyMode::kWalk) {
      const double phase = static_cast<double>(now % 120000U) / 120000.0;
      latitude = 50.9998 + phase * (51.0002 - 50.9998);
      longitude = 6.9997 + phase * (7.0003 - 6.9997);
    } else if (mode == DummyMode::kQuality) {
      switch ((now / 10000U) % 3U) {
        case 0:
          quality = 1;
          qualityText = "SINGLE";
          break;
        case 1:
          quality = 5;
          qualityText = "RTK FLOAT";
          break;
        default:
          quality = 4;
          qualityText = "RTK FIX";
          break;
      }
    }

    const uint32_t secondsOfDay = (12U * 3600U + now / 1000U) % 86400U;
    const unsigned hour = secondsOfDay / 3600U;
    const unsigned minute = (secondsOfDay % 3600U) / 60U;
    const unsigned second = secondsOfDay % 60U;
    char utc[16]{};
    const unsigned hundredths = (now % 1000U) / 10U;
    std::snprintf(utc, sizeof(utc), "%02u%02u%02u.%02u", hour, minute,
                  second, hundredths);

    char latitudeValue[20]{};
    char longitudeValue[20]{};
    char latitudeHemisphere = 'N';
    char longitudeHemisphere = 'E';
    formatCoordinate(latitude, true, latitudeValue, sizeof(latitudeValue),
                     &latitudeHemisphere);
    formatCoordinate(longitude, false, longitudeValue,
                     sizeof(longitudeValue), &longitudeHemisphere);

    char body[170]{};
    std::snprintf(body, sizeof(body),
                  "GNGGA,%s,%s,%c,%s,%c,%d,24,0.70,88.500,M,46.000,M,0.5,"
                  "0000",
                  utc, latitudeValue, latitudeHemisphere, longitudeValue,
                  longitudeHemisphere, quality);
    notifyNmeaBody(body);

    std::snprintf(body, sizeof(body),
                  "GNRMC,%s,A,%s,%c,%s,%c,0.80,42.0,100826,,,A", utc,
                  latitudeValue, latitudeHemisphere, longitudeValue,
                  longitudeHemisphere);
    notifyNmeaBody(body);

    std::snprintf(body, sizeof(body),
                  "GNGST,%s,0.012,0.018,0.014,0.0,0.010,0.010,0.025", utc);
    notifyNmeaBody(body);

    std::snprintf(body, sizeof(body), "PQTMTXT,1,%s", qualityText);
    notifyNmeaBody(body);

    vTaskDelay(pdMS_TO_TICKS(200));
  }
}

void statusTask(void*) {
  uint8_t diagnosticDivider = 0;
  while (true) {
    TransportStats snapshot;
    portENTER_CRITICAL(&statsMux);
    snapshot = transportStats;
    portEXIT_CRITICAL(&statsMux);

    const unsigned queueSpaces = uxQueueSpacesAvailable(rtcmQueue);
    const long age = snapshot.hasValidRtcm
                         ? static_cast<long>(millis() -
                                             snapshot.lastValidRtcmMs)
                         : -1L;
    char json[180]{};
    std::snprintf(
        json, sizeof(json),
        "{\"v\":1,\"m\":\"%s\",\"rb\":%lu,\"rf\":%lu,\"rc\":%lu,"
        "\"sg\":%lu,\"qd\":%lu,\"free\":%u,\"age\":%ld}",
        gnssModeName(), static_cast<unsigned long>(snapshot.rtcmBytes),
        static_cast<unsigned long>(snapshot.rtcmFrames),
        static_cast<unsigned long>(snapshot.rtcmCrcErrors),
        static_cast<unsigned long>(snapshot.sequenceGaps),
        static_cast<unsigned long>(snapshot.queueDrops), queueSpaces, age);

    if (statusCharacteristic != nullptr) {
      statusCharacteristic->setValue(json);
      if (bleConnected) {
        statusCharacteristic->notify();
      }
    }
    if (++diagnosticDivider >= 10U) {
      diagnosticDivider = 0;
      Serial.printf(
          "Hardware: LG290P RX=%lu bytes, NMEA=%lu valid, "
          "GY-521=%s/%lu samples, BLE=%s\n",
          static_cast<unsigned long>(lg290pRxBytes),
          static_cast<unsigned long>(lg290pValidNmeaSentences),
          imuHardwarePresent ? "detected" : "not detected",
          static_cast<unsigned long>(imuHardwareSamples),
          bleConnected ? "connected" : "advertising");
    }
    vTaskDelay(pdMS_TO_TICKS(500));
  }
}

void setupBle() {
  const uint64_t mac = ESP.getEfuseMac();
  char deviceName[32]{};
  std::snprintf(deviceName, sizeof(deviceName), "KRover-%04llX",
                static_cast<unsigned long long>(mac & 0xFFFFU));

  NimBLEDevice::init(deviceName);
  NimBLEDevice::setMTU(517);
  NimBLEServer* server = NimBLEDevice::createServer();
  server->setCallbacks(new RoverServerCallbacks());
  server->advertiseOnDisconnect(true);

  NimBLEService* service = server->createService(kataster::kServiceUuid);
  NimBLECharacteristic* rtcmCharacteristic = service->createCharacteristic(
      kataster::kRtcmRxUuid,
      NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR,
      kMaximumBleValue);
  gnssCharacteristic = service->createCharacteristic(
      kataster::kGnssTxUuid, NIMBLE_PROPERTY::NOTIFY, kMaximumBleValue);
  statusCharacteristic = service->createCharacteristic(
      kataster::kStatusUuid, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY,
      256);
  controlCharacteristic = service->createCharacteristic(
      kataster::kControlUuid, NIMBLE_PROPERTY::WRITE, 160);
  imuCharacteristic = service->createCharacteristic(
      kataster::kImuTxUuid, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY,
      384);

  rtcmCharacteristic->setCallbacks(new RtcmCallbacks());
  controlCharacteristic->setCallbacks(new ControlCallbacks());
  char initialStatus[128]{};
  std::snprintf(
      initialStatus, sizeof(initialStatus),
      "{\"v\":1,\"m\":\"%s\",\"rb\":0,\"rf\":0,\"rc\":0,\"sg\":0,"
      "\"qd\":0,\"free\":0,\"age\":-1}",
      gnssModeName());
  statusCharacteristic->setValue(initialStatus);
  imuCharacteristic->setValue(
      "{\"v\":1,\"s\":\"starting\",\"x\":true,\"r\":0,\"p\":0,"
      "\"t\":0,\"a\":1,\"g\":0,\"m\":true,\"l\":false,"
      "\"o\":false,\"c\":false,\"y\":false,\"q\":\"required\",\"n\":0,"
      "\"u\":false,\"d\":-1,\"h\":0,\"e\":0}");
  NimBLEAdvertising* advertising = NimBLEDevice::getAdvertising();
  advertising->addServiceUUID(kataster::kServiceUuid);
  advertising->enableScanResponse(true);
  advertising->setName(deviceName);
  advertising->start();

  Serial.printf("BLE advertising as %s\n", deviceName);
}

}  // namespace

void setup() {
  Serial.begin(115200);
  delay(500);
  Serial.println("KRover ESP32-S3 hardware bridge starting");

#if !KATASTER_GNSS_SIMULATION
  lg290pSerial.setRxBufferSize(8192);
  lg290pSerial.begin(KATASTER_LG290P_BAUD, SERIAL_8N1, KATASTER_LG290P_RX,
                     KATASTER_LG290P_TX);
  Serial.printf("LG290P UART1 started: RX=GPIO%d, TX=GPIO%d, baud=%lu\n",
                KATASTER_LG290P_RX, KATASTER_LG290P_TX,
                static_cast<unsigned long>(KATASTER_LG290P_BAUD));
#endif

  rtcmQueue = xQueueCreate(kRtcmQueueDepth, sizeof(BlePacket));
  if (rtcmQueue == nullptr) {
    Serial.println("Unable to allocate RTCM queue");
    ESP.restart();
  }

  setupBle();
  xTaskCreatePinnedToCore(rtcmTask, "rtcm", 6144, nullptr, 3, nullptr, 1);
#if KATASTER_GNSS_SIMULATION
  xTaskCreatePinnedToCore(dummyGnssTask, "dummy-gnss", 6144, nullptr, 2,
                          nullptr, 1);
#else
  xTaskCreatePinnedToCore(lg290pGnssTask, "lg290p-gnss", 6144, nullptr, 2,
                          nullptr, 1);
#endif
  xTaskCreatePinnedToCore(statusTask, "status", 4096, nullptr, 1, nullptr, 0);
  xTaskCreatePinnedToCore(imuTask, "imu", 6144, nullptr, 2, nullptr, 0);
}

void loop() { delay(1000); }
