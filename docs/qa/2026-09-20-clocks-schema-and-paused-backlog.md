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

**只读消费点的默认值不改**（定价，不是漏掉）：读失败时最危险的字段 `autoSendEnabled` 的默认是
`false`，所以失败即不发；剩下的（自定义敏感词、每会话上限）放松的前提是自动发送本来就关着，
而要让所有 `getSettingJSON("autopilot")` 消费点在失败时都改为「按住不发」，代价是把
一次性 BUSY 变成整条托管路径停摆 —— 这条交易现在不划算。已扫过全部 11 个消费点。
**但这条定价当时划错了界**：`load()` 不是只读消费点，它是写操作数 —— 已在 §168 修掉。

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


## §168 同一条形状的其余实例：这一轮先从「批量读」和「水位读」两处补

派出去的两路（一路攻刚提交的 6f164045，一路按形状扫全仓）回来 6 条候选 P0，逐条回源码后
成立 4 条、其中 1 条是我自己上一轮的漏定价。本轮修掉 4 条：

- **§164 的另一半在载入侧**（我自己漏的）。`AutopilotSettingsView.load()` 仍然是
  `getSettingJSON("autopilot") ?? AutopilotConfig()`：onAppear 一次 BUSY 就把 8 个字段以默认值
  上屏，而 `save()` 合并写回去的正是这 8 个 —— 用户看到「自动发送是关的」于是打开它，
  这一次点击同时把 `excludedContacts` 清成 `[]`（「不再自动回复这些人」没了），并显示「已保存」。
  §164 的定价理由（「失败即不发」）只覆盖只读消费点，`load()` 是**写操作数**，不算只读。
  改法：载入走三态；`.unreadable` 时置 `loadError`、`save()` 的守卫里带上 `loadError == nil`，
  页面给「重新读取设置」出口。判据：`testAutopilotPageNeverHydratesFromDefaultsItCouldThenSave`。
- **准入快照用的是把读失败塌成 `[]` 的批量读**。`AdmissionRules.load` → `store.getWhitelist()`
  （`queryAll` 吞错）→ `followedChats` 空 → `AdmissionPolicy.decide` 答「没关注」→
  分类队列那一支 `completed.insert` → 行被删。和 §161 修掉的 `isWhitelisted` 是同一件事，
  但一次 BUSY 抹掉的是**整批**待分析消息而不是一条。改法：`whitelistAllRead()` 三态 +
  `AdmissionRules.followingUnreadable` + 把「拒绝时怎么办」抽成
  `dispositionForUnadmitted(followingUnreadable:)` 可直驱的谓词。
  判据：`testWhitelistAllReadSeparatesNobodyFollowedFromUnreadable`、
  `testUnadmittedMessageIsRetiredOnlyOverAReadableList`（含两端接线：快照必须来自三态读、
  `.retry` 那一臂必须真的写 `deferClassificationMessage`）。
- **水位读失败被当成「从没扫过」**（`ScanEngine.swift:314`、`:887` 两条链）。`nil` 的语义是
  「首次扫描 ⇒ 基线到当前最新」，于是一次 BUSY 把水位直接推到最新，**上次水位到最新之间那段
  消息此后再也不会被扫到**：没有未回、没有待办、不进托管，也没有任何地方说为什么。
  这正是 :366-374 注释里承认过的老 bug，经「读失败」这条路复活。改法：`CursorRead` 三态
  （`value / neverScanned / unreadable`），读不到时该对话本轮 `continue`，既不前跳也不猜旧值。
  判据：`testCursorReadSeparatesNeverScannedFromUnreadable`（含 DEFAULT-0 那一臂仍算 neverScanned）、
  `testScanSkipsTheRoundWhenTheWatermarkCannotBeRead`。
- **取消侧的写回失败没有第三种答案**（`resolveAutopilotLogSkipped` 原为 Bool）。
  `false` 同时代表「不是待确认」和「写失败」，于是写失败时那条被用户明确取消的草稿继续留在
  待确认里，点一下就把他取消掉的回复发给真人 —— §161 修的发送侧的反方向。改法：返回
  `AutopilotSendResolution`，`rejectPending` 在 `.writeFailed` 时把 id 记进
  `unresolvedSkippedLogWrites`，闸门 `mayStillDeliver(rejectedHere:)` 拒发，
  `retryUnresolvedSendWrites()` 里补一条 skip 重试（先 sent 后 skipped：一条同时出现在两个集合里时，
  已投递是更强的事实）。三个消费点全扫：`AutopilotService.rejectPending`、
  `ChatMonitor.rejectAutopilotItem`（无 service 的那支）、以及原有那条断言。
  判据：`testSkipResolutionSeparatesWriteFailureFromNotPending`（真吃掉一个 pending 行才算数）、
  `testCancelWithFailedWriteIsHeldByTheGate`。

## §169 判据侧这轮又踩到的两个「假绿」，都是我自己写的

13 条新变异里有 4 条第一版是活的，四条的教训各不相同：

- **N3**：`dispositionForUnadmitted` 的两个臂写反（`.retry` 分支去 `completed.insert`）判据仍绿 ——
  因为我只验了「这个函数被调用了」。补：钉住那一臂的完整字面句。
- **N6**：`testCancelWithFailedWriteIsHeldByTheGate` 第一版把整张 `autopilot_log` 删掉，于是闸门
  因为「读不到 pending 行」而拒绝发送 —— 断言被**另一个信号**满足了，本地集合删掉也不红。
  改成用 `BEFORE UPDATE … RAISE(ABORT)` 让写失败而读照常，先断言行仍是 pending，再验闸门。
- **N7**：`load()` 的 `.unreadable` 臂只把 `loadError =` 换成 `_ =` 判据仍绿（三处字符串都还在）。
  补：钉住 `loadError = "读不到` 这一句。载入是 SwiftUI 视图里的状态机，单测驱动不了，
  源码判据是这里能做到的上限。
- **N10**：托管水位链的切片取「循环头 → guard」整段，里面别处本来就有 `continue`
  （`guard let messages = … else { continue }`），删掉真正的 `continue` 照样绿。
  改成按花括号配对取那个 `if` 的**体内**再验（新增 `ifBody(of:anchor:)`，数括号而不是数缩进）。

一条被拒的变异：`retryUnresolvedSkipWrites` 里 `.wasNotPending` 不放回集合 —— 那个改动只是把
拦截做得更严（行已终态时多拦一会儿），不是缺陷，所以不为它写断言。

本轮（§168–§169）共 14 条变异，全部抓住：N1-N11 + N6b（拒）+ 重跑的 N3/N7/N10。

## §170 已验未修（下一轮的清单，逐条带后果链）

攻刚提交那一路另外报的，全部回过源码、都成立，但都不适合塞进本轮（要么需要新的持久状态，
要么要动 2900 行的文件）：

- ~~**P0 `AutopilotService.swift:1771` 队列孪干的收口失败**~~ → 已修，见 §171。
- ~~**P0 `AutopilotService.swift:1553`「取消本条」的持久侧**~~ → 已修，见 §171。
- ~~**P1 `HUDStore.swift:4096 clearAutopilotHistory`**~~ → 已修，见 §171。
- ~~**P1 `HUDStore.swift:3845/3864 deletePendingSendForLog`**~~ → 已修，见 §171。
- （已修项的历史描述留在下面，便于回看后果链）
- **P0-历史 `AutopilotService.swift:1771` 队列孪干的收口失败**：`resolveVerifiedSend` 抛错时只 print +
  `flipped = 0`，事务回滚 → `pending_sends` 行仍存活；`start()`（:241 + :256 `loadPendingSends`）
  会把它整条载回，闸门读 `hasPendingSend` 得 true → **重启后同一条 AI 回复无人点击就再发一遍**。
  `unresolvedSentLogWrites` 是内存态且按 logId 索引，这条路两个条件都不满足。
  需要的是「已投递但收口失败」的 queueId **持久化**（一列或一张小表），`start()` 载入时命中即挂
  `manualOnlyReason`。这条是本轮 §161 那条 P0 的另一半，优先级最高。
- **P0 `AutopilotService.swift:1553`「取消本条」的持久侧**：`try? deletePendingSend` +
  `try? markAutopilotLogSkipped` 双双吞掉；:1545-1548 的注释自己写着「DB twin 才是发送键前
  最后一次校验的持久记录」。删除失败即取消在持久层空转，界面显示「已取消」，重启或发送检查
  仍按该行放行。（V4 修的是另一条路径上的同一个形状，这条还没走。）
- **P1 `HUDStore.swift:4096 clearAutopilotHistory`**：安全联锁用 `currentAutopilotSession()`
  （`queryOne`）→ 读失败判「无活动会话」→ 4103/4105 **全表** `DELETE FROM autopilot_log` +
  `autopilot_pending_sends`，而托管其实还在跑；页面随后显示成功。联锁要改 `queryOneThrowing` 并抛错。
- **P1 `HUDStore.swift:3845/3864 deletePendingSendForLog`**：依赖 `autopilotLogQueueId`
  （`queryOne`），读失败 → 掉进 legacy 文本匹配分支，`DELETE … WHERE chat_username=? AND
  reply_text=?` 会删掉**另一条**同文本草稿，而真正该删的那条继续可发。读失败时不许降级到文本匹配。
- **P1 `ConversationMemoryUpdater.swift:105/113`**：`loadConversationMemory`（`queryOne`）读失败
  → 既绕过频控又让 `oldSummary` 变空 → prompt 写「（首次生成）」→ `upsertConversationMemory`
  对**全部列** `DO UPDATE SET`：90 天滚动摘要被一次瞬时 BUSY 覆成首轮摘要。
- **P1 `ChatMonitor.swift:3441`**：改草稿后 `autopilotLogQueueId` 读失败 → 跳过
  `updatePendingSendReply` → 队列孪干仍存旧文本（正是 :3932 注释里「pre-edit text stays sendable」
  的后果），而用户看到「已保存」。
- **P1 `ProactiveAlertEngine.swift:489`**：预占 120 秒过期与 completion 抢跑 —— 晚于 120 秒到达的
  **成功**回执被 `removeValue` 的 guard 直接 return，既不记配额也不记去重 → 同一标识符每 ~120 秒
  重投一次。过期只该用于释放槽位，回执仍要按 identifier 记一次账。
  （和 §166 定价的「失败不记账」同一形状，但这条是成功路径，之前没定价到。）
- **P1 `ChatMonitor+Classification.swift:72` 的 `.retry` 无退役路径**：`deferClassificationMessage`
  的 attempts 无上限（`HUDStore+DiscussionQueue.swift:135` 的兄弟队列有 `attempts>=?` 死信），
  永久读不到就是永远排队；不算无痕（`classificationQueueCount()` 在
  SupportDiagnosticsView:94 / SyncSettingsView:400 可见），但也不是「重试过就放弃」。
- **P2 两处**：同一条消息一轮里被 defer 两次（`attempts += 2`，退避比设计快一倍）；
  `SchemaMigrator.swift:30` 又把「表不存在」（合法）和「索引建失败」塌进同一个 Bool，
  前者会让 `user_version` 永不落地、每次启动重跑刷 NSLog —— 正是本轮要消灭的形状，
  我自己刚写的那条守卫带了它。
- **P2 死字段**：`AutopilotConfig.vipAutoNotify` / `vipBusyTemplate`（Models.swift:2140 起）
  全仓零消费者，唯一相关代码就是 §165 删掉的 `pushVIPNotification`；注释还在承诺「VIP 有 busy
  自动通知」，§164 还把 `vipAutoNotify` 列为要保命的护栏。要么删字段，要么把话说清楚。

## §171 两条 P0 与两条 P1 收口：队列轴的「终态写回」与两处安全联锁

- **队列轴的统一收口（修掉 §170 那两条 P0）**：新增 `unresolvedQueueWrites: [UUID:
  UnresolvedQueueWrite]`（`.delivered(chatUsername:replyText:)` / `.cancelled(...)`），
  两个入口都记账：验证投递之后 `resolveVerifiedSend` 抛错（原来只 print + `flipped = 0`，
  于是那行还留在 `autopilot_pending_sends` 里，`start()` 载回后**无人点击也会再发一遍**），
  以及 `cancelPendingSend` 的 `deletePendingSend` / `markAutopilotLogSkipped`
  （原来双双 `try?`：界面印「已取消」，盘上那行仍可发）。闸门多一个入参
  `queueHeldHere`，`retryUnresolvedQueueWrites()` 只在写真正落库后才放掉这条。
  诚实的边界：这是**会话内**的拦截；「写失败 + 进程立刻崩 + 重启」这一段要的是持久化
  的 outbox intent 行（发信前落一条、收口时删），属于设计改动，见本节末。
  判据：`testCancelWithFailedQueueDeleteIsHeldThenReleasedWhenTheWriteLands` —— 用
  `BEFORE DELETE … RAISE(ABORT)` 只让删除失败（读一切正常，闸门唯一的依据就是本地集合），
  并且**先验一次仍然失败的重试**（第一版只验成功那次，「失败也放掉」的变异是活的）。
  发送尾与取消两处接线走源码判据。变异 O1/O2/O3/O4 全红。
- **`clearAutopilotHistory` 的安全联锁**：`currentAutopilotSession()` 的 nil 同时代表
  「没有活动会话」和「读不到」，后者让全表 `DELETE` 在托管仍活着时跑掉。新增
  `currentAutopilotSessionThrowing()`，联锁改用它。判据：谓词 + 函数体接线（两条都钉）。O5 红。
- **`deletePendingSendForLog` 不许在读不到孪干时降级去文本匹配**：那样删掉的是
  「另一条同文本、无人认领」的草稿，而真正该删的那条继续可发。改为 `.unreadable` 直接 throw。
  判据：`testQueueIdReadSeparatesLegacyNullFromUnreadable`（NULL 是合法答案、读失败不是），
  外加一段"分支体内必须有 throw"的接线判据。O6 红。

## §172 判据自身这一轮又被攻出两次，都记下来

- **被另一个信号满足**（O6、以及 §169 的 N6）：断言的对象是「有没有抛错」，而环境里
  本来就有另一句会抛错 —— DROP 掉的表让 legacy 子查询自己失败，测试于是为错误的理由通过。
  这类只能靠「先让被测分支可观测」或退回源码判据，本轮两处都这么处理。
- **判据假红**（O6 第一版）：要求 `case .unreadable:` 的**下一行**就是 `throw`，被自己的
  注释挡掉了。改成「取到下一个 case 为止，这段里必须有 throw」。
  教训同 §167：一条源码判据要先在**未变异的代码**上跑绿，才能拿它当变异证据。

已修/未修的完整清单在 §170（划掉的是本轮收口的）。仍未处理里最高的一条是
**投递收口的跨重启窗口**：需要持久化的 outbox intent 行（发信前落、收口时删），
以及 `ConversationMemoryUpdater` 读失败把 90 天滚动摘要覆成「首次生成」那两条 P1。

## §173 §171 的修法自己留了一个 P0：拦截记在两根 id 轴上，闸门只读一根

复检刚提交那一路攻出来的，回源码成立。`AutopilotService` 有两条互不相通的行标识轴：
队列行按 `queueId(UUID)` 记，审计行按 `logId(Int64)` 记，而**唯一的交叉出口** ——
`approvePending`（人工「确认发送」）的 gate 传的是 `queueId: nil, logId: logId`
（`AutopilotService.swift:789`）。于是 §171 新加的 `unresolvedQueueWrites` 对那条路完全不可见：

- 取消侧：`cancelPendingSend` 的 `markAutopilotLogSkipped` 抛错 → 日志行**仍是 'pending'** →
  「待确认回复」上那颗 确认发送 还活着 → 失败只记在队列轴上 → 用户点一下，刚取消的回复发给真人。
- 投递侧：人工「立即发送」成功后 `resolveVerifiedSend` 抛错 → 同理，同一条文本可再发一遍。

这正是 §168 我自己定价为 P0 的那个形状，只是换了个入口 —— 修得不彻底，而不是新问题的类型。

修法：两根轴同时记。`holdTwinLog(for:kind:)` 用新的
`HUDStore.autopilotLogIdForQueueId(queueId:)` 反查孪干日志行，`.delivered` 进
`unresolvedSentLogWrites`、`.cancelled` 进 `unresolvedSkippedLogWrites`（两个重试分支各自
本来就会做正确的写回）。第三条漏点同轮补上：`approvePending` 成功后
`deletePendingSendForLog` 抛错时也要记队列轴，否则「已发送的草稿仍留在 autopilot_pending_sends 里」
这一半仍然没人拦。顺手改掉一句假话注释（store 里那句「调用方那条日志仍被本地集合拦着」
在三个 `try?` 调用点上并不成立）。

判据：`testFailedCancelWriteHoldsBothIdAxes` —— 用 `BEFORE UPDATE ON autopilot_log
RAISE(ABORT)` 只让日志写失败（队列 DELETE 照常），先确认「日志行仍是 pending、那颗按钮还活着」，
再分别按两根轴问闸门。变异 P1（不跨轴记账）、P2（把 cancelled 记到 sent 集合）、
P3（approve 路径又不记队列轴）全红；P3 第一版是活的，因为接线判据只数了 `= hold` 那两处 ——
补了第三条字面句才红。

## §174 一条谓词只喂了一个消费者：`parseSysMsg` 少两道闸，而闸本来就该在解析器里

`parseAppMsg` 有 `<!doctype`/`<!entity` 拒绝 + 1MB 长度上限（第 96–101 行，历史上是
修 XXE/放大时加的），`parseSysMsg` 一道都没有 —— 而两者构造的是同一个 `SimpleXMLParser`。
`renderMessage` 有两个 XML 入口（:230 appmsg、:236 sysmsg），所以 baseType 10000 那条
一直是唯一能带着未检查文本进解析器的消息面。

修法没有停在「给 sysmsg 补两行」：`hasEntityRisk(_:)` / `isTooLarge(_:)` 提到
`SimpleXMLParser` 上，`parse()` 自己先核对再交给 `XMLParser`，两个调用方问同样两个问题。
第三个人将来加 XML 分支时，忘记问也会被内层拦下 —— 这就是这一整轮的形状：
**一条判断放在调用方，等于只保护了记得问的那一个。**

sysmsg 侧的闸放在 `type=` 正则**之前**：内层 `parse()` 拒绝并不够，正则和 `lowercased()`
已经在那 1MB 上跑过一遍了。判据用 `sysKind` 是否为空来区分两种顺序 —— `sysKind` 只有那条
正则写得进，所以它是「有没有跑过正则」的唯一可观测证据。

判据：`testSysmsgEntityDocumentIsNotExpanded`、`testSysmsgOversizedDocumentIsRejectedBeforeTheRegexPass`、
`testSimpleXMLParserRefusesDangerousInputOnItsOwn`（直接构造解析器，唯一能把内层闸和外层闸
分开的办法）、以及 `testSysmsgStillParsesAfterTheGuards` —— 没有这条对照组，前三条只是在证明
「什么都不解析」。变异 Q1（去掉外层）红在正则顺序那条，Q2（去掉 `parse()` 内层）红在直接构造那条。
实体的可达性要说清楚：对端要能往 XML 结构里注入标记（而不是元素文本）才谈得上放大，
本轮没能从一条普通消息构造出这种注入，所以**长度那一半是实的，实体那一半按 P1 记**。

## §175 复检三路攻出来的三条：导出的 `try?` chmod、静音不管无人值守、停在生成中途的一批

派出去的三路只查本轮之前没查过的轴（并发/检查-生效间隙、界面承诺 vs 代码、输入合成）。
三条按源码复核成立：

**1）`makeExportPrivate` 是 `try?` + 丢弃返回值，两处导出照样 `return url`。**
设置页写着「文件权限设为只有本账户可读」，日报页收到绿色「已导出」。`chmod` 失败时文件是
0644，落在 iCloud 默认同步的桌面上，里面是真实联系人姓名和消息正文。同文件里
`SecureFileManager.ensureFilePermissions` 早就有会抛的写法 —— 一处定义没被用的那句。
修法不是「把 `try?` 换成 `do/catch`」：`setAttributes` 在不支持 POSIX 权限的卷上会**成功**
而什么都不做，所以判据是**读回来核对** `posixPermissions == 0o600`；核对不过就删掉文件并
报失败（留下文件是这道承诺存在的唯一理由）。变异 R1（读回来但不核对）红。

**2）「静音此对话」只压住收件箱行和横幅，压不住无人值守回复。**
`ScanEngine` 里 `silencedAt` 被用了三次（:219、:252 隐藏行；:679 压横幅），而**两处**交给
回复管线的投递（:727 白名单路径、:978 联系人路径）一次都没查它。用户静音一个人，恰好移除了
唯一能看到「他来了消息」的地方，而 AI 继续给对方起草、开着自动发送时继续发出去。
两处都补，第二处连 `isSilenced` 这个变量都还没有。判据：
`testPermanentlySilencedPeerNeverReachesThatFeed` + 对照组 + 过期静音不得拦
（`testExpiredSilenceDoesNotBlockTheFeed` 那一半防的是把 silencedAt 一律当长期静音），
另一处投递用 `testEveryAutopilotFeedChecksTheMute` 的下限守住（投递点数 ≥ 静音判断数）。
变异 R3/R4/R5 分别红。

**3）`stop()` 落在模型调用中间，这一批仍然被记成上一次会话的决定。**
`handleNewMessages` 在第一个 await 前抓 `sid`，`processBatch` 的日志行用**参数** `sessionId`
盖章，而队列孪干行用的是**活的** `self.sessionId`（:1419）。停止之后孪干行写不进去，日志行
却带着已经结束的会话 id 落了库，内存里还多一条没有孪干的幽灵草稿。
代理把这条报成 P0（理由含「ack 会删掉持久 inbound 行」）—— 那半不成立：`stop()` 自己在
:364 就 `clearAutopilotInboundQueue()` 了。剩下的实害是**一张永远批不动的待确认卡 + 一条
幽灵草稿**，按 P1 记。修法沿用上一轮 §517621ed 的形态：await 之后、记账之前重读会话，
不一致就撤掉内存 enqueue 并且什么都不记。
同轮扫出第四处 `?? AutopilotConfig()`：`approvePending` 每会话上限、队列 tick 的
`processPendingQueue`/`evaluateProactiveOutreach`、生成的 `handleNewMessages` 都是**闸门读**，
读不到时用默认值就是**把闸门开宽**（敏感词退回内置表、上限退回 50）。新增
`HUDStore.autopilotConfigForSendGate()`（`.absent`→默认值安全，`.unreadable`→nil 不发），
三处改走它。变异 R6/R7 红。`AutopilotService:1520` 的 `sendKey` 读法仍用默认值，定价见 §177。

## §176 粘贴前那次 `Cmd+A` 一直在清掉用户没发完的话；而我第一版的闸门自己也不够

`performTextAction` 的顺序是 全选 → 粘贴 → 发送键，从来没有读过输入框。于是：

- 无人值守发送：用户在微信里打了一半的话被整段选中、被 AI 回复覆盖，然后**只有 AI 那句**发出去。
  他那半句在别的 app 里、没有草稿箱、不可恢复。
- 「只填不演」（`sendKey == nil`，人在微信窗口里站着）同样覆盖 —— 而这正是最不该动的模式。

修法分三层，因为**一次读不够**（这一半是代理回攻我第一版时找出来的）：
1. 全选前读一次；非空就不碰。读不到（`nil`）**放行** —— 把「看不见」当成「有人写了」会让
   微信某次改版之后自动发送永久失灵。空白按空处理。
2. 粘贴前再读一次。全选与粘贴之间隔着 `pause(0.05)` + 账号核验 + 三次 actor 跳转，人在这段
   里打字的话，`Cmd+A` 选中的是空，粘贴就变成**插入**，发送键会把「人的半句 + AI 的回复」
   一起发给真人。
3. 发送键前回读，要求框里恰好是我们粘进去的那段（`\r\n` 归一后再比，换行写法不该变成拒发理由）。
   这一层故意**不**调 `retractPastedDraft`：清空会把用户自己的字一起删掉。

两个新理由都写清楚「这条没发出去」。`isRetryableSendBusy` 只匹配「已有发送正在进行」，
所以 `.inputHasUnsentDraft` 落到 `humanRequired`：草稿进待确认卡并带上可行动的理由，
不会被反复重试打爆。

判据：`testInputBoxWithUnsentTextIsNeverSelectedAndOverwritten`（两层谓词各 5–6 个输入，
含 nil 失败打开、`\r\n` 等价、拼接必须拒）、`testDraftGateRunsBeforeTheFirstSelectAll`
（数到 2 次读框，第一次早于全选、第二次紧贴粘贴；发送键前回读落在粘贴之后、发送键之前）、
`testBothBoxRefusalsSayNothingWasSent`。变异 R8（去掉第二次读框）、R9（去掉发送键前回读）红。

未覆盖面，明写：
- 这三层闸门的**真实**行为只有连着微信才验得动 —— `axString(input, kAXValueAttribute)`
  在微信输入框上到底返回什么，本轮没有实测过（历次「最后一公里」都没做过 live 验证）。
  若某版微信不暴露 value，三层都会失败打开、回到今天的行为，不会更糟。
- `writePrivateExport` 里「核对不过就删文件」那条分支没有判据：在 APFS 上造不出
  「写成功但 chmod 失败」的条件（变异 R2 因此存活，属于已知缺口而非误报）。
- §175 第 3 条那个 stop 落在生成中途的竞态，只有位置判据，没有真竞态测试：
  `generator` 是具体类型 `AutoReplyGenerator`，测试里没法让那次 await 停住。

## §177 本轮已复核成立、定价未修的（含三条派单里剩下的 P1）

按「值不值得单独一轮」排，不是按严重度：

1. **`mayStillDeliver` 不重读 `autoSendEnabled`**（`AutopilotService:481-491`，消费点
   `WeChatLauncher:825/847`）。闸门读暂停/会话/队列行/日志行/三种 hold，就是没有那颗开关本身。
   发送一条要花 2–8 秒导航，其间用户关掉「自动发送」（`AutopilotSettingsView:114` 只写设置，
   不 pause 服务，`isPaused` 也不看它），两次闸门读都还是绿的，这一条照发。
   修法要给闸门区分「无人值守」和「人工点了确认」（后者本来就在关着自动发送时工作），
   不是一个参数能糊过去的，单独一轮。
2. **`lastSendFailureMessage` 当成返回值用的共享状态**（写在 :1480/:1484/:1521/:1543/:1575，
   读在 :1946）。B 因为 `isSending` 被弹回、原因是「已有发送正在进行」，它的续体排在 actor
   邮箱后面；A 随后失败并覆写这个变量，B 醒来把 A 的失败安到自己那条从没试过的草稿上 →
   `humanRequired` → 永久 `manualOnlyReason`。这条是**跨条串话**，判据现在只钉了源码顺序。
   修法是让 `executeSend` 把 reason 走返回通道。
3. **`stalePendingSendReason` 只在发送前一次读**（:1875 vs 闸门 :1902）。对端又追问了一句、
   或者用户已经自己在微信里回了 —— 自动化刚聚焦的那个窗口里人打的字，8 秒内被
   `postWillOpenWeChat` 的暂停抑制吃掉 —— 机器人随后用用户的口吻补一句过期回答。
   闸门从不重读消息表。
4. **`rejectPending` 删孪干行用 `try?`、失败不留 hold**（:957），与 §171 修过的
   `cancelPendingSend` 不对称：日志行翻成 skipped 成功、队列行还活着，而队列轴的闸门
   传的是 `logId: nil`，看不见那次 skip。同形缺陷的最后一个消费者。
5. [已修 §179] `ApprovalWorkspaceView:59` `?? AutopilotConfig()`：读不到时整页说「当前未开启自动发送，
   这条回复尚未发出」，而自动发送可能开着并在发。与 §164 同一形状，这次在**确认工作台**上。
6. [已修 §179] 同一页 `:178/:338` 与 `AutopilotTabView:42` 把「自动发送已关」时的队列标成**即将发送**，
   而 `executeSend` 在关着时一条都不会发（:1809）——用户会去点「立即发送」发自己没读过的草稿。
7. [已修 §179] `ApprovalWorkspaceView:299` 的 `n / 500` 计数没有任何一端执行 500。
8. `DailyReportTabView:128/336` 在周报页导出的是**日报**，拿不到时把原因说成桌面写入权限。
9. `NotificationSettingsView:50` / `AISettingsView:1031` 仍是 `?? Defaults()` 灌进去再整块写回，
   和 §164 修掉的托管页同形，只是那两处不驱动发送。
10. 心跳 tick 体没有在飞保护（`ChatMonitor:526-581`），`queue`/`stats`/`manuallyPaused`
    三次 hop 之后才 `publishAutopilotHeartbeat`，旧三元组可能后落地；badge 又被绝对值和
    增量两条路写。
11. `AutopilotService:1520` 的 `sendKey` 读法仍用默认值（读不到时可能按错组合键，最坏是
    把该发的留在框里，不会把不该发的发出去）。
12. `approvePending` 的陈旧校验只在 `if let createdAt` 里跑（参数默认 `nil`）：两个现存的
    调用点都传了值，所以这是陷阱不是活 bug —— 要把参数改成非可选。

## §178 回攻上一轮的修法：五处不成立，其中三处是我自己写的闸门

第三轮派单里专门有一路「只许攻击最近三个提交」。结论：**上一轮我修的东西有一半只修了一半**，
形状仍是同一类 —— 判断放在一处、消费者各有各的写法。

**1）静音只拦投递，不拦已经排队的那条。**（P0，我 §175 那句话说过头了）
`ScanEngine` 两处 feed 拦住了新消息进管线，但用户点「静音此对话」时，倒计时里的草稿
（`replyDelay` 5–300 秒）早就在 `pendingSendQueue` / `autopilot_pending_sends` 里了，
`executeSend` 从头到尾没看过 `silencedAt`。用户刚静音的那个人，随后照样收到一条回复。
修法把静音做成**撤回**：`mayStillDeliver` 多一条 `conversationMuted`，
`deliveryStillPermitted` 多收 `chatUsername`（两处生产调用点都必须传，判据里钉了
「不许再出现不传对话名的调用」）。同时把 `silencedAt > now` 这个判断收进
`ChatActionState.isPermanentlySilenced(nowEpoch:)` —— 收件箱行、横幅、两处投递、发送闸门
读的是同一个事实，此前是五种写法。判据：
`testMutingAConversationWithdrawsWhatIsAlreadyQueued`（对照组 + 永久静音 + 过期水印三态）、
`testMayStillDeliverTreatsMutedAsWithdrawn`、`testPermanentSilenceSentinelHasOneReader`。

**2）回攻自己那条闸门：全选前的读框，管不到粘贴那一刻。**（P1）
读框与 `Cmd+V` 之间隔着 `pause(0.05)`、账号核验和三次 actor 跳转。人在这一段打字，
`Cmd+A` 选中的是空，粘贴就变成**插入**，发送键会把「人的半句 + AI 的回复」一起发出去。
所以补了粘贴前第二次读框、发送键前「框里必须恰好是我们那段」，以及第五处：
`retractPastedDraft`（撤回也按 `Cmd+A`+Delete）此前**根本不读框**，会在同样的间隙里把用户
自己刚打的话和我们的那一段一起删掉 —— 现在只撤回「仍然只有我们那段」的框，否则留着不动。

**3）`stop()` 落在生成中途，我上一轮的丢弃只删内存、不删 DB。**（P0）
`processBatch` 写孪干行用的是**活着的** `self.sessionId`，所以 stop→start 之间醒来会把这条
草稿记到**新**会话名下：`start()` 再水化它、`processPendingQueue` 在 `scheduledSendTime`
已过的情况下把它发出去 —— 我上一轮的 `continue` 恰好制造了这个「界面说不发、DB 里排着发」。
现在丢弃分支同时 `deletePendingSend`，删不掉时按 §171 的形态挂 `unresolvedQueueWrites[.cancelled]`。
顺带修一句我自己写的假话注释：`stop()` 在 :365 就清了 inbound 队列，所以「下一轮会重试」
在这条路上不成立，批次是真没了（这是 stop 的既有语义，不是本次改动引入的）。

**4）`.absent` 被当成一个答案，其实是两个。**（P1）
`readSettingJSON` 把「解不开」折叠成 `.absent`，而 `autopilotConfigForSendGate()` 对
`.absent` 给默认值 —— 于是半写入的一行让敏感词表退回内置、每会话上限退回 50，正是这个
helper 声称要挡的那件事。新增 `SettingRead.corrupt`：写侧仍按 absent 处理（不然这一页永远
存不回去），闸门侧一律不发。设置页拿到的是另一句实话。
判据 `testCorruptStoredConfigRefusesTheSendGate` + 改了 `testSettingReadSeparatesAbsentFromUnreadable`
—— 后者原本钉住的就是那个错的折叠，这是本轮唯一一处「老测试在保护缺陷」的复写。

**5）静音清单由 20 条一圈的通知环驱动，取消静音的按钮会自己消失。**（P1，且被本轮改重）
`ContactsSettingsView` 读 `monitor.silencedItems ← handledItems ← recentNotifications`，
而 `chat_actions.silenced_at` 是永久水印。环一转过去，清单显示「没有静音的对话」，
数据库里那条还在，界面四处都不提醒、也不再自动回复。本轮把静音升级成撤回之后，
这个洞从「看不到」变成「这条对话死了且应用内回不来」。改成读 `loadChatActions()`，
取消走 `clearChatAction`，并把那句「不会出现在收件箱中」补全成它实际做的三件事。

**代理报的两条 P0 判阴**：① 三处读框「读不到就失败打开」是刻意选择，理由写在谓词注释里
—— 反过来会让微信某次 AX 改版后自动发送永久失灵；本轮补的是**可观测性**（读不到时写一行
日志，生产里能被证伪）。② 「静音清单不可达」的另一半（用户改昵称后 `searchNames` 不匹配）
与本轮无关，未采纳。

变异 S1–S7 全部先确认改到了才判红（S1 静音当撤回、S2 corrupt 又当 absent、S3 丢弃不删 DB、
S4 never-ran 当刚跑过、S5 锚点回墙上时钟、S6 撤回不读框、S7 静音判据反向）。

## §179 心跳自己的节拍还在墙上时钟上；确认工作台的三句话有一件不存在

**心跳三处锚点是本轮时钟轴漏掉的最后一块。** `lastSafetyScanAt`、`lastProactiveOutreachAt`、
`lastAutomationActivationAt` 都是 `Date()` 写、`Date()` 比 —— 而它们是「这个进程看着发生的两件事
之间过了多久」，按仓库自己定的规则属于单调轴。反向修正（时区变更唤醒后 macOS 正在做的事）会让
差值变负，于是兜底扫描和**全部**主动提醒（VIP 升档／承诺到期／多条未回）停止触发，时长等于
回拨量，而岛上的外观一切正常；`lastAutomationActivationAt` 反方向失效 —— 8 秒窗口一直开着，
把**用户自己**切回微信这次激活也吞掉，正是那条注释自己警告的「用户在微信里打字时托管还在发」。
新增 `ChatMonitor.windowElapsed(since:now:interval:)`（`nil` = 从没跑过 = 到点）+ 可注入的
`monotonicNow`。判据：纯谓据三条 + 三条字面锚点不许再出现 `= Date()` / `timeIntervalSince(...)`。

**确认工作台的「即将发送」和「/500」。** 三处：
① `autoSendOn ? "需人工确认" : "即将发送"` —— 自动发送**关着**的时候标成「即将发送」，
而 `executeSend` 在关着时一条都不会发（:1809），用户于是会去点「立即发送」发自己没读过的草稿；
② 同一页在设置读不到时说「当前未开启自动发送，这条回复尚未发出」—— 把一次 SQLITE_BUSY
说成一条安全保证；③ `n / 500` 计数，全仓没有任何一端执行 500。
现在这三句都改到与代码一致：`autoSendState: Bool?`（读不到就说读不到）、关着时叫「等你确认」、
超过建议长度改成明说的红字「仍会原样发出」。`AutopilotTabView:42` 同一处误标同修。

**删掉一处从未被调用、且注释撒谎的出网原语。** `LinkExtractor.fetchWebContent(url:)` 拿对端
消息里的 `<url>` 直接 `URLSession` 请求：无 scheme 白名单、无响应体上限，注释说「由 ChatMonitor
另行调用」—— 全仓零调用点。死代码里留一条「按对方给的地址发请求」不值得，删。

判阴一条：`isAtMe` 把纯文本 `@所有人`/`@all` 也算「提到我」。看着像放大入口，但
`MessageHelpers.swift:140-142` 下面紧跟着的注释写明这是有意的分工（「should this interrupt me?」
与「是否只 @ 了全组」是两个问题），且群聊一律人工确认（`AutopilotService:2460`）—— 不改。

未修但已定性的常驻问题（§177 之外新增）：~~`analysis_cache` 只按整键惰性删~~（§182 已修）、
`autopilot_log` 无任何保留策略、~~所有 housekeeping 只在开库时跑一次~~（§182 已修）、
心跳 tick 体无在飞保护、timer 装在 `.default` 模式（菜单跟踪期间不响）。

---

## §180 静音哨兵的判别线在两侧不一致：未来 30 秒的水印 = 永久静音

`chat_actions.silencedAt` 这一列同时装两个意思：「隐藏到这一刻」（`dismissInboxItem` 写，
值 = 最新一条消息自己的 `createTime`）和「永久静音」（写 `now + 10 年`）。于是
「这条对话算不算被静音」必须有一个判别线，而仓库里同时存在两条：

- 收件箱水合（`ChatMonitor:2617`）：`silencedAt > now + 1 年`；
- 两处投递闸门 + 发送闸门 + 静音清单：`silencedAt > now`。

松的那条是错的。`dismissInboxItem` 存的是**对端消息的时间戳**，对方时钟快几秒（本周已经
为「未来时间戳把对话永久静音」修过一次，§128 同族）就得到 `silencedAt = now + 十几秒`：
收件箱认为它没被静音（照常显示新消息），托管链却按永久静音处理 —— 一句「隐藏此对话」
把这条对话从自动回复里永久摘掉，且它会出现在「已静音的对话」清单里，看上去像是用户自己
关的。量级：任何一条时间戳跑在前面的消息都能触发，不需要恶意输入。

修法是把判别线收回一处：`ChatActionState.permanentSilenceBufferSeconds = 365 * 86400`，
四个消费点（`ScanEngine:679`、`ScanEngine:978`、`AutopilotService.conversationIsMuted`、
`ChatMonitor` 水合）全部只读 `isPermanentlySilenced(nowEpoch:)`。

**一条被上一轮自己写坏的判据**：`testEveryAutopilotFeedChecksTheMute` 数的是
`silencedAt ?? 0) > nowEpoch` 这个**字面串**在 `ScanEngine.swift` 里出现的次数 ≥
投递次数。它给的是文本分，不是位置分：守卫写 dead branch、写在 append 之后，都算数；
而把那一处迁到共用哨兵上，它会立刻变红 —— 也就是说这条判据在结构上钉住了它自己声称要
消灭的重复。本轮改成数 `isPermanentlySilenced(nowEpoch: nowEpoch)` 的出现次数，并加两条
「不许再出现内联拼写」的红线。变异验证：把第二处投递的守卫换成 `false`，该条判据红
（`/tmp` 记录，1 failure）。

诚实记录一处**下限判据独木**：第二处投递（按联系人补齐那条）只有这条文本下限在守，没有
行为判据 —— 本轮的夹具（`SyntheticShardedScanFixture` → `performScan`）只能驱动白名单那条
投递。上一轮把这件事写成「行为测试覆盖 :727，下限覆盖 :978」，是对的但不够：下限判据
被绕过的方式比行为判据多。补第二套夹具是本轮之外的事。

## §181 撤回用错了失败方向：读不到输入框就全选删除

§178 那三个覆盖闸门刻意**失败打开**（`kAXValueAttribute` 读不到时放行）：为了看不见
就拒绝发送，等于微信一升级自动回复就永久失效。但同一条谓词被 `retractPastedDraft`
拿去当"能不能删"的依据，而撤回是**已经放弃发送之后**的动作 —— 它唯一的代价是草稿留在
框里（函数自己的注释就这么写）。于是 nil → true → `Cmd+A` + Delete：
把用户在这条粘贴之后自己打的字连着我们的删掉，正是 §178 立起来要防的那次丢失。

修法不是把那条谓词翻过来（那会连带改掉发送侧的刻意选择），而是给破坏性调用配一个
失败关闭的姊妹判据 `boxIsKnownToHoldOnlyTheReply`（nil → false，空盒仍为 true），
并让判据扫**全部** `postCmdKey(kVK_ANSI_A)`：现仓三处 —— 覆盖前、撤回前、微信搜索框
（第三处清的是查询词不是人的草稿，判阴保留）。三处的 320 字符窗口太窄会误报，
改成 700 并让「总数 == 3」成为真正的牙。

## §182 保留窗口只活在启动迁移里 = 24/7 进程从不执行

`pruneAIAudit(olderThanDays: 14)` 全仓只有一个调用点，在 `HUDStore.open()` 的迁移段里；
`gcDailyReportState(45)` 只在全仓一次性的迁移里；`conversation_memory` 的 90 天清理同。
对这个**永远不重启**的浮窗进程，"启动时清一次"就是"从不清"。

最难看的还是 `analysis_cache`：它的删除只发生在 `loadAnalysisCache` 命中同一个
`(chat, type, input_hash)` 且发现已过期时，而那个哈希覆盖的是**消息窗口** —— 每来一条新消息
就换一个键，过期行几乎永远不会被再访问。每一行装的是 AI 结果全文。这就是历史文档里
那句「14 天 / 72 小时」的实际含义。

修法：`HUDStore.runRetentionSweep()`（四处清理，保留「expires_at > 0」这一半条件，免得把
别的写入方的"永不过期"行顺手删光 → 那会把每次刷新变成一次真实 AI 请求），
由心跳按 `retentionSweepInterval = 3600` 触发（用的是 §176 那条 `windowElapsed`，
锚点 `nil` 表示"从没跑过"，所以第一次 tick 就扫）。启动那一次保留（升级后首启要立刻收口）。

行为判据两条，都带正对照：审计行「清理前 2 条 / 清理后 1 条」；缓存行用
`loadAnalysisCache(now:)` 的**过去时刻**读取来区分「过期且已被扫掉」和「过期但还躺在库里」——
直接读默认 `now` 的话，惰性删除也会返回 nil，测试会在没有清理的情况下变绿。
`autopilot_log` / `vip_traces` / `commitment_scans` 仍无窗口：它们从来没有声明过保留期，
挑一个数字是「面板能往回说多久」的产品决定，本轮不替 owner 挑（§141 同一处置纪律）。

## §183 静音一条对话，会把草稿永久转人工，理由还是「请先检查微信」

§179 给「中途暂停」开过的药，在静音这条轴上原样复发：闸门在按下发送键之前拒绝
（`mayStillDeliver` → `conversationMuted`），`executeSend` 却把它当成一次**发送失败**
记账 —— `sendFailureDisposition` 看到 `paused=false, sessionOpen=true, rowStillQueued=true`
（发送前刚 upsert 过）⇒ `.humanRequired` ⇒ `manualOnlyReason = "…请先检查微信，再手动处理"`。
而 `isEligibleForAutomaticSend` 要求 `manualOnlyReason == nil`：**取消静音不会把它换回来**，
回执还在怪一个什么都没坏掉的微信。

修法是给那条唯一决定账目的纯函数补上它缺的那个输入：`conversationMuted`，静音时
`.requeueUnchanged("这个对话已静音，这条没有发出，仍留在队列里。")`（留在队列里是安全的：
静音期间闸门本来就拦着，取消静音才恢复）。读法走 `conversationIsMuted(_:)`，与投递闸门
同一个谓词 —— 记账和闸门不许各自理解一次「静音」。真失败的正对照留在判据里
（同一条 reason + 未静音 ⇒ 仍要 `.humanRequired`），否则"永远不 stamp"也能过。

## §184 幽灵草稿的「挂住」以内存副本还在为条件

§179 那段丢弃分支写成 `catch { if let ghost { unresolvedQueueWrites[uuid] = .cancelled(...) } }`，
而 `ghost` 是从 `pendingSendQueue`（内存）里查的。问题是 `stop()` 清的正是这份内存 ——
也即这条分支存在的理由。内存没留 + DB 删失败 ⇒ 什么都不挂，那条草稿记在**新**会话下
等 `start()` 水化后自己发出去，与 §179 主判据想拦的是同一件事。
改成无条件：`ghost?.chatUsername ?? entry.chatUsername`、`ghost?.replyText ?? entry.generatedReply`
（批次结果带着同一对话同一段文本入队时的值）。

## §185 「立即发送」四条路仍在用默认值兜底（同一谓词的收尾）

`ChatMonitor.loadAutopilotConfig()` 还是 `getSettingJSON(...) ?? AutopilotConfig()`，
而它喂的正是真键盘：`AutopilotTabView:778/848`、`ApprovalWorkspaceView:402`、
`ConversationDetailView:334` → `sendNow`/`editAndSend` → `executeSend(config:)` 读
`config.sensitiveKeywords` 与 `maxSendsPerSession`。半写坏的 `settings.autopilot` 行 ⇒
人工点「立即发送」时用的是内置敏感词表和内置上限 —— 就是上一提交在三个自动闸门上
关掉的那个放宽，区别只在这次有个人站在按钮前。

改：`loadAutopilotConfig() -> AutopilotConfig?` 走同一个诚实读法，四处各自
`guard let`，拒绝话术集中到 `ChatMonitor.unreadableConfigNotice`（同一个动作不许在两个
按钮上说成两句话）。判据数的是**四个** `guard let config = monitor.loadAutopilotConfig()`
加一条「不许再出现 `monitor.loadAutopilotConfig().` 直接当非可选用」。同一轮把
`AIReplySuggester` 的敏感词读法也并进来：它的安全方向与发送闸门**相反**（这一页读不到
配置仍可以显示草稿），所以内置词表照用，但"源文本有没有敏感信号"在读不到时按**有**算，
只剩保守转手能站住。为此把过滤决策抽成 `AIReplySuggester.suggestions(from:input:storedConfig:)`
一个纯函数（配置由调用点交进来，函数内不许再摸 `store.`），四条真行为判据 + 一条接线判据。

仍未收口（同族，已定价）：`AutopilotService:1546` 的 `sendKey` 还在那条禁用兜底上读；
判阴一处 —— 静音清单的「取消」用 `clearChatAction` 删整行，会连带清掉这条对话的
隐藏水印与贪睡，但那两个值在**静音那一刻**就已经被哨兵覆盖了，取消只是不还原，
不是新损伤（P3，产品上"静音=重置这条对话的分诊状态"也讲得通）；`ContactsSettingsView:850`
丢了返回值，且那一页不渲染 `inboxActionError`（取消失败看起来像成功）—— 下一轮。


---

## §186 P0（我自己上一轮引入的）：静音/暂停的撤回，挡不住「键已经按下、只是没确认」

§183 把 `conversationMuted` 接进 `sendFailureDisposition` 之后，一路代理攻破本分支 diff 时
指出它排在了 `retryableReason` 前面，而它的输入里没有任何「是否已经敲过键」的事实。真实时序：
粘贴 + 发送键落地 → 微信 WCDB 刷盘慢，三轮 500 ms 轮询都没在库里看到那条出站消息
（`"发送后未在微信数据库中确认"`）→ **就在这 1.5 秒里**用户点了「静音此对话」或暂停 ⇒
新分支判成 `.requeueUnchanged("…仍留在队列里")`，草稿保留自动资格且 `scheduledSendTime` 不变 ⇒
用户在 10 分钟新鲜窗口内取消静音 ⇒ 下一拍把**对方已经收到过的同一段文本再发一遍**。
改之前这条路是 `.humanRequired` 挂 `manualOnlyReason`，那个标记正是防重复发送的东西。

反向验算时发现**暂停那一支（§179，上一轮我自己写的）同病**：`withheldByPause` 的三个输入
（`paused` / `sessionOpen` / `rowStillQueued`）在「键已落地 + 确认失败 + 期间暂停」下同样全部成立。
也就是说这两条撤回归档都在用「用户改主意了」这一个事实，去回答「有没有东西已经发出去」
—— 那是另一个事实，只有发送链路知道。

修法不是给某一支配一个特例，而是把那个缺失的事实提上来：`lastSendKeystrokesMayHaveLanded`
在 `serialSendWithRateLimit` 入口清零（限流拒绝根本没进过 `serialSend`，不清零会沿用上一条的结论）、
只在「`uiResult.succeeded` 而确认失败」处置真；`sendFailureDisposition` 拿它做**第一道**分岔，
两条撤回分支都要求它为 false。判据一条真值表覆盖三支（静音 + 已按键、暂停 + 已按键、
未按键 + 静音仍要撤回），两条变异各红 2 条，报出的正是 `requeueUnchanged` 的文案 ——
即重复发送那条路。

一般式：**凡是「把不可逆动作降级为可逆」的分支，必须显式持有「不可逆的那一步到底做了没有」**。
把它写成「某个可撤销状态 + 一次失败」是不够的，因为这两件事在时间上可以重叠。

## §187 静音闸门坐在导航之后：每分钟抢一次焦点去打开用户说「别理它」的会话

`mayStillDeliver` 的静音判断在 `WeChatLauncher.performTextAction:829` 才被问到，
而那之前已经 `NSRunningApplication.activate` 微信、点开搜索框、切到该会话。
被静音的排队草稿每 60 秒重演一次，`isStaleForAutomaticSend` 要 ~10 分钟才把它转人工 ⇒
每条草稿约 10 次「把我的微信前台切到那个我明确让助手不要碰的会话」。
§180 把静音这件事接进发送链时只接了「别按发送键」，没接「也别去那个会话」。
修：`executeSend` 在暂停短路之后加一条静音短路（草稿原样回队，什么都不记），
判据断言这一段的切片里 `serialSend` 一次都不许出现。

## §188 一片分片读不全，等于交出一页「看上去完整」的短页

`WeChatReader` 的分片循环对每个分片单独 `catch`，只在**全部**分片都失败时才抛错。
一片坏 + 一片好 ⇒ 调用方拿到一条短页、没有异常，`ScanEngine` 于是把水位/游标推进到
这页里最新的一条 —— 坏片那侧的行从此落在游标之后，**永久不再被抓**。
触发条件不是恶意输入：微信会把 `message_N.db` 合并进主库，而本进程手里的分片映射还认得旧文件
（合并循环自己就写着「同一行在两个分片里都可见」，正因如此才按内容键去重）。

三个静默跳过点都要记：①发现式探测里 `try? getDecryptedDB` / `acquireReadonly` 失败；
②发现式探测里 schema 读抛出；③全量探测的 `catch`（只在 `firstError == nil` 时才写缓存）。
新增 `partialReadChats` + `didReadPartially(chatUsername:)`，`clearPartialReadMarks()` 每轮扫描
开始时清（标记必须是「本轮事实」，否则一片修好后水位永远不动）。两条消费路径都扣上：
白名单那条把「每片都答到」并进 `backlogComplete`（两处水位写都挂在它下面），
按联系人那条照 `.unreadable` 的现例 `continue` 跳过整会话本轮。

写这轮判据时先红后绿了一次，值得记：我最初只在**取行**那个循环加了标记，三条行为判据全红 ——
因为损坏的分片在**发现阶段**就被 `try?` 静默跳过了，根本没进取行循环。
「修完不红」不是好事，「判据先红」才是。

判阴一条（实测，不是推算）：代理举报「外来 `create_time` 直接做数组下标」
（`hourly[cal.component(.hour, from: date)]`、`weekday[... - 1]`）会越界 trap。
真机测 `Calendar.current.component(...)`：`t = 1.7e9 / 1.7e12 / 1.7e18 / Int64.min / Int64.max / 0 / -1`
七种取值下 hour 恒在 0…23、weekday 恒在 1…7，无一越界 ⇒ 不改（CoreFoundation 把超远日期折回合法
分量，不是我以为的返回 0/NSNotFound）。
另有一条本轮未做：跨分片同秒同 `local_id` 的复合游标在 `prefix(limit)` 截断时可能少一条
（需要两片同秒同 localId 且页满的夹具才能证伪），先记为待测，不当已修。

## §189 设置页对「内容读不懂」的承诺是一条走不通的路；发送键是最后一处默认值兜底

`.corrupt` 的文案写「保存一次会重建默认设置」，而 `save()` 的第一行就是
`guard didLoad, !isHydrating, loadError == nil else { return }` —— 保存被自己刚设的
`loadError` 挡死，旁边唯一的按钮「重新读取设置」对 corrupt 恒等重复失败。
同时五处发送提示都叫用户「请先在设置里恢复托管配置」。即：库里有解恢复动作
（`updateAutopilotConfig` 把 `.corrupt` 映射为「从默认值重建」），界面上到不了。
补一个显式的「用默认设置覆盖并重载」（覆盖会丢弃现有托管设置，所以必须是命名按钮，
不能藏在保存背后），并把那句假承诺删掉。判据顺手抓到自己的一次误伤：它按源文本扫
「不许再出现那句承诺」，而我写在注释里的引用把它命中了 —— 注释里别原样引用被禁字符串。

同族收尾：`serialSend` 里 `sendKey` 还在 `getSettingJSON(...) ?? AutopilotConfig()` 上读，
而它就在真人按「确认发送」的那条路上 —— 猜错键要么把已确认的文本留在框里，要么提前发出去。
改为 `guard let sendConfig = store.autopilotConfigForSendGate()`，读不到就什么都不敲
（顺带让 §186 的那道新分岔成立：没敲键，才谈得上撤回）。判据把
`getSettingJSON("autopilot"` 在 `AutopilotService.swift` 里的出现次数钉成 0。

审批台另一处同族的谎：`approvePending` 因为静音返回 `false` 时，回执仍是
「发送结果待核对；请先到微信查看，避免重复发送」—— 一个字都没敲，却叫用户去核对
是否已经发出。改成先按「已静音的对话」清单判断并给出可操作的那句。

## §190 `AutopilotTabView` 整页零实例化：本轮两条守卫落在死页面上

`grep -rn "AutopilotTabView(" Sources/` 零命中（只有 `struct` 声明与一处测试注释）。
§179 的表头「即将发送→等你确认」、§185 的两处 `guard let config` 都在这一页；
真实的活页是 `ApprovalWorkspaceView`，代理逐条核过它的三处说法是自洽的
（读不到时「等你确认」为真，因为闸门会拒发）。⇒ 本轮没有留下用户可见的损伤，
但「四处手动发送」的计数里含 2 处死代码，这条要在删除那一轮一并修正。
删整页（含 `PendingSendRow`）按既定偏好该做，但它会同时移掉 3 条判据的落点，
不与本轮混做。

## §191 本轮判阴与定价

- **判阴**：`Calendar` 极端时间戳越界（实测，见 §188）；`autoSendState` 每秒 5–7 次读会
  「自己造出 `.unreadable`」—— `readSettingJSON` 的 `.unreadable` 只来自**抛错的查询**，
  不是锁竞争，所以那只是重复解码（P2 性能，未做）；取消静音删整行会带走隐藏水印与贪睡 ——
  那两个值在静音那一刻已被哨兵覆盖，取消只是「不还原」，不是新损伤（P3）。
- **定价未做**：`ApprovalWorkspaceView` 一遍 body 里 5 次 gate 读（P2）；新文案未走
  `companionFont` 缩放、超长红字未并进 `TextEditor` 的 a11y 值（P2）；
  `autopilot_log` / `vip_traces` / `commitment_scans` 仍无保留窗口（要 owner 挑数字）；
  `AutopilotTabView` 整页删除；`sendNow` 之外仍未收口的最后一处 `loadAutopilotConfig`
  消费点在 `ConversationDetailView` 之外没有了 —— 五处已全部走完。
- 六条新判据（P0 真值表 / 发送键兜底 / corrupt 恢复按钮 / 静音短路位置 /
  部分页扣水位 / 探测阶段标记）逐条变异，全部 CAUGHT；全量 2063 tests / 0 failures，
  release 零警告。


---

## §192 落库的审计副本比出网的请求更宽（同一件事的第二个边界）

出网那道网是 `AIService.maskDirectIdentifiers`：按位数与分组判号，能吞掉
`138 0013 8000`、全角 `１３８００１３８０００`、`+86…`、`6222 0202 1234 5678`、
`11010119900307457X`、邮箱。落库那道网是 `AIAuditPrivacy.persistableText` →
`Redactor.applyMasks`，也就是被上面那套「按分组」判定**替换掉的旧四条正则**。
结果：同一条消息，送到服务端的是遮蔽过的，写进 `~/.wechat-hud/hud.sqlite3`
的 `ai_audit.input_text` / `output_text`（以及 `ai_feedback.original_output`）的是
**没遮蔽的原件**，一放 14 天。而 `AIAuditPrivacy.swift` 文件头写着
「store a redacted snippet …, never the raw prompt/response」。

这不是"又一条漏遮蔽"，是一个已知的形状规则被补在了一处、没补在另一处：
仓库里 `AIOutboundPrivacyBoundaryTests` 已经把上面 7 种形状逐个钉住了 —— 钉的都是
`sentBody()`，也就是**只有出网那一侧**。判据补落库同一张表（8 种形状 +
`sha256:` 行不许被动 + 「无害文本要原样留下」的正对照），
`persistableText` 改成两层都过；`maskDirectIdentifiers` 因此要能被同步调用，
加 `nonisolated`（它不碰 actor 状态；不加就等于要求第二个边界去等一个 UI actor）。

定级说明：代理报 P0（"落库比出网宽"）。事实成立，但内容**不出机器**，
本机库的 PII 与 §175 导出的 0644 同族 ⇒ 我按 P1 收，修法照做。

## §193 「确认发送」的幂等凭据跨过一次 await 就失效

`approvePending` 全部防重发都押在 `store.autopilotLogPendingReply(id:)` 读到 'pending'，
而这一行**直到发送完成之后**才被 `resolveAutopilotLogSent` 结算。中间的每一次
`await`（`stalePendingSendReason`、`serialSendWithRateLimit`）都是一次 actor 重入口：
`serialSend` 的 `isSending` 在按键返回时就释放（早于结算）⇒ 第二次点击读到同样的
'pending'、`sessionSent` 也还没 +1，同一段文本再敲一次。
`isSending` 救不了它：它守的是"一次只敲一遍键"，不是"一条只发一次"。

修法是把声明和读取焊在同一个同步块里：`mayStartApproval(rowPending:alreadyInFlight:)`
一次决定两件事，紧随其后 `insert` + `defer remove`。判据两条：真值表（四格），
以及**「读到 'pending' 与占位之间不许出现 await」**的切片判据；
变异 = 中间塞一个 `await Task.yield()` ⇒ 红。

## §194 我上一轮新加的标记不取锁（自己引入的 P0 类）

`partialReadChats` 是 `Set<String>`：写侧在 `notePartialRead`（持 `lock`，线程随调用方），
读侧 `didReadPartially` / `clearPartialReadMarks` **不经任何锁**，而
`WeChatReaderActor` 只是门面 —— 全仓 30+ 处各自 `WeChatReaderActor(reader)`
（`ChatMonitor` 5 处、`AutopilotService` 4 处、`InsightStore` 等），actor 实例之间零互斥。
两个访问器于是直接和持锁写并发访问同一个非线程安全 `Set`：`Simultaneous accesses` trap
或缓冲踩踏，且这个进程永不重启。修：两个访问器都上 `lock`，存储从 `private(set)` 收成
`private`（留着 `private(set)` 就是给下一个读者留一条不经锁的读法）。
判据钉这三点；两条变异（不取锁 / 退回 `private(set)`）各红。

一般式：**新加的状态要按它所在类的既有并发约定接入** —— 这个类的约定是
「所有可变态都在 `lock` 后面」，我加的时候只按"谁调用我"想了 actor，没按"谁能读字段"想。

## §195 跨分片同秒游标漏行：判阴，但把成立的前提钉住

举报是 `messageQuerySuffix` 的 `afterCursor`（`(create_time > cT) OR (= cT AND local_id > cL)`）
按分片各自执行，而 `local_id` 只在单个 `message_N.db` 内有序 ⇒ 另一片里同秒、localId 更小的
真实消息被 SQL 挡在页外，内存规则再也看不见它。规则本身成立。判阴的两条证据：

1. 扫描链路根本不传 `afterCursor` —— `ScanEngine.swift` 里它只出现一次且是显式 `nil`；
   白名单那条是"取最新 N 条 + 内存按基线过滤"（`ScanEngine:510-515`）。
   非 nil 的调用点只有 `GroupMentionContextLoader` / 洞察侧，那些路径**没有持久游标**，
   少一条只是上下文窗口短一点。
2. 那条跨片同秒放行有真行为测试钉住（`ScanBacklogPagingTests`
   「same-second row in another shard must not be filtered by localId」，两分片同秒场景）。

因为结论依赖"扫描不把过滤下推进 SQL"这个前提，判据就钉前提本身（三条变异全红）：
`afterCursor` 在扫描里只许显式 nil、放行式两条投递路径各一份（数到 2）、
水位必须记下这一行来自哪一片（`lastShard: messages.first?.shardRelPath`）——
删掉其中任何一条 = 退回那个漏行场景。

## §196 本轮并发轴的其余结论

已查清并排除（代理与我对读一致）：`HUDStore` 无跨线程写（`perform` + `serialQueue`
重入键、`withDatabaseMutex`、`withCachedStatement` 全覆盖）；`processPendingQueue`
的重入摘除与 `globalSendTimestamps` 修剪无丢失。

定价未做（都有具体损伤，但要动的面比本轮剩余预算大）：
- `stop()` 无世代闸门：已 `await` 出去的 tick 醒来后仍会跑 `scan()` /
  `evaluateCommitmentDeadlines()`，把内存项塞回已被 stop 清掉的队列，下次 `start()`
  给它补 DB 孪干并发出 —— 用户已放弃的草稿复活（修法：tick 体与每个 await 之后比对
  `monitorGeneration`，仓库里 `discussionWorkerGeneration` 已有现成做法）。
- 记忆摘要是跨 await 的读-改-写，两个入口并发时后写覆盖新摘要并刷新 `last_updated`；
  §182 的保留扫描**新增**了一个"删掉中间行 ⇒ 摘要复活"的小概率面（修法：写回带
  `last_updated` 版本比较）。
- 心跳 timer 装在 `.default` 模式：菜单跟踪 / 拖窗期间整段冻结（同类 UI 定时器用 `.common`）。
- 本轮 §186/§187 之外，`approvePending` 的 UI 侧 `isSending` 仍是每个视图自己一份，
  跨面（审批台 / 岛内行）重复点击的窗口由 §193 的服务端声明兜住。


---

## §197 岛与洞察页的四处「界面替算法许做不到的愿」（非托管面第一轮）

前几轮的界面诚实性审计都集中在托管/审批页，这一轮把轴换到岛、横幅、日报与洞察总览。
四条都是同一形态：一个可选值或一个负数差值，落进了唯一的显示分支。

1. **负时间差读成「刚刚」**。`RelativeTimeFormatter` 只有一条 `diff < 60 ⇒ 「刚刚」`，
   而 macOS 在唤醒与 NTP 校正时会**往回拨**表（§176 就是这条轴把心跳提醒静音了几小时的）——
   回拨之前盖的水印在此之后就落在未来。落在收件箱行、横幅 arrival、以及
   `InboxView:261` 的「上次同步 …」上：用户读到「刚刚同步」，恰好在程序说不出多新鲜的时候。
   修：负差值单独一档「时间待定」，`suffix:` 那条叠字分支不许把「同步」叠在未知时钟上
   （「时间待定同步」不是一句话）。
2. **徽标只报被截断后的数**。雷达列表封顶 6 条，徽标印 `findings.count` ⇒
   「6 条提醒」被读成总数，而第 7 条信号已经被丢掉。修：`buildFindings(limit: .max)`
   之后在视图里切 6 条，徽标改「显示 6 · 共 9 条提醒」，封顶值收成 `visibleLimit` 一处。
3. **总览没算过却印 0**：`overview?.activeChats ?? 0` ⇒「0 个活跃对话 · 0 条消息」，
   用户把这当成"这周真的没东西"而关掉页面，而不是去点旁边那个能算出数的刷新。
   修：`InsightOverviewCounts.text(for:)` 两档，判据钉的就是「nil 与 0 必须是两个字符串」，
   同时保留"真零照实报"的正对照（不许把 0 也一起藏掉，那会造出一个永远说没算好的界面）。
4. **「本周推进了 N 件事」说的是一个时间点**，而承诺事项这份存储里根本没有完成时刻
   （只有来源消息时间与到期时间；`completedAt` 属于日报状态那一套）。
   三周前做完、周一被提到的事也算「本周推进」。改成能兑现的那句
   「本周相关的事里，已完成 N 件」。这条只有源文本判据（措辞回退会红），
   因为"有没有完成时刻"没法在单元测试里问。

三处判据的落点都要求先能测：2 与 3 的文案决定各抽成一个纯函数
（`InsightRadarBadge.text(shown:total:)` / `InsightOverviewCounts`），不然它们只能以
"视图里那行字符串在源码里出现过"的形式存在，而那种判据上次已经被证明锁不住行为。
本轮 5 条变异（去掉负数档 / 去掉叠字保护 / 徽标只报 shown / nil 塌成 0 / 文案回退）全部 CAUGHT。

同一轮举报里判阴或定价的：`InsightChatInsightDetailView` 的全零画像（未扫描的对话渲染成
「我说 0%」——同族，但那一页的入口本身就要求先扫描，留待下轮核它的可达性）；
`InboxView:135` 三个数加不拢（P2）；`CommitmentTabView:354` 批量撤销在写成功之前武装（P2，
失败路径不清）；`DailyReportTabView:208`「根据已同步的关注对话生成」不看 `syncStatus`（P2）；
`CompactInboxBar:155/159` 取不到 panel 时按假 notch 宽度排版（P2）；
`Models.swift:90 case stale` 无生产方赋值（一旦出现，展开面板四处 switch 全漏 → 记为
"下一轮要么补全要么删掉"的孤儿状态）。

---

# 第 3 轮判阴与修复（两路 diff 复攻 + 一路本地密钥审计）

## §198 P0 快照失败时，「别毁掉不可再生的数据」保护的是已经没了的东西

`ClipboardGuard.save()` 深拷贝剪贴板项；Finder/Preview/AirDrop/Office 的 promised
file 项 `item.data(forType:)` 全 nil，拷贝出来 `types` 为空 → `saved=[]` →
`items=nil`，而 `hadContent=true`。`restore()` 于是走那条「不擦除不可再生数据」的
早退分支。

量出来的事实：`WeChatLauncher` 在粘贴前就 `pasteboard.clearContents()`（:836），
所以走到那一行时用户原内容已经没了 —— 这个分支保护不了任何东西，它唯一的效果是把
AI 草稿（含对方聊天原文）永久留在 general pasteboard 上。剪贴板管理器随时可读，
Universal Clipboard 还会同步到同账号的其他设备。

修法不是「改成清空」就完事：清空会误伤「发送之后别人又复制了东西」这种情况，那时
那份数据是可恢复的、且不是我们的。所以 `restore` 多带一个 `pastedText`，只擦与
自己写过的那串完全相等的内容；认不出就不动。三处调用点（`openChat`、
`sendMessageDetailed`、`AutopilotService` 的发送）都传了自己写的那串。

判据：`ClipboardLeakOnFailedSnapshotTests` 5 条，注入私有 `NSPasteboard` 驱动真实
`restore`，含「别人的内容不许删」「原本为空要清空」「能还原时照常还原」三个正例。
变异：把新分支还原成早退 ⇒ 泄漏那条断言红。

残留（定价不做）：进程在 `clearContents` 与 `restore` 之间被 kill，草稿同样留在
剪贴板上。要覆盖它得在磁盘上放一个哨兵并记下那串文本 —— 那等于把聊天内容写进
临时文件，比它要修的泄漏更糟。窗口约 0.2 s/次发送。

## §199 P0 落键事实住在 actor 变量上，被下一次发送在 await 期间改写

§191 我加的 `lastSendKeystrokesMayHaveLanded` 自己就是本轮的 P0，机制在
`AutopilotService`：

- 复位在 `serialSendWithRateLimit` 入口（外层），置位在 `serialSend` 内层，
  而 `isSending` 的守卫在 `serialSend` 里 —— 于是外层入口的复位不受 `isSending` 保护；
- 读取在 `executeSend`，位于 `await serialSendWithRateLimit(...)` 之后。

A 落键后确认失败置 true，还要 `await ClipboardGuard.restore`；这期间用户点
「确认发送」进 B：B 复位标记、把 `lastSendFailureMessage` 也清成
「已有发送正在进行」，然后被 `isSending` 拒掉。A 回来读到 `false` + 一个属于 B 的
原因串 → 走 `withheldByPause`/`conversationMuted` 分支 →
`.requeueUnchanged("这条没有发出，仍留在队列里")` → 恢复后同一个人收到第二遍。

两个共享变量、一条竞态。修法不是把复位挪个位置：读取点本身在 await 之后，只要事实
存在 actor 上，挪到哪都还能被改写。改成 `SendAttempt(verified:failureMessage:
keystrokesLanded:)` 随调用返回，两个 actor 变量删除 —— 于是这个竞态在结构上不再
可表达。

判据：`testLandedKeystrokeFactTravelsWithTheCall` 断言两个变量名不再存在 + 读取点
用的是返回值 + 置位点贴着那条确认失败（400 字符窗口，不是「文件里有这个字符串」）。
`testRefusedAttemptNeverClaimsLandedKeystrokes` 是类型的正例：拒绝路径不可能带
landed=true。变异：把 actor 变量加回去 ⇒ 红。

## §190 补记 → §200 审批只查一根 id 轴，且「查不到孪生」被当成「没有孪生」

`approvePending` 的 gate 永远传 `queueId: nil`，所以 `mayStillDeliver` 里的
`queueHeldHere` 对这只手不可见；而它 fallback 用的 `holdTwinLog` 在
`autopilotLogIdForQueueId` 读不到时静默 return。两条凑齐 = 已落键的文本被第二次打出去。

修法：领取判据加第三个事实 `twinKnown`，用会报错的 `autopilotLogQueueIdRead` 而不是
fail-open 的 `autopilotLogQueueId`；`.unreadable` 当拒绝（人只损失一次重试），不当
「没有孪生」。同时把 `twinQueueId` 传进 gate，队列轴第一次对审批可见。

判据踩过的坑：`twinKnown` 加进判据后，把调用点改成 `twinKnown: true` 时纯函数测试
全绿 —— 变异活着。补的 `testApprovalGateSeesBothIdAxes` 不只要求调用点出现该实参，
还要求那三个入参里不许有字面量。

## §201 审批回执用「句子里有没有『失败』两个字」决定图标和颜色

`receipt.contains("失败")`。静音拒绝、`unreadableConfigNotice`、「草稿没有保存」、
「队列项已不存在」、「结果待核对」全都不含那个词 ⇒ 每一条都渲染成绿色对勾 +
checkmark.circle.fill。而 `Filter` 枚举里正好有 `case failed = "失败"`，这解释了
作者为什么会想到用子串。

改成 `Receipt(text:isFailure:)` 自带结论。同一轮把「确认发送」的四种拒绝从
`sendUncertain`（「请先到微信查看，避免重复发送」）里拆出来：`approvePending` 现在
返回 `SendAttempt`，UI 只在 `keystrokesLanded` 时才说「可能已发」，其余照实说
「这条没有发出」+ 原因。这与 §179 给另外四个手动发送点立的规矩是同一件事。

## §202 托管设置页的逃生舱，失败信息写在一个永远不显示的槽里

`rebuildFromDefaults()` 失败时写 `saveError`，而渲染是
`if let loadError { … } else if let saveError { … }` —— 这个按钮只在
`loadIsCorrupt`（即 `loadError` 非空）时出现，所以那句话永远出不来。五处发送侧拒绝
话术都把人指到这一页，而这一页唯一的出口表现为「点了没反应」。

改法不是复用 `saveError`：新增 `rebuildError`，渲染在 `loadIsCorrupt` 分支内，入口
先清（否则第二次成功之后旧失败还会带着「重试保存设置」浮出来）。判据从「函数里出现
过某个错误变量」升级成「该变量在 loadError 分支里被渲染」+「入口第一句是清它」。

顺带把按钮文案说全：`.corrupt` 的重建会把本页从不显示的 `sensitiveKeywords` /
`maxSendsPerSession` / `proactive*` 一并归零，那行损坏 JSON 是用户自己配置的最后一
份副本。二次确认对话框仍未做（判阴：只有读不懂的行才走这条路，代价是没有别的出口）。

## §203 「时间待定」补到第三份词汇表；到期列不再印 0

§196 只在岛和收件箱说了「时间待定」。`MessageInfo.formatRelative` 对负差值仍返回
「刚刚」，而它喂 4 处模型上下文（ChatAnalyzer / ContextWindowBuilder /
RecallAnalyzer / AutopilotService）—— 界面说「说不清」，prompt 里说「新鲜」。
字面量收进 `RelativeTimeFormatter.unknown`，两处各自实现的都引用它。

`DailyReportCommandCenterView.deadlineText` 同一族：逾期 30 秒读作
「0 分钟前到期」，未来 30 秒读作「0 分钟后」。改成「刚到期」/「即将到期」，
两侧正常档位留正例。顺带把它提成 `nonisolated static` + 注入 `now`（之前没法测）。

## §204 明文快照：目录要有主人，孤儿要有人收

`.temporary`（默认档）把整库解密明文放在 `$TMPDIR/wechat_hud_cache`，而
`purgeEphemeralCache()` 开头 `guard cacheStrategy == .memory` —— 默认档上它是个空
函数；`applicationWillTerminate` 也不清。被 kill 的运行既到不了 terminate 也到不了
`deinit`，macOS 只按「数天未访问」清 $TMPDIR。

关键约束是不能「启动就清空整个目录」：预览版与正式版共用同一个 $TMPDIR，那会删掉
另一个活实例正在读的文件。所以目录改成带 pid（跨进程本来就不共享句柄，各开各的
只读连接，共享没有收益），于是「上一次留下的」和「别人正在用的」第一次可区分：
启动扫孤儿（`kill(pid,0)` 且 ESRCH 才删），退出清自己的。旧的不带 pid 的目录名当作
无人认领直接收。

判据：`SnapshotReclaimTests` 5 条，`ownerIsAlive` 做成注入参数 —— 测试造不出一个
指定 pid 的死进程，而破坏性最大的正是那一支。含「活着的实例不许删」「别人的临时
目录不许碰」「自己的快照不许删（否则每次扫描重新解密）」。

## §205 迁移把 key 从行里搬走，没从文件里搬走

`migratePlaintextAPIKeysToKeychain` 改写 `settings.ai`，但库开着 WAL 且没有
`secure_delete`：被释放的页和 WAL 里旧 key 照旧 `strings` 可得。修法是迁移成功后
`wal_checkpoint(TRUNCATE)` + `VACUUM` 一次，且只在真搬走过秘密时付这个代价。

`PlaintextKeyReclaimTests` 是本轮少见的直接量到磁盘的行为测试：先断言迁移前
db+wal 字节里读得到 canary（夹具真的建立了泄漏），再断言迁移后读不到。canary 每次
随机，避免上一次运行的残留让「读不到」假绿。变异：删掉 `reclaimFreedPages()` ⇒ 红。

## §206 launcher.log：无界增长，和一行抄输入框内容的诊断

`log()` 没有尺寸帽；`dumpAX` 那行带 `val=<前 40 字符>` —— 而搜索失败时的 dump 里，
输入框在粘贴之后装的就是 AI 草稿。改成只记长度（role/identifier/title 才是找节点
需要的东西），日志按 `cap/2` 留尾部。

策略抽成 `logRewrite(existing:adding:cap:)` 纯函数：真实日志目录不能拿来测。写第一
版时是「减掉 cap/2」，被自己的测试问出破绽 —— 崩溃循环或把 cap 调小时，超出的倍数
会原样留在文件里；改成「留最后 cap/2」。

## §207 转人工的四处记账并成一处

`processPendingQueue` 的积压退役把草稿转成「需人工」却没做另外三处都做的记账。而
「对方不再回话」正是让草稿变陈旧的那个条件 —— 这条分支是每条闲置草稿必走的，于是
徽标和 log 孪生长期低于真实队列。四处收敛成 `countAsAwaitingHuman`。

行为测试直接驱动 `processPendingQueue`，断言的是**持久化后**的 `totalPending`
（徽标读的就是它）+ log 孪生翻成 pending。变异：删掉那一行调用 ⇒ 两条断言同时红。

## §208 内存态 hold 活不过它要防的那次重启（§199 同族的另一半）

三个 hold 集合都是内存态，而 `resume` 从 DB 重新水合队列时不读它们。修法是把同一个
事实写进行上的 `manual_only_reason`：这一行不再自动发射，而看到它的人被告知为什么
不能直接确认。

自己引入的回归，被已有测试抓到：第一版在 `!deleteLanded || !logLanded` 两支都写行，
于是「队列删成功、审计行写失败」那条路上 `upsertPendingSend` 把用户已取消的草稿又
造了回来。`testFailedCancelWriteHoldsBothIdAxes` 当场变红。修成只在 `!deleteLanded`
时落盘，并把前置条件写进函数注释（「行还在盘上」不是显然的）。

`ON CONFLICT DO UPDATE` 不触发 BEFORE DELETE 触发器 —— 这点先量过再依赖，否则这条
测试会因为夹具而不是因为代码通过。

## §209 本轮判阴与定价

- `persistRawText`：文件头两句都不成立（不是 debug 专属；保留期是普通 14 天不是
  0 天）。**改说法不改行为**：这个 app 一辈子以 release 运行，只留 debug 后门等于
  没有后门。要改的是「打开它意味着把未脱敏 prompt 落盘两周」这句得写在脸上。
- `InsightRadar.buildFindings` 默认 `limit=6` 与 `InsightRadarBadge.visibleLimit=6`
  是两个必须相等的 6，其中一个没人钉。合并成服务侧一个常量。第 7 条起无处可看是产品
  判断（徽标已如实说「显示 6 · 共 9」），不做展开。
- `partialReadChats` 的三处不自洽（递归重试不清自己那轮、驱逐被随后的写回撤销、
  旁路读会把不相干分片的失败记到被扫页头上）：量下来都只造成一轮延迟，不丢数据。
  正确形态是随页返回 `partial: Bool`，改动面覆盖 4 个读取路径 + 2 条喂入，单独一轮做。
- codex refresh token 明文落 `~/.wechat-hud/codex-tokens.json`（0600）。API key 已经
  走 Keychain 且库里只留 `keychainItemRef`，这个不对称是真的；但 `CodexTokenStore`
  的轮换/单例去重逻辑与文件缓存耦合较深，且需要一次真账号验证，未在本轮动。
- `stop()` 缺代际门（僵尸草稿）、心跳 `Timer` 在 `.default` 模式、
  `autopilot_log`/`vip_traces`/`commitment_scans` 的保留阈值需要一个负责人给的数：
  均维持前轮定价。

## §210 两处新文案的回拍与量宽（脚本化截图确实到了洞察页）

`--preview-tab=insight --preview-insight-overview --preview-expand-modules` 这一路
启动确实落在洞察总览页（截图里右侧就是「今天聊了什么 / 需要留意 / 关系雷达」），
所以 §197 那两条新句子有可拍的现场。量宽（`NSString.size(withAttributes:)`，
字号取渲染用的那两档）：

| 槽位 | 原来 | 新增/最长态 | 增量 |
| --- | --- | --- | --- |
| 总览计数行 | `2 个活跃对话 · 138 条消息` 131.3pt | `统计还没算好 · 点右侧刷新生成` 153.8pt | +22.5pt |
| 雷达徽标（含 7pt 左右内边距） | `6 条提醒` 53.3pt | `显示 6 · 共 9 条提醒` 106.0pt | +52.7pt |

截图里这两格都还有可见余量（徽标右侧到卡片边缘、计数行下方整行只有它自己），
所以**在演示数据这一态下没有裁切**。两点如实说清楚：

1. 预览夹具只产 6 条 finding，所以 `total > shown` 那一支（+52.7pt 的那个）**从来没被
   渲染过** —— 纯函数有判据，界面态没有。要拍到它得让夹具造出 >6 条，那是为了截图
   去改产品数据面，本轮不做，记在这里。
2. 计数行的 `pending` 态要求 `overview == nil`，预览里概览总是算得出来，于是这一支
   同样只在纯函数层被测过。
3. 900pt 这个窗口下限处的余量我没有量到具体像素 —— 上面说的是"演示态有余量 +
   增量 22.5pt"，不是"900pt 下证明不裁"。

## §211 夜间回复率：读库侧凭空伪造的第二个字段（P0，第 4 轮）

代理报「`loadReplyTimingProfile` 把 `silent_at_night` 位重建成 0.0/1.0」。回源码坐实：
`ReplyTimingProfile.lateNightReplyRate` 是非可选 `Double`，库里根本没有这一列，
读出来的一行永远由那个布尔位决定 —— 于是两个方向都错：

- 历史读不到（微信关闭 / 换号 / 锁库）→ `defaultTimingProfile(silent:true, rate:0.0)`
  被缓存 1 小时并写库 24 小时 → 凌晨的自动回复整天被锁，且回执对用户宣称「回复率0%」；
- 真实测到 0.35（`silent=false`）→ 重启后读回 1.0 → 把阈值从 0.2 提到 0.5 的那一次改动
  恰好让凌晨拦截静默失效（0.35 与 1.0 都 ≥ 阈值，所以没有任何一条测试会红）。

修法是把"没测到"变成类型里能表达的状态：字段 `Double?`，新增
`late_night_reply_rate REAL NOT NULL DEFAULT -1`（-1 = 从没测过，历史行天然落在这一档），
`buildTimingProfile` 读失败返回 nil（不缓存、不写库），判断收进
`lateNightHold(rate:threshold:) -> (holds: Bool, reason: String)`。
两条分支都拦（凌晨发给真人是不可逆的一半），但只有真测到的值才允许被印成百分比。

同一形状在计算侧还有一处：`totalLateNightIncoming == 0` 时 `lnReplyRate = 0.0`
仍然是"测到 0%"，改成 nil（没有夜里的往来 ≠ 夜里不回）。

## §212 写失败仍然记账：第 5 个待确认口径（P1）

`insertAutopilotLog` 的 7 个调用点里 3 个用 `try?`、3 个用只打印的 `catch`，
然后照样 `pending += 1`。这条比"读不到印 0"更糟，因为它是**耐久**的：
`sessionPending` 只有"解决一行"才会减，而那一行从没写进去；
`persistSessionCounts` 又把它写库、`start()` 读回来 —— 一次磁盘忙就留下一个
用户永远清不掉、且跨重启存活的 +1。统一收进 `record(_:) -> Bool`，
调用点由结果决定显示与记账；消息仍然 ack（不 ack 会让每个扫描周期再花一次 AI）。

例外是 转账/红包/小程序 这一支：它是"必须有本人听到"的类别，
所以保留显示、只从计数里扣掉（`unrecordedAwaitingHuman`）。
代理主张"直接不显示"，我判为过度收口 —— 那是把"写不进去"变成"你没听说过的这张转账"。

## §213 我上一轮的药被这一轮攻成 P0：`requiresQueueRow` 已撤回（P0）

第 4 轮我为了解开"有 pending 审计行、无队列孪生行 ⇒ 永久不可确认"，
给 `deliveryStillPermitted` 加了 `requiresQueueRow`，让手动确认忽略队列轴。
代理攻击成立：**「队列行没了」正是"用户取消过"的唯一耐久痕迹**
（取消 = 删队列行 + 翻日志行；翻失败时旧顺序已经删了行），
拆掉这一轴等于让重启后的 确认发送 把用户明确撤回的话再敲一遍。

根因不在闸门而在**生产者撒谎**：`processBatch` 用 `try?` 写队列孪生行，
无论成败都把 `queue_id` 盖到日志行上。所以"行没了"这一形状同时被
"取消过"和"从没写进去过"两种事实共用 —— 这才是不可判定的来源。

两处一起改，`requiresQueueRow` 删掉：
1. 队列孪生写成功才声称它存在：`queueId: twinLanded ? … : nil`；
2. `cancelPendingSend` 改成先翻日志行、再删队列行；翻失败就不删
   （取消没发生 = 卡片还在、可以再按一次；旧顺序留下的是"队列没行、日志还 pending"
   这种只能靠内存 hold 兜住的形状）。

**复写了一条保护缺陷的老测试**：`testFailedCancelWriteHoldsBothIdAxes`
原来断言的正是"翻转失败但队列行已删除"。已改写并补上
"队列行必须留着且带 `cancelNotLandedHoldText`"。历史库里已经存在该形状的行
按 fail-closed 处理（不可确认、原始消息仍在收件箱），不做数据治愈 ——
无法区分它来自旧代码的取消还是从未写入的孪生。

## §214 立即发送绕过了自己写的警告（P0）

`holdRowAcrossRestart` 把「这条很可能已经发出」写到队列行的
`manual_only_reason` 上，注释明写是为了跨重启存活；但只有自动路径读它。
`sendNow` 完全不读 `manualOnlyReason`，而审批卡片恰好只对这类行显示「立即发送」
—— 于是那条警告的唯一作用是被下一次敲键覆盖掉。
新增 `durableHold(_:) -> .none | .possiblyDelivered | .withdrawn`，
按写入方使用的**常量**做全等判断（两个文案提为 `unverifiedDeliveryHoldText` /
`cancelNotLandedHoldText`，写侧与判侧同源，杜绝字符串漂移），
`sendNow` 对两档都拒绝且**不消费队列行**。普通人工档（敏感词/群聊/置信度）
仍然允许立即发送，并有正控测试钉住"不是把所有 hold 都挡住"。

## §215 缓存：一个无界键和一个不单向的时钟（P1/P2）

`profileCache` 的键含 `excludeMsgUIDs` 的哈希，而那个集合每次发送都在变 ⇒
每次决策产生一个新键；全仓唯一的 `invalidateCache()` 没有调用者。
24/7 进程里等于按小时漏 StyleProfile（含 fewShotExamples）。
补 `pruning(ttl:cap:)`（纯函数）+ 写在插入之后。

接线判据的教训：`pruning` 的单测全绿，而把 `pruneProfileCache()` 从写路径删掉
**仍然全绿** —— 于是加了 `testingProfileCacheCount()` 直接驱动 `getProfile` 104 次，
第一次跑出 104 > 64（我当时正把变异留在树里）。这条测试同时是界线和牙。

`Date()` 的年龄只在一个方向上可信：`elapsed < window` 对负数同样成立，
一次回跳就让 `refreshedAt` 永远"在未来"，风格画像与夜间回复率被永久冻结。
`isFresh` 统一要求 `elapsed >= 0`。读失败的 timing 画像补 60 秒负缓存
（1 小时会重新造出"锁死一整天"，0 秒会让微信关闭时每次决策重扫 500 条）。

## §216 剪贴板：调用点说不出它最终粘的是什么（P2，第 3 轮药的收尾）

第 3 轮给 `ClipboardGuard.restore` 加了 `pastedText`，但 `navigateToChat`
是在循环里逐个候选名粘贴的，调用点能命名的 `chatName` 未必是板上那串 ——
比较不相等 ⇒ 跳过 `clearContents()` ⇒ 联系人昵称留在通用剪贴板。
改成由写侧记账：`ClipboardGuard.noteWritten(text, on:)` 在真正
`clearContents()+setString` 的那一刻记下，restore 同时接受调用点命名与写侧记账，
两者都对不上时（用户自己复制过东西）仍然不清。
门禁保留：所有 `restore(` 调用点必须显式命名 `pastedText`，并带"至少扫到 3 处"的覆盖度下限。

## §217 本轮判阴与定价

1. 代理主张「`AIAuditPrivacy.persistRawText` 应该 `#if DEBUG`」—— 判阴：
   这个 app 只以 release 形态运行，`#if DEBUG` 等于把开关永久焊死，
   而用户需要它来排查一次真实的打码误伤。改为把文件头注释写准（不是 debug-only、
   保留期就是常规 14 天）。
2. 「`WeChatReader` 快照目录的 pid 复用会让明文快照永存」—— 成立但未修：
   需要 `sysctl KERN_PROC_PID` 取进程启动时间与目录 mtime 比较，
   或落一个 owner 标记文件；另外 legacy 目录（无 pid 后缀）目前是**无条件删**，
   同机第二实例会被误删。要动的是跨平台启动时间语义，留待单独一轮，
   并且它不改变"重启后会被自己清理"这一现状的严重性排序。
3. 「`ConversationMemoryUpdater` / `ChatMonitor+DailyReport` 的窗口该迁单调钟」——
   部分不成立：前者的 anchor 是**持久** `lastUpdated`（迁单调会破坏跨重启语义），
   后者只影响"是否重复生成一次日报"。已给 StyleProfiler 的两处补 `elapsed >= 0`，
   这两处是内存 anchor、且被冻结的是护栏本身。
4. 「`ChatAnalyzer` 把读不到说成 concluded」—— 字面不成立（OnDemandAnalysis
   的"读取消息失败/没有找到消息记录"是分开的），但相邻缺陷成立：
   读到 0 条**可读**内容（全表情/媒体、或被群分析过滤空）也产出 `concluded`，
   在 `ActionPanelView` 渲染成绿色「已定」并被缓存。未修原因：需要新增一档状态
   + 两处生产者 + 一个 `analysisType` bump 才能让旧缓存失效，
   属产品口径（"没内容可读"要不要单独成一档）而不是纯缺陷，交回给 owner 定价。
5. 崩溃窗口里的剪贴板残留：要修只能把聊天原文写进哨兵文件，比泄漏本身更糟 —— 不做。

## §218 撤回被发送路径自己复活（P0，第 5 轮代理攻击成立）

`executeSend` 在敲键之前有一行 `if let sid = sessionId { try? store.upsertPendingSend(item, …) }`，
注释写着"队列行必须在整个发送期间存在，否则闸门会读成『已取消』而永远不发"。
但 `upsertPendingSend` 是 `ON CONFLICT DO UPDATE` —— 对被删除的行它是 **INSERT**，
于是这条防御恰好把用户刚刚按下的「取消本条」撤销了：

`await stalePendingSendReason(item)` 是 actor 的再入点，取消在这一步落地
（翻日志行成功 + 删队列行成功 ⇒ 不留任何 hold，因为两笔写都成了）
→ 恢复后上面那行把队列行写回去 → 闸门 `deliveryStillPermitted(queueId: item.id, logId: nil, …)`
读到 `queueRowLive = true`，而 `logId: nil` 让审批行轴无从拒绝 → 敲键。
发送成功后 `markAutopilotLogSentUnchecked` 的 `WHERE queue_id=? AND action='skipped'`
还会把那行"已取消"改回 `sent`，撤回记录一起抹掉。

这不是 §213 那次重排造成的（旧顺序同样存在），但重排让它变成唯一的存活路径，
所以代理这一击正好打在新代码上。**修法**：给 `mayStillDeliver` 加一条耐久轴
`queueRowWithdrawn`（`autopilotLogWithdrawnForQueue(queueId:)`：有日志行认领这个 queue_id
且 `action='skipped'`），并在 `deliveryStillPermitted` 里对两个调用方都计算。
队列行"活着"不再是"没人撤回过"的证据。

## §219 耐久标记写好了，没有第二个人读（P0，同一谓词的漏消费点）

§214 我把 `durableHold` 只接在 `sendNow` 上（全仓一个调用点），
而审批走的是 `deliveryStillPermitted` / `mayStartApproval` —— 它们的八条轴里
没有任何一条读 `manual_only_reason`。于是重启后：内存 hold 空、队列行还在、
审计行还是 `pending` ⇒ 确认发送全轴放行，而那一行自己写着"先别确认发送"。
**我自己记过的规矩（一处谓词要扫它全部消费点）这次是我违犯的那一条。**

修法与 §218 同一处：再加一条 `durableHoldActive`（读队列行的
`manual_only_reason` 过 `durableHold`），两档（未确认送达 / 撤回未落库）都拒绝。
判据带四条真值表：两支 hold 拒绝，`包含敏感词，转人工` 与 nil 两支**必须放行**，
否则这就是第 N 个确认发送死锁。写侧与判侧共用常量（`unverifiedDeliveryHoldText` /
`cancelNotLandedHoldText`），文案一改测试就红。

有了这两条耐久轴之后，`requiresQueueRow: false` 才重新成立：
取消由"日志行 skipped"和"队列行 hold"两把耐久锁盖住，队列行的存在与否
不再承担区分"取消过 / 从没写进去"的职责 —— §213 的两次反复根源于此。

## §220 我把"诚实的 nil"当成了"没测到"（P1，自己上一轮的药）

§211 让夜里没有来量时 `lateNightReplyRate = nil`（正确），
但缓存与信任轴是按"rate 非 nil"判断"这行是不是测过"的 ⇒
一个测了 40 对、只是夜里不说话的联系人，DB 行永远不被信任、内存窗口被降级到 60 秒
→ 每个批次 flush 重跑一次 500 条全量配对分析（白名单里多数是夜间不回复的人）。
改成问 `sampleCount > 0`：**"测过但没有值"与"没测过"是两个问题，别用同一个字段答**。
判据 `testACompletedMeasurementWithNoLateNightTrafficIsNotReMeasured`
用一个指向空目录的 reader 做判别器：信 DB 就返回 sampleCount=40，重测就返回 0。

## §221 pid 复用：明文快照的守灵人换了（P1，§217 的第 2 条已修）

`ownerIsAlive = kill(pid,0)==0` 在 pid 被复用后会对着一个陌生进程说"主人还活着"，
而那个目录是整个消息库的明文副本 —— 它永远不会被回收。
`shouldRemoveSnapshotDirectory` 增加"主人启动时刻晚于目录 mtime ⇒ 不可能是主人"，
判据四向：晚启动 ⇒ 删；早启动 ⇒ 留；启动时间或 mtime 未知 ⇒ 留（这是破坏性分支）；
以及一条活的内核探针测试（`processStartedAt(getpid())` 必须落在 boot 与 now 之间）。

**实测推翻了我的先验**：`proc_bsdinfo.p_starttime` 在这台 macOS 上就是**绝对 epoch 秒**
（本进程读到 1789862775.650，`Date()` 1789862775.858，`kern.boottime` 1789351563），
不是"开机以来秒数"。我先按 `boot + p_starttime` 写，测试立刻红在
"我们的进程启动于 2083-06-03"，如果只靠推理这里就会留下一个永久失效的防御
（所有目录都比"主人"年轻 ⇒ 什么都不清理，且看起来完全正常）。
boot time 只留作下界校验。

## §222 本轮判阴与定价（不修，但记清楚为什么不修）

1. **legacy 文本兜底现在有歧义池（P1，未修）**：`legacyTwinPredicate` 是
   `queue_id IS NULL … ORDER BY created_at, rowid LIMIT 1`（最旧优先）。
   §213 让运行期的孪生写失败也产出 `queue_id IS NULL` 的 pending 行，
   于是同会话同文本（"好的""收到"）两行时，取消可能翻到**更旧的那行**，
   `flipped=1、deleteLanded=true` ⇒ 不布防任何 hold，用户那张卡片还是 pending。
   没有一并修的原因：这条路径要求"孪生写失败 + 同文本并发 + 取消"三件事同时发生，
   而正确修法（把兜底收紧成"仅当候选唯一"或把 session_id 一路传进 `markAutopilotLogSkipped`）
   会改变 `twinClaimed` 的语义，需要一整轮回归；
   §218/§219 两条耐久轴已经把"翻错行 ⇒ 能发出去"这一步挡住了（队列行被删 ⇒ `queueRowLive=false`，
   除非它又被复活，而那正是 §218 的轴在读）。
2. **第四种 hold 文案没进分类器（P1，故意只做两档）**：`sendFailureDisposition` 的
   `.humanRequired` 文本（"…请先检查微信，再手动处理"）语义上同样是"键可能已进"，
   但它是**运行时拼接**的（原因 + 后缀），精确等值分类器无法覆盖。
   不修的理由：给它加一档会立刻把"每一次发送失败"都变成"禁止确认发送"，
   那是把 P0 换成另一个死锁。要修得先在 `SendFailureDisposition` 里把
   "键是否可能已落地"提成枚举字段而不是文案（同 §214 的形状），是一次独立重构。
3. **拒绝语指向一个不存在的按钮（P2，文案已改，缺口仍在）**：`sendNow` 的拒绝文案原本
   让用户"用「编辑并发送」"，而 `editAndSendAutopilot`（`ChatMonitor.swift:2395`）在
   Views 里零调用点 —— grep「编辑并发送|editAndSend」在 Sources 里只有 3 处命中，
   全在 Service/Data 层，没有一处是按钮。
   （自查：这一段第一版写着"已把文案改成…"，其实当时并没有改，是下一轮复核时才发现的
   —— 文档里的"已修"必须回读一次源码，和代理的结论同样对待。）
   现在文案改成只指向真实存在的动作（"先在微信里核对；确认没有发出，再取消这条并手动回复"）。
   剩下的产品缺口：用户需要一个"核对完再放行"的按钮，即 `editAndSend` 的上屏
   —— 那是新功能，不是质检项，交回给 owner 定价。
4. **统计口径（P2）**：写失败的转账被 `immediateEntries.count - pending` 归进"已跳过"，
   统计页会把它报成跳过的消息，而它其实是待本人处理。要单开一档"记录失败"才准。
5. **`loadAutopilotLog` 不读 `queue_id`（P3）**：共享解码器的列表停在 `created_at`，
   所以任何从 `loadAutopilotLog` 出来的行 `.queueId == nil`。今天没有读者依赖它
   （全部 `.queueId` 消费点用的都是当场构造的 entry），已在字段注释里写明
   "别把这里的 nil 当成『没有孪生』，要问 store"。

## §223 最后一公里：输入框读数失败时闸门是"打开"的 —— 已instrument，仍未真机验证

本轮把长期挂着的一条"从未验证"项查清了**代码侧**的立场：
所有三处覆盖闸门（`inputBoxIsKnownEmpty` / `pastedBoxStillHoldsOnlyTheReply` /
`boxIsKnownToHoldOnlyTheReply`）都从 `readInputBoxValue` 取值，
而这个函数在 `kAXValueAttribute` 读不到时返回 nil，调用方一律**放行**（fail open）。

- 这是刻意选择，理由写在注释里：如果某个微信版本不再暴露该属性，
  收紧会把整个自动发送变成"永远发不出去"，代价比"可能覆盖用户没发完的话"更大。
- 但"刻意的 fail open"必须可被证伪，否则它就只是"我们永远不知道它有没有在工作"。
  所以现在读不到会往 launcher.log 落一行
  「input-box AX value unreadable — 覆盖/发送闸门本轮失败打开（未拦任何内容）」，
  字段级（而不是推断级）的证据。
- 例外是撤回路径 `boxIsKnownToHoldOnlyTheReply`：那里"读不到 ⇒ 不要动手"，
  因为撤回的替代动作是"把我们自己粘进去的草稿留在框里"，
  而对着读不到的框做全选+删除会抹掉用户后来的输入。

**仍未验证的事实**：微信当前版本的输入框到底能不能读到 `kAXValueAttribute`。
本机不装微信、也不允许读真机聊天数据，所以这条只能靠用户跑一次真实发送后
看 `launcher.log` 里有没有那一行来判定。上报口径：
**如果那行日志在正常发送后出现过，则本轮 §128/§129/§191 一系列"不覆盖用户输入"的
防御在生产里全部等价于没做**（不是"做错了"，是"没人知道有没有生效"）。
这是这个分支上唯一一处"闸门本身是否工作"悬空的已知项。

## §224 第 6 轮后端确认：P0：无，但耐久标记在它最该生效的那一类行上没写

后端一路专门攻"撤回/静音/暂停之后文本仍抵达发送键"，结论 **P0：无**
（四条入口在没有写失败的前提下都能拦住；下列都要一次 DB 写失败才成立）。
三条 P1 里两条落地修了：

1. **`holdRowAcrossRestart` 的 `manualOnlyReason == nil` 早退（P1，已修）**：
   会话上限 / 过期 / 敏感词 转人工的那一行，恰好是审批卡片会对它显示「立即发送」的那一行。
   如果这一行的取消翻转写失败，早退守卫让撤回标记**根本不写**，
   于是盘上留下的唯一事实是"不能自动发"—— 重启后 `durableHoldActive=false`、
   `queueRowWithdrawn=false`（行还是 pending）、`requiresQueueRow:false` 关掉队列轴 ⇒ 放行。
   用户先看到「已取消即将发送的回复」，然后那条真的发出去了。
   修法是取消早退：**「上一次的结果没人知道」优先于「不能自动发」**，直接覆写；
   具体原因仍然留在审计行自己的文本里。`countAsAwaitingHuman` 保留它自己的守卫（记账不能重复）。
2. **`editAndSend` 没有那两条拒答（P2→修）**：`sendNow` 上一轮补的耐久检查
   只接了一个门。"一处谓词要扫它全部消费点"这条规矩我这一轮又违犯了一次。
   该函数目前在 Views 里零调用点（grep「编辑并发送|editAndSend」在 Sources 只有 3 处、
   全在 Service/Data 层），所以不可触发 —— 但闸门补齐之前，那条不可达路径是唯一不设防的门。
   顺带把拒绝文案里指向这个不存在的按钮的指令改掉了（见 §222 第 3 条的复核）。
3. **legacy `queue_id IS NULL` 的孪生行对两条新轴恒不可见（P1，未修）**：
   `queue_id` 是 `ALTER TABLE ADD COLUMN` 加的、不回填，老库里所有孪生行都是 NULL，
   于是 `autopilotLogWithdrawnForQueue(queue_id=?)` 看不见它们被取消的那一行；
   新代码在 `twinLanded=false` 时也会产同形状。触发需要 upsert + flip 两次写失败，
   而"给 legacy 行补 link"要么回填要么把文本兜底收紧成"候选唯一"，
   两者都会改 `twinClaimed` 的语义 —— 与 §222 第 1 条同一个根，留作一轮独立回归。

另外两条被这一路确认**没有**问题：`unrecordedAwaitingHuman` 不会多减
（`.pending` 的 immediate 只有 forcePending 一支，批量路径的 pending 在 `record` 成功之后才加）；
`executeSend` 传 `logId: nil` 导致审计行轴在批处理路径不可达 —— 由 `queueRowWithdrawn` 补上，
只剩上面第 3 条那个 legacy 盲区。

判据：`DurableHoldCoverageTests` 2 条，各带反向变异
（把早退守卫放回去 ⇒ 第一条红；把 `durableHold(existing.manualOnlyReason)` 换成 `durableHold(nil)` ⇒ 第二条红），
以及"普通 hold 必须仍可编辑并发送"的正控。

## §225 第 6 轮前端确认：P0：无，三条 P1 修了两条半

前端一路专查本轮 34 个 UI 文件改动的四条轴，回报 **P0：无**，并核实了
被删的 `AutopilotTabView` / `InsightWindow` 零悬挂入口（`SettingsView.Tab` 18 个 case 全有渲染分支），
同时**证伪了两条它自己考虑过的候选**（取消关注的长文案确实兑现到 `clearDerivedArtifacts`；
`RelativeTimeFormatter.unknown` 在三个整句调用点不会拼出破碎句）。

已修：

1. **回执会跨行存活（P1）**：`ApprovalWorkspaceView` 里 `receipt` 有 10 处赋值、
   零处清空；选中另一条队列项时，上一条的绿色「已发送给「A」」仍挂在 B 的详情下方。
   本轮刚把 `receipt` 升级成自带 `isFailure` 的 `Receipt`，于是这条陈旧横幅
   从"图标靠猜"变成"确定地报错"。`onChange(of: selected?.id)` 里清空。
2. **「已取消」不看结果（P1）**：`cancelPendingSend` 返回 Void，界面无条件打印
   「已取消即将发送的回复」—— 而 §224 之后，翻转写失败时我们**故意留着队列行**，
   于是同一个屏幕上一边打勾一边把那条继续排在待发队列里。
   改成 `CancelOutcome { withdrawn | held(reason:) }`，两个写都落地才算撤回；
   "队列里根本没有这条"算撤回（没有东西能发出去），不是撤回失败。
3. **读不到配置的设置页长得像能改（P1）**：`.unreadable/.corrupt` 分支的提示在表单
   **下方**，八个 `@State` 保持 Swift 默认值，`save()` 又被 `loadError == nil` 挡住 ——
   用户拖动置信度滑块，滑块动了、什么都没写；同一页还印「不会自动回复的人 (0)」，
   把"没读到"当计数显示。表单整体 `.disabled(loadError != nil)` + 半透明。

未修（定价）：`ChatInsightView` 把日统计移出 body 之后，读取期间 `stats` 为 nil，
详情面板没有"正在读"这一档：无 AI 结果时印「选一个日期后…」（用户已经选了），
有 AI 结果时 `stats?.messageCount ?? 0` 把"没读到"喂成实测值印「0 条消息」。
这是本轮"把计算移出 body"引入的瞬态，要修得给详情面板加一档读态（并顺手处理
`InsightKPIGrid` 把 nil 一律解释成"范围不足 7 天"）；两条都是**瞬时**且
下一次刷新自愈，不是持久谎言，排在下一轮。

判据：`CancelReceiptHonestyTests` 2 条（真值表 + 两条 View 侧接线守卫带下限），
反向变异"取消总是回报成功"⇒ 1 红。

## §226 我自己写的两面旗子被我自己新写的注释绊倒（判据精度）

第 6 轮之后跑全量，红了两条 —— 都不是产品缺陷，是**门禁把注释当文案扫**：

1. `RelativeTimeVocabularyTests.testPassedDeadlineIsCalledOneThingAcrossTheApp`
   禁止 `超期/过期` 出现在 Sources 任何一行，我给 `holdRowAcrossRestart` 写的解释性注释
   （"会话上限 / 过期 / 敏感词 转人工的行"）命中。
2. 本轮新加的 `ReferralCopyPointsAtRealControlsTests` 禁止 `编辑并发送` 出现在
   `AutopilotService.swift`，而我为"为什么这条路径不设防"写的注释里正提到那个不存在的按钮。

两条都改成**只看用户读得到的行**（跳过 `//` 与 `*` 开头的行），
理由与那条老判据自己的注释一致（"comments may still describe the old label"）。
收紧之后各自反向变异仍然红：往 Sources 放一个含 `已超期` 的实体文件 ⇒ 第 1 条红；
把 `sendNow` 的拒绝文案改回"…再用「编辑并发送」" ⇒ 第 2 条红；
并给第 2 条补了"剥完注释后不能是空串"的覆盖度下限，
否则"全部剥掉"和"没有问题"又是一对长得一样的输出。

一般式：**判据的作用面要与它要管的东西同宽**。管文案就只看字面量，
把散文一起管进去的判据，第一次被人认真写注释时就会红，
而那一红的正确反应往往是删掉有用的注释 —— 那是判据在倒过来编程。

## §227 第 7 轮：另一颗取消键是同一缺陷的第二个门（P1→修）

第 7 轮只审最近三个提交，回报 **P0：无**，两条 P1 都指向我上一轮药的另一半：

1. **`rejectPending`（详情面板那颗「取消本条」）从不布防耐久 hold**。
   §219/§224 修的撤回痕迹全在 `cancelPendingSend` 这条路上，而审批卡片自己的那颗按钮
   走 `ChatMonitor.rejectAutopilotItem → service.rejectPending(logId:)`：
   翻转 `.writeFailed` 时它把队列孪生照样 `try?` 删掉，于是留下
   「审计行 pending + 孪生没了」——正是 §219 花两轮关掉的那个形状。
   重启后 `durableHoldActive`（读队列行）与 `queueRowWithdrawn`（读审计行 skipped）
   双双为 false，加上 `requiresQueueRow:false` ⇒ 确认发送放行。
   **改法**：翻转失败时不删孪生，改为找到它并走 `holdRowAcrossRestart(.cancelled)`
   （与 `cancelPendingSend` 同一目的地），同时把结果回报成 `CancelOutcome`，
   界面不再无条件打印「已取消本条，对应的待发草稿已一并移除。」。
2. **取消失败时那张卡片自己先消失了**。`cancelPendingSend` 在任何写之前无条件
   `pendingSendQueue.removeAll`，而列表镜像正是这个内存数组 ⇒
   我上一轮写的提示「请再按一次取消」指向一颗刚刚不存在的按钮，
   而详情面板那条橙色耐久 hold 文案在本会话内永远不可能出现（只有重启后才露出）。
   **改法**：`!deleteLanded` 时把这一行放回内存队列（它确实还排着、也确实被按住）。

P2 三条的处置：
- `receipt = nil` 也吃程序化换选中（取消成功后该行离开 `.pending` 过滤器，
  下一次刷新会把刚印出的回执抹掉）——**已知代价，未修**：
  在"陈旧回执确定地报错"与"回执可能提前消失"之间，后者是更轻的错；
  要修得把清空点从 `onChange` 移到列表行的点击处理上。
- `.cancelled` 覆写会盖掉 `.delivered` 那支更强的文案（两支都拒绝发送，
  只是人话降级）——记在此处，与 §224 第 3 条一并留待把 `manual_only_reason`
  从文案升级成带档位的编码。
- 设置页的逃生门复核为**没被禁**（`SettingsSection` 在 disabled 容器之外闭合，
  「重新读取设置」与「用默认设置覆盖并重载」仍按得动）；一起被压暗的是只读安全陈述
  与两个 `DisclosureGroup`，可接受。
- 另外它证伪了两条它自己考虑过的候选：`autopilotService` 全仓只在
  `ChatMonitor.swift:3361` 赋值、从不置 nil（故 `?? .withdrawn` 当前不可达）；
  `sessionPending` 不会重计或漏计。

判据：`RejectDoorDurabilityTests` 2 条，反向变异各红 1 条
（去掉 `holdRowAcrossRestart` ⇒ 第一条红；去掉把行放回内存队列 ⇒ 第二条红）。
写这两条判据时第一条测试自己先红了两次：一次是忘了插审计行（没有孪生可翻时
翻转"成功"是正确的），一次是 `.cancelled` 忘了带参数 —— 都属于判据自己坏掉，
不是被测对象坏掉。

## §228 第 8 轮：第 7 轮那颗药自己把耐久标记抹了（P0，已修）

第 7 轮让 `cancelPendingSend` 在删队列行失败时把行放回内存队列，好让「请再按一次
取消」指得到一颗真存在的按钮。复核代理（只读，审 `git show HEAD`）指出放回去的是
**hold 之前的那份快照**，回源码确认成立：

- `let requeueable = item` 在写耐久标记之前取值；`holdRowAcrossRestart` 只
  `upsertPendingSend(guarded)` 改盘，不动内存数组。
- 于是内存镜像里那行的 `manualOnly_reason` 还是旧值，而 `sendNow` 的耐久判据读的正是
  这份内存副本 ⇒ 本会话「立即发送」不拦（队列页那条橙色横幅同样不出现，即第 7 轮
  第 2 项也没达成）。
- 更坏的是它不止"少一道内存闸"：`upsertPendingSend` 是
  `manual_only_reason = excluded.manual_only_reason` 整列覆写，这次放行的「立即发送」
  会顺手把盘上唯一的耐久痕迹写回旧值。之后审计行仍是 pending、`queueRowWithdrawn`
  为假、`approvePending` 走 `requiresQueueRow: false` ⇒ 重启后确认发送（一键）或
  自动发送（零点击）把用户撤回的话敲给真人 —— 与 §213/§218/§219 定 P0 的同一形状。

修在产端而不是再叠一层判据：`holdRowAcrossRestart` 改为 `@discardableResult` 返回
带标记的那一份，`cancelPendingSend` 放回 `heldCopy ?? item`。

判据：`RejectDoorDurabilityTests.testACancelThatDidNotLandKeepsItsCardVisible` 从
「行还在队列里」升级到走完整链路 —— 内存镜像带标记 → `sendNow` 拦下 → 拦下之后盘上
标记仍在。反向变异（放回 `item`）红 3 条，第三条正是"标记被覆写回旧值"，即代理预测
的破坏链在测试里真演了一遍。全量：2135 XCTest + 70 swift-testing 全绿。

自查记录：第一次跑反向变异时我把 `--filter` 写成了 `CancelReceiptHonestyTests`，而这条
测试其实在 `RejectDoorDurabilityTests`，于是"变异存活、0 failures"是**跑错了套件**造出来
的假绿，不是判据弱。上一轮刚把"@MainActor XCTestCase 不被收集"记进记忆，同一族（绿灯
可能来自根本没跑）在同一个 session 里第二次差点骗过我。

## §229 第 8 轮定价为未修（1 P1 + 1 P1 + 1 P2，均在撤回链上）

- **P1** `holdTwinAcrossReject` 找不到孪生行时 `guard let twin else { return }` 静默
  返回，调用方仍回报 `.held("…已经按住…")` ⇒ 用户读到一句没有两条耐久轴支撑的承诺。
  触发用的是单层 Optional 的 `autopilotLogQueueId`，而不是 `approvePending` 那套三态
  `autopilotLogQueueIdRead`（§200 同族）。方向：读失败/确无孪生要分两样说，且回报值
  必须由实际写了什么决定。
- **P1** `ApprovalWorkspaceView` 那颗「取消本条」：回执现在在两次 `await` 之后才写，
  而 §225-1 的清空发生在 `onChange(of: selected?.id)`（早于落地）⇒ 按完立刻换选中，
  橙色横幅会挂到另一条详情下；且这颗按钮没有 `confirmSend` 那样的 `isSending` 闩，
  双击会起两个 Task（`target` 是值拷贝，id 不会错，第二次走 `.wasNotPending`）。
  上一轮修的跨行陈旧回执被新加的 await 复活了一半。
- **P2** `rejectPending` 走 hold 分支时把行从内存队列 `removeAll` 后再不放回（与
  `cancelPendingSend` 门不对称），:1233 那句「it stays visible」在 reject 这扇门不成立；
  盘上行仍在，重启后又会出现 —— 界面在两次启动之间对同一条给了不同答案。

三条都在撤回链上，不构成"撤回失败还发出去"，故留作下一轮；本轮只落 §228 这条 P0。

## §230 第 8 轮补：reject 这扇门也放回带标记的行（P2，已修）

`holdTwinAcrossReject` 走 hold 分支时把行从 `pendingSendQueue` 里 `removeAll` 之后再也
不放回，而盘上的行仍在 —— 于是 §227 那段注释里的「it stays visible」只在 cancel 门成立：
同一个用户在两次启动之间会看到两个答案（本页说没了，重启后说"仍按住等人工"），并且
`sendNow` 读的正是内存镜像，这一扇门本会话没有任何东西可拒。
修在产端：`pendingSendQueue.append(holdRowAcrossRestart(twin, kind: hold))`，放回的是带
耐久标记的那一份，与 §228 同形。

判据：`testRejectWithFailedFlipHoldsTheTwinInsteadOfDeletingIt` 增加"内存镜像里那一行必须
带 `cancelNotLandedHoldText`"。反向变异（改回不 append）红 1 条；全量 2135 XCTest +
70 swift-testing 绿。写这条判据时先撞了一次编译错：`XCTUnwrap` 的表达式参数是
`@autoclosure`，`await` 放进去不合法 —— 属于判据自己坏掉，已 hoist 成局部变量。

## §231 第 8 轮另两路并行审计的回报：**含 1 条未修 P0**，本轮预算耗尽，原样交棒

回源码状态：**未裁决、未修**。以下是代理给出的证据坐标，下一轮必须先回读源码再定价
（§228 的教训：上一轮的药也可能是被告）。

- **【P0，未修】DiscussionTracker 把「白名单这一行读不到」当成「用户已取关」，直接
  DELETE 未分析的持久队列。**
  (a) `HUDStore.getWhitelistEntry`(:1059) 走 `queryOne`，其 `try?`(:4961) 把 step/prepare
  错吞成 nil；单行读没有 throwing 兄弟，`whitelistAllRead()`(:1043) 只覆盖全表且全仓仅 2 处调用。
  (b) `DiscussionTracker.swift:78/103/126/308` 四处 `else { try? store.clearDiscussionMessages(...) }`
  → `DELETE FROM discussion_queue WHERE chat_username=?`；该表的全部意义是跨扫描存活，删掉后
  这些消息永不再被抽取（待办/承诺/讨论项静默消失），而白名单水位独立推进，不会重放。
  (c) 可达：:308 在 AI await 之后、:126 在 drain 循环内。
  与 §211 定 P0 的夜间回复率同形（一个取值同时代表「没有」与「读不到」），但落点是删除。
  方向：三态读（复用 `SettingRead` 的 absent/corrupt/unreadable），只有 absent 才清，
  unreadable 走 `ChatMonitor+Classification.swift:193` 的 `.retry`。
- **P1（未修）** `AutopilotService.start()`(:320/:325) 用非抛 `currentAutopilotSession()`(:3486)
  恢复会话 ⇒ nil 兼"读不到"时 `maxSendsPerSession` 从零重计（最多翻倍）且旧 session 的待发行
  成孤儿（:3491 注释自己承认，并备了 `currentAutopilotSessionThrowing`，但非抛版仍有 4 处调用）。
- **P1（未修）** `addToWhitelist`(:977-979) 把 `getContact`(:2256) 读不到当 nil 后
  `?? 默认值` 交给全量覆盖的 `upsertContact`(:2216) ⇒ 悄悄重置 role/roleNote/replyWindowMinutes，
  与已修的 `updateAutopilotConfig`(:905-915) 完全同形。
- **P2（未修）** `bulkMessageStats`（`WeChatReader.swift:1774-1808`）分片读失败被 `continue`
  丢弃且无 partial 标记 → `ChatInsightEngine:384` 的 `?? 0` 把它当"0 条消息"，
  渲染成「被忽视的高层」/「回复率 0%」；`loadChatActions()`(:1297) 失败＝「从未静音」，
  会让用户静音过的对话重新弹通知（`ScanEngine:138/151`→:219/:252/:681）。
- **常驻退化轴：P0：无。** 两处 P1 待核：待确认队列在默认配置下没有退出路径
  （`pendingSendQueue` 无 TTL/上限、`loadPendingSends` 无 LIMIT，靠用户动作或 `stop()` 才清）；
  `vip_traces`/`commitment_scans`/`ai_data_ledger`/`review_runs` 四张表零 DELETE
  （`clearOlderThan` 全仓无调用方，`runRetentionSweep` 显式声明这三张"无声明窗口"）。
  另 `StyleProfiler.timingCache`(:490) 是上一轮 profileCache 剪枝的**同形状漏改**（TTL 只在读时判）。
  该轮并排除了句柄/Timer/observer 一全部候选（statementCache cap 24 + finalize、
  handleCache limit 16 + close、decryptedCache 每轮清、各计时器有 invalidate）。

## §232 第 9 轮：§231 那条 P0 回源码核实成立，已修

`DiscussionTracker` 的门禁写的是 `store.getWhitelistEntry(...) != nil`，而它的 else 分支
是 `clearDiscussionMessages` ⇒ `DELETE FROM discussion_queue WHERE chat_username=?`。
`getWhitelistEntry`(:1059) 走 `queryOne`，其 `try?`(:4963) 把 prepare/step 错误吞成 nil，
于是「这一行读不到」与「用户已取关」是同一个答案。

危害坐实（不是理论）：`discussion_queue` 是唯一跨扫描存活的载体，白名单水位独立推进、
不会重放已经翻过去的消息 —— 一次读失败就把尚未分析的待办/承诺/讨论项整段删净，且无任何
用户可见痕迹。四处都在最容易撞上读失败的时刻：`extract`(:107) 之前、`resumePending`(:134)
的 drain 循环里、`drainChat`(:159) 每批次前、`extractWindow`(:344) 在 AI await 之后。

仓库里其实早已备好东西并写明规矩：`whitelistRead`(:1013) 三态 `.followed /
.unfollowed / .unreadable`，注释还特别点名「Callers that *delete* or retire work on a
false answer must use `whitelistRead(_:)`」，`ChatMonitor+Classification` 也确实照做了 ——
这是本会话反复出现的形状 B（一个谓词在 N 个消费点里只迁了部分）。

修法：`DiscussionTracker` 内加私有 `scope(_:)`，只有 `.unfollowed` 才允许进入删除分支；
`.unreadable` 不抽取也不删（下一轮扫描再来）；`.followed` 但 `getWhitelistEntry` 取不到
载荷（行存在却解不出）同样归入 `.unreadable`，宁可不做也不误删。

判据：`DiscussionQueueScopePurgeTests` 3 条。故障注入用 `ALTER TABLE whitelist RENAME TO
whitelist_hidden`（模拟迁移中/BUSY 超时/IOERR 下所有对该表的读都报错，而不是回答"没这行"）。
- 反向验证不是"改坏新代码"而是**直接拿修复前的文件跑**：两条"必须留着"的判据各红一次，
  失败信息就是 `("0") is not equal to ("2")` —— 队列真的被删空过。
- 正对照：确证取关（表在、行删）仍清空，证明这条修改没有把"删除"换成"永不删除"。
全量 2138 XCTest（+3）+ 70 swift-testing 绿；无任何旧判据在保护这个缺陷。

## §233 第 9 轮：`addToWhitelist` 把「联系人读不到」写成默认值（P1，已修）

§231 第 3 条回源码核实成立。`addToWhitelist` 先 `INSERT OR REPLACE INTO whitelist`，再
`getContact(username:)`（走 `queryOne`，`try?` 吞掉 prepare/step 错误）拿旧值，然后
`existingContact?.role ?? 默认` 交给 `upsertContact` —— 而它是
`ON CONFLICT DO UPDATE SET role/excluded...` 的整列覆盖。于是「这次读不到」与「这人从来没有
联系人记录」同一个答案，一次读失败就把用户手工设的 role / role_note / reply_window_minutes
悄悄重置成默认；`ReplyDebtScorer` 与收件箱排序据此再算一遍「超时」。与已修的
`updateAutopilotConfig`（"refusing to write over a config that could not be read"）同形，
也是形状 B：三态化做过了，消费点漏了。

修法照 `whitelistRead` 的既有约定补 `HUDStore.ContactRead`（`.value / .absent / .unreadable`，
行存在但解不出也算 `.unreadable`），并把读挪到任何写之前；`unreadable` 时**只跳过这次合并写**：
关注本身仍然成功（抛错会让 `ChatMonitor` 三处 `try? addToWhitelist` 静默不关注，那是另一种
用户可见损失），只是不拿默认值去覆盖读不到的东西。

判据：`ContactMergeHonestyTests` 4 条 —— 三态各自可辨（含真故障注入：把 `contacts` 表改名，
让 SELECT 报 `no such table` 而不是回答"没有这行"）；正常路径的合并语义仍生效（正对照，
证明不是把"覆盖"换成"永不写"）；读失败下不抛错且 roleNote/replyWindowMinutes 保持；
读失败下关注确实写进去了。反向变异（把 `.unreadable` 塌回 `.absent`）红 3 条，其中一条正是
`("absent") is not equal to ("unreadable")`。全量 2142 XCTest（+4）+ 70 swift-testing 绿。

## §234 第 9 轮：会话恢复读失败会「再开一个会话」，每会话发送上限被花第二次（P1，已修）

§231 第 2 条核实成立。`AutopilotService.start()` 用 `store.currentAutopilotSession()` 恢复
活动会话，而它走 `queryOne`（`try?` 吞 prepare/step 错）⇒ nil 同时表示「没有活动会话」与
「这次读不到」；下一行 `recovered?.id ?? store.startAutopilotSession()` 于是**新建一个会话**，
`sessionSent` 归零 —— `maxSendsPerSession`（默认 50）正是挡住托管模式对同一个人反复敲键的最后
一道闸，一次读失败就把它变成可以花两遍；同时旧会话的 `ended_at` 永久为 NULL，它名下的队列行
再也没人加载。

同一族第三次命中：`currentAutopilotSessionThrowing` 早已存在，注释还写明「clearAutopilotHistory
把 nil 当成可以删」而需要它 —— 又是形状 B（三态兄弟做过了，消费点漏了）。

修法：`start()` 改 `try store.currentAutopilotSessionThrowing()`。它本来就是 `throws`，而
`startAutopilotAndWait` 已经把抛错如实变成「没开启」（不打印已开启、不翻转 UI），所以不需要
额外的回执改造。

判据：`AutopilotSessionRecoveryHonestyTests` 2 条。故障注入取的是"读坏而写不坏"的最小形状：
`startAutopilotSession()` 只 INSERT `started_at`，所以 `ALTER TABLE autopilot_sessions
RENAME COLUMN total_sent TO total_sent_x` 只打断恢复用的 SELECT。
- 反向变异（换回非抛版）红 5 条，其中两条就是 `("2") is not equal to ("1")`（多开了一个会话）
  和 `("0") is not equal to ("40")`（已发送数被弃用/归零）。
- 正对照：健康重启仍复用同一会话、仍带 40 的计数 —— 证明修改没把恢复变成「永远拒绝启动」。
全量 2144 XCTest（+2）+ 70 swift-testing 绿。

自查：本轮我自己的两个流程错误值得记 —— (1) 把 `cp X.bak X` 的备份方向搞反，用"改前备份"
去"恢复改后"，等于悄悄回滚了自己的修复（恢复后必须 grep 关键行确认，已补做）；(2) 变异跑
"没输出"是因为测试文件根本没编译过，`grep` 只找断言行就看不见编译错 —— 这是同一族第三次
（没收集 / filter 打错 / 编译没过）。

## §235 第 9 轮：另一颗「取消本条」在"没有任何可持有对象"时也在承诺「已经按住」（P1，已修）

§229 第 1 条核实成立。`rejectPending` 的 flip 失败分支无条件回报
`.held(reason: "…这条已经按住，不会自动发出…")`，而它依赖的 `holdTwinAcrossReject` 第一行就是
`guard let twin else { return }` —— 找不到队列孪生时**静默什么都不做**。此时两条耐久轴全空
（审计行仍是 pending、`queue_id` 无行可查），`approvePending` 走 `requiresQueueRow: false`
仍然可发：用户读到一句产端根本兑现不了的承诺，于是停止核对，而下一次点「确认发送」就会把
他刚拒掉的回复敲给真人。取孪生用的还是单层 Optional 的 `autopilotLogQueueId`（读失败＝没有
孪生），而同文件早已备好三态的 `autopilotLogQueueIdRead`。

修法：`holdTwinAcrossReject` 返回它到底持有了谁（`PendingSend?`），孪生查找改走三态读；
`rejectPending` 的回报文案由"实际写了什么"决定 —— 无持有对象时明说
「它并没有被记成已撤回，请再按一次并核对微信」。仍不改数据结构：给无孪生的审计行加耐久痕迹
需要另一套编码（与 §224 第 3 条"把 `manual_only_reason` 从文案升级成档位"同批）。

判据：`RejectDoorDurabilityTests` 加 2 条，两条朝相反方向把关，因此不可能被"两句合成一句
通用警告"糊过去 —— 无孪生时禁止出现「已经按住」；有孪生时仍必须出现「已经按住」。
反向变异（直接拿修复前的源文件跑，测试保留）：第一条红，第二条仍绿。全量 2146 XCTest
（+2）+ 70 swift-testing 绿。

流程自查（第三次踩同一族，值得单独记）：这轮我 (1) 又一次把 `cp` 的备份方向搞反，
用"改前备份"去"恢复改后"，等于自我回滚；(2) 一次 perl 变异锚点没匹配上、`sed` 之后
计数仍是 1，我却把随后的"0 failures"当成了变异存活的结论。两步都被"恢复后 grep 关键行"
这道收尾断言抓住 —— 以后所有变异实验都必须打印"我确实改到了"的计数，并且把
"改前源文件 + 新测试"这一组当作默认的红/绿对照，而不是依赖手写的 mutation 字符串。

## §236 第 9 轮：静音规则「读不到」＝「没人被静音」，于是把撤回过的回复敲进微信（P0，已修）

第四路只读扫描代理报回这一族的又两处，其中一处它把我原先定价的 P2 上调为 P0，回源码同意：
`loadChatActions()`（HUDStore:1312）走 `queryAll`，其 `try?` 把 prepare/step 错吞成 `[]`，
四个消费点全部把空字典读成「没有任何对话被静音/稍后提醒」：

- `AutopilotService.conversationIsMuted`(:626) 的 `?? false` 直接喂 `deliveryStillPermitted`
  (:644) 的发送门禁 —— 静音是用户**不开审批卡就撤回一条回复**的手段，读失败即放行，等于把
  他刚撤回的话敲进微信。按本轴定义（发出已撤回内容）是 P0，不是 P2。
- `ScanEngine.performScan`(:57) 的 6 处读（:138/:151/:686/:996/:1422→:1533）决定横幅与系统
  通知；读失败会把用户静音过的对话重新弹通知。
- `ChatMonitor.hydrateInboxActionsFromStore`(:2628) 更糟：它先 `removeAll` 再按读到的内容重建，
  于是一次启动期的读失败会**清空内存里的静音/稍后提醒**，而它在 `start()` 里跑。
- `silencedConversations`(:2745) 只影响管理页（读失败→列表空→没有那颗取消静音键），
  本轮按原样保留，属"展示层少东西"不是"做错事"。

修法：新增 `HUDStore.chatActionsRead() -> [String: ChatActionState]?`（nil＝读不到），三个会
做错事的消费点改为保守方向 —— 门禁 nil⇒视为已静音（不发）、扫描 nil⇒本轮不出结论且
**不推水位**、水合 nil⇒保留现有内存状态不重建。`loadChatActions()` 留给展示型调用点。
另补 `StyleProfiler.timingCache` 的上限（上一轮 profileCache 的同形状漏改，复用已有的纯函数
`pruning`，TTL 取读侧最长窗口 3600 以免剪掉仍算新鲜的条目）。

判据：`MuteRuleFailClosedTests` 3 条 + `ScanSkipsUnreadableMuteRulesTests` 1 条。
- 门禁：同一份 setup 里先要 `permittedNormally == true`（正对照，防"改成永不发送"），
  再把 `chat_actions` 改名让读失败，随后必须 false。
- 扫描：读失败那一轮返回 nil 之后，把表改回来再扫，**必须仍然看到那两条未回消息** ——
  这条才是"没有把水位推过去"的证据，不是断言函数返回值。
- 三条变异（门禁回退成 `?? false` / 剪枝不接线 / 扫描改回吞错读）各红 1 条，且都用
  **能编译**的变异；前一版我把整个 `guard` 块替换掉导致编译失败、测试静默不跑，
  已在下面记成流程教训。全量 2150 XCTest（+4）+ 70 swift-testing 绿。

流程教训（本轮又两次）：变异实验必须"改完还能编译"，并且要看到**你新写那条断言的失败行**；
`grep` 只匹配 `error: -[` 时，编译错会让整轮"看起来 0 failures"。

## §237 第 9 轮：三张准入规则表读不到＝「没有规则」，既放行被静音的人，又删掉待分析的行（P0，已修）

`AdmissionRules.load` 的四个输入里有三个走吞错读：`loadGroupMemberMap`、
`loadIgnoredSenderMap`、`loadGlobalIgnoredSenders`（全部经 `queryAll`，`try?` 把 prepare/step
错变成 `[]`）。已有的 `followingUnreadable` 旗标只覆盖关注列表，所以**规则表读失败不举任何旗**，
而 `[]` 在两个方向上都是破坏性的（`AdmissionPolicy.decide`:72-80）：

- `senderIsMuted` 变假 ⇒ 用户全局/按群静音的人，消息被放行、弹横幅、进自动回复；
  这正是 §236 那条 P0 的另一张表。
- `senderIsWatchedMember` 变假 ⇒ **已关注群里的被关注成员**消息落到
  `.suppress(.notFollowed)`，分类 worker 据此 `.retire` 删掉队列行（唯一记录），
  同一事务 `ScanEngine:821` 又无条件 `setWhitelistCursor` ⇒ 这批消息永不再被扫。

修法：`HUDStore` 补 `groupMemberRulesRead()` / `ignoredSendersRead()` 三态读；
`AdmissionRules` 增 `rulesUnreadable`，并把「负面裁决能不能删工作或推水位」这一问收成一个
`scopeUnreadable`（= 关注列表或规则表任一读不到）；退班判定与水位两处消费点都改问它。
`loadIgnoredSenders` 等旧函数保留给展示型调用点（它们最坏只是列表少一项）。

判据 5 条，两条是端到端：
- `AdmissionRuleReadHonestyTests`：空表 ≠ 读不到（正对照，否则旗标会永久压住水位）、
  两张表各自读失败都举旗、被静音的人确实不放行、`dispositionForUnadmitted` 在
  `scopeUnreadable` 下返回 `.retry`。
- `AdmissionRuleWatermarkTests`：规则读不到那一轮之后，恢复表再扫，那两条消息
  **仍须出现在 `newInboundForClassifier` 里** —— 这是水位敏感的断言，
  变异（把旗标钉死 false / 去掉水位守卫）都得到 `("0") is not equal to ("2")`。
- `ClassificationQueueWorkerTests.testUnreadableGroupRulesKeepTheQueueRowForRetry`：
  真跑一次 worker。第一版我把群设成"未关注"，结果被 `scopeVerdict` 合法退役，测试以
  `("0")!=("1")` 红给我看，说明我把不可达的场景当成了缺陷；改成"已关注群里被关注的成员"
  才是可达形状。**并且这条才是补上 Mc 漏洞的那条**：先前我只直接调
  `dispositionForUnadmitted(...)` 传旗标，变异（worker 仍传 `followingUnreadable`）
  全绿 —— 记忆里的「接线断言不算行为测试」今天第三次生效。
变异：Ma/Mb/Mc 各红（Mc 只在端到端那条存在时才红）。全量 2155 XCTest（+5）绿。

## §238 第 9 轮：每次启动都会跑的 VIP 对齐修复，把读不到的分类写成「其他」（P1，已修）

`repairVIPTrackingAlignment()` 由 `HUDStore.open()`(:152) 调用 ⇒ 每次启动、每次换号必经。
它用 `getWhitelistEntry`（`queryOne`，出错即 nil）取现有行，再以
`category: existing?.category ?? .other` 喂给整列覆盖的 `upsertWhitelistTracking`
(:2502 `DO UPDATE SET display_name/is_group/category/attention_level`)。于是「这次读不到」
被回答成「这人没有分类」，把用户自己归的 工作/生活 静默改成 其他；`guard existing?.attentionLevel
!= .vip` 同样在 nil 上放行，整行都可能被重写。

修法：补行级三态 `whitelistEntryRead()`（复用已审的 `whitelistRead` 做存在性判断，
"行在但解不出"归 `.unreadable`），`.unreadable` 时**这一行完全不动**；`.absent` 仍按联系人
建行（那是这个修复存在的理由）。读函数作为参数注入，生产调用点签名不变。

判据：`VIPAlignmentRepairHonestyTests` 3 条 —— 可读写入时分类必须保留（今天也成立，用来
钉住语义）、读不到时分类与档位都不许变、确无行时仍要建得出跟踪行。反向变异（把
`.unreadable` 折进 `.absent`，即旧的 `?? .other` 形状）红 2 条：
`("other") is not equal to ("work")` 与 `("vip") is not equal to ("watch")`。
全量 2158 XCTest（+3）绿。

## §239 第 9 轮：对话记忆「读不到」被当成「还没有记忆」，整列覆盖掉 90 天滚动摘要（P1，已修）

`loadConversationMemory`(:3522) 走 `queryOne`（出错即 nil）。`ConversationMemoryUpdater` 拿它
做两件不可逆的事：(1) 新鲜度门禁 `if let existing = …` —— nil 即"不新鲜"；(2) 合并输入
`oldMemory?.summary ?? ""` —— nil 即"以前什么都没发生过"。而 `upsertConversationMemory`(:3496)
是 `DO UPDATE SET summary=excluded.summary, key_topics=…, pending_items=…` 的整列覆盖，
新摘要只由**最近 30 条**生成 ⇒ 一次读失败就把 90 天滚动摘要连同 topics/pending items
一起换成短版本，且不会自愈。

修法：`HUDStore.conversationMemoryRead(_:)` 三态（复用存在性 SELECT；行在而解不出算
`.unreadable`），把决策抽成纯函数 `ConversationMemoryUpdater.memoryRebuildDecision(prior:stalenessSeconds:now:)`
（`.skipFresh / .skipUnreadable / .rebuild`），`.unreadable` 优先于陈旧判断直接不重建；
旧记忆从同一次读取复用，不再二次查询（两次查询可以给出不同答案）。
读函数按参数注入，生产调用点签名不变 —— `AIService` 是具体类、协议里没有
`isConfigured()`，所以 actor 内部无法用 Mock 驱动模型调用，本轮把可测面收在
"读出的 prior + 决策函数"这一层，并如实记录：**actor 里那一行 switch 的接线没有行为级
判据覆盖**（要补得先把 updater 的 AI 依赖换成协议）。

判据：`ConversationMemoryRebuildHonestyTests` 5 条 —— 三态可辨（真注入：改表名让读失败）、
读不到时决策必须是 `.skipUnreadable`、可读写入时 `.rebuild`（正对照，防止旗子等于永不更新）、
新鲜时仍限流、被跳过的那一轮之后库里的摘要原样还在。反向变异（删掉 `.unreadable` 那一行，
即旧的 nil 兼两意）红 2 条：`("rebuild") is not equal to ("skipUnreadable")`。
全量 2163 XCTest（+5）绿。

## §240 更正：`2bb9e3df` 提交进去的是一棵编译不过的树（判据 5 条里那 2 条当时根本没跑）

上一条 §239 的"全量 2163 绿"当时并不成立。成因是我自己的两个错误叠起来：

1. 变异实验后用 `cp /tmp/fixed9/ConversationMemoryUpdater.swift` 恢复 —— 但那份备份是在
   **抽出 `memoryRebuildDecision` 之前**存的，于是恢复动作把被 §239 依赖的那个函数一起删掉了
   （同一族第二次：备份方向 / 恢复后不复核关键行）。
2. 随后的收尾命令是 `swift test 2>&1 | grep -E "Executed …|failure" | tail -4 && … commit`。
   编译失败时 `swift test` 的输出里没有一行匹配我的 grep，管道退出码取的是 `tail` 的 0，
   `&&` 于是照常往下走 —— 我把"什么都没打印"读成了"跑过了"。这条管道掩码是"0 failures
   的三类假绿"之外的第四类：**管道末位命令的退出码冒充了被测命令的**。

后果：`2bb9e3df` 的测试树编译不过（`type 'ConversationMemoryUpdater' has no member
'memoryRebuildDecision'`），本提交把它修好；现在用 `set -o pipefail` + 显式
`TEST_EXIT=$?` + 真实用例计数三条一起看，才允许自己写"全绿"。
本轮实测：2163 XCTest + 70 swift-testing，`TEST_EXIT=0`。
§239 里"反向变异红 2 条"的结论仍然有效（那一步是在完好树上做的，失败行是我新写的断言），
但其后那次恢复把它带坏了 —— 结论没错、提交错了，两件事都要记。

## §241 第 9 轮：准入设置也是同一份快照的第四个输入，读不到＝解掉用户的 @ 静默（P1，已修）

§237 补的旗标漏了 `AdmissionRules.config`：`loadAdmissionConfig()` 是
`getSettingJSON("admission") ?? AdmissionConfig()`，而默认值是 `mode = .whitelistOnly` +
`atMutedGroups = []`。于是 settings 一次读失败会同时做两件用户没同意的事：把
`mode` 从 `.all` 收成 `.whitelistOnly`（该出现的对话不再出现），并**解掉所有
「@ 提醒静默」的群**（`shouldRaiseBanner` 少了那层抑制，@ 又开始弹横幅）。

修法：补 `admissionConfigRead() -> SettingRead<AdmissionConfig>`，`.unreadable` 折进
`rulesUnreadable`，因此沿用 §237 已有的两处守卫（退班判定与水位）而不再新增消费点。
`.corrupt` **有意不折**：半写的行是永久状态，为它无限期按住水位等于把"数据丢失"换成
"应用冻住"；它需要的是一个可见的「设置读不懂，请重存」入口，那是界面改动，单独排。

判据：`AdmissionRuleReadHonestyTests` 新增 1 条，三段：没设过配置 ≠ 读不到（否则旗标会
永久压住水位）、设过的 `atMutedGroups` 确实读得到、settings 读失败 ⇒ 举旗且**恢复后旗标落下**
（防一次失败钉死）。反向变异（去掉 `|| configUnreadable`）红 1 条。
全量 2164 XCTest + 70 swift-testing，`TEST_EXIT=0`（pipefail + 真实计数，见 §240）。

## §242 第 9 轮：标 VIP 不再读改写整行（P1，已修 —— 用"根本不读"消灭歧义）

`ChatMonitor.updateWhitelistAttention` 先前是 `getWhitelistEntry`（出错即 nil）→
`existing?.displayName ?? 调用方给的` 等四个 `??` → `addToWhitelist` 整行覆盖。于是"给某人
标 VIP"这一次点击，在恰逢读失败时会顺手改掉显示名、私聊/群、以及用户自己归的 工作/生活。
与 §233/§238 同形，差别在于这次不必补三态旗标：**这个读本来就不需要**。

新 `HUDStore.setWhitelistAttentionLevel(_:username:)` 只 `UPDATE whitelist SET attention_level=?`，
`false` 因此精确表示「这行确实没有」（SQLite 计的是被 UPDATE 匹配到的行，值相同也算），
写失败则**抛出**而不是回答 false —— 否则调用方会把它当成"没有这行"再插一条。只有确无行时
才用调用方的值插入（那时没有可保留的东西）。

判据：`WhitelistAttentionFlipTests` 3 条 —— 调用方传来的显示名/群标记/兜底分类一个都不许
落到既有行上（只有档位变）、确无行时仍按调用方值建、以及**语句失败必须抛而不是返回 false**
（反向变异：把 `try withCachedStatement` 换成 `try?` ⇒ 第三条红
「did not throw an error」，前两条仍绿，说明它测的正是那条歧义）。
全量 2167 XCTest + 70 swift-testing，`TEST_EXIT=0`。

## §243 第 9 轮：设置 blob 的「读不到→用默认值整行写回」（P1，已修 4 个写点）

`getSettingJSON("sync") ?? SyncConfig()` 再 `setSettingJSON("sync")` 是整行覆盖
（`setSetting` → `INSERT OR REPLACE`）。settings 一次读失败，`persistRoot` /
`persistKeysPath` / `bindLegacyRecords` / 预览态的显示器切换就会把**账号根目录、keys 路径、
同步间隔、缓存与显示偏好**一起复位成出厂值，而界面报「已保存」。

修法：`HUDStore.updatingSettingJSON(_:as:fallback:mutate:)` —— 与已修的
`updateAutopilotConfig` 同一条规矩：`.unreadable` 直接返回 nil（一个字节都不写），
`.absent`/`.corrupt` 才用默认值；调用点拿不到值就抛，走既有的
「连接设置没有保存成功，请重试。」通道，而不是静默保存错的东西。
`SyncSettingsView.save()` 复核为**不在此列**：它 `guard didLoad`，且写入的是表单自己的字段，
`previous` 只用来算 `needsRestart`。

判据：`SettingsMergeWriteTests` 4 条 —— 合并保留调用方没碰的字段（间隔/keys 路径不丢）、
读不到时返回 nil **且库里的原值一字未动**、首次安装（`.absent`）仍存得进去，加一条
反回潮闸：扫描"在 5 行内 `?? SyncConfig()` 之后紧跟 `setSettingJSON("sync"`"。
闸门第一版写成了「文件里不许出现 `?? SyncConfig()`」，被两处**只读**的表单初值判红 ——
作用面比管控对象宽，已收窄成只查这一对读写（§224 同族教训）。
两条变异：把旧形状塞回一个视图 ⇒ 闸门红；把 `.unreadable` 改成走 fallback ⇒ 行为判据红。
全量 2171 XCTest（+4）+ 70 swift-testing，`TEST_EXIT=0`。
