import CoreLocation
import UIKit

/// Maps geographic coordinates into a drawing rectangle.
struct SurveyPlanProjection {
    let rect: CGRect
    let point: (CLLocationCoordinate2D) -> CGPoint
    let metersPerPoint: Double
    /// Raster background (map snapshot). `nil` draws a plain plan.
    let backgroundImage: UIImage?

    /// Planar UTM projection that fits `coordinates` into `rect` (grid north up).
    static func vector(
        fitting coordinates: [CLLocationCoordinate2D],
        into rect: CGRect,
        minimumExtent: Double = 20
    ) -> SurveyPlanProjection {
        let utm = coordinates.map(UTM32Projection.project)
        let region = SurveyPlanRegion(utm: utm, minimumExtent: minimumExtent)
        let scale = min(rect.width / region.width, rect.height / region.height)
        let centerX = (region.minE + region.maxE) / 2
        let centerY = (region.minN + region.maxN) / 2
        return SurveyPlanProjection(
            rect: rect,
            point: { coordinate in
                let projected = UTM32Projection.project(coordinate)
                return CGPoint(
                    x: rect.midX + (projected.easting - centerX) * scale,
                    y: rect.midY - (projected.northing - centerY) * scale
                )
            },
            metersPerPoint: 1 / scale,
            backgroundImage: nil
        )
    }

    /// Planar UTM projection showing `region` (already fitted to the rect's aspect).
    static func vector(region: SurveyPlanRegion, into rect: CGRect) -> SurveyPlanProjection {
        let scale = min(rect.width / region.width, rect.height / region.height)
        let centerX = (region.minE + region.maxE) / 2
        let centerY = (region.minN + region.maxN) / 2
        return SurveyPlanProjection(
            rect: rect,
            point: { coordinate in
                let projected = UTM32Projection.project(coordinate)
                return CGPoint(
                    x: rect.midX + (projected.easting - centerX) * scale,
                    y: rect.midY - (projected.northing - centerY) * scale
                )
            },
            metersPerPoint: 1 / scale,
            backgroundImage: nil
        )
    }

    static func snapshot(_ snapshot: SurveyMapSnapshotter.Result, into rect: CGRect) -> SurveyPlanProjection {
        let size = snapshot.image.size
        let sx = rect.width / size.width
        let sy = rect.height / size.height
        let left = snapshot.coordinateForPoint(CGPoint(x: size.width * 0.25, y: size.height / 2))
        let right = snapshot.coordinateForPoint(CGPoint(x: size.width * 0.75, y: size.height / 2))
        let meters = UTM32Projection.distance(UTM32Projection.project(left), UTM32Projection.project(right))
        return SurveyPlanProjection(
            rect: rect,
            point: { coordinate in
                let point = snapshot.pointForCoordinate(coordinate)
                return CGPoint(x: rect.minX + point.x * sx, y: rect.minY + point.y * sy)
            },
            metersPerPoint: meters / (size.width * 0.5 * sx),
            backgroundImage: snapshot.image
        )
    }
}

/// Padded bounding box (UTM metres) of the plan content.
struct SurveyPlanRegion {
    let minE: Double
    let minN: Double
    let maxE: Double
    let maxN: Double

    var width: Double { maxE - minE }
    var height: Double { maxN - minN }

    init(utm: [UTMCoordinate], minimumExtent: Double = 20, margin: Double = 0.14) {
        let eastings = utm.map(\.easting)
        let northings = utm.map(\.northing)
        var minE = eastings.min() ?? 0
        var maxE = eastings.max() ?? 0
        var minN = northings.min() ?? 0
        var maxN = northings.max() ?? 0
        let extent = max(maxE - minE, maxN - minN, minimumExtent)
        let padE = (extent - (maxE - minE)) / 2 + extent * margin
        let padN = (extent - (maxN - minN)) / 2 + extent * margin
        minE -= padE; maxE += padE; minN -= padN; maxN += padN
        self.minE = minE; self.maxE = maxE; self.minN = minN; self.maxN = maxN
    }

    /// Region stretched to the target aspect ratio (width / height).
    func fitted(toAspect aspect: Double) -> SurveyPlanRegion {
        var minE = minE, maxE = maxE, minN = minN, maxN = maxN
        if width / height < aspect {
            let extra = (height * aspect - width) / 2
            minE -= extra; maxE += extra
        } else {
            let extra = (width / aspect - height) / 2
            minN -= extra; maxN += extra
        }
        return SurveyPlanRegion(minE: minE, minN: minN, maxE: maxE, maxN: maxN)
    }

    private init(minE: Double, minN: Double, maxE: Double, maxN: Double) {
        self.minE = minE; self.minN = minN; self.maxE = maxE; self.maxN = maxN
    }

    func extendedEast(by meters: Double) -> SurveyPlanRegion {
        SurveyPlanRegion(minE: minE, minN: minN, maxE: maxE + meters, maxN: maxN)
    }

    var southWest: CLLocationCoordinate2D {
        UTM32Projection.unproject(UTMCoordinate(easting: minE, northing: minN))
    }

    var northEast: CLLocationCoordinate2D {
        UTM32Projection.unproject(UTMCoordinate(easting: maxE, northing: maxN))
    }
}

/// Draws the survey plan (Lageplan) and the PDF report (Messprotokoll).
enum SurveyPlanRenderer {
    // MARK: - Colors

    private static let parcelColor = UIColor(red: 0.96, green: 0.76, blue: 0.05, alpha: 1)
    private static let measurementColor = UIColor(red: 0.12, green: 0.45, blue: 0.95, alpha: 1)
    private static let boundaryColor = UIColor(red: 0.16, green: 0.62, blue: 0.27, alpha: 1)
    private static let testColor = UIColor(red: 0.95, green: 0.45, blue: 0.08, alpha: 1)
    private static let ink = UIColor(white: 0.1, alpha: 1)
    private static let mutedInk = UIColor(white: 0.38, alpha: 1)
    private static let rule = UIColor(white: 0.82, alpha: 1)

    // MARK: - Plan

    struct PlanOptions {
        var labelsPoints = true
        var showsTerrain = true
        /// Enlarges symbols and labels for large canvases (PNG).
        var symbolScale: CGFloat = 1
    }

    /// Draws parcel, measurement, points, scale bar and north arrow.
    static func drawPlan(
        _ snapshot: SurveyExportSnapshot,
        projection: SurveyPlanProjection,
        in context: CGContext,
        options: PlanOptions = PlanOptions()
    ) {
        let rect = projection.rect
        let k = options.symbolScale
        context.saveGState()
        context.clip(to: rect)

        if let image = projection.backgroundImage {
            image.draw(in: rect)
            // Slight veil so overlays stay readable on the orthophoto.
            UIColor(white: 1, alpha: 0.12).setFill()
            context.fill(rect)
        } else {
            UIColor(red: 0.985, green: 0.98, blue: 0.965, alpha: 1).setFill()
            context.fill(rect)
            drawGrid(projection: projection, in: context)
        }

        if options.showsTerrain, let terrain = snapshot.terrain, let model = terrain.model, model.canInterpolate {
            drawTerrain(model, projection: projection, in: context)
        }

        if let parcel = snapshot.parcel {
            let path = UIBezierPath()
            for ring in parcel.wgs84Rings where ring.count >= 2 {
                path.move(to: projection.point(ring[0]))
                for coordinate in ring.dropFirst() { path.addLine(to: projection.point(coordinate)) }
                path.close()
            }
            path.usesEvenOddFillRule = true
            parcelColor.withAlphaComponent(snapshot.terrain?.model?.canInterpolate == true ? 0.0 : 0.12).setFill()
            path.fill()
            UIColor.black.withAlphaComponent(0.35).setStroke()
            path.lineWidth = 3.4 * k
            path.stroke()
            parcelColor.setStroke()
            path.lineWidth = 2.2 * k
            path.stroke()
        }

        if let measurement = snapshot.measurement, measurement.points.count >= 2 {
            let path = UIBezierPath()
            path.move(to: projection.point(measurement.points[0].coordinate))
            for point in measurement.points.dropFirst() { path.addLine(to: projection.point(point.coordinate)) }
            if measurement.kind == .area && measurement.points.count >= 3 {
                path.close()
                measurementColor.withAlphaComponent(0.16).setFill()
                path.fill()
            }
            path.lineJoinStyle = .round
            UIColor.white.withAlphaComponent(0.85).setStroke()
            path.lineWidth = 4 * k
            path.stroke()
            measurementColor.setStroke()
            path.lineWidth = 2.2 * k
            path.stroke()
            drawSegmentLengths(measurement, projection: projection, scale: k)
        }

        let terrainModel = snapshot.terrain?.model
        let labelBudget = options.labelsPoints ? 90 : 0
        let labelsAllowed = snapshot.allPoints.count <= labelBudget
        for point in snapshot.boundaryPoints {
            drawPoint(at: projection.point(point.coordinate), fill: .white, stroke: boundaryColor, radius: 3.2 * k)
        }
        for point in snapshot.measurement?.points ?? [] {
            drawPoint(
                at: projection.point(point.coordinate),
                fill: point.isTest ? testColor : measurementColor,
                stroke: .white,
                radius: 3.6 * k
            )
        }
        for point in snapshot.terrain?.points ?? [] {
            var fill = point.isTest ? testColor : measurementColor
            if let model = terrainModel, let height = point.antennaHeight, model.heightRange > 1e-6 {
                let color = TerrainColorRamp.color(at: model.normalizedHeight(height))
                fill = UIColor(red: color.x, green: color.y, blue: color.z, alpha: 1)
            }
            drawPoint(at: projection.point(point.coordinate), fill: fill, stroke: ink, radius: 3 * k)
        }
        if labelsAllowed {
            for point in snapshot.surveyedPoints {
                drawLabel(point.name, at: projection.point(point.coordinate), color: ink, size: 8.5 * k)
            }
            if snapshot.boundaryPoints.count <= 40 {
                for point in snapshot.boundaryPoints {
                    drawLabel(point.name, at: projection.point(point.coordinate), color: boundaryColor, size: 7 * k)
                }
            }
        }

        context.restoreGState()

        drawNorthArrow(in: CGRect(x: rect.maxX - 34, y: rect.minY + 8, width: 26, height: 36))
        drawScaleBar(metersPerPoint: projection.metersPerPoint, origin: CGPoint(x: rect.minX + 10, y: rect.maxY - 12))
        UIColor(white: 0.25, alpha: 1).setStroke()
        let frame = UIBezierPath(rect: rect)
        frame.lineWidth = 0.75
        frame.stroke()
    }

    private static func drawGrid(projection: SurveyPlanProjection, in context: CGContext) {
        let rect = projection.rect
        let spacing = niceStep(Double(rect.width) * projection.metersPerPoint / 6)
        let pointSpacing = CGFloat(spacing / projection.metersPerPoint)
        guard pointSpacing > 8 else { return }
        UIColor(white: 0.86, alpha: 1).setStroke()
        let path = UIBezierPath()
        var x = rect.minX + pointSpacing / 2
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            x += pointSpacing
        }
        var y = rect.minY + pointSpacing / 2
        while y < rect.maxY {
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
            y += pointSpacing
        }
        path.lineWidth = 0.4
        path.stroke()
    }

    private static func drawTerrain(_ model: TerrainModel, projection: SurveyPlanProjection, in context: CGContext) {
        guard let raster = model.makeRaster(maxDimension: 700) else { return }
        let bounds = raster.bounds
        // Affine transform from image unit square to the projected corners,
        // so the raster follows the projection's rotation (UTM vs. Mercator).
        let topLeft = projection.point(model.coordinate(of: SIMD2(bounds.minX, bounds.maxY)))
        let topRight = projection.point(model.coordinate(of: SIMD2(bounds.maxX, bounds.maxY)))
        let bottomLeft = projection.point(model.coordinate(of: SIMD2(bounds.minX, bounds.minY)))
        context.saveGState()
        context.concatenate(CGAffineTransform(
            a: topRight.x - topLeft.x, b: topRight.y - topLeft.y,
            c: bottomLeft.x - topLeft.x, d: bottomLeft.y - topLeft.y,
            tx: topLeft.x, ty: topLeft.y
        ))
        context.setAlpha(0.88)
        UIImage(cgImage: raster.image).draw(in: CGRect(x: 0, y: 0, width: 1, height: 1))
        context.restoreGState()

        let interval = TerrainModel.contourInterval(forRange: model.heightRange)
        for segment in model.contourSegments(interval: interval) {
            let path = UIBezierPath()
            path.move(to: projection.point(model.coordinate(of: segment.start)))
            path.addLine(to: projection.point(model.coordinate(of: segment.end)))
            path.lineWidth = segment.isMajor ? 0.9 : 0.45
            UIColor(white: 0.15, alpha: segment.isMajor ? 0.7 : 0.45).setStroke()
            path.stroke()
        }
    }

    private static func drawSegmentLengths(_ measurement: SurveyExportMeasurement, projection: SurveyPlanProjection, scale: CGFloat) {
        guard measurement.points.count <= 40 else { return }
        var pairs = Array(zip(measurement.points, measurement.points.dropFirst()))
        if measurement.kind == .area, measurement.points.count >= 3,
           let first = measurement.points.first, let last = measurement.points.last {
            pairs.append((last, first))
        }
        for (start, end) in pairs {
            let a = projection.point(start.coordinate)
            let b = projection.point(end.coordinate)
            guard hypot(b.x - a.x, b.y - a.y) > 46 * scale else { continue }
            let length = UTM32Projection.distance(start.utm, end.utm)
            drawLabel(
                String(format: "%.2f m", length),
                at: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2),
                color: measurementColor,
                size: 7.5 * scale,
                centered: true
            )
        }
    }

    private static func drawPoint(at point: CGPoint, fill: UIColor, stroke: UIColor, radius: CGFloat) {
        let path = UIBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        fill.setFill()
        path.fill()
        stroke.setStroke()
        path.lineWidth = 1.1
        path.stroke()
    }

    private static func drawLabel(_ text: String, at point: CGPoint, color: UIColor, size: CGFloat, centered: Bool = false) {
        let font = UIFont.systemFont(ofSize: size, weight: .semibold)
        let halo = NSAttributedString(string: text, attributes: [
            .font: font,
            .strokeColor: UIColor.white,
            .strokeWidth: 5.0
        ])
        let label = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let textSize = label.size()
        let origin = centered
            ? CGPoint(x: point.x - textSize.width / 2, y: point.y - textSize.height / 2)
            : CGPoint(x: point.x + size * 0.55, y: point.y - textSize.height - 1)
        halo.draw(at: origin)
        label.draw(at: origin)
    }

    private static func drawNorthArrow(in rect: CGRect) {
        let background = UIBezierPath(roundedRect: rect, cornerRadius: 4)
        UIColor.white.withAlphaComponent(0.85).setFill()
        background.fill()
        let arrow = UIBezierPath()
        arrow.move(to: CGPoint(x: rect.midX, y: rect.minY + 13))
        arrow.addLine(to: CGPoint(x: rect.midX + 6, y: rect.maxY - 4))
        arrow.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - 9))
        arrow.addLine(to: CGPoint(x: rect.midX - 6, y: rect.maxY - 4))
        arrow.close()
        ink.setFill()
        arrow.fill()
        let label = NSAttributedString(string: "N", attributes: [
            .font: UIFont.systemFont(ofSize: 9, weight: .bold),
            .foregroundColor: ink
        ])
        label.draw(at: CGPoint(x: rect.midX - label.size().width / 2, y: rect.minY + 1))
    }

    private static func drawScaleBar(metersPerPoint: Double, origin: CGPoint) {
        guard metersPerPoint > 0, metersPerPoint.isFinite else { return }
        let meters = niceStep(110 * metersPerPoint)
        let length = CGFloat(meters / metersPerPoint)
        let background = UIBezierPath(roundedRect: CGRect(x: origin.x - 5, y: origin.y - 19, width: length + 10, height: 24), cornerRadius: 4)
        UIColor.white.withAlphaComponent(0.85).setFill()
        background.fill()
        let half = length / 2
        ink.setFill()
        UIRectFill(CGRect(x: origin.x, y: origin.y - 4, width: half, height: 4))
        ink.setStroke()
        let outline = UIBezierPath(rect: CGRect(x: origin.x, y: origin.y - 4, width: length, height: 4))
        outline.lineWidth = 0.8
        outline.stroke()
        let text = meters >= 1 ? String(format: "%.0f m", meters) : String(format: "%.1f m", meters)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 7.5, weight: .medium),
            .foregroundColor: ink
        ]
        NSAttributedString(string: "0", attributes: attributes).draw(at: CGPoint(x: origin.x, y: origin.y - 16))
        let endLabel = NSAttributedString(string: text, attributes: attributes)
        endLabel.draw(at: CGPoint(x: origin.x + length - endLabel.size().width, y: origin.y - 16))
    }

    static func niceStep(_ raw: Double) -> Double {
        guard raw > 0, raw.isFinite else { return 1 }
        let magnitude = pow(10, floor(log10(raw)))
        let normalized = raw / magnitude
        let nice: Double = normalized < 1.5 ? 1 : normalized < 3.5 ? 2 : normalized < 7.5 ? 5 : 10
        return nice * magnitude
    }

    // MARK: - Projection helper

    /// Builds a projection, preferring the background map snapshot.
    @MainActor
    static func makeProjection(
        for snapshot: SurveyExportSnapshot,
        rect: CGRect,
        background: MapBackgroundLayer?,
        scale: CGFloat
    ) async -> SurveyPlanProjection {
        let coordinates = snapshot.focusCoordinates
        guard !coordinates.isEmpty else { return .vector(fitting: coordinates, into: rect) }
        let region = visibleRegion(for: snapshot, aspect: rect.width / rect.height)
        guard let background else { return .vector(region: region, into: rect) }
        if let result = await SurveyMapSnapshotter.snapshot(
            southWest: region.southWest,
            northEast: region.northEast,
            size: rect.size,
            scale: scale,
            background: background
        ) {
            return .snapshot(result, into: rect)
        }
        return .vector(region: region, into: rect)
    }

    /// Visible plan region. When the plan zooms into a small part of the
    /// content, room is left on the east side for the overview inset.
    static func visibleRegion(for snapshot: SurveyExportSnapshot, aspect: Double) -> SurveyPlanRegion {
        let focus = SurveyPlanRegion(utm: snapshot.focusCoordinates.map(UTM32Projection.project))
        guard needsOverviewInset(snapshot, focus: focus) else { return focus.fitted(toAspect: aspect) }
        return focus.extendedEast(by: focus.width * 0.5).fitted(toAspect: aspect)
    }

    private static func needsOverviewInset(_ snapshot: SurveyExportSnapshot, focus: SurveyPlanRegion) -> Bool {
        let all = snapshot.boundingCoordinates.map(UTM32Projection.project)
        guard !all.isEmpty else { return false }
        let full = SurveyPlanRegion(utm: all)
        return max(full.width, full.height) > max(focus.width, focus.height) * 2.5
    }

    /// Small overview map when the plan is zoomed into a part of the content.
    static func drawOverviewInsetIfNeeded(_ snapshot: SurveyExportSnapshot, planRect: CGRect) {
        let focus = SurveyPlanRegion(utm: snapshot.focusCoordinates.map(UTM32Projection.project))
        guard needsOverviewInset(snapshot, focus: focus) else { return }
        let aspect = planRect.width / planRect.height
        let visible = visibleRegion(for: snapshot, aspect: aspect)

        let insetWidth = min(170, planRect.width * 0.3)
        let frame = CGRect(
            x: planRect.maxX - insetWidth - 8,
            y: planRect.maxY - insetWidth / aspect - 8,
            width: insetWidth,
            height: insetWidth / aspect
        )
        let background = UIBezierPath(roundedRect: frame, cornerRadius: 4)
        UIColor.white.withAlphaComponent(0.92).setFill()
        background.fill()
        UIColor(white: 0.3, alpha: 1).setStroke()
        background.lineWidth = 0.6
        background.stroke()

        let projection = SurveyPlanProjection.vector(
            fitting: snapshot.boundingCoordinates,
            into: frame.insetBy(dx: 4, dy: 4)
        )
        if let parcel = snapshot.parcel {
            let path = UIBezierPath()
            for ring in parcel.wgs84Rings where ring.count >= 2 {
                path.move(to: projection.point(ring[0]))
                for coordinate in ring.dropFirst() { path.addLine(to: projection.point(coordinate)) }
                path.close()
            }
            parcelColor.withAlphaComponent(0.18).setFill()
            path.fill()
            parcelColor.setStroke()
            path.lineWidth = 1.2
            path.stroke()
        }
        let corners = [
            (visible.minE, visible.maxN), (visible.maxE, visible.maxN),
            (visible.maxE, visible.minN), (visible.minE, visible.minN)
        ].map { projection.point(UTM32Projection.unproject(UTMCoordinate(easting: $0.0, northing: $0.1))) }
        let box = UIBezierPath()
        box.move(to: corners[0])
        corners.dropFirst().forEach { box.addLine(to: $0) }
        box.close()
        // Keep tiny measurements visible as at least a few points.
        let bounds = box.bounds
        let marker = bounds.width < 6 || bounds.height < 6
            ? UIBezierPath(rect: CGRect(x: bounds.midX - 4, y: bounds.midY - 4, width: 8, height: 8))
            : box
        UIColor.systemRed.setStroke()
        marker.lineWidth = 1.4
        marker.stroke()
        draw("Übersicht", in: CGRect(x: frame.minX + 5, y: frame.minY + 3, width: frame.width - 10, height: 10),
             font: .systemFont(ofSize: 6.5, weight: .semibold), color: mutedInk)
    }

    // MARK: - PNG

    @MainActor
    static func planImage(
        _ snapshot: SurveyExportSnapshot,
        background: MapBackgroundLayer?
    ) async -> Data? {
        let canvas = CGSize(width: 1200, height: 900)
        let footerHeight: CGFloat = 92
        let planRect = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height - footerHeight)
        let projection = await makeProjection(for: snapshot, rect: planRect, background: background, scale: 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: canvas, format: format)
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: canvas))
            drawPlan(snapshot, projection: projection, in: context.cgContext,
                     options: PlanOptions(symbolScale: 1.7))
            drawOverviewInsetIfNeeded(snapshot, planRect: planRect)

            let footer = CGRect(x: 0, y: planRect.maxY, width: canvas.width, height: footerHeight)
                .insetBy(dx: 18, dy: 12)
            draw(snapshot.title, in: CGRect(x: footer.minX, y: footer.minY, width: footer.width * 0.6, height: 24),
                 font: .systemFont(ofSize: 19, weight: .bold))
            draw(subtitle(for: snapshot), in: CGRect(x: footer.minX, y: footer.minY + 26, width: footer.width * 0.6, height: 18),
                 font: .systemFont(ofSize: 12), color: mutedInk)
            let results = summaryLines(snapshot).prefix(3).map { "\($0.0): \($0.1)" }.joined(separator: "   ·   ")
            draw(results, in: CGRect(x: footer.minX, y: footer.minY + 46, width: footer.width * 0.62, height: 18),
                 font: .monospacedDigitSystemFont(ofSize: 12, weight: .semibold))
            let meta = [
                dateString(snapshot.createdAt),
                SurveyExportWriters.crsDescription,
                attribution(for: projection, background: background),
                "Auffindehilfe – keine rechtsverbindliche Grenzfeststellung"
            ].joined(separator: "\n")
            draw(meta, in: CGRect(x: footer.minX + footer.width * 0.62, y: footer.minY, width: footer.width * 0.38, height: footer.height),
                 font: .systemFont(ofSize: 10), color: mutedInk, alignment: .right)
            if snapshot.containsTestPoints {
                drawTestBanner(in: CGRect(x: planRect.midX - 150, y: 12, width: 300, height: 24))
            }
        }
        return image.pngData()
    }

    // MARK: - PDF

    private static let pageSize = CGSize(width: 595.2, height: 841.8) // A4
    private static let margin: CGFloat = 40

    @MainActor
    static func pdfReport(
        _ snapshot: SurveyExportSnapshot,
        background: MapBackgroundLayer?
    ) async -> Data {
        let contentWidth = pageSize.width - margin * 2
        let planRect = CGRect(x: margin, y: 168, width: contentWidth, height: 360)
        let projection = await makeProjection(for: snapshot, rect: planRect, background: background, scale: 3)
        var terrainProjection: SurveyPlanProjection?
        if let model = snapshot.terrain?.model, model.canInterpolate {
            let rect = CGRect(x: margin, y: 110, width: contentWidth, height: 430)
            terrainProjection = await makeProjection(for: snapshot, rect: rect, background: nil, scale: 3)
        }

        let metadata: [String: Any] = [
            kCGPDFContextCreator as String: "KRover",
            kCGPDFContextTitle as String: "Messprotokoll – \(snapshot.title)"
        ]
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = metadata
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize), format: format)
        var pageNumber = 0
        return renderer.pdfData { context in
            func beginPage() {
                context.beginPage()
                pageNumber += 1
                drawPageFrame(snapshot, page: pageNumber)
            }

            // Page 1: header, plan, results.
            beginPage()
            drawReportHeader(snapshot)
            drawPlan(snapshot, projection: projection, in: context.cgContext)
            drawOverviewInsetIfNeeded(snapshot, planRect: planRect)
            draw(
                attribution(for: projection, background: background),
                in: CGRect(x: margin, y: planRect.maxY + 3, width: contentWidth, height: 12),
                font: .systemFont(ofSize: 7), color: mutedInk, alignment: .right
            )
            drawLegend(snapshot, origin: CGPoint(x: margin, y: planRect.maxY + 18))
            drawResults(snapshot, in: CGRect(x: margin, y: planRect.maxY + 40, width: contentWidth, height: pageSize.height - planRect.maxY - 100))

            // Terrain page.
            if let terrainProjection, let terrain = snapshot.terrain, let model = terrain.model {
                beginPage()
                draw("Geländemodell", in: CGRect(x: margin, y: 56, width: contentWidth, height: 24),
                     font: .systemFont(ofSize: 17, weight: .bold))
                draw("Höhenstufen und Höhenlinien aus \(terrain.points.count) Messpunkten (lineare Dreiecksvermaschung, keine Extrapolation).",
                     in: CGRect(x: margin, y: 80, width: contentWidth, height: 26),
                     font: .systemFont(ofSize: 9.5), color: mutedInk)
                drawPlan(snapshot, projection: terrainProjection, in: context.cgContext,
                         options: PlanOptions(labelsPoints: true, showsTerrain: true))
                drawHeightRamp(model, poleLength: snapshot.poleLength,
                               in: CGRect(x: margin, y: terrainProjection.rect.maxY + 14, width: contentWidth, height: 30))
                drawTerrainStatistics(terrain, poleLength: snapshot.poleLength,
                                      in: CGRect(x: margin, y: terrainProjection.rect.maxY + 60, width: contentWidth, height: 160))
            }

            // Point table.
            let points = snapshot.allPoints
            guard !points.isEmpty else { return }
            let rowHeight: CGFloat = 13
            let tableTop: CGFloat = 92
            let tableBottom = pageSize.height - 56
            var index = 0
            while index < points.count {
                beginPage()
                draw(index == 0 ? "Punktliste" : "Punktliste (Fortsetzung)",
                     in: CGRect(x: margin, y: 56, width: contentWidth, height: 22),
                     font: .systemFont(ofSize: 17, weight: .bold))
                var y = tableTop
                drawTableRow(pointTableHeader, y: y, header: true)
                y += rowHeight + 3
                while index < points.count, y + rowHeight <= tableBottom {
                    if index % 2 == 1 {
                        UIColor(white: 0.955, alpha: 1).setFill()
                        UIRectFill(CGRect(x: margin, y: y - 1.5, width: contentWidth, height: rowHeight))
                    }
                    drawTableRow(pointTableRow(points[index]), y: y, header: false,
                                 highlight: points[index].isTest ? testColor : nil)
                    y += rowHeight
                    index += 1
                }
                draw("E/N in \(SurveyExportWriters.crsDescription). H Boden = GNSS-Antennenhöhe − Stablänge \(String(format: "%.3f", snapshot.poleLength)) m; \(SurveyExportWriters.heightDescription). σ = geschätzte Standardabweichung, bei Grenzpunkten amtliche Genauigkeitsstufe.",
                     in: CGRect(x: margin, y: tableBottom + 2, width: contentWidth, height: 24),
                     font: .systemFont(ofSize: 7), color: mutedInk)
            }
        }
    }

    private static func drawPageFrame(_ snapshot: SurveyExportSnapshot, page: Int) {
        let footerY = pageSize.height - 30
        rule.setFill()
        UIRectFill(CGRect(x: margin, y: footerY - 6, width: pageSize.width - margin * 2, height: 0.5))
        draw("KRover · Messprotokoll · \(dateString(snapshot.createdAt))",
             in: CGRect(x: margin, y: footerY, width: 300, height: 12),
             font: .systemFont(ofSize: 7.5), color: mutedInk)
        draw("Seite \(page)",
             in: CGRect(x: pageSize.width - margin - 100, y: footerY, width: 100, height: 12),
             font: .systemFont(ofSize: 7.5), color: mutedInk, alignment: .right)
    }

    private static func drawReportHeader(_ snapshot: SurveyExportSnapshot) {
        let width = pageSize.width - margin * 2
        draw("MESSPROTOKOLL", in: CGRect(x: margin, y: 38, width: width, height: 12),
             font: .systemFont(ofSize: 8.5, weight: .bold), color: measurementColor)
        draw(snapshot.title, in: CGRect(x: margin, y: 51, width: width, height: 26),
             font: .systemFont(ofSize: 20, weight: .bold))
        draw(subtitle(for: snapshot), in: CGRect(x: margin, y: 77, width: width, height: 14),
             font: .systemFont(ofSize: 10), color: mutedInk)

        var left: [(String, String)] = []
        if let parcel = snapshot.parcel {
            if !parcel.municipality.isEmpty { left.append(("Gemeinde", parcel.municipality)) }
            if !parcel.district.isEmpty { left.append(("Gemarkung", parcel.district)) }
            let flurFlst = [parcel.section.isEmpty ? nil : "Flur \(parcel.section)",
                            parcel.number.isEmpty ? nil : "Flurstück \(parcel.number)"]
                .compactMap { $0 }.joined(separator: " · ")
            if !flurFlst.isEmpty { left.append(("Flur/Flurstück", flurFlst)) }
            if let area = parcel.area { left.append(("Amtl. Fläche", String(format: "%.0f m²", area))) }
        }
        let sources = Set(snapshot.surveyedPoints.map(\.source)).sorted()
        let right: [(String, String)] = [
            ("Datum", dateString(snapshot.createdAt)),
            ("Messquelle", sources.isEmpty ? "–" : sources.joined(separator: ", ")),
            ("Lage", "ETRS89 / UTM 32N (EPSG:25832)"),
            ("Stablänge", String(format: "%.3f m", snapshot.poleLength))
        ]
        drawKeyValues(left.isEmpty ? [("Inhalt", snapshot.title)] : left,
                      in: CGRect(x: margin, y: 100, width: width / 2 - 10, height: 60))
        drawKeyValues(right, in: CGRect(x: margin + width / 2 + 10, y: 100, width: width / 2 - 10, height: 60))

        if snapshot.containsTestPoints {
            drawTestBanner(in: CGRect(x: margin + width - 230, y: 14, width: 230, height: 18))
        }
    }

    private static func drawKeyValues(_ items: [(String, String)], in rect: CGRect) {
        var y = rect.minY
        for (key, value) in items {
            draw(key, in: CGRect(x: rect.minX, y: y, width: 82, height: 13),
                 font: .systemFont(ofSize: 8.5), color: mutedInk)
            draw(value, in: CGRect(x: rect.minX + 84, y: y, width: rect.width - 84, height: 13),
                 font: .systemFont(ofSize: 8.5, weight: .medium))
            y += 14
        }
    }

    private static func drawLegend(_ snapshot: SurveyExportSnapshot, origin: CGPoint) {
        var entries: [(UIColor, String, Bool)] = []
        if snapshot.parcel != nil { entries.append((parcelColor, "Flurstücksgrenze (ALKIS)", true)) }
        if !snapshot.boundaryPoints.isEmpty { entries.append((boundaryColor, "Grenzpunkt (ALKIS)", false)) }
        if snapshot.measurement != nil { entries.append((measurementColor, "Messpunkt / Messung", false)) }
        if snapshot.containsTestPoints { entries.append((testColor, "Testpunkt (ohne RTK)", false)) }
        if snapshot.terrain?.points.isEmpty == false { entries.append((mutedInk, "Geländepunkt (nach Höhe eingefärbt)", false)) }
        var x = origin.x
        for (color, text, isLine) in entries {
            if isLine {
                color.setFill()
                UIRectFill(CGRect(x: x, y: origin.y + 4, width: 14, height: 2.5))
            } else {
                drawPoint(at: CGPoint(x: x + 7, y: origin.y + 5), fill: color, stroke: .white, radius: 3.5)
            }
            let label = NSAttributedString(string: text, attributes: [
                .font: UIFont.systemFont(ofSize: 7.5), .foregroundColor: ink
            ])
            label.draw(at: CGPoint(x: x + 18, y: origin.y))
            x += 26 + label.size().width
        }
    }

    private static func drawResults(_ snapshot: SurveyExportSnapshot, in rect: CGRect) {
        let lines = summaryLines(snapshot)
        guard !lines.isEmpty else { return }
        draw("Ergebnisse", in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 18),
             font: .systemFont(ofSize: 13, weight: .bold))
        let columns = 3
        let tileWidth = (rect.width - CGFloat(columns - 1) * 8) / CGFloat(columns)
        for (index, line) in lines.enumerated() {
            let column = index % columns
            let row = index / columns
            let tile = CGRect(
                x: rect.minX + CGFloat(column) * (tileWidth + 8),
                y: rect.minY + 22 + CGFloat(row) * 44,
                width: tileWidth,
                height: 38
            )
            guard tile.maxY <= rect.maxY else { break }
            let path = UIBezierPath(roundedRect: tile, cornerRadius: 5)
            UIColor(white: 0.96, alpha: 1).setFill()
            path.fill()
            draw(line.0, in: tile.insetBy(dx: 8, dy: 5), font: .systemFont(ofSize: 7.5), color: mutedInk)
            draw(line.1, in: CGRect(x: tile.minX + 8, y: tile.minY + 16, width: tile.width - 16, height: 18),
                 font: .monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold))
        }
        let disclaimerY = rect.minY + 22 + CGFloat((lines.count + columns - 1) / columns) * 44 + 6
        draw("Kartendarstellung und Grenzpunkte dienen als Auffindehilfe – keine rechtsverbindliche Grenzfeststellung. Messwerte sind gemittelte GNSS-Positionen mit geschätzter Genauigkeit.",
             in: CGRect(x: rect.minX, y: min(disclaimerY, rect.maxY - 22), width: rect.width, height: 22),
             font: .systemFont(ofSize: 7.5), color: mutedInk)
    }

    private static func drawHeightRamp(_ model: TerrainModel, poleLength: Double, in rect: CGRect) {
        let bar = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 10)
        let steps = 120
        for step in 0..<steps {
            let color = TerrainColorRamp.color(at: Double(step) / Double(steps - 1))
            UIColor(red: color.x, green: color.y, blue: color.z, alpha: 1).setFill()
            UIRectFill(CGRect(x: bar.minX + bar.width * CGFloat(step) / CGFloat(steps),
                              y: bar.minY, width: bar.width / CGFloat(steps) + 0.5, height: bar.height))
        }
        let font = UIFont.monospacedDigitSystemFont(ofSize: 7.5, weight: .medium)
        draw(String(format: "%.2f m", model.minHeight - poleLength),
             in: CGRect(x: rect.minX, y: bar.maxY + 3, width: 120, height: 12), font: font)
        draw(String(format: "%.2f m", model.maxHeight - poleLength),
             in: CGRect(x: rect.maxX - 120, y: bar.maxY + 3, width: 120, height: 12), font: font, alignment: .right)
        let interval = TerrainModel.contourInterval(forRange: model.heightRange)
        draw(String(format: "Höhenlinien alle %.2f m", interval),
             in: CGRect(x: rect.midX - 100, y: bar.maxY + 3, width: 200, height: 12),
             font: .systemFont(ofSize: 7.5), color: mutedInk, alignment: .center)
    }

    private static func drawTerrainStatistics(_ terrain: SurveyExportTerrain, poleLength: Double, in rect: CGRect) {
        guard let statistics = terrain.statistics else { return }
        var items: [(String, String)] = [
            ("Messpunkte", "\(statistics.pointCount)"),
            ("Tiefster Punkt (Boden)", String(format: "%.3f m", statistics.minHeight - poleLength)),
            ("Höchster Punkt (Boden)", String(format: "%.3f m", statistics.maxHeight - poleLength)),
            ("Höhenspanne", String(format: "%.3f m", statistics.heightRange))
        ]
        if let mean = statistics.meanSlopePercent { items.append(("Mittleres Gefälle", String(format: "%.1f %%", mean))) }
        if let maximum = statistics.maxSlopePercent { items.append(("Größtes Gefälle", String(format: "%.1f %%", maximum))) }
        if let bearing = statistics.downhillBearing { items.append(("Hauptgefälle Richtung", String(format: "%.0f° (%@)", bearing, compassName(bearing)))) }
        if let covered = statistics.coveredFraction { items.append(("Flächenabdeckung", String(format: "%.0f %%", covered * 100))) }
        drawKeyValues(items, in: rect)
    }

    static func compassName(_ bearing: Double) -> String {
        let names = ["N", "NO", "O", "SO", "S", "SW", "W", "NW"]
        let index = Int(((bearing.truncatingRemainder(dividingBy: 360) + 360 + 22.5) / 45)) % 8
        return names[index]
    }

    // MARK: - Point table

    private static let tableColumns: [(width: CGFloat, alignment: NSTextAlignment)] = [
        (50, .left), (58, .left), (62, .right), (68, .right), (48, .right),
        (36, .right), (36, .right), (20, .right), (137, .left)
    ]

    private static let pointTableHeader = ["Punkt", "Art", "E [m]", "N [m]", "H Boden", "σ Lage", "σ Höhe", "n", "Quelle / Bemerkung"]

    private static func pointTableRow(_ point: SurveyExportPoint) -> [String] {
        let fixed = SurveyExportWriters.optionalFixed
        var note = point.source
        if let remark = point.remark { note += " · \(remark)" }
        return [
            point.name,
            point.category.rawValue,
            SurveyExportWriters.fixed(point.utm.easting, 3),
            SurveyExportWriters.fixed(point.utm.northing, 3),
            fixed(point.groundHeight, 3),
            fixed(point.horizontalAccuracy, 3),
            fixed(point.verticalAccuracy, 3),
            point.sampleCount.map(String.init) ?? "",
            note
        ]
    }

    private static func drawTableRow(_ values: [String], y: CGFloat, header: Bool, highlight: UIColor? = nil) {
        var x = margin + 3
        let font = header
            ? UIFont.systemFont(ofSize: 7.5, weight: .bold)
            : UIFont.monospacedDigitSystemFont(ofSize: 7.3, weight: .regular)
        for (value, column) in zip(values, tableColumns) {
            draw(value, in: CGRect(x: x, y: y, width: column.width - 5, height: 11),
                 font: font, color: header ? mutedInk : (highlight ?? ink), alignment: column.alignment)
            x += column.width
        }
        if header {
            rule.setFill()
            UIRectFill(CGRect(x: margin, y: y + 12, width: pageSize.width - margin * 2, height: 0.6))
        }
    }

    // MARK: - Shared text

    static func summaryLines(_ snapshot: SurveyExportSnapshot) -> [(String, String)] {
        var lines: [(String, String)] = []
        if let measurement = snapshot.measurement {
            if let length = measurement.length {
                lines.append((measurement.kind == .elevation ? "Strecke P1 → Pn (Summe)" : "Streckenlänge", String(format: "%.3f m", length)))
            }
            if let area = measurement.area { lines.append(("Fläche (Messung)", String(format: "%.3f m²", area))) }
            if let perimeter = measurement.perimeter { lines.append(("Umfang (Messung)", String(format: "%.3f m", perimeter))) }
            if measurement.kind == .elevation {
                let relative = measurement.relativeHeights.compactMap { $0 }
                if let low = relative.min(), let high = relative.max() {
                    lines.append(("Höhenspanne ΔH", String(format: "%.3f m", high - low)))
                }
                if let last = measurement.relativeHeights.last ?? nil,
                   measurement.points.count >= 2,
                   let first = measurement.points.first, let end = measurement.points.last {
                    let distance = UTM32Projection.distance(first.utm, end.utm)
                    lines.append(("ΔH P1 → P\(measurement.points.count)", String(format: "%+.3f m", last)))
                    if distance > 0.001 {
                        lines.append(("Gefälle P1 → P\(measurement.points.count)", String(format: "%+.2f %%", last / distance * 100)))
                    }
                }
            }
            lines.append(("Messpunkte", "\(measurement.points.count)"))
        }
        if let parcel = snapshot.parcel {
            if let area = parcel.area { lines.append(("Flurstücksfläche (amtl.)", String(format: "%.0f m²", area))) }
            lines.append(("Flurstücksumfang", String(format: "%.2f m", parcel.perimeter)))
        }
        if !snapshot.boundaryPoints.isEmpty {
            lines.append(("Grenzpunkte (ALKIS)", "\(snapshot.boundaryPoints.count)"))
        }
        if let terrain = snapshot.terrain, !terrain.points.isEmpty {
            lines.append(("Geländepunkte", "\(terrain.points.count)"))
            if let model = terrain.model, terrain.points.count >= 2 {
                lines.append(("Geländehöhenspanne", String(format: "%.3f m", model.heightRange)))
            }
        }
        return lines
    }

    private static func subtitle(for snapshot: SurveyExportSnapshot) -> String {
        var parts: [String] = []
        if let parcel = snapshot.parcel { parts.append(parcel.cadastralDesignation) }
        if let measurement = snapshot.measurement { parts.append(measurement.kind.title) }
        if let terrain = snapshot.terrain, !terrain.points.isEmpty { parts.append("Geländeaufnahme") }
        return parts.joined(separator: " · ")
    }

    private static func attribution(for projection: SurveyPlanProjection, background: MapBackgroundLayer?) -> String {
        guard projection.backgroundImage != nil, let background else {
            return "Plan ohne Kartenhintergrund (Gitternord oben)"
        }
        switch background {
        case .cadastre: return "Hintergrund: © Geobasis NRW, Liegenschaftskarte (dl-de/zero-2-0)"
        case .aerialDOP: return "Hintergrund: © Geobasis NRW, Digitales Orthophoto (dl-de/zero-2-0)"
        }
    }

    private static func drawTestBanner(in rect: CGRect) {
        let path = UIBezierPath(roundedRect: rect, cornerRadius: rect.height / 2)
        testColor.setFill()
        path.fill()
        draw("TESTPUNKTE – ohne RTK-Messung", in: rect.insetBy(dx: 8, dy: (rect.height - 12) / 2),
             font: .systemFont(ofSize: 8.5, weight: .bold), color: .white, alignment: .center)
    }

    static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "dd.MM.yyyy, HH:mm 'Uhr'"
        return formatter.string(from: date)
    }

    private static func draw(
        _ text: String,
        in rect: CGRect,
        font: UIFont,
        color: UIColor = ink,
        alignment: NSTextAlignment = .left
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping
        NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }
}
