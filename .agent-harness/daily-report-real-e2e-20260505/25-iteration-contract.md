# Iteration Contract

Status: AGREED

## Cycle Goal

Deliver a first usable Daily Report slice that is deterministic without AI and does not present stale retrospective data as today.

## Deliverables

- `DailyReport` carries source/degradation metadata.
- `DailyReportBuilder` filters retrospective input to today's overlap and fills local fallback narrative, tomorrow focus, and WeChat draft.
- `AIDailyReportGenerator` preserves local fallback fields and marks AI success/failure state.
- `ChatMonitor.loadDailyReport` publishes a local report before awaiting AI and exposes errors/degraded state.
- `DailyReportTabView` shows loading/refresh/fallback/error/freshness states and always renders deterministic content when a report exists.
- New or adjusted tests under `Tests/WeChatHUDTests` prove fallback and stale-retrospective behavior.

## Acceptance Criteria

- Reports with only local pending ask/commitment/reply debt/stats produce readable non-empty `narrative`, `tomorrowFocus`, and `wechatDraft`.
- Reports with no local signals produce a deterministic quiet-day message, not empty copy.
- A completed retrospective run whose `rangeEnd` is before today's start contributes zero highlights and todos to today.
- Same-day retrospective data still contributes highlights/todos.
- AI failure does not erase local fallback fields and produces an explicit fallback status/error in the model.
- UI contains visible status text for generating, refreshing, local fallback, AI enhanced, error, and last update.
- `swift test --filter DailyReport` passes.
- `swift build` is attempted and result recorded.

## Verification Method

- Direct diff inspection.
- `swift test --filter DailyReport`.
- `swift build`.
- Harness checkpoint and final gates.

## Ownership

Generator may edit only:
- `Sources/WeChatHUD/Data/DailyReport.swift`
- `Sources/WeChatHUD/Services/DailyReportBuilder.swift`
- `Sources/WeChatHUD/Services/AIDailyReportGenerator.swift`
- `Sources/WeChatHUD/Services/ChatMonitor.swift`
- `Sources/WeChatHUD/Views/DailyReportTabView.swift`
- focused `Tests/WeChatHUDTests/*DailyReport*Tests.swift`
- harness files in this workspace

Evaluator is read-only for product files.

## Out of Scope

- Changing AI provider config.
- Building a new persistence schema.
- Editing the existing dirty insight/settings/app delegate files.
- Full visual redesign.

## Stop Condition

One cycle passes all acceptance criteria, or a blocking Swift/tooling issue is recorded with evidence.

## Negotiation Log

- Generator proposed deterministic local fallback plus metadata.
- Evaluator required explicit stale-retrospective tests, AI-failure preservation, visible UI status text, and real Swift verification.
- Generator accepted within minimal chain scope.
