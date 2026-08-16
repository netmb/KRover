import CoreLocation
import Foundation

enum BoundarySnapper {
    static func snap(
        _ coordinate: CLLocationCoordinate2D,
        to rings: [ParcelBoundaryRing],
        vertexCaptureRadius: Double = 1.0
    ) -> BoundaryTarget? {
        let tappedUTM = UTM32Projection.project(coordinate)

        if let vertex = nearestVertex(to: tappedUTM, in: rings), vertex.distance <= vertexCaptureRadius {
            return BoundaryTarget(
                coordinate: vertex.coordinate,
                utm: vertex.utm,
                kind: .vertex,
                ringIndex: vertex.ringIndex,
                segmentIndex: vertex.vertexIndex,
                snapDistance: vertex.distance
            )
        }

        var best: SegmentCandidate?
        for (ringIndex, ring) in rings.enumerated() where ring.utm.count >= 2 && ring.utm.count == ring.wgs84.count {
            for segmentIndex in ring.utm.indices {
                let nextIndex = (segmentIndex + 1) % ring.utm.count
                let start = ring.utm[segmentIndex]
                let end = ring.utm[nextIndex]
                let deltaEasting = end.easting - start.easting
                let deltaNorthing = end.northing - start.northing
                let lengthSquared = deltaEasting * deltaEasting + deltaNorthing * deltaNorthing
                guard lengthSquared > 0 else { continue }

                let rawFraction = (
                    (tappedUTM.easting - start.easting) * deltaEasting +
                    (tappedUTM.northing - start.northing) * deltaNorthing
                ) / lengthSquared
                let fraction = min(1, max(0, rawFraction))
                let projected = UTMCoordinate(
                    easting: start.easting + fraction * deltaEasting,
                    northing: start.northing + fraction * deltaNorthing
                )
                let distance = UTM32Projection.distance(tappedUTM, projected)
                if best == nil || distance < best!.distance {
                    best = SegmentCandidate(
                        ringIndex: ringIndex,
                        segmentIndex: segmentIndex,
                        nextIndex: nextIndex,
                        fraction: fraction,
                        utm: projected,
                        distance: distance
                    )
                }
            }
        }

        guard let best else { return nil }
        let ring = rings[best.ringIndex]
        if best.fraction <= 1e-9 || best.fraction >= 1 - 1e-9 {
            let vertexIndex = best.fraction <= 1e-9 ? best.segmentIndex : best.nextIndex
            return BoundaryTarget(
                coordinate: ring.wgs84[vertexIndex],
                utm: ring.utm[vertexIndex],
                kind: .vertex,
                ringIndex: best.ringIndex,
                segmentIndex: vertexIndex,
                snapDistance: best.distance
            )
        }

        let start = ring.wgs84[best.segmentIndex]
        let end = ring.wgs84[best.nextIndex]
        return BoundaryTarget(
            coordinate: CLLocationCoordinate2D(
                latitude: start.latitude + best.fraction * (end.latitude - start.latitude),
                longitude: start.longitude + best.fraction * (end.longitude - start.longitude)
            ),
            utm: best.utm,
            kind: .edge,
            ringIndex: best.ringIndex,
            segmentIndex: best.segmentIndex,
            snapDistance: best.distance
        )
    }

    private static func nearestVertex(
        to coordinate: UTMCoordinate,
        in rings: [ParcelBoundaryRing]
    ) -> VertexCandidate? {
        var best: VertexCandidate?
        for (ringIndex, ring) in rings.enumerated() where ring.utm.count == ring.wgs84.count {
            for vertexIndex in ring.utm.indices {
                let distance = UTM32Projection.distance(coordinate, ring.utm[vertexIndex])
                if best == nil || distance < best!.distance {
                    best = VertexCandidate(
                        ringIndex: ringIndex,
                        vertexIndex: vertexIndex,
                        coordinate: ring.wgs84[vertexIndex],
                        utm: ring.utm[vertexIndex],
                        distance: distance
                    )
                }
            }
        }
        return best
    }

    private struct VertexCandidate {
        let ringIndex: Int
        let vertexIndex: Int
        let coordinate: CLLocationCoordinate2D
        let utm: UTMCoordinate
        let distance: Double
    }

    private struct SegmentCandidate {
        let ringIndex: Int
        let segmentIndex: Int
        let nextIndex: Int
        let fraction: Double
        let utm: UTMCoordinate
        let distance: Double
    }
}
