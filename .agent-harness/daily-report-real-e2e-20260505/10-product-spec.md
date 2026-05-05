# Product Spec

## Outcome

Make the Daily Report tab deliver a readable, deterministic first slice of today's work status even when AI or retrospective data is unavailable.

## Target User

A WeChatHUD user opening the "日报" tab near the end of a workday to understand what needs attention and copy a short daily-report draft.

## Scope

- Build today's report from local pending asks, commitments, reply debt, stats, recalled messages, and same-day retrospective data when available.
- Exclude stale retrospective highlights and todos from today's report.
- Produce deterministic local narrative, tomorrow focus, and WeChat draft before any AI enrichment.
- Preserve AI enrichment as an optional upgrade path.
- Expose loading, refreshed, degraded, and error state in the tab so refresh behavior is understandable.
- Add focused tests for stale-retrospective exclusion and local fallback content.

## Non-Goals

- Full redesign of the daily tab visual system.
- New persistence table for daily reports.
- End-to-end UI automation of the macOS panel.
- Reworking the retrospective pipeline itself.
- Touching unrelated dirty insight/settings files.

## Acceptance Criteria

- Opening the tab produces local readable content after the builder runs; AI failure cannot leave the report empty.
- A report with only local stats/action data has a non-empty narrative, tomorrow focus, and copyable WeChat draft.
- If no local signals exist, the UI still shows a calm "no work items" state rather than an indefinite spinner or hollow AI copy.
- Stale retrospective runs from before today are not counted as today's highlights/todos/actions.
- If AI enrichment fails, the report remains usable and the UI labels the result as local fallback/degraded.
- Force refresh has clear feedback and does not misuse old generated timestamps.
- Tests prove the core fallback and stale-data behavior.

## Risks

- `DailyReport` is used by multiple views and export code; model additions must stay source-compatible where possible.
- `ChatMonitor` is large; keep changes minimal and isolated.
- SwiftUI view tests are not present, so UI behavior should be backed by model state plus build verification.

## Milestone

One vertical slice: deterministic local daily report plus UI degradation metadata and tests.
