import XCTest
@testable import WeChatHUD

final class InboxContextBuilderTests: XCTestCase {

    // MARK: - contextWindowSize

    func testContextWindowSizeVeryShort() {
        XCTAssertEqual(InboxContextBuilder.contextWindowSize(messageLength: 2), 15)
    }

    func testContextWindowSizeShort() {
        XCTAssertEqual(InboxContextBuilder.contextWindowSize(messageLength: 15), 10)
    }

    func testContextWindowSizeMedium() {
        XCTAssertEqual(InboxContextBuilder.contextWindowSize(messageLength: 35), 6)
    }

    func testContextWindowSizeLong() {
        XCTAssertEqual(InboxContextBuilder.contextWindowSize(messageLength: 80), 3)
    }

    func testContextWindowSizeBoundaryAt5() {
        XCTAssertEqual(InboxContextBuilder.contextWindowSize(messageLength: 5), 15)
    }

    func testContextWindowSizeBoundaryAt6() {
        XCTAssertEqual(InboxContextBuilder.contextWindowSize(messageLength: 6), 10)
    }

    func testContextWindowSizeBoundaryAt20() {
        XCTAssertEqual(InboxContextBuilder.contextWindowSize(messageLength: 20), 10)
    }

    func testContextWindowSizeBoundaryAt21() {
        XCTAssertEqual(InboxContextBuilder.contextWindowSize(messageLength: 21), 6)
    }

    func testContextWindowSizeBoundaryAt50() {
        XCTAssertEqual(InboxContextBuilder.contextWindowSize(messageLength: 50), 6)
    }

    func testContextWindowSizeBoundaryAt51() {
        XCTAssertEqual(InboxContextBuilder.contextWindowSize(messageLength: 51), 3)
    }

    // MARK: - calculateTrend

    func testTrendUp() {
        let trend = InboxContextBuilder.calculateTrend(dailyCounts: [1, 2, 1, 3, 4, 5, 6])
        XCTAssertEqual(trend, .up)
    }

    func testTrendDown() {
        let trend = InboxContextBuilder.calculateTrend(dailyCounts: [6, 5, 4, 3, 1, 1, 1])
        XCTAssertEqual(trend, .down)
    }

    func testTrendStable() {
        let trend = InboxContextBuilder.calculateTrend(dailyCounts: [3, 3, 3, 3, 3, 3, 3])
        XCTAssertEqual(trend, .stable)
    }

    func testTrendTooFewDays() {
        let trend = InboxContextBuilder.calculateTrend(dailyCounts: [1, 5, 10])
        XCTAssertEqual(trend, .stable, "fewer than 4 data points should return stable")
    }

    func testTrendEmptyArray() {
        let trend = InboxContextBuilder.calculateTrend(dailyCounts: [])
        XCTAssertEqual(trend, .stable)
    }

    func testTrendExactlyFourElements() {
        // [1, 1, 5, 5] → firstHalf=2, secondHalf=10, diff=8, threshold=max(2/3,2)=2
        let trend = InboxContextBuilder.calculateTrend(dailyCounts: [1, 1, 5, 5])
        XCTAssertEqual(trend, .up)
    }

    // MARK: - detectMediaType

    func testMediaTypeImage() {
        XCTAssertEqual(InboxContextBuilder.detectMediaType(baseType: 3), .image)
    }

    func testMediaTypeVoice() {
        XCTAssertEqual(InboxContextBuilder.detectMediaType(baseType: 34), .voice)
    }

    func testMediaTypeVideo() {
        XCTAssertEqual(InboxContextBuilder.detectMediaType(baseType: 43), .video)
    }

    func testMediaTypeSticker() {
        XCTAssertEqual(InboxContextBuilder.detectMediaType(baseType: 47), .sticker)
    }

    func testMediaTypeLocation() {
        XCTAssertEqual(InboxContextBuilder.detectMediaType(baseType: 48), .location)
    }

    func testMediaTypeLink() {
        XCTAssertEqual(InboxContextBuilder.detectMediaType(baseType: 49), .link)
    }

    func testMediaTypeTextReturnsNil() {
        XCTAssertNil(InboxContextBuilder.detectMediaType(baseType: 1), "text baseType should return nil")
    }

    func testMediaTypeSystemReturnsNil() {
        XCTAssertNil(InboxContextBuilder.detectMediaType(baseType: 10000), "system baseType should return nil")
    }

    func testMediaTypeZeroReturnsNil() {
        XCTAssertNil(InboxContextBuilder.detectMediaType(baseType: 0))
    }
}
