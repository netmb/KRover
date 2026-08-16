import CoreLocation
import Foundation

enum FixQuality: String, Codable {
    case none = "Kein Fix"
    case single = "Single"
    case differential = "DGPS"
    case rtkFixed = "RTK Fixed"
    case rtkFloat = "RTK Float"
    case estimated = "Geschätzt"
    case unknown = "Unbekannt"

    init(ggaCode: Int) {
        switch ggaCode {
        case 0: self = .none
        case 1: self = .single
        case 2: self = .differential
        case 4: self = .rtkFixed
        case 5: self = .rtkFloat
        case 6: self = .estimated
        default: self = .unknown
        }
    }
}

struct GNSSPosition: Equatable {
    var coordinate: CLLocationCoordinate2D
    var altitude: Double?
    var horizontalSigma: Double?
    var verticalSigma: Double?
    var fixQuality: FixQuality
    var satellites: Int
    var hdop: Double?
    var timestamp: Date
    var sampleID: UInt64 = 0

    static func == (lhs: GNSSPosition, rhs: GNSSPosition) -> Bool {
        lhs.coordinate.latitude == rhs.coordinate.latitude &&
        lhs.coordinate.longitude == rhs.coordinate.longitude &&
        lhs.altitude == rhs.altitude && lhs.fixQuality == rhs.fixQuality &&
        lhs.satellites == rhs.satellites && lhs.timestamp == rhs.timestamp &&
        lhs.sampleID == rhs.sampleID
    }
}

struct RoverStatus: Codable, Equatable {
    var version: Int = 1
    var mode = "unbekannt"
    var rtcmBytes: UInt64 = 0
    var rtcmFrames: UInt64 = 0
    var crcErrors: UInt64 = 0
    var sequenceGaps: UInt64 = 0
    var freeQueueSlots: Int = 0
    var lastRtcmAgeMilliseconds: Int = -1
    var queueDrops: UInt64 = 0

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case mode = "m"
        case rtcmBytes = "rb"
        case rtcmFrames = "rf"
        case crcErrors = "rc"
        case sequenceGaps = "sg"
        case freeQueueSlots = "free"
        case lastRtcmAgeMilliseconds = "age"
        case queueDrops = "qd"
    }
}

enum IMUCalibrationState: String, Codable {
    case required
    case calibrating
    case aligning
    case ready

    var label: String {
        switch self {
        case .required: return "Kalibrierung erforderlich"
        case .calibrating: return "Nulllage wird kalibriert"
        case .aligning: return "Gehäusestrich wird kalibriert"
        case .ready: return "Kalibriert"
        }
    }
}

struct IMUState: Codable, Equatable {
    var version = 1
    var source = "nicht verfügbar"
    var isSimulation = false
    var rollDegrees = 0.0
    var pitchDegrees = 0.0
    var totalTiltDegrees = 0.0
    /// Direction of the housing marker in the sensor's (pitch, roll) plane.
    /// Older firmware omits this and uses the documented -90° mounting.
    var markerDirectionDegrees: Double?
    var accelerationMagnitudeG = 1.0
    var angularRateDps = 0.0
    var isMoving = true
    var isLevel = false
    var measurementReady = false
    var isCalibrated = false
    /// Added after vertical zero and operator-relative direction calibration
    /// became two separate actions. Missing on older firmware.
    var directionCalibrated: Bool?
    var calibrationState: IMUCalibrationState = .required
    var calibrationSamples = 0
    var isAvailable = false
    var sampleAgeMilliseconds = -1
    var stableMilliseconds: Int?
    var readySequence: UInt32?

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case source = "s"
        case isSimulation = "x"
        case rollDegrees = "r"
        case pitchDegrees = "p"
        case totalTiltDegrees = "t"
        case markerDirectionDegrees = "k"
        case accelerationMagnitudeG = "a"
        case angularRateDps = "g"
        case isMoving = "m"
        case isLevel = "l"
        case measurementReady = "o"
        case isCalibrated = "c"
        case directionCalibrated = "y"
        case calibrationState = "q"
        case calibrationSamples = "n"
        case isAvailable = "u"
        case sampleAgeMilliseconds = "d"
        case stableMilliseconds = "h"
        case readySequence = "e"
    }

    var hasDirectionCalibration: Bool { directionCalibrated == true }
}

enum ConnectionState: Equatable {
    case unavailable(String)
    case idle
    case scanning
    case connecting(String)
    case connected(String)
    case failed(String)

    var label: String {
        switch self {
        case .unavailable(let reason): return "Bluetooth: \(reason)"
        case .idle: return "Rover getrennt"
        case .scanning: return "Rover wird gesucht …"
        case .connecting(let name): return "Verbinde \(name) …"
        case .connected(let name): return "Verbunden: \(name)"
        case .failed(let error): return "BLE-Fehler: \(error)"
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

enum NtripState: Equatable {
    case idle
    case connecting
    case streaming
    case retrying(Int, String)
    case failed(String)

    var label: String {
        switch self {
        case .idle: return "SAPOS aus"
        case .connecting: return "SAPOS verbindet …"
        case .streaming: return "SAPOS empfängt RTCM"
        case .retrying(let seconds, let error): return "Neuer Versuch in \(seconds) s: \(error)"
        case .failed(let error): return "SAPOS-Fehler: \(error)"
        }
    }

    var isStreaming: Bool {
        if case .streaming = self { return true }
        return false
    }
}

struct NtripSettings: Equatable {
    var host = "sapos-nw-ntrip.de"
    var port: UInt16 = 2101
    var mountpoint = "VRS_3_4G_NW"
    var username = ""
    var password = ""

    var hasValidRequestFields: Bool {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMountpoint = mountpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedHost.isEmpty, trimmedHost.count <= 253,
              !trimmedMountpoint.isEmpty, trimmedMountpoint.count <= 1_024 else { return false }
        let forbidden = CharacterSet.controlCharacters.union(.whitespacesAndNewlines)
        return !trimmedHost.unicodeScalars.contains(where: forbidden.contains)
            && !trimmedMountpoint.unicodeScalars.contains(where: forbidden.contains)
    }
}

struct NtripStatistics: Equatable {
    var bytes: UInt64 = 0
    var validFrames: UInt64 = 0
    var crcErrors: UInt64 = 0
    var lastFrameAt: Date?
}

struct UTMCoordinate: Equatable, Hashable {
    var easting: Double
    var northing: Double
}

struct ParcelBoundaryRing {
    let wgs84: [CLLocationCoordinate2D]
    let utm: [UTMCoordinate]
}

struct ParcelInfo: Identifiable, Equatable {
    let id: String
    let label: String
    let municipality: String
    let district: String
    let section: String
    let number: String
    let area: Double?
    let updatedAt: String?
    let geoJSON: Data
    let wgs84Vertices: [CLLocationCoordinate2D]
    let utmVertices: [UTMCoordinate]
    let boundaryRings: [ParcelBoundaryRing]

    static func == (lhs: ParcelInfo, rhs: ParcelInfo) -> Bool { lhs.id == rhs.id }
}

enum BoundaryTargetKind: Equatable {
    case vertex
    case edge
    case marker

    var label: String {
        switch self {
        case .vertex: return "Katasterpunkt"
        case .edge: return "Punkt auf Grenzlinie"
        case .marker: return "amtliche Abmarkung"
        }
    }
}

struct BoundaryTarget {
    let coordinate: CLLocationCoordinate2D
    let utm: UTMCoordinate
    let kind: BoundaryTargetKind
    let ringIndex: Int
    let segmentIndex: Int
    let snapDistance: Double
    let markerID: String?

    init(
        coordinate: CLLocationCoordinate2D,
        utm: UTMCoordinate,
        kind: BoundaryTargetKind,
        ringIndex: Int,
        segmentIndex: Int,
        snapDistance: Double,
        markerID: String? = nil
    ) {
        self.coordinate = coordinate
        self.utm = utm
        self.kind = kind
        self.ringIndex = ringIndex
        self.segmentIndex = segmentIndex
        self.snapDistance = snapDistance
        self.markerID = markerID
    }
}

enum MapInteractionMode: String, CaseIterable, Identifiable {
    case inspect = "Flurstück"
    case target = "Ziel"
    case distance = "Strecke"
    case area = "Fläche"
    case elevation = "Höhe"

    var id: String { rawValue }
}

enum AreaCaptureMode: String, CaseIterable, Identifiable {
    case append = "Eckpunkte"
    case insert = "Knick"
    case control = "Prüfen"

    var id: String { rawValue }
}

struct PolygonEdgeMatch {
    let startIndex: Int
    let endIndex: Int
    let fraction: Double
    let projectedCoordinate: CLLocationCoordinate2D
    let distance: Double
    let projectionIsWithinSegment: Bool
}

struct AreaControlMeasurement {
    let coordinate: CLLocationCoordinate2D
    let edgeStartIndex: Int
    let edgeEndIndex: Int
    let distanceToEdge: Double
    let horizontalSigma: Double?
    let timestamp: Date

    var significanceThreshold: Double {
        max(0.05, 3 * (horizontalSigma ?? 0.02))
    }

    var isSignificant: Bool { distanceToEdge > significanceThreshold }
}

enum PointMeasurementSource: String, CaseIterable, Identifiable {
    case roverRTK = "Rover RTK"
    case iphoneTest = "iPhone GPS · TEST"

    var id: String { rawValue }
    var isTest: Bool { self == .iphoneTest }
}

enum PointCapturePhase: Equatable {
    case idle
    case armed
    case collecting
    case completed

    var isActive: Bool { self == .armed || self == .collecting }
}

struct PointMeasurementResult {
    let coordinate: CLLocationCoordinate2D
    let altitudeMSL: Double?
    let source: PointMeasurementSource
    let sampleCount: Int
    let duration: TimeInterval
    let minimumTiltDegrees: Double
    let meanTiltDegrees: Double
    let horizontalSpread: Double
    let estimatedHorizontalAccuracy: Double
    let verticalSpread: Double?
    let estimatedVerticalAccuracy: Double?
    let timestamp: Date
}

struct ElevationMeasurementSummary {
    let referenceAltitudeMSL: Double
    let highestPointIndex: Int
    let lowestPointIndex: Int
    let heightRange: Double
    let estimatedRangeAccuracy: Double?
    let startToEndHeightDifference: Double
    let startToEndHorizontalDistance: Double

    init?(measurements: [PointMeasurementResult]) {
        let heights = measurements.enumerated().compactMap { index, measurement in
            measurement.altitudeMSL.map { (index: index, altitude: $0) }
        }
        guard let reference = heights.first,
              let highest = heights.max(by: { $0.altitude < $1.altitude }),
              let lowest = heights.min(by: { $0.altitude < $1.altitude }),
              let last = heights.last else { return nil }

        referenceAltitudeMSL = reference.altitude
        highestPointIndex = highest.index
        lowestPointIndex = lowest.index
        heightRange = highest.altitude - lowest.altitude
        startToEndHeightDifference = last.altitude - reference.altitude

        let startCoordinate = measurements[reference.index].coordinate
        let endCoordinate = measurements[last.index].coordinate
        startToEndHorizontalDistance = UTM32Projection.distance(
            UTM32Projection.project(startCoordinate),
            UTM32Projection.project(endCoordinate)
        )

        if let highAccuracy = measurements[highest.index].estimatedVerticalAccuracy,
           let lowAccuracy = measurements[lowest.index].estimatedVerticalAccuracy {
            estimatedRangeAccuracy = hypot(highAccuracy, lowAccuracy)
        } else {
            estimatedRangeAccuracy = nil
        }
    }

    var startToEndSlopePercent: Double? {
        guard startToEndHorizontalDistance > 0.001 else { return nil }
        return startToEndHeightDifference / startToEndHorizontalDistance * 100
    }
}

struct PoleCorrection: Equatable {
    /// Current pole-head displacement toward the operator's right.
    let deviationRightDegrees: Double
    /// Current pole-head displacement toward the housing marker/operator.
    let deviationTowardUserDegrees: Double
    /// Positive means move the top of the pole to the operator's right.
    let rightDegrees: Double
    /// Positive means move the top of the pole away from the operator.
    let forwardDegrees: Double

    init(imu: IMUState) {
        // The UI is a fixed top view: the housing marker is always at the
        // bottom (toward the operator). Calibration supplies the marker's
        // fixed direction in the sensor plane; no compass heading is used.
        let markerRadians = (imu.markerDirectionDegrees ?? -90) * .pi / 180
        let markerPitch = cos(markerRadians)
        let markerRoll = sin(markerRadians)

        deviationRightDegrees =
            markerRoll * imu.pitchDegrees - markerPitch * imu.rollDegrees
        deviationTowardUserDegrees =
            markerPitch * imu.pitchDegrees + markerRoll * imu.rollDegrees
        rightDegrees = -deviationRightDegrees
        forwardDegrees = deviationTowardUserDegrees
    }

    var magnitudeDegrees: Double { hypot(rightDegrees, forwardDegrees) }

    var instruction: String {
        guard magnitudeDegrees > 0.5 else { return "Senkrecht halten" }
        if abs(rightDegrees) >= abs(forwardDegrees) {
            return rightDegrees >= 0 ? "Stabkopf nach rechts" : "Stabkopf nach links"
        }
        return forwardDegrees >= 0 ? "Stabkopf nach vorn" : "Stabkopf zu dir"
    }
}
