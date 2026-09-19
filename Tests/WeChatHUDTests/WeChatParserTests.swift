import XCTest
@testable import WeChatHUD

final class WeChatParserTests: XCTestCase {

    func testLegacyShortUsernameExtractsWeChatAccountSuffix() {
        XCTAssertEqual(WeChatReader.legacyShortUsername(for: "lilei_06a2"), "lilei")
        XCTAssertEqual(WeChatReader.legacyShortUsername(for: "wxid_abc_ffff"), "wxid_abc")
        XCTAssertNil(WeChatReader.legacyShortUsername(for: "lilei"))
        XCTAssertNil(WeChatReader.legacyShortUsername(for: "lilei_long"))
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

    /// Real quote-reply XML nests `refermsg` under `msg.appmsg` — the old
    /// root-level "refermsg.content" lookup never matched, so the quoted
    /// original (and its sender) silently dropped.
    func testQuoteReplyExtractsNestedRefermsg() {
        let xml = """
        <msg><appmsg><title>好的，就这么定</title><type>57</type><refermsg><type>1</type><fromusr>wxid_peer</fromusr><displayname>张三</displayname><content>周五前把方案发我</content></refermsg></appmsg></msg>
        """
        let result = WeChatParser.parseAppMsg(xml)
        XCTAssertEqual(result.appType, 57, "appmsg.type must win over refermsg.type")
        XCTAssertEqual(result.quotedText, "周五前把方案发我")
        XCTAssertEqual(result.quotedSender, "张三")
        XCTAssertTrue(result.text.contains("好的，就这么定"))
        XCTAssertTrue(result.text.contains("回复 张三: 周五前把方案发我"),
                      "the quoted original must render into the text")
    }

    /// `refermsg` carries its own <type> (the quoted message's base type).
    /// A leaf-name lookup could hand that back as the app type, so a link
    /// quoting a text message could misclassify as type 1.
    func testRefermsgTypeDoesNotShadowAppmsgType() {
        let xml = """
        <msg><appmsg><title>分享标题</title><type>5</type><refermsg><type>1</type><content>引用内容</content></refermsg></appmsg></msg>
        """
        let result = WeChatParser.parseAppMsg(xml)
        XCTAssertEqual(result.appType, 5)
        XCTAssertEqual(result.text, "[链接] 分享标题")
    }

    /// Typed appmsg prefixes mirror the reference renderer: a shared file or
    /// mini-program must not read as a bare title in previews and AI context.
    func testAppmsgTypedPrefixes() {
        let file = """
        <msg><appmsg><title>报告.pdf</title><type>6</type></appmsg></msg>
        """
        XCTAssertEqual(WeChatParser.parseAppMsg(file).text, "[文件] 报告.pdf")

        let mini = """
        <msg><appmsg><title>点餐小程序</title><type>33</type></appmsg></msg>
        """
        XCTAssertEqual(WeChatParser.parseAppMsg(mini).text, "[小程序] 点餐小程序")
    }

    /// WeChat wraps human-readable payloads in CDATA — without a foundCDATA
    /// delegate the element stored an empty string and link descriptions
    /// silently vanished.
    func testCDATAContentIsCaptured() {
        let xml = """
        <msg><appmsg><title>链接标题</title><type>5</type><des><![CDATA[描述里 <b>有标记</b>]]></des><url>https://example.com</url></appmsg></msg>
        """
        let result = WeChatParser.parseAppMsg(xml)
        XCTAssertEqual(result.description, "描述里 <b>有标记</b>")
    }

    /// Text on both sides of a child element used to lose the leading half:
    /// `abc<br/>def` stored only "def".
    func testMixedContentKeepsTextAroundChildElements() {
        let xml = "<msg><appmsg><title>前半<br/>后半</title><type>5</type></appmsg></msg>"
        XCTAssertEqual(WeChatParser.parseAppMsg(xml).title, "前半后半")
    }

    /// The entity guard was case-sensitive — `<!doctype`/`<!entity` in lower
    /// case still expands internal entities in XMLParser and slipped through.
    func testRejectsLowercaseDoctypeAndEntity() {
        let xml = "<!doctype foo [<!entity xxe SYSTEM \"file:///etc/passwd\">]><msg>&xxe;</msg>"
        XCTAssertTrue(WeChatParser.parseAppMsg(xml).title.isEmpty)
    }

    /// …and the whole guard only covered `parseAppMsg`. A baseType-10000 row
    /// reached `SimpleXMLParser` through `parseSysMsg` with no check at all, so
    /// the amplification primitive was still reachable on one of the two
    /// message surfaces. The document here is deliberately tiny: if the guard
    /// regresses, the assertion has to fail on expanded text rather than the
    /// runner dying on a real bomb.
    func testSysmsgEntityDocumentIsNotExpanded() {
        let bomb = """
        <?xml version="1.0"?><!DOCTYPE sysmsg [<!ENTITY a "AAAA"> \
        <!ENTITY b "&a;&a;&a;&a;"><!ENTITY c "&b;&b;&b;&b;"> \
        <!ENTITY d "&c;&c;&c;&c;">]><sysmsg><content>&d;</content></sysmsg>
        """
        let result = WeChatParser.renderMessage(content: bomb, baseType: 10000, isGroup: false)
        XCTAssertEqual(result.text, "[系统消息]", "内部实体被展开了：这道闸只管 appmsg 时这里是通的")
        XCTAssertFalse(result.text.contains("AAAA"))
    }

    func testSysmsgOversizedDocumentIsNotParsed() {
        let xml = "<sysmsg><content>" + String(repeating: "很长", count: 600_000) + "</content></sysmsg>"
        let result = WeChatParser.renderMessage(content: xml, baseType: 10000, isGroup: false)
        XCTAssertEqual(result.text, "[系统消息]")
    }

    /// The size check has to sit ahead of the `type=` regex, not just ahead of
    /// the DOM pass — `parse()` refusing is not enough when the work already
    /// spent a copy and a scan over the blob. `sysKind` is only ever set by
    /// that regex, so an empty one is the observable proof of the ordering.
    func testSysmsgOversizedDocumentIsRejectedBeforeTheRegexPass() {
        let xml = "<sysmsg type=\"revokemsg\"><revokemsg><replacemsg>"
            + String(repeating: "很", count: 1_000_000)
            + "</replacemsg></revokemsg></sysmsg>"
        let result = WeChatParser.renderMessage(content: xml, baseType: 10000, isGroup: false)
        XCTAssertTrue(result.sysKind.isEmpty, "sysKind 有值就说明正则已经跑过这个大文本")
        XCTAssertEqual(result.text, "[系统消息]")
    }

    /// A healthy system notice still parses — otherwise the two assertions
    /// above are just proving that nothing parses.
    func testSysmsgStillParsesAfterTheGuards() {
        let xml = "<sysmsg type=\"normal\"><content><![CDATA[你已添加了对方]]></content></sysmsg>"
        let result = WeChatParser.renderMessage(content: xml, baseType: 10000, isGroup: false)
        XCTAssertTrue(result.text.contains("你已添加了对方"))
    }

    /// The checks live on the parser, not only at the call sites, so a third
    /// caller cannot forget them. This drives `SimpleXMLParser` directly, which
    /// is the only way to tell the inner guard apart from the outer ones.
    func testSimpleXMLParserRefusesDangerousInputOnItsOwn() {
        let dangerous = Data("""
        <!DOCTYPE r [<!ENTITY a "XXXX"><!ENTITY b "&a;&a;">]><r><title>&b;</title></r>
        """.utf8)
        let parser = SimpleXMLParser(data: dangerous)
        parser.parse()
        XCTAssertNil(parser.value(for: "title"), "parse() 自己要是不拦，调用方忘了就是漏点")

        let bigDocument = "<r><title>" + String(repeating: "x", count: 1_000_001) + "</title></r>"
        let oversized = Data(bigDocument.utf8)
        let bigParser = SimpleXMLParser(data: oversized)
        bigParser.parse()
        XCTAssertNil(bigParser.value(for: "title"))

        let healthy = Data("<r><title>ok</title></r>".utf8)
        let okParser = SimpleXMLParser(data: healthy)
        okParser.parse()
        XCTAssertEqual(okParser.value(for: "title"), "ok")
    }

    /// baseType-10000 rows carry `<sysmsg>` XML — rendering the raw blob
    /// leaked markup into previews and AI context, and revokemsg rows fed
    /// nothing to the recall pipeline.
    func testSysmsgRevokeExtractsReplacemsgAndKind() {
        let xml = """
        <sysmsg type="revokemsg"><revokemsg><session>peer_x</session><msgid>42</msgid><replacemsg><![CDATA["张三" 撤回了一条消息]]></replacemsg></revokemsg></sysmsg>
        """
        let result = WeChatParser.renderMessage(content: xml, baseType: 10000, isGroup: false)
        XCTAssertEqual(result.sysKind, "revokemsg")
        XCTAssertTrue(result.text.contains("撤回了一条消息"))
        XCTAssertTrue(result.text.contains("张三"))
    }

    func testSysmsgGenericExtractsContent() {
        let xml = "<sysmsg type=\"sysmsgtemplate\"><sysmsgtemplate><content>你已添加了李四，现在可以开始聊天</content></sysmsgtemplate></sysmsg>"
        let result = WeChatParser.renderMessage(content: xml, baseType: 10000, isGroup: false)
        XCTAssertEqual(result.sysKind, "sysmsgtemplate")
        XCTAssertEqual(result.text, "你已添加了李四，现在可以开始聊天")
    }

    /// Plain-text system notices (no <sysmsg> wrapper) render as text, and
    /// neither path leaks raw markup into the transcript.
    func testSysmsgNonXMLFallsBackToText() {
        let plain = WeChatParser.renderMessage(content: "消息已发出，但被对方拒收了", baseType: 10000, isGroup: false)
        XCTAssertEqual(plain.text, "消息已发出，但被对方拒收了")
    }
}
