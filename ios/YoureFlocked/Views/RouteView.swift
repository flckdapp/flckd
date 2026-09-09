import SwiftUI
import MapKit
import UIKit
import Combine
import os

struct RouteView: View {
    @Environment(CameraStore.self) private var cameraStore
    @Environment(LocationManager.self) private var locationManager

    private let overpassService = OverpassService()
    private let valhallaService = ValhallaRoutingService()

    @State private var searchText: String = ""
    @State private var searchCompleter = SearchCompleter()
    @State private var recents: [RecentDestination] = RecentsStore.load()
    @FocusState private var searchFocused: Bool
    @State private var selectedPlace: MKMapItem?
    @State private var routeResult: RouteResult?
    @State private var routeCameras: [SurveillanceCamera] = []
    // Avoidance aggressiveness (slider in the result card). Persisted so the
    // preference sticks across launches. Raw value of AvoidanceLevel.
    @AppStorage("avoidanceLevel") private var avoidanceLevelRaw = AvoidanceLevel.balanced.rawValue
    @State private var lastRoutedLevel: Int = AvoidanceLevel.balanced.rawValue
    
    // State machine
    @State private var isCalculating = false
    @State private var calculationStatus: String?
    @State private var routeError: String?
    @State private var routeErrorNeedsRegion = false
    @State private var showOfflineRoutingSheet = false
    @State private var missingHomeRegion: USStateBounds?
    
    // Sheet control
    @State private var sheetDetent: PresentationDetent = .fraction(0.25)
    @State private var isSheetPresented = false
    
    @AppStorage("useMetric") private var useMetric: Bool = false
    #if DEBUG
    @AppStorage("showRoutingSpikeOverlay") private var showRoutingSpikeOverlay: Bool = false
    #endif
    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)

    private let cameraBufferMeters: Double = 35
    
    private let searchSubject = PassthroughSubject<String, Never>()

    var body: some View {
        Map(position: $cameraPosition) {
            UserAnnotation()

            ForEach(routeCameras) { camera in
                Annotation(camera.displayName, coordinate: camera.coordinate) {
                    CameraMarkerView(camera: camera)
                }
            }

            if let result = routeResult {
                MapPolyline(coordinates: result.coordinates)
                    .stroke(.white, lineWidth: 10)
                MapPolyline(coordinates: result.coordinates)
                    .stroke(Color(red: 0.0, green: 0.7, blue: 0.65), lineWidth: 7)
            }

            if let place = selectedPlace, let coord = place.placemark.location?.coordinate {
                Marker(place.name ?? "Destination", coordinate: coord)
                    .tint(Color(red: 0.0, green: 0.7, blue: 0.65))
            }
        }
        .mapStyle(.standard)
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .safeAreaInset(edge: .bottom) {
            // Spacer to push map controls up above the sheet
            Color.clear.frame(height: 80)
        }
        .overlay(alignment: .bottom) {
            // Swiping the panel away keeps the route; this pill floats above
            // the tab bar and brings the panel back in one tap.
            if let result = routeResult, !isSheetPresented {
                Button {
                    isSheetPresented = true
                    sheetDetent = .fraction(0.25)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.up")
                            .font(.caption.weight(.bold))
                        Text(selectedPlace?.name ?? "Route")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text("\u{00B7} \(formatTime(result.timeSeconds))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 8)
                .accessibilityLabel("Show route details")
            }
        }
        .safeAreaInset(edge: .top) {
            VStack(spacing: 8) {
                searchBar
                if let missing = missingHomeRegion, routeResult == nil, !isCalculating {
                    regionPreflightBanner(missing)
                }
                #if DEBUG
                if showRoutingSpikeOverlay {
                    HStack {
                        RoutingDebugOverlay(
                            destination: selectedPlace?.placemark.location?.coordinate
                        )
                        Spacer()
                    }
                    .padding(.horizontal)
                }
                #endif
            }
        }
        .sheet(isPresented: $isSheetPresented, onDismiss: {
            // Swiped away: drop keyboard focus so the sheet does not
            // immediately re-present, and reset to the collapsed detent
            // for the next presentation.
            searchFocused = false
            sheetDetent = .fraction(0.25)
        }) {
            sheetContent
                .presentationDetents(availableDetents, selection: $sheetDetent)
                .presentationBackgroundInteraction(.enabled)
                .presentationBackground(.regularMaterial)
                .presentationDragIndicator(.visible)
                // Swipe-down clears the panel so the tab bar stays reachable;
                // only lock it mid-calculation.
                .interactiveDismissDisabled(isCalculating)
        }
        .onChange(of: searchText) { _, newValue in
            if !newValue.isEmpty {
                if routeError != nil { routeError = nil }
                searchSubject.send(newValue)
                if routeResult == nil && !isCalculating {
                    isSheetPresented = true
                    sheetDetent = .fraction(0.6)
                }
            } else if routeResult == nil {
                // Cleared text: show recents while the field is focused,
                // otherwise put the sheet away.
                searchCompleter.results = []
                if !isCalculating && !searchFocused {
                    isSheetPresented = false
                }
            }
        }
        .onChange(of: searchFocused) { _, focused in
            // Tapping the field surfaces recents immediately, before typing.
            if focused && routeResult == nil && !isCalculating {
                recents = RecentsStore.load()
                isSheetPresented = true
                sheetDetent = .fraction(0.6)
            } else if focused && routeResult != nil && !isSheetPresented {
                // A route is active but its panel was swiped away; bring it
                // back rather than leaving the tap dead.
                isSheetPresented = true
                sheetDetent = .fraction(0.25)
            }
        }
        .onReceive(searchSubject.debounce(for: .milliseconds(250), scheduler: RunLoop.main)) { query in
            guard query.count >= 2 else { return }
            // Bias results toward the user when we have a fix, but don't
            // require one: searching must work before location resolves.
            let region: MKCoordinateRegion?
            if let location = locationManager.currentLocation {
                region = MKCoordinateRegion(
                    center: location.coordinate,
                    latitudinalMeters: 50_000,
                    longitudinalMeters: 50_000
                )
            } else {
                region = nil
            }
            searchCompleter.search(query, region: region)
        }
        .task {
            await waitAndRunRegionPreflight()
        }
        .onChange(of: showOfflineRoutingSheet) { _, showing in
            // Re-check after the download sheet closes: a fresh install
            // should clear the banner without leaving the tab.
            if !showing { updateRegionPreflight() }
        }
    }
    
    private var availableDetents: Set<PresentationDetent> {
        if routeResult != nil {
            return [.fraction(0.25), .fraction(0.6), .large]
        } else if isCalculating {
            return [.fraction(0.25)]
        } else {
            // Include a small detent so the panel can be collapsed out of the
            // way without being fully dismissed.
            return [.fraction(0.25), .fraction(0.6), .large]
        }
    }

    // MARK: - Region Preflight

    @ViewBuilder
    private func regionPreflightBanner(_ missing: USStateBounds) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(missing.name) isn\u{2019}t downloaded")
                    .font(.subheadline.weight(.semibold))
                Text("Route planning needs your state\u{2019}s road data on this device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Download") {
                // The offline-routing sheet is attached inside sheetContent,
                // so the results sheet must be live before it can present.
                if isSheetPresented {
                    showOfflineRoutingSheet = true
                } else {
                    isSheetPresented = true
                    sheetDetent = .fraction(0.6)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        showOfflineRoutingSheet = true
                    }
                }
            }
            .accessibilityIdentifier("preflight-download")
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(Color(red: 0.0, green: 0.7, blue: 0.65))
        }
        .padding(12)
        .background(.thickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 4, y: 2)
        .padding(.horizontal)
    }

    /// Cold start: wait briefly for the first GPS fix so the check runs
    /// against a real coordinate instead of silently doing nothing.
    private func waitAndRunRegionPreflight() async {
        for _ in 0..<20 where locationManager.currentLocation == nil {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        updateRegionPreflight()
    }

    private func updateRegionPreflight() {
        guard let coord = locationManager.currentLocation?.coordinate,
              let state = USStateBounds.region(containing: coord) else {
            missingHomeRegion = nil
            return
        }
        let installed = Set(RegionStore.installedRegions().map(\.id))
        missingHomeRegion = installed.contains(state.id) ? nil : state
    }

    // MARK: - Search Bar

    @ViewBuilder
    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Where to?", text: $searchText)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .focused($searchFocused)
                .onSubmit {
                     if let first = searchCompleter.results.first {
                         selectCompletion(first)
                     }
                }
            
            if !searchText.isEmpty {
                Button {
                    clearAll()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(.thickMaterial) // Better visibility over map
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 4, y: 2)
        .padding(.horizontal)
        .padding(.top, 8)
        .opacity(routeResult != nil ? 0.8 : 1.0)
    }

    // MARK: - Sheet Content

    @ViewBuilder
    private var sheetContent: some View {
        VStack(spacing: 0) {
            if isCalculating {
                loadingView
            } else if let result = routeResult {
                routeDetailView(result)
            } else if let error = routeError {
                errorStateView(error)
            } else {
                searchResultsList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $showOfflineRoutingSheet) {
            NavigationStack {
                OfflineRoutingView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showOfflineRoutingSheet = false }
                        }
                    }
            }
        }
    }
    
    @ViewBuilder
    private var loadingView: some View {
        VStack(spacing: 16) {
            Text(selectedPlace?.name ?? "Destination")
                .font(.headline)
            ProgressView()
                .controlSize(.large)
            Text(calculationStatus ?? "Loading...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 32)
    }

    @ViewBuilder
    private func errorStateView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundStyle(.orange)
            Text("Couldn\u{2019}t get a route")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if routeErrorNeedsRegion {
                Button {
                    showOfflineRoutingSheet = true
                } label: {
                    Label("Download Region", systemImage: "arrow.down.circle.fill")
                        .frame(minWidth: 212)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.0, green: 0.7, blue: 0.65))
                .padding(.top, 4)
            }
            HStack(spacing: 12) {
                if let place = selectedPlace {
                    Button {
                        routeError = nil
                        Task { await routeToPlace(place) }
                    } label: {
                        Text("Try Again").frame(minWidth: 100)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.0, green: 0.7, blue: 0.65))
                }
                Button {
                    routeError = nil
                } label: {
                    Text("Back to Search").frame(minWidth: 100)
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 32)
        .padding(.top, 32)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var searchResultsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if let error = searchCompleter.errorMessage {
                    searchStatusView(
                        icon: "wifi.exclamationmark",
                        title: "Search unavailable",
                        message: error
                    )
                } else if searchText.isEmpty {
                    recentsList
                } else if searchCompleter.isSearching && searchCompleter.results.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Searching…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 24)
                    .frame(maxWidth: .infinity)
                } else if searchCompleter.results.isEmpty && searchText.count >= 2 {
                    searchStatusView(
                        icon: "magnifyingglass",
                        title: "No results",
                        message: "No places match \u{201C}\(searchText)\u{201D}. Try a different name or a street address."
                    )
                } else {
                    ForEach(searchCompleter.results, id: \.self) { completion in
                        searchResultRow(
                            title: completion.title,
                            subtitle: completion.subtitle,
                            icon: "mappin.circle.fill"
                        ) {
                            selectCompletion(completion)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var recentsList: some View {
        if recents.isEmpty {
            searchStatusView(
                icon: "clock",
                title: "Where to?",
                message: "Search for a place or address. Recent destinations will appear here."
            )
        } else {
            HStack {
                Text("Recent")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") {
                    RecentsStore.clear()
                    recents = []
                }
                .font(.footnote)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            ForEach(recents) { recent in
                searchResultRow(
                    title: recent.name,
                    subtitle: recent.subtitle,
                    icon: "clock.arrow.circlepath"
                ) {
                    selectRecent(recent)
                }
            }
        }
    }

    @ViewBuilder
    private func searchResultRow(
        title: String,
        subtitle: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.gray)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(.primary)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        Divider().padding(.leading, 60)
    }

    private func searchStatusView(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .padding(.top, 32)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func routeDetailView(_ result: RouteResult) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                // Summary Header
                VStack(spacing: 16) {
                    if let name = selectedPlace?.name {
                        Text(name)
                            .font(.title3.bold())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    
                    HStack(spacing: 24) {
                        statItem(value: formatTime(result.timeSeconds), label: "Time", color: .primary)
                        statItem(value: formatDistance(result.distanceMeters), label: "Distance", color: .secondary)
                        
                        HStack(spacing: 4) {
                            Image(systemName: result.cameraCount == 0 ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(result.cameraCount == 0 ? Color(red: 0.0, green: 0.7, blue: 0.65) : .orange)
                            statItem(value: "\(result.cameraCount)", label: "Cameras", color: result.cameraCount == 0 ? Color(red: 0.0, green: 0.7, blue: 0.65) : .orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Avoidance summary ("Avoided all N cameras"), computed
                    // from the corridor set.
                    Text(result.avoidanceInfo)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // Aggressiveness slider: higher levels exclude more
                    // cameras with bigger keep-away radii. Recalculates the
                    // route when the thumb is released on a new level.
                    VStack(spacing: 2) {
                        HStack {
                            Text("Avoidance")
                                .font(.footnote.weight(.medium))
                            Spacer()
                            Text((AvoidanceLevel(rawValue: avoidanceLevelRaw) ?? .balanced).label)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(avoidanceLevelRaw) },
                                set: { avoidanceLevelRaw = Int($0.rounded()) }
                            ),
                            in: 0...3,
                            step: 1
                        ) { editing in
                            if !editing,
                               avoidanceLevelRaw != lastRoutedLevel,
                               let place = selectedPlace {
                                Task { await routeToPlace(place) }
                            }
                        }
                        .tint(Color(red: 0.0, green: 0.7, blue: 0.65))
                        .accessibilityLabel("Camera avoidance aggressiveness")
                        HStack {
                            Text("Low").font(.caption2).foregroundStyle(.tertiary)
                            Spacer()
                            Text("Max").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }

                    Button {
                        openInAppleMaps()
                    } label: {
                        HStack {
                            Text("Open in Apple Maps")
                            Image(systemName: "arrow.up.right.circle.fill")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.0, green: 0.7, blue: 0.65))
                }
                .padding(20)
                
                Divider()
                
                // Maneuvers List
                LazyVStack(spacing: 0) {
                    ForEach(Array(result.maneuvers.indices), id: \.self) { index in
                        let maneuver = result.maneuvers[index]
                        HStack(alignment: .top, spacing: 16) {
                            Image(systemName: maneuverIcon(for: maneuver.type))
                                .font(.title2)
                                .foregroundStyle(.secondary)
                                .frame(width: 30, alignment: .center)
                                .padding(.top, 2)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text(maneuver.instruction)
                                    .font(.body)
                                    .fixedSize(horizontal: false, vertical: true)
                                
                                if index < result.maneuvers.count - 1 {
                                    Text(formatDistance(maneuver.length * 1000))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                        
                        Divider().padding(.leading, 66)
                    }
                }
            }
        }
    }
    
    private func statItem(value: String, label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.headline).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions
    
    private func selectCompletion(_ completion: MKLocalSearchCompletion) {
        searchText = completion.title
        // Dismiss keyboard
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        
        // Resolve to MapItem
        let request = MKLocalSearch.Request(completion: completion)
        let search = MKLocalSearch(request: request)
        
        isCalculating = true
        calculationStatus = "Locating..."
        isSheetPresented = true
        sheetDetent = .fraction(0.25)
        
        Task {
            do {
                let response = try await search.start()
                if let item = response.mapItems.first {
                    selectedPlace = item
                    if let coord = item.placemark.location?.coordinate {
                        RecentsStore.add(
                            name: item.name ?? completion.title,
                            subtitle: completion.subtitle,
                            coordinate: coord
                        )
                        recents = RecentsStore.load()
                    }
                    await routeToPlace(item)
                } else {
                    routeError = "Could not locate place."
                    isCalculating = false
                }
            } catch {
                routeError = error.localizedDescription
                isCalculating = false
            }
        }
    }

    private func selectRecent(_ recent: RecentDestination) {
        searchText = recent.name
        searchFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)

        let coordinate = CLLocationCoordinate2D(latitude: recent.latitude, longitude: recent.longitude)
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = recent.name
        selectedPlace = item

        isCalculating = true
        calculationStatus = "Locating..."
        isSheetPresented = true
        sheetDetent = .fraction(0.25)

        RecentsStore.add(name: recent.name, subtitle: recent.subtitle, coordinate: coordinate)
        recents = RecentsStore.load()

        Task {
            await routeToPlace(item)
        }
    }

    @MainActor
    private func routeToPlace(_ place: MKMapItem) async {
        // A cold start often reaches here before the first GPS fix. Waiting
        // beats failing: show status and give CoreLocation up to 10 seconds.
        var maybeLocation = locationManager.currentLocation?.coordinate
        if maybeLocation == nil {
            isCalculating = true
            calculationStatus = "Getting your location..."
            locationManager.requestAuthorizationIfNeeded()
            locationManager.startTracking()
            for _ in 0..<20 where maybeLocation == nil {
                try? await Task.sleep(nanoseconds: 500_000_000)
                maybeLocation = locationManager.currentLocation?.coordinate
            }
        }
        guard let userLocation = maybeLocation else {
            routeError = "Couldn\u{2019}t get your location. Allow location access and try again."
            isCalculating = false
            return
        }
        guard let destCoord = place.placemark.location?.coordinate else {
            routeError = "Couldn't determine location for this place."
            isCalculating = false
            return
        }

        isCalculating = true
        routeError = nil
        routeResult = nil
        routeCameras = []
        sheetDetent = .fraction(0.25)

        do {
            calculationStatus = "Fetching cameras..."
            let bounds = corridorBounds(from: userLocation, to: destCoord, bufferKm: 3.0)
            // Use the same merged source as the Map tab (DeFlock CDN bulk
            // ALPRs plus Overpass speed cameras) so routes see every camera
            // the map shows.
            var cameras: [SurveillanceCamera]
            do {
                cameras = try await cameraStore.fetchFromBestSource(in: bounds)
            } catch {
                cameras = []
            }
            // Merge in whatever the map already knows inside the corridor;
            // this covers offline runs and any source that just failed.
            let known = cameraStore.cameras.filter { bounds.contains($0.coordinate) }
            var byID = Dictionary(uniqueKeysWithValues: cameras.map { ($0.id, $0) })
            for cam in known where byID[cam.id] == nil { byID[cam.id] = cam }
            cameras = Array(byID.values)
            routeCameras = cameras

            calculationStatus = "Calculating camera-avoidance route..."
            // Route planning always keeps physical distance from every camera
            // (full circles). FOV wedges are for live driving alerts only:
            // wedge avoidance lets a route pass directly behind a camera pole,
            // which looks wrong on the map.
            let level = AvoidanceLevel(rawValue: avoidanceLevelRaw) ?? .balanced
            lastRoutedLevel = level.rawValue
            #if DEBUG
            var result = try await valhallaService.timedRouteWithProgressiveAvoidance(
                from: userLocation, to: destCoord, cameras: cameras,
                useFOV: false, level: level, trigger: .initial
            )
            #else
            var result = try await valhallaService.routeWithProgressiveAvoidance(
                from: userLocation, to: destCoord, cameras: cameras,
                useFOV: false, level: level
            )
            #endif

            // The chosen route can stray outside the start-to-end corridor
            // box. If it does, fetch cameras along the actual route geometry
            // and re-run avoidance once so cameras on the detour are shown
            // and avoided.
            if result.route.coordinates.contains(where: { !bounds.contains($0) }) {
                let routeBox = boundsOfCoordinates(result.route.coordinates, bufferKm: 1.5)
                var extra = (try? await cameraStore.fetchFromBestSource(in: routeBox)) ?? []
                extra += cameraStore.cameras.filter { routeBox.contains($0.coordinate) }
                var grew = false
                for cam in extra where byID[cam.id] == nil {
                    byID[cam.id] = cam
                    grew = true
                }
                if grew {
                    cameras = Array(byID.values)
                    routeCameras = cameras
                    calculationStatus = "Rechecking cameras along the route..."
                    #if DEBUG
                    result = try await valhallaService.timedRouteWithProgressiveAvoidance(
                        from: userLocation, to: destCoord, cameras: cameras,
                        useFOV: false, level: level, trigger: .recheck
                    )
                    #else
                    result = try await valhallaService.routeWithProgressiveAvoidance(
                        from: userLocation, to: destCoord, cameras: cameras,
                        useFOV: false, level: level
                    )
                    #endif
                }
            }

            let exposure = camerasAlongCoordinates(result.route.coordinates, cameras: cameras)

            // "Avoided" is the corridor total minus the cameras that can see
            // this route, the same exposure count shown in the Cameras stat,
            // so the two numbers add up.
            let avoidanceInfo: String
            if result.totalCount == 0 {
                avoidanceInfo = "No cameras detected along this corridor"
            } else if exposure.isEmpty {
                avoidanceInfo = "Avoided all \(result.totalCount) cameras nearby"
            } else {
                let avoided = max(0, result.totalCount - exposure.count)
                avoidanceInfo = "Avoided \(avoided) of \(result.totalCount) nearby \u{00B7} \(exposure.count) on route"
            }

            routeResult = RouteResult(
                coordinates: result.route.coordinates,
                distanceMeters: result.route.distanceKm * 1000,
                timeSeconds: result.route.timeSeconds,
                cameraCount: exposure.count,
                avoidanceInfo: avoidanceInfo,
                maneuvers: result.route.maneuvers
            )

            zoomToRoute(result.route.coordinates)

            isSheetPresented = true
            sheetDetent = .fraction(0.25) // Start collapsed

        } catch {
            Logger(subsystem: "io.vws.app.flckd", category: "routing")
                .error("route failed: \(error.localizedDescription, privacy: .public)")
            // Name the states the user needs to download instead of reporting
            // a generic failure.
            let installed = Set(RegionStore.installedRegions().map(\.id))
            var missingStates: [String] = []
            if let home = USStateBounds.region(containing: userLocation),
               !installed.contains(home.id) {
                missingStates.append(home.name)
            }
            if let dest = USStateBounds.region(containing: destCoord),
               !installed.contains(dest.id),
               !missingStates.contains(dest.name) {
                missingStates.append(dest.name)
            }
            if !missingStates.isEmpty {
                routeErrorNeedsRegion = true
                let list = missingStates.joined(separator: " and ")
                routeError = missingStates.count == 1
                    ? "This route needs \(list) road data, which isn\u{2019}t downloaded yet. Download it, then try again."
                    : "This route crosses state lines. Download \(list) road data, then try again."
            } else if case RoutingError.engineUnavailable = error {
                routeErrorNeedsRegion = true
                routeError = error.localizedDescription
            } else {
                routeErrorNeedsRegion = false
                routeError = "Route failed: \(error.localizedDescription)"
            }
            sheetDetent = .fraction(0.6)
        }

        isCalculating = false
        calculationStatus = nil
    }

    // MARK: - Helpers

    private func clearAll() {
        searchText = ""
        searchCompleter.results = []
        selectedPlace = nil
        routeResult = nil
        routeCameras = []
        routeError = nil
        routeErrorNeedsRegion = false
        calculationStatus = nil
        isCalculating = false
        isSheetPresented = false
        cameraPosition = .userLocation(fallback: .automatic)
    }

    private func camerasAlongCoordinates(_ coords: [CLLocationCoordinate2D], cameras: [SurveillanceCamera]) -> [SurveillanceCamera] {
        // Same yardstick the planner optimizes: every camera within the
        // buffer counts, regardless of which way it faces.
        return cameras.filter { camera in
            let camLoc = CLLocation(latitude: camera.latitude, longitude: camera.longitude)
            return coords.contains { point in
                camLoc.distance(from: CLLocation(latitude: point.latitude, longitude: point.longitude)) <= cameraBufferMeters
            }
        }
    }

    private func corridorBounds(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D, bufferKm: Double) -> BoundingBox {
        let latBuffer = bufferKm / 111.0
        let avgLat = (start.latitude + end.latitude) / 2
        let lonBuffer = bufferKm / (111.0 * cos(avgLat * .pi / 180))
        return BoundingBox(
            south: min(start.latitude, end.latitude) - latBuffer,
            west: min(start.longitude, end.longitude) - lonBuffer,
            north: max(start.latitude, end.latitude) + latBuffer,
            east: max(start.longitude, end.longitude) + lonBuffer
        )
    }

    /// Bounding box enclosing a set of coordinates, padded by `bufferKm`.
    private func boundsOfCoordinates(_ coords: [CLLocationCoordinate2D], bufferKm: Double) -> BoundingBox {
        guard let first = coords.first else {
            return BoundingBox(south: 0, west: 0, north: 0, east: 0)
        }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in coords {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let latBuffer = bufferKm / 111.0
        let lonBuffer = bufferKm / (111.0 * cos(((minLat + maxLat) / 2) * .pi / 180))
        return BoundingBox(south: minLat - latBuffer, west: minLon - lonBuffer,
                           north: maxLat + latBuffer, east: maxLon + lonBuffer)
    }

    private func zoomToRoute(_ coordinates: [CLLocationCoordinate2D]) {
        var allPoints = coordinates
        if let userCoord = locationManager.currentLocation?.coordinate {
            allPoints.append(userCoord)
        }
        guard let first = allPoints.first else { return }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in allPoints {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let latSpan = maxLat - minLat
        let lonSpan = maxLon - minLon
        // Extra bottom padding to account for the sheet covering ~30% of screen
        let latPad = max(latSpan * 0.3, 0.01)
        let lonPad = max(lonSpan * 0.15, 0.01)
        let centerLat = (minLat + maxLat) / 2 + latPad * 0.3 // shift center up slightly
        cameraPosition = .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centerLat, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: latSpan + latPad * 2, longitudeDelta: lonSpan + lonPad * 2)
        ))
    }

    private func openInAppleMaps() {
        guard let place = selectedPlace else { return }
        place.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving,
        ])
    }

    private func formatDistance(_ meters: Double) -> String {
        if useMetric {
            return meters >= 1000 ? String(format: "%.1f km", meters / 1000) : "\(Int(meters)) m"
        }
        let feet = meters * 3.28084
        return feet >= 5280 ? String(format: "%.1f mi", feet / 5280) : "\(Int(feet)) ft"
    }

    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds / 60)
        return mins >= 60 ? "\(mins / 60)h \(mins % 60)m" : "\(mins) min"
    }
    
    private func maneuverIcon(for type: Int) -> String {
        // Valhalla maneuver types to SF Symbols
        switch type {
        case 1, 2, 3: return "arrow.up.circle.fill" // Start
        case 4, 5, 6: return "flag.checkered.circle.fill" // Dest
        case 7: return "arrow.up" // Continue
        case 8: return "arrow.turn.up.right" // Slight right
        case 9: return "arrow.turn.up.right" // Right
        case 10: return "arrow.turn.right.down" // Sharp right
        case 11: return "arrow.uturn.right" // U-turn right
        case 12: return "arrow.uturn.left" // U-turn left
        case 13: return "arrow.turn.left.down" // Sharp left
        case 14: return "arrow.turn.up.left" // Left
        case 15: return "arrow.turn.up.left" // Slight left
        case 16: return "arrow.triangle.merge" // Ramp straight
        case 17: return "arrow.turn.up.right" // Ramp right
        case 18: return "arrow.turn.up.left" // Ramp left
        case 19: return "arrow.turn.up.right" // Exit right
        case 20: return "arrow.turn.up.left" // Exit left
        case 21: return "arrow.up" // Stay straight
        case 24: return "arrow.triangle.merge" // Merge
        case 25: return "arrow.triangle.turn.up.right.circle" // Roundabout
        default: return "arrow.up"
        }
    }
}

// MARK: - Search Completer

@Observable
class SearchCompleter: NSObject, MKLocalSearchCompleterDelegate {
    var results: [MKLocalSearchCompletion] = []
    var isSearching = false
    var errorMessage: String?
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .address, .query]
    }

    /// Region is a bias only. Searching must work before a location fix
    /// exists, so `region` is optional.
    func search(_ query: String, region: MKCoordinateRegion?) {
        if let region {
            completer.region = region
        }
        isSearching = true
        errorMessage = nil
        completer.queryFragment = query
    }

    func cancel() {
        completer.cancel()
        isSearching = false
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        isSearching = false
        errorMessage = nil
        results = Array(completer.results.prefix(12))
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        isSearching = false
        results = []
        errorMessage = "Search is unavailable. Check your connection and try again."
    }
}

// MARK: - Route Result

struct RouteResult {
    let coordinates: [CLLocationCoordinate2D]
    let distanceMeters: Double
    let timeSeconds: Double
    let cameraCount: Int
    let avoidanceInfo: String
    let maneuvers: [ValhallaManeuver]
}

// MARK: - MKPolyline Extension

extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: pointCount)
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }
}

// MARK: - Recent Destinations

/// A previously routed-to destination, persisted so the user can re-route
/// with one tap instead of re-typing a search.
struct RecentDestination: Codable, Identifiable, Hashable {
    var id: String { "\(latitude),\(longitude)" }
    let name: String
    let subtitle: String
    let latitude: Double
    let longitude: Double
    let lastUsed: Date
}

enum RecentsStore {
    private static let key = "recentDestinations"
    private static let maxCount = 8

    static func load() -> [RecentDestination] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let recents = try? JSONDecoder().decode([RecentDestination].self, from: data) else {
            return []
        }
        return recents
    }

    static func add(name: String, subtitle: String, coordinate: CLLocationCoordinate2D) {
        // Dedupe by proximity (~20 m) so re-routing bumps instead of duplicates.
        var recents = load().filter {
            abs($0.latitude - coordinate.latitude) > 0.0002 ||
            abs($0.longitude - coordinate.longitude) > 0.0002
        }
        recents.insert(
            RecentDestination(
                name: name,
                subtitle: subtitle,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                lastUsed: Date()
            ),
            at: 0
        )
        if recents.count > maxCount {
            recents = Array(recents.prefix(maxCount))
        }
        if let data = try? JSONEncoder().encode(recents) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
