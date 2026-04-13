# Contacts Tab Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign the contacts settings page with sub-tabs (通讯录 / AI 扫描 / 屏蔽规则), persist scan dismissals, and replace per-contact AI calls with a single batch request.

**Architecture:** ContactsSettingsView gains an internal segmented picker that routes to three sub-views. HUDStore gets a `scan_dismissed` table for persistence. AIWhitelistCategorizer gets a `categorizeBatch()` method that sends all candidates in one API call. WhitelistScanView is rewritten to use batch results and manage dismissed contacts.

**Tech Stack:** SwiftUI, SQLite3 (raw), OpenAI-compatible chat completions API

---

### Task 1: Add `scan_dismissed` table and CRUD to HUDStore

**Files:**
- Modify: `Sources/WeChatHUD/Data/HUDStore.swift:50-170` (createTables)
- Modify: `Sources/WeChatHUD/Data/Models.swift` (add ScanDismissedEntry)
- Test: `Tests/WeChatHUDTests/HUDStoreTests.swift`

- [ ] **Step 1: Add ScanDismissedEntry model**

In `Sources/WeChatHUD/Data/Models.swift`, add after the existing `IgnoredSenderRule` struct:

```swift
struct ScanDismissedEntry: Identifiable {
    var id: String { username }
    let username: String
    let displayName: String
    let dismissedAt: Date
}
```

- [ ] **Step 2: Add table creation in HUDStore.createTables()**

In `Sources/WeChatHUD/Data/HUDStore.swift`, add after the `ignored_senders` index creation (line ~147):

```swift
try exec("""
    CREATE TABLE IF NOT EXISTS scan_dismissed (
        username     TEXT PRIMARY KEY,
        display_name TEXT NOT NULL DEFAULT '',
        dismissed_at INTEGER NOT NULL
    )
""")
```

- [ ] **Step 3: Add CRUD methods to HUDStore**

Add after the `ignoreSender` / `loadIgnoredSenders` group (~line 700):

```swift
// MARK: - Scan Dismissed

func dismissScanResult(username: String, displayName: String) throws {
    let now = Int(Date().timeIntervalSince1970)
    try exec("""
        INSERT OR REPLACE INTO scan_dismissed(username, display_name, dismissed_at)
        VALUES(?,?,?)
    """, params: [username, displayName, "\(now)"])
}

func undismissScanResult(username: String) throws {
    try exec("DELETE FROM scan_dismissed WHERE username=?", params: [username])
}

func loadDismissedScanResults() -> [ScanDismissedEntry] {
    var results: [ScanDismissedEntry] = []
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, """
        SELECT username, display_name, dismissed_at
        FROM scan_dismissed ORDER BY dismissed_at DESC
    """, -1, &stmt, nil) == SQLITE_OK else { return results }
    while sqlite3_step(stmt) == SQLITE_ROW {
        results.append(ScanDismissedEntry(
            username: String(cString: sqlite3_column_text(stmt, 0)),
            displayName: String(cString: sqlite3_column_text(stmt, 1)),
            dismissedAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 2)))
        ))
    }
    return results
}

func dismissedScanUsernames() -> Set<String> {
    var result = Set<String>()
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, "SELECT username FROM scan_dismissed", -1, &stmt, nil) == SQLITE_OK else { return result }
    while sqlite3_step(stmt) == SQLITE_ROW {
        result.insert(String(cString: sqlite3_column_text(stmt, 0)))
    }
    return result
}
```

- [ ] **Step 4: Write tests**

In `Tests/WeChatHUDTests/HUDStoreTests.swift`, add:

```swift
func testScanDismissedRoundTrip() throws {
    try store.dismissScanResult(username: "alice", displayName: "Alice")
    try store.dismissScanResult(username: "bob", displayName: "Bob")

    let all = store.loadDismissedScanResults()
    XCTAssertEqual(all.count, 2)
    XCTAssertEqual(all[0].username, "bob")  // most recent first

    let set = store.dismissedScanUsernames()
    XCTAssertTrue(set.contains("alice"))
    XCTAssertTrue(set.contains("bob"))

    try store.undismissScanResult(username: "alice")
    XCTAssertEqual(store.loadDismissedScanResults().count, 1)
    XCTAssertFalse(store.dismissedScanUsernames().contains("alice"))
}

func testScanDismissedUpsert() throws {
    try store.dismissScanResult(username: "alice", displayName: "Alice")
    try store.dismissScanResult(username: "alice", displayName: "Alice Updated")
    let all = store.loadDismissedScanResults()
    XCTAssertEqual(all.count, 1)
    XCTAssertEqual(all[0].displayName, "Alice Updated")
}
```

- [ ] **Step 5: Run tests**

Run: `swift test --filter HUDStoreTests 2>&1 | tail -20`
Expected: all tests pass including the two new ones.

- [ ] **Step 6: Commit**

```bash
git add Sources/WeChatHUD/Data/Models.swift Sources/WeChatHUD/Data/HUDStore.swift Tests/WeChatHUDTests/HUDStoreTests.swift
git commit -m "feat(contacts): add scan_dismissed table and CRUD"
```

---

### Task 2: Update scanCandidates to exclude dismissed contacts

**Files:**
- Modify: `Sources/WeChatHUD/Services/ChatMonitor.swift:1301-1313` (scanCandidates)

- [ ] **Step 1: Update scanCandidates**

Replace the existing `scanCandidates` method (added earlier this session) in `ChatMonitor.swift`:

```swift
func scanCandidates(limit: Int = 50) -> [(username: String, displayName: String, isGroup: Bool)] {
    let whitelisted = Set(store.loadContacts(level: nil).map(\.username))
    let dismissed = store.dismissedScanUsernames()
    let excluded = whitelisted.union(dismissed)
    guard let active = try? reader.topActiveContacts(limit: limit + excluded.count) else {
        return []
    }
    return active
        .filter { !excluded.contains($0.username) }
        .prefix(limit)
        .map { (username: $0.username, displayName: $0.displayName, isGroup: $0.isGroup) }
}
```

- [ ] **Step 2: Build to verify**

Run: `swift build 2>&1 | tail -5`
Expected: Build complete

- [ ] **Step 3: Commit**

```bash
git add Sources/WeChatHUD/Services/ChatMonitor.swift
git commit -m "feat(contacts): scanCandidates excludes dismissed contacts"
```

---

### Task 3: Add batch categorize to AIWhitelistCategorizer

**Files:**
- Modify: `Sources/WeChatHUD/Services/AIWhitelistCategorizer.swift`
- Create: `Sources/WeChatHUD/Resources/prompts/whitelist_batch_v1.txt`

- [ ] **Step 1: Create batch prompt template**

Create `Sources/WeChatHUD/Resources/prompts/whitelist_batch_v1.txt`:

```text
你是一个微信联系人批量分类助手。任务：根据每个联系人最近的对话内容，判断他属于 work / life / other，并决定是否应加入白名单。

输出**必须**是 JSON 数组，每个元素对应一个联系人，**不要**包含 markdown 围栏或其它文本。

每个元素的 schema:
{
  "index": 联系人编号（从1开始）,
  "category": "work" | "life" | "other",
  "should_whitelist": true|false,
  "reason": "一句话理由，最多20字"
}

# 类别定义

- **work**: 工作相关 — 同事、上下级、客户、合作伙伴、行业群
- **life**: 生活相关 — 家人、朋友、同学、生活服务
- **other**: 不明确 — 偶尔联系、营销号、通知号

# 规则

1. 优先看话题而不是名字
2. should_whitelist: work 几乎都 true（除营销号），life 中亲密关系 true，other 通常 false
3. 对话太少/模糊 → should_whitelist: false
4. 严格按 index 顺序输出，不要遗漏任何联系人

# 联系人列表

{candidates}

只输出 JSON 数组。
```

- [ ] **Step 2: Add BatchInput and categorizeBatch method**

In `Sources/WeChatHUD/Services/AIWhitelistCategorizer.swift`, add after the existing `categorize` method (~line 108):

```swift
// MARK: - Batch categorization

struct BatchItem {
    let index: Int
    let contactName: String
    let isGroup: Bool
    let recentCount: Int
    let messages: [(sender: String, body: String)]
}

struct BatchResult: Decodable {
    let index: Int
    let category: String
    let shouldWhitelist: Bool
    let reason: String

    enum CodingKeys: String, CodingKey {
        case index, category, reason
        case shouldWhitelist = "should_whitelist"
    }
}

func categorizeBatch(_ items: [BatchItem]) async -> [BatchResult] {
    guard !items.isEmpty else { return [] }

    let template: String
    do {
        template = try promptLoader.load(version: "whitelist_batch_v1")
    } catch {
        print("[WCHUD] AIWhitelistCategorizer: batch prompt load failed: \(error)")
        return []
    }

    // Build candidate text block
    let candidatesText = items.map { item in
        let msgs = item.messages.prefix(5)
            .map { "[\(clean($0.sender))] \(clean($0.body))" }
            .joined(separator: "\n")
        let groupLabel = item.isGroup ? "群聊" : "个人"
        return """
        \(item.index). \(clean(item.contactName)) (\(groupLabel), 近45天\(item.recentCount)条)
        最近消息:
        \(msgs)
        """
    }.joined(separator: "\n---\n")

    let userPrompt = template
        .replacingOccurrences(of: "{candidates}", with: candidatesText)

    let response = await call(userPrompt)
    guard !response.text.isEmpty else { return [] }
    return parseBatch(response.text)
}

private func parseBatch(_ raw: String) -> [BatchResult] {
    var cleaned = raw
    // Strip markdown fences
    if let fenceRange = cleaned.range(of: "```") {
        cleaned = String(cleaned[fenceRange.upperBound...])
        if cleaned.hasPrefix("json") { cleaned = String(cleaned.dropFirst(4)) }
        if let endFence = cleaned.range(of: "```") {
            cleaned = String(cleaned[..<endFence.lowerBound])
        }
    }
    cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    // Find array bounds
    if !cleaned.hasPrefix("[") {
        if let lo = cleaned.firstIndex(of: "["), let hi = cleaned.lastIndex(of: "]") {
            cleaned = String(cleaned[lo...hi])
        }
    }
    guard let data = cleaned.data(using: .utf8) else { return [] }
    return (try? JSONDecoder().decode([BatchResult].self, from: data)) ?? []
}
```

- [ ] **Step 3: Build to verify**

Run: `swift build 2>&1 | tail -5`
Expected: Build complete

- [ ] **Step 4: Commit**

```bash
git add Sources/WeChatHUD/Services/AIWhitelistCategorizer.swift Sources/WeChatHUD/Resources/prompts/whitelist_batch_v1.txt
git commit -m "feat(contacts): batch AI categorization for whitelist scan"
```

---

### Task 4: Rewrite WhitelistScanView with batch scan + dismissed management

**Files:**
- Modify: `Sources/WeChatHUD/Views/WhitelistScanView.swift` (full rewrite)

- [ ] **Step 1: Rewrite WhitelistScanView**

Replace the entire content of `Sources/WeChatHUD/Views/WhitelistScanView.swift`:

```swift
import SwiftUI

/// AI whitelist scan tab: batch-scan active contacts, show grouped results,
/// manage previously dismissed contacts.
struct WhitelistScanView: View {
    @EnvironmentObject private var store: HUDStore
    @EnvironmentObject var monitor: ChatMonitor

    @State private var isScanning = false
    @State private var results: [ScanResultItem] = []
    @State private var dismissed: [ScanDismissedEntry] = []
    @State private var showDismissed = false

    struct ScanResultItem: Identifiable {
        let id: String  // username
        let username: String
        let displayName: String
        let isGroup: Bool
        let recentCount: Int
        let category: String
        let shouldWhitelist: Bool
        let reason: String
        var accepted: Bool = false
    }

    private var pendingResults: [ScanResultItem] {
        results.filter { !$0.accepted && $0.shouldWhitelist }
    }

    private var groupedResults: [(String, [ScanResultItem])] {
        let groups = Dictionary(grouping: pendingResults) { $0.category }
        let order = ["work", "life", "other"]
        return order.compactMap { key in
            guard let items = groups[key], !items.isEmpty else { return nil }
            return (key, items)
        }
    }

    private var categoryLabel: (String) -> String = { cat in
        switch cat {
        case "work": return "工作"
        case "life": return "生活"
        default: return "其他"
        }
    }

    private var categoryColor: (String) -> Color = { cat in
        switch cat {
        case "work": return .blue
        case "life": return .green
        default: return .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Scan controls
            HStack {
                Button(action: startScan) {
                    HStack(spacing: 6) {
                        if isScanning {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "sparkles")
                                .font(.system(size: 12))
                        }
                        Text(isScanning ? "扫描中…" : "开始扫描")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(isScanning)

                Spacer()

                if !pendingResults.isEmpty {
                    Button("全部接受") { acceptAll() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("全部忽略") { dismissAll() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            if !results.isEmpty && pendingResults.isEmpty && !isScanning {
                Label("扫描完成，没有新的建议", systemImage: "checkmark.circle")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            // Grouped results
            ForEach(groupedResults, id: \.0) { category, items in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle().fill(categoryColor(category))
                            .frame(width: 8, height: 8)
                        Text(categoryLabel(category))
                            .font(.system(size: 12, weight: .semibold))
                        Text("(\(items.count))")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }

                    VStack(spacing: 1) {
                        ForEach(items) { item in
                            resultRow(item)
                        }
                    }
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                }
            }

            // Dismissed section
            if !dismissed.isEmpty {
                Divider()

                DisclosureGroup(isExpanded: $showDismissed) {
                    VStack(spacing: 1) {
                        ForEach(dismissed) { entry in
                            dismissedRow(entry)
                        }
                    }
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                } label: {
                    Text("已忽略 (\(dismissed.count))")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
        }
        .onAppear { loadDismissed() }
    }

    // MARK: - Rows

    private func resultRow(_ item: ScanResultItem) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    if item.isGroup {
                        Text("群")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.12))
                            .cornerRadius(3)
                    }
                }
                HStack(spacing: 8) {
                    Text("\(item.recentCount) 条/45天")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(item.reason)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button("加入") {
                accept(item)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)

            Button("忽略") {
                dismiss(item)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func dismissedRow(_ entry: ScanDismissedEntry) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName.isEmpty ? entry.username : entry.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text("忽略于 \(entry.dismissedAt.formatted(.dateTime.month().day()))")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button("加入白名单") {
                acceptDismissed(entry)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)

            Button("删除") {
                removeDismissed(entry)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    // MARK: - Actions

    private func accept(_ item: ScanResultItem) {
        let category: WhitelistCategory = item.category == "work" ? .work :
                                          item.category == "life" ? .life : .other
        try? store.addToWhitelist(
            username: item.username,
            displayName: item.displayName,
            isGroup: item.isGroup,
            category: category,
            attentionLevel: .watch
        )
        if let idx = results.firstIndex(where: { $0.id == item.id }) {
            results[idx].accepted = true
        }
    }

    private func dismiss(_ item: ScanResultItem) {
        try? store.dismissScanResult(username: item.username, displayName: item.displayName)
        results.removeAll { $0.id == item.id }
        loadDismissed()
    }

    private func acceptAll() {
        for item in pendingResults { accept(item) }
    }

    private func dismissAll() {
        for item in pendingResults { dismiss(item) }
    }

    private func acceptDismissed(_ entry: ScanDismissedEntry) {
        let isGroup = entry.username.contains("@chatroom")
        try? store.addToWhitelist(
            username: entry.username,
            displayName: entry.displayName,
            isGroup: isGroup,
            category: .other,
            attentionLevel: .watch
        )
        try? store.undismissScanResult(username: entry.username)
        loadDismissed()
    }

    private func removeDismissed(_ entry: ScanDismissedEntry) {
        try? store.undismissScanResult(username: entry.username)
        loadDismissed()
    }

    private func loadDismissed() {
        dismissed = store.loadDismissedScanResults()
    }

    // MARK: - Scan

    private func startScan() {
        guard !isScanning else { return }
        isScanning = true
        results = []

        Task {
            let candidates = monitor.scanCandidates(limit: 50)

            guard !candidates.isEmpty else {
                await MainActor.run { isScanning = false }
                return
            }

            // Build batch items with recent messages
            var batchItems: [AIWhitelistCategorizer.BatchItem] = []
            for (i, c) in candidates.enumerated() {
                let msgs = monitor.recentMessages(chatUsername: c.username, limit: 5)
                guard !msgs.isEmpty else { continue }
                batchItems.append(AIWhitelistCategorizer.BatchItem(
                    index: i + 1,
                    contactName: c.displayName,
                    isGroup: c.isGroup,
                    recentCount: 0, // filled below
                    messages: msgs
                ))
            }

            // Get recent counts from candidates
            // (topActiveContacts already computed them, but we lost them through
            //  the tuple interface — for now we pass 0 and show message count from msgs)

            let categorizer = AIWhitelistCategorizer(
                store: store,
                config: store.loadAIConfig()
            )

            // Batch in groups of 15 to stay within token limits
            var allBatchResults: [AIWhitelistCategorizer.BatchResult] = []
            let chunks = stride(from: 0, to: batchItems.count, by: 15).map {
                Array(batchItems[$0..<min($0 + 15, batchItems.count)])
            }
            for chunk in chunks {
                // Re-index within chunk
                let reindexed = chunk.enumerated().map { i, item in
                    AIWhitelistCategorizer.BatchItem(
                        index: i + 1,
                        contactName: item.contactName,
                        isGroup: item.isGroup,
                        recentCount: item.recentCount,
                        messages: item.messages
                    )
                }
                let batchResults = await categorizer.categorizeBatch(reindexed)
                // Map back to original items
                for br in batchResults {
                    let originalIdx = br.index - 1
                    guard originalIdx >= 0, originalIdx < chunk.count else { continue }
                    allBatchResults.append(AIWhitelistCategorizer.BatchResult(
                        index: chunk[originalIdx].index,
                        category: br.category,
                        shouldWhitelist: br.shouldWhitelist,
                        reason: br.reason
                    ))
                }
            }

            // Map batch results back to candidates
            let candidateByIndex = Dictionary(uniqueKeysWithValues:
                batchItems.map { ($0.index, $0) }
            )

            await MainActor.run {
                for br in allBatchResults {
                    guard let item = candidateByIndex[br.index] else { continue }
                    let c = candidates.first { $0.username == item.contactName || $0.displayName == item.contactName }
                    let username = c?.username ?? ""
                    guard !username.isEmpty else { continue }
                    results.append(ScanResultItem(
                        id: username,
                        username: username,
                        displayName: c?.displayName ?? item.contactName,
                        isGroup: item.isGroup,
                        recentCount: item.messages.count,
                        category: br.category,
                        shouldWhitelist: br.shouldWhitelist,
                        reason: br.reason
                    ))
                }
                isScanning = false
            }
        }
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `swift build 2>&1 | tail -5`
Expected: Build complete

- [ ] **Step 3: Commit**

```bash
git add Sources/WeChatHUD/Views/WhitelistScanView.swift
git commit -m "feat(contacts): rewrite WhitelistScanView with batch scan + dismissed mgmt"
```

---

### Task 5: Add sub-tabs to ContactsSettingsView

**Files:**
- Modify: `Sources/WeChatHUD/Views/Settings/ContactsSettingsView.swift`

- [ ] **Step 1: Refactor ContactsSettingsView with sub-tabs**

Replace the entire content of `Sources/WeChatHUD/Views/Settings/ContactsSettingsView.swift`:

```swift
import SwiftUI

/// Four-tier contact manager with sub-tabs for different concerns.
/// Redesigned to give each function area full layout space.
struct ContactsSettingsView: View {
    @EnvironmentObject private var store: HUDStore
    @EnvironmentObject private var monitor: ChatMonitor

    enum SubTab: String, CaseIterable {
        case contacts = "通讯录"
        case aiScan = "AI 扫描"
        case blockRules = "屏蔽规则"
    }

    @State private var selectedSubTab: SubTab = .contacts

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Sub-tab picker
            Picker("", selection: $selectedSubTab) {
                ForEach(SubTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)

            // Tab content
            switch selectedSubTab {
            case .contacts:
                ContactsListSubView()
            case .aiScan:
                WhitelistScanView()
            case .blockRules:
                BlockRulesSubView()
            }
        }
    }
}

// MARK: - Contacts List Sub-View

/// The original contact list: VIP / whitelist / greylist with search + edit.
private struct ContactsListSubView: View {
    @EnvironmentObject private var store: HUDStore
    @EnvironmentObject private var monitor: ChatMonitor

    @State private var contacts: [ContactEntry] = []
    @State private var searchText = ""
    @State private var editingContact: ContactEntry?
    @State private var showAddSheet = false
    @State private var didLoad = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Top bar: search + add
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))
                    TextField("搜索联系人", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }

                Button {
                    showAddSheet = true
                } label: {
                    Label("添加", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            // Stats bar
            if !contacts.isEmpty {
                statsBar
            }

            // Contact list
            List {
                contactSection(level: .vip, title: "VIP", color: .yellow)
                contactSection(level: .whitelist, title: "白名单", color: .blue)
                contactSection(level: .greylist, title: "灰名单", color: .gray)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(minHeight: 300)
        }
        .onAppear {
            if !didLoad {
                reload()
                didLoad = true
            }
        }
        .sheet(item: $editingContact) { contact in
            ContactEditSheet(contact: contact, store: store, onSave: { reload() })
        }
        .sheet(isPresented: $showAddSheet) {
            Text("添加联系人（待实现）")
                .padding(32)
        }
    }

    // MARK: - Stats bar

    private var statsBar: some View {
        let vipCount   = contacts.filter { $0.attentionLevel == .vip }.count
        let whiteCount = contacts.filter { $0.attentionLevel == .whitelist }.count
        let greyCount  = contacts.filter { $0.attentionLevel == .greylist }.count
        return HStack(spacing: 12) {
            statPill("VIP",  count: vipCount,   color: .yellow)
            statPill("白名单", count: whiteCount, color: .blue)
            statPill("灰名单", count: greyCount,  color: .gray)
            Spacer()
            Text("共 \(contacts.count) 人")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }

    private func statPill(_ label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(count) \(label)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - List sections

    @ViewBuilder
    private func contactSection(level: AttentionLevel, title: String, color: Color) -> some View {
        let filtered = contacts
            .filter { $0.attentionLevel == level }
            .filter {
                searchText.isEmpty
                    || $0.displayName.localizedCaseInsensitiveContains(searchText)
                    || $0.role.label.localizedCaseInsensitiveContains(searchText)
            }

        if !filtered.isEmpty {
            Section {
                ForEach(filtered) { contact in
                    contactRow(contact, levelColor: color)
                }
            } header: {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 7, height: 7)
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.primary)
                    Text("(\(filtered.count))")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Contact row

    private func contactRow(_ contact: ContactEntry, levelColor: Color) -> some View {
        Button(action: { editingContact = contact }) {
            HStack(spacing: 8) {
                Text(contact.role.icon)
                    .font(.system(size: 14))

                VStack(alignment: .leading, spacing: 1) {
                    Text(contact.displayName)
                        .font(.system(size: 12))
                        .foregroundColor(.primary)
                    if !contact.roleNote.isEmpty {
                        Text(contact.roleNote)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Text(contact.role.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(levelColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(levelColor.opacity(0.12))
                    .cornerRadius(3)

                if contact.replyWindowMinutes > 0 {
                    Text("\(contact.replyWindowMinutes)m")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Menu("变更级别") {
                ForEach([AttentionLevel.vip, .whitelist, .greylist], id: \.self) { level in
                    if level != contact.attentionLevel {
                        Button(level.label) {
                            try? store.updateContactLevel(username: contact.username, level: level, role: contact.role)
                            reload()
                        }
                    }
                }
            }
            Divider()
            Button("删除", role: .destructive) {
                try? store.deleteContact(username: contact.username)
                reload()
            }
        }
    }

    private func reload() {
        contacts = store.loadContacts(level: nil)
    }
}

// MARK: - Block Rules Sub-View

/// Per-chat sender ignore rules.
private struct BlockRulesSubView: View {
    @EnvironmentObject private var store: HUDStore
    @EnvironmentObject private var monitor: ChatMonitor

    @State private var ignoredSenders: [IgnoredSenderRule] = []
    @State private var didLoad = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("通过消息右键菜单添加的忽略规则。被忽略的人不会进入未读统计。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            if ignoredSenders.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.slash")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("没有忽略的发送人")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List {
                    ForEach(ignoredSenders) { rule in
                        ignoredSenderRow(rule)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .frame(minHeight: 200)
            }
        }
        .onAppear {
            if !didLoad {
                reload()
                didLoad = true
            }
        }
    }

    private func ignoredSenderRow(_ rule: IgnoredSenderRule) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(rule.senderName)
                        .font(.system(size: 12, weight: .semibold))
                    Text(rule.chatName)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                if !rule.senderUsername.isEmpty {
                    Text(rule.senderUsername)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button("取消忽略") {
                monitor.unignoreSender(
                    chatUsername: rule.chatUsername,
                    senderUsername: rule.senderUsername,
                    senderName: rule.senderName
                )
                reload()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func reload() {
        ignoredSenders = store.loadIgnoredSenders()
    }
}

// MARK: - Edit Sheet (unchanged)

struct ContactEditSheet: View {
    let contact: ContactEntry
    let store: HUDStore
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedLevel: AttentionLevel
    @State private var selectedRole: ContactRole
    @State private var roleNote: String
    @State private var replyWindow: Int

    init(contact: ContactEntry, store: HUDStore, onSave: @escaping () -> Void) {
        self.contact = contact
        self.store = store
        self.onSave = onSave
        _selectedLevel  = State(initialValue: contact.attentionLevel)
        _selectedRole   = State(initialValue: contact.role)
        _roleNote       = State(initialValue: contact.roleNote)
        _replyWindow    = State(initialValue: contact.replyWindowMinutes)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("编辑联系人")
                    .font(.headline)
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding()

            Divider()

            Form {
                Section("基本信息") {
                    LabeledContent("名称") {
                        HStack(spacing: 6) {
                            Text(contact.role.icon)
                            Text(contact.displayName)
                        }
                    }
                    LabeledContent("用户名") {
                        Text(contact.username)
                            .foregroundColor(.secondary)
                    }
                }

                Section("关注设置") {
                    Picker("关注级别", selection: $selectedLevel) {
                        Text("VIP").tag(AttentionLevel.vip)
                        Text("白名单").tag(AttentionLevel.whitelist)
                        Text("灰名单").tag(AttentionLevel.greylist)
                    }
                    .onChange(of: selectedLevel) {
                        let roles = rolesForLevel(selectedLevel)
                        if !roles.contains(selectedRole) {
                            selectedRole = roles.first ?? selectedRole
                            replyWindow  = selectedRole.defaultReplyWindowMinutes
                        }
                    }

                    Picker("身份角色", selection: $selectedRole) {
                        ForEach(rolesForLevel(selectedLevel), id: \.self) { role in
                            Text("\(role.icon) \(role.label)").tag(role)
                        }
                    }
                    .onChange(of: selectedRole) {
                        replyWindow = selectedRole.defaultReplyWindowMinutes
                    }

                    TextField("备注", text: $roleNote)
                        .textFieldStyle(.roundedBorder)
                }

                Section("回复追踪") {
                    HStack(spacing: 8) {
                        TextField("回复窗口（分钟）", value: $replyWindow, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                        Text("默认 \(selectedRole.defaultReplyWindowMinutes) 分钟，0 = 不追踪")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }

                Section {
                    Text(selectedRole.roleDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                } header: {
                    Text("角色说明")
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 420, height: 440)
    }

    private func save() {
        try? store.upsertContact(
            username: contact.username,
            displayName: contact.displayName,
            attentionLevel: selectedLevel,
            role: selectedRole,
            roleNote: roleNote,
            replyWindowMinutes: replyWindow
        )
        onSave()
        dismiss()
    }

    private func rolesForLevel(_ level: AttentionLevel) -> [ContactRole] {
        switch level {
        case .vip:       return [.boss, .keyClient, .family, .partner]
        case .whitelist: return [.colleague, .client, .friend, .supplier]
        case .greylist:  return [.acquaintance, .groupOnly, .service]
        case .stranger:  return []
        }
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `swift build 2>&1 | tail -5`
Expected: Build complete

- [ ] **Step 3: Commit**

```bash
git add Sources/WeChatHUD/Views/Settings/ContactsSettingsView.swift
git commit -m "feat(contacts): split into sub-tabs (通讯录/AI扫描/屏蔽规则)"
```

---

### Task 6: Wire recentCount through scanCandidates

**Files:**
- Modify: `Sources/WeChatHUD/Services/ChatMonitor.swift`
- Modify: `Sources/WeChatHUD/Views/WhitelistScanView.swift`

The current `scanCandidates` returns a tuple without `recentCount`. Update it to include this data from `topActiveContacts`.

- [ ] **Step 1: Update scanCandidates return type**

In `ChatMonitor.swift`, replace the `scanCandidates` method:

```swift
struct ScanCandidate {
    let username: String
    let displayName: String
    let isGroup: Bool
    let recentCount: Int
}

func scanCandidates(limit: Int = 50) -> [ScanCandidate] {
    let whitelisted = Set(store.loadContacts(level: nil).map(\.username))
    let dismissed = store.dismissedScanUsernames()
    let excluded = whitelisted.union(dismissed)
    guard let active = try? reader.topActiveContacts(limit: limit + excluded.count) else {
        return []
    }
    return active
        .filter { !excluded.contains($0.username) }
        .prefix(limit)
        .map { ScanCandidate(
            username: $0.username,
            displayName: $0.displayName,
            isGroup: $0.isGroup,
            recentCount: $0.recentCount
        ) }
}
```

- [ ] **Step 2: Update WhitelistScanView.startScan to use ScanCandidate**

In `WhitelistScanView.swift`, update the `startScan` method's candidate handling. Replace the `Task { ... }` block inside `startScan`:

```swift
Task {
    let candidates = monitor.scanCandidates(limit: 50)

    guard !candidates.isEmpty else {
        await MainActor.run { isScanning = false }
        return
    }

    var batchItems: [AIWhitelistCategorizer.BatchItem] = []
    for (i, c) in candidates.enumerated() {
        let msgs = monitor.recentMessages(chatUsername: c.username, limit: 5)
        guard !msgs.isEmpty else { continue }
        batchItems.append(AIWhitelistCategorizer.BatchItem(
            index: i + 1,
            contactName: c.displayName,
            isGroup: c.isGroup,
            recentCount: c.recentCount,
            messages: msgs
        ))
    }

    let categorizer = AIWhitelistCategorizer(
        store: store,
        config: store.loadAIConfig()
    )

    var allBatchResults: [AIWhitelistCategorizer.BatchResult] = []
    let chunks = stride(from: 0, to: batchItems.count, by: 15).map {
        Array(batchItems[$0..<min($0 + 15, batchItems.count)])
    }
    for chunk in chunks {
        let reindexed = chunk.enumerated().map { i, item in
            AIWhitelistCategorizer.BatchItem(
                index: i + 1,
                contactName: item.contactName,
                isGroup: item.isGroup,
                recentCount: item.recentCount,
                messages: item.messages
            )
        }
        let batchResults = await categorizer.categorizeBatch(reindexed)
        for br in batchResults {
            let originalIdx = br.index - 1
            guard originalIdx >= 0, originalIdx < chunk.count else { continue }
            allBatchResults.append(AIWhitelistCategorizer.BatchResult(
                index: chunk[originalIdx].index,
                category: br.category,
                shouldWhitelist: br.shouldWhitelist,
                reason: br.reason
            ))
        }
    }

    // Map results back using batchItem index → candidate
    let itemByIndex = Dictionary(uniqueKeysWithValues: batchItems.map { ($0.index, $0) })

    await MainActor.run {
        for br in allBatchResults {
            guard let item = itemByIndex[br.index] else { continue }
            // Find original candidate by index (batchItem.index = candidateArrayIndex + 1)
            let candIdx = br.index - 1
            guard candIdx >= 0, candIdx < candidates.count else { continue }
            let c = candidates[candIdx]
            results.append(ScanResultItem(
                id: c.username,
                username: c.username,
                displayName: c.displayName,
                isGroup: c.isGroup,
                recentCount: c.recentCount,
                category: br.category,
                shouldWhitelist: br.shouldWhitelist,
                reason: br.reason
            ))
        }
        isScanning = false
    }
}
```

- [ ] **Step 3: Build to verify**

Run: `swift build 2>&1 | tail -5`
Expected: Build complete

- [ ] **Step 4: Commit**

```bash
git add Sources/WeChatHUD/Services/ChatMonitor.swift Sources/WeChatHUD/Views/WhitelistScanView.swift
git commit -m "feat(contacts): pass recentCount through scan pipeline"
```

---

### Task 7: Full build + test verification

**Files:** None (verification only)

- [ ] **Step 1: Run full build**

Run: `swift build 2>&1 | tail -10`
Expected: Build complete with zero errors

- [ ] **Step 2: Run full test suite**

Run: `swift test 2>&1 | grep -E '(Test Suite|passed|failed|error)'`
Expected: All tests pass, including the new `testScanDismissedRoundTrip` and `testScanDismissedUpsert`

- [ ] **Step 3: Run release build**

Run: `swift build -c release 2>&1 | tail -10`
Expected: Build complete with zero warnings (or only pre-existing warnings)
