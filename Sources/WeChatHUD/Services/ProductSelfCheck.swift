import Foundation

/// Local diagnostics report counts and capability states, never chat contents or keys.
enum ProductSelfCheck {
    typealias AICheckSlotTester = (AIProviderSlot) async throws -> String
    static func run() {
        var result: [String: Any] = ["mode": "source-read-only", "generated_at": ISO8601DateFormatter().string(from: Date())]
        do {
            _ = try PromptLoader().load(version: "classifier_v4")
            result["bundled_prompts"] = "ready"
        } catch { result["bundled_prompts"] = "unavailable" }
        do {
            let candidates = WeChatReader.databaseCandidates()
            result["account_candidates"] = candidates.count
            let bootstrap = try AccountStoreCoordinator().readOnly(databaseCandidates: candidates)
            defer { bootstrap.store?.close() }
            switch bootstrap.deviceSettings.legacyStoreStatus {
            case .absent: result["legacy_records"] = "absent"
            case .bound: result["legacy_records"] = "bound"
            case .needsAccountConfirmation: result["legacy_records"] = "account_confirmation_required"
            }
            guard let root = bootstrap.databaseRoot else {
                result["database"] = candidates.isEmpty ? "not_found" : "selection_required"
                result["business_store"] = "unavailable"
                emit(result); return
            }
            // The diagnostic uses a disposable, account-scoped plaintext cache.
            let syncCfg = bootstrap.syncConfig
            let reader = WeChatReader(keysPath: syncCfg.keysFilePath, dbDir: root, cacheStrategy: .memory,
                                      persistLearnedAliases: false)
            try reader.loadKeys()
            _ = try? reader.refreshContactsIfChanged()
            let sessions = try reader.getSessions()
            result["database"] = "readable"
            result["business_store"] = bootstrap.store == nil ? "unavailable" : "readable"
            result["diagnostic_cache"] = "temporary_only"
            result["sessions"] = sessions.count
            result["wechat_contacts"] = reader.allContacts().count
            if let store = bootstrap.store {
                result["tracked_chats"] = store.getWhitelist().count
                result["pending_classifications"] = store.classificationQueueCount()
                result["discussion_items"] = store.loadDiscussionItems().count
                result["discussion_feedback"] = store.loadAIFeedback(msgUIDPrefix: "discussion_item:").count
                result["reply_drafts"] = store.loadDrafts().count
            } else {
                result["tracked_chats"] = "unavailable"
                result["pending_classifications"] = "unavailable"
                result["discussion_items"] = "unavailable"
                result["discussion_feedback"] = "unavailable"
                result["reply_drafts"] = "unavailable"
            }
            // Session timestamps are not a reliable proxy for message-table
            // availability. Probe up to 100 distinct non-system sessions,
            // prioritizing tracked chats, without printing any private data.
            var probed = 0
            var readableMessages = 0
            var failedProbes = 0
            let probeCandidates = diagnosticSessionCandidates(
                sessions,
                trackedUsernames: Set(bootstrap.store?.getWhitelist().map(\.id) ?? [])
            )
            for session in probeCandidates {
                probed += 1
                do {
                    let count = try reader.getMessages(chatUsername: session.username, limit: 1).count
                    if count > 0 {
                        readableMessages = count
                        break
                    }
                } catch {
                    failedProbes += 1
                }
            }
            let probeStatus: String
            if readableMessages > 0 {
                probeStatus = "readable"
            } else if !probeCandidates.isEmpty && failedProbes == probeCandidates.count {
                probeStatus = "failed"
            } else {
                probeStatus = "empty"
            }
            result["message_probe"] = probeStatus
            result["message_probe_count"] = readableMessages
            result["probed_sessions"] = probed
            result["message_probe_failures"] = failedProbes
        } catch {
            result["database"] = "needs_attention"
            result["next_step"] = "Open Connections and Data to verify the selected directory and access materials."
        }
        emit(result)
    }

    /// Read the device-scoped AI configuration and send one synthetic test
    /// request to the selected primary slot. This intentionally calls
    /// `testSlot` (rather than `testConnection`/`complete`) so auto mode
    /// cannot report a fallback provider as a successful primary check.
    /// No connection evidence or other setting is written here.
    @discardableResult
    static func runAICheck(timeout: TimeInterval = 30) -> Int32 {
        let settingsURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".wechat-hud/device-settings.json")
        let result: [String: Any]
        do {
            let device = try DeviceSettingsStore(path: settingsURL)
            guard let raw = device.get("ai"),
                  let data = raw.data(using: .utf8) else {
                result = aiCheckUnavailable(providerID: "unconfigured")
                emit(result)
                return 1
            }
            var config = try JSONDecoder().decode(AIConfig.self, from: data)
            config.migrateIfNeeded()
            result = aiCheck(config: config, timeout: timeout)
        } catch {
            result = aiCheckUnavailable(providerID: "unconfigured")
        }
        emit(result)
        return result["result"] as? String == "success" ? 0 : 1
    }

    private static func aiCheckUnavailable(providerID: String) -> [String: Any] {
        [
            "mode": "synthetic-ai-check",
            "result": "unconfigured",
            "providerID": providerID,
            "generated_at": ISO8601DateFormatter().string(from: Date()),
            "next_step": "Open AI settings, configure the primary service, and run its connection test."
        ]
    }

    static func aiCheck(
        config: AIConfig,
        timeout: TimeInterval,
        testSlot: AICheckSlotTester? = nil
    ) -> [String: Any] {
        let slot = config.provider
        let normalizedProviderID = slot.providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let providerID = normalizedProviderID.isEmpty ? "unconfigured" : normalizedProviderID
        let configured = providerID != "unconfigured"
            && !slot.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (providerID == "openai-codex" || !slot.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        guard configured else { return aiCheckUnavailable(providerID: providerID) }

        let finished = DispatchSemaphore(value: 0)
        let success = DispatchSemaphore(value: 0)
        let failureSignals = Dictionary(
            uniqueKeysWithValues: ["timeout", "authentication", "model", "network", "unknown"]
                .map { ($0, DispatchSemaphore(value: 0)) }
        )
        let service = AIService(config: config)
        let task = Task {
            do {
                if let testSlot {
                    _ = try await testSlot(slot)
                } else {
                    _ = try await service.testSlot(slot)
                }
                success.signal()
            } catch {
                // Never expose provider, URLSession, server, or credential
                // details through this diagnostic command.
                failureSignals[aiFailureCategory(error)]?.signal()
            }
            finished.signal()
        }

        let didFinish = finished.wait(timeout: .now() + max(0.1, timeout)) == .success
        let wasSuccessful = didFinish && success.wait(timeout: .now()) == .success
        if !didFinish {
            task.cancel()
            return [
                "mode": "synthetic-ai-check",
                "result": "timeout",
                "providerID": providerID,
                "generated_at": ISO8601DateFormatter().string(from: Date()),
                "category": "timeout",
                "next_step": "Check the configured AI service and network, then retry the connection test."
            ]
        }
        if wasSuccessful {
            return [
                "mode": "synthetic-ai-check",
                "result": "success",
                "providerID": providerID,
                "generated_at": ISO8601DateFormatter().string(from: Date())
            ]
        }
        let category = ["authentication", "model", "network", "unknown"]
            .first { failureSignals[$0]?.wait(timeout: .now()) == .success } ?? "unknown"
        return [
            "mode": "synthetic-ai-check",
            "result": "failed",
            "providerID": providerID,
            "generated_at": ISO8601DateFormatter().string(from: Date()),
            "category": category,
            "next_step": "Check the configured AI service and network, then retry the connection test."
        ]
    }

    /// Keep the categorization intentionally coarse. The inspected error is
    /// never serialized, so provider payloads and credentials cannot escape.
    static func aiFailureCategory(_ error: Error) -> String {
        if let urlError = error as? URLError {
            return urlError.code == .timedOut ? "timeout" : "network"
        }
        if let codexError = error as? CodexError {
            switch codexError {
            case .timeout: return "timeout"
            case .notLoggedIn, .notChatGPTMode, .missingTokens, .invalidJWT,
                 .missingAccountId, .authRefreshFailed, .authExpired:
                return "authentication"
            case .responseFailed, .invalidResponse: return "model"
            case .usageLimitReached: return "authentication"
            case .backendError: return "network"
            }
        }
        if let aiError = error as? AIError {
            switch aiError {
            case .invalidURL: return "network"
            case .parseFailed: return "model"
            case .requestFailed(let message):
                let text = message.lowercased()
                if text.contains("401") || text.contains("403")
                    || text.contains("unauthorized") || text.contains("forbidden")
                    || text.contains("api key") || text.contains("apikey")
                    || text.contains("authentication") || text.contains("token") {
                    return "authentication"
                }
                if text.contains("timeout") || text.contains("timed out") {
                    return "timeout"
                }
                if text.contains("model") || text.contains("deployment")
                    || text.contains("404") || text.contains("not found") {
                    return "model"
                }
                return "network"
            }
        }
        return "unknown"
    }

    static func diagnosticSessionCandidates(
        _ sessions: [SessionInfo],
        trackedUsernames: Set<String>,
        limit: Int = 100
    ) -> [SessionInfo] {
        var seen = Set<String>()
        let candidates = sessions.filter { session in
            guard !session.username.isEmpty, !isDiagnosticSystemSession(session.username) else { return false }
            return seen.insert(session.username).inserted
        }
        let tracked = candidates.filter { trackedUsernames.contains($0.username) }
        let other = candidates.filter { !trackedUsernames.contains($0.username) }
        return Array((tracked + other).prefix(max(0, limit)))
    }

    private static func isDiagnosticSystemSession(_ username: String) -> Bool {
        let exact = Set([
            "weixin", "qqmail", "qqsync", "qqsafe", "facebook", "voipapp",
            "masssendapp", "feedsapp", "filehelper", "medianote", "newsapp",
            "floatbottle", "officialaccounts", "fmessage", "tmessage"
        ])
        let prefixes = [
            "gh_", "notification_", "notifymessage", "brandsessionholder",
            "masssend", "voip", "blogapp"
        ]
        return exact.contains(username)
            || prefixes.contains(where: username.hasPrefix)
            || username.contains("@openim")
            || username.contains("@im.chatroom")
    }

    private static func emit(_ result: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) else { return }
        print(String(decoding: data, as: UTF8.self))
    }
}
