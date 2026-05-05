# Context Transition — 方案修正

## 修正目标
解决 Evaluator 提出的 3 个阻塞问题：
1. 移除对 WeChatReader.swift 的不必要修改
2. 解决 actor 隔离问题
3. 收紧 token 预算

## 修正 1：移除 WeChatReader 改动

**原方案**：在 WeChatReader.swift 新增 `todayMessagesByChat` 批量查询。

**修正**：DailyChatScanner 直接使用现有 `WeChatReader.getMessages(chatUsername:limit:)` 方法。Scanner 内部通过 `topActiveContacts` 获取联系人列表，然后对每个 contact 调用 `getMessages` 并过滤 `createTime >= startOfDay`。

```swift
// DailyChatScanner.scanToday 内部实现（修正后）
func scanToday(maxChats: Int = 8) -> [ScannedChat] {
    let startOfDay = Calendar.current.startOfDay(for: Date())
    let startTs = Int(startOfDay.timeIntervalSince1970)
    
    guard let contacts = try? reader.topActiveContacts(limit: 50) else { return [] }
    
    var scored: [(contact: ActiveContact, score: Double)] = []
    for contact in contacts {
        guard let messages = try? reader.getMessages(chatUsername: contact.username, limit: 200) else { continue }
        let todayMessages = messages.filter { $0.createTime >= startTs }
        guard !todayMessages.isEmpty else { continue }
        
        let outboundCount = todayMessages.filter { $0.senderUsername == myUsername }.count
        let atCount = todayMessages.filter { $0.isAtMention }.count
        let score = computePriorityScore(
            messageCount: todayMessages.count,
            outboundCount: outboundCount,
            atCount: atCount,
            isGroup: contact.isGroup,
            relation: store.getWhitelistEntry(username: contact.username)?.relation ?? .unknown,
            lastMessageTime: Date(timeIntervalSince1970: TimeInterval(todayMessages.first?.createTime ?? 0))
        )
        scored.append((contact, score))
    }
    
    return scored
        .sorted { $0.score > $1.score }
        .prefix(maxChats)
        .map { /* build ScannedChat */ }
}
```

**影响**：文件改动清单中移除 `Data/WeChatReader.swift`，新增文件数从 8 降到 7。

## 修正 2：解决 actor 隔离

**原方案**：`DailyReportBuilder` 是 `struct`，内部创建多个 actor 并 `await` 调用。

**修正**：将 DailyReportBuilder 的逻辑合并到 ChatMonitor 中。ChatMonitor 已经是 @MainActor，可以协调多个 actor 的调用。DailyReportBuilder 降级为纯数据格式化工具（或完全移除）。

```swift
// ChatMonitor.loadDailyReport（修正后）
func loadDailyReport(force: Bool = false) async {
    // 缓存检查 ...
    
    do {
        // 1. 扫描活跃对话
        let scanner = DailyChatScanner(reader: reader, store: store, myUsername: reader.myUsername())
        let scannedChats = await scanner.scanToday(maxChats: UserDefaults.standard.integer(forKey: "dailyReport.maxScannedChats") > 0 ? UserDefaults.standard.integer(forKey: "dailyReport.maxScannedChats") : 8)
        
        // 2. 生成消息摘要（并发）
        let digester = DailyMessageDigest(reader: reader, myUsername: reader.myUsername())
        let chatDigests = try await withThrowingTaskGroup(of: DailyMessageDigest.ChatDigest.self) { group in
            for chat in scannedChats {
                group.addTask { await digester.digest(chat: chat, maxMessages: 10) }
            }
            var results: [DailyMessageDigest.ChatDigest] = []
            for try await digest in group {
                results.append(digest)
            }
            return results
        }
        
        // 3. 获取现有数据
        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        // ... asks, commitments, replyDebt ...
        
        // 4. 构建 ReportInput
        let reportInput = UnifiedDailyReportGenerator.ReportInput(...)
        
        // 5. AI 生成
        let generator = UnifiedDailyReportGenerator(aiService: aiService)
        let aiOutput = await generator.generateWithRetry(reportInput)
        
        // 6. 构建 DailyReport
        let report = buildDailyReport(from: aiOutput, digests: chatDigests, ...)
        dailyReport = report
        dailyReportGeneratedAt = Date()
        dailyReportCache.save(report: report, generatedAt: Date())
        
    } catch {
        dailyReportError = error.localizedDescription
        // fallback ...
    }
}
```

**影响**：移除 `DailyReportBuilder.swift` 的重构，改为在 ChatMonitor 中直接协调。DailyReportBuilder 可以保留（作为 legacy fallback），但不参与新流程。

## 修正 3：收紧 token 预算

**原方案**：8 对话 × 20 消息 = 160 条消息，预估 5000 tokens。

**修正**：
- 每对话消息上限：**10 条**（而非 20）
- 扫描对话上限：**8 个**
- 总消息硬上限：**60 条**（如果 8×10=80 超过 60，按优先级截断低分对话的消息数）
- 每条消息文本截断：**60 字符**（而非 80）

**重新估算：**

| 环节 | Token 估算 | 说明 |
|------|-----------|------|
| Prompt 头部 | ~500 | 固定 |
| 今日统计 | ~200 | 固定 |
| 对话摘要 | ~3000 | 8 对话 × 10 消息 × ~35 tokens/消息（60 字中文 ≈ 35 tokens） |
| 待办与承诺 | ~600 | 约 15 条 |
| 风险 | ~200 | 约 3 条 |
| **总输入** | **~4500** | **< 5000，留有 3000 余量** |

**动态截断策略：**

```swift
func buildPrompt(input: ReportInput) -> String {
    let maxTotalMessages = 60
    var digests = input.chatDigests
    
    // 1. 截断每条消息长度
    digests = digests.map { digest in
        var d = digest
        d.selectedMessages = digest.selectedMessages.map { msg in
            var m = msg
            m.text = String(msg.text.prefix(60))
            return m
        }
        return d
    }
    
    // 2. 如果总消息数超过上限，从低分对话开始减少消息数
    var totalMessages = digests.reduce(0) { $0 + $1.selectedMessages.count }
    while totalMessages > maxTotalMessages {
        // 从最后一个对话（最低分）开始，每次减少 2 条
        for i in (0..<digests.count).reversed() {
            if digests[i].selectedMessages.count > 3 {
                digests[i].selectedMessages.removeLast(2)
                totalMessages -= 2
                break
            }
        }
    }
    
    // 3. 构建 prompt
    return formatPrompt(digests: digests, ...)
}
```

## 修正后的文件改动清单

### 新增文件（7 个）
1. `Sources/WeChatHUD/Services/DailyChatScanner.swift`
2. `Sources/WeChatHUD/Services/DailyMessageDigest.swift`
3. `Sources/WeChatHUD/Services/UnifiedDailyReportGenerator.swift`
4. `Sources/WeChatHUD/Services/DailyReportCache.swift`
5. `Sources/WeChatHUD/Services/DailyReportWarmer.swift`
6. `Sources/WeChatHUD/Views/DailyReportSettingsView.swift`
7. `Sources/WeChatHUD/Resources/prompts/daily_report_v2.txt`

### 修改文件（4 个）
1. `Sources/WeChatHUD/Services/ChatMonitor.swift` — 接入 Scanner + Digest + Generator + 缓存 + 预热
2. `Sources/WeChatHUD/Views/DailyReportTabView.swift` — 增强展示
3. `Sources/WeChatHUD/App/SettingsWindow.swift` — 集成配置面板
4. `Sources/WeChatHUD/App/AppDelegate.swift` — 启动自动预热

### 移除（不修改）
- ~~`Data/WeChatReader.swift`~~ — 复用现有方法，不修改
- ~~`Services/DailyReportBuilder.swift`~~ — 不在原文件中重构，逻辑移到 ChatMonitor
