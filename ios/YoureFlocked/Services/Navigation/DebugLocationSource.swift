#if DEBUG
import Foundation

/// A generation token prevents a stopped/replaced simulator's late callbacks
/// from reclaiming the shared location stream. Real fixes are retained for exit.
struct DebugLocationSource<Value> {
    private(set) var token: UUID?
    private(set) var latestReal: Value?

    mutating func real(_ value: Value) -> Value? {
        latestReal = value
        return token == nil ? value : nil
    }

    mutating func begin() -> UUID {
        let token = UUID()
        self.token = token
        return token
    }

    func simulated(_ value: Value, token: UUID) -> Value? {
        self.token == token ? value : nil
    }

    mutating func end(_ token: UUID) -> Value? {
        guard self.token == token else { return nil }
        self.token = nil
        return latestReal
    }
}
#endif
