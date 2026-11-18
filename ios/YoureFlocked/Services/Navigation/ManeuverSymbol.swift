import Foundation
import FerrostarCoreFFI

/// Which way a maneuver modifier points, when it points anywhere.
///
/// Most of the Valhalla cases a guidance banner can land on come in a left and
/// a right flavour and nothing else, so the sharpness in the modifier is noise
/// for them. Reading the side once keeps that out of every branch below.
private enum Hand {
    case right
    case left

    init?(_ modifier: FerrostarCoreFFI.ManeuverModifier) {
        switch modifier {
        case .sharpRight, .right, .slightRight:
            self = .right
        case .sharpLeft, .left, .slightLeft:
            self = .left
        case .straight, .uTurn:
            return nil
        }
    }
}

extension ManeuverType {

    /// The app's maneuver for the one Ferrostar reports.
    ///
    /// Guidance banners reach the app in OSRM's vocabulary — a coarse type and
    /// a modifier — because that is the format Ferrostar parses, while the
    /// engine underneath it and the rest of the app speak Valhalla's numbered
    /// maneuvers. This is the only place the two are reconciled. The widget
    /// draws `ManeuverType.symbolName`, so a second table here is how the
    /// mirrored ramp arrow that `RouteView` used to draw comes back.
    ///
    /// Total, like `init(code:)`: a combination this build doesn't recognise
    /// becomes something drivable rather than nothing. A turn with no side to
    /// it is ``unknown``, which draws a straight arrow — unhelpful, but never
    /// pointing the wrong way, and the banner text beside it still names the
    /// street.
    ///
    /// Valhalla's own OSRM serialiser writes its exit maneuvers as `off ramp`
    /// and its ramp maneuvers as `on ramp`, and its stay-left/right maneuvers
    /// as `fork`, so those come back as the exit and stay cases. Ramps and
    /// exits draw the same symbol either way; only `displayLabel` differs.
    init(
        osrmType: FerrostarCoreFFI.ManeuverType?,
        modifier: FerrostarCoreFFI.ManeuverModifier?,
        roundaboutExitDegrees: UInt16?
    ) {
        guard let osrmType else {
            // A banner with a modifier but no type is malformed. The side is
            // the part a driver acts on, so take the modifier at its word.
            self = Self.turn(for: modifier) ?? .unknown
            return
        }

        let hand = modifier.flatMap(Hand.init)

        switch osrmType {
        case .turn:
            self = Self.turn(for: modifier) ?? .unknown

        case .newName:
            // The road carrying on under a different name is Valhalla's
            // `becomes` exactly. A modifier that names a side is still drawn as
            // that turn, because the bend is what the driver sees.
            self = Self.turn(for: modifier) ?? .becomes

        case .depart:
            switch hand {
            case .right: self = .startRight
            case .left: self = .startLeft
            case nil: self = .start
            }

        case .arrive:
            switch hand {
            case .right: self = .destinationRight
            case .left: self = .destinationLeft
            case nil: self = .destination
            }

        case .merge:
            switch hand {
            case .right: self = .mergeRight
            case .left: self = .mergeLeft
            case nil: self = .merge
            }

        case .onRamp:
            switch hand {
            case .right: self = .rampRight
            case .left: self = .rampLeft
            case nil: self = .rampStraight
            }

        case .offRamp:
            switch hand {
            case .right: self = .exitRight
            case .left: self = .exitLeft
            // Valhalla has no sideless exit. "Take the ramp" is the honest
            // reading of an off-ramp whose side the response did not state.
            case nil: self = .rampStraight
            }

        case .fork:
            // Keeping left or right at a fork is a lane choice, not a turn. The
            // stay cases draw the gentlest arrow that states the side and are
            // labelled "Keep right" rather than "Slight right".
            switch hand {
            case .right: self = .stayRight
            case .left: self = .stayLeft
            case nil: self = .stayStraight
            }

        case .endOfRoad:
            // The road ends and you turn onto another one. How sharp the turn
            // is doesn't matter; which way does.
            switch hand {
            case .right: self = .right
            case .left: self = .left
            case nil: self = Self.turn(for: modifier) ?? .continue
            }

        case .continue:
            self = Self.turn(for: modifier) ?? .continue

        case .roundabout, .rotary:
            self = .roundaboutEnter

        case .roundaboutTurn:
            // A mini-roundabout instructed as an ordinary turn. OSRM carries an
            // exit angle only when it wants the driver to go round, so without
            // one the side of the turn is the more honest arrow.
            if roundaboutExitDegrees == nil, let turn = Self.turn(for: modifier) {
                self = turn
            } else {
                self = .roundaboutEnter
            }

        case .exitRoundabout, .exitRotary:
            self = .roundaboutExit

        case .notification:
            // Not a maneuver at all: something changed about the road the
            // driver is already on.
            self = .continue
        }
    }

    /// The modifier read as a turn in its own right, keeping the sharpness it
    /// states. `nil` only when there is no modifier, which is the one case each
    /// maneuver type has to answer for itself.
    private static func turn(for modifier: FerrostarCoreFFI.ManeuverModifier?) -> ManeuverType? {
        guard let modifier else { return nil }

        switch modifier {
        case .sharpRight: return .sharpRight
        case .right: return .right
        case .slightRight: return .slightRight
        case .straight: return .continue
        case .slightLeft: return .slightLeft
        case .left: return .left
        case .sharpLeft: return .sharpLeft
        case .uTurn: return uTurnForTrafficSide
        }
    }

    /// OSRM's `uTurn` modifier says nothing about which way you swing, and
    /// Valhalla has a case for each. Every region pack this app can download is
    /// a US state, so traffic is right-hand and a U-turn is made to the left.
    /// `.uturnRight` is still reached the other way round, from a Valhalla code
    /// read straight off a maneuver.
    private static let uTurnForTrafficSide: ManeuverType = .uturnLeft
}
