# Plan A: 后端基础设施 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Unify AI config, build InboxContext data pipeline, fix 7 broken backend settings, clean up dead code — laying the foundation for Plans B/C/D.

**Architecture:** Merge AIClassifierConfig into AIConfig (single source of truth), create InboxContext as the structured data packet that algorithms extract and AI consumes, wire up 6 disconnected settings to their backend consumers, remove dead tab code.

**Tech Stack:** Swift 5.9, SQLite3, SwiftUI, AppKit

**Spec:** `docs/superpowers/specs/2026-04-13-ai-butler-inbox-v2.md`

---

## File Structure

| Action | File | Responsibility |
|--------|------|----------------|
| Modify | `Sources/WeChatHUD/Data/Models.swift` | Extend AIConfig, remove AIClassifierConfig, add AI capability toggles |
| Modify | `Sources/WeChatHUD/Data/HUDStore.swift` | Remove classifier config, unify seed/load, add migration |
| Create | `Sources/WeChatHUD/Data/InboxContext.swift` | InboxContext struct definition |
| Create | `Sources/WeChatHUD/Services/InboxContextBuilder.swift` | Build InboxContext from DB for each inbox item |
| Create | `Tests/WeChatHUDTests/InboxContextBuilderTests.swift` | Tests for context builder |
| Modify | `Sources/WeChatHUD/Services/AIClassifier.swift` | Accept AIConfig instead of AIClassifierConfig |
| Modify | `Sources/WeChatHUD/Services/AIReplySuggester.swift` | Accept AIConfig |
| Modify | `Sources/WeChatHUD/Services/AIDailyRetrospector.swift` | Accept AIConfig |
| Modify | `Sources/WeChatHUD/Services/AIGroupCatchup.swift` | Accept AIConfig |
| Modify | `Sources/WeChatHUD/Services/AIWhitelistCategorizer.swift` | Accept AIConfig |
| Modify | `Sources/WeChatHUD/Services/AutopilotService.swift` | Accept AIConfig |
| Modify | `Sources/WeChatHUD/Services/AutoReplyGenerator.swift` | Accept AIConfig |
| Modify | `Sources/WeChatHUD/Services/VIPAggregator.swift` | Accept AIConfig in callModel |
| Modify | `Sources/WeChatHUD/Services/CommitmentTracker.swift` | Accept AIConfig in callModel |
| Modify | `Sources/WeChatHUD/Services/ContextAnalyzer.swift` | Accept AIConfig in callModel |
| Modify | `Sources/WeChatHUD/Services/RecallAnalyzer.swift` | Accept AIConfig in callModel |
| Modify | `Sources/WeChatHUD/Services/ChatMonitor.swift` | Use AIConfig everywhere, read scan interval, wire notification filters |
| Modify | `Sources/WeChatHUD/Services/ReplyDebtScorer.swift` | Use per-contact replyWindowMinutes |
| Modify | `Sources/WeChatHUD/Services/ScanEngine.swift` | Pass contact data to scorer, build InboxContext |
| Modify | `Sources/WeChatHUD/App/AppDelegate.swift` | Remove Cmd+1-5, use AIConfig, notification filters |
| Modify | `Sources/WeChatHUD/Views/Settings/AISettingsView.swift` | Single config save, AI toggles |
| Modify | `Sources/WeChatHUD/Views/OnboardingView.swift` | Update shortcut text |
| Modify | `Sources/WeChatHUD/Services/ClassifierCLI.swift` | Use AIConfig |
| Delete | `Sources/WeChatHUD/Views/CompactBarView.swift` | Dead code |
| Delete | `Sources/WeChatHUD/Views/ExtendedBarView.swift` | Dead code |

---

### Task 1: Unify AIConfig — Remove AIClassifierConfig

The most impactful change. Every AI service currently takes `AIClassifierConfig`. We merge its fields into `AIConfig` and delete the old type.

**Files:**
- Modify: `Sources/WeChatHUD/Data/Models.swift`
- Modify: `Sources/WeChatHUD/Data/HUDStore.swift`

- [ ] **Step 1: Extend AIConfig with classifier fields + capability toggles**

In `Sources/WeChatHUD/Data/Models.swift`, replace the current `AIConfig` struct (lines 564-570):

```swift
// BEFORE:
struct AIConfig: Codable {
    var baseURL: String = ""
    var model: String = ""
    var apiKey: String = ""
    var maxTokens: Int = 2048
    var temperature: Double = 0.3
}
```

With:

```swift
/// Unified AI configuration. Single source of truth for all AI services.
/// Stored in the `ai` row of the `settings` table.
/// Read via `HUDStore.loadAIConfig()`.
struct AIConfig: Codable {
    // Connection
    var baseURL: String = ""
    var model: String = ""
    var apiKey: String = ""

    // Generation defaults (services may override per-call)
    var maxTokens: Int = 2048
    var temperature: Double = 0.3

    // Capability toggles
    var summaryEnabled: Bool = true
    var suggestionsEnabled: Bool = true
    var moodDetectionEnabled: Bool = true
    var debtJudgeEnabled: Bool = true
    var debtJudgeShadowMode: Bool = true
}
```

- [ ] **Step 2: Delete AIClassifierConfig**

In `Sources/WeChatHUD/Data/Models.swift`, delete the entire `AIClassifierConfig` struct (lines 610-631, including the doc comment above it). It will be approximately:

```swift
// DELETE THIS ENTIRE BLOCK:
/// Configuration for the per-message ask classifier ...
struct AIClassifierConfig: Codable {
    var baseURL: String = "http://127.0.0.1:8000/v1"
    var model: String = "Qwen3.5-27B-6bit"
    var apiKey: String = ""
    var temperature: Double = 0.1
    var maxTokens: Int = 256
    var promptVersion: String = "classifier_v1"
}
```

- [ ] **Step 3: Update HUDStore — remove classifier config, unify seed/load**

In `Sources/WeChatHUD/Data/HUDStore.swift`:

**a)** Delete `factoryClassifierConfig` (lines 1113-1132).

**b)** Update `factoryAIConfig` to include the factory defaults that were in classifier:

```swift
private static let factoryAIConfig: AIConfig = {
    var cfg = AIConfig()
    cfg.baseURL = "http://127.0.0.1:8000/v1"
    cfg.model = "Qwen3.5-27B-6bit"
    cfg.apiKey = ""
    cfg.maxTokens = 2048
    cfg.temperature = 0.3
    return cfg
}()
```

**c)** Rewrite `seedAISettingsIfMissing()`:

```swift
func seedAISettingsIfMissing() {
    // Migrate: if old "classifier" key exists but "ai" doesn't,
    // copy connection params from classifier to the new unified config.
    if getSetting("ai") == nil {
        if let oldCls = getSetting("classifier"),
           let data = oldCls.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Build AIConfig from old classifier values
            var cfg = HUDStore.factoryAIConfig
            if let url = json["baseURL"] as? String { cfg.baseURL = url }
            if let model = json["model"] as? String { cfg.model = model }
            if let key = json["apiKey"] as? String { cfg.apiKey = key }
            try? setSettingJSON("ai", value: cfg)
            print("[WCHUD] migrated classifier config → unified ai config")
        } else {
            try? setSettingJSON("ai", value: HUDStore.factoryAIConfig)
            print("[WCHUD] seeded settings.ai (first launch)")
        }
    }

    if getSetting("role_configs") == nil {
        // ... (keep existing role_configs seeding unchanged)
    }

    if getSetting("notification") == nil {
        try? setSettingJSON("notification", value: NotificationConfig())
        print("[WCHUD] seeded settings.notification (first launch)")
    }
}
```

**d)** Delete `loadClassifierConfig()` function. Keep only `loadAIConfig()`.

**e)** Remove the classifier↔ai sync block that we added earlier (the `if let ai = getSettingJSON("ai" ...)` block).

- [ ] **Step 4: Verify build fails (AIClassifierConfig references everywhere)**

Run: `swift build 2>&1 | grep "error:" | head -20`
Expected: Many errors like "Cannot find type 'AIClassifierConfig' in scope"

- [ ] **Step 5: Commit checkpoint**

```bash
git add Sources/WeChatHUD/Data/Models.swift Sources/WeChatHUD/Data/HUDStore.swift
git commit -m "refactor: unify AIConfig, remove AIClassifierConfig (build broken — WIP)"
```

---

### Task 2: Migrate All AI Services to AIConfig

Fix every AI service that references `AIClassifierConfig`.

**Files:**
- Modify: 11 service files (AIClassifier, AIReplySuggester, AIDailyRetrospector, AIGroupCatchup, AIWhitelistCategorizer, AutopilotService, AutoReplyGenerator, VIPAggregator, CommitmentTracker, ContextAnalyzer, RecallAnalyzer)
- Modify: `Sources/WeChatHUD/Services/ClassifierCLI.swift`

- [ ] **Step 1: AIClassifier.swift — replace AIClassifierConfig with AIConfig**

Find and replace all occurrences of `AIClassifierConfig` with `AIConfig` in the file. The key changes:

```swift
// BEFORE:
private var config: AIClassifierConfig
init(store: HUDStore, config: AIClassifierConfig = AIClassifierConfig(), ...)
func updateConfig(_ config: AIClassifierConfig) {

// AFTER:
private var config: AIConfig
init(store: HUDStore, config: AIConfig = AIConfig(), ...)
func updateConfig(_ config: AIConfig) {
```

The classifier uses `config.temperature` (0.1) and `config.maxTokens` (256) — these differ from AIConfig defaults (0.3, 2048). Override them in init:

```swift
init(store: HUDStore, config: AIConfig = AIConfig(), promptLoader: PromptLoader = PromptLoader()) {
    self.store = store
    var c = config
    c.temperature = 0.1   // classifier needs low temperature
    c.maxTokens = 256     // classifier output is small
    self.config = c
    self.promptLoader = promptLoader
}
```

- [ ] **Step 2: AIReplySuggester.swift — same pattern**

Replace `AIClassifierConfig` → `AIConfig`. Keep the existing init override of maxTokens=512, temperature=0.4:

```swift
init(store: HUDStore, config: AIConfig, ...) {
    self.store = store
    var inflated = config
    inflated.maxTokens = 512
    inflated.temperature = 0.4
    self.config = inflated
    // ...
}

func updateConfig(_ newConfig: AIConfig) {
    var inflated = newConfig
    inflated.maxTokens = 512
    inflated.temperature = 0.4
    self.config = inflated
}
```

- [ ] **Step 3: AIDailyRetrospector.swift — replace type**

Replace `AIClassifierConfig` → `AIConfig` throughout. No special overrides needed (uses config as-is for longer output).

- [ ] **Step 4: AIGroupCatchup.swift — replace type**

Replace `AIClassifierConfig` → `AIConfig` throughout.

- [ ] **Step 5: AIWhitelistCategorizer.swift — replace type**

Replace `AIClassifierConfig` → `AIConfig` throughout.

- [ ] **Step 6: AutopilotService.swift — replace type**

Replace all occurrences. This file has:
```swift
private var aiConfig: AIClassifierConfig  →  private var aiConfig: AIConfig
init(store: HUDStore, reader: WeChatReader, config: AIClassifierConfig)  →  init(..., config: AIConfig)
func updateConfig(_ config: AIClassifierConfig) async  →  func updateConfig(_ config: AIConfig) async
```

- [ ] **Step 7: AutoReplyGenerator.swift — replace type**

Same pattern: `AIClassifierConfig` → `AIConfig` for config property, init, and updateConfig.

- [ ] **Step 8: Helper services — replace AIClassifierConfig in callModel signatures**

For each of these files, find `func callModel(prompt: String, config: AIClassifierConfig)` and change to `func callModel(prompt: String, config: AIConfig)`:

- `Sources/WeChatHUD/Services/VIPAggregator.swift`
- `Sources/WeChatHUD/Services/CommitmentTracker.swift`
- `Sources/WeChatHUD/Services/ContextAnalyzer.swift` (also the writeAudit method)
- `Sources/WeChatHUD/Services/RecallAnalyzer.swift`

- [ ] **Step 9: ClassifierCLI.swift — replace makeClassifierConfig**

```swift
// BEFORE:
private static func makeClassifierConfig(store: HUDStore) -> AIClassifierConfig {
    store.loadClassifierConfig()
}

// AFTER:
private static func makeClassifierConfig(store: HUDStore) -> AIConfig {
    store.loadAIConfig()
}
```

Also replace any other `AIClassifierConfig` references in this file (search and replace).

- [ ] **Step 10: Verify build compiles**

Run: `swift build 2>&1 | grep -E "error:|Build complete"`
Expected: `Build complete!`

- [ ] **Step 11: Run existing tests**

Run: `swift test --filter "HUDStoreTests|AIServicesTests|InboxBuilderTests" 2>&1 | tail -5`
Expected: All pass

- [ ] **Step 12: Commit**

```bash
git add Sources/WeChatHUD/Services/ Sources/WeChatHUD/Data/
git commit -m "refactor: migrate all AI services from AIClassifierConfig to AIConfig"
```

---

### Task 3: Update ChatMonitor + AppDelegate to Use AIConfig

**Files:**
- Modify: `Sources/WeChatHUD/Services/ChatMonitor.swift`
- Modify: `Sources/WeChatHUD/App/AppDelegate.swift`
- Modify: `Sources/WeChatHUD/Views/Settings/AISettingsView.swift`

- [ ] **Step 1: ChatMonitor — replace all loadClassifierConfig with loadAIConfig**

In `Sources/WeChatHUD/Services/ChatMonitor.swift`:

Replace every `store.loadClassifierConfig()` with `store.loadAIConfig()`. There are ~5 occurrences:

```swift
// lazy vars:
private lazy var aiClassifier: AIClassifier = {
    AIClassifier(store: store, config: store.loadAIConfig())
}()
private lazy var replySuggester: AIReplySuggester = {
    AIReplySuggester(store: store, config: store.loadAIConfig())
}()
private lazy var dailyRetrospector: AIDailyRetrospector = {
    AIDailyRetrospector(store: store, config: store.loadAIConfig())
}()

// init:
let classifierConfig = store.loadAIConfig()
self.aiGroupCatchup = AIGroupCatchup(store: store, config: classifierConfig)

// startAutopilot:
let config = store.loadAIConfig()
autopilotService = AutopilotService(store: store, reader: reader, config: config)
```

Also update `refreshReplySuggesterConfig`:

```swift
func refreshReplySuggesterConfig() async {
    let cfg = store.loadAIConfig()
    await replySuggester.updateConfig(cfg)
}
```

- [ ] **Step 2: AppDelegate — propagate AIConfig on config change**

In `Sources/WeChatHUD/App/AppDelegate.swift`, find the `.hudAIConfigDidChange` sink (around line 183):

```swift
// BEFORE:
NotificationCenter.default.publisher(for: .hudAIConfigDidChange)
    .sink { [weak self] _ in
        guard let self = self else { return }
        let cfg = self.store.loadAIConfig()
        Task {
            await self.aiService.updateConfig(cfg)
        }
        let classifierCfg = self.store.loadClassifierConfig()
        Task {
            await self.monitor.autopilotService?.updateConfig(classifierCfg)
            await self.monitor.refreshReplySuggesterConfig()
        }
    }

// AFTER:
NotificationCenter.default.publisher(for: .hudAIConfigDidChange)
    .sink { [weak self] _ in
        guard let self = self else { return }
        let cfg = self.store.loadAIConfig()
        Task {
            await self.aiService.updateConfig(cfg)
            await self.monitor.autopilotService?.updateConfig(cfg)
            await self.monitor.refreshReplySuggesterConfig()
        }
    }
```

- [ ] **Step 3: AISettingsView — save single config, add capability toggles**

In `Sources/WeChatHUD/Views/Settings/AISettingsView.swift`:

**a)** Remove the classifier sync block from `saveAIConfig()`:

```swift
// BEFORE:
private func saveAIConfig() {
    guard didLoad else { return }
    let cfg = AIConfig(baseURL: baseURL, model: model, apiKey: apiKey)
    try? store.setSettingJSON("ai", value: cfg)
    var cls = store.loadClassifierConfig()
    cls.baseURL = baseURL
    cls.model = model
    cls.apiKey = apiKey
    try? store.setSettingJSON("classifier", value: cls)
    // ...
}

// AFTER:
private func saveAIConfig() {
    guard didLoad else { return }
    var cfg = store.loadAIConfig()
    cfg.baseURL = baseURL
    cfg.model = model
    cfg.apiKey = apiKey
    try? store.setSettingJSON("ai", value: cfg)
    NotificationCenter.default.post(name: .hudAIConfigDidChange, object: nil)
    showSaved = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showSaved = false }
}
```

**b)** The capability toggles UI will be added in Plan D (settings redesign). For now just ensure the save/load path is clean.

- [ ] **Step 4: Verify build + tests**

Run: `swift build 2>&1 | grep -E "error:|Build complete"`
Run: `swift test --filter "HUDStoreTests|InboxBuilderTests" 2>&1 | tail -5`

- [ ] **Step 5: Commit**

```bash
git add Sources/WeChatHUD/Services/ChatMonitor.swift Sources/WeChatHUD/App/AppDelegate.swift Sources/WeChatHUD/Views/Settings/AISettingsView.swift
git commit -m "refactor: ChatMonitor + AppDelegate use unified AIConfig"
```

---

### Task 4: Per-Contact Reply Window in ReplyDebtScorer

Currently `ReplyDebtScorer` uses 3 global thresholds (normalOverdueMinutes=120, vipOverdueMinutes=30, groupAtOverdueMinutes=30). The contacts table has per-contact `replyWindowMinutes` but it's never read. Fix this.

**Files:**
- Modify: `Sources/WeChatHUD/Services/ReplyDebtScorer.swift`
- Modify: `Sources/WeChatHUD/Services/ScanEngine.swift`
- Create: `Tests/WeChatHUDTests/ReplyDebtScorerPerContactTests.swift`

- [ ] **Step 1: Write failing test**

```swift
// Tests/WeChatHUDTests/ReplyDebtScorerPerContactTests.swift
import XCTest
@testable import WeChatHUD

final class ReplyDebtScorerPerContactTests: XCTestCase {

    private func makeSeed(
        username: String = "wxid_test",
        isVIP: Bool = false,
        isWhitelisted: Bool = true,
        isGroup: Bool = false,
        isAtMention: Bool = false,
        inboundAge: Int = 60,  // minutes
        contactReplyWindowMinutes: Int? = nil
    ) -> ReplyDebtScorer.Seed {
        let now = Date()
        let inboundTime = Int(now.timeIntervalSince1970) - (inboundAge * 60)
        return ReplyDebtScorer.Seed(
            session: SessionInfo(
                username: username,
                lastTimestamp: inboundTime,
                unreadCount: 1,
                isGroup: isGroup
            ),
            chatName: "Test",
            isWhitelisted: isWhitelisted,
            isVIP: isVIP,
            latestInbound: MessageInfo(
                localId: 1,
                createTime: inboundTime,
                messageType: 1,
                appType: 0,
                text: "Hello",
                senderUsername: "sender",
                senderName: "Sender",
                chatName: "Test"
            ),
            latestOutbound: nil,
            inboundCountSinceLastOutbound: 1,
            isAtMention: isAtMention,
            chatAction: nil,
            now: now,
            contactReplyWindowMinutes: contactReplyWindowMinutes
        )
    }

    func testContactReplyWindowOverridesGlobalThreshold() {
        // Contact has a 15-minute reply window. Message is 20 minutes old.
        // Global threshold is 120 minutes (not overdue), but per-contact is 15 (overdue).
        let seed = makeSeed(inboundAge: 20, contactReplyWindowMinutes: 15)
        let config = ReplyDebtConfig()  // normalOverdueMinutes = 120
        let items = ReplyDebtScorer.build(seeds: [seed], config: config)
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items[0].reasons.contains { $0.code == .overdue },
                       "Should be overdue: 20 min > contact's 15 min window")
    }

    func testGlobalThresholdUsedWhenNoContactWindow() {
        // No per-contact window. Message is 60 minutes old.
        // Global threshold is 120 minutes → not overdue.
        let seed = makeSeed(inboundAge: 60, contactReplyWindowMinutes: nil)
        let config = ReplyDebtConfig()
        let items = ReplyDebtScorer.build(seeds: [seed], config: config)
        XCTAssertEqual(items.count, 1)
        XCTAssertFalse(items[0].reasons.contains { $0.code == .overdue },
                        "Should NOT be overdue: 60 min < global 120 min")
    }

    func testVIPContactWindowOverridesVIPGlobal() {
        // VIP contact with custom 5-minute window. Message 10 min old.
        // VIP global = 30 min (not overdue), contact = 5 min (overdue).
        let seed = makeSeed(isVIP: true, inboundAge: 10, contactReplyWindowMinutes: 5)
        let config = ReplyDebtConfig()
        let items = ReplyDebtScorer.build(seeds: [seed], config: config)
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items[0].reasons.contains { $0.code == .overdue })
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ReplyDebtScorerPerContactTests 2>&1 | tail -5`
Expected: Compilation error — `Seed` has no `contactReplyWindowMinutes` parameter.

- [ ] **Step 3: Add contactReplyWindowMinutes to Seed**

In `Sources/WeChatHUD/Services/ReplyDebtScorer.swift`, add to the `Seed` struct:

```swift
struct Seed {
    let session: SessionInfo
    let chatName: String
    let isWhitelisted: Bool
    let isVIP: Bool
    let latestInbound: MessageInfo?
    let latestOutbound: MessageInfo?
    let inboundCountSinceLastOutbound: Int
    let isAtMention: Bool
    let chatAction: HUDStore.ChatActionState?
    let now: Date
    let contactReplyWindowMinutes: Int?  // NEW: from contacts table, nil = use global
}
```

- [ ] **Step 4: Use per-contact window in overdue calculation**

In `ReplyDebtScorer.buildItem()`, replace the overdue calculation (lines 53-62):

```swift
// BEFORE:
let overdueMinutes: Int
if seed.session.isGroup && seed.isAtMention {
    overdueMinutes = config.groupAtOverdueMinutes
} else if seed.isVIP {
    overdueMinutes = config.vipOverdueMinutes
} else {
    overdueMinutes = config.normalOverdueMinutes
}

// AFTER:
let overdueMinutes: Int
if let contactWindow = seed.contactReplyWindowMinutes, contactWindow > 0 {
    // Per-contact setting takes precedence
    overdueMinutes = contactWindow
} else if seed.session.isGroup && seed.isAtMention {
    overdueMinutes = config.groupAtOverdueMinutes
} else if seed.isVIP {
    overdueMinutes = config.vipOverdueMinutes
} else {
    overdueMinutes = config.normalOverdueMinutes
}
```

- [ ] **Step 5: Update ScanEngine to pass contactReplyWindowMinutes**

In `Sources/WeChatHUD/Services/ScanEngine.swift`, the `buildReplyDebtItems` function needs to look up the contact's reply window. 

First, change the function signature to accept contacts:

```swift
static func buildReplyDebtItems(
    sessions: [SessionInfo],
    reader: WeChatReader,
    chatActions: [String: HUDStore.ChatActionState],
    ignoredSenderMap: [String: Set<String>],
    myUsername: String,
    whitelistSet: Set<String>,
    vipSet: Set<String>,
    contactMap: [String: ContactEntry],  // NEW
    config: ReplyDebtConfig
) -> [ReplyDebtItem] {
```

Inside the function, when building each Seed (around line 476):

```swift
return ReplyDebtScorer.Seed(
    session: session,
    chatName: inbound.chatName,
    isWhitelisted: whitelistSet.contains(session.username),
    isVIP: vipSet.contains(session.username),
    latestInbound: inbound,
    latestOutbound: latestOutbound,
    inboundCountSinceLastOutbound: inboundCountSinceLastOutbound,
    isAtMention: MessageHelpers.isAtMe(inbound.text, myUsername: myUsername),
    chatAction: chatActions[session.username],
    now: now,
    contactReplyWindowMinutes: contactMap[session.username]?.replyWindowMinutes  // NEW
)
```

In `performScan()`, build the contact map and pass it:

```swift
// After: let vipSet = ...
let allContacts = store.loadContacts()
let contactMap = Dictionary(uniqueKeysWithValues: allContacts.map { ($0.username, $0) })

var replyDebtItems = buildReplyDebtItems(
    sessions: sessions,
    reader: reader,
    chatActions: chatActions,
    ignoredSenderMap: ignoredSenderMap,
    myUsername: myUname,
    whitelistSet: whitelistSet,
    vipSet: vipSet,
    contactMap: contactMap,  // NEW
    config: replyDebtConfig
)
```

- [ ] **Step 6: Run tests**

Run: `swift test --filter ReplyDebtScorerPerContactTests 2>&1 | tail -5`
Expected: All 3 pass.

Run: `swift build 2>&1 | grep -E "error:|Build complete"`
Expected: `Build complete!`

- [ ] **Step 7: Commit**

```bash
git add Sources/WeChatHUD/Services/ReplyDebtScorer.swift Sources/WeChatHUD/Services/ScanEngine.swift Tests/WeChatHUDTests/ReplyDebtScorerPerContactTests.swift
git commit -m "feat: per-contact reply window in ReplyDebtScorer"
```

---

### Task 5: Notification Filter Toggles

NotificationConfig has 3 booleans (atMention, important, allWhitelist) that are saved in settings but never read by the notification trigger logic.

**Files:**
- Modify: `Sources/WeChatHUD/App/AppDelegate.swift`
- Modify: `Sources/WeChatHUD/Services/ChatMonitor.swift`

- [ ] **Step 1: Add notification filter to AppDelegate**

In AppDelegate, the notification trigger (around line 149) currently fires for every `latestNotification`:

```swift
// BEFORE:
monitor.$latestNotification
    .compactMap { $0 }
    .sink { [weak self] _ in
        guard let self = self else { return }
        let duration = self.store.getSettingJSON("notification", as: NotificationConfig.self)?.durationSeconds ?? 3
        self.panelState.showNotification(duration: TimeInterval(duration))
    }
    .store(in: &cancellables)
```

Replace with filtered version:

```swift
// AFTER:
monitor.$latestNotification
    .compactMap { $0 }
    .sink { [weak self] notif in
        guard let self = self else { return }
        let cfg = self.store.getSettingJSON("notification", as: NotificationConfig.self) ?? NotificationConfig()
        
        // Apply notification filter toggles
        let shouldNotify: Bool
        switch notif.kind {
        case .groupAt:
            shouldNotify = cfg.atMention
        case .privateChat:
            if notif.attentionLevel == .vip {
                shouldNotify = cfg.important
            } else {
                shouldNotify = cfg.allWhitelist
            }
        case .groupMessage:
            shouldNotify = cfg.allWhitelist
        }
        
        guard shouldNotify else { return }
        self.panelState.showNotification(duration: TimeInterval(cfg.durationSeconds))
    }
    .store(in: &cancellables)
```

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | grep -E "error:|Build complete"`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/WeChatHUD/App/AppDelegate.swift
git commit -m "fix: notification filter toggles now actually work"
```

---

### Task 6: Scan Interval from Settings

The 10-second timer tick with every-6th-tick scan is hardcoded. The user's `syncConfig.intervalSeconds` is saved but never read.

**Files:**
- Modify: `Sources/WeChatHUD/Services/ChatMonitor.swift`

- [ ] **Step 1: Read intervalSeconds in start()**

In ChatMonitor.start(), replace the hardcoded timer:

```swift
// BEFORE:
safetyTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in

// AFTER:
let syncCfg = store.getSettingJSON("sync", as: SyncConfig.self) ?? SyncConfig()
let tickInterval: TimeInterval = 10  // fixed tick for autopilot queue processing
let scanEveryNTicks = max(1, syncCfg.intervalSeconds / 10)  // convert seconds → ticks
safetyTimer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
```

And replace the hardcoded `% 6`:

```swift
// BEFORE:
if self.safetyTickCount % 6 == 0 {
    await self.scan()
}

// AFTER:
if self.safetyTickCount % scanEveryNTicks == 0 {
    await self.scan()
}
```

Note: `scanEveryNTicks` needs to be captured by the closure. Store it as a property or capture it:

```swift
let scanMod = max(1, syncCfg.intervalSeconds / 10)
safetyTimer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
    Task { [weak self] in
        guard let self = self else { return }
        // ... autopilot queue processing ...
        
        self.safetyTickCount += 1
        if self.safetyTickCount % scanMod == 0 {
            await self.scan()
        }
```

Since `scanMod` is a let captured by the closure, this works. But if the user changes the setting, they need to restart the monitor. For now this is acceptable.

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | grep -E "error:|Build complete"`

- [ ] **Step 3: Commit**

```bash
git add Sources/WeChatHUD/Services/ChatMonitor.swift
git commit -m "fix: scan interval reads from sync settings instead of hardcoded 60s"
```

---

### Task 7: DB Path from Settings

WeChatReader auto-detects the WeChat DB directory. The user can set a custom path in sync settings, but it's ignored.

**Files:**
- Modify: `Sources/WeChatHUD/App/AppDelegate.swift`

- [ ] **Step 1: Pass DB path from settings to WeChatReader**

In AppDelegate, find where `WeChatReader` is created (around line 25-30):

```swift
// Find the current reader init and add dbDir parameter:
let syncCfg = store.getSettingJSON("sync", as: SyncConfig.self) ?? SyncConfig()
let customDBPath: String? = (syncCfg.wechatDBPath != "auto" && !syncCfg.wechatDBPath.isEmpty)
    ? syncCfg.wechatDBPath
    : nil
reader = WeChatReader(dbDir: customDBPath)
```

Check the exact current code first — the reader init might already be called with specific parameters. Adapt accordingly.

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | grep -E "error:|Build complete"`

- [ ] **Step 3: Commit**

```bash
git add Sources/WeChatHUD/App/AppDelegate.swift
git commit -m "fix: WeChatReader uses custom DB path from sync settings"
```

---

### Task 8: InboxContext Data Structure

Create the structured data packet that algorithms build and AI consumes.

**Files:**
- Create: `Sources/WeChatHUD/Data/InboxContext.swift`

- [ ] **Step 1: Create InboxContext**

```swift
// Sources/WeChatHUD/Data/InboxContext.swift
import Foundation

/// Structured data packet for a single inbox item.
/// Built by algorithms (precise DB extraction), consumed by AI (summary/briefing).
/// Every field is an objective fact — no AI inference at this level.
struct InboxContext {
    // 1. Trigger message
    let triggerMessage: MessageInfo
    let triggerMessageText: String

    // 2. Conversation window (dynamic size)
    let recentMessages: [MessageInfo]
    let myLastReply: MessageInfo?
    let myLastReplyText: String?
    let timeSinceMyLastReply: TimeInterval?

    // 3. Sender profile
    let senderRole: ContactRole
    let senderAttentionLevel: AttentionLevel
    let senderReplyWindow: Int          // from contacts table
    let isOverdue: Bool
    let overdueMinutes: Int

    // 4. Interaction history
    let weeklyInteractionCount: Int
    let weeklyTrend: InteractionTrend
    let avgResponseTimeMinutes: Int

    // 5. Related data
    let pendingCommitments: [Commitment]
    let pendingAsks: [PendingAsk]

    // 6. Group-specific
    let isGroupChat: Bool
    let mentionedMe: Bool
    let groupRecentContext: [MessageInfo]?

    // 7. Message signals
    let hasUrgentKeyword: Bool
    let hasAskSignal: Bool
    let inboundCountSinceMyLastReply: Int

    // 8. Media content
    let mediaType: DetectedMediaType?
    let mediaFilePath: String?
    let mediaContextMessages: [MessageInfo]

    // 9. Link content (baseType=49)
    let linkTitle: String?
    let linkDescription: String?
    let linkURL: String?
    let linkBodyText: String?
}

enum InteractionTrend: String {
    case up
    case down
    case stable
}

/// Detected media type from message content.
/// Used by InboxContext to determine what kind of AI analysis is needed.
enum DetectedMediaType: String {
    case image
    case video
    case voice
    case file
    case link
    case sticker
    case location
    case system
}
```

- [ ] **Step 2: Check for DetectedMediaType conflict**

There's already a `DetectedMediaType` in MessageFeatureExtractor.swift. Check if it exists:

Run: `grep -rn "enum DetectedMediaType" Sources/ --include="*.swift"`

If it exists, reuse it (import from that file) instead of redefining. If it's in a different module, move the definition to Models.swift.

- [ ] **Step 3: Verify build**

Run: `swift build 2>&1 | grep -E "error:|Build complete"`

- [ ] **Step 4: Commit**

```bash
git add Sources/WeChatHUD/Data/InboxContext.swift
git commit -m "feat: add InboxContext data structure"
```

---

### Task 9: InboxContextBuilder

Build InboxContext from DB for each inbox item. This is the algorithm layer's core contribution.

**Files:**
- Create: `Sources/WeChatHUD/Services/InboxContextBuilder.swift`
- Create: `Tests/WeChatHUDTests/InboxContextBuilderTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// Tests/WeChatHUDTests/InboxContextBuilderTests.swift
import XCTest
@testable import WeChatHUD

final class InboxContextBuilderTests: XCTestCase {
    var tmpPath: String!
    var store: HUDStore!

    override func setUp() {
        tmpPath = NSTemporaryDirectory() + "hud_ctx_\(UUID().uuidString).sqlite3"
        store = HUDStore(dbPath: tmpPath)
        try! store.open()
    }

    override func tearDown() {
        store.close()
        try? FileManager.default.removeItem(atPath: tmpPath)
    }

    func testContextWindowSizeShortMessage() {
        // ≤5 chars → 15 messages context
        let size = InboxContextBuilder.contextWindowSize(messageLength: 3)
        XCTAssertEqual(size, 15)
    }

    func testContextWindowSizeMediumMessage() {
        // 6-20 chars → 10 messages
        let size = InboxContextBuilder.contextWindowSize(messageLength: 15)
        XCTAssertEqual(size, 10)
    }

    func testContextWindowSizeLongMessage() {
        // >50 chars → 3 messages
        let size = InboxContextBuilder.contextWindowSize(messageLength: 80)
        XCTAssertEqual(size, 3)
    }

    func testWeeklyTrendCalculation() {
        // 7 daily counts: first half lower, second half higher → up
        let trend = InboxContextBuilder.calculateTrend(dailyCounts: [1, 2, 1, 3, 4, 5, 6])
        XCTAssertEqual(trend, .up)
    }

    func testWeeklyTrendStable() {
        let trend = InboxContextBuilder.calculateTrend(dailyCounts: [3, 3, 3, 3, 3, 3, 3])
        XCTAssertEqual(trend, .stable)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter InboxContextBuilderTests 2>&1 | tail -5`
Expected: Compilation error

- [ ] **Step 3: Implement InboxContextBuilder**

```swift
// Sources/WeChatHUD/Services/InboxContextBuilder.swift
import Foundation

/// Builds InboxContext by extracting precise data from DB.
/// Pure algorithm — no AI calls. Every field is an objective fact.
enum InboxContextBuilder {

    /// Determine how many context messages to fetch based on trigger message length.
    /// Shorter messages carry less information → need more context.
    static func contextWindowSize(messageLength: Int) -> Int {
        switch messageLength {
        case ...5:   return 15
        case 6...20: return 10
        case 21...50: return 6
        default:     return 3
        }
    }

    /// Calculate interaction trend from 7 daily message counts.
    static func calculateTrend(dailyCounts: [Int]) -> InteractionTrend {
        guard dailyCounts.count >= 4 else { return .stable }
        let mid = dailyCounts.count / 2
        let firstHalf = dailyCounts[..<mid].reduce(0, +)
        let secondHalf = dailyCounts[mid...].reduce(0, +)
        let diff = secondHalf - firstHalf
        if diff > max(firstHalf / 3, 2) { return .up }
        if diff < -max(firstHalf / 3, 2) { return .down }
        return .stable
    }

    /// Build InboxContext for a single conversation.
    /// Called once per inbox item during scan.
    static func build(
        chatUsername: String,
        triggerMessage: MessageInfo,
        reader: WeChatReader,
        store: HUDStore,
        myUsername: String,
        contactEntry: ContactEntry?,
        whitelistEntry: WhitelistEntry?,
        replyDebtItem: ReplyDebtItem?
    ) -> InboxContext {
        let text = triggerMessage.text
        let windowSize = contextWindowSize(messageLength: text.count)

        // Fetch recent messages for context
        let recentMessages = (try? reader.getMessages(
            chatUsername: chatUsername,
            limit: windowSize
        )) ?? []

        // Find my last reply in this conversation
        let myLastReply = recentMessages.first {
            MessageHelpers.isFromSelf($0, chatUsername: chatUsername, myUsername: myUsername)
        }
        let timeSinceMyLastReply: TimeInterval? = myLastReply.map {
            Date().timeIntervalSince(Date(timeIntervalSince1970: Double($0.createTime)))
        }

        // Count inbound since my last reply
        let inboundSinceReply: Int
        if let outbound = myLastReply {
            inboundSinceReply = recentMessages.filter {
                !MessageHelpers.isFromSelf($0, chatUsername: chatUsername, myUsername: myUsername)
                && $0.createTime > outbound.createTime
            }.count
        } else {
            inboundSinceReply = recentMessages.filter {
                !MessageHelpers.isFromSelf($0, chatUsername: chatUsername, myUsername: myUsername)
            }.count
        }

        // Sender profile from contacts
        let role = contactEntry?.role ?? .acquaintance
        let attentionLevel: AttentionLevel
        if let wl = whitelistEntry {
            attentionLevel = wl.attentionLevel == .vip ? .vip : .whitelist
        } else {
            attentionLevel = .stranger
        }
        let replyWindow = contactEntry?.replyWindowMinutes ?? 120

        // Overdue calculation
        let ageMinutes = Int(Date().timeIntervalSince(
            Date(timeIntervalSince1970: Double(triggerMessage.createTime))
        ) / 60)
        let isOverdue = ageMinutes >= replyWindow
        let overdueMinutes = max(0, ageMinutes - replyWindow)

        // Weekly interaction count + trend
        let weeklyCount = recentMessages.count  // simplified; full impl would query 7 days
        let trend: InteractionTrend = .stable   // simplified; full impl uses chatTrend

        // Related data
        let commitments = store.loadCommitments(chatUsername: chatUsername, status: .pending)
        let asks = store.loadPendingAsks(status: .pending)
            .filter { $0.chatUsername == chatUsername }

        // Group context
        let isGroup = chatUsername.contains("@chatroom")
        let mentionedMe = MessageHelpers.isAtMe(text, myUsername: myUsername)
        let groupContext: [MessageInfo]?
        if isGroup && mentionedMe {
            // Get messages before the @mention for context
            let allRecent = (try? reader.getMessages(chatUsername: chatUsername, limit: windowSize + 10)) ?? []
            let mentionIndex = allRecent.firstIndex(where: { $0.localId == triggerMessage.localId }) ?? 0
            let startIndex = max(0, mentionIndex + 1)  // messages before mention (older)
            let endIndex = min(startIndex + 10, allRecent.count)
            groupContext = Array(allRecent[startIndex..<endIndex])
        } else {
            groupContext = nil
        }

        // Message signals
        let urgentKeywords = ["紧急", "尽快", "ASAP", "马上", "立即", "截止", "deadline"]
        let askSignals = ["?", "？", "麻烦", "请", "帮忙", "发我", "确认", "看看"]
        let hasUrgent = urgentKeywords.contains { text.localizedCaseInsensitiveContains($0) }
        let hasAsk = askSignals.contains { text.contains($0) }

        // Media detection
        let mediaType = detectMediaType(baseType: triggerMessage.baseType)
        // Image file path extraction is Phase B (requires WeChat file system mapping)
        let mediaFilePath: String? = nil
        let mediaContext = mediaType != nil
            ? Array(recentMessages.filter { $0.baseType == 1 }.prefix(5))  // text messages before media
            : []

        // Link content
        let linkTitle: String? = nil    // Will be extracted from XML in Phase B
        let linkDesc: String? = nil
        let linkURL: String? = nil
        let linkBody: String? = nil

        return InboxContext(
            triggerMessage: triggerMessage,
            triggerMessageText: text,
            recentMessages: recentMessages,
            myLastReply: myLastReply,
            myLastReplyText: myLastReply?.text,
            timeSinceMyLastReply: timeSinceMyLastReply,
            senderRole: role,
            senderAttentionLevel: attentionLevel,
            senderReplyWindow: replyWindow,
            isOverdue: isOverdue,
            overdueMinutes: overdueMinutes,
            weeklyInteractionCount: weeklyCount,
            weeklyTrend: trend,
            avgResponseTimeMinutes: 0,  // Phase 2
            pendingCommitments: commitments,
            pendingAsks: asks,
            isGroupChat: isGroup,
            mentionedMe: mentionedMe,
            groupRecentContext: groupContext,
            hasUrgentKeyword: hasUrgent,
            hasAskSignal: hasAsk,
            inboundCountSinceMyLastReply: inboundSinceReply,
            mediaType: mediaType,
            mediaFilePath: mediaFilePath,
            mediaContextMessages: mediaContext,
            linkTitle: linkTitle,
            linkDescription: linkDesc,
            linkURL: linkURL,
            linkBodyText: linkBody
        )
    }

    private static func detectMediaType(baseType: Int) -> DetectedMediaType? {
        switch baseType {
        case 3:  return .image
        case 34: return .voice
        case 43: return .video
        case 47: return .sticker
        case 48: return .location
        case 49: return .link       // app message (link/file/mini program)
        default: return nil         // text (1) or other
        }
    }
}
```

- [ ] **Step 4: Handle missing methods**

Check if `store.loadCommitments(chatUsername:status:)` exists. If not, the builder may need to use existing `store.loadPendingAsks()` and filter. Also check if `MessageInfo` has a `baseType` field (from the exploration, it's called `baseType: Int`).

Adapt the code to match actual API signatures found in the codebase.

- [ ] **Step 5: Run tests**

Run: `swift test --filter InboxContextBuilderTests 2>&1 | tail -5`
Expected: All pass.

Run: `swift build 2>&1 | grep -E "error:|Build complete"`
Expected: `Build complete!`

- [ ] **Step 6: Commit**

```bash
git add Sources/WeChatHUD/Services/InboxContextBuilder.swift Tests/WeChatHUDTests/InboxContextBuilderTests.swift
git commit -m "feat: add InboxContextBuilder — algorithm layer for inbox data extraction"
```

---

### Task 10: Code Cleanup — Dead Files and Shortcuts

**Files:**
- Delete: `Sources/WeChatHUD/Views/CompactBarView.swift`
- Delete: `Sources/WeChatHUD/Views/ExtendedBarView.swift`
- Modify: `Sources/WeChatHUD/App/AppDelegate.swift` (remove Cmd+1-5)
- Modify: `Sources/WeChatHUD/Views/OnboardingView.swift` (update text)

- [ ] **Step 1: Delete dead view files**

```bash
git rm Sources/WeChatHUD/Views/CompactBarView.swift
git rm Sources/WeChatHUD/Views/ExtendedBarView.swift
```

- [ ] **Step 2: Remove Cmd+1-5 keyboard shortcuts**

In `Sources/WeChatHUD/App/AppDelegate.swift`, find `handleKeyDown` and replace the tab-switching cases:

```swift
@MainActor
private func handleKeyDown(_ event: NSEvent) -> Bool {
    // Esc → collapse to compact
    if event.keyCode == 53 {
        panelState.collapse()
        return true
    }

    guard event.modifierFlags.contains(.command) else { return false }

    switch event.charactersIgnoringModifiers {
    case ",":
        panelState.showDetail()
        return true
    case "r":
        Task { await monitor.manualRefresh() }
        return true
    default:
        return false
    }
}
```

Check if `monitor.manualRefresh()` exists. If not, use the existing scan trigger mechanism (e.g., `monitor.scan()` or similar). If no public scan method exists, skip the Cmd+R for now.

- [ ] **Step 3: Update onboarding text**

In `Sources/WeChatHUD/Views/OnboardingView.swift`, find line 169:

```swift
// BEFORE:
featureRow("⌨️", "快捷键", "Esc 折叠, Cmd+1-5 切换标签")

// AFTER:
featureRow("⌨️", "快捷键", "Esc 折叠, Cmd+, 设置, Cmd+R 刷新")
```

- [ ] **Step 4: Verify build**

Run: `swift build 2>&1 | grep -E "error:|Build complete"`

- [ ] **Step 5: Run all tests**

Run: `swift test 2>&1 | grep -E "Executed.*tests|passed|failed"`

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "chore: remove dead CompactBarView/ExtendedBarView, update shortcuts"
```

---

### Task 11: Final Verification

- [ ] **Step 1: Clean build**

Run: `swift build -c release 2>&1 | grep -E "error:|Build complete"`
Expected: `Build complete!`

- [ ] **Step 2: Full test suite**

Run: `swift test 2>&1 | grep -E "Executed.*tests"`
Expected: All tests pass (existing + new)

- [ ] **Step 3: Verify no AIClassifierConfig references remain**

Run: `grep -rn "AIClassifierConfig" Sources/ Tests/ --include="*.swift"`
Expected: Zero matches

- [ ] **Step 4: Verify loadClassifierConfig is gone**

Run: `grep -rn "loadClassifierConfig" Sources/ --include="*.swift"`
Expected: Zero matches

- [ ] **Step 5: Package and smoke test**

Run: `make app && open .build/WeChatHUD.app`
Verify app launches, shows compact bar, hover expands inbox, gear opens settings.

- [ ] **Step 6: Commit tag**

```bash
git commit --allow-empty -m "milestone: Plan A complete — backend infra ready for Plans B/C/D"
```
