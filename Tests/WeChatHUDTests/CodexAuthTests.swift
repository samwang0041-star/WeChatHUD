import XCTest
@testable import WeChatHUD

/// Unit tests for `CodexAuth` — auth.json reading, JWT decoding,
/// and profile extraction. All pure; no network.
final class CodexAuthTests: XCTestCase {

    // MARK: - resolveCodexHome

    func testResolveCodexHomeDefault() {
        let home = CodexAuth.resolveCodexHome(env: [:])
        XCTAssertEqual(home.lastPathComponent, ".codex")
        XCTAssertTrue(home.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path))
    }

    func testResolveCodexHomeExplicit() {
        let home = CodexAuth.resolveCodexHome(env: ["CODEX_HOME": "/opt/foo"])
        XCTAssertEqual(home.path, "/opt/foo")
    }

    func testResolveCodexHomeTildeExpansion() {
        let home = CodexAuth.resolveCodexHome(env: ["CODEX_HOME": "~/foo"])
        XCTAssertEqual(home.lastPathComponent, "foo")
        XCTAssertTrue(home.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path))
    }

    func testResolveCodexHomeBareTilde() {
        let home = CodexAuth.resolveCodexHome(env: ["CODEX_HOME": "~"])
        XCTAssertEqual(home.path, FileManager.default.homeDirectoryForCurrentUser.path)
    }

    // MARK: - JWT decoding

    func testDecodeJWTPayloadExtractsClaims() throws {
        let token = CodexTestSupport.makeJWT(payload: [
            "exp": 1234567890,
            "https://api.openai.com/auth": ["chatgpt_account_id": "act_abc"],
            "https://api.openai.com/profile": ["email": "bob@example.com"]
        ])
        let claims = try CodexAuth.decodeJWTPayload(token)
        XCTAssertEqual(claims["exp"] as? Int, 1234567890)
        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        XCTAssertEqual(auth?["chatgpt_account_id"] as? String, "act_abc")
    }

    func testDecodeJWTRejectsMalformedStructure() {
        XCTAssertThrowsError(try CodexAuth.decodeJWTPayload("not.a.jwt.token"))
        XCTAssertThrowsError(try CodexAuth.decodeJWTPayload("only-one-part"))
        XCTAssertThrowsError(try CodexAuth.decodeJWTPayload("two.parts"))
    }

    func testDecodeJWTRejectsNonJSONPayload() {
        // Valid 3 parts, but middle segment isn't base64 of JSON.
        let malformed = "abc.!!!.xyz"
        XCTAssertThrowsError(try CodexAuth.decodeJWTPayload(malformed)) { error in
            XCTAssertEqual(error as? CodexError, .invalidJWT)
        }
    }

    func testBase64URLDecodeHandlesMissingPadding() {
        // "Hello" — base64url with no padding.
        let decoded = CodexAuth.base64URLDecode("SGVsbG8")
        XCTAssertEqual(decoded.flatMap { String(data: $0, encoding: .utf8) }, "Hello")
    }

    // MARK: - parseProfile (pure)

    func testParseProfileHappyPath() throws {
        let raw = makeRawAuth()
        let profile = try CodexAuth.parseProfile(raw: raw)
        XCTAssertEqual(profile.accountId, "act_test")
        XCTAssertEqual(profile.email, "alice@example.com")
        XCTAssertFalse(profile.accessToken.isEmpty)
        XCTAssertFalse(profile.refreshToken.isEmpty)
        XCTAssertGreaterThan(profile.accessExpiresAt, Date())
    }

    func testParseProfileRejectsNonChatGPTMode() {
        let raw = RawAuthFile(authMode: "apikey", tokens: nil)
        XCTAssertThrowsError(try CodexAuth.parseProfile(raw: raw)) { error in
            XCTAssertEqual(error as? CodexError, .notChatGPTMode)
        }
    }

    func testParseProfileRejectsMissingTokens() {
        let raw = RawAuthFile(authMode: "chatgpt", tokens: nil)
        XCTAssertThrowsError(try CodexAuth.parseProfile(raw: raw)) { error in
            XCTAssertEqual(error as? CodexError, .missingTokens)
        }
    }

    func testParseProfileRejectsEmptyAccessToken() {
        let raw = RawAuthFile(
            authMode: "chatgpt",
            tokens: .init(accessToken: "  ", refreshToken: "r", accountId: nil)
        )
        XCTAssertThrowsError(try CodexAuth.parseProfile(raw: raw)) { error in
            XCTAssertEqual(error as? CodexError, .missingTokens)
        }
    }

    func testParseProfileRejectsMalformedJWT() {
        let raw = RawAuthFile(
            authMode: "chatgpt",
            tokens: .init(
                accessToken: "not-a-real-jwt",
                refreshToken: "refresh",
                accountId: "act_x"
            )
        )
        XCTAssertThrowsError(try CodexAuth.parseProfile(raw: raw)) { error in
            XCTAssertEqual(error as? CodexError, .invalidJWT)
        }
    }

    func testParseProfilePrefersJWTAccountOverFileAccount() throws {
        let jwt = CodexTestSupport.makeJWT(payload: [
            "exp": Date().timeIntervalSince1970 + 3600,
            "https://api.openai.com/auth": ["chatgpt_account_id": "act_from_jwt"]
        ])
        let raw = RawAuthFile(
            authMode: "chatgpt",
            tokens: .init(
                accessToken: jwt,
                refreshToken: "r",
                accountId: "act_from_file"
            )
        )
        let profile = try CodexAuth.parseProfile(raw: raw)
        XCTAssertEqual(profile.accountId, "act_from_jwt")
    }

    func testParseProfileFallsBackToFileAccountId() throws {
        let jwt = CodexTestSupport.makeJWT(payload: [
            "exp": Date().timeIntervalSince1970 + 3600
        ])
        let raw = RawAuthFile(
            authMode: "chatgpt",
            tokens: .init(
                accessToken: jwt,
                refreshToken: "r",
                accountId: "act_from_file"
            )
        )
        let profile = try CodexAuth.parseProfile(raw: raw)
        XCTAssertEqual(profile.accountId, "act_from_file")
    }

    func testParseProfileThrowsWhenAccountIdAbsentEverywhere() {
        let jwt = CodexTestSupport.makeJWT(payload: [
            "exp": Date().timeIntervalSince1970 + 3600
        ])
        let raw = RawAuthFile(
            authMode: "chatgpt",
            tokens: .init(accessToken: jwt, refreshToken: "r", accountId: nil)
        )
        XCTAssertThrowsError(try CodexAuth.parseProfile(raw: raw)) { error in
            XCTAssertEqual(error as? CodexError, .missingAccountId)
        }
    }

    // MARK: - readProfile (filesystem round-trip)

    func testReadProfileHappyPath() throws {
        let dir = try CodexTestSupport.writeAuthJSON(CodexTestSupport.makeAuthJSON())
        defer { try? FileManager.default.removeItem(at: dir) }

        let profile = try CodexAuth.readProfile(env: ["CODEX_HOME": dir.path])
        XCTAssertEqual(profile.accountId, "act_test")
        XCTAssertEqual(profile.email, "alice@example.com")
    }

    func testReadProfileThrowsNotLoggedInWhenFileMissing() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex_empty_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertThrowsError(try CodexAuth.readProfile(env: ["CODEX_HOME": dir.path])) { error in
            XCTAssertEqual(error as? CodexError, .notLoggedIn)
        }
    }

    // MARK: - Helpers

    private func makeRawAuth() -> RawAuthFile {
        let jwt = CodexTestSupport.makeJWT(payload: [
            "exp": Date().timeIntervalSince1970 + 3600,
            "https://api.openai.com/auth": ["chatgpt_account_id": "act_test"],
            "https://api.openai.com/profile": ["email": "alice@example.com"]
        ])
        return RawAuthFile(
            authMode: "chatgpt",
            tokens: .init(accessToken: jwt, refreshToken: "refresh_v1", accountId: "act_test")
        )
    }
}
