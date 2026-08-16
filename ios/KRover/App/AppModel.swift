import Combine
import CoreLocation
import Foundation

final class AppModel: ObservableObject {
    let ble = BLERoverManager()
    let ntrip = NtripClient()
    let phoneLocation = PhoneLocationProvider()
    let parcels = ParcelService()
    let boundaryMarkerService = BoundaryMarkerService()

    @Published var selectedParcel: ParcelInfo?
    @Published private(set) var recentParcels: [ParcelInfo] = []
    @Published var boundaryTarget: BoundaryTarget?
    @Published private(set) var cadastralBoundaryPoints: [CadastralBoundaryPoint] = []
    @Published private(set) var boundaryPointLoadState: BoundaryPointLoadState = .idle
    @Published var measurementPoints: [CLLocationCoordinate2D] = []
    @Published private(set) var areaPointMeasurements: [PointMeasurementResult?] = []
    @Published private(set) var elevationPointMeasurements: [PointMeasurementResult] = []
    @Published private(set) var areaCaptureMode: AreaCaptureMode = .append
    @Published private(set) var selectedAreaEdgeIndex: Int?
    @Published private(set) var areaControlMeasurement: AreaControlMeasurement?
    @Published private(set) var areaEditMessage: String?
    @Published private(set) var lastAreaChange: Double?
    @Published private(set) var pointMeasurementSource: PointMeasurementSource = .roverRTK
    @Published private(set) var pointCapturePhase: PointCapturePhase = .idle
    @Published private(set) var pointCaptureProgress = 0.0
    @Published private(set) var pointCaptureSampleCount = 0
    @Published private(set) var pointCaptureTargetSampleCount = 5
    @Published private(set) var pointCaptureStatus = "Messung nicht gestartet"
    @Published private(set) var lastPointMeasurement: PointMeasurementResult?
    @Published var mapBackgroundLayer = MapBackgroundLayer(
        rawValue: UserDefaults.standard.string(forKey: "map.backgroundLayer") ?? ""
    ) ?? .cadastre {
        didSet {
            UserDefaults.standard.set(mapBackgroundLayer.rawValue, forKey: "map.backgroundLayer")
        }
    }
    @Published var poleLengthMeters: Double = max(
        0.5,
        UserDefaults.standard.object(forKey: "measurement.poleLength") as? Double ?? 2.0
    ) {
        didSet {
            UserDefaults.standard.set(poleLengthMeters, forKey: "measurement.poleLength")
        }
    }
    @Published var interactionMode: MapInteractionMode = .inspect
    @Published var activeCoordinate: CLLocationCoordinate2D?
    @Published var deviceHeading: CLLocationDirection?
    // Deliberately synthetic demo location in NRW; never use a developer's private location here.
    @Published var mapCenter = CLLocationCoordinate2D(latitude: 51.0, longitude: 7.0)
    @Published var mapCameraRevision = 0
    @Published private(set) var mapZoomDelta = 0.0
    @Published private(set) var mapZoomRevision = 0
    @Published var searchText = ""
    @Published var isMapBusy = false
    @Published var errorMessage: String?

    @Published var saposHost = "sapos-nw-ntrip.de"
    @Published var saposPort = "2101"
    @Published var saposMountpoint = "VRS_3_4G_NW"
    @Published var saposUsername = UserDefaults.standard.string(forKey: "sapos.username") ?? ""
    @Published var saposPassword = KeychainStore.load(account: "password") ?? ""

    private var cancellables: Set<AnyCancellable> = []
    private let levelAudio = LevelGuidanceAudioController()
    private var roverWasConnected = false
    private var pointAccumulator: PointMeasurementAccumulator?
    private var pendingPointAction: PendingPointAction?
    private var parcelLoadTask: Task<Void, Never>?
    private var parcelLoadGeneration = 0
    private var boundaryPointTask: Task<Void, Never>?

    private enum PendingPointAction {
        case append
        case insert(edgeStartIndex: Int)
        case control(edgeStartIndex: Int)
    }

    init() {
        ble.$latestPosition
            .receive(on: DispatchQueue.main)
            .sink { [weak self] position in
                guard let self else { return }
                guard let position,
                      Date().timeIntervalSince(position.timestamp) < 10 else {
                    self.activeCoordinate = self.phoneLocation.location?.coordinate
                    return
                }
                self.activeCoordinate = position.coordinate
                self.processRoverMeasurementPosition(position)
            }
            .store(in: &cancellables)

        phoneLocation.$location
            .receive(on: DispatchQueue.main)
            .sink { [weak self] location in
                guard let self, let coordinate = location?.coordinate else { return }
                if self.recentRoverPosition == nil { self.activeCoordinate = coordinate }
                if let location { self.processPhoneMeasurementLocation(location) }
            }
            .store(in: &cancellables)

        phoneLocation.$heading
            .receive(on: DispatchQueue.main)
            .sink { [weak self] heading in self?.deviceHeading = heading }
            .store(in: &cancellables)

        ble.$imuState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.processIMUState(state) }
            .store(in: &cancellables)

        ntrip.onRTCMFrame = { [weak self] frame in self?.ble.enqueueRTCM(frame: frame.data) }
        ntrip.ggaProvider = { [weak self] in self?.ggaForCaster() }
        ble.$state
            .map(\.isConnected)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isConnected in
                self?.synchronizeSAPOS(withRoverConnected: isConnected)
            }
            .store(in: &cancellables)
        phoneLocation.start()
        ble.connect()
    }

    var measurementValue: String? {
        switch interactionMode {
        case .inspect, .target: return nil
        case .distance:
            return measurementPoints.count >= 2
                ? String(format: "%.3f m", UTM32Projection.polylineLength(measurementPoints)) : nil
        case .area:
            return measurementPoints.count >= 3
                ? String(format: "%.3f m²", UTM32Projection.polygonArea(measurementPoints)) : nil
        case .elevation:
            guard elevationPointMeasurements.count >= 2,
                  let summary = elevationSummary else { return nil }
            return String(format: "ΔH %.3f m", summary.heightRange)
        }
    }

    var elevationSummary: ElevationMeasurementSummary? {
        ElevationMeasurementSummary(measurements: elevationPointMeasurements)
    }

    func elevationRelativeToReference(at index: Int) -> Double? {
        guard elevationPointMeasurements.indices.contains(index),
              let reference = elevationPointMeasurements.first?.altitudeMSL,
              let altitude = elevationPointMeasurements[index].altitudeMSL else { return nil }
        return altitude - reference
    }

    var areaPerimeter: Double? {
        measurementPoints.count >= 3
            ? UTM32Projection.polygonPerimeter(measurementPoints) : nil
    }

    var selectedAreaEdgeLabel: String? {
        guard let selectedAreaEdgeIndex,
              measurementPoints.indices.contains(selectedAreaEdgeIndex) else { return nil }
        let endIndex = (selectedAreaEdgeIndex + 1) % measurementPoints.count
        return "P\(selectedAreaEdgeIndex + 1)–P\(endIndex + 1)"
    }

    var selectedAreaEdgeDeviation: Double? { selectedAreaEdgeMatch?.distance }

    var areaDeviationThreshold: Double? {
        guard currentPointMeasurementCoordinate != nil else { return nil }
        return max(0.05, 3 * currentPointMeasurementSigma)
    }

    var selectedAreaDeviationIsSignificant: Bool? {
        guard let deviation = selectedAreaEdgeDeviation,
              let threshold = areaDeviationThreshold else { return nil }
        return deviation > threshold
    }

    var selectedAreaEdgeCoordinates: [CLLocationCoordinate2D]? {
        guard let selectedAreaEdgeIndex,
              measurementPoints.indices.contains(selectedAreaEdgeIndex) else { return nil }
        let endIndex = (selectedAreaEdgeIndex + 1) % measurementPoints.count
        return [measurementPoints[selectedAreaEdgeIndex], measurementPoints[endIndex]]
    }

    private var selectedAreaEdgeMatch: PolygonEdgeMatch? {
        guard let selectedAreaEdgeIndex,
              let coordinate = currentPointMeasurementCoordinate else { return nil }
        return PolygonEditor.match(
            coordinate,
            toEdgeStartingAt: selectedAreaEdgeIndex,
            in: measurementPoints
        )
    }

    var poleCorrection: PoleCorrection { PoleCorrection(imu: ble.imuState) }

    var canArmPointMeasurement: Bool {
        switch pointMeasurementSource {
        case .roverRTK:
            let imu = ble.imuState
            return ble.state.isConnected && imu.isAvailable
                && imu.isCalibrated && imu.hasDirectionCalibration
        case .iphoneTest:
            return phoneLocation.location != nil
        }
    }

    var pointCaptureActionLabel: String {
        if pointCapturePhase.isActive { return "Messung abbrechen" }
        if interactionMode == .distance || interactionMode == .elevation {
            return pointMeasurementSource.isTest ? "GPS-Testpunkt messen" : "Messpunkt erfassen"
        }
        switch areaCaptureMode {
        case .append: return pointMeasurementSource.isTest ? "GPS-Testpunkt messen" : "Messpunkt erfassen"
        case .insert: return pointMeasurementSource.isTest ? "GPS-Knick testen" : "Knickmessung starten"
        case .control: return pointMeasurementSource.isTest ? "GPS-Prüfung testen" : "Kontrollmessung starten"
        }
    }

    private var currentPointMeasurementCoordinate: CLLocationCoordinate2D? {
        switch pointMeasurementSource {
        case .roverRTK: return recentRoverPosition?.coordinate
        case .iphoneTest: return phoneLocation.location?.coordinate
        }
    }

    private var currentPointMeasurementSigma: Double {
        switch pointMeasurementSource {
        case .roverRTK: return recentRoverPosition?.horizontalSigma ?? 0.02
        case .iphoneTest: return max(0, phoneLocation.location?.horizontalAccuracy ?? 10)
        }
    }

    var targetCoordinate: CLLocationCoordinate2D? { boundaryTarget?.coordinate }
    var targetUTM: UTMCoordinate? { boundaryTarget?.utm }

    var recentRoverPosition: GNSSPosition? {
        guard let position = ble.latestPosition,
              Date().timeIntervalSince(position.timestamp) < 10 else { return nil }
        return position
    }

    var roverMeasurementReady: Bool {
        guard let position = recentRoverPosition,
              position.fixQuality == .rtkFixed else { return false }
        return ble.imuState.isAvailable
            && ble.imuState.hasDirectionCalibration
            && ble.imuState.measurementReady
    }

    var roverMeasurementReadinessLabel: String {
        guard let position = recentRoverPosition else { return "Rover-Position fehlt" }
        guard position.fixQuality == .rtkFixed else { return "RTK Fix erforderlich" }
        let imu = ble.imuState
        guard imu.isAvailable else { return "Neigungssensor fehlt" }
        guard imu.isCalibrated else { return "Neigungssensor kalibrieren" }
        guard imu.hasDirectionCalibration else { return "Richtung zu dir kalibrieren" }
        guard !imu.isMoving else { return "Stab ruhig halten" }
        guard imu.isLevel else {
            return String(format: "Stab aufrichten · %.2f°", imu.totalTiltDegrees)
        }
        guard imu.measurementReady else { return "Stab kurz ruhig halten" }
        return "Messbereit"
    }

    var targetDistance: Double? {
        guard let activeCoordinate, let targetUTM else { return nil }
        return UTM32Projection.distance(UTM32Projection.project(activeCoordinate), targetUTM)
    }

    var targetBearing: Double? {
        guard let activeCoordinate, let targetUTM else { return nil }
        let origin = UTM32Projection.project(activeCoordinate)
        let degrees = atan2(targetUTM.easting - origin.easting, targetUTM.northing - origin.northing) * 180 / .pi
        return degrees >= 0 ? degrees : degrees + 360
    }

    var targetOffset: (east: Double, north: Double)? {
        guard let activeCoordinate, let targetUTM else { return nil }
        let origin = UTM32Projection.project(activeCoordinate)
        return (
            east: targetUTM.easting - origin.easting,
            north: targetUTM.northing - origin.northing
        )
    }

    var targetTurn: Double? {
        guard let targetBearing, let deviceHeading else { return nil }
        return Self.signedTurn(targetBearing: targetBearing, deviceHeading: deviceHeading)
    }

    static func signedTurn(targetBearing: Double, deviceHeading: Double) -> Double {
        var difference = (targetBearing - deviceHeading).truncatingRemainder(dividingBy: 360)
        if difference > 180 { difference -= 360 }
        if difference < -180 { difference += 360 }
        return difference
    }

    func handleMapTap(_ coordinate: CLLocationCoordinate2D) {
        switch interactionMode {
        case .inspect:
            loadParcel(at: coordinate)
        case .target:
            guard let parcel = selectedParcel else {
                errorMessage = "Bitte zuerst ein Flurstück auswählen."
                return
            }
            guard let target = boundaryMarkerTarget(near: coordinate) ??
                    BoundarySnapper.snap(coordinate, to: parcel.boundaryRings) else {
                errorMessage = "Die Flurstücksgrenze konnte nicht als Ziel verwendet werden."
                return
            }
            boundaryTarget = target
            interactionMode = .inspect
        case .distance:
            measurementPoints.append(coordinate)
        case .elevation:
            break
        case .area:
            switch areaCaptureMode {
            case .append:
                cancelPointCapture()
                appendAreaPoint(coordinate, measurement: nil)
            case .insert, .control:
                cancelPointCapture()
                selectAreaEdge(near: coordinate)
            }
        }
    }

    func setInteractionMode(_ mode: MapInteractionMode) {
        cancelPointCapture()
        if interactionMode != mode && (mode == .distance || mode == .area || mode == .elevation) {
            measurementPoints.removeAll()
            areaPointMeasurements.removeAll()
            elevationPointMeasurements.removeAll()
        }
        if mode == .area, interactionMode != .area {
            resetAreaEditing()
            areaCaptureMode = .append
        }
        interactionMode = mode
    }

    func undoMeasurementPoint() {
        cancelPointCapture()
        if !measurementPoints.isEmpty { measurementPoints.removeLast() }
        if interactionMode == .area, !areaPointMeasurements.isEmpty {
            areaPointMeasurements.removeLast()
        }
        if interactionMode == .elevation, !elevationPointMeasurements.isEmpty {
            elevationPointMeasurements.removeLast()
        }
        resetAreaEditing()
    }

    func clearMeasurement() {
        cancelPointCapture()
        measurementPoints.removeAll()
        areaPointMeasurements.removeAll()
        elevationPointMeasurements.removeAll()
        resetAreaEditing()
    }

    func moveMeasurementPoint(at index: Int, to coordinate: CLLocationCoordinate2D) {
        guard interactionMode != .elevation else { return }
        guard measurementPoints.indices.contains(index) else { return }
        var candidate = measurementPoints
        candidate[index] = coordinate
        if interactionMode == .area, PolygonEditor.hasSelfIntersections(candidate) {
            errorMessage = "Der Punkt kann dort nicht abgelegt werden, weil sich Polygonkanten kreuzen würden."
            return
        }

        measurementPoints = candidate
        if interactionMode == .area {
            if areaPointMeasurements.indices.contains(index) {
                areaPointMeasurements[index] = nil
            }
            resetAreaEditing()
            areaEditMessage = "P\(index + 1) manuell verschoben – vorhandene Messgenauigkeit verworfen."
        }
    }

    func setAreaCaptureMode(_ mode: AreaCaptureMode) {
        cancelPointCapture()
        areaCaptureMode = mode
        selectedAreaEdgeIndex = nil
        areaControlMeasurement = nil
        areaEditMessage = nil
        lastAreaChange = nil
    }

    func setPointMeasurementSource(_ source: PointMeasurementSource) {
        cancelPointCapture()
        pointMeasurementSource = source
        selectedAreaEdgeIndex = nil
        areaControlMeasurement = nil
        areaEditMessage = source.isTest
            ? "TESTMODUS – Punkte verwenden ausschließlich das iPhone-GPS."
            : nil
    }

    func startOrCancelPointCapture() {
        if pointCapturePhase.isActive {
            cancelPointCapture()
            return
        }
        if interactionMode == .distance || interactionMode == .elevation {
            beginPointCapture(action: .append)
            return
        }
        guard interactionMode == .area else { return }
        switch areaCaptureMode {
        case .append:
            beginPointCapture(action: .append)
        case .insert:
            guard let edgeStartIndex = resolvedAreaEdgeForCapture() else { return }
            beginPointCapture(action: .insert(edgeStartIndex: edgeStartIndex))
        case .control:
            guard let edgeStartIndex = resolvedAreaEdgeForCapture() else { return }
            beginPointCapture(action: .control(edgeStartIndex: edgeStartIndex))
        }
    }

    func captureAreaPointFromRover() {
        beginPointCapture(action: .append)
    }

    func selectNearestAreaEdgeToRover() {
        guard let coordinate = currentPointMeasurementCoordinate else {
            errorMessage = "Für die Kantenauswahl wird eine aktuelle Messposition benötigt."
            return
        }
        cancelPointCapture()
        selectAreaEdge(near: coordinate)
    }

    func clearAreaEdgeSelection() {
        cancelPointCapture()
        selectedAreaEdgeIndex = nil
        areaEditMessage = nil
    }

    func insertRoverPointIntoSelectedEdge() {
        guard let edgeStartIndex = resolvedAreaEdgeForCapture() else { return }
        beginPointCapture(action: .insert(edgeStartIndex: edgeStartIndex))
    }

    func captureAreaControlPoint() {
        guard let edgeStartIndex = resolvedAreaEdgeForCapture() else { return }
        beginPointCapture(action: .control(edgeStartIndex: edgeStartIndex))
    }

    func cancelPointCapture() {
        pointAccumulator = nil
        pendingPointAction = nil
        pointCapturePhase = .idle
        pointCaptureProgress = 0
        pointCaptureSampleCount = 0
        pointCaptureStatus = "Messung nicht gestartet"
        levelAudio.stop()
    }

    func search() {
        let query = searchText
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        parcelLoadTask?.cancel()
        parcelLoadGeneration &+= 1
        let generation = parcelLoadGeneration
        let service = parcels
        isMapBusy = true
        parcelLoadTask = Task { [weak self] in
            do {
                let parcel = try await service.search(query)
                try Task.checkCancellation()
                guard let self, self.parcelLoadGeneration == generation else { return }
                self.select(parcel)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.parcelLoadGeneration == generation else { return }
                self.errorMessage = error.localizedDescription
            }
            guard let self, self.parcelLoadGeneration == generation else { return }
            self.isMapBusy = false
            self.parcelLoadTask = nil
        }
    }

    func loadParcelAtCurrentPosition() {
        guard let coordinate = currentCoordinate() else {
            errorMessage = "Noch keine Position vom Rover oder iPhone verfügbar."
            return
        }
        centerMap(on: coordinate)
        loadParcel(at: coordinate)
    }

    func centerOnCurrentPosition() {
        guard let coordinate = currentCoordinate() else {
            errorMessage = "Noch keine Position verfügbar."
            return
        }
        centerMap(on: coordinate)
    }

    func centerOnTarget() {
        guard let coordinate = targetCoordinate else { return }
        centerMap(on: coordinate)
    }

    func zoomMap(by delta: Double) {
        mapZoomDelta = delta
        mapZoomRevision += 1
    }

    func selectParcel(_ parcel: ParcelInfo) {
        parcelLoadTask?.cancel()
        parcelLoadTask = nil
        parcelLoadGeneration &+= 1
        isMapBusy = false
        select(parcel)
    }

    func removeRecentParcel(_ parcel: ParcelInfo) {
        recentParcels.removeAll { $0.id == parcel.id }
        guard selectedParcel?.id == parcel.id else { return }

        boundaryPointTask?.cancel()
        selectedParcel = nil
        clearTarget()
        cadastralBoundaryPoints = []
        boundaryPointLoadState = .idle
        if interactionMode == .target { interactionMode = .inspect }
    }

    func beginBoundaryTargetSelection() {
        guard selectedParcel != nil else {
            errorMessage = "Bitte zuerst ein Flurstück auswählen."
            return
        }
        interactionMode = .target
    }

    func clearTarget() {
        boundaryTarget = nil
    }

    func startSAPOS() {
        guard ntrip.state == .idle else { return }
        guard let port = UInt16(saposPort), !saposUsername.isEmpty, !saposPassword.isEmpty else {
            errorMessage = "Bitte SAPOS-Benutzername, Passwort und einen gültigen Port eintragen."
            return
        }
        let settings = NtripSettings(
            host: saposHost, port: port, mountpoint: saposMountpoint,
            username: saposUsername, password: saposPassword
        )
        guard settings.hasValidRequestFields else {
            errorMessage = "Caster und Mountpoint dürfen nicht leer sein und keine Leer- oder Steuerzeichen enthalten."
            return
        }
        UserDefaults.standard.set(saposUsername, forKey: "sapos.username")
        do {
            try KeychainStore.save(saposPassword, account: "password")
        } catch {
            errorMessage = "Das SAPOS-Passwort konnte nicht im Schlüsselbund gespeichert werden."
            return
        }
        ntrip.start(settings: settings)
    }

    func stopSAPOS() { ntrip.stop() }

    private func synchronizeSAPOS(withRoverConnected isConnected: Bool) {
        guard isConnected != roverWasConnected else { return }
        roverWasConnected = isConnected
        if isConnected {
            startSAPOS()
        } else {
            stopSAPOS()
        }
    }

    private func loadParcel(at coordinate: CLLocationCoordinate2D) {
        parcelLoadTask?.cancel()
        parcelLoadGeneration &+= 1
        let generation = parcelLoadGeneration
        let service = parcels
        isMapBusy = true
        parcelLoadTask = Task { [weak self] in
            do {
                let parcel = try await service.parcel(at: coordinate)
                try Task.checkCancellation()
                guard let self, self.parcelLoadGeneration == generation else { return }
                self.select(parcel)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.parcelLoadGeneration == generation else { return }
                self.errorMessage = error.localizedDescription
            }
            guard let self, self.parcelLoadGeneration == generation else { return }
            self.isMapBusy = false
            self.parcelLoadTask = nil
        }
    }

    private func select(_ parcel: ParcelInfo) {
        selectedParcel = parcel
        recentParcels.removeAll { $0.id == parcel.id }
        recentParcels.insert(parcel, at: 0)
        if recentParcels.count > 8 { recentParcels.removeLast(recentParcels.count - 8) }
        clearTarget()
        loadBoundaryPoints(for: parcel)
        if !parcel.wgs84Vertices.isEmpty {
            let latitude = parcel.wgs84Vertices.map(\.latitude).reduce(0, +) / Double(parcel.wgs84Vertices.count)
            let longitude = parcel.wgs84Vertices.map(\.longitude).reduce(0, +) / Double(parcel.wgs84Vertices.count)
            centerMap(on: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
        }
    }

    func cadastralBoundaryPoint(for target: BoundaryTarget) -> CadastralBoundaryPoint? {
        if let markerID = target.markerID {
            return cadastralBoundaryPoints.first { $0.id == markerID }
        }
        let candidates = cadastralBoundaryPoints.filter {
            UTM32Projection.distance($0.boundaryUTM, target.utm) <= 0.05
        }
        return candidates.min {
            let leftRank = $0.markStatus == .marked ? 0 : 1
            let rightRank = $1.markStatus == .marked ? 0 : 1
            if leftRank != rightRank { return leftRank < rightRank }
            return UTM32Projection.distance($0.boundaryUTM, target.utm) <
                UTM32Projection.distance($1.boundaryUTM, target.utm)
        }
    }

    private func boundaryMarkerTarget(near coordinate: CLLocationCoordinate2D) -> BoundaryTarget? {
        let tappedUTM = UTM32Projection.project(coordinate)
        guard let candidate = cadastralBoundaryPoints
            .filter({ $0.markStatus == .marked })
            .map({ ($0, UTM32Projection.distance(tappedUTM, $0.utm)) })
            .min(by: { $0.1 < $1.1 }),
              candidate.1 <= 1.0 else { return nil }
        return BoundaryTarget(
            coordinate: candidate.0.coordinate,
            utm: candidate.0.utm,
            kind: .marker,
            ringIndex: -1,
            segmentIndex: -1,
            snapDistance: candidate.1,
            markerID: candidate.0.id
        )
    }

    private func loadBoundaryPoints(for parcel: ParcelInfo) {
        boundaryPointTask?.cancel()
        cadastralBoundaryPoints = []
        boundaryPointLoadState = .loading
        let selectedParcelID = parcel.id
        let service = boundaryMarkerService
        boundaryPointTask = Task { [weak self] in
            do {
                let points = try await service.boundaryPoints(for: parcel)
                guard !Task.isCancelled else { return }
                await Task { @MainActor [weak self] in
                    guard self?.selectedParcel?.id == selectedParcelID else { return }
                    self?.cadastralBoundaryPoints = points
                    self?.boundaryPointLoadState = .loaded
                }.value
            } catch {
                guard !Task.isCancelled else { return }
                await Task { @MainActor [weak self] in
                    guard self?.selectedParcel?.id == selectedParcelID else { return }
                    self?.cadastralBoundaryPoints = []
                    self?.boundaryPointLoadState = .unavailable(error.localizedDescription)
                }.value
            }
        }
    }

    private func centerMap(on coordinate: CLLocationCoordinate2D) {
        mapCenter = coordinate
        mapCameraRevision += 1
    }

    private func currentCoordinate() -> CLLocationCoordinate2D? {
        if let position = recentRoverPosition { return position.coordinate }
        return phoneLocation.location?.coordinate ?? activeCoordinate
    }

    private func appendAreaPoint(
        _ coordinate: CLLocationCoordinate2D,
        measurement: PointMeasurementResult?
    ) {
        let candidate = measurementPoints + [coordinate]
        guard !PolygonEditor.hasSelfIntersections(candidate) else {
            errorMessage = "Dieser Punkt würde sich kreuzende Polygonkanten erzeugen."
            return
        }
        measurementPoints = candidate
        areaPointMeasurements.append(measurement)
        selectedAreaEdgeIndex = nil
        areaControlMeasurement = nil
        lastAreaChange = nil
        if let measurement {
            areaEditMessage = String(
                format: "Punkt aus %d Messungen · geschätzt ±%.3f m",
                measurement.sampleCount,
                measurement.estimatedHorizontalAccuracy
            )
        } else {
            areaEditMessage = "TESTPUNKT – manuell in der Karte gesetzt."
        }
    }

    private func selectAreaEdge(near coordinate: CLLocationCoordinate2D) {
        guard let match = PolygonEditor.nearestEdge(to: coordinate, in: measurementPoints) else {
            errorMessage = "Für die Kantenauswahl werden mindestens drei Flächenpunkte benötigt."
            return
        }
        selectedAreaEdgeIndex = match.startIndex
        areaControlMeasurement = nil
        lastAreaChange = nil
        areaEditMessage = "Kante P\(match.startIndex + 1)–P\(match.endIndex + 1) ausgewählt."
    }

    private func areaEdgeMatch(for coordinate: CLLocationCoordinate2D) -> PolygonEdgeMatch? {
        if let selectedAreaEdgeIndex {
            return PolygonEditor.match(
                coordinate,
                toEdgeStartingAt: selectedAreaEdgeIndex,
                in: measurementPoints
            )
        }
        guard let nearest = PolygonEditor.nearestEdge(to: coordinate, in: measurementPoints) else {
            return nil
        }
        selectedAreaEdgeIndex = nearest.startIndex
        return nearest
    }

    private func resolvedAreaEdgeForCapture() -> Int? {
        guard measurementPoints.count >= 3 else {
            errorMessage = "Für eine Knick- oder Kontrollmessung werden mindestens drei Flächenpunkte benötigt."
            return nil
        }
        if let selectedAreaEdgeIndex,
           measurementPoints.indices.contains(selectedAreaEdgeIndex) {
            return selectedAreaEdgeIndex
        }
        guard let coordinate = currentPointMeasurementCoordinate,
              let match = PolygonEditor.nearestEdge(to: coordinate, in: measurementPoints) else {
            errorMessage = "Bitte zuerst eine Polygonkante antippen."
            return nil
        }
        selectedAreaEdgeIndex = match.startIndex
        areaEditMessage = "Kante P\(match.startIndex + 1)–P\(match.endIndex + 1) automatisch gewählt."
        return match.startIndex
    }

    private func beginPointCapture(action: PendingPointAction) {
        guard canArmPointMeasurement else {
            errorMessage = pointMeasurementSource == .roverRTK
                ? "Rover verbinden und den Neigungssensor kalibrieren."
                : "Noch keine iPhone-GPS-Position verfügbar."
            return
        }
        if interactionMode == .elevation {
            let altitude = pointMeasurementSource == .roverRTK
                ? recentRoverPosition?.altitude
                : phoneLocation.location?.altitude
            guard let altitude, altitude.isFinite else {
                errorMessage = "Die aktuelle Messquelle liefert noch keinen Höhenwert."
                return
            }
        }
        pendingPointAction = action
        lastPointMeasurement = nil
        pointCaptureProgress = 0
        pointCaptureSampleCount = 0
        let accumulator = makePointAccumulator()
        pointAccumulator = accumulator
        pointCaptureTargetSampleCount = accumulator.configuration.minimumSamples

        switch pointMeasurementSource {
        case .roverRTK:
            pointCapturePhase = .armed
            pointCaptureStatus = "Aktiv · 0/\(pointCaptureTargetSampleCount) · auf grüne Ausrichtung warten"
            processIMUState(ble.imuState)
            if let position = recentRoverPosition { processRoverMeasurementPosition(position) }
        case .iphoneTest:
            pointCapturePhase = .collecting
            pointCaptureStatus = "TESTMODUS · iPhone-GPS wird gesammelt"
            if let location = phoneLocation.location { processPhoneMeasurementLocation(location) }
        }
    }

    private func makePointAccumulator() -> PointMeasurementAccumulator {
        let configuration = interactionMode == .elevation
            ? PointMeasurementAccumulator.Configuration.elevation(
                for: pointMeasurementSource,
                poleLengthMeters: poleLengthMeters
            )
            : PointMeasurementAccumulator.Configuration.standard(
                for: pointMeasurementSource,
                poleLengthMeters: poleLengthMeters
            )
        return PointMeasurementAccumulator(
            source: pointMeasurementSource,
            configuration: configuration
        )
    }

    private func processIMUState(_ state: IMUState) {
        guard pointMeasurementSource == .roverRTK,
              pointCapturePhase.isActive else { return }

        if state.hasDirectionCalibration,
           state.measurementReady,
           recentRoverPosition?.fixQuality == .rtkFixed {
            pointCapturePhase = .collecting
            pointCaptureStatus = "Grün · \(pointCaptureSampleCount)/\(pointCaptureTargetSampleCount) Werte erfasst"
            if let position = recentRoverPosition { processRoverMeasurementPosition(position) }
        } else if state.isLevel, !state.isMoving {
            pointCapturePhase = .armed
            let stable = state.stableMilliseconds ?? 0
            pointCaptureStatus = "\(pointCaptureSampleCount)/\(pointCaptureTargetSampleCount) gespeichert · Grün wird vorbereitet · \(stable) / 400 ms"
        } else {
            pointCapturePhase = .armed
            let guidance = state.isMoving
                ? "Stab ruhig halten"
                : PoleCorrection(imu: state).instruction
            pointCaptureStatus = "\(pointCaptureSampleCount)/\(pointCaptureTargetSampleCount) gespeichert · \(guidance)"
        }
    }

    private func processRoverMeasurementPosition(_ position: GNSSPosition) {
        guard pointMeasurementSource == .roverRTK,
              pointCapturePhase.isActive else { return }
        guard position.fixQuality == .rtkFixed else {
            pointCapturePhase = .armed
            pointCaptureStatus = "\(pointCaptureSampleCount)/\(pointCaptureTargetSampleCount) gespeichert · warte auf RTK Fixed"
            return
        }
        guard interactionMode != .elevation || position.altitude != nil else {
            pointCapturePhase = .armed
            pointCaptureStatus = "Höhenwert fehlt · warte auf GGA"
            return
        }
        guard ble.imuState.hasDirectionCalibration,
              ble.imuState.measurementReady else {
            pointCapturePhase = .armed
            pointCaptureStatus = "\(pointCaptureSampleCount)/\(pointCaptureTargetSampleCount) gespeichert · \(roverMeasurementReadinessLabel)"
            return
        }
        pointCapturePhase = .collecting
        addPointMeasurementSample(
            position,
            tiltDegrees: ble.imuState.totalTiltDegrees
        )
    }

    private func processPhoneMeasurementLocation(_ location: CLLocation) {
        guard pointMeasurementSource == .iphoneTest,
              pointCapturePhase == .collecting,
              location.horizontalAccuracy >= 0 else { return }
        let milliseconds = max(0, location.timestamp.timeIntervalSince1970 * 1_000)
        let position = GNSSPosition(
            coordinate: location.coordinate,
            altitude: location.altitude.isFinite ? location.altitude : nil,
            horizontalSigma: location.horizontalAccuracy,
            verticalSigma: location.verticalAccuracy >= 0 ? location.verticalAccuracy : nil,
            fixQuality: .single,
            satellites: 0,
            hdop: nil,
            timestamp: location.timestamp,
            sampleID: UInt64(milliseconds)
        )
        addPointMeasurementSample(position, tiltDegrees: 0)
    }

    private func addPointMeasurementSample(
        _ position: GNSSPosition,
        tiltDegrees: Double
    ) {
        guard var accumulator = pointAccumulator else { return }
        let previousSampleCount = accumulator.sampleCount
        let result = accumulator.add(position: position, tiltDegrees: tiltDegrees)
        pointAccumulator = accumulator
        let acceptedNewSample = accumulator.sampleCount > previousSampleCount
        pointCaptureProgress = result == nil ? min(0.96, accumulator.progress) : 1
        pointCaptureSampleCount = accumulator.sampleCount
        if pointMeasurementSource == .iphoneTest {
            pointCaptureStatus = String(
                format: "TESTMODUS · %d GPS-Werte · %.0f %%",
                accumulator.sampleCount,
                accumulator.progress * 100
            )
        } else {
            pointCaptureStatus = String(
                format: "Grüne RTK-Werte · %d/%d · %.0f %%",
                accumulator.sampleCount,
                pointCaptureTargetSampleCount,
                accumulator.progress * 100
            )
        }
        if let result {
            finishPointCapture(with: result)
        } else if acceptedNewSample {
            levelAudio.playMeasurementSample()
        }
    }

    private func finishPointCapture(with result: PointMeasurementResult) {
        guard let action = pendingPointAction,
              apply(result, for: action) else {
            cancelPointCapture()
            return
        }
        pointAccumulator = nil
        pendingPointAction = nil
        lastPointMeasurement = result
        pointCapturePhase = .completed
        pointCaptureProgress = 1
        pointCaptureSampleCount = result.sampleCount
        if interactionMode == .elevation,
           let verticalSpread = result.verticalSpread,
           let verticalAccuracy = result.estimatedVerticalAccuracy {
            pointCaptureStatus = String(
                format: "Höhe gespeichert · %d Werte · H-Streuung %.3f m · ±%.3f m",
                result.sampleCount,
                verticalSpread,
                verticalAccuracy
            )
        } else {
            pointCaptureStatus = String(
                format: "Gespeichert · %d Werte · Streuung %.3f m · ±%.3f m",
                result.sampleCount,
                result.horizontalSpread,
                result.estimatedHorizontalAccuracy
            )
        }
        levelAudio.playMeasurementCompleted()
    }

    private func apply(
        _ result: PointMeasurementResult,
        for action: PendingPointAction
    ) -> Bool {
        switch action {
        case .append:
            if interactionMode == .distance {
                measurementPoints.append(result.coordinate)
                return true
            }
            if interactionMode == .elevation {
                guard result.altitudeMSL != nil else {
                    errorMessage = "Die Höhenmessung enthielt nicht genügend gültige Höhenwerte."
                    return false
                }
                if let firstSource = elevationPointMeasurements.first?.source,
                   firstSource != result.source {
                    errorMessage = "Alle Höhenpunkte müssen mit derselben Messquelle aufgenommen werden."
                    return false
                }
                measurementPoints.append(result.coordinate)
                elevationPointMeasurements.append(result)
                return true
            }
            let previousCount = measurementPoints.count
            appendAreaPoint(result.coordinate, measurement: result)
            return measurementPoints.count == previousCount + 1

        case .insert(let edgeStartIndex):
            guard let match = PolygonEditor.match(
                result.coordinate,
                toEdgeStartingAt: edgeStartIndex,
                in: measurementPoints
            ), match.projectionIsWithinSegment,
                  match.fraction > 0.001, match.fraction < 0.999 else {
                errorMessage = "Der gemittelte Punkt liegt nicht zwischen den Endpunkten der ausgewählten Kante."
                return false
            }
            guard let candidate = PolygonEditor.inserting(
                result.coordinate,
                afterEdgeStartingAt: edgeStartIndex,
                in: measurementPoints
            ), !PolygonEditor.hasSelfIntersections(candidate) else {
                errorMessage = "Der gemittelte Punkt würde sich kreuzende Polygonkanten erzeugen."
                return false
            }
            let previousArea = UTM32Projection.polygonArea(measurementPoints)
            measurementPoints = candidate
            while areaPointMeasurements.count < candidate.count - 1 {
                areaPointMeasurements.append(nil)
            }
            areaPointMeasurements.insert(result, at: edgeStartIndex + 1)
            let areaChange = UTM32Projection.polygonArea(candidate) - previousArea
            lastAreaChange = areaChange
            areaControlMeasurement = nil
            selectedAreaEdgeIndex = nil
            areaEditMessage = String(
                format: "Knickpunkt aus %d Messungen · Fläche %+.3f m²",
                result.sampleCount,
                areaChange
            )
            return true

        case .control(let edgeStartIndex):
            guard let match = PolygonEditor.match(
                result.coordinate,
                toEdgeStartingAt: edgeStartIndex,
                in: measurementPoints
            ) else {
                errorMessage = "Die ausgewählte Kontrollkante ist nicht mehr verfügbar."
                return false
            }
            let measurement = AreaControlMeasurement(
                coordinate: result.coordinate,
                edgeStartIndex: match.startIndex,
                edgeEndIndex: match.endIndex,
                distanceToEdge: match.distance,
                horizontalSigma: result.estimatedHorizontalAccuracy,
                timestamp: result.timestamp
            )
            areaControlMeasurement = measurement
            lastAreaChange = nil
            areaEditMessage = measurement.isSignificant
                ? "Kontrollabweichung ist größer als die geschätzte Messunsicherheit."
                : "Kontrollabweichung liegt innerhalb der geschätzten Messunsicherheit."
            return true
        }
    }

    private func resetAreaEditing() {
        selectedAreaEdgeIndex = nil
        areaControlMeasurement = nil
        areaEditMessage = nil
        lastAreaChange = nil
    }

    private func ggaForCaster() -> String? {
        if recentRoverPosition != nil, let sentence = ble.latestGGA {
            return sentence
        }
        guard let location = phoneLocation.location else { return nil }
        return NMEAGenerator.gga(
            coordinate: location.coordinate,
            altitude: location.altitude.isFinite ? location.altitude : 0
        )
    }
}
