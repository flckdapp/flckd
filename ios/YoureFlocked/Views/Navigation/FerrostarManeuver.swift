@preconcurrency import FerrostarCoreFFI

/// Translates Ferrostar's maneuver vocabulary into the app's.
///
/// Ferrostar reports a maneuver the way OSRM does: a coarse type plus a
/// separate turn modifier. The app's `ManeuverType` is Valhalla's single
/// enumeration, and its symbol table is the one the route planner's step list
/// and the Live Activity already draw from. Mapping onto it here, rather than
/// adding a second icon table for the driving screen, is what keeps the arrow
/// above the windscreen identical to the one in the step list — and it means
/// there is still only one table to get wrong, and it is tested.
///
/// An absent or unexpected modifier degrades to a straight-ahead maneuver
/// instead of guessing a side. A mirrored arrow is worse than no arrow: it
/// tells the driver to turn the wrong way.
enum FerrostarManeuver {

    static func appManeuver(
        type: FerrostarCoreFFI.ManeuverType?,
        modifier: FerrostarCoreFFI.ManeuverModifier?
    ) -> ManeuverType {
        guard let type else { return .continue }

        switch type {
        case .depart:
            switch side(of: modifier) {
            case .right: return .startRight
            case .left: return .startLeft
            case .none: return .start
            }

        case .arrive:
            switch side(of: modifier) {
            case .right: return .destinationRight
            case .left: return .destinationLeft
            case .none: return .destination
            }

        // `roundaboutTurn` is a roundabout small enough that the driver is
        // given a plain turn, so it belongs with the turns rather than with
        // the roundabouts.
        case .turn, .endOfRoad, .continue, .roundaboutTurn:
            return directional(modifier) ?? .continue

        case .newName:
            return .becomes

        case .merge:
            switch side(of: modifier) {
            case .right: return .mergeRight
            case .left: return .mergeLeft
            case .none: return .merge
            }

        case .onRamp:
            switch side(of: modifier) {
            case .right: return .rampRight
            case .left: return .rampLeft
            case .none: return .rampStraight
            }

        case .offRamp:
            switch side(of: modifier) {
            case .right: return .exitRight
            case .left: return .exitLeft
            // Valhalla has no sideless exit. "Take the ramp" is the honest
            // reading of an off-ramp whose side the response did not state.
            case .none: return .rampStraight
            }

        case .fork:
            switch side(of: modifier) {
            case .right: return .stayRight
            case .left: return .stayLeft
            case .none: return .stayStraight
            }

        case .roundabout, .rotary:
            return .roundaboutEnter

        case .exitRoundabout, .exitRotary:
            return .roundaboutExit

        // Not a maneuver: a notice that something about the road changed.
        case .notification:
            return .continue
        }
    }

    /// The turn itself, for the maneuver types where the modifier *is* the
    /// instruction. `nil` when there is no modifier to turn into one.
    private static func directional(_ modifier: FerrostarCoreFFI.ManeuverModifier?) -> ManeuverType? {
        switch modifier {
        case .sharpRight: return .sharpRight
        case .right: return .right
        case .slightRight: return .slightRight
        case .straight: return .continue
        case .slightLeft: return .slightLeft
        case .left: return .left
        case .sharpLeft: return .sharpLeft
        // Ferrostar carries one U-turn modifier; Valhalla splits it by the
        // side the turn is made from. Every region the app ships road data
        // for drives on the right, where a U-turn is made to the left. Both
        // cases read "Make a U-turn", so only the arrow differs.
        case .uTurn: return .uturnLeft
        case nil: return nil
        }
    }

    private enum Side {
        case left
        case right
        case none
    }

    private static func side(of modifier: FerrostarCoreFFI.ManeuverModifier?) -> Side {
        switch modifier {
        case .sharpRight, .right, .slightRight: return .right
        case .sharpLeft, .left, .slightLeft: return .left
        // A U-turn onto a ramp or out of a fork is not something the app has
        // a symbol for, so it loses the side rather than inventing one.
        case .uTurn, .straight, nil: return .none
        }
    }
}
