import Foundation

/// A Valhalla maneuver type, named.
///
/// The engine reports each maneuver as a bare integer. The numbers are the
/// `DirectionsLeg.Maneuver.Type` enum from Valhalla 3.6.3, which is the version
/// `valhalla-mobile` 0.6.3 compiles in:
/// https://github.com/valhalla/valhalla/blob/e2f017b16080f49203de245a211b09efab09cf72/proto/directions.proto#L41-L87
///
/// Lives in `Shared/` rather than with the app's other models because the Live
/// Activity's `ContentState` carries a maneuver, and the widget target compiles
/// only `YoureFlockedWidgets` and `Shared`. Putting it here is also what stops
/// the turn card and the widget from each keeping their own copy of the symbol
/// table: the icon belongs to the type, so there is one table and it is tested.
/// An earlier private copy of that table in `RouteView` was off by one from
/// `becomes` onwards, which drew a left arrow for a right-hand ramp.
enum ManeuverType: Int, Codable, Hashable, Sendable, CaseIterable {

    /// Valhalla `kNone`. Spelled out rather than `none` so that comparing an
    /// optional maneuver against a case can't collide with `Optional.none`.
    case noManeuver = 0

    case start = 1
    case startRight = 2
    case startLeft = 3

    case destination = 4
    case destinationRight = 5
    case destinationLeft = 6

    /// The road continues under a different name. No action for the driver.
    case becomes = 7
    case `continue` = 8

    case slightRight = 9
    case right = 10
    case sharpRight = 11
    case uturnRight = 12
    case uturnLeft = 13
    case sharpLeft = 14
    case left = 15
    case slightLeft = 16

    case rampStraight = 17
    case rampRight = 18
    case rampLeft = 19
    case exitRight = 20
    case exitLeft = 21

    case stayStraight = 22
    case stayRight = 23
    case stayLeft = 24

    case merge = 25
    case roundaboutEnter = 26
    case roundaboutExit = 27
    case ferryEnter = 28
    case ferryExit = 29

    case transit = 30
    case transitTransfer = 31
    case transitRemainOn = 32
    case transitConnectionStart = 33
    case transitConnectionTransfer = 34
    case transitConnectionDestination = 35
    case postTransitConnectionDestination = 36

    case mergeRight = 37
    case mergeLeft = 38

    // Pedestrian and indoor maneuvers. Present in the engine but absent from
    // Valhalla's published HTTP API reference, and unreachable while routing by
    // car. Named so a code from a walking route doesn't fall through.
    case elevatorEnter = 39
    case stepsEnter = 40
    case escalatorEnter = 41
    case buildingEnter = 42
    case buildingExit = 43
    case levelChange = 44

    /// A code this build doesn't know. Valhalla has added maneuver types before
    /// and the app is pinned to a tile format, not to a response schema, so an
    /// unrecognised number has to degrade rather than fail.
    case unknown = -1

    /// Total, unlike `init(rawValue:)`: every integer maps to a case.
    ///
    /// A route is only useful if it can be drawn, so one unfamiliar maneuver in
    /// the middle of it must not discard the leg. Out-of-range becomes
    /// ``unknown`` and still renders.
    init(code: Int) {
        self = ManeuverType(rawValue: code) ?? .unknown
    }
}

extension ManeuverType {

    /// The SF Symbol to draw for this maneuver.
    ///
    /// Left and right cases always resolve to a symbol whose name states that
    /// side. A mirrored arrow is worse than no arrow: it tells the driver to
    /// turn the wrong way.
    var symbolName: String {
        switch self {
        case .start, .startRight, .startLeft:
            return "arrow.up.circle.fill"

        case .destination, .destinationRight, .destinationLeft:
            return "flag.checkered.circle.fill"

        case .noManeuver, .becomes, .continue, .rampStraight, .stayStraight, .unknown:
            return "arrow.up"

        case .slightRight, .stayRight:
            return "arrow.up.right"
        case .slightLeft, .stayLeft:
            return "arrow.up.left"

        case .right, .rampRight, .exitRight:
            return "arrow.turn.up.right"
        case .left, .rampLeft, .exitLeft:
            return "arrow.turn.up.left"

        case .sharpRight:
            return "arrow.turn.right.down"
        case .sharpLeft:
            return "arrow.turn.left.down"

        case .uturnRight:
            return "arrow.uturn.right"
        case .uturnLeft:
            return "arrow.uturn.left"

        // SF Symbols has no left or right merge glyph, so all three merges share
        // one symbol and the side is carried by ``displayLabel``. Drawing a turn
        // arrow instead would overstate the maneuver.
        case .merge, .mergeRight, .mergeLeft:
            return "arrow.triangle.merge"

        case .roundaboutEnter, .roundaboutExit:
            return "arrow.triangle.turn.up.right.circle"

        case .ferryEnter, .ferryExit:
            return "ferry.fill"

        case .transit, .transitTransfer, .transitRemainOn:
            return "tram.fill"

        case .transitConnectionStart, .transitConnectionTransfer,
             .transitConnectionDestination, .postTransitConnectionDestination:
            return "figure.walk"

        case .elevatorEnter, .levelChange:
            return "arrow.up.arrow.down"
        case .stepsEnter, .escalatorEnter:
            return "figure.stairs"
        case .buildingEnter, .buildingExit:
            return "building.2"
        }
    }

    /// A short label for this maneuver, for when there is no instruction text to
    /// show or an accessibility label is needed. Valhalla's own `instruction`
    /// field is better when it's present: it names the street.
    var displayLabel: String {
        switch self {
        case .noManeuver, .unknown: return "Continue"
        case .start: return "Start"
        case .startRight: return "Start right"
        case .startLeft: return "Start left"
        case .destination: return "Arrive"
        case .destinationRight: return "Arrive on the right"
        case .destinationLeft: return "Arrive on the left"
        case .becomes: return "Continue"
        case .continue: return "Continue"
        case .slightRight: return "Slight right"
        case .right: return "Turn right"
        case .sharpRight: return "Sharp right"
        case .uturnRight: return "Make a U-turn"
        case .uturnLeft: return "Make a U-turn"
        case .sharpLeft: return "Sharp left"
        case .left: return "Turn left"
        case .slightLeft: return "Slight left"
        case .rampStraight: return "Take the ramp"
        case .rampRight: return "Take the ramp on the right"
        case .rampLeft: return "Take the ramp on the left"
        case .exitRight: return "Take the exit on the right"
        case .exitLeft: return "Take the exit on the left"
        case .stayStraight: return "Keep straight"
        case .stayRight: return "Keep right"
        case .stayLeft: return "Keep left"
        case .merge: return "Merge"
        case .mergeRight: return "Merge right"
        case .mergeLeft: return "Merge left"
        case .roundaboutEnter: return "Enter the roundabout"
        case .roundaboutExit: return "Exit the roundabout"
        case .ferryEnter: return "Board the ferry"
        case .ferryExit: return "Leave the ferry"
        case .transit: return "Take transit"
        case .transitTransfer: return "Transfer"
        case .transitRemainOn: return "Stay on board"
        case .transitConnectionStart: return "Enter the station"
        case .transitConnectionTransfer: return "Change station"
        case .transitConnectionDestination: return "Leave the station"
        case .postTransitConnectionDestination: return "Continue on foot"
        case .elevatorEnter: return "Take the elevator"
        case .stepsEnter: return "Take the stairs"
        case .escalatorEnter: return "Take the escalator"
        case .buildingEnter: return "Enter the building"
        case .buildingExit: return "Leave the building"
        case .levelChange: return "Change level"
        }
    }

    /// True for maneuvers a driver can actually be given. Transit, indoor and
    /// pedestrian maneuvers can't appear on an `auto` route, so a turn card has
    /// no reason to handle them.
    var isDrivable: Bool {
        switch self {
        case .transit, .transitTransfer, .transitRemainOn,
             .transitConnectionStart, .transitConnectionTransfer,
             .transitConnectionDestination, .postTransitConnectionDestination,
             .elevatorEnter, .stepsEnter, .escalatorEnter,
             .buildingEnter, .buildingExit, .levelChange:
            return false
        default:
            return true
        }
    }
}
