# Daily Report Command Center — Implementation Checkpoint

## Goal
Replace the read-only Daily Report with an actionable "Daily Command Center" featuring progress tracking, completion, dismissal, chat jumps, copy/export, and date history.

## Non-Goals
- No new external dependencies
- No ViewInspector or SwiftUI snapshot tests
- No NavigationSplitView in floating panel
- No changes to AI prompt schema (keep v1 compatible)

## Current Phase
Phase 1: Data models + Store persistence

## Task Slices

### Phase 1: Data Models + Store Persistence
- [ ] Create `DailyReportCommandState.swift` (enum + struct)
- [ ] Create `DailyReportSnapshot.swift` (Codable snapshot)
- [ ] Create `DailyReportProgressMetrics.swift` (progress computation)
- [ ] Create `HUDStore+DailyReport.swift` (SQLite CRUD)
- [ ] Modify `DailyReport.swift` (add stable IDs, state fields)
- [ ] Modify `HUDStore.swift` (migration)
- [ ] Create `HUDStoreDailyReportTests.swift`

### Phase 2: Presentation Policy
- [ ] Create `DailyReportPresentationPolicy.swift`
- [ ] Create `DailyReportPresentationPolicyTests.swift`

### Phase 3: Builder Updates
- [ ] Modify `DailyReportBuilder.swift` (date support, state application)
- [ ] Extend `DailyReportBuilderTests.swift`

### Phase 4: Action Mutation
- [ ] Create `DailyReportMutation.swift` (pure planner)
- [ ] Modify `ChatMonitor.swift` (add mutation methods)
- [ ] Tests for mutation routing

### Phase 5: Export
- [ ] Create `DailyReportMarkdownExporter.swift`
- [ ] Modify `ChatMonitor.swift` (export/copy methods)

### Phase 6: UI Replacement
- [ ] Create `DailyReportCommandCenterView.swift`
- [ ] Create `DailyReportCards.swift`
- [ ] Create `DailyReportControls.swift`
- [ ] Modify `DailyReportTabView.swift` (replace content)

### Phase 7: Integration
- [ ] Move `FirstMouseRowHost` to shared file
- [ ] Modify `ExtendedTabsView.swift`
- [ ] Modify `SettingsView.swift`

### Phase 8: Verification
- [ ] Run all tests
- [ ] Run release build
- [ ] Manual QA checklist

## Verification Commands
```bash
swift test --filter HUDStoreDailyReportTests
swift test --filter DailyReportPresentationPolicyTests
swift test --filter DailyReportBuilderTests
swift test --filter AIDailyReportGeneratorTests
swift test
swift build
swift build -c release
```

## Progress
- [2026-05-05] Plan agent completed, full plan received
- [2026-05-05] Phase 1-3 complete: Data models, store persistence, presentation policy, builder updates
- [2026-05-05] Phase 4-5 complete: ChatMonitor mutations, markdown export
- [2026-05-05] Phase 6 complete: New SwiftUI Command Center UI
- [2026-05-05] Phase 8 complete: All 492 tests pass, release build zero warnings

## Changed Files
- Modified: `Sources/WeChatHUD/Data/DailyReport.swift` — Added stable IDs, state fields, Hashable
- Modified: `Sources/WeChatHUD/Services/DailyReportBuilder.swift` — Date range support
- Modified: `Sources/WeChatHUD/Services/ChatMonitor.swift` — Date nav, mutations, export
- Modified: `Sources/WeChatHUD/Data/HUDStore.swift` — Migration hook
- Modified: `Sources/WeChatHUD/Views/DailyReportTabView.swift` — New header with date nav + export
- Created: `Sources/WeChatHUD/Data/DailyReportCommandState.swift` — State model + progress metrics
- Created: `Sources/WeChatHUD/Data/DailyReportPresentationPolicy.swift` — Pure grouping/progress/export logic
- Created: `Sources/WeChatHUD/Data/HUDStore+DailyReport.swift` — SQLite persistence
- Created: `Sources/WeChatHUD/Views/DailyReportCommandCenterView.swift` — Main dashboard UI
- Created: `Tests/WeChatHUDTests/DailyReportPresentationPolicyTests.swift` — 7 tests
- Created: `Tests/WeChatHUDTests/HUDStoreDailyReportTests.swift` — 5 tests

## Verification Results
- `swift test`: 492 tests, 0 failures (1 skipped)
- `swift build -c release`: Zero warnings

## Next Step
Implementation complete. Awaiting user review.
