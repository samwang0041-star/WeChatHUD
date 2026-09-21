import XCTest
@testable import WeChatHUD

final class ImageUnderstandingServiceTests: XCTestCase {
   func testPromptContextUsesOCRTextAsImageContent() {
       let result = ImageUnderstandingResult(
           filePath: "/tmp/image.png",
           ocrText: "演唱会 7点入场\n带身份证",
           errorMessage: nil
       )

        XCTAssertTrue(result.promptContext.contains("图片里出现的文字"))
        XCTAssertFalse(result.promptContext.contains("OCR"))
        XCTAssertTrue(result.promptContext.contains("演唱会 7点入场 带身份证"))
    }

    func testPromptContextFailsClosedWhenImageMissing() {
        let result = ImageUnderstandingResult(
            filePath: nil,
            ocrText: "",
            errorMessage: nil
        )

        XCTAssertTrue(result.promptContext.contains("本机没有这份图"))
        XCTAssertFalse(result.promptContext.contains("OCR"))
        XCTAssertFalse(result.promptContext.contains("dat"))
    }

    func testUnreadableImageDoesNotNameTheCacheOrOCR() {
        let result = ImageUnderstandingResult(
            filePath: "/tmp/foo.dat",
            ocrText: "",
            errorMessage: "encrypted"
        )
        XCTAssertTrue(result.promptContext.contains("读不出图上的字"))
        XCTAssertFalse(result.promptContext.contains("OCR"))
        XCTAssertFalse(result.promptContext.contains("加密"))
        XCTAssertFalse(result.promptContext.contains("dat"))
    }
}
