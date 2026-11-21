#if DEBUG
import Foundation
import os

/// Ordinals are route-local and contain no OSM IDs, coordinates or text.
struct CameraDiagnosticEvent: Codable {
    var recordType = "cameraTimeline"
    let date: Date
    let ordinal: Int?
    let stage: String
    let reason: String
    let exposed: Int
    let nearbyNotExposed: Int
}

@MainActor
enum CameraDiagnostics {
    private static let log = Logger(subsystem: "io.vws.app.flckd", category: "camera.timeline")
    static func record(ordinal: Int? = nil, stage: String, reason: String = "none", exposed: Int = 0,
                       nearbyNotExposed: Int = 0) {
        let event = CameraDiagnosticEvent(date: Date(), ordinal: ordinal, stage: stage, reason: reason,
            exposed: exposed, nearbyNotExposed: nearbyNotExposed)
        RoutingMetricsStore.shared.recordCameraEvent(event)
        log.notice("camera ordinal=\(ordinal ?? 0, privacy: .public) stage=\(stage, privacy: .public) reason=\(reason, privacy: .public) exposed=\(exposed, privacy: .public) nearbyNotExposed=\(nearbyNotExposed, privacy: .public)")
    }
}
#endif
