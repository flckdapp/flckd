import FerrostarCoreFFI
import XCTest
@testable import YoureFlocked

/// Pins the translation from Ferrostar's type-plus-modifier maneuvers to the
/// app's single enumeration. The app's own table is already tested; what is
/// untested without this is the step between them, and a slip there puts a
/// left arrow on a right turn.
///
/// Both modules declare a `ManeuverType`, so every reference here is
/// qualified.
final class FerrostarManeuverTests: XCTestCase {

    private typealias FFIType = FerrostarCoreFFI.ManeuverType
    private typealias FFIModifier = FerrostarCoreFFI.ManeuverModifier
    private typealias AppType = YoureFlocked.ManeuverType

    private static let allModifiers: [FFIModifier] = [
        .uTurn, .sharpRight, .right, .slightRight,
        .straight, .slightLeft, .left, .sharpLeft,
    ]

    private static let allModifiersAndNone: [FFIModifier?] = allModifiers.map { Optional($0) } + [nil]

    /// The families where the modifier is the whole instruction.
    private static let directionalTypes: [FFIType] = [
        .turn, .endOfRoad, .continue, .roundaboutTurn,
    ]

    /// The families that only care which side, not how sharply.
    private static let sidedTypes: [FFIType] = [
        .depart, .arrive, .merge, .onRamp, .offRamp, .fork,
    ]

    /// The families that describe the road rather than a turn.
    private static let modifierFreeTypes: [FFIType] = [
        .newName, .roundabout, .rotary, .exitRoundabout, .exitRotary, .notification,
    ]

    func testTheModifierBecomesTheTurn() {
        let expected: [FFIModifier: AppType] = [
            .sharpRight: .sharpRight,
            .right: .right,
            .slightRight: .slightRight,
            .straight: .continue,
            .slightLeft: .slightLeft,
            .left: .left,
            .sharpLeft: .sharpLeft,
            // Every region the app ships road data for drives on the right,
            // where a U-turn is made to the left.
            .uTurn: .uturnLeft,
        ]

        for type in Self.directionalTypes {
            for (modifier, appType) in expected {
                XCTAssertEqual(
                    FerrostarManeuver.appManeuver(type: type, modifier: modifier),
                    appType,
                    "\(type) with \(modifier)"
                )
            }
            XCTAssertEqual(
                FerrostarManeuver.appManeuver(type: type, modifier: nil),
                .continue,
                "\(type) with no modifier"
            )
        }
    }

    func testSidedFamiliesKeepTheirSide() {
        let expected: [FFIType: (right: AppType, left: AppType, none: AppType)] = [
            .depart: (.startRight, .startLeft, .start),
            .arrive: (.destinationRight, .destinationLeft, .destination),
            .merge: (.mergeRight, .mergeLeft, .merge),
            .onRamp: (.rampRight, .rampLeft, .rampStraight),
            .offRamp: (.exitRight, .exitLeft, .rampStraight),
            .fork: (.stayRight, .stayLeft, .stayStraight),
        ]

        for (type, sides) in expected {
            for modifier in [FFIModifier.sharpRight, .right, .slightRight] {
                XCTAssertEqual(
                    FerrostarManeuver.appManeuver(type: type, modifier: modifier),
                    sides.right,
                    "\(type) with \(modifier)"
                )
            }
            for modifier in [FFIModifier.sharpLeft, .left, .slightLeft] {
                XCTAssertEqual(
                    FerrostarManeuver.appManeuver(type: type, modifier: modifier),
                    sides.left,
                    "\(type) with \(modifier)"
                )
            }
            for modifier in [FFIModifier.straight, .uTurn] {
                XCTAssertEqual(
                    FerrostarManeuver.appManeuver(type: type, modifier: modifier),
                    sides.none,
                    "\(type) with \(modifier)"
                )
            }
            XCTAssertEqual(
                FerrostarManeuver.appManeuver(type: type, modifier: nil),
                sides.none,
                "\(type) with no modifier"
            )
        }
    }

    func testRoadDescriptionsIgnoreTheModifier() {
        let expected: [FFIType: AppType] = [
            .newName: .becomes,
            .roundabout: .roundaboutEnter,
            .rotary: .roundaboutEnter,
            .exitRoundabout: .roundaboutExit,
            .exitRotary: .roundaboutExit,
            .notification: .continue,
        ]

        for (type, appType) in expected {
            for modifier in Self.allModifiersAndNone {
                XCTAssertEqual(
                    FerrostarManeuver.appManeuver(type: type, modifier: modifier),
                    appType,
                    "\(type) with \(String(describing: modifier))"
                )
            }
        }
    }

    /// The one that matters on a windscreen: a turn to one side must never
    /// resolve to a symbol that names the other.
    func testNoManeuverCrossesSides() {
        for type in Self.directionalTypes + Self.sidedTypes {
            for modifier in [FFIModifier.sharpRight, .right, .slightRight] {
                let symbol = FerrostarManeuver.appManeuver(type: type, modifier: modifier).symbolName
                XCTAssertFalse(symbol.contains("left"), "\(type) with \(modifier) drew \(symbol)")
            }
            for modifier in [FFIModifier.sharpLeft, .left, .slightLeft] {
                let symbol = FerrostarManeuver.appManeuver(type: type, modifier: modifier).symbolName
                XCTAssertFalse(symbol.contains("right"), "\(type) with \(modifier) drew \(symbol)")
            }
        }
    }

    func testEveryCombinationIsDrivable() {
        let types: [FFIType] = Self.directionalTypes + Self.sidedTypes + Self.modifierFreeTypes
        for type in types {
            for modifier in Self.allModifiersAndNone {
                let maneuver = FerrostarManeuver.appManeuver(type: type, modifier: modifier)
                XCTAssertTrue(
                    maneuver.isDrivable,
                    "\(type) with \(String(describing: modifier)) produced \(maneuver)"
                )
                XCTAssertNotEqual(maneuver, .unknown, "\(type) with \(String(describing: modifier))")
            }
        }
    }

    func testAMissingTypeStillDraws() {
        XCTAssertEqual(FerrostarManeuver.appManeuver(type: nil, modifier: nil), .continue)
        XCTAssertEqual(FerrostarManeuver.appManeuver(type: nil, modifier: .right), .continue)
    }
}
