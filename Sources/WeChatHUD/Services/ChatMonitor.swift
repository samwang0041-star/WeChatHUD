import Foundation

/// Polls WeChat databases for new messages on a timer.
/// Publishes stats (unread, @mentions, important) for whitelisted chats.
@MainActor
final class ChatMonitor: ObservableObject {
    @Published var stats = HUDStats()
    @Published var latestNotification: HUDNotification?

    private let reader: WeChatReader
    private let store: HUDStore
    private var timer: Timer?
    private var myUsername: String = ""

    // Importance keywords
    private let urgentKeywords = ["紧急", "尽快", "ASAP", "马上", "立即", "截止", "deadline"]

    init(reader: WeChatReader, store: HUDStore) {
        self.reader = reader
        self.store = store
    }

    func start(interval: TimeInterval = 30) {
        stop()
        // Initial scan
        Task { await scan() }
        // Periodic scan
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { [weak self] in await self?.scan() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Detect the current user's username from contacts or config.
    func detectMyUsername() {
        if let saved = store.getSetting("my_username") {
            myUsername = saved
        }
    }

    private func scan() async {
        stats.syncStatus = .syncing

        do {
            // Re-load keys and contacts each cycle to pick up new WAL writes.
            try reader.loadKeys()
            try reader.loadContacts()

            let whitelist = store.getWhitelist()
            guard !whitelist.isEmpty else {
                stats = HUDStats(syncStatus: .ok, lastSyncAt: Date())
                return
            }

            var totalUnread = 0
            var totalAt = 0
            var totalImportant = 0
            var latestImportant: HUDNotification?

            let msgDBs = reader.findMessageDBs()

            for entry in whitelist {
                for relPath in msgDBs {
                    let sourceKey = "\(relPath)/\(entry.id)"
                    let lastState = store.getSyncState(sourceKey)
                    let sinceId = lastState?.lastLocalId ?? 0

                    do {
                        let messages = try reader.getMessages(
                            chatUsername: entry.id,
                            limit: 100,
                            sinceLocalId: sinceId > 0 ? sinceId : nil
                        )

                        let newMessages = sinceId > 0
                            ? messages.filter { msg in
                                if let lastComponent = msg.id.split(separator: "/").last,
                                   let lid = Int(lastComponent) {
                                    return lid > sinceId
                                }
                                return false
                            }
                            : []

                        totalUnread += newMessages.count

                        for msg in newMessages {
                            let isAt = msg.text.contains("@\(myUsername)") ||
                                       msg.text.contains("@所有人") ||
                                       msg.text.contains("@All")
                            let isImportant = isAt ||
                                urgentKeywords.contains(where: { msg.text.contains($0) })

                            if isAt { totalAt += 1 }
                            if isImportant {
                                totalImportant += 1
                                latestImportant = HUDNotification(
                                    chatName: msg.chatName,
                                    senderName: msg.senderName,
                                    snippet: String(msg.text.prefix(80)),
                                    isAtMention: isAt,
                                    timestamp: Date(timeIntervalSince1970: Double(msg.createTime))
                                )
                            }
                        }

                        // Update sync state with the max local_id we've seen
                        if let maxMsg = messages.first,
                           let lastComp = maxMsg.id.split(separator: "/").last,
                           let maxId = Int(lastComp) {
                            try store.updateSyncState(sourceKey, lastLocalId: maxId)
                        }
                    } catch {
                        // Skip this chat/DB combination silently
                        continue
                    }
                }
            }

            stats = HUDStats(
                unreadCount: totalUnread,
                atMentionCount: totalAt,
                importantCount: totalImportant,
                syncStatus: .ok,
                lastSyncAt: Date()
            )

            if let notif = latestImportant {
                latestNotification = notif
            }

        } catch {
            stats.syncStatus = .error(error.localizedDescription)
        }
    }
}
