import FerrostarCoreFFI
import XCTest
@testable import YoureFlocked

/// Guidance banners arrive in OSRM's vocabulary and the rest of the app speaks
/// Valhalla's, so one table reconciles them. The property that matters is the
/// one `ManeuverTypeTests` already asserts for the symbols: a maneuver that
/// points right must never end up drawn as a left turn. A mirrored arrow on a
/// windscreen is worse than no arrow.
final class ManeuverSymbolMappingTests: XCTestCase {

    /// Ferrostar's enums carry no raw value and aren't `CaseIterable`, so the
    /// lists are written out. A case added upstream breaks the mapping's own
    /// exhaustive switch, which is the compiler's job; these lists are here to
    /// check what every pair this build can see resolves to.
    private let types: [FerrostarCoreFFI.ManeuverType] = [
        .turn, .newName, .depart, .arrive, .merge, .onRamp, .offRamp, .fork,
        .endOfRoad, .continue, .roundabout, .rotary, .roundaboutTurn,
        .notification, .exitRoundabout, .exitRotary,
    ]

    private let modifiers: [FerrostarCoreFFI.ManeuverModifier] = [
        .uTurn, .sharpRight, .right, .slightRight,
        .straight, .slightLeft, .left, .sharpLeft,
    ]

    private var modifierStates: [FerrostarCoreFFI.ManeuverModifier?] {
        let present: [FerrostarCoreFFI.ManeuverModifier?] = modifiers.map { $0 }
        return present + [nil]
    }

    private let rightHandCases: Set<YoureFlocked.ManeuverType> = [
        .startRight, .destinationRight, .slightRight, .right, .sharpRight,
        .uturnRight, .rampRight, .exitRight, .stayRight, .mergeRight,
    ]

    private let leftHandCases: Set<YoureFlocked.ManeuverType> = [
        .startLeft, .destinationLeft, .slightLeft, .left, .sharpLeft,
        .uturnLeft, .rampLeft, .exitLeft, .stayLeft, .mergeLeft,
    ]

    // MARK: - Totality

    func testEveryTypeAndModifierPairResolvesToSomethingDrivable() {
        for type in types {
            for modifier in modifierStates {
                let resolved = ManeuverType(
                    osrmType: type,
                    modifier: modifier,
                    roundaboutExitDegrees: nil
                )

                XCTAssertTrue(
                    resolved.isDrivable,
                    "\(type) + \(describe(modifier)) resolved to \(resolved), which can't appear on a car route"
                )
                XCTAssertFalse(resolved.symbolName.isEmpty, "\(type) + \(describe(modifier))")
                XCTAssertFalse(resolved.displayLabel.isEmpty, "\(type) + \(describe(modifier))")
            }
        }
    }

    /// A roundabout exit angle must not change whether the result is usable; it
    /// only decides whether a mini-roundabout draws as a roundabout or a turn.
    func testTheExitAngleNeverMakesAPairUndrawable() {
        for type in types {
            for modifier in modifierStates {
                let resolved = ManeuverType(
                    osrmType: type,
                    modifier: modifier,
                    roundaboutExitDegrees: 180
                )

                XCTAssertTrue(resolved.isDrivable, "\(type) + \(describe(modifier))")
                XCTAssertFalse(resolved.symbolName.isEmpty, "\(type) + \(describe(modifier))")
            }
        }
    }

    // MARK: - Handedness

    /// The handedness property, over cases rather than strings, because the
    /// side-agnostic maneuvers borrow a symbol that names a side: all three
    /// merges share one glyph and both roundabouts share a right-hand one. Those
    /// are excluded here the same way `ManeuverTypeTests` excludes the merges.
    func testARightHandModifierNeverResolvesToALeftHandManeuver() {
        for type in types {
            for modifier in modifiers {
                guard let side = side(of: modifier) else { continue }
                let resolved = ManeuverType(
                    osrmType: type,
                    modifier: modifier,
                    roundaboutExitDegrees: nil
                )
                let wrong = side == "right" ? leftHandCases : rightHandCases

                XCTAssertFalse(
                    wrong.contains(resolved),
                    "\(type) + \(modifier) points \(side) but resolved to \(resolved)"
                )

                if rightHandCases.contains(resolved) || leftHandCases.contains(resolved) {
                    XCTAssertFalse(
                        resolved.symbolName.contains(side == "right" ? "left" : "right"),
                        "\(type) + \(modifier) draws '\(resolved.symbolName)'"
                    )
                }
            }
        }
    }

    // MARK: - The table itself

    func testPlainTurnsKeepTheirSideAndTheirSharpness() {
        XCTAssertEqual(mapping(.turn, .right), .right)
        XCTAssertEqual(mapping(.turn, .left), .left)
        XCTAssertEqual(mapping(.turn, .slightRight), .slightRight)
        XCTAssertEqual(mapping(.turn, .slightLeft), .slightLeft)
        XCTAssertEqual(mapping(.turn, .sharpRight), .sharpRight)
        XCTAssertEqual(mapping(.turn, .sharpLeft), .sharpLeft)
        XCTAssertEqual(mapping(.turn, .straight), .continue)
    }

    /// Valhalla serialises its exit maneuvers as `off ramp`, so an off-ramp is
    /// an exit in the app's vocabulary; a sideless one falls back to the ramp.
    func testRampsAndExitsKeepTheirSide() {
        XCTAssertEqual(mapping(.offRamp, .slightRight), .exitRight)
        XCTAssertEqual(mapping(.offRamp, .slightLeft), .exitLeft)
        XCTAssertEqual(mapping(.offRamp, nil), .rampStraight)
        XCTAssertEqual(mapping(.onRamp, .right), .rampRight)
        XCTAssertEqual(mapping(.onRamp, .left), .rampLeft)
        XCTAssertEqual(mapping(.onRamp, .straight), .rampStraight)
    }

    func testStartAndArrivalMapToTheirOwnCases() {
        XCTAssertEqual(mapping(.depart, nil), .start)
        XCTAssertEqual(mapping(.depart, .right), .startRight)
        XCTAssertEqual(mapping(.depart, .left), .startLeft)
        XCTAssertEqual(mapping(.arrive, nil), .destination)
        XCTAssertEqual(mapping(.arrive, .right), .destinationRight)
        XCTAssertEqual(mapping(.arrive, .left), .destinationLeft)
    }

    func testMergesForksAndEndsOfRoad() {
        XCTAssertEqual(mapping(.merge, nil), .merge)
        XCTAssertEqual(mapping(.merge, .slightRight), .mergeRight)
        XCTAssertEqual(mapping(.merge, .slightLeft), .mergeLeft)

        XCTAssertEqual(mapping(.fork, .right), .stayRight)
        XCTAssertEqual(mapping(.fork, .left), .stayLeft)
        XCTAssertEqual(mapping(.fork, .straight), .stayStraight)
        XCTAssertEqual(mapping(.fork, nil), .stayStraight)

        XCTAssertEqual(mapping(.endOfRoad, .right), .right)
        XCTAssertEqual(mapping(.endOfRoad, .left), .left)
    }

    func testContinuingAndRenamedRoadsDoNotInventATurn() {
        XCTAssertEqual(mapping(.continue, .straight), .continue)
        XCTAssertEqual(mapping(.continue, nil), .continue)
        XCTAssertEqual(mapping(.newName, .straight), .continue)
        XCTAssertEqual(mapping(.newName, nil), .becomes)
        XCTAssertEqual(mapping(.notification, nil), .continue)
    }

    /// Both roundabout maneuvers have to keep their own symbol: rendering one as
    /// "carry on straight" is a missed turn, which is what the app's first icon
    /// table did.
    func testRoundaboutsStayRoundabouts() {
        for modifier in modifierStates {
            XCTAssertEqual(
                ManeuverType(osrmType: .roundabout, modifier: modifier, roundaboutExitDegrees: 270),
                .roundaboutEnter
            )
            XCTAssertEqual(
                ManeuverType(osrmType: .rotary, modifier: modifier, roundaboutExitDegrees: nil),
                .roundaboutEnter
            )
            XCTAssertEqual(
                ManeuverType(osrmType: .exitRoundabout, modifier: modifier, roundaboutExitDegrees: nil),
                .roundaboutExit
            )
            XCTAssertEqual(
                ManeuverType(osrmType: .exitRotary, modifier: modifier, roundaboutExitDegrees: nil),
                .roundaboutExit
            )
        }

        XCTAssertNotEqual(ManeuverType.roundaboutEnter.symbolName, "arrow.up")
    }

    /// A mini-roundabout instructed as a turn reads better as that turn. OSRM
    /// sends an exit angle only when it wants the driver to go round, so the
    /// angle is the signal.
    func testMiniRoundaboutsDrawTheTurnWhenThereIsNoExitAngle() {
        XCTAssertEqual(
            ManeuverType(osrmType: .roundaboutTurn, modifier: .right, roundaboutExitDegrees: nil),
            .right
        )
        XCTAssertEqual(
            ManeuverType(osrmType: .roundaboutTurn, modifier: .right, roundaboutExitDegrees: 90),
            .roundaboutEnter
        )
        XCTAssertEqual(
            ManeuverType(osrmType: .roundaboutTurn, modifier: nil, roundaboutExitDegrees: nil),
            .roundaboutEnter
        )
    }

    /// OSRM's `uTurn` says nothing about which way you swing. Every region pack
    /// the app can download is a US state, so it swings left.
    func testUTurnsResolveToTheRightHandTrafficDirection() {
        XCTAssertEqual(mapping(.turn, .uTurn), .uturnLeft)
        XCTAssertEqual(mapping(.continue, .uTurn), .uturnLeft)
        XCTAssertEqual(mapping(.endOfRoad, .uTurn), .uturnLeft)
        XCTAssertTrue(ManeuverType.uturnLeft.symbolName.contains("left"))
    }

    /// Ferrostar types both fields as optional. A banner with neither has to
    /// render as something, and a banner with only a modifier is best read as
    /// the turn it names.
    func testAMissingTypeFallsBackToTheModifierThenToUnknown() {
        XCTAssertEqual(mapping(nil, nil), .unknown)
        XCTAssertEqual(mapping(nil, .right), .right)
        XCTAssertEqual(mapping(nil, .slightLeft), .slightLeft)
        XCTAssertEqual(mapping(.turn, nil), .unknown)
        XCTAssertTrue(ManeuverType.unknown.isDrivable)
    }

    // MARK: - Helpers

    private func mapping(
        _ type: FerrostarCoreFFI.ManeuverType?,
        _ modifier: FerrostarCoreFFI.ManeuverModifier?
    ) -> YoureFlocked.ManeuverType {
        YoureFlocked.ManeuverType(osrmType: type, modifier: modifier, roundaboutExitDegrees: nil)
    }

    private func side(of modifier: FerrostarCoreFFI.ManeuverModifier) -> String? {
        switch modifier {
        case .sharpRight, .right, .slightRight: return "right"
        case .sharpLeft, .left, .slightLeft: return "left"
        case .straight, .uTurn: return nil
        }
    }

    private func describe(_ modifier: FerrostarCoreFFI.ManeuverModifier?) -> String {
        modifier.map { "\($0)" } ?? "no modifier"
    }
}
