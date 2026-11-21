import Foundation

/// Cameras the user has muted from a notification: forever, or for an hour.
///
/// Kept in standard UserDefaults so a relaunch doesn't forget them (iOS may
/// include preferences in its backups). IDs amount to places the user drives
/// past, so the app never logs or transmits them. A mute silences
/// notifications only; the banner, haptics and spoken alerts are unaffected.
struct NotificationMuteStore {
    /// Camera IDs muted permanently, as decimal strings.
    static let permanentKey = "mutedCameraIDs"
    /// Camera ID (decimal string) to expiry, seconds since 1970.
    static let temporaryKey = "temporarilyMutedCameras"
    static let oneHour: TimeInterval = 3600

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var permanent: Set<Int64> {
        Set((defaults.stringArray(forKey: Self.permanentKey) ?? []).compactMap { Int64($0) })
    }

    private func temporary(now: Date) -> [Int64: Date] {
        let raw = defaults.dictionary(forKey: Self.temporaryKey) as? [String: Double] ?? [:]
        var live: [Int64: Date] = [:]
        for (key, expiry) in raw {
            let date = Date(timeIntervalSince1970: expiry)
            if let id = Int64(key), date > now { live[id] = date }
        }
        return live
    }

    private func save(permanent: Set<Int64>, temporary: [Int64: Date]) {
        defaults.set(permanent.sorted().map(String.init), forKey: Self.permanentKey)
        var raw: [String: Double] = [:]
        for (id, date) in temporary { raw[String(id)] = date.timeIntervalSince1970 }
        defaults.set(raw, forKey: Self.temporaryKey)
    }

    func isMuted(_ id: Int64, now: Date = Date()) -> Bool {
        permanent.contains(id) || temporary(now: now)[id] != nil
    }

    func mutePermanently(_ id: Int64, now: Date = Date()) {
        var perm = permanent
        perm.insert(id)
        save(permanent: perm, temporary: temporary(now: now))
    }

    func muteForOneHour(_ id: Int64, now: Date = Date()) {
        var temp = temporary(now: now)
        temp[id] = now.addingTimeInterval(Self.oneHour)
        save(permanent: permanent, temporary: temp)
    }

    /// Cameras currently muted, expired one-hour mutes excluded.
    func count(now: Date = Date()) -> Int {
        permanent.union(temporary(now: now).keys).count
    }

    func unmuteAll() {
        defaults.removeObject(forKey: Self.permanentKey)
        defaults.removeObject(forKey: Self.temporaryKey)
    }
}
