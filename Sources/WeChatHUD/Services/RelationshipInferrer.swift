import Foundation

actor RelationshipInferrer {
    private let store: HUDStore
    private var config: AIConfig
    private let promptLoader: PromptLoader
    private let promptVersion: String

    init(
        store: HUDStore,
        config: AIConfig,
        promptLoader: PromptLoader = PromptLoader(),
        promptVersion: String = "relationship_infer_v1"
    ) {
        self.store = store
        var cfg = config
        cfg.maxTokens = 256
        cfg.temperature = 0.1
        self.config = cfg
        self.promptLoader = promptLoader
        self.promptVersion = promptVersion
    }

    func updateConfig(_ newConfig: AIConfig) {
        var cfg = newConfig
        cfg.maxTokens = 256
        cfg.temperature = 0.1
        self.config = cfg
    }

    struct InferResult: Decodable {
        let relationship: String
        let hierarchy: String
        let tone_preference: String
        let context: String?
        let confidence: Double
    }

    func infer(
        contactUsername: String,
        contactName: String,
        isGroup: Bool,
        messages: [MessageInfo],
        myUsername: String,
        myDisplayName: String = "",
        mySelfNames: Set<String> = []
    ) async -> RelationshipProfile? {
        guard !messages.isEmpty else { return nil }

        let template: String
        do {
            template = try promptLoader.load(version: promptVersion)
        } catch {
            print("[WCHUD] RelationshipInferrer: prompt load failed: \(error)")
            return nil
        }

        let formatted = messages.prefix(50).map { msg in
            let isMe = MessageHelpers.isFromSelf(msg, chatUsername: contactUsername, myUsername: myUsername, myDisplayName: myDisplayName, mySelfNames: mySelfNames)
            let sender = isMe ? "用户" : (msg.senderName.isEmpty ? contactName : msg.senderName)
            return "\(sender): \(AIService.sanitizeForAI(msg.text))"
        }.joined(separator: "\n")

        let userPrompt = template
            .replacingOccurrences(of: "{contact_name}", with: contactName)
            .replacingOccurrences(of: "{chat_kind}", with: isGroup ? "群聊" : "私聊")
            .replacingOccurrences(of: "{messages}", with: formatted)

        let ai = AIService(config: config)
        let raw: String
        do {
            raw = try await ai.complete(
                system: "你是一个关系分析助手，严格按要求输出 JSON。",
                user: userPrompt,
                options: CompleteOptions(timeout: 60, temperature: 0.1, maxTokens: 512, responseFormatJSON: true)
            )
        } catch {
            print("[WCHUD] RelationshipInferrer: AI call failed: \(error)")
            return nil
        }

        guard let result = parseResult(raw) else {
            print("[WCHUD] RelationshipInferrer: parse failed for \(contactName)")
            return nil
        }

        let profile = RelationshipProfile(
            username: contactUsername,
            displayName: contactName,
            relationship: result.relationship,
            hierarchy: RelationshipProfile.Hierarchy(rawValue: result.hierarchy) ?? .peer,
            tonePreference: RelationshipProfile.TonePreference(rawValue: result.tone_preference) ?? .formal,
            context: result.context,
            confidence: min(max(result.confidence, 0), 1),
            userNote: nil,
            userEdited: false,
            inferredAt: Date(),
            updatedAt: Date()
        )

        let existing = store.getRelationshipProfile(username: contactUsername)
        if existing?.userEdited == true {
            return existing
        }

        do {
            try store.upsertRelationshipProfile(profile)
        } catch {
            print("[WCHUD] RelationshipInferrer: DB save failed: \(error)")
            // Do not report a successful inference when its durable result
            // was not written. Callers use nil to keep the previous profile
            // visible and show a retryable failure state.
            return nil
        }
        return profile
    }

    private func parseResult(_ raw: String) -> InferResult? {
        AIJSONExtractor.decodeFirstObject(from: raw, as: InferResult.self)
    }
}
