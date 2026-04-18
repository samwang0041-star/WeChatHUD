import Foundation

/// Installs a `URLProtocol` that captures every URLSession.shared request and
/// optionally stubs the response body. Used by AIService tests so we can
/// verify request shape without hitting the network.
///
/// NOTE: `AIService` currently uses `URLSession.shared.data(for:)`, which
/// honors globally registered URLProtocol classes. If the service later moves
/// to a custom URLSessionConfiguration, this recorder will need to be wired
/// via `configuration.protocolClasses` instead.
final class URLRequestRecorder: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var capturedRequests: [URLRequest] = []
    nonisolated(unsafe) static var stubbedResponse: (Data, URLResponse)? = nil
    nonisolated(unsafe) static var installed = false

    static func install() {
        capturedRequests = []
        stubbedResponse = nil
        URLProtocol.registerClass(URLRequestRecorder.self)
        installed = true
    }

    static func uninstall() {
        URLProtocol.unregisterClass(URLRequestRecorder.self)
        capturedRequests = []
        stubbedResponse = nil
        installed = false
    }

    static func makeChatCompletionsResponse(content: String) -> (Data, URLResponse) {
        let body = try! JSONSerialization.data(withJSONObject: [
            "choices": [[
                "message": ["role": "assistant", "content": content]
            ]]
        ])
        let resp = HTTPURLResponse(
            url: URL(string: "http://test/chat/completions")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (body, resp)
    }

    override class func canInit(with request: URLRequest) -> Bool { installed }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        URLRequestRecorder.capturedRequests.append(request)
        if let (data, resp) = URLRequestRecorder.stubbedResponse {
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
    }
    override func stopLoading() {}
}
