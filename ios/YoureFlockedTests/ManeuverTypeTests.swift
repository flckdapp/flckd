import XCTest
@testable import YoureFlocked

/// The numbers here are Valhalla 3.6.3's `DirectionsLeg.Maneuver.Type`, the
/// version `valhalla-mobile` 0.6.3 compiles in. They are the reason this file
/// exists: the app's first icon table assumed `continue` was 7 when it is 8, so
/// every maneuver from there on drew the wrong symbol, including four that
/// pointed the opposite way.
final class ManeuverTypeTests: XCTestCase {

    /// Pins the whole table. A transcription slip anywhere in it shows up here
    /// rather than on a windscreen.
    func testValhallaIntegerCodesMapToNamedManeuvers() {
        let authoritative: [Int: ManeuverType] = [
            0: .noManeuver, 1: .start, 2: .startRight, 3: .startLeft,
            4: .destination, 5: .destinationRight, 6: .destinationLeft,
            7: .becomes, 8: .continue, 9: .slightRight, 10: .right,
            11: .sharpRight, 12: .uturnRight, 13: .uturnLeft, 14: .sharpLeft,
            15: .left, 16: .slightLeft, 17: .rampStraight, 18: .rampRight,
            19: .rampLeft, 20: .exitRight, 21: .exitLeft, 22: .stayStraight,
            23: .stayRight, 24: .stayLeft, 25: .merge, 26: .roundaboutEnter,
            27: .roundaboutExit, 28: .ferryEnter, 29: .ferryExit, 30: .transit,
            31: .transitTransfer, 32: .transitRemainOn,
            33: .transitConnectionStart, 34: .transitConnectionTransfer,
            35: .transitConnectionDestination,
            36: .postTransitConnectionDestination,
            37: .mergeRight, 38: .mergeLeft, 39: .elevatorEnter,
            40: .stepsEnter, 41: .escalatorEnter, 42: .buildingEnter,
            43: .buildingExit, 44: .levelChange,
        ]

        for (code, expected) in authoritative {
            XCTAssertEqual(ManeuverType(code: code), expected,
                           "Valhalla code \(code) decoded to the wrong maneuver")
        }
    }

    /// Drawing a left arrow for a right-hand maneuver is worse than drawing
    /// nothing, so this asserts the property rather than a list of expected
    /// strings: whatever symbol is chosen, its name has to state the correct
    /// side. This is what the shipped table failed, on u-turns, ramps and exits.
    func testRightHandManeuversNeverResolveToALeftHandSymbol() {
        let pairs: [(String, ManeuverType, ManeuverType)] = [
            ("slight", .slightRight, .slightLeft),
            ("plain", .right, .left),
            ("sharp", .sharpRight, .sharpLeft),
            ("u-turn", .uturnRight, .uturnLeft),
            ("ramp", .rampRight, .rampLeft),
            ("exit", .exitRight, .exitLeft),
            ("stay", .stayRight, .stayLeft),
        ]

        for (name, rightHand, leftHand) in pairs {
            let right = rightHand.symbolName
            let left = leftHand.symbolName

            XCTAssertTrue(right.contains("right"), "\(name) right uses '\(right)'")
            XCTAssertFalse(right.contains("left"), "\(name) right is mirrored: '\(right)'")
            XCTAssertTrue(left.contains("left"), "\(name) left uses '\(left)'")
            XCTAssertFalse(left.contains("right"), "\(name) left is mirrored: '\(left)'")
            XCTAssertNotEqual(right, left, "\(name) draws one symbol for both sides")
        }
    }

    /// A roundabout that renders as "carry on straight" is a missed turn. Both
    /// roundabout maneuvers fell through to the default arrow before, because
    /// the table had them one number early.
    func testRoundaboutsDoNotResolveToTheStraightAheadFallback() {
        XCTAssertNotEqual(ManeuverType.roundaboutEnter.symbolName, "arrow.up")
        XCTAssertNotEqual(ManeuverType.roundaboutExit.symbolName, "arrow.up")
    }

    /// Valhalla has added maneuver types before, and the region packs are
    /// pinned to a tile format rather than to a response schema. An unfamiliar
    /// number has to render as something, or one odd maneuver loses the leg.
    func testUnrecognisedCodesDegradeInsteadOfFailing() {
        for code in [45, 99, -7, Int.max] {
            XCTAssertEqual(ManeuverType(code: code), .unknown, "code \(code)")
        }
        XCTAssertFalse(ManeuverType.unknown.symbolName.isEmpty)
        XCTAssertFalse(ManeuverType.unknown.displayLabel.isEmpty)
    }

    /// `maneuverIcon` used to answer for any `Int`, so a case added later could
    /// silently inherit the straight-ahead arrow. Switching over the enum means
    /// the compiler catches that, and this catches an empty string.
    func testEveryManeuverHasASymbolAndALabel() {
        for type in ManeuverType.allCases {
            XCTAssertFalse(type.symbolName.isEmpty, "\(type) has no symbol")
            XCTAssertFalse(type.displayLabel.isEmpty, "\(type) has no label")
        }
    }

    /// The Live Activity encodes its state and ActivityKit holds it across an
    /// app update, so the maneuver has to survive a round-trip by number.
    func testManeuverSurvivesCodableRoundTrip() throws {
        for type in ManeuverType.allCases {
            let data = try JSONEncoder().encode(type)
            XCTAssertEqual(try JSONDecoder().decode(ManeuverType.self, from: data), type)
        }
    }

    /// Transit and indoor maneuvers can't occur on an `auto` route, which is the
    /// only costing this app requests. A turn card can ignore them.
    func testDrivingManeuversAreSeparatedFromTransitAndIndoorOnes() {
        XCTAssertTrue(ManeuverType.right.isDrivable)
        XCTAssertTrue(ManeuverType.roundaboutEnter.isDrivable)
        XCTAssertTrue(ManeuverType.unknown.isDrivable)
        XCTAssertFalse(ManeuverType.transit.isDrivable)
        XCTAssertFalse(ManeuverType.stepsEnter.isDrivable)
        XCTAssertFalse(ManeuverType.levelChange.isDrivable)
    }
}
