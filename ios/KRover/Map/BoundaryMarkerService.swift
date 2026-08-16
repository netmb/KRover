import CoreLocation
import Foundation

enum BoundaryMarkStatus: Equatable {
    case marked
    case unmarked
    case deferred
    case unknown
}

struct CadastralBoundaryPoint: Identifiable, Equatable {
    let id: String
    let boundaryPointID: String
    let coordinate: CLLocationCoordinate2D
    let utm: UTMCoordinate
    let boundaryUTM: UTMCoordinate
    let pointCode: String?
    let markCode: String
    let isEstablished: Bool?
    let isIntermediate: Bool?
    let accuracyCode: String?
    let updatedAt: String?
    let createdAt: String?
    let remark: String?
    let isIndirect: Bool

    static func == (lhs: CadastralBoundaryPoint, rhs: CadastralBoundaryPoint) -> Bool {
        lhs.id == rhs.id && lhs.utm == rhs.utm && lhs.boundaryUTM == rhs.boundaryUTM &&
            lhs.markCode == rhs.markCode && lhs.accuracyCode == rhs.accuracyCode
    }

    var markStatus: BoundaryMarkStatus {
        switch markCode {
        case "9500": return .unmarked
        case "9600": return .deferred
        case "9998", "9999": return .unknown
        default: return .marked
        }
    }

    var markLabel: String { Self.markLabels[markCode] ?? "Marke (Code \(markCode))" }

    var accuracyUpperBoundMeters: Double? { Self.accuracyUpperBound(for: accuracyCode) }

    var accuracyLabel: String? {
        guard let accuracyCode else { return nil }
        if accuracyCode == "5000" { return "Standardabweichung über 5 m" }
        guard let meters = accuracyUpperBoundMeters else {
            return "Genauigkeitsstufe \(accuracyCode)"
        }
        if meters < 0.01 { return String(format: "Standardabweichung ≤ %.0f mm", meters * 1_000) }
        if meters < 1 { return String(format: "Standardabweichung ≤ %.0f cm", meters * 100) }
        return String(format: "Standardabweichung ≤ %.0f m", meters)
    }

    var offsetFromBoundary: Double { UTM32Projection.distance(utm, boundaryUTM) }

    var navigationLabel: String {
        if isIndirect {
            return String(format: "%@ · %.3f m zurückgesetzt", markLabel, offsetFromBoundary)
        }
        return markLabel
    }

    fileprivate static func accuracyUpperBound(for code: String?) -> Double? {
        accuracyUpperBounds[code ?? ""]
    }

    private static let accuracyUpperBounds: [String: Double] = [
        "0900": 0.001,
        "1000": 0.002,
        "1100": 0.005,
        "1200": 0.010,
        "1300": 0.015,
        "2000": 0.020,
        "2050": 0.025,
        "2100": 0.030,
        "2200": 0.060,
        "2300": 0.100,
        "2400": 0.200,
        "3000": 0.300,
        "3100": 0.600,
        "3200": 1.000,
        "3300": 5.000
    ]

    private static let markLabels: [String: String] = [
        "1000": "Marke, allgemein",
        "1100": "Stein",
        "1110": "Grenzstein",
        "1111": "Lochstein",
        "1112": "Vermessungspunktstein",
        "1120": "Unbehauener Feldstein",
        "1130": "Gemeinde- oder Waldgrenzstein",
        "1131": "Gemeindegrenzstein",
        "1132": "Wald- oder Forstgrenzstein",
        "1140": "Kunststoffmarke",
        "1160": "Landesgrenzstein",
        "1190": "Stein besonderer Ausführung",
        "1200": "Rohr",
        "1201": "Rohr mit Schutzkappe",
        "1202": "Rohr mit Kopf",
        "1203": "Rohr mit Bolzen",
        "1210": "Eisenrohr",
        "1220": "Kunststoffrohr",
        "1230": "Drainrohr",
        "1240": "Rohr mit Schutzkasten",
        "1250": "Zementrohr",
        "1260": "Glasrohr",
        "1290": "Tonrohr",
        "1300": "Bolzen oder Nagel",
        "1310": "Bolzen",
        "1311": "Adapterbolzen",
        "1320": "Nagel",
        "1400": "Meißelzeichen",
        "1410": "Bohrloch",
        "1500": "Pfahl",
        "1600": "Sonstige Marke",
        "1610": "Marke in Schutzbehälter",
        "1630": "Platte",
        "1631": "Klinkerplatte",
        "1632": "Granitplatte",
        "1635": "Platte mit Loch",
        "1650": "Klebemarke",
        "1655": "Schlagmarke",
        "1670": "Marke besonderer Ausführung",
        "1700": "Dauerhaft erkennbar festgelegt",
        "1710": "Punkt einer baulichen Anlage",
        "1711": "Sockel, roh",
        "1712": "Sockel, verputzt",
        "1713": "Mauerecke, roh",
        "1714": "Mauerecke, verputzt",
        "1720": "Grenzsäule",
        "1800": "Pfeiler",
        "9000": "Marke laut Bemerkung",
        "9500": "Ohne Marke",
        "9600": "Abmarkung zeitweilig ausgesetzt",
        "9998": "Markenart nicht spezifiziert",
        "9999": "Sonstige Abmarkung"
    ]
}

enum BoundaryPointLoadState: Equatable {
    case idle
    case loading
    case loaded
    case unavailable(String)
}

final class BoundaryMarkerService {
    fileprivate enum InputLimit {
        static let maximumResponseBytes = 16 * 1_024 * 1_024
        static let maximumRecordsPerResponse = 2_000
        static let maximumTextLength = 65_536
        static let maximumPages = 100
        static let maximumTotalRecords = 100_000
    }

    enum ServiceError: LocalizedError {
        case invalidResponse
        case malformedXML
        case responseTooLarge
        case service(String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "Der vollständige NRW-ALKIS-Dienst hat ungültig geantwortet."
            case .malformedXML:
                return "Die ALKIS-Grenzpunktdaten konnten nicht gelesen werden."
            case .responseTooLarge:
                return "Die ALKIS-Antwort überschreitet das zulässige Größenlimit."
            case .service(let message):
                return "ALKIS-Grenzpunkte: \(message)"
            }
        }
    }

    private let baseURL = URL(
        string: "https://www.wfs.nrw.de/geobasis/wfs_nw_alkis_aaa-modell-basiert"
    )!
    private let pageSize = 1_000
    private let boundaryTolerance = 0.05
    private let queryBuffer = 0.50

    func boundaryPoints(for parcel: ParcelInfo) async throws -> [CadastralBoundaryPoint] {
        try Task.checkCancellation()
        let boundaryLocations = try await pointLocationsNearBoundary(of: parcel)
        guard !boundaryLocations.isEmpty else { return [] }

        let directRecords = try await boundaryPointRecords(
            ids: Array(Set(boundaryLocations.map(\.parentID)))
        )
        let directByID = try Self.recordsByUniqueID(directRecords)

        var result: [CadastralBoundaryPoint] = []
        var indirectIDs: Set<String> = []
        for location in preferredLocations(boundaryLocations) {
            guard let record = directByID[location.parentID] else { continue }
            result.append(
                makeBoundaryPoint(record: record, location: location, boundaryUTM: location.utm)
            )
            indirectIDs.formUnion(record.indirectMarkerIDs)
        }

        if !indirectIDs.isEmpty {
            let indirectRecords = try await boundaryPointRecords(ids: Array(indirectIDs))
            let locationIDs = Array(Set(indirectRecords.flatMap(\.pointLocationIDs)))
            let locations = try await pointLocations(ids: locationIDs, typeName: "AX_PunktortAU")
            let locationsByParent = Dictionary(grouping: locations, by: \.parentID)
            let directLocationByID = Dictionary(
                uniqueKeysWithValues: preferredLocations(boundaryLocations).map { ($0.parentID, $0) }
            )

            for record in indirectRecords {
                guard let boundaryID = record.pointsToBoundaryID,
                      let boundaryLocation = directLocationByID[boundaryID],
                      let physicalLocation = preferredLocation(in: locationsByParent[record.id] ?? []) else {
                    continue
                }
                result.append(
                    makeBoundaryPoint(
                        record: record,
                        location: physicalLocation,
                        boundaryUTM: boundaryLocation.utm,
                        boundaryPointID: boundaryID,
                        isIndirect: true
                    )
                )
            }
        }

        return result.sorted {
            if $0.boundaryUTM.northing != $1.boundaryUTM.northing {
                return $0.boundaryUTM.northing < $1.boundaryUTM.northing
            }
            if $0.boundaryUTM.easting != $1.boundaryUTM.easting {
                return $0.boundaryUTM.easting < $1.boundaryUTM.easting
            }
            return $0.id < $1.id
        }
    }

    private func pointLocationsNearBoundary(of parcel: ParcelInfo) async throws -> [PointLocationRecord] {
        let points = parcel.boundaryRings.flatMap(\.utm)
        guard let minEasting = points.map(\.easting).min(),
              let maxEasting = points.map(\.easting).max(),
              let minNorthing = points.map(\.northing).min(),
              let maxNorthing = points.map(\.northing).max() else { return [] }

        let bbox = BoundingBox(
            minEasting: minEasting - queryBuffer,
            minNorthing: minNorthing - queryBuffer,
            maxEasting: maxEasting + queryBuffer,
            maxNorthing: maxNorthing + queryBuffer
        )
        let candidates = try await pointLocations(typeName: "AX_PunktortTA", bbox: bbox)
        return candidates.filter {
            Self.distance($0.utm, to: parcel.boundaryRings) <= boundaryTolerance
        }
    }

    private func pointLocations(
        typeName: String,
        bbox: BoundingBox
    ) async throws -> [PointLocationRecord] {
        var records: [PointLocationRecord] = []
        var seenRecordIDs: Set<String> = []
        var startIndex = 0
        var pageCount = 0
        while true {
            try Task.checkCancellation()
            guard pageCount < InputLimit.maximumPages,
                  records.count < InputLimit.maximumTotalRecords else {
                throw ServiceError.responseTooLarge
            }
            let url = try wfsURL(queryItems: [
                URLQueryItem(name: "SERVICE", value: "WFS"),
                URLQueryItem(name: "VERSION", value: "2.0.0"),
                URLQueryItem(name: "REQUEST", value: "GetFeature"),
                URLQueryItem(name: "TYPENAMES", value: "adv:\(typeName)"),
                URLQueryItem(name: "COUNT", value: String(pageSize)),
                URLQueryItem(name: "STARTINDEX", value: String(startIndex)),
                URLQueryItem(name: "SRSNAME", value: Self.officialCRS),
                URLQueryItem(name: "BBOX", value: bbox.queryValue)
            ])
            let page = try Self.parsePointLocations(data: try await fetch(url))
            pageCount += 1
            let newRecords = page.records.filter { seenRecordIDs.insert($0.id).inserted }
            guard !page.records.isEmpty, !newRecords.isEmpty else { break }
            records.append(contentsOf: newRecords)
            guard records.count <= InputLimit.maximumTotalRecords else {
                throw ServiceError.responseTooLarge
            }
            guard page.records.count == pageSize,
                  page.numberMatched.map({ records.count < $0 }) ?? true else { break }
            startIndex += page.records.count
        }
        return records
    }

    private func pointLocations(ids: [String], typeName: String) async throws -> [PointLocationRecord] {
        guard !ids.isEmpty else { return [] }
        var result: [PointLocationRecord] = []
        for chunk in ids.chunked(into: 40) {
            try Task.checkCancellation()
            let filter = Self.resourceIDFilter(chunk)
            let url = try wfsURL(queryItems: [
                URLQueryItem(name: "SERVICE", value: "WFS"),
                URLQueryItem(name: "VERSION", value: "2.0.0"),
                URLQueryItem(name: "REQUEST", value: "GetFeature"),
                URLQueryItem(name: "TYPENAMES", value: "adv:\(typeName)"),
                URLQueryItem(name: "SRSNAME", value: Self.officialCRS),
                URLQueryItem(name: "FILTER", value: filter)
            ])
            result.append(contentsOf: try Self.parsePointLocations(data: try await fetch(url)).records)
        }
        return result
    }

    private func boundaryPointRecords(ids: [String]) async throws -> [BoundaryPointRecord] {
        guard !ids.isEmpty else { return [] }
        var result: [BoundaryPointRecord] = []
        for chunk in ids.chunked(into: 40) {
            try Task.checkCancellation()
            let filter = Self.resourceIDFilter(chunk)
            let url = try wfsURL(queryItems: [
                URLQueryItem(name: "SERVICE", value: "WFS"),
                URLQueryItem(name: "VERSION", value: "2.0.0"),
                URLQueryItem(name: "REQUEST", value: "GetFeature"),
                URLQueryItem(name: "TYPENAMES", value: "adv:AX_Grenzpunkt"),
                URLQueryItem(name: "FILTER", value: filter)
            ])
            result.append(contentsOf: try Self.parseBoundaryPoints(data: try await fetch(url)))
        }
        return result
    }

    private func wfsURL(queryItems: [URLQueryItem]) throws -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = queryItems
        guard let url = components.url else { throw ServiceError.invalidResponse }
        return url
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("KRover/0.1 iOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ServiceError.invalidResponse
        }
        guard data.count <= InputLimit.maximumResponseBytes else {
            throw ServiceError.responseTooLarge
        }
        return data
    }

    private func makeBoundaryPoint(
        record: BoundaryPointRecord,
        location: PointLocationRecord,
        boundaryUTM: UTMCoordinate,
        boundaryPointID: String? = nil,
        isIndirect: Bool = false
    ) -> CadastralBoundaryPoint {
        CadastralBoundaryPoint(
            id: record.id,
            boundaryPointID: boundaryPointID ?? record.id,
            coordinate: UTM32Projection.unproject(location.utm),
            utm: location.utm,
            boundaryUTM: boundaryUTM,
            pointCode: record.pointCode,
            markCode: record.markCode,
            isEstablished: record.isEstablished,
            isIntermediate: record.isIntermediate,
            accuracyCode: location.accuracyCode,
            updatedAt: record.updatedAt ?? location.updatedAt,
            createdAt: record.createdAt,
            remark: record.remark,
            isIndirect: isIndirect
        )
    }

    private func preferredLocations(_ records: [PointLocationRecord]) -> [PointLocationRecord] {
        Dictionary(grouping: records, by: \.parentID).values.compactMap {
            preferredLocation(in: Array($0))
        }
    }

    private func preferredLocation(in records: [PointLocationRecord]) -> PointLocationRecord? {
        records.min {
            let leftMapRank = $0.isMapRepresentation == true ? 0 : 1
            let rightMapRank = $1.isMapRepresentation == true ? 0 : 1
            if leftMapRank != rightMapRank { return leftMapRank < rightMapRank }
            let leftAccuracy = CadastralBoundaryPoint.accuracyUpperBound(for: $0.accuracyCode)
                ?? .greatestFiniteMagnitude
            let rightAccuracy = CadastralBoundaryPoint.accuracyUpperBound(for: $1.accuracyCode)
                ?? .greatestFiniteMagnitude
            return leftAccuracy < rightAccuracy
        }
    }

    static func parsePointLocations(data: Data) throws -> ParsedPointLocations {
        let delegate = PointLocationXMLDelegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { throw delegate.error ?? parser.parserError ?? ServiceError.malformedXML }
        if let serviceMessage = delegate.serviceMessage { throw ServiceError.service(serviceMessage) }
        return ParsedPointLocations(records: delegate.records, numberMatched: delegate.numberMatched)
    }

    static func parseBoundaryPoints(data: Data) throws -> [BoundaryPointRecord] {
        let delegate = BoundaryPointXMLDelegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { throw delegate.error ?? parser.parserError ?? ServiceError.malformedXML }
        if let serviceMessage = delegate.serviceMessage { throw ServiceError.service(serviceMessage) }
        return delegate.records
    }

    private static func recordsByUniqueID(
        _ records: [BoundaryPointRecord]
    ) throws -> [String: BoundaryPointRecord] {
        var result: [String: BoundaryPointRecord] = [:]
        for record in records {
            guard result.updateValue(record, forKey: record.id) == nil else {
                throw ServiceError.malformedXML
            }
        }
        return result
    }

    private static func resourceIDFilter(_ ids: [String]) -> String {
        let resources = ids
            .filter { $0.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil }
            .map { #"<fes:ResourceId rid="\#($0)"/>"# }
            .joined()
        return #"<fes:Filter xmlns:fes="http://www.opengis.net/fes/2.0">\#(resources)</fes:Filter>"#
    }

    private static func distance(_ point: UTMCoordinate, to rings: [ParcelBoundaryRing]) -> Double {
        var best = Double.greatestFiniteMagnitude
        for ring in rings where ring.utm.count >= 2 {
            for index in ring.utm.indices {
                let start = ring.utm[index]
                let end = ring.utm[(index + 1) % ring.utm.count]
                let deltaEasting = end.easting - start.easting
                let deltaNorthing = end.northing - start.northing
                let lengthSquared = deltaEasting * deltaEasting + deltaNorthing * deltaNorthing
                guard lengthSquared > 0 else { continue }
                let fraction = min(1, max(0, (
                    (point.easting - start.easting) * deltaEasting +
                        (point.northing - start.northing) * deltaNorthing
                ) / lengthSquared))
                let projected = UTMCoordinate(
                    easting: start.easting + fraction * deltaEasting,
                    northing: start.northing + fraction * deltaNorthing
                )
                best = min(best, UTM32Projection.distance(point, projected))
            }
        }
        return best
    }

    private static let officialCRS = "urn:ogc:def:crs:EPSG::25832"
}

private struct BoundingBox {
    let minEasting: Double
    let minNorthing: Double
    let maxEasting: Double
    let maxNorthing: Double

    var queryValue: String {
        "\(minEasting),\(minNorthing),\(maxEasting),\(maxNorthing),urn:ogc:def:crs:EPSG::25832"
    }
}

struct ParsedPointLocations {
    let records: [PointLocationRecord]
    let numberMatched: Int?
}

struct PointLocationRecord {
    let id: String
    let parentID: String
    let utm: UTMCoordinate
    let isMapRepresentation: Bool?
    let coordinateStatus: String?
    let accuracyCode: String?
    let updatedAt: String?
}

struct BoundaryPointRecord {
    let id: String
    let pointCode: String?
    let markCode: String
    let isEstablished: Bool?
    let isIntermediate: Bool?
    let updatedAt: String?
    let createdAt: String?
    let remark: String?
    let pointLocationIDs: [String]
    let pointsToBoundaryID: String?
    let indirectMarkerIDs: [String]
}

private final class PointLocationXMLDelegate: NSObject, XMLParserDelegate {
    var records: [PointLocationRecord] = []
    var numberMatched: Int?
    var serviceMessage: String?
    var error: Error?

    private var current: PointLocationBuilder?
    private var text = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = Self.localName(qName ?? elementName)
        text = ""
        if name == "FeatureCollection" {
            numberMatched = Int(attributeDict["numberMatched"] ?? "")
        } else if name == "AX_PunktortTA" || name == "AX_PunktortAU" || name == "AX_PunktortAG" {
            current = PointLocationBuilder(id: Self.attribute("id", in: attributeDict) ?? "")
        } else if name == "istTeilVon" {
            current?.parentID = Self.objectID(Self.attribute("href", in: attributeDict))
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard text.utf8.count + string.utf8.count <= BoundaryMarkerService.InputLimit.maximumTextLength else {
            error = BoundaryMarkerService.ServiceError.responseTooLarge
            parser.abortParsing()
            return
        }
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = Self.localName(qName ?? elementName)
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "pos":
            let values = value.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
            if values.count >= 2 { current?.utm = UTMCoordinate(easting: values[0], northing: values[1]) }
        case "kartendarstellung": current?.isMapRepresentation = Self.bool(value)
        case "koordinatenstatus": current?.coordinateStatus = value.nilIfEmpty
        case "genauigkeitsstufe": current?.accuracyCode = value.nilIfEmpty
        case "beginnt": if current?.updatedAt == nil { current?.updatedAt = value.nilIfEmpty }
        case "ExceptionText": serviceMessage = value.nilIfEmpty
        case "AX_PunktortTA", "AX_PunktortAU", "AX_PunktortAG":
            if let current, let record = current.record {
                guard records.count < BoundaryMarkerService.InputLimit.maximumRecordsPerResponse else {
                    error = BoundaryMarkerService.ServiceError.responseTooLarge
                    parser.abortParsing()
                    return
                }
                records.append(record)
            }
            current = nil
        default: break
        }
        text = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { error = parseError }

    private static func bool(_ value: String) -> Bool? {
        if value == "true" || value == "1" { return true }
        if value == "false" || value == "0" { return false }
        return nil
    }

    fileprivate static func localName(_ name: String) -> String {
        String(name.split(separator: ":").last ?? Substring(name))
    }

    fileprivate static func attribute(_ localName: String, in attributes: [String: String]) -> String? {
        attributes.first { Self.localName($0.key) == localName }?.value
    }

    fileprivate static func objectID(_ reference: String?) -> String? {
        reference?.split(separator: ":").last.map(String.init)
    }
}

private struct PointLocationBuilder {
    let id: String
    var parentID: String?
    var utm: UTMCoordinate?
    var isMapRepresentation: Bool?
    var coordinateStatus: String?
    var accuracyCode: String?
    var updatedAt: String?

    var record: PointLocationRecord? {
        guard !id.isEmpty, let parentID, let utm else { return nil }
        return PointLocationRecord(
            id: id,
            parentID: parentID,
            utm: utm,
            isMapRepresentation: isMapRepresentation,
            coordinateStatus: coordinateStatus,
            accuracyCode: accuracyCode,
            updatedAt: updatedAt
        )
    }
}

private final class BoundaryPointXMLDelegate: NSObject, XMLParserDelegate {
    var records: [BoundaryPointRecord] = []
    var serviceMessage: String?
    var error: Error?

    private var current: BoundaryPointBuilder?
    private var text = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = PointLocationXMLDelegate.localName(qName ?? elementName)
        text = ""
        if name == "AX_Grenzpunkt" {
            current = BoundaryPointBuilder(
                id: PointLocationXMLDelegate.attribute("id", in: attributeDict) ?? ""
            )
        } else if name == "bestehtAus" {
            if let id = PointLocationXMLDelegate.objectID(
                PointLocationXMLDelegate.attribute("href", in: attributeDict)
            ) { current?.pointLocationIDs.append(id) }
        } else if name == "zeigtAuf" {
            current?.pointsToBoundaryID = PointLocationXMLDelegate.objectID(
                PointLocationXMLDelegate.attribute("href", in: attributeDict)
            )
        } else if name == "inversZu_zeigtAuf" {
            if let id = PointLocationXMLDelegate.objectID(
                PointLocationXMLDelegate.attribute("href", in: attributeDict)
            ) { current?.indirectMarkerIDs.append(id) }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard text.utf8.count + string.utf8.count <= BoundaryMarkerService.InputLimit.maximumTextLength else {
            error = BoundaryMarkerService.ServiceError.responseTooLarge
            parser.abortParsing()
            return
        }
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = PointLocationXMLDelegate.localName(qName ?? elementName)
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "punktkennung": current?.pointCode = value.nilIfEmpty
        case "abmarkung_Marke": current?.markCode = value.nilIfEmpty
        case "festgestellterGrenzpunkt": current?.isEstablished = Self.bool(value)
        case "zwischenmarke": current?.isIntermediate = Self.bool(value)
        case "beginnt": if current?.updatedAt == nil { current?.updatedAt = value.nilIfEmpty }
        case "zeitpunktDerEntstehung": current?.createdAt = value.nilIfEmpty
        case "bemerkungZurAbmarkung": current?.remark = value.nilIfEmpty
        case "sonstigeEigenschaft":
            if let value = value.nilIfEmpty {
                let existing = current?.remark
                current?.remark = [existing, value].compactMap { $0 }.joined(separator: " · ")
            }
        case "ExceptionText": serviceMessage = value.nilIfEmpty
        case "AX_Grenzpunkt":
            if let current, let record = current.record {
                guard records.count < BoundaryMarkerService.InputLimit.maximumRecordsPerResponse else {
                    error = BoundaryMarkerService.ServiceError.responseTooLarge
                    parser.abortParsing()
                    return
                }
                records.append(record)
            }
            current = nil
        default: break
        }
        text = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { error = parseError }

    private static func bool(_ value: String) -> Bool? {
        if value == "true" || value == "1" { return true }
        if value == "false" || value == "0" { return false }
        return nil
    }
}

private struct BoundaryPointBuilder {
    let id: String
    var pointCode: String?
    var markCode: String?
    var isEstablished: Bool?
    var isIntermediate: Bool?
    var updatedAt: String?
    var createdAt: String?
    var remark: String?
    var pointLocationIDs: [String] = []
    var pointsToBoundaryID: String?
    var indirectMarkerIDs: [String] = []

    var record: BoundaryPointRecord? {
        guard !id.isEmpty, let markCode else { return nil }
        return BoundaryPointRecord(
            id: id,
            pointCode: pointCode,
            markCode: markCode,
            isEstablished: isEstablished,
            isIntermediate: isIntermediate,
            updatedAt: updatedAt,
            createdAt: createdAt,
            remark: remark,
            pointLocationIDs: pointLocationIDs,
            pointsToBoundaryID: pointsToBoundaryID,
            indirectMarkerIDs: indirectMarkerIDs
        )
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
