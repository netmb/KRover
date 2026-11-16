import CoreLocation
import Foundation

/// A single point as it appears in every export format.
struct SurveyExportPoint: Equatable {
    enum Category: String, CaseIterable {
        case boundary = "Grenzpunkt"
        case distance = "Streckenpunkt"
        case area = "Flächenpunkt"
        case elevation = "Höhenpunkt"
        case terrain = "Geländepunkt"

        /// Short point code used by CAD/GIS imports.
        var code: String {
            switch self {
            case .boundary: return "GP"
            case .distance: return "SP"
            case .area: return "FP"
            case .elevation: return "HP"
            case .terrain: return "GL"
            }
        }

        var namePrefix: String {
            switch self {
            case .boundary: return "GP"
            case .distance: return "S"
            case .area: return "F"
            case .elevation: return "H"
            case .terrain: return "G"
            }
        }
    }

    var name: String
    var category: Category
    var coordinate: CLLocationCoordinate2D
    var utm: UTMCoordinate
    /// GNSS antenna height above the receiver's geoid (GGA "MSL").
    var antennaHeight: Double?
    /// Antenna height minus pole length.
    var groundHeight: Double?
    var horizontalAccuracy: Double?
    var verticalAccuracy: Double?
    var sampleCount: Int?
    var timestamp: Date?
    var source: String
    var remark: String?
    var isTest: Bool

    static func == (lhs: SurveyExportPoint, rhs: SurveyExportPoint) -> Bool {
        lhs.name == rhs.name && lhs.category == rhs.category && lhs.utm == rhs.utm
            && lhs.antennaHeight == rhs.antennaHeight && lhs.groundHeight == rhs.groundHeight
    }
}

struct SurveyExportParcel {
    let id: String
    let label: String
    let municipality: String
    let district: String
    let section: String
    let number: String
    let area: Double?
    let updatedAt: String?
    /// First ring is the outer boundary, all further rings are holes.
    let wgs84Rings: [[CLLocationCoordinate2D]]
    let utmRings: [[UTMCoordinate]]

    var perimeter: Double {
        utmRings.reduce(0) { total, ring in
            guard ring.count > 1 else { return total }
            return total + ring.indices.reduce(0) {
                $0 + UTM32Projection.distance(ring[$1], ring[($1 + 1) % ring.count])
            }
        }
    }

    var cadastralDesignation: String {
        var parts: [String] = []
        if !district.isEmpty { parts.append("Gemarkung \(district)") }
        if !section.isEmpty { parts.append("Flur \(section)") }
        if !number.isEmpty { parts.append("Flurstück \(number)") }
        return parts.joined(separator: " · ")
    }
}

struct SurveyExportMeasurement {
    enum Kind {
        case distance
        case area
        case elevation

        var title: String {
            switch self {
            case .distance: return "Streckenmessung"
            case .area: return "Flächenmessung"
            case .elevation: return "Höhen-/Gefällemessung"
            }
        }
    }

    let kind: Kind
    let points: [SurveyExportPoint]

    var coordinates: [CLLocationCoordinate2D] { points.map(\.coordinate) }

    var length: Double? {
        guard kind != .area, points.count >= 2 else { return nil }
        return UTM32Projection.polylineLength(coordinates)
    }

    var area: Double? {
        guard kind == .area, points.count >= 3 else { return nil }
        return UTM32Projection.polygonArea(coordinates)
    }

    var perimeter: Double? {
        guard kind == .area, points.count >= 3 else { return nil }
        return UTM32Projection.polygonPerimeter(coordinates)
    }

    /// Height of every point relative to the first one (elevation mode).
    var relativeHeights: [Double?] {
        guard let reference = points.first?.antennaHeight else {
            return points.map { _ in nil }
        }
        return points.map { $0.antennaHeight.map { $0 - reference } }
    }
}

struct SurveyExportTerrain {
    let points: [SurveyExportPoint]
    let model: TerrainModel?

    var statistics: TerrainStatistics? {
        guard let model, !model.vertices.isEmpty else { return nil }
        return model.statistics()
    }
}

/// Everything that can be exported, captured at one moment.
struct SurveyExportSnapshot {
    var createdAt: Date
    var poleLength: Double
    var mapBackground: MapBackgroundLayer
    var parcel: SurveyExportParcel?
    var boundaryPoints: [SurveyExportPoint]
    var measurement: SurveyExportMeasurement?
    var terrain: SurveyExportTerrain?

    var surveyedPoints: [SurveyExportPoint] {
        (measurement?.points ?? []) + (terrain?.points ?? [])
    }

    var allPoints: [SurveyExportPoint] { boundaryPoints + surveyedPoints }

    var containsTestPoints: Bool { surveyedPoints.contains(where: \.isTest) }

    var isEmpty: Bool {
        parcel == nil && allPoints.isEmpty
    }

    var title: String {
        if let measurement, parcel == nil { return measurement.kind.title }
        if let parcel { return parcel.label }
        if terrain != nil { return "Geländeaufnahme" }
        return "KRover-Export"
    }

    /// File-system friendly base name, e.g. `KRover_Flur-3-Flst-120_20261116-1405`.
    var fileBaseName: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        var subject = "Messung"
        if let parcel {
            var parts: [String] = []
            if !parcel.section.isEmpty { parts.append("Flur-\(parcel.section)") }
            if !parcel.number.isEmpty { parts.append("Flst-\(parcel.number)") }
            subject = parts.isEmpty ? parcel.id : parts.joined(separator: "-")
        } else if let measurement {
            switch measurement.kind {
            case .distance: subject = "Strecke"
            case .area: subject = "Flaeche"
            case .elevation: subject = "Hoehe"
            }
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let safeSubject = String(subject.unicodeScalars.map {
            allowed.contains($0) && $0.isASCII ? Character($0) : "-"
        })
        return "KRover_\(safeSubject)_\(formatter.string(from: createdAt))"
    }

    /// Bounding box of all exported geometry.
    var boundingCoordinates: [CLLocationCoordinate2D] {
        var coordinates = allPoints.map(\.coordinate)
        if let parcel { coordinates += parcel.wgs84Rings.flatMap { $0 } }
        return coordinates
    }

    /// Region the plan zooms to: the running measurement if there is one,
    /// otherwise everything (parcel, boundary points, terrain).
    var focusCoordinates: [CLLocationCoordinate2D] {
        if let measurement, !measurement.points.isEmpty { return measurement.coordinates }
        return boundingCoordinates
    }

    /// Restricts the snapshot to the content the user selected.
    func filtered(by content: SurveyExportContent) -> SurveyExportSnapshot {
        var copy = self
        if !content.contains(.parcel) { copy.parcel = nil }
        if !content.contains(.boundaryPoints) { copy.boundaryPoints = [] }
        if !content.contains(.measurement) { copy.measurement = nil }
        if !content.contains(.terrain) { copy.terrain = nil }
        return copy
    }
}

struct SurveyExportContent: OptionSet, Hashable {
    let rawValue: Int
    static let parcel = SurveyExportContent(rawValue: 1 << 0)
    static let boundaryPoints = SurveyExportContent(rawValue: 1 << 1)
    static let measurement = SurveyExportContent(rawValue: 1 << 2)
    static let terrain = SurveyExportContent(rawValue: 1 << 3)
    static let all: SurveyExportContent = [.parcel, .boundaryPoints, .measurement, .terrain]
}

extension SurveyExportPoint {
    /// Builds a point from an averaged GNSS measurement.
    init(
        name: String,
        category: Category,
        coordinate: CLLocationCoordinate2D,
        measurement: PointMeasurementResult?,
        poleLength: Double
    ) {
        let antennaHeight = measurement?.altitudeMSL
        self.init(
            name: name,
            category: category,
            coordinate: coordinate,
            utm: UTM32Projection.project(coordinate),
            antennaHeight: antennaHeight,
            groundHeight: antennaHeight.map { $0 - poleLength },
            horizontalAccuracy: measurement?.estimatedHorizontalAccuracy,
            verticalAccuracy: measurement?.estimatedVerticalAccuracy,
            sampleCount: measurement?.sampleCount,
            timestamp: measurement?.timestamp,
            source: measurement.map { $0.source.isTest ? "iPhone-GPS (Test)" : "Rover RTK" } ?? "manuell (Karte)",
            remark: nil,
            isTest: measurement?.source.isTest ?? true
        )
    }

    init(terrainPoint: TerrainSurveyPoint, name: String, poleLength: Double) {
        self.init(
            name: name,
            category: .terrain,
            coordinate: terrainPoint.coordinate,
            utm: UTM32Projection.project(terrainPoint.coordinate),
            antennaHeight: terrainPoint.altitudeMSL,
            groundHeight: terrainPoint.altitudeMSL - poleLength,
            horizontalAccuracy: terrainPoint.estimatedHorizontalAccuracy,
            verticalAccuracy: terrainPoint.estimatedVerticalAccuracy,
            sampleCount: terrainPoint.sampleCount,
            timestamp: terrainPoint.timestamp,
            source: terrainPoint.isTest ? "iPhone-GPS (Test)" : "Rover RTK",
            remark: nil,
            isTest: terrainPoint.isTest
        )
    }

    init(boundaryPoint: CadastralBoundaryPoint, index: Int) {
        var remarks: [String] = []
        if let pointCode = boundaryPoint.pointCode?.trimmingCharacters(in: .whitespaces), !pointCode.isEmpty {
            remarks.append("PKZ \(pointCode)")
        }
        remarks.append(boundaryPoint.markLabel)
        if let accuracy = boundaryPoint.accuracyLabel { remarks.append(accuracy) }
        if boundaryPoint.isIndirect { remarks.append("indirekte Abmarkung") }
        self.init(
            name: "GP\(index + 1)",
            category: .boundary,
            coordinate: boundaryPoint.coordinate,
            utm: boundaryPoint.utm,
            antennaHeight: nil,
            groundHeight: nil,
            horizontalAccuracy: boundaryPoint.accuracyUpperBoundMeters,
            verticalAccuracy: nil,
            sampleCount: nil,
            timestamp: nil,
            source: "ALKIS NRW",
            remark: remarks.joined(separator: ", "),
            isTest: false
        )
    }
}
