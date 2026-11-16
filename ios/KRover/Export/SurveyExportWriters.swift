import CoreLocation
import Foundation

/// Text based exchange formats. All writers are pure functions of the snapshot
/// so they can be unit tested without UI.
enum SurveyExportWriters {
    static let crsDescription = "ETRS89 / UTM Zone 32N (EPSG:25832)"
    static let heightDescription =
        "GNSS-Höhe über dem Geoidmodell des Empfängers (nicht amtlich DHHN2016)"

    // MARK: - Number formatting

    static func fixed(_ value: Double, _ decimals: Int) -> String {
        String(format: "%.\(decimals)f", value)
    }

    static func optionalFixed(_ value: Double?, _ decimals: Int) -> String {
        value.map { fixed($0, decimals) } ?? ""
    }

    static func isoTimestamp(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    // MARK: - CSV

    struct CSVOptions {
        /// German Excel: decimal comma, UTF-8 BOM. Separator stays `;`.
        var usesDecimalComma = false
    }

    static func csv(_ snapshot: SurveyExportSnapshot, options: CSVOptions = CSVOptions()) -> Data {
        let header = [
            "Punkt", "Art", "Code", "E_UTM32", "N_UTM32", "H_Boden", "H_Antenne",
            "Lat_WGS84", "Lon_WGS84", "Sigma_Lage", "Sigma_Hoehe", "Anzahl",
            "Zeit_UTC", "Quelle", "Bemerkung"
        ]
        func number(_ value: Double?, _ decimals: Int) -> String {
            let text = optionalFixed(value, decimals)
            return options.usesDecimalComma ? text.replacingOccurrences(of: ".", with: ",") : text
        }
        var rows = [header.joined(separator: ";")]
        for point in snapshot.allPoints {
            let fields = [
                point.name,
                point.category.rawValue,
                point.category.code,
                number(point.utm.easting, 3),
                number(point.utm.northing, 3),
                number(point.groundHeight, 3),
                number(point.antennaHeight, 3),
                number(point.coordinate.latitude, 9),
                number(point.coordinate.longitude, 9),
                number(point.horizontalAccuracy, 3),
                number(point.verticalAccuracy, 3),
                point.sampleCount.map(String.init) ?? "",
                isoTimestamp(point.timestamp),
                point.source,
                point.remark ?? ""
            ]
            rows.append(fields.map(csvEscaped).joined(separator: ";"))
        }
        let text = rows.joined(separator: "\r\n") + "\r\n"
        var data = Data()
        if options.usesDecimalComma { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
        data.append(Data(text.utf8))
        return data
    }

    private static func csvEscaped(_ field: String) -> String {
        guard field.contains(where: { $0 == ";" || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - GeoJSON (RFC 7946, WGS84 lon/lat)

    static func geoJSON(_ snapshot: SurveyExportSnapshot) -> Data {
        var features: [String] = []

        if let parcel = snapshot.parcel {
            let rings = parcel.wgs84Rings.map { ring in
                "[" + closed(ring).map(position).joined(separator: ",") + "]"
            }
            features.append(feature(
                geometry: "{\"type\":\"Polygon\",\"coordinates\":[\(rings.joined(separator: ","))]}",
                properties: [
                    ("art", .string("Flurstück")),
                    ("kennzeichen", .string(parcel.id)),
                    ("bezeichnung", .string(parcel.label)),
                    ("gemeinde", .string(parcel.municipality)),
                    ("gemarkung", .string(parcel.district)),
                    ("flur", .string(parcel.section)),
                    ("flurstueck", .string(parcel.number)),
                    ("flaeche_m2", parcel.area.map { .number($0, 2) } ?? .null),
                    ("quelle", .string("ALKIS NRW"))
                ]
            ))
        }

        if let measurement = snapshot.measurement, measurement.points.count >= 2 {
            let positions = measurement.kind == .area ? closed(measurement.coordinates) : measurement.coordinates
            let coordinates = positions.map(position).joined(separator: ",")
            let geometry = measurement.kind == .area && measurement.points.count >= 3
                ? "{\"type\":\"Polygon\",\"coordinates\":[[\(coordinates)]]}"
                : "{\"type\":\"LineString\",\"coordinates\":[\(coordinates)]}"
            var properties: [(String, JSONScalar)] = [("art", .string(measurement.kind.title))]
            if let length = measurement.length { properties.append(("laenge_m", .number(length, 3))) }
            if let area = measurement.area { properties.append(("flaeche_m2", .number(area, 3))) }
            if let perimeter = measurement.perimeter { properties.append(("umfang_m", .number(perimeter, 3))) }
            features.append(feature(geometry: geometry, properties: properties))
        }

        for point in snapshot.allPoints {
            let geometry = "{\"type\":\"Point\",\"coordinates\":\(position(point.coordinate, height: point.groundHeight))}"
            features.append(feature(geometry: geometry, properties: pointProperties(point)))
        }

        let json = """
        {"type":"FeatureCollection","name":\(jsonString(snapshot.title)),\
        "features":[
        \(features.joined(separator: ",\n"))
        ]}

        """
        return Data(json.utf8)
    }

    private enum JSONScalar {
        case string(String)
        case number(Double, Int)
        case integer(Int)
        case bool(Bool)
        case null

        var rendered: String {
            switch self {
            case .string(let value): return jsonString(value)
            case .number(let value, let decimals): return value.isFinite ? fixed(value, decimals) : "null"
            case .integer(let value): return String(value)
            case .bool(let value): return value ? "true" : "false"
            case .null: return "null"
            }
        }
    }

    private static func pointProperties(_ point: SurveyExportPoint) -> [(String, JSONScalar)] {
        func optional(_ value: Double?, _ decimals: Int) -> JSONScalar {
            value.map { .number($0, decimals) } ?? .null
        }
        return [
            ("name", .string(point.name)),
            ("art", .string(point.category.rawValue)),
            ("code", .string(point.category.code)),
            ("e_utm32", .number(point.utm.easting, 3)),
            ("n_utm32", .number(point.utm.northing, 3)),
            ("h_boden", optional(point.groundHeight, 3)),
            ("h_antenne", optional(point.antennaHeight, 3)),
            ("sigma_lage", optional(point.horizontalAccuracy, 3)),
            ("sigma_hoehe", optional(point.verticalAccuracy, 3)),
            ("anzahl", point.sampleCount.map { .integer($0) } ?? .null),
            ("zeit", point.timestamp.map { .string(isoTimestamp($0)) } ?? .null),
            ("quelle", .string(point.source)),
            ("bemerkung", point.remark.map { .string($0) } ?? .null),
            ("test", .bool(point.isTest))
        ]
    }

    private static func feature(geometry: String, properties: [(String, JSONScalar)]) -> String {
        let props = properties.map { "\(jsonString($0.0)):\($0.1.rendered)" }.joined(separator: ",")
        return "{\"type\":\"Feature\",\"geometry\":\(geometry),\"properties\":{\(props)}}"
    }

    private static func position(_ coordinate: CLLocationCoordinate2D) -> String {
        position(coordinate, height: nil)
    }

    private static func position(_ coordinate: CLLocationCoordinate2D, height: Double?) -> String {
        let base = "\(fixed(coordinate.longitude, 9)),\(fixed(coordinate.latitude, 9))"
        if let height, height.isFinite { return "[\(base),\(fixed(height, 3))]" }
        return "[\(base)]"
    }

    static func jsonString(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }

    private static func closed(_ ring: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard let first = ring.first, let last = ring.last else { return ring }
        if first.latitude == last.latitude && first.longitude == last.longitude { return ring }
        return ring + [first]
    }

    // MARK: - KML (Google Earth)

    static func kml(_ snapshot: SurveyExportSnapshot) -> Data {
        var body = ""
        if let parcel = snapshot.parcel {
            let outer = parcel.wgs84Rings.first ?? []
            let holes = parcel.wgs84Rings.dropFirst().map { ring in
                "<innerBoundaryIs><LinearRing><coordinates>\(kmlCoordinates(closed(ring)))</coordinates></LinearRing></innerBoundaryIs>"
            }.joined()
            body += """
            <Folder><name>Flurstück</name>
            <Placemark><name>\(xmlEscaped(parcel.label))</name>
            <description>\(xmlEscaped(parcelDescription(parcel)))</description>
            <styleUrl>#parcel</styleUrl>
            <Polygon><tessellate>1</tessellate>\
            <outerBoundaryIs><LinearRing><coordinates>\(kmlCoordinates(closed(outer)))</coordinates></LinearRing></outerBoundaryIs>\
            \(holes)</Polygon></Placemark>
            </Folder>

            """
        }
        if let measurement = snapshot.measurement, measurement.points.count >= 2 {
            let geometry: String
            if measurement.kind == .area && measurement.points.count >= 3 {
                geometry = "<Polygon><tessellate>1</tessellate><outerBoundaryIs><LinearRing><coordinates>\(kmlCoordinates(closed(measurement.coordinates)))</coordinates></LinearRing></outerBoundaryIs></Polygon>"
            } else {
                geometry = "<LineString><tessellate>1</tessellate><coordinates>\(kmlCoordinates(measurement.coordinates))</coordinates></LineString>"
            }
            body += """
            <Folder><name>\(xmlEscaped(measurement.kind.title))</name>
            <Placemark><name>\(xmlEscaped(measurement.kind.title))</name>
            <description>\(xmlEscaped(measurementDescription(measurement)))</description>
            <styleUrl>#measurement</styleUrl>\(geometry)</Placemark>
            </Folder>

            """
        }
        let groups: [(String, [SurveyExportPoint])] = [
            ("Grenzpunkte", snapshot.boundaryPoints),
            ("Messpunkte", snapshot.measurement?.points ?? []),
            ("Geländepunkte", snapshot.terrain?.points ?? [])
        ]
        for (title, points) in groups where !points.isEmpty {
            body += "<Folder><name>\(title)</name>\n"
            for point in points {
                let style = point.category == .boundary ? "#boundary" : "#point"
                body += """
                <Placemark><name>\(xmlEscaped(point.name))</name>\
                <description>\(xmlEscaped(pointDescription(point)))</description>\
                <styleUrl>\(style)</styleUrl>\
                <Point><coordinates>\(fixed(point.coordinate.longitude, 9)),\(fixed(point.coordinate.latitude, 9)),0</coordinates></Point></Placemark>

                """
            }
            body += "</Folder>\n"
        }

        let document = """
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2">
        <Document>
        <name>\(xmlEscaped(snapshot.title))</name>
        <description>Erstellt mit KRover am \(isoTimestamp(snapshot.createdAt)). Lagekoordinaten zusätzlich in \(crsDescription) in den Punktbeschreibungen.</description>
        <Style id="parcel"><LineStyle><color>ff00d7ff</color><width>3</width></LineStyle><PolyStyle><color>3300d7ff</color></PolyStyle></Style>
        <Style id="measurement"><LineStyle><color>ffff8a1e</color><width>3</width></LineStyle><PolyStyle><color>40ff8a1e</color></PolyStyle></Style>
        <Style id="point"><IconStyle><color>ffff8a1e</color><scale>0.8</scale><Icon><href>http://maps.google.com/mapfiles/kml/shapes/placemark_circle.png</href></Icon></IconStyle></Style>
        <Style id="boundary"><IconStyle><color>ff3cb043</color><scale>0.7</scale><Icon><href>http://maps.google.com/mapfiles/kml/shapes/placemark_circle.png</href></Icon></IconStyle></Style>
        \(body)</Document>
        </kml>

        """
        return Data(document.utf8)
    }

    private static func kmlCoordinates(_ coordinates: [CLLocationCoordinate2D]) -> String {
        coordinates.map { "\(fixed($0.longitude, 9)),\(fixed($0.latitude, 9)),0" }.joined(separator: " ")
    }

    static func parcelDescription(_ parcel: SurveyExportParcel) -> String {
        var lines = [parcel.cadastralDesignation]
        if !parcel.municipality.isEmpty { lines.append("Gemeinde \(parcel.municipality)") }
        if let area = parcel.area { lines.append("Amtliche Fläche \(fixed(area, 0)) m²") }
        lines.append("Kennzeichen \(parcel.id)")
        return lines.joined(separator: "\n")
    }

    static func measurementDescription(_ measurement: SurveyExportMeasurement) -> String {
        var lines = ["\(measurement.points.count) Punkte"]
        if let length = measurement.length { lines.append("Länge \(fixed(length, 3)) m") }
        if let area = measurement.area { lines.append("Fläche \(fixed(area, 3)) m²") }
        if let perimeter = measurement.perimeter { lines.append("Umfang \(fixed(perimeter, 3)) m") }
        return lines.joined(separator: "\n")
    }

    static func pointDescription(_ point: SurveyExportPoint) -> String {
        var lines = [
            point.category.rawValue,
            "E \(fixed(point.utm.easting, 3)) · N \(fixed(point.utm.northing, 3))"
        ]
        if let height = point.groundHeight { lines.append("H Boden \(fixed(height, 3)) m") }
        if let sigma = point.horizontalAccuracy { lines.append("σ Lage ±\(fixed(sigma, 3)) m") }
        lines.append("Quelle \(point.source)")
        if let remark = point.remark { lines.append(remark) }
        return lines.joined(separator: "\n")
    }

    static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    // MARK: - GPX

    static func gpx(_ snapshot: SurveyExportSnapshot) -> Data {
        var body = ""
        for point in snapshot.allPoints {
            body += "<wpt lat=\"\(fixed(point.coordinate.latitude, 9))\" lon=\"\(fixed(point.coordinate.longitude, 9))\">"
            if let height = point.groundHeight { body += "<ele>\(fixed(height, 3))</ele>" }
            if let time = point.timestamp { body += "<time>\(isoTimestamp(time))</time>" }
            body += "<name>\(xmlEscaped(point.name))</name>"
            body += "<desc>\(xmlEscaped(pointDescription(point)))</desc>"
            body += "<type>\(xmlEscaped(point.category.rawValue))</type></wpt>\n"
        }
        func track(_ name: String, _ coordinates: [CLLocationCoordinate2D], heights: [Double?]) -> String {
            var text = "<trk><name>\(xmlEscaped(name))</name><trkseg>"
            for (coordinate, height) in zip(coordinates, heights) {
                text += "<trkpt lat=\"\(fixed(coordinate.latitude, 9))\" lon=\"\(fixed(coordinate.longitude, 9))\">"
                if let height { text += "<ele>\(fixed(height, 3))</ele>" }
                text += "</trkpt>"
            }
            return text + "</trkseg></trk>\n"
        }
        if let parcel = snapshot.parcel {
            for (index, ring) in parcel.wgs84Rings.enumerated() {
                let coordinates = closed(ring)
                let name = index == 0 ? parcel.label : "\(parcel.label) (Aussparung \(index))"
                body += track(name, coordinates, heights: coordinates.map { _ in nil })
            }
        }
        if let measurement = snapshot.measurement, measurement.points.count >= 2 {
            let points = measurement.kind == .area ? measurement.points + [measurement.points[0]] : measurement.points
            body += track(measurement.kind.title, points.map(\.coordinate), heights: points.map(\.groundHeight))
        }
        let document = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="KRover" xmlns="http://www.topografix.com/GPX/1/1">
        <metadata><name>\(xmlEscaped(snapshot.title))</name><time>\(isoTimestamp(snapshot.createdAt))</time></metadata>
        \(body)</gpx>

        """
        return Data(document.utf8)
    }

    // MARK: - DXF (AutoCAD R12 ASCII, UTM coordinates)

    enum DXFLayer: String, CaseIterable {
        case parcel = "FLURSTUECK"
        case boundaryPoints = "GRENZPUNKTE"
        case measurementLine = "MESSUNG"
        case measurementPoints = "MESSPUNKTE"
        case terrainPoints = "GELAENDEPUNKTE"
        case terrainSurface = "GELAENDE_TIN"
        case contours = "HOEHENLINIEN"
        case pointNames = "PUNKTNUMMERN"
        case heights = "HOEHEN"

        /// AutoCAD color index.
        var color: Int {
            switch self {
            case .parcel: return 2
            case .boundaryPoints: return 3
            case .measurementLine: return 5
            case .measurementPoints: return 5
            case .terrainPoints: return 6
            case .terrainSurface: return 8
            case .contours: return 30
            case .pointNames: return 7
            case .heights: return 4
            }
        }
    }

    static func dxf(_ snapshot: SurveyExportSnapshot) -> Data {
        var writer = DXFWriter()
        let textHeight = 0.25

        if let parcel = snapshot.parcel {
            for ring in parcel.utmRings where ring.count >= 2 {
                writer.polyline(ring.map { ($0.easting, $0.northing, 0) }, closed: true, layer: .parcel)
            }
        }
        if let measurement = snapshot.measurement, measurement.points.count >= 2 {
            writer.polyline(
                measurement.points.map { ($0.utm.easting, $0.utm.northing, $0.groundHeight ?? 0) },
                closed: measurement.kind == .area,
                layer: .measurementLine
            )
        }
        for point in snapshot.allPoints {
            let layer: DXFLayer
            switch point.category {
            case .boundary: layer = .boundaryPoints
            case .terrain: layer = .terrainPoints
            default: layer = .measurementPoints
            }
            let z = point.groundHeight ?? 0
            writer.point(point.utm.easting, point.utm.northing, z, layer: layer)
            writer.text(
                point.name,
                x: point.utm.easting + textHeight * 0.4,
                y: point.utm.northing + textHeight * 0.4,
                height: textHeight,
                layer: .pointNames
            )
            if let height = point.groundHeight {
                writer.text(
                    fixed(height, 2),
                    x: point.utm.easting + textHeight * 0.4,
                    y: point.utm.northing - textHeight * 1.4,
                    height: textHeight * 0.8,
                    layer: .heights
                )
            }
        }
        if let terrain = snapshot.terrain, let model = terrain.model, model.canInterpolate {
            let poleLength = snapshot.poleLength
            func world(_ index: Int) -> (Double, Double, Double) {
                let vertex = model.vertices[index]
                return (
                    vertex.position.x + model.origin.easting,
                    vertex.position.y + model.origin.northing,
                    vertex.height - poleLength
                )
            }
            for triangle in model.triangles {
                writer.face(world(triangle.a), world(triangle.b), world(triangle.c), layer: .terrainSurface)
            }
            let interval = TerrainModel.contourInterval(forRange: model.heightRange)
            for segment in model.contourSegments(interval: interval) {
                let z = segment.level - poleLength
                writer.line(
                    (segment.start.x + model.origin.easting, segment.start.y + model.origin.northing, z),
                    (segment.end.x + model.origin.easting, segment.end.y + model.origin.northing, z),
                    layer: .contours
                )
            }
        }
        return Data(writer.document().utf8)
    }

    struct DXFWriter {
        private var entities = ""

        private mutating func pair(_ code: Int, _ value: String) {
            entities += "\(code)\n\(value)\n"
        }

        private mutating func coordinate(_ base: Int, _ point: (Double, Double, Double)) {
            pair(base, fixed(point.0, 4))
            pair(base + 10, fixed(point.1, 4))
            pair(base + 20, fixed(point.2, 4))
        }

        mutating func point(_ x: Double, _ y: Double, _ z: Double, layer: DXFLayer) {
            pair(0, "POINT")
            pair(8, layer.rawValue)
            coordinate(10, (x, y, z))
        }

        mutating func text(_ value: String, x: Double, y: Double, height: Double, layer: DXFLayer) {
            pair(0, "TEXT")
            pair(8, layer.rawValue)
            coordinate(10, (x, y, 0))
            pair(40, fixed(height, 3))
            pair(1, DXFWriter.ascii(value))
        }

        mutating func line(_ start: (Double, Double, Double), _ end: (Double, Double, Double), layer: DXFLayer) {
            pair(0, "LINE")
            pair(8, layer.rawValue)
            coordinate(10, start)
            coordinate(11, end)
        }

        mutating func polyline(_ points: [(Double, Double, Double)], closed: Bool, layer: DXFLayer) {
            let is3D = points.contains { $0.2 != 0 }
            pair(0, "POLYLINE")
            pair(8, layer.rawValue)
            pair(66, "1")
            coordinate(10, (0, 0, 0))
            pair(70, String((closed ? 1 : 0) | (is3D ? 8 : 0)))
            for point in points {
                pair(0, "VERTEX")
                pair(8, layer.rawValue)
                coordinate(10, point)
                if is3D { pair(70, "32") }
            }
            pair(0, "SEQEND")
            pair(8, layer.rawValue)
        }

        mutating func face(
            _ a: (Double, Double, Double),
            _ b: (Double, Double, Double),
            _ c: (Double, Double, Double),
            layer: DXFLayer
        ) {
            pair(0, "3DFACE")
            pair(8, layer.rawValue)
            coordinate(10, a)
            coordinate(11, b)
            coordinate(12, c)
            coordinate(13, c)
        }

        func document() -> String {
            var header = "0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1009\n9\n$INSUNITS\n70\n6\n0\nENDSEC\n"
            header += "0\nSECTION\n2\nTABLES\n0\nTABLE\n2\nLAYER\n70\n\(DXFLayer.allCases.count)\n"
            for layer in DXFLayer.allCases {
                header += "0\nLAYER\n2\n\(layer.rawValue)\n70\n0\n62\n\(layer.color)\n6\nCONTINUOUS\n"
            }
            header += "0\nENDTAB\n0\nENDSEC\n"
            return header + "0\nSECTION\n2\nENTITIES\n" + entities + "0\nENDSEC\n0\nEOF\n"
        }

        /// R12 files are not UTF-8; transliterate umlauts and drop the rest.
        static func ascii(_ value: String) -> String {
            let replacements: [Character: String] = [
                "ä": "ae", "ö": "oe", "ü": "ue", "Ä": "Ae", "Ö": "Oe", "Ü": "Ue", "ß": "ss"
            ]
            return value.map { character -> String in
                if let replacement = replacements[character] { return replacement }
                return character.isASCII && !(character.asciiValue.map { $0 < 0x20 } ?? false)
                    ? String(character) : "_"
            }.joined()
        }
    }

    // MARK: - LandXML 1.2 (points + terrain surface)

    static func landXML(_ snapshot: SurveyExportSnapshot) -> Data {
        // LandXML uses "northing easting elevation" order.
        func nez(_ northing: Double, _ easting: Double, _ height: Double?) -> String {
            var text = "\(fixed(northing, 4)) \(fixed(easting, 4))"
            if let height { text += " \(fixed(height, 4))" }
            return text
        }
        var body = ""
        let points = snapshot.allPoints
        if !points.isEmpty {
            body += "<CgPoints>\n"
            for point in points {
                body += "<CgPoint name=\"\(xmlEscaped(point.name))\" code=\"\(point.category.code)\" desc=\"\(xmlEscaped(point.category.rawValue))\">\(nez(point.utm.northing, point.utm.easting, point.groundHeight))</CgPoint>\n"
            }
            body += "</CgPoints>\n"
        }
        if let parcel = snapshot.parcel, let outer = parcel.utmRings.first, outer.count >= 3 {
            let ring = outer + [outer[0]]
            body += "<Parcels><Parcel name=\"\(xmlEscaped(parcel.number.isEmpty ? parcel.id : parcel.number))\" desc=\"\(xmlEscaped(parcel.cadastralDesignation))\""
            if let area = parcel.area { body += " area=\"\(fixed(area, 2))\"" }
            body += "><CoordGeom>"
            for (start, end) in zip(ring, ring.dropFirst()) {
                body += "<Line><Start>\(nez(start.northing, start.easting, nil))</Start><End>\(nez(end.northing, end.easting, nil))</End></Line>"
            }
            body += "</CoordGeom></Parcel></Parcels>\n"
        }
        if let terrain = snapshot.terrain, let model = terrain.model, model.canInterpolate {
            let poleLength = snapshot.poleLength
            body += "<Surfaces><Surface name=\"Gelaende\" desc=\"\(xmlEscaped(snapshot.parcel?.label ?? "Geländeaufnahme"))\">"
            body += "<Definition surfType=\"TIN\"><Pnts>\n"
            for (index, vertex) in model.vertices.enumerated() {
                body += "<P id=\"\(index + 1)\">\(nez(vertex.position.y + model.origin.northing, vertex.position.x + model.origin.easting, vertex.height - poleLength))</P>\n"
            }
            body += "</Pnts><Faces>\n"
            for triangle in model.triangles {
                body += "<F>\(triangle.a + 1) \(triangle.b + 1) \(triangle.c + 1)</F>\n"
            }
            body += "</Faces></Definition></Surface></Surfaces>\n"
        }
        let document = """
        <?xml version="1.0" encoding="UTF-8"?>
        <LandXML xmlns="http://www.landxml.org/schema/LandXML-1.2" version="1.2" \
        date="\(dayString(snapshot.createdAt))" time="\(timeString(snapshot.createdAt))">
        <Units><Metric areaUnit="squareMeter" linearUnit="meter" volumeUnit="cubicMeter" \
        temperatureUnit="celsius" pressureUnit="HPA" angularUnit="decimal degrees" directionUnit="decimal degrees"/></Units>
        <CoordinateSystem name="ETRS89 / UTM zone 32N" epsgCode="25832" horizontalDatum="ETRS89" \
        desc="\(xmlEscaped(heightDescription))"/>
        <Application name="KRover" manufacturer="KRover"/>
        \(body)</LandXML>

        """
        return Data(document.utf8)
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
