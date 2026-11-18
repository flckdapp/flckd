import SwiftUI

/// What the driving screen has to say about the route itself, as opposed to
/// the next turn.
///
/// One value rather than three booleans: the states are mutually exclusive on
/// screen, and a plain enumeration is what lets the view stop deciding which
/// of them wins.
enum NavigationStatus: Equatable {
    case quiet
    case rerouting
    case rerouted(avoided: Int, total: Int)
    case rerouteFailed
}

/// The notice under the turn card.
struct NavigationStatusView: View {

    let status: NavigationStatus

    var body: some View {
        switch status {
        case .quiet:
            EmptyView()

        case .rerouting:
            NavigationStatusChip(
                text: "Rerouting\u{2026}",
                systemImage: nil,
                showsProgress: true
            )

        case let .rerouted(avoided, total):
            NavigationStatusChip(
                text: "New route avoids \(avoided) of \(total) cameras",
                systemImage: "checkmark.shield.fill",
                tint: NavigationPalette.accent
            )

        case .rerouteFailed:
            NavigationStatusChip(
                text: "Couldn\u{2019}t find a new route. Continuing on the current one.",
                systemImage: "exclamationmark.triangle.fill",
                tint: .orange
            )
        }
    }
}

/// A single pill, sized to its text.
struct NavigationStatusChip: View {

    let text: String
    let systemImage: String?
    var tint: Color = .secondary
    var showsProgress: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(tint)
            }

            Text(text)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 6, y: 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Previews

#Preview("Statuses") {
    ZStack {
        LinearGradient(colors: [.teal.opacity(0.35), .gray.opacity(0.5)], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()

        VStack(spacing: 12) {
            NavigationStatusView(status: .rerouting)
            NavigationStatusView(status: .rerouted(avoided: 4, total: 6))
            NavigationStatusView(status: .rerouteFailed)
                .padding(.horizontal, 40)
        }
    }
}

#Preview("Statuses — Dark") {
    ZStack {
        LinearGradient(colors: [.teal.opacity(0.35), .gray.opacity(0.5)], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()

        VStack(spacing: 12) {
            NavigationStatusView(status: .rerouting)
            NavigationStatusView(status: .rerouted(avoided: 0, total: 3))
            NavigationStatusView(status: .rerouteFailed)
                .padding(.horizontal, 40)
        }
    }
    .preferredColorScheme(.dark)
}
