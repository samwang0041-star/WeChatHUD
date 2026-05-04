import XCTest
@testable import WeChatHUD

final class PanelStateTests: XCTestCase {
    @MainActor
    func testClosingPopoverAfterMouseExitSchedulesCollapse() {
        let state = PanelState()
        state.currentState = .extended
        state.popoverOpen = true

        state.mouseExited()
        XCTAssertEqual(state.currentState, .extended)

        state.popoverOpen = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.55))

        XCTAssertEqual(state.currentState, .compact)
    }

    @MainActor
    func testClosingMenuAfterStaleMouseInsideResampleCanCollapse() {
        let state = PanelState()
        state.currentState = .extended
        state.updateMouseInside(true)
        state.popoverOpen = true

        state.updateMouseInside(false)
        state.popoverOpen = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.55))

        XCTAssertEqual(state.currentState, .compact)
    }

    @MainActor
    func testNotificationCollapsesOnMouseExit() {
        let state = PanelState()
        state.currentState = .notification
        state.updateMouseInside(true)

        state.mouseExited()
        RunLoop.main.run(until: Date().addingTimeInterval(0.55))

        XCTAssertEqual(state.currentState, .compact)
    }
}
