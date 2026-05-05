# 25-iteration-contract.md — Cycle 3: UI Layer

## Cycle Goal
Replace `DailyReportTabView` with a new design that surfaces the 5 sections from the unified data model: at-a-glance metrics, today's highlights, action required, risks & anomalies, and tomorrow's focus. Integrates with `ChatMonitor.loadDailyReport()` using the new pipeline.

## Deliverables
1. `Sources/WeChatHUD/Views/DailyReportTabView.swift` — Complete rewrite with:
   - **Metrics row**: 4-5 stat pills (unread, pending actions, overdue, reply debt, highlights)
   - **Today's narrative**: AI-generated or data-fallback narrative section
   - **Highlights section**: Categorized cards with source chat attribution and quoted snippets
   - **Action required**: Prioritized list with urgency badges (critical/high/medium/low)
   - **Risks**: Severity-coded list with source attribution
   - **Tomorrow focus**: AI-generated priority card
   - **WeChat draft**: Copy-paste section with button
   - Loading, empty, and error states
2. `Sources/WeChatHUD/Services/ChatMonitor.swift` — Modify `loadDailyReport()` to:
   - Use `DailyReportBuilder` + `AIDailyReportGenerator` instead of `AIDailyRetrospector`
   - Publish `DailyReport` instead of `AIDailyRetrospector.Retrospective`
3. `Sources/WeChatHUD/Views/ExtendedTabsView.swift` — Update `DailyReportTabView` environment injection if needed

## Acceptance Criteria
- [ ] New `DailyReportTabView` renders all 5 sections with real data
- [ ] Metrics are computed from `DailyReport.metrics`
- [ ] Highlights show category, source chat, and quoted snippet
- [ ] Actions are sorted by urgency with visual badges
- [ ] Risks show severity-coded indicators
- [ ] Copy-paste WeChat draft works
- [ ] Loading state shows during generation
- [ ] Empty state shows when no data available
- [ ] Error state shows when AI fails
- [ ] No visual regressions in other tabs (复盘, VIP, etc.)
- [ ] Build passes, existing tests pass

## Verification Method
1. `swift build` — compile check
2. `swift test` — all existing tests pass
3. Code review: verify SwiftUI correctness, no retain cycles, proper state management

## Out-of-Scope
- Menu bar / settings changes (M4)
- Removing old `AIDailyRetrospector` (will be deprecated, not deleted)
- Changing 复盘 tab UI
- New database tables or migrations

## File Ownership
- Generator writes: DailyReportTabView.swift (rewrite), ChatMonitor.swift (modify loadDailyReport)
- Evaluator reads-only

## Stop Condition
- All acceptance criteria pass, or
- 3 iteration attempts, then escalate

## Agreement Status
AGREED

## Negotiation Log
- Generator proposed: Full UI rewrite with 5 sections
- Evaluator added: Must handle loading/empty/error states, must not regress other tabs
- Generator accepted: Added state handling and regression test to acceptance criteria
- Evaluator added: ChatMonitor.loadDailyReport must use new pipeline
- Generator accepted
