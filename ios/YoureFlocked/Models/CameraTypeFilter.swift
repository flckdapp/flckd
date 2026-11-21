import Foundation

/// Which camera types the user has asked to see and hear about.
///
/// This is about what the user sees and hears: the map markers, banner,
/// haptics, notifications, Live Activity and spoken alerts. It is not about
/// what route planning avoids. Routing reads `CameraStore.cameras` directly
/// and never goes through this filter.
struct CameraTypeFilter: Equatable, Sendable {
    /// Settings writes these through `@AppStorage`.
    static let alprOnlyKey = "showALPROnly"
    static let genericKey = "showGenericCameras"
    static let speedKey = CameraStore.showSpeedCamerasKey

    var alprOnly: Bool = false
    var showSpeed: Bool = true
    var showGeneric: Bool = true

    static let all = CameraTypeFilter()

    static func fromDefaults(_ defaults: UserDefaults = .standard) -> CameraTypeFilter {
        CameraTypeFilter(
            alprOnly: defaults.object(forKey: alprOnlyKey) as? Bool ?? false,
            showSpeed: defaults.object(forKey: speedKey) as? Bool ?? true,
            showGeneric: defaults.object(forKey: genericKey) as? Bool ?? true
        )
    }

    /// ALPR-only wins over the other two switches, which Settings hides while
    /// it is on. Guards, gunshot detectors and unknown devices follow it too.
    func allows(_ camera: SurveillanceCamera) -> Bool {
        switch camera.surveillanceType {
        case .alpr: return true
        case .speedCamera: return !alprOnly && showSpeed
        case .camera: return !alprOnly && showGeneric
        default: return !alprOnly
        }
    }
}
