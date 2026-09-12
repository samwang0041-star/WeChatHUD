# Overnight report — 2026-09-13

Cloud agent run on Linux. This package is macOS-only (`swift test` / `swift build -c release` were not executed here). New and touched XCTest files are intended to keep the existing live-skip gates.

Autopilot defaults were not changed: `autoSendEnabled=false`, confidence `0.8`, sensitive-word hold, finance force-pending, group messages manual-confirm, session cap `50`.

## Wave A — security (evolution-plan P0)

Shipped:

- `KeychainSecretStore` + `InMemorySecretStore`. `AIProviderSlot.apiKey` is hydrated in memory; SQLite / device-settings JSON keep `keychainItemRef` and an empty key.
- Two-phase persist: Keychain write + read-back, then strip SQLite. Read-back mismatch leaves plaintext in place. Empty key + existing ref keeps the secret (JSON round-trip); empty key + no ref deletes it.
- `~/.wechat-hud` (and HUD db / cache / launcher logs / media-cache) go through `SecureFileManager`: directories `0700`, files `0600`. Symlinks are not chmod'd.
- Remote `http://` AI endpoints throw `AIError.insecureCleartext` in `AIService.send` / `fetchModels`. Loopback HTTP (`localhost`, `127.0.0.1`, `::1`) stays allowed.
- Codex `auth.json`: `lstat` rejects symlink, wrong owner, or mode bits outside `0640`.
- `ai_audit` stores `sha256:<hex>` + redacted 240-char snippet unless `WCHUD_AI_AUDIT_RAW=1`.

Tests: `SecurityRegressionTests`, `CodexAuthSecurityTests`, plus a real `AIService.complete` cleartext rejection (throws before any URLSession hop).

Not done (evolution-plan leftovers): request-time `AIPrivacyPipeline` on every outbound prompt; zstd/XML DoS hard caps (still P4).

## Wave B — storage / concurrency

Shipped:

- `HUDStore` serial queue (`com.wechathud.hudstore`) with re-entrant `perform` / `withDatabaseMutex`. Cached statement paths and `getSetting` hop onto it. Sync API kept for tests.
- `SchemaMigrator` + `PRAGMA user_version`. Current version `2` creates `chat_insight_daily` and `relationship_radar`.
- ChatMonitor scan no longer uses `nonisolated(unsafe)` store or `Task.detached`. Insight reload uses `DispatchQueue.global` + continuation.

Tests: `HUDStoreConcurrencyAndMigrationTests` (idempotent v0→v2, 8×80 mixed settings/audit/cache).

Leftover: many HUDStore methods still `sqlite3_prepare_v2` on `db` outside the statement cache (whitelist, sync_state, contacts, …). They are FULLMUTEX-protected but not on the Swift serial queue. WeChatReader is still `@unchecked Sendable`, not an actor.

## Wave C — 关系雷达

Partial delivery, as allowed:

- Model: `DailyInsightPoint`, `RelationshipRadarSnapshot` (attitude / tone / silence / trend).
- Store: upsert/load daily facts + snapshots (schema v2).
- `RelationshipRadarService`: deterministic trends from **≥2 days** of facts; single-day snapshot stays `attitudeUnknown` and has no `moodShift`.
- Single-day `ChatInsightResult` still has no `attitudes` / `tone_changes` / `mood_shift` (`reservedInferenceKeys`). Analyze-entry writes a fact point only.
- Global briefing prompt `chat_insight_global_v2` consumes `{radar_summaries}`; summaries are redacted before encode.
- UI stub: `RelationshipRadarView` on the insight overview dashboard.

Not done: dedicated radar pane, live AI trend language, refresh from a scan tick.

## Wave D — pipeline tests

`AutopilotGuardrailPipelineTests` now drives the real actor path, not only helpers:

- group `@` with `handleGroupAt=true` still queues `manualOnlyReason = 群聊消息，请人工确认后发送`
- image type `3` + model confidence `0.9` → `0.7×` decay → hold
- generated reply containing `转账` → hold
- `testingSetSessionSent(50)` + `testingExecuteSend` → cap block before WeChat/AX

`AIService.complete` is stubbed with localhost HTTP + `URLRequestRecorder` so the generator/parser/enqueue chain runs.

## Tests / build

| Command | Result |
|---|---|
| `swift test` | Not run — Linux cloud agent, macOS SwiftUI/AppKit package |
| `swift build -c release` | Not run — same |

Please run on a Mac:

```bash
swift test
swift build -c release
swift test --filter AutopilotGuardrailPipelineTests
swift test --filter SecurityRegressionTests
swift test --filter RelationshipRadarTests
swift test --filter HUDStoreConcurrencyAndMigrationTests
```

Existing live skips (`WCHUD_LIVE_COMPANION_AI`, no local WeChat DB) stay as explicit skips.
