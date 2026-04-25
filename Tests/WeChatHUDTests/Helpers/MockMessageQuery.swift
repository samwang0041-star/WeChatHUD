import Foundation
@testable import WeChatHUD

actor MockMessageQuery: MessageQuery {
    private var stored: [String: [SimpleMessage]] = [:]

    nonisolated init() {}

    func setMessages(_ msgs: [SimpleMessage], for chatUsername: String) {
        stored[chatUsername] = msgs
    }

    func myMessages(chatUsername: String, since: Date, until: Date) async -> [SimpleMessage] {
        return (stored[chatUsername] ?? []).filter { $0.timestamp >= since && $0.timestamp <= until }
    }
}
