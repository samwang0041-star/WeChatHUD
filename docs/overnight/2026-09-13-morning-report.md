# WeChatHUD overnight morning report — 2026-09-13

## Mode
Local Mac assistant edits only (no Codex, no Cursor Cloud Agent). Autopilot guardrails unchanged.

## PR
https://github.com/samwang0041-star/WeChatHUD/pull/5  
Branch: `cursor/overnight-evolution-266d`  
HEAD: see latest on PR branch (HUDStore serial-queue wave complete).

## Shipped overnight (local slices)

1. **Slice 4** — drafts / autopilot / classification readers + **statement-cache reset fix** (pinned read txn broke due_at migration tests)
2. **Slice 5** — ignored/dismissed/asks/cache/memory/timing/pending sends/profiles + open pending variants
3. **Slice 6** — VIP / recalled / AI audit / feedback / pending asks (fixed SQL literals)
4. **Slice 7** — DiscussionQueue onto serial `exec` / throwing query helpers
5. **Slice 8** — Autopilot write prepares onto `withCachedStatement`
6. **Slice 9** — `OffMainWork` (no Task.detached in recommendation scan) + schema v3 retrospective indexes

Earlier same night (already on PR before this wave): Keychain API keys, relationship radar pane, Autopilot pipeline tests, Mac compile/XCTest fixes.

## Verification (each slice)
`swift test` → **1519** XCTest (15 skipped) + **70** swift-testing, **0** failures  
`swift build -c release` → pass

## Autopilot guardrails (unchanged)
Default off; confidence 0.8; sensitive words; finance pending; **group chats manual confirm**; session cap 50.

## Suggested next
- WeChatReader actor boundary (evolution-plan P1)
- Optional live AI trend language behind explicit opt-in (not default)

## WeChatReader note
Already uses `NSRecursiveLock` for wrapper state. Full actor facade deferred to next session (ScanEngine batch APIs + caller migration).

- Slice 11: ClipboardGuard @MainActor; Autopilot serialSend await restore (1520+70).

- Slice 12: WeChatReader getMessagesBatch + ScanEngine unread/autopilot wiring (1521+70).

- Slice 13: WeChatReaderActor + ScanEngine prep/batch via actor (1522+70).
