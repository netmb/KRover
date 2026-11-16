import CoreGraphics
import CoreLocation
import Foundation
import simd

/// A single height measurement inside a parcel. Persisted per parcel so a
/// terrain survey can be continued across app launches.
struct TerrainSurveyPoint: Codable, Identifiable, Equatable {
    var id: UUID
    var latitude: Double
    var longitude: Double
    var altitudeMSL: Double
    var estimatedVerticalAccuracy: Double?
    var estimatedHorizontalAccuracy: Double
    var sampleCount: Int
    var isTest: Bool
    var timestamp: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(
        id: UUID = UUID(),
        coordinate: CLLocationCoordinate2D,
        altitudeMSL: Double,
        estimatedVerticalAccuracy: Double? = nil,
        estimatedHorizontalAccuracy: Double = 0,
        sampleCount: Int = 1,
        isTest: Bool = false,
        timestamp: Date = Date()
    ) {
        self.id = id
        latitude = coordinate.latitude
        longitude = coordinate.longitude
        self.altitudeMSL = altitudeMSL
        self.estimatedVerticalAccuracy = estimatedVerticalAccuracy
        self.estimatedHorizontalAccuracy = estimatedHorizontalAccuracy
        self.sampleCount = sampleCount
        self.isTest = isTest
        self.timestamp = timestamp
    }

    init?(measurement: PointMeasurementResult) {
        guard let altitude = measurement.altitudeMSL, altitude.isFinite else { return nil }
        self.init(
            coordinate: measurement.coordinate,
            altitudeMSL: altitude,
            estimatedVerticalAccuracy: measurement.estimatedVerticalAccuracy,
            estimatedHorizontalAccuracy: measurement.estimatedHorizontalAccuracy,
            sampleCount: measurement.sampleCount,
            isTest: measurement.source.isTest,
            timestamp: measurement.timestamp
        )
    }
}

// MARK: - Planar geometry helpers (local metric coordinates)

enum TerrainGeometry {
    /// Even-odd rule over all rings, so holes and multi-part parcels work
    /// without knowing which ring is the outer one.
    static func contains(_ point: SIMD2<Double>, rings: [[SIMD2<Double>]]) -> Bool {
        var inside = false
        for ring in rings where ring.count >= 3 {
            var previous = ring[ring.count - 1]
            for current in ring {
                if (current.y > point.y) != (previous.y > point.y) {
                    let crossingX = previous.x + (point.y - previous.y)
                        / (current.y - previous.y) * (current.x - previous.x)
                    if point.x < crossingX { inside.toggle() }
                }
                previous = current
            }
        }
        return inside
    }

    static func distanceToBoundary(_ point: SIMD2<Double>, rings: [[SIMD2<Double>]]) -> Double {
        var best = Double.infinity
        for ring in rings where ring.count >= 2 {
            var previous = ring[ring.count - 1]
            for current in ring {
                best = min(best, distance(point, toSegment: previous, current))
                previous = current
            }
        }
        return best
    }

    static func distance(
        _ point: SIMD2<Double>,
        toSegment start: SIMD2<Double>,
        _ end: SIMD2<Double>
    ) -> Double {
        let segment = end - start
        let lengthSquared = simd_length_squared(segment)
        guard lengthSquared > 0 else { return simd_distance(point, start) }
        let t = min(1, max(0, simd_dot(point - start, segment) / lengthSquared))
        return simd_distance(point, start + t * segment)
    }

    /// Clips the infinite line through `point` with `direction` to the
    /// outermost crossings with the parcel boundary.
    static func clipLine(
        through point: SIMD2<Double>,
        direction: SIMD2<Double>,
        rings: [[SIMD2<Double>]]
    ) -> (SIMD2<Double>, SIMD2<Double>)? {
        let length = simd_length(direction)
        guard length > 1e-9 else { return nil }
        let d = direction / length
        var minimum = Double.infinity
        var maximum = -Double.infinity
        for ring in rings where ring.count >= 2 {
            var previous = ring[ring.count - 1]
            for current in ring {
                let edge = current - previous
                let denominator = cross(d, edge)
                if abs(denominator) > 1e-12 {
                    let offset = previous - point
                    let t = cross(offset, edge) / denominator
                    let u = cross(offset, d) / denominator
                    if u >= -1e-9 && u <= 1 + 1e-9 {
                        minimum = min(minimum, t)
                        maximum = max(maximum, t)
                    }
                }
                previous = current
            }
        }
        guard minimum.isFinite, maximum.isFinite, maximum - minimum > 1e-6 else { return nil }
        return (point + minimum * d, point + maximum * d)
    }

    static func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        a.x * b.y - a.y * b.x
    }

    static func signedArea(_ ring: [SIMD2<Double>]) -> Double {
        guard ring.count >= 3 else { return 0 }
        var sum = 0.0
        var previous = ring[ring.count - 1]
        for current in ring {
            sum += previous.x * current.y - current.x * previous.y
            previous = current
        }
        return sum / 2
    }
}

// MARK: - Delaunay triangulation (Bowyer–Watson)

enum DelaunayTriangulator {
    struct Triangle: Equatable {
        let a: Int
        let b: Int
        let c: Int
    }

    private struct Edge: Hashable {
        let u: Int
        let v: Int
        init(_ first: Int, _ second: Int) {
            u = min(first, second)
            v = max(first, second)
        }
    }

    private struct Circumcircle {
        let center: SIMD2<Double>
        let radiusSquared: Double
    }

    /// Returns counter-clockwise triangles. Degenerate (collinear) input
    /// yields an empty result. Input sizes are field surveys (tens to a few
    /// hundred points), so the simple O(n²) algorithm is sufficient.
    static func triangulate(_ points: [SIMD2<Double>]) -> [Triangle] {
        guard points.count >= 3 else { return [] }
        var minimum = points[0]
        var maximum = points[0]
        for point in points {
            minimum = simd_min(minimum, point)
            maximum = simd_max(maximum, point)
        }
        let span = max(maximum.x - minimum.x, maximum.y - minimum.y, 1)
        let middle = (minimum + maximum) / 2
        var vertices = points
        vertices.append(SIMD2(middle.x - 20 * span, middle.y - span))
        vertices.append(SIMD2(middle.x, middle.y + 20 * span))
        vertices.append(SIMD2(middle.x + 20 * span, middle.y - span))
        let count = points.count

        var triangles = [Triangle(a: count, b: count + 1, c: count + 2)]
        var circles = [circumcircle(triangles[0], vertices)]

        for index in 0..<count {
            let point = vertices[index]
            var boundary: [Edge: Int] = [:]
            var keptTriangles: [Triangle] = []
            var keptCircles: [Circumcircle] = []
            keptTriangles.reserveCapacity(triangles.count + 2)
            keptCircles.reserveCapacity(triangles.count + 2)

            for (triangle, circle) in zip(triangles, circles) {
                if simd_distance_squared(point, circle.center) < circle.radiusSquared * (1 + 1e-12) {
                    boundary[Edge(triangle.a, triangle.b), default: 0] += 1
                    boundary[Edge(triangle.b, triangle.c), default: 0] += 1
                    boundary[Edge(triangle.c, triangle.a), default: 0] += 1
                } else {
                    keptTriangles.append(triangle)
                    keptCircles.append(circle)
                }
            }

            for (edge, occurrences) in boundary where occurrences == 1 {
                let triangle = counterClockwise(Triangle(a: edge.u, b: edge.v, c: index), vertices)
                keptTriangles.append(triangle)
                keptCircles.append(circumcircle(triangle, vertices))
            }
            triangles = keptTriangles
            circles = keptCircles
        }

        return triangles.filter { triangle in
            triangle.a < count && triangle.b < count && triangle.c < count
                && abs(doubleArea(triangle, vertices)) > 1e-6
        }
    }

    static func doubleArea(_ triangle: Triangle, _ vertices: [SIMD2<Double>]) -> Double {
        TerrainGeometry.cross(
            vertices[triangle.b] - vertices[triangle.a],
            vertices[triangle.c] - vertices[triangle.a]
        )
    }

    private static func counterClockwise(_ triangle: Triangle, _ vertices: [SIMD2<Double>]) -> Triangle {
        doubleArea(triangle, vertices) >= 0
            ? triangle
            : Triangle(a: triangle.a, b: triangle.c, c: triangle.b)
    }

    private static func circumcircle(_ triangle: Triangle, _ vertices: [SIMD2<Double>]) -> Circumcircle {
        let a = vertices[triangle.a]
        let b = vertices[triangle.b]
        let c = vertices[triangle.c]
        let d = 2 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
        guard abs(d) > 1e-12 else {
            // Collinear: treat as an infinitely large circle so it is replaced.
            return Circumcircle(center: (a + b + c) / 3, radiusSquared: .infinity)
        }
        let aa = simd_length_squared(a)
        let bb = simd_length_squared(b)
        let cc = simd_length_squared(c)
        let center = SIMD2(
            (aa * (b.y - c.y) + bb * (c.y - a.y) + cc * (a.y - b.y)) / d,
            (aa * (c.x - b.x) + bb * (a.x - c.x) + cc * (b.x - a.x)) / d
        )
        return Circumcircle(center: center, radiusSquared: simd_distance_squared(center, a))
    }
}

// MARK: - Color ramp

enum TerrainColorRamp {
    /// Hypsometric tints from low (green) to high (light brown/white).
    static let stops: [(position: Double, color: SIMD3<Double>)] = [
        (0.00, SIMD3(0.10, 0.42, 0.36)),
        (0.22, SIMD3(0.36, 0.64, 0.33)),
        (0.48, SIMD3(0.90, 0.85, 0.42)),
        (0.74, SIMD3(0.82, 0.52, 0.26)),
        (1.00, SIMD3(0.97, 0.93, 0.88))
    ]

    static func color(at t: Double) -> SIMD3<Double> {
        let value = t.isFinite ? min(1, max(0, t)) : 0.5
        for index in 1..<stops.count where value <= stops[index].position {
            let lower = stops[index - 1]
            let upper = stops[index]
            let fraction = (value - lower.position) / (upper.position - lower.position)
            return lower.color + (upper.color - lower.color) * fraction
        }
        return stops[stops.count - 1].color
    }
}

// MARK: - Terrain model

struct TerrainProfileSample: Identifiable {
    let id: Int
    let distance: Double
    let height: Double?
    let position: SIMD2<Double>
}

struct TerrainContourSegment {
    let level: Double
    let isMajor: Bool
    let start: SIMD2<Double>
    let end: SIMD2<Double>
}

struct TerrainBounds: Equatable {
    var minX: Double
    var minY: Double
    var maxX: Double
    var maxY: Double

    var width: Double { maxX - minX }
    var height: Double { maxY - minY }
    var center: SIMD2<Double> { SIMD2((minX + maxX) / 2, (minY + maxY) / 2) }

    init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    init?(points: [SIMD2<Double>]) {
        guard let first = points.first else { return nil }
        var minimum = first
        var maximum = first
        for point in points {
            minimum = simd_min(minimum, point)
            maximum = simd_max(maximum, point)
        }
        self.init(minX: minimum.x, minY: minimum.y, maxX: maximum.x, maxY: maximum.y)
    }

    func expanded(by margin: Double) -> TerrainBounds {
        TerrainBounds(minX: minX - margin, minY: minY - margin, maxX: maxX + margin, maxY: maxY + margin)
    }

    func union(_ other: TerrainBounds) -> TerrainBounds {
        TerrainBounds(
            minX: min(minX, other.minX), minY: min(minY, other.minY),
            maxX: max(maxX, other.maxX), maxY: max(maxY, other.maxY)
        )
    }
}

struct TerrainStatistics {
    let pointCount: Int
    let minHeight: Double
    let maxHeight: Double
    let meanSlopePercent: Double?
    let maxSlopePercent: Double?
    /// Compass bearing (0° = north) in which the surface falls on average.
    let downhillBearing: Double?
    let coveredFraction: Double?

    var heightRange: Double { maxHeight - minHeight }
}

struct TerrainRaster {
    let image: CGImage
    /// Local metric bounds covered by the image (top edge = maxY).
    let bounds: TerrainBounds
}

struct TerrainModel {
    struct Vertex {
        let position: SIMD2<Double>
        let height: Double
    }

    let revision = UUID()
    /// UTM origin of the local metric frame (x = east, y = north).
    let origin: UTMCoordinate
    let vertices: [Vertex]
    let triangles: [DelaunayTriangulator.Triangle]
    let parcelRings: [[SIMD2<Double>]]
    let parcelBounds: TerrainBounds
    let minHeight: Double
    let maxHeight: Double

    var heightRange: Double { maxHeight - minHeight }
    var canInterpolate: Bool { !triangles.isEmpty }
    var displayBounds: TerrainBounds {
        guard let vertexBounds = TerrainBounds(points: vertices.map(\.position)) else {
            return parcelBounds
        }
        return parcelBounds.union(vertexBounds)
    }

    /// - Parameters:
    ///   - mergeDistance: measurements closer than this are averaged into a
    ///     single vertex so repeated measurements don't create sliver triangles.
    init?(points: [TerrainSurveyPoint], parcelRings utmRings: [[UTMCoordinate]], mergeDistance: Double = 0.05) {
        guard let firstVertex = utmRings.first(where: { !$0.isEmpty })?.first else { return nil }
        let origin = UTMCoordinate(
            easting: firstVertex.easting.rounded(.down),
            northing: firstVertex.northing.rounded(.down)
        )
        let rings = utmRings.map { ring in
            ring.map { SIMD2($0.easting - origin.easting, $0.northing - origin.northing) }
        }
        guard let bounds = TerrainBounds(points: rings.flatMap { $0 }) else { return nil }

        var merged: [(position: SIMD2<Double>, heightSum: Double, count: Int)] = []
        for point in points {
            let utm = UTM32Projection.project(point.coordinate)
            let position = SIMD2(utm.easting - origin.easting, utm.northing - origin.northing)
            if let index = merged.firstIndex(where: {
                simd_distance($0.position / Double($0.count), position) < mergeDistance
            }) {
                merged[index].position += position
                merged[index].heightSum += point.altitudeMSL
                merged[index].count += 1
            } else {
                merged.append((position, point.altitudeMSL, 1))
            }
        }
        let vertices = merged.map {
            Vertex(position: $0.position / Double($0.count), height: $0.heightSum / Double($0.count))
        }

        self.origin = origin
        self.vertices = vertices
        self.parcelRings = rings
        self.parcelBounds = bounds
        self.triangles = DelaunayTriangulator.triangulate(vertices.map(\.position))
        self.minHeight = vertices.map(\.height).min() ?? 0
        self.maxHeight = vertices.map(\.height).max() ?? 0
    }

    // MARK: Coordinate conversion

    func localPosition(of coordinate: CLLocationCoordinate2D) -> SIMD2<Double> {
        let utm = UTM32Projection.project(coordinate)
        return SIMD2(utm.easting - origin.easting, utm.northing - origin.northing)
    }

    func coordinate(of position: SIMD2<Double>) -> CLLocationCoordinate2D {
        UTM32Projection.unproject(UTMCoordinate(
            easting: position.x + origin.easting,
            northing: position.y + origin.northing
        ))
    }

    func normalizedHeight(_ height: Double) -> Double {
        heightRange > 1e-6 ? (height - minHeight) / heightRange : 0.5
    }

    // MARK: Interpolation

    /// Linear interpolation on the triangulated surface. `nil` outside the
    /// convex hull of the measured points – no extrapolation.
    func height(at position: SIMD2<Double>) -> Double? {
        for triangle in triangles {
            if let weights = barycentric(position, triangle), weights.min() >= -1e-9 {
                return weights.x * vertices[triangle.a].height
                    + weights.y * vertices[triangle.b].height
                    + weights.z * vertices[triangle.c].height
            }
        }
        return nil
    }

    private func barycentric(_ point: SIMD2<Double>, _ triangle: DelaunayTriangulator.Triangle) -> SIMD3<Double>? {
        let a = vertices[triangle.a].position
        let b = vertices[triangle.b].position
        let c = vertices[triangle.c].position
        let denominator = TerrainGeometry.cross(b - a, c - a)
        guard abs(denominator) > 1e-12 else { return nil }
        let wb = TerrainGeometry.cross(point - a, c - a) / denominator
        let wc = TerrainGeometry.cross(b - a, point - a) / denominator
        return SIMD3(1 - wb - wc, wb, wc)
    }

    /// Gradient (dz/dx, dz/dy) of a triangle's plane.
    func gradient(of triangle: DelaunayTriangulator.Triangle) -> SIMD2<Double>? {
        let a = vertices[triangle.a]
        let b = vertices[triangle.b]
        let c = vertices[triangle.c]
        let ab = b.position - a.position
        let ac = c.position - a.position
        let denominator = TerrainGeometry.cross(ab, ac)
        guard abs(denominator) > 1e-12 else { return nil }
        let dzb = b.height - a.height
        let dzc = c.height - a.height
        return SIMD2(
            (dzb * ac.y - dzc * ab.y) / denominator,
            (ab.x * dzc - ac.x * dzb) / denominator
        )
    }

    // MARK: Profile

    func profile(from start: SIMD2<Double>, to end: SIMD2<Double>, sampleCount: Int = 160) -> [TerrainProfileSample] {
        let count = max(2, sampleCount)
        let length = simd_distance(start, end)
        return (0..<count).map { index in
            let t = Double(index) / Double(count - 1)
            let position = start + (end - start) * t
            return TerrainProfileSample(
                id: index,
                distance: length * t,
                height: height(at: position),
                position: position
            )
        }
    }

    /// Default section: through the lowest and highest measurement, clipped
    /// to the parcel. Falls back to the parcel's long axis.
    func defaultProfileLine() -> (SIMD2<Double>, SIMD2<Double>) {
        if let lowest = vertices.min(by: { $0.height < $1.height }),
           let highest = vertices.max(by: { $0.height < $1.height }),
           simd_distance(lowest.position, highest.position) > 0.5,
           let clipped = TerrainGeometry.clipLine(
               through: lowest.position,
               direction: highest.position - lowest.position,
               rings: parcelRings
           ) {
            // Orient from low to high so the profile reads as a climb.
            let direction = highest.position - lowest.position
            return simd_dot(clipped.1 - clipped.0, direction) >= 0 ? clipped : (clipped.1, clipped.0)
        }
        let center = parcelBounds.center
        let direction = parcelBounds.width >= parcelBounds.height ? SIMD2(1.0, 0) : SIMD2(0, 1.0)
        return TerrainGeometry.clipLine(through: center, direction: direction, rings: parcelRings)
            ?? (SIMD2(parcelBounds.minX, center.y), SIMD2(parcelBounds.maxX, center.y))
    }

    // MARK: Contours

    static func contourInterval(forRange range: Double, targetLineCount: Double = 10) -> Double {
        guard range > 0 else { return 0.1 }
        let candidates = [0.01, 0.02, 0.05, 0.1, 0.2, 0.25, 0.5, 1, 2, 2.5, 5, 10, 20, 25, 50]
        let ideal = range / targetLineCount
        return candidates.first { $0 >= ideal } ?? 100
    }

    func contourSegments(interval: Double) -> [TerrainContourSegment] {
        guard interval > 0, canInterpolate, heightRange > 1e-6 else { return [] }
        let firstLevel = (minHeight / interval).rounded(.up) * interval
        var levels: [Double] = []
        var level = firstLevel
        while level <= maxHeight + 1e-9, levels.count < 500 {
            levels.append(level)
            level += interval
        }
        let majorInterval = interval * 5
        var segments: [TerrainContourSegment] = []
        for triangle in triangles {
            let corners = [vertices[triangle.a], vertices[triangle.b], vertices[triangle.c]]
            let lower = corners.map(\.height).min()!
            let upper = corners.map(\.height).max()!
            for level in levels where level > lower && level < upper {
                // Nudge to avoid a level passing exactly through a vertex.
                let l = level + 1e-9
                var crossings: [SIMD2<Double>] = []
                for (first, second) in [(0, 1), (1, 2), (2, 0)] {
                    let h1 = corners[first].height
                    let h2 = corners[second].height
                    if (h1 - l) * (h2 - l) < 0 {
                        let t = (l - h1) / (h2 - h1)
                        crossings.append(corners[first].position + (corners[second].position - corners[first].position) * t)
                    }
                }
                if crossings.count == 2 {
                    let ratio = level / majorInterval
                    segments.append(TerrainContourSegment(
                        level: level,
                        isMajor: abs(ratio - ratio.rounded()) < 1e-6,
                        start: crossings[0],
                        end: crossings[1]
                    ))
                }
            }
        }
        return segments
    }

    // MARK: Statistics

    func statistics() -> TerrainStatistics {
        var weightedSlope = 0.0
        var weightedGradient = SIMD2<Double>(0, 0)
        var totalArea = 0.0
        var maxSlope: Double?
        for triangle in triangles {
            guard let gradient = gradient(of: triangle) else { continue }
            let area = abs(DelaunayTriangulator.doubleArea(triangle, vertices.map(\.position))) / 2
            let slope = simd_length(gradient) * 100
            weightedSlope += slope * area
            weightedGradient += gradient * area
            totalArea += area
            maxSlope = max(maxSlope ?? 0, slope)
        }

        var downhillBearing: Double?
        if totalArea > 0, simd_length(weightedGradient) / totalArea > 1e-4 {
            let downhill = -weightedGradient
            let degrees = atan2(downhill.x, downhill.y) * 180 / .pi
            downhillBearing = degrees >= 0 ? degrees : degrees + 360
        }

        return TerrainStatistics(
            pointCount: vertices.count,
            minHeight: minHeight,
            maxHeight: maxHeight,
            meanSlopePercent: totalArea > 0 ? weightedSlope / totalArea : nil,
            maxSlopePercent: maxSlope,
            downhillBearing: downhillBearing,
            coveredFraction: canInterpolate ? coveredFraction() : nil
        )
    }

    /// Share of the parcel area that lies inside the triangulated surface.
    private func coveredFraction(resolution: Int = 80) -> Double? {
        let bounds = parcelBounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        var inside = 0
        var covered = 0
        for row in 0..<resolution {
            for column in 0..<resolution {
                let point = SIMD2(
                    bounds.minX + (Double(column) + 0.5) / Double(resolution) * bounds.width,
                    bounds.minY + (Double(row) + 0.5) / Double(resolution) * bounds.height
                )
                guard TerrainGeometry.contains(point, rings: parcelRings) else { continue }
                inside += 1
                if height(at: point) != nil { covered += 1 }
            }
        }
        return inside > 0 ? Double(covered) / Double(inside) : nil
    }

    // MARK: Raster

    /// Hypsometric, hill-shaded raster clipped to the parcel. Parcel areas
    /// outside the measured hull are drawn neutral grey.
    func makeRaster(maxDimension: Int = 512) -> TerrainRaster? {
        let bounds = displayBounds.expanded(by: 0.25)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let metersPerPixel = max(bounds.width, bounds.height) / Double(maxDimension)
        let width = max(1, Int((bounds.width / metersPerPixel).rounded(.up)))
        let height = max(1, Int((bounds.height / metersPerPixel).rounded(.up)))
        let pixelCount = width * height

        func localPoint(column: Double, row: Double) -> SIMD2<Double> {
            SIMD2(bounds.minX + column * metersPerPixel, bounds.maxY - row * metersPerPixel)
        }

        // 1. Parcel mask via even-odd scanlines.
        var inParcel = [Bool](repeating: false, count: pixelCount)
        for row in 0..<height {
            let y = bounds.maxY - (Double(row) + 0.5) * metersPerPixel
            var crossings: [Double] = []
            for ring in parcelRings where ring.count >= 3 {
                var previous = ring[ring.count - 1]
                for current in ring {
                    if (current.y > y) != (previous.y > y) {
                        crossings.append(previous.x + (y - previous.y) / (current.y - previous.y) * (current.x - previous.x))
                    }
                    previous = current
                }
            }
            crossings.sort()
            var index = 0
            while index + 1 < crossings.count {
                let startColumn = max(0, Int(((crossings[index] - bounds.minX) / metersPerPixel - 0.5).rounded(.up)))
                let endColumn = min(width - 1, Int(((crossings[index + 1] - bounds.minX) / metersPerPixel - 0.5).rounded(.down)))
                if startColumn <= endColumn {
                    for column in startColumn...endColumn { inParcel[row * width + column] = true }
                }
                index += 2
            }
        }

        // 2. Heights and per-triangle hill shading.
        var heights = [Double](repeating: .nan, count: pixelCount)
        var shades = [Double](repeating: 1, count: pixelCount)
        let light = simd_normalize(SIMD3<Double>(-1, 1, 1.4)) // from north-west, elevated
        let shadeExaggeration = 3.0
        for triangle in triangles {
            let a = vertices[triangle.a]
            let b = vertices[triangle.b]
            let c = vertices[triangle.c]
            var shade = 1.0
            if let gradient = gradient(of: triangle) {
                let normal = simd_normalize(SIMD3(-gradient.x * shadeExaggeration, -gradient.y * shadeExaggeration, 1))
                // Flat ground keeps its tint (1.0); slopes facing away darken.
                shade = min(1.12, max(0.55, 0.6 + 0.4 * simd_dot(normal, light) / light.z))
            }
            let minColumn = max(0, Int(((min(a.position.x, b.position.x, c.position.x) - bounds.minX) / metersPerPixel).rounded(.down)))
            let maxColumn = min(width - 1, Int(((max(a.position.x, b.position.x, c.position.x) - bounds.minX) / metersPerPixel).rounded(.up)))
            let minRow = max(0, Int(((bounds.maxY - max(a.position.y, b.position.y, c.position.y)) / metersPerPixel).rounded(.down)))
            let maxRow = min(height - 1, Int(((bounds.maxY - min(a.position.y, b.position.y, c.position.y)) / metersPerPixel).rounded(.up)))
            guard minColumn <= maxColumn, minRow <= maxRow else { continue }
            for row in minRow...maxRow {
                for column in minColumn...maxColumn {
                    let point = localPoint(column: Double(column) + 0.5, row: Double(row) + 0.5)
                    guard let weights = barycentric(point, triangle), weights.min() >= -1e-9 else { continue }
                    let index = row * width + column
                    heights[index] = weights.x * a.height + weights.y * b.height + weights.z * c.height
                    shades[index] = shade
                }
            }
        }

        // 3. Compose RGBA.
        var pixels = [UInt8](repeating: 0, count: pixelCount * 4)
        for index in 0..<pixelCount where inParcel[index] {
            let offset = index * 4
            let value = heights[index]
            if value.isNaN {
                pixels[offset] = 92
                pixels[offset + 1] = 94
                pixels[offset + 2] = 102
                pixels[offset + 3] = 120
            } else {
                let color = TerrainColorRamp.color(at: normalizedHeight(value)) * min(1.05, shades[index])
                pixels[offset] = UInt8(min(255, max(0, color.x * 255)))
                pixels[offset + 1] = UInt8(min(255, max(0, color.y * 255)))
                pixels[offset + 2] = UInt8(min(255, max(0, color.z * 255)))
                pixels[offset + 3] = 255
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else { return nil }
        let imageBounds = TerrainBounds(
            minX: bounds.minX,
            minY: bounds.maxY - Double(height) * metersPerPixel,
            maxX: bounds.minX + Double(width) * metersPerPixel,
            maxY: bounds.maxY
        )
        return TerrainRaster(image: image, bounds: imageBounds)
    }
}

extension TerrainModel {
    init?(points: [TerrainSurveyPoint], parcel: ParcelInfo) {
        self.init(points: points, parcelRings: parcel.boundaryRings.map(\.utm))
    }
}

// MARK: - Persistence

final class TerrainSurveyStore {
    private struct StoredSurvey: Codable {
        var parcelID: String
        var parcelLabel: String
        var points: [TerrainSurveyPoint]
        var updatedAt: Date
    }

    private let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = base.appendingPathComponent("TerrainSurveys", isDirectory: true)
        }
    }

    func load(parcelID: String) -> [TerrainSurveyPoint] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL(for: parcelID)),
              let survey = try? decoder.decode(StoredSurvey.self, from: data) else { return [] }
        return survey.points
    }

    func save(_ points: [TerrainSurveyPoint], parcelID: String, parcelLabel: String) throws {
        let url = fileURL(for: parcelID)
        if points.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let survey = StoredSurvey(parcelID: parcelID, parcelLabel: parcelLabel, points: points, updatedAt: Date())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(survey).write(to: url, options: [.atomic, .completeFileProtection])
    }

    private func fileURL(for parcelID: String) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let name = String(parcelID.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return directory.appendingPathComponent("\(name).json")
    }
}
