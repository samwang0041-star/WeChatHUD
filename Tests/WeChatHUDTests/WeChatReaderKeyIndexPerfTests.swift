import XCTest
@testable import WeChatHUD

/// `findKey(for:)` used to filter the whole key dictionary on every call. It is
/// called several times per DB per scan, so the lookup now runs against an index
/// built once per key load. These tests pin both halves of that: the index is
/// actually used, and it answers exactly like the linear filter it replaced.
final class WeChatReaderKeyIndexPerfTests: XCTestCase {
    private let relative = "message/message_0.db"

    // MARK: Index is used and rebuilt with the key material

    func testFindKeyNeverFallsBackToALinearScanOnceKeysAreLoaded() throws {
        let fixture = try WeChatReaderPerfFixture()
        defer { fixture.cleanUp() }
        var expected: [String: Data] = [:]
        for index in 0..<50 {
            let path = "message/message_\(index).db"
            let key = Data(repeating: UInt8(index + 1), count: 32)
            expected[path] = key
            fixture.addKeyEntry(path, key: key)
        }
        try fixture.writeKeyFile()
        let reader = try fixture.makeReader()
        XCTAssertEqual(reader.keyIndexBuildCount, 1, "the index must be built by the key load")

        for (path, key) in expected {
            XCTAssertEqual(reader.findKey(for: path), key, "index missed \(path)")
            XCTAssertEqual(reader.findKey(for: (path as NSString).lastPathComponent), key)
        }
        // Misses must be answered from the index too, not by walking `keys`.
        XCTAssertNil(reader.findKey(for: "message/message_missing.db"))
        XCTAssertNil(reader.findKey(for: "contact/contact.db"))

        XCTAssertEqual(reader.keyLookupLinearScanCount, 0, "findKey walked the key dictionary")
    }

    func testIndexRebuildsExactlyWhenTheKeyFileChanges() throws {
        let fixture = try WeChatReaderPerfFixture()
        defer { fixture.cleanUp() }
        let firstKey = Data(repeating: 0x11, count: 32)
        let secondKey = Data(repeating: 0x22, count: 32)
        fixture.addKeyEntry(relative, key: firstKey)
        try fixture.writeKeyFile(mtime: Date(timeIntervalSince1970: 1_700_000_000))
        let reader = try fixture.makeReader()
        XCTAssertEqual(reader.findKey(for: relative), firstKey)
        XCTAssertEqual(reader.keyIndexBuildCount, 1)

        // Same file mtime → unchanged material → the index must be reused.
        try reader.loadKeys()
        XCTAssertEqual(reader.keyIndexBuildCount, 1)

        fixture.addKeyEntry(relative, key: secondKey)
        try fixture.writeKeyFile(mtime: Date(timeIntervalSince1970: 1_700_000_500))
        try reader.loadKeys()
        XCTAssertEqual(reader.keyIndexBuildCount, 2, "a changed key file must rebuild the index")
        XCTAssertEqual(reader.findKey(for: relative), secondKey)

        try reader.loadKeys(force: true)
        XCTAssertEqual(reader.keyIndexBuildCount, 3, "a forced reload must rebuild the index")
    }

    // MARK: Equivalence with the original linear filter

    /// Differential test: every key-file shape is answered identically by the
    /// index and by a verbatim copy of the previous implementation.
    func testIndexAnswersExactlyLikeTheLinearFilter() throws {
        let shapes: [(name: String, entries: (String) -> [(String, Data)])] = [
            ("relative", { _ in [(self.relative, Data(repeating: 0x11, count: 32))] }),
            ("relative two DBs", { _ in
                [("message/message_0.db", Data(repeating: 0x11, count: 32)),
                 ("message/message_1.db", Data(repeating: 0x22, count: 32))]
            }),
            ("name only", { _ in [("message_0.db", Data(repeating: 0x11, count: 32))] }),
            ("backslash entry", { _ in [("message\\message_0.db", Data(repeating: 0x11, count: 32))] }),
            ("absolute under dbDir", { db in [("\(db)/message/message_0.db", Data(repeating: 0x33, count: 32))] }),
            ("absolute under dbDir + relative, same key", { db in
                [("\(db)/message/message_0.db", Data(repeating: 0x33, count: 32)),
                 ("message/message_0.db", Data(repeating: 0x33, count: 32))]
            }),
            ("absolute under dbDir + relative, conflict", { db in
                [("\(db)/message/message_0.db", Data(repeating: 0x33, count: 32)),
                 ("message/message_0.db", Data(repeating: 0x44, count: 32))]
            }),
            ("absolute under dbDir, two conflicts", { db in
                [("\(db)/a/message_0.db", Data(repeating: 0x33, count: 32)),
                 ("\(db)/b/message_0.db", Data(repeating: 0x44, count: 32))]
            }),
            ("absolute other account", { _ in [("/elsewhere/other_account/db_storage/message/message_0.db", Data(repeating: 0x55, count: 32))] }),
            ("absolute other account + relative", { _ in
                [("/elsewhere/other_account/db_storage/message/message_0.db", Data(repeating: 0x55, count: 32)),
                 ("message/message_0.db", Data(repeating: 0x11, count: 32))]
            }),
            ("filename collision, different keys", { _ in
                [("a/message_0.db", Data(repeating: 0x11, count: 32)),
                 ("b/message_0.db", Data(repeating: 0x22, count: 32))]
            }),
            ("filename collision, same key", { _ in
                [("a/message_0.db", Data(repeating: 0x11, count: 32)),
                 ("b/message_0.db", Data(repeating: 0x11, count: 32))]
            }),
            ("underscore entry ignored", { _ in
                [("_meta", Data(repeating: 0x99, count: 32)),
                 ("message/message_0.db", Data(repeating: 0x11, count: 32))]
            }),
            ("short key ignored", { _ in
                [("message/message_1.db", Data(repeating: 0x11, count: 16)),
                 ("message/message_0.db", Data(repeating: 0x11, count: 32))]
            }),
        ]

        for shape in shapes {
            let fixture = try WeChatReaderPerfFixture()
            defer { fixture.cleanUp() }
            let entries = shape.entries(fixture.dbDir.path)
            for (path, key) in entries { fixture.addKeyEntry(path, key: key) }
            try fixture.writeKeyFile(mtime: Date(timeIntervalSince1970: 1_700_000_000))
            let reader = try fixture.makeReader()
            let reference = Self.legacyKeys(from: entries)

            let queries = [
                relative,
                "message\\message_0.db",
                "message_0.db",
                "message/message_1.db",
                "contact/contact.db",
                "\(fixture.dbDir.path)/message/message_0.db",
                "\(fixture.dbDir.path)/a/message_0.db",
                "/elsewhere/other_account/db_storage/message/message_0.db",
            ]
            for query in queries {
                XCTAssertEqual(
                    reader.findKey(for: query),
                    Self.legacyFindKey(keys: reference, path: query, dbDir: fixture.dbDir.path),
                    "shape '\(shape.name)' diverged for query '\(query)'"
                )
            }
            XCTAssertEqual(reader.keyLookupLinearScanCount, 0, "shape '\(shape.name)' scanned linearly")
        }
    }

    // MARK: Reference implementation (previous behaviour, verbatim)

    private static func legacyKeys(from entries: [(String, Data)]) -> [String: Data] {
        var keys: [String: Data] = [:]
        for (path, key) in entries {
            guard !path.hasPrefix("_") else { continue }
            guard key.count == 32 else { continue }
            keys[path.replacingOccurrences(of: "\\", with: "/")] = key
        }
        return keys
    }

    private static func legacyFindKey(keys: [String: Data], path: String, dbDir: String) -> Data? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let filename = (normalized as NSString).lastPathComponent
        let candidates = keys.filter { keyPath, _ in
            let kp = keyPath.replacingOccurrences(of: "\\", with: "/")
            return kp == path || kp == normalized || (kp as NSString).lastPathComponent == filename
        }
        if candidates.isEmpty { return nil }

        let db = URL(fileURLWithPath: dbDir).standardizedFileURL.path
        let scoped = candidates.filter { keyPath, _ in
            let kp = keyPath.replacingOccurrences(of: "\\", with: "/")
            guard kp.hasPrefix("/") else { return false }
            let absolute = URL(fileURLWithPath: kp).standardizedFileURL.path
            return WeChatReader.keyPath(absolute, isUnderDatabaseRoot: db)
        }
        if !scoped.isEmpty {
            let unique = Set(scoped.map(\.value))
            return unique.count == 1 ? unique.first : nil
        }
        let hasAbsolute = candidates.contains { keyPath, _ in
            keyPath.replacingOccurrences(of: "\\", with: "/").hasPrefix("/")
        }
        if hasAbsolute { return nil }
        let unique = Set(candidates.map(\.value))
        return unique.count == 1 ? unique.first : nil
    }
}
