import XCTest
@testable import WeChatHUD

final class BundleSelfCheckTests: XCTestCase {
    func testBundledResourcesAndNativeDependencyAreUsable() {
        XCTAssertEqual(BundleSelfCheck.inspect()["result"], "ready")
    }

    func testMissingOrEmptyPromptFailsWithoutLeakingError() {
        let failure = BundleSelfCheck.inspect { _ in
            throw NSError(domain: "private-source-path-and-secret", code: 1)
        }
        XCTAssertEqual(failure["result"], "failed")
        XCTAssertFalse(String(describing: failure).contains("private-source"))
        XCTAssertEqual(BundleSelfCheck.inspect { _ in " " }["result"], "failed")
    }
}
