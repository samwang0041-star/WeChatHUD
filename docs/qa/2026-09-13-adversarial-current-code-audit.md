# WeChatHUD 当前代码对抗性质检报告

- 日期：2026-09-13
- 基线：HEAD `b887bc4 chore(release): bump to 1.3.3` + 工作区未提交 peek WIP
- 对照：2026-09-12 全代码审计（基线 `3ff24ac` / 1.2.23）之后的 33 个提交
- 范围：当前工作树（含未跟踪 `IslandGlowLayer.swift` / `IslandPeekTests.swift`）
- 方法：多子代理分面攻击（状态机 / 岛形 UI / P0 回归 / 发送与隐私 / 1.2.23 之后新代码 / 测试诚实度 / 崩溃与并发），根代理逐条对照源码复核；能推翻的已剔除

---

## 一、总体判断

**2026-09-12 的 7 条 P0 在当前树上仍然成立，没有回归。** 分片归并、积压翻页、SafeNumber、自更新 TeamID 钉扎、`screens[0]`、AX `as!`、`/tmp` 启动器日志都还在。

当前工作树的主要风险不在崩溃，而在 **未提交的 `.peek` 形态被测量 sink 掐成瞬切**，以及几条 **自动驾驶 / 隐私旁路** 不在「发文字」护栏上。

`IslandPeekTests` 12 条、`CompactIslandPolicyTests` 13 条、`CompanionMotionTests` 12 条均绿（本轮实测 37/37）。绿的是 PanelState 缝和 glance 文案，**不是** AppDelegate 的 morph，也不是真实 180ms dwell timer。

| 面 | 结论 |
|---|---|
| 2026-09-12 P0 | 全部仍在，未见回归 |
| 未提交 peek WIP | 状态机安全；**形态弹簧在真实链路上会被 `setFrameInstantly` 取消** |
| 发送护栏 | 转账/红包/小程序、群发文字、session cap 仍在 enqueue；**已读不回会在发字之前用 AX 打开微信** |
| 测试 | peek 与若干安全数字仍是 helper / 缝，不是生产路径 |

无新的进程崩溃 P0。下文按修复优先级。

**2026-09-13 晚间已按此单修复 P1 与可安全落地的 P2**（见文末「修复记录」）。本文件保留质检当时的证据，不把修复后的代码改写成「从未有过」。

---

## 二、P1 — 用户可见错误 / 未守护自动化 / 密钥

### P1-1 peek 加宽弹簧被 compact 测量分支掐掉（两条独立审计同时命中）

`Sources/WeChatHUD/App/AppDelegate.swift:236-243` 在 `currentState → .peek` 时启动 mask spring：

```swift
} else if state == .compact || state == .peek {
    self.panel.animateHeight(to: h, width: w, caller: state == .peek ? "AppDelegate.currentState.peek" : "AppDelegate.currentState.compact")
}
```

随后 CompactInboxBar 因左右各 +78pt 重新报告尺寸（`CompactInboxBar.swift:101-103` `reportExtendedSize`）。同一文件的测量 sink（`AppDelegate.swift:338-348`）把 peek 当成 compact 宽度抖动：

```swift
if current == .compact || current == .peek {
    if curr.height > targetSize.height + 8 {
        self.panel.animateHeight(...) // 只有从更高状态收矮才走弹簧
    } else {
        self.panel.setFrameInstantly(height: targetSize.height, width: targetSize.width)
    }
}
```

Peek 是 **同高加宽**（`panelSize(for: .peek)` = notch + 2×wing + 2×78，高度仍是 `notchHeight`）。`32 > 40` 为假，于是走 `setFrameInstantly` → `cancelFrameAnimation(notify: false)`（`FloatingPanel.swift:745-747`）。用户看到的是一帧蹦到 peek 宽，不是 `ui-language.md` 写的「从刘海弹出来」。

失败序列：hover compact → state sink 启动 spring → GeometryReader 上报 ~468×32 → 测量 sink 对 mid-flight `visibleIslandFrame` 比宽度 → 瞬切。`IslandPeekTests` 只驱动 `PanelState`，这条链路零覆盖。本轮 12 条 peek 测试全绿，不能证明 morph。

### P1-2 「已读不回」在群聊 / 未开自动发送时仍会 AX 打开微信

`AutopilotService.processBatch`（`AutopilotService.swift:676-688`）在 `automaticSendHoldReason`（:824）和 `processPendingQueue` 的 `autoSendEnabled` 闸（:1137）**之前**：

```swift
if decision.readNoReply == true {
    // Full-auto mode: read-no-reply executes directly, no human confirmation needed.
    ...
    WeChatLauncher.openChat(named: representative.chatName, searchNames: names)
}
```

重复缓兵之计分支（:761）同样 `openChat`。`ChatMonitor.swift:3056-3067` 写明「开始整理」**不**翻转 `autoSendEnabled`（默认 false），但会把 `autopilotActive = true`，扫描层就会把消息送进 `handleNewMessages`（`ChatMonitor.swift:1364-1380`）。

文字发送仍被 `manualOnlyReason = "群聊消息，请人工确认后发送"` 拦住（:1554-1555），session cap 也持久化。这里破的是 **未值守去前台开群、打已读**，不是把回复发出去。

### P1-3 无 scheme 的 API 地址被补成 `http://`，Bearer 密钥走明文

`AIService.swift:281`：

```swift
if !u.contains("://") { u = "http://\(u)" }
```

随后 `:156-157` 设置 `Authorization: Bearer \(slot.apiKey)`。设置页只检查「填了没有」。用户写 `api.openai.com` 会先走明文。

### P1-4 群筛选把明文群名和样本送出网

`GroupScreener.swift:165` 自己标注 `redacted: false  // group screen sees plain chat names + sample text`。样本只经 `AIService.sanitizeForAI`（占位符），不走 `Redactor` 的人名/手机号码。与回溯路径的脱敏不一致。

### P1-5 光晕画的是无刘海胶囊，VIP 还会带动 30Hz 扫光

`IslandGlowLayer.swift:49-56` 故意 `notchWidth: 0`，发丝线和扫光会横穿摄像头凹槽；外接屏上这条线完全可见。同文件 `:30`：

```swift
let sweep = snap.phase == .working(.analyzing) || snap.glow != .none
```

`ui-language.md`：VIP 只变色相、不改变不透明度；30Hz 扫光只给 AI 整理中。现在 attention/critical 也会挂 `TimelineView(.animation(minimumInterval: 1/30))`。

光晕还读 **未去抖** 的 `aiTracker.isActive`（:18-22），左边点读 `heldAIActive`（450/900ms hold，`CompactInboxBar.swift:282-297`）。同一扇窗两套「AI 在工作」。

### P1-6 飞行中目标变高仍会 `setFrame`

`cf53e36` 写「运动期间窗口不 resize」。`FloatingPanel.swift:553-557` 在 retarget 时若新目标超出当前 cover，仍 `setFrame(needed, display: false)`。行展开/更高 banner 叠在展开弹簧上，会付回那个 29–42ms 丢帧。更准确的承诺是：**每个 run 最多一次 resize，飞行中长高再加一次。**

---

## 三、P2

- **菜单与 peek 矛盾**：`isCompanionOpen = currentState != .compact`（`AppDelegate.swift:664`）把 peek 当成已打开，菜单显示收起；点击却 `goExtended()`（:740）。顺带在未打开收件箱时预热 action 行。
- **断连态 peek 点击进设置**：左翼 `peekPill` 走 `leftWingCopy.route`；`connectionProblem` → `openWeChatConnection`。文档写「点击打开收件箱」。右槽是 `Color.clear` 占位（:74-78），不是第二颗按钮。
- **网页更新通道可能把 -rc 当正式版**：`AppUpdateService.swift:407-420` 抓页面上所有 `/releases/tag/` 取最高版本，无 prerelease 过滤。安装仍有 TeamID 钉扎。
- **已删的 GitHub Token 仍可能留在 sqlite**：`17d66ac` 去掉了字段，没有 scrub。下次序列化设置会自愈。
- **`positionAtTop` 在弹簧飞行中改锚点**：mask 跟新屏，spring 仍用旧 cover（`FloatingPanel.swift:326-333` vs `:683`）。热插拔/换屏时岛屿会偏一截。
- **积压预算按白名单顺序吃**：`ScanEngine.swift:604-606` 不推进水印是对的，但后面的会话连最新页也要等前面耗完 6 页预算。
- **每小时发送上限只在内存**：`globalSendTimestamps` 重启清零；每会话 50 条是落盘的。
- **stdout 仍打会话名**：`AutopilotService.swift:843` 等；同文件主动草稿路径已经故意去掉。
- **默认缓存仍在 `/tmp/wechat_hud_cache`**：创建时 `chmod 0700`（`WeChatReader.swift:146-148`），不是全局可读，但名字在 sticky tmp 里可见。
- **`openMorph` / `closeMorph` 没有接到窗口**：只被测试和 `rowExpand()` 引用。窗口 morph 是 `IslandMotion` + CALayer。
- **Hover dwell timer 用默认 RunLoop mode**：菜单跟踪时 180ms 计时器不走；测试把 delay 改成 30s 再调用 `finishHoverExpandIfPending()`，生产 timer 从未被等过。
- **预览刘海回退不一致**：CompactInboxBar 200 vs HUDRootView 16。
- **发丝线圆角 22 vs mask 在 32pt 高度上 clamp 到 ~16**：peek 是唯一在 32pt 高度画外圈发丝线的状态。

---

## 四、2026-09-12 P0 回归

| 原 P0 | 当前 | 证据 |
|---|---|---|
| `Int(Double)` trap | 仍修复 | `SafeNumber.swift`；AI/HTTP/AX 入口不再裸 `Int(` |
| 分片只读第一个库 | 仍修复 | `WeChatReader.getMessages` 探全部 `message_N.db` 再归并 |
| 有游标时积压 >100 丢弃 | 仍修复 | `whitelistFetchLimit` 不再按 `hasCursor` 砍成 100；向后翻页 + 水印扣留 |
| 自更新无签名 | 仍修复 | `verifyIncomingSignature` + `SecStaticCodeCheckValidity` + TeamID |
| `NSScreen.screens[0]` | 仍修复 | 全仓 0 处；`screens.first` 且调用方 `guard` |
| AX `as!` | 仍修复 | `Sources/` 无活 `as!` |
| `/tmp/wchud_launcher.log` | 仍修复 | 旧文件删除；启动器日志已迁走 |

群聊文字强制人工确认、媒体 0.7x、金融 pending、洞察冻结/不稳定 id 仍在。冷却窗口仍是进程内（重启丢失）——与上次一样，未升格。

---

## 五、被推翻（子代理提了、源码对不上）

- **「左右 peek 药丸同一控件」**：右边是 `Color.clear` + `allowsHitTesting(false)`，只为把刘海留在几何中心。只有左边有 glance。
- **「`if isAdmitted, private || groupAt` 让 groupAt 绕过准入」**：Swift 的 `if a, b || c` 是两个条件，即 `a && (b || c)`。`groupAt` 仍要 `isAdmitted`。
- **`formatResponseTime` 遇 NaN 崩进程**：`computeAvgResponseTime` 只平均 `(0, 86400)` 的 delta，空则 0；`Int(seconds)` 只在 `< 60` 分支。不是活崩溃。
- **`Dictionary(uniqueKeysWithValues:)` 仍会因重复用户名 trap**：活着的那处是 `allStats: [String: ChatStatsData]`，键本来就唯一。
- **peek 会在鼠标离开后打开收件箱 / 卡死**：`mouseExited` 取消 dwell，timer 再检查 `isMouseInside && currentState == .peek`，`collapsesWhenMouseOutside` 含 `.peek`。
- **发丝线画了两层**：`IslandGlowLayer` 只挂 compact/peek；`HUDMonitorSurface.expandedChrome` 只挂 extended/notification/detail。
- **未跟踪的 `IslandGlowLayer.swift` 让 `swift test` 编不过**：SPM 按目录收源，本轮 37 条测试已编过并全绿。风险是 `git add -u` 漏掉它，干净 checkout 的 HEAD 不含这个引用。

---

## 六、测试诚实度（针对本轮 WIP）

`IslandPeekTests` 全部把 `hoverExpandDelayProvider` 设成 `{ 30 }`，再用 `finishHoverExpandIfPending()` 推进。`testLeavingPeekBeforeDwellDoesNotOpenInbox` 等 0.35s 却面对 30s 的 hover timer，断言几乎是恒真。没有测试：

1. 真实 180ms timer + generation + `isMouseInside`（仍缺；dwell 仍靠 `finishHoverExpandIfPending` 缝）
2. AppDelegate 测量 sink 在 peek 宽度变化时不 `setFrameInstantly`（已用 `IslandMeasurement.sizeAction` 纯函数钉住）
3. `IslandGlowLayer` 的凹槽/扫光/去抖（代码已改；仍无直接挂载 glow 的渲染测试）

`AutopilotGuardrailPipelineTests` 仍只覆盖金融 pending、贴纸跳过、关群处理、文本进缓冲。置信度 0.8、媒体 0.7x 跨阈、敏感词、session cap、群处理打开、以及一次真正 `executeSend` 成功，都还只在 helper 上。

---

## 七、方法与边界

- 子代理分面：island 状态机、island UI、P0 回归、发送/隐私、`3ff24ac..HEAD`、测试诚实度、崩溃/并发。
- 根代理对每条结论回源码；两条独立代理同时打到 P1-1，视为高置信。
- **没有**用 computer-use 看真实悬停 morph（上次状态精修用过 preview hold）。P1-1 是代码路径论证。要实锤需要 `make preview` + 悬停，且不要动用户鼠标。
- 质检当时只跑了与 WIP 相关的 37 条。修复后过滤跑 **178 条，0 失败**；全量 `swift test` / 真机悬停 morph 仍未做。

---

## 八、修复记录（同日）

| 条目 | 落地 |
|---|---|
| P1-1 peek 瞬切 | `IslandMeasurement.sizeAction`：peek 一律 `.animate`；compact 同高大幅收窄也不 snap。测量 sink 只跟这个纯函数。 |
| P1-2 已读不回开微信 | `shouldOpenChatForReadReceipt`：必须 `autoSendEnabled && !isGroup`，否则不 sleep、不 `openChat`。 |
| P1-3 明文 HTTP | 无 scheme 默认 https；localhost / 127.0.0.1 / ::1 仍 http。 |
| P1-4 群筛选明文 | `GroupScreener` 用 Redactor：`chat_name` 代号、样本脱敏、`chat_username` 保留；ledger `redacted: true`。 |
| P1-5 光晕 | 真实 `notchWidth`；扫光只给 `.working(.analyzing)`；跟左边共用 `heldAIActive`。 |
| P1-6 飞行中 resize | 行为保留（stage 不够必须长高）；文档改成「live run 可以再长 stage」。换屏时 `positionAtTop` 先取消弹簧。 |
| P2 菜单 / timer / 预览刘海 / token / -rc / stdout | peek 不算打开；dwell timer 进 `.common`；刘海回退 200；启动 scrub `githubToken`；网页通道忽略 prerelease；日志去掉会话名。 |

验证：`swift test` 过滤 IslandRowExpand / IslandPeek / CompactIslandPolicy / CompanionMotion / AutopilotSafety / AutopilotGuardrailPipeline / AIService / RetrospectivePrivacy / AppUpdate* → **178 条，0 失败，5 条 live 门禁跳过**。
