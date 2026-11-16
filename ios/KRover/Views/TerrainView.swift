import Charts
import CoreLocation
import SwiftUI
import UIKit
import simd

/// Full-screen terrain model of one parcel: hypsometric height map with
/// contour lines, an interactive section profile and a 3D view.
struct TerrainView: View {
    let parcelLabel: String
    let points: [TerrainSurveyPoint]
    let model: TerrainModel?
    var onDeletePoint: ((UUID) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var displayMode = DisplayMode.map
    @State private var raster: TerrainRaster?
    @State private var contours: [TerrainContourSegment] = []
    @State private var contourInterval = 0.1
    @State private var statistics: TerrainStatistics?
    @State private var profileStart: SIMD2<Double>?
    @State private var profileEnd: SIMD2<Double>?
    @State private var selectedDistance: Double?
    @State private var exaggeration: Double = 1
    @State private var showsPointList = false

    private enum DisplayMode: String, CaseIterable, Identifiable {
        case map = "Höhenkarte"
        case scene = "3D"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                if horizontalSizeClass == .regular && geometry.size.width > geometry.size.height {
                    HStack(spacing: 0) {
                        visualization
                            .padding(16)
                        Divider()
                        ScrollView { detailPanel.padding(16) }
                            .frame(width: min(420, geometry.size.width * 0.42))
                    }
                } else {
                    VStack(spacing: 0) {
                        visualization
                            .frame(height: geometry.size.height * 0.46)
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                        ScrollView { detailPanel.padding(16) }
                    }
                }
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("Gelände · \(parcelLabel)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Fertig") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    Picker("Darstellung", selection: $displayMode) {
                        ForEach(DisplayMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Text(parcelLabel)
                        .font(.subheadline.bold())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task(id: model?.revision) { rebuildDerivedData() }
    }

    // MARK: Visualization

    @ViewBuilder private var visualization: some View {
        if let model {
            ZStack(alignment: .bottomLeading) {
                switch displayMode {
                case .map:
                    TerrainMapCanvas(
                        model: model,
                        raster: raster,
                        contours: contours,
                        profileStart: $profileStart,
                        profileEnd: $profileEnd,
                        highlightedPosition: selectedSample?.position
                    )
                case .scene:
                    if model.canInterpolate {
                        TerrainSceneView(
                            model: model,
                            exaggeration: exaggeration,
                            profileLine: profileLine
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    } else {
                        insufficientPointsNotice
                    }
                }
                if model.canInterpolate {
                    overlayControls(model)
                        .padding(10)
                }
            }
            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.10), lineWidth: 0.5)
            )
        } else {
            insufficientPointsNotice
        }
    }

    @ViewBuilder private func overlayControls(_ model: TerrainModel) -> some View {
        switch displayMode {
        case .map:
            HeightLegend(minHeight: model.minHeight, maxHeight: model.maxHeight, contourInterval: contourInterval)
        case .scene:
            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: "Überhöhung %.1f×", exaggeration))
                    .font(.caption.bold().monospacedDigit())
                Slider(value: $exaggeration, in: 1...30, step: 0.5)
                    .frame(width: 180)
            }
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var insufficientPointsNotice: some View {
        VStack(spacing: 10) {
            Image(systemName: "mountain.2")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Für ein Geländemodell werden mindestens drei Messpunkte benötigt, die nicht auf einer Linie liegen.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Detail panel

    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let model, model.canInterpolate {
                profileSection(model)
            }
            if let statistics, !points.isEmpty {
                statisticsSection(statistics)
            }
            pointListSection
            Text("Höhen aus GNSS (Ellipsoid- bzw. Geoidhöhe des Empfängers). Zwischen den Messpunkten wird linear über ein Dreiecksnetz interpoliert; graue Flächen sind nicht durch Messpunkte abgedeckt und werden nicht extrapoliert.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func profileSection(_ model: TerrainModel) -> some View {
        let samples = profileSamples
        let valid = samples.compactMap { sample in sample.height.map { (sample: sample, height: $0) } }
        let heights = valid.map(\.height)
        let lower = (heights.min() ?? model.minHeight)
        let upper = (heights.max() ?? model.maxHeight)
        let padding = max(0.05, (upper - lower) * 0.15)
        let domain = (lower - padding)...(upper + padding)
        let length = samples.last?.distance ?? 0

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Höhenprofil A → B")
                    .font(.headline)
                Spacer()
                Button {
                    resetProfileLine()
                } label: {
                    Label("Zurücksetzen", systemImage: "arrow.counterclockwise")
                        .font(.caption.bold())
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Text(displayMode == .map
                 ? "In der Höhenkarte eine Linie ziehen oder A/B verschieben. Zum Ablesen im Profil mit dem Finger entlangfahren."
                 : "Der Schnitt wird in der Höhenkarte festgelegt.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Chart {
                ForEach(profileRuns(samples)) { run in
                    ForEach(run.samples) { sample in
                        AreaMark(
                            x: .value("Strecke", sample.distance),
                            yStart: .value("Basis", domain.lowerBound),
                            yEnd: .value("Höhe", sample.height ?? domain.lowerBound),
                            series: .value("Abschnitt", "F\(run.id)")
                        )
                        .foregroundStyle(TerrainPalette.verticalGradient.opacity(0.55))
                        LineMark(
                            x: .value("Strecke", sample.distance),
                            y: .value("Höhe", sample.height ?? domain.lowerBound),
                            series: .value("Abschnitt", "L\(run.id)")
                        )
                        .foregroundStyle(.white)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                }
                if let selected = selectedSample, let height = selected.height {
                    RuleMark(x: .value("Auswahl", selected.distance))
                        .foregroundStyle(.white.opacity(0.5))
                    PointMark(x: .value("Auswahl", selected.distance), y: .value("Höhe", height))
                        .foregroundStyle(.cyan)
                        .symbolSize(70)
                }
            }
            .chartXScale(domain: 0...max(length, 0.1))
            .chartYScale(domain: domain)
            .chartXSelection(value: $selectedDistance)
            .chartXAxisLabel("Strecke [m]")
            .chartYAxisLabel("Höhe [m]")
            .frame(height: 210)

            if let selected = selectedSample {
                Group {
                    if let height = selected.height {
                        Text(String(format: "bei %.2f m: %.3f m · %+.3f m zum Tiefpunkt", selected.distance, height, height - model.minHeight))
                    } else {
                        Text(String(format: "bei %.2f m: nicht vermessen", selected.distance))
                    }
                }
                .font(.caption.bold().monospacedDigit())
                .foregroundStyle(.cyan)
            }

            if let first = valid.first, let last = valid.last, last.sample.distance > first.sample.distance {
                let horizontal = last.sample.distance - first.sample.distance
                let rise = last.height - first.height
                HStack(spacing: 10) {
                    TerrainMetric(title: "Länge", value: String(format: "%.1f m", length))
                    TerrainMetric(title: "ΔH A→B", value: String(format: "%+.2f m", rise))
                    TerrainMetric(title: "Ø Neigung", value: String(format: "%.1f %%", abs(rise) / horizontal * 100))
                    TerrainMetric(title: "max.", value: String(format: "%.1f %%", maximumProfileSlope(valid.map { ($0.sample.distance, $0.height) })))
                }
            }
        }
    }

    private func statisticsSection(_ statistics: TerrainStatistics) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Gelände")
                .font(.headline)
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    TerrainMetric(title: "Tiefpunkt", value: String(format: "%.2f m", statistics.minHeight))
                    TerrainMetric(title: "Hochpunkt", value: String(format: "%.2f m", statistics.maxHeight))
                    TerrainMetric(title: "Höhenspanne", value: String(format: "%.2f m", statistics.heightRange))
                }
                GridRow {
                    TerrainMetric(
                        title: "Ø Neigung",
                        value: statistics.meanSlopePercent.map { String(format: "%.1f %%", $0) } ?? "–"
                    )
                    TerrainMetric(
                        title: "Gefälle nach",
                        value: statistics.downhillBearing.map(Self.cardinalDirection) ?? "eben"
                    )
                    TerrainMetric(
                        title: "Abdeckung",
                        value: statistics.coveredFraction.map { String(format: "%.0f %%", $0 * 100) } ?? "–"
                    )
                }
            }
            if let covered = statistics.coveredFraction, covered < 0.8 {
                Label("Weitere Punkte entlang der Flurstücksgrenze erhöhen die Abdeckung.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var pointListSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { showsPointList.toggle() }
            } label: {
                HStack {
                    Text("Messpunkte (\(points.count))")
                        .font(.headline)
                    Spacer()
                    Image(systemName: showsPointList ? "chevron.up" : "chevron.down")
                        .font(.caption.bold())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsPointList {
                ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                    HStack(spacing: 10) {
                        Text("P\(index + 1)")
                            .font(.caption.bold())
                            .frame(width: 36, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(format: "%.3f m", point.altitudeMSL))
                                .font(.callout.monospacedDigit())
                            Text(pointDetail(point))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(point.isTest ? .orange : .secondary)
                        }
                        Spacer()
                        if let onDeletePoint {
                            Button(role: .destructive) {
                                onDeletePoint(point.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("P\(index + 1) löschen")
                        }
                    }
                    .padding(.vertical, 4)
                    Divider().overlay(.white.opacity(0.08))
                }
            }
        }
    }

    private func pointDetail(_ point: TerrainSurveyPoint) -> String {
        var parts: [String] = []
        if let vertical = point.estimatedVerticalAccuracy {
            parts.append(String(format: "H ±%.3f m", vertical))
        }
        parts.append("\(point.sampleCount) Werte")
        if point.isTest { parts.append("TEST") }
        parts.append(point.timestamp.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: " · ")
    }

    // MARK: Derived data

    private var profileLine: (SIMD2<Double>, SIMD2<Double>)? {
        guard let profileStart, let profileEnd else { return nil }
        return (profileStart, profileEnd)
    }

    private var profileSamples: [TerrainProfileSample] {
        guard let model, let line = profileLine else { return [] }
        return model.profile(from: line.0, to: line.1)
    }

    private var selectedSample: TerrainProfileSample? {
        guard let selectedDistance else { return nil }
        return profileSamples.min { abs($0.distance - selectedDistance) < abs($1.distance - selectedDistance) }
    }

    private struct ProfileRun: Identifiable {
        let id: Int
        let samples: [TerrainProfileSample]
    }

    /// Splits the profile into contiguous stretches with heights, so gaps
    /// outside the measured area are not bridged.
    private func profileRuns(_ samples: [TerrainProfileSample]) -> [ProfileRun] {
        var runs: [ProfileRun] = []
        var current: [TerrainProfileSample] = []
        for sample in samples {
            if sample.height != nil {
                current.append(sample)
            } else if !current.isEmpty {
                runs.append(ProfileRun(id: runs.count, samples: current))
                current = []
            }
        }
        if !current.isEmpty { runs.append(ProfileRun(id: runs.count, samples: current)) }
        return runs
    }

    private func maximumProfileSlope(_ values: [(distance: Double, height: Double)]) -> Double {
        zip(values, values.dropFirst()).reduce(0) { result, pair in
            let run = pair.1.distance - pair.0.distance
            guard run > 1e-6 else { return result }
            return max(result, abs(pair.1.height - pair.0.height) / run * 100)
        }
    }

    private func rebuildDerivedData() {
        guard let model else {
            raster = nil
            contours = []
            statistics = nil
            return
        }
        contourInterval = TerrainModel.contourInterval(forRange: model.heightRange)
        contours = model.contourSegments(interval: contourInterval)
        raster = model.canInterpolate ? model.makeRaster() : nil
        statistics = model.statistics()
        let span = max(model.displayBounds.width, model.displayBounds.height)
        exaggeration = min(30, max(1, (span * 0.2 / max(model.heightRange, 0.01) * 2).rounded() / 2))
        if profileStart == nil || profileEnd == nil { resetProfileLine() }
    }

    private func resetProfileLine() {
        guard let model else { return }
        let line = model.defaultProfileLine()
        profileStart = line.0
        profileEnd = line.1
        selectedDistance = nil
    }

    static func cardinalDirection(_ bearing: Double) -> String {
        let names = ["N", "NO", "O", "SO", "S", "SW", "W", "NW"]
        let index = Int(((bearing + 22.5).truncatingRemainder(dividingBy: 360)) / 45)
        return "\(names[index]) (\(Int(bearing.rounded()))°)"
    }
}

// MARK: - Palette

enum TerrainPalette {
    static var colors: [Color] {
        TerrainColorRamp.stops.map { Color(red: $0.color.x, green: $0.color.y, blue: $0.color.z) }
    }

    static var verticalGradient: LinearGradient {
        LinearGradient(colors: colors, startPoint: .bottom, endPoint: .top)
    }
}

private struct HeightLegend: View {
    let minHeight: Double
    let maxHeight: Double
    let contourInterval: Double

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            TerrainPalette.verticalGradient
                .frame(width: 10, height: 72)
                .clipShape(Capsule())
            VStack(alignment: .leading) {
                Text(String(format: "%.2f m", maxHeight))
                Spacer()
                Text(String(format: "Linien %@ m", Self.intervalText(contourInterval)))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.2f m", minHeight))
            }
            .font(.caption2.bold().monospacedDigit())
            .frame(height: 72)
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    static func intervalText(_ interval: Double) -> String {
        interval >= 1 ? String(format: "%.0f", interval)
            : interval >= 0.1 ? String(format: "%.2g", interval) : String(format: "%.2f", interval)
    }
}

private struct TerrainMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.subheadline.bold().monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - 2D height map

private struct TerrainMapCanvas: View {
    let model: TerrainModel
    let raster: TerrainRaster?
    let contours: [TerrainContourSegment]
    @Binding var profileStart: SIMD2<Double>?
    @Binding var profileEnd: SIMD2<Double>?
    let highlightedPosition: SIMD2<Double>?

    @State private var dragTarget: DragTarget?

    private enum DragTarget {
        case start
        case end
        case newLine(SIMD2<Double>)
    }

    var body: some View {
        GeometryReader { geometry in
            let transform = CanvasTransform(bounds: model.displayBounds.expanded(by: 0.5), size: geometry.size, padding: 18)
            Canvas { context, _ in
                draw(in: &context, transform: transform)
            }
            .contentShape(Rectangle())
            .gesture(profileGesture(transform))
            .overlay(alignment: .topTrailing) {
                northArrow.padding(10)
            }
            .overlay(alignment: .bottomTrailing) {
                scaleBar(transform).padding(12)
            }
        }
    }

    private func draw(in context: inout GraphicsContext, transform: CanvasTransform) {
        // Height raster.
        if let raster {
            let topLeft = transform.point(SIMD2(raster.bounds.minX, raster.bounds.maxY))
            let bottomRight = transform.point(SIMD2(raster.bounds.maxX, raster.bounds.minY))
            let rect = CGRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
            context.draw(Image(decorative: raster.image, scale: 1).interpolation(.high), in: rect)
        }

        // Parcel boundary.
        var parcelPath = Path()
        for ring in model.parcelRings where ring.count >= 3 {
            parcelPath.addLines(ring.map(transform.point))
            parcelPath.closeSubpath()
        }
        if raster == nil {
            context.fill(parcelPath, with: .color(.yellow.opacity(0.12)), style: FillStyle(eoFill: true))
        }

        // Contours.
        var minor = Path()
        var major = Path()
        for segment in contours {
            if segment.isMajor {
                major.move(to: transform.point(segment.start))
                major.addLine(to: transform.point(segment.end))
            } else {
                minor.move(to: transform.point(segment.start))
                minor.addLine(to: transform.point(segment.end))
            }
        }
        context.stroke(minor, with: .color(.black.opacity(0.35)), lineWidth: 0.8)
        context.stroke(major, with: .color(.black.opacity(0.6)), lineWidth: 1.6)

        context.stroke(parcelPath, with: .color(.yellow), lineWidth: 2.5)

        // Measurement points.
        let showLabels = model.vertices.count <= 40
        for vertex in model.vertices {
            let center = transform.point(vertex.position)
            let dot = Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
            context.fill(dot, with: .color(.white))
            context.stroke(dot, with: .color(.black.opacity(0.7)), lineWidth: 1)
            if showLabels {
                let label = Text(String(format: "%.2f", vertex.height - model.minHeight))
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundColor(.white)
                context.draw(label, at: CGPoint(x: center.x, y: center.y - 11))
            }
        }

        // Profile line.
        if let profileStart, let profileEnd {
            let start = transform.point(profileStart)
            let end = transform.point(profileEnd)
            var line = Path()
            line.move(to: start)
            line.addLine(to: end)
            context.stroke(line, with: .color(.black.opacity(0.6)), lineWidth: 5)
            context.stroke(line, with: .color(.cyan), style: StrokeStyle(lineWidth: 2.5, dash: [7, 4]))
            drawHandle("A", at: start, in: &context)
            drawHandle("B", at: end, in: &context)
        }

        if let highlightedPosition {
            let center = transform.point(highlightedPosition)
            let ring = Path(ellipseIn: CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16))
            context.fill(ring, with: .color(.cyan.opacity(0.35)))
            context.stroke(ring, with: .color(.white), lineWidth: 2)
        }
    }

    private func drawHandle(_ label: String, at point: CGPoint, in context: inout GraphicsContext) {
        let circle = Path(ellipseIn: CGRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24))
        context.fill(circle, with: .color(.cyan))
        context.stroke(circle, with: .color(.white), lineWidth: 2)
        context.draw(
            Text(label).font(.system(size: 13, weight: .bold)).foregroundColor(.black),
            at: point
        )
    }

    private func profileGesture(_ transform: CanvasTransform) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let location = transform.local(value.location)
                if dragTarget == nil {
                    let startPoint = profileStart.map(transform.point)
                    let endPoint = profileEnd.map(transform.point)
                    let distanceToStart = startPoint.map { hypot($0.x - value.startLocation.x, $0.y - value.startLocation.y) } ?? .infinity
                    let distanceToEnd = endPoint.map { hypot($0.x - value.startLocation.x, $0.y - value.startLocation.y) } ?? .infinity
                    if min(distanceToStart, distanceToEnd) < 32 {
                        dragTarget = distanceToStart <= distanceToEnd ? .start : .end
                    } else {
                        dragTarget = .newLine(transform.local(value.startLocation))
                    }
                }
                switch dragTarget {
                case .start:
                    profileStart = location
                case .end:
                    profileEnd = location
                case .newLine(let origin):
                    guard hypot(value.translation.width, value.translation.height) > 12 else { return }
                    profileStart = origin
                    profileEnd = location
                case nil:
                    break
                }
            }
            .onEnded { _ in dragTarget = nil }
    }

    private var northArrow: some View {
        VStack(spacing: 1) {
            Image(systemName: "location.north.fill")
                .font(.system(size: 14, weight: .bold))
            Text("N").font(.caption2.bold())
        }
        .padding(7)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func scaleBar(_ transform: CanvasTransform) -> some View {
        let targetMeters = 90 / max(transform.scale, 1e-6)
        let candidates: [Double] = [1, 2, 5, 10, 20, 25, 50, 100, 200, 500]
        let meters = candidates.last { $0 <= targetMeters } ?? 1
        let width = meters * transform.scale
        return VStack(alignment: .trailing, spacing: 3) {
            Text("\(Int(meters)) m")
                .font(.caption2.bold().monospacedDigit())
            Rectangle()
                .fill(.white)
                .frame(width: width, height: 3)
                .overlay(alignment: .leading) { Rectangle().fill(.white).frame(width: 1.5, height: 9) }
                .overlay(alignment: .trailing) { Rectangle().fill(.white).frame(width: 1.5, height: 9) }
        }
        .padding(7)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Maps local metric coordinates (north up) into a view rectangle.
private struct CanvasTransform {
    let bounds: TerrainBounds
    let scale: Double
    let offset: CGPoint

    init(bounds: TerrainBounds, size: CGSize, padding: CGFloat) {
        self.bounds = bounds
        let availableWidth = max(1, Double(size.width - 2 * padding))
        let availableHeight = max(1, Double(size.height - 2 * padding))
        scale = min(availableWidth / max(bounds.width, 1e-6), availableHeight / max(bounds.height, 1e-6))
        offset = CGPoint(
            x: (Double(size.width) - bounds.width * scale) / 2,
            y: (Double(size.height) - bounds.height * scale) / 2
        )
    }

    func point(_ local: SIMD2<Double>) -> CGPoint {
        CGPoint(x: offset.x + (local.x - bounds.minX) * scale, y: offset.y + (bounds.maxY - local.y) * scale)
    }

    func local(_ point: CGPoint) -> SIMD2<Double> {
        SIMD2(bounds.minX + (point.x - offset.x) / scale, bounds.maxY - (point.y - offset.y) / scale)
    }
}

// MARK: - Screen bound to the app model

struct TerrainScreen: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TerrainView(
            parcelLabel: model.selectedParcel?.label ?? "Flurstück",
            points: model.terrainPoints,
            model: model.terrainModel,
            onDeletePoint: { model.removeTerrainPoint(id: $0) }
        )
    }
}

#if DEBUG
/// Synthetic data for UI development (launch argument `-KRoverTerrainDemo`).
/// Uses the app's synthetic NRW demo location, never real parcels.
enum TerrainDemo {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-KRoverTerrainDemo")
    }

    static func makeView() -> TerrainView {
        let center = UTM32Projection.project(CLLocationCoordinate2D(latitude: 51.0, longitude: 7.0))
        let outline: [(Double, Double)] = [(0, 0), (42, -3), (47, 24), (20, 36), (-2, 28)]
        let ring = outline.map { UTMCoordinate(easting: center.easting + $0.0, northing: center.northing + $0.1) }

        var generator = SeededGenerator(seed: 7)
        var points: [TerrainSurveyPoint] = []
        for row in 0..<6 {
            for column in 0..<7 {
                let x = Double(column) * 7 + Double.random(in: -1.5...1.5, using: &generator)
                let y = Double(row) * 6 + Double.random(in: -1.5...1.5, using: &generator)
                let local = SIMD2(x, y)
                let rings = [outline.map { SIMD2($0.0, $0.1) }]
                guard TerrainGeometry.contains(local, rings: rings) else { continue }
                let height = 112.0 + 0.045 * x + 0.03 * y
                    + 0.55 * exp(-(pow(x - 30, 2) + pow(y - 18, 2)) / 60)
                    - 0.25 * exp(-(pow(x - 10, 2) + pow(y - 8, 2)) / 30)
                let coordinate = UTM32Projection.unproject(UTMCoordinate(
                    easting: center.easting + x,
                    northing: center.northing + y
                ))
                points.append(TerrainSurveyPoint(
                    coordinate: coordinate,
                    altitudeMSL: height + Double.random(in: -0.01...0.01, using: &generator),
                    estimatedVerticalAccuracy: 0.018,
                    estimatedHorizontalAccuracy: 0.012,
                    sampleCount: 15
                ))
            }
        }
        let model = TerrainModel(points: points, parcelRings: [ring])
        return TerrainView(parcelLabel: "Demo-Flurstück 123", points: points, model: model)
    }

    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }
}
#endif
