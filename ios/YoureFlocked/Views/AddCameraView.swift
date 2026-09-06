import SwiftUI
import MapKit

// MARK: - Add Camera View

/// Form for submitting a new surveillance camera location.
/// Uses camera profiles (matching DeFlock's profile system) to set OSM tags.
///
/// Uploading to OSM requires OAuth2 against the OSM API, which is not
/// implemented yet; submissions are saved locally as pending cameras.
struct AddCameraView: View {
    @Environment(LocationManager.self) private var locationManager
    @Environment(CameraStore.self) private var cameraStore
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var selectedProfile: CameraProfile = CameraProfile.defaults[0]
    @State private var direction: Double = 0
    @State private var notes: String = ""
    @State private var pinCoordinate: CLLocationCoordinate2D?
    @State private var showConfirmation = false

    var body: some View {
        Form {
            mapSection
            profileSection
            directionSection
            notesSection
            submitSection
        }
        .navigationTitle("Report Camera")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            pinCoordinate = locationManager.currentLocation?.coordinate
        }
        .alert("Camera Saved", isPresented: $showConfirmation) {
            Button("OK") { dismiss() }
        } message: {
            Text("Camera saved to your device. It will appear on your map and be uploaded to OpenStreetMap when sync is available.")
        }
    }

    // MARK: - Map Section

    @ViewBuilder
    private var mapSection: some View {
        Section("Location") {
            if let coordinate = pinCoordinate {
                Map {
                    Marker("New Camera", coordinate: coordinate)
                        .tint(.red)
                }
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .listRowInsets(EdgeInsets())

                Text(String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            } else {
                ContentUnavailableView(
                    "No Location",
                    systemImage: "location.slash",
                    description: Text("Enable location services to report a camera.")
                )
            }

            Button("Use Current Location") {
                pinCoordinate = locationManager.currentLocation?.coordinate
            }
            .disabled(locationManager.currentLocation == nil)
        }
    }

    // MARK: - Profile Section

    @ViewBuilder
    private var profileSection: some View {
        Section("Camera Type") {
            Picker("Profile", selection: $selectedProfile) {
                ForEach(CameraProfile.defaults) { profile in
                    Text(profile.name).tag(profile)
                }
            }
            .pickerStyle(.menu)

            DisclosureGroup("OSM Tags") {
                ForEach(selectedProfile.tags.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    HStack {
                        Text(key)
                            .font(.caption.monospaced())
                        Spacer()
                        Text(value)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Direction Section

    @ViewBuilder
    private var directionSection: some View {
        if selectedProfile.requiresDirection {
            Section("Camera Direction") {
                VStack {
                    Text("\(Int(direction))\u{00B0}")
                        .font(.title2.monospaced())

                    Slider(value: $direction, in: 0...360, step: 5) {
                        Text("Direction")
                    } minimumValueLabel: {
                        Text("N")
                    } maximumValueLabel: {
                        Text("N")
                    }
                }

                Text("Compass direction the camera is pointing (0\u{00B0} = North)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Notes Section

    @ViewBuilder
    private var notesSection: some View {
        Section("Notes (optional)") {
            TextField("Additional details...", text: $notes, axis: .vertical)
                .lineLimit(3...6)
        }
    }

    // MARK: - Submit Section

    @ViewBuilder
    private var submitSection: some View {
        Section {
            Button {
                submitCamera()
            } label: {
                Label("Submit Camera", systemImage: "paperplane.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(pinCoordinate == nil)
        } footer: {
            Text("Saved locally. Will sync to OpenStreetMap when available.")
                .font(.caption)
        }
    }

    // MARK: - Submission

    private func submitCamera() {
        guard let coordinate = pinCoordinate else { return }

        let cached = CachedCamera(
            pending: selectedProfile,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            direction: selectedProfile.requiresDirection ? direction : nil,
            notes: notes.isEmpty ? nil : notes
        )

        modelContext.insert(cached)
        try? modelContext.save()

        cameraStore.addPendingCamera(cached.toSurveillanceCamera())

        showConfirmation = true
    }
}

// Picker selection requires Hashable; profiles are identified by id.
extension CameraProfile: Hashable {
    static func == (lhs: CameraProfile, rhs: CameraProfile) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
