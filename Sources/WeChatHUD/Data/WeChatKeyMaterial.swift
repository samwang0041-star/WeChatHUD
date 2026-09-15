import Foundation

/// Parsers for the access-material shapes a user may already hold.
///
/// Why this is its own type: the reader used to accept exactly one shape —
/// `{ "<db-relative-path>": { "enc_key": "<64 hex>" } }` — and silently
/// `continue`d past anything else. A file in any other shape therefore loaded
/// **zero** keys and surfaced as "no key for this database", which reads as
/// "your key is wrong" when the truth is "this file is not in a shape I read".
/// That is the most expensive kind of wrong: the user goes looking for a new
/// key when nothing was wrong with the one they had.
///
/// Three shapes are accepted, in the order the ecosystem produces them:
///
///   1. Path map, object form — `{ "message/message_0.db": { "enc_key": "…",
///      "salt": "…" } }`. What this project’s own key preparation writes, so
///      it is the shape already on disk for existing users.
///   2. Path map, bare form — `{ "message_0.db": "…" }`, plus `"key"` as an
///      alias for `"enc_key"`. The other public convention for the same idea.
///   3. Schema-2 salt map — `{ "schema_version": 2, "keys": { "<32 hex
///      salt>": "<64 hex post-PBKDF2 key>" } }`. Keyed by each database’s own
///      first 16 bytes rather than by a path.
///
/// Shape 3 is the reason this matters beyond mere tolerance: it is *content
/// addressed*. A path map breaks the moment a database is renamed or moved, and
/// cannot express a key set collected without paths at all. The salt is also
/// already sitting in this project’s own key files — written by
/// `WeChatKeyPreparationService`, ignored by the reader — so accepting it gives
/// the reader a second, independent way to find a key it already has.
///
/// Nothing here derives, extracts or recovers a key. It reads material the user
/// already possesses and normalises it.
enum WeChatKeyMaterial {

    /// Bytes a database key must be. SQLCipher raw keys are 32 bytes.
    static let keyByteCount = 32
    /// Bytes of the database header that identify it: the page-1 salt.
    static let saltByteCount = 16

    // MARK: - Entry keys

    /// The key inside one path-map entry, whichever spelling it uses.
    ///
    /// Returns nil for anything that is neither a bare 64-hex string nor an
    /// object carrying `enc_key` / `key`. Callers count those separately so an
    /// unrecognised file becomes a visible state instead of an empty one.
    static func keyData(from entry: Any) -> Data? {
        if let hex = entry as? String {
            return keyData(fromHex: hex)
        }
        guard let object = entry as? [String: Any] else { return nil }
        for field in ["enc_key", "key"] {
            if let hex = object[field] as? String, let data = keyData(fromHex: hex) {
                return data
            }
        }
        return nil
    }

    /// Decode a hex key, enforcing the 32-byte length SQLCipher expects.
    ///
    /// The length check is not cosmetic: a truncated value, or a 96-hex
    /// `enc_key + salt`, would otherwise load as a key that can never match and
    /// fail later as a decrypt error instead of here as a format error.
    static func keyData(fromHex hex: String) -> Data? {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(hexString: trimmed), data.count == keyByteCount else { return nil }
        return data
    }

    /// True for a top-level name that is metadata rather than a database path.
    ///
    /// These are the names that carry the file’s own envelope; treating one as
    /// a path would put a key under a name no lookup ever asks for.
    static func isEnvelopeKey(_ key: String) -> Bool {
        key.hasPrefix("_") || key == "schema_version" || key == "keys"
    }

    // MARK: - Salt map

    /// Result of parsing a schema-2 salt map.
    struct SaltMap: Equatable {
        /// Lowercased 32-hex salt → 32-byte key.
        var keys: [String: Data]
        /// Entries that carried a salt and a value but failed validation, so a
        /// caller can report a partially-usable file rather than a whole one.
        var rejectedEntries: Int
    }

    /// Parse `{ "schema_version": 2, "keys": { salt: key } }`.
    ///
    /// Returns nil when the file is not a salt map at all — including when it
    /// has a `keys` dictionary whose values are objects, which is the path-map
    /// shape and must be left to the path map parser.
    static func saltMap(from json: [String: Any]) -> SaltMap? {
        guard schemaVersion(from: json) == 2 else { return nil }
        guard let raw = json["keys"] as? [String: Any], !raw.isEmpty else { return nil }

        var keys: [String: Data] = [:]
        var rejected = 0
        for (saltHex, value) in raw {
            guard let salt = normalizedSalt(saltHex),
                  let key = keyData(from: value) else {
                rejected += 1
                continue
            }
            keys[salt] = key
        }
        // A map that is entirely objects (or entirely malformed) is not this
        // shape; leaving it to the path parser avoids claiming the file.
        guard !keys.isEmpty else { return nil }
        return SaltMap(keys: keys, rejectedEntries: rejected)
    }

    /// Lowercased 32-hex salt, or nil when the string is not one.
    static func normalizedSalt(_ hex: String) -> String? {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count == saltByteCount * 2,
              trimmed.allSatisfy({ $0.isHexDigit }),
              let data = Data(hexString: trimmed), data.count == saltByteCount else { return nil }
        return trimmed
    }

    /// `schema_version` as an integer, tolerating the string spelling.
    private static func schemaVersion(from json: [String: Any]) -> Int? {
        if let value = json["schema_version"] as? Int { return value }
        if let value = json["schema_version"] as? String { return Int(value) }
        return nil
    }

    // MARK: - Database salt

    /// First 16 bytes of an encrypted database, as lowercased hex.
    ///
    /// Reads at most `saltByteCount` bytes: the header salt is the whole
    /// identifying input, and a multi-gigabyte message database must not be
    /// pulled into memory to find it.
    static func headerSaltHex(atPath path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: saltByteCount),
              data.count == saltByteCount else { return nil }
        return data.map { String(format: "%02x", $0) }.joined()
    }
}
