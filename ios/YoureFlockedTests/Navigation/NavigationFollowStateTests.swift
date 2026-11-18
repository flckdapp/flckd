import XCTest
@testable import YoureFlocked

final class NavigationFollowStateTests: XCTestCase {
    func testFirstTouchYieldsBeforeAnyRegionCallback() {
        var state = NavigationFollowState()
        XCTAssertTrue(state.canDriveCamera)
        state.beginInteraction()
        XCTAssertFalse(state.canDriveCamera)
        XCTAssertFalse(state.following)
        state.endInteraction()
        XCTAssertFalse(state.canDriveCamera)
        state.recenter()
        XCTAssertTrue(state.canDriveCamera)
    }

    func testRecenterCannotFightAnActiveMultiTouchGesture() {
        var state = NavigationFollowState()
        state.beginInteraction()
        state.recenter()
        XCTAssertFalse(state.canDriveCamera)
        state.endInteraction()
        XCTAssertTrue(state.canDriveCamera)
        state.beginInteraction()
        state.stopFollowing()
        state.endInteraction()
        XCTAssertFalse(state.canDriveCamera)
    }

    func testASecondGestureCancelsAPendingRecenter() {
        var state = NavigationFollowState()
        state.beginInteraction()
        state.recenter()
        state.beginInteraction()
        state.endInteraction()
        XCTAssertFalse(state.canDriveCamera)
    }
}
