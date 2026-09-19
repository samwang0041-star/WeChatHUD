import XCTest
@testable import WeChatHUD

/// An existing `~/.wechat-hud/hud.sqlite3` is opened by newer code, and two
/// statements in that upgrade path disagreed about what a failure means.
final class SchemaUpgradeResilienceTests: XCTestCase {
    private var tmpDir: URL!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func store(at path: String) throws -> HUDStore {
        let store = HUDStore(dbPath: path)
        try store.open()
        return store
    }

    private func columns(_ store: HUDStore, table: String) throws -> Set<String> {
        var found: Set<String> = []
        for name in store.tableInfo(table) { found.insert(name) }
        return found
    }

    /// The old guard probed only `shared_context` and then applied the pair as
    /// a block, so this shape — first ALTER landed, second did not — was
    /// declared finished on every later launch. `communication_notes` then
    /// stayed missing for the life of the file, and every read and write of it
    /// failed without a log line.
    func testHalfMigratedConversationMemoryIsCompletedOnNextOpen() throws {
        let path = tmpDir.appendingPathComponent("half.sqlite3").path
        let first = try store(at: path)
        try first.exec("DROP TABLE conversation_memory")
        try first.exec("""
            CREATE TABLE conversation_memory (
                chat_username TEXT PRIMARY KEY,
                summary TEXT NOT NULL DEFAULT '',
                key_topics TEXT NOT NULL DEFAULT '[]',
                pending_items TEXT NOT NULL DEFAULT '[]',
                shared_context TEXT NOT NULL DEFAULT '[]',
                mood_trend TEXT NOT NULL DEFAULT '',
                message_count_7d INTEGER NOT NULL DEFAULT 0,
                last_updated INTEGER NOT NULL DEFAULT 0
            )
            """)
        first.close()

        let second = try store(at: path)
        let after = try columns(second, table: "conversation_memory")
        second.close()

        XCTAssertTrue(after.contains("shared_context"), "the column that did land stays")
        XCTAssertTrue(after.contains("communication_notes"),
                      "a column the previous block skipped must be added on its own")
        XCTAssertTrue(after.contains("conversation_phase"))
        XCTAssertTrue(after.contains("stance"))
    }

    /// Same class, one level up: an index whose column comes from a
    /// swallowed ALTER must not be able to make `open()` throw. That pair was
    /// `autopilot_log.queue_id` — one busy write lock away from a modal and
    /// `NSApp.terminate` on every launch for every existing database, while
    /// the comment two lines above declared the missing column runnable.
    func testNoIndexHardFailsOnAColumnThatMayBeMissing() throws {
        let source = try read("Sources/WeChatHUD/Data/HUDStore.swift")
        let lines = source.components(separatedBy: "\n")

        var optionalAlterColumns: Set<String> = []
        var hardIndexTargets: [String] = []
        for (offset, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.contains("try? exec(\"ALTER TABLE ") {
                if let pair = Self.alteredColumn(in: line) {
                    optionalAlterColumns.insert("\(pair.table).\(pair.column)")
                }
            }
            if line.hasPrefix("try exec(\"CREATE INDEX") {
                guard let pair = Self.indexTarget(in: line) else { continue }
                for column in pair.columns {
                    hardIndexTargets.append("\(offset + 1):\(pair.table).\(column)")
                }
            }
        }

        // Coverage floor: without it, a parser that matched nothing looks
        // exactly like a file with no defects.
        XCTAssertGreaterThanOrEqual(optionalAlterColumns.count, 12,
                                    "升级路径的 ADD COLUMN 至少应扫出这么多，否则是判据自己坏了")
        XCTAssertGreaterThanOrEqual(hardIndexTargets.count, 10,
                                    "硬 try 的 CREATE INDEX 至少应扫出这么多")

        let offending = hardIndexTargets.filter {
            optionalAlterColumns.contains($0.components(separatedBy: ":").last ?? "")
        }
        XCTAssertTrue(offending.isEmpty,
                      "这些索引建在被吞掉错误的 ALTER 列上，一次 ALTER 失败就会让 open() 抛错: \(offending)")
    }

    /// `ALTER TABLE <table> ADD COLUMN <column> …`
    private static func alteredColumn(in line: String) -> (table: String, column: String)? {
        let parts = line.split(separator: " ")
        guard let atIndex = parts.firstIndex(of: "TABLE"), atIndex + 1 < parts.count,
              let columnIndex = parts.firstIndex(of: "COLUMN"), columnIndex + 1 < parts.count
        else { return nil }
        return (
            String(parts[atIndex + 1]).trimmingCharacters(in: CharacterSet(charactersIn: "(\"';")),
            String(parts[columnIndex + 1]).trimmingCharacters(in: CharacterSet(charactersIn: "(\"';"))
        )
    }

    /// `CREATE INDEX … ON <table>(<col>, <col> DESC)`
    private static func indexTarget(in line: String) -> (table: String, columns: [String])? {
        guard let on = line.range(of: " ON ") else { return nil }
        let rest = line[on.upperBound...]
        let table = String(rest.prefix { $0 != "(" && $0 != " " && $0 != "\"" })
        guard let paren = rest.range(of: "(") else { return nil }
        let inside = rest[paren.upperBound...].prefix(while: { $0 != ")" })
        let columns = inside.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        }.filter { !$0.isEmpty }
        guard !table.isEmpty, !columns.isEmpty else { return nil }
        return (table, columns)
    }

    /// The index pass now reports whether it landed, but a second block used to
    /// follow it and stamp `currentVersion` unconditionally — which made the
    /// guard inert. The doc comment promised 「a failed pass retried forever」;
    /// with the stamp in place the retry could never happen on any launch after
    /// the one that failed, so an unindexed store stayed unindexed silently.
    func testFailedIndexMigrationLeavesTheVersionForTheNextLaunch() throws {
        let path = tmpDir.appendingPathComponent("v3retry.sqlite3").path
        let store = try store(at: path)
        defer { store.close() }

        store.setSchemaUserVersion(2)
        XCTAssertTrue(store.migrateToV3RetrospectiveIndexes(),
                      "正常情况下这两条索引该建得起来")
        try SchemaMigrator.applyAfterRetrospective(to: store)
        XCTAssertEqual(store.schemaUserVersion(), SchemaMigrator.currentVersion,
                       "落地的迁移要盖章，不然每次启动都重来一遍")

        store.setSchemaUserVersion(2)
        try store.exec("DROP TABLE red_banner_dismissals")
        XCTAssertFalse(store.migrateToV3RetrospectiveIndexes(),
                       "表不在时索引必然建不成，这里必须报失败")
        try SchemaMigrator.applyAfterRetrospective(to: store)
        XCTAssertLessThan(store.schemaUserVersion(), 3,
                          "没落地的迁移不许盖章，否则下次启动不会再试")
    }

    private func read(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }
}
