import Foundation

/// Real-data adapter from `ChatMonitor` to `MessageQuery`. Used by
/// `RedBannerDetector` to find user's own follow-up messages in a chat
/// since a given todo's createdAt. Plan M6.0.
actor ChatMonitorMessageQuery: MessageQuery {
    private weak var monitor: ChatMonitor?

    init(monitor: ChatMonitor) {
        self.monitor = monitor
    }

    func myMessages(chatUsername: String, since: Date, until: Date) async -> [SimpleMessage] {
        guard let monitor else { return [] }
        let myUname = monitor.myUsername
        let inRange = monitor.messagesInRange(
            chatUsername: chatUsername, start: since, end: until, fetchLimit: 1000
        )
        return inRange
            .filter { $0.senderUsername == myUname }
            .map {
                SimpleMessage(
                    id: $0.id,  // MessageInfo.id is a String UID
                    text: $0.text,
                    timestamp: Date(timeIntervalSince1970: TimeInterval($0.createTime))
                )
            }
    }
}
