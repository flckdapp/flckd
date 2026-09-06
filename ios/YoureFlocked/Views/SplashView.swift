import SwiftUI
import UIKit

struct SplashView: View {
    private let bgColor = Color(red: 0.133, green: 0.188, blue: 0.239)

    var body: some View {
        ZStack {
            bgColor.ignoresSafeArea()

            VStack(spacing: 20) {
                appIcon
                    .frame(width: 120, height: 120)
                    // Clip slightly inside the artwork's own corner radius
                    // (~29.3pt at 120pt) so the icon's white canvas corners
                    // never peek out.
                    .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                    // The icon tile is nearly the same navy as the splash
                    // background, so give it a visible edge: hairline stroke
                    // plus a soft drop shadow for separation.
                    .overlay(
                        RoundedRectangle(cornerRadius: 30, style: .continuous)
                            .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.45), radius: 22, x: 0, y: 10)

                Text("You're Flocked")
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    @ViewBuilder
    private var appIcon: some View {
        if let uiImage = UIImage(named: "SplashIcon") ?? UIImage(named: "AppIcon") {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "eye.trianglebadge.exclamationmark")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.white)
                .padding(24)
        }
    }
}

#Preview {
    SplashView()
}
