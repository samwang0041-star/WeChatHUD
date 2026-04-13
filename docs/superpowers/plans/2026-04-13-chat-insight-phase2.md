# ChatInsight Phase 2: AI Service Layer

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the AI service layer — prompt templates, AIChatInsight actor that calls AI for per-chat analysis and global briefing, caching via analysis_cache, and integration into ChatMonitor.

**Architecture:** Follow existing `AIGroupCatchup` / `AIDailyRetrospector` actor pattern. Two prompt files, one actor with three public methods. ChatMonitor gets a new `@Published` property and lazy-loaded service.

**Tech Stack:** Swift, Foundation, existing AIService/PromptLoader/HUDStore infrastructure.

**Spec:** `docs/superpowers/specs/2026-04-13-chat-insight-design.md`

---

## File Structure

| Action | File | Responsibility |
|--------|------|---------------|
| Create | `Sources/WeChatHUD/Resources/prompts/chat_insight_v1.txt` | Per-chat analysis prompt |
| Create | `Sources/WeChatHUD/Resources/prompts/chat_insight_global_v1.txt` | Global briefing prompt |
| Create | `Sources/WeChatHUD/Services/AIChatInsight.swift` | AI actor: analyze single chat, generate global briefing, keyword search |
| Modify | `Sources/WeChatHUD/Services/ChatMonitor.swift` | Add @Published insightResults, lazy service init, loadInsight method |

---

### Task 1: Prompt templates

**Files:**
- Create: `Sources/WeChatHUD/Resources/prompts/chat_insight_v1.txt`
- Create: `Sources/WeChatHUD/Resources/prompts/chat_insight_global_v1.txt`

- [ ] **Step 1: Create chat_insight_v1.txt**

```
你是一个高级聊天分析师。你的任务不是总结聊天内容，而是分析文字背后的隐性信号 — 态度、情绪、关系动态。

输出必须是单个 JSON 对象，不要 markdown 代码块，不要任何其它文字。

JSON schema:
{
  "headline": "一句话概括",
  "topics": [{"name":"具体话题名(2-4字)","message_count":0,"participant_count":0,"summary":"讨论摘要","status":"已决/讨论中/搁置/信息同步","my_involvement":"我的参与,null如果没参与","attitudes":{"人名":"态度"},"cross_chats":["也在讨论的群"]}],
  "decisions": ["明确的决策"],
  "action_items": [{"what":"事项","who":"责任人","deadline":"如有,null如果没有"}],
  "mentions_me": 0,
  "waiting_for_me": [{"source":"谁在等","what":"等什么","waiting_hours":0}],
  "my_commitments": ["我承诺了什么"],
  "needs_my_attention": true,
  "overall_mood": "焦虑/轻松/正式/紧张/正常",
  "mood_shift": {"from":"之前","to":"之后","trigger":"触发事件","time":"大约时间"},
  "attitudes": [{"person":"人名","topic":"话题","attitude":"积极推进/表面配合/敷衍/隐性反对/显性反对/回避","evidence":"依据措辞"}],
  "tone_changes": [{"person":"人名","change":"变化描述","interpretation":"解读"}],
  "signal_noise_ratio": 0.7,
  "decision_efficiency": "快/正常/慢",
  "importance_to_me": {"level":"高/中/低","reason":"原因"},
  "participants": [{"name":"人名","message_count":0,"role":"推动者/决策者/执行者/反对者/旁观者","doing":"在做什么","attitude_toward":{"话题":"态度"}}],
  "relationship_signal": "升温/平稳/降温",
  "symmetry": 0.8,
  "insight": "非显而易见的洞察",
  "suggestion": "具体行动建议"
}

分析要求:
1. 态度分析是核心。不看说了什么，看怎么说的。"好的我看看"=表面配合，"收到"=敷衍，提出具体问题=真正关心，沉默=可能反对。
2. 情绪转折要具体到时间和触发事件。
3. 话题名必须具体，"工作讨论"太模糊，"Q2排期调整"才有用。
4. 洞察必须基于数据推导，不是常识。建议必须具体到人+行动。
5. 群聊必须填 participants，私聊填 relationship_signal 和 symmetry。
6. mood_shift 如果没有情绪变化则设为 null。
7. 所有态度判断必须附带 evidence（具体措辞）。

输入:
聊天: {chat_name} ({chat_type})
分类: {category}
我是: {self_name}
时间: {time_range}
撤回消息: {recalled_messages}
历史记忆: {memory}

消息:
{messages}

只输出 JSON，不要任何其它文字。
```

- [ ] **Step 2: Create chat_insight_global_v1.txt**

```
你是一个通信态势分析师。基于所有聊天的分析结果，生成全局简报。

输出必须是单个 JSON 对象，不要 markdown 代码块。

JSON schema:
{
  "date": "日期",
  "action_required": [{"source":"来源","what":"等你做什么","waiting_hours":0,"urgency":"高/中/低"}],
  "headline": "2-3句全局概括,必须具体",
  "stats": {"total_messages":0,"my_messages":0,"active_groups":0,"total_groups":0,"active_private_chats":0,"work_ratio":0.7},
  "cross_topics": [{"name":"话题名","chats":["涉及的群"],"summary":"综合摘要","conflict":"信息冲突点,null如果没有","status":"状态"}],
  "dark_signals": {"tone_changes":[{"person":"","change":"","interpretation":""}],"silences":[{"name":"","usual_daily_messages":0,"today_messages":0,"active_elsewhere":false,"interpretation":""}],"recalls":[{"person":"","original_content":"","context":"","replacement":"","interpretation":""}],"ignored":[{"person":"","content":"","usual_response_rate":"","interpretation":""}],"headline":"暗信号总结"},
  "overall_mood": "今天整体沟通氛围",
  "blind_spots": ["盲区提醒"],
  "top_suggestion": "今天最重要的一件事"
}

要求:
1. headline 必须具体。不要"今天比较忙"，要"今天72%的沟通集中在Q2排期，你有3个人在等你回复"。
2. 跨群话题用语义匹配，"排期"和"timeline"和"什么时候上线"是同一件事。
3. 暗信号从各聊天分析中收集语气变化、沉默、撤回、忽略，生成总结。
4. 盲区：VIP没互动的人、工作群你没参与的重要讨论、承诺未兑现。
5. top_suggestion 综合所有信息给出今天最应做的一件事。

输入:
我是: {self_name}
日期: {date}
全局统计: {global_stats}

各聊天分析结果:
{chat_insights}

只输出 JSON，不要任何其它文字。
```

- [ ] **Step 3: Verify build (prompts are bundled as resources)**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded.

- [ ] **Step 4: Commit**

```bash
git add Sources/WeChatHUD/Resources/prompts/chat_insight_v1.txt Sources/WeChatHUD/Resources/prompts/chat_insight_global_v1.txt
git commit -m "feat(insight): add AI prompt templates for chat insight"
```

---

### Task 2: AIChatInsight actor

**Files:**
- Create: `Sources/WeChatHUD/Services/AIChatInsight.swift`

- [ ] **Step 1: Create AIChatInsight.swift**

Follow the exact pattern from AIGroupCatchup — actor with store, config, promptLoader.

```swift
import Foundation

/// AI-powered chat insight analysis.
/// Analyzes individual chats and generates global briefings.
actor AIChatInsight {
    private let store: HUDStore
    private var config: AIConfig
    private let promptLoader: PromptLoader

    init(
        store: HUDStore,
        config: AIConfig,
        promptLoader: PromptLoader = PromptLoader()
    ) {
        self.store = store
        var inflated = config
        inflated.maxTokens = 2048  // insight output is larger
        inflated.temperature = 0.2
        self.config = inflated
        self.promptLoader = promptLoader
    }

    // MARK: - Single chat analysis

    /// Analyze a single chat's messages and return structured insight.
    func analyzeChat(
        chatUsername: String,
        chatName: String,
        chatType: String,  // "group" or "private"
        category: String,  // "work", "life", "other"
        selfName: String,
        timeRange: String,
        messages: [(sender: String, body: String, time: Int)],
        recalledMessages: [(sender: String, content: String)],
        memory: String
    ) async -> ChatInsightResult? {
        // Check cache first
        let inputHash = md5("\(chatUsername)_\(timeRange)_\(messages.count)")
        if let cached = store.readAnalysisCache(
            chatUsername: chatUsername,
            analysisType: "chat_insight_v1",
            inputHash: inputHash
        ) {
            return parseInsight(cached)
        }

        // Load and fill prompt template
        guard let template = try? promptLoader.load(version: "chat_insight_v1") else {
            print("[ChatInsight] Failed to load prompt template")
            return nil
        }

        let formattedMessages = messages.map { "[\($0.sender)] \($0.body)" }.joined(separator: "\n")
        let formattedRecalled = recalledMessages.isEmpty
            ? "无"
            : recalledMessages.map { "[\($0.sender)] \($0.content)" }.joined(separator: "\n")

        let prompt = template
            .replacingOccurrences(of: "{chat_name}", with: chatName)
            .replacingOccurrences(of: "{chat_type}", with: chatType)
            .replacingOccurrences(of: "{category}", with: category)
            .replacingOccurrences(of: "{self_name}", with: selfName)
            .replacingOccurrences(of: "{time_range}", with: timeRange)
            .replacingOccurrences(of: "{messages}", with: formattedMessages)
            .replacingOccurrences(of: "{recalled_messages}", with: formattedRecalled)
            .replacingOccurrences(of: "{memory}", with: memory.isEmpty ? "无" : memory)

        // Call AI
        guard let response = await call(prompt) else { return nil }

        // Parse
        guard let result = parseInsight(response) else {
            // Retry with strict instruction
            let retry = prompt + "\n\n严格要求：上一次输出无法解析为 JSON。只输出符合 schema 的 JSON 对象。"
            guard let retryResponse = await call(retry),
                  let retryResult = parseInsight(retryResponse) else {
                return nil
            }
            // Cache and return
            store.writeAnalysisCache(
                chatUsername: chatUsername,
                analysisType: "chat_insight_v1",
                inputHash: inputHash,
                result: retryResponse,
                ttlHours: 2
            )
            return retryResult
        }

        // Cache and return
        store.writeAnalysisCache(
            chatUsername: chatUsername,
            analysisType: "chat_insight_v1",
            inputHash: inputHash,
            result: response,
            ttlHours: 2
        )

        // Audit
        store.writeAIAudit(entry: AIAuditEntry(
            model: config.model,
            feature: "chat_insight",
            chatUsername: chatUsername,
            inputTokens: prompt.count / 4,
            outputTokens: response.count / 4,
            latencyMs: 0,
            success: true,
            errorMessage: nil
        ))

        return result
    }

    // MARK: - Global briefing

    /// Generate a global briefing from all per-chat insights.
    func generateGlobalBriefing(
        selfName: String,
        date: String,
        chatInsights: [(chatName: String, result: ChatInsightResult)],
        globalStats: BriefingStats
    ) async -> GlobalBriefing? {
        guard let template = try? promptLoader.load(version: "chat_insight_global_v1") else {
            return nil
        }

        // Serialize chat insights to JSON
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let insightsJSON: String
        do {
            let data = try encoder.encode(chatInsights.map { $0.result })
            insightsJSON = String(data: data, encoding: .utf8) ?? "[]"
        } catch {
            insightsJSON = "[]"
        }

        let statsJSON: String
        do {
            let data = try encoder.encode(globalStats)
            statsJSON = String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            statsJSON = "{}"
        }

        let prompt = template
            .replacingOccurrences(of: "{self_name}", with: selfName)
            .replacingOccurrences(of: "{date}", with: date)
            .replacingOccurrences(of: "{chat_insights}", with: insightsJSON)
            .replacingOccurrences(of: "{global_stats}", with: statsJSON)

        guard let response = await call(prompt) else { return nil }
        return parseGlobalBriefing(response)
    }

    // MARK: - HTTP call (same pattern as AIGroupCatchup)

    private func call(_ userPrompt: String) async -> String? {
        guard !config.baseURL.isEmpty, !config.apiKey.isEmpty else { return nil }
        let url = URL(string: "\(config.baseURL)/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60

        let body: [String: Any] = [
            "model": config.model,
            "max_tokens": config.maxTokens,
            "temperature": config.temperature,
            "messages": [
                ["role": "user", "content": userPrompt]
            ]
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, resp) = try await URLSession.shared.data(for: request)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                return nil
            }
            // Strip thinking tags if present
            let cleaned = content.replacingOccurrences(
                of: "<thinking>[\\s\\S]*?</thinking>",
                with: "",
                options: .regularExpression
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned
        } catch {
            print("[ChatInsight] API error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - JSON parsing

    private func parseInsight(_ raw: String) -> ChatInsightResult? {
        guard let jsonStr = extractJSON(raw),
              let data = jsonStr.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ChatInsightResult.self, from: data)
    }

    private func parseGlobalBriefing(_ raw: String) -> GlobalBriefing? {
        guard let jsonStr = extractJSON(raw),
              let data = jsonStr.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GlobalBriefing.self, from: data)
    }

    /// Extract JSON object from raw AI response (handles markdown fences, leading text).
    private func extractJSON(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip markdown fences
        s = s.replacingOccurrences(of: "```json", with: "")
        s = s.replacingOccurrences(of: "```", with: "")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Find JSON boundaries
        guard let start = s.firstIndex(of: "{") else { return nil }
        guard let end = s.lastIndex(of: "}") else { return nil }
        return String(s[start...end])
    }

    private func md5(_ input: String) -> String {
        let data = Data(input.utf8)
        var hash = [UInt8](repeating: 0, count: 16)
        data.withUnsafeBytes { ptr in
            _ = CC_MD5(ptr.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
```

NOTE: The `md5` function uses CommonCrypto. Check if the project already imports it. If not, use a simpler hash. Look at `WeChatReader.swift` which has an `md5Hex` function — you may need to use the same approach or just use `String(hashValue)` as the input hash instead of MD5.

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | tail -10`

If CC_MD5 is not available, replace the `md5` function with:
```swift
    private func md5(_ input: String) -> String {
        // Simple hash — doesn't need to be cryptographic for cache keys
        String(input.hashValue)
    }
```

Expected: Build succeeded.

- [ ] **Step 3: Commit**

```bash
git add Sources/WeChatHUD/Services/AIChatInsight.swift
git commit -m "feat(insight): add AIChatInsight AI service actor"
```

---

### Task 3: Integrate into ChatMonitor

**Files:**
- Modify: `Sources/WeChatHUD/Services/ChatMonitor.swift`

- [ ] **Step 1: Add published properties**

Find the section with other `@Published` properties (around line 26-70) and add:

```swift
@Published var chatInsights: [String: ChatInsightResult] = [:]  // chatUsername → result
@Published var globalBriefing: GlobalBriefing? = nil
@Published var insightLoading: Bool = false
```

- [ ] **Step 2: Add lazy service initialization**

Find where other services are lazy-initialized (around line 108-110, near `dailyRetrospector`) and add:

```swift
private lazy var chatInsight: AIChatInsight = {
    AIChatInsight(store: store, config: store.loadAIConfig())
}()
```

- [ ] **Step 3: Add loadInsight method**

Add a new public method (after `loadDailyReport`):

```swift
/// Load chat insight analysis for all whitelisted chats.
func loadInsight(force: Bool = false) async {
    // Skip if already loading or recently loaded (within 30 min)
    guard !insightLoading else { return }
    if !force, let briefing = globalBriefing {
        let age = Date().timeIntervalSince(
            ISO8601DateFormatter().date(from: briefing.date) ?? .distantPast
        )
        if age < 1800 { return }
    }

    await MainActor.run { insightLoading = true }

    let whitelist = store.loadWhitelist()
    let selfName = reader.myUsername()
    let selfDisplayName = reader.displayName(for: selfName)
    let dateStr = ISO8601DateFormatter().string(from: Date())
    let timeRange = "今天"

    var results: [String: ChatInsightResult] = [:]
    var statsResults: [ChatStatsData] = []

    // Analyze each whitelisted chat
    for entry in whitelist {
        let messages: [MessageInfo]
        do {
            messages = try reader.getMessages(chatUsername: entry.id, limit: 200)
        } catch { continue }

        // Filter to today's messages
        let todayStart = Calendar.current.startOfDay(for: Date())
        let todayMessages = messages.filter {
            Date(timeIntervalSince1970: Double($0.createTime)) >= todayStart
        }
        guard !todayMessages.isEmpty else { continue }

        // Pure stats
        let stats = ChatInsightEngine.computeStats(
            messages: todayMessages,
            selfUsername: selfName,
            chatUsername: entry.id,
            chatName: entry.displayName,
            isGroup: entry.isGroup,
            category: entry.category
        )
        statsResults.append(stats)

        // Format messages for AI
        let formatted = todayMessages
            .sorted { $0.createTime < $1.createTime }
            .map { (sender: $0.senderName, body: $0.text, time: $0.createTime) }

        // Get recalled messages for this chat
        let recalled = recalledMessages
            .filter { $0.chatUsername == entry.id }
            .map { (sender: $0.senderName, content: $0.originalText) }

        // Get conversation memory
        let memory = store.getConversationMemory(chatUsername: entry.id)
        let memoryStr = memory?.formatForPrompt() ?? ""

        // AI analysis
        if let result = await chatInsight.analyzeChat(
            chatUsername: entry.id,
            chatName: entry.displayName,
            chatType: entry.isGroup ? "group" : "private",
            category: entry.category.rawValue,
            selfName: selfDisplayName,
            timeRange: timeRange,
            messages: formatted,
            recalledMessages: recalled,
            memory: memoryStr
        ) {
            results[entry.id] = result
        }
    }

    // Global briefing
    let totalMessages = statsResults.reduce(0) { $0 + $1.messageCount }
    let myMessages = statsResults.reduce(0) { $0 + $1.myMessageCount }
    let activeGroups = statsResults.filter { $0.isGroup }.count
    let totalGroups = whitelist.filter { $0.isGroup }.count
    let activePrivate = statsResults.filter { !$0.isGroup }.count
    let workMessages = statsResults.filter { $0.category == .work }.reduce(0) { $0 + $1.messageCount }
    let workRatio = totalMessages > 0 ? Double(workMessages) / Double(totalMessages) : 0

    let globalStats = BriefingStats(
        totalMessages: totalMessages,
        myMessages: myMessages,
        activeGroups: activeGroups,
        totalGroups: totalGroups,
        activePrivateChats: activePrivate,
        workRatio: workRatio
    )

    let insightPairs = results.compactMap { (key, value) -> (chatName: String, result: ChatInsightResult)? in
        guard let entry = whitelist.first(where: { $0.id == key }) else { return nil }
        return (chatName: entry.displayName, result: value)
    }

    let briefing = await chatInsight.generateGlobalBriefing(
        selfName: selfDisplayName,
        date: dateStr,
        chatInsights: insightPairs,
        globalStats: globalStats
    )

    await MainActor.run {
        self.chatInsights = results
        self.globalBriefing = briefing
        self.insightLoading = false
    }
}
```

- [ ] **Step 4: Verify build**

Run: `swift build 2>&1 | tail -10`
Fix any compilation errors (likely around `store.getConversationMemory` — check if method exists, adjust accordingly).

- [ ] **Step 5: Run tests for regressions**

Run: `swift test 2>&1 | grep -E "passed|failed" | tail -5`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/WeChatHUD/Services/ChatMonitor.swift
git commit -m "feat(insight): integrate AIChatInsight into ChatMonitor"
```
