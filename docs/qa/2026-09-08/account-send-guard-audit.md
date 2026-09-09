# Account-to-send guard audit (2026-09-08)

## Scope

Read-only source audit of manual reply and autopilot sends. The concrete risk checked was: the HUD reader/composer is bound to account A while the running WeChat process is logged into account B, with A's old directory still present.

## Findings

The send path has guards designed to reject that split-brain case. Both `ConversationDetailView.sendReply()` and `AutopilotService.serialSend()` call `WeChatLauncher.sendMessageDetailed()` (`Views/ConversationDetailView.swift:190-210`, `Services/AutopilotService.swift:859-869`). There is no alternate direct keyboard-send path in either caller.

`WeChatLauncher.performTextAction()` binds the exact running process (PID, launch date, bundle ID) and the current `AppDelegate.reader.dbDir` before navigation (`Services/WeChatLauncher.swift:648-660`). `accountFailure()` then probes only that PID's open database files through `WeChatAccountEvidence.inspect()` and requires the reader root to remain unchanged across the async probe (`Services/WeChatLauncher.swift:754-766`). A process using B while the reader remains on A returns `.mismatch`; missing/ambiguous evidence returns `.accountUnverified`. Both stop before navigation/paste/send.

The guard is repeated after navigation/focus, before paste, and immediately before the send key (`Services/WeChatLauncher.swift:674-697`). It also rechecks process identity using PID + launch date (`Services/WeChatLauncher.swift:769-775`), so process replacement with a reused PID is rejected. The lsof probe and the final key event are still separate operations; an account change in that narrow interval is not atomically prevented by this source path.

`WeChatAccountEvidence` accepts only one canonical `db_storage` root from NUL-delimited `lsof` regular-file evidence. A/B roots are intentionally ambiguous and rejected (`Services/WeChatAccountEvidence.swift:13-21`, `:28-42`). Thus an old A directory remaining on disk does not authorize a B process; directory enumeration is not used by this send guard.

`WeChatReader.hasAccountSwitched()` is deliberately weaker: it only reports a missing configured root (`Data/WeChatReader.swift:138-143`). It can fail to notice a live account switch when A remains on disk, and is used by scan/classification paths. This does not bypass the explicit send checks because `performTextAction()` independently requires process-open-file evidence.

There is a separate startup boundary: `AccountStoreCoordinator.selectedRoot()` chooses a sole on-disk candidate when the setting is `auto` (`Data/AccountStoreCoordinator.swift:172-179`), and bootstrap uses that result for the reader/store (`:136-169`). This is selection/discovery, not proof of the currently logged-in process. The connection setup policy prefers a single process-observed root when available, but also falls back to a unique candidate (`Data/ConnectionSetupPolicy.swift:35-65`); callers should therefore treat the resulting configured root as a binding that still needs the send-time process evidence.

## Receipt / projection behavior

Manual sends additionally require a new outgoing message in the reader snapshot before reporting success (`Views/ConversationDetailView.swift:213-229`; `Services/ManualReplyReceipt.swift:4-29`). Autopilot verifies a new outgoing row in the configured `chatUsername` after the UI send (`Services/AutopilotService.swift:872-901`). These receipts are useful confirmation but are downstream of the pre-send account guard.

## Test coverage and remaining boundary

`Tests/WeChatHUDTests/WeChatAccountEvidenceTests.swift` covers matching A, mismatching B, ambiguous A+B roots, missing/non-regular evidence, wrong PID, timeout/truncation, and PID/launch-date replacement (`:12-100`). There is no integration test invoking the private `performTextAction()` against a fake AX tree, and no live two-account WeChat test (the existing probe explicitly uses a synthetic file and never a real WeChat process, `:86-99`). Therefore source-level evidence supports the guard, while real-process lsof/AX behavior remains an acceptance-test boundary.

## Audit conclusion

For the stated A-reader/B-current-WeChat scenario, the source checks are designed to stop the send with account mismatch/unverified before text is pasted or submitted. This is not an atomic guarantee across the final probe and key event, and no live dual-account AX/send orchestration test establishes that race boundary. The residual weakness also includes non-send scans/UI state that rely on `hasAccountSwitched()` and may continue while A's directory persists; that should not be treated as proof of the active account.


## Separate persistence correction found during review

`DeviceSettingsStore.confirmLegacyAccountIdentity` previously updated its in-memory document before the atomic disk write. It now changes a candidate and publishes it only after persistence succeeds. The new regression replaces a temporary settings destination with a directory to force rename failure, verifies identity remains nil, removes the blocker, retries, and verifies the binding survives reload. AccountStoreCoordinatorTests: 9 passed. Root inspected the failure/retry assertions and independently completed a debug build. No production account data or binding was changed.
