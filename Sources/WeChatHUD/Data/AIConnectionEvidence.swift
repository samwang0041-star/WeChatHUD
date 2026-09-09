import CryptoKit
import Foundation

extension Notification.Name {
    static let hudAIConnectionEvidenceDidChange = Notification.Name("WeChatHUD.AIConnectionEvidenceDidChange")
}

/// A durable record of an explicit AI connection test. The provider secret is
/// used only while computing the fingerprint and is never stored in a record.
struct AIConnectionEvidence: Codable, Equatable {
    static let settingKey = "ai_connection_evidence"

    struct Record: Codable, Equatable {
        let fingerprint: String
        let testedAt: Date
        let requestStartedAt: Date
        let succeeded: Bool

        private enum CodingKeys: String, CodingKey {
            case fingerprint, testedAt, requestStartedAt, succeeded
        }

        init(fingerprint: String, testedAt: Date, requestStartedAt: Date, succeeded: Bool) {
            self.fingerprint = fingerprint
            self.testedAt = testedAt
            self.requestStartedAt = requestStartedAt
            self.succeeded = succeeded
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            fingerprint = try container.decode(String.self, forKey: .fingerprint)
            testedAt = try container.decode(Date.self, forKey: .testedAt)
            // Evidence written before request start times were introduced is
            // still usable; its completion time is the safest lower bound.
            requestStartedAt = try container.decodeIfPresent(Date.self, forKey: .requestStartedAt) ?? testedAt
            succeeded = try container.decode(Bool.self, forKey: .succeeded)
        }
    }

    var provider: Record?
    // Legacy dual-slot records — read for compatibility, never written.
    var cloud: Record?
    var local: Record?

    init(provider: Record? = nil, cloud: Record? = nil, local: Record? = nil) {
        self.provider = provider
        self.cloud = cloud
        self.local = local
    }

    static func fingerprint(for slot: AIProviderSlot) -> String {
        // Length-prefixed fields avoid ambiguity while keeping the secret out
        // of the persisted representation. JSON is deterministic here because
        // the payload has a fixed Codable property order.
        let payload = FingerprintPayload(
            providerID: slot.providerID,
            baseURL: slot.baseURL,
            model: slot.model,
            apiKey: slot.apiKey
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(payload)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func record(for slot: AIProviderSlot) -> Record? {
        let candidates = [provider, cloud, local].compactMap { $0 }
        let candidate = candidates.first { $0.fingerprint == Self.fingerprint(for: slot) }
        guard let candidate, candidate.fingerprint == Self.fingerprint(for: slot) else { return nil }
        return candidate
    }

    @discardableResult
    mutating func setResult(
        for slot: AIProviderSlot,
        succeeded: Bool,
        at date: Date = Date(),
        requestStartedAt: Date? = nil
    ) -> Bool {
        let startedAt = requestStartedAt ?? date
        let fingerprint = Self.fingerprint(for: slot)
        let existing = provider
        if let existing,
           existing.requestStartedAt > startedAt
                || (existing.requestStartedAt == startedAt && existing.testedAt > date) {
            // A request that started later already has a durable result. This
            // protects a slow old request from overwriting it after a view was
            // closed and reopened.
            return false
        }
        let record = Record(
            fingerprint: fingerprint,
            testedAt: date,
            requestStartedAt: startedAt,
            succeeded: succeeded
        )
        self.provider = record
        // Legacy dual-slot records are superseded by the single provider key.
        self.cloud = nil
        self.local = nil
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case cloud, local
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decodeIfPresent(Record.self, forKey: .provider)
        cloud = try container.decodeIfPresent(Record.self, forKey: .cloud)
        local = try container.decodeIfPresent(Record.self, forKey: .local)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(provider, forKey: .provider)
    }

    private struct FingerprintPayload: Encodable {
        let providerID: String
        let baseURL: String
        let model: String
        let apiKey: String
    }
}

extension HUDStore {
    func loadAIConnectionEvidence() -> AIConnectionEvidence {
        getSettingJSON(AIConnectionEvidence.settingKey, as: AIConnectionEvidence.self)
            ?? AIConnectionEvidence()
    }

    func saveAIConnectionEvidence(_ evidence: AIConnectionEvidence) throws {
        try setSettingJSON(AIConnectionEvidence.settingKey, value: evidence)
        NotificationCenter.default.post(name: .hudAIConnectionEvidenceDidChange, object: nil)
    }
}

enum AIConnectionEvidenceStore {
    static func isSuccessful(_ config: AIConfig, store: HUDStore) -> Bool {
        store.loadAIConnectionEvidence().record(for: config.provider)?.succeeded == true
    }
}
