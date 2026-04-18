import Foundation
import XCTest
@testable import WeChatHUD

/// Shared helpers for Codex-layer tests — fixture builders, URLProtocol
/// mock, and a tiny JWT minter (alg=none, unverified signature).
enum CodexTestSupport {

    // MARK: - JWT

    /// Produce a JWT whose payload decodes to `payload`. Signature is literal
    /// garbage — CodexAuth never verifies it.
    static func makeJWT(payload: [String: Any]) -> String {
        let header: [String: Any] = ["alg": "none", "typ": "JWT"]
        let headerData = try! JSONSerialization.data(withJSONObject: header)
        let payloadData = try! JSONSerialization.data(withJSONObject: payload)
        return "\(headerData.base64URLEncodedString()).\(payloadData.base64URLEncodedString()).fakesig"
    }

    // MARK: - auth.json fixture

    /// Build a RawAuthFile dictionary suitable for writing to a fake
    /// `~/.codex/auth.json`. `expOffset` is seconds relative to now.
    static func makeAuthJSON(
        accountId: String = "act_test",
        email: String = "alice@example.com",
        expOffset: TimeInterval = 3600,
        refreshToken: String = "refresh_v1"
    ) -> [String: Any] {
        let jwt = makeJWT(payload: [
            "exp": Date().timeIntervalSince1970 + expOffset,
            "https://api.openai.com/auth": ["chatgpt_account_id": accountId],
            "https://api.openai.com/profile": ["email": email]
        ])
        return [
            "auth_mode": "chatgpt",
            "tokens": [
                "access_token": jwt,
                "refresh_token": refreshToken,
                "account_id": accountId
            ]
        ]
    }

    /// Write an auth.json into a temp CODEX_HOME and return its path.
    static func writeAuthJSON(_ json: [String: Any]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("auth.json")
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        try data.write(to: file)
        return dir
    }

    // MARK: - URLSession mock

    /// Build a URLSession that routes all requests through `MockURLProtocol`.
    static func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

/// URLProtocol that replays canned responses; shared by Token + Backend tests.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, [Data])

    /// Swap in per-test. Tests should reset to nil in tearDown.
    nonisolated(unsafe) static var handler: Handler?
    /// Record of requests seen — useful to assert retry behavior.
    nonisolated(unsafe) static var capturedRequests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.capturedRequests.append(request)
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, chunks) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks {
                client?.urlProtocol(self, didLoad: chunk)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func reset() {
        handler = nil
        capturedRequests = []
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        return base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
