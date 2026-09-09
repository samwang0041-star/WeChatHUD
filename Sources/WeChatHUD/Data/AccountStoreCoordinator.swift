import Foundation

/// Device preferences have their own persistence. Account data never enters this file.
final class DeviceSettingsStore {
    static let sharedKeys: Set<String> = ["ai", "sync", "notification", "ai_connection_evidence", "update"]
    private struct Document: Codable {
        var settings: [String: String] = [:]
        var legacyBindingRecorded = false
        var legacyAccountIdentity: String?
    }
    private let path: URL
    private var document: Document
    private let lock = NSRecursiveLock()

    init(path: URL) throws {
        self.path = path
        if FileManager.default.fileExists(atPath: path.path) {
            document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: path))
        } else {
            document = Document()
        }
    }

    func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return document.settings[key]
    }

    func set(_ key: String, value: String) throws {
        lock.lock(); defer { lock.unlock() }
        var updated = document
        updated.settings[key] = value
        try persist(updated)
    }

    var legacyAccountIdentity: String? {
        lock.lock(); defer { lock.unlock() }
        return document.legacyAccountIdentity
    }

    enum LegacyStoreStatus {
        case absent, bound, needsAccountConfirmation
    }

    /// Reports file presence and binding metadata only, without querying chat content.
    var legacyStoreStatus: LegacyStoreStatus {
        guard FileManager.default.fileExists(atPath: legacyStoreURL.path) else { return .absent }
        return legacyAccountIdentity == nil ? .needsAccountConfirmation : .bound
    }

    var legacyStoreURL: URL {
        path.deletingLastPathComponent().appendingPathComponent("hud.sqlite3")
    }

    /// One-time binding cannot be reassigned when a later account is selected.
    func initializeIfNeeded(legacySettings: [String: String], legacyAccountRoot: String?) throws {
        lock.lock(); defer { lock.unlock() }
        guard !document.legacyBindingRecorded else { return }
        var updated = document
        updated.settings = legacySettings.filter { Self.sharedKeys.contains($0.key) }
        updated.legacyBindingRecorded = true
        updated.legacyAccountIdentity = legacyAccountRoot.map(WeChatReader.accountCacheIdentity)
        try persist(updated)
    }

    /// The only supported repair path for an unbound legacy store. It requires
    /// explicit human confirmation of the exact current account directory and
    /// takes effect on restart; selection discovery is never used as proof.
    func confirmLegacyAccountIdentity(expectedRoot: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard document.legacyBindingRecorded else {
            throw HUDStoreError.openFailed("Legacy store binding is not initialized")
        }
        guard document.legacyAccountIdentity == nil else {
            throw HUDStoreError.openFailed("Legacy store identity is already bound")
        }
        let canonical = URL(fileURLWithPath: expectedRoot).standardizedFileURL.resolvingSymlinksInPath().path
        guard !canonical.isEmpty else {
            throw HUDStoreError.openFailed("Legacy store requires a selected account directory")
        }
        var updated = document
        updated.legacyAccountIdentity = WeChatReader.accountCacheIdentity(canonical)
        try persist(updated)
    }

    private func persist(_ updated: Document) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        // The staging file is private before content is written; rename preserves mode.
        let stage = path.appendingPathExtension(UUID().uuidString)
        defer { try? fm.removeItem(at: stage) }
        guard fm.createFile(atPath: stage.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw HUDStoreError.openFailed("Cannot create device preferences")
        }
        let handle = try FileHandle(forWritingTo: stage)
        do {
            try handle.write(contentsOf: JSONEncoder().encode(updated))
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        guard rename(stage.path, path.path) == 0 else {
            throw HUDStoreError.openFailed("Cannot save device preferences")
        }
        document = updated
    }
}

/// Keeps the original database in place. New accounts get empty business stores.
struct AccountStoreCoordinator {
    struct Bootstrap {
        let store: HUDStore
        let databaseRoot: String?
        let storePath: String
    }

    struct ReadOnlyBootstrap {
        let deviceSettings: DeviceSettingsStore
        let syncConfig: SyncConfig
        let store: HUDStore?
        let databaseRoot: String?
        let storePath: String?
    }

    let supportDirectory: URL

    init(supportDirectory: URL = URL(fileURLWithPath: NSHomeDirectory() + "/.wechat-hud")) {
        self.supportDirectory = supportDirectory
    }

    func bootstrap(databaseCandidates: [String] = WeChatReader.databaseCandidates()) throws -> Bootstrap {
        let fm = FileManager.default
        let legacyPath = supportDirectory.appendingPathComponent("hud.sqlite3")
        let device = try DeviceSettingsStore(path: supportDirectory.appendingPathComponent("device-settings.json"))
        var legacy: HUDStore?
        if fm.fileExists(atPath: legacyPath.path) {
            let original = HUDStore(dbPath: legacyPath.path)
            try original.open()
            legacy = original
        }
        let oldSync = legacy?.getSettingJSON("sync", as: SyncConfig.self) ?? SyncConfig()
        // Current discovery is not evidence of which account created legacy data.
        // An old "auto" setting must never bind A's history to the sole remaining B.
        let legacyPathSetting = oldSync.wechatDBPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalRoot = (legacyPathSetting.isEmpty || legacyPathSetting == "auto") ? nil
            : Self.selectedRoot(configuredPath: legacyPathSetting, candidates: [])
        var isDirectory: ObjCBool = false
        let validOriginal = originalRoot.flatMap { root in
            fm.fileExists(atPath: root, isDirectory: &isDirectory) && isDirectory.boolValue ? root : nil
        }
        var initialSettings: [String: String] = [:]
        for key in DeviceSettingsStore.sharedKeys {
            if let value = legacy?.getSetting(key) { initialSettings[key] = value }
        }
        try device.initializeIfNeeded(legacySettings: initialSettings,
                                      legacyAccountRoot: legacy == nil ? nil : validOriginal)
        let sync = device.get("sync").flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(SyncConfig.self, from: $0) } ?? SyncConfig()
        let root = Self.selectedRoot(configuredPath: sync.wechatDBPath, candidates: databaseCandidates)
        let identity = root.map(WeChatReader.accountCacheIdentity)
        let useLegacy = identity != nil && identity == device.legacyAccountIdentity && legacy != nil
        let storePath = useLegacy ? legacyPath.path
            : supportDirectory.appendingPathComponent("accounts/" + (identity ?? "unconfigured") + "/hud.sqlite3").path
        let store: HUDStore
        if useLegacy, let legacy {
            store = legacy
            store.deviceSettings = device
        } else {
            legacy?.close()
            store = HUDStore(dbPath: storePath)
            store.deviceSettings = device
            try store.open()
        }
        return Bootstrap(store: store, databaseRoot: root, storePath: storePath)
    }

    /// Discovers the selected account and reads existing state without
    /// creating directories, initializing settings, migrating schema, or
    /// opening SQLite in a write-capable mode. Missing business stores are
    /// represented by a nil store so source diagnostics can still proceed.
    func readOnly(databaseCandidates: [String] = WeChatReader.databaseCandidates()) throws -> ReadOnlyBootstrap {
        let fm = FileManager.default
        let device = try DeviceSettingsStore(path: supportDirectory.appendingPathComponent("device-settings.json"))
        let deviceRaw = device.get("sync")
        let deviceSync: SyncConfig?
        if let deviceRaw {
            guard let data = deviceRaw.data(using: .utf8), let decoded = try? JSONDecoder().decode(SyncConfig.self, from: data) else {
                throw HUDStoreError.openFailed("Read-only device configuration is unavailable")
            }
            deviceSync = decoded
        } else { deviceSync = nil }
        let legacyPath = supportDirectory.appendingPathComponent("hud.sqlite3").path
        var sync = deviceSync ?? SyncConfig()
        if deviceSync == nil, fm.fileExists(atPath: legacyPath) {
            guard let legacy = try Self.diagnosticSnapshot(path: legacyPath) else {
                throw HUDStoreError.openFailed("Read-only device configuration is unavailable")
            }
            defer { legacy.close() }
            guard let raw = legacy.getSetting("sync"), let data = raw.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(SyncConfig.self, from: data) else {
                throw HUDStoreError.openFailed("Read-only device configuration is unavailable")
            }
            sync = decoded
        }
        let root = Self.selectedRoot(configuredPath: sync.wechatDBPath, candidates: databaseCandidates)
        let identity = root.map(WeChatReader.accountCacheIdentity)
        let selectedPath = identity.map { id in
            id == device.legacyAccountIdentity ? legacyPath
                : supportDirectory.appendingPathComponent("accounts/\(id)/hud.sqlite3").path
        }
        // Optional business counters must not prevent a source check.
        let selected = selectedPath.flatMap { try? Self.diagnosticSnapshot(path: $0) }
        selected?.deviceSettings = device
        return ReadOnlyBootstrap(deviceSettings: device, syncConfig: sync,
                                 store: selected, databaseRoot: root, storePath: selectedPath)
    }

    /// Never opens the original database with SQLite. Refuse potentially
    /// active databases and discard a copy if the source changes during copying.
    private static func diagnosticSnapshot(path: String) throws -> HUDStore? {
        let fm = FileManager.default
        func hasSidecars() -> Bool {
            ["-wal", "-journal"].contains { fm.fileExists(atPath: path + $0) }
        }
        guard fm.fileExists(atPath: path), !hasSidecars() else { return nil }
        let before = try fm.attributesOfItem(atPath: path)
        guard let size = before[.size] as? NSNumber,
              let modified = before[.modificationDate] as? Date else { return nil }
        let directory = fm.temporaryDirectory.appendingPathComponent("wechat-hud-diagnostic-\(UUID().uuidString)")
        try fm.createDirectory(at: directory, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        var retained = false
        defer { if !retained { try? fm.removeItem(at: directory) } }
        let copy = directory.appendingPathComponent("snapshot.sqlite3")
        try fm.copyItem(atPath: path, toPath: copy.path)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
        let after = try fm.attributesOfItem(atPath: path)
        guard !hasSidecars(), after[.size] as? NSNumber == size,
              after[.modificationDate] as? Date == modified,
              after[.systemFileNumber] as? NSNumber == before[.systemFileNumber] as? NSNumber else { return nil }
        let store = HUDStore(dbPath: copy.path, createParentDirectory: false, cleanupPath: directory.path)
        try store.openReadOnly()
        retained = true
        return store
    }

    static func selectedRoot(configuredPath: String, candidates: [String]) -> String? {
        let path = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty || path == "auto" {
            guard candidates.count == 1 else { return nil }
            return canonicalRoot(candidates[0])
        }
        return canonicalRoot(path)
    }

    private static func canonicalRoot(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL.resolvingSymlinksInPath().path
    }
}
