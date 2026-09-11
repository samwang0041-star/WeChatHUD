# WeChatHUD 全代码对抗性质检报告

- 日期：2026-09-12
- 基线提交：`3ff24ac chore(release): bump to 1.2.23`
- 范围：`Sources/WeChatHUD/` 全部 187 个 Swift 文件（约 63k 行）+ `Tests/` 129 个文件
- 方法：多子代理对抗式审计（见文末「方法与可信度」），每条结论必须给出 `文件:行号` + 逐字引用，并由独立子代理尝试推翻

---

## 一、总体判断

**工程质量高于同类个人项目，但存在三类系统性风险：**

1. **未校验的 AI/外部数值直接参与整数转换** → 可稳定复现的进程崩溃（唯一被实测复现的崩溃类缺陷）。
2. **微信数据分片模型理解错误** → 同一会话的历史分散在最多 10 个 `message_N.db` 中，读取层却"命中第一个就 break"，导致历史/按日查询**静默返回空**。这是影响面最大的功能性缺陷。
3. **测试全绿但存在大量虚假覆盖** → 1109 条 XCTest 实测 0 失败，然而被 AGENTS.md 宣传的两条安全护栏（金融类强制 pending、媒体 0.7x 衰减）**零行为测试**，另有若干永不失败的断言与恒被跳过的门禁。

客观基线（本轮实测，非文档转述）：

| 项目 | 实测结果 |
|---|---|
| `swift build -c release` | **exit 0，0 warning，0 error**（与 AGENTS.md 宣称一致） |
| `swift test` | **1109 个 XCTest 执行，0 失败，9 跳过**；另 swift-testing **70 个用例通过** |
| 测试文件 | 129 个 `.swift`，其中 124 个含用例（AGENTS.md 称 119） |
| 新增测试函数 | `Tests/` 中 4 个 `disabled_testXxx` **从不被 XCTest 收集** |

共登记约 **118 条原始结论**，经两轮独立复核后：**成立/部分成立 ~105 条**，**被推翻 3 条**，其余为严重度下调。下文按修复优先级给出最终定级（已剔除被推翻项，并标注复核后的修正）。

---

## 二、P0 — 崩溃 / 数据丢失 / 安全（建议立即修复）

### P0-1 未校验的 AI 数值经 `Int(Double)` 转换直接 trap（已实测复现）

`Sources/WeChatHUD/Services/DiscussionTracker.swift:414-424`

```swift
    private static func sourceIndex(_ value: Any?, count: Int) -> Int? {
        let raw: Int?
        switch value {
        case let i as Int: raw = i
        case let d as Double: raw = d.rounded() == d ? Int(d) : nil
        case let s as String: raw = Int(s.trimmingCharacters(in: .whitespaces))
        default: raw = nil
        }
        guard let raw, raw >= 1, raw <= count else { return nil }
        return raw - 1
    }
```

- 触发：可配置的 OpenAI 兼容端点在 `items[].msg` 返回 `1e30` 或 20 位整数。`JSONSerialization` 把它解成 `Double`，`d.rounded() == d` 成立，`Int(d)` 在 `guard` 之前求值 → 边界校验永远来不及生效。
- **实测**：`swiftc` 编译 `let d: Double = 1e30; Int(d)` → `Trace/BPT trap: 5`（exit 133）。Swift 的 `Int(Double)` 越界是 `_precondition`，release 同样触发，不可 catch。
- 后果：扫描线程直接 trap，整个 HUD 进程退出。

**同类缺陷（同一根因，应一并修复）：**

| 位置 | 未校验输入 | 落点 |
|---|---|---|
| `Services/CommitmentDeadlineResolver.swift:272-277` | 模型输出 `+<number><m\|h\|d\|w>`，仅要求 `number > 0`；`Double("1e400") == +inf` | `HUDStore.upsertCommitment` 的 `String(Int(deadline.timeIntervalSince1970))` |
| `Services/AIGroupCatchup.swift:35` → `Services/ClassifierCLI.swift:601` | `noise_ratio` 无区间钳制（同仓 `GroupContextBriefingService.finalize:253` 有 `max(0,min(1,·))`） | `Int(summary.noiseRatio * 100)` |
| `Services/Insight/ChatInsightEngine.swift:372` 附近 | AI `waiting_hours` 未 clamp | `Int(...)` 时间格式化 |

修法：所有来自 AI/网络/外部的数值在转换前统一 `clamp`，并提供 `Int(exactly:)` + 兜底默认值。

---

### P0-2 微信消息分片：`getMessages` 只读第一个命中的库，历史静默丢失（已用真实数据实测）

`Sources/WeChatHUD/Data/WeChatReader.swift:718-723、827`

```swift
            guard let tableName = Self.msgTableName(chatUsername: chatUsername, db: db) else {
                continue
            }
            foundTable = true
            // Remember this mapping for future calls.
            chatDBCache[chatUsername] = relPath
```
```swift
            break  // Msg_<hash> table lives in exactly one DB — no need to check others.
```

注释里的前提**与真实数据不符**。用本机真实解密缓存（`~/.wechat-hud/cache/<hash>/`，10 个 `message_0..9.db`）实测：

```
distinct Msg_ tables: 2572      出现在 >1 个分片: 932
whitelist rows: 115             跨分片会话: 103
shengqiting → Msg_cbcc410a761cca6d20c47521b56ab8a2
  2023-06-15  day range 1686758400 1686844800
  message_0.db → 0 行        message_3.db → 105 行
```

即 `getMessages` 会选中的 `message_0.db` 对该日返回 0 行，数据真实存在于 `message_3.db`。区间连续、互不重叠、索引越大越旧——这是**同一会话按时间分片**，不是 md5 碰撞。

- 影响：历史/按日查询、洞察「回顾日期」、回溯范围查询静默返回空；受影响白名单会话 **103/115**。
- 另注：`messagesInRange`（`ChatMonitor.swift:152-165`）历史区间为空还有独立成因——取最新 1000 条且不带时间过滤。
- 修法：`getMessages` 需跨全部含该 `Msg_` 表的分片做归并，或至少按时间区间选择分片；`chatDBCache` 应缓存「会话 → 分片列表」。

---

### P0-3 增量扫描在积压 >100 条时永久丢弃较早消息

`Sources/WeChatHUD/Services/ScanEngine.swift:725-727`

```swift
    static func whitelistFetchLimit(hasCursor: Bool, unreadCount: Int, defaultLimit: Int = 100, hardCap: Int = 500) -> Int {
        hasCursor ? defaultLimit : firstScanFetchLimit(unreadCount: unreadCount, defaultLimit: defaultLimit, hardCap: hardCap)
    }
```

- 触发：会话已有游标（`hasCursor == true`），HUD 未运行期间累积 N > 100 条新消息（`session.db` 的 `unread_count` 就是 N）。
- `whitelistFetchLimit` 的 `hasCursor` 分支**把 `unreadCount` 完全丢弃**，只取最新 100 条；`currentCursor = messages.first`（newest-first）= 最新一条；随后在事务里**无条件**把游标写成它（`:563` `store.setWhitelistCursor(...)`）。
- 后果：介于旧游标与「最新 100 条」之间的 N-100 条消息永远不会被分类/进收件箱，且无任何提示。
- 关键在于：紧邻的注释（`:718-721`）已明确写出首扫存在同一失效模式——"a hard 100-row page would seed the cursor past older unread and never classify them"——**增量分支漏了同一保护**。
- 修法：`hasCursor` 分支也应以 `unreadCount` 抬升页大小并设上限；或用 `sinceLocalId` 分页直到追上最新。

---

### P0-4 自更新不校验代码签名，身份校验读的是待安装包自带的 Info.plist

`Sources/WeChatHUD/Services/AppUpdateService.swift:203-206、300-316`

```swift
        let incoming = try findApp(in: extract)
        try verifyIncomingApp(incoming, expectedVersion: offer.version)

        try replace(destination: dest, with: incoming)
```

`verifyIncomingApp` 只读取**待安装包自己**的 `Contents/Info.plist` 比对 bundleID 与版本，随后 `replace()` 直接覆盖安装位置的 `.app` 并重启。

全仓签名校验存在性检查：
```
$ rg -n "SecCode|SecStaticCode|SecTrust|teamIdentifier|TeamIdentifier|kSecGuestAttribute" Sources scripts Makefile
（无输出）
```

- 唯一的完整性检查是可选 `.sha256` 侧车文件（`AppUpdateService.swift:189`），但它与资产来自**同一个 release**，对"被篡改的 release"不提供任何保证。
- 下载 URL 强制 https，因此这不是"中间人可随手替换"，而是**缺少签名/TeamID 钉扎**。
- 工程已具备 Developer ID + 公证能力（`Makefile notarize`），但自更新链路未使用。
- 修法：安装前用 `SecStaticCodeCheckValidity` + TeamID 钉扎校验解压出的 `.app`。

---

### P0-5 无显示器/显示器重配置瞬间 `NSScreen.screens[0]` 越界崩溃

`Sources/WeChatHUD/App/FloatingPanel.swift:218-220`

```swift
        let picked = IslandScreenPolicy.pick(preference: displayScreen, screens: mapped.map(\.1))
        return mapped.first(where: { $0.1 == picked })?.0 ?? NSScreen.main ?? NSScreen.screens[0]
    }
```

`screens` 为空（合盖且未接外屏 / 热插拔瞬间）时 `mapped` 为空、`NSScreen.main` 也为 nil → `Index out of range`。入口在启动路径 `AppDelegate.swift:98 → positionAtTop()`。修法：改用 `NSScreen.screens.first` 并给出无屏兜底。

---

### P0-6 微信 AX 属性用 `as!` 强转（外部进程数据决定类型）

`Sources/WeChatHUD/Services/WeChatLauncher.swift:223`（同型 `:475`、`:476` 可达，`:359` 为死代码）

```swift
            guard let sizeRaw = axGet(el, kAXSizeAttribute) else { return false }
            var size = CGSize.zero
            guard AXValueGetValue(sizeRaw as! AXValue, .cgSize, &size),
                  size.width > 10, size.height > 10 else { return false }
```

`axGet` 只判 `err == .success`，**不判类型**；同文件对同类外部数据用的是安全写法（`:239` `as? String`、`:244` `as? [AXUIElement]`）。全仓 `as!` 仅这 4 处。这些函数在 UI 自动化开聊/发送主路径上。修法：`as? AXValue` 并 guard。

---

### P0-7 微信 AX 树快照（联系人名/会话标题/控件文本）写入全局可读的 `/tmp` 日志

`Sources/WeChatHUD/Services/WeChatLauncher.swift:101、106-111、281、442、456-457`

```swift
    private static let logPath = "/tmp/wchud_launcher.log"
```

- **实测**：该文件在作者机器上真实存在（104 行，`-rw-r--r--`），内容含真实群名与联系人名；无权限收紧（全仓 5 处 `logPath` 引用，无 `posixPermissions`）、无清理、无开关。
- `/tmp` 的 sticky 位只防删除不防读取，同机任意用户可读。
- 对比：仓库其他落盘点都显式收紧（`HUDStore.swift:22` 目录 `0o700`、`WeChatDecryptor.swift:149/215` `0o600`、`AccountKeyStore` `0o600`）。
- 同族问题：`Services/ClassifierCLI.swift:219` 把**完整私聊正文与发件人名**写成 `/tmp` 下默认权限的 JSON（`:240` 的守卫只挡仓库内路径）；`AutopilotService.swift:1352` 把联系人显示名与草稿全文 `print` 到 stdout。
- 修法：改为 `os.Logger` + `privacy: .private`，或写入 `~/.wechat-hud/logs/` 并设 `0o600`；`/tmp` 路径改为 `FileManager.default.temporaryDirectory` 且设权限。

---

### P0-8 手动发送把 HUD 别名同时当微信搜索词与标题校验词

`Sources/WeChatHUD/Views/ConversationDetailView.swift:307-308` → `WeChatLauncher.swift:665、832-840`

本行未传 `searchNames:`，后端退化为 `WeChatOpenSearch.names(stored: [chatName], username: chatName)`；该数组同时是**搜索输入**与**当前会话标题校验词**，而 `chatName` 来自 `monitor.displayName(for:)`（第一优先级是 HUD 本地别名，`renameChat` 只改自有 sqlite，不改微信）。

- 微信里存在同名会话 → 搜索唯一命中它、标题校验通过 → **回复发给错误的人**，且确认框显示的也是同一别名，用户难以察觉。
- 不存在同名会话 → 发送以 `.chatMismatch` 失败（功能不可用，但不致错发）。
- 对照：`AutopilotService:885` 与 `openWeChatChat` 都传了按 username 解析的 `searchNames`，**全仓仅此手动路径漏传**。
- 修法：调用点补传 `searchNames: reader.searchNames(for: chatUsername)`。

---

### P0-9 回溯（Retrospective）脱敏与失败固化

- `Services/Retrospective/RetrospectiveAnalyzer`（逐条「先注册后脱敏」）→ **文本中提到但尚未发言的人名以明文出网**（high）。
- `Services/Retrospective/GroupScreener.swift:5x` → 瞬时 AI 失败被固化成永久 `ask_each_time` 策略，群被静默排除且无法恢复（high）。
- `Services/Retrospective/SummarySynthesizer` → 把未脱敏的 highlights/todos（真实姓名、群名）发给 AI，而台账记 `redacted: true`（medium，**审计数值造假**）。
- `Services/Retrospective/GroupScreener.swift:1xx` → 按 `chat_name` 字符串回填，同名群共用第一条决策并永久落库（medium）。

---

### P0-10 设置页切换供应商即清空已存 API Key（已实测确认）

`Sources/WeChatHUD/Views/Settings/AISettingsView.swift:878-883`，调用点 `:611`

```swift
    private func applyPresetProvider(_ id: String) {
        providerID = id
        guard let preset = AIProvider.find(id), preset.id != "custom" else { return }
        baseURL = preset.baseURL
        apiKey = ""
```

`onChange(of: serviceSource)`（`:604-617`）在切回 `.preset` 时，因 `providerID == "custom"` 而调用 `applyPresetProvider(lastPresetProviderID)` → `apiKey = ""` → `debouncedSave()` 落盘。**两次普通点击**（预设 → 自定义 → 预设）即物理丢失凭据，AI 全部停摆直至重新粘贴。同类函数 `syncProviderPreset:319-330` 有 `baseURL != preset.baseURL` 守卫，此处没有。修法：仅在供应商确实变更时清空，且清空前提示。

---

## 三、P1 — 功能静默失效 / 性能

| # | 位置 | 问题 |
|---|---|---|
| P1-1 | `Services/ConversationMemoryUpdater.swift:29-32` | `for entry in whitelist.prefix(maxChats)` **先截断后判陈旧**（陈旧判断在 `updateMemoryIfNeeded:43-46` 内部）。白名单第 6 条起**永远**不生成对话记忆 → autopilot 主动消息（`AutopilotService:1286` 的 `guard let memory ... else { continue }`）、按需分析、洞察的记忆上下文永久为空。方法注释自称"按陈旧度挑选"，实现与注释矛盾。 |
| P1-2 | `Services/Insight/InsightStore.swift:75`（`@MainActor`） | `reload` 同步调用 `InsightDataLoader.load` → `bulkMessageStats` 遍历全部 `message_*.db` 的每个 `Msg_` 表逐行累加。**实测**：4648 个表/分片对、287,565 行、10 个分片合计约 550 MB；窗口选「全部」时 `cutoff = 0` 无时间过滤。任何 `await` 都不让出主线程 → 打开洞察页/切换窗口即冻结。且 `onChange(of: monitor.stats.lastSyncAt)` 每次扫描完成都会重跑。 |
| P1-3 | `Views/Analytics/InsightSidebarView.swift:307` | 视图 `body` 内逐会话调用 `statsForDay` → `getMessages(limit: Int.max)`，在 `filter` 之前求值，即使筛选「全部」也照样读库。`scope == .all` 时是**数百上千次"整天消息全量解码"**，全在 SwiftUI body 求值的主线程上。 |
| P1-4 | `Views/ConversationDetailView.swift:33-36` + `465-466`、`514-524` | 「AI 建议」区块与生成按钮**互斥自锁**：区块仅在 `suggestions` 非空或 `isLoadingSuggestions` 为真时渲染，而按钮要求两者皆假；`loadSuggestions` 只被该按钮调用 → 整块 UI、`SuggestionRowView`、采纳反馈 `recordReplyFeedback` 全为死代码。 |
| P1-5 | `Services/AIService.swift`（`AIRateLimiter`） | 并发场景下限流**完全失效**（检查与置位之间存在竞态），全局 AI 限流形同虚设。 |
| P1-6 | `Services/AIAnalysisPipeline.swift` | 所有 AI 错误被压成 `nil`，审计只留一句 "AI call failed"；配合宽松解码（任意 JSON 对象都算解析成功），**空分析被当成功缓存 72 小时**，严格重试永不触发。 |
| P1-7 | `Services/AIJSONExtractor.swift` | `stripMarkdownFence` 会删掉围栏之外的**全部正文**；响应体无长度上限 + 不配对括号退化为 O(n²)。 |
| P1-8 | `Services/Codex/CodexTokenStore.swift:88-91` | `loadOrRefresh(forceReread: true)` 无条件用 `auth.json` 里的旧 refresh token 覆盖内存中**服务端刚轮换过的**新 token；而本进程从不回写 `auth.json`。冷启动与 401 恢复路径都会用「已被自己轮换作废」的 token 去刷新，并可能把内存中唯一有效的那份覆盖掉。 |
| P1-9 | `Services/ProactiveAlertEngine.swift:166-170` | 过期承诺提醒**每小时无限重复**，耗尽 5 条/小时全局配额 → 关键告警被静默丢弃。 |
| P1-10 | `Data/DailyReport.swift:190` | 风险/高亮 id 由 `String.hashValue` 派生（**实测**跨进程不稳定）。用户「忽略风险」每次重启失效，并在 `daily_report_state` 累积永不匹配的孤儿行。 |
| P1-11 | `Data/Models.swift:1932` | `AutopilotConfig` 仅靠合成 Codable：持久化 JSON **缺任一键即整体解码失败**，`getSettingJSON` 的 `try?` 吞掉后取全默认 → 护栏配置静默回默认，并被后续保存永久覆盖。T7 用本机真实 DB 行实测复现（仅 17 键、缺 `autoSendEnabled` → `keyNotFound`）。 |
| P1-12 | `Views/Settings/AISettingsView.swift:827` | 连接测试失败原因被**二次关键字映射**：`connectionFailure` 固定返回含 "API Key" 的串，于是模型名错误(400/404)、额度用尽(429)、5xx 全被显示成「请补充访问凭据」，与刚通过的密钥校验自相矛盾。 |
| P1-13 | `Services/DiscussionCorrection.swift:58-62` | `hint` 用 `.suffix(limit)` 取到的是**最旧** `limit` 条纠错，而非最近 limit 条。 |

---

## 四、测试质量：全绿 ≠ 有效覆盖

基线：**1109 XCTest（0 失败 / 9 跳过）+ 70 swift-testing 全通过**。但审计发现下列**虚假覆盖**：

### 4.1 安全护栏零行为测试（最高风险）

`Services/AutopilotService.swift` 中被 AGENTS.md 宣传的两条护栏：

```
$ grep -rn "forcePending" Sources Tests --include=*.swift
Sources/WeChatHUD/Services/AutopilotService.swift:355:   if mediaType.forcePending {
Sources/WeChatHUD/Services/AutopilotService.swift:1591:  var forcePending: Bool {
$ grep -rn "effectiveConfidence\|hasMedia" Sources Tests --include=*.swift
Sources/WeChatHUD/Services/AutopilotService.swift:557, 648, 713      ← Tests 中 0 命中
```

- **金融类强制 pending**（转账/红包/小程序）：`Tests/` 零引用。且默认敏感词表不含「红包」「小程序」，即**没有第二道兜底**。该分支只在 `handleNewMessages` 的 Phase 1 消费，而全测试目录从未调用过 `handleNewMessages`。
- **媒体置信度 0.7x 衰减**：`Tests/` 零引用。所有降级测试的 `confidence` 与 `originalConfidence` 入参**恒等**（`AutopilotSafetyTests.swift:266-267、313`），因此删掉 `* 0.7`、改成 `0.9`、或把两个参数写反，43 条测试全部保持绿色。

### 4.2 恒真 / 空转断言

| 位置 | 问题 |
|---|---|
| `AutopilotSafetyTests.swift:85-102` | 3 条会话上限"测试"把生产表达式 `maxSendsPerSession > 0 && sessionSent >= maxSendsPerSession` 抄进断言。`maxSendsPerSession = 0` 时 `0 > 0` 恒假；另两条是字面量算术恒真/恒假。删掉生产的 cap 分支仍全绿。 |
| `AutopilotSafetyTests.swift:53-81` | 4 条敏感词"检测"测试**自写了一遍匹配循环**，且语义与生产不同（生产大小写不敏感并扫入站文本）；`testSensitiveKeywordEmptyList` 是永真断言。 |
| `AutopilotSafetyTests.swift:17` | `XCTAssertFalse(config.enabled)` 被当作"默认关闭"证据，但 `AutopilotConfig.enabled` 在 `Sources/` 中**没有任何读取点**（`grep '\.enabled' Sources` 仅命中一个无关枚举 case）——是死字段。真正生效的是 `autoSendEnabled`。 |
| `NewSchemaTests.swift:483` | `testWhitelistMigrationToContacts` **不可能失败**：`addToWhitelist` 已用与迁移逐字相同的规则建好 contacts 行，迁移内部的 `getContact(...) == nil` 守卫对全部记录为假，迁移是纯空转。升级用户「老库有 whitelist 无 contacts」的前置状态从未被构造。 |
| `ChatNamingTests.swift:303` | 群成员名恢复的断言落在**测试自写的 join SQL 副本**上；构造的 `reader` 是死对象（`_ = reader`）。生产 `loadGroupMemberNames` 从未被执行。 |
| `ChatNamingTests.swift:214` | `repairStaleChatNames` / `repairStaleCommitTargets`（写 15 张表的用户数据）无任何测试调用，只验证测试自写的副本循环。 |
| `InsightRadarTests` | 两条断言按构造永不失败（`FindingKind` 死枚举）。 |
| `ScanClassificationDeliveryTests.swift:248` | 灰名单护栏测试用 `?? 0`，使 `performScan` 返回 `nil`（扫描失败）也被算作通过。 |

### 4.3 恒被跳过的门禁

- `AIClassifierTests.testClassifierAgainstFixturesLive:164` — 分类器**唯一的端到端 F1 ≥ 0.85 门禁**，用 `AIConfig()` **默认值**而非用户配置探测可用性。本机实测跳过原因是「不支持的URL」，即默认端点在任何未跑该默认 omlx 服务的机器上恒不可用 → 门禁实际不生效。
- `AIServicesTests.swift:66/92/116/141` — 4 个 `disabled_testXxxLive` 因命名前缀**从不被 XCTest 收集**（既不通过也不跳过），其中 2 个服务因此零本地覆盖。
- `ChatNamingMonitorLiveTests` / `ChatNamingHintTests` 等：`renameChat` / `clearChatAlias` / `hasOnlyFallbackName` 的**唯一**验证被「无本机微信库即跳过」门控挡住，CI 上永不执行。
- 实测跳过的 9 个用例中，`testClassifierAgainstFixturesLive` **不是设计使然**，而是配置读错导致的恒跳过。

---

## 五、文档与代码不一致

| 文档断言 | 实测 | 结论 |
|---|---|---|
| AGENTS.md:9 「981 个 XCTest + 70 swift-testing、119 个测试文件」 | **1109 + 70**、129 文件（124 含用例） | 偏差 |
| AGENTS.md:89 「350 个测试覆盖」、AGENTS.md:83 「(194 个)」 | 同文档内三个数字互斥 | 自相矛盾 |
| AGENTS.md:12 「ChatMonitor 2608 行 / HUDStore 2945 / Models 1744；拆出 703 行」 | **2957 / 3627 / 1991**；拆分三文件实为 903 行 | 低估 13%–23% |
| AGENTS.md:41 「ReplyDebtJudge.swift — AI 二次判断 + shadow mode」 | 文件与测试**均已删除**（`git log --diff-filter=D` 可查），全仓无该符号；仅残留死配置键 `debtJudgeEnabled` / `debtJudgeShadowMode` | 架构图失效 |
| AGENTS.md:83 「make test（过滤输出只显示结果）」 | `Makefile:83-84` 是裸 `swift test` | 未实现 |
| README.md:96 「群聊不自动发」 | `Models.swift:1946-1947` `shouldQueue = !isGroup \|\| (handleGroupAt && isAtMention)`；`AutopilotService:812-817` 的 `manualOnlyReason` **无 isGroup 项**，`:1477` 据此自动发送 | **承诺的护栏在实现中不存在** |
| CONTEXT.md:8 「启动后全自动发送，无需人工确认」 vs AGENTS.md:14「文档与代码已对齐」 | 代码为默认关闭 + 敏感词/金融类强制人工确认 | 领域文档与实现相反，且被误标为"已对齐" |
| AGENTS.md:10 「9 个用例按设计跳过」 | 9 个确实跳过，但其中 1 个是配置错误导致的恒跳过；另有 4 个从不被收集 | 部分成立 |

---

## 六、被对抗复核推翻 / 降级的结论

对抗流程的价值在此——下列结论**不成立或需大幅降级**，已从上面的清单剔除：

| 原结论 | 复核结果 |
|---|---|
| 「Autopilot 50 条/会话上限、金融类强制 pending、敏感词拦截只存在于策略层或测试中」 | **killed**。六项护栏全部在 `ChatMonitor` 扫描 → `handleNewMessages` / `processPendingQueue` → `executeSend` 的真实链路上强制执行。 |
| 「`AutopilotConfig` 解码失败回默认 → 可能意外开启自动发送」 | **不成立**。默认全关（fail-closed）。 |
| 「`sqlite3_last_insert_rowid` 在互斥区外读取导致会话归属写错」 | 机制为真但窗口仅纳秒级、后果多为一次性误判 → **medium → low**。 |
| 「陈旧 offer 可降级覆盖已升级的应用」 | 需「关闭自动检查 + 绕过 app 手工升级 + 不先点检查更新」三条件，损失仅本机较新副本 → **medium → low**。 |
| 「GitHub Token 保存失败无反馈」「添加关注弹窗吞错误」「连接测试文案误导」 | 机制均确认，但后果只是提示层面且有缓解 → **medium → low**。 |
| 「风险 id 用 hashValue 导致忽略失效」 | 确认，但无数据/资金/隐私损失 → **high → medium**。 |
| 「『明晚/今晚』导致承诺截止时间错算」 | 「今晚 X 点」落回当天**恰好正确**，系统性错的只是「明晚/明早」→ **high → medium**。 |
| 「StyleProfiler 把 autopilot 消息当我的回复 → 深夜静默护栏失效」 | 「从阈值以下顶上去」不成立（闸门在阈值以下直接 skip）；真实影响是指标不再随用户行为衰减 → 维持 medium。 |

---

## 七、建议修复顺序

1. **P0-1 数值转换崩溃**（一个统一的 `safeInt(_:)` 工具函数可一次覆盖 4 处）——收益最高、成本最低。
2. **P0-2 分片读取**——影响 103/115 白名单会话的历史查询，是最大的功能性缺陷。
3. **P0-3 增量游标截断**——静默丢消息，修复面小。
4. **P0-7 / P0-4 隐私与供应链**——`/tmp` 日志与自更新签名校验。
5. **P0-8 手动发送目标解析**——存在错发风险。
6. **P0-5 / P0-6 崩溃兜底**。
7. **P1-1 / P1-2 / P1-4** 三个"整块功能静默失效/冻结"。
8. **补安全护栏的行为测试**（金融类强制 pending、媒体 0.7x 衰减、会话上限、`handleNewMessages` 管线），并修掉 4.2 中的恒真断言。
9. **更新 AGENTS.md / README / CONTEXT.md**，特别是「群聊不自动发」与「文档与代码已对齐」两处**会误导后续代理**的断言。

---

## 八、方法与可信度

- **流程**：21 个源码域 + 7 个横切任务 = **28 个子代理**，四轮执行：
  - Wave A/B/C：21 个域，每域「审计员 → 独立复核员」两段流水线（42 个子代理调用）；
  - Wave D：测试质量（3）、文档断言（1）、安全清扫（1）、健壮性清扫（1）、顶结论硬复核（1）。
- **约束**：所有审计员**只读**，禁止 `swift build/test/make`（构建由独立后台任务并行执行）；每条结论必须附 `文件:行号` + 逐字 `code_quote`，复核者逐字比对，引用不实即判 `refuted`。
- **对抗性**：复核者默认立场是「每条结论都是错的」，且被要求区分 `confirmed` / `partially_confirmed` / `refuted` / `unverifiable`，并按"触发是否需要非常规操作、后果是否仅为显示不准"校准严重度。第二轮硬复核（T7）对 10 条最高危结论做了真实数据复现，产出 6 stands / 3 weakened / 1 killed。
- **本报告作者独立复核**：对 12 条关键结论亲自复跑了 `grep`/`sed` 与编译探针，包括 `Int(1e30)` 的 SIGTRAP 实测、`ConversationMemoryUpdater.prefix` 截断顺序、`AISettingsView` 的 `apiKey = ""`、`forcePending`/`hasMedia` 的测试零命中、`allContacts()` 无锁读取、`ScanEngine` 游标无条件推进、测试计数（1109/70/129/124）、`NSScreen.screens[0]`。
- **已知限制**：
  1. 未运行 App，所有 SwiftUI 渲染期表现（重复 id、命中区落穿、body 卡顿秒数）为静态推断链；
  2. 崩溃类缺陷的**触发依赖 AI/外部端点返回异常数值**，本报告实测的是 Swift 语义（`Int(Double)` 必 trap），非端到端崩溃复现；
  3. 真实微信图片目录受 macOS TCC 限制无法读取，`ImageResolver` 的文件名约定未能核实；
  4. live AI 端点未调用，"模型是否会照注入行事"仍属推断；
  5. 原始逐域报告（含已排除项与复现命令）存于 `/tmp/wechathud-qa/{audit,refute}/`，非仓库产物。

- **仓库状态**：全程未修改任何被测源码，`git status --porcelain` 为空。

---

## 九、执行记录（2026-09-12，修复轮）

本节由执行方追加：报告中的 P0/P1、测试质量与文档三类条目**已全部落地**，并补了防回归测试。逐条对应如下（文件:行号为修复后的位置）。

### P0

| 项 | 修复 | 防回归测试 |
|---|---|---|
| P0-1 未校验数值 | 新增 `Services/SafeNumber.swift`（clamped / clampedInt / exactInt / jsonInt，NaN 取下界、±∞ 饱和、`Int.max` 边界在 Double 里比较）；`DiscussionTracker.sourceIndex`、`CommitmentDeadlineResolver.relativeDeadline`（含 `isFinite` + 400 天上限）、`AIGroupCatchup.noiseRatio` 自定义解码钳制、`InsightRadar/InsightAttentionBar/InsightOverviewDashboard` 的 `waiting_hours` 全部走它 | SafeNumberTests（含 `1e30`/`±∞`/`NaN`/边界）、RetrospectivePrivacyTests 等间接覆盖 |
| P0-2 分片读取 | `WeChatReader` 把 `chatDBCache`（单库）换成 `chatShardCache`（会话→全部含该 `Msg_` 表的分片）；`getMessages` 探查全部 message DB、跨分片归并排序后按 limit 截断；空数组为负缓存；键文件重载/新分片出现时整体失效 | WeChatShardMergeTests（跨分片归并、limit 语义、按日查询命中非默认分片、beforeCursor 跨分片、负缓存） |
| P0-3 游标截断 | `whitelistFetchLimit` 两个分支都覆盖 session.db 的 unread 数（上限 500）；超出上限时按 `beforeCursor` 向后翻页，扫描级共享预算 `backlogPageBudgetPerScan = 6` | ScanBacklogPagingTests（501 条待整理消息被完整覆盖：分类/讨论队列各 501、水位线到最新；小积压不受影响）、ScanEngineTests 更新 |
| P0-4 自更新签名 | 新增 `AppUpdateSignature`：`SecStaticCodeCheckValidity`（all-architectures + strict）+ TeamID 读取；安装前校验"归档有效签名且与本进程 TeamID 一致"，本进程无身份时拒绝（fail-closed）；`.sha256` 仍保留但不作为唯一依据 | AppUpdateSignatureTests（未签名/adhoc 无 TeamID/签名后篡改/不同 Team/本进程无身份），install 测试断言解压出的包确实被校验 |
| P0-5 无显示器崩溃 | `FloatingPanel.targetScreen` 改为可选，`screens` 为空时用当前 frame 兜底，不再 `screens[0]` | 编译期 + 该路径现在无 trap 点 |
| P0-6 AX 强转 | 新增 `axValue(_:)`（先查 `AXValueGetTypeID` 再 `unsafeBitCast`），launcher 里 4 处 `as!` 全部替换；`as!` 在 `Sources/` 归零 | 编译期；行为依赖真实微信 AX 树 |
| P0-7 /tmp 隐私 | `WeChatLauncher` 日志改到 `~/.wechat-hud/logs/launcher.log`（目录 0700、文件 0600）；`ClassifierCLI --out` 默认写 `FileManager.temporaryDirectory` 且落盘后设 0600；`AutopilotService` 不再打印联系人显示名+草稿全文 | 编译期；`/tmp/wchud_launcher.log` 是历史遗留文件，需手工删除（见"剩余边界"） |
| P0-8 手动发送目标 | `ConversationDetailView` 发送时传 `monitor.weChatSendSearchNames(for:)`（只含微信自己认识的备注/昵称/username）；新增 `ChatMonitor.weChatSendSearchNames`；`AutopilotService.searchNames` 同步去掉 HUD alias 与调用方 fallback（alias 只存在于 HUD 库，拿去搜索会命中同名陌生人且骗过标题校验） | ChatNamingTests 现有断言 + 方法拆分可测 |
| P0-9 回溯脱敏 | ① `RetrospectiveAnalyzer` 先给本窗口**所有发言人**注册代号再逐行脱敏（原先"先注册后脱敏"导致先被提及的人名明文出网）；② `GroupScreener` AI 失败/无法解析时不再落库策略（返回 nil→本次只问用户不缓存）；③ `SummarySynthesizer` 真正对 highlights/todos 里的姓名、群名做代号替换后再发（此前台账写 redacted=true 但发的是明文），返回后再还原；④ 群筛选按稳定的 `chat_username` 匹配（prompt 同步更新，旧回复按 chat_name 回退且每条只用一次） | RetrospectivePrivacyTests（7 条：发言前被提及、失败不缓存且可恢复、同名群不串、旧格式回退、无法解析→无决策、摘要脱敏、代号还原） |
| P0-10 切换供应商清空 Key | `applyPresetProvider` 只在 baseURL 真正变化时清空 apiKey（与 `syncProviderPreset` 的既有守卫一致） | 编译期 + 现有 SettingsReliabilityTests |

### P1

全部 13 条已修：P1-1 记忆更新改为"先按陈旧度挑再截断"（`staleChats` 纯函数，ConversationMemoryUpdaterTests）；P1-2 洞察加载移到后台执行器（`loadInBackground`/`computeDayStats`）；P1-3 侧栏按 (日期, 会话集) 预计算 day stats，body 不再读库；P1-4 建议区块在有 reply-debt 上下文时也渲染（按钮可达）；P1-5 `AIRateLimiter` 检查与置位合并为一次同步 `reserve()`，等待在 actor 外（AIRateLimiterTests，16 并发 ≥2s ≈ 4/s）；P1-6 管道新增 `isUsable`（空分析不算成功）+ 失败详情写进审计（AIAnalysisPipelineTests，注入协议后首次可测）；P1-7 `AIJSONExtractor` 保留围栏内外两种候选、限长 200k、扫描预算 2M（AIJSONExtractorTests 4 条）；P1-8 `CodexTokenStore` 记住"本进程轮换过的 token"并优先使用，文件 token 作为回退（CodexTokenStoreTests 2 条）；P1-9 过期承诺提醒 24h 冷却（ProactiveAlertTests）；P1-10 报告 id 改 SHA-256（DailyReportIdentityTests）；P1-11 `AutopilotConfig` 宽容解码 + 比例钳制（AutopilotSafetyTests）；P1-12 连接失败按 HTTP 状态给建议、不回显响应体（AISettingsValidationTests）；P1-13 `hint` 用 `prefix` 取最近 limit 条（DiscussionCorrectionTests）。

### 测试质量

- **安全护栏行为测试**：新增 `AutopilotGuardrailPipelineTests`（真实 `handleNewMessages`：转账/红包/小程序强制 pending 且不进队列、表情跳过、群聊仅记录、文本只进批处理）；`AutopilotSafetyTests` 里 4 条"自写匹配循环"、3 条会话上限、以及媒体衰减断言全部改为直接驱动生产函数，并新增"媒体 0.7x 跨过阈值"用例（删掉衰减/写反参数都会失败）。
- **群聊护栏**：`automaticSendHoldReason` 增加 `isGroup`，群聊消息（含 @ 提醒）一律人工确认——README 的承诺现在由发送闸门真正执行，而不只是入队闸门。
- **死代码/恒真断言**：删除 `AutopilotConfig.enabled`（无读取点）、`InsightRadar.isMeaningfulAttitude/isHardNegative`（无调用点）；`InsightRadarTests` 两条恒真断言换成"计数器不产生卡片 / 具名联系人才产生卡片 + 只允许 action/waiting/relationship 三种 kind"的契约断言；`ScanClassificationDeliveryTests` 的 `?? 0` 改成 `XCTUnwrap`。
- **照抄生产的测试副本**：`ChatNamingTests` 的迁移/修复循环改为调用生产静态方法（`ChatMonitor.repairStaleChatNames(store:resolve:)` 等新拆出），成员名恢复改走真实 `WeChatReader.loadGroupMemberNames`（该函数由 private 改 internal 以便注入 fixture DB）；`NewSchemaTests` 迁移测试改为用原始 SQL 构造真实"有 whitelist、无 contacts"前置（原版用 `addToWhitelist` 造前置，迁移是纯空转）。
- **从不收集/恒跳过的门禁**：4 个 `disabled_testXxxLive` 改名回 `testXxxLive` 并统一 `WCHUD_LIVE_COMPANION_AI=1` opt-in；`testClassifierAgainstFixturesLive` 从 `AIConfig()` 空默认值改为读设备已保存配置，未 opt-in 时显式 skip。本轮 `swift test`：**1174 条 XCTest 执行 / 9 跳过 / 0 失败 + 70 条 swift-testing 通过**，9 条跳过全部是显式门禁。

### 文档

- `AGENTS.md`：测试与行数改为实测值并注明"以 swift test 输出为准"；删掉已不存在的 `ReplyDebtJudge.swift`；`make test` 描述改为真实的裸 `swift test`；Autopilot 段去掉 `enabled`、补上群聊人工确认与行为测试位置；新增质检条目。
- `README.md`：自动托管条目明确"群聊不自动发（@ 提醒也只出草稿）"——该承诺现在由代码强制。
- `CONTEXT.md`：自动托管条目从"启动后全自动发送、无需人工确认"改为与代码一致的"默认关闭 + 多层护栏"，并说明群聊/金融类/低置信度的处理。

### 剩余边界（本次未做）

1. `/tmp/wchud_launcher.log`（历史文件，含真实群名/联系人名，权限 0644）在新代码下不再写入，但文件仍在磁盘上，需要手工删除：`rm /tmp/wchud_launcher.log`。
2. `RetrospectiveConfig.redactorEnabled` 仍是未被读取的配置键：脱敏现在无条件开启（fail-safe），若要支持关闭需要显式实现。
3. 分片归并的策略是"缓存会话→分片列表，键文件重载时重新探查"；若某天微信把表**复制**进新分片而不改键文件，旧分片列表不会自动发现（当前观测到的分片是写入时分片、不搬迁）。
4. `ChatMonitor.messagesInRange` 仍取"最新 1000 条再按时间过滤"，超长历史区间需要后续改成 SQL 时间谓词分页。
5. 本轮未启动 App：SwiftUI 渲染期表现（洞察侧栏预计算的实际体感、无显示器兜底路径）只有编译与单元测试证据。
