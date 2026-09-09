# Accessibility permission identity audit (2026-09-08)

This is a read-only snapshot. No TCC database, System Settings switch, app
signature, running process, or permission state was changed.

## Observed identities and processes

| Process | Path | Bundle ID | Signature identity | CDHash |
|---|---|---|---|---|
| installed app, PID 45968 | `/Applications/WeChatHUD.app/Contents/MacOS/WeChatHUD` | `com.wechat-cli.hud` | Developer ID Application: wang Yuzhao (`SL3HYH77EF`), notarization ticket stapled | `468352fdcf7a9d9cf92d8c8c0b6399c34718473d` |
| preview app, PID 96149 | `.build/WeChatHUD Preview.app/Contents/MacOS/WeChatHUD` | `com.wechathud.product-preview` | ad hoc (`TeamIdentifier=not set`) | `9457620f25fb2df4f21314288bfd37f74bc7adfe` |

Both processes were alive during the audit. The installed app was launched at
16:12:34 local time; the preview was launched at 17:49:58. The installed app's
current bundle metadata is version 1.1.4 and its Developer ID signature was
timestamped 16:09:50. The preview Makefile deliberately changes the bundle ID
and signs ad hoc (`Makefile:49-62`), so it is a separate TCC identity and must
not be used as evidence for the installed app's permission.

The running WeChat process is `/Applications/WeChat.app/Contents/MacOS/WeChat`
(PID 933), with `WeChatAppEx` children. This is the target app; its identity is
separate from the caller identity checked by `AXIsProcessTrusted`.

The live native window inspected through Computer Use was obtained by resolving
the exact `/Applications/WeChatHUD.app` path. Its AX tree identifies the window
as “WeChatHUD” / “WeChat HUD” and shows the installed app's real synced contacts
and settings; this is consistent with PID 45968, although AX itself does not
expose the executable path. The shell `ps`/`lsof` result is the path attribution
evidence for that window's process.

## Permission probe and behavior

The production settings view initializes and refreshes the system-owned probe
with `AXIsProcessTrusted()` (`MacExperienceSettingsView.swift:9-10, 114-121`).
It does not mirror a local setting. The Accessibility settings button only
opens the system pane (`:29-35`); the explicit “重新检查权限” action calls
`refresh()` (`:37-46`), and the view also refreshes when the app becomes active
(`:74-75`).

Actual WeChat UI actions use the same caller-scoped check with prompt enabled:
`AXIsProcessTrustedWithOptions` gates chat navigation
(`WeChatLauncher.swift:154-165`) and paste/send (`:648-663`). A false result
therefore correctly prevents input automation while database reading remains
available.

## Evidence and interpretation

The current source QA record explicitly leaves “installed app accessibility-
trust mismatch” open (`docs/qa/2026-09-08/workspace-audit/audit.md:161-165`).
The installed app is now a newly signed Developer ID build, while the preview
has a different bundle ID and an ad-hoc identity. If the macOS switch was
enabled for an older build, the preview, or a prior signature, that switch can
appear enabled while the currently running installed process still returns
false. This is a hypothesis consistent with the identity evidence, not a
confirmed TCC row: the per-user TCC database was not readable in this session,
and no `tccd` log event naming either WeChatHUD identity was emitted in the
last two hours.

The existing `installed-app-check.json` is not an Accessibility probe. The
`self-check` command dispatches `ProductSelfCheck.run()` before `NSApplication`
starts (`main.swift:8-14`); that routine reads source/database capabilities and
never calls `AXIsProcessTrusted` (`ProductSelfCheck.swift:6-79`). Its JSON file
therefore cannot establish which process was trusted. The artifact has no
process path, PID, bundle ID, or TCC result. If it was run by invoking the
installed binary from a terminal, it still only proves source-read capability;
if it was run from a development binary, the same limitation applies.

## Safe next diagnostic

With both apps closed, launch only `/Applications/WeChatHUD.app` and record the
exact path, bundle ID, and Developer ID/CDHash shown above. In System Settings
→ Privacy & Security → Accessibility, inspect the row corresponding to that
installed app (not the Preview row), then return to the app and press
“重新检查权限”. Record the resulting `AXIsProcessTrusted()` state and the
row's displayed app path. If the row points elsewhere or the state remains
false, the next user-authorized step is to remove/re-add only the installed
Developer ID app in that pane, then relaunch it; do not infer success from the
switch alone—recheck the in-app probe and a single guarded navigation attempt.


## Later direct native observation

Root opened the exact `/Applications/WeChatHUD.app` in CUA, selected 连接与数据, and clicked 重新检查权限. The live app reported 当前应用仍未获得授权. The same page showed a recent successful sync at 18:03, so database reading and operation permission remain separate. Opening the app's permission-settings link reached the System Settings page titled 设备控制和数据访问. Its accessibility tree explicitly showed both WeChatHUD and WeChatHUD Preview switches ON. Evidence screenshot: `system-permission-rows.png`. No switch was toggled and no row was removed or added.

This supersedes the earlier statement that no direct system row was observed. It confirms a display/probe discrepancy, but the list does not expose each row's executable path or signing requirement. A subsequent row-selection attempt produced unexpected selected rows; no attribution is drawn from it. Stale identity, responsible-process attribution, and OS permission mapping are still hypotheses rather than established causes.


## Runtime and signature revalidation

Current host reports macOS 27.0 (26A5425a), not the historical Xcode/macOS versions in project notes. PID 45968 is parented by launchd (PPID 1), with the installed application executable path. `codesign --verify --deep --strict --verbose=2 /Applications/WeChatHUD.app` succeeds, including the bundled libzstd library; its designated requirement uses bundle com.wechat-cli.hud and Team SL3HYH77EF. These checks rule out an invalid on-disk signature at this observation, but do not prove which code requirement the system permission row retained. PPID alone does not determine TCC responsible-process attribution.

Apple's [AXIsProcessTrusted documentation](https://developer.apple.com/documentation/applicationservices/1460720-axisprocesstrusted) defines the probe as current-process accessibility trust. The available SDK header retains that declaration. No verified macOS 27 replacement permission API or documented explanation of this mismatch was found in this pass; do not blame the OS version based on correlation.


## Diagnostic capture added to current source

Explicit 复制诊断概况 now includes a current-process snapshot: OS/app version, bundle identifier, location category, PID, AX trust, and preview flag. It never exports the bundle path or reads another application's accessibility tree, and does not request permissions. Location tests reject `/tmp/Applications` and recognize explicit system/user application roots. Two focused tests pass; root independently ran swift build successfully. This code is not yet installed in the signed 1.1.4 app, so no new installed-app snapshot is claimed. The underlying permission mismatch remains unresolved.
