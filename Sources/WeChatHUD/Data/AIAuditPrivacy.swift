import CryptoKit
import Foundation

/// Default AI audit writer: store a redacted snippet plus a hash, never the
/// raw prompt/response.
///
/// `WCHUD_AI_AUDIT_RAW=1` opts back into plaintext. It is deliberately not
/// `#if DEBUG`: this app is built and run in release for its whole life, so a
/// debug-only escape hatch would be no hatch at all. The honest consequence is
/// that the switch is reachable by anything that can set an environment variable
/// for this user, and the rows it writes are pruned on the ordinary 14-day
/// audit schedule — not zero-day, whatever an earlier version of this comment
/// claimed. Turning it on is a decision to keep unredacted prompts on disk.
enum AIAuditPrivacy {
    static let snippetLimit = 240

    static var persistRawText: Bool {
        let flag = ProcessInfo.processInfo.environment["WCHUD_AI_AUDIT_RAW"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return flag == "1" || flag == "true" || flag == "yes"
    }

    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Persistence form written to `ai_audit.input_text` / `output_text`.
    static func persistableText(_ raw: String) -> String {
        if persistRawText { return raw }
        // `Redactor.applyMasks` is the retrospective path's stronger name/codename
        // layer, but on its own it is the *four-regex* version: a mobile typed as
        // 「138 0013 8000」, a full-width 全角 number, a `+86` prefix, a grouped card
        // number or a copy-pasted zero-width one all walked straight through it and
        // landed in `ai_audit` — which meant the local copy of a prompt kept PII
        // shapes that the wire copy had masked. The floor has to be the same
        // function at both boundaries, or the claim on this file's header
        // (「never the raw prompt/response」) is only true of half the pipeline.
        let redacted = Redactor.applyMasks(AIService.maskDirectIdentifiers(raw))
        let snippet = String(redacted.prefix(snippetLimit))
        return "sha256:\(sha256Hex(raw))\n\(snippet)"
    }
}
