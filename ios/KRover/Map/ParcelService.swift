import CoreLocation
import Foundation
import MapKit

final class ParcelService {
    private enum InputLimit {
        static let maximumResponseBytes = 8 * 1_024 * 1_024
        static let maximumFeatures = 100
        static let maximumGeometryDepth = 8
        static let maximumRings = 256
        static let maximumVertices = 50_000
        static let maximumCrossCRSError = 1.0
    }

    enum ServiceError: LocalizedError {
        case invalidResponse
        case noResult
        case malformedGeometry
        case responseTooLarge

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "Der NRW-Kartendienst hat ungültig geantwortet."
            case .noResult: return "An dieser Stelle wurde kein Flurstück gefunden."
            case .malformedGeometry: return "Die Flurstücksgeometrie konnte nicht gelesen werden."
            case .responseTooLarge: return "Die Flurstücksantwort überschreitet das zulässige Größenlimit."
            }
        }
    }

    private let baseURL = URL(string: "https://ogc-api.nrw.de/lika/v1")!
    private let parcelSearchURL = URL(string: "https://www.gis-rest.nrw.de/geobasis/flurstuecksuche/2.0/search")!

    func search(_ query: String) async throws -> ParcelInfo {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ServiceError.noResult }

        if let identifier = try? await searchParcelIdentifier(trimmed) {
            return try await parcel(identifier: identifier)
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        request.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 51.45, longitude: 7.55),
            span: MKCoordinateSpan(latitudeDelta: 4.0, longitudeDelta: 5.0)
        )
        let response = try await MKLocalSearch(request: request).start()
        guard let coordinate = response.mapItems.first?.placemark.coordinate else { throw ServiceError.noResult }
        return try await parcel(at: coordinate)
    }

    func parcel(at coordinate: CLLocationCoordinate2D) async throws -> ParcelInfo {
        let delta = 0.00003
        var components = URLComponents(
            url: baseURL.appendingPathComponent("collections/flurstueck/items"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "f", value: "json"),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(
                name: "bbox",
                value: "\(coordinate.longitude - delta),\(coordinate.latitude - delta),\(coordinate.longitude + delta),\(coordinate.latitude + delta)"
            )
        ]
        let data = try await fetch(components.url!)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = object["features"] as? [[String: Any]], !features.isEmpty else {
            throw ServiceError.noResult
        }
        guard features.count <= InputLimit.maximumFeatures else { throw ServiceError.responseTooLarge }
        let selected = features.first(where: { Self.contains(coordinate, feature: $0) }) ?? features[0]
        guard let identifier = selected["id"] as? String else { throw ServiceError.invalidResponse }
        return try await parcel(identifier: identifier)
    }

    func parcel(identifier: String) async throws -> ParcelInfo {
        let itemURL = baseURL
            .appendingPathComponent("collections/flurstueck/items")
            .appendingPathComponent(identifier)
        var geographicComponents = URLComponents(url: itemURL, resolvingAgainstBaseURL: false)!
        geographicComponents.queryItems = [URLQueryItem(name: "f", value: "json")]
        var exactComponents = URLComponents(url: itemURL, resolvingAgainstBaseURL: false)!
        exactComponents.queryItems = [
            URLQueryItem(name: "f", value: "json"),
            URLQueryItem(name: "profile", value: "jsonfg"),
            URLQueryItem(name: "crs", value: "http://www.opengis.net/def/crs/EPSG/0/25832")
        ]
        let geographicURL = geographicComponents.url!
        let exactURL = exactComponents.url!
        async let geographicData = fetch(geographicURL)
        async let exactData = fetch(exactURL)
        return try await decodeParcel(
            identifier: identifier,
            geographicData: geographicData,
            exactData: exactData
        )
    }

    private func searchParcelIdentifier(_ query: String) async throws -> String {
        var components = URLComponents(url: parcelSearchURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "query", value: query)]
        let data = try await fetch(components.url!)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]],
              let identifier = results.first?["kennzeichen"] as? String else {
            throw ServiceError.noResult
        }
        return identifier
    }

    private func decodeParcel(identifier: String, geographicData: Data, exactData: Data) throws -> ParcelInfo {
        guard let geographic = try JSONSerialization.jsonObject(with: geographicData) as? [String: Any],
              let geometry = geographic["geometry"] as? [String: Any],
              let geographicCoordinates = geometry["coordinates"],
              let properties = geographic["properties"] as? [String: Any],
              let exact = try JSONSerialization.jsonObject(with: exactData) as? [String: Any],
              let place = exact["place"] as? [String: Any],
              let exactCoordinates = place["coordinates"] else {
            throw ServiceError.malformedGeometry
        }
        let wgsRings = try Self.coordinateRings(in: geographicCoordinates).map { ring in
            Self.withoutClosingCoordinateDuplicates(ring.map {
                CLLocationCoordinate2D(latitude: $0.1, longitude: $0.0)
            })
        }
        let utmRings = try Self.coordinateRings(in: exactCoordinates).map { ring in
            Self.withoutClosingDuplicates(ring.map {
                UTMCoordinate(easting: $0.0, northing: $0.1)
            })
        }
        guard wgsRings.count == utmRings.count else { throw ServiceError.malformedGeometry }
        let boundaryRings = zip(wgsRings, utmRings).compactMap { wgs, utm -> ParcelBoundaryRing? in
            guard wgs.count == utm.count, wgs.count >= 2,
                  wgs.allSatisfy({ CLLocationCoordinate2DIsValid($0) }),
                  utm.allSatisfy({ $0.easting.isFinite && $0.northing.isFinite }),
                  zip(wgs, utm).allSatisfy({ pair in
                      UTM32Projection.distance(UTM32Projection.project(pair.0), pair.1)
                          <= InputLimit.maximumCrossCRSError
                  }) else { return nil }
            return ParcelBoundaryRing(wgs84: wgs, utm: utm)
        }
        guard !boundaryRings.isEmpty, boundaryRings.count == wgsRings.count else {
            throw ServiceError.malformedGeometry
        }
        let wgs = boundaryRings.flatMap(\.wgs84)
        let utm = boundaryRings.flatMap(\.utm)
        let declaredArea = Self.numericValue(properties["flaeche"])
        let geometryArea = Self.area(of: boundaryRings)
        return ParcelInfo(
            id: identifier,
            label: properties["lagebeztxt"] as? String ?? "Flurstück \(properties["flstnrzae"] as? String ?? identifier)",
            municipality: properties["gemeinde"] as? String ?? "",
            district: properties["gemarkung"] as? String ?? "",
            section: properties["flur"] as? String ?? "",
            number: properties["flstnrzae"] as? String ?? "",
            area: declaredArea ?? (geometryArea > 0 ? geometryArea : nil),
            updatedAt: properties["aktualit"] as? String,
            geoJSON: geographicData,
            wgs84Vertices: wgs,
            utmVertices: utm,
            boundaryRings: boundaryRings
        )
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
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

    private static func numericValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String {
            return Double(string.replacingOccurrences(of: ",", with: "."))
        }
        return nil
    }

    private static func area(of rings: [ParcelBoundaryRing]) -> Double {
        guard let outer = rings.first else { return 0 }
        let outerArea = ringArea(outer.utm)
        let holesArea = rings.dropFirst().reduce(0) { $0 + ringArea($1.utm) }
        return max(0, outerArea - holesArea)
    }

    private static func ringArea(_ points: [UTMCoordinate]) -> Double {
        guard points.count >= 3 else { return 0 }
        let sum = points.indices.reduce(0.0) { result, index in
            let next = points[(index + 1) % points.count]
            return result
                + points[index].easting * next.northing
                - next.easting * points[index].northing
        }
        return abs(sum) / 2
    }

    private static func coordinateRings(in value: Any) throws -> [[(Double, Double)]] {
        var rings: [[(Double, Double)]] = []
        var vertexCount = 0
        try appendCoordinateRings(
            in: value,
            depth: 0,
            rings: &rings,
            vertexCount: &vertexCount
        )
        return rings
    }

    private static func appendCoordinateRings(
        in value: Any,
        depth: Int,
        rings: inout [[(Double, Double)]],
        vertexCount: inout Int
    ) throws {
        guard depth <= InputLimit.maximumGeometryDepth,
              let array = value as? [Any], !array.isEmpty else {
            throw ServiceError.malformedGeometry
        }
        if let first = array.first as? [Any],
           first.count >= 2, first[0] is NSNumber, first[1] is NSNumber {
            let ring = array.compactMap { value -> (Double, Double)? in
                guard let pair = value as? [Any], pair.count >= 2,
                      let x = pair[0] as? NSNumber, let y = pair[1] as? NSNumber else { return nil }
                return (x.doubleValue, y.doubleValue)
            }
            guard ring.count == array.count,
                  ring.allSatisfy({ $0.0.isFinite && $0.1.isFinite }),
                  rings.count < InputLimit.maximumRings,
                  vertexCount + ring.count <= InputLimit.maximumVertices else {
                throw ServiceError.responseTooLarge
            }
            rings.append(ring)
            vertexCount += ring.count
            return
        }
        for child in array {
            try appendCoordinateRings(
                in: child,
                depth: depth + 1,
                rings: &rings,
                vertexCount: &vertexCount
            )
        }
    }

    private static func withoutClosingDuplicates<T: Equatable>(_ coordinates: [T]) -> [T] {
        var result: [T] = []
        for coordinate in coordinates where result.last != coordinate { result.append(coordinate) }
        if result.count > 1, result.first == result.last { result.removeLast() }
        return result
    }

    private static func withoutClosingCoordinateDuplicates(
        _ coordinates: [CLLocationCoordinate2D]
    ) -> [CLLocationCoordinate2D] {
        func equal(_ lhs: CLLocationCoordinate2D, _ rhs: CLLocationCoordinate2D) -> Bool {
            lhs.latitude == rhs.latitude && lhs.longitude == rhs.longitude
        }
        var result: [CLLocationCoordinate2D] = []
        for coordinate in coordinates where result.last.map({ !equal($0, coordinate) }) ?? true {
            result.append(coordinate)
        }
        if result.count > 1, equal(result[0], result[result.count - 1]) { result.removeLast() }
        return result
    }

    private static func contains(_ coordinate: CLLocationCoordinate2D, feature: [String: Any]) -> Bool {
        guard let geometry = feature["geometry"] as? [String: Any],
              let coordinates = geometry["coordinates"] else { return false }
        guard let points = try? coordinateRings(in: coordinates).flatMap({ $0 }) else {
            return false
        }
        guard points.count >= 3 else { return false }
        var inside = false
        var previous = points.count - 1
        for current in points.indices {
            let xi = points[current].0, yi = points[current].1
            let xj = points[previous].0, yj = points[previous].1
            if ((yi > coordinate.latitude) != (yj > coordinate.latitude)) &&
                coordinate.longitude < (xj - xi) * (coordinate.latitude - yi) / (yj - yi) + xi {
                inside.toggle()
            }
            previous = current
        }
        return inside
    }
}
