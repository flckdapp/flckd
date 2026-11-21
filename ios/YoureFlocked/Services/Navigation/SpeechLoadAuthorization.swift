import Foundation
import Synchronization
import UIKit

/// A foreground grant is invalidated on every lifecycle transition. Queued
/// work must validate it again on the executor where the operation starts.
final class SpeechLoadAuthorization: Sendable {
    struct State { var generation = 0; var active = false }
    private let state = Mutex(State())
    static let shared = SpeechLoadAuthorization()

    func transition(active: Bool) { state.withLock { $0.generation += 1; $0.active = active } }

    @MainActor
    func grant(applicationActive: Bool = UIApplication.shared.applicationState == .active) throws -> Int {
        try Task.checkCancellation()
        guard applicationActive else { throw CancellationError() }
        return state.withLock { value in
            if !value.active { value.generation += 1; value.active = true }
            return value.generation
        }
    }

    func check(_ grant: Int) throws {
        try Task.checkCancellation()
        guard state.withLock({ $0.active && $0.generation == grant }) else { throw CancellationError() }
    }

    @MainActor
    func validateForeground(_ grant: Int) throws {
        try check(grant)
        guard UIApplication.shared.applicationState == .active else { throw CancellationError() }
    }

    func perform<T>(_ grant: Int, operation: () throws -> T) throws -> T {
        try check(grant)
        return try operation()
    }
}

enum SpeechWarmUpPolicy {
    static func automatic(voice: NavigationVoice, master: Bool, foreground: Bool) -> Bool {
        voice.live && master && foreground
    }
}
