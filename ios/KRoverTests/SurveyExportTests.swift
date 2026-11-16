import CoreLocation
import XCTest
@testable import KRover

final class SurveyExportTests: XCTestCase {
    private let origin = UTMCoordinate(easting: 364_000, northing: 5_620_000)

    private func coordinate(_ x: Double, _ y: Double) -> CLLocationCoordinate2D {
        UTM32Projection.unproject(UTMCoordinate(easting: origin.easting + x, northing: origin.northing + y))
    }

    private func point(
        _ name: String,
        _ category: SurveyExportPoint.Category,
        _ x: Double,
        _ y: Double,
        height: Double? = nil,
        isTest: Bool = false
    ) -> SurveyExportPoint {
        SurveyExportPoint(
            name: name,
            category: category,
            coordinate: coordinate(x, y),
            utm: UTMCoordinate(easting: origin.easting + x, northing: origin.northing + y),
            antennaHeight: height,
            groundHeight: height.map { $0 - 2 },
            horizontalAccuracy: 0.012,
            verticalAccuracy: height == nil ? nil : 0.02,
            sampleCount: 5,
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            source: isTest ? "iPhone-GPS (Test)" : "Rover RTK",
            remark: nil,
            isTest: isTest
        )
    }

    private func makeSnapshot(withTerrain: Bool = false) -> SurveyExportSnapshot {
        let ring = [(0.0, 0.0), (20.0, 0.0), (20.0, 15.0), (0.0, 15.0)]
        let parcel = SurveyExportParcel(
            id: "05123400100120______",
            label: "Musterweg 1",
            municipality: "Musterstadt",
            district: "Musterhausen",
            section: "3",
            number: "120",
            area: 300,
            updatedAt: nil,
            wgs84Rings: [ring.map { coordinate($0.0, $0.1) }],
            utmRings: [ring.map { UTMCoordinate(easting: origin.easting + $0.0, northing: origin.northing + $0.1) }]
        )
        let measurement = SurveyExportMeasurement(kind: .area, points: [
            point("F1", .area, 1, 1, height: 102),
            point("F2", .area, 11, 1, height: 102.5),
            point("F3", .area, 11, 9, height: 103)
        ])
        var terrain: SurveyExportTerrain?
        if withTerrain {
            let surveyPoints = [(2.0, 2.0, 100.0), (18.0, 2.0, 101.0), (18.0, 13.0, 102.0), (2.0, 13.0, 101.0), (10.0, 7.0, 101.5)]
                .map { TerrainSurveyPoint(coordinate: coordinate($0.0, $0.1), altitudeMSL: $0.2) }
            terrain = SurveyExportTerrain(
                points: surveyPoints.enumerated().map {
                    SurveyExportPoint(terrainPoint: $0.element, name: "G\($0.offset + 1)", poleLength: 2)
                },
                model: TerrainModel(points: surveyPoints, parcelRings: parcel.utmRings)
            )
        }
        return SurveyExportSnapshot(
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            poleLength: 2,
            mapBackground: .cadastre,
            parcel: parcel,
            boundaryPoints: [point("GP1", .boundary, 0, 0), point("GP2", .boundary, 20, 0)],
            measurement: measurement,
            terrain: terrain
        )
    }

    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    func testCSVContainsHeaderAndAllPointsInUTM() {
        let csv = text(SurveyExportWriters.csv(makeSnapshot()))
        let lines = csv.split(separator: "\r\n")
        XCTAssertEqual(lines.count, 1 + 5)
        XCTAssertTrue(lines[0].hasPrefix("Punkt;Art;Code;E_UTM32;N_UTM32;H_Boden"))
        let f2 = lines.first { $0.hasPrefix("F2;") }!.split(separator: ";", omittingEmptySubsequences: false)
        XCTAssertEqual(f2[3], "364011.000")
        XCTAssertEqual(f2[4], "5620001.000")
        XCTAssertEqual(f2[5], "100.500")
        XCTAssertEqual(f2[6], "102.500")
    }

    func testCSVDecimalCommaVariantForExcel() {
        let data = SurveyExportWriters.csv(makeSnapshot(), options: .init(usesDecimalComma: true))
        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF], "Excel needs a BOM for umlauts")
        XCTAssertTrue(text(data).contains("364011,000;5620001,000"))
    }

    func testCSVEscapesSeparators() {
        var snapshot = makeSnapshot()
        snapshot.boundaryPoints[0].remark = "Grenzstein; \"alt\""
        let csv = text(SurveyExportWriters.csv(snapshot))
        XCTAssertTrue(csv.contains("\"Grenzstein; \"\"alt\"\"\""))
    }

    func testGeoJSONIsValidAndUsesLonLat() throws {
        let data = SurveyExportWriters.geoJSON(makeSnapshot())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let features = try XCTUnwrap(object["features"] as? [[String: Any]])
        // parcel + measurement polygon + 5 points
        XCTAssertEqual(features.count, 7)
        let parcelGeometry = try XCTUnwrap(features[0]["geometry"] as? [String: Any])
        XCTAssertEqual(parcelGeometry["type"] as? String, "Polygon")
        let ring = try XCTUnwrap((parcelGeometry["coordinates"] as? [[[Double]]])?.first)
        XCTAssertEqual(ring.first, ring.last, "rings must be closed")
        XCTAssertEqual(ring.count, 5)
        let firstPosition = try XCTUnwrap(ring.first)
        XCTAssertEqual(firstPosition[0], coordinate(0, 0).longitude, accuracy: 1e-8)
        XCTAssertEqual(firstPosition[1], coordinate(0, 0).latitude, accuracy: 1e-8)
    }

    func testKMLAndGPXAreWellFormedXML() {
        for data in [SurveyExportWriters.kml(makeSnapshot()), SurveyExportWriters.gpx(makeSnapshot()),
                     SurveyExportWriters.landXML(makeSnapshot(withTerrain: true))] {
            let parser = XMLParser(data: data)
            XCTAssertTrue(parser.parse(), "\(String(describing: parser.parserError))\n\(text(data).prefix(300))")
        }
    }

    func testDXFStructureAndLayers() {
        let dxf = text(SurveyExportWriters.dxf(makeSnapshot(withTerrain: true)))
        XCTAssertTrue(dxf.hasPrefix("0\nSECTION\n2\nHEADER"))
        XCTAssertTrue(dxf.hasSuffix("0\nEOF\n"))
        XCTAssertTrue(dxf.contains("\nFLURSTUECK\n"))
        XCTAssertTrue(dxf.contains("\n3DFACE\n"))
        XCTAssertTrue(dxf.contains("\n364011.0000\n"))
        // Group codes and values alternate, so the line count must be even.
        XCTAssertEqual(dxf.split(separator: "\n", omittingEmptySubsequences: false).dropLast().count % 2, 0)
        XCTAssertFalse(dxf.unicodeScalars.contains { !$0.isASCII }, "R12 DXF must stay ASCII")
    }

    func testLandXMLContainsTINFaces() {
        let snapshot = makeSnapshot(withTerrain: true)
        let xml = text(SurveyExportWriters.landXML(snapshot))
        let faceCount = xml.components(separatedBy: "<F>").count - 1
        XCTAssertEqual(faceCount, snapshot.terrain?.model?.triangles.count)
        XCTAssertGreaterThan(faceCount, 0)
        // Ground height = antenna height − pole length.
        XCTAssertTrue(xml.contains(" 98.0000</P>"))
    }

    func testContentFilterAndFileName() {
        let snapshot = makeSnapshot().filtered(by: [.measurement])
        XCTAssertNil(snapshot.parcel)
        XCTAssertTrue(snapshot.boundaryPoints.isEmpty)
        XCTAssertEqual(snapshot.allPoints.count, 3)
        XCTAssertTrue(makeSnapshot().fileBaseName.hasPrefix("KRover_Flur-3-Flst-120_"))
    }

    func testDXFTransliteratesUmlauts() {
        XCTAssertEqual(SurveyExportWriters.DXFWriter.ascii("Grenzpunkt Müß"), "Grenzpunkt Muess")
    }

    @MainActor
    func testPDFAndPlanImageRenderWithoutBackground() async throws {
        let snapshot = makeSnapshot(withTerrain: true)
        let pdf = await SurveyPlanRenderer.pdfReport(snapshot, background: nil)
        XCTAssertTrue(pdf.starts(with: Data("%PDF".utf8)))
        let png = await SurveyPlanRenderer.planImage(snapshot, background: nil)
        let image = try XCTUnwrap(png.flatMap(UIImage.init(data:)))
        XCTAssertEqual(image.size.width * image.scale, 2400, accuracy: 1, "1200 pt at 2x")
    }
}
