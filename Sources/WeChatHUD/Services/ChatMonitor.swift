import Foundation
import AppKit
import SQLite3

/// Millisecond-precision timestamp for log tracing.
private func ts() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

/// Event-driven WeChat message monitor.
///
/// Primary trigger: FSEventsWatcher feeds paths into `onFSEvent` whenever
/// a `.db` or `.db-wal` file under WeChat's `db_storage` changes.
/// Secondary trigger: a 60s safety timer that runs `refreshIfChanged` on
/// every tracked DB. If nothing has moved, the safety scan is a handful of
/// `stat` calls and returns in microseconds.
///
/// Gating: the whole monitor is paused while WeChat isn't running. Launch
/// and terminate events from NSWorkspace flip the gate instantly, so the
/// status dot turns red the moment WeChat quits.
@MainActor
final class ChatMonitor: ObservableObject {
    @Published var stats = HUDStats()
    @Published var latestNotification: HUDNotification?

    private let reader: WeChatReader
    private let store: HUDStore
    private var safetyTimer: Timer?
    private var myUsername: String = ""
    private var scanInProgress = false

    nonisolated(unsafe) private static let wechatBundleIDs: Set<String> = [
        "com.tencent.xinWeChat",
        "com.tencent.WeChat"
    ]

    private var launchObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?

    private let urgentKeywords = ["紧急", "尽快", "ASAP", "马上", "立即", "截止", "deadline"]

    init(reader: WeChatReader, store: HUDStore) {
        self.reader = reader
        self.store = store
    }

    deinit {
        if let obs = launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
        if let obs = terminateObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
    }

    // MARK: - Lifecycle

    func start() {
        print("[WCHUD] monitor.start()")
        stop()
        registerWeChatObservers()
        print("[WCHUD] wechat running at startup? \(isWeChatRunning())")

        // Initial scan — either red (no WeChat) or green (scanned clean).
        Task { @MainActor in
            print("[WCHUD] initial scan Task starting")
            await self.scan()
        }

        // Safety fallback: cheap mtime-only check every 60s.
        // If FSEvents delivers in time, this is a no-op.
        safetyTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { [weak self] in await self?.scan() }
        }
    }

    func stop() {
        safetyTimer?.invalidate()
        safetyTimer = nil
    }

    func detectMyUsername() {
        if let saved = store.getSetting("my_username") {
            myUsername = saved
        }
    }

    // MARK: - Event entry points

    /// Called by FSEventsWatcher when files in db_storage change.
    /// Extracts which specific DBs changed and scans only those.
    func onFSEvent(paths: [String]) {
        var changedRelPaths: Set<String> = []
        for path in paths {
            guard let rel = extractRelPath(from: path) else { continue }
            guard rel.contains("/message_") || rel.contains("/contact.db") else { continue }
            changedRelPaths.insert(rel)
        }
        guard !changedRelPaths.isEmpty else { return }

        let eventTime = Date()
        print("[\(ts())] FSEvent: \(changedRelPaths.sorted().joined(separator: ", "))")
        Task { @MainActor in
            await self.scan(changedRelPaths: changedRelPaths)
            let latencyMs = Int(Date().timeIntervalSince(eventTime) * 1000)
            print("[\(ts())] FSEvent → scan complete (+\(latencyMs)ms)")
        }
    }

    /// Map an absolute path (e.g. `/.../db_storage/message/message_1.db-wal`)
    /// to the repo-relative form used as the key in `keys` and `sync_state`
    /// (e.g. `message/message_1.db`). Returns nil for paths outside db_storage.
    private func extractRelPath(from absPath: String) -> String? {
        let dbDir = reader.dbDir
        guard !dbDir.isEmpty, absPath.hasPrefix(dbDir) else { return nil }
        var rel = String(absPath.dropFirst(dbDir.count))
        if rel.hasPrefix("/") { rel.removeFirst() }
        // Strip WAL / SHM / journal suffixes to get the main DB path.
        if rel.hasSuffix("-wal") { rel = String(rel.dropLast(4)) }
        else if rel.hasSuffix("-shm") { rel = String(rel.dropLast(4)) }
        else if rel.hasSuffix("-journal") { rel = String(rel.dropLast(8)) }
        return rel.isEmpty ? nil : rel
    }

    // MARK: - WeChat process detection

    private func isWeChatRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            guard let bid = app.bundleIdentifier else { return false }
            return Self.wechatBundleIDs.contains(bid)
        }
    }

    private func registerWeChatObservers() {
        let center = NSWorkspace.shared.notificationCenter
        launchObserver = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            guard let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bid = app.bundleIdentifier,
                  Self.wechatBundleIDs.contains(bid) else { return }
            Task { @MainActor [weak self] in await self?.scan() }
        }
        terminateObserver = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            guard let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bid = app.bundleIdentifier,
                  Self.wechatBundleIDs.contains(bid) else { return }
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.stats = HUDStats(
                    unreadCount: 0,
                    atMentionCount: 0,
                    importantCount: 0,
                    syncStatus: .waitingForWeChat,
                    lastSyncAt: self.stats.lastSyncAt
                )
            }
        }
    }

    // MARK: - Scan

    /// - Parameter changedRelPaths: If non-nil, only DBs matching these
    ///   relative paths are refreshed and scanned. The 60s safety timer
    ///   passes nil to do a full sweep.
    private func scan(changedRelPaths: Set<String>? = nil) async {
        guard !scanInProgress else {
            print("[WCHUD] scan skipped — already in progress")
            return
        }
        scanInProgress = true
        defer { scanInProgress = false }

        // Gate: WeChat must be running.
        guard isWeChatRunning() else {
            print("[WCHUD] scan gated — WeChat not running")
            stats = HUDStats(
                unreadCount: 0,
                atMentionCount: 0,
                importantCount: 0,
                syncStatus: .waitingForWeChat,
                lastSyncAt: stats.lastSyncAt
            )
            return
        }

        let scanStart = Date()
        stats.syncStatus = .syncing

        do {
            try reader.loadKeys()                  // mtime-gated, cheap when unchanged
            try reader.refreshContactsIfChanged()  // mtime-gated, cheap when unchanged

            let whitelist = store.getWhitelist()

            // DEBUG MODE: empty whitelist → scan every chat table to surface
            // totals. Lets you measure end-to-end latency without setting up
            // whitelist entries first.
            if whitelist.isEmpty {
                let (unread, scanned) = try debugScanAllTables(changedRelPaths: changedRelPaths)
                let ms = Int(Date().timeIntervalSince(scanStart) * 1000)
                let newTotal = stats.unreadCount + unread
                print("[\(ts())] scan (debug): \(scanned) tables, +\(unread) msgs, total=\(newTotal), \(ms)ms")
                stats = HUDStats(
                    unreadCount: newTotal,
                    atMentionCount: stats.atMentionCount,
                    importantCount: stats.importantCount,
                    syncStatus: .ok,
                    lastSyncAt: Date()
                )
                reader.purgeEphemeralCache()
                return
            }

            var totalUnread = 0
            var totalAt = 0
            var totalImportant = 0
            var latestImportant: HUDNotification?

            let msgDBs = reader.findMessageDBs()

            // Pre-refresh all message DBs once; refreshIfChanged is cheap when
            // nothing changed (just a stat() per file).
            for relPath in msgDBs {
                _ = try? reader.refreshIfChanged(relPath: relPath)
            }

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

                        if let maxMsg = messages.first,
                           let lastComp = maxMsg.id.split(separator: "/").last,
                           let maxId = Int(lastComp) {
                            try store.updateSyncState(sourceKey, lastLocalId: maxId)
                        }
                    } catch {
                        continue
                    }
                }
            }

            let ms = Int(Date().timeIntervalSince(scanStart) * 1000)
            print("[WCHUD] scan (whitelist): unread=\(totalUnread) at=\(totalAt) important=\(totalImportant), \(ms)ms")

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

            // Memory strategy: wipe decrypted files after we're done reading.
            reader.purgeEphemeralCache()

        } catch {
            print("[WCHUD] scan ERROR: \(error)")
            stats.syncStatus = .error(error.localizedDescription)
        }
    }

    // MARK: - Debug whole-DB scan

    /// Iterate Msg_* tables in the target message DBs, count new rows since
    /// last known local_id. First sighting of a table establishes a baseline
    /// (doesn't count the historical backlog as "new").
    ///
    /// Hot-path optimization: WeChat's Msg_* tables all use
    /// `local_id INTEGER PRIMARY KEY AUTOINCREMENT`, so SQLite maintains a
    /// current sequence value per table in `sqlite_sequence`. A single
    /// `SELECT name, seq FROM sqlite_sequence` per DB gives us every
    /// table's max_id — no need for ~100 per-table COUNT/MAX queries. With
    /// AUTOINCREMENT the "new messages since last scan" count is exactly
    /// `new_max - last_seen_max` (there are no deletions on the hot path).
    private func debugScanAllTables(changedRelPaths: Set<String>? = nil) throws -> (unread: Int, scanned: Int) {
        let allMsgDBs = reader.findMessageDBs()
        let targetDBs: [String]
        if let changed = changedRelPaths {
            targetDBs = allMsgDBs.filter { changed.contains($0) }
        } else {
            targetDBs = allMsgDBs
        }
        for relPath in targetDBs {
            _ = try? reader.refreshIfChanged(relPath: relPath)
        }
        guard !targetDBs.isEmpty else { return (0, 0) }

        var totalNew = 0
        var totalScanned = 0

        for relPath in targetDBs {
            let decPath: String
            do {
                decPath = try reader.getDecryptedDB(relativePath: relPath)
            } catch {
                continue
            }
            var db: OpaquePointer?
            guard WeChatReader.openReadonly(path: decPath, db: &db) else { continue }
            defer { sqlite3_close(db) }

            var stmt: OpaquePointer?
            let sql = "SELECT name, seq FROM sqlite_sequence WHERE name LIKE 'Msg_%'"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }

            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let namePtr = sqlite3_column_text(stmt, 0) else { continue }
                let tableName = String(cString: namePtr)
                let maxId = Int(sqlite3_column_int64(stmt, 1))
                totalScanned += 1

                let sourceKey = "debug/\(relPath)/\(tableName)"
                let lastState = store.getSyncState(sourceKey)
                let sinceId = lastState?.lastLocalId ?? 0

                if sinceId == 0 {
                    if maxId > 0 {
                        try? store.updateSyncState(sourceKey, lastLocalId: maxId)
                    }
                } else if maxId > sinceId {
                    totalNew += (maxId - sinceId)
                    try? store.updateSyncState(sourceKey, lastLocalId: maxId)
                }
            }
            sqlite3_finalize(stmt)
        }
        return (totalNew, totalScanned)
    }
}
