import SwiftUI

/// Says an offline-data update is available, with an Update button, or that
/// one was downloaded. Same floating material style as the proximity banner.
struct OfflineUpdateBanner: View {
    let notice: OfflineDataUpdater.Notice
    let isUpdating: Bool
    let onUpdate: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            if case .available = notice {
                Button(action: onUpdate) {
                    if isUpdating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Update")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isUpdating)
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 16)
    }

    private var title: String {
        switch notice {
        case .available: "Update available"
        case .downloaded: "Offline data updated"
        }
    }

    private var detail: String {
        switch notice {
        case .available(let items), .downloaded(let items):
            items.prefix(1).uppercased() + items.dropFirst()
        }
    }

    private var icon: String {
        switch notice {
        case .available: "arrow.down.circle.fill"
        case .downloaded: "checkmark.circle.fill"
        }
    }

    private var tint: Color {
        switch notice {
        case .available: .blue
        case .downloaded: Color(red: 0.0, green: 0.7, blue: 0.65)
        }
    }
}
