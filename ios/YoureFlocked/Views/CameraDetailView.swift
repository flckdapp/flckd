import SwiftUI
import MapKit

// MARK: - Camera Detail View

/// Detail sheet showing information about a selected surveillance camera.
/// Displays OSM tags, location on a mini-map, and links to the OSM node.
struct CameraDetailView: View {
    let camera: SurveillanceCamera
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headerSection
                    miniMap
                    detailsSection
                    tagsSection
                    linksSection
                }
                .padding()
            }
            .navigationTitle("Camera Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerSection: some View {
        HStack(spacing: 16) {
            Image(systemName: camera.surveillanceType.iconName)
                .font(.largeTitle)
                .foregroundStyle(typeColor)
                .frame(width: 60, height: 60)
                .background(typeColor.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                Text(camera.displayName)
                    .font(.title2.bold())
                Text(camera.surveillanceType.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let zone = camera.surveillanceZone {
                    Text("Monitoring: \(zone)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    // MARK: - Mini Map

    @ViewBuilder
    private var miniMap: some View {
        Map {
            Marker(camera.displayName, coordinate: camera.coordinate)
                .tint(typeColor)
        }
        .frame(height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .allowsHitTesting(false) // static preview
    }

    // MARK: - Details

    @ViewBuilder
    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Details")
                .font(.headline)

            DetailRow(label: "Type", value: camera.surveillanceType.displayName)

            if let manufacturer = camera.manufacturer {
                DetailRow(label: "Manufacturer", value: manufacturer)
            }
            if let operatorName = camera.operatorName {
                DetailRow(label: "Operator", value: operatorName)
            }
            if let direction = camera.direction {
                DetailRow(label: "Direction", value: "\(Int(direction))\u{00B0}")
            }
            if let mount = camera.cameraMount {
                DetailRow(label: "Mount", value: mount)
            }
            if let cameraType = camera.cameraType {
                DetailRow(label: "Camera Type", value: cameraType)
            }

            DetailRow(
                label: "Coordinates",
                value: String(format: "%.5f, %.5f", camera.latitude, camera.longitude)
            )
            DetailRow(label: "OSM Node ID", value: "\(camera.osmID)")
        }
    }

    // MARK: - Raw Tags

    @ViewBuilder
    private var tagsSection: some View {
        if !camera.tags.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("OSM Tags")
                    .font(.headline)

                ForEach(camera.tags.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    HStack {
                        Text(key)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(value)
                            .font(.caption.monospaced())
                    }
                }
            }
            .padding()
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Links

    @ViewBuilder
    private var linksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Links")
                .font(.headline)

            if let osmURL = URL(string: "https://www.openstreetmap.org/node/\(camera.osmID)") {
                Link(destination: osmURL) {
                    Label("View on OpenStreetMap", systemImage: "globe")
                }
            }

            if let deflockURL = URL(string: "https://deflock.me/map?node=\(camera.osmID)") {
                Link(destination: deflockURL) {
                    Label("View on DeFlock", systemImage: "map")
                }
            }
        }
    }

    // MARK: - Helpers

    private var typeColor: Color {
        switch camera.surveillanceType {
        case .alpr: return .red
        case .camera: return .orange
        case .speedCamera: return .yellow
        case .gunshotDetector: return .purple
        default: return .gray
        }
    }
}

// MARK: - Detail Row

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }
}
