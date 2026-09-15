# Evolution Log

> 项目自我进化日志，PM 和工程师双方追加

## 2026-09-15 — 1.5.3：全局 UI 大布局统一对齐与 AI 聊天总结上下文时序修正

### [Engineer] 修复跨天陈旧消息混入总结，修正多项 AI 提示词与上下文缺陷，重构工作台大布局统一对齐

- **群聊总结防跨天混淆与对话连续性修复**：
  - 重构 `GroupContextSourceLoader`，废弃原先纯靠消息条数的滑动窗口机制，引入对话连续性检测（连续静默超 6 小时自动截断会话跨度），彻底根绝静默群中几天前的旧陈旧发言混入今日 @ 总结的致命逻辑缺陷。
  - 升级群聊分析缓存版本至 `action_panel_group_v4`，同步优化 `group_analysis_v1` 提示词引导模型区分历史对话与当前连续语境。
- **全局 AI 提示词与上下文审计完善**：
  - 修复回复建议在找不到精准目标消息时盲目 fallback 到最新消息导致的借尸还魂错位。
  - 修复消息撤回分析只读撤回后 10 条的单向缺陷，重写为跨越撤回事件前后的对称上下文检索。
  - 新增 `PromptWiringTests` 静态校验全站 28 个 Prompt 模板 107 个占位符的匹配完整性。
- **全站 UI 布局统一规范（WorkspacePageLayout）**：
  - 统一定义全站工作区两大宽度家族（双栏工作台 1180pt、单栏表单阅读 960pt）与统一左边距（28pt），彻底消除页头与正文、子页面间左缘参差不齐的问题。
  - 页头由居中改为左对齐，标题与正文左缘严格重合；统一全站工作区底色（温润 canvas）。
  - 待办筛选胶囊引入 `ViewThatFits` 自适应单双行兜底，避免 900pt 极窄窗口下胶囊内容被截断或换行折断。
- 验证：全量 1608 个 XCTest + 70 个 Swift Testing 测试全绿；Developer ID 严格签名打包。

## 2026-09-15 — 1.5.2：流光连续巡轨循环、一键清空与工作台底部状态栏沉底固定

### [Engineer] 修复流光动画不循环，补齐待办/承诺一键清空与撤销，修复工作台空态布局断层

- **浮岛流光动画（IslandLoadingSweep）重构**：
  - 彻底废弃在 10:1 扁平长条带刘海切口的轮廓上使用中心旋转 `AngularGradient` 的做法（导致 90% 夹角射向屏幕外/刘海内部而产生卡死不循环假象）。
  - 重写为基于真实轮廓周长（Perimeter Arc-Length）的连续循轨光束，14 级彗星尾迹渐弱与模糊，物理级 0.0 ~ 1.0 无缝循环。
- **待办与承诺增加「一键清空」闭环**：
  - 「待办」页与「我答应的事」页在有未完成项时提供显式「一键清空」按钮，带模态防误触确认。
  - 支持清空后底部回执一键「撤销」还原；`ChatMonitor` 补齐批量更新接口。
- **修复工作台第二页面空态 UI 错位与底部状态栏浮动**：
  - 为工作区 `content` 补充 `maxHeight: .infinity` 纵向占满约束，保证底部状态栏（`WorkspaceStatusBar`）永远沉底固定在窗口最下边缘。
  - `emptyState` 改为撑满可用空间垂直居中对齐，背景色无缝铺满。
- 验证：全量测试套件全绿（新增巡轨测试）；Developer ID 签名打包通过。

## 2026-09-15 — 1.5.1：前端全界面视觉精修与主题色对齐

### [Engineer] 浮岛展开操作质感重构，各模块按钮/指示器对齐房间强调色

- **浮岛展开面板（ActionPanelView）质感升级**：
  - 主操作「查看上下文」从生硬直角的系统蓝（`Color.accentColor` + `.cornerRadius(6)`）重塑为 `CompanionPalette.jade` 胶囊，加入 0.5pt 高光发丝描边与微压反馈（`CompanionPressStyle`）。
  - 次操作「生成回复」统一为 `IslandInk.chip` 胶囊；回复建议改为平滑圆角（`style: .continuous`），推荐项微光浸润，去除硬蓝色块。
  - 解读卡片背景由粗颗粒蓝底改为纯净温和的低饱和暗色半透明面（`Color.white.opacity(0.04)` + `strokeBorder(0.08)`）。
- **工作台各模块按钮与交互色闭环**：
  - 待办（Tasks）模块主按钮「标记完成」、更正/原文链接与选中行边框统一对齐专属生产力蓝（`Tab.tasks.accentColor`）。
  - 草稿（Drafts）模块「继续回复」主按钮、选中指示坚条与编辑器外边框统一对齐专属靛蓝（`Tab.drafts.accentColor`）。
  - 聊天回顾（Insight）模块「重新分析」主按钮、时间线与解读标签统一对齐专属紫（`Tab.insight.accentColor`）。
  - 今日（Today）模块消息卡片主操作「理解上下文与回复」对齐主站翡翠绿（`CompanionPalette.jade`）。
  - 承诺与日报模块「标记完成」与「导出」按钮分别对齐各自模块强调色。
- **底层密钥材料与连接诊断完善**：
  - 密钥文件权限检测改为动态计算属性，新增 `looseKeyPermissions` 明确指引（`chmod 600`）。
  - 密钥内容寻址支持 schema-2 salt 表，容错未识别格式。
- 验证：全量测试套件通过（1592+ XCTest，70 Swift Testing，0 失败）；release 构建零警告。

## 2026-09-14 — 1.4.0

### [Engineer] 版本号 1.4.0，界面与 1.3.8 相同

- 自动回复默认关，护栏未改。

## 2026-09-13 — 1.3.8：全界面视觉交互精修

### [Engineer] 动效、字号、文案收成一套原生小尺寸语言

- 展开/收起走同一组弹簧：展开略带回弹，收起更干脆；Reduce Motion 时动画为 nil，状态仍切换。按压缩到 0.96 / ~120ms，悬停洗层 100ms。
- 工作台标题从 30pt 收到 17pt；岛面、设置、分析、引导页的大标题收到 15–17pt。可读文字不低于 10pt。
- 用户可见「白名单」改为「关注 / 已关注」。侧栏副标题缩短。群聊只记草稿、snooze、发送确认、相对时间词表未改。
- 验证：精修相关 91 项用例两遍全绿；ImageRenderer 岛面与工作台均有墨迹。已签名并通过 Apple 公证（Notarized Developer ID）。

## 2026-09-13 — 1.3.7：查看新消息把岛面撑成 720pt 黑板

### [Engineer] 菜单入口打开收件箱，但测量把 grow-only 窗口当成了内容高度

- 点菜单「查看新消息」以前只 silent scan，收件箱要靠悬停展开才会出现；现在会刷新并打开收件箱。
- GeometryReader 若量到 720pt 上限（覆盖窗口而不是列表），不再写入 lastExtendedSize，下次打开也不会按 720 缓存去动画。已经撑开的黑板会收回上次真实内容高度。
- 收件箱改成和通知横幅一样：先量 intrinsic，再 stretch 填 stage。
- 收件箱在指针正下方打开时，第一行不再立刻露出稍后/关闭，避免看起来像一张没拆掉的通知横幅。

## 2026-09-13 — 1.3.6：Keychain 密钥 / 串行存储 / 关系雷达

### [Engineer] 合入 overnight PR #5，发第一版把安全与存储地基收进来

- API Key 离开 SQLite：两阶段写入 Keychain（写后读回才清明文），迁移失败保留原值。`~/.wechat-hud` 目录 0700、文件 0600。远程 `http://` AI 端点 fail closed，loopback HTTP 保留。Codex `auth.json` 拒绝符号链接 / 错误属主 / 宽于 0640。AI 审计默认只留 `sha256:` + 脱敏片段（`WCHUD_AI_AUDIT_RAW=1` 才存原文）。
- HUDStore 增加串行队列与 `PRAGMA user_version` 迁移（v2 关系雷达表、v3 回顾索引）。白名单 / sync_state / contacts / chat_actions / 草稿 / autopilot_log / classification 等热路径读全部改走 `queryOne`/`queryAll` + 语句缓存，扫描不再 `Task.detached` 抓 store。
- `WeChatReaderActor` 门面接管扫描准备、会话、批量消息、白名单分页、Insight 读写、群上下文、按需分析、承诺 / 回溯上下文、详情转写与收件箱摘要等读路径；Scanner 一次 pass 内批量读消息，分片 / handle 缓存只热一次。
- 工作台「回顾」多一页「关系雷达」：跨天态度 / 语气 / 沉默 / 关系趋势，转淡与沉默排前面；扫描成功后离主线程确定性重算快照（15 分钟节流），不调 AI、不发微信。单天分析仍然没有 attitudes / tone_changes / mood_shift。
- 自动驾驶护栏未改：默认关闭（`autoSendEnabled=false`）、阈值 0.8、敏感词二级拦截、媒体 0.7x 衰减、金融类强制 pending、群聊（含 @）一律人工确认、会话上限 50。补了驱动真实 `handleNewMessages` / `executeSend` 的行为测试。
- 验证：合并 `main` 后全量 `swift test` + release 构建；已签名并通过 Apple 公证（Notarized Developer ID）。




### [Overnight] 2026-09-13 Slice 21 — commitment + recall context via WeChatReaderActor
- ChatMonitor self-outgoing commitment tracking and recall analysis fetch context through actor
- Tests 1522+70 green





### [Overnight] 2026-09-13 Slice 17 — ChatMonitor on-demand → WeChatReaderActor
- OnDemandAnalysis + Classification async reads/identity via actor; hasAccountSwitched wrapper
- GroupContextSourceLoader still sync provider (debt); Autopilot unchanged
- Tests 1522+70 green

### [Overnight] 2026-09-13 Slice 16 — InsightStore bulk load via WeChatReaderActor
- Actor bulkMessageStats + async InsightDataLoader.load; InsightStore reload/day priming via actor
- Sync load/statsForDay kept; ChatMonitor still debt; Autopilot unchanged
- Tests 1522+70 green

### [Overnight] 2026-09-13 Slice 15 — Insight→WeChatReaderActor / batch
- ChatInsightService + InsightCoordinator day probe/stats via actor; whitelist today-filter uses messagesBatch
- InsightStore.bulk load still direct reader (debt); Autopilot unchanged
- Tests 1522+70 green

### [Overnight] 2026-09-13 Slice 14 — whitelist paging + ReplyDebt via facade/batch
- WeChatReaderActor.getMessages used for whitelist first page + backfill
- ReplyDebt seeds use getMessagesBatch (no per-session getMessages in ScanEngine)
- Tests 1522+70 green





### [Overnight] 2026-09-13 Slice 13 — WeChatReaderActor facade
- New WeChatReaderActor: prepareForScan / sessions / refresh / messagesBatch
- ScanEngine.performScan hops prep + unread/autopilot batch through actor
- Tests 1522+70 green





### [Overnight] 2026-09-13 Slice 12 — WeChatReader getMessagesBatch
- Extracted getMessagesLocked; batch API holds one lock across chats
- ScanEngine unread + autopilot loops use batch (fewer lock hops)
- Test WeChatReaderBatchMessagesTests; 1521+70 green





### [Overnight] 2026-09-13 Slice 11 — ClipboardGuard @MainActor
- Moved ClipboardGuard into Utilities; pasteboard save/restore MainActor-only
- Autopilot serialSend awaits save/restore (no detached restore Task race)
- SavedState @unchecked Sendable; restore only on MainActor
- Tests 1520+70 green; release pass









### [Overnight] 2026-09-13 Slice 10 — OffMain account evidence + v2→v3 test
- Sources path clear of Task.detached capturing app state
- Tests 1520+70 green

### [Overnight] 2026-09-13 Slice 9 — OffMainWork + schema v3 indexes
- Contact recommendation scan drops Task.detached
- Retrospective query indexes via SchemaMigrator v3 (post-table)
- Tests 1519+70 green

### [Overnight] 2026-09-13 Slice 8 — Autopilot writes via statement cache
- insertAutopilotLog / upsertPendingSend / enqueueAutopilotInbound
- HUDStore hot-path direct prepares cleared; tests 1518+70 green

### [Overnight] 2026-09-13 Slice 7 — DiscussionQueue on serial query helpers
- Dropped rawDB prepare path; throwing query helpers preserve corrupt-row errors
- Tests 1518+70 green

### [Overnight] 2026-09-13 Slice 6 — VIP/recalled/audit/asks on query cache
- Fixed-SQL variants for filtered audit/feedback/asks loaders
- Autopilot guardrails unchanged; tests 1518+70 green

### [Overnight] 2026-09-13 Slice 5 — more HUDStore readers on query cache
- ignored/dismissed/asks/cache/memory/timing/pending sends/profiles + open autopilot pending variants
- Autopilot guardrails unchanged; tests 1518+70 green

### [Overnight] 2026-09-13 Slice 4 — HUDStore drafts/autopilot/classification + statement-cache reset
- Readers moved onto `queryOne`/`queryAll` serial path
- Fixed cached `queryOne` leaving SQLITE_ROW and pinning read txn (due_at migration tests)
- Autopilot guardrails unchanged
- `swift test` 1518+70 green; release build pass

## 2026-09-13 — Overnight PR#5：关系雷达独立页 + HUDStore 热路径串行化

### [Engineer] Wave C 收尾 + Wave B 再推一段

- 工作台「回顾」多了一页「关系雷达」：跨天态度 / 语气 / 沉默 / 关系趋势，转淡和沉默排前面。单天分析仍然没有 attitudes / tone_changes / mood_shift。
- 扫描成功后离主线程重算雷达快照（15 分钟节流）；单聊分析写入日事实后立刻刷新该会话。刷新是确定性计算，不调 AI、不发微信。
- HUDStore 白名单 / sync_state / contacts / chat_actions 读路径改走 `queryOne`/`queryAll`，进入同一条 Swift 串行队列。草稿、autopilot_log、classification_queue 仍是直接 prepare，下一刀再迁。
- 空 `overallMood` 时 `1..<moods.count` 会 `Range` 崩溃；扫描刷新会走到这条路径，已改成 `moods.count >= 2` 才算语气变化。
- 自动驾驶护栏未改。

## 2026-09-13 — Overnight：Keychain / 串行存储 / 关系雷达

### [Engineer] 安全 P0 + 存储地基 + 关系雷达初版

- API Key 离开 SQLite：两阶段写入 Keychain（写后读回才清明文），失败保留原值。`~/.wechat-hud` 目录 0700、文件 0600。远程 `http://` AI 拒绝，localhost HTTP 保留。Codex `auth.json` 拒绝符号链接 / 错主 / 宽于 0640。AI 审计默认只留 hash + 脱敏片段。
- HUDStore 增加串行队列与 `PRAGMA user_version` 迁移（v2 = 关系雷达表）。扫描不再 `Task.detached` 抓 store。
- 关系雷达：跨天态度/语气/沉默/趋势；单聊分析仍然没有 attitudes / tone_changes / mood_shift。简报 prompt 可吃雷达摘要。UI 是 insight 页上的 stub。
- 自动驾驶护栏默认值未动。补了 `handleNewMessages` / `executeSend` 真链路测试（群聊人工确认、媒体 0.7x、敏感词、会话上限 50）。
- 验证：本环境是 Linux，未跑 `swift test` / release 构建。用例写在 `SecurityRegressionTests` / `CodexAuthSecurityTests` / `HUDStoreConcurrencyAndMigrationTests` / `RelationshipRadarTests` / `AutopilotGuardrailPipelineTests`。
- 细节见 `docs/overnight/2026-09-13-morning-report.md`。

## 2026-09-13 — 1.3.5：对话窗口与回复建议

### [Engineer] 点进去要看到最新消息，不能替用户决定接种

- 详情页对 newest-first 的 `recentMessages` 取了 `suffix(4)`，把下午 12:40 的 @ 切掉，只留下上午订房和表情。改为取最近窗口再翻成微信顺序（旧上新下），打开滚到最新；群 @ 昵称里的 U+0489 装饰符只在展示时剥掉。
- 详情顶栏另一条会话的「查看」只 `goExtended()`，状态切换会清掉展开行。现在 `revealInboxItem` 在回到收件箱之后再展开被提醒的那一行。
- 「打开群聊回复」和点建议会进浮窗对话工作台并带上草稿，不再直接把微信拉到前台粘贴。
- 疫苗 / 医疗类来源不允许推荐「需要接种 / 不接种 / 已接龙」。未表态时只留「我确认下再回你」。生成时和展示时都过同一道门，避免缓存里的旧建议漏网。
- 验证：`MessageHelpersTests` / `ReplySuggestionSafetyTests` / `DetailNoticeTests`。

## 2026-09-13 — 1.3.4 发布前：peek 弹簧与质检 P1

### [Engineer] 悬停加宽不能瞬切；已读不回不能在没开托管时去前台

- Peek 同高加宽若走 `setFrameInstantly`，会 `cancelFrameAnimation` 掐掉 mask spring。测量 sink 改由 `IslandMeasurement.sizeAction` 决定：peek / 已离开刘海的状态一律弹簧；compact 只有真正从更高岛收回才动画，同高宽变若是 peek 量级（>48pt）也不瞬切。
- 光晕画真实刘海轮廓，30Hz 扫光只给「整理中」，VIP 只变色相。菜单把 peek 当收起，不预热收件箱。
- 已读不回 / 重复缓兵打开微信窗口按发送闸：未开自动发送、群聊都不去前台。无 scheme 的远程 API 默认 https，loopback 仍 http。群筛选出网前把群名编成代号、样本走 Redactor。网页更新通道不再把 `-rc` 当正式版；启动时清掉 sqlite 里旧的 githubToken。
- 验证：`IslandPeekTests` / `IslandRowExpandTests` / `AutopilotSafetyTests.testReadReceiptOpenChatGate` / `AIServiceBaseURLTests` / `AppUpdateServiceTests` 的 prerelease 与 token scrub。

## 2026-09-13 — 收件箱行展开空板 + 点击动画

### [Engineer] 点一条记录后岛面多出一大块黑；展开没有动画

- 根因：`InboxView` 的 `.frame(width:)` 放在 `.fixedSize(vertical: true)` 之后，GeometryReader 读到的是 grow-only stage 的提议高度，不是列表本身。点击重测一次就把 lastExtendedSize 毒成窗口高，岛在短列表下面留出黑板。
- 另一个根因：根视图 `.transaction { animation = nil }` 把行内展开也杀了，ActionPanel 突然出现。改为只对 `presentedState` 禁用隐式动画；行展开跟岛的 openMorph 弹簧走同一套物理（codex-island detailReveal）。
- 同一时间只展开一行；忽略等于 covering stage 且明显高于上次真实内容的测量。

## 2026-09-13 — Codex Island 状态位 / 初展开 / 边框动效

### [Engineer] 把codex-island 的 peek 三态与边框编舞接进现有 mask spring

- 对照 [codex-island](https://github.com/ericjypark/codex-island) @ `1a0634d2`：悬停不直接开收件箱，先 morph 到 `.peek`（同高、两侧 +78pt glance 槽），180ms dwell 或点击再进 `.extended`。边过刘海只看到一下小开口。
- 边框：离开 compact 后 0.5pt 白发丝线；VIP 紧急光晕只变色相（琥珀 / 红）；AI 整理中 30Hz 锦 sweep。Mask 角用 `.continuous` squircle。
- 不改窗口架构：仍是固定 stage + CALayer mask spring。`goExtended()` / 菜单点击仍直达收件箱。
- 验证：`IslandPeekTests` + `swift test --filter IslandPeekTests`.

## 2026-09-13 — 动效收口：合成器遮罩 + 物理曲线

### [Engineer] 参考 codex-island，重构面板形态动画并实测收敛

- 参考 [codex-island](https://github.com/ericjypark/codex-island)（同一个"吸顶岛"问题域的成熟实现）后移植三件事：强 ease-out 内容曲线、shape 先提交/内容后到的编舞、窗口鼠标穿透与可见形状分离。
- 根因（实测而非推测）：展开时窗口 frame 从 128×32 放大到 560×252，这一次 resize 落在动画路径上；收起时覆盖范围不变、从来不 resize，所以收起一直是干净的 16.7ms。
- 改法：引入只涨不缩的 island **stage**，窗口一次铺到最大需求尺寸，展开/收起全部由 `CALayer` mask 在合成器上完成；窗口在动画期间 0 次 resize。
- 仪器：新增 `--preview-cycle=N`，循环完全在应用内驱动，**不移动操作者光标、不需要第二块屏**，动画质检因此可重复。
- 实测（主屏，10 轮循环，466 帧稳态）：平均 **16.83ms**，>20ms 的帧 6 个（1.3%），worst 33.3ms，`slowStep` 0 次，`stageGrow` 0 次。
- 反面收获记录在案：中途加过一版"同步首帧"，实测把 display link 的启动延迟伪装成第 0 帧掉帧，已回退——只信 trace，不信直觉。
- 验证：`swift test` 1437 用例 0 失败 11 skip。

## 2026-09-12 — 全状态精修与性能收口

### [Engineer] 逐状态体验 + 四路只读审计 + 分文件所有权并行实施

- 质检通道：隔离预览进程 + computer use 元素级操作。发现元素点击会带动真实光标后，改为新增 `--preview-hold-island` / `--preview-disconnected` / `--preview-tab=<page>` 启动旗标，实现零鼠标移动的状态/页面截图。
- 实机抓到并修掉 12 类缺陷，含：断连文案重复「上次同步 N 分钟前同步」、草稿页页头压列表、草稿按钮行裁掉主操作、群聊误标私聊、关注谁 inspector 列被裁、日报显示裸账号名、预览工具条竖排单字、引导 3 点 2 页、预览捕获泄漏 popover 闩锁导致永不收起、预览通知时长 900s 泄漏。
- 性能：心跳等值短路与降频、摘要取数移出主线程、预取限制可见前 3 条、SQL 语句缓存、去掉失效 CAST 谓词、扫描复用 session 快照、归档节流、manifest 去抖、PixelBuddy Canvas 化与停表。
- 算法：4 处会 trap 的 `Dictionary(uniqueKeysWithValues:)` 改为保留先到者；排序补 tiebreaker；回复债务锚点改为「最近一条未被实质回应的入站」，修掉 ack 吞正事与群 @ 被后续闲聊覆盖两类漏判。
- 验证：`swift test` 1368 用例 0 失败 10 skip；实机矩阵覆盖深/浅色、各状态、各页面、无障碍开关。
- 记录见 `docs/qa/2026-09-12-state-refinement-audit.md`。

## 2026-04-12

### [PM] 项目评估完成
- Phase 1 全部 12 个 task 已完成，代码量 ~17,500 行
- 识别三个进化方向: 测试补全(P0) → ChatMonitor 重构(P1) → AI 健壮性(P2)
- 建立 PM ↔ Engineer 通讯协议

### [Engineer] 首次报告 — 纠正 PM 评估
- 项目已有 117 个 XCTest 全部通过，非 0 个
- "0 tests in 0 suites" 是 Swift Testing 框架独立报告，不代表无测试
- 识别真正的覆盖率空白: HUDStore 38%、ChatMonitor 0%
- 提出先拆分 ChatMonitor 再补测的策略

### [PM] Review 并调整指令
- 承认评估错误，接受工程师的纠正
- P0 范围调整: 从"从零补测"→"补充 HUDStore 未覆盖方法"
- P1 优先级提升: ChatMonitor 拆分与 P0 并行
- 批准 mock 加密 DB fixture 方案
- 新增 P0.5: WeChatDecryptor 端到端测试

### [Engineer] P0 HUDStore 测试补充完成
- 新增 33 个测试 (HUDStoreTests 12→45)，全项目 117→150 测试
- 覆盖 ChatAction/PendingAsk/Autopilot/AIAudit/Baseline/SenderIdentifier/Config
- **发现并修复 bug**: `currentAutopilotSession()` column index 偏移（2,3,4→3,4,5），导致 autopilot session 计数全部读错
- 等待 PM 确认下一步: P0.5 (WeChatDecryptor e2e) 或 P1 (ChatMonitor 拆分)

### [PM] P0 Review 通过，下发 P1 指令
- P0 关闭: 33 个新测试质量良好，column index bug 修复确认
- 指令: 直接进入 P1 ChatMonitor 拆分重构
- 目标: 1690 行 → 协调者 ≤400 行 + ≤5 个独立 service（各自带测试）
- 分步提交策略: 每拆一个 service 一个 commit

### [Engineer] P0.5 WeChatDecryptor e2e 测试完成
- 新增 8 个端到端解密测试（page 级 + full DB 级 + WAL + 边界）
- 用 CommonCrypto 构造合成加密页面，无需真实微信 DB
- 测试全部通过

### [PM] P0.5 Review 通过，确认进入 P1
- P0.5 关闭: 测试质量优秀，覆盖完整
- 项目测试安全网已建立: P0 + P0.5 共计 156 测试
- 正式启动 P1: ChatMonitor 拆分重构

### [Engineer] P1 拆分分析完成
- ChatMonitor 1690行分析: 6 个职责域，12 个已有独立 service
- 5 步拆分计划: MessageHelpers → ChatActionManager → Autopilot合并 → GroupContext合并 → ScanEngine
- 预计: 1690行 → ~550行协调器
- 关键技术约束: @Published + @MainActor 限制提取粒度

### [PM] 批准拆分方案
- 550 行目标可接受（vs 原目标 400 行）
- 原因: @Published/@MainActor 是真实限制，强压会增加 SwiftUI 绑定复杂度
- 指令: 按 Step 1→5 执行，不需要再等确认

### [Engineer] P1 Step 1 完成 — MessageHelpers 提取
- 提取 6 个纯函数到 MessageHelpers.swift (81行)
- ChatMonitor: 1690 → 1621 行（同时整理了 autopilot/service 属性声明）
- Build + test 通过

### [PM] Step 1 Review 通过
- MessageHelpers 是纯函数 enum，无副作用，提取干净
- ChatMonitor 增加的属性声明是合理的重构准备工作
- 继续执行 Step 2 (ChatActionManager)

### [Engineer] P1 Step 2 完成 — ScanEngine 提取 (原计划 Step 5)
- 跳到收益最大的提取: performScan + 后处理 → ScanEngine.swift (492行)
- ChatMonitor: 1621 → 1131 行 (减少 490 行)
- ScanEngine 设计: 纯函数 enum, nonisolated static, ScanOutcome 原子结果

### [PM] Step 2 Review 通过
- 调整执行顺序的判断正确: ScanEngine 是最大单笔收益
- ScanOutcome struct 设计优秀: 主线程原子更新 @Published，线程安全
- ChatMonitor 已从 1690 → 1131 行 (减少 33%)

### [Engineer] P1 深入分析 — 建议关闭
- 剩余 1131 行中，几乎所有代码都直接操作 @Published 属性
- @Published + @MainActor 是硬约束：属性 setter 必须在持有者类中
- 强行提取需要引入回调模式或新 ObservableObject，会增加复杂度不减少
- ChatMonitor 角色已从 God Object → Coordinator（scan 在 ScanEngine，工具在 MessageHelpers，12 个 AI service 独立）
- 建议 P1 关闭，进入 P2 (AI 响应健壮性)

### [PM] P1 关闭，下发 P2 指令
- P1 成果: ChatMonitor 1690→1131行(-33%), ScanEngine(492行) + MessageHelpers(81行) 独立
- 接受工程师判断: 剩余代码是 Coordinator 本职工作，不应强行拆
- P2 启动: AI 响应健壮性，从 ReplyDebtJudge 的 invalidResponseShape 开始

### [Engineer] P2 审计���成 — 项目质量超预期
- 11 个 AI service 全面审计: 10/11 已健壮
- 唯一真实问题: CommitmentTracker 默认值掩盖解析错误 → 已修复
- 关键发现: `invalidResponseShape` 是设计意图（防御��制），非 bug
- ReplyDebtJudge 已有完善的 audit + fallback 到确定性排序

### [PM] P2 关闭，第一轮进化完成
- P2 关闭: 审计充分，唯一问题已修复
- PM 反思: 项目代码质量比初始评估好得多，后续指令需更深技术验证
- **第一轮进化总结**: P0-P2 全部完成，+39 测���，1 个生产 bug 修复，架构改善
- P3 方向交给工程师提议（已建立信任）

### [Engineer] P3 方向提议: 实际运行验证
- 选择 [1] 实际运行验证 + [5] 工程发现
- P0-P2 都是读代码/写测试/重构，没有真正运行 app
- 计划: make app → 运行验证 → 修复发现的问题 → 工程改进(test report, audit prune)

### [PM] P3 方向批准
- 完全同意实际运行验证 + 工程改进
- 提醒: 运行���要真实微信环境，可能受限
- 信任工程师自主判断，按 Phase A→B→C 推进

### [Engineer] P3 Phase A+B 完成
- Phase A: app 构建运行正常，P1 重构无行为回归
- Phase B: 修复 10 个 deprecation warnings → 零警告构建; Makefile test output 改进

### [PM] P3 关闭 — 本轮进化全部完成
- P0-P3 全部关闭，任务队列清空

---

## 本轮进化总成果

| 指标 | 数值 |
|------|------|
| 新增测试 | +39 (117→156) |
| 生产 bug 修复 | 1 (autopilot column index 偏移) |
| 代码质量修复 | CommitmentTracker 解析强化 + 10 deprecation warnings |
| 架构改善 | ChatMonitor 1690→1131行, +ScanEngine(492行) +MessageHelpers(81行) |
| 构建质量 | Release build 零警告 |
| AI 服务审计 | 11/11 服务已验证健壮 |
| 协作模式 | PM ↔ Engineer 双向通讯协议验证成功 |
- Phase C: 运行中无新问题（两个旧 crash report 与本次无关）
- audit 自动 prune 已存在于 HUDStore.open()

### [PM] P3 关闭 — 两轮进化完成
- P3 Review 通过: 零警告构建 + 运行验证 + test output 改进
- **两轮进化总结**:
  - 第一轮(P0-P2): 质量 + 架构（+39 测试, 1 bug fix, God Object → Coordinator）
  - 第二轮(P3): 验证 + 工程实践（零警告, 运行无回归, 开发体验改善）
- 项目状态: 生产就绪，等待用户决定下一步方向

## 2026-09-13 Slice 18 — Group @ context via WeChatReaderActor

- Async `GroupContextSourceLoader.load(… readerActor:)` + ChatMonitor on-demand / inbox-summary callers
- Sync provider kept for briefing service + tests
- Tests: 1522 + 70 green; release OK; Autopilot guardrails unchanged

## 2026-09-13 Slice 19 — Briefing service via WeChatReaderActor

- `GroupContextBriefingService` production path uses `WeChatReaderActor`; sync provider kept for tests
- ChatMonitor wires `readerActor:` init; tests still use `reader:`
- Tests: 1522 + 70 green; release OK; Autopilot guardrails unchanged

## 2026-09-13 Slice 20 — InboxContextBuilder via WeChatReaderActor

- Async `InboxContextBuilder.build(… readerActor:)` + shared core; ChatMonitor inbox summaries await actor path
- Sync reader overload kept for compat; Autopilot guardrails unchanged
- Tests: 1522 + 70 green; release OK

## 2026-09-15 Slice 26 — 材质与光 / 错峰动效 / 交互文案分层

参考本机 CleanMyMac 5（真机点击取样，非记忆描述）：彩色模块方块侧栏、随模块变色的环境光、单一发光主按钮。

- 新增 `CompanionMaterial.swift`：一个从上往下的光源（顶边高光 + 面部浅渐变 + 单层柔影）、
  `CompanionBackdrop` 环境光、`CompanionModuleTile` 模块方块、`CompanionGlowButtonStyle` 发光主按钮、
  `CompanionStatusDot` 呼吸状态灯、`CompanionSectionHeader`。`CompanionSurface` 改走新面板 → 全站既有卡片一次性升级。
- `SettingsView.Tab.accentColor`：18 个模块各自的强调色，贯穿侧栏 / 页头 / 环境光 / 选中行 / 筛选胶囊。
- `CompanionMotion` 新增错峰入场（6pt / 45ms 步进 / 240ms 整组 / 封顶第 6 个）与 cardHover、sidebarSelection、pulse。
- 新增 `CompanionInteractionCopy.swift`：hover 承诺、等待态、空态、失败下一步、完成度。
  侧栏 18 行 hint 说明"这页干什么用"且与标签不同；同一串同时供 tooltip 与 VoiceOver。
- 修掉：toast 边框恒橙（成功态也戴警告框）、侧栏页脚压住滚动内容、待办筛选是手写副本、
  筛选胶囊全站品牌绿、卡片顶边高光有 trim 接缝、引导页/使用指南用原生系统字体、空列表只有劝退句、
  预览构建读正式钥匙串导致每次预览弹密码框（把整个界面挡在后面）。
- `docs/design/ui-language.md` 增「材质与光（v2）」；`docs/qa/2026-09-15-frontend-quality-pass.md` 为本次实测记录。
- Tests: 1555 green (11 explicit skips), 新增 CompanionMaterialTests 14 用例；release 零警告。
- 动画实测：peek/extended 形态弹簧 60.0 FPS，最差帧 17.06ms。
- 边界：走查跑在 `--preview` 演示数据；浅色外观抽查 3 页；浮窗展开态受抓帧时序限制未逐帧复验。

## 2026-09-13 Slice 22 — peer/trend/fulfillment via WeChatReaderActor

- Manual send receipt + lastPeerMessage + inferRelationship + chatTrend/relationshipStrength + commitment fulfillment hop through WeChatReaderActor
- ConversationDetailView no longer reads raw `monitor.reader` for send receipt
- Tests: 1522 + 70 green; release OK; Autopilot guardrails unchanged

## 2026-09-13 Slice 23 — detail transcript + discussion identity via WeChatReaderActor

- `recentMessagesAsync` + discussion-extraction identity hop through WeChatReaderActor; ConversationDetailView transcript/selfNames cached async
- Sync WhitelistScan `recentMessages` kept; Autopilot guardrails unchanged
- Tests: 1522 + 70 green; release OK

## 2026-09-13 Slice 24 — Autopilot message reads via WeChatReaderActor

- Autopilot `processBatch` / `verifySend` / `latestOutgoingMessage` / `stalePendingSendReason` / proactive last-msg hop through WeChatReaderActor
- Helpers made async where needed; guardrails + naming helpers unchanged
- Tests: 1522 + 70 green; release OK

## 2026-09-13 Slice 25 — contacts/sessions via WeChatReaderActor

- Actor contact wrappers + async ChatMonitor wechatContacts/activePrivateChatCandidates; ContactsSettingsView caches async-loaded candidates
- ChatNaming left as debt; Autopilot guardrails unchanged
- Tests: 1522 + 70 green; release OK

## 2026-09-15 Slice 27 — 质检测量：底色强度按可读性反解

把「像不像 CleanMyMac」从目测改成量：同一套采样代码量两边「最平的地面」的通道极差。

- 第一轮测出 **不达标**：参考 59.7，我们 8.0–16.0。模块底色弱到没人会注意到，
  即该功能自称的目的（切模块换房间）当时并未达成。
- 量参考为什么敢用 58：它地面相对亮度 0.058，其上 55% 白文字只有 2.9:1——**参考自己不合规**，
  它敢这样是因为色场上只放又亮又少的字。
- 因此抄结构不抄数字：**把落在底色上的字提亮**（`onWashSecondary()`），用提亮换回颜色额度。
- 地面亮度上限从「落在它上面的字必须过 AA」反解（`ambientLuminanceCeiling`）；
  强度再由**按通道极差归一化**与**亮度天花板**取最小值。
- 结果：**23.5–35.3**（原 8.0–16.0，参考 59.7）。实测渲染对比度页头 10.0–10.7:1、正文 11.7–16.5:1，AA 门槛 4.5:1。
- 修掉：浅色外观下 `onWashSecondary` 写死白色导致页头变白底白字（只有浅色截图会暴露）；
  同一透明度下琥珀房间比玉色房间强一倍多（30.9 vs 13.8）。
- 新增 3 条质量门，其中 AA 门第一次跑就拦下 4.389:1。
- Tests: 1559 green (11 explicit skips); release 零警告。
## 2026-09-15 Slice 28 — 按社区源码质检 HUD 浮岛

读了 `TheBoredTeam/boring.notch`（约 10.6k★）的 `ContentView.swift` / `NotchShape.swift` 全文，
及其来源 `MrKai77/DynamicNotchKit`。对照后修三处：

- **外形只能缩放不能变形**：参考把两个圆角声明为可变并实现 `animatableData`，让形状本身在过渡中重塑。
  我们三个半径在每个调用点都是字面量、每个状态都一样，32pt 药丸的曲率一直锁着，岛体长到 250pt 也不变。
  改为状态驱动（闭合 22/10/16，展开 16/12/20）；硬件缺口几何不参与插值，否则缺口会滑离真实刘海。
- **圆角会瞬跳**：外层 `.animation(nil, value: presentedState)` 会抑制形状的隐式动画，
  光有 `animatableData` 不够。新增 `islandSilhouette(expanding:)` 并把动画作用域收到形状本身，
  弹簧对齐窗口帧弹簧（0.42/0.82 展开、0.26/1.0 收起），不是内容 morph 的 0.30/0.88。
- **无场景合成**：参考用 `compositingGroup()`；我们的半透明层各自对窗口混合，过渡中有接缝。已加。

顺带修掉活 bug：内容 chrome 的圆角写死 22，没跟轮廓走（半径改为状态驱动后它成了唯一钉死处）。

新增 `--preview-transitions` 测**全部七条**转换（原验收只覆盖一条路径）：
移入 / 停留展开 / 行展开 / 收起 / 二次移入 / 通知横幅 / 横幅收起 ——
**全部 60 FPS，最差帧 16.69 ms**。测量本身也修了一个报告 bug（收起腿曾误报 extended→extended）。

## 2026-09-15 Slice 29 — 修「浅色外观下模块底色静默失效」

由测试套件崩溃引出：`strengths.min()!` 强解包在空数组上带崩整个 xctest 进程。
去掉强解包后立刻报出失败，暴露真 bug：**亮度模型只会提亮地面**，守卫
`relativeLuminance(tint) > relativeLuminance(canvas)` 在近白画布上对所有模块都为假，
函数一律返回 0 —— 该功能在浅色外观下从来没生效过。

修：模型显式接收外观（不再读环境），深色提亮受天花板约束、浅色压暗受地板约束；
浅色另乘 0.38，按感知而非测量值归一。画布颜色改为显式常量，两种外观都能确定性断言。
测试结构也改为**按外观外层循环**（原按模块循环抓不到「全体归零」）。

- Tests: 1570 green (11 explicit skips), 无 crash；release 零警告。
- CompanionMaterialTests 21 条；新增门全部验证过能失败。
## 1.5.0 — 前端质感重做（材质 / 动效 / 文案）与浮岛质检

这一版把界面从"平涂 + 边框"换成一套有光源的语言，并按社区高星实现质检了浮岛。

### 材质与光

- 全站只有一个光源、从上方照：抬起的面同时具备顶边高光、面部浅渐变、单层柔影。
  既有的 20 多处卡片一次性升级，不是逐页重写。深色浅色两套方向相反（浅色下顶白无效，改由底边定义）。
- **模块色**：18 个模块各自的强调色，贯穿侧栏方块、页头方块、环境光、选中行、筛选胶囊。
  选中行用本模块色填充，不再统一品牌绿。
- **环境光强度是算出来的**：由「按通道极差归一化」与「亮度天花板」两个约束取最小值，
  天花板从"落在它上面的字必须过 WCAG AA"反解。实测页头 10.0–10.7:1、正文 11.7–16.5:1。
- 发光主按钮、呼吸状态灯、错峰入场（6pt / 45ms 步进 / 封顶第 6 个）。

### 交互文案分层

新增 `CompanionInteractionCopy`：`CompanionProductCopy` 管"东西叫什么"，
新层管"用户正在操作时界面对他说什么"。三条硬规则：说结果不说实现、每个等待都要有承诺、每个失败都要有下一步。
18 行侧栏每行有了说明这页干什么用的 tooltip/VoiceOver，且与标签不同。

### 浮岛（按社区源码质检）

读了 `TheBoredTeam/boring.notch`（约 10.6k★）与 `MrKai77/DynamicNotchKit` 的源码，修三处：

- **外形现在会重塑，不只是缩放**：圆角改为状态驱动（闭合 22/10/16，展开 16/12/20），
  并实现 `animatableData` 让它们插值。此前三个半径在每个调用点都是字面量、每个状态都一样，
  32pt 药丸的曲率一直锁着，岛体长到 250pt 也不变。硬件缺口几何不参与插值。
- **圆角不再瞬跳**：动画作用域收到形状本身（外层 `.animation(nil, …)` 会抑制隐式动画）。
- **加了场景合成**，消除过渡中阴影轮廓与缺口带相接处的接缝。

新增 `--preview-transitions`，驱动九条转换并逐条记录帧率：
**八条测到 60 FPS，最差帧 16.69 ms**（一次 vsync 16.67）。

### 修掉的真 bug

| 缺陷 | 事实 |
|---|---|
| **浅色外观下模块底色完全不存在** | 亮度模型只会提亮地面，守卫在近白画布上对所有模块都为假，函数一律返回 0。该功能在一半外观下从未生效。 |
| 浮岛内容 chrome 圆角写死 | 没跟轮廓走，描边与阴影落在与形状不同的圆角上。 |
| 提示条边框恒为橙色 | 成功态的"已撤销"戴着警告框。 |
| 侧栏页脚压住滚动内容 | `safeAreaInset` 没有自己的底色。 |
| 三处分组标题与它唯一的行重复同一句 | 自动回复 / 使用偏好 / AI 服务。 |
| 待办筛选是手写副本 | 同尺寸但锁死品牌绿、无选中态抬起。 |
| 卡片顶边高光有接缝 | `trim` 描半个路径，首尾相接处可见断点。 |
| 引导页与使用指南用原生系统字体 | 与全站 token 不一致。 |
| 空列表只有劝退句 | 补"今天已经处理了 N 条"，且为 0 时不显示。 |
| 预览构建读正式钥匙串 | 每次预览弹系统密码框，把界面挡在解锁框之后。 |

### 质量门

- `CompanionMaterialTests` 21 条、`CompanionMotionTests` 24 条，均**验证过能失败**。
- 源码扫描门禁止任何调用点再写死浮岛圆角（曾抓到 `HUDRootView.swift:148`）。
- 全部去掉强制解包：测试崩掉进程等于没有任何测试结果。

### 验收

- `swift test`：**1570 通过，0 失败**，11 个显式跳过。
- `swift build -c release`：零警告零错误。
- 浮岛九条转换：八条 60 FPS；`peek → compact` 因真实指针监视器正确覆盖合成事件而无法活体测量，
  由通过的单测 `testLeavingPeekBeforeDwellDoesNotOpenInbox` 覆盖。

### 分发

- arm64，macOS 14+，Developer ID 签名并公证。
- 数据边界不变：只读本机微信聊天，不修改微信记录；自动托管默认关闭。
## 2026-09-15 Slice 30 — 对照 wechat-intelligence-hub 的密钥材料机制

参考 `Rion-Wu-tech/wechat-intelligence-hub`（v0.9.2-preview.2，**AGPL-3.0**）。
只借鉴机制与公开数据契约，不复制代码。

### 修掉一个"静默"级别的缺陷

`loadKeys` 原先只认 `{ "<path>": { "enc_key": "…" } }`，其他形状一律 `continue` 且**不报**。
于是别的格式会加载出 0 条密钥，Reader 再报"这个库没有对应密钥"——
用户读到的是「我的密钥不对」，真相是「这个文件不是我能读的形状」。

现在接受三种形状：对象式路径表（本项目自己的）、裸字符串路径表 + `key` 别名、
schema-2 salt 表（`{ schema_version: 2, keys: { "<32hex salt>": "<64hex key>" } }`）。
无法识别的条目改为**计数**（`rejectedKeyEntryCount`），"一条都没认出来"成为可见状态。

### salt 寻址：我们一直在写一个自己读不懂的字段

salt 表的真正价值是**内容寻址**：路径表在数据库改名/移动时失效，也无法表达无路径的密钥集。
而 `WeChatKeyPreparationService` 写出的密钥文件里**本来就有 `salt`**，Reader 从不用它。
现在路径查不到时读数据库前 16 字节再查一次；只在存在 salt 条目时才发生，纯路径文件零 I/O。

### 引导流程补两个状态

- `looseKeyPermissions`：密钥文件对本机其他账号可读。只查 group/other 位——
  owner 读不到已由 `.unreadable` 表达，重复判定会把一个问题报成两个。
- `unrecognizedKeyFormat(recognized:rejected:)`：文案明确写「这不代表密钥不对」，
  直接对冲上面那个误导。

判定顺序有意让**密钥问题排在目录问题前**：目录正确但密钥不可读同样读不到，
先说可操作的那个，用户才不会去重选一个本来就对的目录。

### 对照后确认已做到、不改的

zstd 压缩内容（`ct==4`）已实现；不打开微信正在写的原文件（我们解密成独立快照，更强）；
WAL 重放已有且注释记录了"微信 flush 会令 WAL 头盐失效"的真实陷阱；
`.ready` 文案本来就写「账号与密钥是否匹配仍需以成功同步为准」，
正是参考强调的 `ok:true` 只表示检查完成。

### 未做（明确边界）

实验性密钥获取工具（会重启微信、重签名副本、涉及管理员密码，需逐次确认）；
macOS 通知预览降级后端（是新功能不是优化，需单独产品决策）；能力矩阵文档（不需要对外承诺同等接口面）。

- Tests: 1589 green (11 explicit skips), 无 crash；release 零警告。
- 新增 19 条门**验证过能失败**：改回旧行为后 13 条立刻红，其中一条报出 `recognized=0, rejected=1`。
- 一条既有测试因新权限态失败，已确认非回归（它用默认 umask 0644，而 0644 确实过宽），
  改为固定 0600 让它只测"可用性 ≠ 可解析"那条轴。
