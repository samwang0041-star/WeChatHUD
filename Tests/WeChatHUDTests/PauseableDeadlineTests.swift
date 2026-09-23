import XCTest
@testable import WeChatHUD

/// The toast / undo bar countdown must not expire while the user cannot see
/// the screen. A deadline is a promise to be seen, not a race.
final class PauseableDeadlineTests: XCTestCase {

    @MainActor
    func testFiresWhenLeftAlone() {
        let fired = expectation(description: "deadline fires")
        let deadline = PauseableDeadline { fired.fulfill() }
        deadline.start(0.05)
        wait(for: [fired], timeout: 1)
    }

    @MainActor
    func testCancelDropsTheCountdown() {
        let fired = expectation(description: "must not fire")
        fired.isInverted = true
        let deadline = PauseableDeadline { fired.fulfill() }
        deadline.start(0.05)
        deadline.cancel()
        wait(for: [fired], timeout: 0.3)
    }

    @MainActor
    func testRestartReplacesThePreviousCountdown() {
        var fires = 0
        let fired = expectation(description: "the replacement fires")
        let deadline = PauseableDeadline {
            fires += 1
            fired.fulfill()
        }
        deadline.start(0.25)
        deadline.start(0.05)
        wait(for: [fired], timeout: 1)
        // Give the replaced 250ms countdown time to misfire if it survived.
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        XCTAssertEqual(fires, 1)
    }

    @MainActor
    func testSuspensionFreezesTheRemainderAndResumeFinishesIt() {
        let fired = expectation(description: "fires after the session returns")
        let deadline = PauseableDeadline { fired.fulfill() }
        deadline.start(0.2)
        deadline.suspend()
        // Well past the original deadline: the frozen clock must not fire.
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        deadline.resume()
        wait(for: [fired], timeout: 1)
    }

    @MainActor
    func testCancelWhileSuspendedStaysDead() {
        let fired = expectation(description: "must not fire")
        fired.isInverted = true
        let deadline = PauseableDeadline { fired.fulfill() }
        deadline.start(0.2)
        deadline.suspend()
        deadline.cancel()
        deadline.resume()
        wait(for: [fired], timeout: 0.5)
    }
}
