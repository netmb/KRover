import CoreLocation
import Foundation

final class PhoneLocationProvider: NSObject, ObservableObject {
    @Published private(set) var location: CLLocation?
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var hasFullAccuracyAuthorization = false
    @Published private(set) var heading: CLLocationDirection?

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.headingFilter = 1
        manager.headingOrientation = .portrait
        hasFullAccuracyAuthorization = manager.accuracyAuthorization == .fullAccuracy
    }

    func start() {
        authorization = manager.authorizationStatus
        hasFullAccuracyAuthorization = manager.accuracyAuthorization == .fullAccuracy
        if authorization == .notDetermined { manager.requestWhenInUseAuthorization() }
        if authorization == .authorizedAlways || authorization == .authorizedWhenInUse {
            manager.startUpdatingLocation()
            startHeadingUpdates()
        }
    }

    func setHeadingOrientation(_ orientation: CLDeviceOrientation) {
        if manager.headingOrientation != orientation { manager.headingOrientation = orientation }
    }
}

extension PhoneLocationProvider: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        hasFullAccuracyAuthorization = manager.accuracyAuthorization == .fullAccuracy
        if authorization == .authorizedAlways || authorization == .authorizedWhenInUse {
            manager.startUpdatingLocation()
            startHeadingUpdates()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let newest = locations.last(where: { $0.horizontalAccuracy >= 0 }) { location = newest }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0 else { return }
        let bestHeading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        heading = bestHeading
    }

    private func startHeadingUpdates() {
        guard CLLocationManager.headingAvailable() else { return }
        manager.startUpdatingHeading()
    }
}

enum NMEAGenerator {
    static func gga(coordinate: CLLocationCoordinate2D, altitude: Double, quality: Int = 1) -> String {
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        timeFormatter.dateFormat = "HHmmss.SS"

        let latitude = coordinateField(abs(coordinate.latitude), degreeDigits: 2)
        let longitude = coordinateField(abs(coordinate.longitude), degreeDigits: 3)
        let body = String(
            format: "GPGGA,%@,%@,%@,%@,%@,%d,12,1.0,%.3f,M,0.0,M,,",
            locale: Locale(identifier: "en_US_POSIX"),
            timeFormatter.string(from: Date()), latitude,
            coordinate.latitude >= 0 ? "N" : "S", longitude,
            coordinate.longitude >= 0 ? "E" : "W", quality, altitude
        )
        let checksum = body.utf8.reduce(UInt8(0), ^)
        return String(format: "$%@*%02X", body, checksum)
    }

    private static func coordinateField(_ degrees: Double, degreeDigits: Int) -> String {
        let whole = floor(degrees)
        let minutes = (degrees - whole) * 60
        return String(format: "%0*d%09.6f", degreeDigits, Int(whole), minutes)
    }
}
