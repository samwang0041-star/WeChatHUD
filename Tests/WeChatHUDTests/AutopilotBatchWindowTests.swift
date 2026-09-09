import XCTest
@testable import WeChatHUD

final class AutopilotBatchWindowTests: XCTestCase {
    private let firstArrival = Date(timeIntervalSince1970: 1_000)

    func testConfiguredWindowIsUsedForFirstMessage() {
        let fiveSecond = AutopilotService.batchDeadline(
            firstArrival: firstArrival,
            now: firstArrival,
            window: 5,
            existingDeadline: nil
        )
        let tenSecond = AutopilotService.batchDeadline(
            firstArrival: firstArrival,
            now: firstArrival,
            window: 10,
            existingDeadline: nil
        )

        XCTAssertEqual(fiveSecond, firstArrival.addingTimeInterval(5))
        XCTAssertEqual(tenSecond, firstArrival.addingTimeInterval(10))
    }

    func testContinuousMessageExtendsByTenSeconds() {
        let deadline = AutopilotService.batchDeadline(
            firstArrival: firstArrival,
            now: firstArrival.addingTimeInterval(15),
            window: 10,
            existingDeadline: firstArrival.addingTimeInterval(10)
        )

        XCTAssertEqual(deadline, firstArrival.addingTimeInterval(25))
    }

    func testContinuousMessageNeverShortensExistingDeadline() {
        let deadline = AutopilotService.batchDeadline(
            firstArrival: firstArrival,
            now: firstArrival.addingTimeInterval(2),
            window: 30,
            existingDeadline: firstArrival.addingTimeInterval(30)
        )

        XCTAssertEqual(deadline, firstArrival.addingTimeInterval(30))
    }

    func testContinuousMessageIsCappedAtSixtySecondsFromFirstArrival() {
        let deadline = AutopilotService.batchDeadline(
            firstArrival: firstArrival,
            now: firstArrival.addingTimeInterval(55),
            window: 30,
            existingDeadline: firstArrival.addingTimeInterval(50)
        )

        XCTAssertEqual(deadline, firstArrival.addingTimeInterval(60))
    }

    func testInitialWindowAlsoHonorsSixtySecondCap() {
        let deadline = AutopilotService.batchDeadline(
            firstArrival: firstArrival,
            now: firstArrival,
            window: 90,
            existingDeadline: nil
        )

        XCTAssertEqual(deadline, firstArrival.addingTimeInterval(60))
    }
}
