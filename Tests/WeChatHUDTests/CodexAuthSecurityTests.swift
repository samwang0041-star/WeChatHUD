import XCTest
@testable import WeChatHUD

final class CodexAuthSecurityTests: XCTestCase {
    func testReadProfileRejectsWorldReadableAuthFile() throws {
        let dir = try CodexTestSupport.writeAuthJSON(CodexTestSupport.makeAuthJSON())
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("auth.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertThrowsError(try CodexAuth.readProfile(env: ["CODEX_HOME": dir.path])) { error in
            XCTAssertEqual(error as? CodexError, .insecureAuthFile)
        }
    }

    func testReadProfileRejectsSymlinkAuthFile() throws {
        let dir = try CodexTestSupport.writeAuthJSON(CodexTestSupport.makeAuthJSON())
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("auth.json")
        let linkedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex_link_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: linkedHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: linkedHome) }
        let link = linkedHome.appendingPathComponent("auth.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertThrowsError(try CodexAuth.readProfile(env: ["CODEX_HOME": linkedHome.path])) { error in
            XCTAssertEqual(error as? CodexError, .insecureAuthFile)
        }
    }

    func testReadProfileAcceptsOwnerOnlyAuthFile() throws {
        let dir = try CodexTestSupport.writeAuthJSON(CodexTestSupport.makeAuthJSON())
        defer { try? FileManager.default.removeItem(at: dir) }
        let profile = try CodexAuth.readProfile(env: ["CODEX_HOME": dir.path])
        XCTAssertEqual(profile.accountId, "act_test")
    }
}
