import Foundation

/// Per-run codename map + sensitive-pattern masker (Spec §6.3).
///
/// Within a single RetrospectiveJob run:
/// - Each unique `senderUsername` (wxid) gets a stable codename (A1/A2/A3…).
/// - When two contacts share a displayName but have different wxids, they
///   get distinct codenames (correct: they ARE different people).
/// - The reverse map is used to replace AI output's codename mentions
///   with the original display names before persisting / showing in UI.
/// - Phone, email, money tokens are masked unconditionally.
///
/// The map lives only in memory — never persisted to disk.
actor Redactor {

    private var codenameByUsername: [String: String] = [:]
    private var displayNameByCodename: [String: String] = [:]
    private var nextIndex = 1

    nonisolated init() {}

    /// Returns the codename for `username`, creating one if first seen.
    /// Same username → same codename for the lifetime of this Redactor.
    func codenameFor(username: String, displayName: String) -> String {
        if let existing = codenameByUsername[username] {
            // Update displayName mapping if it was empty before but now has one.
            if displayNameByCodename[existing]?.isEmpty != false, !displayName.isEmpty {
                displayNameByCodename[existing] = displayName
            }
            return existing
        }
        let code = "A\(nextIndex)"
        nextIndex += 1
        codenameByUsername[username] = code
        displayNameByCodename[code] = displayName
        return code
    }

    /// Returns the display name (or nil) for a codename.
    func originalForCodename(_ code: String) -> String? {
        let name = displayNameByCodename[code]
        return (name?.isEmpty == false) ? name : nil
    }

    /// Replaces registered display names with their codenames + applies
    /// sensitive-pattern masks + strips WeChat placeholders that trigger
    /// provider content filters. Idempotent within a run.
    func redactText(_ s: String) -> String {
        var out = AIService.sanitizeForAI(s)
        // Codenames first: longest displayName first to avoid partial collisions.
        let names = displayNameByCodename
            .compactMap { (code, name) -> (String, String)? in
                guard let n = name as String?, !n.isEmpty else { return nil }
                return (n, code)
            }
            .sorted { $0.0.count > $1.0.count }
        for (name, code) in names {
            out = out.replacingOccurrences(of: name, with: code)
        }
        return Redactor.applyMasks(out)
    }

    /// Reverses codenames → display names in AI-generated text.
    /// Used after the model returns to convert "A1 决定上线" back to
    /// "张总 决定上线" before persisting.
    func unredactText(_ s: String) -> String {
        var out = s
        // Replace codenames standalone (avoid mid-word substitution).
        // Iterate longest codename first so "A10" doesn't get partially matched as "A1".
        let pairs = displayNameByCodename
            .map { ($0.key, $0.value) }
            .sorted { $0.0.count > $1.0.count }
        for (code, name) in pairs where !name.isEmpty {
            out = Redactor.replaceStandaloneToken(in: out, token: code, with: name)
        }
        return out
    }

    // MARK: - Static helpers (pure, can be reused by tests)

    static func applyMasks(_ s: String) -> String {
        var out = s
        // Phone: 11-digit Chinese mobile starting with 1, OR 7-15 digit run
        out = out.replacingOccurrences(
            of: #"(?:1\d{10})|(?:\b\d{7,11}\b)"#,
            with: "[手机]",
            options: .regularExpression
        )
        // Email
        out = out.replacingOccurrences(
            of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
            with: "[邮箱]",
            options: .regularExpression
        )
        // Money: ¥xxx / $xxx / 50万 / 100K / 30M
        out = out.replacingOccurrences(
            of: #"(?:¥\s?\d+[\d,.]*)|(?:\$\s?\d+[\d,.]*)|(?:\d+\s?[KkMm万千百])"#,
            with: "[金额]",
            options: .regularExpression
        )
        return out
    }

    static func replaceStandaloneToken(in s: String, token: String, with replacement: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: token)
        let pattern = "(?<![A-Za-z0-9])\(escaped)(?![A-Za-z0-9])"
        return s.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
}
