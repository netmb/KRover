import SwiftUI
import UIKit

/// Export sheet: choose content and formats, then hand the files to the
/// system share sheet (Dateien, AirDrop, Mail, Drucken …).
struct ExportView: View {
    let snapshot: SurveyExportSnapshot
    @Environment(\.dismiss) private var dismiss

    @AppStorage("export.formats") private var storedFormats = "pdf,csv"
    @AppStorage("export.background") private var storedBackground = "cadastre"
    @AppStorage("export.csvDecimalComma") private var csvUsesDecimalComma = false
    @State private var content: SurveyExportContent = .all
    @State private var isExporting = false
    @State private var sharedFiles: SharedFiles?
    @State private var errorMessage: String?

    private struct SharedFiles: Identifiable {
        let id = UUID()
        let urls: [URL]
    }

    private var formats: Set<SurveyExportFormat> {
        Set(storedFormats.split(separator: ",").compactMap { SurveyExportFormat(rawValue: String($0)) })
    }

    private var planBackground: MapBackgroundLayer? {
        MapBackgroundLayer(rawValue: storedBackground)
    }

    private var availableContent: SurveyExportContent {
        var result: SurveyExportContent = []
        if snapshot.parcel != nil { result.insert(.parcel) }
        if !snapshot.boundaryPoints.isEmpty { result.insert(.boundaryPoints) }
        if snapshot.measurement != nil { result.insert(.measurement) }
        if snapshot.terrain != nil { result.insert(.terrain) }
        return result
    }

    private var selectedContent: SurveyExportContent { content.intersection(availableContent) }

    private var canExport: Bool {
        !formats.isEmpty && !snapshot.filtered(by: selectedContent).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                if availableContent.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "Nichts zu exportieren",
                            systemImage: "square.and.arrow.up.trianglebadge.exclamationmark",
                            description: Text("Wähle ein Flurstück aus oder nimm eine Strecke, Fläche, Höhe oder Geländeaufnahme auf.")
                        )
                    }
                } else {
                    contentSection
                    formatSection
                    if formats.contains(.pdf) || formats.contains(.png) { planSection }
                    if formats.contains(.csv) { csvSection }
                    infoSection
                }
            }
            .navigationTitle("Exportieren")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isExporting {
                        ProgressView()
                    } else {
                        Button("Teilen") { export() }
                            .bold()
                            .disabled(!canExport)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !availableContent.isEmpty {
                    exportButton
                }
            }
        }
        .sheet(item: $sharedFiles) { files in
            ActivityView(items: files.urls)
                .ignoresSafeArea()
        }
        .alert("Export fehlgeschlagen", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Sections

    private var contentSection: some View {
        Section {
            if let parcel = snapshot.parcel {
                contentToggle(.parcel, title: "Flurstück", detail: parcel.label, systemImage: "pentagon")
            }
            if !snapshot.boundaryPoints.isEmpty {
                contentToggle(
                    .boundaryPoints,
                    title: "Grenzpunkte (ALKIS)",
                    detail: "\(snapshot.boundaryPoints.count) Punkte",
                    systemImage: "smallcircle.filled.circle"
                )
            }
            if let measurement = snapshot.measurement {
                contentToggle(
                    .measurement,
                    title: measurement.kind.title,
                    detail: measurementDetail(measurement),
                    systemImage: "ruler"
                )
            }
            if let terrain = snapshot.terrain {
                contentToggle(
                    .terrain,
                    title: "Geländeaufnahme",
                    detail: "\(terrain.points.count) Höhenpunkte",
                    systemImage: "mountain.2"
                )
            }
        } header: {
            Text("Inhalt")
        } footer: {
            if snapshot.containsTestPoints {
                Label("Enthält Testpunkte ohne RTK-Messung (iPhone-GPS oder auf der Karte gesetzt).", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func contentToggle(
        _ option: SurveyExportContent,
        title: String,
        detail: String,
        systemImage: String
    ) -> some View {
        Toggle(isOn: Binding(
            get: { content.contains(option) },
            set: { isOn in
                if isOn { content.insert(option) } else { content.remove(option) }
            }
        )) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } icon: {
                Image(systemName: systemImage)
            }
        }
    }

    private var formatSection: some View {
        Section {
            ForEach(SurveyExportFormat.allCases) { format in
                Button {
                    var updated = formats
                    if updated.contains(format) { updated.remove(format) } else { updated.insert(format) }
                    storedFormats = SurveyExportFormat.allCases
                        .filter(updated.contains)
                        .map(\.rawValue)
                        .joined(separator: ",")
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: format.systemImage)
                            .frame(width: 26)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(format.title)
                                .foregroundStyle(.primary)
                            Text(format.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: formats.contains(format) ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(formats.contains(format) ? Color.accentColor : Color.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(formats.contains(format) ? .isSelected : [])
            }
        } header: {
            Text("Formate")
        } footer: {
            Text("Mehrere Formate werden gemeinsam geteilt, z. B. „In Dateien sichern“, AirDrop oder Mail.")
        }
    }

    private var planSection: some View {
        Section {
            Picker("Kartenhintergrund", selection: $storedBackground) {
                Text("Liegenschaftskarte").tag(MapBackgroundLayer.cadastre.rawValue)
                Text("Luftbild (DOP)").tag(MapBackgroundLayer.aerialDOP.rawValue)
                Text("Ohne (nur Vektorplan)").tag("none")
            }
        } header: {
            Text("Lageplan")
        } footer: {
            Text("Der Hintergrund wird online von Geobasis NRW geladen. Ohne Verbindung entsteht automatisch ein Vektorplan.")
        }
    }

    private var csvSection: some View {
        Section {
            Toggle("Dezimalkomma für Excel", isOn: $csvUsesDecimalComma)
        } header: {
            Text("CSV")
        } footer: {
            Text("Trennzeichen ist immer „;“. Für QGIS und Vermessungssoftware den Dezimalpunkt beibehalten.")
        }
    }

    private var infoSection: some View {
        Section {
            LabeledContent("Lage", value: "ETRS89 / UTM 32N")
            LabeledContent("EPSG", value: "25832 (GeoJSON/KML/GPX: WGS84)")
            LabeledContent("Höhe Boden", value: String(format: "GNSS − Stab %.3f m", snapshot.poleLength))
        } header: {
            Text("Bezugssystem")
        } footer: {
            Text(SurveyExportWriters.heightDescription + ". Grenzpunkte und Flurstück stammen aus ALKIS NRW und dienen als Auffindehilfe.")
        }
    }

    private var exportButton: some View {
        Button(action: export) {
            HStack {
                if isExporting {
                    ProgressView().tint(.white)
                    Text("Wird erstellt …")
                } else {
                    Image(systemName: "square.and.arrow.up")
                    Text(formats.count == 1 ? "1 Datei teilen" : "\(formats.count) Dateien teilen")
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .disabled(!canExport)
        .allowsHitTesting(!isExporting)
        .animation(nil, value: isExporting)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: Actions

    private func export() {
        guard canExport, !isExporting else { return }
        isExporting = true
        let settings = SurveyExportSettings(
            formats: formats,
            content: selectedContent,
            planBackground: planBackground,
            csvUsesDecimalComma: csvUsesDecimalComma
        )
        Task { @MainActor in
            defer { isExporting = false }
            do {
                let urls = try await SurveyExporter.export(snapshot, settings: settings)
                sharedFiles = SharedFiles(urls: urls)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func measurementDetail(_ measurement: SurveyExportMeasurement) -> String {
        var parts = ["\(measurement.points.count) Punkte"]
        if let length = measurement.length, measurement.kind == .distance {
            parts.append(String(format: "%.3f m", length))
        }
        if let area = measurement.area { parts.append(String(format: "%.3f m²", area)) }
        return parts.joined(separator: " · ")
    }
}

/// UIKit share sheet; supports multiple files and "In Dateien sichern".
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
