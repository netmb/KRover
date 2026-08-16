import CoreLocation
import Foundation

enum PolygonEditor {
    static func nearestEdge(
        to coordinate: CLLocationCoordinate2D,
        in polygon: [CLLocationCoordinate2D]
    ) -> PolygonEdgeMatch? {
        guard polygon.count >= 3 else { return nil }
        return polygon.indices
            .compactMap { match(coordinate, toEdgeStartingAt: $0, in: polygon) }
            .min { $0.distance < $1.distance }
    }

    static func match(
        _ coordinate: CLLocationCoordinate2D,
        toEdgeStartingAt startIndex: Int,
        in polygon: [CLLocationCoordinate2D]
    ) -> PolygonEdgeMatch? {
        guard polygon.count >= 3, polygon.indices.contains(startIndex) else { return nil }
        let endIndex = (startIndex + 1) % polygon.count
        let start = UTM32Projection.project(polygon[startIndex])
        let end = UTM32Projection.project(polygon[endIndex])
        let point = UTM32Projection.project(coordinate)
        let deltaEasting = end.easting - start.easting
        let deltaNorthing = end.northing - start.northing
        let lengthSquared = deltaEasting * deltaEasting + deltaNorthing * deltaNorthing
        guard lengthSquared > 0 else { return nil }

        let rawFraction = (
            (point.easting - start.easting) * deltaEasting +
            (point.northing - start.northing) * deltaNorthing
        ) / lengthSquared
        let fraction = min(1, max(0, rawFraction))
        let projectedUTM = UTMCoordinate(
            easting: start.easting + fraction * deltaEasting,
            northing: start.northing + fraction * deltaNorthing
        )
        let startCoordinate = polygon[startIndex]
        let endCoordinate = polygon[endIndex]

        return PolygonEdgeMatch(
            startIndex: startIndex,
            endIndex: endIndex,
            fraction: fraction,
            projectedCoordinate: CLLocationCoordinate2D(
                latitude: startCoordinate.latitude + fraction * (endCoordinate.latitude - startCoordinate.latitude),
                longitude: startCoordinate.longitude + fraction * (endCoordinate.longitude - startCoordinate.longitude)
            ),
            distance: UTM32Projection.distance(point, projectedUTM),
            projectionIsWithinSegment: rawFraction > 0 && rawFraction < 1
        )
    }

    static func inserting(
        _ coordinate: CLLocationCoordinate2D,
        afterEdgeStartingAt startIndex: Int,
        in polygon: [CLLocationCoordinate2D]
    ) -> [CLLocationCoordinate2D]? {
        guard polygon.count >= 3, polygon.indices.contains(startIndex) else { return nil }
        var result = polygon
        result.insert(coordinate, at: startIndex + 1)
        return result
    }

    static func hasSelfIntersections(_ polygon: [CLLocationCoordinate2D]) -> Bool {
        guard polygon.count >= 4 else { return false }
        let points = polygon.map(UTM32Projection.project)

        for firstStart in points.indices {
            let firstEnd = (firstStart + 1) % points.count
            for secondStart in points.indices where secondStart > firstStart {
                let secondEnd = (secondStart + 1) % points.count
                let edgesAreAdjacent = firstStart == secondStart ||
                    firstEnd == secondStart || secondEnd == firstStart
                guard !edgesAreAdjacent else { continue }
                if segmentsIntersect(
                    points[firstStart], points[firstEnd],
                    points[secondStart], points[secondEnd]
                ) {
                    return true
                }
            }
        }
        return false
    }

    private static func segmentsIntersect(
        _ firstStart: UTMCoordinate,
        _ firstEnd: UTMCoordinate,
        _ secondStart: UTMCoordinate,
        _ secondEnd: UTMCoordinate
    ) -> Bool {
        let epsilon = 1e-8
        let o1 = orientation(firstStart, firstEnd, secondStart)
        let o2 = orientation(firstStart, firstEnd, secondEnd)
        let o3 = orientation(secondStart, secondEnd, firstStart)
        let o4 = orientation(secondStart, secondEnd, firstEnd)

        if ((o1 > epsilon && o2 < -epsilon) || (o1 < -epsilon && o2 > epsilon)) &&
            ((o3 > epsilon && o4 < -epsilon) || (o3 < -epsilon && o4 > epsilon)) {
            return true
        }
        if abs(o1) <= epsilon && isOnSegment(secondStart, firstStart, firstEnd) { return true }
        if abs(o2) <= epsilon && isOnSegment(secondEnd, firstStart, firstEnd) { return true }
        if abs(o3) <= epsilon && isOnSegment(firstStart, secondStart, secondEnd) { return true }
        if abs(o4) <= epsilon && isOnSegment(firstEnd, secondStart, secondEnd) { return true }
        return false
    }

    private static func orientation(
        _ first: UTMCoordinate,
        _ second: UTMCoordinate,
        _ third: UTMCoordinate
    ) -> Double {
        (second.easting - first.easting) * (third.northing - first.northing) -
            (second.northing - first.northing) * (third.easting - first.easting)
    }

    private static func isOnSegment(
        _ point: UTMCoordinate,
        _ start: UTMCoordinate,
        _ end: UTMCoordinate
    ) -> Bool {
        let epsilon = 1e-8
        return point.easting >= min(start.easting, end.easting) - epsilon &&
            point.easting <= max(start.easting, end.easting) + epsilon &&
            point.northing >= min(start.northing, end.northing) - epsilon &&
            point.northing <= max(start.northing, end.northing) + epsilon
    }
}
