import Foundation

/// Whether this phone may say street names with Kokoro. Support is measured,
/// not listed (plan D9): enough memory, and renders at least as fast as real
/// time once a measurement exists. An unmeasured phone is allowed to try.
enum KokoroSupport {
    static let memoryFloor: UInt64 = 5_000_000_000
    static let sayNamesKey = "kokoroSayStreetNames"
    static let measuredRTFKey = "kokoroMeasuredRTF"
    static let measuredPackKey = "kokoroMeasuredPack"

    static func namesSupported(physicalMemory: UInt64, measuredRTF: Double?) -> Bool {
        physicalMemory >= memoryFloor && (measuredRTF.map { $0 <= 1.0 } ?? true)
    }

    static func sayNames(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: sayNamesKey) == nil ? true : defaults.bool(forKey: sayNamesKey)
    }

    /// The stored measurement, if it belongs to the bundled pack.
    static func measuredRTF(_ defaults: UserDefaults = .standard,
                            descriptor: KokoroPackDescriptor? = .bundled) -> Double? {
        guard let descriptor, defaults.string(forKey: measuredPackKey) == descriptor.id,
              defaults.object(forKey: measuredRTFKey) != nil else { return nil }
        return defaults.double(forKey: measuredRTFKey)
    }

    static func storeMeasurement(_ rtf: Double, _ defaults: UserDefaults = .standard,
                                 descriptor: KokoroPackDescriptor? = .bundled) {
        guard let descriptor, rtf.isFinite, rtf > 0 else { return }
        defaults.set(rtf, forKey: measuredRTFKey)
        defaults.set(descriptor.id, forKey: measuredPackKey)
    }

    static func clearMeasurement(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: measuredRTFKey)
        defaults.removeObject(forKey: measuredPackKey)
    }

    static func namesEnabled(_ defaults: UserDefaults = .standard, store: KokoroVoiceStore? = .standard,
                             physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Bool {
        guard VoiceEngine.selected(defaults) == .kokoro, sayNames(defaults), let store, store.modelInstalled() else {
            return false
        }
        return namesSupported(physicalMemory: physicalMemory, measuredRTF: measuredRTF(defaults, descriptor: store.descriptor))
    }

    enum NamesStatus: Equatable, Sendable { case needsMoreMemory, notInstalled, tooSlow, ready }

    /// What the street-names section of the Kokoro page shows, checked in this order.
    static func namesStatus(physicalMemory: UInt64, modelInstalled: Bool, measuredRTF: Double?) -> NamesStatus {
        if physicalMemory < memoryFloor { return .needsMoreMemory }
        if !modelInstalled { return .notInstalled }
        if let measuredRTF, measuredRTF > 1.0 { return .tooSlow }
        return .ready
    }

    /// A live preview is a measurement too. Cancelled or failed renders record nothing.
    static func record(_ result: KokoroNameRenderer.PreviewResult, _ defaults: UserDefaults = .standard,
                       descriptor: KokoroPackDescriptor? = .bundled) {
        if case let .rendered(_, rtf) = result { storeMeasurement(rtf, defaults, descriptor: descriptor) }
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}
