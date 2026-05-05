# Evaluation Rubric

## Blocking Criteria

- FAIL if stale retrospective data can still appear as today's highlights/todos.
- FAIL if AI failure leaves `narrative`, `tomorrowFocus`, and `wechatDraft` empty for a report with local signals.
- FAIL if the Daily Report tab can only express loading/success and not degraded/error/freshness.
- FAIL if `swift test --filter DailyReport` does not pass.
- FAIL if changes overwrite or revert the six pre-existing dirty files.

## Dimensions

- Correctness, 35%: same-day filtering, deterministic local fields, accurate metrics/actions/risks.
- User-visible functionality, 25%: tab communicates status, fallback, refresh, and no-data states clearly.
- Minimal integration risk, 20%: changes stay in the requested chain and keep model compatibility manageable.
- Verification, 20%: tests cover new behavior and real Swift commands pass.

## Acceptable Patterns

- A local builder sets fallback narrative/draft before AI.
- AI enrichment can replace local text when valid, while failure leaves local text intact and records degraded state.
- UI labels a report as "本地生成" or "AI 增强" with last refresh time and error message.

## Failing Patterns

- Hiding AI failure while showing empty or generic copy.
- Counting yesterday or last week's retrospective highlights as today's high points.
- Only adding view text without changing data contract/tests.

## Verification Plan

1. Inspect actual diff for daily chain and tests.
2. Run `swift test --filter DailyReport`.
3. Run `swift build` if the focused tests pass.
4. Read `30-generation-report.md` only after direct diff/test inspection, then cross-check claims.
