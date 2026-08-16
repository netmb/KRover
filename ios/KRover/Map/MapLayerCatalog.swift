import Foundation

enum MapBackgroundLayer: String, CaseIterable, Identifiable {
    case cadastre
    case aerialDOP

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cadastre: return "Kataster"
        case .aerialDOP: return "Luftbild (DOP)"
        }
    }

    var detail: String {
        switch self {
        case .cadastre: return "Amtliche Liegenschaftskarte NRW"
        case .aerialDOP: return "Amtliches digitales Orthophoto NRW"
        }
    }

    var systemImage: String {
        switch self {
        case .cadastre: return "map"
        case .aerialDOP: return "globe.europe.africa.fill"
        }
    }
}

enum NRWMapLayerCatalog {
    static let precisionMaximumZoomLevel = 25.5
    static let dopNativeMaximumZoomLevel = 22.0
    static let dopSourceIdentifier = "nrw-dop-rgb-source"
    static let dopLayerIdentifier = "nrw-dop-rgb-layer"

    /// WMS 1.1.1 keeps the EPSG:3857 BBOX axis order compatible with the
    /// Web-Mercator tile placeholder understood by MapLibre Native.
    static let dopRGBTileTemplate =
        "https://www.wms.nrw.de/geobasis/wms_nw_dop" +
        "?SERVICE=WMS&VERSION=1.1.1&REQUEST=GetMap" +
        "&LAYERS=nw_dop_rgb&STYLES=&FORMAT=image/jpeg" +
        "&TRANSPARENT=false&SRS=EPSG:3857" +
        "&WIDTH=256&HEIGHT=256&BBOX={bbox-epsg-3857}"

    static let geobasisAttributionHTML =
        "<a href=\"https://www.wms.nrw.de/geobasis/wms_nw_dop\">Geobasis NRW · DOP</a>"
}
