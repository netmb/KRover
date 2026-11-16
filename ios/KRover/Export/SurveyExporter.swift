import Foundation
import UniformTypeIdentifiers

enum SurveyExportFormat: String, CaseIterable, Identifiable, Hashable {
    case pdf
    case png
    case csv
    case dxf
    case geoJSON
    case kml
    case gpx
    case landXML

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pdf: return "PDF-Messprotokoll"
        case .png: return "Lageplan als Bild"
        case .csv: return "CSV-Punktliste"
        case .dxf: return "DXF (CAD)"
        case .geoJSON: return "GeoJSON"
        case .kml: return "KML (Google Earth)"
        case .gpx: return "GPX"
        case .landXML: return "LandXML"
        }
    }

    var detail: String {
        switch self {
        case .pdf: return "Lageplan, Ergebnisse, Punktliste – zum Drucken oder Weitergeben"
        case .png: return "Karte mit Messung, Maßstab und Nordpfeil"
        case .csv: return "Punktnummer, E/N/H in UTM 32 und WGS84 – Excel, QGIS, Vermessungssoftware"
        case .dxf: return "AutoCAD/BricsCAD/QCAD – Layer, Punkte, Linien, Geländedreiecke"
        case .geoJSON: return "QGIS, ArcGIS, Webkarten (WGS84)"
        case .kml: return "Google Earth, Google My Maps"
        case .gpx: return "Wegpunkte für GPS-Geräte und Outdoor-Apps"
        case .landXML: return "Civil 3D, 12d, Trimble – Punkte und Geländeoberfläche (TIN)"
        }
    }

    var systemImage: String {
        switch self {
        case .pdf: return "doc.richtext"
        case .png: return "photo"
        case .csv: return "tablecells"
        case .dxf: return "square.on.square.dashed"
        case .geoJSON: return "curlybraces"
        case .kml: return "globe.europe.africa"
        case .gpx: return "mappin.and.ellipse"
        case .landXML: return "chevron.left.forwardslash.chevron.right"
        }
    }

    var fileExtension: String {
        switch self {
        case .pdf: return "pdf"
        case .png: return "png"
        case .csv: return "csv"
        case .dxf: return "dxf"
        case .geoJSON: return "geojson"
        case .kml: return "kml"
        case .gpx: return "gpx"
        case .landXML: return "xml"
        }
    }

    var isDocument: Bool { self == .pdf || self == .png }
}

struct SurveyExportSettings: Equatable {
    var formats: Set<SurveyExportFormat> = [.pdf, .csv]
    var content: SurveyExportContent = .all
    /// `nil` renders the plan without background map.
    var planBackground: MapBackgroundLayer? = .cadastre
    var csvUsesDecimalComma = false
}

enum SurveyExporter {
    enum ExportError: LocalizedError {
        case nothingToExport
        case renderingFailed(SurveyExportFormat)

        var errorDescription: String? {
            switch self {
            case .nothingToExport: return "Für die gewählten Inhalte liegen keine Daten vor."
            case .renderingFailed(let format): return "\(format.title) konnte nicht erstellt werden."
            }
        }
    }

    /// Writes the selected formats to a fresh temporary folder.
    @MainActor
    static func export(_ snapshot: SurveyExportSnapshot, settings: SurveyExportSettings) async throws -> [URL] {
        let filtered = snapshot.filtered(by: settings.content)
        guard !filtered.isEmpty else { throw ExportError.nothingToExport }

        removeTemporaryExports()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("KRoverExport", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var urls: [URL] = []
        for format in SurveyExportFormat.allCases where settings.formats.contains(format) {
            let data: Data
            switch format {
            case .pdf:
                data = await SurveyPlanRenderer.pdfReport(filtered, background: settings.planBackground)
            case .png:
                guard let image = await SurveyPlanRenderer.planImage(filtered, background: settings.planBackground) else {
                    throw ExportError.renderingFailed(format)
                }
                data = image
            case .csv:
                data = SurveyExportWriters.csv(
                    filtered,
                    options: .init(usesDecimalComma: settings.csvUsesDecimalComma)
                )
            case .dxf:
                data = SurveyExportWriters.dxf(filtered)
            case .geoJSON:
                data = SurveyExportWriters.geoJSON(filtered)
            case .kml:
                data = SurveyExportWriters.kml(filtered)
            case .gpx:
                data = SurveyExportWriters.gpx(filtered)
            case .landXML:
                data = SurveyExportWriters.landXML(filtered)
            }
            let url = folder.appendingPathComponent(filtered.fileBaseName)
                .appendingPathExtension(format.fileExtension)
            try data.write(to: url, options: .atomic)
            urls.append(url)
        }
        return urls
    }

    /// Removes files of earlier exports; they were already handed to the share sheet.
    private static func removeTemporaryExports() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KRoverExport", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
    }
}
