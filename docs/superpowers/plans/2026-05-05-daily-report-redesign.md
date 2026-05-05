# Daily Report Tab Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Take the daily-report tab from "unusable" (white-on-white text in Settings + nested ScrollViews) to a productized "调度表" with optional per-row AI annotations.

**Architecture:** Single SwiftUI view rendered into both HUD (dark) and Settings (light) surfaces, using semantic colors and an external ScrollView. Information architecture re-grouped by deadline buckets. M2 layer adds per-action AI reason/next-step strings produced by a new actor, cached in a new SQLite table, and rendered only on urgent rows.

**Tech Stack:** SwiftUI / AppKit / Swift Concurrency (actor + async let) / SQLite3 (raw bindings via existing `HUDStore` extensions) / XCTest.

**Spec:** [`docs/superpowers/specs/2026-05-05-daily-report-redesign-design.md`](../specs/2026-05-05-daily-report-redesign-design.md)

---

## File Structure

### M1 (PR-A) — UI baseline only, no schema changes

| File | Action | Responsibility |
| --- | --- | --- |
| `Sources/WeChatHUD/Data/DailyReportPresentationPolicy.swift` | Modify | Add deadline-bucket partitioning (`activeToday / activeThisWeek / activeLater`); keep `activeActions` for backward compat |
| `Sources/WeChatHUD/Views/DailyReportCommandCenterView.swift` | Modify | Remove inner ScrollView; replace all `Color.white.opacity(...)` with semantic tokens; render 3-bucket active section; default-visible row buttons; `DisclosureGroup` for completed/highlights/risks |
| `Sources/WeChatHUD/Views/DailyReportTabView.swift` | Modify | Add HUD-path `.preferredColorScheme(.dark)` wrapper |
| `Tests/WeChatHUDTests/DailyReportPresentationPolicyTests.swift` | Modify | Add bucket-grouping tests |

### M2 (PR-B) — data layer

| File | Action | Responsibility |
| --- | --- | --- |
| `Sources/WeChatHUD/Data/DailyReportActionInsight.swift` | Create | Insight model + Codable |
| `Sources/WeChatHUD/Data/HUDStore+DailyReport.swift` | Modify | Migration adds `daily_report_action_insights` table; add `upsertActionInsight(_:)` / `loadActionInsights(dateKey:)` |
| `Tests/WeChatHUDTests/HUDStoreDailyReportTests.swift` | Modify | Insight CRUD round-trip |

### M2 (PR-C) — generator + wiring + UI

| File | Action | Responsibility |
| --- | --- | --- |
| `Sources/WeChatHUD/Resources/prompts/daily_report_action_insights_v1.txt` | Create | AI prompt template (note lowercase `prompts/`) |
| `Sources/WeChatHUD/Services/AIDailyReportActionInsightGenerator.swift` | Create | Actor: format prompt, call AI, parse JSON, write store, audit |
| `Sources/WeChatHUD/Services/ChatMonitor.swift` | Modify | Inject generator; `@Published var dailyReportActionInsights`; `loadDailyReport` runs both generators with `async let` |
| `Sources/WeChatHUD/Data/DailyReportPresentationPolicy.swift` | Modify | `buildViewModel(from:commandStates:insights:)` overload; `CommandCenterViewModel.actionInsights` |
| `Sources/WeChatHUD/Views/DailyReportCommandCenterView.swift` | Modify | Render `aiReason` / `aiNextStep` on urgent cards |
| `Tests/WeChatHUDTests/AIDailyReportActionInsightGeneratorTests.swift` | Create | Format / parse / cache hit / partial match |
| `Tests/WeChatHUDTests/DailyReportPresentationPolicyTests.swift` | Modify | Insight-injection assertions |

### M2 (PR-D) — config toggle

| File | Action | Responsibility |
| --- | --- | --- |
| `Sources/WeChatHUD/Data/Models.swift` | Modify | Add `AIConfig.dailyReportActionInsightsEnabled` |
| `Sources/WeChatHUD/Services/ChatMonitor.swift` | Modify | Skip insight generation when flag is `false` |
| `Sources/WeChatHUD/Views/Settings/AISettingsView.swift` | Modify | Toggle row + persistence |

---

## PR-A · M1 Rendering Baseline

**Goal:** The page is readable in both light Settings and dark HUD, has no nested scroll containers, and groups待处理 by deadline. No new schema, no AI changes.

### Task 1: Add deadline buckets to `CommandCenterViewModel`

**Files:**
- Modify: `Sources/WeChatHUD/Data/DailyReportPresentationPolicy.swift`
- Test: `Tests/WeChatHUDTests/DailyReportPresentationPolicyTests.swift`

- [ ] **Step 1: Write the failing test for bucket partitioning**

Add to `Tests/WeChatHUDTests/DailyReportPresentationPolicyTests.swift`, before the closing brace at line 169:

```swift
    func testActiveActionsBucketedByDeadline() {
        let cal = Calendar.current
        let now = Date()
        let endOfToday = cal.date(bySettingHour: 23, minute: 59, second: 59, of: now)!
        let inThreeDays = cal.date(byAdding: .day, value: 3, to: now)!
        let inTwentyDays = cal.date(byAdding: .day, value: 20, to: now)!

        let actions = [
            makeAction(content: "Today",     urgency: .medium, deadline: endOfToday),
            makeAction(content: "ThisWeek",  urgency: .medium, deadline: inThreeDays),
            makeAction(content: "Later",     urgency: .medium, deadline: inTwentyDays),
            makeAction(content: "NoDate",    urgency: .low,    deadline: nil),
        ]
        let report = makeReport(actions: actions, risks: [], highlights: [])
        let vm = DailyReportPresentationPolicy.buildViewModel(from: report)

        XCTAssertEqual(vm.activeToday.map(\.content),    ["Today"])
        XCTAssertEqual(vm.activeThisWeek.map(\.content), ["ThisWeek"])
        XCTAssertEqual(Set(vm.activeLater.map(\.content)), ["Later", "NoDate"])
    }

    func testActiveActionsBackwardCompatField() {
        let cal = Calendar.current
        let inOneDay = cal.date(byAdding: .day, value: 1, to: Date())!
        let actions = [makeAction(content: "X", urgency: .medium, deadline: inOneDay)]
        let report = makeReport(actions: actions, risks: [], highlights: [])
        let vm = DailyReportPresentationPolicy.buildViewModel(from: report)

        // Existing callers reading vm.activeActions must still see the union.
        XCTAssertEqual(vm.activeActions.count, 1)
    }
```

Update the existing `makeAction` helper (line 159 of the same file) to take an optional deadline:

```swift
    private func makeAction(content: String, urgency: ActionUrgency, deadline: Date? = nil) -> DailyReportAction {
        DailyReportAction(
            content: content,
            type: .todo,
            urgency: urgency,
            deadline: deadline,
            sourceChatName: "Test",
            sourceChatUsername: "wxid_test",
            relatedID: UUID().uuidString
        )
    }
```

- [ ] **Step 2: Run tests, verify the new ones fail**

```bash
swift test --filter DailyReportPresentationPolicyTests
```
Expected: `testActiveActionsBucketedByDeadline` and `testActiveActionsBackwardCompatField` fail with "value of type ... has no member 'activeToday'". Existing tests still pass.

- [ ] **Step 3: Add bucket fields to `CommandCenterViewModel`**

In `Sources/WeChatHUD/Data/DailyReportPresentationPolicy.swift`, edit the `CommandCenterViewModel` struct (lines 13-26):

```swift
    struct CommandCenterViewModel: Sendable {
        let progress: DailyReportProgressMetrics
        let urgentActions: [DailyReportAction]
        let activeActions: [DailyReportAction]
        let activeToday: [DailyReportAction]
        let activeThisWeek: [DailyReportAction]
        let activeLater: [DailyReportAction]
        let completedActions: [DailyReportAction]
        let highlights: [DailyReportHighlight]
        let activeRisks: [DailyReportRisk]
        let dismissedRisks: [DailyReportRisk]
        let narrative: String?
        let tomorrowFocus: String?
        let wechatDraft: String?
        let isAIEnhanced: Bool
        let date: Date
    }
```

- [ ] **Step 4: Implement bucket partitioning in `buildViewModel`**

Inside `buildViewModel(from:commandStates:)`, after the existing `active.sort { ... }` block (around line 71), insert:

```swift
        // Partition `active` into deadline buckets.
        let cal = Calendar.current
        let now = Date()
        let endOfToday = cal.date(bySettingHour: 23, minute: 59, second: 59, of: now) ?? now
        let endOfWeek = cal.date(byAdding: .day, value: 7, to: cal.startOfDay(for: now)) ?? now

        var bucketToday: [DailyReportAction] = []
        var bucketWeek: [DailyReportAction] = []
        var bucketLater: [DailyReportAction] = []
        for a in active {
            guard let d = a.deadline else { bucketLater.append(a); continue }
            if d <= endOfToday { bucketToday.append(a) }
            else if d <= endOfWeek { bucketWeek.append(a) }
            else { bucketLater.append(a) }
        }
```

Then update the `return CommandCenterViewModel(...)` call (currently lines 108-121) to pass the new fields:

```swift
        return CommandCenterViewModel(
            progress: progress,
            urgentActions: urgent,
            activeActions: active,
            activeToday: bucketToday,
            activeThisWeek: bucketWeek,
            activeLater: bucketLater,
            completedActions: completed,
            highlights: report.highlights,
            activeRisks: activeRisks,
            dismissedRisks: dismissedRisks,
            narrative: report.narrative,
            tomorrowFocus: report.tomorrowFocus,
            wechatDraft: report.wechatDraft,
            isAIEnhanced: report.status == .aiEnhanced,
            date: report.date
        )
```

- [ ] **Step 5: Run tests, verify all pass**

```bash
swift test --filter DailyReportPresentationPolicyTests
```
Expected: PASS, including the two new tests and all existing ones.

- [ ] **Step 6: Commit**

```bash
git add Sources/WeChatHUD/Data/DailyReportPresentationPolicy.swift \
        Tests/WeChatHUDTests/DailyReportPresentationPolicyTests.swift
git commit -m "feat(daily-report): partition active actions by deadline buckets"
```

---

### Task 2: Replace `.white.opacity(...)` with semantic colors throughout the view

**Files:**
- Modify: `Sources/WeChatHUD/Views/DailyReportCommandCenterView.swift`

This task is mechanical: change foreground / background tokens. No behavior change.

- [ ] **Step 1: Run a baseline grep to confirm scope**

```bash
grep -c "Color\.white" Sources/WeChatHUD/Views/DailyReportCommandCenterView.swift
```
Expected: a number ≥ 30. Note it; you'll re-grep after changes and expect zero.

- [ ] **Step 2: Replace foreground white-text usages with `.primary` / `.secondary`**

The mapping rules:

| Old | New |
| --- | --- |
| `.foregroundColor(.white)` (no opacity) | `.foregroundColor(.primary)` |
| `.foregroundColor(.white.opacity(0.85))` and stronger (≥ 0.7) | `.foregroundColor(.primary)` |
| `.foregroundColor(.white.opacity(0.6))` to `(0.4)` | `.foregroundColor(.secondary)` |
| `.foregroundColor(.white.opacity(< 0.4))` | `.foregroundColor(Color.primary.opacity(0.4))` |

For container fills:

| Old | New |
| --- | --- |
| `.background(Color.white.opacity(0.04))` / `(0.045)` / `(0.05)` / `(0.06)` | `.background(Color(NSColor.controlBackgroundColor))` |
| `.background(Color.white.opacity(0.08))` (button hover) | `.background(Color.primary.opacity(0.08))` |
| `.fill(Color.white.opacity(0.08))` (progress track) | `.fill(Color.primary.opacity(0.12))` |
| `.background(isHovered ? Color.white.opacity(0.06) : Color.clear)` | `.background(isHovered ? Color.primary.opacity(0.06) : Color.clear)` |
| `Divider().background(Color.white.opacity(0.07))` / `(0.06)` / `(0.08)` | `Divider().background(Color.primary.opacity(0.08))` |

Walk through the file with `Edit` calls. The accent / urgency colors (`.red`, `.orange`, `.yellow`, `.green`, `.cyan`) keep their `.opacity(...)` modifiers — only `.white` foregrounds and white-tinted neutral backgrounds change.

Use `replace_all: true` only for exact strings that appear identically. For semantically different uses (e.g. button-hover vs container background) edit one at a time.

- [ ] **Step 3: Verify no `Color.white` references remain**

```bash
grep -n "Color\.white\|\.white\.opacity" Sources/WeChatHUD/Views/DailyReportCommandCenterView.swift
```
Expected: no matches.

- [ ] **Step 4: Build**

```bash
swift build
```
Expected: success.

- [ ] **Step 5: Commit**

```bash
git add Sources/WeChatHUD/Views/DailyReportCommandCenterView.swift
git commit -m "fix(daily-report): use semantic colors so view renders on light Settings background"
```

---

### Task 3: Remove inner ScrollView from `DailyReportCommandCenterView`

**Files:**
- Modify: `Sources/WeChatHUD/Views/DailyReportCommandCenterView.swift`

Both callers (`SettingsView.swift:204`, `ExtendedTabsView.swift:74`) already wrap the view in their own `ScrollView`. The inner one in `content(vm:report:)` causes a double-scroll layout bug.

- [ ] **Step 1: Replace the `ScrollView` block in `content`**

Find the `private func content(vm:report:)` method (around line 30). Replace the outer `ScrollView { ... }` with a plain `VStack`. The body becomes:

```swift
    private func content(vm: DailyReportPresentationPolicy.CommandCenterViewModel, report: DailyReport) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            progressCard(vm.progress)
            divider

            if !vm.urgentActions.isEmpty {
                sectionHeader("🔴 紧急待处理", count: vm.urgentActions.count)
                ForEach(vm.urgentActions) { action in
                    actionCard(action, isUrgent: true)
                }
                divider
            }

            if !vm.activeActions.isEmpty {
                sectionHeader("📋 待处理", count: vm.activeActions.count)
                ForEach(vm.activeActions) { action in
                    actionCard(action, isUrgent: false)
                }
                divider
            }

            if !vm.completedActions.isEmpty {
                completedSection(vm.completedActions)
                divider
            }

            if !vm.highlights.isEmpty {
                sectionHeader("📌 今日高亮", count: vm.highlights.count)
                ForEach(vm.highlights) { highlight in
                    highlightCard(highlight)
                }
                divider
            }

            if !vm.activeRisks.isEmpty {
                sectionHeader("⚠️ 风险与异常", count: vm.activeRisks.count)
                ForEach(vm.activeRisks) { risk in
                    riskCard(risk)
                }
                divider
            }

            if let narrative = vm.narrative, !narrative.isEmpty {
                insightCard(narrative: narrative, tomorrow: vm.tomorrowFocus)
                divider
            }

            if let draft = vm.wechatDraft, !draft.isEmpty {
                draftCard(draft: draft)
            }
        }
        .padding(.bottom, 8)
    }
```

(The change from the previous file is exactly: outer `ScrollView { ... }` + inner `VStack` → bare `VStack`. Bucket-aware sections come in Task 4 — this task only flattens the scroll wrapper.)

- [ ] **Step 2: Build**

```bash
swift build
```
Expected: success.

- [ ] **Step 3: Commit**

```bash
git add Sources/WeChatHUD/Views/DailyReportCommandCenterView.swift
git commit -m "fix(daily-report): drop nested ScrollView (caller already provides one)"
```

---

### Task 4: Render待处理 as three deadline buckets

**Files:**
- Modify: `Sources/WeChatHUD/Views/DailyReportCommandCenterView.swift`

- [ ] **Step 1: Replace the single待处理 block**

In `content(vm:report:)`, replace the existing待处理 block with three sub-blocks. Replace this:

```swift
            if !vm.activeActions.isEmpty {
                sectionHeader("📋 待处理", count: vm.activeActions.count)
                ForEach(vm.activeActions) { action in
                    actionCard(action, isUrgent: false)
                }
                divider
            }
```

with:

```swift
            if !vm.activeToday.isEmpty {
                sectionHeader("📋 待处理 · 今天到期", count: vm.activeToday.count)
                ForEach(vm.activeToday) { action in
                    actionCard(action, isUrgent: false)
                }
                divider
            }

            if !vm.activeThisWeek.isEmpty {
                sectionHeader("📋 待处理 · 本周到期", count: vm.activeThisWeek.count)
                ForEach(vm.activeThisWeek) { action in
                    actionCard(action, isUrgent: false)
                }
                divider
            }

            if !vm.activeLater.isEmpty {
                sectionHeader("📋 待处理 · 之后 / 无期限", count: vm.activeLater.count)
                ForEach(vm.activeLater) { action in
                    actionCard(action, isUrgent: false)
                }
                divider
            }
```

- [ ] **Step 2: Build**

```bash
swift build
```
Expected: success.

- [ ] **Step 3: Commit**

```bash
git add Sources/WeChatHUD/Views/DailyReportCommandCenterView.swift
git commit -m "feat(daily-report): split active section into today/this-week/later buckets"
```

---

### Task 5: Make action buttons default-visible on rows

**Files:**
- Modify: `Sources/WeChatHUD/Views/DailyReportCommandCenterView.swift`

Hover-only is wrong for HUD floats with hover-dismiss; users need one-glance affordance.

- [ ] **Step 1: Pull the action buttons out of the `if isHovered` branch**

Find `actionCard(_:isUrgent:)` (around line 182). Remove the `if isHovered { ... }` wrapper around the two buttons; render them unconditionally. The hover state now only adjusts subtle background highlight.

Replace:

```swift
            if isHovered {
                HStack(spacing: 4) {
                    Button(action: { monitor.markDailyReportActionDone(action) }) { ... }
                    Button(action: { WeChatLauncher.openChat(named: action.sourceChatName) }) { ... }
                }
            }
```

with:

```swift
            HStack(spacing: 4) {
                Button(action: { monitor.markDailyReportActionDone(action) }) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.green)
                        .frame(width: 22, height: 20)
                        .background(Color.green.opacity(0.12))
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help("标记完成")

                Button(action: { WeChatLauncher.openChat(named: action.sourceChatName) }) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .frame(width: 22, height: 20)
                        .background(Color.primary.opacity(0.08))
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help("在微信中打开")
            }
            .opacity(isHovered ? 1.0 : 0.85)
```

The same `isHovered` state still drives the row's existing `.background(...)` highlight — keep that line as-is.

- [ ] **Step 2: Build**

```bash
swift build
```
Expected: success.

- [ ] **Step 3: Commit**

```bash
git add Sources/WeChatHUD/Views/DailyReportCommandCenterView.swift
git commit -m "feat(daily-report): always show row action buttons (hover only adjusts opacity)"
```

---

### Task 6: Wrap completed / highlights / risks sections in `DisclosureGroup`

**Files:**
- Modify: `Sources/WeChatHUD/Views/DailyReportCommandCenterView.swift`

The existing `completedSection` already collapses; we now also collapse highlights and risks for the調度 use case. Defaults: all collapsed.

- [ ] **Step 1: Add hover state for the new disclosures**

At the top of `DailyReportCommandCenterView`, alongside the existing `@State private var showCompleted = false`, add:

```swift
    @State private var showHighlights = false
    @State private var showRisks = false
```

- [ ] **Step 2: Wrap the highlights section**

In `content(vm:report:)`, replace the highlights block with a disclosure variant that mirrors `completedSection`:

```swift
            if !vm.highlights.isEmpty {
                highlightsSection(vm.highlights)
                divider
            }
```

and add this helper next to `completedSection`:

```swift
    private func highlightsSection(_ highlights: [DailyReportHighlight]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { showHighlights.toggle() }) {
                HStack(spacing: 4) {
                    Image(systemName: showHighlights ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text("📌 今日高亮")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text("\(highlights.count)")
                        .font(.system(size: 9))
                        .foregroundColor(Color.primary.opacity(0.4))
                        .monospacedDigit()
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 4)

            if showHighlights {
                ForEach(highlights) { highlight in
                    highlightCard(highlight)
                }
            }
        }
    }
```

- [ ] **Step 3: Wrap the risks section the same way**

Replace the risks block with:

```swift
            if !vm.activeRisks.isEmpty {
                risksSection(vm.activeRisks)
                divider
            }
```

and add:

```swift
    private func risksSection(_ risks: [DailyReportRisk]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { showRisks.toggle() }) {
                HStack(spacing: 4) {
                    Image(systemName: showRisks ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text("⚠️ 风险与异常")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text("\(risks.count)")
                        .font(.system(size: 9))
                        .foregroundColor(Color.primary.opacity(0.4))
                        .monospacedDigit()
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 4)

            if showRisks {
                ForEach(risks) { risk in
                    riskCard(risk)
                }
            }
        }
    }
```

- [ ] **Step 4: Build**

```bash
swift build
```
Expected: success.

- [ ] **Step 5: Commit**

```bash
git add Sources/WeChatHUD/Views/DailyReportCommandCenterView.swift
git commit -m "feat(daily-report): collapse completed/highlights/risks sections by default"
```

---

### Task 7: Force dark color scheme on the HUD path

**Files:**
- Modify: `Sources/WeChatHUD/Views/DailyReportTabView.swift`

The view is now neutral. HUD's black background needs `.primary` to compute as white — wrap only the HUD entry point.

- [ ] **Step 1: Add a HUD-specific wrapper view**

In `DailyReportTabView.swift`, at the end of the file (after the closing brace of `DailyReportTabView`), add:

```swift
struct DailyReportHUDTabView: View {
    var body: some View {
        DailyReportTabView()
            .preferredColorScheme(.dark)
    }
}
```

- [ ] **Step 2: Update HUD caller to use the wrapper**

In `Sources/WeChatHUD/Views/ExtendedTabsView.swift` at line 83, change:

```swift
                    case .dailyReport: DailyReportTabView()
```
to:

```swift
                    case .dailyReport: DailyReportHUDTabView()
```

Settings caller (`SettingsView.swift:217`) stays on `DailyReportTabView()` — it follows system color scheme.

- [ ] **Step 3: Build**

```bash
swift build
```
Expected: success.

- [ ] **Step 4: Commit**

```bash
git add Sources/WeChatHUD/Views/DailyReportTabView.swift \
        Sources/WeChatHUD/Views/ExtendedTabsView.swift
git commit -m "feat(daily-report): pin HUD path to dark color scheme"
```

---

### Task 8: Manual visual verification + screenshots

**Files:**
- Create: `docs/superpowers/specs/screenshots/2026-05-05-daily-report-light.png`
- Create: `docs/superpowers/specs/screenshots/2026-05-05-daily-report-dark.png`

This is the hard gate that the previous e2e missed.

- [ ] **Step 1: Build and launch the app**

```bash
swift run
```

- [ ] **Step 2: Settings (light) verification**

Open `⌘,` (Settings) → 日报 tab. Confirm all of:
- Section headers (`🎯 今日进度`, `🔴 紧急待处理`, `📋 待处理 · 今天到期`, etc.) are visible against the light Aqua background.
- Action card content text is dark (not white-on-white).
- Hover over an action row — `[完成]` and `[打开微信]` buttons are present even before hover.
- Click `▸ 📌 今日高亮` — section expands.
- Scroll the panel — only the outer Settings ScrollView scrolls (no double scrollbar).

Take a screenshot showing the visible 日报 panel. Save as `docs/superpowers/specs/screenshots/2026-05-05-daily-report-light.png`.

- [ ] **Step 3: HUD (dark) verification**

Open the HUD floating panel (whatever shortcut launches it; default activation is via menu-bar icon). Click 日报 tab. Confirm:
- All text remains visible on the dark backdrop.
- Same controls as light mode are present.
- No layout collapse.

Take a screenshot. Save as `docs/superpowers/specs/screenshots/2026-05-05-daily-report-dark.png`.

- [ ] **Step 4: Commit screenshots**

```bash
git add docs/superpowers/specs/screenshots/
git commit -m "docs(daily-report): M1 verification screenshots (light + dark)"
```

- [ ] **Step 5: Open PR-A**

```bash
git push -u origin <branch>
gh pr create --title "feat(daily-report): M1 productization baseline" --body "$(cat <<'EOF'
## Summary
- Replace dark-only `Color.white.opacity(...)` with semantic `.primary`/`.secondary` so the daily-report tab renders on Settings' light background
- Drop nested ScrollView; rely on caller's outer ScrollView
- Bucket 待处理 by deadline (today / this week / later)
- Default-visible row action buttons; hover only adjusts opacity
- DisclosureGroup wraps completed / highlights / risks
- Pin HUD path to `.preferredColorScheme(.dark)` via `DailyReportHUDTabView` wrapper

## Test plan
- [x] `swift test --filter DailyReportPresentationPolicyTests`
- [x] Visual verification (light): `docs/superpowers/specs/screenshots/2026-05-05-daily-report-light.png`
- [x] Visual verification (dark): `docs/superpowers/specs/screenshots/2026-05-05-daily-report-dark.png`

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## PR-B · M2 Data Layer

**Goal:** Land the SQLite table, migration, and CRUD methods that PR-C will read/write. No generator, no UI changes — this PR alone is a no-op for the user but lets PR-C land cleanly.

### Task 9: Create `DailyReportActionInsight` model

**Files:**
- Create: `Sources/WeChatHUD/Data/DailyReportActionInsight.swift`

- [ ] **Step 1: Write the file**

```swift
import Foundation

/// AI-produced per-action annotation for the daily report.
/// Persisted in `daily_report_action_insights`, keyed by `(dateKey, actionID)`.
struct DailyReportActionInsight: Sendable, Codable, Equatable {
    let dateKey: String
    let actionID: String
    let reason: String        // ≤ 30 字
    let nextStep: String      // ≤ 40 字
    let modelVersion: String  // e.g. "daily_report_action_insights_v1"
    let generatedAt: Date
}
```

- [ ] **Step 2: Build**

```bash
swift build
```
Expected: success.

- [ ] **Step 3: Commit**

```bash
git add Sources/WeChatHUD/Data/DailyReportActionInsight.swift
git commit -m "feat(daily-report): add DailyReportActionInsight model"
```

---

### Task 10: Add migration + CRUD methods to `HUDStore+DailyReport`

**Files:**
- Modify: `Sources/WeChatHUD/Data/HUDStore+DailyReport.swift`
- Test: `Tests/WeChatHUDTests/HUDStoreDailyReportTests.swift`

- [ ] **Step 1: Write the failing CRUD round-trip test**

Append to `Tests/WeChatHUDTests/HUDStoreDailyReportTests.swift` before the closing brace of the class:

```swift
    func testActionInsightRoundTrip() throws {
        let (store, path) = try makeTempStore()
        defer {
            store.close()
            try? FileManager.default.removeItem(atPath: path)
        }

        let insight = DailyReportActionInsight(
            dateKey: "2026-05-05",
            actionID: "todo-42",
            reason: "客户今天 18 点要答复",
            nextStep: "回复确认时间并同步内部",
            modelVersion: "daily_report_action_insights_v1",
            generatedAt: Date()
        )
        try store.upsertActionInsight(insight)

        let loaded = store.loadActionInsights(dateKey: "2026-05-05")
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0], insight)
    }

    func testActionInsightOverwrite() throws {
        let (store, path) = try makeTempStore()
        defer {
            store.close()
            try? FileManager.default.removeItem(atPath: path)
        }

        let v1 = DailyReportActionInsight(
            dateKey: "2026-05-05", actionID: "todo-1",
            reason: "old", nextStep: "old",
            modelVersion: "daily_report_action_insights_v1",
            generatedAt: Date()
        )
        try store.upsertActionInsight(v1)
        let v2 = DailyReportActionInsight(
            dateKey: "2026-05-05", actionID: "todo-1",
            reason: "new", nextStep: "new",
            modelVersion: "daily_report_action_insights_v1",
            generatedAt: Date()
        )
        try store.upsertActionInsight(v2)

        let loaded = store.loadActionInsights(dateKey: "2026-05-05")
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].reason, "new")
    }

    func testActionInsightCrossDateIsolation() throws {
        let (store, path) = try makeTempStore()
        defer {
            store.close()
            try? FileManager.default.removeItem(atPath: path)
        }

        try store.upsertActionInsight(DailyReportActionInsight(
            dateKey: "2026-05-05", actionID: "x",
            reason: "a", nextStep: "b",
            modelVersion: "v1", generatedAt: Date()
        ))
        try store.upsertActionInsight(DailyReportActionInsight(
            dateKey: "2026-05-06", actionID: "x",
            reason: "c", nextStep: "d",
            modelVersion: "v1", generatedAt: Date()
        ))

        XCTAssertEqual(store.loadActionInsights(dateKey: "2026-05-05").count, 1)
        XCTAssertEqual(store.loadActionInsights(dateKey: "2026-05-06").count, 1)
        XCTAssertEqual(store.loadActionInsights(dateKey: "2026-05-07").count, 0)
    }
```

- [ ] **Step 2: Run tests, verify they fail**

```bash
swift test --filter HUDStoreDailyReportTests
```
Expected: 3 new tests fail with "value of type 'HUDStore' has no member 'upsertActionInsight'".

- [ ] **Step 3: Add migration to `migrateDailyReportState`**

In `Sources/WeChatHUD/Data/HUDStore+DailyReport.swift`, inside `migrateDailyReportState()` (line 6), append:

```swift
        execIgnoringError("""
            CREATE TABLE IF NOT EXISTS daily_report_action_insights (
                date_key       TEXT NOT NULL,
                action_id      TEXT NOT NULL,
                reason         TEXT NOT NULL,
                next_step      TEXT NOT NULL,
                model_version  TEXT NOT NULL,
                generated_at   INTEGER NOT NULL,
                PRIMARY KEY(date_key, action_id)
            )
        """)
        execIgnoringError("CREATE INDEX IF NOT EXISTS idx_action_insights_date ON daily_report_action_insights(date_key)")
```

- [ ] **Step 4: Add `upsertActionInsight(_:)` and `loadActionInsights(dateKey:)`**

Append to the `extension HUDStore` block (after `recentDailyReportSnapshots` at line 150, before the closing brace):

```swift
    func upsertActionInsight(_ insight: DailyReportActionInsight) throws {
        let sql = """
            INSERT INTO daily_report_action_insights
                (date_key, action_id, reason, next_step, model_version, generated_at)
            VALUES
                (?, ?, ?, ?, ?, ?)
            ON CONFLICT(date_key, action_id) DO UPDATE SET
                reason = excluded.reason,
                next_step = excluded.next_step,
                model_version = excluded.model_version,
                generated_at = excluded.generated_at
        """
        let params: [String] = [
            insight.dateKey,
            insight.actionID,
            insight.reason,
            insight.nextStep,
            insight.modelVersion,
            String(Int(insight.generatedAt.timeIntervalSince1970))
        ]
        _ = executeUpdate(sql) { stmt in
            for (i, p) in params.enumerated() {
                sqlite3_bind_text(stmt, Int32(i + 1), p, -1, Self.sqliteTransient)
            }
        }
    }

    func loadActionInsights(dateKey: String) -> [DailyReportActionInsight] {
        queryAll("""
            SELECT date_key, action_id, reason, next_step, model_version, generated_at
            FROM daily_report_action_insights
            WHERE date_key = ?
        """, bind: { stmt in
            sqlite3_bind_text(stmt, 1, dateKey, -1, Self.sqliteTransient)
        }, decode: { stmt in
            guard let dk = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
                  let aid = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
                  let reason = sqlite3_column_text(stmt, 2).map({ String(cString: $0) }),
                  let nextStep = sqlite3_column_text(stmt, 3).map({ String(cString: $0) }),
                  let mv = sqlite3_column_text(stmt, 4).map({ String(cString: $0) })
            else { return nil }
            let ts = sqlite3_column_int64(stmt, 5)
            return DailyReportActionInsight(
                dateKey: dk,
                actionID: aid,
                reason: reason,
                nextStep: nextStep,
                modelVersion: mv,
                generatedAt: Date(timeIntervalSince1970: TimeInterval(ts))
            )
        })
    }
```

- [ ] **Step 5: Run tests, verify all pass**

```bash
swift test --filter HUDStoreDailyReportTests
```
Expected: PASS, all 3 new tests + existing tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/WeChatHUD/Data/HUDStore+DailyReport.swift \
        Tests/WeChatHUDTests/HUDStoreDailyReportTests.swift
git commit -m "feat(daily-report): add daily_report_action_insights table + CRUD"
```

- [ ] **Step 7: Open PR-B**

```bash
gh pr create --title "feat(daily-report): add action-insight data layer (M2 prep)" --body "$(cat <<'EOF'
## Summary
- Add `DailyReportActionInsight` model
- Add `daily_report_action_insights` SQLite table + idempotent migration
- Add `HUDStore.upsertActionInsight(_:)` / `loadActionInsights(dateKey:)`

No user-facing changes; PR-C will start writing to this table.

## Test plan
- [x] `swift test --filter HUDStoreDailyReportTests`
- [x] App launches and the new migration runs without breaking existing tables

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## PR-C · M2 Generator + Wiring + UI

**Goal:** New AI generator produces `(reason, nextStep)` for urgent actions; `ChatMonitor` runs it in parallel with the existing summary generator; UI renders a third line on urgent cards. Cache hits skip the AI call. Failure leaves cards intact without an annotation.

### Task 11: Create the prompt resource

**Files:**
- Create: `Sources/WeChatHUD/Resources/prompts/daily_report_action_insights_v1.txt`

- [ ] **Step 1: Write the prompt file**

```
你是工作调度助手。下面是用户今天 N 条紧急或高优先级事项。
为每条返回一个对象，包含：
- id: 原 ID 原样回填，不能修改、不能合并、不能省略
- reason: ≤30 字，解释"为什么必须立刻处理"。基于 deadline、来源、类型，不要复述 content。
- next_step: ≤40 字，给出"下一步具体动作"。动词开头，祈使句，禁止"继续推进"等空话。

输入数量: {count}

输入：
{actions}

只输出 JSON 数组：[{"id":"...","reason":"...","next_step":"..."}, ...]
不要任何 markdown 围栏、不要任何其它文字。如果某条无法解释，返回空字符串而不是省略 id。
```

- [ ] **Step 2: Verify Bundle resource picks it up**

The Package.swift already does `.copy("Resources/prompts")`, so any new `.txt` file in that directory ships automatically. No build edit needed.

```bash
swift build
```
Expected: success.

- [ ] **Step 3: Commit**

```bash
git add Sources/WeChatHUD/Resources/prompts/daily_report_action_insights_v1.txt
git commit -m "feat(daily-report): add v1 prompt for per-action AI insights"
```

---

### Task 12: Stub the generator + write failing format/parse tests

**Files:**
- Create: `Sources/WeChatHUD/Services/AIDailyReportActionInsightGenerator.swift`
- Create: `Tests/WeChatHUDTests/AIDailyReportActionInsightGeneratorTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/WeChatHUDTests/AIDailyReportActionInsightGeneratorTests.swift`:

```swift
import Foundation
import XCTest
@testable import WeChatHUD

final class AIDailyReportActionInsightGeneratorTests: XCTestCase {

    // MARK: - Prompt formatting

    func testFormatPromptIncludesAllActions() {
        let generator = makeGenerator()
        let actions = [
            makeAction(id: "todo-1",       content: "回复客户", deadline: Date()),
            makeAction(id: "commitment-2", content: "交付报告", deadline: nil),
        ]
        let template = "count={count}\nactions:\n{actions}"
        let prompt = generator.formatPrompt(template: template, actions: actions)

        XCTAssertTrue(prompt.contains("count=2"))
        XCTAssertTrue(prompt.contains("id=\"todo-1\""))
        XCTAssertTrue(prompt.contains("id=\"commitment-2\""))
        XCTAssertTrue(prompt.contains("回复客户"))
        XCTAssertTrue(prompt.contains("交付报告"))
    }

    func testFormatPromptCapsActionsAtTwelve() {
        let generator = makeGenerator()
        let actions = (0..<20).map { makeAction(id: "todo-\($0)", content: "x", deadline: nil) }
        let template = "{actions}"
        let prompt = generator.formatPrompt(template: template, actions: actions)

        let occurrences = prompt.components(separatedBy: "id=\"todo-").count - 1
        XCTAssertEqual(occurrences, 12)
    }

    // MARK: - Parsing

    func testParseValidArray() {
        let generator = makeGenerator()
        let raw = """
        [
          {"id":"todo-1","reason":"r1","next_step":"n1"},
          {"id":"todo-2","reason":"r2","next_step":"n2"}
        ]
        """
        let parsed = generator.parse(raw)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].id, "todo-1")
        XCTAssertEqual(parsed[0].reason, "r1")
        XCTAssertEqual(parsed[1].nextStep, "n2")
    }

    func testParseRejectsGarbage() {
        let generator = makeGenerator()
        XCTAssertTrue(generator.parse("not json").isEmpty)
        XCTAssertTrue(generator.parse("").isEmpty)
    }

    // MARK: - Helpers

    private func makeGenerator() -> AIDailyReportActionInsightGenerator {
        AIDailyReportActionInsightGenerator(
            aiService: AIService(config: AIConfig()),
            store: HUDStore(dbPath: ":memory:")
        )
    }

    private func makeAction(id: String, content: String, deadline: Date?) -> DailyReportAction {
        DailyReportAction(
            id: id,
            content: content,
            type: .todo,
            urgency: .high,
            deadline: deadline,
            sourceChatName: "Test",
            sourceChatUsername: "wxid_test",
            relatedID: id
        )
    }
}
```

- [ ] **Step 2: Run tests, verify they fail**

```bash
swift test --filter AIDailyReportActionInsightGeneratorTests
```
Expected: build fails with "cannot find 'AIDailyReportActionInsightGenerator'".

- [ ] **Step 3: Create the generator skeleton**

Create `Sources/WeChatHUD/Services/AIDailyReportActionInsightGenerator.swift`:

```swift
import Foundation

/// Generates per-action AI insights (reason + nextStep) for the daily report.
/// One batched call per `loadDailyReport` invocation. Caches results in
/// `daily_report_action_insights` keyed by (dateKey, actionID); cached
/// rows are not re-requested.
actor AIDailyReportActionInsightGenerator {
    private let aiService: AIService
    private let store: HUDStore
    private let promptLoader: PromptLoader
    private let promptVersion: String
    static let actionsPerCall = 12

    init(
        aiService: AIService,
        store: HUDStore,
        promptLoader: PromptLoader = PromptLoader(),
        promptVersion: String = "daily_report_action_insights_v1"
    ) {
        self.aiService = aiService
        self.store = store
        self.promptLoader = promptLoader
        self.promptVersion = promptVersion
    }

    // MARK: - Output schema

    struct AIRow: Decodable {
        let id: String
        let reason: String
        let nextStep: String

        enum CodingKeys: String, CodingKey {
            case id, reason
            case nextStep = "next_step"
        }
    }

    // MARK: - Generate (skeleton; wired in Task 13)

    func generate(for actions: [DailyReportAction], dateKey: String) async -> [DailyReportActionInsight] {
        return []
    }

    // MARK: - Prompt formatting

    nonisolated func formatPrompt(template: String, actions: [DailyReportAction]) -> String {
        let capped = Array(actions.prefix(Self.actionsPerCall))
        let lines = capped.map { a -> String in
            let deadline = a.deadline.map { " deadline=\"\($0.formatted(date: .abbreviated, time: .shortened))\"" } ?? ""
            return "id=\"\(a.id)\" type=\"\(a.type.rawValue)\" source=\"\(a.sourceChatName)\"\(deadline) content=\"\(a.content.replacingOccurrences(of: "\"", with: "'"))\""
        }
        return template
            .replacingOccurrences(of: "{count}", with: "\(capped.count)")
            .replacingOccurrences(of: "{actions}", with: lines.joined(separator: "\n"))
    }

    // MARK: - Parsing

    nonisolated func parse(_ raw: String) -> [AIRow] {
        AIJSONExtractor.decodeFirstArray(from: raw, as: AIRow.self) ?? []
    }
}
```

- [ ] **Step 4: Verify `AIJSONExtractor.decodeFirstArray` exists**

```bash
grep -n "decodeFirstArray\|decodeFirstObject" Sources/WeChatHUD/Services/AIJSONExtractor.swift
```
If only `decodeFirstObject` exists, add a sibling array helper to `AIJSONExtractor.swift`. The existing `decodeFirstObject` strips markdown fences and parses; the array version does the same but expects `[`. Add (only if missing):

```swift
    static func decodeFirstArray<T: Decodable>(from raw: String, as type: T.Type) -> [T]? {
        let trimmed = stripFences(raw)
        guard let start = trimmed.firstIndex(of: "["),
              let end = trimmed.lastIndex(of: "]"),
              start < end
        else { return nil }
        let slice = String(trimmed[start...end])
        guard let data = slice.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([T].self, from: data)
    }
```

(Only do this step if grep shows the helper is missing. If `stripFences` is private, name a local equivalent inside the helper.)

- [ ] **Step 5: Run tests, verify format/parse tests pass**

```bash
swift test --filter AIDailyReportActionInsightGeneratorTests
```
Expected: 4 tests pass (`generate(for:dateKey:)` is an empty stub but no test exercises it yet).

- [ ] **Step 6: Commit**

```bash
git add Sources/WeChatHUD/Services/AIDailyReportActionInsightGenerator.swift \
        Tests/WeChatHUDTests/AIDailyReportActionInsightGeneratorTests.swift \
        Sources/WeChatHUD/Services/AIJSONExtractor.swift
git commit -m "feat(daily-report): scaffold AIDailyReportActionInsightGenerator (prompt + parse)"
```

---

### Task 13: Implement `generate(for:dateKey:)` with cache, AI call, retry, audit

**Files:**
- Modify: `Sources/WeChatHUD/Services/AIDailyReportActionInsightGenerator.swift`
- Modify: `Tests/WeChatHUDTests/AIDailyReportActionInsightGeneratorTests.swift`

- [ ] **Step 1: Write failing test for cache hit (no AI call)**

Append to `AIDailyReportActionInsightGeneratorTests.swift` before the `// MARK: - Helpers` section:

```swift
    // MARK: - Cache

    func testCacheHitSkipsAICall() async throws {
        let (store, path) = try makeTempStore()
        defer {
            store.close()
            try? FileManager.default.removeItem(atPath: path)
        }
        // Pre-populate cache
        let cached = DailyReportActionInsight(
            dateKey: "2026-05-05", actionID: "todo-x",
            reason: "cached_r", nextStep: "cached_n",
            modelVersion: "daily_report_action_insights_v1",
            generatedAt: Date()
        )
        try store.upsertActionInsight(cached)

        // AIService config has no API key, so any real call would error.
        // If the cache works, it returns without calling.
        let gen = AIDailyReportActionInsightGenerator(
            aiService: AIService(config: AIConfig()), store: store
        )
        let action = makeAction(id: "todo-x", content: "x", deadline: nil)
        let result = await gen.generate(for: [action], dateKey: "2026-05-05")

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].reason, "cached_r")
    }

    func testEmptyActionsReturnsEmpty() async {
        let gen = makeGenerator()
        let result = await gen.generate(for: [], dateKey: "2026-05-05")
        XCTAssertTrue(result.isEmpty)
    }
```

Also add the `makeTempStore()` helper to the same test file (copy from `HUDStoreDailyReportTests.swift:132`):

```swift
    private func makeTempStore() throws -> (HUDStore, String) {
        let dir = NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent("daily-insights-\(UUID().uuidString).db")
        let store = HUDStore(dbPath: path)
        return (store, path)
    }
```

- [ ] **Step 2: Run tests, verify cache test fails**

```bash
swift test --filter AIDailyReportActionInsightGeneratorTests
```
Expected: `testCacheHitSkipsAICall` fails (returns empty array). `testEmptyActionsReturnsEmpty` passes (stub already returns empty).

- [ ] **Step 3: Implement `generate(for:dateKey:)`**

Replace the stub in `AIDailyReportActionInsightGenerator.swift` with the full implementation:

```swift
    func generate(for actions: [DailyReportAction], dateKey: String) async -> [DailyReportActionInsight] {
        guard !actions.isEmpty else { return [] }

        // 1. Load cache; partition into hits and misses.
        let cached = store.loadActionInsights(dateKey: dateKey)
        let cacheMap = Dictionary(uniqueKeysWithValues: cached.map { ($0.actionID, $0) })

        var hits: [DailyReportActionInsight] = []
        var misses: [DailyReportAction] = []
        for a in actions {
            if let c = cacheMap[a.id] { hits.append(c) } else { misses.append(a) }
        }
        if misses.isEmpty { return hits }

        // 2. Load template.
        let template: String
        do {
            template = try promptLoader.load(version: promptVersion)
        } catch {
            await audit(dateKey: dateKey, output: "", latencyMs: 0,
                        status: .parseError, error: "prompt load failed: \(error)", model: nil)
            return hits
        }

        // 3. Call AI with retry on parse failure.
        let started = Date()
        let userPrompt = formatPrompt(template: template, actions: misses)

        var rows: [AIRow] = []
        let first = await call(userPrompt)
        rows = parse(first.text)
        if rows.isEmpty, !first.text.isEmpty {
            let strict = userPrompt + "\n\n严格要求：上一次输出无法解析为 JSON 数组。只输出符合 schema 的 JSON 数组，不要任何其他文字。"
            let second = await call(strict)
            rows = parse(second.text)
            if rows.isEmpty {
                await audit(dateKey: dateKey, output: second.text,
                            latencyMs: ms(since: started),
                            status: .parseError, error: "JSON parse failed after retry", model: second.model)
                return hits
            }
        } else if rows.isEmpty {
            await audit(dateKey: dateKey, output: "", latencyMs: ms(since: started),
                        status: .httpError, error: first.error ?? "empty AI response", model: first.model)
            return hits
        }

        // 4. Match rows by id and persist.
        let now = Date()
        let missMap = Dictionary(uniqueKeysWithValues: misses.map { ($0.id, $0) })
        var fresh: [DailyReportActionInsight] = []
        for row in rows where missMap[row.id] != nil {
            let insight = DailyReportActionInsight(
                dateKey: dateKey,
                actionID: row.id,
                reason: row.reason,
                nextStep: row.nextStep,
                modelVersion: promptVersion,
                generatedAt: now
            )
            do {
                try store.upsertActionInsight(insight)
                fresh.append(insight)
            } catch {
                print("[WCHUD] insight upsert failed for \(row.id): \(error)")
            }
        }

        await audit(dateKey: dateKey, output: "rows=\(rows.count) fresh=\(fresh.count)",
                    latencyMs: ms(since: started), status: .ok, error: nil, model: nil)

        return hits + fresh
    }

    // MARK: - Model call

    private struct ModelResponse {
        let text: String
        let error: String?
        let model: String?
    }

    private func call(_ userPrompt: String) async -> ModelResponse {
        let trackID = "daily_insight:\(UUID().uuidString.prefix(8))"
        AIActivityTracker.shared.begin(trackID, label: "日报逐条注释")
        defer { AIActivityTracker.shared.end(trackID) }

        do {
            let result = try await aiService.completeWithMetadata(
                system: "你是工作调度助手，严格按要求输出 JSON 数组。",
                user: userPrompt,
                options: CompleteOptions(timeout: 60, temperature: 0.2, maxTokens: 1024, responseFormatJSON: true)
            )
            return ModelResponse(text: result.text, error: nil, model: result.model)
        } catch {
            return ModelResponse(text: "", error: error.localizedDescription, model: nil)
        }
    }

    // MARK: - Audit

    private func audit(dateKey: String, output: String, latencyMs: Int,
                       status: AIAuditStatus, error: String?, model: String?) async {
        let resolved = model ?? (await aiService.currentConfig().model)
        let entry = AIAuditEntry(
            id: 0, ts: Date(), role: .retrospector, model: resolved,
            promptVersion: promptVersion,
            inputText: "[daily_action_insights|\(dateKey)]",
            outputText: output, latencyMs: latencyMs,
            status: status, errorMessage: error
        )
        do {
            try store.writeAIAudit(entry)
        } catch {
            print("[WCHUD] AIDailyReportActionInsightGenerator audit failed: \(error)")
        }
    }

    private func ms(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
```

- [ ] **Step 4: Run tests, verify all pass**

```bash
swift test --filter AIDailyReportActionInsightGeneratorTests
```
Expected: PASS, including `testCacheHitSkipsAICall` and `testEmptyActionsReturnsEmpty`.

- [ ] **Step 5: Commit**

```bash
git add Sources/WeChatHUD/Services/AIDailyReportActionInsightGenerator.swift \
        Tests/WeChatHUDTests/AIDailyReportActionInsightGeneratorTests.swift
git commit -m "feat(daily-report): wire generator AI call + cache + retry + audit"
```

---

### Task 14: Extend `CommandCenterViewModel` to carry insights

**Files:**
- Modify: `Sources/WeChatHUD/Data/DailyReportPresentationPolicy.swift`
- Modify: `Tests/WeChatHUDTests/DailyReportPresentationPolicyTests.swift`

- [ ] **Step 1: Write failing test for insight injection**

Append to `DailyReportPresentationPolicyTests.swift` before the `private func makeReport`:

```swift
    func testActionInsightsExposedThroughViewModel() {
        let action = makeAction(content: "Reply", urgency: .high)
        let report = makeReport(actions: [action], risks: [], highlights: [])
        let insight = DailyReportActionInsight(
            dateKey: report.date.dailyReportDateKey,
            actionID: action.id,
            reason: "客户在等",
            nextStep: "立刻回 OK",
            modelVersion: "daily_report_action_insights_v1",
            generatedAt: Date()
        )

        let vm = DailyReportPresentationPolicy.buildViewModel(
            from: report,
            commandStates: [],
            insights: [insight.actionID: insight]
        )

        XCTAssertEqual(vm.actionInsights[action.id]?.reason, "客户在等")
    }
```

- [ ] **Step 2: Run tests, verify failure**

```bash
swift test --filter DailyReportPresentationPolicyTests
```
Expected: build fails — `buildViewModel` has no `insights:` parameter.

- [ ] **Step 3: Add `actionInsights` field + parameter**

In `DailyReportPresentationPolicy.swift`, add to `CommandCenterViewModel`:

```swift
        let actionInsights: [String: DailyReportActionInsight]
```

Update the function signature to:

```swift
    static func buildViewModel(
        from report: DailyReport,
        commandStates: [DailyReportCommandState] = [],
        insights: [String: DailyReportActionInsight] = [:]
    ) -> CommandCenterViewModel {
```

In the `return CommandCenterViewModel(...)` call at the end, add:

```swift
            actionInsights: insights,
```

(Place it right after `wechatDraft: report.wechatDraft,` so the alphabetical-ish flow stays similar; field order in the struct must match the call.)

- [ ] **Step 4: Run tests, verify all pass**

```bash
swift test --filter DailyReportPresentationPolicyTests
```
Expected: PASS, including the new insight test and all existing.

- [ ] **Step 5: Commit**

```bash
git add Sources/WeChatHUD/Data/DailyReportPresentationPolicy.swift \
        Tests/WeChatHUDTests/DailyReportPresentationPolicyTests.swift
git commit -m "feat(daily-report): pipe action insights through CommandCenterViewModel"
```

---

### Task 15: Wire generator + insights into `ChatMonitor.loadDailyReport`

**Files:**
- Modify: `Sources/WeChatHUD/Services/ChatMonitor.swift`

- [ ] **Step 1: Add `@Published` field + lazy generator**

In `ChatMonitor.swift`, near the existing `@Published var dailyReport*` fields (lines 71-75), add:

```swift
    @Published var dailyReportActionInsights: [String: DailyReportActionInsight] = [:]
```

Near the existing `dailyReportGenerator` lazy var (line 231), add:

```swift
    private lazy var dailyReportActionInsightGenerator: AIDailyReportActionInsightGenerator = {
        AIDailyReportActionInsightGenerator(aiService: aiService, store: store)
    }()
```

- [ ] **Step 2: Update `loadDailyReport(for:force:)` to run both generators in parallel**

Replace the body of `loadDailyReport(for:force:)` (lines 1685-1702):

```swift
    func loadDailyReport(for date: Date, force: Bool = false) async {
        if !force, let gen = dailyReportGeneratedAt,
           Date().timeIntervalSince(gen) < 1800,
           dailyReport != nil,
           Calendar.current.isDate(dailyReport!.date, inSameDayAs: date) {
            return
        }
        dailyReportError = nil
        dailyReportIsLoading = true

        let dateKey = date.dailyReportDateKey
        let builder = DailyReportBuilder(store: store, replyDebtItems: replyDebtItems, stats: stats)
        let baseReport = builder.build(for: date)
        dailyReport = baseReport
        dailyReportGeneratedAt = baseReport.generatedAt

        // Seed insights dict from cache so cards can render annotations immediately.
        dailyReportActionInsights = store.loadActionInsights(dateKey: dateKey)
            .reduce(into: [:]) { $0[$1.actionID] = $1 }

        let urgentActions = baseReport.actions.filter {
            $0.urgency == .critical || $0.urgency == .high
        }

        async let enrichedReport = dailyReportGenerator.enrich(baseReport)
        async let freshInsights = dailyReportActionInsightGenerator.generate(
            for: urgentActions, dateKey: dateKey
        )

        let (report, insights) = await (enrichedReport, freshInsights)

        dailyReport = report
        dailyReportGeneratedAt = report.generatedAt
        dailyReportError = report.aiErrorMessage
        for ins in insights { dailyReportActionInsights[ins.actionID] = ins }
        dailyReportIsLoading = false
    }
```

- [ ] **Step 3: Build**

```bash
swift build
```
Expected: success.

- [ ] **Step 4: Commit**

```bash
git add Sources/WeChatHUD/Services/ChatMonitor.swift
git commit -m "feat(daily-report): run AI summary + per-row insights in parallel"
```

---

### Task 16: Render `aiReason` / `aiNextStep` on urgent action cards

**Files:**
- Modify: `Sources/WeChatHUD/Views/DailyReportCommandCenterView.swift`

- [ ] **Step 1: Pass insights into the view-model build call**

Find where `buildViewModel(from:commandStates:)` is called inside `body` (currently lines 13-17). Replace with:

```swift
            if let report = monitor.dailyReport {
                let states = monitor.store.loadDailyReportCommandStates(
                    dateKey: report.date.dailyReportDateKey
                )
                let vm = DailyReportPresentationPolicy.buildViewModel(
                    from: report,
                    commandStates: states,
                    insights: monitor.dailyReportActionInsights
                )
                content(vm: vm, report: report)
            }
```

- [ ] **Step 2: Plumb insights through `content(vm:report:)` to `actionCard(_:isUrgent:)`**

Change `actionCard`'s signature to accept an optional insight:

```swift
    private func actionCard(_ action: DailyReportAction, isUrgent: Bool, insight: DailyReportActionInsight? = nil) -> some View {
```

In `content(vm:report:)`, change the urgent loop to look up the insight:

```swift
                if !vm.urgentActions.isEmpty {
                    sectionHeader("🔴 紧急待处理", count: vm.urgentActions.count)
                    ForEach(vm.urgentActions) { action in
                        actionCard(action, isUrgent: true, insight: vm.actionInsights[action.id])
                    }
                    divider
                }
```

(Active buckets stay without insight; we only annotate urgent rows in M2.)

- [ ] **Step 3: Render the insight subview inside `actionCard`**

Inside the `VStack(alignment: .leading, spacing: 3)` of `actionCard`, after the existing chip/source/deadline row, append a conditional block:

```swift
                if let insight {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .top, spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 9))
                                .foregroundColor(.cyan.opacity(0.85))
                            Text(insight.reason)
                                .font(.system(size: 11))
                                .italic()
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(alignment: .top, spacing: 4) {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 9))
                                .foregroundColor(.orange.opacity(0.85))
                            Text(insight.nextStep)
                                .font(.system(size: 11))
                                .foregroundColor(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 2)
                }
```

- [ ] **Step 4: Build**

```bash
swift build
```
Expected: success.

- [ ] **Step 5: Commit**

```bash
git add Sources/WeChatHUD/Views/DailyReportCommandCenterView.swift
git commit -m "feat(daily-report): render AI reason + next-step on urgent action cards"
```

---

### Task 17: Visual verification + screenshot for M2

**Files:**
- Create: `docs/superpowers/specs/screenshots/2026-05-05-daily-report-m2.png`

- [ ] **Step 1: Build, launch, generate a report with urgent actions**

```bash
swift run
```

In the running app, navigate to the daily-report tab. If today has no urgent items, manually create one (e.g. add a 30-minute commitment via your existing test fixture path, or wait for one to surface).

- [ ] **Step 2: Confirm rendering**

- Each 🔴 紧急待处理 card now shows two extra lines: a sparkles+italic "reason" line and an arrow+text "next step" line.
- Cards without an insight (cache miss + AI not yet returned) render the original layout.
- Reload (`↻` button) shows the insight stays cached; second load doesn't re-call AI (check console / audit table).

Screenshot one card with insight visible. Save as `docs/superpowers/specs/screenshots/2026-05-05-daily-report-m2.png`.

- [ ] **Step 3: Commit screenshot**

```bash
git add docs/superpowers/specs/screenshots/2026-05-05-daily-report-m2.png
git commit -m "docs(daily-report): M2 verification screenshot"
```

- [ ] **Step 4: Open PR-C**

```bash
gh pr create --title "feat(daily-report): per-action AI insights on urgent rows" --body "$(cat <<'EOF'
## Summary
- New `AIDailyReportActionInsightGenerator` actor (batched call ≤12 actions, retry-on-parse-fail, cache by `(dateKey, actionID)`)
- New prompt `daily_report_action_insights_v1.txt`
- `ChatMonitor.loadDailyReport` runs summary + insights generators in parallel via `async let`
- `CommandCenterViewModel.actionInsights` plumbed through `DailyReportPresentationPolicy`
- Urgent cards render `reason` (italic, sparkles) and `next_step` (arrow icon, primary text)

## Test plan
- [x] `swift test --filter AIDailyReportActionInsightGeneratorTests`
- [x] `swift test --filter DailyReportPresentationPolicyTests`
- [x] Visual verification: `docs/superpowers/specs/screenshots/2026-05-05-daily-report-m2.png`
- [x] Cached re-load doesn't re-call AI (verified via `ai_audit` table)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## PR-D · M2 Config Toggle

**Goal:** Let the user disable per-action insights, falling back to the M1 baseline. Default `true`.

### Task 18: Add `dailyReportActionInsightsEnabled` to `AIConfig`

**Files:**
- Modify: `Sources/WeChatHUD/Data/Models.swift`

- [ ] **Step 1: Add the property**

In `Models.swift`, find the `AIConfig` struct (line 720). Add a new property near the other booleans (around line 744):

```swift
    var dailyReportActionInsightsEnabled: Bool = true
```

- [ ] **Step 2: Build**

```bash
swift build
```
Expected: success. (Codable synthesizes the new key; existing configs deserialize with the default.)

- [ ] **Step 3: Commit**

```bash
git add Sources/WeChatHUD/Data/Models.swift
git commit -m "feat(daily-report): add AIConfig.dailyReportActionInsightsEnabled flag"
```

---

### Task 19: Honor the flag in `ChatMonitor`

**Files:**
- Modify: `Sources/WeChatHUD/Services/ChatMonitor.swift`

- [ ] **Step 1: Gate the generator call**

In `loadDailyReport(for:force:)` (modified in Task 15), replace the `async let freshInsights = ...` block with a conditional:

```swift
        async let enrichedReport = dailyReportGenerator.enrich(baseReport)
        let aiConfig = await aiService.currentConfig()
        let insightsTask: Task<[DailyReportActionInsight], Never>? = aiConfig.dailyReportActionInsightsEnabled
            ? Task { await dailyReportActionInsightGenerator.generate(for: urgentActions, dateKey: dateKey) }
            : nil

        let report = await enrichedReport
        let insights = await insightsTask?.value ?? []

        dailyReport = report
        dailyReportGeneratedAt = report.generatedAt
        dailyReportError = report.aiErrorMessage
        for ins in insights { dailyReportActionInsights[ins.actionID] = ins }
        dailyReportIsLoading = false
```

(The `async let` form doesn't compose cleanly with a conditional, hence the explicit `Task` + optional.)

- [ ] **Step 2: Build**

```bash
swift build
```
Expected: success.

- [ ] **Step 3: Commit**

```bash
git add Sources/WeChatHUD/Services/ChatMonitor.swift
git commit -m "feat(daily-report): skip insight generator when disabled in AIConfig"
```

---

### Task 20: Surface the toggle in `AISettingsView`

**Files:**
- Modify: `Sources/WeChatHUD/Views/Settings/AISettingsView.swift`

- [ ] **Step 1: Add `@State` mirror**

Near the existing `@State private var summaryEnabled = true` (line 271), add:

```swift
    @State private var dailyReportActionInsightsEnabled = true
```

- [ ] **Step 2: Add the toggle row**

In the same view body where the existing `SettingsToggleRow("消息摘要", ...)` lives (around line 418), add another row after `summaryEnabled`:

```swift
            SettingsToggleRow("日报逐条 AI 注释", subtitle: "为紧急待处理行生成 AI 一句解释 + 下一步建议", isOn: $dailyReportActionInsightsEnabled)
```

Add the persistence hook next to the other `.onChange` triggers (around line 424):

```swift
        .onChange(of: dailyReportActionInsightsEnabled) { _, _ in debouncedSave() }
```

- [ ] **Step 3: Wire save / load**

In the save method (look near line 538 where `cfg.summaryEnabled = summaryEnabled` is set), add:

```swift
        cfg.dailyReportActionInsightsEnabled = dailyReportActionInsightsEnabled
```

In the load method (near line 596 where `summaryEnabled = cfg.summaryEnabled`), add:

```swift
        dailyReportActionInsightsEnabled = cfg.dailyReportActionInsightsEnabled
```

- [ ] **Step 4: Build**

```bash
swift build
```
Expected: success.

- [ ] **Step 5: Manual verification**

```bash
swift run
```
Open Settings → AI 设置. Confirm the toggle is present, defaults to ON, persists across relaunch, and that toggling OFF makes new daily-report loads skip insight generation (urgent cards lose the sparkles/arrow lines on next refresh).

- [ ] **Step 6: Commit**

```bash
git add Sources/WeChatHUD/Views/Settings/AISettingsView.swift
git commit -m "feat(daily-report): expose action-insights toggle in AI settings"
```

- [ ] **Step 7: Open PR-D**

```bash
gh pr create --title "feat(daily-report): config toggle for per-action AI insights" --body "$(cat <<'EOF'
## Summary
- `AIConfig.dailyReportActionInsightsEnabled` (default true)
- `ChatMonitor.loadDailyReport` skips the insight generator when disabled
- New toggle row in AI settings; persists across launch

## Test plan
- [x] `swift build`
- [x] Toggle on → urgent cards show insight lines after next load
- [x] Toggle off → next load shows urgent cards without insight lines

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Self-Review

Spec coverage check (cross against spec sections):

- §0 三类不可用根因 → fixed by Tasks 2 (semantic colors), 3 (drop ScrollView), 8 (visual gate)
- §1 M1 / M2 split → reflected in PR-A vs PR-B/C/D
- §2 双表面 + semantic tokens → Tasks 2, 7
- §3 信息架构 / 三桶 / 折叠 → Tasks 1, 4, 5, 6
- §4 视觉细节 → Tasks 2, 5, 6 (font sizes / corner radii / disclosure)
- §5 M2 prompt + 批量 + 缓存 + 兜底 → Tasks 11, 12, 13
- §6 数据模型 + 表 → Tasks 9, 10
- §7 服务层接线 → Tasks 12, 13, 14, 15
- §8 测试策略 → tests in Tasks 1, 10, 12, 13, 14; visual gates in Tasks 8, 17
- §9 文件清单 + 4-PR 顺序 → Tasks aligned with PR-A/B/C/D
- §10 开放问题 → explicitly out of scope; no plan task needed

Type-consistency spot checks:

- `DailyReportActionInsight` (Task 9) used unchanged in Tasks 10, 13, 14, 15, 16 ✓
- `actionInsights: [String: DailyReportActionInsight]` field name (Task 14) referenced same way in Tasks 15, 16 ✓
- `AIDailyReportActionInsightGenerator.generate(for:dateKey:)` signature (Task 12 stub → Task 13 impl → Task 15 caller) consistent ✓
- `dailyReportActionInsightsEnabled` flag name (Tasks 18, 19, 20) consistent ✓
- `loadActionInsights(dateKey:)` / `upsertActionInsight(_:)` names (Task 10) match calls in Tasks 13 (generator) and 15 (ChatMonitor) ✓
- `activeToday / activeThisWeek / activeLater` field names (Task 1 model, Task 4 view) consistent ✓
- `DailyReportHUDTabView` wrapper name (Task 7) — referenced once in `ExtendedTabsView`; spelled identically ✓

No placeholders found. No "TBD" or "TODO" or under-specified steps. Test code is concrete; tasks reference actual line numbers from the current file states.

One known risk: in Task 12, the `AIJSONExtractor.decodeFirstArray` helper might not exist; the task includes a conditional add-it step, but if the existing helper API differs (e.g. private `stripFences`), the engineer needs to adapt. Step 4 in Task 12 calls this out explicitly.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-05-daily-report-redesign.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
