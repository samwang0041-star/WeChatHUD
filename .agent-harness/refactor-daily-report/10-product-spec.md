# 10-product-spec.md — Daily Report Refactor

## Problem Statement

The current **日报 (Daily Report)** tab is broken in three fundamental ways:

1. **Shallow data source**: It feeds AI only `pending_asks` (a simple todo-like table) — not actual chat content. The "today summary" is a generic paraphrase of a task list, not an insightful reading of what actually happened in conversations.

2. **No relationship to 复盘**: The user runs a sophisticated RetrospectiveJob that extracts highlights, todos, risks, and decisions from real chat history. The Daily Report ignores all of this rich data and produces a separate, disconnected narrative.

3. **Low utility**: The output ("today summary" + "tomorrow first thing" + a WeChat draft) is boilerplate. Users glance at it once and never return. It does not answer "what matters today" or "what should I do next."

## Desired Outcome

A **unified daily report** that:
- Pulls from the same rich data pipeline as 复盘 (highlights, todos, commitments, reply debt)
- Surfaces what actually happened today with **context and evidence**
- Tells the user **what needs their attention** with clear priority
- Provides **actionable next steps** grounded in real conversation state
- Is visually scannable — a user should get value in 5 seconds

## Target User

A busy professional who processes many WeChat conversations daily. They want a quick, authoritative briefing at end-of-day (or on demand) that answers: "What happened? What do I owe? What owes me? What's at risk?"

## Scope

### In Scope
1. **Data integration**: Daily Report reads from `review_runs`, `review_highlights`, `review_todos`, `pending_asks`, `commitments`, `replyDebtItems`, and `recalledMessages` — unified view, not siloed.
2. **New data model**: `DailyReport` struct that aggregates and enriches data from all sources.
3. **New AI prompt**: A single, context-rich prompt that feeds the unified model to produce structured output (not the current shallow prompt).
4. **UI redesign**: Replace `DailyReportTabView` with a new design that shows:
   - **At-a-glance metrics** (messages, unread, pending todos, overdue commitments, reply debt score)
   - **Today in review** (categorized highlights from today's chats with evidence)
   - **Action required** (prioritized todos + commitments + reply debt, sorted by urgency)
   - **Risks & anomalies** (recalled messages, flagged uncertain highlights, overdue items)
   - **Tomorrow's focus** (AI-generated priority based on deadline proximity and conversation momentum)
5. **Automatic generation**: Trigger on schedule (e.g., 17:45) or when user opens the tab, with freshness check.
6. **Copy-paste WeChat draft**: Preserve the existing utility but improve content quality.

### Out of Scope
- Removing or changing the 复盘 tab/window — it stays as the deep-dive tool
- Changing the RetrospectiveJob pipeline — we consume its output, not modify it
- New database tables — we reuse existing retrospective + ask + commitment tables
- Real-time push notifications for daily report

## Constraints
- Swift/SwiftUI macOS app
- Must work with existing `ChatMonitor` + `HUDStore` architecture
- AI calls must respect existing `AIServiceProtocol` and ledger/audit patterns
- Must not increase daily AI token budget beyond ~2× current (unified prompt replaces multiple shallow ones)

## Milestones

### M1: Data Layer — Unified Daily Report Model
- Define `DailyReport` struct with sections: `metrics`, `highlights`, `actions`, `risks`, `tomorrowFocus`
- Build `DailyReportBuilder` that queries all existing tables and assembles the model
- No AI yet — pure data aggregation

### M2: AI Layer — Rich Prompt + Structured Output
- Design new prompt that feeds `DailyReportBuilder` output to AI
- Define JSON schema for AI response (today narrative, prioritized actions, risk summary, tomorrow focus, WeChat draft)
- Implement `AIDailyReportGenerator` service with retry + audit

### M3: UI Layer — New DailyReportTabView
- Redesign with the 5 sections listed in scope
- Use existing dark theme, maintain visual consistency with 复盘 tab
- Support loading, empty, error, and success states
- Keep copy-paste WeChat draft

### M4: Integration + Polish
- Wire `ChatMonitor.loadDailyReport()` to new pipeline
- Ensure freshness logic (>30 min stale) still works
- Menu bar integration (if any changes needed)
- Settings integration (if any changes needed)

## Acceptance Criteria
- [ ] Daily Report shows real highlights from today's chats with source attribution
- [ ] Action section combines todos, commitments, and reply debt sorted by urgency
- [ ] Risks section surfaces overdue items and recalled messages
- [ ] AI-generated narrative is grounded in actual conversation evidence, not generic
- [ ] WeChat draft is copyable and quality-improved
- [ ] Load time < 3s when data is cached, < 15s when AI generation required
- [ ] No regressions in 复盘 tab functionality

## Risks
- **AI cost**: Richer prompt = more tokens. Mitigation: prompt compression, caching, and strict max token limits.
- **Data staleness**: If 复盘 hasn't run today, Daily Report has no highlights. Mitigation: gracefully degrade to pending_asks-only mode with clear UI indication.
- **Scope creep**: Don't rebuild 复盘 inside Daily Report. Daily Report is a *summary* surface, not a replacement.
