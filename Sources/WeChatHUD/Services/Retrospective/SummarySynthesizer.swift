import Foundation

/// One-shot summary pass: takes all of a run's highlights + todos
/// (already in DB) and asks AI for {top3, risk, missed} with evidence
/// pointers back to highlight ids. Spec §7.3.
actor SummarySynthesizer {
    private let store: HUDStore
    private let aiService: any AIServiceProtocol
    private let promptLoader: PromptLoader
    private let dataLedger: DataLedger
    private let redactor: Redactor

    init(
        store: HUDStore,
        aiService: any AIServiceProtocol,
        promptLoader: PromptLoader = PromptLoader(),
        dataLedger: DataLedger,
        redactor: Redactor = Redactor()
    ) {
        self.store = store
        self.aiService = aiService
        self.promptLoader = promptLoader
        self.dataLedger = dataLedger
        self.redactor = redactor
    }

    struct SynthesizedSummary: Sendable {
        let top3: [SummaryItem]
        let risk: SummaryItem?
        let missed: SummaryItem?
    }

    /// Returns an empty summary on AI failure or empty input — never throws,
    /// since RetrospectiveJob still wants to finalize the run.
    func synthesize(runID: Int) async -> SynthesizedSummary {
        let highlights = store.highlights(for: runID)
        let todos = store.todos(for: runID, statuses: [.pending])
        if highlights.isEmpty && todos.isEmpty {
            return SynthesizedSummary(top3: [], risk: nil, missed: nil)
        }

        let aggregated = SummarySynthesizer.aggregateJSON(highlights: highlights, todos: todos)

        // The ledger below records `redacted: true`, so the payload has to
        // actually be redacted. It was not: highlight summaries, involved
        // names, chat names and quoted snippets went to the model verbatim
        // while the ledger claimed otherwise (a real name and group name leak,
        // and an untrue audit number). Register every name the payload mentions
        // so the redactor can substitute codenames, then mask the JSON itself.
        for highlight in highlights {
            for name in highlight.involved {
                _ = await redactor.codenameFor(username: name, displayName: name)
            }
            let chatName = highlight.sourceChatName
            if !chatName.isEmpty {
                _ = await redactor.codenameFor(username: chatName, displayName: chatName)
            }
        }
        for todo in todos {
            for name in todo.involved {
                _ = await redactor.codenameFor(username: name, displayName: name)
            }
            let chatName = todo.sourceChatName
            if !chatName.isEmpty {
                _ = await redactor.codenameFor(username: chatName, displayName: chatName)
            }
        }
        let redactedAggregate = await redactor.redactText(aggregated)

        let template: String
        do {
            template = try promptLoader.load(version: "retrospective_summary_synth_v1")
        } catch {
            print("[Retrospective] SummarySynthesizer prompt load failed: \(error)")
            return SummarySynthesizer.fallbackSummary(highlights: highlights)
        }
        let userPrompt = template.replacingOccurrences(of: "{aggregated_json}", with: redactedAggregate)

        let result: AICompletionResult
        do {
            result = try await aiService.completeWithMetadata(
                system: "你严格按 JSON Schema 输出。",
                user: userPrompt,
                options: CompleteOptions(timeout: 60, temperature: 0.3, maxTokens: 1024, responseFormatJSON: true)
            )
        } catch {
            print("[Retrospective] SummarySynthesizer AI call failed: \(error)")
            return SummarySynthesizer.fallbackSummary(highlights: highlights)
        }

        // Ledger
        await dataLedger.recordBatch([AILedgerEntry(
            id: 0, ts: Date(),
            provider: result.providerID,
            model: result.model,
            purpose: .summarySynth,
            chatCount: nil, msgCount: highlights.count + todos.count,
            byteCount: userPrompt.utf8.count,
            tokenIn: nil, tokenOut: nil, redacted: true
        )])

        guard let parsed = SummarySynthesizer.parse(result.text) else {
            return SummarySynthesizer.fallbackSummary(highlights: highlights)
        }
        return await restoreNames(in: parsed)
    }

    /// Codenames back to real names, so the stored summary reads naturally.
    private func restoreNames(in summary: SynthesizedSummary) async -> SynthesizedSummary {
        func restore(_ item: SummaryItem) async -> SummaryItem {
            SummaryItem(
                text: await redactor.unredactText(item.text),
                evidenceHighlightIDs: item.evidenceHighlightIDs
            )
        }
        var top3: [SummaryItem] = []
        for item in summary.top3 {
            top3.append(await restore(item))
        }
        let risk: SummaryItem?
        if let item = summary.risk {
            risk = await restore(item)
        } else {
            risk = nil
        }
        let missed: SummaryItem?
        if let item = summary.missed {
            missed = await restore(item)
        } else {
            missed = nil
        }
        return SynthesizedSummary(top3: top3, risk: risk, missed: missed)
    }

    // MARK: - Aggregation + parsing

    static func aggregateJSON(highlights: [ReviewHighlight], todos: [ReviewTodo]) -> String {
        let h: [[String: Any]] = highlights.map { h in
            [
                "id": h.id,
                "summary": h.summary,
                "category": h.category.rawValue,
                "confidence": h.confidence,
                "involved": h.involved,
                "chat_name": h.sourceChatName
            ]
        }
        let t: [[String: Any]] = todos.map { t in
            var o: [String: Any] = [
                "content": t.content,
                "direction": t.direction.rawValue,
                "confidence": t.confidence,
                "involved": t.involved,
                "chat_name": t.sourceChatName
            ]
            if let d = t.deadline {
                o["deadline"] = Int(d.timeIntervalSince1970)
            }
            return o
        }
        let blob: [String: Any] = ["highlights": h, "todos": t]
        guard let data = try? JSONSerialization.data(withJSONObject: blob),
              let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }

    static func parse(_ raw: String) -> SynthesizedSummary? {
        guard let cleaned = AIJSONExtractor.firstObjectString(from: raw),
              let data = cleaned.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let top3 = SummarySynthesizer.parseSummaryArray(obj["top3"]) ?? []
        let risk = SummarySynthesizer.parseSummaryItem(obj["risk"])
        let missed = SummarySynthesizer.parseSummaryItem(obj["missed"])
        return SynthesizedSummary(top3: top3, risk: risk, missed: missed)
    }

    private static func parseSummaryArray(_ x: Any?) -> [SummaryItem]? {
        guard let arr = x as? [[String: Any]] else { return nil }
        return arr.compactMap { parseSummaryDict($0) }
    }

    private static func parseSummaryItem(_ x: Any?) -> SummaryItem? {
        guard let obj = x as? [String: Any] else { return nil }
        return parseSummaryDict(obj)
    }

    private static func parseSummaryDict(_ d: [String: Any]) -> SummaryItem? {
        guard let text = d["text"] as? String, !text.isEmpty else { return nil }
        // AI may return ids as Int or as String — accept both.
        let raw = d["evidence_highlight_ids"]
        let ids: [Int]
        if let intArr = raw as? [Int] {
            ids = intArr
        } else if let strArr = raw as? [String] {
            ids = strArr.compactMap(Int.init)
        } else {
            ids = []
        }
        return SummaryItem(text: text, evidenceHighlightIDs: ids)
    }

    /// Cheap fallback when AI returns nothing usable: take top-3 highlights
    /// by confidence and surface them as the summary.
    static func fallbackSummary(highlights: [ReviewHighlight]) -> SynthesizedSummary {
        let top = highlights.sorted { $0.confidence > $1.confidence }.prefix(3)
        let items = top.map { SummaryItem(text: $0.summary, evidenceHighlightIDs: [$0.id]) }
        return SynthesizedSummary(top3: Array(items), risk: nil, missed: nil)
    }
}
