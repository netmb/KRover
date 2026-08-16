import CoreLocation
import Foundation

enum UTM32Projection {
    private static let semiMajor = 6_378_137.0
    private static let flattening = 1.0 / 298.257223563
    private static let scale = 0.9996
    private static let centralMeridian = 9.0 * .pi / 180

    static func project(_ coordinate: CLLocationCoordinate2D) -> UTMCoordinate {
        let eccentricitySquared = flattening * (2 - flattening)
        let secondEccentricitySquared = eccentricitySquared / (1 - eccentricitySquared)
        let latitude = coordinate.latitude * .pi / 180
        let longitude = coordinate.longitude * .pi / 180
        let sinLatitude = sin(latitude)
        let cosLatitude = cos(latitude)
        let tanLatitude = tan(latitude)
        let n = semiMajor / sqrt(1 - eccentricitySquared * sinLatitude * sinLatitude)
        let t = tanLatitude * tanLatitude
        let c = secondEccentricitySquared * cosLatitude * cosLatitude
        let a = cosLatitude * (longitude - centralMeridian)
        let e2 = eccentricitySquared
        let meridionalArc = semiMajor * (
            (1 - e2 / 4 - 3 * e2 * e2 / 64 - 5 * pow(e2, 3) / 256) * latitude
            - (3 * e2 / 8 + 3 * e2 * e2 / 32 + 45 * pow(e2, 3) / 1024) * sin(2 * latitude)
            + (15 * e2 * e2 / 256 + 45 * pow(e2, 3) / 1024) * sin(4 * latitude)
            - (35 * pow(e2, 3) / 3072) * sin(6 * latitude)
        )
        let easting = scale * n * (
            a + (1 - t + c) * pow(a, 3) / 6
            + (5 - 18 * t + t * t + 72 * c - 58 * secondEccentricitySquared) * pow(a, 5) / 120
        ) + 500_000
        let northing = scale * (
            meridionalArc + n * tanLatitude * (
                a * a / 2
                + (5 - t + 9 * c + 4 * c * c) * pow(a, 4) / 24
                + (61 - 58 * t + t * t + 600 * c - 330 * secondEccentricitySquared) * pow(a, 6) / 720
            )
        )
        return UTMCoordinate(easting: easting, northing: northing)
    }

    static func unproject(_ coordinate: UTMCoordinate) -> CLLocationCoordinate2D {
        let eccentricitySquared = flattening * (2 - flattening)
        let secondEccentricitySquared = eccentricitySquared / (1 - eccentricitySquared)
        let x = coordinate.easting - 500_000
        let meridionalArc = coordinate.northing / scale
        let mu = meridionalArc / (
            semiMajor * (1 - eccentricitySquared / 4
                         - 3 * pow(eccentricitySquared, 2) / 64
                         - 5 * pow(eccentricitySquared, 3) / 256)
        )
        let e1 = (1 - sqrt(1 - eccentricitySquared)) / (1 + sqrt(1 - eccentricitySquared))
        let footprintLatitude = mu
            + (3 * e1 / 2 - 27 * pow(e1, 3) / 32) * sin(2 * mu)
            + (21 * pow(e1, 2) / 16 - 55 * pow(e1, 4) / 32) * sin(4 * mu)
            + (151 * pow(e1, 3) / 96) * sin(6 * mu)
            + (1097 * pow(e1, 4) / 512) * sin(8 * mu)
        let sinFootprint = sin(footprintLatitude)
        let cosFootprint = cos(footprintLatitude)
        let tanFootprint = tan(footprintLatitude)
        let n1 = semiMajor / sqrt(1 - eccentricitySquared * sinFootprint * sinFootprint)
        let r1 = semiMajor * (1 - eccentricitySquared) /
            pow(1 - eccentricitySquared * sinFootprint * sinFootprint, 1.5)
        let t1 = tanFootprint * tanFootprint
        let c1 = secondEccentricitySquared * cosFootprint * cosFootprint
        let d = x / (n1 * scale)

        let latitude = footprintLatitude - (n1 * tanFootprint / r1) * (
            d * d / 2
            - (5 + 3 * t1 + 10 * c1 - 4 * c1 * c1 - 9 * secondEccentricitySquared)
                * pow(d, 4) / 24
            + (61 + 90 * t1 + 298 * c1 + 45 * t1 * t1
               - 252 * secondEccentricitySquared - 3 * c1 * c1)
                * pow(d, 6) / 720
        )
        let longitude = centralMeridian + (
            d - (1 + 2 * t1 + c1) * pow(d, 3) / 6
            + (5 - 2 * c1 + 28 * t1 - 3 * c1 * c1
               + 8 * secondEccentricitySquared + 24 * t1 * t1)
                * pow(d, 5) / 120
        ) / cosFootprint

        return CLLocationCoordinate2D(
            latitude: latitude * 180 / .pi,
            longitude: longitude * 180 / .pi
        )
    }

    static func distance(_ lhs: UTMCoordinate, _ rhs: UTMCoordinate) -> Double {
        hypot(rhs.easting - lhs.easting, rhs.northing - lhs.northing)
    }

    static func polylineLength(_ coordinates: [CLLocationCoordinate2D]) -> Double {
        zip(coordinates, coordinates.dropFirst()).reduce(0) {
            $0 + distance(project($1.0), project($1.1))
        }
    }

    static func polygonArea(_ coordinates: [CLLocationCoordinate2D]) -> Double {
        guard coordinates.count >= 3 else { return 0 }
        let points = coordinates.map(project)
        var sum = 0.0
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            sum += points[index].easting * next.northing - next.easting * points[index].northing
        }
        return abs(sum) / 2
    }

    static func polygonPerimeter(_ coordinates: [CLLocationCoordinate2D]) -> Double {
        guard coordinates.count >= 2 else { return 0 }
        let points = coordinates.map(project)
        return points.indices.reduce(0) { result, index in
            result + distance(points[index], points[(index + 1) % points.count])
        }
    }
}
