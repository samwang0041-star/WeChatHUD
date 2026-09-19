# 第 32 轮：窗口走错了时钟、升级路径把降级放大成退出、暂停期间的积压

判据：多子代理持续质检到没有 P0。本轮三路并发（时钟/时间轴、常驻资源增长、读失败塌陷）
＋一路（老库升级路径），逐条回源码判定，成立 4 条 P0、修 3 条判阴 1 条，另收 P1 两条。

## §157 三处「窗口」记在墙钟上，用户拨一次表就把护栏和提醒一起抹掉

`Date()` 是系统**拥有**的量，不是它**测量**的量：用户可以手动改，macOS 也会在硬件时钟漂移后
校正。而这三处记录的窗口，比的都是「本进程亲眼看到的两个事件之间过了多久」：

- `AutopilotService.globalSendTimestamps` —— 每小时发送上限。墙钟**前进** 2 小时，
  所有时间戳被判成「一小时以前」→ 清空 → 同一个真实小时内可以再发一整轮无人值守回复。
  这条是无人值守发送的最后一道兜底，被一次拨表解除。
- `ProactiveAlertEngine.alertHistory` / `pushedIdentifiers` —— 每小时 5 条配额与
  按标识符的静默期（到期承诺是 24 小时）。**前进**：配额退回 + 未解决的到期承诺立刻再提醒一次；
  **后退**：所有记录变成「未来时间」→ 整个主动提醒（含 P0 未回规则）静默到墙钟追上来为止，
  而设置页仍然写着「已开启提醒」。这与第 30 轮修的「未来时间戳把对话永久静音」同一形状。
- `batchTimers` / `batchStartTimes` / `recentStallByContact` —— 批处理截止与缓兵之计去重。

新增 `Services/MonotonicClock.swift`（`ProcessInfo.processInfo.systemUptime`，只计开机后的
清醒时间）与可注入的 `MonotonicSeconds`。**判据是一条可复述的界线**：本进程自己观察到、
只跟自己比的时间 → 单调轴；要和数据库里的瞬间比、或要落盘的 → 墙钟。因此
`scheduledSendTime`（落盘、跨重启）、热聊 10 分钟窗口（比 `createTime`）、
`verifySend` 的 `startedAt`、`stalePendingSendReason` 全部**留在墙钟**上，代码里写明了为什么。
睡眠期不计是刻意的：睡着时本来就不发送也不评估，窗口跟着停只会让上限更严、批处理更晚，
不会让它提前触发。

会话时长 `SessionStats.duration` 的锚点是数据库里的 `started_at`（必须留在墙钟），
只补了 `max(0, …)`：倒退的墙钟以前会印出「-7200s」。

配套判据（`AutopilotBatchWindowTests` / `ProactiveAlertTests`）：
- `testBatchWindowIsMeasuredOnTheInjectedAxis` —— 注入一个「开机秒级」的时钟，
  只有这条轴越过截止点才排空批次。旧实现下截止点≈17.7 亿，怎么推都不动 → 该测试红。
- `testForwardWallClockJumpDoesNotRefireAnOverdueCommitment` /
  `testForwardWallClockJumpDoesNotRefillTheHourlyBudget` /
  `testBackwardWallClockJumpDoesNotMuteAlertsForever` —— 墙钟跳 ±3 天，单调轴只走 1 秒，
  三个方向各钉一条。
- `testSendCapAndStallWindowReadTheMonotonicAxis` —— 闸门函数体内必须出现 `monotonic()`
  且不得出现 `Date()`/`3600`；阈值只许在 `rollingSendHour` 里算一次。

变异记录（每次都用 python 断言锚点在，跑完 `cp` 还原，还原后 grep 变异标记为 0）：
M13（提醒窗口退回墙钟）→ 3 条新测试全红；M14（批处理排空退回墙钟）→ 注入轴测试 3 条断言红；
M15（每小时上限退回墙钟）→ 接线判据红；M18b（淘汰阈值改成 `.infinity`）→ 接线判据红。

顺手删掉两条假测试：`testRateLimitPreventsExcessAlerts` / `testRateLimitAllowsAfterPrune`
各自在测试里现造一个 `[Date]` 数组、用**自己写的** `removeAll { $0 < oneHourAgo }` 判一条
自己刚塞进去的断言，一行生产代码都没碰到。引擎级的窗口行为已由注入 `monotonic` 的
`testIdentifierDedupExpiresAfterOneHour` / `testHourlyBudgetIncludesInFlightAndReopensAfterWindow`
真实覆盖。

## §158 被吞掉错误的 ALTER，被一条硬 `try` 消费：一次 BUSY 就让老库用户永远打不开应用

`HUDStore.createTables()`：

```swift
_ = try? exec("ALTER TABLE autopilot_log ADD COLUMN queue_id TEXT")
try   exec("CREATE INDEX IF NOT EXISTS idx_autopilot_log_queue_id ON autopilot_log(queue_id)")
```

上面两行注释明说 `queue_id` 缺失是**可运行状态**（旧行保持 NULL，退回 (chat, reply) 文本匹配），
而下一条索引语句却把这条 ALTER 的成功当成前提。ALTER 真失败（另一个进程持有写锁超过
busy_timeout=5000、磁盘满、`hardenTree` 之后文件不可写）时，`no such column: queue_id`
从 `createTables()` 抛到 `store.open()`，`AppDelegate.swift:100` 的 catch 给出一个模态框
然后 `NSApp.terminate` —— **每个老库用户每次启动都是这样**。全仓 21 处 ALTER 里这是唯一一处
这种配对（`autopilot_inbound_queue.content_key` 与 `classification_queue.content_key` 都是
两条 `try?` 配套，做法正确）。

同一模式的第二处（P1）：`SchemaMigrator.migrateToV3RetrospectiveIndexes` 用硬 `try` 在
`red_banner_dismissals` / `review_todos` 上建索引，而这两张表由 `migrateRetrospective()` 的
`execIgnoringError` 建立 —— 表没建起来时同样是启动即退。

第三处（P1）：`conversation_memory` 的补列守卫只探测 `shared_context` 一列就跳过整段。
若第一条 ALTER 成功、第二条 BUSY，该库永久停在「有 shared_context、无 communication_notes」，
以后每次启动守卫都已满足，**再没有任何代码路径补这一列**，而读写它的地方全部静默失败。
改成逐列判断（新增 `HUDStore.tableInfo(_:)`，名字里非标识符字符直接返回空，
因为 PRAGMA 不能绑参）。

判据：`SchemaUpgradeResilienceTests`
- `testNoIndexHardFailsOnAColumnThatMayBeMissing` —— 扫全文件，任何 `try exec("CREATE INDEX …
  ON t(col)` 都不得建在被 `_ = try?` 吞掉的 ALTER 列上。带覆盖度下限（至少扫出 12 列 /
  10 条硬索引），否则「零命中」和「全部合格」长得一样。M16（还原成硬 `try`）→ 该判据红并
  指名 `665:autopilot_log.queue_id`。
- `testHalfMigratedConversationMemoryIsCompletedOnNextOpen` —— 真造一个「有
  shared_context、无 communication_notes」的库文件，重开一次必须补齐三列。
  旧守卫下重开十次也不会补。

## §159 暂停期间积压：缓冲区只进不出，恢复时回答几天前的消息

`handleNewMessages` 里 `allExpired = isPaused ? [] : …` —— 暂停时**没有任何批次会被排空**，
而：

- `batchBuffer` 全文件没有容量上限（`removeAll()` 只在 start/stop）；
- 暂停时不 ack，`ackedMsgUIDs` 只来自被处理的批次，`deleteAutopilotInbound` 完全依赖它 →
  磁盘表 `autopilot_inbound_queue` 只进不出；
- 去重屏障会被击穿：`processedMsgUIDs` 超 5000 裁到 2500，被裁掉的 UID 因为仍在磁盘队列里，
  会被 `loadPendingAutopilotInbound(limit: 200)` 重新喂进缓冲区。

用户可见的后果不是「内存有点大」，而是**恢复自动回复时去回答几天前的消息**。
「暂停」是用户主动关掉又不动它的最自然方式（不是异常态），所以可达。

修法是一条谓词、两个消费点：`AutopilotService.isPastReplyHorizon(timestamp:now:horizon:)`
（10 分钟，与它身边的缓兵去重/热聊窗口同量级，远大于 60 秒批处理上限）。
喂入时超龄的消息不进缓冲区（落一条 `.skipped` 审计行 + ack，让磁盘行随之消失）；
`ageOutBufferedMessages` 每趟扫一次已缓冲的内容，暂停期间也扫（`allExpired` 那一步被
`isPaused` 挡住，这一趟没有）。谓词刻意单边：未来时间戳算出负龄 → 保持可回复，
不让对端时钟超前把自己的对话永久静音（§128 的教训）。

判据：`testMessagePastTheHorizonIsDroppedAndAcknowledged`（旧代码 5 条断言全红，M17）、
`testBufferedBacklogAgesOutInsteadOfReplaying`、`testFutureTimestampsStayEligible`、
`testFeedPathRunsTheAgeOutSweepAndKeepsItsResult`。最后一条是接线判据而不是行为判据 ——
淘汰阈值可以从外部注入，`handleNewMessages` 里那一趟却没法用不动真实时间的测试驱动，
所以钉住「调用点存在 + 用生产阈值 + 返回的行与 id 都被接走」。

## §160 判阴：批处理 deadline 不会「永久卡住」

时钟轴那路代理另报一条 P0：「future-dated 批处理截止时间把队列永久卡住，重启后
`batchBuffer` 清零 → 这批消息永久不再被分类」。回源码不成立：

- 未 ack 的行**不会被删**（`deleteAutopilotInbound` 只吃 `ackedMsgUIDs`），因此重启后
  `loadPendingAutopilotInbound` 会把它们重新喂进来，`processedMsgUIDs` 是内存态、重启即空，
  于是拿到一个**全新的**截止时间 —— 不会永久不再分类。
- 唯一的永久清除发生在 `stop()`（`clearAutopilotInboundQueue`），那是用户亲手按下停止，
  丢弃是它该做的事。
- 所以墙钟倒退的真实伤害是「这段时间里批次不排空」，可自愈。仍然随 §157 一起换到单调轴，
  但记为 P2 而不是 P0。

同轮另两条判阴：
- 「扫描风暴」：`ChatMonitor.chasesPendingBatches(hasPending:paused:)` 已经处理过
  （注释里就写着暂停时批次永远排不掉，所以不再追），不是本轮新问题。
- 「autopilotActive 为真但 sessionId 为空时磁盘队列无限增长」：`autopilotActive` 只在
  `service.start()` 成功后置真、`stopAutopilot()` 无条件置假，两条路径都不留这个组合，
  判为不可达；真要加固应是「载入时按龄过滤」，但那会把该留审计行的消息静默删掉，
  与 §159 的做法相反，故不加。

## §161 未收口的（已定价，等决定）

`read-failure` 那路另报 3 条 P0 + 2 组 P1，逐条回源码后确认成立、但都不在本轮的时钟轴上，
留作下一轮：`isWhitelisted` 读失败 → 分类队列把该消息**当已处理删掉**（永久跳过，界面无痕）；
`resolveAutopilotLogSent` 事务被 `try?` 吞掉 → 双胞胎仍是 pending → 二次「确认发送」双发；
`?? AutopilotConfig()` 家族（设置页的 merge-update 以默认值为基底覆写未暴露字段后仍显示
「已保存」）—— 已在 §164 收口；谓词本身也抽成了可直驱的三臂函数。通知授权（`error == nil` 当成送达、不检查 authorization、
`granted` 被丢弃、真话 `notificationExplanation` 是死代码）—— 那条单独一轮 —— 已写成 §162（授权闸门）+ §165（前台丢弃）+ §166（尾巴定价与两条判阴）。
前两条的三态谓词与 `resolveAutopilotLogSent` 的失败分型也已在本轮落地（`whitelistRead` /
`AutopilotSendResolution` + `alreadySentHere` 闸门，见 §161 之后各节）。

## §162 「已提醒」原来是算出来的：系统通知被拒时，配额和 24 小时静默期照扣

`ProactiveAlertEngine.pushAlert` 把 `completion(error == nil)` 当成「已送达」，
`systemNotificationSender` 提交前不看授权，`requestAuthorization` 的 `granted` 直接丢弃。
macOS 在通知被拒时 `add()` **不报错**，只是什么都不显示 —— 于是每条规则每次都：
扣掉一格每小时配额、给这个标识符记上静默期（到期承诺是 24 小时）。
用户后来去系统设置里打开通知，那一整段时间里仍然一条提醒都收不到，
而设置页写的是「接收待办提醒与重要更新。」——一句只有 macOS 同意才算数的话。

同页其实早就有一句按授权状态说实话的 `notificationExplanation`（`.denied` 分支写着
「通知未获允许，顶部浮窗和窗口仍可使用。」），**全仓零引用**，是死代码。

修法：
- 纯谓词 `canSubmitNotification(authorization:)`：`.authorized/.provisional/.ephemeral` 可提交
  （静默进通知中心也算送达，该扣配额），`.denied/.notDetermined` 不提交、**不扣任何账**，
  下一次评估就能补上；读取还没落地时 `nil` 失败打开，启动后第一条 P0 提醒不能因为
  一个还没回来的异步读被丢掉。
- 授权状态按 30 秒的节奏在 `evaluate` / `evaluateCommitmentDeadlines` 入口刷新，
  读的操作者自带回主 actor 的一跳（测试里同步完成）。生产 init 读真值，
  测试 init 默认 `.authorized`：`UNUserNotificationCenter.current()` 在测试宿主里不可用，
  而规则测试不该替通知中心回答「这条会不会显示」。
- 设置页那一行的副标题改成 `notificationExplanation`，删掉那句无条件的好处。

判据：`testDeniedAuthorizationDeliversNothingAndChargesNothing`（被拒不发 → 开启后**立刻**能发）、
`testAuthorizationGateFailsOpenOnlyBeforeTheFirstRead`、
`testNotificationRowSaysWhatTheSystemAllows`（钉住「一处定义、一处渲染」，
再少一处就是它又变回死代码）。变异 M19（闸门只看返回值不放行）→ 第一条断言红；
M20（`nil` 当不能提交）→ 纯判据红，并且整套提醒测试一起红（说明「失败打开」是承重的）；
M21（被拒时仍记静默期）→ 「开启之后就该立刻提醒」那条红。

未覆盖面（本轮没查）：`RetrospectiveJob` 与其他直接 `add()` 的通知生产者是否有同形问题、
点击横幅的回跳路由、以及在 HUD 里处理完之后通知中心里的旧横幅是否还在说话。已另派一路。

## §163 自查：§158 里「下次启动会重试」这句当时是假的

§158 把 `migrateToV3RetrospectiveIndexes()` 改成返回 Bool、并且只在落地后才写 `user_version`，
我以为这就恢复了重试。变异 M6（把守卫写成 `|| true`）**全绿** —— 因为同一个函数下面还留着：

```swift
if store.schemaUserVersion() < currentVersion { store.setSchemaUserVersion(currentVersion) }
```

`currentVersion == 3`，所以这个无条件兜底紧跟在守卫后面把章又盖上：失败的那次启动照样走到 3，
「retried forever」从来只在打章之前的那一次成立。这段兜底是 Void 版迁移的遗留 ——
当时迁移不报告结果，需要有人把版本推到 `currentVersion`；现在它是那条守卫的对偶，必须删。
「版本号是一次工作落地的收据，不是要追平的计数器。」

判据：`testFailedIndexMigrationLeavesTheVersionForTheNextLaunch`（真表 → 落地 → 章盖上；
`DROP TABLE red_banner_dismissals` → 迁移报 false → `user_version` 必须仍 < 3）。M6 重跑 → 红。

## §164 `?? AutopilotConfig()`：读失败时「以默认值为基底」合并，再把整条写回去

`getSettingJSON` 对「没存过」和「这次读不回」都答 `nil` —— 和 §161 里 `isWhitelisted` 那个
两态 Bool 是同一个缺陷，但这一处的杀伤在**写**侧。托管设置页整页只暴露 `AutopilotConfig`
约 20 个字段里的 8 个，其余（`sensitiveKeywords`、`maxSendsPerSession`、`proactive*`、
`vipAutoNotify`…）全靠那句 `?? AutopilotConfig()` 之外的合并注释保命：

```swift
var cfg = store.getSettingJSON("autopilot", as: AutopilotConfig.self) ?? AutopilotConfig()
// …改 8 个字段…
try store.setSettingJSON("autopilot", value: cfg)   // INSERT OR REPLACE 整条
```

于是一次 BUSY（`busy_timeout=5000` 之后仍失败、磁盘满、iCloud 同步中）就把用户自己加的敏感词、
每会话上限、主动提醒开关全部换成默认值，**并且盖上「设置已保存」**。默认值里
`autoSendEnabled=false`，所以这条不会立刻让人被自动发消息；它做的是拆掉用户自己架的护栏，
然后假装什么都没发生。

第二处同形：`SettingsView.swift:270`（截图夹具用的确认框）里「允许自动发送」按钮做的是同一件事，
而且写失败被 `try?` 吞掉 —— 全仓最危险的那个开关，读不到时照写，写了不报。

修法：`HUDStore.readSettingJSON` 三态（`.absent / .unreadable / .value`）+ 唯一的合并入口
`updateAutopilotConfig(_:)`，读不到就 `return false`、连合并闭包都不调用；两个页面都改走它。
解不开（deletable garbage）故意算 `.absent`：那不是读失败，没合并的余地，而在写侧拒绝会把
设置页永久锁死。两个页面的「已保存」只在 `wrote == true` 时出现，否则是
「读不回当前的托管设置，这次没有保存 —— 否则会用默认规则盖掉这页没有显示的开关」。

**读侧的默认值不改**（定价，不是漏掉）：读失败时最危险的字段 `autoSendEnabled` 的默认是 `false`，
所以失败即不发；剩下的（自定义敏感词、每会话上限）放松的前提是自动发送本来就关着，
而要让所有 `getSettingJSON("autopilot")` 消费点在失败时都改为「按住不发」，代价是把
一次性 BUSY 变成整条托管路径停摆 —— 这条交易现在不划算。已扫过全部 11 个消费点。

判据：`testSettingReadSeparatesAbsentFromUnreadable`（含垃圾 JSON 那条支路）、
`testAutopilotConfigMergeWriteRefusesAnUnreadableConfig`（false 时闭包未执行 + 正常时未暴露字段存活）、
`testAutopilotConfigIsOnlyEverWrittenThroughTheMergingHelper`（两个页面都不得自己 `setSettingJSON`/
`setSetting("autopilot"`，且必须真的出现 `store.updateAutopilotConfig`）。
变异 M9（`.unreadable` 时以默认值为基底继续写）、M13（还原 SettingsView 的整条写回）→ 都红。

## §165 前台时通知被系统整条丢掉，配额和 24 小时静默期照扣

§162 修的是「被拒不发」，还剩另一半：**app 在前台时 macOS 不弹横幅**，除非委托对象
`willPresent` 里要回来。全仓从来没有 `UNUserNotificationCenterDelegate`，而 工作台
（`AppDelegate.swift:1014/1041`）和 设置（`SettingsWindow.swift:94`）都会 `NSApp.activate`
—— 正是用户最容易看到「该提醒却没提醒」的两个窗口。`add()` 的 completion 照样报成功，
于是那次提交既扣了一格每小时配额，又给这个标识符记上静默期（到期承诺 24 小时）：
开一次工作台的功夫，当天这条承诺的提醒就没了。

修法：`AlertPresentationDelegate`（`foregroundPresentationOptions = [.banner, .sound]` 做成独立
静态量，因为 `UNNotification` 在测试里造不出来），由生产 init 安装、引擎自己强持有
（通知中心弱引用委托）。测试 init 不装：`UNUserNotificationCenter.current()` 在测试宿主里不可用。

同轮删除：`AutopilotService.pushVIPNotification`（原 :2368-2384）是**全仓唯一**绕过
`pushAlert` 的直发 `add()` —— 无授权闸门、无配额、无去重，标识符还是 `UUID()`（连系统去重都吃不到）。
它同时是唯一一处 `import UserNotifications` 的使用，连着 import 一起删。
判阴：删之前确认过它零引用（含测试），且 `RetrospectiveJob` 等其余生产者不直接 `add()`。

判据：`testForegroundBannersAreAskedForRatherThanDropped`（选项含 `.banner` + 生产 init 里真的
`.delegate = presentationDelegate` + 引擎强持有）。M7（选项返回 `[]`）、M8（不装委托）→ 都红。

## §166 通知尾巴的其余四条：定价与两条判阴

派出去攻这条尾巴的那一路带回来 5 条假设 + 3 条额外发现，逐条回源码后：

- **成立，未修（P2）**：没有任何点击回跳。`didReceive`/`UNNotificationResponse`/`NSUserActivity`/
  `setNotificationCategories`（连通知按钮都没有）全仓零命中，`add()` 两处均不接点击。
  点通知跳到那个对话是一个功能，不是修 bug；现在没有任何文案承诺它，所以不进本轮。
- **成立，未修（P2）**：零 `removeDeliveredNotifications`/`getDeliveredNotifications`，
  用户在 HUD 里处理完之后，通知中心里的旧横幅还在说话。标识符本来就是确定式的
  （`commitment-overdue-<msgUID>`、`vip-<chat>-<tier>`、`p0-debt-<chat>`），
  要清就得在 `ChatMonitor.updateCommitmentStatus:2427`、`batchUpdateCommitmentsStatus:2444`、
  `dismissInboxItem:2587`、`HUDStore.resolveVerifiedSend:3700` 这几个状态变更点后各摘一次 ——
  4 处接线，一处不接就不一致，所以单独立一轮而不是塞进本轮。
- **成立（P2，故意不改）**：提交失败既不扣配额也不记去重，下一个 tick（心跳 30 秒）就重试同一个
  标识符；`add()` 持续失败就是每 30 秒一次 XPC，无限期。给失败记静默期就等于让「用户没看到的
  一次提交」把他该收到的提醒按住 5 分钟 —— 和 §162 刚拆掉的那个逻辑是同一个错误，只是方向相反。
  上限就是 XPC 频率，授权闸门挡住的是更常见的成因，所以留着。
- **判阴**：「`ProactiveAlertEngine` 的去重只在内存里，重启后同一条到期承诺会再提醒一次」成立，
  但「能发好几次」不成立：一次启动扫描里同一条只发 1 条（心跳 `ChatMonitor:539` 与扫描
  `evaluate→:217` 都被 `pushAlert` 的同步预占 :479 挡住），放大只来自重启，即 N 次重启 = N 条。
- **判阴**：「DetailPanelView.swift:155 的『关掉这条提醒』管不住承诺横幅」是假阳性。
  那个按钮关的是详情面板里那条**瞬时内联提示**，`DetailNoticeState` 的注释（:164-167）明说
  「只活到这次访问，下次进来看见，不写盘」，tooltip 也写「消息仍在收件箱里」。
  承诺到期告警走的是 `evaluateCommitmentDeadlines`，它确实过滤了免打扰名单
  （`store.loadIgnoredSenders()` + `isMutedForCommitment`，:300-304）。把「稍后提醒/整条静默」
  那套 per-chat `chat_actions` 塞进承诺路径是另一件事，不是文案落空。

## §167 判据侧被攻出的四处「永远绿」，以及本轮变异表

本轮最后一路专门攻我自己的判据（只读代理，不改文件），带回来 8 条，其中 4 条成立并已修：

1. `testUnreadableWhitelistKeepsTheQueueRowForRetry`：`queueCount==1` + `ai.calls==0` 恰好也是
   「worker 完全没跑」的样子。补 `pendingClassificationMessages().isEmpty`（行必须已被推到将来，
   证明确实执行过一次退避），另加直驱三臂的 `testScopeVerdictMapsAllThreeWhitelistAnswers`
   —— 为此把谓词抽成 `nonisolated static ChatMonitor.scopeVerdict(whitelist:muted:)`，
   队列那条退化成接线判据。
2. `source.contains("retryUnresolvedSendWrites()")` 被**函数声明自己**满足（声明就叫这个）。
   删掉 `processPendingQueue` 里唯一那个调用点它照样绿。改成出现次数 ≥2（M10 → 红）。
3. `testLauncherReReadsPermissionAtBothSidesOfThePaste`：`count==2` 加只跟**第一个**检查点比过
   发送键 —— 把第二个 guard 挪到 `switch sendKey` 之后它仍然绿，而「按发送键前能拦住」正是这条
   判据存在的全部理由。改为逐个检查点定位、都要求早于发送键，且粘贴在第一个之后。
   同处把三处 `range(of:)!` 换成 `XCTUnwrap`：锚点没了会 trap，等于打死整个测试二进制。
4. `testUnresolvedSendWriteIsRecordedAndConsulted` 的切片越界：从 `approvePending` 一路切到
   `/// Reject a pending item` 会把 `retryUnresolvedSendWrites` 圈进来，而那里也有一句
   `case .writeFailed:` —— 发送路径删掉它，判据由重试函数满足。收口到 `func retryUnresolvedSendWrites` 之前。

另有两条同轮的自伤修正：`testFutureTimestampsStayEligible` 的玩具时间戳（epoch 1000）被我自己在
§159 之后加的 `plausibleMessageEpoch` 地板判成「 unusable」，测试绿在产品是对的那个支路上 ——
换到可信纪元；以及该判据的绝对值补强（`1_200_000_000` 必须是「可疑」而不是「超龄」，
否则地板退化成 `timestamp > 0` 时上面三行仍然全绿）。
`inFlightReservationWindow` 那条则相反：原来 `mono += window + 1` 把常量读回来当断言，
常量飘到 1e9 秒也测不到 —— 现在行为步长仍由常量推（合法改 180 不假红），
另外加 `30 ≤ window ≤ 600` 的绝对区间负责抓漂移。

本轮 19 条变异，全部被抓住：M1-M3（已发送写回集合、喂给闸门的入参、纪元地板）、
M4-M6（预占窗口两向、免打扰三态、版本收据）、M7-M13（前台选项、委托安装、合并写、
重试调用、纯谓词、地板漂移、页面绕过合并入口）、M16/M19-M21（§158/§162 的既有判据）。
「变异后仍全绿」这一轮出现 3 次，三次的结论都是判据有问题：两次是切片/锚点指错，
一次（M6）直接暴露了 §163 那条真的死守卫。

