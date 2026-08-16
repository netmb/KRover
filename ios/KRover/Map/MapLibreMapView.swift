import Combine
import MapLibre
import SwiftUI
import UIKit

enum MapOrnamentLayout {
    case phone
    case pad
}

struct MapLibreMapView: UIViewRepresentable {
    @ObservedObject var model: AppModel
    let ornamentLayout: MapOrnamentLayout

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> MLNMapView {
        let styleURL = URL(string: "https://ogc-api.nrw.de/lika/v1/styles/lika-farbe-web?f=mbs")!
        let map = MLNMapView(frame: .zero, styleURL: styleURL)
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.compassView.compassVisibility = .visible
        map.logoView.isHidden = false
        map.attributionButton.isHidden = false
        map.maximumZoomLevel = NRWMapLayerCatalog.precisionMaximumZoomLevel
        configureOrnaments(on: map)
        map.setCenter(model.mapCenter, zoomLevel: 18, animated: false)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.numberOfTapsRequired = 1
        map.addGestureRecognizer(tap)
        let precisionPlacement = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePrecisionPlacement(_:))
        )
        precisionPlacement.minimumPressDuration = 0.12
        precisionPlacement.allowableMovement = 44
        precisionPlacement.numberOfTouchesRequired = 1
        precisionPlacement.delegate = context.coordinator
        map.addGestureRecognizer(precisionPlacement)
        tap.require(toFail: precisionPlacement)
        for recognizer in map.gestureRecognizers ?? []
        where recognizer !== precisionPlacement && recognizer is UIPanGestureRecognizer {
            recognizer.require(toFail: precisionPlacement)
        }
        context.coordinator.precisionPlacementRecognizer = precisionPlacement
        context.coordinator.updatePrecisionPlacementAvailability()
        context.coordinator.mapView = map
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        context.coordinator.model = model
        configureOrnaments(on: map)
        map.showsUserLocation = model.recentRoverPosition == nil
        if let interfaceOrientation = map.window?.windowScene?.interfaceOrientation {
            model.phoneLocation.setHeadingOrientation(interfaceOrientation.headingOrientation)
        }
        if context.coordinator.cameraRevision != model.mapCameraRevision {
            context.coordinator.cameraRevision = model.mapCameraRevision
            map.setCenter(model.mapCenter, zoomLevel: max(map.zoomLevel, 18), animated: true)
        }
        if context.coordinator.zoomRevision != model.mapZoomRevision {
            context.coordinator.zoomRevision = model.mapZoomRevision
            let zoom = min(max(map.zoomLevel + model.mapZoomDelta, map.minimumZoomLevel), map.maximumZoomLevel)
            map.setZoomLevel(zoom, animated: true)
        }
        context.coordinator.updateMapBackground(on: map)
        context.coordinator.updatePrecisionPlacementAvailability()
        context.coordinator.updateNavigationCamera(on: map)
        context.coordinator.render(on: map)
    }

    private func configureOrnaments(on map: MLNMapView) {
        switch ornamentLayout {
        case .phone:
            map.attributionButtonPosition = .topLeft
            let topMargin: CGFloat = map.bounds.width > map.bounds.height ? 54 : 108
            map.attributionButtonMargins = CGPoint(x: 8, y: topMargin)
        case .pad:
            map.attributionButtonPosition = .bottomRight
            map.attributionButtonMargins = CGPoint(x: 8, y: 8)
        }
    }

    final class Coordinator: NSObject, MLNMapViewDelegate, UIGestureRecognizerDelegate {
        private struct BoundaryRenderValue: Equatable {
            let id: String
            let latitude: Double
            let longitude: Double
            let boundaryEasting: Double
            let boundaryNorthing: Double
            let markStatus: BoundaryMarkStatus
            let isIndirect: Bool

            init(_ point: CadastralBoundaryPoint) {
                id = point.id
                latitude = point.coordinate.latitude
                longitude = point.coordinate.longitude
                boundaryEasting = point.boundaryUTM.easting
                boundaryNorthing = point.boundaryUTM.northing
                markStatus = point.markStatus
                isIndirect = point.isIndirect
            }
        }

        var model: AppModel
        weak var mapView: MLNMapView?
        weak var precisionPlacementRecognizer: UILongPressGestureRecognizer?
        var cameraRevision = -1
        var zoomRevision = -1
        private var renderedParcelID: String?
        private var renderedBoundaryPoints: [BoundaryRenderValue] = []
        private var renderedBackgroundLayer: MapBackgroundLayer?
        private var ownedAnnotations: [MLNAnnotation] = []
        private var selectedAreaEdgeAnnotation: MLNPolyline?
        private var isDraggingMeasurementPoint = false
        private var isPlacingMeasurementPoint = false
        private var precisionDraggedPointIndex: Int?
        private var placementMagnifier: DragMagnifierView?
        private var placementStem: UIView?
        private var wasNavigating = false
        private var styleIsReady = false
        private var originalBaseLayerVisibility: [String: Bool] = [:]
        private weak var roverPositionView: RoverPositionAnnotationView?
        private var imuCancellable: AnyCancellable?

        init(model: AppModel) {
            self.model = model
            super.init()
            imuCancellable = model.ble.$imuState
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    self?.roverPositionView?.update(imuState: state)
                }
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let map = mapView else { return }
            let coordinate = map.convert(recognizer.location(in: map), toCoordinateFrom: map)
            model.handleMapTap(coordinate)
        }

        @objc func handlePrecisionPlacement(_ recognizer: UILongPressGestureRecognizer) {
            guard let map = mapView else { return }
            let fingerPoint = recognizer.location(in: map)
            switch recognizer.state {
            case .began:
                let draggedPointIndex = editableMeasurementPointIndex(
                    near: fingerPoint,
                    on: map
                )
                beginPrecisionInteraction(
                    at: fingerPoint,
                    on: map,
                    draggedPointIndex: draggedPointIndex
                )
            case .changed:
                updatePrecisionInteraction(at: fingerPoint)
            case .ended:
                let coordinate = precisionCoordinate(for: fingerPoint, on: map)
                let draggedPointIndex = precisionDraggedPointIndex
                endPrecisionInteraction()
                if let draggedPointIndex {
                    model.moveMeasurementPoint(at: draggedPointIndex, to: coordinate)
                } else {
                    model.handleMapTap(coordinate)
                }
            case .cancelled, .failed:
                endPrecisionInteraction()
                render(on: map)
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === precisionPlacementRecognizer else { return true }
            guard let map = mapView else { return false }
            let point = gestureRecognizer.location(in: map)
            return editableMeasurementPointIndex(near: point, on: map) != nil
                || allowsPrecisionPointPlacement
        }

        func updatePrecisionPlacementAvailability() {
            let shouldBeEnabled = allowsPrecisionPointPlacement || allowsMeasurementPointDragging
            if precisionPlacementRecognizer?.isEnabled != shouldBeEnabled {
                precisionPlacementRecognizer?.isEnabled = shouldBeEnabled
            }
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            originalBaseLayerVisibility = Dictionary(
                uniqueKeysWithValues: style.layers.map { ($0.identifier, $0.isVisible) }
            )
            styleIsReady = true
            renderedBackgroundLayer = nil
            updateMapBackground(on: mapView)
            render(on: mapView)
        }

        func updateMapBackground(on map: MLNMapView) {
            guard styleIsReady, let style = map.style,
                  renderedBackgroundLayer != model.mapBackgroundLayer else { return }
            renderedBackgroundLayer = model.mapBackgroundLayer
            for (identifier, wasVisible) in originalBaseLayerVisibility {
                style.layer(withIdentifier: identifier)?.isVisible =
                    model.mapBackgroundLayer == .cadastre && wasVisible
            }
            switch model.mapBackgroundLayer {
            case .cadastre:
                if let layer = style.layer(withIdentifier: NRWMapLayerCatalog.dopLayerIdentifier) {
                    style.removeLayer(layer)
                }

            case .aerialDOP:
                let source: MLNRasterTileSource
                if let existing = style.source(
                    withIdentifier: NRWMapLayerCatalog.dopSourceIdentifier
                ) as? MLNRasterTileSource {
                    source = existing
                } else {
                    source = MLNRasterTileSource(
                        identifier: NRWMapLayerCatalog.dopSourceIdentifier,
                        tileURLTemplates: [NRWMapLayerCatalog.dopRGBTileTemplate],
                        options: [
                            .minimumZoomLevel: 5,
                            .maximumZoomLevel: NRWMapLayerCatalog.dopNativeMaximumZoomLevel,
                            .tileSize: 256,
                            .attributionHTMLString:
                                NRWMapLayerCatalog.geobasisAttributionHTML
                        ]
                    )
                    style.addSource(source)
                }
                guard style.layer(
                    withIdentifier: NRWMapLayerCatalog.dopLayerIdentifier
                ) == nil else { return }
                let layer = MLNRasterStyleLayer(
                    identifier: NRWMapLayerCatalog.dopLayerIdentifier,
                    source: source
                )
                layer.rasterOpacity = NSExpression(forConstantValue: 1.0)
                if let selectedParcel = style.layer(withIdentifier: "selected-parcel-fill") {
                    style.insertLayer(layer, below: selectedParcel)
                } else {
                    style.addLayer(layer)
                }
            }
        }

        func render(on map: MLNMapView) {
            guard !isDraggingMeasurementPoint, !isPlacingMeasurementPoint else { return }
            renderParcel(on: map)
            renderMeasurementShape(on: map)
            renderNavigationRoute(on: map)
            if !ownedAnnotations.isEmpty { map.removeAnnotations(ownedAnnotations) }
            ownedAnnotations.removeAll()
            roverPositionView = nil
            selectedAreaEdgeAnnotation = nil

            if let roverPosition = model.recentRoverPosition {
                let annotation = RoverPositionAnnotation()
                annotation.coordinate = roverPosition.coordinate
                annotation.fixQuality = roverPosition.fixQuality
                annotation.satellites = roverPosition.satellites
                annotation.title = "Rover · \(roverPosition.fixQuality.rawValue)"
                ownedAnnotations.append(annotation)
            }
            if let target = model.targetCoordinate {
                let annotation = NavigationTargetAnnotation()
                annotation.coordinate = target
                annotation.title = "Zielpunkt"
                ownedAnnotations.append(annotation)
            }
            if model.interactionMode == .distance ||
                model.interactionMode == .area ||
                model.interactionMode == .elevation {
                for (index, coordinate) in model.measurementPoints.enumerated() {
                    let annotation = MeasurementPointAnnotation()
                    annotation.coordinate = coordinate
                    annotation.pointIndex = index + 1
                    if model.interactionMode == .elevation,
                       let relativeHeight = model.elevationRelativeToReference(at: index) {
                        annotation.title = String(
                            format: "P%d · %+.3f m zur Referenz",
                            index + 1,
                            relativeHeight
                        )
                    } else if model.areaPointMeasurements.indices.contains(index),
                       let measurement = model.areaPointMeasurements[index] {
                        annotation.title = String(
                            format: "P%d · ±%.3f m · %d Werte",
                            index + 1,
                            measurement.estimatedHorizontalAccuracy,
                            measurement.sampleCount
                        )
                    } else {
                        annotation.title = "P\(index + 1) · manueller Testpunkt"
                    }
                    ownedAnnotations.append(annotation)
                }
            }
            if model.interactionMode == .area {
                if var selectedEdge = model.selectedAreaEdgeCoordinates {
                    let annotation = MLNPolyline(
                        coordinates: &selectedEdge,
                        count: UInt(selectedEdge.count)
                    )
                    selectedAreaEdgeAnnotation = annotation
                    ownedAnnotations.append(annotation)
                }
                if let control = model.areaControlMeasurement {
                    let annotation = MLNPointAnnotation()
                    annotation.coordinate = control.coordinate
                    annotation.title = String(format: "Kontrollpunkt · %.3f m", control.distanceToEdge)
                    ownedAnnotations.append(annotation)
                }
            }
            if !ownedAnnotations.isEmpty { map.addAnnotations(ownedAnnotations) }
        }

        func mapView(
            _ mapView: MLNMapView,
            viewFor annotation: MLNAnnotation
        ) -> MLNAnnotationView? {
            if let rover = annotation as? RoverPositionAnnotation {
                let reuseIdentifier = RoverPositionAnnotationView.reuseIdentifier
                let view = (mapView.dequeueReusableAnnotationView(
                    withIdentifier: reuseIdentifier
                ) as? RoverPositionAnnotationView)
                    ?? RoverPositionAnnotationView(reuseIdentifier: reuseIdentifier)
                view.configure(
                    fixQuality: rover.fixQuality,
                    satellites: rover.satellites,
                    imuState: model.ble.imuState
                )
                roverPositionView = view
                return view
            }
            if annotation is NavigationTargetAnnotation {
                let reuseIdentifier = NavigationTargetAnnotationView.reuseIdentifier
                return mapView.dequeueReusableAnnotationView(withIdentifier: reuseIdentifier)
                    ?? NavigationTargetAnnotationView(reuseIdentifier: reuseIdentifier)
            }
            guard let measurementPoint = annotation as? MeasurementPointAnnotation else {
                return nil
            }
            let reuseIdentifier = MeasurementPointAnnotationView.reuseIdentifier
            let view = (mapView.dequeueReusableAnnotationView(
                withIdentifier: reuseIdentifier
            ) as? MeasurementPointAnnotationView)
                ?? MeasurementPointAnnotationView(reuseIdentifier: reuseIdentifier)
            view.configure(
                pointIndex: measurementPoint.pointIndex,
                isEditable: model.interactionMode != .elevation
            )
            return view
        }

        private var allowsPrecisionPointPlacement: Bool {
            switch model.interactionMode {
            case .distance:
                return true
            case .area:
                return model.areaCaptureMode == .append
            case .inspect, .target, .elevation:
                return false
            }
        }

        private var allowsMeasurementPointDragging: Bool {
            !model.measurementPoints.isEmpty
                && (model.interactionMode == .distance || model.interactionMode == .area)
        }

        private func editableMeasurementPointIndex(
            near fingerPoint: CGPoint,
            on map: MLNMapView
        ) -> Int? {
            guard allowsMeasurementPointDragging else { return nil }

            let pointLocations = model.measurementPoints.map {
                map.convert($0, toPointTo: map)
            }
            return Self.nearestMeasurementPointIndex(
                to: fingerPoint,
                among: pointLocations
            )
        }

        static func nearestMeasurementPointIndex(
            to fingerPoint: CGPoint,
            among pointLocations: [CGPoint],
            hitRadius: CGFloat = 36
        ) -> Int? {
            pointLocations.enumerated()
                .map { index, point in
                    let distance = hypot(
                        point.x - fingerPoint.x,
                        point.y - fingerPoint.y
                    )
                    return (index: index, distance: distance)
                }
                .filter { $0.distance <= hitRadius }
                .min { $0.distance < $1.distance }?
                .index
        }

        private func beginPrecisionInteraction(
            at fingerPoint: CGPoint,
            on map: MLNMapView,
            draggedPointIndex: Int?
        ) {
            precisionDraggedPointIndex = draggedPointIndex
            isDraggingMeasurementPoint = draggedPointIndex != nil
            isPlacingMeasurementPoint = draggedPointIndex == nil

            let magnifier = DragMagnifierView(
                frame: CGRect(x: 0, y: 0, width: 86, height: 86)
            )
            magnifier.capture(from: map)
            map.addSubview(magnifier)
            placementMagnifier = magnifier

            let stem = UIView()
            stem.backgroundColor = UIColor.systemTeal.withAlphaComponent(0.9)
            stem.layer.cornerRadius = 1
            map.addSubview(stem)
            placementStem = stem

            updatePrecisionInteraction(at: fingerPoint)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }

        private func updatePrecisionInteraction(at fingerPoint: CGPoint) {
            let previewPoint = CGPoint(
                x: fingerPoint.x,
                y: fingerPoint.y - MeasurementPointAnnotationView.dragPreviewOffset
            )
            placementMagnifier?.center = previewPoint
            placementMagnifier?.showSourcePoint(previewPoint)

            let stemTop = previewPoint.y + 43
            let stemBottom = fingerPoint.y - 10
            placementStem?.frame = CGRect(
                x: fingerPoint.x - 1,
                y: stemTop,
                width: 2,
                height: max(0, stemBottom - stemTop)
            )
        }

        private func precisionCoordinate(
            for fingerPoint: CGPoint,
            on map: MLNMapView
        ) -> CLLocationCoordinate2D {
            let previewPoint = CGPoint(
                x: fingerPoint.x,
                y: fingerPoint.y - MeasurementPointAnnotationView.dragPreviewOffset
            )
            return map.convert(previewPoint, toCoordinateFrom: map)
        }

        private func endPrecisionInteraction() {
            isDraggingMeasurementPoint = false
            isPlacingMeasurementPoint = false
            precisionDraggedPointIndex = nil
            placementMagnifier?.clearSnapshot()
            placementMagnifier?.removeFromSuperview()
            placementStem?.removeFromSuperview()
            placementMagnifier = nil
            placementStem = nil
        }

        func mapView(_ mapView: MLNMapView, strokeColorForShapeAnnotation annotation: MLNShape) -> UIColor {
            if annotation === selectedAreaEdgeAnnotation { return .systemOrange }
            return .systemBlue
        }

        func mapView(_ mapView: MLNMapView, fillColorForPolygonAnnotation annotation: MLNPolygon) -> UIColor {
            UIColor.systemBlue.withAlphaComponent(0.15)
        }

        func mapView(_ mapView: MLNMapView, lineWidthForPolylineAnnotation annotation: MLNPolyline) -> CGFloat {
            annotation === selectedAreaEdgeAnnotation ? 6 : 3
        }

        func updateNavigationCamera(on map: MLNMapView) {
            guard let active = model.activeCoordinate,
                  let target = model.targetCoordinate,
                  let heading = model.deviceHeading else {
                if wasNavigating {
                    wasNavigating = false
                    map.isRotateEnabled = true
                    map.setDirection(0, animated: true)
                }
                return
            }

            wasNavigating = true
            map.isRotateEnabled = false
            var coordinates = [active, target]
            let topInset = max(145, map.safeAreaInsets.top + 120)
            let bottomInset = max(175, map.safeAreaInsets.bottom + 145)
            map.setVisibleCoordinates(
                &coordinates,
                count: UInt(coordinates.count),
                edgePadding: UIEdgeInsets(top: topInset, left: 45, bottom: bottomInset, right: 45),
                direction: heading,
                duration: 0.25,
                animationTimingFunction: nil,
                completionHandler: nil
            )
        }

        private func renderParcel(on map: MLNMapView) {
            guard let style = map.style else { return }
            let sourceID = "selected-parcel-source"
            let fillID = "selected-parcel-fill"
            let lineID = "selected-parcel-line"
            let verticesSourceID = "selected-parcel-vertices-source"
            let verticesLayerID = "selected-parcel-vertices-layer"
            let parcelID = model.selectedParcel?.id
            let parcelNeedsUpdate = renderedParcelID != parcelID
                || style.source(withIdentifier: sourceID) == nil
                || style.source(withIdentifier: verticesSourceID) == nil
            if parcelNeedsUpdate {
                let shape: MLNShape?
                let verticesShape: MLNShape?
                if let parcel = model.selectedParcel {
                    shape = try? MLNShape(data: parcel.geoJSON, encoding: String.Encoding.utf8.rawValue)
                    verticesShape = Self.vertexShape(for: parcel)
                } else {
                    shape = nil
                    verticesShape = nil
                }

                if let source = style.source(withIdentifier: sourceID) as? MLNShapeSource {
                    source.shape = shape
                } else {
                    let source = MLNShapeSource(identifier: sourceID, shape: shape, options: nil)
                    style.addSource(source)
                    let fill = MLNFillStyleLayer(identifier: fillID, source: source)
                    fill.fillColor = NSExpression(forConstantValue: UIColor.systemYellow.withAlphaComponent(0.28))
                    fill.fillOutlineColor = NSExpression(forConstantValue: UIColor.systemYellow)
                    style.addLayer(fill)
                    let line = MLNLineStyleLayer(identifier: lineID, source: source)
                    line.lineColor = NSExpression(forConstantValue: UIColor.systemYellow)
                    line.lineWidth = NSExpression(forConstantValue: 3.0)
                    style.addLayer(line)
                }
                if let source = style.source(withIdentifier: verticesSourceID) as? MLNShapeSource {
                    source.shape = verticesShape
                } else {
                    let source = MLNShapeSource(identifier: verticesSourceID, shape: verticesShape, options: nil)
                    style.addSource(source)
                    let circles = MLNCircleStyleLayer(identifier: verticesLayerID, source: source)
                    circles.circleColor = NSExpression(
                        forConstantValue: UIColor.white.withAlphaComponent(0.72)
                    )
                    circles.circleRadius = NSExpression(forConstantValue: 3.5)
                    circles.circleStrokeColor = NSExpression(forConstantValue: UIColor.systemYellow)
                    circles.circleStrokeWidth = NSExpression(forConstantValue: 1.5)
                    style.addLayer(circles)
                }
                renderedParcelID = parcelID
            }

            let boundarySourceIDs = [
                "alkis-indirect-markers-source",
                "alkis-marked-boundary-points-source",
                "alkis-unmarked-boundary-points-source"
            ]
            let boundaryRenderValues = model.cadastralBoundaryPoints.map(BoundaryRenderValue.init)
            let boundaryNeedsUpdate = renderedBoundaryPoints != boundaryRenderValues
                || boundarySourceIDs.contains { style.source(withIdentifier: $0) == nil }
            if boundaryNeedsUpdate {
                let marked = model.cadastralBoundaryPoints.filter { $0.markStatus == .marked }
                let notMarked = model.cadastralBoundaryPoints.filter { $0.markStatus != .marked }
                renderIndirectMarkerConnections(on: style)
                renderBoundaryPointLayer(
                    on: style,
                    sourceID: "alkis-marked-boundary-points-source",
                    layerID: "alkis-marked-boundary-points-layer",
                    shape: Self.boundaryPointShape(for: marked),
                    color: .systemGreen,
                    strokeColor: .white,
                    radius: 7
                )
                renderBoundaryPointLayer(
                    on: style,
                    sourceID: "alkis-unmarked-boundary-points-source",
                    layerID: "alkis-unmarked-boundary-points-layer",
                    shape: Self.boundaryPointShape(for: notMarked),
                    color: UIColor.systemOrange.withAlphaComponent(0.20),
                    strokeColor: .systemOrange,
                    radius: 6
                )
                renderedBoundaryPoints = boundaryRenderValues
            }
        }

        private func renderBoundaryPointLayer(
            on style: MLNStyle,
            sourceID: String,
            layerID: String,
            shape: MLNShape?,
            color: UIColor,
            strokeColor: UIColor,
            radius: Double
        ) {
            let source: MLNShapeSource
            if let existing = style.source(withIdentifier: sourceID) as? MLNShapeSource {
                source = existing
                source.shape = shape
            } else {
                source = MLNShapeSource(identifier: sourceID, shape: shape, options: nil)
                style.addSource(source)
            }
            guard style.layer(withIdentifier: layerID) == nil else { return }
            let circles = MLNCircleStyleLayer(identifier: layerID, source: source)
            circles.circleColor = NSExpression(forConstantValue: color)
            circles.circleRadius = NSExpression(forConstantValue: radius)
            circles.circleStrokeColor = NSExpression(forConstantValue: strokeColor)
            circles.circleStrokeWidth = NSExpression(forConstantValue: 2.5)
            style.addLayer(circles)
        }

        private func renderIndirectMarkerConnections(on style: MLNStyle) {
            let sourceID = "alkis-indirect-markers-source"
            let layerID = "alkis-indirect-markers-layer"
            let indirect = model.cadastralBoundaryPoints.filter(\.isIndirect)
            let shape = Self.indirectMarkerShape(for: indirect)
            let source: MLNShapeSource
            if let existing = style.source(withIdentifier: sourceID) as? MLNShapeSource {
                source = existing
                source.shape = shape
            } else {
                source = MLNShapeSource(identifier: sourceID, shape: shape, options: nil)
                style.addSource(source)
            }
            guard style.layer(withIdentifier: layerID) == nil else { return }
            let line = MLNLineStyleLayer(identifier: layerID, source: source)
            line.lineColor = NSExpression(forConstantValue: UIColor.systemOrange)
            line.lineWidth = NSExpression(forConstantValue: 2.0)
            line.lineDashPattern = NSExpression(forConstantValue: [2, 2])
            style.addLayer(line)
        }

        private func renderMeasurementShape(on map: MLNMapView) {
            guard let style = map.style else { return }
            let sourceID = "measurement-shape-source"
            let fillID = "measurement-shape-fill"
            let casingID = "measurement-shape-casing"
            let lineID = "measurement-shape-line"
            let shape: MLNShape?

            if model.measurementPoints.count >= 2 {
                var coordinates = model.measurementPoints
                if model.interactionMode == .area, coordinates.count >= 3 {
                    shape = MLNPolygon(coordinates: &coordinates, count: UInt(coordinates.count))
                } else {
                    shape = MLNPolyline(coordinates: &coordinates, count: UInt(coordinates.count))
                }
            } else {
                shape = nil
            }

            if let source = style.source(withIdentifier: sourceID) as? MLNShapeSource {
                source.shape = shape
                return
            }

            let source = MLNShapeSource(identifier: sourceID, shape: shape, options: nil)
            style.addSource(source)

            let fill = MLNFillStyleLayer(identifier: fillID, source: source)
            fill.fillColor = NSExpression(forConstantValue: UIColor.systemTeal)
            fill.fillOpacity = NSExpression(forConstantValue: 0.18)
            style.addLayer(fill)

            let casing = MLNLineStyleLayer(identifier: casingID, source: source)
            casing.lineColor = NSExpression(forConstantValue: UIColor.white.withAlphaComponent(0.9))
            casing.lineWidth = NSExpression(forConstantValue: 6.0)
            style.addLayer(casing)

            let line = MLNLineStyleLayer(identifier: lineID, source: source)
            line.lineColor = NSExpression(forConstantValue: UIColor.systemTeal)
            line.lineWidth = NSExpression(forConstantValue: 3.0)
            style.addLayer(line)
        }

        private func renderNavigationRoute(on map: MLNMapView) {
            guard let style = map.style else { return }
            let sourceID = "navigation-route-source"
            let casingID = "navigation-route-casing"
            let lineID = "navigation-route-line"
            let shape: MLNShape?

            if let active = model.activeCoordinate, let target = model.targetCoordinate {
                var coordinates = [active, target]
                shape = MLNPolyline(coordinates: &coordinates, count: UInt(coordinates.count))
            } else {
                shape = nil
            }

            if let source = style.source(withIdentifier: sourceID) as? MLNShapeSource {
                source.shape = shape
                return
            }

            let source = MLNShapeSource(identifier: sourceID, shape: shape, options: nil)
            style.addSource(source)

            let casing = MLNLineStyleLayer(identifier: casingID, source: source)
            casing.lineColor = NSExpression(forConstantValue: UIColor.white.withAlphaComponent(0.95))
            casing.lineWidth = NSExpression(forConstantValue: 8.0)
            casing.lineCap = NSExpression(forConstantValue: "round")
            casing.lineJoin = NSExpression(forConstantValue: "round")
            style.addLayer(casing)

            let line = MLNLineStyleLayer(identifier: lineID, source: source)
            line.lineColor = NSExpression(forConstantValue: UIColor.systemBlue)
            line.lineWidth = NSExpression(forConstantValue: 4.0)
            line.lineCap = NSExpression(forConstantValue: "round")
            line.lineJoin = NSExpression(forConstantValue: "round")
            style.addLayer(line)
        }

        private static func vertexShape(for parcel: ParcelInfo) -> MLNShape? {
            let features: [[String: Any]] = parcel.boundaryRings.flatMap { ring in
                ring.wgs84.map { coordinate in
                    [
                        "type": "Feature",
                        "properties": [:],
                        "geometry": [
                            "type": "Point",
                            "coordinates": [coordinate.longitude, coordinate.latitude]
                        ]
                    ]
                }
            }
            let collection: [String: Any] = ["type": "FeatureCollection", "features": features]
            guard let data = try? JSONSerialization.data(withJSONObject: collection) else { return nil }
            return try? MLNShape(data: data, encoding: String.Encoding.utf8.rawValue)
        }

        private static func boundaryPointShape(for points: [CadastralBoundaryPoint]) -> MLNShape? {
            let features: [[String: Any]] = points.map { point in
                [
                    "type": "Feature",
                    "properties": ["id": point.id, "mark": point.markCode],
                    "geometry": [
                        "type": "Point",
                        "coordinates": [point.coordinate.longitude, point.coordinate.latitude]
                    ]
                ]
            }
            let collection: [String: Any] = ["type": "FeatureCollection", "features": features]
            guard let data = try? JSONSerialization.data(withJSONObject: collection) else { return nil }
            return try? MLNShape(data: data, encoding: String.Encoding.utf8.rawValue)
        }

        private static func indirectMarkerShape(for points: [CadastralBoundaryPoint]) -> MLNShape? {
            let features: [[String: Any]] = points.map { point in
                let boundary = UTM32Projection.unproject(point.boundaryUTM)
                return [
                    "type": "Feature",
                    "properties": ["id": point.id],
                    "geometry": [
                        "type": "LineString",
                        "coordinates": [
                            [boundary.longitude, boundary.latitude],
                            [point.coordinate.longitude, point.coordinate.latitude]
                        ]
                    ]
                ]
            }
            let collection: [String: Any] = ["type": "FeatureCollection", "features": features]
            guard let data = try? JSONSerialization.data(withJSONObject: collection) else { return nil }
            return try? MLNShape(data: data, encoding: String.Encoding.utf8.rawValue)
        }
    }
}

private final class RoverPositionAnnotation: MLNPointAnnotation {
    var fixQuality: FixQuality = .none
    var satellites = 0
}

private final class NavigationTargetAnnotation: MLNPointAnnotation {}

private final class NavigationTargetAnnotationView: MLNAnnotationView {
    static let reuseIdentifier = "navigation-target"

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 48, height: 48)
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityLabel = "Gewählter Zielpunkt"

        let diamondPath = UIBezierPath()
        diamondPath.move(to: CGPoint(x: 24, y: 4.2))
        diamondPath.addLine(to: CGPoint(x: 43.8, y: 24))
        diamondPath.addLine(to: CGPoint(x: 24, y: 43.8))
        diamondPath.addLine(to: CGPoint(x: 4.2, y: 24))
        diamondPath.close()

        for (color, width) in [
            (UIColor.black.withAlphaComponent(0.5), CGFloat(7.6)),
            (UIColor.white, CGFloat(5.4)),
            (UIColor.systemBlue, CGFloat(2.8))
        ] {
            let layer = CAShapeLayer()
            layer.frame = bounds
            layer.path = diamondPath.cgPath
            layer.fillColor = UIColor.clear.cgColor
            layer.strokeColor = color.cgColor
            layer.lineWidth = width
            layer.lineJoin = .round
            self.layer.addSublayer(layer)
        }

        let centerDot = CAShapeLayer()
        centerDot.frame = bounds
        centerDot.path = UIBezierPath(
            ovalIn: CGRect(x: 21, y: 21, width: 6, height: 6)
        ).cgPath
        centerDot.fillColor = UIColor.white.cgColor
        centerDot.strokeColor = UIColor.black.withAlphaComponent(0.45).cgColor
        centerDot.lineWidth = 1.5
        self.layer.addSublayer(centerDot)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class RoverPositionAnnotationView: MLNAnnotationView {
    static let reuseIdentifier = "rover-position"

    private let ring = UIView()
    private let fixedCenter = UIView()
    private let centerDot = UIView()
    private let tiltBubble = UIView()
    private let toleranceLayer = CAShapeLayer()
    private let crosshairOutlineLayer = CAShapeLayer()
    private let crosshairLayer = CAShapeLayer()
    private let centerOutlineLayer = CAShapeLayer()
    private let centerRingLayer = CAShapeLayer()
    private var fixQuality: FixQuality = .none
    private var satellites = 0

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 72, height: 72)
        backgroundColor = .clear
        isAccessibilityElement = true

        ring.frame = CGRect(x: 2, y: 2, width: 68, height: 68)
        ring.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.10)
        ring.layer.cornerRadius = 34
        ring.layer.borderWidth = 1
        ring.layer.shadowColor = UIColor.black.cgColor
        ring.layer.shadowOpacity = 0.55
        ring.layer.shadowRadius = 3
        ring.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(ring)

        fixedCenter.frame = CGRect(x: 20, y: 20, width: 32, height: 32)
        fixedCenter.backgroundColor = .clear
        fixedCenter.layer.cornerRadius = 16
        addSubview(fixedCenter)

        toleranceLayer.frame = fixedCenter.bounds
        toleranceLayer.path = UIBezierPath(ovalIn: fixedCenter.bounds.insetBy(dx: 1, dy: 1)).cgPath
        toleranceLayer.fillColor = UIColor.clear.cgColor
        toleranceLayer.strokeColor = UIColor.white.withAlphaComponent(0.32).cgColor
        toleranceLayer.lineWidth = 1
        toleranceLayer.lineDashPattern = [2, 3]
        fixedCenter.layer.addSublayer(toleranceLayer)

        let crosshairPath = UIBezierPath()
        crosshairPath.move(to: CGPoint(x: 12, y: 36))
        crosshairPath.addLine(to: CGPoint(x: 27, y: 36))
        crosshairPath.move(to: CGPoint(x: 45, y: 36))
        crosshairPath.addLine(to: CGPoint(x: 60, y: 36))
        crosshairPath.move(to: CGPoint(x: 36, y: 12))
        crosshairPath.addLine(to: CGPoint(x: 36, y: 27))
        crosshairPath.move(to: CGPoint(x: 36, y: 45))
        crosshairPath.addLine(to: CGPoint(x: 36, y: 60))

        crosshairOutlineLayer.frame = bounds
        crosshairOutlineLayer.path = crosshairPath.cgPath
        crosshairOutlineLayer.fillColor = UIColor.clear.cgColor
        crosshairOutlineLayer.strokeColor = UIColor.black.withAlphaComponent(0.55).cgColor
        crosshairOutlineLayer.lineWidth = 5.4
        crosshairOutlineLayer.lineCap = .round
        layer.addSublayer(crosshairOutlineLayer)

        crosshairLayer.frame = bounds
        crosshairLayer.path = crosshairPath.cgPath
        crosshairLayer.fillColor = UIColor.clear.cgColor
        crosshairLayer.strokeColor = UIColor.white.cgColor
        crosshairLayer.lineWidth = 2.6
        crosshairLayer.lineCap = .round
        layer.addSublayer(crosshairLayer)

        let centerPath = UIBezierPath(ovalIn: CGRect(x: 31.4, y: 31.4, width: 9.2, height: 9.2))
        centerOutlineLayer.frame = bounds
        centerOutlineLayer.path = centerPath.cgPath
        centerOutlineLayer.fillColor = UIColor.clear.cgColor
        centerOutlineLayer.strokeColor = UIColor.black.withAlphaComponent(0.55).cgColor
        centerOutlineLayer.lineWidth = 3.6
        layer.addSublayer(centerOutlineLayer)

        centerRingLayer.frame = bounds
        centerRingLayer.path = centerPath.cgPath
        centerRingLayer.fillColor = UIColor.clear.cgColor
        centerRingLayer.strokeColor = UIColor.white.cgColor
        centerRingLayer.lineWidth = 1.8
        layer.addSublayer(centerRingLayer)

        centerDot.frame = CGRect(x: 34.3, y: 34.3, width: 3.4, height: 3.4)
        centerDot.backgroundColor = .systemGreen
        centerDot.layer.cornerRadius = 1.7
        addSubview(centerDot)

        tiltBubble.frame = CGRect(x: 40.6, y: 20.6, width: 12.8, height: 12.8)
        tiltBubble.backgroundColor = .systemOrange
        tiltBubble.layer.cornerRadius = 6.4
        tiltBubble.layer.borderColor = UIColor.white.cgColor
        tiltBubble.layer.borderWidth = 1.5
        tiltBubble.layer.shadowColor = UIColor.black.cgColor
        tiltBubble.layer.shadowOpacity = 0.55
        tiltBubble.layer.shadowRadius = 1.5
        tiltBubble.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(tiltBubble)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(fixQuality: FixQuality, satellites: Int, imuState: IMUState) {
        self.fixQuality = fixQuality
        self.satellites = satellites
        update(imuState: imuState, animated: false)
    }

    func update(imuState: IMUState) {
        update(imuState: imuState, animated: true)
    }

    private func update(imuState: IMUState, animated: Bool) {
        let travel: CGFloat = 20
        let correction = PoleCorrection(imu: imuState)
        let normalizedX = max(-1, min(1, correction.deviationRightDegrees / 5.0))
        let normalizedY = max(-1, min(1, correction.deviationTowardUserDegrees / 5.0))
        let bubbleCenter = CGPoint(
            x: 36 + CGFloat(normalizedX) * travel,
            y: 36 + CGFloat(normalizedY) * travel
        )
        let markerColor = Self.color(
            fixQuality: fixQuality,
            imuState: imuState
        )
        let changes = {
            self.tiltBubble.center = bubbleCenter
            self.tiltBubble.backgroundColor = imuState.measurementReady
                ? .systemGreen : .systemOrange
            self.ring.layer.borderColor = markerColor.cgColor
            self.ring.backgroundColor = markerColor.withAlphaComponent(0.10)
            self.centerDot.backgroundColor = markerColor
        }
        if animated {
            UIView.animate(
                withDuration: 0.10,
                delay: 0,
                options: [.beginFromCurrentState, .curveLinear, .allowUserInteraction],
                animations: changes
            )
        } else {
            changes()
        }
        accessibilityLabel = String(
            format: "Rover, %@, %d Satelliten, Neigung %.2f Grad",
            fixQuality.rawValue,
            satellites,
            imuState.totalTiltDegrees
        )
    }

    private static func color(fixQuality: FixQuality, imuState: IMUState) -> UIColor {
        switch fixQuality {
        case .rtkFloat, .differential: return .systemOrange
        case .single, .estimated: return .systemRed
        case .none, .unknown: return .systemGray
        case .rtkFixed: break
        }
        guard imuState.isAvailable,
              imuState.isCalibrated,
              imuState.hasDirectionCalibration else { return .systemGray }
        return imuState.measurementReady ? .systemGreen : .systemOrange
    }
}

private final class MeasurementPointAnnotation: MLNPointAnnotation {
    var pointIndex = 0
}

private final class MeasurementPointAnnotationView: MLNAnnotationView {
    static let reuseIdentifier = "measurement-point"
    static let dragPreviewOffset: CGFloat = 82

    private let targetRing = UIView()
    private let centerDot = UIView()
    private let numberLabel = UILabel()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        backgroundColor = .clear
        isDraggable = false

        targetRing.frame = CGRect(x: 13, y: 13, width: 18, height: 18)
        targetRing.backgroundColor = UIColor.white.withAlphaComponent(0.9)
        targetRing.layer.cornerRadius = 9
        targetRing.layer.borderColor = UIColor.systemTeal.cgColor
        targetRing.layer.borderWidth = 2
        targetRing.layer.shadowColor = UIColor.black.cgColor
        targetRing.layer.shadowOpacity = 0.5
        targetRing.layer.shadowRadius = 1.5
        targetRing.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(targetRing)

        centerDot.frame = CGRect(x: 7, y: 7, width: 4, height: 4)
        centerDot.backgroundColor = .systemTeal
        centerDot.layer.cornerRadius = 2
        targetRing.addSubview(centerDot)

        numberLabel.frame = CGRect(x: 27, y: 0, width: 22, height: 20)
        numberLabel.font = .systemFont(ofSize: 12, weight: .bold)
        numberLabel.textAlignment = .center
        numberLabel.textColor = .white
        numberLabel.backgroundColor = UIColor.systemTeal.withAlphaComponent(0.95)
        numberLabel.layer.cornerRadius = 10
        numberLabel.clipsToBounds = true
        addSubview(numberLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(pointIndex: Int, isEditable: Bool) {
        numberLabel.text = String(pointIndex)
        accessibilityLabel = isEditable
            ? "Messpunkt \(pointIndex). Zum Verschieben lange drücken und ziehen."
            : "Höhenmesspunkt \(pointIndex)."
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        targetRing.transform = .identity
        numberLabel.transform = .identity
        targetRing.alpha = 1
        numberLabel.alpha = 1
    }
}

private final class DragMagnifierView: UIView {
    private let magnification: CGFloat = 2.25
    private let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .secondarySystemBackground
        clipsToBounds = true
        layer.cornerRadius = frame.width / 2
        layer.borderColor = UIColor.white.cgColor
        layer.borderWidth = 3

        imageView.contentMode = .scaleToFill
        addSubview(imageView)

        addCrosshairLine(frame: CGRect(x: bounds.midX - 16, y: bounds.midY - 1.5, width: 32, height: 3))
        addCrosshairLine(frame: CGRect(x: bounds.midX - 1.5, y: bounds.midY - 16, width: 3, height: 32))

        let center = UIView(frame: CGRect(x: bounds.midX - 3, y: bounds.midY - 3, width: 6, height: 6))
        center.backgroundColor = .systemTeal
        center.layer.cornerRadius = 3
        center.layer.borderColor = UIColor.white.cgColor
        center.layer.borderWidth = 1
        addSubview(center)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func capture(from sourceView: UIView) {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(bounds: sourceView.bounds, format: format)
        imageView.image = renderer.image { _ in
            sourceView.drawHierarchy(in: sourceView.bounds, afterScreenUpdates: false)
        }
    }

    func showSourcePoint(_ point: CGPoint) {
        guard let image = imageView.image else { return }
        imageView.frame = CGRect(
            x: bounds.midX - point.x * magnification,
            y: bounds.midY - point.y * magnification,
            width: image.size.width * magnification,
            height: image.size.height * magnification
        )
    }

    func clearSnapshot() {
        imageView.image = nil
    }

    private func addCrosshairLine(frame: CGRect) {
        let casing = UIView(frame: frame)
        casing.backgroundColor = UIColor.white.withAlphaComponent(0.95)
        addSubview(casing)

        let teal: CGRect
        if frame.width > frame.height {
            teal = CGRect(x: frame.minX, y: frame.midY - 0.5, width: frame.width, height: 1)
        } else {
            teal = CGRect(x: frame.midX - 0.5, y: frame.minY, width: 1, height: frame.height)
        }
        let line = UIView(frame: teal)
        line.backgroundColor = .systemTeal
        addSubview(line)
    }
}

private extension UIInterfaceOrientation {
    var headingOrientation: CLDeviceOrientation {
        switch self {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        default: return .portrait
        }
    }
}
