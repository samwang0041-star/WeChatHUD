import XCTest
@testable import WeChatHUD

final class WeChatParserTests: XCTestCase {

    func testLegacyShortUsernameExtractsWeChatAccountSuffix() {
        XCTAssertEqual(WeChatReader.legacyShortUsername(for: "yuriwong_06a2"), "yuriwong")
        XCTAssertEqual(WeChatReader.legacyShortUsername(for: "wxid_abc_ffff"), "wxid_abc")
        XCTAssertNil(WeChatReader.legacyShortUsername(for: "yuriwong"))
        XCTAssertNil(WeChatReader.legacyShortUsername(for: "yuriwong_long"))
    }

    func testDecodeContentPlainText() {
        let data = "Hello World".data(using: .utf8)
        let result = WeChatParser.decodeContent(data, ct: 0)
        XCTAssertEqual(result, "Hello World")
    }

    func testDecodeContentNil() {
        XCTAssertEqual(WeChatParser.decodeContent(nil, ct: 0), "")
    }

    func testExtractGroupSender() {
        let (sender, content) = WeChatParser.extractGroupSender("wxid_abc:\nHello", isGroup: true)
        XCTAssertEqual(sender, "wxid_abc")
        XCTAssertEqual(content, "Hello")
    }

    func testExtractGroupSenderNotGroup() {
        let (sender, content) = WeChatParser.extractGroupSender("wxid_abc:\nHello", isGroup: false)
        XCTAssertNil(sender)
        XCTAssertEqual(content, "wxid_abc:\nHello")
    }

    func testParseAppMsgXML() {
        let xml = """
        <msg><appmsg><title>Test Title</title><des>Test Description</des><url>https://example.com</url><type>5</type></appmsg></msg>
        """
        let result = WeChatParser.parseAppMsg(xml)
        XCTAssertEqual(result.title, "Test Title")
        XCTAssertEqual(result.description, "Test Description")
        XCTAssertEqual(result.url, "https://example.com")
        XCTAssertEqual(result.appType, 5)
    }

    func testRenderMessageText() {
        let msg = WeChatParser.renderMessage(content: "Hello", baseType: 1, isGroup: false)
        XCTAssertEqual(msg.text, "Hello")
    }

    func testRenderMessageMedia() {
        XCTAssertEqual(WeChatParser.renderMessage(content: "", baseType: 3, isGroup: false).text, "[图片]")
        XCTAssertEqual(WeChatParser.renderMessage(content: "", baseType: 34, isGroup: false).text, "[语音]")
        XCTAssertEqual(WeChatParser.renderMessage(content: "", baseType: 43, isGroup: false).text, "[视频]")
    }

    func testRejectDangerousXML() {
        let xml = "<!DOCTYPE foo [<!ENTITY xxe SYSTEM \"file:///etc/passwd\">]><msg>&xxe;</msg>"
        let result = WeChatParser.parseAppMsg(xml)
        XCTAssertTrue(result.title.isEmpty)  // should not parse
    }
}
