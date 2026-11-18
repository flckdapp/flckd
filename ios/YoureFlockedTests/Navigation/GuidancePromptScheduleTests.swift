import XCTest
@testable import YoureFlocked

final class GuidancePromptScheduleTests: XCTestCase {
    private let mile = GuidancePromptSchedule.metersPerMile

    func testHighwayContinueAndEveryCountdownThenFinal() {
        var schedule = GuidancePromptSchedule()
        let length = mile * 5
        XCTAssertEqual(schedule.update(step: 0, length: length, remaining: length, speed: 25), .continueRoad("continue_mi.5_00"))
        for threshold in GuidancePromptSchedule.countdown {
            XCTAssertEqual(schedule.update(step: 0, length: length, remaining: threshold.meters, speed: 25),
                           .approach(threshold.key, meters: threshold.meters))
            XCTAssertNil(schedule.update(step: 0, length: length, remaining: threshold.meters, speed: 25))
        }
        XCTAssertEqual(schedule.update(step: 0, length: length, remaining: 150, speed: 25), .final)
        XCTAssertNil(schedule.update(step: 0, length: length, remaining: 140, speed: 25))
    }

    func testMediumStepStartsCountdownAtOneMile() {
        var schedule = GuidancePromptSchedule()
        let length = mile * 1.5
        XCTAssertEqual(schedule.update(step: 1, length: length, remaining: length, speed: 20), .continueRoad("continue_mi.1_50"))
        XCTAssertEqual(schedule.update(step: 1, length: length, remaining: mile, speed: 20), .approach("1mi", meters: mile))
    }

    func testCityStepGetsFiveHundredFeetThenFinalWithoutContinue() {
        var schedule = GuidancePromptSchedule()
        XCTAssertNil(schedule.update(step: 0, length: 250, remaining: 250, speed: 10))
        XCTAssertEqual(schedule.update(step: 0, length: 250, remaining: 152.4, speed: 10), .approach("500ft", meters: 152.4))
        XCTAssertEqual(schedule.update(step: 0, length: 250, remaining: 60, speed: 10), .final)
    }

    func testVeryShortStepHasFinalOnly() {
        var schedule = GuidancePromptSchedule()
        XCTAssertNil(schedule.update(step: 0, length: 100, remaining: 100, speed: 10))
        XCTAssertEqual(schedule.update(step: 0, length: 100, remaining: 60, speed: 10), .final)
        XCTAssertNil(schedule.update(step: 0, length: 100, remaining: 60, speed: 10))
    }

    func testJumpPastTwoThresholdsSpeaksOnlyNearest() {
        var schedule = GuidancePromptSchedule()
        _ = schedule.update(step: 0, length: mile * 3, remaining: mile * 3, speed: 20)
        XCTAssertEqual(schedule.update(step: 0, length: mile * 3, remaining: mile * 0.8, speed: 20), .approach("1mi", meters: mile))
        XCTAssertNil(schedule.update(step: 0, length: mile * 3, remaining: mile * 0.8, speed: 20))
        XCTAssertNil(schedule.update(step: 0, length: mile * 3, remaining: mile * 2.1, speed: 20))
        XCTAssertNil(schedule.update(step: 0, length: mile * 3, remaining: mile * 0.8, speed: 20))
        XCTAssertEqual(schedule.update(step: 0, length: mile * 3, remaining: 30, speed: 20), .final)
    }

    func testStepAdvanceAndRerouteReset() {
        var schedule = GuidancePromptSchedule()
        for step in 0...1 {
            XCTAssertEqual(schedule.update(step: step, length: 100, remaining: 30, speed: 5), .final)
            XCTAssertNil(schedule.update(step: step, length: 100, remaining: 30, speed: 5))
        }
        schedule.reset()
        XCTAssertEqual(schedule.update(step: 1, length: 100, remaining: 30, speed: 5), .final)
        schedule.reset()
        XCTAssertEqual(schedule.update(step: 0, length: mile * 3, remaining: mile * 3, speed: 20), .continueRoad("continue_mi.3_00"))
    }

    func testSpeedScaledFinalAtFifteenAndSeventyMPH() {
        let slow = 15 * mile / 3600
        let fast = 70 * mile / 3600
        XCTAssertEqual(GuidancePromptSchedule.finalDistance(speed: slow), 40.2336, accuracy: 0.001)
        XCTAssertEqual(GuidancePromptSchedule.finalDistance(speed: fast), 150)
        for speed in [slow, fast] {
            var schedule = GuidancePromptSchedule()
            let trigger = GuidancePromptSchedule.finalDistance(speed: speed)
            XCTAssertNil(schedule.update(step: 0, length: 200, remaining: 200, speed: speed))
            XCTAssertEqual(schedule.update(step: 0, length: 200, remaining: trigger, speed: speed), .final)
        }
        XCTAssertEqual(GuidancePromptSchedule.finalDistance(speed: 0), 30)
        XCTAssertEqual(GuidancePromptSchedule.finalDistance(speed: -1), 80.4, accuracy: 0.001)
    }

    func testApproachNearFinalIsSkippedEvenAfterJump() {
        var schedule = GuidancePromptSchedule()
        XCTAssertNil(schedule.update(step: 0, length: 300, remaining: 300, speed: 31))
        XCTAssertNil(schedule.update(step: 0, length: 300, remaining: 152, speed: 31))
        XCTAssertEqual(schedule.update(step: 0, length: 300, remaining: 150, speed: 31), .final)
        schedule.reset()
        _ = schedule.update(step: 0, length: mile * 3, remaining: mile * 3, speed: 31)
        XCTAssertNil(schedule.update(step: 0, length: mile * 3, remaining: 180, speed: 31))
        XCTAssertEqual(schedule.update(step: 0, length: mile * 3, remaining: 140, speed: 31), .final)
    }

    func testContinueNeedsRoomBeforeCountdownAndNeverCatchesUpLate() {
        var schedule = GuidancePromptSchedule()
        XCTAssertNil(schedule.update(step: 0, length: mile * 2 + 10, remaining: mile * 2 + 10, speed: 20))
        XCTAssertNil(schedule.update(step: 0, length: mile * 2 + 10, remaining: mile * 2 + 5, speed: 20))
        XCTAssertEqual(schedule.update(step: 0, length: mile * 2 + 10, remaining: mile * 2, speed: 20), .approach("2mi", meters: mile * 2))
        schedule.reset()
        XCTAssertEqual(schedule.update(step: 0, length: mile * 5, remaining: mile * 0.8, speed: 20), .approach("1mi", meters: mile))
    }

    func testContinueQuarterMileRoundingAndLimits() {
        XCTAssertNil(GuidancePromptSchedule.continueKey(miles: 0.124))
        XCTAssertEqual(GuidancePromptSchedule.continueKey(miles: 0.125), "continue_mi.0_25")
        XCTAssertEqual(GuidancePromptSchedule.continueKey(miles: 0.13), "continue_mi.0_25")
        XCTAssertEqual(GuidancePromptSchedule.continueKey(miles: 2.4), "continue_mi.2_50")
        XCTAssertEqual(GuidancePromptSchedule.continueKey(miles: 9.9), "continue_mi.10_00")
        XCTAssertEqual(GuidancePromptSchedule.continueKey(miles: 10.2), "continue_long")
        XCTAssertEqual(GuidancePromptSchedule.continueKeys.count, 40)
        for quarter in 1...40 {
            XCTAssertTrue(GuidancePromptSchedule.continueKeys.contains(GuidancePromptSchedule.continueKey(miles: Double(quarter) / 4) ?? ""))
        }
    }

    func testInvalidFixDoesNotConsumeSchedule() {
        var schedule = GuidancePromptSchedule()
        XCTAssertNil(schedule.update(step: 0, length: 100, remaining: .nan, speed: 5))
        XCTAssertNil(schedule.update(step: 0, length: 100, remaining: -1, speed: 5))
        XCTAssertEqual(schedule.update(step: 0, length: 100, remaining: 30, speed: 5), .final)
    }
}
