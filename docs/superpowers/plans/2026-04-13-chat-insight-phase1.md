# ChatInsight Phase 1: Data Models + Analytics Engine

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the foundation layer — all Codable data models for ChatInsight results, plus the pure-algorithm `ChatInsightEngine` that computes statistics (message counts, silence detection, ignored messages, response times) without any AI calls.

**Architecture:** Data models go into a new `ChatInsightModels.swift` file (Models.swift is already large). `ChatInsightEngine` is a pure-function struct that takes `[MessageInfo]` and whitelist data, returns `ChatStatsData`. All logic is testable without AI, network, or database.

**Tech Stack:** Swift, Foundation. No UI, no AI, no database access in this phase.

**Spec:** `docs/superpowers/specs/2026-04-13-chat-insight-design.md`

---

## File Structure

| Action | File | Responsibility |
|--------|------|---------------|
| Create | `Sources/WeChatHUD/Data/ChatInsightModels.swift` | All Codable structs for insight results |
| Create | `Sources/WeChatHUD/Services/ChatInsightEngine.swift` | Pure algorithm: stats, silence detection, ignored messages |
| Create | `Tests/WeChatHUDTests/ChatInsightEngineTests.swift` | Tests for all engine computations |

---

### Task 1: Core result data models

**Files:**
- Create: `Sources/WeChatHUD/Data/ChatInsightModels.swift`

- [ ] **Step 1: Create ChatInsightModels.swift with all Codable structs**

```swift
// Sources/WeChatHUD/Data/ChatInsightModels.swift
import Foundation

// MARK: - Chat Insight Result (per-chat AI output)

struct ChatInsightResult: Codable {
    // Content
    let headline: String
    let topics: [TopicInsight]
    let decisions: [String]
    let actionItems: [InsightActionItem]

    // Relevance to me
    let mentionsMe: Int
    let waitingForMe: [WaitingItem]
    let myCommitments: [String]
    let needsMyAttention: Bool

    // Mood
    let overallMood: String
    let moodShift: MoodShift?
    let attitudes: [AttitudeSignal]?

    // Dark signals
    let toneChanges: [ToneChange]?
    let silentMembers: [SilentMember]?
    let recalledNotes: [RecalledNote]?
    let ignoredNotes: [IgnoredNote]?

    // Value
    let signalNoiseRatio: Double
    let decisionEfficiency: String
    let importanceToMe: ImportanceLevel

    // People (group)
    let participants: [ParticipantRole]?

    // Relationship (private)
    let relationshipSignal: String?
    let symmetry: Double?

    // Cross-chat
    let crossChatTopics: [String]?

    // Profile
    let insight: String
    let suggestion: String

    enum CodingKeys: String, CodingKey {
        case headline, topics, decisions
        case actionItems = "action_items"
        case mentionsMe = "mentions_me"
        case waitingForMe = "waiting_for_me"
        case myCommitments = "my_commitments"
        case needsMyAttention = "needs_my_attention"
        case overallMood = "overall_mood"
        case moodShift = "mood_shift"
        case attitudes
        case toneChanges = "tone_changes"
        case silentMembers = "silent_members"
        case recalledNotes = "recalled_notes"
        case ignoredNotes = "ignored_notes"
        case signalNoiseRatio = "signal_noise_ratio"
        case decisionEfficiency = "decision_efficiency"
        case importanceToMe = "importance_to_me"
        case participants
        case relationshipSignal = "relationship_signal"
        case symmetry
        case crossChatTopics = "cross_chat_topics"
        case insight, suggestion
    }
}

// MARK: - Sub-types

struct TopicInsight: Codable {
    let name: String
    let messageCount: Int
    let participantCount: Int
    let summary: String
    let status: String
    let myInvolvement: String?
    let attitudes: [String: String]?
    let crossChats: [String]?

    enum CodingKeys: String, CodingKey {
        case name
        case messageCount = "message_count"
        case participantCount = "participant_count"
        case summary, status
        case myInvolvement = "my_involvement"
        case attitudes
        case crossChats = "cross_chats"
    }
}

struct InsightActionItem: Codable {
    let what: String
    let who: String
    let deadline: String?
}

struct WaitingItem: Codable {
    let source: String
    let what: String
    let waitingHours: Double

    enum CodingKeys: String, CodingKey {
        case source, what
        case waitingHours = "waiting_hours"
    }
}

struct MoodShift: Codable {
    let from: String
    let to: String
    let trigger: String
    let time: String
}

struct AttitudeSignal: Codable {
    let person: String
    let topic: String
    let attitude: String
    let evidence: String
}

struct ToneChange: Codable {
    let person: String
    let change: String
    let interpretation: String
}

struct SilentMember: Codable {
    let name: String
    let usualDailyMessages: Int
    let todayMessages: Int
    let activeElsewhere: Bool
    let interpretation: String

    enum CodingKeys: String, CodingKey {
        case name
        case usualDailyMessages = "usual_daily_messages"
        case todayMessages = "today_messages"
        case activeElsewhere = "active_elsewhere"
        case interpretation
    }
}

struct RecalledNote: Codable {
    let person: String
    let originalContent: String?
    let context: String
    let replacement: String?
    let interpretation: String

    enum CodingKeys: String, CodingKey {
        case person
        case originalContent = "original_content"
        case context, replacement, interpretation
    }
}

struct IgnoredNote: Codable {
    let person: String
    let content: String
    let usualResponseRate: String
    let interpretation: String

    enum CodingKeys: String, CodingKey {
        case person, content
        case usualResponseRate = "usual_response_rate"
        case interpretation
    }
}

struct ImportanceLevel: Codable {
    let level: String
    let reason: String
}

struct ParticipantRole: Codable {
    let name: String
    let messageCount: Int
    let role: String
    let doing: String
    let attitudeToward: [String: String]?

    enum CodingKeys: String, CodingKey {
        case name
        case messageCount = "message_count"
        case role, doing
        case attitudeToward = "attitude_toward"
    }
}

// MARK: - Global Briefing (cross-chat AI output)

struct GlobalBriefing: Codable {
    let date: String
    let actionRequired: [ActionRequiredItem]
    let headline: String
    let stats: BriefingStats
    let crossTopics: [CrossTopic]
    let darkSignals: DarkSignals
    let overallMood: String
    let blindSpots: [String]
    let topSuggestion: String

    enum CodingKeys: String, CodingKey {
        case date
        case actionRequired = "action_required"
        case headline, stats
        case crossTopics = "cross_topics"
        case darkSignals = "dark_signals"
        case overallMood = "overall_mood"
        case blindSpots = "blind_spots"
        case topSuggestion = "top_suggestion"
    }
}

struct ActionRequiredItem: Codable {
    let source: String
    let what: String
    let waitingHours: Double
    let urgency: String

    enum CodingKeys: String, CodingKey {
        case source, what
        case waitingHours = "waiting_hours"
        case urgency
    }
}

struct CrossTopic: Codable {
    let name: String
    let chats: [String]
    let summary: String
    let conflict: String?
    let status: String
}

struct DarkSignals: Codable {
    let toneChanges: [ToneChange]
    let silences: [SilentMember]
    let recalls: [RecalledNote]
    let ignored: [IgnoredNote]
    let headline: String?

    enum CodingKeys: String, CodingKey {
        case toneChanges = "tone_changes"
        case silences, recalls, ignored, headline
    }
}

struct BriefingStats: Codable {
    let totalMessages: Int
    let myMessages: Int
    let activeGroups: Int
    let totalGroups: Int
    let activePrivateChats: Int
    let workRatio: Double

    enum CodingKeys: String, CodingKey {
        case totalMessages = "total_messages"
        case myMessages = "my_messages"
        case activeGroups = "active_groups"
        case totalGroups = "total_groups"
        case activePrivateChats = "active_private_chats"
        case workRatio = "work_ratio"
    }
}

// MARK: - Keyword Insight (search result)

struct KeywordInsight: Codable {
    let summary: String
    let status: String
    let chats: [String]
    let timeline: [TimelineEvent]
    let stakeholders: [Stakeholder]
    let perspectives: [Perspective]
    let conflicts: [String]
    let myPosition: String
    let risks: [String]
    let recommendation: String

    enum CodingKeys: String, CodingKey {
        case summary, status, chats, timeline, stakeholders
        case perspectives, conflicts
        case myPosition = "my_position"
        case risks, recommendation
    }
}

struct TimelineEvent: Codable {
    let date: String
    let event: String
}

struct Stakeholder: Codable {
    let name: String
    let role: String
    let attitude: String
    let evidence: String
}

struct Perspective: Codable {
    let chat: String
    let angle: String
}

// MARK: - Pure algorithm stats (no AI)

struct ChatStatsData {
    let chatUsername: String
    let chatName: String
    let isGroup: Bool
    let category: WhitelistCategory
    let messageCount: Int
    let myMessageCount: Int
    let participantCount: Int
    let messagesByHour: [Int]              // 24 slots
    let avgResponseTimeSeconds: Double
    let symmetryRatio: Double              // 1.0 = perfectly balanced
    let trend7d: Double                    // positive = growing
    let topSenders: [(name: String, count: Int)]
    let silentMembers: [(name: String, usualDaily: Int, today: Int)]
    let ignoredMessages: [(sender: String, text: String, time: Int)]
}
```

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded.

- [ ] **Step 3: Commit**

```bash
git add Sources/WeChatHUD/Data/ChatInsightModels.swift
git commit -m "feat(insight): add ChatInsight data models"
```

---

### Task 2: ChatInsightEngine — basic stats computation

**Files:**
- Create: `Sources/WeChatHUD/Services/ChatInsightEngine.swift`
- Create: `Tests/WeChatHUDTests/ChatInsightEngineTests.swift`

- [ ] **Step 1: Write tests for basic stats**

```swift
// Tests/WeChatHUDTests/ChatInsightEngineTests.swift
import XCTest
@testable import WeChatHUD

final class ChatInsightEngineTests: XCTestCase {

    private let selfUsername = "wxid_me"

    private func msg(_ sender: String, _ text: String, _ time: Int) -> MessageInfo {
        MessageInfo(
            id: UUID().uuidString,
            chatUsername: "test_chat",
            chatName: "Test",
            senderUsername: sender,
            senderName: sender,
            text: text,
            baseType: 1,
            subType: 0,
            createTime: time
        )
    }

    // MARK: - Message counts

    func testBasicStats_countsMessages() {
        let messages = [
            msg("wxid_me", "hello", 1000),
            msg("wxid_a", "hi", 1001),
            msg("wxid_b", "hey", 1002),
            msg("wxid_me", "sup", 1003),
        ]
        let stats = ChatInsightEngine.computeStats(
            messages: messages,
            selfUsername: selfUsername,
            chatUsername: "test_chat",
            chatName: "Test",
            isGroup: true,
            category: .work
        )
        XCTAssertEqual(stats.messageCount, 4)
        XCTAssertEqual(stats.myMessageCount, 2)
        XCTAssertEqual(stats.participantCount, 3)
    }

    // MARK: - Messages by hour

    func testMessagesByHour_correctSlots() {
        // 10:00 AM = hour 10
        let base = 1713000000  // some timestamp
        let hour10 = base - (base % 86400) + 10 * 3600  // 10:00 AM UTC
        let hour14 = base - (base % 86400) + 14 * 3600  // 2:00 PM UTC
        let messages = [
            msg("wxid_a", "morning", hour10),
            msg("wxid_a", "morning2", hour10 + 60),
            msg("wxid_b", "afternoon", hour14),
        ]
        let stats = ChatInsightEngine.computeStats(
            messages: messages, selfUsername: selfUsername,
            chatUsername: "test", chatName: "Test", isGroup: false, category: .work
        )
        XCTAssertEqual(stats.messagesByHour[10], 2)
        XCTAssertEqual(stats.messagesByHour[14], 1)
        XCTAssertEqual(stats.messagesByHour.reduce(0, +), 3)
    }

    // MARK: - Top senders

    func testTopSenders_sortedByCount() {
        let messages = [
            msg("wxid_a", "1", 1000),
            msg("wxid_a", "2", 1001),
            msg("wxid_a", "3", 1002),
            msg("wxid_b", "4", 1003),
            msg("wxid_b", "5", 1004),
            msg("wxid_c", "6", 1005),
        ]
        let stats = ChatInsightEngine.computeStats(
            messages: messages, selfUsername: selfUsername,
            chatUsername: "test", chatName: "Test", isGroup: true, category: .work
        )
        XCTAssertEqual(stats.topSenders[0].name, "wxid_a")
        XCTAssertEqual(stats.topSenders[0].count, 3)
        XCTAssertEqual(stats.topSenders[1].name, "wxid_b")
        XCTAssertEqual(stats.topSenders[1].count, 2)
    }

    // MARK: - Symmetry ratio

    func testSymmetry_balanced() {
        let messages = [
            msg("wxid_me", "hi", 1000),
            msg("wxid_a", "hey", 1001),
        ]
        let stats = ChatInsightEngine.computeStats(
            messages: messages, selfUsername: selfUsername,
            chatUsername: "test", chatName: "Test", isGroup: false, category: .life
        )
        XCTAssertEqual(stats.symmetryRatio, 1.0, accuracy: 0.01)
    }

    func testSymmetry_imbalanced() {
        let messages = [
            msg("wxid_me", "1", 1000),
            msg("wxid_me", "2", 1001),
            msg("wxid_me", "3", 1002),
            msg("wxid_a", "4", 1003),
        ]
        let stats = ChatInsightEngine.computeStats(
            messages: messages, selfUsername: selfUsername,
            chatUsername: "test", chatName: "Test", isGroup: false, category: .life
        )
        // me: 3, them: 1. ratio = min(3,1)/max(3,1) = 0.333
        XCTAssertEqual(stats.symmetryRatio, 0.333, accuracy: 0.01)
    }

    // MARK: - Empty input

    func testEmptyMessages_returnsZeros() {
        let stats = ChatInsightEngine.computeStats(
            messages: [], selfUsername: selfUsername,
            chatUsername: "test", chatName: "Test", isGroup: false, category: .other
        )
        XCTAssertEqual(stats.messageCount, 0)
        XCTAssertEqual(stats.myMessageCount, 0)
        XCTAssertEqual(stats.symmetryRatio, 1.0)
        XCTAssertEqual(stats.avgResponseTimeSeconds, 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ChatInsightEngineTests 2>&1 | tail -10`
Expected: Build error — `ChatInsightEngine` not found.

- [ ] **Step 3: Create ChatInsightEngine with computeStats**

```swift
// Sources/WeChatHUD/Services/ChatInsightEngine.swift
import Foundation

/// Pure-function analytics engine. No AI, no network, no database.
/// Takes messages and returns computed statistics.
enum ChatInsightEngine {

    /// Compute stats for a single chat's messages.
    static func computeStats(
        messages: [MessageInfo],
        selfUsername: String,
        chatUsername: String,
        chatName: String,
        isGroup: Bool,
        category: WhitelistCategory
    ) -> ChatStatsData {
        let messageCount = messages.count
        let myMessageCount = messages.filter { $0.senderUsername == selfUsername }.count
        let participants = Set(messages.map { $0.senderUsername })
        let participantCount = participants.count

        // Messages by hour
        var byHour = Array(repeating: 0, count: 24)
        for m in messages {
            let date = Date(timeIntervalSince1970: Double(m.createTime))
            let hour = Calendar.current.component(.hour, from: date)
            byHour[hour] += 1
        }

        // Top senders
        var senderCounts: [String: Int] = [:]
        for m in messages { senderCounts[m.senderName, default: 0] += 1 }
        let topSenders = senderCounts.sorted { $0.value > $1.value }
            .map { (name: $0.key, count: $0.value) }

        // Symmetry ratio (private chat: me vs them)
        let othersCount = messageCount - myMessageCount
        let symmetryRatio: Double
        if messageCount == 0 {
            symmetryRatio = 1.0
        } else {
            let minC = Double(min(myMessageCount, othersCount))
            let maxC = Double(max(myMessageCount, othersCount))
            symmetryRatio = maxC > 0 ? minC / maxC : 1.0
        }

        // Average response time (my responses to others)
        let avgResponse = computeAvgResponseTime(
            messages: messages, selfUsername: selfUsername
        )

        return ChatStatsData(
            chatUsername: chatUsername,
            chatName: chatName,
            isGroup: isGroup,
            category: category,
            messageCount: messageCount,
            myMessageCount: myMessageCount,
            participantCount: participantCount,
            messagesByHour: byHour,
            avgResponseTimeSeconds: avgResponse,
            symmetryRatio: symmetryRatio,
            trend7d: 0,  // requires historical data, filled later
            topSenders: topSenders,
            silentMembers: [],  // filled by detectSilence()
            ignoredMessages: []  // filled by detectIgnored()
        )
    }

    /// Average time between someone else's message and my next reply.
    private static func computeAvgResponseTime(
        messages: [MessageInfo],
        selfUsername: String
    ) -> Double {
        let sorted = messages.sorted { $0.createTime < $1.createTime }
        var responseTimes: [Double] = []
        var lastOtherTime: Int?

        for m in sorted {
            if m.senderUsername != selfUsername {
                lastOtherTime = m.createTime
            } else if let otherTime = lastOtherTime {
                let delta = Double(m.createTime - otherTime)
                if delta > 0 && delta < 86400 {  // within 24h
                    responseTimes.append(delta)
                }
                lastOtherTime = nil
            }
        }

        guard !responseTimes.isEmpty else { return 0 }
        return responseTimes.reduce(0, +) / Double(responseTimes.count)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ChatInsightEngineTests 2>&1 | tail -15`
Expected: 6 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/WeChatHUD/Services/ChatInsightEngine.swift Tests/WeChatHUDTests/ChatInsightEngineTests.swift
git commit -m "feat(insight): add ChatInsightEngine with basic stats computation"
```

---

### Task 3: Silence detection

**Files:**
- Modify: `Sources/WeChatHUD/Services/ChatInsightEngine.swift`
- Modify: `Tests/WeChatHUDTests/ChatInsightEngineTests.swift`

- [ ] **Step 1: Write tests for silence detection**

Add to `ChatInsightEngineTests.swift`:

```swift
    // MARK: - Silence detection

    func testDetectSilence_findsAbnormallySilent() {
        // Historical: wxid_a sends 10/day on average
        let historical: [String: Int] = ["wxid_a": 10, "wxid_b": 2]
        // Today: wxid_a sent only 1 message (< 30% of usual)
        let todayCounts: [String: Int] = ["wxid_a": 1, "wxid_b": 2]

        let silent = ChatInsightEngine.detectSilence(
            historicalDailyCounts: historical,
            todayCounts: todayCounts
        )
        XCTAssertEqual(silent.count, 1)
        XCTAssertEqual(silent[0].name, "wxid_a")
        XCTAssertEqual(silent[0].usualDaily, 10)
        XCTAssertEqual(silent[0].today, 1)
    }

    func testDetectSilence_normalActivityNotFlagged() {
        let historical: [String: Int] = ["wxid_a": 10]
        let todayCounts: [String: Int] = ["wxid_a": 8]

        let silent = ChatInsightEngine.detectSilence(
            historicalDailyCounts: historical,
            todayCounts: todayCounts
        )
        XCTAssertTrue(silent.isEmpty)
    }

    func testDetectSilence_completelySilent() {
        let historical: [String: Int] = ["wxid_a": 5]
        let todayCounts: [String: Int] = [:]

        let silent = ChatInsightEngine.detectSilence(
            historicalDailyCounts: historical,
            todayCounts: todayCounts
        )
        XCTAssertEqual(silent.count, 1)
        XCTAssertEqual(silent[0].today, 0)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ChatInsightEngineTests 2>&1 | tail -10`
Expected: Build error — `detectSilence` not found.

- [ ] **Step 3: Implement detectSilence**

Add to `ChatInsightEngine`:

```swift
    /// Detect members who are abnormally silent today.
    /// A member is "silent" if today's message count < 30% of their daily average.
    /// Requires at least 3 messages/day historical average to flag (avoid noise).
    static func detectSilence(
        historicalDailyCounts: [String: Int],
        todayCounts: [String: Int]
    ) -> [(name: String, usualDaily: Int, today: Int)] {
        var results: [(name: String, usualDaily: Int, today: Int)] = []
        for (name, usual) in historicalDailyCounts {
            guard usual >= 3 else { continue }  // skip low-activity members
            let today = todayCounts[name] ?? 0
            if Double(today) < Double(usual) * 0.3 {
                results.append((name: name, usualDaily: usual, today: today))
            }
        }
        return results.sorted { $0.usualDaily > $1.usualDaily }
    }
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter ChatInsightEngineTests 2>&1 | tail -10`
Expected: 9 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/WeChatHUD/Services/ChatInsightEngine.swift Tests/WeChatHUDTests/ChatInsightEngineTests.swift
git commit -m "feat(insight): add silence detection to ChatInsightEngine"
```

---

### Task 4: Ignored message detection

**Files:**
- Modify: `Sources/WeChatHUD/Services/ChatInsightEngine.swift`
- Modify: `Tests/WeChatHUDTests/ChatInsightEngineTests.swift`

- [ ] **Step 1: Write tests for ignored message detection**

Add to `ChatInsightEngineTests.swift`:

```swift
    // MARK: - Ignored message detection

    func testDetectIgnored_findsUnrepliedMessages() {
        // A says something, then B and C talk but don't respond to A
        let messages = [
            msg("wxid_a", "我觉得方案一更好", 1000),
            msg("wxid_b", "今天天气不错", 1200),       // different topic
            msg("wxid_c", "确实", 1300),               // responds to B
            msg("wxid_b", "明天开会", 1400),
        ]
        let ignored = ChatInsightEngine.detectIgnored(
            messages: messages,
            windowSeconds: 600  // 10 min window
        )
        XCTAssertEqual(ignored.count, 1)
        XCTAssertEqual(ignored[0].sender, "wxid_a")
        XCTAssertEqual(ignored[0].text, "我觉得方案一更好")
    }

    func testDetectIgnored_repliedNotFlagged() {
        let messages = [
            msg("wxid_a", "方案一如何", 1000),
            msg("wxid_b", "我同意", 1100),
        ]
        let ignored = ChatInsightEngine.detectIgnored(
            messages: messages,
            windowSeconds: 600
        )
        XCTAssertTrue(ignored.isEmpty)
    }

    func testDetectIgnored_lastMessageNotFlagged() {
        // Last message in the window shouldn't be flagged (no time to respond)
        let messages = [
            msg("wxid_a", "有人在吗", 1000),
        ]
        let ignored = ChatInsightEngine.detectIgnored(
            messages: messages,
            windowSeconds: 600
        )
        XCTAssertTrue(ignored.isEmpty)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ChatInsightEngineTests 2>&1 | tail -10`
Expected: Build error — `detectIgnored` not found.

- [ ] **Step 3: Implement detectIgnored**

Add to `ChatInsightEngine`:

```swift
    /// Detect messages that got no response within a time window.
    /// A message is "ignored" if:
    /// 1. It's not the last message in the conversation
    /// 2. No one else replied within `windowSeconds`
    /// 3. Subsequent messages exist (the conversation continued without responding)
    static func detectIgnored(
        messages: [MessageInfo],
        windowSeconds: Int = 600  // 10 minutes
    ) -> [(sender: String, text: String, time: Int)] {
        let sorted = messages.sorted { $0.createTime < $1.createTime }
        guard sorted.count >= 2 else { return [] }

        var results: [(sender: String, text: String, time: Int)] = []

        for i in 0..<(sorted.count - 1) {
            let current = sorted[i]
            let nextMsg = sorted[i + 1]

            // Check if someone different responded within the window
            let hasResponse = nextMsg.senderUsername != current.senderUsername
                && (nextMsg.createTime - current.createTime) <= windowSeconds

            // If no direct response but conversation continued
            if !hasResponse {
                // Check if any message from a different person arrives within window
                var responded = false
                for j in (i + 1)..<sorted.count {
                    let future = sorted[j]
                    if future.createTime - current.createTime > windowSeconds { break }
                    if future.senderUsername != current.senderUsername {
                        responded = true
                        break
                    }
                }
                // Conversation continued past the window but nobody responded
                let conversationContinued = sorted.last!.createTime - current.createTime > windowSeconds
                if !responded && conversationContinued {
                    results.append((
                        sender: current.senderName,
                        text: current.text,
                        time: current.createTime
                    ))
                }
            }
        }

        return results
    }
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter ChatInsightEngineTests 2>&1 | tail -10`
Expected: 12 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/WeChatHUD/Services/ChatInsightEngine.swift Tests/WeChatHUDTests/ChatInsightEngineTests.swift
git commit -m "feat(insight): add ignored message detection to ChatInsightEngine"
```

---

### Task 5: Response time and sorting score

**Files:**
- Modify: `Sources/WeChatHUD/Services/ChatInsightEngine.swift`
- Modify: `Tests/WeChatHUDTests/ChatInsightEngineTests.swift`

- [ ] **Step 1: Write tests for response time and sorting**

Add to `ChatInsightEngineTests.swift`:

```swift
    // MARK: - Response time

    func testAvgResponseTime_calculated() {
        let messages = [
            msg("wxid_a", "question", 1000),
            msg("wxid_me", "answer", 1060),  // 60s response
            msg("wxid_a", "followup", 1200),
            msg("wxid_me", "reply", 1320),   // 120s response
        ]
        let stats = ChatInsightEngine.computeStats(
            messages: messages, selfUsername: selfUsername,
            chatUsername: "test", chatName: "Test", isGroup: false, category: .work
        )
        // avg = (60 + 120) / 2 = 90
        XCTAssertEqual(stats.avgResponseTimeSeconds, 90, accuracy: 0.1)
    }

    // MARK: - Sorting score

    func testSortingScore_workHigherThanLife() {
        let workStats = ChatStatsData(
            chatUsername: "w", chatName: "Work", isGroup: true, category: .work,
            messageCount: 10, myMessageCount: 0, participantCount: 1,
            messagesByHour: Array(repeating: 0, count: 24),
            avgResponseTimeSeconds: 0, symmetryRatio: 1.0, trend7d: 0,
            topSenders: [], silentMembers: [], ignoredMessages: []
        )
        let lifeStats = ChatStatsData(
            chatUsername: "l", chatName: "Life", isGroup: true, category: .life,
            messageCount: 10, myMessageCount: 0, participantCount: 1,
            messagesByHour: Array(repeating: 0, count: 24),
            avgResponseTimeSeconds: 0, symmetryRatio: 1.0, trend7d: 0,
            topSenders: [], silentMembers: [], ignoredMessages: []
        )
        XCTAssertGreaterThan(
            ChatInsightEngine.sortingScore(workStats, hasActionForMe: false),
            ChatInsightEngine.sortingScore(lifeStats, hasActionForMe: false)
        )
    }

    func testSortingScore_actionBoostsScore() {
        let stats = ChatStatsData(
            chatUsername: "t", chatName: "Test", isGroup: true, category: .other,
            messageCount: 1, myMessageCount: 0, participantCount: 1,
            messagesByHour: Array(repeating: 0, count: 24),
            avgResponseTimeSeconds: 0, symmetryRatio: 1.0, trend7d: 0,
            topSenders: [], silentMembers: [], ignoredMessages: []
        )
        let withAction = ChatInsightEngine.sortingScore(stats, hasActionForMe: true)
        let withoutAction = ChatInsightEngine.sortingScore(stats, hasActionForMe: false)
        XCTAssertGreaterThan(withAction, withoutAction)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ChatInsightEngineTests 2>&1 | tail -10`
Expected: Build error — `sortingScore` not found.

- [ ] **Step 3: Implement sortingScore**

Add to `ChatInsightEngine`:

```swift
    /// Sorting score for ordering chats in the briefing.
    /// Higher = shown first.
    /// Formula: categoryWeight × 1000 + messageCount × 10 + hasAction × 500
    static func sortingScore(_ stats: ChatStatsData, hasActionForMe: Bool) -> Int {
        let categoryWeight: Int
        switch stats.category {
        case .work: categoryWeight = 3
        case .life: categoryWeight = 2
        case .other: categoryWeight = 1
        }
        return categoryWeight * 1000
            + stats.messageCount * 10
            + (hasActionForMe ? 500 : 0)
    }
```

- [ ] **Step 4: Run all tests**

Run: `swift test --filter ChatInsightEngineTests 2>&1 | tail -15`
Expected: 15 tests PASS.

- [ ] **Step 5: Run full test suite for regressions**

Run: `swift test 2>&1 | grep -E "passed|failed"`
Expected: All tests pass (existing + 15 new).

- [ ] **Step 6: Commit**

```bash
git add Sources/WeChatHUD/Services/ChatInsightEngine.swift Tests/WeChatHUDTests/ChatInsightEngineTests.swift
git commit -m "feat(insight): add sorting score and response time to ChatInsightEngine"
```
