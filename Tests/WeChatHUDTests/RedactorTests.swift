import Testing
import Foundation
@testable import WeChatHUD

@Suite("Redactor")
struct RedactorTests {

    @Test("Same username → same codename within run")
    func stableCodename() async {
        let r = Redactor()
        let c1 = await r.codenameFor(username: "wxid_abc", displayName: "张总")
        let c2 = await r.codenameFor(username: "wxid_abc", displayName: "张总")
        #expect(c1 == c2)
    }

    @Test("Different usernames yield different codenames even when displayName matches")
    func differentUsernamesSameName() async {
        let r = Redactor()
        let c1 = await r.codenameFor(username: "wxid_a", displayName: "张总")
        let c2 = await r.codenameFor(username: "wxid_b", displayName: "张总")
        #expect(c1 != c2)
    }

    @Test("Codenames generated as A1, A2, A3 in order of first sight")
    func sequentialCodenames() async {
        let r = Redactor()
        let c1 = await r.codenameFor(username: "wxid_1", displayName: "")
        let c2 = await r.codenameFor(username: "wxid_2", displayName: "")
        let c3 = await r.codenameFor(username: "wxid_3", displayName: "")
        #expect(c1 == "A1")
        #expect(c2 == "A2")
        #expect(c3 == "A3")
    }

    @Test("Phone, email, money patterns masked")
    func maskPatterns() async {
        let r = Redactor()
        let input = "联系我 13800138000 或 foo@bar.com，预算 ¥50000"
        let out = await r.redactText(input)
        #expect(out.contains("[手机]"))
        #expect(out.contains("[邮箱]"))
        #expect(out.contains("[金额]"))
        #expect(!out.contains("13800138000"))
        #expect(!out.contains("foo@bar.com"))
    }

    @Test("Money in 万 / K / $ notation all masked")
    func moneyVariants() {
        #expect(Redactor.applyMasks("预算 50万").contains("[金额]"))
        #expect(Redactor.applyMasks("预算 100K").contains("[金额]"))
        #expect(Redactor.applyMasks("$5000").contains("[金额]"))
    }

    @Test("originalForCodename returns the registered displayName")
    func reverseLookup() async {
        let r = Redactor()
        let code = await r.codenameFor(username: "wxid_z", displayName: "李四")
        let name = await r.originalForCodename(code)
        #expect(name == "李四")
    }

    @Test("unredactText reverses codenames in AI output")
    func aiOutputRoundtrip() async {
        let r = Redactor()
        _ = await r.codenameFor(username: "wxid_w", displayName: "王总")
        let unredacted = await r.unredactText("A1 决定上线")
        #expect(unredacted == "王总 决定上线")
    }

    @Test("redactText replaces displayName with codename")
    func redactReplacesDisplayName() async {
        let r = Redactor()
        _ = await r.codenameFor(username: "wxid_q", displayName: "张总")
        let redacted = await r.redactText("张总同意了")
        #expect(redacted == "A1同意了")
    }

    @Test("Longest displayName replaced first to avoid partial collisions")
    func longestFirstReplacement() async {
        let r = Redactor()
        // "李" and "李四" — replacing "李" first would mangle "李四" → "A1四"
        _ = await r.codenameFor(username: "wxid_li", displayName: "李")
        _ = await r.codenameFor(username: "wxid_lisi", displayName: "李四")
        let redacted = await r.redactText("李四 找 李")
        // Both should be substituted as wholes.
        #expect(redacted.contains("A2"))
        #expect(redacted.contains("A1"))
        #expect(!redacted.contains("李"))
    }
}
