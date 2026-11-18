import Foundation

/// Camera ownership changes before MapKit begins moving, not after a region
/// callback. Touching the map yields control even for taps/double-tap zoom.
struct NavigationFollowState {
    private(set) var following = true
    private(set) var interacting = false
    private var recenterRequested = false

    var canDriveCamera: Bool { following && !interacting }

    mutating func beginInteraction() {
        interacting = true
        following = false
        recenterRequested = false
    }

    mutating func endInteraction() {
        interacting = false
        if recenterRequested { following = true; recenterRequested = false }
    }

    mutating func recenter() {
        if interacting { recenterRequested = true } else { following = true }
    }

    mutating func stopFollowing() { following = false; recenterRequested = false }
}
