# KRover BLE protocol

Protocol version: **1**

The BLE service carries two ordered byte streams plus status and control. The
GNSS and RTCM payloads are not modified. A small transport header detects
session changes and missing BLE writes/notifications.

## UUIDs

| Purpose | UUID | Direction | GATT properties |
|---|---|---|---|
| Service | `7A1E0001-9B6D-4C7A-8F21-6D3E5C790001` | — | — |
| RTCM RX | `7A1E0002-9B6D-4C7A-8F21-6D3E5C790001` | iOS → ESP | Write, Write Without Response |
| GNSS TX | `7A1E0003-9B6D-4C7A-8F21-6D3E5C790001` | ESP → iOS | Notify |
| Status | `7A1E0004-9B6D-4C7A-8F21-6D3E5C790001` | ESP → iOS | Read, Notify |
| Control | `7A1E0005-9B6D-4C7A-8F21-6D3E5C790001` | iOS → ESP | Write |
| IMU TX | `7A1E0006-9B6D-4C7A-8F21-6D3E5C790001` | ESP → iOS | Read, Notify |

## Stream packet

Every value written to RTCM RX or notified on GNSS TX begins with this
four-byte header:

| Offset | Size | Field |
|---:|---:|---|
| 0 | 1 | Protocol version (`1`) |
| 1 | 1 | Session identifier |
| 2 | 2 | Unsigned sequence, little-endian |
| 4 | n | Unmodified stream payload |

Sequence numbers wrap modulo 65536. A new session identifier resets the
expected sequence and all partial stream parsers. A sequence gap causes the
receiver to discard its partial NMEA sentence or RTCM frame and resynchronise.

The sender determines the maximum payload at runtime from the negotiated ATT
write/notification size. No fixed MTU is assumed.

## RTCM rules

- iOS parses and CRC24Q-validates RTCM 3 before enqueueing it for BLE.
- ESP parses the received stream again.
- ESP only passes complete CRC-valid RTCM frames to the active `RtcmSink`.
- Partial data is never replayed after a reconnect.
- Corrections are live data. Queues are bounded and stale data is discarded.

RTCM RX normally uses Write Without Response. iOS obeys both CoreBluetooth's
`canSendWriteWithoutResponse` signal and the `free` capacity reported by ESP.

## GNSS rules

GNSS TX carries complete or partial NMEA/PQTM byte streams. The iOS parser
reassembles lines using CR/LF delimiters and validates NMEA checksums. A
sequence gap clears the partial line buffer.

## Status payload

Status is compact UTF-8 JSON so that it remains readable in generic BLE tools.

```json
{"v":1,"m":"walk","rb":12345,"rf":37,"rc":0,"sg":0,"qd":0,"free":18,"age":180}
```

| Key | Meaning |
|---|---|
| `v` | Protocol version |
| `m` | Dummy GNSS mode |
| `rb` | RTCM payload bytes accepted |
| `rf` | Valid RTCM frames |
| `rc` | RTCM CRC errors |
| `sg` | BLE sequence gaps |
| `qd` | RTCM packets dropped because the ESP queue was full |
| `free` | Free RTCM packet slots in the ESP queue |
| `age` | Milliseconds since the most recent valid RTCM frame, `-1` if none |

## Control payload

Control is UTF-8 JSON written with response.

```json
{"mode":"static"}
{"mode":"walk"}
{"mode":"quality"}
{"resetStats":true}
```

Unknown commands are ignored. Control never shares a characteristic with the
GNSS or RTCM byte streams.

IMU commands use the same control characteristic:

```json
{"imuMode":"level"}
{"imuMode":"tilted"}
{"imuMode":"motion"}
{"imuMode":"left"}
{"imuMode":"right"}
{"imuMode":"forward"}
{"imuMode":"backward"}
{"calibrateImu":true}
{"calibrateImuDirection":true}
{"resetImuCalibration":true}
```

The `imuMode` values only affect the simulator. The four directional values
name the correction shown to the operator and exercise the marker-relative
visual and acoustic guidance without physical IMU hardware. `calibrateImu`
collects 125 consecutive stationary samples (about 2.5 seconds) while the pole
is vertical, stores the vertical zero, and finishes. The independent
`calibrateImuDirection` command then reports `q=aligning` and collects 30
stationary samples (about 0.6 seconds) while the pole top is tilted 3–20 degrees
toward the housing marker; 5–15 degrees is the recommended target. Up to five
rejected samples are tolerated after collection begins before progress is
reset. This separate action determines the fixed sensor-to-marker angle; a
vertical pole cannot provide that direction. The command is rejected until a
vertical calibration exists. Both results are stored in ESP32 NVS and normally
remain valid for the lifetime of the unchanged mechanical assembly.

## IMU telemetry

IMU TX sends compact JSON at 10 Hz. It is deliberately separate from transport
status so the orientation update rate does not increase RTCM control traffic.

```json
{"v":1,"s":"simulation","x":true,"r":0.03,"p":-0.02,"t":0.04,"k":-90.0,"a":1.0000,"g":0.02,"m":false,"l":true,"o":true,"c":true,"y":true,"q":"ready","n":50,"u":true,"d":4,"h":810,"e":3}
```

| Key | Meaning |
|---|---|
| `s` | `simulation` or `mpu6050` |
| `x` | Values are simulated and must be labelled as a test mode |
| `r`, `p`, `t` | Roll, pitch and total pole tilt in degrees |
| `k` | Housing-marker direction in the sensor `(pitch, roll)` plane, in degrees |
| `a` | Acceleration vector magnitude in g |
| `g` | Angular rate magnitude in degrees per second |
| `m` | Pole is moving |
| `l` | Calibrated tilt is at most 0.5 degrees |
| `o` | Fully calibrated, within 0.5 degrees and stationary for at least 400 ms |
| `c` | Vertical zero calibration is valid |
| `y` | Operator-relative direction calibration is valid |
| `q`, `n` | Active calibration (`required`, `calibrating`, `aligning`, `ready`) and samples in that action |
| `u`, `d` | Sensor availability and sample age in milliseconds |
| `h` | Milliseconds continuously held level and stationary |
| `e` | Counter incremented whenever a new measurement-ready window begins |

Fields `k`, `y`, `h` and `e` were appended without increasing the protocol version.
The iOS decoder therefore treats them as optional when talking to older
firmware; an absent `k` uses the documented -90-degree marker mounting.
