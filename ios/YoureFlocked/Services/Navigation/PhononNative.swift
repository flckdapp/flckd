import Dispatch
import Foundation
import PhononCore
import PhononTTS

/// Owns the C handle on a dedicated executor, including install and compile.
/// Unlike the upstream async loader, authorization is checked AFTER queueing,
/// immediately before the synchronous C load. No pointer crosses isolation.
actor PhononNative {
    private let executor = DispatchSerialQueue(label: "app.flckd.phonon", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private var owner: HandleOwner?
    private var handle: OpaquePointer? { owner?.pointer }
    private var names: [String] = []

    struct Loaded: Sendable { let voices: [String]; let compiled: Bool }
    struct Audio: Sendable { let samples: [Float]; let seconds: Double; let first: Double }
    enum Failure: Error { case load, voice, render }

    func load(bundle: URL, authorization: SpeechLoadAuthorization, grant: Int) async throws -> Loaded {
        try authorization.check(grant)
        if handle != nil { return Loaded(voices: names, compiled: false) }
        try await authorization.validateForeground(grant)
        let models = try authorization.perform(grant) { try PhononModels.install(bundled: bundle) }
        let compiled = Phonon.needsCompiling(models)
        #if targetEnvironment(simulator)
        let unit = UInt32(PTTS_UNIT_CPU)
        #else
        let unit = UInt32(PTTS_UNIT_ANE)
        #endif
        try await authorization.validateForeground(grant)
        let loaded = try authorization.perform(grant) {
            models.path.withCString { path in "en".withCString { ptts_new(path, unit, $0) } }
        }
        guard let loaded else { throw Failure.load }
        do { try authorization.check(grant) } catch { ptts_free(loaded); throw error }
        owner = HandleOwner(loaded)
        names = []
        if var p = ptts_voices(loaded) {
            while p.pointee != 0 {
                let name = String(cString: p)
                names.append(name)
                p = p.advanced(by: name.utf8.count + 1)
            }
        }
        return Loaded(voices: names, compiled: compiled)
    }

    func unload() { owner = nil; names = [] }

    #if DEBUG
    /// Test scheduling seam on the SAME executor used by install and C load.
    func debugHoldExecutor(started: @Sendable () -> Void, until release: DispatchSemaphore) {
        started()
        release.wait()
    }

    func debugAuthorizedOperation(authorization: SpeechLoadAuthorization, grant: Int,
                                  reachedPerform: @Sendable () -> Void, operation: @Sendable () -> Void) throws {
        reachedPerform()
        try authorization.perform(grant, operation: operation)
    }
    #endif

    func setVoice(_ name: String) throws {
        try Task.checkCancellation()
        guard let handle, name.withCString({ ptts_set_voice(handle, $0) }) else { throw Failure.voice }
    }

    func audio(_ text: String) throws -> Audio {
        try Task.checkCancellation()
        guard let handle else { throw Failure.load }
        ptts_set_seed(handle, 42)
        let collector = Collector()
        let user = Unmanaged.passUnretained(collector).toOpaque()
        var result = PttsResult()
        let ok = text.withCString { text in
            ptts_speak(handle, text, { pcm, count, user in
                guard !Task.isCancelled, let pcm, let user else { return false }
                Unmanaged<Collector>.fromOpaque(user).takeUnretainedValue().samples.append(contentsOf:
                    UnsafeBufferPointer(start: pcm, count: count))
                return true
            }, user, &result)
        }
        try Task.checkCancellation()
        guard ok else { throw Failure.render }
        return Audio(samples: collector.samples, seconds: Double(result.samples) / Phonon.sampleRate,
                     first: result.ttfa_ms / 1000)
    }

    private final class Collector { var samples: [Float] = [] }
    private final class HandleOwner {
        let pointer: OpaquePointer
        init(_ pointer: OpaquePointer) { self.pointer = pointer }
        deinit { ptts_free(pointer) }
    }
}
