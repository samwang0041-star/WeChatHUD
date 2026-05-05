import XCTest
@testable import WeChatHUD

final class ImageUnderstandingServiceTests: XCTestCase {
    func testPromptContextUsesOCRTextAsImageContent() {
        let result = ImageUnderstandingResult(
            filePath: "/tmp/image.png",
            ocrText: "演唱会 7点入场\n带身份证",
            errorMessage: nil
        )

        XCTAssertTrue(result.promptContext.contains("图片识别/OCR文字"))
        XCTAssertTrue(result.promptContext.contains("演唱会 7点入场 带身份证"))
    }

    func testPromptContextFailsClosedWhenImageMissing() {
        let result = ImageUnderstandingResult(
            filePath: nil,
            ocrText: "",
            errorMessage: "未找到本地图片文件"
        )

        XCTAssertTrue(result.promptContext.contains("未找到本地图片文件"))
        XCTAssertTrue(result.promptContext.contains("不能判断图片具体内容"))
    }
}
