# 第 31 轮：发送链路的最后一米，和「撤回」到底撤回了什么

承接 `2026-09-18-island-motion-and-copy-pass.md`（§116–§129）。本轮四路子代理并行
（攻本分支上一条 commit、微信 AX 发送最后一公里、外部字符串进 SQL、常驻资源增长），
外加一条重派。落地两条 P0 + 一条我自己上一条造出来的 P1。

## §130 撤回之后仍然演发送（P0，commit 517621ed）

**症状**：自动驾驶正在把一条回复敲进微信（导航 → Cmd+A → 粘贴 → Return），
用户在这 1.5–8 秒里点了「停止」「暂停」或对这一条点「取消本条」。
HUD 显示 OFF / 回执写着「已取消本条，对应的待发草稿已一并移除」，
两秒后消息照样发到对方那里。

**为什么成立**（逐条回源码，不看代理结论）：
- `WeChatLauncher.performTextAction` 是全世界唯一碰微信键盘的函数。它只观察四件事：
  预览模式、`textActionInFlight` 互斥、账号证据、前台 + 会话标题。
  它从不问 `AutopilotService.isPaused`、`sessionId`、也不看这一条是否已被撤回。
- `AutopilotService` 是 actor，`executeSend`/`approvePending` 在
  `await WeChatLauncher.sendMessageDetailed`（:1087）处挂起 ⇒ actor 重入，
  `stop()`（:235）/`manualPause()`/`rejectPending` 完全可以在发送中途执行完。
  所有 `guard !isPaused, sessionId != nil` 都在**进入发送之前**，没有一处在这之后。
- `Task.isCancelled` 走不通：没有任何调用方留着这个 Task 的句柄（根是 ChatMonitor
  的 Timer Task），取消在结构上不可能。
- `ApprovalWorkspaceView` 的「确认发送」`.disabled(… || isSending)`，
  「取消本条」没有 —— 而 `approvePending` 要到发送**成功之后**才把行从 pending 翻走
  （`resolveAutopilotLogSent`），所以正在发送的那一行在界面上仍然是 pending，
  取消按钮此刻可点。
- 更糟：`cancelPendingSend(id:)` 第一行是
  `guard let item = pendingSendQueue.first(where: { $0.id == id }) else { return }`，
  而 `sendNow`/`processPendingQueue` 在发送前已经把这条从数组里取走了 ⇒
  对正在发送的行，这次取消**除了打印一句成功之外什么都没做**。

**改法**：给启动器一个「还要不要发」的回调，在粘贴前和按 Return 前各重读一次；
许可只看用户自己的撤回信号，不看第二套状态：

```swift
nonisolated static func mayStillDeliver(paused: Bool, sessionOpen: Bool,
                                        queueRowLive: Bool?, approvalRowPending: Bool?) -> Bool
```

- 队列路径：`store.hasPendingSend(id:)` —— 取消会删这行，停止会清整个会话；
  为此 `executeSend` 在发送前补一次 `upsertPendingSend`，保证「在飞的队列发送一定有 DB 行」
  （入队时若 sessionId 还是 nil 就没有行，不补会把这条永久读成已取消）。
- 审批路径：`store.autopilotLogPendingReply(id:) != nil` —— 取消本条把它翻成 skipped。

**中途撤掉的两个设计**（记下来免得再走一遍）：
先做了 `withdrawnSends: Set<UUID>` 内存标记，判据是 `isSending && 不在数组里`。
它有两个毛病：标记的清理时机靠「一次只有一条在飞」这个前提，且测试要驱动它必须
碰私有状态。DB 行本身就是用户撤回的持久记录，删掉标记之后代码更少、且能用真库测。

**验证**（`AutopilotInFlightWithdrawalTests`，4 条 + 3 个反向变异）：
- 真 store + 真 actor：行在 ⇒ 放行；`manualPause` ⇒ 关；删行 ⇒ 关；`stop` ⇒ 关。
- 取消一条「内存里已经没有、DB 里还在」的行 ⇒ 行被删、闸门关闭。
  变异 M1（把 `cancelPendingSend` 换回 `guard let … else { return }`）⇒
  2 条断言失败，其中一条正是「a canceled row must not press keys」。
- 变异 M2（删掉 Return 前那次检查）⇒ 形状判据失败（2 个检查点变 1 个）。
- 变异 M3（`mayStillDeliver` 恒 true）⇒ 7 条断言失败。

**没修的部分（定价）**：闸门只能在按 Return **之前**拦住。若撤回落在最后一次检查
和按键之间，消息仍会出去；此时 `resolveAutopilotLogSent` 的 `consumed == false`
已经知道发生了竞争，但界面上还没有把「已送达（撤回前已发出）」这句话讲出来。
下一轮的正确做法是把 `consumed` 传到人眼前，而不是再加一层检查。

## §131 `swift test` 会走真的微信自动化，此前只有一个崩溃在挡着（P0 测试基建，commit 517621ed）

新写的 `testingExecuteSend` 用例让测试真的进了 `performTextAction`：
这台机器上微信是开着的，`runningWeChat()` 返回了非 nil，然后
`WeChatLauncher.swift:767` 在 `NSApp.delegate` 上崩了 —— `NSApp` 是隐式解包全局量，
测试进程里没有 NSApplication。

也就是说：**过去唯一阻止 `swift test` 去操作用户真实微信的东西，是一个偶发崩溃。**
一旦哪天测试进程里有了 NSApp（比如某个用例先碰了 AppKit），
测试就会去搜索会话、粘贴文本、按 Return。

改成显式拒绝：账号证据读不到就是 `SendFailureReason.automationHostMissing`
（「浮窗主程序没有运行，已停止自动操作，微信不会收到任何内容。」），
不再依赖崩溃。测试日志里现在能看到这句话，说明路径确实被挡住了。

**残留**：这道墙是「拿不到 AppDelegate/reader」，不是「进程身份校验」。
一个构造了 AppDelegate + 真 reader 的测试仍然可以驱动真微信。
真要封死需要 bundle 身份判断，但 `swift run` 的开发态没有 bundle id，
会把开发者自己的发送也挡掉 —— 所以留给人做。

## §132 「依据」行把「意义」又念了一遍（P1，上一条 commit 造成，commit f425dbdf）

§128 把 `waiting_hours` 从解码里摘掉是对的，但没检查摘掉之后四个消费方的
`> 0` 分枝变成死分枝会退化成什么。「攻自己 diff」的那路子代理报回 BROKEN：

1. `InsightRadar.chatFindings` 的 evidence 退到 `item.source`，而同一行的
   `source` 是 `chatName` —— 私聊里两者就是同一个人名，
   卡片读作「张三 ／ 依据：张三」。
2. evidence 为 nil 的行改用回落文案
   `按多条消息或近期互动推断：<reason>`，展开后下一行「意义」又是同一个 `reason`
   ⇒ 同一句话在同一张卡上出现两次，而唯一能说「这条凭的是什么」的位置被占掉了。

改法：回落文案不再引用 `reason`（各 kind 本来就有自己的诚实说法：
「来自…统计，不是单句原话」）；`radarInterpretationOnlyText` 从 private 实例方法
改成 internal static 纯函数，这样能被断言。
evidence 在 `item.source == chatName` 时给 nil（宁可不显示，不重复显示）。

变异 M4（把 reason 回显加回去）+ M5（evidence 退回 `item.source`）⇒ 2 条新用例失败。

## §133 把 `waitingHours` 字段整个删掉

留着它的代价不是多一行代码，是**测试会去断言一个线上不可能出现的状态**：
`InsightRadarTests` 里三处 `waitingHours: 3` 撑着 `severity == .high` 的断言，
读起来像「等待足够久会变成红色紧急」这条产品规则真实存在 —— 它不存在，
生产里那个数永远是 0（唯一传非零的是预览 fixture）。

删掉：两个模型字段、`InsightAttentionBar.actionItemRow(hours:)` 参数与
「· 等 3h」文本、两处 `formatHoursShort`、`InsightRadar.formatHours`、
`ChatInsightView` 导出文本里的「（已等 N 小时）」。
`severity: waitingHours >= 2 ? .high : .medium` 退成 `.medium`，
并在原位写下为什么等待行不再被抬成红色。

顺带修了一条自己写的担保句：模型注释里「the inbox does, from the messages
themselves」是空的 —— 全项目没有任何地方真的算出过等待时长。注释改成陈述现状。

## §134 外部字符串进 SQL：P0 无，4 条定价

子代理报 `P0: 无`，并给出覆盖面（HUDStore 12 处插值 SQL 全部读过上下文）。
我自己复核了它点出的两条最像 P0 的：

- **P1（潜伏）** `WeChatReader.listAllChatTables()` 用 `name LIKE 'Msg_%'` 取表名，
  SQL 的 `_` 是单字符通配 ⇒ 能捞到 `MsgX…`；且这里没有 Swift 侧 `hasPrefix("Msg_")`
  复查（:1852 那条路径有），表名随后被拼进 `FROM [\(name)]`（:1346/:1621/:1695/:1709），
  全项目没有 `]` 转义。**当前不可达**：这几条只有测试在调，
  活路径的表名来自 `Msg_\(md5Hex(username))`，纯 `%02x`。
  定价：不改（改法要给一个不可达的分支加转义，属于给假想需求做设计），
  但如果哪天把 `listAllChatTables` 接上活路径，这条必须先补前缀复查。
- **P1** 同一片区域的 `guard let db = try? acquireReadonly(...) else { return 0 }` +
  `prepare != SQLITE_OK ⇒ return 0`，出现在声明为 `throws` 的函数里 ⇒
  一条永久失败的语句被读成「没有新消息」，游标不前进、也没有错误面。
  同类：`HUDStore:2706`（讨论查询失败 ⇒ 空收件箱）、`SchemaMigrator:43`
  （`try? exec("PRAGMA user_version = …")` ⇒ 版本标记可能永不落）。
  这条本轮没动，是下一轮「读不到印 0」扫描的入口。
- **P2** `HUDStore+ChatAlias:171` 把常量「未命名群聊」拼进 `= '…'`：值安全，
  但它是对显示名的精确匹配，任何参与者把群起成这个名字就会被 `propagateChatName*` 改写。
- **P2** `HUDStore+Retrospective:497` 用 `'\(rawValue)'` 拼 `status IN (…)`（内部枚举，今天安全）；
  `HUDStore:1628/1641/1767` 的 `LIKE "\(prefix)%"` 没有 `ESCAPE`（当前 prefix 全是常量）。

## §135 上一轮 §128/§129 的回账（同一路子代理逐条攻）

- **Q1 `waiting_hours` 有没有残留通路** —— 无。encode/decode 两侧都摘了，
  全项目没有自写 `init(from:)` 嵌这些结构体、没有 `keyDecodingStrategy`。
  改动前写的缓存行读出即无这个键，不崩、静默丢数（可接受：那些数本来就没依据）。
  它同时抓出注释里的假担保 ⇒ §133。
- **Q2 摘掉 `> 0` 分枝后有没有留下悬空文案** —— BROKEN ⇒ §132（不是空串，是重复/自引用）。
- **Q3 丢掉 `.high` 会不会让一行整个消失** —— 判阴。没有任何 UI 按 severity 过滤，
  severity 只喂颜色、标签和排序；唯一的「消失」是 `prefix(limit)` 的挤出，属既有行为。
- **Q4 钳制水位会不会造成无限重扫** —— 成立（不翻页）。合法超前写入不存在
  （水位写入点只有 ScanEngine:793/891/975，seed 用 `Date()`）。
  代价说清楚：未来行现在每轮都被当成新行重扫、水位钉在 now，
  但 :387-419 的 while 由 `gapClosed`/预算收敛，不会无限翻页。
  比「该对话永久静音」好，但不是免费的。
- **Q5 回填方向的钳制** —— 成立，残余 P2：`frontierToPersist` 取自 anchor/page.last，
  回填朝旧，合法值恒 ≤ now，钳制实为空操作；只有整页都是未来行时才生效，
  此时写入的续扫点被拖回 now（非单调），最深点丢失，每轮重复回走同一段。
  以损坏库为前提，接受。

## §136 本轮没验到的（写清楚，别让它读起来像全覆盖）

1. **§130 的最后一米没有真机验证。** 预览模式下 `performTextAction` 直接返回
   `.previewMode`，撤回路径在测试和截图里都到不了。测到的是判定函数与接线，
   不是「按 Return 前真的停住」。要验只能开着真微信手动点一次停止。
2. **§132/§133 的像素质检没做到。** 洞察页挂在工作台侧栏「聊天回顾」那一行
   （`SettingsView.swift:366`），`--preview-insight-overview` 只保证「进了洞察页
   就停在总览」，不会替脚本把那一行选中 —— 预览库默认落在「今天」，
   所以截图产物里没有总览。欠一个「选中某个工作台分页」的启动开关。
   （写这条之前我先按 `InsightWindow` 判过一次「文档过期」，回源码才发现
   那个独立窗口类**零调用方**：本轮删掉了它，见 §137。）
3. **常驻资源增长那一轴本轮没结论**：派出的代理在 38 次调用后中断，
   重派范围已收窄到「重复创建的 timer/observer」+「只增不减的集合」两条面。

## §137 `InsightWindow` 是一个没人能打开的窗口（P2，本轮删除）

55 行的 `NSWindow` 子类，`Sources/` 与 `Tests/` 里零调用方 —— 它自己注释写着
「large independent window for chat analysis」，而洞察页实际是工作台侧栏的一行
（`ChatInsightWorkspacePage` → `SettingsView.swift:366`）。
它同时是 §136 那条误判的来源：我按它推断「总览在独立窗口里，所以截图没到」，
把一次没截到图的锅扣给了文档。回源码走一遍调用方才看清：窗口类是死的，
缺的是「选中分页」的开关。

按「生产不可达的死 UI 直接删」处理。要恢复它得先回答它和侧栏那一行的分工，
而不是留一份和真实入口互相矛盾的代码。

## §138 截图把我上一条修复证伪了（P1，本轮修）

§132 的判据写成 `item.source == chatName`。跑 `--preview-tab=insight` 拍总览，
等待行仍然是「林晓 · 产品同事 ／ 依据：林晓」——
因为对话的显示名带角色后缀（`「名字 · 角色」`，见 `AdmissionSettingsView.swift:183`
等三处 `joined(separator: " · ")` 的约定），精确相等对私聊永远不成立。

改成 `chatName.hasPrefix(item.source)`，并给测试补上带后缀的那一种形状
（`InsightRadarTests.testWaitingEvidenceDoesNotEchoTheChatName` 里新增一段）。
群聊那一行仍然保留「依据：林晓」—— 图里也确认了：群名不含人名时，这是新信息。

顺带补了缺的治具：`--preview-tab=<tab>`（`PreviewRuntime.requestedLaunchTab` →
`SettingsView.selectedTab` 初值）。在此之前脚本启动永远落在「今天」，
`--preview-insight-overview` 只能保证「进了洞察页就停在总览」，
所以那一页从来没被自动拍到过 —— 这也是 §132 当初只做了字符串级验证的真实原因。

**教训**：判据用「相等」还是「包含」，要看渲染侧的字符串是谁拼的。
我按数据字段想当然，而界面拿到的是拼好的显示名。

## §139 桌面导出的权限位、QA 产物的权限位、以及打进系统日志的群名（P1）

导出轴的代理报了 P0「导出绕过脱敏政策」。回源码判阴一半、成立一半：

- **判阴的部分**：`Redactor` 的文件头写得很清楚 —— 它是 RetrospectiveJob 的
  代号映射，「The map lives only in memory — never persisted to disk」，
  管的是**出网**。桌面导出是用户主动导自己的报告，把人名和原文打码会让这个
  功能失去意义。代理把一条出网政策当成了普适政策。
- **成立的部分（已修）**：
  1. `ChatMonitor+DailyReport.swift` 写 `~/Desktop/WeChatHUD-<date>.md` 用默认的
     0644，而 macOS 默认把桌面同步进 iCloud；同一个仓库里密钥文件是 0o600
     （`AccountStoreCoordinator.swift:262`）。改成写完 chmod 0600。
  2. `AccessibilityAudit.swift:240` 把每个控件的 AX `label`/`help` 落到 `$TMPDIR`
     且 0644 —— 那里面会有联系人名字和消息派生文本。同样补 0600。
  3. `ChatAnalyzer.swift` 三处 `print` 把真实 `chatName` 打进 stdout（进统一日志，
     其他进程可读）。消息正文那里已经 `sanitizeForAI`，名字这里漏了；
     改成只报计数。

## §140 两个设置在替算法许愿（P1，改文案 + 让文案咬住调用点）

- 「回复最长写多少」「写得更随意一些」的注释写着
  「这是平时**写摘要和草稿**的习惯」。实际：`AIInboxSummarizer.swift:124` 传
  `temperature: 0.1, maxTokens: 2048`，`AIReplySuggester.swift:208` 传
  `temperature: 0.4, maxTokens: 512` —— 被点名的两条路径恰好都不读这两个滑杆，
  它们只影响没传 options 的调用。另外 `AIService.swift:154` 对
  `responseFormatJSON` 强制关思考，所以「慢慢想清楚再答」对草稿也不成立（对摘要成立）。
- 「发现后自动安装」：`installIfEnabled: true` 全项目只有一处，
  在 `scheduleLaunchCheck` 里，而它又被 `config.autoCheckEnabled` 挡着。
  三个用户会点的「检查更新」按钮全都传 `false`。
  所以这个开关的生效条件是「启动 + 开了自动检查」，面上一个字没提。

改法选文案不选行为：那两个固定参数是调出来的（摘要要确定、草稿要短），
把它们交给用户滑杆是一次产品改动，不该由质检顺手做。
新增 `SettingsScopeHonestyTests`：一条锁文案不再声称摘要/草稿，
一条锁**调用点仍然传字面量** —— 哪天真接上滑杆，这条会红，逼着回来重写文案。

## §141 判阴：已提交的 31 张 workspace-audit 截图不是真实对话

导出轴另报一条 P1：「`docs/qa/2026-09-08/workspace-audit/` 的截图没有来源声明，
而这个仓库是公开的」。它找的是 `acceptance.md`（那里只声明了 `design/` 那批）。

我自己打开 `01-today.png` 看了：窗口顶部有常驻横幅
「交互演示 · 全部为虚构数据，不读取或操作微信」，人名是 fixture 的
「项目协作群 / 林晓 · 产品同事」，与我这一轮预览拍到的完全同一套。
`workspace-audit/audit.md:3` 也写了「截图来自原生演示包，全部为虚构对话」。

判阴，但这条值得留在记录里：**公开仓库里的截图必须自带可见的虚构声明**，
声明在 markdown 里不算，图上有才算 —— 这次代理只能从文档找证据，
而文档恰好没覆盖那一个目录，看起来就像泄漏。

## §142 改完文案的像素复核只做到一半

`--preview-tab=preferences` 现在能把「使用偏好」直接拍到视口里，
但 `--preview-capture` 是**视口截图**：「版本与更新」这张卡只拍到
当前版本 / 检查更新 / 启动时自动检查 三行，我改的那一条（发现后自动安装）
在折叠线以下，没拍到。

所以新写的说明先按同页最长的那一行（「登录时启动」约 40 字）压到同一量级，
而不是赌它能换行。真正欠的是一个「滚动到某张卡再拍」的开关，
和 §138 的 `--preview-tab` 是同一类缺口。

## §143 那两条「潜伏 P1」其实骑在死代码上（本轮删除）

SQL 轴报的两条最像 P1 的 —— `listAllChatTables()` 的 `LIKE 'Msg_%'`（`_` 是通配、
没有 Swift 侧前缀复查、表名随后被拼进 `FROM [\(name)]`）和
`countNewMessages` / `maxLocalId` 把 prepare 失败读成「0 条新消息」——
代理的覆盖面写的是「当前只有测试在调，属潜伏」。

我自己重跑了一遍引用检索（全仓库，含 `Tests/`、`scripts/`）：
**三个函数一个调用方都没有**，连测试都没调。
所以既不是"潜伏的活路径缺陷"，也不值得为它加错误处理 —— 直接删掉 51 行。
删完 `swift build` 干净，`WeChatReader|ScanEngine|NewSchema` 57 条通过。

顺带记一条对代理报告的处理纪律：**「只有测试在调」和「没人调」是两回事**，
前者要修，后者要删；判据要自己重跑，这次重跑直接把两条 P1 变成了零条。

## §144 我这条修复自己造了一个新 P1：暂停会把草稿判死刑（本轮修）

「攻本轮 diff」的子代理报回：`deliveryStillPermitted` 把 `isPaused` 算进关闭条件，
而 `isPaused` 包含**用户切进微信时自动生效的 `pausedForUserActivity`**。
中途关闭 ⇒ 发送失败 ⇒ 落进失败尾巴：`autoSendAttempts += 1`、
`manualOnlyReason = "…"`、重新入队并**写进 DB**。而
`isEligibleForAutomaticSend` 要求 `manualOnlyReason == nil`，
`start()` 又从 DB 把它读回来 —— 结果：**用户在打字的 1.5–8 秒里切到微信，
一条排好队的自动回复就被永久转成人工，卡片还写着「发送失败」**。
这和 `sendNow` / 暂停分支「暂停只保留、不消费」的既有约定相反。

改法：把「暂停」和「撤回」分开处置。`withheldByPause(paused:sessionOpen:rowStillQueued)`
为真 ⇒ 走可重试路径（不记尝试、不打人工标记、回执改说
「自动驾驶暂停，这条没有发出，仍留在队列里。」）；只有行真的没了或会话真的结束，
才按撤回/失败消费掉这条。

验证过程里翻了一次车，记下来：
第一版我只加了「`withheldByPause` 出现在打标记之前」这条顺序判据，
然后跑变异 M6（把调用点的 `|| pausedMidFlight` 去掉）—— **7 条全绿**。
判据没牙：函数还在原地被调用，顺序当然成立，而真正被改掉的是它结果的使用方式。
（同一个函数里 `retained.manualOnlyReason` 在发送**之前**的额度/过期分支也出现，
第一次取到的位置在尾段之外，这条判据连"在看哪一段"都没锁住。）

于是把处置收成一个纯函数 `sendFailureDisposition(paused:sessionOpen:rowStillQueued:
reason:retryableReason:) -> .requeueUnchanged | .humanRequired`，
打标记、记尝试、回执文案三处全部改由它的结果决定，判据也就能咬住接线：
- 4 条真值表（含两个必须为假的形状：行已删、会话已结束）；
- 尾段顺序 + 两条接线断言（记账必须挂在 `if case .humanRequired`，
  判定必须真的读 `store.hasPendingSend(id:)`）。
- **M7**（调用点把 `rowStillQueued` 写死成 true）⇒ 1 条失败。
- **M8**（把记账挂反到 `.requeueUnchanged` 上）⇒ 1 条失败。

教训：**判据写完必须用变异跑一次才知道有没有牙**，这次是跑出来才发现的，
不是我写的时候想到的。

同轮三条 P2 一并处理：
- `.automationHostMissing` 原本把「reader.dbDir 为空」也吞进去，
  于是「没连微信就打开自动驾驶」会被提示成「浮窗主程序没有运行」——
  拆回 `.accountUnverified`；
- 删 `formatHours` 时把它那段 4 行文档注释留给了下面的 `sanitizedFinding`，已删；
- `--preview-tab=` 打错字会静默落回「今天」，QA 脚本却以为自己拍到了目标页 ⇒
  现在打一行警告。

**仍留着的一条（定价）**：`hasPendingSend` / `autopilotLogPendingReply` 走 `queryOne`，
而 `queryOne` 内部 `try?` 吞错 ⇒ 一次 SQLITE_BUSY 读会被读成「已撤回」，
把真发送关掉并（修完 §144 后）转人工。要根治得给这两个查询一个能区分
「查不到」与「查失败」的返回，属于「读不到印 0」那一整类，下一轮统一收。
