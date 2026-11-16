import CoreLocation
import XCTest
@testable import KRover

final class TerrainModelTests: XCTestCase {
    private let origin = UTMCoordinate(easting: 360_000, northing: 5_650_000)

    private func coordinate(_ x: Double, _ y: Double) -> CLLocationCoordinate2D {
        UTM32Projection.unproject(UTMCoordinate(easting: origin.easting + x, northing: origin.northing + y))
    }

    private func squareRing(size: Double = 20) -> [UTMCoordinate] {
        [(0, 0), (size, 0), (size, size), (0, size)].map {
            UTMCoordinate(easting: origin.easting + $0.0, northing: origin.northing + $0.1)
        }
    }

    private func planePoints(_ positions: [(Double, Double)], height: (Double, Double) -> Double) -> [TerrainSurveyPoint] {
        positions.map { TerrainSurveyPoint(coordinate: coordinate($0.0, $0.1), altitudeMSL: height($0.0, $0.1)) }
    }

    func testDelaunayTriangulatesSquareWithCenter() {
        let points: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(0, 10), SIMD2(5, 5)]
        let triangles = DelaunayTriangulator.triangulate(points)
        XCTAssertEqual(triangles.count, 4)
        for triangle in triangles {
            XCTAssertGreaterThan(DelaunayTriangulator.doubleArea(triangle, points), 0, "triangles must be counter-clockwise")
        }
    }

    func testCollinearPointsYieldNoSurface() {
        let points = planePoints([(1, 1), (5, 5), (9, 9)]) { x, _ in 100 + x }
        let model = TerrainModel(points: points, parcelRings: [squareRing()])
        XCTAssertNotNil(model)
        XCTAssertFalse(model!.canInterpolate)
        XCTAssertNil(model!.height(at: SIMD2(5, 5)))
    }

    func testLinearInterpolationReproducesPlane() throws {
        let height: (Double, Double) -> Double = { x, y in 100 + 0.1 * x + 0.05 * y }
        let points = planePoints([(0, 0), (20, 0), (20, 20), (0, 20), (8, 11)], height: height)
        let model = try XCTUnwrap(TerrainModel(points: points, parcelRings: [squareRing()]))
        XCTAssertTrue(model.canInterpolate)
        // Projection round trip costs well below a millimetre.
        XCTAssertEqual(try XCTUnwrap(model.height(at: SIMD2(13, 4))), height(13, 4), accuracy: 0.002)
        XCTAssertEqual(try XCTUnwrap(model.height(at: SIMD2(2, 18))), height(2, 18), accuracy: 0.002)
        XCTAssertNil(model.height(at: SIMD2(-3, 5)), "no extrapolation outside the measured hull")

        let statistics = model.statistics()
        XCTAssertEqual(try XCTUnwrap(statistics.meanSlopePercent), hypot(0.1, 0.05) * 100, accuracy: 0.05)
        // Surface rises toward east-north-east, so it falls toward west-south-west.
        let bearing = try XCTUnwrap(statistics.downhillBearing)
        XCTAssertEqual(bearing, 180 + atan2(0.1, 0.05) * 180 / .pi, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(statistics.coveredFraction), 1, accuracy: 0.02)
    }

    func testProfileFollowsSurfaceAndHasGapsOutsideHull() throws {
        let points = planePoints([(5, 5), (15, 5), (15, 15), (5, 15)]) { x, _ in 50 + 0.2 * x }
        let model = try XCTUnwrap(TerrainModel(points: points, parcelRings: [squareRing()]))
        let samples = model.profile(from: SIMD2(0, 10), to: SIMD2(20, 10), sampleCount: 21)
        XCTAssertEqual(samples.count, 21)
        XCTAssertNil(samples[0].height)
        XCTAssertNil(samples[20].height)
        XCTAssertEqual(try XCTUnwrap(samples[10].height), 52, accuracy: 0.002)
        XCTAssertEqual(samples[20].distance, 20, accuracy: 1e-9)
    }

    func testDefaultProfileRunsFromLowToHighAcrossParcel() throws {
        let points = planePoints([(2, 10), (18, 10), (10, 2), (10, 18)]) { x, _ in 10 + x }
        let model = try XCTUnwrap(TerrainModel(points: points, parcelRings: [squareRing()]))
        let line = model.defaultProfileLine()
        XCTAssertEqual(line.0.x, 0, accuracy: 0.01)
        XCTAssertEqual(line.1.x, 20, accuracy: 0.01)
        XCTAssertEqual(line.0.y, 10, accuracy: 0.01)
    }

    func testContoursCrossSurfaceAtLevels() throws {
        let points = planePoints([(0, 0), (20, 0), (20, 20), (0, 20)]) { x, _ in 100 + 0.1 * x }
        let model = try XCTUnwrap(TerrainModel(points: points, parcelRings: [squareRing()]))
        let interval = TerrainModel.contourInterval(forRange: model.heightRange)
        XCTAssertEqual(interval, 0.2)
        let segments = model.contourSegments(interval: interval)
        XCTAssertFalse(segments.isEmpty)
        for segment in segments {
            // A plane rising in x has vertical contour lines at x = (level - 100) / 0.1.
            XCTAssertEqual(segment.start.x, (segment.level - 100) / 0.1, accuracy: 0.02)
            XCTAssertEqual(segment.end.x, (segment.level - 100) / 0.1, accuracy: 0.02)
        }
    }

    func testNearbyRepeatedMeasurementsAreMerged() throws {
        let points = [
            TerrainSurveyPoint(coordinate: coordinate(5, 5), altitudeMSL: 100.00),
            TerrainSurveyPoint(coordinate: coordinate(5.01, 5), altitudeMSL: 100.02),
            TerrainSurveyPoint(coordinate: coordinate(15, 5), altitudeMSL: 101),
            TerrainSurveyPoint(coordinate: coordinate(10, 15), altitudeMSL: 102)
        ]
        let model = try XCTUnwrap(TerrainModel(points: points, parcelRings: [squareRing()]))
        XCTAssertEqual(model.vertices.count, 3)
        XCTAssertEqual(model.minHeight, 100.01, accuracy: 1e-6)
    }

    func testContainmentRespectsHolesAndTolerance() {
        let outer: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(0, 10)]
        let hole: [SIMD2<Double>] = [SIMD2(4, 4), SIMD2(6, 4), SIMD2(6, 6), SIMD2(4, 6)]
        XCTAssertTrue(TerrainGeometry.contains(SIMD2(2, 2), rings: [outer, hole]))
        XCTAssertFalse(TerrainGeometry.contains(SIMD2(5, 5), rings: [outer, hole]))
        XCTAssertFalse(TerrainGeometry.contains(SIMD2(10.2, 5), rings: [outer]))
        XCTAssertEqual(TerrainGeometry.distanceToBoundary(SIMD2(10.2, 5), rings: [outer]), 0.2, accuracy: 1e-9)
    }

    func testRasterCoversParcel() throws {
        let points = planePoints([(0, 0), (20, 0), (20, 20), (0, 20)]) { x, y in 100 + 0.1 * x + 0.1 * y }
        let model = try XCTUnwrap(TerrainModel(points: points, parcelRings: [squareRing()]))
        let raster = try XCTUnwrap(model.makeRaster(maxDimension: 64))
        XCTAssertLessThanOrEqual(max(raster.image.width, raster.image.height), 65)
        XCTAssertLessThanOrEqual(raster.bounds.minX, 0)
        XCTAssertGreaterThanOrEqual(raster.bounds.maxY, 20)
    }

    func testSurveyStoreRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("terrain-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TerrainSurveyStore(directory: directory)
        let points = planePoints([(1, 2), (3, 4)]) { _, _ in 99.5 }
        try store.save(points, parcelID: "05/123:4-ab", parcelLabel: "Test")
        let loaded = store.load(parcelID: "05/123:4-ab")
        XCTAssertEqual(loaded.map(\.id), points.map(\.id))
        XCTAssertEqual(loaded.first?.altitudeMSL, 99.5)
        try store.save([], parcelID: "05/123:4-ab", parcelLabel: "Test")
        XCTAssertTrue(store.load(parcelID: "05/123:4-ab").isEmpty)
    }
}
