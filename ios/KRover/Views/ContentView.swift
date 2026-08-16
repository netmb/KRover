import SwiftUI
import UIKit

private enum AppTab: Hashable {
    case map
    case rover
    case sapos
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedTab = AppTab.map

    var body: some View {
        Group {
            switch selectedTab {
            case .map:
                MapScreen(openTab: { selectedTab = $0 })
            case .rover:
                RoverRedesignScreen(manager: model.ble) { selectedTab = .map }
            case .sapos:
                SAPOSRedesignScreen(client: model.ntrip) { selectedTab = .map }
            }
        }
        .tint(.blue)
        .preferredColorScheme(.dark)
        .alert("Hinweis", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

private struct MapScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let openTab: (AppTab) -> Void

    @State private var sheetLevel = MapSheetLevel.standard
    @State private var sheetDragOffset: CGFloat = 0
    @State private var searchIsPresented = false
    @State private var activeControlPopup: MapControlPopup?
    @State private var iPadSidebarIsVisible = true
    @State private var iPadShowsParcelDetails = false
    @FocusState private var searchIsFocused: Bool

    private var usesCompactLandscapeLayout: Bool { verticalSizeClass == .compact }

    var body: some View {
        GeometryReader { geometry in
            Group {
                if usesIPadLayout(in: geometry.size) {
                    iPadMapLayout(in: geometry)
                } else {
                    phoneMapLayout(in: geometry)
                }
            }
            .onChange(of: model.boundaryTarget != nil) { _, hasTarget in
                withAnimation(.snappy) {
                    if usesIPadLayout(in: geometry.size) {
                        iPadSidebarIsVisible = !hasTarget
                    } else {
                        sheetLevel = hasTarget ? .collapsed : .standard
                    }
                }
            }
            .onChange(of: model.selectedParcel != nil) { _, hasParcel in
                if hasParcel, model.boundaryTarget == nil {
                    withAnimation(.snappy) { sheetLevel = .standard }
                }
            }
            .onChange(of: model.selectedParcel?.id) { _, _ in
                iPadShowsParcelDetails = false
            }
        }
    }

    private func usesIPadLayout(in size: CGSize) -> Bool {
        horizontalSizeClass == .regular && size.width >= 700
    }

    private func phoneMapLayout(in geometry: GeometryProxy) -> some View {
        ZStack {
            MapLibreMapView(model: model, ornamentLayout: .phone)
                .ignoresSafeArea()

            if activeControlPopup != nil {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.snappy) { activeControlPopup = nil }
                    }
            }

            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    mapStatusMenu
                    Spacer(minLength: 8)
                    mapControls
                }
                Spacer(minLength: 12)
                HStack {
                    if usesCompactLandscapeLayout { Spacer(minLength: 0) }
                    mapBottomSheet(height: sheetHeight(in: geometry.size))
                        .frame(maxWidth: usesCompactLandscapeLayout ? 680 : .infinity)
                }
            }
            .padding(.horizontal, usesCompactLandscapeLayout ? 12 : 8)
            .padding(.top, 8)
            .padding(.bottom, 4)

            if searchIsPresented {
                searchField
                    .padding(.top, 66)
                    .padding(.leading, 16)
                    .padding(.trailing, 76)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if model.isMapBusy {
                ProgressView()
                    .controlSize(.large)
                    .padding(18)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 0.5))
            }
        }
    }

    private var mapStatusMenu: some View {
        Button {
            searchIsPresented = false
            searchIsFocused = false
            withAnimation(.snappy) {
                activeControlPopup = activeControlPopup == .devices ? nil : .devices
            }
        } label: {
            mapStatusPill
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topLeading) {
            if activeControlPopup == .devices {
                deviceSettingsPopup
                    .offset(y: 44)
                    .transition(
                        .scale(scale: 0.92, anchor: .topLeading)
                            .combined(with: .opacity)
                    )
            }
        }
        .zIndex(3)
        .accessibilityLabel("Rover- und SAPOS-Einstellungen")
    }

    private var mapStatusPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(positionStatusColor)
                .frame(width: 9, height: 9)
            Text(positionAccuracyText)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(.white)
            Rectangle()
                .fill(.white.opacity(0.28))
                .frame(width: 1, height: 14)
            Text(model.ntrip.state.isStreaming ? "SAPOS" : "ohne SAPOS")
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
            Rectangle()
                .fill(.white.opacity(0.28))
                .frame(width: 1, height: 14)
            Image(systemName: "gearshape.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .accessibilityHidden(true)
        }
        .font(.system(size: 14))
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.10), lineWidth: 0.5))
        .contentShape(Capsule())
        .accessibilityElement(children: .combine)
    }

    private var deviceSettingsPopup: some View {
        VStack(spacing: 4) {
            deviceSettingsRow(
                title: "Rover",
                systemImage: "antenna.radiowaves.left.and.right",
                statusColor: model.ble.state.isConnected ? .green : .gray
            ) {
                activeControlPopup = nil
                openTab(.rover)
            }
            deviceSettingsRow(
                title: "SAPOS",
                systemImage: "dot.radiowaves.up.forward",
                statusColor: model.ntrip.state.isStreaming ? .green : .gray
            ) {
                activeControlPopup = nil
                openTab(.sapos)
            }
        }
        .padding(8)
        .frame(width: 232)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background(
            Color.black.opacity(0.48),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.48), radius: 18, y: 8)
    }

    private func deviceSettingsRow(
        title: String,
        systemImage: String,
        statusColor: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 12)
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
            }
            .padding(.horizontal, 12)
            .frame(height: 54)
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var mapControls: some View {
        VStack(spacing: 12) {
            Button {
                activeControlPopup = nil
                withAnimation(.snappy) { searchIsPresented.toggle() }
                searchIsFocused = searchIsPresented
            } label: {
                FloatingMapControl(
                    systemImage: searchIsPresented ? "xmark" : "magnifyingglass"
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(searchIsPresented ? "Suche schließen" : "Flurstück suchen")

            Button {
                searchIsPresented = false
                searchIsFocused = false
                withAnimation(.snappy) {
                    activeControlPopup = activeControlPopup == .interaction ? nil : .interaction
                }
            } label: {
                FloatingMapControl(
                    systemImage: model.interactionMode.systemImage,
                    foreground: model.interactionMode == .inspect ? .yellow : .white
                )
            }
            .buttonStyle(.plain)
            .overlay(alignment: .topTrailing) {
                if activeControlPopup == .interaction {
                    interactionModePopup
                        .offset(x: -60)
                        .transition(.scale(scale: 0.92, anchor: .topTrailing).combined(with: .opacity))
                }
            }
            .zIndex(2)
            .accessibilityLabel("Modus: \(model.interactionMode.rawValue)")

            Button {
                searchIsPresented = false
                searchIsFocused = false
                withAnimation(.snappy) {
                    activeControlPopup = activeControlPopup == .layers ? nil : .layers
                }
            } label: {
                FloatingMapControl(systemImage: "square.3.layers.3d")
            }
            .buttonStyle(.plain)
            .overlay(alignment: .topTrailing) {
                if activeControlPopup == .layers {
                    mapLayerPopup
                        .offset(x: -60)
                        .transition(.scale(scale: 0.92, anchor: .topTrailing).combined(with: .opacity))
                }
            }
            .zIndex(1)
            .accessibilityLabel("Kartenlayer: \(model.mapBackgroundLayer.title)")

            Button {
                activeControlPopup = nil
                model.centerOnCurrentPosition()
            } label: {
                FloatingMapControl(systemImage: "location.fill", isProminent: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Auf Position zentrieren")
        }
    }

    private var interactionModePopup: some View {
        VStack(spacing: 4) {
            ForEach(MapInteractionMode.allCases) { mode in
                Button {
                    model.setInteractionMode(mode)
                    if mode == .target { sheetLevel = .standard }
                    withAnimation(.snappy) { activeControlPopup = nil }
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: mode.popupSystemImage)
                            .symbolRenderingMode(.monochrome)
                            .font(.system(size: 25, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                        Text(mode.rawValue)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                        Spacer(minLength: 12)
                        if mode == model.interactionMode {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 52)
                    .background(
                        mode == model.interactionMode ? Color.white.opacity(0.13) : .clear,
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .frame(width: 246)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background(
            Color.black.opacity(0.48),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.48), radius: 18, y: 8)
    }

    private var mapLayerPopup: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("KARTENHINTERGRUND")
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 5)

            ForEach(MapBackgroundLayer.allCases) { layer in
                Button {
                    model.mapBackgroundLayer = layer
                    withAnimation(.snappy) { activeControlPopup = nil }
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: layer.systemImage)
                            .symbolRenderingMode(.monochrome)
                            .font(.system(size: 25, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(layer.title)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white)
                            Text(layer.detail)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if layer == model.mapBackgroundLayer {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 60)
                    .background(
                        layer == model.mapBackgroundLayer ? Color.white.opacity(0.13) : .clear,
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .frame(width: 286)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background(
            Color.black.opacity(0.48),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.48), radius: 18, y: 8)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .semibold))
            TextField("Adresse oder Flurstück", text: $model.searchText)
                .focused($searchIsFocused)
                .textInputAutocapitalization(.words)
                .submitLabel(.search)
                .onSubmit {
                    model.search()
                    searchIsFocused = false
                }
            if !model.searchText.isEmpty {
                Button { model.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                model.search()
                searchIsFocused = false
            } label: {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 28))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
    }

    private func mapBottomSheet(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            Button(action: cycleSheetLevel) {
                VStack(spacing: 5) {
                    Capsule()
                        .fill(.white.opacity(0.28))
                        .frame(width: 38, height: 5)
                    Image(systemName: sheetLevel == .details ? "chevron.down" : "chevron.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 9)
                .padding(.bottom, sheetLevel == .collapsed ? 1 : 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .gesture(sheetDragGesture)

            ScrollView(.vertical) {
                sheetContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.bottom, sheetLevel == .collapsed ? 4 : 16)
            }
            .scrollIndicators(.hidden)
            .scrollDisabled(sheetLevel != .details)
        }
        .frame(height: height, alignment: .top)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .background(
            Color.black.opacity(0.34),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.09), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.50), radius: 22, y: -4)
        .offset(y: max(-18, sheetDragOffset))
        .animation(.snappy, value: sheetLevel)
    }

    private var sheetDragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { sheetDragOffset = $0.translation.height }
            .onEnded { value in
                let projected = value.predictedEndTranslation.height
                if projected < -45 {
                    sheetLevel = sheetLevel == .collapsed ? .standard : .details
                } else if projected > 45 {
                    sheetLevel = sheetLevel == .details ? .standard : .collapsed
                }
                sheetDragOffset = 0
            }
    }

    private func cycleSheetLevel() {
        withAnimation(.snappy) {
            switch sheetLevel {
            case .collapsed: sheetLevel = .standard
            case .standard: sheetLevel = .details
            case .details: sheetLevel = .collapsed
            }
        }
    }

    private func sheetHeight(in size: CGSize) -> CGFloat {
        if usesCompactLandscapeLayout {
            switch sheetLevel {
            case .collapsed: return model.boundaryTarget == nil ? 74 : 86
            case .standard: return min(195, size.height * 0.42)
            case .details: return min(300, size.height * 0.68)
            }
        }
        switch sheetLevel {
        case .collapsed: return model.boundaryTarget == nil ? 74 : 86
        case .standard:
            if model.interactionMode == .distance {
                let isActiveRoverMeasurement = model.pointCapturePhase.isActive
                    && model.pointMeasurementSource == .roverRTK
                return isActiveRoverMeasurement
                    ? min(390, size.height * 0.52)
                    : min(255, size.height * 0.38)
            }
            if model.interactionMode == .area || model.interactionMode == .elevation {
                return min(330, size.height * 0.44)
            }
            if model.boundaryTarget != nil { return min(240, size.height * 0.34) }
            return min(225, size.height * 0.31)
        case .details: return min(540, size.height * 0.64)
        }
    }

    @ViewBuilder private var sheetContent: some View {
        if sheetLevel == .collapsed {
            collapsedSheetContent
        } else if model.interactionMode == .area {
            areaMeasurementControls
        } else if model.interactionMode == .elevation {
            elevationMeasurementControls
        } else if model.interactionMode == .distance {
            distanceMeasurementControls
        } else if model.interactionMode == .target {
            targetSelectionContent
        } else if let parcel = model.selectedParcel, let target = model.boundaryTarget {
            navigationContent(parcel: parcel, target: target)
        } else if let parcel = model.selectedParcel {
            parcelContent(parcel)
        } else {
            emptyMapContent
        }
    }

    @ViewBuilder private var collapsedSheetContent: some View {
        if let value = model.measurementValue {
            HStack {
                Label(model.interactionMode.rawValue, systemImage: model.interactionMode.systemImage)
                    .font(.headline)
                Spacer()
                Text(value).font(.title3.bold().monospacedDigit())
            }
            .padding(.top, 5)
        } else if let parcel = model.selectedParcel, let target = model.boundaryTarget {
            navigationCollapsedContent(parcel: parcel, target: target)
        } else if let parcel = model.selectedParcel {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(parcel.label)
                        .font(.system(size: 19, weight: .semibold))
                        .lineLimit(1)
                    Text(parcelSummary(parcel))
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.up")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        } else {
            HStack {
                Label(model.interactionMode.rawValue, systemImage: model.interactionMode.systemImage)
                    .font(.headline)
                Spacer()
                Text("Karte antippen").foregroundStyle(.secondary)
            }
            .padding(.top, 5)
        }
    }

    private var targetSelectionContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let parcel = model.selectedParcel {
                Label("Ziel auf Flurstück \(parcel.number)", systemImage: "scope")
                    .font(.system(size: 20, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Text("Grüne Abmarkung, Katasterpunkt oder gelbe Grenzlinie antippen. Nachbarflurstücke bleiben gesperrt.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                Button("Abbrechen") { model.setInteractionMode(.inspect) }
                    .buttonStyle(SecondaryCapsuleButtonStyle())
            } else {
                Text("Zuerst ein Flurstück auswählen.")
                    .font(.headline)
                Button("Flurstück wählen") { model.setInteractionMode(.inspect) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.top, 2)
    }

    private func parcelContent(_ parcel: ParcelInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(parcel.label)
                        .font(.system(size: 24, weight: .bold))
                        .lineLimit(1)
                    Text(parcelSummary(parcel))
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "lock.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }

            if sheetLevel == .details {
                parcelDetails(parcel)
            } else {
                boundaryPointStatus
            }
            Button("Ziel wählen") { model.beginBoundaryTargetSelection() }
                .buttonStyle(FilledCapsuleButtonStyle())
        }
        .padding(.top, 1)
    }

    private func parcelDetails(_ parcel: ParcelInfo) -> some View {
        let marked = model.cadastralBoundaryPoints.filter { $0.markStatus == .marked }.count
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                MetricTile(title: "Grenzpunkte", value: "\(model.cadastralBoundaryPoints.count)")
                MetricTile(title: "vermarkt", value: "\(marked)", valueColor: .orange)
                MetricTile(
                    title: "Umfang",
                    value: String(format: "%.0f m", parcelPerimeter(parcel))
                )
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionEyebrow("Punktfarben")
                MapLegendRow(color: .green, text: "Abmarkung vorhanden")
                MapLegendRow(color: .orange, text: "ohne oder unklare Marke")
                MapLegendRow(color: .yellow, text: "nur Geometrie")
            }

            Divider().overlay(.white.opacity(0.12))
            Text("ALKIS · Standardabweichung abhängig vom amtlichen Punkt. Kartendarstellung als Auffindehilfe – keine rechtsverbindliche Grenzfeststellung.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
    }

    private var emptyMapContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Flurstück auswählen")
                .font(.system(size: 22, weight: .bold))
            Text("Tippe ein Flurstück auf der Karte an oder lade das Flurstück an deiner aktuellen Position.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            Button("Flurstück an Position") { model.loadParcelAtCurrentPosition() }
                .buttonStyle(FilledCapsuleButtonStyle())
            if sheetLevel == .details {
                Text("Kartendarstellung als Auffindehilfe – keine rechtsverbindliche Grenzfeststellung.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
    }

    private var positionStatusColor: Color {
        if let position = model.recentRoverPosition {
            return position.fixQuality == .rtkFixed ? .green : .orange
        }
        return model.phoneLocation.location == nil ? .gray : .green
    }

    private var positionAccuracyText: String {
        if let position = model.recentRoverPosition {
            if let sigma = position.horizontalSigma {
                return String(format: "±%.2f m", locale: Locale.current, sigma)
            }
            return position.fixQuality.rawValue
        }
        if let location = model.phoneLocation.location {
            return String(format: "±%.1f m", locale: Locale.current, location.horizontalAccuracy)
        }
        return "Position fehlt"
    }

    private func parcelPerimeter(_ parcel: ParcelInfo) -> Double {
        parcel.boundaryRings.reduce(0) { total, ring in
            guard ring.utm.count > 1 else { return total }
            var result = 0.0
            for index in ring.utm.indices {
                let next = ring.utm[(index + 1) % ring.utm.count]
                result += UTM32Projection.distance(ring.utm[index], next)
            }
            return total + result
        }
    }

    @ViewBuilder private var distanceMeasurementControls: some View {
        HStack {
            Text("Strecke · \(model.measurementPoints.count) Punkte")
                .font(.system(size: 22, weight: .bold))
            Spacer()
            measurementSourcePicker
        }
        measurementSourceWarning
        measurementValueSummary
        pointCaptureControls(actionEnabled: model.canArmPointMeasurement)
        if sheetLevel == .details {
            Text("Jede abgeschlossene Messung wird als nächster Punkt der Strecke angefügt.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Die Streckenlänge wird aus den gemittelten Punkten in ETRS89 / UTM 32N berechnet.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("Alternativ lassen sich Testpunkte weiterhin direkt auf der Karte setzen und verschieben.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var elevationMeasurementControls: some View {
        HStack {
            Text("Höhe/Gefälle · \(model.elevationPointMeasurements.count) Punkte")
                .font(.system(size: 22, weight: .bold))
            Spacer()
            measurementSourcePicker
        }
        measurementSourceWarning
        measurementValueSummary

        Text("Lotrechte Messpunkte aufnehmen; der erste Punkt ist die Höhenreferenz.")
            .font(.caption)
            .foregroundStyle(.secondary)

        pointCaptureControls(actionEnabled: model.canArmPointMeasurement)

        if let summary = model.elevationSummary,
           !model.elevationPointMeasurements.isEmpty {
            elevationSummary(summary)
        }

        Text("Hoch- und Tiefpunkt beziehen sich auf die aufgenommenen Punkte. Stab und Antenne zwischen den Messungen nicht verändern.")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder private func elevationSummary(_ summary: ElevationMeasurementSummary) -> some View {
        if model.elevationPointMeasurements.count == 1 {
            Label("P1 ist die Referenz · 0,000 m", systemImage: "flag.fill")
                .font(.caption.bold().monospacedDigit())
        } else {
            HStack(spacing: 12) {
                Label("Hoch P\(summary.highestPointIndex + 1)", systemImage: "arrow.up.circle.fill")
                Label("Tief P\(summary.lowestPointIndex + 1)", systemImage: "arrow.down.circle.fill")
                Spacer()
                Text(String(format: "ΔH %.3f m", summary.heightRange))
                    .font(.headline.monospacedDigit())
            }
            .font(.caption.bold())

            if let accuracy = summary.estimatedRangeAccuracy {
                Text(String(format: "Geschätzte Unsicherheit der Höhendifferenz: ±%.3f m", accuracy))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let slope = summary.startToEndSlopePercent {
                let direction = slope < 0 ? "Gefälle" : "Steigung"
                Text(String(
                    format: "P1 → P%d: %+.3f m auf %.3f m · %@ %.2f %%",
                    model.elevationPointMeasurements.count,
                    summary.startToEndHeightDifference,
                    summary.startToEndHorizontalDistance,
                    direction,
                    abs(slope)
                ))
                .font(.caption.bold().monospacedDigit())
            }
        }

        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                ForEach(model.elevationPointMeasurements.indices, id: \.self) { index in
                    if let relativeHeight = model.elevationRelativeToReference(at: index) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("P\(index + 1)").font(.caption2.bold())
                            Text(String(format: "%+.3f m", relativeHeight))
                                .font(.caption.monospacedDigit())
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder private var areaMeasurementControls: some View {
        HStack {
            Text("Fläche · \(model.measurementPoints.count) Punkte")
                .font(.system(size: 22, weight: .bold))
            Spacer()
            if let perimeter = model.areaPerimeter {
                Text(String(format: "U %.3f m", perimeter))
                    .font(.caption.bold().monospacedDigit())
            }
            measurementSourcePicker
        }
        measurementSourceWarning
        measurementValueSummary
        Picker("Flächenaufnahme", selection: Binding(
            get: { model.areaCaptureMode },
            set: { model.setAreaCaptureMode($0) }
        )) {
            ForEach(AreaCaptureMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)

        switch model.areaCaptureMode {
        case .append:
            Text("Jede abgeschlossene Messung wird als nächster Polygonpunkt angefügt.")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .insert:
            HStack {
                Label(
                    model.selectedAreaEdgeLabel.map { "Kante \($0)" } ?? "Kante antippen",
                    systemImage: "point.topleft.down.to.point.bottomright.curvepath"
                )
                .font(.subheadline.bold())
                Spacer()
                Button("Am Rover") { model.selectNearestAreaEdgeToRover() }
                    .controlSize(.small)
                if model.selectedAreaEdgeLabel != nil {
                    Button { model.clearAreaEdgeSelection() } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .accessibilityLabel("Kantenauswahl aufheben")
                }
            }
            if let deviation = model.selectedAreaEdgeDeviation,
               let significant = model.selectedAreaDeviationIsSignificant {
                Label(
                    String(format: "Messposition %.3f m neben der bisherigen Kante", deviation),
                    systemImage: significant ? "arrow.triangle.branch" : "checkmark.circle"
                )
                .font(.caption.bold().monospacedDigit())
                .foregroundStyle(significant ? .orange : .secondary)
            }

        case .control:
            HStack {
                Label(
                    model.selectedAreaEdgeLabel.map { "Prüfe \($0)" } ?? "Kante antippen",
                    systemImage: "ruler"
                )
                .font(.subheadline.bold())
                Spacer()
                Button("Am Rover") { model.selectNearestAreaEdgeToRover() }
                    .controlSize(.small)
            }
            if let control = model.areaControlMeasurement {
                Label(
                    String(
                        format: "Abstand %.3f m · Schwelle %.3f m",
                        control.distanceToEdge,
                        control.significanceThreshold
                    ),
                    systemImage: control.isSignificant
                        ? "exclamationmark.triangle.fill" : "checkmark.seal.fill"
                )
                .font(.caption.bold().monospacedDigit())
                .foregroundStyle(control.isSignificant ? .orange : .green)
            }
        }

        pointCaptureControls(actionEnabled: areaCaptureActionEnabled)

        if let message = model.areaEditMessage {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Text("Polygon wird in Punktreihenfolge geschlossen und in ETRS89 / UTM 32N berechnet.")
            .font(.caption2)
            .foregroundStyle(.secondary)
        Text("Auf der Karte oder einem Punkt kurz halten; das Fadenkreuz in der Lupe bestimmt die Position.")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private var areaCaptureActionEnabled: Bool {
        guard model.canArmPointMeasurement else { return false }
        switch model.areaCaptureMode {
        case .append: return true
        case .insert, .control: return model.measurementPoints.count >= 3
        }
    }

    private var measurementSourcePicker: some View {
        Picker("Messquelle", selection: Binding(
            get: { model.pointMeasurementSource },
            set: { model.setPointMeasurementSource($0) }
        )) {
            ForEach(PointMeasurementSource.allCases) { source in
                Text(source.rawValue).tag(source)
            }
        }
        .pickerStyle(.menu)
        .disabled(model.interactionMode == .elevation && !model.elevationPointMeasurements.isEmpty)
    }

    @ViewBuilder private var measurementSourceWarning: some View {
        if model.pointMeasurementSource.isTest {
            Label("TESTMODUS – keine RTK-Messung", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.bold())
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder private var measurementValueSummary: some View {
        if let value = model.measurementValue {
            HStack(spacing: 10) {
                Label(measurementValueLabel, systemImage: measurementValueIcon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(value)
                    .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 6)
                    .background(.blue.opacity(0.86), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 0.5))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(measurementValueLabel): \(value)")
        }
    }

    private var measurementValueLabel: String {
        switch model.interactionMode {
        case .distance: return "Gesamtlänge"
        case .area: return "Fläche"
        case .elevation: return "Höhendifferenz"
        case .inspect, .target: return "Messwert"
        }
    }

    private var measurementValueIcon: String {
        switch model.interactionMode {
        case .distance: return "ruler"
        case .area: return "square.dashed"
        case .elevation: return "arrow.up.and.down"
        case .inspect, .target: return "number"
        }
    }

    @ViewBuilder private func pointCaptureControls(actionEnabled: Bool) -> some View {
        if model.pointCapturePhase.isActive && model.pointMeasurementSource == .roverRTK {
            HStack(spacing: 12) {
                PoleGuidanceView(
                    correction: model.poleCorrection,
                    isLevel: model.ble.imuState.isLevel,
                    isReady: model.ble.imuState.measurementReady
                )
                .frame(width: 118, height: 118)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.poleCorrection.instruction)
                        .font(.headline)
                    Text("Gehäusestrich zeigt zu dir")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                    Text(String(format: "Neigung %.2f°", model.ble.imuState.totalTiltDegrees))
                        .font(.caption.monospacedDigit())
                    Text("Kurze Grünphasen genügen. Jeder gültige Wert wird kurz quittiert.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        if model.pointCapturePhase.isActive || model.pointCapturePhase == .completed {
            ProgressView(value: model.pointCaptureProgress) {
                Text(model.pointCaptureStatus)
                    .font(.caption.bold().monospacedDigit())
            }
        }

        HStack {
            Button {
                model.startOrCancelPointCapture()
            } label: {
                Label(
                    model.pointCaptureActionLabel,
                    systemImage: model.pointCapturePhase.isActive
                        ? "xmark.circle" : "scope"
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(model.pointCapturePhase.isActive ? .orange : .blue)
            .disabled(!model.pointCapturePhase.isActive && !actionEnabled)
            Spacer()
            measurementEditButtons
        }

        if let result = model.lastPointMeasurement,
           model.interactionMode == .elevation,
           let verticalSpread = result.verticalSpread,
           let verticalAccuracy = result.estimatedVerticalAccuracy {
            Text(String(
                format: "%d Werte / %.1f s · Ø Neigung %.2f° · H-Streuung %.3f m · geschätzt ±%.3f m",
                result.sampleCount,
                result.duration,
                result.meanTiltDegrees,
                verticalSpread,
                verticalAccuracy
            ))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(result.source.isTest ? .orange : .secondary)
        } else if let result = model.lastPointMeasurement {
            Text(String(
                format: "%d Werte / %.1f s · min %.2f° · Ø %.2f° · Streuung %.3f m · geschätzt ±%.3f m",
                result.sampleCount,
                result.duration,
                result.minimumTiltDegrees,
                result.meanTiltDegrees,
                result.horizontalSpread,
                result.estimatedHorizontalAccuracy
            ))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(result.source.isTest ? .orange : .secondary)
        }
    }

    private var measurementEditButtons: some View {
        HStack(spacing: 10) {
            Button("Zurück") { model.undoMeasurementPoint() }
                .disabled(model.measurementPoints.isEmpty)
            Button(role: .destructive) { model.clearMeasurement() } label: {
                Image(systemName: "trash")
            }
            .disabled(model.measurementPoints.isEmpty)
            .accessibilityLabel("Messung löschen")
        }
        .controlSize(.small)
    }

    private func navigationCollapsedContent(
        parcel: ParcelInfo,
        target: BoundaryTarget
    ) -> some View {
        HStack(spacing: 12) {
            if let direction = model.targetTurn ?? model.targetBearing {
                NavigationArrow(direction: direction, size: 40)
                    .accessibilityLabel(turnHint(model.targetTurn))
            }
            VStack(alignment: .leading, spacing: 0) {
                if let distance = model.targetDistance {
                    NavigationDistanceReadout(distance: distance)
                } else {
                    Text("Position fehlt").font(.headline)
                }
                Label(target.kind.compactSelectionLabel, systemImage: target.kind.compactSelectionIcon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(target.kind.isCadastralPoint ? Color.blue : Color.orange)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(role: .destructive) { model.clearTarget() } label: {
                Image(systemName: "trash.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .background(.red.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel("Ziel löschen")
        }
        .padding(.top, 1)
    }

    private func navigationContent(parcel: ParcelInfo, target: BoundaryTarget) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                if let direction = model.targetTurn ?? model.targetBearing {
                    NavigationArrow(direction: direction, size: 40)
                        .accessibilityLabel(turnHint(model.targetTurn))
                }
                VStack(alignment: .leading, spacing: 1) {
                    if let distance = model.targetDistance {
                        NavigationDistanceReadout(distance: distance)
                    } else {
                        Text("Position fehlt").font(.headline)
                    }
                    Text(navigationDirectionText)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                .layoutPriority(1)
                Spacer(minLength: 4)
                if let offset = model.targetOffset {
                    Grid(alignment: .trailing, horizontalSpacing: 3, verticalSpacing: 2) {
                        GridRow {
                            Text(String(format: "%.3f", locale: Locale.current, abs(offset.east)))
                            Text("m").foregroundStyle(.secondary)
                            Text(offset.east >= 0 ? "Ost" : "West")
                                .gridColumnAlignment(.leading)
                        }
                        GridRow {
                            Text(String(format: "%.3f", locale: Locale.current, abs(offset.north)))
                            Text("m").foregroundStyle(.secondary)
                            Text(offset.north >= 0 ? "Nord" : "Süd")
                                .gridColumnAlignment(.leading)
                        }
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                }
            }

            HStack(spacing: 8) {
                Label(
                    "Ausgewählt · \(parcel.number) · \(target.kind.label)",
                    systemImage: "checkmark.circle.fill"
                )
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(.blue, in: Capsule())
                    .layoutPriority(1)
                if let point = model.cadastralBoundaryPoint(for: target) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(point.markStatus == .marked ? Color.green : Color.orange)
                            .frame(width: 9, height: 9)
                        Text(point.navigationLabel)
                            .lineLimit(1)
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(point.markStatus == .marked ? .green : .orange)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(
                        (point.markStatus == .marked ? Color.green : Color.orange).opacity(0.15),
                        in: Capsule()
                    )
                }
            }

            if sheetLevel == .details {
                if model.ble.state.isConnected {
                    Label(
                        model.roverMeasurementReadinessLabel,
                        systemImage: model.roverMeasurementReady
                            ? "checkmark.seal.fill" : "angle"
                    )
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(model.roverMeasurementReady ? .green : .orange)
                }
                if let point = model.cadastralBoundaryPoint(for: target),
                   let accuracy = point.accuracyLabel {
                    Text("ALKIS · \(accuracy)")
                        .font(.system(size: 15).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                Button("Punkt messen") {
                    model.setInteractionMode(.distance)
                    model.startOrCancelPointCapture()
                }
                .buttonStyle(FilledCapsuleButtonStyle())
                Button("Ziel") { model.beginBoundaryTargetSelection() }
                    .buttonStyle(SecondaryCapsuleButtonStyle())
                    .frame(width: 96)
                Button(role: .destructive) { model.clearTarget() } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 52, height: 52)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .background(.red.opacity(0.16), in: RoundedRectangle(cornerRadius: 15))
                .accessibilityLabel("Ziel löschen")
            }
        }
        .padding(.top, 1)
    }

    private var navigationDirectionText: String {
        if let turn = model.targetTurn { return turnHint(turn) }
        if let bearing = model.targetBearing {
            return String(
                format: "Peilung %.1f° %@",
                locale: Locale.current,
                bearing,
                cardinalDirection(bearing)
            )
        }
        return "Kompass wird ermittelt"
    }

    @ViewBuilder private var boundaryPointStatus: some View {
        switch model.boundaryPointLoadState {
        case .idle:
            EmptyView()
        case .loading:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Amtliche Grenzpunkte werden geladen …")
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.white.opacity(0.82))
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
        case .loaded:
            let marked = model.cadastralBoundaryPoints.filter { $0.markStatus == .marked }.count
            if model.cadastralBoundaryPoints.isEmpty {
                Label("Nur Katasterpunkte aus Geometrie verfügbar", systemImage: "circle.dashed")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 21, weight: .semibold))
                    Text(
                        "ALKIS · \(model.cadastralBoundaryPoints.count) Grenzpunkte · \(marked) vermarkt"
                    )
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                }
                .foregroundStyle(marked > 0 ? .green : .orange)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(
                    (marked > 0 ? Color.green : Color.orange).opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 13)
                )
            }
        case .unavailable(let message):
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 20, weight: .semibold))
                Text("ALKIS nicht verfügbar · Katasterpunkte aus Geometrie")
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .foregroundStyle(.orange)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 13))
            .accessibilityHint(message)
        }
    }

    private func parcelSummary(_ parcel: ParcelInfo) -> String {
        var parts = ["Flur \(parcel.section)", "Nr. \(parcel.number)"]
        if let area = parcel.area { parts.append(String(format: "%.0f m²", area)) }
        return parts.joined(separator: " · ")
    }

    private func cardinalDirection(_ bearing: Double) -> String {
        let directions = ["N", "NO", "O", "SO", "S", "SW", "W", "NW"]
        let index = Int((bearing + 22.5) / 45).quotientAndRemainder(dividingBy: 8).remainder
        return directions[index]
    }

    private func turnHint(_ turn: Double?) -> String {
        guard let turn else { return "Kompass wird ermittelt" }
        if abs(turn) < 8 { return "geradeaus" }
        return String(format: "%.0f° %@", abs(turn), turn > 0 ? "rechts" : "links")
    }
}

// MARK: - iPad map layout

private extension MapScreen {
    func iPadMapLayout(in geometry: GeometryProxy) -> some View {
        HStack(spacing: 0) {
            if iPadSidebarIsVisible {
                iPadParcelSidebar
                    .frame(width: iPadSidebarWidth(for: geometry.size.width))
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .zIndex(2)
            }

            iPadMapCanvas(in: geometry)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .background(Color(uiColor: .systemBackground))
        .animation(.snappy, value: iPadSidebarIsVisible)
    }

    func iPadSidebarWidth(for availableWidth: CGFloat) -> CGFloat {
        availableWidth >= 1_000 ? 352 : 320
    }

    func iPadMapCanvas(in geometry: GeometryProxy) -> some View {
        ZStack {
            MapLibreMapView(model: model, ornamentLayout: .pad)
                .ignoresSafeArea()

            if activeControlPopup != nil {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.snappy) { activeControlPopup = nil }
                    }
            }

            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    if !iPadSidebarIsVisible {
                        iPadCollapsedSidebarControls
                    }
                    Spacer(minLength: 16)
                    iPadTrailingMapControls
                }

                Spacer(minLength: 18)

                HStack(alignment: .bottom) {
                    iPadBottomMapCard(in: geometry.size)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 14)

            if model.isMapBusy {
                ProgressView()
                    .controlSize(.large)
                    .padding(18)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 0.5))
            }
        }
    }

    var iPadParcelSidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 15) {
                HStack(alignment: .center, spacing: 12) {
                    Text("Flurstücke")
                        .font(.system(size: 30, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .layoutPriority(1)
                    Spacer(minLength: 8)
                    Button {
                        searchIsFocused = false
                        activeControlPopup = nil
                        withAnimation(.snappy) { iPadSidebarIsVisible = false }
                    } label: {
                        Image(systemName: "chevron.backward")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 34, height: 34)
                            .background(.white.opacity(0.09), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Seitenleiste einklappen")
                }

                iPadSidebarSearchField
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 13)

            ScrollView(.vertical) {
                LazyVStack(spacing: 4) {
                    if model.recentParcels.isEmpty {
                        VStack(spacing: 14) {
                            Image(systemName: "map")
                                .font(.system(size: 30, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text("Flurstück auf der Karte antippen oder an der aktuellen Position laden.")
                                .font(.system(size: 15))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button("Flurstück an Position") {
                                model.loadParcelAtCurrentPosition()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 42)
                    } else {
                        ForEach(model.recentParcels) { parcel in
                            iPadParcelRow(parcel)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 18)
            }
            .scrollIndicators(.hidden)

            Divider().overlay(.white.opacity(0.10))
            iPadRoverStatusRow
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(width: 0.5)
        }
    }

    var iPadSidebarSearchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Adresse oder Flurstück", text: $model.searchText)
                .focused($searchIsFocused)
                .font(.system(size: 16))
                .textInputAutocapitalization(.words)
                .submitLabel(.search)
                .onSubmit {
                    model.search()
                    searchIsFocused = false
                }
            if model.isMapBusy {
                ProgressView().controlSize(.small)
            } else if !model.searchText.isEmpty {
                Button { model.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Suche leeren")
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 44)
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
    }

    func iPadParcelRow(_ parcel: ParcelInfo) -> some View {
        let isSelected = model.selectedParcel?.id == parcel.id
        return HStack(spacing: 4) {
            Button {
                model.selectParcel(parcel)
            } label: {
                HStack(spacing: 13) {
                    Image(systemName: isSelected ? "pentagon.fill" : "pentagon")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(isSelected ? .yellow : .secondary)
                        .frame(width: 44, height: 44)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(parcel.label)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(parcelSummary(parcel))
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            Button(role: .destructive) {
                withAnimation(.snappy) { model.removeRecentParcel(parcel) }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(width: 36, height: 36)
                    .background(.red.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(parcel.label) aus Liste löschen")
        }
        .padding(.horizontal, 12)
        .frame(height: 64)
        .background(
            isSelected ? Color.blue.opacity(0.22) : .clear,
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    var iPadRoverStatusRow: some View {
        Button {
            openTab(.rover)
        } label: {
            HStack(spacing: 13) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(model.ble.state.isConnected ? .green : .orange)
                    .frame(width: 42, height: 42)
                    .background(
                        (model.ble.state.isConnected ? Color.green : Color.orange).opacity(0.14),
                        in: Circle()
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.ble.state.isConnected ? "Rover verbunden" : "Rover getrennt")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(model.ntrip.state.isStreaming ? "SAPOS aktiv" : "SAPOS gestoppt")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Rover- und SAPOS-Einstellungen")
    }

    var iPadCollapsedSidebarControls: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.snappy) { iPadSidebarIsVisible = true }
            } label: {
                FloatingMapControl(systemImage: "chevron.forward")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Seitenleiste einblenden")

            Button {
                withAnimation(.snappy) {
                    activeControlPopup = activeControlPopup == .devices ? nil : .devices
                }
            } label: {
                iPadCompactPositionStatus
            }
            .buttonStyle(.plain)
            .overlay(alignment: .topLeading) {
                if activeControlPopup == .devices {
                    deviceSettingsPopup
                        .offset(y: 46)
                        .transition(.scale(scale: 0.92, anchor: .topLeading).combined(with: .opacity))
                }
            }
            .zIndex(4)
            .accessibilityLabel("Rover- und SAPOS-Einstellungen")
        }
    }

    var iPadCompactPositionStatus: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(positionStatusColor)
                .frame(width: 9, height: 9)
            Text(positionAccuracyText)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(.white)
            Rectangle()
                .fill(.white.opacity(0.28))
                .frame(width: 1, height: 14)
            Text(model.ntrip.state.isStreaming ? "SAPOS" : "ohne SAPOS")
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
        }
        .font(.system(size: 15))
        .padding(.horizontal, 13)
        .frame(height: 38)
        .background(.ultraThinMaterial, in: Capsule())
        .background(Color.black.opacity(0.38), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.10), lineWidth: 0.5))
    }

    @ViewBuilder var iPadTrailingMapControls: some View {
        if model.boundaryTarget != nil && model.interactionMode == .inspect {
            iPadNavigationMapControls
        } else {
            iPadStandardMapControls
        }
    }

    var iPadStandardMapControls: some View {
        VStack(spacing: 12) {
            Button {
                withAnimation(.snappy) {
                    activeControlPopup = activeControlPopup == .interaction ? nil : .interaction
                }
            } label: {
                FloatingMapControl(
                    systemImage: model.interactionMode.systemImage,
                    foreground: model.interactionMode == .inspect ? .yellow : .white
                )
            }
            .buttonStyle(.plain)
            .overlay(alignment: .topTrailing) {
                if activeControlPopup == .interaction {
                    interactionModePopup
                        .offset(x: -60)
                        .transition(.scale(scale: 0.92, anchor: .topTrailing).combined(with: .opacity))
                }
            }
            .zIndex(3)

            iPadLayerButton

            Button {
                activeControlPopup = nil
                model.centerOnCurrentPosition()
            } label: {
                FloatingMapControl(systemImage: "location.fill", isProminent: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Auf Position zentrieren")

            iPadZoomControl
        }
    }

    var iPadNavigationMapControls: some View {
        VStack(spacing: 12) {
            Button {
                activeControlPopup = nil
                model.centerOnTarget()
            } label: {
                FloatingMapControl(systemImage: "scope")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Auf Ziel zentrieren")

            iPadLayerButton

            Button {
                activeControlPopup = nil
                model.centerOnCurrentPosition()
            } label: {
                FloatingMapControl(systemImage: "location.fill", isProminent: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Auf Position zentrieren")

            Button {
                activeControlPopup = nil
                openTab(.rover)
            } label: {
                FloatingMapControl(systemImage: "antenna.radiowaves.left.and.right")
                    .overlay(alignment: .topTrailing) {
                        Circle()
                            .fill(model.ble.state.isConnected ? Color.green : Color.orange)
                            .frame(width: 13, height: 13)
                            .overlay(Circle().stroke(Color.black.opacity(0.55), lineWidth: 2))
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.ble.state.isConnected ? "Rover verbunden" : "Rover getrennt")
        }
    }

    var iPadLayerButton: some View {
        Button {
            withAnimation(.snappy) {
                activeControlPopup = activeControlPopup == .layers ? nil : .layers
            }
        } label: {
            FloatingMapControl(systemImage: "square.3.layers.3d")
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if activeControlPopup == .layers {
                mapLayerPopup
                    .offset(x: -60)
                    .transition(.scale(scale: 0.92, anchor: .topTrailing).combined(with: .opacity))
            }
        }
        .zIndex(2)
        .accessibilityLabel("Kartenlayer: \(model.mapBackgroundLayer.title)")
    }

    var iPadZoomControl: some View {
        VStack(spacing: 0) {
            Button { model.zoomMap(by: 1) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 48, height: 46)
            }
            .accessibilityLabel("Vergrößern")
            Divider().overlay(.white.opacity(0.12)).padding(.horizontal, 10)
            Button { model.zoomMap(by: -1) } label: {
                Image(systemName: "minus")
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 48, height: 46)
            }
            .accessibilityLabel("Verkleinern")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .frame(width: 48)
        .fixedSize(horizontal: true, vertical: true)
        .background(.ultraThinMaterial, in: Capsule())
        .background(Color.black.opacity(0.48), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.10), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.45), radius: 9, y: 5)
    }

    @ViewBuilder func iPadBottomMapCard(in availableSize: CGSize) -> some View {
        if model.interactionMode == .distance || model.interactionMode == .area
            || model.interactionMode == .elevation || model.interactionMode == .target {
            mapBottomSheet(height: iPadWorkspaceCardHeight(in: availableSize))
                .frame(width: min(590, availableSize.width * 0.62))
        } else if let parcel = model.selectedParcel, let target = model.boundaryTarget {
            iPadNavigationCard(parcel: parcel, target: target)
                .frame(width: min(500, availableSize.width * 0.58))
        } else if let parcel = model.selectedParcel {
            iPadParcelInspector(parcel)
                .frame(width: min(430, availableSize.width * 0.54))
        } else {
            mapBottomSheet(height: 188)
                .frame(width: min(470, availableSize.width * 0.58))
        }
    }

    func iPadWorkspaceCardHeight(in availableSize: CGSize) -> CGFloat {
        if model.interactionMode == .target { return min(190, availableSize.height * 0.28) }
        return min(360, availableSize.height * 0.48)
    }

    func iPadParcelInspector(_ parcel: ParcelInfo) -> some View {
        let marked = model.cadastralBoundaryPoints.filter { $0.markStatus == .marked }.count
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(parcel.label)
                        .font(.system(size: 24, weight: .bold))
                        .lineLimit(1)
                    Text(parcelSummary(parcel))
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 10)
                Image(systemName: "lock.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }

            HStack(spacing: 10) {
                MetricTile(title: "Grenzpunkte", value: "\(model.cadastralBoundaryPoints.count)")
                MetricTile(title: "vermarkt", value: "\(marked)", valueColor: .orange)
                MetricTile(
                    title: "Umfang",
                    value: String(format: "%.0f m", parcelPerimeter(parcel))
                )
            }

            if iPadShowsParcelDetails {
                boundaryPointStatus
                HStack(spacing: 16) {
                    MapLegendRow(color: .green, text: "vermarkt")
                    MapLegendRow(color: .orange, text: "ohne Marke")
                }
                .font(.system(size: 14))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(spacing: 10) {
                Button("Ziel wählen") {
                    model.beginBoundaryTargetSelection()
                }
                .buttonStyle(FilledCapsuleButtonStyle())

                Button(iPadShowsParcelDetails ? "Weniger" : "Details") {
                    withAnimation(.snappy) { iPadShowsParcelDetails.toggle() }
                }
                .buttonStyle(SecondaryCapsuleButtonStyle())
            }
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background(
            Color.black.opacity(0.56),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.46), radius: 20, y: 8)
    }

    func iPadNavigationCard(parcel: ParcelInfo, target: BoundaryTarget) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 15) {
                if let direction = model.targetTurn ?? model.targetBearing {
                    NavigationArrow(direction: direction, size: 62)
                        .accessibilityLabel(turnHint(model.targetTurn))
                }

                VStack(alignment: .leading, spacing: 0) {
                    if let distance = model.targetDistance {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(String(format: "%.3f", locale: Locale.current, distance))
                                .font(.system(size: 46, weight: .bold, design: .rounded))
                                .monospacedDigit()
                            Text("m")
                                .font(.system(size: 23, weight: .bold, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    } else {
                        Text("Position fehlt")
                            .font(.system(size: 24, weight: .bold))
                    }
                    Text(navigationDirectionText)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .layoutPriority(1)

                Spacer(minLength: 6)

                if let offset = model.targetOffset {
                    Grid(alignment: .trailing, horizontalSpacing: 3, verticalSpacing: 3) {
                        GridRow {
                            Text(String(format: "%.3f", locale: Locale.current, abs(offset.east)))
                            Text("m").foregroundStyle(.secondary)
                            Text(offset.east >= 0 ? "Ost" : "West")
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.leading)
                        }
                        GridRow {
                            Text(String(format: "%.3f", locale: Locale.current, abs(offset.north)))
                            Text("m").foregroundStyle(.secondary)
                            Text(offset.north >= 0 ? "Nord" : "Süd")
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.leading)
                        }
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .monospacedDigit()
                    .fixedSize()
                }
            }

            HStack(spacing: 9) {
                Label(
                    target.kind.isCadastralPoint
                        ? "Punkt gewählt · \(parcel.number) · \(target.kind.label)"
                        : "Grenzlinie gewählt · \(parcel.number)",
                    systemImage: target.kind.isCadastralPoint
                        ? "checkmark.circle.fill" : "line.diagonal"
                )
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(
                        target.kind.isCadastralPoint ? Color.blue : Color.orange,
                        in: Capsule()
                    )
                    .layoutPriority(1)

                if let point = model.cadastralBoundaryPoint(for: target) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(point.markStatus == .marked ? Color.green : Color.orange)
                            .frame(width: 9, height: 9)
                        Text(point.navigationLabel)
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(point.markStatus == .marked ? .green : .orange)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(
                        (point.markStatus == .marked ? Color.green : Color.orange).opacity(0.14),
                        in: Capsule()
                    )
                }
            }

            HStack(spacing: 10) {
                Button("Punkt messen") {
                    model.setInteractionMode(.distance)
                    model.startOrCancelPointCapture()
                }
                .buttonStyle(FilledCapsuleButtonStyle())

                Button("Ziel") {
                    model.beginBoundaryTargetSelection()
                }
                .buttonStyle(SecondaryCapsuleButtonStyle())
                .frame(width: 105)

                Button(role: .destructive) {
                    model.clearTarget()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 52, height: 52)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .background(.red.opacity(0.16), in: RoundedRectangle(cornerRadius: 15))
                .accessibilityLabel("Ziel löschen")
            }
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background(
            Color.black.opacity(0.58),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.48), radius: 20, y: 8)
    }
}

private enum MapSheetLevel: Int {
    case collapsed
    case standard
    case details
}

private enum MapControlPopup: Equatable {
    case devices
    case interaction
    case layers
}

private extension BoundaryTargetKind {
    var isCadastralPoint: Bool { self != .edge }

    var compactSelectionLabel: String {
        switch self {
        case .vertex: return "Katasterpunkt ausgewählt"
        case .marker: return "Amtlicher Katasterpunkt ausgewählt"
        case .edge: return "Punkt auf Grenzlinie ausgewählt"
        }
    }

    var compactSelectionIcon: String {
        isCadastralPoint ? "checkmark.circle.fill" : "line.diagonal"
    }
}

private extension MapInteractionMode {
    var systemImage: String {
        switch self {
        case .inspect: return "map"
        case .target: return "scope"
        case .distance: return "point.topleft.down.to.point.bottomright.curvepath"
        case .area: return "circle.dashed"
        case .elevation: return "mountain.2"
        }
    }

    var popupSystemImage: String {
        switch self {
        case .inspect: return "map.fill"
        case .target: return "scope"
        case .distance: return "ruler.fill"
        case .area: return "square.dashed"
        case .elevation: return "mountain.2.fill"
        }
    }
}

private struct FloatingMapControl: View {
    let systemImage: String
    var foreground = Color.white
    var isProminent = false

    var body: some View {
        ZStack {
            Circle().fill(isProminent ? Color.blue : Color.black.opacity(0.52))
            if !isProminent { Circle().fill(.ultraThinMaterial) }
            Image(systemName: systemImage)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(foreground)
        }
        .frame(width: 48, height: 48)
        .overlay(Circle().stroke(.white.opacity(isProminent ? 0 : 0.10), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.45), radius: 9, y: 5)
        .contentShape(Circle())
    }
}

private struct FilledCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                Color.blue.opacity(configuration.isPressed ? 0.72 : 1),
                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

private struct SecondaryCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.blue)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                Color(uiColor: .tertiarySystemFill)
                    .opacity(configuration.isPressed ? 0.72 : 1),
                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    var valueColor = Color.primary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(valueColor)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct SectionEyebrow: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 13, weight: .medium))
            .tracking(1.0)
            .foregroundStyle(.secondary)
    }
}

private struct MapLegendRow: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .stroke(color, lineWidth: 3)
                .frame(width: 13, height: 13)
            Text(text).font(.system(size: 16))
        }
    }
}

private struct NavigationDistanceReadout: View {
    let distance: Double

    var body: some View {
        Text(String(format: "%.3f m", locale: Locale.current, distance))
            .font(.system(size: 30, weight: .bold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
        .accessibilityElement(children: .combine)
    }
}

private struct NavigationArrow: View {
    let direction: Double
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(.blue)
            Image(systemName: "location.north.fill")
                .font(.system(size: size * 0.48, weight: .bold))
                .foregroundStyle(.white)
                .rotationEffect(.degrees(direction))
        }
        .frame(width: size, height: size)
    }
}

private struct AppSurfaceCard<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                Color(uiColor: .secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
    }
}

private struct AppStatusBadge: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(text).font(.system(size: 15, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(color == .gray ? .secondary : color)
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
        .background(color.opacity(color == .gray ? 0.12 : 0.15), in: Capsule())
    }
}

private struct PanelCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.09), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Schließen")
    }
}

private struct RoverRedesignScreen: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var manager: BLERoverManager
    let onClose: () -> Void
    @State private var gnssDetailsAreExpanded = false
    @State private var rtcmDetailsAreExpanded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center) {
                        Text("Rover")
                            .font(.system(size: 34, weight: .bold))
                        Spacer()
                        if manager.imuState.isSimulation {
                            AppStatusBadge(color: .orange, text: "Testmodus")
                        } else {
                            AppStatusBadge(
                                color: manager.state.isConnected ? .green : .gray,
                                text: manager.state.isConnected ? "verbunden" : "getrennt"
                            )
                        }
                        PanelCloseButton(action: onClose)
                    }

                    connectionCard

                    SectionEyebrow("GNSS").padding(.leading, 4)
                    gnssCard

                    SectionEyebrow("Stabneigung").padding(.leading, 4)
                    poleCard

                    settingsCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .background(Color.black.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var connectionCard: some View {
        AppSurfaceCard {
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(.white.opacity(0.08))
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 21, weight: .medium))
                            .foregroundStyle(manager.state.isConnected ? .blue : .secondary)
                    }
                    .frame(width: 42, height: 42)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(roverConnectionTitle)
                            .font(.system(size: 19, weight: .semibold))
                        Text("KRover · BLE")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Button(roverConnectionButtonTitle) {
                    if manager.state.isConnected || manager.state == .scanning {
                        manager.disconnect()
                    } else if case .connecting = manager.state {
                        manager.disconnect()
                    } else {
                        manager.connect()
                    }
                }
                .buttonStyle(FilledCapsuleButtonStyle())
            }
        }
    }

    private var gnssCard: some View {
        AppSurfaceCard {
            VStack(spacing: 0) {
                RoverValueRow(
                    title: "Fix",
                    value: manager.latestPosition?.fixQuality.rawValue ?? "keine NMEA-Daten",
                    valueColor: manager.latestPosition?.fixQuality == .rtkFixed ? .green : .secondary
                )
                Divider().overlay(.white.opacity(0.10))
                RoverValueRow(
                    title: "Satelliten",
                    value: manager.latestPosition.map { "\($0.satellites)" } ?? "–"
                )
                if let position = manager.latestPosition {
                    Divider().overlay(.white.opacity(0.10))
                    DisclosureGroup(isExpanded: $gnssDetailsAreExpanded) {
                        VStack(spacing: 10) {
                            RoverValueRow(
                                title: "Breite",
                                value: String(
                                    format: "%.9f°",
                                    locale: Locale.current,
                                    position.coordinate.latitude
                                ),
                                compact: true
                            )
                            RoverValueRow(
                                title: "Länge",
                                value: String(
                                    format: "%.9f°",
                                    locale: Locale.current,
                                    position.coordinate.longitude
                                ),
                                compact: true
                            )
                            if let sigma = position.horizontalSigma {
                                RoverValueRow(
                                    title: "σ horizontal",
                                    value: String(
                                        format: "%.3f m",
                                        locale: Locale.current,
                                        sigma
                                    ),
                                    compact: true
                                )
                            }
                        }
                        .padding(.top, 10)
                    } label: {
                        Text("GNSS-Details")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .padding(.vertical, 13)
                }
            }
        }
    }

    private var roverConnectionTitle: String {
        switch manager.state {
        case .scanning: return "Rover wird gesucht …"
        case .connecting: return "Rover wird verbunden …"
        case .connected: return "Rover verbunden"
        default: return "Rover getrennt"
        }
    }

    private var roverConnectionButtonTitle: String {
        switch manager.state {
        case .scanning: return "Suche abbrechen"
        case .connecting: return "Verbindung abbrechen"
        case .connected: return "Rover trennen"
        default: return "Rover suchen"
        }
    }

    @ViewBuilder private var poleCard: some View {
        AppSurfaceCard {
            if manager.imuState.isAvailable {
                HStack(spacing: 14) {
                    VStack(spacing: 6) {
                        PoleGuidanceView(
                            correction: PoleCorrection(imu: manager.imuState),
                            isLevel: manager.imuState.isLevel,
                            isReady: manager.imuState.measurementReady
                        )
                        .frame(width: 110, height: 110)
                        HousingMarkBadge()
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(imuReadinessText)
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(manager.imuState.measurementReady ? .green : .orange)
                        Text(
                            String(
                                format: "%.2f°",
                                locale: Locale.current,
                                manager.imuState.totalTiltDegrees
                            )
                        )
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        Text("Blase in den Ring bringen · Stablänge \(poleLengthText)")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "angle")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Noch keine IMU-Daten")
                            .font(.system(size: 19, weight: .semibold))
                        Text("Rover verbinden, um die Stabneigung anzuzeigen.")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var settingsCard: some View {
        AppSurfaceCard {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("Stablänge").font(.system(size: 17))
                    Spacer()
                    Text(poleLengthText)
                        .font(.system(size: 17, weight: .semibold))
                        .monospacedDigit()
                    Stepper("", value: $model.poleLengthMeters, in: 0.5...5.0, step: 0.05)
                        .labelsHidden()
                        .fixedSize()
                }
                .padding(.vertical, 2)

                Divider().overlay(.white.opacity(0.10)).padding(.vertical, 12)

                NavigationLink {
                    CalibrationRedesignScreen(manager: manager)
                } label: {
                    HStack {
                        Text("Kalibrierung")
                            .font(.system(size: 17))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(calibrationShortStatus)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(calibrationStatusColor)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Divider().overlay(.white.opacity(0.10)).padding(.vertical, 12)

                DisclosureGroup(isExpanded: $rtcmDetailsAreExpanded) {
                    VStack(spacing: 10) {
                        RoverValueRow(title: "Bytes", value: "\(manager.roverStatus.rtcmBytes)", compact: true)
                        RoverValueRow(title: "gültige Frames", value: "\(manager.roverStatus.rtcmFrames)", compact: true)
                        RoverValueRow(title: "CRC-Fehler", value: "\(manager.roverStatus.crcErrors)", compact: true)
                        RoverValueRow(title: "Sequenzlücken", value: "\(manager.roverStatus.sequenceGaps)", compact: true)
                        RoverValueRow(title: "BLE-Warteschlange", value: "\(manager.pendingRTCMChunks)", compact: true)
                        Button("Zähler zurücksetzen") { manager.resetRoverStatistics() }
                            .buttonStyle(.bordered)
                            .disabled(!manager.state.isConnected)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.top, 12)
                } label: {
                    Text("RTCM-Statistik").font(.system(size: 17))
                }
            }
        }
    }

    private var poleLengthText: String {
        String(format: "%.2f m", locale: Locale.current, model.poleLengthMeters)
    }

    private var calibrationShortStatus: String {
        let state = manager.imuState
        if state.isCalibrated && state.hasDirectionCalibration { return "bereit" }
        if state.isCalibrated { return "Strich nötig" }
        return "nötig"
    }

    private var calibrationStatusColor: Color {
        manager.imuState.isCalibrated && manager.imuState.hasDirectionCalibration
            ? .green : .orange
    }

    private var imuReadinessText: String {
        let state = manager.imuState
        if state.calibrationState == .calibrating { return "Nulllage wird kalibriert" }
        if state.calibrationState == .aligning { return "Gehäusestrich wird kalibriert" }
        if !state.isCalibrated { return "Nulllage kalibrieren" }
        if !state.hasDirectionCalibration { return "Gehäusestrich kalibrieren" }
        if state.isMoving { return "Stab ruhig halten" }
        if !state.isLevel { return PoleCorrection(imu: state).instruction }
        if !state.measurementReady { return "Stab kurz ruhig halten" }
        return "Messbereit"
    }
}

private struct RoverValueRow: View {
    let title: String
    let value: String
    var valueColor = Color.primary
    var compact = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: compact ? 15 : 17))
                .foregroundStyle(compact ? .secondary : .primary)
            Spacer()
            Text(value)
                .font(.system(size: compact ? 15 : 17, weight: .semibold))
                .foregroundStyle(valueColor)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .lineLimit(compact ? 1 : 2)
                .minimumScaleFactor(0.72)
        }
        .padding(.vertical, compact ? 0 : 13)
    }
}

private struct HousingMarkBadge: View {
    var body: some View {
        HStack(spacing: 6) {
            Capsule().fill(.orange).frame(width: 3, height: 14)
            Text("Strich zu dir")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.orange.opacity(0.16), in: Capsule())
    }
}

private struct CalibrationRedesignScreen: View {
    @ObservedObject var manager: BLERoverManager
    @State private var confirmsReset = false

    var body: some View {
        Group {
            switch manager.imuState.calibrationState {
            case .calibrating:
                verticalCalibrationProgress
            case .aligning:
                directionCalibrationProgress
            case .required, .ready:
                calibrationOverview
            }
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Kalibrierung")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .confirmationDialog(
            "Kalibrierung wirklich löschen?",
            isPresented: $confirmsReset,
            titleVisibility: .visible
        ) {
            Button("Kalibrierung löschen", role: .destructive) {
                manager.resetIMUCalibration()
            }
        } message: {
            Text("Nulllage und Gehäusestrich müssen danach neu eingelernt werden.")
        }
    }

    private var calibrationOverview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Beide Schritte sind voneinander unabhängig und einzeln wiederholbar.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)

                AppSurfaceCard {
                    VStack(spacing: 14) {
                        HStack(spacing: 14) {
                            LevelCalibrationIllustration()
                                .frame(width: 76, height: 76)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text("Nulllage")
                                        .font(.system(size: 19, weight: .semibold))
                                    CalibrationStatusPill(
                                        isComplete: manager.imuState.isCalibrated
                                    )
                                }
                                Text("Rover vom Stab nehmen. Das Gehäuse muss exakt waagerecht stehen – Fläche vorher prüfen.")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button(
                            manager.imuState.isCalibrated
                                ? "Nulllage neu messen" : "Nulllage messen"
                        ) {
                            manager.calibrateIMU()
                        }
                        .buttonStyle(FilledCapsuleButtonStyle())
                        .disabled(!manager.state.isConnected || !manager.imuState.isAvailable)
                    }
                }

                AppSurfaceCard {
                    VStack(spacing: 14) {
                        HStack(spacing: 14) {
                            DirectionCalibrationIllustration()
                                .frame(width: 76, height: 76)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text("Gehäusestrich")
                                        .font(.system(size: 19, weight: .semibold))
                                    CalibrationStatusPill(
                                        isComplete: manager.imuState.hasDirectionCalibration
                                    )
                                }
                                Text("Strich zu dir drehen und den Stabkopf zu dir kippen. Stab bleibt montiert.")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button(
                            manager.imuState.hasDirectionCalibration
                                ? "Strich neu einlernen" : "Gehäusestrich einlernen"
                        ) {
                            manager.calibrateIMUDirection()
                        }
                        .buttonStyle(SecondaryCapsuleButtonStyle())
                        .disabled(
                            !manager.state.isConnected
                                || !manager.imuState.isAvailable
                                || !manager.imuState.isCalibrated
                        )
                    }
                }

                Button(role: .destructive) { confirmsReset = true } label: {
                    Text("Kalibrierung löschen")
                        .font(.system(size: 17))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(
                            Color(uiColor: .secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 18)
                        )
                }
                .buttonStyle(.plain)
                .disabled(
                    !manager.state.isConnected
                        || (!manager.imuState.isCalibrated
                            && !manager.imuState.hasDirectionCalibration)
                )
            }
            .padding(16)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
    }

    private var verticalCalibrationProgress: some View {
        CalibrationProgressLayout(
            eyebrow: "Nulllage",
            graphic: AnyView(LevelCalibrationIllustration().frame(width: 240, height: 240)),
            title: "Gehäuse exakt waagerecht",
            subtitle: "Ohne Stab, frei auf geprüfter Fläche · nicht berühren",
            progress: min(1, Double(manager.imuState.calibrationSamples) / 125),
            progressText: "\(manager.imuState.calibrationSamples) / 125 Werte",
            detailText: String(
                format: "Abweichung %.2f°",
                locale: Locale.current,
                manager.imuState.totalTiltDegrees
            ),
            detailColor: .green,
            warning: "Eine schiefe Fläche oder ein montierter Stab speichern eine falsche Nulllage – der Fehler steckt danach in jeder Messung.",
            cancel: manager.resetIMUCalibration
        )
    }

    private var directionCalibrationProgress: some View {
        CalibrationProgressLayout(
            eyebrow: "Gehäusestrich",
            graphic: AnyView(
                VStack(spacing: 8) {
                    PoleGuidanceView(
                        correction: PoleCorrection(imu: manager.imuState),
                        isLevel: manager.imuState.isLevel,
                        isReady: manager.imuState.measurementReady
                    )
                    HousingMarkBadge()
                }
                .frame(width: 240, height: 258)
            ),
            title: "Neigung halten",
            subtitle: "Stabkopf zu dir kippen · Stab bleibt montiert",
            progress: min(1, Double(manager.imuState.calibrationSamples) / 30),
            progressText: "\(manager.imuState.calibrationSamples) / 30 Werte",
            detailText: String(
                format: "%.1f° zu dir",
                locale: Locale.current,
                abs(PoleCorrection(imu: manager.imuState).deviationTowardUserDegrees)
            ),
            detailColor: .primary,
            warning: nil,
            auxiliaryTitle: manager.imuState.isSimulation ? "Neigung simulieren" : nil,
            auxiliaryAction: manager.imuState.isSimulation
                ? { manager.setIMUSimulationMode("forward") } : nil,
            cancel: manager.resetIMUCalibration
        )
    }
}

private struct CalibrationStatusPill: View {
    let isComplete: Bool

    var body: some View {
        Text(isComplete ? "gespeichert" : "nötig")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isComplete ? .green : .orange)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(
                (isComplete ? Color.green : Color.orange).opacity(0.16),
                in: Capsule()
            )
    }
}

private struct CalibrationProgressLayout: View {
    let eyebrow: String
    let graphic: AnyView
    let title: String
    let subtitle: String
    let progress: Double
    let progressText: String
    let detailText: String
    let detailColor: Color
    let warning: String?
    var auxiliaryTitle: String?
    var auxiliaryAction: (() -> Void)?
    let cancel: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SectionEyebrow(eyebrow)
                    .frame(maxWidth: .infinity, alignment: .leading)
                graphic
                VStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(detailColor == .green ? .green : .primary)
                    Text(subtitle)
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                VStack(spacing: 8) {
                    ProgressView(value: progress)
                        .tint(detailColor == .green ? .blue : .green)
                    HStack {
                        Text(progressText)
                        Spacer()
                        Text(detailText).foregroundStyle(detailColor)
                    }
                    .font(.system(size: 15, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                if let warning {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(warning)
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                }
                if let auxiliaryTitle, let auxiliaryAction {
                    Button(auxiliaryTitle, action: auxiliaryAction)
                        .buttonStyle(.bordered)
                }
                Button("Abbrechen", role: .destructive, action: cancel)
                    .buttonStyle(SecondaryCapsuleButtonStyle())
                    .foregroundStyle(.red)
                    .padding(.top, 6)
            }
            .padding(20)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct LevelCalibrationIllustration: View {
    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack(alignment: .bottom) {
                Rectangle()
                    .fill(.secondary.opacity(0.35))
                    .frame(height: max(2, side * 0.025))
                    .offset(y: -side * 0.05)
                RoundedRectangle(cornerRadius: side * 0.12)
                    .fill(.white.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: side * 0.12)
                            .stroke(.white.opacity(0.90), lineWidth: max(1.5, side * 0.025))
                    )
                    .frame(width: side * 0.38, height: side * 0.56)
                    .offset(y: -side * 0.07)
                Capsule()
                    .fill(.orange)
                    .frame(width: max(3, side * 0.035), height: side * 0.34)
                    .offset(x: side * 0.11, y: -side * 0.13)
                Circle()
                    .fill(.green)
                    .overlay(Circle().stroke(.white, lineWidth: max(1, side * 0.015)))
                    .frame(width: side * 0.09, height: side * 0.09)
                    .offset(y: -side * 0.60)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }
}

private struct DirectionCalibrationIllustration: View {
    var body: some View {
        ZStack {
            Circle().fill(.white.opacity(0.08))
            Circle().stroke(.white.opacity(0.18), lineWidth: 1)
            Circle()
                .stroke(.white.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                .frame(width: 25, height: 25)
            Capsule().fill(.orange).frame(width: 5, height: 18).offset(y: 34)
            Circle()
                .fill(.green)
                .overlay(Circle().stroke(.white, lineWidth: 1.5))
                .frame(width: 18, height: 18)
                .offset(y: 18)
        }
        .padding(7)
        .accessibilityHidden(true)
    }
}

private struct PoleGuidanceView: View {
    let correction: PoleCorrection
    let isLevel: Bool
    let isReady: Bool

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let travel = side * 0.30
            let x = CGFloat(max(-1, min(1, correction.deviationRightDegrees / 5))) * travel
            let y = CGFloat(max(-1, min(1, correction.deviationTowardUserDegrees / 5))) * travel

            ZStack {
                Circle().fill(.white.opacity(0.07))
                Circle().stroke(.white.opacity(0.18), lineWidth: 1.5)
                Rectangle().fill(.white.opacity(0.11)).frame(width: 1, height: side * 0.82)
                Rectangle().fill(.white.opacity(0.11)).frame(width: side * 0.82, height: 1)
                Circle()
                    .stroke(
                        isLevel ? Color.green.opacity(0.75) : Color.white.opacity(0.28),
                        style: StrokeStyle(lineWidth: 1.2, dash: [2, 3])
                    )
                    .frame(width: side * 0.28, height: side * 0.28)
                Image(systemName: "scope")
                    .font(.system(size: side * 0.17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                Capsule()
                    .fill(.orange)
                    .frame(width: max(5, side * 0.055), height: side * 0.18)
                    .offset(y: side * 0.48)
                Circle()
                    .fill(isReady ? Color.green : Color.orange)
                    .overlay(Circle().stroke(.white, lineWidth: max(1.2, side * 0.014)))
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
                    .frame(width: side * 0.20, height: side * 0.20)
                    .offset(x: x, y: y)
                Text("VOR")
                    .font(.system(size: max(8, side * 0.075), weight: .bold))
                    .foregroundStyle(.secondary)
                    .offset(y: -side * 0.39)
            }
            .frame(width: side * 0.88, height: side * 0.88)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(correction.instruction)
    }
}

private struct SAPOSRedesignScreen: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var client: NtripClient
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("SAPOS")
                        .font(.system(size: 34, weight: .bold))
                    Spacer()
                    AppStatusBadge(
                        color: client.state.isStreaming ? .green : .gray,
                        text: client.state.isStreaming ? "empfängt" : "gestoppt"
                    )
                    PanelCloseButton(action: onClose)
                }

                AppSurfaceCard {
                    VStack(spacing: 0) {
                        SAPOSFieldRow(title: "Caster", text: $model.saposHost)
                        Divider().overlay(.white.opacity(0.10))
                        SAPOSFieldRow(
                            title: "Port",
                            text: $model.saposPort,
                            keyboardType: .numberPad
                        )
                        Divider().overlay(.white.opacity(0.10))
                        SAPOSFieldRow(title: "Mountpoint", text: $model.saposMountpoint)
                        Divider().overlay(.white.opacity(0.10))
                        SAPOSFieldRow(title: "Benutzer", text: $model.saposUsername)
                        Divider().overlay(.white.opacity(0.10))
                        SAPOSFieldRow(title: "Passwort", text: $model.saposPassword, isSecure: true)
                    }
                }

                Button(client.state == .idle ? "SAPOS starten" : "SAPOS stoppen") {
                    client.state == .idle ? model.startSAPOS() : model.stopSAPOS()
                }
                .buttonStyle(FilledCapsuleButtonStyle())

                Link(destination: URL(string: "https://registrierung.saposnrw.de")!) {
                    Label("Kostenlosen SAPOS-NRW-Zugang registrieren", systemImage: "person.badge.plus")
                        .font(.system(size: 15, weight: .medium))
                }
                .padding(.horizontal, 4)

                SectionEyebrow("Empfang").padding(.leading, 4)
                HStack(spacing: 10) {
                    MetricTile(title: "RTCM", value: "\(client.statistics.bytes) B")
                    MetricTile(title: "Frames", value: "\(client.statistics.validFrames)")
                    MetricTile(
                        title: "CRC-Fehler",
                        value: "\(client.statistics.crcErrors)",
                        valueColor: client.statistics.crcErrors > 0 ? .orange : .primary
                    )
                }

                if let date = client.statistics.lastFrameAt {
                    AppSurfaceCard {
                        RoverValueRow(
                            title: "Letztes Frame",
                            value: date.formatted(date: .omitted, time: .standard)
                        )
                    }
                }

                Text("SAPOS startet automatisch mit dem Rover und stoppt beim Trennen.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .background(Color.black.ignoresSafeArea())
    }
}

private struct SAPOSFieldRow: View {
    let title: String
    @Binding var text: String
    var isSecure = false
    var keyboardType = UIKeyboardType.default

    var body: some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .frame(width: 95, alignment: .leading)
            if isSecure {
                SecureField(title, text: $text)
                    .multilineTextAlignment(.trailing)
            } else {
                TextField(title, text: $text)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(keyboardType)
                    .textInputAutocapitalization(title == "Mountpoint" ? .characters : .never)
                    .autocorrectionDisabled()
            }
        }
        .font(.system(size: 17, weight: .medium))
        .padding(.vertical, 14)
    }
}
