import CoreLocation
import MapLibre
import UIKit

/// Renders the official NRW background map (cadastre or orthophoto) for a
/// coordinate region without a visible map view.
@MainActor
final class SurveyMapSnapshotter: NSObject, MLNMapSnapshotterDelegate {
    struct Result {
        let image: UIImage
        let pointForCoordinate: (CLLocationCoordinate2D) -> CGPoint
        let coordinateForPoint: (CGPoint) -> CLLocationCoordinate2D
    }

    private var snapshotter: MLNMapSnapshotter?
    private var continuation: CheckedContinuation<Result?, Never>?

    /// A snapshot fails as a whole as soon as one tile request fails. The LIKA
    /// vector tiles answer requests beyond zoom 18 with HTTP 400 (the map view
    /// simply overzooms), so the cadastre is rendered at most at zoom 18 with a
    /// correspondingly higher pixel density. The orthophoto uses its own
    /// minimal style and can go deeper.
    static func maximumZoom(for background: MapBackgroundLayer) -> Double {
        switch background {
        case .cadastre: return 18
        case .aerialDOP: return 20
        }
    }

    /// - Returns: `nil` if the map could not be loaded in time (offline).
    static func snapshot(
        southWest: CLLocationCoordinate2D,
        northEast: CLLocationCoordinate2D,
        size: CGSize,
        scale: CGFloat,
        background: MapBackgroundLayer,
        timeout: TimeInterval = 25
    ) async -> Result? {
        guard let styleURL = styleURL(for: background) else { return nil }
        let center = CLLocationCoordinate2D(
            latitude: (southWest.latitude + northEast.latitude) / 2,
            longitude: (southWest.longitude + northEast.longitude) / 2
        )
        let requiredZoom = zoomLevel(fittingLongitudeSpan: northEast.longitude - southWest.longitude, width: size.width)
        let deadline = Date().addingTimeInterval(timeout)
        // Integer zoom levels; step down once more if a level is rejected.
        var zoom = min(floor(requiredZoom), maximumZoom(for: background))
        for _ in 0..<2 {
            let factor = pow(2, requiredZoom - zoom)
            let loader = SurveyMapSnapshotter()
            if let result = await loader.run(
                styleURL: styleURL,
                center: center,
                zoom: zoom,
                size: CGSize(width: size.width / factor, height: size.height / factor),
                scale: scale * factor,
                timeout: max(1, deadline.timeIntervalSinceNow)
            ) {
                return result
            }
            guard deadline.timeIntervalSinceNow > 1 else { return nil }
            zoom -= 1
        }
        return nil
    }

    /// Web-Mercator zoom at which `longitudeSpan` degrees fill `width` points.
    static func zoomLevel(fittingLongitudeSpan longitudeSpan: Double, width: CGFloat) -> Double {
        guard longitudeSpan > 0 else { return 18 }
        return log2(Double(width) * 360 / (512 * longitudeSpan))
    }

    private static func styleURL(for background: MapBackgroundLayer) -> URL? {
        switch background {
        case .cadastre:
            return NRWMapLayerCatalog.cadastreStyleURL
        case .aerialDOP:
            let style: [String: Any] = [
                "version": 8,
                "sources": [
                    "dop": [
                        "type": "raster",
                        "tiles": [NRWMapLayerCatalog.dopRGBTileTemplate],
                        "tileSize": 256,
                        "minzoom": 5,
                        "maxzoom": NRWMapLayerCatalog.dopNativeMaximumZoomLevel
                    ]
                ],
                "layers": [["id": "dop", "type": "raster", "source": "dop"]]
            ]
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("krover-dop-style.json")
            guard let data = try? JSONSerialization.data(withJSONObject: style),
                  (try? data.write(to: url, options: .atomic)) != nil else { return nil }
            return url
        }
    }

    private func run(
        styleURL: URL,
        center: CLLocationCoordinate2D,
        zoom: Double,
        size: CGSize,
        scale: CGFloat,
        timeout: TimeInterval
    ) async -> Result? {
        let camera = MLNMapCamera()
        camera.centerCoordinate = center
        let options = MLNMapSnapshotOptions(styleURL: styleURL, camera: camera, size: size)
        options.zoomLevel = zoom
        options.scale = scale
        options.showsLogo = false
        options.showsAttribution = false
        let snapshotter = MLNMapSnapshotter(options: options)
        snapshotter.delegate = self
        self.snapshotter = snapshotter

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            snapshotter.start { [weak self] snapshot, _ in
                guard let snapshot else {
                    self?.finish(nil)
                    return
                }
                self?.finish(Result(
                    image: snapshot.image,
                    pointForCoordinate: { snapshot.point(for: $0) },
                    coordinateForPoint: { snapshot.coordinate(for: $0) }
                ))
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.snapshotter?.cancel()
                self?.finish(nil)
            }
        }
    }

    private func finish(_ result: Result?) {
        guard let continuation else { return }
        self.continuation = nil
        snapshotter = nil
        continuation.resume(returning: result)
    }

    nonisolated func mapSnapshotterDidFail(_ snapshotter: MLNMapSnapshotter, withError error: Error) {
        MainActor.assumeIsolated { finish(nil) }
    }
}
